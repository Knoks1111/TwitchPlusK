/* Adds the custom orientation button and handles auto-lock. */

#import "System/7tv-system-native-behavior-hooks.h"
#import "Core/7tv-core-manager.h"
#import "Localization/7tv-localization-manager.h"
#import "System/7tv-system-player-gestures.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kS7TVOrientationLockButtonEnabled =
    @"s7tv_orientation_lock_button_enabled";
static NSString *const kS7TVAutoOrientationLockMode =
    @"s7tv_auto_orientation_lock_mode";

static char kS7TVOrientationLockButtonKey;
static __weak UIView *s_activeControlsView;

static BOOL s_orientationPolicySuspended = NO;
static NSUInteger s_orientationLifecycleGeneration = 0;
static NSArray *s_orientationLifecycleObservers = nil;

@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end

static void s7tv_refreshOrientationObserver(void);
static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void);
static void s7tv_enumerateActiveViews(void (^visit)(UIView *view));
static UIView *s7tv_activePlayerGeometryView(void);
static UIWindowScene *s7tv_activeWindowScene(void);
static void s7tv_refreshOrientationPolicySuspension(void);
static void s7tv_installOrientationLifecycleObservers(void);

static BOOL s7tv_isPictureInPictureWindow(UIWindow *window) {
    if (!window) return NO;
    NSString *className = NSStringFromClass(window.class);
    return [className hasSuffix:@"PictureInPictureWindow"];
}

static NSArray<NSNumber *> *s7tv_orientationButtonStates(void) {
    return @[@(UIControlStateNormal), @(UIControlStateHighlighted),
             @(UIControlStateSelected), @(UIControlStateDisabled)];
}

