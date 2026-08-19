/*
 * 7tv-picker-sizes.m
 * Extrait de SevenTVManager.m (nettoyage picker).
 *
 * Refonte (mi-août 2026) : les anciennes mini-previews par ligne
 * (_buildPreviewContentForKey:/_updatePreviewForKey:) sont remplacées par un
 * seul faux chat en haut du panneau, une vraie instance de
 * SevenTVChatCustomView alimentée par un S7TVChatMessageStore factice —
 * garanti 100% identique au rendu réel, sans double maintenance. Ajout
 * également d'une section "Couleurs" pour les fonds sub/resub/prime/gift
 * (toggle unique + 3 UIColorWell), auparavant en dur dans
 * SevenTVChatCustomView.m.
 */

#import "7tv-picker-sizes.h"
#import "7tv-picker-controler.h"
#import "7tv-picker-resolved-emote.h"
#import "SevenTVManager.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVChatMessage.h"
#import "SevenTVChatCustomView.h"
#import "SevenTVEmoteProvider.h"
#import "7tv-localization.h"
#import <objc/runtime.h>

static const char kS7TVRowKeyTag = 0;


// ============================================================
// MARK: - Objet minimal <S7TVResolvedEmote> pour l'emote Twitch
// native fixe (Kappa) du faux message de preview — pas de provider
// Twitch générique disponible hors du flux IRC réel.
// ============================================================

@interface S7TVPickerSizesPreviewAsset : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy, readonly) NSString *emoteID;
@property (nonatomic, assign, readonly) CGSize nativeSize;
@property (nonatomic, strong, readonly) NSURL *imageURL;
@property (nonatomic, assign, readonly) BOOL isAnimated;
- (instancetype)initWithEmoteID:(NSString *)emoteID
                            size:(CGSize)size
                        imageURL:(NSURL *)imageURL;
@end

@implementation S7TVPickerSizesPreviewAsset
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


@interface SevenTVPickerSizesPanel ()
@property (nonatomic, weak, readwrite) UIView *panelView;
@property (nonatomic, assign, readwrite) CGFloat contentHeight;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISlider *> *sizeSliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *>  *sizeValueLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIColorWell *> *colorWells;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *colorRowLabels;
// Ligne unique "vous êtes mentionné" (toggle + couleur combinés, voir
// _buildSelfMentionSectionInScrollView:...) — pas besoin de dictionnaires
// comme colorWells/colorRowLabels puisqu'il n'y a qu'une seule ligne, pas
// plusieurs clés à indexer.
@property (nonatomic, weak) UISwitch *selfMentionSwitch;
@property (nonatomic, weak) UIColorWell *selfMentionColorWell;
@property (nonatomic, weak) UILabel *selfMentionRowLabel;
@property (nonatomic, strong) S7TVChatMessageStore *fakeChatStore;
@property (nonatomic, strong) SevenTVChatCustomView *fakeChatView;
@property (nonatomic, strong) UIColor *panelTextColor;
@property (nonatomic, strong) UIColor *panelSubColor;
@end

@implementation SevenTVPickerSizesPanel

- (NSArray<NSArray *> *)_sizeOptionsTable {
    return @[
        @[@"emote7TVSize",     L(@"title_emotes_7tv"),         @12, @56],
        @[@"emoteTwitchSize",  L(@"size_label_emote_twitch"),  @12, @56],
        @[@"badgeSize",        L(@"size_label_badges"),        @8,  @34],
        @[@"usernameFontSize", L(@"size_label_username"),      @8,  @28],
        @[@"messageFontSize",  L(@"size_label_message"),       @8,  @28],
        @[@"lineSpacing",      L(@"size_label_line_spacing"),  @0,  @30],
        @[@"emoteVerticalOffset", L(@"size_label_emote_offset"), @-10, @10],
    ];
}

