/*
 * 7tv-info-tooltip.h
 *
 * Composant réutilisable "bouton info + bulle tooltip" pour les écrans de
 * réglages TwitchPlusK. Remplace les longues descriptions/footers affichés
 * en permanence : un petit info.circle à côté du réglage ou du header de
 * section, et la description s'affiche dans une bulle compacte au style
 * dark existant.
 *
 * Comportement :
 *   - tap sur le même "i"          → ferme la bulle
 *   - tap sur un autre "i"         → ferme l'ancienne, ouvre la nouvelle
 *   - tap n'importe où ailleurs    → ferme immédiatement
 *   - scroll de la table hôte      → ferme (jamais de bulle détachée)
 *   - rotation / changement de
 *     langue / sortie de l'écran   → ferme
 *
 * La description n'est JAMAIS résolue à la création du bouton : seule la
 * clé de localisation est stockée, le texte est relu via L(key) à chaque
 * ouverture — le changement de langue est donc reflété immédiatement.
 */

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface S7TVInfoButton : UIButton

// Clé de localisation de la description (résolue à l'affichage uniquement).
@property (nonatomic, copy, readonly) NSString *s7tv_localizationKey;

@end

@interface S7TVInfoTooltip : NSObject

// Crée un bouton "i" (icône 13pt, zone tactile ≈ 30×30pt) qui ouvre/ferme
// la bulle de description correspondant à la clé donnée.
+ (UIButton *)infoButtonWithKey:(NSString *)key;

// Variante d'alerte avec le même comportement de tooltip et une icône rouge
// « ! ». La clé de localisation est résolue à l'ouverture, comme pour le
// bouton d'information normal.
+ (UIButton *)warningButtonWithKey:(NSString *)key;

// Ferme la bulle actuellement ouverte, s'il y en a une. No-op sinon.
// À appeler dans viewWillDisappear des écrans qui utilisent des boutons info.
+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END
