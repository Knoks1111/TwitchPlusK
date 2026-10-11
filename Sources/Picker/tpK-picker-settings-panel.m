/*
 * tpK-picker-settings-panel.m
 * Extrait de tpK-core-manager.m (nettoyage picker).
 *
 * Refonte (mi-août 2026) : les anciennes mini-previews par ligne
 * (_buildPreviewContentForKey:/_updatePreviewForKey:) sont remplacées par un
 * seul faux chat flottant, une vraie instance de
 * TPKChatCustomView alimentée par un TPKChatMessageStore factice —
 * garanti 100% identique au rendu réel, sans double maintenance. Ajout
 * également des catégories Tailles / Apparence / Modération et des couleurs
 * (toggle unique + 3 UIColorWell), auparavant en dur dans
 * tpK-chat-custom-view.m.
 */

#import "Picker/tpK-picker-settings-panel.h"
#import "Picker/tpK-picker-controller.h"
#import "Picker/tpK-picker-resolved-emote.h"
#import "Core/tpK-core-manager.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Chat/tpK-chat-message.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Emote/tpK-emote-provider.h"
#import "Localization/tpK-localization-manager.h"
#import <objc/runtime.h>

static const char kTPKRowKeyTag = 0;

typedef NS_ENUM(NSInteger, TPKPickerOption) {
    TPKPickerOptionHeight = 0,
    TPKPickerOptionEmoteScale,
};


// ============================================================
// MARK: - Objet minimal <TPKResolvedEmote> pour l'emote Twitch
// native fixe (Kappa) du faux message de preview — pas de provider
// Twitch générique disponible hors du flux IRC réel.
// ============================================================

@interface TPKPickerSizesPreviewAsset : NSObject <TPKResolvedEmote>
@property (nonatomic, copy, readonly) NSString *emoteID;
@property (nonatomic, assign, readonly) CGSize nativeSize;
@property (nonatomic, strong, readonly) NSURL *imageURL;
@property (nonatomic, assign, readonly) BOOL isAnimated;
- (instancetype)initWithEmoteID:(NSString *)emoteID
                            size:(CGSize)size
                        imageURL:(NSURL *)imageURL;
@end

@implementation TPKPickerSizesPreviewAsset
- (instancetype)initWithEmoteID:(NSString *)emoteID
                            size:(CGSize)size
                        imageURL:(NSURL *)imageURL {
    self = [super init];
    if (self) {
        _emoteID = [emoteID copy];
        _nativeSize = size;
        _imageURL = imageURL;
        _isAnimated = NO;
    }
    return self;
}
@end


// Capsule de catégories calée sur le composant d'onglets du picker. Elle
// recalcule ses trois segments en proportions égales à chaque rotation ou
// changement de largeur, sans dépendre du rendu natif de UISegmentedControl.
@interface TPKPickerCategoryCapsuleView : UIView
@property (nonatomic, weak) UIView *categoryIndicatorView;
@property (nonatomic, copy) NSArray<UIButton *> *categoryButtons;
@property (nonatomic, assign) NSInteger selectedIndex;
@end

@implementation TPKPickerCategoryCapsuleView

- (void)layoutSubviews {
    [super layoutSubviews];
    NSUInteger count = self.categoryButtons.count;
    if (count == 0) return;

    CGFloat segmentWidth = self.bounds.size.width / (CGFloat)count;
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
    self.categoryIndicatorView.layer.cornerRadius = self.bounds.size.height / 2.0;
    self.categoryIndicatorView.frame = CGRectMake(segmentWidth * self.selectedIndex,
                                                   0,
                                                   segmentWidth,
                                                   self.bounds.size.height);
    [self.categoryButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger index, BOOL *stop) {
        button.frame = CGRectMake(segmentWidth * index, 0, segmentWidth, self.bounds.size.height);
    }];
}

@end


@interface TPKPickerSizesPanel ()
@property (nonatomic, weak, readwrite) UIView *panelView;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISlider *> *sizeSliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *>  *sizeValueLabels;
// Libellés (nameLbl) des lignes de sliders, gardés à part de sizeValueLabels
// (qui contient la pastille "+X pt") — nécessaire pour retraduire ces
// lignes à la volée sur changement de langue (voir
// TPKLanguageDidChangeNotification / _refreshLocalizedStrings).
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *sizeRowLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIColorWell *> *colorWells;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *colorRowLabels;
// Titre + toggle de la section Couleurs (voir
// _buildSystemColorsSectionInScrollView:) — mêmes besoins de retraduction
// à la volée que sizeRowLabels ci-dessus.
@property (nonatomic, weak) UILabel *colorsSectionLabel;
@property (nonatomic, weak) UILabel *colorsToggleLabel;
// Lignes de highlights (toggle + couleur combinés) : mention du viewer et
// premier message. Elles partagent le même constructeur pour garantir le
// même rendu et le même placement des contrôles.
@property (nonatomic, weak) UISwitch *selfMentionSwitch;
@property (nonatomic, weak) UIColorWell *selfMentionColorWell;
@property (nonatomic, weak) UILabel *selfMentionRowLabel;
@property (nonatomic, weak) UISwitch *firstMessageSwitch;
@property (nonatomic, weak) UIColorWell *firstMessageColorWell;
@property (nonatomic, weak) UILabel *firstMessageRowLabel;
@property (nonatomic, weak) UISwitch *sharedChatAvatarsSwitch;
@property (nonatomic, weak) UILabel *sharedChatAvatarsRowLabel;
@property (nonatomic, weak) UILabel *moderationSectionLabel;
@property (nonatomic, weak) UILabel *deletedPreviewLabel;
@property (nonatomic, weak) UISegmentedControl *deletedPreviewControl;
@property (nonatomic, weak) UILabel *deletedStyleLabel;
@property (nonatomic, weak) UISegmentedControl *deletedStyleControl;
@property (nonatomic, weak) UILabel *moderationDetailsLabel;
@property (nonatomic, weak) UISwitch *moderationDetailsSwitch;
@property (nonatomic, weak) UILabel *deletedOpacityLabel;
@property (nonatomic, weak) UILabel *deletedOpacityValueLabel;
@property (nonatomic, weak) UISlider *deletedOpacitySlider;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIButton *> *pickerOrientationLabels;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UILabel *> *pickerValueLabels;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UISlider *> *pickerSliders;
@property (nonatomic, assign) BOOL pickerEditingLandscape;
@property (nonatomic, strong) TPKChatMessageStore *fakeChatStore;
@property (nonatomic, strong) TPKChatCustomView *fakeChatView;
@property (nonatomic, strong) UIColor *panelTextColor;
@property (nonatomic, strong) UIColor *panelSubColor;
// Couleurs structurelles mémorisées pour pouvoir recolorer à la volée le
// panneau (séparateurs, capsule de catégories, segmented controls) lors d'une
// bascule du mode OLED, sans reconstruire toute la hiérarchie.
@property (nonatomic, strong) UIColor *panelSepColor;
@property (nonatomic, strong) UIColor *panelCardColor;
@property (nonatomic, weak) TPKPickerCategoryCapsuleView *categoryCapsuleView;
@property (nonatomic, strong) NSArray<UIButton *> *categoryButtons;
@property (nonatomic, weak) UIScrollView *sizesCategoryView;
@property (nonatomic, weak) UIScrollView *appearanceCategoryView;
@property (nonatomic, weak) UIScrollView *moderationCategoryView;
@end

@implementation TPKPickerSizesPanel

- (NSArray<NSArray *> *)_sizeOptionsTable {
    return @[
        @[@"emote7TVSize",     L(@"title_emotes_7tv"),         @12, @56],
        @[@"emoteTwitchSize",  L(@"size_label_emote_twitch"),  @12, @56],
        @[@"gifSize",          L(@"size_label_gif"),           @12, @96],
        @[@"badgeSize",        L(@"size_label_badges"),        @8,  @34],
        @[@"usernameFontSize", L(@"size_label_username"),      @8,  @28],
        @[@"messageFontSize",  L(@"size_label_message"),       @8,  @28],
        @[@"lineSpacing",      L(@"size_label_line_spacing"),  @0,  @30],
        @[@"usernameMessageSpacing", L(@"size_label_username_message_spacing"), @0, @20],
        @[@"emoteVerticalOffset", L(@"size_label_emote_offset"), @-10, @10],
    ];
}

- (TPKEmote *)_findEZEmote {
    TPKEmote *ez = nil;
    for (TPKEmote *e in self.picker.emotePickerAllEmotes) {
        if ([e.emoteName isEqualToString:@"EZ"]) { ez = e; break; }
    }
    if (!ez) ez = self.picker.emotePickerGlobalEmotes.firstObject ?: self.picker.emotePickerAllEmotes.firstObject;
    return ez;
}

