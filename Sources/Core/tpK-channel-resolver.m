#import "Core/tpK-channel-resolver.h"
#import "Core/tpK-core-manager.h"
#import "System/tpK-system-player-reload.h"
#import <objc/message.h>

#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void tpk_resolverLog(NSString *format, ...) {
    TPKManager *manager = TPKManager.sharedManager;
    if (!manager.logsEnabled || !manager.logChannelResolver) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [manager log:@"[ChannelResolver] 🧭 %@", message];
}

static uint32_t TPKResolverParseChannelID(const char *text) {
    if (!text || !*text) return 0;
    uint32_t value = 0;
    for (const char *p = text; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        unsigned digit = (unsigned)(*p - '0');
        if (value > (UINT32_MAX - digit) / 10) return 0;
        value = value * 10 + digit;
    }
    return value;
}

static BOOL TPKResolverCanApplyIdentity(uint32_t expectedID, uint32_t returnedID,
                                      NSUInteger requestGeneration, NSUInteger currentGeneration,
                                      BOOL sameSession, BOOL requestMatches) {
    return expectedID && expectedID == returnedID && requestGeneration == currentGeneration &&
           sameSession && requestMatches;
}

NSNotificationName const TPKChannelResolverDidChangeNotification =
    @"TPKChannelResolverDidChangeNotification";

@interface TPKChannelContext ()

- (instancetype)initWithChannelID:(uint32_t)channelID
                      channelName:(nullable NSString *)channelName
                       displayName:(nullable NSString *)displayName
                         mediaKind:(TPKChannelMediaKind)mediaKind
                            source:(TPKChannelSource)source
                         sessionID:(NSUUID *)sessionID
                        sessionKey:(nullable NSString *)sessionKey
                        generation:(NSUInteger)generation
                      sourceObject:(nullable id)sourceObject;

@end

@interface TPKChannelResolver () {
    NSLock *_lock;
    TPKChannelContext *_currentContext;
    NSUInteger _generationCounter;
    uint32_t _nativeActiveLiveChannelID;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_nativeConnectionIdentities;
}

- (NSUInteger)tpk_nextGenerationLocked;

@end

@interface TPKChannelResolver (TPKNativeState)

- (void)tpk_setNativeActiveLiveChannelID:(uint32_t)channelID
                             sourceObject:(nullable id)sourceObject;
- (void)tpk_updateNativeIdentityForChannelID:(uint32_t)channelID
                                  channelName:(nullable NSString *)channelName
                                 displayName:(nullable NSString *)displayName
                                sourceObject:(nullable id)sourceObject;
- (void)tpk_clearNativeLiveChannel;

@end

static NSString *tpk_trimString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;

    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : nil;
}

static NSString *tpk_channelName(NSString *value) {
    return tpk_trimString(value).lowercaseString;
}

static BOOL tpk_isResolverLogin(NSString *login) {
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"].invertedSet;
    });
    return login.length && [login rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL tpk_sameString(NSString *left, NSString *right) {
    if (left == right) return YES;
    if (!left || !right) return NO;
    return [left isEqualToString:right];
}

static BOOL tpk_sameContextIdentity(TPKChannelContext *context,
                                     uint32_t channelID,
                                     TPKChannelMediaKind mediaKind,
                                     NSString *sessionKey) {
    return context &&
        context.channelID == channelID &&
        context.mediaKind == mediaKind &&
        tpk_sameString(context.sessionKey, sessionKey);
}

static BOOL tpk_sameContextMetadata(TPKChannelContext *left,
                                      TPKChannelContext *right) {
    if (!left || !right) return left == right;

    return left.channelID == right.channelID &&
        left.mediaKind == right.mediaKind &&
        left.source == right.source &&
        tpk_sameString(left.channelName, right.channelName) &&
        tpk_sameString(left.displayName, right.displayName) &&
        tpk_sameString(left.sessionKey, right.sessionKey);
}

static void tpk_postContextChange(TPKChannelResolver *resolver,
                                   TPKChannelContext *context,
                                   NSUInteger generation) {
    tpk_resolverLog(@"context id=%u login=%@ kind=%lu source=%lu generation=%lu", context.channelID,
                   context.channelName ?: @"-", (unsigned long)context.mediaKind,
                   (unsigned long)context.source, (unsigned long)generation);
    NSDictionary *userInfo = context
        ? @{@"context": context, @"generation": @(generation)}
        : @{@"generation": @(generation)};

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKChannelResolverDidChangeNotification
                          object:resolver
                        userInfo:userInfo];
    });
}

@implementation TPKChannelContext

- (instancetype)initWithChannelID:(uint32_t)channelID
                      channelName:(NSString *)channelName
                       displayName:(NSString *)displayName
                         mediaKind:(TPKChannelMediaKind)mediaKind
                            source:(TPKChannelSource)source
                         sessionID:(NSUUID *)sessionID
                        sessionKey:(NSString *)sessionKey
                        generation:(NSUInteger)generation
                      sourceObject:(id)sourceObject {
    self = [super init];
    if (!self) return nil;

    _channelID = channelID;
    _channelName = [tpk_channelName(channelName) copy];
    _displayName = [tpk_trimString(displayName) copy];
    _mediaKind = mediaKind;
    _source = source;
    _sessionID = [sessionID copy];
    _sessionKey = [tpk_trimString(sessionKey) copy];
    _generation = generation;
    _sourceObject = sourceObject;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)matchesChannelID:(uint32_t)channelID {
    return channelID != 0 && _channelID == channelID;
}

@end

@implementation TPKChannelResolver

+ (instancetype)sharedResolver {
    static TPKChannelResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resolver = [[self alloc] init];
    });
    return resolver;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _lock = [[NSLock alloc] init];
    _nativeConnectionIdentities = [NSMutableDictionary dictionary];
    return self;
}

