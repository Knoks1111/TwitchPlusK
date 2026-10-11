/*
 * tpK-system-autoclaim.m
 *
 * Auto Claim Channel Points sur le chat RN (theater) : surveille chaque
 * seconde l'apparition du coffre réclamable (`channel-points-claimable-chest`)
 * et lui livre un touch via le handler RN.
 * Même logique que l'ancien watcher natif : tick 1 s, latch anti-double,
 * préférence persistée, logs Channel Points et état diagnostics.
 */

#import "System/tpK-system-autoclaim.h"
#import "Core/tpK-core-manager.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static NSString *const kTPKAutoClaimPreference =
    @"TCDBGLiveAutoCollectChannelPoints";
NSString *const TPKAutoClaimRuntimeStateDidChangeNotification =
    @"TPKAutoClaimRuntimeStateDidChangeNotification";
static const NSTimeInterval kTPKAutoClaimTickInterval = 1.0;
static const NSTimeInterval kTPKAutoClaimPostAttemptWarningDelay = 10.0;
static char kTPKAutoClaimWatcherAssociationKey;

@implementation TPKAutoClaimDiagnosticsState
@end

static void tpk_autoClaimLog(NSString *format, ...) {
    if (!format.length) return;

    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    if (message.length) {
        // Channel Points diagnostics.
        [[TPKManager sharedManager] log:@"[ChannelPoints] [AutoClaim] %@", message];
    }
}

static BOOL tpk_autoClaimEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kTPKAutoClaimPreference] != nil
        ? [defaults boolForKey:kTPKAutoClaimPreference] : YES;
}

// ── Repérage RN par accessibilityIdentifier ──
static NSString *const kTPKRNChatAreaID = @"chat-area";
static NSString *const kTPKRNClaimableChestID = @"channel-points-claimable-chest";

static BOOL tpk_rnViewIsVisible(UIView *view) {
    if (!view || view.hidden || view.alpha <= 0.0 || !view.window) return NO;
    if (CGRectIsEmpty(view.bounds) && CGRectIsEmpty(view.frame)) return NO;
    return YES;
}

