#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVAdblockProxyStatus) {
    S7TVAdblockProxyStatusUnknown,
    S7TVAdblockProxyStatusChecking,
    S7TVAdblockProxyStatusOnline,
    S7TVAdblockProxyStatusOffline,
};

// GET /ping (Luminous), sinon GET <base>https://google.com (préfixe).
// « Online » = 2xx sur l'une des deux. Appels identiques groupés.
void S7TVAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(S7TVAdblockProxyStatus status));

NS_ASSUME_NONNULL_END
