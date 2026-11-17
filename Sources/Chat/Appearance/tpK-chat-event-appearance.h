#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const TPKChatEventAppearanceDidChangeNotification;
FOUNDATION_EXPORT const CGFloat TPKChatHighlightBackgroundOpacity;

typedef NS_ENUM(NSInteger, TPKChatEventGroup) {
    TPKChatEventGroupNone = -1,
    TPKChatEventGroupSubscriptions,
    TPKChatEventGroupGifts,
    TPKChatEventGroupBits,
    TPKChatEventGroupPoints,
    TPKChatEventGroupRaids,
    TPKChatEventGroupAnnouncements,
    TPKChatEventGroupMilestones,
    TPKChatEventGroupOther,
    TPKChatEventGroupDeleted,
    TPKChatEventGroupCount,
};

FOUNDATION_EXPORT TPKChatEventGroup TPKChatEventGroupForIdentifier(const char *identifier);
FOUNDATION_EXPORT UIColor *TPKChatColorFromHexString(NSString *hex);
FOUNDATION_EXPORT NSString *TPKChatColorToHexString(UIColor *color);
FOUNDATION_EXPORT void TPKChatAttachColorControl(UITableViewCell *cell, UIColor *color, id target, SEL action);

@interface TPKChatEventAppearance : NSObject
+ (void)reload;
+ (BOOL)hasCustomBackgrounds;
+ (BOOL)enabledForGroup:(TPKChatEventGroup)group;
+ (UIColor *)colorForGroup:(TPKChatEventGroup)group;
+ (UIColor *)backgroundForGroup:(TPKChatEventGroup)group oled:(BOOL)oled;
+ (NSString *)titleForGroup:(TPKChatEventGroup)group;
+ (NSString *)iconForGroup:(TPKChatEventGroup)group;
+ (UIColor *)tintForGroup:(TPKChatEventGroup)group;
+ (void)configureCell:(UITableViewCell *)cell forGroup:(TPKChatEventGroup)group;
+ (void)toggleGroup:(UISwitch *)toggle;
@end
