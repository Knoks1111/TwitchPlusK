/*
 * 7tv-picker-cell.h
 * Cellule de la grille du picker d'emotes.
 *
 * Extrait de SevenTVManager.m (nettoyage picker) — classe déjà autonome à
 * l'origine, ne dépend d'aucun état privé de SevenTVManager.
 */

#import <UIKit/UIKit.h>

// ============================================================
// Cellule dédiée du picker — remplace le UICollectionViewCell générique
// utilisé jusqu'ici. L'UIImageView et l'étoile favoris sont créés UNE SEULE
// FOIS ici (dans -initWithFrame:), jamais recréés à chaque dequeue : sur
// l'ancienne version, cellForItemAtIndexPath: retirait puis reconstruisait
// tous les subviews à chaque réapparition de cellule pendant le scroll,
// ajoutant de l'alloc/dealloc pour rien. Ici, prepareForReuse: se contente
// de vider l'image et de se désinscrire de l'engine d'animation.
// ============================================================
@interface S7TVEmotePickerCell : UICollectionViewCell
@property (nonatomic, strong, readonly) UIImageView *emoteImageView;
@property (nonatomic, strong, readonly) UIImageView *favoriteStarView;
// Clé (URL absolue) de l'emote actuellement affichée par cette cellule.
// Sert à valider qu'un callback asynchrone arrivant après un recyclage
// concerne toujours la bonne emote avant d'appliquer une image/frame.
@property (nonatomic, copy) NSString *currentEmoteKey;
@end