// Token emote 7TV (EZ ou fallback) + token espace de fin — factorisé car
// réutilisé par plusieurs messages factices (message normal + commentaires
// sub/prime) pour montrer le rendu emote7TVSize dans plusieurs contextes.
// Tableau vide si aucune emote 7TV disponible (catalogue pas encore chargé) —
// le message factice reste alors sans cette emote, sans erreur.
- (NSArray<TPKChatToken *> *)_ezEmoteTokensWithTrailingSpace {
    TPKEmote *ez = [self _findEZEmote];
    if (!ez) return @[];
    TPKChatToken *emoteTok = [TPKChatToken emoteToken:ez.emoteName
                                                 provider:TPKChatTokenTypeEmote7TV
                                                  emoteID:ez.emoteID];
    emoteTok.resolvedEmote = [[TPKPickerResolvedEmote alloc] initWithEmote:ez];
    return @[emoteTok, [TPKChatToken textToken:@" "]];
}

- (void)buildInView:(UIView *)container
              frame:(CGRect)frame
            bgColor:(UIColor *)bgColor
          textColor:(UIColor *)textColor
           subColor:(UIColor *)subColor
           sepColor:(UIColor *)sepColor
             accent:(UIColor *)accent
          cardColor:(UIColor *)cardColor {

    UIView *sizesPanel = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, frame.size.width, frame.size.height)];
    sizesPanel.backgroundColor = bgColor;
    sizesPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sizesPanel.hidden = YES;
    self.panelView       = sizesPanel;
    self.sizeSliders      = [NSMutableDictionary dictionary];
    self.sizeValueLabels  = [NSMutableDictionary dictionary];
    self.sizeRowLabels    = [NSMutableDictionary dictionary];
    self.colorWells        = [NSMutableDictionary dictionary];
    self.colorRowLabels    = [NSMutableDictionary dictionary];
    self.panelTextColor    = textColor;
    self.panelSubColor     = subColor;
    self.panelSepColor     = sepColor;
    self.panelCardColor    = cardColor;

    // Trois catégories seulement. Cette capsule reprend exactement la logique
    // visuelle des onglets du picker : un fond pilule partagé et un indicateur
    // violet arrondi qui se déplace derrière le bouton actif.
    CGFloat categoryX = 12.0;
    CGFloat categoryY = 8.0;
    CGFloat categoryH = 32.0;
    CGFloat categoryW = frame.size.width - 92.0; // place pour Retour/Réglages
    TPKPickerCategoryCapsuleView *categoryCapsule = [[TPKPickerCategoryCapsuleView alloc] initWithFrame:
        CGRectMake(categoryX, categoryY, categoryW, categoryH)];
    categoryCapsule.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    categoryCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    categoryCapsule.clipsToBounds = YES;
    [sizesPanel addSubview:categoryCapsule];
    self.categoryCapsuleView = categoryCapsule;

    UIView *categoryIndicator = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, categoryW / 3.0, categoryH)];
    // Sélection neutre : le gros fond accentué bleu/violet attirait beaucoup
    // trop l'œil dans ce panneau. Une légère pastille blanche translucide
    // conserve l'indication de catégorie active sans ajouter de couleur.
    categoryIndicator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    categoryIndicator.layer.cornerRadius = categoryH / 2.0;
    [categoryCapsule addSubview:categoryIndicator];
    categoryCapsule.categoryIndicatorView = categoryIndicator;

    NSArray<NSString *> *categoryTitles = @[
        L(@"sizes_category_sizes"),
        L(@"sizes_category_appearance"),
        L(@"sizes_category_moderation"),
    ];
    NSMutableArray<UIButton *> *categoryButtons = [NSMutableArray arrayWithCapacity:3];
    for (NSInteger index = 0; index < 3; index++) {
        // UIButtonTypeSystem peut injecter le fond/tint bleu automatique de
        // UIKit derrière le titre selon la version d'iOS et les réglages
        // d'accessibilité. Les catégories gèrent déjà elles-mêmes leur état
        // sélectionné : un bouton custom garantit donc un fond transparent.
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake((categoryW / 3.0) * index, 0, categoryW / 3.0, categoryH);
        button.tag = index;
        button.backgroundColor = [UIColor clearColor];
        button.showsTouchWhenHighlighted = NO;
        button.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.75;
        [button setTitle:categoryTitles[index] forState:UIControlStateNormal];
        [button setTitleColor:subColor forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
        [button addTarget:self action:@selector(_categoryTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        [categoryCapsule addSubview:button];
        [categoryButtons addObject:button];
    }
    self.categoryButtons = categoryButtons;
    categoryCapsule.categoryButtons = categoryButtons;
    categoryCapsule.selectedIndex = 0;
    categoryButtons.firstObject.selected = YES;

    CGRect categoryFrame = CGRectMake(0, 48, frame.size.width, frame.size.height - 48);
    UIScrollView *sizesCategory = [[UIScrollView alloc] initWithFrame:categoryFrame];
    UIScrollView *appearanceCategory = [[UIScrollView alloc] initWithFrame:categoryFrame];
    UIScrollView *moderationCategory = [[UIScrollView alloc] initWithFrame:categoryFrame];
    for (UIScrollView *category in @[sizesCategory, appearanceCategory, moderationCategory]) {
        category.backgroundColor = [UIColor clearColor];
        category.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sizesPanel addSubview:category];
    }
    appearanceCategory.hidden = YES;
    moderationCategory.hidden = YES;
    self.sizesCategoryView = sizesCategory;
    self.appearanceCategoryView = appearanceCategory;
    self.moderationCategoryView = moderationCategory;

    // Le faux chat n'est plus construit ici : il vit dans une fenêtre
    // flottante séparée gérée par le picker (voir -[TPKEmotePickerController
    // emotePickerSizesToggleTapped]), positionnée au-dessus du champ de
    // saisie — le panneau scrollable ⚙️ Tailles ne peut pas héberger un
    // aperçu positionné librement puisqu'il EST l'inputView (remplace le
    // clavier). On construit quand même fakeChatStore/fakeChatView ici pour
    // que le controller puisse les récupérer via les accesseurs publics.
    [self _setupFakeChatView];

    CGFloat appearanceY = 8.0;
    appearanceY = [self _buildSystemColorsSectionInScrollView:appearanceCategory atY:appearanceY
                                                       width:frame.size.width
                                                   textColor:textColor subColor:subColor
                                                    sepColor:sepColor accent:accent];

    appearanceY = [self _buildSelfMentionSectionInScrollView:appearanceCategory atY:appearanceY
                                                      width:frame.size.width
                                                  textColor:textColor subColor:subColor
                                                   sepColor:sepColor accent:accent];
    appearanceY = [self _buildFirstMessageSectionInScrollView:appearanceCategory atY:appearanceY
                                                       width:frame.size.width
                                                   textColor:textColor subColor:subColor
                                                    sepColor:sepColor accent:accent];
    appearanceY = [self _buildSharedChatAvatarsSectionInScrollView:appearanceCategory atY:appearanceY
                                                            width:frame.size.width
                                                        textColor:textColor
                                                         sepColor:sepColor accent:accent];
    appearanceCategory.contentSize = CGSizeMake(frame.size.width, appearanceY);

    CGFloat moderationY = 8.0;
    moderationY = [self _buildModerationSectionInScrollView:moderationCategory atY:moderationY
                                                      width:frame.size.width
                                                  textColor:textColor subColor:subColor
                                                   sepColor:sepColor accent:accent];
    moderationCategory.contentSize = CGSizeMake(frame.size.width, moderationY);

CGFloat contentY = 8.0;
    CGFloat rowH = 60.0;
    self.pickerOrientationLabels = [NSMutableDictionary dictionary];
    self.pickerValueLabels = [NSMutableDictionary dictionary];
    self.pickerSliders = [NSMutableDictionary dictionary];
    // Réglages du picker en tête : les plus structurants du panneau.
    for (NSNumber *boxed in @[@(TPKPickerOptionHeight), @(TPKPickerOptionEmoteScale)]) {
        contentY = [self _buildPickerOptionRow:boxed.integerValue
                                   inScrollView:sizesCategory
                                            atY:contentY
                                          width:frame.size.width
                                      textColor:textColor
                                       subColor:subColor
                                        sepColor:sepColor
                                         accent:accent];
    }
    for (NSArray *entry in self._sizeOptionsTable) {
        NSString *key = entry[0], *label = entry[1];
        CGFloat minVal = [entry[2] doubleValue], maxVal = [entry[3] doubleValue];
        CGFloat current = [[[TPKChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
        if (current < minVal || current > maxVal) current = minVal;

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, contentY, frame.size.width, rowH)];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, rowH - 0.5, frame.size.width - 24, 0.5)];
        rowSep.backgroundColor = sepColor;
        rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:rowSep];

        const CGFloat pillW = 44.0;
        CGFloat resetLeft = frame.size.width - 32;
        CGFloat pillLeft = resetLeft - 8 - pillW;

        UILabel *nameLbl = [[UILabel alloc] initWithFrame:
            CGRectMake(12, 11, pillLeft - 12 - 6, 16)];
        nameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        nameLbl.textColor = textColor;
        nameLbl.text = label;
        nameLbl.lineBreakMode = NSLineBreakByClipping;
        nameLbl.adjustsFontSizeToFitWidth = YES;
        nameLbl.minimumScaleFactor = 0.7;
        nameLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:nameLbl];
        self.sizeRowLabels[key] = nameLbl;

        UILabel *valuePill = [[UILabel alloc] initWithFrame:
            CGRectMake(pillLeft, 7, pillW, 20)];
        valuePill.font = [UIFont boldSystemFontOfSize:11];
        valuePill.textColor = [UIColor whiteColor];
        valuePill.textAlignment = NSTextAlignmentCenter;
        valuePill.backgroundColor = accent;
        valuePill.layer.cornerRadius = 6;
        valuePill.layer.masksToBounds = YES;
        valuePill.text = [NSString stringWithFormat:@"%+ld pt", (long)llround(current)];
        valuePill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [row addSubview:valuePill];
        self.sizeValueLabels[key] = valuePill;

        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resetBtn.frame = CGRectMake(resetLeft, 4, 28, 24);
        resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:rCfg]
                  forState:UIControlStateNormal];
        resetBtn.tintColor = subColor;
        objc_setAssociatedObject(resetBtn, &kTPKRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [resetBtn addTarget:self action:@selector(_rowResetTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:resetBtn];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, 34, frame.size.width - 24, 22)];
        slider.minimumValue = minVal;
        slider.maximumValue = maxVal;
        slider.value = (float)current;
        slider.minimumTrackTintColor = accent;
        slider.maximumTrackTintColor = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
        slider.thumbTintColor        = accent;
        slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        objc_setAssociatedObject(slider, &kTPKRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [slider addTarget:self action:@selector(_rowSliderChanged:)
          forControlEvents:UIControlEventValueChanged];
        [row addSubview:slider];
        self.sizeSliders[key] = slider;

        [sizesCategory addSubview:row];
        contentY += rowH;
}
    sizesCategory.contentSize = CGSizeMake(frame.size.width, contentY);
