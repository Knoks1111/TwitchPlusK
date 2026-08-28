/*
 * 7tv-system-autoclaim.m
 *
 * Isolated native Auto Claim implementation. Twitch owns the Channel Points
 * state; this module only observes the already-created live chat hierarchy and
 * invokes Twitch's own button handler when its button reports an available
 * claim.
 */

#import "System/7tv-system-autoclaim.h"
#import "Core/7tv-core-manager.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <stddef.h>
#import <stdint.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

static NSString *const kS7TVAutoClaimPreference =
    @"TCDBGLiveAutoCollectChannelPoints";
static const NSTimeInterval kS7TVAutoClaimTickInterval = 1.0;
static const NSTimeInterval kS7TVAutoClaimPostAttemptWarningDelay = 10.0;
static char kS7TVAutoClaimWatcherAssociationKey;

static void s7tv_autoClaimLog(NSString *format, ...) {
    if (!format.length) return;

    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    if (message.length) {
        // Keep the existing Channel Points log category while retaining the
        // stable diagnostic prefix used to filter these lines.
        [[SevenTVManager sharedManager] log:@"[AutoClaim] %@ — Channel Points", message];
    }
}

static BOOL s7tv_autoClaimEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kS7TVAutoClaimPreference] != nil
        ? [defaults boolForKey:kS7TVAutoClaimPreference] : YES;
}

static BOOL s7tv_runtimeClassIsNamed(id object, NSString *name,
                                     NSString *legacyName) {
    if (!object) return NO;
    NSString *className = NSStringFromClass(object_getClass(object));
    if ([className isEqualToString:name] ||
        (legacyName.length && [className isEqualToString:legacyName])) {
        return YES;
    }
    Class expectedClass = NSClassFromString(name);
    return expectedClass && [object isKindOfClass:expectedClass];
}

static BOOL s7tv_isChannelChatViewController(id object) {
    return s7tv_runtimeClassIsNamed(
        object, @"Twitch.ChannelChatViewController",
        @"_TtC6Twitch25ChannelChatViewController");
}

static BOOL s7tv_isBitsController(id object) {
    return s7tv_runtimeClassIsNamed(
        object, @"Twitch.TWBitsController",
        @"_TtC6Twitch16TWBitsController");
}

static BOOL s7tv_isChatInputView(id object) {
    return s7tv_runtimeClassIsNamed(
        object, @"Twitch.ChatInputView",
        @"_TtC6Twitch13ChatInputView");
}

static BOOL s7tv_isChannelPointsButton(id object) {
    return s7tv_runtimeClassIsNamed(
        object, @"Twitch.ChannelPointsChatButton",
        @"_TtC6Twitch23ChannelPointsChatButton");
}

static Ivar s7tv_ivarForObject(id object, const char *name) {
    if (!object || !name) return NULL;
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar && name[0] != '_') {
        NSString *underscoredName = [NSString stringWithFormat:@"_%s", name];
        ivar = class_getInstanceVariable(cls, underscoredName.UTF8String);
    }
    return ivar;
}

static id s7tv_objectIvar(id object, const char *name) {
    Ivar ivar = s7tv_ivarForObject(object, name);
    const char *encoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    // Swift-compiled object ivars in the current Twitch binary expose an
    // empty Objective-C encoding. Permit only the known object slots used by
    // this module; each call site still validates the expected runtime class.
    BOOL isObjectiveCObject = encoding && encoding[0] == '@';
    BOOL isKnownOpaqueSwiftObject = encoding && encoding[0] == '\0' &&
         (strcmp(name, "bitsController") == 0 ||
         strcmp(name, "chatInputView") == 0 ||
         strcmp(name, "channelPointsButton") == 0);
    if (!isObjectiveCObject && !isKnownOpaqueSwiftObject) return nil;

    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(object_getClass(object));
    if (offset < 0 || (size_t)offset > instanceSize ||
        sizeof(id) > instanceSize - (size_t)offset ||
        ((size_t)offset % _Alignof(void *)) != 0) {
        return nil;
    }
    return object_getIvar(object, ivar);
}

static BOOL s7tv_readBoolIvar(id object, const char *name, BOOL *value) {
    if (!object || !name || !value) return NO;
    Ivar ivar = s7tv_ivarForObject(object, name);
    if (!ivar) return NO;

    const char *encoding = ivar_getTypeEncoding(ivar);
    BOOL isObjectiveCBool = encoding &&
        (encoding[0] == 'B' || encoding[0] == 'c' || encoding[0] == 'C');
    // The current Swift ChatInput button exposes `showsClaim` with an empty
    // Objective-C encoding even though it is a one-byte Bool.
    BOOL isKnownOpaqueSwiftBool = encoding && encoding[0] == '\0' &&
        strcmp(name, "showsClaim") == 0;
    if (!isObjectiveCBool && !isKnownOpaqueSwiftBool) {
        return NO;
    }

    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(object_getClass(object));
    if (offset < 0 || (size_t)offset >= instanceSize ||
        1 > instanceSize - (size_t)offset) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    *value = bytes[offset] != 0;
    return YES;
}

