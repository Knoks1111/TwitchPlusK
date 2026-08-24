/*
 * 7tv-chat-appearance-config.m
 *
 * Voir 7tv-chat-appearance-config.h pour le contexte (Phase 1b) et
 * l'avertissement sur les valeurs par défaut non encore mesurées.
 */

#import "Chat/7tv-chat-appearance-config.h"
#import "Core/7tv-core-manager.h"
#import <math.h>

NSString *const S7TVChatAppearanceConfigDidChangeNotification =
    @"S7TVChatAppearanceConfigDidChangeNotification";

// ── Sérialisation couleur (NSUserDefaults ne stocke pas UIColor) ───────────
// Format "RRGGBBAA" hexadécimal. Utilisé uniquement pour la persistance —
// en mémoire on garde toujours de vrais UIColor.
static NSString *S7TVColorToHexString(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return @"FFFFFFFF";
    return [NSString stringWithFormat:@"%02lX%02lX%02lX%02lX",
        (long)lround(r * 255.0), (long)lround(g * 255.0),
        (long)lround(b * 255.0), (long)lround(a * 255.0)];
}

static UIColor *S7TVColorFromHexString(NSString *hex) {
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
// 7tv-chat-custom-view.m (s7tv_cellForMessageID:), avant leur passage en
// config. Fonctions plutôt que des constantes CGFloat : UIColor n'est pas
// une constante compile-time.
static UIColor *S7TVDefaultSubResubColor(void) {
    return [UIColor colorWithRed:0.0 green:(122.0 / 255.0) blue:1.0 alpha:1.0]; // #007AFF
}
static UIColor *S7TVDefaultPrimeColor(void) {
    return [UIColor colorWithRed:0.62 green:0.35 blue:0.95 alpha:1.0];
}
static UIColor *S7TVDefaultGiftColor(void) {
    return [UIColor colorWithRed:0.90 green:0.20 blue:0.65 alpha:1.0];
}
// Rouge/cramoisi — reprend l'esprit du surlignage natif Twitch "vous êtes
// mentionné" (barre + fond teintés en rouge), voir référence Knoks.
static UIColor *S7TVDefaultSelfMentionColor(void) {
    return [UIColor colorWithRed:0.92 green:0.23 blue:0.27 alpha:1.0];
}
// Violet/magenta du bandeau FIRST MESSAGE natif montré dans la référence.
static UIColor *S7TVDefaultFirstMessageColor(void) {
    return [UIColor colorWithRed:0.82 green:0.18 blue:0.86 alpha:1.0];
}

// ── Clés NSUserDefaults ──────────────────────────────────────────────────────
static NSString *const kS7TVCfgEmote7TVSize           = @"s7tv_cfg_emote_7tv_size";
static NSString *const kS7TVCfgEmoteTwitchSize         = @"s7tv_cfg_emote_twitch_size";
static NSString *const kS7TVCfgBadgeSize               = @"s7tv_cfg_badge_size";
static NSString *const kS7TVCfgUsernameFontSize        = @"s7tv_cfg_username_font_size";
static NSString *const kS7TVCfgMessageFontSize         = @"s7tv_cfg_message_font_size";
static NSString *const kS7TVCfgLineSpacing             = @"s7tv_cfg_line_spacing";
static NSString *const kS7TVCfgUsernameMessageSpacing  = @"s7tv_cfg_username_message_spacing";
static NSString *const kS7TVCfgEmoteVerticalOffset     = @"s7tv_cfg_emote_vertical_offset";
static NSString *const kS7TVCfgEmoteOffsetRealMigrated = @"s7tv_cfg_emote_offset_real_v1_migrated";
static NSString *const kS7TVCfgEmote7TVResolution      = @"s7tv_cfg_emote_7tv_resolution";
static NSString *const kS7TVCfgSystemBGEnabled         = @"s7tv_cfg_system_bg_enabled";
static NSString *const kS7TVCfgSubResubColor           = @"s7tv_cfg_color_sub_resub";
static NSString *const kS7TVCfgPrimeColor              = @"s7tv_cfg_color_prime";
static NSString *const kS7TVCfgGiftColor               = @"s7tv_cfg_color_gift";
static NSString *const kS7TVCfgSelfMentionEnabled       = @"s7tv_cfg_self_mention_enabled";
static NSString *const kS7TVCfgSelfMentionColor         = @"s7tv_cfg_color_self_mention";
static NSString *const kS7TVCfgFirstMessageEnabled      = @"s7tv_cfg_first_message_enabled";
static NSString *const kS7TVCfgFirstMessageColor        = @"s7tv_cfg_color_first_message";
static NSString *const kS7TVCfgShowModerationDetails    = @"s7tv_cfg_show_moderation_details";
static NSString *const kS7TVCfgDeletedRevealMode        = @"s7tv_cfg_deleted_reveal_mode";
static NSString *const kS7TVCfgDeletedMessageStyle      = @"s7tv_cfg_deleted_message_style";
static NSString *const kS7TVCfgDeletedMessageOpacity    = @"s7tv_cfg_deleted_message_opacity";
static NSString *const kS7TVCfgDeletedOpacityMigrated   = @"s7tv_cfg_deleted_opacity_50_migrated";

static const CGFloat kDefaultEmote7TVSize          = 28.0;
static const CGFloat kDefaultEmoteTwitchSize        = 28.0; // TODO mesure réelle
static const CGFloat kDefaultBadgeSize              = 17.0;
static const CGFloat kDefaultUsernameFontSize       = 13.0;
static const CGFloat kDefaultMessageFontSize        = 13.0;
// 2.0, pas 6.0 : compense exactement le passage de la marge structurelle
// du label (top+bottom) de 4 à 8 dans SevenTVChatCustomView
// s7tv_heightForMessage: (correction du bug de clipping du dernier mot en
// cas limite de wrapping — voir commentaire de s7tv_measureAttributedText:
// dans ce fichier .m). 8 + 2 = 10 = ancien 4 + 6 : espacement visuel entre
// messages inchangé par défaut. Cette valeur reste "TODO mesure réelle"
// comme avant, seule la compensation a changé.
static const CGFloat kDefaultLineSpacing            = 2.0;  // défaut = rendu du picker à 6, compensé -4
static const CGFloat kDefaultUsernameMessageSpacing = 4.0;  // TODO mesure réelle
// Valeur réelle transmise aux bounds de l'attachment : le picker et le rendu
// utilisent désormais exactement le même nombre, sans rebase invisible.
static const CGFloat kDefaultEmoteVerticalOffset    = -6.0;
static const NSInteger kDefaultEmote7TVResolution   = 2;
static const CGFloat kDefaultDeletedMessageOpacity  = 0.50;
static const S7TVDeletedMessageStyle kDefaultDeletedMessageStyle = S7TVDeletedMessageStyleDimmed;
static const S7TVDeletedMessageRevealMode kDefaultDeletedRevealMode = S7TVDeletedMessageRevealModeOnTap;


@implementation SevenTVChatAppearanceConfig

+ (instancetype)sharedConfig {
    static SevenTVChatAppearanceConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVChatAppearanceConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self s7tv_applyDefaults];
        [self reloadFromDefaults];
    }
    return self;
}

