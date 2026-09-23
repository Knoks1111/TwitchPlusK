#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "System/7tv-system-chat-top-banner.h"

static NSString *const S7TVHideChatMessagesAndAnnouncementsKey =
    @"s7tv_hide_chat_messages_and_announcements";
static NSString *const S7TVHideChatGoalsAndLeaderboardKey =
    @"s7tv_hide_chat_goals_and_leaderboard";

// État par vue, via objets associés.
static char kS7TVChatTopBannerManagedKey;
static char kS7TVChatTopBannerOriginalHiddenKey;
static char kS7TVChatTopBannerZeroHeightConstraintKey;

BOOL s7tv_hideChatMessagesAndAnnouncementsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:S7TVHideChatMessagesAndAnnouncementsKey];
}

void s7tv_setHideChatMessagesAndAnnouncementsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                           forKey:S7TVHideChatMessagesAndAnnouncementsKey];
    s7tv_applyChatTopBannerSettings();
}

BOOL s7tv_hideChatGoalsAndLeaderboardEnabled(void) {
    return [NSUserDefaults.standardUserDefaults
        boolForKey:S7TVHideChatGoalsAndLeaderboardKey];
}

void s7tv_setHideChatGoalsAndLeaderboardEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                           forKey:S7TVHideChatGoalsAndLeaderboardKey];
    s7tv_applyChatTopBannerSettings();
}

static BOOL s7tv_chatTopBannerClassEnabled(NSString *className) {
    if ([className isEqualToString:@"Twitch.VerticalContentScrollView"]) {
        return s7tv_hideChatMessagesAndAnnouncementsEnabled();
    }
    if ([className isEqualToString:@"Twitch.TopChatCalloutView"]) {
        return s7tv_hideChatMessagesAndAnnouncementsEnabled();
    }
    if ([className isEqualToString:@"Twitch.CreatorGoalsBannerView"]) {
        return s7tv_hideChatGoalsAndLeaderboardEnabled();
    }
    if ([className isEqualToString:@"Twitch.LeaderboardBannerView"]) {
        return s7tv_hideChatGoalsAndLeaderboardEnabled();
    }
    return NO;
}

static BOOL s7tv_isChatTopBannerTargetClass(NSString *className) {
    return [className isEqualToString:@"Twitch.VerticalContentScrollView"] ||
           [className isEqualToString:@"Twitch.TopChatCalloutView"] ||
           [className isEqualToString:@"Twitch.CreatorGoalsBannerView"] ||
           [className isEqualToString:@"Twitch.LeaderboardBannerView"];
}

// Retour à l'état d'origine.
static void s7tv_restoreChatTopBannerView(UIView *view) {
    NSNumber *originalHidden = objc_getAssociatedObject(
        view, &kS7TVChatTopBannerOriginalHiddenKey);
    NSLayoutConstraint *zeroHeight = objc_getAssociatedObject(
        view, &kS7TVChatTopBannerZeroHeightConstraintKey);

    zeroHeight.active = NO;
    if (originalHidden) view.hidden = originalHidden.boolValue;

    objc_setAssociatedObject(view, &kS7TVChatTopBannerManagedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kS7TVChatTopBannerOriginalHiddenKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view,
                             &kS7TVChatTopBannerZeroHeightConstraintKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void s7tv_handleChatTopBannerViewLifecycle(UIView *view) {
    if (!view || !view.window) return;

    NSString *className = NSStringFromClass(view.class);
    if (!s7tv_isChatTopBannerTargetClass(className)) return;

    BOOL enabled = s7tv_chatTopBannerClassEnabled(className);
    BOOL managed = [objc_getAssociatedObject(
        view, &kS7TVChatTopBannerManagedKey) boolValue];
    if (!enabled) {
        if (managed) s7tv_restoreChatTopBannerView(view);
        return;
    }
    if (managed) return;

    objc_setAssociatedObject(view, &kS7TVChatTopBannerManagedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kS7TVChatTopBannerOriginalHiddenKey,
                             @(view.hidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = YES;

    // Dans une UIStackView, hidden suffit (pas de contrainte).
    if (![view.superview isKindOfClass:UIStackView.class]) {
        NSLayoutConstraint *zeroHeight =
            [view.heightAnchor constraintEqualToConstant:0.0];
        zeroHeight.priority = UILayoutPriorityRequired;
        zeroHeight.active = YES;
        objc_setAssociatedObject(view,
                                 &kS7TVChatTopBannerZeroHeightConstraintKey,
                                 zeroHeight,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void s7tv_applyChatTopBannerSettingsToView(UIView *view) {
    s7tv_handleChatTopBannerViewLifecycle(view);
    for (UIView *subview in [view.subviews copy]) {
        s7tv_applyChatTopBannerSettingsToView(subview);
    }
}

void s7tv_applyChatTopBannerSettings(void) {
    // UI : main thread obligatoire.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_applyChatTopBannerSettings();
        });
        return;
    }

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        s7tv_applyChatTopBannerSettingsToView(window);
    }
}
