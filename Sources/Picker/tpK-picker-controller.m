// Extrait de tpK-core-manager.m : picker d'emotes 7TV indépendant du picker natif Twitch.

#import "Picker/tpK-picker-controller.h"
#import "Core/tpK-core-manager.h"
#import "Settings/tpK-settings-controller.h"
#import "Picker/tpK-picker-settings-panel.h"
#import "Localization/tpK-localization-manager.h"
#import "Picker/tpK-picker-resolved-emote.h"
#import "Picker/tpK-picker-cell.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Emote/tpK-badge-provider.h"
#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-provider-settings.h"
#import "Emote/tpK-emote-animation-engine.h"
#import "Emote/tpK-network-emote-cache.h"
#import "UI/7tv-ui-logo.h"
#import "UI/tpK-ui-logo.h"
#import "UI/bttv-ui-logo.h"
#import "UI/ffz-ui-logo.h"
#import "UI/tpK-oled-mode.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const char kTPKPickerHostAssociation = 5;
static const char kTPKBitsReplacement = 7;
static const char kTPKBitsReplacementPin = 8;
static __weak UIView *tpk_pickerChatButtonNative = nil;
static __weak UIButton *tpk_pickerChatButtonReplacement = nil;

static UIImage *tpk_pickerLogoImage(CGFloat targetHeight) {
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *icon = [UIImage imageWithData:logoData scale:1.0];
    if (!icon) return nil;
    if (targetHeight < 12.0) targetHeight = 18.0;
    CGFloat targetWidth = targetHeight * (icon.size.width / MAX(icon.size.height, 1.0));
    UIGraphicsBeginImageContextWithOptions(
        CGSizeMake(targetWidth, targetHeight), NO, UIScreen.mainScreen.scale);
    [icon drawInRect:CGRectMake(0, 0, targetWidth, targetHeight)];
    UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedIcon ?: icon;
}

// ── Palette du picker (mode normal / OLED) ───────────────────────────────
// bgColor=fond le plus sombre, cardColor=cartes, sepColor=séparateurs ; OLED=noir profond, contraste juste.
static UIColor *tpk_pickerBgColor(void) {
    return TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}
static UIColor *tpk_pickerCardColor(void) {
    return TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.05 alpha:1.0]
        : [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
}
static UIColor *tpk_pickerSepColor(void) {
    return TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.12 alpha:1.0]
        : [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}
static UIColor *tpk_pickerAccentColor(void) {
    return [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
}

// Cellules créées avant d'avoir une UIWindow → signal à l'attachement du clavier, pas dispatch_async.
@interface TPKPickerContainerView : UIView
@property (nonatomic, copy) dispatch_block_t didAttachToWindow;
// UIKit impose sa frame à l'inputView : la seule hauteur qu'il respecte est
// celle annoncée en Auto Layout. D'où translatesAutoresizingMaskIntoConstraints
// à NO et une preferredHeight explicite.
@property (nonatomic, assign) CGFloat preferredHeight;
@end

@implementation TPKPickerContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _preferredHeight = frame.size.height;
    }
    return self;
}

- (void)setPreferredHeight:(CGFloat)preferredHeight {
    if (fabs(_preferredHeight - preferredHeight) < 0.5) return;
    _preferredHeight = preferredHeight;
    [self invalidateIntrinsicContentSize];
}

- (CGSize)intrinsicContentSize {
    // Jamais 0 : une hauteur nulle ferait disparaître le picker.
    // CGFLOAT_MAX = "aucune contrainte" sur le sens horizontal (UIViewNoMetric).
    return CGSizeMake(CGFLOAT_MAX,
                      _preferredHeight > 0 ? _preferredHeight
                                           : CGRectGetHeight(self.bounds));
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && self.didAttachToWindow) self.didAttachToWindow();
}
@end

@interface TPKPickerWeakRef : NSObject
@property (nonatomic, weak) id object;
+ (instancetype)refWithObject:(id)object;
@end

@implementation TPKPickerWeakRef
+ (instancetype)refWithObject:(id)object {
    TPKPickerWeakRef *reference = [TPKPickerWeakRef new];
    reference.object = object;
    return reference;
}
@end

// Section de catalogue distincte de l'array plat : sous-catégorie choisie sans casser le pipeline.
@interface TPKPickerDisplaySection : NSObject
@property (nonatomic, assign) TPKEmoteProviderID provider;
@property (nonatomic, assign) TPKEmoteSectionKind kind;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<TPKEmote *> *items;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL empty;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end

@implementation TPKPickerDisplaySection
@end

// En-tête léger : bouton transparent sur toute la ligne, une seule cible VoiceOver/tap.
@interface TPKPickerSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *retryButton;
@end

@implementation TPKPickerSectionHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _toggleButton.frame = self.bounds;
    _toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    // Button spans the whole row for tappability, but keep its chevron trailing, not centered.
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

@interface TPKManager (TPKChatBarButton)
- (void)tpk_emoteButtonTappedForButton:(UIButton *)sender;
@end

@implementation TPKManager (TPKChatBarButton)
- (void)tpk_emoteButtonTappedForButton:(UIButton *)sender {
    id association = objc_getAssociatedObject(sender, &kTPKPickerHostAssociation);
    UIView *chatInputView = [association isKindOfClass:TPKPickerWeakRef.class]
        ? ((TPKPickerWeakRef *)association).object : association;
    if (!chatInputView || !chatInputView.window) return;
    [self toggleEmotePickerForChatInputView:chatInputView];
}
@end

static UIView *tpk_pickerHostForBitsView(UIView *bitsView) {
    for (UIView *current = bitsView.superview; current; current = current.superview) {
        NSString *className = NSStringFromClass(current.class);
        if ([className containsString:@"RNSScreenContentWrapper"] ||
            [className containsString:@"KeyboardControllerView"] ||
            [className containsString:@"ChatInput"]) return current;
    }
    return bitsView.window ?: bitsView;
}

BOOL TPKPickerChatButtonReady(void) {
    UIButton *replacement = tpk_pickerChatButtonReplacement;
    return replacement != nil && replacement.window != nil &&
        replacement.superview != nil && !replacement.hidden;
}

void tpk_handleChatTrayButtonLifecycle(UIView *view) {
    if (![view.accessibilityIdentifier isEqualToString:@"chat-tray-button-bits"]) return;
    if (!view.window) return;
    UIView *target = view.superview;
    if (!target) return;
    tpk_pickerChatButtonNative = view;

    CGRect frame = [view convertRect:view.bounds toView:target];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame)) return;

    TPKManager *manager = [TPKManager sharedManager];
    UIButton *replacement = objc_getAssociatedObject(view, &kTPKBitsReplacement);
    if (![replacement isKindOfClass:[UIButton class]]) {
        // Twitch may recreate the native button: drop the previous copy.
        UIButton *previous = tpk_pickerChatButtonReplacement;
        if (previous && previous != replacement) [previous removeFromSuperview];
        replacement = [UIButton buttonWithType:UIButtonTypeCustom];
        replacement.tag = 0x7778;
        replacement.backgroundColor = UIColor.clearColor;
        replacement.accessibilityLabel = L(@"label_7tv_emotes");
        replacement.accessibilityIdentifier = @"tpk_emote_picker_button";
        UIImage *icon = tpk_pickerLogoImage(MIN(frame.size.height, frame.size.width) * 0.60);
        if (icon) {
            for (NSNumber *state in @[@(UIControlStateNormal),
                                      @(UIControlStateHighlighted),
                                      @(UIControlStateSelected),
                                      @(UIControlStateDisabled)]) {
                [replacement setImage:icon forState:state.unsignedIntegerValue];
            }
            replacement.imageView.contentMode = UIViewContentModeScaleAspectFit;
            replacement.tintColor = UIColor.whiteColor;
        }
        [replacement addTarget:manager
                       action:@selector(tpk_emoteButtonTappedForButton:)
             forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(view, &kTPKBitsReplacement, replacement,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tpk_pickerChatButtonReplacement = replacement;

    replacement.frame = frame;
    BOOL reattached = replacement.superview != target;
    if (reattached) [target addSubview:replacement];
    // Pin to the native button so every relayout moves our copy too.
    NSArray<NSLayoutConstraint *> *pin = objc_getAssociatedObject(
        replacement, &kTPKBitsReplacementPin);
    if (!pin || reattached) {
        if (pin) [NSLayoutConstraint deactivateConstraints:pin];
        replacement.translatesAutoresizingMaskIntoConstraints = NO;
        pin = @[
            [replacement.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [replacement.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [replacement.topAnchor constraintEqualToAnchor:view.topAnchor],
            [replacement.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ];
        [NSLayoutConstraint activateConstraints:pin];
        objc_setAssociatedObject(replacement, &kTPKBitsReplacementPin, pin,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [target bringSubviewToFront:replacement];
    view.hidden = YES;
    view.userInteractionEnabled = NO;
    UIView *host = tpk_pickerHostForBitsView(view);
    objc_setAssociatedObject(replacement, &kTPKPickerHostAssociation,
                             [TPKPickerWeakRef refWithObject:host],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface TPKEmotePickerController ()

// Panneau des tailles — composant enfant, créé paresseusement (voir -sizesPanel)
@property (nonatomic, strong) TPKPickerSizesPanel *sizesPanel;

// Picker d'emotes inline (affiché au-dessus de la barre de saisie)
@property (nonatomic, strong) UIView              *emotePickerView;
// FORT (pas weak) — doit rester valide jusqu'au tap : un weak deviendrait nil si Twitch recycle la vue.
@property (nonatomic, weak)   UIView              *emotePickerTextField;
// Forte sur le TextEntryView (firstResponder) : nécessaire pour TextDidEndEditing et l'aperçu.
@property (nonatomic, strong) UITextView          *emotePickerTextEntryView;
@property (nonatomic, strong) UICollectionView    *emoteCollectionView;
@property (nonatomic, strong) UITextField         *emoteSearchField;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerEmotes;
@property (nonatomic, strong, readwrite) NSArray<TPKEmote *> *emotePickerAllEmotes;
// L'alerte de recherche vole le first responder : TextDidEndEditing pendant ce transfert = fausse fermeture.
@property (nonatomic, assign) BOOL pickerSearchAlertActive;

// Arrays filtrés pour l'affichage dans le picker (3 sections)
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerChannelEmotes;
@property (nonatomic, strong, readwrite) NSArray<TPKEmote *> *emotePickerGlobalEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerOtherEmotes; // compatibilité
// Arrays provider-aware (TPKEmoteCatalog) ; les anciens servent encore aux previews et au code historique.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<TPKEmote *> *> *pickerProviderEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *pickerCatalogFavorites;
@property (nonatomic, copy) NSSet<NSString *> *pickerFavoriteKeySet;
// Sections Channel/Global en wrappers TPKEmote : partage cellules/animations avec le chemin legacy.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<TPKPickerDisplaySection *> *> *pickerProviderSections;
@property (nonatomic, strong) NSArray<TPKPickerDisplaySection *> *pickerDisplaySections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pickerCollapsedSections;
// Search expands sections temporarily; keep prior collapse choices aside so clearing search restores them.
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pickerCollapseStateBeforeSearch;
@property (nonatomic, assign) BOOL pickerCatalogSearchActive;
@property (nonatomic, assign) BOOL pickerUsesCatalogSections;

// Bouton ⚙️ du panneau des tailles (chrome du picker — logique dans TPKPickerSizesPanel)
@property (nonatomic, weak) UIButton *pickerSizesToggleBtn;
// Bouton réglages collé aux tailles — ouvre le même écran que le flottant 7TV (presentSettingsMenu).
@property (nonatomic, weak) UIButton *pickerSettingsBtn;
// Capsule pilule commune aux 2 boutons (même langage que pickerTabCapsuleView) au lieu de 2 pastilles séparées.
@property (nonatomic, weak) UIView   *pickerToolsCapsuleView;
@property (nonatomic, assign) BOOL   pickerSizesPanelVisible;

// Faux chat sur la key window (pas emotePickerView, c'est l'inputView) ; retenu pour le retirer à la fermeture.
@property (nonatomic, strong) UIView *pickerFakeChatPreviewView;

// ── Refonte tabbed + refonte visuelle du picker (style 7TV PC) ──────────
// Onglet actif : Favoris/Tous/7TV/BTTV/FFZ. « Tous » = pseudo-provider purement visuel, jamais en requêtes.
@property (nonatomic, assign) NSInteger pickerActiveTab;
// Onglet avant recherche, restauré quand le champ se vide (la recherche bascule Favoris→Channel→Globales).
@property (nonatomic, assign) BOOL      pickerIsSearching;
@property (nonatomic, assign) NSInteger pickerPreSearchTab;
// Pas de header ni de dock : tout flotte au-dessus de la grille (capsules provider et Channel/Global).
@property (nonatomic, weak) UIView    *pickerSubcategoryCapsuleView;
@property (nonatomic, weak) UIButton  *pickerSubcategoryChannelBtn;
@property (nonatomic, weak) UIButton  *pickerSubcategoryGlobalBtn;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pickerSubcategoryByProvider;
@property (nonatomic, weak) UIView    *pickerTabCapsuleView;         // bas gauche (Favoris/Tous/7TV/BTTV/FFZ)
@property (nonatomic, strong) NSMutableArray<UIButton *> *pickerTabButtons;
@property (nonatomic, weak) UIView    *pickerTabIndicatorView;       // pastille violette qui glisse entre les 5 boutons
@property (nonatomic, weak) UIView    *pickerSearchCapsuleView;      // bas, pleine largeur (recherche)
@property (nonatomic, weak) UIButton  *pickerSearchClearBtn;         // petite croix à droite du champ, visible si texte non vide
// En drag, chaque cellule visible demande une preview annulable ; sa sortie coupe observation/décodage.
@property (nonatomic, assign) BOOL pickerScrollInProgress;
@property (nonatomic, assign) BOOL pickerCatalogReloadPending;
@property (nonatomic, assign) NSUInteger pickerOrientationGeneration;
// 1re ouverture : bascule vers le 1er provider non vide si le défaut est vide ; tap onglet = désactivé.
@property (nonatomic, assign) BOOL pickerInitialProviderSelectionPending;
// Snapshots coûteux à aplatir : wrappers reconstruits seulement sur notif, pas à chaque ouverture.
@property (nonatomic, assign) BOOL pickerCatalogArraysDirty;
// Choix explicite des réglages jamais remplacé par la sélection auto du premier provider.
@property (nonatomic, assign) BOOL pickerOpeningLocationExplicit;

- (void)_tpk_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection;
- (void)_tpk_emoteCatalogDidUpdate:(NSNotification *)notification;
- (void)_tpk_twitchCredentialsDidUpdate:(NSNotification *)notification;
- (void)_tpk_badgesCatalogDidUpdate:(NSNotification *)notification;
- (void)_tpk_deviceOrientationDidChange:(NSNotification *)notification;
- (void)_tpk_applyCatalogUpdateNow;
- (void)_tpk_normalizeActivePickerTab;
- (BOOL)_tpk_selectInitialProviderIfNeeded;
- (TPKEmoteProviderID)_tpk_providerForPickerTab:(NSInteger)tab;
- (void)_tpk_updateSubcategoryCapsule;
- (void)_pickerSubcategoryTapped:(UIButton *)sender;
- (BOOL)_tpk_sectionIsChannel:(TPKPickerDisplaySection *)section;
- (BOOL)_tpk_sectionIsGlobal:(TPKPickerDisplaySection *)section;
- (BOOL)_tpk_pickerTabIsProvider:(NSInteger)tab;
- (void)_tpk_updatePickerTabButtonLayout;
- (NSArray<NSNumber *> *)_tpk_providerIDsInPriorityOrder;
- (void)_tpk_persistLastPickerLocation;
- (BOOL)_tpk_applyConfiguredPickerOpeningLocation;
- (void)_tpk_oledModeDidChange:(NSNotification *)notification;
- (void)_tpk_applyOLEDColors;
- (void)_tpk_relayoutPickerForSize:(CGSize)size;
- (CGFloat)_tpk_resolvedGridHeight;
- (void)_showFakeChatPreviewAboveInputView;
- (void)_tpk_deactivateVisiblePickerAnimations;
- (void)_tpk_activateVisiblePickerAnimations;
- (void)_tpk_scheduleAnimationForPickerCell:(TPKEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath;
- (void)_tpk_scheduleStaticImageForPickerCell:(TPKEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath;
- (BOOL)_tpk_configureAnimatedPickerCell:(TPKEmotePickerCell *)cell
                             resolvedEmote:(TPKPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode;
- (void)_pickerSectionHeaderTapped:(UIButton *)sender;
- (void)_pickerSectionRetryTapped:(UIButton *)sender;

@end

@implementation TPKEmotePickerController

// Valeurs par défaut de l'ancien -[TPKManager setup] : onglet Favoris, Channel, boutons prêts.
- (instancetype)init {
    self = [super init];
    if (self) {
        _pickerActiveTab                  = 0; // TPKPickerTabFavorites
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
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKEmoteCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKProviderCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKEmoteProviderSettingsDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_twitchCredentialsDidUpdate:)
                                                      name:TPKTwitchCredentialsDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_badgesCatalogDidUpdate:)
                                                      name:TPKBadgesCatalogUpdatedNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_deviceOrientationDidChange:)
                                                      name:UIDeviceOrientationDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_oledModeDidChange:)
                                                      name:TPKOLEDModeDidChangeNotification
                                                    object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_keyboardFrameDidChange:)
                                                      name:UIKeyboardDidChangeFrameNotification
                                                    object:nil];

        // Résignation sans notre bouton → inputView retiré sans _hideEmotePicker : faux chat rattrapé ici.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_textEntryDidEndEditing:)
                                                      name:UITextViewTextDidEndEditingNotification
                                                    object:nil];
    }
    return self;
}

- (void)_tpk_oledModeDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _tpk_applyOLEDColors];
    });
}

- (void)_tpk_applyOLEDColors {
    if (!self.emotePickerView) return;

    UIColor *backgroundColor = tpk_pickerBgColor();
    UIColor *cardColor       = tpk_pickerCardColor();
    UIColor *sepColor        = tpk_pickerSepColor();

    self.emotePickerView.backgroundColor = backgroundColor;
    self.emoteCollectionView.backgroundColor = backgroundColor;

    // Capsules flottantes : fond carte translucide, même teinte que les cellules (cohérence).
    UIColor *capsuleColor = [cardColor colorWithAlphaComponent:0.92];
    self.pickerTabCapsuleView.backgroundColor   = capsuleColor;
    self.pickerSubcategoryCapsuleView.backgroundColor = capsuleColor;
    self.pickerToolsCapsuleView.backgroundColor = capsuleColor;
    self.pickerSearchCapsuleView.backgroundColor = capsuleColor;

    // Cellules visibles : recolorer carte+bordure tout de suite ; cellForRow: fera le reste au prochain dequeue.
    for (TPKEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell tpk_applyOLEDColors];
    }
    UIColor *headerColor = TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:1.0 alpha:0.035]
        : [UIColor colorWithWhite:1.0 alpha:0.055];
    for (TPKPickerSectionHeaderView *header in
         [self.emoteCollectionView visibleSupplementaryViewsOfKind:
             UICollectionElementKindSectionHeader]) {
        header.backgroundColor = headerColor;
    }

    // Panneau des tailles (séparateurs + capsule de catégories + segmented controls).
    if (_sizesPanel) {
        [_sizesPanel tpk_applyOLEDColorsWithBgColor:backgroundColor
                                            sepColor:sepColor
                                           cardColor:cardColor];
    }

    // Aperçu du chat flottant.
    self.pickerFakeChatPreviewView.backgroundColor = TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.09 alpha:0.97];
}