- (void)s7tv_applyDefaults {
    _emote7TVSize           = kDefaultEmote7TVSize;
    _emoteTwitchSize        = kDefaultEmoteTwitchSize;
    _badgeSize               = kDefaultBadgeSize;
    _usernameFontSize        = kDefaultUsernameFontSize;
    _messageFontSize         = kDefaultMessageFontSize;
    _lineSpacing             = kDefaultLineSpacing;
    _usernameMessageSpacing  = kDefaultUsernameMessageSpacing;
    _emoteVerticalOffset     = kDefaultEmoteVerticalOffset;
    _emote7TVResolution      = kDefaultEmote7TVResolution;
    _systemMessageBackgroundsEnabled = YES;
    _subResubAccentColor     = S7TVDefaultSubResubColor();
    _primeAccentColor        = S7TVDefaultPrimeColor();
    _giftAccentColor         = S7TVDefaultGiftColor();
    _selfMentionHighlightEnabled = YES;
    _selfMentionHighlightColor   = S7TVDefaultSelfMentionColor();
    _showFirstMessageBadge       = YES;
    _firstMessageHighlightColor  = S7TVDefaultFirstMessageColor();
    _showModerationDetails       = YES;
    _deletedMessageRevealMode    = kDefaultDeletedRevealMode;
    _deletedMessageStyle         = kDefaultDeletedMessageStyle;
    _deletedMessageTextOpacity   = kDefaultDeletedMessageOpacity;
}

