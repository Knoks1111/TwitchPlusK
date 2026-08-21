/*
 * SevenTVURLProtocol.m
 *
 * Utilitaire de téléchargement/cache des images d'emotes 7TV.
 *
 * HISTORIQUE : cette classe s'appelait ainsi car elle interceptait les
 * requêtes HTTP que Twitch faisait pour charger les images d'emotes (via un
 * faux ID "7tv_{realID}" injecté dans le tag emotes= du message IRC). Cette
 * injection a été retirée (le rendu du chat passe à une vue maison), donc
 * l'interception ne se déclenche plus jamais — le code NSURLProtocol
 * (canInitWithRequest:/startLoading/stopLoading) a été supprimé.
 *
 * Ce qui reste et qui est toujours utilisé :
 *   - prefetchEmoteID:completion: / isEmoteIDCached: — appelés directement
 *     par SevenTVManager au JOIN d'un channel (prefetch en masse).
 *   - sharedEmoteCache — lu directement par le picker pour afficher les
 *     images sans réseau supplémentaire.
 *
 * FORMAT: les emotes sont stockées telles que reçues du CDN 7TV, en WebP
 * natif (animé ou statique) — aucune conversion en GIF.
 */

#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"
#import "SevenTVChatAppearanceConfig.h"

NSString *const S7TVEmoteCacheCountDidChangeNotification = @"S7TVEmoteCacheCountDidChangeNotification";

// ── Sessions CDN ──────────────────────────────────────────────────────────────
//
// ARCHITECTURE (important pour la cohérence du cache) :
//
//   SevenTVGetCDNSession()      — utilisée par prewarm
//   SevenTVGetPrefetchSession() — utilisée par prefetchEmoteID:completion:
//
// Les deux partagent le MÊME objet NSURLCache (s_emoteCache), donc les
// requêtes arrivent au cache avec la clé URL brute (identique dans les deux).

static NSURLCache      *s_emoteCache     = nil;
static dispatch_once_t  s_emoteCacheOnce;

// Cache partagé entre les deux sessions.
static NSURLCache *SevenTVGetSharedCache(void) {
    dispatch_once(&s_emoteCacheOnce, ^{
        s_emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
    });
    return s_emoteCache;
}

static NSURLSession    *s_cdnSession     = nil;
static dispatch_once_t  s_cdnSessionOnce;

