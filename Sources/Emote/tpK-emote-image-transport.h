#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void TPKEmoteImageTransportSetup(void);
FOUNDATION_EXPORT NSURLSession *TPKEmoteImageSession(void);
FOUNDATION_EXPORT BOOL TPKEmoteImageProviderURL(NSURL *url);
FOUNDATION_EXPORT void TPKEmoteImageTransportClear(void);

FOUNDATION_EXPORT NSString *const TPKEmoteCacheCountDidChangeNotification;

@interface TPKURLProtocol : NSObject
+ (NSURLCache *)sharedEmoteCache;
+ (void)noteCachedEmoteImageURL:(NSURL *)url;
+ (NSInteger)cachedEmoteCount;
+ (void)refreshCachedEmoteCountWithCompletion:(void (^)(NSInteger count))completion;
+ (void)refreshCachedEmoteCountForImageURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSInteger count))completion;
+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger clearedCount))completion;
@end
