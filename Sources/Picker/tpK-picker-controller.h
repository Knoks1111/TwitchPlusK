/*
 * tpK-picker-controller.h
 *
 * Picker d'emotes 7TV affiché au-dessus de la barre de saisie Twitch quand
 * l'utilisateur tape sur le bouton 7TV intégré dans la barre. Grille de
 * cellules (2 onglets : Favoris / 7TV) + barre de recherche + panneau des
 * tailles (voir TPKPickerSizesPanel, composant enfant).
 *
 * Entièrement indépendant du picker natif de Twitch : aucune catégorie,
 * aucune donnée, aucune logique de navigation liée aux emotes natives Twitch.
 *
 * Composant de TPKManager : lit les données d'emotes/favoris via
 * [TPKManager sharedManager] mais gère lui-même toute son UI. Instancié
 * paresseusement par TPKManager, qui garde les deux méthodes publiques
 * ci-dessous comme façade (aucun changement côté appelant / tpK-core-runtime-hooks.m).
 *
 * Extrait de tpK-core-manager.m (nettoyage picker).
 */

#import <UIKit/UIKit.h>

@class TPKPickerSizesPanel;
@class TPKEmote;

void tpk_handleChatTrayButtonLifecycle(UIView *view);
BOOL TPKPickerChatButtonReady(void);

@interface TPKEmotePickerController : NSObject <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>

// --- Affichage / fermeture (façade appelée par TPKManager) ------------
- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;
- (void)cleanupPickerForStreamClose;
- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView;

// --- Listes filtrées exposées pour TPKPickerSizesPanel -----------------
// (choix des emotes de preview : EZ en priorité, sinon 1ère globale)
@property (nonatomic, strong, readonly) NSArray<TPKEmote *> *emotePickerAllEmotes;
@property (nonatomic, strong, readonly) NSArray<TPKEmote *> *emotePickerGlobalEmotes;

// --- Pipeline réseau/décodage image partagé, réutilisé par TPKPickerSizesPanel ---
// (session persistante + décodage forcé hors thread principal ; voir le .m
// pour le détail — ce pipeline sert uniquement aux 3 previews du panneau des
// tailles, la grille elle-même passe par TPKEmoteImageCache/AnimationEngine)
- (NSURLSession *)pickerImageSession;
- (UIImage *)decodePickerImageData:(NSData *)data wantsAnimated:(BOOL)wantsAnimated;

// --- Panneau des tailles (toggle du bouton ⚙️, appelle TPKPickerSizesPanel) ---
- (void)emotePickerSizesToggleTapped;

// Taille de la fenêtre qui héberge le picker.
- (CGSize)pickerHostSize;

// Orientation courante. UIScreen plutôt que la fenêtre : après une rotation,
// window.bounds a une passe de layout de retard et renverrait l'ancienne.
- (BOOL)pickerHostIsLandscape;

// Appliqué par le panneau ⚙️, qui n'a pas accès à l'inputView du clavier.
- (void)pickerSizePreferenceDidChange;

// --- Cache de tri interne, invalidé par TPKManager quand le catalogue
// d'emotes change (nouveau channel, refresh global/channel) pour que le
// picker retrie au prochain affichage. ---
- (void)invalidateSortCache;

// Recalcule immédiatement l'onglet Favoris après un import/suppression dans
// les réglages, sans recréer le picker ni relancer l'application.
- (void)favoritesDidChange;

// Annule les chargements des previews du panneau de réglages avant un
// vidage complet du cache partagé.
- (void)cancelPendingImageLoadsWithCompletion:(void (^)(void))completion;

@end
