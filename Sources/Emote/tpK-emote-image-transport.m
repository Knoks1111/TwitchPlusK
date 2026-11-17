#import "Emote/tpK-emote-image-transport.h"
#import <ImageIO/ImageIO.h>
#import "Core/tpK-core-manager.h"
#import "Adblock/Emote/tpK-adblock-emote-proxy.h"
#import <objc/runtime.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <strings.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <sys/time.h>

// Scheduler state belongs to the transport queue.
enum { TPKImageSlots = 256, TPKImageTransfers = 8, TPKImageColdTransfers = 6, TPKImageConsumers = 256 };
typedef struct { unsigned consumers; BOOL running; uint64_t order; BOOL checking, cached; } TPKImageSlot;
typedef struct { TPKImageSlot slots[TPKImageSlots]; unsigned active, coldActive; uint64_t order; } TPKImageSchedule;
static int ImageAdmit(TPKImageSchedule *state) {
    for (unsigned i = 0; i < TPKImageSlots; ++i) {
        if (state->slots[i].order) continue;
        state->slots[i] = (TPKImageSlot){1, NO, ++state->order, NO, NO};
        return (int)i;
    }
    return -1;
}
static BOOL ImageJoin(TPKImageSchedule *state, unsigned slot) {
    TPKImageSlot *item = &state->slots[slot];
    if (!item->order || item->consumers >= TPKImageConsumers) return NO;
    ++item->consumers; return YES;
}
static BOOL ImageLeave(TPKImageSchedule *state, unsigned slot) {
    TPKImageSlot *item = &state->slots[slot];
    if (!item->consumers) return NO;
    if (--item->consumers || item->running) return NO;
    memset(item, 0, sizeof(*item)); return YES;
}
static void ImageFinish(TPKImageSchedule *state, unsigned slot) {
    if (state->slots[slot].running) {
        --state->active;
        if (!state->slots[slot].cached) --state->coldActive;
    }
    memset(&state->slots[slot], 0, sizeof(TPKImageSlot));
}
static int ImageNext(TPKImageSchedule *state) {
    if (state->active >= TPKImageTransfers) return -1;
    int selected = -1;
    for (unsigned i = 0; i < TPKImageSlots; ++i) {
        TPKImageSlot *item = &state->slots[i];
        if (!item->order || item->running || item->checking || !item->consumers) continue;
        if (!item->cached && state->coldActive >= TPKImageColdTransfers) continue;
        if (selected < 0 || (item->cached && !state->slots[selected].cached) ||
            (item->cached == state->slots[selected].cached && item->order < state->slots[selected].order)) selected = (int)i;
    }
    if (selected >= 0) {
        state->slots[selected].running = YES; ++state->active;
        if (!state->slots[selected].cached) ++state->coldActive;
    }
    return selected;
}
// End of scheduler.

static double ImageFreshSeconds(double lifetime, double age, double dateAge, double transfer, double elapsed) {
    if (!isfinite(lifetime) || !isfinite(age) || !isfinite(dateAge) || !isfinite(transfer) || !isfinite(elapsed) ||
        lifetime <= 0 || age < 0 || dateAge < 0 || transfer < 0 || elapsed < 0) return 0;
    return fmax(0, lifetime - fmax(age, dateAge) - transfer - elapsed);
}
static BOOL ImageMaxAge(const char *input, double *seconds) {
    BOOL found = NO;
    if (!input || strlen(input) > 4096) return NO;
    while (*input) {
        const char *end = strchr(input, ','); if (!end) end = input + strlen(input);
        while (input < end && (*input == ' ' || *input == '\t')) ++input;
        while (end > input && (end[-1] == ' ' || end[-1] == '\t')) --end;
        size_t size = (size_t)(end-input);
        size_t prefix = size > 8 && !strncasecmp(input, "max-age=", 8) ? 8 :
            size > 9 && !strncasecmp(input, "s-maxage=", 9) ? 9 :
            size > 23 && !strncasecmp(input, "stale-while-revalidate=", 23) ? 23 :
            size > 15 && !strncasecmp(input, "stale-if-error=", 15) ? 15 : 0;
        if (prefix) {
            if (prefix == 8 && found) return NO;
            double value = 0;
            for (const char *p = input+prefix; p < end; ++p) {
                if (*p < '0' || *p > '9') return NO;
                value = value*10 + (*p-'0'); if (value > 2147483647) return NO;
            }
            if (prefix == 8) { if (value <= 0) return NO; *seconds = value; found = YES; }
        } else if (!((size == 6 && !strncasecmp(input, "public", size)) ||
                     (size == 9 && !strncasecmp(input, "immutable", size)) ||
                     (size == 15 && !strncasecmp(input, "must-revalidate", size)) ||
                     (size == 12 && !strncasecmp(input, "no-transform", size)))) return NO;
        input = strchr(input, ','); if (!input) break;
        if (!*++input) return NO;
    }
    return found;
}
static unsigned ImageVaryRequirements(const char *input) {
    unsigned mask = 0;
    if (!input || !*input) return 0;
    if (strlen(input) > 1024) return UINT32_MAX;
    while (*input) {
        const char *end = strchr(input, ','); if (!end) end = input + strlen(input);
        while (input < end && (*input == ' ' || *input == '\t')) ++input;
        while (end > input && (end[-1] == ' ' || end[-1] == '\t')) --end;
        size_t n = (size_t)(end-input);
        if (n == 10 && !strncasecmp(input,"user-agent",n)) mask |= 1;
        else if (n == 15 && !strncasecmp(input,"accept-encoding",n)) mask |= 2;
        else if (n == 15 && !strncasecmp(input,"accept-language",n)) mask |= 4;
        else if (n == 6 && !strncasecmp(input,"accept",n)) mask |= 8;
        else if (!((n == 6 && !strncasecmp(input,"origin",n)) ||
            (n == 29 && !strncasecmp(input,"access-control-request-method",n)) ||
            (n == 30 && !strncasecmp(input,"access-control-request-headers",n)))) return UINT32_MAX;
        input = strchr(input, ','); if (!input) break;
        if (!*++input) return UINT32_MAX;
    }
    return mask;
}
// End of freshness helpers.

