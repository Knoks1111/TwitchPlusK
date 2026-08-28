/*
 * 7tv-system-native-behavior-hooks.m
 *
 * Module "100% autonome" qui modifie un comportement natif de Twitch
 * sans rapport avec le rendu 7TV (emotes/chat/badges) :
 *
 *  Verrou d'orientation — hijack du bouton Share du lecteur theater pour
 *     verrouiller l'orientation de l'écran (requestGeometryUpdate iOS 16+,
 *     fallback setStatusBarOrientation: sinon), avec toast de confirmation.
 *
 * Fonctions exposées par ce fichier (déclarées dans 7tv-system-native-behavior-hooks.h) :
 *  - s7tv_isOrientationLocked() — lecture seule, pour l'icône du bouton Share
 *    au moment du hijack (avant même le premier lock)
 *  - s7tv_swizzle_orientation_lock() — réactive l'observer d'auto-lock au
 *     lancement si nécessaire ; les swizzles s'installent au premier lock
 */

#import "System/7tv-system-native-behavior-hooks.h"
#import "Core/7tv-core-manager.h"
#import "Localization/7tv-localization-manager.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kS7TVOrientationLockButtonEnabled =
    @"s7tv_orientation_lock_button_enabled";
static NSString *const kS7TVAutoOrientationLockMode =
    @"s7tv_auto_orientation_lock_mode";

static const char kS7TVShareHijacked = 8;
static const char kS7TVShareButtonSnapshot = 10;

@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end

static void s7tv_refreshOrientationObserver(void);
static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void);

@interface S7TVShareActionRecord : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end
@implementation S7TVShareActionRecord
@end

@interface S7TVShareButtonSnapshot : NSObject
@property (nonatomic, copy) NSArray<S7TVShareActionRecord *> *actions;
@property (nonatomic, copy) NSArray *images;
@property (nonatomic, strong) UIColor *tintColor;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic, copy) NSString *accessibilityIdentifier;
@end
@implementation S7TVShareButtonSnapshot
@end

static NSArray<NSNumber *> *s7tv_orientationButtonStates(void) {
    return @[@(UIControlStateNormal), @(UIControlStateHighlighted),
             @(UIControlStateSelected), @(UIControlStateDisabled)];
}

