#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPKAdblockProxyStatus) {
    TPKAdblockProxyStatusUnknown,
    TPKAdblockProxyStatusChecking,
    TPKAdblockProxyStatusOnline,
    TPKAdblockProxyStatusOffline,
};

// GET /ping (Luminous), sinon GET <base>https://google.com (préfixe).
// « Online » = 2xx sur l'une des deux. Appels identiques groupés.
void TPKAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(TPKAdblockProxyStatus status));

NS_ASSUME_NONNULL_END
