/*
 * SevenTVChatCustomView.m
 *
 * Voir SevenTVChatCustomView.h pour le contexte (Phase 1c).
 */

#import "SevenTVChatCustomView.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVEmoteImageCache.h"
#import "SevenTVEmoteAnimationEngine.h"
#import "SevenTVBadgeProvider.h"
#import "SevenTVManager.h"
#import <math.h>


// ============================================================
// MARK: - Cellule (texte + emotes, hauteur dynamique)
// ============================================================

@interface S7TVChatCustomCell : UITableViewCell
@property (nonatomic, strong) UILabel *messageLabel;
// Clés d'animation (emote.imageURL.absoluteString) des emotes animées du
// message actuellement affiché par cette cellule — calculées au moment du
// binding (s7tv_cellForMessageID:), consommées par willDisplayCell/
// didEndDisplayingCell pour (dés)inscrire messageLabel auprès de
// SevenTVEmoteAnimationEngine selon la visibilité réelle à l'écran. nil ou
// vide si le message ne contient aucune emote animée (ou que
// SevenTVManager.showAnimated est désactivé).
@property (nonatomic, strong, nullable) NSSet<NSString *> *animationKeys;
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
        // wrapper (constaté en test réel : "bonj..." sur un message sans
        // espace assez long). .byWordWrapping pousse le mot ENTIER à la
        // ligne suivante quand il ne tient pas, et ne le coupe en plein
        // milieu que si le mot à lui seul dépasse la largeur d'une ligne
        // complète (ex: spam sans espace) — contrairement à .byCharWrapping,
        // testé d'abord, qui coupait des mots normaux ("crème"→"crè"/"me")
        // alors qu'ils tenaient très bien sur la ligne suivante en entier.
        // Voir aussi la paragraph style dans s7tv_buildAttributedStringForMessage:
        // pour que la hauteur calculée corresponde exactement à ce rendu.
        _messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        // Filet de sécurité : même si un futur changement réintroduit un
        // écart de mesure, le texte ne débordera plus jamais visuellement
        // hors de la cellule — il sera coupé net plutôt que de déborder à
        // droite (ce qui reste un bug visible, mais un bug propre plutôt
        // qu'un débordement qui abîme la lisibilité des lignes suivantes).
        _messageLabel.clipsToBounds = YES;
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
// Label de mesure hors-écran, jamais ajouté à une hiérarchie de vues —
// configuré EXACTEMENT comme S7TVChatCustomCell.messageLabel (même
// numberOfLines, même lineBreakMode) pour que s7tv_measureAttributedText:
// fasse tourner le même moteur TextKit que le rendu réel. Voir cette
// méthode pour le raisonnement complet (remplace boundingRectWithSize:,
// qui pouvait diverger du rendu effectif sur certains points de wrap).
@property (nonatomic, strong) UILabel *measuringLabel;
// État persistant "on veut rester en bas" — mis à jour UNIQUEMENT par un
// vrai geste utilisateur (voir scrollViewDidScroll:), jamais recalculé à
// partir d'une simple mesure de distance à chaque message. Contrairement à
// un recalcul systématique, ça résiste à un redimensionnement externe
// passager de la vue (ex: bannière au-dessus du chat) qui fausserait sinon
// la mesure de distance sans qu'aucun geste utilisateur n'ait eu lieu.
@property (nonatomic, assign) BOOL isPinnedToBottom;
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
        _isPinnedToBottom = YES;

        // Config strictement identique à S7TVChatCustomCell.messageLabel —
        // voir s7tv_measureAttributedText: pour pourquoi c'est nécessaire.
        _measuringLabel = [[UILabel alloc] init];
        _measuringLabel.numberOfLines = 0;
        _measuringLabel.lineBreakMode = NSLineBreakByWordWrapping;

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
    BOOL wasNearBottom = (self.displayedMessages.count == 0) || self.isPinnedToBottom;


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
    if (!wasNearBottom || count == 0) {
        return;
    }

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
    NSMutableArray<id<S7TVResolvedEmote>> *animatedEmotes = [NSMutableArray array];
    cell.messageLabel.attributedText = [self s7tv_buildAttributedStringForMessage:msg
                                                              collectUncachedEmotes:uncachedEmotes
                                                              collectAnimatedEmotes:animatedEmotes];

    // Mémorise les clés d'animation de CE message sur la cellule — la vraie
    // inscription/désinscription auprès du moteur partagé se fait dans
    // willDisplayCell/didEndDisplayingCell (visibilité réelle à l'écran, voir
    // plan §Phase 2 "démarrage/arrêt selon visibilité"), pas ici : cette
    // méthode peut être appelée par le diffable data source sans que la
    // cellule soit encore réellement visible.
    if (animatedEmotes.count > 0) {
        NSMutableSet<NSString *> *animationKeys = [NSMutableSet setWithCapacity:animatedEmotes.count];
        SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
        SevenTVEmoteImageCache *imgCache = [SevenTVEmoteImageCache sharedCache];
        for (id<S7TVResolvedEmote> emote in animatedEmotes) {
            NSString *key = emote.imageURL.absoluteString;
            if (!key.length) continue;
            [animationKeys addObject:key];

            if ([engine hasFramesForKey:key]) continue; // déjà décodée, rien à refaire

            // Chemin sync d'abord (frames déjà décodées par une apparition
            // précédente de cette emote, ex: plus haut dans le même chat) —
            // évite un aller-retour async inutile. Sinon décodage complet
            // (réseau + toutes les frames), hors main thread.
            S7TVEmoteAnimatedFrames *cachedFrames = [imgCache cachedFramesForResolvedEmote:emote];
            if (cachedFrames) {
                [engine registerFrames:cachedFrames forKey:key];
            } else {
                [imgCache framesForResolvedEmote:emote
                                       completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
                    if (frames) [engine registerFrames:frames forKey:key];
                    // Pas de reload de message ici : l'attachment animé lit
                    // sa frame dynamiquement à chaque dessin (voir
                    // S7TVAnimatedEmoteAttachment) — l'inscription au moteur
                    // suffit, la cellule (si toujours à l'écran) sera
                    // redessinée automatiquement via son observation.
                }];
            }
        }
        cell.animationKeys = animationKeys;
    } else {
        cell.animationKeys = nil;
    }

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

