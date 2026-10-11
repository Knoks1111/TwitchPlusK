#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, TPKChannelMediaKind) {
    TPKChannelMediaKindUnknown = 0,
    TPKChannelMediaKindLive,
    TPKChannelMediaKindReplay,
};

typedef NS_ENUM(NSUInteger, TPKChannelSource) {
    TPKChannelSourceUnknown = 0,
    TPKChannelSourceLiveChat,
    TPKChannelSourceLiveMetadata,
    TPKChannelSourceReplayComment,
};

FOUNDATION_EXPORT NSNotificationName const TPKChannelResolverDidChangeNotification;

@interface TPKChannelContext : NSObject <NSCopying>

@property (nonatomic, readonly) uint32_t channelID;
@property (nonatomic, copy, readonly, nullable) NSString *channelName;
@property (nonatomic, copy, readonly, nullable) NSString *displayName;
@property (nonatomic, readonly) TPKChannelMediaKind mediaKind;
@property (nonatomic, readonly) TPKChannelSource source;
@property (nonatomic, copy, readonly) NSUUID *sessionID;
@property (nonatomic, copy, readonly, nullable) NSString *sessionKey;
@property (nonatomic, readonly) NSUInteger generation;
@property (nonatomic, weak, readonly, nullable) id sourceObject;

- (BOOL)matchesChannelID:(uint32_t)channelID;

@end

@interface TPKChannelResolver : NSObject

+ (instancetype)sharedResolver;

@property (nonatomic, copy, readonly, nullable) TPKChannelContext *currentContext;

// Channel ID is required; names are metadata only.
- (nullable TPKChannelContext *)beginLiveChannelWithID:(uint32_t)channelID
                                          channelName:(nullable NSString *)channelName
                                           displayName:(nullable NSString *)displayName
                                               source:(TPKChannelSource)source
                                           sessionKey:(nullable NSString *)sessionKey
                                         sourceObject:(nullable id)sourceObject;

- (nullable TPKChannelContext *)beginReplayChannelWithID:(uint32_t)channelID
                                            channelName:(nullable NSString *)channelName
                                             displayName:(nullable NSString *)displayName
                                                 source:(TPKChannelSource)source
                                             sessionKey:(nullable NSString *)sessionKey
                                           sourceObject:(nullable id)sourceObject;

- (BOOL)isCurrentContext:(nullable TPKChannelContext *)context;
- (BOOL)isCurrentSessionID:(nullable NSUUID *)sessionID
                 channelID:(uint32_t)channelID
                generation:(NSUInteger)generation;

- (void)invalidateCurrentContext;
- (BOOL)invalidateIfCurrentContext:(nullable TPKChannelContext *)context;
- (BOOL)invalidateIfCurrentSessionID:(nullable NSUUID *)sessionID
                           channelID:(uint32_t)channelID
                          generation:(NSUInteger)generation;
- (BOOL)invalidateIfSourceObject:(nullable id)sourceObject;

@end

// Installe les hooks natifs Twitch du resolver.
FOUNDATION_EXPORT void TPKChannelResolverSetup(void);
FOUNDATION_EXPORT void TPKChannelResolverRefresh(void);

// Secours indépendant du chat : login vu sur une playlist usher live.
// Résout l'ID via Helix et nourrit le resolver (toutes versions).
FOUNDATION_EXPORT void TPKChannelResolverNoteStreamLogin(NSString * _Nullable login);

FOUNDATION_EXPORT TPKChannelContext * _Nullable TPKCurrentChannelContext(void);
FOUNDATION_EXPORT BOOL TPKChannelContextIsCurrent(TPKChannelContext * _Nullable context);

NS_ASSUME_NONNULL_END
