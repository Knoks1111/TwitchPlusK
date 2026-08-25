/*
 * Export / import of TwitchPlusK-owned NSUserDefaults values.
 *
 * New user-facing settings must use the `s7tv_` prefix. They will then be
 * included automatically without adding them to an export allow-list.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const S7TVSettingsTransferErrorDomain;

typedef NS_ENUM(NSInteger, S7TVSettingsTransferErrorCode) {
    S7TVSettingsTransferErrorSerialization = 1,
    S7TVSettingsTransferErrorInvalidArchive,
    S7TVSettingsTransferErrorInvalidValue,
};

// XML property-list archive containing all exportable TwitchPlusK settings.
NSData * _Nullable S7TVSettingsExportData(NSError * _Nullable * _Nullable error);
NSString *S7TVSettingsExportFileName(void);

// Merges only TwitchPlusK-owned values from a file produced by the exporter.
// Returns the number of imported values, or NSNotFound on failure.
NSUInteger S7TVSettingsImportData(NSData *data, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
