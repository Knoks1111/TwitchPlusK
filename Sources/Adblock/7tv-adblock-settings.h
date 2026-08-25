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

void S7TVAdblockRegisterDefaults(void);
BOOL S7TVAdblockIsEnabled(void);
BOOL S7TVAdblockProxyIsEnabled(void);
BOOL S7TVAdblockCustomProxyIsEnabled(void);
BOOL S7TVAdblockHideAdFreeButtonIsEnabled(void);
NSString * _Nullable S7TVAdblockCustomProxyAddress(void);
NSArray<NSString *> *S7TVAdblockCustomProxyAddresses(void);
void S7TVAdblockSetEnabled(BOOL enabled);
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
