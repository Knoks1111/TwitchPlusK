/*
 * 7tv-chat-ReplyThreadPanel.h
 *
 * Panneau "Fil" (réponses) — voir 7tv-chat-ReplyThreadPanel.m pours le détail.
 * Extrait de TweakSevenTV.m (voir migration-panneau-fil.md).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVChatCustomView.h"

@interface S7TVReplyThreadPanel : NSObject <SevenTVChatCustomViewDelegate>
+ (instancetype)sharedPanel;
// Reçoit directement le tap depuis la vue de chat réelle — voir l'assignation
// de .delegate sur customView dans s7tv_applyChatCustomTest (TweakSevenTV.m).
// tappedMessageID : garde en mémoire le message précis sur lequel on a tapé
// (voir pendingReplyTargetMessageID) — c'est LUI la cible de la réponse,
// pas la racine du fil (les deux sont différents dès que le fil a plus d'un
// message). Pas encore utilisé pour pré-remplir un champ de saisie (input
// pas encore implémenté), mais déjà stocké pour ne pas avoir à refaire cette
// plomberie plus tard.
- (void)showForThreadRootID:(NSString *)threadRootID tappedMessageID:(NSString *)tappedMessageID;
- (void)hide;
// Appelé après chaque reload du chat principal (voir
// s7tv_reloadActiveChatCustomView dans TweakSevenTV.m) — no-op si le
// panneau est fermé.
- (void)refreshIfNeeded;
@end
