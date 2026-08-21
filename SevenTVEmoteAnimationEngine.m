/*
 * SevenTVEmoteAnimationEngine.m
 *
 * Voir SevenTVEmoteAnimationEngine.h pour le contexte complet (Phase 2 —
 * animation des emotes).
 */

#import "SevenTVEmoteAnimationEngine.h"
#import "SevenTVManager.h"
#import <float.h>

// Le picker peut afficher plus de 24 emotes animées distinctes en même temps,
// auxquelles s'ajoutent celles du chat encore visible derrière lui. La limite
// précédente gelait donc certaines cellules pourtant durablement à l'écran.
// Les observateurs sont strictement liés aux cellules réellement visibles et
// retirés dans didEndDisplayingCell. On peut donc couvrir tout le picker + le
// chat derrière sans geler arbitrairement une cellule encore à l'écran.
static const NSInteger kS7TVDefaultMaxSimultaneousAnimations = 128;
static const NSUInteger kS7TVMaxRegisteredFrameSets = 32;
static const NSUInteger kS7TVMaxRegisteredFramesCost = 48 * 1024 * 1024;

static NSUInteger s7tv_engineFramesCost(S7TVEmoteAnimatedFrames *frames) {
    NSUInteger total = 0;
    for (UIImage *image in frames.images) {
        CGImageRef cgImage = image.CGImage;
        if (cgImage) total += CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage);
    }
    return total;
}


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
@property (nonatomic, assign) CFTimeInterval lastTickTimestamp;

@property (nonatomic, strong) NSMutableDictionary<NSString *, S7TVEmoteAnimatedFrames *> *framesByKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *frameIndexByKey;   // NSUInteger
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *elapsedByKey;      // CFTimeInterval accumulé
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *firstSeenAtByKey;  // CFTimeInterval, référence throttle
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastAccessByKey;   // LRU des frames inactives
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *frameCostByKey;    // octets décodés estimés

// Clé → observateurs actuellement affichés (weak — un observateur qui
// disparaît sans appeler removeObserver: ne fuit pas indéfiniment).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSHashTable *> *observersByKey;
// Observateur → ses clés actuelles (weak key : suit le cycle de vie réel de
// l'observateur, filet de sécurité en plus de removeObserver: explicite).
@property (nonatomic, strong) NSMapTable<id, NSMutableSet<NSString *> *> *keysByObserver;
@property (nonatomic, strong) NSMapTable<id, dispatch_block_t> *redrawByObserver;
- (void)s7tv_pruneInactiveFrameSetsPreservingKey:(NSString *)protectedKey;
- (void)s7tv_pruneEmptyObserverKeys;
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
        _lastAccessByKey   = [NSMutableDictionary dictionary];
        _frameCostByKey    = [NSMutableDictionary dictionary];
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

    S7TVEmoteAnimatedFrames *existingFrames = self.framesByKey[key];
    // Une preview peut arriver après la boucle complète (files de décodage
    // distinctes). Ne jamais dégrader alors l'animation déjà enregistrée.
    if (existingFrames && !existingFrames.isPreview && frames.isPreview) {
        self.lastAccessByKey[key] = @(CACurrentMediaTime());
        return;
    }
    // Ne pas réinitialiser une animation déjà enregistrée quand plusieurs
    // cellules demandent exactement le même résultat au même moment.
    if (existingFrames == frames) {
        self.lastAccessByKey[key] = @(CACurrentMediaTime());
        return;
    }

    self.framesByKey[key]     = frames;
    self.frameIndexByKey[key] = @0;
    self.elapsedByKey[key]    = @0.0;
    self.lastAccessByKey[key] = @(CACurrentMediaTime());
    self.frameCostByKey[key]  = @(s7tv_engineFramesCost(frames));
    // registerFrames: précède nécessairement addObserver:. Protéger cette clé
    // pendant le prune empêche qu'elle soit considérée comme inactive puis
    // évincée immédiatement lorsque le chat + le picker dépassent déjà la
    // limite du cache interne.
    [self s7tv_pruneInactiveFrameSetsPreservingKey:key];

    // Redraw immédiat : sans ça, une clé qui vient tout juste d'être décodée
    // n'affiche sa vraie frame 0 qu'au PROCHAIN avancement de frame (jusqu'à
    // frameDuration plus tard) au lieu d'immédiatement — voir s7tv_tick:.
    [self s7tv_notifyObserversOfKey:key];
}

