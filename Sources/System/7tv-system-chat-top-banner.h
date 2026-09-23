#ifndef S7TV_SYSTEM_CHAT_TOP_BANNER_H
#define S7TV_SYSTEM_CHAT_TOP_BANNER_H

#import <UIKit/UIKit.h>

// Bannières du haut du chat : messages/annonces et goals/leaderboard.
BOOL s7tv_hideChatMessagesAndAnnouncementsEnabled(void);
void s7tv_setHideChatMessagesAndAnnouncementsEnabled(BOOL enabled);

BOOL s7tv_hideChatGoalsAndLeaderboardEnabled(void);
void s7tv_setHideChatGoalsAndLeaderboardEnabled(BOOL enabled);

void s7tv_handleChatTopBannerViewLifecycle(UIView *view);
void s7tv_applyChatTopBannerSettings(void);

#endif
