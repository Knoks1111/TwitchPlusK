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

// Résultat du décodage WebP animé complet (toutes les frames, pas juste la
// 1ère) — voir SevenTVEmoteAnimationEngine pour la lecture/synchro de ces
// frames à l'affichage. images.count == durations.count, même index.
@interface S7TVEmoteAnimatedFrames : NSObject
@property (nonatomic, copy) NSArray<UIImage *> *images;
// Durée de chaque frame en secondes (index correspondant à images) — issue
// des métadonnées WebP (delay time), 0.1s de filet de sécurité si absente.
@property (nonatomic, copy) NSArray<NSNumber *> *durations;
@end


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

// --- Animation (Phase 2 — décodage WebP animé natif) ---
//
// Ne s'applique qu'aux emotes avec emote.isAnimated == YES ; retourne nil
// immédiatement pour une emote statique (utiliser imageForResolvedEmote:
// dans ce cas). Le décodage de TOUTES les frames se fait hors thread
// principal (ImageIO), jamais pendant le scroll — voir exigence transverse
// #3 du plan chat-twitch-custom.
//
// Cache-first, synchrone, main thread — même rôle que
// cachedImageForResolvedEmote: pour le chemin statique : évite un
// round-trip async inutile quand les frames sont déjà décodées (ex: emote
// déjà vue plus haut dans le même chat).
- (nullable S7TVEmoteAnimatedFrames *)cachedFramesForResolvedEmote:(id<S7TVResolvedEmote>)emote;

// completion appelé une fois sur le main thread : frames si le décodage a
// réussi (WebP animé valide, ≥1 frame), nil sinon (réseau, décodage échoué,
// ou emote non animée) — l'appelant garde alors le fallback statique déjà
// affiché (voir S7TVAnimatedEmoteAttachment.staticFallbackImage).
- (void)framesForResolvedEmote:(id<S7TVResolvedEmote>)emote
                     completion:(void (^)(S7TVEmoteAnimatedFrames * _Nullable frames))completion;

@end

NS_ASSUME_NONNULL_END
