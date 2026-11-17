#import "Emote/tpK-emote-catalog.h"
#import "Picker/tpK-picker-settings.h"
#import "Adblock/Emote/tpK-adblock-emote-proxy.h"
#import <math.h>
#import <stdlib.h>

NSString *const TPKProviderCatalogDidUpdateNotification =
    @"TPKProviderCatalogDidUpdateNotification";

static NSString *const kTPKFavoriteMetadataKey =
    @"tpk_emote_favorite_metadata_v1";
static NSString *const kTPKFavoriteCompositionsKey =
    @"tpk_emote_favorite_compositions_v1";

TPKEmoteProviderID TPKEmoteProviderFromIdentifier(NSString * _Null_unspecified identifier) {
    NSString *value = [identifier.lowercaseString stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value isEqualToString:@"bttv"] || [value isEqualToString:@"betterttv"])
        return TPKEmoteProviderIDBTTV;
    if ([value isEqualToString:@"ffz"] || [value isEqualToString:@"frankerfacez"])
        return TPKEmoteProviderIDFFZ;
    return TPKEmoteProviderIDTPK;
}

static void TPKSevenTVAddImage(NSMutableDictionary *formats, NSString *url, NSInteger scale) {
    if (!url.length || scale <= 0) return;
    NSString *extension = [NSURL URLWithString:url].pathExtension.lowercaseString;
    if (!extension.length || ![@[@"gif", @"webp", @"png"] containsObject:extension]) return;
    NSMutableDictionary *variants = formats[extension];
    if (!variants) formats[extension] = variants = [NSMutableDictionary dictionary];
    variants[@(scale)] = url;
}

NSString *TPKEmoteProviderName(TPKEmoteProviderID provider) {
    switch (provider) {
        case TPKEmoteProviderIDTPK: return @"7TV";
        case TPKEmoteProviderIDBTTV: return @"BTTV";
        case TPKEmoteProviderIDFFZ: return @"FFZ";
    }
    return @"Unknown";
}

NSString *TPKEmoteProviderKey(TPKEmoteProviderID provider) {
    switch (provider) {
        case TPKEmoteProviderIDTPK: return @"7tv";
        case TPKEmoteProviderIDBTTV: return @"bttv";
        case TPKEmoteProviderIDFFZ: return @"ffz";
    }
    return @"unknown";
}

NSString *TPKEmoteFavoriteKey(TPKEmoteProviderID provider, NSString *emoteID) {
    if (!emoteID.length) return @"";
    return [NSString stringWithFormat:@"%@:%@", TPKEmoteProviderKey(provider), emoteID];
}

// Validate imported values before favorite-key parsing reaches the UI.
static NSString *TPKCanonicalFavoriteKey(id value) {
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) return nil;
    NSString *raw = (NSString *)value;
    NSRange separator = [raw rangeOfString:@":" options:0 range:NSMakeRange(0, raw.length)];
    if (separator.location == NSNotFound) {
        // Accept bare IDs for legacy 7TV imports.
        return TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, raw);
    }
    if (separator.location == 0 || separator.location == raw.length - 1) return nil;
    NSString *provider = [[raw substringToIndex:separator.location] lowercaseString];
    if (![provider isEqualToString:@"7tv"] &&
        ![provider isEqualToString:@"bttv"] &&
        ![provider isEqualToString:@"ffz"]) return nil;
    NSString *emoteID = [raw substringFromIndex:separator.location + 1];
    return emoteID.length ? [NSString stringWithFormat:@"%@:%@", provider, emoteID] : nil;
}

static NSString *TPKString(id value);
static NSInteger TPKInteger(id value);
static CGFloat TPKDouble(id value);
static BOOL TPKBool(id value);
static NSArray<NSString *> *TPKAliases(id value);
static NSDictionary<NSNumber *, NSString *> *TPKURLMap(id value);

// Scope-qualified section IDs let lazy loads target the correct endpoint.
static NSString *TPKSetSectionIdentifier(NSString *setID, BOOL global) {
    if (!setID.length) return @"";
    return [NSString stringWithFormat:@"%@:%@", global ? @"global-set" : @"set", setID];
}

static NSString *TPKSetIDFromSectionIdentifier(NSString *identifier, BOOL *globalOut) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSString *prefix = nil;
    BOOL global = NO;
    if ([identifier hasPrefix:@"global-set:"]) {
        prefix = @"global-set:";
        global = YES;
    } else if ([identifier hasPrefix:@"set:"]) {
        prefix = @"set:";
    } else {
        return nil;
    }
    NSString *setID = [identifier substringFromIndex:prefix.length];
    if (!setID.length) return nil;
    if (globalOut) *globalOut = global;
    return setID;
}

static BOOL TPKParseFavoriteKey(NSString *key,
                                 TPKEmoteProviderID *providerOut,
                                 NSString **emoteIDOut) {
    NSString *canonical = TPKCanonicalFavoriteKey(key);
    if (!canonical.length) return NO;
    NSRange separator = [canonical rangeOfString:@":" options:0
                                             range:NSMakeRange(0, canonical.length)];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location == canonical.length - 1) return NO;
    NSString *providerKey = [canonical substringToIndex:separator.location];
    TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
    if ([providerKey isEqualToString:@"bttv"]) provider = TPKEmoteProviderIDBTTV;
    else if ([providerKey isEqualToString:@"ffz"]) provider = TPKEmoteProviderIDFFZ;
    else if (![providerKey isEqualToString:@"7tv"]) return NO;
    if (providerOut) *providerOut = provider;
    if (emoteIDOut) *emoteIDOut = [canonical substringFromIndex:separator.location + 1];
    return YES;
}

static NSDictionary *TPKFavoriteMetadataForDescriptor(TPKEmoteDescriptor *descriptor) {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"provider"] = @(descriptor.provider);
    metadata[@"providerIdentifier"] = descriptor.providerIdentifier ?: TPKEmoteProviderKey(descriptor.provider);
    metadata[@"id"] = descriptor.emoteID;
    metadata[@"name"] = descriptor.name;
    metadata[@"aliases"] = descriptor.aliases ?: @[];
    metadata[@"sectionKind"] = @(descriptor.sectionKind);
    metadata[@"sectionIdentifier"] = descriptor.sectionIdentifier ?: @"";
    metadata[@"sectionTitle"] = descriptor.sectionTitle ?: @"";
    if (descriptor.setID.length) metadata[@"setID"] = descriptor.setID;
    metadata[@"width"] = @(MAX(1.0, descriptor.nativeSize.width));
    metadata[@"height"] = @(MAX(1.0, descriptor.nativeSize.height));
    metadata[@"animated"] = @(descriptor.animated);
    metadata[@"zeroWidth"] = @(descriptor.zeroWidth);

    // Convert scale keys to strings for property-list storage.
    NSMutableDictionary *urls = [NSMutableDictionary dictionary];
    [descriptor.imageURLs enumerateKeysAndObjectsUsingBlock:^(NSNumber *scale, NSString *url, BOOL *stop) {
        if ([scale respondsToSelector:@selector(integerValue)] && url.length)
            urls[[scale stringValue]] = url;
    }];
    metadata[@"imageURLs"] = urls.copy;
    // Keep property-list-safe modifier metadata for the v2 effects UI.
    if (descriptor.modifierMetadata.count &&
        [NSPropertyListSerialization propertyList:descriptor.modifierMetadata
                               isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        metadata[@"modifierMetadata"] = descriptor.modifierMetadata;
    }
    return metadata.copy;
}

static BOOL TPKFavoriteCompositionContainsKey(id value, NSString *emoteKey) {
    if (!emoteKey.length || ![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *composition = (NSDictionary *)value;
    NSArray *memberKeys = [composition[@"keys"] isKindOfClass:NSArray.class]
        ? composition[@"keys"] : @[];
    for (id member in memberKeys) {
        if ([member isKindOfClass:NSString.class] &&
            [member isEqualToString:emoteKey]) return YES;
    }
    return [composition[@"baseKey"] isKindOfClass:NSString.class] &&
        [composition[@"baseKey"] isEqualToString:emoteKey];
}

static void TPKRemoveFavoriteCompositionsContainingKey(
    NSMutableDictionary<NSString *, NSDictionary *> *compositions,
    NSString *emoteKey) {
    if (!compositions || !emoteKey.length) return;
    for (NSString *baseKey in compositions.allKeys.copy) {
        if (TPKFavoriteCompositionContainsKey(compositions[baseKey], emoteKey))
            [compositions removeObjectForKey:baseKey];
    }
}

static NSMutableDictionary<NSString *, NSDictionary *> *TPKMutableFavoriteCompositions(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kTPKFavoriteCompositionsKey];
    return [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void TPKStoreFavoriteCompositions(
    NSMutableDictionary<NSString *, NSDictionary *> *compositions) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (compositions.count) [defaults setObject:compositions.copy
                                         forKey:kTPKFavoriteCompositionsKey];
    else [defaults removeObjectForKey:kTPKFavoriteCompositionsKey];
}

static TPKEmoteDescriptor *TPKDescriptorFromFavoriteMetadata(NSString *favoriteKey,
                                                               NSDictionary *metadata) {
    TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
    NSString *emoteID = nil;
    if (!TPKParseFavoriteKey(favoriteKey, &provider, &emoteID) || !metadata.count)
        return nil;
    NSString *metadataID = TPKString(metadata[@"id"]);
    if (metadataID.length && ![metadataID isEqualToString:emoteID]) return nil;
    NSString *name = TPKString(metadata[@"name"]);
    if (!name.length) return nil;
    NSInteger kindValue = TPKInteger(metadata[@"sectionKind"]);
    if (kindValue < TPKEmoteSectionKindChannel || kindValue > TPKEmoteSectionKindFavorites)
        kindValue = TPKEmoteSectionKindSet;
    NSDictionary *rawURLs = [metadata[@"imageURLs"] isKindOfClass:NSDictionary.class]
        ? metadata[@"imageURLs"] : @{};
    NSDictionary<NSNumber *, NSString *> *urls = TPKURLMap(rawURLs);
    NSString *sectionIdentifier = TPKString(metadata[@"sectionIdentifier"]);
    NSString *sectionTitle = TPKString(metadata[@"sectionTitle"]);
    NSString *providerIdentifier = TPKString(metadata[@"providerIdentifier"]);
    NSDictionary *modifiers = [metadata[@"modifierMetadata"] isKindOfClass:NSDictionary.class]
        ? metadata[@"modifierMetadata"] : @{};
    CGSize size = CGSizeMake(MAX(1, TPKInteger(metadata[@"width"])),
                             MAX(1, TPKInteger(metadata[@"height"])));
    return [[TPKEmoteDescriptor alloc]
        initWithProvider:provider
        providerIdentifier:providerIdentifier ?: TPKEmoteProviderKey(provider)
        emoteID:emoteID name:name aliases:TPKAliases(metadata[@"aliases"])
        sectionKind:(TPKEmoteSectionKind)kindValue
        sectionIdentifier:sectionIdentifier ?: @"favorites"
        sectionTitle:sectionTitle ?: @"Favorites"
        setID:TPKString(metadata[@"setID"])
        nativeSize:size animated:TPKBool(metadata[@"animated"])
        zeroWidth:TPKBool(metadata[@"zeroWidth"])
        modifierMetadata:modifiers imageURLs:urls];
}

static NSString *TPKString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSInteger TPKInteger(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static CGFloat TPKDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 0.0;
}

static BOOL TPKBool(id value) {
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSArray<NSString *> *TPKAliases(id value) {
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value length] ? @[value] : @[];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *alias = TPKString(item);
        if (!alias.length && [item isKindOfClass:NSDictionary.class]) {
            NSDictionary *dictionary = item;
            alias = TPKString(dictionary[@"name"]) ?: TPKString(dictionary[@"alias"]);
            if (!alias.length) alias = TPKString(dictionary[@"code"]);
        }
        if (alias.length) [result addObject:alias];
    }
    return result.copy;
}

static NSDictionary<NSNumber *, NSString *> *TPKURLMap(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *url = TPKString(obj);
        NSInteger scale = TPKInteger(key);
        if (url.length && scale > 0) {
            if ([url hasPrefix:@"//"]) url = [@"https:" stringByAppendingString:url];
            else if ([url hasPrefix:@"/"]) url = [@"https://cdn.frankerfacez.com" stringByAppendingString:url];
            result[@(scale)] = url;
        }
    }];
    return result.copy;
}

// Accept REST arrays and GraphQL-style emote wrappers.
static NSArray *TPKEmoteEntriesFromSet(NSDictionary *set) {
    if (![set isKindOfClass:NSDictionary.class]) return @[];
    id collection = set[@"emotes"] ?: set[@"emoticons"];
    if ([collection isKindOfClass:NSArray.class]) return collection;
    if (![collection isKindOfClass:NSDictionary.class]) return @[];

    NSDictionary *wrapped = (NSDictionary *)collection;
    for (NSString *key in @[@"items", @"data", @"results", @"emotes", @"emoticons"]) {
        id candidate = wrapped[key];
        if ([candidate isKindOfClass:NSArray.class]) return candidate;
        if ([candidate isKindOfClass:NSDictionary.class]) {
            NSArray *nested = TPKEmoteEntriesFromSet(candidate);
            if (nested.count) return nested;
        }
    }
    // Accept maps keyed by emote ID; ignore scalar metadata.
    NSMutableArray *mappedEntries = [NSMutableArray array];
    for (id value in wrapped.allValues) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry = (NSDictionary *)value;
        if (entry[@"id"] || entry[@"name"] || entry[@"code"] ||
            entry[@"emote"] || entry[@"data"])
            [mappedEntries addObject:entry];
    }
    if (mappedEntries.count) return mappedEntries;
    return @[];
}

static BOOL TPKDictionaryHasDirectEmoteCollection(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return NO;
    id collection = dictionary[@"emotes"] ?: dictionary[@"emoticons"];
    return [collection isKindOfClass:NSArray.class] ||
        [collection isKindOfClass:NSDictionary.class];
}

// Migrate the legacy TPKManager cache to the provider cache on ioQueue.

