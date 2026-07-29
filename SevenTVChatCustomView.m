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
// Cache messageID → hauteur exacte déjà mesurée. Remplace complètement
// UITableViewAutomaticDimension (voir raison dans reloadMessages) : avec une
// hauteur connue à l'avance, UIKit n'a plus jamais besoin de re-mesurer une
// cellule après son insertion, donc plus de "saut" visuel entre l'estimation
// et la vraie taille — c'était la cause du rebond qui persistait malgré le
// performBatchUpdates. Bonus perf : une cellule déjà vue ne recalcule plus
// sa hauteur au scroll non plus.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *rowHeightCache;
// Largeur pour laquelle rowHeightCache a été calculé — invalidé si la vue
// change de largeur (rotation, passage normal/théâtre).
@property (nonatomic, assign) CGFloat cachedContentWidth;
@end

@implementation SevenTVChatCustomView

- (instancetype)initWithStore:(S7TVChatMessageStore *)store {
    self = [super init];
    if (self) {
        _store = store;
        _displayedMessages = @[];
        _rowHeightCache = [NSMutableDictionary dictionary];
        _cachedContentWidth = 0;

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.translatesAutoresizingMaskIntoConstraints = NO;
        _tableView.backgroundColor        = [UIColor clearColor];
        _tableView.separatorStyle         = UITableViewCellSeparatorStyleNone;
        _tableView.dataSource             = self;
        _tableView.delegate               = self;
        // Pas d'UITableViewAutomaticDimension : la hauteur exacte de chaque
        // cellule est calculée à l'avance (voir s7tv_heightForMessage:) et
        // mise en cache — élimine le cycle "estimation puis correction" qui
        // causait le rebond, et évite à UIKit de re-mesurer une cellule à
        // chaque passage en scroll.
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

- (void)layoutSubviews {
    [super layoutSubviews];
    // Rotation, ou passage normal ↔ théâtre : la largeur change, donc les
    // hauteurs mises en cache (calculées pour l'ancienne largeur) ne sont
    // plus valables. On invalide tout et on redemande les hauteurs — sans
    // ça, le texte se ré-enroule visuellement mais la ligne garde son
    // ancienne hauteur figée en cache → texte tronqué ou espace vide.
    if (self.bounds.size.width > 0 && self.bounds.size.width != self.cachedContentWidth) {
        self.cachedContentWidth = self.bounds.size.width;
        [self.rowHeightCache removeAllObjects];
        [self.tableView reloadData];
    }
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
        // performBatchUpdates coordonne l'insertion ET le scroll comme une
        // seule transaction de layout — sans ça, UITableViewAutomaticDimension
        // recalcule la vraie hauteur des cellules APRÈS le scroll déjà fait
        // (l'estimatedRowHeight sert de placeholder le temps du premier
        // passage), ce qui décale le contenu une deuxième fois juste après
        // coup → effet de rebond. En scrollant dans le bloc completion (donc
        // après que le layout final soit connu), on scrolle une seule fois,
        // au bon endroit, sans à-coup.
        __weak typeof(self) weakSelf = self;
        [self.tableView performBatchUpdates:^{
            [weakSelf.tableView insertRowsAtIndexPaths:newIndexPaths
                                       withRowAnimation:UITableViewRowAnimationNone];
        } completion:^(BOOL finished) {
            [weakSelf s7tv_scrollToBottomIfNeeded:wasNearBottom];
        }];
    } else {
        // Suppression, purge mémoire, ou premier reload → pas de diff fiable
        // possible, reload complet (plus sûr qu'un diff partiel incorrect).

        // Purge les entrées du cache dont le message n'existe plus dans le
        // store (sinon rowHeightCache grossirait sans limite sur une session
        // longue — un message purgé par maxMessageCount ne revient jamais).
        if (self.rowHeightCache.count > 0) {
            NSMutableSet<NSString *> *validIDs = [NSMutableSet setWithCapacity:newMessages.count];
            for (S7TVChatMessage *m in newMessages) [validIDs addObject:m.messageID];
            NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
            for (NSString *key in self.rowHeightCache) {
                if (![validIDs containsObject:key]) [staleKeys addObject:key];
            }
            [self.rowHeightCache removeObjectsForKeys:staleKeys];
        }

        [self.tableView reloadData];
        // reloadData n'a pas de completion — layoutIfNeeded force le calcul
        // des vraies hauteurs de cellule avant de scroller, même raison que
        // ci-dessus (éviter de scroller sur une estimation puis rebondir).
        [self.tableView layoutIfNeeded];
        [self s7tv_scrollToBottomIfNeeded:wasNearBottom];
    }
}

- (void)s7tv_scrollToBottomIfNeeded:(BOOL)wasNearBottom {
    NSInteger count = self.displayedMessages.count;
    if (!wasNearBottom || count == 0) return;

    // Ne JAMAIS forcer un scroll pendant que le doigt de la personne est sur
    // l'écran (ou que la table décélère après un swipe) — sinon chaque batch
    // de messages (~150ms sur un flux actif) entre en conflit avec le geste
    // en cours et casse la fluidité du scroll manuel. On retente simplement
    // au prochain reloadMessages une fois le geste terminé.
    if (self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating) {
        return;
    }

    NSIndexPath *last = [NSIndexPath indexPathForRow:count - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last
                           atScrollPosition:UITableViewScrollPositionBottom
                                   animated:NO];
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

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatMessage *msg = self.displayedMessages[indexPath.row];
    return [self s7tv_heightForMessage:msg];
}

// Hauteur exacte mise en cache par messageID — voir rowHeightCache pour le
// raisonnement complet (élimine le rebond causé par l'auto-dimension).
- (CGFloat)s7tv_heightForMessage:(S7TVChatMessage *)msg {
    NSNumber *cached = self.rowHeightCache[msg.messageID];
    if (cached) return cached.doubleValue;

    // Largeur dispo = largeur de la vue moins les marges horizontales de la
    // cellule (8+8, voir S7TVChatCustomCell). Fallback avant le tout premier
    // layout (largeur encore à 0) : une valeur raisonnable plutôt qu'un
    // boundingRect avec largeur 0 qui donnerait une hauteur ~infinie.
    CGFloat availableWidth = self.bounds.size.width - 16;
    if (availableWidth <= 0) availableWidth = 300;

    NSAttributedString *text = [self s7tv_attributedTextForMessage:msg];
    CGRect rect = [text boundingRectWithSize:CGSizeMake(availableWidth, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin |
                                              NSStringDrawingUsesFontLeading
                                      context:nil];
    // +8 = marges verticales de la cellule (4 haut + 4 bas, voir
    // S7TVChatCustomCell). ceil() : jamais couper un pixel de la dernière ligne.
    CGFloat height = ceil(rect.size.height) + 8;
    self.rowHeightCache[msg.messageID] = @(height);
    return height;
}

#pragma mark - Construction du texte

// Twitch n'affiche jamais une couleur de pseudo brute telle que choisie par
// l'utilisateur : son client applique un plancher de luminosité pour rester
// lisible sur fond sombre (certains pseudos ont une couleur proche du noir
// en valeur brute, invisible sur notre fond noir sinon). On reproduit ce
// comportement ici, au moment du RENDU — pas au parsing/stockage — pour que
// S7TVChatMessage garde la vraie couleur choisie par l'utilisateur (utile
// si un thème clair arrive un jour, Phase 6 : le calcul de lisibilité doit
// alors se faire contre un fond clair, pas être figé dans le modèle).
static UIColor *s7tv_readableColorOnDarkBackground(UIColor * _Nullable color) {
    if (!color) return [UIColor whiteColor];

    CGFloat h, s, b, a;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) {
        return [UIColor whiteColor]; // couleur non convertible (espace exotique) → fallback sûr
    }

    // Seuil et plancher choisis empiriquement pour rester proches du rendu
    // natif Twitch (couleurs vives préservées telles quelles, seules les
    // couleurs franchement trop sombres sont relevées).
    static const CGFloat kMinBrightness = 0.50;
    if (b >= kMinBrightness) return color;

    return [UIColor colorWithHue:h saturation:s brightness:kMinBrightness alpha:a];
}

- (NSAttributedString *)s7tv_attributedTextForMessage:(S7TVChatMessage *)msg {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];

    UIFont *usernameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *messageFont  = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
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