- (SevenTVEmote *)_findEZEmote {
    SevenTVEmote *ez = nil;
    for (SevenTVEmote *e in self.picker.emotePickerAllEmotes) {
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
- (NSArray<S7TVChatToken *> *)_ezEmoteTokensWithTrailingSpace {
    SevenTVEmote *ez = [self _findEZEmote];
    if (!ez) return @[];
    S7TVChatToken *emoteTok = [S7TVChatToken emoteToken:ez.emoteName
                                                 provider:S7TVChatTokenTypeEmote7TV
                                                  emoteID:ez.emoteID];
    emoteTok.resolvedEmote = [[S7TVPickerResolvedEmote alloc] initWithEmote:ez];
    return @[emoteTok, [S7TVChatToken textToken:@" "]];
}

- (void)buildInView:(UIView *)container
              frame:(CGRect)frame
            bgColor:(UIColor *)bgColor
          textColor:(UIColor *)textColor
           subColor:(UIColor *)subColor
           sepColor:(UIColor *)sepColor
             accent:(UIColor *)accent
          cardColor:(UIColor *)cardColor {

    UIScrollView *sizesPanel = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, 0, frame.size.width, frame.size.height)];
    sizesPanel.backgroundColor = bgColor;
    sizesPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sizesPanel.hidden = YES;
    self.panelView       = sizesPanel;
    self.sizeSliders      = [NSMutableDictionary dictionary];
    self.sizeValueLabels  = [NSMutableDictionary dictionary];
    self.colorWells        = [NSMutableDictionary dictionary];
    self.colorRowLabels    = [NSMutableDictionary dictionary];
    self.panelTextColor    = textColor;
    self.panelSubColor     = subColor;

    CGFloat contentY = 12.0;

    // Le faux chat n'est plus construit ici : il vit dans une fenêtre
    // flottante séparée gérée par le picker (voir -[SevenTVEmotePickerController
    // emotePickerSizesToggleTapped]), positionnée au-dessus du champ de
    // saisie — le panneau scrollable ⚙️ Tailles ne peut pas héberger un
    // aperçu positionné librement puisqu'il EST l'inputView (remplace le
    // clavier). On construit quand même fakeChatStore/fakeChatView ici pour
    // que le controller puisse les récupérer via les accesseurs publics.
    [self _setupFakeChatView];

    contentY = [self _buildSystemColorsSectionInScrollView:sizesPanel atY:contentY
                                                       width:frame.size.width
                                                   textColor:textColor subColor:subColor
                                                    sepColor:sepColor accent:accent];

    contentY = [self _buildSelfMentionSectionInScrollView:sizesPanel atY:contentY
                                                      width:frame.size.width
                                                  textColor:textColor subColor:subColor
                                                   sepColor:sepColor accent:accent];

    CGFloat rowH = 60.0;
    for (NSArray *entry in self._sizeOptionsTable) {
        NSString *key = entry[0], *label = entry[1];
        CGFloat minVal = [entry[2] doubleValue], maxVal = [entry[3] doubleValue];
        CGFloat current = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
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
        objc_setAssociatedObject(resetBtn, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
        objc_setAssociatedObject(slider, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [slider addTarget:self action:@selector(_rowSliderChanged:)
          forControlEvents:UIControlEventValueChanged];
        [row addSubview:slider];
        self.sizeSliders[key] = slider;

        [sizesPanel addSubview:row];
        contentY += rowH;
    }
    sizesPanel.contentSize = CGSizeMake(frame.size.width, contentY);
    self.contentHeight = contentY + 8;
    [container addSubview:sizesPanel];
}

#pragma mark - Sliders (tailles/espacements)

- (void)_rowSliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, &kS7TVRowKeyTag);
    if (!key) return;
    NSInteger val = (NSInteger)roundf(slider.value);
    slider.value = (float)val;
    [[SevenTVChatAppearanceConfig sharedConfig] setValue:(CGFloat)val forSizeKey:key];
    self.sizeValueLabels[key].text = [NSString stringWithFormat:@"%+ld pt", (long)val];
    [self.fakeChatView reloadMessages];
}