- (TPKChannelContext *)currentContext {
    [_lock lock];
    TPKChannelContext *context = _currentContext;
    [_lock unlock];
    return context;
}

- (NSUInteger)tpk_nextGenerationLocked {
    _generationCounter += 1;
    if (_generationCounter == 0) _generationCounter = 1;
    return _generationCounter;
}

- (TPKChannelContext *)beginContextForChannelID:(uint32_t)channelID
                                       mediaKind:(TPKChannelMediaKind)mediaKind
                                          source:(TPKChannelSource)source
                                    channelName:(NSString *)channelName
                                     displayName:(NSString *)displayName
                                     sessionKey:(NSString *)sessionKey
                                   sourceObject:(id)sourceObject
                                expectedContext:(TPKChannelContext *)expectedContext {
    if (channelID == 0 || mediaKind == TPKChannelMediaKindUnknown) return nil;

    NSString *cleanName = tpk_channelName(channelName);
    NSString *cleanDisplayName = tpk_trimString(displayName);
    NSString *cleanSessionKey = tpk_trimString(sessionKey);

    [_lock lock];
    if (expectedContext && !TPKResolverCanApplyIdentity(expectedContext.channelID, channelID,
            expectedContext.generation, _currentContext.generation,
            [_currentContext.sessionID isEqual:expectedContext.sessionID], YES)) {
        [_lock unlock];
        tpk_resolverLog(@"metadata ignored id=%u reason=selection-changed", channelID);
        return nil;
    }

    // Le chat confirme la sélection ; les playlists ne fournissent que des métadonnées.
    if (mediaKind == TPKChannelMediaKindLive &&
        (_nativeActiveLiveChannelID != channelID || !sourceObject)) {
        [_lock unlock];
        return nil;
    }

    TPKChannelContext *previous = _currentContext;
    BOOL sameIdentity = tpk_sameContextIdentity(previous,
                                                 channelID,
                                                 mediaKind,
                                                 cleanSessionKey);
    NSUInteger generation = sameIdentity
        ? previous.generation
        : [self tpk_nextGenerationLocked];
    NSUUID *sessionID = sameIdentity ? previous.sessionID : [NSUUID UUID];

    TPKChannelContext *context = [[TPKChannelContext alloc]
        initWithChannelID:channelID
             channelName:cleanName
              displayName:cleanDisplayName
                mediaKind:mediaKind
                   source:source
                sessionID:sessionID
               sessionKey:cleanSessionKey
             generation:generation
             sourceObject:sourceObject];
    BOOL changed = !tpk_sameContextMetadata(previous, context);
    _currentContext = context;
    [_lock unlock];

    if (changed) tpk_postContextChange(self, context, generation);
    return context;
}

- (TPKChannelContext *)beginLiveChannelWithID:(uint32_t)channelID
                                  channelName:(NSString *)channelName
                                   displayName:(NSString *)displayName
                                       source:(TPKChannelSource)source
                                   sessionKey:(NSString *)sessionKey
                                 sourceObject:(id)sourceObject {
    return [self beginContextForChannelID:channelID
                                mediaKind:TPKChannelMediaKindLive
                                   source:source
                             channelName:channelName
                              displayName:displayName
                              sessionKey:sessionKey
                            sourceObject:sourceObject expectedContext:nil];
}

- (TPKChannelContext *)beginReplayChannelWithID:(uint32_t)channelID
                                    channelName:(NSString *)channelName
                                     displayName:(NSString *)displayName
                                         source:(TPKChannelSource)source
                                     sessionKey:(NSString *)sessionKey
                                   sourceObject:(id)sourceObject {
    if (channelID == 0) return nil;

    [_lock lock];
    _nativeActiveLiveChannelID = 0;
    [_nativeConnectionIdentities removeAllObjects];
    [_lock unlock];

    return [self beginContextForChannelID:channelID
                                mediaKind:TPKChannelMediaKindReplay
                                   source:source
                             channelName:channelName
                              displayName:displayName
                              sessionKey:sessionKey
                            sourceObject:sourceObject expectedContext:nil];
}

- (BOOL)isCurrentContext:(TPKChannelContext *)context {
    if (!context) return NO;

    [_lock lock];
    BOOL current = _currentContext.channelID == context.channelID &&
        _currentContext.generation == context.generation &&
        [_currentContext.sessionID isEqual:context.sessionID];
    [_lock unlock];
    return current;
}

- (BOOL)isCurrentSessionID:(NSUUID *)sessionID
                 channelID:(uint32_t)channelID
                generation:(NSUInteger)generation {
    if (!sessionID || channelID == 0 || generation == 0) return NO;

    [_lock lock];
    BOOL current = _currentContext.channelID == channelID &&
        _currentContext.generation == generation &&
        [_currentContext.sessionID isEqual:sessionID];
    [_lock unlock];
    return current;
}

- (void)invalidateCurrentContext {
    [_lock lock];
    BOOL hadContext = _currentContext != nil;
    _currentContext = nil;
    _nativeActiveLiveChannelID = 0;
    [_nativeConnectionIdentities removeAllObjects];
    NSUInteger generation = [self tpk_nextGenerationLocked];
    [_lock unlock];

    if (hadContext) tpk_postContextChange(self, nil, generation);
}

- (BOOL)invalidateIfCurrentContext:(TPKChannelContext *)context {
    if (!context) return NO;

    [_lock lock];
    BOOL shouldInvalidate = _currentContext.channelID == context.channelID &&
        _currentContext.generation == context.generation &&
        [_currentContext.sessionID isEqual:context.sessionID];
    NSUInteger generation = shouldInvalidate
        ? [self tpk_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) tpk_postContextChange(self, nil, generation);
    return shouldInvalidate;
}

