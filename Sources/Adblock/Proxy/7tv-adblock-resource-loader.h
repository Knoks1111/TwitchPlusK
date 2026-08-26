/* AVFoundation resource loader derived from TwitchAdBlock (MIT). */

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface S7TVAdblockResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
+ (instancetype)sharedLoader;
- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest;
@end

NS_ASSUME_NONNULL_END
