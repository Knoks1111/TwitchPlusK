#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "System/7tv-system-chat-top-banner.h"

static NSString *const S7TVHideChatMessagesAndAnnouncementsKey =
    @"s7tv_hide_chat_messages_and_announcements";
static NSString *const S7TVHideChatGoalsAndLeaderboardKey =
    @"s7tv_hide_chat_goals_and_leaderboard";

typedef NS_ENUM(NSInteger, S7TVChatBannerGroup) {
    S7TVChatBannerGroupNone = -1,
    S7TVChatBannerGroupMessages = 0,
    S7TVChatBannerGroupGoals,
};

static char kS7TVChatTopBannerDetachedKey;
static char kS7TVChatTopBannerParentKey;
static char kS7TVChatTopBannerIndexKey;

// Parent en faible référence : la vue détachée ne doit pas le retenir.
@interface S7TVChatBannerWeakRef : NSObject
@property (nonatomic, weak) UIView *view;
@end

@implementation S7TVChatBannerWeakRef
@end

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

// Classes résolues une seule fois : le hook passe sur chaque vue de l'app et
// NSClassFromString sur un nom Swift est loin d'être gratuit.
typedef struct {
    Class cls;
    S7TVChatBannerGroup group;
} S7TVChatBannerTarget;

static S7TVChatBannerTarget *s7tv_bannerTargets;
static NSUInteger s7tv_bannerTargetCount;

static void s7tv_resolveChatBannerTargets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *messages = @[@"Twitch.TopChatCalloutView",
                                          @"Twitch.VerticalContentScrollView"];
        NSArray<NSString *> *goals = @[@"Twitch.CreatorGoalsBannerView",
                                        @"Twitch.LeaderboardBannerView",
                                        @"TwitchCoreUI.StandardToolbar"];
        NSUInteger capacity = messages.count + goals.count;
        if (capacity == 0) return;
        S7TVChatBannerTarget *targets = calloc(capacity, sizeof(S7TVChatBannerTarget));
        if (!targets) return;
        NSUInteger index = 0;
        for (NSString *name in messages) {
            Class cls = NSClassFromString(name);
            if (cls) targets[index++] = (S7TVChatBannerTarget){cls, S7TVChatBannerGroupMessages};
        }
        for (NSString *name in goals) {
            Class cls = NSClassFromString(name);
            if (cls) targets[index++] = (S7TVChatBannerTarget){cls, S7TVChatBannerGroupGoals};
        }
        s7tv_bannerTargets = targets;
        s7tv_bannerTargetCount = index;
    });
}

// Une seule remontée de hiérarchie, comparaisons de pointeurs : les variantes
// sont des sous-classes des cibles.
static S7TVChatBannerGroup s7tv_chatBannerGroupForView(UIView *view) {
    if (s7tv_bannerTargetCount == 0) {
        s7tv_resolveChatBannerTargets();
        if (s7tv_bannerTargetCount == 0) return S7TVChatBannerGroupNone;
    }
    for (Class candidate = view.class; candidate;
         candidate = class_getSuperclass(candidate)) {
        for (NSUInteger i = 0; i < s7tv_bannerTargetCount; i++) {
            if (candidate == s7tv_bannerTargets[i].cls) {
                return s7tv_bannerTargets[i].group;
            }
        }
    }
    return S7TVChatBannerGroupNone;
}

// hidden avant détachage : évite l'image d'une frame si Twitch ré-ajoute.
static void s7tv_detachChatBanner(UIView *view) {
    UIView *parent = view.superview;
    if (parent) {
        NSUInteger index = [parent.subviews indexOfObject:view];
        S7TVChatBannerWeakRef *ref = [S7TVChatBannerWeakRef new];
        ref.view = parent;
        objc_setAssociatedObject(view, &kS7TVChatTopBannerParentKey, ref,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kS7TVChatTopBannerIndexKey,
                                 @(index == NSNotFound ? 0 : index),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = YES;
    [view removeFromSuperview];
    objc_setAssociatedObject(view, &kS7TVChatTopBannerDetachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void s7tv_restoreChatBanner(UIView *view) {
    if (![objc_getAssociatedObject(view, &kS7TVChatTopBannerDetachedKey) boolValue]) {
        return;
    }
    view.hidden = NO;
    S7TVChatBannerWeakRef *ref = objc_getAssociatedObject(view, &kS7TVChatTopBannerParentKey);
    NSNumber *index = objc_getAssociatedObject(view, &kS7TVChatTopBannerIndexKey);
    UIView *parent = ref.view;
    if (parent) {
        NSUInteger position = index.unsignedIntegerValue;
        if (position <= parent.subviews.count) {
            [parent insertSubview:view atIndex:position];
        } else {
            [parent addSubview:view];
        }
    }
    objc_setAssociatedObject(view, &kS7TVChatTopBannerDetachedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kS7TVChatTopBannerParentKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kS7TVChatTopBannerIndexKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void s7tv_handleChatTopBannerViewLifecycle(UIView *view) {
    if (!view || !view.window) return;

    S7TVChatBannerGroup group = s7tv_chatBannerGroupForView(view);
    if (group == S7TVChatBannerGroupNone) {
        if ([objc_getAssociatedObject(view, &kS7TVChatTopBannerDetachedKey) boolValue]) {
            s7tv_restoreChatBanner(view);
        }
        return;
    }
    BOOL detached = [objc_getAssociatedObject(
        view, &kS7TVChatTopBannerDetachedKey) boolValue];

    BOOL enabled = group == S7TVChatBannerGroupMessages
        ? s7tv_hideChatMessagesAndAnnouncementsEnabled()
        : s7tv_hideChatGoalsAndLeaderboardEnabled();
    if (!enabled) {
        s7tv_restoreChatBanner(view);
        return;
    }

    // Déjà détaché et toujours sans parent : Twitch ne l'a pas ré-ajouté.
    if (detached && !view.superview) return;
    s7tv_detachChatBanner(view);
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