static BOOL TPKSetHasEmotePayload(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        id collection = dictionary[@"emotes"] ?: dictionary[@"emoticons"];
        // An empty collection is valid and differs from a missing payload.
        if ([collection isKindOfClass:NSArray.class] ||
            [collection isKindOfClass:NSDictionary.class]) return YES;
        for (id nested in dictionary.allValues) {
            if (TPKSetHasEmotePayload(nested)) return YES;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id nested in (NSArray *)value) {
            if (TPKSetHasEmotePayload(nested)) return YES;
        }
    }
    return NO;
}

static BOOL TPKJSONObjectIsValid(NSData *data, NSURLResponse *response, NSError **outError) {
    if (!data.length) {
        if (outError) *outError = [NSError errorWithDomain:@"TPKEmoteCatalog"
                                                       code:1
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Empty response"}];
        return NO;
    }
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status >= 300) {
            if (outError) *outError = [NSError errorWithDomain:@"TPKEmoteCatalog"
                                                           code:status
                                                       userInfo:@{NSLocalizedDescriptionKey:
                                                                      [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
            return NO;
        }
    }
    return YES;
}

static void TPKSetCatalogStructureError(NSError **error,
                                         TPKEmoteProviderID provider) {
    if (!error) return;
    *error = [NSError errorWithDomain:@"TPKEmoteCatalog"
                                 code:2
                             userInfo:@{
        NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ returned an unexpected response",
             TPKEmoteProviderName(provider)]
    }];
}

static void TPKCollectSetIDsFromObject(id value,
                                        NSMutableOrderedSet<NSString *> *setIDs) {
    if (!setIDs || !value) return;
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value)
            TPKCollectSetIDsFromObject(item, setIDs);
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dictionary = (NSDictionary *)value;

    // Handle a direct set object before interpreting dictionary keys as set IDs.
    if (TPKDictionaryHasDirectEmoteCollection(dictionary)) {
        NSString *identifier = TPKString(dictionary[@"id"]) ?:
            TPKString(dictionary[@"emote_set_id"]);
        if (identifier.length) [setIDs addObject:identifier];
    }

    // Accept known v3 active-set fields and cached variants.
    for (NSString *key in @[@"emote_set_id", @"emoteSetId", @"set_id", @"setId"]) {
        id candidate = dictionary[key];
        if ([candidate isKindOfClass:NSString.class] && [candidate length])
            [setIDs addObject:candidate];
    }
    for (NSString *activeKey in @[@"emote_set", @"emoteSet", @"set"]) {
        id activeSet = dictionary[activeKey];
        if ([activeSet isKindOfClass:NSString.class] && [activeSet length]) {
            [setIDs addObject:activeSet];
        } else if ([activeSet isKindOfClass:NSDictionary.class]) {
            NSString *identifier = TPKString(activeSet[@"id"]) ?:
                TPKString(activeSet[@"emote_set_id"]) ?:
                TPKString(activeSet[@"emoteSetId"]);
            if (identifier.length) [setIDs addObject:identifier];
        }
    }

    for (NSString *containerKey in @[@"emote_sets", @"sets"]) {
        id container = dictionary[containerKey];
        if ([container isKindOfClass:NSDictionary.class]) {
            // `sets` may be one set object rather than a map of sets.
            NSDictionary *directSet = (NSDictionary *)container;
            if (TPKDictionaryHasDirectEmoteCollection(directSet)) {
                NSString *identifier = TPKString(directSet[@"id"]) ?:
                    TPKString(directSet[@"emote_set_id"]);
                if (identifier.length) [setIDs addObject:identifier];
                continue;
            }
            // Metadata-only set objects still provide a valid set ID.
            if (TPKString(directSet[@"id"]).length &&
                TPKString(directSet[@"name"]).length) {
                [setIDs addObject:TPKString(directSet[@"id"])];
                continue;
            }
            [(NSDictionary *)container enumerateKeysAndObjectsUsingBlock:
                ^(id key, id object, BOOL *stop) {
                if ([object isKindOfClass:NSDictionary.class]) {
                    NSString *identifier = TPKString(object[@"id"]) ?: TPKString(key);
                    if (identifier.length) [setIDs addObject:identifier];
                    // A nested emote_set can carry the actual active set.
                    TPKCollectSetIDsFromObject(object, setIDs);
                } else if ([key isKindOfClass:NSString.class] && [key length]) {
                    [setIDs addObject:key];
                } else if ([object isKindOfClass:NSString.class] && [object length]) {
                    [setIDs addObject:object];
                }
            }];
        } else if ([container isKindOfClass:NSArray.class]) {
            for (id object in (NSArray *)container) {
                if ([object isKindOfClass:NSDictionary.class]) {
                    NSString *identifier = TPKString(object[@"id"]);
                    if (identifier.length) [setIDs addObject:identifier];
                    TPKCollectSetIDsFromObject(object, setIDs);
                } else if ([object isKindOfClass:NSString.class] && [object length]) {
                    [setIDs addObject:object];
                }
            }
        }
    }

    id connections = dictionary[@"connections"];
    if ([connections isKindOfClass:NSArray.class]) {
        for (id connection in (NSArray *)connections)
            TPKCollectSetIDsFromObject(connection, setIDs);
    } else if ([connections isKindOfClass:NSDictionary.class]) {
        // Accept connection maps as well as arrays.
        for (id connection in [(NSDictionary *)connections allValues])
            TPKCollectSetIDsFromObject(connection, setIDs);
    }
}

static BOOL TPKSetContainerHasEmotePayload(id value) {
    return TPKSetHasEmotePayload(value);
}

static NSDictionary *TPKFindSetDictionary(id container, NSString *identifier) {
    if (!identifier.length) return nil;
    if ([container isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)container;
        NSString *containerID = TPKString(dictionary[@"id"]);
        if ([containerID isEqualToString:identifier] &&
            TPKDictionaryHasDirectEmoteCollection(dictionary)) {
            return dictionary;
        }
        NSDictionary *direct = [dictionary[identifier] isKindOfClass:NSDictionary.class]
            ? dictionary[identifier] : nil;
        if (direct) return direct;
        for (id value in dictionary.allValues) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSString *valueID = TPKString(value[@"id"]);
            if ([valueID isEqualToString:identifier]) return value;
        }
    } else if ([container isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)container) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSString *valueID = TPKString(value[@"id"]);
            if ([valueID isEqualToString:identifier]) return value;
        }
    }
    return nil;
}

