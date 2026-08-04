/*
 * 7tv-picker-sizes.m
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import "7tv-picker-sizes.h"
#import "7tv-picker-controler.h"
#import "SevenTVManager.h"
#import "SevenTVChatAppearanceConfig.h"
#import "7tv-localization.h"
#import <objc/runtime.h>

// associe un UISlider/UIButton de ligne à sa clé SevenTVChatAppearanceConfig
static const char kS7TVRowKeyTag = 0;

@interface SevenTVPickerSizesPanel ()
@property (nonatomic, weak, readwrite) UIView *panelView;
@property (nonatomic, assign, readwrite) CGFloat contentHeight;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISlider *> *sizeSliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *>  *sizeValueLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *>   *sizePreviewViews;
@end

@implementation SevenTVPickerSizesPanel

- (NSArray<NSArray *> *)_sizeOptionsTable {
    return @[
        @[@"emote7TVSize",     L(@"title_emotes_7tv"),      @12, @56],
        @[@"emoteTwitchSize",  L(@"size_label_emote_twitch"), @12, @56],
        @[@"badgeSize",        L(@"size_label_badges"),      @8,  @34],
        @[@"usernameFontSize", L(@"size_label_username"),    @8,  @28],
        @[@"messageFontSize",  L(@"size_label_message"),     @8,  @28],
    ];
}

- (void)buildInView:(UIView *)container
              frame:(CGRect)frame
            bgColor:(UIColor *)bgColor
          textColor:(UIColor *)textColor
           subColor:(UIColor *)subColor
           sepColor:(UIColor *)sepColor
             accent:(UIColor *)accent
          cardColor:(UIColor *)cardColor {

    // ── Panneau des tailles ──────────────────────────────────────────────
    // S'adapte au contenu réel (5 lignes) au lieu d'une hauteur fixe qui
    // laissait un grand vide sous la dernière ligne. La hauteur calculée ici
    // (contentHeight) est ensuite appliquée au picker par
    // -[SevenTVEmotePickerController emotePickerSizesToggleTapped].
    UIScrollView *sizesPanel = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, 0, frame.size.width, frame.size.height)];
    sizesPanel.backgroundColor = bgColor;
    sizesPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sizesPanel.hidden = YES;
    self.panelView       = sizesPanel;
    self.sizeSliders      = [NSMutableDictionary dictionary];
    self.sizeValueLabels  = [NSMutableDictionary dictionary];
    self.sizePreviewViews = [NSMutableDictionary dictionary];

    CGFloat rowH = 84.0, rowY = 12.0;
    CGFloat previewW = 64.0, previewH = 44.0;
    for (NSArray *entry in self._sizeOptionsTable) {
        NSString *key = entry[0], *label = entry[1];
        CGFloat minVal = [entry[2] doubleValue], maxVal = [entry[3] doubleValue];
        CGFloat current = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
        if (current < minVal || current > maxVal) current = minVal;

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, rowY, frame.size.width, rowH)];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, rowH - 0.5, frame.size.width - 24, 0.5)];
        rowSep.backgroundColor = sepColor;
        rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:rowSep];

        UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 9, 130, 16)];
        nameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        nameLbl.textColor = textColor;
        nameLbl.text = label;
        [row addSubview:nameLbl];

        UILabel *valuePill = [[UILabel alloc] initWithFrame:CGRectMake(12 + 130 + 6, 7, 44, 20)];
        valuePill.font = [UIFont boldSystemFontOfSize:11];
        valuePill.textColor = [UIColor whiteColor];
        valuePill.textAlignment = NSTextAlignmentCenter;
        valuePill.backgroundColor = accent;
        valuePill.layer.cornerRadius = 6;
        valuePill.layer.masksToBounds = YES;
        valuePill.text = [NSString stringWithFormat:@"%ld pt", (long)llround(current)];
        [row addSubview:valuePill];
        self.sizeValueLabels[key] = valuePill;

        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resetBtn.frame = CGRectMake(frame.size.width - 32, 4, 28, 24);
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

        CGFloat previewX = frame.size.width - previewW - 8;
        UIView *previewBox = [[UIView alloc] initWithFrame:CGRectMake(previewX, 34, previewW, previewH)];
        previewBox.backgroundColor = cardColor;
        previewBox.layer.cornerRadius = 8;
        previewBox.clipsToBounds = YES;
        previewBox.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [row addSubview:previewBox];
        [self _buildPreviewContentForKey:key inBox:previewBox value:current];

        CGFloat sliderX = 12, sliderW = previewX - 8 - sliderX;
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, 36, sliderW, 22)];
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
        rowY += rowH;
    }
    sizesPanel.contentSize = CGSizeMake(frame.size.width, rowY);
    self.contentHeight = rowY + 8; // + petite marge basse, utilisé pour adapter la hauteur du picker
    [container addSubview:sizesPanel];
}

- (void)_rowSliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, &kS7TVRowKeyTag);
    if (!key) return;
    NSInteger val = (NSInteger)roundf(slider.value);
    slider.value = (float)val; // snap au pas 1

    // Branché sur la vraie config du chat custom (SevenTVChatAppearanceConfig)
    // — setValue:forSizeKey: sauvegarde ET notifie automatiquement le chat
    // en direct pour la clé concernée.
    [[SevenTVChatAppearanceConfig sharedConfig] setValue:(CGFloat)val forSizeKey:key];
    [self _refreshRowDisplayForKey:key value:val];
}

- (void)_rowResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kS7TVRowKeyTag);
    if (!key) return;
    [[SevenTVChatAppearanceConfig sharedConfig] resetKeyToDefault:key];
    CGFloat val = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
    self.sizeSliders[key].value = (float)val;
    [self _refreshRowDisplayForKey:key value:val];
}

// Met à jour la pill "XX pt" + la preview d'une ligne donnée
- (void)_refreshRowDisplayForKey:(NSString *)key value:(CGFloat)val {
    self.sizeValueLabels[key].text = [NSString stringWithFormat:@"%ld pt", (long)llround(val)];
    [self _updatePreviewForKey:key value:val];
}

// "image" = vraie image (aspect ratio d'origine) : emote 7TV globale, vraie
// emote Twitch (Kappa, CDN officiel), vrai badge Twitch (Modérateur, CDN
// officiel). "text" = mot d'exemple rendu à la taille réglée (pseudo / message).
- (NSString *)_previewKindForKey:(NSString *)key {
    if ([key isEqualToString:@"usernameFontSize"] || [key isEqualToString:@"messageFontSize"]) return @"text";
    return @"image";
}

- (void)_buildPreviewContentForKey:(NSString *)key inBox:(UIView *)box value:(CGFloat)value {
    NSString *kind = [self _previewKindForKey:key];
    UIView *content = nil;
    if ([kind isEqualToString:@"text"]) {
        UILabel *lbl = [[UILabel alloc] init];
        BOOL isUsername = [key isEqualToString:@"usernameFontSize"];
        lbl.text = isUsername ? L(@"preview_username") : L(@"preview_greeting");
        lbl.textColor = isUsername
            ? [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]
            : [UIColor whiteColor];
        content = lbl;
    } else {
        // Image réelle chargée async par -loadRealPreviewAssetsIfNeeded
        // (ou déjà en cache si le panneau a déjà été ouvert une fois).
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        content = iv;
    }
    [box addSubview:content];
    self.sizePreviewViews[key] = content;
    [self _updatePreviewForKey:key value:value];
}

- (void)_updatePreviewForKey:(NSString *)key value:(CGFloat)value {
    UIView *content = self.sizePreviewViews[key];
    UIView *box = content.superview;
    if (!content || !box) return;
    CGFloat boxW = box.bounds.size.width, boxH = box.bounds.size.height;

    if ([[self _previewKindForKey:key] isEqualToString:@"text"]) {
        UILabel *lbl = (UILabel *)content;
        BOOL isUsername = [key isEqualToString:@"usernameFontSize"];
        lbl.font = isUsername ? [UIFont boldSystemFontOfSize:value] : [UIFont systemFontOfSize:value];
        [lbl sizeToFit];
        if (lbl.bounds.size.width > boxW - 8) {
            CGRect f = lbl.frame; f.size.width = boxW - 8; lbl.frame = f;
        }
        lbl.center = CGPointMake(boxW / 2.0, boxH / 2.0);
    } else {
        // Image réelle — aspect ratio d'origine, grandit/rétrécit avec la valeur
        UIImageView *iv = (UIImageView *)content;
        UIImage *img = iv.image;
        CGFloat ratio = (img && img.size.height > 0) ? (img.size.width / img.size.height) : 1.0;
        CGFloat targetH = MIN(value, boxH - 6);
        CGFloat targetW = MIN(targetH * ratio, boxW - 6);
        targetH = targetW / ratio;
        iv.frame = CGRectMake(0, 0, targetW, targetH);
        iv.center = CGPointMake(boxW / 2.0, boxH / 2.0);
    }
}

// Charge les 3 vraies images utilisées comme previews (une seule fois, mises
// en cache dans les UIImageView elles-mêmes — pas de refetch aux toggles
// suivants) :
//  - "Emotes 7TV"    → l'emote globale EZ, même pipeline que la grille
//  - "Emotes Twitch" → Kappa (emote globale Twitch, ID stable et public)
//  - "Badges"        → le badge Modérateur Twitch (asset public du CDN officiel)
- (void)loadRealPreviewAssetsIfNeeded {
    UIImageView *ivEZ = (UIImageView *)self.sizePreviewViews[@"emote7TVSize"];
    if ([ivEZ isKindOfClass:[UIImageView class]] && !ivEZ.image) {
        SevenTVEmote *ez = nil;
        for (SevenTVEmote *e in self.picker.emotePickerAllEmotes) {
            if ([e.emoteName isEqualToString:@"EZ"]) { ez = e; break; }
        }
        if (!ez) ez = self.picker.emotePickerGlobalEmotes.firstObject ?: self.picker.emotePickerAllEmotes.firstObject;
        if (ez) [self _loadPreviewImageFromURL:[[SevenTVManager sharedManager] cdnURLForEmote:ez] forKey:@"emote7TVSize"];
    }

    UIImageView *ivKappa = (UIImageView *)self.sizePreviewViews[@"emoteTwitchSize"];
    if ([ivKappa isKindOfClass:[UIImageView class]] && !ivKappa.image) {
        NSURL *kappaURL = [NSURL URLWithString:@"https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/3.0"];
        [self _loadPreviewImageFromURL:kappaURL forKey:@"emoteTwitchSize"];
    }

    UIImageView *ivBadge = (UIImageView *)self.sizePreviewViews[@"badgeSize"];
    if ([ivBadge isKindOfClass:[UIImageView class]] && !ivBadge.image) {
        NSURL *badgeURL = [NSURL URLWithString:
            @"https://static-cdn.jtvnw.net/badges/v1/3267646d-33f0-4b17-b3df-f923a41db1d0/3"];
        [self _loadPreviewImageFromURL:badgeURL forKey:@"badgeSize"];
    }
}

// Fetch + décodage générique (même pipeline réseau que la grille — réutilise
// pickerImageSession/decodePickerImageData:wantsAnimated: du picker hôte)
// réutilisé pour les 3 previews, quelle que soit leur source.
- (void)_loadPreviewImageFromURL:(NSURL *)url forKey:(NSString *)key {
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    __weak SevenTVEmotePickerController *weakPicker = self.picker;
    NSURLSessionDataTask *task = [[self.picker pickerImageSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data) return;
        UIImage *img = [weakPicker decodePickerImageData:data wantsAnimated:NO];
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            UIImageView *iv = (UIImageView *)strongSelf.sizePreviewViews[key];
            if (![iv isKindOfClass:[UIImageView class]]) return;
            iv.image = img;
            CGFloat val = strongSelf.sizeSliders[key].value;
            [strongSelf _updatePreviewForKey:key value:val];
        });
    }];
    [task resume];
}

@end
