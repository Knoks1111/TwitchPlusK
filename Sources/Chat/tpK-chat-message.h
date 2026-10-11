/*
 * tpK-chat-message.h
 *
 * Modèle de données du chat custom (Phase 1a du plan chat-twitch-custom).
 * Indépendant du rendu (Phase 1c) et de la source (IRC live aujourd'hui,
 * VOD éventuellement plus tard — voir décision Phase 0 : live d'abord,
 * architecture VOD-ready).
 *
 * Le fichier regroupe les données, leur stockage et la conversion des lignes
 * IRC en messages. Il ne réalise lui-même aucun accès réseau.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Emote/tpK-emote-provider.h"

NS_ASSUME_NONNULL_BEGIN

@class TPKChannelPointRewardInfo;
@class TPKChatMessage;

typedef TPKChannelPointRewardInfo * _Nullable
    (^TPKAutomaticRewardResolver)(NSString *messageID);

// Utilitaires IRC partagés avec le gestionnaire de session chat. Le parsing
// et la construction des messages vivent avec le modèle plutôt que dans le
// point d'entrée du tweak.
FOUNDATION_EXPORT NSString *tpk_tagValue(NSDictionary<NSString *, NSString *> *tags,
                                           NSString *key, NSString *defaultValue);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *tpk_parseIRCTags(NSString *tagBlock);
FOUNDATION_EXPORT NSDate *tpk_messageTimestampFromTags(
    NSDictionary<NSString *, NSString *> *tags);
FOUNDATION_EXPORT UIColor * _Nullable tpk_colorFromHexString(NSString *hex);

FOUNDATION_EXPORT TPKChatMessage * _Nullable tpk_parsePRIVMSG(
    NSString *ircLine,
    NSArray<id<TPKEmoteProvider>> *providers,
    TPKAutomaticRewardResolver _Nullable automaticRewardResolver);
FOUNDATION_EXPORT TPKChatMessage * _Nullable tpk_parseUSERNOTICE(
    NSString *ircLine,
    NSArray<id<TPKEmoteProvider>> *providers);
FOUNDATION_EXPORT TPKChatMessage * _Nullable tpk_parseChatMessage(
    NSString *ircLine, NSArray<id<TPKEmoteProvider>> *providers);

// Primitives de conversion PubSub/IRC utilisées par le gestionnaire de
// session pour fusionner une récompense et son éventuel PRIVMSG compagnon.
FOUNDATION_EXPORT NSArray<TPKChatMessage *> *
    tpk_channelPointMessagesFromWebSocketText(
        NSString *text, NSArray<id<TPKEmoteProvider>> *providers);
FOUNDATION_EXPORT BOOL tpk_shouldSuppressChannelPointCompanion(
    TPKChatMessage *message);

// ============================================================
// MARK: - TPKChatUserColorRegistry
// ============================================================
//
// Registre pseudo (insensible à la casse) -> couleur Twitch, alimenté au
// fil de l'eau par les messages qui arrivent (voir
// TPKChatMessageStore addMessage: dans le .m). Sert à colorer les
// mentions "@pseudo" ET les pseudos cités sans @ dans le texte d'un
// message (comportement 7TV PC) — voir tpK-chat-tokenizer.m — en
// réutilisant la couleur déjà connue de cet utilisateur plutôt que d'en
// deviner une.
//
// Portée volontairement globale (singleton, pas liée à une chaîne) : la
// couleur d'un pseudo Twitch est la même partout, et ça évite de perdre
// l'info si quelqu'un est mentionné avant d'avoir lui-même parlé sur CETTE
// session de vue (mais a déjà parlé ailleurs pendant la session app).
//
// Limite connue : un pseudo mentionné qui n'a jamais encore posté dans le
// chat (sur cette session) n'a pas de couleur connue — comportement normal,
// Twitch IRC ne fournit la couleur d'un utilisateur que via SES propres
// messages, jamais à la demande pour un pseudo arbitraire.
//
// Pas de purge automatique : table légère (un UIColor par pseudo vu), coût
// mémoire négligeable même sur une session très longue.
//
// Regroupé ici plutôt que dans un fichier séparé : classe courte, utilisée
// uniquement en lien avec TPKChatMessage/TPKChatToken (alimentation côté
// store, lecture côté tokenizer) — pas de raison de la disperser ailleurs.

@interface TPKChatUserColorRegistry : NSObject

+ (instancetype)sharedRegistry;

// No-op si color est nil ou username vide — n'écrase jamais une couleur
// déjà connue par une valeur absente.
- (void)registerColor:(nullable UIColor *)color forUsername:(NSString *)username;

// Recherche insensible à la casse. nil si le pseudo n'a jamais été vu.
- (nullable UIColor *)colorForUsername:(NSString *)username;

@end


// ============================================================
// MARK: - Token (segment de message)
// ============================================================
//
// Un message est découpé en tokens dans l'ordre d'affichage : texte brut,
// emote (7TV ou Twitch native), GIF Twitch, mention (@pseudo), URL. Le
// tokenizer conserve toujours le texte original comme fallback si un média
// ne peut pas être chargé.

typedef NS_ENUM(NSInteger, TPKChatTokenType) {
    TPKChatTokenTypeText = 0,
    TPKChatTokenTypeEmote7TV,
    TPKChatTokenTypeEmoteTwitch,
    TPKChatTokenTypeMention,
    TPKChatTokenTypeURL,
    TPKChatTokenTypeGIF,
};

@interface TPKChatToken : NSObject

@property (nonatomic, assign) TPKChatTokenType type;

// Texte affiché tel quel pour .text/.mention/.url ; nom de l'emote ou texte
// original du GIF (fallback si l'image ne charge pas) pour les tokens média.
@property (nonatomic, copy) NSString *text;

// ID du provider (emoteID 7TV, ou ID emote Twitch) — nil si type == .text.
// Pensé "générique fournisseur" (voir Phase 2) : ce champ ne présuppose pas
// que c'est forcément du 7TV, juste "un identifiant que le provider du bon
// type saura résoudre en image".
@property (nonatomic, copy, nullable) NSString *providerEmoteID;

// Stable provider identity, kept separately from the emote ID so that two
// providers exposing the same ID/name never collide in previews or favorites.
// Legacy 7TV tokens may leave this nil; the renderer then treats them as 7TV.
@property (nonatomic, copy, nullable) NSString *providerIdentifier;
@property (nonatomic, copy, nullable) NSString *providerName;

// 7TV Zero-Width metadata.  A zero-width token grouped after a base emote is
// marked isOverlayLayer and rendered as part of that base attachment.  When
// no base exists, it remains a normal-width token (the provider flag is kept
// intact for metadata and a later token cannot use it as an anchor).
@property (nonatomic, assign) BOOL zeroWidth;
@property (nonatomic, assign) BOOL isOverlayLayer;
@property (nonatomic, assign) BOOL isSuppressedByOverlay;
@property (nonatomic, copy) NSArray<TPKChatToken *> *overlayTokens;

// Couleur du pseudo mentionné/cité, résolue via
// TPKChatUserColorRegistry au moment de la tokenisation (voir
// tpK-chat-tokenizer.m) — nil si ce pseudo n'a jamais été vu dans le
// chat (comportement 7TV PC : reste blanc dans ce cas, pas de couleur
// devinée). Utilisé uniquement pour .mention.
@property (nonatomic, strong, nullable) UIColor *mentionColor;

// Emote déjà résolue par le tokenizer (Phase 2) — dimensions/URL/animé,
// mis en cache ici pour que le renderer n'ait pas à re-interroger le
// fournisseur à chaque passage de cellule. nil pour les tokens non-emote.
@property (nonatomic, strong, nullable) id<TPKResolvedEmote> resolvedEmote;

+ (instancetype)textToken:(NSString *)text;

// color : couleur connue du pseudo mentionné (via
// TPKChatUserColorRegistry), nil si inconnu — voir mentionColor
// ci-dessus.
+ (instancetype)mentionToken:(NSString *)text color:(nullable UIColor *)color;
+ (instancetype)urlToken:(NSString *)text;
+ (instancetype)emoteToken:(NSString *)name
                   provider:(TPKChatTokenType)providerType   // .emote7TV ou .emoteTwitch
                   emoteID:(NSString *)emoteID;
+ (instancetype)gifToken:(NSString *)caption
                    gifID:(NSString *)gifID
                      url:(NSURL *)url;

@end


// ============================================================
// MARK: - Type et état d'un message
// ============================================================

typedef NS_ENUM(NSInteger, TPKChatMessageType) {
    TPKChatMessageTypeNormal = 0,
    TPKChatMessageTypeSystem,          // sub / resub / gift sub / raid (détail Phase 3)
    TPKChatMessageTypeAnnouncement,
    TPKChatMessageTypePoll,
    TPKChatMessageTypePrediction,
    // Utilisation d'une récompense personnalisée de points de chaîne.
    // Les données textuelles sont portées par channelPointRewardInfo et
    // viennent du payload PubSub `reward-redeemed` ou des tags IRC.
    TPKChatMessageTypeChannelPointRedemption,
    // Lignes locales sans équivalent IRC, insérées à la jonction entre
    // l'historique récent et les nouveaux messages reçus en direct.
    TPKChatMessageTypeHistoryWelcome,
    TPKChatMessageTypeHistoryDivider,
};

// Voir exigence transverse #2 du plan : la suppression ne vide JAMAIS
// rawText. Seul .state change le mode de rendu de la cellule (Phase 5).
typedef NS_ENUM(NSInteger, TPKChatMessageState) {
    TPKChatMessageStateNormal = 0,
    TPKChatMessageStateDeletedCollapsed,   // placeholder "message supprimé", tappable
    TPKChatMessageStateDeletedExpanded,    // contenu original ré-affiché, style atténué
};

// Cause de la suppression locale, conservée avec le message pour enrichir
// le placeholder sans dépendre du texte IRC après coup. `durationSeconds`
// n'est renseigné que pour un timeout ; un ban ciblé sans tag
// `ban-duration` est permanent selon le protocole IRC Twitch.
typedef NS_ENUM(NSInteger, TPKChatModerationKind) {
    TPKChatModerationKindNone = 0,
    TPKChatModerationKindMessageDeleted,
    TPKChatModerationKindTimeout,
    TPKChatModerationKindPermanentBan,
    TPKChatModerationKindChatCleared,
};


// ============================================================
// MARK: - Messages système (Phase 3 — sub / resub / gift sub)
// ============================================================
//
// Kind distingue seulement le gift communautaire du reste : premier sub vs
// réabonnement se distingue via cumulativeMonths <= 1 (pas de tag IRC dédié
// pour "premier sub"). Périmètre actuel : sub/resub + gift communautaire
// (submysterygift) — voir tpk_parseUSERNOTICE dans tpK-chat-message.m. Subgift
// ciblé (1 destinataire nommé) est rendu comme une variante du gift communautaire.
typedef NS_ENUM(NSInteger, TPKSystemMessageKind) {
    TPKSystemMessageKindSubOrResub = 0,
    TPKSystemMessageKindCommunityGift,
    TPKSystemMessageKindAnnouncement,
};

@interface TPKSystemMessageInfo : NSObject
@property (nonatomic, assign) TPKSystemMessageKind kind;
@property (nonatomic, assign) NSInteger tier;                 // 1/2/3, ignoré si isPrime
@property (nonatomic, assign) BOOL      isPrime;
@property (nonatomic, assign) NSInteger cumulativeMonths;      // SubOrResub uniquement
@property (nonatomic, assign) NSInteger streakMonths;          // 0 si non partagé par l'utilisateur
@property (nonatomic, assign) NSInteger massGiftCount;         // CommunityGift uniquement
@property (nonatomic, assign) NSInteger senderTotalGiftCount;  // CommunityGift uniquement
@property (nonatomic, copy, nullable) NSString *channelDisplayName; // CommunityGift uniquement
@property (nonatomic, copy, nullable) NSString *giftRecipientDisplayName; // Subgift ciblé uniquement
@property (nonatomic, copy, nullable) NSString *announcementColorName; // Announcement : PRIMARY/BLUE/GREEN/ORANGE/PURPLE
@end


// ============================================================
// MARK: - Récompense de points de chaîne
// ============================================================
//
// Modèle volontairement générique : une récompense personnalisée peut être
// renommée et reconfigurée librement par chaque streamer. Le chat conserve
// uniquement les informations textuelles nécessaires au bandeau de
// récompense. Le coût et les images ne sont volontairement pas gérés.

@interface TPKChannelPointRewardInfo : NSObject
@property (nonatomic, copy) NSString *rewardID;
@property (nonatomic, copy) NSString *title;
// Récompenses automatiques Twitch uniquement : leur catalogue ne renvoie
// aucun titre, seulement un type technique fixe. Le renderer résout alors
// ce libellé local à chaque affichage pour suivre le changement FR/EN live.
@property (nonatomic, copy, nullable) NSString *titleLocalizationKey;
@property (nonatomic, copy, nullable) NSString *prompt;
@property (nonatomic, assign) BOOL isUserInputRequired;
@property (nonatomic, copy, nullable) NSString *userInput;
@property (nonatomic, strong, nullable) UIColor *accentColor;
@end


// ============================================================
// MARK: - TPKChatMessage
// ============================================================

@interface TPKChatMessage : NSObject

// Identifiant unique du message (tag IRC `id=`). Sert de clé dans le store
// pour les updates/suppressions rétroactives (Phase 5).
@property (nonatomic, copy) NSString *messageID;

@property (nonatomic, strong) NSDate *timestamp;

// YES uniquement pour un message provenant du backfill Recent Messages au
// JOIN. Tous les messages, live compris, possèdent un timestamp : ce flag
// explicite permet au renderer de réserver l'affichage HH:mm à l'historique.
@property (nonatomic, assign) BOOL isHistorical;

// Identifiant utilisateur stable (tag IRC `user-id=`) — PAS le pseudo
// affiché, qui peut changer. Sert à retrouver tous les messages d'un
// utilisateur lors d'un timeout/ban (Phase 5), indépendamment de son nom.
@property (nonatomic, copy) NSString *authorUserID;

@property (nonatomic, copy) NSString *authorDisplayName;
@property (nonatomic, strong, nullable) UIColor *authorColor;

// Tokens dans l'ordre d'affichage (texte + emotes + mentions mixés).
// Vide/nil tant que le tokenizer de Phase 2 n'existe pas — Phase 1c affiche
// alors directement rawText en fallback texte brut.
@property (nonatomic, copy, nullable) NSArray<TPKChatToken *> *tokens;

// Tag IRC `emotes=` conservé pour pouvoir retokeniser le message lorsque le
// catalogue 7TV de la chaîne finit de charger, sans perdre les emotes Twitch.
@property (nonatomic, copy) NSString *twitchEmotesTag;

// Tag IRC `gifs=` conservé avec le message pour que les changements de
// provider, de résolution ou d'apparence puissent retokeniser sans perdre
// les GIFs déjà reçus. Twitch fournit directement l'ID et l'URL de chaque GIF.
@property (nonatomic, copy) NSString *twitchGIFsTag;

// Identifiants de badges (Phase 3), tels qu'extraits du tag IRC `badges=`
// (ex: @[@"subscriber/3", @"moderator/1"]), dans l'ordre d'affichage envoyé
// par Twitch. Volontairement PAS dans `tokens` — un badge est un attribut de
// l'auteur, pas un segment du texte du message (voir tpK-badge-provider.h
// pour le raisonnement complet). Résolu en image par TPKBadgeProvider au
// moment du rendu, pas ici — ce modèle ne fait que porter la donnée brute.
@property (nonatomic, copy, nullable) NSArray<NSString *> *badgeIdentifiers;

// Chaîne de la rediffusion ayant fourni ces badges. Nil pour le chat live.
// `source-room-id` des PRIVMSG/USERNOTICE du Shared Chat. Il est présent
// également sur la chaîne d'origine (où il est égal à `room-id`) et absent
// du chat normal. Le renderer l'utilise pour placer l'avatar de la chaîne
// source avant tous les badges uniquement lorsque Twitch signale ce mode.
@property (nonatomic, copy, nullable) NSString *sharedChatSourceChannelID;

// Phase 3 — nil pour un message normal. systemPhrase est pré-construit par
// le parser IRC (tpK-chat-message.m, tpk_buildSystemMessagePhrase) — le
// renderer ne fait que de l'affichage, la logique de formulation reste
// côté parsing, pas dans TPKChatCustomView.
@property (nonatomic, strong, nullable) TPKSystemMessageInfo *systemInfo;
@property (nonatomic, copy, nullable) NSString *systemPhrase;

// Présent uniquement sur la ligne synthétique créée depuis
// `reward-redeemed`. Le titre et la saisie éventuelle viennent de Twitch.
@property (nonatomic, strong, nullable) TPKChannelPointRewardInfo *channelPointRewardInfo;

// Tag IRC `custom-reward-id`. Il sert à associer/supprimer le PRIVMSG
// compagnon d'une récompense avec saisie, afin que le texte ne soit jamais
// affiché deux fois quand PubSub et IRC livrent le même événement.
@property (nonatomic, copy, nullable) NSString *channelPointRewardID;

@property (nonatomic, assign) TPKChatMessageType type;
@property (nonatomic, assign) TPKChatMessageState state;
@property (nonatomic, assign) TPKChatModerationKind moderationKind;
@property (nonatomic, assign) NSInteger moderationDurationSeconds;

// Source de vérité unique pour synchroniser l'état d'une même ligne lorsque
// le FIFO principal et un transcript figé en retiennent deux instances.
- (void)applyModerationState:(TPKChatMessageState)state
              moderationKind:(TPKChatModerationKind)moderationKind
             durationSeconds:(NSInteger)durationSeconds;

// YES si le message vient d'un /me (CTCP ACTION en IRC, voir
// tpk_parsePRIVMSG dans tpK-chat-message.m qui déballe déjà le wrapper
// \x01ACTION ... \x01 avant de remplir rawText/tokens). Comportement
// Twitch : le corps entier du message prend authorColor au lieu du blanc
// habituel (le pseudo est déjà coloré dans tous les cas) — voir
// tpK-chat-custom-view.m, tpk_appendNormalBodyForMessage:into:...
@property (nonatomic, assign) BOOL isActionMessage;

// YES si CE message (écrit par quelqu'un d'autre) cite le pseudo du viewer
// connecté — @pseudo ou pseudo nu, même détection que les tokens .mention
// habituels (voir TPKChatToken ci-dessus). Calculé une fois à la
// construction du message par tpk_parsePRIVMSG (tpK-chat-message.m), comparé
// à TPKManager.currentViewerDisplayName — PAS recalculé au rendu, pour
// que le résultat reste stable même si le pseudo local change en cours de
// session (peu probable mais gratuit à garantir ici). Piloté par
// TPKChatAppearanceConfig.selfMentionHighlightEnabled/
// selfMentionHighlightColor côté rendu — voir tpK-chat-custom-view.m.
@property (nonatomic, assign) BOOL mentionsCurrentViewer;

// Tag IRC Twitch `first-msg=1`. Indique le premier message de cet
// utilisateur dans ce chat et pilote le bandeau FIRST MESSAGE du renderer.
// Le flag reste dans le modèle même si l'affichage est désactivé afin que le
// toggle puisse s'appliquer immédiatement sans reparsing ni reconnexion.
@property (nonatomic, assign) BOOL isFirstMessage;

// ── Réponses / fils de discussion ───────────────────────────────────────
// Tags IRC reply-parent-* : Twitch les duplique sur CHAQUE message qui
// répond, donc dispo directement ici même si le message parent n'est plus
// en mémoire (purgé) — pas besoin de le retrouver dans le store pour
// afficher le bandeau "Répond à @X : ...".
@property (nonatomic, copy, nullable) NSString *replyParentMessageID;   // tag reply-parent-msg-id
@property (nonatomic, copy, nullable) NSString *replyParentUsername;    // tag reply-parent-user-login (ou display-name)
@property (nonatomic, copy, nullable) NSString *replyParentBodyPreview; // tag reply-parent-msg-body (texte brut, tronqué au rendu, pas ici)

// Racine du fil — À REMPLIR PAR LE PARSER avec le tag reply-thread-parent-msg-id
// s'il existe, SINON replyParentMessageID lui-même (1er niveau de réponse =
// racine). nil si ce message n'est pas une réponse.
// C'est ce champ qui sert à regrouper les messages d'un même fil, JAMAIS
// replyParentMessageID (qui ne pointe que sur le message immédiatement
// au-dessus et fragmenterait un fil de 3+ messages en plusieurs sous-fils
// déconnectés dès qu'quelqu'un répond à une réponse plutôt qu'au premier
// message). Tous les messages d'un même fil partagent la même valeur ici.
@property (nonatomic, copy, nullable) NSString *replyThreadRootID;

// YES si CE message est la racine d'au moins un fil (quelqu'un lui a
// répondu). Mis à jour par TPKChatMessageStore quand un reply arrive, pas
// par le parser — permet d'afficher "X réponses" sous un message racine
// sans scanner le fil à chaque rendu de cellule.
@property (nonatomic, assign) NSUInteger replyCount;

// Texte brut IRC original, JAMAIS purgé par un changement de state — voir
// exigence transverse #2. Seule la purge mémoire globale du store (limite
// de rétention, voir TPKChatMessageStore) peut faire disparaître un
// message entièrement, tokens ET rawText ensemble.
@property (nonatomic, copy) NSString *rawText;

- (instancetype)initWithMessageID:(NSString *)messageID
                       timestamp:(NSDate *)timestamp
                    authorUserID:(NSString *)authorUserID
                 authorDisplayName:(NSString *)authorDisplayName
                         rawText:(NSString *)rawText;

@end


// ============================================================
// MARK: - TPKChatMessageStore
// ============================================================
//
// Stockage ordonné + index par messageID et par authorUserID, pour permettre
// suppression/update rétroactifs en O(1) plutôt qu'un scan linéaire à chaque
// timeout (important sur une grosse chaîne — voir exigence transverse #3).
//
// Thread-safety : suit le pattern déjà en place dans TPKManager
// (emoteQueue) — queue concurrente dédiée, lectures en dispatch_sync,
// écritures en dispatch_barrier_async. Les messages arrivent depuis le hook
// WebSocket IRC (thread background) ; le rendu lit depuis le main thread.

@interface TPKChatMessageStore : NSObject

// Nombre max de messages conservés (état + tokens + rawText). Au-delà, les
// plus anciens sont purgés, qu'ils soient supprimés ou non (voir Phase 1a :
// pas de stockage illimité de l'historique "supprimé"). Défaut : 300.
@property (nonatomic, assign) NSUInteger maxMessageCount;

- (instancetype)init; // maxMessageCount = 300 par défaut

// --- Écriture (thread-safe, appelable depuis le thread IRC) ---

// Ajoute en fin de liste. Purge automatiquement le plus ancien si
// maxMessageCount est dépassé après ajout.
- (void)addMessage:(TPKChatMessage *)message;

// Passe le message en .deletedCollapsed (ne touche pas rawText/tokens).
// No-op silencieux si l'id est introuvable (déjà purgé, ou jamais reçu).
- (void)markMessageDeletedByID:(NSString *)messageID;

// Variante avec completion appelée sur le main thread APRÈS que la barrière
// d'écriture a terminé. Utilisée par la Phase 5 pour ne jamais rafraîchir la
// cellule avant que son nouvel état soit réellement visible par le renderer.
- (void)markMessageDeletedByID:(NSString *)messageID
                    completion:(void (^ _Nullable)(void))completion;

// Passe TOUS les messages actuellement en mémoire d'un utilisateur en
// .deletedCollapsed — utilisé pour timeout/ban (Phase 5). Retrouve les
// messages via l'index authorUserID, pas un scan.
- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID;

- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID
                              completion:(void (^ _Nullable)(void))completion;

// Variante enrichie utilisée par CLEARCHAT : propage la nature de la
// sanction et sa durée à tous les messages concernés.
- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID
                         moderationKind:(TPKChatModerationKind)moderationKind
                        durationSeconds:(NSInteger)durationSeconds
                              completion:(void (^ _Nullable)(void))completion;

// Bascule .deletedCollapsed <-> .deletedExpanded (tap-to-reveal, Phase 5).
// No-op si le message n'est pas dans un état "supprimé".
- (void)toggleExpandedForMessageID:(NSString *)messageID;

- (void)toggleExpandedForMessageID:(NSString *)messageID
                         completion:(void (^ _Nullable)(void))completion;

// Variante robuste pour une cellule dont le modèle est encore affiché mais
// a déjà quitté le FIFO du store (transcript principal figé à 300 messages).
// La mutation reste sérialisée sur storeQueue et renvoie le modèle réellement
// basculé sur le main thread.
- (void)toggleExpandedForMessage:(TPKChatMessage *)message
                      completion:(void (^ _Nullable)(TPKChatMessage *updatedMessage))completion;

// CLEARCHAT global (Phase 5) : marque tous les messages actuellement en
// mémoire comme .deletedCollapsed d'un coup.
- (void)markAllMessagesDeleted;

- (void)markAllMessagesDeletedWithCompletion:(void (^ _Nullable)(void))completion;

// Vide entièrement le store (changement de channel — voir Phase 0,
// nettoyage à la fermeture/réouverture pour éviter les fuites entre chaînes).
- (void)removeAllMessages;

// Remplace atomiquement le contenu du store. Utilisé au JOIN pour poser les
// marqueurs Bienvenue/Nouveautés avant que les premiers PRIVMSG live soient
// ajoutés ; completion est appelée sur le main thread après la barrière.
- (void)replaceAllMessages:(NSArray<TPKChatMessage *> *)messages
                completion:(void (^ _Nullable)(void))completion;

// Insère un lot historique AVANT le contenu déjà présent (marqueurs + live),
// sans remplacer les doublons déjà reçus en direct. Tous les index du store
// et les compteurs de réponses sont reconstruits dans la même barrière.
- (void)prependHistoricalMessages:(NSArray<TPKChatMessage *> *)messages
                        completion:(void (^ _Nullable)(void))completion;

// Variante conditionnelle : isCurrent est évalué dans la barrière juste
// avant la fusion, afin d'abandonner un historique devenu périmé.
- (void)prependHistoricalMessages:(NSArray<TPKChatMessage *> *)messages
                         ifCurrent:(BOOL (^ _Nullable)(void))isCurrent
                         completion:(void (^ _Nullable)(void))completion;

// Recalcule les tokens sous une barrière d'écriture, puis appelle completion
// sur le main thread. Le bloc est exécuté hors du thread UIKit.
- (void)retokenizeMessagesUsingBlock:(NSArray<TPKChatToken *> * (^)(TPKChatMessage *message))tokenizer
                          completion:(void (^ _Nullable)(void))completion;

// Enrichit la ligne reward-redeemed correspondante avec les données de son
// PRIVMSG custom-reward-id (badges, couleur et offsets d'emotes Twitch),
// sans ajouter une seconde ligne. Rare et borné à 300 messages, un scan
// inverse est préférable à un index permanent supplémentaire.
- (void)mergeChannelPointCompanionMessage:(TPKChatMessage *)companion
                                completion:(void (^ _Nullable)(NSString * _Nullable mergedMessageID))completion;

// --- Lecture (thread-safe) ---

// Copie de tous les messages, dans l'ordre chronologique d'ajout.
- (NSArray<TPKChatMessage *> *)allMessages;

// Change à chaque reconstruction/vidage complet du store. Permet au renderer
// de distinguer une simple purge FIFO d'un changement de chaîne ou d'un
// remplacement global, même lorsqu'il a temporairement figé son transcript.
- (NSUInteger)generation;

- (nullable TPKChatMessage *)messageWithID:(NSString *)messageID;

// Tous les messages d'un même fil (replyThreadRootID == threadRootID), dans
// l'ordre chronologique d'arrivée — alimente le panneau "Fil". Les messages
// du fil déjà purgés de la mémoire (limite maxMessageCount) sont absents du
// résultat plutôt que de planter ; le message racine lui-même peut être
// absent (voir replyParentUsername/replyParentBodyPreview sur chaque
// message pour ne pas dépendre de la présence du parent).
- (NSArray<TPKChatMessage *> *)messagesForThreadRootID:(NSString *)threadRootID;

// Peuple ce store en lecture seule à partir d'une liste déjà connue (ex: un
// fil de discussion extrait du store principal via -messagesForThreadRootID:).
// Contrairement à -addMessage:, AUCUN effet de bord : pas de
// re-registration de couleur, pas de purge, pas d'incrément de replyCount —
// les messages passés sont des instances déjà comptabilisées ailleurs.
// Réservé aux stores "vue" temporaires (ex: panneau Fil) qui affichent un
// sous-ensemble d'un store principal ; jamais pour de l'ingestion IRC réelle.
- (void)seedReadOnlyWithMessages:(NSArray<TPKChatMessage *> *)messages;

@property (nonatomic, strong, readonly) dispatch_queue_t storeQueue;

@end

NS_ASSUME_NONNULL_END
