// Shared provider-agnostic emote catalogue; TPKManager remains the 7TV facade.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPKEmoteProviderID) {
    TPKEmoteProviderIDTPK = 0,
    TPKEmoteProviderIDBTTV,
    TPKEmoteProviderIDFFZ,
};

typedef NS_ENUM(NSInteger, TPKEmoteSectionKind) {
    TPKEmoteSectionKindChannel = 0,
    TPKEmoteSectionKindShared,
    TPKEmoteSectionKindGlobal,
    TPKEmoteSectionKindSet,
    TPKEmoteSectionKindFavorites,
};

typedef NS_ENUM(NSInteger, TPKEmoteProviderState) {
    TPKEmoteProviderStateIdle = 0,
    TPKEmoteProviderStateLoading,
    TPKEmoteProviderStateLoaded,
    TPKEmoteProviderStateError,
};

FOUNDATION_EXPORT NSString *const TPKProviderCatalogDidUpdateNotification;
FOUNDATION_EXPORT TPKEmoteProviderID TPKEmoteProviderFromIdentifier(
    NSString * _Null_unspecified identifier);
FOUNDATION_EXPORT NSString *TPKEmoteProviderName(TPKEmoteProviderID provider);
FOUNDATION_EXPORT NSString *TPKEmoteProviderKey(TPKEmoteProviderID provider);
FOUNDATION_EXPORT NSString *TPKEmoteFavoriteKey(TPKEmoteProviderID provider,
                                                  NSString *emoteID);

// Provider-neutral emote; imageURLs uses scale keys and modifiers are reserved for v2.
@interface TPKEmoteDescriptor : NSObject <NSCopying>
@property (nonatomic, assign, readonly) TPKEmoteProviderID provider;
@property (nonatomic, copy, readonly) NSString *providerIdentifier;
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, copy, readonly) NSString *emoteID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<NSString *> *aliases;
@property (nonatomic, assign, readonly) TPKEmoteSectionKind sectionKind;
@property (nonatomic, copy, readonly) NSString *sectionIdentifier;
@property (nonatomic, copy, readonly) NSString *sectionTitle;
@property (nonatomic, copy, readonly, nullable) NSString *setID;
@property (nonatomic, assign, readonly) CGSize nativeSize;
@property (nonatomic, assign, readonly) BOOL animated;
@property (nonatomic, assign, readonly) BOOL zeroWidth;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *modifierMetadata;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSString *> *imageURLs;

- (instancetype)initWithProvider:(TPKEmoteProviderID)provider
               providerIdentifier:(NSString *)providerIdentifier
                           emoteID:(NSString *)emoteID
                              name:(NSString *)name
                           aliases:(NSArray<NSString *> *)aliases
                       sectionKind:(TPKEmoteSectionKind)sectionKind
                sectionIdentifier:(NSString *)sectionIdentifier
                       sectionTitle:(NSString *)sectionTitle
                             setID:(nullable NSString *)setID
                        nativeSize:(CGSize)nativeSize
                          animated:(BOOL)animated
                         zeroWidth:(BOOL)zeroWidth
                  modifierMetadata:(NSDictionary<NSString *, id> *)modifierMetadata
                         imageURLs:(NSDictionary<NSNumber *, NSString *> *)imageURLs;

- (nullable NSURL *)imageURLForResolution:(NSInteger)resolution;
@end

@interface TPKEmoteSection : NSObject <NSCopying>
@property (nonatomic, assign, readonly) TPKEmoteProviderID provider;
@property (nonatomic, assign, readonly) TPKEmoteSectionKind kind;
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<TPKEmoteDescriptor *> *emotes;
@property (nonatomic, assign, readonly) BOOL loaded;
@property (nonatomic, assign, readonly) BOOL loading;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

- (instancetype)initWithProvider:(TPKEmoteProviderID)provider
                              kind:(TPKEmoteSectionKind)kind
                        identifier:(NSString *)identifier
                             title:(NSString *)title
                            emotes:(NSArray<TPKEmoteDescriptor *> *)emotes
                            loaded:(BOOL)loaded
                           loading:(BOOL)loading
                      errorMessage:(nullable NSString *)errorMessage;
@end

@interface TPKEmoteProviderSnapshot : NSObject <NSCopying>
@property (nonatomic, assign, readonly) TPKEmoteProviderID provider;
@property (nonatomic, assign, readonly) TPKEmoteProviderState state;
@property (nonatomic, copy, readonly) NSString *channelID;
@property (nonatomic, copy, readonly) NSArray<TPKEmoteSection *> *sections;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;
@end

@interface TPKEmoteCatalog : NSObject
+ (instancetype)sharedCatalog;

@property (nonatomic, copy, readonly) NSArray<NSNumber *> *providerPriority;

- (TPKEmoteProviderSnapshot *)snapshotForProvider:(TPKEmoteProviderID)provider;
- (NSArray<TPKEmoteSection *> *)sectionsForProvider:(TPKEmoteProviderID)provider;
- (NSArray<TPKEmoteDescriptor *> *)allEmotesForProvider:(TPKEmoteProviderID)provider;
// Resolve exact, case-sensitive names and aliases within one provider.
- (nullable TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name
                                           provider:(TPKEmoteProviderID)provider;
// Resolve according to the configured cross-provider priority.
- (nullable TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name;

// Load from cache first; completion runs on main and failures stay provider-local.
- (void)loadGlobalProviders;
- (void)loadChannelProvidersForTwitchID:(NSString *)twitchID;
// Remove the active channel scope while keeping provider-global emotes.
- (void)clearActiveChannelScope;
// Load an optional 7TV set when its picker section expands or retries.
- (void)loadTPKEmoteSetWithID:(NSString *)setID
                            global:(BOOL)global
                           channel:(nullable NSString *)twitchID;
- (void)loadSetForProvider:(TPKEmoteProviderID)provider
                identifier:(NSString *)identifier
                    global:(BOOL)global
                   channel:(nullable NSString *)twitchID;
- (void)loadProvider:(TPKEmoteProviderID)provider
             global:(BOOL)global
           channel:(nullable NSString *)twitchID
         completion:(nullable void (^)(TPKEmoteProviderSnapshot *snapshot))completion;
- (void)cancelLoadsForChannel:(NSString *)twitchID;

// Clear provider snapshots and requests; complete on main after cache work finishes.
- (void)clearCachedDataWithCompletion:(nullable dispatch_block_t)completion;

// Provider-aware favorites; legacy tpk_favorites data is migrated lazily.
- (BOOL)isEmoteFavorited:(TPKEmoteDescriptor *)emote;
- (void)setEmote:(TPKEmoteDescriptor *)emote favorited:(BOOL)favorited;
- (void)setLegacyTPKFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited;
- (void)replaceLegacyTPKFavoriteIDs:(NSArray<NSString *> *)emoteIDs;
- (void)setFavoriteKey:(NSString *)favoriteKey favorited:(BOOL)favorited;
- (NSArray<NSString *> *)favoriteKeysSnapshot;
// Stored metadata keeps favorites available offline or outside their source channel.
- (NSArray<TPKEmoteDescriptor *> *)favoriteDescriptorsSnapshot;

// Store Zero-Width text sequences so selecting any member restores the composition.
- (nullable NSString *)favoriteCompositionTextForEmoteKey:(NSString *)emoteKey;
@end

NS_ASSUME_NONNULL_END