// `channelPointsState` is a Swift value type in the current Twitch build, so
// Objective-C cannot return it through `object_getIvar`. Resolve the live
// Swift metadata field offset instead of assuming a fixed offset in the
// value. The accessor address is tied to the currently audited Twitch binary;
// its instruction signature is checked so a future binary fails closed.
static const uint8_t *s7tv_channelPointsStateMetadata(void) {
    static const uint8_t *metadata;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controllerClass = NSClassFromString(
            @"_TtC6Twitch25ChannelChatViewController");
        if (!controllerClass) {
            controllerClass = NSClassFromString(
                @"Twitch.ChannelChatViewController");
        }
        Method knownMethod = controllerClass
            ? class_getInstanceMethod(controllerClass, @selector(viewDidLoad))
            : NULL;
        IMP knownImplementation = knownMethod
            ? method_getImplementation(knownMethod) : NULL;
        Dl_info imageInfo = {0};
        if (!knownImplementation ||
            dladdr((const void *)knownImplementation, &imageInfo) == 0 ||
            !imageInfo.dli_fbase) {
            return;
        }

        // Relative to the image base of the audited current Twitch build.
        const uintptr_t accessorOffset = 0x3232ed8;
        uintptr_t accessorAddress =
            (uintptr_t)imageInfo.dli_fbase + accessorOffset;
        Dl_info accessorInfo = {0};
        if (dladdr((const void *)accessorAddress, &accessorInfo) == 0 ||
            accessorInfo.dli_fbase != imageInfo.dli_fbase) {
            return;
        }

        // The first two instructions of the current metadata accessor. This
        // prevents calling an unrelated address after a Twitch update.
        uint32_t signature[4] = {0, 0, 0, 0};
        memcpy(signature, (const void *)accessorAddress, sizeof(signature));
        if (signature[0] != 0xaa0003e8 || signature[1] != 0xb0013989 ||
            signature[2] != 0xf9477120 || signature[3] != 0xb4000060) {
            return;
        }

        typedef const void *(*S7TVMetadataAccessor)(uintptr_t request);
        S7TVMetadataAccessor accessor =
            (S7TVMetadataAccessor)(uintptr_t)accessorAddress;
        metadata = (const uint8_t *)accessor(0);
    });
    return metadata;
}

static BOOL s7tv_channelPointsStateStorageForController(
    UIViewController *controller, uintptr_t *stateAddress) {
    if (stateAddress) *stateAddress = 0;
    if (!controller || !s7tv_isChannelChatViewController(controller)) return NO;

    Ivar stateIvar = s7tv_ivarForObject(controller, "channelPointsState");
    if (!stateIvar) return NO;

    // A future object-backed implementation is a different layout. Do not
    // guess at its contents or interpret an Objective-C object pointer as a
    // Swift value.
    const char *encoding = ivar_getTypeEncoding(stateIvar);
    if (encoding && encoding[0] == '@') return NO;

    ptrdiff_t offset = ivar_getOffset(stateIvar);
    size_t instanceSize = class_getInstanceSize(object_getClass(controller));
    if (offset < 0 || (size_t)offset >= instanceSize ||
        ((size_t)offset % _Alignof(uint64_t)) != 0) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)controller;
    if (stateAddress) *stateAddress = (uintptr_t)(bytes + offset);
    return YES;
}

static BOOL s7tv_readNativeChannelPointsBalance(
    UIViewController *controller, uintptr_t *stateAddress, int64_t *balance) {
    if (stateAddress) *stateAddress = 0;
    if (!balance) return NO;

    uintptr_t address = 0;
    if (!s7tv_channelPointsStateStorageForController(controller, &address)) {
        return NO;
    }
    if (stateAddress) *stateAddress = address;

    if (sizeof(void *) != 8) return NO;
    const uint8_t *metadata = s7tv_channelPointsStateMetadata();
    if (!metadata || ((uintptr_t)metadata % _Alignof(uint64_t)) != 0) {
        return NO;
    }

    // Swift's resilient struct metadata stores field offsets as 32-bit
    // values. FieldOffsetVectorOffset is 2 for this type and
    // lastChannelPointsBalance is field 6, so the live entry is at
    // metadata + 2 pointers + 6 uint32_t values.
    const size_t fieldOffsetEntry =
        (2 * sizeof(uintptr_t)) + (6 * sizeof(uint32_t));
    uint32_t balanceOffset = 0;
    memcpy(&balanceOffset, metadata + fieldOffsetEntry,
           sizeof(balanceOffset));

    Ivar stateIvar = s7tv_ivarForObject(controller, "channelPointsState");
    ptrdiff_t stateIvarOffset = stateIvar ? ivar_getOffset(stateIvar) : -1;
    size_t instanceSize = class_getInstanceSize(object_getClass(controller));
    size_t stateSize = (stateIvarOffset >= 0 &&
                        (size_t)stateIvarOffset < instanceSize)
        ? instanceSize - (size_t)stateIvarOffset : 0;
    Ivar followingIvar = s7tv_ivarForObject(controller, "watchStreakStatus");
    ptrdiff_t followingIvarOffset = followingIvar
        ? ivar_getOffset(followingIvar) : -1;
    if (stateIvarOffset >= 0 && followingIvarOffset > stateIvarOffset &&
        (size_t)followingIvarOffset <= instanceSize) {
        stateSize = (size_t)followingIvarOffset - (size_t)stateIvarOffset;
    }
    if (stateIvarOffset < 0 || (size_t)stateIvarOffset >= instanceSize ||
        balanceOffset == 0 ||
        (size_t)balanceOffset > stateSize ||
        16 > stateSize - (size_t)balanceOffset ||
        (balanceOffset % _Alignof(uint64_t)) != 0) {
        return NO;
    }

    uintptr_t balanceAddress = address + (uintptr_t)balanceOffset;
    uint64_t payload = 0;
    uint64_t discriminator = UINT64_MAX;
    memcpy(&payload, (const void *)balanceAddress, sizeof(payload));
    memcpy(&discriminator, (const void *)(balanceAddress + sizeof(payload)),
           sizeof(discriminator));

    // Optional<Int> uses discriminator 0 for `.some` in Swift's native
    // representation in this arm64 build. Any other value is treated as
    // unknown, so a missing balance can never turn into a fabricated
    // diagnostic.
    if (discriminator != 0 || payload > INT64_MAX) return NO;
    *balance = (int64_t)payload;
    return YES;
}

static void s7tv_setAutoClaimFailure(NSString **failureReason,
                                      NSString *reason) {
    if (failureReason) *failureReason = reason;
}

