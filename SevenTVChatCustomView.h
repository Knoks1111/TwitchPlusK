/*
 * SevenTVChatCustomView.h
 *
 * Rendu minimal du chat custom (Phase 1c du plan chat-twitch-custom) :
 * texte brut + couleur du pseudo, sans emotes (arrivent en Phase 2), lu
 * depuis SevenTVChatMessageStore. Basé sur UITableView (hauteur de cellule
 * dynamique via Auto Layout) pour être directement réutilisable telle
 * quelle en Phase 2 (cell reuse déjà en place).
 *
 * Activation : gardée par le kill switch de Phase 0
 * (SevenTVManager.chatCustomTestEnabled) — voir TweakSevenTV.m,
 * s7tv_applyChatCustomTest().
 */

#import <UIKit/UIKit.h>
#import "SevenTVChatMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface SevenTVChatCustomView : UIView

- (instancetype)initWithStore:(S7TVChatMessageStore *)store;

// Recharge l'affichage depuis le store. Phase 1c fait un reload complet à
// chaque appel — le batching (regrouper les messages arrivés dans une
// fenêtre ~100-200ms, exigence transverse #3) arrive quand le volume le
// justifiera, pas avant d'avoir un rendu qui marche.
- (void)reloadMessages;

@end

NS_ASSUME_NONNULL_END