@class TPKEmoteImageProtocol;
@interface TPKImageFlight : NSObject
@property (nonatomic) unsigned slot;
@property (nonatomic, copy) NSArray *key;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURL *providerURL;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLResponse *response;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSMutableArray<TPKEmoteImageProtocol *> *consumers;
@property (nonatomic) NSTimeInterval queuedAt;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic, strong) NSURLSessionTaskMetrics *metrics;
@property (nonatomic, strong) NSCachedURLResponse *proposal;
@property (nonatomic, weak) NSOperation *lookup;
@property (nonatomic) BOOL cacheChecked;
@property (nonatomic) unsigned provider;
@property (nonatomic) BOOL proxy;
@end
@implementation TPKImageFlight
@end

@interface TPKEmoteImageProtocol : NSURLProtocol
@property (nonatomic) BOOL stopped;
@property (nonatomic, weak) TPKImageFlight *flight;
- (void)deliver:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error;
@end
@interface TPKImageSessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

static dispatch_queue_t transportQueue;
static NSMutableDictionary<NSArray *, TPKImageFlight *> *flights;
static NSMapTable<NSURLSessionTask *, TPKImageFlight *> *tasks;
static TPKImageSchedule schedule;
static NSURLSession *innerSession;
static NSOperationQueue *cacheQueue;
static NSString *cacheEpoch;
static id (*originalSession)(id, SEL, NSURLSessionConfiguration *);
static id (*originalSessionDelegate)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);
static NSString *const internalKey = @"TPKEmoteImageTransportInternal";
static const NSUInteger maxImageBytes = 8 * 1024 * 1024;

