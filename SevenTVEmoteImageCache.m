/*
 * SevenTVEmoteImageCache.m
 *
 * Voir SevenTVEmoteImageCache.h pour le contexte (Phase 2).
 */

#import "SevenTVEmoteImageCache.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"
#import <ImageIO/ImageIO.h>

typedef void (^S7TVImageCompletion)(UIImage * _Nullable image);
typedef void (^S7TVFramesCompletion)(S7TVEmoteAnimatedFrames * _Nullable frames);
typedef void (^S7TVFramesPreview)(S7TVEmoteAnimatedFrames *frames);
typedef void (^S7TVDataCompletion)(NSData * _Nullable data);

static void *kS7TVEmoteCacheSyncQueueKey = &kS7TVEmoteCacheSyncQueueKey;

static NSUInteger s7tv_imageMemoryCost(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return 0;
    return CGImageGetBytesPerRow(cgImage) * CGImageGetHeight(cgImage);
}

static NSUInteger s7tv_framesMemoryCost(S7TVEmoteAnimatedFrames *frames) {
    NSUInteger total = 0;
    for (UIImage *image in frames.images) total += s7tv_imageMemoryCost(image);
    return total;
}

static NSString *s7tv_emoteIDFromURL(NSURL *url) {
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger index = [parts indexOfObject:@"emote"];
    if (index != NSNotFound && index + 1 < parts.count) return parts[index + 1];
    return nil;
}

static NSTimeInterval s7tv_animationFrameDuration(CGImageSourceRef source, size_t index) {
    NSTimeInterval duration = 0.1;
    NSDictionary *props = (__bridge_transfer NSDictionary *)
        CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    NSDictionary *webpProps = props[(__bridge NSString *)kCGImagePropertyWebPDictionary];
    NSNumber *delay = webpProps[(__bridge NSString *)kCGImagePropertyWebPUnclampedDelayTime]
                    ?: webpProps[(__bridge NSString *)kCGImagePropertyWebPDelayTime];
    if (!delay) {
        // Certaines versions d'ImageIO exposent les délais WebP sous les clés
        // GIF. Accepter les deux conserve la vitesse réelle de l'animation.
        NSDictionary *gifProps = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        delay = gifProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
              ?: gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
    }
    if (delay && delay.doubleValue > 0) duration = delay.doubleValue;
    return duration;
}

@implementation S7TVEmoteAnimatedFrames
@end

@interface S7TVEmoteFrameRequest ()
@property (atomic, assign, getter=isCancelled) BOOL cancelled;
@property (atomic, copy) S7TVFramesPreview preview;
@property (atomic, copy) S7TVFramesCompletion completion;
@end

@implementation S7TVEmoteFrameRequest
- (void)cancel {
    self.cancelled = YES;
    self.preview = nil;
    self.completion = nil;
}
@end

@interface SevenTVEmoteImageCache ()
// Images déjà décodées — countLimit borne la mémoire (exigence transverse #3).
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *decodedCache;
// URL en cours de chargement → liste des callbacks en attente. Protégé par
// syncQueue (accès concurrent depuis plusieurs cellules en scroll rapide).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVImageCompletion> *> *pendingCallbacks;
// Frames animées déjà décodées — countLimit plus bas que decodedCache : un
// tableau de N frames pèse N fois plus qu'une image statique, donc la même
// limite ferait exploser la mémoire sur une chaîne avec beaucoup d'emotes
// animées distinctes (voir exigence transverse #3).
@property (nonatomic, strong) NSCache<NSString *, S7TVEmoteAnimatedFrames *> *animatedFramesCache;
// Même dédoublonnage que pendingCallbacks, pour le décodage animé.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVEmoteFrameRequest *> *> *pendingFrameCallbacks;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingPreviewKeys;
// Dédoublonnage commun au chemin statique et au chemin animé. Sans lui, une
// même cellule pouvait lancer deux téléchargements de la même URL : un pour
// sa miniature immédiate et un autre pour ses frames.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVDataCompletion> *> *pendingDataCallbacks;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
// Les décodages ImageIO ne doivent jamais saturer tous les cœurs pendant un
// scroll. Les files bornées gardent le travail hors main thread tout en
// donnant la priorité aux miniatures visibles.
@property (nonatomic, strong) NSOperationQueue *staticDecodeQueue;
// File courte dédiée aux previews du picker. Elle n'attend jamais qu'un WebP
// complet soit entièrement décodé avant de passer à l'emote visible suivante.
@property (nonatomic, strong) NSOperationQueue *animatedPreviewDecodeQueue;
@property (nonatomic, strong) NSOperationQueue *animatedDecodeQueue;
@property (atomic, assign) NSUInteger cacheGeneration;
- (nullable UIImage *)s7tv_decodeFirstFrameData:(NSData *)data;
- (nullable S7TVEmoteAnimatedFrames *)s7tv_decodeAnimatedWebPData:(NSData *)data
                                                maximumFrameCount:(size_t)maximumFrameCount
                                                   shouldContinue:(BOOL (^)(void))shouldContinue;