- (void)_tpk_textEntryDidEndEditing:(NSNotification *)note {
    if (note.object != self.emotePickerTextEntryView) return;
    if (!self.emotePickerView || self.emotePickerView.hidden) return; // picker déjà fermé, rien à faire
    if (self.pickerSearchAlertActive) return; // focus prêté à l'alerte de recherche

    // Pas de resign/reloadInputViews ici : la résignation vient déjà de UIKit, on remet juste notre état à plat.
    [self _tpk_deactivateVisiblePickerAnimations];
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    // Invalider les relayouts d'orientation prévus : sinon le faux chat réapparaît après fermeture.
    self.pickerOrientationGeneration += 1;
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
    [self _hideFakeChatPreview];
}

// Panneau des tailles — composant enfant créé à la demande (toggle ⚙️ ou construction du picker).
- (TPKPickerSizesPanel *)sizesPanel {
    if (!_sizesPanel) {
        _sizesPanel = [[TPKPickerSizesPanel alloc] init];
        _sizesPanel.picker = self;
    }
    return _sizesPanel;
}

static NSString *const kEmoteCellID = @"TPKEmoteCell";

// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize = 40.0;

// ── Onglets du picker refondu (style 7TV PC) ──────────────────────────────
// 5 valeurs : Favoris/Tous/7TV/BTTV/FFZ — « Tous » agrège Channel/Shared/Sets + Global des providers activés.
typedef NS_ENUM(NSInteger, TPKPickerTab) {
    TPKPickerTabFavorites = 0,
    TPKPickerTabAll       = 1,
    TPKPickerTabTPK   = 2,
    TPKPickerTabBTTV      = 3,
    TPKPickerTabFFZ       = 4,
};

// ── Dimensions du picker refondu ────────────────────────────────────────
// Grille = 100% du picker, tout flotte ; sectionInset réserve haut/bas pour les cellules.
static const CGFloat kTPKPickerFloatSize    = 28.0; // diamètre/hauteur des pastilles flottantes (fermer, onglets, sous-choix, ⚙️)
static const CGFloat kTPKPickerFloatMargin  = 8.0;  // marge entre une pastille et le bord du picker
static const CGFloat kTPKPickerFloatGap     = 6.0;  // écart vertical entre 2 rangées de pastilles flottantes
static const CGFloat kTPKPickerSubcategoryGap = 4.0; // écart preview entre Channel/Global et les providers
static const CGFloat kTPKPickerSearchH      = 38.0; // hauteur de la capsule de recherche
// sectionInset.bottom = marge + onglets + écart + recherche + marge : aucune cellule cachée sous les flottants.
static const CGFloat kTPKPickerBottomZoneH  =
    kTPKPickerFloatMargin + kTPKPickerFloatSize + kTPKPickerFloatGap + kTPKPickerSearchH + kTPKPickerFloatMargin;

// Hauteur utile minimale : la zone basse (88 pt) plus une rangée d'emotes.
static const CGFloat kTPKPickerMinUsableH = 120.0;
// Place réservée au-dessus du picker (safe area + chat bar).
static const CGFloat kTPKPickerChromeReserveH = 120.0;
// (annulation lors du recyclage)
- (NSURLSession *)pickerImageSession {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ephemeral = isolation du sharedURLCache (videable par Twitch) → cache dédié ; @[] = pas de boucle.
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache                      = [TPKURLProtocol sharedEmoteCache];
        cfg.requestCachePolicy            = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses               = @[];
        cfg.HTTPMaximumConnectionsPerHost = 6;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

// ── Queue série pour le décodage des animations ───────────────────────────────
// CRITIQUE : queue SÉRIE (pas globale) — frame WebP 4x ≈ 160 Ko, 30×20 frames = spike ~100 Mo → OOM.
- (dispatch_queue_t)_animationDecodeQueue {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("tv.s7tv.anim-decode", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ── Décodage image pour le picker ─────────────────────────────────────────────
// wantsAnimated + showPickerAnimations → UIImage animée, sinon frame 0 seule (rapide, économe en RAM).
// ── Force-decode hors thread principal ─────────────────────────────────────
// Image "lazy" décompressée au 1er rendu (MAIN THREAD) → freeze : on redessine ici en bitmap.
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
            // Cap 24 frames — au-delà, gains nuls et RAM explose (frame 4x ≈ 160 Ko décompressés).
            NSUInteger maxFrames = MIN(count, 24);
            NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:maxFrames];
            NSTimeInterval duration = 0.0;

            for (NSUInteger i = 0; i < maxFrames; i++) {
                // @autoreleasepool : libère le CGImage après chaque itération → pic mémoire = 1 frame, pas N.
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

// À CHAQUE ouverture : applique l'avatar en cache ou lance le fetch — filet de sécurité si la chaîne a changé.
- (void)_tpk_refreshChannelAvatarIfNeeded {
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    if (!channelID.length) {
        [self _tpk_resetChannelButtonToPlaceholder];
        return;
    }

    // Source unique = TPKBadgeProvider (Helix, dédup, retry, cache) : plus de client Helix parallèle ici.
    id<TPKResolvedEmote> avatar = [[TPKBadgeProvider sharedProvider]
        resolvedChannelAvatarForChannelID:channelID];
    if (!avatar) {
        [self _tpk_resetChannelButtonToPlaceholder];
        return; // le provider publiera TPKBadgesCatalogUpdatedNotification
    }

    TPKEmoteImageCache *imageCache = [TPKEmoteImageCache sharedCache];
    UIImage *cached = [imageCache cachedImageForResolvedEmote:avatar];
    if (cached) {
        [self _tpk_applyChannelAvatarImage:cached];
        return;
    }

    [self _tpk_resetChannelButtonToPlaceholder];
    NSString *requestedChannelID = [channelID copy];
    __weak typeof(self) weakSelf = self;
    [imageCache imageForResolvedEmote:avatar completion:^(UIImage * _Nullable image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // Réponse tardive d'une ancienne chaîne ne doit pas remplacer l'avatar du salon courant.
        if (![[TPKManager sharedManager].currentChannelTwitchID
              isEqualToString:requestedChannelID]) return;
        [strongSelf _tpk_applyChannelAvatarImage:image];
    }];
}

// Ouvert avant la 1re GQL → premier Helix sans credentials : relancer à leur capture évite de rouvrir le picker.
- (void)_tpk_twitchCredentialsDidUpdate:(__unused NSNotification *)notification {
    self.pickerCatalogArraysDirty = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _tpk_refreshChannelAvatarIfNeeded];
    });
}

// URL Helix d'avatar dispo → on résout l'objet, puis le cache image partagé télécharge et décode.
- (void)_tpk_badgesCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _tpk_refreshChannelAvatarIfNeeded];
    });
}

- (void)_tpk_deviceOrientationDidChange:(__unused NSNotification *)notification {
    NSUInteger generation = ++self.pickerOrientationGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.pickerOrientationGeneration ||
            !strongSelf.emotePickerView || strongSelf.emotePickerView.hidden) return;
        // inputView perdu sans _hideEmotePicker : ne jamais relancer un aperçu flottant orphelin sur rotation.
        BOOL pickerAttachedAsInputView = strongSelf.emotePickerTextEntryView &&
            strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView;
        BOOL pickerVisibleAsWindowFallback = !strongSelf.emotePickerTextEntryView &&
            strongSelf.emotePickerView.window &&
            strongSelf.emotePickerView.superview == strongSelf.emotePickerView.window;
        if (!pickerAttachedAsInputView && !pickerVisibleAsWindowFallback) return;
        UIWindow *hostWindow = strongSelf.emotePickerTextField.window
            ?: strongSelf.emotePickerTextEntryView.window;
        CGFloat width = hostWindow.bounds.size.width;
        if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
        CGFloat targetHeight = [strongSelf _tpk_resolvedGridHeight];
        BOOL attachedAsInputView = strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView;
        CGFloat originY = 0;
        if (!attachedAsInputView && strongSelf.emotePickerView.superview == hostWindow) {
            // Fallback = vraie sous-vue de la fenêtre, pas un inputView : conserver l'ancrage bas après rotation.
            originY = MAX(hostWindow.safeAreaInsets.top,
                hostWindow.bounds.size.height - targetHeight - 56.0);
        }
        strongSelf.emotePickerView.frame = CGRectMake(0, originY, width, targetHeight);
        [strongSelf _tpk_relayoutPickerForSize:strongSelf.emotePickerView.bounds.size];
        if (strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView) {
            [strongSelf.emotePickerTextEntryView reloadInputViews];
        }
        if (strongSelf.pickerSizesPanelVisible) {
            [strongSelf _showFakeChatPreviewAboveInputView];
            // Le réglage affiché doit suivre l'orientation qui vient de changer.
            [strongSelf.sizesPanel tpk_syncPickerSizeRow];
        }
    });
}

// Cercle de `diameter` pts : en frame-based, UIButton ne redimensionne pas l'image (avatar 300x300).
- (UIImage *)_tpk_circularAvatarFromImage:(UIImage *)source diameter:(CGFloat)diameter {
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

// 22pt au lieu de 28 : marge cohérente avec le placeholder (14pt) et le logo voisin ; 30pt collait aux bords.
static const CGFloat kTPKPickerAvatarDiameter = 22.0;

- (void)_tpk_applyChannelAvatarImage:(UIImage *)image {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn || !image) return;
    UIImage *circular = [self _tpk_circularAvatarFromImage:image diameter:kTPKPickerAvatarDiameter];
    if (!circular) return;
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[circular imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
          forState:UIControlStateNormal];
}

// Fallback propre — remet le symbole d'origine (mêmes réglages qu'à la création).
- (void)_tpk_resetChannelButtonToPlaceholder {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn) return;
    UIImageSymbolConfiguration *avCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:avCfg]
          forState:UIControlStateNormal];
}

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    // Appel synchrone (déjà main thread) : dispatch_async laissait UIKit résigner avant reloadInputViews.

    // ── Invalider le cache si le TextEntryView n'est plus dans une fenêtre ──
    // Changement de channel = hiérarchie reconstruite : vue orpheline, BFS skippé → picker jamais affiché.
    if (self.emotePickerTextEntryView && !self.emotePickerTextEntryView.window) {
        [[TPKManager sharedManager] log:@"⚠️ emotePickerTextEntryView orphelin (window=nil) → reset cache"];
        self.emotePickerTextEntryView = nil;
    }

    // ── Trouver le champ de saisie (UITextView RN) via BFS ──────────────────
    if (!self.emotePickerTextEntryView && chatInputView) {
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:chatInputView];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            if ([v isKindOfClass:[UITextView class]]) {
                self.emotePickerTextEntryView = (UITextView *)v;
                [[TPKManager sharedManager] log:@"⚠️ TextEntryView UITextView: %@", NSStringFromClass([v class])];
                break;
            }
        }
    }

    // ── Basculer : picker déjà affiché → retirer ────────────────────────────
    // GUARD emotePickerView non-nil : sans lui, 1er tap → _hideEmotePicker avant création → bug d'ouverture.
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
    // Toute relayout différée (rotation) devient obsolète dès que le picker est fermé.
    self.pickerOrientationGeneration += 1;
    [self _tpk_deactivateVisiblePickerAnimations];
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Nettoyer inputView même sans window ; resign/reload sans fenêtre → UIKit crashe.
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
    self.pickerSearchAlertActive = NO;
    self.pickerOrientationGeneration += 1;
    [self _tpk_deactivateVisiblePickerAnimations];
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setDecodingSuspended:NO];
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
    // Ancienne ChatInputView survivante : son didMoveToWindow:nil ne doit pas fermer le picker de la nouvelle chaîne.
    if (self.emotePickerTextField && self.emotePickerTextField != chatInputView) return;
    [self cleanupPickerForStreamClose];
}

// Compatibility hook for older builds: sorting now comes from the provider-aware catalogue.
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
    NSAssert([NSThread isMainThread], @"TPKEmotePickerController: main thread uniquement");
    self.pickerCatalogArraysDirty = YES;
    [self _tpk_reloadCatalogSnapshotReloadCollection:
        (self.emotePickerView && !self.emotePickerView.hidden)];
}

- (TPKEmote *)_pickerEmoteForDescriptor:(TPKEmoteDescriptor *)descriptor {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    return [[TPKPickerCatalogEmote alloc] initWithDescriptor:descriptor];
}

static NSString *TPKPickerStableEmoteKey(TPKEmote *emote) {
    if (!emote.emoteID.length) return @"";
    if ([emote isKindOfClass:[TPKPickerCatalogEmote class]]) {
        TPKEmoteDescriptor *descriptor = [(TPKPickerCatalogEmote *)emote descriptor];
        if (descriptor.emoteID.length)
            return TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
    }
    return TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emote.emoteID);
}

// Tri historique : emotes carrées d'abord, puis aire croissante, puis nom ; aucun champ provider dans l'onglet agrégé.
static NSComparisonResult TPKPickerCompareEmotes(id firstObject,
                                                   id secondObject,
                                                   BOOL includeProviderTieBreak) {
    TPKEmote *a = (TPKEmote *)firstObject;
    TPKEmote *b = (TPKEmote *)secondObject;
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
        if ([a isKindOfClass:[TPKPickerCatalogEmote class]])
            aProvider = [(TPKPickerCatalogEmote *)a descriptor].provider;
        if ([b isKindOfClass:[TPKPickerCatalogEmote class]])
            bProvider = [(TPKPickerCatalogEmote *)b descriptor].provider;
        if (aProvider < bProvider) return NSOrderedAscending;
        if (aProvider > bProvider) return NSOrderedDescending;
    }

    return [(a.emoteID ?: @"") compare:(b.emoteID ?: @"")
        options:NSCaseInsensitiveSearch | NSNumericSearch];
}