- (BOOL)invalidateIfCurrentSessionID:(NSUUID *)sessionID
                           channelID:(uint32_t)channelID
                          generation:(NSUInteger)generation {
    if (!sessionID || channelID == 0 || generation == 0) return NO;

    [_lock lock];
    BOOL shouldInvalidate = _currentContext.channelID == channelID &&
        _currentContext.generation == generation &&
        [_currentContext.sessionID isEqual:sessionID];
    NSUInteger newGeneration = shouldInvalidate
        ? [self tpk_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) tpk_postContextChange(self, nil, newGeneration);
    return shouldInvalidate;
}

- (BOOL)invalidateIfSourceObject:(id)sourceObject {
    if (!sourceObject) return NO;

    [_lock lock];
    BOOL shouldInvalidate = _currentContext.sourceObject == sourceObject;
    NSUInteger generation = shouldInvalidate
        ? [self tpk_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) tpk_postContextChange(self, nil, generation);
    return shouldInvalidate;
}

@end

TPKChannelContext *TPKCurrentChannelContext(void) {
    return [TPKChannelResolver sharedResolver].currentContext;
}

BOOL TPKChannelContextIsCurrent(TPKChannelContext *context) {
    return [[TPKChannelResolver sharedResolver] isCurrentContext:context];
}

@implementation TPKChannelResolver (TPKNativeState)

- (void)tpk_setNativeActiveLiveChannelID:(uint32_t)channelID
                             sourceObject:(id)sourceObject {
    if (channelID == 0) {
        [self tpk_clearNativeLiveChannel];
        return;
    }

    NSDictionary *identity = nil;
    [_lock lock];
    if (_currentContext.mediaKind == TPKChannelMediaKindReplay) {
        [_lock unlock];
        tpk_resolverLog(@"chat selection ignored id=%u reason=replay-active", channelID);
        return;
    }
    _nativeActiveLiveChannelID = channelID;
    identity = [_nativeConnectionIdentities[@(channelID)] copy];
    [_lock unlock];

    [self beginLiveChannelWithID:channelID
                      channelName:identity[@"channelName"]
                       displayName:identity[@"displayName"]
                           source:TPKChannelSourceLiveChat
                       sessionKey:nil
                     sourceObject:sourceObject];
}

- (void)tpk_updateNativeIdentityForChannelID:(uint32_t)channelID
                                  channelName:(NSString *)channelName
                                 displayName:(NSString *)displayName
                                sourceObject:(id)sourceObject {
    if (channelID == 0) return;

    NSString *cleanName = tpk_channelName(channelName);
    NSString *cleanDisplayName = tpk_trimString(displayName);
    if (!cleanName.length) cleanName = tpk_channelName(cleanDisplayName);
    if (!cleanDisplayName.length) cleanDisplayName = cleanName;
    if (!cleanName.length) return;

    BOOL shouldApply = NO;
    BOOL identityChanged = NO;
    [_lock lock];
    NSDictionary *identity = @{
        @"channelName": cleanName,
        @"displayName": cleanDisplayName ?: cleanName
    };
    identityChanged = ![_nativeConnectionIdentities[@(channelID)] isEqual:identity];
    if (identityChanged) {
        _nativeConnectionIdentities[@(channelID)] = identity;
    }
    shouldApply = _nativeActiveLiveChannelID == channelID &&
        (!_currentContext ||
         _currentContext.mediaKind == TPKChannelMediaKindLive);
    BOOL alreadyCurrent = _currentContext &&
        _currentContext.mediaKind == TPKChannelMediaKindLive &&
        _currentContext.channelID == channelID &&
        tpk_sameString(_currentContext.channelName, cleanName) &&
        tpk_sameString(_currentContext.displayName, cleanDisplayName);
    TPKChannelContext *confirmed = _currentContext;
    [_lock unlock];

    if (!shouldApply || (!identityChanged && alreadyCurrent)) return;

    [self beginContextForChannelID:channelID mediaKind:TPKChannelMediaKindLive
                           source:confirmed.source
                      channelName:cleanName
                       displayName:cleanDisplayName
                       sessionKey:nil
                     sourceObject:confirmed.sourceObject ?: sourceObject expectedContext:confirmed];
}

- (void)tpk_clearNativeLiveChannel {
    BOOL shouldNotify = NO;
    NSUInteger generation = 0;

    [_lock lock];
    _nativeActiveLiveChannelID = 0;
    [_nativeConnectionIdentities removeAllObjects];
    shouldNotify = _currentContext.mediaKind == TPKChannelMediaKindLive;
    if (shouldNotify) {
        _currentContext = nil;
        generation = [self tpk_nextGenerationLocked];
    }
    [_lock unlock];

    if (shouldNotify) tpk_postContextChange(self, nil, generation);
}

@end

@interface NSObject (TPKChannelResolverNativeAccess)

- (unsigned int)id;
- (nullable NSString *)name;
- (nullable NSString *)displayName;
- (unsigned int)channelID;
- (nullable NSString *)channelName;
- (nullable NSString *)channelDisplayName;

@end

@interface NSObject (TPKChannelResolverRuntimeHooks)

- (void)tpk_cr_setChannelName:(id)name;
- (void)tpk_cr_setChannelDisplayName:(id)name;
- (void)tpk_cr_addMessages:(id)messages;
- (void)tpk_cr_prependMessages:(id)messages;
- (void)tpk_cr_addMessagesToChatLog:(id)log;
- (void)tpk_cr_prependMessagesToChatLog:(id)log;
- (void)tpk_cr_connect;

@end

static __weak id tpk_pendingNativeConnection;