- (BOOL)s7tv_hasActiveFrameRequestsForKey:(NSString *)key requiringPreview:(BOOL)requiringPreview;
- (void)s7tv_publishPreviewFrames:(S7TVEmoteAnimatedFrames *)frames forKey:(NSString *)key;
- (void)s7tv_schedulePreviewForKey:(NSString *)key url:(NSURL *)url generation:(NSUInteger)generation;
@end

@implementation SevenTVEmoteImageCache

+ (instancetype)sharedCache {
    static SevenTVEmoteImageCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVEmoteImageCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _decodedCache = [[NSCache alloc] init];
        _decodedCache.countLimit = 200; // borne mémoire, voir exigence transverse #3
        _decodedCache.totalCostLimit = 24 * 1024 * 1024;
        _pendingCallbacks = [NSMutableDictionary dictionary];
        _animatedFramesCache = [[NSCache alloc] init];
        _animatedFramesCache.countLimit = 48; // plus bas que decodedCache — voir raison en @interface
        _animatedFramesCache.totalCostLimit = 48 * 1024 * 1024;
        _pendingFrameCallbacks = [NSMutableDictionary dictionary];
        _pendingPreviewKeys = [NSMutableSet set];
        _pendingDataCallbacks = [NSMutableDictionary dictionary];
        _syncQueue = dispatch_queue_create("tv.s7tv.emote-image-cache", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_syncQueue, kS7TVEmoteCacheSyncQueueKey,
                                    kS7TVEmoteCacheSyncQueueKey, NULL);
        _cacheGeneration = 1;

        _staticDecodeQueue = [[NSOperationQueue alloc] init];
        _staticDecodeQueue.name = @"tv.s7tv.emote-static-decode";
        _staticDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _staticDecodeQueue.maxConcurrentOperationCount = 2;

        _animatedPreviewDecodeQueue = [[NSOperationQueue alloc] init];
        _animatedPreviewDecodeQueue.name = @"tv.s7tv.emote-animation-preview-decode";
        _animatedPreviewDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _animatedPreviewDecodeQueue.maxConcurrentOperationCount = 2;

        _animatedDecodeQueue = [[NSOperationQueue alloc] init];
        _animatedDecodeQueue.name = @"tv.s7tv.emote-animation-decode";
        _animatedDecodeQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _animatedDecodeQueue.maxConcurrentOperationCount = 1;
    }
    return self;
}

- (nullable UIImage *)cachedImageForResolvedEmote:(id<S7TVResolvedEmote>)emote {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) return nil;
    return [self.decodedCache objectForKey:key];
}

- (void)imageForResolvedEmote:(id<S7TVResolvedEmote>)emote
                    completion:(S7TVImageCompletion)completion {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    UIImage *cached = [self.decodedCache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(self.syncQueue, ^{
        NSMutableArray<S7TVImageCompletion> *callbacks = self.pendingCallbacks[key];
        if (callbacks) {
            // Une requête est déjà en vol pour cette URL (autre cellule qui
            // affiche la même emote) → on rejoint la liste plutôt que de
            // retélécharger/redécoder en double.
            [callbacks addObject:completion];
            return;
        }
        self.pendingCallbacks[key] = [NSMutableArray arrayWithObject:completion];
        [self s7tv_loadAndDecodeForKey:key url:emote.imageURL];
    });
}

#pragma mark - Animation (frames complètes)

- (nullable S7TVEmoteAnimatedFrames *)cachedFramesForResolvedEmote:(id<S7TVResolvedEmote>)emote {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) return nil;
    return [self.animatedFramesCache objectForKey:key];
}