static id TPKConnectionValue(id connections, BOOL wantsPayload) {
    BOOL isMap = [connections isKindOfClass:NSDictionary.class];
    if (!isMap && ![connections isKindOfClass:NSArray.class]) return nil;

    BOOL sawIdentifiablePlatform = NO;
    id fallback = nil, selection = nil;
    NSDictionary *fallbackConnection = nil, *selectionConnection = nil;
    id fallbackMapKey = nil, selectionMapKey = nil;
    for (id entry in connections) {
        id mapKey = isMap ? entry : nil;
        id rawConnection = isMap ? ((NSDictionary *)connections)[entry] : entry;
        if (![rawConnection isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *connection = rawConnection;

        NSString *platform = TPKString(connection[@"platform"]);
        if (!platform.length && !wantsPayload && isMap &&
            [mapKey isKindOfClass:NSString.class]) platform = mapKey;
        if (!platform.length) platform = TPKString(connection[@"platform_name"]);
        if (!platform.length) platform = TPKString(connection[@"platformName"]);
        if (!platform.length && wantsPayload) {
            id hint = connection[@"__tpk_platform_hint"];
            if (isMap && [mapKey isKindOfClass:NSString.class] &&
                !TPKString(connection[@"platform"]).length) hint = mapKey;
            platform = TPKString(hint);
        }
        platform = platform.lowercaseString;
        if (!wantsPayload && platform.length) sawIdentifiablePlatform = YES;

        id candidate = nil;
        if (wantsPayload) {
            id rawSet = connection[@"emote_set"] ?: connection[@"emoteSet"] ?: connection[@"set"];
            if ([rawSet isKindOfClass:NSDictionary.class] &&
                TPKDictionaryHasDirectEmoteCollection(rawSet)) {
                candidate = rawSet;
            } else if (TPKDictionaryHasDirectEmoteCollection(connection)) {
                candidate = connection;
            }
        } else {
            NSString *identifier = TPKString(connection[@"emote_set_id"]) ?:
                TPKString(connection[@"emoteSetId"]);
            if (!identifier.length) {
                id rawSet = connection[@"emote_set"] ?: connection[@"emoteSet"] ?: connection[@"set"];
                identifier = [rawSet isKindOfClass:NSString.class]
                    ? rawSet
                    : ([rawSet isKindOfClass:NSDictionary.class]
                       ? (TPKString(rawSet[@"id"]) ?:
                          TPKString(rawSet[@"emote_set_id"]) ?:
                          TPKString(rawSet[@"emoteSetId"])) : nil);
            }
            candidate = identifier;
        }
        if (wantsPayload && !candidate) continue;
        if (!wantsPayload &&
            (![candidate isKindOfClass:NSString.class] || ![(NSString *)candidate length]))
            continue;
        if (wantsPayload && platform.length) sawIdentifiablePlatform = YES;

        if ([platform isEqualToString:@"twitch"] || [platform containsString:@"twitch"]) {
            selection = candidate;
            selectionConnection = connection;
            selectionMapKey = mapKey;
            break;
        }
        if (!platform.length && !fallback) {
            fallback = candidate;
            fallbackConnection = connection;
            fallbackMapKey = mapKey;
        }
    }

    if (!selection) {
        if (sawIdentifiablePlatform) return nil;
        selection = fallback;
        selectionConnection = fallbackConnection;
        selectionMapKey = fallbackMapKey;
    }
    if (wantsPayload && selection && selection == selectionConnection &&
        [selectionMapKey isKindOfClass:NSString.class] &&
        !TPKString(selectionConnection[@"platform"]).length) {
        NSMutableDictionary *withHint = [selection mutableCopy];
        withHint[@"__tpk_platform_hint"] = selectionMapKey;
        selection = withHint.copy;
    }
    return selection;
}

static NSString *TPKActiveSetIDFromObject(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = (NSDictionary *)value;
    id active = root[@"emote_set"] ?: root[@"emoteSet"] ?: root[@"set"];
    if ([active isKindOfClass:NSString.class] && [active length]) return active;
    if ([active isKindOfClass:NSDictionary.class]) {
        NSString *identifier = TPKString(active[@"id"]);
        if (identifier.length) return identifier;
    }
    for (NSString *key in @[@"emote_set_id", @"emoteSetId"]) {
        NSString *identifier = TPKString(root[key]);
        if (identifier.length) return identifier;
    }
    NSString *connectionID = TPKConnectionValue(root[@"connections"], NO);
    if (connectionID.length) return connectionID;
    id sets = root[@"emote_sets"] ?: root[@"sets"];
    if ([sets isKindOfClass:NSArray.class]) {
        for (id rawSet in (NSArray *)sets) {
            if ([rawSet isKindOfClass:NSDictionary.class]) {
                NSString *identifier = TPKString(rawSet[@"id"]);
                if (identifier.length) return identifier;
            } else if ([rawSet isKindOfClass:NSString.class] && [rawSet length]) {
                return rawSet;
            }
        }
    }
    if ([sets isKindOfClass:NSDictionary.class]) {
        NSDictionary *directSet = (NSDictionary *)sets;
        if (TPKDictionaryHasDirectEmoteCollection(directSet)) {
            NSString *identifier = TPKString(directSet[@"id"]) ?:
                TPKString(directSet[@"emote_set_id"]);
            if (identifier.length) return identifier;
        }
        if (TPKString(directSet[@"id"]).length &&
            TPKString(directSet[@"name"]).length)
            return TPKString(directSet[@"id"]);
        for (id key in [(NSDictionary *)sets allKeys]) {
            if ([key isKindOfClass:NSString.class] && [key length]) return key;
        }
    }
    return nil;
}

static NSDictionary *TPKConnectionSetWithPayload(id connections) {
    return TPKConnectionValue(connections, YES);
}

@interface TPKEmoteDescriptor ()
@property (nonatomic, assign, readwrite) TPKEmoteProviderID provider;
@property (nonatomic, copy, readwrite) NSString *providerIdentifier;
@property (nonatomic, copy, readwrite) NSString *providerName;
@property (nonatomic, copy, readwrite) NSString *emoteID;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *aliases;
@property (nonatomic, assign, readwrite) TPKEmoteSectionKind sectionKind;
@property (nonatomic, copy, readwrite) NSString *sectionIdentifier;
@property (nonatomic, copy, readwrite) NSString *sectionTitle;
@property (nonatomic, copy, readwrite, nullable) NSString *setID;
@property (nonatomic, assign, readwrite) CGSize nativeSize;
@property (nonatomic, assign, readwrite) BOOL animated;
@property (nonatomic, assign, readwrite) BOOL zeroWidth;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *modifierMetadata;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSString *> *imageURLs;
@end

@implementation TPKEmoteDescriptor

- (instancetype)initWithProvider:(TPKEmoteProviderID)provider
               providerIdentifier:(NSString *)providerIdentifier
                           emoteID:(NSString *)emoteID
                              name:(NSString *)name
                           aliases:(NSArray<NSString *> *)aliases
                       sectionKind:(TPKEmoteSectionKind)sectionKind
                sectionIdentifier:(NSString *)sectionIdentifier
                       sectionTitle:(NSString *)sectionTitle
                             setID:(NSString *)setID
                        nativeSize:(CGSize)nativeSize
                          animated:(BOOL)animated
                         zeroWidth:(BOOL)zeroWidth
                  modifierMetadata:(NSDictionary<NSString *, id> *)modifierMetadata
                         imageURLs:(NSDictionary<NSNumber *, NSString *> *)imageURLs {
    self = [super init];
    if (!self) return nil;
    _provider = provider;
    _providerIdentifier = [providerIdentifier copy] ?: TPKEmoteProviderKey(provider);
    _providerName = TPKEmoteProviderName(provider);
    _emoteID = [emoteID copy] ?: @"";
    _name = [name copy] ?: @"";
    _aliases = [aliases copy] ?: @[];
    _sectionKind = sectionKind;
    _sectionIdentifier = [sectionIdentifier copy] ?: @"";
    _sectionTitle = [sectionTitle copy] ?: @"";
    _setID = [setID copy];
    _nativeSize = (nativeSize.width > 0.0 && nativeSize.height > 0.0)
        ? nativeSize : CGSizeMake(1.0, 1.0);
    _animated = animated;
    _zeroWidth = zeroWidth;
    _modifierMetadata = [modifierMetadata copy] ?: @{};
    _imageURLs = [imageURLs copy] ?: @{};
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (nullable NSURL *)imageURLForResolution:(NSInteger)resolution {
    if (resolution < 1) resolution = 1;
    if (resolution > 4) resolution = 4;
    if (!self.imageURLs.count) return nil;

    NSString *urlString = self.imageURLs[@(resolution)];
    // FFZ provides 1x, 2x, and 4x assets.
    if (!urlString.length && resolution == 3) urlString = self.imageURLs[@4];
    if (!urlString.length && resolution == 4) urlString = self.imageURLs[@3];
    if (!urlString.length) urlString = self.imageURLs[@2];
    if (!urlString.length) urlString = self.imageURLs[@1];
    if (!urlString.length) {
        NSArray<NSNumber *> *scales = [self.imageURLs.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSNumber *closest = nil;
        NSInteger distance = NSIntegerMax;
        for (NSNumber *scale in scales) {
            NSInteger candidateDistance = labs(scale.integerValue - resolution);
            if (candidateDistance < distance ||
                (candidateDistance == distance && scale.integerValue > closest.integerValue)) {
                closest = scale;
                distance = candidateDistance;
            }
        }
        urlString = closest ? self.imageURLs[closest] : nil;
    }
    return urlString.length ? [NSURL URLWithString:urlString] : nil;
}

@end

@interface TPKEmoteSection ()
@property (nonatomic, assign, readwrite) TPKEmoteProviderID provider;
@property (nonatomic, assign, readwrite) TPKEmoteSectionKind kind;
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSArray<TPKEmoteDescriptor *> *emotes;
@property (nonatomic, assign, readwrite) BOOL loaded;
@property (nonatomic, assign, readwrite) BOOL loading;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@end

@implementation TPKEmoteSection
- (instancetype)initWithProvider:(TPKEmoteProviderID)provider
                              kind:(TPKEmoteSectionKind)kind
                        identifier:(NSString *)identifier
                             title:(NSString *)title
                            emotes:(NSArray<TPKEmoteDescriptor *> *)emotes
                            loaded:(BOOL)loaded
                           loading:(BOOL)loading
                      errorMessage:(NSString *)errorMessage {
    self = [super init];
    if (!self) return nil;
    _provider = provider;
    _kind = kind;
    _identifier = [identifier copy] ?: @"";
    _title = [title copy] ?: @"";
    _emotes = [emotes copy] ?: @[];
    _loaded = loaded;
    _loading = loading;
    _errorMessage = [errorMessage copy];
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@interface TPKEmoteProviderSnapshot ()
@property (nonatomic, assign, readwrite) TPKEmoteProviderID provider;
@property (nonatomic, assign, readwrite) TPKEmoteProviderState state;
@property (nonatomic, copy, readwrite) NSString *channelID;
@property (nonatomic, copy, readwrite) NSArray<TPKEmoteSection *> *sections;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@end

@implementation TPKEmoteProviderSnapshot

- (id)copyWithZone:(NSZone *)zone {
    TPKEmoteProviderSnapshot *copy = [TPKEmoteProviderSnapshot allocWithZone:zone];
    copy.provider = self.provider;
    copy.state = self.state;
    copy.channelID = self.channelID;
    copy.sections = self.sections;
    copy.errorMessage = self.errorMessage;
    return copy;
}
@end

@interface TPKEmoteCatalogRequest : NSObject
@property (nonatomic, copy) NSString *taskKey;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) TPKEmoteProviderID provider;
@property (nonatomic, copy) NSString *scope;
@property (nonatomic, copy) NSString *setID;
@property (nonatomic) BOOL global;
@property (nonatomic) BOOL asPrimary;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger cacheEpoch;
@property (nonatomic, weak) NSURLSessionDataTask *task;
@end

@implementation TPKEmoteCatalogRequest
@end

@interface TPKEmoteCatalogResult : NSObject
@property (nonatomic, copy) NSArray<TPKEmoteSection *> *sections;
@property (nonatomic, copy) NSArray<NSDictionary *> *discoveredSets;
@property (nonatomic, strong) NSError *error;
@end

@implementation TPKEmoteCatalogResult
@end

@interface TPKEmoteCatalog ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TPKEmoteProviderSnapshot *> *snapshots;
// NSNull reserves a request while its task is being created.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *requestGenerations;
// Reuse the latest successful snapshot when the picker reopens.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastSuccessfulLoads;
@property (nonatomic, copy) NSString *activeChannelID;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<TPKEmoteSection *> *> *orderedSectionsCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<TPKEmoteDescriptor *> *> *orderedEmoteCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary<NSString *, TPKEmoteDescriptor *> *> *nameIndexCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *derivedCacheGenerations;
@property (nonatomic) NSUInteger cacheEpoch;
- (void)loadTPKAdditionalSets:(NSArray<NSDictionary *> *)discoveredSets
                        global:(BOOL)global
                       channel:(nullable NSString *)channel
                    generation:(NSUInteger)parentGeneration
                    cacheEpoch:(NSUInteger)parentCacheEpoch
         requireActiveRequest:(BOOL)requireActiveRequest;
- (void)loadTPKSetID:(NSString *)setID
                   global:(BOOL)global
                  channel:(nullable NSString *)channel
                asPrimary:(BOOL)asPrimary;
- (BOOL)updateTPKSetPlaceholderForID:(NSString *)setID
                                  global:(BOOL)global
                                 channel:(nullable NSString *)channel
                                  title:(nullable NSString *)title
                              asPrimary:(BOOL)asPrimary
                                 loaded:(BOOL)loaded
                                loading:(BOOL)loading
                           errorMessage:(nullable NSString *)errorMessage;
- (void)mergeTPKSetSections:(NSArray<TPKEmoteSection *> *)sections
                          global:(BOOL)global
                         channel:(nullable NSString *)channel;
- (NSArray<TPKEmoteSection *> *)sectionsByCombining:(NSArray<TPKEmoteSection *> *)fresh
                                        withExisting:(NSArray<TPKEmoteSection *> *)existing
                                               global:(BOOL)global;
- (void)invalidateDerivedCachesForProvider:(TPKEmoteProviderID)provider;
- (nullable TPKEmoteSection *)sevenTVSectionFromSet:(NSDictionary *)set
                                               global:(BOOL)global
                                          sectionKind:(TPKEmoteSectionKind)kind
                                      sectionIdentifier:(NSString *)identifier
                                               title:(NSString *)title;
- (NSArray<TPKEmoteSection *> *)sevenTVSetSectionsFromObject:(id)object
                                                     requestedID:(NSString *)requestedID
                                                     asPrimary:(BOOL)asPrimary
                                                       global:(BOOL)global;
- (NSArray<TPKEmoteSection *> *)sectionsFromObject:(id)object
                                            provider:(TPKEmoteProviderID)provider
                                               global:(BOOL)global
                                              channel:(NSString *)channel
                                              setIDs:(nullable NSOrderedSet<NSString *> *)setIDs
                                                error:(NSError **)error;
- (BOOL)startCatalogRequest:(TPKEmoteCatalogRequest *)request
                   willStart:(dispatch_block_t)willStart
                      cached:(void (^)(TPKEmoteCatalogResult *))cached
                  completion:(void (^)(TPKEmoteCatalogResult *, NSData *))completion;
- (BOOL)requestIsCurrent:(TPKEmoteCatalogRequest *)request;
- (TPKEmoteCatalogResult *)resultForObject:(id)object
                                   request:(TPKEmoteCatalogRequest *)request
                                     error:(NSError **)error;
- (NSArray<NSDictionary *> *)discoveredTPKSetsFromObject:(id)object
                                                    setIDs:(NSOrderedSet<NSString *> *)setIDs;
- (void)publishTPKSetState:(TPKEmoteCatalogRequest *)request
                    loading:(BOOL)loading
                      error:(nullable NSError *)error;
- (void)cancelCatalogTaskForKey:(NSString *)key;
- (void)writeCatalogData:(NSData *)data toPath:(NSString *)path;
- (TPKEmoteProviderSnapshot *)publishProviderResult:(nullable TPKEmoteCatalogResult *)result
                                            request:(TPKEmoteCatalogRequest *)request
                                            loading:(BOOL)loading;
@end

@implementation TPKEmoteCatalog

+ (instancetype)sharedCatalog {
    static TPKEmoteCatalog *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ catalog = [self new]; });
    return catalog;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _stateQueue = dispatch_queue_create("com.twitchplusk.emote-catalog", DISPATCH_QUEUE_SERIAL);
    _ioQueue = dispatch_queue_create("com.twitchplusk.emote-catalog-io", DISPATCH_QUEUE_SERIAL);
    _snapshots = [NSMutableDictionary dictionary];
    _tasks = [NSMutableDictionary dictionary];
    _requestGenerations = [NSMutableDictionary dictionary];
    _lastSuccessfulLoads = [NSMutableDictionary dictionary];
    _orderedSectionsCache = [NSMutableDictionary dictionary];
    _orderedEmoteCache = [NSMutableDictionary dictionary];
    _nameIndexCache = [NSMutableDictionary dictionary];
    _derivedCacheGenerations = [NSMutableDictionary dictionary];
    [TPKEmoteProviderSettings migrateLegacySettings];
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        TPKEmoteProviderSnapshot *snapshot = [TPKEmoteProviderSnapshot new];
        snapshot.provider = (TPKEmoteProviderID)provider;
        snapshot.state = TPKEmoteProviderStateIdle;
        snapshot.channelID = @"";
        snapshot.sections = @[];
        _snapshots[@(provider)] = snapshot;
    }
    return self;
}

- (NSArray<NSNumber *> *)providerPriority {
    static NSArray<NSNumber *> *priority;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ priority = @[@(TPKEmoteProviderIDTPK), @(TPKEmoteProviderIDBTTV), @(TPKEmoteProviderIDFFZ)]; });
    return priority;
}

- (TPKEmoteProviderSnapshot *)snapshotForProvider:(TPKEmoteProviderID)provider {
    __block TPKEmoteProviderSnapshot *snapshot;
    dispatch_sync(self.stateQueue, ^{ snapshot = [self.snapshots[@(provider)] copy]; });
    return snapshot ?: [TPKEmoteProviderSnapshot new];
}

