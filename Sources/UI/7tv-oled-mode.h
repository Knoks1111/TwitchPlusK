/*
 * 7tv-oled-mode.h
 *
 * Mode OLED centralisé : ne remplace que les tokens de fond fournis par la
 * palette sombre de Twitch. Les vues, textes, séparateurs et boutons ne sont
 * jamais parcourus ni recolorés individuellement.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const S7TVOLEDModePreferenceKey;

BOOL S7TVOLEDModeEnabled(void);
void S7TVOLEDModeSetEnabled(BOOL enabled);
void S7TVOLEDModeReloadFromDefaults(void);
void S7TVOLEDModeSetup(void);

NS_ASSUME_NONNULL_END
