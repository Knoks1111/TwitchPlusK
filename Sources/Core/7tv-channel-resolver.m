#import "Core/7tv-channel-resolver.h"

#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

NSNotificationName const S7TVChannelResolverDidChangeNotification =
    @"S7TVChannelResolverDidChangeNotification";

@interface S7TVChannelContext ()

- (instancetype)initWithChannelID:(uint32_t)channelID
                      channelName:(nullable NSString *)channelName
                       displayName:(nullable NSString *)displayName
                         mediaKind:(S7TVChannelMediaKind)mediaKind
                            source:(S7TVChannelSource)source
                         sessionID:(NSUUID *)sessionID
                        sessionKey:(nullable NSString *)sessionKey
                        generation:(NSUInteger)generation
                      sourceObject:(nullable id)sourceObject;

@end

@interface S7TVChannelResolver () {
    NSLock *_lock;
    S7TVChannelContext *_currentContext;
    NSUInteger _generationCounter;
    uint32_t _nativeActiveLiveChannelID;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_nativeConnectionIdentities;
}

- (NSUInteger)s7tv_nextGenerationLocked;

@end

@interface S7TVChannelResolver (S7TVNativeState)

- (void)s7tv_setNativeActiveLiveChannelID:(uint32_t)channelID
                             sourceObject:(nullable id)sourceObject;
- (void)s7tv_updateNativeIdentityForChannelID:(uint32_t)channelID
                                  channelName:(nullable NSString *)channelName
                                 displayName:(nullable NSString *)displayName
                                sourceObject:(nullable id)sourceObject;
- (void)s7tv_clearNativeLiveChannel;

@end

static NSString *s7tv_trimString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;

    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : nil;
}

static NSString *s7tv_channelName(NSString *value) {
    return s7tv_trimString(value).lowercaseString;
}

static BOOL s7tv_sameString(NSString *left, NSString *right) {
    if (left == right) return YES;
    if (!left || !right) return NO;
    return [left isEqualToString:right];
}

static BOOL s7tv_sameContextIdentity(S7TVChannelContext *context,
                                     uint32_t channelID,
                                     S7TVChannelMediaKind mediaKind,
                                     NSString *sessionKey) {
    return context &&
        context.channelID == channelID &&
        context.mediaKind == mediaKind &&
        s7tv_sameString(context.sessionKey, sessionKey);
}

static BOOL s7tv_sameContextMetadata(S7TVChannelContext *left,
                                      S7TVChannelContext *right) {
    if (!left || !right) return left == right;

    return left.channelID == right.channelID &&
        left.mediaKind == right.mediaKind &&
        left.source == right.source &&
        s7tv_sameString(left.channelName, right.channelName) &&
        s7tv_sameString(left.displayName, right.displayName) &&
        s7tv_sameString(left.sessionKey, right.sessionKey);
}

static void s7tv_postContextChange(S7TVChannelResolver *resolver,
                                   S7TVChannelContext *context,
                                   NSUInteger generation) {
    NSDictionary *userInfo = context
        ? @{@"context": context, @"generation": @(generation)}
        : @{@"generation": @(generation)};

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVChannelResolverDidChangeNotification
                          object:resolver
                        userInfo:userInfo];
    });
}

@implementation S7TVChannelContext

