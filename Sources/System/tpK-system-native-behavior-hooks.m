/* Adds the custom orientation button and handles auto-lock. */

#import "System/tpK-system-native-behavior-hooks.h"
#import "Core/tpK-core-manager.h"
#import "Localization/tpK-localization-manager.h"
#import "System/tpK-system-player-gestures.h"
#import "System/tpK-system-player-reload.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kTPKOrientationLockButtonEnabled =
    @"tpk_orientation_lock_button_enabled";
static NSString *const kTPKAutoOrientationLockMode =
    @"tpk_auto_orientation_lock_mode";

static char kTPKOrientationLockButtonKey;
static __weak UIView *s_activeControlsView;
static __weak UIView *s_activePlayerHostView;

static BOOL s_orientationPolicySuspended = NO;
static NSUInteger s_orientationLifecycleGeneration = 0;
static NSArray *s_orientationLifecycleObservers = nil;

@interface TPKManager (OrientationLock)
- (void)tpk_toggleOrientationLock:(UIButton *)sender;
@end

static void tpk_refreshOrientationObserver(void);
static BOOL tpk_hasOrientationLockButtonInActivePlayer(void);
static void tpk_enumerateActiveViews(void (^visit)(UIView *view));
static UIView *tpk_activePlayerGeometryView(void);
static UIWindowScene *tpk_activeWindowScene(void);
static void tpk_refreshOrientationPolicySuspension(void);
static void tpk_installOrientationLifecycleObservers(void);

static NSArray<NSNumber *> *tpk_orientationButtonStates(void) {
    return @[@(UIControlStateNormal), @(UIControlStateHighlighted),
             @(UIControlStateSelected), @(UIControlStateDisabled)];
}

