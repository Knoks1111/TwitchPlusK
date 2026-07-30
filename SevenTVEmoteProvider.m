/*
 * SevenTVEmoteProvider.m
 *
 * Voir SevenTVEmoteProvider.h pour le contexte (Phase 2).
 */

#import "SevenTVEmoteProvider.h"
#import "SevenTVManager.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVChatMessage.h" // S7TVChatTokenTypeEmote7TV


// ============================================================
// MARK: - S7TVResolved7TVEmote
// ============================================================

@interface S7TVResolved7TVEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy)   NSString *emoteID;
@property (nonatomic, assign) CGSize    nativeSize;
@property (nonatomic, assign) BOOL      isAnimated;
@property (nonatomic, strong) NSURL    *imageURL;
@end

@implementation S7TVResolved7TVEmote
@end


// ============================================================
// MARK: - S7TVSevenTVEmoteProvider
// ============================================================

@implementation S7TVSevenTVEmoteProvider

- (nullable id<S7TVResolvedEmote>)resolveEmoteNamed:(NSString *)name {
    if (!name.length) return nil;

    SevenTVEmote *emote = [[SevenTVManager sharedManager] emoteForName:name];
    if (!emote) return nil;

    // Dimensions absentes (vieilles entrées de cache sans dimensions, voir
    // commentaire sur SevenTVEmote.width/height) → on ne peut pas réserver
    // un espace fiable, donc pas de token emote pour ce nom : le tokenizer
    // retombera sur un token texte brut (fallback nom d'emote, exigence
    // Phase 2 "échec réseau/dimensions inconnues").
    if (emote.width <= 0 || emote.height <= 0) return nil;

    S7TVResolved7TVEmote *resolved = [S7TVResolved7TVEmote new];
    resolved.emoteID    = emote.emoteID;
    resolved.nativeSize  = CGSizeMake(emote.width, emote.height);
    resolved.isAnimated  = emote.isAnimated;

    NSInteger res = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
    if (res < 1) res = 1;
    if (res > 4) res = 4;
    resolved.imageURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"%@/%@/%ldx.webp", S7TV_CDN_BASE, emote.emoteID, (long)res]];

    return resolved;
}

- (NSInteger)tokenType {
    return S7TVChatTokenTypeEmote7TV;
}

@end
