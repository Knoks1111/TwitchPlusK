/* GraphQL transforms derived from TwitchAdBlock (MIT). */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSData *TPKAdblockTransformRequestData(NSData * _Nullable data,
                                        NSURLRequest * _Nullable request);
NSData *TPKAdblockTransformResponseData(NSData * _Nullable data,
                                         NSURLRequest * _Nullable request);

NS_ASSUME_NONNULL_END
