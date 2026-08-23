/*
 * 7tv-chat-ReplyThreadPanel.h
 *
 * Panneau "Fil" (réponses) — voir 7tv-chat-ReplyThreadPanel.m pour le détail.
 * Extrait de TweakSevenTV.m (voir migration-panneau-fil.md).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVChatCustomView.h"

@interface S7TVReplyThreadPanel : NSObject <SevenTVChatCustomViewDelegate>
+ (instancetype)sharedPanel;
// Reçoit directement le tap depuis la vue de chat réelle — voir l'assignation
// de .delegate lors de l'installation dans SevenTVChatCustomView.m.
// tappedMessageID garde en mémoire le message précis ayant ouvert le fil,
// distinct de sa racine. L'ouverture reste en mode consultation : seule une
// sélection explicite (flèche ou appui long) préremplit la saisie Twitch.
- (void)showForThreadRootID:(NSString *)threadRootID tappedMessageID:(NSString *)tappedMessageID;
// Point d'entrée unique pour toute sélection de cible : flèche d'un thread
// ou appui long dans le chat principal.
- (void)selectReplyTargetForMessageID:(NSString *)messageID username:(NSString *)username;
- (void)hide;
// Appelé après chaque reload du chat principal (voir
// s7tv_reloadActiveChatCustomView dans SevenTVChatCustomView.m) — no-op si le
// panneau est fermé.
- (void)refreshIfNeeded;
@end