- (void)framesForResolvedEmote:(id<S7TVResolvedEmote>)emote
                     completion:(S7TVFramesCompletion)completion {
    // Le chat n'a pas besoin de preview progressive et conserve l'API simple.
    [self framesForResolvedEmote:emote preview:nil completion:completion];
}

- (S7TVEmoteFrameRequest *)framesForResolvedEmote:(id<S7TVResolvedEmote>)emote
                                          preview:(S7TVFramesPreview)preview
                                       completion:(S7TVFramesCompletion)completion {
    S7TVEmoteFrameRequest *request = [S7TVEmoteFrameRequest new];
    request.preview = preview;
    request.completion = completion;

    if (!emote.isAnimated) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(nil);
        });
        return request;
    }

    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(nil);
        });
        return request;
    }

    S7TVEmoteAnimatedFrames *cached = [self.animatedFramesCache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(cached);
        });
        return request;
    }

    dispatch_async(self.syncQueue, ^{
        NSMutableArray<S7TVEmoteFrameRequest *> *requests = self.pendingFrameCallbacks[key];
        if (requests) {
            // Décodage déjà en vol pour cette clé (autre cellule affichant
            // la même emote animée) → on rejoint la liste, même logique de
            // dédoublonnage que le chemin statique ci-dessous.
            [requests addObject:request];
            if (request.preview) {
                [self s7tv_schedulePreviewForKey:key
                                             url:emote.imageURL
                                      generation:self.cacheGeneration];
            }
            return;
        }
        self.pendingFrameCallbacks[key] = [NSMutableArray arrayWithObject:request];
        if (request.preview) {
            [self s7tv_schedulePreviewForKey:key
                                         url:emote.imageURL
                                  generation:self.cacheGeneration];
        }
        [self s7tv_loadAndDecodeFramesForKey:key url:emote.imageURL];
    });
    return request;
}

// YES si au moins un consommateur non annulé attend toujours cette clé. Avec
// requiringPreview=YES, seuls les consommateurs du picker sont considérés.
- (BOOL)s7tv_hasActiveFrameRequestsForKey:(NSString *)key requiringPreview:(BOOL)requiringPreview {
    __block BOOL active = NO;
    dispatch_block_t inspect = ^{
        NSMutableArray<S7TVEmoteFrameRequest *> *requests = self.pendingFrameCallbacks[key];
        // Pour le décodage complet, retirer réellement les demandes annulées.
        // Si la liste devient vide, une future cellule créera un nouveau
        // pipeline au lieu de rejoindre une opération déjà abandonnée.
        if (!requiringPreview) {
            NSIndexSet *cancelledIndexes = [requests indexesOfObjectsPassingTest:
                ^BOOL(S7TVEmoteFrameRequest *request, NSUInteger idx, BOOL *stop) {
                    return request.isCancelled;
                }];
            if (cancelledIndexes.count) [requests removeObjectsAtIndexes:cancelledIndexes];
            if (requests.count == 0) {
                [self.pendingFrameCallbacks removeObjectForKey:key];
                return;
            }
        }
        for (S7TVEmoteFrameRequest *request in requests) {
            if (request.isCancelled) continue;
            if (requiringPreview && !request.preview) continue;
            active = YES;
            break;
        }
    };
    // Les callbacks réseau dédupliqués sont eux-mêmes délivrés sur syncQueue.
    // Ne jamais dispatch_sync vers la file sur laquelle on se trouve déjà.
    if (dispatch_get_specific(kS7TVEmoteCacheSyncQueueKey)) inspect();
    else dispatch_sync(self.syncQueue, inspect);
    return active;
}

- (void)s7tv_publishPreviewFrames:(S7TVEmoteAnimatedFrames *)frames forKey:(NSString *)key {
    if (!frames.images.count) return;
    dispatch_async(self.syncQueue, ^{
        NSArray<S7TVEmoteFrameRequest *> *requests = [self.pendingFrameCallbacks[key] copy] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (S7TVEmoteFrameRequest *request in requests) {
                if (!request.isCancelled && request.preview) request.preview(frames);
            }
        });
    });
}