static double ImageTick(void) {
    static mach_timebase_info_data_t scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&scale); });
    return (double)mach_continuous_time() * scale.numer / scale.denom / 1e9;
}
static NSString *ImageCacheEpoch(void) {
    struct timeval boot = {0};
    size_t size = sizeof(boot);
    int mib[] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &size, NULL, 0) == 0 && size == sizeof(boot) && boot.tv_sec > 0)
        return [NSString stringWithFormat:@"tpk-http-v1:%lld:%d", (long long)boot.tv_sec, (int)boot.tv_usec];
    return NSUUID.UUID.UUIDString;
}
typedef struct {
    unsigned requests, joins, direct, fallback, errors, network, local, unknown, cancelled;
    unsigned lookups, loads, deliveries, receipts, proofSkip, headerSkip, storeSkip, candidates, headerReasons[7];
    double lookupSum, lookupMax, queueSum, queueMax, loadSum, loadMax, deliverySum, deliveryMax, lastLog;
} TPKImageStats;
static TPKImageStats stats;
static BOOL statsDirty, statsFlushPending;
typedef struct { unsigned domain, count; NSInteger code; } TPKImageErrorCount;
typedef struct {
    unsigned network, local, errors, queueTimeouts, httpErrors, proxyErrors, rejected;
    unsigned phaseCount[5];
    double phaseSum[5], phaseMax[5];
    NSInteger lastCode, underlyingCode, httpStatus;
    unsigned domain, underlyingDomain, protocol, failureProtocol, failureStage;
    NSUInteger failureBytes;
    int64_t expectedBytes;
    double failureLoad;
    TPKImageErrorCount codes[8];
    unsigned otherCodes;
    uint64_t payloadBytes, wireBytes;
    NSUInteger maxPayload, slowPayload;
    double slowBody;
    unsigned formats[5], slowFormat, slowScale, cellular;
} TPKImageProviderStats;
static TPKImageProviderStats providers[4];
static unsigned ProviderIndex(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"cdn.7tv.app"] || [host isEqualToString:@"cdn.7tv.io"]) return 0;
    if ([host isEqualToString:@"cdn.betterttv.net"]) return 1;
    if ([host isEqualToString:@"cdn.frankerfacez.com"]) return 2;
    return 3;
}
static unsigned ErrorDomain(NSString *domain) {
    if ([domain isEqualToString:NSURLErrorDomain]) return 1;
    if ([domain isEqualToString:NSPOSIXErrorDomain]) return 2;
    if ([domain isEqualToString:@"kCFErrorDomainCFNetwork"]) return 3;
    if ([domain isEqualToString:NSOSStatusErrorDomain]) return 4;
    return domain ? 5 : 0;
}
static unsigned ProtocolIndex(NSString *value) {
    NSString *protocol = value.lowercaseString;
    return [protocol hasPrefix:@"h3"] ? 3 : [protocol isEqualToString:@"h2"] ? 2 :
        [protocol hasPrefix:@"http/1"] ? 1 : protocol.length ? 4 : 0;
}
static void RecordFailure(unsigned provider, NSError *error, NSInteger status, BOOL proxy, BOOL queued) {
    statsDirty = YES;
    TPKImageProviderStats *item = &providers[provider];
    ++item->errors; if (proxy) ++item->proxyErrors;
    if (queued && error.code == NSURLErrorTimedOut) ++item->queueTimeouts;
    if (status >= 400) ++item->httpErrors;
    if (queued) return;
    BOOL counted = NO;
    for (unsigned i = 0; i < 8; ++i) {
        TPKImageErrorCount *bucket = &item->codes[i];
        if (bucket->count && (bucket->domain != ErrorDomain(error.domain) || bucket->code != error.code)) continue;
        bucket->domain = ErrorDomain(error.domain); bucket->code = error.code; ++bucket->count; counted = YES; break;
    }
    if (!counted) ++item->otherCodes;
    item->lastCode = error.code; item->domain = ErrorDomain(error.domain); item->httpStatus = status;
    item->failureStage = queued ? 1 : 0; item->failureBytes = 0; item->expectedBytes = -1;
    item->failureLoad = 0; item->failureProtocol = 0;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (![underlying isKindOfClass:NSError.class]) underlying = nil;
    item->underlyingCode = underlying.code; item->underlyingDomain = ErrorDomain(underlying.domain);
}
static void RecordPhase(TPKImageProviderStats *item, unsigned phase, NSDate *start, NSDate *end) {
    if (!start || !end) return;
    double elapsed = [end timeIntervalSinceDate:start];
    if (!isfinite(elapsed) || elapsed < 0) return;
    ++item->phaseCount[phase]; item->phaseSum[phase] += elapsed; item->phaseMax[phase] = MAX(item->phaseMax[phase],elapsed);
}
static void ImageStatsLog(void) {
    if (!statsDirty) return;
    double now = ImageTick();
    TPKManager *manager = TPKManager.sharedManager;
    if (!manager.logsEnabled || !manager.logChat) return;
    if (now-stats.lastLog < 15) {
        if (!statsFlushPending) {
            statsFlushPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((15-(now-stats.lastLog))*NSEC_PER_SEC)),transportQueue,^{
                statsFlushPending = NO; ImageStatsLog();
            });
        }
        return;
    }
    statsDirty = NO;
    stats.lastLog = now;
    [manager log:@"[Chat] 🧪 Images: req=%u shared=%u direct=%u fallback=%u cachedCandidate=%u groups=%lu active=%u cold=%u net=%u local=%u unknown=%u errors=%u cancel=%u receipt=%u skip(proof/headers/store)=%u/%u/%u headers(shape/vary/ttl/age/date/mismatch/expired)=%u/%u/%u/%u/%u/%u/%u | cache avg/max=%.0f/%.0fms queue=%.0f/%.0fms load=%.0f/%.0fms delivery=%.0f/%.0fms",
        stats.requests, stats.joins, stats.direct, stats.fallback, stats.candidates,(unsigned long)flights.count,schedule.active,schedule.coldActive,
        stats.network, stats.local, stats.unknown, stats.errors, stats.cancelled,
        stats.receipts, stats.proofSkip, stats.headerSkip, stats.storeSkip,
        stats.headerReasons[0],stats.headerReasons[1],stats.headerReasons[2],stats.headerReasons[3],stats.headerReasons[4],stats.headerReasons[5],stats.headerReasons[6],
        1000*stats.lookupSum/MAX(1,stats.lookups), 1000*stats.lookupMax,
        1000*stats.queueSum/MAX(1,stats.loads), 1000*stats.queueMax,
        1000*stats.loadSum/MAX(1,stats.loads), 1000*stats.loadMax,
        1000*stats.deliverySum/MAX(1,stats.deliveries), 1000*stats.deliveryMax];
    NSArray *names = @[@"7TV", @"BTTV", @"FFZ", @"other"];
    NSArray *domains = @[@"none", @"URL", @"POSIX", @"CFNetwork", @"OSStatus", @"other"];
    NSArray *protocols = @[@"unknown", @"h1", @"h2", @"h3", @"other"];
    NSArray *stages = @[@"unknown", @"queue", @"DNS", @"connect", @"TLS", @"TTFB", @"body", @"HTTP"];
    NSArray *formats = @[@"other", @"webp", @"gif", @"png", @"avif"];
    for (unsigned i = 0; i < 4; ++i) {
        TPKImageProviderStats *p = &providers[i];
        if (!p->network && !p->local && !p->errors) continue;
        NSMutableArray *codes = [NSMutableArray array];
        for (unsigned j = 0; j < 8; ++j) if (p->codes[j].count)
            [codes addObject:[NSString stringWithFormat:@"%@:%ld=%u",domains[p->codes[j].domain],(long)p->codes[j].code,p->codes[j].count]];
        [manager log:@"[Chat] 🧪 Images %@: net=%u local=%u errors=%u queueTimeout=%u httpError=%u proxyError=%u rejected=%u protocol=%@ taskCodes={%@} otherCodes=%u lastTask=%@:%ld underlying=%@:%ld HTTP=%ld failureProtocol=%@ stage=%@ bytes=%lu/%lld load=%.0fms | avg/max ms DNS=%.0f/%.0f connect=%.0f/%.0f TLS=%.0f/%.0f TTFB=%.0f/%.0f body=%.0f/%.0f",
            names[i], p->network,p->local,p->errors,p->queueTimeouts,p->httpErrors,p->proxyErrors,p->rejected,
            protocols[p->protocol],[codes componentsJoinedByString:@","],p->otherCodes,
            domains[p->domain],(long)p->lastCode,domains[p->underlyingDomain],(long)p->underlyingCode,(long)p->httpStatus,protocols[p->failureProtocol],
            stages[p->failureStage],(unsigned long)p->failureBytes,(long long)p->expectedBytes,1000*p->failureLoad,
            1000*p->phaseSum[0]/MAX(1,p->phaseCount[0]),1000*p->phaseMax[0],
            1000*p->phaseSum[1]/MAX(1,p->phaseCount[1]),1000*p->phaseMax[1],
            1000*p->phaseSum[2]/MAX(1,p->phaseCount[2]),1000*p->phaseMax[2],
            1000*p->phaseSum[3]/MAX(1,p->phaseCount[3]),1000*p->phaseMax[3],
            1000*p->phaseSum[4]/MAX(1,p->phaseCount[4]),1000*p->phaseMax[4]];
        if (p->payloadBytes) [manager log:@"[Chat] 🧪 Images %@ payload: total=%llu max=%lu wire=%llu cellularTx=%u formats(other/webp/gif/png/avif)=%u/%u/%u/%u/%u slowestBody=%.0fms bytes=%lu rate=%.1fKiB/s format=%@ scale=%ux",
            names[i],(unsigned long long)p->payloadBytes,(unsigned long)p->maxPayload,(unsigned long long)p->wireBytes,p->cellular,
            p->formats[0],p->formats[1],p->formats[2],p->formats[3],p->formats[4],1000*p->slowBody,
            (unsigned long)p->slowPayload,p->slowBody > 0 ? p->slowPayload/1024.0/p->slowBody : 0,formats[p->slowFormat],p->slowScale];
    }
}
static NSDictionary *ImageHeaders(NSHTTPURLResponse *response) {
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (id key in response.allHeaderFields) {
        if (![key isKindOfClass:NSString.class]) return nil;
        NSString *name = [key lowercaseString];
        if (headers[name]) return nil;
        headers[name] = [response.allHeaderFields[key] description];
    }
    return headers;
}
static BOOL CacheRequest(NSURLRequest *request) {
    if (request.cachePolicy != NSURLRequestUseProtocolCachePolicy) return NO;
    for (NSString *name in request.allHTTPHeaderFields) {
        NSString *lower = name.lowercaseString;
        if ([lower hasPrefix:@"if-"] || [@[@"cache-control", @"pragma", @"authorization", @"cookie", @"range"] containsObject:lower]) return NO;
    }
    return YES;
}
static BOOL CacheVary(NSDictionary *headers, NSURLRequest *request) {
    unsigned mask = ImageVaryRequirements([headers[@"vary"] UTF8String]);
    if (mask == UINT32_MAX) return NO;
    NSArray *fields = @[@"User-Agent", @"Accept-Encoding", @"Accept-Language", @"Accept"];
    for (unsigned i = 0; i < 4; ++i)
        if ((mask & (1u << i)) && ![request valueForHTTPHeaderField:fields[i]].length) return NO;
    return YES;
}
static NSDictionary *CacheHeaders(NSHTTPURLResponse *response, NSURLRequest *request, double *lifetime, double *age, double *dateAge, unsigned *reason) {
    *reason = 0;
    NSDictionary *headers = ImageHeaders(response);
    if (!headers || headers[@"pragma"] || headers[@"set-cookie"] || headers[@"content-range"]) return nil;
    *reason = 1; if (!CacheVary(headers,request)) return nil;
    *reason = 2; if (!ImageMaxAge([headers[@"cache-control"] UTF8String], lifetime)) return nil;
    *reason = 3;
    NSString *ageText = headers[@"age"];
    *age = 0; *dateAge = 0;
    if (ageText) {
        if (!ageText.length || ageText.length > 10) return nil;
        for (NSUInteger i = 0; i < ageText.length; ++i) {
            unichar c = [ageText characterAtIndex:i]; if (c < '0' || c > '9') return nil;
            *age = *age*10 + c-'0';
        }
        if (*age > 2147483647) return nil;
    }
    if (headers[@"date"]) {
        *reason = 4;
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'"; formatter.lenient = NO;
        NSDate *date = [formatter dateFromString:headers[@"date"]];
        if (!date || ![[formatter stringFromDate:date] isEqual:headers[@"date"]]) return nil;
        *dateAge = -date.timeIntervalSinceNow;
        if (*dateAge < 0) return nil;
    }
    return headers;
}