- (NSArray<TPKEmoteSection *> *)sectionsForProvider:(TPKEmoteProviderID)provider {
    NSNumber *providerKey = @(provider);
    NSUInteger generation = 0;
    @synchronized (self) {
        NSArray<TPKEmoteSection *> *cached = self.orderedSectionsCache[providerKey];
        if (cached) return cached;
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }

    NSArray<TPKEmoteSection *> *sections = [self snapshotForProvider:provider].sections ?: @[];
    // Sort unordered API data for stable picker sections.
    NSArray<TPKEmoteSection *> *sorted = [sections sortedArrayUsingComparator:^NSComparisonResult(TPKEmoteSection *left,
                                                                                                    TPKEmoteSection *right) {
        NSInteger leftRank = left.kind == TPKEmoteSectionKindChannel ? 0
            : (left.kind == TPKEmoteSectionKindShared ? 1
               : (left.kind == TPKEmoteSectionKindGlobal ? 2 : 3));
        NSInteger rightRank = right.kind == TPKEmoteSectionKindChannel ? 0
            : (right.kind == TPKEmoteSectionKindShared ? 1
               : (right.kind == TPKEmoteSectionKindGlobal ? 2 : 3));
        if (leftRank < rightRank) return NSOrderedAscending;
        if (leftRank > rightRank) return NSOrderedDescending;
        NSComparisonResult titleResult = [left.title compare:right.title
            options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (titleResult != NSOrderedSame) return titleResult;
        return [left.identifier compare:right.identifier
            options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    @synchronized (self) {
        // Ignore sort results for an outdated snapshot.
        if (self.derivedCacheGenerations[providerKey].unsignedIntegerValue == generation) {
            NSArray<TPKEmoteSection *> *existing = self.orderedSectionsCache[providerKey];
            if (existing) return existing;
            self.orderedSectionsCache[providerKey] = sorted;
        }
    }
    return sorted;
}

- (NSArray<TPKEmoteDescriptor *> *)allEmotesForProvider:(TPKEmoteProviderID)provider {
    NSNumber *providerKey = @(provider);
    NSUInteger generation = 0;
    @synchronized (self) {
        NSArray<TPKEmoteDescriptor *> *cached = self.orderedEmoteCache[providerKey];
        if (cached) return cached;
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }

    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    // Prefer channel/shared emotes over provider-global matches.
    NSArray<TPKEmoteSection *> *sections = [[self sectionsForProvider:provider]
        sortedArrayUsingComparator:^NSComparisonResult(TPKEmoteSection *left,
                                                       TPKEmoteSection *right) {
        NSInteger leftRank = left.kind == TPKEmoteSectionKindChannel ? 0
            : (left.kind == TPKEmoteSectionKindShared ? 1
               : (left.kind == TPKEmoteSectionKindSet ? 2 : 3));
        NSInteger rightRank = right.kind == TPKEmoteSectionKindChannel ? 0
            : (right.kind == TPKEmoteSectionKindShared ? 1
               : (right.kind == TPKEmoteSectionKindSet ? 2 : 3));
        if (leftRank < rightRank) return NSOrderedAscending;
        if (leftRank > rightRank) return NSOrderedDescending;
        return [left.identifier compare:right.identifier
            options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    // Put channel/shared/set emotes first when names collide.
    for (TPKEmoteSection *section in sections) {
        for (TPKEmoteDescriptor *emote in section.emotes) {
            NSString *stableKey = TPKEmoteFavoriteKey(emote.provider, emote.emoteID);
            if (!stableKey.length || [seenKeys containsObject:stableKey]) continue;
            [seenKeys addObject:stableKey];
            [result addObject:emote];
        }
    }
    NSArray<TPKEmoteDescriptor *> *flattened = result.copy;
    @synchronized (self) {
        if (self.derivedCacheGenerations[providerKey].unsignedIntegerValue == generation) {
            NSArray<TPKEmoteDescriptor *> *existing = self.orderedEmoteCache[providerKey];
            if (existing) return existing;
            self.orderedEmoteCache[providerKey] = flattened;
        }
    }
    return flattened;
}

- (TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name
                                  provider:(TPKEmoteProviderID)provider {
    if (!name.length) return nil;
    NSNumber *providerKey = @(provider);
    NSDictionary<NSString *, TPKEmoteDescriptor *> *index = nil;
    NSUInteger generation = 0;
    @synchronized (self) {
        index = self.nameIndexCache[providerKey];
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }
    if (!index) {
        NSMutableDictionary<NSString *, TPKEmoteDescriptor *> *built = [NSMutableDictionary dictionary];
        for (TPKEmoteDescriptor *emote in [self allEmotesForProvider:provider]) {
            if (emote.name.length && !built[emote.name]) built[emote.name] = emote;
            for (NSString *alias in emote.aliases) {
                if (alias.length && !built[alias]) built[alias] = emote;
            }
        }
        @synchronized (self) {
            if (self.derivedCacheGenerations[providerKey].unsignedIntegerValue == generation) {
                index = self.nameIndexCache[providerKey];
                if (!index) {
                    index = built.copy;
                    self.nameIndexCache[providerKey] = index;
                }
            }
        }
        if (!index) index = built;
    }
    return index[name];
}

- (TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;
    for (NSNumber *providerNumber in self.providerPriority) {
        TPKEmoteDescriptor *emote = [self resolveEmoteNamed:name
                                                       provider:providerNumber.integerValue];
        if (emote) return emote;
    }
    return nil;
}

- (void)invalidateDerivedCachesForProvider:(TPKEmoteProviderID)provider {
    NSNumber *key = @(provider);
    @synchronized (self) {
        self.derivedCacheGenerations[key] =
            @(self.derivedCacheGenerations[key].unsignedIntegerValue + 1);
        [self.orderedSectionsCache removeObjectForKey:key];
        [self.orderedEmoteCache removeObjectForKey:key];
        [self.nameIndexCache removeObjectForKey:key];
    }
}

- (NSString *)cacheDirectory {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"s7tv-emote-providers"];
}

- (NSString *)cachePathForProvider:(TPKEmoteProviderID)provider global:(BOOL)global channel:(NSString *)channel {
    NSString *scope = global ? @"global" : ([channel stringByReplacingOccurrencesOfString:@"/" withString:@"_"] ?: @"channel");
    return [[self cacheDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.json", TPKEmoteProviderKey(provider), scope]];
}

- (NSString *)cachePathForTPKSetID:(NSString *)setID {
    NSString *safeID = [setID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeID = [safeID stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return [[self cacheDirectory]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"7tv-set-%@.json", safeID]];
}

- (void)mergeTPKSetSections:(NSArray<TPKEmoteSection *> *)sections
                          global:(BOOL)global
                         channel:(nullable NSString *)channel {
    if (!sections.count) return;
    if (!global && (!channel.length ||
                    [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame))
        return;

    TPKEmoteProviderSnapshot *snapshot =
        self.snapshots[@(TPKEmoteProviderIDTPK)];
    if (!snapshot) return;
    NSMutableArray<TPKEmoteSection *> *merged =
        [snapshot.sections mutableCopy] ?: [NSMutableArray array];
    for (TPKEmoteSection *fresh in sections) {
        if (!fresh.identifier.length) continue;
        NSUInteger replaceIndex = NSNotFound;
        for (NSUInteger index = 0; index < merged.count; index++) {
            TPKEmoteSection *existing = merged[index];
            if (existing.provider == fresh.provider &&
                [existing.identifier isEqualToString:fresh.identifier]) {
                replaceIndex = index;
                break;
            }
        }
        if (replaceIndex == NSNotFound) [merged addObject:fresh];
        else merged[replaceIndex] = fresh;
    }
    snapshot.sections = merged.copy;
    // Show loading while the active set ID is being resolved.
    snapshot.state = TPKEmoteProviderStateLoaded;
    snapshot.errorMessage = nil;
    [self invalidateDerivedCachesForProvider:TPKEmoteProviderIDTPK];
    [self postUpdateForProvider:TPKEmoteProviderIDTPK];
}

- (BOOL)updateTPKSetPlaceholderForID:(NSString *)setID
                                  global:(BOOL)global
                                 channel:(nullable NSString *)channel
                                   title:(nullable NSString *)title
                               asPrimary:(BOOL)asPrimary
                                  loaded:(BOOL)loaded
                                 loading:(BOOL)loading
                            errorMessage:(nullable NSString *)errorMessage {
    if (!setID.length || (!global &&
        (!channel.length || [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)))
        return NO;
    TPKEmoteProviderSnapshot *snapshot =
        self.snapshots[@(TPKEmoteProviderIDTPK)];
    if (!snapshot) return NO;

    // Keep primary sets on stable IDs; optional sets use scope-qualified IDs.
    NSString *identifier = asPrimary
        ? (global ? @"global" : @"channel")
        : TPKSetSectionIdentifier(setID, global);
    NSMutableArray<TPKEmoteSection *> *sections =
        [snapshot.sections mutableCopy] ?: [NSMutableArray array];
    NSUInteger existingIndex = NSNotFound;
    TPKEmoteSection *existing = nil;
    for (NSUInteger index = 0; index < sections.count; index++) {
        TPKEmoteSection *candidate = sections[index];
        if (candidate.provider == TPKEmoteProviderIDTPK &&
            [candidate.identifier isEqualToString:identifier]) {
            existingIndex = index;
            existing = candidate;
            break;
        }
    }

    // Keep usable cached emotes visible during refresh failures.
    if (existing.emotes.count) return NO;

    NSString *resolvedTitle = title.length ? title :
        (existing.title.length ? existing.title :
         (asPrimary ? (global ? @"Global Emotes" : @"Channel Emotes") : @"Emote Set"));
    NSString *resolvedError = errorMessage.length ? errorMessage : nil;
    NSString *existingError = existing.errorMessage ?: @"";
    NSString *newError = resolvedError ?: @"";
    if (existing && existing.loaded == loaded && existing.loading == loading &&
        [existingError isEqualToString:newError] &&
        [existing.title isEqualToString:resolvedTitle]) {
        return NO;
    }

    TPKEmoteSection *replacement = [[TPKEmoteSection alloc]
        initWithProvider:TPKEmoteProviderIDTPK
                   kind:(asPrimary ? (global ? TPKEmoteSectionKindGlobal
                                             : TPKEmoteSectionKindChannel)
                                   : TPKEmoteSectionKindSet)
             identifier:identifier
                   title:resolvedTitle
                  emotes:@[]
                  loaded:loaded
                 loading:loading
            errorMessage:resolvedError];
    if (existingIndex == NSNotFound) [sections addObject:replacement];
    else sections[existingIndex] = replacement;
    snapshot.sections = sections.copy;
    [self invalidateDerivedCachesForProvider:TPKEmoteProviderIDTPK];
    return YES;
}

- (void)loadTPKSetID:(NSString *)setID
                   global:(BOOL)global
                  channel:(nullable NSString *)channel
                asPrimary:(BOOL)asPrimary {
    if (!setID.length) return;
    NSString *scope = global ? @"global" : channel;
    if (!scope.length) return;
    NSString *escapedID = [setID stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://7tv.io/v3/emote-sets/%@", escapedID ?: setID]];
    if (!url) return;

    TPKEmoteCatalogRequest *request = [TPKEmoteCatalogRequest new];
    request.taskKey = [NSString stringWithFormat:@"7tv-set:%@:%@", setID, scope];
    request.url = TPKEmoteProxyRewriteURL(url);
    request.provider = TPKEmoteProviderIDTPK;
    request.scope = scope;
    request.setID = setID;
    request.global = global;
    request.asPrimary = asPrimary;
    if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)
        return;
    [self startCatalogRequest:request willStart:^{
        if (!asPrimary) [self publishTPKSetState:request loading:YES error:nil];
    } cached:^(TPKEmoteCatalogResult *result) {
        if (result.sections.count)
            [self mergeTPKSetSections:result.sections global:global channel:channel];
    } completion:^(TPKEmoteCatalogResult *result, NSData *data) {
        if (result.sections.count)
            [self mergeTPKSetSections:result.sections global:global channel:channel];
        else
            [self publishTPKSetState:request loading:NO error:result.error];
    }];
}

- (void)publishTPKSetState:(TPKEmoteCatalogRequest *)request
                    loading:(BOOL)loading
                      error:(NSError *)error {
    BOOL loaded = !loading && !error;
    if (error && request.asPrimary && !request.global) loaded = YES;
    BOOL changed = [self updateTPKSetPlaceholderForID:request.setID
        global:request.global channel:(request.global ? nil : request.scope)
        title:nil asPrimary:request.asPrimary loaded:loaded loading:loading
        errorMessage:error.localizedDescription ?: (error ? @"Unable to load 7TV emote set" : nil)];
    if (changed) [self postUpdateForProvider:TPKEmoteProviderIDTPK];
}

- (NSArray<NSDictionary *> *)discoveredTPKSetsFromObject:(id)object
                                                    setIDs:(NSOrderedSet<NSString *> *)setIDs {
    if (![object isKindOfClass:NSDictionary.class] || !setIDs.count) return @[];

    NSString *activeID = TPKActiveSetIDFromObject(object);
    id container = object[@"emote_sets"] ?: object[@"sets"];
    NSMutableArray<NSDictionary *> *discovered = [NSMutableArray array];
    NSUInteger count = 0;
    for (NSString *setID in setIDs) {
        if (!setID.length || setID.length > 128 || count >= 32) continue;
        count++;
        NSDictionary *metadata = TPKFindSetDictionary(container, setID);
        NSString *title = TPKString(metadata[@"name"]);
        [discovered addObject:@{
            @"id": setID,
            @"title": title ?: NSNull.null,
            @"primary": @(activeID.length && [activeID isEqualToString:setID]),
            @"hasActive": @(activeID.length > 0),
        }];
    }
    return discovered.copy;
}

- (void)loadTPKAdditionalSets:(NSArray<NSDictionary *> *)discoveredSets
                        global:(BOOL)global
                       channel:(NSString *)channel
                    generation:(NSUInteger)parentGeneration
                    cacheEpoch:(NSUInteger)parentCacheEpoch
         requireActiveRequest:(BOOL)requireActiveRequest {
    if (!discoveredSets.count) return;
    NSString *parentKey = [NSString stringWithFormat:@"7tv:%@",
                           global ? @"global" : (channel ?: @"")];
    if (self.cacheEpoch != parentCacheEpoch ||
        self.requestGenerations[parentKey].unsignedIntegerValue != parentGeneration ||
        (requireActiveRequest && !self.tasks[parentKey]) ||
        (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame))
        return;

    TPKEmoteProviderSnapshot *snapshot = self.snapshots[@(TPKEmoteProviderIDTPK)];
    NSMutableSet<NSString *> *loadedIDs = [NSMutableSet set];
    for (TPKEmoteSection *section in snapshot.sections) {
        NSString *prefix = [section.identifier hasPrefix:@"global-set:"]
            ? @"global-set:" : ([section.identifier hasPrefix:@"set:"] ? @"set:" : nil);
        if (prefix && section.kind == TPKEmoteSectionKindSet &&
            (section.loaded || section.loading || section.errorMessage.length))
            [loadedIDs addObject:[section.identifier substringFromIndex:prefix.length]];
        for (TPKEmoteDescriptor *emote in section.emotes)
            if (emote.setID.length) [loadedIDs addObject:emote.setID];
    }

    BOOL changed = NO;
    BOOL fallbackPrimaryAssigned = NO;
    BOOL primaryScheduled = NO;
    NSString *primarySetID = nil;
    for (NSDictionary *entry in discoveredSets) {
        NSString *setID = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : nil;
        if (!setID.length || [loadedIDs containsObject:setID]) continue;
        BOOL primary = [entry[@"primary"] boolValue];
        if (![entry[@"hasActive"] boolValue]) {
            primary = !fallbackPrimaryAssigned;
            if (primary) fallbackPrimaryAssigned = YES;
        }
        id rawTitle = entry[@"title"];
        NSString *title = [rawTitle isKindOfClass:NSString.class] ? rawTitle : nil;
        if (primary) {
            primaryScheduled = YES;
            primarySetID = setID;
            [self loadTPKSetID:setID global:global channel:channel asPrimary:YES];
            if (global)
                changed |= [self updateTPKSetPlaceholderForID:setID global:YES channel:nil
                    title:title asPrimary:YES loaded:NO loading:YES errorMessage:nil];
        } else {
            changed |= [self updateTPKSetPlaceholderForID:setID global:global channel:channel
                title:title asPrimary:NO loaded:NO loading:YES errorMessage:nil];
            [self loadTPKSetID:setID global:global channel:channel asPrimary:NO];
        }
    }
    if (primaryScheduled && !global)
        changed |= [self updateTPKSetPlaceholderForID:primarySetID global:NO channel:channel
            title:nil asPrimary:YES loaded:NO loading:YES errorMessage:nil];
    if (changed) [self postUpdateForProvider:TPKEmoteProviderIDTPK];
}

- (void)loadGlobalProviders {
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++)
        [self loadProvider:(TPKEmoteProviderID)provider global:YES channel:nil completion:nil];
}

- (void)loadChannelProvidersForTwitchID:(NSString *)twitchID {
    if (!twitchID.length) return;
    dispatch_async(self.stateQueue, ^{
        NSString *previous = self.activeChannelID;
        if (previous.length && ![previous isEqualToString:twitchID]) {
            NSString *suffix = [NSString stringWithFormat:@":%@", previous];
            for (NSString *key in self.tasks.allKeys.copy)
                if ([key hasSuffix:suffix]) [self cancelCatalogTaskForKey:key];
        }
        self.activeChannelID = [twitchID copy];
        for (NSInteger provider = TPKEmoteProviderIDTPK;
             provider <= TPKEmoteProviderIDFFZ; provider++)
            [self loadProvider:(TPKEmoteProviderID)provider global:NO channel:twitchID completion:nil];
    });
}

- (void)clearActiveChannelScope {
    dispatch_async(self.stateQueue, ^{
        NSString *previous = self.activeChannelID;
        if (previous.length) {
            NSString *suffix = [NSString stringWithFormat:@":%@", previous];
            for (NSString *key in self.tasks.allKeys.copy)
                if ([key hasSuffix:suffix]) [self cancelCatalogTaskForKey:key];
        }
        self.activeChannelID = @"";
        for (NSInteger provider = TPKEmoteProviderIDTPK;
             provider <= TPKEmoteProviderIDFFZ; provider++) {
            TPKEmoteProviderSnapshot *old = self.snapshots[@(provider)];
            NSMutableArray<TPKEmoteSection *> *global = [NSMutableArray array];
            for (TPKEmoteSection *section in old.sections) {
                BOOL keep = section.kind == TPKEmoteSectionKindGlobal ||
                    (section.kind == TPKEmoteSectionKindSet &&
                     [section.identifier hasPrefix:@"global-set:"]);
                if (keep) [global addObject:section];
            }
            TPKEmoteProviderSnapshot *snapshot = [TPKEmoteProviderSnapshot new];
            snapshot.provider = (TPKEmoteProviderID)provider;
            snapshot.state = global.count ? TPKEmoteProviderStateLoaded : TPKEmoteProviderStateIdle;
            snapshot.channelID = @"";
            snapshot.sections = global.copy;
            self.snapshots[@(provider)] = snapshot;
            [self invalidateDerivedCachesForProvider:(TPKEmoteProviderID)provider];
            [self postUpdateForProvider:(TPKEmoteProviderID)provider];
        }
    });
}

- (void)loadTPKEmoteSetWithID:(NSString *)setID
                       global:(BOOL)global
                      channel:(nullable NSString *)twitchID {
    if (!setID.length) return;
    dispatch_async(self.stateQueue, ^{
        NSString *channel = twitchID.length ? twitchID : self.activeChannelID;
        if (!global && !channel.length) return;
        [self loadTPKSetID:setID global:global channel:(global ? nil : channel) asPrimary:NO];
    });
}

- (void)loadSetForProvider:(TPKEmoteProviderID)provider
                identifier:(NSString *)identifier
                    global:(BOOL)global
                   channel:(nullable NSString *)twitchID {
    if (provider != TPKEmoteProviderIDTPK || !identifier.length) return;
    BOOL identifierGlobal = global;
    NSString *setID = TPKSetIDFromSectionIdentifier(identifier, &identifierGlobal);
    if (!setID.length) return;
    dispatch_async(self.stateQueue, ^{
        NSString *channel = twitchID.length ? twitchID : self.activeChannelID;
        if (!identifierGlobal && !channel.length) return;
        [self loadTPKSetID:setID global:identifierGlobal
                   channel:(identifierGlobal ? nil : channel) asPrimary:NO];
    });
}

- (NSURL *)URLForProvider:(TPKEmoteProviderID)provider global:(BOOL)global channel:(NSString *)channel {
    NSString *urlString = nil;
    switch (provider) {
        case TPKEmoteProviderIDTPK:
            urlString = global ? @"https://7tv.io/v3/emote-sets/global"
                               : [NSString stringWithFormat:@"https://7tv.io/v3/users/twitch/%@", channel];
            break;
        case TPKEmoteProviderIDBTTV:
            urlString = global ? @"https://api.betterttv.net/3/cached/emotes/global"
                               : [NSString stringWithFormat:@"https://api.betterttv.net/3/cached/users/twitch/%@", channel];
            break;
        case TPKEmoteProviderIDFFZ:
            urlString = global ? @"https://api.frankerfacez.com/v1/set/global"
                               : [NSString stringWithFormat:@"https://api.frankerfacez.com/v1/room/id/%@", channel];
            break;
    }
    return TPKEmoteProxyRewriteURL([NSURL URLWithString:urlString]);
}

- (BOOL)requestIsCurrent:(TPKEmoteCatalogRequest *)request {
    id current = self.tasks[request.taskKey];
    return request.task && current && current == request.task &&
        self.requestGenerations[request.taskKey].unsignedIntegerValue == request.generation &&
        self.cacheEpoch == request.cacheEpoch &&
        (request.global || [self.activeChannelID caseInsensitiveCompare:request.scope] == NSOrderedSame);
}

- (TPKEmoteCatalogResult *)resultForObject:(id)object
                                   request:(TPKEmoteCatalogRequest *)request
                                     error:(NSError **)error {
    TPKEmoteCatalogResult *result = [TPKEmoteCatalogResult new];
    NSError *parseError = nil;
    NSArray<TPKEmoteSection *> *sections = nil;
    if (request.setID.length) {
        if (TPKSetContainerHasEmotePayload(object))
            sections = [self sevenTVSetSectionsFromObject:object
                                               requestedID:request.setID
                                                 asPrimary:request.asPrimary
                                                   global:request.global];
        else
            TPKSetCatalogStructureError(&parseError, request.provider);
    } else {
        NSMutableOrderedSet<NSString *> *setIDs = nil;
        if (request.provider == TPKEmoteProviderIDTPK) {
            setIDs = [NSMutableOrderedSet orderedSet];
            TPKCollectSetIDsFromObject(object, setIDs);
            result.discoveredSets = [self discoveredTPKSetsFromObject:object setIDs:setIDs];
        }
        sections = [self sectionsFromObject:object provider:request.provider
                                      global:request.global channel:request.scope
                                     setIDs:setIDs error:&parseError];
    }
    result.sections = sections;
    result.error = parseError;
    if (error) *error = parseError;
    return result;
}

- (BOOL)startCatalogRequest:(TPKEmoteCatalogRequest *)request
                   willStart:(dispatch_block_t)willStart
                      cached:(void (^)(TPKEmoteCatalogResult *))cached
                  completion:(void (^)(TPKEmoteCatalogResult *, NSData *))completion {
    if (!request.url || (!request.global &&
        [self.activeChannelID caseInsensitiveCompare:request.scope] != NSOrderedSame)) return NO;
    // Retain jobs until parsed results publish.
    if (self.tasks[request.taskKey]) return NO;

    self.tasks[request.taskKey] = NSNull.null;
    request.generation = self.requestGenerations[request.taskKey].unsignedIntegerValue + 1;
    self.requestGenerations[request.taskKey] = @(request.generation);
    request.cacheEpoch = self.cacheEpoch;
    if (willStart) willStart();

    NSString *cachePath = request.setID.length
        ? [self cachePathForTPKSetID:request.setID]
        : [self cachePathForProvider:request.provider global:request.global
                             channel:request.scope];
    dispatch_async(self.ioQueue, ^{
        NSData *cacheData = [NSData dataWithContentsOfFile:cachePath];
        NSError *cacheError = nil;
        id object = cacheData.length
            ? [NSJSONSerialization JSONObjectWithData:cacheData options:0 error:&cacheError] : nil;
        TPKEmoteCatalogResult *result = object
            ? [self resultForObject:object request:request error:&cacheError] : nil;
        if (!result.sections.count) return;
        dispatch_async(self.stateQueue, ^{
            if ([self requestIsCurrent:request] && cached) cached(result);
        });
    });

    NSMutableURLRequest *networkRequest = [NSMutableURLRequest requestWithURL:request.url];
    networkRequest.timeoutInterval = 15.0;
    [networkRequest setValue:@"TwitchPlusK/1.0" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:networkRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(self.ioQueue, ^{
            NSError *responseError = error;
            if (!responseError) TPKJSONObjectIsValid(data, response, &responseError);
            NSError *jsonError = nil;
            id object = data.length
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            if (!responseError && !object) responseError = jsonError;
            TPKEmoteCatalogResult *result = nil;
            if (!responseError && object)
                result = [self resultForObject:object request:request error:&responseError];
            else if (request.provider == TPKEmoteProviderIDTPK &&
                     !request.setID.length && object) {
                result = [TPKEmoteCatalogResult new];
                NSMutableOrderedSet<NSString *> *setIDs = [NSMutableOrderedSet orderedSet];
                TPKCollectSetIDsFromObject(object, setIDs);
                result.discoveredSets = [self discoveredTPKSetsFromObject:object setIDs:setIDs];
            }
            if (!result) result = [TPKEmoteCatalogResult new];
            result.error = responseError;

            dispatch_async(self.stateQueue, ^{
                if (![self requestIsCurrent:request]) return;
                [self.tasks removeObjectForKey:request.taskKey];
                BOOL shouldPersist = result.sections &&
                    (!request.setID.length || result.sections.count > 0);
                if (shouldPersist) {
                    NSData *dataToSave = [data copy];
                    NSString *path = [cachePath copy];
                    dispatch_async(self.ioQueue, ^{
                        [self writeCatalogData:dataToSave toPath:path];
                    });
                }
                if (completion) completion(result, data);
            });
        });
    }];
    request.task = task;
    self.tasks[request.taskKey] = task;
    [task resume];
    return YES;
}

- (void)writeCatalogData:(NSData *)data toPath:(NSString *)path {
    if (!data.length || !path.length) return;
    NSString *directory = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:path options:NSDataWritingAtomic error:NULL];
}

- (TPKEmoteProviderSnapshot *)publishProviderResult:(TPKEmoteCatalogResult *)result
                                            request:(TPKEmoteCatalogRequest *)request
                                            loading:(BOOL)loading {
    TPKEmoteProviderSnapshot *previous = self.snapshots[@(request.provider)];
    BOOL keepChannel = request.global
        ? (!previous.channelID.length || !self.activeChannelID.length ||
           [previous.channelID caseInsensitiveCompare:self.activeChannelID] == NSOrderedSame)
        : (previous.channelID.length &&
           [previous.channelID caseInsensitiveCompare:request.scope] == NSOrderedSame);
    NSArray<TPKEmoteSection *> *existing = previous.sections ?: @[];
    if (!keepChannel)
        existing = [self sectionsByCombining:@[] withExisting:existing global:NO];

    TPKEmoteProviderSnapshot *snapshot = [TPKEmoteProviderSnapshot new];
    snapshot.provider = request.provider;
    snapshot.channelID = request.global
        ? (keepChannel ? (previous.channelID ?: @"") : @"") : request.scope;
    if (!result || result.sections) {
        snapshot.state = loading ? TPKEmoteProviderStateLoading : TPKEmoteProviderStateLoaded;
        snapshot.sections = result
            ? [self sectionsByCombining:result.sections withExisting:existing global:request.global]
            : existing;
        if (!loading) self.lastSuccessfulLoads[request.taskKey] = [NSDate date];
    } else {
        snapshot.state = TPKEmoteProviderStateError;
        snapshot.sections = existing;
        snapshot.errorMessage = result.error.localizedDescription ?: @"Unable to load emotes";
    }
    self.snapshots[@(request.provider)] = snapshot;
    [self invalidateDerivedCachesForProvider:request.provider];
    [self postUpdateForProvider:request.provider];
    return snapshot;
}

- (void)loadProvider:(TPKEmoteProviderID)provider
              global:(BOOL)global
             channel:(NSString *)channel
          completion:(void (^)(TPKEmoteProviderSnapshot *))completion {
    if (!global && !channel.length) return;
    TPKEmoteCatalogRequest *request = [TPKEmoteCatalogRequest new];
    request.scope = global ? @"global" : channel;
    request.taskKey = [NSString stringWithFormat:@"%@:%@", TPKEmoteProviderKey(provider), request.scope];
    request.url = [self URLForProvider:provider global:global channel:channel];
    if (!request.url) return;
    request.provider = provider;
    request.global = global;
    dispatch_async(self.stateQueue, ^{
        if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame) return;
        TPKEmoteProviderSnapshot *current = self.snapshots[@(provider)];
        NSDate *lastSuccess = self.lastSuccessfulLoads[request.taskKey];
        BOOL matchesScope = global || [current.channelID caseInsensitiveCompare:channel] == NSOrderedSame;
        if (current.state == TPKEmoteProviderStateLoaded && lastSuccess &&
            matchesScope && -[lastSuccess timeIntervalSinceNow] < 300.0) {
            if (completion) {
                TPKEmoteProviderSnapshot *copy = [current copy];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(copy); });
            }
            return;
        }

        [self startCatalogRequest:request willStart:^{
            [self publishProviderResult:nil request:request loading:YES];
        } cached:^(TPKEmoteCatalogResult *cached) {
            [self publishProviderResult:cached request:request loading:YES];
            if (provider == TPKEmoteProviderIDTPK)
                [self loadTPKAdditionalSets:cached.discoveredSets global:global
                    channel:(global ? nil : channel) generation:request.generation
                    cacheEpoch:request.cacheEpoch requireActiveRequest:YES];
        } completion:^(TPKEmoteCatalogResult *result, NSData *data) {
            TPKEmoteProviderSnapshot *snapshot =
                [self publishProviderResult:result request:request loading:NO];
            if (provider == TPKEmoteProviderIDTPK && result.discoveredSets.count)
                [self loadTPKAdditionalSets:result.discoveredSets global:global
                    channel:(global ? nil : channel) generation:request.generation
                    cacheEpoch:request.cacheEpoch requireActiveRequest:NO];
            if (completion) {
                TPKEmoteProviderSnapshot *copy = [snapshot copy];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(copy); });
            }
        }];
    });
}

- (NSArray<TPKEmoteSection *> *)sectionsByCombining:(NSArray<TPKEmoteSection *> *)fresh
                                        withExisting:(NSArray<TPKEmoteSection *> *)existing
                                               global:(BOOL)global {
    NSMutableArray *combined = [fresh mutableCopy] ?: [NSMutableArray array];
    for (TPKEmoteSection *section in existing) {
        BOOL keepExisting = global
            ? (section.kind != TPKEmoteSectionKindGlobal)
            : (section.kind == TPKEmoteSectionKindGlobal ||
               [section.identifier hasPrefix:@"global-set:"]);
        if (!keepExisting) continue;
        BOOL duplicate = NO;
        for (TPKEmoteSection *candidate in combined) {
            if (candidate.provider == section.provider &&
                [candidate.identifier isEqualToString:section.identifier]) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate) [combined addObject:section];
    }
    return combined.copy;
}

- (void)cancelCatalogTaskForKey:(NSString *)key {
    id task = self.tasks[key];
    if ([task isKindOfClass:NSURLSessionDataTask.class])
        [(NSURLSessionDataTask *)task cancel];
    [self.tasks removeObjectForKey:key];
    self.requestGenerations[key] =
        @(self.requestGenerations[key].unsignedIntegerValue + 1);
}

- (void)cancelLoadsForChannel:(NSString *)channel {
    if (!channel.length) return;
    dispatch_async(self.stateQueue, ^{
        NSString *suffix = [NSString stringWithFormat:@":%@", channel];
        for (NSString *key in self.tasks.allKeys.copy)
            if ([key hasSuffix:suffix]) [self cancelCatalogTaskForKey:key];
    });
}

- (void)clearCachedDataWithCompletion:(dispatch_block_t)completion {
    dispatch_async(self.stateQueue, ^{
        self.cacheEpoch++;
        for (NSString *key in self.tasks.allKeys.copy) [self cancelCatalogTaskForKey:key];
        [self.lastSuccessfulLoads removeAllObjects];
        for (NSInteger provider = TPKEmoteProviderIDTPK;
             provider <= TPKEmoteProviderIDFFZ; provider++) {
            TPKEmoteProviderSnapshot *snapshot = [TPKEmoteProviderSnapshot new];
            snapshot.provider = (TPKEmoteProviderID)provider;
            snapshot.state = TPKEmoteProviderStateIdle;
            snapshot.channelID = self.activeChannelID ?: @"";
            snapshot.sections = @[];
            self.snapshots[@(provider)] = snapshot;
            [self invalidateDerivedCachesForProvider:(TPKEmoteProviderID)provider];
            [self postUpdateForProvider:(TPKEmoteProviderID)provider];
        }

        NSString *directory = [self cacheDirectory];
        NSString *legacyDirectory = [directory.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"s7tv"];
        dispatch_async(self.ioQueue, ^{
            NSFileManager *manager = [NSFileManager defaultManager];
            for (NSString *path in @[directory ?: @"", legacyDirectory ?: @""]) {
                if (!path.length) continue;
                for (NSString *file in [manager contentsOfDirectoryAtPath:path error:NULL]) {
                    [manager removeItemAtPath:[path stringByAppendingPathComponent:file]
                                        error:NULL];
                }
            }
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        });
    });
}

- (void)postUpdateForProvider:(TPKEmoteProviderID)provider {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKProviderCatalogDidUpdateNotification
                          object:self userInfo:@{@"provider": @(provider)}];
    });
}

- (NSArray<TPKEmoteSection *> *)sectionsFromObject:(id)object
                                            provider:(TPKEmoteProviderID)provider
                                               global:(BOOL)global
                                              channel:(NSString *)channel
                                              setIDs:(NSOrderedSet<NSString *> *)setIDs
                                                error:(NSError **)error {
    // Reject valid JSON with an unrelated top-level shape.
    BOOL validShape = NO;
    if (provider == TPKEmoteProviderIDTPK) {
        if ([object isKindOfClass:NSDictionary.class]) {
            id set = object[@"emote_set"] ?: object[@"emoteSet"] ?: object[@"set"];
            id additionalSets = object[@"emote_sets"] ?: object[@"sets"];
            BOOL directPayload = TPKDictionaryHasDirectEmoteCollection((NSDictionary *)object);
            BOOL setIdentifierHasPayload = [set isKindOfClass:NSString.class] &&
                TPKFindSetDictionary(additionalSets, set) != nil;
            BOOL hasSetIdentifier = setIDs.count > 0;
            validShape = global
                ? (directPayload ||
                   [set isKindOfClass:NSDictionary.class] || setIdentifierHasPayload ||
                   hasSetIdentifier || TPKSetContainerHasEmotePayload(additionalSets))
                : (directPayload || [set isKindOfClass:NSDictionary.class] || set == NSNull.null ||
                   setIdentifierHasPayload || hasSetIdentifier ||
                   TPKSetContainerHasEmotePayload(additionalSets));
        }
    } else if (provider == TPKEmoteProviderIDBTTV) {
        if (global) {
            validShape = [object isKindOfClass:NSArray.class] ||
                ([object isKindOfClass:NSDictionary.class] &&
                 [object[@"emotes"] isKindOfClass:NSArray.class]);
        } else if ([object isKindOfClass:NSDictionary.class]) {
            validShape = [object[@"channelEmotes"] isKindOfClass:NSArray.class] ||
                [object[@"sharedEmotes"] isKindOfClass:NSArray.class] ||
                // Older BTTV payloads may use the generic `emotes` key.
                [object[@"emotes"] isKindOfClass:NSArray.class];
        }
    } else if (provider == TPKEmoteProviderIDFFZ) {
        validShape = [object isKindOfClass:NSDictionary.class] &&
            [object[@"sets"] isKindOfClass:NSDictionary.class];
    }
    if (!validShape) {
        TPKSetCatalogStructureError(error, provider);
        return nil;
    }
    switch (provider) {
        case TPKEmoteProviderIDTPK: return [self sevenTVSectionsFromObject:object global:global];
        case TPKEmoteProviderIDBTTV: return [self bttvSectionsFromObject:object global:global];
        case TPKEmoteProviderIDFFZ: return [self ffzSectionsFromObject:object global:global];
    }
    return nil;
}

- (TPKEmoteSection *)sevenTVSectionFromSet:(NSDictionary *)set
                                      global:(BOOL)global
                                 sectionKind:(TPKEmoteSectionKind)kind
                             sectionIdentifier:(NSString *)identifier
                                      title:(NSString *)title {
    (void)global;
    if (![set isKindOfClass:NSDictionary.class]) return nil;
    NSArray *raw = TPKEmoteEntriesFromSet(set);
    NSMutableArray *emotes = [NSMutableArray array];
    for (id rawEntry in raw) {
        NSDictionary *entry = [rawEntry isKindOfClass:NSDictionary.class] ? rawEntry : nil;
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        // Normalize REST and GraphQL-style set entries here.
        NSDictionary *nestedEmote = [entry[@"emote"] isKindOfClass:NSDictionary.class]
            ? entry[@"emote"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:NSDictionary.class]
            ? entry[@"data"] : (nestedEmote ?: entry);
        NSString *eid = TPKString(nestedEmote[@"id"]) ?:
            TPKString(data[@"id"]) ?: TPKString(entry[@"id"]);
        NSString *name = TPKString(entry[@"name"]) ?: TPKString(entry[@"alias"]) ?:
            TPKString(data[@"name"]) ?: TPKString(data[@"defaultName"]);
        NSDictionary *host = [data[@"host"] isKindOfClass:NSDictionary.class] ? data[@"host"] : @{};
        NSMutableDictionary *urls = [NSMutableDictionary dictionary];
        NSMutableDictionary *formats = [NSMutableDictionary dictionary];
        NSArray *files = [host[@"files"] isKindOfClass:NSArray.class] ? host[@"files"] : @[];
        NSInteger width = TPKInteger(data[@"width"]), height = TPKInteger(data[@"height"]);
        BOOL animatedFromFiles = NO;
        for (id rawFile in files) {
            // Accept both filename strings and metadata dictionaries in host.files.
            NSString *fileName = nil;
            NSInteger fileWidth = 0;
            NSInteger fileHeight = 0;
            if ([rawFile isKindOfClass:NSString.class]) {
                fileName = rawFile;
            } else if ([rawFile isKindOfClass:NSDictionary.class]) {
                NSDictionary *file = (NSDictionary *)rawFile;
                fileName = TPKString(file[@"name"]) ?: TPKString(file[@"path"]);
                fileWidth = TPKInteger(file[@"width"]);
                fileHeight = TPKInteger(file[@"height"]);
                if (TPKInteger(file[@"frame_count"]) > 1 ||
                    TPKInteger(file[@"frameCount"]) > 1) {
                    animatedFromFiles = YES;
                }
            }
            NSString *hostURL = TPKString(host[@"url"]);
            if (!hostURL.length || !fileName.length) continue;
            if ([hostURL hasPrefix:@"//"]) hostURL = [@"https:" stringByAppendingString:hostURL];
            if ([hostURL hasSuffix:@"/"]) hostURL = [hostURL substringToIndex:hostURL.length - 1];
            NSInteger scale = 0;
            NSScanner *scanner = [NSScanner scannerWithString:fileName];
            [scanner scanInteger:&scale];
            TPKSevenTVAddImage(formats, [NSString stringWithFormat:@"%@/%@", hostURL, fileName], scale);
            if (!width) width = fileWidth;
            if (!height) height = fileHeight;
        }
        // Accept normalized image objects as well as legacy host/files data.
        NSArray *images = [data[@"images"] isKindOfClass:NSArray.class]
            ? data[@"images"] : @[];
        for (NSDictionary *image in images) {
            if (![image isKindOfClass:NSDictionary.class]) continue;
            NSString *imageURL = TPKString(image[@"url"]);
            NSInteger scale = TPKInteger(image[@"scale"]);
            if ([imageURL hasPrefix:@"//"])
                imageURL = [@"https:" stringByAppendingString:imageURL];
            TPKSevenTVAddImage(formats, imageURL, scale);
            if (!width) width = TPKInteger(image[@"width"]);
            if (!height) height = TPKInteger(image[@"height"]);
        }
        // Preserve aspectRatio when dimensions are unavailable.
        CGFloat aspectRatio = TPKDouble(data[@"aspectRatio"]);
        if (aspectRatio <= 0.0) aspectRatio = TPKDouble(data[@"aspect_ratio"]);
        if (aspectRatio <= 0.0) aspectRatio = TPKDouble(entry[@"aspectRatio"]);
        if (aspectRatio <= 0.0) aspectRatio = TPKDouble(nestedEmote[@"aspectRatio"]);
        if (aspectRatio > 0.0 && (width <= 0 || height <= 0)) {
            if (width > 0) {
                height = MAX(1, (NSInteger)llround((CGFloat)width / aspectRatio));
            } else if (height > 0) {
                width = MAX(1, (NSInteger)llround((CGFloat)height * aspectRatio));
            } else {
                height = 32;
                width = MAX(1, (NSInteger)llround((CGFloat)height * aspectRatio));
            }
        }
        if (!eid.length || !name.length) continue;
        NSInteger dataFlags = TPKInteger(data[@"flags"]);
        NSInteger entryFlags = TPKInteger(entry[@"flags"]);
        // Read Zero-Width from legacy and current 7TV flag formats.
        NSDictionary *entryFlagObject = [entry[@"flags"] isKindOfClass:NSDictionary.class]
            ? entry[@"flags"] : @{};
        NSDictionary *dataFlagObject = [data[@"flags"] isKindOfClass:NSDictionary.class]
            ? data[@"flags"] : @{};
        NSDictionary *nestedFlagObject = [nestedEmote[@"flags"] isKindOfClass:NSDictionary.class]
            ? nestedEmote[@"flags"] : @{};
        BOOL zeroWidth = TPKBool(entry[@"zeroWidth"]) ||
            TPKBool(entry[@"zero_width"]) ||
            TPKBool(entry[@"defaultZeroWidth"]) ||
            TPKBool(entry[@"default_zero_width"]) ||
            TPKBool(data[@"zeroWidth"]) ||
            TPKBool(data[@"zero_width"]) ||
            TPKBool(data[@"defaultZeroWidth"]) ||
            TPKBool(data[@"default_zero_width"]) ||
            TPKBool(entryFlagObject[@"zeroWidth"]) ||
            TPKBool(entryFlagObject[@"zero_width"]) ||
            TPKBool(entryFlagObject[@"defaultZeroWidth"]) ||
            TPKBool(entryFlagObject[@"default_zero_width"]) ||
            TPKBool(dataFlagObject[@"zeroWidth"]) ||
            TPKBool(dataFlagObject[@"zero_width"]) ||
            TPKBool(dataFlagObject[@"defaultZeroWidth"]) ||
            TPKBool(dataFlagObject[@"default_zero_width"]) ||
            TPKBool(nestedFlagObject[@"defaultZeroWidth"]) ||
            TPKBool(nestedFlagObject[@"zeroWidth"]) ||
            TPKBool(nestedFlagObject[@"zero_width"]) ||
            ((entryFlags & 1) != 0) || ((entryFlags & (1 << 8)) != 0) ||
            ((dataFlags & (1 << 1)) != 0) ||
            ((dataFlags & (1 << 8)) != 0);
        BOOL animated = TPKBool(data[@"animated"]) ||
            TPKBool(entry[@"animated"]) ||
            TPKBool(dataFlagObject[@"animated"]) ||
            TPKBool(nestedFlagObject[@"animated"]) ||
            // Active-set bit 0 means Zero-Width, unlike EmoteFlagsModel.
            ((dataFlags & 1) != 0) || animatedFromFiles;
        for (NSDictionary *image in images) {
            if (TPKInteger(image[@"frameCount"]) > 1 ||
                TPKBool(image[@"animated"])) {
                animated = YES;
                break;
            }
        }
        // Merge the preferred format last, independently for each resolution.
        for (NSString *format in animated ? @[@"webp", @"gif"] : @[@"png", @"webp"])
            if (formats[format]) [urls addEntriesFromDictionary:formats[format]];
        if (!urls.count) continue;
        [emotes addObject:[[TPKEmoteDescriptor alloc]
            initWithProvider:TPKEmoteProviderIDTPK providerIdentifier:@"7tv"
            emoteID:eid name:name aliases:@[] sectionKind:kind sectionIdentifier:identifier
            sectionTitle:title setID:TPKString(set[@"id"])
            nativeSize:CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1)
            animated:animated
            zeroWidth:zeroWidth
            modifierMetadata:@{ @"flags": @(dataFlags), @"entryFlags": @(entryFlags) }
            imageURLs:urls]];
    }
    if (!emotes.count) return nil;
    return [[TPKEmoteSection alloc]
        initWithProvider:TPKEmoteProviderIDTPK
        kind:kind identifier:identifier title:title emotes:emotes
        loaded:YES loading:NO errorMessage:nil];
}

