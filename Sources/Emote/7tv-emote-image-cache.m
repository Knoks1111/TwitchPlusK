/*
 * 7tv-emote-image-cache.m
 *
 * Voir 7tv-emote-image-cache.h pour le contexte (Phase 2).
 */

#import "Emote/7tv-emote-image-cache.h"
#import "Network/7tv-network-emote-cache.h"
#import "Core/7tv-core-manager.h"
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

static BOOL s7tv_isTwitchGIFEmote(id<S7TVResolvedEmote> emote) {
    if (!emote || ![emote respondsToSelector:@selector(providerIdentifier)]) return NO;
    NSString *identifier = [(id)emote providerIdentifier];
    return [identifier caseInsensitiveCompare:@"twitch-gif"] == NSOrderedSame;
}

// The shared image cache is used by every external provider.  Validate both
// the HTTP result and the payload before returning/storing it; otherwise a
// cached 404/429 HTML or JSON response would be retried as an image forever.
static BOOL s7tv_isValidImageResponse(NSURLResponse *response, NSData *data) {
    if (!data.length) return NO;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status >= 300) return NO;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NO;
    BOOL valid = CGImageSourceGetCount(source) > 0;
    CFRelease(source);
    return valid;
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
// Les GIFs Twitch ne doivent ni partager le budget des emotes ni être
// persistés par le cache HTTP. Ce cache mémoire volontairement petit est
// évincé par NSCache sous pression.
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *gifDecodedCache;
// URL en cours de chargement → liste des callbacks en attente. Protégé par
// syncQueue (accès concurrent depuis plusieurs cellules en scroll rapide).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVImageCompletion> *> *pendingCallbacks;
// Frames animées déjà décodées — countLimit plus bas que decodedCache : un
// tableau de N frames pèse N fois plus qu'une image statique, donc la même
// limite ferait exploser la mémoire sur une chaîne avec beaucoup d'emotes
// animées distinctes (voir exigence transverse #3).
@property (nonatomic, strong) NSCache<NSString *, S7TVEmoteAnimatedFrames *> *animatedFramesCache;
// Les boucles GIF sont beaucoup plus coûteuses qu'une emote animée classique.
@property (nonatomic, strong) NSCache<NSString *, S7TVEmoteAnimatedFrames *> *gifAnimatedFramesCache;
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
// File courte dédiée aux previews des cellules visibles (chat et picker). Elle
// n'attend jamais qu'un WebP complet soit décodé avant l'emote suivante.
@property (nonatomic, strong) NSOperationQueue *animatedPreviewDecodeQueue;
@property (nonatomic, strong) NSOperationQueue *animatedDecodeQueue;
// Session éphémère : aucune réponse GIF ne rejoint NSURLCache (ni son disque,
// ni le cache mémoire global partagé avec 7TV/BTTV/FFZ).
@property (nonatomic, strong) NSURLSession *nonPersistentSession;
@property (atomic, assign) NSUInteger cacheGeneration;
- (nullable UIImage *)s7tv_decodeFirstFrameData:(NSData *)data;
- (nullable S7TVEmoteAnimatedFrames *)s7tv_decodeAnimatedWebPData:(NSData *)data
                                                maximumFrameCount:(size_t)maximumFrameCount
                                            preserveLeadingFrames:(BOOL)preserveLeadingFrames
                                                   shouldContinue:(BOOL (^)(void))shouldContinue;
