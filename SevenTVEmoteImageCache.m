/*
 * SevenTVEmoteImageCache.m
 *
 * Voir SevenTVEmoteImageCache.h pour le contexte (Phase 2).
 */

#import "SevenTVEmoteImageCache.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"

typedef void (^S7TVImageCompletion)(UIImage * _Nullable image);

@interface SevenTVEmoteImageCache ()
// Images déjà décodées — countLimit borne la mémoire (exigence transverse #3).
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *decodedCache;
// URL en cours de chargement → liste des callbacks en attente. Protégé par
// syncQueue (accès concurrent depuis plusieurs cellules en scroll rapide).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVImageCompletion> *> *pendingCallbacks;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
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
        _pendingCallbacks = [NSMutableDictionary dictionary];
        _syncQueue = dispatch_queue_create("tv.s7tv.emote-image-cache", DISPATCH_QUEUE_SERIAL);
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

        NSURL *url = emote.imageURL;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self s7tv_loadAndDecodeForKey:key url:url];
        });
    });
}

// Hors thread principal (queue utility) : va chercher les données (cache
// partagé avec le picker/prefetch, sinon réseau), décode, puis notifie tous
// les appelants en attente sur le main thread.
- (void)s7tv_loadAndDecodeForKey:(NSString *)key url:(NSURL *)url {
    NSData *data = [self s7tv_dataForURL:url];
    // +imageWithData: décode nativement le WebP (animé ou statique) sur iOS,
    // sans conversion — ne restitue que la 1ère frame pour l'instant (voir
    // note d'en-tête : l'animation est un incrément séparé).
    UIImage *image = data ? [UIImage imageWithData:data] : nil;

    if (image) {
        [self.decodedCache setObject:image forKey:key];
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
}

// Cache-first (partagé avec le picker et le prefetch de channel — voir
// SevenTVURLProtocol.sharedEmoteCache), sinon téléchargement direct. On est
// déjà hors main thread ici, donc un appel réseau bloquant sur cette queue
// (via sémaphore) ne gèle rien côté UI ; timeout 10s en garde-fou.
- (nullable NSData *)s7tv_dataForURL:(NSURL *)url {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    NSCachedURLResponse *cachedResponse =
        [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
    if (cachedResponse.data.length) return cachedResponse.data;

    __block NSData *resultData = nil;
    __block NSURLResponse *resultResponse = nil;
    __block NSError *resultError = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        resultData = data;
        resultResponse = response;
        resultError = error;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

    if (resultData.length && resultResponse && !resultError) {
        // Mise en cache partagée — un futur passage (picker, autre message
        // avec la même emote) en profite directement, pas de re-téléchargement.
        NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
            initWithResponse:resultResponse data:resultData];
        [[SevenTVURLProtocol sharedEmoteCache] storeCachedResponse:toCache forRequest:req];
    }
    return resultData;
}

@end
