/* Player tools: delay reset and stream statistics. */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#import "System/7tv-system-player-reload.h"
#import "UI/7tv-oled-mode.h"

static NSString *const kS7TVPlayerControlsClass =
    @"Twitch.TheaterPlayerControlsView";
static NSString *const kS7TVPlayerCoreClass =
    @"Twitch.PlayerCoreVideoPlayer";
static NSString *const kS7TVPlayerReloadButtonIdentifier =
    @"s7tv_player_reload_button";
static NSString *const kS7TVPlayerStatsButtonIdentifier =
    @"s7tv_player_stats_button";
static NSString *const kS7TVPlayerToolsEnabledKey =
    @"s7tv_player_tools_enabled";
static NSString *const kS7TVPlayerStatsEnabledKey =
    @"s7tv_player_stats_enabled";

static char kS7TVPlayerReloadButtonKey;
static char kS7TVPlayerReloadTimerKey;
static char kS7TVPlayerReloadInstallAttemptKey;
static char kS7TVPlayerReloadPendingKey;
static char kS7TVPlayerReloadLastTitleKey;
static char kS7TVPlayerStatsButtonKey;
static char kS7TVPlayerStatsPanelKey;
static char kS7TVPlayerStatsLastLatencyKey;
static char kS7TVPlayerStatsLastUpdateTimeKey;
static char kS7TVPlayerButtonsStackKey;
static char kS7TVPlayerReloadInstallScheduledKey;
static char kS7TVPlayerReloadFallbackPlayerKey;
static char kS7TVPlayerReloadFallbackSearchTimeKey;
static char kS7TVPlayerReloadStyledHeightKey;
static char kS7TVPlayerReloadVODStateKey;

static const CGFloat kS7TVPlayerStatsPanelWidth = 238.0;
static const CGFloat kS7TVPlayerStatsPanelHeight = 200.0;

static Class s7tv_playerReloadControlsClass(void) {
    static Class controlsClass;
    if (!controlsClass) {
        controlsClass = NSClassFromString(kS7TVPlayerControlsClass);
    }
    return controlsClass;
}

static BOOL s7tv_playerReloadIsControlsView(UIView *view) {
    Class controlsClass = s7tv_playerReloadControlsClass();
    return view && controlsClass && view.class == controlsClass;
}

static UIView *s7tv_playerReloadTheaterForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class)
                isEqualToString:@"Twitch.TheaterView"]) {
            return cursor;
        }
    }
    return nil;
}

void s7tv_setPlayerReloadVODState(UIView *view, BOOL isVOD) {
    UIView *theater = s7tv_playerReloadTheaterForView(view);
    if (!theater) return;
    objc_setAssociatedObject(theater, &kS7TVPlayerReloadVODStateKey,
                             isVOD ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL s7tv_playerReloadIsVODControls(UIView *controls) {
    UIView *theater = s7tv_playerReloadTheaterForView(controls);
    return [objc_getAssociatedObject(theater,
                                     &kS7TVPlayerReloadVODStateKey) boolValue];
}

static NSString *const kS7TVPlayerCaptureLock =
    @"com.twitchplusk.player-capture";
static NSString *const kS7TVPlayerHooksLock =
    @"com.twitchplusk.player-hooks";
static __weak id s7tv_reloadCapturedPlayer;

@interface S7TVPlayerReloadWeakReference : NSObject
@property (nonatomic, weak) id object;
@end

@implementation S7TVPlayerReloadWeakReference
@end

static IMP s7tv_reloadOriginalIVSLoadSourceConfiguration;
static IMP s7tv_reloadOriginalIVSLoadSource;
static IMP s7tv_reloadOriginalIVSLoadConfiguration;
static IMP s7tv_reloadOriginalIVSPlay;
static IMP s7tv_reloadOriginalPlayerCoreState;
static IMP s7tv_reloadOriginalPlayerCoreQuality;
static BOOL s7tv_reloadIVSLoadSourceConfigurationHooked;
static BOOL s7tv_reloadIVSLoadSourceHooked;
static BOOL s7tv_reloadIVSLoadConfigurationHooked;
static BOOL s7tv_reloadIVSPlayHooked;
static BOOL s7tv_reloadPlayerCoreStateHooked;
static BOOL s7tv_reloadPlayerCoreQualityHooked;

static void s7tv_reloadUpdateStatsPanelForControls(UIView *controls,
                                                   id player);
static void s7tv_reloadInstallButton(UIView *controls);

BOOL s7tv_playerToolsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:kS7TVPlayerToolsEnabledKey]) return NO;
    return [defaults boolForKey:kS7TVPlayerToolsEnabledKey];
}

BOOL s7tv_playerStatsEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:kS7TVPlayerStatsEnabledKey]) return NO;
    return [defaults boolForKey:kS7TVPlayerStatsEnabledKey];
}

static BOOL s7tv_reloadLooksLikePlayer(id object) {
    return object &&
        [object respondsToSelector:@selector(loadSource:configuration:)] &&
        [object respondsToSelector:@selector(source)] &&
        [object respondsToSelector:@selector(liveLatency)];
}

static void s7tv_reloadRememberPlayer(id player) {
    if (!s7tv_reloadLooksLikePlayer(player)) return;

    @synchronized(kS7TVPlayerCaptureLock) {
        s7tv_reloadCapturedPlayer = player;
    }
}

static id s7tv_reloadCapturedPlayerObject(void) {
    @synchronized(kS7TVPlayerCaptureLock) {
        return s7tv_reloadCapturedPlayer;
    }
}

