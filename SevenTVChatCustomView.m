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
#import "7tv-localization.h"
#import "SevenTVManager.h"
#import <math.h>


// ============================================================
// MARK: - Cellule (texte + emotes, hauteur dynamique)
// ============================================================

@interface S7TVChatCustomCell : UITableViewCell
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong, nullable) NSSet<NSString *> *animationKeys;
// Phase 3 — bandeau d'accent (barre colorée + icône + fond teinté) pour les
// messages système (sub/resub/gift). Invisible par défaut, activé par
// s7tv_configureSystemAccentWithColor:iconName:.
@property (nonatomic, strong) UIView *systemAccentBar;
@property (nonatomic, strong) UIImageView *systemIconView;
@property (nonatomic, strong) NSLayoutConstraint *messageLabelLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *messageLabelBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *systemAccentBarWidthConstraint;
@end

@implementation S7TVChatCustomCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(nullable NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        _messageLabel = [[UILabel alloc] init];
        _messageLabel.numberOfLines = 0;
        _messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _messageLabel.clipsToBounds = YES;
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _messageLabel.userInteractionEnabled = YES;
        [_messageLabel addGestureRecognizer:
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(s7tv_handleTap:)]];
        [self.contentView addSubview:_messageLabel];

        _systemAccentBar = [[UIView alloc] init];
        _systemAccentBar.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_systemAccentBar];

        _systemIconView = [[UIImageView alloc] init];
        _systemIconView.translatesAutoresizingMaskIntoConstraints = NO;
        _systemIconView.contentMode = UIViewContentModeScaleAspectFit;
        _systemIconView.hidden = YES;
        [self.contentView addSubview:_systemIconView];

        _systemAccentBarWidthConstraint =
            [_systemAccentBar.widthAnchor constraintEqualToConstant:0];
        _messageLabelLeadingConstraint =
            [_messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8];
        // -4 par défaut ; le constant réel est recalculé dans
        // s7tv_configureCell:forMessage:attributedText: en fonction de
        // cfg.lineSpacing (espacement ENTRE deux messages, voir
        // SevenTVChatAppearanceConfig.h) à chaque configuration de cellule —
        // avec les self-sizing cells, c'est ici (et non plus dans un calcul
        // de hauteur externe supprimé) que cet espacement doit être ajouté,
        // puisqu'il contribue directement à la hauteur intrinsèque de la
        // cellule que UIKit va lire.
        _messageLabelBottomConstraint =
            [_messageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4];

        [NSLayoutConstraint activateConstraints:@[
            [_systemAccentBar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_systemAccentBar.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_systemAccentBar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            _systemAccentBarWidthConstraint,

            [_systemIconView.leadingAnchor constraintEqualToAnchor:_systemAccentBar.trailingAnchor constant:8],
            [_systemIconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_systemIconView.widthAnchor constraintEqualToConstant:14],
            [_systemIconView.heightAnchor constraintEqualToConstant:14],

            _messageLabelLeadingConstraint,
            [_messageLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            _messageLabelBottomConstraint,
            [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        ]];
    }
    return self;
}

// Couleurs/icônes approximatives (barre + icône + fond teinté à 12%), pas
// mesurées pixel-perfect sur le rendu natif — TODO mesure réelle si besoin
// (même convention que SevenTVChatAppearanceConfig). accentColor nil =
// message normal (tout redevient invisible/transparent).
// backgroundEnabled : contrôle UNIQUEMENT le fond (12% teinté vs neutre).
// La barre d'accent (gauche) et l'icône restent toujours affichées/colorées
// quand isSystem — voir SevenTVChatAppearanceConfig.systemMessageBackgroundsEnabled.
// Fond OFF (comme PC) : le fond du chat de base (self.tableView) est
// clearColor — transparent, hérite du fond natif Twitch derrière. Sur PC,
// désactiver les fonds colorés ne rend PAS le message totalement
// transparent : il garde un fond neutre légèrement plus clair que le fond du
// chat pour rester visuellement distinct de la liste. Overlay blanc à faible
// alpha plutôt qu'une couleur fixe : "plus clair que le fond de base" reste
// vrai quel que soit le thème/la couleur réelle du fond natif Twitch
// derrière (transparent ici, donc pas mesurable en dur).
- (void)s7tv_configureSystemAccentWithColor:(nullable UIColor *)accentColor
                                    iconName:(nullable NSString *)iconName
                           backgroundEnabled:(BOOL)backgroundEnabled {
    BOOL isSystem = (accentColor != nil);
    self.systemAccentBar.backgroundColor = accentColor ?: [UIColor clearColor];
    self.systemAccentBarWidthConstraint.constant = isSystem ? 3.0 : 0.0;
    self.systemIconView.hidden = !isSystem;
    self.systemIconView.tintColor = accentColor;
    self.systemIconView.image = iconName ? [UIImage systemImageNamed:iconName] : nil;
    self.messageLabelLeadingConstraint.constant = isSystem ? 31.0 : 8.0;
    if (!isSystem) {
        self.contentView.backgroundColor = [UIColor clearColor];
    } else if (backgroundEnabled) {
        self.contentView.backgroundColor = [accentColor colorWithAlphaComponent:0.12];
    } else {
        self.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    }
}

- (void)s7tv_handleTap:(UITapGestureRecognizer *)gesture {
    NSAttributedString *attributedText = self.messageLabel.attributedText;
    if (!attributedText.length) return;

    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:attributedText];
    [textStorage addLayoutManager:layoutManager];

    NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:self.messageLabel.bounds.size];
    textContainer.lineFragmentPadding = 0;
    textContainer.lineBreakMode = self.messageLabel.lineBreakMode;
    textContainer.maximumNumberOfLines = self.messageLabel.numberOfLines;
    [layoutManager addTextContainer:textContainer];

    CGPoint tapPoint = [gesture locationInView:self.messageLabel];
    NSUInteger charIndex = [layoutManager characterIndexForPoint:tapPoint
                                                   inTextContainer:textContainer
                          fractionOfDistanceBetweenInsertionPoints:NULL];
    if (charIndex >= attributedText.length) return;

    id linkValue = [attributedText attribute:NSLinkAttributeName atIndex:charIndex effectiveRange:NULL];
    NSURL *url = [linkValue isKindOfClass:[NSURL class]] ? linkValue : nil;
    if (!url && [linkValue isKindOfClass:[NSString class]]) url = [NSURL URLWithString:linkValue];
    if (!url) return;

    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end