- (instancetype)initWithChannelID:(uint32_t)channelID
                      channelName:(NSString *)channelName
                       displayName:(NSString *)displayName
                         mediaKind:(S7TVChannelMediaKind)mediaKind
                            source:(S7TVChannelSource)source
                         sessionID:(NSUUID *)sessionID
                        sessionKey:(NSString *)sessionKey
                        generation:(NSUInteger)generation
                      sourceObject:(id)sourceObject {
    self = [super init];
    if (!self) return nil;

    _channelID = channelID;
    _channelName = [s7tv_channelName(channelName) copy];
    _displayName = [s7tv_trimString(displayName) copy];
    _mediaKind = mediaKind;
    _source = source;
    _sessionID = [sessionID copy];
    _sessionKey = [s7tv_trimString(sessionKey) copy];
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

@implementation S7TVChannelResolver

+ (instancetype)sharedResolver {
    static S7TVChannelResolver *resolver;
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

- (S7TVChannelContext *)currentContext {
    [_lock lock];
    S7TVChannelContext *context = _currentContext;
    [_lock unlock];
    return context;
}

- (NSUInteger)s7tv_nextGenerationLocked {
    _generationCounter += 1;
    if (_generationCounter == 0) _generationCounter = 1;
    return _generationCounter;
}

- (S7TVChannelContext *)beginContextForChannelID:(uint32_t)channelID
                                       mediaKind:(S7TVChannelMediaKind)mediaKind
                                          source:(S7TVChannelSource)source
                                    channelName:(NSString *)channelName
                                     displayName:(NSString *)displayName
                                     sessionKey:(NSString *)sessionKey
                                   sourceObject:(id)sourceObject {
    if (channelID == 0 || mediaKind == S7TVChannelMediaKindUnknown) return nil;

    NSString *cleanName = s7tv_channelName(channelName);
    NSString *cleanDisplayName = s7tv_trimString(displayName);
    NSString *cleanSessionKey = s7tv_trimString(sessionKey);

    [_lock lock];

    // Live context only comes from Twitch's native callback.
    if (mediaKind == S7TVChannelMediaKindLive &&
        (_nativeActiveLiveChannelID != channelID || !sourceObject)) {
        [_lock unlock];
        return nil;
    }

    S7TVChannelContext *previous = _currentContext;
    BOOL sameIdentity = s7tv_sameContextIdentity(previous,
                                                 channelID,
                                                 mediaKind,
                                                 cleanSessionKey);
    NSUInteger generation = sameIdentity
        ? previous.generation
        : [self s7tv_nextGenerationLocked];
    NSUUID *sessionID = sameIdentity ? previous.sessionID : [NSUUID UUID];

    S7TVChannelContext *context = [[S7TVChannelContext alloc]
        initWithChannelID:channelID
             channelName:cleanName
              displayName:cleanDisplayName
                mediaKind:mediaKind
                   source:source
                sessionID:sessionID
               sessionKey:cleanSessionKey
             generation:generation
             sourceObject:sourceObject];
    BOOL changed = !s7tv_sameContextMetadata(previous, context);
    _currentContext = context;
    [_lock unlock];

    if (changed) s7tv_postContextChange(self, context, generation);
    return context;
}

- (S7TVChannelContext *)beginLiveChannelWithID:(uint32_t)channelID
                                  channelName:(NSString *)channelName
                                   displayName:(NSString *)displayName
                                       source:(S7TVChannelSource)source
                                   sessionKey:(NSString *)sessionKey
                                 sourceObject:(id)sourceObject {
    return [self beginContextForChannelID:channelID
                                mediaKind:S7TVChannelMediaKindLive
                                   source:source
                             channelName:channelName
                              displayName:displayName
                              sessionKey:sessionKey
                            sourceObject:sourceObject];
}

- (S7TVChannelContext *)beginReplayChannelWithID:(uint32_t)channelID
                                    channelName:(NSString *)channelName
                                     displayName:(NSString *)displayName
                                         source:(S7TVChannelSource)source
                                     sessionKey:(NSString *)sessionKey
                                   sourceObject:(id)sourceObject {
    if (channelID == 0) return nil;

    [_lock lock];
    _nativeActiveLiveChannelID = 0;
    [_nativeConnectionIdentities removeAllObjects];
    [_lock unlock];

    return [self beginContextForChannelID:channelID
                                mediaKind:S7TVChannelMediaKindReplay
                                   source:source
                             channelName:channelName
                              displayName:displayName
                              sessionKey:sessionKey
                            sourceObject:sourceObject];
}

- (BOOL)isCurrentContext:(S7TVChannelContext *)context {
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
    NSUInteger generation = [self s7tv_nextGenerationLocked];
    [_lock unlock];

    if (hadContext) s7tv_postContextChange(self, nil, generation);
}

- (BOOL)invalidateIfCurrentContext:(S7TVChannelContext *)context {
    if (!context) return NO;

    [_lock lock];
    BOOL shouldInvalidate = _currentContext.channelID == context.channelID &&
        _currentContext.generation == context.generation &&
        [_currentContext.sessionID isEqual:context.sessionID];
    NSUInteger generation = shouldInvalidate
        ? [self s7tv_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) s7tv_postContextChange(self, nil, generation);
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
        ? [self s7tv_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) s7tv_postContextChange(self, nil, newGeneration);
    return shouldInvalidate;
}

- (BOOL)invalidateIfSourceObject:(id)sourceObject {
    if (!sourceObject) return NO;

    [_lock lock];
    BOOL shouldInvalidate = _currentContext.sourceObject == sourceObject;
    NSUInteger generation = shouldInvalidate
        ? [self s7tv_nextGenerationLocked] : 0;
    if (shouldInvalidate) {
        _currentContext = nil;
        _nativeActiveLiveChannelID = 0;
        [_nativeConnectionIdentities removeAllObjects];
    }
    [_lock unlock];

    if (shouldInvalidate) s7tv_postContextChange(self, nil, generation);
    return shouldInvalidate;
}

@end

S7TVChannelContext *S7TVCurrentChannelContext(void) {
    return [S7TVChannelResolver sharedResolver].currentContext;
}

BOOL S7TVChannelContextIsCurrent(S7TVChannelContext *context) {
    return [[S7TVChannelResolver sharedResolver] isCurrentContext:context];
}

@implementation S7TVChannelResolver (S7TVNativeState)

- (void)s7tv_setNativeActiveLiveChannelID:(uint32_t)channelID
                             sourceObject:(id)sourceObject {
    if (channelID == 0) {
        [self s7tv_clearNativeLiveChannel];
        return;
    }

    NSDictionary *identity = nil;
    [_lock lock];
    _nativeActiveLiveChannelID = channelID;
    identity = [_nativeConnectionIdentities[@(channelID)] copy];
    [_lock unlock];

    [self beginLiveChannelWithID:channelID
                      channelName:identity[@"channelName"]
                       displayName:identity[@"displayName"]
                           source:S7TVChannelSourceLiveMetadata
                       sessionKey:nil
                     sourceObject:sourceObject];
}

- (void)s7tv_updateNativeIdentityForChannelID:(uint32_t)channelID
                                  channelName:(NSString *)channelName
                                 displayName:(NSString *)displayName
                                sourceObject:(id)sourceObject {
    if (channelID == 0) return;

    NSString *cleanName = s7tv_channelName(channelName);
    NSString *cleanDisplayName = s7tv_trimString(displayName);
    if (!cleanName.length) cleanName = s7tv_channelName(cleanDisplayName);
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
         _currentContext.mediaKind == S7TVChannelMediaKindLive);
    BOOL alreadyCurrent = _currentContext &&
        _currentContext.mediaKind == S7TVChannelMediaKindLive &&
        _currentContext.source == S7TVChannelSourceLiveMetadata &&
        _currentContext.channelID == channelID &&
        s7tv_sameString(_currentContext.channelName, cleanName) &&
        s7tv_sameString(_currentContext.displayName, cleanDisplayName);
    [_lock unlock];

    if (!shouldApply || (!identityChanged && alreadyCurrent)) return;

    [self beginLiveChannelWithID:channelID
                      channelName:cleanName
                       displayName:cleanDisplayName
                           source:S7TVChannelSourceLiveMetadata
                       sessionKey:nil
                     sourceObject:sourceObject];
}

- (void)s7tv_clearNativeLiveChannel {
    BOOL shouldNotify = NO;
    NSUInteger generation = 0;

    [_lock lock];
    _nativeActiveLiveChannelID = 0;
    [_nativeConnectionIdentities removeAllObjects];
    shouldNotify = _currentContext.mediaKind == S7TVChannelMediaKindLive;
    if (shouldNotify) {
        _currentContext = nil;
        generation = [self s7tv_nextGenerationLocked];
    }
    [_lock unlock];

    if (shouldNotify) s7tv_postContextChange(self, nil, generation);
}

@end

@interface NSObject (S7TVChannelResolverNativeAccess)

- (unsigned int)id;
- (nullable NSString *)name;
- (nullable NSString *)displayName;
- (unsigned int)channelID;
- (nullable NSString *)channelName;
- (nullable NSString *)channelDisplayName;

@end

@interface NSObject (S7TVChannelResolverRuntimeHooks)

- (void)s7tv_cr_addWithChannelIdentity:(id)identity;
- (void)s7tv_cr_setInformationDelegate:(id)delegate;
- (id)s7tv_cr_informationDelegate;
- (id)s7tv_cr_messageString:(id)string
    requestsBitsImageDataForPrefix:(id)prefix
                           quantity:(unsigned long long)quantity;
- (id)s7tv_cr_currentChannelUnlockedFollowerEmotesForMessageString:(id)string;
- (id)s7tv_cr_currentChannelUnlockedSubscriberEmotesForMessageString:(id)string;
- (void)s7tv_cr_setActiveChannelID:(unsigned int)channelID;
- (void)s7tv_cr_resetActiveChannelID;
- (void)s7tv_cr_setChannelName:(id)name;
- (void)s7tv_cr_setChannelDisplayName:(id)name;
- (void)s7tv_cr_updateConnectionStatus:(long long)status
                   withTTVErrorCode:(int)code
                    errorCodeString:(id)string;
- (void)s7tv_cr_addMessages:(id)messages;
- (void)s7tv_cr_prependMessages:(id)messages;
- (void)s7tv_cr_addMessagesToChatLog:(id)log;
- (void)s7tv_cr_prependMessagesToChatLog:(id)log;
- (void)s7tv_cr_connect;

@end

static void s7tv_captureNativeConnectionIdentity(id connection) {
    if (!connection) return;

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

    [[S7TVChannelResolver sharedResolver]
        s7tv_updateNativeIdentityForChannelID:channelID
                                  channelName:channelName
                                 displayName:displayName
                     sourceObject:connection];
}

static void s7tv_captureNativeChannelIdentity(id identity) {
    if (!identity) return;

    unsigned int channelID = 0;
    NSString *channelName = nil;
    NSString *displayName = nil;

    if ([identity respondsToSelector:@selector(id)]) {
        channelID = [identity id];
    }
    if ([identity respondsToSelector:@selector(name)]) {
        channelName = [identity name];
    }
    if ([identity respondsToSelector:@selector(displayName)]) {
        displayName = [identity displayName];
    }

    if (channelID == 0) return;

    [[S7TVChannelResolver sharedResolver]
        s7tv_updateNativeIdentityForChannelID:channelID
                                  channelName:channelName
                                 displayName:displayName
                                sourceObject:identity];
}

static uint32_t s7tv_vodChannelIDFromInformationDelegate(id delegate) {
    if (!delegate) return 0;

    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    if ([className rangeOfString:
            @"VODCommentViewDefaultMessageStringInformationDelegate"].location
            == NSNotFound) {
        return 0;
    }

    // Prefer the runtime ivar offset; keep the verified 0x10 fallback.
    Ivar channelIvar = class_getInstanceVariable(delegateClass, "vodChannelID");
    ptrdiff_t offset = channelIvar ? ivar_getOffset(channelIvar) : 0x10;
    size_t instanceSize = class_getInstanceSize(delegateClass);
    if (offset < (ptrdiff_t)sizeof(void *) ||
        (size_t)offset > instanceSize ||
        instanceSize - (size_t)offset < sizeof(uint32_t)) {
        offset = 0x10;
        if ((size_t)offset > instanceSize ||
            instanceSize - (size_t)offset < sizeof(uint32_t)) {
            return 0;
        }
    }

    uint32_t channelID = 0;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)delegate;
    memcpy(&channelID, bytes + offset, sizeof(channelID));
    return channelID;
}

