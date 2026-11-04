#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/tpK-adblock-settings.h"
#import "System/tpK-system-home-features.h"
#import <os/log.h>
#import <limits.h>

BOOL TPKAdblockFeedAdsFilteringEnabled(void) {
    return TPKAdblockEnabledFast() &&
           TPKAdblockActiveMethod() != TPKAdblockMethodDisabled;
}

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

        // Conserver les métadonnées FeedAd des streams et clips.
        types = [NSSet setWithObjects:@"OfferPromotion", @"PromotionDisplay",
            @"BitsProductPromotion", nil];
    });
    return types;
}

static void TPKAdblockProcessTree(id object, NSSet *arrayTypes,
                                NSSet *fieldTypes, BOOL *dirty) {
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
            TPKAdblockProcessTree(value, arrayTypes, fieldTypes, dirty);
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
            TPKAdblockProcessTree(value, arrayTypes, fieldTypes, dirty);
        }
    }
    if (indexes.count) {
        [array removeObjectsAtIndexes:indexes];
        *dirty = YES;
    }
}

id TPKAdblockStripPreloadFeedAds(id result, NSUInteger depth) {
    if (!result || depth > 12) return result;
    if ([result isKindOfClass:NSString.class]) {
        NSString *text = result;
        if (![text containsString:@"FeedAd"]) return result;
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if (!json) {
            os_log(OS_LOG_DEFAULT, "[TPK-Strip] preload text has FeedAd but isn't JSON (%lu chars)", (unsigned long)text.length);
            return result;
        }
        id stripped = TPKAdblockStripPreloadFeedAds(json, depth + 1);
        NSData *out = [NSJSONSerialization dataWithJSONObject:stripped options:0 error:nil];
        NSString *outText = out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : nil;
        return outText ?: result;
    }
    if ([result isKindOfClass:NSDictionary.class] || [result isKindOfClass:NSArray.class]) {
        NSData *copy = [NSJSONSerialization isValidJSONObject:result]
            ? [NSJSONSerialization dataWithJSONObject:result options:0 error:nil] : nil;
        id tree = copy ? [NSJSONSerialization JSONObjectWithData:copy options:NSJSONReadingMutableContainers error:nil] : nil;
        if (!tree) return result;
        BOOL dirty = NO;
        // Ne retirer aucun champ de métadonnées du préchargement.
        TPKAdblockProcessTree(tree, TPKAdblockArrayTypenames(), [NSSet set], &dirty);
        if ([tree isKindOfClass:NSMutableDictionary.class]) {
            NSMutableDictionary *dict = tree;
            for (NSString *key in dict.allKeys) {
                if ([dict[key] isKindOfClass:NSString.class]) dict[key] = TPKAdblockStripPreloadFeedAds(dict[key], depth + 1);
            }
        }
        return tree;
    }
    return result;
}

static NSData *TPKRewriteLiveFeedWatchLimitBytes(NSData *data, NSURLRequest *request, NSString *via) {
  if (data.length < 20 || !tpk_keepLiveFeedPlayingEnabled()) return data;
  if ([data rangeOfData:[@"atchSeconds\"" dataUsingEncoding:NSUTF8StringEncoding]
                options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return data;
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!s) return data;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:
            @"(\"(?:maxStreamWatchSeconds|maxWatchSeconds)\"\\s*:\\s*)(\\d+)" options:0 error:nil];
  });
  NSArray<NSTextCheckingResult *> *matches = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
  if (!matches.count) return data;

  // RN accepte null ; Apollo attend une valeur numérique.
  NSString *replacement = [via isEqualToString:@"RCTHTTPRequestHandler"] ? @"null" : @"1000000";
  NSMutableArray *seen = [NSMutableArray array];
  NSMutableString *out = [s mutableCopy];
  BOOL changed = NO;

  // Remplacer de droite à gauche pour préserver les indices.
  for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
    [seen insertObject:[s substringWithRange:m.range] atIndex:0];
    NSRange num = [m rangeAtIndex:2];
    if (![[s substringWithRange:num] isEqualToString:replacement]) {
      [out replaceCharactersInRange:num withString:replacement];
      changed = YES;
    }
  }
  os_log(OS_LOG_DEFAULT, "[TPK-Home] watch limit in %{public}@%{public}@ via %{public}@: %{public}@ -> %{public}@",
         request.URL.host ?: @"?", request.URL.path ?: @"", via,
         [seen componentsJoinedByString:@", "], replacement);
  return changed ? [out dataUsingEncoding:NSUTF8StringEncoding] : data;
}

static void TPKNeutralizeLiveFeedWatchLimits(id obj, BOOL *dirty) {
    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d = obj;

        id wb = d[@"watchBehavior"];
        if ([wb isKindOfClass:NSMutableDictionary.class]) {
            id evolve = d[@"isEvolveFeed"];
            BOOL isFollowingFeed = [evolve isKindOfClass:NSNumber.class] && ![evolve boolValue];

            // Éviter le dépassement des minuteurs JavaScript après conversion en millisecondes.
            NSNumber *capped = @(1000000);
            for (NSString *key in @[@"maxStreamWatchSeconds", @"maxWatchSeconds"]) {
                id secs = ((NSMutableDictionary *)wb)[key];
                if (isFollowingFeed || ![secs isKindOfClass:NSNumber.class]) continue;
                if ([secs isEqual:capped]) continue;
                ((NSMutableDictionary *)wb)[key] = capped;
                *dirty = YES;
                os_log(OS_LOG_DEFAULT,
                    "[TPK-Home] neutralized %{public}@ (was %{public}@)", key, secs);
            }
        }
        for (NSString *key in d) TPKNeutralizeLiveFeedWatchLimits(d[key], dirty);
    } else if ([obj isKindOfClass:NSMutableArray.class]) {
        for (id val in (NSMutableArray *)obj) TPKNeutralizeLiveFeedWatchLimits(val, dirty);
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

// VAFT normalise ses propres jetons ; ce traitement reste réservé au Proxy.
NSData *TPKAdblockTransformRequestData(NSData *data, NSURLRequest *request) {

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

NSData *TPKAdblockTransformResponseDataForTransport(NSData *data, NSURLRequest *request,
                                                   NSString *transport) {
    if (!data.length || !TPKAdblockIsGQLRequest(request)) return data;
    data = TPKRewriteLiveFeedWatchLimitBytes(data, request, transport);

    BOOL filterAds = TPKAdblockFeedAdsFilteringEnabled();
    BOOL keepLiveFeedPlaying = tpk_keepLiveFeedPlayingEnabled();
    if (!filterAds && !keepLiveFeedPlaying) return data;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers error:&error];
    if (!json || error) return data;
    BOOL dirty = NO;
    NSArray *operations = [json isKindOfClass:NSMutableArray.class] ? json : @[json];
    for (NSUInteger index = 0; index < operations.count; index++) {
        id operation = operations[index];
        if (![operation isKindOfClass:NSMutableDictionary.class]) continue;
        id responseData = operation[@"data"];
        if (filterAds) TPKAdblockProcessTree(responseData,
            TPKAdblockArrayTypenames(), TPKAdblockFieldTypenames(), &dirty);
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

NSData *TPKAdblockTransformResponseData(NSData *data, NSURLRequest *request) {
    return TPKAdblockTransformResponseDataForTransport(data, request, @"completionHandler");
}
