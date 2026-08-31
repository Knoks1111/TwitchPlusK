#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import <math.h>
#import <stdlib.h>

NSString *const S7TVProviderCatalogDidUpdateNotification =
    @"S7TVProviderCatalogDidUpdateNotification";

static NSString *const kS7TVFavoriteMetadataKey =
    @"s7tv_emote_favorite_metadata_v1";
static NSString *const kS7TVFavoriteCompositionsKey =
    @"s7tv_emote_favorite_compositions_v1";

NSString *S7TVEmoteProviderName(S7TVEmoteProviderID provider) {
    switch (provider) {
        case S7TVEmoteProviderIDSevenTV: return @"7TV";
        case S7TVEmoteProviderIDBTTV: return @"BTTV";
        case S7TVEmoteProviderIDFFZ: return @"FFZ";
    }
    return @"Unknown";
}

NSString *S7TVEmoteProviderKey(S7TVEmoteProviderID provider) {
    switch (provider) {
        case S7TVEmoteProviderIDSevenTV: return @"7tv";
        case S7TVEmoteProviderIDBTTV: return @"bttv";
        case S7TVEmoteProviderIDFFZ: return @"ffz";
    }
    return @"unknown";
}

NSString *S7TVEmoteFavoriteKey(S7TVEmoteProviderID provider, NSString *emoteID) {
    if (!emoteID.length) return @"";
    return [NSString stringWithFormat:@"%@:%@", S7TVEmoteProviderKey(provider), emoteID];
}

// UserDefaults is also populated by settings imports from older releases.
// Keep the catalogue boundary strict so malformed values (including
// non-NSString objects) can never reach UI code that parses favorite keys.
static NSString *S7TVCanonicalFavoriteKey(id value) {
    if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) return nil;
    NSString *raw = (NSString *)value;
    NSRange separator = [raw rangeOfString:@":" options:0 range:NSMakeRange(0, raw.length)];
    if (separator.location == NSNotFound) {
        // A bare ID is the legacy 7TV representation.  Accept it while the
        // migration settles so imports from intermediate builds remain usable.
        return S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, raw);
    }
    if (separator.location == 0 || separator.location == raw.length - 1) return nil;
    NSString *provider = [[raw substringToIndex:separator.location] lowercaseString];
    if (![provider isEqualToString:@"7tv"] &&
        ![provider isEqualToString:@"bttv"] &&
        ![provider isEqualToString:@"ffz"]) return nil;
    NSString *emoteID = [raw substringFromIndex:separator.location + 1];
    return emoteID.length ? [NSString stringWithFormat:@"%@:%@", provider, emoteID] : nil;
}

static NSString *S7TVString(id value);
static NSInteger S7TVInteger(id value);
static CGFloat S7TVDouble(id value);
static BOOL S7TVBool(id value);
static NSArray<NSString *> *S7TVAliases(id value);
static NSDictionary<NSNumber *, NSString *> *S7TVURLMap(id value);

// Set sections need to retain their source scope because the provider keeps
// global and channel sections in one snapshot.  The prefix is deliberately
// part of the stable section identifier so a lazy expansion can request the
// right endpoint even after a channel refresh.
static NSString *S7TVSetSectionIdentifier(NSString *setID, BOOL global) {
    if (!setID.length) return @"";
    return [NSString stringWithFormat:@"%@:%@", global ? @"global-set" : @"set", setID];
}

static NSString *S7TVSetIDFromSectionIdentifier(NSString *identifier, BOOL *globalOut) {
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

static BOOL S7TVParseFavoriteKey(NSString *key,
                                 S7TVEmoteProviderID *providerOut,
                                 NSString **emoteIDOut) {
    NSString *canonical = S7TVCanonicalFavoriteKey(key);
    if (!canonical.length) return NO;
    NSRange separator = [canonical rangeOfString:@":" options:0
                                             range:NSMakeRange(0, canonical.length)];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location == canonical.length - 1) return NO;
    NSString *providerKey = [canonical substringToIndex:separator.location];
    S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
    if ([providerKey isEqualToString:@"bttv"]) provider = S7TVEmoteProviderIDBTTV;
    else if ([providerKey isEqualToString:@"ffz"]) provider = S7TVEmoteProviderIDFFZ;
    else if (![providerKey isEqualToString:@"7tv"]) return NO;
    if (providerOut) *providerOut = provider;
    if (emoteIDOut) *emoteIDOut = [canonical substringFromIndex:separator.location + 1];
    return YES;
}

static NSDictionary *S7TVFavoriteMetadataForDescriptor(S7TVEmoteDescriptor *descriptor) {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"provider"] = @(descriptor.provider);
    metadata[@"providerIdentifier"] = descriptor.providerIdentifier ?: S7TVEmoteProviderKey(descriptor.provider);
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

    // NSUserDefaults property-list dictionaries require string keys. The
    // runtime descriptor uses NSNumber scale keys, so normalize them while
    // keeping every URL available for the shared resolution fallback.
    NSMutableDictionary *urls = [NSMutableDictionary dictionary];
    [descriptor.imageURLs enumerateKeysAndObjectsUsingBlock:^(NSNumber *scale, NSString *url, BOOL *stop) {
        if ([scale respondsToSelector:@selector(integerValue)] && url.length)
            urls[[scale stringValue]] = url;
    }];
    metadata[@"imageURLs"] = urls.copy;
    // Modifier metadata is intentionally retained for the v2 effects UI when
    // it is a property-list-safe dictionary. Invalid/non-plist values are
    // simply omitted; v1 never depends on them to render the emote.
    if (descriptor.modifierMetadata.count &&
        [NSPropertyListSerialization propertyList:descriptor.modifierMetadata
                               isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        metadata[@"modifierMetadata"] = descriptor.modifierMetadata;
    }
    return metadata.copy;
}

static BOOL S7TVFavoriteCompositionContainsKey(id value, NSString *emoteKey) {
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

static void S7TVRemoveFavoriteCompositionsContainingKey(
    NSMutableDictionary<NSString *, NSDictionary *> *compositions,
    NSString *emoteKey) {
    if (!compositions || !emoteKey.length) return;
    for (NSString *baseKey in compositions.allKeys.copy) {
        if (S7TVFavoriteCompositionContainsKey(compositions[baseKey], emoteKey))
            [compositions removeObjectForKey:baseKey];
    }
}

static NSMutableDictionary<NSString *, NSDictionary *> *S7TVMutableFavoriteCompositions(void) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kS7TVFavoriteCompositionsKey];
    return [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void S7TVStoreFavoriteCompositions(
    NSMutableDictionary<NSString *, NSDictionary *> *compositions) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (compositions.count) [defaults setObject:compositions.copy
                                         forKey:kS7TVFavoriteCompositionsKey];
    else [defaults removeObjectForKey:kS7TVFavoriteCompositionsKey];
}

static S7TVEmoteDescriptor *S7TVDescriptorFromFavoriteMetadata(NSString *favoriteKey,
                                                               NSDictionary *metadata) {
    S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
    NSString *emoteID = nil;
    if (!S7TVParseFavoriteKey(favoriteKey, &provider, &emoteID) || !metadata.count)
        return nil;
    NSString *metadataID = S7TVString(metadata[@"id"]);
    if (metadataID.length && ![metadataID isEqualToString:emoteID]) return nil;
    NSString *name = S7TVString(metadata[@"name"]);
    if (!name.length) return nil;
    NSInteger kindValue = S7TVInteger(metadata[@"sectionKind"]);
    if (kindValue < S7TVEmoteSectionKindChannel || kindValue > S7TVEmoteSectionKindFavorites)
        kindValue = S7TVEmoteSectionKindSet;
    NSDictionary *rawURLs = [metadata[@"imageURLs"] isKindOfClass:NSDictionary.class]
        ? metadata[@"imageURLs"] : @{};
    NSDictionary<NSNumber *, NSString *> *urls = S7TVURLMap(rawURLs);
    NSString *sectionIdentifier = S7TVString(metadata[@"sectionIdentifier"]);
    NSString *sectionTitle = S7TVString(metadata[@"sectionTitle"]);
    NSString *providerIdentifier = S7TVString(metadata[@"providerIdentifier"]);
    NSDictionary *modifiers = [metadata[@"modifierMetadata"] isKindOfClass:NSDictionary.class]
        ? metadata[@"modifierMetadata"] : @{};
    CGSize size = CGSizeMake(MAX(1, S7TVInteger(metadata[@"width"])),
                             MAX(1, S7TVInteger(metadata[@"height"])));
    return [[S7TVEmoteDescriptor alloc]
        initWithProvider:provider
        providerIdentifier:providerIdentifier ?: S7TVEmoteProviderKey(provider)
        emoteID:emoteID name:name aliases:S7TVAliases(metadata[@"aliases"])
        sectionKind:(S7TVEmoteSectionKind)kindValue
        sectionIdentifier:sectionIdentifier ?: @"favorites"
        sectionTitle:sectionTitle ?: @"Favorites"
        setID:S7TVString(metadata[@"setID"])
        nativeSize:size animated:S7TVBool(metadata[@"animated"])
        zeroWidth:S7TVBool(metadata[@"zeroWidth"])
        modifierMetadata:modifiers imageURLs:urls];
}

static NSString *S7TVString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSInteger S7TVInteger(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static CGFloat S7TVDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 0.0;
}

static BOOL S7TVBool(id value) {
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static BOOL S7TVCatalogProviderEnabled(S7TVEmoteProviderID provider) {
    return [S7TVEmoteProviderSettings isProviderEnabled:
        (S7TVExternalEmoteProvider)provider];
}

static NSArray<NSString *> *S7TVAliases(id value) {
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value length] ? @[value] : @[];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *alias = S7TVString(item);
        if (!alias.length && [item isKindOfClass:NSDictionary.class]) {
            NSDictionary *dictionary = item;
            alias = S7TVString(dictionary[@"name"]) ?: S7TVString(dictionary[@"alias"]);
            if (!alias.length) alias = S7TVString(dictionary[@"code"]);
        }
        if (alias.length) [result addObject:alias];
    }
    return result.copy;
}

static NSDictionary<NSNumber *, NSString *> *S7TVURLMap(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *url = S7TVString(obj);
        NSInteger scale = S7TVInteger(key);
        if (url.length && scale > 0) {
            if ([url hasPrefix:@"//"]) url = [@"https:" stringByAppendingString:url];
            else if ([url hasPrefix:@"/"]) url = [@"https://cdn.frankerfacez.com" stringByAppendingString:url];
            result[@(scale)] = url;
        }
    }];
    return result.copy;
}

// 7TV has used a plain `emotes` array in its REST v3 payloads and an
// `emotes.items`/`emotes.data` wrapper in GraphQL-shaped adapters. Keep that
// wire-format detail inside the catalogue so every parser and shape check
// agrees on what constitutes an emote-set payload.
static NSArray *S7TVEmoteEntriesFromSet(NSDictionary *set) {
    if (![set isKindOfClass:NSDictionary.class]) return @[];
    id collection = set[@"emotes"] ?: set[@"emoticons"];
    if ([collection isKindOfClass:NSArray.class]) return collection;
    if (![collection isKindOfClass:NSDictionary.class]) return @[];

    NSDictionary *wrapped = (NSDictionary *)collection;
    for (NSString *key in @[@"items", @"data", @"results", @"emotes", @"emoticons"]) {
        id candidate = wrapped[key];
        if ([candidate isKindOfClass:NSArray.class]) return candidate;
        if ([candidate isKindOfClass:NSDictionary.class]) {
            NSArray *nested = S7TVEmoteEntriesFromSet(candidate);
            if (nested.count) return nested;
        }
    }
    // Some cache adapters normalize an emote list as a map keyed by emote ID
    // rather than an array. Preserve those entries as long as the values look
    // like emote records; scalar metadata keys are ignored.
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

static BOOL S7TVDictionaryHasDirectEmoteCollection(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return NO;
    id collection = dictionary[@"emotes"] ?: dictionary[@"emoticons"];
    return [collection isKindOfClass:NSArray.class] ||
        [collection isKindOfClass:NSDictionary.class];
}

// The first provider-aware builds used the old SevenTVManager cache before
// the common catalogue was introduced.  Keep that on-disk data useful during
// a one-way, non-destructive migration: convert the legacy name -> metadata
// map into the same 7TV set shape consumed by the normal parser, then persist
// the normalized payload in the provider cache.  No network request or UI work
// happens on the caller's thread; loadProvider performs this helper on ioQueue.
static NSString *S7TVLegacySevenTVCachePath(BOOL global, NSString *channel) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                           NSUserDomainMask,
                                                           YES).firstObject;
    if (!base.length) return nil;
    NSString *scope = global ? @"global" :
        ([channel stringByReplacingOccurrencesOfString:@"/" withString:@"_"] ?: @"channel");
    return [[base stringByAppendingPathComponent:@"s7tv"]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", global ? @"global" :
            [NSString stringWithFormat:@"ch_%@", scope]]];
}

static NSDictionary *S7TVNormalizedLegacySevenTVPayload(NSData *data,
                                                         BOOL global,
                                                         NSString *channel) {
    if (!data.length) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;

    // If a future build already placed a provider-shaped payload in the old
    // directory, accept it as-is instead of wrapping it a second time.
    if (S7TVDictionaryHasDirectEmoteCollection(root)) return root;
    NSDictionary *legacyEmotes = [root[@"emotes"] isKindOfClass:NSDictionary.class]
        ? root[@"emotes"] : nil;
    if (!legacyEmotes.count) return nil;

    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:legacyEmotes.count];
    for (NSString *name in legacyEmotes) {
        NSDictionary *legacy = [legacyEmotes[name] isKindOfClass:NSDictionary.class]
            ? legacyEmotes[name] : nil;
        NSString *emoteID = S7TVString(legacy[@"id"]);
        if (!name.length || !emoteID.length) continue;

        NSInteger width = MAX(1, S7TVInteger(legacy[@"w"]));
        NSInteger height = MAX(1, S7TVInteger(legacy[@"h"]));
        NSString *hostURL = [NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@", emoteID];
        NSMutableArray *files = [NSMutableArray arrayWithCapacity:4];
        for (NSInteger scale = 1; scale <= 4; scale++) {
            [files addObject:@{
                @"name": [NSString stringWithFormat:@"%ldx.webp", (long)scale],
                @"width": @(width * scale),
                @"height": @(height * scale),
            }];
        }
        BOOL animated = S7TVBool(legacy[@"a"]);
        BOOL zeroWidth = S7TVBool(legacy[@"z"]);
        NSDictionary *dataObject = @{
            @"id": emoteID,
            @"name": name,
            @"animated": @(animated),
            @"zeroWidth": @(zeroWidth),
            @"width": @(width),
            @"height": @(height),
            @"host": @{ @"url": hostURL, @"files": files },
        };
        [entries addObject:@{
            @"id": emoteID,
            @"name": name,
            @"flags": @(zeroWidth ? 1 : 0),
            @"data": dataObject,
        }];
    }
    if (!entries.count) return nil;

    NSString *setID = global ? @"legacy-global" :
        [NSString stringWithFormat:@"legacy-channel-%@", channel ?: @"channel"];
    return @{
        @"id": setID,
        @"name": global ? @"Global Emotes" : @"Channel Emotes",
        @"emotes": entries,
    };
}

static BOOL S7TVSetHasEmotePayload(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        id collection = dictionary[@"emotes"] ?: dictionary[@"emoticons"];
        // An explicitly empty array/dictionary is still a valid set payload;
        // callers use the distinction between `nil` and an empty collection
        // to clear a loading placeholder without showing a retry error.
        if ([collection isKindOfClass:NSArray.class] ||
            [collection isKindOfClass:NSDictionary.class]) return YES;
        for (id nested in dictionary.allValues) {
            if (S7TVSetHasEmotePayload(nested)) return YES;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id nested in (NSArray *)value) {
            if (S7TVSetHasEmotePayload(nested)) return YES;
        }
    }
    return NO;
}

