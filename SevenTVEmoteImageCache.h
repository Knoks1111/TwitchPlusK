/*
 * SevenTVEmoteImageCache.h
 *
 * Décodage + cache des images d'emotes (Phase 2 du plan chat-twitch-custom).
 * Tout le travail (réseau + décodage WebP) se fait hors thread principal
 * (exigence transverse #3). Dé-doublonne les requêtes concurrentes pour la
 * même URL — important avec le cell reuse (plusieurs cellules peuvent
 * demander la même emote très fréquente au même moment en scroll rapide).
 *
 * Décodage 1ère frame uniquement pour l'instant (rendu statique) — le
 * pipeline d'animation (démarrage/arrêt selon visibilité, throttle du nombre
 * d'animations simultanées) est un incrément Phase 2 séparé, pas encore fait.
 */

#import <UIKit/UIKit.h>
#import "SevenTVEmoteProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface SevenTVEmoteImageCache : NSObject

+ (instancetype)sharedCache;

// completion toujours appelé sur le main thread, y compris en cas d'échec
// (image nil) — exigence Phase 2 "cas d'échec réseau : fallback texte brut",
// géré côté appelant (le nom de l'emote reste affiché via S7TVChatToken.text
// tant que l'image n'a pas chargé, voir SevenTVChatCustomView).
// Accès synchrone, main thread — pour injecter directement l'image dans
// l'attachment au moment de la construction du texte quand elle est déjà
// décodée, sans passer par le round-trip async de imageForResolvedEmote:
// (qui, même sur un cache hit, repasse par le run loop et cause un flash
// vide perceptible à chaque scroll d'une emote pourtant déjà en mémoire).
- (nullable UIImage *)cachedImageForResolvedEmote:(id<S7TVResolvedEmote>)emote;

- (void)imageForResolvedEmote:(id<S7TVResolvedEmote>)emote
                    completion:(void (^)(UIImage * _Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
