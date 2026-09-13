/* API commune d'intégration des chats Twitch. */

#import <UIKit/UIKit.h>
#import "Chat/7tv-chat-message.h"

NS_ASSUME_NONNULL_BEGIN

@class SevenTVChatCustomView;

UIView * _Nullable s7tv_findChatInputView(void);
SevenTVChatCustomView * _Nullable s7tv_activeChatCustomView(void);
void s7tv_handleNativeChatViewLifecycle(UIView *view);
void s7tv_receiveVODMessage(S7TVChatMessage *message);
void s7tv_applyChatCustomToggle(void);
void s7tv_reloadActiveChatCustomView(void);
void s7tv_reloadActiveChatCustomViewAnimated(void);
void s7tv_reloadActiveChatCustomViewForConfiguration(void);
void s7tv_reloadActiveChatMessage(NSString *messageID);
void s7tv_applyModerationStateToRetainedMessage(NSString *messageID,
                                                S7TVChatMessageState state,
                                                S7TVChatModerationKind moderationKind,
                                                NSInteger durationSeconds);
void s7tv_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString * _Nullable authorLogin,
                                                    S7TVChatModerationKind moderationKind,
                                                    NSInteger durationSeconds);
void s7tv_applyModerationToAllRetainedMessages(void);
void s7tv_scheduleChatCustomReload(void);
void s7tv_setupChatCustomIntegration(void);

// Rafraîchit un message dans tous les chats enregistrés.
void s7tv_refreshChatMessageInViews(NSString *messageID,
                                    SevenTVChatCustomView * _Nullable sourceView,
                                    void (^ _Nullable completion)(void));

NS_ASSUME_NONNULL_END