// ============================================================
// MARK: - SevenTVChatCustomView
// ============================================================

@interface SevenTVChatCustomView () <UITableViewDelegate>
@property (nonatomic, strong) S7TVChatMessageStore *store;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITableViewDiffableDataSource<NSString *, NSString *> *dataSource;
@property (nonatomic, strong) NSArray<S7TVChatMessage *> *displayedMessages;
@property (nonatomic, strong) NSDictionary<NSString *, S7TVChatMessage *> *messagesByID;
@property (nonatomic, assign) CGFloat cachedContentWidth;
@property (nonatomic, assign) BOOL isPinnedToBottom;
@property (nonatomic, assign) NSUInteger pendingNewMessagesCount;
@property (nonatomic, strong) UIView *unseenMessagesBanner;
@property (nonatomic, strong) UILabel *unseenMessagesBannerLabel;
@end

@implementation SevenTVChatCustomView

- (instancetype)initWithStore:(S7TVChatMessageStore *)store {
    self = [super init];
    if (self) {
        _store = store;
        _displayedMessages = @[];
        _messagesByID = @{};
        _cachedContentWidth = 0;
        _isPinnedToBottom = YES;

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.translatesAutoresizingMaskIntoConstraints = NO;
        _tableView.backgroundColor        = [UIColor clearColor];
        _tableView.separatorStyle         = UITableViewCellSeparatorStyleNone;
        _tableView.delegate               = self;
        // Self-sizing cells natives plutôt qu'un calcul de hauteur maison.
        // Deux techniques de prédiction externe (NSLayoutManager manuel,
        // puis cellule prototype + systemLayoutSizeFittingSize:) ont chacune
        // divergé du rendu réel en production (voir logs — notamment
        // systemLayoutSizeFittingSize: qui ne reflétait pas fidèlement le
        // layout d'une cellule réellement attachée à une fenêtre, un
        // comportement documenté comme peu fiable sur du contenu Auto
        // Layout complexe). En laissant UITableView calculer lui-même la
        // hauteur à partir de la VRAIE cellule affichée (via ses contraintes
        // Auto Layout, déjà en place dans S7TVChatCustomCell — label pinné
        // top/bottom/leading/trailing), il n'existe plus de calcul externe
        // pouvant diverger : plus aucune classe de bug possible ici.
        _tableView.rowHeight = UITableViewAutomaticDimension;
        _tableView.estimatedRowHeight = 24;
        [_tableView registerClass:[S7TVChatCustomCell class]
            forCellReuseIdentifier:@"cell"];

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

        _unseenMessagesBanner = [[UIView alloc] init];
        _unseenMessagesBanner.translatesAutoresizingMaskIntoConstraints = NO;
        _unseenMessagesBanner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        _unseenMessagesBanner.layer.cornerRadius = 18;
        _unseenMessagesBanner.layer.borderWidth = 1.0;
        _unseenMessagesBanner.layer.borderColor =
            [UIColor colorWithRed:0.569 green:0.278 blue:1.0 alpha:1.0].CGColor;
        _unseenMessagesBanner.clipsToBounds = YES;
        _unseenMessagesBanner.hidden = YES;
        _unseenMessagesBanner.userInteractionEnabled = YES;
        [_unseenMessagesBanner addGestureRecognizer:
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(s7tv_didTapNewMessagesBanner)]];

        UIImageView *arrowIcon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"arrow.down"]];
        arrowIcon.tintColor = [UIColor whiteColor];
        arrowIcon.contentMode = UIViewContentModeScaleAspectFit;
        arrowIcon.translatesAutoresizingMaskIntoConstraints = NO;

        _unseenMessagesBannerLabel = [[UILabel alloc] init];
        _unseenMessagesBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _unseenMessagesBannerLabel.textColor = [UIColor whiteColor];
        _unseenMessagesBannerLabel.font = [UIFont boldSystemFontOfSize:13];
        _unseenMessagesBannerLabel.textAlignment = NSTextAlignmentCenter;

        [_unseenMessagesBanner addSubview:arrowIcon];
        [_unseenMessagesBanner addSubview:_unseenMessagesBannerLabel];
        [self addSubview:_unseenMessagesBanner];

        [NSLayoutConstraint activateConstraints:@[
            [_unseenMessagesBanner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_unseenMessagesBanner.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
            [_unseenMessagesBanner.heightAnchor constraintEqualToConstant:36],
            [_unseenMessagesBanner.widthAnchor constraintEqualToConstant:230],
            [arrowIcon.leadingAnchor constraintEqualToAnchor:_unseenMessagesBanner.leadingAnchor constant:12],
            [arrowIcon.centerYAnchor constraintEqualToAnchor:_unseenMessagesBanner.centerYAnchor],
            [arrowIcon.widthAnchor constraintEqualToConstant:14],
            [arrowIcon.heightAnchor constraintEqualToConstant:14],
            [_unseenMessagesBannerLabel.centerXAnchor constraintEqualToAnchor:_unseenMessagesBanner.centerXAnchor],
            [_unseenMessagesBannerLabel.centerYAnchor constraintEqualToAnchor:_unseenMessagesBanner.centerYAnchor],
            [_unseenMessagesBannerLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:arrowIcon.trailingAnchor constant:6],
            [_unseenMessagesBannerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_unseenMessagesBanner.trailingAnchor constant:-12],
        ]];

        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(s7tv_handleDeviceOrientationChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UIDeviceOrientationDidChangeNotification object:nil];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // s7tv_actualVisibleWidth plutôt que self.bounds.size.width seul : un
    // ancêtre peut recadrer visuellement cette vue (voir commentaire de
    // s7tv_actualVisibleWidth) sans que self.bounds ne change. Avec les
    // self-sizing cells (UITableViewAutomaticDimension), UITableView met en
    // cache la hauteur calculée par Auto Layout pour chaque ligne — un
    // reloadData force le recalcul quand la largeur réellement visible
    // change, même si self.bounds n'a pas bougé.
    CGFloat visibleWidth = [self s7tv_actualVisibleWidth];
    if (visibleWidth > 0 && visibleWidth != self.cachedContentWidth) {
        self.cachedContentWidth = visibleWidth;
        [self.tableView reloadData];
    }
}

