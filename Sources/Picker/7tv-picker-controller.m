/*
 * 7tv-picker-controller.m
 * Extrait de 7tv-core-manager.m (nettoyage picker).
 *
 * Picker d'emotes 7TV — grille + onglets (Favoris / 7TV) + recherche +
 * panneau des tailles (délégué à SevenTVPickerSizesPanel, composant enfant
 * instancié paresseusement, voir -sizesPanel ci-dessous).
 *
 * Entièrement indépendant du picker natif de Twitch : aucune donnée, aucun
 * onglet, aucune logique ne dépend des emotes natives Twitch.
 */

#import "Picker/7tv-picker-controller.h"
#import "Core/7tv-core-manager.h"
#import "Picker/7tv-picker-settings-panel.h"
#import "Localization/7tv-localization-manager.h"
#import "Picker/7tv-picker-resolved-emote.h"
#import "Picker/7tv-picker-cell.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Badge/7tv-badge-provider.h"
#import "Emote/7tv-emote-image-cache.h"
#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import "Emote/7tv-emote-animation-engine.h"
#import "Network/7tv-network-emote-cache.h"
#import "UI/7tv-ui-logo.h"
#import "UI/bttv-ui-logo.h"
#import "UI/ffz-ui-logo.h"
#import "UI/7tv-oled-mode.h"
#import <objc/runtime.h>

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVBitsHijacked = 6;

// ── Palette du picker (mode normal / OLED) ───────────────────────────────
// bgColor = fond de la grille (le plus sombre). cardColor = tout ce qui doit
// se détacher légèrement du fond (cellules + pastilles/capsules flottantes).
// sepColor = séparateurs. En OLED tout passe au noir profond, cartes et
// séparateurs gardent juste assez de contraste pour rester discernables.
static UIColor *s7tv_pickerBgColor(void) {
    return S7TVOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}
static UIColor *s7tv_pickerCardColor(void) {
    return S7TVOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.05 alpha:1.0]
        : [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
}
static UIColor *s7tv_pickerSepColor(void) {
    return S7TVOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.12 alpha:1.0]
        : [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}
static UIColor *s7tv_pickerAccentColor(void) {
    return [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
}

// UICollectionView crée ses premières cellules pendant le layout préparatoire
// de l'inputView, donc avant que le picker possède une UIWindow. Le pipeline
// image refuse volontairement de charger des cellules hors écran ; il faut
// ainsi un signal fiable au moment exact où UIKit attache réellement le
// clavier custom, plutôt qu'un dispatch_async susceptible d'arriver trop tôt.
@interface S7TVPickerContainerView : UIView
@property (nonatomic, copy) dispatch_block_t didAttachToWindow;
@end

@implementation S7TVPickerContainerView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && self.didAttachToWindow) self.didAttachToWindow();
}
@end

@interface S7TVPickerWeakRef : NSObject
@property (nonatomic, weak) id object;
+ (instancetype)refWithObject:(id)object;
@end

@implementation S7TVPickerWeakRef
+ (instancetype)refWithObject:(id)object {
    S7TVPickerWeakRef *reference = [S7TVPickerWeakRef new];
    reference.object = object;
    return reference;
}
@end

// Une section de catalogue est gardée séparément de l'array plat historique
// du picker. Le renderer sélectionne une sous-catégorie à la fois sans casser
// le pipeline de cellules/animations déjà partagé avec l'ancien picker.
@interface S7TVPickerDisplaySection : NSObject
@property (nonatomic, assign) S7TVEmoteProviderID provider;
@property (nonatomic, assign) S7TVEmoteSectionKind kind;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SevenTVEmote *> *items;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL empty;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end

@implementation S7TVPickerDisplaySection
@end

// En-tête léger pour les sections provider. Le bouton transparent couvre
// toute la ligne ; les labels restent donc lisibles tout en gardant une seule
// cible VoiceOver/tap pour ouvrir ou replier la section.
@interface S7TVPickerSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *retryButton;
@end

@implementation S7TVPickerSectionHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _toggleButton.frame = self.bounds;
    _toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    // The button covers the complete row so the whole header is tappable, but
    // keep its chevron at the trailing edge instead of letting UIKit center it
    // over the title/count labels.
    _toggleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    _toggleButton.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8.0);
    _toggleButton.accessibilityTraits = UIAccessibilityTraitButton;
    [self addSubview:_toggleButton];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    _countLabel.textAlignment = NSTextAlignmentRight;
    _countLabel.userInteractionEnabled = NO;
    [self addSubview:_countLabel];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
    _stateLabel.textAlignment = NSTextAlignmentRight;
    _stateLabel.userInteractionEnabled = NO;
    _stateLabel.hidden = YES;
    [self addSubview:_stateLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
        configurationWithPointSize:11.0 weight:UIImageSymbolWeightMedium];
    [_retryButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"
                              withConfiguration:config]
                   forState:UIControlStateNormal];
    _retryButton.accessibilityLabel = @"Retry";
    _retryButton.hidden = YES;
    [self addSubview:_retryButton];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = 8.0;
    CGFloat retryWidth = self.retryButton.hidden ? 0.0 : 26.0;
    self.retryButton.frame = CGRectMake(self.bounds.size.width - inset - retryWidth,
                                        0, retryWidth, self.bounds.size.height);
    CGFloat chevronWidth = 24.0;
    self.toggleButton.frame = self.bounds;
    self.titleLabel.frame = CGRectMake(inset, 0,
                                       MAX(0, self.bounds.size.width - inset * 2 - retryWidth - chevronWidth),
                                       self.bounds.size.height);
    CGFloat right = self.bounds.size.width - inset - retryWidth - chevronWidth;
    CGFloat stateWidth = self.stateLabel.hidden ? 0.0 : MIN(110.0, right * 0.40);
    self.stateLabel.frame = CGRectMake(MAX(inset, right - stateWidth), 0,
                                       stateWidth, self.bounds.size.height);
    self.countLabel.frame = CGRectMake(MAX(inset, right - stateWidth - 46.0), 0,
                                       46.0, self.bounds.size.height);
}
@end

@interface SevenTVManager (S7TVChatBarButton)
- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender;
@end

@implementation SevenTVManager (S7TVChatBarButton)
- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender {
    id association = objc_getAssociatedObject(sender, &kS7TVTextFieldTagged);
    UIView *chatInputView = [association isKindOfClass:S7TVPickerWeakRef.class]
        ? ((S7TVPickerWeakRef *)association).object : association;
    if (!chatInputView.window) return;
    [self toggleEmotePickerForChatInputView:chatInputView];
}
@end

void s7tv_handleChatInputViewLifecycle(UIView *view) {
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.ChatInputView"]) return;
    if (!view.window) {
        if (objc_getAssociatedObject(view, &kS7TVTextFieldTagged)) {
            [[SevenTVManager sharedManager]
                cleanupPickerForStreamCloseIfOwnedByChatInputView:view];
            objc_setAssociatedObject(view, &kS7TVTextFieldTagged, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (objc_getAssociatedObject(view, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(view, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakChatInputView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *chatInputView = weakChatInputView;
        if (!chatInputView || !chatInputView.window) return;
        SevenTVManager *manager = [SevenTVManager sharedManager];
        __block UIButton *bitsButton = nil;
        __block UIView *emoticonButton = nil;
        NSMutableArray<UIView *> *views =
            [NSMutableArray arrayWithArray:chatInputView.subviews];
        while (views.count > 0) {
            UIView *candidate = views.firstObject;
            [views removeObjectAtIndex:0];
            [views addObjectsFromArray:candidate.subviews];
            NSString *className = NSStringFromClass(candidate.class);
            if ([className containsString:@"BitsButton"] ||
                [className containsString:@"bitsButton"] ||
                [candidate.accessibilityIdentifier isEqualToString:@"chat_input_bits_button"]) {
                bitsButton = (UIButton *)candidate;
            }
            if ([className containsString:@"Emoticon"] ||
                [className containsString:@"emoticon"]) emoticonButton = candidate;
            if (bitsButton && emoticonButton) break;
        }

        if (bitsButton &&
            ![objc_getAssociatedObject(bitsButton, &kS7TVBitsHijacked) boolValue]) {
            objc_setAssociatedObject(bitsButton, &kS7TVBitsHijacked, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (id target in bitsButton.allTargets) {
                for (NSString *action in [bitsButton actionsForTarget:target
                                                       forControlEvent:UIControlEventTouchUpInside]) {
                    [bitsButton removeTarget:target action:NSSelectorFromString(action)
                            forControlEvents:UIControlEventTouchUpInside];
                    [manager log:@"🔌 Bits: action retirée — %@->%@",
                        NSStringFromClass([target class]), action];
                }
            }

            NSData *logoData = [[NSData alloc]
                initWithBase64EncodedString:kS7TVLogoBase64
                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *icon = [UIImage imageWithData:logoData scale:2.0];
            if (icon) {
                CGFloat targetHeight = emoticonButton
                    ? MIN(emoticonButton.bounds.size.height,
                          emoticonButton.bounds.size.width) * 0.75 : 22.0;
                if (targetHeight < 14.0) targetHeight = 22.0;
                CGFloat targetWidth = targetHeight *
                    (icon.size.width / MAX(icon.size.height, 1.0));
                UIGraphicsBeginImageContextWithOptions(
                    CGSizeMake(targetWidth, targetHeight), NO, UIScreen.mainScreen.scale);
                [icon drawInRect:CGRectMake(0, 0, targetWidth, targetHeight)];
                UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (resizedIcon) icon = resizedIcon;
                for (NSNumber *state in @[@(UIControlStateNormal),
                                          @(UIControlStateHighlighted),
                                          @(UIControlStateSelected),
                                          @(UIControlStateDisabled)]) {
                    [bitsButton setImage:icon forState:state.unsignedIntegerValue];
                }
                bitsButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
                bitsButton.tintColor = UIColor.whiteColor;
            }
            bitsButton.accessibilityLabel = L(@"label_7tv_emotes");
            objc_setAssociatedObject(bitsButton, &kS7TVTextFieldTagged,
                                     [S7TVPickerWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [bitsButton addTarget:manager
                           action:@selector(s7tv_emoteButtonTappedForButton:)
                 forControlEvents:UIControlEventTouchUpInside];
            [manager log:@"✅ Bouton Bits hijacké → 7TV (frame=%.0f,%.0f,%.0f,%.0f)",
                bitsButton.frame.origin.x, bitsButton.frame.origin.y,
                bitsButton.frame.size.width, bitsButton.frame.size.height];
            return;
        }

        if (!bitsButton) {
            [manager log:@"⚠️ ChatInputViewBitsButton introuvable — fallback injection"];
            UIView *target = emoticonButton.superview ?: chatInputView;
            for (UIView *subview in target.subviews) if (subview.tag == 0x7777) return;

            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.tag = 0x7777;
            UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
                configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
            UIImage *icon = [UIImage systemImageNamed:@"sparkles"
                                    withConfiguration:configuration];
            UIColor *purple = [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0];
            if (icon) {
                [button setImage:icon forState:UIControlStateNormal];
                button.tintColor = purple;
            } else {
                [button setTitle:L(@"label_7tv_badge") forState:UIControlStateNormal];
                [button setTitleColor:purple forState:UIControlStateNormal];
                button.titleLabel.font = [UIFont boldSystemFontOfSize:10];
            }
            CGFloat size = 36.0;
            CGFloat x = emoticonButton
                ? emoticonButton.frame.origin.x - size - 4.0
                : MAX(0, target.frame.size.width - size - 4.0);
            CGFloat y = emoticonButton
                ? emoticonButton.frame.origin.y + (emoticonButton.frame.size.height - size) / 2.0
                : (target.frame.size.height - size) / 2.0;
            button.frame = CGRectMake(MAX(0, x), y, size, size);
            button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin |
                UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            objc_setAssociatedObject(button, &kS7TVTextFieldTagged,
                                     [S7TVPickerWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [button addTarget:manager action:@selector(s7tv_emoteButtonTappedForButton:)
              forControlEvents:UIControlEventTouchUpInside];
            [target addSubview:button];
            [target bringSubviewToFront:button];
            [manager log:@"🎹 Bouton 7TV fallback injecté — x=%.0f y=%.0f", x, y];
        } else {
            [manager log:@"ℹ️ Bouton Bits déjà hijacké, rien à faire"];
        }
    });
}

@interface SevenTVEmotePickerController ()

// Panneau des tailles — composant enfant, créé paresseusement (voir -sizesPanel)
@property (nonatomic, strong) SevenTVPickerSizesPanel *sizesPanel;

// Picker d'emotes inline (affiché au-dessus de la barre de saisie)
@property (nonatomic, strong) UIView              *emotePickerView;
// FORT (pas weak) — doit rester valide jusqu'au tap sur l'emote.
// Un weak pointer devient nil dès que Twitch recycle la vue → insertion silencieuse.
@property (nonatomic, weak)   UIView              *emotePickerTextField;
// Référence forte au _TtC6Twitch...TextEntryView — reste firstResponder pendant le picker.
@property (nonatomic, weak)   UITextView          *emotePickerTextEntryView;
@property (nonatomic, strong) UICollectionView    *emoteCollectionView;
@property (nonatomic, strong) UITextField         *emoteSearchField;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerEmotes;
@property (nonatomic, strong, readwrite) NSArray<SevenTVEmote *> *emotePickerAllEmotes;
// L'alerte de recherche emprunte temporairement le first responder au champ
// Twitch. Pendant ce transfert, UITextViewTextDidEndEditingNotification ne
// doit pas être interprétée comme une vraie fermeture du picker.
@property (nonatomic, assign) BOOL pickerSearchAlertActive;

// Arrays filtrés pour l'affichage dans le picker (3 sections)
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerChannelEmotes;
@property (nonatomic, strong, readwrite) NSArray<SevenTVEmote *> *emotePickerGlobalEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerOtherEmotes; // compatibilité
// Arrays provider-aware alimentés depuis S7TVEmoteCatalog. Les anciennes
// propriétés restent utilisées par les previews et par le code 7TV historique.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<SevenTVEmote *> *> *pickerProviderEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *pickerCatalogFavorites;
@property (nonatomic, copy) NSSet<NSString *> *pickerFavoriteKeySet;
// Sections provider-aware conservées pour les capsules Channel/Global. Les
// valeurs restent des wrappers SevenTVEmote pour partager toutes les cellules
// et les animations avec le chemin legacy.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<S7TVPickerDisplaySection *> *> *pickerProviderSections;
@property (nonatomic, strong) NSArray<S7TVPickerDisplaySection *> *pickerDisplaySections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pickerCollapsedSections;
// Search temporarily expands every matching section. Keep the user's
// collapsed/open choices out of that transient state so clearing the search
// restores the layout they had before typing.
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pickerCollapseStateBeforeSearch;
@property (nonatomic, assign) BOOL pickerCatalogSearchActive;
@property (nonatomic, assign) BOOL pickerUsesCatalogSections;

// Bouton ⚙️ du panneau des tailles (chrome du picker — voir SevenTVPickerSizesPanel
// pour la logique/les données du panneau lui-même)
@property (nonatomic, weak) UIButton *pickerSizesToggleBtn;
// Bouton réglages, collé au bouton des tailles — ouvre le même écran que le
// bouton flottant 7TV (voir -[SevenTVManager presentSettingsMenu]).
@property (nonatomic, weak) UIButton *pickerSettingsBtn;
// Capsule commune qui regroupe pickerSettingsBtn + pickerSizesToggleBtn dans
// un seul fond pilule partagé (même langage visuel que pickerTabCapsuleView /
// pickerTabCapsuleView, où plusieurs icônes flottent ensemble sur un
// seul fond) — les 2 boutons sont ainsi visuellement collés au lieu d'être
// 2 pastilles séparées avec un espace entre elles.
@property (nonatomic, weak) UIView   *pickerToolsCapsuleView;
@property (nonatomic, assign) BOOL   pickerSizesPanelVisible;

// Conteneur du faux chat (SevenTVPickerSizesPanel.fakeChatView), ajouté
// directement à la key window — pas à emotePickerView — car ce dernier EST
// l'inputView du clavier et ne peut pas héberger un aperçu positionné
// librement par-dessus le vrai chat. weak : la key window (superview) le
// retient, pas ce controller (même logique que emotePickerTextField).
@property (nonatomic, weak) UIView *pickerFakeChatPreviewView;

// ── Refonte tabbed + refonte visuelle du picker (style 7TV PC) ──────────
// Onglet actif : Favoris / Tous / 7TV / BTTV / FFZ. « Tous » est un pseudo-
// provider uniquement visuel : il ne participe jamais aux requêtes, au
// tokenizer ni aux réglages provider-aware.
@property (nonatomic, assign) NSInteger pickerActiveTab;
// Mémorise l'onglet actif juste avant qu'une recherche démarre, pour le
// restaurer quand le champ de recherche redevient vide (la recherche
// bascule automatiquement Favoris → Channel → Globales, voir point 3).
@property (nonatomic, assign) BOOL      pickerIsSearching;
@property (nonatomic, assign) NSInteger pickerPreSearchTab;
// Plus de header, plus de dock plein fond : TOUT est flottant par-dessus la
// grille (comme la pastille fermer), même langage visuel partout → aucun
// bandeau opaque ne mange de la place, on voit plus d'emotes.
// La capsule provider reste fixe en bas à gauche. Une seconde capsule, juste
// au-dessus, permet de choisir Channel ou Global pour le provider actif.
@property (nonatomic, weak) UIView    *pickerSubcategoryCapsuleView;
@property (nonatomic, weak) UIButton  *pickerSubcategoryChannelBtn;
@property (nonatomic, weak) UIButton  *pickerSubcategoryGlobalBtn;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pickerSubcategoryByProvider;
@property (nonatomic, weak) UIView    *pickerTabCapsuleView;         // bas gauche (Favoris/Tous/7TV/BTTV/FFZ)
@property (nonatomic, strong) NSMutableArray<UIButton *> *pickerTabButtons;
@property (nonatomic, weak) UIView    *pickerTabIndicatorView;       // pastille violette qui glisse entre les 5 boutons
@property (nonatomic, weak) UIView    *pickerSearchCapsuleView;      // bas, pleine largeur (recherche)
@property (nonatomic, weak) UIButton  *pickerSearchClearBtn;         // petite croix à droite du champ, visible si texte non vide
// Pendant un drag/deceleration, les miniatures continuent de charger et chaque
// cellule visible demande immédiatement une preview animée annulable. Dès
// qu'elle sort de l'écran, didEndDisplayingCell coupe observation et décodage.
@property (nonatomic, assign) BOOL pickerScrollInProgress;
@property (nonatomic, assign) BOOL pickerCatalogReloadPending;
@property (nonatomic, assign) NSUInteger pickerOrientationGeneration;
// Pendant la première ouverture, si le provider par défaut est encore vide
// mais qu'un autre provider répond déjà, basculer automatiquement vers le
// premier provider non vide. Un tap explicite sur un onglet désactive ce
// comportement pour ne jamais reprendre le contrôle de la sélection utilisateur.
@property (nonatomic, assign) BOOL pickerInitialProviderSelectionPending;
// Les snapshots sont coûteux à aplatir (et les favoris peuvent être stockés
// hors du channel courant). On ne reconstruit donc les wrappers qu'après une
// vraie notification de catalogue/réglages, jamais à chaque ouverture.
@property (nonatomic, assign) BOOL pickerCatalogArraysDirty;
// Un choix explicite dans les réglages ne doit pas être remplacé par la
// sélection automatique du premier provider pendant le chargement.
@property (nonatomic, assign) BOOL pickerOpeningLocationExplicit;

- (void)_s7tv_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection;
- (void)_s7tv_emoteCatalogDidUpdate:(NSNotification *)notification;
- (void)_s7tv_twitchCredentialsDidUpdate:(NSNotification *)notification;
- (void)_s7tv_badgesCatalogDidUpdate:(NSNotification *)notification;
- (void)_s7tv_deviceOrientationDidChange:(NSNotification *)notification;
- (void)_s7tv_applyCatalogUpdateNow;
- (void)_s7tv_normalizeActivePickerTab;
- (BOOL)_s7tv_selectInitialProviderIfNeeded;
- (S7TVEmoteProviderID)_s7tv_providerForPickerTab:(NSInteger)tab;
- (void)_s7tv_updateSubcategoryCapsule;
- (void)_pickerSubcategoryTapped:(UIButton *)sender;
- (BOOL)_s7tv_sectionIsChannel:(S7TVPickerDisplaySection *)section;
- (BOOL)_s7tv_sectionIsGlobal:(S7TVPickerDisplaySection *)section;
- (BOOL)_s7tv_pickerTabIsProvider:(NSInteger)tab;
- (void)_s7tv_updatePickerTabButtonLayout;
- (NSArray<NSNumber *> *)_s7tv_providerIDsInPriorityOrder;
- (void)_s7tv_persistLastPickerLocation;
- (BOOL)_s7tv_applyConfiguredPickerOpeningLocation;
- (void)_s7tv_oledModeDidChange:(NSNotification *)notification;
- (void)_s7tv_applyOLEDColors;
- (void)_s7tv_relayoutPickerForSize:(CGSize)size;
- (void)_showFakeChatPreviewAboveInputView;
- (void)_s7tv_deactivateVisiblePickerAnimations;
- (void)_s7tv_activateVisiblePickerAnimations;
- (void)_s7tv_scheduleAnimationForPickerCell:(S7TVEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath;
- (void)_s7tv_scheduleStaticImageForPickerCell:(S7TVEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath;
- (BOOL)_s7tv_configureAnimatedPickerCell:(S7TVEmotePickerCell *)cell
                             resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode;
- (void)_pickerSectionHeaderTapped:(UIButton *)sender;
- (void)_pickerSectionRetryTapped:(UIButton *)sender;

@end

@implementation SevenTVEmotePickerController

// Valeurs par défaut reprises telles quelles de l'ancien -[SevenTVManager setup]
// (avant l'extraction du picker dans ce fichier) : onglet Favoris au départ,
// sous-catégorie Channel pour les providers, tableau des boutons prêt
// à être rempli par -_createEmotePickerViewWithFrame:.
- (instancetype)init {
    self = [super init];
    if (self) {
        _pickerActiveTab                  = 0; // S7TVPickerTabFavorites
        _pickerTabButtons                 = [NSMutableArray array];
        _emotePickerFavoriteEmotes = @[];
        _emotePickerChannelEmotes  = @[];
        _emotePickerGlobalEmotes   = @[];
        _emotePickerOtherEmotes    = @[];
        _pickerProviderEmotes      = @{};
        _pickerCatalogFavorites    = @[];
        _pickerFavoriteKeySet      = [NSSet set];
        _pickerProviderSections    = @{};
        _pickerDisplaySections     = @[];
        _pickerCollapsedSections   = [NSMutableDictionary dictionary];
        _pickerSubcategoryByProvider = [NSMutableDictionary dictionary];
        _pickerCollapseStateBeforeSearch = nil;
        _pickerCatalogSearchActive = NO;
        _pickerUsesCatalogSections = NO;
        _pickerInitialProviderSelectionPending = NO;
        _pickerCatalogArraysDirty = YES;
        _pickerOpeningLocationExplicit = NO;
        // Abonnement permanent à S7TVChannelJoined (postée par
        // SevenTVManager lors du ROOMSTATE) — même logique que
        // SevenTVBadgeProvider : ce controller n'est jamais désalloué en
        // cours de vie de l'app (cleanupPickerForStreamClose masque juste la
        // vue, ne détruit pas l'objet), donc pas de -dealloc pour se
        // désabonner.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_channelJoinedNotification:)
                                                      name:@"S7TVChannelJoined"
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_emoteCatalogDidUpdate:)
                                                      name:S7TVEmoteCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_emoteCatalogDidUpdate:)
                                                      name:S7TVProviderCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_emoteCatalogDidUpdate:)
                                                      name:S7TVEmoteProviderSettingsDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_twitchCredentialsDidUpdate:)
                                                      name:S7TVTwitchCredentialsDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_badgesCatalogDidUpdate:)
                                                      name:S7TVBadgesCatalogUpdatedNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_deviceOrientationDidChange:)
                                                      name:UIDeviceOrientationDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_oledModeDidChange:)
                                                      name:S7TVOLEDModeDidChangeNotification
                                                    object:nil];

        // Le TextEntryView de Twitch peut résigner le first responder sans
        // passer par notre bouton (ex: tap ailleurs dans l'app) — UIKit
        // retire alors l'inputView (notre picker) tout seul, SANS jamais
        // appeler _hideEmotePicker. Le faux chat flottant (attaché à la key
        // window, indépendant du clavier) restait donc affiché tant que le
        // picker n'était pas rouvert/refermé manuellement. On rattrape ça ici.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_textEntryDidEndEditing:)
                                                      name:UITextViewTextDidEndEditingNotification
                                                    object:nil];
    }
    return self;
}

- (void)_s7tv_oledModeDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _s7tv_applyOLEDColors];
    });
}