static void tpk_captureNativeConnectionIdentity(id connection) {
    if (!connection) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ tpk_captureNativeConnectionIdentity(connection); });
        return;
    }

    unsigned int channelID = 0;
    NSString *channelName = nil;
    NSString *displayName = nil;

    if ([connection respondsToSelector:@selector(channelID)]) {
        channelID = [connection channelID];
    }
    if ([connection respondsToSelector:@selector(channelName)]) {
        channelName = [connection channelName];
    }
    if ([connection respondsToSelector:@selector(channelDisplayName)]) {
        displayName = [connection channelDisplayName];
    }

    if (channelID == 0) return;

    [[TPKChannelResolver sharedResolver]
        tpk_updateNativeIdentityForChannelID:channelID
                                  channelName:channelName
                                 displayName:displayName
                     sourceObject:connection];
    if (connection == tpk_pendingNativeConnection && channelName.length &&
        TPKCurrentChannelContext().mediaKind != TPKChannelMediaKindReplay) {
        tpk_pendingNativeConnection = nil;
        tpk_resolverLog(@"native chat confirms id=%u source=%@", channelID, NSStringFromClass([connection class]));
        [TPKChannelResolver.sharedResolver tpk_setNativeActiveLiveChannelID:channelID sourceObject:connection];
    }
}




static uint32_t tpk_openedChannelID;
static NSString *tpk_openedChannelLogin;
static __weak UIView *tpk_openedLegacyView;

void TPKChannelResolverNoteChatRoom(NSString *login, NSString *roomID, id sourceObject) {
    NSString *clean = tpk_channelName(login);
    uint32_t channelID = [roomID isKindOfClass:NSString.class] ? TPKResolverParseChannelID(roomID.UTF8String) : 0;
    if (!channelID || !tpk_isResolverLogin(clean) || !sourceObject) {
        tpk_resolverLog(@"chat identity ignored reason=invalid-identity");
        return;
    }
    if ([sourceObject isKindOfClass:NSURLSessionWebSocketTask.class]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (tpk_openedChannelID && channelID != tpk_openedChannelID)
                tpk_resolverLog(@"legacy room ignored id=%u expected=%u", channelID, tpk_openedChannelID);
        });
        return;
    }
    TPKChannelResolver *resolver = TPKChannelResolver.sharedResolver;
    TPKChannelContext *current = resolver.currentContext;
    if (current.mediaKind == TPKChannelMediaKindReplay) {
        tpk_resolverLog(@"chat identity ignored id=%u reason=replay-active", channelID);
        return;
    }
    if (current.mediaKind == TPKChannelMediaKindLive && current.channelID == channelID &&
        [current.channelName isEqualToString:clean]) return;
    tpk_resolverLog(@"chat confirms id=%u login=%@ source=%@ previous=%u", channelID, clean,
                   NSStringFromClass([sourceObject class]), current.channelID);
    [resolver tpk_updateNativeIdentityForChannelID:channelID channelName:clean
                                     displayName:nil sourceObject:sourceObject];
    [resolver tpk_setNativeActiveLiveChannelID:channelID sourceObject:sourceObject];
}

static void tpk_noteOpenedChannel(id login, id identifier, id source) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ tpk_noteOpenedChannel(login, identifier, source); });
        return;
    }
    NSString *name = [login isKindOfClass:NSString.class] ? tpk_channelName(login) : nil;
    uint32_t channelID = [identifier isKindOfClass:NSString.class] ? TPKResolverParseChannelID([identifier UTF8String]) : 0;
    tpk_openedLegacyView = nil;
    tpk_openedChannelID = tpk_isResolverLogin(name) ? channelID : 0;
    tpk_openedChannelLogin = tpk_openedChannelID ? name : nil;
    tpk_resolverLog(@"navigation opens id=%u login=%@", tpk_openedChannelID, tpk_openedChannelLogin ?: @"-");
    if (!tpk_openedChannelID) return;
    TPKChannelResolverNoteReplayView(nil, NO);
    TPKChannelResolver *resolver = TPKChannelResolver.sharedResolver;
    [resolver tpk_updateNativeIdentityForChannelID:channelID channelName:name displayName:nil sourceObject:source];
    [resolver beginLiveChannelWithID:channelID channelName:name displayName:nil
        source:TPKChannelSourceLiveChat sessionKey:nil sourceObject:source];
    [resolver tpk_setNativeActiveLiveChannelID:channelID sourceObject:source];
}

static __weak UIView *tpk_replayView;
static NSString *tpk_replayVideoID;
static NSCache *tpk_videoOwners(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 32; });
    return cache;
}

static NSString *tpk_ownerRequestVideo;
static NSURLSessionDataTask *tpk_ownerRequestTask;
static NSUUID *tpk_ownerRequestToken;
static void tpk_applyReplayVideo(void);

static void tpk_requestReplayOwner(NSString *videoID) {
    if ([tpk_ownerRequestVideo isEqual:videoID]) return;
    NSDictionary *credentials = [TPKManager.sharedManager tpk_twitchCredentialsSnapshot];
    if (![credentials[@"Client-ID"] length]) return;
    [tpk_ownerRequestTask cancel];
    tpk_ownerRequestVideo = [videoID copy];
    NSUUID *token = NSUUID.UUID;
    tpk_ownerRequestToken = token;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 12;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:credentials[@"Client-ID"] forHTTPHeaderField:@"Client-ID"];
    if ([credentials[@"Authorization"] length]) [request setValue:credentials[@"Authorization"] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"operationName":@"TPKVideoOwner", @"variables":@{@"id":videoID},
        @"query":@"query TPKVideoOwner($id: ID!) { video(id: $id) { id owner { userID: id name: login displayName } } }"
    } options:0 error:nil];
    tpk_resolverLog(@"VOD owner requested video=%@", videoID);
    tpk_ownerRequestTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        id json = !error && status == 200 && data.length && data.length <= 65536
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id root = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        id video = [root isKindOfClass:NSDictionary.class] ? root[@"video"] : nil;
        id owner = [video isKindOfClass:NSDictionary.class] ? video[@"owner"] : nil;
        BOOL valid = [video isKindOfClass:NSDictionary.class] && [video[@"id"] isEqual:videoID] &&
            [owner isKindOfClass:NSDictionary.class] && [owner[@"userID"] isKindOfClass:NSString.class] &&
            TPKResolverParseChannelID([owner[@"userID"] UTF8String]) && [owner[@"name"] isKindOfClass:NSString.class] &&
            tpk_isResolverLogin(tpk_channelName(owner[@"name"]));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![tpk_ownerRequestToken isEqual:token]) return;
            tpk_ownerRequestTask = nil;
            if (valid) {
                [tpk_videoOwners() setObject:[owner copy] forKey:videoID];
                tpk_resolverLog(@"VOD owner received video=%@", videoID);
                tpk_applyReplayVideo();
            } else tpk_resolverLog(@"VOD owner failed status=%ld error=%ld valid=0", (long)status, (long)error.code);
        });
    }];
    [tpk_ownerRequestTask resume];
}