static UIView *s7tv_chatInputViewForController(
    UIViewController *controller, NSString **failureReason) {
    if (failureReason) *failureReason = nil;
    if (!controller || !s7tv_isChannelChatViewController(controller)) {
        s7tv_setAutoClaimFailure(failureReason,
                                 @"controller class incompatible");
        return nil;
    }

    if (!controller.isViewLoaded) {
        s7tv_setAutoClaimFailure(failureReason, @"view not loaded");
        return nil;
    }
    UIView *controllerView = controller.viewIfLoaded;
    if (!controllerView) {
        s7tv_setAutoClaimFailure(failureReason, @"view not loaded");
        return nil;
    }
    UIWindow *controllerWindow = controllerView.window;
    if (!controllerWindow) {
        s7tv_setAutoClaimFailure(failureReason, @"window nil");
        return nil;
    }

    Ivar bitsIvar = s7tv_ivarForObject(controller, "bitsController");
    if (!bitsIvar) {
        s7tv_setAutoClaimFailure(failureReason,
                                 @"ivar bitsController not found");
        return nil;
    }
    id bitsController = s7tv_objectIvar(controller, "bitsController");
    if (!bitsController) {
        s7tv_setAutoClaimFailure(failureReason, @"bitsController == nil");
        return nil;
    }
    if (!s7tv_isBitsController(bitsController)) {
        s7tv_setAutoClaimFailure(
            failureReason,
            [NSString stringWithFormat:@"hierarchy invalid: bitsController class %@",
                                       NSStringFromClass(object_getClass(bitsController))]);
        return nil;
    }

    Ivar chatInputIvar = s7tv_ivarForObject(bitsController, "chatInputView");
    if (!chatInputIvar) {
        s7tv_setAutoClaimFailure(failureReason,
                                 @"ivar chatInputView not found");
        return nil;
    }
    id chatInput = s7tv_objectIvar(bitsController, "chatInputView");
    if (!chatInput) {
        s7tv_setAutoClaimFailure(failureReason, @"chatInputView == nil");
        return nil;
    }
    if (!s7tv_isChatInputView(chatInput) ||
        ![chatInput isKindOfClass:UIView.class]) {
        s7tv_setAutoClaimFailure(
            failureReason,
            [NSString stringWithFormat:@"hierarchy invalid: chatInputView class %@",
                                       NSStringFromClass(object_getClass(chatInput))]);
        return nil;
    }

    UIView *chatInputView = (UIView *)chatInput;
    if (!chatInputView.window) {
        s7tv_setAutoClaimFailure(failureReason,
                                 @"hierarchy invalid: chatInputView window nil");
        return nil;
    }
    if (chatInputView.window != controllerWindow) {
        s7tv_setAutoClaimFailure(
            failureReason,
            @"hierarchy invalid: chatInputView window differs from controller window");
        return nil;
    }

    // The view must belong to this controller, not merely happen to share a
    // window with another chat or a stale PiP hierarchy.
    BOOL belongsToController = [chatInputView isDescendantOfView:controllerView];
    if (!belongsToController) {
        UIResponder *responder = chatInputView;
        while (responder) {
            if (responder == controller) {
                belongsToController = YES;
                break;
            }
            responder = responder.nextResponder;
        }
    }
    if (!belongsToController) {
        s7tv_setAutoClaimFailure(failureReason,
                                 @"hierarchy invalid: chatInputView not owned by controller");
        return nil;
    }

    return chatInputView;
}

static BOOL s7tv_controllerIsActive(UIViewController *controller) {
    if (!controller || !s7tv_isChannelChatViewController(controller)) return NO;

    UIView *view = controller.isViewLoaded ? controller.viewIfLoaded : nil;
    UIWindow *window = view.window;
    UIWindowScene *scene = window.windowScene;
    if (!view || !window || !scene ||
        scene.activationState != UISceneActivationStateForegroundActive ||
        window.hidden || window.alpha <= 0.0 || view.hidden || view.alpha <= 0.0) {
        return NO;
    }
    return YES;
}

static NSString *s7tv_controllerActivityFailureReason(
    UIViewController *controller, UIViewController *trackedController) {
    if (!controller) return @"controller == nil";
    if (!s7tv_isChannelChatViewController(controller)) {
        return @"controller class incompatible";
    }
    if (trackedController && controller != trackedController) {
        return @"controller differs from tracked";
    }
    if (!controller.isViewLoaded) return @"view not loaded";

    UIView *view = controller.viewIfLoaded;
    if (!view) return @"view not loaded";
    UIWindow *window = view.window;
    if (!window) return @"window nil";
    UIWindowScene *scene = window.windowScene;
    if (!scene) return @"scene absent";
    if (scene.activationState != UISceneActivationStateForegroundActive) {
        return [NSString stringWithFormat:@"scene not ForegroundActive (state=%ld)",
                                          (long)scene.activationState];
    }
    if (window.hidden || window.alpha <= 0.0 || view.hidden || view.alpha <= 0.0) {
        return @"view not visible";
    }
    return nil;
}

static void s7tv_logAutoClaimControllerContext(UIViewController *controller,
                                                NSString *reason) {
    UIView *view = controller.viewIfLoaded;
    UIWindow *window = view.window;
    UIWindowScene *scene = window.windowScene;
    s7tv_autoClaimLog(
        @"%@ controller=%@ window=%@ sceneState=%ld",
        reason.length ? reason : @"controller context",
        controller ? NSStringFromClass(controller.class) : @"<nil>",
        window ? NSStringFromClass(window.class) : @"<nil>",
        scene ? (long)scene.activationState : (long)UISceneActivationStateUnattached);
}

static void s7tv_collectControllers(UIViewController *controller,
                                    NSMutableArray<UIViewController *> *result,
                                    NSMutableSet<NSValue *> *visited) {
    if (!controller) return;
    NSValue *identity = [NSValue valueWithNonretainedObject:controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    if (s7tv_isChannelChatViewController(controller)) {
        [result addObject:controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        s7tv_collectControllers(child, result, visited);
    }
    s7tv_collectControllers(controller.presentedViewController, result, visited);
}

// This scan is used only when starting/resuming the watcher. Individual ticks
// validate the retained controller and never enumerate every application
// window.
static UIViewController *s7tv_findActiveChannelChatViewController(void) {
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
            if (window.hidden || window.alpha <= 0.0 || !window.rootViewController) {
                continue;
            }

            NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
            s7tv_collectControllers(window.rootViewController, controllers, visited);
            for (UIViewController *controller in controllers) {
                if (!s7tv_controllerIsActive(controller)) continue;

                NSInteger score = window.isKeyWindow ? 1000 : 0;
                score += (NSInteger)MIN((CGFloat)100,
                                        MAX((CGFloat)0,
                                            CGRectGetWidth(window.bounds) *
                                            CGRectGetHeight(window.bounds) / 10000.0));
                if (s7tv_chatInputViewForController(controller, NULL)) score += 100;
                if (score > bestScore) {
                    bestScore = score;
                    bestController = controller;
                }
            }
        }
    }
    return bestController;
}