static BOOL s7tv_reloadInstallHook(Class targetClass,
                                   SEL selector,
                                   IMP replacement,
                                   IMP *originalStorage,
                                   BOOL *hooked) {
    if (!targetClass || !selector || !replacement || !originalStorage ||
        !hooked) return NO;
    if (*hooked) return YES;

    Method method = class_getInstanceMethod(targetClass, selector);
    if (!method) return NO;

    *originalStorage = method_setImplementation(method, replacement);
    *hooked = YES;
    return YES;
}

static void s7tv_reloadIVSLoadSourceConfiguration(id self,
                                                  SEL selector,
                                                  id source,
                                                  id configuration) {
    s7tv_reloadRememberPlayer(self);
    IMP original = s7tv_reloadOriginalIVSLoadSourceConfiguration;
    if (original) {
        ((void (*)(id, SEL, id, id))original)(self, selector, source,
                                               configuration);
    }
}

static void s7tv_reloadIVSLoadSource(id self,
                                     SEL selector,
                                     id source) {
    s7tv_reloadRememberPlayer(self);
    IMP original = s7tv_reloadOriginalIVSLoadSource;
    if (original) {
        ((void (*)(id, SEL, id))original)(self, selector, source);
    }
}

static void s7tv_reloadIVSLoadConfiguration(id self,
                                            SEL selector,
                                            id source,
                                            id configuration) {
    s7tv_reloadRememberPlayer(self);
    IMP original = s7tv_reloadOriginalIVSLoadConfiguration;
    if (original) {
        ((void (*)(id, SEL, id, id))original)(self, selector, source,
                                               configuration);
    }
}

static void s7tv_reloadIVSPlay(id self, SEL selector) {
    s7tv_reloadRememberPlayer(self);
    IMP original = s7tv_reloadOriginalIVSPlay;
    if (original) ((void (*)(id, SEL))original)(self, selector);
}

static void s7tv_reloadPlayerCoreDidChangeState(id self,
                                                SEL selector,
                                                id player,
                                                long long state) {
    s7tv_reloadRememberPlayer(player);
    IMP original = s7tv_reloadOriginalPlayerCoreState;
    if (original) {
        ((void (*)(id, SEL, id, long long))original)(self, selector, player,
                                                     state);
    }
}

static void s7tv_reloadPlayerCoreDidChangeQuality(id self,
                                                  SEL selector,
                                                  id player,
                                                  id quality) {
    s7tv_reloadRememberPlayer(player);
    IMP original = s7tv_reloadOriginalPlayerCoreQuality;
    if (original) {
        ((void (*)(id, SEL, id, id))original)(self, selector, player, quality);
    }
}

static void s7tv_reloadInstallRuntimeHooks(void) {
    @synchronized(kS7TVPlayerHooksLock) {
        Class ivsPlayerClass = NSClassFromString(@"IVSPlayer");
        s7tv_reloadInstallHook(
            ivsPlayerClass, @selector(loadSource:configuration:),
            (IMP)s7tv_reloadIVSLoadSourceConfiguration,
            &s7tv_reloadOriginalIVSLoadSourceConfiguration,
            &s7tv_reloadIVSLoadSourceConfigurationHooked);
        s7tv_reloadInstallHook(
            ivsPlayerClass, @selector(loadSource:),
            (IMP)s7tv_reloadIVSLoadSource,
            &s7tv_reloadOriginalIVSLoadSource,
            &s7tv_reloadIVSLoadSourceHooked);
        s7tv_reloadInstallHook(
            ivsPlayerClass, @selector(load:configuration:),
            (IMP)s7tv_reloadIVSLoadConfiguration,
            &s7tv_reloadOriginalIVSLoadConfiguration,
            &s7tv_reloadIVSLoadConfigurationHooked);
        s7tv_reloadInstallHook(
            ivsPlayerClass, @selector(play), (IMP)s7tv_reloadIVSPlay,
            &s7tv_reloadOriginalIVSPlay, &s7tv_reloadIVSPlayHooked);

        Class playerCoreClass = NSClassFromString(kS7TVPlayerCoreClass);
        s7tv_reloadInstallHook(
            playerCoreClass, @selector(player:didChangeState:),
            (IMP)s7tv_reloadPlayerCoreDidChangeState,
            &s7tv_reloadOriginalPlayerCoreState,
            &s7tv_reloadPlayerCoreStateHooked);
        s7tv_reloadInstallHook(
            playerCoreClass, @selector(player:didChangeQuality:),
            (IMP)s7tv_reloadPlayerCoreDidChangeQuality,
            &s7tv_reloadOriginalPlayerCoreQuality,
            &s7tv_reloadPlayerCoreQualityHooked);
    }
}

void s7tv_setupPlayerReloadRuntimeHooks(void) {
    s7tv_reloadInstallRuntimeHooks();
}

