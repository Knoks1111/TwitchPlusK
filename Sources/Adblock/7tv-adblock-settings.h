/*
 * TwitchPlusK adblock settings.
 *
 * Proxy behavior is derived from TwitchAdBlock by level3tjg/gunnerkidBT
 * (MIT). See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const S7TVAdblockEnabledKey;
FOUNDATION_EXPORT NSString *const S7TVAdblockProxyEnabledKey;
FOUNDATION_EXPORT NSString *const S7TVAdblockCustomProxyEnabledKey;
FOUNDATION_EXPORT NSString *const S7TVAdblockCustomProxyKey;
FOUNDATION_EXPORT NSString *const S7TVAdblockHideAdFreeButtonKey;
// Émis lorsque le snapshot runtime du toggle maître change réellement.
// Les consommateurs peuvent réconcilier leur état sans relire les réglages
// dans une boucle.
FOUNDATION_EXPORT NSString *const S7TVAdblockRuntimeStateDidChangeNotification;

// Méthode AdBlock : "disabled" | "proxy" | "local" (VAFT).
// Valeur absente/invalide/corrompue → fallback interne déterministe Disabled.
// État le plus neutre et le plus sûr : une valeur invalide n'active aucun
// qu'un état interne : tant que le toggle maître est OFF, rien n'agit.
FOUNDATION_EXPORT NSString *const S7TVAdblockMethodKey;

typedef NS_ENUM(NSInteger, S7TVAdblockMethod) {
    S7TVAdblockMethodDisabled = 0,
    S7TVAdblockMethodProxy = 1,
    S7TVAdblockMethodLocalVaft = 2,
};

void S7TVAdblockRegisterDefaults(void);
BOOL S7TVAdblockIsEnabled(void);
BOOL S7TVAdblockProxyIsEnabled(void);
BOOL S7TVAdblockCustomProxyIsEnabled(void);
BOOL S7TVAdblockHideAdFreeButtonIsEnabled(void);

// ── Snapshots runtime (O(1), hot-path safe — leçon PR #2) ───────────────────
// La méthode active est déterminée UNE SEULE FOIS au lancement, avant
// l'installation des hooks, puis jamais modifiée. Elle est la seule à pouvoir
// router un moteur au runtime. La méthode configurée sert uniquement aux
// settings/persistance/comparaison de redémarrage.
BOOL S7TVAdblockActiveMethodIsLocal(void);
S7TVAdblockMethod S7TVAdblockActiveMethod(void);
BOOL S7TVAdblockActiveMethodIsProxy(void);
void S7TVAdblockTakeRuntimeMethodSnapshot(void);

// Snapshot du toggle maître et du toggle Turbo, rafraîchissable à chaud
// (setters + import de settings). Hot paths doivent utiliser ces lectures.
BOOL S7TVAdblockEnabledFast(void);
BOOL S7TVAdblockHideAdFreeButtonEnabledFast(void);
void S7TVAdblockRefreshRuntimeSnapshots(void);

// ── Méthode configurée (settings / persistance / prochain lancement) ────────
BOOL S7TVAdblockConfiguredMethodIsLocal(void);
S7TVAdblockMethod S7TVAdblockConfiguredMethod(void);
void S7TVAdblockSetConfiguredMethod(S7TVAdblockMethod method);
NSString * _Nullable S7TVAdblockCustomProxyAddress(void);
NSArray<NSString *> *S7TVAdblockCustomProxyAddresses(void);
void S7TVAdblockSetEnabled(BOOL enabled);
// Persiste l'état pour le prochain lancement sans modifier le snapshot du
// moteur déjà installé dans le processus courant.
void S7TVAdblockSetEnabledForNextLaunch(BOOL enabled);
void S7TVAdblockSetProxyEnabled(BOOL enabled);
void S7TVAdblockSetCustomProxyEnabled(BOOL enabled);
void S7TVAdblockSetHideAdFreeButtonEnabled(BOOL enabled);
void S7TVAdblockSetCustomProxyAddress(NSString * _Nullable address);
void S7TVAdblockSetCustomProxyAddresses(NSArray<NSString *> *addresses);

NSString *S7TVAdblockDefaultProxyAddress(void);
NSString * _Nullable S7TVAdblockEffectiveProxyAddress(void);
NSArray<NSString *> *S7TVAdblockEffectiveProxyAddresses(void);
NSURL * _Nullable S7TVAdblockNormalizedProxyURL(NSString *address);
BOOL S7TVAdblockUserIsAdExempt(NSString * _Nullable queryString);

NS_ASSUME_NONNULL_END