// Filet de sécurité : si un ancêtre change la largeur visuellement visible
// sans jamais déclencher self.layoutSubviews (ex. transform appliqué par
// Twitch sur un conteneur parent lors d'un passage paysage/théâtre, qui ne
// propage pas nécessairement d'invalidation de layout jusqu'à cette vue),
// on revérifie explicitement après chaque rotation, avec un court délai
// pour laisser l'animation de rotation/repositionnement Twitch se stabiliser.
- (void)s7tv_handleDeviceOrientationChange:(NSNotification *)note {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf setNeedsLayout];
        [weakSelf layoutIfNeeded];
    });
}

- (void)reloadMessages {
    NSAssert([NSThread isMainThread],
             @"reloadMessages doit être appelé depuis le main thread (touche UIKit)");

    NSArray<S7TVChatMessage *> *newMessages = [self.store allMessages];

    BOOL wasNearBottom = (self.displayedMessages.count == 0) || self.isPinnedToBottom;

    NSMutableSet<NSString *> *oldIDs = nil;
    if (!wasNearBottom) {
        oldIDs = [NSMutableSet setWithCapacity:self.displayedMessages.count];
        for (S7TVChatMessage *m in self.displayedMessages) {
            [oldIDs addObject:m.messageID];
        }
    }

    NSMutableDictionary<NSString *, S7TVChatMessage *> *byID =
        [NSMutableDictionary dictionaryWithCapacity:newMessages.count];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:newMessages.count];
    NSUInteger newlyAddedCount = 0;
    for (S7TVChatMessage *m in newMessages) {
        byID[m.messageID] = m;
        [identifiers addObject:m.messageID];
        if (oldIDs && ![oldIDs containsObject:m.messageID]) newlyAddedCount++;
    }
    self.displayedMessages = newMessages;
    self.messagesByID       = byID;

    if (wasNearBottom) {
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];
    } else {
        if (newlyAddedCount > 0) self.pendingNewMessagesCount += newlyAddedCount;
        [self s7tv_updateNewMessagesBannerText];
        [self s7tv_showNewMessagesBanner];
    }

    // Invalidation complète via reloadItemsWithIdentifiers (voir plus bas) :
    // nécessaire car reloadMessages est aussi le point d'entrée du
    // rafraîchissement live sur changement de SevenTVChatAppearanceConfig
    // (taille de police, espacement...) — sans ça, un message dont le
    // contenu texte n'a pas changé ne serait pas reconfiguré, et les
    // self-sizing cells ne recalculeraient pas leur hauteur pour refléter
    // le nouveau réglage.

    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot =
        [[NSDiffableDataSourceSnapshot alloc] init];
    [snapshot appendSectionsWithIdentifiers:@[@"main"]];
    [snapshot appendItemsWithIdentifiers:identifiers intoSectionWithIdentifier:@"main"];
    // Sans ça, un reloadMessages où le set d'IDs ne change pas (cas du faux
    // chat statique du panneau Tailles, ou plus généralement un changement
    // de SevenTVChatAppearanceConfig sans nouveau message) produit un diff
    // vide : la snapshot est "identique" du point de vue du diffable data
    // source et aucune cell n'est reconfigurée.
    [snapshot reloadItemsWithIdentifiers:identifiers];

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
    if (self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating) {
        return;
    }
    NSIndexPath *last = [NSIndexPath indexPathForRow:count - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last
                           atScrollPosition:UITableViewScrollPositionBottom
                                   animated:NO];
}