// UITableViewDelegate hérite de UIScrollViewDelegate — pas besoin d'ajouter
// le protocole séparément à l'@interface.
//
// Ne met à jour isPinnedToBottom QUE quand le scroll vient réellement de
// l'utilisateur (tracking/dragging/decelerating) — sinon notre propre appel
// programmatique à scrollToRowAtIndexPath: (dans s7tv_scrollToBottomIfNeeded:)
// déclencherait aussi scrollViewDidScroll: et fausserait l'état à chaque
// fois qu'on scrolle nous-mêmes. isTracking/isDragging/isDecelerating sont
// tous à NO pendant un scroll programmatique non-animé, ce qui les
// distingue proprement d'un vrai geste.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating) {
        return;
    }
    CGFloat distanceFromBottom = scrollView.contentSize.height
        - (scrollView.contentOffset.y + scrollView.bounds.size.height);
    self.isPinnedToBottom = (distanceFromBottom < 80);
}

// Démarre l'animation UNIQUEMENT quand la cellule devient réellement visible
// (voir plan §Phase 2 "démarrage/arrêt selon visibilité réelle") — pas au
// moment du binding (s7tv_cellForMessageID:), qui peut être appelé sans que
// la cellule soit encore à l'écran.
- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];

    // Repart toujours d'un état propre avant de (ré)inscrire : une cellule
    // recyclée peut arriver ici avec un enregistrement résiduel d'un ANCIEN
    // message si didEndDisplayingCell n'est pas encore passé entre les deux
    // — voir plan "annulation propre au cell reuse".
    [engine removeObserver:s7tvCell.messageLabel];

    if (s7tvCell.animationKeys.count == 0) return;

    __weak UILabel *weakLabel = s7tvCell.messageLabel;
    [engine addObserver:s7tvCell.messageLabel
                   keys:s7tvCell.animationKeys
                 redraw:^{
        // setNeedsDisplay (pas setNeedsLayout) : seul le dessin doit se
        // refaire — TextKit ré-interroge alors l'attachment animé pour sa
        // frame courante (voir S7TVAnimatedEmoteAttachment), la mise en page
        // et la hauteur de ligne, elles, ne changent jamais.
        [weakLabel setNeedsDisplay];
    }];
}

