#import "Picker/tpK-picker-settings.h"

NSString *const TPKEmoteProviderSettingsDidChangeNotification =
    @"TPKEmoteProviderSettingsDidChangeNotification";

NSString *const TPKEmotePickerOpeningModeFavorites = @"favorites";
NSString *const TPKEmotePickerOpeningModeTPKChannel = @"7tv-channel";
NSString *const TPKEmotePickerOpeningModeBTTVChannel = @"bttv-channel";
NSString *const TPKEmotePickerOpeningModeFFZChannel = @"ffz-channel";
NSString *const TPKEmotePickerOpeningModeLastUsed = @"last-used";

static NSString *const kTPKMixedPickerEnabled = @"tpk_emote_picker_mixed_providers_enabled";
static NSString *const kTPKPickerOpeningMode = @"tpk_emote_picker_opening_mode";
static NSString *const kTPKPickerLastLocation = @"tpk_emote_picker_last_location";

static NSArray<NSString *> *TPKValidPickerOpeningModes(void) {
    return @[
        TPKEmotePickerOpeningModeFavorites,
        TPKEmotePickerOpeningModeTPKChannel,
        TPKEmotePickerOpeningModeBTTVChannel,
        TPKEmotePickerOpeningModeFFZChannel,
        TPKEmotePickerOpeningModeLastUsed,
    ];
}

static NSUserDefaults *TPKProviderDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

@implementation TPKEmoteProviderSettings
+ (BOOL)mixedPickerEnabled {
    return [TPKProviderDefaults() boolForKey:kTPKMixedPickerEnabled];
}

+ (void)setMixedPickerEnabled:(BOOL)enabled {
    [TPKProviderDefaults() setBool:enabled forKey:kTPKMixedPickerEnabled];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSString *)pickerOpeningMode {
    [self migrateLegacySettings];
    NSString *mode = [TPKProviderDefaults() stringForKey:kTPKPickerOpeningMode];
    return [mode isKindOfClass:NSString.class] &&
        [TPKValidPickerOpeningModes() containsObject:mode]
        ? mode : TPKEmotePickerOpeningModeFavorites;
}

+ (void)setPickerOpeningMode:(NSString *)mode {
    if (![mode isKindOfClass:NSString.class] ||
        ![TPKValidPickerOpeningModes() containsObject:mode]) return;
    [TPKProviderDefaults() setObject:mode forKey:kTPKPickerOpeningMode];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSString *)lastPickerLocation {
    NSString *location = [TPKProviderDefaults() stringForKey:kTPKPickerLastLocation];
    return location.length <= 256 ? location : nil;
}

+ (void)setLastPickerLocation:(NSString *)location {
    if (!location.length || location.length > 256) return;
    [TPKProviderDefaults() setObject:location forKey:kTPKPickerLastLocation];
}

+ (void)migrateLegacySettings {
    NSUserDefaults *defaults = TPKProviderDefaults();
    if (![defaults objectForKey:kTPKPickerOpeningMode])
        [defaults setObject:TPKEmotePickerOpeningModeFavorites forKey:kTPKPickerOpeningMode];
}

@end
