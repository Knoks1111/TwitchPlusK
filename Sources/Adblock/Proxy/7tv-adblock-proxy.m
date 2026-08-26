#import "Adblock/Proxy/7tv-adblock-proxy.h"
#import "Adblock/Proxy/7tv-adblock-data.h"
#import "Adblock/7tv-adblock-settings.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

static NSString *const S7TVAdblockProxyDispatchGuard = @"s7tv_adblock_proxy_dispatch";
static char S7TVAdblockProxySessionAssociationKey;

@interface S7TVAdblockProxyAuthDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, weak) id<NSURLSessionDelegate> inner;
@property (nonatomic, copy) NSString *proxyUser;
@property (nonatomic, copy) NSString *proxyPassword;
@end

@implementation S7TVAdblockProxyAuthDelegate

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

BOOL S7TVAdblockIsAdHost(NSString *host) {
    if (!host.length) return NO;
    static NSSet *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithObjects:@"edge.ads.twitch.tv", @"spade.twitch.tv",
            @"secure-sts-prod.imrworldwide.com", nil];
    });
    if ([exact containsObject:host]) return YES;
    return [host isEqualToString:@"amazon-adsystem.com"] ||
           [host hasSuffix:@".amazon-adsystem.com"];
}

BOOL S7TVAdblockIsPlaylistHost(NSString *host) {
    if (!host.length) return NO;
    return [host isEqualToString:@"usher.ttvnw.net"] ||
           [host isEqualToString:@"playlist.ttvnw.net"] ||
           [host hasSuffix:@".playlist.ttvnw.net"] ||
           [host hasSuffix:@".hls.ttvnw.net"];
}

BOOL S7TVAdblockIsMasterPlaylistHost(NSString *host) {
    return [host isEqualToString:@"usher.ttvnw.net"];
}

static BOOL S7TVAdblockIsActivelyCasting(void) {
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

static BOOL S7TVAdblockIsAirPlaying(void) {
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    for (AVAudioSessionPortDescription *output in audioSession.currentRoute.outputs)
        if ([output.portType isEqualToString:AVAudioSessionPortAirPlay]) return YES;
    return NO;
}

BOOL S7TVAdblockIsExternalPlayback(void) {
    BOOL cast = S7TVAdblockIsActivelyCasting();
    BOOL airPlay = cast ? NO : S7TVAdblockIsAirPlaying();
    if (cast || airPlay) {
        os_log(OS_LOG_DEFAULT,
            "[S7TV-Adblock] external playback (cast=%d airplay=%d), proxy bypassed",
            cast, airPlay);
    }
    return cast || airPlay;
}

BOOL S7TVAdblockIsInternalProxyDispatch(void) {
    return [[NSThread.currentThread.threadDictionary
             objectForKey:S7TVAdblockProxyDispatchGuard] boolValue];
}

NSString *S7TVAdblockBasicAuthHeader(NSURL *url) {
    if (!url.user.length) return nil;
    NSString *raw = [NSString stringWithFormat:@"%@:%@", url.user, url.password ?: @""];
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"Basic %@",
            [data base64EncodedStringWithOptions:0]];
}

static NSString *S7TVAdblockProxyCacheKey(NSURL *url) {
    return [NSString stringWithFormat:@"%@://%@:%@", url.scheme ?: @"http",
            url.host ?: @"?", url.port ?: @80];
}

static BOOL S7TVAdblockProxyIsLuminousV1(NSURL *proxyURL) {
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static dispatch_semaphore_t lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        lock = dispatch_semaphore_create(1);
    });
    NSString *key = S7TVAdblockProxyCacheKey(proxyURL);
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    NSNumber *known = cache[key];
    dispatch_semaphore_signal(lock);
    if (known) return known.boolValue;

    __block NSInteger statusCode = -1;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [proxyURL URLByAppendingPathComponent:@"ping"]];
    request.timeoutInterval = 3.0;
    NSString *authorization = S7TVAdblockBasicAuthHeader(proxyURL);
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
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    cache[key] = @(luminous);
    dispatch_semaphore_signal(lock);
    os_log(OS_LOG_DEFAULT, "[S7TV-Adblock] proxy %{public}@ luminous=%d",
           proxyURL.host ?: @"?", luminous);
    return luminous;
}

