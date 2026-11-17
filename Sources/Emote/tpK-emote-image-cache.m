#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-image-transport.h"
#import <ImageIO/ImageIO.h>

typedef void (^TPKImageCompletion)(UIImage *image);
typedef void (^TPKFramesCompletion)(TPKEmoteAnimatedFrames *frames);
typedef void (^TPKFramesPreview)(TPKEmoteAnimatedFrames *frames);
enum { ImageStage = 1, PreviewStage = 2, FramesStage = 4 };
static void *cacheQueueKey = &cacheQueueKey;

static NSUInteger tpk_imageMemoryCost(UIImage *image) {
    return image.CGImage ? CGImageGetBytesPerRow(image.CGImage) * CGImageGetHeight(image.CGImage) : 0;
}
static NSUInteger tpk_framesMemoryCost(TPKEmoteAnimatedFrames *frames) {
    NSUInteger cost = 0;
    for (UIImage *image in frames.images) cost += tpk_imageMemoryCost(image);
    return cost;
}

static NSTimeInterval tpk_animationFrameDuration(CGImageSourceRef source, size_t index) {
    NSTimeInterval duration = 0.1;
    NSDictionary *props = (__bridge_transfer NSDictionary *)
        CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    NSDictionary *webpProps = props[(__bridge NSString *)kCGImagePropertyWebPDictionary];
    NSNumber *delay = webpProps[(__bridge NSString *)kCGImagePropertyWebPUnclampedDelayTime]
                    ?: webpProps[(__bridge NSString *)kCGImagePropertyWebPDelayTime];
    if (!delay) {
        // ImageIO may expose WebP delays under GIF keys.
        NSDictionary *gifProps = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        delay = gifProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
              ?: gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
    }
    if (delay && delay.doubleValue > 0) duration = delay.doubleValue;
    return duration;
}

@implementation TPKEmoteAnimatedFrames
@end

@interface TPKEmoteFrameRequest ()
@property (atomic, getter=isCancelled) BOOL cancelled;
@property (atomic, copy) TPKFramesPreview preview;
@property (atomic, copy) TPKFramesCompletion completion;
@end

@implementation TPKEmoteFrameRequest
- (void)cancel {
    self.cancelled = YES;
    self.preview = nil;
    self.completion = nil;
}
@end

@interface TPKEmoteImageJob : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger running;
@property (nonatomic) NSUInteger ready;
@property (nonatomic) BOOL fetched;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) TPKEmoteAnimatedFrames *preview;
@property (nonatomic, strong) TPKEmoteAnimatedFrames *frames;
@property (nonatomic, strong) NSMutableArray<TPKImageCompletion> *images;
@property (nonatomic, strong) NSMutableArray<TPKEmoteFrameRequest *> *requests;
@end
@implementation TPKEmoteImageJob
@end

@interface TPKEmoteImageCache ()
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *decodedCache;
@property (nonatomic, strong) NSCache<NSString *, TPKEmoteAnimatedFrames *> *animatedFramesCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, TPKEmoteImageJob *> *jobs;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, strong) NSOperationQueue *staticDecodeQueue;
@property (nonatomic, strong) NSOperationQueue *animatedPreviewDecodeQueue;
@property (nonatomic, strong) NSOperationQueue *animatedDecodeQueue;
@property (atomic) NSUInteger cacheGeneration;
- (TPKEmoteImageJob *)tpk_jobForURL:(NSURL *)url;
- (BOOL)tpk_isCurrentJob:(TPKEmoteImageJob *)job;
- (BOOL)tpk_wantsStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job;
- (void)tpk_continueJob:(TPKEmoteImageJob *)job;
- (void)tpk_scheduleStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job;
- (void)tpk_deliverStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job;
- (nullable UIImage *)tpk_decodeFirstFrameData:(NSData *)data;
- (nullable TPKEmoteAnimatedFrames *)tpk_decodeAnimatedWebPData:(NSData *)data
    maximumFrameCount:(size_t)maximumFrameCount preserveLeadingFrames:(BOOL)preserveLeadingFrames
    shouldContinue:(BOOL (^)(void))shouldContinue;
@end

