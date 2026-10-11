/* Détection et injection des chats Twitch. */

#import "Chat/tpK-chat-integration.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Chat/tpK-chat-custom-vod.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Chat/tpK-chat-reply-thread-panel.h"
#import "Chat/tpK-chat-tokenizer.h"
#import "Emote/tpK-emote-provider.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-provider-settings.h"
#import "Emote/tpK-badge-provider.h"
#import "Localization/tpK-localization-manager.h"
#import "Core/tpK-core-manager.h"
#import "Core/tpK-channel-resolver.h"
#import "System/tpK-system-player-reload.h"
#import <objc/runtime.h>

static const char kTPKChatCustomInstalledView = 21;
static const char kTPKVODChatCustomInstalledView = 22;
static const char kTPKVODChatMessageStore = 23;
static __weak TPKChatCustomView *s_activeChatCustomView = nil;
static __weak UIView *s_activeNativeChatView = nil;
static __weak UIView *s_activeVODNativeChatView = nil;
static __weak TPKChatCustomView *s_activeVODChatCustomView = nil;
static NSMapTable<UIView *, TPKChatCustomView *> *s_chatCustomViewsByNative = nil;
static NSMapTable<UIView *, TPKChatCustomView *> *s_vodChatCustomViewsByNative = nil;
static BOOL s_chatReloadScheduled = NO;
static BOOL s_vodChatReloadScheduled = NO;
static __weak TPKChatCustomView *s_scheduledVODChatCustomView = nil;
static __weak UIView *s_scheduledVODNativeChatView = nil;
static BOOL s_chatRetokenizationScheduled = NO;
static BOOL s_chatConfigurationReloadScheduled = NO;

static NSArray<TPKChatToken *> *tpk_chatTokensForMessage(TPKChatMessage *message);
static void tpk_retokenizeAllChatStoresWithCompletion(void (^completion)(void));
static void tpk_reloadActiveChatCustomViewOnMain(void);
static void tpk_reloadActiveChatCustomViewForConfigurationOnMain(void);
static void tpk_scheduleVODChatCustomReload(TPKChatCustomView *customView,
                                              UIView *nativeView);
static void tpk_scheduleChatRetokenization(void);
static void tpk_scheduleChatConfigurationReload(void);
static BOOL tpk_isOwnChatImplementationClass(NSString *className) {
    NSString *name = className.lowercaseString;
    return [name containsString:@"seventv"] || [name hasPrefix:@"s7tv"];
}

static BOOL tpk_isChatCustomViewActuallyVisible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha <= 0.01) return NO;

    UIView *ancestor = view;
    NSUInteger depth = 0;
    while (ancestor && depth++ < 20) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
        ancestor = ancestor.superview;
    }
    return YES;
}

static NSMapTable<UIView *, TPKChatCustomView *> *tpk_chatCustomViewRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_chatCustomViewsByNative = [NSMapTable weakToWeakObjectsMapTable];
    });
    return s_chatCustomViewsByNative;
}

static void tpk_registerChatCustomView(UIView *nativeView,
                                        TPKChatCustomView *customView) {
    if (!nativeView || !customView) return;
    customView.tpk_nativeTranscriptView = nativeView;
    [tpk_chatCustomViewRegistry() setObject:customView forKey:nativeView];
}

static NSArray<TPKChatCustomView *> *tpk_registeredChatCustomViews(void) {
    if (!s_chatCustomViewsByNative) return @[];

    NSMutableArray<TPKChatCustomView *> *views = [NSMutableArray array];
    for (TPKChatCustomView *view in s_chatCustomViewsByNative.objectEnumerator) {
        if (view) [views addObject:view];
    }
    return views;
}

static NSArray<TPKChatCustomView *> *tpk_liveChatCustomViews(void) {
    NSMutableArray<TPKChatCustomView *> *views = [NSMutableArray array];
    for (TPKChatCustomView *view in tpk_registeredChatCustomViews()) {
        UIView *nativeView = view.tpk_nativeTranscriptView;
        if (!nativeView || !nativeView.window || !nativeView.superview ||
            !view.window) continue;
        [views addObject:view];
    }
    return views;
}

