#import "Emote/tpK-provider-settings.h"

NSString *const TPKEmoteProviderSettingsDidChangeNotification =
    @"TPKEmoteProviderSettingsDidChangeNotification";

NSString *const TPKEmotePickerOpeningModeFavorites = @"favorites";
NSString *const TPKEmotePickerOpeningModeTPKChannel = @"7tv-channel";
NSString *const TPKEmotePickerOpeningModeBTTVChannel = @"bttv-channel";
NSString *const TPKEmotePickerOpeningModeFFZChannel = @"ffz-channel";
NSString *const TPKEmotePickerOpeningModeLastUsed = @"last-used";

static NSString *const kTPKProviderEnabledPrefix = @"tpk_emote_provider_enabled_";
static NSString *const kTPKProviderPriority = @"tpk_emote_provider_priority";
static NSString *const kTPKZeroWidthEnabled = @"tpk_emote_zero_width_enabled";
static NSString *const kTPKMixedPickerEnabled = @"tpk_emote_picker_mixed_providers_enabled";
static NSString *const kTPKPickerOpeningMode = @"tpk_emote_picker_opening_mode";
static NSString *const kTPKPickerLastLocation = @"tpk_emote_picker_last_location";
static NSString *const kTPKProviderSettingsMigrated = @"tpk_emote_provider_settings_v1_migrated";

NSString *TPKEmoteProviderIdentifier(TPKExternalEmoteProvider provider) {
    switch (provider) {
        case TPKExternalEmoteProviderBTTV: return @"bttv";
        case TPKExternalEmoteProviderFFZ: return @"ffz";
        case TPKExternalEmoteProvider7TV:
        default: return @"7tv";
    }
}

TPKExternalEmoteProvider TPKEmoteProviderFromIdentifier(NSString *identifier) {
    NSString *value = [identifier.lowercaseString stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value isEqualToString:@"bttv"] || [value isEqualToString:@"betterttv"])
        return TPKExternalEmoteProviderBTTV;
    if ([value isEqualToString:@"ffz"] || [value isEqualToString:@"frankerfacez"])
        return TPKExternalEmoteProviderFFZ;
    return TPKExternalEmoteProvider7TV;
}

static NSUserDefaults *TPKProviderDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

@implementation TPKEmoteProviderSettings

+ (BOOL)isProviderEnabled:(TPKExternalEmoteProvider)provider {
    [self migrateLegacySettings];
    NSString *key = [kTPKProviderEnabledPrefix stringByAppendingString:
        TPKEmoteProviderIdentifier(provider)];
    NSUserDefaults *defaults = TPKProviderDefaults();
    return [defaults objectForKey:key] == nil ? YES : [defaults boolForKey:key];
}

+ (void)setProvider:(TPKExternalEmoteProvider)provider enabled:(BOOL)enabled {
    NSString *key = [kTPKProviderEnabledPrefix stringByAppendingString:
        TPKEmoteProviderIdentifier(provider)];
    [TPKProviderDefaults() setBool:enabled forKey:key];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSArray<NSString *> *)providerPriority {
    [self migrateLegacySettings];
    id rawSaved = [TPKProviderDefaults() objectForKey:kTPKProviderPriority];
    NSArray *saved = [rawSaved isKindOfClass:[NSArray class]] ? rawSaved : @[];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:3];
    for (id item in saved) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *identifier = TPKEmoteProviderIdentifier(
            TPKEmoteProviderFromIdentifier(item));
        if (![result containsObject:identifier]) [result addObject:identifier];
    }
    for (TPKExternalEmoteProvider provider = TPKExternalEmoteProvider7TV;
         provider <= TPKExternalEmoteProviderFFZ; provider++) {
        NSString *identifier = TPKEmoteProviderIdentifier(provider);
        if (![result containsObject:identifier]) [result addObject:identifier];
    }
    return [result copy];
}

+ (void)setProviderPriority:(NSArray<NSString *> *)priority {
    // Réécrire la liste permet de garantir un ordre déterministe même si un
    // export a été modifié manuellement ou contient des identifiants inconnus.
    NSMutableArray *sanitized = [NSMutableArray arrayWithCapacity:3];
    for (id item in priority) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *identifier = TPKEmoteProviderIdentifier(
            TPKEmoteProviderFromIdentifier(item));
        if (![sanitized containsObject:identifier]) [sanitized addObject:identifier];
    }
    for (TPKExternalEmoteProvider provider = TPKExternalEmoteProvider7TV;
         provider <= TPKExternalEmoteProviderFFZ; provider++) {
        NSString *identifier = TPKEmoteProviderIdentifier(provider);
        if (![sanitized containsObject:identifier]) [sanitized addObject:identifier];
    }
    [TPKProviderDefaults() setObject:sanitized forKey:kTPKProviderPriority];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (BOOL)zeroWidthEnabled {
    [self migrateLegacySettings];
    // Zero-Width fait partie du rendu multi-provider et n'est plus un
    // réglage utilisateur : les anciennes installations qui l'avaient
    // désactivé sont automatiquement réactivées lors de la migration.
    return YES;
}