static NSURLSession *SevenTVGetCDNSession(void) {
    dispatch_once(&s_cdnSessionOnce, ^{
        // ephemeralSessionConfiguration : configuration VIERGE, sans héritage
        // du sharedURLCache ni des hooks de TwitchControl (setRequestCachePolicy:,
        // removeAllCachedResponses). defaultSessionConfiguration hérite du
        // sharedURLCache que TwitchControl vide périodiquement → cache miss
        // systématique sur toutes les emotes → re-téléchargement à chaque fois.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache(); // notre cache isolé
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[]; // isolation totale, aucun protocole custom
        s_cdnSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_cdnSession;
}

// Session dédiée au prefetch — même cache, même isolation URLProtocol.
static NSURLSession    *s_prefetchSession     = nil;
static dispatch_once_t  s_prefetchSessionOnce;

static NSURLSession *SevenTVGetPrefetchSession(void) {
    dispatch_once(&s_prefetchSessionOnce, ^{
        // Même raison qu'au-dessus : ephemeral isole du sharedURLCache
        // et des hooks TwitchControl. Même cache partagé s_emoteCache.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache();
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[];
        // 4 connexions max pour le bulk — laisse de la place à l'urgent session
        cfg.HTTPMaximumConnectionsPerHost = 4;
        s_prefetchSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_prefetchSession;
}

// Session urgente — utilisée UNIQUEMENT par prefetchEmoteID:completion:
// (déclenché quand une emote apparaît dans le chat).
// Complètement séparée de la bulk session → pas de contention HTTP/2.
// Même NSURLCache partagé → les deux écrivent au même endroit.
static NSURLSession    *s_urgentSession     = nil;
static dispatch_once_t  s_urgentSessionOnce;

static NSURLSession *SevenTVGetUrgentSession(void) {
    dispatch_once(&s_urgentSessionOnce, ^{
        // Même raison : ephemeral pour isolation totale.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache(); // même cache que bulk
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[];
        // 8 connexions — couvre le semaphore bulk (6) + les urgences temps réel.
        // HTTP/2 multiplex sur une connexion TCP, donc pas de surcoût réseau.
        cfg.HTTPMaximumConnectionsPerHost = 8;
        s_urgentSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_urgentSession;
}

// ── URL CDN pour un emote ID ─────────────────────────────────────────────────
// Résolution commune chat/picker/préfetch, configurable de 1x à 4x dans les
// vrais réglages 7TV. Défaut 2x. Le WebP reste servi tel quel.
static NSURL *SevenTVCDNURLForEmoteID(NSString *emoteID) {
    NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
    resolution = MIN(4, MAX(1, resolution));
    NSString *str = [NSString stringWithFormat:
        @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)resolution];
    return [NSURL URLWithString:str];
}

// ── Validation réponse CDN ───────────────────────────────────────────────────
//
// PROBLÈME CORRIGÉ (historique) : prefetchEmoteID:completion: ne vérifiait pas
// le statut HTTP ni le contenu réel des données avant de les mettre en cache.
// Si le CDN renvoie un 404 avec un petit corps JSON/HTML d'erreur, ce corps
// était accepté comme "image valide" et stocké en cache tel quel → entrée de
// cache corrompue permanente pour cette emote.
//
// Double vérification :
//   - statusCode == 200 — élimine 404/403/5xx etc.
//   - signature de fichier WebP ("RIFF" + "WEBP" à l'offset 8) — élimine tout
//     corps de réponse qui ne serait pas un vrai WebP (page d'erreur, JSON,
//     HTML), même si le CDN renvoyait par erreur un statusCode 200.
static BOOL SevenTVIsValidWebPResponse(NSURLResponse *response, NSData *data) {
    if (!data || data.length < 12) return NO;

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status != 200) return NO;
    }

    // Format RIFF : 4 octets "RIFF" + 4 octets taille (ignorés) + 4 octets "WEBP".
    const char *bytes = (const char *)data.bytes;
    BOOL hasRIFF = (memcmp(bytes, "RIFF", 4) == 0);
    BOOL hasWEBP = (memcmp(bytes + 8, "WEBP", 4) == 0);
    return hasRIFF && hasWEBP;
}

// ── Compteur global des emotes mises en cache (WebP natif, plus de conversion) ──
static _Atomic(NSInteger) s_cachedCount = 0;
static _Atomic(NSUInteger) s_cacheGeneration = 1;
static NSMutableSet<NSString *> *s_cachedEmoteIDs = nil;
static dispatch_once_t s_cachedEmoteIDsOnce;
static BOOL s_cacheIndexSaveScheduled = NO;
static NSString *const kS7TVCachedEmoteIDsKey = @"s7tv_cached_emote_ids";

static NSMutableSet<NSString *> *SevenTVCachedEmoteIDs(void) {
    dispatch_once(&s_cachedEmoteIDsOnce, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults]
            arrayForKey:kS7TVCachedEmoteIDsKey] ?: @[];
        s_cachedEmoteIDs = [NSMutableSet setWithArray:saved];
        s_cachedCount = (NSInteger)s_cachedEmoteIDs.count;
    });
    return s_cachedEmoteIDs;
}

static BOOL SevenTVAnyCachedResolutionForEmoteID(NSString *emoteID) {
    if (!emoteID.length) return NO;
    for (NSInteger scale = 1; scale <= 4; scale++) {
        NSString *urlString = [NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)scale];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url && [SevenTVGetSharedCache() cachedResponseForRequest:
                    [NSURLRequest requestWithURL:url]]) return YES;
    }
    return NO;
}