BOOL TPKEmoteImageProviderURL(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || url.user || url.password || url.port) return NO;
    static NSSet<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hosts = [NSSet setWithArray:@[@"cdn.7tv.app", @"cdn.7tv.io", @"cdn.betterttv.net", @"cdn.frankerfacez.com"]]; });
    return [hosts containsObject:url.host.lowercaseString];
}
static NSError *TransportError(NSInteger code) {
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
}
static void Reject(TPKEmoteImageProtocol *consumer) {
    ++stats.errors;
    unsigned provider = ProviderIndex(consumer.request.URL);
    ++providers[provider].rejected;
    RecordFailure(provider,TransportError(NSURLErrorResourceUnavailable),0,NO,YES);
    ImageStatsLog();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [consumer deliver:nil response:nil error:TransportError(NSURLErrorResourceUnavailable)];
    });
}
static BOOL PublicImageRequest(NSURLRequest *request) {
    return TPKEmoteImageProviderURL(request.URL) && [request.HTTPMethod isEqualToString:@"GET"] &&
        !request.HTTPBody.length && !request.HTTPBodyStream &&
        ![request valueForHTTPHeaderField:@"Authorization"] && ![request valueForHTTPHeaderField:@"Cookie"] &&
        ![request valueForHTTPHeaderField:@"Range"];
}
static BOOL ImageResponse(NSURLResponse *response) {
    return [response isKindOfClass:NSHTTPURLResponse.class] && [(NSHTTPURLResponse *)response statusCode] == 200 &&
        [response.MIMEType.lowercaseString hasPrefix:@"image/"];
}
static NSURLSessionConfiguration *OuterConfiguration(NSURLSessionConfiguration *configuration) {
    if (!configuration || configuration.identifier || [configuration.protocolClasses containsObject:TPKEmoteImageProtocol.class]) return configuration;
    NSURLSessionConfiguration *copy = configuration.copy;
    copy.protocolClasses = [@[TPKEmoteImageProtocol.class] arrayByAddingObjectsFromArray:copy.protocolClasses ?: @[]];
    return copy;
}
static id Session(id cls, SEL selector, NSURLSessionConfiguration *configuration) {
    return originalSession(cls, selector, OuterConfiguration(configuration));
}
static id SessionDelegate(id cls, SEL selector, NSURLSessionConfiguration *configuration, id delegate, NSOperationQueue *queue) {
    return originalSessionDelegate(cls, selector, OuterConfiguration(configuration), delegate, queue);
}
static NSURLSession *InnerSession(void) {
    if (!innerSession) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.protocolClasses = @[];
        configuration.URLCache = TPKURLProtocol.sharedEmoteCache;
        configuration.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        configuration.HTTPMaximumConnectionsPerHost = TPKImageTransfers;
        configuration.timeoutIntervalForRequest = 15;
        configuration.timeoutIntervalForResource = 30;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCredentialStorage = nil;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
        innerSession = originalSessionDelegate(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:),
            configuration, [TPKImageSessionDelegate new], queue);
    }
    return innerSession;
}
static void RecordCacheReceipt(TPKImageFlight *flight) {
    NSURLSessionTaskMetrics *metrics = flight.metrics;
    if (!flight.proposal || metrics.redirectCount || metrics.transactionMetrics.count != 1 || !CacheRequest(flight.request)) { ++stats.proofSkip; return; }
    NSURLSessionTaskTransactionMetrics *transaction = metrics.transactionMetrics.firstObject;
    if (transaction.resourceFetchType != NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad ||
        !ImageResponse(transaction.response) || ![transaction.request.URL isEqual:flight.request.URL] ||
        ![transaction.response.URL isEqual:flight.response.URL]) { ++stats.proofSkip; return; }
    double lifetime = 0, age = 0, dateAge = 0;
    unsigned reason = 0;
    NSDictionary *headers = CacheHeaders((NSHTTPURLResponse *)flight.response, flight.request, &lifetime, &age, &dateAge, &reason);
    if (!headers || ![headers isEqual:ImageHeaders((NSHTTPURLResponse *)transaction.response)]) {
        ++stats.headerSkip; ++stats.headerReasons[headers ? 5 : reason]; return;
    }
    double tick = ImageTick(), remaining = ImageFreshSeconds(lifetime, age, dateAge, tick-flight.startedAt, 0);
    if (remaining <= 0) { ++stats.headerSkip; ++stats.headerReasons[6]; return; }
    NSCachedURLResponse *stored = [TPKURLProtocol.sharedEmoteCache cachedResponseForRequest:flight.request];
    if (!stored || stored.storagePolicy == NSURLCacheStorageNotAllowed || !ImageResponse(stored.response) ||
        ![stored.response.URL isEqual:flight.response.URL] || ![headers isEqual:ImageHeaders((NSHTTPURLResponse *)stored.response)] ||
        !ImageResponse(flight.proposal.response) || ![flight.proposal.response.URL isEqual:flight.response.URL] ||
        ![headers isEqual:ImageHeaders((NSHTTPURLResponse *)flight.proposal.response)] ||
        stored.storagePolicy != flight.proposal.storagePolicy ||
        ![stored.data isEqualToData:flight.proposal.data] || ![stored.data isEqualToData:flight.data]) { ++stats.storeSkip; return; }
    NSMutableDictionary *info = [stored.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    info[@"TPKImageReceipt"] = @{@"epoch":cacheEpoch, @"tick":@(tick), @"wall":@(NSDate.date.timeIntervalSince1970),
        @"remaining":@(remaining), @"headers":flight.request.allHTTPHeaderFields ?: @{}, @"response":headers};
    NSCachedURLResponse *annotated = [[NSCachedURLResponse alloc] initWithResponse:stored.response data:stored.data
        userInfo:info storagePolicy:stored.storagePolicy];
    [TPKURLProtocol.sharedEmoteCache storeCachedResponse:annotated forRequest:flight.request];
    ++stats.receipts;
}
static NSCachedURLResponse *FastCached(TPKImageFlight *flight, NSString *epoch, BOOL *candidate) {
    if (!CacheRequest(flight.request)) return nil;
    NSCachedURLResponse *cached = [TPKURLProtocol.sharedEmoteCache cachedResponseForRequest:flight.request];
    *candidate = cached && cached.storagePolicy != NSURLCacheStorageNotAllowed && ImageResponse(cached.response) &&
        cached.data.length && cached.data.length <= maxImageBytes && [cached.response.URL isEqual:flight.request.URL];
    NSDictionary *receipt = cached.userInfo[@"TPKImageReceipt"];
    if (![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"epoch"] isEqual:epoch] ||
        cached.storagePolicy == NSURLCacheStorageNotAllowed || !ImageResponse(cached.response) ||
        !cached.data.length || cached.data.length > maxImageBytes || ![cached.response.URL isEqual:flight.request.URL] ||
        ![receipt[@"headers"] isEqual:flight.request.allHTTPHeaderFields ?: @{}] ||
        ![receipt[@"response"] isEqual:ImageHeaders((NSHTTPURLResponse *)cached.response)] ||
        !CacheVary(receipt[@"response"],flight.request)) return nil;
    double wall = NSDate.date.timeIntervalSince1970 - [receipt[@"wall"] doubleValue];
    double tick = ImageTick() - [receipt[@"tick"] doubleValue];
    if (wall < 0 || tick < 0 || ImageFreshSeconds([receipt[@"remaining"] doubleValue], 0, 0, 0, MAX(wall,tick)) <= 0) return nil;
    return cached;
}
static void Finish(TPKImageFlight *flight, NSError *error) {
    if (flights[flight.key] != flight) return;
    if (!error && (!flight.data.length || !ImageResponse(flight.response))) error = TransportError(NSURLErrorBadServerResponse);
    NSArray<TPKEmoteImageProtocol *> *consumers = flight.consumers.copy;
    [flights removeObjectForKey:flight.key];
    if (flight.task) [tasks removeObjectForKey:flight.task];
    double completed = ImageTick();
    if (flight.startedAt) {
        if (!flight.metrics) ++stats.unknown;
        double load = completed-flight.startedAt, wait = flight.startedAt-flight.queuedAt;
        ++stats.loads; stats.loadSum += load; stats.loadMax = MAX(stats.loadMax,load);
        stats.queueSum += wait; stats.queueMax = MAX(stats.queueMax,wait);
        if (!error && flight.data.length && ImageResponse(flight.response)) RecordCacheReceipt(flight);
        if (!error && flight.data.length) {
            TPKImageProviderStats *provider = &providers[flight.provider];
            provider->payloadBytes += flight.data.length;
            provider->maxPayload = MAX(provider->maxPayload,flight.data.length);
            NSString *type = flight.response.MIMEType.lowercaseString;
            unsigned format = [type isEqualToString:@"image/webp"] ? 1 : [type isEqualToString:@"image/gif"] ? 2 :
                [type isEqualToString:@"image/png"] ? 3 : [type isEqualToString:@"image/avif"] ? 4 : 0;
            ++provider->formats[format];
            NSURLSessionTaskTransactionMetrics *t = flight.metrics.transactionMetrics.lastObject;
            double body = t.responseStartDate && t.responseEndDate ? [t.responseEndDate timeIntervalSinceDate:t.responseStartDate] : 0;
            if (isfinite(body) && body > provider->slowBody) {
                provider->slowBody = body; provider->slowPayload = flight.data.length; provider->slowFormat = format;
                NSInteger scale = flight.providerURL.lastPathComponent.integerValue;
                provider->slowScale = scale >= 1 && scale <= 4 ? (unsigned)scale : 0;
            }
        }
    }
    if (error) {
        ++stats.errors;
        NSInteger status = [flight.response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)flight.response statusCode] : 0;
        RecordFailure(flight.provider,error,status,flight.proxy,!flight.startedAt);
        if (flight.startedAt) {
            TPKImageProviderStats *provider = &providers[flight.provider];
            provider->failureBytes = flight.data.length;
            provider->expectedBytes = flight.response ? flight.response.expectedContentLength : -1;
            provider->failureLoad = completed-flight.startedAt;
            NSURLSessionTaskTransactionMetrics *t = flight.metrics.transactionMetrics.lastObject;
            provider->failureProtocol = ProtocolIndex(t.networkProtocolName);
            provider->failureStage = status >= 400 ? 7 : t.responseStartDate || flight.response ? 6 : t.requestEndDate ? 5 :
                t.secureConnectionStartDate && !t.secureConnectionEndDate ? 4 :
                t.connectStartDate && !t.connectEndDate ? 3 : t.domainLookupStartDate && !t.domainLookupEndDate ? 2 : 0;
        }
    }
    ImageFinish(&schedule, flight.slot);
    NSData *data = flight.data;
    NSURLResponse *response = flight.response;
    flight.task = nil; flight.data = nil;
    [flight.consumers removeAllObjects];
    if (!error && data.length && ImageResponse(response) &&
        [TPKURLProtocol.sharedEmoteCache cachedResponseForRequest:flight.request].data.length)
        [TPKURLProtocol noteCachedEmoteImageURL:flight.providerURL];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (TPKEmoteImageProtocol *consumer in consumers) [consumer deliver:data response:response error:error];
        double delivery = ImageTick()-completed;
        dispatch_async(transportQueue, ^{
            statsDirty = YES;
            ++stats.deliveries; stats.deliverySum += delivery; stats.deliveryMax = MAX(stats.deliveryMax,delivery);
            ImageStatsLog();
        });
    });
}
static void Pump(void) {
    int slot;
    while ((slot = ImageNext(&schedule)) >= 0) {
        TPKImageFlight *flight = nil;
        for (TPKImageFlight *candidate in flights.allValues) if (candidate.slot == (unsigned)slot) { flight = candidate; break; }
        if (!flight) { ImageFinish(&schedule, (unsigned)slot); continue; }
        if (ImageTick() - flight.queuedAt > 15) {
            Finish(flight, TransportError(NSURLErrorTimedOut)); continue;
        }
        NSMutableURLRequest *request = flight.request.mutableCopy;
        [NSURLProtocol setProperty:@YES forKey:internalKey inRequest:request];
        flight.request = request;
        flight.data = [NSMutableData data];
        flight.startedAt = ImageTick();
        flight.task = [InnerSession() dataTaskWithRequest:request];
        [tasks setObject:flight forKey:flight.task];
        [flight.task resume];
    }
}
static void CheckCache(TPKImageFlight *flight) {
    NSString *epoch = cacheEpoch;
    double enqueued = ImageTick();
    flight.cacheChecked = YES;
    schedule.slots[flight.slot].checking = YES;
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        @autoreleasepool {
            BOOL candidate = NO;
            NSCachedURLResponse *cached = FastCached(flight, epoch, &candidate);
            double elapsed = ImageTick()-enqueued;
            dispatch_async(transportQueue, ^{
                if (flights[flight.key] != flight) return;
                ++stats.lookups; stats.lookupSum += elapsed; stats.lookupMax = MAX(stats.lookupMax,elapsed);
                schedule.slots[flight.slot].checking = NO;
                schedule.slots[flight.slot].cached = candidate;
                if (candidate) ++stats.candidates;
                if (cached) {
                    ++stats.direct; flight.response = cached.response; flight.data = (NSMutableData *)cached.data;
                    Finish(flight, nil);
                } else {
                    ++stats.fallback;
                    flight.queuedAt = ImageTick();
                }
                Pump();
            });
        }
    }];
    flight.lookup = operation;
    [cacheQueue addOperation:operation];
}

