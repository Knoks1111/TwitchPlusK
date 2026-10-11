/*
 * tpK-tap-logger.h
 *
 * Tap Logger : diagnostic actif uniquement quand le réglage « Tap Logger »
 * est ON. À chaque tap, logue la position, le first responder, la vue
 * touchée, son contrôleur et 15 niveaux de hiérarchie.
 */

#import <UIKit/UIKit.h>

// Installe le swizzle UIWindow.sendEvent:. Appelé une fois au démarrage.
void TPKTapLoggerSetup(void);