// Coupe l'animation dès que la cellule sort réellement de l'écran — avant
// même qu'elle soit recyclée pour une autre ligne. Sans ce hook, une
// cellule qui reste inutilisée dans le pool de réutilisation continuerait
// de recevoir des ticks pour rien (voir plan "annulation propre au cell
// reuse" + "démarrage/arrêt selon visibilité").
- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:s7tvCell.messageLabel];
}

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

// Mesure via un vrai UILabel plutôt que boundingRectWithSize: — constaté en
// test réel : boundingRectWithSize: peut diverger du rendu effectif d'un
// UILabel sur certains points de wrap (un mot à cheval sur la limite de
// largeur débordait à droite au lieu de sauter à la ligne, alors que la
// hauteur calculée pour un autre mot juste à côté était correcte). En
// passant par sizeThatFits: sur un label configuré IDENTIQUEMENT à celui
// réellement affiché (measuringLabel — même numberOfLines, même
// lineBreakMode), on fait tourner exactement le même moteur TextKit pour la
// mesure et pour le rendu : les deux ne peuvent plus diverger, par
// construction, plutôt qu'en espérant que deux chemins de calcul séparés
// donnent toujours le même résultat.
- (CGSize)s7tv_measureAttributedText:(NSAttributedString *)text width:(CGFloat)width {
    self.measuringLabel.attributedText = text;
    CGSize fit = [self.measuringLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.measuringLabel.attributedText = nil; // libère la référence, pas besoin de la garder
    return fit;
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
    // compte pour la mesure. C'est exactement ce qui permet de réserver
    // la bonne hauteur dès le premier passage, avant même que l'image ait
    // fini de télécharger (le point qui bloquait le rendu natif Twitch).
    NSMutableArray<id<S7TVResolvedEmote>> *unusedEmotes = [NSMutableArray array];
    NSAttributedString *text = [self s7tv_buildAttributedStringForMessage:msg
                                                      collectUncachedEmotes:unusedEmotes
                                                      collectAnimatedEmotes:nil];
    // Mesure via un vrai UILabel plutôt que boundingRectWithSize: — constaté
    // en test réel : boundingRectWithSize: peut diverger du rendu effectif
    // du label sur certains points de wrap (un mot à cheval sur la limite
    // débordait à droite au lieu de sauter à la ligne, alors que la hauteur
    // calculée était correcte pour un autre point de wrap juste à côté).
    // sizeThatFits: fait tourner EXACTEMENT le même moteur TextKit que celui
    // utilisé pour l'affichage réel (S7TVChatCustomCell.messageLabel a la
    // même config : numberOfLines=0, lineBreakMode=.byWordWrapping) — donc
    // mesure et rendu ne peuvent plus jamais diverger, par construction.
    CGSize fitSize = [self s7tv_measureAttributedText:text width:availableWidth];
    CGRect rect = CGRectMake(0, 0, fitSize.width, fitSize.height);
    // +8 = marges verticales de la cellule (4 haut + 4 bas, voir
    // S7TVChatCustomCell). ceil() : jamais couper un pixel de la dernière ligne.
    CGFloat height = ceil(rect.size.height) + 8;
    self.rowHeightCache[msg.messageID] = @(height);
    return height;
}

#pragma mark - Construction du texte

// Twitch n'affiche jamais une couleur de pseudo brute telle que choisie par
// l'utilisateur quand l'option "Couleurs lisibles" est activée (Chat Settings
// → Apparence) : Twitch calcule un ratio de contraste WCAG 2.1 (minimum
// 4.5:1, seuil texte normal) contre le fond du chat, et ajuste UNIQUEMENT la
// luminosité (HSL) par recherche binaire jusqu'à atteindre ce ratio — teinte
// et saturation d'origine préservées. Source : blog.twitch.tv "Using
// Algorithms to Meet Accessibility Requirements for Color Contrast" (nov.
// 2021). Reproduit ici au moment du RENDU — pas au parsing/stockage — pour
// que S7TVChatMessage garde la vraie couleur choisie par l'utilisateur (utile
// si un thème clair arrive un jour, Phase 6 : le calcul de contraste doit
// alors se faire contre un fond clair, pas être figé dans le modèle).

// Luminance relative WCAG (sRGB → linéaire → pondération perceptuelle).
static CGFloat s7tv_relativeLuminance(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat (^chan)(CGFloat) = ^CGFloat(CGFloat c) {
        return (c <= 0.03928) ? (c / 12.92) : (CGFloat)pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b);
}

// UIColor n'expose que HSB (Brightness) nativement, pas HSL (Lightness) —
// or c'est bien la Lightness que Twitch ajuste (formule L = (max+min)/2,
// différente de B = max). Conversion manuelle nécessaire.
static void s7tv_rgbToHSL(CGFloat r, CGFloat g, CGFloat b, CGFloat *h, CGFloat *s, CGFloat *l) {
    CGFloat maxC = MAX(r, MAX(g, b));
    CGFloat minC = MIN(r, MIN(g, b));
    CGFloat delta = maxC - minC;
    *l = (maxC + minC) / 2.0;
    if (delta < 1e-6) { *h = 0; *s = 0; return; }
    *s = (*l < 0.5) ? (delta / (maxC + minC)) : (delta / (2.0 - maxC - minC));
    if (maxC == r)      *h = fmod((g - b) / delta, 6.0);
    else if (maxC == g) *h = ((b - r) / delta) + 2.0;
    else                 *h = ((r - g) / delta) + 4.0;
    *h *= 60.0;
    if (*h < 0) *h += 360.0;
}

static CGFloat s7tv_hueToRGB(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0) t += 1.0;
    if (t > 1) t -= 1.0;
    if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0/2.0) return q;
    if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
    return p;
}