static NSString *tpk_videoIDFromURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || ![url.host.lowercaseString isEqual:@"usher.ttvnw.net"]) return nil;
    NSArray *parts = url.pathComponents;
    if (parts.count != 3 || ![parts[1] isEqual:@"vod"] || ![parts[2] hasSuffix:@".m3u8"]) return nil;
    NSString *value = [parts[2] stringByDeletingPathExtension];
    if (!value.length || value.length > 20 ||
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
    return value;
}

static id tpk_replayObjectGetter(id object, SEL selector) {
    Method method = object ? class_getInstanceMethod(object_getClass(object), selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    return type[0] == '@' ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}


static NSString *tpk_visibleReplayVideo(UIView *view) {
    if (!view.window || view.hidden) return nil;
    for (UIView *parent = view; parent; parent = parent.superview)
        if (parent.hidden || parent.alpha <= 0) return nil;
    UIView *theater = tpk_playerTheaterHostForView(view);
    if (!theater) { tpk_resolverLog(@"VOD path check: theater missing"); return nil; }
    Class playerView = NSClassFromString(@"IVSPlayerView");
    if (!playerView) return nil;
    NSMutableArray *pending = [NSMutableArray arrayWithObject:theater];
    NSString *selected = nil;
    NSUInteger players = 0;
    for (NSUInteger index = 0; index < pending.count; ++index) {
        if (index >= 512 || pending.count > 1024) return nil;
        UIView *candidate = pending[index];
        if (candidate.hidden || candidate.alpha <= 0 || !candidate.window) continue;
        if ([candidate isKindOfClass:playerView]) {
            ++players;
            id player = tpk_replayObjectGetter(candidate, @selector(player));
            id path = tpk_replayObjectGetter(player, @selector(path));
            NSString *video = tpk_videoIDFromURL(path);
            if (!video) {
                BOOL url = [path isKindOfClass:NSURL.class];
                tpk_resolverLog(@"VOD path check: player=%@ pathType=%@ usher=%d components=%lu",
                    player ? NSStringFromClass([player class]) : @"none",
                    path ? NSStringFromClass([path class]) : @"none",
                    url && [[path host] isEqual:@"usher.ttvnw.net"],
                    (unsigned long)(url ? [[path pathComponents] count] : 0));
            }
            if (video && selected && ![selected isEqual:video]) return nil;
            if (video) selected = video;
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    if (!players) tpk_resolverLog(@"VOD path check: IVSPlayerView missing");
    return selected;
}

static void tpk_applyReplayVideo(void) {
    static __weak UIView *unavailableView;
    static NSString *awaitingVideo;
    UIView *view = tpk_replayView;
    NSString *videoID = tpk_visibleReplayVideo(view);
    if (!videoID) {
        if (view.window && unavailableView != view) {
            tpk_resolverLog(@"VOD player path unavailable");
            unavailableView = view;
        }
        TPKChannelContext *previous = TPKCurrentChannelContext();
        if (view && previous.mediaKind == TPKChannelMediaKindReplay && previous.sourceObject == view)
            [TPKChannelResolver.sharedResolver invalidateIfCurrentContext:previous];
        tpk_replayVideoID = nil;
        return;
    }
    unavailableView = nil;
    if (![tpk_replayVideoID isEqual:videoID]) {
        tpk_replayVideoID = videoID;
        tpk_resolverLog(@"VOD player confirmed video=%@", videoID);
        TPKChannelContext *previous = TPKCurrentChannelContext();
        if (previous.mediaKind == TPKChannelMediaKindReplay)
            [TPKChannelResolver.sharedResolver invalidateIfCurrentContext:previous];
    }
    NSDictionary *owner = [tpk_videoOwners() objectForKey:videoID];
    uint32_t channelID = [owner[@"userID"] isKindOfClass:NSString.class] ? TPKResolverParseChannelID([owner[@"userID"] UTF8String]) : 0;
    NSString *login = [owner[@"name"] isKindOfClass:NSString.class] ? tpk_channelName(owner[@"name"]) : nil;
    if (!channelID || !tpk_isResolverLogin(login)) {
        if (![awaitingVideo isEqual:videoID]) {
            awaitingVideo = videoID;
            tpk_resolverLog(@"VOD awaiting metadata video=%@", videoID);
        }
        tpk_requestReplayOwner(videoID);
        return;
    }
    awaitingVideo = nil;
    TPKChannelContext *current = TPKCurrentChannelContext();
    if (current.mediaKind == TPKChannelMediaKindReplay && current.channelID == channelID &&
        [current.sessionKey isEqual:videoID] && [current.channelName isEqual:login]) return;
    tpk_resolverLog(@"VOD metadata accepted video=%@ id=%u", videoID, channelID);
    [TPKChannelResolver.sharedResolver beginReplayChannelWithID:channelID channelName:login
        displayName:[owner[@"displayName"] isKindOfClass:NSString.class] ? owner[@"displayName"] : login
        source:TPKChannelSourceReplayComment sessionKey:videoID sourceObject:view];
}

void TPKChannelResolverNoteReplayView(UIView *view, BOOL replay) {
    if (!NSThread.isMainThread) return;
    if (!replay) {
        tpk_openedLegacyView = view && [NSStringFromClass(view.class).lowercaseString hasSuffix:@"chattranscriptview"] ? view : nil;
        tpk_replayView = nil; tpk_replayVideoID = nil;
        [tpk_ownerRequestTask cancel]; tpk_ownerRequestTask = nil; tpk_ownerRequestVideo = nil; tpk_ownerRequestToken = nil;
        return;
    }
    tpk_openedLegacyView = nil;
    tpk_openedChannelID = 0;
    tpk_openedChannelLogin = nil;
    if (view != tpk_replayView) {
        [tpk_ownerRequestTask cancel]; tpk_ownerRequestTask = nil; tpk_ownerRequestVideo = nil; tpk_ownerRequestToken = nil;
        tpk_replayVideoID = nil;
        TPKChannelContext *previous = TPKCurrentChannelContext();
        if (previous.mediaKind == TPKChannelMediaKindReplay)
            [TPKChannelResolver.sharedResolver invalidateIfCurrentContext:previous];
        tpk_resolverLog(@"VOD view observed");
        if (TPKManager.sharedManager.logsEnabled && TPKManager.sharedManager.logChannelResolver) {
            UIView *parent = view;
            for (NSUInteger depth = 0; parent && depth < 12; ++depth, parent = parent.superview)
                tpk_resolverLog(@"VOD hierarchy %lu: %@", (unsigned long)depth, NSStringFromClass(parent.class));
        }
    }
    tpk_replayView = view;
    tpk_applyReplayVideo();
}

void TPKChannelResolverNoteVideoMetadata(NSDictionary *video, NSString *requestedID) {
    if (![video isKindOfClass:NSDictionary.class] || ![requestedID isKindOfClass:NSString.class] ||
        !requestedID.length || ![video[@"id"] isEqual:requestedID]) return;
    id owner = video[@"owner"];
    if (![owner isKindOfClass:NSDictionary.class]) return;
    NSDictionary *snapshot = [owner copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_resolverLog(@"VOD metadata observed video=%@", requestedID);
        [tpk_videoOwners() setObject:snapshot forKey:requestedID];
        tpk_applyReplayVideo();
    });
}

static void tpk_requestResolverHookRefresh(void);
static NSMutableDictionary<NSString *, NSDictionary *> *tpk_helixLoginCache(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSMutableDictionary<NSString *, NSUUID *> *tpk_helixRequests;
static NSString *tpk_lastIgnoredPlaylist;

static uint32_t tpk_helixUserID(NSDictionary *user) {
    id rawID = user[@"id"];
    return [rawID isKindOfClass:NSString.class] ? TPKResolverParseChannelID([rawID UTF8String]) : 0;
}

static void tpk_applyHelixIdentity(NSDictionary *user, TPKChannelContext *expected, BOOL requestMatches) {
    TPKChannelResolver *resolver = TPKChannelResolver.sharedResolver;
    TPKChannelContext *current = resolver.currentContext;
    uint32_t channelID = tpk_helixUserID(user);
    NSString *login = [user[@"login"] isKindOfClass:NSString.class] ? tpk_channelName(user[@"login"]) : nil;
    BOOL valid = current.mediaKind == TPKChannelMediaKindLive &&
        TPKResolverCanApplyIdentity(expected.channelID, channelID, expected.generation,
                                   current.generation, [current.sessionID isEqual:expected.sessionID], requestMatches);
    if (!valid || ![login isEqualToString:expected.channelName]) {
        tpk_resolverLog(@"Helix ignored id=%u expected=%u generation=%lu current=%lu reason=stale-or-mismatched",
            channelID, expected.channelID, (unsigned long)expected.generation, (unsigned long)current.generation);
        return;
    }
    NSString *display = [user[@"display_name"] isKindOfClass:NSString.class] ? user[@"display_name"] : nil;
    TPKChannelContext *applied = [resolver beginContextForChannelID:channelID mediaKind:TPKChannelMediaKindLive
        source:current.source channelName:login displayName:display sessionKey:expected.sessionKey
        sourceObject:expected.sourceObject expectedContext:expected];
    if (applied) tpk_resolverLog(@"Helix metadata accepted id=%u generation=%lu", channelID, (unsigned long)current.generation);
    tpk_requestResolverHookRefresh();
}

void TPKChannelResolverNoteStreamLogin(NSString *login) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TPKChannelResolverNoteStreamLogin(login); });
        return;
    }
    NSString *clean = tpk_channelName(login);
    if (!tpk_isResolverLogin(clean)) return;
    TPKChannelContext *expected = TPKCurrentChannelContext();
    // Une playlist ne sélectionne jamais la chaîne, y compris depuis le cache Helix.
    if (expected.mediaKind != TPKChannelMediaKindLive || !expected.channelName.length ||
        ![expected.channelName isEqualToString:clean]) {
        NSString *signature = [NSString stringWithFormat:@"%@/%u/%lu", clean, expected.channelID,
                               (unsigned long)expected.generation];
        if (!tpk_openedLegacyView.window && ![tpk_lastIgnoredPlaylist isEqualToString:signature]) {
            tpk_lastIgnoredPlaylist = signature;
            tpk_resolverLog(@"playlist candidate ignored login=%@ current=%u reason=no-matching-chat", clean, expected.channelID);
        }
        return;
    }
    tpk_lastIgnoredPlaylist = nil;
    NSDictionary *cached = tpk_helixLoginCache()[clean];
    if (cached && tpk_helixUserID(cached) == expected.channelID) {
        tpk_applyHelixIdentity(cached, expected, YES);
        return;
    }
    if (cached) [tpk_helixLoginCache() removeObjectForKey:clean];
    if (!tpk_helixRequests) tpk_helixRequests = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@/%@", clean, expected.sessionID.UUIDString];
    if (tpk_helixRequests[key]) return;
    NSDictionary<NSString *, NSString *> *credentials = [TPKManager.sharedManager tpk_twitchCredentialsSnapshot];
    if (!credentials[@"Authorization"].length || !credentials[@"Client-ID"].length) {
        tpk_resolverLog(@"Helix skipped id=%u reason=credentials-unavailable", expected.channelID);
        return;
    }
    NSString *encoded = [clean stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.twitch.tv/helix/users?login=%@", encoded]];
    if (!url) return;
    NSUUID *requestID = NSUUID.UUID;
    tpk_helixRequests[key] = requestID;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;
    [request setValue:credentials[@"Authorization"] forHTTPHeaderField:@"Authorization"];
    [request setValue:credentials[@"Client-ID"] forHTTPHeaderField:@"Client-ID"];
    tpk_resolverLog(@"Helix requested id=%u generation=%lu", expected.channelID, (unsigned long)expected.generation);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *user = nil;
        if (!error && status == 200 && data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id users = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
            id first = [users isKindOfClass:NSArray.class] ? [users firstObject] : nil;
            if ([first isKindOfClass:NSDictionary.class]) user = first;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL matches = [tpk_helixRequests[key] isEqual:requestID];
            if (matches) [tpk_helixRequests removeObjectForKey:key];
            NSString *returnedLogin = [user[@"login"] isKindOfClass:NSString.class] ? tpk_channelName(user[@"login"]) : nil;
            if (tpk_helixUserID(user) && [returnedLogin isEqualToString:clean]) {
                tpk_helixLoginCache()[clean] = user;
                tpk_applyHelixIdentity(user, expected, matches);
            } else {
                tpk_resolverLog(@"Helix failed expected=%u status=%ld error=%ld reason=invalid-response",
                    expected.channelID, (long)status, (long)error.code);
            }
        });
    }] resume];
}

