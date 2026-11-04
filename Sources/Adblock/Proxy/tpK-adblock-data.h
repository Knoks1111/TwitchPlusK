#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL TPKAdblockFeedAdsFilteringEnabled(void);

id _Nullable TPKAdblockStripPreloadFeedAds(id _Nullable result, NSUInteger depth);

NSData *TPKAdblockTransformRequestData(NSData * _Nullable data,
                                        NSURLRequest * _Nullable request);
NSData *TPKAdblockTransformResponseData(NSData * _Nullable data,
                                         NSURLRequest * _Nullable request);

// RN accepte null pour les limites ; les chemins natifs attendent une valeur numérique.
NSData *TPKAdblockTransformResponseDataForTransport(NSData * _Nullable data,
                                                   NSURLRequest * _Nullable request,
                                                   NSString *transport);

NS_ASSUME_NONNULL_END