// BFS borné dans une hiérarchie pour un accessibilityIdentifier.
static UIView *tpk_rnFindViewWithID(UIView *root, NSString *identifier, NSUInteger maxNodes) {
    if (!root || !identifier.length) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < maxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([identifier isEqualToString:view.accessibilityIdentifier]) {
            return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static UIViewController *tpk_viewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static void tpk_rnCollectHostControllers(UIViewController *controller,
                                          NSMutableArray<UIViewController *> *result,
                                          NSMutableSet<NSValue *> *visited) {
    if (!controller) return;
    NSValue *identity = [NSValue valueWithNonretainedObject:controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    UIView *view = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    if (view && view.window && !view.hidden && view.alpha > 0.0 &&
        tpk_rnFindViewWithID(view, kTPKRNChatAreaID, 4000)) {
        [result addObject:controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        tpk_rnCollectHostControllers(child, result, visited);
    }
    tpk_rnCollectHostControllers(controller.presentedViewController, result, visited);
}

// VC hôte du chat RN : scan direct de la fenêtre (marche sans
// rootViewController, ex. PiP), VC via la responder chain, arbre sinon.
static UIViewController *tpk_findActiveRNChatHostController(void) {
    UIViewController *bestController = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        for (UIWindow *window in windowScene.windows) {
            if (window.hidden || window.alpha <= 0.0) {
                continue;
            }
            NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
            if (window.rootViewController) {
                tpk_rnCollectHostControllers(window.rootViewController, controllers, visited);
            }
            UIView *chatArea = tpk_rnFindViewWithID(window, kTPKRNChatAreaID, 8000);
            UIViewController *chainController = tpk_viewControllerForView(chatArea);
            if (chainController && ![controllers containsObject:chainController]) {
                [controllers addObject:chainController];
            }
            for (UIViewController *controller in controllers) {
                NSInteger score = window.isKeyWindow ? 1000 : 0;
                score += (NSInteger)MIN((CGFloat)100,
                                        MAX((CGFloat)0,
                                            CGRectGetWidth(window.bounds) *
                                            CGRectGetHeight(window.bounds) / 10000.0));
                if (score > bestScore) {
                    bestScore = score;
                    bestController = controller;
                }
            }
        }
    }
    return bestController;
}

static BOOL tpk_rnHostIsActive(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return NO;
    UIView *view = controller.viewIfLoaded;
    UIWindow *window = view.window;
    UIWindowScene *scene = window.windowScene;
    if (!view || !window || !scene ||
        scene.activationState != UISceneActivationStateForegroundActive ||
        window.hidden || window.alpha <= 0.0 || view.hidden || view.alpha <= 0.0) {
        return NO;
    }
    return tpk_rnFindViewWithID(view, kTPKRNChatAreaID, 4000) != nil;
}

// Coffre réclamable dans la hiérarchie du VC hôte (nil si absent/invisible).
static UIView *tpk_rnClaimableChestForController(UIViewController *controller) {
    UIView *view = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    if (!view) return nil;
    UIView *chest = tpk_rnFindViewWithID(view, kTPKRNClaimableChestID, 6000);
    return (chest && tpk_rnViewIsVisible(chest)) ? chest : nil;
}

// Solde lu sur le paragraphe RN `channel-points-balance` ("119,7 k").
static BOOL tpk_rnParseBalanceText(NSString *text, int64_t *balance) {
    if (!text.length || !balance) return NO;
    NSMutableCharacterSet *stripped = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [stripped addCharactersInString:@"\u00a0\u202f"];
    NSString *compact = [[text componentsSeparatedByCharactersInSet:stripped]
                         componentsJoinedByString:@""];
    if (!compact.length) return NO;
    double multiplier = 1.0;
    unichar last = [compact characterAtIndex:compact.length - 1];
    if (last == 'k' || last == 'K') {
        multiplier = 1000.0;
        compact = [compact substringToIndex:compact.length - 1];
    } else if (last == 'm' || last == 'M') {
        multiplier = 1000000.0;
        compact = [compact substringToIndex:compact.length - 1];
    }
    compact = [compact stringByReplacingOccurrencesOfString:@"," withString:@"."];
    double value = compact.doubleValue;
    if (value < 0 || value * multiplier > 9000000000.0) return NO;
    *balance = (int64_t)(value * multiplier);
    return YES;
}

static BOOL tpk_rnReadChannelPointsBalance(UIViewController *controller, int64_t *balance) {
    UIView *view = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    if (!view) return NO;
    UIView *label = tpk_rnFindViewWithID(view, @"channel-points-balance", 6000);
    if (!label) return NO;
    return tpk_rnParseBalanceText(label.accessibilityLabel, balance);
}

// Fabrique un UITouch valide (KVC éprouvé) sans l'associer à un UIEvent
// (impossible sur cet iOS) : livré direct au touch handler RN de la surface.
static UITouch *tpk_rnCraftTouchOnView(UIView *view) {
    UIWindow *window = view.window;
    if (!view || !window) return nil;
    CGPoint center = CGPointMake(CGRectGetMidX(view.bounds),
                                 CGRectGetMidY(view.bounds));
    CGPoint point = [view convertPoint:center toView:nil];
    @try {
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:view forKey:@"view"];
        [touch setValue:window forKey:@"window"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:@1 forKey:@"tapCount"];
        [touch setValue:@([NSProcessInfo.processInfo systemUptime]) forKey:@"timestamp"];
        NSValue *location = [NSValue valueWithCGPoint:point];
        [touch setValue:location forKey:@"locationInWindow"];
        [touch setValue:location forKey:@"previousLocationInWindow"];
        return touch;
    } @catch (NSException *exception) {
        return nil;
    }
}

static UIGestureRecognizer *tpk_rnFindTouchHandler(UIView *view) {
    // Handler du même sous-arbre (pas le premier depuis la racine).
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        for (UIGestureRecognizer *gr in candidate.gestureRecognizers) {
            NSString *className = NSStringFromClass(gr.class);
            if ([className rangeOfString:@"TouchHandler"].location != NSNotFound) {
                return gr;
            }
        }
    }
    UIView *root = view;
    while (root.superview) root = root.superview;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 6000) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        for (UIGestureRecognizer *gr in candidate.gestureRecognizers) {
            NSString *className = NSStringFromClass(gr.class);
            if ([className rangeOfString:@"TouchHandler"].location != NSNotFound) {
                return gr;
            }
        }
        [queue addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL tpk_rnDeliverTouchToHandler(UIView *view);

BOOL TPKRNTapView(UIView *view) {
    return tpk_rnDeliverTouchToHandler(view);
}

static BOOL tpk_rnDeliverTouchToHandler(UIView *view) {
    UIGestureRecognizer *handler = tpk_rnFindTouchHandler(view);
    UITouch *touch = tpk_rnCraftTouchOnView(view);
    if (!handler || !touch) return NO;
    NSSet<UITouch *> *touches = [NSSet setWithObject:touch];
    SEL began = NSSelectorFromString(@"touchesBegan:withEvent:");
    SEL ended = NSSelectorFromString(@"touchesEnded:withEvent:");
    if (![handler respondsToSelector:began] || ![handler respondsToSelector:ended]) {
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(handler, began, touches, nil);
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        ((void (*)(id, SEL, id, id))objc_msgSend)(handler, ended, touches, nil);
        // Cancel de nettoyage (toucher coincé sinon).
        [touch setValue:@(UITouchPhaseCancelled) forKey:@"phase"];
        SEL cancelled = NSSelectorFromString(@"touchesCancelled:withEvent:");
        if ([handler respondsToSelector:cancelled]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(handler, cancelled, touches, nil);
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

// Hôte RN ? Sa vue contient déjà la zone de chat.
static BOOL tpk_isRNChatHostController(UIViewController *controller) {
    UIView *view = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    if (!view) return NO;
    return tpk_rnFindViewWithID(view, kTPKRNChatAreaID, 4000) != nil;
}

@interface TPKAutoClaimWatcher : NSObject

@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) UIView *rnChestView;
@property (nonatomic, assign) BOOL rnChestSeen;
@property (nonatomic, assign) BOOL rnHasKnownBalance;
@property (nonatomic, assign) int64_t rnLastBalance;
@property (nonatomic, assign) BOOL rnWatchingBalance;
@property (nonatomic, strong) NSDate *rnWatchDeadline;
@property (nonatomic, assign) BOOL attemptLatched;
@property (nonatomic, assign) BOOL diagnosticsLatchBlockedLogged;
@property (nonatomic, assign) BOOL diagnosticsPostAttemptWarningLogged;
@property (nonatomic, strong) NSDate *diagnosticsAttemptDate;
@property (nonatomic, copy) NSString *diagnosticsLastFailureKey;
- (instancetype)initWithController:(UIViewController *)controller;
- (void)start;
- (void)stop;
- (void)resetState;
- (void)tick;
- (void)logFailureOnceWithKey:(NSString *)key message:(NSString *)message;
@end

static __weak UIViewController *s_tpkActiveAutoClaimController;
static __weak TPKAutoClaimWatcher *s_tpkActiveAutoClaimWatcher;
static BOOL s_tpkAutoClaimRuntimeStateKnown = NO;
static BOOL s_tpkAutoClaimWasEnabled = NO;

static void tpk_removeWatcherAssociation(UIViewController *controller,
                                           TPKAutoClaimWatcher *watcher) {
    if (!controller || !watcher) return;
    if (objc_getAssociatedObject(controller,
                                 &kTPKAutoClaimWatcherAssociationKey) == watcher) {
        objc_setAssociatedObject(controller,
                                 &kTPKAutoClaimWatcherAssociationKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void tpk_stopActiveAutoClaimWatcherWithReason(NSString *reason) {
    UIViewController *controller = s_tpkActiveAutoClaimController;
    TPKAutoClaimWatcher *watcher = s_tpkActiveAutoClaimWatcher;
    s_tpkActiveAutoClaimController = nil;
    s_tpkActiveAutoClaimWatcher = nil;
    if (watcher) {
        if (watcher.attemptLatched) {
            tpk_autoClaimLog(@"latch reset after watcher invalidation");
        }
        tpk_autoClaimLog(
            @"watcher invalidated (reason=%@, controller=%@, window=%@)",
            reason.length ? reason : @"unspecified",
            controller ? NSStringFromClass(controller.class) : @"<nil>",
            controller.viewIfLoaded.window
                ? NSStringFromClass(controller.viewIfLoaded.window.class) : @"<nil>");
    }
    [watcher stop];
    tpk_removeWatcherAssociation(controller, watcher);
}

@implementation TPKAutoClaimWatcher

- (instancetype)initWithController:(UIViewController *)controller {
    self = [super init];
    if (self) _controller = controller;
    return self;
}

- (void)start {
    if (_timer || !self.controller) return;
    __weak TPKAutoClaimWatcher *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:kTPKAutoClaimTickInterval
                                      repeats:YES
                                        block:^(__unused NSTimer *timer) {
        [weakSelf tick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self tick];
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
    [self resetState];
    self.diagnosticsAttemptDate = nil;
    self.diagnosticsLatchBlockedLogged = NO;
    self.diagnosticsPostAttemptWarningLogged = NO;
}

- (void)resetState {
    _rnChestView = nil;
    _rnChestSeen = NO;
    _attemptLatched = NO;
    _rnHasKnownBalance = NO;
    _rnLastBalance = 0;
    _rnWatchingBalance = NO;
    _rnWatchDeadline = nil;
}

- (void)logFailureOnceWithKey:(NSString *)key message:(NSString *)message {
    if (!key.length || !message.length ||
        [self.diagnosticsLastFailureKey isEqualToString:key]) {
        return;
    }
    self.diagnosticsLastFailureKey = key;
    tpk_autoClaimLog(@"FAILED: %@", message);
}

- (void)tick {
    if (![NSThread isMainThread]) {
        __weak TPKAutoClaimWatcher *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf tick];
        });
        return;
    }

    UIViewController *controller = self.controller;
    if (!tpk_autoClaimEnabled()) {
        [self logFailureOnceWithKey:@"setting-off"
                            message:@"watcher stopped because Auto Collect is OFF"];
        tpk_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
        return;
    }
    if (controller != s_tpkActiveAutoClaimController || !tpk_rnHostIsActive(controller)) {
        [self logFailureOnceWithKey:@"rn-host-inactive"
                            message:@"RN chat host inactive or untracked"];
        tpk_stopActiveAutoClaimWatcherWithReason(@"RN host inactive");
        return;
    }

    UIView *chest = tpk_rnClaimableChestForController(controller);
    if (!self.rnHasKnownBalance) {
        int64_t balance = 0;
        if (tpk_rnReadChannelPointsBalance(controller, &balance)) {
            self.rnLastBalance = balance;
            self.rnHasKnownBalance = YES;
        }
    }
    if (!chest) {
        if (self.attemptLatched && self.rnChestSeen) {
            tpk_autoClaimLog(
                @"claim UI state cleared after attempt — not a reliable network confirmation");
            // Surveillance bornée : le label se met à jour après le tap.
            self.rnWatchingBalance = YES;
            self.rnWatchDeadline = [NSDate dateWithTimeIntervalSinceNow:300.0];
        }
        if (self.rnWatchingBalance) {
            BOOL expired = !self.rnWatchDeadline ||
                [[NSDate date] compare:self.rnWatchDeadline] != NSOrderedAscending;
            int64_t balance = 0;
            if (!expired && self.rnHasKnownBalance &&
                tpk_rnReadChannelPointsBalance(controller, &balance) &&
                balance != self.rnLastBalance) {
                long long difference = (long long)balance - (long long)self.rnLastBalance;
                NSString *sign = difference >= 0 ? @"+" : @"";
                NSString *emote = difference == 10 ? @"✨ " :
                    (difference == 50 ? @"🎁 " : @"");
                tpk_autoClaimLog(@"%@Channel Points balance: %lld → %lld (%@%lld)",
                                  emote, (long long)self.rnLastBalance,
                                  (long long)balance, sign, difference);
                self.rnLastBalance = balance;
                self.rnWatchingBalance = NO;
                self.rnWatchDeadline = nil;
            } else if (expired) {
                self.rnWatchingBalance = NO;
                self.rnWatchDeadline = nil;
            }
        }
        if (self.rnChestSeen) {
            tpk_autoClaimLog(@"latch reset after chest visible → gone");
        }
        self.attemptLatched = NO;
        self.rnChestSeen = NO;
        self.rnChestView = nil;
        self.diagnosticsAttemptDate = nil;
        self.diagnosticsLatchBlockedLogged = NO;
        self.diagnosticsPostAttemptWarningLogged = NO;
        return;
    }

    if (self.rnChestView != chest) {
        self.rnChestView = chest;
        self.attemptLatched = NO;
        self.rnChestSeen = NO;
    }
    if (!self.rnChestSeen) {
        tpk_autoClaimLog(@"✅ RN claimable chest visible (channel-points-claimable-chest)");
        self.rnChestSeen = YES;
        self.diagnosticsLastFailureKey = nil;
    }

    if (self.attemptLatched) {
        if (!self.diagnosticsLatchBlockedLogged) {
            tpk_autoClaimLog(
                @"attempt blocked: already sent for this chest state (no second tap)");
            self.diagnosticsLatchBlockedLogged = YES;
        }
        if (!self.diagnosticsPostAttemptWarningLogged &&
            self.diagnosticsAttemptDate &&
            [[NSDate date] timeIntervalSinceDate:self.diagnosticsAttemptDate] >=
                kTPKAutoClaimPostAttemptWarningDelay) {
            tpk_autoClaimLog(
                @"warning: chest still visible after attempt — no second tap sent");
            self.diagnosticsPostAttemptWarningLogged = YES;
        }
        return;
    }

    self.attemptLatched = YES;
    tpk_autoClaimLog(@"latch armed for this chest state");
    self.diagnosticsLatchBlockedLogged = NO;
    self.diagnosticsAttemptDate = [NSDate date];
    self.diagnosticsPostAttemptWarningLogged = NO;
    self.diagnosticsLastFailureKey = nil;
    tpk_autoClaimLog(@"🎁 CLAIM ATTEMPT (RN chest) %@ window=%@",
                      NSStringFromClass(chest.class),
                      chest.window ? NSStringFromClass(chest.window.class) : @"<nil>");
    BOOL activated = tpk_rnDeliverTouchToHandler(chest);
    tpk_autoClaimLog(@"%@ claim %@",
                      activated ? @"✅" : @"❌",
                      activated ? @"sent via touch handler" : @"refused by touch handler");
    if (!activated) {
        [self logFailureOnceWithKey:@"rn-tap:refused"
                            message:@"RN chest refused touch handler delivery"];
    }
}

@end

static void tpk_logAutoClaimControllerContext(UIViewController *controller,
                                                NSString *reason) {
    UIView *view = controller.viewIfLoaded;
    UIWindow *window = view.window;
    UIWindowScene *scene = window.windowScene;
    tpk_autoClaimLog(
        @"%@ controller=%@ window=%@ sceneState=%ld",
        reason.length ? reason : @"controller context",
        controller ? NSStringFromClass(controller.class) : @"<nil>",
        window ? NSStringFromClass(window.class) : @"<nil>",
        scene ? (long)scene.activationState : (long)UISceneActivationStateUnattached);
}

static void tpk_startAutoClaimForController(UIViewController *controller) {
    if (!tpk_autoClaimEnabled()) {
        tpk_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
        return;
    }
    // Sans hôte RN : rien à surveiller (pas de contrôleur natif en 31.5).
    if (!controller) {
        controller = tpk_findActiveRNChatHostController();
    }
    if (!controller) {
        tpk_autoClaimLog(@"watcher not started: no RN chat host");
        tpk_stopActiveAutoClaimWatcherWithReason(@"no RN chat host");
        // Le theater RN se construit en différé : retente comme l'ancien
        // resolver (0,25 / 1 / 3 / 6 / 12 s). Une seule vague à la fois.
        static NSDate *s_lastRetryWave = nil;
        BOOL waveStale = !s_lastRetryWave ||
            [[NSDate date] timeIntervalSinceDate:s_lastRetryWave] >= 15.0;
        if (waveStale) {
            s_lastRetryWave = [NSDate date];
            for (NSNumber *delay in @[@0.25, @1.0, @3.0, @6.0, @12.0]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)(delay.doubleValue *
                                                        NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (s_tpkActiveAutoClaimWatcher || !tpk_autoClaimEnabled()) return;
                    tpk_startAutoClaimForController(nil);
                });
            }
        }
        return;
    }
    if (!tpk_rnHostIsActive(controller)) {
        tpk_logAutoClaimControllerContext(controller, @"RN chat host inactive");
        tpk_stopActiveAutoClaimWatcherWithReason(@"RN chat host inactive");
        return;
    }

    if (controller == s_tpkActiveAutoClaimController &&
        s_tpkActiveAutoClaimWatcher) {
        tpk_autoClaimLog(@"watcher already exists for current controller — no duplication");
        [s_tpkActiveAutoClaimWatcher tick];
        return;
    }

    if (s_tpkActiveAutoClaimController &&
        s_tpkActiveAutoClaimController != controller) {
        tpk_autoClaimLog(
            @"context changed: RN chat host replaced — local state reset");
    }
    tpk_stopActiveAutoClaimWatcherWithReason(@"controller replaced");
    TPKAutoClaimWatcher *watcher =
        [[TPKAutoClaimWatcher alloc] initWithController:controller];
    objc_setAssociatedObject(controller, &kTPKAutoClaimWatcherAssociationKey,
                             watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s_tpkActiveAutoClaimController = controller;
    s_tpkActiveAutoClaimWatcher = watcher;
    tpk_logAutoClaimControllerContext(controller,
                                       @"controller registered as active");
    tpk_autoClaimLog(@"controller validation passed: active and visible");
    tpk_autoClaimLog(@"✅ watcher created for RN chat host");
    [watcher start];
    // Référence de solde dès la création (le tick ne relit qu'en secours).
    {
        int64_t balance = 0;
        if (tpk_rnReadChannelPointsBalance(controller, &balance)) {
            watcher.rnLastBalance = balance;
            watcher.rnHasKnownBalance = YES;
        }
    }
}

// Réconcilie l'unique watcher avec la préférence Auto Claim. Cette fonction
// est appelée uniquement sur la main queue, comme les timers et les hooks de
// cycle de vie Auto Claim.
static void tpk_reconcileAutoClaimForRuntimeState(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_reconcileAutoClaimForRuntimeState();
        });
        return;
    }

    BOOL enabled = tpk_autoClaimEnabled();
    BOOL wasKnown = s_tpkAutoClaimRuntimeStateKnown;
    BOOL wasEnabled = s_tpkAutoClaimWasEnabled;

    s_tpkAutoClaimRuntimeStateKnown = YES;
    s_tpkAutoClaimWasEnabled = enabled;

    if (enabled) {
        tpk_startAutoClaimForController(nil);
    } else {
        tpk_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
    }

    if (!wasKnown || enabled != wasEnabled) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKAutoClaimRuntimeStateDidChangeNotification
                          object:nil];
    }
}

