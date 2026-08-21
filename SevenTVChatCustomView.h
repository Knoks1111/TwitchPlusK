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
// sur un message qui répond à quelqu'un (bandeau OU message lui-même — voir
// s7tv_handleTap: dans le .m). Cette vue ne présente jamais elle-même le
// panneau "Fil" — même principe que le panneau des tailles/fake chat du
// picker, géré par son controller hôte plutôt que par le composant enfant.
@protocol SevenTVChatCustomViewDelegate <NSObject>
@optional
// threadRootID = toujours la racine du fil (S7TVChatMessage.replyThreadRootID),
// jamais le parent immédiat — c'est cet id qu'il faut passer à
// -[S7TVChatMessageStore messagesForThreadRootID:] pour peupler le panneau.
// tappedMessageID = l'id du message SPÉCIFIQUE sur lequel l'utilisateur a
// tapé (pas forcément la racine — un fil a plusieurs messages) : c'est CE
// message-là qui doit devenir la cible pré-remplie de la réponse dans le
// panneau, PAS son parent (voir S7TVChatMessage.replyParentMessageID, qui
// reste distinct de threadRootID et sert uniquement au regroupement).
- (void)chatCustomView:(SevenTVChatCustomView *)view
    didTapReplyBannerForThreadRootID:(NSString *)threadRootID
                       tappedMessageID:(NSString *)tappedMessageID;
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

// NO par défaut. YES uniquement sur les 2 sous-vues (racine + réponses) du
// panneau Fil : affiche un bouton flèche à droite de CHAQUE message,
// permettant de le désigner comme cible de réponse (voir
// onReplyTargetSelected juste en dessous). N'a de sens que dans ce contexte
// précis — jamais utilisé sur le chat principal.
@property (nonatomic, assign) BOOL showsReplyTargetButton;

// Appelé quand l'utilisateur tape le bouton de sélection de cible d'UN
// message (messageID + authorDisplayName de ce message précis). Bloc plutôt
// que le protocole delegate ci-dessus : contrairement au bandeau reply (qui
// vise un hôte générique quelconque), ce bouton n'a de sens que pour les 2
// sous-vues du panneau Fil, qui les possèdent déjà directement — pas besoin
// d'indirection supplémentaire par un protocole.
@property (nonatomic, copy, nullable) void (^onReplyTargetSelected)(NSString *messageID, NSString *authorDisplayName);

- (instancetype)initWithStore:(S7TVChatMessageStore *)store;

// Recharge l'affichage depuis le store. Phase 1c fait un reload complet à
// chaque appel — le batching (regrouper les messages arrivés dans une
// fenêtre ~100-200ms, exigence transverse #3) arrive quand le volume le
// justifiera, pas avant d'avoir un rendu qui marche.
- (void)reloadMessages;

// Même mise à jour globale, avec animation des changements d'état. Réservée
// aux mutations groupées de Phase 5 (timeout/ban/CLEARCHAT global) ; le flux
// normal reste non animé pour préserver les performances à haut débit.
- (void)reloadMessagesAnimated:(BOOL)animated;

// Identique, mais appelle completion une fois le contenu RÉELLEMENT appliqué
// à la table (après le applySnapshot: interne, qui est asynchrone même avec
// animatingDifferences:NO). À utiliser quand on doit mesurer le contenu
// juste après (s7tvContentHeight) — mesurer immédiatement après
// -reloadMessages simple lit une hauteur pas encore à jour. Voir
// S7TVReplyThreadPanel dans TweakSevenTV.m.
- (void)reloadMessagesWithCompletion:(void (^ _Nullable)(void))completion;

// Recharge une seule cellule sans reconstruire/recharger tout le transcript.
// Utilisée par CLEARMSG et par le tap collapsed <-> expanded.
- (void)refreshMessageWithID:(NSString *)messageID animated:(BOOL)animated;

// Hauteur réelle du contenu (tableView.contentSize.height, cellules
// self-sizing incluses). Force un layout complet (largeur → recalcul des
// cellules si besoin, cf. -layoutSubviews) avant de lire la valeur — donc
// self.frame doit déjà avoir la bonne largeur au moment de l'appel.
// Utilisée par SevenTVEmotePickerController pour dimensionner sa fenêtre
// flottante de preview sur le contenu réel plutôt qu'une hauteur fixe.
- (CGFloat)s7tvContentHeight;

@end

NS_ASSUME_NONNULL_END