static NSComparator TPKPickerEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return TPKPickerCompareEmotes(firstObject, secondObject, YES);
};

static NSComparator TPKPickerMixedEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return TPKPickerCompareEmotes(firstObject, secondObject, NO);
};

// Logos 400px : rasterize at the 28pt slot size, else BTTV/FFZ look bigger than 7TV/star.
static UIImage *TPKPickerScaledProviderLogo(UIImage *image, CGFloat pointSize) {
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

// Logos larges : inscrit sans étirer (letterbox transparent).
static UIImage *TPKPickerAspectFitProviderLogo(UIImage *image, CGFloat maxWidth, CGFloat maxHeight) {
    if (!image || maxWidth <= 0 || maxHeight <= 0) return image;
    CGSize src = image.size;
    if (src.width <= 0 || src.height <= 0) return image;
    CGFloat ratio = MIN(maxWidth / src.width, maxHeight / src.height);
    CGSize dst = CGSizeMake(src.width * ratio, src.height * ratio);
    CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 2.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(maxWidth, maxHeight) format:format];
    UIImage *fitted = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((maxWidth - dst.width) / 2.0,
                                     (maxHeight - dst.height) / 2.0,
                                     dst.width, dst.height)];
    }];
    return [fitted imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)_tpk_applyProviderCatalogArrays {
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    // Sync UI prefs (text ids) with the catalogue (numeric enum) before building the grid.
    NSDictionary *enabledSettings = @{
        @(TPKEmoteProviderIDTPK): @([TPKEmoteProviderSettings isProviderEnabled:TPKExternalEmoteProvider7TV]),
        @(TPKEmoteProviderIDBTTV): @([TPKEmoteProviderSettings isProviderEnabled:TPKExternalEmoteProviderBTTV]),
        @(TPKEmoteProviderIDFFZ): @([TPKEmoteProviderSettings isProviderEnabled:TPKExternalEmoteProviderFFZ]),
    };
    if (![catalog.providerEnabled isEqualToDictionary:enabledSettings])
        catalog.providerEnabled = enabledSettings;
    NSArray<NSString *> *priority = [TPKEmoteProviderSettings providerPriority];
    NSMutableArray *numericPriority = [NSMutableArray array];
    for (NSString *identifier in priority)
        [numericPriority addObject:@(TPKEmoteProviderFromIdentifier(identifier))];
    if (![catalog.providerPriority isEqualToArray:numericPriority])
        catalog.providerPriority = numericPriority;
    NSMutableDictionary *providerArrays = [NSMutableDictionary dictionary];
    NSMutableDictionary *providerSections = [NSMutableDictionary dictionary];
    NSMutableArray *favorites = [NSMutableArray array];
    NSMutableSet *seenFavoriteKeys = [NSMutableSet set];
    NSMutableSet *currentCatalogKeys = [NSMutableSet set];
    // Favoris lus une seule fois : l'ancien appel par émote relisait UserDefaults à chaque emote et bloquait le thread principal.
    NSSet<NSString *> *favoriteKeySet = [NSSet setWithArray:[catalog favoriteKeysSnapshot]];
    self.pickerFavoriteKeySet = favoriteKeySet;
    BOOL hasSyntheticProviderState = NO;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        NSMutableArray *items = [NSMutableArray array];
        NSMutableDictionary<NSString *, TPKEmote *> *itemsByID = [NSMutableDictionary dictionary];
        NSMutableArray<TPKPickerDisplaySection *> *displaySections = [NSMutableArray array];
        TPKEmoteProviderSnapshot *snapshot =
            [catalog snapshotForProvider:(TPKEmoteProviderID)provider];
        BOOL providerLoading = snapshot.state == TPKEmoteProviderStateLoading;
        NSString *providerError = snapshot.state == TPKEmoteProviderStateError
            ? snapshot.errorMessage : nil;
        if (![catalog.providerEnabled[@(provider)] boolValue]) {
            providerArrays[@(provider)] = @[];
            providerSections[@(provider)] = @[];
            continue;
        }
        // Idle -> Loading runs on a serial queue: show a local loading section so the first open isn't the flat 7TV grid or an empty picker.
        if (snapshot.state == TPKEmoteProviderStateIdle &&
            snapshot.sections.count == 0) {
            TPKPickerDisplaySection *initialLoading = [TPKPickerDisplaySection new];
            initialLoading.provider = (TPKEmoteProviderID)provider;
            initialLoading.kind = TPKEmoteSectionKindSet;
            initialLoading.identifier = @"provider-state";
            initialLoading.title = TPKEmoteProviderName((TPKEmoteProviderID)provider);
            initialLoading.items = @[];
            initialLoading.loaded = NO;
            initialLoading.loading = YES;
            initialLoading.empty = NO;
            [displaySections addObject:initialLoading];
            hasSyntheticProviderState = YES;
        }
        for (TPKEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(TPKEmoteProviderID)provider]) {
            TPKEmote *item = [self _pickerEmoteForDescriptor:descriptor];
            if (!item) continue;
            NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
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
        for (TPKEmoteSection *section in
             [catalog sectionsForProvider:(TPKEmoteProviderID)provider]) {
            NSMutableArray<TPKEmote *> *sectionItems = [NSMutableArray array];
            for (TPKEmoteDescriptor *descriptor in section.emotes) {
                NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
                TPKEmote *item = itemsByID[stableKey];
                if (item && ![sectionItems containsObject:item]) [sectionItems addObject:item];
            }
            [sectionItems sortUsingComparator:TPKPickerEmoteSizeComparator];
            // Loaded empty sections are hidden; loading/error ones stay visible so the user can retry without changing tab or scrolling.
            if (!sectionItems.count && section.loaded && !section.loading && !section.errorMessage.length)
                continue;
            TPKPickerDisplaySection *display = [TPKPickerDisplaySection new];
            display.provider = section.provider;
            display.kind = section.kind;
            display.identifier = section.identifier ?: @"";
            display.title = section.title.length ? section.title : @"Emotes";
            display.items = sectionItems.copy;
            display.loaded = section.loaded;
            // A provider snapshot can fail while a cached section remains: keep it visible, state exposed in the header, retry not hidden.
            display.loading = section.loading || providerLoading;
            display.empty = NO;
            display.errorMessage = section.errorMessage ?: providerError;
            [displaySections addObject:display];
        }
        [items sortUsingComparator:TPKPickerEmoteSizeComparator];
        providerArrays[@(provider)] = items.copy;
        providerSections[@(provider)] = displaySections.copy;
    }
    // Skip favorites absent from the current snapshots: an old channel emote can't render here; current global emotes stay eligible.
    for (TPKEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        if (![catalog.providerEnabled[@(descriptor.provider)] boolValue]) continue;
        NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
        if (![currentCatalogKeys containsObject:stableKey]) continue;
        if (!stableKey.length || [seenFavoriteKeys containsObject:stableKey]) continue;
        TPKEmote *item = [self _pickerEmoteForDescriptor:descriptor];
        if (!item) continue;
        [seenFavoriteKeys addObject:stableKey];
        [favorites addObject:item];
    }
    [favorites sortUsingComparator:TPKPickerEmoteSizeComparator];
    BOOL hasProviderEmotes = NO;
    for (NSArray *items in providerArrays.allValues) {
        if (items.count) { hasProviderEmotes = YES; break; }
    }
    BOOL hasProviderState = hasSyntheticProviderState;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        TPKEmoteProviderState state =
            [catalog snapshotForProvider:(TPKEmoteProviderID)provider].state;
        if (state != TPKEmoteProviderStateIdle) { hasProviderState = YES; break; }
    }
    // Keep provider tabs active even with no emotes yet; if the catalogue hasn't started, don't pass legacy 7TV cache as BTTV/FFZ.
    BOOL hasDisabledProvider = NO;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        if (![catalog.providerEnabled[@(provider)] boolValue]) {
            hasDisabledProvider = YES;
            break;
        }
    }
    BOOL useProviderCatalog = hasProviderEmotes || hasProviderState || hasDisabledProvider;
    self.pickerProviderEmotes = useProviderCatalog ? providerArrays.copy : @{};
    self.pickerProviderSections = useProviderCatalog ? providerSections.copy : @{};
    self.pickerCatalogFavorites = favorites.copy;
    // Keep the legacy favorite array in sync: a favorite removed while open must not leave a stale item pinning the Favorites tab.
    if (useProviderCatalog) self.emotePickerFavoriteEmotes = favorites.copy;
    self.pickerCatalogArraysDirty = NO;
    [self _tpk_normalizeActivePickerTab];
}