static void s7tv_restoreNativeShareButton(UIButton *button) {
    S7TVShareButtonSnapshot *snapshot =
        objc_getAssociatedObject(button, &kS7TVShareButtonSnapshot);
    if (!snapshot) return;

    [button removeTarget:[SevenTVManager sharedManager]
                  action:@selector(s7tv_toggleOrientationLock:)
        forControlEvents:UIControlEventTouchUpInside];
    for (S7TVShareActionRecord *record in snapshot.actions) {
        if (record.target && record.action) {
            [button addTarget:record.target action:record.action
               forControlEvents:UIControlEventTouchUpInside];
        }
    }
    NSArray<NSNumber *> *states = s7tv_orientationButtonStates();
    for (NSUInteger index = 0; index < states.count; index++) {
        id storedImage = index < snapshot.images.count ? snapshot.images[index] : NSNull.null;
        [button setImage:(storedImage == NSNull.null ? nil : storedImage)
                forState:states[index].unsignedIntegerValue];
    }
    button.tintColor = snapshot.tintColor;
    button.accessibilityLabel = snapshot.accessibilityLabel;
    button.accessibilityIdentifier = snapshot.accessibilityIdentifier ?: @"share_button";
    objc_setAssociatedObject(button, &kS7TVShareButtonSnapshot, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *ancestor = button.superview;
    while (ancestor &&
           ![NSStringFromClass(ancestor.class)
               isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
        ancestor = ancestor.superview;
    }
    if (ancestor) {
        objc_setAssociatedObject(ancestor, &kS7TVShareHijacked, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void s7tv_handleTheaterControlsViewLifecycle(UIView *view) {
    if (!s7tv_orientationLockButtonEnabled()) return;
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.TheaterPlayerControlsView"] ||
        !view.window || objc_getAssociatedObject(view, &kS7TVShareHijacked)) return;

    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *controls = weakView;
        if (!s7tv_orientationLockButtonEnabled() || !controls || !controls.window ||
            ![NSStringFromClass(controls.window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"] ||
            objc_getAssociatedObject(controls, &kS7TVShareHijacked)) return;
        objc_setAssociatedObject(controls, &kS7TVShareHijacked, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIButton *shareButton = nil;
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:controls];
        while (views.count > 0) {
            UIView *candidate = views.firstObject;
            [views removeObjectAtIndex:0];
            if ([candidate isKindOfClass:UIButton.class] &&
                [candidate.accessibilityIdentifier isEqualToString:@"share_button"]) {
                shareButton = (UIButton *)candidate;
                break;
            }
            [views addObjectsFromArray:candidate.subviews];
        }
        if (!shareButton) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ share_button introuvable dans TheaterPlayerControlsView"];
            return;
        }

        S7TVShareButtonSnapshot *snapshot = [S7TVShareButtonSnapshot new];
        NSMutableArray<S7TVShareActionRecord *> *savedActions = [NSMutableArray array];
        for (id target in shareButton.allTargets) {
            for (NSString *actionName in [shareButton actionsForTarget:target
                                                        forControlEvent:UIControlEventTouchUpInside]) {
                S7TVShareActionRecord *record = [S7TVShareActionRecord new];
                record.target = target;
                record.action = NSSelectorFromString(actionName);
                [savedActions addObject:record];
            }
        }
        NSMutableArray *savedImages = [NSMutableArray array];
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            UIImage *image = [shareButton imageForState:state.unsignedIntegerValue];
            [savedImages addObject:image ?: NSNull.null];
        }
        snapshot.actions = savedActions;
        snapshot.images = savedImages;
        snapshot.tintColor = shareButton.tintColor;
        snapshot.accessibilityLabel = shareButton.accessibilityLabel;
        snapshot.accessibilityIdentifier = shareButton.accessibilityIdentifier;
        objc_setAssociatedObject(shareButton, &kS7TVShareButtonSnapshot, snapshot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        for (id target in shareButton.allTargets) {
            for (NSString *action in [shareButton actionsForTarget:target
                                                   forControlEvent:UIControlEventTouchUpInside]) {
                [shareButton removeTarget:target action:NSSelectorFromString(action)
                         forControlEvents:UIControlEventTouchUpInside];
                [[SevenTVManager sharedManager] log:@"🔌 Share: action retirée — %@->%@",
                    NSStringFromClass([target class]), action];
            }
        }

        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
            configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        NSString *symbol = s7tv_isOrientationLocked()
            ? @"lock.rotation" : @"lock.rotation.open";
        UIImage *icon = [UIImage systemImageNamed:symbol withConfiguration:configuration];
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            [shareButton setImage:icon forState:state.unsignedIntegerValue];
        }
        shareButton.tintColor = s7tv_isOrientationLocked()
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : UIColor.whiteColor;
        shareButton.accessibilityLabel = s7tv_isOrientationLocked()
            ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
        shareButton.accessibilityIdentifier = @"s7tv_lock_button";
        [shareButton addTarget:[SevenTVManager sharedManager]
                        action:@selector(s7tv_toggleOrientationLock:)
              forControlEvents:UIControlEventTouchUpInside];
        [[SevenTVManager sharedManager]
            log:@"✅ Bouton Share hijacké → verrou orientation"];
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
// Fenêtre dédiée au toast — niveau UIWindowLevelAlert pour passer au-dessus
// du player Twitch qui tourne sur une fenêtre de niveau supérieur à Normal.
static UIWindow *s_toastWindow = nil;

static void s7tv_showOrientationToast(BOOL locked) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Trouver la UIWindowScene active
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!activeScene) return;

        // Créer une fenêtre dédiée au niveau Alert — au-dessus du player Twitch
        UIWindow *toastWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        toastWindow.windowLevel = UIWindowLevelAlert;
        toastWindow.backgroundColor = [UIColor clearColor];
        toastWindow.userInteractionEnabled = NO;
        // Rootvc minimal pour pouvoir addSubview
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        toastWindow.rootViewController = rootVC;
        toastWindow.hidden = NO;
        s_toastWindow = toastWindow; // retain

        UIView *container = toastWindow.rootViewController.view;
        CGFloat winW = toastWindow.bounds.size.width;
        CGFloat winH = toastWindow.bounds.size.height;

        NSString *symbol = locked ? @"lock.rotation"      : @"lock.rotation.open";
        NSString *label  = locked ? L(@"lock_locked") : L(@"lock_unlocked");

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.62];
        toast.layer.cornerRadius = 14;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:toast];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.tintColor   = locked
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : [UIColor colorWithRed:0.6  green:0.6  blue:0.65 alpha:1.0];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:iconView];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text      = label;
        lbl.font      = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:lbl];

        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor  constraintEqualToAnchor:toast.leadingAnchor  constant:12],
            [iconView.centerYAnchor  constraintEqualToAnchor:toast.centerYAnchor],
            [iconView.widthAnchor    constraintEqualToConstant:18],
            [iconView.heightAnchor   constraintEqualToConstant:18],
            [lbl.leadingAnchor       constraintEqualToAnchor:iconView.trailingAnchor constant:8],
            [lbl.trailingAnchor      constraintEqualToAnchor:toast.trailingAnchor    constant:-12],
            [lbl.centerYAnchor       constraintEqualToAnchor:toast.centerYAnchor],
            [toast.heightAnchor      constraintEqualToConstant:38],
            [toast.centerXAnchor     constraintEqualToAnchor:container.centerXAnchor],
            [toast.bottomAnchor      constraintEqualToAnchor:container.bottomAnchor constant:-(winH * 0.12)],
        ]];

        [container layoutIfNeeded];

        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1.0; } completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL ff) {
                    [toast removeFromSuperview];
                    s_toastWindow.hidden = YES;
                    s_toastWindow = nil; // libérer
                }];
            });
        }];
    });
}

// ── Hook principal : UIApplication.supportedInterfaceOrientationsForWindow: ──
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
        configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
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
            for (UIButton *button in buttons) s7tv_restoreNativeShareButton(button);
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
