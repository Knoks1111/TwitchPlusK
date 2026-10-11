/* Player tools: delay reset and stream statistics. */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "System/tpK-system-native-behavior-hooks.h"
#import "System/tpK-system-player-reload.h"
#import "UI/tpK-oled-mode.h"

static NSString *const kTPKPlayerControlsClass =
    @"Twitch.TheaterPlayerControlsView";
static NSString *const kTPKPlayerReloadButtonIdentifier =
    @"tpk_player_reload_button";
static NSString *const kTPKPlayerStatsButtonIdentifier =
    @"tpk_player_stats_button";
static NSString *const kTPKPlayerToolsEnabledKey =
    @"tpk_player_tools_enabled";
static NSString *const kTPKPlayerStatsEnabledKey =
    @"tpk_player_stats_enabled";

static char kTPKPlayerReloadButtonKey;
static char kTPKPlayerReloadTimerKey;
static char kTPKPlayerReloadPendingKey;
static char kTPKPlayerReloadLastTitleKey;
static char kTPKPlayerStatsButtonKey;
static char kTPKPlayerStatsPanelKey;
static char kTPKPlayerStatsLastLatencyKey;
static char kTPKPlayerStatsLastUpdateTimeKey;
static char kTPKPlayerButtonsStackKey;
static char kTPKPlayerReloadStyledHeightKey;
static char kTPKPlayerReloadVODStateKey;

static const CGFloat kTPKPlayerStatsPanelWidth = 238.0;
static const CGFloat kTPKPlayerStatsPanelHeight = 200.0;

static IMP tpk_playerReactOriginalMountChild;
static IMP tpk_playerReactOriginalPrepareForRecycle;

static UIButton *tpk_reloadButtonInControls(UIView *controls);
static void tpk_reloadInstallButton(UIView *controls);
static id tpk_reloadObjectGetter(id object, SEL selector);

static Class tpk_playerReloadControlsClass(void) {
    static Class controlsClass;
    if (!controlsClass) {
        controlsClass = NSClassFromString(kTPKPlayerControlsClass);
    }
    return controlsClass;
}

static BOOL tpk_playerReloadIsControlsView(UIView *view) {
    return tpk_isPlayerControlsContainer(view);
}

BOOL tpk_isReactPlayerControlsContainer(UIView *view) {
    Class componentViewClass = NSClassFromString(@"RCTViewComponentView");
    if (!view || !componentViewClass ||
        ![view isKindOfClass:componentViewClass] ||
        ![view.accessibilityIdentifier
            isEqualToString:@"player-controls-overlay"]) return NO;

    BOOL hasBackButton = NO;
    BOOL hasShareButton = NO;
    BOOL hasCastOrSettingsButton = NO;
    for (UIView *subview in view.subviews) {
        NSString *identifier = subview.accessibilityIdentifier;
        if ([identifier isEqualToString:@"player-controls-back"]) {
            hasBackButton = YES;
        } else if ([identifier isEqualToString:@"player-controls-share"]) {
            hasShareButton = YES;
        } else if ([identifier isEqualToString:@"player-controls-cast"] ||
                   [identifier isEqualToString:@"player-controls-settings"]) {
            hasCastOrSettingsButton = YES;
        }
    }

    BOOL insidePlayerSurface = NO;
    for (UIView *cursor = view.superview; cursor; cursor = cursor.superview) {
        NSString *identifier = cursor.accessibilityIdentifier;
        if ([identifier isEqualToString:@"theatre-video-zoom-gesture-surface"] ||
            [identifier isEqualToString:@"theatre-screen"] ||
            [identifier isEqualToString:@"theatre-portrait-layout"]) {
            insidePlayerSurface = YES;
            break;
        }
    }

    // Recycled IDs are stale; require player controls and a theater ancestor.
    return insidePlayerSurface && hasBackButton && hasShareButton &&
           hasCastOrSettingsButton;
}

BOOL tpk_isPlayerControlsContainer(UIView *view) {
    Class controlsClass = tpk_playerReloadControlsClass();
    return view && ((controlsClass && view.class == controlsClass) ||
                    tpk_isReactPlayerControlsContainer(view));
}

static UIView *tpk_playerFindView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = tpk_playerFindView(subview, identifier);
        if (match) return match;
    }
    return nil;
}

