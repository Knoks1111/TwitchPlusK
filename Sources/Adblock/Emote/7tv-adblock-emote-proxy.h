/*
 * Proxy emotes (7TV/BTTV/FFZ) pour pays bloqués. Indépendant de
 * l'adblock vidéo (hosts emotes uniquement). Sélection propre au module.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL S7TVEmoteProxyIsEnabled(void);
void S7TVEmoteProxySetEnabled(BOOL enabled);
void S7TVEmoteProxyRegisterDefaults(void);

// Sélection propre aux emotes (indépendante du proxy vidéo) : choix parmi
// les défauts + liste custom multiligne. Au premier usage, initialisée depuis
// la config vidéo pour préserver le comportement existant.
NSString *S7TVEmoteProxyDefaultAddress(void);
void S7TVEmoteProxySetDefaultAddress(NSString *address);
NSArray<NSString *> *S7TVEmoteProxyCustomAddresses(void);
void S7TVEmoteProxySetCustomAddresses(NSArray<NSString *> *addresses);
BOOL S7TVEmoteProxyCustomIsEnabled(void);
void S7TVEmoteProxySetCustomEnabled(BOOL enabled);
NSArray<NSString *> *S7TVEmoteProxyEffectiveAddresses(void);

// URL proxifiée, ou l'originale si OFF, host non emote, ou pas de proxy préfixe.
NSURL * _Nullable S7TVEmoteProxyRewriteURL(NSURL * _Nullable URL);

NS_ASSUME_NONNULL_END