@implementation TPKEmoteImageCache
+ (instancetype)sharedCache {
    static TPKEmoteImageCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [self new]; });
    return cache;
}
- (instancetype)init {
    if ((self = [super init])) {
        _decodedCache = [NSCache new];
        _decodedCache.countLimit = 200;
        _decodedCache.totalCostLimit = 24 * 1024 * 1024;
        _animatedFramesCache = [NSCache new];
        _animatedFramesCache.countLimit = 48;
        _animatedFramesCache.totalCostLimit = 48 * 1024 * 1024;
        _jobs = [NSMutableDictionary dictionary];
        _syncQueue = dispatch_queue_create("tpk.emote-image-cache", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_syncQueue, cacheQueueKey, cacheQueueKey, NULL);
        _cacheGeneration = 1;
        _staticDecodeQueue = [NSOperationQueue new];
        _staticDecodeQueue.name = @"tpk.emote-static-decode";
        _staticDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _staticDecodeQueue.maxConcurrentOperationCount = 2;
        _animatedPreviewDecodeQueue = [NSOperationQueue new];
        _animatedPreviewDecodeQueue.name = @"tpk.emote-preview-decode";
        _animatedPreviewDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _animatedPreviewDecodeQueue.maxConcurrentOperationCount = 2;
        _animatedDecodeQueue = [NSOperationQueue new];
        _animatedDecodeQueue.name = @"tpk.emote-animation-decode";
        _animatedDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _animatedDecodeQueue.maxConcurrentOperationCount = 1;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(tpk_memoryWarning:)
            name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}
- (nullable UIImage *)cachedImageForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length ? [self.decodedCache objectForKey:key] : nil;
}
- (nullable TPKEmoteAnimatedFrames *)cachedFramesForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length ? [self.animatedFramesCache objectForKey:key] : nil;
}
- (void)imageForURL:(NSURL *)url completion:(TPKImageCompletion)completion {
    NSUInteger generation = self.cacheGeneration;
    UIImage *cached = [self cachedImageForURL:url];
    if (!url.absoluteString.length || cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(generation == self.cacheGeneration ? cached : nil); });
        return;
    }
    dispatch_async(self.syncQueue, ^{
        TPKEmoteImageJob *job = [self tpk_jobForURL:url];
        [job.images addObject:[completion copy]];
        [self tpk_continueJob:job];
    });
}
- (TPKEmoteFrameRequest *)framesForURL:(NSURL *)url animated:(BOOL)animated
    preview:(TPKFramesPreview)preview completion:(TPKFramesCompletion)completion {
    TPKEmoteFrameRequest *request = [TPKEmoteFrameRequest new];
    request.preview = preview;
    request.completion = completion;
    NSUInteger generation = self.cacheGeneration;
    TPKEmoteAnimatedFrames *cached = [self cachedFramesForURL:url];
    if (!animated || !url.absoluteString.length || cached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TPKFramesCompletion callback = request.completion;
            request.preview = nil; request.completion = nil;
            if (!request.isCancelled && callback) callback(generation == self.cacheGeneration ? cached : nil);
        });
        return request;
    }
    dispatch_async(self.syncQueue, ^{
        TPKEmoteImageJob *job = [self tpk_jobForURL:url];
        [job.requests addObject:request];
        [self tpk_continueJob:job];
    });
    return request;
}

