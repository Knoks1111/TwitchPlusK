/*
 * SevenTVChatMessage.h
 *
 * Modèle de données du chat custom (Phase 1a du plan chat-twitch-custom).
 * Indépendant du rendu (Phase 1c) et de la source (IRC live aujourd'hui,
 * VOD éventuellement plus tard — voir décision Phase 0 : live d'abord,
 * architecture VOD-ready).
 *
 * Toutes les classes de ce fichier sont pures données + stockage — aucune
 * dépendance UIKit au-delà de UIColor (couleur pseudo), aucun accès réseau.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration plutôt qu'un #import de SevenTVEmoteProvider.h : évite
// une dépendance circulaire (le fournisseur 7TV importe déjà ce fichier pour
// S7TVChatTokenType). Le modèle 1a n'a besoin de connaître que le nom du
// protocole, pas son contenu.
@protocol S7TVResolvedEmote;


// ============================================================
// MARK: - S7TVChatUserColorRegistry
// ============================================================
//
// Registre pseudo (insensible à la casse) -> couleur Twitch, alimenté au
// fil de l'eau par les messages qui arrivent (voir
// S7TVChatMessageStore addMessage: dans le .m). Sert à colorer les
// mentions "@pseudo" ET les pseudos cités sans @ dans le texte d'un
// message (comportement 7TV PC) — voir SevenTVChatTokenizer.m — en
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
// uniquement en lien avec S7TVChatMessage/S7TVChatToken (alimentation côté
// store, lecture côté tokenizer) — pas de raison de la disperser ailleurs.

@interface SevenTVChatUserColorRegistry : NSObject

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
// emote (7TV ou Twitch native), mention (@pseudo), URL. Le tokenizer réel
// arrive en Phase 2 (emotes) — ce fichier ne fait que définir la structure
// qu'il alimentera, pour que le modèle n'ait pas à changer de forme plus tard.

typedef NS_ENUM(NSInteger, S7TVChatTokenType) {
    S7TVChatTokenTypeText = 0,
    S7TVChatTokenTypeEmote7TV,
    S7TVChatTokenTypeEmoteTwitch,
    S7TVChatTokenTypeMention,
    S7TVChatTokenTypeURL,
};

@interface S7TVChatToken : NSObject

@property (nonatomic, assign) S7TVChatTokenType type;

// Texte affiché tel quel pour .text/.mention/.url ; nom de l'emote
// (fallback si l'image ne charge pas) pour .emote7TV/.emoteTwitch.
@property (nonatomic, copy) NSString *text;

// ID du provider (emoteID 7TV, ou ID emote Twitch) — nil si type == .text.
// Pensé "générique fournisseur" (voir Phase 2) : ce champ ne présuppose pas
// que c'est forcément du 7TV, juste "un identifiant que le provider du bon
// type saura résoudre en image".
@property (nonatomic, copy, nullable) NSString *providerEmoteID;

// Couleur du pseudo mentionné/cité, résolue via
// SevenTVChatUserColorRegistry au moment de la tokenisation (voir
// SevenTVChatTokenizer.m) — nil si ce pseudo n'a jamais été vu dans le
// chat (comportement 7TV PC : reste blanc dans ce cas, pas de couleur
// devinée). Utilisé uniquement pour .mention.
@property (nonatomic, strong, nullable) UIColor *mentionColor;

// Emote déjà résolue par le tokenizer (Phase 2) — dimensions/URL/animé,
// mis en cache ici pour que le renderer n'ait pas à re-interroger le
// fournisseur à chaque passage de cellule. nil pour les tokens non-emote.
@property (nonatomic, strong, nullable) id<S7TVResolvedEmote> resolvedEmote;

+ (instancetype)textToken:(NSString *)text;

// color : couleur connue du pseudo mentionné (via
// SevenTVChatUserColorRegistry), nil si inconnu — voir mentionColor
// ci-dessus.
+ (instancetype)mentionToken:(NSString *)text color:(nullable UIColor *)color;
+ (instancetype)urlToken:(NSString *)text;
+ (instancetype)emoteToken:(NSString *)name
                   provider:(S7TVChatTokenType)providerType   // .emote7TV ou .emoteTwitch
                   emoteID:(NSString *)emoteID;

@end


// ============================================================
// MARK: - Type et état d'un message
// ============================================================

typedef NS_ENUM(NSInteger, S7TVChatMessageType) {
    S7TVChatMessageTypeNormal = 0,
    S7TVChatMessageTypeSystem,          // sub / resub / gift sub / raid (détail Phase 3)
    S7TVChatMessageTypeAnnouncement,
    S7TVChatMessageTypePoll,
    S7TVChatMessageTypePrediction,
};

// Voir exigence transverse #2 du plan : la suppression ne vide JAMAIS
// rawText. Seul .state change le mode de rendu de la cellule (Phase 5).
typedef NS_ENUM(NSInteger, S7TVChatMessageState) {
    S7TVChatMessageStateNormal = 0,
    S7TVChatMessageStateDeletedCollapsed,   // placeholder "message supprimé", tappable
    S7TVChatMessageStateDeletedExpanded,    // contenu original ré-affiché, style atténué
};


// ============================================================
// MARK: - Messages système (Phase 3 — sub / resub / gift sub)
// ============================================================
//
// Kind distingue seulement le gift communautaire du reste : premier sub vs
// réabonnement se distingue via cumulativeMonths <= 1 (pas de tag IRC dédié
// pour "premier sub"). Périmètre actuel : sub/resub + gift communautaire
// (submysterygift) — voir s7tv_parseUSERNOTICE dans TweakSevenTV.m. Subgift
// ciblé (1 destinataire nommé) hors périmètre pour l'instant.
typedef NS_ENUM(NSInteger, S7TVSystemMessageKind) {
    S7TVSystemMessageKindSubOrResub = 0,
    S7TVSystemMessageKindCommunityGift,
};

@interface S7TVSystemMessageInfo : NSObject
@property (nonatomic, assign) S7TVSystemMessageKind kind;
@property (nonatomic, assign) NSInteger tier;                 // 1/2/3, ignoré si isPrime
@property (nonatomic, assign) BOOL      isPrime;
@property (nonatomic, assign) NSInteger cumulativeMonths;      // SubOrResub uniquement
@property (nonatomic, assign) NSInteger streakMonths;          // 0 si non partagé par l'utilisateur
@property (nonatomic, assign) NSInteger massGiftCount;         // CommunityGift uniquement
@property (nonatomic, assign) NSInteger senderTotalGiftCount;  // CommunityGift uniquement
@property (nonatomic, copy, nullable) NSString *channelDisplayName; // CommunityGift uniquement
@end


// ============================================================
// MARK: - S7TVChatMessage
// ============================================================

@interface S7TVChatMessage : NSObject

// Identifiant unique du message (tag IRC `id=`). Sert de clé dans le store
// pour les updates/suppressions rétroactives (Phase 5).
@property (nonatomic, copy) NSString *messageID;

@property (nonatomic, strong) NSDate *timestamp;

// Identifiant utilisateur stable (tag IRC `user-id=`) — PAS le pseudo
// affiché, qui peut changer. Sert à retrouver tous les messages d'un
// utilisateur lors d'un timeout/ban (Phase 5), indépendamment de son nom.
@property (nonatomic, copy) NSString *authorUserID;

@property (nonatomic, copy) NSString *authorDisplayName;
@property (nonatomic, strong, nullable) UIColor *authorColor;

// Tokens dans l'ordre d'affichage (texte + emotes + mentions mixés).
// Vide/nil tant que le tokenizer de Phase 2 n'existe pas — Phase 1c affiche
// alors directement rawText en fallback texte brut.
@property (nonatomic, copy, nullable) NSArray<S7TVChatToken *> *tokens;

// Tag IRC `emotes=` conservé pour pouvoir retokeniser le message lorsque le
// catalogue 7TV de la chaîne finit de charger, sans perdre les emotes Twitch.
@property (nonatomic, copy) NSString *twitchEmotesTag;

// Identifiants de badges (Phase 3), tels qu'extraits du tag IRC `badges=`
// (ex: @[@"subscriber/3", @"moderator/1"]), dans l'ordre d'affichage envoyé
// par Twitch. Volontairement PAS dans `tokens` — un badge est un attribut de
// l'auteur, pas un segment du texte du message (voir SevenTVBadgeProvider.h
// pour le raisonnement complet). Résolu en image par SevenTVBadgeProvider au
// moment du rendu, pas ici — ce modèle ne fait que porter la donnée brute.
@property (nonatomic, copy, nullable) NSArray<NSString *> *badgeIdentifiers;

// Phase 3 — nil pour un message normal. systemPhrase est pré-construit par
// le parser IRC (TweakSevenTV.m, s7tv_buildSystemMessagePhrase) — le
// renderer ne fait que de l'affichage, la logique de formulation reste
// côté parsing, pas dans SevenTVChatCustomView.
@property (nonatomic, strong, nullable) S7TVSystemMessageInfo *systemInfo;
@property (nonatomic, copy, nullable) NSString *systemPhrase;

@property (nonatomic, assign) S7TVChatMessageType type;
@property (nonatomic, assign) S7TVChatMessageState state;

// YES si le message vient d'un /me (CTCP ACTION en IRC, voir
// s7tv_parsePRIVMSG dans TweakSevenTV.m qui déballe déjà le wrapper
// \x01ACTION ... \x01 avant de remplir rawText/tokens). Comportement
// Twitch : le corps entier du message prend authorColor au lieu du blanc
// habituel (le pseudo est déjà coloré dans tous les cas) — voir
// SevenTVChatCustomView.m, s7tv_appendNormalBodyForMessage:into:...
@property (nonatomic, assign) BOOL isActionMessage;

// YES si CE message (écrit par quelqu'un d'autre) cite le pseudo du viewer
// connecté — @pseudo ou pseudo nu, même détection que les tokens .mention
// habituels (voir S7TVChatToken ci-dessus). Calculé une fois à la
// construction du message par s7tv_parsePRIVMSG (TweakSevenTV.m), comparé
// à SevenTVManager.currentViewerDisplayName — PAS recalculé au rendu, pour
// que le résultat reste stable même si le pseudo local change en cours de
// session (peu probable mais gratuit à garantir ici). Piloté par
// SevenTVChatAppearanceConfig.selfMentionHighlightEnabled/
// selfMentionHighlightColor côté rendu — voir SevenTVChatCustomView.m.
@property (nonatomic, assign) BOOL mentionsCurrentViewer;

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
// répondu). Mis à jour par S7TVChatMessageStore quand un reply arrive, pas
// par le parser — permet d'afficher "X réponses" sous un message racine
// sans scanner le fil à chaque rendu de cellule.
@property (nonatomic, assign) NSUInteger replyCount;

// Texte brut IRC original, JAMAIS purgé par un changement de state — voir
// exigence transverse #2. Seule la purge mémoire globale du store (limite
// de rétention, voir S7TVChatMessageStore) peut faire disparaître un
// message entièrement, tokens ET rawText ensemble.
@property (nonatomic, copy) NSString *rawText;

- (instancetype)initWithMessageID:(NSString *)messageID
                       timestamp:(NSDate *)timestamp
                    authorUserID:(NSString *)authorUserID
                 authorDisplayName:(NSString *)authorDisplayName
                         rawText:(NSString *)rawText;

@end


// ============================================================
// MARK: - S7TVChatMessageStore
// ============================================================
//
// Stockage ordonné + index par messageID et par authorUserID, pour permettre
// suppression/update rétroactifs en O(1) plutôt qu'un scan linéaire à chaque
// timeout (important sur une grosse chaîne — voir exigence transverse #3).
//
// Thread-safety : suit le pattern déjà en place dans SevenTVManager
// (emoteQueue) — queue concurrente dédiée, lectures en dispatch_sync,
// écritures en dispatch_barrier_async. Les messages arrivent depuis le hook
// WebSocket IRC (thread background) ; le rendu lit depuis le main thread.

@interface S7TVChatMessageStore : NSObject

// Nombre max de messages conservés (état + tokens + rawText). Au-delà, les
// plus anciens sont purgés, qu'ils soient supprimés ou non (voir Phase 1a :
// pas de stockage illimité de l'historique "supprimé"). Défaut : 300.
@property (nonatomic, assign) NSUInteger maxMessageCount;

- (instancetype)init; // maxMessageCount = 300 par défaut

// --- Écriture (thread-safe, appelable depuis le thread IRC) ---

// Ajoute en fin de liste. Purge automatiquement le plus ancien si
// maxMessageCount est dépassé après ajout.
- (void)addMessage:(S7TVChatMessage *)message;

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

// Bascule .deletedCollapsed <-> .deletedExpanded (tap-to-reveal, Phase 5).
// No-op si le message n'est pas dans un état "supprimé".
- (void)toggleExpandedForMessageID:(NSString *)messageID;

- (void)toggleExpandedForMessageID:(NSString *)messageID
                         completion:(void (^ _Nullable)(void))completion;

// CLEARCHAT global (Phase 5) : marque tous les messages actuellement en
// mémoire comme .deletedCollapsed d'un coup.
- (void)markAllMessagesDeleted;

- (void)markAllMessagesDeletedWithCompletion:(void (^ _Nullable)(void))completion;

// Vide entièrement le store (changement de channel — voir Phase 0,
// nettoyage à la fermeture/réouverture pour éviter les fuites entre chaînes).
- (void)removeAllMessages;

// Recalcule les tokens sous une barrière d'écriture, puis appelle completion
// sur le main thread. Le bloc est exécuté hors du thread UIKit.
- (void)retokenizeMessagesUsingBlock:(NSArray<S7TVChatToken *> * (^)(S7TVChatMessage *message))tokenizer
                          completion:(void (^ _Nullable)(void))completion;

// --- Lecture (thread-safe) ---

// Copie de tous les messages, dans l'ordre chronologique d'ajout.
- (NSArray<S7TVChatMessage *> *)allMessages;

- (nullable S7TVChatMessage *)messageWithID:(NSString *)messageID;

// Tous les messages d'un même fil (replyThreadRootID == threadRootID), dans
// l'ordre chronologique d'arrivée — alimente le panneau "Fil". Les messages
// du fil déjà purgés de la mémoire (limite maxMessageCount) sont absents du
// résultat plutôt que de planter ; le message racine lui-même peut être
// absent (voir replyParentUsername/replyParentBodyPreview sur chaque
// message pour ne pas dépendre de la présence du parent).
- (NSArray<S7TVChatMessage *> *)messagesForThreadRootID:(NSString *)threadRootID;

// Peuple ce store en lecture seule à partir d'une liste déjà connue (ex: un
// fil de discussion extrait du store principal via -messagesForThreadRootID:).
// Contrairement à -addMessage:, AUCUN effet de bord : pas de
// re-registration de couleur, pas de purge, pas d'incrément de replyCount —
// les messages passés sont des instances déjà comptabilisées ailleurs.
// Réservé aux stores "vue" temporaires (ex: panneau Fil) qui affichent un
// sous-ensemble d'un store principal ; jamais pour de l'ingestion IRC réelle.
- (void)seedReadOnlyWithMessages:(NSArray<S7TVChatMessage *> *)messages;

@property (nonatomic, strong, readonly) dispatch_queue_t storeQueue;

@end

NS_ASSUME_NONNULL_END
