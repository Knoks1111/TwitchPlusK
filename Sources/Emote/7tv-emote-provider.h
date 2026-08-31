/*
 * 7tv-emote-provider.h
 *
 * Architecture "fournisseur d'emotes" générique : 7TV, BTTV et FFZ partagent
 * le même contrat afin que le tokenizer, le renderer et les previews restent
 * indépendants de l'API qui a fourni une emote.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Une emote résolue par un fournisseur : tout ce que le tokenizer et le
// renderer ont besoin de savoir, indépendamment de la source (7TV/BTTV/FFZ).
@protocol S7TVResolvedEmote <NSObject>

@property (nonatomic, copy, readonly) NSString *emoteID;

// Dimensions natives en points (1x), telles que fournies par l'API du
// fournisseur — permet de calculer le ratio largeur/hauteur exact avant même
// d'avoir téléchargé l'image (c'est ça qui règle le problème historique du
// projet : réserver l'espace dès la construction, pas après coup).
@property (nonatomic, readonly) CGSize nativeSize;

@property (nonatomic, readonly) BOOL isAnimated;

// URL CDN de l'image à télécharger, résolution déjà appliquée par le
// fournisseur (voir SevenTVChatAppearanceConfig.emoteImageResolution).
@property (nonatomic, readonly) NSURL *imageURL;

// Optional provider metadata.  They are optional deliberately: badges and
// legacy Twitch adapters also conform to this protocol and must not be
// forced to manufacture provider information.  Chat/picker code checks these
// selectors before reading them.
@optional
@property (nonatomic, copy, readonly) NSString *providerIdentifier;
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, readonly) BOOL zeroWidth;

@end


// Un fournisseur d'emotes : résout un nom tel qu'il apparaît dans le texte
// brut du message (ex: "KEKW") vers une emote exploitable, ou nil si ce
// fournisseur ne connaît pas ce nom (le tokenizer essaie le fournisseur
// suivant dans ce cas — voir SevenTVChatTokenizer).
@protocol S7TVEmoteProvider <NSObject>

- (nullable id<S7TVResolvedEmote>)resolveEmoteNamed:(NSString *)name;

// Type de token à utiliser pour les emotes de ce fournisseur (voir
// S7TVChatTokenType dans 7tv-chat-message.h) — permet au renderer
// d'appliquer la bonne taille de config (emote7TVSize vs emoteTwitchSize)
// sans que le tokenizer ait à connaître la distinction lui-même.
- (NSInteger)tokenType;

// Optional stable provider identifier used to order collision resolution.
// Existing third-party implementations that do not expose it remain valid
// and are kept after configured providers.
@optional
@property (nonatomic, readonly) NSInteger providerID;

@end


// Fournisseur concret 7TV — s'appuie sur SevenTVManager et le catalogue
// provider-aware sans dupliquer leur logique de cache/chargement.
@interface S7TVSevenTVEmoteProvider : NSObject <S7TVEmoteProvider>
@end

// Registre partagé des fournisseurs essayés par le tokenizer, dans l'ordre de
// priorité configuré par l'utilisateur.
// Centralisé ici pour que le live, l'historique et les Channel Points utilisent
// exactement les mêmes instances sans dépendre de 7tv-core-runtime-hooks.m.
FOUNDATION_EXPORT NSArray<id<S7TVEmoteProvider>> *s7tv_chatEmoteProviders(void);


// Emotes Twitch natives : contrairement à 7TV, on ne les résout PAS par nom
// — Twitch envoie déjà l'ID exact et la position dans le tag IRC `emotes=`
// de chaque PRIVMSG (voir s7tv_parsePRIVMSG dans 7tv-chat-message.m), donc pas
// besoin de dictionnaire nom→ID à maintenir. Construction directe depuis
// l'ID, pas de protocole S7TVEmoteProvider ici (qui suppose une résolution
// par nom, inadaptée à ce cas).
@interface S7TVTwitchNativeEmoteFactory : NSObject
+ (id<S7TVResolvedEmote>)resolvedEmoteForTwitchEmoteID:(NSString *)emoteID;
@end

NS_ASSUME_NONNULL_END