// Chaque catégorie scrolle indépendamment : changer d'onglet ne fait pas
    // sauter le clavier ni l'aperçu.
    [container addSubview:sizesPanel];

    // buildInView: n'est appelé qu'une fois par panneau (voir le controller) —
    // c'est donc le bon endroit pour s'abonner une seule fois au changement
    // de langue. Voir _handleLanguageDidChange: plus bas pour le pourquoi.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(_handleLanguageDidChange:)
                                                  name:TPKLanguageDidChangeNotification
                                                object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:TPKLanguageDidChangeNotification object:nil];
}

#pragma mark - Retraduction à la volée (TPKLanguageDidChangeNotification)
//
// Tout le texte de ce panneau (labels des sliders, section Couleurs, ligne
// "Vous êtes mentionné", faux chat de preview) est construit une seule fois
// dans buildInView:/_populateFakeChatStore: avec le résultat de L() figé
// dans des NSString — sans cet observateur, un changement de langue en
// cours de session ne se reflète qu'au prochain lancement de l'app (nouvel
// appel à L() au prochain buildInView:). On retraduit ici en place plutôt
// que de reconstruire tout le panneau : les frames sont statiques, pas
// besoin de relayout, seul le texte affiché change.
- (void)_handleLanguageDidChange:(NSNotification *)note {
    [self _refreshLocalizedStrings];
}

- (void)_refreshLocalizedStrings {
    NSArray<NSString *> *categoryTitles = @[
        L(@"sizes_category_sizes"),
        L(@"sizes_category_appearance"),
        L(@"sizes_category_moderation"),
    ];
    [self.categoryButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger index, BOOL *stop) {
        if (index < categoryTitles.count) {
            [button setTitle:categoryTitles[index] forState:UIControlStateNormal];
        }
    }];
    self.colorsSectionLabel.text = L(@"sizes_colors_section_title");
    self.colorsToggleLabel.text  = L(@"sizes_colors_toggle_label");
    self.firstMessageRowLabel.text = L(@"sizes_first_message_row_label");
    self.sharedChatAvatarsRowLabel.text = L(@"sizes_shared_chat_avatars_label");

    NSDictionary<NSString *, NSString *> *colorLabelKeys = @{
        @"subResubAccentColor": @"sizes_color_sub_resub",
        @"primeAccentColor":    @"sizes_color_prime",
        @"giftAccentColor":     @"sizes_color_gift",
    };
    for (NSString *key in colorLabelKeys) {
        self.colorRowLabels[key].text = L(colorLabelKeys[key]);
    }

    self.selfMentionRowLabel.text = L(@"sizes_self_mention_row_label");
    self.moderationSectionLabel.text = L(@"sizes_moderation_section_title");
    self.deletedPreviewLabel.text = L(@"sizes_deleted_preview_label");
    [self.deletedPreviewControl setTitle:L(@"sizes_deleted_preview_disabled") forSegmentAtIndex:0];
    [self.deletedPreviewControl setTitle:L(@"sizes_deleted_preview_tap") forSegmentAtIndex:1];
    [self.deletedPreviewControl setTitle:L(@"sizes_deleted_preview_revealed") forSegmentAtIndex:2];
    self.deletedStyleLabel.text = L(@"sizes_deleted_style_label");
    [self.deletedStyleControl setTitle:L(@"sizes_deleted_style_dimmed") forSegmentAtIndex:0];
    [self.deletedStyleControl setTitle:L(@"sizes_deleted_style_struck") forSegmentAtIndex:1];
    [self.deletedStyleControl setTitle:L(@"sizes_deleted_style_both") forSegmentAtIndex:2];
    self.moderationDetailsLabel.text = L(@"sizes_moderation_details_label");
    self.deletedOpacityLabel.text = L(@"sizes_deleted_opacity_label");

    // _sizeOptionsTable rappelle L() à chaque invocation : relire la table
    // suffit à obtenir les libellés dans la nouvelle langue, sans dupliquer
    // la liste des clés ici.
    for (NSArray *entry in self._sizeOptionsTable) {
        NSString *key = entry[0], *label = entry[1];
        self.sizeRowLabels[key].text = label;
    }

    // Faux chat : ses messages (pseudos, phrases système, cible de mention
    // "@Toi"/"@You", etc.) sont des NSString figées construites une seule
    // fois par _populateFakeChatStore: — on les reconstruit entièrement
    // plutôt que d'essayer de retraduire chaque message individuellement.
    [self.fakeChatStore removeAllMessages];
    [self _populateFakeChatStore:self.fakeChatStore];
    [self.fakeChatView reloadMessages];
}

#pragma mark - Sliders (tailles/espacements)

- (void)_rowSliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, &kTPKRowKeyTag);
    if (!key) return;
    NSInteger val = (NSInteger)roundf(slider.value);
    slider.value = (float)val;
    [[TPKChatAppearanceConfig sharedConfig] setValue:(CGFloat)val forSizeKey:key];
    self.sizeValueLabels[key].text = [NSString stringWithFormat:@"%+ld pt", (long)val];
    [self.fakeChatView reloadMessages];
}

