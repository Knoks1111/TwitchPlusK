/*
 * SevenTVEmoteAnimationEngine.h
 *
 * Moteur d'animation partagé pour les emotes 7TV animées (Phase 2 —
 * décodage WebP animé natif, voir SevenTVEmoteImageCache pour le décodage).
 *
 * UN SEUL CADisplayLink pour toute l'app fait avancer une frame courante PAR
 * EMOTE (clé = URL CDN résolue, identique à celle utilisée par
 * SevenTVEmoteImageCache) — voir plan §Phase 2 "synchronisation des frames
 * entre instances d'une même emote" : si "KEKW" apparaît 20 fois à l'écran,
 * les 20 occurrences lisent la même frame courante au lieu que chacune
 * décode/anime dans son coin (gaspillage CPU + désynchro visuelle).
 *
 * THROTTLE intégré (plan §Phase 2 "throttle du nombre d'animations
 * simultanées") : au-delà de maxSimultaneousAnimations clés actives en même
 * temps, les plus anciennes (visibles en continu depuis le plus longtemps)
 * arrêtent d'avancer — frame figée, mais toujours affichée, jamais retirée.
 *
 * VISIBILITÉ / CELL REUSE (plan §Phase 2) : ce moteur n'anime QUE les clés
 * explicitement enregistrées via addObserver:keys:redraw: (appelé depuis
 * willDisplayCell) et les retire via removeObserver: (depuis
 * didEndDisplayingCell) — voir SevenTVChatCustomView. Le CADisplayLink lui
 * -même n'est actif que s'il existe au moins un observateur ; sinon
 * invalidé, coût nul quand aucune emote animée n'est à l'écran.
 *
 * Usage exclusivement main thread — comme CADisplayLink lui-même, et comme
 * tout le reste du pipeline de rendu (UIKit).
 */

#import <UIKit/UIKit.h>
#import "SevenTVEmoteImageCache.h"

NS_ASSUME_NONNULL_BEGIN

@interface SevenTVEmoteAnimationEngine : NSObject

+ (instancetype)sharedEngine;

// Nombre max de clés (emotes distinctes) animées activement en simultané.
// Au-delà, les plus anciennes à l'écran gèlent (voir commentaire de fichier).
// Pas encore dans SevenTVChatAppearanceConfig (ce n'est pas une taille
// visuelle, voir exigence transverse #1 du plan) — réglable directement ici.
@property (nonatomic, assign) NSInteger maxSimultaneousAnimations; // défaut 128

// À appeler dès que les frames décodées d'une emote sont prêtes
// (SevenTVEmoteImageCache ne le fait pas lui-même — c'est à l'appelant du
// décodage, typiquement le renderer, de brancher les deux). Écrase toute
// entrée existante pour la clé et redémarre son cycle d'animation à la
// frame 0.
- (void)registerFrames:(S7TVEmoteAnimatedFrames *)frames forKey:(NSString *)key;

// YES si des frames sont déjà enregistrées pour cette clé — permet à
// l'appelant d'éviter de redéclencher un décodage déjà fait (voir
// SevenTVChatCustomView.s7tv_cellForMessageID:).
- (BOOL)hasFramesForKey:(NSString *)key;

// Contrairement à hasFramesForKey:, retourne NO si le moteur ne possède
// encore qu'une preview courte. Les renderers peuvent ainsi l'afficher tout
// de suite tout en poursuivant le décodage complet en arrière-plan.
- (BOOL)hasCompleteFramesForKey:(NSString *)key;

// Frame courante pour une clé, ou nil si pas encore décodée / clé inconnue
// — l'appelant garde alors son fallback statique (voir
// S7TVAnimatedEmoteAttachment.staticFallbackImage).
- (nullable UIImage *)currentFrameForKey:(NSString *)key;

// observer : typiquement le UILabel de la cellule qui affiche le/les
// emote(s) — identité par référence, jamais copié. keys : toutes les clés
// d'animation présentes dans le message actuellement affiché par cet
// observateur. redraw : appelé sur le main thread uniquement quand au moins
// une de ces clés a réellement avancé de frame (jamais pour une clé gelée
// par le throttle) — à l'appelant de faire son propre setNeedsDisplay.
//
// Remplace silencieusement tout enregistrement précédent du même
// observateur (voir removeObserver: pour le nettoyage explicite recommandé
// avant un ré-enregistrement, ex: cell reuse).
- (void)addObserver:(id)observer
               keys:(NSSet<NSString *> *)keys
             redraw:(void (^)(void))redraw;

// Retire TOUTES les clés associées à cet observateur. À appeler dans
// didEndDisplayingCell (visibilité réelle) ET avant tout ré-enregistrement
// en willDisplayCell (cell reuse) — voir SevenTVChatCustomView.
- (void)removeObserver:(id)observer;

// Signale le scroll du picker. Les cellules hors écran restent retirées par
// leurs callbacks de visibilité ; aucune emote encore visible n'est gelée.
// La concurrence du décodage est ajustée séparément par le cache d'images.
- (void)setScrollingPerformanceMode:(BOOL)enabled;

// Retire toutes les frames décodées et arrête immédiatement les animations.
- (void)clearAllCachedFrames;

@end


// Attachment texte dont l'image affichée est recalculée à CHAQUE passage de
// dessin — TextKit appelle -imageForBounds:textContainer:characterIndex:
// (pas juste .image, qui lui est figé une fois assigné) à chaque
// (re)affichage du label, y compris pour un UILabel. C'est ce qui permet à
// un simple UILabel (pas de UIImageView dédiée par occurrence d'emote)
// d'afficher une image qui change dans le temps : on lit la frame courante
// du moteur partagé au moment du dessin, sans jamais reconstruire
// l'attributed string du message à chaque tick.
@interface S7TVAnimatedEmoteAttachment : NSTextAttachment

// Clé identique à celle utilisée par SevenTVEmoteImageCache/
// SevenTVEmoteAnimationEngine (emote.imageURL.absoluteString).
@property (nonatomic, copy) NSString *animationKey;

// Image affichée tant que le moteur n'a pas encore de frame pour cette clé
// (décodage animé pas terminé) — le fallback statique déjà en cache (voir
// s7tv_buildAttributedStringForMessage:), jamais un glyphe de remplacement
// vide une fois qu'on a déjà quelque chose à montrer.
@property (nonatomic, strong, nullable) UIImage *staticFallbackImage;

@end

NS_ASSUME_NONNULL_END
