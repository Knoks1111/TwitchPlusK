#import "Adblock/7tv-adblock-data.h"
#import "Adblock/7tv-adblock-settings.h"
#import "System/7tv-system-home-features.h"
#import <os/log.h>
#import <limits.h>

static NSSet<NSString *> *S7TVAdblockArrayTypenames(void) {
    static NSSet *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = [NSSet setWithObjects:@"FeedAd", @"OfferPromotion",
            @"PromotionDisplay", @"BitsProductPromotion", @"HostReadAd", nil];
    });
    return types;
}

static NSSet<NSString *> *S7TVAdblockFieldTypenames(void) {
    static NSSet *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // FeedAd must only be removed from arrays: Twitch also uses that
        // typename as metadata inside legitimate Stream/Clip objects.
        types = [NSSet setWithObjects:@"OfferPromotion", @"PromotionDisplay",
            @"BitsProductPromotion", nil];
    });
    return types;
}

static void S7TVAdblockProcessTree(id object, BOOL *dirty) {
    NSSet *arrayTypes = S7TVAdblockArrayTypenames();
    NSSet *fieldTypes = S7TVAdblockFieldTypenames();
    if ([object isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dictionary = object;
        NSMutableArray *keysToRemove = nil;
        for (NSString *key in dictionary.allKeys) {
            id value = dictionary[key];
            if ([value isKindOfClass:NSDictionary.class]) {
                NSString *type = value[@"__typename"];
                if ([type isKindOfClass:NSString.class] && [fieldTypes containsObject:type]) {
                    if (!keysToRemove) keysToRemove = [NSMutableArray array];
                    [keysToRemove addObject:key];
                    continue;
                }
            }
            S7TVAdblockProcessTree(value, dirty);
        }
        if (keysToRemove.count) {
            [dictionary removeObjectsForKeys:keysToRemove];
            *dirty = YES;
        }
        return;
    }
    if (![object isKindOfClass:NSMutableArray.class]) return;
    NSMutableArray *array = object;
    NSMutableIndexSet *indexes = nil;
    for (NSUInteger index = 0; index < array.count; index++) {
        id value = array[index];
        BOOL isAd = NO;
        if ([value isKindOfClass:NSDictionary.class]) {
            NSString *type = value[@"__typename"];
            if ([type isKindOfClass:NSString.class] && [arrayTypes containsObject:type]) {
                isAd = YES;
            } else {
                id node = value[@"node"];
                NSString *nodeType = [node isKindOfClass:NSDictionary.class]
                    ? node[@"__typename"] : nil;
                isAd = [nodeType isKindOfClass:NSString.class] &&
                       [arrayTypes containsObject:nodeType];
            }
        }
        if (isAd) {
            if (!indexes) indexes = [NSMutableIndexSet indexSet];
            [indexes addIndex:index];
        } else {
            S7TVAdblockProcessTree(value, dirty);
        }
    }
    if (indexes.count) {
        [array removeObjectsAtIndexes:indexes];
        *dirty = YES;
    }
}

// Le fil Twitch « Live » impose une durée maximale à chaque preview via
// watchBehavior.maxStreamWatchSeconds, puis affiche l'overlay Regarder/Suivre.
// TwitchAdBlock conserve la clé mais lui donne INT_MAX secondes : le code
// natif garde la structure attendue sans atteindre la limite en pratique.
static void S7TVNeutralizeLiveFeedWatchLimits(id object, BOOL *dirty) {
    if ([object isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dictionary = object;
        for (NSString *key in dictionary.allKeys) {
            id value = dictionary[key];
            if ([key isEqualToString:@"maxStreamWatchSeconds"] &&
                [value isKindOfClass:NSNumber.class]) {
                NSNumber *unlimited = @(INT_MAX);
                if (![value isEqual:unlimited]) {
                    dictionary[key] = unlimited;
                    *dirty = YES;
                    os_log(OS_LOG_DEFAULT,
                        "[S7TV-Home] Live-feed watch limit neutralized");
                }
                continue;
            }
            S7TVNeutralizeLiveFeedWatchLimits(value, dirty);
        }
    } else if ([object isKindOfClass:NSMutableArray.class]) {
        for (id value in (NSMutableArray *)object) {
            S7TVNeutralizeLiveFeedWatchLimits(value, dirty);
        }
    }
}

static void S7TVAdblockSpoofPlaybackPlatform(NSMutableDictionary *operation) {
    NSString *operationName = operation[@"operationName"];
    NSString *query = operation[@"query"];
    BOOL stream = [operationName isEqualToString:@"PlaybackAccessToken"] ||
                  [operationName isEqualToString:@"PlaybackAccessToken_Template"] ||
                  [operationName isEqualToString:@"StreamAccessToken"] ||
                  [query containsString:@"PlaybackAccessToken"] ||
                  [query containsString:@"StreamAccessToken"];
    BOOL vod = [operationName isEqualToString:@"VodAccessToken"];
    BOOL clip = [operationName isEqualToString:@"ClipAccessToken"];
    NSString *spoof = NSUUID.UUID.UUIDString;
    if (stream || vod) {
        NSMutableDictionary *variables = operation[@"variables"];
        if (![variables isKindOfClass:NSMutableDictionary.class]) return;
        if (variables[@"playerType"]) variables[@"playerType"] = spoof;
        NSMutableDictionary *params = variables[@"params"];
        if ([params isKindOfClass:NSMutableDictionary.class] && params[@"platform"])
            params[@"platform"] = spoof;
    } else if (clip) {
        NSMutableDictionary *variables = operation[@"variables"];
        NSMutableDictionary *params = [variables isKindOfClass:NSDictionary.class]
            ? variables[@"tokenParams"] : nil;
        if ([params isKindOfClass:NSMutableDictionary.class] && params[@"platform"])
            params[@"platform"] = spoof;
    }
}

static BOOL S7TVAdblockIsGQLRequest(NSURLRequest *request) {
    return [request.URL.host isEqualToString:@"gql.twitch.tv"] &&
           [request.URL.path isEqualToString:@"/gql"];
}

NSData *S7TVAdblockTransformRequestData(NSData *data, NSURLRequest *request) {
    // Spoof platform = moteur Proxy uniquement (VAFT normalise playerType
    // lui-même côté transport Local).
    if (!data.length || !S7TVAdblockIsEnabled() ||
        S7TVAdblockActiveMethodIsLocal() || !S7TVAdblockIsGQLRequest(request))
        return data;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers error:&error];
    if (!json || error) return data;
    if ([json isKindOfClass:NSMutableDictionary.class]) {
        S7TVAdblockSpoofPlaybackPlatform(json);
    } else if ([json isKindOfClass:NSMutableArray.class]) {
        for (id operation in json)
            if ([operation isKindOfClass:NSMutableDictionary.class])
                S7TVAdblockSpoofPlaybackPlatform(operation);
    } else return data;
    NSData *result = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return result && !error ? result : data;
}

NSData *S7TVAdblockTransformResponseData(NSData *data, NSURLRequest *request) {
    if (!data.length || !S7TVAdblockIsGQLRequest(request)) return data;
    // Le filtrage d'ads dans les réponses GQL est spécifique au moteur Proxy ;
    // keepLiveFeedPlaying est une fonctionnalité TwitchPlusK commune aux deux
    // modes (indépendante de la méthode).
    BOOL filterAds = S7TVAdblockIsEnabled() && !S7TVAdblockActiveMethodIsLocal();
    BOOL keepLiveFeedPlaying = s7tv_keepLiveFeedPlayingEnabled();
    if (!filterAds && !keepLiveFeedPlaying) return data;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers error:&error];
    if (!json || error) return data;
    BOOL dirty = NO;
    NSArray *operations = [json isKindOfClass:NSMutableArray.class] ? json : @[json];
    for (id operation in operations) {
        if (![operation isKindOfClass:NSMutableDictionary.class]) continue;
        id responseData = operation[@"data"];
        if (filterAds) S7TVAdblockProcessTree(responseData, &dirty);
        if (keepLiveFeedPlaying) {
            S7TVNeutralizeLiveFeedWatchLimits(responseData, &dirty);
        }
    }
    if (!dirty) return data;
    NSData *result = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (result && !error) {
        os_log(OS_LOG_DEFAULT, "[S7TV] GraphQL response filters applied");
        return result;
    }
    return data;
}