static void s7tv_captureVODChannelIDFromInformationDelegate(id delegate,
                                                             id sourceObject) {
    uint32_t channelID = s7tv_vodChannelIDFromInformationDelegate(delegate);
    if (channelID == 0) return;

    [[S7TVChannelResolver sharedResolver]
        beginReplayChannelWithID:channelID
                      channelName:nil
                       displayName:nil
                           source:S7TVChannelSourceReplayComment
                       sessionKey:nil
                     sourceObject:sourceObject ?: delegate];
}

static BOOL s7tv_resolverHooksReady = NO;
static BOOL s7tv_resolverRefreshQueued = NO;

static BOOL s7tv_installResolverHooks(void);

static void s7tv_requestResolverHookRefresh(void) {
    @synchronized ([S7TVChannelResolver class]) {
        if (s7tv_resolverHooksReady || s7tv_resolverRefreshQueued) return;
        s7tv_resolverRefreshQueued = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized ([S7TVChannelResolver class]) {
            s7tv_resolverRefreshQueued = NO;
        }
        if (!s7tv_resolverHooksReady) {
            s7tv_resolverHooksReady = s7tv_installResolverHooks();
        }
    });
}

static BOOL s7tv_installNativeHook(Class targetClass,
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

static BOOL s7tv_installResolverHook(Class targetClass,
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
        if (s7tv_installNativeHook(targetClass, originalSelector, hookSelector)) {
            [installed addObject:key];
            return YES;
        }
    }
    return NO;
}