static UIButton *tpk_orientationLockButtonForControls(UIView *controls) {
    if (!controls) return nil;

    UIButton *associated = objc_getAssociatedObject(
        controls, &kTPKOrientationLockButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kTPKOrientationLockButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier isEqualToString:@"tpk_lock_button"]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static UIButton *tpk_shareButtonForControls(UIView *controls) {
    if (!controls) return nil;

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier isEqualToString:@"share_button"]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static void tpk_registerOrientationButtonForHitTesting(UIView *controls,
                                                         UIButton *button) {
    if (!controls || !button || ![controls respondsToSelector:@selector(allButtons)]) {
        return;
    }

    id allButtons = ((id (*)(id, SEL))objc_msgSend)(controls,
                                                    @selector(allButtons));
    if (![allButtons isKindOfClass:NSArray.class]) return;

    NSMutableArray *updatedButtons = [allButtons mutableCopy];
    if (![updatedButtons containsObject:button]) [updatedButtons addObject:button];
    if ([controls respondsToSelector:@selector(setAllButtons:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controls,
                                              @selector(setAllButtons:),
                                              updatedButtons);
    }
}

static void tpk_removeOrientationButtonFromHitTesting(UIView *controls,
                                                        UIButton *button) {
    if (!controls || !button || ![controls respondsToSelector:@selector(allButtons)]) {
        return;
    }

    id allButtons = ((id (*)(id, SEL))objc_msgSend)(controls,
                                                    @selector(allButtons));
    if (![allButtons isKindOfClass:NSArray.class]) return;
    NSMutableArray *updatedButtons = [allButtons mutableCopy];
    [updatedButtons removeObject:button];
    if ([controls respondsToSelector:@selector(setAllButtons:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controls,
                                              @selector(setAllButtons:),
                                              updatedButtons);
    }
}

static void tpk_removeOrientationLockButton(UIView *controls) {
    if (!controls) return;
    UIButton *button = tpk_orientationLockButtonForControls(controls);
    if (!button) {
        if (s_activeControlsView == controls) s_activeControlsView = nil;
        return;
    }

    [button removeTarget:[TPKManager sharedManager]
                  action:@selector(tpk_toggleOrientationLock:)
        forControlEvents:UIControlEventTouchUpInside];
    tpk_removeOrientationButtonFromHitTesting(controls, button);
    if ([button.superview isKindOfClass:UIStackView.class]) {
        [(UIStackView *)button.superview removeArrangedSubview:button];
    }
    [button removeFromSuperview];
    objc_setAssociatedObject(controls, &kTPKOrientationLockButtonKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (s_activeControlsView == controls) s_activeControlsView = nil;
}

void tpk_handleTheaterControlsViewLifecycle(UIView *view) {
    if (!view) return;

    UIView *playerHost = tpk_playerTheaterHostForView(view);
    if (playerHost == view) {
        if (view.window && !view.window.hidden) {
            s_activePlayerHostView = view;
        } else if (s_activePlayerHostView == view) {
            s_activePlayerHostView = nil;
        }
    }
    if (!tpk_orientationLockButtonEnabled() ||
        !tpk_isPlayerControlsContainer(view) || !view.window) return;
    if (tpk_orientationLockButtonForControls(view)) {
        if (tpk_isReactPlayerControlsContainer(view)) {
            tpk_playerReactControlsButtonStack(view);
        }
        s_activeControlsView = view;
        tpk_refreshOrientationPolicySuspension();
        return;
    }

    UIView *controls = view;
    BOOL reactNativeControls = tpk_isReactPlayerControlsContainer(controls);
    UIButton *shareButton = reactNativeControls
        ? nil : tpk_shareButtonForControls(controls);
    if (!reactNativeControls && !shareButton) return;

    UIStackView *stack = nil;
    if (reactNativeControls) {
        stack = tpk_playerReactControlsButtonStack(controls);
    } else if ([shareButton.superview isKindOfClass:UIStackView.class]) {
        stack = (UIStackView *)shareButton.superview;
    } else if ([controls respondsToSelector:@selector(topRightStackView)]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(
            controls, @selector(topRightStackView));
        if ([candidate isKindOfClass:UIStackView.class]) {
            stack = candidate;
        }
    }
    if (!stack) return;

    UIButton *lockButton = [UIButton buttonWithType:UIButtonTypeSystem];
    lockButton.translatesAutoresizingMaskIntoConstraints = NO;
    lockButton.accessibilityIdentifier = @"tpk_lock_button";
    lockButton.accessibilityLabel = tpk_isOrientationLocked()
        ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
    lockButton.accessibilityTraits = UIAccessibilityTraitButton;
    lockButton.tintColor = tpk_isOrientationLocked()
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : UIColor.whiteColor;
    lockButton.contentEdgeInsets = UIEdgeInsetsMake(0.0, 2.0, 0.0, 2.0);
    if (reactNativeControls) {
        [NSLayoutConstraint activateConstraints:@[
            [lockButton.widthAnchor constraintEqualToConstant:40.0],
            [lockButton.heightAnchor constraintEqualToConstant:40.0],
        ]];
    }
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:
        (tpk_isOrientationLocked() ? @"lock.rotation" : @"lock.rotation.open")
        withConfiguration:configuration];
    for (NSNumber *state in tpk_orientationButtonStates()) {
        [lockButton setImage:icon forState:state.unsignedIntegerValue];
    }
    [lockButton addTarget:[TPKManager sharedManager]
                   action:@selector(tpk_toggleOrientationLock:)
         forControlEvents:UIControlEventTouchUpInside];

    if (shareButton) {
        NSUInteger shareIndex = [stack.arrangedSubviews
            indexOfObject:shareButton];
        if (shareIndex != NSNotFound) {
            [stack insertArrangedSubview:lockButton atIndex:shareIndex + 1];
        } else {
            [stack addArrangedSubview:lockButton];
        }
    } else {
        [stack addArrangedSubview:lockButton];
    }
    tpk_registerOrientationButtonForHitTesting(controls, lockButton);
    objc_setAssociatedObject(controls, &kTPKOrientationLockButtonKey,
                             lockButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s_activeControlsView = controls;
    tpk_refreshOrientationPolicySuspension();
    tpk_refreshOrientationObserver();
}
// Global orientation-lock state.
static BOOL s_orientationLocked = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
static UIDeviceOrientation s_lastAutoLockCandidate = UIDeviceOrientationUnknown;

// Orientation is enforced with scene geometry and UIKit guards.
static UIInterfaceOrientation s_lockedOrientation = UIInterfaceOrientationUnknown;

static id s_orientationObserver = nil;
static void tpk_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast);

BOOL tpk_orientationLockButtonEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kTPKOrientationLockButtonEnabled] != nil
        ? [defaults boolForKey:kTPKOrientationLockButtonEnabled] : NO;
}

TPKAutoOrientationLockMode tpk_autoOrientationLockMode(void) {
    NSInteger rawMode = [NSUserDefaults.standardUserDefaults
        integerForKey:kTPKAutoOrientationLockMode];
    if (rawMode < TPKAutoOrientationLockModeDisabled ||
        rawMode > TPKAutoOrientationLockModeBothLandscapes) {
        return TPKAutoOrientationLockModeDisabled;
    }
    return (TPKAutoOrientationLockMode)rawMode;
}

// Requests the target orientation through the scene API.
static void tpk_forceSceneOrientation(UIInterfaceOrientationMask mask) {
    if (s_orientationPolicySuspended ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    SEL reqSel = NSSelectorFromString(
        @"requestGeometryUpdateWithPreferences:errorHandler:");
    Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;

        if (prefsCls && [ws respondsToSelector:reqSel]) {
            id prefs = [[prefsCls alloc] initWithInterfaceOrientations:mask];
            ((void(*)(id, SEL, id, id))objc_msgSend)(ws, reqSel, prefs, nil);
        } else {
            // Fallback for older iOS versions.
            UIInterfaceOrientation target = UIInterfaceOrientationPortrait;
            if (mask == UIInterfaceOrientationMaskLandscapeLeft)               target = UIInterfaceOrientationLandscapeLeft;
            else if (mask == UIInterfaceOrientationMaskLandscapeRight)         target = UIInterfaceOrientationLandscapeRight;
            else if (mask == UIInterfaceOrientationMaskPortraitUpsideDown)     target = UIInterfaceOrientationPortraitUpsideDown;
            SEL fbSel = NSSelectorFromString(@"setStatusBarOrientation:animated:");
            ((void(*)(id, SEL, UIInterfaceOrientation, BOOL))objc_msgSend)(
                [UIApplication sharedApplication], fbSel, target, NO);
        }
    }
}

static UIInterfaceOrientation tpk_interfaceOrientationForDeviceOrientation(
    UIDeviceOrientation deviceOrientation) {
    // Device and interface landscape values use opposite sides.
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationUnknown;
}

static BOOL tpk_autoModeAcceptsInterfaceOrientation(
    TPKAutoOrientationLockMode mode, UIInterfaceOrientation orientation) {
    if (mode == TPKAutoOrientationLockModeBothLandscapes) return YES;
    // Map the configured physical side to the interface orientation.
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return mode == TPKAutoOrientationLockModeLandscapeRight;
    }
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return mode == TPKAutoOrientationLockModeLandscapeLeft;
    }
    return NO;
}