static NSMapTable<UIView *, TPKChatCustomView *> *tpk_vodChatCustomViewRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_vodChatCustomViewsByNative = [NSMapTable weakToWeakObjectsMapTable];
    });
    return s_vodChatCustomViewsByNative;
}

static NSArray<TPKChatCustomView *> *tpk_registeredVODChatCustomViews(void) {
    if (!s_vodChatCustomViewsByNative) return @[];

    NSMutableArray<TPKChatCustomView *> *views = [NSMutableArray array];
    for (TPKChatCustomView *view in s_vodChatCustomViewsByNative.objectEnumerator) {
        if (view) [views addObject:view];
    }
    return views;
}

static TPKChatCustomView *tpk_selectInteractionChatCustomView(void) {
    NSArray<TPKChatCustomView *> *views = tpk_liveChatCustomViews();
    TPKChatCustomView *current = s_activeChatCustomView;

    // Garder la vue visible actuelle pendant la construction SwiftUI.
    if (current && [views containsObject:current] &&
        tpk_isChatCustomViewActuallyVisible(current)) {
        s_activeNativeChatView = current.tpk_nativeTranscriptView;
        return current;
    }

    for (TPKChatCustomView *view in views) {
        if (!tpk_isChatCustomViewActuallyVisible(view)) continue;
        s_activeChatCustomView = view;
        s_activeNativeChatView = view.tpk_nativeTranscriptView;
        return view;
    }

    // Garder une vue vivante entre deux passes de layout.
    if (current && [views containsObject:current]) {
        s_activeNativeChatView = current.tpk_nativeTranscriptView;
        return current;
    }
    TPKChatCustomView *fallback = views.firstObject;
    if (fallback) {
        s_activeChatCustomView = fallback;
        s_activeNativeChatView = fallback.tpk_nativeTranscriptView;
    }
    return fallback;
}

static NSArray<TPKChatCustomView *> *tpk_viewsForChatUpdate(void) {
    NSArray<TPKChatCustomView *> *views = tpk_liveChatCustomViews();
    if (views.count > 0) return views;

    TPKChatCustomView *active = tpk_selectInteractionChatCustomView();
    return active ? @[active] : @[];
}

void tpk_refreshChatMessageInViews(NSString *messageID,
                                           TPKChatCustomView *sourceView,
                                           void (^completion)(void)) {
    NSMutableArray<TPKChatCustomView *> *views =
        [tpk_viewsForChatUpdate() mutableCopy];
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
    for (TPKChatCustomView *view in views) {
        [view refreshMessageWithID:messageID animated:YES completion:finishOne];
    }
}

static UIView *tpk_findVisibleChatInputViewInWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return nil;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
    UIView *bestCandidate = nil;
    CGFloat bestBottom = -CGFLOAT_MAX;
    while (views.count > 0) {
        UIView *view = views.firstObject;
        [views removeObjectAtIndex:0];
        if (view.hidden || view.alpha <= 0.01) continue;
        if (([view isKindOfClass:UITextView.class] ||
             [view isKindOfClass:UITextField.class]) &&
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

UIView *tpk_findChatInputView(void) {
    // Utiliser la fenêtre du transcript actif pendant un changement de chaîne.
    TPKChatCustomView *activeView = tpk_selectInteractionChatCustomView();
    UIWindow *activeWindow = activeView.window;
    UIView *activeCandidate = tpk_findVisibleChatInputViewInWindow(activeWindow);
    if (activeCandidate) return activeCandidate;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window == activeWindow) continue;
            UIView *candidate = tpk_findVisibleChatInputViewInWindow(window);
            if (candidate) return candidate;
        }
    }
    return nil;
}

TPKChatCustomView *tpk_activeChatCustomView(void) {
    return tpk_selectInteractionChatCustomView();
}

static void tpk_reloadActiveChatCustomViewOnMain(void) {
    for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
        [view reloadMessages];
    }
    [[TPKReplyThreadPanel sharedPanel] refreshIfNeeded];
}

void tpk_reloadActiveChatCustomView(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_reloadActiveChatCustomViewOnMain();
    });
}

void tpk_reloadActiveChatCustomViewAnimated(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
            [view refreshVisibleMessageContentIfFrozen];
            [view reloadMessagesAnimated:YES];
        }
        [[TPKReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
    });
}

