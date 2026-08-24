/*
 * 7tv-chat-custom-view.h
 *
 * Rendu minimal du chat custom (Phase 1c du plan chat-twitch-custom) :
 * texte brut + couleur du pseudo, sans emotes (arrivent en Phase 2), lu
 * depuis SevenTVChatMessageStore. Basé sur UITableView (hauteur de cellule
 * dynamique via Auto Layout) pour être directement réutilisable telle
 * quelle en Phase 2 (cell reuse déjà en place).
 *
 * Activation : gardée par le kill switch de Phase 0
 * (SevenTVManager.chatCustomTestEnabled). L'installation et le cycle de vie
 * du transcript sont gérés dans 7tv-chat-custom-view.m.
 */

#import <UIKit/UIKit.h>
#import "Chat/7tv-chat-message.h"

NS_ASSUME_NONNULL_BEGIN

@class SevenTVChatCustomView;

// Intégration du composant dans la hiérarchie native Twitch. L'état de la
// vue active et toute la logique de remplacement du transcript vivent avec
// le renderer ; 7tv-core-runtime-hooks.m ne fait que transmettre didMoveToWindow.
UIView * _Nullable s7tv_findChatInputView(void);
SevenTVChatCustomView * _Nullable s7tv_activeChatCustomView(void);
void s7tv_handleNativeChatViewLifecycle(UIView *view);
// Le hook WebSocket transmet les JOIN observés ici au lieu de décider seul
// quelle chaîne est à l'écran. Une vue Twitch déjà conservée peut redevenir
// visible sans nouveau JOIN, tandis qu'un socket hors écran peut se reconnecter.
void s7tv_noteOutgoingChatJoinForChannel(NSString *channel);
// Identité UI actuellement autoritaire, lisible sans toucher UIKit depuis les
// callbacks réseau afin de rejeter les réponses GQL d'une ancienne chaîne.
NSString * _Nullable s7tv_activeNativeChatChannelName(void);
void s7tv_applyChatCustomToggle(void);
void s7tv_reloadActiveChatCustomView(void);
void s7tv_reloadActiveChatCustomViewAnimated(void);
// Invalidation rare de contenu déjà existant (catalogues, apparence, image
// Channel Points) : force aussi le panneau Fil sans réintroduire ce coût dans
// le batching normal des nouveaux messages.
void s7tv_reloadActiveChatCustomViewForConfiguration(void);
void s7tv_reloadActiveChatMessage(NSString *messageID);
// Propage aussi une modération aux modèles encore retenus par un transcript
// figé ou un panneau Fil, même s'ils ont déjà quitté le FIFO principal.
void s7tv_applyModerationStateToRetainedMessage(NSString *messageID,
                                                S7TVChatMessageState state,
                                                S7TVChatModerationKind moderationKind,
                                                NSInteger durationSeconds);
void s7tv_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString * _Nullable authorLogin,
                                                    S7TVChatModerationKind moderationKind,
                                                    NSInteger durationSeconds);
void s7tv_applyModerationToAllRetainedMessages(void);
void s7tv_scheduleChatCustomReload(void);
void s7tv_setupChatCustomIntegration(void);

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
// (voir S7TVReplyThreadPanel) : à l'intérieur d'un fil déjà
// filtré, réafficher "Répond à @X" sur chaque message est redondant — Twitch
// masque ce bandeau dans ce contexte précis (mais pas dans le flux
// principal, où il reste indispensable).
@property (nonatomic, assign) BOOL showsReplyBanners;

// NO par défaut (chat principal). YES uniquement pour la sous-vue
// "réponses" du panneau Fil (voir S7TVReplyThreadPanel) :
// décale chaque message vers la droite avec une barre grise verticale
// continue à gauche, pour les distinguer visuellement du message racine
// épinglé au-dessus (rendu par une AUTRE instance de cette classe, sans ce
// flag). N'a de sens que pour une vue qui n'affiche QUE des réponses —
// jamais utilisé sur le chat principal.
@property (nonatomic, assign) BOOL usesThreadReplyIndent;