static BOOL tpk_hasOwnMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void tpk_installAutoClaimLifecycleOnClass(Class targetClass) {
    if (!targetClass) return;

    SEL appear = @selector(viewDidAppear:);
    SEL willDisappear = @selector(viewWillDisappear:);
    SEL didDisappear = @selector(viewDidDisappear:);
    SEL swizzledAppear = @selector(tpk_autoclaim_viewDidAppear:);
    SEL swizzledWillDisappear = @selector(tpk_autoclaim_viewWillDisappear:);
    SEL swizzledDidDisappear = @selector(tpk_autoclaim_viewDidDisappear:);
    SEL originals[] = {appear, willDisappear, didDisappear};
    SEL replacements[] = {swizzledAppear, swizzledWillDisappear,
                          swizzledDidDisappear};

    for (NSUInteger index = 0; index < 3; index++) {
        if (tpk_hasOwnMethod(targetClass, replacements[index])) continue;

        Method originalMethod = class_getInstanceMethod(targetClass,
                                                         originals[index]);
        Method replacementMethod = class_getInstanceMethod(
            [UIViewController class], replacements[index]);
        if (!originalMethod || !replacementMethod) return;

        if (!tpk_hasOwnMethod(targetClass, originals[index])) {
            class_addMethod(targetClass, originals[index],
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
        }
        class_addMethod(targetClass, replacements[index],
                        method_getImplementation(replacementMethod),
                        method_getTypeEncoding(replacementMethod));
        method_exchangeImplementations(
            class_getInstanceMethod(targetClass, originals[index]),
            class_getInstanceMethod(targetClass, replacements[index]));
    }
}

static void tpk_installAutoClaimLifecycleHooks(void) {
    Class rnScreenClass = NSClassFromString(@"RNSScreen");
    if (rnScreenClass) tpk_installAutoClaimLifecycleOnClass(rnScreenClass);
}

@interface UIViewController (TPKAutoClaimLifecycle)
- (void)tpk_autoclaim_viewDidAppear:(BOOL)animated;
- (void)tpk_autoclaim_viewWillDisappear:(BOOL)animated;
- (void)tpk_autoclaim_viewDidDisappear:(BOOL)animated;
@end

@implementation UIViewController (TPKAutoClaimLifecycle)

- (void)tpk_autoclaim_viewDidAppear:(BOOL)animated {
    [self tpk_autoclaim_viewDidAppear:animated];
    if (tpk_isRNChatHostController(self)) {
        tpk_logAutoClaimControllerContext(self, @"RN chat host viewDidAppear detected");
        tpk_startAutoClaimForController(self);
    }
}

- (void)tpk_autoclaim_viewWillDisappear:(BOOL)animated {
    if (self == s_tpkActiveAutoClaimController) {
        tpk_autoClaimLog(@"controller viewWillDisappear: %@",
                          NSStringFromClass(self.class));
        tpk_stopActiveAutoClaimWatcherWithReason(@"viewWillDisappear");
    }
    [self tpk_autoclaim_viewWillDisappear:animated];
}

- (void)tpk_autoclaim_viewDidDisappear:(BOOL)animated {
    if (self == s_tpkActiveAutoClaimController) {
        tpk_autoClaimLog(@"controller viewDidDisappear: %@",
                          NSStringFromClass(self.class));
        tpk_stopActiveAutoClaimWatcherWithReason(@"viewDidDisappear");
    }
    [self tpk_autoclaim_viewDidDisappear:animated];
}

@end

static id s_tpkAutoClaimWillResignObserver;
static id s_tpkAutoClaimDidBecomeObserver;

static void tpk_registerAutoClaimApplicationObservers(void) {
    if (s_tpkAutoClaimWillResignObserver ||
        s_tpkAutoClaimDidBecomeObserver) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    s_tpkAutoClaimWillResignObserver =
        [center addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
        tpk_autoClaimLog(@"application background");
        tpk_autoClaimLog(@"watcher suspended: application background");
        tpk_stopActiveAutoClaimWatcherWithReason(@"application background");
    }];
    s_tpkAutoClaimDidBecomeObserver =
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
        tpk_autoClaimLog(@"application foreground");
        tpk_installAutoClaimLifecycleHooks();
        if (tpk_autoClaimEnabled()) {
            tpk_startAutoClaimForController(nil);
        } else {
            tpk_autoClaimLog(@"foreground: watcher not recreated because Auto Collect is OFF");
        }
    }];
}