static BOOL s7tv_installVODInformationDelegateHooks(void) {
    unsigned int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) return NO;

    Class *classes = (Class *)malloc(sizeof(Class) * classCount);
    if (!classes) return NO;

    BOOL ready = NO;

    unsigned int actualCount = objc_getClassList(classes, classCount);
    for (unsigned int index = 0; index < actualCount; index++) {
        const char *className = class_getName(classes[index]);
        if (!className ||
            !strstr(className,
                    "VODCommentViewDefaultMessageStringInformationDelegate")) {
            continue;
        }

        Class delegateClass = classes[index];
        BOOL messageStringReady = s7tv_installResolverHook(
            delegateClass,
            @selector(messageString:requestsBitsImageDataForPrefix:quantity:),
            @selector(s7tv_cr_messageString:requestsBitsImageDataForPrefix:quantity:));
        BOOL followerEmotesReady = s7tv_installResolverHook(
            delegateClass,
            @selector(currentChannelUnlockedFollowerEmotesForMessageString:),
            @selector(s7tv_cr_currentChannelUnlockedFollowerEmotesForMessageString:));
        BOOL subscriberEmotesReady = s7tv_installResolverHook(
            delegateClass,
            @selector(currentChannelUnlockedSubscriberEmotesForMessageString:),
            @selector(s7tv_cr_currentChannelUnlockedSubscriberEmotesForMessageString:));
        ready |= messageStringReady && followerEmotesReady && subscriberEmotesReady;
    }

    free(classes);
    return ready;
}

