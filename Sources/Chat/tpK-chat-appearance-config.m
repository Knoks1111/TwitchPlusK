/*
 * tpK-chat-appearance-config.m
 *
 * Voir tpK-chat-appearance-config.h pour le contexte (Phase 1b) et
 * l'avertissement sur les valeurs par défaut non encore mesurées.
 */

#import "Chat/tpK-chat-appearance-config.h"
#import "Core/tpK-core-manager.h"
#import <math.h>

NSString *const TPKChatAppearanceConfigDidChangeNotification =
    @"TPKChatAppearanceConfigDidChangeNotification";

// ── Sérialisation couleur (NSUserDefaults ne stocke pas UIColor) ───────────
// Format "RRGGBBAA" hexadécimal. Utilisé uniquement pour la persistance —
// en mémoire on garde toujours de vrais UIColor.
static NSString *TPKColorToHexString(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return @"FFFFFFFF";
    return [NSString stringWithFormat:@"%02lX%02lX%02lX%02lX",
        (long)lround(r * 255.0), (long)lround(g * 255.0),
        (long)lround(b * 255.0), (long)lround(a * 255.0)];
}

static UIColor *TPKColorFromHexString(NSString *hex) {
    if (hex.length < 6) return nil;
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&value]) return nil;
    CGFloat r, g, b, a;
    if (hex.length >= 8) {
        r = ((value >> 24) & 0xFF) / 255.0;
        g = ((value >> 16) & 0xFF) / 255.0;
        b = ((value >> 8)  & 0xFF) / 255.0;
        a = (value & 0xFF) / 255.0;
    } else {
        r = ((value >> 16) & 0xFF) / 255.0;
        g = ((value >> 8)  & 0xFF) / 255.0;
        b = (value & 0xFF) / 255.0;
        a = 1.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// Défauts couleur — reprennent exactement les anciennes valeurs en dur de
// tpK-chat-custom-view.m (tpk_cellForMessageID:), avant leur passage en
// config. Fonctions plutôt que des constantes CGFloat : UIColor n'est pas
// une constante compile-time.
static UIColor *TPKDefaultSubResubColor(void) {
    return [UIColor colorWithRed:0.0 green:(122.0 / 255.0) blue:1.0 alpha:1.0]; // #007AFF
}
static UIColor *TPKDefaultPrimeColor(void) {
    return [UIColor colorWithRed:0.62 green:0.35 blue:0.95 alpha:1.0];
}
static UIColor *TPKDefaultGiftColor(void) {
    return [UIColor colorWithRed:0.90 green:0.20 blue:0.65 alpha:1.0];
}
// Rouge/cramoisi — reprend l'esprit du surlignage natif Twitch "vous êtes
// mentionné" (barre + fond teintés en rouge), voir référence Knoks.
static UIColor *TPKDefaultSelfMentionColor(void) {
    return [UIColor colorWithRed:0.92 green:0.23 blue:0.27 alpha:1.0];
}
// Violet/magenta du bandeau FIRST MESSAGE natif montré dans la référence.
static UIColor *TPKDefaultFirstMessageColor(void) {
    return [UIColor colorWithRed:0.82 green:0.18 blue:0.86 alpha:1.0];
}

// ── Clés NSUserDefaults ──────────────────────────────────────────────────────
static NSString *const kTPKCfgEmote7TVSize           = @"tpk_cfg_emote_7tv_size";
static NSString *const kTPKCfgEmoteTwitchSize         = @"tpk_cfg_emote_twitch_size";
static NSString *const kTPKCfgGIFSize                 = @"tpk_cfg_gif_size";
static NSString *const kTPKCfgBadgeSize               = @"tpk_cfg_badge_size";
static NSString *const kTPKCfgUsernameFontSize        = @"tpk_cfg_username_font_size";
static NSString *const kTPKCfgMessageFontSize         = @"tpk_cfg_message_font_size";
static NSString *const kTPKCfgLineSpacing             = @"tpk_cfg_line_spacing";
static NSString *const kTPKCfgUsernameMessageSpacing  = @"tpk_cfg_username_message_spacing";
static NSString *const kTPKCfgEmoteVerticalOffset     = @"tpk_cfg_emote_vertical_offset";
static NSString *const kTPKCfgPickerHeightPortrait    = @"tpk_cfg_picker_height_portrait";
static NSString *const kTPKCfgPickerHeightLandscape   = @"tpk_cfg_picker_height_landscape";
static NSString *const kTPKCfgPickerEmoteScalePortrait  = @"tpk_cfg_picker_emote_scale_portrait";
static NSString *const kTPKCfgPickerEmoteScaleLandscape = @"tpk_cfg_picker_emote_scale_landscape";
static NSString *const kTPKCfgEmoteOffsetRealMigrated = @"tpk_cfg_emote_offset_real_v1_migrated";
static NSString *const kTPKCfgEmote7TVResolution      = @"tpk_cfg_emote_7tv_resolution";
static NSString *const kTPKCfgEmoteImageResolution    = @"tpk_cfg_emote_resolution";
static NSString *const kTPKCfgSystemBGEnabled         = @"tpk_cfg_system_bg_enabled";
static NSString *const kTPKCfgSubResubColor           = @"tpk_cfg_color_sub_resub";
static NSString *const kTPKCfgPrimeColor              = @"tpk_cfg_color_prime";
static NSString *const kTPKCfgGiftColor               = @"tpk_cfg_color_gift";
static NSString *const kTPKCfgSelfMentionEnabled       = @"tpk_cfg_self_mention_enabled";
static NSString *const kTPKCfgSelfMentionColor         = @"tpk_cfg_color_self_mention";
static NSString *const kTPKCfgFirstMessageEnabled      = @"tpk_cfg_first_message_enabled";
static NSString *const kTPKCfgFirstMessageColor        = @"tpk_cfg_color_first_message";
static NSString *const kTPKCfgSharedChatAvatarsEnabled = @"tpk_cfg_shared_chat_avatars_enabled";
static NSString *const kTPKCfgShowModerationDetails    = @"tpk_cfg_show_moderation_details";
static NSString *const kTPKCfgDeletedRevealMode        = @"tpk_cfg_deleted_reveal_mode";
static NSString *const kTPKCfgDeletedMessageStyle      = @"tpk_cfg_deleted_message_style";
static NSString *const kTPKCfgDeletedMessageOpacity    = @"tpk_cfg_deleted_message_opacity";
static NSString *const kTPKCfgDeletedOpacityMigrated   = @"tpk_cfg_deleted_opacity_50_migrated";

static const CGFloat kDefaultEmote7TVSize          = 28.0;
static const CGFloat kDefaultEmoteTwitchSize        = 28.0; // TODO mesure réelle
static const CGFloat kDefaultGIFSize                = 28.0;
static const CGFloat kDefaultBadgeSize              = 17.0;
static const CGFloat kDefaultUsernameFontSize       = 13.0;
static const CGFloat kDefaultMessageFontSize        = 13.0;
// 2.0, pas 6.0 : compense exactement le passage de la marge structurelle
// du label (top+bottom) de 4 à 8 dans TPKChatCustomView
// tpk_heightForMessage: (correction du bug de clipping du dernier mot en
// cas limite de wrapping — voir commentaire de tpk_measureAttributedText:
// dans ce fichier .m). 8 + 2 = 10 = ancien 4 + 6 : espacement visuel entre
// messages inchangé par défaut. Cette valeur reste "TODO mesure réelle"
// comme avant, seule la compensation a changé.
static const CGFloat kDefaultLineSpacing            = 2.0;  // défaut = rendu du picker à 6, compensé -4
static const CGFloat kDefaultUsernameMessageSpacing = 4.0;  // TODO mesure réelle
// Valeur réelle transmise aux bounds de l'attachment : le picker et le rendu
// utilisent désormais exactement le même nombre, sans rebase invisible.
static const CGFloat kDefaultEmoteVerticalOffset    = -6.0;
// 280 pt = hauteur historique, donc portrait inchangé sans migration.
static const CGFloat kDefaultPickerHeightPortrait   = 260.0;
static const CGFloat kDefaultPickerHeightLandscape  = 160.0;
static const CGFloat kDefaultPickerEmoteScalePortrait  = 1.0;
static const CGFloat kDefaultPickerEmoteScaleLandscape = 1.0;
static const CGFloat kPickerHeightPortraitMin       = 120.0;
static const CGFloat kPickerHeightPortraitMax       = 400.0;
static const CGFloat kPickerHeightLandscapeMin      = 120.0;
static const CGFloat kPickerHeightLandscapeMax      = 260.0;
static const CGFloat kPickerEmoteScalePortraitMin   = 0.5;
static const CGFloat kPickerEmoteScalePortraitMax   = 2.0;
static const CGFloat kPickerEmoteScaleLandscapeMin  = 0.5;
static const CGFloat kPickerEmoteScaleLandscapeMax  = 2.0;
static NSString *const kTPKPickerHeightPortraitKey  = @"pickerHeightPortrait";
static NSString *const kTPKPickerHeightLandscapeKey = @"pickerHeightLandscape";
static NSString *const kTPKPickerEmoteScalePortraitKey  = @"pickerEmoteScalePortrait";
static NSString *const kTPKPickerEmoteScaleLandscapeKey = @"pickerEmoteScaleLandscape";

static BOOL TPKPickerOptionIsLandscapeKey(NSString *sizeKey) {
    return [sizeKey hasSuffix:@"Landscape"];
}
static BOOL TPKPickerOptionIsEmoteScaleKey(NSString *sizeKey) {
    return [sizeKey hasPrefix:@"pickerEmoteScale"];
}

CGFloat TPKPickerOptionMinForKey(NSString *sizeKey) {
    if (TPKPickerOptionIsEmoteScaleKey(sizeKey)) {
        return TPKPickerOptionIsLandscapeKey(sizeKey) ? kPickerEmoteScaleLandscapeMin
                                                       : kPickerEmoteScalePortraitMin;
    }
    return TPKPickerOptionIsLandscapeKey(sizeKey) ? kPickerHeightLandscapeMin
                                                   : kPickerHeightPortraitMin;
}

CGFloat TPKPickerOptionMaxForKey(NSString *sizeKey) {
    if (TPKPickerOptionIsEmoteScaleKey(sizeKey)) {
        return TPKPickerOptionIsLandscapeKey(sizeKey) ? kPickerEmoteScaleLandscapeMax
                                                       : kPickerEmoteScalePortraitMax;
    }
    return TPKPickerOptionIsLandscapeKey(sizeKey) ? kPickerHeightLandscapeMax
                                                   : kPickerHeightPortraitMax;
}

// Une valeur importée hors bornes ne doit pas casser la grille.
static CGFloat TPKClampPickerOption(CGFloat value, NSString *sizeKey) {
    return MIN(TPKPickerOptionMaxForKey(sizeKey),
               MAX(TPKPickerOptionMinForKey(sizeKey), value));
}
static const NSInteger kDefaultEmote7TVResolution   = 2;
static const CGFloat kDefaultDeletedMessageOpacity  = 0.50;
static const TPKDeletedMessageStyle kDefaultDeletedMessageStyle = TPKDeletedMessageStyleDimmed;
static const TPKDeletedMessageRevealMode kDefaultDeletedRevealMode = TPKDeletedMessageRevealModeOnTap;


@implementation TPKChatAppearanceConfig

+ (instancetype)sharedConfig {
    static TPKChatAppearanceConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TPKChatAppearanceConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self tpk_applyDefaults];
        [self reloadFromDefaults];
    }
    return self;
}