// Appelé depuis syncQueue. Le set empêche plusieurs cellules contenant la
// même emote de lancer plusieurs previews. Ce chemin est indépendant du
// décodage complet : si le chat avait demandé la clé avant l'ouverture du
// picker, une cellule nouvellement visible obtient quand même sa preview.
- (void)s7tv_schedulePreviewForKey:(NSString *)key url:(NSURL *)url generation:(NSUInteger)generation {
    if ([self.pendingPreviewKeys containsObject:key]) return;
    [self.pendingPreviewKeys addObject:key];
    [self s7tv_fetchDataForURL:url completion:^(NSData * _Nullable data) {
        [self.animatedPreviewDecodeQueue addOperationWithBlock:^{
            S7TVEmoteAnimatedFrames *previewFrames = nil;
            if (data && generation == self.cacheGeneration &&
                [self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:YES]) {
                previewFrames = [self s7tv_decodeAnimatedWebPData:data
                                                 maximumFrameCount:12
                                                    shouldContinue:^BOOL{
                    return generation == self.cacheGeneration &&
                        [self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:YES];
                }];
            }
            if (previewFrames.images.count > 1 && generation == self.cacheGeneration) {
                [self s7tv_publishPreviewFrames:previewFrames forKey:key];
            }
            dispatch_async(self.syncQueue, ^{
                [self.pendingPreviewKeys removeObject:key];
            });
        }];
    }];
}

// Réutilise s7tv_fetchDataForURL:completion: (cache HTTP partagé avec le
// chemin statique). Le picker reçoit d'abord une boucle légère via sa file de
// preview ; le décodage complet continue séparément sans bloquer les previews
// des autres cellules visibles.
- (void)s7tv_loadAndDecodeFramesForKey:(NSString *)key url:(NSURL *)url {
    NSUInteger generation = self.cacheGeneration;
    [self s7tv_fetchDataForURL:url completion:^(NSData * _Nullable data) {
        [self.animatedDecodeQueue addOperationWithBlock:^{
            if (generation != self.cacheGeneration ||
                ![self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:NO]) return;
            __block BOOL abandonedBecauseInvisible = NO;
            S7TVEmoteAnimatedFrames *frames = data
                ? [self s7tv_decodeAnimatedWebPData:data
                                  maximumFrameCount:240
                                     shouldContinue:^BOOL{
                    BOOL active = generation == self.cacheGeneration &&
                        [self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:NO];
                    if (!active) abandonedBecauseInvisible = YES;
                    return active;
                }]
                : nil;

            // Le helper a déjà retiré atomiquement la liste devenue vide.
            // Ne surtout pas exécuter le cleanup normal : une cellule revenue
            // entre-temps peut avoir créé un nouveau pipeline pour la même clé.
            if (abandonedBecauseInvisible) return;

            if (generation != self.cacheGeneration) frames = nil;
            if (frames.images.count > 0) {
                [self.animatedFramesCache setObject:frames
                                             forKey:key
                                               cost:s7tv_framesMemoryCost(frames)];
                UIImage *firstFrame = frames.images.firstObject;
                if (![self.decodedCache objectForKey:key] && firstFrame) {
                    [self.decodedCache setObject:firstFrame
                                          forKey:key
                                            cost:s7tv_imageMemoryCost(firstFrame)];
                }
            } else {
                frames = nil;
                [[SevenTVManager sharedManager]
                    log:@"[ChatCustom] ⚠️ Emote animée non décodable (WebP invalide/vide): %@", url.absoluteString];
            }

            dispatch_async(self.syncQueue, ^{
                NSArray<S7TVEmoteFrameRequest *> *requests = self.pendingFrameCallbacks[key] ?: @[];
                [self.pendingFrameCallbacks removeObjectForKey:key];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (S7TVEmoteFrameRequest *request in requests) {
                        if (!request.isCancelled && request.completion) request.completion(frames);
                        request.preview = nil;
                        request.completion = nil;
                    }
                });
            });
        }];
    }];
}

- (void)setDecodingSuspended:(BOOL)suspended {
    self.staticDecodeQueue.suspended = suspended;
    self.animatedPreviewDecodeQueue.suspended = suspended;
    self.animatedDecodeQueue.suspended = suspended;
}

- (void)setScrollingPerformanceMode:(BOOL)enabled {
    // Les previews sont volontairement conservées pendant le scroll : elles
    // sont courtes, annulables et constituent précisément ce qui permet aux
    // nouvelles cellules de commencer à bouger immédiatement. Le décodage
    // complet reste borné à une tâche hors main thread dans les deux modes.
    (void)enabled;
    self.animatedPreviewDecodeQueue.maxConcurrentOperationCount = 2;
    self.animatedDecodeQueue.maxConcurrentOperationCount = 1;
}