- (void)_rowResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kTPKRowKeyTag);
    if (!key) return;
    [[TPKChatAppearanceConfig sharedConfig] resetKeyToDefault:key];
    CGFloat val = [[[TPKChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
    self.sizeSliders[key].value = (float)val;
    self.sizeValueLabels[key].text = [NSString stringWithFormat:@"%+ld pt", (long)llround(val)];
    [self.fakeChatView reloadMessages];
}

// Ligne de réglage du picker (hauteur ou taille des emotes). L'orientation
// suit l'écran : le curseur édite toujours la valeur de l'orientation courante.
- (CGFloat)_buildPickerOptionRow:(TPKPickerOption)option
                      inScrollView:(UIScrollView *)scrollView
                               atY:(CGFloat)y
                             width:(CGFloat)width
                         textColor:(UIColor *)textColor
                          subColor:(UIColor *)subColor
                           sepColor:(UIColor *)sepColor
                            accent:(UIColor *)accent {
    const CGFloat rowH = 60.0;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, rowH)];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *rowSep = [[UIView alloc] initWithFrame:
        CGRectMake(12, rowH - 0.5, width - 24, 0.5)];
    rowSep.backgroundColor = sepColor;
    rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:rowSep];

    const CGFloat pillW = 44.0;
    const CGFloat resetLeft = width - 32;
    const CGFloat pillLeft = resetLeft - 8 - pillW;

    UILabel *nameLbl = [[UILabel alloc] initWithFrame:
        CGRectMake(12, 11, pillLeft - 12 - 6, 16)];
    nameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    nameLbl.textColor = textColor;
    nameLbl.text = TPKPickerOptionIsPercent(option)
        ? L(@"size_label_picker_emote_size") : L(@"size_label_picker_height");
    nameLbl.lineBreakMode = NSLineBreakByClipping;
    nameLbl.adjustsFontSizeToFitWidth = YES;
    nameLbl.minimumScaleFactor = 0.7;
    nameLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:nameLbl];

    UILabel *valuePill = [[UILabel alloc] initWithFrame:
        CGRectMake(pillLeft, 7, pillW, 20)];
    valuePill.font = [UIFont boldSystemFontOfSize:11];
    valuePill.textColor = [UIColor whiteColor];
    valuePill.textAlignment = NSTextAlignmentCenter;
    valuePill.backgroundColor = accent;
    valuePill.layer.cornerRadius = 6;
    valuePill.layer.masksToBounds = YES;
    valuePill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:valuePill];
    self.pickerValueLabels[@(option)] = valuePill;

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(resetLeft, 4, 28, 24);
    resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"
                                 withConfiguration:rCfg]
              forState:UIControlStateNormal];
    resetBtn.tintColor = subColor;
    objc_setAssociatedObject(resetBtn, &kTPKRowKeyTag, @(option),
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [resetBtn addTarget:self action:@selector(_pickerOptionResetTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:resetBtn];

    // Pastille d'orientation : purement indicative, elle suit l'écran.
    const CGFloat indicatorW = 88.0;
    UIButton *indicator = [UIButton buttonWithType:UIButtonTypeCustom];
    indicator.frame = CGRectMake(12, 34, indicatorW, 22);
    indicator.backgroundColor = accent;
    indicator.layer.cornerRadius = 11;
    indicator.clipsToBounds = YES;
    indicator.userInteractionEnabled = NO;
    indicator.titleLabel.font = [UIFont systemFontOfSize:11.5
                                             weight:UIFontWeightSemibold];
    [indicator setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [row addSubview:indicator];
    self.pickerOrientationLabels[@(option)] = indicator;

    const CGFloat sliderLeft = 12 + indicatorW + 8;
    UISlider *slider = [[UISlider alloc] initWithFrame:
        CGRectMake(sliderLeft, 34, resetLeft - 8 - sliderLeft, 22)];
    slider.minimumTrackTintColor = accent;
    slider.maximumTrackTintColor = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
    slider.thumbTintColor        = accent;
    slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    NSString *activeKey = [self _pickerActiveKeyForOption:option];
    slider.minimumValue = TPKPickerOptionMinForKey(activeKey);
    slider.maximumValue = TPKPickerOptionMaxForKey(activeKey);
    objc_setAssociatedObject(slider, &kTPKRowKeyTag, @(option),
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [slider addTarget:self action:@selector(_pickerOptionSliderChanged:)
  forControlEvents:UIControlEventValueChanged];
    // Commit au relâchement, sinon le picker clignote à chaque tick.
    [slider addTarget:self action:@selector(_pickerOptionSliderReleased:)
  forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
               UIControlEventTouchCancel];
    [row addSubview:slider];
    self.pickerSliders[@(option)] = slider;

    [scrollView addSubview:row];
    return y + rowH;
}

static BOOL TPKPickerOptionIsPercent(TPKPickerOption option) {
    return option == TPKPickerOptionEmoteScale;
}

- (NSString *)_pickerActiveKeyForOption:(TPKPickerOption)option {
    NSString *base = TPKPickerOptionIsPercent(option) ? @"pickerEmoteScale"
                                                       : @"pickerHeight";
    return [NSString stringWithFormat:@"%@%@", base,
            self.pickerEditingLandscape ? @"Landscape" : @"Portrait"];
}

- (void)tpk_syncPickerSizeRow {
    self.pickerEditingLandscape = [self.picker pickerHostIsLandscape];
    [self _refreshPickerOptionControls];
}

- (void)_refreshPickerOptionControls {
    NSString *orientation = self.pickerEditingLandscape
        ? L(@"picker_orientation_landscape") : L(@"picker_orientation_portrait");
    for (NSNumber *boxed in self.pickerSliders) {
        TPKPickerOption option = boxed.integerValue;
        NSString *key = [self _pickerActiveKeyForOption:option];
        UISlider *slider = self.pickerSliders[boxed];
        slider.minimumValue = TPKPickerOptionMinForKey(key);
        slider.maximumValue = TPKPickerOptionMaxForKey(key);
        CGFloat value = [[[TPKChatAppearanceConfig sharedConfig]
            valueForKey:key] doubleValue];
        slider.value = (float)value;
        self.pickerValueLabels[boxed].text = [self _formattedPickerValue:value
                                                                   percent:TPKPickerOptionIsPercent(option)];
        [self.pickerOrientationLabels[boxed] setTitle:orientation
                                          forState:UIControlStateNormal];
    }
}

- (NSString *)_formattedPickerValue:(CGFloat)value percent:(BOOL)percent {
    return percent ? [NSString stringWithFormat:@"%ld %%", (long)llround(value * 100.0)]
                   : [NSString stringWithFormat:@"%ld pt", (long)llround(value)];
}

- (void)_pickerOptionSliderChanged:(UISlider *)slider {
    NSNumber *boxed = objc_getAssociatedObject(slider, &kTPKRowKeyTag);
    if (!boxed) return;
    TPKPickerOption option = boxed.integerValue;
    NSInteger value = TPKPickerOptionIsPercent(option)
        ? (NSInteger)lroundf(slider.value * 20.0)   // pas de 5 %
        : (NSInteger)roundf(slider.value);
    slider.value = TPKPickerOptionIsPercent(option) ? value / 20.0 : value;
    [[TPKChatAppearanceConfig sharedConfig]
        setValue:(CGFloat)slider.value forSizeKey:[self _pickerActiveKeyForOption:option]];
    self.pickerValueLabels[boxed].text = [self _formattedPickerValue:slider.value
                                                             percent:TPKPickerOptionIsPercent(option)];
}

- (void)_pickerOptionSliderReleased:(UISlider *)slider {
    [self.picker pickerSizePreferenceDidChange];
}

- (void)_pickerOptionResetTapped:(UIButton *)sender {
    NSNumber *boxed = objc_getAssociatedObject(sender, &kTPKRowKeyTag);
    if (!boxed) return;
    [[TPKChatAppearanceConfig sharedConfig]
        resetKeyToDefault:[self _pickerActiveKeyForOption:boxed.integerValue]];
    [self _refreshPickerOptionControls];
    [self.picker pickerSizePreferenceDidChange];
}

#pragma mark - Section couleurs (toggle + 3 UIColorWell)

- (CGFloat)_buildSystemColorsSectionInScrollView:(UIScrollView *)scrollView
                                              atY:(CGFloat)y
                                            width:(CGFloat)width
                                        textColor:(UIColor *)textColor
                                         subColor:(UIColor *)subColor
                                         sepColor:(UIColor *)sepColor
                                           accent:(UIColor *)accent {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    BOOL enabled = cfg.systemMessageBackgroundsEnabled;

    UILabel *sectionLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, width - 24, 16)];
    sectionLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    sectionLbl.textColor = subColor;
    sectionLbl.text = L(@"sizes_colors_section_title");
    sectionLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:sectionLbl];
    self.colorsSectionLabel = sectionLbl;
    y += 26;

    // Toggle maître — dés/réactive le fond teinté pour tous les types
    // d'un coup (barre + icône restent toujours visibles, voir
    // tpK-chat-custom-view.m).
    UIView *toggleRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    toggleRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *toggleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, width - 12 - 51 - 12 - 8, 20)];
    toggleLbl.font = [UIFont systemFontOfSize:13];
    toggleLbl.textColor = textColor;
    toggleLbl.text = L(@"sizes_colors_toggle_label");
    toggleLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [toggleRow addSubview:toggleLbl];
    self.colorsToggleLabel = toggleLbl;

    UISwitch *bgSwitch = [[UISwitch alloc] init];
    bgSwitch.onTintColor = accent;
    bgSwitch.on = enabled;
    bgSwitch.frame = CGRectMake(width - 12 - 51, 6, 51, 31);
    bgSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [bgSwitch addTarget:self action:@selector(_systemBGToggleChanged:)
       forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:bgSwitch];

    [scrollView addSubview:toggleRow];
    y += 44;

    UIView *sep0 = [[UIView alloc] initWithFrame:CGRectMake(12, y, width - 24, 0.5)];
    sep0.backgroundColor = sepColor;
    sep0.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:sep0];
    y += 8;

    NSArray<NSArray<NSString *> *> *colorRows = @[
        @[@"subResubAccentColor", L(@"sizes_color_sub_resub")],
        @[@"primeAccentColor",    L(@"sizes_color_prime")],
        @[@"giftAccentColor",     L(@"sizes_color_gift")],
    ];

    for (NSArray<NSString *> *entry in colorRows) {
        NSString *key = entry[0], *label = entry[1];
        UIColor *current = [cfg valueForKey:key];

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UILabel *nameLbl = [[UILabel alloc] initWithFrame:
            CGRectMake(12, 12, width - 12 - 36 - 32 - 12, 20)];
        nameLbl.font = [UIFont systemFontOfSize:13];
        nameLbl.textColor = enabled ? textColor : subColor;
        nameLbl.text = label;
        nameLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:nameLbl];
        self.colorRowLabels[key] = nameLbl;

        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resetBtn.frame = CGRectMake(width - 12 - 36 - 8 - 28, 8, 28, 28);
        resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:rCfg]
                  forState:UIControlStateNormal];
        resetBtn.tintColor = subColor;
        objc_setAssociatedObject(resetBtn, &kTPKRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [resetBtn addTarget:self action:@selector(_colorResetTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:resetBtn];

        UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(width - 12 - 36, 4, 36, 36)];
        well.selectedColor = current;
        well.supportsAlpha = NO;
        well.enabled = enabled;
        well.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        objc_setAssociatedObject(well, &kTPKRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [well addTarget:self action:@selector(_colorWellChanged:)
        forControlEvents:UIControlEventValueChanged];
        [row addSubview:well];
        self.colorWells[key] = well;

        [scrollView addSubview:row];
        y += 44;

        UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, y - 0.5, width - 24, 0.5)];
        rowSep.backgroundColor = sepColor;
        rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [scrollView addSubview:rowSep];
    }

    return y + 8;
}

