#import "Adblock/tpK-adblock-runtime.h"
#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/Proxy/tpK-adblock-resource-loader.h"
#import "Adblock/Combo/tpK-adblock-combo.h"
#import "Adblock/Emote/tpK-adblock-emote-proxy.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Vaft/tpK-adblock-vaft.h"
#import "Adblock/Proxy/Fishhook/fishhook.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

static void TPKAdblockRemoveAdControllers(void *pointer) {
    if (!pointer || (((uintptr_t)pointer & 0xFFFF800000000000) != 0)) return;
    id object = (__bridge id)pointer;
    Ivar theaterIvar = class_getInstanceVariable(object_getClass(object),
                                                  "theaterAdController");
    if (!theaterIvar) return;

    if (!TPKAdblockActiveMethodUsesProxy() || !TPKAdblockEnabledFast()) return;
    id theaterController = object_getIvar(object, theaterIvar);
    if (!theaterController) return;
    const char *names[] = {
        "displayAdController", "streamDisplayAdStateManager", "vastAdController"
    };
    for (NSUInteger index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        Ivar ivar = class_getInstanceVariable(object_getClass(theaterController), names[index]);
        if (ivar) object_setIvar(theaterController, ivar, nil);
    }
}

static void *(*TPKAdblockOriginalWeakAssign)(void *, void *);
static void *TPKAdblockWeakAssign(void *reference, void *value) {
    void *result = TPKAdblockOriginalWeakAssign(reference, value);
    TPKAdblockRemoveAdControllers(value);
    return result;
}

static void *(*TPKAdblockOriginalWeakLoadStrong)(void *);
static void *TPKAdblockWeakLoadStrong(void *reference) {
    void *result = TPKAdblockOriginalWeakLoadStrong(reference);
    TPKAdblockRemoveAdControllers(result);
    return result;
}

static void TPKAdblockInstallSwiftRuntimeRebindings(void) {
    struct rebinding rebindings[] = {
        {"swift_unknownObjectWeakAssign", (void *)TPKAdblockWeakAssign,
            (void **)&TPKAdblockOriginalWeakAssign},
        {"swift_unknownObjectWeakLoadStrong", (void *)TPKAdblockWeakLoadStrong,
            (void **)&TPKAdblockOriginalWeakLoadStrong},
    };
    int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    os_log(OS_LOG_DEFAULT, "[TPK-Adblock] Swift ad-controller hooks installed=%d",
           result == 0);
}

static BOOL TPKAdblockExchangeInstanceMethod(Class target, Class source,
                                               SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(target, original);
    Method replacementMethod = class_getInstanceMethod(source, replacement);
    if (!originalMethod || !replacementMethod) return NO;
    class_addMethod(target, original, method_getImplementation(originalMethod),
                    method_getTypeEncoding(originalMethod));
    class_addMethod(target, replacement, method_getImplementation(replacementMethod),
                    method_getTypeEncoding(replacementMethod));
    Method concreteOriginal = class_getInstanceMethod(target, original);
    Method concreteReplacement = class_getInstanceMethod(target, replacement);
    if (!concreteOriginal || !concreteReplacement) return NO;
    method_exchangeImplementations(concreteOriginal, concreteReplacement);
    return YES;
}

static BOOL TPKAdblockViewIsInTurboPurchaseScreen(UIView *view) {
    Class purchaseClass = objc_getClass("_TtC6Twitch25TurboUpsellViewController");
    if (!purchaseClass) return NO;
    for (UIResponder *responder = view.nextResponder;
         responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:purchaseClass]) return YES;
    }
    return NO;
}

static BOOL TPKAdblockStringContains(NSString *string, NSString *needle) {
    return string && [string rangeOfString:needle
                                  options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *TPKAdblockVisibleViewText(UIView *view) {
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) {
        return ((UILabel *)view).text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (button.currentTitle.length) return button.currentTitle;
        if (button.currentAttributedTitle.string.length) {
            return button.currentAttributedTitle.string;
        }
    }
    return view.accessibilityLabel.length ? view.accessibilityLabel : nil;
}

static BOOL TPKAdblockIsAdFreeText(NSString *text) {
    return TPKAdblockStringContains(text, @"Ad-Free") ||
           TPKAdblockStringContains(text, @"Ad Free") ||
           TPKAdblockStringContains(text, @"Sans publicité") ||
           TPKAdblockStringContains(text, @"Sans publicite");
}

static char TPKAdblockAdFreeViewHiddenKey;

static void TPKAdblockHideAdFreeView(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &TPKAdblockAdFreeViewHiddenKey) ||
        TPKAdblockViewIsInTurboPurchaseScreen(view)) return;
    objc_setAssociatedObject(view, &TPKAdblockAdFreeViewHiddenKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = YES;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *width = [view.widthAnchor constraintEqualToConstant:0.0];
    NSLayoutConstraint *height = [view.heightAnchor constraintEqualToConstant:0.0];
    width.priority = height.priority = (UILayoutPriority)999;
    width.active = height.active = YES;
}

