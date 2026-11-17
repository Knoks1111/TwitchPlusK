#import "Emote/tpK-emote-animation-engine.h"

static const NSInteger kTPKDefaultMaxSimultaneousAnimations = 128;

@interface TPKEmoteAnimationEngine ()
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTickTimestamp;

@property (nonatomic, strong) NSMutableDictionary<NSString *, TPKEmoteAnimatedFrames *> *framesByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *frameIndexByKey;   // Frame index.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *elapsedByKey;      // Elapsed time.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *firstSeenAtByKey;  // Throttle reference time.

// Visible observers by animation key; weak references prevent stale views.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSHashTable *> *observersByKey;
// Animation keys by observer; weak keys track observer lifetime.
@property (nonatomic, strong) NSMapTable<id, NSMutableSet<NSString *> *> *keysByObserver;
@property (nonatomic, strong) NSMapTable<id, dispatch_block_t> *redrawByObserver;
- (void)tpk_pruneInactiveFrameSetsPreservingKey:(NSString *)protectedKey;
- (void)tpk_pruneEmptyObserverKeys;
@end

@implementation TPKEmoteAnimationEngine

+ (instancetype)sharedEngine {
    static TPKEmoteAnimationEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [TPKEmoteAnimationEngine new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxSimultaneousAnimations = kTPKDefaultMaxSimultaneousAnimations;
        _framesByKey       = [NSMutableDictionary dictionary];
        _frameIndexByKey   = [NSMutableDictionary dictionary];
        _elapsedByKey      = [NSMutableDictionary dictionary];
        _firstSeenAtByKey  = [NSMutableDictionary dictionary];
        _observersByKey    = [NSMutableDictionary dictionary];
        _keysByObserver    = [NSMapTable weakToStrongObjectsMapTable];
        _redrawByObserver  = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

#pragma mark - Frames décodées

- (void)registerFrames:(TPKEmoteAnimatedFrames *)frames forKey:(NSString *)key {
    NSAssert([NSThread isMainThread], @"TPKEmoteAnimationEngine: main thread uniquement");
    if (!key.length || frames.images.count == 0) return;

    TPKEmoteAnimatedFrames *existingFrames = self.framesByKey[key];
    // Ignore a late preview if full frames are already registered.
    if (existingFrames && !existingFrames.isPreview && frames.isPreview) {
        return;
    }
    // Preserve registered state when cells request the same animation.
    if (existingFrames == frames) {
        return;
    }

    self.framesByKey[key]     = frames;
    self.frameIndexByKey[key] = @0;
    self.elapsedByKey[key]    = @0.0;
    // Protect newly registered frames from pruning before addObserver:.
    [self tpk_pruneInactiveFrameSetsPreservingKey:key];

    // Redraw now so the decoded frame appears without waiting for the next tick.
    [self tpk_notifyObserversOfKey:key];
}

- (BOOL)hasFramesForKey:(NSString *)key {
    BOOL hasFrames = key.length > 0 && self.framesByKey[key] != nil;
    return hasFrames;
}

- (nullable UIImage *)currentFrameForKey:(NSString *)key {
    if (!key.length) return nil;
    TPKEmoteAnimatedFrames *frames = self.framesByKey[key];
    if (!frames.images.count) return nil;
    NSUInteger idx = self.frameIndexByKey[key].unsignedIntegerValue;
    if (idx >= frames.images.count) idx = 0; // Safety fallback.
    return frames.images[idx];
}

#pragma mark - Observateurs

- (void)addObserver:(id)observer keys:(NSSet<NSString *> *)keys redraw:(void (^)(void))redraw {
    NSAssert([NSThread isMainThread], @"TPKEmoteAnimationEngine: main thread uniquement");
    if (!observer || keys.count == 0) return;

    // Detach reused cells even if callers skip removeObserver:.
    NSMutableSet<NSString *> *previousKeys = [self.keysByObserver objectForKey:observer];
    for (NSString *previousKey in previousKeys) {
        NSHashTable *previousObservers = self.observersByKey[previousKey];
        [previousObservers removeObject:observer];
        if (previousObservers.count == 0) {
            [self.observersByKey removeObjectForKey:previousKey];
            [self.firstSeenAtByKey removeObjectForKey:previousKey];
        }
    }

    [self.keysByObserver setObject:[keys mutableCopy] forKey:observer];
    [self.redrawByObserver setObject:redraw forKey:observer];

    CFTimeInterval now = CACurrentMediaTime();
    for (NSString *key in keys) {
        NSHashTable *observers = self.observersByKey[key];
        if (!observers) {
            observers = [NSHashTable weakObjectsHashTable];
            self.observersByKey[key] = observers;
        }
        BOOL wasEmpty = (observers.count == 0);
        [observers addObject:observer];
        if (wasEmpty) {
            // Record when this animation first becomes visible for throttling.
            self.firstSeenAtByKey[key] = @(now);
        }
    }

    [self tpk_updateDisplayLinkState];
}

- (void)removeObserver:(id)observer {
    NSAssert([NSThread isMainThread], @"TPKEmoteAnimationEngine: main thread uniquement");
    if (!observer) return;

    NSMutableSet<NSString *> *keys = [self.keysByObserver objectForKey:observer];
    for (NSString *key in keys) {
        NSHashTable *observers = self.observersByKey[key];
        [observers removeObject:observer];
        if (observers.count == 0) {
            [self.observersByKey removeObjectForKey:key];
            [self.firstSeenAtByKey removeObjectForKey:key];
            // Keep frames cached for quick reuse; the LRU bounds memory.
        }
    }
    [self.keysByObserver removeObjectForKey:observer];
    [self.redrawByObserver removeObjectForKey:observer];

    [self tpk_pruneInactiveFrameSetsPreservingKey:nil];
    [self tpk_updateDisplayLinkState];
}

- (BOOL)hasCompleteFramesForKey:(NSString *)key {
    TPKEmoteAnimatedFrames *frames = key.length > 0 ? self.framesByKey[key] : nil;
    BOOL complete = frames != nil && !frames.isPreview;
    return complete;
}

- (void)clearAllCachedFrames {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self clearAllCachedFrames]; });
        return;
    }
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.lastTickTimestamp = 0;
    [self.framesByKey removeAllObjects];
    [self.frameIndexByKey removeAllObjects];
    [self.elapsedByKey removeAllObjects];
    [self.firstSeenAtByKey removeAllObjects];
    [self.observersByKey removeAllObjects];
    [self.keysByObserver removeAllObjects];
    [self.redrawByObserver removeAllObjects];
}

