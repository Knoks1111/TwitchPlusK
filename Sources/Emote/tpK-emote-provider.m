/*
 * tpK-emote-provider.m
 *
 * Voir tpK-emote-provider.h pour le contexte (Phase 2).
 */

#import "Emote/tpK-emote-provider.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-provider-settings.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Chat/tpK-chat-message.h" // TPKChatTokenTypeEmote7TV

// Adapter around the provider-agnostic catalogue.  Keeping the descriptor
// behind the existing resolved-emote protocol means the image cache and the
// TextKit renderer work unchanged for BTTV/FFZ.
@interface TPKResolvedCatalogEmote : NSObject <TPKResolvedEmote>
@property (nonatomic, copy) NSString *emoteID;
@property (nonatomic, assign) CGSize nativeSize;
@property (nonatomic, assign) BOOL isAnimated;
@property (nonatomic, strong) NSURL *imageURL;
@property (nonatomic, copy) NSString *providerIdentifier;
@property (nonatomic, copy) NSString *providerName;
@property (nonatomic, assign) BOOL zeroWidth;
@end

@implementation TPKResolvedCatalogEmote
@end

static NSInteger tpk_emoteResolution(void) {
    TPKChatAppearanceConfig *config = [TPKChatAppearanceConfig sharedConfig];
    NSInteger resolution = 2;
    // The generic setting is introduced by the settings/catalogue layer. Use
    // KVC so older preference objects remain source-compatible during an
    // upgrade from emote7TVResolution.
    if ([config respondsToSelector:@selector(emoteImageResolution)]) {
        resolution = [[config valueForKey:@"emoteImageResolution"] integerValue];
    } else {
        resolution = config.emote7TVResolution;
    }
    return MIN(4, MAX(1, resolution));
}

static id<TPKResolvedEmote> tpk_resolvedCatalogEmote(TPKEmoteDescriptor *descriptor) {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    TPKResolvedCatalogEmote *resolved = [TPKResolvedCatalogEmote new];
    resolved.emoteID = descriptor.emoteID;
    resolved.nativeSize = descriptor.nativeSize;
    resolved.isAnimated = descriptor.animated;
    resolved.providerIdentifier = descriptor.providerIdentifier;
    resolved.providerName = TPKEmoteProviderName(descriptor.provider);
    resolved.zeroWidth = descriptor.zeroWidth;
    resolved.imageURL = [descriptor imageURLForResolution:tpk_emoteResolution()];
    return resolved.imageURL ? resolved : nil;
}

@interface TPKProviderEmoteAdapter : NSObject <TPKEmoteProvider>
@property (nonatomic, assign) TPKEmoteProviderID providerID;
@end

@implementation TPKProviderEmoteAdapter
- (nullable id<TPKResolvedEmote>)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    if (![TPKEmoteProviderSettings isProviderEnabled:
            (TPKExternalEmoteProvider)self.providerID]) return nil;
    TPKEmoteDescriptor *descriptor = [catalog resolveEmoteNamed:name
                                                            provider:self.providerID];
    if (descriptor) return tpk_resolvedCatalogEmote(descriptor);
    return nil;
}
- (NSInteger)tokenType { return TPKChatTokenTypeEmote7TV; }
@end

@interface TPKBTTVEmoteProvider : TPKProviderEmoteAdapter @end
@interface TPKFFZEmoteProvider : TPKProviderEmoteAdapter @end
@implementation TPKBTTVEmoteProvider
- (instancetype)init { self = [super init]; if (self) self.providerID = TPKEmoteProviderIDBTTV; return self; }
@end
@implementation TPKFFZEmoteProvider
- (instancetype)init { self = [super init]; if (self) self.providerID = TPKEmoteProviderIDFFZ; return self; }
@end

NSArray<id<TPKEmoteProvider>> *tpk_chatEmoteProviders(void) {
    static NSArray<id<TPKEmoteProvider>> *allProviders = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allProviders = @[[TPKTPKEmoteProvider new],
                         [TPKBTTVEmoteProvider new],
                         [TPKFFZEmoteProvider new]];
    });

    // The tokenizer receives providers in the configured collision-priority
    // order.  Keep the instances stable (important for in-flight UI work)
    // while deriving the order on every call so a settings change applies to
    // the next message without restarting chat.
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:allProviders.count];
    for (NSString *identifier in [TPKEmoteProviderSettings providerPriority]) {
        TPKEmoteProviderID provider =
            (TPKEmoteProviderID)TPKEmoteProviderFromIdentifier(identifier);
        for (id<TPKEmoteProvider> candidate in allProviders) {
            if ([candidate respondsToSelector:@selector(providerID)] &&
                [candidate providerID] == provider) {
                [ordered addObject:candidate];
                break;
            }
        }
    }
    for (id<TPKEmoteProvider> candidate in allProviders) {
        if (![ordered containsObject:candidate]) [ordered addObject:candidate];
    }
    return ordered.copy;
}