- (void)tpk_applyDefaults {
    _emote7TVSize           = kDefaultEmote7TVSize;
    _emoteTwitchSize        = kDefaultEmoteTwitchSize;
    _gifSize                = kDefaultGIFSize;
    _badgeSize               = kDefaultBadgeSize;
    _usernameFontSize        = kDefaultUsernameFontSize;
    _messageFontSize         = kDefaultMessageFontSize;
    _lineSpacing             = kDefaultLineSpacing;
    _usernameMessageSpacing  = kDefaultUsernameMessageSpacing;
    _emoteVerticalOffset     = kDefaultEmoteVerticalOffset;
    _pickerHeightPortrait    = kDefaultPickerHeightPortrait;
    _pickerHeightLandscape   = kDefaultPickerHeightLandscape;
    _pickerEmoteScalePortrait  = kDefaultPickerEmoteScalePortrait;
    _pickerEmoteScaleLandscape = kDefaultPickerEmoteScaleLandscape;
    _emote7TVResolution      = kDefaultEmote7TVResolution;
    _emoteImageResolution    = kDefaultEmote7TVResolution;
    _systemMessageBackgroundsEnabled = YES;
    _subResubAccentColor     = TPKDefaultSubResubColor();
    _primeAccentColor        = TPKDefaultPrimeColor();
    _giftAccentColor         = TPKDefaultGiftColor();
    _selfMentionHighlightEnabled = YES;
    _selfMentionHighlightColor   = TPKDefaultSelfMentionColor();
    _showFirstMessageBadge       = YES;
    _firstMessageHighlightColor  = TPKDefaultFirstMessageColor();
    _sharedChatSourceAvatarsEnabled = YES;
    _showModerationDetails       = YES;
    _deletedMessageRevealMode    = kDefaultDeletedRevealMode;
    _deletedMessageStyle         = kDefaultDeletedMessageStyle;
    _deletedMessageTextOpacity   = kDefaultDeletedMessageOpacity;
}