#pragma mark - Cell provider

// Config partagée : évite toute divergence entre ce que fait
// s7tv_cellForMessageID: (cellule réellement affichée) et une éventuelle
// autre logique de configuration (leadingInset notamment, qui influe
// directement sur la largeur disponible pour le texte).
- (void)s7tv_configureCell:(S7TVChatCustomCell *)cell
                 forMessage:(S7TVChatMessage *)msg
             attributedText:(NSAttributedString *)text {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    if (msg.type == S7TVChatMessageTypeSystem && msg.systemInfo) {
        UIColor *accentColor; NSString *iconName;
        switch (msg.systemInfo.kind) {
            case S7TVSystemMessageKindCommunityGift:
                accentColor = cfg.giftAccentColor;
                iconName = @"gift.fill";
                break;
            case S7TVSystemMessageKindSubOrResub:
            default:
                if (msg.systemInfo.isPrime) {
                    accentColor = cfg.primeAccentColor;
                    iconName = @"crown.fill";
                } else {
                    accentColor = cfg.subResubAccentColor;
                    iconName = @"star.fill";
                }
                break;
        }
        [cell s7tv_configureSystemAccentWithColor:accentColor iconName:iconName
                                 backgroundEnabled:cfg.systemMessageBackgroundsEnabled];
    } else {
        [cell s7tv_configureSystemAccentWithColor:nil iconName:nil backgroundEnabled:NO];
    }
    cell.messageLabel.attributedText = text;
    // cfg.lineSpacing = espacement ENTRE deux messages (voir
    // SevenTVChatAppearanceConfig.h). Avec les self-sizing cells, il n'y a
    // plus de calcul de hauteur externe où l'ajouter (voir
    // tableView.rowHeight = UITableViewAutomaticDimension) — c'est donc ici,
    // en l'ajoutant au constant de la contrainte de bas de label, qu'il doit
    // être appliqué, puisque cette contrainte contribue directement à la
    // hauteur intrinsèque que UIKit va lire pour dimensionner la cellule.
    cell.messageLabelBottomConstraint.constant = -(4 + cfg.lineSpacing);
}

