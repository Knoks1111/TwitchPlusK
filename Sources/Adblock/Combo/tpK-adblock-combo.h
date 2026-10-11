/*
 * Liste proxy du mode Combo (Proxy + Local VAFT). Séparée de la liste vidéo :
 * relais non filtrants (RTE4-7) pour l'accès/qualité — ex. pays qui bloquent
 * la 1440p — pendant que VAFT garde la décision anti-pub en local. Customs
 * combo à part, jamais mélangés aux customs vidéo.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void TPKAdblockComboProxyRegisterDefaults(void);

// Pool fixe : RTE4-7 uniquement, pas de built-in (sémantique relais pure).
NSArray<NSString *> *TPKAdblockComboProxyAddresses(void);
// Défaut combo sélectionné (persisté à part, repli : premier RTE).
NSString *TPKAdblockComboProxyDefaultAddress(void);
void TPKAdblockComboProxySetDefaultAddress(NSString *address);
// Customs combo (clés à part, multiligne comme la liste vidéo).
NSArray<NSString *> *TPKAdblockComboProxyCustomAddresses(void);
void TPKAdblockComboProxySetCustomAddresses(NSArray<NSString *> *addresses);
BOOL TPKAdblockComboProxyCustomIsEnabled(void);
void TPKAdblockComboProxySetCustomEnabled(BOOL enabled);
// Effectif combo : customs si activés et non vides, sinon défaut choisi.
NSArray<NSString *> *TPKAdblockComboProxyEffectiveAddresses(void);

NS_ASSUME_NONNULL_END