- (void)_tpk_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection {
    NSAssert([NSThread isMainThread], @"Le snapshot du picker touche UIKit");
    UICollectionView *collectionView = self.emoteCollectionView;
    NSString *anchorEmoteKey = nil;
    CGFloat anchorViewportY = 0;
    CGPoint previousOffset = collectionView.contentOffset;
    if (reloadCollection && collectionView && !collectionView.hidden) {
        NSArray<NSIndexPath *> *visible = [collectionView.indexPathsForVisibleItems
            sortedArrayUsingSelector:@selector(compare:)];
        NSIndexPath *anchorPath = visible.firstObject;
        TPKEmote *anchorEmote = anchorPath
            ? [self _emoteForIndexPath:anchorPath] : nil;
        UICollectionViewLayoutAttributes *attributes = anchorPath
            ? [collectionView layoutAttributesForItemAtIndexPath:anchorPath] : nil;
        NSString *stableAnchorKey = TPKPickerStableEmoteKey(anchorEmote);
        if (stableAnchorKey.length && attributes) {
            anchorEmoteKey = [stableAnchorKey copy];
            anchorViewportY = CGRectGetMinY(attributes.frame) - collectionView.contentOffset.y;
        }
    }

    // Les snapshots provider-aware sont la seule source de vérité du picker.
    if (self.pickerCatalogArraysDirty || !self.pickerProviderSections.count)
        [self _tpk_applyProviderCatalogArrays];
    // Snapshots may finish out of order: re-check the initial empty tab after each merge so BTTV/FFZ appear; no-op once a tab is chosen.
    [self _tpk_selectInitialProviderIfNeeded];
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
        [self _tpk_deactivateVisiblePickerAnimations];
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
                    TPKPickerDisplaySection *section =
                        self.pickerDisplaySections[(NSUInteger)sectionIndex];
                    NSString *sectionKey = [self _tpk_displaySectionKey:section];
                    if ([self.pickerCollapsedSections[sectionKey] boolValue]) continue;
                    NSUInteger itemIndex = [section.items indexOfObjectPassingTest:
                        ^BOOL(TPKEmote *emote, __unused NSUInteger index, __unused BOOL *stop) {
                            return [TPKPickerStableEmoteKey(emote)
                                isEqualToString:anchorEmoteKey];
                        }];
                    if (itemIndex != NSNotFound)
                        newPath = [NSIndexPath indexPathForItem:(NSInteger)itemIndex
                                                      inSection:sectionIndex];
                }
            } else {
                NSUInteger newIndex = [self.emotePickerEmotes
                    indexOfObjectPassingTest:^BOOL(TPKEmote *emote,
                                                    __unused NSUInteger index,
                                                    __unused BOOL *stop) {
                        return [TPKPickerStableEmoteKey(emote)
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

- (void)_tpk_applyCatalogUpdateNow {
    self.pickerCatalogReloadPending = NO;
    [self _tpk_reloadCatalogSnapshotReloadCollection:YES];
    if (self.pickerSizesPanelVisible && self->_sizesPanel) {
        [self->_sizesPanel loadRealPreviewAssetsIfNeeded];
    }
    [self.emoteCollectionView layoutIfNeeded];
}

- (void)_tpk_emoteCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pickerCatalogArraysDirty = YES;
        [self invalidateSortCache];
        if (!self.emotePickerView || self.emotePickerView.hidden) return;
        if (self.pickerScrollInProgress || self.emoteCollectionView.isTracking ||
            self.emoteCollectionView.isDragging || self.emoteCollectionView.isDecelerating) {
            self.pickerCatalogReloadPending = YES;
            return;
        }
        [self _tpk_applyCatalogUpdateNow];
        [self _tpk_activateVisiblePickerAnimations];
    });
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // Une notification différée pendant un ancien scroll ne doit pas survivre à la fermeture : l'ouverture reconstruit le snapshot.
    self.pickerCatalogReloadPending = NO;
    // Réinitialiser l'état AVANT le premier snapshot : sinon pickerPreSearchTab restaurait l'onglet d'avant sur une requête vide.
    self.emoteSearchField.text = @"";
    self.pickerIsSearching = NO;
    // Apply the opening choice before any provider notification; without one, keep the historical fallback (Favorites then first provider).
    self.pickerOpeningLocationExplicit = [self _tpk_applyConfiguredPickerOpeningLocation];
    self.pickerInitialProviderSelectionPending = !self.pickerOpeningLocationExplicit;
    if (!self.pickerOpeningLocationExplicit) {
        self.pickerActiveTab = [TPKEmoteProviderSettings mixedPickerEnabled]
            ? TPKPickerTabAll : TPKPickerTabTPK;
    }

    // Build the cache-first snapshot before scheduling requests: the parser can run off the state queue; layout never waits on network.
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    [self _tpk_reloadCatalogSnapshotReloadCollection:NO];

    // Déclencher les trois providers après le snapshot : le cache s'affiche déjà, les notifications remplacent les cellules sans bloquer.
    [catalog loadGlobalProviders];
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    if (channelID.length) [catalog loadChannelProvidersForTwitchID:channelID];

    // ── Onglet de départ : Favoris s'il y a un favori de la chaîne courante, sinon 7TV/Channel — revérifié à CHAQUE ouverture.
    if (!self.pickerOpeningLocationExplicit &&
        (self.pickerCatalogFavorites.count > 0 || self.emotePickerFavoriteEmotes.count > 0)) {
        self.pickerActiveTab = TPKPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
    }
    // Called again here for the synchronous/cache-hit path: initial selection stays deterministic before the picker view exists.
    [self _tpk_selectInitialProviderIfNeeded];
    [self _tpk_normalizeActivePickerTab];
    [self _updatePickerArraysForSearch:@""]; // recalcule emotePickerEmotes pour l'onglet choisi

    // ── Créer le picker si besoin ─────────────────────────────────────
    // Recalcule la taille à chaque ouverture pour s'adapter à l'orientation courante.
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGFloat pickerH = [self _tpk_resolvedGridHeight];
    CGRect pickerFrame = CGRectMake(0, 0, screenSz.width, pickerH);
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame];
    } else if (self.pickerSizesPanelVisible) {
        // Picker laissé sur le panneau des tailles → retour systématique en mode grille à l'ouverture (état initial, sans animation).
        self.pickerSizesPanelVisible = NO;
        self.sizesPanel.panelView.hidden = YES;
        self.emoteCollectionView.hidden = NO;
        self.pickerSearchCapsuleView.hidden = NO;
        self.pickerTabCapsuleView.hidden = NO;
        self.pickerSubcategoryCapsuleView.hidden = NO;
        [self _tpk_updatePickerTabButtonLayout];
        self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        // Remettre l'icône ⚙️ (pas juste la couleur) : sinon le bouton gardait la flèche "retour" du panneau des tailles.
        UIImageSymbolConfiguration *resetCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        [self.pickerSizesToggleBtn setImage:[UIImage systemImageNamed:@"textformat.size"
                                                      withConfiguration:resetCfg]
                                    forState:UIControlStateNormal];
    }
    self.emotePickerView.frame = pickerFrame;
    // Revérifie l'avatar de chaîne à CHAQUE ouverture : seul filet si la chaîne a changé, sans fetch si le catalogue est à jour.
    [self _tpk_refreshChannelAvatarIfNeeded];
    // Repositionne grille / pastilles / panneau selon l'orientation et l'onglet, et resynchronise surlignage + capsule sous-choix.
    [self _tpk_relayoutPickerForSize:pickerFrame.size];

    // Reset la recherche
    self.emoteSearchField.text = @"";
    [self _tpk_updateSearchClearVisibility];
    [self _updatePickerArraysForSearch:@""];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    // Collection view pas encore présentée → contentSize non garanti, setContentOffset = no-op : on force le layout d'abord.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView layoutIfNeeded];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];

    // ── inputView = picker (keyboard-replacement mode) ──────────────────────
    // Clavier remplacé : picker = inputView sous la chat bar, TextEntryView garde firstResponder.
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        // Étape 1 : le picker DEVIENT le clavier (affiché en dessous de la chat bar)
        self.emotePickerView.hidden = NO;
        self.emotePickerView.translatesAutoresizingMaskIntoConstraints = NO;
        tv.inputView = self.emotePickerView;
        tv.inputAccessoryView = nil;
        // Étape 2 : devenir firstResponder → UIKit affiche inputView (notre picker)
        if (!tv.isFirstResponder) {
            [tv becomeFirstResponder];
        }
        // Étape 3 : recharger pour appliquer le nouvel inputView
        [tv reloadInputViews];
        // Étape 4 : ré-imposer l'offset en haut APRÈS présentation — reloadInputViews relayoute et annule le setContentOffset précédent.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.emoteCollectionView) return;
            [strongSelf.emoteCollectionView setContentOffset:CGPointZero animated:NO];
            [strongSelf _tpk_activateVisiblePickerAnimations];
        });
    } else {
        [[TPKManager sharedManager] log:@"⚠️ TextEntryView nil — fallback fenêtre flottante"];
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (keyWindow) {
            // Sous-vie de fenêtre : plus d'inputView, donc retour au frame-based.
            self.emotePickerView.translatesAutoresizingMaskIntoConstraints = YES;
            CGFloat ph = [self _tpk_resolvedGridHeight];
            self.emotePickerView.frame = CGRectMake(0,
                keyWindow.bounds.size.height - ph - 56,
                keyWindow.bounds.size.width, ph);
            [keyWindow addSubview:self.emotePickerView];
            self.emotePickerView.hidden = NO;
            [self _tpk_relayoutPickerForSize:self.emotePickerView.bounds.size];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _tpk_activateVisiblePickerAnimations];
            });
        }
    }
}
- (void)_createEmotePickerViewWithFrame:(CGRect)frame {

    // ── Palette ─────────────────────────────────────────────────────────
    // bgColor = fond le plus sombre, cardColor = cellules + pastilles, accent = Twitch. Fond réel #0E0E10 légèrement bleuté, pas gris pur.
    UIColor *bgColor   = tpk_pickerBgColor();
    UIColor *cardColor = tpk_pickerCardColor();
    UIColor *sepColor  = tpk_pickerSepColor();
    UIColor *textColor = [UIColor whiteColor];
    UIColor *subColor  = [UIColor colorWithWhite:0.55 alpha:1.0];
    UIColor *accent    = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];    // violet Twitch

    // ── Conteneur principal ────────────────────────────────────────────────
    TPKPickerContainerView *picker =
        [[TPKPickerContainerView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    self.emotePickerView = picker;

    __weak typeof(self) weakSelf = self;
    __weak TPKPickerContainerView *weakPicker = picker;
    picker.didAttachToWindow = ^{
        // didMoveToWindow précède la fin du layout du clavier : le passage main-queue suivant crée les cellules et réactive leur chargement.
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            TPKPickerContainerView *strongPicker = weakPicker;
            if (!strongSelf || !strongPicker.window ||
                strongSelf.emotePickerView != strongPicker || strongPicker.hidden) return;
            [strongSelf.emoteCollectionView layoutIfNeeded];
            [strongSelf _tpk_activateVisiblePickerAnimations];
        });
    };

    // ── Collection View — occupe 100% du picker ─────────────────────────────
    // Pas de bandeaux opaques : layout.sectionInset réserve la place sous les pastilles, plus fiable qu'un contentInset/offset manuel.
    CGFloat topInset = kTPKPickerFloatMargin; // marge mini : 1ère ligne sous les pastilles (z-order).
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection         = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 3;
    layout.minimumLineSpacing      = 3;
    layout.sectionInset            = UIEdgeInsetsMake(topInset, 6, kTPKPickerBottomZoneH, 6);
    // Sous-catégories = capsules flottantes : aucune ligne d'en-tête réservée dans la grille.
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
    // Aucun préchargement : cellFor/willDisplay restent les seules portes du pipeline image, pas d'activation anticipée hors écran.
    if (@available(iOS 10.0, *)) cv.prefetchingEnabled = NO;

    [cv registerClass:[TPKEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellID];
    [cv registerClass:[TPKPickerSectionHeaderView class]
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
           withReuseIdentifier:@"TPKPickerSectionHeader"];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    // ── Capsule provider (flottante, bas gauche) — Favoris / Tous / 7TV / BTTV / FFZ ──
    BOOL mixedPicker = [TPKEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kTPKPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    CGFloat bottomRowY = frame.size.height - kTPKPickerFloatMargin - kTPKPickerSearchH
                          - kTPKPickerFloatGap - kTPKPickerFloatSize;
    UIView *tabCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin, bottomRowY, tabCapsuleW, kTPKPickerFloatSize)];
    tabCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    tabCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    tabCapsule.clipsToBounds = YES;
    tabCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerTabCapsuleView = tabCapsule;
    [picker addSubview:tabCapsule];

    UIView *tabIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize)];
    tabIndicator.backgroundColor = accent;
    tabIndicator.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    [tabCapsule addSubview:tabIndicator];
    self.pickerTabIndicatorView = tabIndicator;

    NSData *_tabLogoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_tabLogoImg = [[UIImage imageWithData:_tabLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    NSData *_bttvLogoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKBTTVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_bttvLogoImg = [[UIImage imageWithData:_bttvLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    NSData *_ffzLogoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKFFZLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_ffzLogoImg = [[UIImage imageWithData:_ffzLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    // BTTV/FFZ assets are optically smaller than the 7TV mark at the same point size: tiny boost, capsule and touch target unchanged.
    UIImage *bttvLogo = TPKPickerScaledProviderLogo(_bttvLogoImg, 16.0);
    UIImage *ffzLogo = TPKPickerScaledProviderLogo(_ffzLogoImg, 16.0);
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
    favBtn.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
    favBtn.tag = TPKPickerTabFavorites;
    [favBtn setImage:[UIImage systemImageNamed:@"star.fill" withConfiguration:starCfg] forState:UIControlStateNormal];
    [favBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:favBtn];
    [self.pickerTabButtons addObject:favBtn];

    // Bouton 2 — Tous (logo TwitchPlusK).
    UIButton *allBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    allBtn.frame = CGRectMake(kTPKPickerFloatSize, 0,
                              kTPKPickerFloatSize, kTPKPickerFloatSize);
    allBtn.tag = TPKPickerTabAll;
    NSData *tpkData = [[NSData alloc]
        initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *tpkLogo = TPKPickerAspectFitProviderLogo(
        [UIImage imageWithData:tpkData scale:UIScreen.mainScreen.scale], 22.0, 14.0);
    if (!tpkLogo) {
        UIImageSymbolConfiguration *allCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        tpkLogo = [UIImage systemImageNamed:@"square.stack.3d.up.fill"
                              withConfiguration:allCfg];
    }
    [allBtn setImage:tpkLogo forState:UIControlStateNormal];
    allBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [allBtn addTarget:self action:@selector(_pickerTabTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:allBtn];
    [self.pickerTabButtons addObject:allBtn];

    // Bouton 3 — 7TV (logo provider).
    UIButton *channelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    channelBtn.frame = CGRectMake(kTPKPickerFloatSize * 2.0, 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
    channelBtn.tag = TPKPickerTabTPK;
    [channelBtn setImage:_tabLogoImg forState:UIControlStateNormal];
    channelBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [channelBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:channelBtn];
    [self.pickerTabButtons addObject:channelBtn];
    // Boutons 4/5 — BTTV et FFZ : logos embarqués localement, SF Symbols en fallback si une image est invalide.
    NSArray *providerButtons = @[
        @[@(TPKPickerTabBTTV), bttvLogo ?: bttvFallback],
        @[@(TPKPickerTabFFZ), ffzLogo ?: ffzFallback],
    ];
    for (NSUInteger idx = 0; idx < providerButtons.count; idx++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(kTPKPickerFloatSize * (idx + 3), 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
        button.tag = [providerButtons[idx][0] integerValue];
        [button setImage:providerButtons[idx][1] forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [button addTarget:self action:@selector(_pickerTabTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [tabCapsule addSubview:button];
        [self.pickerTabButtons addObject:button];
    }

    // ── Capsule sous-catégories (au-dessus de la capsule provider) — Channel/Global : position fixe, Shared et sets agrégés.
    UIView *subcategoryCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin,
                   bottomRowY - kTPKPickerSubcategoryGap - kTPKPickerFloatSize,
                   kTPKPickerFloatSize * 2.0,
                   kTPKPickerFloatSize)];
    subcategoryCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    subcategoryCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    subcategoryCapsule.clipsToBounds = YES;
    subcategoryCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerSubcategoryCapsuleView = subcategoryCapsule;
    [picker addSubview:subcategoryCapsule];

    UIButton *subcategoryChannel = [UIButton buttonWithType:UIButtonTypeSystem];
    subcategoryChannel.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
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
    subcategoryGlobal.frame = CGRectMake(kTPKPickerFloatSize, 0,
                                         kTPKPickerFloatSize,
                                         kTPKPickerFloatSize);
    subcategoryGlobal.tag = 2;
    subcategoryGlobal.accessibilityLabel = @"Global emotes";
    subcategoryGlobal.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [subcategoryGlobal addTarget:self action:@selector(_pickerSubcategoryTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    [subcategoryCapsule addSubview:subcategoryGlobal];
    self.pickerSubcategoryGlobalBtn = subcategoryGlobal;
    [self _tpk_resetChannelButtonToPlaceholder];

    [self _tpk_updateTabButtonHighlight];

    // ── Capsule tailles/réglages (bas droite) : un seul fond pilule pour les 2 boutons, comme les capsules d'onglets/sous-choix.
    CGFloat toolsCapsuleW = kTPKPickerFloatSize * 2.0;
    UIView *toolsCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(frame.size.width - kTPKPickerFloatMargin - toolsCapsuleW, bottomRowY,
                   toolsCapsuleW, kTPKPickerFloatSize)];
    toolsCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    toolsCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    toolsCapsule.clipsToBounds = YES;
    toolsCapsule.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.pickerToolsCapsuleView = toolsCapsule;
    [picker addSubview:toolsCapsule];

    // Bouton réglages — slot gauche : même écran que le bouton 7TV (presentSettingsMenu), le picker fermant d'abord.
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
    UIImageSymbolConfiguration *settingsCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:settingsCfg]
                 forState:UIControlStateNormal];
    settingsBtn.tintColor = subColor;
    [settingsBtn addTarget:self action:@selector(_pickerSettingsTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:settingsBtn];
    self.pickerSettingsBtn = settingsBtn;

    // Bouton tailles — slot droit (vers le bord) : icône "taille de texte", explicite sur la fonction plutôt qu'un engrenage générique.
    UIButton *gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gearBtn.frame = CGRectMake(kTPKPickerFloatSize, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
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
    CGFloat searchY = frame.size.height - kTPKPickerFloatMargin - kTPKPickerSearchH;
    UIView *searchCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin, searchY, frame.size.width - kTPKPickerFloatMargin * 2, kTPKPickerSearchH)];
    searchCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    searchCapsule.layer.cornerRadius = kTPKPickerSearchH / 2.0;
    searchCapsule.clipsToBounds = YES;
    searchCapsule.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.pickerSearchCapsuleView = searchCapsule;
    [picker addSubview:searchCapsule];

    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(0, 0, searchCapsule.bounds.size.width, kTPKPickerSearchH)];
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

    // Croix à droite pour vider le champ d'un tap (point 4) — visible seulement si texte, voir _tpk_updateSearchClearVisibility.
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(0, 0, 28, kTPKPickerSearchH);
    UIImageSymbolConfiguration *clearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [clearBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:clearCfg]
              forState:UIControlStateNormal];
    clearBtn.tintColor = subColor;
    clearBtn.hidden = YES;
    [clearBtn addTarget:self action:@selector(_pickerSearchClearTapped)
       forControlEvents:UIControlEventTouchUpInside];
    self.pickerSearchClearBtn = clearBtn;
    UIView *searchRightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, kTPKPickerSearchH)];
    clearBtn.frame = CGRectMake(2, 0, 28, kTPKPickerSearchH);
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
    // Délégué à TPKPickerSizesPanel (lignes/sliders/previews dans `picker`) ; le picker garde affichage et redimensionnement.
    [self.sizesPanel buildInView:picker
                            frame:frame
                          bgColor:bgColor
                        textColor:textColor
                         subColor:subColor
                         sepColor:sepColor
                           accent:accent
                        cardColor:cardColor];

    // Hauteur des cellules = tailles configurées (cfg.gifSize) : le faux chat prévient après chaque passe de self-sizing.
    __weak typeof(self) previewWeakSelf = self;
    self.sizesPanel.fakeChatView.onContentHeightChanged =
        ^(__unused TPKChatCustomView *view) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(previewWeakSelf) strongSelf = previewWeakSelf;
            if (!strongSelf || !strongSelf.pickerSizesPanelVisible) return;
            [strongSelf _showFakeChatPreviewAboveInputView];
        });
    };

    // Point 3 — vraie cause du "pas de bouton pour fermer" : sizesPanel opaque recouvre toolsCapsule et intercepte ses taps → 1er plan.
    [picker bringSubviewToFront:tabCapsule];
    [picker bringSubviewToFront:subcategoryCapsule];
    [picker bringSubviewToFront:toolsCapsule];

    // NOTE: pas d'addSubview ici — la vue est attachée via inputView (remplace le clavier)
}

// Pastille flottante ronde générique (carte translucide) — fermer et ⚙️ ; capsules multi-éléments construites à la main, même style.
- (UIButton *)_tpk_makeFloatingPillWithFrame:(CGRect)frame cardColor:(UIColor *)cardColor {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    btn.layer.cornerRadius = frame.size.height / 2.0;
    btn.clipsToBounds = YES;
    return btn;
}

// ── Barre d'onglets — helpers ────────────────────────────────────────────

// Keep the selected tab valid when a provider is disabled or the catalogue is legacy-only; works while the picker is visible.
// Le mode mixte ne recrée pas les vues : 5 boutons créés une fois, capsule compactée, boutons incompatibles masqués (tags stables).
- (void)_tpk_updatePickerTabButtonLayout {
    if (!self.pickerTabCapsuleView || !self.pickerTabButtons.count) return;

    BOOL mixedMode = [TPKEmoteProviderSettings mixedPickerEnabled];
    NSArray<NSNumber *> *visibleTags = mixedMode
        ? @[@(TPKPickerTabFavorites), @(TPKPickerTabAll)]
        : @[@(TPKPickerTabFavorites), @(TPKPickerTabTPK),
            @(TPKPickerTabBTTV), @(TPKPickerTabFFZ)];
    NSInteger slot = 0;
    for (UIButton *button in self.pickerTabButtons) {
        BOOL visible = [visibleTags containsObject:@(button.tag)];
        button.hidden = !visible;
        if (!visible) continue;
        button.frame = CGRectMake(kTPKPickerFloatSize * slot, 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
        slot++;
    }

    CGRect capsuleFrame = self.pickerTabCapsuleView.frame;
    capsuleFrame.size.width = kTPKPickerFloatSize * slot;
    self.pickerTabCapsuleView.frame = capsuleFrame;
}

- (void)_tpk_normalizeActivePickerTab {
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    BOOL mixedMode = [TPKEmoteProviderSettings mixedPickerEnabled];
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    BOOL (^available)(NSInteger) = ^BOOL(NSInteger tab) {
        // Do not keep an empty Favorites tab selected: returning NO lets the provider order choose a useful tab (even one loading).
        if (tab == TPKPickerTabFavorites)
            return self.pickerCatalogFavorites.count > 0 ||
                   self.emotePickerFavoriteEmotes.count > 0;
        if (tab == TPKPickerTabAll) {
            if (!mixedMode) return NO;
            if (!providerMode && !self.pickerOpeningLocationExplicit &&
                !self.emotePickerAllEmotes.count) return NO;
            for (NSNumber *provider in [self _tpk_providerIDsInPriorityOrder]) {
                if ([catalog.providerEnabled[provider] boolValue]) return YES;
            }
            return NO;
        }
        if (mixedMode || ![self _tpk_pickerTabIsProvider:tab]) return NO;
        NSInteger provider = tab == TPKPickerTabTPK
            ? TPKEmoteProviderIDTPK
            : (tab == TPKPickerTabBTTV ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
        if (![catalog.providerEnabled[@(provider)] boolValue]) return NO;
        // A legacy cache only contains 7TV: do not show those objects under BTTV/FFZ while their own catalogue is still idle.
        return providerMode || self.pickerOpeningLocationExplicit ||
            provider == TPKEmoteProviderIDTPK;
    };

    if (available(self.pickerActiveTab)) return;
    NSInteger fallback = TPKPickerTabFavorites;
    if (!(self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count)) {
        if (mixedMode && available(TPKPickerTabAll)) {
            fallback = TPKPickerTabAll;
        } else {
        for (NSString *identifier in [TPKEmoteProviderSettings providerPriority]) {
            TPKExternalEmoteProvider provider = TPKEmoteProviderFromIdentifier(identifier);
            NSInteger tab = provider == TPKExternalEmoteProvider7TV
                ? TPKPickerTabTPK
                : (provider == TPKExternalEmoteProviderBTTV
                   ? TPKPickerTabBTTV : TPKPickerTabFFZ);
            if (available(tab)) { fallback = tab; break; }
        }
        }
    }
    self.pickerActiveTab = fallback;
}

- (BOOL)_tpk_selectInitialProviderIfNeeded {
    if (self.pickerOpeningLocationExplicit) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    if (!self.pickerInitialProviderSelectionPending || self.pickerIsSearching)
        return NO;

    // Favorites can arrive after the snapshots: move to Favorites once; the pending flag clears here so later refreshes never steal the tab.
    if (self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count) {
        BOOL changed = self.pickerActiveTab != TPKPickerTabFavorites;
        self.pickerActiveTab = TPKPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // In aggregate mode keep the initial tab on Tous once a snapshot exists, instead of briefly showing 7TV then hiding it.
    if ([TPKEmoteProviderSettings mixedPickerEnabled] &&
        (self.pickerProviderEmotes.count || self.emotePickerAllEmotes.count)) {
        BOOL changed = self.pickerActiveTab != TPKPickerTabAll;
        self.pickerActiveTab = TPKPickerTabAll;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // A legacy-only snapshot has no provider dictionary: it is already the valid 7TV fallback, nothing to select automatically.
    if (!self.pickerProviderEmotes.count) {
        if (self.emotePickerAllEmotes.count || self.emotePickerEmotes.count)
            self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    if (self.pickerActiveTab == TPKPickerTabAll) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    TPKEmoteProviderID activeProvider = [self _tpk_providerForPickerTab:
        self.pickerActiveTab];
    NSArray *activeItems = self.pickerProviderEmotes[@(activeProvider)] ?: @[];
    if (activeItems.count) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    // Providers follow the user's priority; only one with emotes counts (loading/error don't), so a later notification can still select it.
    for (NSString *identifier in [TPKEmoteProviderSettings providerPriority]) {
        TPKExternalEmoteProvider provider = TPKEmoteProviderFromIdentifier(identifier);
        NSArray *items = self.pickerProviderEmotes[@((TPKEmoteProviderID)provider)] ?: @[];
        if (!items.count) continue;
        NSInteger tab = provider == TPKExternalEmoteProvider7TV
            ? TPKPickerTabTPK
            : (provider == TPKExternalEmoteProviderBTTV
               ? TPKPickerTabBTTV : TPKPickerTabFFZ);
        BOOL changed = self.pickerActiveTab != tab;
        self.pickerActiveTab = tab;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }
    return NO;
}

// Met à jour teinte/opacité des icônes + pastille violette ; capsule = Favoris + Tous ou Favoris + 3 providers.
- (void)_tpk_updateTabButtonHighlight {
    [self _tpk_updatePickerTabButtonLayout];
    [self _tpk_normalizeActivePickerTab];
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    UIColor *activeTint   = [UIColor whiteColor];
    UIColor *inactiveTint = [UIColor colorWithWhite:0.55 alpha:1.0];
    for (UIButton *btn in self.pickerTabButtons) {
        BOOL isActive = (btn.tag == self.pickerActiveTab);
        if (btn.tag == TPKPickerTabFavorites) {
            // Seuls les favoris de la chaîne courante remplissent cet onglet : visible mais inactif et très grisé si vide (comme Channel).
            BOOL hasFavorites = self.pickerCatalogFavorites.count > 0 ||
                self.emotePickerFavoriteEmotes.count > 0;
            btn.enabled = hasFavorites;
            btn.alpha = hasFavorites ? 1.0 : 0.25;
            btn.tintColor = (hasFavorites && isActive) ? activeTint : inactiveTint;
            continue;
        }
        if ([self _tpk_pickerTabIsProvider:btn.tag]) {
            NSInteger provider = btn.tag == TPKPickerTabTPK
                ? TPKEmoteProviderIDTPK
                : (btn.tag == TPKPickerTabBTTV ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
            BOOL enabled = [catalog.providerEnabled[@(provider)] boolValue] &&
                (providerMode || provider == TPKEmoteProviderIDTPK);
            btn.enabled = enabled;
            if (!enabled) { btn.alpha = 0.25; continue; }
            // A button can be re-enabled while the picker stays visible: reset alpha before the active/inactive tint so it doesn't stay ghosted.
            btn.alpha = 1.0;
        }
        if ([self _tpk_pickerTabIsProvider:btn.tag]) {
            // Logos provider en images non-template : l'opacité reproduit l'état actif/inactif pour les trois.
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
    [self _tpk_updateSubcategoryCapsule];
}

- (CGSize)pickerHostSize {
    UIWindow *hostWindow = self.emotePickerTextEntryView.window
        ?: self.emotePickerTextField.window
        ?: self.emotePickerView.window;
return hostWindow ? hostWindow.bounds.size : UIScreen.mainScreen.bounds.size;
}

- (BOOL)pickerHostIsLandscape {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (screen.width > 0 && screen.height > 0) return screen.width > screen.height;
    CGSize host = [self pickerHostSize];
    return host.width > host.height;
}

// Hauteur de la grille pour l'orientation courante, bornée à la place disponible.
- (CGFloat)_tpk_resolvedGridHeight {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    CGFloat wanted = [self pickerHostIsLandscape]
        ? cfg.pickerHeightLandscape : cfg.pickerHeightPortrait;
    // Seule la hauteur de la fenêtre sert au plafond, son retard est sans effet.
    CGFloat ceiling = MAX(kTPKPickerMinUsableH,
                          [self pickerHostSize].height - kTPKPickerChromeReserveH);
    return MIN(wanted, ceiling);
}

// Recalcule et applique les frames de toutes les zones du picker (grille /
// pastilles flottantes / panneau des tailles) — appelé à chaque ouverture,
// changement d'orientation, et changement d'onglet. Plus de dock : tout est
// flottant, ancré aux 4 coins/bords via des calculs explicites (fiable même
// quand la hauteur du picker change, ex. panneau des tailles — point 5).
- (void)_tpk_relayoutPickerForSize:(CGSize)size {
    if (!self.emotePickerView) return;

    // Point d'entrée unique de toute changement de taille : c'est ici que la
    // hauteur Auto Layout du conteneur doit être rafraîchie.
    [(TPKPickerContainerView *)self.emotePickerView setPreferredHeight:size.height];
    // Les cellules sont dimensionnées par sizeForItemAtIndexPath: : sans
    // invalidation, le flow layout garde en cache les anciennes dimensions.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    self.emoteCollectionView.frame = CGRectMake(0, 0, size.width, size.height);

    CGFloat bottomRowY = size.height - kTPKPickerFloatMargin - kTPKPickerSearchH
                          - kTPKPickerFloatGap - kTPKPickerFloatSize;
    BOOL mixedPicker = [TPKEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kTPKPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    self.pickerTabCapsuleView.frame = CGRectMake(kTPKPickerFloatMargin, bottomRowY, tabCapsuleW, kTPKPickerFloatSize);
    self.pickerSubcategoryCapsuleView.frame = CGRectMake(
        kTPKPickerFloatMargin,
        bottomRowY - kTPKPickerSubcategoryGap - kTPKPickerFloatSize,
        kTPKPickerFloatSize * 2.0,
        kTPKPickerFloatSize);
    // Capsule en bas à droite dans la grille, en haut à droite dans les réglages : position seule, apparence inchangée.
    CGFloat toolsCapsuleW = kTPKPickerFloatSize * 2.0;
    CGFloat toolsX = size.width - kTPKPickerFloatMargin - toolsCapsuleW;
    CGFloat toolsY = self.pickerSizesPanelVisible ? 9.0 : bottomRowY;
    self.pickerToolsCapsuleView.frame = CGRectMake(toolsX, toolsY, toolsCapsuleW, kTPKPickerFloatSize);
    [self _tpk_updateTabButtonHighlight];

    CGFloat searchY = size.height - kTPKPickerFloatMargin - kTPKPickerSearchH;
    self.pickerSearchCapsuleView.frame = CGRectMake(kTPKPickerFloatMargin, searchY,
                                                      size.width - kTPKPickerFloatMargin * 2, kTPKPickerSearchH);
    self.emoteSearchField.frame = CGRectMake(0, 0, self.pickerSearchCapsuleView.bounds.size.width, kTPKPickerSearchH);

    self.sizesPanel.panelView.frame = CGRectMake(0, 0, size.width, size.height);
}

// ── Onglets — sélection ───────────────────────────────────────────────────

- (void)_pickerTabTapped:(UIButton *)sender {
// A tap is an explicit choice: a late network response must not switch away from it during first-open.
    self.pickerInitialProviderSelectionPending = NO;
    self.pickerOpeningLocationExplicit = NO;
    if (self.pickerActiveTab == sender.tag) {
        [self _tpk_persistLastPickerLocation];
        [self _tpk_updateSubcategoryCapsule];
        return; // déjà actif
    }
    self.pickerActiveTab = sender.tag;
    [self _tpk_persistLastPickerLocation];
    [self _tpk_updateTabButtonHighlight];

    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// Croix à droite du champ : vide le champ et relance la recherche sans passer par l'alerte.
- (void)_pickerSearchClearTapped {
    self.emoteSearchField.text = @"";
    self.pickerSearchClearBtn.hidden = YES;
    [self _applySearchQuery:@""];
}

// Retourne l'array d'emotes correspondant à l'onglet actif.
- (NSArray<TPKEmote *> *)_tpk_currentTabEmotes {
    if (self.pickerProviderEmotes.count > 0) {
        if (self.pickerActiveTab == TPKPickerTabFavorites)
            return self.pickerCatalogFavorites ?: @[];
        if (self.pickerActiveTab == TPKPickerTabAll) {
            NSMutableArray<TPKEmote *> *all = [NSMutableArray array];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (NSNumber *provider in [self _tpk_providerIDsInPriorityOrder]) {
                for (TPKEmote *item in self.pickerProviderEmotes[provider] ?: @[]) {
                    NSString *key = TPKPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [all addObject:item];
                }
            }
            // Aggregate tab: keep historical ordering, leave provider ties to source order (no 7TV/BTTV/FFZ grouping).
            [all sortUsingComparator:TPKPickerMixedEmoteSizeComparator];
            return all.copy;
        }
        NSInteger provider = self.pickerActiveTab == TPKPickerTabTPK
            ? TPKEmoteProviderIDTPK
            : (self.pickerActiveTab == TPKPickerTabBTTV
               ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
        return self.pickerProviderEmotes[@(provider)] ?: @[];
    }
    switch (self.pickerActiveTab) {
        case TPKPickerTabAll:
            return self.emotePickerAllEmotes ?: @[];
        case TPKPickerTabTPK:
            // Legacy cache = combined 7TV catalogue, the only fallback while the provider-aware one is idle.
            return self.emotePickerAllEmotes ?: self.emotePickerChannelEmotes;
        case TPKPickerTabBTTV:
        case TPKPickerTabFFZ:
            // Never show legacy 7TV objects under another provider's tab.
            return @[];
        case TPKPickerTabFavorites:
        default:
            return self.emotePickerFavoriteEmotes;
    }
}

// ── Recherche ──────────────────────────────────────────────────────────────

// ── Méthode centrale de filtrage : met à jour les 2 sections ──────────────

- (void)_updatePickerArraysForSearch:(NSString *)query {
    // Wrapper anti-auto-onglet : seul _applySearchQuery: (vraie frappe) peut changer d'onglet ; ouverture/tap/favori non.
    [self _updatePickerArraysForSearch:query autoSelectTab:NO];
}

- (TPKEmoteProviderID)_tpk_providerForPickerTab:(NSInteger)tab {
    switch (tab) {
        case TPKPickerTabBTTV: return TPKEmoteProviderIDBTTV;
        case TPKPickerTabFFZ: return TPKEmoteProviderIDFFZ;
        case TPKPickerTabTPK:
        default: return TPKEmoteProviderIDTPK;
    }
}

- (BOOL)_tpk_pickerTabIsProvider:(NSInteger)tab {
    return tab == TPKPickerTabTPK || tab == TPKPickerTabBTTV ||
        tab == TPKPickerTabFFZ;
}

- (NSArray<NSNumber *> *)_tpk_providerIDsInPriorityOrder {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:3];
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    for (NSString *identifier in [TPKEmoteProviderSettings providerPriority]) {
        TPKExternalEmoteProvider external = TPKEmoteProviderFromIdentifier(identifier);
        TPKEmoteProviderID provider = (TPKEmoteProviderID)external;
        if (provider < TPKEmoteProviderIDTPK || provider > TPKEmoteProviderIDFFZ ||
            ![catalog.providerEnabled[@(provider)] boolValue] ||
            [result containsObject:@(provider)]) continue;
        [result addObject:@(provider)];
    }
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        if ([catalog.providerEnabled[@(provider)] boolValue] &&
            ![result containsObject:@(provider)])
            [result addObject:@(provider)];
    }
    return result.copy;
}

- (void)_tpk_persistLastPickerLocation {
    NSString *location = nil;
    NSString *subcategory = nil;
    NSNumber *selectionKey = nil;
    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        location = @"favorites";
    } else if (self.pickerActiveTab == TPKPickerTabAll) {
        subcategory = self.pickerSubcategoryByProvider[@(-1)] ?: @"channel";
        location = [NSString stringWithFormat:@"all:%@", subcategory];
    } else if ([self _tpk_pickerTabIsProvider:self.pickerActiveTab]) {
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:self.pickerActiveTab];
        selectionKey = @(provider);
        subcategory = self.pickerSubcategoryByProvider[selectionKey] ?: @"channel";
        location = [NSString stringWithFormat:@"%@:%@",
                    TPKEmoteProviderKey(provider), subcategory];
    }
    if (location.length)
        [TPKEmoteProviderSettings setLastPickerLocation:location];
}

- (BOOL)_tpk_applyConfiguredPickerOpeningLocation {
    NSString *mode = [TPKEmoteProviderSettings pickerOpeningMode];
    if (!mode.length) return NO;
    self.pickerOpeningLocationExplicit = YES;
    if ([mode isEqualToString:TPKEmotePickerOpeningModeFavorites]) {
        self.pickerActiveTab = TPKPickerTabFavorites;
        return YES;
    }
    if ([mode isEqualToString:TPKEmotePickerOpeningModeTPKChannel] ||
        [mode isEqualToString:TPKEmotePickerOpeningModeBTTVChannel] ||
        [mode isEqualToString:TPKEmotePickerOpeningModeFFZChannel]) {
        if ([TPKEmoteProviderSettings mixedPickerEnabled]) {
            // No button in aggregate mode: open the All tab to preserve Channel intent.
            self.pickerActiveTab = TPKPickerTabAll;
            self.pickerSubcategoryByProvider[@(-1)] = @"channel";
            return YES;
        }
        NSInteger tab = [mode hasPrefix:@"7tv"] ? TPKPickerTabTPK
            : ([mode hasPrefix:@"bttv"] ? TPKPickerTabBTTV : TPKPickerTabFFZ);
        self.pickerActiveTab = tab;
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:tab];
        self.pickerSubcategoryByProvider[@(provider)] = @"channel";
        return YES;
    }
    if ([mode isEqualToString:TPKEmotePickerOpeningModeLastUsed]) {
        NSString *location = [TPKEmoteProviderSettings lastPickerLocation];
        if ([location isEqualToString:@"favorites"]) {
            self.pickerActiveTab = TPKPickerTabFavorites;
            return YES;
        }
        NSArray<NSString *> *parts = [location componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            NSString *providerKey = parts[0].lowercaseString;
            NSString *subcategory = [parts[1].lowercaseString isEqualToString:@"global"]
                ? @"global" : @"channel";
            if ([providerKey isEqualToString:@"all"]) {
                self.pickerActiveTab = TPKPickerTabAll;
                self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                return YES;
            }
            TPKEmoteProviderID provider =
                (TPKEmoteProviderID)TPKEmoteProviderFromIdentifier(providerKey);
            if (provider >= TPKEmoteProviderIDTPK && provider <= TPKEmoteProviderIDFFZ) {
                if ([TPKEmoteProviderSettings mixedPickerEnabled]) {
                    self.pickerActiveTab = TPKPickerTabAll;
                    self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                    return YES;
                }
                self.pickerActiveTab = provider == TPKEmoteProviderIDTPK
                    ? TPKPickerTabTPK
                    : (provider == TPKEmoteProviderIDBTTV ? TPKPickerTabBTTV : TPKPickerTabFFZ);
                self.pickerSubcategoryByProvider[@(provider)] = subcategory;
                return YES;
            }
        }
        // « Dernier menu » sans historique : favoris, sinon sélection initiale.
        self.pickerOpeningLocationExplicit = NO;
        return NO;
    }
    self.pickerOpeningLocationExplicit = NO;
    return NO;
}

- (NSString *)_tpk_displaySectionKey:(TPKPickerDisplaySection *)section {
    NSInteger provider = section.provider;
    return [NSString stringWithFormat:@"%ld:%@", (long)provider,
            section.identifier ?: @""];
}

- (BOOL)_tpk_sectionIsChannel:(TPKPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    // BTTV shared/set stay channel-scoped, else the catalogue hides behind Shared/Set.
    if (section.kind == TPKEmoteSectionKindChannel ||
        section.kind == TPKEmoteSectionKindShared) return YES;
    if (section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier.lowercaseString hasPrefix:@"global-set:"]) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"channel"] || [identifier containsString:@"channel"];
}

- (BOOL)_tpk_sectionIsGlobal:(TPKPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    if (section.kind == TPKEmoteSectionKindGlobal) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"global"] || [identifier containsString:@"global"];
}

- (void)_tpk_updateSubcategoryCapsule {
    UIView *capsule = self.pickerSubcategoryCapsuleView;
    UIButton *channelButton = self.pickerSubcategoryChannelBtn;
    UIButton *globalButton = self.pickerSubcategoryGlobalBtn;
    if (!capsule || !channelButton || !globalButton) return;

    BOOL providerTab = [self _tpk_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
    BOOL visible = (providerTab || allTab) && !self.pickerSizesPanelVisible;
    capsule.hidden = !visible;
    if (!visible) return;

    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _tpk_providerForPickerTab:self.pickerActiveTab]);
    BOOL hasChannel = NO;
    BOOL hasGlobal = NO;
    NSArray<NSNumber *> *providers = allTab
        ? [self _tpk_providerIDsInPriorityOrder]
        : @[selectionKey];
    for (NSNumber *providerNumber in providers) {
        for (TPKPickerDisplaySection *section in
             self.pickerProviderSections[providerNumber] ?: @[]) {
            BOOL usable = section.items.count > 0 || !section.loaded ||
                section.loading || section.errorMessage.length;
            if (!usable) continue;
            hasChannel |= [self _tpk_sectionIsChannel:section];
            hasGlobal |= [self _tpk_sectionIsGlobal:section];
        }
    }

    // Channel capsule stays visible even when empty; only its action is disabled.
    channelButton.hidden = NO;
    channelButton.enabled = hasChannel;
    globalButton.hidden = !hasGlobal;
    globalButton.enabled = hasGlobal;

    NSString *selected = self.pickerSubcategoryByProvider[selectionKey];
    // Older builds persisted a section ID (set:abc); normalize to channel/global.
    BOOL selectedIsChannel = [selected isEqualToString:@"channel"] ||
        (selected.length && ![selected isEqualToString:@"global"] && hasChannel &&
         ![selected.lowercaseString containsString:@"global"]);
    BOOL selectedIsGlobal = [selected isEqualToString:@"global"] ||
        (selected.length && [selected.lowercaseString containsString:@"global"] && hasGlobal);
    selectedIsChannel &= hasChannel;
    selectedIsGlobal &= hasGlobal;
    if (!selectedIsChannel && !selectedIsGlobal) {
        // Channel defaults when it has emotes; loading Channel must not hide Global.
        BOOL channelHasItems = NO;
        BOOL globalHasItems = NO;
        for (NSNumber *providerNumber in providers) {
            for (TPKPickerDisplaySection *section in
                 self.pickerProviderSections[providerNumber] ?: @[]) {
                if ([self _tpk_sectionIsChannel:section] && section.items.count) channelHasItems = YES;
                if ([self _tpk_sectionIsGlobal:section] && section.items.count) globalHasItems = YES;
            }
        }
        selected = channelHasItems ? @"channel" :
            (globalHasItems ? @"global" : (hasChannel ? @"channel" : @"global"));
        if (selected.length) self.pickerSubcategoryByProvider[selectionKey] = selected;
        selectedIsChannel = [selected isEqualToString:@"channel"] && hasChannel;
        selectedIsGlobal = [selected isEqualToString:@"global"] && hasGlobal;
    }

    UIColor *accent = tpk_pickerAccentColor();
    UIColor *inactive = [UIColor colorWithWhite:1.0 alpha:0.58];
    channelButton.backgroundColor = selectedIsChannel ? accent : UIColor.clearColor;
    globalButton.backgroundColor = selectedIsGlobal ? accent : UIColor.clearColor;
    channelButton.tintColor = selectedIsChannel ? UIColor.whiteColor : inactive;
    globalButton.tintColor = selectedIsGlobal ? UIColor.whiteColor : inactive;
    channelButton.alpha = hasChannel ? (selectedIsChannel ? 1.0 : 0.55) : 0.25;
    globalButton.alpha = hasGlobal ? (selectedIsGlobal ? 1.0 : 0.55) : 0.25;

    // Global reprend le logo du provider ; l'agrégat « Tous » utilise une mappemonde.
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

    // L'avatar représente la chaîne, pas le provider : il reste visible entre onglets.
    [self _tpk_refreshChannelAvatarIfNeeded];
}

- (void)_pickerSubcategoryTapped:(UIButton *)sender {
    BOOL providerTab = [self _tpk_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
    if ((!providerTab && !allTab) || sender.hidden || !sender.enabled) return;
    BOOL wantChannel = sender == self.pickerSubcategoryChannelBtn;
    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _tpk_providerForPickerTab:self.pickerActiveTab]);
    self.pickerSubcategoryByProvider[selectionKey] = wantChannel ? @"channel" : @"global";
    [self _tpk_persistLastPickerLocation];
    [self _tpk_updateSubcategoryCapsule];
    NSString *query = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:query];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

- (void)_tpk_rebuildCatalogDisplaySectionsForQueryLegacy:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;

    // Preserve explicit collapse choices across search instead of leaving all expanded.
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

    NSMutableArray<TPKPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        if (self.pickerCatalogFavorites.count) {
            NSMutableArray *items = [NSMutableArray array];
            for (TPKEmote *item in self.pickerCatalogFavorites) {
                TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                    ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // Fully filtered Favorites drops its header; empty state = loading/errors.
            if (items.count) {
                TPKPickerDisplaySection *favorites = [TPKPickerDisplaySection new];
                favorites.provider = TPKEmoteProviderIDTPK;
                favorites.kind = TPKEmoteSectionKindFavorites;
                favorites.identifier = @"favorites";
                favorites.title = @"Favorites";
                favorites.items = items.copy;
                favorites.loaded = YES;
                [display addObject:favorites];
            }
        }
    } else {
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:self.pickerActiveTab];
        NSArray<TPKPickerDisplaySection *> *source = self.pickerProviderSections[@(provider)];
        TPKEmoteProviderSnapshot *snapshot = [[TPKEmoteCatalog sharedCatalog]
            snapshotForProvider:provider];

        // No section yet: show a state header with retry instead of an empty grid.
        if (!source.count && (snapshot.state == TPKEmoteProviderStateLoading ||
                              snapshot.state == TPKEmoteProviderStateLoaded ||
                              snapshot.state == TPKEmoteProviderStateError)) {
            TPKPickerDisplaySection *stateSection = [TPKPickerDisplaySection new];
            stateSection.provider = provider;
            stateSection.kind = TPKEmoteSectionKindSet;
            stateSection.identifier = @"provider-state";
            stateSection.title = TPKEmoteProviderName(provider);
            stateSection.items = @[];
            stateSection.loaded = snapshot.state == TPKEmoteProviderStateLoaded;
            stateSection.loading = snapshot.state == TPKEmoteProviderStateLoading;
            stateSection.empty = snapshot.state == TPKEmoteProviderStateLoaded;
            stateSection.errorMessage = snapshot.errorMessage;
            [display addObject:stateSection];
        }

        for (TPKPickerDisplaySection *original in source) {
            NSMutableArray *items = [NSMutableArray array];
            for (TPKEmote *item in original.items) {
                TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                    ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // Hide only after a successful empty response; placeholders stay visible.
            if (!items.count && original.loaded && !original.loading && !original.errorMessage.length) continue;
            TPKPickerDisplaySection *current = [TPKPickerDisplaySection new];
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

    // New sections default to one open (all open while searching), rest collapsed.
    BOOL openedOne = NO;
    for (TPKPickerDisplaySection *section in display) {
        NSString *key = [self _tpk_displaySectionKey:section];
        BOOL canDisplayContent = section.items.count > 0 ||
            section.loading || section.errorMessage.length ||
            section.kind == TPKEmoteSectionKindSet;
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
    // Sync flow header immediately, else switching tabs leaves a stale 30pt header.
    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) {
        flowLayout.headerReferenceSize = CGSizeZero;
    }
    // Keep the flat array (anchor/search compat) in sync with the open sections.
    NSMutableArray<TPKEmote *> *visibleItems = [NSMutableArray array];
    for (TPKPickerDisplaySection *section in display) {
        NSString *key = [self _tpk_displaySectionKey:section];
        if (![self.pickerCollapsedSections[key] boolValue])
            [visibleItems addObjectsFromArray:section.items ?: @[]];
    }
    self.emotePickerEmotes = visibleItems.copy;
}

// Version actuelle : une seule catégorie Channel/Global ; Shared/Set fusionnés dedans.
- (void)_tpk_rebuildCatalogDisplaySectionsForQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;
    NSMutableArray<TPKPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        NSMutableArray<TPKEmote *> *items = [NSMutableArray array];
        for (TPKEmote *item in self.pickerCatalogFavorites ?: @[]) {
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
            BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
            if (!matches && descriptor) {
                for (NSString *alias in descriptor.aliases) {
                    if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                }
            }
            if (matches) [items addObject:item];
        }
        [items sortUsingComparator:TPKPickerEmoteSizeComparator];
        if (items.count) {
            TPKPickerDisplaySection *favorites = [TPKPickerDisplaySection new];
            favorites.provider = TPKEmoteProviderIDTPK;
            favorites.kind = TPKEmoteSectionKindFavorites;
            favorites.identifier = @"favorites";
            favorites.title = @"Favorites";
            favorites.items = items.copy;
            favorites.loaded = YES;
            [display addObject:favorites];
        }
    } else {
        BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
        TPKEmoteProviderID provider = allTab
            ? TPKEmoteProviderIDTPK
            : [self _tpk_providerForPickerTab:self.pickerActiveTab];
        NSNumber *selectionKey = allTab ? @(-1) : @(provider);
        NSArray<NSNumber *> *providers = allTab
            ? [self _tpk_providerIDsInPriorityOrder]
            : @[@(provider)];
        NSMutableArray<TPKEmote *> *channelItems = [NSMutableArray array];
        NSMutableArray<TPKEmote *> *globalItems = [NSMutableArray array];
        NSMutableSet<NSString *> *seenChannel = [NSMutableSet set];
        NSMutableSet<NSString *> *seenGlobal = [NSMutableSet set];
        BOOL channelLoading = NO, globalLoading = NO;
        BOOL channelError = NO, globalError = NO;
        NSString *channelErrorMessage = nil, *globalErrorMessage = nil;
        BOOL anyProviderLoading = NO, anyProviderError = NO;
        NSString *anyProviderErrorMessage = nil;

        BOOL (^matchesQuery)(TPKEmote *) = ^BOOL(TPKEmote *item) {
            if (!lower.length) return YES;
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
            if ([item.emoteName.lowercaseString containsString:lower]) return YES;
            for (NSString *alias in descriptor.aliases)
                if ([alias.lowercaseString containsString:lower]) return YES;
            return NO;
        };

        for (NSNumber *providerNumber in providers) {
            NSArray<TPKPickerDisplaySection *> *source =
                self.pickerProviderSections[providerNumber] ?: @[];
            for (TPKPickerDisplaySection *original in source) {
                BOOL isChannel = [self _tpk_sectionIsChannel:original];
                BOOL isGlobal = [self _tpk_sectionIsGlobal:original];
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
                for (TPKEmote *item in original.items ?: @[]) {
                    if (!matchesQuery(item)) continue;
                    NSString *key = TPKPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [target addObject:item];
                }
            }
        }

        // Sort only after the union: interleaved by size, not provider blocks.
        [channelItems sortUsingComparator:TPKPickerMixedEmoteSizeComparator];
        [globalItems sortUsingComparator:TPKPickerMixedEmoteSizeComparator];

        BOOL (^addCategory)(BOOL, NSArray<TPKEmote *> *, BOOL, BOOL, NSString *, NSString *) =
            ^BOOL(BOOL isChannel, NSArray<TPKEmote *> *items, BOOL loading,
                  BOOL hasError, NSString *errorMessage, NSString *identifier) {
            if (!items.count && !loading && !hasError) return NO;
            TPKPickerDisplaySection *section = [TPKPickerDisplaySection new];
            section.provider = provider;
            section.kind = isChannel ? TPKEmoteSectionKindChannel : TPKEmoteSectionKindGlobal;
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

        // Une seule catégorie : Channel par défaut, sinon Global ; choix persisté.
        NSString *selectedID = [self.pickerSubcategoryByProvider[selectionKey] lowercaseString];
        BOOL wantsChannel = [selectedID isEqualToString:@"channel"] ||
            (selectedID.length && ![selectedID containsString:@"global"] && hasChannelCategory);
        BOOL wantsGlobal = [selectedID isEqualToString:@"global"] ||
            ([selectedID containsString:@"global"] && hasGlobalCategory);
        TPKPickerDisplaySection *selected = nil;
        TPKPickerDisplaySection *channelSection = display.firstObject;
        TPKPickerDisplaySection *globalSection = display.count > 1 ? display[1] :
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
            // Keep only the selected one of the two virtual sections visible.
            [display removeAllObjects];
            [display addObject:selected];
        } else if (anyProviderLoading || anyProviderError || !providers.count) {
            TPKPickerDisplaySection *state = [TPKPickerDisplaySection new];
            state.provider = provider;
            state.kind = TPKEmoteSectionKindSet;
            state.identifier = allTab ? @"all-provider-state" : @"provider-state";
            state.title = allTab ? @"All providers" : TPKEmoteProviderName(provider);
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
    for (TPKPickerDisplaySection *section in display)
        self.pickerCollapsedSections[[self _tpk_displaySectionKey:section]] = @NO;

    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) flowLayout.headerReferenceSize = CGSizeZero;

    self.emotePickerEmotes = display.count ? display.firstObject.items : @[];
    [self _tpk_updateSubcategoryCapsule];
}

- (void)_updatePickerArraysForSearch:(NSString *)query autoSelectTab:(BOOL)autoSelectTab {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    // Catalogue is the only source (even while loading) — never a stale 7TV-only dict.
    {
        NSMutableArray *providerItems = [NSMutableArray array];
        if (self.pickerActiveTab == TPKPickerTabFavorites) {
            [providerItems addObjectsFromArray:self.pickerCatalogFavorites ?: @[]];
        } else if (self.pickerActiveTab == TPKPickerTabAll) {
            // Already ordered by the mixed comparator; no re-grouping by priority.
            [providerItems addObjectsFromArray:[self _tpk_currentTabEmotes]];
        } else {
            NSInteger provider = self.pickerActiveTab == TPKPickerTabTPK
                ? TPKEmoteProviderIDTPK
                : (self.pickerActiveTab == TPKPickerTabBTTV
                   ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
            [providerItems addObjectsFromArray:self.pickerProviderEmotes[@(provider)] ?: @[]];
        }
        NSMutableArray *filtered = [NSMutableArray array];
        for (TPKEmote *item in providerItems) {
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
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
            [filtered sortUsingComparator:^NSComparisonResult(TPKEmote *a, TPKEmote *b) {
                NSInteger ra = [self _tpk_relevanceRankForEmoteName:a.emoteName query:lower];
                NSInteger rb = [self _tpk_relevanceRankForEmoteName:b.emoteName query:lower];
                return ra == rb ? NSOrderedSame : (ra < rb ? NSOrderedAscending : NSOrderedDescending);
            }];
        }
        if (self.pickerActiveTab == TPKPickerTabFavorites)
            self.emotePickerFavoriteEmotes = filtered;
        else {
            self.emotePickerChannelEmotes = filtered;
            self.emotePickerGlobalEmotes = filtered;
        }
        self.emotePickerOtherEmotes = filtered;
        [self _tpk_rebuildCatalogDisplaySectionsForQuery:q];
        [self _tpk_updateTabButtonHighlight];
        return;
    }
}

// Rang : 0 = exact, 1 = préfixe, 2 = sous-chaîne ailleurs (requête en minuscules).
- (NSInteger)_tpk_relevanceRankForEmoteName:(NSString *)name query:(NSString *)lowerQuery {
    NSString *lowerName = name.lowercaseString;
    if ([lowerName isEqualToString:lowerQuery]) return 0;
    if ([lowerName hasPrefix:lowerQuery]) return 1;
    return 2;
}

// ── UITextFieldDelegate — intercepte le focus du champ de recherche ────────
// PROBLÈME : resign du TextEntryView perd le picker. SOLUTION : delegate NO + alerte.
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField != self.emoteSearchField) return YES;
    if (self.pickerSearchAlertActive) return NO;

    // Capturer la query courante pour pré-remplir l'alerte
    NSString *currentQuery = textField.text ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_search_emote_title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    alert.view.tintColor = TPKAccent();

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
        // Dismiss instantané pour éviter deux transitions firstResponder en cascade.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:L(@"common_cancel")
                  style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *action) {
        // Idem à l'annulation : dismiss sans animation, une seule transition.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    [alert addAction:searchAction];
    [alert addAction:cancelAction];
    alert.preferredAction = searchAction;

    // Flag AVANT présentation : le champ de l'alerte résigne le TextEntryView.
    UIViewController *presenter = [self topViewController];
    if (!presenter) return NO;
    [self _tpk_deactivateVisiblePickerAnimations];
    self.pickerSearchAlertActive = YES;
    [presenter presentViewController:alert animated:YES completion:nil];

    // Bloquer le becomeFirstResponder → le picker reste affiché
    return NO;
}

- (void)_applySearchQuery:(NSString *)query {
    // Seul point d'entrée où l'onglet peut être choisi automatiquement.
    [self _updatePickerArraysForSearch:query autoSelectTab:YES];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    [self _tpk_updateSearchClearVisibility];
}

// Affiche/masque la croix à droite du champ selon que le texte est présent ou non.
- (void)_tpk_updateSearchClearVisibility {
    self.pickerSearchClearBtn.hidden = (self.emoteSearchField.text.length == 0);
}

// Après dismiss : le resign efface l'inputView → inputView = picker + reloadInputViews.
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
        // Fenêtre flottante : pas de TextEntryView, observers d'animation coupés.
        pickerView.hidden = NO;
    } else {
        return;
    }
    // Une fois l'inputView remonté, réactiver les animations des cellules visibles.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf _tpk_activateVisiblePickerAnimations];
    });
}