- (NSArray<TPKEmoteSection *> *)sevenTVSectionsFromObject:(id)object global:(BOOL)global {
    NSDictionary *root = [object isKindOfClass:NSDictionary.class] ? object : nil;
    if (!root) return @[];

    NSMutableArray<TPKEmoteSection *> *sections = [NSMutableArray array];
    NSDictionary *primarySet = nil;
    id rawPrimary = root[@"emote_set"] ?: root[@"emoteSet"] ?: root[@"set"];
    id rawAdditionalSets = root[@"emote_sets"] ?: root[@"sets"];
    if ([rawPrimary isKindOfClass:NSDictionary.class]) {
        primarySet = rawPrimary;
    } else if (TPKDictionaryHasDirectEmoteCollection(root)) {
        // The global endpoint commonly returns the set object directly.
        primarySet = root;
    } else if ([rawPrimary isKindOfClass:NSString.class]) {
        primarySet = TPKFindSetDictionary(rawAdditionalSets, rawPrimary);
        if (primarySet && !TPKString(primarySet[@"id"]).length) {
            NSMutableDictionary *withIdentifier = [primarySet mutableCopy];
            withIdentifier[@"id"] = rawPrimary;
            primarySet = withIdentifier.copy;
        }
    } else if ([rawAdditionalSets isKindOfClass:NSDictionary.class] &&
               TPKDictionaryHasDirectEmoteCollection((NSDictionary *)rawAdditionalSets)) {
        // Parse a direct `sets` payload before the optional set request completes.
        primarySet = rawAdditionalSets;
    } else if (!rawPrimary) {
        // ID-only responses load their set asynchronously.
    }

    // Prefer a complete active set in the Twitch connection over an ID placeholder.
    if (!global && (!primarySet || !TPKDictionaryHasDirectEmoteCollection(primarySet))) {
        NSDictionary *connectionSet = TPKConnectionSetWithPayload(root[@"connections"]);
        if (connectionSet) primarySet = connectionSet;
    }

    if (primarySet && !TPKString(primarySet[@"id"]).length) {
        NSString *fallbackID = TPKString(rawPrimary);
        if (!fallbackID.length) fallbackID = TPKActiveSetIDFromObject(root);
        if (fallbackID.length) {
            NSMutableDictionary *withIdentifier = [primarySet mutableCopy];
            withIdentifier[@"id"] = fallbackID;
            primarySet = withIdentifier.copy;
        }
    }

    NSString *primaryID = TPKString(primarySet[@"id"]);
    if (primarySet) {
        TPKEmoteSectionKind kind = global
            ? TPKEmoteSectionKindGlobal : TPKEmoteSectionKindChannel;
        NSString *identifier = global ? @"global" : @"channel";
        NSString *title = global ? @"Global Emotes" : @"Channel Emotes";
        TPKEmoteSection *section = [self sevenTVSectionFromSet:primarySet
                                                            global:global
                                                       sectionKind:kind
                                                   sectionIdentifier:identifier
                                                            title:title];
        if (section) [sections addObject:section];
    }

    // Expose additional sets supplied in `emote_sets` or `sets`.
    if ([rawAdditionalSets isKindOfClass:NSDictionary.class]) {
        NSDictionary *directSet = (NSDictionary *)rawAdditionalSets;
        BOOL isDirectSet = TPKDictionaryHasDirectEmoteCollection(directSet);
        if (isDirectSet && directSet != primarySet) {
            NSString *setID = TPKString(directSet[@"id"]);
            if (!setID.length || ![setID isEqualToString:primaryID]) {
                NSString *identifier = setID.length
                    ? TPKSetSectionIdentifier(setID, global) : @"set:additional";
                NSString *title = TPKString(directSet[@"name"]) ?: @"Emote Set";
                TPKEmoteSection *section = [self sevenTVSectionFromSet:directSet
                                                                    global:NO
                                                               sectionKind:TPKEmoteSectionKindSet
                                                           sectionIdentifier:identifier
                                                                    title:title];
                if (section) [sections addObject:section];
            }
        } else {
            [directSet enumerateKeysAndObjectsUsingBlock:
                ^(id key, id value, BOOL *stop) {
                if (![value isKindOfClass:NSDictionary.class]) return;
                NSDictionary *set = value;
                NSString *setID = TPKString(set[@"id"]) ?: TPKString(key);
                if (setID.length && [setID isEqualToString:primaryID]) return;
                if (!setID.length) return;
                if (!TPKString(set[@"id"]).length) {
                    NSMutableDictionary *withIdentifier = [set mutableCopy];
                    withIdentifier[@"id"] = setID;
                    set = withIdentifier.copy;
                }
                NSString *identifier = TPKSetSectionIdentifier(setID, global);
                NSString *title = TPKString(set[@"name"]) ?: @"Emote Set";
                TPKEmoteSection *section = [self sevenTVSectionFromSet:set
                                                                    global:NO
                                                               sectionKind:TPKEmoteSectionKindSet
                                                           sectionIdentifier:identifier
                                                                    title:title];
                if (section) [sections addObject:section];
            }];
        }
    } else if ([rawAdditionalSets isKindOfClass:NSArray.class]) {
        NSUInteger index = 0;
        for (id value in (NSArray *)rawAdditionalSets) {
            if (![value isKindOfClass:NSDictionary.class]) { index++; continue; }
            NSDictionary *set = value;
            NSString *setID = TPKString(set[@"id"]);
            if (setID.length && [setID isEqualToString:primaryID]) { index++; continue; }
            if (!setID.length) setID = [NSString stringWithFormat:@"index:%lu", (unsigned long)index];
            NSString *identifier = TPKSetSectionIdentifier(setID, global);
            NSString *title = TPKString(set[@"name"]) ?: @"Emote Set";
            TPKEmoteSection *section = [self sevenTVSectionFromSet:set
                                                                global:NO
                                                           sectionKind:TPKEmoteSectionKindSet
                                                       sectionIdentifier:identifier
                                                                title:title];
            if (section) [sections addObject:section];
            index++;
        }
    }
    return sections.copy;
}

