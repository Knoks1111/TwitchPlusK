/*
 * SevenTVChatMessage.m
 *
 * Voir SevenTVChatMessage.h pour le contexte général (Phase 1a).
 */

#import "SevenTVChatMessage.h"
#import "SevenTVManager.h"


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

+ (instancetype)mentionToken:(NSString *)text {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeMention;
    t.text = text;
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

@end