// UIControlEventEditingChanged : champ modifié programmatiquement, quasi bloqué.
- (void)_emoteSearchChanged:(UITextField *)field {
    [self _applySearchQuery:field.text ?: @""];
}



// ── Long press → toggle favori ─────────────────────────────────────────────

- (void)_handleLongPressOnPicker:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    CGPoint pt = [gr locationInView:self.emoteCollectionView];
    NSIndexPath *ip = [self.emoteCollectionView indexPathForItemAtPoint:pt];
    if (!ip) return;

    TPKEmote *emote = [self _emoteForIndexPath:ip];
    if (!emote) return;

    TPKEmoteDescriptor *descriptor = [emote isKindOfClass:[TPKPickerCatalogEmote class]]
        ? [(TPKPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFav = descriptor
        ? [[TPKEmoteCatalog sharedCatalog] isEmoteFavorited:descriptor]
        : [[TPKManager sharedManager] isEmoteFavorited:emote.emoteID];
    if (descriptor && descriptor.provider == TPKEmoteProviderIDTPK) {
        // Keep the legacy manager's 7TV set in sync; Favorites settings still read it.
        [[TPKManager sharedManager] setEmote:descriptor.emoteID favorited:!isFav];
    } else if (descriptor) {
        [[TPKEmoteCatalog sharedCatalog] setEmote:descriptor favorited:!isFav];
    } else {
        [[TPKManager sharedManager] setEmote:emote.emoteID favorited:!isFav];
    }
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // Pas de reload : setEmote:favorited: notifie déjà (un 2e cassait les anims).
}

// ── Helper : emote à partir d'un indexPath ─────────────────────────────────
// Section unique (voir _tpk_currentTabEmotes) : l'onglet actif choisit l'array.

- (TPKEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (self.pickerUsesCatalogSections) {
        if (ip.section < 0 || ip.section >= (NSInteger)self.pickerDisplaySections.count) return nil;
        TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)ip.section];
        NSString *key = [self _tpk_displaySectionKey:section];
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
// Hors inputView : conteneur séparé sur la key window (créé une fois, repositionné).
- (UIView *)_ensureFakeChatPreviewContainer {
    if (self.pickerFakeChatPreviewView) return self.pickerFakeChatPreviewView;

    UIView *container = [[UIView alloc] init];
    container.accessibilityIdentifier = @"tpk_fake_chat_preview";
    container.backgroundColor = TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.09 alpha:0.97];
    container.layer.cornerRadius = 12;
    container.clipsToBounds = YES;
    container.hidden = YES;
    // Opaque et interactif : aucun tap ne traverse vers le vrai chat derrière.
    container.userInteractionEnabled = YES;

    TPKChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:chatView];

    self.pickerFakeChatPreviewView = container;
    return container;
}