- (void)clearAllCaches {
    self.cacheGeneration += 1;
    self.staticDecodeQueue.suspended = NO;
    self.animatedPreviewDecodeQueue.suspended = NO;
    self.animatedDecodeQueue.suspended = NO;
    [self.staticDecodeQueue cancelAllOperations];
    [self.animatedPreviewDecodeQueue cancelAllOperations];
    [self.animatedDecodeQueue cancelAllOperations];
    [self.decodedCache removeAllObjects];
    [self.animatedFramesCache removeAllObjects];

    dispatch_sync(self.syncQueue, ^{
        NSMutableArray<S7TVImageCompletion> *imageCallbacks = [NSMutableArray array];
        for (NSArray *callbacks in self.pendingCallbacks.allValues) {
            [imageCallbacks addObjectsFromArray:callbacks];
        }
        NSMutableArray<S7TVEmoteFrameRequest *> *frameRequests = [NSMutableArray array];
        for (NSArray *requests in self.pendingFrameCallbacks.allValues) {
            [frameRequests addObjectsFromArray:requests];
        }
        [self.pendingCallbacks removeAllObjects];
        [self.pendingFrameCallbacks removeAllObjects];
        [self.pendingPreviewKeys removeAllObjects];
        [self.pendingDataCallbacks removeAllObjects];

        dispatch_async(dispatch_get_main_queue(), ^{
            for (S7TVImageCompletion callback in imageCallbacks) callback(nil);
            for (S7TVEmoteFrameRequest *request in frameRequests) {
                if (!request.isCancelled && request.completion) request.completion(nil);
                request.preview = nil;
                request.completion = nil;
            }
        });
    });
}

// Décodage WebP animé complet via ImageIO — chaque frame + sa durée
// (propriété WebP delay time, avec repli sur les clés GIF si ImageIO les
// expose ainsi selon la version d'OS). Toujours appelé hors main thread
// (voir s7tv_loadAndDecodeFramesForKey:url:, lui-même dans le completion
// handler NSURLSession qui ne délivre jamais sur le main thread).
- (nullable S7TVEmoteAnimatedFrames *)s7tv_decodeAnimatedWebPData:(NSData *)data
                                                maximumFrameCount:(size_t)maximumFrameCount
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

    // Le moteur tourne à 60 Hz : les frames au-delà du nombre réellement
    // affichable selon la durée de la boucle ne produisent aucun gain visuel,
    // mais retardent toutes les animations suivantes sur la file série.
    // On lit d'abord les délais (léger), puis on échantillonne uniquement si
    // la source dépasse 60 fps. Un plafond de 240 protège aussi des WebP
    // pathologiques sans dégrader les boucles ordinaires allant jusqu'à 4 s.
    NSMutableArray<NSNumber *> *sourceDurations = [NSMutableArray arrayWithCapacity:count];
    NSTimeInterval totalDuration = 0.0;
    for (size_t i = 0; i < count; i++) {
        if ((i % 8) == 0 && shouldContinue && !shouldContinue()) {
            CFRelease(source);
            return nil;
        }
        NSTimeInterval duration = s7tv_animationFrameDuration(source, i);
        [sourceDurations addObject:@(duration)];
        totalDuration += duration;
    }

    maximumFrameCount = MAX((size_t)2, maximumFrameCount);
    size_t displayableCount = (size_t)(totalDuration * 60.0 + 0.999);
    displayableCount = MAX((size_t)1, MIN(displayableCount, maximumFrameCount));
    size_t decodedCount = MIN(count, displayableCount);

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
            size_t sourceIndex = (sample * count) / decodedCount;
            size_t nextSourceIndex = ((sample + 1) * count) / decodedCount;
            nextSourceIndex = MAX(nextSourceIndex, sourceIndex + 1);

            CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, sourceIndex,
                (__bridge CFDictionaryRef)decodeOptions);
            if (!cgImage) continue; // frame corrompue isolée → on saute plutôt que d'abandonner toute l'emote
            [images addObject:[UIImage imageWithCGImage:cgImage]];
            CGImageRelease(cgImage);

            NSTimeInterval duration = 0.0;
            for (size_t i = sourceIndex; i < nextSourceIndex && i < count; i++) {
                duration += sourceDurations[i].doubleValue;
            }
            if (duration <= 0) duration = 0.1;
            [durations addObject:@(duration)];
        }
    }
    CFRelease(source);

    if (images.count == 0) return nil;

    S7TVEmoteAnimatedFrames *frames = [S7TVEmoteAnimatedFrames new];
    frames.images    = images;
    frames.durations = durations;
    return frames;
}

