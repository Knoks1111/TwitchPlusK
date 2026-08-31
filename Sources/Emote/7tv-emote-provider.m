/*
 * 7tv-emote-provider.m
 *
 * Voir 7tv-emote-provider.h pour le contexte (Phase 2).
 */

#import "Emote/7tv-emote-provider.h"
#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Chat/7tv-chat-message.h" // S7TVChatTokenTypeEmote7TV

// Adapter around the provider-agnostic catalogue.  Keeping the descriptor
// behind the existing resolved-emote protocol means the image cache and the
// TextKit renderer work unchanged for BTTV/FFZ.
@interface S7TVResolvedCatalogEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy) NSString *emoteID;
@property (nonatomic, assign) CGSize nativeSize;
@property (nonatomic, assign) BOOL isAnimated;
@property (nonatomic, strong) NSURL *imageURL;
@property (nonatomic, copy) NSString *providerIdentifier;
@property (nonatomic, copy) NSString *providerName;
@property (nonatomic, assign) BOOL zeroWidth;
@end

@implementation S7TVResolvedCatalogEmote
@end

static NSInteger s7tv_emoteResolution(void) {
    SevenTVChatAppearanceConfig *config = [SevenTVChatAppearanceConfig sharedConfig];
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

static id<S7TVResolvedEmote> s7tv_resolvedCatalogEmote(S7TVEmoteDescriptor *descriptor) {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    S7TVResolvedCatalogEmote *resolved = [S7TVResolvedCatalogEmote new];
    resolved.emoteID = descriptor.emoteID;
    resolved.nativeSize = descriptor.nativeSize;
    resolved.isAnimated = descriptor.animated;
    resolved.providerIdentifier = descriptor.providerIdentifier;
    resolved.providerName = S7TVEmoteProviderName(descriptor.provider);
    resolved.zeroWidth = descriptor.zeroWidth;
    resolved.imageURL = [descriptor imageURLForResolution:s7tv_emoteResolution()];
    return resolved.imageURL ? resolved : nil;
}

@interface S7TVProviderEmoteAdapter : NSObject <S7TVEmoteProvider>
@property (nonatomic, assign) S7TVEmoteProviderID providerID;
@end

@implementation S7TVProviderEmoteAdapter
- (nullable id<S7TVResolvedEmote>)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    if (![S7TVEmoteProviderSettings isProviderEnabled:
            (S7TVExternalEmoteProvider)self.providerID]) return nil;
    S7TVEmoteDescriptor *descriptor = [catalog resolveEmoteNamed:name
                                                            provider:self.providerID];
    if (descriptor) return s7tv_resolvedCatalogEmote(descriptor);
    return nil;
}
- (NSInteger)tokenType { return S7TVChatTokenTypeEmote7TV; }
@end

@interface S7TVBTTVEmoteProvider : S7TVProviderEmoteAdapter @end
@interface S7TVFFZEmoteProvider : S7TVProviderEmoteAdapter @end
@implementation S7TVBTTVEmoteProvider
- (instancetype)init { self = [super init]; if (self) self.providerID = S7TVEmoteProviderIDBTTV; return self; }
@end
@implementation S7TVFFZEmoteProvider
- (instancetype)init { self = [super init]; if (self) self.providerID = S7TVEmoteProviderIDFFZ; return self; }
@end

NSArray<id<S7TVEmoteProvider>> *s7tv_chatEmoteProviders(void) {
    static NSArray<id<S7TVEmoteProvider>> *allProviders = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allProviders = @[[S7TVSevenTVEmoteProvider new],
                         [S7TVBTTVEmoteProvider new],
                         [S7TVFFZEmoteProvider new]];
    });

    // The tokenizer receives providers in the configured collision-priority
    // order.  Keep the instances stable (important for in-flight UI work)
    // while deriving the order on every call so a settings change applies to
    // the next message without restarting chat.
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:allProviders.count];
    for (NSString *identifier in [S7TVEmoteProviderSettings providerPriority]) {
        S7TVEmoteProviderID provider =
            (S7TVEmoteProviderID)S7TVEmoteProviderFromIdentifier(identifier);
        for (id<S7TVEmoteProvider> candidate in allProviders) {
            if ([candidate respondsToSelector:@selector(providerID)] &&
                [candidate providerID] == provider) {
                [ordered addObject:candidate];
                break;
            }
        }
    }
    for (id<S7TVEmoteProvider> candidate in allProviders) {
        if (![ordered containsObject:candidate]) [ordered addObject:candidate];
    }
    return ordered.copy;
}

