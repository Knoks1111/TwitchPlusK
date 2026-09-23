/* Détection et injection des chats Twitch. */

#import "Chat/7tv-chat-integration.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Chat/7tv-chat-custom-vod.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Chat/7tv-chat-reply-thread-panel.h"
#import "Chat/7tv-chat-tokenizer.h"
#import "Emote/7tv-emote-provider.h"
#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import "Badge/7tv-badge-provider.h"
#import "Localization/7tv-localization-manager.h"
#import "Core/7tv-core-manager.h"
#import "Core/7tv-channel-resolver.h"
#import "System/7tv-system-player-reload.h"
#import <objc/runtime.h>

static const char kS7TVChatCustomInstalledView = 21;
static const char kS7TVVODChatCustomInstalledView = 22;
static const char kS7TVVODChatMessageStore = 23;
static __weak SevenTVChatCustomView *s_activeChatCustomView = nil;
static __weak UIView *s_activeNativeChatView = nil;
static __weak UIView *s_activeVODNativeChatView = nil;
static __weak SevenTVChatCustomView *s_activeVODChatCustomView = nil;
static NSMapTable<UIView *, SevenTVChatCustomView *> *s_chatCustomViewsByNative = nil;
static NSMapTable<UIView *, SevenTVChatCustomView *> *s_vodChatCustomViewsByNative = nil;
static BOOL s_chatReloadScheduled = NO;
static BOOL s_vodChatReloadScheduled = NO;
static __weak SevenTVChatCustomView *s_scheduledVODChatCustomView = nil;
static __weak UIView *s_scheduledVODNativeChatView = nil;
static BOOL s_chatRetokenizationScheduled = NO;
static BOOL s_chatConfigurationReloadScheduled = NO;

static NSArray<S7TVChatToken *> *s7tv_chatTokensForMessage(S7TVChatMessage *message);
static void s7tv_retokenizeAllChatStoresWithCompletion(void (^completion)(void));
static void s7tv_reloadActiveChatCustomViewOnMain(void);
static void s7tv_reloadActiveChatCustomViewForConfigurationOnMain(void);
static void s7tv_scheduleVODChatCustomReload(SevenTVChatCustomView *customView,
                                              UIView *nativeView);
static void s7tv_scheduleChatRetokenization(void);
static void s7tv_scheduleChatConfigurationReload(void);
static BOOL s7tv_isOwnChatImplementationClass(NSString *className) {
    NSString *name = className.lowercaseString;
    return [name containsString:@"seventv"] || [name hasPrefix:@"s7tv"];
}

static BOOL s7tv_isChatCustomViewActuallyVisible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha <= 0.01) return NO;

    UIView *ancestor = view;
    NSUInteger depth = 0;
    while (ancestor && depth++ < 20) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
        ancestor = ancestor.superview;
    }
    return YES;
}

static NSMapTable<UIView *, SevenTVChatCustomView *> *s7tv_chatCustomViewRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_chatCustomViewsByNative = [NSMapTable weakToWeakObjectsMapTable];
    });
    return s_chatCustomViewsByNative;
}

static void s7tv_registerChatCustomView(UIView *nativeView,
                                        SevenTVChatCustomView *customView) {
    if (!nativeView || !customView) return;
    customView.s7tv_nativeTranscriptView = nativeView;
    [s7tv_chatCustomViewRegistry() setObject:customView forKey:nativeView];
}

static NSArray<SevenTVChatCustomView *> *s7tv_registeredChatCustomViews(void) {
    if (!s_chatCustomViewsByNative) return @[];

    NSMutableArray<SevenTVChatCustomView *> *views = [NSMutableArray array];
    for (SevenTVChatCustomView *view in s_chatCustomViewsByNative.objectEnumerator) {
        if (view) [views addObject:view];
    }
    return views;
}