- (UITableViewCell *)s7tv_cellForMessageID:(NSString *)messageID
                                atIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"cell"
                                                                     forIndexPath:indexPath];
    S7TVChatMessage *msg = self.messagesByID[messageID];
    if (!msg) return cell;

    NSMutableArray<id<S7TVResolvedEmote>> *uncachedEmotes = [NSMutableArray array];
    NSMutableArray<id<S7TVResolvedEmote>> *animatedEmotes = [NSMutableArray array];
    NSAttributedString *text = [self s7tv_buildAttributedStringForMessage:msg
                                                      collectUncachedEmotes:uncachedEmotes
                                                      collectAnimatedEmotes:animatedEmotes];
    [self s7tv_configureCell:cell forMessage:msg attributedText:text];

    if (animatedEmotes.count > 0) {
        NSMutableSet<NSString *> *animationKeys = [NSMutableSet setWithCapacity:animatedEmotes.count];
        SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
        SevenTVEmoteImageCache *imgCache = [SevenTVEmoteImageCache sharedCache];
        for (id<S7TVResolvedEmote> emote in animatedEmotes) {
            NSString *key = emote.imageURL.absoluteString;
            if (!key.length) continue;
            [animationKeys addObject:key];
            if ([engine hasFramesForKey:key]) continue;
            S7TVEmoteAnimatedFrames *cachedFrames = [imgCache cachedFramesForResolvedEmote:emote];
            if (cachedFrames) {
                [engine registerFrames:cachedFrames forKey:key];
            } else {
                [imgCache framesForResolvedEmote:emote
                                       completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
                    if (frames) [engine registerFrames:frames forKey:key];
                }];
            }
        }
        cell.animationKeys = animationKeys;
    } else {
        cell.animationKeys = nil;
    }

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];
    __weak typeof(self) weakSelf = self;
    for (id<S7TVResolvedEmote> emote in uncachedEmotes) {
        [imageCache imageForResolvedEmote:emote completion:^(UIImage * _Nullable image) {
            if (!image) return;
            [weakSelf s7tv_reloadMessageWithID:messageID];
        }];
    }

    return cell;
}

- (void)s7tv_reloadMessageWithID:(NSString *)messageID {
    if (!self.messagesByID[messageID]) return;
    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot = [self.dataSource snapshot];
    [snapshot reloadItemsWithIdentifiers:@[messageID]];
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO];
}

#pragma mark - UITableViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating) {
        return;
    }
    CGFloat distanceFromBottom = scrollView.contentSize.height
        - (scrollView.contentOffset.y + scrollView.bounds.size.height);
    BOOL nowPinned = (distanceFromBottom < 80);
    if (nowPinned && !self.isPinnedToBottom) {
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];
    } else if (!nowPinned && self.isPinnedToBottom) {
        [self s7tv_updateNewMessagesBannerText];
        [self s7tv_showNewMessagesBanner];
    }
    self.isPinnedToBottom = nowPinned;
}

#pragma mark - Bannière "nouveaux messages" (Phase 4)

- (void)s7tv_updateNewMessagesBannerText {
    if (self.pendingNewMessagesCount == 0) {
        self.unseenMessagesBannerLabel.text = L(@"banner_new_messages_generic");
    } else if (self.pendingNewMessagesCount == 1) {
        self.unseenMessagesBannerLabel.text = L(@"banner_new_messages_one");
    } else {
        self.unseenMessagesBannerLabel.text =
            [NSString stringWithFormat:L(@"banner_new_messages_format"), (unsigned long)self.pendingNewMessagesCount];
    }
}

- (void)s7tv_showNewMessagesBanner {
    self.unseenMessagesBanner.hidden = NO;
}

- (void)s7tv_hideNewMessagesBanner {
    self.unseenMessagesBanner.hidden = YES;
}

- (void)s7tv_didTapNewMessagesBanner {
    self.pendingNewMessagesCount = 0;
    [self s7tv_hideNewMessagesBanner];
    self.isPinnedToBottom = YES;
    NSInteger count = self.displayedMessages.count;
    if (count == 0) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:count - 1 inSection:0];
    [self.tableView scrollToRowAtIndexPath:last
                           atScrollPosition:UITableViewScrollPositionBottom
                                   animated:YES];
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    [engine removeObserver:s7tvCell.messageLabel];
    if (s7tvCell.animationKeys.count == 0) return;
    __weak UILabel *weakLabel = s7tvCell.messageLabel;
    [engine addObserver:s7tvCell.messageLabel
                   keys:s7tvCell.animationKeys
                 redraw:^{
        [weakLabel setNeedsDisplay];
    }];
}

- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:s7tvCell.messageLabel];
}

// self.bounds.size.width n'est pas fiable telle quelle : constaté en
// production (logs), cette valeur oscille (ex. 253.3 puis 390.0 pour la
// même vue à quelques centaines de ms d'intervalle) sans que ça corresponde
// à un vrai changement de largeur visible à l'écran — cohérent avec un
// panneau flottant repositionné par Twitch via un mécanisme qui ne redonne
// pas systématiquement à cette vue des bounds à jour (transform, conteneur
// parent qui recadre visuellement sans resize direct). On calcule donc la
// largeur RÉELLEMENT visible en remontant la hiérarchie et en intersectant,
// dans le système de coordonnées de self, les bounds de chaque ancêtre qui
// recadre visuellement (clipsToBounds == YES) — convertRect:toView: gère
// correctement les transforms le cas échéant, contrairement à une
// comparaison brute de bounds.size.width. Utilisée par layoutSubviews pour
// savoir quand forcer un reloadData (self-sizing cells) après un tel
// recadrage.
- (CGFloat)s7tv_actualVisibleWidth {
    CGRect visibleRect = self.bounds;
    if (CGRectIsEmpty(visibleRect)) return self.bounds.size.width;

    UIView *ancestor = self.superview;
    while (ancestor) {
        if (ancestor.clipsToBounds) {
            CGRect ancestorRectInSelf = [ancestor convertRect:ancestor.bounds toView:self];
            visibleRect = CGRectIntersection(visibleRect, ancestorRectInSelf);
            if (CGRectIsNull(visibleRect)) {
                // Intersection vide (vue actuellement hors écran/masquée) —
                // pas une largeur exploitable, on retombe sur self.bounds.
                return self.bounds.size.width;
            }
        }
        ancestor = ancestor.superview;
    }
    return ceil(visibleRect.size.width);
}

#pragma mark - Construction du texte

static CGFloat s7tv_relativeLuminance(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat (^chan)(CGFloat) = ^CGFloat(CGFloat c) {
        return (c <= 0.03928) ? (c / 12.92) : (CGFloat)pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b);
}

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
        return [UIColor whiteColor];
    }
    static const CGFloat kBgLuminance      = 0.009281;
    static const CGFloat kMinContrastRatio = 4.5;
    CGFloat targetLuminance = kMinContrastRatio * (kBgLuminance + 0.05) - 0.05;
    if (s7tv_relativeLuminance(r, g, b) >= targetLuminance) return color;
    CGFloat h, s, l;
    s7tv_rgbToHSL(r, g, b, &h, &s, &l);
    CGFloat originalL = l;
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
    CGFloat deltaL = bestL - originalL;
    CGFloat easingFactor = 1.0 - MIN(deltaL * 0.8, 0.8);
    CGFloat desaturatedS = s * easingFactor;
    CGFloat bestR, bestG, bestB;
    s7tv_hslToRGB(h, desaturatedS, bestL, &bestR, &bestG, &bestB);
    return [UIColor colorWithRed:bestR green:bestG blue:bestB alpha:a];
}

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

static NSDataDetector *s7tv_sharedURLDetector(void) {
    static NSDataDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    });
    return detector;
}

static void s7tv_appendTextWithLinkDetection(NSMutableAttributedString *result,
                                              NSString *text,
                                              UIFont *font,
                                              UIColor *textColor) {
    if (!text.length) return;
    NSDataDetector *detector = s7tv_sharedURLDetector();
    NSArray<NSTextCheckingResult *> *matches = detector
        ? [detector matchesInString:text options:0 range:NSMakeRange(0, text.length)]
        : @[];
    if (matches.count == 0) {
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:text
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: textColor}]];
        return;
    }
    static UIColor *linkColor;
    static dispatch_once_t colorToken;
    dispatch_once(&colorToken, ^{
        linkColor = [UIColor colorWithRed:0.482 green:0.667 blue:1.0 alpha:1.0];
    });
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > cursor) {
            NSString *plain = [text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)];
            [result appendAttributedString:[[NSAttributedString alloc]
                initWithString:plain
                    attributes:@{NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: textColor}]];
        }
        NSString *linkText = [text substringWithRange:match.range];
        NSURL *url = match.URL ?: [NSURL URLWithString:linkText];
        NSMutableDictionary *linkAttrs = [@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: linkColor,
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
        } mutableCopy];
        if (url) linkAttrs[NSLinkAttributeName] = url;
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:linkText attributes:linkAttrs]];
        cursor = match.range.location + match.range.length;
    }
    if (cursor < text.length) {
        NSString *tail = [text substringFromIndex:cursor];
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:tail
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: textColor}]];
    }
}