- (void)_s7tv_applyOLEDColors {
    if (!self.emotePickerView) return;

    UIColor *backgroundColor = s7tv_pickerBgColor();
    UIColor *cardColor       = s7tv_pickerCardColor();
    UIColor *sepColor        = s7tv_pickerSepColor();

    self.emotePickerView.backgroundColor = backgroundColor;
    self.emoteCollectionView.backgroundColor = backgroundColor;

    // Capsules flottantes : fond carte translucide, même couleur que les
    // cellules de la grille (cohérence visuelle).
    UIColor *capsuleColor = [cardColor colorWithAlphaComponent:0.92];
    self.pickerTabCapsuleView.backgroundColor   = capsuleColor;
    self.pickerSubcategoryCapsuleView.backgroundColor = capsuleColor;
    self.pickerToolsCapsuleView.backgroundColor = capsuleColor;
    self.pickerSearchCapsuleView.backgroundColor = capsuleColor;

    // Cellules visibles de la grille : recolorer carte + bordure immédiatement
    // (le cellForRowAtIndexPath: du reload normal fera le reste pour les
    // futures cellules déqueuées).
    for (S7TVEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell s7tv_applyOLEDColors];
    }
    UIColor *headerColor = S7TVOLEDModeEnabled()
        ? [UIColor colorWithWhite:1.0 alpha:0.035]
        : [UIColor colorWithWhite:1.0 alpha:0.055];
    for (S7TVPickerSectionHeaderView *header in
         [self.emoteCollectionView visibleSupplementaryViewsOfKind:
             UICollectionElementKindSectionHeader]) {
        header.backgroundColor = headerColor;
    }

    // Panneau des tailles (séparateurs + capsule de catégories + segmented
    // controls).
    if (_sizesPanel) {
        [_sizesPanel s7tv_applyOLEDColorsWithBgColor:backgroundColor
                                            sepColor:sepColor
                                           cardColor:cardColor];
    }

    // Aperçu du chat flottant.
    self.pickerFakeChatPreviewView.backgroundColor = S7TVOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.09 alpha:0.97];
}

- (void)_s7tv_textEntryDidEndEditing:(NSNotification *)note {
    if (note.object != self.emotePickerTextEntryView) return;
    if (!self.emotePickerView || self.emotePickerView.hidden) return; // picker déjà fermé, rien à faire
    if (self.pickerSearchAlertActive) return; // focus prêté à l'alerte de recherche

    // Pas de resignFirstResponder/reloadInputViews ici : la résignation est
    // déjà en cours côté UIKit (c'est elle qui a déclenché cette notif).
    // On se contente de remettre notre propre état à plat.
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
    [self _hideFakeChatPreview];
}

// Panneau des tailles — composant enfant, créé à la demande la première fois
// qu'on y touche (toggle du bouton ⚙️ ou construction de la vue du picker).
- (SevenTVPickerSizesPanel *)sizesPanel {
    if (!_sizesPanel) {
        _sizesPanel = [[SevenTVPickerSizesPanel alloc] init];
        _sizesPanel.picker = self;
    }
    return _sizesPanel;
}

// ID de cellule pour la collection
static NSString *const kEmoteCellID = @"S7TVEmoteCell";

// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize = 40.0;

// ── Onglets du picker refondu (style 7TV PC) ──────────────────────────────
// 5 valeurs : Favoris / Tous / 7TV / BTTV / FFZ. « Tous » agrège les
// sections Channel/Shared/Sets et Global de tous les providers activés.
typedef NS_ENUM(NSInteger, S7TVPickerTab) {
    S7TVPickerTabFavorites = 0,
    S7TVPickerTabAll       = 1,
    S7TVPickerTabSevenTV   = 2,
    S7TVPickerTabBTTV      = 3,
    S7TVPickerTabFFZ       = 4,
};

// ── Dimensions du picker refondu ────────────────────────────────────────
// Plus de header, plus de dock opaque : la grille occupe 100% du picker
// (y=0 à height) et TOUT flotte par-dessus (fermer / sous-choix en haut,
// onglets + ⚙️ + recherche en bas), façon pastilles translucides façon
// petit sélecteur 7TV PC. layout.sectionInset réserve juste assez de place
// en haut et en bas pour que les cellules ne passent jamais dessous.
static const CGFloat kS7TVPickerFloatSize    = 28.0; // diamètre/hauteur des pastilles flottantes (fermer, onglets, sous-choix, ⚙️)
static const CGFloat kS7TVPickerFloatMargin  = 8.0;  // marge entre une pastille et le bord du picker
static const CGFloat kS7TVPickerFloatGap     = 6.0;  // écart vertical entre 2 rangées de pastilles flottantes
static const CGFloat kS7TVPickerSubcategoryGap = 4.0; // écart preview entre Channel/Global et les providers
static const CGFloat kS7TVPickerSearchH      = 38.0; // hauteur de la capsule de recherche
// Zone totale réservée en bas de la grille (sectionInset.bottom) pour ne
// jamais cacher une cellule sous les onglets/⚙️/recherche flottants :
// marge + ligne d'onglets + écart + recherche + marge.
static const CGFloat kS7TVPickerBottomZoneH  =
    kS7TVPickerFloatMargin + kS7TVPickerFloatSize + kS7TVPickerFloatGap + kS7TVPickerSearchH + kS7TVPickerFloatMargin;

static const CGFloat kS7TVPickerGridDefaultH =
    280.0; // hauteur du picker en mode grille — référence pour le mode "tailles" (point 5)
// (annulation lors du recyclage)
- (NSURLSession *)pickerImageSession {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ephemeralSessionConfiguration : isolation totale du sharedURLCache iOS
        // (que Twitch peut vider à tout moment) → on branche sur notre cache dédié.
        // protocolClasses = @[] : SevenTVURLProtocol n'intercepte pas ses propres
        // requêtes CDN → pas de boucle d'interception.
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache                      = [SevenTVURLProtocol sharedEmoteCache];
        cfg.requestCachePolicy            = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses               = @[];
        cfg.HTTPMaximumConnectionsPerHost = 6;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

// ── Queue série pour le décodage des animations ───────────────────────────────
//
// CRITIQUE : ne PAS utiliser dispatch_get_global_queue pour les animations.
// Chaque frame WebP 4x décodée = ~160 KB RAM non compressée.
// 30 frames × 20 emotes visibles × threads concurrent = spike ~100 MB → OOM kill.
// Une queue SÉRIE garantit qu'un seul décodage tourne à la fois.
//
- (dispatch_queue_t)_animationDecodeQueue {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("tv.s7tv.anim-decode", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ── Décodage image pour le picker ─────────────────────────────────────────────
//
// wantsAnimated=YES ET showPickerAnimations=YES → UIImage animée (toutes frames)
// sinon → frame 0 uniquement (rapide, économe en RAM)
//
// ── Force-decode hors thread principal ─────────────────────────────────────
//
// CGImageSourceCreateImageAtIndex crée une image "lazy" : les octets
// compressés (PNG/WebP/GIF) ne sont réellement décompressés qu'au premier
// rendu — c'est-à-dire quand UIKit assigne l'image à un CALayer, sur le
// MAIN THREAD. Résultat : même si tout ce qui précède tourne déjà en
// arrière-plan (decodeQ), UIKit refait un vrai travail de décodage
// synchrone au moment de l'affichage → micro-freeze/saccade au scroll.
//
// Fix : redessiner l'image dans un contexte bitmap ICI (donc toujours en
// arrière-plan, cette méthode n'est jamais appelée depuis le main thread)
// force la décompression complète immédiatement. Le UIImage renvoyé est
// déjà "prêt à afficher" — assigner .image sur le main thread ne coûte
// plus qu'un memcpy.
- (UIImage *)_forceDecodedImage:(UIImage *)img {
    if (!img || img.size.width < 1 || img.size.height < 1) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale  = img.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:img.size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawAtPoint:CGPointZero];
    }];
}

- (UIImage *)decodePickerImageData:(NSData *)data wantsAnimated:(BOOL)wantsAnimated {
    if (!data) return nil;

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return [self _forceDecodedImage:[UIImage imageWithData:data]];

    // ── Animé : décoder toutes les frames ──────────────────────────────────
    if (wantsAnimated) {
        NSUInteger count = CGImageSourceGetCount(src);
        if (count > 1) {
            // Cap à 24 frames — au-delà les gains visuels sont nuls mais
            // la RAM explose (chaque frame 4x ≈ 160 KB décompressé).
            NSUInteger maxFrames = MIN(count, 24);
            NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:maxFrames];
            NSTimeInterval duration = 0.0;

            for (NSUInteger i = 0; i < maxFrames; i++) {
                // @autoreleasepool : libère le CGImage immédiatement après
                // chaque itération → pic mémoire = 1 frame, pas N frames.
                @autoreleasepool {
                    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                    if (!cgImg) continue;

                    UIImage *frame = [UIImage imageWithCGImage:cgImg];
                    CGImageRelease(cgImg);
                    [frames addObject:[self _forceDecodedImage:frame]];

                    NSDictionary *props = CFBridgingRelease(
                        CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
                    NSDictionary *gifProps  = props[@"{GIF}"];
                    NSDictionary *webpProps = props[@"{WebP}"];
                    NSNumber *delay = gifProps[@"UnclampedDelayTime"]
                                   ?: gifProps[@"DelayTime"]
                                   ?: webpProps[@"DelayTime"];
                    duration += (delay && delay.doubleValue > 0.01)
                                ? delay.doubleValue : 0.1;
                }
            }

            CFRelease(src);

            if (frames.count > 1) {
                return [UIImage animatedImageWithImages:frames
                                              duration:MAX(duration, 0.5)];
            }
            return frames.firstObject;
        }
    }

    // ── Statique : frame 0 uniquement ──────────────────────────────────────
    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    UIImage *img = nil;
    if (cgImg) { img = [UIImage imageWithCGImage:cgImg]; CGImageRelease(cgImg); }
    CFRelease(src);
    img = img ?: [UIImage imageWithData:data];
    return [self _forceDecodedImage:img];
}

// ── Avatar de la chaîne (bouton "Chaîne" de la capsule sous-choix) ─────────
//
// Point d'entrée notif : S7TVChannelJoined n'est postée que pour un VRAI
// changement de broadcaster ID (voir -handleIRCRoomState:), jamais pour un
// simple re-join du même channel — pas de refetch inutile.
- (void)_s7tv_channelJoinedNotification:(NSNotification *)note {
    NSString *channelID = note.userInfo[@"channelID"];
    if (!channelID.length) return;

    self.pickerCatalogArraysDirty = YES;

    // CRITIQUE : S7TVChannelJoined est postée depuis -handleIRCRoomState:
    // pendant le traitement des messages IRC (WebSocket), donc HORS main
    // thread. NSNotificationCenter exécute les observers de façon SYNCHRONE
    // sur le thread qui poste — sans ce dispatch, tout ce qui suit (UIButton
    // setImage:) s'exécute hors main thread : ça ne crashe pas forcément,
    // mais ça ne se rend pas de façon fiable (c'était la cause du bug "l'avatar
    // ne change pas au changement de chaîne").
    dispatch_async(dispatch_get_main_queue(), ^{
        // Le bouton n'existe que si le picker a déjà été construit une première fois.
        if (!self.pickerSubcategoryChannelBtn) return;
        // Ne jamais conserver l'image de l'ancienne chaîne pendant que le
        // provider commun résout la nouvelle.
        [self _s7tv_resetChannelButtonToPlaceholder];
        [self _s7tv_refreshChannelAvatarIfNeeded];
    });
}

// Appelé à CHAQUE ouverture du picker (voir -_buildAndShowEmotePickerForView:) :
// applique l'avatar déjà en cache pour la chaîne courante, ou lance le fetch
// sinon. C'est le filet de sécurité qui ne dépend pas du timing de la notif
// S7TVChannelJoined — utile si la chaîne a changé pendant que le picker
// était fermé (aucune autre occasion de revérifier dans ce cas).
- (void)_s7tv_refreshChannelAvatarIfNeeded {
    NSString *channelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    if (!channelID.length) {
        [self _s7tv_resetChannelButtonToPlaceholder];
        return;
    }

    // Source unique avec le chat partagé : résolution Helix, déduplication,
    // retry et cache d'URL vivent tous dans SevenTVBadgeProvider. Le picker
    // ne maintient plus son propre client Helix parallèle.
    id<S7TVResolvedEmote> avatar = [[SevenTVBadgeProvider sharedProvider]
        resolvedChannelAvatarForChannelID:channelID];
    if (!avatar) {
        [self _s7tv_resetChannelButtonToPlaceholder];
        return; // le provider publiera S7TVBadgesCatalogUpdatedNotification
    }

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];
    UIImage *cached = [imageCache cachedImageForResolvedEmote:avatar];
    if (cached) {
        [self _s7tv_applyChannelAvatarImage:cached];
        return;
    }

    [self _s7tv_resetChannelButtonToPlaceholder];
    NSString *requestedChannelID = [channelID copy];
    __weak typeof(self) weakSelf = self;
    [imageCache imageForResolvedEmote:avatar completion:^(UIImage * _Nullable image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // Une réponse tardive d'une ancienne chaîne ne doit jamais remplacer
        // l'avatar du salon courant.
        if (![[SevenTVManager sharedManager].currentChannelTwitchID
              isEqualToString:requestedChannelID]) return;
        [strongSelf _s7tv_applyChannelAvatarImage:image];
    }];
}

// Si le picker s'est ouvert avant que Twitch ait émis sa première requête GQL,
// le premier appel Helix n'avait pas encore de credentials. Relancer dès leur
// capture évite d'exiger une fermeture/réouverture manuelle du picker.
- (void)_s7tv_twitchCredentialsDidUpdate:(__unused NSNotification *)notification {
    self.pickerCatalogArraysDirty = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _s7tv_refreshChannelAvatarIfNeeded];
    });
}

// Le provider publie cette notification lorsque l'URL Helix d'un avatar est
// enfin disponible. On résout alors l'objet puis le cache image partagé prend
// en charge le téléchargement et le décodage.
- (void)_s7tv_badgesCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _s7tv_refreshChannelAvatarIfNeeded];
    });
}

- (void)_s7tv_deviceOrientationDidChange:(__unused NSNotification *)notification {
    NSUInteger generation = ++self.pickerOrientationGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.pickerOrientationGeneration ||
            !strongSelf.emotePickerView || strongSelf.emotePickerView.hidden) return;
        UIWindow *hostWindow = strongSelf.emotePickerTextField.window
            ?: strongSelf.emotePickerTextEntryView.window;
        CGFloat width = hostWindow.bounds.size.width;
        if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
        CGFloat targetHeight = strongSelf.pickerSizesPanelVisible
            ? MIN(MAX(strongSelf.sizesPanel.contentHeight, 160.0), kS7TVPickerGridDefaultH)
            : kS7TVPickerGridDefaultH;
        BOOL attachedAsInputView = strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView;
        CGFloat originY = 0;
        if (!attachedAsInputView && strongSelf.emotePickerView.superview == hostWindow) {
            // Le fallback est une vraie sous-vue de la fenêtre, pas un
            // inputView. Conserver son ancrage bas après rotation.
            originY = MAX(hostWindow.safeAreaInsets.top,
                hostWindow.bounds.size.height - targetHeight - 56.0);
        }
        strongSelf.emotePickerView.frame = CGRectMake(0, originY, width, targetHeight);
        [strongSelf _s7tv_relayoutPickerForSize:strongSelf.emotePickerView.bounds.size];
        if (strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView) {
            [strongSelf.emotePickerTextEntryView reloadInputViews];
        }
        if (strongSelf.pickerSizesPanelVisible) {
            [strongSelf _showFakeChatPreviewAboveInputView];
        }
    });
}

// Redécoupe/redimensionne l'avatar en un cercle plein cadre de `diameter`
// points, prêt à poser tel quel sur channelBtn. Nécessaire car channelBtn
// est en layout frame-based (pas d'autolayout) : UIButton ne redimensionne
// PAS automatiquement une image à la taille du bouton dans ce mode — sans ce
// pré-traitement, un avatar Twitch (souvent 300x300) s'afficherait à sa
// taille native et détonnerait la capsule.
- (UIImage *)_s7tv_circularAvatarFromImage:(UIImage *)source diameter:(CGFloat)diameter {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGSize targetSize = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] addClip];
        // Aspect-fill : centre le plus petit côté de la source sur le cadre cible.
        CGFloat scale = MAX(diameter / source.size.width, diameter / source.size.height);
        CGFloat drawW = source.size.width  * scale;
        CGFloat drawH = source.size.height * scale;
        CGRect drawRect = CGRectMake((diameter - drawW) / 2.0, (diameter - drawH) / 2.0, drawW, drawH);
        [source drawInRect:drawRect];
    }];
}

// Diamètre réel de l'avatar dessiné — volontairement plus petit que
// kS7TVPickerFloatSize (28pt, taille du bouton) pour laisser une marge
// cohérente avec le placeholder SF Symbol (14pt) et le logo 7TV du bouton
// voisin (insets 9pt) ; un cercle plein cadre 30pt collait aux bords et
// paraissait trop imposant dans la capsule.
static const CGFloat kS7TVPickerAvatarDiameter = 22.0;

- (void)_s7tv_applyChannelAvatarImage:(UIImage *)image {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn || !image) return;
    UIImage *circular = [self _s7tv_circularAvatarFromImage:image diameter:kS7TVPickerAvatarDiameter];
    if (!circular) return;
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[circular imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
          forState:UIControlStateNormal];
}

// Fallback propre — remet le symbole générique d'origine (mêmes réglages
// qu'à la création de channelBtn).
- (void)_s7tv_resetChannelButtonToPlaceholder {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn) return;
    UIImageSymbolConfiguration *avCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:avCfg]
          forState:UIControlStateNormal];
}

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    // Appel synchrone : on est déjà sur le main thread (tap UIButton).
    // Le dispatch_async précédent créait une race : UIKit pouvait résigner
    // le firstResponder entre le tap et l'exécution du bloc, rendant
    // reloadInputViews inopérant (NO-OP si pas firstResponder).

    // ── Invalider le cache si le TextEntryView n'est plus dans une fenêtre ──
    // Twitch reconstruit sa hiérarchie lors d'un changement de channel.
    // Sans cette invalidation, le BFS est skippé et on utilise une vue orpheline
    // dont isFirstResponder est toujours NO → picker jamais affiché.
    if (self.emotePickerTextEntryView && !self.emotePickerTextEntryView.window) {
        [[SevenTVManager sharedManager] log:@"⚠️ emotePickerTextEntryView orphelin (window=nil) → reset cache"];
        self.emotePickerTextEntryView = nil;
    }

    // ── Trouver le TextEntryView (UITextView de Twitch) via BFS ─────────────
    // C'est _TtC6Twitch...TextEntryView qui reste firstResponder pendant
    // l'inputAccessoryView — exactement comme le picker d'emotes natif Twitch.
    // Clé : dans UIRemoteKeyboardWindow, tapper une emote ne fait PAS résigner
    // le TextEntryView. On reproduit ça en utilisant inputAccessoryView.
    if (!self.emotePickerTextEntryView && chatInputView) {
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:chatInputView];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass([v class]);
            // Chercher la sous-classe TextEntryView de Twitch (UITextView)
            if ([v isKindOfClass:[UITextView class]] && [cn containsString:@"TextEntryView"]) {
                self.emotePickerTextEntryView = (UITextView *)v;
                [[SevenTVManager sharedManager] log:@"✅ TextEntryView trouvé: %@", cn];
                break;
            }
        }
        // Fallback : n'importe quel UITextView dans ChatInputView
        if (!self.emotePickerTextEntryView) {
            NSMutableArray<UIView *> *bfs2 = [NSMutableArray arrayWithObject:chatInputView];
            while (bfs2.count > 0) {
                UIView *v = bfs2.firstObject; [bfs2 removeObjectAtIndex:0];
                [bfs2 addObjectsFromArray:v.subviews];
                if ([v isKindOfClass:[UITextView class]]) {
                    self.emotePickerTextEntryView = (UITextView *)v;
                    [[SevenTVManager sharedManager] log:@"⚠️ TextEntryView fallback UITextView: %@", NSStringFromClass([v class])];
                    break;
                }
            }
        }
    }

    // ── Basculer : picker déjà affiché → retirer ────────────────────────────
    // GUARD : self.emotePickerView doit être non-nil en premier.
    // Sans ce guard, si emotePickerView == nil, la comparaison
    // tv.inputAccessoryView == nil == self.emotePickerView → TRUE au premier tap →
    // _hideEmotePicker est appelé avant même que le picker ait été créé → bug d'ouverture.
    BOOL pickerAttachedAsInputView = self.emotePickerView &&
        self.emotePickerTextEntryView &&
        self.emotePickerTextEntryView.inputView == self.emotePickerView;
    BOOL pickerVisibleAsWindowFallback = self.emotePickerView &&
        self.emotePickerView.window && !self.emotePickerView.hidden &&
        !pickerAttachedAsInputView;
    if (pickerAttachedAsInputView || pickerVisibleAsWindowFallback) {
        [self _hideEmotePicker];
        return;
    }

    self.emotePickerTextField = chatInputView;
    [self _buildAndShowEmotePickerForView:chatInputView];
}

