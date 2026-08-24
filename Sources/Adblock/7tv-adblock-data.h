/* GraphQL transforms derived from TwitchAdBlock (MIT). */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSData *S7TVAdblockTransformRequestData(NSData * _Nullable data,
                                        NSURLRequest * _Nullable request);
NSData *S7TVAdblockTransformResponseData(NSData * _Nullable data,
                                         NSURLRequest * _Nullable request);

NS_ASSUME_NONNULL_END
