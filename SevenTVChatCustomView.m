/*
 * SevenTVChatCustomView.m
 *
 * Voir SevenTVChatCustomView.h pour le contexte (Phase 1c).
 */

#import "SevenTVChatCustomView.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVManager.h"


// ============================================================
// MARK: - Cellule (texte brut, hauteur dynamique)
// ============================================================

@interface S7TVChatCustomCell : UITableViewCell
@property (nonatomic, strong) UILabel *messageLabel;
@end

@implementation S7TVChatCustomCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(nullable NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        _messageLabel = [[UILabel alloc] init];
        _messageLabel.numberOfLines = 0; // Phase 1c : word-wrap standard,
                                          // le fallback character-wrap pour
                                          // texte sans espace (URL énorme)
                                          // arrive si le test le montre nécessaire.
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_messageLabel];

        // Marges 8pt — pas encore dans la config (Phase 1b ne couvre que
        // les tailles listées par le plan) ; à ajouter si on veut les
        // rendre réglables plus tard.
        [NSLayoutConstraint activateConstraints:@[
            [_messageLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_messageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
            [_messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        ]];
    }
    return self;
}

@end


// ============================================================
// MARK: - SevenTVChatCustomView
// ============================================================

@interface SevenTVChatCustomView () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) S7TVChatMessageStore *store;
@property (nonatomic, strong) UITableView *tableView;
// Snapshot pris à chaque reload — évite un décalage d'index si le store
// change pendant que la table itère dessus (lecture thread-safe côté store,
// mais la table a besoin d'un tableau stable pendant tout le reload).
@property (nonatomic, strong) NSArray<S7TVChatMessage *> *displayedMessages;
@end

@implementation SevenTVChatCustomView