#pragma mark - Persistance

- (void)reloadFromDefaults {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    if ([prefs objectForKey:kS7TVCfgEmote7TVSize] != nil)
        _emote7TVSize = [prefs doubleForKey:kS7TVCfgEmote7TVSize];
    if ([prefs objectForKey:kS7TVCfgEmoteTwitchSize] != nil)
        _emoteTwitchSize = [prefs doubleForKey:kS7TVCfgEmoteTwitchSize];
    if ([prefs objectForKey:kS7TVCfgBadgeSize] != nil)
        _badgeSize = [prefs doubleForKey:kS7TVCfgBadgeSize];
    if ([prefs objectForKey:kS7TVCfgUsernameFontSize] != nil)
        _usernameFontSize = [prefs doubleForKey:kS7TVCfgUsernameFontSize];
    if ([prefs objectForKey:kS7TVCfgMessageFontSize] != nil)
        _messageFontSize = [prefs doubleForKey:kS7TVCfgMessageFontSize];
    if ([prefs objectForKey:kS7TVCfgLineSpacing] != nil)
        _lineSpacing = [prefs doubleForKey:kS7TVCfgLineSpacing];
    if ([prefs objectForKey:kS7TVCfgUsernameMessageSpacing] != nil)
        _usernameMessageSpacing = [prefs doubleForKey:kS7TVCfgUsernameMessageSpacing];
    if ([prefs objectForKey:kS7TVCfgEmoteVerticalOffset] != nil) {
        CGFloat savedOffset = [prefs doubleForKey:kS7TVCfgEmoteVerticalOffset];
        // Migration unique de l'ancien défaut affiché 0 vers le nouveau vrai
        // défaut -6. Les valeurs personnalisées sont conservées telles quelles.
        if (![prefs boolForKey:kS7TVCfgEmoteOffsetRealMigrated] &&
            fabs(savedOffset) < 0.0001) {
            savedOffset = kDefaultEmoteVerticalOffset;
            [prefs setDouble:savedOffset forKey:kS7TVCfgEmoteVerticalOffset];
        }
        _emoteVerticalOffset = savedOffset;
    }
    [prefs setBool:YES forKey:kS7TVCfgEmoteOffsetRealMigrated];
    if ([prefs objectForKey:kS7TVCfgEmote7TVResolution] != nil) {
        NSInteger savedResolution = [prefs integerForKey:kS7TVCfgEmote7TVResolution];
        _emote7TVResolution = MIN(4, MAX(1, savedResolution));
    }
    if ([prefs objectForKey:kS7TVCfgSystemBGEnabled] != nil)
        _systemMessageBackgroundsEnabled = [prefs boolForKey:kS7TVCfgSystemBGEnabled];

    NSString *subHex = [prefs stringForKey:kS7TVCfgSubResubColor];
    // Faire suivre la nouvelle couleur par défaut aux installations qui ont
    // enregistré l'ancien vert. Toute autre couleur personnalisée est gardée.
    if (subHex.length > 0 &&
        [subHex caseInsensitiveCompare:@"30D173FF"] == NSOrderedSame) {
        subHex = S7TVColorToHexString(S7TVDefaultSubResubColor());
        [prefs setObject:subHex forKey:kS7TVCfgSubResubColor];
    }
    UIColor *subColor = subHex ? S7TVColorFromHexString(subHex) : nil;
    if (subColor) _subResubAccentColor = subColor;

    NSString *primeHex = [prefs stringForKey:kS7TVCfgPrimeColor];
    UIColor *primeColor = primeHex ? S7TVColorFromHexString(primeHex) : nil;
    if (primeColor) _primeAccentColor = primeColor;

    NSString *giftHex = [prefs stringForKey:kS7TVCfgGiftColor];
    UIColor *giftColor = giftHex ? S7TVColorFromHexString(giftHex) : nil;
    if (giftColor) _giftAccentColor = giftColor;

    if ([prefs objectForKey:kS7TVCfgSelfMentionEnabled] != nil)
        _selfMentionHighlightEnabled = [prefs boolForKey:kS7TVCfgSelfMentionEnabled];
    NSString *selfMentionHex = [prefs stringForKey:kS7TVCfgSelfMentionColor];
    UIColor *selfMentionColor = selfMentionHex ? S7TVColorFromHexString(selfMentionHex) : nil;
    if (selfMentionColor) _selfMentionHighlightColor = selfMentionColor;
    if ([prefs objectForKey:kS7TVCfgFirstMessageEnabled] != nil)
        _showFirstMessageBadge = [prefs boolForKey:kS7TVCfgFirstMessageEnabled];
    NSString *firstMessageHex = [prefs stringForKey:kS7TVCfgFirstMessageColor];
    UIColor *firstMessageColor = firstMessageHex ? S7TVColorFromHexString(firstMessageHex) : nil;
    if (firstMessageColor) _firstMessageHighlightColor = firstMessageColor;
    if ([prefs objectForKey:kS7TVCfgShowModerationDetails] != nil)
        _showModerationDetails = [prefs boolForKey:kS7TVCfgShowModerationDetails];
    if ([prefs objectForKey:kS7TVCfgDeletedRevealMode] != nil) {
        NSInteger mode = [prefs integerForKey:kS7TVCfgDeletedRevealMode];
        _deletedMessageRevealMode = (mode >= S7TVDeletedMessageRevealModeNever &&
                                     mode <= S7TVDeletedMessageRevealModeAlways)
            ? (S7TVDeletedMessageRevealMode)mode : kDefaultDeletedRevealMode;
    }
    if ([prefs objectForKey:kS7TVCfgDeletedMessageStyle] != nil) {
        NSInteger style = [prefs integerForKey:kS7TVCfgDeletedMessageStyle];
        _deletedMessageStyle = (style >= S7TVDeletedMessageStyleDimmed &&
                                style <= S7TVDeletedMessageStyleDimmedAndStrikethrough)
            ? (S7TVDeletedMessageStyle)style : kDefaultDeletedMessageStyle;
    }
    if ([prefs objectForKey:kS7TVCfgDeletedMessageOpacity] != nil) {
        CGFloat savedOpacity = [prefs doubleForKey:kS7TVCfgDeletedMessageOpacity];
        // Migration unique de l'ancien défaut 58 % vers le nouveau 50 %.
        // Le marqueur évite de remigrer si l'utilisateur choisit lui-même
        // 58 % plus tard.
        if (![prefs boolForKey:kS7TVCfgDeletedOpacityMigrated] &&
            fabs(savedOpacity - 0.58) < 0.0001) {
            savedOpacity = kDefaultDeletedMessageOpacity;
            [prefs setDouble:savedOpacity forKey:kS7TVCfgDeletedMessageOpacity];
        }
        _deletedMessageTextOpacity = MIN(1.0, MAX(0.25, savedOpacity));
    }
    [prefs setBool:YES forKey:kS7TVCfgDeletedOpacityMigrated];

    [[SevenTVManager sharedManager]
        log:@"🏗 Config chargée — emote7TV=%.1f emoteTwitch=%.1f badge=%.1f "
             @"pseudo=%.1f message=%.1f lineSpacing=%.1f pseudoMsgSpacing=%.1f "
             @"emoteOff=%.1f res=%ldx",
        _emote7TVSize, _emoteTwitchSize, _badgeSize, _usernameFontSize,
        _messageFontSize, _lineSpacing, _usernameMessageSpacing,
        _emoteVerticalOffset, (long)_emote7TVResolution];
}