static id s7tv_reloadObjectIvar(id object, const char *name) {
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

static id s7tv_reloadObjectGetter(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void s7tv_reloadAppendCandidate(NSMutableArray *queue,
                                       NSHashTable *visited,
                                       id candidate) {
    if (!candidate || ![candidate isKindOfClass:NSObject.class] ||
        [visited containsObject:candidate]) {
        return;
    }
    [visited addObject:candidate];
    [queue addObject:candidate];
}

static id s7tv_reloadCacheFallbackPlayer(UIView *controls, id player) {
    S7TVPlayerReloadWeakReference *reference = objc_getAssociatedObject(
        controls, &kS7TVPlayerReloadFallbackPlayerKey);
    if (!reference) {
        reference = [S7TVPlayerReloadWeakReference new];
        objc_setAssociatedObject(controls, &kS7TVPlayerReloadFallbackPlayerKey,
                                 reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    reference.object = player;
    objc_setAssociatedObject(controls,
                             &kS7TVPlayerReloadFallbackSearchTimeKey,
                             @(CFAbsoluteTimeGetCurrent()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return player;
}

static id s7tv_reloadFindActivePlayer(UIView *controls) {
    if (!controls) return nil;

    id capturedPlayer = s7tv_reloadCapturedPlayerObject();
    if (capturedPlayer) return capturedPlayer;

    // Avoid repeating the fallback hierarchy scan.
    NSNumber *lastSearch = objc_getAssociatedObject(
        controls, &kS7TVPlayerReloadFallbackSearchTimeKey);
    if (lastSearch &&
        (CFAbsoluteTimeGetCurrent() - lastSearch.doubleValue) < 0.75) {
        S7TVPlayerReloadWeakReference *reference = objc_getAssociatedObject(
            controls, &kS7TVPlayerReloadFallbackPlayerKey);
        return reference.object;
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
        "nativeVideoOverlayPlugin",
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
        "nativeVideoOverlayPlugin",
    };
    const NSUInteger knownCount = sizeof(knownIvars) / sizeof(knownIvars[0]);

    for (NSUInteger index = 0; index < queue.count && index < 64; index++) {
        id candidate = queue[index];
        NSString *className = NSStringFromClass([candidate class]);

        if (s7tv_reloadLooksLikePlayer(candidate)) {
            return s7tv_reloadCacheFallbackPlayer(controls, candidate);
        }

        if ([className rangeOfString:@"PlayerCoreVideoPlayer"].location !=
            NSNotFound) {
            id player = s7tv_reloadObjectIvar(candidate, "ttvPlayer");
            if (!player) {
                player = s7tv_reloadObjectGetter(candidate,
                                                 @selector(ttvPlayer));
            }
            if (s7tv_reloadLooksLikePlayer(player)) {
                return s7tv_reloadCacheFallbackPlayer(controls, player);
            }
            s7tv_reloadAppendCandidate(queue, visited, player);
        }

        if ([className rangeOfString:@"PortalIVSPlayer"].location != NSNotFound) {
            id player = s7tv_reloadObjectIvar(candidate, "player");
            if (!player) {
                player = s7tv_reloadObjectGetter(candidate, @selector(player));
            }
            if (s7tv_reloadLooksLikePlayer(player)) {
                return s7tv_reloadCacheFallbackPlayer(controls, player);
            }
            s7tv_reloadAppendCandidate(queue, visited, player);
        }

        if ([candidate isKindOfClass:UIView.class]) {
            UIView *view = candidate;
            s7tv_reloadAppendCandidate(queue, visited, view.superview);
            s7tv_reloadAppendCandidate(queue, visited, view.nextResponder);
        }

        for (NSUInteger edge = 0; edge < knownCount; edge++) {
            id child = s7tv_reloadObjectIvar(candidate, knownIvars[edge]);
            if (!child) {
                child = s7tv_reloadObjectGetter(
                    candidate, sel_registerName(knownGetterNames[edge]));
            }
            s7tv_reloadAppendCandidate(queue, visited, child);
        }
    }

    return s7tv_reloadCacheFallbackPlayer(controls, nil);
}

static UIView *s7tv_reloadControlsForButton(UIButton *button) {
    UIView *ancestor = button;
    while (ancestor) {
        if (s7tv_playerReloadIsControlsView(ancestor)) {
            return ancestor;
        }
        ancestor = ancestor.superview;
    }
    return nil;
}

static id s7tv_reloadControlsObject(UIView *controls,
                                    const char *ivarName,
                                    SEL getter) {
    id object = s7tv_reloadObjectIvar(controls, ivarName);
    return object ?: s7tv_reloadObjectGetter(controls, getter);
}

static void s7tv_reloadRegisterButtonForHitTesting(UIView *controls,
                                                   UIButton *button) {
    if (!controls || !button) return;

    id allButtons = s7tv_reloadControlsObject(controls, "allButtons",
                                              @selector(allButtons));
    if (![allButtons isKindOfClass:NSArray.class]) return;

    NSMutableArray *updatedButtons = [allButtons mutableCopy];
    if ([updatedButtons containsObject:button]) return;
    [updatedButtons addObject:button];
    SEL setter = @selector(setAllButtons:);
    if ([controls respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controls, setter, updatedButtons);
    }
}

static UIStackView *s7tv_reloadTargetStack(UIView *controls,
                                           UIView **anchorButton) {
    if (anchorButton) *anchorButton = nil;

    NSArray<NSDictionary *> *anchors = @[
        @{ @"ivar": @"liveIndicatorView", @"selector": NSStringFromSelector(@selector(liveIndicatorView)) },
        @{ @"ivar": @"shareButton", @"selector": NSStringFromSelector(@selector(shareButton)) },
        @{ @"ivar": @"rotateButton", @"selector": NSStringFromSelector(@selector(rotateButton)) },
    ];

    for (NSDictionary *anchorInfo in anchors) {
        UIView *anchor = s7tv_reloadControlsObject(
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
        UIStackView *stack = s7tv_reloadControlsObject(
            controls, [stackInfo[@"ivar"] UTF8String],
            NSSelectorFromString(stackInfo[@"selector"]));
        if ([stack isKindOfClass:UIStackView.class]) return stack;
    }

    return nil;
}

static UIStackView *s7tv_reloadViewerButtonStack(UIView *controls,
                                                 UIView **anchorButton) {
    if (anchorButton) *anchorButton = nil;
    if (!controls) return nil;

    UIStackView *associated = objc_getAssociatedObject(
        controls, &kS7TVPlayerButtonsStackKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kS7TVPlayerButtonsStackKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *viewerIndicator = s7tv_reloadControlsObject(
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
        stack.accessibilityIdentifier = @"s7tv_player_buttons_stack";
        [controls addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:viewerIndicator.trailingAnchor
                                                 constant:8.0],
            [stack.centerYAnchor constraintEqualToAnchor:viewerIndicator.centerYAnchor],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:controls.trailingAnchor
                                                              constant:-8.0],
            [stack.heightAnchor constraintEqualToConstant:24.0],
        ]];
        objc_setAssociatedObject(controls, &kS7TVPlayerButtonsStackKey, stack,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return stack;
    }

    return s7tv_reloadTargetStack(controls, anchorButton);
}

static CMTime s7tv_reloadLatency(id player) {
    if (!player || ![player respondsToSelector:@selector(liveLatency)]) {
        return kCMTimeInvalid;
    }
    return ((CMTime (*)(id, SEL))objc_msgSend)(player,
                                               @selector(liveLatency));
}

static NSString *s7tv_reloadTitleForPlayer(id player) {
    if (!player) return @"—";

    CMTime latency = s7tv_reloadLatency(player);
    Float64 seconds = CMTimeGetSeconds(latency);
    if (!CMTIME_IS_NUMERIC(latency) || !isfinite(seconds) || seconds < 0.0) {
        return @"LIVE";
    }
    return [NSString stringWithFormat:@"%.1fs", seconds];
}

static NSString *s7tv_reloadDisplayTitleForButton(UIButton *button, id player) {
    NSString *title = s7tv_reloadTitleForPlayer(player);
    BOOL hasLiveDelay = player && [title hasSuffix:@"s"];
    if (hasLiveDelay) {
        objc_setAssociatedObject(button, &kS7TVPlayerReloadLastTitleKey,
                                 title, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return title;
    }

    // Keep the last valid delay during reload.
    NSString *lastTitle = objc_getAssociatedObject(
        button, &kS7TVPlayerReloadLastTitleKey);
    return lastTitle.length ? lastTitle : title;
}

static BOOL s7tv_reloadBoolValue(id object, SEL selector, BOOL fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long s7tv_reloadLongLongValue(id object, SEL selector,
                                          long long fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
}

static float s7tv_reloadFloatValue(id object, SEL selector, float fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((float (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGSize s7tv_reloadSizeValue(id object, SEL selector,
                                   CGSize fallback) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return fallback;
    }
    return ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *s7tv_reloadCMTimeText(id object, SEL selector) {
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

static NSString *s7tv_reloadBitrateText(long long bitsPerSecond) {
    if (bitsPerSecond <= 0) return @"—";
    if (bitsPerSecond >= 1000000) {
        return [NSString stringWithFormat:@"%.2f Mbps",
                                          (double)bitsPerSecond / 1000000.0];
    }
    return [NSString stringWithFormat:@"%lld kbps",
                                      bitsPerSecond / 1000];
}

static NSString *s7tv_reloadLatencyText(id player) {
    if (!player) return @"—";

    CMTime latency = s7tv_reloadLatency(player);
    Float64 seconds = CMTimeGetSeconds(latency);
    if (!CMTIME_IS_NUMERIC(latency) || !isfinite(seconds) || seconds < 0.0) {
        return @"—";
    }
    return [NSString stringWithFormat:@"%.2fs", seconds];
}

@interface S7TVPlayerStatsPanel : UIView
- (void)updateWithPlayer:(id)player;
- (void)rememberLatencyText:(NSString *)text;
@end

@implementation S7TVPlayerStatsPanel {
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
                                                action:@selector(s7tv_handlePan:)];
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
           selector:@selector(s7tv_oledModeDidChange:)
               name:S7TVOLEDModeDidChangeNotification
             object:nil];
    [self s7tv_updateAppearance];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:S7TVOLEDModeDidChangeNotification
                object:nil];
}

- (void)s7tv_updateAppearance {
    self.backgroundColor = S7TVOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.07 alpha:0.97];
}

- (void)s7tv_oledModeDidChange:(__unused NSNotification *)note {
    if (NSThread.isMainThread) {
        [self s7tv_updateAppearance];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self s7tv_updateAppearance];
        });
    }
}

- (void)s7tv_handlePan:(UIPanGestureRecognizer *)gesture {
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
        objc_setAssociatedObject(self, &kS7TVPlayerStatsLastLatencyKey,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

- (void)updateWithPlayer:(id)player {
    if (!player) {
        for (UILabel *label in _rowLabels) {
            if (![label.text isEqualToString:@"—"]) label.text = @"—";
        }
        NSString *lastLatency = objc_getAssociatedObject(
            self, &kS7TVPlayerStatsLastLatencyKey);
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

    id quality = s7tv_reloadObjectGetter(player, @selector(quality));
    long long qualityWidth = s7tv_reloadLongLongValue(quality, @selector(width), 0);
    long long qualityHeight = s7tv_reloadLongLongValue(quality, @selector(height), 0);
    float framerate = s7tv_reloadFloatValue(quality, @selector(framerate), 0.0f);
    long long qualityBitrate = s7tv_reloadLongLongValue(quality,
                                                         @selector(bitrate), 0);
    CGSize videoSize = s7tv_reloadSizeValue(player, @selector(videoSize),
                                            CGSizeZero);
    long long width = qualityWidth > 0 ? qualityWidth : (long long)videoSize.width;
    long long height = qualityHeight > 0 ? qualityHeight : (long long)videoSize.height;
    long long bitrate = s7tv_reloadLongLongValue(player, @selector(videoBitrate),
                                                  qualityBitrate);
    if (bitrate <= 0) bitrate = qualityBitrate;

    BOOL lowLatency = s7tv_reloadBoolValue(player, @selector(isLiveLowLatency),
                                           NO);
    if ([player respondsToSelector:@selector(liveLowLatency)]) {
        lowLatency = s7tv_reloadBoolValue(player, @selector(liveLowLatency),
                                          lowLatency);
    }

    NSString *qualityName = s7tv_reloadObjectGetter(quality, @selector(name));
    if (![qualityName isKindOfClass:NSString.class] || qualityName.length == 0) {
        qualityName = @"—";
    }

    NSString *latencyText = s7tv_reloadLatencyText(player);
    if ([latencyText hasSuffix:@"s"]) {
        [self rememberLatencyText:latencyText];
    } else {
        NSString *lastLatency = objc_getAssociatedObject(
            self, &kS7TVPlayerStatsLastLatencyKey);
        if (lastLatency.length) latencyText = lastLatency;
    }

    long long averageBitrate = s7tv_reloadLongLongValue(
        player, @selector(averageBitrate), 0);
    long long bandwidth = s7tv_reloadLongLongValue(
        player, @selector(bandwidthEstimate), 0);
    long long droppedFrames = s7tv_reloadLongLongValue(
        player, @selector(videoFramesDropped), 0);
    long long decodedFrames = s7tv_reloadLongLongValue(
        player, @selector(videoFramesDecoded), 0);
    float playbackRate = s7tv_reloadFloatValue(player, @selector(playbackRate),
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
        [NSString stringWithFormat:@"Bitrate: %@", s7tv_reloadBitrateText(bitrate)],
        [NSString stringWithFormat:@"Average Bitrate: %@",
                                  s7tv_reloadBitrateText(averageBitrate)],
        [NSString stringWithFormat:@"Bandwidth: %@", s7tv_reloadBitrateText(bandwidth)],
        [NSString stringWithFormat:@"Dropped Frames: %lld", MAX(0LL, droppedFrames)],
        [NSString stringWithFormat:@"Decoded Frames: %lld", MAX(0LL, decodedFrames)],
        [NSString stringWithFormat:@"Playback Rate: %.2fx", playbackRate],
        [NSString stringWithFormat:@"Buffer: %@",
                                  s7tv_reloadCMTimeText(player, @selector(buffered))],
        [NSString stringWithFormat:@"Position: %@",
                                  s7tv_reloadCMTimeText(player, @selector(position))],
        [NSString stringWithFormat:@"Quality: %@", qualityName],
    ];
    for (NSUInteger index = 0; index < _rowLabels.count; index++) {
        if (![_rowLabels[index].text isEqualToString:lines[index]]) {
            _rowLabels[index].text = lines[index];
        }
    }
}

@end

static UIButton *s7tv_reloadStatsButtonInControls(UIView *controls) {
    UIButton *associated = objc_getAssociatedObject(
        controls, &kS7TVPlayerStatsButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kS7TVPlayerStatsButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier
                isEqualToString:kS7TVPlayerStatsButtonIdentifier]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static S7TVPlayerStatsPanel *s7tv_reloadStatsPanelForControls(UIView *controls) {
    if (!controls) return nil;

    S7TVPlayerStatsPanel *panel = objc_getAssociatedObject(
        controls, &kS7TVPlayerStatsPanelKey);
    UIWindow *host = controls.window;
    if (panel) {
        if (host && panel.superview != host) {
            [panel removeFromSuperview];
            [host addSubview:panel];
            panel.frame = CGRectMake(8.0, 8.0,
                                     kS7TVPlayerStatsPanelWidth,
                                     kS7TVPlayerStatsPanelHeight);
        }
        return panel;
    }
    if (!host) return nil;

    panel = [[S7TVPlayerStatsPanel alloc] init];
    panel.accessibilityIdentifier = @"s7tv_player_stats_panel";
    CGRect videoRect = [controls convertRect:controls.bounds toView:host];
    CGFloat x = CGRectGetMinX(videoRect) + 8.0;
    CGFloat y = CGRectGetMinY(videoRect) + 8.0;
    CGRect hostBounds = host.bounds;
    if (CGRectGetWidth(hostBounds) > kS7TVPlayerStatsPanelWidth) {
        x = MIN(MAX(x, CGRectGetMinX(hostBounds)),
                CGRectGetMaxX(hostBounds) - kS7TVPlayerStatsPanelWidth);
    }
    if (CGRectGetHeight(hostBounds) > kS7TVPlayerStatsPanelHeight) {
        y = MIN(MAX(y, CGRectGetMinY(hostBounds)),
                CGRectGetMaxY(hostBounds) - kS7TVPlayerStatsPanelHeight);
    }
    panel.frame = CGRectMake(x, y, kS7TVPlayerStatsPanelWidth,
                             kS7TVPlayerStatsPanelHeight);
    [host addSubview:panel];
    [host bringSubviewToFront:panel];
    objc_setAssociatedObject(controls, &kS7TVPlayerStatsPanelKey, panel,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return panel;
}

static void s7tv_reloadUpdateStatsPanelForControls(UIView *controls,
                                                   id player) {
    if (!s7tv_playerToolsEnabled() || !s7tv_playerStatsEnabled()) return;
    S7TVPlayerStatsPanel *panel = objc_getAssociatedObject(
        controls, &kS7TVPlayerStatsPanelKey);
    if (!panel || panel.hidden) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *lastUpdate = objc_getAssociatedObject(
        panel, &kS7TVPlayerStatsLastUpdateTimeKey);
    if (lastUpdate && (now - lastUpdate.doubleValue) < 0.9) return;
    objc_setAssociatedObject(panel, &kS7TVPlayerStatsLastUpdateTimeKey,
                             @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIButton *reloadButton = objc_getAssociatedObject(
        controls, &kS7TVPlayerReloadButtonKey);
    NSString *lastButtonTitle = objc_getAssociatedObject(
        reloadButton, &kS7TVPlayerReloadLastTitleKey);
    [panel rememberLatencyText:lastButtonTitle];
    [panel updateWithPlayer:player];
}

@interface S7TVPlayerReloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)s7tv_playerReloadButtonTapped:(UIButton *)sender;
- (void)s7tv_playerStatsButtonTapped:(UIButton *)sender;
@end

static void s7tv_reloadInstallStatsButton(UIView *controls,
                                          UIButton *reloadButton) {
    if (!controls || !s7tv_playerToolsEnabled()) return;

    UIButton *statsButton = s7tv_reloadStatsButtonInControls(controls);
    if (!s7tv_playerStatsEnabled()) {
        statsButton.hidden = YES;
        statsButton.enabled = NO;
        UIView *panel = objc_getAssociatedObject(
            controls, &kS7TVPlayerStatsPanelKey);
        panel.hidden = YES;
        panel.alpha = 0.0;
        return;
    }
    if (statsButton) {
        objc_setAssociatedObject(controls, &kS7TVPlayerStatsButtonKey,
                                 statsButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        reloadButton.hidden = NO;
        reloadButton.enabled = ![objc_getAssociatedObject(
            reloadButton, &kS7TVPlayerReloadPendingKey) boolValue];
        statsButton.hidden = NO;
        statsButton.enabled = YES;
        s7tv_reloadRegisterButtonForHitTesting(controls, statsButton);
        return;
    }

    UIStackView *stack = nil;
    if ([reloadButton.superview isKindOfClass:UIStackView.class]) {
        stack = (UIStackView *)reloadButton.superview;
    }
    if (!stack) {
        stack = s7tv_reloadTargetStack(controls, NULL);
    }
    if (!stack) return;

    statsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    statsButton.translatesAutoresizingMaskIntoConstraints = NO;
    statsButton.accessibilityIdentifier = kS7TVPlayerStatsButtonIdentifier;
    statsButton.accessibilityLabel = @"Video player statistics";
    statsButton.accessibilityHint = @"Show stream statistics";
    statsButton.accessibilityTraits = UIAccessibilityTraitButton;
    statsButton.tintColor = UIColor.whiteColor;
    statsButton.contentEdgeInsets = UIEdgeInsetsMake(0.0, 3.0, 0.0, 3.0);
    UIImage *statsImage = [UIImage systemImageNamed:@"chart.bar"];
    if (statsImage) {
        [statsButton setImage:statsImage forState:UIControlStateNormal];
    } else {
        [statsButton setTitle:@"Stats" forState:UIControlStateNormal];
        [statsButton setTitleColor:UIColor.whiteColor
                          forState:UIControlStateNormal];
        statsButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
    }
    [statsButton addTarget:[S7TVPlayerReloadTarget sharedTarget]
                    action:@selector(s7tv_playerStatsButtonTapped:)
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
    s7tv_reloadRegisterButtonForHitTesting(controls, statsButton);
    objc_setAssociatedObject(controls, &kS7TVPlayerStatsButtonKey,
                             statsButton,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void s7tv_reloadStyleDelayButton(UIButton *button) {
    if (!button) return;
    CGFloat height = CGRectGetHeight(button.bounds);
    NSNumber *lastHeight = objc_getAssociatedObject(
        button, &kS7TVPlayerReloadStyledHeightKey);
    if (lastHeight && fabs(lastHeight.doubleValue - height) < 0.1) return;
    button.layer.cornerRadius = height > 0.0 ? height * 0.5 : 12.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    button.backgroundColor = UIColor.clearColor;
    button.clipsToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, 6.0);
    objc_setAssociatedObject(button, &kS7TVPlayerReloadStyledHeightKey,
                             @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void s7tv_reloadUpdateButton(UIButton *button) {
    if (!button) return;
    if (!s7tv_playerToolsEnabled()) {
        button.hidden = YES;
        button.enabled = NO;
        return;
    }

    UIView *controls = s7tv_reloadControlsForButton(button);
    id player = s7tv_reloadFindActivePlayer(controls);
    if (s7tv_playerReloadIsVODControls(controls)) {
        button.hidden = YES;
        button.enabled = NO;

        UIButton *statsButton = objc_getAssociatedObject(
            controls, &kS7TVPlayerStatsButtonKey);
        statsButton.hidden = YES;
        statsButton.enabled = NO;

        UIView *panel = objc_getAssociatedObject(
            controls, &kS7TVPlayerStatsPanelKey);
        panel.hidden = YES;
        panel.alpha = 0.0;
        return;
    }

    button.hidden = NO;
    s7tv_reloadStyleDelayButton(button);
    NSString *title = s7tv_reloadDisplayTitleForButton(button, player);
    if (![button.currentTitle isEqualToString:title]) {
        [button setTitle:title forState:UIControlStateNormal];
    }
    button.titleLabel.hidden = NO;
    button.titleLabel.alpha = 1.0;
    BOOL pending = [objc_getAssociatedObject(
        button, &kS7TVPlayerReloadPendingKey) boolValue];
    // Restore interaction after a reload or setting change.
    button.enabled = !pending;
    button.alpha = pending
        ? 0.55
        : (player ? 1.0 : 0.65);
    s7tv_reloadUpdateStatsPanelForControls(controls, player);
}

static void s7tv_reloadStartTimer(UIView *controls, UIButton *button) {
    if (!s7tv_playerToolsEnabled()) return;
    if (objc_getAssociatedObject(controls, &kS7TVPlayerReloadTimerKey)) {
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
        s7tv_reloadUpdateButton(currentButton);
    }];
    timer.tolerance = 0.1;
    objc_setAssociatedObject(controls, &kS7TVPlayerReloadTimerKey, timer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL s7tv_reloadPlayerToLive(id player) {
    if (!player) return NO;

    id source = s7tv_reloadObjectGetter(player, @selector(source));
    if (!source) return NO;

    if ([player respondsToSelector:@selector(setRebufferToLive:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            player, @selector(setRebufferToLive:), YES);
    }

    id configuration = s7tv_reloadObjectGetter(player,
                                                @selector(configuration));
    if (configuration &&
        [player respondsToSelector:@selector(loadSource:configuration:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            player, @selector(loadSource:configuration:), source,
            configuration);
    } else if ([player respondsToSelector:@selector(loadSource:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(player, @selector(loadSource:),
                                               source);
    } else {
        return NO;
    }

    // Play again after reopening a frozen player.
    if ([player respondsToSelector:@selector(play)]) {
        __weak id weakPlayer = player;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id currentPlayer = weakPlayer;
            if (currentPlayer && [currentPlayer respondsToSelector:@selector(play)]) {
                ((void (*)(id, SEL))objc_msgSend)(currentPlayer, @selector(play));
            }
        });
    }

    return YES;
}

@implementation S7TVPlayerReloadTarget

+ (instancetype)sharedTarget {
    static S7TVPlayerReloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [S7TVPlayerReloadTarget new];
    });
    return target;
}

- (void)s7tv_playerReloadButtonTapped:(UIButton *)sender {
    if (!s7tv_playerToolsEnabled()) return;
    if (!sender || [objc_getAssociatedObject(sender, &kS7TVPlayerReloadPendingKey)
                       boolValue]) {
        return;
    }

    UIView *controls = s7tv_reloadControlsForButton(sender);
    id player = s7tv_reloadFindActivePlayer(controls);
    if (!player || !s7tv_reloadPlayerToLive(player)) {
        s7tv_reloadUpdateButton(sender);
        return;
    }

    objc_setAssociatedObject(sender, &kS7TVPlayerReloadPendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sender.enabled = NO;
    sender.alpha = 0.55;

    __weak UIButton *weakButton = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIButton *button = weakButton;
        if (!button) return;
        objc_setAssociatedObject(button, &kS7TVPlayerReloadPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        button.enabled = YES;
        s7tv_reloadUpdateButton(button);
    });
}

- (void)s7tv_playerStatsButtonTapped:(UIButton *)sender {
    if (!s7tv_playerToolsEnabled() || !s7tv_playerStatsEnabled()) return;
    if (!sender) return;

    UIView *controls = s7tv_reloadControlsForButton(sender);
    if (!controls) return;

    S7TVPlayerStatsPanel *panel = s7tv_reloadStatsPanelForControls(controls);
    BOOL shouldShow = panel.hidden;
    panel.hidden = !shouldShow;
    panel.alpha = shouldShow ? 1.0 : 0.0;
    if (shouldShow) {
        [panel.superview bringSubviewToFront:panel];
        s7tv_reloadUpdateStatsPanelForControls(
            controls, s7tv_reloadFindActivePlayer(controls));
    }
}

@end

static UIButton *s7tv_reloadButtonInControls(UIView *controls) {
    UIButton *associated = objc_getAssociatedObject(
        controls, &kS7TVPlayerReloadButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kS7TVPlayerReloadButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier
                isEqualToString:kS7TVPlayerReloadButtonIdentifier]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static void s7tv_reloadSetToolsEnabledForControls(UIView *controls,
                                                   BOOL enabled) {
    if (!controls) return;

    UIButton *reloadButton = s7tv_reloadButtonInControls(controls);
    UIButton *statsButton = s7tv_reloadStatsButtonInControls(controls);
    BOOL statsEnabled = enabled && s7tv_playerStatsEnabled();
    if (reloadButton) {
        objc_setAssociatedObject(controls, &kS7TVPlayerReloadButtonKey,
                                 reloadButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        reloadButton.hidden = !enabled;
        reloadButton.enabled = enabled &&
            ![objc_getAssociatedObject(reloadButton,
                                       &kS7TVPlayerReloadPendingKey) boolValue];
    }
    if (statsButton) {
        objc_setAssociatedObject(controls, &kS7TVPlayerStatsButtonKey,
                                 statsButton,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        statsButton.hidden = !statsEnabled;
        statsButton.enabled = statsEnabled;
    }

    if (!enabled) {
        NSTimer *timer = objc_getAssociatedObject(
            controls, &kS7TVPlayerReloadTimerKey);
        [timer invalidate];
        objc_setAssociatedObject(controls, &kS7TVPlayerReloadTimerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    }

    if (!statsEnabled) {
        UIView *panel = objc_getAssociatedObject(
            controls, &kS7TVPlayerStatsPanelKey);
        panel.hidden = YES;
        panel.alpha = 0.0;
    }
}

static void s7tv_reloadInstallButton(UIView *controls) {
    if (!controls || !controls.window ||
        !s7tv_playerToolsEnabled() ||
        !s7tv_playerReloadIsControlsView(controls)) {
        return;
    }

    UIButton *button = s7tv_reloadButtonInControls(controls);
    if (button) {
        objc_setAssociatedObject(controls, &kS7TVPlayerReloadButtonKey, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        s7tv_reloadRegisterButtonForHitTesting(controls, button);
        s7tv_reloadInstallStatsButton(controls, button);
        s7tv_reloadUpdateButton(button);
        s7tv_reloadStartTimer(controls, button);
        return;
    }

    UIView *anchor = nil;
    UIStackView *stack = s7tv_reloadViewerButtonStack(controls, &anchor);
    if (!stack) return;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = kS7TVPlayerReloadButtonIdentifier;
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
    s7tv_reloadStyleDelayButton(button);
    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintEqualToConstant:24.0],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:54.0],
    ]];
    [button addTarget:[S7TVPlayerReloadTarget sharedTarget]
               action:@selector(s7tv_playerReloadButtonTapped:)
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
    s7tv_reloadRegisterButtonForHitTesting(controls, button);

    objc_setAssociatedObject(controls, &kS7TVPlayerReloadButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s7tv_reloadInstallStatsButton(controls, button);
    objc_setAssociatedObject(controls, &kS7TVPlayerReloadInstallAttemptKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s7tv_reloadUpdateButton(button);
    s7tv_reloadStartTimer(controls, button);
}

static void s7tv_reloadScheduleInstall(UIView *controls) {
    if (!s7tv_playerToolsEnabled()) return;
    if (objc_getAssociatedObject(controls,
                                 &kS7TVPlayerReloadInstallScheduledKey)) {
        return;
    }
    NSUInteger attempts = [objc_getAssociatedObject(
        controls, &kS7TVPlayerReloadInstallAttemptKey) unsignedIntegerValue];
    if (attempts >= 6) return;

    objc_setAssociatedObject(controls, &kS7TVPlayerReloadInstallScheduledKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controls, &kS7TVPlayerReloadInstallAttemptKey,
                             @(attempts + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakControls = controls;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *currentControls = weakControls;
        if (currentControls) {
            objc_setAssociatedObject(
                currentControls, &kS7TVPlayerReloadInstallScheduledKey, nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!currentControls || !currentControls.window ||
            !s7tv_playerToolsEnabled()) return;
        s7tv_reloadInstallButton(currentControls);
        if (!objc_getAssociatedObject(currentControls,
                                      &kS7TVPlayerReloadButtonKey)) {
            s7tv_reloadScheduleInstall(currentControls);
        }
    });
}

void s7tv_handlePlayerReloadViewLifecycle(UIView *view) {
    // Filter the class before reading settings or retrying hooks.
    if (!s7tv_playerReloadIsControlsView(view)) return;

    if (!s7tv_playerToolsEnabled()) {
        s7tv_reloadSetToolsEnabledForControls(view, NO);
        return;
    }
    // Retry hook installation when the controls appear.
    s7tv_reloadInstallRuntimeHooks();
    if (!view.window) {
        NSTimer *timer = objc_getAssociatedObject(
            view, &kS7TVPlayerReloadTimerKey);
        [timer invalidate];
        objc_setAssociatedObject(view, &kS7TVPlayerReloadTimerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (s7tv_reloadButtonInControls(view)) {
        s7tv_reloadInstallButton(view);
    } else {
        s7tv_reloadScheduleInstall(view);
    }
}

static void s7tv_reloadApplyToolsSettingToView(UIView *view, BOOL enabled) {
    if (!view) return;

    if (s7tv_playerReloadIsControlsView(view)) {
        if (enabled) {
            s7tv_reloadInstallButton(view);
        } else {
            s7tv_reloadSetToolsEnabledForControls(view, NO);
        }
    }

    for (UIView *subview in [view.subviews copy]) {
        s7tv_reloadApplyToolsSettingToView(subview, enabled);
    }
}

static void s7tv_reloadRefreshToolsInApplication(BOOL enabled) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        s7tv_reloadApplyToolsSettingToView(window, enabled);
    }
}

void s7tv_setPlayerToolsEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kS7TVPlayerToolsEnabledKey];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_reloadRefreshToolsInApplication(enabled);
    });
}

void s7tv_setPlayerStatsEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kS7TVPlayerStatsEnabledKey];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_reloadRefreshToolsInApplication(s7tv_playerToolsEnabled());
    });
}