static NSArray<SevenTVChatCustomView *> *s7tv_liveChatCustomViews(void) {
    NSMutableArray<SevenTVChatCustomView *> *views = [NSMutableArray array];
    for (SevenTVChatCustomView *view in s7tv_registeredChatCustomViews()) {
        UIView *nativeView = view.s7tv_nativeTranscriptView;
        if (!nativeView || !nativeView.window || !nativeView.superview ||
            !view.window) continue;
        [views addObject:view];
    }
    return views;
}

static NSMapTable<UIView *, SevenTVChatCustomView *> *s7tv_vodChatCustomViewRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_vodChatCustomViewsByNative = [NSMapTable weakToWeakObjectsMapTable];
    });
    return s_vodChatCustomViewsByNative;
}

static NSArray<SevenTVChatCustomView *> *s7tv_registeredVODChatCustomViews(void) {
    if (!s_vodChatCustomViewsByNative) return @[];

    NSMutableArray<SevenTVChatCustomView *> *views = [NSMutableArray array];
    for (SevenTVChatCustomView *view in s_vodChatCustomViewsByNative.objectEnumerator) {
        if (view) [views addObject:view];
    }
    return views;
}

static SevenTVChatCustomView *s7tv_selectInteractionChatCustomView(void) {
    NSArray<SevenTVChatCustomView *> *views = s7tv_liveChatCustomViews();
    SevenTVChatCustomView *current = s_activeChatCustomView;

    // Garder la vue visible actuelle pendant la construction SwiftUI.
    if (current && [views containsObject:current] &&
        s7tv_isChatCustomViewActuallyVisible(current)) {
        s_activeNativeChatView = current.s7tv_nativeTranscriptView;
        return current;
    }

    for (SevenTVChatCustomView *view in views) {
        if (!s7tv_isChatCustomViewActuallyVisible(view)) continue;
        s_activeChatCustomView = view;
        s_activeNativeChatView = view.s7tv_nativeTranscriptView;
        return view;
    }

    // Garder une vue vivante entre deux passes de layout.
    if (current && [views containsObject:current]) {
        s_activeNativeChatView = current.s7tv_nativeTranscriptView;
        return current;
    }
    SevenTVChatCustomView *fallback = views.firstObject;
    if (fallback) {
        s_activeChatCustomView = fallback;
        s_activeNativeChatView = fallback.s7tv_nativeTranscriptView;
    }
    return fallback;
}

static NSArray<SevenTVChatCustomView *> *s7tv_viewsForChatUpdate(void) {
    NSArray<SevenTVChatCustomView *> *views = s7tv_liveChatCustomViews();
    if (views.count > 0) return views;

    SevenTVChatCustomView *active = s7tv_selectInteractionChatCustomView();
    return active ? @[active] : @[];
}

void s7tv_refreshChatMessageInViews(NSString *messageID,
                                           SevenTVChatCustomView *sourceView,
                                           void (^completion)(void)) {
    NSMutableArray<SevenTVChatCustomView *> *views =
        [s7tv_viewsForChatUpdate() mutableCopy];
    if (!views) views = [NSMutableArray array];
    if (sourceView && ![views containsObject:sourceView]) {
        [views insertObject:sourceView atIndex:0];
    }
    if (views.count == 0) {
        if (completion) completion();
        return;
    }

    __block NSUInteger remaining = views.count;
    void (^finishOne)(void) = ^{
        if (remaining > 0) remaining -= 1;
        if (remaining == 0 && completion) completion();
    };
    for (SevenTVChatCustomView *view in views) {
        [view refreshMessageWithID:messageID animated:YES completion:finishOne];
    }
}

static UIView *s7tv_findVisibleChatInputViewInWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return nil;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
    UIView *bestCandidate = nil;
    CGFloat bestBottom = -CGFLOAT_MAX;
    while (views.count > 0) {
        UIView *view = views.firstObject;
        [views removeObjectAtIndex:0];
        if (view.hidden || view.alpha <= 0.01) continue;
        if ([NSStringFromClass(view.class) isEqualToString:@"Twitch.ChatInputView"] &&
            view.window == window && !CGRectIsEmpty(view.bounds)) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            if (CGRectIntersectsRect(frame, window.bounds) && CGRectGetMaxY(frame) > bestBottom) {
                bestCandidate = view;
                bestBottom = CGRectGetMaxY(frame);
            }
        }
        [views addObjectsFromArray:view.subviews];
    }
    return bestCandidate;
}

