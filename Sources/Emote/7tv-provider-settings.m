#import "Emote/7tv-provider-settings.h"

NSString *const S7TVEmoteProviderSettingsDidChangeNotification =
    @"S7TVEmoteProviderSettingsDidChangeNotification";

NSString *const S7TVEmotePickerOpeningModeFavorites = @"favorites";
NSString *const S7TVEmotePickerOpeningModeSevenTVChannel = @"7tv-channel";
NSString *const S7TVEmotePickerOpeningModeBTTVChannel = @"bttv-channel";
NSString *const S7TVEmotePickerOpeningModeFFZChannel = @"ffz-channel";
NSString *const S7TVEmotePickerOpeningModeLastUsed = @"last-used";

static NSString *const kS7TVProviderEnabledPrefix = @"s7tv_emote_provider_enabled_";
static NSString *const kS7TVProviderPriority = @"s7tv_emote_provider_priority";
static NSString *const kS7TVZeroWidthEnabled = @"s7tv_emote_zero_width_enabled";
static NSString *const kS7TVMixedPickerEnabled = @"s7tv_emote_picker_mixed_providers_enabled";
static NSString *const kS7TVPickerOpeningMode = @"s7tv_emote_picker_opening_mode";
static NSString *const kS7TVPickerLastLocation = @"s7tv_emote_picker_last_location";
static NSString *const kS7TVProviderSettingsMigrated = @"s7tv_emote_provider_settings_v1_migrated";

NSString *S7TVEmoteProviderIdentifier(S7TVExternalEmoteProvider provider) {
    switch (provider) {
        case S7TVExternalEmoteProviderBTTV: return @"bttv";
        case S7TVExternalEmoteProviderFFZ: return @"ffz";
        case S7TVExternalEmoteProvider7TV:
        default: return @"7tv";
    }
}

S7TVExternalEmoteProvider S7TVEmoteProviderFromIdentifier(NSString *identifier) {
    NSString *value = [identifier.lowercaseString stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value isEqualToString:@"bttv"] || [value isEqualToString:@"betterttv"])
        return S7TVExternalEmoteProviderBTTV;
    if ([value isEqualToString:@"ffz"] || [value isEqualToString:@"frankerfacez"])
        return S7TVExternalEmoteProviderFFZ;
    return S7TVExternalEmoteProvider7TV;
}

static NSUserDefaults *S7TVProviderDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

@implementation S7TVEmoteProviderSettings

+ (BOOL)isProviderEnabled:(S7TVExternalEmoteProvider)provider {
    [self migrateLegacySettings];
    NSString *key = [kS7TVProviderEnabledPrefix stringByAppendingString:
        S7TVEmoteProviderIdentifier(provider)];
    NSUserDefaults *defaults = S7TVProviderDefaults();
    return [defaults objectForKey:key] == nil ? YES : [defaults boolForKey:key];
}

+ (void)setProvider:(S7TVExternalEmoteProvider)provider enabled:(BOOL)enabled {
    NSString *key = [kS7TVProviderEnabledPrefix stringByAppendingString:
        S7TVEmoteProviderIdentifier(provider)];
    [S7TVProviderDefaults() setBool:enabled forKey:key];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSArray<NSString *> *)providerPriority {
    [self migrateLegacySettings];
    id rawSaved = [S7TVProviderDefaults() objectForKey:kS7TVProviderPriority];
    NSArray *saved = [rawSaved isKindOfClass:[NSArray class]] ? rawSaved : @[];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:3];
    for (id item in saved) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *identifier = S7TVEmoteProviderIdentifier(
            S7TVEmoteProviderFromIdentifier(item));
        if (![result containsObject:identifier]) [result addObject:identifier];
    }
    for (S7TVExternalEmoteProvider provider = S7TVExternalEmoteProvider7TV;
         provider <= S7TVExternalEmoteProviderFFZ; provider++) {
        NSString *identifier = S7TVEmoteProviderIdentifier(provider);
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
        NSString *identifier = S7TVEmoteProviderIdentifier(
            S7TVEmoteProviderFromIdentifier(item));
        if (![sanitized containsObject:identifier]) [sanitized addObject:identifier];
    }
    for (S7TVExternalEmoteProvider provider = S7TVExternalEmoteProvider7TV;
         provider <= S7TVExternalEmoteProviderFFZ; provider++) {
        NSString *identifier = S7TVEmoteProviderIdentifier(provider);
        if (![sanitized containsObject:identifier]) [sanitized addObject:identifier];
    }
    [S7TVProviderDefaults() setObject:sanitized forKey:kS7TVProviderPriority];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
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
    [S7TVProviderDefaults() setBool:YES forKey:kS7TVZeroWidthEnabled];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (BOOL)mixedPickerEnabled {
    NSUserDefaults *defaults = S7TVProviderDefaults();
    // Keep the existing three-provider picker as the default for upgrades and
    // fresh installs. The user explicitly opts in to the aggregate tab.
    return [defaults objectForKey:kS7TVMixedPickerEnabled] == nil
        ? NO : [defaults boolForKey:kS7TVMixedPickerEnabled];
}