// Barre de saisie RN (pleine largeur) : seule mesure de position.
static UIView *tpk_pickerFindChatInputBar(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.0) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    UIView *bestBar = nil;
    CGFloat bestBottom = -CGFLOAT_MAX;
    while (queue.count > 0 && visited < 6000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view.hidden || view.alpha <= 0.01) continue;
        if ([@"chat-input-bar" isEqualToString:view.accessibilityIdentifier] &&
            view.window == window && !CGRectIsEmpty(view.bounds)) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            if (CGRectIntersectsRect(frame, window.bounds) && CGRectGetMaxY(frame) > bestBottom) {
                bestBar = view;
                bestBottom = CGRectGetMaxY(frame);
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return bestBar;
}

// Au-dessus de chatInputView (~50% écran), recouvre le chat, repris à chaque appel.
- (void)_showFakeChatPreviewAboveInputView {
    UIView *pickerView = self.emotePickerView;
    BOOL pickerAttachedAsInputView = self.emotePickerTextEntryView &&
        self.emotePickerTextEntryView.window &&
        self.emotePickerTextEntryView.inputView == pickerView;
    BOOL pickerVisibleAsWindowFallback =
        pickerView.window && pickerView.superview == pickerView.window;
    if (!self.pickerSizesPanelVisible || !pickerView || pickerView.hidden ||
        (!pickerAttachedAsInputView && !pickerVisibleAsWindowFallback)) {
        // Relayout différé : si le picker n'est plus attaché, supprimer le conteneur.
        [self _hideFakeChatPreview];
        return;
    }

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
        [[TPKManager sharedManager] log:@"⚠️ _showFakeChatPreviewAboveInputView: pas de key window"];
        return;
    }

    // Pas d'aperçu en paysage : la hauteur d'écran ne laisse pas la place,
    // il masquerait le chat au lieu d'aider.
    if (keyWindow.bounds.size.width > keyWindow.bounds.size.height) {
        [self _hideFakeChatPreview];
        return;
    }

    CGFloat width     = keyWindow.bounds.size.width;
    static const CGFloat kFakeChatInset = 8.0; // même valeur que CGRectInset(container.bounds, 8, 8) plus bas

    // La chat bar est recalée par UIKit après la reconstruction du clavier :
    // sans forcer le layout, inputTopY est mesuré sur l'ancienne position et
    // l'aperçu reste décalé.
    [keyWindow layoutIfNeeded];

    CGFloat inputTopY = keyWindow.bounds.size.height;
    UIView *bar = tpk_pickerFindChatInputBar(keyWindow);
    if (bar) {
        CGRect barFrame = [bar convertRect:bar.bounds toView:keyWindow];
        inputTopY = barFrame.origin.y;
    }
    CGFloat safeTop = keyWindow.safeAreaInsets.top;
    CGFloat availableHeight = MAX(0.0, inputTopY - safeTop);
    CGFloat maxHeight = MIN(keyWindow.bounds.size.height * 0.5, availableHeight);
    if (maxHeight < 80.0) {
        [self _hideFakeChatPreview];
        return;
    }

    UIView *container = [self _ensureFakeChatPreviewContainer];
    TPKChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.renderingSuspended = NO;
    if (container.superview != keyWindow) {
        [container removeFromSuperview];
        [keyWindow addSubview:container];
    }

    // ── Hauteur réelle du contenu ────────────────────────────────────────
    // Contenu réel : largeur d'abord, layout forcé, puis contentSize.height (pas 50%).
    chatView.frame = CGRectMake(0, 0, width - kFakeChatInset * 2, maxHeight);
    CGFloat contentHeight = [chatView tpkContentHeight];

    CGFloat height = (contentHeight > 0)
        ? MIN(contentHeight + kFakeChatInset * 2, maxHeight)
        : maxHeight; // fallback si contentSize indisponible (pas encore layoutée)

    CGFloat y = MAX(safeTop, inputTopY - height);

    container.frame = CGRectMake(0, y, width, height);
    self.sizesPanel.fakeChatView.frame = CGRectInset(container.bounds, kFakeChatInset, kFakeChatInset);
    container.hidden = NO;
    [keyWindow bringSubviewToFront:container];
}

