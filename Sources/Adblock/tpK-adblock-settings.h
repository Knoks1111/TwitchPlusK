/*
 * TwitchPlusK adblock settings.
 *
 * Proxy behavior is derived from TwitchAdBlock by level3tjg/gunnerkidBT
 * (MIT). See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TPKAdblockEnabledKey;
FOUNDATION_EXPORT NSString *const TPKAdblockProxyEnabledKey;
FOUNDATION_EXPORT NSString *const TPKAdblockCustomProxyEnabledKey;
FOUNDATION_EXPORT NSString *const TPKAdblockCustomProxyKey;
FOUNDATION_EXPORT NSString *const TPKAdblockDefaultProxyKey;
FOUNDATION_EXPORT NSString *const TPKAdblockHideAdFreeButtonKey;
// Émis lorsque le snapshot runtime du toggle maître change réellement.
// Les consommateurs peuvent réconcilier leur état sans relire les réglages
// dans une boucle.
FOUNDATION_EXPORT NSString *const TPKAdblockRuntimeStateDidChangeNotification;

// Méthode AdBlock : "disabled" | "proxy" | "local" (VAFT) | "combo".
// "combo" = Proxy (accès/qualité via relais non filtrant) + Local (VAFT,
// décision anti-pub). Opt-in explicite : aucun changement sans sélection.
// État le plus neutre et le plus sûr : une valeur invalide n'active aucun
// qu'un état interne : tant que le toggle maître est OFF, rien n'agit.
FOUNDATION_EXPORT NSString *const TPKAdblockMethodKey;

typedef NS_ENUM(NSInteger, TPKAdblockMethod) {
    TPKAdblockMethodDisabled = 0,
    TPKAdblockMethodProxy = 1,
    TPKAdblockMethodLocalVaft = 2,
    TPKAdblockMethodProxyPlusLocal = 3,
};

void TPKAdblockRegisterDefaults(void);
BOOL TPKAdblockIsEnabled(void);
BOOL TPKAdblockProxyIsEnabled(void);
BOOL TPKAdblockCustomProxyIsEnabled(void);
BOOL TPKAdblockHideAdFreeButtonIsEnabled(void);

// ── Snapshots runtime (O(1), hot-path safe — leçon PR #2) ───────────────────
// La méthode active est déterminée UNE SEULE FOIS au lancement, avant
// l'installation des hooks, puis jamais modifiée. Elle est la seule à pouvoir
// router un moteur au runtime. La méthode configurée sert uniquement aux
// settings/persistance/comparaison de redémarrage.
BOOL TPKAdblockActiveMethodIsLocal(void);
TPKAdblockMethod TPKAdblockActiveMethod(void);
BOOL TPKAdblockActiveMethodIsProxy(void);
// Combo inclus : le pipeline proxy (accès/qualité) tourne aussi en combo.
BOOL TPKAdblockActiveMethodUsesProxy(void);
// Combo inclus : les décisions VAFT tournent aussi en combo.
BOOL TPKAdblockActiveMethodUsesLocal(void);
void TPKAdblockTakeRuntimeMethodSnapshot(void);

// Snapshot du toggle maître et du toggle Turbo, rafraîchissable à chaud
// (setters + import de settings). Hot paths doivent utiliser ces lectures.
BOOL TPKAdblockEnabledFast(void);
BOOL TPKAdblockHideAdFreeButtonEnabledFast(void);
void TPKAdblockRefreshRuntimeSnapshots(void);

// ── Méthode configurée (settings / persistance / prochain lancement) ────────
BOOL TPKAdblockConfiguredMethodIsLocal(void);
TPKAdblockMethod TPKAdblockConfiguredMethod(void);
void TPKAdblockSetConfiguredMethod(TPKAdblockMethod method);
NSString * _Nullable TPKAdblockCustomProxyAddress(void);
NSArray<NSString *> *TPKAdblockCustomProxyAddresses(void);
void TPKAdblockSetEnabled(BOOL enabled);
// Persiste l'état pour le prochain lancement sans modifier le snapshot du
// moteur déjà installé dans le processus courant.
void TPKAdblockSetEnabledForNextLaunch(BOOL enabled);
void TPKAdblockSetProxyEnabled(BOOL enabled);
void TPKAdblockSetCustomProxyEnabled(BOOL enabled);
void TPKAdblockSetHideAdFreeButtonEnabled(BOOL enabled);
void TPKAdblockSetCustomProxyAddress(NSString * _Nullable address);
void TPKAdblockSetCustomProxyAddresses(NSArray<NSString *> *addresses);

NSString *TPKAdblockDefaultProxyAddress(void);
NSArray<NSString *> *TPKAdblockDefaultProxyAddresses(void);
void TPKAdblockSetDefaultProxyAddress(NSString *address);
NSString * _Nullable TPKAdblockEffectiveProxyAddress(void);
NSArray<NSString *> *TPKAdblockEffectiveProxyAddresses(void);
NSURL * _Nullable TPKAdblockNormalizedProxyURL(NSString *address);
BOOL TPKAdblockUserIsAdExempt(NSString * _Nullable queryString);

NS_ASSUME_NONNULL_END