@implementation TPKEmoteImageProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return ![NSURLProtocol propertyForKey:internalKey inRequest:request] && PublicImageRequest(request);
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    if (request.cachePolicy != NSURLRequestReloadIgnoringLocalCacheData) return request;
    NSMutableURLRequest *copy = request.mutableCopy;
    copy.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    return copy;
}
- (void)startLoading {
    dispatch_async(transportQueue, ^{
        @synchronized (self) { if (self.stopped) return; }
        ++stats.requests;
        statsDirty = YES;
        NSMutableURLRequest *request = [[TPKEmoteImageProtocol canonicalRequestForRequest:self.request] mutableCopy];
        if (![request valueForHTTPHeaderField:@"Accept-Encoding"])
            [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        request.URL = TPKEmoteProxyRewriteURL(request.URL) ?: request.URL;
        NSArray *key = @[request.URL.absoluteString, @(request.cachePolicy), request.allHTTPHeaderFields ?: @{}];
        TPKImageFlight *flight = flights[key];
        if (flight) {
            if (!ImageJoin(&schedule, flight.slot)) {
                Reject(self); return;
            }
            ++stats.joins;
        } else {
            int slot = ImageAdmit(&schedule);
            if (slot < 0) { Reject(self); return; }
            flight = [TPKImageFlight new]; flight.slot = (unsigned)slot; flight.key = key; flight.request = request;
            flight.providerURL = self.request.URL;
            flight.provider = ProviderIndex(self.request.URL);
            flight.proxy = ![request.URL isEqual:self.request.URL];
            flight.queuedAt = ImageTick();
            flight.consumers = [NSMutableArray array]; flights[key] = flight;
        }
        self.flight = flight; [flight.consumers addObject:self];
        if (!flight.cacheChecked) CheckCache(flight);
        Pump();
        ImageStatsLog();
    });
}
- (void)stopLoading {
    @synchronized (self) { self.stopped = YES; }
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = self.flight;
        if (!flight || flights[flight.key] != flight || ![flight.consumers containsObject:self]) return;
        [flight.consumers removeObjectIdenticalTo:self]; self.flight = nil;
        ++stats.cancelled;
        statsDirty = YES;
        if (ImageLeave(&schedule, flight.slot)) { [flight.lookup cancel]; [flights removeObjectForKey:flight.key]; }
        Pump();
        ImageStatsLog();
    });
}
- (void)deliver:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    @synchronized (self) {
        if (self.stopped) return;
        if (error || !data.length || !ImageResponse(response)) {
            self.stopped = YES; [self.client URLProtocol:self didFailWithError:error ?: TransportError(NSURLErrorBadServerResponse)]; return;
        }
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (self.stopped) return;
        [self.client URLProtocol:self didLoadData:data];
        if (self.stopped) return;
        self.stopped = YES; [self.client URLProtocolDidFinishLoading:self];
    }
}
@end