- (NSArray<TPKEmoteSection *> *)sevenTVSetSectionsFromObject:(id)object
                                                     requestedID:(NSString *)requestedID
                                                     asPrimary:(BOOL)asPrimary
                                                       global:(BOOL)global {
    NSDictionary *root = [object isKindOfClass:NSDictionary.class] ? object : nil;
    if (!root) return @[];
    NSDictionary *set = [root[@"emote_set"] isKindOfClass:NSDictionary.class]
        ? root[@"emote_set"]
        : ([root[@"emoteSet"] isKindOfClass:NSDictionary.class]
            ? root[@"emoteSet"] : root);
    if (!TPKDictionaryHasDirectEmoteCollection(set)) {
        NSDictionary *wrapped = [root[@"set"] isKindOfClass:NSDictionary.class]
            ? root[@"set"] : nil;
        if (TPKDictionaryHasDirectEmoteCollection(wrapped)) set = wrapped;
    }
    if (!TPKDictionaryHasDirectEmoteCollection(set)) return @[];
    NSString *setID = TPKString(set[@"id"]) ?: requestedID;
    if (!setID.length) return @[];
    NSString *title = asPrimary
        ? (global ? @"Global Emotes" : @"Channel Emotes")
        : (TPKString(set[@"name"]) ?: @"Emote Set");
    TPKEmoteSectionKind kind = asPrimary
        ? (global ? TPKEmoteSectionKindGlobal : TPKEmoteSectionKindChannel)
        : TPKEmoteSectionKindSet;
    NSString *identifier = asPrimary
        ? (global ? @"global" : @"channel")
        : TPKSetSectionIdentifier(setID, global);
    TPKEmoteSection *section = [self sevenTVSectionFromSet:set
                                                       global:global
                                                  sectionKind:kind
                                              sectionIdentifier:identifier
                                                       title:title];
    return section ? @[section] : @[];
}