static UIButton *s7tv_orientationLockButtonForControls(UIView *controls) {
    if (!controls) return nil;

    UIButton *associated = objc_getAssociatedObject(
        controls, &kS7TVOrientationLockButtonKey);
    if (associated && associated.superview) return associated;
    if (associated) {
        objc_setAssociatedObject(controls, &kS7TVOrientationLockButtonKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    for (NSUInteger index = 0; index < pending.count; index++) {
        UIView *candidate = pending[index];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static UIButton *s7tv_shareButtonForControls(UIView *controls) {
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

static void s7tv_registerOrientationButtonForHitTesting(UIView *controls,
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

static void s7tv_removeOrientationButtonFromHitTesting(UIView *controls,
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

static void s7tv_removeOrientationLockButton(UIView *controls) {
    if (!controls) return;
    UIButton *button = s7tv_orientationLockButtonForControls(controls);
    if (!button) {
        if (s_activeControlsView == controls) s_activeControlsView = nil;
        return;
    }

    [button removeTarget:[SevenTVManager sharedManager]
                  action:@selector(s7tv_toggleOrientationLock:)
        forControlEvents:UIControlEventTouchUpInside];
    s7tv_removeOrientationButtonFromHitTesting(controls, button);
    if ([button.superview isKindOfClass:UIStackView.class]) {
        [(UIStackView *)button.superview removeArrangedSubview:button];
    }
    [button removeFromSuperview];
    objc_setAssociatedObject(controls, &kS7TVOrientationLockButtonKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (s_activeControlsView == controls) s_activeControlsView = nil;
}

void s7tv_handleTheaterControlsViewLifecycle(UIView *view) {
    if (!s7tv_orientationLockButtonEnabled()) return;
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.TheaterPlayerControlsView"] ||
        !view.window) return;
    if (s7tv_orientationLockButtonForControls(view)) {
        s_activeControlsView = view;
        s7tv_refreshOrientationPolicySuspension();
        return;
    }

    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *controls = weakView;
        if (!s7tv_orientationLockButtonEnabled() || !controls || !controls.window ||
            !s7tv_isPictureInPictureWindow(controls.window) ||
            s7tv_orientationLockButtonForControls(controls)) return;

        UIButton *shareButton = s7tv_shareButtonForControls(controls);
        if (!shareButton) return;

        UIStackView *stack = nil;
        if ([shareButton.superview isKindOfClass:UIStackView.class]) {
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
        lockButton.accessibilityIdentifier = @"s7tv_lock_button";
        lockButton.accessibilityLabel = s7tv_isOrientationLocked()
            ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
        lockButton.accessibilityTraits = UIAccessibilityTraitButton;
        lockButton.tintColor = s7tv_isOrientationLocked()
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : UIColor.whiteColor;
        lockButton.contentEdgeInsets = UIEdgeInsetsMake(0.0, 2.0, 0.0, 2.0);
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
            configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:
            (s7tv_isOrientationLocked() ? @"lock.rotation" : @"lock.rotation.open")
            withConfiguration:configuration];
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            [lockButton setImage:icon forState:state.unsignedIntegerValue];
        }
        [lockButton addTarget:[SevenTVManager sharedManager]
                       action:@selector(s7tv_toggleOrientationLock:)
             forControlEvents:UIControlEventTouchUpInside];

        NSUInteger shareIndex = [stack.arrangedSubviews indexOfObject:shareButton];
        if (shareIndex != NSNotFound) {
            [stack insertArrangedSubview:lockButton atIndex:shareIndex + 1];
        } else {
            [stack addArrangedSubview:lockButton];
        }
        s7tv_registerOrientationButtonForHitTesting(controls, lockButton);
        objc_setAssociatedObject(controls, &kS7TVOrientationLockButtonKey,
                                 lockButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        s_activeControlsView = controls;
        s7tv_refreshOrientationPolicySuspension();
        s7tv_refreshOrientationObserver();
    });
}

// Global orientation-lock state.
static BOOL s_orientationLocked = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
static UIDeviceOrientation s_lastAutoLockCandidate = UIDeviceOrientationUnknown;

// Orientation is enforced with scene geometry and UIKit guards.
static UIInterfaceOrientation s_lockedOrientation = UIInterfaceOrientationUnknown;

static id s_orientationObserver = nil;
static void s7tv_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast);

BOOL s7tv_orientationLockButtonEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kS7TVOrientationLockButtonEnabled] != nil
        ? [defaults boolForKey:kS7TVOrientationLockButtonEnabled] : NO;
}

S7TVAutoOrientationLockMode s7tv_autoOrientationLockMode(void) {
    NSInteger rawMode = [NSUserDefaults.standardUserDefaults
        integerForKey:kS7TVAutoOrientationLockMode];
    if (rawMode < S7TVAutoOrientationLockModeDisabled ||
        rawMode > S7TVAutoOrientationLockModeBothLandscapes) {
        return S7TVAutoOrientationLockModeDisabled;
    }
    return (S7TVAutoOrientationLockMode)rawMode;
}

// Requests the target orientation through the scene API.
static void s7tv_forceSceneOrientation(UIInterfaceOrientationMask mask) {
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

static UIInterfaceOrientation s7tv_interfaceOrientationForDeviceOrientation(
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

static BOOL s7tv_autoModeAcceptsInterfaceOrientation(
    S7TVAutoOrientationLockMode mode, UIInterfaceOrientation orientation) {
    if (mode == S7TVAutoOrientationLockModeBothLandscapes) return YES;
    // Map the configured physical side to the interface orientation.
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return mode == S7TVAutoOrientationLockModeLandscapeRight;
    }
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return mode == S7TVAutoOrientationLockModeLandscapeLeft;
    }
    return NO;
}

static void s7tv_handlePhysicalOrientationChange(void) {
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    if (deviceOrientation == UIDeviceOrientationPortrait ||
        deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
        // Portrait arms the next auto-lock detection.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_orientationPolicySuspended || s_orientationLocked ||
        !s7tv_orientationLockButtonEnabled() ||
        !s7tv_hasOrientationLockButtonInActivePlayer()) return;

    UIInterfaceOrientation target =
        s7tv_interfaceOrientationForDeviceOrientation(deviceOrientation);
    S7TVAutoOrientationLockMode mode = s7tv_autoOrientationLockMode();
    if (target == UIInterfaceOrientationUnknown) return;
    if (!s7tv_autoModeAcceptsInterfaceOrientation(mode, target)) {
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
            !s7tv_orientationLockButtonEnabled() ||
            !s7tv_hasOrientationLockButtonInActivePlayer() ||
            UIDevice.currentDevice.orientation != deviceOrientation ||
            !s7tv_autoModeAcceptsInterfaceOrientation(
                s7tv_autoOrientationLockMode(), target)) return;
        s7tv_setOrientationLockState(YES, target, YES);
    });
}

// Keep the observer only while auto-lock is active.
static void s7tv_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                    if (s_orientationPolicySuspended || s_orientationLocked) return;
                    s7tv_handlePhysicalOrientationChange();
                }];
}