UIView *s7tv_findChatInputView(void) {
    // Utiliser la fenêtre du transcript actif pendant un changement de chaîne.
    SevenTVChatCustomView *activeView = s7tv_selectInteractionChatCustomView();
    UIWindow *activeWindow = activeView.window;
    UIView *activeCandidate = s7tv_findVisibleChatInputViewInWindow(activeWindow);
    if (activeCandidate) return activeCandidate;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window == activeWindow) continue;
            UIView *candidate = s7tv_findVisibleChatInputViewInWindow(window);
            if (candidate) return candidate;
        }
    }
    return nil;
}

SevenTVChatCustomView *s7tv_activeChatCustomView(void) {
    return s7tv_selectInteractionChatCustomView();
}

static void s7tv_reloadActiveChatCustomViewOnMain(void) {
    for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
        [view reloadMessages];
    }
    [[S7TVReplyThreadPanel sharedPanel] refreshIfNeeded];
}

void s7tv_reloadActiveChatCustomView(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_reloadActiveChatCustomViewOnMain();
    });
}

void s7tv_reloadActiveChatCustomViewAnimated(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
            [view refreshVisibleMessageContentIfFrozen];
            [view reloadMessagesAnimated:YES];
        }
        [[S7TVReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
    });
}

void s7tv_reloadActiveChatMessage(NSString *messageID) {
    if (!messageID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
            [view refreshMessageWithID:messageID animated:YES];
        }
        [[S7TVReplyThreadPanel sharedPanel]
            refreshMessageIfNeededWithID:messageID excludingView:nil];
    });
}

void s7tv_applyModerationStateToRetainedMessage(NSString *messageID,
                                                S7TVChatMessageState state,
                                                S7TVChatModerationKind moderationKind,
                                                NSInteger durationSeconds) {
    if (!messageID.length) return;
    dispatch_block_t apply = ^{
        for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
            [view applyModerationState:state
             toDisplayedMessageWithID:messageID
                      moderationKind:moderationKind
                     durationSeconds:durationSeconds];
        }
        [[S7TVReplyThreadPanel sharedPanel]
            applyModerationState:state
             toRetainedMessageWithID:messageID
                      moderationKind:moderationKind
                     durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void s7tv_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString *authorLogin,
                                                    S7TVChatModerationKind moderationKind,
                                                    NSInteger durationSeconds) {
    if (!authorUserID.length && !authorLogin.length) return;
    dispatch_block_t apply = ^{
        for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
            [view applyModerationToDisplayedMessagesForUserID:authorUserID
                                                   authorLogin:authorLogin
                                                moderationKind:moderationKind
                                               durationSeconds:durationSeconds];
        }
        [[S7TVReplyThreadPanel sharedPanel]
            applyModerationToRetainedMessagesForUserID:authorUserID
                                           authorLogin:authorLogin
                                        moderationKind:moderationKind
                                       durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void s7tv_applyModerationToAllRetainedMessages(void) {
    dispatch_block_t apply = ^{
        for (SevenTVChatCustomView *view in s7tv_viewsForChatUpdate()) {
            [view applyModerationToAllDisplayedMessages];
        }
        [[S7TVReplyThreadPanel sharedPanel] applyModerationToAllRetainedMessages];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

static void s7tv_reloadActiveChatCustomViewForConfigurationOnMain(void) {
    NSMutableArray<SevenTVChatCustomView *> *views =
        [s7tv_viewsForChatUpdate() mutableCopy];
    for (SevenTVChatCustomView *view in s7tv_registeredVODChatCustomViews()) {
        if (![views containsObject:view]) [views addObject:view];
    }
    for (SevenTVChatCustomView *view in views) {
        [view refreshVisibleMessageContentIfFrozen];
        [view reloadMessages];
    }
    [[S7TVReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
}

void s7tv_reloadActiveChatCustomViewForConfiguration(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_reloadActiveChatCustomViewForConfigurationOnMain();
    });
}

static const NSTimeInterval kS7TVChatReloadDelay = 0.05;

static void s7tv_scheduleVODChatCustomReloadOnMain(SevenTVChatCustomView *customView,
                                                    UIView *nativeView) {
    if (!customView || !nativeView) return;

    s_scheduledVODChatCustomView = customView;
    s_scheduledVODNativeChatView = nativeView;
    if (s_vodChatReloadScheduled) return;

    s_vodChatReloadScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(kS7TVChatReloadDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SevenTVChatCustomView *targetView = s_scheduledVODChatCustomView;
        UIView *targetNativeView = s_scheduledVODNativeChatView;
        s_scheduledVODChatCustomView = nil;
        s_scheduledVODNativeChatView = nil;
        s_vodChatReloadScheduled = NO;

        if (!targetView || !targetNativeView ||
            targetView != s_activeVODChatCustomView ||
            targetNativeView != s_activeVODNativeChatView ||
            targetView.s7tv_nativeTranscriptView != targetNativeView ||
            !targetNativeView.window || !targetNativeView.superview) {
            return;
        }
        [targetView reloadMessages];
    });
}

static void s7tv_scheduleVODChatCustomReload(SevenTVChatCustomView *customView,
                                              UIView *nativeView) {
    if (!customView || !nativeView) return;
    if (NSThread.isMainThread) {
        s7tv_scheduleVODChatCustomReloadOnMain(customView, nativeView);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_scheduleVODChatCustomReloadOnMain(customView, nativeView);
        });
    }
}

void s7tv_scheduleChatCustomReload(void) {
    @synchronized ([SevenTVManager class]) {
        if (s_chatReloadScheduled) return;
        s_chatReloadScheduled = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(kS7TVChatReloadDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @synchronized ([SevenTVManager class]) {
                s_chatReloadScheduled = NO;
            }
            s7tv_reloadActiveChatCustomViewOnMain();
        });
    });
}