static void (*tpk_originalOpenChannel)(id, SEL, id, id, BOOL, long long, long long, BOOL, id, id);
static void (*tpk_originalOpenAttributedChannel)(id, SEL, id, id, BOOL, long long, long long, BOOL, id, id, id, id);

static void tpk_openChannel(id self, SEL selector, id login, id identifier, BOOL dual, long long height,
                            long long width, BOOL encrypted, id medium, id content) {
    tpk_noteOpenedChannel(login, identifier, self);
    tpk_originalOpenChannel(self, selector, login, identifier, dual, height, width, encrypted, medium, content);
}

static void tpk_openAttributedChannel(id self, SEL selector, id login, id identifier, BOOL dual,
    long long height, long long width, BOOL encrypted, id medium, id content, id session, id raid) {
    tpk_noteOpenedChannel(login, identifier, self);
    tpk_originalOpenAttributedChannel(self, selector, login, identifier, dual, height, width, encrypted, medium, content, session, raid);
}

static BOOL tpk_navigationSignature(Method method, unsigned count) {
    if (!method || method_getNumberOfArguments(method) != count) return NO;
    char type[32];
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'v') return NO;
    const char *expected = "@:@@BqqB@@@@";
    for (unsigned i = 0; i < count; ++i) {
        method_getArgumentType(method, i, type, sizeof(type));
        if (type[0] != expected[i]) return NO;
    }
    return YES;
}