@interface S7TVAutoClaimWatcher : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) id lastBitsController;
@property (nonatomic, weak) id lastChatInputView;
@property (nonatomic, weak) id lastChannelPointsButton;
@property (nonatomic, assign) uintptr_t lastChannelIdentity;
@property (nonatomic, assign) BOOL attemptLatched;
@property (nonatomic, assign) BOOL lastShowsClaim;
@property (nonatomic, assign) BOOL diagnosticsChainResolved;
@property (nonatomic, assign) BOOL diagnosticsHasObservedShowsClaim;
@property (nonatomic, assign) BOOL diagnosticsLastShowsClaim;
@property (nonatomic, assign) BOOL diagnosticsLatchBlockedLogged;
@property (nonatomic, assign) BOOL diagnosticsPostAttemptWarningLogged;
@property (nonatomic, strong) NSDate *diagnosticsAttemptDate;
@property (nonatomic, copy) NSString *diagnosticsLastFailureKey;
@property (nonatomic, weak) id diagnosticsBitsController;
@property (nonatomic, weak) id diagnosticsChatInputView;
@property (nonatomic, weak) id diagnosticsChannelPointsButton;
@property (nonatomic, assign) uintptr_t diagnosticsChannelPointsStateAddress;
@property (nonatomic, weak) UIWindow *diagnosticsWindow;
@property (nonatomic, assign) uintptr_t diagnosticsChannelIdentity;
@property (nonatomic, assign) BOOL diagnosticsHasContext;
@property (nonatomic, assign) BOOL diagnosticsHasKnownBalance;
@property (nonatomic, assign) int64_t diagnosticsLastBalance;
- (instancetype)initWithController:(UIViewController *)controller;
- (void)start;
- (void)stop;
- (void)resetState;
- (void)tick;
- (void)logFailureOnceWithKey:(NSString *)key message:(NSString *)message;
- (void)resetDiagnosticContext;
- (void)clearDiagnosticContext;
- (void)observeChannelPointsBalanceForController:(UIViewController *)controller;
@end

static __weak UIViewController *s_s7tvActiveAutoClaimController;
static __weak S7TVAutoClaimWatcher *s_s7tvActiveAutoClaimWatcher;