void tpk_reloadActiveChatMessage(NSString *messageID) {
    if (!messageID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
            [view refreshMessageWithID:messageID animated:YES];
        }
        [[TPKReplyThreadPanel sharedPanel]
            refreshMessageIfNeededWithID:messageID excludingView:nil];
    });
}

void tpk_applyModerationStateToRetainedMessage(NSString *messageID,
                                                TPKChatMessageState state,
                                                TPKChatModerationKind moderationKind,
                                                NSInteger durationSeconds) {
    if (!messageID.length) return;
    dispatch_block_t apply = ^{
        for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
            [view applyModerationState:state
             toDisplayedMessageWithID:messageID
                      moderationKind:moderationKind
                     durationSeconds:durationSeconds];
        }
        [[TPKReplyThreadPanel sharedPanel]
            applyModerationState:state
             toRetainedMessageWithID:messageID
                      moderationKind:moderationKind
                     durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void tpk_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString *authorLogin,
                                                    TPKChatModerationKind moderationKind,
                                                    NSInteger durationSeconds) {
    if (!authorUserID.length && !authorLogin.length) return;
    dispatch_block_t apply = ^{
        for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
            [view applyModerationToDisplayedMessagesForUserID:authorUserID
                                                   authorLogin:authorLogin
                                                moderationKind:moderationKind
                                               durationSeconds:durationSeconds];
        }
        [[TPKReplyThreadPanel sharedPanel]
            applyModerationToRetainedMessagesForUserID:authorUserID
                                           authorLogin:authorLogin
                                        moderationKind:moderationKind
                                       durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void tpk_applyModerationToAllRetainedMessages(void) {
    dispatch_block_t apply = ^{
        for (TPKChatCustomView *view in tpk_viewsForChatUpdate()) {
            [view applyModerationToAllDisplayedMessages];
        }
        [[TPKReplyThreadPanel sharedPanel] applyModerationToAllRetainedMessages];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

static void tpk_reloadActiveChatCustomViewForConfigurationOnMain(void) {
    NSMutableArray<TPKChatCustomView *> *views =
        [tpk_viewsForChatUpdate() mutableCopy];
    for (TPKChatCustomView *view in tpk_registeredVODChatCustomViews()) {
        if (![views containsObject:view]) [views addObject:view];
    }
    for (TPKChatCustomView *view in views) {
        [view refreshVisibleMessageContentIfFrozen];
        [view reloadMessages];
    }
    [[TPKReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
}

void tpk_reloadActiveChatCustomViewForConfiguration(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_reloadActiveChatCustomViewForConfigurationOnMain();
    });
}

static const NSTimeInterval kTPKChatReloadDelay = 0.05;

static void tpk_scheduleVODChatCustomReloadOnMain(TPKChatCustomView *customView,
                                                    UIView *nativeView) {
    if (!customView || !nativeView) return;

    s_scheduledVODChatCustomView = customView;
    s_scheduledVODNativeChatView = nativeView;
    if (s_vodChatReloadScheduled) return;

    s_vodChatReloadScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(kTPKChatReloadDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TPKChatCustomView *targetView = s_scheduledVODChatCustomView;
        UIView *targetNativeView = s_scheduledVODNativeChatView;
        s_scheduledVODChatCustomView = nil;
        s_scheduledVODNativeChatView = nil;
        s_vodChatReloadScheduled = NO;

        if (!targetView || !targetNativeView ||
            targetView != s_activeVODChatCustomView ||
            targetNativeView != s_activeVODNativeChatView ||
            targetView.tpk_nativeTranscriptView != targetNativeView ||
            !targetNativeView.window || !targetNativeView.superview) {
            return;
        }
        [targetView reloadMessages];
    });
}

static void tpk_scheduleVODChatCustomReload(TPKChatCustomView *customView,
                                              UIView *nativeView) {
    if (!customView || !nativeView) return;
    if (NSThread.isMainThread) {
        tpk_scheduleVODChatCustomReloadOnMain(customView, nativeView);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_scheduleVODChatCustomReloadOnMain(customView, nativeView);
        });
    }
}

void tpk_scheduleChatCustomReload(void) {
    @synchronized ([TPKManager class]) {
        if (s_chatReloadScheduled) return;
        s_chatReloadScheduled = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(kTPKChatReloadDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @synchronized ([TPKManager class]) {
                s_chatReloadScheduled = NO;
            }
            tpk_reloadActiveChatCustomViewOnMain();
        });
    });
}