NSURL *S7TVAdblockRewriteURLThroughProxy(NSURL *URL, NSURL *proxyURL) {
    NSArray<NSString *> *path = URL.path.pathComponents;
    if (path.count < 2 || !S7TVAdblockProxyIsLuminousV1(proxyURL)) return URL;
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

static NSDictionary *S7TVAdblockParseProxyAddress(NSString *address) {
    NSURL *url = S7TVAdblockNormalizedProxyURL(address);
    if (!url) return nil;
    return @{
        @"host": url.host,
        @"port": url.port ?: @8080,
        @"user": url.user ?: @"",
        @"password": url.password ?: @"",
    };
}

NSURLSession *S7TVAdblockProxySession(NSURLSession *session, NSString *address) {
    NSDictionary *proxy = S7TVAdblockParseProxyAddress(address);
    NSURLSessionConfiguration *configuration = session.configuration.copy
        ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
    if (proxy) {
        configuration.connectionProxyDictionary = @{
            @"HTTPEnable": @YES, @"HTTPProxy": proxy[@"host"],
            @"HTTPPort": proxy[@"port"], @"HTTPSEnable": @YES,
            @"HTTPSProxy": proxy[@"host"], @"HTTPSPort": proxy[@"port"],
        };
    }
    S7TVAdblockProxyAuthDelegate *delegate = [S7TVAdblockProxyAuthDelegate new];
    delegate.inner = session.delegate;
    delegate.proxyUser = proxy[@"user"];
    delegate.proxyPassword = proxy[@"password"];
    return [NSURLSession sessionWithConfiguration:configuration delegate:delegate
        delegateQueue:session.delegateQueue ?: [NSOperationQueue new]];
}

NSURLRequest *S7TVAdblockPrepareRequest(NSURLRequest *request, BOOL *blocked) {
    if (blocked) *blocked = NO;
    if (!request || !S7TVAdblockIsEnabled() || S7TVAdblockIsInternalProxyDispatch())
        return request;
    if (S7TVAdblockIsAdHost(request.URL.host)) {
        if (blocked) *blocked = YES;
        return request;
    }
    // Le proxy ne doit jamais toucher aux requêtes Helix (badges/avatars),
    // aux CDN d'images, ni au reste de l'application. Seuls GQL et les
    // playlists vidéo font partie de son pipeline.
    NSString *host = request.URL.host.lowercaseString;
    BOOL isGQLRequest = [host isEqualToString:@"gql.twitch.tv"];
    BOOL isMasterPlaylistRequest = S7TVAdblockIsMasterPlaylistHost(host);
    if (!isGQLRequest && !isMasterPlaylistRequest) return request;

    NSMutableURLRequest *prepared = request.mutableCopy;
    NSData *body = S7TVAdblockTransformRequestData(request.HTTPBody, request);
    if (body != request.HTTPBody) prepared.HTTPBody = body;
    if (!S7TVAdblockProxyIsEnabled() ||
        !S7TVAdblockIsMasterPlaylistHost(prepared.URL.host) ||
        S7TVAdblockUserIsAdExempt(prepared.URL.query) ||
        S7TVAdblockIsExternalPlayback()) return prepared;
    for (NSString *address in S7TVAdblockEffectiveProxyAddresses()) {
        NSURL *proxyURL = S7TVAdblockNormalizedProxyURL(address);
        if (!proxyURL) continue;
        NSURL *rewritten = S7TVAdblockRewriteURLThroughProxy(prepared.URL, proxyURL);
        if (![rewritten isEqual:prepared.URL]) {
            prepared.URL = rewritten;
            NSString *authorization = S7TVAdblockBasicAuthHeader(proxyURL);
            if (authorization)
                [prepared setValue:authorization forHTTPHeaderField:@"Authorization"];
            os_log(OS_LOG_DEFAULT,
                "[S7TV-Adblock] master playlist rewritten through %{public}@",
                proxyURL.host ?: @"?");
            break;
        }
    }
    return prepared;
}

static NSURLSession *S7TVAdblockConnectProxySessionIfNeeded(
    NSURLSession *session, NSURLRequest *request) {
    if (!S7TVAdblockIsEnabled() || !S7TVAdblockProxyIsEnabled() ||
        !S7TVAdblockIsMasterPlaylistHost(request.URL.host) ||
        S7TVAdblockUserIsAdExempt(request.URL.query) ||
        S7TVAdblockIsExternalPlayback()) return nil;
    NSString *address = nil;
    for (NSString *candidate in S7TVAdblockEffectiveProxyAddresses()) {
        if (S7TVAdblockNormalizedProxyURL(candidate)) {
            address = candidate;
            break;
        }
    }
    return address ? S7TVAdblockProxySession(session, address) : nil;
}

NSURLSessionDataTask *S7TVAdblockCreateConnectTaskIfNeeded(
    NSURLSession *session, NSURLRequest *request) {
    NSURLSession *proxySession = S7TVAdblockConnectProxySessionIfNeeded(session, request);
    if (!proxySession) return nil;
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    threadDictionary[S7TVAdblockProxyDispatchGuard] = @YES;
    NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:request];
    [threadDictionary removeObjectForKey:S7TVAdblockProxyDispatchGuard];
    if (task) {
        objc_setAssociatedObject(task, &S7TVAdblockProxySessionAssociationKey,
            proxySession, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(OS_LOG_DEFAULT, "[S7TV-Adblock] master playlist routed via HTTP CONNECT");
    }
    return task;
}

NSURLSessionDataTask *S7TVAdblockCreateConnectTaskWithCompletionIfNeeded(
    NSURLSession *session, NSURLRequest *request,
    void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    NSURLSession *proxySession = S7TVAdblockConnectProxySessionIfNeeded(session, request);
    if (!proxySession) return nil;
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    threadDictionary[S7TVAdblockProxyDispatchGuard] = @YES;
    NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:request
                                                completionHandler:completion];
    [threadDictionary removeObjectForKey:S7TVAdblockProxyDispatchGuard];
    if (task) {
        objc_setAssociatedObject(task, &S7TVAdblockProxySessionAssociationKey,
            proxySession, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_log(OS_LOG_DEFAULT,
            "[S7TV-Adblock] master playlist routed via HTTP CONNECT (completion)");
    }
    return task;
}
