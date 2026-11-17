/*
 * tpK-picker-cell.h
 * Cellule de la grille d'emotes.
 *
 * Extrait de tpK-core-manager.m lors du nettoyage du picker.
 */

#import <UIKit/UIKit.h>

@class TPKEmoteFrameRequest;

// La cellule conserve ses vues et les vide dans prepareForReuse:.
@interface TPKEmotePickerCell : UICollectionViewCell
@property (nonatomic, strong, readonly) UIImageView *emoteImageView;
@property (nonatomic, strong, readonly) UIImageView *favoriteStarView;
// Indique le fournisseur dans les favoris agrégés.
@property (nonatomic, strong, readonly) UILabel *providerBadgeLabel;
// Clé de l'emote affichée, vérifiée avant d'appliquer un callback asynchrone.
@property (nonatomic, copy) NSString *currentEmoteKey;
// L'animation tourne uniquement pendant l'affichage de la cellule.
@property (nonatomic, assign) BOOL wantsAnimation;
@property (nonatomic, assign) NSUInteger imageLoadGeneration;
// Invalide les activations et callbacks après fermeture ou réutilisation.
@property (nonatomic, assign) NSUInteger animationGeneration;
// Requête de décodage annulée quand la cellule quitte l'écran ou est recyclée.
@property (nonatomic, strong) TPKEmoteFrameRequest *animationFrameRequest;

// Applique la palette courante à la carte et à sa bordure.
- (void)tpk_applyOLEDColors;
- (void)resetContent;
@end
