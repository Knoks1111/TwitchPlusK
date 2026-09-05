#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Ouvre la carte Twitch depuis une vue du chat custom en réutilisant le
// callback natif de ChannelChatViewController.
FOUNDATION_EXPORT BOOL s7tv_openViewerCardForUsername(NSString *username,
                                                       UIView * _Nullable sourceView);

NS_ASSUME_NONNULL_END