static void s7tv_removeWatcherAssociation(UIViewController *controller,
                                           S7TVAutoClaimWatcher *watcher) {
    if (!controller || !watcher) return;
    if (objc_getAssociatedObject(controller,
                                 &kS7TVAutoClaimWatcherAssociationKey) == watcher) {
        objc_setAssociatedObject(controller,
                                 &kS7TVAutoClaimWatcherAssociationKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void s7tv_stopActiveAutoClaimWatcherWithReason(NSString *reason) {
    UIViewController *controller = s_s7tvActiveAutoClaimController;
    S7TVAutoClaimWatcher *watcher = s_s7tvActiveAutoClaimWatcher;
    s_s7tvActiveAutoClaimController = nil;
    s_s7tvActiveAutoClaimWatcher = nil;
    if (watcher) {
        if (watcher.attemptLatched) {
            s7tv_autoClaimLog(@"latch reset after watcher invalidation");
        }
        s7tv_autoClaimLog(
            @"watcher invalidated (reason=%@, controller=%@, window=%@)",
            reason.length ? reason : @"unspecified",
            controller ? NSStringFromClass(controller.class) : @"<nil>",
            controller.viewIfLoaded.window
                ? NSStringFromClass(controller.viewIfLoaded.window.class) : @"<nil>");
    }
    [watcher stop];
    s7tv_removeWatcherAssociation(controller, watcher);
}

@implementation S7TVAutoClaimWatcher

- (instancetype)initWithController:(UIViewController *)controller {
    self = [super init];
    if (self) _controller = controller;
    return self;
}

- (void)start {
    if (_timer || !self.controller) return;
    __weak S7TVAutoClaimWatcher *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:kS7TVAutoClaimTickInterval
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
    [self clearDiagnosticContext];
}

- (void)resetState {
    _lastBitsController = nil;
    _lastChatInputView = nil;
    _lastChannelPointsButton = nil;
    _lastChannelIdentity = 0;
    _attemptLatched = NO;
    _lastShowsClaim = NO;
}

- (void)resetDiagnosticContext {
    self.diagnosticsChainResolved = NO;
    self.diagnosticsHasObservedShowsClaim = NO;
    self.diagnosticsLastShowsClaim = NO;
    self.diagnosticsLatchBlockedLogged = NO;
    self.diagnosticsPostAttemptWarningLogged = NO;
    self.diagnosticsAttemptDate = nil;
    self.diagnosticsLastFailureKey = nil;
    self.diagnosticsChannelPointsStateAddress = 0;
    self.diagnosticsHasKnownBalance = NO;
    self.diagnosticsLastBalance = 0;
}

- (void)clearDiagnosticContext {
    [self resetDiagnosticContext];
    self.diagnosticsBitsController = nil;
    self.diagnosticsChatInputView = nil;
    self.diagnosticsChannelPointsButton = nil;
    self.diagnosticsChannelPointsStateAddress = 0;
    self.diagnosticsWindow = nil;
    self.diagnosticsChannelIdentity = 0;
    self.diagnosticsHasContext = NO;
    self.diagnosticsHasKnownBalance = NO;
    self.diagnosticsLastBalance = 0;
}

- (void)logFailureOnceWithKey:(NSString *)key message:(NSString *)message {
    if (!key.length || !message.length ||
        [self.diagnosticsLastFailureKey isEqualToString:key]) {
        return;
    }
    self.diagnosticsLastFailureKey = key;

    if ([key hasPrefix:@"ivar:"] || [key hasPrefix:@"showsClaim:"]) {
        NSString *name = nil;
        if ([key isEqualToString:@"ivar:bitsController"]) name = @"bitsController";
        else if ([key isEqualToString:@"ivar:chatInputView"]) name = @"chatInputView";
        else if ([key isEqualToString:@"ivar:channelPointsButton"]) name = @"channelPointsButton";
        else if ([key isEqualToString:@"showsClaim:missing"]) name = @"showsClaim";
        if (name.length) {
            s7tv_autoClaimLog(@"COMPATIBILITY FAILURE: `%@` ivar unavailable", name);
        } else if ([key isEqualToString:@"showsClaim:unsafe"]) {
            s7tv_autoClaimLog(@"COMPATIBILITY FAILURE: unable to read `showsClaim` safely");
        }
    }
    s7tv_autoClaimLog(@"FAILED: %@", message);
}

- (void)observeChannelPointsBalanceForController:(UIViewController *)controller {
    uintptr_t stateAddress = 0;
    int64_t balance = 0;
    BOOL balanceKnown = s7tv_readNativeChannelPointsBalance(
        controller, &stateAddress, &balance);

    if (self.diagnosticsChannelPointsStateAddress != stateAddress) {
        self.diagnosticsChannelPointsStateAddress = stateAddress;
        self.diagnosticsHasKnownBalance = NO;
        self.diagnosticsLastBalance = 0;
    }

    if (!balanceKnown) {
        // Twitch may not have published a balance yet. An unknown value is
        // deliberately not logged and cannot be compared with old data.
        self.diagnosticsHasKnownBalance = NO;
        return;
    }

    if (self.diagnosticsHasKnownBalance &&
        self.diagnosticsLastBalance != balance) {
        long long previous = (long long)self.diagnosticsLastBalance;
        long long current = (long long)balance;
        long long difference = current - previous;
        NSString *sign = difference >= 0 ? @"+" : @"";
        s7tv_autoClaimLog(
            @"Channel Points balance: %lld → %lld (%@%lld)",
            previous, current, sign, difference);
        if (self.diagnosticsAttemptDate) {
            s7tv_autoClaimLog(
                @"native balance variation observed after the Auto Claim attempt; attribution to the claim is not proven");
        }
    }

    self.diagnosticsLastBalance = balance;
    self.diagnosticsHasKnownBalance = YES;
}

- (void)tick {
    if (![NSThread isMainThread]) {
        __weak S7TVAutoClaimWatcher *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf tick];
        });
        return;
    }

    UIViewController *controller = self.controller;
    if (!s7tv_autoClaimEnabled()) {
        [self logFailureOnceWithKey:@"setting-off"
                            message:@"watcher stopped because Auto Collect is OFF"];
        s7tv_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
        return;
    }
    if (controller != s_s7tvActiveAutoClaimController) {
        NSString *reason = s7tv_controllerActivityFailureReason(
            controller, s_s7tvActiveAutoClaimController);
        [self logFailureOnceWithKey:@"controller-untracked"
                            message:reason.length ? reason
                                                   : @"controller differs from tracked"];
        s7tv_stopActiveAutoClaimWatcherWithReason(@"controller differs from tracked");
        return;
    }
    if (!s7tv_controllerIsActive(controller)) {
        NSString *reason = s7tv_controllerActivityFailureReason(
            controller, s_s7tvActiveAutoClaimController);
        NSString *key = [NSString stringWithFormat:@"validation:%@",
                         reason.length ? reason : @"inactive"];
        [self logFailureOnceWithKey:key
                            message:reason.length ? reason : @"controller not active"];
        s7tv_stopActiveAutoClaimWatcherWithReason(
            reason.length ? reason : @"controller not active");
        return;
    }

    NSString *chainFailure = nil;
    UIView *chatInputView = s7tv_chatInputViewForController(controller,
                                                             &chainFailure);
    if (!chatInputView || chatInputView.hidden || chatInputView.alpha <= 0.0) {
        if (!chatInputView) {
            self.diagnosticsChainResolved = NO;
            NSString *failure = chainFailure.length ? chainFailure
                                                     : @"native chain unavailable";
            NSString *key = [NSString stringWithFormat:@"chain:%@", failure];
            if ([failure isEqualToString:@"ivar bitsController not found"]) {
                key = @"ivar:bitsController";
            } else if ([failure isEqualToString:@"ivar chatInputView not found"]) {
                key = @"ivar:chatInputView";
            }
            [self logFailureOnceWithKey:key message:failure];
        } else {
            self.diagnosticsChainResolved = NO;
            [self logFailureOnceWithKey:@"chat-input-hidden"
                                message:@"view not visible: ChatInputView hidden or alpha zero"];
        }
        [self resetState];
        return;
    }

    id bitsController = s7tv_objectIvar(controller, "bitsController");
    Ivar buttonIvar = s7tv_ivarForObject(chatInputView,
                                         "channelPointsButton");
    if (!buttonIvar) {
        [self logFailureOnceWithKey:@"ivar:channelPointsButton"
                            message:@"ivar channelPointsButton not found"];
        self.diagnosticsChainResolved = NO;
        [self resetState];
        return;
    }
    id channelPointsButton = s7tv_objectIvar(chatInputView,
                                              "channelPointsButton");
    if (!channelPointsButton) {
        [self logFailureOnceWithKey:@"button:nil"
                            message:@"channelPointsButton == nil"];
        self.diagnosticsChainResolved = NO;
        [self resetState];
        return;
    }
    if (!s7tv_isChannelPointsButton(channelPointsButton)) {
        [self logFailureOnceWithKey:@"button:class"
                            message:[NSString stringWithFormat:
                                     @"hierarchy invalid: channelPointsButton class %@",
                                     NSStringFromClass(object_getClass(channelPointsButton))]];
        self.diagnosticsChainResolved = NO;
        [self resetState];
        return;
    }

    BOOL bitsChanged = self.lastBitsController != bitsController;
    BOOL chatInputChanged = self.lastChatInputView != chatInputView;
    BOOL buttonChanged = self.lastChannelPointsButton != channelPointsButton;
    UIWindow *window = chatInputView.window;
    uintptr_t channelPointsStateAddress = 0;
    s7tv_channelPointsStateStorageForController(controller,
                                                &channelPointsStateAddress);
    id channelIdentity = s7tv_objectIvar(chatInputView, "channelIdentity");
    uintptr_t identityPointer = channelIdentity
        ? (uintptr_t)(__bridge void *)channelIdentity : 0;
    BOOL identityChanged = self.lastChannelIdentity != identityPointer;
    BOOL objectChanged = bitsChanged || chatInputChanged || buttonChanged ||
        identityChanged;

    BOOL diagnosticsContextChanged = self.diagnosticsHasContext &&
        (self.diagnosticsBitsController != bitsController ||
         self.diagnosticsChatInputView != chatInputView ||
         self.diagnosticsChannelPointsButton != channelPointsButton ||
         self.diagnosticsChannelPointsStateAddress != channelPointsStateAddress ||
         self.diagnosticsWindow != window ||
         self.diagnosticsChannelIdentity != identityPointer);
    if (diagnosticsContextChanged) {
        if (self.diagnosticsBitsController != bitsController) {
            s7tv_autoClaimLog(@"context changed: bitsController replaced — local state reset");
        }
        if (self.diagnosticsChatInputView != chatInputView) {
            s7tv_autoClaimLog(@"context changed: ChatInputView replaced — local state reset");
        }
        if (self.diagnosticsChannelPointsButton != channelPointsButton) {
            s7tv_autoClaimLog(@"context changed: channelPointsButton replaced — local state reset");
        }
        if (self.diagnosticsChannelPointsStateAddress !=
            channelPointsStateAddress) {
            s7tv_autoClaimLog(@"context changed: native Channel Points state replaced — local balance reset");
        }
        if (self.diagnosticsChannelIdentity != identityPointer) {
            s7tv_autoClaimLog(@"context changed: channel identity replaced — local state reset");
        }
        if (self.diagnosticsWindow != window) {
            s7tv_autoClaimLog(@"context changed: window replaced (now %@)",
                              window ? NSStringFromClass(window.class) : @"<nil>");
        }
        [self resetDiagnosticContext];
    }
    if (objectChanged) {
        self.lastBitsController = bitsController;
        self.lastChatInputView = chatInputView;
        self.lastChannelPointsButton = channelPointsButton;
        self.lastChannelIdentity = identityPointer;
        self.attemptLatched = NO;
        self.lastShowsClaim = NO;
    }

    self.diagnosticsBitsController = bitsController;
    self.diagnosticsChatInputView = chatInputView;
    self.diagnosticsChannelPointsButton = channelPointsButton;
    self.diagnosticsChannelPointsStateAddress = channelPointsStateAddress;
    self.diagnosticsWindow = window;
    self.diagnosticsChannelIdentity = identityPointer;
    self.diagnosticsHasContext = YES;

    [self observeChannelPointsBalanceForController:controller];

    Ivar showsClaimIvar = s7tv_ivarForObject(channelPointsButton, "showsClaim");
    if (!showsClaimIvar) {
        [self logFailureOnceWithKey:@"showsClaim:missing"
                            message:@"ivar showsClaim not found"];
        self.diagnosticsChainResolved = NO;
        [self resetState];
        return;
    }
    BOOL showsClaim = NO;
    if (!s7tv_readBoolIvar(channelPointsButton, "showsClaim", &showsClaim)) {
        [self logFailureOnceWithKey:@"showsClaim:unsafe"
                            message:@"unable to read showsClaim safely"];
        self.diagnosticsChainResolved = NO;
        [self resetState];
        return;
    }

    if (!self.diagnosticsChainResolved) {
        s7tv_autoClaimLog(
            @"native chain resolved successfully (controller=%@, bitsController=%@, chatInputView=%@, channelPointsButton=%@, window=%@)",
            NSStringFromClass(controller.class),
            NSStringFromClass(object_getClass(bitsController)),
            NSStringFromClass(chatInputView.class),
            NSStringFromClass(object_getClass(channelPointsButton)),
            window ? NSStringFromClass(window.class) : @"<nil>");
        if (window &&
            ([NSStringFromClass(window.class)
                 isEqualToString:@"Twitch.PictureInPictureWindow"] ||
             [NSStringFromClass(window.class)
                 isEqualToString:@"_TtC6Twitch22PictureInPictureWindow"])) {
            s7tv_autoClaimLog(
                @"ChatInputView belongs to PictureInPictureWindow (valid: owned by the currently tracked active ChannelChatViewController)");
        }
        self.diagnosticsChainResolved = YES;
        self.diagnosticsLastFailureKey = nil;
    }

    if (!self.diagnosticsHasObservedShowsClaim) {
        s7tv_autoClaimLog(@"showsClaim initial: %@", showsClaim ? @"YES" : @"NO");
        self.diagnosticsHasObservedShowsClaim = YES;
        self.diagnosticsLastShowsClaim = showsClaim;
        self.diagnosticsLastFailureKey = nil;
    } else if (self.diagnosticsLastShowsClaim != showsClaim) {
        s7tv_autoClaimLog(@"showsClaim: %@ → %@",
                          self.diagnosticsLastShowsClaim ? @"YES" : @"NO",
                          showsClaim ? @"YES" : @"NO");
        self.diagnosticsLastShowsClaim = showsClaim;
        self.diagnosticsLastFailureKey = nil;
    }

    if (!showsClaim) {
        if (self.attemptLatched && self.lastShowsClaim) {
            s7tv_autoClaimLog(
                @"claim UI state cleared after attempt — not a reliable network confirmation");
        }
        if (self.lastShowsClaim) {
            s7tv_autoClaimLog(@"latch reset after showsClaim YES → NO");
        }
        self.attemptLatched = NO;
        self.lastShowsClaim = NO;
        self.diagnosticsLatchBlockedLogged = NO;
        self.diagnosticsAttemptDate = nil;
        self.diagnosticsPostAttemptWarningLogged = NO;
        return;
    }

    self.lastShowsClaim = YES;
    if (self.attemptLatched) {
        if (!self.diagnosticsLatchBlockedLogged) {
            s7tv_autoClaimLog(
                @"attempt blocked: already sent for this showsClaim state (no second tap)");
            self.diagnosticsLatchBlockedLogged = YES;
        }
        if (!self.diagnosticsPostAttemptWarningLogged &&
            self.diagnosticsAttemptDate &&
            [[NSDate date] timeIntervalSinceDate:self.diagnosticsAttemptDate] >=
                kS7TVAutoClaimPostAttemptWarningDelay) {
            s7tv_autoClaimLog(
                @"warning: showsClaim still YES after native attempt — no second tap sent");
            self.diagnosticsPostAttemptWarningLogged = YES;
        }
        return;
    }

    SEL claimSelector = NSSelectorFromString(
        @"handleChannelPointsButtonTapped");
    if (![chatInputView respondsToSelector:claimSelector]) {
        [self logFailureOnceWithKey:@"selector-unavailable"
                            message:@"ChatInputView does not respond to handleChannelPointsButtonTapped"];
        return;
    }
    if ([self.diagnosticsLastFailureKey isEqualToString:@"selector-unavailable"]) {
        self.diagnosticsLastFailureKey = nil;
    }

    // Revalidate the controller-owned chain immediately before the native
    // call. All of this runs on the main thread, so no network lock is held.
    NSString *revalidationFailure = nil;
    BOOL controllerStillActive = s7tv_controllerIsActive(controller);
    UIView *revalidatedChatInput = controllerStillActive
        ? s7tv_chatInputViewForController(controller, &revalidationFailure)
        : nil;
    if (!controllerStillActive ||
        s7tv_objectIvar(controller, "bitsController") != bitsController ||
        revalidatedChatInput != chatInputView ||
        s7tv_objectIvar(chatInputView, "channelPointsButton") !=
            channelPointsButton) {
        NSString *failure = revalidationFailure.length
            ? revalidationFailure : @"native chain changed before attempt";
        [self logFailureOnceWithKey:[NSString stringWithFormat:@"revalidate:%@", failure]
                            message:failure];
        [self resetState];
        return;
    }

    s7tv_autoClaimLog(
        @"preflight OK: ChatInputView valid, selector available, showsClaim=YES, latch unused");
    self.attemptLatched = YES;
    s7tv_autoClaimLog(@"latch armed for this showsClaim state");
    self.diagnosticsLatchBlockedLogged = NO;
    self.diagnosticsAttemptDate = [NSDate date];
    self.diagnosticsPostAttemptWarningLogged = NO;
    s7tv_autoClaimLog(
        @"CLAIM ATTEMPT controller=%@ chatInputView=%@ channelPointsButton=%@ window=%@",
        NSStringFromClass(controller.class), NSStringFromClass(chatInputView.class),
        NSStringFromClass(object_getClass(channelPointsButton)),
        chatInputView.window ? NSStringFromClass(chatInputView.window.class) : @"<nil>");
    @try {
        ((void (*)(id, SEL))objc_msgSend)(chatInputView, claimSelector);
        s7tv_autoClaimLog(@"handleChannelPointsButtonTapped invoked");
    } @catch (NSException *exception) {
        s7tv_autoClaimLog(
            @"FAILED: handleChannelPointsButtonTapped raised an exception (%@)",
            exception.name ?: @"<unknown>");
    }
}