static void s7tv_stopOrientationObserver(void) {
    if (!s_orientationObserver) return;
    [[NSNotificationCenter defaultCenter] removeObserver:s_orientationObserver];
    s_orientationObserver = nil;
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

static void s7tv_refreshOrientationObserver(void) {
    BOOL autoLockActive = s7tv_orientationLockButtonEnabled() &&
        s7tv_autoOrientationLockMode() != S7TVAutoOrientationLockModeDisabled;
    if (!s_orientationPolicySuspended && !s_orientationLocked && autoLockActive) {
        s7tv_startOrientationObserver();
        s7tv_handlePhysicalOrientationChange();
    } else {
        s7tv_stopOrientationObserver();
    }
}

// Reuse the player HUD for lock feedback.
static void s7tv_showOrientationToast(BOOL locked) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *geometryView = s7tv_activePlayerGeometryView();
        if (!geometryView) return;

        NSString *symbol = locked ? @"lock.rotation" : @"lock.rotation.open";
        NSString *label = locked ? L(@"lock_locked") : L(@"lock_unlocked");
        UIColor *iconTint = locked
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : UIColor.whiteColor;
        s7tv_showPlayerGestureOverlayWithTint(geometryView, label, symbol,
                                              iconTint);
    });
}
// Global UIKit guard while locked.
@interface UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window;
@end
@implementation UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return s_lockedOrientationMask;
    }
    return [self s7tv_supportedInterfaceOrientationsForWindow:window];
}
@end

// Apply the lock through UIKit orientation callbacks.
@interface UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations;
@end
@implementation UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return s_lockedOrientationMask;
    }
    return [self s7tv_supportedInterfaceOrientations];
}
@end

@interface UIViewController (S7TVOrientationPreferenceLock)
- (BOOL)s7tv_prefersInterfaceOrientationLocked;
@end
@implementation UIViewController (S7TVOrientationPreferenceLock)
- (BOOL)s7tv_prefersInterfaceOrientationLocked {
    if (s_orientationLocked && !s_orientationPolicySuspended &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        return YES;
    }
    return [self s7tv_prefersInterfaceOrientationLocked];
}
@end

@implementation SevenTVManager (OrientationLock)

static void s7tv_install_orientation_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s7tv_installOrientationLifecycleObservers();
        s7tv_swizzle([UIApplication class],
                     [UIApplication class],
                     @selector(supportedInterfaceOrientationsForWindow:),
                     NSSelectorFromString(@"s7tv_supportedInterfaceOrientationsForWindow:"));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(supportedInterfaceOrientations),
                     @selector(s7tv_supportedInterfaceOrientations));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     NSSelectorFromString(@"prefersInterfaceOrientationLocked"),
                     @selector(s7tv_prefersInterfaceOrientationLocked));
    });
}

static void s7tv_enumerateActiveViews(void (^visit)(UIView *view)) {
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

static UIView *s7tv_activePlayerGeometryView(void) {
    UIView *controls = s_activeControlsView;
    if (!controls || !controls.window || controls.window.hidden) return nil;
    if (![NSStringFromClass(controls.window.class)
            isEqualToString:@"Twitch.PictureInPictureWindow"]) return nil;
    return s7tv_playerGestureGeometryViewForControls(controls);
}

static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void) {
    UIView *controls = s_activeControlsView;
    if (!controls || !controls.window || controls.window.hidden) return NO;
    if (![NSStringFromClass(controls.window.class)
            isEqualToString:@"Twitch.PictureInPictureWindow"]) return NO;
    return s7tv_orientationLockButtonForControls(controls) != nil;
}

static void s7tv_updateOrientationLockButtons(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    UIButton *button = s7tv_orientationLockButtonForControls(s_activeControlsView);
    if (!button) return;
    for (NSNumber *state in s7tv_orientationButtonStates()) {
        [button setImage:icon forState:state.unsignedIntegerValue];
    }
    button.tintColor = tint;
    button.accessibilityLabel = s_orientationLocked
        ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
}

