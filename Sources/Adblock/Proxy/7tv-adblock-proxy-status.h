#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVAdblockProxyStatus) {
    S7TVAdblockProxyStatusUnknown,
    S7TVAdblockProxyStatusChecking,
    S7TVAdblockProxyStatusOnline,
    S7TVAdblockProxyStatusOffline,
};

// Vérifie le fonctionnement réel du endpoint Luminous V1 : GET /ping avec
// l'authentification configurée. « Online » signifie uniquement HTTP 200.
// La sonde est asynchrone et les appels identiques déjà en cours sont groupés.
void S7TVAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(S7TVAdblockProxyStatus status));

NS_ASSUME_NONNULL_END
