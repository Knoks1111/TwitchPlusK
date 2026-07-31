/*
 * SevenTVEmoteAnimationEngine.m
 *
 * Voir SevenTVEmoteAnimationEngine.h pour le contexte complet (Phase 2 —
 * animation des emotes).
 */

#import "SevenTVEmoteAnimationEngine.h"
#import "SevenTVManager.h"

static const NSInteger kS7TVDefaultMaxSimultaneousAnimations = 24;


// ============================================================
// MARK: - S7TVAnimatedEmoteAttachment
// ============================================================

@implementation S7TVAnimatedEmoteAttachment

- (nullable UIImage *)imageForBounds:(CGRect)imageBounds
                        textContainer:(nullable NSTextContainer *)textContainer
                       characterIndex:(NSUInteger)charIndex {
    // Simple lookup, aucun I/O ici — sûr à appeler depuis le pipeline de
    // dessin TextKit à chaque frame.
    UIImage *frame = [[SevenTVEmoteAnimationEngine sharedEngine] currentFrameForKey:self.animationKey];
    return frame ?: self.staticFallbackImage;
}

@end


// ============================================================
// MARK: - SevenTVEmoteAnimationEngine
// ============================================================

@interface SevenTVEmoteAnimationEngine ()
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;

@property (nonatomic, strong) NSMutableDictionary<NSString *, S7TVEmoteAnimatedFrames *> *framesByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *frameIndexByKey;   // NSUInteger
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *elapsedByKey;      // CFTimeInterval accumulé
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *firstSeenAtByKey;  // CFTimeInterval, référence throttle

// Clé → observateurs actuellement affichés (weak — un observateur qui
// disparaît sans appeler removeObserver: ne fuit pas indéfiniment).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSHashTable *> *observersByKey;
// Observateur → ses clés actuelles (weak key : suit le cycle de vie réel de
// l'observateur, filet de sécurité en plus de removeObserver: explicite).
@property (nonatomic, strong) NSMapTable<id, NSMutableSet<NSString *> *> *keysByObserver;
@property (nonatomic, strong) NSMapTable<id, dispatch_block_t> *redrawByObserver;
@end

@implementation SevenTVEmoteAnimationEngine

+ (instancetype)sharedEngine {
    static SevenTVEmoteAnimationEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [SevenTVEmoteAnimationEngine new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxSimultaneousAnimations = kS7TVDefaultMaxSimultaneousAnimations;
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

- (void)registerFrames:(S7TVEmoteAnimatedFrames *)frames forKey:(NSString *)key {
    NSAssert([NSThread isMainThread], @"SevenTVEmoteAnimationEngine: main thread uniquement");
    if (!key.length || frames.images.count == 0) return;

    self.framesByKey[key]     = frames;
    self.frameIndexByKey[key] = @0;
    self.elapsedByKey[key]    = @0.0;

    // Redraw immédiat : sans ça, une clé qui vient tout juste d'être décodée
    // n'affiche sa vraie frame 0 qu'au PROCHAIN avancement de frame (jusqu'à
    // frameDuration plus tard) au lieu d'immédiatement — voir s7tv_tick:.
    [self s7tv_notifyObserversOfKey:key];
}

- (BOOL)hasFramesForKey:(NSString *)key {
    return key.length > 0 && self.framesByKey[key] != nil;
}

- (nullable UIImage *)currentFrameForKey:(NSString *)key {
    if (!key.length) return nil;
    S7TVEmoteAnimatedFrames *frames = self.framesByKey[key];
    if (!frames.images.count) return nil;
    NSUInteger idx = self.frameIndexByKey[key].unsignedIntegerValue;
    if (idx >= frames.images.count) idx = 0; // filet de sécurité, ne devrait pas arriver
    return frames.images[idx];
}

#pragma mark - Observateurs

- (void)addObserver:(id)observer keys:(NSSet<NSString *> *)keys redraw:(void (^)(void))redraw {
    NSAssert([NSThread isMainThread], @"SevenTVEmoteAnimationEngine: main thread uniquement");
    if (!observer || keys.count == 0) return;

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
            // Transition 0 → 1 observateur : cette clé "apparaît" à l'écran
            // maintenant — référence pour le throttle (voir s7tv_tick:, les
            // clés au firstSeenAt le plus ancien gèlent en premier).
            self.firstSeenAtByKey[key] = @(now);
        }
    }

    [self s7tv_updateDisplayLinkState];
}