static void SevenTVScheduleCacheIndexSave(void) {
    @synchronized (SevenTVCachedEmoteIDs()) {
        if (s_cacheIndexSaveScheduled) return;
        s_cacheIndexSaveScheduled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *snapshot = nil;
        @synchronized (SevenTVCachedEmoteIDs()) {
            snapshot = SevenTVCachedEmoteIDs().allObjects;
            s_cacheIndexSaveScheduled = NO;
        }
        [[NSUserDefaults standardUserDefaults] setObject:snapshot
                                                   forKey:kS7TVCachedEmoteIDsKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:S7TVEmoteCacheCountDidChangeNotification object:nil];
        });
    });
}


@implementation SevenTVURLProtocol

+ (NSInteger)cachedEmoteCount {
    SevenTVCachedEmoteIDs();
    return s_cachedCount;
}

+ (void)refreshCachedEmoteCountWithCompletion:(void (^)(NSInteger))completion {
    NSArray<NSString *> *known = nil;
    @synchronized (SevenTVCachedEmoteIDs()) {
        known = SevenTVCachedEmoteIDs().allObjects;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        for (NSString *emoteID in known) {
            if (!SevenTVAnyCachedResolutionForEmoteID(emoteID)) {
                [missing addObject:emoteID];
            }
        }
        NSInteger count = 0;
        @synchronized (SevenTVCachedEmoteIDs()) {
            [SevenTVCachedEmoteIDs() minusSet:[NSSet setWithArray:missing]];
            s_cachedCount = (NSInteger)SevenTVCachedEmoteIDs().count;
            count = s_cachedCount;
        }
        if (missing.count) SevenTVScheduleCacheIndexSave();
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(count); });
    });
}

+ (void)noteCachedEmoteID:(NSString *)emoteID {
    if (!emoteID.length) return;
    BOOL added = NO;
    @synchronized (SevenTVCachedEmoteIDs()) {
        if (![SevenTVCachedEmoteIDs() containsObject:emoteID]) {
            [SevenTVCachedEmoteIDs() addObject:emoteID];
            added = YES;
        }
        s_cachedCount = (NSInteger)SevenTVCachedEmoteIDs().count;
    }
    if (added) SevenTVScheduleCacheIndexSave();
}

// ============================================================
// MARK: - Utilitaires (appelés depuis TweakSevenTV.m)
// ============================================================

// Vérifie si l'image est en cache sans faire de réseau.
+ (BOOL)isEmoteIDCached:(NSString *)emoteID {
    if (!emoteID.length) return NO;
    NSURL *url = SevenTVCDNURLForEmoteID(emoteID);
    if (!url) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    BOOL cached = ([SevenTVGetSharedCache() cachedResponseForRequest:req] != nil);
    if (cached) [self noteCachedEmoteID:emoteID];
    return cached;
}