- (NSArray<TPKEmoteSection *> *)bttvSectionsFromObject:(id)object global:(BOOL)global {
    NSArray *(^arrayForKey)(NSString *) = ^NSArray *(NSString *key) {
        id value = [object isKindOfClass:NSDictionary.class] ? object[key] : nil;
        return [value isKindOfClass:NSArray.class] ? value : @[];
    };
    NSMutableArray *sections = [NSMutableArray array];
    NSArray *globalValues = [object isKindOfClass:NSArray.class] ? object : arrayForKey(@"emotes");
    NSArray *channelValues = arrayForKey(@"channelEmotes");
    // Accept BTTV channel lists under `channelEmotes` or `emotes`.
    if (!channelValues.count) channelValues = arrayForKey(@"emotes");
    NSArray *sharedValues = arrayForKey(@"sharedEmotes");
    NSArray *groups = global ? @[@[@"global", @"Global Emotes", globalValues]]
                             : @[@[@"channel", @"Channel Emotes", channelValues],
                                 @[@"shared", @"Shared Emotes", sharedValues]];
    for (NSArray *group in groups) {
        NSMutableArray *emotes = [NSMutableArray array];
        for (NSDictionary *raw in group[2]) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            // Reserve effect-like entries for the v2 UI.
            if (TPKBool(raw[@"modifier"]) || TPKBool(raw[@"isModifier"])) continue;
            NSString *eid = TPKString(raw[@"id"]), *name = TPKString(raw[@"code"]);
            if (!eid.length || !name.length) continue;
            NSMutableDictionary *urls = [NSMutableDictionary dictionary];
            for (NSInteger scale = 1; scale <= 4; scale++) {
                // BTTV provides 1x/2x/3x assets.
                if (scale == 4) break;
                urls[@(scale)] = [NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/%ldx", eid, (long)scale];
            }
            NSInteger width = TPKInteger(raw[@"width"]), height = TPKInteger(raw[@"height"]);
            NSString *imageType = TPKString(raw[@"imageType"]);
            BOOL animated = TPKBool(raw[@"animated"]) ||
                (imageType.length &&
                 [imageType caseInsensitiveCompare:@"gif"] == NSOrderedSame);
            [emotes addObject:[[TPKEmoteDescriptor alloc]
                initWithProvider:TPKEmoteProviderIDBTTV providerIdentifier:@"bttv"
                emoteID:eid name:name aliases:TPKAliases(raw[@"aliases"])
                sectionKind:([group[0] isEqual:@"shared"] ? TPKEmoteSectionKindShared :
                             (global ? TPKEmoteSectionKindGlobal : TPKEmoteSectionKindChannel))
                sectionIdentifier:group[0] sectionTitle:group[1] setID:nil
                nativeSize:CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1)
                animated:animated zeroWidth:NO modifierMetadata:@{} imageURLs:urls]];
        }
        if (emotes.count) [sections addObject:[[TPKEmoteSection alloc]
            initWithProvider:TPKEmoteProviderIDBTTV
            kind:([group[0] isEqual:@"shared"] ? TPKEmoteSectionKindShared :
                  (global ? TPKEmoteSectionKindGlobal : TPKEmoteSectionKindChannel))
            identifier:group[0] title:group[1] emotes:emotes loaded:YES loading:NO errorMessage:nil]];
    }
    return sections.copy;
}

