/*
 * tpK-oled-mode.h
 *
 * Mode OLED de Twitch :
 * - constructors UIColor de la palette native Twitch ;
 * - setters setBackgroundColor: de RCTViewComponentView et RNSScreenContentWrapper ;
 * - fonds React Native neutres et opaques uniquement.
 *
 * Les composants texte, image, icône, avatar, badge et contrôles
 * interactifs ou sélectionnés (onglets, catégories, segments, chips) sont exclus.
 * Le mode n'utilise ni patch machine ni hook global de UIView.
 *
 * Maintenance après une mise à jour de Twitch :
 * 1. Tester d'abord le tweak existant sur les écrans concernés.
 * 2. Si un fond React Native reste incorrect, vérifier uniquement les noms de
 *    classes RCTViewComponentView/RNSScreenContentWrapper dans
 *    Sources/UI/tpK-oled-mode.m.
 * 3. Si la palette change, mettre à jour les valeurs exactes dans
 *    tpk_oledShouldMapColor et, si nécessaire, le seuil de couleur neutre dans
 *    tpk_oledReactBackgroundColor.
 * 4. Ne pas faire un reverse global : les hooks de classes couvrent déjà toutes
 *    leurs instances, quel que soit l'écran.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TPKOLEDModePreferenceKey;
FOUNDATION_EXPORT NSString *const TPKOLEDModeDidChangeNotification;

BOOL TPKOLEDModeEnabled(void);
void TPKOLEDModeSetEnabled(BOOL enabled);
void TPKOLEDModeReloadFromDefaults(void);
void TPKOLEDModeSetup(void);

NS_ASSUME_NONNULL_END