static NSArray<TPKChatToken *> *tpk_chatTokensForMessage(TPKChatMessage *message) {
    if (!message) return @[];
    return [TPKChatTokenizer tokenizeText:message.rawText ?: @""
                              twitchEmotesTag:message.twitchEmotesTag ?: @""
                                twitchGIFsTag:message.twitchGIFsTag ?: @""
                                      providers:tpk_chatEmoteProviders()];
}

static NSArray<TPKChatMessageStore *> *tpk_vodMessageStores(void) {
    NSMutableArray<TPKChatMessageStore *> *stores = [NSMutableArray array];
    for (TPKChatCustomView *view in tpk_registeredVODChatCustomViews()) {
        UIView *nativeView = view.tpk_nativeTranscriptView;
        TPKChatMessageStore *store = nativeView
            ? objc_getAssociatedObject(nativeView, &kTPKVODChatMessageStore) : nil;
        if ([store isKindOfClass:TPKChatMessageStore.class] &&
            ![stores containsObject:store]) {
            [stores addObject:store];
        }
    }
    return stores;
}

static void tpk_retokenizeAllChatStoresWithCompletion(void (^completion)(void)) {
    NSMutableArray<TPKChatMessageStore *> *stores = [NSMutableArray array];
    TPKChatMessageStore *liveStore = [TPKManager sharedManager].chatMessageStore;
    if (liveStore) [stores addObject:liveStore];
    for (TPKChatMessageStore *store in tpk_vodMessageStores()) {
        if (![stores containsObject:store]) [stores addObject:store];
    }

    dispatch_group_t group = dispatch_group_create();
    for (TPKChatMessageStore *store in stores) {
        dispatch_group_enter(group);
        [store retokenizeMessagesUsingBlock:^NSArray<TPKChatToken *> *
            (TPKChatMessage *message) {
            return tpk_chatTokensForMessage(message);
        } completion:^{
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (completion) completion();
    });
}

static void tpk_retokenizeChatStoresAndReload(void) {
    tpk_retokenizeAllChatStoresWithCompletion(^{
        [[TPKReplyThreadPanel sharedPanel]
            retokenizeVisibleMessagesWithCompletion:^{
            tpk_scheduleChatConfigurationReload();
        }];
    });
}

static void tpk_scheduleChatRetokenization(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_scheduleChatRetokenization();
        });
        return;
    }
    if (s_chatRetokenizationScheduled) return;

    s_chatRetokenizationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        s_chatRetokenizationScheduled = NO;
        tpk_retokenizeChatStoresAndReload();
    });
}

static void tpk_scheduleChatConfigurationReload(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_scheduleChatConfigurationReload();
        });
        return;
    }
    if (s_chatConfigurationReloadScheduled) return;

    s_chatConfigurationReloadScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        s_chatConfigurationReloadScheduled = NO;
        tpk_reloadActiveChatCustomViewForConfigurationOnMain();
    });
}

static BOOL tpk_isChatReplayResponder(UIResponder *responder) {
    if (!responder) return NO;
    NSString *className = NSStringFromClass(responder.class);
    return [className isEqualToString:@"Twitch.ChatReplayTableViewController"] ||
           [className isEqualToString:@"Twitch.ChatReplayViewController"] ||
           [className isEqualToString:@"Twitch.ChatReplayListViewController"];
}

static BOOL tpk_viewBelongsToCustomChat(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:TPKChatCustomView.class]) return YES;
    }
    return NO;
}

static UITableView *tpk_replayTableForView(UIView *view) {
    if (!view) return nil;
    if (tpk_viewBelongsToCustomChat(view)) return nil;

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
        if (tpk_isChatReplayResponder(responder)) return tableView;
    }
    return nil;
}

static BOOL tpk_isLiveChatMessageListView(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass(view.class);
    if (tpk_isOwnChatImplementationClass(className)) return NO;
    return [className isEqualToString:@"RCTScrollViewComponentView"] &&
           [view.accessibilityIdentifier isEqualToString:@"chat-message-list"];
}