- (void)_rowResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kS7TVRowKeyTag);
    if (!key) return;
    [[SevenTVChatAppearanceConfig sharedConfig] resetKeyToDefault:key];
    CGFloat val = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
    self.sizeSliders[key].value = (float)val;
    self.sizeValueLabels[key].text = [NSString stringWithFormat:@"%+ld pt", (long)llround(val)];
    [self.fakeChatView reloadMessages];
}

#pragma mark - Section couleurs (toggle + 3 UIColorWell)

- (CGFloat)_buildSystemColorsSectionInScrollView:(UIScrollView *)scrollView
                                              atY:(CGFloat)y
                                            width:(CGFloat)width
                                        textColor:(UIColor *)textColor
                                         subColor:(UIColor *)subColor
                                         sepColor:(UIColor *)sepColor
                                           accent:(UIColor *)accent {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    BOOL enabled = cfg.systemMessageBackgroundsEnabled;

    UILabel *sectionLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, width - 24, 16)];
    sectionLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    sectionLbl.textColor = subColor;
    sectionLbl.text = L(@"sizes_colors_section_title");
    sectionLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:sectionLbl];
    y += 26;

    // Toggle maître — dés/réactive le fond teinté pour tous les types
    // d'un coup (barre + icône restent toujours visibles, voir
    // SevenTVChatCustomView.m).
    UIView *toggleRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 44)];
    toggleRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *toggleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, width - 12 - 51 - 12 - 8, 20)];
    toggleLbl.font = [UIFont systemFontOfSize:13];
    toggleLbl.textColor = textColor;
    toggleLbl.text = L(@"sizes_colors_toggle_label");
    toggleLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [toggleRow addSubview:toggleLbl];

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
        objc_setAssociatedObject(resetBtn, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [resetBtn addTarget:self action:@selector(_colorResetTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:resetBtn];

        UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(width - 12 - 36, 4, 36, 36)];
        well.selectedColor = current;
        well.supportsAlpha = NO;
        well.enabled = enabled;
        well.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        objc_setAssociatedObject(well, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
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

#pragma mark - Ligne "Vous êtes mentionné" (toggle + couleur, 1 seule ligne)
//
// Fondue dans la section Couleurs des messages système ci-dessus (même
// catégorie que sub/prime/gift) plutôt que d'avoir sa propre section — pas
// de titre ici, cette méthode ne fait qu'ajouter une ligne de plus à la
// suite de _buildSystemColorsSectionInScrollView: (voir l'appel chaîné dans
// buildInView:). Une seule ligne suffit puisqu'il n'y a qu'un seul type de
// highlight à régler : label, reset, switch, colorwell, dans cet ordre de
// droite à gauche. Même style (police, tailles de contrôles, comportement
// grisé quand désactivé) que les lignes de la section Couleurs pour rester
// cohérent visuellement.
- (CGFloat)_buildSelfMentionSectionInScrollView:(UIScrollView *)scrollView
                                             atY:(CGFloat)y
                                           width:(CGFloat)width
                                       textColor:(UIColor *)textColor
                                        subColor:(UIColor *)subColor
                                        sepColor:(UIColor *)sepColor
                                          accent:(UIColor *)accent {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    BOOL enabled = cfg.selfMentionHighlightEnabled;

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
    nameLbl.text = L(@"sizes_self_mention_row_label");
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    nameLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:nameLbl];
    self.selfMentionRowLabel = nameLbl;

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(resetLeft, 8, resetW, 28);
    resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:rCfg]
              forState:UIControlStateNormal];
    resetBtn.tintColor = subColor;
    [resetBtn addTarget:self action:@selector(_selfMentionResetTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:resetBtn];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = accent;
    sw.on = enabled;
    sw.frame = CGRectMake(switchLeft, 6, switchW, 31);
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sw addTarget:self action:@selector(_selfMentionToggleChanged:)
   forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    self.selfMentionSwitch = sw;

    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(wellLeft, 4, wellW, wellW)];
    well.selectedColor = cfg.selfMentionHighlightColor;
    well.supportsAlpha = NO;
    well.enabled = enabled;
    well.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [well addTarget:self action:@selector(_selfMentionColorWellChanged:)
   forControlEvents:UIControlEventValueChanged];
    [row addSubview:well];
    self.selfMentionColorWell = well;

    [scrollView addSubview:row];
    y += 44;

    UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, y - 0.5, width - 24, 0.5)];
    rowSep.backgroundColor = sepColor;
    rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:rowSep];

    return y + 8;
}