- (void)removeObserver:(id)observer {
    NSAssert([NSThread isMainThread], @"SevenTVEmoteAnimationEngine: main thread uniquement");
    if (!observer) return;

    NSMutableSet<NSString *> *keys = [self.keysByObserver objectForKey:observer];
    for (NSString *key in keys) {
        NSHashTable *observers = self.observersByKey[key];
        [observers removeObject:observer];
        if (observers.count == 0) {
            [self.observersByKey removeObjectForKey:key];
            [self.firstSeenAtByKey removeObjectForKey:key];
            // framesByKey/frameIndexByKey/elapsedByKey restent en cache
            // volontairement — redécoder à chaque scroll coûterait bien plus
            // cher qu'un peu de mémoire ; l'éviction se fait côté
            // SevenTVEmoteImageCache (NSCache bornée), pas ici.
        }
    }
    [self.keysByObserver removeObjectForKey:observer];
    [self.redrawByObserver removeObjectForKey:observer];

    [self s7tv_updateDisplayLinkState];
}

- (void)s7tv_notifyObserversOfKey:(NSString *)key {
    NSHashTable *observers = self.observersByKey[key];
    for (id observer in observers) {
        dispatch_block_t redraw = [self.redrawByObserver objectForKey:observer];
        if (redraw) redraw();
    }
}

#pragma mark - CADisplayLink lifecycle

- (void)s7tv_updateDisplayLinkState {
    BOOL shouldRun = self.observersByKey.count > 0;
    if (shouldRun && !self.displayLink) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(s7tv_tick:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && self.displayLink) {
        // Plus aucune emote animée observée à l'écran → coupe le timer
        // plutôt que de le laisser tourner pour rien (chat custom désactivé,
        // ou aucune emote animée dans les messages visibles actuellement).
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

#pragma mark - Tick

- (void)s7tv_tick:(CADisplayLink *)link {
    if (self.observersByKey.count == 0) return;

    // Throttle : au-delà de maxSimultaneousAnimations clés actives, les plus
    // anciennes (firstSeenAt le plus petit) gèlent — jamais retirées, juste
    // pas avancées ce tick (voir header). Aucune clé n'est jamais désinscrite
    // par le throttle lui-même.
    NSArray<NSString *> *activeKeys = self.observersByKey.allKeys;
    NSSet<NSString *> *frozenSet = nil;
    if (activeKeys.count > self.maxSimultaneousAnimations) {
        NSArray<NSString *> *sortedByAge = [activeKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
            CFTimeInterval ta = self.firstSeenAtByKey[a].doubleValue;
            CFTimeInterval tb = self.firstSeenAtByKey[b].doubleValue;
            if (ta < tb) return NSOrderedAscending;
            if (ta > tb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSInteger frozenCount = sortedByAge.count - self.maxSimultaneousAnimations;
        frozenSet = [NSSet setWithArray:[sortedByAge subarrayWithRange:NSMakeRange(0, frozenCount)]];
    }

    NSHashTable *observersToRedraw = [NSHashTable weakObjectsHashTable];

    for (NSString *key in activeKeys) {
        if ([frozenSet containsObject:key]) continue;

        S7TVEmoteAnimatedFrames *frames = self.framesByKey[key];
        if (!frames.images.count) continue; // décodage pas encore terminé pour cette clé

        NSUInteger idx = self.frameIndexByKey[key].unsignedIntegerValue;
        NSTimeInterval elapsed = self.elapsedByKey[key].doubleValue + link.duration;
        NSTimeInterval frameDuration = [frames.durations[idx] doubleValue];
        if (frameDuration <= 0) frameDuration = 0.1;

        BOOL advanced = NO;
        // while plutôt que if : rattrape un retard important (ex: app
        // revenue au premier plan après un long moment en arrière-plan) une
        // frame à la fois, sans bond visuel brutal ni boucle infinie
        // (frameDuration replanché à chaque itération).
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
