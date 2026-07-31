/*
 * SevenTVChatCustomView.m
 *
 * Voir SevenTVChatCustomView.h pour le contexte (Phase 1c).
 */

#import "SevenTVChatCustomView.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVEmoteImageCache.h"
#import "SevenTVManager.h"


// ============================================================
// MARK: - Cellule (texte + emotes, hauteur dynamique)
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
        _messageLabel.numberOfLines = 0; // Phase 1c : word-wrap standard.
        // lineBreakMode : le défaut UIKit (.byTruncatingTail) tronque avec
        // "…" un mot trop large pour la largeur disponible au lieu de le
        // couper à la ligne suivante (constaté en test réel : "bonj..." sur
        // un message sans espace assez long). .byCharWrapping wrap toujours
        // aux espaces quand c'est possible, et coupe au caractère seulement
        // quand un "mot" dépasse la largeur — voir aussi la paragraph style
        // appliquée dans s7tv_buildAttributedStringForMessage: pour que la
        // hauteur calculée (Phase 1c height cache) corresponde exactement à
        // ce que ce label affiche réellement.
        _messageLabel.lineBreakMode = NSLineBreakByCharWrapping;
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

@interface SevenTVChatCustomView () <UITableViewDelegate>
@property (nonatomic, strong) S7TVChatMessageStore *store;
@property (nonatomic, strong) UITableView *tableView;
// Diffable data source, section unique identifiée par messageID (NSString,
// stable et unique — voir S7TVChatMessage.messageID). Remplace l'ancien
// UITableViewDataSource manuel + comparaison de préfixe "isSimpleAppend" :
// ce dernier ne détectait QUE le cas "ajout pur en fin de liste" et tombait
// systématiquement en reloadData complet dès qu'un message était purgé en
// tête (S7TVChatMessageStore.maxMessageCount) — ce qui arrive en continu sur
// une chaîne active dès que le store est plein. Le diffable data source
// calcule le vrai diff (suppressions en tête + ajouts en fin) quel que soit
// le motif, et surtout sérialise en interne tous les apply(), donc un reload
// d'image en cours de route (voir s7tv_reloadMessageWithID:) ne peut plus
// jamais entrer en collision avec un batch d'insertion en cours — c'était la
// cause du flash/superposition observé sur un chat rapide.
@property (nonatomic, strong) UITableViewDiffableDataSource<NSString *, NSString *> *dataSource;
// Snapshot pris à chaque reload — évite un décalage d'index si le store
// change pendant que la table itère dessus (lecture thread-safe côté store,
// mais la table a besoin d'un tableau stable pendant tout le reload).
@property (nonatomic, strong) NSArray<S7TVChatMessage *> *displayedMessages;
// Index messageID → message, reconstruit à chaque reload en même temps que
// displayedMessages. Utilisé par le cellProvider et par heightForRowAtIndexPath:
// pour retrouver le contenu d'un message à partir de son identifiant — le
// diffable data source ne manipule que des identifiants, jamais les objets
// message directement.
@property (nonatomic, strong) NSDictionary<NSString *, S7TVChatMessage *> *messagesByID;
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
        _messagesByID = @{};
        _rowHeightCache = [NSMutableDictionary dictionary];
        _cachedContentWidth = 0;

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.translatesAutoresizingMaskIntoConstraints = NO;
        _tableView.backgroundColor        = [UIColor clearColor];
        _tableView.separatorStyle         = UITableViewCellSeparatorStyleNone;
        _tableView.delegate               = self;
        // Pas de rowHeight = UITableViewAutomaticDimension : la hauteur
        // exacte de chaque cellule est calculée à l'avance (voir
        // s7tv_heightForMessage:) — élimine le cycle "estimation puis
        // correction" de l'auto-sizing qui causait le rebond.
        //
        // MAIS estimatedRowHeight reste nécessaire : sans lui, UITableView
        // n'a aucune base pour estimer sa taille totale de scroll, et se
        // retrouve à appeler heightForRowAtIndexPath: pour TOUTES les lignes
        // d'un coup, de façon synchrone sur le main thread, dès qu'un gros
        // paquet de messages arrive (typiquement à l'arrivée sur une chaîne
        // active) — c'était la cause du scroll saccadé au join. Avec
        // estimatedRowHeight défini, UIKit s'en sert comme approximation
        // pour le calcul de contentSize et n'appelle notre hauteur exacte
        // que pour les lignes réellement proches de l'écran (lazy). Ce
        // mécanisme est indépendant de l'auto-sizing des cellules : pas de
        // retour du rebond.
        _tableView.estimatedRowHeight = 24;
        // Sans ça, UIKit peut réduire la largeur réelle de contentView de
        // chaque cellule selon la safe area (nonzéro en landscape/théâtre
        // selon la disposition), alors que s7tv_heightForMessage: calcule
        // la hauteur avec `self.bounds.size.width` qui, lui, ignore cette
        // réduction. Constaté en test réel : la hauteur réservée devient
        // légèrement trop courte, et le dernier mot d'une ligne proche du
        // bord se retrouve tronqué sans qu'aucune ligne supplémentaire ne
        // s'affiche pour le contenir (le label ne peut pas grandir au-delà
        // de la hauteur de cellule déjà fixée). Désactiver garantit que la
        // largeur de mesure et la largeur de rendu sont TOUJOURS identiques.
        _tableView.insetsContentViewsToSafeArea = NO;
        // Le clavier/barre de saisie restent 100% natifs Twitch (principe
        // directeur du plan) — cette table n'a donc pas à gérer le clavier.
        [_tableView registerClass:[S7TVChatCustomCell class]
            forCellReuseIdentifier:@"cell"];

        // cellProvider capture faible : le data source vit tant que la vue
        // existe, mais on évite quand même le cycle de rétention implicite
        // (dataSource → block → self → dataSource).
        __weak typeof(self) weakSelf = self;
        _dataSource = [[UITableViewDiffableDataSource alloc]
            initWithTableView:_tableView
                 cellProvider:^UITableViewCell * _Nullable(UITableView * _Nonnull tv,
                                                             NSIndexPath * _Nonnull indexPath,
                                                             NSString * _Nonnull messageID) {
            return [weakSelf s7tv_cellForMessageID:messageID atIndexPath:indexPath];
        }];
        _tableView.dataSource = _dataSource;

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

    NSArray<S7TVChatMessage *> *newMessages = [self.store allMessages];

    // Ne fige "on est en bas" qu'AVANT de toucher au contenu — sinon la
    // comparaison se ferait sur une table déjà mise à jour. Version minimale :
    // la vraie suspension du scroll manuel (bouton "nouveaux messages") est
    // prévue explicitement en Phase 4 ; ce garde-fou évite juste qu'un flux
    // rapide fasse sauter la vue sous les yeux de quelqu'un qui remonte lire
    // l'historique.
    CGFloat distanceFromBottom = self.tableView.contentSize.height
        - (self.tableView.contentOffset.y + self.tableView.bounds.size.height);
    BOOL wasNearBottom = (self.displayedMessages.count == 0) || (distanceFromBottom < 80);

    // Index messageID → message reconstruit à chaque reload : utilisé par le
    // cellProvider et par heightForRowAtIndexPath: (voir propriétés).
    NSMutableDictionary<NSString *, S7TVChatMessage *> *byID =
        [NSMutableDictionary dictionaryWithCapacity:newMessages.count];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:newMessages.count];
    for (S7TVChatMessage *m in newMessages) {
        byID[m.messageID] = m;
        [identifiers addObject:m.messageID];
    }
    self.displayedMessages = newMessages;
    self.messagesByID       = byID;

    // Purge les entrées du cache dont le message n'existe plus dans le store
    // (sinon rowHeightCache grossirait sans limite sur une session longue —
    // un message purgé par maxMessageCount ne revient jamais).
    if (self.rowHeightCache.count > 0) {
        NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
        for (NSString *key in self.rowHeightCache) {
            if (!byID[key]) [staleKeys addObject:key];
        }
        [self.rowHeightCache removeObjectsForKeys:staleKeys];
    }

    // Le diffable data source calcule lui-même le vrai diff (suppressions +
    // insertions, dans n'importe quel ordre) à partir des identifiants — plus
    // besoin de détecter "cas simple = append en fin" à la main : le cas le
    // plus fréquent sur une chaîne active (le plus vieux message est purgé en
    // tête PENDANT qu'un nouveau arrive en queue) est géré nativement, sans
    // jamais retomber sur un reloadData complet de toute la table.
    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot =
        [[NSDiffableDataSourceSnapshot alloc] init];
    [snapshot appendSectionsWithIdentifiers:@[@"main"]];
    [snapshot appendItemsWithIdentifiers:identifiers intoSectionWithIdentifier:@"main"];

    // animatingDifferences:NO — même choix que l'ancien insertRowsAtIndexPaths
    // avec UITableViewRowAnimationNone : pas d'animation d'insertion/suppression
    // individuelle, on ne veut qu'un scroll net une fois le contenu à jour.
    // apply(...) sérialise en interne tous les appels (y compris ceux issus de
    // s7tv_reloadMessageWithID: quand une image finit de charger) — c'est ce
    // qui élimine la collision entre un batch d'insertion et un reload de
    // ligne qui causait le flash/superposition sur un chat rapide.
    __weak typeof(self) weakSelf = self;
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO completion:^{
        [weakSelf s7tv_scrollToBottomIfNeeded:wasNearBottom];
    }];
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