static UIInterfaceOrientationMask s7tv_maskForInterfaceOrientation(
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

static UIWindowScene *s7tv_activeWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void s7tv_notifyOrientationPolicyChanged(void) {
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

static void s7tv_refreshOrientationPolicySuspension(void) {
    BOOL shouldSuspend =
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    if (shouldSuspend == s_orientationPolicySuspended) return;

    s_orientationPolicySuspended = shouldSuspend;
    s_orientationLifecycleGeneration++;
    if (shouldSuspend) s7tv_stopOrientationObserver();
    else s7tv_refreshOrientationObserver();
    s7tv_notifyOrientationPolicyChanged();
}

static void s7tv_installOrientationLifecycleObservers(void) {
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
            s7tv_refreshOrientationPolicySuspension();
        }];
        if (token) [tokens addObject:token];
    }
    s_orientationLifecycleObservers = [tokens copy];
    s7tv_refreshOrientationPolicySuspension();
}

static void s7tv_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast) {
    if (locked == s_orientationLocked) return;
    s_orientationLifecycleGeneration++;

    if (locked) {
        s7tv_install_orientation_swizzles();
        UIWindowScene *activeScene = s7tv_activeWindowScene();
        UIInterfaceOrientation current = requestedOrientation;
        if (current == UIInterfaceOrientationUnknown) {
            current = activeScene ? activeScene.interfaceOrientation
                                  : UIInterfaceOrientationPortrait;
        }
        s_lockedOrientation = current;
        s_lockedOrientationMask = s7tv_maskForInterfaceOrientation(current);
        s_orientationLocked = YES;
        s7tv_notifyOrientationPolicyChanged();

        // Complete a pending auto-rotation before applying the mask.
        if (requestedOrientation != UIInterfaceOrientationUnknown &&
            activeScene && activeScene.interfaceOrientation != requestedOrientation) {
            s7tv_forceSceneOrientation(s_lockedOrientationMask);
        }
    } else {
        s_orientationLocked = NO;
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation = UIInterfaceOrientationUnknown;
        UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
        s_lastAutoLockCandidate = UIDeviceOrientationIsLandscape(physical)
            ? physical : UIDeviceOrientationUnknown;
        s7tv_notifyOrientationPolicyChanged();
        s7tv_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        if (!s_orientationPolicySuspended) {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    }

    s7tv_refreshOrientationObserver();
    s7tv_updateOrientationLockButtons();
    if (showToast) s7tv_showOrientationToast(s_orientationLocked);
}

- (void)s7tv_toggleOrientationLock:(UIButton *)sender {
    if (!s7tv_orientationLockButtonEnabled()) return;
    s7tv_setOrientationLockState(!s_orientationLocked,
                                 UIInterfaceOrientationUnknown, YES);
}

@end

// Getter en lecture seule utilisé par le bouton ajouté au player.
BOOL s7tv_isOrientationLocked(void) {
    return s_orientationLocked;
}

void s7tv_setOrientationLockButtonEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kS7TVOrientationLockButtonEnabled];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        s_orientationLifecycleGeneration++;
        if (!enabled) {
            if (s_orientationLocked) {
                s7tv_setOrientationLockState(NO, UIInterfaceOrientationUnknown, NO);
            }
            NSMutableArray<UIView *> *controlsViews = [NSMutableArray array];
            s7tv_enumerateActiveViews(^(UIView *view) {
                if ([NSStringFromClass(view.class)
                        isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
                    [controlsViews addObject:view];
                }
            });
            for (UIView *controls in controlsViews) {
                s7tv_removeOrientationLockButton(controls);
            }
            s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
            s_activeControlsView = nil;
        } else {
            NSMutableArray<UIView *> *controlsViews = [NSMutableArray array];
            s7tv_enumerateActiveViews(^(UIView *view) {
                if ([NSStringFromClass(view.class)
                        isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
                    [controlsViews addObject:view];
                }
            });
            for (UIView *controls in controlsViews) {
                s7tv_handleTheaterControlsViewLifecycle(controls);
            }
        }
        s7tv_refreshOrientationObserver();
    });
}

void s7tv_setAutoOrientationLockMode(S7TVAutoOrientationLockMode mode) {
    if (mode < S7TVAutoOrientationLockModeDisabled ||
        mode > S7TVAutoOrientationLockModeBothLandscapes) {
        mode = S7TVAutoOrientationLockModeDisabled;
    }
    [NSUserDefaults.standardUserDefaults setInteger:mode
                                             forKey:kS7TVAutoOrientationLockMode];
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        s_orientationLifecycleGeneration++;
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        s7tv_refreshOrientationObserver();
    });
}

void s7tv_swizzle_orientation_lock(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_installOrientationLifecycleObservers();
        s7tv_refreshOrientationObserver();
    });
}