static void tpk_installChatCustomView(UIView *chatView, BOOL isVOD) {
    if (!chatView || tpk_viewBelongsToCustomChat(chatView)) return;
    if (!isVOD) s_activeNativeChatView = chatView;

    UIView *container = chatView.superview;
    UIStackView *stack = [container isKindOfClass:UIStackView.class]
        ? (UIStackView *)container : nil;
    if (!container) return;

    tpk_setPlayerReloadVODState(chatView, isVOD);

    NSInteger stackIndex = stack
        ? [stack.arrangedSubviews indexOfObject:chatView] : NSNotFound;
    if (stack && stackIndex == NSNotFound) return;

    const void *associationKey = isVOD
        ? &kTPKVODChatCustomInstalledView : &kTPKChatCustomInstalledView;
    NSMapTable<UIView *, TPKChatCustomView *> *registry = isVOD
        ? tpk_vodChatCustomViewRegistry() : tpk_chatCustomViewRegistry();

    TPKChatCustomView *existing =
        objc_getAssociatedObject(chatView, associationKey);
    if (existing && existing.superview == container) {
        existing.tpk_nativeTranscriptView = chatView;
        [registry setObject:existing forKey:chatView];
        chatView.hidden = YES;
        existing.hidden = NO;
        if (isVOD) {
            s_activeVODNativeChatView = chatView;
            s_activeVODChatCustomView = existing;
        } else {
            tpk_registerChatCustomView(chatView, existing);
            s_activeChatCustomView = existing;
            [existing reloadMessages];
        }
        return;
    }
    if (existing) [existing removeFromSuperview];

    TPKChatMessageStore *store = [TPKManager sharedManager].chatMessageStore;
    if (isVOD) {
        store = objc_getAssociatedObject(chatView, &kTPKVODChatMessageStore);
        if (![store isKindOfClass:TPKChatMessageStore.class]) {
            store = [[TPKChatMessageStore alloc] init];
            objc_setAssociatedObject(chatView, &kTPKVODChatMessageStore, store,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    TPKChatCustomView *customView = [[TPKChatCustomView alloc]
        initWithStore:store];
    customView.delegate = [TPKReplyThreadPanel sharedPanel];
    __weak TPKChatCustomView *weakCustomView = customView;
    customView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        TPKChatCustomView *sourceView = weakCustomView;
        if (!sourceView) return;
        [[TPKReplyThreadPanel sharedPanel]
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
    customView.tpk_nativeTranscriptView = chatView;
    [registry setObject:customView forKey:chatView];

    if (isVOD) {
        s_activeVODNativeChatView = chatView;
        s_activeVODChatCustomView = customView;
    } else {
        tpk_registerChatCustomView(chatView, customView);
        s_activeChatCustomView = customView;
    }
    [customView reloadMessages];
    if (!isVOD) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [container layoutIfNeeded];
            [customView layoutIfNeeded];
        });
    }
}

void tpk_receiveVODMessage(TPKChatMessage *message) {
    if (!message.messageID.length || !message.rawText.length) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        TPKManager *manager = [TPKManager sharedManager];
        if (!manager.chatCustomTestEnabled) return;

        UIView *nativeView = s_activeVODNativeChatView;
        TPKChatCustomView *customView = s_activeVODChatCustomView;
        TPKChatMessageStore *store = nativeView
            ? objc_getAssociatedObject(nativeView, &kTPKVODChatMessageStore) : nil;
        if (!nativeView || !customView || !store ||
            customView.tpk_nativeTranscriptView != nativeView) {
            return;
        }
        if ([store messageWithID:message.messageID]) return;

        [store addMessage:message];
        tpk_scheduleVODChatCustomReload(customView, nativeView);
    });
}

