/*
 * 7tv-system-native-behavior-hooks.h
 *
 * Modules "100% autonomes" qui modifient un comportement natif de Twitch
 * sans rapport avec le rendu 7TV : Auto Collect Channel Points (autoclaim
 * des coffres de points de chaîne) et le verrou d'orientation (bouton
 * Share hijacké). Voir 7tv-system-native-behavior-hooks.m pour le détail.
 *
 * Extrait de 7tv-core-runtime-hooks.m.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ============================================================
// Channel Points — points d'accroche appelés depuis 7tv-core-runtime-hooks.m
// ============================================================

// Appelé sur chaque réponse gql.twitch.tv interceptée (hooks NSURLSession/
// Apollo dans 7tv-core-runtime-hooks.m) — détecte le champ availableClaim.
void s7tv_scanGQLResponseForChannelPointsClaim(NSData *data);

// Appelé sur chaque trame WebSocket texte interceptée (hook
// NSURLSessionWebSocketTask dans 7tv-core-runtime-hooks.m) — détecte l'événement
// PubSub "claim-available" en cours de session.
void s7tv_scanWebSocketTextForChannelPointsClaimAvailable(NSString *text);

// Stoppe le retry pour l'ID en cours — appelé depuis le hook Apollo
// (7tv-core-runtime-hooks.m) quand la mutation ClaimChannelPointsMutation est
// confirmée réussie côté serveur.
void s7tv_setPendingChannelPointsClaimID(NSString * _Nullable claimID);

// Démarre la boucle de polling de secours (filet de sécurité silencieux) —
// appelé une fois depuis le constructeur (7tv-core-runtime-hooks.m).
void s7tv_scanForChannelPointsLoop(void);

// Valeur partagée avec les logs du hook Apollo resté dans 7tv-core-runtime-hooks.m.
// Exportée pour garder une source de vérité unique après l'extraction du
// module (la rendre static ici cassait la compilation du fichier principal).
FOUNDATION_EXPORT const NSTimeInterval S7TVChannelPointsClaimRetryCooldown;

// ============================================================
// Verrou d'orientation — points d'accroche appelés depuis 7tv-core-runtime-hooks.m
// ============================================================

typedef NS_ENUM(NSInteger, S7TVAutoOrientationLockMode) {
    S7TVAutoOrientationLockModeDisabled = 0,
    S7TVAutoOrientationLockModeLandscapeLeft,
    S7TVAutoOrientationLockModeLandscapeRight,
    S7TVAutoOrientationLockModeBothLandscapes,
};

// Préférences persistées du verrou. Le bouton et l'auto-lock sont désactivés
// par défaut. Désactiver le bouton restaure le bouton Partager natif, libère
// un verrou éventuel et suspend totalement la détection automatique.
BOOL s7tv_orientationLockButtonEnabled(void);
void s7tv_setOrientationLockButtonEnabled(BOOL enabled);
S7TVAutoOrientationLockMode s7tv_autoOrientationLockMode(void);
void s7tv_setAutoOrientationLockMode(S7TVAutoOrientationLockMode mode);

// Lecture seule de l'état du verrou — utilisé par le hijack du bouton Share
// du module pour l'icône/tint/label initiaux, avant même le premier
// lock. La variable réelle reste privée à ce fichier.
BOOL s7tv_isOrientationLocked(void);

// Appelé par le hook UIView.didMoveToWindow. Ne traite que
// Twitch.TheaterPlayerControlsView et installe le bouton de verrouillage.
void s7tv_handleTheaterControlsViewLifecycle(UIView *view);

// Réactive au lancement l'observer physique si l'auto-lock est configuré.
// Les swizzles de blocage restent installés à la demande au premier lock.
// Appelé depuis le constructeur de 7tv-core-runtime-hooks.m.
void s7tv_swizzle_orientation_lock(void);

NS_ASSUME_NONNULL_END
