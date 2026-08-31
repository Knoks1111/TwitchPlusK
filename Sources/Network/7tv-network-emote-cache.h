/*
 * 7tv-network-emote-cache.h
 *
 * Utilitaire de cache/téléchargement des images d'emotes 7TV (CDN → cache
 * disque partagé). Le nom "URLProtocol" est un résidu historique : cette
 * classe n'intercepte plus aucune requête Twitch (l'ancien mécanisme
 * reposait sur un faux ID "7tv_" injecté dans les messages IRC — injection
 * retirée, donc interception définitivement morte). Elle sert maintenant
 * uniquement de cache d'images partagé par le renderer multi-provider, le
 * picker et l'écran de diagnostics.
 *
 * Format servi : WebP natif tel que fourni par le CDN 7TV (animé ou
 * statique) — aucune conversion en GIF.
 */

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const S7TVEmoteCacheCountDidChangeNotification;

@interface SevenTVURLProtocol : NSObject

// Cache partagé par le renderer, le picker et les diagnostics.
+ (NSURLCache *)sharedEmoteCache;

// Enregistre une écriture 7TV faite par un autre pipeline (chat/picker) dans
// le cache partagé, afin que le compteur reste exact.
+ (void)noteCachedEmoteID:(NSString *)emoteID;

// Variante provider-aware utilisée par le renderer commun. Les URLs BTTV et
// FFZ sont enregistrées dans le même index que les URLs 7TV, avec une identité
// stable « provider:id ».
+ (void)noteCachedEmoteImageURL:(NSURL *)url;

// Nombre actuel d'emotes présentes dans le cache d'images partagé (7TV, BTTV
// et FFZ), chaque emote étant comptée une seule fois quelle que soit sa
// résolution ou le nombre de sections qui la référence.
+ (NSInteger)cachedEmoteCount;
+ (void)refreshCachedEmoteCountWithCompletion:(void (^)(NSInteger count))completion;
// Recalcule le nombre d'emotes réellement présentes dans le cache HTTP à
// partir des URLs connues du catalogue (7TV, BTTV et FFZ). Le scan est
// asynchrone afin de ne jamais bloquer l'interface des réglages.
+ (void)refreshCachedEmoteCountForImageURLs:(NSArray<NSURL *> *)imageURLs
                                 completion:(void (^)(NSInteger count))completion;

// Vide entièrement le NSURLCache dédié (mémoire + disque) et son index
// provider-aware. Les téléchargements actifs sont invalidés par
// SevenTVEmoteImageCache avant cet appel.
+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger clearedCount))completion;

@end