// Télécharge l'image et appelle completion quand elle est en cache.
// completion est toujours appelé (succès, erreur, ou timeout 1s).
//
// Utilise SevenTVGetPrefetchSession() — même NSURLCache que les autres
// sessions CDN — pour garantir que la réponse est stockée sous la clé
// URL brute, la même que lit isEmoteIDCached:/le picker.
+ (void)prefetchEmoteID:(NSString *)emoteID completion:(void(^)(void))completion {
    if (!emoteID.length) {
        if (completion) completion();
        return;
    }

    NSURL *url = SevenTVCDNURLForEmoteID(emoteID);
    if (!url) {
        if (completion) completion();
        return;
    }

    // Si déjà en cache → completion immédiate, pas de réseau.
    NSMutableURLRequest *checkReq = [NSMutableURLRequest requestWithURL:url];
    checkReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    if ([SevenTVGetSharedCache() cachedResponseForRequest:checkReq]) {
        [self noteCachedEmoteID:emoteID];
        if (completion) completion();
        return;
    }

    // Téléchargement en background via la session prefetch dédiée.
    // La completion est appelée exactement une fois par NSURLSession :
    // succès, erreur réseau, ou expiration (timeoutInterval).
    // 30s : avec 6 streams HTTP/2 en parallèle et 335 emotes, les requêtes
    // en queue pouvaient expirer avant d'être envoyées avec l'ancien 10s.
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy     = NSURLRequestReturnCacheDataElseLoad;
    req.timeoutInterval = 30.0;

    // Session URGENTE — indépendante du bulk prefetch.
    NSUInteger requestGeneration = s_cacheGeneration;
    [[SevenTVGetUrgentSession() dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            [[SevenTVManager sharedManager] log:@"⚠️ Préfetch %@ → %@",
             emoteID, err.localizedDescription];
        }
        // Stockage manuel — NSURLSession ne stocke que si le CDN retourne les
        // bons headers Cache-Control. On utilise une requête propre (juste l'URL)
        // pour que la clé de cache corresponde exactement à ce que lit
        // isEmoteIDCached:/le picker via cachedResponseForRequest:.
        //
        // Validation AVANT stockage : sans ça, un 404 7TV avec un petit corps
        // JSON/HTML d'erreur était accepté comme image valide et restait en
        // cache pour toujours.
        //
        // On stocke le WebP natif tel que reçu du CDN 7TV — plus de conversion
        // GIF, format d'origine conservé tel quel.
        if (data && resp && !err && requestGeneration == s_cacheGeneration) {
            if (SevenTVIsValidWebPResponse(resp, data)) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
                NSHTTPURLResponse *webpResp = [[NSHTTPURLResponse alloc]
                    initWithURL:url
                    statusCode:http.statusCode
                   HTTPVersion:@"HTTP/1.1"
                  headerFields:@{@"Content-Type": @"image/webp"}];
                NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
                    initWithResponse:webpResp data:data];
                NSURLRequest *cacheKey = [NSURLRequest requestWithURL:url];
                [SevenTVGetSharedCache() storeCachedResponse:toCache forRequest:cacheKey];

                [self noteCachedEmoteID:emoteID];
                [[SevenTVManager sharedManager] log:
                    @"🖼 Préfetch %@ → WebP natif mis en cache (%lu bytes) [total:%ld]",
                    emoteID, (unsigned long)data.length, (long)s_cachedCount];
            } else {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)resp).statusCode : -1;
                [[SevenTVManager sharedManager] log:
                    @"❌ Préfetch %@ → réponse invalide status:%ld bytes:%lu — non mise en cache",
                    emoteID, (long)status, (unsigned long)data.length];
            }
        }
        if (completion) completion();
    }] resume];
}


// ============================================================
// MARK: - Préchauffage connexion CDN
// ============================================================

// ============================================================
// MARK: - Cache partagé (accessible depuis SevenTVManager pour le picker)
// ============================================================

+ (NSURLCache *)sharedEmoteCache {
    return SevenTVGetSharedCache();
}

+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger))completion {
    NSUInteger clearedCount = (NSUInteger)[self cachedEmoteCount];
    s_cacheGeneration++;

    dispatch_group_t cancellationGroup = dispatch_group_create();
    void (^cancelTasks)(NSURLSession *) = ^(NSURLSession *session) {
        dispatch_group_enter(cancellationGroup);
        [session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
            for (NSURLSessionTask *task in tasks) [task cancel];
            dispatch_group_leave(cancellationGroup);
        }];
    };
    cancelTasks(SevenTVGetCDNSession());
    cancelTasks(SevenTVGetPrefetchSession());
    cancelTasks(SevenTVGetUrgentSession());

    dispatch_group_notify(cancellationGroup,
                          dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [SevenTVGetSharedCache() removeAllCachedResponses];
        @synchronized (SevenTVCachedEmoteIDs()) {
            [SevenTVCachedEmoteIDs() removeAllObjects];
            s_cachedCount = 0;
            s_cacheIndexSaveScheduled = NO;
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kS7TVCachedEmoteIDsKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:S7TVEmoteCacheCountDidChangeNotification object:nil];
            if (completion) completion(clearedCount);
        });
    });
}

+ (void)prewarmCDNConnection {
    NSURL *warmURL = SevenTVCDNURLForEmoteID(@"01F6MSP3NV00001B6E");
    if (!warmURL) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:warmURL];
    req.HTTPMethod     = @"HEAD";
    req.timeoutInterval = 10.0;

    [[SevenTVGetCDNSession() dataTaskWithRequest:req
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSLog(@"[TwitchSevenTV] 🔥 CDN prewarm: %@",
              e ? e.localizedDescription : @"OK");
    }] resume];
}

@end