#pragma mark - Persistance

- (void)reloadFromDefaults {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    if ([prefs objectForKey:kTPKCfgEmote7TVSize] != nil)
        _emote7TVSize = [prefs doubleForKey:kTPKCfgEmote7TVSize];
    if ([prefs objectForKey:kTPKCfgEmoteTwitchSize] != nil)
        _emoteTwitchSize = [prefs doubleForKey:kTPKCfgEmoteTwitchSize];
    if ([prefs objectForKey:kTPKCfgGIFSize] != nil)
        _gifSize = [prefs doubleForKey:kTPKCfgGIFSize];
    if ([prefs objectForKey:kTPKCfgBadgeSize] != nil)
        _badgeSize = [prefs doubleForKey:kTPKCfgBadgeSize];
    if ([prefs objectForKey:kTPKCfgUsernameFontSize] != nil)
        _usernameFontSize = [prefs doubleForKey:kTPKCfgUsernameFontSize];
    if ([prefs objectForKey:kTPKCfgMessageFontSize] != nil)
        _messageFontSize = [prefs doubleForKey:kTPKCfgMessageFontSize];
    if ([prefs objectForKey:kTPKCfgLineSpacing] != nil)
        _lineSpacing = [prefs doubleForKey:kTPKCfgLineSpacing];
    if ([prefs objectForKey:kTPKCfgUsernameMessageSpacing] != nil)
        _usernameMessageSpacing = [prefs doubleForKey:kTPKCfgUsernameMessageSpacing];
    if ([prefs objectForKey:kTPKCfgEmoteVerticalOffset] != nil) {
        CGFloat savedOffset = [prefs doubleForKey:kTPKCfgEmoteVerticalOffset];
        // Migration unique de l'ancien défaut affiché 0 vers le nouveau vrai
        // défaut -6. Les valeurs personnalisées sont conservées telles quelles.
        if (![prefs boolForKey:kTPKCfgEmoteOffsetRealMigrated] &&
            fabs(savedOffset) < 0.0001) {
            savedOffset = kDefaultEmoteVerticalOffset;
            [prefs setDouble:savedOffset forKey:kTPKCfgEmoteVerticalOffset];
        }
        _emoteVerticalOffset = savedOffset;
    }
    [prefs setBool:YES forKey:kTPKCfgEmoteOffsetRealMigrated];
// Absents = pas encore réglés, la valeur en mémoire reste valable.
if ([prefs objectForKey:kTPKCfgPickerHeightPortrait] != nil)
        _pickerHeightPortrait = TPKClampPickerOption(
            [prefs doubleForKey:kTPKCfgPickerHeightPortrait],
            kTPKPickerHeightPortraitKey);
    if ([prefs objectForKey:kTPKCfgPickerHeightLandscape] != nil)
        _pickerHeightLandscape = TPKClampPickerOption(
            [prefs doubleForKey:kTPKCfgPickerHeightLandscape],
            kTPKPickerHeightLandscapeKey);
    if ([prefs objectForKey:kTPKCfgPickerEmoteScalePortrait] != nil)
        _pickerEmoteScalePortrait = TPKClampPickerOption(
            [prefs doubleForKey:kTPKCfgPickerEmoteScalePortrait],
            kTPKPickerEmoteScalePortraitKey);
    if ([prefs objectForKey:kTPKCfgPickerEmoteScaleLandscape] != nil)
        _pickerEmoteScaleLandscape = TPKClampPickerOption(
            [prefs doubleForKey:kTPKCfgPickerEmoteScaleLandscape],
            kTPKPickerEmoteScaleLandscapeKey);
    // Le réglage v2 est commun à tous les providers. Les installations
    // existantes n'ayant que la clé 7TV sont migrées sans perdre leur choix.
    NSString *resolutionKey = [prefs objectForKey:kTPKCfgEmoteImageResolution] != nil
        ? kTPKCfgEmoteImageResolution : kTPKCfgEmote7TVResolution;
    if ([prefs objectForKey:resolutionKey] != nil) {
        NSInteger savedResolution = [prefs integerForKey:resolutionKey];
        _emoteImageResolution = MIN(4, MAX(1, savedResolution));
        _emote7TVResolution = _emoteImageResolution;
        [prefs setInteger:_emoteImageResolution forKey:kTPKCfgEmoteImageResolution];
    }
    if ([prefs objectForKey:kTPKCfgSystemBGEnabled] != nil)
        _systemMessageBackgroundsEnabled = [prefs boolForKey:kTPKCfgSystemBGEnabled];

    NSString *subHex = [prefs stringForKey:kTPKCfgSubResubColor];
    // Faire suivre la nouvelle couleur par défaut aux installations qui ont
    // enregistré l'ancien vert. Toute autre couleur personnalisée est gardée.
    if (subHex.length > 0 &&
        [subHex caseInsensitiveCompare:@"30D173FF"] == NSOrderedSame) {
        subHex = TPKColorToHexString(TPKDefaultSubResubColor());
        [prefs setObject:subHex forKey:kTPKCfgSubResubColor];
    }
    UIColor *subColor = subHex ? TPKColorFromHexString(subHex) : nil;
    if (subColor) _subResubAccentColor = subColor;

    NSString *primeHex = [prefs stringForKey:kTPKCfgPrimeColor];
    UIColor *primeColor = primeHex ? TPKColorFromHexString(primeHex) : nil;
    if (primeColor) _primeAccentColor = primeColor;

    NSString *giftHex = [prefs stringForKey:kTPKCfgGiftColor];
    UIColor *giftColor = giftHex ? TPKColorFromHexString(giftHex) : nil;
    if (giftColor) _giftAccentColor = giftColor;

    if ([prefs objectForKey:kTPKCfgSelfMentionEnabled] != nil)
        _selfMentionHighlightEnabled = [prefs boolForKey:kTPKCfgSelfMentionEnabled];
    NSString *selfMentionHex = [prefs stringForKey:kTPKCfgSelfMentionColor];
    UIColor *selfMentionColor = selfMentionHex ? TPKColorFromHexString(selfMentionHex) : nil;
    if (selfMentionColor) _selfMentionHighlightColor = selfMentionColor;
    if ([prefs objectForKey:kTPKCfgFirstMessageEnabled] != nil)
        _showFirstMessageBadge = [prefs boolForKey:kTPKCfgFirstMessageEnabled];
    NSString *firstMessageHex = [prefs stringForKey:kTPKCfgFirstMessageColor];
    UIColor *firstMessageColor = firstMessageHex ? TPKColorFromHexString(firstMessageHex) : nil;
    if (firstMessageColor) _firstMessageHighlightColor = firstMessageColor;
    if ([prefs objectForKey:kTPKCfgSharedChatAvatarsEnabled] != nil)
        _sharedChatSourceAvatarsEnabled = [prefs boolForKey:kTPKCfgSharedChatAvatarsEnabled];
    if ([prefs objectForKey:kTPKCfgShowModerationDetails] != nil)
        _showModerationDetails = [prefs boolForKey:kTPKCfgShowModerationDetails];
    if ([prefs objectForKey:kTPKCfgDeletedRevealMode] != nil) {
        NSInteger mode = [prefs integerForKey:kTPKCfgDeletedRevealMode];
        _deletedMessageRevealMode = (mode >= TPKDeletedMessageRevealModeNever &&
                                     mode <= TPKDeletedMessageRevealModeAlways)
            ? (TPKDeletedMessageRevealMode)mode : kDefaultDeletedRevealMode;
    }
    if ([prefs objectForKey:kTPKCfgDeletedMessageStyle] != nil) {
        NSInteger style = [prefs integerForKey:kTPKCfgDeletedMessageStyle];
        _deletedMessageStyle = (style >= TPKDeletedMessageStyleDimmed &&
                                style <= TPKDeletedMessageStyleDimmedAndStrikethrough)
            ? (TPKDeletedMessageStyle)style : kDefaultDeletedMessageStyle;
    }
    if ([prefs objectForKey:kTPKCfgDeletedMessageOpacity] != nil) {
        CGFloat savedOpacity = [prefs doubleForKey:kTPKCfgDeletedMessageOpacity];
        // Migration unique de l'ancien défaut 58 % vers le nouveau 50 %.
        // Le marqueur évite de remigrer si l'utilisateur choisit lui-même
        // 58 % plus tard.
        if (![prefs boolForKey:kTPKCfgDeletedOpacityMigrated] &&
            fabs(savedOpacity - 0.58) < 0.0001) {
            savedOpacity = kDefaultDeletedMessageOpacity;
            [prefs setDouble:savedOpacity forKey:kTPKCfgDeletedMessageOpacity];
        }
        _deletedMessageTextOpacity = MIN(1.0, MAX(0.25, savedOpacity));
    }
    [prefs setBool:YES forKey:kTPKCfgDeletedOpacityMigrated];

    [[TPKManager sharedManager]
        log:@"[ChatCustom] 🏗 Config chargée — emote7TV=%.1f emoteTwitch=%.1f gif=%.1f badge=%.1f "
             @"pseudo=%.1f message=%.1f lineSpacing=%.1f pseudoMsgSpacing=%.1f "
             @"emoteOff=%.1f res=%ldx",
        _emote7TVSize, _emoteTwitchSize, _gifSize, _badgeSize, _usernameFontSize,
        _messageFontSize, _lineSpacing, _usernameMessageSpacing,
        _emoteVerticalOffset, (long)_emoteImageResolution];
}

