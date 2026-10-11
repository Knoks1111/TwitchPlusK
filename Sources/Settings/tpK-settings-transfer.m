#import "Settings/tpK-settings-transfer.h"

NSString *const TPKSettingsTransferErrorDomain = @"TwitchPlusK.SettingsTransfer";

static NSString *const TPKSettingsTransferMarkerKey = @"twitchplusk_settings";
static NSString *const TPKSettingsTransferValuesKey = @"values";
static NSString *const TPKLegacyChannelPointsKey = @"TCDBGLiveAutoCollectChannelPoints";

static BOOL TPKSettingsTransferIsRemovedLogKey(NSString *key) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"tpk_log_swizzle", @"tpk_log_cache", @"tpk_log_prefetch",
            @"tpk_log_api", @"tpk_log_irc_channel", @"tpk_log_ui_picker",
            @"tpk_log_favorites", @"tpk_log_orientation",
            @"tpk_log_image_conv", @"tpk_log_dump",
            @"s7tv_log_swizzle", @"s7tv_log_cache", @"s7tv_log_prefetch",
            @"s7tv_log_api", @"s7tv_log_irc_channel", @"s7tv_log_ui_picker",
            @"s7tv_log_favorites", @"s7tv_log_orientation",
            @"s7tv_log_image_conv", @"s7tv_log_dump",
        ]];
    });
    return [keys containsObject:key];
}

static NSArray<NSString *> *TPKSettingsTransferInternalPrefixes(void) {
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[
            @"tpk_cache_", @"tpk_cached_", @"tpk_channel_id_",
            @"tpk_runtime_",
            @"s7tv_cache_", @"s7tv_cached_", @"s7tv_channel_id_",
            @"s7tv_runtime_",
        ];
    });
    return prefixes;
}

static BOOL TPKSettingsTransferIsInternalKey(NSString *key) {
    for (NSString *prefix in TPKSettingsTransferInternalPrefixes()) {
        if ([key hasPrefix:prefix]) return YES;
    }
    return NO;
}

static BOOL TPKSettingsTransferOwnsKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    // Accepter les anciennes clés uniquement pour les imports historiques.
    if (TPKSettingsTransferIsRemovedLogKey(key)) return YES;
    if ([key isEqualToString:TPKLegacyChannelPointsKey]) return YES;
    // Clé originale du moteur TASDiagnostics (VAFT) : conservée telle quelle
    // pour la provenance upstream, incluse dans l'export/import.
    if ([key isEqualToString:@"TASDiagnosticsEnabled"]) return YES;
    // Historique (backups) + courant.
    if ([key hasPrefix:@"s7tv_"] || [key hasPrefix:@"tpk_"]) {
        return !TPKSettingsTransferIsInternalKey(key);
    }
    return NO;
}

static NSError *TPKSettingsTransferError(TPKSettingsTransferErrorCode code,
                                          NSString *description) {
    return [NSError errorWithDomain:TPKSettingsTransferErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSDictionary<NSString *, id> *TPKSettingsTransferValues(void) {
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary<NSString *, id> *defaults = [userDefaults dictionaryRepresentation];
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (!TPKSettingsTransferIsRemovedLogKey(key) &&
            TPKSettingsTransferOwnsKey(key) &&
            [NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            values[key] = value;
        }
    }];

    // La récupération automatique des points est l'unique préférence
    // historique sans préfixe tpk_. Son défaut effectif est ON, mais cette
    // valeur n'est pas écrite tant que l'utilisateur n'a jamais touché le
    // switch. La sérialiser explicitement évite qu'un import conserve un
    // ancien OFF sur l'autre appareil.
    if (!values[TPKLegacyChannelPointsKey]) {
        BOOL autoClaim = [defaults objectForKey:TPKLegacyChannelPointsKey] != nil
            ? [userDefaults boolForKey:TPKLegacyChannelPointsKey] : YES;
        values[TPKLegacyChannelPointsKey] = @(autoClaim);
    }
    return values.copy;
}

NSData *TPKSettingsExportData(NSError **error) {
    NSDictionary *archive = @{
        TPKSettingsTransferMarkerKey: @1,
        @"format_version": @1,
        TPKSettingsTransferValuesKey: TPKSettingsTransferValues(),
    };
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:archive
                                                                format:NSPropertyListXMLFormat_v1_0
                                                               options:0
                                                                 error:&serializationError];
    if (!data && error) {
        *error = serializationError ?: TPKSettingsTransferError(
            TPKSettingsTransferErrorSerialization,
            @"Unable to create settings archive.");
    }
    return data;
}

