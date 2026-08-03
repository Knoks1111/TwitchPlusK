/*
 * 7tv-picker-sizes.h
 *
 * Panneau des 5 tailles (emotes 7TV, emotes Twitch, badges, texte pseudo,
 * texte message) affiché par-dessus la grille du picker quand on tape sur
 * le bouton ⚙️. Toutes les lignes sont empilées et réglables en même temps,
 * chacune avec son slider + une preview live à droite.
 *
 * Composant ENFANT de SevenTVEmotePickerController : ne gère pas sa propre
 * fenêtre/présentation, il dessine ses lignes dans la vue qu'on lui donne
 * (-buildInView:...) et référence son picker hôte pour :
 *   - lire les listes d'emotes déjà filtrées (emotePickerAllEmotes/GlobalEmotes)
 *     utilisées pour choisir les 2 emotes de preview
 *   - réutiliser la session réseau + le pipeline de décodage d'image partagés
 *     du picker (pickerImageSession / decodePickerImageData:wantsAnimated:)
 * La visibilité du panneau (afficher/masquer, redimensionner le picker) reste
 * de la responsabilité du picker lui-même (c'est du chrome du picker, pas une
 * donnée du panneau des tailles) — voir -[SevenTVEmotePickerController
 * emotePickerSizesToggleTapped].
 *
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import <UIKit/UIKit.h>

@class SevenTVEmotePickerController;

@interface SevenTVPickerSizesPanel : NSObject

// Référence faible vers le picker hôte (voir note ci-dessus).
@property (nonatomic, weak) SevenTVEmotePickerController *picker;

// Vue racine du panneau (UIScrollView), construite par -buildInView:...
// Le picker en gère lui-même le hidden/frame (visibilité + redimensionnement).
@property (nonatomic, weak, readonly) UIView *panelView;

// Hauteur réelle du contenu (5 lignes), utilisée par le picker pour adapter
// sa propre hauteur quand le panneau est affiché.
@property (nonatomic, assign, readonly) CGFloat contentHeight;

// Construit les 5 lignes (nom + slider + pastille valeur + bouton reset +
// preview live) dans `container`, avec le style visuel transmis par le picker
// (couleurs déjà résolues). Doit être appelé une seule fois, à la création
// du picker.
- (void)buildInView:(UIView *)container
              frame:(CGRect)frame
            bgColor:(UIColor *)bgColor
          textColor:(UIColor *)textColor
           subColor:(UIColor *)subColor
           sepColor:(UIColor *)sepColor
             accent:(UIColor *)accent
          cardColor:(UIColor *)cardColor;

// Précharge les 3 vraies images de preview (emote 7TV, emote Twitch native,
// badge) la première fois que le panneau est affiché — mises en cache dans
// les UIImageView elles-mêmes ensuite (pas de refetch aux ouvertures suivantes).
- (void)loadRealPreviewAssetsIfNeeded;

@end