static void tpk_installNavigationHooks(void) {
    Class cls = NSClassFromString(@"TwitchRNHostNavigation");
    SEL open = NSSelectorFromString(@"openChannel:channelId:isDualFormat:videoHeight:videoWidth:isEncrypted:medium:content:");
    SEL attributed = NSSelectorFromString(@"openChannelWithAttribution:channelId:isDualFormat:videoHeight:videoWidth:isEncrypted:medium:content:originalPlaySessionId:raidId:");
    @synchronized (TPKChannelResolver.class) {
        Method method = class_getInstanceMethod(cls, open);
        if (!tpk_originalOpenChannel && tpk_navigationSignature(method, 10)) {
            class_addMethod(cls, open, method_getImplementation(method), method_getTypeEncoding(method));
            tpk_originalOpenChannel = (void *)method_getImplementation(class_getInstanceMethod(cls, open));
            method_setImplementation(class_getInstanceMethod(cls, open), (IMP)tpk_openChannel);
        }
        method = class_getInstanceMethod(cls, attributed);
        if (!tpk_originalOpenAttributedChannel && tpk_navigationSignature(method, 12)) {
            class_addMethod(cls, attributed, method_getImplementation(method), method_getTypeEncoding(method));
            tpk_originalOpenAttributedChannel = (void *)method_getImplementation(class_getInstanceMethod(cls, attributed));
            method_setImplementation(class_getInstanceMethod(cls, attributed), (IMP)tpk_openAttributedChannel);
        }
        static NSInteger reported = -1;
        NSInteger status = (tpk_originalOpenChannel ? 1 : 0) | (tpk_originalOpenAttributedChannel ? 2 : 0);
        if (status != reported) {
            reported = status;
            tpk_resolverLog(@"navigation hooks open=%d attributed=%d", tpk_originalOpenChannel != NULL, tpk_originalOpenAttributedChannel != NULL);
        }
    }
}

static BOOL tpk_resolverHooksReady = NO;
static BOOL tpk_resolverRefreshQueued = NO;

static BOOL tpk_installResolverHooks(void);

static void tpk_requestResolverHookRefresh(void) {
    @synchronized ([TPKChannelResolver class]) {
        if (tpk_resolverHooksReady || tpk_resolverRefreshQueued) return;
        tpk_resolverRefreshQueued = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized ([TPKChannelResolver class]) {
            tpk_resolverRefreshQueued = NO;
        }
        if (!tpk_resolverHooksReady) {
            tpk_resolverHooksReady = tpk_installResolverHooks();
        }
    });
}

