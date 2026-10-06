#import "Adblock/Proxy/7tv-adblock-proxy-status.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Adblock/Proxy/7tv-adblock-proxy.h"
#import <os/log.h>

typedef void (^S7TVAdblockProxyStatusCompletion)(S7TVAdblockProxyStatus status);

// The status screen is event-driven, but several UI updates can request the
// same probe in quick succession (view appearance + table reload + a toggle).
// Coalesce those requests so one network check fans out to every waiter.
static dispatch_queue_t s7tv_proxyStatusQueue;
static NSMutableDictionary<NSString *, NSMutableArray *> *s7tv_proxyStatusPending;

static void S7TVAdblockInitializeProxyStatusState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s7tv_proxyStatusQueue = dispatch_queue_create(
            "com.twitchplusk.adblock-proxy-status", DISPATCH_QUEUE_SERIAL);
        s7tv_proxyStatusPending = [NSMutableDictionary dictionary];
    });
}

static NSString *S7TVAdblockProxyStatusKey(NSURL *URL) {
    // Include the complete normalized URL so changing credentials or a
    // non-default endpoint cannot reuse a result from another configuration.
    return URL.absoluteString ?: @"";
}

static void S7TVAdblockFinishProxyStatusProbe(
    NSString *key, S7TVAdblockProxyStatus status) {
    __block NSArray *callbacks = nil;
    dispatch_sync(s7tv_proxyStatusQueue, ^{
        callbacks = [s7tv_proxyStatusPending[key] copy] ?: @[];
        [s7tv_proxyStatusPending removeObjectForKey:key];
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        for (S7TVAdblockProxyStatusCompletion callback in callbacks) {
            if (callback) callback(status);
        }
    });
}

void S7TVAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(S7TVAdblockProxyStatus status)) {
    if (!completion) return;
    S7TVAdblockInitializeProxyStatusState();

    if (!address.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(S7TVAdblockProxyStatusOffline);
        });
        return;
    }

    NSURL *URL = S7TVAdblockNormalizedProxyURL(address);
    if (!URL.host.length) {
        os_log_error(OS_LOG_DEFAULT,
                     "[7TV-Adblock] functional proxy probe: invalid address");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(S7TVAdblockProxyStatusOffline);
        });
        return;
    }

    NSURL *pingURL = [URL URLByAppendingPathComponent:@"ping"];
    NSString *key = S7TVAdblockProxyStatusKey(URL);
    __block BOOL shouldStartProbe = NO;
    dispatch_sync(s7tv_proxyStatusQueue, ^{
        NSMutableArray *callbacks = s7tv_proxyStatusPending[key];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            s7tv_proxyStatusPending[key] = callbacks;
            shouldStartProbe = YES;
        }
        [callbacks addObject:[completion copy]];
    });
    if (!shouldStartProbe) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:pingURL];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 4.0;
    NSString *authorization = S7TVAdblockBasicAuthHeader(URL);
    if (authorization) {
        [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.URLCredentialStorage = nil;
    configuration.timeoutIntervalForRequest = 4.0;
    configuration.timeoutIntervalForResource = 5.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data,
                            NSURLResponse *response,
                            NSError *error) {
        NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;
        if (statusCode == 200) {
            os_log(OS_LOG_DEFAULT,
               "[7TV-Adblock] functional proxy probe %{public}@:%d status=%ld errorCode=%ld",
               URL.host ?: @"?", (URL.port ?: @8080).intValue,
               (long)statusCode, (long)(error ? error.code : 0));
            S7TVAdblockFinishProxyStatusProbe(
                key, S7TVAdblockProxyStatusOnline);
            return;
        }
        // Repli préfixe : <base>https://google.com → 2xx.
        NSString *base = URL.absoluteString ?: @"";
        if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
        NSURL *prefixProbeURL = [NSURL URLWithString:
            [base stringByAppendingString:@"https://google.com"]];
        if (!prefixProbeURL) {
            S7TVAdblockFinishProxyStatusProbe(key, S7TVAdblockProxyStatusOffline);
            return;
        }
        NSMutableURLRequest *prefixRequest =
            [NSMutableURLRequest requestWithURL:prefixProbeURL];
        prefixRequest.HTTPMethod = @"GET";
        prefixRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        prefixRequest.timeoutInterval = 4.0;
        if (authorization) {
            [prefixRequest setValue:authorization forHTTPHeaderField:@"Authorization"];
        }
        NSURLSessionConfiguration *prefixConfig =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        prefixConfig.URLCredentialStorage = nil;
        prefixConfig.timeoutIntervalForRequest = 4.0;
        prefixConfig.timeoutIntervalForResource = 5.0;
        NSURLSession *prefixSession = [NSURLSession sessionWithConfiguration:prefixConfig];
        NSURLSessionDataTask *prefixTask = [prefixSession dataTaskWithRequest:prefixRequest
            completionHandler:^(__unused NSData *prefixData,
                                NSURLResponse *prefixResponse,
                                NSError *prefixError) {
            NSInteger prefixCode = [prefixResponse isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)prefixResponse).statusCode : -1;
            BOOL functional = prefixCode >= 200 && prefixCode < 300;
            os_log(OS_LOG_DEFAULT,
                   "[7TV-Adblock] functional proxy probe %{public}@:%d status=%ld errorCode=%ld prefix=%d",
                   URL.host ?: @"?", (URL.port ?: @8080).intValue,
                   (long)prefixCode, (long)(prefixError ? prefixError.code : 0), functional);
            S7TVAdblockFinishProxyStatusProbe(
                key, functional ? S7TVAdblockProxyStatusOnline
                                 : S7TVAdblockProxyStatusOffline);
        }];
        if (!prefixTask) {
            S7TVAdblockFinishProxyStatusProbe(key, S7TVAdblockProxyStatusOffline);
            return;
        }
        [prefixTask resume];
    }];

    if (!task) {
        S7TVAdblockFinishProxyStatusProbe(key, S7TVAdblockProxyStatusOffline);
        return;
    }
    [task resume];
}