#pragma mark - Lignes de highlights (toggle + couleur)

// Constructeur commun à « Vous êtes mentionné » et « Premier message ».
// Ces deux états utilisent exactement le même composant dans le chat ; leur
// réglage doit donc rester lui aussi identique, hors libellé/couleur/actions.
- (CGFloat)_buildHighlightRowInScrollView:(UIScrollView *)scrollView
                                      atY:(CGFloat)y
                                    width:(CGFloat)width
                                textColor:(UIColor *)textColor
                                 subColor:(UIColor *)subColor
                                 sepColor:(UIColor *)sepColor
                                   accent:(UIColor *)accent
                                 labelKey:(NSString *)labelKey
                                  enabled:(BOOL)enabled
                                    color:(UIColor *)color
                             toggleAction:(SEL)toggleAction
                              colorAction:(SEL)colorAction
                              resetAction:(SEL)resetAction
                                switchOut:(UISwitch * __autoreleasing *)switchOut
                                  wellOut:(UIColorWell * __autoreleasing *)wellOut
                                 labelOut:(UILabel * __autoreleasing *)labelOut {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    const CGFloat wellW = 36, switchW = 51, resetW = 28, gap = 6;
    CGFloat wellLeft   = width - 12 - wellW;
    CGFloat switchLeft = wellLeft - gap - switchW;
    CGFloat resetLeft  = switchLeft - gap - resetW;

    UILabel *nameLbl = [[UILabel alloc] initWithFrame:
        CGRectMake(12, 12, resetLeft - 12 - 8, 20)];
    nameLbl.font = [UIFont systemFontOfSize:13];
    nameLbl.textColor = enabled ? textColor : subColor;
    nameLbl.text = L(labelKey);
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    nameLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:nameLbl];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(resetLeft, 8, resetW, 28);
    resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:rCfg]
              forState:UIControlStateNormal];
    resetBtn.tintColor = subColor;
    [resetBtn addTarget:self action:resetAction
        forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:resetBtn];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = accent;
    sw.on = enabled;
    sw.frame = CGRectMake(switchLeft, 6, switchW, 31);
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sw addTarget:self action:toggleAction
   forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(wellLeft, 4, wellW, wellW)];
    well.selectedColor = color;
    well.supportsAlpha = NO;
    well.enabled = enabled;
    well.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [well addTarget:self action:colorAction
   forControlEvents:UIControlEventValueChanged];
    [row addSubview:well];

    if (switchOut) *switchOut = sw;
    if (wellOut) *wellOut = well;
    if (labelOut) *labelOut = nameLbl;

    [scrollView addSubview:row];
    y += 44;

    UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, y - 0.5, width - 24, 0.5)];
    rowSep.backgroundColor = sepColor;
    rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:rowSep];

    return y + 8;
}

- (CGFloat)_buildSelfMentionSectionInScrollView:(UIScrollView *)scrollView
                                             atY:(CGFloat)y
                                           width:(CGFloat)width
                                       textColor:(UIColor *)textColor
                                        subColor:(UIColor *)subColor
                                        sepColor:(UIColor *)sepColor
                                          accent:(UIColor *)accent {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    UISwitch *sw = nil;
    UIColorWell *well = nil;
    UILabel *label = nil;
    CGFloat nextY = [self _buildHighlightRowInScrollView:scrollView atY:y width:width
                                               textColor:textColor subColor:subColor
                                                sepColor:sepColor accent:accent
                                                labelKey:@"sizes_self_mention_row_label"
                                                 enabled:cfg.selfMentionHighlightEnabled
                                                   color:cfg.selfMentionHighlightColor
                                            toggleAction:@selector(_selfMentionToggleChanged:)
                                             colorAction:@selector(_selfMentionColorWellChanged:)
                                             resetAction:@selector(_selfMentionResetTapped:)
                                               switchOut:&sw wellOut:&well labelOut:&label];
    self.selfMentionSwitch = sw;
    self.selfMentionColorWell = well;
    self.selfMentionRowLabel = label;
    return nextY;
}

- (CGFloat)_buildFirstMessageSectionInScrollView:(UIScrollView *)scrollView
                                              atY:(CGFloat)y
                                            width:(CGFloat)width
                                        textColor:(UIColor *)textColor
                                         subColor:(UIColor *)subColor
                                         sepColor:(UIColor *)sepColor
                                           accent:(UIColor *)accent {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    UISwitch *sw = nil;
    UIColorWell *well = nil;
    UILabel *label = nil;
    CGFloat nextY = [self _buildHighlightRowInScrollView:scrollView atY:y width:width
                                               textColor:textColor subColor:subColor
                                                sepColor:sepColor accent:accent
                                                labelKey:@"sizes_first_message_row_label"
                                                 enabled:cfg.showFirstMessageBadge
                                                   color:cfg.firstMessageHighlightColor
                                            toggleAction:@selector(_firstMessageToggleChanged:)
                                             colorAction:@selector(_firstMessageColorWellChanged:)
                                             resetAction:@selector(_firstMessageResetTapped:)
                                               switchOut:&sw wellOut:&well labelOut:&label];
    self.firstMessageSwitch = sw;
    self.firstMessageColorWell = well;
    self.firstMessageRowLabel = label;
    return nextY;
}

- (CGFloat)_buildSharedChatAvatarsSectionInScrollView:(UIScrollView *)scrollView
                                                   atY:(CGFloat)y
                                                 width:(CGFloat)width
                                             textColor:(UIColor *)textColor
                                              sepColor:(UIColor *)sepColor
                                                accent:(UIColor *)accent {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, width - 87, 20)];
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = textColor;
    label.text = L(@"sizes_shared_chat_avatars_label");
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:label];
    self.sharedChatAvatarsRowLabel = label;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.frame = CGRectMake(width - 63, 6, 51, 31);
    toggle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    toggle.onTintColor = accent;
    toggle.on = cfg.sharedChatSourceAvatarsEnabled;
    [toggle addTarget:self action:@selector(_sharedChatAvatarsToggleChanged:)
       forControlEvents:UIControlEventValueChanged];
    [row addSubview:toggle];
    self.sharedChatAvatarsSwitch = toggle;

    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(12, 43.5, width - 24, 0.5)];
    separator.backgroundColor = sepColor;
    separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:separator];
    [scrollView addSubview:row];
    return y + 52;
}

- (void)_selfMentionToggleChanged:(UISwitch *)sw {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.selfMentionHighlightEnabled = sw.on;
    self.selfMentionColorWell.enabled = sw.on;
    self.selfMentionRowLabel.textColor = sw.on ? self.panelTextColor : self.panelSubColor;
    [self.fakeChatView reloadMessages];
}

- (void)_selfMentionColorWellChanged:(UIColorWell *)well {
    if (!well.selectedColor) return;
    [[TPKChatAppearanceConfig sharedConfig] setColor:well.selectedColor
                                              forColorKey:@"selfMentionHighlightColor"];
    [self.fakeChatView reloadMessages];
}

// Réinitialise les DEUX réglages de la ligne d'un coup (toggle + couleur) —
// contrairement aux resets de la section Couleurs qui ne touchent qu'UNE
// clé chacun : ici il n'y a qu'une seule ligne pour l'ensemble de la
// fonctionnalité, donc "réinitialiser" porte sur tout le bloc.
- (void)_selfMentionResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    [cfg resetColorKeyToDefault:@"selfMentionHighlightColor"];
    cfg.selfMentionHighlightEnabled = YES;
    self.selfMentionColorWell.selectedColor = cfg.selfMentionHighlightColor;
    self.selfMentionColorWell.enabled = YES;
    self.selfMentionSwitch.on = YES;
    self.selfMentionRowLabel.textColor = self.panelTextColor;
    [self.fakeChatView reloadMessages];
}

- (void)_firstMessageToggleChanged:(UISwitch *)sw {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.showFirstMessageBadge = sw.on;
    self.firstMessageColorWell.enabled = sw.on;
    self.firstMessageRowLabel.textColor = sw.on ? self.panelTextColor : self.panelSubColor;
    [self.fakeChatView reloadMessages];
}

- (void)_sharedChatAvatarsToggleChanged:(UISwitch *)sw {
    [TPKChatAppearanceConfig sharedConfig].sharedChatSourceAvatarsEnabled = sw.on;
    [self.fakeChatView reloadMessages];
}

- (void)_firstMessageColorWellChanged:(UIColorWell *)well {
    if (!well.selectedColor) return;
    [[TPKChatAppearanceConfig sharedConfig] setColor:well.selectedColor
                                              forColorKey:@"firstMessageHighlightColor"];
    [self.fakeChatView reloadMessages];
}

