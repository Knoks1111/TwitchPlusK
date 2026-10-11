#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/tpK-adblock-settings.h"
#import "System/tpK-system-home-features.h"
#import <os/log.h>
#import <limits.h>

static NSSet<NSString *> *TPKAdblockArrayTypenames(void) {
    static NSSet *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = [NSSet setWithObjects:@"FeedAd", @"OfferPromotion",
            @"PromotionDisplay", @"BitsProductPromotion", @"HostReadAd", nil];
    });
    return types;
}

static NSSet<NSString *> *TPKAdblockFieldTypenames(void) {
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

static void TPKAdblockProcessTree(id object, BOOL *dirty) {
    NSSet *arrayTypes = TPKAdblockArrayTypenames();
    NSSet *fieldTypes = TPKAdblockFieldTypenames();
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
            TPKAdblockProcessTree(value, dirty);
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
            TPKAdblockProcessTree(value, dirty);
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
static void TPKNeutralizeLiveFeedWatchLimits(id object, BOOL *dirty) {
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
                        "[TPK-Home] Live-feed watch limit neutralized");
                }
                continue;
            }
            TPKNeutralizeLiveFeedWatchLimits(value, dirty);
        }
    } else if ([object isKindOfClass:NSMutableArray.class]) {
        for (id value in (NSMutableArray *)object) {
            TPKNeutralizeLiveFeedWatchLimits(value, dirty);
        }
    }
}

static void TPKAdblockSpoofPlaybackPlatform(NSMutableDictionary *operation) {
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

static BOOL TPKAdblockIsGQLRequest(NSURLRequest *request) {
    return [request.URL.host isEqualToString:@"gql.twitch.tv"] &&
           [request.URL.path isEqualToString:@"/gql"];
}

NSData *TPKAdblockTransformRequestData(NSData *data, NSURLRequest *request) {
    // Spoof platform = moteur Proxy uniquement (VAFT normalise playerType
    // lui-même côté transport Local).
    if (!data.length || !TPKAdblockIsEnabled() ||
        TPKAdblockActiveMethod() != TPKAdblockMethodProxy || !TPKAdblockIsGQLRequest(request))
        return data;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers error:&error];
    if (!json || error) return data;
    if ([json isKindOfClass:NSMutableDictionary.class]) {
        TPKAdblockSpoofPlaybackPlatform(json);
    } else if ([json isKindOfClass:NSMutableArray.class]) {
        for (id operation in json)
            if ([operation isKindOfClass:NSMutableDictionary.class])
                TPKAdblockSpoofPlaybackPlatform(operation);
    } else return data;
    NSData *result = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return result && !error ? result : data;
}

NSData *TPKAdblockTransformResponseData(NSData *data, NSURLRequest *request) {
    if (!data.length || !TPKAdblockIsGQLRequest(request)) return data;
    // Le filtrage d'ads dans les réponses GQL est spécifique au moteur Proxy ;
    // keepLiveFeedPlaying est une fonctionnalité TwitchPlusK commune aux deux
    // modes (indépendante de la méthode).
    BOOL filterAds = TPKAdblockIsEnabled() && TPKAdblockActiveMethod() == TPKAdblockMethodProxy;
    BOOL keepLiveFeedPlaying = tpk_keepLiveFeedPlayingEnabled();
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
        if (filterAds) TPKAdblockProcessTree(responseData, &dirty);
        if (keepLiveFeedPlaying) {
            TPKNeutralizeLiveFeedWatchLimits(responseData, &dirty);
        }
    }
    if (!dirty) return data;
    NSData *result = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (result && !error) {
        os_log(OS_LOG_DEFAULT, "[TPK] GraphQL response filters applied");
        return result;
    }
    return data;
}
