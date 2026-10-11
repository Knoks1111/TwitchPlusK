#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/Combo/tpK-adblock-combo.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Core/tpK-channel-resolver.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

static NSString *const TPKAdblockProxyDispatchGuard = @"tpk_adblock_proxy_dispatch";
static char TPKAdblockProxySessionAssociationKey;
static NSMutableDictionary<NSString *, NSNumber *> *tpk_proxyLuminousCache;
static dispatch_semaphore_t tpk_proxyLuminousCacheLock;
static NSMutableDictionary<NSString *, NSNumber *> *tpk_proxyPrefixCache;
static dispatch_semaphore_t tpk_proxyPrefixCacheLock;
// Dernier token Twitch brut (sans schéma) vu sur GQL, pour le ?auth= préfixe.
static NSString *tpk_lastTwitchRawAuthToken;
static NSObject *tpk_authTokenLock;

static void TPKAdblockInitializeProxyLuminousCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tpk_proxyLuminousCache = [NSMutableDictionary dictionary];
        tpk_proxyLuminousCacheLock = dispatch_semaphore_create(1);
        tpk_proxyPrefixCache = [NSMutableDictionary dictionary];
        tpk_proxyPrefixCacheLock = dispatch_semaphore_create(1);
        tpk_authTokenLock = [NSObject new];
    });
}

// "OAuth/Bearer xxx" ou brut → xxx. Rejette Basic et vide.
static NSString *TPKAdblockRawTokenFromAuthHeader(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSRange separator = [trimmed rangeOfCharacterFromSet:
        NSCharacterSet.whitespaceCharacterSet];
    NSString *credential = nil;
    if (separator.location == NSNotFound) {
        credential = trimmed;
    } else {
        NSString *scheme = [trimmed substringToIndex:separator.location];
        if ([scheme caseInsensitiveCompare:@"OAuth"] != NSOrderedSame &&
            [scheme caseInsensitiveCompare:@"Bearer"] != NSOrderedSame) return nil;
        credential = [[trimmed substringFromIndex:separator.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return credential.length ? credential : nil;
}

static void TPKAdblockNoteTwitchAuthHeader(NSString *value) {
    NSString *raw = TPKAdblockRawTokenFromAuthHeader(value);
    if (!raw.length) return;
    TPKAdblockInitializeProxyLuminousCache();
    @synchronized (tpk_authTokenLock) {
        tpk_lastTwitchRawAuthToken = [raw copy];
    }
}

static NSString *TPKAdblockCachedTwitchAuthToken(void) {
    TPKAdblockInitializeProxyLuminousCache();
    @synchronized (tpk_authTokenLock) {
        return tpk_lastTwitchRawAuthToken;
    }
}

@interface TPKAdblockProxyAuthDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, weak) id<NSURLSessionDelegate> inner;
@property (nonatomic, copy) NSString *proxyUser;
@property (nonatomic, copy) NSString *proxyPassword;
@end

@implementation TPKAdblockProxyAuthDelegate

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if (challenge.protectionSpace.isProxy && self.proxyUser.length) {
        NSURLCredential *credential = [NSURLCredential credentialWithUser:self.proxyUser
            password:self.proxyPassword ?: @""
            persistence:NSURLCredentialPersistenceForSession];
        completion(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }
    if ([self.inner respondsToSelector:_cmd]) {
        [self.inner URLSession:session didReceiveChallenge:challenge completionHandler:completion];
    } else {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    [self URLSession:session didReceiveChallenge:challenge completionHandler:completion];
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.inner respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.inner respondsToSelector:selector] ? self.inner : nil;
}

@end

BOOL TPKAdblockIsAdHost(NSString *host) {
    if (!host.length) return NO;
    static NSSet *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithObjects:@"edge.ads.twitch.tv",
            @"secure-sts-prod.imrworldwide.com", nil];
    });
    if ([exact containsObject:host]) return YES;
    return [host isEqualToString:@"amazon-adsystem.com"] ||
           [host hasSuffix:@".amazon-adsystem.com"];
}

BOOL TPKAdblockIsPlaylistHost(NSString *host) {
    if (!host.length) return NO;
    return [host isEqualToString:@"usher.ttvnw.net"] ||
           [host isEqualToString:@"playlist.ttvnw.net"] ||
           [host hasSuffix:@".playlist.ttvnw.net"] ||
           [host hasSuffix:@".hls.ttvnw.net"];
}

BOOL TPKAdblockIsMasterPlaylistHost(NSString *host) {
    return [host isEqualToString:@"usher.ttvnw.net"];
}