#pragma mark - Cell provider (appelé par le diffable data source, voir initWithStore:)

// Remplace l'ancien tableView:cellForRowAtIndexPath: — même logique, mais le
// message est retrouvé par identifiant (messagesByID) plutôt que par index
// de ligne, puisque le diffable data source ne raisonne qu'en identifiants.
- (UITableViewCell *)s7tv_cellForMessageID:(NSString *)messageID
                                atIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"cell"
                                                                     forIndexPath:indexPath];
    S7TVChatMessage *msg = self.messagesByID[messageID];
    if (!msg) return cell; // filet de sécurité — ne devrait pas arriver, l'identifiant
                            // vient toujours de messagesByID juste avant l'apply du snapshot

    NSMutableArray<id<S7TVResolvedEmote>> *uncachedEmotes = [NSMutableArray array];
    cell.messageLabel.attributedText = [self s7tv_buildAttributedStringForMessage:msg
                                                              collectUncachedEmotes:uncachedEmotes];

    // Les emotes déjà en cache ont été injectées directement par le builder
    // ci-dessus (voir cachedImageForResolvedEmote: dedans) — ici on ne
    // déclenche un chargement async QUE pour celles encore manquantes.
    //
    // IMPORTANT : sur un chat actif avec auto-scroll, les cellules sont
    // recyclées en continu — largement plus vite que le temps d'un aller-
    // retour réseau. Capturer la cellule courante (weak) et vérifier son
    // identité au retour du chargement échouait donc la plupart du temps :
    // le réseau avait bien réussi, mais la cellule qui avait lancé la
    // requête montrait déjà un AUTRE message par le temps que ça revienne,
    // donc on abandonnait l'application de l'image — et rien ne redonnait
    // sa chance à la ligne d'origine (d'où "sortir de vision et remettre"
    // qui "corrige" : ça relance cellForRowAtIndexPath, qui retrouve alors
    // l'image déjà en cache et l'applique directement, sans passer par le
    // chemin async cassé).
    //
    // Le fix : au lieu de suivre une cellule capturée, on retrouve la ligne
    // ACTUELLE du message par son id au moment où l'image arrive, puis on
    // demande à la table view sa cellule EN CE MOMENT à cet indexPath —
    // tableView:cellForRowAtIndexPath: (méthode UIKit, pas notre delegate)
    // retourne nil si la ligne n'est pas à l'écran, ou la bonne cellule
    // sinon. C'est la seule source de vérité fiable pour "qui affiche quoi
    // maintenant" dans une liste qui recycle ses cellules.
    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];
    __weak typeof(self) weakSelf = self;
    for (id<S7TVResolvedEmote> emote in uncachedEmotes) {
        [imageCache imageForResolvedEmote:emote completion:^(UIImage * _Nullable image) {
            if (!image) return; // échec réseau/décodage → le nom reste affiché en fallback
            [weakSelf s7tv_reloadMessageWithID:messageID];
        }];
    }

    return cell;
}

