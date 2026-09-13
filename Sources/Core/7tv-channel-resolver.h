#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, S7TVChannelMediaKind) {
    S7TVChannelMediaKindUnknown = 0,
    S7TVChannelMediaKindLive,
    S7TVChannelMediaKindReplay,
};

typedef NS_ENUM(NSUInteger, S7TVChannelSource) {
    S7TVChannelSourceUnknown = 0,
    S7TVChannelSourceLiveChat,
    S7TVChannelSourceLiveMetadata,
    S7TVChannelSourceReplayComment,
};

FOUNDATION_EXPORT NSNotificationName const S7TVChannelResolverDidChangeNotification;

@interface S7TVChannelContext : NSObject <NSCopying>

@property (nonatomic, readonly) uint32_t channelID;
@property (nonatomic, copy, readonly, nullable) NSString *channelName;
@property (nonatomic, copy, readonly, nullable) NSString *displayName;
@property (nonatomic, readonly) S7TVChannelMediaKind mediaKind;
@property (nonatomic, readonly) S7TVChannelSource source;
@property (nonatomic, copy, readonly) NSUUID *sessionID;
@property (nonatomic, copy, readonly, nullable) NSString *sessionKey;
@property (nonatomic, readonly) NSUInteger generation;
@property (nonatomic, weak, readonly, nullable) id sourceObject;

- (BOOL)matchesChannelID:(uint32_t)channelID;

@end

@interface S7TVChannelResolver : NSObject

+ (instancetype)sharedResolver;

@property (nonatomic, copy, readonly, nullable) S7TVChannelContext *currentContext;

// Channel ID is required; names are metadata only.
- (nullable S7TVChannelContext *)beginLiveChannelWithID:(uint32_t)channelID
                                          channelName:(nullable NSString *)channelName
                                           displayName:(nullable NSString *)displayName
                                               source:(S7TVChannelSource)source
                                           sessionKey:(nullable NSString *)sessionKey
                                         sourceObject:(nullable id)sourceObject;

- (nullable S7TVChannelContext *)beginReplayChannelWithID:(uint32_t)channelID
                                            channelName:(nullable NSString *)channelName
                                             displayName:(nullable NSString *)displayName
                                                 source:(S7TVChannelSource)source
                                             sessionKey:(nullable NSString *)sessionKey
                                           sourceObject:(nullable id)sourceObject;

- (BOOL)isCurrentContext:(nullable S7TVChannelContext *)context;
- (BOOL)isCurrentSessionID:(nullable NSUUID *)sessionID
                 channelID:(uint32_t)channelID
                generation:(NSUInteger)generation;

- (void)invalidateCurrentContext;
- (BOOL)invalidateIfCurrentContext:(nullable S7TVChannelContext *)context;
- (BOOL)invalidateIfCurrentSessionID:(nullable NSUUID *)sessionID
                           channelID:(uint32_t)channelID
                          generation:(NSUInteger)generation;
- (BOOL)invalidateIfSourceObject:(nullable id)sourceObject;

@end

// Installe les hooks natifs Twitch du resolver.
FOUNDATION_EXPORT void S7TVChannelResolverSetup(void);
FOUNDATION_EXPORT void S7TVChannelResolverRefresh(void);

FOUNDATION_EXPORT S7TVChannelContext * _Nullable S7TVCurrentChannelContext(void);
FOUNDATION_EXPORT BOOL S7TVChannelContextIsCurrent(S7TVChannelContext * _Nullable context);

NS_ASSUME_NONNULL_END