- (void)_hideEmotePicker {
    self.pickerSearchAlertActive = NO;
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Toujours nettoyer inputView, même si tv.window == nil (stream fermé).
            // Ne pas appeler reloadInputViews/resignFirstResponder sans fenêtre →
            // UIKit crashe. On retire juste le custom inputView proprement.
            tv.inputView = nil;
            tv.inputAccessoryView = nil;
            if (tv.window) {
                [tv resignFirstResponder];
                [tv reloadInputViews];
            }
        } @catch (...) {}
    }
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
    [self _hideFakeChatPreview];
}
- (void)cleanupPickerForStreamClose {
    [[SevenTVManager sharedManager] log:@"🔒 cleanupPickerForStreamClose → nettoyage picker"];
    self.pickerSearchAlertActive = NO;
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Pas de window → ne pas toucher au responder chain.
            tv.inputView = nil;
            tv.inputAccessoryView = nil;
        } @catch (...) {}
    }
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
    [self _hideFakeChatPreview];
}

- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView {
    // Twitch garde parfois l'ancienne ChatInputView quelques instants après
    // avoir installé celle de la nouvelle chaîne. Son didMoveToWindow:nil ne
    // doit pas fermer un picker déjà rattaché à la nouvelle vue.
    if (self.emotePickerTextField && self.emotePickerTextField != chatInputView) return;
    [self cleanupPickerForStreamClose];
}

// Kept as a compatibility hook for callers from older picker builds. Sorting
// is now performed from the provider-aware catalogue on every snapshot.
- (void)invalidateSortCache {
    // No legacy emote cache remains to invalidate.
}

- (void)cancelPendingImageLoadsWithCompletion:(void (^)(void))completion {
    [[self pickerImageSession] getAllTasksWithCompletionHandler:
        ^(NSArray<__kindof NSURLSessionTask *> *tasks) {
            for (NSURLSessionTask *task in tasks) [task cancel];
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        }];
}

- (void)favoritesDidChange {
    NSAssert([NSThread isMainThread], @"SevenTVEmotePickerController: main thread uniquement");
    self.pickerCatalogArraysDirty = YES;
    [self _s7tv_reloadCatalogSnapshotReloadCollection:
        (self.emotePickerView && !self.emotePickerView.hidden)];
}

- (SevenTVEmote *)_pickerEmoteForDescriptor:(S7TVEmoteDescriptor *)descriptor {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    return [[S7TVPickerCatalogEmote alloc] initWithDescriptor:descriptor];
}

static NSString *S7TVPickerStableEmoteKey(SevenTVEmote *emote) {
    if (!emote.emoteID.length) return @"";
    if ([emote isKindOfClass:[S7TVPickerCatalogEmote class]]) {
        S7TVEmoteDescriptor *descriptor = [(S7TVPickerCatalogEmote *)emote descriptor];
        if (descriptor.emoteID.length)
            return S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
    }
    return S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, emote.emoteID);
}

// Conserver le tri historique du picker : emotes carrées d'abord, puis par
// aire croissante, et enfin par nom.  Le comparateur peut être utilisé par
// l'onglet provider-aware (avec un tie-breaker provider déterministe) ou par
// l'onglet agrégé.  Dans ce dernier cas, aucun champ provider n'intervient :
// les emotes restent réellement mélangées, même lorsqu'elles ont exactement
// la même taille et le même nom.
static NSComparisonResult S7TVPickerCompareEmotes(id firstObject,
                                                   id secondObject,
                                                   BOOL includeProviderTieBreak) {
    SevenTVEmote *a = (SevenTVEmote *)firstObject;
    SevenTVEmote *b = (SevenTVEmote *)secondObject;
    if (a == b) return NSOrderedSame;

    BOOL aSquare = (a.width > 0 && a.height > 0 && a.width == a.height);
    BOOL bSquare = (b.width > 0 && b.height > 0 && b.width == b.height);
    if (aSquare != bSquare) return aSquare ? NSOrderedAscending : NSOrderedDescending;

    NSInteger aArea = a.width * a.height;
    NSInteger bArea = b.width * b.height;
    if (aArea == 0 && bArea == 0) {
        NSComparisonResult result = [(a.emoteName ?: @"")
            compare:(b.emoteName ?: @"")
            options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (result != NSOrderedSame) return result;
    } else {
        if (aArea == 0) return NSOrderedDescending;
        if (bArea == 0) return NSOrderedAscending;
        if (aArea < bArea) return NSOrderedAscending;
        if (aArea > bArea) return NSOrderedDescending;

        NSString *aName = a.emoteName ?: @"";
        NSString *bName = b.emoteName ?: @"";
        NSUInteger len = MIN(aName.length, bName.length);
        for (NSUInteger i = 0; i < len; i++) {
            unichar ac = [aName characterAtIndex:i];
            unichar bc = [bName characterAtIndex:i];
            if (ac >= 'a' && ac <= 'z') ac -= 32;
            if (bc >= 'a' && bc <= 'z') bc -= 32;
            if (ac < bc) return NSOrderedAscending;
            if (ac > bc) return NSOrderedDescending;
        }
        if (aName.length < bName.length) return NSOrderedAscending;
        if (aName.length > bName.length) return NSOrderedDescending;
    }

    if (includeProviderTieBreak) {
        NSInteger aProvider = -1;
        NSInteger bProvider = -1;
        if ([a isKindOfClass:[S7TVPickerCatalogEmote class]])
            aProvider = [(S7TVPickerCatalogEmote *)a descriptor].provider;
        if ([b isKindOfClass:[S7TVPickerCatalogEmote class]])
            bProvider = [(S7TVPickerCatalogEmote *)b descriptor].provider;
        if (aProvider < bProvider) return NSOrderedAscending;
        if (aProvider > bProvider) return NSOrderedDescending;
    }

    return [(a.emoteID ?: @"") compare:(b.emoteID ?: @"")
        options:NSCaseInsensitiveSearch | NSNumericSearch];
}

static NSComparator S7TVPickerEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return S7TVPickerCompareEmotes(firstObject, secondObject, YES);
};

static NSComparator S7TVPickerMixedEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return S7TVPickerCompareEmotes(firstObject, secondObject, NO);
};

// The provider logos are shipped as 400px square assets. UIKit's button image
// view otherwise lets their opaque mark fill the whole 28pt slot, which makes
// BTTV/FFZ look larger than the star and 7TV symbols. Rasterize them once at
// the intended visual size instead of relying on per-button content insets.
static UIImage *S7TVPickerScaledProviderLogo(UIImage *image, CGFloat pointSize) {
    if (!image || pointSize <= 0) return image;
    CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 2.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(pointSize, pointSize) format:format];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, pointSize, pointSize)];
    }];
    return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)_s7tv_applyProviderCatalogArrays {
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    // Synchroniser les préférences UI (identifiants texte) avec le catalogue
    // (enum numérique) avant de construire la grille.
    NSDictionary *enabledSettings = @{
        @(S7TVEmoteProviderIDSevenTV): @([S7TVEmoteProviderSettings isProviderEnabled:S7TVExternalEmoteProvider7TV]),
        @(S7TVEmoteProviderIDBTTV): @([S7TVEmoteProviderSettings isProviderEnabled:S7TVExternalEmoteProviderBTTV]),
        @(S7TVEmoteProviderIDFFZ): @([S7TVEmoteProviderSettings isProviderEnabled:S7TVExternalEmoteProviderFFZ]),
    };
    if (![catalog.providerEnabled isEqualToDictionary:enabledSettings])
        catalog.providerEnabled = enabledSettings;
    NSArray<NSString *> *priority = [S7TVEmoteProviderSettings providerPriority];
    NSMutableArray *numericPriority = [NSMutableArray array];
    for (NSString *identifier in priority)
        [numericPriority addObject:@(S7TVEmoteProviderFromIdentifier(identifier))];
    if (![catalog.providerPriority isEqualToArray:numericPriority])
        catalog.providerPriority = numericPriority;
    NSMutableDictionary *providerArrays = [NSMutableDictionary dictionary];
    NSMutableDictionary *providerSections = [NSMutableDictionary dictionary];
    NSMutableArray *favorites = [NSMutableArray array];
    NSMutableSet *seenFavoriteKeys = [NSMutableSet set];
    NSMutableSet *currentCatalogKeys = [NSMutableSet set];
    // Lire les favoris une seule fois pour tout le snapshot. L'ancien appel
    // par émote relisait UserDefaults et relançait la migration à chaque
    // élément, ce qui bloquait le thread principal avec plusieurs milliers
    // d'emotes.
    NSSet<NSString *> *favoriteKeySet = [NSSet setWithArray:[catalog favoriteKeysSnapshot]];
    self.pickerFavoriteKeySet = favoriteKeySet;
    BOOL hasSyntheticProviderState = NO;
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        NSMutableArray *items = [NSMutableArray array];
        NSMutableDictionary<NSString *, SevenTVEmote *> *itemsByID = [NSMutableDictionary dictionary];
        NSMutableArray<S7TVPickerDisplaySection *> *displaySections = [NSMutableArray array];
        S7TVEmoteProviderSnapshot *snapshot =
            [catalog snapshotForProvider:(S7TVEmoteProviderID)provider];
        BOOL providerLoading = snapshot.state == S7TVEmoteProviderStateLoading;
        NSString *providerError = snapshot.state == S7TVEmoteProviderStateError
            ? snapshot.errorMessage : nil;
        if (![catalog.providerEnabled[@(provider)] boolValue]) {
            providerArrays[@(provider)] = @[];
            providerSections[@(provider)] = @[];
            continue;
        }
        // The catalog changes Idle -> Loading on its serial state queue. The
        // first picker snapshot can therefore be built in the tiny interval
        // before that queue runs. Expose a local loading section immediately
        // for enabled providers so the first opening never falls back to the
        // old flat 7TV grid (or an apparently empty picker) while the request
        // is being reserved. The real provider snapshot replaces this row as
        // soon as its notification arrives.
        if (snapshot.state == S7TVEmoteProviderStateIdle &&
            snapshot.sections.count == 0) {
            S7TVPickerDisplaySection *initialLoading = [S7TVPickerDisplaySection new];
            initialLoading.provider = (S7TVEmoteProviderID)provider;
            initialLoading.kind = S7TVEmoteSectionKindSet;
            initialLoading.identifier = @"provider-state";
            initialLoading.title = S7TVEmoteProviderName((S7TVEmoteProviderID)provider);
            initialLoading.items = @[];
            initialLoading.loaded = NO;
            initialLoading.loading = YES;
            initialLoading.empty = NO;
            [displaySections addObject:initialLoading];
            hasSyntheticProviderState = YES;
        }
        for (S7TVEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(S7TVEmoteProviderID)provider]) {
            SevenTVEmote *item = [self _pickerEmoteForDescriptor:descriptor];
            if (!item) continue;
            NSString *stableKey = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (stableKey.length) [currentCatalogKeys addObject:stableKey];
            if (!itemsByID[stableKey]) {
                itemsByID[stableKey] = item;
                [items addObject:item];
            }
            if ([favoriteKeySet containsObject:stableKey]) {
                if (![seenFavoriteKeys containsObject:stableKey]) {
                    [seenFavoriteKeys addObject:stableKey];
                    [favorites addObject:item];
                }
            }
        }
        for (S7TVEmoteSection *section in
             [catalog sectionsForProvider:(S7TVEmoteProviderID)provider]) {
            NSMutableArray<SevenTVEmote *> *sectionItems = [NSMutableArray array];
            for (S7TVEmoteDescriptor *descriptor in section.emotes) {
                NSString *stableKey = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
                SevenTVEmote *item = itemsByID[stableKey];
                if (item && ![sectionItems containsObject:item]) [sectionItems addObject:item];
            }
            [sectionItems sortUsingComparator:S7TVPickerEmoteSizeComparator];
            // Loaded empty sections are deliberately hidden. Loading/error
            // sections stay visible so the user can understand what happens
            // and retry without changing tab or scrolling.
            if (!sectionItems.count && section.loaded && !section.loading && !section.errorMessage.length)
                continue;
            S7TVPickerDisplaySection *display = [S7TVPickerDisplaySection new];
            display.provider = section.provider;
            display.kind = section.kind;
            display.identifier = section.identifier ?: @"";
            display.title = section.title.length ? section.title : @"Emotes";
            display.items = sectionItems.copy;
            display.loaded = section.loaded;
            // A provider snapshot can fail while a cached section remains
            // available (for example, a background refresh after the first
            // open). Keep the section visible and expose that state in its
            // header instead of silently hiding the retry affordance.
            display.loading = section.loading || providerLoading;
            display.empty = NO;
            display.errorMessage = section.errorMessage ?: providerError;
            [displaySections addObject:display];
        }
        [items sortUsingComparator:S7TVPickerEmoteSizeComparator];
        providerArrays[@(provider)] = items.copy;
        providerSections[@(provider)] = displaySections.copy;
    }
    // Favorites are global to the installation, but a channel emote from an
    // old channel is not usable in the current chat. Do not hydrate metadata
    // for descriptors that are absent from the current provider snapshots;
    // otherwise the picker would offer an emote that cannot be rendered by
    // anyone in this channel. Current global emotes remain eligible because
    // they are part of the current provider snapshot as well.
    for (S7TVEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        if (![catalog.providerEnabled[@(descriptor.provider)] boolValue]) continue;
        NSString *stableKey = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
        if (![currentCatalogKeys containsObject:stableKey]) continue;
        if (!stableKey.length || [seenFavoriteKeys containsObject:stableKey]) continue;
        SevenTVEmote *item = [self _pickerEmoteForDescriptor:descriptor];
        if (!item) continue;
        [seenFavoriteKeys addObject:stableKey];
        [favorites addObject:item];
    }
    [favorites sortUsingComparator:S7TVPickerEmoteSizeComparator];
    BOOL hasProviderEmotes = NO;
    for (NSArray *items in providerArrays.allValues) {
        if (items.count) { hasProviderEmotes = YES; break; }
    }
    BOOL hasProviderState = hasSyntheticProviderState;
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        S7TVEmoteProviderState state =
            [catalog snapshotForProvider:(S7TVEmoteProviderID)provider].state;
        if (state != S7TVEmoteProviderStateIdle) { hasProviderState = YES; break; }
    }
    // Keep the provider-aware tabs active even when a provider is enabled but
    // currently has no emotes (or is still loading).  Conversely, if the
    // catalogue has not started yet, do not pretend that the legacy 7TV cache
    // is BTTV/FFZ content.
    BOOL hasDisabledProvider = NO;
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        if (![catalog.providerEnabled[@(provider)] boolValue]) {
            hasDisabledProvider = YES;
            break;
        }
    }
    BOOL useProviderCatalog = hasProviderEmotes || hasProviderState || hasDisabledProvider;
    self.pickerProviderEmotes = useProviderCatalog ? providerArrays.copy : @{};
    self.pickerProviderSections = useProviderCatalog ? providerSections.copy : @{};
    self.pickerCatalogFavorites = favorites.copy;
    // Once the provider-aware catalogue is active, keep the legacy favorite
    // array in sync as well.  A favorite removed while the picker is open
    // must not leave a stale item that keeps the Favorites tab selected on
    // the next reload/open.
    if (useProviderCatalog) self.emotePickerFavoriteEmotes = favorites.copy;
    self.pickerCatalogArraysDirty = NO;
    [self _s7tv_normalizeActivePickerTab];
}

- (void)_s7tv_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection {
    NSAssert([NSThread isMainThread], @"Le snapshot du picker touche UIKit");
    UICollectionView *collectionView = self.emoteCollectionView;
    NSString *anchorEmoteKey = nil;
    CGFloat anchorViewportY = 0;
    CGPoint previousOffset = collectionView.contentOffset;
    if (reloadCollection && collectionView && !collectionView.hidden) {
        NSArray<NSIndexPath *> *visible = [collectionView.indexPathsForVisibleItems
            sortedArrayUsingSelector:@selector(compare:)];
        NSIndexPath *anchorPath = visible.firstObject;
        SevenTVEmote *anchorEmote = anchorPath
            ? [self _emoteForIndexPath:anchorPath] : nil;
        UICollectionViewLayoutAttributes *attributes = anchorPath
            ? [collectionView layoutAttributesForItemAtIndexPath:anchorPath] : nil;
        NSString *stableAnchorKey = S7TVPickerStableEmoteKey(anchorEmote);
        if (stableAnchorKey.length && attributes) {
            anchorEmoteKey = [stableAnchorKey copy];
            anchorViewportY = CGRectGetMinY(attributes.frame) - collectionView.contentOffset.y;
        }
    }

    // Les snapshots provider-aware sont la seule source de vérité du picker.
    if (self.pickerCatalogArraysDirty || !self.pickerProviderSections.count)
        [self _s7tv_applyProviderCatalogArrays];
    // The provider snapshots may complete in a different order. During the
    // first opening, re-evaluate the initially empty tab after every snapshot
    // merge so BTTV/FFZ can become visible immediately even if 7TV is slower.
    // The helper is a no-op after a user-selected tab or once a provider has
    // been chosen, so normal refreshes never jump the picker unexpectedly.
    [self _s7tv_selectInitialProviderIfNeeded];
    NSMutableArray *catalogAll = [NSMutableArray array];
    for (NSArray *items in self.pickerProviderEmotes.allValues)
        [catalogAll addObjectsFromArray:items];
    self.emotePickerAllEmotes = catalogAll.count ? catalogAll.copy : @[];
    self.emotePickerEmotes    = self.emotePickerAllEmotes;
    [self _updatePickerArraysForSearch:self.emoteSearchField.text ?: @""];
    if (collectionView) {
        UICollectionViewFlowLayout *flowLayout =
            (UICollectionViewFlowLayout *)collectionView.collectionViewLayout;
        flowLayout.headerReferenceSize = CGSizeZero;
    }
    if (reloadCollection && self.emoteCollectionView) {
        [self _s7tv_deactivateVisiblePickerAnimations];
        [self.emoteCollectionView reloadData];
        [self.emoteCollectionView.collectionViewLayout invalidateLayout];
        [self.emoteCollectionView layoutIfNeeded];

        CGFloat targetY = previousOffset.y;
        if (anchorEmoteKey.length) {
            NSIndexPath *newPath = nil;
            if (self.pickerUsesCatalogSections) {
                for (NSInteger sectionIndex = 0;
                     sectionIndex < (NSInteger)self.pickerDisplaySections.count && !newPath;
                     sectionIndex++) {
                    S7TVPickerDisplaySection *section =
                        self.pickerDisplaySections[(NSUInteger)sectionIndex];
                    NSString *sectionKey = [self _s7tv_displaySectionKey:section];
                    if ([self.pickerCollapsedSections[sectionKey] boolValue]) continue;
                    NSUInteger itemIndex = [section.items indexOfObjectPassingTest:
                        ^BOOL(SevenTVEmote *emote, __unused NSUInteger index, __unused BOOL *stop) {
                            return [S7TVPickerStableEmoteKey(emote)
                                isEqualToString:anchorEmoteKey];
                        }];
                    if (itemIndex != NSNotFound)
                        newPath = [NSIndexPath indexPathForItem:(NSInteger)itemIndex
                                                      inSection:sectionIndex];
                }
            } else {
                NSUInteger newIndex = [self.emotePickerEmotes
                    indexOfObjectPassingTest:^BOOL(SevenTVEmote *emote,
                                                    __unused NSUInteger index,
                                                    __unused BOOL *stop) {
                        return [S7TVPickerStableEmoteKey(emote)
                            isEqualToString:anchorEmoteKey];
                    }];
                if (newIndex != NSNotFound)
                    newPath = [NSIndexPath indexPathForItem:(NSInteger)newIndex inSection:0];
            }
            if (newPath) {
                UICollectionViewLayoutAttributes *attributes =
                    [self.emoteCollectionView layoutAttributesForItemAtIndexPath:newPath];
                if (attributes) targetY = CGRectGetMinY(attributes.frame) - anchorViewportY;
            }
        }
        UIEdgeInsets inset = self.emoteCollectionView.adjustedContentInset;
        CGFloat minimumY = -inset.top;
        CGFloat maximumY = MAX(minimumY,
            self.emoteCollectionView.contentSize.height - self.emoteCollectionView.bounds.size.height +
            inset.bottom);
        CGPoint restoredOffset = self.emoteCollectionView.contentOffset;
        restoredOffset.y = MIN(maximumY, MAX(minimumY, targetY));
        [self.emoteCollectionView setContentOffset:restoredOffset animated:NO];
    }
}

- (void)_s7tv_applyCatalogUpdateNow {
    self.pickerCatalogReloadPending = NO;
    [self _s7tv_reloadCatalogSnapshotReloadCollection:YES];
    if (self.pickerSizesPanelVisible && self->_sizesPanel) {
        [self->_sizesPanel loadRealPreviewAssetsIfNeeded];
    }
    [self.emoteCollectionView layoutIfNeeded];
}

