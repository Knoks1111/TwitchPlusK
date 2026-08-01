/*
 * SevenTVChatAppearanceConfig.m
 *
 * Voir SevenTVChatAppearanceConfig.h pour le contexte (Phase 1b) et
 * l'avertissement sur les valeurs par défaut non encore mesurées.
 */

#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVManager.h"

NSString *const S7TVChatAppearanceConfigDidChangeNotification =
    @"S7TVChatAppearanceConfigDidChangeNotification";

// ── Clés NSUserDefaults ──────────────────────────────────────────────────────
static NSString *const kS7TVCfgEmote7TVSize           = @"s7tv_cfg_emote_7tv_size";
static NSString *const kS7TVCfgEmoteTwitchSize         = @"s7tv_cfg_emote_twitch_size";
static NSString *const kS7TVCfgBadgeSize               = @"s7tv_cfg_badge_size";
static NSString *const kS7TVCfgUsernameFontSize        = @"s7tv_cfg_username_font_size";
static NSString *const kS7TVCfgMessageFontSize         = @"s7tv_cfg_message_font_size";
static NSString *const kS7TVCfgLineSpacing             = @"s7tv_cfg_line_spacing";
static NSString *const kS7TVCfgUsernameMessageSpacing  = @"s7tv_cfg_username_message_spacing";
static NSString *const kS7TVCfgEmote7TVResolution      = @"s7tv_cfg_emote_7tv_resolution";

static const CGFloat kDefaultEmote7TVSize          = 28.0;
static const CGFloat kDefaultEmoteTwitchSize        = 28.0; // TODO mesure réelle
static const CGFloat kDefaultBadgeSize              = 17.0;
static const CGFloat kDefaultUsernameFontSize       = 13.0;
static const CGFloat kDefaultMessageFontSize        = 13.0;
static const CGFloat kDefaultLineSpacing            = 4.0;  // TODO mesure réelle
static const CGFloat kDefaultUsernameMessageSpacing = 4.0;  // TODO mesure réelle
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
    _emote7TVResolution      = kDefaultEmote7TVResolution;
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
    if ([prefs objectForKey:kS7TVCfgEmote7TVResolution] != nil)
        _emote7TVResolution = [prefs integerForKey:kS7TVCfgEmote7TVResolution];

    [[SevenTVManager sharedManager]
        log:@"[ChatCustom] 🏗 Config chargée — emote7TV=%.1f emoteTwitch=%.1f badge=%.1f "
             @"pseudo=%.1f message=%.1f lineSpacing=%.1f pseudoMsgSpacing=%.1f res=%ldx",
        _emote7TVSize, _emoteTwitchSize, _badgeSize, _usernameFontSize,
        _messageFontSize, _lineSpacing, _usernameMessageSpacing,
        (long)_emote7TVResolution];
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
    [prefs setInteger:self.emote7TVResolution    forKey:kS7TVCfgEmote7TVResolution];
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

// Table nom-de-propriété → (défaut, clé UserDefaults). Une seule table à
// maintenir plutôt qu'un if/else dupliqué entre reset et save/load.
- (nullable NSDictionary<NSString *, id> *)s7tv_resetTable {
    return @{
        @"emote7TVSize":           @[@(kDefaultEmote7TVSize),          kS7TVCfgEmote7TVSize],
        @"emoteTwitchSize":        @[@(kDefaultEmoteTwitchSize),       kS7TVCfgEmoteTwitchSize],
        @"badgeSize":              @[@(kDefaultBadgeSize),             kS7TVCfgBadgeSize],
        @"usernameFontSize":       @[@(kDefaultUsernameFontSize),      kS7TVCfgUsernameFontSize],
        @"messageFontSize":        @[@(kDefaultMessageFontSize),       kS7TVCfgMessageFontSize],
        @"lineSpacing":            @[@(kDefaultLineSpacing),           kS7TVCfgLineSpacing],
        @"usernameMessageSpacing": @[@(kDefaultUsernameMessageSpacing),kS7TVCfgUsernameMessageSpacing],
        @"emote7TVResolution":     @[@(kDefaultEmote7TVResolution),    kS7TVCfgEmote7TVResolution],
    };
}

- (CGFloat)defaultValueForKey:(NSString *)key {
    NSArray *entry = self.s7tv_resetTable[key];
    return entry ? [entry.firstObject doubleValue] : 0.0;
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
    [self save];
    [[SevenTVManager sharedManager] log:@"[ChatCustom] 🏗 Config réinitialisée aux défauts"];
    [self s7tv_postDidChangeNotification];
}

@end