- (void)_firstMessageResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    [cfg resetColorKeyToDefault:@"firstMessageHighlightColor"];
    cfg.showFirstMessageBadge = YES;
    self.firstMessageColorWell.selectedColor = cfg.firstMessageHighlightColor;
    self.firstMessageColorWell.enabled = YES;
    self.firstMessageSwitch.on = YES;
    self.firstMessageRowLabel.textColor = self.panelTextColor;
    [self.fakeChatView reloadMessages];
}

#pragma mark - Section messages supprimés (sanction + atténuation)

- (CGFloat)_buildModerationSectionInScrollView:(UIScrollView *)scrollView
                                            atY:(CGFloat)y
                                          width:(CGFloat)width
                                      textColor:(UIColor *)textColor
                                       subColor:(UIColor *)subColor
                                       sepColor:(UIColor *)sepColor
                                         accent:(UIColor *)accent {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];

    UILabel *sectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, y, width - 24, 24)];
    sectionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    sectionLabel.textColor = subColor;
    sectionLabel.text = L(@"sizes_moderation_section_title");
    sectionLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:sectionLabel];
    self.moderationSectionLabel = sectionLabel;
    y += 26;

    UIView *previewRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 64)];
    previewRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *previewLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, width - 56, 18)];
    previewLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    previewLabel.textColor = textColor;
    previewLabel.text = L(@"sizes_deleted_preview_label");
    previewLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [previewRow addSubview:previewLabel];
    self.deletedPreviewLabel = previewLabel;

    UIButton *previewReset = [UIButton buttonWithType:UIButtonTypeSystem];
    previewReset.frame = CGRectMake(width - 40, 0, 28, 28);
    previewReset.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *previewResetCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [previewReset setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:previewResetCfg]
                  forState:UIControlStateNormal];
    previewReset.tintColor = subColor;
    [previewReset addTarget:self action:@selector(_deletedPreviewResetTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [previewRow addSubview:previewReset];

    UISegmentedControl *previewControl = [[UISegmentedControl alloc] initWithItems:@[
        L(@"sizes_deleted_preview_disabled"),
        L(@"sizes_deleted_preview_tap"),
        L(@"sizes_deleted_preview_revealed"),
    ]];
    previewControl.frame = CGRectMake(12, 28, width - 24, 30);
    previewControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    previewControl.selectedSegmentIndex = cfg.deletedMessageRevealMode;
    previewControl.selectedSegmentTintColor = accent;
    previewControl.backgroundColor = [self.panelCardColor colorWithAlphaComponent:0.92];
    previewControl.layer.cornerRadius = 8;
    previewControl.clipsToBounds = YES;
    [previewControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: subColor,
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]
    } forState:UIControlStateNormal];
    [previewControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]
    }
                                  forState:UIControlStateSelected];
    [previewControl addTarget:self action:@selector(_deletedPreviewChanged:)
             forControlEvents:UIControlEventValueChanged];
    [previewRow addSubview:previewControl];
    self.deletedPreviewControl = previewControl;

    UIView *previewSep = [[UIView alloc] initWithFrame:CGRectMake(12, 63.5, width - 24, 0.5)];
    previewSep.backgroundColor = sepColor;
    previewSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [previewRow addSubview:previewSep];
    [scrollView addSubview:previewRow];
    y += 64;

    UIView *styleRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 64)];
    styleRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *styleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, width - 56, 18)];
    styleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    styleLabel.textColor = textColor;
    styleLabel.text = L(@"sizes_deleted_style_label");
    styleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [styleRow addSubview:styleLabel];
    self.deletedStyleLabel = styleLabel;

    UIButton *styleReset = [UIButton buttonWithType:UIButtonTypeSystem];
    styleReset.frame = CGRectMake(width - 40, 0, 28, 28);
    styleReset.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *styleResetCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [styleReset setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:styleResetCfg]
                forState:UIControlStateNormal];
    styleReset.tintColor = subColor;
    [styleReset addTarget:self action:@selector(_deletedStyleResetTapped:)
         forControlEvents:UIControlEventTouchUpInside];
    [styleRow addSubview:styleReset];

    UISegmentedControl *styleControl = [[UISegmentedControl alloc] initWithItems:@[
        L(@"sizes_deleted_style_dimmed"),
        L(@"sizes_deleted_style_struck"),
        L(@"sizes_deleted_style_both"),
    ]];
    styleControl.frame = CGRectMake(12, 28, width - 24, 30);
    styleControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    styleControl.selectedSegmentIndex = cfg.deletedMessageStyle;
    styleControl.selectedSegmentTintColor = accent;
    styleControl.backgroundColor = [self.panelCardColor colorWithAlphaComponent:0.92];
    styleControl.layer.cornerRadius = 8;
    styleControl.clipsToBounds = YES;
    [styleControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: subColor,
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]
    } forState:UIControlStateNormal];
    [styleControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]
    }
                                forState:UIControlStateSelected];
    [styleControl addTarget:self action:@selector(_deletedStyleChanged:)
           forControlEvents:UIControlEventValueChanged];
    [styleRow addSubview:styleControl];
    self.deletedStyleControl = styleControl;

    UIView *styleSep = [[UIView alloc] initWithFrame:CGRectMake(12, 63.5, width - 24, 0.5)];
    styleSep.backgroundColor = sepColor;
    styleSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [styleRow addSubview:styleSep];
    [scrollView addSubview:styleRow];
    y += 64;

    UIView *toggleRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    toggleRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    const CGFloat switchW = 51, resetW = 28, gap = 6;
    CGFloat switchLeft = width - 12 - switchW;
    CGFloat resetLeft = switchLeft - gap - resetW;

    UILabel *toggleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, resetLeft - 20, 20)];
    toggleLabel.font = [UIFont systemFontOfSize:13];
    toggleLabel.textColor = textColor;
    toggleLabel.text = L(@"sizes_moderation_details_label");
    toggleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    toggleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [toggleRow addSubview:toggleLabel];
    self.moderationDetailsLabel = toggleLabel;

    UIButton *toggleReset = [UIButton buttonWithType:UIButtonTypeSystem];
    toggleReset.frame = CGRectMake(resetLeft, 8, resetW, 28);
    toggleReset.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *resetCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [toggleReset setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:resetCfg]
                 forState:UIControlStateNormal];
    toggleReset.tintColor = subColor;
    [toggleReset addTarget:self action:@selector(_moderationDetailsResetTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [toggleRow addSubview:toggleReset];

    UISwitch *detailsSwitch = [[UISwitch alloc] init];
    detailsSwitch.frame = CGRectMake(switchLeft, 6, switchW, 31);
    detailsSwitch.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    detailsSwitch.onTintColor = accent;
    detailsSwitch.on = cfg.showModerationDetails;
    [detailsSwitch addTarget:self action:@selector(_moderationDetailsChanged:)
            forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:detailsSwitch];
    self.moderationDetailsSwitch = detailsSwitch;

    UIView *toggleSep = [[UIView alloc] initWithFrame:CGRectMake(12, 43.5, width - 24, 0.5)];
    toggleSep.backgroundColor = sepColor;
    toggleSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [toggleRow addSubview:toggleSep];
    [scrollView addSubview:toggleRow];
    y += 44;

    UIView *opacityRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 60)];
    opacityRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    const CGFloat pillW = 44;
    resetLeft = width - 32;
    CGFloat pillLeft = resetLeft - 8 - pillW;

    UILabel *opacityLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 11, pillLeft - 18, 16)];
    opacityLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    opacityLabel.textColor = textColor;
    opacityLabel.text = L(@"sizes_deleted_opacity_label");
    opacityLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    opacityLabel.adjustsFontSizeToFitWidth = YES;
    opacityLabel.minimumScaleFactor = 0.7;
    opacityLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [opacityRow addSubview:opacityLabel];
    self.deletedOpacityLabel = opacityLabel;

    UILabel *opacityValue = [[UILabel alloc] initWithFrame:CGRectMake(pillLeft, 7, pillW, 20)];
    opacityValue.font = [UIFont boldSystemFontOfSize:11];
    opacityValue.textColor = [UIColor whiteColor];
    opacityValue.textAlignment = NSTextAlignmentCenter;
    opacityValue.backgroundColor = accent;
    opacityValue.layer.cornerRadius = 6;
    opacityValue.layer.masksToBounds = YES;
    opacityValue.text = [NSString stringWithFormat:@"%ld%%", (long)llround(cfg.deletedMessageTextOpacity * 100)];
    opacityValue.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [opacityRow addSubview:opacityValue];
    self.deletedOpacityValueLabel = opacityValue;

    UIButton *opacityReset = [UIButton buttonWithType:UIButtonTypeSystem];
    opacityReset.frame = CGRectMake(resetLeft, 4, 28, 24);
    opacityReset.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [opacityReset setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:resetCfg]
                  forState:UIControlStateNormal];
    opacityReset.tintColor = subColor;
    [opacityReset addTarget:self action:@selector(_deletedOpacityResetTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [opacityRow addSubview:opacityReset];

    UISlider *opacitySlider = [[UISlider alloc] initWithFrame:CGRectMake(12, 34, width - 24, 22)];
    opacitySlider.minimumValue = 0.25;
    opacitySlider.maximumValue = 1.0;
    opacitySlider.value = cfg.deletedMessageTextOpacity;
    opacitySlider.minimumTrackTintColor = accent;
    opacitySlider.maximumTrackTintColor = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
    opacitySlider.thumbTintColor = accent;
    opacitySlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [opacitySlider addTarget:self action:@selector(_deletedOpacityChanged:)
             forControlEvents:UIControlEventValueChanged];
    [opacityRow addSubview:opacitySlider];
    self.deletedOpacitySlider = opacitySlider;

    UIView *opacitySep = [[UIView alloc] initWithFrame:CGRectMake(12, 59.5, width - 24, 0.5)];
    opacitySep.backgroundColor = sepColor;
    opacitySep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [opacityRow addSubview:opacitySep];
    [scrollView addSubview:opacityRow];
    [self _updateDeletedOpacityControlsForStyle:cfg.deletedMessageStyle];
    return y + 68;
}

- (void)_updateDeletedOpacityControlsForStyle:(TPKDeletedMessageStyle)style {
    BOOL usesDimming = (style != TPKDeletedMessageStyleStrikethrough);
    self.deletedOpacitySlider.enabled = usesDimming;
    self.deletedOpacityLabel.textColor = usesDimming ? self.panelTextColor : self.panelSubColor;
    self.deletedOpacityValueLabel.alpha = usesDimming ? 1.0 : 0.45;
}

- (void)_deletedPreviewChanged:(UISegmentedControl *)control {
    TPKDeletedMessageRevealMode mode =
        (TPKDeletedMessageRevealMode)control.selectedSegmentIndex;
    [TPKChatAppearanceConfig sharedConfig].deletedMessageRevealMode = mode;
    [self.fakeChatView reloadMessages];
}

- (void)_deletedPreviewResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.deletedMessageRevealMode = TPKDeletedMessageRevealModeOnTap;
    self.deletedPreviewControl.selectedSegmentIndex = TPKDeletedMessageRevealModeOnTap;
    [self.fakeChatView reloadMessages];
}