- (void)_s7tv_emoteCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pickerCatalogArraysDirty = YES;
        [self invalidateSortCache];
        if (!self.emotePickerView || self.emotePickerView.hidden) return;
        if (self.pickerScrollInProgress || self.emoteCollectionView.isTracking ||
            self.emoteCollectionView.isDragging || self.emoteCollectionView.isDecelerating) {
            self.pickerCatalogReloadPending = YES;
            return;
        }
        [self _s7tv_applyCatalogUpdateNow];
        [self _s7tv_activateVisiblePickerAnimations];
    });
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // Une notification de catalogue différée pendant un ancien scroll ne doit
    // jamais survivre à la fermeture du picker. L'ouverture reconstruit de
    // toute façon un snapshot exact juste en dessous.
    self.pickerCatalogReloadPending = NO;
    // Réinitialiser l'état logique AVANT le premier snapshot. Sinon une
    // recherche de l'ouverture précédente pouvait restaurer pickerPreSearchTab
    // pendant le passage à une requête vide et écraser le choix ci-dessous.
    self.emoteSearchField.text = @"";
    self.pickerIsSearching = NO;
    // Apply the user's opening choice before any provider notification arrives.
    // When no preference exists, preserve the historical automatic fallback
    // (Favorites, then the first provider with data).
    self.pickerOpeningLocationExplicit = [self _s7tv_applyConfiguredPickerOpeningLocation];
    self.pickerInitialProviderSelectionPending = !self.pickerOpeningLocationExplicit;
    if (!self.pickerOpeningLocationExplicit) {
        self.pickerActiveTab = [S7TVEmoteProviderSettings mixedPickerEnabled]
            ? S7TVPickerTabAll : S7TVPickerTabSevenTV;
    }

    // Build the current cache-first snapshot before scheduling new requests.
    // This ordering is important: a response parser can now run off the state
    // queue, and the first layout never waits for a fresh network response.
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    [self _s7tv_reloadCatalogSnapshotReloadCollection:NO];

    // Déclencher les trois providers après le snapshot initial. Les données
    // en cache sont donc déjà affichées et les notifications remplaceront les
    // cellules sans bloquer l'ouverture, ni demander un scroll/onglet manuel.
    [catalog loadGlobalProviders];
    NSString *channelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    if (channelID.length) [catalog loadChannelProvidersForTwitchID:channelID];

    // ── Choix de l'onglet de départ : Favoris s'il y a au moins un favori
    // (sur la chaîne courante), sinon 7TV/Channel. Revérifié à CHAQUE
    // ouverture — pas seulement quand on était déjà sur Favoris — pour
    // refléter les favoris ajoutés/retirés ou un changement de chaîne
    // depuis la dernière ouverture du picker.
    if (!self.pickerOpeningLocationExplicit &&
        (self.pickerCatalogFavorites.count > 0 || self.emotePickerFavoriteEmotes.count > 0)) {
        self.pickerActiveTab = S7TVPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
    }
    // `_s7tv_reloadCatalogSnapshotReloadCollection:` normally performs this
    // check after merging the snapshots. Calling it once more here covers the
    // synchronous/cache-hit path and keeps the initial selection deterministic
    // even when the picker view did not exist yet.
    [self _s7tv_selectInitialProviderIfNeeded];
    [self _s7tv_normalizeActivePickerTab];
    [self _updatePickerArraysForSearch:@""]; // recalcule emotePickerEmotes pour l'onglet choisi

    // ── Créer le picker si besoin ─────────────────────────────────────
    // Recalcule la taille à chaque ouverture pour s'adapter à l'orientation courante.
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGFloat pickerH = kS7TVPickerGridDefaultH;
    CGRect pickerFrame = CGRectMake(0, 0, screenSz.width, pickerH);
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame];
    } else if (self.pickerSizesPanelVisible) {
        // Le picker existait déjà et avait été laissé sur le panneau des
        // tailles lors de la dernière fermeture → on revient toujours en
        // mode grille à l'ouverture (pas d'animation, c'est un état initial).
        self.pickerSizesPanelVisible = NO;
        self.sizesPanel.panelView.hidden = YES;
        self.emoteCollectionView.hidden = NO;
        self.pickerSearchCapsuleView.hidden = NO;
        self.pickerTabCapsuleView.hidden = NO;
        self.pickerSubcategoryCapsuleView.hidden = NO;
        [self _s7tv_updatePickerTabButtonLayout];
        self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        // Remettre l'icône ⚙️ (pas juste la couleur) — sans ça le bouton
        // gardait visuellement la flèche "retour" du panneau des tailles
        // alors qu'on vient de revenir en mode grille.
        UIImageSymbolConfiguration *resetCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        [self.pickerSizesToggleBtn setImage:[UIImage systemImageNamed:@"textformat.size"
                                                      withConfiguration:resetCfg]
                                    forState:UIControlStateNormal];
    }
    self.emotePickerView.frame = pickerFrame;
    // Revérifie l'avatar de chaîne à CHAQUE ouverture (pas seulement à la
    // création du picker) : si la chaîne a changé pendant que le picker
    // était fermé, c'est le seul filet de sécurité qui ne dépend pas du
    // timing de la notif S7TVChannelJoined. No-op si déjà à jour (cache hit).
    [self _s7tv_refreshChannelAvatarIfNeeded];
    // Repositionne toutes les zones (grille / pastilles flottantes / panneau
    // des tailles) — s'adapte à l'orientation courante et à l'onglet actif,
    // et resynchronise au passage le surlignage des onglets + la capsule
    // sous-choix (utile si l'onglet a changé automatiquement ci-dessus).
    [self _s7tv_relayoutPickerForSize:pickerFrame.size];

    // Reset la recherche
    self.emoteSearchField.text = @"";
    [self _s7tv_updateSearchClearVisibility];
    [self _updatePickerArraysForSearch:@""];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    // À ce stade la collection view n'est pas encore présentée (inputView pas
    // encore assigné/becomeFirstResponder pas encore appelé plus bas) → son
    // contentSize n'est pas garanti calculé, donc un setContentOffset ici peut
    // être un no-op silencieux. On force le layout pour rendre l'appel fiable.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView layoutIfNeeded];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];

    // ── inputView = picker (keyboard-replacement mode) ──────────────────────
    // STRATÉGIE "clavier remplacé" :
    //   inputView remplace entièrement le clavier natif.
    //   Le picker s'affiche EN DESSOUS de la chat bar (comme le picker d'emojis iOS).
    //   Le TextEntryView reste firstResponder → insertText: fonctionne normalement.
    //
    // ORDRE CRITIQUE :
    //   1. inputView = picker     → substitue le clavier par notre picker
    //   2. inputAccessoryView nil → pas de barre accessoire superflue
    //   3. becomeFirstResponder   → affiche l'inputView (picker) à la place du clavier
    //   4. reloadInputViews       → UIKit re-render avec inputView = picker
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        // Étape 1 : le picker DEVIENT le clavier (affiché en dessous de la chat bar)
        self.emotePickerView.hidden = NO;
        tv.inputView = self.emotePickerView;
        tv.inputAccessoryView = nil;
        // Étape 2 : devenir firstResponder → UIKit affiche inputView (notre picker)
        if (!tv.isFirstResponder) {
            [[SevenTVManager sharedManager] log:@"ℹ️ tv pas firstResponder → becomeFirstResponder"];
            [tv becomeFirstResponder];
        }
        // Étape 3 : recharger pour appliquer le nouvel inputView
        [tv reloadInputViews];
        [[SevenTVManager sharedManager] log:@"✅ picker en dessous de la chat bar (inputView) sur %@", NSStringFromClass([tv class])];
        // Étape 4 (Point 1) : ré-imposer l'offset en haut APRÈS la présentation
        // réelle. reloadInputViews déclenche la mise en fenêtre de l'inputView
        // et son propre passage de layout (safe area / adjustedContentInset),
        // qui peut annuler le setContentOffset fait plus haut avant que la vue
        // ne soit dans la fenêtre. On le refait une fois la présentation faite.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.emoteCollectionView) return;
            [strongSelf.emoteCollectionView setContentOffset:CGPointZero animated:NO];
            [strongSelf _s7tv_activateVisiblePickerAnimations];
        });
    } else {
        [[SevenTVManager sharedManager] log:@"⚠️ TextEntryView nil — fallback fenêtre flottante"];
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (keyWindow) {
            CGFloat ph = 280.0;
            self.emotePickerView.frame = CGRectMake(0,
                keyWindow.bounds.size.height - ph - 56,
                keyWindow.bounds.size.width, ph);
            [keyWindow addSubview:self.emotePickerView];
            self.emotePickerView.hidden = NO;
            [self _s7tv_relayoutPickerForSize:self.emotePickerView.bounds.size];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _s7tv_activateVisiblePickerAnimations];
            });
        }
    }
}
- (void)_createEmotePickerViewWithFrame:(CGRect)frame {

    // ── Palette ─────────────────────────────────────────────────────────
    // bgColor = fond de la grille (le plus sombre). cardColor = tout ce qui
    // doit se détacher légèrement du fond (cellules + TOUTES les pastilles
    // flottantes, qui partagent maintenant exactement le même style — plus
    // aucun bandeau opaque qui mange de la place). accent = violet Twitch.
    // Twitch utilise #0E0E10 pour le fond de la chatbox (confirmé par
    // color picker directement sur l'app Twitch) — ce n'est PAS un gris pur,
    // il y a un léger biais bleu, contrairement à ce qu'on avait supposé.
    UIColor *bgColor   = s7tv_pickerBgColor();
    UIColor *cardColor = s7tv_pickerCardColor();
    UIColor *sepColor  = s7tv_pickerSepColor();
    UIColor *textColor = [UIColor whiteColor];
    UIColor *subColor  = [UIColor colorWithWhite:0.55 alpha:1.0];
    UIColor *accent    = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];    // violet Twitch

    // ── Conteneur principal ────────────────────────────────────────────────
    S7TVPickerContainerView *picker =
        [[S7TVPickerContainerView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    self.emotePickerView = picker;

    __weak typeof(self) weakSelf = self;
    __weak S7TVPickerContainerView *weakPicker = picker;
    picker.didAttachToWindow = ^{
        // didMoveToWindow arrive avant la fin du layout du clavier. Le passage
        // suivant de la main queue crée/positionne toutes les cellules visibles,
        // puis réactive leur chargement statique et animé dès la 1re ouverture.
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            S7TVPickerContainerView *strongPicker = weakPicker;
            if (!strongSelf || !strongPicker.window ||
                strongSelf.emotePickerView != strongPicker || strongPicker.hidden) return;
            [strongSelf.emoteCollectionView layoutIfNeeded];
            [strongSelf _s7tv_activateVisiblePickerAnimations];
        });
    };

    // ── Collection View — occupe 100% du picker ─────────────────────────────
    // Plus de bandeau opaque en haut ni en bas : c'est layout.sectionInset qui
    // réserve la place nécessaire pour que les cellules ne passent jamais
    // sous les pastilles flottantes (fiable dès la 1ère ouverture, contrairement
    // à un contentInset + contentOffset manuel qui peut être ignoré tant que
    // le 1er layout de la collection view n'a pas eu lieu).
    CGFloat topInset = kS7TVPickerFloatMargin; // marge minimale seulement — la
    // 1ère ligne démarre quasiment au ras du haut du picker, sous les
    // pastilles flottantes qui sont ajoutées PAR-DESSUS (z-order) juste après :
    // effet recherché = la grille défile VISUELLEMENT DERRIÈRE ces pastilles
    // (comme sur 7TV PC), au lieu de laisser un bandeau vide réservé qui ne
    // fait qu'espacer la grille en dessous d'elles.
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection         = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 3;
    layout.minimumLineSpacing      = 3;
    layout.sectionInset            = UIEdgeInsetsMake(topInset, 6, kS7TVPickerBottomZoneH, 6);
    // Les sous-catégories sont maintenant de vraies capsules flottantes;
    // aucune ligne d'en-tête ne doit être réservée dans la grille.
    layout.headerReferenceSize     = CGSizeZero;

    UICollectionView *cv = [[UICollectionView alloc]
        initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)
 collectionViewLayout:layout];
    cv.backgroundColor        = bgColor;
    cv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cv.dataSource             = (id<UICollectionViewDataSource>)self;
    cv.delegate               = (id<UICollectionViewDelegate>)self;
    cv.alwaysBounceVertical   = YES;
    cv.alwaysBounceHorizontal = NO;
    cv.showsHorizontalScrollIndicator = NO;
    cv.showsVerticalScrollIndicator   = YES;
    // Aucun préchargement implicite : cellFor/willDisplay restent les seules
    // portes d'entrée du pipeline image, donc une emote hors écran ne peut pas
    // être activée par anticipation par UICollectionView.
    if (@available(iOS 10.0, *)) cv.prefetchingEnabled = NO;

    [cv registerClass:[S7TVEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellID];
    [cv registerClass:[S7TVPickerSectionHeaderView class]
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
           withReuseIdentifier:@"S7TVPickerSectionHeader"];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    // ── Capsule provider (flottante, bas gauche) — Favoris / Tous / 7TV / BTTV / FFZ
    // ─────────────────────────────────────────────────────────────────────
    BOOL mixedPicker = [S7TVEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kS7TVPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    CGFloat bottomRowY = frame.size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH
                          - kS7TVPickerFloatGap - kS7TVPickerFloatSize;
    UIView *tabCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kS7TVPickerFloatMargin, bottomRowY, tabCapsuleW, kS7TVPickerFloatSize)];
    tabCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    tabCapsule.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    tabCapsule.clipsToBounds = YES;
    tabCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerTabCapsuleView = tabCapsule;
    [picker addSubview:tabCapsule];

    UIView *tabIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize)];
    tabIndicator.backgroundColor = accent;
    tabIndicator.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    [tabCapsule addSubview:tabIndicator];
    self.pickerTabIndicatorView = tabIndicator;

    NSData *_tabLogoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_tabLogoImg = [[UIImage imageWithData:_tabLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    NSData *_bttvLogoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVBTTVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_bttvLogoImg = [[UIImage imageWithData:_bttvLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    NSData *_ffzLogoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVFFZLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_ffzLogoImg = [[UIImage imageWithData:_ffzLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    // BTTV/FFZ assets are optically a little smaller than the 7TV mark at the
    // same point size. Give them a tiny boost while keeping the capsule and
    // touch target unchanged.
    UIImage *bttvLogo = S7TVPickerScaledProviderLogo(_bttvLogoImg, 16.0);
    UIImage *ffzLogo = S7TVPickerScaledProviderLogo(_ffzLogoImg, 16.0);
    UIImageSymbolConfiguration *providerFallbackCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    UIImage *bttvFallback = [UIImage systemImageNamed:@"b.circle.fill"
                                      withConfiguration:providerFallbackCfg];
    UIImage *ffzFallback = [UIImage systemImageNamed:@"f.circle.fill"
                                      withConfiguration:providerFallbackCfg];

    [self.pickerTabButtons removeAllObjects];

    // Bouton 1 — Favoris
    UIImageSymbolConfiguration *starCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    UIButton *favBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    favBtn.frame = CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    favBtn.tag = S7TVPickerTabFavorites;
    [favBtn setImage:[UIImage systemImageNamed:@"star.fill" withConfiguration:starCfg] forState:UIControlStateNormal];
    [favBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:favBtn];
    [self.pickerTabButtons addObject:favBtn];

    // Bouton 2 — Tous les providers mélangés.
    UIButton *allBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    allBtn.frame = CGRectMake(kS7TVPickerFloatSize, 0,
                              kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    allBtn.tag = S7TVPickerTabAll;
    UIImageSymbolConfiguration *allCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [allBtn setImage:[UIImage systemImageNamed:@"square.stack.3d.up.fill"
                                   withConfiguration:allCfg]
            forState:UIControlStateNormal];
    [allBtn addTarget:self action:@selector(_pickerTabTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:allBtn];
    [self.pickerTabButtons addObject:allBtn];

    // Bouton 3 — 7TV (logo provider).
    UIButton *channelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    channelBtn.frame = CGRectMake(kS7TVPickerFloatSize * 2.0, 0,
                                  kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    channelBtn.tag = S7TVPickerTabSevenTV;
    [channelBtn setImage:_tabLogoImg forState:UIControlStateNormal];
    channelBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [channelBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:channelBtn];
    [self.pickerTabButtons addObject:channelBtn];
    // Boutons 4/5 — BTTV et FFZ. Les logos sont embarqués localement, avec
    // les anciens symboles SF Symbols comme fallback si une image est invalide.
    NSArray *providerButtons = @[
        @[@(S7TVPickerTabBTTV), bttvLogo ?: bttvFallback],
        @[@(S7TVPickerTabFFZ), ffzLogo ?: ffzFallback],
    ];
    for (NSUInteger idx = 0; idx < providerButtons.count; idx++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(kS7TVPickerFloatSize * (idx + 3), 0,
                                  kS7TVPickerFloatSize, kS7TVPickerFloatSize);
        button.tag = [providerButtons[idx][0] integerValue];
        [button setImage:providerButtons[idx][1] forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [button addTarget:self action:@selector(_pickerTabTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [tabCapsule addSubview:button];
        [self.pickerTabButtons addObject:button];
    }

    // ── Capsule sous-catégories (flottante, toujours à gauche, juste au-dessus
    // de la capsule provider) — Channel / Global ───────────────────────────
    // Le picker desktop garde ces deux choix à la même position quel que soit
    // le provider actif. Shared et les sets sont agrégés dans Channel/Global.
    UIView *subcategoryCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kS7TVPickerFloatMargin,
                   bottomRowY - kS7TVPickerSubcategoryGap - kS7TVPickerFloatSize,
                   kS7TVPickerFloatSize * 2.0,
                   kS7TVPickerFloatSize)];
    subcategoryCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    subcategoryCapsule.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    subcategoryCapsule.clipsToBounds = YES;
    subcategoryCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerSubcategoryCapsuleView = subcategoryCapsule;
    [picker addSubview:subcategoryCapsule];

    UIButton *subcategoryChannel = [UIButton buttonWithType:UIButtonTypeSystem];
    subcategoryChannel.frame = CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    subcategoryChannel.tag = 1;
    subcategoryChannel.accessibilityLabel = @"Channel emotes";
    subcategoryChannel.imageView.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *subcategoryIconCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [subcategoryChannel setImage:[UIImage systemImageNamed:@"person.crop.circle.fill"
                                         withConfiguration:subcategoryIconCfg]
                         forState:UIControlStateNormal];
    [subcategoryChannel addTarget:self action:@selector(_pickerSubcategoryTapped:)
                   forControlEvents:UIControlEventTouchUpInside];
    [subcategoryCapsule addSubview:subcategoryChannel];
    self.pickerSubcategoryChannelBtn = subcategoryChannel;

    UIButton *subcategoryGlobal = [UIButton buttonWithType:UIButtonTypeSystem];
    subcategoryGlobal.frame = CGRectMake(kS7TVPickerFloatSize, 0,
                                         kS7TVPickerFloatSize,
                                         kS7TVPickerFloatSize);
    subcategoryGlobal.tag = 2;
    subcategoryGlobal.accessibilityLabel = @"Global emotes";
    subcategoryGlobal.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [subcategoryGlobal addTarget:self action:@selector(_pickerSubcategoryTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    [subcategoryCapsule addSubview:subcategoryGlobal];
    self.pickerSubcategoryGlobalBtn = subcategoryGlobal;
    [self _s7tv_resetChannelButtonToPlaceholder];

    [self _s7tv_updateTabButtonHighlight];

    // ── Capsule tailles/réglages (flottante, bas droite) ────────────────────
    // Même langage visuel que la capsule d'onglets ci-dessus et la capsule
    // sous-choix : un seul fond pilule partagé pour les 2 boutons (au lieu de
    // 2 pastilles séparées avec un espace entre elles), pour qu'ils restent
    // toujours visuellement collés — même taille/forme que les boutons de
    // catégories (Favoris/7TV), qui utilisent déjà ce mécanisme.
    CGFloat toolsCapsuleW = kS7TVPickerFloatSize * 2.0;
    UIView *toolsCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(frame.size.width - kS7TVPickerFloatMargin - toolsCapsuleW, bottomRowY,
                   toolsCapsuleW, kS7TVPickerFloatSize)];
    toolsCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    toolsCapsule.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    toolsCapsule.clipsToBounds = YES;
    toolsCapsule.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.pickerToolsCapsuleView = toolsCapsule;
    [picker addSubview:toolsCapsule];

    // Bouton réglages — slot gauche de la capsule (côté "intérieur", vers le
    // centre). Ouvre le même écran que le bouton flottant 7TV (voir
    // -[SevenTVManager presentSettingsMenu]) ; ferme d'abord le picker (voir
    // -_pickerSettingsTapped) pour ne pas laisser les 2 superposés.
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    UIImageSymbolConfiguration *settingsCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:settingsCfg]
                 forState:UIControlStateNormal];
    settingsBtn.tintColor = subColor;
    [settingsBtn addTarget:self action:@selector(_pickerSettingsTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:settingsBtn];
    self.pickerSettingsBtn = settingsBtn;

    // Bouton tailles — slot droit de la capsule (côté "extérieur", vers le
    // bord de l'écran). Icône "taille de texte" : représente vraiment ce que
    // fait ce bouton (régler des tailles), plutôt qu'un engrenage générique.
    UIButton *gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gearBtn.frame = CGRectMake(kS7TVPickerFloatSize, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    UIImageSymbolConfiguration *gearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [gearBtn setImage:[UIImage systemImageNamed:@"textformat.size" withConfiguration:gearCfg]
             forState:UIControlStateNormal];
    gearBtn.tintColor = subColor;
    [gearBtn addTarget:self action:@selector(emotePickerSizesToggleTapped)
      forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:gearBtn];
    self.pickerSizesToggleBtn = gearBtn;

    // ── Capsule de recherche (flottante, tout en bas, pleine largeur) ──────
    CGFloat searchY = frame.size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH;
    UIView *searchCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kS7TVPickerFloatMargin, searchY, frame.size.width - kS7TVPickerFloatMargin * 2, kS7TVPickerSearchH)];
    searchCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    searchCapsule.layer.cornerRadius = kS7TVPickerSearchH / 2.0;
    searchCapsule.clipsToBounds = YES;
    searchCapsule.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.pickerSearchCapsuleView = searchCapsule;
    [picker addSubview:searchCapsule];

    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(0, 0, searchCapsule.bounds.size.width, kS7TVPickerSearchH)];
    search.placeholder     = L(@"placeholder_search_picker");
    search.font            = [UIFont systemFontOfSize:13];
    search.returnKeyType   = UIReturnKeyDone;
    search.clearButtonMode = UITextFieldViewModeNever; // remplacé par notre propre bouton croix (point 4)
    search.backgroundColor = [UIColor clearColor];
    search.textColor       = textColor;
    search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:L(@"placeholder_search_picker")
            attributes:@{NSForegroundColorAttributeName: subColor}];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Icône loupe intégrée à gauche du champ
    UIImageSymbolConfiguration *searchCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    UIImageView *searchIcon = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:searchCfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    searchIcon.tintColor = subColor;
    searchIcon.contentMode = UIViewContentModeCenter;
    UIView *searchLeftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 20)];
    searchIcon.frame = CGRectMake(12, 0, 16, 20);
    [searchLeftView addSubview:searchIcon];
    search.leftView = searchLeftView;
    search.leftViewMode = UITextFieldViewModeAlways;

    // Petite croix à droite pour vider le champ d'un tap (point 4) — visible
    // uniquement si le champ contient du texte, voir _s7tv_updateSearchClearVisibility.
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(0, 0, 28, kS7TVPickerSearchH);
    UIImageSymbolConfiguration *clearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [clearBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:clearCfg]
              forState:UIControlStateNormal];
    clearBtn.tintColor = subColor;
    clearBtn.hidden = YES;
    [clearBtn addTarget:self action:@selector(_pickerSearchClearTapped)
       forControlEvents:UIControlEventTouchUpInside];
    self.pickerSearchClearBtn = clearBtn;
    UIView *searchRightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, kS7TVPickerSearchH)];
    clearBtn.frame = CGRectMake(2, 0, 28, kS7TVPickerSearchH);
    [searchRightView addSubview:clearBtn];
    search.rightView = searchRightView;
    search.rightViewMode = UITextFieldViewModeAlways;

    // Déléguer à self pour intercepter le focus et éviter que le picker se ferme
    search.delegate = (id<UITextFieldDelegate>)self;
    [search addTarget:self action:@selector(_emoteSearchChanged:)
     forControlEvents:UIControlEventEditingChanged];
    self.emoteSearchField = search;
    [searchCapsule addSubview:search];

    // ── Panneau des tailles ─────────────────────────────────────────────
    // Délégué à SevenTVPickerSizesPanel (composant enfant) : construit ses
    // propres lignes/sliders/previews dans `picker`, avec le style visuel
    // résolu ci-dessus. Le picker garde la main sur l'affichage/masquage et
    // le redimensionnement (voir -emotePickerSizesToggleTapped).
    [self.sizesPanel buildInView:picker
                            frame:frame
                          bgColor:bgColor
                        textColor:textColor
                         subColor:subColor
                         sepColor:sepColor
                           accent:accent
                        cardColor:cardColor];

    // Point 3 — VRAIE CAUSE du bug "pas de bouton pour fermer/revenir" :
    // sizesPanel est un UIScrollView OPAQUE plein cadre ajouté APRÈS
    // toolsCapsule ci-dessus → il la recouvre visuellement ET intercepte ses
    // taps, même avec hidden=NO. On la repasse au premier plan explicitement
    // pour qu'elle reste visible et cliquable par-dessus le panneau des
    // tailles (bringSubviewToFront sur la capsule suffit pour les 2 boutons
    // qu'elle contient).
    [picker bringSubviewToFront:tabCapsule];
    [picker bringSubviewToFront:subcategoryCapsule];
    [picker bringSubviewToFront:toolsCapsule];

    // NOTE: pas d'addSubview ici — la vue est attachée via inputView (remplace le clavier)
}

// Pastille flottante ronde générique (fond carte translucide) — utilisée pour
// fermer et ⚙️. Les capsules (sous-choix, onglets, recherche) sont construites
// à la main car elles contiennent plusieurs éléments, mais partagent le même style.
- (UIButton *)_s7tv_makeFloatingPillWithFrame:(CGRect)frame cardColor:(UIColor *)cardColor {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    btn.layer.cornerRadius = frame.size.height / 2.0;
    btn.clipsToBounds = YES;
    return btn;
}

// ── Barre d'onglets — helpers ────────────────────────────────────────────

// Keep the selected tab valid when a provider is disabled from Settings or
// when the catalogue is still in its legacy-only fallback state.  This is
// intentionally independent from button creation so it also works while the
// picker is already visible and a settings notification arrives.
// Le mode mixte ne remplace pas les boutons à chaque ouverture : les cinq
// boutons sont créés une seule fois, puis la capsule est compactée et les
// boutons incompatibles sont masqués. Cela évite de recréer des vues pendant
// qu'UIKit présente l'inputView et garde les cibles/tags stables.
- (void)_s7tv_updatePickerTabButtonLayout {
    if (!self.pickerTabCapsuleView || !self.pickerTabButtons.count) return;

    BOOL mixedMode = [S7TVEmoteProviderSettings mixedPickerEnabled];
    NSArray<NSNumber *> *visibleTags = mixedMode
        ? @[@(S7TVPickerTabFavorites), @(S7TVPickerTabAll)]
        : @[@(S7TVPickerTabFavorites), @(S7TVPickerTabSevenTV),
            @(S7TVPickerTabBTTV), @(S7TVPickerTabFFZ)];
    NSInteger slot = 0;
    for (UIButton *button in self.pickerTabButtons) {
        BOOL visible = [visibleTags containsObject:@(button.tag)];
        button.hidden = !visible;
        if (!visible) continue;
        button.frame = CGRectMake(kS7TVPickerFloatSize * slot, 0,
                                  kS7TVPickerFloatSize, kS7TVPickerFloatSize);
        slot++;
    }

    CGRect capsuleFrame = self.pickerTabCapsuleView.frame;
    capsuleFrame.size.width = kS7TVPickerFloatSize * slot;
    self.pickerTabCapsuleView.frame = capsuleFrame;
}

- (void)_s7tv_normalizeActivePickerTab {
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    BOOL mixedMode = [S7TVEmoteProviderSettings mixedPickerEnabled];
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    BOOL (^available)(NSInteger) = ^BOOL(NSInteger tab) {
        // Do not keep an empty Favorites tab selected after the last favorite
        // is removed.  Returning NO here lets the configured provider order
        // choose a useful tab (including a provider that is still loading).
        if (tab == S7TVPickerTabFavorites)
            return self.pickerCatalogFavorites.count > 0 ||
                   self.emotePickerFavoriteEmotes.count > 0;
        if (tab == S7TVPickerTabAll) {
            if (!mixedMode) return NO;
            if (!providerMode && !self.pickerOpeningLocationExplicit &&
                !self.emotePickerAllEmotes.count) return NO;
            for (NSNumber *provider in [self _s7tv_providerIDsInPriorityOrder]) {
                if ([catalog.providerEnabled[provider] boolValue]) return YES;
            }
            return NO;
        }
        if (mixedMode || ![self _s7tv_pickerTabIsProvider:tab]) return NO;
        NSInteger provider = tab == S7TVPickerTabSevenTV
            ? S7TVEmoteProviderIDSevenTV
            : (tab == S7TVPickerTabBTTV ? S7TVEmoteProviderIDBTTV : S7TVEmoteProviderIDFFZ);
        if (![catalog.providerEnabled[@(provider)] boolValue]) return NO;
        // A legacy cache only contains 7TV. Do not let those objects appear
        // under BTTV/FFZ while their own catalogue is still idle.
        return providerMode || self.pickerOpeningLocationExplicit ||
            provider == S7TVEmoteProviderIDSevenTV;
    };

    if (available(self.pickerActiveTab)) return;
    NSInteger fallback = S7TVPickerTabFavorites;
    if (!(self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count)) {
        if (mixedMode && available(S7TVPickerTabAll)) {
            fallback = S7TVPickerTabAll;
        } else {
        for (NSString *identifier in [S7TVEmoteProviderSettings providerPriority]) {
            S7TVExternalEmoteProvider provider = S7TVEmoteProviderFromIdentifier(identifier);
            NSInteger tab = provider == S7TVExternalEmoteProvider7TV
                ? S7TVPickerTabSevenTV
                : (provider == S7TVExternalEmoteProviderBTTV
                   ? S7TVPickerTabBTTV : S7TVPickerTabFFZ);
            if (available(tab)) { fallback = tab; break; }
        }
        }
    }
    self.pickerActiveTab = fallback;
}

- (BOOL)_s7tv_selectInitialProviderIfNeeded {
    if (self.pickerOpeningLocationExplicit) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    if (!self.pickerInitialProviderSelectionPending || self.pickerIsSearching)
        return NO;

    // Favorites are installation-wide and can arrive from the metadata
    // sidecar slightly after the provider snapshots. If they become
    // available during the first open, keep the same initial-open rule and
    // move to Favorites once; subsequent catalog refreshes never steal the
    // user's tab because the pending flag is cleared here.
    if (self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count) {
        BOOL changed = self.pickerActiveTab != S7TVPickerTabFavorites;
        self.pickerActiveTab = S7TVPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // In aggregate mode there is no provider-specific button to select. Once
    // the provider-aware snapshot (or the legacy 7TV fallback) exists, keep
    // the initial tab on Tous instead of briefly showing 7TV and then hiding
    // that button when the compact tab layout is applied.
    if ([S7TVEmoteProviderSettings mixedPickerEnabled] &&
        (self.pickerProviderEmotes.count || self.emotePickerAllEmotes.count)) {
        BOOL changed = self.pickerActiveTab != S7TVPickerTabAll;
        self.pickerActiveTab = S7TVPickerTabAll;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // A legacy-only snapshot has no provider dictionary. It is already the
    // valid 7TV fallback, so there is nothing to select automatically.
    if (!self.pickerProviderEmotes.count) {
        if (self.emotePickerAllEmotes.count || self.emotePickerEmotes.count)
            self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    if (self.pickerActiveTab == S7TVPickerTabAll) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    S7TVEmoteProviderID activeProvider = [self _s7tv_providerForPickerTab:
        self.pickerActiveTab];
    NSArray *activeItems = self.pickerProviderEmotes[@(activeProvider)] ?: @[];
    if (activeItems.count) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    // Providers are ordered by the user's collision priority. Only a
    // provider with actual emotes is eligible; loading/error placeholders do
    // not count, so a later notification can still select the first one that
    // becomes usable without relying on a tab switch or a scroll.
    for (NSString *identifier in [S7TVEmoteProviderSettings providerPriority]) {
        S7TVExternalEmoteProvider provider = S7TVEmoteProviderFromIdentifier(identifier);
        NSArray *items = self.pickerProviderEmotes[@((S7TVEmoteProviderID)provider)] ?: @[];
        if (!items.count) continue;
        NSInteger tab = provider == S7TVExternalEmoteProvider7TV
            ? S7TVPickerTabSevenTV
            : (provider == S7TVExternalEmoteProviderBTTV
               ? S7TVPickerTabBTTV : S7TVPickerTabFFZ);
        BOOL changed = self.pickerActiveTab != tab;
        self.pickerActiveTab = tab;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }
    return NO;
}

// Met à jour la teinte/opacité de chaque icône + déplace la pastille
// violette derrière l'onglet actif. La capsule contient soit Favoris + Tous,
// soit Favoris + les trois providers selon le réglage choisi.
- (void)_s7tv_updateTabButtonHighlight {
    [self _s7tv_updatePickerTabButtonLayout];
    [self _s7tv_normalizeActivePickerTab];
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    UIColor *activeTint   = [UIColor whiteColor];
    UIColor *inactiveTint = [UIColor colorWithWhite:0.55 alpha:1.0];
    for (UIButton *btn in self.pickerTabButtons) {
        BOOL isActive = (btn.tag == self.pickerActiveTab);
        if ([self _s7tv_pickerTabIsProvider:btn.tag]) {
            NSInteger provider = btn.tag == S7TVPickerTabSevenTV
                ? S7TVEmoteProviderIDSevenTV
                : (btn.tag == S7TVPickerTabBTTV ? S7TVEmoteProviderIDBTTV : S7TVEmoteProviderIDFFZ);
            BOOL enabled = [catalog.providerEnabled[@(provider)] boolValue] &&
                (providerMode || provider == S7TVEmoteProviderIDSevenTV);
            btn.enabled = enabled;
            if (!enabled) { btn.alpha = 0.25; continue; }
            // A button can be disabled and re-enabled while the picker stays
            // visible (settings notification). Reset alpha before applying
            // the active/inactive tint so it does not remain ghosted.
            btn.alpha = 1.0;
        }
        if ([self _s7tv_pickerTabIsProvider:btn.tag]) {
            // Les logos provider sont des images non-template : l'opacité
            // reproduit l'état actif/inactif de la preview pour les trois.
            btn.alpha = isActive ? 1.0 : 0.55;
        } else {
            btn.tintColor = isActive ? activeTint : inactiveTint;
        }
    }
    for (UIButton *btn in self.pickerTabButtons) {
        if (btn.tag == self.pickerActiveTab) {
            self.pickerTabIndicatorView.frame = btn.frame;
            break;
        }
    }
    [self _s7tv_updateSubcategoryCapsule];
}

// Recalcule et applique les frames de toutes les zones du picker (grille /
// pastilles flottantes / panneau des tailles) — appelé à chaque ouverture,
// changement d'orientation, et changement d'onglet. Plus de dock : tout est
// flottant, ancré aux 4 coins/bords via des calculs explicites (fiable même
// quand la hauteur du picker change, ex. panneau des tailles — point 5).
- (void)_s7tv_relayoutPickerForSize:(CGSize)size {
    if (!self.emotePickerView) return;

    self.emoteCollectionView.frame = CGRectMake(0, 0, size.width, size.height);

    CGFloat bottomRowY = size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH
                          - kS7TVPickerFloatGap - kS7TVPickerFloatSize;
    BOOL mixedPicker = [S7TVEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kS7TVPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    self.pickerTabCapsuleView.frame = CGRectMake(kS7TVPickerFloatMargin, bottomRowY, tabCapsuleW, kS7TVPickerFloatSize);
    self.pickerSubcategoryCapsuleView.frame = CGRectMake(
        kS7TVPickerFloatMargin,
        bottomRowY - kS7TVPickerSubcategoryGap - kS7TVPickerFloatSize,
        kS7TVPickerFloatSize * 2.0,
        kS7TVPickerFloatSize);
    // Dans la grille, la capsule reste en bas à droite. Dans les réglages,
    // elle rejoint la ligne des trois catégories en haut à droite. Seule sa
    // position change : son apparence reste exactement celle du picker.
    CGFloat toolsCapsuleW = kS7TVPickerFloatSize * 2.0;
    CGFloat toolsX = size.width - kS7TVPickerFloatMargin - toolsCapsuleW;
    CGFloat toolsY = self.pickerSizesPanelVisible ? 9.0 : bottomRowY;
    self.pickerToolsCapsuleView.frame = CGRectMake(toolsX, toolsY, toolsCapsuleW, kS7TVPickerFloatSize);
    [self _s7tv_updateTabButtonHighlight];

    CGFloat searchY = size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH;
    self.pickerSearchCapsuleView.frame = CGRectMake(kS7TVPickerFloatMargin, searchY,
                                                      size.width - kS7TVPickerFloatMargin * 2, kS7TVPickerSearchH);
    self.emoteSearchField.frame = CGRectMake(0, 0, self.pickerSearchCapsuleView.bounds.size.width, kS7TVPickerSearchH);

    self.sizesPanel.panelView.frame = CGRectMake(0, 0, size.width, size.height);
}

// ── Onglets — sélection ───────────────────────────────────────────────────

- (void)_pickerTabTapped:(UIButton *)sender {
    // A tap is an explicit user choice, even when it targets the already
    // selected (currently empty/loading) provider. Do not let a late network
    // response switch away from that choice during the first-open window.
    self.pickerInitialProviderSelectionPending = NO;
    self.pickerOpeningLocationExplicit = NO;
    if (self.pickerActiveTab == sender.tag) {
        [self _s7tv_persistLastPickerLocation];
        [self _s7tv_updateSubcategoryCapsule];
        return; // déjà actif
    }
    self.pickerActiveTab = sender.tag;
    [self _s7tv_persistLastPickerLocation];
    [self _s7tv_updateTabButtonHighlight];

    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// Tap sur la petite croix à droite du champ de recherche (point 4) — vide le
// champ et relance la recherche immédiatement, sans passer par l'alerte.
- (void)_pickerSearchClearTapped {
    self.emoteSearchField.text = @"";
    self.pickerSearchClearBtn.hidden = YES;
    [self _applySearchQuery:@""];
}

// Retourne l'array d'emotes correspondant à l'onglet actif.
- (NSArray<SevenTVEmote *> *)_s7tv_currentTabEmotes {
    if (self.pickerProviderEmotes.count > 0) {
        if (self.pickerActiveTab == S7TVPickerTabFavorites)
            return self.pickerCatalogFavorites ?: @[];
        if (self.pickerActiveTab == S7TVPickerTabAll) {
            NSMutableArray<SevenTVEmote *> *all = [NSMutableArray array];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (NSNumber *provider in [self _s7tv_providerIDsInPriorityOrder]) {
                for (SevenTVEmote *item in self.pickerProviderEmotes[provider] ?: @[]) {
                    NSString *key = S7TVPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [all addObject:item];
                }
            }
            // The aggregate tab must not impose a provider order.  Keep the
            // historical dimensions/name ordering, but leave provider ties to
            // the source order instead of grouping 7TV, BTTV and FFZ.
            [all sortUsingComparator:S7TVPickerMixedEmoteSizeComparator];
            return all.copy;
        }
        NSInteger provider = self.pickerActiveTab == S7TVPickerTabSevenTV
            ? S7TVEmoteProviderIDSevenTV
            : (self.pickerActiveTab == S7TVPickerTabBTTV
               ? S7TVEmoteProviderIDBTTV : S7TVEmoteProviderIDFFZ);
        return self.pickerProviderEmotes[@(provider)] ?: @[];
    }
    switch (self.pickerActiveTab) {
        case S7TVPickerTabAll:
            return self.emotePickerAllEmotes ?: @[];
        case S7TVPickerTabSevenTV:
            // The legacy cache is a combined 7TV catalogue.  It is the only
            // valid fallback while the provider-aware catalogue is idle.
            return self.emotePickerAllEmotes ?: self.emotePickerChannelEmotes;
        case S7TVPickerTabBTTV:
        case S7TVPickerTabFFZ:
            // Never show legacy 7TV objects under another provider's tab.
            return @[];
        case S7TVPickerTabFavorites:
        default:
            return self.emotePickerFavoriteEmotes;
    }
}

// ── Recherche ──────────────────────────────────────────────────────────────

// ── Méthode centrale de filtrage : met à jour les 2 sections ──────────────

- (void)_updatePickerArraysForSearch:(NSString *)query {
    // Wrapper de compat : appelé partout où on ne veut PAS que l'onglet actif
    // soit ré-imposé automatiquement (ouverture du picker, tap manuel sur un
    // onglet/sous-choix, toggle favori). Seul _applySearchQuery: (déclenché
    // par une vraie frappe dans le champ de recherche) doit pouvoir changer
    // l'onglet tout seul → voir _updatePickerArraysForSearch:autoSelectTab:.
    [self _updatePickerArraysForSearch:query autoSelectTab:NO];
}

- (S7TVEmoteProviderID)_s7tv_providerForPickerTab:(NSInteger)tab {
    switch (tab) {
        case S7TVPickerTabBTTV: return S7TVEmoteProviderIDBTTV;
        case S7TVPickerTabFFZ: return S7TVEmoteProviderIDFFZ;
        case S7TVPickerTabSevenTV:
        default: return S7TVEmoteProviderIDSevenTV;
    }
}

- (BOOL)_s7tv_pickerTabIsProvider:(NSInteger)tab {
    return tab == S7TVPickerTabSevenTV || tab == S7TVPickerTabBTTV ||
        tab == S7TVPickerTabFFZ;
}

- (NSArray<NSNumber *> *)_s7tv_providerIDsInPriorityOrder {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:3];
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    for (NSString *identifier in [S7TVEmoteProviderSettings providerPriority]) {
        S7TVExternalEmoteProvider external = S7TVEmoteProviderFromIdentifier(identifier);
        S7TVEmoteProviderID provider = (S7TVEmoteProviderID)external;
        if (provider < S7TVEmoteProviderIDSevenTV || provider > S7TVEmoteProviderIDFFZ ||
            ![catalog.providerEnabled[@(provider)] boolValue] ||
            [result containsObject:@(provider)]) continue;
        [result addObject:@(provider)];
    }
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        if ([catalog.providerEnabled[@(provider)] boolValue] &&
            ![result containsObject:@(provider)])
            [result addObject:@(provider)];
    }
    return result.copy;
}

- (void)_s7tv_persistLastPickerLocation {
    NSString *location = nil;
    NSString *subcategory = nil;
    NSNumber *selectionKey = nil;
    if (self.pickerActiveTab == S7TVPickerTabFavorites) {
        location = @"favorites";
    } else if (self.pickerActiveTab == S7TVPickerTabAll) {
        subcategory = self.pickerSubcategoryByProvider[@(-1)] ?: @"channel";
        location = [NSString stringWithFormat:@"all:%@", subcategory];
    } else if ([self _s7tv_pickerTabIsProvider:self.pickerActiveTab]) {
        S7TVEmoteProviderID provider = [self _s7tv_providerForPickerTab:self.pickerActiveTab];
        selectionKey = @(provider);
        subcategory = self.pickerSubcategoryByProvider[selectionKey] ?: @"channel";
        location = [NSString stringWithFormat:@"%@:%@",
                    S7TVEmoteProviderKey(provider), subcategory];
    }
    if (location.length)
        [S7TVEmoteProviderSettings setLastPickerLocation:location];
}

- (BOOL)_s7tv_applyConfiguredPickerOpeningLocation {
    NSString *mode = [S7TVEmoteProviderSettings pickerOpeningMode];
    if (!mode.length) return NO;
    self.pickerOpeningLocationExplicit = YES;
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeFavorites]) {
        self.pickerActiveTab = S7TVPickerTabFavorites;
        return YES;
    }
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeSevenTVChannel] ||
        [mode isEqualToString:S7TVEmotePickerOpeningModeBTTVChannel] ||
        [mode isEqualToString:S7TVEmotePickerOpeningModeFFZChannel]) {
        if ([S7TVEmoteProviderSettings mixedPickerEnabled]) {
            // A provider-specific opening choice has no visible button in
            // aggregate mode. Preserve its Channel intent by opening the
            // corresponding virtual All tab instead of falling back to
            // Favorites or a hidden provider.
            self.pickerActiveTab = S7TVPickerTabAll;
            self.pickerSubcategoryByProvider[@(-1)] = @"channel";
            return YES;
        }
        NSInteger tab = [mode hasPrefix:@"7tv"] ? S7TVPickerTabSevenTV
            : ([mode hasPrefix:@"bttv"] ? S7TVPickerTabBTTV : S7TVPickerTabFFZ);
        self.pickerActiveTab = tab;
        S7TVEmoteProviderID provider = [self _s7tv_providerForPickerTab:tab];
        self.pickerSubcategoryByProvider[@(provider)] = @"channel";
        return YES;
    }
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeLastUsed]) {
        NSString *location = [S7TVEmoteProviderSettings lastPickerLocation];
        if ([location isEqualToString:@"favorites"]) {
            self.pickerActiveTab = S7TVPickerTabFavorites;
            return YES;
        }
        NSArray<NSString *> *parts = [location componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            NSString *providerKey = parts[0].lowercaseString;
            NSString *subcategory = [parts[1].lowercaseString isEqualToString:@"global"]
                ? @"global" : @"channel";
            if ([providerKey isEqualToString:@"all"]) {
                self.pickerActiveTab = S7TVPickerTabAll;
                self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                return YES;
            }
            S7TVEmoteProviderID provider =
                (S7TVEmoteProviderID)S7TVEmoteProviderFromIdentifier(providerKey);
            if (provider >= S7TVEmoteProviderIDSevenTV && provider <= S7TVEmoteProviderIDFFZ) {
                if ([S7TVEmoteProviderSettings mixedPickerEnabled]) {
                    self.pickerActiveTab = S7TVPickerTabAll;
                    self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                    return YES;
                }
                self.pickerActiveTab = provider == S7TVEmoteProviderIDSevenTV
                    ? S7TVPickerTabSevenTV
                    : (provider == S7TVEmoteProviderIDBTTV ? S7TVPickerTabBTTV : S7TVPickerTabFFZ);
                self.pickerSubcategoryByProvider[@(provider)] = subcategory;
                return YES;
            }
        }
        // « Dernier menu » sans historique reprend les favoris si présents,
        // puis laisse la sélection initiale choisir le provider prioritaire.
        self.pickerOpeningLocationExplicit = NO;
        return NO;
    }
    self.pickerOpeningLocationExplicit = NO;
    return NO;
}