@end

static void s7tv_startAutoClaimForController(UIViewController *controller) {
    if (!s7tv_autoClaimEnabled()) {
        s7tv_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
        return;
    }
    if (!controller) {
        s7tv_autoClaimLog(@"watcher not started: no active ChannelChatViewController");
        s7tv_stopActiveAutoClaimWatcherWithReason(@"no active controller");
        return;
    }
    if (!s7tv_controllerIsActive(controller)) {
        NSString *reason = s7tv_controllerActivityFailureReason(controller, nil);
        s7tv_logAutoClaimControllerContext(controller,
                                           reason.length ? reason : @"controller inactive");
        s7tv_stopActiveAutoClaimWatcherWithReason(
            reason.length ? reason : @"controller inactive");
        return;
    }

    if (controller == s_s7tvActiveAutoClaimController &&
        s_s7tvActiveAutoClaimWatcher) {
        s7tv_autoClaimLog(@"watcher already exists for current controller — no duplication");
        [s_s7tvActiveAutoClaimWatcher tick];
        return;
    }

    if (s_s7tvActiveAutoClaimController &&
        s_s7tvActiveAutoClaimController != controller) {
        s7tv_autoClaimLog(
            @"context changed: ChannelChatViewController replaced — local state reset");
    }
    s7tv_stopActiveAutoClaimWatcherWithReason(@"controller replaced");
    S7TVAutoClaimWatcher *watcher =
        [[S7TVAutoClaimWatcher alloc] initWithController:controller];
    objc_setAssociatedObject(controller, &kS7TVAutoClaimWatcherAssociationKey,
                             watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s_s7tvActiveAutoClaimController = controller;
    s_s7tvActiveAutoClaimWatcher = watcher;
    s7tv_logAutoClaimControllerContext(controller,
                                       @"controller registered as active");
    s7tv_autoClaimLog(@"controller validation passed: active and visible");
    s7tv_autoClaimLog(@"watcher created for ChannelChatViewController");
    [watcher start];
}

static BOOL s7tv_hasOwnMethod(Class cls, SEL selector) {
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

static BOOL s7tv_installAutoClaimLifecycleOnClass(Class targetClass) {
    if (!targetClass) return NO;

    SEL appear = @selector(viewDidAppear:);
    SEL willDisappear = @selector(viewWillDisappear:);
    SEL didDisappear = @selector(viewDidDisappear:);
    SEL swizzledAppear = @selector(s7tv_autoclaim_viewDidAppear:);
    SEL swizzledWillDisappear = @selector(s7tv_autoclaim_viewWillDisappear:);
    SEL swizzledDidDisappear = @selector(s7tv_autoclaim_viewDidDisappear:);
    SEL originals[] = {appear, willDisappear, didDisappear};
    SEL replacements[] = {swizzledAppear, swizzledWillDisappear,
                          swizzledDidDisappear};

    for (NSUInteger index = 0; index < 3; index++) {
        if (s7tv_hasOwnMethod(targetClass, replacements[index])) continue;

        Method originalMethod = class_getInstanceMethod(targetClass,
                                                         originals[index]);
        Method replacementMethod = class_getInstanceMethod(
            [UIViewController class], replacements[index]);
        if (!originalMethod || !replacementMethod) return NO;

        if (!s7tv_hasOwnMethod(targetClass, originals[index])) {
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
    return YES;
}

static void s7tv_installAutoClaimLifecycleHooks(void) {
    NSArray<NSString *> *classNames = @[
        @"Twitch.ChannelChatViewController",
        @"_TtC6Twitch25ChannelChatViewController",
    ];
    for (NSString *className in classNames) {
        Class targetClass = NSClassFromString(className);
        if (targetClass) s7tv_installAutoClaimLifecycleOnClass(targetClass);
    }
}

@interface UIViewController (S7TVAutoClaimLifecycle)
- (void)s7tv_autoclaim_viewDidAppear:(BOOL)animated;
- (void)s7tv_autoclaim_viewWillDisappear:(BOOL)animated;
- (void)s7tv_autoclaim_viewDidDisappear:(BOOL)animated;
@end

@implementation UIViewController (S7TVAutoClaimLifecycle)

- (void)s7tv_autoclaim_viewDidAppear:(BOOL)animated {
    [self s7tv_autoclaim_viewDidAppear:animated];
    if (s7tv_isChannelChatViewController(self)) {
        s7tv_logAutoClaimControllerContext(self, @"controller viewDidAppear detected");
        s7tv_startAutoClaimForController(self);
    }
}

- (void)s7tv_autoclaim_viewWillDisappear:(BOOL)animated {
    if (s7tv_isChannelChatViewController(self)) {
        s7tv_autoClaimLog(@"controller viewWillDisappear: %@",
                          NSStringFromClass(self.class));
        if (self == s_s7tvActiveAutoClaimController) {
            s7tv_stopActiveAutoClaimWatcherWithReason(@"viewWillDisappear");
        }
    }
    [self s7tv_autoclaim_viewWillDisappear:animated];
}

- (void)s7tv_autoclaim_viewDidDisappear:(BOOL)animated {
    if (s7tv_isChannelChatViewController(self)) {
        s7tv_autoClaimLog(@"controller viewDidDisappear: %@",
                          NSStringFromClass(self.class));
        if (self == s_s7tvActiveAutoClaimController) {
            s7tv_stopActiveAutoClaimWatcherWithReason(@"viewDidDisappear");
        }
    }
    [self s7tv_autoclaim_viewDidDisappear:animated];
}

@end

static id s_s7tvAutoClaimWillResignObserver;
static id s_s7tvAutoClaimDidBecomeObserver;

static void s7tv_registerAutoClaimApplicationObservers(void) {
    if (s_s7tvAutoClaimWillResignObserver ||
        s_s7tvAutoClaimDidBecomeObserver) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    s_s7tvAutoClaimWillResignObserver =
        [center addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
        s7tv_autoClaimLog(@"application background");
        s7tv_autoClaimLog(@"watcher suspended: application background");
        s7tv_stopActiveAutoClaimWatcherWithReason(@"application background");
    }];
    s_s7tvAutoClaimDidBecomeObserver =
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
        s7tv_autoClaimLog(@"application foreground");
        s7tv_installAutoClaimLifecycleHooks();
        if (s7tv_autoClaimEnabled()) {
            UIViewController *controller =
                s7tv_findActiveChannelChatViewController();
            if (controller) {
                s7tv_autoClaimLog(@"foreground: watcher resumed/recreated for active controller");
            } else {
                s7tv_autoClaimLog(
                    @"foreground: watcher not recreated — no active controller");
            }
            s7tv_startAutoClaimForController(controller);
        } else {
            s7tv_autoClaimLog(@"foreground: watcher not recreated because Auto Collect is OFF");
        }
    }];
}

static void s7tv_setupAutoClaimOnMain(void) {
    s7tv_installAutoClaimLifecycleHooks();
    s7tv_registerAutoClaimApplicationObservers();
    if (s7tv_autoClaimEnabled()) {
        s7tv_startAutoClaimForController(
            s7tv_findActiveChannelChatViewController());
    } else {
        s7tv_stopActiveAutoClaimWatcherWithReason(@"setting OFF");
    }
}

void S7TVAutoClaimSetup(void) {
    if ([NSThread isMainThread]) {
        s7tv_setupAutoClaimOnMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_setupAutoClaimOnMain();
        });
    }
}

void S7TVAutoClaimSettingsDidChange(void) {
    if ([NSThread isMainThread]) {
        BOOL enabled = s7tv_autoClaimEnabled();
        s7tv_autoClaimLog(@"toggle Auto Collect: %@", enabled ? @"ON" : @"OFF");
        s7tv_setupAutoClaimOnMain();
        if (enabled) {
            s7tv_autoClaimLog(
                @"toggle ON: %@",
                s_s7tvActiveAutoClaimWatcher
                    ? @"watcher active immediately"
                    : @"watcher not started — no active controller available");
        } else {
            s7tv_autoClaimLog(@"toggle OFF: watcher stopped");
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL enabled = s7tv_autoClaimEnabled();
            s7tv_autoClaimLog(@"toggle Auto Collect: %@", enabled ? @"ON" : @"OFF");
            s7tv_setupAutoClaimOnMain();
            if (enabled) {
                s7tv_autoClaimLog(
                    @"toggle ON: %@",
                    s_s7tvActiveAutoClaimWatcher
                        ? @"watcher active immediately"
                        : @"watcher not started — no active controller available");
            } else {
                s7tv_autoClaimLog(@"toggle OFF: watcher stopped");
            }
        });
    }
}
