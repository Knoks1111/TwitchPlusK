/*
 * Video proxy engine derived from TwitchAdBlock v0.1.13 (MIT).
 * See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL TPKAdblockIsAdHost(NSString * _Nullable host);
BOOL TPKAdblockIsPlaylistHost(NSString * _Nullable host);
BOOL TPKAdblockIsMasterPlaylistHost(NSString * _Nullable host);
BOOL TPKAdblockIsExternalPlayback(void);
BOOL TPKAdblockIsInternalProxyDispatch(void);

NSString * _Nullable TPKAdblockBasicAuthHeader(NSURL *proxyURL);
NSURL *TPKAdblockRewriteURLThroughProxy(NSURL *URL, NSURL *proxyURL);
// YES si proxy style préfixe (ex: rte.net.ru). Sonde <base>https://google.com (2xx), avec cache.
BOOL TPKAdblockProxyIsPrefixStyle(NSURL *proxyURL);
NSURLSession *TPKAdblockProxySession(NSURLSession *session, NSString *address);
// Forget cached Luminous V1 detection results after the selected endpoint or
// the custom proxy order changes. The next playlist request will probe again.
void TPKAdblockInvalidateProxyDetectionCache(void);

// Applies domain blocking, GQL playback-token spoofing and Luminous V1 URL
// rewriting. `blocked` is set when the caller must return a nil task.
NSURLRequest *TPKAdblockPrepareRequest(NSURLRequest *request, BOOL *blocked);

// Standard HTTP CONNECT fallback used when the configured endpoint does not
// expose Luminous V1. Returns nil when routing is unnecessary or impossible.
NSURLSessionDataTask * _Nullable TPKAdblockCreateConnectTaskIfNeeded(
    NSURLSession *session, NSURLRequest *request);
NSURLSessionDataTask * _Nullable TPKAdblockCreateConnectTaskWithCompletionIfNeeded(
    NSURLSession *session, NSURLRequest *request,
    void (^ _Nullable completion)(NSData * _Nullable, NSURLResponse * _Nullable,
                                   NSError * _Nullable));

NS_ASSUME_NONNULL_END