// Login sur playlist live (.../channel/hls/<login>.m3u8). Pas les VOD.
static NSString *TPKAdblockChannelLoginFromUsherURL(NSURL *URL) {
    if (!TPKAdblockIsMasterPlaylistHost(URL.host)) return nil;
    NSArray<NSString *> *parts = URL.path.pathComponents;
    if ([parts containsObject:@"vod"]) return nil;
    NSUInteger hls = [parts indexOfObject:@"hls"];
    if (hls == NSNotFound || hls + 1 >= parts.count) return nil;
    NSString *login = [parts[hls + 1].stringByDeletingPathExtension
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return login.length ? login : nil;
}

static BOOL TPKAdblockIsActivelyCasting(void) {
    Class contextClass = objc_getClass("GCKCastContext");
    if (!contextClass) return NO;
    SEL initializedSelector = @selector(isSharedInstanceInitialized);
    if ([contextClass respondsToSelector:initializedSelector] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(contextClass, initializedSelector)) return NO;
    if (![contextClass respondsToSelector:@selector(sharedInstance)]) return NO;
    id context = ((id (*)(id, SEL))objc_msgSend)(contextClass, @selector(sharedInstance));
    if (![context respondsToSelector:@selector(sessionManager)]) return NO;
    id manager = ((id (*)(id, SEL))objc_msgSend)(context, @selector(sessionManager));
    if (![manager respondsToSelector:@selector(currentCastSession)]) return NO;
    id castSession = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(currentCastSession));
    if (![castSession respondsToSelector:@selector(remoteMediaClient)]) return NO;
    id client = ((id (*)(id, SEL))objc_msgSend)(castSession, @selector(remoteMediaClient));
    if (![client respondsToSelector:@selector(mediaStatus)]) return NO;
    id status = ((id (*)(id, SEL))objc_msgSend)(client, @selector(mediaStatus));
    if (!status) return NO;
    if (![status respondsToSelector:@selector(playerState)]) return YES;
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(status, @selector(playerState));
    return state != 0 && state != 1;
}

static BOOL TPKAdblockIsAirPlaying(void) {
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    for (AVAudioSessionPortDescription *output in audioSession.currentRoute.outputs)
        if ([output.portType isEqualToString:AVAudioSessionPortAirPlay]) return YES;
    return NO;
}

BOOL TPKAdblockIsExternalPlayback(void) {
    BOOL cast = TPKAdblockIsActivelyCasting();
    BOOL airPlay = cast ? NO : TPKAdblockIsAirPlaying();
    if (cast || airPlay) {
        os_log(OS_LOG_DEFAULT,
            "[TPK-Adblock] external playback (cast=%d airplay=%d), proxy bypassed",
            cast, airPlay);
    }
    return cast || airPlay;
}

BOOL TPKAdblockIsInternalProxyDispatch(void) {
    return [[NSThread.currentThread.threadDictionary
             objectForKey:TPKAdblockProxyDispatchGuard] boolValue];
}

NSString *TPKAdblockBasicAuthHeader(NSURL *url) {
    if (!url.user.length) return nil;
    NSString *raw = [NSString stringWithFormat:@"%@:%@", url.user, url.password ?: @""];
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"Basic %@",
            [data base64EncodedStringWithOptions:0]];
}

void TPKAdblockInvalidateProxyDetectionCache(void) {
    TPKAdblockInitializeProxyLuminousCache();
    dispatch_semaphore_wait(tpk_proxyLuminousCacheLock, DISPATCH_TIME_FOREVER);
    [tpk_proxyLuminousCache removeAllObjects];
    dispatch_semaphore_signal(tpk_proxyLuminousCacheLock);
    dispatch_semaphore_wait(tpk_proxyPrefixCacheLock, DISPATCH_TIME_FOREVER);
    [tpk_proxyPrefixCache removeAllObjects];
    dispatch_semaphore_signal(tpk_proxyPrefixCacheLock);
}

static NSString *TPKAdblockProxyCacheKey(NSURL *url) {
    return [NSString stringWithFormat:@"%@://%@:%@", url.scheme ?: @"http",
            url.host ?: @"?", url.port ?: @80];
}

