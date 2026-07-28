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

// Nombre total d'emotes mises en cache (WebP natif) depuis le démarrage.
// Utilisé par SevenTVManager pour le log bilan de fin de prefetch.
+ (NSInteger)cachedEmoteCount;

@end
