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

@class SevenTVChatCustomView;

// Notifie l'hôte (le vrai chat, PAS ce composant) quand l'utilisateur tape
// sur le bandeau "Répond à @X" d'un message. Cette vue ne présente jamais
// elle-même le panneau "Fil" — même principe que le panneau des
// tailles/fake chat du picker, géré par son controller hôte plutôt que par
// le composant enfant.
@protocol SevenTVChatCustomViewDelegate <NSObject>
@optional
// threadRootID = toujours la racine du fil (S7TVChatMessage.replyThreadRootID),
// jamais le parent immédiat — c'est cet id qu'il faut passer à
// -[S7TVChatMessageStore messagesForThreadRootID:] pour peupler le panneau.
- (void)chatCustomView:(SevenTVChatCustomView *)view
    didTapReplyBannerForThreadRootID:(NSString *)threadRootID;
@end

@interface SevenTVChatCustomView : UIView

@property (nonatomic, weak) id<SevenTVChatCustomViewDelegate> delegate;

// YES par défaut (chat principal). Passer à NO pour un usage "panneau Fil"
// (voir S7TVReplyThreadPanel, TweakSevenTV.m) : à l'intérieur d'un fil déjà
// filtré, réafficher "Répond à @X" sur chaque message est redondant — Twitch
// masque ce bandeau dans ce contexte précis (mais pas dans le flux
// principal, où il reste indispensable).
@property (nonatomic, assign) BOOL showsReplyBanners;

// NO par défaut (chat principal). YES uniquement pour la sous-vue
// "réponses" du panneau Fil (voir S7TVReplyThreadPanel, TweakSevenTV.m) :
// décale chaque message vers la droite avec une barre grise verticale
// continue à gauche, pour les distinguer visuellement du message racine
// épinglé au-dessus (rendu par une AUTRE instance de cette classe, sans ce
// flag). N'a de sens que pour une vue qui n'affiche QUE des réponses —
// jamais utilisé sur le chat principal.
@property (nonatomic, assign) BOOL usesThreadReplyIndent;

- (instancetype)initWithStore:(S7TVChatMessageStore *)store;

// Recharge l'affichage depuis le store. Phase 1c fait un reload complet à
// chaque appel — le batching (regrouper les messages arrivés dans une
// fenêtre ~100-200ms, exigence transverse #3) arrive quand le volume le
// justifiera, pas avant d'avoir un rendu qui marche.
- (void)reloadMessages;

// Hauteur réelle du contenu (tableView.contentSize.height, cellules
// self-sizing incluses). Force un layout complet (largeur → recalcul des
// cellules si besoin, cf. -layoutSubviews) avant de lire la valeur — donc
// self.frame doit déjà avoir la bonne largeur au moment de l'appel.
// Utilisée par SevenTVEmotePickerController pour dimensionner sa fenêtre
// flottante de preview sur le contenu réel plutôt qu'une hauteur fixe.
- (CGFloat)s7tvContentHeight;

@end

NS_ASSUME_NONNULL_END
