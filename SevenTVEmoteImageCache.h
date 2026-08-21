/*
 * SevenTVEmoteImageCache.h
 *
 * Décodage + cache des images d'emotes (Phase 2 du plan chat-twitch-custom).
 * Tout le travail (réseau + décodage WebP) se fait hors thread principal
 * (exigence transverse #3). Dé-doublonne les requêtes concurrentes pour la
 * même URL — important avec le cell reuse (plusieurs cellules peuvent
 * demander la même emote très fréquente au même moment en scroll rapide).
 *
 * Le chemin statique décompresse uniquement la première frame. Le chemin
 * animé décode toutes les frames sur une file bornée ; l'activation réelle
 * reste pilotée par SevenTVEmoteAnimationEngine selon la visibilité.
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

// Suspend les opérations de décodage encore en attente. Le picker l'utilise
// pendant un drag/deceleration afin que ImageIO ne dispute pas les cœurs CPU
// au scroll ; les opérations déjà terminées restent naturellement en cache.
- (void)setDecodingSuspended:(BOOL)suspended;

// Vide les images statiques, frames animées et travaux en attente. Les
// callbacks déjà inscrits sont terminés avec nil sur le main thread.
- (void)clearAllCaches;

@end

NS_ASSUME_NONNULL_END