- (NSAttributedString *)s7tv_buildAttributedStringForMessage:(S7TVChatMessage *)msg
                                       collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes
                                       collectAnimatedEmotes:(nullable NSMutableArray<id<S7TVResolvedEmote>> *)outAnimatedEmotes {
    NSMutableAttributedString *result = [NSMutableAttributedString new];

    // Phase 3 — message système (sub/resub/gift) : bannière au lieu du
    // "pseudo: texte" habituel, suivie éventuellement du commentaire que
    // l'utilisateur a attaché à son resub (rendu comme un message normal).
    if (msg.type == S7TVChatMessageTypeSystem && msg.systemInfo) {
        [self s7tv_appendSystemBannerForMessage:msg into:result];
        if (msg.rawText.length) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
            [self s7tv_appendNormalBodyForMessage:msg into:result
                            collectUncachedEmotes:outUncachedEmotes
                            collectAnimatedEmotes:outAnimatedEmotes];
        }
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }

    [self s7tv_appendNormalBodyForMessage:msg into:result
                    collectUncachedEmotes:outUncachedEmotes
                    collectAnimatedEmotes:outAnimatedEmotes];
    s7tv_applyLineBreakParagraphStyle(result);
    return result;
}

// Phase 3 — pseudo (couleur chat) + phrase système pré-construite par le
// parser IRC (voir TweakSevenTV.m, s7tv_buildSystemMessagePhrase). Le
// renderer ne fait qu'afficher, aucune logique de formulation ici.
- (void)s7tv_appendSystemBannerForMessage:(S7TVChatMessage *)msg
                                      into:(NSMutableAttributedString *)result {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    UIFont *nameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *bodyFont = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *nameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
    UIColor *bodyColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";

    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:displayName
            attributes:@{NSFontAttributeName: nameFont, NSForegroundColorAttributeName: nameColor}]];
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[@" " stringByAppendingString:msg.systemPhrase ?: @""]
            attributes:@{NSFontAttributeName: bodyFont, NSForegroundColorAttributeName: bodyColor}]];
}