- (void)setEmoteImageResolution:(NSInteger)value {
    NSInteger normalized = MIN(4, MAX(1, value));
    _emoteImageResolution = normalized;
    _emote7TVResolution = normalized;
}

- (void)setEmote7TVResolution:(NSInteger)value {
    // Alias historique : toute écriture de l'ancienne propriété met à jour
    // le réglage commun afin que les providers ne divergent jamais.
    [self setEmoteImageResolution:value];
}

- (void)save {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setDouble:self.emote7TVSize           forKey:kTPKCfgEmote7TVSize];
    [prefs setDouble:self.emoteTwitchSize        forKey:kTPKCfgEmoteTwitchSize];
    [prefs setDouble:self.gifSize                forKey:kTPKCfgGIFSize];
    [prefs setDouble:self.badgeSize              forKey:kTPKCfgBadgeSize];
    [prefs setDouble:self.usernameFontSize       forKey:kTPKCfgUsernameFontSize];
    [prefs setDouble:self.messageFontSize        forKey:kTPKCfgMessageFontSize];
    [prefs setDouble:self.lineSpacing            forKey:kTPKCfgLineSpacing];
    [prefs setDouble:self.usernameMessageSpacing forKey:kTPKCfgUsernameMessageSpacing];
    [prefs setDouble:self.emoteVerticalOffset    forKey:kTPKCfgEmoteVerticalOffset];
    [prefs setDouble:self.pickerHeightPortrait    forKey:kTPKCfgPickerHeightPortrait];
    [prefs setDouble:self.pickerHeightLandscape   forKey:kTPKCfgPickerHeightLandscape];
    [prefs setDouble:self.pickerEmoteScalePortrait  forKey:kTPKCfgPickerEmoteScalePortrait];
    [prefs setDouble:self.pickerEmoteScaleLandscape forKey:kTPKCfgPickerEmoteScaleLandscape];
    [prefs setInteger:self.emoteImageResolution  forKey:kTPKCfgEmoteImageResolution];
    [prefs setInteger:self.emoteImageResolution  forKey:kTPKCfgEmote7TVResolution];
    [prefs setBool:self.systemMessageBackgroundsEnabled forKey:kTPKCfgSystemBGEnabled];
    [prefs setObject:TPKColorToHexString(self.subResubAccentColor) forKey:kTPKCfgSubResubColor];
    [prefs setObject:TPKColorToHexString(self.primeAccentColor)    forKey:kTPKCfgPrimeColor];
    [prefs setObject:TPKColorToHexString(self.giftAccentColor)     forKey:kTPKCfgGiftColor];
    [prefs setBool:self.selfMentionHighlightEnabled forKey:kTPKCfgSelfMentionEnabled];
    [prefs setObject:TPKColorToHexString(self.selfMentionHighlightColor) forKey:kTPKCfgSelfMentionColor];
    [prefs setBool:self.showFirstMessageBadge forKey:kTPKCfgFirstMessageEnabled];
    [prefs setObject:TPKColorToHexString(self.firstMessageHighlightColor) forKey:kTPKCfgFirstMessageColor];
    [prefs setBool:self.sharedChatSourceAvatarsEnabled forKey:kTPKCfgSharedChatAvatarsEnabled];
    [prefs setBool:self.showModerationDetails forKey:kTPKCfgShowModerationDetails];
    [prefs setInteger:self.deletedMessageRevealMode forKey:kTPKCfgDeletedRevealMode];
    [prefs setInteger:self.deletedMessageStyle forKey:kTPKCfgDeletedMessageStyle];
    [prefs setDouble:self.deletedMessageTextOpacity forKey:kTPKCfgDeletedMessageOpacity];
}