static void tpk_handlePhysicalOrientationChange(void) {
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    if (deviceOrientation == UIDeviceOrientationPortrait ||
        deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
        // Portrait arms the next auto-lock detection.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_orientationPolicySuspended || s_orientationLocked ||
        !tpk_orientationLockButtonEnabled() ||
        !tpk_hasOrientationLockButtonInActivePlayer()) return;

    UIInterfaceOrientation target =
        tpk_interfaceOrientationForDeviceOrientation(deviceOrientation);
    TPKAutoOrientationLockMode mode = tpk_autoOrientationLockMode();
    if (target == UIInterfaceOrientationUnknown) return;
    if (!tpk_autoModeAcceptsInterfaceOrientation(mode, target)) {
        // A non-selected landscape side arms a new detection.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_lastAutoLockCandidate == deviceOrientation) return;

    s_lastAutoLockCandidate = deviceOrientation;
    NSUInteger generation = s_orientationLifecycleGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != s_orientationLifecycleGeneration ||
            s_orientationPolicySuspended || s_orientationLocked ||
            !tpk_orientationLockButtonEnabled() ||
            !tpk_hasOrientationLockButtonInActivePlayer() ||
            UIDevice.currentDevice.orientation != deviceOrientation ||
            !tpk_autoModeAcceptsInterfaceOrientation(
                tpk_autoOrientationLockMode(), target)) return;
        tpk_setOrientationLockState(YES, target, YES);
    });
}

