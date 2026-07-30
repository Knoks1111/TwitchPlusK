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
        [self s7tv_loadAndDecodeForKey:key url:emote.imageURL];
    });
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
    [self s7tv_fetchDataForURL:url completion:^(NSData * _Nullable data) {
        // Décodage hors thread principal — le completion handler de
        // NSURLSession (partagée) ne délivre jamais sur le main thread par
        // défaut, donc on est déjà en sécurité ici sans dispatch explicite.
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
    }];
}

- (void)s7tv_fetchDataForURL:(NSURL *)url completion:(void (^)(NSData * _Nullable data))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    NSCachedURLResponse *cachedResponse =
        [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
    if (cachedResponse.data.length) {
        completion(cachedResponse.data);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length && response && !error) {
            // Mise en cache partagée — un futur passage (picker, autre
            // message avec la même emote) en profite directement.
            NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
                initWithResponse:response data:data];
            [[SevenTVURLProtocol sharedEmoteCache] storeCachedResponse:toCache forRequest:req];
        }
        completion(data);
    }];
    [task resume];
}

@end
