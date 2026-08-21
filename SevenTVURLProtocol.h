/*
 * SevenTVURLProtocol.h
 *
 * Utilitaire de cache/téléchargement des images d'emotes 7TV (CDN → cache
 * disque partagé). Le nom "URLProtocol" est un résidu historique : cette
 * classe n'intercepte plus aucune requête Twitch (l'ancien mécanisme
 * reposait sur un faux ID "7tv_" injecté dans les messages IRC — injection
 * retirée, donc interception définitivement morte). Elle sert maintenant
 * uniquement d'utilitaire appelé directement par SevenTVManager (prefetch
 * au join de channel) et par le picker (lecture directe du cache).
 *
 * Format servi : WebP natif tel que fourni par le CDN 7TV (animé ou
 * statique) — aucune conversion en GIF.
 */

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const S7TVEmoteCacheCountDidChangeNotification;

@interface SevenTVURLProtocol : NSObject

// Préchauffage TCP/TLS vers cdn.7tv.app au JOIN d'un channel.
+ (void)prewarmCDNConnection;

// Vérifie si l'image d'une emote est déjà dans le cache NSURLCache.
// Thread-safe. Retourne YES immédiatement si en cache, NO sinon.
+ (BOOL)isEmoteIDCached:(NSString *)emoteID;

// Télécharge l'image d'une emote et la stocke dans le cache partagé.
// completion est appelé quand l'image est en cache (ou après 1s de timeout).
// Si l'image est déjà en cache, completion est appelé immédiatement.
+ (void)prefetchEmoteID:(NSString *)emoteID completion:(void(^)(void))completion;

// Cache partagé entre le prefetch (join de channel) et le picker.
// Une emote préfetchée est immédiatement disponible dans le picker sans
// aucun réseau supplémentaire.
+ (NSURLCache *)sharedEmoteCache;

// Enregistre une écriture faite par un autre pipeline (chat/picker) dans le
// cache partagé, afin que le compteur reste exact.
+ (void)noteCachedEmoteID:(NSString *)emoteID;

// Nombre actuel d'emotes encore présentes dans le cache WebP natif.
+ (NSInteger)cachedEmoteCount;
+ (void)refreshCachedEmoteCountWithCompletion:(void (^)(NSInteger count))completion;

// Annule les téléchargements CDN en cours et vide entièrement le NSURLCache
// dédié (mémoire + disque). Les requêtes terminées après l'appel ne peuvent
// pas repeupler le cache grâce à une génération d'invalidation.
+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger clearedCount))completion;

@end
