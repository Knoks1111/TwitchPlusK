/*
 * Runtime integration for the TwitchAdBlock-derived proxy engine.
 * Original project: https://github.com/gunnerkidBT/TwitchAdBlock (MIT).
 */

#import "Adblock/tpK-adblock-runtime.h"
#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/Proxy/tpK-adblock-resource-loader.h"
#import "Adblock/Combo/tpK-adblock-combo.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Vaft/tpK-adblock-vaft.h"
#import "Adblock/Proxy/Fishhook/fishhook.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

// TwitchAdBlock's client-side half: Twitch stores the display/VAST managers
// behind Swift weak references. Rebinding these two runtime functions lets us
// clear those managers whenever the surrounding theater controller is seen.
static void TPKAdblockRemoveAdControllers(void *pointer) {
    if (!pointer || (((uintptr_t)pointer & 0xFFFF800000000000) != 0)) return;
    id object = (__bridge id)pointer;
    Ivar theaterIvar = class_getInstanceVariable(object_getClass(object),
                                                  "theaterAdController");
    if (!theaterIvar) return;
    // Moteur Proxy uniquement + snapshots O(1) (fix perf PR #2).
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

// « Go Ad-Free » est une promotion Twitch Turbo dans l'en-tête Live Now de
// l'onglet Following. Ce bloc vient de TwitchAdBlock v0.1.13 : il cible le
// contrôle par son texte/classe, tout en protégeant l'écran d'achat Turbo.
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

static void TPKAdblockScanForAdFreeView(UIView *root) {
    if (!root) return;
    NSString *className = NSStringFromClass(root.class);
    BOOL matchingControlText = [root isKindOfClass:UIControl.class] &&
        TPKAdblockIsAdFreeText(TPKAdblockVisibleViewText(root));
    if ((TPKAdblockStringContains(className, @"Upsell") ||
         TPKAdblockStringContains(className, @"AdFree") ||
         matchingControlText) && !root.hidden) {
        TPKAdblockHideAdFreeView(root);
        return;
    }
    for (UIView *subview in root.subviews.copy) {
        TPKAdblockScanForAdFreeView(subview);
    }
}

void TPKAdblockHideAdFreeUpsellIfNeeded(void) {
    if (!TPKAdblockHideAdFreeButtonEnabledFast()) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows.copy) {
        TPKAdblockScanForAdFreeView(window);
    }
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

    // Combo : VAFT possède les variantes/segments (décisions anti-pub
    // locales). Le proxy ne réécrit que la master pour l'accès.
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
    // Transport combo = VAFT : même observer qu'en Local.
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
    NSData *filtered = TPKAdblockTransformResponseData(data, request);
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
    TPKAdblockHideAdFreeUpsellIfNeeded();
}

@end

static BOOL TPKAdblockLegacyGQLInstalled = NO;
static BOOL TPKAdblockFollowingInstalled = NO;
static BOOL TPKAdblockHeadlinerInstalled = NO;
static BOOL TPKAdblockStandardButtonDidMoveInstalled = NO;
static BOOL TPKAdblockStandardButtonLayoutInstalled = NO;
static BOOL TPKAdblockFollowingLayoutInstalled = NO;

static void TPKAdblockTryInstallLateHooks(void) {
    // Méthode active = snapshot figé au lancement (jamais la préférence).
    BOOL proxyMode = TPKAdblockActiveMethodUsesProxy();
    @synchronized (TPKAdblockResourceLoader.class) {
        // Commun : sert keepLiveFeedPlaying (les deux modes) et le filtrage
        // GQL du Proxy (gated par méthode dans Transform*).
        if (!TPKAdblockLegacyGQLInstalled) {
            Class legacyClient = NSClassFromString(@"_TtC9TwitchKit18TKURLSessionClient");
            if (legacyClient) {
                TPKAdblockLegacyGQLInstalled = TPKAdblockExchangeInstanceMethod(
                    legacyClient, NSObject.class,
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
        // Commun : masquage Turbo upsell (réglage indépendant des moteurs).
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
        // Commun : point d'appel du scan Turbo upsell.
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
        // Snapshot de la méthode ACTIVE : une seule lecture au lancement,
        // avant toute installation ; figé jusqu'à la fin du processus.
        TPKAdblockTakeRuntimeMethodSnapshot();
        BOOL proxyMode = TPKAdblockActiveMethodUsesProxy();

        os_log(OS_LOG_DEFAULT, "[TPK-Adblock] Active method: %{public}s",
               (TPKAdblockActiveMethod() == TPKAdblockMethodLocalVaft ? "local" :
                TPKAdblockActiveMethod() == TPKAdblockMethodProxyPlusLocal ? "combo" :
                TPKAdblockActiveMethod() == TPKAdblockMethodDisabled ? "disabled" : "proxy"));

        if (proxyMode) {
            // ── Moteur Proxy : comportement existant inchangé ──────────
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
            // ── Moteur Local (VAFT) : upstream adapté (divergence D1/D3) ──
            vaft_initialize();
        }

        TPKAdblockTryInstallLateHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ TPKAdblockTryInstallLateHooks(); });
        }
    });
}
