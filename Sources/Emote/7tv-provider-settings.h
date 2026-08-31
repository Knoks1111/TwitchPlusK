/*
 * Réglages communs des providers d'emotes.
 *
 * Les valeurs sont volontairement regroupées ici plutôt que dans le picker :
 * le chat, le picker et les imports/exports doivent observer le même état.
 */
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const S7TVEmoteProviderSettingsDidChangeNotification;

typedef NS_ENUM(NSInteger, S7TVExternalEmoteProvider) {
    S7TVExternalEmoteProvider7TV = 0,
    S7TVExternalEmoteProviderBTTV,
    S7TVExternalEmoteProviderFFZ,
};

@interface S7TVEmoteProviderSettings : NSObject
+ (BOOL)isProviderEnabled:(S7TVExternalEmoteProvider)provider;
+ (void)setProvider:(S7TVExternalEmoteProvider)provider enabled:(BOOL)enabled;

// Tableau d'identifiants stables ("7tv", "bttv", "ffz"), sans doublon.
// La valeur par défaut est 7TV > BTTV > FFZ.
+ (NSArray<NSString *> *)providerPriority;
+ (void)setProviderPriority:(NSArray<NSString *> *)priority;

+ (BOOL)zeroWidthEnabled;
+ (void)setZeroWidthEnabled:(BOOL)enabled;

// Quand cette option est activée, le picker affiche un seul onglet « Tous »
// (avec Favoris) et mélange les trois providers. Désactivée, l'interface
// conserve les onglets 7TV, BTTV et FFZ séparés.
+ (BOOL)mixedPickerEnabled;
+ (void)setMixedPickerEnabled:(BOOL)enabled;

// Point d'entrée à l'ouverture du picker (Favoris, channel d'un provider ou
// dernier menu utilisé). Les deux composants ne lisent donc jamais directement
// une clé NSUserDefaults différente ou une valeur non validée.
+ (NSString *)pickerOpeningMode;
+ (void)setPickerOpeningMode:(NSString *)mode;

// Dernier emplacement réellement utilisé par le picker. Cette valeur est un
// historique interne ; elle passe tout de même par le même store central pour
// que le réglage « dernier menu utilisé » reste cohérent après import.
+ (NSString *)lastPickerLocation;
+ (void)setLastPickerLocation:(NSString *)location;

// Appelable après import d'une ancienne sauvegarde. La migration est
// idempotente et ne remplace jamais une préférence v2 déjà présente.
+ (void)migrateLegacySettings;
@end

FOUNDATION_EXPORT NSString *S7TVEmoteProviderIdentifier(S7TVExternalEmoteProvider provider);
FOUNDATION_EXPORT S7TVExternalEmoteProvider S7TVEmoteProviderFromIdentifier(NSString *identifier);

FOUNDATION_EXPORT NSString *const S7TVEmotePickerOpeningModeFavorites;
FOUNDATION_EXPORT NSString *const S7TVEmotePickerOpeningModeSevenTVChannel;
FOUNDATION_EXPORT NSString *const S7TVEmotePickerOpeningModeBTTVChannel;
FOUNDATION_EXPORT NSString *const S7TVEmotePickerOpeningModeFFZChannel;
FOUNDATION_EXPORT NSString *const S7TVEmotePickerOpeningModeLastUsed;