@implementation NSObject (S7TVChannelResolverRuntimeHooks)

- (void)s7tv_cr_addWithChannelIdentity:(id)identity {
    [self s7tv_cr_addWithChannelIdentity:identity];
    s7tv_captureNativeChannelIdentity(identity);
    s7tv_requestResolverHookRefresh();
}

- (void)s7tv_cr_setInformationDelegate:(id)delegate {
    [self s7tv_cr_setInformationDelegate:delegate];
    s7tv_captureVODChannelIDFromInformationDelegate(delegate, self);
}

- (id)s7tv_cr_informationDelegate {
    id delegate = [self s7tv_cr_informationDelegate];
    s7tv_captureVODChannelIDFromInformationDelegate(delegate, self);
    return delegate;
}

- (id)s7tv_cr_messageString:(id)string
    requestsBitsImageDataForPrefix:(id)prefix
                           quantity:(unsigned long long)quantity {
    id result = [self s7tv_cr_messageString:string
           requestsBitsImageDataForPrefix:prefix
                                  quantity:quantity];
    s7tv_captureVODChannelIDFromInformationDelegate(self, nil);
    return result;
}

- (id)s7tv_cr_currentChannelUnlockedFollowerEmotesForMessageString:(id)string {
    id result = [self s7tv_cr_currentChannelUnlockedFollowerEmotesForMessageString:string];
    s7tv_captureVODChannelIDFromInformationDelegate(self, nil);
    return result;
}

- (id)s7tv_cr_currentChannelUnlockedSubscriberEmotesForMessageString:(id)string {
    id result = [self s7tv_cr_currentChannelUnlockedSubscriberEmotesForMessageString:string];
    s7tv_captureVODChannelIDFromInformationDelegate(self, nil);
    return result;
}

- (void)s7tv_cr_setActiveChannelID:(unsigned int)channelID {
    [self s7tv_cr_setActiveChannelID:channelID];
    [[S7TVChannelResolver sharedResolver]
        s7tv_setNativeActiveLiveChannelID:channelID
                             sourceObject:self];
    s7tv_requestResolverHookRefresh();
}

- (void)s7tv_cr_resetActiveChannelID {
    [self s7tv_cr_resetActiveChannelID];
    [[S7TVChannelResolver sharedResolver] s7tv_clearNativeLiveChannel];
}

