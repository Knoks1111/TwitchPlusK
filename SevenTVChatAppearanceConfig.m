/*
 * SevenTVChatAppearanceConfig.m
 *
 * Voir SevenTVChatAppearanceConfig.h pour le contexte (Phase 1b) et
 * l'avertissement sur les valeurs par défaut non encore mesurées.
 */

#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVManager.h"
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
// SevenTVChatCustomView.m (s7tv_cellForMessageID:), avant leur passage en
// config. Fonctions plutôt que des constantes CGFloat : UIColor n'est pas
// une constante compile-time.
static UIColor *S7TVDefaultSubResubColor(void) {
    return [UIColor colorWithRed:0.19 green:0.82 blue:0.45 alpha:1.0];
}
static UIColor *S7TVDefaultPrimeColor(void) {
    return [UIColor colorWithRed:0.62 green:0.35 blue:0.95 alpha:1.0];
}
static UIColor *S7TVDefaultGiftColor(void) {
    return [UIColor colorWithRed:0.90 green:0.20 blue:0.65 alpha:1.0];
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
static NSString *const kS7TVCfgEmote7TVResolution      = @"s7tv_cfg_emote_7tv_resolution";
static NSString *const kS7TVCfgSystemBGEnabled         = @"s7tv_cfg_system_bg_enabled";
static NSString *const kS7TVCfgSubResubColor           = @"s7tv_cfg_color_sub_resub";
static NSString *const kS7TVCfgPrimeColor              = @"s7tv_cfg_color_prime";
static NSString *const kS7TVCfgGiftColor               = @"s7tv_cfg_color_gift";

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
// 0 = rendu d'origine (emote posée sur la ligne du bas, ce qui correspondait
// avant à +4 sur l'ancienne échelle). Sens logique : positif = vers le haut,
// négatif = vers le bas. Le rebase de +4 vers 0 est appliqué au moment du
// rendu (voir SevenTVChatCustomView.m et 7tv-picker-sizes.m), pas ici.
static const CGFloat kDefaultEmoteVerticalOffset    = 0.0;
static const NSInteger kDefaultEmote7TVResolution   = 2;


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
    if ([prefs objectForKey:kS7TVCfgEmoteVerticalOffset] != nil)
        _emoteVerticalOffset = [prefs doubleForKey:kS7TVCfgEmoteVerticalOffset];
    if ([prefs objectForKey:kS7TVCfgEmote7TVResolution] != nil)
        _emote7TVResolution = [prefs integerForKey:kS7TVCfgEmote7TVResolution];
    if ([prefs objectForKey:kS7TVCfgSystemBGEnabled] != nil)
        _systemMessageBackgroundsEnabled = [prefs boolForKey:kS7TVCfgSystemBGEnabled];

    NSString *subHex = [prefs stringForKey:kS7TVCfgSubResubColor];
    UIColor *subColor = subHex ? S7TVColorFromHexString(subHex) : nil;
    if (subColor) _subResubAccentColor = subColor;

    NSString *primeHex = [prefs stringForKey:kS7TVCfgPrimeColor];
    UIColor *primeColor = primeHex ? S7TVColorFromHexString(primeHex) : nil;
    if (primeColor) _primeAccentColor = primeColor;

    NSString *giftHex = [prefs stringForKey:kS7TVCfgGiftColor];
    UIColor *giftColor = giftHex ? S7TVColorFromHexString(giftHex) : nil;
    if (giftColor) _giftAccentColor = giftColor;

    [[SevenTVManager sharedManager]
        log:@"[ChatCustom] 🏗 Config chargée — emote7TV=%.1f emoteTwitch=%.1f badge=%.1f "
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
}

// Setter custom (toggle simple, pas de table KVC comme les tailles) —
// mêmes garanties que setValue:forSizeKey: : sauvegarde + notification.
- (void)setSystemMessageBackgroundsEnabled:(BOOL)systemMessageBackgroundsEnabled {
    _systemMessageBackgroundsEnabled = systemMessageBackgroundsEnabled;
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
            log:@"[ChatCustom] ⚠️ setValue:forSizeKey: clé inconnue '%@'", key];
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
    };
}

- (void)setColor:(UIColor *)color forColorKey:(NSString *)key {
    if (!color || !self.s7tv_colorResetTable[key]) {
        [[SevenTVManager sharedManager]
            log:@"[ChatCustom] ⚠️ setColor:forColorKey: clé inconnue ou couleur nil '%@'", key];
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
            log:@"[ChatCustom] ⚠️ resetColorKeyToDefault: clé inconnue '%@'", key];
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
            log:@"[ChatCustom] ⚠️ resetKeyToDefault: clé inconnue '%@'", key];
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
    [self save];
    [[SevenTVManager sharedManager] log:@"[ChatCustom] 🏗 Config réinitialisée aux défauts"];
    [self s7tv_postDidChangeNotification];
}

@end