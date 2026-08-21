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

// Postée sur le main thread dès qu'un catalogue (global OU channel) vient de
// finir de charger avec succès. Corrige un bug de timing : un message rendu
// AVANT la fin du fetch voit resolvedBadgeForIdentifier: retourner nil (badge
// simplement sauté, PAS ajouté à outUncachedEmotes — contrairement à une
// image manquante, il n'y a alors aucun mécanisme de retry automatique). Sans
// cette notification, les messages affichés avant la fin du chargement du
// catalogue n'auraient jamais leurs badges, même une fois le catalogue prêt.
// TweakSevenTV.m écoute cette notification et déclenche un reload complet du
// chat custom (même mécanisme que pour un changement de chaîne).
extern NSString *const S7TVBadgesCatalogUpdatedNotification;

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

// Convertit directement le tag IRC `badges=` en identifiants ordonnés
// "setID/version" compris par resolvedBadgeForIdentifier:. Les entrées
// absentes ou malformées sont simplement ignorées.
+ (NSArray<NSString *> *)identifiersFromIRCTag:(nullable NSString *)tagValue;

// Résout un identifiant "setID/version" (tel qu'extrait du tag IRC badges=)
// vers un badge exploitable, ou nil si absent des deux catalogues (global +
// channel) — ex: fetch pas encore terminé, ou set/version inconnu (nouveau
// badge Twitch pas encore dans le catalogue mis en cache).
- (nullable id<S7TVResolvedEmote>)resolvedBadgeForIdentifier:(NSString *)identifier;

// Chargement explicite (aussi appelé automatiquement par +setup pour le
// global, et par la notification S7TVChannelJoined pour le channel).
- (void)loadGlobalBadges;
- (void)loadBadgesForChannelID:(NSString *)channelID;

// Vide immédiatement le catalogue channel (channelBadges = {}) — à appeler
// dès qu'un changement de chaîne est détecté, AVANT même que le nouveau
// fetch ne parte. Sans ça, entre le moment du switch et la fin du fetch
// pour la nouvelle chaîne, resolvedBadgeForIdentifier: pourrait encore
// retourner un badge custom de l'ANCIENNE chaîne si un setID/version
// coïncidait par hasard avec un identifiant envoyé par la nouvelle (cas
// rare mais possible, ex: deux chaînes avec un même nom de set custom).
// Même logique de reset immédiat que SevenTVManager.channelEmotes au
// changement de chaîne — voir loadEmotesForChannelName:.
// N'affecte PAS globalBadges (commun à toute la plateforme, jamais lié à
// une chaîne précise) ni lastLoadedChannelID (le prochain
// loadBadgesForChannelID: pour la nouvelle chaîne doit toujours pouvoir
// partir normalement).
- (void)resetChannelBadges;

@end

NS_ASSUME_NONNULL_END