// YES uniquement pour le transcript principal : quand l'utilisateur remonte,
// sa structure visible reste figée malgré la purge FIFO à 300 messages.
// Les vues temporaires et petites (thread, preview du picker) passent ce flag
// à NO : elles conservent leur ancre mais ne doivent jamais bloquer un reload.
@property (nonatomic, assign) BOOL freezesTranscriptWhenScrolled;

// YES suspend tout travail visuel coûteux (observers et décodages animés,
// rechargements déclenchés par une image) tout en laissant les snapshots se
// terminer proprement. Utilisé lorsque le panneau Fil est masqué.
@property (nonatomic, assign, getter=isRenderingSuspended) BOOL renderingSuspended;

// YES par défaut. La racine épinglée d'un fil passe à NO afin qu'un message
// long et plafonné commence toujours par sa première ligne, pas par sa fin.
@property (nonatomic, assign) BOOL automaticallyScrollsToBottom;

// Appelé après un appui long sur un message, dans le chat principal comme
// dans un fil. Tous les contextes transmettent le même messageID et le même
// authorDisplayName au pipeline de réponse unique côté hôte.
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
// 7tv-chat-reply-thread-panel.m.
- (void)reloadMessagesWithCompletion:(void (^ _Nullable)(void))completion;

// Recharge une seule cellule sans reconstruire/recharger tout le transcript.
// Utilisée par CLEARMSG et par le tap collapsed <-> expanded.
- (void)refreshMessageWithID:(NSString *)messageID animated:(BOOL)animated;
- (void)refreshMessageWithID:(NSString *)messageID
                    animated:(BOOL)animated
                  completion:(void (^ _Nullable)(void))completion;

// Recherche dans le snapshot réellement affiché, y compris pendant le gel
// du transcript lorsque le FIFO principal a déjà purgé ce modèle.
- (S7TVChatMessage * _Nullable)displayedMessageWithID:(NSString *)messageID;
// Snapshot du fil tel qu'il est réellement visible. Couvre les réponses que
// le gel retient après leur purge du store principal.
- (NSArray<S7TVChatMessage *> *)displayedMessagesForThreadRootID:(NSString *)threadRootID;

// Mutations de contenu sans toucher à la structure du snapshot. Elles sont
// utilisées après la mutation du store principal pour couvrir les objets que
// le gel du transcript conserve au-delà de la limite de 300 messages.
- (void)applyModerationState:(S7TVChatMessageState)state
  toDisplayedMessageWithID:(NSString *)messageID
             moderationKind:(S7TVChatModerationKind)moderationKind
            durationSeconds:(NSInteger)durationSeconds;
- (void)applyModerationToDisplayedMessagesForUserID:(NSString *)authorUserID
                                        authorLogin:(NSString * _Nullable)authorLogin
                                      moderationKind:(S7TVChatModerationKind)moderationKind
                                     durationSeconds:(NSInteger)durationSeconds;
- (void)applyModerationToAllDisplayedMessages;

// Lorsqu'un transcript principal est figé, un reload structurel reste en
// attente jusqu'au retour en bas. Cette méthode reconfigure tout de même les
// cellules actuellement visibles (apparence, ban/timeout/CLEARCHAT) sans
// modifier l'ordre ni les IDs du snapshot gelé.
- (void)refreshVisibleMessageContentIfFrozen;

// Nettoie l'état qui ne doit pas survivre à la réutilisation d'une vue dans
// un autre contexte (thread fermé/réouvert), sans interrompre brutalement un
// applySnapshot déjà en vol.
- (void)resetTransientTranscriptState;

// Active ou désactive uniquement le défilement de la table, sans couper ses
// gestes. Le message racine d'un thread l'utilise avec NO : sa cellule garde
// donc l'appui long de réponse tout en restant physiquement non scrollable.
- (void)setScrollingEnabled:(BOOL)enabled;

// Hauteur réelle du contenu (tableView.contentSize.height, cellules
// self-sizing incluses). Force un layout complet (largeur → recalcul des
// cellules si besoin, cf. -layoutSubviews) avant de lire la valeur — donc
// self.frame doit déjà avoir la bonne largeur au moment de l'appel.
// Utilisée par SevenTVEmotePickerController pour dimensionner sa fenêtre
// flottante de preview sur le contenu réel plutôt qu'une hauteur fixe.
- (CGFloat)s7tvContentHeight;

@end

NS_ASSUME_NONNULL_END
