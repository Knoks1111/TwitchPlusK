/*
 * 7tv-network-emote-cache.m
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
 *   - sharedEmoteCache — cache explicite partagé par le renderer, le picker
 *     et les diagnostics.
 *   - l'index provider-aware des identités mises en cache, utilisé par les
 *     réglages pour afficher un compteur fiable.
 *
 * FORMAT: les emotes sont stockées telles que reçues du CDN 7TV, en WebP
 * natif (animé ou statique) — aucune conversion en GIF.
 */

#import "Network/7tv-network-emote-cache.h"
#import "Chat/7tv-chat-appearance-config.h"
#import <ImageIO/ImageIO.h>

NSString *const S7TVEmoteCacheCountDidChangeNotification = @"S7TVEmoteCacheCountDidChangeNotification";

// ── Cache d'images partagé ───────────────────────────────────────────────────
//
// Le catalogue ne télécharge que les métadonnées provider. Les images sont
// demandées à la demande par SevenTVEmoteImageCache, qui écrit explicitement
// dans ce NSURLCache. Il n'existe donc plus de session de préchauffage ou de
// préchargement 7TV séparée.

static NSURLCache *s_emoteCache = nil;
static dispatch_once_t s_emoteCacheOnce;

static NSURLCache *SevenTVGetSharedCache(void) {
    dispatch_once(&s_emoteCacheOnce, ^{
        s_emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
    });
    return s_emoteCache;
}

// ── URL CDN historique 7TV (utilisée uniquement par la migration du compteur)
// La résolution reste bornée aux valeurs prises en charge par l'ancien index.
static NSURL *SevenTVCDNURLForEmoteID(NSString *emoteID) {
    NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
    resolution = MIN(4, MAX(1, resolution));
    NSString *str = [NSString stringWithFormat:
        @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)resolution];
    return [NSURL URLWithString:str];
}

// ── Validation réponse CDN ───────────────────────────────────────────────────
//
// Validation conservée pour vérifier les anciennes entrées WebP 7TV lors de la
// migration/actualisation de l'index. Les nouveaux téléchargements passent par
// SevenTVEmoteImageCache et sa validation provider-agnostique.
// Si le CDN renvoie un 404 avec un petit corps JSON/HTML d'erreur, ce corps
// était accepté comme "image valide" et stocké en cache tel quel → entrée de
// cache corrompue permanente pour cette emote.
//
// Double vérification :
//   - statusCode 2xx — élimine 404/403/5xx etc. tout en acceptant un éventuel
//     206 renvoyé par un CDN intermédiaire.
//   - signature de fichier WebP ("RIFF" + "WEBP" à l'offset 8) — élimine tout
//     corps de réponse qui ne serait pas un vrai WebP (page d'erreur, JSON,
//     HTML), même si le CDN renvoyait par erreur un statusCode 200.
static BOOL SevenTVIsValidWebPResponse(NSURLResponse *response, NSData *data) {
    if (!data || data.length < 12) return NO;

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status >= 300) return NO;
    }

    // Format RIFF : 4 octets "RIFF" + 4 octets taille (ignorés) + 4 octets "WEBP".
    const char *bytes = (const char *)data.bytes;
    BOOL hasRIFF = (memcmp(bytes, "RIFF", 4) == 0);
    BOOL hasWEBP = (memcmp(bytes + 8, "WEBP", 4) == 0);
    return hasRIFF && hasWEBP;
}

// BTTV and FFZ can return PNG/GIF as well as WebP.  The cache counter must
// validate the payload generically instead of reusing the 7TV-only RIFF/WebP
// check above, otherwise perfectly valid third-party emotes would still be
// reported as missing.
static BOOL SevenTVIsValidCachedImageResponse(NSURLResponse *response, NSData *data) {
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

// A descriptor can appear in several picker sections (for example a shared
// BTTV emote).  Collapse all scale URLs to one provider/id identity so the
// displayed value is an emote count, not a count of downloaded resolutions.
static NSString *SevenTVCacheIdentityForImageURL(NSURL *url) {
    if (!url) return nil;
    NSString *host = url.host.lowercaseString;
    if (!host.length) return nil;

    NSString *provider = nil;
    if ([host isEqualToString:@"cdn.7tv.app"] || [host hasSuffix:@".7tv.app"] ||
        [host isEqualToString:@"cdn.7tv.io"] || [host hasSuffix:@".7tv.io"]) {
        provider = @"7tv";
    } else if ([host isEqualToString:@"cdn.betterttv.net"] ||
               [host hasSuffix:@".betterttv.net"]) {
        provider = @"bttv";
    } else if ([host isEqualToString:@"cdn.frankerfacez.com"] ||
               [host hasSuffix:@".frankerfacez.com"]) {
        provider = @"ffz";
    }
    // Le compteur ne doit jamais inclure une requête sans identité provider :
    // cette classe ne gère que les CDN d'emotes connus.
    if (!provider) return nil;

    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger markerIndex = NSNotFound;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i].lowercaseString;
        if ([part isEqualToString:@"emote"] || [part isEqualToString:@"emoticon"]) {
            markerIndex = i;
            break;
        }
    }
    if (markerIndex != NSNotFound && markerIndex + 1 < parts.count) {
        NSString *emoteID = parts[markerIndex + 1];
        if (emoteID.length && ![emoteID isEqualToString:@"/"])
            return [NSString stringWithFormat:@"%@:%@", provider, emoteID];
    }
    return nil;
}