// La chat bar est recalée par UIKit pendant l'animation du clavier : sa frame
// finale n'existe qu'à ce moment. Repositionner sur l'événement, et non sur un
// délai deviné, sinon l'aperçu reste à l'ancienne position.
// Même événement pour l'orientation : c'est le seul signal qui tombe APRÈS la
// rotation de la fenêtre, donc le seul fiable pour recaler la ligne de taille.
- (void)_tpk_keyboardFrameDidChange:(NSNotification *)notification {
    UIView *pickerView = self.emotePickerView;
    if (!pickerView.window || pickerView.hidden) return;
    // Filet : la zone clavier vient d'être redimensionnée, donc si la hauteur
    // voulue a changé entre-temps (rotation) le conteneur doit se recaler.
    CGFloat height = [self _tpk_resolvedGridHeight];
    if (fabs(pickerView.bounds.size.height - height) >= 0.5) {
        CGRect frame = pickerView.frame;
        frame.size.height = height;
        pickerView.frame = frame;
        [self _tpk_relayoutPickerForSize:frame.size];
        [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    }
    if (!self.pickerSizesPanelVisible) return;
    [self _showFakeChatPreviewAboveInputView];
    [self.sizesPanel tpk_syncPickerSizeRow];
}

- (void)_hideFakeChatPreview {
    TPKChatCustomView *chatView = self->_sizesPanel.fakeChatView;
    [chatView resetTransientTranscriptState];
    chatView.renderingSuspended = YES;
    UIView *container = self.pickerFakeChatPreviewView;
    container.hidden = YES;
    // Retirer (pas seulement masquer) : un callback différé peut le remontrer.
    [container removeFromSuperview];
    self.pickerFakeChatPreviewView = nil;
}

// ── Slider taille des emotes ───────────────────────────────────────────────

// Table clé → (nom, min, max) : source unique (menu, slider, label) ; bornes ~2x défaut.
- (void)emotePickerSizesToggleTapped {
    BOOL show = !self.pickerSizesPanelVisible;
    if (show) {
        // Couper aussi la décélération : son callback réactiverait une cellule derrière.
        CGPoint offset = self.emoteCollectionView.contentOffset;
        [self.emoteCollectionView setContentOffset:offset animated:NO];
        self.emoteCollectionView.panGestureRecognizer.enabled = NO;
        self.emoteCollectionView.panGestureRecognizer.enabled = YES;
        [self _tpk_deactivateVisiblePickerAnimations];
        [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
        [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
        [[TPKEmoteImageCache sharedCache] setDecodingSuspended:NO];
        self.pickerScrollInProgress = NO;
        // Le toggle supprime didEndDecelerating : appliquer ici le catalogue en attente.
        if (self.pickerCatalogReloadPending) [self _tpk_applyCatalogUpdateNow];
    }
    self.pickerSizesPanelVisible = show;
    self.sizesPanel.panelView.hidden = !show;
    self.emoteCollectionView.hidden  = show;
    self.pickerSearchCapsuleView.hidden = show;
    // Masquer conteneur + icônes : sinon la capsule vide reste visible à gauche.
    self.pickerTabCapsuleView.hidden = show;
    self.pickerSubcategoryCapsuleView.hidden = show;
    for (UIButton *btn in self.pickerTabButtons) btn.hidden = show;
    self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    // L'émoticône reprend l'icône de retour du picker : même langage visuel.
    UIImageSymbolConfiguration *backCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [self.pickerSizesToggleBtn setImage:
        [UIImage systemImageNamed:(show ? @"face.smiling" : @"textformat.size")
                withConfiguration:backCfg]
                                forState:UIControlStateNormal];

    // Panneau et grille partagent la hauteur configurée : le toggle ne change
// que le contenu affiché. Toujours relayout : c'est lui qui replace la
// capsule tailles/réglages du bon côté.
    CGRect f = self.emotePickerView.frame;
    CGFloat targetH = [self _tpk_resolvedGridHeight];
    f.size.height = targetH;
    self.emotePickerView.frame = f;
    [self _tpk_relayoutPickerForSize:f.size];
    // Relire la taille de l'inputView, sinon la zone clavier reste figée.
    [self.emotePickerTextEntryView reloadInputViews];

    if (show) {
        self.sizesPanel.fakeChatView.renderingSuspended = NO;
        [self.sizesPanel loadRealPreviewAssetsIfNeeded];
        [self _showFakeChatPreviewAboveInputView];
        // Après l'aperçu : c'est lui qui attache le faux chat à la key window,
        // seule source fiable pour lire l'orientation courante.
        [self.sizesPanel tpk_syncPickerSizeRow];
    } else {
        [self _hideFakeChatPreview];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _tpk_activateVisiblePickerAnimations];
        });
    }
}

// Ouvre l'écran de réglages complet depuis le picker (même écran que le
// Le picker étant l'inputView, la fenêtre clavier n'est détruite que si le
// texte résigne. reloadInputViews ne change donc pas la hauteur de la zone.
// On repasse par le chemin éprouvé (fermeture + réouverture), seul moyen que
// UIKit reconstruise le clavier à la nouvelle taille.
- (void)pickerSizePreferenceDidChange {
    // D'abord la grille : changer la taille des emotes ne bouge pas la hauteur,
    // donc le cycle ci-dessous nepart pas et la grille resterait obsolète.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    if (!self.emotePickerView || !self.emotePickerTextField.window) return;
    // Rien à reconstruire si la hauteur de l'orientation courante n'a pas bougé
    // — cas où l'on édite la valeur de l'autre orientation.
    if (fabs(self.emotePickerView.bounds.size.height
             - [self _tpk_resolvedGridHeight]) < 0.5) return;
    UIView *inputRoot = self.emotePickerTextField;
    BOOL panelWasVisible = self.pickerSizesPanelVisible;
    [self _hideEmotePicker];
    [self toggleEmotePickerForChatInputView:inputRoot];
    if (panelWasVisible) [self emotePickerSizesToggleTapped];
}

