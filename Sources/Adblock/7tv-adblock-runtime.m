/*
 * Runtime integration for the TwitchAdBlock-derived proxy engine.
 * Original project: https://github.com/gunnerkidBT/TwitchAdBlock (MIT).
 */

#import "Adblock/7tv-adblock-runtime.h"
#import "Adblock/7tv-adblock-data.h"
#import "Adblock/7tv-adblock-proxy.h"
#import "Adblock/7tv-adblock-resource-loader.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Adblock/Fishhook/fishhook.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <os/log.h>

// TwitchAdBlock's client-side half: Twitch stores the display/VAST managers
// behind Swift weak references. Rebinding these two runtime functions lets us
// clear those managers whenever the surrounding theater controller is seen.
static void S7TVAdblockRemoveAdControllers(void *pointer) {
    if (!pointer || (((uintptr_t)pointer & 0xFFFF800000000000) != 0)) return;
    id object = (__bridge id)pointer;
    Ivar theaterIvar = class_getInstanceVariable(object_getClass(object),
                                                  "theaterAdController");
    if (!theaterIvar) return;
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

static void *(*S7TVAdblockOriginalWeakAssign)(void *, void *);
static void *S7TVAdblockWeakAssign(void *reference, void *value) {
    void *result = S7TVAdblockOriginalWeakAssign(reference, value);
    if (S7TVAdblockIsEnabled()) S7TVAdblockRemoveAdControllers(value);
    return result;
}

static void *(*S7TVAdblockOriginalWeakLoadStrong)(void *);
static void *S7TVAdblockWeakLoadStrong(void *reference) {
    void *result = S7TVAdblockOriginalWeakLoadStrong(reference);
    if (S7TVAdblockIsEnabled()) S7TVAdblockRemoveAdControllers(result);
    return result;
}

static void S7TVAdblockInstallSwiftRuntimeRebindings(void) {
    struct rebinding rebindings[] = {
        {"swift_unknownObjectWeakAssign", (void *)S7TVAdblockWeakAssign,
            (void **)&S7TVAdblockOriginalWeakAssign},
        {"swift_unknownObjectWeakLoadStrong", (void *)S7TVAdblockWeakLoadStrong,
            (void **)&S7TVAdblockOriginalWeakLoadStrong},
    };
    int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    os_log(OS_LOG_DEFAULT, "[S7TV-Adblock] Swift ad-controller hooks installed=%d",
           result == 0);
}

static BOOL S7TVAdblockExchangeInstanceMethod(Class target, Class source,
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

@interface AVURLAsset (S7TVAdblockRuntime)
- (instancetype)s7tv_adblock_initWithURL:(NSURL *)URL
                                 options:(NSDictionary<NSString *, id> *)options;
@end

@implementation AVURLAsset (S7TVAdblockRuntime)

- (instancetype)s7tv_adblock_initWithURL:(NSURL *)URL
                                 options:(NSDictionary<NSString *, id> *)options {
    if (!S7TVAdblockIsEnabled() || !S7TVAdblockProxyIsEnabled() ||
        ![URL.scheme isEqualToString:@"https"] ||
        !S7TVAdblockIsPlaylistHost(URL.host) ||
        S7TVAdblockUserIsAdExempt(URL.query) || S7TVAdblockIsExternalPlayback()) {
        return [self s7tv_adblock_initWithURL:URL options:options];
    }

    if (S7TVAdblockIsMasterPlaylistHost(URL.host)) {
        for (NSString *address in S7TVAdblockEffectiveProxyAddresses()) {
            NSURL *proxyURL = S7TVAdblockNormalizedProxyURL(address);
            if (!proxyURL) continue;
            NSURL *rewritten = S7TVAdblockRewriteURLThroughProxy(URL, proxyURL);
            if ([rewritten isEqual:URL]) continue;
            NSString *authorization = S7TVAdblockBasicAuthHeader(proxyURL);
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
            return [self s7tv_adblock_initWithURL:rewritten options:options];
        }
    }

    NSURLComponents *components = [NSURLComponents
        componentsWithURL:URL resolvingAgainstBaseURL:YES];
    components.scheme = @"s7tv-adblock";
    AVURLAsset *asset = [self s7tv_adblock_initWithURL:components.URL options:options];
    [asset.resourceLoader setDelegate:S7TVAdblockResourceLoader.sharedLoader
        queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
    return asset;
}

@end

static char S7TVAdblockPlayerStatusContext;

@interface AVPlayer (S7TVAdblockPlayback)
- (instancetype)s7tv_adblock_init;
- (void)s7tv_adblock_observeValueForKeyPath:(NSString *)keyPath
                                   ofObject:(id)object
                                     change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                                    context:(void *)context;
@end

@implementation AVPlayer (S7TVAdblockPlayback)

- (instancetype)s7tv_adblock_init {
    AVPlayer *player = [self s7tv_adblock_init];
    [player addObserver:player forKeyPath:@"status"
        options:NSKeyValueObservingOptionNew context:&S7TVAdblockPlayerStatusContext];
    return player;
}

- (void)s7tv_adblock_observeValueForKeyPath:(NSString *)keyPath
                                   ofObject:(id)object
                                     change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                                    context:(void *)context {
    if (context == &S7TVAdblockPlayerStatusContext &&
        [keyPath isEqualToString:@"status"] && S7TVAdblockIsEnabled() &&
        [change[NSKeyValueChangeNewKey] integerValue] == AVPlayerStatusReadyToPlay) {
        [self play];
        return;
    }
    [self s7tv_adblock_observeValueForKeyPath:keyPath ofObject:object
        change:change context:context];
}

@end

@interface NSObject (S7TVAdblockTwitchResourceLoader)
- (BOOL)s7tv_adblock_resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest;
- (BOOL)s7tv_adblock_resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest;
- (void)s7tv_adblock_URLSession:(NSURLSession *)session
                       dataTask:(NSURLSessionDataTask *)dataTask
                 didReceiveData:(NSData *)data;
- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager;
- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController;
- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController isInitialTab:(BOOL)isInitialTab;
+ (instancetype)s7tv_adblock_shared;
@end

@implementation NSObject (S7TVAdblockTwitchResourceLoader)

- (BOOL)s7tv_adblock_resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    if ([S7TVAdblockResourceLoader.sharedLoader handleLoadingRequest:loadingRequest]) return YES;
    return [self s7tv_adblock_resourceLoader:resourceLoader
        shouldWaitForLoadingOfRequestedResource:loadingRequest];
}

- (BOOL)s7tv_adblock_resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    if ([S7TVAdblockResourceLoader.sharedLoader handleLoadingRequest:renewalRequest]) return YES;
    return [self s7tv_adblock_resourceLoader:resourceLoader
        shouldWaitForRenewalOfRequestedResource:renewalRequest];
}

- (void)s7tv_adblock_URLSession:(NSURLSession *)session
                       dataTask:(NSURLSessionDataTask *)dataTask
                 didReceiveData:(NSData *)data {
    NSURLRequest *request = dataTask.currentRequest ?: dataTask.originalRequest;
    NSData *filtered = S7TVAdblockTransformResponseData(data, request);
    [self s7tv_adblock_URLSession:session dataTask:dataTask didReceiveData:filtered];
}

static void S7TVAdblockClearFollowingAds(id object) {
    Ivar headliner = class_getInstanceVariable(object_getClass(object), "headlinerManager");
    if (!headliner) return;
    Ivar displayState = class_getInstanceVariable(object_getClass(object),
                                                   "displayAdStateManager");
    if (displayState) object_setIvar(object, displayState, nil);
}

- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager {
    id object = [self s7tv_adblock_initWithGraphQL:graphQL themeManager:themeManager];
    if (S7TVAdblockIsEnabled()) S7TVAdblockClearFollowingAds(object);
    return object;
}

- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController {
    id object = [self s7tv_adblock_initWithGraphQL:graphQL themeManager:themeManager
                                     urlController:urlController];
    if (S7TVAdblockIsEnabled()) S7TVAdblockClearFollowingAds(object);
    return object;
}

- (instancetype)s7tv_adblock_initWithGraphQL:(id)graphQL themeManager:(id)themeManager
                                urlController:(id)urlController isInitialTab:(BOOL)isInitialTab {
    id object = [self s7tv_adblock_initWithGraphQL:graphQL themeManager:themeManager
        urlController:urlController isInitialTab:isInitialTab];
    if (S7TVAdblockIsEnabled()) S7TVAdblockClearFollowingAds(object);
    return object;
}

+ (instancetype)s7tv_adblock_shared {
    id shared = [self s7tv_adblock_shared];
    if (!S7TVAdblockIsEnabled() || !shared) return shared;
    Ivar displayState = class_getInstanceVariable(object_getClass(shared),
                                                   "displayAdStateManager");
    if (displayState) object_setIvar(shared, displayState, nil);
    return shared;
}

@end

static BOOL S7TVAdblockPrivateResourceLoaderInstalled = NO;
static BOOL S7TVAdblockLegacyGQLInstalled = NO;
static BOOL S7TVAdblockFollowingInstalled = NO;
static BOOL S7TVAdblockHeadlinerInstalled = NO;

static void S7TVAdblockTryInstallLateHooks(void) {
    @synchronized (S7TVAdblockResourceLoader.class) {
        if (!S7TVAdblockPrivateResourceLoaderInstalled) {
            Class loaderClass = NSClassFromString(@"_TtC6Twitch27AssetResourceLoaderDelegate");
            if (loaderClass) {
                BOOL first = S7TVAdblockExchangeInstanceMethod(loaderClass, NSObject.class,
                    @selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:),
                    @selector(s7tv_adblock_resourceLoader:shouldWaitForLoadingOfRequestedResource:));
                BOOL second = S7TVAdblockExchangeInstanceMethod(loaderClass, NSObject.class,
                    @selector(resourceLoader:shouldWaitForRenewalOfRequestedResource:),
                    @selector(s7tv_adblock_resourceLoader:shouldWaitForRenewalOfRequestedResource:));
                S7TVAdblockPrivateResourceLoaderInstalled = first || second;
            }
        }
        if (!S7TVAdblockLegacyGQLInstalled) {
            Class legacyClient = NSClassFromString(@"_TtC9TwitchKit18TKURLSessionClient");
            if (legacyClient) {
                S7TVAdblockLegacyGQLInstalled = S7TVAdblockExchangeInstanceMethod(
                    legacyClient, NSObject.class,
                    @selector(URLSession:dataTask:didReceiveData:),
                    @selector(s7tv_adblock_URLSession:dataTask:didReceiveData:));
            }
        }
        if (!S7TVAdblockFollowingInstalled) {
            Class following = NSClassFromString(@"_TtC6Twitch23FollowingViewController");
            if (following) {
                BOOL two = S7TVAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:"),
                    @selector(s7tv_adblock_initWithGraphQL:themeManager:));
                BOOL three = S7TVAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:urlController:"),
                    @selector(s7tv_adblock_initWithGraphQL:themeManager:urlController:));
                BOOL four = S7TVAdblockExchangeInstanceMethod(following, NSObject.class,
                    NSSelectorFromString(@"initWithGraphQL:themeManager:urlController:isInitialTab:"),
                    @selector(s7tv_adblock_initWithGraphQL:themeManager:urlController:isInitialTab:));
                S7TVAdblockFollowingInstalled = two || three || four;
            }
        }
        if (!S7TVAdblockHeadlinerInstalled) {
            Class headliner = NSClassFromString(@"_TtC6Twitch27HeadlinerFollowingAdManager");
            if (headliner) {
                S7TVAdblockHeadlinerInstalled = S7TVAdblockExchangeInstanceMethod(
                    object_getClass(headliner), object_getClass(NSObject.class),
                    @selector(shared), @selector(s7tv_adblock_shared));
            }
        }
    }
}

void S7TVAdblockInstallRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        S7TVAdblockRegisterDefaults();
        S7TVAdblockInstallSwiftRuntimeRebindings();
        BOOL assetHook = S7TVAdblockExchangeInstanceMethod(AVURLAsset.class,
            AVURLAsset.class, @selector(initWithURL:options:),
            @selector(s7tv_adblock_initWithURL:options:));
        BOOL playerInitHook = S7TVAdblockExchangeInstanceMethod(AVPlayer.class,
            AVPlayer.class, @selector(init), @selector(s7tv_adblock_init));
        BOOL playerKVOHook = S7TVAdblockExchangeInstanceMethod(AVPlayer.class,
            AVPlayer.class, @selector(observeValueForKeyPath:ofObject:change:context:),
            @selector(s7tv_adblock_observeValueForKeyPath:ofObject:change:context:));
        os_log(OS_LOG_DEFAULT, "[S7TV-Adblock] AVURLAsset hook installed=%d", assetHook);
        os_log(OS_LOG_DEFAULT, "[S7TV-Adblock] AVPlayer hooks installed=%d/%d",
               playerInitHook, playerKVOHook);
        S7TVAdblockTryInstallLateHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ S7TVAdblockTryInstallLateHooks(); });
        }
    });
}
