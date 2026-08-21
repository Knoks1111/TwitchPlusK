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

// Résultat d'un décodage WebP animé, preview légère ou boucle complète — voir
// SevenTVEmoteAnimationEngine pour la lecture/synchro de ces frames à
// l'affichage. images.count == durations.count, même index.
@interface S7TVEmoteAnimatedFrames : NSObject
@property (nonatomic, copy) NSArray<UIImage *> *images;
// Durée de chaque frame en secondes (index correspondant à images) — issue
// des métadonnées WebP (delay time), 0.1s de filet de sécurité si absente.
@property (nonatomic, copy) NSArray<NSNumber *> *durations;
// YES uniquement pour la petite boucle rapidement décodée par le picker.
// Une preview est immédiatement affichable, mais ne doit jamais empêcher le
// décodage de la boucle complète ni remplacer celle-ci si elle est déjà prête.
@property (nonatomic, assign, getter=isPreview) BOOL preview;
@end

// Jeton d'une demande de frames liée à une vue. Le picker l'annule dès que
// sa cellule quitte l'écran ; le téléchargement peut rester partagé avec le
// chemin statique, mais aucun décodage animé inutile n'est alors poursuivi.
@interface S7TVEmoteFrameRequest : NSObject
- (void)cancel;
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
// dans ce cas). Le décodage se fait hors thread principal (ImageIO). Les
// previews prioritaires du picker et les boucles complètes utilisent deux
// files distinctes afin qu'une longue animation ne bloque pas les suivantes.
//
// Cache-first, synchrone, main thread — même rôle que
// cachedImageForResolvedEmote: pour le chemin statique : évite un
// round-trip async inutile quand les frames sont déjà décodées (ex: emote
// déjà vue plus haut dans le même chat).
- (nullable S7TVEmoteAnimatedFrames *)cachedFramesForResolvedEmote:(id<S7TVResolvedEmote>)emote;

// Demande annulable utilisée par toute cellule visible (chat et picker).
// preview reçoit rapidement une boucle légère ; completion reçoit ensuite la
// boucle complète. Les deux callbacks s'exécutent sur le main thread et ne
// sont plus appelés après cancel.
- (S7TVEmoteFrameRequest *)framesForResolvedEmote:(id<S7TVResolvedEmote>)emote
                                          preview:(void (^ _Nullable)(S7TVEmoteAnimatedFrames *frames))preview
                                       completion:(void (^)(S7TVEmoteAnimatedFrames * _Nullable frames))completion;

// Suspend exceptionnellement les opérations de décodage encore en attente.
// Le picker ne gèle plus ces files pendant le scroll : ses cellules filtrent
// elles-mêmes les travaux selon leur visibilité, ce qui permet aux miniatures
// visibles et aux animations du chat de continuer à progresser.
- (void)setDecodingSuspended:(BOOL)suspended;

// Conserve les files de preview et de décodage bornées pendant le scroll.
// Les previews annulables continuent afin que chaque cellule visible s'anime.
- (void)setScrollingPerformanceMode:(BOOL)enabled;

// Vide les images statiques, frames animées et travaux en attente. Les
// callbacks déjà inscrits sont terminés avec nil sur le main thread.
- (void)clearAllCaches;

@end

NS_ASSUME_NONNULL_END