- (NSString *)_s7tv_displaySectionKey:(S7TVPickerDisplaySection *)section {
    NSInteger provider = section.provider;
    return [NSString stringWithFormat:@"%ld:%@", (long)provider,
            section.identifier ?: @""];
}

- (BOOL)_s7tv_sectionIsChannel:(S7TVPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    // BTTV shared emotes and provider sets are still channel-scoped in the
    // picker. Keeping them in this bucket prevents the desktop catalogue from
    // silently disappearing behind an unexposed "Shared"/"Set" category.
    if (section.kind == S7TVEmoteSectionKindChannel ||
        section.kind == S7TVEmoteSectionKindShared) return YES;
    if (section.kind == S7TVEmoteSectionKindSet &&
        ![section.identifier.lowercaseString hasPrefix:@"global-set:"]) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"channel"] || [identifier containsString:@"channel"];
}

- (BOOL)_s7tv_sectionIsGlobal:(S7TVPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    if (section.kind == S7TVEmoteSectionKindGlobal) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"global"] || [identifier containsString:@"global"];
}

- (void)_s7tv_updateSubcategoryCapsule {
    UIView *capsule = self.pickerSubcategoryCapsuleView;
    UIButton *channelButton = self.pickerSubcategoryChannelBtn;
    UIButton *globalButton = self.pickerSubcategoryGlobalBtn;
    if (!capsule || !channelButton || !globalButton) return;

    BOOL providerTab = [self _s7tv_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == S7TVPickerTabAll;
    BOOL visible = (providerTab || allTab) && !self.pickerSizesPanelVisible;
    capsule.hidden = !visible;
    if (!visible) return;

    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _s7tv_providerForPickerTab:self.pickerActiveTab]);
    BOOL hasChannel = NO;
    BOOL hasGlobal = NO;
    NSArray<NSNumber *> *providers = allTab
        ? [self _s7tv_providerIDsInPriorityOrder]
        : @[selectionKey];
    for (NSNumber *providerNumber in providers) {
        for (S7TVPickerDisplaySection *section in
             self.pickerProviderSections[providerNumber] ?: @[]) {
            BOOL usable = section.items.count > 0 || !section.loaded ||
                section.loading || section.errorMessage.length;
            if (!usable) continue;
            hasChannel |= [self _s7tv_sectionIsChannel:section];
            hasGlobal |= [self _s7tv_sectionIsGlobal:section];
        }
    }

    // Keep the Channel capsule visible even when the current broadcaster has
    // no channel emotes. The avatar identifies the active channel and must not
    // disappear merely because its section is empty; only the action itself is
    // disabled until a channel section becomes available.
    channelButton.hidden = NO;
    channelButton.enabled = hasChannel;
    globalButton.hidden = !hasGlobal;
    globalButton.enabled = hasGlobal;

    NSString *selected = self.pickerSubcategoryByProvider[selectionKey];
    // Older builds persisted a dynamic section ID (for example `set:abc`).
    // Normalize it to the stable two-value state used by the aggregate view.
    BOOL selectedIsChannel = [selected isEqualToString:@"channel"] ||
        (selected.length && ![selected isEqualToString:@"global"] && hasChannel &&
         ![selected.lowercaseString containsString:@"global"]);
    BOOL selectedIsGlobal = [selected isEqualToString:@"global"] ||
        (selected.length && [selected.lowercaseString containsString:@"global"] && hasGlobal);
    selectedIsChannel &= hasChannel;
    selectedIsGlobal &= hasGlobal;
    if (!selectedIsChannel && !selectedIsGlobal) {
        // Channel is the default when it contains emotes; otherwise Global.
        // A loading Channel placeholder must not hide a Global section that is
        // already available during the first opening.
        BOOL channelHasItems = NO;
        BOOL globalHasItems = NO;
        for (NSNumber *providerNumber in providers) {
            for (S7TVPickerDisplaySection *section in
                 self.pickerProviderSections[providerNumber] ?: @[]) {
                if ([self _s7tv_sectionIsChannel:section] && section.items.count) channelHasItems = YES;
                if ([self _s7tv_sectionIsGlobal:section] && section.items.count) globalHasItems = YES;
            }
        }
        selected = channelHasItems ? @"channel" :
            (globalHasItems ? @"global" : (hasChannel ? @"channel" : @"global"));
        if (selected.length) self.pickerSubcategoryByProvider[selectionKey] = selected;
        selectedIsChannel = [selected isEqualToString:@"channel"] && hasChannel;
        selectedIsGlobal = [selected isEqualToString:@"global"] && hasGlobal;
    }

    UIColor *accent = s7tv_pickerAccentColor();
    UIColor *inactive = [UIColor colorWithWhite:1.0 alpha:0.58];
    channelButton.backgroundColor = selectedIsChannel ? accent : UIColor.clearColor;
    globalButton.backgroundColor = selectedIsGlobal ? accent : UIColor.clearColor;
    channelButton.tintColor = selectedIsChannel ? UIColor.whiteColor : inactive;
    globalButton.tintColor = selectedIsGlobal ? UIColor.whiteColor : inactive;
    channelButton.alpha = hasChannel ? (selectedIsChannel ? 1.0 : 0.55) : 0.25;
    globalButton.alpha = hasGlobal ? (selectedIsGlobal ? 1.0 : 0.55) : 0.25;

    // Le bouton Global reprend le logo du provider actif. Pour l'agrégat «
    // Tous », une petite mappemonde indique que plusieurs sources sont mêlées.
    UIImage *providerLogo = nil;
    if (!allTab) {
        for (UIButton *providerButton in self.pickerTabButtons) {
            if (providerButton.tag == self.pickerActiveTab) {
                providerLogo = [providerButton imageForState:UIControlStateNormal];
                break;
            }
        }
    }
    if (!providerLogo) {
        UIImageSymbolConfiguration *globalCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        providerLogo = [UIImage systemImageNamed:@"globe" withConfiguration:globalCfg];
    }
    [globalButton setImage:[providerLogo imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                  forState:UIControlStateNormal];
    globalButton.imageView.contentMode = UIViewContentModeScaleAspectFit;

    // L'avatar représente la chaîne, pas le provider : il reste donc visible
    // quand on passe de 7TV à BTTV ou FFZ.
    [self _s7tv_refreshChannelAvatarIfNeeded];
}