static BOOL tpk_installNativeHook(Class targetClass,
                                   SEL originalSelector,
                                   SEL hookSelector) {
    if (!targetClass || !originalSelector || !hookSelector) return NO;

    Method originalMethod = class_getInstanceMethod(targetClass,
                                                    originalSelector);
    Method hookMethod = class_getInstanceMethod([NSObject class],
                                                hookSelector);
    if (!originalMethod || !hookMethod) return NO;

    // Preserve Twitch's native selector encoding and ABI.
    IMP originalIMP = method_getImplementation(originalMethod);
    IMP hookIMP = method_getImplementation(hookMethod);
    const char *nativeTypes = method_getTypeEncoding(originalMethod);

    class_addMethod(targetClass, originalSelector, originalIMP, nativeTypes);
    class_replaceMethod(targetClass, hookSelector, hookIMP, nativeTypes);

    Method targetOriginal = class_getInstanceMethod(targetClass,
                                                    originalSelector);
    Method targetHook = class_getInstanceMethod(targetClass, hookSelector);
    if (!targetOriginal || !targetHook) return NO;

    method_exchangeImplementations(targetOriginal, targetHook);
    return YES;
}

static BOOL tpk_installResolverHook(Class targetClass,
                                     SEL originalSelector,
                                     SEL hookSelector) {
    if (!targetClass) return NO;

    static NSMutableSet<NSString *> *installed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installed = [NSMutableSet set];
    });

    NSString *key = [NSString stringWithFormat:@"%@/%@",
                     NSStringFromClass(targetClass),
                     NSStringFromSelector(originalSelector)];
    @synchronized (installed) {
        if ([installed containsObject:key]) return YES;
        if (tpk_installNativeHook(targetClass, originalSelector, hookSelector)) {
            [installed addObject:key];
            return YES;
        }
    }
    return NO;
}


@implementation NSObject (TPKChannelResolverRuntimeHooks)







- (void)tpk_cr_setChannelName:(id)name {
    [self tpk_cr_setChannelName:name];
    tpk_captureNativeConnectionIdentity(self);
}

- (void)tpk_cr_setChannelDisplayName:(id)name {
    [self tpk_cr_setChannelDisplayName:name];
    tpk_captureNativeConnectionIdentity(self);
}

- (void)tpk_cr_addMessages:(id)messages {
    [self tpk_cr_addMessages:messages];
    tpk_captureNativeConnectionIdentity(self);
}

- (void)tpk_cr_prependMessages:(id)messages {
    [self tpk_cr_prependMessages:messages];
    tpk_captureNativeConnectionIdentity(self);
}

- (void)tpk_cr_addMessagesToChatLog:(id)log {
    [self tpk_cr_addMessagesToChatLog:log];
    tpk_captureNativeConnectionIdentity(self);
}

- (void)tpk_cr_prependMessagesToChatLog:(id)log {
    [self tpk_cr_prependMessagesToChatLog:log];
    tpk_captureNativeConnectionIdentity(self);
}

// Compat UIKit : confirmation lors de la connexion du chat natif.
- (void)tpk_cr_connect {
    [self tpk_cr_connect];
    dispatch_async(dispatch_get_main_queue(), ^{
        tpk_pendingNativeConnection = self;
        tpk_captureNativeConnectionIdentity(self);
    });
}

@end

static BOOL tpk_installResolverHooks(void) {
    tpk_installNavigationHooks();
    BOOL connectionReady = NO;
    for (NSString *className in @[
        @"Twitch.ChannelChatConnectionController",
        @"_TtC6Twitch31ChannelChatConnectionController"
    ]) {
        Class connectionClass = NSClassFromString(className);
        BOOL channelNameReady = tpk_installResolverHook(connectionClass,
                                  @selector(setChannelName:),
                                  @selector(tpk_cr_setChannelName:));
        BOOL displayNameReady = tpk_installResolverHook(connectionClass,
                                  @selector(setChannelDisplayName:),
                                  @selector(tpk_cr_setChannelDisplayName:));
        BOOL addMessagesReady = tpk_installResolverHook(connectionClass,
                                  @selector(addMessages:),
                                  @selector(tpk_cr_addMessages:));
        BOOL prependMessagesReady = tpk_installResolverHook(connectionClass,
                                  @selector(prependMessages:),
                                  @selector(tpk_cr_prependMessages:));
        BOOL addLogReady = tpk_installResolverHook(connectionClass,
                                  @selector(addMessagesToChatLog:),
                                  @selector(tpk_cr_addMessagesToChatLog:));
        BOOL prependLogReady = tpk_installResolverHook(connectionClass,
                                  @selector(prependMessagesToChatLog:),
                                  @selector(tpk_cr_prependMessagesToChatLog:));
        BOOL connectReady = tpk_installResolverHook(connectionClass,
                                  @selector(connect),
                                  @selector(tpk_cr_connect));
        connectionReady |= channelNameReady && displayNameReady &&
            addMessagesReady && prependMessagesReady && addLogReady &&
            prependLogReady && connectReady;
    }

    return connectionReady;
}

void TPKChannelResolverSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tpk_resolverHooksReady = tpk_installResolverHooks();

        // Twitch loads Swift chat classes lazily.
        for (NSNumber *delay in @[@0.25, @1.0, @3.0, @6.0, @12.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(delay.doubleValue *
                                                    NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!tpk_resolverHooksReady) {
                    tpk_resolverHooksReady = tpk_installResolverHooks();
                }
            });
        }
    });
}

void TPKChannelResolverRefresh(void) {
    if (NSThread.isMainThread) {
        tpk_applyReplayVideo();
        if (tpk_pendingNativeConnection) tpk_captureNativeConnectionIdentity(tpk_pendingNativeConnection);
        if (!tpk_resolverHooksReady) {
            tpk_resolverHooksReady = tpk_installResolverHooks();
        }
    } else {
        tpk_requestResolverHookRefresh();
    }
}
