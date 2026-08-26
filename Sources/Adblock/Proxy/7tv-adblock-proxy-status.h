#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVAdblockProxyStatus) {
    S7TVAdblockProxyStatusUnknown,
    S7TVAdblockProxyStatusChecking,
    S7TVAdblockProxyStatusOnline,
    S7TVAdblockProxyStatusOffline,
};

// Reprise de la sonde TwitchAdBlock : vérifie qu'une connexion TCP peut être
// ouverte vers le proxy. Cela teste sa disponibilité, pas ses identifiants.
void S7TVAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(S7TVAdblockProxyStatus status));

NS_ASSUME_NONNULL_END
