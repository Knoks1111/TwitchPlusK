/*
 * SevenTVBadgeProvider.h
 *
 * Badges Twitch (sub, mod, VIP, custom channel) — Phase 3 du plan
 * chat-twitch-custom. Volontairement HORS du tokenizer/pipeline emote de
 * message (voir SevenTVChatTokenizer/SevenTVEmoteProvider) : un badge est un
 * attribut de l'AUTEUR, pas un token du texte du message — un mod peut avoir
 * 3 badges sans une seule emote dans son message. Les coupler aurait fermé la
 * porte à réutiliser l'affichage des badges ailleurs (message système,
 * bannière "returning chatter" Phase 3, reply threading Phase 6) sans
 * dépendre de la logique de découpage de texte.
 *
 * Catalogue source : endpoint public badges.twitch.tv (JSON, sans auth) —
 * pas besoin de passer par Helix (token d'app) pour un simple mapping
 * set-id/version → URL image, cohérent avec le choix déjà fait pour 7TV
 * (API publique, pas d'auth).
 *
 * Le tag IRC `badges=` (ex: "subscriber/3,moderator/1") donne directement
 * la liste ordonnée des identifiants "setID/version" à résoudre — pas de
 * lookup par nom nécessaire, contrairement aux emotes 7TV.
 *
 * Simplification assumée pour cette phase : catalogue tenu UNIQUEMENT en
 * mémoire (pas de cache disque comme SevenTVManager pour les emotes) — les
 * badges changent rarement en cours de session et le fetch est un aller-
 * retour JSON léger, pas justifié de dupliquer toute l'infra de cache
 * fichier pour ça. Le fetch global se fait une fois au démarrage, le fetch
 * channel une fois par join (voir notification S7TVChannelJoined, déjà
 * postée par TweakSevenTV.m mais jamais consommée jusqu'ici).
 */

#import <Foundation/Foundation.h>
#import "SevenTVEmoteProvider.h" // protocole S7TVResolvedEmote

NS_ASSUME_NONNULL_BEGIN

// Badge résolu — conforme à S7TVResolvedEmote pour réutiliser tel quel
// SevenTVEmoteImageCache (fetch/décodage/cache image) et le mécanisme de
// reload-on-load déjà en place dans SevenTVChatCustomView
// (s7tv_cellForMessageID: ne fait aucune distinction entre une emote et un
// badge, les deux sont juste des id<S7TVResolvedEmote>).
@interface S7TVResolvedBadge : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy)   NSString *emoteID;     // identifiant "setID/version"
@property (nonatomic, assign) CGSize    nativeSize;  // toujours carré (1,1) — voir .m
@property (nonatomic, assign) BOOL      isAnimated;  // toujours NO, badges PNG statiques
@property (nonatomic, strong) NSURL    *imageURL;
@end


@interface SevenTVBadgeProvider : NSObject

+ (instancetype)sharedProvider;

// À appeler une fois au démarrage du tweak (voir TweakSevenTV.m, à côté de
// [SevenTVManager setup]) : charge le catalogue global et s'abonne à
// S7TVChannelJoined pour charger automatiquement le catalogue channel à
// chaque changement de chaîne. Idempotent (dispatch_once interne via
// sharedProvider) — sûr à appeler plusieurs fois.
+ (void)setup;

// Résout un identifiant "setID/version" (tel qu'extrait du tag IRC badges=)
// vers un badge exploitable, ou nil si absent des deux catalogues (global +
// channel) — ex: fetch pas encore terminé, ou set/version inconnu (nouveau
// badge Twitch pas encore dans le catalogue mis en cache).
- (nullable id<S7TVResolvedEmote>)resolvedBadgeForIdentifier:(NSString *)identifier;

// Chargement explicite (aussi appelé automatiquement par +setup pour le
// global, et par la notification S7TVChannelJoined pour le channel).
- (void)loadGlobalBadges;
- (void)loadBadgesForChannelID:(NSString *)channelID;

@end

NS_ASSUME_NONNULL_END