static BOOL tpk_playerInstallReactHook(Class cls, SEL selector,
                                        IMP replacement, IMP *original) {
    if (*original) return YES;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static void tpk_playerReactControlsDidMountChild(UIView *controls) {
    if (!tpk_isReactPlayerControlsContainer(controls) || !controls.window)
        return;
    if (tpk_playerToolsEnabled() &&
        !tpk_reloadButtonInControls(controls) &&
        tpk_playerReactControlsButtonStack(controls)) {
        tpk_reloadInstallButton(controls);
    }
    tpk_handleTheaterControlsViewLifecycle(controls);
}

static void tpk_playerReactMountChild(id self, SEL selector,
                                       UIView *child, NSInteger index) {
    if (tpk_playerReactOriginalMountChild) {
        ((void (*)(id, SEL, id, NSInteger))tpk_playerReactOriginalMountChild)(
            self, selector, child, index);
    }
    tpk_playerReactControlsDidMountChild(self);
}

static void tpk_playerReactCleanupRecycledControls(UIView *controls) {
    UIStackView *stack = (UIStackView *)tpk_playerFindView(
        controls, @"tpk_player_buttons_stack");
    UIButton *reloadButton = objc_getAssociatedObject(
        controls, &kTPKPlayerReloadButtonKey);
    UIButton *statsButton = objc_getAssociatedObject(
        controls, &kTPKPlayerStatsButtonKey);
    NSTimer *timer = objc_getAssociatedObject(
        controls, &kTPKPlayerReloadTimerKey);
    if (!stack && !reloadButton && !statsButton && !timer) return;

    [timer invalidate];
    [stack removeFromSuperview];
    objc_setAssociatedObject(controls, &kTPKPlayerReloadButtonKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTPKPlayerStatsButtonKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTPKPlayerReloadTimerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kTPKPlayerButtonsStackKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void tpk_playerReactPrepareForRecycle(id self, SEL selector) {
    if (tpk_playerReactOriginalPrepareForRecycle) {
        ((void (*)(id, SEL))tpk_playerReactOriginalPrepareForRecycle)(
            self, selector);
    }
    tpk_playerReactCleanupRecycledControls(self);
}

static void tpk_playerReactInstallHooks(void) {
    Class cls = NSClassFromString(@"RCTViewComponentView");
    if (!cls) return;

    static CFTimeInterval lastAttempt;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - lastAttempt < 0.5) return;
    lastAttempt = now;

    @synchronized(cls) {
        tpk_playerInstallReactHook(
            cls, NSSelectorFromString(@"mountChildComponentView:index:"),
            (IMP)tpk_playerReactMountChild, &tpk_playerReactOriginalMountChild);
        tpk_playerInstallReactHook(
            cls, NSSelectorFromString(@"prepareForRecycle"),
            (IMP)tpk_playerReactPrepareForRecycle,
            &tpk_playerReactOriginalPrepareForRecycle);
    }
}
UIStackView *tpk_playerReactControlsButtonStack(UIView *view) {
    if (!tpk_isReactPlayerControlsContainer(view)) return nil;

    UIStackView *stack = objc_getAssociatedObject(
        view, &kTPKPlayerButtonsStackKey);
    if (stack && stack.superview == view) {
        [view bringSubviewToFront:stack];
        return stack;
    }
    if (stack) [stack removeFromSuperview];

    for (UIView *candidate in view.subviews) {
        if ([candidate isKindOfClass:UIStackView.class] &&
            [candidate.accessibilityIdentifier
                isEqualToString:@"tpk_player_buttons_stack"]) {
            stack = (UIStackView *)candidate;
            objc_setAssociatedObject(view, &kTPKPlayerButtonsStackKey, stack,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view bringSubviewToFront:stack];
            return stack;
        }
    }

    UIView *viewerStats = tpk_playerFindView(view, @"viewer-stats");
    UIView *muteButton = tpk_playerFindView(
        view, @"player-controls-mute");
    if (!viewerStats || !muteButton) {
        return nil;
    }

    stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 4.0;
    stack.accessibilityIdentifier = @"tpk_player_buttons_stack";
    stack.isAccessibilityElement = NO;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:viewerStats.trailingAnchor
                                              constant:4.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:
            muteButton.leadingAnchor constant:-4.0],
        [stack.centerYAnchor constraintEqualToAnchor:muteButton.centerYAnchor],
        [stack.heightAnchor constraintEqualToConstant:40.0],
    ]];
    objc_setAssociatedObject(view, &kTPKPlayerButtonsStackKey, stack,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view bringSubviewToFront:stack];
    return stack;
}

static UIView *tpk_playerReloadTheaterForView(UIView *view) {
    return tpk_playerTheaterHostForView(view);
}

UIView *tpk_playerTheaterHostForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class)
                isEqualToString:@"Twitch.TheaterView"] ||
            [cursor.accessibilityIdentifier isEqualToString:@"theatre-screen"]) {
            return cursor;
        }
        UIResponder *responder = cursor.nextResponder;
        if (responder && [NSStringFromClass(responder.class)
                containsString:@"PortalTheaterViewController"]) {
            UIView *controllerView = tpk_reloadObjectGetter(
                responder, @selector(view));
            return controllerView ?: cursor;
        }
    }
    return nil;
}

void tpk_setPlayerReloadVODState(UIView *view, BOOL isVOD) {
    UIView *theater = tpk_playerReloadTheaterForView(view);
    if (!theater) return;
    objc_setAssociatedObject(theater, &kTPKPlayerReloadVODStateKey,
                             isVOD ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL tpk_playerReloadIsVODControls(UIView *controls) {
    UIView *theater = tpk_playerReloadTheaterForView(controls);
    return [objc_getAssociatedObject(theater,
                                     &kTPKPlayerReloadVODStateKey) boolValue];
}

static void tpk_reloadUpdateStatsPanelForControls(UIView *controls,
                                                   id player);
static void tpk_reloadInstallButton(UIView *controls);

BOOL tpk_playerToolsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:kTPKPlayerToolsEnabledKey]) return NO;
    return [defaults boolForKey:kTPKPlayerToolsEnabledKey];
}

BOOL tpk_playerStatsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:kTPKPlayerStatsEnabledKey]) return NO;
    return [defaults boolForKey:kTPKPlayerStatsEnabledKey];
}

static BOOL tpk_reloadLooksLikePlayer(id object) {
    return object &&
        [object respondsToSelector:@selector(setRebufferToLive:)] &&
        [object respondsToSelector:@selector(liveLatency)];
}

void tpk_setupPlayerReloadRuntimeHooks(void) {
    tpk_playerReactInstallHooks();
}

static id tpk_reloadObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;

    Class currentClass = object_getClass(object);
    while (currentClass) {
        Ivar ivar = class_getInstanceVariable(currentClass, name);
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') {
                return object_getIvar(object, ivar);
            }
            return nil;
        }
        currentClass = class_getSuperclass(currentClass);
    }
    return nil;
}