- (void)_pickerSubcategoryTapped:(UIButton *)sender {
    BOOL providerTab = [self _s7tv_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == S7TVPickerTabAll;
    if ((!providerTab && !allTab) || sender.hidden || !sender.enabled) return;
    BOOL wantChannel = sender == self.pickerSubcategoryChannelBtn;
    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _s7tv_providerForPickerTab:self.pickerActiveTab]);
    self.pickerSubcategoryByProvider[selectionKey] = wantChannel ? @"channel" : @"global";
    [self _s7tv_persistLastPickerLocation];
    [self _s7tv_updateSubcategoryCapsule];
    NSString *query = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:query];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

- (void)_s7tv_rebuildCatalogDisplaySectionsForQueryLegacy:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;

    // Searching temporarily expands matching sections. Preserve the user's
    // explicit open/collapsed choices and restore them when the query is
    // cleared, instead of leaving every section expanded after a search.
    BOOL hasQuery = lower.length > 0;
    if (hasQuery && !self.pickerCatalogSearchActive) {
        self.pickerCollapseStateBeforeSearch = self.pickerCollapsedSections.copy ?: @{};
        self.pickerCatalogSearchActive = YES;
    } else if (!hasQuery && self.pickerCatalogSearchActive) {
        self.pickerCollapsedSections =
            [self.pickerCollapseStateBeforeSearch mutableCopy] ?: [NSMutableDictionary dictionary];
        self.pickerCollapseStateBeforeSearch = nil;
        self.pickerCatalogSearchActive = NO;
    }

    NSMutableArray<S7TVPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == S7TVPickerTabFavorites) {
        if (self.pickerCatalogFavorites.count) {
            NSMutableArray *items = [NSMutableArray array];
            for (SevenTVEmote *item in self.pickerCatalogFavorites) {
                S7TVEmoteDescriptor *descriptor = [item isKindOfClass:[S7TVPickerCatalogEmote class]]
                    ? [(S7TVPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // A query may filter every favorite out. Do not leave an empty
            // collapsible header behind; an empty-state header is only useful
            // for a provider that is still loading or failed, not for a
            // successfully filtered Favorites tab.
            if (items.count) {
                S7TVPickerDisplaySection *favorites = [S7TVPickerDisplaySection new];
                favorites.provider = S7TVEmoteProviderIDSevenTV;
                favorites.kind = S7TVEmoteSectionKindFavorites;
                favorites.identifier = @"favorites";
                favorites.title = @"Favorites";
                favorites.items = items.copy;
                favorites.loaded = YES;
                [display addObject:favorites];
            }
        }
    } else {
        S7TVEmoteProviderID provider = [self _s7tv_providerForPickerTab:self.pickerActiveTab];
        NSArray<S7TVPickerDisplaySection *> *source = self.pickerProviderSections[@(provider)];
        S7TVEmoteProviderSnapshot *snapshot = [[S7TVEmoteCatalog sharedCatalog]
            snapshotForProvider:provider];

        // Before a provider has produced its first section, expose a compact
        // state header instead of an empty grid. This removes the old “scroll
        // to make it load” behaviour and gives errors an explicit retry path.
        if (!source.count && (snapshot.state == S7TVEmoteProviderStateLoading ||
                              snapshot.state == S7TVEmoteProviderStateLoaded ||
                              snapshot.state == S7TVEmoteProviderStateError)) {
            S7TVPickerDisplaySection *stateSection = [S7TVPickerDisplaySection new];
            stateSection.provider = provider;
            stateSection.kind = S7TVEmoteSectionKindSet;
            stateSection.identifier = @"provider-state";
            stateSection.title = S7TVEmoteProviderName(provider);
            stateSection.items = @[];
            stateSection.loaded = snapshot.state == S7TVEmoteProviderStateLoaded;
            stateSection.loading = snapshot.state == S7TVEmoteProviderStateLoading;
            stateSection.empty = snapshot.state == S7TVEmoteProviderStateLoaded;
            stateSection.errorMessage = snapshot.errorMessage;
            [display addObject:stateSection];
        }

        for (S7TVPickerDisplaySection *original in source) {
            NSMutableArray *items = [NSMutableArray array];
            for (SevenTVEmote *item in original.items) {
                S7TVEmoteDescriptor *descriptor = [item isKindOfClass:[S7TVPickerCatalogEmote class]]
                    ? [(S7TVPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // A loaded section with no search result is hidden; a loading or
            // failed section remains as a visible header for feedback/retry.
            // An undispatched optional set is a real, expandable section even
            // though it has no emotes yet. Only hide a section after a
            // successful empty response; placeholders must stay visible so
            // the user can expand them to trigger their request.
            if (!items.count && original.loaded && !original.loading && !original.errorMessage.length) continue;
            S7TVPickerDisplaySection *current = [S7TVPickerDisplaySection new];
            current.provider = original.provider;
            current.kind = original.kind;
            current.identifier = original.identifier;
            current.title = original.title;
            current.items = items.copy;
            current.loaded = original.loaded;
            current.loading = original.loading;
            current.empty = original.empty;
            current.errorMessage = original.errorMessage;
            [display addObject:current];
        }
    }

    // Preserve explicit collapse choices. New sections default to one open
    // section (or all matching sections during a search) and the remainder
    // collapsed, mirroring the desktop picker without hiding their headers.
    BOOL openedOne = NO;
    for (S7TVPickerDisplaySection *section in display) {
        NSString *key = [self _s7tv_displaySectionKey:section];
        BOOL canDisplayContent = section.items.count > 0 ||
            section.loading || section.errorMessage.length ||
            section.kind == S7TVEmoteSectionKindSet;
        if (lower.length) {
            self.pickerCollapsedSections[key] = @NO;
        } else if (!self.pickerCollapsedSections[key]) {
            BOOL shouldCollapse = openedOne && canDisplayContent;
            self.pickerCollapsedSections[key] = @(shouldCollapse);
        }
        if (canDisplayContent && ![self.pickerCollapsedSections[key] boolValue])
            openedOne = YES;
    }

    self.pickerDisplaySections = display.copy;
    self.pickerUsesCatalogSections = display.count > 0;
    // The active provider can switch between a sectioned catalog and the
    // legacy flat fallback.  Keep the flow layout in sync immediately; if
    // this is left to picker creation/reload only, switching tabs can leave a
    // stale 30pt header (or hide real section headers with a zero height).
    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) {
        flowLayout.headerReferenceSize = CGSizeZero;
    }
    // Keep the legacy flat array synchronized with the sections that are
    // actually open. It is still used by the anchor/search compatibility code,
    // while the collection data source reads the section arrays directly.
    NSMutableArray<SevenTVEmote *> *visibleItems = [NSMutableArray array];
    for (S7TVPickerDisplaySection *section in display) {
        NSString *key = [self _s7tv_displaySectionKey:section];
        if (![self.pickerCollapsedSections[key] boolValue])
            [visibleItems addObjectsFromArray:section.items ?: @[]];
    }
    self.emotePickerEmotes = visibleItems.copy;
}

// Version utilisée par la présentation actuelle : une seule catégorie
// Channel/Global est rendue à la fois. Les sections natives Shared et Set sont
// volontairement fusionnées dans leur portée (Channel ou Global), ce qui
// garantit que le picker affiche tout ce que les providers ont fourni.
- (void)_s7tv_rebuildCatalogDisplaySectionsForQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;
    NSMutableArray<S7TVPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == S7TVPickerTabFavorites) {
        NSMutableArray<SevenTVEmote *> *items = [NSMutableArray array];
        for (SevenTVEmote *item in self.pickerCatalogFavorites ?: @[]) {
            S7TVEmoteDescriptor *descriptor = [item isKindOfClass:[S7TVPickerCatalogEmote class]]
                ? [(S7TVPickerCatalogEmote *)item descriptor] : nil;
            BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
            if (!matches && descriptor) {
                for (NSString *alias in descriptor.aliases) {
                    if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                }
            }
            if (matches) [items addObject:item];
        }
        [items sortUsingComparator:S7TVPickerEmoteSizeComparator];
        if (items.count) {
            S7TVPickerDisplaySection *favorites = [S7TVPickerDisplaySection new];
            favorites.provider = S7TVEmoteProviderIDSevenTV;
            favorites.kind = S7TVEmoteSectionKindFavorites;
            favorites.identifier = @"favorites";
            favorites.title = @"Favorites";
            favorites.items = items.copy;
            favorites.loaded = YES;
            [display addObject:favorites];
        }
    } else {
        BOOL allTab = self.pickerActiveTab == S7TVPickerTabAll;
        S7TVEmoteProviderID provider = allTab
            ? S7TVEmoteProviderIDSevenTV
            : [self _s7tv_providerForPickerTab:self.pickerActiveTab];
        NSNumber *selectionKey = allTab ? @(-1) : @(provider);
        NSArray<NSNumber *> *providers = allTab
            ? [self _s7tv_providerIDsInPriorityOrder]
            : @[@(provider)];
        NSMutableArray<SevenTVEmote *> *channelItems = [NSMutableArray array];
        NSMutableArray<SevenTVEmote *> *globalItems = [NSMutableArray array];
        NSMutableSet<NSString *> *seenChannel = [NSMutableSet set];
        NSMutableSet<NSString *> *seenGlobal = [NSMutableSet set];
        BOOL channelLoading = NO, globalLoading = NO;
        BOOL channelError = NO, globalError = NO;
        NSString *channelErrorMessage = nil, *globalErrorMessage = nil;
        BOOL anyProviderLoading = NO, anyProviderError = NO;
        NSString *anyProviderErrorMessage = nil;

        BOOL (^matchesQuery)(SevenTVEmote *) = ^BOOL(SevenTVEmote *item) {
            if (!lower.length) return YES;
            S7TVEmoteDescriptor *descriptor = [item isKindOfClass:[S7TVPickerCatalogEmote class]]
                ? [(S7TVPickerCatalogEmote *)item descriptor] : nil;
            if ([item.emoteName.lowercaseString containsString:lower]) return YES;
            for (NSString *alias in descriptor.aliases)
                if ([alias.lowercaseString containsString:lower]) return YES;
            return NO;
        };

        for (NSNumber *providerNumber in providers) {
            NSArray<S7TVPickerDisplaySection *> *source =
                self.pickerProviderSections[providerNumber] ?: @[];
            for (S7TVPickerDisplaySection *original in source) {
                BOOL isChannel = [self _s7tv_sectionIsChannel:original];
                BOOL isGlobal = [self _s7tv_sectionIsGlobal:original];
                if (!isChannel && !isGlobal) {
                    if (original.loading) anyProviderLoading = YES;
                    if (original.errorMessage.length) {
                        anyProviderError = YES;
                        if (!anyProviderErrorMessage.length) anyProviderErrorMessage = original.errorMessage;
                    }
                    continue;
                }
                BOOL pending = !original.loaded || original.loading;
                if (isChannel) {
                    channelLoading |= pending;
                    if (original.errorMessage.length) {
                        channelError = YES;
                        if (!channelErrorMessage.length) channelErrorMessage = original.errorMessage;
                    }
                } else {
                    globalLoading |= pending;
                    if (original.errorMessage.length) {
                        globalError = YES;
                        if (!globalErrorMessage.length) globalErrorMessage = original.errorMessage;
                    }
                }
                NSMutableArray *target = isChannel ? channelItems : globalItems;
                NSMutableSet *seen = isChannel ? seenChannel : seenGlobal;
                for (SevenTVEmote *item in original.items ?: @[]) {
                    if (!matchesQuery(item)) continue;
                    NSString *key = S7TVPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [target addObject:item];
                }
            }
        }

        // Each virtual Channel/Global section is the union of all enabled
        // providers. Sort only after the union so BTTV/FFZ/7TV entries are
        // interleaved by the same dimensions-first order as the old picker,
        // instead of appearing as three provider-sized blocks.
        [channelItems sortUsingComparator:S7TVPickerMixedEmoteSizeComparator];
        [globalItems sortUsingComparator:S7TVPickerMixedEmoteSizeComparator];

        BOOL (^addCategory)(BOOL, NSArray<SevenTVEmote *> *, BOOL, BOOL, NSString *, NSString *) =
            ^BOOL(BOOL isChannel, NSArray<SevenTVEmote *> *items, BOOL loading,
                  BOOL hasError, NSString *errorMessage, NSString *identifier) {
            if (!items.count && !loading && !hasError) return NO;
            S7TVPickerDisplaySection *section = [S7TVPickerDisplaySection new];
            section.provider = provider;
            section.kind = isChannel ? S7TVEmoteSectionKindChannel : S7TVEmoteSectionKindGlobal;
            section.identifier = identifier;
            section.title = isChannel ? @"Channel Emotes" : @"Global Emotes";
            section.items = items ?: @[];
            section.loaded = !loading;
            section.loading = loading;
            section.empty = !items.count && !hasError && !loading;
            section.errorMessage = errorMessage;
            [display addObject:section];
            return YES;
        };
        BOOL hasChannelCategory = addCategory(YES, channelItems, channelLoading,
            channelError, channelErrorMessage, allTab ? @"all-channel" : @"channel");
        BOOL hasGlobalCategory = addCategory(NO, globalItems, globalLoading,
            globalError, globalErrorMessage, allTab ? @"all-global" : @"global");

        // Une seule catégorie reste ouverte. Par défaut Channel est choisie
        // si elle contient des emotes, sinon Global ; un choix utilisateur est
        // conservé par provider (ou par l'agrégat pour « Tous »).
        NSString *selectedID = [self.pickerSubcategoryByProvider[selectionKey] lowercaseString];
        BOOL wantsChannel = [selectedID isEqualToString:@"channel"] ||
            (selectedID.length && ![selectedID containsString:@"global"] && hasChannelCategory);
        BOOL wantsGlobal = [selectedID isEqualToString:@"global"] ||
            ([selectedID containsString:@"global"] && hasGlobalCategory);
        S7TVPickerDisplaySection *selected = nil;
        S7TVPickerDisplaySection *channelSection = display.firstObject;
        S7TVPickerDisplaySection *globalSection = display.count > 1 ? display[1] :
            (hasGlobalCategory ? display.firstObject : nil);
        if (wantsChannel && hasChannelCategory) selected = channelSection;
        if (wantsGlobal && hasGlobalCategory) selected = globalSection;
        if (!selected && !lower.length) {
            if (channelItems.count) selected = hasChannelCategory ? channelSection : nil;
            if (!selected && globalItems.count) selected = hasGlobalCategory ? globalSection : nil;
            if (!selected && hasChannelCategory) selected = channelSection;
            if (!selected && hasGlobalCategory) selected = globalSection;
        }
        if (!selected && lower.length) {
            if (channelItems.count && hasChannelCategory) selected = channelSection;
            else if (globalItems.count && hasGlobalCategory) selected = globalSection;
        }
        if (selected) {
            if (!lower.length)
                self.pickerSubcategoryByProvider[selectionKey] =
                    [selected.identifier hasSuffix:@"global"] ? @"global" : @"channel";
            // The two virtual sections are ordered Channel then Global. Keep
            // only the selected one visible, as in the original picker.
            [display removeAllObjects];
            [display addObject:selected];
        } else if (anyProviderLoading || anyProviderError || !providers.count) {
            S7TVPickerDisplaySection *state = [S7TVPickerDisplaySection new];
            state.provider = provider;
            state.kind = S7TVEmoteSectionKindSet;
            state.identifier = allTab ? @"all-provider-state" : @"provider-state";
            state.title = allTab ? @"All providers" : S7TVEmoteProviderName(provider);
            state.items = @[];
            state.loading = anyProviderLoading;
            state.loaded = !anyProviderLoading;
            state.empty = !anyProviderLoading && !anyProviderError;
            state.errorMessage = anyProviderErrorMessage;
            [display addObject:state];
        }
    }

    self.pickerDisplaySections = display.copy;
    self.pickerUsesCatalogSections = display.count > 0;
    [self.pickerCollapsedSections removeAllObjects];
    for (S7TVPickerDisplaySection *section in display)
        self.pickerCollapsedSections[[self _s7tv_displaySectionKey:section]] = @NO;

    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) flowLayout.headerReferenceSize = CGSizeZero;

    self.emotePickerEmotes = display.count ? display.firstObject.items : @[];
    [self _s7tv_updateSubcategoryCapsule];
}

- (void)_updatePickerArraysForSearch:(NSString *)query autoSelectTab:(BOOL)autoSelectTab {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    // The provider-aware catalogue is the only source of picker data.  Keep
    // this path active even while every provider is still loading: the
    // catalogue publishes explicit loading/error sections, so opening the
    // picker never falls back to a stale 7TV-only dictionary.
    {
        NSMutableArray *providerItems = [NSMutableArray array];
        if (self.pickerActiveTab == S7TVPickerTabFavorites) {
            [providerItems addObjectsFromArray:self.pickerCatalogFavorites ?: @[]];
        } else if (self.pickerActiveTab == S7TVPickerTabAll) {
            // The aggregate list is already dimension/name ordered by its
            // mixed comparator.  Do not re-group it by the collision priority;
            // every `(provider,id)` entry remains visible in this tab.
            [providerItems addObjectsFromArray:[self _s7tv_currentTabEmotes]];
        } else {
            NSInteger provider = self.pickerActiveTab == S7TVPickerTabSevenTV
                ? S7TVEmoteProviderIDSevenTV
                : (self.pickerActiveTab == S7TVPickerTabBTTV
                   ? S7TVEmoteProviderIDBTTV : S7TVEmoteProviderIDFFZ);
            [providerItems addObjectsFromArray:self.pickerProviderEmotes[@(provider)] ?: @[]];
        }
        NSMutableArray *filtered = [NSMutableArray array];
        for (SevenTVEmote *item in providerItems) {
            S7TVEmoteDescriptor *descriptor = [item isKindOfClass:[S7TVPickerCatalogEmote class]]
                ? [(S7TVPickerCatalogEmote *)item descriptor] : nil;
            BOOL matches = !q.length || [item.emoteName.lowercaseString containsString:lower];
            if (!matches && descriptor) {
                for (NSString *alias in descriptor.aliases) {
                    if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                }
            }
            if (matches)
                [filtered addObject:item];
        }
        if (q.length > 0) {
            [filtered sortUsingComparator:^NSComparisonResult(SevenTVEmote *a, SevenTVEmote *b) {
                NSInteger ra = [self _s7tv_relevanceRankForEmoteName:a.emoteName query:lower];
                NSInteger rb = [self _s7tv_relevanceRankForEmoteName:b.emoteName query:lower];
                return ra == rb ? NSOrderedSame : (ra < rb ? NSOrderedAscending : NSOrderedDescending);
            }];
        }
        if (self.pickerActiveTab == S7TVPickerTabFavorites)
            self.emotePickerFavoriteEmotes = filtered;
        else {
            self.emotePickerChannelEmotes = filtered;
            self.emotePickerGlobalEmotes = filtered;
        }
        self.emotePickerOtherEmotes = filtered;
        [self _s7tv_rebuildCatalogDisplaySectionsForQuery:q];
        [self _s7tv_updateTabButtonHighlight];
        return;
    }
}

// Rang de pertinence d'un nom d'emote pour une requête (déjà en minuscules,
// déjà garantie non-vide par l'appelant) : 0 = correspondance exacte,
// 1 = commence par la recherche, 2 = la contient ailleurs.
- (NSInteger)_s7tv_relevanceRankForEmoteName:(NSString *)name query:(NSString *)lowerQuery {
    NSString *lowerName = name.lowercaseString;
    if ([lowerName isEqualToString:lowerQuery]) return 0;
    if ([lowerName hasPrefix:lowerQuery]) return 1;
    return 2;
}

// ── UITextFieldDelegate — intercepte le focus du champ de recherche ────────
//
// PROBLÈME : quand emoteSearchField appelle becomeFirstResponder, UIKit
// résigne automatiquement l'ancien firstResponder (TextEntryView).
// Cela retire l'inputView du TextEntryView → le picker disparaît et
// les frappes suivantes vont directement dans la chatbox de Twitch.
//
// SOLUTION : bloquer becomeFirstResponder sur le champ intégré (retourner NO
// dans le delegate), puis afficher un UIAlertController avec un champ texte.
// Son clavier natif emprunte temporairement le first responder au TextEntryView
// Twitch ; pickerSearchAlertActive empêche de prendre ce transfert pour une
// fermeture. À la validation, on recharge la grille puis on restaure le picker.
//
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField != self.emoteSearchField) return YES;
    if (self.pickerSearchAlertActive) return NO;

    // Capturer la query courante pour pré-remplir l'alerte
    NSString *currentQuery = textField.text ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_search_emote_title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *alertField) {
        alertField.placeholder   = L(@"placeholder_emote_name");
        alertField.text          = currentQuery;
        alertField.returnKeyType = UIReturnKeySearch;
        alertField.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Sélectionner tout le texte existant pour faciliter la réécriture
        if (currentQuery.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [alertField selectAll:nil];
            });
        }
    }];

    UIAlertAction *searchAction = [UIAlertAction
        actionWithTitle:L(@"action_search")
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
        NSString *query = alert.textFields.firstObject.text ?: @"";
        // Mettre à jour le texte du champ affiché pour feedback visuel
        textField.text = query;
        if (query.length == 0) {
            UIColor *subColor = [UIColor colorWithWhite:0.55 alpha:1.0];
            textField.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:L(@"placeholder_search_picker")
                    attributes:@{NSForegroundColorAttributeName: subColor}];
        }
        [self _applySearchQuery:query];
        // Reste du clignotement : même en callant _restorePickerFocus pile au
        // bon moment, il y avait ENCORE 2 animations qui s'enchaînaient l'une
        // après l'autre — la fermeture de l'alerte (+ son clavier natif qui
        // se replie), PUIS la réapparition du picker une fois celle-ci finie.
        // iOS ne permet pas de vraiment les superposer (un seul firstResponder
        // à la fois pendant une transition modale). En désactivant l'animation
        // de fermeture de l'alerte (dismiss instantané), il ne reste plus que
        // l'animation de réapparition du picker — un seul mouvement au lieu
        // de deux qui se suivent.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:L(@"common_cancel")
                  style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *action) {
        // Même chose à l'annulation (voir searchAction ci-dessus) : dismiss
        // sans animation pour ne garder qu'une seule transition visible.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    [alert addAction:searchAction];
    [alert addAction:cancelAction];
    alert.preferredAction = searchAction;

    // Présenter depuis le topViewController (le picker est inputView, pas un VC).
    // Le flag doit être levé AVANT la présentation : le champ de l'alerte va
    // immédiatement faire résigner le TextEntryView de Twitch.
    UIViewController *presenter = [self topViewController];
    if (!presenter) return NO;
    [self _s7tv_deactivateVisiblePickerAnimations];
    self.pickerSearchAlertActive = YES;
    [presenter presentViewController:alert animated:YES completion:nil];

    // Bloquer le becomeFirstResponder → le picker reste affiché
    return NO;
}

