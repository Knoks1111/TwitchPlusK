// Tables Languages/*.strings intégrées au dylib ; langue choisie manuellement.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPKLanguage) {
    TPKLanguageFrench = 0,
    TPKLanguageEnglish,
};

@interface TPKLocalization : NSObject

+ (instancetype)shared;

// Langue actuelle — lue/écrite dans NSUserDefaults (clé "tpk_language"),
// persistée entre les lancements de l'app. Défaut : anglais.
@property (nonatomic, assign) TPKLanguage currentLanguage;

// Traduction pour une clé donnée dans la langue actuelle. Si la clé est
// inconnue (ou sa traduction vide dans la langue courante), retourne
// "[Missing translation: clé]", toujours en anglais : plus facile à
// repérer pendant les tests qu'une chaîne vide ou la clé nue, sans jamais
// crasher.
- (NSString *)stringForKey:(NSString *)key;

@end

// Raccourci global, à la façon de NSLocalizedString — plus court à écrire
// dans tout le code UI. Postée dès que la langue change (voir
// TPKLanguageDidChangeNotification) pour que les écrans déjà affichés
// puissent se recharger.
FOUNDATION_EXPORT NSString *L(NSString *key);

// Postée sur le main thread dès que currentLanguage change. Les écrans de
// réglages actuellement affichés doivent s'y abonner (ou simplement se
// recharger après le toggle, voir TPKSettingsController) pour refléter
// la nouvelle langue immédiatement, sans relancer l'app.
FOUNDATION_EXPORT NSString *const TPKLanguageDidChangeNotification;

NS_ASSUME_NONNULL_END