- (void)s7tv_cr_setChannelName:(id)name {
    [self s7tv_cr_setChannelName:name];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_setChannelDisplayName:(id)name {
    [self s7tv_cr_setChannelDisplayName:name];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_updateConnectionStatus:(long long)status
                   withTTVErrorCode:(int)code
                    errorCodeString:(id)string {
    [self s7tv_cr_updateConnectionStatus:status
                       withTTVErrorCode:code
                        errorCodeString:string];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_addMessages:(id)messages {
    [self s7tv_cr_addMessages:messages];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_prependMessages:(id)messages {
    [self s7tv_cr_prependMessages:messages];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_addMessagesToChatLog:(id)log {
    [self s7tv_cr_addMessagesToChatLog:log];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_prependMessagesToChatLog:(id)log {
    [self s7tv_cr_prependMessagesToChatLog:log];
    s7tv_captureNativeConnectionIdentity(self);
}

- (void)s7tv_cr_connect {
    [self s7tv_cr_connect];
    s7tv_captureNativeConnectionIdentity(self);
}

@end

static BOOL s7tv_installResolverHooks(void) {
    BOOL managerReady = NO;
    for (NSString *className in @[
        @"Twitch.TwitchChatManager",
        @"_TtC6Twitch17TwitchChatManager"
    ]) {
        Class managerClass = NSClassFromString(className);
        BOOL addIdentityReady = s7tv_installResolverHook(managerClass,
                                  @selector(addWithChannelIdentity:),
                                  @selector(s7tv_cr_addWithChannelIdentity:));
        BOOL activeChannelReady = s7tv_installResolverHook(managerClass,
                                  @selector(setActiveChannelID:),
                                  @selector(s7tv_cr_setActiveChannelID:));
        BOOL resetChannelReady = s7tv_installResolverHook(managerClass,
                                  @selector(resetActiveChannelID),
                                  @selector(s7tv_cr_resetActiveChannelID));
        managerReady |= addIdentityReady && activeChannelReady && resetChannelReady;
    }

    BOOL connectionReady = NO;
    for (NSString *className in @[
        @"Twitch.ChannelChatConnectionController",
        @"_TtC6Twitch31ChannelChatConnectionController"
    ]) {
        Class connectionClass = NSClassFromString(className);
        BOOL channelNameReady = s7tv_installResolverHook(connectionClass,
                                  @selector(setChannelName:),
                                  @selector(s7tv_cr_setChannelName:));
        BOOL displayNameReady = s7tv_installResolverHook(connectionClass,
                                  @selector(setChannelDisplayName:),
                                  @selector(s7tv_cr_setChannelDisplayName:));
        BOOL statusReady = s7tv_installResolverHook(connectionClass,
                                  @selector(updateConnectionStatus:withTTVErrorCode:errorCodeString:),
                                  @selector(s7tv_cr_updateConnectionStatus:withTTVErrorCode:errorCodeString:));
        BOOL addMessagesReady = s7tv_installResolverHook(connectionClass,
                                  @selector(addMessages:),
                                  @selector(s7tv_cr_addMessages:));
        BOOL prependMessagesReady = s7tv_installResolverHook(connectionClass,
                                  @selector(prependMessages:),
                                  @selector(s7tv_cr_prependMessages:));
        BOOL addLogReady = s7tv_installResolverHook(connectionClass,
                                  @selector(addMessagesToChatLog:),
                                  @selector(s7tv_cr_addMessagesToChatLog:));
        BOOL prependLogReady = s7tv_installResolverHook(connectionClass,
                                  @selector(prependMessagesToChatLog:),
                                  @selector(s7tv_cr_prependMessagesToChatLog:));
        BOOL connectReady = s7tv_installResolverHook(connectionClass,
                                  @selector(connect),
                                  @selector(s7tv_cr_connect));
        connectionReady |= channelNameReady && displayNameReady && statusReady &&
            addMessagesReady && prependMessagesReady && addLogReady &&
            prependLogReady && connectReady;
    }

    BOOL messageStringReady = NO;
    for (NSString *className in @[
        @"Twitch.MessageString",
        @"_TtC6Twitch13MessageString"
    ]) {
        Class messageStringClass = NSClassFromString(className);
        BOOL delegateSetterReady = s7tv_installResolverHook(messageStringClass,
                                  @selector(setInformationDelegate:),
                                  @selector(s7tv_cr_setInformationDelegate:));
        BOOL delegateGetterReady = s7tv_installResolverHook(messageStringClass,
                                  @selector(informationDelegate),
                                  @selector(s7tv_cr_informationDelegate));
        messageStringReady |= delegateSetterReady && delegateGetterReady;
    }

    BOOL vodReady = s7tv_installVODInformationDelegateHooks();
    return managerReady && connectionReady && messageStringReady && vodReady;
}

void S7TVChannelResolverSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s7tv_resolverHooksReady = s7tv_installResolverHooks();

        // Twitch loads Swift chat classes lazily.
        for (NSNumber *delay in @[@0.25, @1.0, @3.0, @6.0, @12.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(delay.doubleValue *
                                                    NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!s7tv_resolverHooksReady) {
                    s7tv_resolverHooksReady = s7tv_installResolverHooks();
                }
            });
        }
    });
}

void S7TVChannelResolverRefresh(void) {
    if (NSThread.isMainThread) {
        if (!s7tv_resolverHooksReady) {
            s7tv_resolverHooksReady = s7tv_installResolverHooks();
        }
    } else {
        s7tv_requestResolverHookRefresh();
    }
}