// Une image arrivée est dans le cache : on reconstruit alors la ligne depuis
// les données du message. Ainsi, aucun NSTextAttachment vide ne survit à un
// rebuild de cellule ou à un basculement du chat custom.
//
// Passe par reloadItemsWithIdentifiers: sur une copie du snapshot courant
// plutôt que par reloadRowsAtIndexPaths: direct — l'ancien code capturait un
// indexPath calculé à l'instant du chargement, qui pouvait ne plus être
// valable une fois l'appel réseau terminé (cellules recyclées entre-temps
// sur un chat rapide). Ici, applySnapshot: sérialise cet appel avec tout
// batch d'insertion/suppression en cours (voir reloadMessages) — plus de
// risque de collision entre les deux, quelle que soit la cadence du flux.
- (void)s7tv_reloadMessageWithID:(NSString *)messageID {
    if (!self.messagesByID[messageID]) return; // message plus dans la liste affichée (purgé)

    [self.rowHeightCache removeObjectForKey:messageID];

    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot = [self.dataSource snapshot];
    [snapshot reloadItemsWithIdentifiers:@[messageID]];
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO];
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *messageID = [self.dataSource itemIdentifierForIndexPath:indexPath];
    S7TVChatMessage *msg = messageID ? self.messagesByID[messageID] : nil;
    // Filet de sécurité pendant une transition de snapshot (indexPath pas
    // encore résolu) — ne devrait être qu'une estimation transitoire, jamais
    // la valeur finale affichée pour une ligne.
    if (!msg) return self.tableView.estimatedRowHeight;
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

    // Mesure pure : les tableaux collectés ne sont pas utilisés ici, seule
    // la taille des attachments (déjà fixée par le builder à partir des
    // dimensions du fournisseur, indépendamment de l'image chargée ou non)
    // compte pour boundingRect. C'est exactement ce qui permet de réserver
    // la bonne hauteur dès le premier passage, avant même que l'image ait
    // fini de télécharger (le point qui bloquait le rendu natif Twitch).
    NSMutableArray<id<S7TVResolvedEmote>> *unusedEmotes = [NSMutableArray array];
    NSAttributedString *text = [self s7tv_buildAttributedStringForMessage:msg
                                                      collectUncachedEmotes:unusedEmotes];
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