// Cache-first (partagé avec le picker et le prefetch de channel — voir
// SevenTVURLProtocol.sharedEmoteCache), sinon téléchargement via NSURLSession.
// ENTIÈREMENT asynchrone — pas de blocage de thread. Une salve de dizaines
// d'emotes demandées en même temps (chat actif, arrivée sur une chaîne) ne
// consomme donc jamais tout le pool de threads GCD : chaque requête réseau
// s'exécute sur son propre callback quand elle est prête, point.
//
// (Version précédente : bloquait un thread de la queue utility par requête
// via dispatch_semaphore_wait le temps de la réponse réseau. Sous charge —
// beaucoup d'emotes différentes demandées d'un coup — ça épuisait le pool de
// threads GCD, empêchant même les réponses déjà arrivées d'être traitées à
// temps → timeout en cascade → aucune image ne se posait, glyphe par défaut
// affichée à la place. C'était un vrai bug introduit par ce fichier, pas lié
// au pipeline de prefetch existant de SevenTVManager.)
- (void)s7tv_loadAndDecodeForKey:(NSString *)key url:(NSURL *)url {
    NSUInteger generation = self.cacheGeneration;
    [self s7tv_fetchDataForURL:url completion:^(NSData * _Nullable data) {
        [self.staticDecodeQueue addOperationWithBlock:^{
            UIImage *image = [self.decodedCache objectForKey:key];
            if (!image && data) image = [self s7tv_decodeFirstFrameData:data];
            if (generation != self.cacheGeneration) image = nil;

            if (image) {
                [self.decodedCache setObject:image forKey:key cost:s7tv_imageMemoryCost(image)];
            } else {
                [[SevenTVManager sharedManager]
                    log:@"[ChatCustom] ⚠️ Emote image introuvable/non décodable: %@", url.absoluteString];
            }

            dispatch_async(self.syncQueue, ^{
                NSArray<S7TVImageCompletion> *callbacks = self.pendingCallbacks[key] ?: @[];
                [self.pendingCallbacks removeObjectForKey:key];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (S7TVImageCompletion cb in callbacks) cb(image);
                });
            });
        }];
    }];
}

// Décode uniquement la première frame et force sa décompression sur la file
// de fond. UIImage imageWithData: pouvait conserver un backing compressé et
// reporter le coût au premier draw de l'UIImageView sur le main thread.
- (nullable UIImage *)s7tv_decodeFirstFrameData:(NSData *)data {
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

- (void)s7tv_fetchDataForURL:(NSURL *)url completion:(void (^)(NSData * _Nullable data))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    NSCachedURLResponse *cachedResponse =
        [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
    if (cachedResponse.data.length) {
        [SevenTVURLProtocol noteCachedEmoteID:s7tv_emoteIDFromURL(url)];
        completion(cachedResponse.data);
        return;
    }

    NSString *key = url.absoluteString;
    if (!key.length) {
        completion(nil);
        return;
    }

    dispatch_async(self.syncQueue, ^{
        NSMutableArray<S7TVDataCompletion> *callbacks = self.pendingDataCallbacks[key];
        if (callbacks) {
            [callbacks addObject:completion];
            return;
        }
        self.pendingDataCallbacks[key] = [NSMutableArray arrayWithObject:completion];
        NSUInteger generation = self.cacheGeneration;

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:url
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (generation != self.cacheGeneration) data = nil;
            if (data.length && response && !error) {
                NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
                    initWithResponse:response data:data];
                [[SevenTVURLProtocol sharedEmoteCache] storeCachedResponse:toCache forRequest:req];
                [SevenTVURLProtocol noteCachedEmoteID:s7tv_emoteIDFromURL(url)];
            }
            dispatch_async(self.syncQueue, ^{
                NSArray<S7TVDataCompletion> *waiting = self.pendingDataCallbacks[key] ?: @[];
                [self.pendingDataCallbacks removeObjectForKey:key];
                for (S7TVDataCompletion callback in waiting) callback(data);
            });
        }];
        [task resume];
    });
}

@end
