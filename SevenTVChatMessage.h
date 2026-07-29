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

+ (instancetype)textToken:(NSString *)text;
+ (instancetype)mentionToken:(NSString *)text;
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

@property (nonatomic, assign) S7TVChatMessageType type;
@property (nonatomic, assign) S7TVChatMessageState state;

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

// Passe TOUS les messages actuellement en mémoire d'un utilisateur en
// .deletedCollapsed — utilisé pour timeout/ban (Phase 5). Retrouve les
// messages via l'index authorUserID, pas un scan.
- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID;

// Bascule .deletedCollapsed <-> .deletedExpanded (tap-to-reveal, Phase 5).
// No-op si le message n'est pas dans un état "supprimé".
- (void)toggleExpandedForMessageID:(NSString *)messageID;

// CLEARCHAT global (Phase 5) : marque tous les messages actuellement en
// mémoire comme .deletedCollapsed d'un coup.
- (void)markAllMessagesDeleted;

// Vide entièrement le store (changement de channel — voir Phase 0,
// nettoyage à la fermeture/réouverture pour éviter les fuites entre chaînes).
- (void)removeAllMessages;

// --- Lecture (thread-safe) ---

// Copie de tous les messages, dans l'ordre chronologique d'ajout.
- (NSArray<S7TVChatMessage *> *)allMessages;

- (nullable S7TVChatMessage *)messageWithID:(NSString *)messageID;

@property (nonatomic, strong, readonly) dispatch_queue_t storeQueue;

@end

NS_ASSUME_NONNULL_END