// Keep the observer only while auto-lock is active.
static void tpk_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                    if (s_orientationPolicySuspended || s_orientationLocked) return;
                    tpk_handlePhysicalOrientationChange();
                }];
}

static void tpk_stopOrientationObserver(void) {
    if (!s_orientationObserver) return;
    [[NSNotificationCenter defaultCenter] removeObserver:s_orientationObserver];
    s_orientationObserver = nil;
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

static void tpk_refreshOrientationObserver(void) {
    BOOL autoLockActive = tpk_orientationLockButtonEnabled() &&
        tpk_autoOrientationLockMode() != TPKAutoOrientationLockModeDisabled;
    if (!s_orientationPolicySuspended && !s_orientationLocked && autoLockActive) {
        tpk_startOrientationObserver();
        tpk_handlePhysicalOrientationChange();
    } else {
        tpk_stopOrientationObserver();
    }
}

// Reuse the player HUD for lock feedback.
static void tpk_showOrientationToast(BOOL locked) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *geometryView = tpk_activePlayerGeometryView();
        if (!geometryView) return;

        NSString *symbol = locked ? @"lock.rotation" : @"lock.rotation.open";
        NSString *label = locked ? L(@"lock_locked") : L(@"lock_unlocked");
        UIColor *iconTint = locked
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : UIColor.whiteColor;
        tpk_showPlayerGestureOverlayWithTint(geometryView, label, symbol,
                                              iconTint);
    });
}
// Global UIKit guard while locked.
@interface UIApplication (TPKOrientationLock)
- (UIInterfaceOrientationMask)tpk_supportedInterfaceOrientationsForWindow:(UIWindow *)window;
@end
@implementation UIApplication (TPKOrientationLock)
- (UIInterfaceOrientationMask)tpk_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return s_lockedOrientationMask;
    }
    return [self tpk_supportedInterfaceOrientationsForWindow:window];
}
@end

// Apply the lock through UIKit orientation callbacks.
@interface UIViewController (TPKOrientationLock)
- (UIInterfaceOrientationMask)tpk_supportedInterfaceOrientations;
@end
@implementation UIViewController (TPKOrientationLock)
- (UIInterfaceOrientationMask)tpk_supportedInterfaceOrientations {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return s_lockedOrientationMask;
    }
    return [self tpk_supportedInterfaceOrientations];
}
@end

@interface UIViewController (TPKOrientationPreferenceLock)
- (BOOL)tpk_prefersInterfaceOrientationLocked;
@end
@implementation UIViewController (TPKOrientationPreferenceLock)
- (BOOL)tpk_prefersInterfaceOrientationLocked {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return YES;
    }
    return [self tpk_prefersInterfaceOrientationLocked];
}
@end

@implementation TPKManager (OrientationLock)

static void tpk_install_orientation_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tpk_installOrientationLifecycleObservers();
        tpk_swizzle([UIApplication class],
                     [UIApplication class],
                     @selector(supportedInterfaceOrientationsForWindow:),
                     NSSelectorFromString(@"tpk_supportedInterfaceOrientationsForWindow:"));
        tpk_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(supportedInterfaceOrientations),
                     @selector(tpk_supportedInterfaceOrientations));
        tpk_swizzle([UIViewController class],
                     [UIViewController class],
                     NSSelectorFromString(@"prefersInterfaceOrientationLocked"),
                     @selector(tpk_prefersInterfaceOrientationLocked));
    });
}