+ (void)setZeroWidthEnabled:(BOOL)enabled {
    (void)enabled;
    [TPKProviderDefaults() setBool:YES forKey:kTPKZeroWidthEnabled];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (BOOL)mixedPickerEnabled {
    NSUserDefaults *defaults = TPKProviderDefaults();
    // Keep the existing three-provider picker as the default for upgrades and
    // fresh installs. The user explicitly opts in to the aggregate tab.
    return [defaults objectForKey:kTPKMixedPickerEnabled] == nil
        ? NO : [defaults boolForKey:kTPKMixedPickerEnabled];
}

+ (void)setMixedPickerEnabled:(BOOL)enabled {
    [TPKProviderDefaults() setBool:enabled forKey:kTPKMixedPickerEnabled];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSString *)pickerOpeningMode {
    [self migrateLegacySettings];
    NSString *mode = [TPKProviderDefaults() stringForKey:kTPKPickerOpeningMode];
    NSArray<NSString *> *validModes = @[
        TPKEmotePickerOpeningModeFavorites,
        TPKEmotePickerOpeningModeTPKChannel,
        TPKEmotePickerOpeningModeBTTVChannel,
        TPKEmotePickerOpeningModeFFZChannel,
        TPKEmotePickerOpeningModeLastUsed,
    ];
    return [validModes containsObject:mode]
        ? mode : TPKEmotePickerOpeningModeFavorites;
}

+ (void)setPickerOpeningMode:(NSString *)mode {
    NSArray<NSString *> *validModes = @[
        TPKEmotePickerOpeningModeFavorites,
        TPKEmotePickerOpeningModeTPKChannel,
        TPKEmotePickerOpeningModeBTTVChannel,
        TPKEmotePickerOpeningModeFFZChannel,
        TPKEmotePickerOpeningModeLastUsed,
    ];
    if (![validModes containsObject:mode]) return;
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
    BOOL alreadyMigrated = [defaults boolForKey:kTPKProviderSettingsMigrated];

    // Les anciennes versions n'avaient qu'un interrupteur 7TV exposé par le
    // manager. Si sa clé historique existe, la reporter sans modifier le
    // comportement des installations neuves. Cette vérification reste
    // volontairement active après la migration : un utilisateur peut importer
    // à tout moment un ancien export qui ne contient pas encore la clé v2.
    if ([defaults objectForKey:@"tpk_enabled"] != nil &&
        [defaults objectForKey:@"tpk_emote_provider_enabled_7tv"] == nil) {
        [defaults setBool:[defaults boolForKey:@"tpk_enabled"]
                   forKey:@"tpk_emote_provider_enabled_7tv"];
    }

    // A short-lived development build stored the three switches in one
    // dictionary. Promote any missing provider keys on every call as well, so
    // importing that export after the one-time marker was written still
    // preserves a disabled BTTV/FFZ choice.
    NSDictionary *aggregate = [defaults dictionaryForKey:@"tpk_emote_provider_enabled"];
    if ([aggregate isKindOfClass:NSDictionary.class]) {
        for (TPKExternalEmoteProvider provider = TPKExternalEmoteProvider7TV;
             provider <= TPKExternalEmoteProviderFFZ; provider++) {
            NSString *key = [kTPKProviderEnabledPrefix stringByAppendingString:
                TPKEmoteProviderIdentifier(provider)];
            if ([defaults objectForKey:key] != nil) continue;
            id value = aggregate[TPKEmoteProviderIdentifier(provider)];
            if (!value) {
                NSString *numericKey = [@(provider) stringValue];
                value = aggregate[numericKey];
            }
            if ([value respondsToSelector:@selector(boolValue)])
                [defaults setBool:[value boolValue] forKey:key];
        }
    }

    // L'option n'est plus exposée : Zero-Width doit toujours rester actif,
    // y compris après l'import d'un ancien export qui contenait false.
    if (![defaults boolForKey:kTPKZeroWidthEnabled])
        [defaults setBool:YES forKey:kTPKZeroWidthEnabled];

    // Le comportement d'une installation neuve reste déterministe : le
    // picker commence dans Favoris tant que l'utilisateur n'a pas choisi un
    // autre emplacement. Les builds précédents pouvaient laisser la clé
    // absente, ce qui forçait alors la sélection implicite du premier provider.
    if (![defaults objectForKey:kTPKPickerOpeningMode])
        [defaults setObject:TPKEmotePickerOpeningModeFavorites
                     forKey:kTPKPickerOpeningMode];

    // Le reste de la migration n'a besoin d'être exécuté qu'une fois. Les
    // préférences v2 déjà présentes doivent toujours rester prioritaires sur
    // une ancienne représentation éventuellement encore conservée dans les
    // defaults.
    if (alreadyMigrated) return;

    if ([defaults objectForKey:kTPKProviderPriority] == nil)
        [defaults setObject:@[@"7tv", @"bttv", @"ffz"] forKey:kTPKProviderPriority];
    [defaults setBool:YES forKey:kTPKProviderSettingsMigrated];
}

@end