- (BOOL)hasFramesForKey:(NSString *)key {
    BOOL hasFrames = key.length > 0 && self.framesByKey[key] != nil;
    if (hasFrames) self.lastAccessByKey[key] = @(CACurrentMediaTime());
    return hasFrames;
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

    // Rend l'API sûre même si un appelant réutilise une cellule sans faire le
    // removeObserver: recommandé juste avant. Sans ce détachement, l'ancien
    // key → observer restait vivant et pouvait consommer une place du throttle
    // alors que l'emote n'était plus affichée.
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
        self.lastAccessByKey[key] = @(now);
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
            // Les frames restent disponibles pour un retour rapide à l'écran,
            // mais le LRU borné ci-dessous évite leur accumulation illimitée.
        }
    }
    [self.keysByObserver removeObjectForKey:observer];
    [self.redrawByObserver removeObjectForKey:observer];

    [self s7tv_pruneInactiveFrameSetsPreservingKey:nil];
    [self s7tv_updateDisplayLinkState];
}

- (BOOL)hasCompleteFramesForKey:(NSString *)key {
    S7TVEmoteAnimatedFrames *frames = key.length > 0 ? self.framesByKey[key] : nil;
    BOOL complete = frames != nil && !frames.isPreview;
    if (complete) self.lastAccessByKey[key] = @(CACurrentMediaTime());
    return complete;
}

- (void)setScrollingPerformanceMode:(BOOL)enabled {
    NSAssert([NSThread isMainThread], @"SevenTVEmoteAnimationEngine: main thread uniquement");
    // Conservé comme point d'entrée du picker. La visibilité stricte des
    // cellules remplace désormais le throttle artificiel pendant le scroll.
    (void)enabled;
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
    [self.lastAccessByKey removeAllObjects];
    [self.frameCostByKey removeAllObjects];
    [self.observersByKey removeAllObjects];
    [self.keysByObserver removeAllObjects];
    [self.redrawByObserver removeAllObjects];
}

// Le NSCache d'images est borné, mais framesByKey retenait auparavant une
// seconde référence forte vers chaque animation jamais rencontrée. Après un
// long scroll, cette table devenait donc un cache illimité. On garde un petit
// LRU borné à la fois en nombre et à ~48 Mo, sans jamais évincer une clé
// actuellement visible.
- (void)s7tv_pruneInactiveFrameSetsPreservingKey:(NSString *)protectedKey {
    NSUInteger totalCost = 0;
    for (NSNumber *cost in self.frameCostByKey.allValues) totalCost += cost.unsignedIntegerValue;
    while (self.framesByKey.count > kS7TVMaxRegisteredFrameSets ||
           totalCost > kS7TVMaxRegisteredFramesCost) {
        NSString *oldestKey = nil;
        CFTimeInterval oldestAccess = DBL_MAX;
        for (NSString *candidate in self.framesByKey) {
            if ([candidate isEqualToString:protectedKey]) continue;
            if (self.observersByKey[candidate].count > 0) continue;
            CFTimeInterval access = self.lastAccessByKey[candidate].doubleValue;
            if (!oldestKey || access < oldestAccess) {
                oldestKey = candidate;
                oldestAccess = access;
            }
        }
        if (!oldestKey) break; // toutes les clés sont réellement visibles
        totalCost -= MIN(totalCost, self.frameCostByKey[oldestKey].unsignedIntegerValue);
        [self.framesByKey removeObjectForKey:oldestKey];
        [self.frameIndexByKey removeObjectForKey:oldestKey];
        [self.elapsedByKey removeObjectForKey:oldestKey];
        [self.lastAccessByKey removeObjectForKey:oldestKey];
        [self.frameCostByKey removeObjectForKey:oldestKey];
    }
}