static BOOL TPKAdblockProxyIsLuminousV1(NSURL *proxyURL) {
    TPKAdblockInitializeProxyLuminousCache();
    NSString *key = TPKAdblockProxyCacheKey(proxyURL);
    dispatch_semaphore_wait(tpk_proxyLuminousCacheLock, DISPATCH_TIME_FOREVER);
    NSNumber *known = tpk_proxyLuminousCache[key];
    dispatch_semaphore_signal(tpk_proxyLuminousCacheLock);
    if (known) return known.boolValue;

    __block NSInteger statusCode = -1;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [proxyURL URLByAppendingPathComponent:@"ping"]];
    request.timeoutInterval = 3.0;
    NSString *authorization = TPKAdblockBasicAuthHeader(proxyURL);
    if (authorization) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, __unused NSError *error) {
            if ([response isKindOfClass:NSHTTPURLResponse.class])
                statusCode = ((NSHTTPURLResponse *)response).statusCode;
            dispatch_semaphore_signal(completed);
        }] resume];
    dispatch_semaphore_wait(completed,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3500 * NSEC_PER_MSEC)));
    BOOL luminous = statusCode == 200;
    dispatch_semaphore_wait(tpk_proxyLuminousCacheLock, DISPATCH_TIME_FOREVER);
    tpk_proxyLuminousCache[key] = @(luminous);
    dispatch_semaphore_signal(tpk_proxyLuminousCacheLock);
    os_log(OS_LOG_DEFAULT, "[TPK-Adblock] proxy %{public}@ luminous=%d",
           proxyURL.host ?: @"?", luminous);
    return luminous;
}

BOOL TPKAdblockProxyIsPrefixStyle(NSURL *proxyURL) {
    if (!proxyURL.host.length) return NO;
    TPKAdblockInitializeProxyLuminousCache();
    NSString *key = TPKAdblockProxyCacheKey(proxyURL);
    dispatch_semaphore_wait(tpk_proxyPrefixCacheLock, DISPATCH_TIME_FOREVER);
    NSNumber *known = tpk_proxyPrefixCache[key];
    dispatch_semaphore_signal(tpk_proxyPrefixCacheLock);
    if (known) return known.boolValue;

    // Sonde : <base>https://google.com → 2xx.
    NSString *base = proxyURL.absoluteString ?: @"";
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    NSURL *probeURL = [NSURL URLWithString:
        [base stringByAppendingString:@"https://google.com"]];
    BOOL prefix = NO;
    if (probeURL) {
        __block NSInteger statusCode = -1;
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:probeURL];
        request.timeoutInterval = 3.0;
        NSString *authorization = TPKAdblockBasicAuthHeader(proxyURL);
        if (authorization) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
        [[NSURLSession.sharedSession dataTaskWithRequest:request
            completionHandler:^(__unused NSData *data, NSURLResponse *response, __unused NSError *error) {
                if ([response isKindOfClass:NSHTTPURLResponse.class])
                    statusCode = ((NSHTTPURLResponse *)response).statusCode;
                dispatch_semaphore_signal(completed);
            }] resume];
        dispatch_semaphore_wait(completed,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3500 * NSEC_PER_MSEC)));
        prefix = statusCode >= 200 && statusCode < 300;
    }
    dispatch_semaphore_wait(tpk_proxyPrefixCacheLock, DISPATCH_TIME_FOREVER);
    tpk_proxyPrefixCache[key] = @(prefix);
    dispatch_semaphore_signal(tpk_proxyPrefixCacheLock);
    os_log(OS_LOG_DEFAULT, "[TPK-Adblock] proxy %{public}@ prefix=%d",
           proxyURL.host ?: @"?", prefix);
    return prefix;
}