// Corps badges + pseudo + tokens — extrait de l'ancien
// s7tv_buildAttributedStringForMessage: (comportement inchangé pour les
// messages normaux), réutilisé aussi pour le commentaire attaché à un
// message système (Phase 3).
- (void)s7tv_appendNormalBodyForMessage:(S7TVChatMessage *)msg
                                    into:(NSMutableAttributedString *)result
                  collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes
                  collectAnimatedEmotes:(nullable NSMutableArray<id<S7TVResolvedEmote>> *)outAnimatedEmotes {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];

    UIFont *usernameFont = [UIFont boldSystemFontOfSize:cfg.usernameFontSize];
    UIFont *messageFont  = [UIFont systemFontOfSize:cfg.messageFontSize];
    // Mentions ("@pseudo" ET pseudo cité sans @, même token type — voir
    // SevenTVChatMessage.h) en gras pour ressortir dans le corps du
    // message, indépendamment de la couleur appliquée juste en dessous.
    UIFont *mentionFont  = [UIFont boldSystemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
    // /me : le corps entier prend la couleur du pseudo (comportement
    // Twitch) au lieu du blanc habituel — voir isActionMessage sur
    // S7TVChatMessage, déballé du CTCP ACTION par s7tv_parsePRIVMSG dans
    // TweakSevenTV.m. Un seul point de bascule : messageColor est déjà
    // réutilisé pour tous les chemins du corps ci-dessous (fallback sans
    // tokens, texte brut, emote non résolue, texte hors mention).
    UIColor *messageColor  = msg.isActionMessage ? usernameColor : [UIColor whiteColor];

    NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];

    // Badges (Phase 3) — gardent leur position verticale actuelle
    // (bounds y=-3). Le réglage emoteVerticalOffset ne s'applique qu'aux
    // emotes (7TV + Twitch natives), pas aux badges.
    SevenTVBadgeProvider *badgeProvider = [SevenTVBadgeProvider sharedProvider];
    for (NSString *badgeIdentifier in msg.badgeIdentifiers) {
        id<S7TVResolvedEmote> badge = [badgeProvider resolvedBadgeForIdentifier:badgeIdentifier];
        if (!badge) {
            continue;
        }
        UIImage *cachedBadgeImage = [imageCache cachedImageForResolvedEmote:badge];
        if (!cachedBadgeImage) {
            [outUncachedEmotes addObject:badge];
            continue;
        }
        NSTextAttachment *badgeAttachment = [[NSTextAttachment alloc] init];
        badgeAttachment.image = cachedBadgeImage;
        badgeAttachment.bounds = CGRectMake(0, -3, cfg.badgeSize, cfg.badgeSize);
        [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:badgeAttachment]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }

    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:[displayName stringByAppendingString:@": "]
            attributes:@{NSFontAttributeName: usernameFont,
                         NSForegroundColorAttributeName: usernameColor}]];

    if (msg.state == S7TVChatMessageStateDeletedCollapsed) {
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"[message supprimé]"
                attributes:@{NSFontAttributeName: messageFont,
                             NSForegroundColorAttributeName: [UIColor grayColor]}]];
        return;
    }

    NSArray<S7TVChatToken *> *tokens = msg.tokens;
    if (!tokens.count) {
        s7tv_appendTextWithLinkDetection(result, msg.rawText ?: @"", messageFont, messageColor);
        return;
    }

    for (S7TVChatToken *token in tokens) {
        if (token.type == S7TVChatTokenTypeEmote7TV || token.type == S7TVChatTokenTypeEmoteTwitch) {
            id<S7TVResolvedEmote> emote = token.resolvedEmote;
            if (!emote) {
                [result appendAttributedString:[[NSAttributedString alloc]
                    initWithString:token.text ?: @""
                        attributes:@{NSFontAttributeName: messageFont,
                                     NSForegroundColorAttributeName: messageColor}]];
                continue;
            }

            CGFloat targetHeight = (token.type == S7TVChatTokenTypeEmote7TV)
                ? cfg.emote7TVSize : cfg.emoteTwitchSize;
            CGFloat ratio = (emote.nativeSize.height > 0)
                ? emote.nativeSize.width / emote.nativeSize.height : 1.0;
            CGFloat targetWidth = targetHeight * ratio;

            UIImage *cachedImage = [imageCache cachedImageForResolvedEmote:emote];
            if (!cachedImage) {
                [result appendAttributedString:[[NSAttributedString alloc]
                    initWithString:token.text ?: @""
                        attributes:@{NSFontAttributeName: messageFont,
                                     NSForegroundColorAttributeName: messageColor}]];
                [outUncachedEmotes addObject:emote];
                continue;
            }

            BOOL wantsAnimation = emote.isAnimated && [SevenTVManager sharedManager].showAnimated;

            NSTextAttachment *attachment;
            if (wantsAnimation) {
                S7TVAnimatedEmoteAttachment *animatedAttachment = [S7TVAnimatedEmoteAttachment new];
                animatedAttachment.animationKey = emote.imageURL.absoluteString;
                animatedAttachment.staticFallbackImage = cachedImage;
                attachment = animatedAttachment;
                if (outAnimatedEmotes) [outAnimatedEmotes addObject:emote];
            } else {
                attachment = [[NSTextAttachment alloc] init];
                attachment.image = cachedImage;
            }

            // Sens logique : positif = vers le haut, négatif = vers le bas
            // — identique au picker/preview. Pas d'inversion de signe ici
            // (contrairement à une version précédente) : dans les bounds
            // d'un NSTextAttachment, augmenter y déplace vers le haut, donc
            // le sens correspond déjà. Le -4.0 fixe est le rebase du zéro :
            // à offset=0, l'emote est posée sur la ligne du bas (= l'ancien
            // rendu par défaut, qui valait +4 sur l'ancienne échelle centrée).
            CGFloat y = cfg.emoteVerticalOffset - 4.0;
            attachment.bounds = CGRectMake(0, y, targetWidth, targetHeight);

            [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            continue;
        }

        if (token.type == S7TVChatTokenTypeMention) {
            // Couleur résolue par le tokenizer (voir
            // SevenTVChatUserColorRegistry) — même traitement de contraste
            // que le pseudo de l'auteur (s7tv_readableColorOnDarkBackground)
            // pour rester lisible sur fond sombre. nil (pseudo jamais vu
            // dans le chat) → couleur normale du texte, pas de couleur
            // devinée.
            UIColor *mentionColor = token.mentionColor
                ? s7tv_readableColorOnDarkBackground(token.mentionColor)
                : messageColor;
            [result appendAttributedString:[[NSAttributedString alloc]
                initWithString:token.text ?: @""
                    attributes:@{NSFontAttributeName: mentionFont,
                                 NSForegroundColorAttributeName: mentionColor}]];
            continue;
        }

        s7tv_appendTextWithLinkDetection(result, token.text ?: @"", messageFont, messageColor);
    }
}

@end