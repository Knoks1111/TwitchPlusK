/*
 * SevenTVURLProtocol.h
 *
 * Ce fichier intercepte les requêtes HTTP que Twitch fait pour charger
 * les images des emotes. Quand Twitch demande une image avec un ID
 * commençant par "7tv_", on redirige vers le vrai CDN de 7TV.
 *
 * Format servi : WebP natif tel que fourni par le CDN 7TV (animé ou
 * statique) — aucune conversion en GIF.
 */

#import <Foundation/Foundation.h>

@interface SevenTVURLProtocol : NSURLProtocol

// Préchauffage TCP/TLS vers cdn.7tv.app au JOIN d'un channel.
+ (void)prewarmCDNConnection;

// Vérifie si l'image d'une emote est déjà dans le cache NSURLCache.
// Thread-safe. Retourne YES immédiatement si en cache, NO sinon.
+ (BOOL)isEmoteIDCached:(NSString *)emoteID;

// Télécharge l'image d'une emote dans NSURLCache sans passer par URLProtocol.
// completion est appelé quand l'image est en cache (ou après 1s de timeout).
// Si l'image est déjà en cache, completion est appelé immédiatement.
+ (void)prefetchEmoteID:(NSString *)emoteID completion:(void(^)(void))completion;

// Cache partagé entre le chat (URLProtocol) et le picker.
// Utiliser ce cache dans SevenTVManager pour que les deux lisent/écrivent
// au même endroit — une emote vue dans le chat est immédiatement disponible
// dans le picker sans aucun réseau supplémentaire.
+ (NSURLCache *)sharedEmoteCache;

// Nombre total d'emotes mises en cache (WebP natif) depuis le démarrage.
// Utilisé par SevenTVManager pour le log bilan de fin de prefetch.
+ (NSInteger)cachedEmoteCount;

@end
