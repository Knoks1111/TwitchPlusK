/*
 * SevenTVEmoteProvider.h
 *
 * Architecture "fournisseur d'emotes" générique (Phase 2 du plan
 * chat-twitch-custom) : une interface commune, implémentée aujourd'hui par
 * un fournisseur 7TV, pour ne pas fermer la porte à BTTV/FFZ plus tard sans
 * rouvrir le tokenizer. Aucun développement BTTV/FFZ prévu maintenant —
 * c'est uniquement un choix d'architecture.
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
// fournisseur (voir SevenTVChatAppearanceConfig.emote7TVResolution).
@property (nonatomic, readonly) NSURL *imageURL;

@end


// Un fournisseur d'emotes : résout un nom tel qu'il apparaît dans le texte
// brut du message (ex: "KEKW") vers une emote exploitable, ou nil si ce
// fournisseur ne connaît pas ce nom (le tokenizer essaie le fournisseur
// suivant dans ce cas — voir SevenTVChatTokenizer).
@protocol S7TVEmoteProvider <NSObject>

- (nullable id<S7TVResolvedEmote>)resolveEmoteNamed:(NSString *)name;

// Type de token à utiliser pour les emotes de ce fournisseur (voir
// S7TVChatTokenType dans SevenTVChatMessage.h) — permet au renderer
// d'appliquer la bonne taille de config (emote7TVSize vs emoteTwitchSize)
// sans que le tokenizer ait à connaître la distinction lui-même.
- (NSInteger)tokenType;

@end


// Fournisseur concret 7TV — s'appuie sur SevenTVManager (déjà source de
// vérité pour les emotes globales/channel) sans dupliquer sa logique de
// cache/chargement, juste un adaptateur vers l'interface générique ci-dessus.
@interface S7TVSevenTVEmoteProvider : NSObject <S7TVEmoteProvider>
@end

NS_ASSUME_NONNULL_END
