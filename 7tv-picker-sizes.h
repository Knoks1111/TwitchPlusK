/*
 * 7tv-picker-sizes.h
 *
 * Panneau des réglages visuels du chat affiché par-dessus la grille du
 * picker quand on tape sur le bouton ⚙️. Les options sont regroupées en
 * trois catégories (Tailles / Apparence / Modération), avec aperçu live.
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
@class SevenTVChatCustomView;
@class S7TVChatMessageStore;

@interface SevenTVPickerSizesPanel : NSObject

// Référence faible vers le picker hôte (voir note ci-dessus).
@property (nonatomic, weak) SevenTVEmotePickerController *picker;

// Vue racine du panneau, avec trois catégories (Tailles / Apparence /
// Modération) contenant chacune leur propre UIScrollView.
// Le picker en gère lui-même le hidden/frame (visibilité + redimensionnement).
@property (nonatomic, weak, readonly) UIView *panelView;

// Hauteur du panneau catégorisé, utilisée par le
// picker pour adapter sa propre hauteur quand le panneau est affiché.
@property (nonatomic, assign, readonly) CGFloat contentHeight;

// Faux chat (preview live 1:1, 5 messages factices) — construit par
// -buildInView:... mais volontairement PAS attaché à panelView : le panneau
// est l'inputView du clavier et ne peut pas héberger un aperçu positionné
// librement au milieu de l'écran. C'est au picker de poser fakeChatView dans
// sa fenêtre flottante (au-dessus du champ de saisie) et de gérer son frame,
// sa visibilité, et son cycle de vie (afficher/masquer avec le panneau).
@property (nonatomic, strong, readonly) SevenTVChatCustomView *fakeChatView;
@property (nonatomic, strong, readonly) S7TVChatMessageStore *fakeChatStore;

// Construit les trois catégories dans `container`, avec le style transmis par le picker
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
