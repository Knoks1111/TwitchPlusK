/*
 * 7tv-system-native-behavior-hooks.m
 *
 * Module "100% autonome" qui modifie un comportement natif de Twitch
 * sans rapport avec le rendu 7TV (emotes/chat/badges) :
 *
 *  Verrou d'orientation — ajoute un bouton à côté du bouton Share du lecteur
 *     theater pour verrouiller l'orientation de l'écran (requestGeometryUpdate
 *     iOS 16+, fallback setStatusBarOrientation: sinon), avec toast de
 *     confirmation.
 *
 * Fonctions exposées par ce fichier (déclarées dans 7tv-system-native-behavior-hooks.h) :
 *  - s7tv_isOrientationLocked() — lecture seule pour l'état du bouton ajouté
 *  - s7tv_swizzle_orientation_lock() — réactive l'observer d'auto-lock au
 *     lancement si nécessaire ; les swizzles s'installent au premier lock
 */

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

static const char kS7TVShareHijacked = 8;
static char kS7TVOrientationLockButtonKey;

@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end

static void s7tv_refreshOrientationObserver(void);
static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void);
static void s7tv_enumerateActiveViews(void (^visit)(UIView *view));
static UIView *s7tv_activePlayerGeometryView(void);

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
    while (pending.count > 0) {
        UIView *candidate = pending.firstObject;
        [pending removeObjectAtIndex:0];
        if ([candidate isKindOfClass:UIButton.class] &&
            [candidate.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) {
            return (UIButton *)candidate;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static UIButton *s7tv_orientationShareButtonForControls(UIView *controls) {
    if (!controls) return nil;

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:controls];
    while (pending.count > 0) {
        UIView *candidate = pending.firstObject;
        [pending removeObjectAtIndex:0];
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
        objc_setAssociatedObject(controls, &kS7TVShareHijacked, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    objc_setAssociatedObject(controls, &kS7TVShareHijacked, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *s7tv_orientationControlsForButton(UIButton *button) {
    UIView *candidate = button;
    while (candidate &&
           ![NSStringFromClass(candidate.class)
               isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
        candidate = candidate.superview;
    }
    return candidate;
}

void s7tv_handleTheaterControlsViewLifecycle(UIView *view) {
    if (!s7tv_orientationLockButtonEnabled()) return;
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.TheaterPlayerControlsView"] ||
        !view.window || s7tv_orientationLockButtonForControls(view)) return;

    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *controls = weakView;
        if (!s7tv_orientationLockButtonEnabled() || !controls || !controls.window ||
            ![NSStringFromClass(controls.window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"] ||
            s7tv_orientationLockButtonForControls(controls)) return;

        UIButton *shareButton = s7tv_orientationShareButtonForControls(controls);
        if (!shareButton) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ share_button introuvable dans TheaterPlayerControlsView"];
            return;
        }

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
        if (!stack) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ stack Share introuvable dans TheaterPlayerControlsView"];
            return;
        }

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
        objc_setAssociatedObject(controls, &kS7TVShareHijacked, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[SevenTVManager sharedManager]
            log:@"✅ Bouton verrou orientation ajouté à côté de Share"];
        s7tv_refreshOrientationObserver();
    });
}

// État global verrou d'orientation — déplacées depuis le haut de
// 7tv-core-runtime-hooks.m (section "Clés associated objects") où elles vivaient sans
// rapport avec les autres clés qui y restent. s_orientationLocked est lue en
// lecture seule par le hijack du bouton Share ci-dessus, avant même le
// premier lock, pour l'état initial de l'icône) via s7tv_isOrientationLocked().
static BOOL s_orientationLocked = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
static UIDeviceOrientation s_lastAutoLockCandidate = UIDeviceOrientationUnknown;

// ────────────────────────────────────────────────────────────
// MARK: - Verrou d'orientation (bouton Share hijacké)
// Approche : requestGeometryUpdate (iOS 16+) pour forcer l'orientation
// de la scène au niveau système — c'est la seule API qui contrôle
// réellement la rotation visuelle sur les apps SwiftUI modernes.
// Combiné avec shouldAutorotate=NO pour bloquer UIKit en parallèle.
// ────────────────────────────────────────────────────────────

// ── Orientation verrouillée capturée au moment du lock ───────────────────────
static UIInterfaceOrientation s_lockedOrientation = UIInterfaceOrientationUnknown;

// ── Observer rotation physique ───────────────────────────────────────────────
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

// ── Force la géométrie de toutes les scènes actives ─────────────────────────
static void s7tv_forceSceneOrientation(UIInterfaceOrientationMask mask) {
    // iOS 16+ : UIWindowScene requestGeometryUpdate:errorHandler:
    // Appelé via objc_msgSend pour éviter les erreurs de header manquant dans le SDK Theos
    SEL reqSel   = NSSelectorFromString(@"requestGeometryUpdate:errorHandler:");
    Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;

        if (prefsCls && [ws respondsToSelector:reqSel]) {
            id prefs = [[prefsCls alloc] initWithInterfaceOrientations:mask];
            ((void(*)(id, SEL, id, id))objc_msgSend)(ws, reqSel, prefs, nil);
        } else {
            // Fallback iOS < 16 : setStatusBarOrientation:animated: (déprécié)
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
    // Les enums device et interface sont inversés : lorsque le haut physique
    // du téléphone pointe à gauche, le contenu UIKit est en LandscapeRight.
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
    // Les orientations UIDevice et UIInterface sont opposées. Les libellés
    // Gauche/Droite décrivent le geste physique de l'utilisateur : le mode
    // Gauche doit donc accepter LandscapeRight côté interface, et inversement.
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
        // Le retour en portrait réarme l'auto-lock. Un déverrouillage manuel
        // en restant exactement du même côté ne reboucle donc pas.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_orientationLocked || !s7tv_orientationLockButtonEnabled() ||
        !s7tv_hasOrientationLockButtonInActivePlayer()) return;

    UIInterfaceOrientation target =
        s7tv_interfaceOrientationForDeviceOrientation(deviceOrientation);
    S7TVAutoOrientationLockMode mode = s7tv_autoOrientationLockMode();
    if (target == UIInterfaceOrientationUnknown) return;
    if (!s7tv_autoModeAcceptsInterfaceOrientation(mode, target)) {
        // Quitter le côté sélectionné vers l'autre paysage réarme aussi la
        // détection, sans exiger un passage artificiel par le portrait.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_lastAutoLockCandidate == deviceOrientation) return;

    s_lastAutoLockCandidate = deviceOrientation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (s_orientationLocked || !s7tv_orientationLockButtonEnabled() ||
            !s7tv_hasOrientationLockButtonInActivePlayer() ||
            UIDevice.currentDevice.orientation != deviceOrientation ||
            !s7tv_autoModeAcceptsInterfaceOrientation(
                s7tv_autoOrientationLockMode(), target)) return;
        s7tv_setOrientationLockState(YES, target, YES);
    });
}

// L'observer reste vivant lorsque le verrou est actif OU lorsqu'une détection
// automatique est configurée. Il est entièrement supprimé dans les autres cas
// pour ne laisser aucun travail permanent inutile en arrière-plan.
static void s7tv_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        if (s_orientationLocked) {
            [[SevenTVManager sharedManager] log:@"🔒 Rotation physique bloquée (verrou actif)"];
            return;
        }
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
    if (s_orientationLocked || autoLockActive) {
        s7tv_startOrientationObserver();
        if (!s_orientationLocked && autoLockActive) {
            s7tv_handlePhysicalOrientationChange();
        }
    } else {
        s7tv_stopOrientationObserver();
    }
}

// ── Toast ─────────────────────────────────────────────────────────────────────
// Pastille de confirmation réutilisant le rendu du HUD des gestes du player.
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
// C'est le check système qui prime sur toutes les overrides Twitch dans les VCs.
@interface UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window;
@end
@implementation UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientationsForWindow:window];
}
@end