// ============================================================
// MARK: - S7TVSevenTVEmoteProvider
// ============================================================

@implementation S7TVSevenTVEmoteProvider

- (NSInteger)providerID { return S7TVEmoteProviderIDSevenTV; }

- (nullable id<S7TVResolvedEmote>)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;

    if (![S7TVEmoteProviderSettings isProviderEnabled:S7TVExternalEmoteProvider7TV])
        return nil;

    // The shared catalogue is the single source of truth for aliases,
    // Zero-Width flags, provider identity and cache-backed availability.
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    if ([catalog.providerEnabled[@(S7TVEmoteProviderIDSevenTV)] boolValue]) {
        S7TVEmoteDescriptor *descriptor =
            [catalog resolveEmoteNamed:name provider:S7TVEmoteProviderIDSevenTV];
        if (descriptor) return s7tv_resolvedCatalogEmote(descriptor);
    }
    return nil;
}

- (NSInteger)tokenType {
    return S7TVChatTokenTypeEmote7TV;
}

@end


// ============================================================
// MARK: - S7TVResolvedTwitchEmote / S7TVTwitchNativeEmoteFactory
// ============================================================

@interface S7TVResolvedTwitchEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy)   NSString *emoteID;
@property (nonatomic, assign) CGSize    nativeSize;
@property (nonatomic, assign) BOOL      isAnimated;
@property (nonatomic, strong) NSURL    *imageURL;
@property (nonatomic, copy)   NSString *providerIdentifier;
@property (nonatomic, copy)   NSString *providerName;
@property (nonatomic, assign) BOOL      zeroWidth;
@end

@implementation S7TVResolvedTwitchEmote
@end

@implementation S7TVTwitchNativeEmoteFactory

+ (id<S7TVResolvedEmote>)resolvedEmoteForTwitchEmoteID:(NSString *)emoteID {
    if (!emoteID.length) return nil;

    S7TVResolvedTwitchEmote *resolved = [S7TVResolvedTwitchEmote new];
    resolved.emoteID = emoteID;
    resolved.providerIdentifier = @"twitch";
    resolved.providerName = @"Twitch";
    resolved.zeroWidth = NO;

    // Twitch ne fournit pas les dimensions réelles dans le tag IRC (contrairement
    // à l'API 7TV) — quasi toutes les emotes Twitch (natives et sub) sont
    // carrées, même fallback 1:1 que pour le cas "dimensions 7TV inconnues"
    // ci-dessus (voir S7TVSevenTVEmoteProvider). Cohérent avec le reste du fichier.
    resolved.nativeSize = CGSizeMake(1, 1);

    // Animées ou non : indétectable depuis le tag IRC seul (Twitch ne le
    // dit nulle part à l'avance). On met YES systématiquement plutôt que NO
    // — l'URL CDN ci-dessous utilise le format "default", qui sert déjà
    // automatiquement le GIF animé si l'emote en a un, un PNG statique
    // sinon (documenté côté Twitch). isAnimated ne fait ici que déterminer
    // si le pipeline PASSE par le décodage multi-frames
    // (SevenTVEmoteImageCache) plutôt que par le
    // décodage 1-frame classique — et ce pipeline gère déjà très bien le
    // cas "1 seule frame décodée" (voir s7tv_decodeAnimatedWebPData:),
    // donc mettre YES pour une emote en réalité statique ne casse rien,
    // ça évite juste de fermer la porte à celles qui SONT animées.
    // (Avant : NO en dur, avec un commentaire "le pipeline n'existe pas
    // encore" qui datait d'avant son implémentation — jamais mis à jour,
    // c'était la cause du bug "emotes Twitch natives jamais animées".)
    resolved.isAnimated = YES;

    // URL CDN Twitch standard (format documenté, utilisé par tous les clients
    // tiers) — 2.0 = résolution ~56x56, cohérent avec le choix x2 par défaut
    // côté 7TV (SevenTVChatAppearanceConfig.emote7TVResolution).
    resolved.imageURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://static-cdn.jtvnw.net/emoticons/v2/%@/default/dark/2.0",
            emoteID]];

    return resolved;
}

@end
