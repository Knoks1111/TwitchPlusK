/*
 * 7tv-system-native-behavior-hooks.h
 *
 * Module autonome qui modifie le verrou d'orientation natif de Twitch
 * (bouton Share hijacké). Voir 7tv-system-native-behavior-hooks.m pour le détail.
 *
 * Extrait de 7tv-core-runtime-hooks.m.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

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