- (instancetype)initWithStore:(S7TVChatMessageStore *)store {
    self = [super init];
    if (self) {
        _store = store;
        _displayedMessages = @[];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.translatesAutoresizingMaskIntoConstraints = NO;
        _tableView.backgroundColor        = [UIColor clearColor];
        _tableView.separatorStyle         = UITableViewCellSeparatorStyleNone;
        _tableView.dataSource             = self;
        _tableView.delegate               = self;
        _tableView.rowHeight              = UITableViewAutomaticDimension;
        _tableView.estimatedRowHeight     = 24;
        // Le clavier/barre de saisie restent 100% natifs Twitch (principe
        // directeur du plan) — cette table n'a donc pas à gérer le clavier.
        [_tableView registerClass:[S7TVChatCustomCell class]
            forCellReuseIdentifier:@"cell"];

        self.backgroundColor = [UIColor clearColor];
        [self addSubview:_tableView];
        [NSLayoutConstraint activateConstraints:@[
            [_tableView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_tableView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_tableView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_tableView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
}

- (void)reloadMessages {
    NSAssert([NSThread isMainThread],
             @"reloadMessages doit être appelé depuis le main thread (touche UIKit)");

    NSArray<S7TVChatMessage *> *oldMessages = self.displayedMessages;
    NSArray<S7TVChatMessage *> *newMessages = [self.store allMessages];

    // Ne fige "on est en bas" qu'AVANT de toucher au contenu — sinon la
    // comparaison se ferait sur une table déjà mise à jour. Version minimale :
    // la vraie suspension du scroll manuel (bouton "nouveaux messages") est
    // prévue explicitement en Phase 4 ; ce garde-fou évite juste qu'un flux
    // rapide fasse sauter la vue sous les yeux de quelqu'un qui remonte lire
    // l'historique.
    CGFloat distanceFromBottom = self.tableView.contentSize.height
        - (self.tableView.contentOffset.y + self.tableView.bounds.size.height);
    BOOL wasNearBottom = (oldMessages.count == 0) || (distanceFromBottom < 80);

    self.displayedMessages = newMessages;

    // Cas fréquent sur un flux actif : uniquement des messages ajoutés en
    // fin de liste depuis le dernier reload (pas de suppression/purge entre
    // les deux) → insertion incrémentale des nouvelles lignes seulement,
    // bien moins coûteuse qu'un reloadData complet qui retraverse toute la
    // table à chaque message (exigence transverse #3 — perf grosse chaîne).
    //
    // Comparaison par référence (isEqualToArray → isEqual: → pointeur pour
    // NSObject) : les messages sont les mêmes instances mutables d'un appel
    // à l'autre, donc ce test est fiable ET gratuit — pas de deep-copy.
    //
    // LIMITE CONNUE (Phase 5) : si un message déjà affiché change d'état
    // (ex: passage en .deletedCollapsed suite à un timeout) sans qu'aucun
    // message ne soit ajouté après lui, ce chemin rapide ne rafraîchit PAS
    // sa cellule (même référence d'objet, donc "préfixe identique" reste
    // vrai). Non bloquant pour l'instant : le pipeline de suppression n'est
    // pas encore branché sur reloadMessages. À corriger quand la Phase 5
    // sera câblée ici — invalider spécifiquement les indexPaths concernés
    // via reloadRowsAtIndexPaths: plutôt que de se fier au seul appendage.
    BOOL isSimpleAppend = newMessages.count > oldMessages.count &&
        [[newMessages subarrayWithRange:NSMakeRange(0, oldMessages.count)]
            isEqualToArray:oldMessages];

    if (isSimpleAppend) {
        NSMutableArray<NSIndexPath *> *newIndexPaths = [NSMutableArray array];
        for (NSUInteger i = oldMessages.count; i < newMessages.count; i++) {
            [newIndexPaths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
        }
        [self.tableView insertRowsAtIndexPaths:newIndexPaths
                              withRowAnimation:UITableViewRowAnimationNone];
    } else {
        // Suppression, purge mémoire, ou premier reload → pas de diff fiable
        // possible, reload complet (plus sûr qu'un diff partiel incorrect).
        [self.tableView reloadData];
    }

    if (wasNearBottom && newMessages.count > 0) {
        NSIndexPath *last = [NSIndexPath indexPathForRow:newMessages.count - 1
                                                 inSection:0];
        [self.tableView scrollToRowAtIndexPath:last
                               atScrollPosition:UITableViewScrollPositionBottom
                                       animated:NO];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayedMessages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"
                                                                forIndexPath:indexPath];
    S7TVChatMessage *msg = self.displayedMessages[indexPath.row];
    cell.messageLabel.attributedText = [self s7tv_attributedTextForMessage:msg];
    return cell;
}

#pragma mark - Construction du texte

- (NSAttributedString *)s7tv_attributedTextForMessage:(S7TVChatMessage *)msg {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];

    UIFont *usernameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *messageFont  = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = msg.authorColor ?: [UIColor whiteColor];
    UIColor *messageColor  = [UIColor whiteColor];

    NSMutableAttributedString *result = [NSMutableAttributedString new];

    NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";

    // Placeholder texte de la Phase 5 (déjà anticipé par le modèle de
    // données — state géré ici en attendant l'implémentation complète du
    // tap-to-reveal, qui viendra avec sa propre cellule dédiée en Phase 5).
    NSString *bodyText;
    if (msg.state == S7TVChatMessageStateDeletedCollapsed) {
        bodyText = @"[message supprimé]";
        messageColor = [UIColor grayColor];
    } else {
        // .normal et .deletedExpanded affichent tous deux rawText pour
        // l'instant — la distinction visuelle (texte atténué) pour
        // .deletedExpanded arrive avec la cellule dédiée en Phase 5.
        bodyText = msg.rawText ?: @"";
    }

    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[displayName stringByAppendingString:@": "]
            attributes:@{NSFontAttributeName: usernameFont,
                         NSForegroundColorAttributeName: usernameColor}]];
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:bodyText
            attributes:@{NSFontAttributeName: messageFont,
                         NSForegroundColorAttributeName: messageColor}]];

    return result;
}

@end