static NSArray<S7TVChatToken *> *s7tv_chatTokensForMessage(S7TVChatMessage *message) {
    if (!message) return @[];
    return [SevenTVChatTokenizer tokenizeText:message.rawText ?: @""
                              twitchEmotesTag:message.twitchEmotesTag ?: @""
                                twitchGIFsTag:message.twitchGIFsTag ?: @""
                                      providers:s7tv_chatEmoteProviders()];
}

static NSArray<S7TVChatMessageStore *> *s7tv_vodMessageStores(void) {
    NSMutableArray<S7TVChatMessageStore *> *stores = [NSMutableArray array];
    for (SevenTVChatCustomView *view in s7tv_registeredVODChatCustomViews()) {
        UIView *nativeView = view.s7tv_nativeTranscriptView;
        S7TVChatMessageStore *store = nativeView
            ? objc_getAssociatedObject(nativeView, &kS7TVVODChatMessageStore) : nil;
        if ([store isKindOfClass:S7TVChatMessageStore.class] &&
            ![stores containsObject:store]) {
            [stores addObject:store];
        }
    }
    return stores;
}

static void s7tv_retokenizeAllChatStoresWithCompletion(void (^completion)(void)) {
    NSMutableArray<S7TVChatMessageStore *> *stores = [NSMutableArray array];
    S7TVChatMessageStore *liveStore = [SevenTVManager sharedManager].chatMessageStore;
    if (liveStore) [stores addObject:liveStore];
    for (S7TVChatMessageStore *store in s7tv_vodMessageStores()) {
        if (![stores containsObject:store]) [stores addObject:store];
    }

    dispatch_group_t group = dispatch_group_create();
    for (S7TVChatMessageStore *store in stores) {
        dispatch_group_enter(group);
        [store retokenizeMessagesUsingBlock:^NSArray<S7TVChatToken *> *
            (S7TVChatMessage *message) {
            return s7tv_chatTokensForMessage(message);
        } completion:^{
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (completion) completion();
    });
}

static void s7tv_retokenizeChatStoresAndReload(void) {
    s7tv_retokenizeAllChatStoresWithCompletion(^{
        [[S7TVReplyThreadPanel sharedPanel]
            retokenizeVisibleMessagesWithCompletion:^{
            s7tv_scheduleChatConfigurationReload();
        }];
    });
}

static void s7tv_scheduleChatRetokenization(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_scheduleChatRetokenization();
        });
        return;
    }
    if (s_chatRetokenizationScheduled) return;

    s_chatRetokenizationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        s_chatRetokenizationScheduled = NO;
        s7tv_retokenizeChatStoresAndReload();
    });
}