- (void)_applySearchQuery:(NSString *)query {
    // Seul point d'entrée où l'onglet peut être choisi automatiquement
    // (nouvelle frappe = nouveaux résultats à faire découvrir).
    [self _updatePickerArraysForSearch:query autoSelectTab:YES];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    [self _s7tv_updateSearchClearVisibility];
}

// Affiche/masque la petite croix à droite du champ de recherche selon que le
// champ contient du texte ou non (point 4).
- (void)_s7tv_updateSearchClearVisibility {
    self.pickerSearchClearBtn.hidden = (self.emoteSearchField.text.length == 0);
}

// Restaure le picker après fermeture de l'UIAlertController — appelée depuis
// le completion du dismiss (voir searchAction/cancelAction ci-dessus), donc
// exactement quand l'alerte a fini de disparaître. La fermeture de l'alerte
// déclenche parfois un resign/become du firstResponder sur le TextEntryView,
// ce qui efface son inputView et affiche le clavier natif un court instant :
// on réassigne inputView = picker et on force reloadInputViews pour reprendre
// la main immédiatement.
- (void)_restorePickerFocus {
    UITextView *tv = self.emotePickerTextEntryView;
    UIView *pickerView = self.emotePickerView;
    if (!pickerView) return;
    if (tv && tv.window) {
        // Réassigner l'inputView au cas où il aurait été effacé.
        tv.inputView = pickerView;
        tv.inputAccessoryView = nil;
        pickerView.hidden = NO;
        if (!tv.isFirstResponder) [tv becomeFirstResponder];
        [tv reloadInputViews];
    } else if (pickerView.window) {
        // Mode fenêtre flottante : aucun TextEntryView n'existe à restaurer,
        // mais la recherche a tout de même coupé les observers d'animation.
        pickerView.hidden = NO;
    } else {
        return;
    }
    // reloadData pendant la recherche coupe volontairement les anciens
    // observateurs d'animation. Une fois l'inputView réellement remonté,
    // réactiver immédiatement les seules cellules désormais visibles.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf _s7tv_activateVisiblePickerAnimations];
    });
}

// Appelé par UIControlEventEditingChanged (cas où le champ est modifié
// programmatiquement — en pratique bloqué par textFieldShouldBeginEditing:)
- (void)_emoteSearchChanged:(UITextField *)field {
    [self _applySearchQuery:field.text ?: @""];
}



// ── Long press → toggle favori ─────────────────────────────────────────────

- (void)_handleLongPressOnPicker:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    CGPoint pt = [gr locationInView:self.emoteCollectionView];
    NSIndexPath *ip = [self.emoteCollectionView indexPathForItemAtPoint:pt];
    if (!ip) return;

    SevenTVEmote *emote = [self _emoteForIndexPath:ip];
    if (!emote) return;

    S7TVEmoteDescriptor *descriptor = [emote isKindOfClass:[S7TVPickerCatalogEmote class]]
        ? [(S7TVPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFav = descriptor
        ? [[S7TVEmoteCatalog sharedCatalog] isEmoteFavorited:descriptor]
        : [[SevenTVManager sharedManager] isEmoteFavorited:emote.emoteID];
    if (descriptor && descriptor.provider == S7TVEmoteProviderIDSevenTV) {
        // Keep the legacy manager's in-memory 7TV set in sync as well as the
        // provider-qualified catalogue.  The existing Favorites settings
        // screen still reads that manager snapshot until it is migrated.
        [[SevenTVManager sharedManager] setEmote:descriptor.emoteID favorited:!isFav];
    } else if (descriptor) {
        [[S7TVEmoteCatalog sharedCatalog] setEmote:descriptor favorited:!isFav];
    } else {
        [[SevenTVManager sharedManager] setEmote:emote.emoteID favorited:!isFav];
    }
    if (isFav) {
        [[SevenTVManager sharedManager] log:@"💔 Favori retiré : %@", emote.emoteName];
    } else {
        [[SevenTVManager sharedManager] log:@"⭐ Favori ajouté : %@", emote.emoteName];
    }

    // Haptique
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // setEmote:favorited: publie déjà l'unique mise à jour via
    // s7tv_notifyFavoritesChanged -> favoritesDidChange. Un second reload ici
    // annulait/recréait immédiatement les animations visibles.
}

// ── Helper : emote à partir d'un indexPath ─────────────────────────────────
// Section unique désormais (voir _s7tv_currentTabEmotes) — plus de sections
// favoris/channel/globales empilées, l'onglet actif choisit l'array affiché.

- (SevenTVEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (self.pickerUsesCatalogSections) {
        if (ip.section < 0 || ip.section >= (NSInteger)self.pickerDisplaySections.count) return nil;
        S7TVPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)ip.section];
        NSString *key = [self _s7tv_displaySectionKey:section];
        if ([self.pickerCollapsedSections[key] boolValue]) return nil;
        if (ip.item < 0 || ip.item >= (NSInteger)section.items.count) return nil;
        return section.items[(NSUInteger)ip.item];
    }
    if (ip.section != 0) return nil;
    if ((NSUInteger)ip.item < self.emotePickerEmotes.count)
        return self.emotePickerEmotes[(NSUInteger)ip.item];
    return nil;
}

// ── Faux chat flottant (preview live du panneau ⚙️ Tailles) ────────────────
// Le panneau des tailles est le panelView de SevenTVPickerSizesPanel, qui EST
// l'inputView du clavier (voir -_buildAndShowEmotePickerForView:) : impossible
// d'y positionner un aperçu librement au milieu de l'écran. Solution : un
// conteneur séparé ajouté directement à la key window, même technique que le
// fallback "TextEntryView nil" plus haut (-toggleEmotePickerForChatInputView:)
// qui fait déjà un addSubview: direct sur keyWindow.
// Créé une seule fois ; repositionné/affiché à chaque ouverture du panneau
// (l'orientation ou la hauteur de chatInputView peuvent avoir changé).
- (UIView *)_ensureFakeChatPreviewContainer {
    if (self.pickerFakeChatPreviewView) return self.pickerFakeChatPreviewView;

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = S7TVOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.09 alpha:0.97];
    container.layer.cornerRadius = 12;
    container.clipsToBounds = YES;
    container.hidden = YES;
    // La preview est interactive et ce conteneur opaque doit aussi absorber
    // toute touche dans ses marges : aucun tap ne traverse vers le vrai chat,
    // le lecteur ou une autre vue Twitch placée derrière.
    container.userInteractionEnabled = YES;

    SevenTVChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:chatView];

    self.pickerFakeChatPreviewView = container;
    return container;
}

// Affiche le conteneur, positionné juste au-dessus de chatInputView
// (self.emotePickerTextField), ~50% de la hauteur d'écran, pleine largeur —
// peut recouvrir le vrai chat (comportement validé). Repris à chaque appel
// pour suivre l'orientation/la position courante de chatInputView plutôt que
// figé à la première ouverture.
- (void)_showFakeChatPreviewAboveInputView {
    UIView *inputRoot = self.emotePickerTextField;
    UIWindow *keyWindow = inputRoot.window;
    if (!keyWindow) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    if (!keyWindow) {
        [[SevenTVManager sharedManager] log:@"⚠️ _showFakeChatPreviewAboveInputView: pas de key window"];
        return;
    }

    CGFloat width     = keyWindow.bounds.size.width;
    static const CGFloat kFakeChatInset = 8.0; // même valeur que CGRectInset(container.bounds, 8, 8) plus bas

    CGFloat inputTopY = keyWindow.bounds.size.height;
    if (inputRoot) {
        CGRect inputFrameInWindow = [inputRoot convertRect:inputRoot.bounds toView:keyWindow];
        inputTopY = inputFrameInWindow.origin.y;
    }
    CGFloat safeTop = keyWindow.safeAreaInsets.top;
    CGFloat availableHeight = MAX(0.0, inputTopY - safeTop);
    CGFloat maxHeight = MIN(keyWindow.bounds.size.height * 0.5, availableHeight);
    if (maxHeight < 80.0) {
        [self _hideFakeChatPreview];
        return;
    }

    UIView *container = [self _ensureFakeChatPreviewContainer];
    SevenTVChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.renderingSuspended = NO;
    if (container.superview != keyWindow) {
        [container removeFromSuperview];
        [keyWindow addSubview:container];
    }

    // ── Hauteur réelle du contenu ────────────────────────────────────────
    // Avant, la hauteur était fixée à 50% de l'écran quel que soit le
    // nombre de messages factices → gros vide en dessous du dernier message.
    // On fixe d'abord la largeur du chatView (nécessaire pour que sa collection
    // calcule le wrapping du texte et donc sa vraie hauteur de contenu), on
    // force le layout, puis on lit contentSize.height. SevenTVChatCustomView
    // est une UICollectionView (diffable data source) → UIScrollView.contentSize
    // reflète exactement la hauteur des 7 messages empilés.
    chatView.frame = CGRectMake(0, 0, width - kFakeChatInset * 2, maxHeight);
    CGFloat contentHeight = [chatView s7tvContentHeight];

    CGFloat height = (contentHeight > 0)
        ? MIN(contentHeight + kFakeChatInset * 2, maxHeight)
        : maxHeight; // fallback si contentSize indisponible (pas encore layoutée)

    CGFloat y = MAX(safeTop, inputTopY - height);

    container.frame = CGRectMake(0, y, width, height);
    self.sizesPanel.fakeChatView.frame = CGRectInset(container.bounds, kFakeChatInset, kFakeChatInset);
    container.hidden = NO;
    [keyWindow bringSubviewToFront:container];
}

- (void)_hideFakeChatPreview {
    SevenTVChatCustomView *chatView = self->_sizesPanel.fakeChatView;
    [chatView resetTransientTranscriptState];
    chatView.renderingSuspended = YES;
    self.pickerFakeChatPreviewView.hidden = YES;
}

// ── Slider taille des emotes ───────────────────────────────────────────────

// Table nom-de-clé → (nom affiché, min, max) — une seule source pour le menu
// de sélection, l'ouverture du slider et le label de propriété. Bornes
// choisies pour couvrir large sans avoir à les retoucher plus tard (~2x le
// défaut mesuré pour chaque élément, voir 7tv-chat-appearance-config.m).
- (void)emotePickerSizesToggleTapped {
    BOOL show = !self.pickerSizesPanelVisible;
    if (show) {
        // Couper aussi une décélération en cours. Sinon le callback de fin de
        // scroll peut réactiver une ancienne cellule derrière le panneau.
        CGPoint offset = self.emoteCollectionView.contentOffset;
        [self.emoteCollectionView setContentOffset:offset animated:NO];
        self.emoteCollectionView.panGestureRecognizer.enabled = NO;
        self.emoteCollectionView.panGestureRecognizer.enabled = YES;
        [self _s7tv_deactivateVisiblePickerAnimations];
        [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
        [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
        [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
        self.pickerScrollInProgress = NO;
        // Le toggle du panGestureRecognizer peut supprimer le callback
        // didEndDecelerating. Appliquer ici le catalogue mis en attente évite
        // de laisser la grille/preview obsolète jusqu'à la prochaine ouverture.
        if (self.pickerCatalogReloadPending) [self _s7tv_applyCatalogUpdateNow];
    }
    self.pickerSizesPanelVisible = show;
    self.sizesPanel.panelView.hidden = !show;
    self.emoteCollectionView.hidden  = show;
    self.pickerSearchCapsuleView.hidden = show;
    // Masque le conteneur ET les icônes (pas juste les icônes) : la capsule
    // vide se retrouverait sinon sous la paire tailles/réglages quand elle
    // passe à gauche dans le panneau des tailles.
    self.pickerTabCapsuleView.hidden = show;
    self.pickerSubcategoryCapsuleView.hidden = show;
    for (UIButton *btn in self.pickerTabButtons) btn.hidden = show;
    self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    // L'émoticône reprend l'icône de retour historique du picker : la capsule
    // garde ainsi le même langage visuel dans les deux pages.
    UIImageSymbolConfiguration *backCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [self.pickerSizesToggleBtn setImage:
        [UIImage systemImageNamed:(show ? @"face.smiling" : @"textformat.size")
                withConfiguration:backCfg]
                                forState:UIControlStateNormal];

    // ── Point 5 : adapter la hauteur du picker au panneau où on se trouve ──
    // Le panneau des tailles n'a que 5 lignes courtes : pas besoin de garder
    // la hauteur de la grille (qui laissait un grand vide en dessous) si le
    // contenu réel est plus court. On ne dépasse jamais la hauteur "grille"
    // pour rester dans une zone confortable à l'écran.
    // Toujours ré-appeler le relayout (pas seulement si la hauteur change) :
    // c'est lui qui replace la capsule tailles/réglages du bon côté selon
    // pickerSizesPanelVisible (à droite en grille, à gauche dans le panneau
    // des tailles) — sans ça, sur un contenu de hauteur identique par
    // coïncidence, les boutons resteraient du mauvais côté.
    // Instantané (pas d'animation) : le déplacement de la capsule d'un côté à
    // l'autre doit être immédiat, pas un glissement visible.
    CGRect f = self.emotePickerView.frame;
    CGFloat targetH = show
        ? MIN(MAX(self.sizesPanel.contentHeight, 160.0), kS7TVPickerGridDefaultH)
        : kS7TVPickerGridDefaultH;
    f.size.height = targetH;
    self.emotePickerView.frame = f;
    [self _s7tv_relayoutPickerForSize:f.size];
    // Force UIKit à relire la nouvelle taille de l'inputView (sinon la zone
    // réservée au clavier peut rester figée à l'ancienne hauteur).
    [self.emotePickerTextEntryView reloadInputViews];

    if (show) {
        self.sizesPanel.fakeChatView.renderingSuspended = NO;
        [self.sizesPanel loadRealPreviewAssetsIfNeeded];
        [self _showFakeChatPreviewAboveInputView];
    } else {
        [self _hideFakeChatPreview];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _s7tv_activateVisiblePickerAnimations];
        });
    }
}