static BOOL S7TVJSONObjectIsValid(NSData *data, NSURLResponse *response, NSError **outError) {
    if (!data.length) {
        if (outError) *outError = [NSError errorWithDomain:@"S7TVEmoteCatalog"
                                                       code:1
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Empty response"}];
        return NO;
    }
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status >= 300) {
            if (outError) *outError = [NSError errorWithDomain:@"S7TVEmoteCatalog"
                                                           code:status
                                                       userInfo:@{NSLocalizedDescriptionKey:
                                                                      [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
            return NO;
        }
    }
    return YES;
}

static void S7TVSetCatalogStructureError(NSError **error,
                                         S7TVEmoteProviderID provider) {
    if (!error) return;
    *error = [NSError errorWithDomain:@"S7TVEmoteCatalog"
                                 code:2
                             userInfo:@{
        NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ returned an unexpected response",
             S7TVEmoteProviderName(provider)]
    }];
}

static void S7TVCollectSetIDsFromObject(id value,
                                        NSMutableOrderedSet<NSString *> *setIDs) {
    if (!setIDs || !value) return;
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value)
            S7TVCollectSetIDsFromObject(item, setIDs);
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dictionary = (NSDictionary *)value;

    // A set payload is also a dictionary, but its `id`/`name`/`emotes`
    // fields are not a map of set IDs. Handle it before walking keys so a
    // direct object cannot accidentally enqueue literal IDs such as
    // `id`, `name` or `emotes` as additional network requests.
    if (S7TVDictionaryHasDirectEmoteCollection(dictionary)) {
        NSString *identifier = S7TVString(dictionary[@"id"]) ?:
            S7TVString(dictionary[@"emote_set_id"]);
        if (identifier.length) [setIDs addObject:identifier];
    }

    // The v3 user response has appeared in both forms over time:
    // emote_set/emoteSet/set: "id", emote_set_id: "id", and a TWITCH
    // connection containing emote_set_id. Accept all documented/cached
    // spellings so a camel-case GraphQL/cache adapter cannot hide the active
    // set from the optional set loader.
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
            NSString *identifier = S7TVString(activeSet[@"id"]) ?:
                S7TVString(activeSet[@"emote_set_id"]) ?:
                S7TVString(activeSet[@"emoteSetId"]);
            if (identifier.length) [setIDs addObject:identifier];
        }
    }

    for (NSString *containerKey in @[@"emote_sets", @"sets"]) {
        id container = dictionary[containerKey];
        if ([container isKindOfClass:NSDictionary.class]) {
            // `sets` itself can be a single set object in compact/cache
            // responses (`{"id":..., "emotes":[...]}`), not always a map
            // keyed by set ID. Treat it as one set before enumerating fields;
            // otherwise keys such as "id"/"name" would become bogus request
            // identifiers and the real set ID could be lost.
            NSDictionary *directSet = (NSDictionary *)container;
            if (S7TVDictionaryHasDirectEmoteCollection(directSet)) {
                NSString *identifier = S7TVString(directSet[@"id"]) ?:
                    S7TVString(directSet[@"emote_set_id"]);
                if (identifier.length) [setIDs addObject:identifier];
                continue;
            }
            // Some compact responses include set metadata (`id` + `name`)
            // but omit the emote array because it is fetched separately. It
            // is still a valid set identifier; do not walk its scalar fields
            // and enqueue literal keys such as `id` or `name`.
            if (S7TVString(directSet[@"id"]).length &&
                S7TVString(directSet[@"name"]).length) {
                [setIDs addObject:S7TVString(directSet[@"id"])];
                continue;
            }
            [(NSDictionary *)container enumerateKeysAndObjectsUsingBlock:
                ^(id key, id object, BOOL *stop) {
                if ([object isKindOfClass:NSDictionary.class]) {
                    NSString *identifier = S7TVString(object[@"id"]) ?: S7TVString(key);
                    if (identifier.length) [setIDs addObject:identifier];
                    // A nested emote_set can carry the actual active set.
                    S7TVCollectSetIDsFromObject(object, setIDs);
                } else if ([key isKindOfClass:NSString.class] && [key length]) {
                    [setIDs addObject:key];
                } else if ([object isKindOfClass:NSString.class] && [object length]) {
                    [setIDs addObject:object];
                }
            }];
        } else if ([container isKindOfClass:NSArray.class]) {
            for (id object in (NSArray *)container) {
                if ([object isKindOfClass:NSDictionary.class]) {
                    NSString *identifier = S7TVString(object[@"id"]);
                    if (identifier.length) [setIDs addObject:identifier];
                    S7TVCollectSetIDsFromObject(object, setIDs);
                } else if ([object isKindOfClass:NSString.class] && [object length]) {
                    [setIDs addObject:object];
                }
            }
        }
    }

    id connections = dictionary[@"connections"];
    if ([connections isKindOfClass:NSArray.class]) {
        for (id connection in (NSArray *)connections)
            S7TVCollectSetIDsFromObject(connection, setIDs);
    } else if ([connections isKindOfClass:NSDictionary.class]) {
        // A few cached/API adapters normalize the connection list as a map
        // keyed by platform (for example {"TWITCH": {...}}). Traverse it
        // exactly like the documented array form so set discovery does not
        // depend on that serialization detail.
        for (id connection in [(NSDictionary *)connections allValues])
            S7TVCollectSetIDsFromObject(connection, setIDs);
    }
}

static BOOL S7TVSetContainerHasEmotePayload(id value) {
    return S7TVSetHasEmotePayload(value);
}

static NSDictionary *S7TVFindSetDictionary(id container, NSString *identifier) {
    if (!identifier.length) return nil;
    if ([container isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)container;
        NSString *containerID = S7TVString(dictionary[@"id"]);
        if ([containerID isEqualToString:identifier] &&
            S7TVDictionaryHasDirectEmoteCollection(dictionary)) {
            return dictionary;
        }
        NSDictionary *direct = [dictionary[identifier] isKindOfClass:NSDictionary.class]
            ? dictionary[identifier] : nil;
        if (direct) return direct;
        for (id value in dictionary.allValues) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSString *valueID = S7TVString(value[@"id"]);
            if ([valueID isEqualToString:identifier]) return value;
        }
    } else if ([container isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)container) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSString *valueID = S7TVString(value[@"id"]);
            if ([valueID isEqualToString:identifier]) return value;
        }
    }
    return nil;
}

static NSString *S7TVActiveSetIDFromObject(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = (NSDictionary *)value;
    id active = root[@"emote_set"] ?: root[@"emoteSet"] ?: root[@"set"];
    if ([active isKindOfClass:NSString.class] && [active length]) return active;
    if ([active isKindOfClass:NSDictionary.class]) {
        NSString *identifier = S7TVString(active[@"id"]);
        if (identifier.length) return identifier;
    }
    for (NSString *key in @[@"emote_set_id", @"emoteSetId"]) {
        NSString *identifier = S7TVString(root[key]);
        if (identifier.length) return identifier;
    }
    id connections = root[@"connections"];
    if ([connections isKindOfClass:NSArray.class]) {
        NSString *fallback = nil;
        BOOL sawIdentifiablePlatform = NO;
        for (id rawConnection in (NSArray *)connections) {
            if (![rawConnection isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *connection = rawConnection;
            NSString *platform = [S7TVString(connection[@"platform"]) lowercaseString];
            if (!platform.length)
                platform = [S7TVString(connection[@"platform_name"]) lowercaseString];
            if (!platform.length)
                platform = [S7TVString(connection[@"platformName"]) lowercaseString];
            if (platform.length) sawIdentifiablePlatform = YES;
            NSString *identifier = S7TVString(connection[@"emote_set_id"]) ?:
                S7TVString(connection[@"emoteSetId"]);
            if (!identifier.length) {
                id connectionSet = connection[@"emote_set"] ?:
                    connection[@"emoteSet"] ?: connection[@"set"];
                identifier = [connectionSet isKindOfClass:NSString.class]
                    ? connectionSet
                    : ([connectionSet isKindOfClass:NSDictionary.class]
                       ? (S7TVString(connectionSet[@"id"]) ?:
                          S7TVString(connectionSet[@"emote_set_id"]) ?:
                          S7TVString(connectionSet[@"emoteSetId"])) : nil);
            }
            if (!identifier.length) continue;
            if ([platform isEqualToString:@"twitch"] || [platform containsString:@"twitch"])
                return identifier;
            // A non-Twitch connection must not become the active Twitch set.
            // Keep a fallback only for an unlabeled connection, and use it
            // only when the response contains no identifiable platform at all.
            if (!platform.length && !fallback.length) fallback = identifier;
        }
        if (fallback.length && !sawIdentifiablePlatform) return fallback;
    } else if ([connections isKindOfClass:NSDictionary.class]) {
        // Some persisted responses expose platform connections as a map
        // instead of the documented array form. Prefer Twitch when present,
        // then use the first usable set identifier.
        NSDictionary *connectionMap = (NSDictionary *)connections;
        NSString *fallback = nil;
        BOOL sawIdentifiablePlatform = NO;
        for (id rawKey in connectionMap) {
            id rawConnection = connectionMap[rawKey];
            if (![rawConnection isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *connection = rawConnection;
            NSString *platform = [S7TVString(connection[@"platform"]) lowercaseString];
            if (!platform.length && [rawKey isKindOfClass:NSString.class])
                platform = [rawKey lowercaseString];
            if (!platform.length)
                platform = [S7TVString(connection[@"platform_name"]) lowercaseString];
            if (!platform.length)
                platform = [S7TVString(connection[@"platformName"]) lowercaseString];
            if (platform.length) sawIdentifiablePlatform = YES;
            NSString *identifier = S7TVString(connection[@"emote_set_id"]) ?:
                S7TVString(connection[@"emoteSetId"]);
            if (!identifier.length) {
                id connectionSet = connection[@"emote_set"] ?:
                    connection[@"emoteSet"] ?: connection[@"set"];
                identifier = [connectionSet isKindOfClass:NSString.class]
                    ? connectionSet
                    : ([connectionSet isKindOfClass:NSDictionary.class]
                       ? (S7TVString(connectionSet[@"id"]) ?:
                          S7TVString(connectionSet[@"emote_set_id"]) ?:
                          S7TVString(connectionSet[@"emoteSetId"])) : nil);
            }
            if (!identifier.length) continue;
            if ([platform isEqualToString:@"twitch"] || [platform containsString:@"twitch"])
                return identifier;
            if (!platform.length && !fallback.length) fallback = identifier;
        }
        if (fallback.length && !sawIdentifiablePlatform) return fallback;
    }
    id sets = root[@"emote_sets"] ?: root[@"sets"];
    if ([sets isKindOfClass:NSArray.class]) {
        for (id rawSet in (NSArray *)sets) {
            if ([rawSet isKindOfClass:NSDictionary.class]) {
                NSString *identifier = S7TVString(rawSet[@"id"]);
                if (identifier.length) return identifier;
            } else if ([rawSet isKindOfClass:NSString.class] && [rawSet length]) {
                return rawSet;
            }
        }
    }
    if ([sets isKindOfClass:NSDictionary.class]) {
        NSDictionary *directSet = (NSDictionary *)sets;
        if (S7TVDictionaryHasDirectEmoteCollection(directSet)) {
            NSString *identifier = S7TVString(directSet[@"id"]) ?:
                S7TVString(directSet[@"emote_set_id"]);
            if (identifier.length) return identifier;
        }
        if (S7TVString(directSet[@"id"]).length &&
            S7TVString(directSet[@"name"]).length)
            return S7TVString(directSet[@"id"]);
        for (id key in [(NSDictionary *)sets allKeys]) {
            if ([key isKindOfClass:NSString.class] && [key length]) return key;
        }
    }
    return nil;
}

// Current 7TV user responses may embed the complete active set in a Twitch
// connection instead of exposing it through the top-level `emote_set` field.
// Keep that shape in the primary Channel section immediately; the set-ID
// loader remains a fallback for responses that only contain an identifier.
static NSDictionary *S7TVConnectionSetWithPayload(id connections) {
    NSMutableArray<NSDictionary *> *normalized = [NSMutableArray array];
    if ([connections isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)connections) {
            if ([value isKindOfClass:NSDictionary.class])
                [normalized addObject:value];
        }
    } else if ([connections isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)connections enumerateKeysAndObjectsUsingBlock:
            ^(id key, id value, BOOL *stop) {
            if (![value isKindOfClass:NSDictionary.class]) return;
            NSMutableDictionary *connection = [value mutableCopy];
            if (!S7TVString(connection[@"platform"]).length &&
                [key isKindOfClass:NSString.class]) {
                connection[@"__s7tv_platform_hint"] = key;
            }
            [normalized addObject:connection.copy];
        }];
    }

    NSDictionary *fallback = nil;
    BOOL sawIdentifiablePlatform = NO;
    for (NSDictionary *connection in normalized) {
        id rawSet = connection[@"emote_set"] ?: connection[@"emoteSet"] ?: connection[@"set"];
        NSDictionary *set = [rawSet isKindOfClass:NSDictionary.class] &&
            S7TVDictionaryHasDirectEmoteCollection(rawSet)
            ? rawSet : (S7TVDictionaryHasDirectEmoteCollection(connection) ? connection : nil);
        if (!set) continue;

        NSString *platform = [S7TVString(connection[@"platform"]) lowercaseString];
        if (!platform.length) platform = [S7TVString(connection[@"platform_name"]) lowercaseString];
        if (!platform.length) platform = [S7TVString(connection[@"platformName"]) lowercaseString];
        if (!platform.length) platform = [S7TVString(connection[@"__s7tv_platform_hint"]) lowercaseString];
        if (platform.length) sawIdentifiablePlatform = YES;
        if ([platform isEqualToString:@"twitch"] || [platform containsString:@"twitch"])
            return set;
        if (!platform.length && !fallback) fallback = set;
    }
    // Never present a known non-Twitch connection (YouTube, Discord, ...)
    // as the current Twitch channel. An unlabeled payload is a safe fallback
    // only when the response gives us no platform information at all.
    return sawIdentifiablePlatform ? nil : fallback;
}

@interface S7TVEmoteDescriptor ()
@property (nonatomic, assign, readwrite) S7TVEmoteProviderID provider;
@property (nonatomic, copy, readwrite) NSString *providerIdentifier;
@property (nonatomic, copy, readwrite) NSString *providerName;
@property (nonatomic, copy, readwrite) NSString *emoteID;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *aliases;
@property (nonatomic, assign, readwrite) S7TVEmoteSectionKind sectionKind;
@property (nonatomic, copy, readwrite) NSString *sectionIdentifier;
@property (nonatomic, copy, readwrite) NSString *sectionTitle;
@property (nonatomic, copy, readwrite, nullable) NSString *setID;
@property (nonatomic, assign, readwrite) CGSize nativeSize;
@property (nonatomic, assign, readwrite) BOOL animated;
@property (nonatomic, assign, readwrite) BOOL zeroWidth;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, id> *modifierMetadata;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSString *> *imageURLs;
@end

@implementation S7TVEmoteDescriptor

- (instancetype)initWithProvider:(S7TVEmoteProviderID)provider
               providerIdentifier:(NSString *)providerIdentifier
                           emoteID:(NSString *)emoteID
                              name:(NSString *)name
                           aliases:(NSArray<NSString *> *)aliases
                       sectionKind:(S7TVEmoteSectionKind)sectionKind
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
    _providerIdentifier = [providerIdentifier copy] ?: S7TVEmoteProviderKey(provider);
    _providerName = S7TVEmoteProviderName(provider);
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

- (id)copyWithZone:(NSZone *)zone {
    return [[S7TVEmoteDescriptor allocWithZone:zone]
        initWithProvider:self.provider
        providerIdentifier:self.providerIdentifier
        emoteID:self.emoteID
        name:self.name
        aliases:self.aliases
        sectionKind:self.sectionKind
        sectionIdentifier:self.sectionIdentifier
        sectionTitle:self.sectionTitle
        setID:self.setID
        nativeSize:self.nativeSize
        animated:self.animated
        zeroWidth:self.zeroWidth
        modifierMetadata:self.modifierMetadata
        imageURLs:self.imageURLs];
}

- (nullable NSURL *)imageURLForResolution:(NSInteger)resolution {
    if (resolution < 1) resolution = 1;
    if (resolution > 4) resolution = 4;
    if (!self.imageURLs.count) return nil;

    NSString *urlString = self.imageURLs[@(resolution)];
    // FFZ publishes 1/2/4; 3X intentionally uses the best available 4X.
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

- (BOOL)matchesName:(NSString *)name {
    if (!name.length) return NO;
    if ([self.name isEqualToString:name]) return YES;
    for (NSString *alias in self.aliases) {
        if ([alias isEqualToString:name]) return YES;
    }
    return NO;
}
@end

@interface S7TVEmoteSection ()
@property (nonatomic, assign, readwrite) S7TVEmoteProviderID provider;
@property (nonatomic, assign, readwrite) S7TVEmoteSectionKind kind;
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSArray<S7TVEmoteDescriptor *> *emotes;
@property (nonatomic, assign, readwrite) BOOL loaded;
@property (nonatomic, assign, readwrite) BOOL loading;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@end

@implementation S7TVEmoteSection
- (instancetype)initWithProvider:(S7TVEmoteProviderID)provider
                              kind:(S7TVEmoteSectionKind)kind
                        identifier:(NSString *)identifier
                             title:(NSString *)title
                            emotes:(NSArray<S7TVEmoteDescriptor *> *)emotes
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
- (id)copyWithZone:(NSZone *)zone {
    return [[S7TVEmoteSection allocWithZone:zone]
        initWithProvider:self.provider kind:self.kind identifier:self.identifier
        title:self.title emotes:self.emotes loaded:self.loaded loading:self.loading
        errorMessage:self.errorMessage];
}
@end

@interface S7TVEmoteProviderSnapshot ()
@property (nonatomic, assign, readwrite) S7TVEmoteProviderID provider;
@property (nonatomic, assign, readwrite) S7TVEmoteProviderState state;
@property (nonatomic, copy, readwrite) NSString *channelID;
@property (nonatomic, copy, readwrite) NSArray<S7TVEmoteSection *> *sections;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@end

@implementation S7TVEmoteProviderSnapshot

- (id)copyWithZone:(NSZone *)zone {
    S7TVEmoteProviderSnapshot *copy = [S7TVEmoteProviderSnapshot allocWithZone:zone];
    copy.provider = self.provider;
    copy.state = self.state;
    copy.channelID = self.channelID;
    copy.sections = self.sections;
    copy.errorMessage = self.errorMessage;
    return copy;
}
@end

@interface S7TVEmoteCatalog ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, S7TVEmoteProviderSnapshot *> *snapshots;
// NSNull is used as a short-lived reservation while the NSURLSession task is
// being constructed on the serial state queue.  Keep the type honest instead
// of pretending that every value is already a data task.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *requestGenerations;
// Dernière réponse réussie par scope. Le picker peut être présenté plusieurs
// fois pendant une même session : réutiliser un snapshot récent évite de
// relancer trois requêtes et de repasser en état Loading à chaque ouverture.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastSuccessfulLoads;
@property (nonatomic, copy) NSString *activeChannelID;
// The public priority/enabled properties have synchronized custom accessors,
// so keep their backing storage on private properties that can be synthesized
// by older Theos/Clang toolchains as well.
@property (nonatomic, copy) NSArray<NSNumber *> *providerPriorityStorage;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *providerEnabledStorage;
// Snapshot kept separate from the public synchronization property.  The
// picker mirrors settings into providerEnabled immediately on the main thread;
// using that property to detect an enable transition would erase the old
// value before this notification handler reaches the serial state queue.
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *lastKnownProviderEnabled;
// The picker and tokenizer ask for the same flattened provider data many
// times. Keep the sorted sections/emotes and exact name/alias lookup tables
// until the corresponding snapshot changes.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<S7TVEmoteSection *> *> *orderedSectionsCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<S7TVEmoteDescriptor *> *> *orderedEmoteCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary<NSString *, S7TVEmoteDescriptor *> *> *nameIndexCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *derivedCacheGenerations;
- (void)providerSettingsDidChange:(NSNotification *)notification;
- (void)loadSevenTVAdditionalSetsFromData:(NSData *)data
                                   global:(BOOL)global
                                  channel:(nullable NSString *)channel
                               generation:(NSUInteger)parentGeneration
                   requireActiveRequest:(BOOL)requireActiveRequest;
- (void)loadSevenTVSetID:(NSString *)setID
                   global:(BOOL)global
                  channel:(nullable NSString *)channel
                asPrimary:(BOOL)asPrimary;
- (BOOL)updateSevenTVSetPlaceholderForID:(NSString *)setID
                                  global:(BOOL)global
                                 channel:(nullable NSString *)channel
                                  title:(nullable NSString *)title
                              asPrimary:(BOOL)asPrimary
                                 loaded:(BOOL)loaded
                                loading:(BOOL)loading
                           errorMessage:(nullable NSString *)errorMessage;
- (void)mergeSevenTVSetSections:(NSArray<S7TVEmoteSection *> *)sections
                          global:(BOOL)global
                         channel:(nullable NSString *)channel;
- (void)setSevenTVPrimaryPlaceholderLoading:(BOOL)loading
                              errorMessage:(nullable NSString *)errorMessage
                                   channel:(nullable NSString *)channel;
- (NSArray<S7TVEmoteSection *> *)sectionsByCombining:(NSArray<S7TVEmoteSection *> *)fresh
                                        withExisting:(NSArray<S7TVEmoteSection *> *)existing
                                               global:(BOOL)global;
- (void)invalidateDerivedCachesForProvider:(S7TVEmoteProviderID)provider;
- (nullable S7TVEmoteSection *)sevenTVSectionFromSet:(NSDictionary *)set
                                               global:(BOOL)global
                                          sectionKind:(S7TVEmoteSectionKind)kind
                                      sectionIdentifier:(NSString *)identifier
                                               title:(NSString *)title;
- (NSArray<S7TVEmoteSection *> *)sevenTVSetSectionsFromObject:(id)object
                                                     requestedID:(NSString *)requestedID
                                                     asPrimary:(BOOL)asPrimary
                                                       global:(BOOL)global;
- (void)s7tv_providerConfigurationSnapshot:(NSArray<NSNumber *> **)priorityOut
                                   enabled:(NSDictionary<NSNumber *, NSNumber *> **)enabledOut;
@end

@implementation S7TVEmoteCatalog

+ (instancetype)sharedCatalog {
    static S7TVEmoteCatalog *catalog;
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
    _providerPriorityStorage = @[@(S7TVEmoteProviderIDSevenTV), @(S7TVEmoteProviderIDBTTV), @(S7TVEmoteProviderIDFFZ)];
    _providerEnabledStorage = @{@(S7TVEmoteProviderIDSevenTV): @YES,
                                @(S7TVEmoteProviderIDBTTV): @YES,
                                @(S7TVEmoteProviderIDFFZ): @YES};
    // Migrate the legacy 7TV switch/aggregate representation before reading
    // the public snapshot.  Otherwise an existing install with 7TV disabled
    // would briefly look enabled until the picker queried provider settings.
    [S7TVEmoteProviderSettings migrateLegacySettings];
    [self loadConfiguration];
    _lastKnownProviderEnabled = _providerEnabledStorage.copy;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(providerSettingsDidChange:)
                                                 name:S7TVEmoteProviderSettingsDidChangeNotification
                                               object:nil];
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        S7TVEmoteProviderSnapshot *snapshot = [S7TVEmoteProviderSnapshot new];
        snapshot.provider = (S7TVEmoteProviderID)provider;
        snapshot.state = S7TVEmoteProviderStateIdle;
        snapshot.channelID = @"";
        snapshot.sections = @[];
        _snapshots[@(provider)] = snapshot;
    }
    return self;
}

// The picker updates these properties on the main thread while the tokenizer
// can read them from a chat/layout callback.  Return immutable copies and
// publish writes under one lock so no caller can observe a partially-mutated
// array/dictionary during a settings change.
- (NSArray<NSNumber *> *)providerPriority {
    @synchronized (self) {
        return [_providerPriorityStorage copy] ?: @[];
    }
}

- (void)setProviderPriority:(NSArray<NSNumber *> *)priority {
    NSMutableArray *clean = [NSMutableArray array];
    for (id value in priority) {
        NSInteger provider = [value isKindOfClass:NSString.class]
            ? (NSInteger)S7TVEmoteProviderFromIdentifier(value)
            : S7TVInteger(value);
        if (provider >= S7TVEmoteProviderIDSevenTV && provider <= S7TVEmoteProviderIDFFZ &&
            ![clean containsObject:@(provider)]) [clean addObject:@(provider)];
    }
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        if (![clean containsObject:@(provider)]) [clean addObject:@(provider)];
    }
    @synchronized (self) {
        _providerPriorityStorage = clean.copy;
    }
}