// Aligne un NSAttributedString sur S7TVChatCustomCell.messageLabel.lineBreakMode
// (.byCharWrapping) — sans ça, boundingRectWithSize: (utilisé pour la hauteur
// de cellule, voir s7tv_heightForMessage:) mesure avec le défaut NSParagraphStyle
// (.byWordWrapping) pendant que le label affiche avec .byCharWrapping : les
// deux peuvent diverger sur un message avec un "mot" trop long, désynchronisant
// la hauteur réservée et le rendu réel. Appelée sur les 3 points de sortie de
// s7tv_buildAttributedStringForMessage:collectUncachedEmotes: (message normal,
// message supprimé, fallback sans tokens) pour rester cohérente dans tous les cas.
static void s7tv_applyLineBreakParagraphStyle(NSMutableAttributedString *attrString) {
    static NSParagraphStyle *style = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableParagraphStyle *mutableStyle = [NSMutableParagraphStyle new];
        mutableStyle.lineBreakMode = NSLineBreakByCharWrapping;
        style = [mutableStyle copy];
    });
    if (attrString.length > 0) {
        [attrString addAttribute:NSParagraphStyleAttributeName
                            value:style
                            range:NSMakeRange(0, attrString.length)];
    }
}

- (NSAttributedString *)s7tv_buildAttributedStringForMessage:(S7TVChatMessage *)msg
                                       collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];

    UIFont *usernameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *messageFont  = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
    UIColor *messageColor  = [UIColor whiteColor];

    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";

    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[displayName stringByAppendingString:@": "]
            attributes:@{NSFontAttributeName: usernameFont,
                         NSForegroundColorAttributeName: usernameColor}]];

    // Placeholder texte de la Phase 5 (déjà anticipé par le modèle de
    // données — state géré ici en attendant l'implémentation complète du
    // tap-to-reveal, qui viendra avec sa propre cellule dédiée en Phase 5).
    if (msg.state == S7TVChatMessageStateDeletedCollapsed) {
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"[message supprimé]"
                attributes:@{NSFontAttributeName: messageFont,
                             NSForegroundColorAttributeName: [UIColor grayColor]}]];
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }

    NSArray<S7TVChatToken *> *tokens = msg.tokens;
    if (!tokens.count) {
        // Fallback Phase 1c : pas de tokens (tokenizer pas encore passé sur
        // ce message, ou aucune emote détectée dedans) → texte brut tel quel.
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:msg.rawText ?: @""
                attributes:@{NSFontAttributeName: messageFont,
                             NSForegroundColorAttributeName: messageColor}]];
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];

    for (S7TVChatToken *token in tokens) {
        if (token.type == S7TVChatTokenTypeEmote7TV || token.type == S7TVChatTokenTypeEmoteTwitch) {
            id<S7TVResolvedEmote> emote = token.resolvedEmote;
            if (!emote) {
                // Ne devrait pas arriver (le tokenizer ne crée un token
                // emote qu'avec une résolution) — filet de sécurité plutôt
                // que planter le rendu.
                [result appendAttributedString:[[NSAttributedString alloc]
                    initWithString:token.text ?: @""
                        attributes:@{NSFontAttributeName: messageFont,
                                     NSForegroundColorAttributeName: messageColor}]];
                continue;
            }

            // Taille réservée à partir des dimensions natives du fournisseur
            // (déjà connues, résolues à la construction du message) — le
            // point qui règle le problème historique du projet : on n'a
            // jamais besoin de corriger après coup une fois l'image chargée.
            CGFloat targetHeight = (token.type == S7TVChatTokenTypeEmote7TV)
                ? cfg.emote7TVSize : cfg.emoteTwitchSize;
            CGFloat ratio = (emote.nativeSize.height > 0)
                ? emote.nativeSize.width / emote.nativeSize.height : 1.0;
            CGFloat targetWidth = targetHeight * ratio;

            UIImage *cachedImage = [imageCache cachedImageForResolvedEmote:emote];
            if (!cachedImage) {
                // NSTextAttachment sans image = glyphe de remplacement UIKit.
                // Le nom est un fallback lisible pendant le chargement; la ligne
                // sera reconstruite lorsque l'image entrera dans le cache.
                [result appendAttributedString:[[NSAttributedString alloc]
                    initWithString:token.text ?: @""
                        attributes:@{NSFontAttributeName: messageFont,
                                     NSForegroundColorAttributeName: messageColor}]];
                [outUncachedEmotes addObject:emote];
                continue;
            }

            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            // Léger décalage vertical pour rapprocher l'emote de la ligne de
            // base du texte plutôt que de son sommet — réglage fin visuel à
            // reprendre en Phase 6 si besoin, pas critique pour l'instant.
            attachment.bounds = CGRectMake(0, -4, targetWidth, targetHeight);
            // Cache hit → image injectée immédiatement, aucun flash vide.
            // Cache miss → bounds déjà corrects, l'espace est réservé ; le
            // chargement async (déclenché côté cellForRowAtIndexPath, pas
            // ici — cette méthode reste pure/sans effet de bord pour rester
            // réutilisable pour la mesure de hauteur) remplira l'image
            // plus tard sans jamais changer la taille de la ligne.
            attachment.image = cachedImage;

            [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            continue;
        }

        // .text, .mention, .url : même style pour l'instant. Le highlight
        // visuel distinct des mentions (fond coloré si c'est nous) et le
        // style tappable des URLs sont prévus explicitement en Phase 6.
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:token.text ?: @""
                attributes:@{NSFontAttributeName: messageFont,
                             NSForegroundColorAttributeName: messageColor}]];
    }

    s7tv_applyLineBreakParagraphStyle(result);
    return result;
}

@end