// ── Compteur global des emotes mises en cache (WebP natif, plus de conversion) ──
static _Atomic(NSInteger) s_cachedCount = 0;
static NSMutableSet<NSString *> *s_cachedEmoteIDs = nil;
static dispatch_once_t s_cachedEmoteIDsOnce;
static NSMutableSet<NSString *> *s_cachedEmoteIdentities = nil;
static dispatch_once_t s_cachedEmoteIdentitiesOnce;
static BOOL s_cacheIndexSaveScheduled = NO;
static NSString *const kS7TVCachedEmoteIDsKey = @"s7tv_cached_emote_ids";
static NSString *const kS7TVCachedEmoteIdentitiesKey = @"s7tv_cached_emote_identities";

static NSMutableSet<NSString *> *SevenTVCachedEmoteIdentities(void) {
    dispatch_once(&s_cachedEmoteIdentitiesOnce, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults]
            arrayForKey:kS7TVCachedEmoteIdentitiesKey] ?: @[];
        s_cachedEmoteIdentities = [NSMutableSet set];
        for (id value in saved) {
            if ([value isKindOfClass:NSString.class] &&
                [value rangeOfString:@":"].location != NSNotFound) {
                [s_cachedEmoteIdentities addObject:value];
            }
        }
    });
    return s_cachedEmoteIdentities;
}

static NSMutableSet<NSString *> *SevenTVCachedEmoteIDs(void) {
    dispatch_once(&s_cachedEmoteIDsOnce, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults]
            arrayForKey:kS7TVCachedEmoteIDsKey] ?: @[];
        s_cachedEmoteIDs = [NSMutableSet setWithArray:saved];
        // Migrate the old bare 7TV IDs into the provider-aware index. Keep the
        // legacy set as well for older exports.
        NSMutableSet *identities = SevenTVCachedEmoteIdentities();
        for (id value in s_cachedEmoteIDs) {
            if ([value isKindOfClass:NSString.class] && [value length])
                [identities addObject:[NSString stringWithFormat:@"7tv:%@", value]];
        }
        s_cachedCount = (NSInteger)identities.count;
    });
    return s_cachedEmoteIDs;
}

static BOOL SevenTVAnyCachedResolutionForEmoteID(NSString *emoteID) {
    if (!emoteID.length) return NO;
    for (NSInteger scale = 1; scale <= 4; scale++) {
        NSString *urlString = [NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)scale];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) continue;
        NSCachedURLResponse *cached = [SevenTVGetSharedCache()
            cachedResponseForRequest:[NSURLRequest requestWithURL:url]];
        if (cached && SevenTVIsValidWebPResponse(cached.response, cached.data))
            return YES;
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
        NSArray *identitySnapshot = nil;
        @synchronized (SevenTVCachedEmoteIDs()) {
            snapshot = SevenTVCachedEmoteIDs().allObjects;
            @synchronized (SevenTVCachedEmoteIdentities()) {
                identitySnapshot = SevenTVCachedEmoteIdentities().allObjects;
            }
            s_cacheIndexSaveScheduled = NO;
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:snapshot forKey:kS7TVCachedEmoteIDsKey];
        [defaults setObject:identitySnapshot forKey:kS7TVCachedEmoteIdentitiesKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:S7TVEmoteCacheCountDidChangeNotification object:nil];
        });
    });
}


@implementation SevenTVURLProtocol

+ (NSInteger)cachedEmoteCount {
    SevenTVCachedEmoteIDs();
    SevenTVCachedEmoteIdentities();
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
            @synchronized (SevenTVCachedEmoteIdentities()) {
                for (NSString *emoteID in missing) {
                    [SevenTVCachedEmoteIdentities()
                        removeObject:[NSString stringWithFormat:@"7tv:%@", emoteID]];
                }
                s_cachedCount = (NSInteger)SevenTVCachedEmoteIdentities().count;
            }
            count = s_cachedCount;
        }
        if (missing.count) SevenTVScheduleCacheIndexSave();
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(count); });
    });
}