static void s7tv_scheduleChatConfigurationReload(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_scheduleChatConfigurationReload();
        });
        return;
    }
    if (s_chatConfigurationReloadScheduled) return;

    s_chatConfigurationReloadScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        s_chatConfigurationReloadScheduled = NO;
        s7tv_reloadActiveChatCustomViewForConfigurationOnMain();
    });
}

static BOOL s7tv_isChatReplayResponder(UIResponder *responder) {
    if (!responder) return NO;
    NSString *className = NSStringFromClass(responder.class);
    return [className isEqualToString:@"Twitch.ChatReplayTableViewController"] ||
           [className isEqualToString:@"Twitch.ChatReplayViewController"] ||
           [className isEqualToString:@"Twitch.ChatReplayListViewController"];
}

static BOOL s7tv_viewBelongsToCustomChat(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:SevenTVChatCustomView.class]) return YES;
    }
    return NO;
}

static UITableView *s7tv_replayTableForView(UIView *view) {
    if (!view) return nil;
    if (s7tv_viewBelongsToCustomChat(view)) return nil;

    UITableView *tableView = nil;
    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 16; depth++, cursor = cursor.superview) {
        if ([cursor isKindOfClass:UITableView.class]) {
            tableView = (UITableView *)cursor;
            break;
        }
    }
    if (!tableView || !tableView.superview || !tableView.window) return nil;

    UIResponder *responder = tableView;
    for (NSUInteger depth = 0; responder && depth < 16; depth++, responder = responder.nextResponder) {
        if (s7tv_isChatReplayResponder(responder)) return tableView;
    }
    return nil;
}

static BOOL s7tv_isNativeChatTranscriptView(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass(view.class);
    NSString *lowerName = className.lowercaseString;
    if (s7tv_isOwnChatImplementationClass(className)) return NO;
    // Seul le transcript UIView/table doit être remplacé.
    return [lowerName hasSuffix:@"chattranscriptview"];
}

