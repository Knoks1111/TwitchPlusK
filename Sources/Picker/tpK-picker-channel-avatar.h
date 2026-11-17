#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern NSString *const TPKPickerChannelAvatarDidUpdateNotification;

// Caches channel avatars for the picker's Channel tab.
@interface TPKPickerChannelAvatarProvider : NSObject
+ (instancetype)sharedProvider;
- (nullable NSURL *)channelAvatarURLForChannelID:(NSString *)channelID;
@end
NS_ASSUME_NONNULL_END