static id tpk_reloadObjectGetter(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void tpk_reloadAppendCandidate(NSMutableArray *queue,
                                       NSHashTable *visited,
                                       id candidate) {
    if (!candidate || ![candidate isKindOfClass:NSObject.class] ||
        [visited containsObject:candidate]) {
        return;
    }
    [visited addObject:candidate];
    [queue addObject:candidate];
}

static id tpk_reloadPlayerInViewTree(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    for (NSUInteger index = 0; index < pending.count && index < 2048; index++) {
        UIView *view = pending[index];
        if ([NSStringFromClass(view.class) isEqualToString:@"IVSPlayerView"]) {
            id player = tpk_reloadObjectGetter(view, @selector(player));
            if (tpk_reloadLooksLikePlayer(player)) return player;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    return nil;
}

static id tpk_reloadFindActivePlayer(UIView *controls) {
    if (!controls) return nil;

    UIView *theater = tpk_playerTheaterHostForView(controls);
    id player = tpk_reloadPlayerInViewTree(theater);
    if (player) return player;

    UIResponder *responder = controls;
    while (responder) {
        if ([NSStringFromClass(responder.class)
                containsString:@"PortalTheaterViewController"]) {
            for (NSString *name in @[@"videoBackingView",
                                     @"nativeVideoOverlayContainer"]) {
                id container = tpk_reloadObjectIvar(
                    responder, name.UTF8String);
                if (!container) {
                    container = tpk_reloadObjectGetter(
                        responder, NSSelectorFromString(name));
                }
                if ([container isKindOfClass:UIView.class]) {
                    player = tpk_reloadPlayerInViewTree(container);
                    if (player) return player;
                }
            }
            break;
        }
        responder = responder.nextResponder;
    }

    NSMutableArray *queue = [NSMutableArray arrayWithObject:controls];
    NSHashTable *visited = [NSHashTable
        hashTableWithOptions:NSHashTableObjectPointerPersonality |
                          NSHashTableStrongMemory];
    [visited addObject:controls];

    static const char *knownIvars[] = {
        "delegate",
        "playbackSession",
        "playbackController",
        "playerController",
        "player",
        "ttvPlayer",
        "wrappedPlayer",
        "theaterView",
        "viewController",
        "currentPortalTheater",
        "theaterPlugin",
        "nativeVideoOverlayPlugin",
        "videoBackingView",
        "nativeVideoOverlayContainer",
    };
    static const char *knownGetterNames[] = {
        "delegate",
        "playbackSession",
        "playbackController",
        "playerController",
        "player",
        "ttvPlayer",
        "wrappedPlayer",
        "theaterView",
        "viewController",
        "currentPortalTheater",
        "theaterPlugin",
        "nativeVideoOverlayPlugin",
        "videoBackingView",
        "nativeVideoOverlayContainer",
    };
    const NSUInteger knownCount = sizeof(knownIvars) / sizeof(knownIvars[0]);

    for (NSUInteger index = 0; index < queue.count && index < 64; index++) {
        id candidate = queue[index];
        NSString *className = NSStringFromClass([candidate class]);

        if (tpk_reloadLooksLikePlayer(candidate)) {
            return candidate;
        }

        if ([candidate isKindOfClass:UIView.class]) {
            player = tpk_reloadPlayerInViewTree(candidate);
            if (player) return player;
        }

        if ([className rangeOfString:@"PlayerCoreVideoPlayer"].location !=
            NSNotFound) {
            id player = tpk_reloadObjectIvar(candidate, "ttvPlayer");
            if (!player) {
                player = tpk_reloadObjectGetter(candidate,
                                                 @selector(ttvPlayer));
            }
            if (tpk_reloadLooksLikePlayer(player)) {
                return player;
            }
            tpk_reloadAppendCandidate(queue, visited, player);
        }

        if ([className rangeOfString:@"PortalIVSPlayer"].location != NSNotFound) {
            id player = tpk_reloadObjectIvar(candidate, "player");
            if (!player) {
                player = tpk_reloadObjectGetter(candidate, @selector(player));
            }
            if (tpk_reloadLooksLikePlayer(player)) {
                return player;
            }
            tpk_reloadAppendCandidate(queue, visited, player);
        }

        if ([candidate isKindOfClass:UIView.class]) {
            UIView *view = candidate;
            tpk_reloadAppendCandidate(queue, visited, view.superview);
            tpk_reloadAppendCandidate(queue, visited, view.nextResponder);
        }

        for (NSUInteger edge = 0; edge < knownCount; edge++) {
            id child = tpk_reloadObjectIvar(candidate, knownIvars[edge]);
            if (!child) {
                child = tpk_reloadObjectGetter(
                    candidate, sel_registerName(knownGetterNames[edge]));
            }
            tpk_reloadAppendCandidate(queue, visited, child);
        }
    }

    return nil;
}

static UIView *tpk_reloadControlsForButton(UIButton *button) {
    UIView *ancestor = button;
    while (ancestor) {
        if (tpk_playerReloadIsControlsView(ancestor)) {
            return ancestor;
        }
        ancestor = ancestor.superview;
    }
    return nil;
}

static id tpk_reloadControlsObject(UIView *controls,
                                    const char *ivarName,
                                    SEL getter) {
    id object = tpk_reloadObjectIvar(controls, ivarName);
    return object ?: tpk_reloadObjectGetter(controls, getter);
}

static void tpk_reloadRegisterButtonForHitTesting(UIView *controls,
                                                   UIButton *button) {
    if (!controls || !button) return;

    NSString *traceName =
        [button.accessibilityIdentifier
            isEqualToString:kTPKPlayerStatsButtonIdentifier]
                ? @"stats" : @"reload";

    id allButtons = tpk_reloadControlsObject(controls, "allButtons",
                                              @selector(allButtons));
    if (![allButtons isKindOfClass:NSArray.class]) {
        return;
    }

    NSMutableArray *updatedButtons = [allButtons mutableCopy];
    if ([updatedButtons containsObject:button]) {
        return;
    }
    [updatedButtons addObject:button];
    SEL setter = @selector(setAllButtons:);
    if ([controls respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controls, setter, updatedButtons);
        id result = tpk_reloadControlsObject(controls, "allButtons",
                                              @selector(allButtons));
        BOOL registered = [result isKindOfClass:NSArray.class] &&
            [result containsObject:button];
    } else {
    }
}

static UIStackView *tpk_reloadTargetStack(UIView *controls,
                                           UIView **anchorButton) {
    if (anchorButton) *anchorButton = nil;

    NSArray<NSDictionary *> *anchors = @[
        @{ @"ivar": @"liveIndicatorView", @"selector": NSStringFromSelector(@selector(liveIndicatorView)) },
        @{ @"ivar": @"shareButton", @"selector": NSStringFromSelector(@selector(shareButton)) },
        @{ @"ivar": @"rotateButton", @"selector": NSStringFromSelector(@selector(rotateButton)) },
    ];

    for (NSDictionary *anchorInfo in anchors) {
        UIView *anchor = tpk_reloadControlsObject(
            controls, [anchorInfo[@"ivar"] UTF8String],
            NSSelectorFromString(anchorInfo[@"selector"]));
        if ([anchor.superview isKindOfClass:UIStackView.class]) {
            if (anchorButton) *anchorButton = anchor;
            return (UIStackView *)anchor.superview;
        }
    }

    for (NSDictionary *stackInfo in @[
        @{ @"ivar": @"topRightStackView", @"selector": NSStringFromSelector(@selector(topRightStackView)) },
        @{ @"ivar": @"bottomRightStackView", @"selector": NSStringFromSelector(@selector(bottomRightStackView)) },
        @{ @"ivar": @"topLeftStackView", @"selector": NSStringFromSelector(@selector(topLeftStackView)) },
    ]) {
        UIStackView *stack = tpk_reloadControlsObject(
            controls, [stackInfo[@"ivar"] UTF8String],
            NSSelectorFromString(stackInfo[@"selector"]));
        if ([stack isKindOfClass:UIStackView.class]) return stack;
    }

    return nil;
}

static UIStackView *tpk_reloadViewerButtonStack(UIView *controls,
                                                 UIView **anchorButton) {
    if (anchorButton) *anchorButton = nil;
    if (!controls) return nil;

    if (tpk_isReactPlayerControlsContainer(controls)) {
        return tpk_playerReactControlsButtonStack(controls);
    }

    UIStackView *associated = objc_getAssociatedObject(
        controls, &kTPKPlayerButtonsStackKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kTPKPlayerButtonsStackKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *viewerIndicator = tpk_reloadControlsObject(
        controls, "liveIndicatorView", @selector(liveIndicatorView));
    if ([viewerIndicator.superview isKindOfClass:UIStackView.class]) {
        if (anchorButton) *anchorButton = viewerIndicator;
        return (UIStackView *)viewerIndicator.superview;
    }

    // Keep native controls in place.
    if (viewerIndicator && viewerIndicator.superview == controls) {
        UIStackView *stack = [[UIStackView alloc] init];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.distribution = UIStackViewDistributionFill;
        stack.spacing = 4.0;
        stack.accessibilityIdentifier = @"tpk_player_buttons_stack";
        [controls addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:viewerIndicator.trailingAnchor
                                                 constant:8.0],
            [stack.centerYAnchor constraintEqualToAnchor:viewerIndicator.centerYAnchor],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:controls.trailingAnchor
                                                              constant:-8.0],
            [stack.heightAnchor constraintEqualToConstant:24.0],
        ]];
        objc_setAssociatedObject(controls, &kTPKPlayerButtonsStackKey, stack,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return stack;
    }

    return tpk_reloadTargetStack(controls, anchorButton);
}

static CMTime tpk_reloadLatency(id player) {
    if (!player || ![player respondsToSelector:@selector(liveLatency)]) {
        return kCMTimeInvalid;
    }
    return ((CMTime (*)(id, SEL))objc_msgSend)(player,
                                               @selector(liveLatency));
}

static NSString *tpk_reloadTitleForPlayer(id player) {
    if (!player) return @"—";

    CMTime latency = tpk_reloadLatency(player);
    Float64 seconds = CMTimeGetSeconds(latency);
    if (!CMTIME_IS_NUMERIC(latency) || !isfinite(seconds) || seconds < 0.0) {
        return @"LIVE";
    }
    return [NSString stringWithFormat:@"%.1fs", seconds];
}

static NSString *tpk_reloadDisplayTitleForButton(UIButton *button, id player) {
    NSString *title = tpk_reloadTitleForPlayer(player);
    BOOL hasLiveDelay = player && [title hasSuffix:@"s"];
    if (hasLiveDelay) {
        objc_setAssociatedObject(button, &kTPKPlayerReloadLastTitleKey,
                                 title, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return title;
    }

    // Keep the last valid delay during reload.
    NSString *lastTitle = objc_getAssociatedObject(
        button, &kTPKPlayerReloadLastTitleKey);
    return lastTitle.length ? lastTitle : title;
}

static BOOL tpk_reloadBoolValue(id object, SEL selector, BOOL fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long tpk_reloadLongLongValue(id object, SEL selector,
                                          long long fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
}

static float tpk_reloadFloatValue(id object, SEL selector, float fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((float (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGSize tpk_reloadSizeValue(id object, SEL selector,
                                   CGSize fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *tpk_reloadCMTimeText(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return @"—";
    }

    CMTime time = ((CMTime (*)(id, SEL))objc_msgSend)(object, selector);
    Float64 seconds = CMTimeGetSeconds(time);
    if (!CMTIME_IS_NUMERIC(time) || !isfinite(seconds) || seconds < 0.0) {
        return @"—";
    }
    return [NSString stringWithFormat:@"%.2fs", seconds];
}

static NSString *tpk_reloadBitrateText(long long bitsPerSecond) {
    if (bitsPerSecond <= 0) return @"—";
    if (bitsPerSecond >= 1000000) {
        return [NSString stringWithFormat:@"%.2f Mbps",
                                          (double)bitsPerSecond / 1000000.0];
    }
    return [NSString stringWithFormat:@"%lld kbps",
                                      bitsPerSecond / 1000];
}

static NSString *tpk_reloadLatencyText(id player) {
    if (!player) return @"—";

    CMTime latency = tpk_reloadLatency(player);
    Float64 seconds = CMTimeGetSeconds(latency);
    if (!CMTIME_IS_NUMERIC(latency) || !isfinite(seconds) || seconds < 0.0) {
        return @"—";
    }
    return [NSString stringWithFormat:@"%.2fs", seconds];
}

@interface TPKPlayerStatsPanel : UIView
- (void)updateWithPlayer:(id)player;
- (void)rememberLatencyText:(NSString *)text;
@end

@implementation TPKPlayerStatsPanel {
    UILabel *_titleLabel;
    UIStackView *_rowsStack;
    NSArray<UILabel *> *_rowLabels;
    CGPoint _panStartCenter;
}

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = YES;
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    self.clipsToBounds = YES;
    self.hidden = YES;
    self.alpha = 0.0;
    self.userInteractionEnabled = YES;
    self.accessibilityElementsHidden = NO;
    self.layer.zPosition = 2000.0;

    UIPanGestureRecognizer *panGesture =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(tpk_handlePan:)];
    panGesture.cancelsTouchesInView = NO;
    [self addGestureRecognizer:panGesture];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = @"Video Player Stats";
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont boldSystemFontOfSize:12.5];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_titleLabel];

    _rowsStack = [[UIStackView alloc] init];
    _rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _rowsStack.axis = UILayoutConstraintAxisVertical;
    _rowsStack.alignment = UIStackViewAlignmentFill;
    _rowsStack.distribution = UIStackViewDistributionFill;
    _rowsStack.spacing = 0.0;
    [self addSubview:_rowsStack];

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    for (NSUInteger index = 0; index < 13; index++) {
        UILabel *label = [[UILabel alloc] init];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
        label.numberOfLines = 1;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.75;
        [_rowsStack addArrangedSubview:label];
        [labels addObject:label];
    }
    _rowLabels = labels;

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor
                                                constant:7.0],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                   constant:7.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-7.0],
        [_rowsStack.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                               constant:3.0],
        [_rowsStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                   constant:8.0],
        [_rowsStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-8.0],
        [_rowsStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                 constant:-7.0],
    ]];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(tpk_oledModeDidChange:)
               name:TPKOLEDModeDidChangeNotification
             object:nil];
    [self tpk_updateAppearance];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:TPKOLEDModeDidChangeNotification
                object:nil];
}

