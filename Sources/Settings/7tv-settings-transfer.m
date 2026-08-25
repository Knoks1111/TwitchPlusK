#import "Settings/7tv-settings-transfer.h"

NSString *const S7TVSettingsTransferErrorDomain = @"TwitchPlusK.SettingsTransfer";

static NSString *const S7TVSettingsTransferMarkerKey = @"twitchplusk_settings";
static NSString *const S7TVSettingsTransferValuesKey = @"values";
static NSString *const S7TVLegacyChannelPointsKey = @"TCDBGLiveAutoCollectChannelPoints";

static NSArray<NSString *> *S7TVSettingsTransferInternalPrefixes(void) {
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[
            @"s7tv_cache_", @"s7tv_cached_", @"s7tv_channel_id_",
            @"s7tv_runtime_",
        ];
    });
    return prefixes;
}

static BOOL S7TVSettingsTransferIsInternalKey(NSString *key) {
    for (NSString *prefix in S7TVSettingsTransferInternalPrefixes()) {
        if ([key hasPrefix:prefix]) return YES;
    }
    return NO;
}

static BOOL S7TVSettingsTransferOwnsKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    if ([key isEqualToString:S7TVLegacyChannelPointsKey]) return YES;
    return [key hasPrefix:@"s7tv_"] && !S7TVSettingsTransferIsInternalKey(key);
}

static NSError *S7TVSettingsTransferError(S7TVSettingsTransferErrorCode code,
                                          NSString *description) {
    return [NSError errorWithDomain:S7TVSettingsTransferErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSDictionary<NSString *, id> *S7TVSettingsTransferValues(void) {
    NSDictionary<NSString *, id> *defaults =
        [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (S7TVSettingsTransferOwnsKey(key) &&
            [NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            values[key] = value;
        }
    }];
    return values.copy;
}

NSData *S7TVSettingsExportData(NSError **error) {
    NSDictionary *archive = @{
        S7TVSettingsTransferMarkerKey: @1,
        @"format_version": @1,
        S7TVSettingsTransferValuesKey: S7TVSettingsTransferValues(),
    };
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:archive
                                                                format:NSPropertyListXMLFormat_v1_0
                                                               options:0
                                                                 error:&serializationError];
    if (!data && error) {
        *error = serializationError ?: S7TVSettingsTransferError(
            S7TVSettingsTransferErrorSerialization,
            @"Unable to create settings archive.");
    }
    return data;
}

NSString *S7TVSettingsExportFileName(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"TwitchPlusK-Settings-%@.plist",
            [formatter stringFromDate:[NSDate date]]];
}

NSUInteger S7TVSettingsImportData(NSData *data, NSError **error) {
    if (!data.length) {
        if (error) *error = S7TVSettingsTransferError(
            S7TVSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }
    NSError *parseError = nil;
    id archive = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:nil
                                                               error:&parseError];
    if (![archive isKindOfClass:NSDictionary.class]) {
        if (error) *error = parseError ?: S7TVSettingsTransferError(
            S7TVSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }
    NSDictionary *dictionary = archive;
    id marker = dictionary[S7TVSettingsTransferMarkerKey];
    if (![marker isKindOfClass:NSNumber.class] || ![marker boolValue] ||
        ![dictionary[S7TVSettingsTransferValuesKey] isKindOfClass:NSDictionary.class]) {
        if (error) *error = S7TVSettingsTransferError(
            S7TVSettingsTransferErrorInvalidArchive,
            @"This is not a TwitchPlusK settings file.");
        return NSNotFound;
    }

    NSDictionary<NSString *, id> *values = dictionary[S7TVSettingsTransferValuesKey];
    for (NSString *key in values) {
        id value = values[key];
        if (!S7TVSettingsTransferOwnsKey(key) ||
            ![NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            if (error) *error = S7TVSettingsTransferError(
                S7TVSettingsTransferErrorInvalidValue,
                @"The settings file contains an invalid value.");
            return NSNotFound;
        }
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUInteger importedCount = 0;
    for (NSString *key in values) {
        [defaults setObject:values[key] forKey:key];
        importedCount++;
    }
    [defaults synchronize];
    return importedCount;
}