- (void)save {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setDouble:self.emote7TVSize           forKey:kS7TVCfgEmote7TVSize];
    [prefs setDouble:self.emoteTwitchSize        forKey:kS7TVCfgEmoteTwitchSize];
    [prefs setDouble:self.badgeSize              forKey:kS7TVCfgBadgeSize];
    [prefs setDouble:self.usernameFontSize       forKey:kS7TVCfgUsernameFontSize];
    [prefs setDouble:self.messageFontSize        forKey:kS7TVCfgMessageFontSize];
    [prefs setDouble:self.lineSpacing            forKey:kS7TVCfgLineSpacing];
    [prefs setDouble:self.usernameMessageSpacing forKey:kS7TVCfgUsernameMessageSpacing];
    [prefs setDouble:self.emoteVerticalOffset    forKey:kS7TVCfgEmoteVerticalOffset];
    [prefs setInteger:self.emote7TVResolution    forKey:kS7TVCfgEmote7TVResolution];
    [prefs setBool:self.systemMessageBackgroundsEnabled forKey:kS7TVCfgSystemBGEnabled];
    [prefs setObject:S7TVColorToHexString(self.subResubAccentColor) forKey:kS7TVCfgSubResubColor];
    [prefs setObject:S7TVColorToHexString(self.primeAccentColor)    forKey:kS7TVCfgPrimeColor];
    [prefs setObject:S7TVColorToHexString(self.giftAccentColor)     forKey:kS7TVCfgGiftColor];
    [prefs setBool:self.selfMentionHighlightEnabled forKey:kS7TVCfgSelfMentionEnabled];
    [prefs setObject:S7TVColorToHexString(self.selfMentionHighlightColor) forKey:kS7TVCfgSelfMentionColor];
    [prefs setBool:self.showFirstMessageBadge forKey:kS7TVCfgFirstMessageEnabled];
    [prefs setObject:S7TVColorToHexString(self.firstMessageHighlightColor) forKey:kS7TVCfgFirstMessageColor];
    [prefs setBool:self.showModerationDetails forKey:kS7TVCfgShowModerationDetails];
    [prefs setInteger:self.deletedMessageRevealMode forKey:kS7TVCfgDeletedRevealMode];
    [prefs setInteger:self.deletedMessageStyle forKey:kS7TVCfgDeletedMessageStyle];
    [prefs setDouble:self.deletedMessageTextOpacity forKey:kS7TVCfgDeletedMessageOpacity];
}