@implementation TPKImageSessionDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = [tasks objectForKey:task];
        if (flight) flight.response = response;
        if (!flight || !ImageResponse(response) || response.expectedContentLength > (int64_t)maxImageBytes) {
            if (flight) flight.error = TransportError(response.expectedContentLength > (int64_t)maxImageBytes
                ? NSURLErrorDataLengthExceedsMaximum : NSURLErrorBadServerResponse);
            completion(NSURLSessionResponseCancel); return;
        }
        completion(NSURLSessionResponseAllow);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = [tasks objectForKey:task];
        if (!flight || flight.error) return;
        if (data.length > maxImageBytes - flight.data.length) {
            flight.error = TransportError(NSURLErrorDataLengthExceedsMaximum); [task cancel]; return;
        }
        [flight.data appendData:data];
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = [tasks objectForKey:task];
        if (flight) Finish(flight, flight.error ?: error);
        Pump();
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = [tasks objectForKey:task];
        if (!flight) return;
        flight.metrics = metrics;
        statsDirty = YES;
        if (!metrics.transactionMetrics.count) ++stats.unknown;
        for (NSURLSessionTaskTransactionMetrics *transaction in metrics.transactionMetrics) {
            TPKImageProviderStats *provider = &providers[flight.provider];
            if (transaction.resourceFetchType == NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad) {
                ++stats.network; ++provider->network;
                RecordPhase(provider,0,transaction.domainLookupStartDate,transaction.domainLookupEndDate);
                RecordPhase(provider,1,transaction.connectStartDate,transaction.connectEndDate);
                RecordPhase(provider,2,transaction.secureConnectionStartDate,transaction.secureConnectionEndDate);
                RecordPhase(provider,3,transaction.requestEndDate,transaction.responseStartDate);
                RecordPhase(provider,4,transaction.responseStartDate,transaction.responseEndDate);
                provider->protocol = ProtocolIndex(transaction.networkProtocolName);
                if (transaction.countOfResponseBodyBytesReceived > 0)
                    provider->wireBytes += (uint64_t)transaction.countOfResponseBodyBytesReceived;
                if (transaction.isCellular) ++provider->cellular;
            }
            else if (transaction.resourceFetchType == NSURLSessionTaskMetricsResourceFetchTypeLocalCache) { ++stats.local; ++provider->local; }
            else ++stats.unknown;
        }
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    willCacheResponse:(NSCachedURLResponse *)response completionHandler:(void (^)(NSCachedURLResponse *))completion {
    dispatch_async(transportQueue, ^{
        TPKImageFlight *flight = [tasks objectForKey:task];
        if (flight && session == innerSession) flight.proposal = response;
        completion(session == innerSession && ImageResponse(response.response) && response.data.length <= maxImageBytes ? response : nil);
    });
}
@end

void TPKEmoteImageTransportSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        transportQueue = dispatch_queue_create("tpk.emote-image-transport", DISPATCH_QUEUE_SERIAL);
        cacheQueue = [NSOperationQueue new]; cacheQueue.maxConcurrentOperationCount = 2;
        cacheQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        cacheEpoch = ImageCacheEpoch();
        stats.lastLog = ImageTick();
        flights = [NSMutableDictionary dictionary];
        tasks = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                    valueOptions:NSPointerFunctionsStrongMemory];
        Method plain = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:));
        Method delegate = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:));
        originalSession = (void *)method_setImplementation(plain, (IMP)Session);
        originalSessionDelegate = (void *)method_setImplementation(delegate, (IMP)SessionDelegate);
    });
}
NSURLSession *TPKEmoteImageSession(void) {
    TPKEmoteImageTransportSetup();
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration]; });
    return session;
}
void TPKEmoteImageTransportClear(void) {
    TPKEmoteImageTransportSetup();
    dispatch_async(transportQueue, ^{
        [cacheQueue cancelAllOperations];
        [innerSession invalidateAndCancel]; innerSession = nil;
        for (TPKImageFlight *flight in flights.allValues.copy) Finish(flight, TransportError(NSURLErrorCancelled));
        [tasks removeAllObjects];
    });
}

NSString *const TPKEmoteCacheCountDidChangeNotification = @"TPKEmoteCacheCountDidChangeNotification";
static NSString *const indexKey = @"tpk_cached_emote_identities", *const legacyIndexKey = @"tpk_cached_emote_ids";
static dispatch_queue_t indexQueue;
static NSMutableSet<NSString *> *imageIndex;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *indexedURLs;
static NSString *const imageURLsKey = @"tpk_cached_emote_urls";
static BOOL savePending;
static NSUInteger indexGeneration;
static _Atomic(NSInteger) indexedCount;