// ── Garde UIViewController au cas où (certains chemins UIKit passent par là) ──
@interface UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations;
@end
@implementation UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientations];
}
@end

@interface UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate;
@end
@implementation UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate {
    if (s_orientationLocked) return NO;
    return [self s7tv_shouldAutorotate];
}
@end

// ── Action toggle ─────────────────────────────────────────────────────────────
@implementation SevenTVManager (OrientationLock)

static void s7tv_install_orientation_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
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
                     @selector(shouldAutorotate),
                     @selector(s7tv_shouldAutorotate));
        [[SevenTVManager sharedManager] log:@"✅ Swizzles verrou orientation installés (premier lock)"];
    });
}

static void s7tv_enumerateActiveViews(void (^visit)(UIView *view)) {
    if (!visit) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
            while (pending.count) {
                UIView *view = pending.firstObject;
                [pending removeObjectAtIndex:0];
                visit(view);
                [pending addObjectsFromArray:view.subviews];
            }
        }
    }
}

static UIView *s7tv_activePlayerGeometryView(void) {
    __block UIView *usableTheaterView = nil;
    __block UIView *activeControlsView = nil;
    __block UIView *fallbackTheaterView = nil;

    s7tv_enumerateActiveViews(^(UIView *view) {
        NSString *className = NSStringFromClass(view.class);
        BOOL isTheaterView = [className isEqualToString:@"Twitch.TheaterView"];
        BOOL isControlsView =
            [className isEqualToString:@"Twitch.TheaterPlayerControlsView"];
        if (!isTheaterView && !isControlsView) return;

        UIWindow *window = view.window;
        if (!window || window.hidden ||
            ![NSStringFromClass(window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"]) return;

        if (isTheaterView && !fallbackTheaterView) {
            fallbackTheaterView = view;
        }

        if (isControlsView && !activeControlsView) {
            activeControlsView = view;
        }

        BOOL usable = CGRectGetWidth(view.bounds) > 1.0 &&
            CGRectGetHeight(view.bounds) > 1.0;
        if (!usable) return;
        if (isTheaterView && !usableTheaterView) {
            usableTheaterView = view;
        }
    });

    // Utilise exactement la même vue de géométrie que le module de gestes :
    // les contrôles quand ils ont leur vraie taille, puis le TheaterView ou
    // son ancêtre utilisable pendant les transitions.
    UIView *gestureGeometry =
        s7tv_playerGestureGeometryViewForControls(activeControlsView);
    return gestureGeometry ?: usableTheaterView ?: fallbackTheaterView;
}

static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void) {
    __block BOOL found = NO;
    s7tv_enumerateActiveViews(^(UIView *view) {
        if (found || ![view isKindOfClass:UIButton.class] ||
            ![view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) return;
        UIWindow *window = view.window;
        if (window && !window.hidden &&
            [NSStringFromClass(window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"]) {
            found = YES;
        }
    });
    return found;
}

static void s7tv_updateOrientationLockButtons(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    s7tv_enumerateActiveViews(^(UIView *view) {
        if (![view isKindOfClass:UIButton.class] ||
            ![view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) return;
        UIButton *button = (UIButton *)view;
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            [button setImage:icon forState:state.unsignedIntegerValue];
        }
        button.tintColor = tint;
        button.accessibilityLabel = s_orientationLocked
            ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
    });
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

static void s7tv_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast) {
    if (locked == s_orientationLocked) return;

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

        // L'auto-lock peut être notifié juste avant la fin de l'animation
        // UIKit. Dans ce seul cas, termine explicitement la rotation vers le
        // côté détecté avant que le masque ne la fige.
        if (requestedOrientation != UIInterfaceOrientationUnknown &&
            activeScene.interfaceOrientation != requestedOrientation) {
            s7tv_forceSceneOrientation(s_lockedOrientationMask);
        }
        [[SevenTVManager sharedManager]
            log:@"🔒 Orientation verrouillée (orientation=%ld)", (long)current];
    } else {
        s_orientationLocked = NO;
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation = UIInterfaceOrientationUnknown;
        UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
        s_lastAutoLockCandidate = UIDeviceOrientationIsLandscape(physical)
            ? physical : UIDeviceOrientationUnknown;
        s7tv_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        [UIViewController attemptRotationToDeviceOrientation];
        [[SevenTVManager sharedManager] log:@"🔓 Orientation déverrouillée"];
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

// Getter en lecture seule vers s_orientationLocked — utilisé par le hijack
// du bouton Share (icône/tint/label initiaux, avant
// même le premier lock). La variable elle-même reste privée à ce fichier.
BOOL s7tv_isOrientationLocked(void) {
    return s_orientationLocked;
}

void s7tv_setOrientationLockButtonEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kS7TVOrientationLockButtonEnabled];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!enabled) {
            if (s_orientationLocked) {
                s7tv_setOrientationLockState(NO, UIInterfaceOrientationUnknown, NO);
            }
            NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
            s7tv_enumerateActiveViews(^(UIView *view) {
                if ([view isKindOfClass:UIButton.class] &&
                    [view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) {
                    [buttons addObject:(UIButton *)view];
                }
            });
            for (UIButton *button in buttons) {
                s7tv_removeOrientationLockButton(
                    s7tv_orientationControlsForButton(button));
            }
            s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
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
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        s7tv_refreshOrientationObserver();
    });
}

void s7tv_swizzle_orientation_lock(void) {
    // Les swizzles restent installés à la demande au premier verrouillage.
    // Seul l'observer physique démarre ici si l'auto-lock était déjà activé
    // dans les préférences d'une session précédente.
    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_refreshOrientationObserver();
    });
}