static void s7tv_hslToRGB(CGFloat h, CGFloat s, CGFloat l, CGFloat *r, CGFloat *g, CGFloat *b) {
    if (s < 1e-6) { *r = *g = *b = l; return; }
    CGFloat q = (l < 0.5) ? (l * (1.0 + s)) : (l + s - l * s);
    CGFloat p = 2.0 * l - q;
    CGFloat hk = h / 360.0;
    *r = s7tv_hueToRGB(p, q, hk + 1.0/3.0);
    *g = s7tv_hueToRGB(p, q, hk);
    *b = s7tv_hueToRGB(p, q, hk - 1.0/3.0);
}

static UIColor *s7tv_readableColorOnDarkBackground(UIColor * _Nullable color) {
    if (!color) return [UIColor whiteColor];

    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        return [UIColor whiteColor]; // couleur non convertible (espace exotique) → fallback sûr
    }

    // Fond de référence : chat Twitch en thème sombre (#18181B), pas un noir
    // pur — le ratio WCAG dépend de la luminance réelle du fond contre lequel
    // le texte est lu.
    static const CGFloat kBgLuminance      = 0.009281; // luminance relative de #18181B
    static const CGFloat kMinContrastRatio = 4.5;       // WCAG 2.1 AA, texte normal
    CGFloat targetLuminance = kMinContrastRatio * (kBgLuminance + 0.05) - 0.05;

    if (s7tv_relativeLuminance(r, g, b) >= targetLuminance) return color; // déjà lisible, on ne touche à rien

    CGFloat h, s, l;
    s7tv_rgbToHSL(r, g, b, &h, &s, &l);
    CGFloat originalL = l;

    // Recherche binaire sur la Lightness (teinte + saturation ORIGINALE
    // pendant la recherche — la désaturation est appliquée séparément
    // ensuite, sinon la cible de luminance bougerait à chaque itération).
    CGFloat lo = l, hi = 1.0;
    CGFloat bestL = l;
    for (int i = 0; i < 20; i++) {
        CGFloat mid = (lo + hi) / 2.0;
        CGFloat cr, cg, cb;
        s7tv_hslToRGB(h, s, mid, &cr, &cg, &cb);
        if (s7tv_relativeLuminance(cr, cg, cb) >= targetLuminance) {
            bestL = mid;
            hi = mid;
        } else {
            lo = mid;
        }
    }

    // Courbe de désaturation (documentée par l'équipe Twitch : "quand on
    // éclaircit une couleur très sombre, le résultat semblait trop saturé —
    // on a ajouté une courbe qui réduit la saturation"). Plus la Lightness a
    // dû bouger pour atteindre le contraste cible, plus on désature — un
    // ajustement léger reste presque inchangé, un ajustement extrême tend
    // vers une couleur pâle plutôt qu'un ton "néon" trop vif.
    CGFloat deltaL = bestL - originalL;
    CGFloat easingFactor = 1.0 - MIN(deltaL * 0.8, 0.8); // borné à [0.2, 1.0]
    CGFloat desaturatedS = s * easingFactor;

    CGFloat bestR, bestG, bestB;
    s7tv_hslToRGB(h, desaturatedS, bestL, &bestR, &bestG, &bestB);

    return [UIColor colorWithRed:bestR green:bestG blue:bestB alpha:a];
}