void tpk_applyChatCustomToggle(void) {
    TPKManager *manager = [TPKManager sharedManager];
    if (!manager.chatCustomTestEnabled) {
        // Restaurer tous les transcripts natifs connus.
        for (TPKChatCustomView *view in tpk_registeredChatCustomViews()) {
            UIView *nativeView = view.tpk_nativeTranscriptView;
            nativeView.hidden = NO;
            view.hidden = YES;
        }
        for (TPKChatCustomView *view in tpk_registeredVODChatCustomViews()) {
            UIView *nativeView = view.tpk_nativeTranscriptView;
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
        tpk_installChatCustomView(chatView, NO);
    }

    // Réinstaller les vues natives encore présentes après réactivation.
    for (TPKChatCustomView *view in tpk_registeredChatCustomViews()) {
        UIView *nativeView = view.tpk_nativeTranscriptView;
        if (!nativeView || nativeView == chatView || !nativeView.window ||
            !nativeView.superview) continue;
        tpk_installChatCustomView(nativeView, NO);
    }
    UIView *vodChatView = s_activeVODNativeChatView;
    if (vodChatView && vodChatView.superview && vodChatView.window) {
        tpk_installChatCustomView(vodChatView, YES);
    }
    for (TPKChatCustomView *view in tpk_registeredVODChatCustomViews()) {
        UIView *nativeView = view.tpk_nativeTranscriptView;
        if (!nativeView || nativeView == vodChatView || !nativeView.window ||
            !nativeView.superview) continue;
        tpk_installChatCustomView(nativeView, YES);
    }
    tpk_selectInteractionChatCustomView();
}

void tpk_handleNativeChatViewLifecycle(UIView *view) {
    if (!view) return;

    tpk_installNativeReplayChatHook();

    BOOL isTable = [view isKindOfClass:UITableView.class];
    UITableView *replayTable = isTable ? tpk_replayTableForView(view) : nil;
    if (replayTable == (UITableView *)view) {
        tpk_setPlayerReloadVODState(view, YES);
        TPKChannelResolverRefresh();
        UITableView *retainedTable = (UITableView *)view;
        void (^install)(void) = ^{
            if (retainedTable.window && retainedTable.superview &&
                [TPKManager sharedManager].chatCustomTestEnabled) {
                tpk_installChatCustomView(retainedTable, YES);
            }
        };
        if (NSThread.isMainThread) install();
        else dispatch_async(dispatch_get_main_queue(), install);
        return;
    }

    if (!tpk_isLiveChatMessageListView(view) ||
        !view.window || !view.superview) {
        return;
    }

    if (tpk_replayTableForView(view)) return;

    TPKChannelContext *context = TPKCurrentChannelContext();
    if (context.mediaKind == TPKChannelMediaKindReplay) {
        [[TPKChannelResolver sharedResolver]
            invalidateIfCurrentContext:context];
    }
    TPKChannelResolverRefresh();

    tpk_setPlayerReloadVODState(view, NO);
    s_activeNativeChatView = view;
    tpk_applyChatCustomToggle();
}

void tpk_setupChatCustomIntegration(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        TPKManager *manager = [TPKManager sharedManager];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

        // Retokeniser seulement quand la résolution des emotes change.
        __block NSInteger lastEmoteResolution =
            [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
        [center addObserverForName:TPKChatCustomToggleDidChangeNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            tpk_applyChatCustomToggle();
        }];
        [center addObserverForName:TPKEmoteCatalogDidUpdateNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            tpk_scheduleChatRetokenization();
        }];
        // Retokeniser après chaque mise à jour du catalogue provider.
        [center addObserverForName:TPKProviderCatalogDidUpdateNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            tpk_scheduleChatRetokenization();
        }];
        // Recalculer les tokens après un changement de provider ou de Zero-Width.
        [center addObserverForName:TPKEmoteProviderSettingsDidChangeNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            tpk_scheduleChatRetokenization();
        }];
        [center addObserverForName:TPKChatAppearanceConfigDidChangeNotification
                           object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            NSInteger currentResolution =
                [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
            BOOL resolutionChanged = currentResolution != lastEmoteResolution;
            lastEmoteResolution = currentResolution;
            if (!resolutionChanged) {
                tpk_scheduleChatConfigurationReload();
                return;
            }
            tpk_scheduleChatRetokenization();
        }];
        for (NSString *notificationName in @[
            TPKBadgesCatalogUpdatedNotification,
            TPKLanguageDidChangeNotification
        ]) {
            [center addObserverForName:notificationName object:nil queue:nil
                            usingBlock:^(__unused NSNotification *note) {
                tpk_scheduleChatConfigurationReload();
            }];
        }
    });
}