static void tpk_enumerateActiveViews(void (^visit)(UIView *view)) {
    if (!visit) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
            for (NSUInteger index = 0; index < pending.count; index++) {
                UIView *view = pending[index];
                visit(view);
                [pending addObjectsFromArray:view.subviews];
            }
        }
    }
}

static UIView *tpk_activePlayerGeometryView(void) {
    UIView *controls = s_activeControlsView;
    if (controls && controls.window && !controls.window.hidden) {
        return tpk_playerGestureGeometryViewForControls(controls);
    }
    UIView *host = s_activePlayerHostView;
    return host && host.window && !host.window.hidden ? host : nil;
}

static BOOL tpk_hasOrientationLockButtonInActivePlayer(void) {
    UIView *host = s_activePlayerHostView;
    return host && host.window && !host.window.hidden;
}

static void tpk_updateOrientationLockButtons(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    UIButton *button = tpk_orientationLockButtonForControls(s_activeControlsView);
    if (!button) return;
    for (NSNumber *state in tpk_orientationButtonStates()) {
        [button setImage:icon forState:state.unsignedIntegerValue];
    }
    button.tintColor = tint;
    button.accessibilityLabel = s_orientationLocked
        ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
}

static UIInterfaceOrientationMask tpk_maskForInterfaceOrientation(
    UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIInterfaceOrientationMaskLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:
            return UIInterfaceOrientationMaskLandscapeRight;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationMaskPortraitUpsideDown;
        default:
            return UIInterfaceOrientationMaskPortrait;
    }
}

static UIWindowScene *tpk_activeWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void tpk_notifyOrientationPolicyChanged(void) {
    if (s_orientationPolicySuspended ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    SEL supportedSel = NSSelectorFromString(
        @"setNeedsUpdateOfSupportedInterfaceOrientations");
    SEL lockedSel = NSSelectorFromString(
        @"setNeedsUpdateOfPrefersInterfaceOrientationLocked");

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if (!root) continue;
            if ([root respondsToSelector:supportedSel]) {
                ((void(*)(id, SEL))objc_msgSend)(root, supportedSel);
            }
            if ([root respondsToSelector:lockedSel]) {
                ((void(*)(id, SEL))objc_msgSend)(root, lockedSel);
            }
        }
    }
}

static void tpk_refreshOrientationPolicySuspension(void) {
    BOOL shouldSuspend =
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    if (shouldSuspend == s_orientationPolicySuspended) return;

    s_orientationPolicySuspended = shouldSuspend;
    s_orientationLifecycleGeneration++;
    if (shouldSuspend) tpk_stopOrientationObserver();
    else tpk_refreshOrientationObserver();
    tpk_notifyOrientationPolicyChanged();
}

static void tpk_installOrientationLifecycleObservers(void) {
    if (s_orientationLifecycleObservers) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSArray<NSString *> *notificationNames = @[
        UIApplicationWillResignActiveNotification,
        UIApplicationDidBecomeActiveNotification,
        UIWindowDidBecomeVisibleNotification,
        UIWindowDidBecomeHiddenNotification,
        UISceneWillDeactivateNotification,
        UISceneDidActivateNotification,
        UISceneDidDisconnectNotification,
    ];
    NSMutableArray *tokens = [NSMutableArray arrayWithCapacity:notificationNames.count];
    for (NSString *name in notificationNames) {
        id token = [center addObserverForName:name
                                       object:nil
                                        queue:NSOperationQueue.mainQueue
                                   usingBlock:^(__unused NSNotification *note) {
            tpk_refreshOrientationPolicySuspension();
        }];
        if (token) [tokens addObject:token];
    }
    s_orientationLifecycleObservers = [tokens copy];
    tpk_refreshOrientationPolicySuspension();
}

