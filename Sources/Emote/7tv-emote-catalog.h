/*
 * 7tv-emote-catalog.h
 *
 * Provider-agnostic emote catalogue.  The legacy SevenTVManager remains the
 * compatibility facade for existing 7TV callers; this catalogue is the
 * shared data layer used by the multi-provider picker/chat implementation.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVEmoteProviderID) {
    S7TVEmoteProviderIDSevenTV = 0,
    S7TVEmoteProviderIDBTTV,
    S7TVEmoteProviderIDFFZ,
};

typedef NS_ENUM(NSInteger, S7TVEmoteSectionKind) {
    S7TVEmoteSectionKindChannel = 0,
    S7TVEmoteSectionKindShared,
    S7TVEmoteSectionKindGlobal,
    S7TVEmoteSectionKindSet,
    S7TVEmoteSectionKindFavorites,
};

typedef NS_ENUM(NSInteger, S7TVEmoteProviderState) {
    S7TVEmoteProviderStateIdle = 0,
    S7TVEmoteProviderStateLoading,
    S7TVEmoteProviderStateLoaded,
    S7TVEmoteProviderStateError,
};

FOUNDATION_EXPORT NSString *const S7TVProviderCatalogDidUpdateNotification;
FOUNDATION_EXPORT NSString *S7TVEmoteProviderName(S7TVEmoteProviderID provider);
FOUNDATION_EXPORT NSString *S7TVEmoteProviderKey(S7TVEmoteProviderID provider);
FOUNDATION_EXPORT NSString *S7TVEmoteFavoriteKey(S7TVEmoteProviderID provider,
                                                  NSString *emoteID);

// One emote independently of the API which supplied it.  imageURLs is keyed
// by NSNumber scales (1, 2, 3, 4).  The model keeps modifier metadata ready
// for the effects phase, while v1 only uses zeroWidth.
@interface S7TVEmoteDescriptor : NSObject <NSCopying>
@property (nonatomic, assign, readonly) S7TVEmoteProviderID provider;
@property (nonatomic, copy, readonly) NSString *providerIdentifier;
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, copy, readonly) NSString *emoteID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<NSString *> *aliases;
@property (nonatomic, assign, readonly) S7TVEmoteSectionKind sectionKind;
@property (nonatomic, copy, readonly) NSString *sectionIdentifier;
@property (nonatomic, copy, readonly) NSString *sectionTitle;
@property (nonatomic, copy, readonly, nullable) NSString *setID;
@property (nonatomic, assign, readonly) CGSize nativeSize;
@property (nonatomic, assign, readonly) BOOL animated;
@property (nonatomic, assign, readonly) BOOL zeroWidth;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *modifierMetadata;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSString *> *imageURLs;

- (instancetype)initWithProvider:(S7TVEmoteProviderID)provider
               providerIdentifier:(NSString *)providerIdentifier
                           emoteID:(NSString *)emoteID
                              name:(NSString *)name
                           aliases:(NSArray<NSString *> *)aliases
                       sectionKind:(S7TVEmoteSectionKind)sectionKind
                sectionIdentifier:(NSString *)sectionIdentifier
                       sectionTitle:(NSString *)sectionTitle
                             setID:(nullable NSString *)setID
                        nativeSize:(CGSize)nativeSize
                          animated:(BOOL)animated
                         zeroWidth:(BOOL)zeroWidth
                  modifierMetadata:(NSDictionary<NSString *, id> *)modifierMetadata
                         imageURLs:(NSDictionary<NSNumber *, NSString *> *)imageURLs;

- (nullable NSURL *)imageURLForResolution:(NSInteger)resolution;
- (BOOL)matchesName:(NSString *)name;
@end

@interface S7TVEmoteSection : NSObject <NSCopying>
@property (nonatomic, assign, readonly) S7TVEmoteProviderID provider;
@property (nonatomic, assign, readonly) S7TVEmoteSectionKind kind;
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSArray<S7TVEmoteDescriptor *> *emotes;
@property (nonatomic, assign, readonly) BOOL loaded;
@property (nonatomic, assign, readonly) BOOL loading;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

- (instancetype)initWithProvider:(S7TVEmoteProviderID)provider
                              kind:(S7TVEmoteSectionKind)kind
                        identifier:(NSString *)identifier
                             title:(NSString *)title
                            emotes:(NSArray<S7TVEmoteDescriptor *> *)emotes
                            loaded:(BOOL)loaded
                           loading:(BOOL)loading
                      errorMessage:(nullable NSString *)errorMessage;
@end

@interface S7TVEmoteProviderSnapshot : NSObject <NSCopying>
@property (nonatomic, assign, readonly) S7TVEmoteProviderID provider;
@property (nonatomic, assign, readonly) S7TVEmoteProviderState state;
@property (nonatomic, copy, readonly) NSString *channelID;
@property (nonatomic, copy, readonly) NSArray<S7TVEmoteSection *> *sections;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;
@end

@interface S7TVEmoteCatalog : NSObject
+ (instancetype)sharedCatalog;

@property (nonatomic, copy) NSArray<NSNumber *> *providerPriority;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *providerEnabled;

- (S7TVEmoteProviderSnapshot *)snapshotForProvider:(S7TVEmoteProviderID)provider;
- (NSArray<S7TVEmoteSection *> *)sectionsForProvider:(S7TVEmoteProviderID)provider;
- (NSArray<S7TVEmoteDescriptor *> *)allEmotesForProvider:(S7TVEmoteProviderID)provider;
// Resolve within one provider without scanning every emote for each chat
// token.  The catalogue keeps a name/alias index for this path; matching is
// still exact and case-sensitive, just like S7TVEmoteDescriptor.
- (nullable S7TVEmoteDescriptor *)resolveEmoteNamed:(NSString *)name
                                           provider:(S7TVEmoteProviderID)provider;
// Resolve according to the configured cross-provider priority.
- (nullable S7TVEmoteDescriptor *)resolveEmoteNamed:(NSString *)name;

// Cache-first loads. Completion is delivered on the main queue and is
// provider-local: one provider failing does not affect the other snapshots.
- (void)loadGlobalProviders;
- (void)loadChannelProvidersForTwitchID:(NSString *)twitchID;
// Loads one optional 7TV set on demand. The channel/user payload advertises
// set IDs before their emotes are needed; the picker calls this when a set
// section is expanded (or its retry button is pressed).
- (void)loadSevenTVEmoteSetWithID:(NSString *)setID
                            global:(BOOL)global
                           channel:(nullable NSString *)twitchID;
- (void)loadSetForProvider:(S7TVEmoteProviderID)provider
                identifier:(NSString *)identifier
                    global:(BOOL)global
                   channel:(nullable NSString *)twitchID;
- (void)loadProvider:(S7TVEmoteProviderID)provider
             global:(BOOL)global
           channel:(nullable NSString *)twitchID
         completion:(nullable void (^)(S7TVEmoteProviderSnapshot *snapshot))completion;
- (void)cancelLoadsForChannel:(NSString *)twitchID;

// Clear provider JSON snapshots and in-flight catalogue requests.  The
// completion is delivered on the main queue after the serial state/cache
// work has finished, so a manual cache reset can safely start fresh loads.
- (void)clearCachedDataWithCompletion:(nullable dispatch_block_t)completion;

// Provider-aware favorites. The old s7tv_favorites array is migrated lazily
// into these qualified keys and remains untouched for legacy callers.
- (BOOL)isEmoteFavorited:(S7TVEmoteDescriptor *)emote;
- (void)setEmote:(S7TVEmoteDescriptor *)emote favorited:(BOOL)favorited;
- (void)setLegacySevenTVFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited;
- (void)replaceLegacySevenTVFavoriteIDs:(NSArray<NSString *> *)emoteIDs;
- (void)setFavoriteKey:(NSString *)favoriteKey favorited:(BOOL)favorited;
- (NSArray<NSString *> *)favoriteKeysSnapshot;
// Provider-aware favorite descriptors are backed by a small metadata store.
// They remain available in the Favorites picker/settings screen when the
// channel that supplied them is no longer the active one or the network is
// offline.  A loaded provider snapshot transparently refreshes the metadata.
- (NSArray<S7TVEmoteDescriptor *> *)favoriteDescriptorsSnapshot;

// A Zero-Width composition is a single chat gesture but contains several
// provider-qualified favorites.  Keep the exact text sequence separately so
// selecting either member from the picker can reproduce the composition.
- (nullable NSString *)favoriteCompositionTextForEmoteKey:(NSString *)emoteKey;
- (void)setFavoriteCompositionText:(nullable NSString *)text
                  forBaseEmoteKey:(NSString *)baseEmoteKey
                        memberKeys:(NSArray<NSString *> *)memberKeys;
@end

NS_ASSUME_NONNULL_END