NSString *TPKSettingsExportFileName(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"TwitchPlusK-Settings-%@.plist",
            [formatter stringFromDate:[NSDate date]]];
}

NSUInteger TPKSettingsImportData(NSData *data, NSError **error) {
    if (!data.length) {
        if (error) *error = TPKSettingsTransferError(
            TPKSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }
    NSError *parseError = nil;
    id archive = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:nil
                                                               error:&parseError];
    if (![archive isKindOfClass:NSDictionary.class]) {
        if (error) *error = parseError ?: TPKSettingsTransferError(
            TPKSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }
    NSDictionary *dictionary = archive;
    id marker = dictionary[TPKSettingsTransferMarkerKey];
    if (![marker isKindOfClass:NSNumber.class] || ![marker boolValue] ||
        ![dictionary[TPKSettingsTransferValuesKey] isKindOfClass:NSDictionary.class]) {
        if (error) *error = TPKSettingsTransferError(
            TPKSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }

    NSDictionary<NSString *, id> *values = dictionary[TPKSettingsTransferValuesKey];
    for (NSString *key in values) {
        id value = values[key];
        if (!TPKSettingsTransferOwnsKey(key) ||
            ![NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            if (error) *error = TPKSettingsTransferError(
                TPKSettingsTransferErrorInvalidValue,
                @"The settings file contains an invalid value.");
            return NSNotFound;
        }
    }

    // Backups s7tv_ traduits en tpk_ (tpk_ gagne si doublon).
    NSMutableDictionary<NSString *, id> *translated = [NSMutableDictionary dictionary];
    for (NSString *key in values) {
        id value = values[key];
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"s7tv_"]) {
            NSString *newKey = [@"tpk_" stringByAppendingString:
                                [key substringFromIndex:5]];
            if (translated[newKey] == nil) translated[newKey] = value;
        } else {
            if (translated[key] == nil) translated[key] = value;
        }
    }

    // Older exports predate the provider-aware switches and only contain the
    // legacy `tpk_enabled` flag (or a short-lived aggregate dictionary).
    // Materialize those values in the imported payload itself, rather than
    // relying on the one-time startup migration: the destination may already
    // have v2 keys, and an explicit import must still carry the old user's
    // choice to that installation.  A v2 value present in the archive always
    // wins over its legacy counterpart.
    NSMutableDictionary<NSString *, id> *valuesToImport = [translated mutableCopy];
    if (valuesToImport[@"tpk_enabled"] != nil &&
        valuesToImport[@"tpk_emote_provider_enabled_7tv"] == nil) {
        id value = valuesToImport[@"tpk_enabled"];
        if ([value respondsToSelector:@selector(boolValue)])
            valuesToImport[@"tpk_emote_provider_enabled_7tv"] = @([value boolValue]);
    }
    NSDictionary *aggregate = [valuesToImport[@"tpk_emote_provider_enabled"]
        isKindOfClass:NSDictionary.class] ? valuesToImport[@"tpk_emote_provider_enabled"] : nil;
    if (aggregate) {
        NSDictionary<NSString *, NSString *> *providerKeys = @{
            @"7tv": @"tpk_emote_provider_enabled_7tv",
            @"bttv": @"tpk_emote_provider_enabled_bttv",
            @"ffz": @"tpk_emote_provider_enabled_ffz",
        };
        [providerKeys enumerateKeysAndObjectsUsingBlock:
            ^(NSString *identifier, NSString *key, BOOL *stop) {
            if (valuesToImport[key] != nil) return;
            id value = aggregate[identifier] ?: aggregate[[NSString stringWithFormat:@"%lu",
                (unsigned long)([identifier isEqualToString:@"7tv"] ? 0 :
                    ([identifier isEqualToString:@"bttv"] ? 1 : 2))]];
            if ([value respondsToSelector:@selector(boolValue)])
                valuesToImport[key] = @([value boolValue]);
        }];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUInteger importedCount = 0;
    for (NSString *key in valuesToImport) {
        if (TPKSettingsTransferIsRemovedLogKey(key)) continue;
        [defaults setObject:valuesToImport[key] forKey:key];
        importedCount++;
    }
    [defaults synchronize];
    return importedCount;
}