static void tpk_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast) {
    if (locked == s_orientationLocked) return;
    s_orientationLifecycleGeneration++;

    if (locked) {
        tpk_install_orientation_swizzles();
        UIWindowScene *activeScene = tpk_activeWindowScene();
        UIInterfaceOrientation current = requestedOrientation;
        if (current == UIInterfaceOrientationUnknown) {
            current = activeScene ? activeScene.interfaceOrientation
                                  : UIInterfaceOrientationPortrait;
        }
        s_lockedOrientation = current;
        s_lockedOrientationMask = tpk_maskForInterfaceOrientation(current);
        s_orientationLocked = YES;
        tpk_notifyOrientationPolicyChanged();

        // Complete a pending auto-rotation before applying the mask.
        if (requestedOrientation != UIInterfaceOrientationUnknown &&
            activeScene && activeScene.interfaceOrientation != requestedOrientation) {
            tpk_forceSceneOrientation(s_lockedOrientationMask);
        }
    } else {
        s_orientationLocked = NO;
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation = UIInterfaceOrientationUnknown;
        UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
        s_lastAutoLockCandidate = UIDeviceOrientationIsLandscape(physical)
            ? physical : UIDeviceOrientationUnknown;
        tpk_notifyOrientationPolicyChanged();
        tpk_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        if (!s_orientationPolicySuspended) {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    }

    tpk_refreshOrientationObserver();
    tpk_updateOrientationLockButtons();
    if (showToast) tpk_showOrientationToast(s_orientationLocked);
}

- (void)tpk_toggleOrientationLock:(UIButton *)sender {
    if (!tpk_orientationLockButtonEnabled()) return;
    tpk_setOrientationLockState(!s_orientationLocked,
                                 UIInterfaceOrientationUnknown, YES);
}

@end

// Getter en lecture seule utilisé par le bouton ajouté au player.
BOOL tpk_isOrientationLocked(void) {
    return s_orientationLocked;
}

void tpk_setOrientationLockButtonEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kTPKOrientationLockButtonEnabled];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        s_orientationLifecycleGeneration++;
        if (!enabled) {
            if (s_orientationLocked) {
                tpk_setOrientationLockState(NO, UIInterfaceOrientationUnknown, NO);
            }
            NSMutableArray<UIView *> *controlsViews = [NSMutableArray array];
            tpk_enumerateActiveViews(^(UIView *view) {
                if (tpk_isPlayerControlsContainer(view)) {
                    [controlsViews addObject:view];
                }
            });
            for (UIView *controls in controlsViews) {
                tpk_removeOrientationLockButton(controls);
            }
            s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
            s_activeControlsView = nil;
            s_activePlayerHostView = nil;
        } else {
            NSMutableArray<UIView *> *playerViews = [NSMutableArray array];
            tpk_enumerateActiveViews(^(UIView *view) {
                if (tpk_isPlayerControlsContainer(view) ||
                    tpk_playerTheaterHostForView(view) == view) {
                    [playerViews addObject:view];
                }
            });
            for (UIView *view in playerViews) {
                tpk_handleTheaterControlsViewLifecycle(view);
            }
        }
        tpk_refreshOrientationObserver();
    });
}

void tpk_setAutoOrientationLockMode(TPKAutoOrientationLockMode mode) {
    if (mode < TPKAutoOrientationLockModeDisabled ||
        mode > TPKAutoOrientationLockModeBothLandscapes) {
        mode = TPKAutoOrientationLockModeDisabled;
    }
    [NSUserDefaults.standardUserDefaults setInteger:mode
                                             forKey:kTPKAutoOrientationLockMode];
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        s_orientationLifecycleGeneration++;
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        tpk_refreshOrientationObserver();
    });
}

void tpk_swizzle_orientation_lock(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_installOrientationLifecycleObservers();
        tpk_refreshOrientationObserver();
    });
}
