/*
 * Export / import of TwitchPlusK-owned NSUserDefaults values.
 *
 * New user-facing settings must use the `tpk_` prefix. They will then be
 * included automatically without adding them to an export allow-list.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TPKSettingsTransferErrorDomain;

typedef NS_ENUM(NSInteger, TPKSettingsTransferErrorCode) {
    TPKSettingsTransferErrorSerialization = 1,
    TPKSettingsTransferErrorInvalidArchive,
    TPKSettingsTransferErrorInvalidValue,
};

// XML property-list archive containing all exportable TwitchPlusK settings.
NSData * _Nullable TPKSettingsExportData(NSError * _Nullable * _Nullable error);
NSString *TPKSettingsExportFileName(void);

// Merges only TwitchPlusK-owned values from a file produced by the exporter.
// Returns the number of imported values, or NSNotFound on failure.
NSUInteger TPKSettingsImportData(NSData *data, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