- (NSDictionary<NSNumber *, NSNumber *> *)providerEnabled {
    @synchronized (self) {
        return [_providerEnabledStorage copy] ?: @{};
    }
}

- (void)setProviderEnabled:(NSDictionary<NSNumber *,NSNumber *> *)providerEnabled {
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        NSNumber *value = providerEnabled[@(provider)] ?: @YES;
        clean[@(provider)] = @([value boolValue]);
        stored[S7TVEmoteProviderKey((S7TVEmoteProviderID)provider)] = clean[@(provider)];
    }
    @synchronized (self) {
        _providerEnabledStorage = clean.copy;
    }
    // Keep the legacy aggregate dictionary available for imports, while the
    // provider settings object remains the source of truth for the individual
    // switches.
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:@"s7tv_emote_provider_enabled"];
}

- (void)s7tv_providerConfigurationSnapshot:(NSArray<NSNumber *> **)priorityOut
                                   enabled:(NSDictionary<NSNumber *, NSNumber *> **)enabledOut {
    @synchronized (self) {
        if (priorityOut) *priorityOut = [_providerPriorityStorage copy] ?: @[];
        if (enabledOut) *enabledOut = [_providerEnabledStorage copy] ?: @{};
    }
}

- (void)loadConfiguration {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *savedPriority = [defaults arrayForKey:@"s7tv_emote_provider_priority"];
    if (savedPriority.count) {
        NSMutableArray *priority = [NSMutableArray array];
        for (id value in savedPriority) {
            NSInteger provider = [value isKindOfClass:NSString.class]
                ? (NSInteger)S7TVEmoteProviderFromIdentifier(value)
                : S7TVInteger(value);
            if (provider >= S7TVEmoteProviderIDSevenTV && provider <= S7TVEmoteProviderIDFFZ &&
                ![priority containsObject:@(provider)]) [priority addObject:@(provider)];
        }
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            if (![priority containsObject:@(provider)]) [priority addObject:@(provider)];
        }
        @synchronized (self) {
            _providerPriorityStorage = priority.copy;
        }
    }
    NSDictionary *enabled = [defaults dictionaryForKey:@"s7tv_emote_provider_enabled"];
    BOOL hasIndividualSettings = NO;
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        NSString *key = [@"s7tv_emote_provider_enabled_" stringByAppendingString:
            S7TVEmoteProviderKey((S7TVEmoteProviderID)provider)];
        if ([defaults objectForKey:key] != nil) {
            hasIndividualSettings = YES;
            break;
        }
    }
    if (hasIndividualSettings) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            NSString *key = [@"s7tv_emote_provider_enabled_" stringByAppendingString:
                S7TVEmoteProviderKey((S7TVEmoteProviderID)provider)];
            values[@(provider)] = [defaults objectForKey:key]
                ? @([defaults boolForKey:key]) : @YES;
        }
        @synchronized (self) {
            _providerEnabledStorage = values.copy;
        }
    } else if (enabled.count) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            id value = enabled[[S7TVEmoteProviderKey((S7TVEmoteProviderID)provider) lowercaseString]];
            if (!value) {
                NSString *numericKey = [@(provider) stringValue];
                value = enabled[numericKey];
            }
            values[@(provider)] = value ? @([value boolValue]) : @YES;
        }
        @synchronized (self) {
            _providerEnabledStorage = values.copy;
        }
    } else {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            NSString *key = [@"s7tv_emote_provider_enabled_" stringByAppendingString:
                S7TVEmoteProviderKey((S7TVEmoteProviderID)provider)];
            values[@(provider)] = [defaults objectForKey:key]
                ? @([defaults boolForKey:key]) : @YES;
        }
        @synchronized (self) {
            _providerEnabledStorage = values.copy;
        }
    }
}

- (void)providerSettingsDidChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(self.stateQueue, ^{
        NSDictionary<NSNumber *, NSNumber *> *previouslyEnabled =
            [self.lastKnownProviderEnabled copy] ?: [self.providerEnabled copy] ?: @{};
        [self loadConfiguration];
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            BOOL enabled = [self.providerEnabled[@(provider)] boolValue];
            if (!enabled) {
                NSString *prefix = [NSString stringWithFormat:@"%@:",
                    S7TVEmoteProviderKey((S7TVEmoteProviderID)provider)];
                // Optional 7TV set requests use a separate task-key namespace
                // (`7tv-set:<id>:<scope>`). They belong to the same provider
                // and must be cancelled too when 7TV is disabled; otherwise a
                // late set response could repopulate the picker after the
                // toggle even though normal `7tv:<scope>` requests stopped.
                NSString *secondaryPrefix = provider == S7TVEmoteProviderIDSevenTV
                    ? @"7tv-set:" : nil;
                for (NSString *key in self.tasks.allKeys.copy) {
                    if (![key hasPrefix:prefix] &&
                        !(secondaryPrefix.length && [key hasPrefix:secondaryPrefix])) continue;
                    id task = self.tasks[key];
                    if ([task isKindOfClass:NSURLSessionDataTask.class])
                        [(NSURLSessionDataTask *)task cancel];
                    [self.tasks removeObjectForKey:key];
                    self.requestGenerations[key] =
                        @(self.requestGenerations[key].unsignedIntegerValue + 1);
                }
            } else if (![previouslyEnabled[@(provider)] boolValue]) {
                // Re-enabling a provider while a stream is already open must
                // populate it immediately. Otherwise the toggle would only
                // affect a future channel switch or a later picker open.
                [self loadProvider:(S7TVEmoteProviderID)provider
                             global:YES channel:nil completion:nil];
                if (self.activeChannelID.length) {
                    [self loadProvider:(S7TVEmoteProviderID)provider
                                 global:NO channel:self.activeChannelID completion:nil];
                }
            }
            [self postUpdateForProvider:(S7TVEmoteProviderID)provider];
        }
        self.lastKnownProviderEnabled = self.providerEnabled.copy;
    });
}

- (S7TVEmoteProviderSnapshot *)snapshotForProvider:(S7TVEmoteProviderID)provider {
    __block S7TVEmoteProviderSnapshot *snapshot;
    dispatch_sync(self.stateQueue, ^{ snapshot = [self.snapshots[@(provider)] copy]; });
    return snapshot ?: [S7TVEmoteProviderSnapshot new];
}