// Setter custom (toggle simple, pas de table KVC comme les tailles) —
// mêmes garanties que setValue:forSizeKey: : sauvegarde + notification.
- (void)setSystemMessageBackgroundsEnabled:(BOOL)systemMessageBackgroundsEnabled {
    _systemMessageBackgroundsEnabled = systemMessageBackgroundsEnabled;
    [self save];
    [self tpk_postDidChangeNotification];
}

// Même garanties que setSystemMessageBackgroundsEnabled: ci-dessus.
- (void)setSelfMentionHighlightEnabled:(BOOL)selfMentionHighlightEnabled {
    _selfMentionHighlightEnabled = selfMentionHighlightEnabled;
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)setShowFirstMessageBadge:(BOOL)showFirstMessageBadge {
    _showFirstMessageBadge = showFirstMessageBadge;
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)setSharedChatSourceAvatarsEnabled:(BOOL)sharedChatSourceAvatarsEnabled {
    _sharedChatSourceAvatarsEnabled = sharedChatSourceAvatarsEnabled;
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)setShowModerationDetails:(BOOL)showModerationDetails {
    _showModerationDetails = showModerationDetails;
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)setDeletedMessageStyle:(TPKDeletedMessageStyle)deletedMessageStyle {
    _deletedMessageStyle = deletedMessageStyle;
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)setDeletedMessageRevealMode:(TPKDeletedMessageRevealMode)deletedMessageRevealMode {
    _deletedMessageRevealMode = deletedMessageRevealMode;
    [self save];
    [self tpk_postDidChangeNotification];
}