static void tpk_setupAutoClaimOnMain(void) {
    tpk_installAutoClaimLifecycleHooks();
    tpk_registerAutoClaimApplicationObservers();
    tpk_reconcileAutoClaimForRuntimeState();
}

void TPKAutoClaimSetup(void) {
    if ([NSThread isMainThread]) {
        tpk_setupAutoClaimOnMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_setupAutoClaimOnMain();
        });
    }
}

void TPKAutoClaimSettingsDidChange(void) {
    if ([NSThread isMainThread]) {
        BOOL enabled = tpk_autoClaimEnabled();
        tpk_autoClaimLog(@"toggle Auto Collect: %@", enabled ? @"ON" : @"OFF");
        tpk_setupAutoClaimOnMain();
        if (enabled) {
            tpk_autoClaimLog(
                @"toggle ON: %@",
                s_tpkActiveAutoClaimWatcher
                    ? @"watcher active immediately"
                    : @"watcher not started — no RN chat host available");
        } else {
            tpk_autoClaimLog(@"toggle OFF: watcher stopped");
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL enabled = tpk_autoClaimEnabled();
            tpk_autoClaimLog(@"toggle Auto Collect: %@", enabled ? @"ON" : @"OFF");
            tpk_setupAutoClaimOnMain();
            if (enabled) {
                tpk_autoClaimLog(
                    @"toggle ON: %@",
                    s_tpkActiveAutoClaimWatcher
                        ? @"watcher active immediately"
                        : @"watcher not started — no RN chat host available");
            } else {
                tpk_autoClaimLog(@"toggle OFF: watcher stopped");
            }
        });
    }
}