+ (void)refreshCachedEmoteCountForImageURLs:(NSArray<NSURL *> *)imageURLs
                                 completion:(void (^)(NSInteger))completion {
    // Copy and de-duplicate before leaving the caller's thread.  The catalog
    // can expose the same provider/id in multiple sections, and the picker
    // may still be updating its snapshots while Settings appears.
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];
    for (id value in imageURLs ?: @[]) {
        NSURL *url = [value isKindOfClass:NSURL.class] ? value : nil;
        NSString *key = url.absoluteString;
        if (!key.length || [seenURLs containsObject:key]) continue;
        [seenURLs addObject:key];
        [urls addObject:url];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableSet<NSString *> *cachedIdentities = [NSMutableSet set];
        // Do not replace the persistent index with only the URLs visible in
        // the current catalogue. A channel can have changed since those
        // images were cached, and doing so was the reason the Settings row
        // reported only a small fraction of the real cache.
        @synchronized (SevenTVCachedEmoteIdentities()) {
            [cachedIdentities unionSet:SevenTVCachedEmoteIdentities()];
        }
        NSURLCache *cache = SevenTVGetSharedCache();
        for (NSURL *url in urls) {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            request.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
            NSCachedURLResponse *cached = [cache cachedResponseForRequest:request];
            if (!cached || !SevenTVIsValidCachedImageResponse(cached.response, cached.data))
                continue;

            NSString *identity = SevenTVCacheIdentityForImageURL(url);
            if (identity.length) [cachedIdentities addObject:identity];
        }
        BOOL changed = NO;
        @synchronized (SevenTVCachedEmoteIdentities()) {
            for (NSString *identity in cachedIdentities) {
                if (![SevenTVCachedEmoteIdentities() containsObject:identity]) {
                    [SevenTVCachedEmoteIdentities() addObject:identity];
                    changed = YES;
                }
            }
            s_cachedCount = (NSInteger)SevenTVCachedEmoteIdentities().count;
        }
        if (changed) SevenTVScheduleCacheIndexSave();
        NSInteger count = s_cachedCount;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(count);
            });
        }
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
        NSString *identity = [NSString stringWithFormat:@"7tv:%@", emoteID];
        @synchronized (SevenTVCachedEmoteIdentities()) {
            if (![SevenTVCachedEmoteIdentities() containsObject:identity]) {
                [SevenTVCachedEmoteIdentities() addObject:identity];
                added = YES;
            }
            s_cachedCount = (NSInteger)SevenTVCachedEmoteIdentities().count;
        }
    }
    if (added) SevenTVScheduleCacheIndexSave();
}

+ (void)noteCachedEmoteImageURL:(NSURL *)url {
    NSString *identity = SevenTVCacheIdentityForImageURL(url);
    if (!identity.length) return;

    BOOL added = NO;
    // Keep the same lock order as noteCachedEmoteID:/clearAll... (legacy IDs
    // first, provider identities second) so concurrent image callbacks cannot
    // deadlock while updating the two indexes.
    @synchronized (SevenTVCachedEmoteIDs()) {
        @synchronized (SevenTVCachedEmoteIdentities()) {
            if (![SevenTVCachedEmoteIdentities() containsObject:identity]) {
                [SevenTVCachedEmoteIdentities() addObject:identity];
                added = YES;
            }

            // Keep the historical 7TV-only index in sync for old callers and
            // old exports. BTTV/FFZ are intentionally not inserted into that
            // bare-ID set.
            if ([identity hasPrefix:@"7tv:"]) {
                NSString *emoteID = [identity substringFromIndex:5];
                if (emoteID.length &&
                    ![SevenTVCachedEmoteIDs() containsObject:emoteID]) {
                    [SevenTVCachedEmoteIDs() addObject:emoteID];
                    added = YES;
                }
            }
            s_cachedCount = (NSInteger)SevenTVCachedEmoteIdentities().count;
        }
    }
    if (added) SevenTVScheduleCacheIndexSave();
}

// ============================================================
// MARK: - Cache partagé (accessible depuis SevenTVManager pour le picker)
// ============================================================

+ (NSURLCache *)sharedEmoteCache {
    return SevenTVGetSharedCache();
}

+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger))completion {
    NSUInteger clearedCount = (NSUInteger)[self cachedEmoteCount];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [SevenTVGetSharedCache() removeAllCachedResponses];
        @synchronized (SevenTVCachedEmoteIDs()) {
            [SevenTVCachedEmoteIDs() removeAllObjects];
            @synchronized (SevenTVCachedEmoteIdentities()) {
                [SevenTVCachedEmoteIdentities() removeAllObjects];
                s_cachedCount = 0;
            }
            s_cacheIndexSaveScheduled = NO;
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kS7TVCachedEmoteIDsKey];
        [[NSUserDefaults standardUserDefaults]
            removeObjectForKey:kS7TVCachedEmoteIdentitiesKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:S7TVEmoteCacheCountDidChangeNotification object:nil];
            if (completion) completion(clearedCount);
        });
    });
}

@end
