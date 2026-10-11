/*
 * Proxy emotes (7TV/BTTV/FFZ) pour pays bloqués. Indépendant de
 * l'adblock vidéo (hosts emotes uniquement). Sélection propre au module.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL TPKEmoteProxyIsEnabled(void);
void TPKEmoteProxySetEnabled(BOOL enabled);
void TPKEmoteProxyRegisterDefaults(void);

// Sélection propre aux emotes (indépendante du proxy vidéo) : choix parmi
// les défauts + liste custom multiligne. Au premier usage, initialisée depuis
// la config vidéo pour préserver le comportement existant.
NSString *TPKEmoteProxyDefaultAddress(void);
void TPKEmoteProxySetDefaultAddress(NSString *address);
NSArray<NSString *> *TPKEmoteProxyCustomAddresses(void);
void TPKEmoteProxySetCustomAddresses(NSArray<NSString *> *addresses);
BOOL TPKEmoteProxyCustomIsEnabled(void);
void TPKEmoteProxySetCustomEnabled(BOOL enabled);
NSArray<NSString *> *TPKEmoteProxyEffectiveAddresses(void);

// URL proxifiée, ou l'originale si OFF, host non emote, ou pas de proxy préfixe.
NSURL * _Nullable TPKEmoteProxyRewriteURL(NSURL * _Nullable URL);

NS_ASSUME_NONNULL_END