- (void)tpk_pruneInactiveFrameSetsPreservingKey:(NSString *)protectedKey {
    // NSCache owns inactive frames; the engine retains only visible animations.
    for (NSString *key in self.framesByKey.allKeys) {
        if ([key isEqualToString:protectedKey] || self.observersByKey[key].count) continue;
        [self.framesByKey removeObjectForKey:key];
        [self.frameIndexByKey removeObjectForKey:key];
        [self.elapsedByKey removeObjectForKey:key];
    }
}

// Remove keys with no live observers before computing the animation limit.
- (void)tpk_pruneEmptyObserverKeys {
    for (NSString *key in [self.observersByKey.allKeys copy]) {
        if (self.observersByKey[key].count > 0) continue;
        [self.observersByKey removeObjectForKey:key];
        [self.firstSeenAtByKey removeObjectForKey:key];
    }
    [self tpk_pruneInactiveFrameSetsPreservingKey:nil];
}

- (void)tpk_notifyObserversOfKey:(NSString *)key {
    NSHashTable *observers = self.observersByKey[key];
    for (id observer in observers) {
        dispatch_block_t redraw = [self.redrawByObserver objectForKey:observer];
        if (redraw) redraw();
    }
}

#pragma mark - CADisplayLink lifecycle

- (void)tpk_updateDisplayLinkState {
    [self tpk_pruneEmptyObserverKeys];
    BOOL shouldRun = self.observersByKey.count > 0;
    if (shouldRun && !self.displayLink) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tpk_tick:)];
        // Keep visible animations smooth without requesting unnecessary 120 Hz updates.
        self.displayLink.preferredFramesPerSecond = 60;
        self.lastTickTimestamp = 0;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && self.displayLink) {
        // Stop the timer when no animated emotes are visible.
        [self.displayLink invalidate];
        self.displayLink = nil;
        self.lastTickTimestamp = 0;
    }
}