static NSURL *TPKAdblockRewriteURLThroughPrefixProxy(NSURL *URL, NSURL *proxyURL) {
    NSString *original = URL.absoluteString;
    if (!original.length) return URL;
    NSString *base = proxyURL.absoluteString ?: @"";
    if (!base.length) return URL;
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    // Évite un double rewrite si l'URL est déjà proxifiée.
    if ([original hasPrefix:base]) return URL;
    NSString *result = [base stringByAppendingString:original];
    NSString *rawAuth = TPKAdblockCachedTwitchAuthToken();
    if (rawAuth.length) {
        NSString *separator = ([original rangeOfString:@"?"].location != NSNotFound) ? @"&" : @"?";
        NSMutableCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet.mutableCopy;
        [allowed addCharactersInString:@"-_.~"];
        NSString *encoded = [rawAuth stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        result = [NSString stringWithFormat:@"%@%@auth=%@", result, separator, encoded ?: rawAuth];
    }
    return [NSURL URLWithString:result] ?: URL;
}

NSURL *TPKAdblockRewriteURLThroughProxy(NSURL *URL, NSURL *proxyURL) {
    if (TPKAdblockProxyIsLuminousV1(proxyURL)) {
        NSArray<NSString *> *path = URL.path.pathComponents;
        if (path.count < 2) return URL;
        BOOL vod = [path[1] isEqualToString:@"vod"];
        NSString *playlistID = URL.lastPathComponent.stringByDeletingPathExtension;
        NSString *query = URL.query ?: @"";
        if (!vod && query.length) {
            NSURLComponents *components = [NSURLComponents new];
            components.percentEncodedQuery = query;
            NSMutableArray<NSURLQueryItem *> *items = components.queryItems.mutableCopy
                ?: [NSMutableArray array];
            [items filterUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSURLQueryItem *item, __unused NSDictionary *bindings) {
                    return ![item.name isEqualToString:@"token"] &&
                           ![item.name isEqualToString:@"sig"];
                }]];
            components.queryItems = items.count ? items : nil;
            query = components.percentEncodedQuery ?: @"";
        }
        NSString *fragment = query.length
            ? [NSString stringWithFormat:@"%@.m3u8?%@", playlistID, query]
            : [NSString stringWithFormat:@"%@.m3u8", playlistID];
        NSMutableCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet.mutableCopy;
        [allowed addCharactersInString:@"-_.~"];
        NSString *encoded = [fragment stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        NSString *base = proxyURL.absoluteString;
        if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
        NSString *result = [NSString stringWithFormat:@"%@%@/%@", base,
                            vod ? @"vod" : @"playlist", encoded];
        return [NSURL URLWithString:result] ?: URL;
    }
    // Sinon style préfixe, sinon URL intacte (fallback CONNECT préservé).
    if (TPKAdblockProxyIsPrefixStyle(proxyURL)) {
        return TPKAdblockRewriteURLThroughPrefixProxy(URL, proxyURL);
    }
    return URL;
}

static NSDictionary *TPKAdblockParseProxyAddress(NSString *address) {
    NSURL *url = TPKAdblockNormalizedProxyURL(address);
    if (!url) return nil;
    return @{
        @"host": url.host,
        @"port": url.port ?: @8080,
        @"user": url.user ?: @"",
        @"password": url.password ?: @"",
    };
}

NSURLSession *TPKAdblockProxySession(NSURLSession *session, NSString *address) {
    NSDictionary *proxy = TPKAdblockParseProxyAddress(address);
    NSURLSessionConfiguration *configuration = session.configuration.copy
        ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
    if (proxy) {
        configuration.connectionProxyDictionary = @{
            @"HTTPEnable": @YES, @"HTTPProxy": proxy[@"host"],
            @"HTTPPort": proxy[@"port"], @"HTTPSEnable": @YES,
            @"HTTPSProxy": proxy[@"host"], @"HTTPSPort": proxy[@"port"],
        };
    }
    TPKAdblockProxyAuthDelegate *delegate = [TPKAdblockProxyAuthDelegate new];
    delegate.inner = session.delegate;
    delegate.proxyUser = proxy[@"user"];
    delegate.proxyPassword = proxy[@"password"];
    return [NSURLSession sessionWithConfiguration:configuration delegate:delegate
        delegateQueue:session.delegateQueue ?: [NSOperationQueue new]];
}

// Liste effective selon la méthode active : combo = liste combo séparée,
// sinon liste vidéo. La détection chaîne/token au-dessus reste inchangée.
static NSArray<NSString *> *TPKAdblockProxyEffectiveAddressesForMethod(void) {
    if (TPKAdblockActiveMethod() == TPKAdblockMethodProxyPlusLocal) {
        return TPKAdblockComboProxyEffectiveAddresses();
    }
    return TPKAdblockEffectiveProxyAddresses();
}