- (NSArray<S7TVEmoteSection *> *)sectionsForProvider:(S7TVEmoteProviderID)provider {
    NSNumber *providerKey = @(provider);
    NSUInteger generation = 0;
    @synchronized (self) {
        NSArray<S7TVEmoteSection *> *cached = self.orderedSectionsCache[providerKey];
        if (cached) return cached;
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }

    NSArray<S7TVEmoteSection *> *sections = [self snapshotForProvider:provider].sections ?: @[];
    // API dictionaries (notably FFZ's `sets`) are unordered. Keep the picker
    // layout and its "first section open" rule deterministic across launches.
    NSArray<S7TVEmoteSection *> *sorted = [sections sortedArrayUsingComparator:^NSComparisonResult(S7TVEmoteSection *left,
                                                                                                    S7TVEmoteSection *right) {
        NSInteger leftRank = left.kind == S7TVEmoteSectionKindChannel ? 0
            : (left.kind == S7TVEmoteSectionKindShared ? 1
               : (left.kind == S7TVEmoteSectionKindGlobal ? 2 : 3));
        NSInteger rightRank = right.kind == S7TVEmoteSectionKindChannel ? 0
            : (right.kind == S7TVEmoteSectionKindShared ? 1
               : (right.kind == S7TVEmoteSectionKindGlobal ? 2 : 3));
        if (leftRank < rightRank) return NSOrderedAscending;
        if (leftRank > rightRank) return NSOrderedDescending;
        NSComparisonResult titleResult = [left.title compare:right.title
            options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (titleResult != NSOrderedSame) return titleResult;
        return [left.identifier compare:right.identifier
            options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    @synchronized (self) {
        // A response can replace the snapshot while the sort is running. Do
        // not let a result from the previous generation become the cache for
        // the new snapshot.
        if (self.derivedCacheGenerations[providerKey].unsignedIntegerValue == generation) {
            NSArray<S7TVEmoteSection *> *existing = self.orderedSectionsCache[providerKey];
            if (existing) return existing;
            self.orderedSectionsCache[providerKey] = sorted;
        }
    }
    return sorted;
}

- (NSArray<S7TVEmoteDescriptor *> *)allEmotesForProvider:(S7TVEmoteProviderID)provider {
    NSNumber *providerKey = @(provider);
    NSUInteger generation = 0;
    @synchronized (self) {
        NSArray<S7TVEmoteDescriptor *> *cached = self.orderedEmoteCache[providerKey];
        if (cached) return cached;
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }

    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    // Resolve names deterministically even when global and channel responses
    // finish in the opposite order.  A channel/shared emote should win over a
    // provider-global one before the cross-provider priority is consulted.
    NSArray<S7TVEmoteSection *> *sections = [[self sectionsForProvider:provider]
        sortedArrayUsingComparator:^NSComparisonResult(S7TVEmoteSection *left,
                                                       S7TVEmoteSection *right) {
        NSInteger leftRank = left.kind == S7TVEmoteSectionKindChannel ? 0
            : (left.kind == S7TVEmoteSectionKindShared ? 1
               : (left.kind == S7TVEmoteSectionKindSet ? 2 : 3));
        NSInteger rightRank = right.kind == S7TVEmoteSectionKindChannel ? 0
            : (right.kind == S7TVEmoteSectionKindShared ? 1
               : (right.kind == S7TVEmoteSectionKindSet ? 2 : 3));
        if (leftRank < rightRank) return NSOrderedAscending;
        if (leftRank > rightRank) return NSOrderedDescending;
        return [left.identifier compare:right.identifier
            options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    // The flattened list intentionally gives channel/shared/set emotes the
    // first chance to claim a duplicate name before provider-global emotes.
    for (S7TVEmoteSection *section in sections) {
        for (S7TVEmoteDescriptor *emote in section.emotes) {
            NSString *stableKey = S7TVEmoteFavoriteKey(emote.provider, emote.emoteID);
            if (!stableKey.length || [seenKeys containsObject:stableKey]) continue;
            [seenKeys addObject:stableKey];
            [result addObject:emote];
        }
    }
    NSArray<S7TVEmoteDescriptor *> *flattened = result.copy;
    @synchronized (self) {
        if (self.derivedCacheGenerations[providerKey].unsignedIntegerValue == generation) {
            NSArray<S7TVEmoteDescriptor *> *existing = self.orderedEmoteCache[providerKey];
            if (existing) return existing;
            self.orderedEmoteCache[providerKey] = flattened;
        }
    }
    return flattened;
}

- (S7TVEmoteDescriptor *)resolveEmoteNamed:(NSString *)name
                                  provider:(S7TVEmoteProviderID)provider {
    if (!name.length || !S7TVCatalogProviderEnabled(provider)) return nil;
    NSNumber *providerKey = @(provider);
    NSDictionary<NSString *, S7TVEmoteDescriptor *> *index = nil;
    NSUInteger generation = 0;
    @synchronized (self) {
        index = self.nameIndexCache[providerKey];
        generation = self.derivedCacheGenerations[providerKey].unsignedIntegerValue;
    }
    if (!index) {
        NSMutableDictionary<NSString *, S7TVEmoteDescriptor *> *built = [NSMutableDictionary dictionary];
        for (S7TVEmoteDescriptor *emote in [self allEmotesForProvider:provider]) {
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

- (S7TVEmoteDescriptor *)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;
    NSArray<NSNumber *> *priority = nil;
    NSDictionary<NSNumber *, NSNumber *> *enabled = nil;
    [self s7tv_providerConfigurationSnapshot:&priority enabled:&enabled];
    for (NSNumber *providerNumber in priority) {
        if (![enabled[providerNumber] boolValue]) continue;
        S7TVEmoteDescriptor *emote = [self resolveEmoteNamed:name
                                                       provider:providerNumber.integerValue];
        if (emote) return emote;
    }
    return nil;
}

- (void)invalidateDerivedCachesForProvider:(S7TVEmoteProviderID)provider {
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
    NSString *directory = [base stringByAppendingPathComponent:@"s7tv-emote-providers"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                               withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

- (NSString *)cachePathForProvider:(S7TVEmoteProviderID)provider global:(BOOL)global channel:(NSString *)channel {
    NSString *scope = global ? @"global" : ([channel stringByReplacingOccurrencesOfString:@"/" withString:@"_"] ?: @"channel");
    return [[self cacheDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@.json", S7TVEmoteProviderKey(provider), scope]];
}

- (NSString *)cachePathForSevenTVSetID:(NSString *)setID {
    NSString *safeID = [setID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeID = [safeID stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return [[self cacheDirectory]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"7tv-set-%@.json", safeID]];
}

- (void)mergeSevenTVSetSections:(NSArray<S7TVEmoteSection *> *)sections
                          global:(BOOL)global
                         channel:(nullable NSString *)channel {
    if (!sections.count) return;
    if (!global && (!channel.length ||
                    [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame))
        return;

    S7TVEmoteProviderSnapshot *snapshot =
        self.snapshots[@(S7TVEmoteProviderIDSevenTV)];
    if (!snapshot) return;
    NSMutableArray<S7TVEmoteSection *> *merged =
        [snapshot.sections mutableCopy] ?: [NSMutableArray array];
    for (S7TVEmoteSection *fresh in sections) {
        if (!fresh.identifier.length) continue;
        NSUInteger replaceIndex = NSNotFound;
        for (NSUInteger index = 0; index < merged.count; index++) {
            S7TVEmoteSection *existing = merged[index];
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
    // A channel/user response can contain only the active set ID; while the
    // dedicated set request is in flight the provider snapshot is marked
    // loading so the picker shows an explicit state instead of a misleading
    // empty result. Once any set data arrives, the normal loaded state is
    // restored (additional sets can still merge later without hiding the
    // already usable sections).
    snapshot.state = S7TVEmoteProviderStateLoaded;
    snapshot.errorMessage = nil;
    [self invalidateDerivedCachesForProvider:S7TVEmoteProviderIDSevenTV];
    [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
}

- (BOOL)updateSevenTVSetPlaceholderForID:(NSString *)setID
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
    S7TVEmoteProviderSnapshot *snapshot =
        self.snapshots[@(S7TVEmoteProviderIDSevenTV)];
    if (!snapshot) return NO;

    // The primary set is rendered under the stable provider section IDs
    // (`global`/`channel`). Optional sets use a scope-qualified ID so their
    // headers can trigger an on-demand request. Keeping the primary global
    // placeholder on `global` is important: a successful `/emote-sets/<id>`
    // response must replace it rather than leave a second `global-set:<id>`
    // row behind.
    NSString *identifier = asPrimary
        ? (global ? @"global" : @"channel")
        : S7TVSetSectionIdentifier(setID, global);
    NSMutableArray<S7TVEmoteSection *> *sections =
        [snapshot.sections mutableCopy] ?: [NSMutableArray array];
    NSUInteger existingIndex = NSNotFound;
    S7TVEmoteSection *existing = nil;
    for (NSUInteger index = 0; index < sections.count; index++) {
        S7TVEmoteSection *candidate = sections[index];
        if (candidate.provider == S7TVEmoteProviderIDSevenTV &&
            [candidate.identifier isEqualToString:identifier]) {
            existingIndex = index;
            existing = candidate;
            break;
        }
    }

    // Never replace usable cached emotes with a loading/error placeholder.
    // The background refresh can fail without making an already visible set
    // disappear; a later explicit retry may still request it again.
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

    S7TVEmoteSection *replacement = [[S7TVEmoteSection alloc]
        initWithProvider:S7TVEmoteProviderIDSevenTV
                   kind:(asPrimary ? (global ? S7TVEmoteSectionKindGlobal
                                             : S7TVEmoteSectionKindChannel)
                                   : S7TVEmoteSectionKindSet)
             identifier:identifier
                   title:resolvedTitle
                  emotes:@[]
                  loaded:loaded
                 loading:loading
            errorMessage:resolvedError];
    if (existingIndex == NSNotFound) [sections addObject:replacement];
    else sections[existingIndex] = replacement;
    snapshot.sections = sections.copy;
    [self invalidateDerivedCachesForProvider:S7TVEmoteProviderIDSevenTV];
    return YES;
}

- (void)setSevenTVPrimaryPlaceholderLoading:(BOOL)loading
                              errorMessage:(nullable NSString *)errorMessage
                                   channel:(nullable NSString *)channel {
    if (!channel.length ||
        [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)
        return;
    S7TVEmoteProviderSnapshot *snapshot =
        self.snapshots[@(S7TVEmoteProviderIDSevenTV)];
    if (!snapshot) return;

    NSMutableArray<S7TVEmoteSection *> *sections =
        [snapshot.sections mutableCopy] ?: [NSMutableArray array];
    NSUInteger existingIndex = NSNotFound;
    for (NSUInteger index = 0; index < sections.count; index++) {
        S7TVEmoteSection *section = sections[index];
        if (section.kind == S7TVEmoteSectionKindChannel &&
            [section.identifier isEqualToString:@"channel"]) {
            existingIndex = index;
            break;
        }
    }

    // A real channel section should never be replaced by a placeholder (for
    // example, an additional set request can finish just before another
    // cached parent payload is processed). Keep its emotes intact when a
    // background refresh later fails; cached content remains preferable to a
    // retry banner with no usable emotes.
    if (existingIndex != NSNotFound && sections[existingIndex].emotes.count)
        return;

    S7TVEmoteSection *placeholder = [[S7TVEmoteSection alloc]
        initWithProvider:S7TVEmoteProviderIDSevenTV
                   kind:S7TVEmoteSectionKindChannel
             identifier:@"channel"
                   title:@"Channel Emotes"
                  emotes:@[]
                  loaded:!loading
                 loading:loading
            errorMessage:errorMessage];
    if (existingIndex == NSNotFound) [sections addObject:placeholder];
    else sections[existingIndex] = placeholder;
    snapshot.sections = sections.copy;
    [self invalidateDerivedCachesForProvider:S7TVEmoteProviderIDSevenTV];
    [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
}

- (void)loadSevenTVSetID:(NSString *)setID
                   global:(BOOL)global
                  channel:(nullable NSString *)channel
                asPrimary:(BOOL)asPrimary {
    if (!setID.length || !S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV))
        return;
    NSString *scope = global ? @"global" : channel;
    if (!scope.length) return;
    NSString *taskKey = [NSString stringWithFormat:@"7tv-set:%@:%@", setID, scope];
    NSString *escapedID = [setID stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
                                       @"https://7tv.io/v3/emote-sets/%@",
                                       escapedID ?: setID]];
    if (!url) return;

    dispatch_async(self.stateQueue, ^{
        if (!S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV)) return;
        if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)
            return;
        id old = self.tasks[taskKey];
        if ([old isKindOfClass:NSURLSessionDataTask.class] &&
            ((NSURLSessionDataTask *)old).state != NSURLSessionTaskStateCompleted &&
            ((NSURLSessionDataTask *)old).state != NSURLSessionTaskStateCanceling)
            return;
        if ([old isKindOfClass:NSURLSessionDataTask.class]) [(NSURLSessionDataTask *)old cancel];
        self.tasks[taskKey] = (id)[NSNull null];
        NSUInteger generation = self.requestGenerations[taskKey].unsignedIntegerValue + 1;
        self.requestGenerations[taskKey] = @(generation);

        // Optional sets are represented by a collapsed placeholder until the
        // user expands them.  Once expanded, expose an explicit Loading state
        // while keeping any usable cached emotes intact.
        if (!asPrimary) {
            BOOL changed = [self updateSevenTVSetPlaceholderForID:setID
                                                            global:global
                                                           channel:channel
                                                            title:nil
                                                        asPrimary:NO
                                                           loaded:NO
                                                          loading:YES
                                                     errorMessage:nil];
            if (changed) [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
        }

        NSString *setCachePath = [self cachePathForSevenTVSetID:setID];
        // Cache reads can hit the disk-backed NSURL store and are therefore
        // kept off stateQueue.  The generation/task checks in the hop back
        // prevent stale data from a previous channel or a completed request
        // from being merged after the live response wins the race.
        dispatch_async(self.ioQueue, ^{
            NSData *cachedData = [NSData dataWithContentsOfFile:setCachePath];
            if (!cachedData.length) return;
            id cachedObject = [NSJSONSerialization JSONObjectWithData:cachedData options:0 error:NULL];
            NSArray *cachedSections = [self sevenTVSetSectionsFromObject:cachedObject
                                                               requestedID:setID
                                                               asPrimary:asPrimary
                                                                 global:global];
            dispatch_async(self.stateQueue, ^{
                if (self.requestGenerations[taskKey].unsignedIntegerValue != generation ||
                    !self.tasks[taskKey] ||
                    (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame))
                    return;
                [self mergeSevenTVSetSections:cachedSections global:global channel:channel];
            });
        });

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 15.0;
        [request setValue:@"TwitchPlusK/1.0" forHTTPHeaderField:@"User-Agent"];
        __block NSURLSessionDataTask *task = nil;
        task = [NSURLSession.sharedSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            // Optional set payloads can be just as large as the parent user
            // payload. Validate and parse them off stateQueue so expanding a
            // set never blocks snapshot reads or the picker UI.
            dispatch_async(self.ioQueue, ^{
                NSError *responseError = error;
                if (!responseError && !S7TVJSONObjectIsValid(data, response, &responseError)) {
                    // Keep the primary provider snapshot usable when an
                    // optional set fails; the next retry can request it again.
                }
                id object = nil;
                NSArray *sections = nil;
                if (!responseError) {
                    object = [NSJSONSerialization JSONObjectWithData:data options:0
                                                                error:&responseError];
                    sections = [self sevenTVSetSectionsFromObject:object
                                                         requestedID:setID
                                                         asPrimary:asPrimary
                                                           global:global];
                    // A syntactically valid but unrelated JSON object is not
                    // an empty set. Treat it as an error so the provider state
                    // can expose Retry instead of leaving the picker stuck in
                    // Loading forever.
                    if (!responseError && !S7TVSetContainerHasEmotePayload(object))
                        S7TVSetCatalogStructureError(&responseError,
                                                     S7TVEmoteProviderIDSevenTV);
                }
                dispatch_async(self.stateQueue, ^{
                if (self.requestGenerations[taskKey].unsignedIntegerValue != generation)
                    return;
                if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)
                    return;
                [self.tasks removeObjectForKey:taskKey];
                if (sections.count) {
                    // Keep the state queue responsive while persisting a set
                    // payload.  Large sets can be several hundred KB and a
                    // synchronous atomic write here would delay the picker
                    // notification and any queued channel cancellation.
                    NSData *cacheData = [data copy];
                    NSString *cachePath = [[self cachePathForSevenTVSetID:setID] copy];
                    dispatch_async(self.ioQueue, ^{
                        [cacheData writeToFile:cachePath
                                      options:NSDataWritingAtomic error:NULL];
                    });
                    [self mergeSevenTVSetSections:sections global:global channel:channel];
                } else if (!responseError) {
                    // An explicit empty `emotes: []` set is a successful
                    // response. Replace a primary channel placeholder with a
                    // loaded-empty section so the picker can hide it normally
                    // instead of leaving the UI in Loading.
                    if (asPrimary) {
                        if (global) {
                            BOOL changed = [self updateSevenTVSetPlaceholderForID:setID
                                                                            global:YES
                                                                           channel:nil
                                                                            title:nil
                                                                        asPrimary:YES
                                                                            loaded:YES
                                                                           loading:NO
                                                                      errorMessage:nil];
                            if (changed) [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
                        } else {
                            [self setSevenTVPrimaryPlaceholderLoading:NO
                                                          errorMessage:nil
                                                               channel:channel];
                        }
                    } else {
                        BOOL changed = [self updateSevenTVSetPlaceholderForID:setID
                                                                        global:global
                                                                       channel:channel
                                                                        title:nil
                                                                    asPrimary:NO
                                                                        loaded:YES
                                                                       loading:NO
                                                                  errorMessage:nil];
                        if (changed) [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
                    }
                } else {
                    // Optional set failures are isolated from the provider's
                    // already usable sections. A primary channel set gets an
                    // explicit Retry header; non-primary set failures remain
                    // optional and never hide channel/global emotes.
                    if (asPrimary) {
                        if (global) {
                            BOOL changed = [self updateSevenTVSetPlaceholderForID:setID
                                                                            global:YES
                                                                           channel:nil
                                                                            title:nil
                                                                        asPrimary:YES
                                                                            loaded:NO
                                                                           loading:NO
                                                                      errorMessage:responseError.localizedDescription
                                                                         ?: @"Unable to load 7TV emote set"];
                            if (changed) [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
                        } else {
                            [self setSevenTVPrimaryPlaceholderLoading:NO
                                                          errorMessage:responseError.localizedDescription
                                                              ?: @"Unable to load 7TV emote set"
                                                               channel:channel];
                        }
                    } else {
                        BOOL changed = [self updateSevenTVSetPlaceholderForID:setID
                                                                        global:global
                                                                       channel:channel
                                                                        title:nil
                                                                    asPrimary:NO
                                                                        loaded:NO
                                                                       loading:NO
                                                                  errorMessage:responseError.localizedDescription
                                                                     ?: @"Unable to load 7TV emote set"];
                        if (changed) [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
                    }
                }
                });
            });
        }];
        self.tasks[taskKey] = task;
        [task resume];
    });
}

- (void)loadSevenTVAdditionalSetsFromData:(NSData *)data
                                   global:(BOOL)global
                                  channel:(NSString *)channel
                               generation:(NSUInteger)parentGeneration
                   requireActiveRequest:(BOOL)requireActiveRequest {
    if (!data.length || !S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV))
        return;
    // Set discovery can enumerate a large user payload.  It is called from
    // both cached and live responses, so decode it off the serial state queue
    // before publishing placeholders or scheduling optional set requests.
    NSData *payload = [data copy];
    dispatch_async(self.ioQueue, ^{
        id object = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
        if (![object isKindOfClass:NSDictionary.class]) return;
        dispatch_async(self.stateQueue, ^{
        if (!S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV)) return;
        NSString *parentKey = [NSString stringWithFormat:@"7tv:%@",
                               global ? @"global" : (channel ?: @"")];
        if (self.requestGenerations[parentKey].unsignedIntegerValue != parentGeneration)
            return;
        // Cached parent data is allowed to discover sets only while the
        // parent request is still active. A late disk callback must never
        // recreate placeholders after the live response has completed.
        if (requireActiveRequest && !self.tasks[parentKey]) return;
        if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame)
            return;

        NSMutableOrderedSet<NSString *> *setIDs = [NSMutableOrderedSet orderedSet];
        S7TVCollectSetIDsFromObject(object, setIDs);
        if (!setIDs.count) return;
        NSString *activeID = S7TVActiveSetIDFromObject(object);
        S7TVEmoteProviderSnapshot *snapshot =
            self.snapshots[@(S7TVEmoteProviderIDSevenTV)];
        NSMutableSet<NSString *> *loadedIDs = [NSMutableSet set];
        for (S7TVEmoteSection *section in snapshot.sections) {
            if (section.kind == S7TVEmoteSectionKindSet &&
                [section.identifier hasPrefix:@"global-set:"]) {
                NSString *sectionID = [section.identifier substringFromIndex:[@"global-set:" length]];
                if (sectionID.length && (section.loaded || section.loading || section.errorMessage.length))
                    [loadedIDs addObject:sectionID];
            } else if (section.kind == S7TVEmoteSectionKindSet &&
                       [section.identifier hasPrefix:@"set:"]) {
                NSString *sectionID = [section.identifier substringFromIndex:[@"set:" length]];
                if (sectionID.length && (section.loaded || section.loading || section.errorMessage.length))
                    [loadedIDs addObject:sectionID];
            }
            for (S7TVEmoteDescriptor *descriptor in section.emotes) {
                if (descriptor.setID.length) [loadedIDs addObject:descriptor.setID];
            }
        }

        BOOL primaryAssigned = NO;
        BOOL primaryScheduled = NO;
        BOOL placeholdersChanged = NO;
        NSUInteger discoveredCount = 0;
        for (NSString *setID in setIDs) {
            // A malformed user payload must not turn into an unbounded list
            // of placeholder sections. Real Twitch users normally expose one
            // active set plus a small number of shared sets; keep a generous
            // but finite bound for the picker metadata.
            if (!setID.length || setID.length > 128 || discoveredCount >= 32)
                continue;
            discoveredCount++;
            if ([loadedIDs containsObject:setID]) continue;

            BOOL primary = activeID.length
                ? [activeID isEqualToString:setID] : !primaryAssigned;
            if (primary) primaryAssigned = YES;
            NSDictionary *setMetadata = S7TVFindSetDictionary(
                object[@"emote_sets"] ?: object[@"sets"], setID);
            NSString *setTitle = S7TVString(setMetadata[@"name"]);
            if (primary) {
                primaryScheduled = YES;
                [self loadSevenTVSetID:setID global:global channel:channel asPrimary:YES];
                if (global) {
                    placeholdersChanged |= [self updateSevenTVSetPlaceholderForID:setID
                                                                            global:YES
                                                                           channel:nil
                                                                            title:setTitle
                                                                        asPrimary:YES
                                                                            loaded:NO
                                                                           loading:YES
                                                                      errorMessage:nil];
                }
            } else {
                // The picker intentionally presents only Channel/Global
                // buckets, so secondary 7TV sets no longer have a visible
                // header the user can expand. Fetch them in the background
                // as soon as they are discovered; NSURLSession applies its
                // per-host connection limit, while the response parsing stays
                // on ioQueue. This keeps every channel set visible without
                // blocking the first picker layout or dropping a set behind a
                // category that no longer exists in the UI.
                placeholdersChanged |= [self updateSevenTVSetPlaceholderForID:setID
                                                                        global:global
                                                                       channel:channel
                                                                    title:setTitle
                                                                asPrimary:NO
                                                                    loaded:NO
                                                                   loading:YES
                                                               errorMessage:nil];
                [self loadSevenTVSetID:setID
                                global:global
                               channel:channel
                             asPrimary:NO];
            }
        }
        if (primaryScheduled) {
            // The parent user payload may contain only set identifiers. Keep
            // a dedicated Channel Emotes placeholder visible until the set
            // response arrives; global sections already cached for the same
            // provider must not be relabelled as loading in the meantime.
            [self setSevenTVPrimaryPlaceholderLoading:YES
                                          errorMessage:nil
                                               channel:channel];
        }
        if (placeholdersChanged)
            [self postUpdateForProvider:S7TVEmoteProviderIDSevenTV];
        });
    });
}

- (void)loadGlobalProviders {
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        if (!S7TVCatalogProviderEnabled((S7TVEmoteProviderID)provider)) continue;
        [self loadProvider:(S7TVEmoteProviderID)provider global:YES channel:nil completion:nil];
    }
}

- (void)loadChannelProvidersForTwitchID:(NSString *)twitchID {
    if (!twitchID.length) return;
    // Keep the channel switch and cancellation on the same serial queue as
    // request generation updates.  The previous implementation scheduled
    // cancellation asynchronously and changed activeChannelID immediately,
    // which allowed an old response to race a new request.
    dispatch_async(self.stateQueue, ^{
        NSString *previousChannel = self.activeChannelID;
        BOOL changed = ![previousChannel isEqualToString:twitchID];
        if (changed && previousChannel.length) {
            NSString *suffix = [NSString stringWithFormat:@":%@", previousChannel];
            for (NSString *key in self.tasks.allKeys.copy) {
                if (![key hasSuffix:suffix]) continue;
                id task = self.tasks[key];
                if ([task isKindOfClass:NSURLSessionDataTask.class]) {
                    [(NSURLSessionDataTask *)task cancel];
                }
                [self.tasks removeObjectForKey:key];
                self.requestGenerations[key] =
                    @(self.requestGenerations[key].unsignedIntegerValue + 1);
            }
        }
        self.activeChannelID = [twitchID copy];
        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            if (!S7TVCatalogProviderEnabled((S7TVEmoteProviderID)provider)) continue;
            [self loadProvider:(S7TVEmoteProviderID)provider global:NO channel:twitchID completion:nil];
        }
    });
}

- (void)loadSevenTVEmoteSetWithID:(NSString *)setID
                            global:(BOOL)global
                           channel:(nullable NSString *)twitchID {
    if (!setID.length || !S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV)) return;
    // Resolve a missing channel on the catalogue queue. This keeps the
    // on-demand request tied to the same active-channel generation as the
    // parent user request and prevents a late expansion from another stream.
    dispatch_async(self.stateQueue, ^{
        NSString *channel = twitchID.length ? twitchID : self.activeChannelID;
        if (!global && !channel.length) return;
        [self loadSevenTVSetID:setID
                        global:global
                       channel:(global ? nil : channel)
                     asPrimary:NO];
    });
}

- (void)loadSetForProvider:(S7TVEmoteProviderID)provider
                identifier:(NSString *)identifier
                    global:(BOOL)global
                   channel:(nullable NSString *)twitchID {
    if (provider != S7TVEmoteProviderIDSevenTV || !identifier.length) return;
    BOOL identifierGlobal = global;
    NSString *setID = S7TVSetIDFromSectionIdentifier(identifier, &identifierGlobal);
    if (!setID.length) return;
    if (!S7TVCatalogProviderEnabled(S7TVEmoteProviderIDSevenTV)) return;
    global = identifierGlobal;
    dispatch_async(self.stateQueue, ^{
        NSString *channel = twitchID.length ? twitchID : self.activeChannelID;
        if (!global && !channel.length) return;
        [self loadSevenTVSetID:setID
                        global:global
                       channel:(global ? nil : channel)
                     asPrimary:NO];
    });
}

- (NSURL *)URLForProvider:(S7TVEmoteProviderID)provider global:(BOOL)global channel:(NSString *)channel {
    NSString *urlString = nil;
    switch (provider) {
        case S7TVEmoteProviderIDSevenTV:
            urlString = global ? @"https://7tv.io/v3/emote-sets/global"
                               : [NSString stringWithFormat:@"https://7tv.io/v3/users/twitch/%@", channel];
            break;
        case S7TVEmoteProviderIDBTTV:
            urlString = global ? @"https://api.betterttv.net/3/cached/emotes/global"
                               : [NSString stringWithFormat:@"https://api.betterttv.net/3/cached/users/twitch/%@", channel];
            break;
        case S7TVEmoteProviderIDFFZ:
            urlString = global ? @"https://api.frankerfacez.com/v1/set/global"
                               : [NSString stringWithFormat:@"https://api.frankerfacez.com/v1/room/id/%@", channel];
            break;
    }
    return [NSURL URLWithString:urlString];
}

- (void)loadProvider:(S7TVEmoteProviderID)provider
             global:(BOOL)global
           channel:(NSString *)channel
         completion:(void (^)(S7TVEmoteProviderSnapshot *))completion {
    if (!global && !channel.length) return;
    if (!S7TVCatalogProviderEnabled(provider)) return;
    NSString *scope = global ? @"global" : channel;
    NSString *taskKey = [NSString stringWithFormat:@"%@:%@", S7TVEmoteProviderKey(provider), scope];
    NSURL *url = [self URLForProvider:provider global:global channel:channel];
    if (!url) return;

    dispatch_async(self.stateQueue, ^{
        // Settings can change between the caller and this queued block.  Do
        // the check again before reserving a request so disabling a provider
        // never starts a late network task.
        if (!S7TVCatalogProviderEnabled(provider)) return;
        S7TVEmoteProviderSnapshot *currentSnapshot = self.snapshots[@(provider)];
        NSDate *lastSuccess = self.lastSuccessfulLoads[taskKey];
        BOOL snapshotMatchesScope = global ||
            [currentSnapshot.channelID caseInsensitiveCompare:channel] == NSOrderedSame;
        // A picker opening is not an explicit refresh action. Keep a recent
        // successful scope alive for five minutes; this removes the repeated
        // Loading -> parse -> reload cycle that used to freeze Twitch every
        // time the picker was opened again. Channel changes still use their
        // own task key and can never reuse another channel's snapshot.
        if (currentSnapshot.state == S7TVEmoteProviderStateLoaded &&
            lastSuccess && snapshotMatchesScope &&
            -[lastSuccess timeIntervalSinceNow] < 300.0) {
            if (completion) {
                S7TVEmoteProviderSnapshot *result = [currentSnapshot copy];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            }
            return;
        }
        NSURLSessionDataTask *old = self.tasks[taskKey];
        // Calls can originate from both manager lifecycle hooks and picker
        // openings.  Do not cancel a healthy request just because the same
        // scope was requested again; otherwise repeated picker openings can
        // starve the provider before its first response arrives.
        if ([old isKindOfClass:NSURLSessionDataTask.class] &&
            old.state != NSURLSessionTaskStateCompleted &&
            old.state != NSURLSessionTaskStateCanceling) {
            return;
        }
        if ([old isKindOfClass:NSURLSessionDataTask.class]) [old cancel];
        self.tasks[taskKey] = (id)[NSNull null];
        NSUInteger generation = self.requestGenerations[taskKey].unsignedIntegerValue + 1;
        self.requestGenerations[taskKey] = @(generation);
        S7TVEmoteProviderSnapshot *oldSnapshot = self.snapshots[@(provider)];
        BOOL sameChannel = global ||
            (oldSnapshot.channelID.length &&
             [oldSnapshot.channelID caseInsensitiveCompare:channel] == NSOrderedSame);
        // A global refresh can race a channel switch.  Do not carry the
        // previous channel's sections into the new snapshot; the next channel
        // response may otherwise briefly expose another stream's emotes.
        BOOL globalSnapshotMatchesActiveChannel =
            !global || !oldSnapshot.channelID.length || !self.activeChannelID.length ||
            [oldSnapshot.channelID caseInsensitiveCompare:self.activeChannelID] == NSOrderedSame;
        NSArray<S7TVEmoteSection *> *existingSections =
            (sameChannel && globalSnapshotMatchesActiveChannel)
                ? (oldSnapshot.sections ?: @[])
                : [self sectionsByCombining:@[] withExisting:oldSnapshot.sections global:NO];
        S7TVEmoteProviderSnapshot *loading = [S7TVEmoteProviderSnapshot new];
        loading.provider = provider;
        loading.state = S7TVEmoteProviderStateLoading;
        loading.channelID = global ? @"" : channel;
        loading.sections = existingSections;
        self.snapshots[@(provider)] = loading;
        [self invalidateDerivedCachesForProvider:provider];
        [self postUpdateForProvider:provider];

        NSString *providerCachePath = [self cachePathForProvider:provider
                                                            global:global
                                                           channel:scope];
        // Do not make the catalogue state queue wait for a disk-backed cache
        // read.  The request is started immediately below; cached data is
        // merged only while that request is still current, so an old cache can
        // never overwrite a newer live response that already completed.
        dispatch_async(self.ioQueue, ^{
            NSData *cachedData = [NSData dataWithContentsOfFile:providerCachePath];
            NSError *parseError = nil;
            NSArray *cachedSections = cachedData.length
                ? [self sectionsFromData:cachedData
                                 provider:provider
                                    global:global
                                   channel:scope
                                     error:&parseError]
                : nil;

            // Migrate the pre-catalogue 7TV JSON cache lazily and off the
            // state/main queues. The old files remain untouched until an
            // explicit cache clear, so a failed write cannot lose data.
            if (!cachedSections.count && provider == S7TVEmoteProviderIDSevenTV) {
                NSString *legacyPath = S7TVLegacySevenTVCachePath(global, scope);
                NSData *legacyData = legacyPath.length
                    ? [NSData dataWithContentsOfFile:legacyPath] : nil;
                NSDictionary *normalized = S7TVNormalizedLegacySevenTVPayload(
                    legacyData, global, scope);
                if (normalized) {
                    NSArray *migratedSections = [self sevenTVSectionsFromObject:normalized
                                                                            global:global];
                    if (migratedSections.count) {
                        cachedSections = migratedSections;
                        NSData *normalizedData =
                            [NSJSONSerialization dataWithJSONObject:normalized
                                                               options:0 error:NULL];
                        if (normalizedData.length) {
                            [normalizedData writeToFile:providerCachePath
                                               options:NSDataWritingAtomic
                                                 error:NULL];
                        }
                    }
                }
            }
            if (!cachedSections.count) return;

            // Parsing a cached provider payload can walk thousands of emotes.
            // Keep JSON decoding and descriptor construction on ioQueue; the
            // state queue must remain available for snapshot reads and channel
            // cancellation while the picker is being presented.
            dispatch_async(self.stateQueue, ^{
                if (self.requestGenerations[taskKey].unsignedIntegerValue != generation ||
                    !self.tasks[taskKey] ||
                    (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame))
                    return;
                if (cachedSections.count) {
                    S7TVEmoteProviderSnapshot *cached = [S7TVEmoteProviderSnapshot new];
                    cached.provider = provider;
                    cached.state = S7TVEmoteProviderStateLoading;
                    cached.channelID = global ? @"" : channel;
                    cached.sections = [self sectionsByCombining:cachedSections
                                                       withExisting:existingSections
                                                           global:global];
                    self.snapshots[@(provider)] = cached;
                    [self invalidateDerivedCachesForProvider:provider];
                    [self postUpdateForProvider:provider];
                }
                if (provider == S7TVEmoteProviderIDSevenTV) {
                    // The cached user payload can still contain set IDs even
                    // when the live request is offline. Discover their
                    // placeholders and resume all discovered set requests in
                    // the background, so cache-first rendering still exposes
                    // secondary channel/global sets without waiting for a
                    // fresh parent response or a manual scroll.
                    [self loadSevenTVAdditionalSetsFromData:cachedData
                                                     global:global
                                                    channel:(global ? nil : channel)
                                                 generation:generation
                                     requireActiveRequest:YES];
                }
            });
        });

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 15.0;
        [request setValue:@"TwitchPlusK/1.0" forHTTPHeaderField:@"User-Agent"];
        __block NSURLSessionDataTask *task = nil;
        task = [NSURLSession.sharedSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            // JSON validation/parsing can involve thousands of descriptors.
            // Keep it off the serial state queue so snapshotForProvider never
            // makes the main thread wait behind a large provider response.
            dispatch_async(self.ioQueue, ^{
                NSError *responseError = error;
                if (!responseError && !S7TVJSONObjectIsValid(data, response, &responseError)) {
                    // responseError is filled by the validator
                }
                NSArray *sections = nil;
                if (!responseError)
                    sections = [self sectionsFromData:data provider:provider global:global channel:scope error:&responseError];
                dispatch_async(self.stateQueue, ^{
                if (self.requestGenerations[taskKey].unsignedIntegerValue != generation) return;
                if (!global && [self.activeChannelID caseInsensitiveCompare:channel] != NSOrderedSame) return;
                [self.tasks removeObjectForKey:taskKey];
                S7TVEmoteProviderSnapshot *previous = self.snapshots[@(provider)];
                S7TVEmoteProviderSnapshot *result = [S7TVEmoteProviderSnapshot new];
                result.provider = provider;
                result.channelID = global ? @"" : channel;
                if (sections) {
                    result.state = S7TVEmoteProviderStateLoaded;
                    self.lastSuccessfulLoads[taskKey] = [NSDate date];
                    // A global response may finish after a channel switch.
                    // Do not reattach the previous channel's sections in that
                    // race; only preserve them when the snapshot still belongs
                    // to the active channel (the next channel request will
                    // repopulate them otherwise).
                    NSArray<S7TVEmoteSection *> *existing = previous.sections ?: @[];
                    BOOL canKeepPreviousChannel = !global ||
                        !previous.channelID.length || !self.activeChannelID.length ||
                        [previous.channelID caseInsensitiveCompare:self.activeChannelID] == NSOrderedSame;
                    if (global && !canKeepPreviousChannel)
                        existing = [self sectionsByCombining:@[]
                                               withExisting:existing
                                                   global:NO];
                    result.sections = [self sectionsByCombining:sections
                                                       withExisting:existing
                                                           global:global];
                    if (global && canKeepPreviousChannel && previous.channelID.length)
                        result.channelID = previous.channelID;
                    // Persist off stateQueue: provider responses may contain
                    // thousands of emotes and the atomic write must not
                    // postpone the snapshot publication or a channel switch.
                    NSData *cacheData = [data copy];
                    NSString *cachePath = [[self cachePathForProvider:provider
                                                                  global:global
                                                                 channel:scope] copy];
                    dispatch_async(self.ioQueue, ^{
                        [cacheData writeToFile:cachePath
                                      options:NSDataWritingAtomic error:NULL];
                    });
                } else {
                    result.state = S7TVEmoteProviderStateError;
                    result.sections = previous.sections ?: existingSections;
                    result.errorMessage = responseError.localizedDescription ?: @"Unable to load emotes";
                }
                self.snapshots[@(provider)] = result;
                [self invalidateDerivedCachesForProvider:provider];
                [self postUpdateForProvider:provider];
                if (provider == S7TVEmoteProviderIDSevenTV && data.length) {
                    [self loadSevenTVAdditionalSetsFromData:data
                                                     global:global
                                                    channel:(global ? nil : channel)
                                                 generation:generation
                                     requireActiveRequest:NO];
                }
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion([result copy]); });
                });
            });
        }];
        self.tasks[taskKey] = task;
        [task resume];
    });
}

- (NSArray<S7TVEmoteSection *> *)sectionsByCombining:(NSArray<S7TVEmoteSection *> *)fresh
                                        withExisting:(NSArray<S7TVEmoteSection *> *)existing
                                               global:(BOOL)global {
    NSMutableArray *combined = [fresh mutableCopy] ?: [NSMutableArray array];
    for (S7TVEmoteSection *section in existing) {
        BOOL keepExisting = global
            ? (section.kind != S7TVEmoteSectionKindGlobal)
            : (section.kind == S7TVEmoteSectionKindGlobal ||
               [section.identifier hasPrefix:@"global-set:"]);
        if (!keepExisting) continue;
        BOOL duplicate = NO;
        for (S7TVEmoteSection *candidate in combined) {
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

- (void)cancelLoadsForChannel:(NSString *)channel {
    if (!channel.length) return;
    dispatch_async(self.stateQueue, ^{
        NSString *suffix = [NSString stringWithFormat:@":%@", channel];
        for (NSString *key in self.tasks.allKeys.copy) {
            if ([key hasSuffix:suffix]) {
                id task = self.tasks[key];
                if ([task isKindOfClass:NSURLSessionDataTask.class]) [(NSURLSessionDataTask *)task cancel];
                [self.tasks removeObjectForKey:key];
                self.requestGenerations[key] = @(self.requestGenerations[key].unsignedIntegerValue + 1);
            }
        }
    });
}

- (void)clearCachedDataWithCompletion:(dispatch_block_t)completion {
    dispatch_async(self.stateQueue, ^{
        // Cancel every scope and advance its generation before deleting the
        // files.  A cancelled NSURLSession callback may still arrive later;
        // the generation check then prevents it from repopulating a cache
        // that the user explicitly cleared.
        for (NSString *key in self.tasks.allKeys.copy) {
            id task = self.tasks[key];
            if ([task isKindOfClass:NSURLSessionDataTask.class])
                [(NSURLSessionDataTask *)task cancel];
            self.requestGenerations[key] =
                @(self.requestGenerations[key].unsignedIntegerValue + 1);
        }
        [self.tasks removeAllObjects];
        [self.lastSuccessfulLoads removeAllObjects];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *directory = [self cacheDirectory];
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:directory error:NULL]) {
            NSString *path = [directory stringByAppendingPathComponent:file];
            [fileManager removeItemAtPath:path error:NULL];
        }

        // The legacy manager stored 7TV JSON under Library/Caches/s7tv.
        // It is part of the same emote cache now that migration is owned by
        // this catalogue, so an explicit "clear cache" must remove it too.
        NSString *legacyDirectory = [directory.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"s7tv"];
        for (NSString *file in [fileManager contentsOfDirectoryAtPath:legacyDirectory
                                                                  error:NULL]) {
            NSString *path = [legacyDirectory stringByAppendingPathComponent:file];
            [fileManager removeItemAtPath:path error:NULL];
        }

        for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
             provider <= S7TVEmoteProviderIDFFZ; provider++) {
            S7TVEmoteProviderSnapshot *snapshot = [S7TVEmoteProviderSnapshot new];
            snapshot.provider = (S7TVEmoteProviderID)provider;
            snapshot.state = S7TVEmoteProviderStateIdle;
            snapshot.channelID = self.activeChannelID ?: @"";
            snapshot.sections = @[];
            self.snapshots[@(provider)] = snapshot;
            [self invalidateDerivedCachesForProvider:(S7TVEmoteProviderID)provider];
            [self postUpdateForProvider:(S7TVEmoteProviderID)provider];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)postUpdateForProvider:(S7TVEmoteProviderID)provider {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVProviderCatalogDidUpdateNotification
                          object:self userInfo:@{@"provider": @(provider)}];
    });
}

- (NSArray<S7TVEmoteSection *> *)sectionsFromData:(NSData *)data
                                         provider:(S7TVEmoteProviderID)provider
                                            global:(BOOL)global
                                           channel:(NSString *)channel
                                             error:(NSError **)error {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!object) return nil;
    // A syntactically valid JSON error payload must not be treated as a
    // successful empty catalogue. Validate the provider's top-level shape
    // before parsing so the picker can expose a retry state.
    BOOL validShape = NO;
    if (provider == S7TVEmoteProviderIDSevenTV) {
        if ([object isKindOfClass:NSDictionary.class]) {
            id set = object[@"emote_set"] ?: object[@"emoteSet"] ?: object[@"set"];
            id additionalSets = object[@"emote_sets"] ?: object[@"sets"];
            BOOL directPayload = S7TVDictionaryHasDirectEmoteCollection((NSDictionary *)object);
            BOOL setIdentifierHasPayload = [set isKindOfClass:NSString.class] &&
                S7TVFindSetDictionary(additionalSets, set) != nil;
            NSMutableOrderedSet *setIDs = [NSMutableOrderedSet orderedSet];
            S7TVCollectSetIDsFromObject(object, setIDs);
            BOOL hasSetIdentifier = setIDs.count > 0;
            validShape = global
                ? (directPayload ||
                   [set isKindOfClass:NSDictionary.class] || setIdentifierHasPayload ||
                   hasSetIdentifier || S7TVSetContainerHasEmotePayload(additionalSets))
                : (directPayload || [set isKindOfClass:NSDictionary.class] || set == NSNull.null ||
                   setIdentifierHasPayload || hasSetIdentifier ||
                   S7TVSetContainerHasEmotePayload(additionalSets));
        }
    } else if (provider == S7TVEmoteProviderIDBTTV) {
        if (global) {
            validShape = [object isKindOfClass:NSArray.class] ||
                ([object isKindOfClass:NSDictionary.class] &&
                 [object[@"emotes"] isKindOfClass:NSArray.class]);
        } else if ([object isKindOfClass:NSDictionary.class]) {
            validShape = [object[@"channelEmotes"] isKindOfClass:NSArray.class] ||
                [object[@"sharedEmotes"] isKindOfClass:NSArray.class] ||
                // Older BTTV responses (and some cached payloads) expose the
                // channel list under the generic `emotes` key. Accept that
                // shape as well so a provider version cannot make the picker
                // silently appear empty.
                [object[@"emotes"] isKindOfClass:NSArray.class];
        }
    } else if (provider == S7TVEmoteProviderIDFFZ) {
        validShape = [object isKindOfClass:NSDictionary.class] &&
            [object[@"sets"] isKindOfClass:NSDictionary.class];
    }
    if (!validShape) {
        S7TVSetCatalogStructureError(error, provider);
        return nil;
    }
    switch (provider) {
        case S7TVEmoteProviderIDSevenTV: return [self sevenTVSectionsFromObject:object global:global];
        case S7TVEmoteProviderIDBTTV: return [self bttvSectionsFromObject:object global:global];
        case S7TVEmoteProviderIDFFZ: return [self ffzSectionsFromObject:object global:global];
    }
    return nil;
}

- (S7TVEmoteSection *)sevenTVSectionFromSet:(NSDictionary *)set
                                      global:(BOOL)global
                                 sectionKind:(S7TVEmoteSectionKind)kind
                             sectionIdentifier:(NSString *)identifier
                                      title:(NSString *)title {
    (void)global;
    if (![set isKindOfClass:NSDictionary.class]) return nil;
    NSArray *raw = S7TVEmoteEntriesFromSet(set);
    NSMutableArray *emotes = [NSMutableArray array];
    for (id rawEntry in raw) {
        NSDictionary *entry = [rawEntry isKindOfClass:NSDictionary.class] ? rawEntry : nil;
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        // REST v3 historically returned `{data, flags}` entries, while the
        // current model also exposes GraphQL-shaped `{emote, alias, flags}`
        // entries. Normalize both forms at this boundary so the picker and
        // tokenizer never need to know which API revision supplied a set.
        NSDictionary *nestedEmote = [entry[@"emote"] isKindOfClass:NSDictionary.class]
            ? entry[@"emote"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:NSDictionary.class]
            ? entry[@"data"] : (nestedEmote ?: entry);
        NSString *eid = S7TVString(nestedEmote[@"id"]) ?:
            S7TVString(data[@"id"]) ?: S7TVString(entry[@"id"]);
        NSString *name = S7TVString(entry[@"name"]) ?: S7TVString(entry[@"alias"]) ?:
            S7TVString(data[@"name"]) ?: S7TVString(data[@"defaultName"]);
        NSDictionary *host = [data[@"host"] isKindOfClass:NSDictionary.class] ? data[@"host"] : @{};
        NSMutableDictionary *urls = [NSMutableDictionary dictionary];
        NSArray *files = [host[@"files"] isKindOfClass:NSArray.class] ? host[@"files"] : @[];
        NSInteger width = S7TVInteger(data[@"width"]), height = S7TVInteger(data[@"height"]);
        BOOL animatedFromFiles = NO;
        for (id rawFile in files) {
            // The v3 REST API currently returns `host.files` as plain names
            // (for example `1x.webp`), while older/cache-adapted payloads
            // sometimes wrap the same name and dimensions in a dictionary.
            // Accept both forms; rejecting the string form leaves descriptors
            // without image URLs and makes an otherwise valid 7TV set look
            // empty until a legacy cache happens to be available.
            NSString *fileName = nil;
            NSInteger fileWidth = 0;
            NSInteger fileHeight = 0;
            if ([rawFile isKindOfClass:NSString.class]) {
                fileName = rawFile;
            } else if ([rawFile isKindOfClass:NSDictionary.class]) {
                NSDictionary *file = (NSDictionary *)rawFile;
                fileName = S7TVString(file[@"name"]) ?: S7TVString(file[@"path"]);
                fileWidth = S7TVInteger(file[@"width"]);
                fileHeight = S7TVInteger(file[@"height"]);
                if (S7TVInteger(file[@"frame_count"]) > 1 ||
                    S7TVInteger(file[@"frameCount"]) > 1) {
                    animatedFromFiles = YES;
                }
            }
            NSString *hostURL = S7TVString(host[@"url"]);
            if (!hostURL.length || !fileName.length) continue;
            if ([hostURL hasPrefix:@"//"]) hostURL = [@"https:" stringByAppendingString:hostURL];
            if ([hostURL hasSuffix:@"/"]) hostURL = [hostURL substringToIndex:hostURL.length - 1];
            NSInteger scale = 0;
            NSScanner *scanner = [NSScanner scannerWithString:fileName];
            [scanner scanInteger:&scale];
            if (scale > 0) urls[@(scale)] = [NSString stringWithFormat:@"%@/%@", hostURL, fileName];
            if (!width) width = fileWidth;
            if (!height) height = fileHeight;
        }
        // Newer set responses can provide normalized image objects instead of
        // the legacy host/files pair. Keep their explicit scale and URL, and
        // use the 1x (or first available) dimensions for layout reservation.
        NSArray *images = [data[@"images"] isKindOfClass:NSArray.class]
            ? data[@"images"] : @[];
        for (NSDictionary *image in images) {
            if (![image isKindOfClass:NSDictionary.class]) continue;
            NSString *imageURL = S7TVString(image[@"url"]);
            NSInteger scale = S7TVInteger(image[@"scale"]);
            if ([imageURL hasPrefix:@"//"])
                imageURL = [@"https:" stringByAppendingString:imageURL];
            if (imageURL.length && scale > 0) urls[@(scale)] = imageURL;
            if (!width) width = S7TVInteger(image[@"width"]);
            if (!height) height = S7TVInteger(image[@"height"]);
        }
        // The public 7TV model may expose only `aspectRatio` (especially in
        // compact/cache-adapted responses) instead of width/height. Preserve
        // that ratio for the shared chat/thread renderer; a neutral 32pt
        // reference height is sufficient because the renderer scales the
        // descriptor to the user's configured emote size.
        CGFloat aspectRatio = S7TVDouble(data[@"aspectRatio"]);
        if (aspectRatio <= 0.0) aspectRatio = S7TVDouble(data[@"aspect_ratio"]);
        if (aspectRatio <= 0.0) aspectRatio = S7TVDouble(entry[@"aspectRatio"]);
        if (aspectRatio <= 0.0) aspectRatio = S7TVDouble(nestedEmote[@"aspectRatio"]);
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
        NSInteger dataFlags = S7TVInteger(data[@"flags"]);
        NSInteger entryFlags = S7TVInteger(entry[@"flags"]);
        // The legacy v3 REST payload stores Zero-Width on the active set
        // entry (bit 0), while newer payloads expose the emote flag bitfield
        // on `data` (bit 8). Accept both forms and the boolean fields emitted
        // by newer REST/cache adapters so overlays survive an API migration.
        NSDictionary *entryFlagObject = [entry[@"flags"] isKindOfClass:NSDictionary.class]
            ? entry[@"flags"] : @{};
        NSDictionary *dataFlagObject = [data[@"flags"] isKindOfClass:NSDictionary.class]
            ? data[@"flags"] : @{};
        NSDictionary *nestedFlagObject = [nestedEmote[@"flags"] isKindOfClass:NSDictionary.class]
            ? nestedEmote[@"flags"] : @{};
        BOOL zeroWidth = S7TVBool(entry[@"zeroWidth"]) ||
            S7TVBool(entry[@"zero_width"]) ||
            S7TVBool(entry[@"defaultZeroWidth"]) ||
            S7TVBool(entry[@"default_zero_width"]) ||
            S7TVBool(data[@"zeroWidth"]) ||
            S7TVBool(data[@"zero_width"]) ||
            S7TVBool(data[@"defaultZeroWidth"]) ||
            S7TVBool(data[@"default_zero_width"]) ||
            S7TVBool(entryFlagObject[@"zeroWidth"]) ||
            S7TVBool(entryFlagObject[@"zero_width"]) ||
            S7TVBool(entryFlagObject[@"defaultZeroWidth"]) ||
            S7TVBool(entryFlagObject[@"default_zero_width"]) ||
            S7TVBool(dataFlagObject[@"zeroWidth"]) ||
            S7TVBool(dataFlagObject[@"zero_width"]) ||
            S7TVBool(dataFlagObject[@"defaultZeroWidth"]) ||
            S7TVBool(dataFlagObject[@"default_zero_width"]) ||
            S7TVBool(nestedFlagObject[@"defaultZeroWidth"]) ||
            S7TVBool(nestedFlagObject[@"zeroWidth"]) ||
            S7TVBool(nestedFlagObject[@"zero_width"]) ||
            ((entryFlags & 1) != 0) || ((entryFlags & (1 << 8)) != 0) ||
            ((dataFlags & (1 << 1)) != 0) ||
            ((dataFlags & (1 << 8)) != 0);
        // Depending on the 7TV REST/cache version, aliases may live on the
        // active-set entry, on the embedded emote data object, or on both.
        // Merge both sources instead of choosing one so every documented
        // alias remains resolvable after a cache/API shape change.
        NSMutableArray *aliases = [NSMutableArray array];
        for (id aliasSource in @[entry[@"aliases"] ?: NSNull.null,
                                 data[@"aliases"] ?: NSNull.null]) {
            for (NSString *alias in S7TVAliases(aliasSource)) {
                if (![aliases containsObject:alias]) [aliases addObject:alias];
            }
        }
        NSString *entryAlias = S7TVString(entry[@"alias"]);
        NSString *dataName = S7TVString(data[@"name"]);
        if (entryAlias.length && ![entryAlias isEqualToString:name] &&
            ![aliases containsObject:entryAlias]) [aliases addObject:entryAlias];
        if (dataName.length && ![dataName isEqualToString:name] &&
            ![aliases containsObject:dataName]) [aliases addObject:dataName];
        NSString *defaultName = S7TVString(data[@"defaultName"]);
        if (defaultName.length && ![defaultName isEqualToString:name] &&
            ![aliases containsObject:defaultName]) [aliases addObject:defaultName];
        BOOL animated = S7TVBool(data[@"animated"]) ||
            S7TVBool(entry[@"animated"]) ||
            S7TVBool(dataFlagObject[@"animated"]) ||
            S7TVBool(nestedFlagObject[@"animated"]) ||
            // EmoteFlagsModel uses bit 0 for the animated flag. Active-set
            // flags intentionally are not interpreted here because their bit
            // 0 denotes Zero-Width in the v3 REST payload.
            ((dataFlags & 1) != 0) || animatedFromFiles;
        for (NSDictionary *image in images) {
            if (S7TVInteger(image[@"frameCount"]) > 1 ||
                S7TVBool(image[@"animated"])) {
                animated = YES;
                break;
            }
        }
        [emotes addObject:[[S7TVEmoteDescriptor alloc]
            initWithProvider:S7TVEmoteProviderIDSevenTV providerIdentifier:@"7tv"
            emoteID:eid name:name aliases:aliases sectionKind:kind sectionIdentifier:identifier
            sectionTitle:title setID:S7TVString(set[@"id"])
            nativeSize:CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1)
            animated:animated
            zeroWidth:zeroWidth
            modifierMetadata:@{ @"flags": @(dataFlags), @"entryFlags": @(entryFlags) }
            imageURLs:urls]];
    }
    if (!emotes.count) return nil;
    return [[S7TVEmoteSection alloc]
        initWithProvider:S7TVEmoteProviderIDSevenTV
        kind:kind identifier:identifier title:title emotes:emotes
        loaded:YES loading:NO errorMessage:nil];
}

- (NSArray<S7TVEmoteSection *> *)sevenTVSectionsFromObject:(id)object global:(BOOL)global {
    NSDictionary *root = [object isKindOfClass:NSDictionary.class] ? object : nil;
    if (!root) return @[];

    NSMutableArray<S7TVEmoteSection *> *sections = [NSMutableArray array];
    NSDictionary *primarySet = nil;
    id rawPrimary = root[@"emote_set"] ?: root[@"emoteSet"] ?: root[@"set"];
    id rawAdditionalSets = root[@"emote_sets"] ?: root[@"sets"];
    if ([rawPrimary isKindOfClass:NSDictionary.class]) {
        primarySet = rawPrimary;
    } else if (S7TVDictionaryHasDirectEmoteCollection(root)) {
        // The global endpoint commonly returns the set object directly.
        primarySet = root;
    } else if ([rawPrimary isKindOfClass:NSString.class]) {
        primarySet = S7TVFindSetDictionary(rawAdditionalSets, rawPrimary);
        if (primarySet && !S7TVString(primarySet[@"id"]).length) {
            NSMutableDictionary *withIdentifier = [primarySet mutableCopy];
            withIdentifier[@"id"] = rawPrimary;
            primarySet = withIdentifier.copy;
        }
    } else if ([rawAdditionalSets isKindOfClass:NSDictionary.class] &&
               S7TVDictionaryHasDirectEmoteCollection((NSDictionary *)rawAdditionalSets)) {
        // Compact/cache adapters sometimes put the active set directly in
        // `sets` instead of wrapping it in `emote_set` or a map keyed by ID.
        // Parse it immediately so the first picker snapshot is useful even
        // before the optional `/emote-sets/<id>` request completes.
        primarySet = rawAdditionalSets;
    } else if (!rawPrimary) {
        // Newer user responses can expose only an emote_set_id/connection.
        // The corresponding set is fetched by loadSevenTVAdditionalSets...
        // so there is intentionally no synthetic empty Channel section here.
    }

    // The current v3 user endpoint can put the complete active set under a
    // Twitch connection. Prefer that payload over an ID-only placeholder so a
    // fresh picker can render Channel Emotes without waiting for a second
    // request (or requiring a scroll/tab change to trigger layout).
    if (!global && (!primarySet || !S7TVDictionaryHasDirectEmoteCollection(primarySet))) {
        NSDictionary *connectionSet = S7TVConnectionSetWithPayload(root[@"connections"]);
        if (connectionSet) primarySet = connectionSet;
    }

    if (primarySet && !S7TVString(primarySet[@"id"]).length) {
        NSString *fallbackID = S7TVString(rawPrimary);
        if (!fallbackID.length) fallbackID = S7TVActiveSetIDFromObject(root);
        if (fallbackID.length) {
            NSMutableDictionary *withIdentifier = [primarySet mutableCopy];
            withIdentifier[@"id"] = fallbackID;
            primarySet = withIdentifier.copy;
        }
    }

    NSString *primaryID = S7TVString(primarySet[@"id"]);
    if (primarySet) {
        S7TVEmoteSectionKind kind = global
            ? S7TVEmoteSectionKindGlobal : S7TVEmoteSectionKindChannel;
        NSString *identifier = global ? @"global" : @"channel";
        NSString *title = global ? @"Global Emotes" : @"Channel Emotes";
        S7TVEmoteSection *section = [self sevenTVSectionFromSet:primarySet
                                                            global:global
                                                       sectionKind:kind
                                                   sectionIdentifier:identifier
                                                            title:title];
        if (section) [sections addObject:section];
    }

    // Some 7TV-compatible responses include several available sets in
    // `emote_sets`/`sets` in addition to the active set. Expose those sets as
    // their own collapsible picker sections when the payload provides them;
    // no extra unauthenticated endpoint is guessed or required.
    if ([rawAdditionalSets isKindOfClass:NSDictionary.class]) {
        NSDictionary *directSet = (NSDictionary *)rawAdditionalSets;
        BOOL isDirectSet = S7TVDictionaryHasDirectEmoteCollection(directSet);
        if (isDirectSet && directSet != primarySet) {
            NSString *setID = S7TVString(directSet[@"id"]);
            if (!setID.length || ![setID isEqualToString:primaryID]) {
                NSString *identifier = setID.length
                    ? S7TVSetSectionIdentifier(setID, global) : @"set:additional";
                NSString *title = S7TVString(directSet[@"name"]) ?: @"Emote Set";
                S7TVEmoteSection *section = [self sevenTVSectionFromSet:directSet
                                                                    global:NO
                                                               sectionKind:S7TVEmoteSectionKindSet
                                                           sectionIdentifier:identifier
                                                                    title:title];
                if (section) [sections addObject:section];
            }
        } else {
            [directSet enumerateKeysAndObjectsUsingBlock:
                ^(id key, id value, BOOL *stop) {
                if (![value isKindOfClass:NSDictionary.class]) return;
                NSDictionary *set = value;
                NSString *setID = S7TVString(set[@"id"]) ?: S7TVString(key);
                if (setID.length && [setID isEqualToString:primaryID]) return;
                if (!setID.length) return;
                if (!S7TVString(set[@"id"]).length) {
                    NSMutableDictionary *withIdentifier = [set mutableCopy];
                    withIdentifier[@"id"] = setID;
                    set = withIdentifier.copy;
                }
                NSString *identifier = S7TVSetSectionIdentifier(setID, global);
                NSString *title = S7TVString(set[@"name"]) ?: @"Emote Set";
                S7TVEmoteSection *section = [self sevenTVSectionFromSet:set
                                                                    global:NO
                                                               sectionKind:S7TVEmoteSectionKindSet
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
            NSString *setID = S7TVString(set[@"id"]);
            if (setID.length && [setID isEqualToString:primaryID]) { index++; continue; }
            if (!setID.length) setID = [NSString stringWithFormat:@"index:%lu", (unsigned long)index];
            NSString *identifier = S7TVSetSectionIdentifier(setID, global);
            NSString *title = S7TVString(set[@"name"]) ?: @"Emote Set";
            S7TVEmoteSection *section = [self sevenTVSectionFromSet:set
                                                                global:NO
                                                           sectionKind:S7TVEmoteSectionKindSet
                                                       sectionIdentifier:identifier
                                                                title:title];
            if (section) [sections addObject:section];
            index++;
        }
    }
    return sections.copy;
}

- (NSArray<S7TVEmoteSection *> *)sevenTVSetSectionsFromObject:(id)object
                                                     requestedID:(NSString *)requestedID
                                                     asPrimary:(BOOL)asPrimary
                                                       global:(BOOL)global {
    NSDictionary *root = [object isKindOfClass:NSDictionary.class] ? object : nil;
    if (!root) return @[];
    NSDictionary *set = [root[@"emote_set"] isKindOfClass:NSDictionary.class]
        ? root[@"emote_set"]
        : ([root[@"emoteSet"] isKindOfClass:NSDictionary.class]
            ? root[@"emoteSet"] : root);
    if (!S7TVDictionaryHasDirectEmoteCollection(set)) {
        NSDictionary *wrapped = [root[@"set"] isKindOfClass:NSDictionary.class]
            ? root[@"set"] : nil;
        if (S7TVDictionaryHasDirectEmoteCollection(wrapped)) set = wrapped;
    }
    if (!S7TVDictionaryHasDirectEmoteCollection(set)) return @[];
    NSString *setID = S7TVString(set[@"id"]) ?: requestedID;
    if (!setID.length) return @[];
    NSString *title = asPrimary
        ? (global ? @"Global Emotes" : @"Channel Emotes")
        : (S7TVString(set[@"name"]) ?: @"Emote Set");
    S7TVEmoteSectionKind kind = asPrimary
        ? (global ? S7TVEmoteSectionKindGlobal : S7TVEmoteSectionKindChannel)
        : S7TVEmoteSectionKindSet;
    NSString *identifier = asPrimary
        ? (global ? @"global" : @"channel")
        : S7TVSetSectionIdentifier(setID, global);
    S7TVEmoteSection *section = [self sevenTVSectionFromSet:set
                                                       global:global
                                                  sectionKind:kind
                                              sectionIdentifier:identifier
                                                       title:title];
    return section ? @[section] : @[];
}

- (NSArray<S7TVEmoteSection *> *)bttvSectionsFromObject:(id)object global:(BOOL)global {
    NSArray *(^arrayForKey)(NSString *) = ^NSArray *(NSString *key) {
        id value = [object isKindOfClass:NSDictionary.class] ? object[key] : nil;
        return [value isKindOfClass:NSArray.class] ? value : @[];
    };
    NSMutableArray *sections = [NSMutableArray array];
    NSArray *globalValues = [object isKindOfClass:NSArray.class] ? object : arrayForKey(@"emotes");
    NSArray *channelValues = arrayForKey(@"channelEmotes");
    // BTTV has used both `channelEmotes` and the generic `emotes` key for
    // channel payloads. Prefer the explicit key, but fall back to the latter
    // when needed so those emotes are never dropped from the picker.
    if (!channelValues.count) channelValues = arrayForKey(@"emotes");
    NSArray *sharedValues = arrayForKey(@"sharedEmotes");
    NSArray *groups = global ? @[@[@"global", @"Global Emotes", globalValues]]
                             : @[@[@"channel", @"Channel Emotes", channelValues],
                                 @[@"shared", @"Shared Emotes", sharedValues]];
    for (NSArray *group in groups) {
        NSMutableArray *emotes = [NSMutableArray array];
        for (NSDictionary *raw in group[2]) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            // Be defensive with third-party/cache payloads that may expose
            // effect-like entries next to regular BTTV emotes. They are not
            // normal emotes and are intentionally reserved for the v2 UI.
            if (S7TVBool(raw[@"modifier"]) || S7TVBool(raw[@"isModifier"])) continue;
            NSString *eid = S7TVString(raw[@"id"]), *name = S7TVString(raw[@"code"]);
            if (!eid.length || !name.length) continue;
            NSMutableDictionary *urls = [NSMutableDictionary dictionary];
            for (NSInteger scale = 1; scale <= 4; scale++) {
                // BTTV currently publishes 1x/2x/3x.  Do not manufacture a
                // 4x URL: imageURLForResolution: will correctly fall back to
                // the closest available 3x asset.
                if (scale == 4) break;
                urls[@(scale)] = [NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/%ldx", eid, (long)scale];
            }
            NSInteger width = S7TVInteger(raw[@"width"]), height = S7TVInteger(raw[@"height"]);
            NSString *imageType = S7TVString(raw[@"imageType"]);
            BOOL animated = S7TVBool(raw[@"animated"]) ||
                (imageType.length &&
                 [imageType caseInsensitiveCompare:@"gif"] == NSOrderedSame);
            [emotes addObject:[[S7TVEmoteDescriptor alloc]
                initWithProvider:S7TVEmoteProviderIDBTTV providerIdentifier:@"bttv"
                emoteID:eid name:name aliases:S7TVAliases(raw[@"aliases"])
                sectionKind:([group[0] isEqual:@"shared"] ? S7TVEmoteSectionKindShared :
                             (global ? S7TVEmoteSectionKindGlobal : S7TVEmoteSectionKindChannel))
                sectionIdentifier:group[0] sectionTitle:group[1] setID:nil
                nativeSize:CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1)
                animated:animated zeroWidth:NO modifierMetadata:@{} imageURLs:urls]];
        }
        if (emotes.count) [sections addObject:[[S7TVEmoteSection alloc]
            initWithProvider:S7TVEmoteProviderIDBTTV
            kind:([group[0] isEqual:@"shared"] ? S7TVEmoteSectionKindShared :
                  (global ? S7TVEmoteSectionKindGlobal : S7TVEmoteSectionKindChannel))
            identifier:group[0] title:group[1] emotes:emotes loaded:YES loading:NO errorMessage:nil]];
    }
    return sections.copy;
}

- (NSArray<S7TVEmoteSection *> *)ffzSectionsFromObject:(id)object global:(BOOL)global {
    NSDictionary *sets = [object isKindOfClass:NSDictionary.class] ? object[@"sets"] : nil;
    if (![sets isKindOfClass:NSDictionary.class]) return @[];
    // FFZ's global endpoint also returns sets that are only globally usable
    // by particular users.  Without authentication we can safely expose the
    // provider's `default_sets` only; otherwise chat would resolve emote
    // names that the current viewer cannot actually send.
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
    // FFZ returns the active room set as a numeric ID in some API versions
    // and as a string in others. Normalize both forms so the channel section
    // is not accidentally presented as an anonymous set.
    NSString *roomSet = S7TVString(rawRoomSet);
    if (!roomSet.length && [rawRoomSet isKindOfClass:NSDictionary.class])
        roomSet = S7TVString(rawRoomSet[@"id"]);
    if (!roomSet.length && rawRoomSet)
        roomSet = [NSString stringWithFormat:@"%@", rawRoomSet];
    NSMutableArray *sections = [NSMutableArray array];
    // The FFZ global endpoint can expose several default sets.  They are all
    // part of the same provider-global catalogue, so keep one clear
    // "Global Emotes" section instead of repeating the same header once per
    // set.  The original set ID remains on each descriptor for identity and
    // future set-aware UI.
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
            // FFZ exposes Emote Effects as modifier entries in the same
            // `emoticons` array as regular emotes.  Effects are intentionally
            // kept for the v2 modifier UI and must not be sent as standalone
            // chat emotes in the first multi-provider release.
            if (S7TVBool(raw[@"modifier"]) || S7TVBool(raw[@"isModifier"])) continue;
            NSString *eid = [NSString stringWithFormat:@"%@", raw[@"id"] ?: @""];
            NSString *name = S7TVString(raw[@"name"]);
            if (!eid.length || !name.length) continue;
            NSMutableDictionary *urls = [S7TVURLMap(raw[@"urls"]) mutableCopy];
            // FFZ keeps animated variants in a separate DPI -> URL map. Keep
            // both maps so the shared renderer can select an animated frame
            // when one is available and fall back to the static CDN URL.
            NSDictionary *animatedURLs = S7TVURLMap(raw[@"animated"]);
            if (animatedURLs.count) [urls addEntriesFromDictionary:animatedURLs];
            BOOL animated = animatedURLs.count > 0 || S7TVBool(raw[@"animated"]);
            NSInteger width = S7TVInteger(raw[@"width"]), height = S7TVInteger(raw[@"height"]);
            S7TVEmoteSectionKind kind = global ? S7TVEmoteSectionKindGlobal
                : ([setKey isEqualToString:roomSet] ? S7TVEmoteSectionKindChannel : S7TVEmoteSectionKindSet);
            NSString *title = global ? @"Global Emotes" :
                ([setKey isEqualToString:roomSet] ? @"Channel Emotes" :
                 (S7TVString(value[@"name"]) ?: S7TVString(value[@"title"]) ?: @"Emote Set"));
            [emotes addObject:[[S7TVEmoteDescriptor alloc]
                initWithProvider:S7TVEmoteProviderIDFFZ providerIdentifier:@"ffz"
                emoteID:eid name:name aliases:S7TVAliases(raw[@"aliases"])
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
            S7TVEmoteSectionKind kind =
                ([setKey isEqualToString:roomSet] ? S7TVEmoteSectionKindChannel : S7TVEmoteSectionKindSet);
            NSString *title =
                ([setKey isEqualToString:roomSet] ? @"Channel Emotes" :
                 (S7TVString(value[@"name"]) ?: S7TVString(value[@"title"]) ?: @"Emote Set"));
            [sections addObject:[[S7TVEmoteSection alloc]
                initWithProvider:S7TVEmoteProviderIDFFZ kind:kind
                identifier:[NSString stringWithFormat:@"set:%@", setKey] title:title emotes:emotes
            loaded:YES loading:NO errorMessage:nil]];
        }
    }];
    if (globalEmotes.count) {
        [sections insertObject:[[S7TVEmoteSection alloc]
            initWithProvider:S7TVEmoteProviderIDFFZ kind:S7TVEmoteSectionKindGlobal
                  identifier:@"global" title:@"Global Emotes" emotes:globalEmotes
                    loaded:YES loading:NO errorMessage:nil] atIndex:0];
    }
    return sections.copy;
}

- (BOOL)isEmoteFavorited:(S7TVEmoteDescriptor *)emote {
    if (!emote.emoteID.length) return NO;
    NSArray *favorites = [self favoriteKeysSnapshot];
    return [favorites containsObject:
        S7TVEmoteFavoriteKey(emote.provider, emote.emoteID)];
}

- (void)setEmote:(S7TVEmoteDescriptor *)emote favorited:(BOOL)favorited {
    if (!emote.emoteID.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *favorites = [[self favoriteKeysSnapshot] mutableCopy] ?: [NSMutableArray array];
    NSString *key = S7TVEmoteFavoriteKey(emote.provider, emote.emoteID);
    [favorites removeObject:key];
    if (favorited) [favorites addObject:key];
    [defaults setObject:favorites.copy forKey:@"s7tv_favorites_v2"];
    NSMutableDictionary *favoriteMetadata =
        [[defaults dictionaryForKey:kS7TVFavoriteMetadataKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    if (favorited) {
        NSDictionary *metadata = S7TVFavoriteMetadataForDescriptor(emote);
        if (metadata) favoriteMetadata[key] = metadata;
    } else {
        [favoriteMetadata removeObjectForKey:key];
    }
    [defaults setObject:favoriteMetadata.copy forKey:kS7TVFavoriteMetadataKey];
    if (!favorited) {
        // Removing any member invalidates the saved Zero-Width composition;
        // otherwise another picker cell could keep inserting an incomplete
        // sequence after the user explicitly unfavorited one layer.
        NSMutableDictionary *compositions = S7TVMutableFavoriteCompositions();
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, key);
        S7TVStoreFavoriteCompositions(compositions);
    }
    // Keep the legacy 7TV-only API and its settings screen in sync while
    // provider-qualified favorites are being rolled out.  BTTV/FFZ never
    // touch the old array, so IDs from different providers cannot collide.
    if (emote.provider == S7TVEmoteProviderIDSevenTV) {
        NSMutableArray *legacy = [[defaults arrayForKey:@"s7tv_favorites"] mutableCopy]
            ?: [NSMutableArray array];
        [legacy removeObject:emote.emoteID];
        if (favorited) [legacy addObject:emote.emoteID];
        [defaults setObject:legacy.copy forKey:@"s7tv_favorites"];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"S7TVFavoritesDidChangeNotification" object:self];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVProviderCatalogDidUpdateNotification
                      object:self
                    userInfo:@{@"provider": @(emote.provider), @"favorites": @YES}];
}

- (void)setLegacySevenTVFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited {
    if (!emoteID.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *favorites = [[self favoriteKeysSnapshot] mutableCopy]
        ?: [NSMutableArray array];
    NSString *key = S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, emoteID);
    [favorites removeObject:key];
    if (favorited) [favorites addObject:key];
    [defaults setObject:favorites.copy forKey:@"s7tv_favorites_v2"];

    // The legacy manager only has the bare 7TV ID, but the descriptor is
    // usually already present when a user favorites an emote from the picker
    // or its chat preview. Persist its provider-aware metadata here as well;
    // otherwise the favorite would disappear from the rich Favorites view as
    // soon as the active channel changes or the app goes offline. If the
    // descriptor is not loaded yet, keep any metadata that may have arrived
    // from an earlier session and let favoriteDescriptorsSnapshot refresh it
    // on the next successful catalogue load.
    NSMutableDictionary *favoriteMetadata =
        [[defaults dictionaryForKey:kS7TVFavoriteMetadataKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    if (!favorited) {
        [favoriteMetadata removeObjectForKey:key];
    } else {
        S7TVEmoteDescriptor *loadedDescriptor = nil;
        for (S7TVEmoteDescriptor *descriptor in
             [self allEmotesForProvider:S7TVEmoteProviderIDSevenTV]) {
            if ([descriptor.emoteID isEqualToString:emoteID]) {
                loadedDescriptor = descriptor;
                break;
            }
        }
        NSDictionary *metadata = S7TVFavoriteMetadataForDescriptor(loadedDescriptor);
        if (metadata) favoriteMetadata[key] = metadata;
    }
    [defaults setObject:favoriteMetadata.copy forKey:kS7TVFavoriteMetadataKey];
    if (!favorited) {
        NSMutableDictionary *compositions = S7TVMutableFavoriteCompositions();
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, key);
        S7TVStoreFavoriteCompositions(compositions);
    }
}

- (void)setFavoriteKey:(NSString *)favoriteKey favorited:(BOOL)favorited {
    if (!favoriteKey.length) return;
    NSRange separator = [favoriteKey rangeOfString:@":" options:0 range:NSMakeRange(0, favoriteKey.length)];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location == favoriteKey.length - 1) return;

    NSString *providerKey = [[favoriteKey substringToIndex:separator.location] lowercaseString];
    S7TVEmoteProviderID provider;
    if ([providerKey isEqualToString:@"7tv"]) provider = S7TVEmoteProviderIDSevenTV;
    else if ([providerKey isEqualToString:@"bttv"]) provider = S7TVEmoteProviderIDBTTV;
    else if ([providerKey isEqualToString:@"ffz"]) provider = S7TVEmoteProviderIDFFZ;
    else return;
    NSString *normalizedKey = [NSString stringWithFormat:@"%@:%@",
        providerKey, [favoriteKey substringFromIndex:separator.location + 1]];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *favorites = [[self favoriteKeysSnapshot] mutableCopy]
        ?: [NSMutableArray array];
    [favorites removeObject:normalizedKey];
    [favorites removeObject:favoriteKey];
    if (favorited) [favorites addObject:normalizedKey];
    [defaults setObject:favorites.copy forKey:@"s7tv_favorites_v2"];

    // The legacy manager remains the source of truth for its in-memory 7TV
    // set.  Callers that operate on a descriptor use setEmote:, while this
    // key-level API is intentionally limited to provider-qualified storage
    // (the Settings screen uses it for BTTV/FFZ entries).
    if (provider == S7TVEmoteProviderIDSevenTV) {
        NSMutableArray *legacy = [[defaults arrayForKey:@"s7tv_favorites"] mutableCopy]
            ?: [NSMutableArray array];
        NSString *emoteID = [normalizedKey substringFromIndex:separator.location + 1];
        [legacy removeObject:emoteID];
        if (favorited) [legacy addObject:emoteID];
        [defaults setObject:legacy.copy forKey:@"s7tv_favorites"];
    }

    // Keep the offline descriptor sidecar bounded when a settings/import
    // caller removes a qualified favorite without having a live descriptor.
    // `setEmote:` already performs this cleanup for descriptor-based calls;
    // this key-level path must do the same for BTTV/FFZ and legacy 7TV rows.
    if (!favorited) {
        NSMutableDictionary *favoriteMetadata =
            [[defaults dictionaryForKey:kS7TVFavoriteMetadataKey] mutableCopy];
        if (favoriteMetadata[normalizedKey] || favoriteMetadata[favoriteKey]) {
            [favoriteMetadata removeObjectForKey:normalizedKey];
            [favoriteMetadata removeObjectForKey:favoriteKey];
            [defaults setObject:favoriteMetadata.copy forKey:kS7TVFavoriteMetadataKey];
        }
        NSMutableDictionary *compositions = S7TVMutableFavoriteCompositions();
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, normalizedKey);
        S7TVStoreFavoriteCompositions(compositions);
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"S7TVFavoritesDidChangeNotification" object:self];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVProviderCatalogDidUpdateNotification
                      object:self
                    userInfo:@{ @"provider": @(provider), @"favorites": @YES }];
}

- (void)replaceLegacySevenTVFavoriteIDs:(NSArray<NSString *> *)emoteIDs {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *favorites = [[self favoriteKeysSnapshot] mutableCopy]
        ?: [NSMutableArray array];
    NSMutableArray *withoutLegacy = [NSMutableArray arrayWithCapacity:favorites.count];
    for (id value in favorites) {
        if (![value isKindOfClass:NSString.class] ||
            ![(NSString *)value hasPrefix:@"7tv:"]) {
            [withoutLegacy addObject:value];
        }
    }
    NSMutableSet *seenIDs = [NSMutableSet set];
    for (id value in emoteIDs) {
        if (![value isKindOfClass:NSString.class] || ![(NSString *)value length]) continue;
        NSString *emoteID = (NSString *)value;
        if ([seenIDs containsObject:emoteID]) continue;
        [seenIDs addObject:emoteID];
        [withoutLegacy addObject:S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, emoteID)];
    }
    [defaults setObject:withoutLegacy.copy forKey:@"s7tv_favorites_v2"];

    // Keep the metadata sidecar in lockstep with the 7TV slice. BTTV/FFZ
    // favorites are intentionally preserved, while loaded 7TV descriptors
    // refresh names/URLs/Zero-Width flags during a bulk legacy migration.
    NSMutableDictionary *favoriteMetadata =
        [[defaults dictionaryForKey:kS7TVFavoriteMetadataKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    for (NSString *metadataKey in favoriteMetadata.allKeys.copy) {
        S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
        NSString *metadataID = nil;
        if (!S7TVParseFavoriteKey(metadataKey, &provider, &metadataID) ||
            provider == S7TVEmoteProviderIDSevenTV) {
            if (provider == S7TVEmoteProviderIDSevenTV &&
                ![seenIDs containsObject:metadataID]) {
                [favoriteMetadata removeObjectForKey:metadataKey];
            }
        }
    }
    for (S7TVEmoteDescriptor *descriptor in
         [self allEmotesForProvider:S7TVEmoteProviderIDSevenTV]) {
        if (![seenIDs containsObject:descriptor.emoteID]) continue;
        NSString *metadataKey = S7TVEmoteFavoriteKey(
            S7TVEmoteProviderIDSevenTV, descriptor.emoteID);
        NSDictionary *metadata = S7TVFavoriteMetadataForDescriptor(descriptor);
        if (metadata) favoriteMetadata[metadataKey] = metadata;
    }
    [defaults setObject:favoriteMetadata.copy forKey:kS7TVFavoriteMetadataKey];
}

- (NSArray<NSString *> *)favoriteKeysSnapshot {
    [self migrateLegacyFavoritesIfNeeded];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *raw = [defaults arrayForKey:@"s7tv_favorites_v2"] ?: @[];
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:raw.count];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:raw.count];
    for (id value in raw) {
        NSString *key = S7TVCanonicalFavoriteKey(value);
        if (!key.length || [seen containsObject:key]) continue;
        [seen addObject:key];
        [clean addObject:key];
    }
    // Persist the canonical form once.  Besides preventing crashes in the
    // Settings list, this makes uppercase provider prefixes and intermediate
    // bare-7TV IDs stable for future launches.
    if (![raw isEqualToArray:clean]) [defaults setObject:clean.copy forKey:@"s7tv_favorites_v2"];
    return clean.copy;
}

- (NSArray<S7TVEmoteDescriptor *> *)favoriteDescriptorsSnapshot {
    NSArray<NSString *> *favoriteKeys = [self favoriteKeysSnapshot];
    if (!favoriteKeys.count) return @[];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary<NSString *, NSDictionary *> *metadataByKey =
        [[defaults dictionaryForKey:kS7TVFavoriteMetadataKey] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, S7TVEmoteDescriptor *> *loadedByKey =
        [NSMutableDictionary dictionary];
    NSSet<NSString *> *favoriteSet = [NSSet setWithArray:favoriteKeys];

    // A current snapshot is always more trustworthy than persisted metadata
    // (the emote may have changed URL, animation or Zero-Width flags). Refresh
    // the metadata while walking all providers, then use it as an offline
    // fallback for favorites belonging to another channel.
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        for (S7TVEmoteDescriptor *descriptor in
             [self allEmotesForProvider:(S7TVEmoteProviderID)provider]) {
            NSString *key = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (!key.length || ![favoriteSet containsObject:key]) continue;
            loadedByKey[key] = descriptor;
            NSDictionary *metadata = S7TVFavoriteMetadataForDescriptor(descriptor);
            if (metadata) metadataByKey[key] = metadata;
        }
    }
    [defaults setObject:metadataByKey.copy forKey:kS7TVFavoriteMetadataKey];

    NSMutableArray<S7TVEmoteDescriptor *> *result =
        [NSMutableArray arrayWithCapacity:favoriteKeys.count];
    for (NSString *key in favoriteKeys) {
        S7TVEmoteDescriptor *descriptor = loadedByKey[key];
        if (!descriptor) {
            NSDictionary *metadata = [metadataByKey[key] isKindOfClass:NSDictionary.class]
                ? metadataByKey[key] : nil;
            descriptor = S7TVDescriptorFromFavoriteMetadata(key, metadata);
        }
        if (descriptor) [result addObject:descriptor];
    }
    return result.copy;
}

- (NSString *)favoriteCompositionTextForEmoteKey:(NSString *)emoteKey {
    NSString *canonicalKey = S7TVCanonicalFavoriteKey(emoteKey) ?: emoteKey;
    if (!canonicalKey.length) return nil;

    NSDictionary *compositions = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:kS7TVFavoriteCompositionsKey];
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

    // The overlay cell is also a valid entry point in the picker.  Resolve it
    // through the member list so tapping either layer reproduces the complete
    // `base overlay1 overlay2` sequence.
    for (id value in compositions.allValues) {
        if (!S7TVFavoriteCompositionContainsKey(value, canonicalKey)) continue;
        NSString *text = textFromValue(value);
        if (text.length) return text;
    }
    return nil;
}

- (void)setFavoriteCompositionText:(NSString *)text
                  forBaseEmoteKey:(NSString *)baseEmoteKey
                        memberKeys:(NSArray<NSString *> *)memberKeys {
    NSString *canonicalBaseKey = S7TVCanonicalFavoriteKey(baseEmoteKey) ?: baseEmoteKey;
    if (!canonicalBaseKey.length) return;

    NSMutableDictionary *compositions = S7TVMutableFavoriteCompositions();
    if (!text.length || memberKeys.count < 2) {
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, canonicalBaseKey);
        S7TVStoreFavoriteCompositions(compositions);
        return;
    }

    NSMutableArray<NSString *> *canonicalMembers = [NSMutableArray array];
    for (id rawKey in memberKeys) {
        NSString *key = S7TVCanonicalFavoriteKey(rawKey) ?: rawKey;
        if (![key isKindOfClass:NSString.class] || !key.length ||
            [canonicalMembers containsObject:key]) continue;
        [canonicalMembers addObject:key];
    }
    if (![canonicalMembers containsObject:canonicalBaseKey])
        [canonicalMembers insertObject:canonicalBaseKey atIndex:0];
    else if (![[canonicalMembers firstObject] isEqualToString:canonicalBaseKey]) {
        [canonicalMembers removeObject:canonicalBaseKey];
        [canonicalMembers insertObject:canonicalBaseKey atIndex:0];
    }
    if (canonicalMembers.count < 2) {
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, canonicalBaseKey);
        S7TVStoreFavoriteCompositions(compositions);
        return;
    }

    // A base can be favorited again with a different overlay sequence.  Clear
    // old compositions touching any member before writing the new canonical
    // record, so every picker cell points to one unambiguous sequence.
    for (NSString *memberKey in canonicalMembers)
        S7TVRemoveFavoriteCompositionsContainingKey(compositions, memberKey);
    compositions[canonicalBaseKey] = @{
        @"baseKey": canonicalBaseKey,
        @"keys": canonicalMembers.copy,
        @"text": [text copy],
    };
    // The individual favorite APIs already publish the visible picker update;
    // this sidecar only supplies the exact insertion text and must not trigger
    // a second reload for every layer of one composition.
    S7TVStoreFavoriteCompositions(compositions);
}

- (void)migrateLegacyFavoritesIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Do not use the mere presence of the v2 key as a migration marker.  A
    // previous build could have created an empty v2 array before the legacy
    // IDs were imported (or an old settings file could be imported later).
    // Merge both representations every time, preserving provider-qualified
    // BTTV/FFZ favorites and avoiding duplicates.
    NSArray *existing = [defaults arrayForKey:@"s7tv_favorites_v2"] ?: @[];
    NSArray *legacy = [defaults arrayForKey:@"s7tv_favorites"] ?: @[];
    NSMutableArray *migrated = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id value in existing) {
        NSString *canonical = S7TVCanonicalFavoriteKey(value);
        if (!canonical.length || [seen containsObject:canonical]) continue;
        [seen addObject:canonical];
        [migrated addObject:canonical];
    }
    for (id value in legacy) {
        NSString *legacyID = S7TVString(value);
        if (!legacyID.length) continue;
        NSString *canonical = S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, legacyID);
        if ([seen containsObject:canonical]) continue;
        [seen addObject:canonical];
        [migrated addObject:canonical];
    }
    if (![existing isEqualToArray:migrated])
        [defaults setObject:migrated.copy forKey:@"s7tv_favorites_v2"];
}

@end