// syncQueue owns job state and cache writes.
- (TPKEmoteImageJob *)tpk_jobForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    TPKEmoteImageJob *job = self.jobs[key];
    if (!job) {
        job = [TPKEmoteImageJob new];
        job.key = key; job.url = url; job.generation = self.cacheGeneration;
        job.images = [NSMutableArray array]; job.requests = [NSMutableArray array];
        job.frames = [self.animatedFramesCache objectForKey:key];
        job.image = [self.decodedCache objectForKey:key] ?: job.frames.images.firstObject;
        job.ready = (job.image ? ImageStage : 0) | (job.frames ? FramesStage : 0);
        self.jobs[key] = job;
    }
    return job;
}
- (BOOL)tpk_isCurrentJob:(TPKEmoteImageJob *)job {
    return self.jobs[job.key] == job && job.generation == self.cacheGeneration;
}
- (BOOL)tpk_wantsStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job {
    if (stage == ImageStage) return job.images.count > 0;
    for (TPKEmoteFrameRequest *request in job.requests)
        if (!request.isCancelled && (stage == FramesStage || request.preview)) return YES;
    return NO;
}
- (void)tpk_continueJob:(TPKEmoteImageJob *)job {
    if (![self tpk_isCurrentJob:job]) return;
    for (NSUInteger i = job.requests.count; i > 0; --i)
        if (job.requests[i - 1].isCancelled) [job.requests removeObjectAtIndex:i - 1];
    if (job.ready & ImageStage) [self tpk_deliverStage:ImageStage job:job];
    if (job.ready & FramesStage) [self tpk_deliverStage:FramesStage job:job];
    BOOL wantsFrames = [self tpk_wantsStage:FramesStage job:job];
    if (!job.images.count && !wantsFrames) {
        [job.task cancel]; [self.jobs removeObjectForKey:job.key];
        return;
    }
    if (!job.fetched) {
        if (job.task) return;
        NSURLRequest *request = [NSURLRequest requestWithURL:job.url
            cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
        job.task = [TPKEmoteImageSession() dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 200;
                NSData *body = !error && status >= 200 && status < 300 && data.length ? data : nil;
                dispatch_async(self.syncQueue, ^{
                    if (![self tpk_isCurrentJob:job]) return;
                    job.task = nil; job.fetched = YES; job.data = body;
                    [self tpk_continueJob:job];
                });
            }];
        [job.task resume];
        return;
    }
    if (!job.data.length) job.ready = ImageStage | PreviewStage | FramesStage;
    for (NSUInteger stage = ImageStage; stage <= FramesStage; stage <<= 1) {
        if (![self tpk_wantsStage:stage job:job]) continue;
        if (job.ready & stage) [self tpk_deliverStage:stage job:job];
        else if (!(job.running & stage) && !(stage == PreviewStage && (job.ready & FramesStage)))
            [self tpk_scheduleStage:stage job:job];
    }
    if (!job.images.count && !job.requests.count) [self.jobs removeObjectForKey:job.key];
}
- (void)tpk_scheduleStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job {
    job.running |= stage;
    NSData *data = job.data;
    NSOperationQueue *queue = stage == ImageStage ? self.staticDecodeQueue :
        stage == PreviewStage ? self.animatedPreviewDecodeQueue : self.animatedDecodeQueue;
    [queue addOperationWithBlock:^{
        @autoreleasepool {
            __block BOOL abandoned = NO;
            BOOL (^active)(void) = ^BOOL{
                __block BOOL wanted = NO;
                dispatch_sync(self.syncQueue, ^{
                    wanted = [self tpk_isCurrentJob:job] && !(job.ready & stage) &&
                        [self tpk_wantsStage:stage job:job];
                });
                if (!wanted) abandoned = YES;
                return wanted;
            };
            UIImage *image = nil;
            TPKEmoteAnimatedFrames *frames = nil;
            if (stage == ImageStage) {
                if (active()) image = [self tpk_decodeFirstFrameData:data];
            } else {
                frames = [self tpk_decodeAnimatedWebPData:data maximumFrameCount:stage == PreviewStage ? 24 : 240
                    preserveLeadingFrames:stage == PreviewStage shouldContinue:active];
            }
            dispatch_async(self.syncQueue, ^{
                if (![self tpk_isCurrentJob:job]) return;
                job.running &= ~stage;
                if (!abandoned && !(job.ready & stage)) {
                    job.ready |= stage;
                    if (stage == ImageStage) job.image = image;
                    else if (stage == PreviewStage) job.preview = frames.images.count > 1 ? frames : nil;
                    else job.frames = frames;
                    if (frames.images.count && stage == FramesStage) {
                        job.ready |= ImageStage | FramesStage;
                        job.frames = frames; job.image = job.image ?: frames.images.firstObject;
                        [self.animatedFramesCache setObject:frames forKey:job.key cost:tpk_framesMemoryCost(frames)];
                    }
                    if (job.image) [self.decodedCache setObject:job.image forKey:job.key cost:tpk_imageMemoryCost(job.image)];
                }
                [self tpk_continueJob:job];
            });
        }
    }];
}
- (void)tpk_deliverStage:(NSUInteger)stage job:(TPKEmoteImageJob *)job {
    if (stage == ImageStage ? !job.images.count : !job.requests.count) return;
    NSArray<TPKImageCompletion> *images = stage == ImageStage ? job.images.copy : @[];
    NSArray<TPKEmoteFrameRequest *> *requests = stage == ImageStage ? @[] : job.requests.copy;
    if (stage == ImageStage) [job.images removeAllObjects];
    if (stage == FramesStage) [job.requests removeAllObjects];
    UIImage *image = job.image;
    TPKEmoteAnimatedFrames *frames = stage == PreviewStage ? job.preview : job.frames;
    NSUInteger generation = job.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL current = generation == self.cacheGeneration;
        for (TPKImageCompletion callback in images) callback(current ? image : nil);
        for (TPKEmoteFrameRequest *request in requests) {
            if (stage == PreviewStage) {
                TPKFramesPreview callback = request.preview;
                request.preview = nil;
                if (current && frames && !request.isCancelled && callback) callback(frames);
            } else {
                TPKFramesCompletion callback = request.completion;
                request.preview = nil; request.completion = nil;
                if (!request.isCancelled && callback) callback(current ? frames : nil);
            }
        }
    });
}
- (void)tpk_memoryWarning:(NSNotification *)notification {
    [self.decodedCache removeAllObjects];
    [self.animatedFramesCache removeAllObjects];
}
- (void)clearAllCaches {
    dispatch_block_t clear = ^{
        [self.staticDecodeQueue cancelAllOperations];
        [self.animatedPreviewDecodeQueue cancelAllOperations];
        [self.animatedDecodeQueue cancelAllOperations];
        for (TPKEmoteImageJob *job in self.jobs.allValues) {
            [job.task cancel]; job.image = nil; job.frames = nil;
            [self tpk_deliverStage:ImageStage job:job];
            [self tpk_deliverStage:FramesStage job:job];
        }
        [self.jobs removeAllObjects];
        [self.decodedCache removeAllObjects];
        [self.animatedFramesCache removeAllObjects];
        ++self.cacheGeneration;
    };
    if (dispatch_get_specific(cacheQueueKey)) clear();
    else dispatch_sync(self.syncQueue, clear);
}