- (NSArray<TPKEmoteSection *> *)ffzSectionsFromObject:(id)object global:(BOOL)global {
    NSDictionary *sets = [object isKindOfClass:NSDictionary.class] ? object[@"sets"] : nil;
    if (![sets isKindOfClass:NSDictionary.class]) return @[];
    // Expose only FFZ default sets without authentication.
    NSMutableSet<NSString *> *defaultGlobalSetIDs = [NSMutableSet set];
    id rawDefaultSets = [object isKindOfClass:NSDictionary.class]
        ? object[@"default_sets"] : nil;
    if ([rawDefaultSets isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)rawDefaultSets)
            if (value) [defaultGlobalSetIDs addObject:[NSString stringWithFormat:@"%@", value]];
    }
    NSDictionary *room = [object isKindOfClass:NSDictionary.class]
        ? ([object[@"room"] isKindOfClass:NSDictionary.class] ? object[@"room"] : nil)
        : nil;
    id rawRoomSet = room[@"set"];
    // Normalize numeric and string FFZ room-set IDs.
    NSString *roomSet = TPKString(rawRoomSet);
    if (!roomSet.length && [rawRoomSet isKindOfClass:NSDictionary.class])
        roomSet = TPKString(rawRoomSet[@"id"]);
    if (!roomSet.length && rawRoomSet)
        roomSet = [NSString stringWithFormat:@"%@", rawRoomSet];
    NSMutableArray *sections = [NSMutableArray array];
    // Merge FFZ default sets into one global section.
    NSMutableArray *globalEmotes = global ? [NSMutableArray array] : nil;
    [sets enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        NSString *setKey = [NSString stringWithFormat:@"%@", key ?: @""];
        if (global && defaultGlobalSetIDs.count &&
            ![defaultGlobalSetIDs containsObject:setKey]) return;
        if (![value isKindOfClass:NSDictionary.class]) return;
        NSArray *rawEmotes = [value[@"emoticons"] isKindOfClass:NSArray.class] ? value[@"emoticons"] : value[@"emotes"];
        if (![rawEmotes isKindOfClass:NSArray.class]) return;
        NSMutableArray *emotes = [NSMutableArray array];
        for (NSDictionary *raw in rawEmotes) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            // Reserve FFZ effects for the v2 modifier UI.
            if (TPKBool(raw[@"modifier"]) || TPKBool(raw[@"isModifier"])) continue;
            NSString *eid = [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""];
            NSString *name = TPKString(raw[@"name"]);
            if (!eid.length || !name.length) continue;
            NSMutableDictionary *urls = [TPKURLMap(raw[@"urls"]) mutableCopy];
            // Keep FFZ animated URLs alongside static assets.
            NSDictionary *animatedURLs = TPKURLMap(raw[@"animated"]);
            if (animatedURLs.count) [urls addEntriesFromDictionary:animatedURLs];
            BOOL animated = animatedURLs.count > 0 || TPKBool(raw[@"animated"]);
            NSInteger width = TPKInteger(raw[@"width"]), height = TPKInteger(raw[@"height"]);
            TPKEmoteSectionKind kind = global ? TPKEmoteSectionKindGlobal
                : ([setKey isEqualToString:roomSet] ? TPKEmoteSectionKindChannel : TPKEmoteSectionKindSet);
            NSString *title = global ? @"Global Emotes" :
                ([setKey isEqualToString:roomSet] ? @"Channel Emotes" :
                 (TPKString(value[@"name"]) ?: TPKString(value[@"title"]) ?: @"Emote Set"));
            [emotes addObject:[[TPKEmoteDescriptor alloc]
                initWithProvider:TPKEmoteProviderIDFFZ providerIdentifier:@"ffz"
                emoteID:eid name:name aliases:TPKAliases(raw[@"aliases"])
                sectionKind:kind sectionIdentifier:(global ? @"global" :
                    [NSString stringWithFormat:@"set:%@", setKey])
                sectionTitle:title setID:setKey
                nativeSize:CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1)
                animated:animated zeroWidth:NO
                modifierMetadata:@{ @"flags": raw[@"flags"] ?: @0 } imageURLs:urls]];
        }
        if (global) {
            [globalEmotes addObjectsFromArray:emotes];
            return;
        }
        if (emotes.count) {
            TPKEmoteSectionKind kind =
                ([setKey isEqualToString:roomSet] ? TPKEmoteSectionKindChannel : TPKEmoteSectionKindSet);
            NSString *title =
                ([setKey isEqualToString:roomSet] ? @"Channel Emotes" :
                 (TPKString(value[@"name"]) ?: TPKString(value[@"title"]) ?: @"Emote Set"));
            [sections addObject:[[TPKEmoteSection alloc]
                initWithProvider:TPKEmoteProviderIDFFZ kind:kind
                identifier:[NSString stringWithFormat:@"set:%@", setKey] title:title emotes:emotes
            loaded:YES loading:NO errorMessage:nil]];
        }
    }];
    if (globalEmotes.count) {
        [sections insertObject:[[TPKEmoteSection alloc]
            initWithProvider:TPKEmoteProviderIDFFZ kind:TPKEmoteSectionKindGlobal
                  identifier:@"global" title:@"Global Emotes" emotes:globalEmotes
                    loaded:YES loading:NO errorMessage:nil] atIndex:0];
    }
    return sections.copy;
}

- (BOOL)isEmoteFavorited:(TPKEmoteDescriptor *)emote {
    if (!emote.emoteID.length) return NO;
    return [[self favoriteKeysSnapshot] containsObject:
        TPKEmoteFavoriteKey(emote.provider, emote.emoteID)];
}

- (NSMutableArray<NSString *> *)mutableFavoriteKeys {
    return [[self favoriteKeysSnapshot] mutableCopy] ?: [NSMutableArray array];
}

- (void)storeFavoriteKeys:(NSArray<NSString *> *)favoriteKeys {
    [NSUserDefaults.standardUserDefaults setObject:favoriteKeys.copy
                                            forKey:@"tpk_favorites_v2"];
}

- (void)updateFavoriteKey:(NSString *)key favorited:(BOOL)favorited {
    NSMutableArray<NSString *> *favorites = [self mutableFavoriteKeys];
    [favorites removeObject:key];
    if (favorited) [favorites addObject:key];
    [self storeFavoriteKeys:favorites];
}

- (NSMutableDictionary<NSString *, NSDictionary *> *)mutableFavoriteMetadata {
    id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kTPKFavoriteMetadataKey];
    return [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)storeFavoriteMetadata:(NSDictionary<NSString *, NSDictionary *> *)metadata {
    [NSUserDefaults.standardUserDefaults setObject:metadata.copy
                                            forKey:kTPKFavoriteMetadataKey];
}

- (void)updateFavoriteMetadataForKey:(NSString *)key
                               value:(NSDictionary *)value
                              remove:(BOOL)remove {
    NSMutableDictionary *metadata = [self mutableFavoriteMetadata];
    if (remove) [metadata removeObjectForKey:key];
    else if (value) metadata[key] = value;
    [self storeFavoriteMetadata:metadata];
}

- (void)removeFavoriteMetadataForKeys:(NSArray<NSString *> *)keys {
    NSMutableDictionary *metadata = [self mutableFavoriteMetadata];
    BOOL changed = NO;
    for (NSString *key in keys) {
        if (!metadata[key]) continue;
        [metadata removeObjectForKey:key];
        changed = YES;
    }
    if (changed) [self storeFavoriteMetadata:metadata];
}

- (void)removeFavoriteCompositionForKey:(NSString *)key {
    NSMutableDictionary *compositions = TPKMutableFavoriteCompositions();
    TPKRemoveFavoriteCompositionsContainingKey(compositions, key);
    TPKStoreFavoriteCompositions(compositions);
}

- (void)syncLegacyFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *legacy = [[defaults arrayForKey:@"tpk_favorites"] mutableCopy]
        ?: [NSMutableArray array];
    [legacy removeObject:emoteID];
    if (favorited) [legacy addObject:emoteID];
    [defaults setObject:legacy.copy forKey:@"tpk_favorites"];
}

- (void)notifyFavoriteChangeForProvider:(TPKEmoteProviderID)provider {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"TPKFavoritesDidChangeNotification" object:self];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKProviderCatalogDidUpdateNotification
                      object:self
                    userInfo:@{@"provider": @(provider), @"favorites": @YES}];
}

- (void)setEmote:(TPKEmoteDescriptor *)emote favorited:(BOOL)favorited {
    if (!emote.emoteID.length) return;
    NSString *key = TPKEmoteFavoriteKey(emote.provider, emote.emoteID);
    [self updateFavoriteKey:key favorited:favorited];
    [self updateFavoriteMetadataForKey:key
                                 value:(favorited ? TPKFavoriteMetadataForDescriptor(emote) : nil)
                                remove:!favorited];
    if (!favorited) [self removeFavoriteCompositionForKey:key];
    if (emote.provider == TPKEmoteProviderIDTPK)
        [self syncLegacyFavoriteID:emote.emoteID favorited:favorited];
    [self notifyFavoriteChangeForProvider:emote.provider];
}

- (void)setLegacyTPKFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited {
    if (!emoteID.length) return;
    NSString *key = TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emoteID);
    [self updateFavoriteKey:key favorited:favorited];

    // Preserve unloaded favorites and refresh them from later snapshots.
    TPKEmoteDescriptor *loadedDescriptor = nil;
    if (favorited) {
        for (TPKEmoteDescriptor *descriptor in
             [self allEmotesForProvider:TPKEmoteProviderIDTPK]) {
            if ([descriptor.emoteID isEqualToString:emoteID]) {
                loadedDescriptor = descriptor;
                break;
            }
        }
    }
    [self updateFavoriteMetadataForKey:key
                                 value:TPKFavoriteMetadataForDescriptor(loadedDescriptor)
                                remove:!favorited];
    if (!favorited) [self removeFavoriteCompositionForKey:key];
}

- (void)setFavoriteKey:(NSString *)favoriteKey favorited:(BOOL)favorited {
    if (!favoriteKey.length) return;
    NSRange separator = [favoriteKey rangeOfString:@":" options:0
                                              range:NSMakeRange(0, favoriteKey.length)];
    // Imports require provider:ID; only migration accepts bare legacy 7TV IDs.
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location == favoriteKey.length - 1) return;

    TPKEmoteProviderID provider;
    NSString *emoteID = nil;
    if (!TPKParseFavoriteKey(favoriteKey, &provider, &emoteID)) return;
    NSString *normalizedKey = TPKEmoteFavoriteKey(provider, emoteID);
    [self updateFavoriteKey:normalizedKey favorited:favorited];

    // Mirror qualified 7TV keys to the persistent legacy array.
    if (provider == TPKEmoteProviderIDTPK)
        [self syncLegacyFavoriteID:emoteID favorited:favorited];

    if (!favorited) {
        [self removeFavoriteMetadataForKeys:@[normalizedKey, favoriteKey]];
        [self removeFavoriteCompositionForKey:normalizedKey];
    }
    [self notifyFavoriteChangeForProvider:provider];
}

- (void)replaceLegacyTPKFavoriteIDs:(NSArray<NSString *> *)emoteIDs {
    NSMutableArray<NSString *> *favorites = [self mutableFavoriteKeys];
    NSMutableArray<NSString *> *withoutLegacy = [NSMutableArray arrayWithCapacity:favorites.count];
    for (NSString *key in favorites) {
        if (![key hasPrefix:@"7tv:"]) [withoutLegacy addObject:key];
    }

    NSMutableSet<NSString *> *seenIDs = [NSMutableSet set];
    for (id value in emoteIDs) {
        if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) continue;
        NSString *emoteID = value;
        if (![seenIDs containsObject:emoteID]) {
            [seenIDs addObject:emoteID];
            [withoutLegacy addObject:TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emoteID)];
        }
    }
    [self storeFavoriteKeys:withoutLegacy];

    // Preserve BTTV/FFZ metadata and refresh the 7TV replacement slice.
    NSMutableDictionary *favoriteMetadata = [self mutableFavoriteMetadata];
    for (NSString *metadataKey in favoriteMetadata.allKeys.copy) {
        TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
        NSString *metadataID = nil;
        if (!TPKParseFavoriteKey(metadataKey, &provider, &metadataID) ||
            (provider == TPKEmoteProviderIDTPK && ![seenIDs containsObject:metadataID])) {
            [favoriteMetadata removeObjectForKey:metadataKey];
        }
    }
    for (TPKEmoteDescriptor *descriptor in
         [self allEmotesForProvider:TPKEmoteProviderIDTPK]) {
        if (![seenIDs containsObject:descriptor.emoteID]) continue;
        NSString *key = TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, descriptor.emoteID);
        NSDictionary *metadata = TPKFavoriteMetadataForDescriptor(descriptor);
        if (metadata) favoriteMetadata[key] = metadata;
    }
    [self storeFavoriteMetadata:favoriteMetadata];
}

- (NSArray<NSString *> *)favoriteKeysSnapshot {
    return [self migrateLegacyFavoritesIfNeeded];
}

- (NSArray<TPKEmoteDescriptor *> *)favoriteDescriptorsSnapshot {
    NSArray<NSString *> *favoriteKeys = [self favoriteKeysSnapshot];
    if (!favoriteKeys.count) return @[];

    NSMutableDictionary<NSString *, NSDictionary *> *metadataByKey =
        [self mutableFavoriteMetadata];
    NSMutableDictionary<NSString *, TPKEmoteDescriptor *> *loadedByKey =
        [NSMutableDictionary dictionary];
    NSSet<NSString *> *favoriteSet = [NSSet setWithArray:favoriteKeys];

    // Refresh loaded metadata while preserving favorites from other channels.
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        for (TPKEmoteDescriptor *descriptor in
             [self allEmotesForProvider:(TPKEmoteProviderID)provider]) {
            NSString *key = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (!key.length || ![favoriteSet containsObject:key]) continue;
            loadedByKey[key] = descriptor;
            NSDictionary *metadata = TPKFavoriteMetadataForDescriptor(descriptor);
            if (metadata) metadataByKey[key] = metadata;
        }
    }
    [self storeFavoriteMetadata:metadataByKey];

    NSMutableArray<TPKEmoteDescriptor *> *result =
        [NSMutableArray arrayWithCapacity:favoriteKeys.count];
    for (NSString *key in favoriteKeys) {
        TPKEmoteDescriptor *descriptor = loadedByKey[key];
        if (!descriptor) {
            NSDictionary *metadata = [metadataByKey[key] isKindOfClass:NSDictionary.class]
                ? metadataByKey[key] : nil;
            descriptor = TPKDescriptorFromFavoriteMetadata(key, metadata);
        }
        if (descriptor) [result addObject:descriptor];
    }
    return result.copy;
}

- (NSString *)favoriteCompositionTextForEmoteKey:(NSString *)emoteKey {
    NSString *canonicalKey = TPKCanonicalFavoriteKey(emoteKey) ?: emoteKey;
    if (!canonicalKey.length) return nil;

    NSDictionary *compositions = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kTPKFavoriteCompositionsKey];
    if (![compositions isKindOfClass:NSDictionary.class]) return nil;

    id directValue = compositions[canonicalKey];
    NSString *(^textFromValue)(id) = ^NSString *(id value) {
        if (![value isKindOfClass:NSDictionary.class]) return nil;
        NSString *text = [value[@"text"] isKindOfClass:NSString.class]
            ? value[@"text"] : nil;
        return text.length ? text : nil;
    };
    NSString *directText = textFromValue(directValue);
    if (directText.length) return directText;

    // Resolve either composition member to the full chat text.
    for (id value in compositions.allValues) {
        if (!TPKFavoriteCompositionContainsKey(value, canonicalKey)) continue;
        NSString *text = textFromValue(value);
        if (text.length) return text;
    }
    return nil;
}

- (NSArray<NSString *> *)migrateLegacyFavoritesIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *existing = [defaults arrayForKey:@"tpk_favorites_v2"] ?: @[];
    NSArray *legacy = [defaults arrayForKey:@"tpk_favorites"] ?: @[];
    NSMutableArray<NSString *> *favorites = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // Preserve v2 order and append newly imported legacy IDs.
    for (id value in existing) {
        NSString *key = TPKCanonicalFavoriteKey(value);
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [favorites addObject:key];
    }
    for (id value in legacy) {
        NSString *emoteID = TPKString(value);
        if (!emoteID.length) continue;
        NSString *key = TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emoteID);
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [favorites addObject:key];
    }
    if (![existing isEqualToArray:favorites]) [self storeFavoriteKeys:favorites];
    return favorites.copy;
}

@end