#pragma mark - Tick

- (void)tpk_tick:(CADisplayLink *)link {
    [self tpk_pruneEmptyObserverKeys];
    if (self.observersByKey.count == 0) {
        [self tpk_updateDisplayLinkState];
        return;
    }

    // Timestamp deltas reflect delivered callbacks, including missed frames.
    NSTimeInterval nominalStep = link.targetTimestamp > link.timestamp
        ? (link.targetTimestamp - link.timestamp) : (1.0 / 60.0);
    NSTimeInterval elapsedStep = self.lastTickTimestamp > 0
        ? (link.timestamp - self.lastTickTimestamp) : nominalStep;
    self.lastTickTimestamp = link.timestamp;
    if (elapsedStep <= 0) elapsedStep = nominalStep;
    // Cap catch-up time after backgrounding while absorbing brief delays.
    elapsedStep = MIN(elapsedStep, 0.25);

    // Freeze the oldest animations above the limit; throttling never unregisters them.
    NSArray<NSString *> *activeKeys = self.observersByKey.allKeys;
    NSSet<NSString *> *frozenSet = nil;
    NSInteger activeLimit = self.maxSimultaneousAnimations;
    if (activeKeys.count > activeLimit) {
        NSArray<NSString *> *sortedByAge = [activeKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
            CFTimeInterval ta = self.firstSeenAtByKey[a].doubleValue;
            CFTimeInterval tb = self.firstSeenAtByKey[b].doubleValue;
            if (ta < tb) return NSOrderedAscending;
            if (ta > tb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSInteger frozenCount = sortedByAge.count - activeLimit;
        frozenSet = [NSSet setWithArray:[sortedByAge subarrayWithRange:NSMakeRange(0, frozenCount)]];
    }

    NSHashTable *observersToRedraw = [NSHashTable weakObjectsHashTable];

    for (NSString *key in activeKeys) {
        if ([frozenSet containsObject:key]) continue;

        TPKEmoteAnimatedFrames *frames = self.framesByKey[key];
        if (!frames.images.count) continue; // Frames are still decoding.

        NSUInteger idx = self.frameIndexByKey[key].unsignedIntegerValue;
        NSTimeInterval elapsed = self.elapsedByKey[key].doubleValue + elapsedStep;
        NSTimeInterval frameDuration = [frames.durations[idx] doubleValue];
        if (frameDuration <= 0) frameDuration = 0.1;

        BOOL advanced = NO;
        // Catch up one frame at a time without a large visual jump.
        while (elapsed >= frameDuration && frames.images.count > 1) {
            elapsed -= frameDuration;
            idx = (idx + 1) % frames.images.count;
            frameDuration = [frames.durations[idx] doubleValue];
            if (frameDuration <= 0) frameDuration = 0.1;
            advanced = YES;
        }

        self.elapsedByKey[key] = @(elapsed);
        if (!advanced) continue;

        self.frameIndexByKey[key] = @(idx);
        NSHashTable *observers = self.observersByKey[key];
        for (id observer in observers) {
            [observersToRedraw addObject:observer];
        }
    }

    for (id observer in observersToRedraw) {
        dispatch_block_t redraw = [self.redrawByObserver objectForKey:observer];
        if (redraw) redraw();
    }
}

@end
