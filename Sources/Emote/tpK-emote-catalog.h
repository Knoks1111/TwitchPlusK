/*
 * tpK-emote-catalog.h
 *
 * Provider-agnostic emote catalogue.  The legacy TPKManager remains the
 * compatibility facade for existing 7TV callers; this catalogue is the
 * shared data layer used by the multi-provider picker/chat implementation.
 */

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
FOUNDATION_EXPORT NSString *TPKEmoteProviderName(TPKEmoteProviderID provider);
FOUNDATION_EXPORT NSString *TPKEmoteProviderKey(TPKEmoteProviderID provider);
FOUNDATION_EXPORT NSString *TPKEmoteFavoriteKey(TPKEmoteProviderID provider,
                                                  NSString *emoteID);

// One emote independently of the API which supplied it.  imageURLs is keyed
// by NSNumber scales (1, 2, 3, 4).  The model keeps modifier metadata ready
// for the effects phase, while v1 only uses zeroWidth.
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
- (BOOL)matchesName:(NSString *)name;
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

@property (nonatomic, copy) NSArray<NSNumber *> *providerPriority;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *providerEnabled;

- (TPKEmoteProviderSnapshot *)snapshotForProvider:(TPKEmoteProviderID)provider;
- (NSArray<TPKEmoteSection *> *)sectionsForProvider:(TPKEmoteProviderID)provider;
- (NSArray<TPKEmoteDescriptor *> *)allEmotesForProvider:(TPKEmoteProviderID)provider;
// Resolve within one provider without scanning every emote for each chat
// token.  The catalogue keeps a name/alias index for this path; matching is
// still exact and case-sensitive, just like TPKEmoteDescriptor.
- (nullable TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name
                                           provider:(TPKEmoteProviderID)provider;
// Resolve according to the configured cross-provider priority.
- (nullable TPKEmoteDescriptor *)resolveEmoteNamed:(NSString *)name;

// Cache-first loads. Completion is delivered on the main queue and is
// provider-local: one provider failing does not affect the other snapshots.
- (void)loadGlobalProviders;
- (void)loadChannelProvidersForTwitchID:(NSString *)twitchID;
// Remove the active channel scope while keeping provider-global emotes.
- (void)clearActiveChannelScope;
// Loads one optional 7TV set on demand. The channel/user payload advertises
// set IDs before their emotes are needed; the picker calls this when a set
// section is expanded (or its retry button is pressed).
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

// Clear provider JSON snapshots and in-flight catalogue requests.  The
// completion is delivered on the main queue after the serial state/cache
// work has finished, so a manual cache reset can safely start fresh loads.
- (void)clearCachedDataWithCompletion:(nullable dispatch_block_t)completion;

// Provider-aware favorites. The old tpk_favorites array is migrated lazily
// into these qualified keys and remains untouched for legacy callers.
- (BOOL)isEmoteFavorited:(TPKEmoteDescriptor *)emote;
- (void)setEmote:(TPKEmoteDescriptor *)emote favorited:(BOOL)favorited;
- (void)setLegacyTPKFavoriteID:(NSString *)emoteID favorited:(BOOL)favorited;
- (void)replaceLegacyTPKFavoriteIDs:(NSArray<NSString *> *)emoteIDs;
- (void)setFavoriteKey:(NSString *)favoriteKey favorited:(BOOL)favorited;
- (NSArray<NSString *> *)favoriteKeysSnapshot;
// Provider-aware favorite descriptors are backed by a small metadata store.
// They remain available in the Favorites picker/settings screen when the
// channel that supplied them is no longer the active one or the network is
// offline.  A loaded provider snapshot transparently refreshes the metadata.
- (NSArray<TPKEmoteDescriptor *> *)favoriteDescriptorsSnapshot;

// A Zero-Width composition is a single chat gesture but contains several
// provider-qualified favorites.  Keep the exact text sequence separately so
// selecting either member from the picker can reproduce the composition.
- (nullable NSString *)favoriteCompositionTextForEmoteKey:(NSString *)emoteKey;
- (void)setFavoriteCompositionText:(nullable NSString *)text
                  forBaseEmoteKey:(NSString *)baseEmoteKey
                        memberKeys:(NSArray<NSString *> *)memberKeys;
@end

NS_ASSUME_NONNULL_END