- (void)tpk_updateAppearance {
    self.backgroundColor = TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.07 alpha:0.97];
}

- (void)tpk_oledModeDidChange:(__unused NSNotification *)note {
    if (NSThread.isMainThread) {
        [self tpk_updateAppearance];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self tpk_updateAppearance];
        });
    }
}

- (void)tpk_handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *host = self.superview;
    if (!host) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        _panStartCenter = self.center;
    }

    CGPoint translation = [gesture translationInView:host];
    CGPoint center = CGPointMake(_panStartCenter.x + translation.x,
                                 _panStartCenter.y + translation.y);
    CGRect hostBounds = host.bounds;
    CGFloat halfWidth = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) * 0.5;

    if (CGRectGetWidth(hostBounds) > CGRectGetWidth(self.bounds)) {
        center.x = MIN(MAX(center.x, CGRectGetMinX(hostBounds) + halfWidth),
                       CGRectGetMaxX(hostBounds) - halfWidth);
    }
    if (CGRectGetHeight(hostBounds) > CGRectGetHeight(self.bounds)) {
        center.y = MIN(MAX(center.y, CGRectGetMinY(hostBounds) + halfHeight),
                       CGRectGetMaxY(hostBounds) - halfHeight);
    }
    self.center = center;
}

- (void)rememberLatencyText:(NSString *)text {
    if ([text hasSuffix:@"s"]) {
        objc_setAssociatedObject(self, &kTPKPlayerStatsLastLatencyKey,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

- (void)updateWithPlayer:(id)player {
    if (!player) {
        for (UILabel *label in _rowLabels) {
            if (![label.text isEqualToString:@"—"]) label.text = @"—";
        }
        NSString *lastLatency = objc_getAssociatedObject(
            self, &kTPKPlayerStatsLastLatencyKey);
        NSString *latencyLine = [NSString stringWithFormat:@"Latency: %@",
                                 lastLatency.length ? lastLatency : @"—"];
        if (![_rowLabels[0].text isEqualToString:latencyLine]) {
            _rowLabels[0].text = latencyLine;
        }
        if (![_rowLabels[1].text isEqualToString:@"Player: unavailable"]) {
            _rowLabels[1].text = @"Player: unavailable";
        }
        return;
    }

    id quality = tpk_reloadObjectGetter(player, @selector(quality));
    long long qualityWidth = tpk_reloadLongLongValue(quality, @selector(width), 0);
    long long qualityHeight = tpk_reloadLongLongValue(quality, @selector(height), 0);
    float framerate = tpk_reloadFloatValue(quality, @selector(framerate), 0.0f);
    long long qualityBitrate = tpk_reloadLongLongValue(quality,
                                                         @selector(bitrate), 0);
    CGSize videoSize = tpk_reloadSizeValue(player, @selector(videoSize),
                                            CGSizeZero);
    long long width = qualityWidth > 0 ? qualityWidth : (long long)videoSize.width;
    long long height = qualityHeight > 0 ? qualityHeight : (long long)videoSize.height;
    long long bitrate = tpk_reloadLongLongValue(player, @selector(videoBitrate),
                                                  qualityBitrate);
    if (bitrate <= 0) bitrate = qualityBitrate;

    BOOL lowLatency = tpk_reloadBoolValue(player, @selector(isLiveLowLatency),
                                           NO);
    if ([player respondsToSelector:@selector(liveLowLatency)]) {
        lowLatency = tpk_reloadBoolValue(player, @selector(liveLowLatency),
                                          lowLatency);
    }

    NSString *qualityName = tpk_reloadObjectGetter(quality, @selector(name));
    if (![qualityName isKindOfClass:NSString.class] || qualityName.length == 0) {
        qualityName = @"—";
    }

    NSString *latencyText = tpk_reloadLatencyText(player);
    if ([latencyText hasSuffix:@"s"]) {
        [self rememberLatencyText:latencyText];
    } else {
        NSString *lastLatency = objc_getAssociatedObject(
            self, &kTPKPlayerStatsLastLatencyKey);
        if (lastLatency.length) latencyText = lastLatency;
    }

    long long averageBitrate = tpk_reloadLongLongValue(
        player, @selector(averageBitrate), 0);
    long long bandwidth = tpk_reloadLongLongValue(
        player, @selector(bandwidthEstimate), 0);
    long long droppedFrames = tpk_reloadLongLongValue(
        player, @selector(videoFramesDropped), 0);
    long long decodedFrames = tpk_reloadLongLongValue(
        player, @selector(videoFramesDecoded), 0);
    float playbackRate = tpk_reloadFloatValue(player, @selector(playbackRate),
                                                0.0f);
    NSArray<NSString *> *lines = @[
        [NSString stringWithFormat:@"Latency: %@", latencyText],
        [NSString stringWithFormat:@"Low Latency Mode: %@", lowLatency ? @"Yes" : @"No"],
        [NSString stringWithFormat:@"Resolution: %@",
                                  (width > 0 && height > 0)
                                      ? [NSString stringWithFormat:@"%lld×%lld", width, height]
                                      : @"—"],
        [NSString stringWithFormat:@"Framerate: %@",
                                  framerate > 0.0f
                                      ? [NSString stringWithFormat:@"%.2g fps", framerate]
                                      : @"—"],
        [NSString stringWithFormat:@"Bitrate: %@", tpk_reloadBitrateText(bitrate)],
        [NSString stringWithFormat:@"Average Bitrate: %@",
                                  tpk_reloadBitrateText(averageBitrate)],
        [NSString stringWithFormat:@"Bandwidth: %@", tpk_reloadBitrateText(bandwidth)],
        [NSString stringWithFormat:@"Dropped Frames: %lld", MAX(0LL, droppedFrames)],
        [NSString stringWithFormat:@"Decoded Frames: %lld", MAX(0LL, decodedFrames)],
        [NSString stringWithFormat:@"Playback Rate: %.2fx", playbackRate],
        [NSString stringWithFormat:@"Buffer: %@",
                                  tpk_reloadCMTimeText(player, @selector(buffered))],
        [NSString stringWithFormat:@"Position: %@",
                                  tpk_reloadCMTimeText(player, @selector(position))],
        [NSString stringWithFormat:@"Quality: %@", qualityName],
    ];
    for (NSUInteger index = 0; index < _rowLabels.count; index++) {
        if (![_rowLabels[index].text isEqualToString:lines[index]]) {
            _rowLabels[index].text = lines[index];
        }
    }
}

@end

static UIButton *tpk_reloadStatsButtonInControls(UIView *controls) {
    UIButton *associated = objc_getAssociatedObject(
        controls, &kTPKPlayerStatsButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kTPKPlayerStatsButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier
                isEqualToString:kTPKPlayerStatsButtonIdentifier]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static UIView *tpk_reloadStatsPanelHost(UIView *controls) {
    return controls
        ? (tpk_playerReloadTheaterForView(controls) ?: controls.window) : nil;
}

static TPKPlayerStatsPanel *tpk_reloadExistingStatsPanel(UIView *controls) {
    UIView *host = tpk_reloadStatsPanelHost(controls);
    return host ? objc_getAssociatedObject(host, &kTPKPlayerStatsPanelKey) : nil;
}

static TPKPlayerStatsPanel *tpk_reloadStatsPanelForControls(UIView *controls) {
    UIView *host = tpk_reloadStatsPanelHost(controls);
    if (!host) return nil;

    TPKPlayerStatsPanel *panel = objc_getAssociatedObject(
        host, &kTPKPlayerStatsPanelKey);
    if (panel) return panel;

    panel = [[TPKPlayerStatsPanel alloc] init];
    panel.accessibilityIdentifier = @"tpk_player_stats_panel";
    CGRect videoRect = [controls convertRect:controls.bounds toView:host];
    CGFloat x = CGRectGetMinX(videoRect) + 8.0;
    CGFloat y = CGRectGetMinY(videoRect) + 8.0;
    CGRect hostBounds = host.bounds;
    if (CGRectGetWidth(hostBounds) > kTPKPlayerStatsPanelWidth) {
        x = MIN(MAX(x, CGRectGetMinX(hostBounds)),
                CGRectGetMaxX(hostBounds) - kTPKPlayerStatsPanelWidth);
    }
    if (CGRectGetHeight(hostBounds) > kTPKPlayerStatsPanelHeight) {
        y = MIN(MAX(y, CGRectGetMinY(hostBounds)),
                CGRectGetMaxY(hostBounds) - kTPKPlayerStatsPanelHeight);
    }
    panel.frame = CGRectMake(x, y, kTPKPlayerStatsPanelWidth,
                             kTPKPlayerStatsPanelHeight);
    [host addSubview:panel];
    [host bringSubviewToFront:panel];
    objc_setAssociatedObject(host, &kTPKPlayerStatsPanelKey, panel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return panel;
}

static void tpk_reloadUpdateStatsPanelForControls(UIView *controls,
                                                   id player) {
    if (!tpk_playerToolsEnabled() || !tpk_playerStatsEnabled()) return;
    TPKPlayerStatsPanel *panel = tpk_reloadExistingStatsPanel(controls);
    if (!panel || panel.hidden) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *lastUpdate = objc_getAssociatedObject(
        panel, &kTPKPlayerStatsLastUpdateTimeKey);
    if (lastUpdate && (now - lastUpdate.doubleValue) < 0.9) return;
    objc_setAssociatedObject(panel, &kTPKPlayerStatsLastUpdateTimeKey,
                             @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIButton *reloadButton = objc_getAssociatedObject(
        controls, &kTPKPlayerReloadButtonKey);
    NSString *lastButtonTitle = objc_getAssociatedObject(
        reloadButton, &kTPKPlayerReloadLastTitleKey);
    [panel rememberLatencyText:lastButtonTitle];
    [panel updateWithPlayer:player];
}

@interface TPKPlayerReloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)tpk_playerReloadButtonTapped:(UIButton *)sender;
- (void)tpk_playerStatsButtonTapped:(UIButton *)sender;
@end

static void tpk_reloadInstallStatsButton(UIView *controls,
                                          UIButton *reloadButton) {
    if (!controls) return;
    if (!tpk_playerToolsEnabled()) {
        return;
    }

    UIButton *statsButton = tpk_reloadStatsButtonInControls(controls);
    if (!tpk_playerStatsEnabled()) {
        statsButton.hidden = YES;
        statsButton.enabled = NO;
        UIView *panel = tpk_reloadExistingStatsPanel(controls);
        panel.hidden = YES;
        panel.alpha = 0.0;
        return;
    }
    if (statsButton) {
        objc_setAssociatedObject(controls, &kTPKPlayerStatsButtonKey,
                                 statsButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        reloadButton.hidden = NO;
        reloadButton.enabled = ![objc_getAssociatedObject(
            reloadButton, &kTPKPlayerReloadPendingKey) boolValue];
        statsButton.hidden = NO;
        statsButton.enabled = YES;
        tpk_reloadRegisterButtonForHitTesting(controls, statsButton);
        return;
    }

    UIStackView *stack = nil;
    if ([reloadButton.superview isKindOfClass:UIStackView.class]) {
        stack = (UIStackView *)reloadButton.superview;
    }
    if (!stack) {
        stack = tpk_reloadTargetStack(controls, NULL);
    }
    if (!stack) {
        return;
    }

    statsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    statsButton.translatesAutoresizingMaskIntoConstraints = NO;
    statsButton.accessibilityIdentifier = kTPKPlayerStatsButtonIdentifier;
    statsButton.accessibilityLabel = @"Video player statistics";
    statsButton.accessibilityHint = @"Show stream statistics";
    statsButton.accessibilityTraits = UIAccessibilityTraitButton;
    statsButton.tintColor = UIColor.whiteColor;
    statsButton.contentEdgeInsets = UIEdgeInsetsMake(0.0, 3.0, 0.0, 3.0);
    if (tpk_isReactPlayerControlsContainer(controls)) {
        [NSLayoutConstraint activateConstraints:@[
            [statsButton.widthAnchor constraintEqualToConstant:40.0],
            [statsButton.heightAnchor constraintEqualToConstant:40.0],
        ]];
    }
    UIImage *statsImage = [UIImage systemImageNamed:@"chart.bar"];
    if (statsImage) {
        [statsButton setImage:statsImage forState:UIControlStateNormal];
    } else {
        [statsButton setTitle:@"Stats" forState:UIControlStateNormal];
        [statsButton setTitleColor:UIColor.whiteColor
                          forState:UIControlStateNormal];
        statsButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
    }
    [statsButton addTarget:[TPKPlayerReloadTarget sharedTarget]
                    action:@selector(tpk_playerStatsButtonTapped:)
          forControlEvents:UIControlEventTouchUpInside];

    NSUInteger reloadIndex = NSNotFound;
    if (reloadButton) {
        reloadIndex = [stack.arrangedSubviews indexOfObject:reloadButton];
    }
    if (reloadIndex != NSNotFound) {
        [stack insertArrangedSubview:statsButton atIndex:reloadIndex + 1];
    } else {
        [stack addArrangedSubview:statsButton];
    }
    tpk_reloadRegisterButtonForHitTesting(controls, statsButton);
    objc_setAssociatedObject(controls, &kTPKPlayerStatsButtonKey,
                             statsButton,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void tpk_reloadStyleDelayButton(UIButton *button) {
    if (!button) return;
    CGFloat height = CGRectGetHeight(button.bounds);
    NSNumber *lastHeight = objc_getAssociatedObject(
        button, &kTPKPlayerReloadStyledHeightKey);
    if (lastHeight && fabs(lastHeight.doubleValue - height) < 0.1) return;
    button.layer.cornerRadius = height > 0.0 ? height * 0.5 : 12.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    button.backgroundColor = UIColor.clearColor;
    button.clipsToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, 6.0);
    objc_setAssociatedObject(button, &kTPKPlayerReloadStyledHeightKey,
                             @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void tpk_reloadUpdateButton(UIButton *button) {
    if (!button) return;
    if (!tpk_playerToolsEnabled()) {
        button.hidden = YES;
        button.enabled = NO;
        return;
    }

    UIView *controls = tpk_reloadControlsForButton(button);
    id player = tpk_reloadFindActivePlayer(controls);
    if (tpk_playerReloadIsVODControls(controls)) {
        button.hidden = YES;
        button.enabled = NO;

        UIButton *statsButton = objc_getAssociatedObject(
            controls, &kTPKPlayerStatsButtonKey);
        statsButton.hidden = YES;
        statsButton.enabled = NO;

        UIView *panel = tpk_reloadExistingStatsPanel(controls);
        panel.hidden = YES;
        panel.alpha = 0.0;
        return;
    }

    button.hidden = NO;
    tpk_reloadStyleDelayButton(button);
    NSString *title = tpk_reloadDisplayTitleForButton(button, player);
    if (![button.currentTitle isEqualToString:title]) {
        [button setTitle:title forState:UIControlStateNormal];
    }
    button.titleLabel.hidden = NO;
    button.titleLabel.alpha = 1.0;
    BOOL pending = [objc_getAssociatedObject(
        button, &kTPKPlayerReloadPendingKey) boolValue];
    // Restore interaction after a reload or setting change.
    button.enabled = !pending;
    button.alpha = pending
        ? 0.55
        : (player ? 1.0 : 0.65);
    tpk_reloadUpdateStatsPanelForControls(controls, player);
}

static void tpk_reloadStartTimer(UIView *controls, UIButton *button) {
    if (!tpk_playerToolsEnabled()) return;
    if (objc_getAssociatedObject(controls, &kTPKPlayerReloadTimerKey)) {
        return;
    }

    __weak UIView *weakControls = controls;
    __weak UIButton *weakButton = button;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        repeats:YES
                                                          block:^(NSTimer *timer) {
        UIView *currentControls = weakControls;
        UIButton *currentButton = weakButton;
        if (!currentControls || !currentButton || !currentControls.window) {
            [timer invalidate];
            return;
        }
        tpk_reloadUpdateButton(currentButton);
    }];
    timer.tolerance = 0.1;
    objc_setAssociatedObject(controls, &kTPKPlayerReloadTimerKey, timer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL tpk_reloadPlayerToLive(id player) {
    id configuration = tpk_reloadObjectGetter(player,
                                                @selector(configuration));
    id path = tpk_reloadObjectGetter(player, @selector(path));

    if ([player respondsToSelector:@selector(setRebufferToLive:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            player, @selector(setRebufferToLive:), YES);
    }

    if (path) {
        SEL loadPathWithConfiguration = @selector(load:configuration:);
        if (configuration &&
            [player respondsToSelector:loadPathWithConfiguration]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                player, loadPathWithConfiguration, path, configuration);
        } else if ([player respondsToSelector:@selector(load:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                player, @selector(load:), path);
        } else {
            return NO;
        }
    } else {
        id source = tpk_reloadObjectGetter(player, @selector(source));
        SEL loadSourceWithConfiguration = @selector(loadSource:configuration:);
        if (source && configuration &&
            [player respondsToSelector:loadSourceWithConfiguration]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                player, loadSourceWithConfiguration, source, configuration);
        } else if (source && [player respondsToSelector:@selector(loadSource:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                player, @selector(loadSource:), source);
        } else {
            return NO;
        }
    }

    if ([player respondsToSelector:@selector(play)]) {
        ((void (*)(id, SEL))objc_msgSend)(player, @selector(play));
    }
    return YES;
}

@implementation TPKPlayerReloadTarget

+ (instancetype)sharedTarget {
    static TPKPlayerReloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [TPKPlayerReloadTarget new];
    });
    return target;
}

- (void)tpk_playerReloadButtonTapped:(UIButton *)sender {
    if (!tpk_playerToolsEnabled()) return;
    if (!sender || [objc_getAssociatedObject(sender, &kTPKPlayerReloadPendingKey)
                       boolValue]) {
        return;
    }

    UIView *controls = tpk_reloadControlsForButton(sender);
    id player = tpk_reloadFindActivePlayer(controls);
    if (!player || !tpk_reloadPlayerToLive(player)) {
        tpk_reloadUpdateButton(sender);
        return;
    }

    objc_setAssociatedObject(sender, &kTPKPlayerReloadPendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sender.enabled = NO;
    sender.alpha = 0.55;

    __weak UIButton *weakButton = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIButton *button = weakButton;
        if (!button) return;
        objc_setAssociatedObject(button, &kTPKPlayerReloadPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        button.enabled = YES;
        tpk_reloadUpdateButton(button);
    });
}

- (void)tpk_playerStatsButtonTapped:(UIButton *)sender {
    if (!tpk_playerToolsEnabled() || !tpk_playerStatsEnabled()) return;
    if (!sender) return;

    UIView *controls = tpk_reloadControlsForButton(sender);
    if (!controls) return;

    TPKPlayerStatsPanel *panel = tpk_reloadStatsPanelForControls(controls);
    BOOL shouldShow = panel.hidden;
    panel.hidden = !shouldShow;
    panel.alpha = shouldShow ? 1.0 : 0.0;
    if (shouldShow) {
        [panel.superview bringSubviewToFront:panel];
        tpk_reloadUpdateStatsPanelForControls(
            controls, tpk_reloadFindActivePlayer(controls));
    }
}

@end

static UIButton *tpk_reloadButtonInControls(UIView *controls) {
    UIButton *associated = objc_getAssociatedObject(
        controls, &kTPKPlayerReloadButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kTPKPlayerReloadButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier
                isEqualToString:kTPKPlayerReloadButtonIdentifier]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static void tpk_reloadSetToolsEnabledForControls(UIView *controls,
                                                   BOOL enabled) {
    if (!controls) return;

    UIButton *reloadButton = tpk_reloadButtonInControls(controls);
    UIButton *statsButton = tpk_reloadStatsButtonInControls(controls);
    BOOL statsEnabled = enabled && tpk_playerStatsEnabled();
    if (reloadButton) {
        objc_setAssociatedObject(controls, &kTPKPlayerReloadButtonKey,
                                 reloadButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        reloadButton.hidden = !enabled;
        reloadButton.enabled = enabled &&
            ![objc_getAssociatedObject(reloadButton,
                                       &kTPKPlayerReloadPendingKey) boolValue];
    }
    if (statsButton) {
        objc_setAssociatedObject(controls, &kTPKPlayerStatsButtonKey,
                                 statsButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        statsButton.hidden = !statsEnabled;
        statsButton.enabled = statsEnabled;
    }

    if (!enabled) {
        NSTimer *timer = objc_getAssociatedObject(
            controls, &kTPKPlayerReloadTimerKey);
        [timer invalidate];
        objc_setAssociatedObject(controls, &kTPKPlayerReloadTimerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    }

    if (!statsEnabled) {
        UIView *panel = tpk_reloadExistingStatsPanel(controls);
        panel.hidden = YES;
        panel.alpha = 0.0;
    }
}

static void tpk_reloadInstallButton(UIView *controls) {
    if (!controls) return;
    if (!controls.window) {
        return;
    }
    if (!tpk_playerToolsEnabled()) {
        return;
    }
    if (!tpk_playerReloadIsControlsView(controls)) {
        return;
    }

    UIButton *button = tpk_reloadButtonInControls(controls);
    if (button) {
        if (tpk_isReactPlayerControlsContainer(controls)) {
            tpk_playerReactControlsButtonStack(controls);
        }
        objc_setAssociatedObject(controls, &kTPKPlayerReloadButtonKey, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tpk_reloadRegisterButtonForHitTesting(controls, button);
        tpk_reloadInstallStatsButton(controls, button);
        tpk_reloadUpdateButton(button);
        tpk_reloadStartTimer(controls, button);
        return;
    }

    UIView *anchor = nil;
    UIStackView *stack = tpk_reloadViewerButtonStack(controls, &anchor);
    if (!stack) {
        return;
    }

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = kTPKPlayerReloadButtonIdentifier;
    button.accessibilityLabel = @"Reset stream delay";
    button.accessibilityHint = @"Reload the live stream";
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.titleLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:13.0
                                         weight:UIFontWeightSemibold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateDisabled];
    [button setTitle:@"LIVE" forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    tpk_reloadStyleDelayButton(button);
    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintEqualToConstant:24.0],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:54.0],
    ]];
    [button addTarget:[TPKPlayerReloadTarget sharedTarget]
               action:@selector(tpk_playerReloadButtonTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    NSUInteger anchorIndex = NSNotFound;
    if (anchor) {
        anchorIndex = [stack.arrangedSubviews indexOfObject:anchor];
    }
    if (anchorIndex != NSNotFound) {
        [stack insertArrangedSubview:button atIndex:anchorIndex + 1];
    } else {
        [stack addArrangedSubview:button];
    }
    tpk_reloadRegisterButtonForHitTesting(controls, button);

    objc_setAssociatedObject(controls, &kTPKPlayerReloadButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tpk_reloadInstallStatsButton(controls, button);
    tpk_reloadUpdateButton(button);
    tpk_reloadStartTimer(controls, button);
}

void tpk_handlePlayerReloadViewLifecycle(UIView *view) {
    // React Native can load after startup, so retry its hooks here.
    tpk_playerReactInstallHooks();

    if (!tpk_playerReloadIsControlsView(view)) return;
    if (!tpk_playerToolsEnabled()) {
        tpk_reloadSetToolsEnabledForControls(view, NO);
        return;
    }
    if (!view.window) {
        NSTimer *timer = objc_getAssociatedObject(
            view, &kTPKPlayerReloadTimerKey);
        [timer invalidate];
        objc_setAssociatedObject(view, &kTPKPlayerReloadTimerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    tpk_reloadInstallButton(view);
}

static void tpk_reloadApplyToolsSettingToView(UIView *view, BOOL enabled) {
    if (!view) return;

    if (tpk_playerReloadIsControlsView(view)) {
        if (enabled) {
            tpk_reloadInstallButton(view);
        } else {
            tpk_reloadSetToolsEnabledForControls(view, NO);
        }
    }

    for (UIView *subview in [view.subviews copy]) {
        tpk_reloadApplyToolsSettingToView(subview, enabled);
    }
}

static void tpk_reloadRefreshToolsInApplication(BOOL enabled) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        tpk_reloadApplyToolsSettingToView(window, enabled);
    }
}

void tpk_setPlayerToolsEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kTPKPlayerToolsEnabledKey];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_reloadRefreshToolsInApplication(enabled);
    });
}

void tpk_setPlayerStatsEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kTPKPlayerStatsEnabledKey];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_reloadRefreshToolsInApplication(tpk_playerToolsEnabled());
    });
}
