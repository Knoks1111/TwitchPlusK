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

@implementation S7TVEmoteAnimatedFrames
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<S7TVFramesCompletion> *> *pendingFrameCallbacks;
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
        _animatedFramesCache = [[NSCache alloc] init];
        _animatedFramesCache.countLimit = 60; // plus bas que decodedCache — voir raison en @interface
        _pendingFrameCallbacks = [NSMutableDictionary dictionary];
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

#pragma mark - Animation (frames complètes)

- (nullable S7TVEmoteAnimatedFrames *)cachedFramesForResolvedEmote:(id<S7TVResolvedEmote>)emote {
    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) return nil;
    return [self.animatedFramesCache objectForKey:key];
}

- (void)framesForResolvedEmote:(id<S7TVResolvedEmote>)emote
                     completion:(S7TVFramesCompletion)completion {
    if (!emote.isAnimated) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    NSString *key = emote.imageURL.absoluteString;
    if (!key.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    S7TVEmoteAnimatedFrames *cached = [self.animatedFramesCache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(self.syncQueue, ^{
        NSMutableArray<S7TVFramesCompletion> *callbacks = self.pendingFrameCallbacks[key];
        if (callbacks) {
            // Décodage déjà en vol pour cette clé (autre cellule affichant
            // la même emote animée) → on rejoint la liste, même logique de
            // dédoublonnage que le chemin statique ci-dessous.
            [callbacks addObject:completion];
            return;
        }
        self.pendingFrameCallbacks[key] = [NSMutableArray arrayWithObject:completion];
        [self s7tv_loadAndDecodeFramesForKey:key url:emote.imageURL];
    });
}

// Réutilise s7tv_fetchDataForURL:completion: (cache HTTP partagé avec le
// chemin statique et le prefetch de channel) — seul le décodage diffère :
// ici on décode TOUTES les frames au lieu de la seule 1ère.
- (void)s7tv_loadAndDecodeFramesForKey:(NSString *)key url:(NSURL *)url {
    [self s7tv_fetchDataForURL:url completion:^(NSData * _Nullable data) {
        // Décodage hors main thread — même raisonnement que
        // s7tv_loadAndDecodeForKey:url: pour le chemin statique.
        S7TVEmoteAnimatedFrames *frames = data ? [self s7tv_decodeAnimatedWebPData:data] : nil;

        if (frames.images.count > 0) {
            [self.animatedFramesCache setObject:frames forKey:key];
            // La 1ère frame alimente aussi decodedCache (chemin statique) si
            // elle n'y est pas déjà — garde cachedImageForResolvedEmote:
            // cohérent avec ce qu'on vient de décoder, sans redécoder deux
            // fois la même image pour rien.
            if (![self.decodedCache objectForKey:key]) {
                [self.decodedCache setObject:frames.images.firstObject forKey:key];
            }
        } else {
            frames = nil;
            [[SevenTVManager sharedManager]
                log:@"[ChatCustom] ⚠️ Emote animée non décodable (WebP invalide/vide): %@", url.absoluteString];
        }

        dispatch_async(self.syncQueue, ^{
            NSArray<S7TVFramesCompletion> *callbacks = self.pendingFrameCallbacks[key] ?: @[];
            [self.pendingFrameCallbacks removeObjectForKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                for (S7TVFramesCompletion cb in callbacks) cb(frames);
            });
        });
    }];
}

// Décodage WebP animé complet via ImageIO — chaque frame + sa durée
// (propriété WebP delay time, avec repli sur les clés GIF si ImageIO les
// expose ainsi selon la version d'OS). Toujours appelé hors main thread
// (voir s7tv_loadAndDecodeFramesForKey:url:, lui-même dans le completion
// handler NSURLSession qui ne délivre jamais sur le main thread).
- (nullable S7TVEmoteAnimatedFrames *)s7tv_decodeAnimatedWebPData:(NSData *)data {
    if (!data.length) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t count = CGImageSourceGetCount(source);
    if (count == 0) {
        CFRelease(source);
        return nil;
    }

    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:count];

    for (size_t i = 0; i < count; i++) {
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, i, NULL);
        if (!cgImage) continue; // frame corrompue isolée → on saute plutôt que d'abandonner toute l'emote
        [images addObject:[UIImage imageWithCGImage:cgImage]];
        CGImageRelease(cgImage);

        NSTimeInterval duration = 0.1; // filet de sécurité si la métadonnée manque
        NSDictionary *props = (__bridge_transfer NSDictionary *)
            CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
        NSDictionary *webpProps = props[(__bridge NSString *)kCGImagePropertyWebPDictionary];
        NSNumber *delay = webpProps[(__bridge NSString *)kCGImagePropertyWebPUnclampedDelayTime]
                        ?: webpProps[(__bridge NSString *)kCGImagePropertyWebPDelayTime];
        if (!delay) {
            // Repli GIF : constaté que certaines versions d'ImageIO exposent
            // les WebP animés via les mêmes clés que les GIF plutôt que les
            // clés WebP dédiées — on couvre les deux plutôt que de supposer
            // un seul comportement.
            NSDictionary *gifProps = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
            delay = gifProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
                  ?: gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
        }
        if (delay && delay.doubleValue > 0) duration = delay.doubleValue;
        [durations addObject:@(duration)];
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