- (BOOL)s7tv_hasActiveFrameRequestsForKey:(NSString *)key requiringPreview:(BOOL)requiringPreview;
- (void)s7tv_publishPreviewFrames:(S7TVEmoteAnimatedFrames *)frames forKey:(NSString *)key;
- (void)s7tv_schedulePreviewForKey:(NSString *)key
                               url:(NSURL *)url
                        generation:(NSUInteger)generation
                    isTwitchGIF:(BOOL)isTwitchGIF;
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
        _gifDecodedCache = [[NSCache alloc] init];
        _gifDecodedCache.countLimit = 8;
        _gifDecodedCache.totalCostLimit = 8 * 1024 * 1024;
        _pendingCallbacks = [NSMutableDictionary dictionary];
        _animatedFramesCache = [[NSCache alloc] init];
        _animatedFramesCache.countLimit = 48; // plus bas que decodedCache — voir raison en @interface
        _animatedFramesCache.totalCostLimit = 48 * 1024 * 1024;
        _gifAnimatedFramesCache = [[NSCache alloc] init];
        _gifAnimatedFramesCache.countLimit = 4;
        _gifAnimatedFramesCache.totalCostLimit = 16 * 1024 * 1024;
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

        NSURLSessionConfiguration *ephemeralConfiguration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        ephemeralConfiguration.URLCache = nil;
        ephemeralConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _nonPersistentSession = [NSURLSession sessionWithConfiguration:ephemeralConfiguration];
    }
    return self;
}

- (nullable UIImage *)cachedImageForResolvedEmote:(id<S7TVResolvedEmote>)emote {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) return nil;
    NSCache *cache = s7tv_isTwitchGIFEmote(emote) ? self.gifDecodedCache : self.decodedCache;
    return [cache objectForKey:key];
}

- (void)imageForResolvedEmote:(id<S7TVResolvedEmote>)emote
                    completion:(S7TVImageCompletion)completion {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    BOOL isTwitchGIF = s7tv_isTwitchGIFEmote(emote);
    NSCache *decodedCache = isTwitchGIF ? self.gifDecodedCache : self.decodedCache;
    UIImage *cached = [decodedCache objectForKey:key];
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
        [self s7tv_loadAndDecodeForKey:key url:emote.imageURL isTwitchGIF:isTwitchGIF];
    });
}

#pragma mark - Animation (frames complètes)

- (nullable S7TVEmoteAnimatedFrames *)cachedFramesForResolvedEmote:(id<S7TVResolvedEmote>)emote {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) return nil;
    NSCache *cache = s7tv_isTwitchGIFEmote(emote)
        ? self.gifAnimatedFramesCache : self.animatedFramesCache;
    return [cache objectForKey:key];
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

    BOOL isTwitchGIF = s7tv_isTwitchGIFEmote(emote);
    NSCache *animatedFramesCache = isTwitchGIF
        ? self.gifAnimatedFramesCache : self.animatedFramesCache;
    S7TVEmoteAnimatedFrames *cached = [animatedFramesCache objectForKey:key];
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
                                      generation:self.cacheGeneration
                                      isTwitchGIF:isTwitchGIF];
            }
            return;
        }
        self.pendingFrameCallbacks[key] = [NSMutableArray arrayWithObject:request];
        if (request.preview) {
            [self s7tv_schedulePreviewForKey:key
                                         url:emote.imageURL
                                  generation:self.cacheGeneration
                                  isTwitchGIF:isTwitchGIF];
        }
        [self s7tv_loadAndDecodeFramesForKey:key
                                        url:emote.imageURL
                                isTwitchGIF:isTwitchGIF];
    });
    return request;
}