@interface TPKTurboScanState : NSObject
@property (nonatomic, weak) UIView *root;
@property (nonatomic, strong) NSPointerArray *pending;
@property (nonatomic) NSUInteger cursor;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL queued;
@property (nonatomic) BOOL changedWhileScanning;
@end

@implementation TPKTurboScanState
@end

static char TPKTurboScanStateKey;

static void TPKAdblockRunTurboScan(TPKTurboScanState *state) {
    UIView *root = state.root;
    if (!TPKAdblockHideAdFreeButtonEnabledFast() || !root.window ||
        root.window.hidden || root.hidden || root.alpha <= 0) {
        state.pending = nil;
        state.cursor = 0;
        state.queued = NO;
        return;
    }
    if (!state.pending) {
        state.pending = NSPointerArray.weakObjectsPointerArray;
        [state.pending addPointer:(__bridge void *)root];
        state.startedAt = NSProcessInfo.processInfo.systemUptime;
        state.changedWhileScanning = NO;
    }
    // Borner chaque passage et laisser la file principale traiter les images entre les lots.
    for (NSUInteger visited = 0; visited < 256 && state.cursor < state.pending.count; visited++) {
        UIView *view = (__bridge UIView *)[state.pending pointerAtIndex:state.cursor++];
        if (!view || view.hidden || view.alpha <= 0 || ![view isDescendantOfView:root]) continue;
        NSString *className = NSStringFromClass(view.class);
        BOOL matchingText = [view isKindOfClass:UIControl.class] &&
            TPKAdblockIsAdFreeText(TPKAdblockVisibleViewText(view));
        if (TPKAdblockStringContains(className, @"Upsell") ||
            TPKAdblockStringContains(className, @"AdFree") || matchingText) {
            TPKAdblockHideAdFreeView(view);
            continue;
        }
        for (UIView *child in view.subviews) [state.pending addPointer:(__bridge void *)child];
    }
    if (state.cursor < state.pending.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ TPKAdblockRunTurboScan(state); });
        return;
    }
    state.pending = nil;
    state.cursor = 0;
    state.queued = NO;
    if (state.changedWhileScanning) TPKAdblockHideAdFreeUpsellIfNeeded(root);
}