// Les NSHashTable d'observateurs sont faibles. Si UIKit détruit une vue sans
// envoyer didEndDisplayingCell (fermeture/transitions rapides), la table peut
// devenir vide toute seule mais sa clé reste dans observersByKey. On purge ces
// clés avant chaque calcul de limite afin qu'une animation hors écran ne puisse
// jamais voler l'une des places réservées aux emotes réellement visibles.
- (void)s7tv_pruneEmptyObserverKeys {
    for (NSString *key in [self.observersByKey.allKeys copy]) {
        if (self.observersByKey[key].count > 0) continue;
        [self.observersByKey removeObjectForKey:key];
        [self.firstSeenAtByKey removeObjectForKey:key];
    }
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
    [self s7tv_pruneEmptyObserverKeys];
    BOOL shouldRun = self.observersByKey.count > 0;
    if (shouldRun && !self.displayLink) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(s7tv_tick:)];
        // Conserver les emotes 50/60 fps réellement fluides, tout en évitant
        // les passages inutiles à 120 Hz sur les écrans ProMotion. Le moteur
        // ne tourne déjà que pour les emotes dont une cellule est visible.
        self.displayLink.preferredFramesPerSecond = 60;
        self.lastTickTimestamp = 0;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && self.displayLink) {
        // Plus aucune emote animée observée à l'écran → coupe le timer
        // plutôt que de le laisser tourner pour rien (chat custom désactivé,
        // ou aucune emote animée dans les messages visibles actuellement).
        [self.displayLink invalidate];
        self.displayLink = nil;
        self.lastTickTimestamp = 0;
    }
}

#pragma mark - Tick

- (void)s7tv_tick:(CADisplayLink *)link {
    [self s7tv_pruneEmptyObserverKeys];
    if (self.observersByKey.count == 0) {
        [self s7tv_updateDisplayLinkState];
        return;
    }

    // link.duration correspond à la cadence physique de l'écran. Sur un
    // écran ProMotion 120 Hz avec un displayLink demandé à 60 Hz, elle peut
    // donc valoir 1/120 alors que ce callback n'arrive que toutes les 1/60 s :
    // les animations avançaient à demi-vitesse et semblaient saccader. La
    // différence entre deux timestamps mesure la cadence réellement livrée,
    // y compris lorsqu'une frame est ponctuellement manquée par le main thread.
    NSTimeInterval nominalStep = link.targetTimestamp > link.timestamp
        ? (link.targetTimestamp - link.timestamp) : (1.0 / 60.0);
    NSTimeInterval elapsedStep = self.lastTickTimestamp > 0
        ? (link.timestamp - self.lastTickTimestamp) : nominalStep;
    self.lastTickTimestamp = link.timestamp;
    if (elapsedStep <= 0) elapsedStep = nominalStep;
    // Évite une énorme boucle de rattrapage après un passage en arrière-plan,
    // tout en absorbant largement les petites pointes de charge réelles.
    elapsedStep = MIN(elapsedStep, 0.25);

    // Throttle : au-delà de maxSimultaneousAnimations clés actives, les plus
    // anciennes (firstSeenAt le plus petit) gèlent — jamais retirées, juste
    // pas avancées ce tick (voir header). Aucune clé n'est jamais désinscrite
    // par le throttle lui-même.
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

        S7TVEmoteAnimatedFrames *frames = self.framesByKey[key];
        if (!frames.images.count) continue; // décodage pas encore terminé pour cette clé

        NSUInteger idx = self.frameIndexByKey[key].unsignedIntegerValue;
        NSTimeInterval elapsed = self.elapsedByKey[key].doubleValue + elapsedStep;
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