- (nullable TPKEmoteAnimatedFrames *)tpk_decodeAnimatedWebPData:(NSData *)data
                                                maximumFrameCount:(size_t)maximumFrameCount
                                            preserveLeadingFrames:(BOOL)preserveLeadingFrames
                                                   shouldContinue:(BOOL (^)(void))shouldContinue {
    if (!data.length) return nil;
    if (shouldContinue && !shouldContinue()) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t count = CGImageSourceGetCount(source);
    if (count == 0) {
        CFRelease(source);
        return nil;
    }

    // Decode at most 60 fps, capped at 240 frames to protect serial workers.
    maximumFrameCount = MAX((size_t)2, maximumFrameCount);
    // Consecutive leading frames keep previews smooth until full decoding finishes.
    size_t durationCount = preserveLeadingFrames ? MIN(count, maximumFrameCount) : count;
    NSMutableArray<NSNumber *> *sourceDurations =
        [NSMutableArray arrayWithCapacity:durationCount];
    NSTimeInterval totalDuration = 0.0;
    for (size_t i = 0; i < durationCount; i++) {
        if ((i % 8) == 0 && shouldContinue && !shouldContinue()) {
            CFRelease(source);
            return nil;
        }
        NSTimeInterval duration = tpk_animationFrameDuration(source, i);
        [sourceDurations addObject:@(duration)];
        totalDuration += duration;
    }

    size_t decodedCount;
    if (preserveLeadingFrames) {
        decodedCount = durationCount;
    } else {
        size_t displayableCount = (size_t)(totalDuration * 60.0 + 0.999);
        displayableCount = MAX((size_t)1, MIN(displayableCount, maximumFrameCount));
        decodedCount = MIN(count, displayableCount);
    }

    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:decodedCount];
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:decodedCount];
    NSDictionary *decodeOptions = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @256,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    };

    for (size_t sample = 0; sample < decodedCount; sample++) {
        @autoreleasepool {
            if (shouldContinue && !shouldContinue()) {
                CFRelease(source);
                return nil;
            }
            size_t sourceIndex = preserveLeadingFrames
                ? sample : (sample * count) / decodedCount;
            size_t nextSourceIndex = preserveLeadingFrames
                ? (sample + 1) : ((sample + 1) * count) / decodedCount;
            nextSourceIndex = MAX(nextSourceIndex, sourceIndex + 1);

            CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, sourceIndex,
                (__bridge CFDictionaryRef)decodeOptions);
            if (!cgImage) continue; // Skip a corrupt frame.
            [images addObject:[UIImage imageWithCGImage:cgImage]];
            CGImageRelease(cgImage);

            NSTimeInterval duration = 0.0;
            for (size_t i = sourceIndex; i < nextSourceIndex && i < sourceDurations.count; i++) {
                duration += sourceDurations[i].doubleValue;
            }
            if (duration <= 0) duration = 0.1;
            [durations addObject:@(duration)];
        }
    }
    CFRelease(source);

    if (images.count == 0) return nil;

    TPKEmoteAnimatedFrames *frames = [TPKEmoteAnimatedFrames new];
    frames.images    = images;
    frames.durations = durations;
    // Reuse the preview as complete when it includes every source frame.
    frames.preview = preserveLeadingFrames && decodedCount < count;
    return frames;
}

- (nullable UIImage *)tpk_decodeFirstFrameData:(NSData *)data {
    if (!data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @256,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
        (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

@end