static void s7tv_installChatCustomView(UIView *chatView, BOOL isVOD) {
    if (!chatView || s7tv_viewBelongsToCustomChat(chatView)) return;
    if (!isVOD) s_activeNativeChatView = chatView;

    UIView *container = chatView.superview;
    UIStackView *stack = [container isKindOfClass:UIStackView.class]
        ? (UIStackView *)container : nil;
    if (!container) return;

    s7tv_setPlayerReloadVODState(chatView, isVOD);

    NSInteger stackIndex = stack
        ? [stack.arrangedSubviews indexOfObject:chatView] : NSNotFound;
    if (stack && stackIndex == NSNotFound) return;

    const void *associationKey = isVOD
        ? &kS7TVVODChatCustomInstalledView : &kS7TVChatCustomInstalledView;
    NSMapTable<UIView *, SevenTVChatCustomView *> *registry = isVOD
        ? s7tv_vodChatCustomViewRegistry() : s7tv_chatCustomViewRegistry();

    SevenTVChatCustomView *existing =
        objc_getAssociatedObject(chatView, associationKey);
    if (existing && existing.superview == container) {
        existing.s7tv_nativeTranscriptView = chatView;
        [registry setObject:existing forKey:chatView];
        chatView.hidden = YES;
        existing.hidden = NO;
        if (isVOD) {
            s_activeVODNativeChatView = chatView;
            s_activeVODChatCustomView = existing;
        } else {
            s7tv_registerChatCustomView(chatView, existing);
            s_activeChatCustomView = existing;
            [existing reloadMessages];
        }
        return;
    }
    if (existing) [existing removeFromSuperview];

    S7TVChatMessageStore *store = [SevenTVManager sharedManager].chatMessageStore;
    if (isVOD) {
        store = objc_getAssociatedObject(chatView, &kS7TVVODChatMessageStore);
        if (![store isKindOfClass:S7TVChatMessageStore.class]) {
            store = [[S7TVChatMessageStore alloc] init];
            objc_setAssociatedObject(chatView, &kS7TVVODChatMessageStore, store,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    SevenTVChatCustomView *customView = [[SevenTVChatCustomView alloc]
        initWithStore:store];
    customView.delegate = [S7TVReplyThreadPanel sharedPanel];
    __weak SevenTVChatCustomView *weakCustomView = customView;
    customView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        SevenTVChatCustomView *sourceView = weakCustomView;
        if (!sourceView) return;
        [[S7TVReplyThreadPanel sharedPanel]
            selectReplyTargetForMessageID:messageID
                                 username:username
                               sourceView:sourceView];
    };

    if (!stack) {
        chatView.hidden = YES;
        customView.translatesAutoresizingMaskIntoConstraints = NO;
        [container insertSubview:customView aboveSubview:chatView];
        [NSLayoutConstraint activateConstraints:@[
            [customView.leadingAnchor constraintEqualToAnchor:chatView.leadingAnchor],
            [customView.trailingAnchor constraintEqualToAnchor:chatView.trailingAnchor],
            [customView.topAnchor constraintEqualToAnchor:chatView.topAnchor],
            [customView.bottomAnchor constraintEqualToAnchor:chatView.bottomAnchor],
        ]];
    } else {
        chatView.hidden = YES;
        [stack insertArrangedSubview:customView atIndex:stackIndex];
    }

    objc_setAssociatedObject(chatView, associationKey, customView,
                             OBJC_ASSOCIATION_RETAIN);
    customView.s7tv_nativeTranscriptView = chatView;
    [registry setObject:customView forKey:chatView];

    if (isVOD) {
        s_activeVODNativeChatView = chatView;
        s_activeVODChatCustomView = customView;
    } else {
        s7tv_registerChatCustomView(chatView, customView);
        s_activeChatCustomView = customView;
    }
    [customView reloadMessages];
}

void s7tv_receiveVODMessage(S7TVChatMessage *message) {
    if (!message.messageID.length || !message.rawText.length) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SevenTVManager *manager = [SevenTVManager sharedManager];
        if (!manager.chatCustomTestEnabled) return;

        UIView *nativeView = s_activeVODNativeChatView;
        SevenTVChatCustomView *customView = s_activeVODChatCustomView;
        S7TVChatMessageStore *store = nativeView
            ? objc_getAssociatedObject(nativeView, &kS7TVVODChatMessageStore) : nil;
        if (!nativeView || !customView || !store ||
            customView.s7tv_nativeTranscriptView != nativeView) {
            return;
        }
        if ([store messageWithID:message.messageID]) return;

        [store addMessage:message];
        s7tv_scheduleVODChatCustomReload(customView, nativeView);
    });
}

