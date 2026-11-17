#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TPKEmoteProviderSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *const TPKEmotePickerOpeningModeFavorites;
FOUNDATION_EXPORT NSString *const TPKEmotePickerOpeningModeTPKChannel;
FOUNDATION_EXPORT NSString *const TPKEmotePickerOpeningModeBTTVChannel;
FOUNDATION_EXPORT NSString *const TPKEmotePickerOpeningModeFFZChannel;
FOUNDATION_EXPORT NSString *const TPKEmotePickerOpeningModeLastUsed;

@interface TPKEmoteProviderSettings : NSObject
+ (BOOL)mixedPickerEnabled;
+ (void)setMixedPickerEnabled:(BOOL)enabled;
+ (NSString *)pickerOpeningMode;
+ (void)setPickerOpeningMode:(NSString * _Null_unspecified)mode;
+ (nullable NSString *)lastPickerLocation;
+ (void)setLastPickerLocation:(NSString * _Null_unspecified)location;
+ (void)migrateLegacySettings;
@end

NS_ASSUME_NONNULL_END
