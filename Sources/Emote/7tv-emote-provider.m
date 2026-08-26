/*
 * 7tv-emote-provider.m
 *
 * Voir 7tv-emote-provider.h pour le contexte (Phase 2).
 */

#import "Emote/7tv-emote-provider.h"
#import "Core/7tv-core-manager.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Chat/7tv-chat-message.h" // S7TVChatTokenTypeEmote7TV

NSArray<id<S7TVEmoteProvider>> *s7tv_chatEmoteProviders(void) {
    static NSArray<id<S7TVEmoteProvider>> *providers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        providers = @[[S7TVSevenTVEmoteProvider new]];
    });
    return providers;
}


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
    // dans 7tv-core-manager.h) → on ne connaît pas le vrai ratio, mais on ne
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


// ============================================================
// MARK: - S7TVResolvedTwitchEmote / S7TVTwitchNativeEmoteFactory
// ============================================================

@interface S7TVResolvedTwitchEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy)   NSString *emoteID;
@property (nonatomic, assign) CGSize    nativeSize;
@property (nonatomic, assign) BOOL      isAnimated;
@property (nonatomic, strong) NSURL    *imageURL;
@end

@implementation S7TVResolvedTwitchEmote
@end

@implementation S7TVTwitchNativeEmoteFactory

+ (id<S7TVResolvedEmote>)resolvedEmoteForTwitchEmoteID:(NSString *)emoteID {
    if (!emoteID.length) return nil;

    S7TVResolvedTwitchEmote *resolved = [S7TVResolvedTwitchEmote new];
    resolved.emoteID = emoteID;

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