static dispatch_queue_t ImageIndexQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        indexQueue = dispatch_queue_create("tpk.emote-image-index", DISPATCH_QUEUE_SERIAL);
        imageIndex = [NSMutableSet set];
        indexedURLs = [NSMutableDictionary dictionary];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id savedURLs = [defaults objectForKey:imageURLsKey];
        if ([savedURLs isKindOfClass:NSDictionary.class]) {
            for (NSString *identity in savedURLs) {
                id urls = savedURLs[identity];
                if (![identity isKindOfClass:NSString.class] || ![urls isKindOfClass:NSArray.class]) continue;
                NSMutableSet *valid = [NSMutableSet set];
                for (id url in urls)
                    if ([url isKindOfClass:NSString.class] && TPKEmoteImageProviderURL([NSURL URLWithString:url])) [valid addObject:url];
                if (valid.count) indexedURLs[identity] = valid;
            }
        }
        for (id value in [defaults arrayForKey:indexKey])
            if ([value isKindOfClass:NSString.class] && [value containsString:@":"]) [imageIndex addObject:value];
        for (id value in [defaults arrayForKey:legacyIndexKey])
            if ([value isKindOfClass:NSString.class] && [value length])
                [imageIndex addObject:[@"7tv:" stringByAppendingString:value]];
        [imageIndex intersectSet:[NSSet setWithArray:indexedURLs.allKeys]];
        indexedCount = imageIndex.count;
    });
    return indexQueue;
}
static void ImageIndexNotify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:TPKEmoteCacheCountDidChangeNotification object:nil];
    });
}
static void ImageIndexSave(void) {
    indexedCount = imageIndex.count;
    if (savePending) return;
    savePending = YES;
    NSUInteger generation = indexGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * .75), indexQueue, ^{
        if (generation != indexGeneration) return;
        savePending = NO;
        NSMutableArray *legacy = [NSMutableArray array];
        for (NSString *identity in imageIndex)
            if ([identity hasPrefix:@"7tv:"]) [legacy addObject:[identity substringFromIndex:4]];
        [NSUserDefaults.standardUserDefaults setObject:imageIndex.allObjects forKey:indexKey];
        [NSUserDefaults.standardUserDefaults setObject:legacy forKey:legacyIndexKey];
        NSMutableDictionary *urls = [NSMutableDictionary dictionary];
        for (NSString *identity in indexedURLs) urls[identity] = indexedURLs[identity].allObjects;
        [NSUserDefaults.standardUserDefaults setObject:urls forKey:imageURLsKey];
        ImageIndexNotify();
    });
}
static NSString *ImageIdentity(NSURL *url) {
    NSString *host = url.host.lowercaseString, *provider = nil;
    NSDictionary *domains = @{@"7tv.app":@"7tv", @"7tv.io":@"7tv", @"betterttv.net":@"bttv", @"frankerfacez.com":@"ffz"};
    for (NSString *domain in domains)
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) { provider = domains[domain]; break; }
    if (!provider) return nil;
    NSArray *parts = url.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; ++i)
        if ([@[@"emote", @"emoticon"] containsObject:[parts[i] lowercaseString]] && [parts[i+1] length])
            return [NSString stringWithFormat:@"%@:%@", provider, parts[i+1]];
    return nil;
}
static BOOL StoredImage(NSURL *url) {
    if (!url) return NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:TPKEmoteProxyRewriteURL(url) ?: url];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    NSURLCache *cache = TPKURLProtocol.sharedEmoteCache;
    NSCachedURLResponse *cached = [cache cachedResponseForRequest:request];
    if (!cached.data.length) { request.URL = url; cached = [cache cachedResponseForRequest:request]; }
    if (!cached.data.length) { request.allHTTPHeaderFields = nil; cached = [cache cachedResponseForRequest:request]; }
    if (!cached.data.length) return NO;
    if ([cached.response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger code = [(NSHTTPURLResponse *)cached.response statusCode];
        if (code < 200 || code >= 300) return NO;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)cached.data, NULL);
    BOOL valid = source && CGImageSourceGetCount(source) > 0;
    if (source) CFRelease(source);
    return valid;
}
@implementation TPKURLProtocol
+ (NSURLCache *)sharedEmoteCache {
    static NSURLCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSURLCache alloc] initWithMemoryCapacity:30*1024*1024 diskCapacity:500*1024*1024 diskPath:@"tpk_cdn_cache"];
    });
    return cache;
}
+ (NSInteger)cachedEmoteCount { ImageIndexQueue(); return indexedCount; }
+ (void)noteCachedEmoteImageURL:(NSURL *)url {
    NSString *identity = ImageIdentity(url);
    if (!identity) return;
    dispatch_async(ImageIndexQueue(), ^{
        NSMutableSet *urls = indexedURLs[identity];
        if (!urls) indexedURLs[identity] = urls = [NSMutableSet set];
        if (![urls containsObject:url.absoluteString] || ![imageIndex containsObject:identity]) {
            [urls addObject:url.absoluteString];
            [imageIndex addObject:identity];
            ImageIndexSave();
        }
    });
}
+ (void)refreshCachedEmoteCountWithCompletion:(void (^)(NSInteger))completion {
    [self refreshCachedEmoteCountForImageURLs:@[] completion:completion];
}
+ (void)refreshCachedEmoteCountForImageURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSInteger))completion {
    NSArray *snapshot = urls.copy;
    dispatch_async(ImageIndexQueue(), ^{
        for (NSURL *url in [NSSet setWithArray:snapshot ?: @[]]) {
            if (![url isKindOfClass:NSURL.class]) continue;
            NSString *identity = ImageIdentity(url);
            if (!identity) continue;
            if (!indexedURLs[identity]) indexedURLs[identity] = [NSMutableSet set];
            [indexedURLs[identity] addObject:url.absoluteString];
        }
        [imageIndex removeAllObjects];
        for (NSString *identity in indexedURLs.allKeys) {
            NSMutableSet *urls = indexedURLs[identity];
            for (NSString *value in urls.allObjects)
                if (!StoredImage([NSURL URLWithString:value])) [urls removeObject:value];
            if (urls.count) [imageIndex addObject:identity];
            else { [imageIndex removeObject:identity]; [indexedURLs removeObjectForKey:identity]; }
        }
        ImageIndexSave();
        NSInteger count = indexedCount;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(count); });
    });
}
+ (void)clearAllEmoteCachesWithCompletion:(void (^)(NSUInteger))completion {
    NSUInteger count = self.cachedEmoteCount;
    TPKEmoteImageTransportClear();
    // Remove only after invalidation and earlier index updates finish.
    dispatch_async(transportQueue, ^{
        dispatch_async(ImageIndexQueue(), ^{
            ++indexGeneration; savePending = NO;
            [self.sharedEmoteCache removeAllCachedResponses]; [imageIndex removeAllObjects]; [indexedURLs removeAllObjects]; indexedCount = 0;
            [NSUserDefaults.standardUserDefaults removeObjectForKey:indexKey];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:legacyIndexKey];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:imageURLsKey];
            ImageIndexNotify();
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(count); });
        });
    });
}
@end