// ============================================================
// MARK: - TPKTPKEmoteProvider
// ============================================================

@implementation TPKTPKEmoteProvider

- (NSInteger)providerID { return TPKEmoteProviderIDTPK; }

- (nullable id<TPKResolvedEmote>)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;

    if (![TPKEmoteProviderSettings isProviderEnabled:TPKExternalEmoteProvider7TV])
        return nil;

    // The shared catalogue is the single source of truth for aliases,
    // Zero-Width flags, provider identity and cache-backed availability.
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    if ([catalog.providerEnabled[@(TPKEmoteProviderIDTPK)] boolValue]) {
        TPKEmoteDescriptor *descriptor =
            [catalog resolveEmoteNamed:name provider:TPKEmoteProviderIDTPK];
        if (descriptor) return tpk_resolvedCatalogEmote(descriptor);
    }
    return nil;
}

- (NSInteger)tokenType {
    return TPKChatTokenTypeEmote7TV;
}

@end


// ============================================================
// MARK: - TPKResolvedTwitchEmote / TPKTwitchNativeEmoteFactory
// ============================================================

@interface TPKResolvedTwitchEmote : NSObject <TPKResolvedEmote>
@property (nonatomic, copy)   NSString *emoteID;
@property (nonatomic, assign) CGSize    nativeSize;
@property (nonatomic, assign) BOOL      isAnimated;
@property (nonatomic, strong) NSURL    *imageURL;
@property (nonatomic, copy)   NSString *providerIdentifier;
@property (nonatomic, copy)   NSString *providerName;
@property (nonatomic, assign) BOOL      zeroWidth;
@end

@implementation TPKResolvedTwitchEmote
@end

@implementation TPKTwitchNativeEmoteFactory

+ (id<TPKResolvedEmote>)resolvedEmoteForTwitchEmoteID:(NSString *)emoteID {
    if (!emoteID.length) return nil;

    TPKResolvedTwitchEmote *resolved = [TPKResolvedTwitchEmote new];
    resolved.emoteID = emoteID;
    resolved.providerIdentifier = @"twitch";
    resolved.providerName = @"Twitch";
    resolved.zeroWidth = NO;

    // Twitch ne fournit pas les dimensions réelles dans le tag IRC (contrairement
    // à l'API 7TV) — quasi toutes les emotes Twitch (natives et sub) sont
    // carrées, même fallback 1:1 que pour le cas "dimensions 7TV inconnues"
    // ci-dessus (voir TPKTPKEmoteProvider). Cohérent avec le reste du fichier.
    resolved.nativeSize = CGSizeMake(1, 1);

    // Animées ou non : indétectable depuis le tag IRC seul (Twitch ne le
    // dit nulle part à l'avance). On met YES systématiquement plutôt que NO
    // — l'URL CDN ci-dessous utilise le format "default", qui sert déjà
    // automatiquement le GIF animé si l'emote en a un, un PNG statique
    // sinon (documenté côté Twitch). isAnimated ne fait ici que déterminer
    // si le pipeline PASSE par le décodage multi-frames
    // (TPKEmoteImageCache) plutôt que par le
    // décodage 1-frame classique — et ce pipeline gère déjà très bien le
    // cas "1 seule frame décodée" (voir tpk_decodeAnimatedWebPData:),
    // donc mettre YES pour une emote en réalité statique ne casse rien,
    // ça évite juste de fermer la porte à celles qui SONT animées.
    // (Avant : NO en dur, avec un commentaire "le pipeline n'existe pas
    // encore" qui datait d'avant son implémentation — jamais mis à jour,
    // c'était la cause du bug "emotes Twitch natives jamais animées".)
    resolved.isAnimated = YES;

    // URL CDN Twitch standard (format documenté, utilisé par tous les clients
    // tiers) — 2.0 = résolution ~56x56, cohérent avec le choix x2 par défaut
    // côté 7TV (TPKChatAppearanceConfig.emote7TVResolution).
    resolved.imageURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://static-cdn.jtvnw.net/emoticons/v2/%@/default/dark/2.0",
            emoteID]];

    return resolved;
}

@end
