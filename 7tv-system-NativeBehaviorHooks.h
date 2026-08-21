/*
 * 7tv-system-NativeBehaviorHooks.h
 *
 * Modules "100% autonomes" qui modifient un comportement natif de Twitch
 * sans rapport avec le rendu 7TV : Auto Collect Channel Points (autoclaim
 * des coffres de points de chaîne) et le verrou d'orientation (bouton
 * Share hijacké). Voir 7tv-system-NativeBehaviorHooks.m pour le détail.
 *
 * Extrait de TweakSevenTV.m.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
// Channel Points — points d'accroche appelés depuis TweakSevenTV.m
// ============================================================

// Appelé sur chaque réponse gql.twitch.tv interceptée (hooks NSURLSession/
// Apollo dans TweakSevenTV.m) — détecte le champ availableClaim.
void s7tv_scanGQLResponseForChannelPointsClaim(NSData *data);

// Appelé sur chaque trame WebSocket texte interceptée (hook
// NSURLSessionWebSocketTask dans TweakSevenTV.m) — détecte l'événement
// PubSub "claim-available" en cours de session.
void s7tv_scanWebSocketTextForChannelPointsClaimAvailable(NSString *text);

// Stoppe le retry pour l'ID en cours — appelé depuis le hook Apollo
// (TweakSevenTV.m) quand la mutation ClaimChannelPointsMutation est
// confirmée réussie côté serveur.
void s7tv_setPendingChannelPointsClaimID(NSString * _Nullable claimID);

// Démarre la boucle de polling de secours (filet de sécurité silencieux) —
// appelé une fois depuis le constructeur (TweakSevenTV.m).
void s7tv_scanForChannelPointsLoop(void);

// ============================================================
// Verrou d'orientation — points d'accroche appelés depuis TweakSevenTV.m
// ============================================================

// Lecture seule de l'état du verrou — utilisé par le hijack du bouton Share
// (TweakSevenTV.m) pour l'icône/tint/label initiaux, avant même le premier
// lock. La variable réelle reste privée à ce fichier.
BOOL s7tv_isOrientationLocked(void);

// Installe les swizzles orientation à la demande (no-op au lancement) —
// appelé depuis le constructeur (TweakSevenTV.m), symétrique aux autres
// s7tv_swizzle_*() du fichier principal.
void s7tv_swizzle_orientation_lock(void);
