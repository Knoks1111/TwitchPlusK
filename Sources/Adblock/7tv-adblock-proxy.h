/*
 * Video proxy engine derived from TwitchAdBlock v0.1.13 (MIT).
 * See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL S7TVAdblockIsAdHost(NSString * _Nullable host);
BOOL S7TVAdblockIsPlaylistHost(NSString * _Nullable host);
BOOL S7TVAdblockIsMasterPlaylistHost(NSString * _Nullable host);
BOOL S7TVAdblockIsExternalPlayback(void);
BOOL S7TVAdblockIsInternalProxyDispatch(void);

NSString * _Nullable S7TVAdblockBasicAuthHeader(NSURL *proxyURL);
NSURL *S7TVAdblockRewriteURLThroughProxy(NSURL *URL, NSURL *proxyURL);
NSURLSession *S7TVAdblockProxySession(NSURLSession *session, NSString *address);

// Applies domain blocking, GQL playback-token spoofing and Luminous V1 URL
// rewriting. `blocked` is set when the caller must return a nil task.
NSURLRequest *S7TVAdblockPrepareRequest(NSURLRequest *request, BOOL *blocked);

// Standard HTTP CONNECT fallback used when the configured endpoint does not
// expose Luminous V1. Returns nil when routing is unnecessary or impossible.
NSURLSessionDataTask * _Nullable S7TVAdblockCreateConnectTaskIfNeeded(
    NSURLSession *session, NSURLRequest *request);
NSURLSessionDataTask * _Nullable S7TVAdblockCreateConnectTaskWithCompletionIfNeeded(
    NSURLSession *session, NSURLRequest *request,
    void (^ _Nullable completion)(NSData * _Nullable, NSURLResponse * _Nullable,
                                   NSError * _Nullable));

NS_ASSUME_NONNULL_END