// Aligne un NSAttributedString sur S7TVChatCustomCell.messageLabel.lineBreakMode
// (.byWordWrapping) — sans ça, boundingRectWithSize: (utilisé pour la hauteur
// de cellule, voir s7tv_heightForMessage:) mesure avec un paragraph style qui
// peut diverger de celui du label affiché, désynchronisant la hauteur
// réservée et le rendu réel. Appelée sur les 3 points de sortie de
// s7tv_buildAttributedStringForMessage:collectUncachedEmotes: (message normal,
// message supprimé, fallback sans tokens) pour rester cohérente dans tous les cas.
static void s7tv_applyLineBreakParagraphStyle(NSMutableAttributedString *attrString) {
    static NSParagraphStyle *style = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableParagraphStyle *mutableStyle = [NSMutableParagraphStyle new];
        mutableStyle.lineBreakMode = NSLineBreakByWordWrapping;
        style = [mutableStyle copy];
    });
    if (attrString.length > 0) {
        [attrString addAttribute:NSParagraphStyleAttributeName
                            value:style
                            range:NSMakeRange(0, attrString.length)];
    }
}

// collectAnimatedEmotes : optionnel (peut être nil, ex: passe de mesure de
// hauteur qui n'a pas besoin d'inscrire quoi que ce soit auprès du moteur
// d'animation) — reçoit toute emote animée effectivement utilisée dans le
// message (sous réserve que SevenTVManager.showAnimated soit actif), pour
// que l'appelant sache quelles clés inscrire/décoder (voir
// s7tv_cellForMessageID:).
- (NSAttributedString *)s7tv_buildAttributedStringForMessage:(S7TVChatMessage *)msg
                                       collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes
                                       collectAnimatedEmotes:(nullable NSMutableArray<id<S7TVResolvedEmote>> *)outAnimatedEmotes {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];

    UIFont *usernameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *messageFont  = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
    UIColor *messageColor  = [UIColor whiteColor];

    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];

    // Badges (Phase 3) — avant le pseudo, comme le natif Twitch. Même
    // pipeline attachment que les emotes ci-dessous (S7TVResolvedBadge
    // conforme à S7TVResolvedEmote) : un badge encore non téléchargé rejoint
    // outUncachedEmotes et déclenche le même reload générique que pour une
    // emote manquante, sans code dédié — voir s7tv_cellForMessageID:.
    // Toujours rendus (y compris message .deletedCollapsed) : même logique
    // que le pseudo juste en dessous, qui reste affiché dans ce cas.
    SevenTVBadgeProvider *badgeProvider = [SevenTVBadgeProvider sharedProvider];
    for (NSString *badgeIdentifier in msg.badgeIdentifiers) {
        id<S7TVResolvedEmote> badge = [badgeProvider resolvedBadgeForIdentifier:badgeIdentifier];
        if (!badge) continue; // catalogue pas encore chargé, ou set/version inconnu — on saute, pas de glyphe vide

        UIImage *cachedBadgeImage = [imageCache cachedImageForResolvedEmote:badge];
        if (!cachedBadgeImage) {
            [outUncachedEmotes addObject:badge];
            continue; // pas d'image dispo → rien à afficher pour ce badge tant que le fetch n'a pas fini
        }

        NSTextAttachment *badgeAttachment = [[NSTextAttachment alloc] init];
        badgeAttachment.image = cachedBadgeImage;
        // Badges carrés (nativeSize (1,1), voir SevenTVBadgeProvider) →
        // largeur == hauteur == cfg.badgeSize, pas de calcul de ratio requis
        // contrairement aux emotes (dimensions variables).
        badgeAttachment.bounds = CGRectMake(0, -3, cfg.badgeSize, cfg.badgeSize);
        [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:badgeAttachment]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }

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

            // Animées (Phase 2 — décodage WebP animé) : seulement si le
            // toggle global showAnimated est actif (voir SevenTVManager) —
            // sinon on reste volontairement sur le chemin statique existant
            // (1ère frame figée), pour économiser tout le pipeline de
            // décodage/animation quand la personne ne veut pas d'animation.
            BOOL wantsAnimation = emote.isAnimated && [SevenTVManager sharedManager].showAnimated;

            NSTextAttachment *attachment;
            if (wantsAnimation) {
                S7TVAnimatedEmoteAttachment *animatedAttachment = [S7TVAnimatedEmoteAttachment new];
                animatedAttachment.animationKey = emote.imageURL.absoluteString;
                // Tant que le moteur n'a pas encore la 1ère frame animée
                // décodée, on montre l'image statique déjà en cache — jamais
                // de glyphe de remplacement une fois qu'on a déjà une image.
                animatedAttachment.staticFallbackImage = cachedImage;
                attachment = animatedAttachment;
                if (outAnimatedEmotes) [outAnimatedEmotes addObject:emote];
            } else {
                attachment = [[NSTextAttachment alloc] init];
                // Cache hit → image injectée immédiatement, aucun flash vide.
                attachment.image = cachedImage;
            }
            // Léger décalage vertical pour rapprocher l'emote de la ligne de
            // base du texte plutôt que de son sommet — réglage fin visuel à
            // reprendre en Phase 6 si besoin, pas critique pour l'instant.
            // Bounds identiques dans les deux cas : la taille réservée ne
            // dépend que des dimensions natives du fournisseur, jamais de
            // l'image (statique ou frame animée) effectivement affichée —
            // aucun risque de resize au fil de l'animation.
            attachment.bounds = CGRectMake(0, -4, targetWidth, targetHeight);

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
