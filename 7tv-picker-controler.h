/*
 * 7tv-picker-controler.h
 *
 * Picker d'emotes 7TV affiché au-dessus de la barre de saisie Twitch quand
 * l'utilisateur tape sur le bouton 7TV intégré dans la barre. Grille de
 * cellules (2 onglets : Favoris / 7TV) + barre de recherche + panneau des
 * tailles (voir SevenTVPickerSizesPanel, composant enfant).
 *
 * Entièrement indépendant du picker natif de Twitch : aucune catégorie,
 * aucune donnée, aucune logique de navigation liée aux emotes natives Twitch.
 *
 * Composant de SevenTVManager : lit les données d'emotes/favoris via
 * [SevenTVManager sharedManager] mais gère lui-même toute son UI. Instancié
 * paresseusement par SevenTVManager, qui garde les deux méthodes publiques
 * ci-dessous comme façade (aucun changement côté appelant / TweakSevenTV.m).
 *
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import <UIKit/UIKit.h>

@class SevenTVPickerSizesPanel;
@class SevenTVEmote;

// Point d'entrée du hook UIView.didMoveToWindow : initialise/nettoie le
// bouton 7TV uniquement lorsqu'une Twitch.ChatInputView change de fenêtre.
void s7tv_handleChatInputViewLifecycle(UIView *view);

@interface SevenTVEmotePickerController : NSObject <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>

// --- Affichage / fermeture (façade appelée par SevenTVManager) ------------
- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;
- (void)cleanupPickerForStreamClose;

// --- Listes filtrées exposées pour SevenTVPickerSizesPanel -----------------
// (choix des emotes de preview : EZ en priorité, sinon 1ère globale)
@property (nonatomic, strong, readonly) NSArray<SevenTVEmote *> *emotePickerAllEmotes;
@property (nonatomic, strong, readonly) NSArray<SevenTVEmote *> *emotePickerGlobalEmotes;

// --- Pipeline réseau/décodage image partagé, réutilisé par SevenTVPickerSizesPanel ---
// (session persistante + décodage forcé hors thread principal ; voir le .m
// pour le détail — ce pipeline sert uniquement aux 3 previews du panneau des
// tailles, la grille elle-même passe par SevenTVEmoteImageCache/AnimationEngine)
- (NSURLSession *)pickerImageSession;
- (UIImage *)decodePickerImageData:(NSData *)data wantsAnimated:(BOOL)wantsAnimated;

// --- Panneau des tailles (toggle du bouton ⚙️, appelle SevenTVPickerSizesPanel) ---
- (void)emotePickerSizesToggleTapped;

// --- Cache de tri interne, invalidé par SevenTVManager quand le catalogue
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
