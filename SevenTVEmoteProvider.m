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

    // Dimensions absentes (vieilles entrées de cache disque écrites avant
    // que ce champ n'existe, voir commentaire sur SevenTVEmote.width/height
    // dans SevenTVManager.h) → on ne connaît pas le vrai ratio, mais on ne
    // renonce PAS pour autant à afficher l'image : la quasi-totalité des
    // emotes 7TV sont carrées, donc un fallback 1:1 est une bien meilleure
    // approximation que de retomber sur du texte brut pour une emote pourtant
    // bien identifiée. Le cache disque se réécrit avec les vraies dimensions
    // dès le prochain fetch API frais (loadGlobalEmotes/loadEmotesForChannel...),
    // donc ce fallback ne dure qu'un temps, pas indéfiniment.
    CGSize nativeSize = (emote.width > 0 && emote.height > 0)
        ? CGSizeMake(emote.width, emote.height)
        : CGSizeMake(1, 1);

    S7TVResolved7TVEmote *resolved = [S7TVResolved7TVEmote new];
    resolved.emoteID    = emote.emoteID;
    resolved.nativeSize  = nativeSize;
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