NSURLRequest *TPKAdblockPrepareRequest(NSURLRequest *request, BOOL *blocked) {
    if (blocked) *blocked = NO;
    // Détection chaîne, TOUJOURS active même adblock OFF (lecture seule).
    if (request) {
        NSString *sniffHost = request.URL.host.lowercaseString;
        if ([sniffHost isEqualToString:@"gql.twitch.tv"]) {
            NSString *authHeader = [request valueForHTTPHeaderField:@"Authorization"];
            if (authHeader.length) TPKAdblockNoteTwitchAuthHeader(authHeader);
        } else if (TPKAdblockIsMasterPlaylistHost(sniffHost)) {
            NSString *login = TPKAdblockChannelLoginFromUsherURL(request.URL);
            if (login.length) TPKChannelResolverNoteStreamLogin(login);
        }
    }
    if (!request || !TPKAdblockIsEnabled() || TPKAdblockIsInternalProxyDispatch())
        return request;
    if (TPKAdblockIsAdHost(request.URL.host)) {
        if (blocked) *blocked = YES;
        return request;
    }
    // Le proxy ne doit jamais toucher aux requêtes Helix (badges/avatars),
    // aux CDN d'images, ni au reste de l'application. Seuls GQL et les
    // playlists vidéo font partie de son pipeline.
    NSString *host = request.URL.host.lowercaseString;
    BOOL isGQLRequest = [host isEqualToString:@"gql.twitch.tv"];
    BOOL isMasterPlaylistRequest = TPKAdblockIsMasterPlaylistHost(host);
    if (!isGQLRequest && !isMasterPlaylistRequest) return request;

    NSMutableURLRequest *prepared = request.mutableCopy;
    NSData *body = TPKAdblockTransformRequestData(request.HTTPBody, request);
    if (body != request.HTTPBody) prepared.HTTPBody = body;
    if (!TPKAdblockProxyIsEnabled() ||
        !TPKAdblockIsMasterPlaylistHost(prepared.URL.host) ||
        TPKAdblockUserIsAdExempt(prepared.URL.query) ||
        TPKAdblockIsExternalPlayback()) return prepared;
    for (NSString *address in TPKAdblockProxyEffectiveAddressesForMethod()) {
        NSURL *proxyURL = TPKAdblockNormalizedProxyURL(address);
        if (!proxyURL) continue;
        NSURL *rewritten = TPKAdblockRewriteURLThroughProxy(prepared.URL, proxyURL);
        if (![rewritten isEqual:prepared.URL]) {
            prepared.URL = rewritten;
            NSString *authorization = TPKAdblockBasicAuthHeader(proxyURL);
            if (authorization)
                [prepared setValue:authorization forHTTPHeaderField:@"Authorization"];
            os_log(OS_LOG_DEFAULT,
                "[TPK-Adblock] master playlist rewritten through %{public}@",
                proxyURL.host ?: @"?");
            break;
        }
    }
    return prepared;
}

static NSURLSession *TPKAdblockConnectProxySessionIfNeeded(
    NSURLSession *session, NSURLRequest *request) {
    if (!TPKAdblockIsEnabled() || !TPKAdblockProxyIsEnabled() ||
        !TPKAdblockIsMasterPlaylistHost(request.URL.host) ||
        TPKAdblockUserIsAdExempt(request.URL.query) ||
        TPKAdblockIsExternalPlayback()) return nil;
    NSString *address = nil;
    for (NSString *candidate in TPKAdblockProxyEffectiveAddressesForMethod()) {
        if (TPKAdblockNormalizedProxyURL(candidate)) {
            address = candidate;
            break;
        }
    }
    return address ? TPKAdblockProxySession(session, address) : nil;
}

NSURLSessionDataTask *TPKAdblockCreateConnectTaskIfNeeded(
    NSURLSession *session, NSURLRequest *request) {
    NSURLSession *proxySession = TPKAdblockConnectProxySessionIfNeeded(session, request);
    if (!proxySession) return nil;
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    threadDictionary[TPKAdblockProxyDispatchGuard] = @YES;
    // Marqueur VAFT : ce fetch tunnelé ne doit pas être réintercepté par
    // TASURLProtocol (il contournerait le proxy).
    NSMutableURLRequest *tunneled = request.mutableCopy;
    [tunneled setValue:@"1" forHTTPHeaderField:@"X-TAS-Internal"];
    NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:tunneled];
    [threadDictionary removeObjectForKey:TPKAdblockProxyDispatchGuard];
    if (task) {
        objc_setAssociatedObject(task, &TPKAdblockProxySessionAssociationKey,
            proxySession, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(OS_LOG_DEFAULT, "[TPK-Adblock] master playlist routed via HTTP CONNECT");
    }
    return task;
}

NSURLSessionDataTask *TPKAdblockCreateConnectTaskWithCompletionIfNeeded(
    NSURLSession *session, NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    NSURLSession *proxySession = TPKAdblockConnectProxySessionIfNeeded(session, request);
    if (!proxySession) return nil;
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    threadDictionary[TPKAdblockProxyDispatchGuard] = @YES;
    NSMutableURLRequest *tunneled = request.mutableCopy;
    [tunneled setValue:@"1" forHTTPHeaderField:@"X-TAS-Internal"];
    NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:tunneled
                                                 completionHandler:completion];
    [threadDictionary removeObjectForKey:TPKAdblockProxyDispatchGuard];
    if (task) {
        objc_setAssociatedObject(task, &TPKAdblockProxySessionAssociationKey,
            proxySession, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(OS_LOG_DEFAULT,
            "[TPK-Adblock] master playlist routed via HTTP CONNECT (completion)");
    }
    return task;
}