- (void)_deletedStyleChanged:(UISegmentedControl *)control {
    TPKDeletedMessageStyle style = (TPKDeletedMessageStyle)control.selectedSegmentIndex;
    [TPKChatAppearanceConfig sharedConfig].deletedMessageStyle = style;
    [self _updateDeletedOpacityControlsForStyle:style];
    [self.fakeChatView reloadMessages];
}

- (void)_categoryTapped:(UIButton *)button {
    NSInteger selected = button.tag;
    self.categoryCapsuleView.selectedIndex = selected;
    [self.categoryCapsuleView setNeedsLayout];
    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self.categoryCapsuleView layoutIfNeeded];
    } completion:nil];
    [self.categoryButtons enumerateObjectsUsingBlock:^(UIButton *categoryButton, NSUInteger index, BOOL *stop) {
        categoryButton.selected = (index == selected);
    }];
    self.sizesCategoryView.hidden = (selected != 0);
    self.appearanceCategoryView.hidden = (selected != 1);
    self.moderationCategoryView.hidden = (selected != 2);
}

- (void)_deletedStyleResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.deletedMessageStyle = TPKDeletedMessageStyleDimmed;
    self.deletedStyleControl.selectedSegmentIndex = TPKDeletedMessageStyleDimmed;
    [self _updateDeletedOpacityControlsForStyle:TPKDeletedMessageStyleDimmed];
    [self.fakeChatView reloadMessages];
}

- (void)_moderationDetailsChanged:(UISwitch *)sw {
    [TPKChatAppearanceConfig sharedConfig].showModerationDetails = sw.on;
    [self.fakeChatView reloadMessages];
}

- (void)_moderationDetailsResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.showModerationDetails = YES;
    self.moderationDetailsSwitch.on = YES;
    [self.fakeChatView reloadMessages];
}

- (void)_deletedOpacityChanged:(UISlider *)slider {
    NSInteger percent = (NSInteger)llround(slider.value * 100.0);
    CGFloat value = percent / 100.0;
    slider.value = value;
    [[TPKChatAppearanceConfig sharedConfig] setValue:value
                                              forSizeKey:@"deletedMessageTextOpacity"];
    self.deletedOpacityValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    [self.fakeChatView reloadMessages];
}

- (void)_deletedOpacityResetTapped:(UIButton *)btn {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    [cfg resetKeyToDefault:@"deletedMessageTextOpacity"];
    self.deletedOpacitySlider.value = cfg.deletedMessageTextOpacity;
    self.deletedOpacityValueLabel.text = [NSString stringWithFormat:@"%ld%%",
        (long)llround(cfg.deletedMessageTextOpacity * 100.0)];
    [self.fakeChatView reloadMessages];
}

- (void)_systemBGToggleChanged:(UISwitch *)sw {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    cfg.systemMessageBackgroundsEnabled = sw.on;
    for (NSString *key in self.colorWells) {
        self.colorWells[key].enabled = sw.on;
        self.colorRowLabels[key].textColor = sw.on ? self.panelTextColor : self.panelSubColor;
    }
    [self.fakeChatView reloadMessages];
}

- (void)_colorWellChanged:(UIColorWell *)well {
    NSString *key = objc_getAssociatedObject(well, &kTPKRowKeyTag);
    if (!key || !well.selectedColor) return;
    [[TPKChatAppearanceConfig sharedConfig] setColor:well.selectedColor forColorKey:key];
    [self.fakeChatView reloadMessages];
}

- (void)_colorResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kTPKRowKeyTag);
    if (!key) return;
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    [cfg resetColorKeyToDefault:key];
    self.colorWells[key].selectedColor = [cfg valueForKey:key];
    [self.fakeChatView reloadMessages];
}

#pragma mark - Faux chat (preview live 1:1, hébergé par la fenêtre flottante du controller)

// Construit fakeChatStore/fakeChatView sans les attacher à aucune vue —
// c'est au controller (fenêtre flottante) de poser fakeChatView dans sa
// propre hiérarchie et de lui donner un frame. Card/titre de section/
// séparateur ne sont plus du ressort du panneau : ce sont des éléments de
// chrome de la fenêtre flottante désormais.
- (void)_setupFakeChatView {
    self.fakeChatStore = [[TPKChatMessageStore alloc] init];
    [self _populateFakeChatStore:self.fakeChatStore];

    TPKChatCustomView *chatView = [[TPKChatCustomView alloc] initWithStore:self.fakeChatStore];
    chatView.freezesTranscriptWhenScrolled = NO;
    // Le panneau est créé avec le picker mais son aperçu flotte hors de sa
    // hiérarchie. Tant qu'il est caché, il ne doit conserver ni observers ni
    // décodages animés. Le controller le réactive juste avant de l'afficher.
    chatView.renderingSuspended = YES;
    // Preview interactive : le même tap-to-reveal que dans le vrai chat est
    // testable directement, et la table peut défiler si son contenu dépasse
    // la hauteur disponible. Le conteneur de fenêtre bloque les touches vers
    // les vues Twitch situées derrière (voir tpK-picker-controller.m).
    chatView.userInteractionEnabled = YES;
    self.fakeChatView = chatView;
    [chatView reloadMessages];
}