+ (void)setMixedPickerEnabled:(BOOL)enabled {
    [S7TVProviderDefaults() setBool:enabled forKey:kS7TVMixedPickerEnabled];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSString *)pickerOpeningMode {
    [self migrateLegacySettings];
    NSString *mode = [S7TVProviderDefaults() stringForKey:kS7TVPickerOpeningMode];
    NSArray<NSString *> *validModes = @[
        S7TVEmotePickerOpeningModeFavorites,
        S7TVEmotePickerOpeningModeSevenTVChannel,
        S7TVEmotePickerOpeningModeBTTVChannel,
        S7TVEmotePickerOpeningModeFFZChannel,
        S7TVEmotePickerOpeningModeLastUsed,
    ];
    return [validModes containsObject:mode]
        ? mode : S7TVEmotePickerOpeningModeFavorites;
}

+ (void)setPickerOpeningMode:(NSString *)mode {
    NSArray<NSString *> *validModes = @[
        S7TVEmotePickerOpeningModeFavorites,
        S7TVEmotePickerOpeningModeSevenTVChannel,
        S7TVEmotePickerOpeningModeBTTVChannel,
        S7TVEmotePickerOpeningModeFFZChannel,
        S7TVEmotePickerOpeningModeLastUsed,
    ];
    if (![validModes containsObject:mode]) return;
    [S7TVProviderDefaults() setObject:mode forKey:kS7TVPickerOpeningMode];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
}

+ (NSString *)lastPickerLocation {
    NSString *location = [S7TVProviderDefaults() stringForKey:kS7TVPickerLastLocation];
    return location.length <= 256 ? location : nil;
}

+ (void)setLastPickerLocation:(NSString *)location {
    if (!location.length || location.length > 256) return;
    [S7TVProviderDefaults() setObject:location forKey:kS7TVPickerLastLocation];
}

+ (void)migrateLegacySettings {
    NSUserDefaults *defaults = S7TVProviderDefaults();
    BOOL alreadyMigrated = [defaults boolForKey:kS7TVProviderSettingsMigrated];

    // Les anciennes versions n'avaient qu'un interrupteur 7TV exposé par le
    // manager. Si sa clé historique existe, la reporter sans modifier le
    // comportement des installations neuves. Cette vérification reste
    // volontairement active après la migration : un utilisateur peut importer
    // à tout moment un ancien export qui ne contient pas encore la clé v2.
    if ([defaults objectForKey:@"s7tv_enabled"] != nil &&
        [defaults objectForKey:@"s7tv_emote_provider_enabled_7tv"] == nil) {
        [defaults setBool:[defaults boolForKey:@"s7tv_enabled"]
                   forKey:@"s7tv_emote_provider_enabled_7tv"];
    }

    // A short-lived development build stored the three switches in one
    // dictionary. Promote any missing provider keys on every call as well, so
    // importing that export after the one-time marker was written still
    // preserves a disabled BTTV/FFZ choice.
    NSDictionary *aggregate = [defaults dictionaryForKey:@"s7tv_emote_provider_enabled"];
    if ([aggregate isKindOfClass:NSDictionary.class]) {
        for (S7TVExternalEmoteProvider provider = S7TVExternalEmoteProvider7TV;
             provider <= S7TVExternalEmoteProviderFFZ; provider++) {
            NSString *key = [kS7TVProviderEnabledPrefix stringByAppendingString:
                S7TVEmoteProviderIdentifier(provider)];
            if ([defaults objectForKey:key] != nil) continue;
            id value = aggregate[S7TVEmoteProviderIdentifier(provider)];
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
    if (![defaults boolForKey:kS7TVZeroWidthEnabled])
        [defaults setBool:YES forKey:kS7TVZeroWidthEnabled];

    // Le comportement d'une installation neuve reste déterministe : le
    // picker commence dans Favoris tant que l'utilisateur n'a pas choisi un
    // autre emplacement. Les builds précédents pouvaient laisser la clé
    // absente, ce qui forçait alors la sélection implicite du premier provider.
    if (![defaults objectForKey:kS7TVPickerOpeningMode])
        [defaults setObject:S7TVEmotePickerOpeningModeFavorites
                     forKey:kS7TVPickerOpeningMode];

    // Le reste de la migration n'a besoin d'être exécuté qu'une fois. Les
    // préférences v2 déjà présentes doivent toujours rester prioritaires sur
    // une ancienne représentation éventuellement encore conservée dans les
    // defaults.
    if (alreadyMigrated) return;

    if ([defaults objectForKey:kS7TVProviderPriority] == nil)
        [defaults setObject:@[@"7tv", @"bttv", @"ffz"] forKey:kS7TVProviderPriority];
    [defaults setBool:YES forKey:kS7TVProviderSettingsMigrated];
}

@end
