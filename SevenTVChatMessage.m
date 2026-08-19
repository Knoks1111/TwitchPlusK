/*
 * SevenTVChatMessage.m
 *
 * Voir SevenTVChatMessage.h pour le contexte général (Phase 1a).
 */

#import "SevenTVChatMessage.h"
#import "SevenTVManager.h"


// ============================================================
// MARK: - S7TVChatUserColorRegistry
// ============================================================

@interface SevenTVChatUserColorRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIColor *> *colorsByLowercaseUsername;
// Même pattern que S7TVChatMessageStore.storeQueue plus bas dans ce
// fichier : queue concurrente dédiée, lecture en dispatch_sync, écriture
// en dispatch_barrier_async.
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation SevenTVChatUserColorRegistry

+ (instancetype)sharedRegistry {
    static SevenTVChatUserColorRegistry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVChatUserColorRegistry alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorsByLowercaseUsername = [NSMutableDictionary dictionary];
        _queue = dispatch_queue_create("tv.s7tv.chat-user-color-registry",
                                        DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)registerColor:(nullable UIColor *)color forUsername:(NSString *)username {
    if (!color || !username.length) return;
    NSString *key = username.lowercaseString;
    dispatch_barrier_async(self.queue, ^{
        self.colorsByLowercaseUsername[key] = color;
    });
}

- (nullable UIColor *)colorForUsername:(NSString *)username {
    if (!username.length) return nil;
    NSString *key = username.lowercaseString;
    __block UIColor *result;
    dispatch_sync(self.queue, ^{
        result = self.colorsByLowercaseUsername[key];
    });
    return result;
}

@end


// ============================================================
// MARK: - S7TVChatToken
// ============================================================

@implementation S7TVChatToken

+ (instancetype)textToken:(NSString *)text {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeText;
    t.text = text;
    return t;
}

+ (instancetype)mentionToken:(NSString *)text color:(nullable UIColor *)color {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeMention;
    t.text = text;
    t.mentionColor = color;
    return t;
}

+ (instancetype)urlToken:(NSString *)text {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeURL;
    t.text = text;
    return t;
}

+ (instancetype)emoteToken:(NSString *)name
                   provider:(S7TVChatTokenType)providerType
                   emoteID:(NSString *)emoteID {
    NSAssert(providerType == S7TVChatTokenTypeEmote7TV ||
             providerType == S7TVChatTokenTypeEmoteTwitch,
             @"emoteToken: providerType doit être .emote7TV ou .emoteTwitch");
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = providerType;
    t.text = name;
    t.providerEmoteID = emoteID;
    return t;
}

@end


// ============================================================
// MARK: - S7TVSystemMessageInfo (Phase 3)
// ============================================================

@implementation S7TVSystemMessageInfo
@end


// ============================================================
// MARK: - S7TVChatMessage
// ============================================================

@implementation S7TVChatMessage

- (instancetype)initWithMessageID:(NSString *)messageID
                       timestamp:(NSDate *)timestamp
                    authorUserID:(NSString *)authorUserID
                 authorDisplayName:(NSString *)authorDisplayName
                         rawText:(NSString *)rawText {
    self = [super init];
    if (self) {
        _messageID         = [messageID copy];
        _timestamp         = timestamp;
        _authorUserID      = [authorUserID copy];
        _authorDisplayName = [authorDisplayName copy];
        _rawText           = [rawText copy];
        _twitchEmotesTag   = @"";
        _badgeIdentifiers  = @[];
        _type              = S7TVChatMessageTypeNormal;
        _state             = S7TVChatMessageStateNormal;
    }
    return self;
}

@end


// ============================================================
// MARK: - S7TVChatMessageStore
// ============================================================

@interface S7TVChatMessageStore ()
// Ordre chronologique d'ajout — source de vérité pour l'affichage et pour
// la purge FIFO au-delà de maxMessageCount.
@property (nonatomic, strong) NSMutableArray<S7TVChatMessage *> *orderedMessages;
// Index messageID → message, pour retrouver/mettre à jour en O(1) plutôt
// qu'un scan de orderedMessages à chaque suppression (important : un
// timeout peut viser plusieurs dizaines de messages d'un coup sur une
// grosse chaîne, voir exigence transverse #3).
@property (nonatomic, strong) NSMutableDictionary<NSString *, S7TVChatMessage *> *messagesByID;
// Index authorUserID → ensemble de messageID actuellement en mémoire pour
// cet utilisateur. Alimente markAllMessagesDeletedForUserID: sans scan.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *messageIDsByUserID;
// threadRootID → messageID de réponse, dans l'ordre chronologique d'ajout
// (le message racine lui-même n'est PAS dans ce tableau, seulement ses
// réponses — voir -messagesForThreadRootID: qui reconstitue l'ordre complet
// via orderedMessages si besoin, mais s'appuie d'abord sur cet index pour
// savoir QUELS ids appartiennent au fil sans scanner tout le store).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *replyIDsByThreadRootID;
@property (nonatomic, strong, readwrite) dispatch_queue_t storeQueue;
@end

@implementation S7TVChatMessageStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxMessageCount     = 300;
        _orderedMessages     = [NSMutableArray array];
        _messagesByID        = [NSMutableDictionary dictionary];
        _messageIDsByUserID  = [NSMutableDictionary dictionary];
        _replyIDsByThreadRootID = [NSMutableDictionary dictionary];
        // Même pattern que SevenTVManager.emoteQueue : concurrente, lectures
        // en dispatch_sync, écritures en dispatch_barrier_async.
        _storeQueue = dispatch_queue_create("tv.s7tv.chat-message-store",
                                            DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

#pragma mark - Écriture

- (void)addMessage:(S7TVChatMessage *)message {
    if (!message.messageID.length) {
        [[SevenTVManager sharedManager]
            log:@"[ChatCustom] ⚠️ addMessage: ignoré (messageID vide)"];
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        // Doublon (ex: re-livraison IRC) → no-op plutôt que dupliquer à l'écran.
        if (self.messagesByID[message.messageID]) return;

        // Alimente le registre pseudo -> couleur (voir
        // SevenTVChatUserColorRegistry ci-dessus) AVANT tout autre traitement, pour
        // que la couleur de CET auteur soit déjà disponible si un message
        // suivant (même dans le même burst IRC) le mentionne.
        if (message.authorColor && message.authorDisplayName.length) {
            [[SevenTVChatUserColorRegistry sharedRegistry]
                registerColor:message.authorColor forUsername:message.authorDisplayName];
        }

        [self.orderedMessages addObject:message];
        self.messagesByID[message.messageID] = message;

        if (message.authorUserID.length) {
            NSMutableSet<NSString *> *set = self.messageIDsByUserID[message.authorUserID];
            if (!set) {
                set = [NSMutableSet set];
                self.messageIDsByUserID[message.authorUserID] = set;
            }
            [set addObject:message.messageID];
        }

        // ── Fils de discussion ──────────────────────────────────────────
        // Toujours indexé sur replyThreadRootID (la racine), jamais sur
        // replyParentMessageID (le parent immédiat) — voir le commentaire
        // sur replyThreadRootID dans SevenTVChatMessage.h : indexer sur le
        // parent immédiat fragmenterait un même fil dès qu'un message
        // répond à une réponse plutôt qu'au tout premier message.
        if (message.replyThreadRootID.length) {
            NSMutableArray<NSString *> *replies = self.replyIDsByThreadRootID[message.replyThreadRootID];
            if (!replies) {
                replies = [NSMutableArray array];
                self.replyIDsByThreadRootID[message.replyThreadRootID] = replies;
            }
            [replies addObject:message.messageID];

            // Le message racine peut être encore en mémoire (cas courant) —
            // si oui, on lui incrémente replyCount pour l'affichage "X
            // réponses" sous le message racine. S'il n'est plus en mémoire
            // (purgé), rien à mettre à jour ici : le panneau Fil retombe sur
            // replyParentUsername/replyParentBodyPreview de chaque réponse.
            S7TVChatMessage *root = self.messagesByID[message.replyThreadRootID];
            root.replyCount += 1;
        }

        [self s7tv_purgeIfNeeded];
    });
}

// Doit être appelé depuis l'intérieur d'un bloc déjà sur storeQueue
// (barrier) — pas de dispatch supplémentaire ici pour éviter un deadlock.
- (void)s7tv_purgeIfNeeded {
    while (self.orderedMessages.count > self.maxMessageCount) {
        S7TVChatMessage *oldest = self.orderedMessages.firstObject;
        if (!oldest) break;
        [self.orderedMessages removeObjectAtIndex:0];
        [self.messagesByID removeObjectForKey:oldest.messageID];
        if (oldest.authorUserID.length) {
            NSMutableSet<NSString *> *set = self.messageIDsByUserID[oldest.authorUserID];
            [set removeObject:oldest.messageID];
            if (set.count == 0) {
                [self.messageIDsByUserID removeObjectForKey:oldest.authorUserID];
            }
        }
        // Retire cette réponse de l'index de son fil si elle en a un — sinon
        // messagesForThreadRootID: renverrait un id purgé (message
        // introuvable dans messagesByID, filtré à la lecture de toute façon,
        // mais autant garder l'index propre plutôt que de compter dessus).
        if (oldest.replyThreadRootID.length) {
            NSMutableArray<NSString *> *replies = self.replyIDsByThreadRootID[oldest.replyThreadRootID];
            [replies removeObject:oldest.messageID];
            if (replies.count == 0) {
                [self.replyIDsByThreadRootID removeObjectForKey:oldest.replyThreadRootID];
            }
        }
    }
}

- (void)markMessageDeletedByID:(NSString *)messageID {
    if (!messageID.length) return;
    dispatch_barrier_async(self.storeQueue, ^{
        S7TVChatMessage *msg = self.messagesByID[messageID];
        if (!msg) return; // déjà purgé ou jamais reçu — no-op silencieux
        msg.state = S7TVChatMessageStateDeletedCollapsed;
    });
}

- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID {
    if (!authorUserID.length) return;
    dispatch_barrier_async(self.storeQueue, ^{
        NSSet<NSString *> *ids = self.messageIDsByUserID[authorUserID];
        for (NSString *msgID in ids) {
            S7TVChatMessage *msg = self.messagesByID[msgID];
            msg.state = S7TVChatMessageStateDeletedCollapsed;
        }
    });
}

- (void)toggleExpandedForMessageID:(NSString *)messageID {
    if (!messageID.length) return;
    dispatch_barrier_async(self.storeQueue, ^{
        S7TVChatMessage *msg = self.messagesByID[messageID];
        if (!msg) return;
        if (msg.state == S7TVChatMessageStateDeletedCollapsed) {
            msg.state = S7TVChatMessageStateDeletedExpanded;
        } else if (msg.state == S7TVChatMessageStateDeletedExpanded) {
            msg.state = S7TVChatMessageStateDeletedCollapsed;
        }
        // .normal : pas de toggle, rien à révéler.
    });
}

- (void)markAllMessagesDeleted {
    dispatch_barrier_async(self.storeQueue, ^{
        for (S7TVChatMessage *msg in self.orderedMessages) {
            msg.state = S7TVChatMessageStateDeletedCollapsed;
        }
    });
}

- (void)removeAllMessages {
    dispatch_barrier_async(self.storeQueue, ^{
        [self.orderedMessages removeAllObjects];
        [self.messagesByID removeAllObjects];
        [self.messageIDsByUserID removeAllObjects];
    });
}

- (void)retokenizeMessagesUsingBlock:(NSArray<S7TVChatToken *> * (^)(S7TVChatMessage *message))tokenizer
                          completion:(void (^ _Nullable)(void))completion {
    if (!tokenizer) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        for (S7TVChatMessage *message in self.orderedMessages) {
            message.tokens = tokenizer(message);
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Lecture

- (NSArray<S7TVChatMessage *> *)allMessages {
    __block NSArray<S7TVChatMessage *> *snapshot;
    dispatch_sync(self.storeQueue, ^{
        snapshot = [self.orderedMessages copy];
    });
    return snapshot;
}

- (nullable S7TVChatMessage *)messageWithID:(NSString *)messageID {
    if (!messageID.length) return nil;
    __block S7TVChatMessage *result;
    dispatch_sync(self.storeQueue, ^{
        result = self.messagesByID[messageID];
    });
    return result;
}

- (NSArray<S7TVChatMessage *> *)messagesForThreadRootID:(NSString *)threadRootID {
    if (!threadRootID.length) return @[];
    __block NSArray<S7TVChatMessage *> *result;
    dispatch_sync(self.storeQueue, ^{
        NSMutableArray<S7TVChatMessage *> *messages = [NSMutableArray array];
        // Le message racine lui-même compte comme premier message du fil
        // s'il est encore en mémoire.
        S7TVChatMessage *root = self.messagesByID[threadRootID];
        if (root) [messages addObject:root];
        NSArray<NSString *> *replyIDs = self.replyIDsByThreadRootID[threadRootID];
        for (NSString *msgID in replyIDs) {
            S7TVChatMessage *msg = self.messagesByID[msgID];
            if (msg) [messages addObject:msg]; // absent = purgé, on saute
        }
        result = messages;
    });
    return result;
}

- (void)seedReadOnlyWithMessages:(NSArray<S7TVChatMessage *> *)messages {
    dispatch_barrier_async(self.storeQueue, ^{
        [self.orderedMessages removeAllObjects];
        [self.messagesByID removeAllObjects];
        [self.messageIDsByUserID removeAllObjects];
        [self.replyIDsByThreadRootID removeAllObjects];
        for (S7TVChatMessage *msg in messages) {
            if (!msg.messageID.length) continue;
            [self.orderedMessages addObject:msg];
            self.messagesByID[msg.messageID] = msg;
        }
    });
}

@end