// Setter custom (toggle simple, pas de table KVC comme les tailles) —
// mêmes garanties que setValue:forSizeKey: : sauvegarde + notification.
- (void)setSystemMessageBackgroundsEnabled:(BOOL)systemMessageBackgroundsEnabled {
    _systemMessageBackgroundsEnabled = systemMessageBackgroundsEnabled;
    [self save];
    [self s7tv_postDidChangeNotification];
}

// Même garanties que setSystemMessageBackgroundsEnabled: ci-dessus.
- (void)setSelfMentionHighlightEnabled:(BOOL)selfMentionHighlightEnabled {
    _selfMentionHighlightEnabled = selfMentionHighlightEnabled;
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)setShowFirstMessageBadge:(BOOL)showFirstMessageBadge {
    _showFirstMessageBadge = showFirstMessageBadge;
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)setShowModerationDetails:(BOOL)showModerationDetails {
    _showModerationDetails = showModerationDetails;
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)setDeletedMessageStyle:(S7TVDeletedMessageStyle)deletedMessageStyle {
    _deletedMessageStyle = deletedMessageStyle;
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)setDeletedMessageRevealMode:(S7TVDeletedMessageRevealMode)deletedMessageRevealMode {
    _deletedMessageRevealMode = deletedMessageRevealMode;
    [self save];
    [self s7tv_postDidChangeNotification];
}

#pragma mark - Notification de changement (preview live, Phase 6)

- (void)s7tv_postDidChangeNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVChatAppearanceConfigDidChangeNotification object:self];
    });
}

- (void)setValue:(CGFloat)value forSizeKey:(NSString *)key {
    if (!self.s7tv_resetTable[key]) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ setValue:forSizeKey: clé inconnue '%@'", key];
        return;
    }
    [self setValue:@(value) forKey:key];
    [self save];
    [self s7tv_postDidChangeNotification];
}

#pragma mark - Reset (point d'accroche pour l'écran Phase 6)

