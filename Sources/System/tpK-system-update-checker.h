#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void TPKUpdateCheckerSetup(void);
// Version dispo si le manifeste caché est plus récent que le build,
// même si ignorée au lancement. Nil sinon.
FOUNDATION_EXPORT NSString * _Nullable TPKUpdateCheckerAvailableVersion(void);
