#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Twitch updates: verify JSI ABI and RN lifecycle hooks.
// Check Metro module IDs and useChatCommands/openViewerCard wiring.
// Update the RN version and bundle SHA-256 in .mm, then test on device.

FOUNDATION_EXPORT NSAttributedStringKey const TPKChatViewerCardUserIDAttribute;
FOUNDATION_EXPORT void TPKChatViewerCardSetup(void);
FOUNDATION_EXPORT void TPKChatViewerCardOpen(NSString *userID, UIView *sourceView);

NS_ASSUME_NONNULL_END