// YES si au moins un consommateur non annulé attend toujours cette clé. Avec
// requiringPreview=YES, seuls les consommateurs demandant la boucle rapide
// (cellules visibles du chat ou du picker) sont considérés.
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
- (void)s7tv_schedulePreviewForKey:(NSString *)key
                               url:(NSURL *)url
                        generation:(NSUInteger)generation
                    isTwitchGIF:(BOOL)isTwitchGIF {
    if ([self.pendingPreviewKeys containsObject:key]) return;
    [self.pendingPreviewKeys addObject:key];
    [self s7tv_fetchDataForURL:url persistToDisk:!isTwitchGIF completion:^(NSData * _Nullable data) {
        [self.animatedPreviewDecodeQueue addOperationWithBlock:^{
            S7TVEmoteAnimatedFrames *previewFrames = nil;
            if (data && generation == self.cacheGeneration &&
                [self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:YES]) {
                previewFrames = [self s7tv_decodeAnimatedWebPData:data
                                                 maximumFrameCount:24
                                            preserveLeadingFrames:YES
                                                    shouldContinue:^BOOL{
                    return generation == self.cacheGeneration &&
                        [self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:YES];
                }];
                previewFrames.twitchGIF = isTwitchGIF;
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
// chemin statique). Le renderer reçoit d'abord une boucle légère via sa file
// de preview ; le décodage complet continue séparément sans bloquer les autres
// cellules visibles.
- (void)s7tv_loadAndDecodeFramesForKey:(NSString *)key
                                   url:(NSURL *)url
                           isTwitchGIF:(BOOL)isTwitchGIF {
    NSUInteger generation = self.cacheGeneration;
    [self s7tv_fetchDataForURL:url persistToDisk:!isTwitchGIF completion:^(NSData * _Nullable data) {
        [self.animatedDecodeQueue addOperationWithBlock:^{
            if (generation != self.cacheGeneration ||
                ![self s7tv_hasActiveFrameRequestsForKey:key requiringPreview:NO]) return;
            __block BOOL abandonedBecauseInvisible = NO;
            S7TVEmoteAnimatedFrames *frames = data
                ? [self s7tv_decodeAnimatedWebPData:data
                                  maximumFrameCount:240
                             preserveLeadingFrames:NO
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
                frames.twitchGIF = isTwitchGIF;
                NSCache *animatedFramesCache = isTwitchGIF
                    ? self.gifAnimatedFramesCache : self.animatedFramesCache;
                [animatedFramesCache setObject:frames
                                             forKey:key
                                               cost:s7tv_framesMemoryCost(frames)];
                UIImage *firstFrame = frames.images.firstObject;
                NSCache *decodedCache = isTwitchGIF ? self.gifDecodedCache : self.decodedCache;
                if (![decodedCache objectForKey:key] && firstFrame) {
                    [decodedCache setObject:firstFrame
                                          forKey:key
                                            cost:s7tv_imageMemoryCost(firstFrame)];
                }
            } else {
                frames = nil;
                [[SevenTVManager sharedManager]
                    log:@"⚠️ Emote animée non décodable (WebP invalide/vide): %@", url.absoluteString];
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
    [self.gifDecodedCache removeAllObjects];
    [self.animatedFramesCache removeAllObjects];
    [self.gifAnimatedFramesCache removeAllObjects];

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

// Décodage WebP animé via ImageIO — préfixe fluide pour la preview ou boucle
// complète échantillonnée à 60 fps. Chaque frame conserve sa vraie durée
// (clés WebP, avec repli GIF selon la version d'iOS). Toujours hors main.
- (nullable S7TVEmoteAnimatedFrames *)s7tv_decodeAnimatedWebPData:(NSData *)data
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

    // Le moteur tourne à 60 Hz : les frames au-delà du nombre réellement
    // affichable selon la durée de la boucle ne produisent aucun gain visuel,
    // mais retardent toutes les animations suivantes sur la file série.
    // On lit d'abord les délais (léger), puis on échantillonne uniquement si
    // la source dépasse 60 fps. Un plafond de 240 protège aussi des WebP
    // pathologiques sans dégrader les boucles ordinaires allant jusqu'à 4 s.
    maximumFrameCount = MAX((size_t)2, maximumFrameCount);
    // Une preview doit démarrer vite et rester fluide : lire seulement les
    // premières frames consécutives. L'ancien échantillonnage de 12 images
    // réparties sur toute la boucle transformait par exemple une emote de 4 s
    // en une preview à ~3 fps jusqu'à l'arrivée du décodage complet.
    size_t durationCount = preserveLeadingFrames ? MIN(count, maximumFrameCount) : count;
    NSMutableArray<NSNumber *> *sourceDurations =
        [NSMutableArray arrayWithCapacity:durationCount];
    NSTimeInterval totalDuration = 0.0;
    for (size_t i = 0; i < durationCount; i++) {
        if ((i % 8) == 0 && shouldContinue && !shouldContinue()) {
            CFRelease(source);
            return nil;
        }
        NSTimeInterval duration = s7tv_animationFrameDuration(source, i);
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
            if (!cgImage) continue; // frame corrompue isolée → on saute plutôt que d'abandonner toute l'emote
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

    S7TVEmoteAnimatedFrames *frames = [S7TVEmoteAnimatedFrames new];
    frames.images    = images;
    frames.durations = durations;
    // Si toute la source tient déjà dans la passe rapide, ce résultat est en
    // réalité complet et peut être réutilisé comme tel par le moteur.
    frames.preview = preserveLeadingFrames && decodedCount < count;
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
- (void)s7tv_loadAndDecodeForKey:(NSString *)key
                             url:(NSURL *)url
                     isTwitchGIF:(BOOL)isTwitchGIF {
    NSUInteger generation = self.cacheGeneration;
    [self s7tv_fetchDataForURL:url persistToDisk:!isTwitchGIF completion:^(NSData * _Nullable data) {
        [self.staticDecodeQueue addOperationWithBlock:^{
            NSCache *decodedCache = isTwitchGIF ? self.gifDecodedCache : self.decodedCache;
            UIImage *image = [decodedCache objectForKey:key];
            if (!image && data) image = [self s7tv_decodeFirstFrameData:data];
            if (generation != self.cacheGeneration) image = nil;

            if (image) {
                [decodedCache setObject:image forKey:key cost:s7tv_imageMemoryCost(image)];
            } else {
                [[SevenTVManager sharedManager]
                    log:@"⚠️ Emote image introuvable/non décodable: %@", url.absoluteString];
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

- (void)s7tv_fetchDataForURL:(NSURL *)url
                persistToDisk:(BOOL)persistToDisk
                   completion:(void (^)(NSData * _Nullable data))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (persistToDisk) {
        req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
        NSCachedURLResponse *cachedResponse =
            [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
        if (cachedResponse.data.length &&
            s7tv_isValidImageResponse(cachedResponse.response, cachedResponse.data)) {
            [SevenTVURLProtocol noteCachedEmoteImageURL:url];
            completion(cachedResponse.data);
            return;
        }
        if (cachedResponse) {
            // Remove stale error bodies left by older builds before going to the
            // network, so a later cache-only lookup cannot report a false hit.
            [[SevenTVURLProtocol sharedEmoteCache] removeCachedResponseForRequest:req];
        }
    } else {
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [req setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
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
        // The custom cache is consulted above explicitly. Once it misses (or
        // an invalid body was evicted), bypass NSURLCache as well so a stale
        // 404/429 response from an older session cannot mask a fresh CDN
        // response.
        NSMutableURLRequest *networkRequest = [req mutableCopy];
        networkRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        NSURLSession *session = persistToDisk
            ? [NSURLSession sharedSession] : self.nonPersistentSession;
        NSURLSessionDataTask *task = [session
            dataTaskWithRequest:networkRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (generation != self.cacheGeneration) data = nil;
            if (data.length && response && !error &&
                s7tv_isValidImageResponse(response, data)) {
                if (persistToDisk) {
                    NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
                        initWithResponse:response data:data];
                    [[SevenTVURLProtocol sharedEmoteCache]
                        storeCachedResponse:toCache forRequest:req];
                    [SevenTVURLProtocol noteCachedEmoteImageURL:url];
                }
            } else {
                // Do not let callers decode an HTTP error or malformed body.
                data = nil;
            }
            dispatch_async(self.syncQueue, ^{
                if (generation != self.cacheGeneration) return;
                NSArray<S7TVDataCompletion> *waiting = self.pendingDataCallbacks[key] ?: @[];
                [self.pendingDataCallbacks removeObjectForKey:key];
                for (S7TVDataCompletion callback in waiting) callback(data);
            });
        }];
        [task resume];
    });
}

@end