- (nullable NSDictionary<NSString *, id> *)s7tv_resetTable {
    return @{
        @"emote7TVSize":           @[@(kDefaultEmote7TVSize),          kS7TVCfgEmote7TVSize],
        @"emoteTwitchSize":        @[@(kDefaultEmoteTwitchSize),       kS7TVCfgEmoteTwitchSize],
        @"badgeSize":              @[@(kDefaultBadgeSize),             kS7TVCfgBadgeSize],
        @"usernameFontSize":       @[@(kDefaultUsernameFontSize),      kS7TVCfgUsernameFontSize],
        @"messageFontSize":        @[@(kDefaultMessageFontSize),       kS7TVCfgMessageFontSize],
        @"lineSpacing":            @[@(kDefaultLineSpacing),           kS7TVCfgLineSpacing],
        @"usernameMessageSpacing": @[@(kDefaultUsernameMessageSpacing),kS7TVCfgUsernameMessageSpacing],
        @"emoteVerticalOffset":    @[@(kDefaultEmoteVerticalOffset),   kS7TVCfgEmoteVerticalOffset],
        @"emote7TVResolution":     @[@(kDefaultEmote7TVResolution),    kS7TVCfgEmote7TVResolution],
        @"deletedMessageTextOpacity": @[@(kDefaultDeletedMessageOpacity), kS7TVCfgDeletedMessageOpacity],
    };
}

- (CGFloat)defaultValueForKey:(NSString *)key {
    NSArray *entry = self.s7tv_resetTable[key];
    return entry ? [entry.firstObject doubleValue] : 0.0;
}

#pragma mark - Couleurs (mêmes garanties que les tailles, table séparée car
#pragma mark   type différent — UIColor, pas CGFloat)

- (NSDictionary<NSString *, id> *)s7tv_colorResetTable {
    return @{
        @"subResubAccentColor": @[S7TVDefaultSubResubColor(), kS7TVCfgSubResubColor],
        @"primeAccentColor":    @[S7TVDefaultPrimeColor(),    kS7TVCfgPrimeColor],
        @"giftAccentColor":     @[S7TVDefaultGiftColor(),     kS7TVCfgGiftColor],
        @"selfMentionHighlightColor": @[S7TVDefaultSelfMentionColor(), kS7TVCfgSelfMentionColor],
        @"firstMessageHighlightColor": @[S7TVDefaultFirstMessageColor(), kS7TVCfgFirstMessageColor],
    };
}

- (void)setColor:(UIColor *)color forColorKey:(NSString *)key {
    if (!color || !self.s7tv_colorResetTable[key]) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ setColor:forColorKey: clé inconnue ou couleur nil '%@'", key];
        return;
    }
    [self setValue:color forKey:key];
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (nullable UIColor *)defaultColorForColorKey:(NSString *)key {
    NSArray *entry = self.s7tv_colorResetTable[key];
    return entry ? entry.firstObject : nil;
}

- (void)resetColorKeyToDefault:(NSString *)key {
    NSArray *entry = self.s7tv_colorResetTable[key];
    if (!entry) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ resetColorKeyToDefault: clé inconnue '%@'", key];
        return;
    }
    [self setValue:entry.firstObject forKey:key];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:entry.lastObject];
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)resetKeyToDefault:(NSString *)key {
    NSArray *entry = self.s7tv_resetTable[key];
    if (!entry) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ resetKeyToDefault: clé inconnue '%@'", key];
        return;
    }
    [self setValue:entry.firstObject forKey:key];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:entry.lastObject];
    [self save];
    [self s7tv_postDidChangeNotification];
}

- (void)resetAllToDefaults {
    [self s7tv_applyDefaults];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    for (NSArray *entry in self.s7tv_resetTable.allValues) {
        [prefs removeObjectForKey:entry.lastObject];
    }
    for (NSArray *entry in self.s7tv_colorResetTable.allValues) {
        [prefs removeObjectForKey:entry.lastObject];
    }
    [prefs removeObjectForKey:kS7TVCfgSystemBGEnabled];
    [prefs removeObjectForKey:kS7TVCfgSelfMentionEnabled];
    [prefs removeObjectForKey:kS7TVCfgFirstMessageEnabled];
    [prefs removeObjectForKey:kS7TVCfgShowModerationDetails];
    [prefs removeObjectForKey:kS7TVCfgDeletedRevealMode];
    [prefs removeObjectForKey:kS7TVCfgDeletedMessageStyle];
    [self save];
    [[SevenTVManager sharedManager] log:@"🏗 Config réinitialisée aux défauts"];
    [self s7tv_postDidChangeNotification];
}

@end