#pragma mark - Notification de changement (preview live, Phase 6)

- (void)tpk_postDidChangeNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKChatAppearanceConfigDidChangeNotification object:self];
    });
}

- (void)setValue:(CGFloat)value forSizeKey:(NSString *)key {
    if (!self.tpk_resetTable[key]) {
        [[TPKManager sharedManager]
            log:@"⚠️ setValue:forSizeKey: clé inconnue '%@'", key];
        return;
    }
    [self setValue:@(value) forKey:key];
    [self save];
    [self tpk_postDidChangeNotification];
}

#pragma mark - Reset (point d'accroche pour l'écran Phase 6)

- (nullable NSDictionary<NSString *, id> *)tpk_resetTable {
    return @{
        @"emote7TVSize":           @[@(kDefaultEmote7TVSize),          kTPKCfgEmote7TVSize],
        @"emoteTwitchSize":        @[@(kDefaultEmoteTwitchSize),       kTPKCfgEmoteTwitchSize],
        @"gifSize":                @[@(kDefaultGIFSize),               kTPKCfgGIFSize],
        @"badgeSize":              @[@(kDefaultBadgeSize),             kTPKCfgBadgeSize],
        @"usernameFontSize":       @[@(kDefaultUsernameFontSize),      kTPKCfgUsernameFontSize],
        @"messageFontSize":        @[@(kDefaultMessageFontSize),       kTPKCfgMessageFontSize],
        @"lineSpacing":            @[@(kDefaultLineSpacing),           kTPKCfgLineSpacing],
        @"usernameMessageSpacing": @[@(kDefaultUsernameMessageSpacing),kTPKCfgUsernameMessageSpacing],
        @"emoteVerticalOffset":    @[@(kDefaultEmoteVerticalOffset),   kTPKCfgEmoteVerticalOffset],
        @"pickerHeightPortrait":   @[@(kDefaultPickerHeightPortrait),  kTPKCfgPickerHeightPortrait],
        @"pickerHeightLandscape":  @[@(kDefaultPickerHeightLandscape), kTPKCfgPickerHeightLandscape],
        @"pickerEmoteScalePortrait":  @[@(kDefaultPickerEmoteScalePortrait),  kTPKCfgPickerEmoteScalePortrait],
        @"pickerEmoteScaleLandscape": @[@(kDefaultPickerEmoteScaleLandscape), kTPKCfgPickerEmoteScaleLandscape],
        @"emoteImageResolution":   @[@(kDefaultEmote7TVResolution),    kTPKCfgEmoteImageResolution],
        @"emote7TVResolution":     @[@(kDefaultEmote7TVResolution),    kTPKCfgEmote7TVResolution],
        @"deletedMessageTextOpacity": @[@(kDefaultDeletedMessageOpacity), kTPKCfgDeletedMessageOpacity],
    };
}