- (void)_selfMentionToggleChanged:(UISwitch *)sw {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    cfg.selfMentionHighlightEnabled = sw.on;
    self.selfMentionColorWell.enabled = sw.on;
    self.selfMentionRowLabel.textColor = sw.on ? self.panelTextColor : self.panelSubColor;
    [self.fakeChatView reloadMessages];
}

- (void)_selfMentionColorWellChanged:(UIColorWell *)well {
    if (!well.selectedColor) return;
    [[SevenTVChatAppearanceConfig sharedConfig] setColor:well.selectedColor
                                              forColorKey:@"selfMentionHighlightColor"];
    [self.fakeChatView reloadMessages];
}

// Réinitialise les DEUX réglages de la ligne d'un coup (toggle + couleur) —
// contrairement aux resets de la section Couleurs qui ne touchent qu'UNE
// clé chacun : ici il n'y a qu'une seule ligne pour l'ensemble de la
// fonctionnalité, donc "réinitialiser" porte sur tout le bloc.
- (void)_selfMentionResetTapped:(UIButton *)btn {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    [cfg resetColorKeyToDefault:@"selfMentionHighlightColor"];
    cfg.selfMentionHighlightEnabled = YES;
    self.selfMentionColorWell.selectedColor = cfg.selfMentionHighlightColor;
    self.selfMentionColorWell.enabled = YES;
    self.selfMentionSwitch.on = YES;
    self.selfMentionRowLabel.textColor = self.panelTextColor;
    [self.fakeChatView reloadMessages];
}

- (void)_systemBGToggleChanged:(UISwitch *)sw {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    cfg.systemMessageBackgroundsEnabled = sw.on;
    for (NSString *key in self.colorWells) {
        self.colorWells[key].enabled = sw.on;
        self.colorRowLabels[key].textColor = sw.on ? self.panelTextColor : self.panelSubColor;
    }
    [self.fakeChatView reloadMessages];
}

- (void)_colorWellChanged:(UIColorWell *)well {
    NSString *key = objc_getAssociatedObject(well, &kS7TVRowKeyTag);
    if (!key || !well.selectedColor) return;
    [[SevenTVChatAppearanceConfig sharedConfig] setColor:well.selectedColor forColorKey:key];
    [self.fakeChatView reloadMessages];
}

- (void)_colorResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kS7TVRowKeyTag);
    if (!key) return;
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
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
    self.fakeChatStore = [[S7TVChatMessageStore alloc] init];
    [self _populateFakeChatStore:self.fakeChatStore];

    SevenTVChatCustomView *chatView = [[SevenTVChatCustomView alloc] initWithStore:self.fakeChatStore];
    // Preview statique : pas de scroll/tap indépendant (le vrai chat en
    // dessous ne doit pas non plus recevoir les touches à travers la
    // fenêtre flottante) — le contenu tient dans les 5 messages factices.
    chatView.userInteractionEnabled = NO;
    self.fakeChatView = chatView;
    [chatView reloadMessages];
}

