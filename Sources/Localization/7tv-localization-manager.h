/*
 * 7tv-localization-manager.h
 *
 * Système de traduction FR/EN maison (pas de .strings/.lproj Apple — pas
 * adapté à un tweak Theos sans bundle de ressources dédié, et surtout on
 * veut un TOGGLE MANUEL dans les réglages, indépendant de la langue système
 * de l'iPhone).
 *
 * Usage : remplacer chaque @"Texte visible" par L(@"clé") dans le code UI.
 * Toutes les clés + leurs deux traductions vivent dans 7tv-localization-manager.m.
 *
 * Seul le texte réellement affiché à l'écran est concerné (labels, titres,
 * boutons, messages d'alerte). Les logs internes (-log:) et les commentaires
 * restent en français dans le code, non traduits — ce ne sont pas des
 * strings UI.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVLanguage) {
    S7TVLanguageFrench = 0,
    S7TVLanguageEnglish,
};

@interface S7TVLocalization : NSObject

+ (instancetype)shared;

// Langue actuelle — lue/écrite dans NSUserDefaults (clé "s7tv_language"),
// persistée entre les lancements de l'app. Défaut : anglais.
@property (nonatomic, assign) S7TVLanguage currentLanguage;

// Traduction pour une clé donnée dans la langue actuelle. Si la clé est
// inconnue (ou sa traduction vide dans la langue courante), retourne
// "[clé]" — filet de sécurité VOLONTAIREMENT VISIBLE : plus facile à
// repérer pendant les tests qu'une chaîne vide ou la clé nue, sans jamais
// crasher.
- (NSString *)stringForKey:(NSString *)key;

@end

// Raccourci global, à la façon de NSLocalizedString — plus court à écrire
// dans tout le code UI. Postée dès que la langue change (voir
// S7TVLanguageDidChangeNotification) pour que les écrans déjà affichés
// puissent se recharger.
FOUNDATION_EXPORT NSString *L(NSString *key);

// Postée sur le main thread dès que currentLanguage change. Les écrans de
// réglages actuellement affichés doivent s'y abonner (ou simplement se
// recharger après le toggle, voir SevenTVSettingsController) pour refléter
// la nouvelle langue immédiatement, sans relancer l'app.
FOUNDATION_EXPORT NSString *const S7TVLanguageDidChangeNotification;

NS_ASSUME_NONNULL_END