TPKAutoClaimDiagnosticsState *TPKAutoClaimDiagnosticsCurrentState(void) {
    if (![NSThread isMainThread]) {
        __block TPKAutoClaimDiagnosticsState *state = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            state = TPKAutoClaimDiagnosticsCurrentState();
        });
        return state ?: [TPKAutoClaimDiagnosticsState new];
    }

    TPKAutoClaimDiagnosticsState *state =
        [TPKAutoClaimDiagnosticsState new];
    BOOL enabled = tpk_autoClaimEnabled();
    state.effectiveState = enabled
        ? TPKAutoClaimEffectiveStateActive
        : TPKAutoClaimEffectiveStateDisabledByUser;

    TPKAutoClaimWatcher *watcher = s_tpkActiveAutoClaimWatcher;
    state.watcherActive = watcher != nil && watcher.timer != nil &&
        watcher.timer.isValid;

    UIViewController *controller = s_tpkActiveAutoClaimController;
    if (!controller || !tpk_rnHostIsActive(controller)) {
        controller = tpk_findActiveRNChatHostController();
        if (controller && !tpk_rnHostIsActive(controller)) controller = nil;
    }
    state.rnChatHostDetected = (controller != nil);
    state.rnChestDetected =
        (controller && tpk_rnClaimableChestForController(controller) != nil);
    state.rnBalanceKnown = NO;
    state.rnBalance = 0;
    if (controller) {
        int64_t balance = 0;
        if (tpk_rnReadChannelPointsBalance(controller, &balance)) {
            state.rnBalanceKnown = YES;
            state.rnBalance = balance;
        }
    }

    return state;
}