// Ouvre l'écran de réglages complet depuis le picker (même écran que le
// bouton flottant 7TV) — ferme d'abord le picker (clavier custom + inputView)
// pour ne pas laisser le menu de réglages s'ouvrir par-dessus le picker
// encore affiché en arrière-plan.
- (void)_pickerSettingsTapped {
    [self _hideEmotePicker];
    [[SevenTVManager sharedManager] presentSettingsMenu];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    if (self.pickerUsesCatalogSections) return (NSInteger)self.pickerDisplaySections.count;
    return 1; // Compatibilité avec le catalogue legacy aplati.
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if (self.pickerUsesCatalogSections) {
        if (section < 0 || section >= (NSInteger)self.pickerDisplaySections.count) return 0;
        S7TVPickerDisplaySection *display = self.pickerDisplaySections[(NSUInteger)section];
        NSString *key = [self _s7tv_displaySectionKey:display];
        return [self.pickerCollapsedSections[key] boolValue] ? 0 : (NSInteger)display.items.count;
    }
    return (NSInteger)self.emotePickerEmotes.count;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView ||
        ![kind isEqualToString:UICollectionElementKindSectionHeader] ||
        !self.pickerUsesCatalogSections ||
        indexPath.section >= (NSInteger)self.pickerDisplaySections.count) {
        return [UICollectionReusableView new];
    }
    S7TVPickerSectionHeaderView *header =
        (S7TVPickerSectionHeaderView *)[collectionView
            dequeueReusableSupplementaryViewOfKind:kind
                               withReuseIdentifier:@"S7TVPickerSectionHeader"
                                      forIndexPath:indexPath];
    S7TVPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)indexPath.section];
    NSString *sectionKey = [self _s7tv_displaySectionKey:section];
    BOOL collapsed = [self.pickerCollapsedSections[sectionKey] boolValue];
    UIColor *textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    UIColor *subColor = [UIColor colorWithWhite:1.0 alpha:0.52];
    header.titleLabel.text = section.title ?: @"Emotes";
    header.titleLabel.textColor = textColor;
    header.countLabel.text = section.items.count ? [NSString stringWithFormat:@"%lu",
        (unsigned long)section.items.count] : @"—";
    header.countLabel.textColor = subColor;
    header.stateLabel.hidden = section.loaded && !section.loading && !section.empty &&
        !section.errorMessage.length;
    header.stateLabel.text = section.loading ? @"Loading…"
        : (section.errorMessage.length ? @"Unavailable"
           : (section.loaded ? @"No emotes" : @"Tap to load"));
    header.stateLabel.textColor = section.loading || section.empty || !section.loaded
        ? [UIColor colorWithWhite:1.0 alpha:0.45] : [UIColor systemOrangeColor];
    header.retryButton.hidden = !section.errorMessage.length;
    header.backgroundColor = S7TVOLEDModeEnabled()
        ? [UIColor colorWithWhite:1.0 alpha:0.035]
        : [UIColor colorWithWhite:1.0 alpha:0.055];
    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration
        configurationWithPointSize:10.0 weight:UIImageSymbolWeightSemibold];
    [header.toggleButton setImage:[UIImage systemImageNamed:(collapsed
        ? @"chevron.right" : @"chevron.down") withConfiguration:chevronConfig]
                          forState:UIControlStateNormal];
    header.toggleButton.tintColor = subColor;
    header.toggleButton.tag = indexPath.section;
    header.retryButton.tag = indexPath.section;
    [header.toggleButton removeTarget:self action:@selector(_pickerSectionHeaderTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
    [header.toggleButton addTarget:self action:@selector(_pickerSectionHeaderTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    [header.retryButton removeTarget:self action:@selector(_pickerSectionRetryTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
    [header.retryButton addTarget:self action:@selector(_pickerSectionRetryTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    header.toggleButton.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        section.title ?: @"Emotes", collapsed ? @"Expand" : @"Collapse"];
    return header;
}

- (void)_pickerSectionHeaderTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pickerDisplaySections.count) return;
    S7TVPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    NSString *key = [self _s7tv_displaySectionKey:section];
    BOOL willExpand = [self.pickerCollapsedSections[key] boolValue];
    self.pickerCollapsedSections[key] = @(!willExpand);
    if (willExpand && section.provider == S7TVEmoteProviderIDSevenTV &&
        section.kind == S7TVEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"] &&
        !section.items.count &&
        !section.loaded &&
        !section.loading && !section.errorMessage.length) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [SevenTVManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[S7TVEmoteCatalog sharedCatalog] loadSevenTVEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
    }
    [self _s7tv_rebuildCatalogDisplaySectionsForQuery:self.emoteSearchField.text ?: @""];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
}

- (void)_pickerSectionRetryTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pickerDisplaySections.count) return;
    S7TVPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    if (section.provider == S7TVEmoteProviderIDSevenTV &&
        section.kind == S7TVEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"]) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [SevenTVManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[S7TVEmoteCatalog sharedCatalog] loadSevenTVEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
        return;
    }
    NSString *channelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    [catalog loadProvider:section.provider global:YES channel:nil completion:nil];
    if (channelID.length)
        [catalog loadProvider:section.provider global:NO channel:channelID completion:nil];
}

// ── Taille variable par emote ─────────────────────────────────────────────
//
// Hauteur de référence = screenWidth / 6  (→ environ 6 carrés par ligne).
// Largeur = hauteur × ratio de l'emote   (si ratio > 1 → plus large).
// La cellule épouse le ratio naturel de l'emote, exactement comme sur 7TV PC.
//
// Contraintes :
//   • largeur min : cellH * 0.25   (évite les emotes ultra-étroites)
//   • largeur max : cv.bounds.width (pas de débordement)
//   • hauteur min : 32 pt

// Nombre de colonnes de référence — plus élevé en paysage pour des cellules plus petites.
// Portrait  : 6 cols → cellules ~65pt (iPhone 390pt wide)
// Paysage   : 10 cols → cellules ~84pt (iPhone 844pt wide) — taille réduite voulue
- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    CGFloat cvW = cv.bounds.size.width > 0 ? cv.bounds.size.width : 390.0;
    UIWindow *hostWindow = cv.window ?: self.emotePickerTextField.window;
    CGSize hostSize = hostWindow ? hostWindow.bounds.size : UIScreen.mainScreen.bounds.size;
    CGFloat referenceColumns = hostSize.width > hostSize.height ? 10.0 : 6.0;
    CGFloat cellH = MAX(32.0, floor(cvW / referenceColumns));

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote || emote.width <= 0 || emote.height <= 0) {
        // Pas de dimensions connues → carré
        return CGSizeMake(cellH, cellH);
    }

    CGFloat ratio = (CGFloat)emote.width / (CGFloat)emote.height;
    CGFloat cellW = cellH * ratio;

    // Contraintes
    cellW = MAX(cellH * 0.25, cellW);   // min 25% de la hauteur
    cellW = MIN(cvW, cellW);            // max = pleine largeur
    cellW = ceil(cellW);
    cellH = ceil(cellH);

    return CGSizeMake(cellW, cellH);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    S7TVEmotePickerCell *cell = (S7TVEmotePickerCell *)
        [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID forIndexPath:indexPath];
    // La couleur de carte/bordure dépend du mode OLED : la réappliquer à
    // chaque déqueue garantit qu'une cellule recyclée après un changement de
    // mode ne garde pas une palette obsolète.
    [cell s7tv_applyOLEDColors];

    // Une cellule peut être reconfigurée sans passer immédiatement par
    // prepareForReuse. On coupe donc ici l'ancienne observation, exactement
    // comme le chat custom le fait avant son willDisplayCell.
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:cell];
    [cell.animationFrameRequest cancel];
    cell.animationFrameRequest = nil;
    cell.imageLoadGeneration += 1;
    cell.animationGeneration += 1;
    cell.wantsAnimation = NO;
    cell.currentEmoteKey = nil;
    cell.emoteImageView.image = nil;
    cell.favoriteStarView.hidden = YES;
    cell.providerBadgeLabel.hidden = YES;
    cell.providerBadgeLabel.text = nil;

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Étoile favoris — la vue existe déjà sur la cellule (créée une fois
    // dans S7TVEmotePickerCell), on ne fait que l'afficher/masquer ici.
    // Basée sur l'appartenance réelle aux favoris (et non plus sur la
    // section) puisqu'une emote favorite reste visible dans son onglet 7TV
    // normal (channel/globales) en plus de l'onglet Favoris.
    S7TVEmoteDescriptor *descriptor = [emote isKindOfClass:[S7TVPickerCatalogEmote class]]
        ? [(S7TVPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFavorite = descriptor
        ? [self.pickerFavoriteKeySet containsObject:
              S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID)]
        : [[SevenTVManager sharedManager] isEmoteFavorited:emote.emoteID];
    cell.favoriteStarView.hidden = !isFavorite;
    cell.accessibilityLabel = emote.emoteName ?: @"Emote";
    if (descriptor && (self.pickerActiveTab == S7TVPickerTabFavorites ||
                       self.pickerActiveTab == S7TVPickerTabAll)) {
        cell.providerBadgeLabel.text = descriptor.providerIdentifier.uppercaseString;
        cell.providerBadgeLabel.hidden = NO;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
            descriptor.name, descriptor.providerName ?: descriptor.providerIdentifier,
            descriptor.sectionTitle ?: @"Emotes"];
    }

    // Le réglage s'applique à tout le picker, pas seulement aux favoris —
    // sauf si la sous-option "Animations uniquement pour les favoris" est
    // active, auquel cas seul l'onglet Favoris anime, le reste reste statique.
    BOOL wantsAnimated = emote.isAnimated && [SevenTVManager sharedManager].showPickerAnimations &&
        (![SevenTVManager sharedManager].showPickerAnimationsFavoritesOnly || self.pickerActiveTab == S7TVPickerTabFavorites);

    S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
    NSString *key = resolved.imageURL.absoluteString;
    cell.currentEmoteKey = key;
    cell.wantsAnimation = wantsAnimated;

    // cellFor ne démarre aucun travail. Un cache hit est posé immédiatement ;
    // sinon willDisplay attend que la cellule soit stable avant de demander
    // sa miniature et, éventuellement, ses frames animées.
    cell.emoteImageView.image = [[SevenTVEmoteImageCache sharedCache]
        cachedImageForResolvedEmote:resolved];

    return cell;
}

// ── Chemin animé : frames servies par le cache, lecture pilotée par
// SevenTVEmoteAnimationEngine (même CADisplayLink centralisé que le chat
// custom, déjà throttlé à maxSimultaneousAnimations) au lieu que chaque
// cellule fasse tourner sa propre boucle d'animation UIImage indépendante.
- (BOOL)_s7tv_configureAnimatedPickerCell:(S7TVEmotePickerCell *)cell
                             resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode {
    SevenTVEmoteImageCache *cache   = [SevenTVEmoteImageCache sharedCache];
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];

    __weak typeof(self) weakSelfForActivity = self;
    __weak S7TVEmotePickerCell *weakCellForActivity = cell;
    BOOL (^cellIsStillActive)(void) = ^BOOL{
        SevenTVEmotePickerController *strongSelf = weakSelfForActivity;
        S7TVEmotePickerCell *strongCell = weakCellForActivity;
        return strongSelf && strongCell &&
               strongCell.window != nil &&
               strongSelf.emotePickerView.window != nil &&
               !strongSelf.pickerSearchAlertActive &&
               !strongSelf.emotePickerView.hidden &&
               !strongSelf.emoteCollectionView.hidden &&
               strongCell.wantsAnimation &&
               strongCell.animationGeneration == generation &&
               [strongCell.currentEmoteKey isEqualToString:key];
    };
    if (!cellIsStillActive()) return NO;

    __weak S7TVEmotePickerCell *weakCell = cell;
    void (^redraw)(void) = ^{
        __strong S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongCell || ![strongCell.currentEmoteKey isEqualToString:key]) return;
        UIImage *frame = [engine currentFrameForKey:key];
        if (frame) strongCell.emoteImageView.image = frame;
    };

    // Toute frame déjà enregistrée (y compris une preview courte) est affichée
    // immédiatement. Seule une boucle COMPLÈTE autorise toutefois un retour
    // anticipé : une preview ne doit plus bloquer à vie le vrai décodage.
    if ([engine hasFramesForKey:key]) {
        if (!cellIsStillActive()) return NO;
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw(); // pose la frame courante immédiatement, sans attendre le prochain tick
        if ([engine hasCompleteFramesForKey:key]) return YES;
    }

    // Frames décodées et en cache (ex: vues dans le chat) mais pas encore
    // enregistrées auprès de l'engine → enregistrement direct, toujours pas
    // de redécodage.
    S7TVEmoteAnimatedFrames *cachedFrames = [cache cachedFramesForResolvedEmote:resolved];
    if (cachedFrames) {
        if (!cellIsStillActive()) return NO;
        [engine registerFrames:cachedFrames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
        return YES;
    }

    // Premier passage depuis willDisplay : les cache hits ci-dessus doivent
    // démarrer immédiatement, même pendant un flick. En revanche, un nouveau
    // décodage multi-frames n'est autorisé qu'après le court délai de stabilité
    // appliqué par _s7tv_scheduleAnimationForPickerCell:atIndexPath:. Cela
    // évite de remplir la file série avec les emotes seulement traversées.
    if (!allowDecode) return NO;

    // Rien en cache : afficher au moins la frame statique déjà connue (si
    // elle existe) pendant que les frames animées se décodent en arrière-plan,
    // plutôt qu'une cellule vide.
    UIImage *staticCached = [cache cachedImageForResolvedEmote:resolved];
    if (staticCached) cell.emoteImageView.image = staticCached;

    __weak S7TVEmotePickerCell *weakCellForLoad = cell;
    void (^applyFrames)(S7TVEmoteAnimatedFrames *) = ^(S7TVEmoteAnimatedFrames *frames) {
        if (!frames.images.count) return;
        S7TVEmotePickerCell *strongCell = weakCellForLoad;
        if (!strongCell || !cellIsStillActive()) return;
        // La file de preview et la file complète sont indépendantes. Si la
        // complète a gagné la course, ignorer une preview arrivée plus tard.
        if (frames.isPreview && [engine hasCompleteFramesForKey:key]) return;
        [engine registerFrames:frames forKey:key];
        [engine addObserver:strongCell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
    };

    cell.animationFrameRequest = [cache framesForResolvedEmote:resolved
        preview:^(S7TVEmoteAnimatedFrames *previewFrames) {
            // Boucle légère (12 frames max) : rend l'animation visible sans
            // attendre le décodage complet du WebP.
            applyFrames(previewFrames);
        }
        completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
            S7TVEmotePickerCell *strongCell = weakCellForLoad;
            if (frames) applyFrames(frames);
            if (strongCell && cellIsStillActive()) {
                strongCell.animationFrameRequest = nil;
            }
        }];
    return YES;
}

// ── Visibilité réelle / scroll ─────────────────────────────────────────────

- (void)_s7tv_scheduleStaticImageForPickerCell:(S7TVEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden) return;
    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.imageLoadGeneration;
    __weak typeof(self) weakSelf = self;
    __weak S7TVEmotePickerCell *weakCell = cell;

    // Un flick rapide ne doit pas remplir la file de décodage avec des
    // cellules déjà parties. Après 40 ms de stabilité, seule une cellule
    // encore visible est autorisée à demander sa première frame.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window ||
            strongSelf.emotePickerView.hidden || strongSelf.emoteCollectionView.hidden) return;
        if (strongCell.imageLoadGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        SevenTVEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote) return;
        S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;

        SevenTVEmoteImageCache *cache = [SevenTVEmoteImageCache sharedCache];
        UIImage *cached = [cache cachedImageForResolvedEmote:resolved];
        if (cached) {
            strongCell.emoteImageView.image = cached;
            return;
        }
        [cache imageForResolvedEmote:resolved completion:^(UIImage * _Nullable image) {
            S7TVEmotePickerCell *completionCell = weakCell;
            SevenTVEmotePickerController *completionSelf = weakSelf;
            if (!image || !completionSelf || completionSelf.pickerSearchAlertActive ||
                !completionSelf.emotePickerView.window || !completionCell || !completionCell.window ||
                completionCell.imageLoadGeneration != generation ||
                ![completionCell.currentEmoteKey isEqualToString:key]) return;
            completionCell.emoteImageView.image = image;
        }];
    });
}

- (void)_s7tv_scheduleAnimationForPickerCell:(S7TVEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        !cell.wantsAnimation || self.emoteCollectionView.hidden) return;
    if (cell.animationFrameRequest) return; // décodage courant déjà lié à cette cellule

    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.animationGeneration;
    __weak typeof(self) weakSelf = self;
    __weak S7TVEmotePickerCell *weakCell = cell;

    SevenTVEmote *initialEmote = [self _emoteForIndexPath:indexPath];
    if (!initialEmote || !initialEmote.isAnimated) return;
    S7TVPickerResolvedEmote *initialResolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:initialEmote];
    if (![initialResolved.imageURL.absoluteString isEqualToString:key]) return;

    // Un cache hit doit s'animer tout de suite. Cette première passe ne peut
    // jamais lancer de décodage lourd : elle ne fait que brancher les frames
    // déjà présentes dans le moteur ou le cache.
    BOOL attachedFromCache = [self _s7tv_configureAnimatedPickerCell:cell
                                                        resolvedEmote:initialResolved
                                                                  key:key
                                                           generation:generation
                                                          allowDecode:NO];
    if (attachedFromCache) return;

    // Les requêtes sont désormais annulables dans didEndDisplayingCell : plus
    // besoin d'attendre 80/120 ms pour filtrer un flick. Toute cellule visible
    // demande sa preview animée dès le prochain passage du run loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window) return;
        if (strongCell.animationGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        SevenTVEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote || !emote.isAnimated) return;
        S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;
        [strongSelf _s7tv_configureAnimatedPickerCell:strongCell
                                        resolvedEmote:resolved
                                                  key:key
                                           generation:generation
                                          allowDecode:YES];
    });
}

- (void)_s7tv_deactivateVisiblePickerAnimations {
    for (S7TVEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell.animationFrameRequest cancel];
        cell.animationFrameRequest = nil;
        cell.imageLoadGeneration += 1;
        cell.animationGeneration += 1;
        [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:cell];
    }
}

- (void)_s7tv_activateVisiblePickerAnimations {
    if (self.pickerSearchAlertActive || self.pickerScrollInProgress ||
        self.emoteCollectionView.isTracking || self.emoteCollectionView.isDragging ||
        self.emoteCollectionView.isDecelerating || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden || self.emotePickerView.hidden) return;
    for (NSIndexPath *indexPath in self.emoteCollectionView.indexPathsForVisibleItems) {
        S7TVEmotePickerCell *cell = (S7TVEmotePickerCell *)
            [self.emoteCollectionView cellForItemAtIndexPath:indexPath];
        if (cell) {
            [self _s7tv_scheduleStaticImageForPickerCell:cell atIndexPath:indexPath];
            [self _s7tv_scheduleAnimationForPickerCell:cell atIndexPath:indexPath];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView
        willDisplayCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    S7TVEmotePickerCell *pickerCell = (S7TVEmotePickerCell *)cell;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
    [self _s7tv_scheduleStaticImageForPickerCell:pickerCell atIndexPath:indexPath];
    [self _s7tv_scheduleAnimationForPickerCell:pickerCell atIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView
 didEndDisplayingCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    S7TVEmotePickerCell *pickerCell = (S7TVEmotePickerCell *)cell;
    [pickerCell.animationFrameRequest cancel];
    pickerCell.animationFrameRequest = nil;
    pickerCell.imageLoadGeneration += 1;
    pickerCell.animationGeneration += 1;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = YES;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:YES];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:YES];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.emoteCollectionView || decelerate) return;
    self.pickerScrollInProgress = NO;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    if (self.pickerCatalogReloadPending) [self _s7tv_applyCatalogUpdateNow];
    [self _s7tv_activateVisiblePickerAnimations];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = NO;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    if (self.pickerCatalogReloadPending) [self _s7tv_applyCatalogUpdateNow];
    [self _s7tv_activateVisiblePickerAnimations];
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // ── Étape 1: trouver la ChatInputView ────────────────────────────────────
    // On cherche d'abord dans la référence stockée, puis dans toute la fenêtre.
    UIView *inputRoot = self.emotePickerTextField;

    if (!inputRoot) {
        [[SevenTVManager sharedManager] log:@"⚠️ didSelect: emotePickerTextField nil → BFS fenêtre"];
        UIWindow *kw = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { kw = w; break; }
        if (!kw) kw = [UIApplication sharedApplication].windows.firstObject;
        if (kw) {
            NSMutableArray<UIView *> *bq = [NSMutableArray arrayWithObject:kw];
            while (bq.count > 0) {
                UIView *v = bq.firstObject; [bq removeObjectAtIndex:0];
                [bq addObjectsFromArray:v.subviews];
                if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.ChatInputView"]) {
                    inputRoot = v;
                    self.emotePickerTextField = v;
                    break;
                }
            }
        }
    }

    // ── Étape 2: utiliser directement emotePickerTextEntryView ────────────
    // C’est lui qui est firstResponder (inputAccessoryView) — insertText: fonctionnera.
    // On garde le BFS en fallback si emotePickerTextEntryView est nil.
    UITextView  *textView  = self.emotePickerTextEntryView;
    UITextField *textField = nil;
    id<UIKeyInput> keyInput = nil;

    if (!textView && inputRoot) {
        // Fallback BFS
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:inputRoot];
        while (queue.count > 0) {
            UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            [queue addObjectsFromArray:v.subviews];
            if (!textView  && [v isKindOfClass:[UITextView class]])  textView  = (UITextView *)v;
            if (!textField && [v isKindOfClass:[UITextField class]]) textField = (UITextField *)v;
            if (!keyInput  && [v conformsToProtocol:@protocol(UIKeyInput)]
                           && ![v isKindOfClass:[UIButton class]])   keyInput  = (id<UIKeyInput>)v;
        }
    }

    [[SevenTVManager sharedManager] log:@"🔍 didSelect — textView:%@ textField:%@ keyInput:%@",
     textView  ? NSStringFromClass([textView  class]) : @"nil",
     textField ? NSStringFromClass([textField class]) : @"nil",
     keyInput  ? NSStringFromClass([(UIView *)keyInput class]) : @"nil"];

    // ── Étape 3: construire le texte à insérer ────────────────────────────────
    NSString *currentText = @"";
    if (textView)       currentText = textView.text  ?: @"";
    else if (textField) currentText = textField.text ?: @"";

    NSString *prefix  = (currentText.length > 0 && ![currentText hasSuffix:@" "]) ? @" " : @"";
    NSString *emoteText = emote.emoteName ?: @"";
    NSString *stableKey = S7TVPickerStableEmoteKey(emote);
    NSString *favoriteComposition = stableKey.length
        ? [[S7TVEmoteCatalog sharedCatalog]
            favoriteCompositionTextForEmoteKey:stableKey] : nil;
    if (favoriteComposition.length) emoteText = favoriteComposition;
    NSString *toAppend = [NSString stringWithFormat:@"%@%@ ", prefix, emoteText];

    // ── Étape 4: insertion ─────────────────────────────────────────────────
    // insertText: seul ne suffit pas : le UITextView de Twitch est un
    // composant SwiftUI bridgé. UITextInput/insertText: modifie le buffer
    // interne de UITextView mais ne déclenche PAS le @Binding SwiftUI ni
    // textViewDidChange: du côté natif de Twitch.
    //
    // Solution : simuler une saisie clavier complète —
    //   1. Copier le texte voulu dans le presse-papier
    //   2. Appeler paste: sur le firstResponder
    // paste: passe par UITextInput.insertText: ET déclenche le
    // UITextViewTextDidChangeNotification + le delegate textViewDidChange:
    // que Twitch observe → le binding SwiftUI est mis à jour.
    //
    // Effet de bord UIPasteboard : le contenu du presse-papier est temporairement
    // remplacé. On restaure l'ancien contenu juste après via dispatch_async.
    BOOL inserted = NO;

    if (textView) {
        // Aller à la fin
        textView.selectedRange = NSMakeRange(textView.text.length, 0);

        // Sauvegarder et remplacer le presse-papier
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *savedString = pb.string;
        pb.string = toAppend;

        // paste: déclenche le pipeline UITextInput complet + notifie SwiftUI
        if ([textView respondsToSelector:@selector(paste:)]) {
            [textView paste:nil];
            inserted = YES;
            [[SevenTVManager sharedManager] log:@"✅ paste: emote → «%@»", emoteText];
        } else {
            // Ultime fallback
            [textView insertText:toAppend];
            inserted = YES;
            [[SevenTVManager sharedManager] log:@"⚠️ paste: non dispo → insertText: fallback"];
        }

        // Restaurer le presse-papier après l'animation de paste
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            pb.string = savedString ?: @"";
        });

        // Forcer la notification UITextViewTextDidChangeNotification
        // au cas où paste: ne l'aurait pas déclenchée (bridge SwiftUI parfois silencieux)
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UITextViewTextDidChangeNotification
                              object:textView];
            // Déclencher aussi le delegate si Twitch l'a assigné
            if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [textView.delegate textViewDidChange:textView];
            }
        });
    } else if (textField) {
        [textField becomeFirstResponder];
        [(id<UIKeyInput>)textField insertText:toAppend];
        [[SevenTVManager sharedManager] log:@"✅ insertText: UITextField → «%@»", toAppend];
        inserted = YES;
    } else if (keyInput) {
        [(UIView *)keyInput becomeFirstResponder];
        [(id<UIKeyInput>)keyInput insertText:toAppend];
        [[SevenTVManager sharedManager] log:@"✅ insertText: UIKeyInput → «%@»", toAppend];
        inserted = YES;
    }

    if (!inserted) {
        [[SevenTVManager sharedManager] log:@"❌ didSelect: aucun champ texte trouvé — emote=%@", emote.emoteName];
    }

        // Feedback haptique léger
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { window = w; break; }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
@end