// 5 messages factices couvrant tous les réglages du panneau : emote 7TV +
// emote Twitch native + badge + pseudo (normal), sub/resub, prime (24e mois,
// comme la référence utilisateur), gift communautaire, et un message
// supprimé (collapsed). Pas de tap-to-reveal ici (chatView non interactive,
// et la fonctionnalité n'existe pas encore côté chat réel — Phase 5).
// 7 messages factices couvrant tous les réglages du panneau, dans un ordre
// volontairement mélangé (pas juste "un de chaque type à la suite") pour se
// rapprocher d'un vrai fil de chat : gift, normal (badge + emote 7TV + emote
// Twitch native), sub avec commentaire (badge + emote 7TV dans le corps du
// commentaire, pas seulement la bannière), normal (badge différent, texte
// seul), mention de soi (highlight barre + fond, voir
// selfMentionHighlightEnabled/Color), prime avec commentaire (badge + emote
// 7TV), message supprimé (collapsed). Pas de tap-to-reveal ici (chatView
// non interactive, et la fonctionnalité n'existe pas encore côté chat réel
// — Phase 5).
- (void)_populateFakeChatStore:(S7TVChatMessageStore *)store {
    NSDate *now = [NSDate date];

    S7TVChatMessage *gift = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_gift"
                 timestamp:now
              authorUserID:@"s7tv_preview_u4"
         authorDisplayName:L(@"preview_username")
                   rawText:@""];
    gift.type = S7TVChatMessageTypeSystem;
    S7TVSystemMessageInfo *giftInfo = [S7TVSystemMessageInfo new];
    giftInfo.kind = S7TVSystemMessageKindCommunityGift;
    giftInfo.massGiftCount = 5;
    giftInfo.senderTotalGiftCount = 12;
    gift.systemInfo = giftInfo;
    gift.systemPhrase = L(@"preview_gift_phrase");
    [store addMessage:gift];

    S7TVChatMessage *normal = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_normal"
                 timestamp:now
              authorUserID:@"s7tv_preview_u1"
         authorDisplayName:L(@"preview_username")
                   rawText:L(@"preview_greeting")];
    normal.authorColor = [UIColor colorWithRed:0.35 green:0.68 blue:1.0 alpha:1.0];
    // Badge global Twitch (quasi toujours présent dans le catalogue chargé,
    // contrairement à un badge d'abonné propre à une chaîne) — best-effort :
    // s'il n'est pas encore résolu (catalogue pas chargé), le badge est
    // simplement absent du message de preview, sans erreur.
    normal.badgeIdentifiers = @[@"moderator/1"];

    NSMutableArray<S7TVChatToken *> *tokens = [NSMutableArray array];
    [tokens addObject:[S7TVChatToken textToken:
        [L(@"preview_greeting") stringByAppendingString:@" "]]];
    [tokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];

    S7TVChatToken *kappaTok = [S7TVChatToken emoteToken:@"Kappa"
                                                 provider:S7TVChatTokenTypeEmoteTwitch
                                                  emoteID:@"25"];
    kappaTok.resolvedEmote = [[S7TVPickerSizesPreviewAsset alloc]
        initWithEmoteID:@"25"
                    size:CGSizeMake(28, 28)
                imageURL:[NSURL URLWithString:
                    @"https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/3.0"]];
    [tokens addObject:kappaTok];
    normal.tokens = tokens;
    [store addMessage:normal];

    // Sub avec commentaire attaché : badge + emote 7TV rendus dans le corps
    // du commentaire (pas seulement la bannière système) — c'est le cas réel
    // le plus fréquent (un abonné qui écrit un mot en resub).
    S7TVChatMessage *sub = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_sub"
                 timestamp:now
              authorUserID:@"s7tv_preview_u2"
         authorDisplayName:L(@"preview_username_2")
                   rawText:L(@"preview_sub_comment")];
    sub.type = S7TVChatMessageTypeSystem;
    sub.badgeIdentifiers = @[@"subscriber/3"];
    S7TVSystemMessageInfo *subInfo = [S7TVSystemMessageInfo new];
    subInfo.kind = S7TVSystemMessageKindSubOrResub;
    subInfo.isPrime = NO;
    subInfo.tier = 1;
    subInfo.cumulativeMonths = 3;
    sub.systemInfo = subInfo;
    sub.systemPhrase = L(@"preview_sub_phrase");
    NSMutableArray<S7TVChatToken *> *subTokens = [NSMutableArray array];
    [subTokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];
    [subTokens addObject:[S7TVChatToken textToken:L(@"preview_sub_comment")]];
    sub.tokens = subTokens;
    [store addMessage:sub];

    // Normal #2 : badge différent (VIP), texte seul sans emote — variété de
    // rendu (largeur de ligne, badge autre que modérateur).
    S7TVChatMessage *normal2 = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_normal_2"
                 timestamp:now
              authorUserID:@"s7tv_preview_u6"
         authorDisplayName:L(@"preview_username_3")
                   rawText:L(@"preview_message_2")];
    normal2.authorColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.25 alpha:1.0];
    normal2.badgeIdentifiers = @[@"vip/1"];
    [store addMessage:normal2];

    // Mention de soi-même — montre le highlight (barre d'accent + fond
    // teinté, voir SevenTVChatAppearanceConfig.selfMentionHighlightEnabled/
    // selfMentionHighlightColor et SevenTVChatCustomView.m,
    // s7tv_configureCell:forMessage:...). mentionsCurrentViewer est set
    // directement ici plutôt que déduit d'un vrai match de pseudo : le faux
    // chat est volontairement déconnecté du viewer réellement connecté (voir
    // le commentaire sur mentionsCurrentViewer dans SevenTVChatMessage.h),
    // donc le texte "@Toi" ci-dessous est purement cosmétique.
    S7TVChatMessage *mention = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_mention"
                 timestamp:now
              authorUserID:@"s7tv_preview_u7"
         authorDisplayName:L(@"preview_username_3")
                   rawText:@"@Toi"];
    mention.authorColor = [UIColor colorWithRed:0.55 green:0.85 blue:0.35 alpha:1.0];
    mention.badgeIdentifiers = @[@"moderator/1"];
    mention.mentionsCurrentViewer = YES;
    mention.tokens = @[[S7TVChatToken mentionToken:@"@Toi" color:nil]];
    [store addMessage:mention];

    // Prime avec commentaire attaché — même logique que le sub, badge/emote
    // différents pour ne pas dupliquer visuellement le message sub.
    S7TVChatMessage *prime = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_prime"
                 timestamp:now
              authorUserID:@"s7tv_preview_u3"
         authorDisplayName:L(@"preview_username")
                   rawText:L(@"preview_prime_comment")];
    prime.type = S7TVChatMessageTypeSystem;
    prime.badgeIdentifiers = @[@"founder/0"];
    S7TVSystemMessageInfo *primeInfo = [S7TVSystemMessageInfo new];
    primeInfo.kind = S7TVSystemMessageKindSubOrResub;
    primeInfo.isPrime = YES;
    primeInfo.cumulativeMonths = 24;
    prime.systemInfo = primeInfo;
    prime.systemPhrase = L(@"preview_prime_phrase");
    NSMutableArray<S7TVChatToken *> *primeTokens = [NSMutableArray array];
    [primeTokens addObjectsFromArray:[self _ezEmoteTokensWithTrailingSpace]];
    [primeTokens addObject:[S7TVChatToken textToken:L(@"preview_prime_comment")]];
    prime.tokens = primeTokens;
    [store addMessage:prime];

    S7TVChatMessage *deleted = [[S7TVChatMessage alloc]
        initWithMessageID:@"s7tv_preview_deleted"
                 timestamp:now
              authorUserID:@"s7tv_preview_u5"
         authorDisplayName:L(@"preview_username")
                   rawText:L(@"preview_deleted_message")];
    deleted.state = S7TVChatMessageStateDeletedCollapsed;
    [store addMessage:deleted];
}

// Façade historique appelée par 7tv-picker-controler.m à chaque ouverture
// du panneau (nom conservé pour ne pas toucher au .h ni au controller) —
// sert désormais à rafraîchir le faux chat plutôt qu'à charger des images
// de preview séparées, qui n'existent plus.
- (void)loadRealPreviewAssetsIfNeeded {
    [self.fakeChatView reloadMessages];
}

@end
