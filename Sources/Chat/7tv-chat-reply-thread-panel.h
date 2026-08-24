/*
 * 7tv-chat-reply-thread-panel.h
 *
 * Panneau "Fil" (réponses) — voir 7tv-chat-reply-thread-panel.m pour le détail.
 * Extrait de 7tv-core-runtime-hooks.m (voir migration-panneau-fil.md).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Chat/7tv-chat-custom-view.h"

NS_ASSUME_NONNULL_BEGIN

@interface S7TVReplyThreadPanel : NSObject <SevenTVChatCustomViewDelegate>
+ (instancetype)sharedPanel;
// Reçoit directement le tap depuis la vue de chat réelle — voir l'assignation
// de .delegate lors de l'installation dans 7tv-chat-custom-view.m.
// tappedMessageID garde en mémoire le message précis ayant ouvert le fil,
// distinct de sa racine. L'ouverture reste en mode consultation : seul un
// appui long explicite préremplit la saisie Twitch.
- (void)showForThreadRootID:(NSString *)threadRootID tappedMessageID:(NSString *)tappedMessageID;
// Point d'entrée unique pour l'appui long du chat principal et des threads.
- (void)selectReplyTargetForMessageID:(NSString *)messageID username:(NSString *)username;
- (void)hide;
// Appelé après chaque reload du chat principal (voir
// s7tv_reloadActiveChatCustomView dans 7tv-chat-custom-view.m) — no-op si le
// panneau est fermé.
- (void)refreshIfNeeded;
// Reconfigure volontairement le fil même si sa liste d'IDs est inchangée
// (langue/apparence, badges ou modération groupée).
- (void)forceRefreshIfNeeded;
// Met à jour uniquement le message concerné dans les sous-vues qui
// l'affichent. excludedView évite un double snapshot après une interaction
// provenant directement de cette sous-vue.
- (void)refreshMessageIfNeededWithID:(NSString *)messageID
                       excludingView:(SevenTVChatCustomView * _Nullable)excludedView;
- (void)applyModerationState:(S7TVChatMessageState)state
   toRetainedMessageWithID:(NSString *)messageID
             moderationKind:(S7TVChatModerationKind)moderationKind
            durationSeconds:(NSInteger)durationSeconds;
- (void)applyModerationToRetainedMessagesForUserID:(NSString *)authorUserID
                                      authorLogin:(NSString * _Nullable)authorLogin
                                    moderationKind:(S7TVChatModerationKind)moderationKind
                                   durationSeconds:(NSInteger)durationSeconds;
- (void)applyModerationToAllRetainedMessages;
@end

NS_ASSUME_NONNULL_END