void s7tv_applyChatCustomToggle(void) {
    SevenTVManager *manager = [SevenTVManager sharedManager];
    if (!manager.chatCustomTestEnabled) {
        // Restaurer tous les transcripts natifs connus.
        for (SevenTVChatCustomView *view in s7tv_registeredChatCustomViews()) {
            UIView *nativeView = view.s7tv_nativeTranscriptView;
            nativeView.hidden = NO;
            view.hidden = YES;
        }
        for (SevenTVChatCustomView *view in s7tv_registeredVODChatCustomViews()) {
            UIView *nativeView = view.s7tv_nativeTranscriptView;
            nativeView.hidden = NO;
            view.hidden = YES;
        }
        s_activeChatCustomView = nil;
        s_activeNativeChatView = nil;
        s_activeVODChatCustomView = nil;
        s_activeVODNativeChatView = nil;
        return;
    }

    UIView *chatView = s_activeNativeChatView;
    if (chatView && chatView.superview && chatView.window) {
        s7tv_installChatCustomView(chatView, NO);
    }

    // Réinstaller les vues natives encore présentes après réactivation.
    for (SevenTVChatCustomView *view in s7tv_registeredChatCustomViews()) {
        UIView *nativeView = view.s7tv_nativeTranscriptView;
        if (!nativeView || nativeView == chatView || !nativeView.window ||
            !nativeView.superview) continue;
        s7tv_installChatCustomView(nativeView, NO);
    }
    UIView *vodChatView = s_activeVODNativeChatView;
    if (vodChatView && vodChatView.superview && vodChatView.window) {
        s7tv_installChatCustomView(vodChatView, YES);
    }
    for (SevenTVChatCustomView *view in s7tv_registeredVODChatCustomViews()) {
        UIView *nativeView = view.s7tv_nativeTranscriptView;
        if (!nativeView || nativeView == vodChatView || !nativeView.window ||
            !nativeView.superview) continue;
        s7tv_installChatCustomView(nativeView, YES);
    }
    s7tv_selectInteractionChatCustomView();
}

void s7tv_handleNativeChatViewLifecycle(UIView *view) {
    if (!view) return;

    s7tv_installNativeReplayChatHook();

    BOOL isTable = [view isKindOfClass:UITableView.class];
    UITableView *replayTable = isTable ? s7tv_replayTableForView(view) : nil;
    if (replayTable == (UITableView *)view) {
        s7tv_setPlayerReloadVODState(view, YES);
        S7TVChannelResolverRefresh();
        UITableView *retainedTable = (UITableView *)view;
        void (^install)(void) = ^{
            if (retainedTable.window && retainedTable.superview &&
                [SevenTVManager sharedManager].chatCustomTestEnabled) {
                s7tv_installChatCustomView(retainedTable, YES);
            }
        };
        if (NSThread.isMainThread) install();
        else dispatch_async(dispatch_get_main_queue(), install);
        return;
    }

    if (!s7tv_isNativeChatTranscriptView(view) ||
        !view.window || !view.superview) {
        return;
    }

    s7tv_setPlayerReloadVODState(view, NO);
    s_activeNativeChatView = view;
    s7tv_applyChatCustomToggle();
}

void s7tv_setupChatCustomIntegration(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SevenTVManager *manager = [SevenTVManager sharedManager];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

        // Retokeniser seulement quand la résolution des emotes change.
        __block NSInteger lastEmoteResolution =
            [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
        [center addObserverForName:S7TVChatCustomToggleDidChangeNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            s7tv_applyChatCustomToggle();
        }];
        [center addObserverForName:S7TVEmoteCatalogDidUpdateNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            s7tv_scheduleChatRetokenization();
        }];
        // Retokeniser après chaque mise à jour du catalogue provider.
        [center addObserverForName:S7TVProviderCatalogDidUpdateNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            s7tv_scheduleChatRetokenization();
        }];
        // Recalculer les tokens après un changement de provider ou de Zero-Width.
        [center addObserverForName:S7TVEmoteProviderSettingsDidChangeNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            s7tv_scheduleChatRetokenization();
        }];
        [center addObserverForName:S7TVChatAppearanceConfigDidChangeNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            NSInteger currentResolution =
                [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
            BOOL resolutionChanged = currentResolution != lastEmoteResolution;
            lastEmoteResolution = currentResolution;
            if (!resolutionChanged) {
                s7tv_scheduleChatConfigurationReload();
                return;
            }
            s7tv_scheduleChatRetokenization();
        }];
        for (NSString *notificationName in @[
            S7TVBadgesCatalogUpdatedNotification,
            S7TVLanguageDidChangeNotification
        ]) {
            [center addObserverForName:notificationName object:nil queue:nil
                            usingBlock:^(__unused NSNotification *note) {
                s7tv_scheduleChatConfigurationReload();
            }];
        }
    });
}
