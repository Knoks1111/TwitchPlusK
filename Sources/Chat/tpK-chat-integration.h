/* API commune d'intégration des chats Twitch. */

#import <UIKit/UIKit.h>
#import "Chat/tpK-chat-message.h"

NS_ASSUME_NONNULL_BEGIN

@class TPKChatCustomView;

UIView * _Nullable tpk_findChatInputView(void);
TPKChatCustomView * _Nullable tpk_activeChatCustomView(void);
void tpk_handleNativeChatViewLifecycle(UIView *view);
void tpk_receiveVODMessage(TPKChatMessage *message);
void tpk_applyChatCustomToggle(void);
void tpk_reloadActiveChatCustomView(void);
void tpk_reloadActiveChatCustomViewAnimated(void);
void tpk_reloadActiveChatCustomViewForConfiguration(void);
void tpk_reloadActiveChatMessage(NSString *messageID);
void tpk_applyModerationStateToRetainedMessage(NSString *messageID,
                                                TPKChatMessageState state,
                                                TPKChatModerationKind moderationKind,
                                                NSInteger durationSeconds);
void tpk_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString * _Nullable authorLogin,
                                                    TPKChatModerationKind moderationKind,
                                                    NSInteger durationSeconds);
void tpk_applyModerationToAllRetainedMessages(void);
void tpk_scheduleChatCustomReload(void);
void tpk_setupChatCustomIntegration(void);

// Rafraîchit un message dans tous les chats enregistrés.
void tpk_refreshChatMessageInViews(NSString *messageID,
                                    TPKChatCustomView * _Nullable sourceView,
                                    void (^ _Nullable completion)(void));

NS_ASSUME_NONNULL_END