- (CGFloat)defaultValueForKey:(NSString *)key {
    NSArray *entry = self.tpk_resetTable[key];
    return entry ? [entry.firstObject doubleValue] : 0.0;
}

#pragma mark - Couleurs (mêmes garanties que les tailles, table séparée car
#pragma mark   type différent — UIColor, pas CGFloat)

- (NSDictionary<NSString *, id> *)tpk_colorResetTable {
    return @{
        @"subResubAccentColor": @[TPKDefaultSubResubColor(), kTPKCfgSubResubColor],
        @"primeAccentColor":    @[TPKDefaultPrimeColor(),    kTPKCfgPrimeColor],
        @"giftAccentColor":     @[TPKDefaultGiftColor(),     kTPKCfgGiftColor],
        @"selfMentionHighlightColor": @[TPKDefaultSelfMentionColor(), kTPKCfgSelfMentionColor],
        @"firstMessageHighlightColor": @[TPKDefaultFirstMessageColor(), kTPKCfgFirstMessageColor],
    };
}

- (void)setColor:(UIColor *)color forColorKey:(NSString *)key {
    if (!color || !self.tpk_colorResetTable[key]) {
        [[TPKManager sharedManager]
            log:@"⚠️ setColor:forColorKey: clé inconnue ou couleur nil '%@'", key];
        return;
    }
    [self setValue:color forKey:key];
    [self save];
    [self tpk_postDidChangeNotification];
}