// Ouvre l'écran de réglages complet depuis le picker (même écran que le
// bouton flottant 7TV) — ferme d'abord le picker (clavier custom + inputView)
// pour ne pas laisser les 2 superposés.
- (void)_pickerSettingsTapped {
    [self _hideEmotePicker];
    [[TPKManager sharedManager] presentSettingsMenu];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    if (self.pickerUsesCatalogSections) return (NSInteger)self.pickerDisplaySections.count;
    return 1; // Compatibilité avec le catalogue legacy aplati.
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if (self.pickerUsesCatalogSections) {
        if (section < 0 || section >= (NSInteger)self.pickerDisplaySections.count) return 0;
        TPKPickerDisplaySection *display = self.pickerDisplaySections[(NSUInteger)section];
        NSString *key = [self _tpk_displaySectionKey:display];
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
    TPKPickerSectionHeaderView *header =
        (TPKPickerSectionHeaderView *)[collectionView
            dequeueReusableSupplementaryViewOfKind:kind
                               withReuseIdentifier:@"TPKPickerSectionHeader"
                                      forIndexPath:indexPath];
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)indexPath.section];
    NSString *sectionKey = [self _tpk_displaySectionKey:section];
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
    header.backgroundColor = TPKOLEDModeEnabled()
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
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    NSString *key = [self _tpk_displaySectionKey:section];
    BOOL willExpand = [self.pickerCollapsedSections[key] boolValue];
    self.pickerCollapsedSections[key] = @(!willExpand);
    if (willExpand && section.provider == TPKEmoteProviderIDTPK &&
        section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"] &&
        !section.items.count &&
        !section.loaded &&
        !section.loading && !section.errorMessage.length) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [TPKManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[TPKEmoteCatalog sharedCatalog] loadTPKEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
    }
    [self _tpk_rebuildCatalogDisplaySectionsForQuery:self.emoteSearchField.text ?: @""];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
}

- (void)_pickerSectionRetryTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pickerDisplaySections.count) return;
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    if (section.provider == TPKEmoteProviderIDTPK &&
        section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"]) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [TPKManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[TPKEmoteCatalog sharedCatalog] loadTPKEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
        return;
    }
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    [catalog loadProvider:section.provider global:YES channel:nil completion:nil];
    if (channelID.length)
        [catalog loadProvider:section.provider global:NO channel:channelID completion:nil];
}

// ── Taille variable par emote ─────────────────────────────────────────────
// Hauteur = largeur/6 ; largeur = hauteur × ratio ; min = hauteur*0.25, hauteur min 32pt.

// Colonnes de référence : 6 en portrait, 10 en paysage (cellules plus petites).
- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    CGFloat cvW = cv.bounds.size.width > 0 ? cv.bounds.size.width : 390.0;
    CGFloat referenceColumns = [self pickerHostIsLandscape] ? 10.0 : 6.0;
    // Facteur réglable, plancher inchangé pour ne jamais descendre sous 32 pt.
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    CGFloat scale = [self pickerHostIsLandscape] ? cfg.pickerEmoteScaleLandscape
                                                : cfg.pickerEmoteScalePortrait;
    CGFloat cellH = MAX(32.0, floor(cvW / referenceColumns) * scale);

    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote || emote.width <= 0 || emote.height <= 0) {
        // Pas de dimensions connues → carré
        return CGSizeMake(cellH, cellH);
    }

    CGFloat ratio = (CGFloat)emote.width / (CGFloat)emote.height;
    CGFloat cellW = cellH * ratio;

    cellW = MAX(cellH * 0.25, cellW);   // min 25% de la hauteur
    cellW = MIN(cvW, cellW);            // max = pleine largeur
    cellW = ceil(cellW);
    cellH = ceil(cellH);

    return CGSizeMake(cellW, cellH);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TPKEmotePickerCell *cell = (TPKEmotePickerCell *)
        [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID forIndexPath:indexPath];
    // Réappliqué à chaque déqueue : pas de palette obsolète sur cellule recyclée.
    [cell tpk_applyOLEDColors];

    // Reconfigurable sans prepareForReuse : couper l'observation ici (comme le chat).
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:cell];
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

    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Étoile = favoris réels, pas la section (favorite visible dans son onglet).
    TPKEmoteDescriptor *descriptor = [emote isKindOfClass:[TPKPickerCatalogEmote class]]
        ? [(TPKPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFavorite = descriptor
        ? [self.pickerFavoriteKeySet containsObject:
              TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID)]
        : [[TPKManager sharedManager] isEmoteFavorited:emote.emoteID];
    cell.favoriteStarView.hidden = !isFavorite;
    cell.accessibilityLabel = emote.emoteName ?: @"Emote";
    if (descriptor && (self.pickerActiveTab == TPKPickerTabFavorites ||
                       self.pickerActiveTab == TPKPickerTabAll)) {
        cell.providerBadgeLabel.text = descriptor.providerIdentifier.uppercaseString;
        cell.providerBadgeLabel.hidden = NO;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
            descriptor.name, descriptor.providerName ?: descriptor.providerIdentifier,
            descriptor.sectionTitle ?: @"Emotes"];
    }

    // Réglage global, sauf l'option « favoris uniquement » qui limite à Favoris.
    BOOL wantsAnimated = emote.isAnimated && [TPKManager sharedManager].showPickerAnimations &&
        (![TPKManager sharedManager].showPickerAnimationsFavoritesOnly || self.pickerActiveTab == TPKPickerTabFavorites);

    TPKPickerResolvedEmote *resolved = [[TPKPickerResolvedEmote alloc] initWithEmote:emote];
    NSString *key = resolved.imageURL.absoluteString;
    cell.currentEmoteKey = key;
    cell.wantsAnimation = wantsAnimated;

    // cellFor ne démarre rien : cache hit immédiat, sinon attendre willDisplay.
    cell.emoteImageView.image = [[TPKEmoteImageCache sharedCache]
        cachedImageForResolvedEmote:resolved];

    return cell;
}

// ── Chemin animé : frames du cache pilotées par l'engine (CADisplayLink partagé).
- (BOOL)_tpk_configureAnimatedPickerCell:(TPKEmotePickerCell *)cell
                             resolvedEmote:(TPKPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode {
    TPKEmoteImageCache *cache   = [TPKEmoteImageCache sharedCache];
    TPKEmoteAnimationEngine *engine = [TPKEmoteAnimationEngine sharedEngine];

    __weak typeof(self) weakSelfForActivity = self;
    __weak TPKEmotePickerCell *weakCellForActivity = cell;
    BOOL (^cellIsStillActive)(void) = ^BOOL{
        TPKEmotePickerController *strongSelf = weakSelfForActivity;
        TPKEmotePickerCell *strongCell = weakCellForActivity;
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

    __weak TPKEmotePickerCell *weakCell = cell;
    void (^redraw)(void) = ^{
        __strong TPKEmotePickerCell *strongCell = weakCell;
        if (!strongCell || ![strongCell.currentEmoteKey isEqualToString:key]) return;
        UIImage *frame = [engine currentFrameForKey:key];
        if (frame) strongCell.emoteImageView.image = frame;
    };

    // Toute frame en cache s'affiche ; seule une boucle complète autorise le retour.
    if ([engine hasFramesForKey:key]) {
        if (!cellIsStillActive()) return NO;
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw(); // pose la frame courante immédiatement, sans attendre le prochain tick
        if ([engine hasCompleteFramesForKey:key]) return YES;
    }

    // Frames déjà décodées (ex: chat) : enregistrement direct, pas de redécodage.
    TPKEmoteAnimatedFrames *cachedFrames = [cache cachedFramesForResolvedEmote:resolved];
    if (cachedFrames) {
        if (!cellIsStillActive()) return NO;
        [engine registerFrames:cachedFrames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
        return YES;
    }

    // Cache hits immédiats ; décodage neuf seulement après le délai de stabilité.
    if (!allowDecode) return NO;

    // Rien en cache : afficher la frame statique connue pendant le décodage.
    UIImage *staticCached = [cache cachedImageForResolvedEmote:resolved];
    if (staticCached) cell.emoteImageView.image = staticCached;

    __weak TPKEmotePickerCell *weakCellForLoad = cell;
    void (^applyFrames)(TPKEmoteAnimatedFrames *) = ^(TPKEmoteAnimatedFrames *frames) {
        if (!frames.images.count) return;
        TPKEmotePickerCell *strongCell = weakCellForLoad;
        if (!strongCell || !cellIsStillActive()) return;
        // Si la boucle complète a gagné la course, ignorer une preview tardive.
        if (frames.isPreview && [engine hasCompleteFramesForKey:key]) return;
        [engine registerFrames:frames forKey:key];
        [engine addObserver:strongCell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
    };

    cell.animationFrameRequest = [cache framesForResolvedEmote:resolved
        preview:^(TPKEmoteAnimatedFrames *previewFrames) {
            // Boucle légère (12 frames max) : visible sans attendre le décodage WebP.
            applyFrames(previewFrames);
        }
        completion:^(TPKEmoteAnimatedFrames * _Nullable frames) {
            TPKEmotePickerCell *strongCell = weakCellForLoad;
            if (frames) applyFrames(frames);
            if (strongCell && cellIsStillActive()) {
                strongCell.animationFrameRequest = nil;
            }
        }];
    return YES;
}

// ── Visibilité réelle / scroll ─────────────────────────────────────────────

- (void)_tpk_scheduleStaticImageForPickerCell:(TPKEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden) return;
    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.imageLoadGeneration;
    __weak typeof(self) weakSelf = self;
    __weak TPKEmotePickerCell *weakCell = cell;

    // Anti-flick : après 40 ms de stabilité, seule une cellule visible demande sa frame.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        TPKEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window ||
            strongSelf.emotePickerView.hidden || strongSelf.emoteCollectionView.hidden) return;
        if (strongCell.imageLoadGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        TPKEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote) return;
        TPKPickerResolvedEmote *resolved = [[TPKPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;

        TPKEmoteImageCache *cache = [TPKEmoteImageCache sharedCache];
        UIImage *cached = [cache cachedImageForResolvedEmote:resolved];
        if (cached) {
            strongCell.emoteImageView.image = cached;
            return;
        }
        [cache imageForResolvedEmote:resolved completion:^(UIImage * _Nullable image) {
            TPKEmotePickerCell *completionCell = weakCell;
            TPKEmotePickerController *completionSelf = weakSelf;
            if (!image || !completionSelf || completionSelf.pickerSearchAlertActive ||
                !completionSelf.emotePickerView.window || !completionCell || !completionCell.window ||
                completionCell.imageLoadGeneration != generation ||
                ![completionCell.currentEmoteKey isEqualToString:key]) return;
            completionCell.emoteImageView.image = image;
        }];
    });
}

- (void)_tpk_scheduleAnimationForPickerCell:(TPKEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        !cell.wantsAnimation || self.emoteCollectionView.hidden) return;
    if (cell.animationFrameRequest) return; // décodage courant déjà lié à cette cellule

    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.animationGeneration;
    __weak typeof(self) weakSelf = self;
    __weak TPKEmotePickerCell *weakCell = cell;

    TPKEmote *initialEmote = [self _emoteForIndexPath:indexPath];
    if (!initialEmote || !initialEmote.isAnimated) return;
    TPKPickerResolvedEmote *initialResolved = [[TPKPickerResolvedEmote alloc] initWithEmote:initialEmote];
    if (![initialResolved.imageURL.absoluteString isEqualToString:key]) return;

    // Cache hit : première passe ne branche que les frames existantes, sans décodage.
    BOOL attachedFromCache = [self _tpk_configureAnimatedPickerCell:cell
                                                        resolvedEmote:initialResolved
                                                                  key:key
                                                           generation:generation
                                                          allowDecode:NO];
    if (attachedFromCache) return;

    // Annulables via didEndDisplayingCell : preview dès le prochain run loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        TPKEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window) return;
        if (strongCell.animationGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        TPKEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote || !emote.isAnimated) return;
        TPKPickerResolvedEmote *resolved = [[TPKPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;
        [strongSelf _tpk_configureAnimatedPickerCell:strongCell
                                        resolvedEmote:resolved
                                                  key:key
                                           generation:generation
                                          allowDecode:YES];
    });
}

- (void)_tpk_deactivateVisiblePickerAnimations {
    for (TPKEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell.animationFrameRequest cancel];
        cell.animationFrameRequest = nil;
        cell.imageLoadGeneration += 1;
        cell.animationGeneration += 1;
        [[TPKEmoteAnimationEngine sharedEngine] removeObserver:cell];
    }
}

- (void)_tpk_activateVisiblePickerAnimations {
    if (self.pickerSearchAlertActive || self.pickerScrollInProgress ||
        self.emoteCollectionView.isTracking || self.emoteCollectionView.isDragging ||
        self.emoteCollectionView.isDecelerating || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden || self.emotePickerView.hidden) return;
    for (NSIndexPath *indexPath in self.emoteCollectionView.indexPathsForVisibleItems) {
        TPKEmotePickerCell *cell = (TPKEmotePickerCell *)
            [self.emoteCollectionView cellForItemAtIndexPath:indexPath];
        if (cell) {
            [self _tpk_scheduleStaticImageForPickerCell:cell atIndexPath:indexPath];
            [self _tpk_scheduleAnimationForPickerCell:cell atIndexPath:indexPath];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView
        willDisplayCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    TPKEmotePickerCell *pickerCell = (TPKEmotePickerCell *)cell;
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
    [self _tpk_scheduleStaticImageForPickerCell:pickerCell atIndexPath:indexPath];
    [self _tpk_scheduleAnimationForPickerCell:pickerCell atIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView
 didEndDisplayingCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    TPKEmotePickerCell *pickerCell = (TPKEmotePickerCell *)cell;
    [pickerCell.animationFrameRequest cancel];
    pickerCell.animationFrameRequest = nil;
    pickerCell.imageLoadGeneration += 1;
    pickerCell.animationGeneration += 1;
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = YES;
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:YES];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:YES];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.emoteCollectionView || decelerate) return;
    self.pickerScrollInProgress = NO;
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    if (self.pickerCatalogReloadPending) [self _tpk_applyCatalogUpdateNow];
    [self _tpk_activateVisiblePickerAnimations];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = NO;
    [[TPKEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[TPKEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    if (self.pickerCatalogReloadPending) [self _tpk_applyCatalogUpdateNow];
    [self _tpk_activateVisiblePickerAnimations];
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // ── Étape 1 : trouver la ChatInputView (référence stockée, puis BFS fenêtre) ──
    UIView *inputRoot = self.emotePickerTextField;

    if (!inputRoot) {
        [[TPKManager sharedManager] log:@"⚠️ didSelect: emotePickerTextField nil → BFS fenêtre"];
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

    // ── Étape 2 : emotePickerTextEntryView (firstResponder) ; BFS en fallback si nil ──
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

    // ── Étape 3: construire le texte à insérer ────────────────────────────────
    NSString *currentText = @"";
    if (textView)       currentText = textView.text  ?: @"";
    else if (textField) currentText = textField.text ?: @"";

    NSString *prefix  = (currentText.length > 0 && ![currentText hasSuffix:@" "]) ? @" " : @"";
    NSString *emoteText = emote.emoteName ?: @"";
    NSString *stableKey = TPKPickerStableEmoteKey(emote);
    NSString *favoriteComposition = stableKey.length
        ? [[TPKEmoteCatalog sharedCatalog]
            favoriteCompositionTextForEmoteKey:stableKey] : nil;
    if (favoriteComposition.length) emoteText = favoriteComposition;
    NSString *toAppend = [NSString stringWithFormat:@"%@%@ ", prefix, emoteText];

    // ── Étape 4: insertion ─────────────────────────────────────────────────
    // insertText: ne notifie pas SwiftUI → copier dans le presse-papier + paste:.
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
        } else {
            // Ultime fallback
            [textView insertText:toAppend];
            inserted = YES;
            [[TPKManager sharedManager] log:@"⚠️ paste: non dispo → insertText: fallback"];
        }

        // Restaurer le presse-papier après l'animation de paste
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            pb.string = savedString ?: @"";
        });

        // Forcer UITextViewTextDidChangeNotification si paste: ne l'a pas déclenchée.
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
        inserted = YES;
    } else if (keyInput) {
        [(UIView *)keyInput becomeFirstResponder];
        [(id<UIKeyInput>)keyInput insertText:toAppend];
        inserted = YES;
    }

    if (!inserted) {
        [[TPKManager sharedManager] log:@"❌ didSelect: aucun champ texte trouvé — emote=%@", emote.emoteName];
    }

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