// Messages factices couvrant tous les réglages du panneau, dans un ordre
// volontairement mélangé (pas juste "un de chaque type à la suite") pour se
// rapprocher d'un vrai fil de chat : gift, GIF Twitch, normal (badge + emote
// 7TV + emote Twitch native), sub avec commentaire (badge + emote 7TV dans le
// corps du commentaire, pas seulement la bannière), premier message supprimé
// replié, mention de soi supprimée révélée (highlights barre + fond
// configurables), puis prime avec commentaire.
- (void)_populateFakeChatStore:(TPKChatMessageStore *)store {
    NSDate *now = [NSDate date];

    TPKChatMessage *gift = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_gift"
                 timestamp:now
              authorUserID:@"tpk_preview_u4"
         authorDisplayName:L(@"preview_username")
                   rawText:@""];
    gift.type = TPKChatMessageTypeSystem;
    TPKSystemMessageInfo *giftInfo = [TPKSystemMessageInfo new];
    giftInfo.kind = TPKSystemMessageKindCommunityGift;
    giftInfo.massGiftCount = 5;
    giftInfo.senderTotalGiftCount = 12;
    gift.systemInfo = giftInfo;
    gift.systemPhrase = L(@"preview_gift_phrase");
    [store addMessage:gift];

    // GIF Twitch reçu : il passe par le même token et le même renderer que
    // les messages réels. L'URL est celle d'un GIF GIPHY public stable, le
    // texte restant visible automatiquement tant que l'image n'est pas
    // encore en cache.
    NSString *gifCaption = L(@"preview_gif_text");
    TPKChatMessage *gifMessage = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_gif_message"
                 timestamp:now
              authorUserID:@"tpk_preview_gif_user"
         authorDisplayName:L(@"preview_gif_username")
                   rawText:gifCaption];
    gifMessage.authorColor = [UIColor colorWithRed:0.95 green:0.42 blue:0.62 alpha:1.0];
    gifMessage.tokens = @[[TPKChatToken gifToken:gifCaption
                                             gifID:@"nqB7RzcmyWTjr03PA5"
                                               url:[NSURL URLWithString:
                                                   @"https://media3.giphy.com/media/v1.Y2lkPTc5MGI3NjExZzZ6bHRxb2F3djFzd3ZvOTgxY3VuaDJnc3VrNmNtenBjYnU0NDhxcyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/nqB7RzcmyWTjr03PA5/giphy.gif"]]];
    [store addMessage:gifMessage];

    TPKChatMessage *normal = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_normal"
                 timestamp:now
              authorUserID:@"tpk_preview_u1"
         authorDisplayName:L(@"preview_username")
                   rawText:L(@"preview_greeting")];
    normal.authorColor = [UIColor colorWithRed:0.35 green:0.68 blue:1.0 alpha:1.0];
    // Badge global Twitch (quasi toujours présent dans le catalogue chargé,
    // contrairement à un badge d'abonné propre à une chaîne) — best-effort :
    // s'il n'est pas encore résolu (catalogue pas chargé), le badge est
    // simplement absent du message de preview, sans erreur.
    normal.badgeIdentifiers = @[@"moderator/1"];

    NSMutableArray<TPKChatToken *> *tokens = [NSMutableArray array];
    [tokens addObject:[TPKChatToken textToken:
        [L(@"preview_greeting") stringByAppendingString:@" "]]];
    [tokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];

    TPKChatToken *kappaTok = [TPKChatToken emoteToken:@"Kappa"
                                                 provider:TPKChatTokenTypeEmoteTwitch
                                                  emoteID:@"25"];
    kappaTok.resolvedEmote = [[TPKPickerSizesPreviewAsset alloc]
        initWithEmoteID:@"25"
                    size:CGSizeMake(28, 28)
                imageURL:[NSURL URLWithString:
                    @"https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/3.0"]];
    [tokens addObject:kappaTok];
    normal.tokens = tokens;
    // Rendu en annonce (barres + badge ANNONCE).
    normal.type = TPKChatMessageTypeSystem;
    TPKSystemMessageInfo *normalAnnouncement = [TPKSystemMessageInfo new];
    normalAnnouncement.kind = TPKSystemMessageKindAnnouncement;
    normalAnnouncement.announcementColorName = @"BLUE";
    normal.systemInfo = normalAnnouncement;
    normal.systemPhrase = @"";
    [store addMessage:normal];

    // Sub avec commentaire attaché : badge + emote 7TV rendus dans le corps
    // du commentaire (pas seulement la bannière système) — c'est le cas réel
    // le plus fréquent (un abonné qui écrit un mot en resub).
    TPKChatMessage *sub = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_sub"
                 timestamp:now
              authorUserID:@"tpk_preview_u2"
         authorDisplayName:L(@"preview_username_2")
                   rawText:L(@"preview_sub_comment")];
    sub.type = TPKChatMessageTypeSystem;
    sub.badgeIdentifiers = @[@"subscriber/3"];
    TPKSystemMessageInfo *subInfo = [TPKSystemMessageInfo new];
    subInfo.kind = TPKSystemMessageKindSubOrResub;
    subInfo.isPrime = NO;
    subInfo.tier = 1;
    subInfo.cumulativeMonths = 3;
    sub.systemInfo = subInfo;
    sub.systemPhrase = L(@"preview_sub_phrase");
    NSMutableArray<TPKChatToken *> *subTokens = [NSMutableArray array];
    [subTokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];
    [subTokens addObject:[TPKChatToken textToken:L(@"preview_sub_comment")]];
    sub.tokens = subTokens;
    [store addMessage:sub];

    // Premier message supprimé — le flag isFirstMessage reste porté par le
    // même objet que l'état DeletedCollapsed, afin de vérifier que le
    // highlight FIRST MESSAGE survit au placeholder de suppression.
    TPKChatMessage *firstMessage = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_first_message"
                 timestamp:now
              authorUserID:@"tpk_preview_u9"
         authorDisplayName:L(@"preview_first_message_username")
                   rawText:L(@"preview_first_message_text")];
    firstMessage.authorColor = [UIColor colorWithRed:0.72 green:0.38 blue:0.90 alpha:1.0];
    firstMessage.badgeIdentifiers = @[@"subscriber/3"];
    firstMessage.isFirstMessage = YES;
    firstMessage.state = TPKChatMessageStateDeletedCollapsed;
    firstMessage.moderationKind = TPKChatModerationKindTimeout;
    firstMessage.moderationDurationSeconds = 10 * 60;
    [store addMessage:firstMessage];

    // Mention de soi-même supprimée et révélée — mentionsCurrentViewer reste
    // porté par le même objet que l'état DeletedExpanded. Le renderer garde
    // donc le highlight MENTIONS YOU et n'atténue que le corps supprimé.
    TPKChatMessage *mention = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_mention"
                 timestamp:now
              authorUserID:@"tpk_preview_u7"
         authorDisplayName:L(@"preview_username_3")
                   rawText:L(@"preview_deleted_message")];
    mention.authorColor = [UIColor colorWithRed:0.55 green:0.85 blue:0.35 alpha:1.0];
    mention.badgeIdentifiers = @[@"moderator/1"];
    mention.mentionsCurrentViewer = YES;
    mention.state = TPKChatMessageStateDeletedExpanded;
    mention.moderationKind = TPKChatModerationKindPermanentBan;
    [store addMessage:mention];

    // Prime avec commentaire attaché — même logique que le sub, badge/emote
    // différents pour ne pas dupliquer visuellement le message sub.
    TPKChatMessage *prime = [[TPKChatMessage alloc]
        initWithMessageID:@"tpk_preview_prime"
                 timestamp:now
              authorUserID:@"tpk_preview_u3"
         authorDisplayName:L(@"preview_username")
                   rawText:L(@"preview_prime_comment")];
    prime.type = TPKChatMessageTypeSystem;
    prime.badgeIdentifiers = @[@"founder/0"];
    TPKSystemMessageInfo *primeInfo = [TPKSystemMessageInfo new];
    primeInfo.kind = TPKSystemMessageKindSubOrResub;
    primeInfo.isPrime = YES;
    primeInfo.cumulativeMonths = 24;
    prime.systemInfo = primeInfo;
    prime.systemPhrase = L(@"preview_prime_phrase");
    NSMutableArray<TPKChatToken *> *primeTokens = [NSMutableArray array];
    [primeTokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];
    [primeTokens addObject:[TPKChatToken textToken:L(@"preview_prime_comment")]];
    prime.tokens = primeTokens;
    [store addMessage:prime];

}

// Façade historique appelée par tpK-picker-controller.m à chaque ouverture
// du panneau (nom conservé pour ne pas toucher au .h ni au controller) —
// sert désormais à rafraîchir le faux chat plutôt qu'à charger des images
// de preview séparées, qui n'existent plus.
- (void)loadRealPreviewAssetsIfNeeded {
    [self.fakeChatView resetTransientTranscriptState];
    [self.fakeChatStore removeAllMessages];
    [self _populateFakeChatStore:self.fakeChatStore];
    [self.fakeChatView reloadMessages];
}

#pragma mark - Bascule OLED (recoloration à chaud)

// Recolore le panneau sans reconstruire sa hiérarchie : fond, capsule de
// catégories, segmented controls et séparateurs suivent la palette transmise
// par le picker. Appelé à chaque bascule du mode OLED (et non à la
// construction, déjà couverte par buildInView:).
- (void)tpk_applyOLEDColorsWithBgColor:(UIColor *)bgColor
                               sepColor:(UIColor *)sepColor
                              cardColor:(UIColor *)cardColor {
    self.panelView.backgroundColor = bgColor;
    self.panelSepColor = sepColor;
    self.panelCardColor = cardColor;

    UIColor *cardAlpha = [cardColor colorWithAlphaComponent:0.92];
    self.categoryCapsuleView.backgroundColor = cardAlpha;
    self.deletedPreviewControl.backgroundColor = cardAlpha;
    self.deletedStyleControl.backgroundColor = cardAlpha;

    // Les séparateurs vivent dans les 3 UIScrollView de catégories (fils
    // des lignes de sliders, section couleurs, modération). On les recolore
    // en parcourant ces seuls sous-arbres — sans toucher aux segmented
    // controls ni à la capsule de catégories.
    for (UIScrollView *category in @[self.sizesCategoryView,
                                     self.appearanceCategoryView,
                                     self.moderationCategoryView]) {
        if (category) [self _tpk_recolorSeparatorsInView:category withColor:sepColor];
    }
}

- (void)_tpk_recolorSeparatorsInView:(UIView *)view withColor:(UIColor *)color {
    for (UIView *subview in view.subviews) {
        CGFloat h = subview.frame.size.height;
        if (subview.subviews.count == 0 && h > 0 && h < 1.0) {
            subview.backgroundColor = color;
        } else {
            [self _tpk_recolorSeparatorsInView:subview withColor:color];
        }
    }
}

@end