- (nullable UIColor *)defaultColorForColorKey:(NSString *)key {
    NSArray *entry = self.tpk_colorResetTable[key];
    return entry ? entry.firstObject : nil;
}

- (void)resetColorKeyToDefault:(NSString *)key {
    NSArray *entry = self.tpk_colorResetTable[key];
    if (!entry) {
        [[TPKManager sharedManager]
            log:@"⚠️ resetColorKeyToDefault: clé inconnue '%@'", key];
        return;
    }
    [self setValue:entry.firstObject forKey:key];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:entry.lastObject];
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)resetKeyToDefault:(NSString *)key {
    NSArray *entry = self.tpk_resetTable[key];
    if (!entry) {
        [[TPKManager sharedManager]
            log:@"⚠️ resetKeyToDefault: clé inconnue '%@'", key];
        return;
    }
    [self setValue:entry.firstObject forKey:key];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:entry.lastObject];
    [self save];
    [self tpk_postDidChangeNotification];
}

- (void)resetAllToDefaults {
    [self tpk_applyDefaults];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    for (NSArray *entry in self.tpk_resetTable.allValues) {
        [prefs removeObjectForKey:entry.lastObject];
    }
    for (NSArray *entry in self.tpk_colorResetTable.allValues) {
        [prefs removeObjectForKey:entry.lastObject];
    }
    [prefs removeObjectForKey:kTPKCfgSystemBGEnabled];
    [prefs removeObjectForKey:kTPKCfgSelfMentionEnabled];
    [prefs removeObjectForKey:kTPKCfgFirstMessageEnabled];
    [prefs removeObjectForKey:kTPKCfgSharedChatAvatarsEnabled];
    [prefs removeObjectForKey:kTPKCfgShowModerationDetails];
    [prefs removeObjectForKey:kTPKCfgDeletedRevealMode];
    [prefs removeObjectForKey:kTPKCfgDeletedMessageStyle];
    [self save];
    [[TPKManager sharedManager] log:@"[ChatCustom] 🏗 Config réinitialisée aux défauts"];
    [self tpk_postDidChangeNotification];
}

@end
