#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface TPKEmoteAnimatedFrames : NSObject
@property (nonatomic, copy) NSArray<UIImage *> *images;
@property (nonatomic, copy) NSArray<NSNumber *> *durations;
@property (nonatomic, getter=isPreview) BOOL preview;
@end

@interface TPKEmoteFrameRequest : NSObject
- (void)cancel;
@end

// Shared image requests; completions run on the main thread.
@interface TPKEmoteImageCache : NSObject
+ (instancetype)sharedCache;
- (nullable UIImage *)cachedImageForURL:(nullable NSURL *)url;
- (void)imageForURL:(nullable NSURL *)url completion:(void (^)(UIImage * _Nullable image))completion;
- (nullable TPKEmoteAnimatedFrames *)cachedFramesForURL:(nullable NSURL *)url;
- (TPKEmoteFrameRequest *)framesForURL:(nullable NSURL *)url animated:(BOOL)animated
    preview:(void (^ _Nullable)(TPKEmoteAnimatedFrames *frames))preview
    completion:(void (^)(TPKEmoteAnimatedFrames * _Nullable frames))completion;
- (void)clearAllCaches;
@end
NS_ASSUME_NONNULL_END