void TPKAdblockHideAdFreeUpsellIfNeeded(UIView *root) {
    if (!TPKAdblockHideAdFreeButtonEnabledFast() || !root.window || root.hidden || root.alpha <= 0) return;
    TPKTurboScanState *state = objc_getAssociatedObject(root, &TPKTurboScanStateKey);
    if (!state) {
        state = [TPKTurboScanState new];
        state.root = root;
        objc_setAssociatedObject(root, &TPKTurboScanStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.queued) {
        if (state.pending) state.changedWhileScanning = YES;
        return;
    }
    state.queued = YES;
    NSTimeInterval delay = MAX(0, 0.5 - (NSProcessInfo.processInfo.systemUptime - state.startedAt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TPKAdblockRunTurboScan(state); });
}

@interface AVURLAsset (TPKAdblockRuntime)
- (instancetype)tpk_adblock_initWithURL:(NSURL *)URL
                                 options:(NSDictionary<NSString *, id> *)options;
@end

@implementation AVURLAsset (TPKAdblockRuntime)

- (instancetype)tpk_adblock_initWithURL:(NSURL *)URL
                                 options:(NSDictionary<NSString *, id> *)options {
    if (!TPKAdblockIsEnabled() || !TPKAdblockProxyIsEnabled() ||
        ![URL.scheme isEqualToString:@"https"] ||
        !TPKAdblockIsPlaylistHost(URL.host) ||
        TPKAdblockUserIsAdExempt(URL.query) || TPKAdblockIsExternalPlayback()) {
        return [self tpk_adblock_initWithURL:URL options:options];
    }

    if (TPKAdblockIsMasterPlaylistHost(URL.host)) {
        NSArray<NSString *> *proxyAddresses =
            TPKAdblockActiveMethod() == TPKAdblockMethodProxyPlusLocal
                ? TPKAdblockComboProxyEffectiveAddresses()
                : TPKAdblockEffectiveProxyAddresses();
        for (NSString *address in proxyAddresses) {
            NSURL *proxyURL = TPKAdblockNormalizedProxyURL(address);
            if (!proxyURL) continue;
            NSURL *rewritten = TPKAdblockRewriteURLThroughProxy(URL, proxyURL);
            if ([rewritten isEqual:URL]) continue;
            NSString *authorization = TPKAdblockBasicAuthHeader(proxyURL);
            if (authorization.length) {
                NSMutableDictionary *newOptions = options.mutableCopy
                    ?: [NSMutableDictionary dictionary];
                NSMutableDictionary *headers =
                    [newOptions[@"AVURLAssetHTTPHeaderFieldsKey"] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
                headers[@"Authorization"] = authorization;
                newOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = headers;
                options = newOptions.copy;
            }
            return [self tpk_adblock_initWithURL:rewritten options:options];
        }
    }

    // En mode combiné, seul le manifeste maître passe par le proxy.
    if (TPKAdblockActiveMethod() != TPKAdblockMethodProxy) {
        return [self tpk_adblock_initWithURL:URL options:options];
    }
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:URL resolvingAgainstBaseURL:YES];
    components.scheme = @"tpk-adblock";
    AVURLAsset *asset = [self tpk_adblock_initWithURL:components.URL options:options];
    [asset.resourceLoader setDelegate:TPKAdblockResourceLoader.sharedLoader
        queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
    return asset;
}

@end

static char TPKAdblockPlayerStatusContext;

@interface AVPlayer (TPKAdblockPlayback)
- (instancetype)tpk_adblock_init;
- (void)tpk_adblock_observeValueForKeyPath:(NSString *)keyPath
                                   ofObject:(id)object
                                     change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                                    context:(void *)context;
@end

@implementation AVPlayer (TPKAdblockPlayback)

- (instancetype)tpk_adblock_init {
    AVPlayer *player = [self tpk_adblock_init];

    if (TPKAdblockActiveMethod() != TPKAdblockMethodProxy) {
        [player addObserver:player forKeyPath:@"status"
            options:NSKeyValueObservingOptionNew context:&TPKAdblockPlayerStatusContext];
    }
    return player;
}

- (void)tpk_adblock_observeValueForKeyPath:(NSString *)keyPath
                                   ofObject:(id)object
                                     change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                                    context:(void *)context {
    if (context == &TPKAdblockPlayerStatusContext &&
        [keyPath isEqualToString:@"status"] && TPKAdblockIsEnabled() &&
        [change[NSKeyValueChangeNewKey] integerValue] == AVPlayerStatusReadyToPlay) {
        [self play];
        return;
    }
    [self tpk_adblock_observeValueForKeyPath:keyPath ofObject:object
        change:change context:context];
}

@end

@interface NSObject (TPKAdblockTwitchResourceLoader)
- (void)tpk_adblock_URLSession:(NSURLSession *)session
                       dataTask:(NSURLSessionDataTask *)dataTask
                 didReceiveData:(NSData *)data;
- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager;
- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController;
- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController isInitialTab:(BOOL)isInitialTab;
+ (instancetype)tpk_adblock_shared;
- (void)tpk_adblock_standardButtonDidMoveToWindow;
- (void)tpk_adblock_standardButtonLayoutSubviews;
- (void)tpk_adblock_followingViewDidLayoutSubviews;
@end

@implementation NSObject (TPKAdblockTwitchResourceLoader)

- (void)tpk_adblock_URLSession:(NSURLSession *)session
                       dataTask:(NSURLSessionDataTask *)dataTask
                 didReceiveData:(NSData *)data {
    NSURLRequest *request = dataTask.currentRequest ?: dataTask.originalRequest;
    NSData *filtered = TPKAdblockTransformResponseDataForTransport(
        data, request, NSStringFromClass([self class]));
    [self tpk_adblock_URLSession:session dataTask:dataTask didReceiveData:filtered];
}

static void TPKAdblockClearFollowingAds(id object) {
    Ivar headliner = class_getInstanceVariable(object_getClass(object), "headlinerManager");
    if (!headliner) return;
    Ivar displayState = class_getInstanceVariable(object_getClass(object),
                                                   "displayAdStateManager");
    if (displayState) object_setIvar(object, displayState, nil);
}

- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager {
    id object = [self tpk_adblock_initWithGraphQL:graphQL themeManager:themeManager];
    if (!TPKAdblockActiveMethodUsesProxy() || !TPKAdblockEnabledFast()) TPKAdblockClearFollowingAds(object);
    return object;
}

- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController {
    id object = [self tpk_adblock_initWithGraphQL:graphQL themeManager:themeManager
                                     urlController:urlController];
    if (!TPKAdblockActiveMethodUsesProxy() || !TPKAdblockEnabledFast()) TPKAdblockClearFollowingAds(object);
    return object;
}

- (instancetype)tpk_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController isInitialTab:(BOOL)isInitialTab {
    id object = [self tpk_adblock_initWithGraphQL:graphQL themeManager:themeManager
        urlController:urlController isInitialTab:isInitialTab];
    if (!TPKAdblockActiveMethodUsesProxy() || !TPKAdblockEnabledFast()) TPKAdblockClearFollowingAds(object);
    return object;
}

+ (instancetype)tpk_adblock_shared {
    id shared = [self tpk_adblock_shared];
    if (!TPKAdblockActiveMethodUsesProxy() || !TPKAdblockEnabledFast() || !shared) return shared;
    Ivar displayState = class_getInstanceVariable(object_getClass(shared),
                                                   "displayAdStateManager");
    if (displayState) object_setIvar(shared, displayState, nil);
    return shared;
}

- (void)tpk_adblock_standardButtonDidMoveToWindow {
    [self tpk_adblock_standardButtonDidMoveToWindow];
    if (!TPKAdblockHideAdFreeButtonEnabledFast()) return;
    UIView *button = (UIView *)self;
    if (TPKAdblockIsAdFreeText(TPKAdblockVisibleViewText(button))) {
        TPKAdblockHideAdFreeView(button);
    }
}

- (void)tpk_adblock_standardButtonLayoutSubviews {
    [self tpk_adblock_standardButtonLayoutSubviews];
    if (!TPKAdblockHideAdFreeButtonEnabledFast()) return;
    UIView *button = (UIView *)self;
    if (TPKAdblockIsAdFreeText(TPKAdblockVisibleViewText(button))) {
        TPKAdblockHideAdFreeView(button);
    }
}

- (void)tpk_adblock_followingViewDidLayoutSubviews {
    [self tpk_adblock_followingViewDidLayoutSubviews];
    TPKAdblockHideAdFreeUpsellIfNeeded(((UIViewController *)self).viewIfLoaded);
}

@end

static BOOL TPKAdblockLegacyGQLInstalled = NO;
static BOOL TPKAdblockRNGQLInstalled = NO;
static BOOL TPKAdblockFollowingInstalled = NO;
static BOOL TPKAdblockHeadlinerInstalled = NO;
static BOOL TPKAdblockStandardButtonDidMoveInstalled = NO;
static BOOL TPKAdblockStandardButtonLayoutInstalled = NO;
static BOOL TPKAdblockFollowingLayoutInstalled = NO;

static void TPKAdblockTryInstallLateHooks(void) {

    BOOL proxyMode = TPKAdblockActiveMethodUsesProxy();
    @synchronized (TPKAdblockResourceLoader.class) {

        if (!TPKAdblockLegacyGQLInstalled) {
            Class legacyClient = NSClassFromString(@"_TtC9TwitchKit18TKURLSessionClient");
            if (legacyClient) {
                TPKAdblockLegacyGQLInstalled = TPKAdblockExchangeInstanceMethod(
                    legacyClient, NSObject.class,
                    @selector(URLSession:dataTask:didReceiveData:),
                    @selector(tpk_adblock_URLSession:dataTask:didReceiveData:));
            }
        }

        if (!TPKAdblockRNGQLInstalled) {
            Class reactClient = NSClassFromString(@"RCTHTTPRequestHandler");
            if (reactClient) {
                TPKAdblockRNGQLInstalled = TPKAdblockExchangeInstanceMethod(
                    reactClient, NSObject.class,
                    @selector(URLSession:dataTask:didReceiveData:),
                    @selector(tpk_adblock_URLSession:dataTask:didReceiveData:));
            }
        }
        if (proxyMode && !TPKAdblockFollowingInstalled) {
            Class following = NSClassFromString(@"_TtC6Twitch23FollowingViewController");
            if (following) {
                BOOL two = TPKAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:"),
                    @selector(tpk_adblock_initWithGraphQL:themeManager:));
                BOOL three = TPKAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:urlController:"),
                    @selector(tpk_adblock_initWithGraphQL:themeManager:urlController:));
                BOOL four = TPKAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:urlController:isInitialTab:"),
                    @selector(tpk_adblock_initWithGraphQL:themeManager:urlController:isInitialTab:));
                TPKAdblockFollowingInstalled = two || three || four;
            }
        }
        if (proxyMode && !TPKAdblockHeadlinerInstalled) {
            Class headliner = NSClassFromString(@"_TtC6Twitch27HeadlinerFollowingAdManager");
            if (headliner) {
                TPKAdblockHeadlinerInstalled = TPKAdblockExchangeInstanceMethod(
                    object_getClass(headliner), object_getClass(NSObject.class),
                    @selector(shared), @selector(tpk_adblock_shared));
            }
        }

        if (!TPKAdblockStandardButtonDidMoveInstalled ||
            !TPKAdblockStandardButtonLayoutInstalled) {
            Class standardButton = NSClassFromString(
                @"_TtC12TwitchCoreUI14StandardButton");
            if (standardButton) {
                if (!TPKAdblockStandardButtonDidMoveInstalled) {
                    TPKAdblockStandardButtonDidMoveInstalled =
                        TPKAdblockExchangeInstanceMethod(standardButton, NSObject.class,
                            @selector(didMoveToWindow),
                            @selector(tpk_adblock_standardButtonDidMoveToWindow));
                }
                if (!TPKAdblockStandardButtonLayoutInstalled) {
                    TPKAdblockStandardButtonLayoutInstalled =
                        TPKAdblockExchangeInstanceMethod(standardButton, NSObject.class,
                            @selector(layoutSubviews),
                            @selector(tpk_adblock_standardButtonLayoutSubviews));
                }
            }
        }

        if (!TPKAdblockFollowingLayoutInstalled) {
            Class following = NSClassFromString(@"_TtC6Twitch23FollowingViewController");
            if (following) {
                TPKAdblockFollowingLayoutInstalled =
                    TPKAdblockExchangeInstanceMethod(following, NSObject.class,
                        @selector(viewDidLayoutSubviews),
                        @selector(tpk_adblock_followingViewDidLayoutSubviews));
            }
        }
    }
}

void TPKAdblockInstallRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TPKAdblockRegisterDefaults();
        TPKAdblockRefreshRuntimeSnapshots();

        // La méthode reste figée jusqu'au prochain lancement.
        TPKAdblockTakeRuntimeMethodSnapshot();
        BOOL proxyMode = TPKAdblockActiveMethodUsesProxy();

        os_log(OS_LOG_DEFAULT, "[TPK-Adblock] Active method: %{public}s",
               (TPKAdblockActiveMethod() == TPKAdblockMethodLocalVaft ? "local" :
                TPKAdblockActiveMethod() == TPKAdblockMethodProxyPlusLocal ? "combo" :
                TPKAdblockActiveMethod() == TPKAdblockMethodDisabled ? "disabled" : "proxy"));

        if (proxyMode) {

            TPKAdblockInstallSwiftRuntimeRebindings();
            BOOL assetHook = TPKAdblockExchangeInstanceMethod(AVURLAsset.class,
                AVURLAsset.class, @selector(initWithURL:options:),
                @selector(tpk_adblock_initWithURL:options:));
            BOOL playerInitHook = TPKAdblockExchangeInstanceMethod(AVPlayer.class,
                AVPlayer.class, @selector(init), @selector(tpk_adblock_init));
            BOOL playerKVOHook = TPKAdblockExchangeInstanceMethod(AVPlayer.class,
                AVPlayer.class, @selector(observeValueForKeyPath:ofObject:change:context:),
                @selector(tpk_adblock_observeValueForKeyPath:ofObject:change:context:));
            os_log(OS_LOG_DEFAULT, "[TPK-Adblock] AVURLAsset hook installed=%d", assetHook);
            os_log(OS_LOG_DEFAULT, "[TPK-Adblock] AVPlayer hooks installed=%d/%d",
                   playerInitHook, playerKVOHook);
        }
        if (TPKAdblockActiveMethodUsesLocal()) {

            vaft_initialize();
        }

        TPKAdblockTryInstallLateHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ TPKAdblockTryInstallLateHooks(); });
        }

        // Préchauffer la détection après établissement du réseau.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSMutableArray<NSString *> *addresses = [NSMutableArray array];
            if (TPKEmoteProxyIsEnabled()) {
                [addresses addObjectsFromArray:TPKEmoteProxyEffectiveAddresses()];
            }
            if (TPKAdblockActiveMethod() == TPKAdblockMethodProxyPlusLocal) {
                [addresses addObjectsFromArray:TPKAdblockComboProxyEffectiveAddresses()];
            } else if (TPKAdblockActiveMethod() == TPKAdblockMethodProxy) {
                [addresses addObjectsFromArray:TPKAdblockEffectiveProxyAddresses()];
            }
            for (NSString *address in addresses) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    NSURL *proxyURL = TPKAdblockNormalizedProxyURL(address);
                    if (proxyURL) TPKAdblockProxyIsPrefixStyle(proxyURL);
                });
            }
        });
    });
}
