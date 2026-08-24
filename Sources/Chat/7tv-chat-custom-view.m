/*
 * 7tv-chat-custom-view.m
 *
 * Voir 7tv-chat-custom-view.h pour le contexte (Phase 1c).
 */

#import "Chat/7tv-chat-custom-view.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Emote/7tv-emote-image-cache.h"
#import "Emote/7tv-emote-animation-engine.h"
#import "Badge/7tv-badge-provider.h"
#import "Localization/7tv-localization-manager.h"
#import "Core/7tv-core-manager.h"
#import "Chat/7tv-chat-reply-thread-panel.h"
#import "Chat/7tv-chat-tokenizer.h"
#import "Emote/7tv-emote-provider.h"
#import <objc/runtime.h>
#import <math.h>

// ============================================================
// MARK: - Intégration dans le transcript Twitch
// ============================================================

static const char kS7TVChatCustomInstalledView = 21;
static __weak SevenTVChatCustomView *s_activeChatCustomView = nil;
static __weak UIView *s_activeNativeChatView = nil;
static BOOL s_chatReloadScheduled = NO;

static UIView *s7tv_findVisibleChatInputViewInWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return nil;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
    UIView *bestCandidate = nil;
    CGFloat bestBottom = -CGFLOAT_MAX;
    while (views.count > 0) {
        UIView *view = views.firstObject;
        [views removeObjectAtIndex:0];
        if (view.hidden || view.alpha <= 0.01) continue;
        if ([NSStringFromClass(view.class) isEqualToString:@"Twitch.ChatInputView"] &&
            view.window == window && !CGRectIsEmpty(view.bounds)) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            if (CGRectIntersectsRect(frame, window.bounds) && CGRectGetMaxY(frame) > bestBottom) {
                bestCandidate = view;
                bestBottom = CGRectGetMaxY(frame);
            }
        }
        [views addObjectsFromArray:view.subviews];
    }
    return bestCandidate;
}

UIView *s7tv_findChatInputView(void) {
    // Pendant une transition de chaîne, Twitch peut conserver brièvement une
    // ancienne ChatInputView dans une autre fenêtre. La fenêtre du transcript
    // réellement actif est la seule source fiable pour ancrer les bandeaux.
    UIWindow *activeWindow = s_activeChatCustomView.window;
    UIView *activeCandidate = s7tv_findVisibleChatInputViewInWindow(activeWindow);
    if (activeCandidate) return activeCandidate;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window == activeWindow) continue;
            UIView *candidate = s7tv_findVisibleChatInputViewInWindow(window);
            if (candidate) return candidate;
        }
    }
    return nil;
}

SevenTVChatCustomView *s7tv_activeChatCustomView(void) {
    return s_activeChatCustomView;
}

void s7tv_reloadActiveChatCustomView(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view reloadMessages];
        [[S7TVReplyThreadPanel sharedPanel] refreshIfNeeded];
    });
}

void s7tv_reloadActiveChatCustomViewAnimated(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view refreshVisibleMessageContentIfFrozen];
        [view reloadMessagesAnimated:YES];
        [[S7TVReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
    });
}

void s7tv_reloadActiveChatMessage(NSString *messageID) {
    if (!messageID.length) return;
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view refreshMessageWithID:messageID animated:YES];
        [[S7TVReplyThreadPanel sharedPanel]
            refreshMessageIfNeededWithID:messageID excludingView:nil];
    });
}

void s7tv_applyModerationStateToRetainedMessage(NSString *messageID,
                                                S7TVChatMessageState state,
                                                S7TVChatModerationKind moderationKind,
                                                NSInteger durationSeconds) {
    if (!messageID.length) return;
    dispatch_block_t apply = ^{
        [s_activeChatCustomView applyModerationState:state
                         toDisplayedMessageWithID:messageID
                                  moderationKind:moderationKind
                                 durationSeconds:durationSeconds];
        [[S7TVReplyThreadPanel sharedPanel]
            applyModerationState:state
             toRetainedMessageWithID:messageID
                      moderationKind:moderationKind
                     durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void s7tv_applyModerationToRetainedMessagesForUser(NSString *authorUserID,
                                                    NSString *authorLogin,
                                                    S7TVChatModerationKind moderationKind,
                                                    NSInteger durationSeconds) {
    if (!authorUserID.length && !authorLogin.length) return;
    dispatch_block_t apply = ^{
        [s_activeChatCustomView applyModerationToDisplayedMessagesForUserID:authorUserID
                                                                authorLogin:authorLogin
                                                             moderationKind:moderationKind
                                                            durationSeconds:durationSeconds];
        [[S7TVReplyThreadPanel sharedPanel]
            applyModerationToRetainedMessagesForUserID:authorUserID
                                           authorLogin:authorLogin
                                        moderationKind:moderationKind
                                       durationSeconds:durationSeconds];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void s7tv_applyModerationToAllRetainedMessages(void) {
    dispatch_block_t apply = ^{
        [s_activeChatCustomView applyModerationToAllDisplayedMessages];
        [[S7TVReplyThreadPanel sharedPanel] applyModerationToAllRetainedMessages];
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void s7tv_reloadActiveChatCustomViewForConfiguration(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view refreshVisibleMessageContentIfFrozen];
        [view reloadMessages];
        [[S7TVReplyThreadPanel sharedPanel] forceRefreshIfNeeded];
    });
}

void s7tv_scheduleChatCustomReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_chatReloadScheduled) return;
        s_chatReloadScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            s_chatReloadScheduled = NO;
            s7tv_reloadActiveChatCustomView();
        });
    });
}

static void s7tv_installChatCustomView(UIView *chatView) {
    s_activeNativeChatView = chatView;
    UIStackView *stack = [chatView.superview isKindOfClass:UIStackView.class]
        ? (UIStackView *)chatView.superview : nil;
    if (!stack) return;

    SevenTVChatCustomView *existing =
        objc_getAssociatedObject(chatView, &kS7TVChatCustomInstalledView);
    if (existing && existing.superview == stack) {
        chatView.hidden = YES;
        existing.hidden = NO;
        s_activeChatCustomView = existing;
        [existing reloadMessages];
        return;
    }

    NSInteger index = [stack.arrangedSubviews indexOfObject:chatView];
    if (index == NSNotFound) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ ChatTranscriptView introuvable dans arrangedSubviews"];
        return;
    }

    chatView.hidden = YES;
    SevenTVChatCustomView *customView = [[SevenTVChatCustomView alloc]
        initWithStore:[SevenTVManager sharedManager].chatMessageStore];
    customView.delegate = [S7TVReplyThreadPanel sharedPanel];
    customView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        [[S7TVReplyThreadPanel sharedPanel]
            selectReplyTargetForMessageID:messageID username:username];
    };
    [stack insertArrangedSubview:customView atIndex:index];
    objc_setAssociatedObject(chatView, &kS7TVChatCustomInstalledView, customView,
                             OBJC_ASSOCIATION_RETAIN);
    s_activeChatCustomView = customView;
    [customView reloadMessages];
    [[SevenTVManager sharedManager]
        log:@"🏗 SevenTVChatCustomView insérée (index %ld du UIStackView, chat réel caché)",
        (long)index];
}

void s7tv_applyChatCustomToggle(void) {
    UIView *chatView = s_activeNativeChatView;
    if (!chatView || ![chatView.superview isKindOfClass:UIStackView.class]) return;
    if ([SevenTVManager sharedManager].chatCustomTestEnabled) {
        s7tv_installChatCustomView(chatView);
        return;
    }

    SevenTVChatCustomView *customView =
        objc_getAssociatedObject(chatView, &kS7TVChatCustomInstalledView);
    chatView.hidden = NO;
    customView.hidden = YES;
    if (s_activeChatCustomView == customView) s_activeChatCustomView = nil;
}

void s7tv_handleNativeChatViewLifecycle(UIView *view) {
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.ChatTranscriptView"] ||
        !view.window || ![view.superview isKindOfClass:UIStackView.class]) return;
    s_activeNativeChatView = view;
    s7tv_applyChatCustomToggle();
}

void s7tv_setupChatCustomIntegration(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SevenTVManager *manager = [SevenTVManager sharedManager];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:S7TVChatCustomToggleDidChangeNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            s7tv_applyChatCustomToggle();
        }];
        [center addObserverForName:S7TVEmoteCatalogDidUpdateNotification
                           object:manager queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            [manager.chatMessageStore
                retokenizeMessagesUsingBlock:^NSArray<S7TVChatToken *> *(S7TVChatMessage *message) {
                    return [SevenTVChatTokenizer tokenizeText:message.rawText ?: @""
                                              twitchEmotesTag:message.twitchEmotesTag ?: @""
                                                    providers:s7tv_chatEmoteProviders()];
                } completion:^{
                    s7tv_reloadActiveChatCustomViewForConfiguration();
                }];
        }];
        for (NSString *notificationName in @[
            S7TVBadgesCatalogUpdatedNotification,
            S7TVChatAppearanceConfigDidChangeNotification,
            S7TVLanguageDidChangeNotification
        ]) {
            [center addObserverForName:notificationName object:nil queue:nil
                            usingBlock:^(__unused NSNotification *note) {
                s7tv_reloadActiveChatCustomViewForConfiguration();
            }];
        }
    });
}

// Métadonnée privée posée uniquement sur le caractère d'attachement d'une
// emote. Le hit-test de l'appui long récupère directement le token déjà
// résolu, sans rescanner le texte ni réinterroger le provider.
static NSString *const kS7TVChatEmoteTokenAttributeName = @"S7TVChatEmoteToken";
static const NSInteger kS7TVChatEmotePreviewOverlayTag = 0x7E7E71;

static BOOL s7tv_isDeletedMessage(S7TVChatMessage *msg) {
    return msg.state == S7TVChatMessageStateDeletedCollapsed ||
           msg.state == S7TVChatMessageStateDeletedExpanded;
}

static BOOL s7tv_shouldRenderDeletedCollapsed(S7TVChatMessage *msg,
                                               SevenTVChatAppearanceConfig *cfg) {
    if (!s7tv_isDeletedMessage(msg)) return NO;
    switch (cfg.deletedMessageRevealMode) {
        case S7TVDeletedMessageRevealModeNever:
            return YES;
        case S7TVDeletedMessageRevealModeAlways:
            return NO;
        case S7TVDeletedMessageRevealModeOnTap:
        default:
            return msg.state == S7TVChatMessageStateDeletedCollapsed;
    }
}

static BOOL s7tv_shouldRenderDeletedExpanded(S7TVChatMessage *msg,
                                              SevenTVChatAppearanceConfig *cfg) {
    return s7tv_isDeletedMessage(msg) && !s7tv_shouldRenderDeletedCollapsed(msg, cfg);
}


// ============================================================
// MARK: - Cellule (texte + emotes, hauteur dynamique)
// ============================================================

@interface S7TVChatCustomCell : UITableViewCell
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong, nullable) NSSet<NSString *> *animationKeys;
// Demandes de décodage liées à cette cellule visible. Elles sont annulées au
// reuse / didEndDisplaying afin qu'une emote partie de l'écran ne bloque pas
// la file série devant celles que l'utilisateur regarde réellement.
@property (nonatomic, strong) NSArray<S7TVEmoteFrameRequest *> *animationFrameRequests;
// Phase 3 — bandeau d'accent (barre colorée + icône + fond teinté) pour les
// messages système (sub/resub/gift). Invisible par défaut, activé par
// s7tv_configureSystemAccentWithColor:iconName:.
@property (nonatomic, strong) UIView *systemAccentBar;
@property (nonatomic, strong) UIImageView *systemIconView;
// Miroir à droite de systemAccentBar + petit label en haut à droite, partagé
// par les highlights "TE MENTIONNE" et "FIRST MESSAGE". Les messages système
// sub/resub/gift passent un texte nil et n'affichent donc pas cet élément.
@property (nonatomic, strong) UIView *systemAccentBarRight;
@property (nonatomic, strong) UILabel *highlightBadgeLabel;
@property (nonatomic, strong) NSLayoutConstraint *messageLabelLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *messageLabelTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *messageLabelBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *systemAccentBarWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *systemAccentBarRightWidthConstraint;
// ── Bandeau "Répond à @X" (fils de discussion) ──────────────────────────
// Ligne compacte au-dessus du message, tappable, ouvre le panneau Fil côté
// hôte (voir onReplyBannerTap). Invisible par défaut ; visible/positionné
// par -s7tv_configureReplyBannerWithUsername:bodyPreview:.
@property (nonatomic, strong) UILabel *replyBannerLabel;
// messageLabel.top = contentView.top + constant (défaut, pas de reply) —
// reste piloté par s7tv_configureSystemAccentWithColor:... comme avant.
// messageLabelTopToBannerConstraint : messageLabel.top = replyBannerLabel.bottom
// + 4 (actif uniquement quand le bandeau est visible). Les deux ne sont
// JAMAIS actives en même temps — voir s7tv_configureReplyBannerWithUsername:.
@property (nonatomic, strong) NSLayoutConstraint *messageLabelTopToBannerConstraint;
// Callback plutôt qu'un delegate direct sur la cellule (comme animationKeys
// plus bas) : la cellule ne connaît pas SevenTVChatCustomView, juste ce
// qu'on lui donne au moment de la configuration (voir s7tv_cellForMessageID:).
@property (nonatomic, copy, nullable) void (^onReplyBannerTap)(void);
// Phase 5 — présent uniquement pour un message supprimé (collapsed OU
// expanded). Le tap sur le corps bascule l'état avant toute détection de
// lien/réponse : le placeholder et le contenu révélé partagent ainsi la
// même zone interactive, sans ajouter de geste concurrent sur contentView.
@property (nonatomic, copy, nullable) void (^onDeletedMessageTap)(void);
@property (nonatomic, strong) NSLayoutConstraint *messageLabelTrailingConstraint;
// ── Barre "fil de discussion" (panneau Fil, réponses uniquement) ───────
// Barre grise verticale pleine hauteur de cellule (contentView.top →
// contentView.bottom, sans marge) : comme les cellules se touchent sans
// espacement (separatorStyle none, pas de spacing inter-cellule), les
// barres de cellules consécutives se prolongent visuellement en une seule
// ligne continue — effet "fil" façon Reddit/Discord, sans rien de plus à
// faire côté layout. Masquée par défaut (chat principal) — voir
// SevenTVChatCustomView.usesThreadReplyIndent.
@property (nonatomic, strong) UIView *threadBarView;
// Séparateur local entre l'historique chargé et les PRIVMSG live. Le label
// de message invisible conserve l'auto-sizing ; ces deux vues dessinent la
// vraie barre continue et son libellé rouge par-dessus.
@property (nonatomic, strong) UIView *historyDividerLineView;
@property (nonatomic, strong) UILabel *historyDividerLabel;
- (void)s7tv_cancelAnimationFrameRequests;
@end

@implementation S7TVChatCustomCell

- (void)s7tv_cancelAnimationFrameRequests {
    for (S7TVEmoteFrameRequest *request in self.animationFrameRequests) {
        [request cancel];
    }
    self.animationFrameRequests = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self s7tv_cancelAnimationFrameRequests];
    self.onReplyBannerTap = nil;
    self.onDeletedMessageTap = nil;
    self.animationKeys = nil;
    self.messageLabel.alpha = 1.0;
    self.historyDividerLineView.hidden = YES;
    self.historyDividerLabel.hidden = YES;
}

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

        _systemAccentBarRight = [[UIView alloc] init];
        _systemAccentBarRight.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_systemAccentBarRight];

        _highlightBadgeLabel = [[UILabel alloc] init];
        _highlightBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _highlightBadgeLabel.font = [UIFont boldSystemFontOfSize:9];
        _highlightBadgeLabel.textAlignment = NSTextAlignmentRight;
        _highlightBadgeLabel.hidden = YES;
        [self.contentView addSubview:_highlightBadgeLabel];

        _replyBannerLabel = [[UILabel alloc] init];
        _replyBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _replyBannerLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _replyBannerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _replyBannerLabel.numberOfLines = 1;
        _replyBannerLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _replyBannerLabel.hidden = YES;
        _replyBannerLabel.userInteractionEnabled = YES;
        [_replyBannerLabel addGestureRecognizer:
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(s7tv_handleReplyBannerTap:)]];
        [self.contentView addSubview:_replyBannerLabel];

        _threadBarView = [[UIView alloc] init];
        _threadBarView.translatesAutoresizingMaskIntoConstraints = NO;
        _threadBarView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        _threadBarView.hidden = YES;
        [self.contentView addSubview:_threadBarView];

        UIColor *historyRed = [UIColor colorWithRed:0.94 green:0.24 blue:0.30 alpha:1.0];
        _historyDividerLineView = [[UIView alloc] init];
        _historyDividerLineView.translatesAutoresizingMaskIntoConstraints = NO;
        _historyDividerLineView.backgroundColor = historyRed;
        _historyDividerLineView.hidden = YES;
        [self.contentView addSubview:_historyDividerLineView];

        _historyDividerLabel = [[UILabel alloc] init];
        _historyDividerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _historyDividerLabel.font = [UIFont boldSystemFontOfSize:13];
        _historyDividerLabel.textColor = historyRed;
        _historyDividerLabel.text = L(@"chat_history_new_messages");
        _historyDividerLabel.hidden = YES;
        [self.contentView addSubview:_historyDividerLabel];

        _systemAccentBarWidthConstraint =
            [_systemAccentBar.widthAnchor constraintEqualToConstant:0];
        _systemAccentBarRightWidthConstraint =
            [_systemAccentBarRight.widthAnchor constraintEqualToConstant:0];
        _messageLabelLeadingConstraint =
            [_messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8];
        // 4 par défaut ; passe à une valeur plus grande quand le badge
        // highlightBadgeLabel est affiché (voir
        // s7tv_configureSystemAccentWithColor:iconName:backgroundEnabled:highlightBadgeText:)
        // pour lui laisser sa propre ligne au-dessus du texte du message,
        // plutôt que de le superposer.
        _messageLabelTopConstraint =
            [_messageLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4];
        // -4 par défaut ; le constant réel est recalculé dans
        // s7tv_configureCell:forMessage:attributedText: en fonction de
        // cfg.lineSpacing (espacement ENTRE deux messages, voir
        // 7tv-chat-appearance-config.h) à chaque configuration de cellule —
        // avec les self-sizing cells, c'est ici (et non plus dans un calcul
        // de hauteur externe supprimé) que cet espacement doit être ajouté,
        // puisqu'il contribue directement à la hauteur intrinsèque de la
        // cellule que UIKit va lire.
        _messageLabelBottomConstraint =
            [_messageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4];

        // Inactive par défaut — activée uniquement quand le bandeau reply
        // est visible (voir s7tv_configureReplyBannerWithUsername:), en
        // même temps que messageLabelTopConstraint est désactivée. Jamais
        // les deux actives ensemble (conflit de contraintes sinon).
        _messageLabelTopToBannerConstraint =
            [_messageLabel.topAnchor constraintEqualToAnchor:_replyBannerLabel.bottomAnchor constant:4];
        _messageLabelTopToBannerConstraint.active = NO;

        _messageLabelTrailingConstraint =
            [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8];

        [NSLayoutConstraint activateConstraints:@[
            [_systemAccentBar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_systemAccentBar.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_systemAccentBar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            _systemAccentBarWidthConstraint,

            [_systemIconView.leadingAnchor constraintEqualToAnchor:_systemAccentBar.trailingAnchor constant:8],
            [_systemIconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_systemIconView.widthAnchor constraintEqualToConstant:14],
            [_systemIconView.heightAnchor constraintEqualToConstant:14],

            [_systemAccentBarRight.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_systemAccentBarRight.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_systemAccentBarRight.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            _systemAccentBarRightWidthConstraint,

            [_highlightBadgeLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            // Collé au bord supérieur pour laisser le badge sur sa propre
            // ligne sans créer une grande zone vide avant le message.
            [_highlightBadgeLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:1],
            [_highlightBadgeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:8],

            // Même leading que messageLabel (suit isSystem via
            // messageLabelLeadingConstraint, pas de leading dédié) pour que
            // le bandeau s'aligne avec le texte du message juste en dessous.
            [_replyBannerLabel.leadingAnchor constraintEqualToAnchor:_messageLabel.leadingAnchor],
            [_replyBannerLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_replyBannerLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],

            _messageLabelLeadingConstraint,
            _messageLabelTopConstraint,
            _messageLabelBottomConstraint,
            _messageLabelTrailingConstraint,

            [_threadBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_threadBarView.widthAnchor constraintEqualToConstant:3],
            [_threadBarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_threadBarView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

            [_historyDividerLineView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
            [_historyDividerLineView.trailingAnchor constraintEqualToAnchor:_historyDividerLabel.leadingAnchor constant:-8],
            [_historyDividerLineView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_historyDividerLineView.heightAnchor constraintEqualToConstant:1],
            [_historyDividerLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_historyDividerLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
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
//
// highlightBadgeText : non-nil pour les highlights self-mention et premier
// message (pas pour les messages système). Affiche une barre miroir à droite
// et le petit label correspondant, puis pousse le texte vers le bas pour lui
// garder sa propre ligne plutôt que de le superposer.
- (void)s7tv_configureSystemAccentWithColor:(nullable UIColor *)accentColor
                                    iconName:(nullable NSString *)iconName
                           backgroundEnabled:(BOOL)backgroundEnabled
                          highlightBadgeText:(nullable NSString *)highlightBadgeText {
    BOOL isSystem = (accentColor != nil);
    BOOL showHighlightBadge = isSystem && highlightBadgeText.length > 0;

    self.systemAccentBar.backgroundColor = accentColor ?: [UIColor clearColor];
    self.systemAccentBarWidthConstraint.constant = isSystem ? 3.0 : 0.0;
    self.systemIconView.hidden = !isSystem;
    self.systemIconView.tintColor = accentColor;
    self.systemIconView.image = iconName ? [UIImage systemImageNamed:iconName] : nil;
    self.messageLabelLeadingConstraint.constant = isSystem ? 31.0 : 8.0;

    self.systemAccentBarRight.backgroundColor = accentColor ?: [UIColor clearColor];
    self.systemAccentBarRightWidthConstraint.constant = showHighlightBadge ? 3.0 : 0.0;
    self.highlightBadgeLabel.hidden = !showHighlightBadge;
    self.highlightBadgeLabel.textColor = accentColor;
    self.highlightBadgeLabel.text = showHighlightBadge ? highlightBadgeText : nil;
    // 13 pt suffisent pour le petit label de 9 pt placé à y=1 : le texte
    // reste dessous sans le grand espacement produit auparavant par 16 pt.
    self.messageLabelTopConstraint.constant = showHighlightBadge ? 13.0 : 4.0;

    if (!isSystem) {
        self.contentView.backgroundColor = [UIColor clearColor];
    } else if (backgroundEnabled) {
        self.contentView.backgroundColor = [accentColor colorWithAlphaComponent:0.12];
    } else {
        self.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    }
}

// Toutes les utilisations de points suivent le même rendu Twitch PC, quelle
// que soit l'origine de la récompense : barre blanche pure, aucun fond ajouté
// et icône réelle des points dans le texte juste avant le coût.
- (void)s7tv_configureChannelPointAccent {
    [self s7tv_configureSystemAccentWithColor:[UIColor whiteColor]
                                      iconName:nil
                             backgroundEnabled:NO
                           highlightBadgeText:nil];
    self.systemIconView.hidden = YES;
    self.messageLabelLeadingConstraint.constant = 18.0;
    self.messageLabelTopConstraint.constant = 9.0;
    self.contentView.backgroundColor = [UIColor clearColor];
}

// username nil/vide → pas une réponse, bandeau masqué, messageLabel reprend
// sa position normale (top = contentView.top, pilotée par
// s7tv_configureSystemAccentWithColor:...). Simplification connue : si un
// message est À LA FOIS une réponse ET un highlight (highlightBadgeLabel
// visible), le bandeau reply prend le dessus — messageLabelTopConstraint
// (avec son constant 16 pour le badge) est désactivée dans ce cas, donc le
// badge mention perdrait sa marge dédiée. Combo rare, pas géré précisément
// pour l'instant.
- (void)s7tv_configureReplyBannerWithUsername:(nullable NSString *)username
                                    bodyPreview:(nullable NSString *)bodyPreview {
    BOOL isReply = username.length > 0;
    self.replyBannerLabel.hidden = !isReply;
    if (isReply) {
        NSString *preview = bodyPreview.length > 0 ? bodyPreview : @"";
        // Troncature ici (pas dans le modèle, voir 7tv-chat-message.h) —
        // NSLineBreakByTruncatingTail sur le label gère déjà l'overflow
        // visuel, mais on borne aussi la chaîne pour éviter de construire un
        // attributedText énorme pour rien sur un message très long.
        if (preview.length > 60) {
            preview = [[preview substringToIndex:60]
                stringByAppendingString:@"…"];
        }
        self.replyBannerLabel.text = [NSString stringWithFormat:L(@"chat_reply_banner_format"), username, preview];
    }
    self.messageLabelTopConstraint.active = !isReply;
    self.messageLabelTopToBannerConstraint.active = isReply;
}

// enabled : décale le contenu vers la droite (16 = 8 marge de base + 8 pour
// laisser respirer la barre) et affiche la barre grise continue. Appelé
// APRÈS s7tv_configureSystemAccentWithColor:... (qui pose la valeur de base
// 8/31 selon isSystem) — écrase volontairement cette valeur plutôt que de
// l'additionner : dans le panneau Fil, les réponses sont quasi toujours des
// messages normaux, ce cas simplifié suffit.
- (void)s7tv_setThreadIndentEnabled:(BOOL)enabled {
    self.threadBarView.hidden = !enabled;
    if (enabled) {
        self.messageLabelLeadingConstraint.constant = 16.0;
    }
}

- (void)s7tv_handleReplyBannerTap:(UITapGestureRecognizer *)gesture {
    if (self.onReplyBannerTap) self.onReplyBannerTap();
}

- (void)s7tv_setHistoryDividerEnabled:(BOOL)enabled {
    self.historyDividerLineView.hidden = !enabled;
    self.historyDividerLabel.hidden = !enabled;
    self.historyDividerLabel.text = enabled ? L(@"chat_history_new_messages") : nil;
    // Le texte contient volontairement un espace avec la bonne fonte pour
    // fournir une hauteur intrinsèque stable à la cellule auto-dimensionnée.
    self.messageLabel.alpha = enabled ? 0.0 : 1.0;
}

- (NSUInteger)s7tv_characterIndexAtPointInMessageLabel:(CGPoint)point
                                        requireGlyphHit:(BOOL)requireGlyphHit {
    NSAttributedString *attributedText = self.messageLabel.attributedText;
    if (!attributedText.length ||
        !CGRectContainsPoint(self.messageLabel.bounds, point)) return NSNotFound;

    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:attributedText];
    [textStorage addLayoutManager:layoutManager];

    NSTextContainer *textContainer =
        [[NSTextContainer alloc] initWithSize:self.messageLabel.bounds.size];
    textContainer.lineFragmentPadding = 0;
    textContainer.lineBreakMode = self.messageLabel.lineBreakMode;
    textContainer.maximumNumberOfLines = self.messageLabel.numberOfLines;
    [layoutManager addTextContainer:textContainer];

    CGFloat fraction = 0;
    NSUInteger glyphIndex = [layoutManager glyphIndexForPoint:point
                                              inTextContainer:textContainer
                       fractionOfDistanceThroughGlyph:&fraction];
    if (glyphIndex >= layoutManager.numberOfGlyphs) return NSNotFound;
    if (requireGlyphHit) {
        CGRect glyphRect = [layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIndex, 1)
                                                    inTextContainer:textContainer];
        if (!CGRectContainsPoint(CGRectInset(glyphRect, -2.0, -2.0), point)) return NSNotFound;
    }

    NSUInteger characterIndex = [layoutManager characterIndexForGlyphAtIndex:glyphIndex];
    return characterIndex < attributedText.length ? characterIndex : NSNotFound;
}

// Gère 2 choses sur le MÊME geste : ouvrir un lien tapé (comportement
// existant), ET — nouveau — ouvrir le fil si le message est une réponse et
// qu'aucun lien n'a été tapé à cet endroit précis. messageLabel est ancré
// quasi bord à bord dans la cellule (leading/trailing/top/bottom constants
// de quelques points), donc "taper le message" revient en pratique à taper
// messageLabel — pas besoin d'un geste séparé sur contentView (qui, lui, ne
// se déclenchait pas de façon fiable, retiré).
- (void)s7tv_handleTap:(UITapGestureRecognizer *)gesture {
    if (self.onDeletedMessageTap) {
        self.onDeletedMessageTap();
        return;
    }

    NSAttributedString *attributedText = self.messageLabel.attributedText;
    CGPoint tapPoint = [gesture locationInView:self.messageLabel];
    NSUInteger charIndex = [self s7tv_characterIndexAtPointInMessageLabel:tapPoint
                                                          requireGlyphHit:NO];
    if (charIndex != NSNotFound) {
        id linkValue = [attributedText attribute:NSLinkAttributeName atIndex:charIndex effectiveRange:NULL];
        NSURL *url = [linkValue isKindOfClass:[NSURL class]] ? linkValue : nil;
        if (!url && [linkValue isKindOfClass:[NSString class]]) url = [NSURL URLWithString:linkValue];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return; // un lien tapé prend le dessus, pas d'ouverture de fil en plus
        }
    }

    if (self.onReplyBannerTap) self.onReplyBannerTap();
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
// Fiche compacte d'emote affichée au-dessus du chat après appui long.
// Une seule par instance ; l'overlay plein écran intercepte le tap extérieur
// afin de fermer proprement la fiche sans cliquer dans le chat derrière.
@property (nonatomic, strong) UIControl *emotePreviewOverlay;
@property (nonatomic, strong) S7TVChatToken *previewedEmoteToken;
@property (nonatomic, weak) UIImageView *emotePreviewImageView;
@property (nonatomic, weak) UIButton *emotePreviewFavoriteButton;
@property (nonatomic, strong) S7TVEmoteFrameRequest *emotePreviewFrameRequest;
@property (nonatomic, assign) BOOL reloadDeferredUntilScrollEnds;
@property (nonatomic, assign) BOOL deferredReloadAnimated;
@property (nonatomic, strong) NSMutableArray *deferredReloadCompletions;
@property (nonatomic, strong) NSMutableSet<NSString *> *deferredMessageReloadIDs;
@property (nonatomic, assign) BOOL deferredMessageReloadAnimated;
@property (nonatomic, strong) NSMutableArray *deferredMessageReloadCompletions;
@property (nonatomic, assign) BOOL messageInteractionInProgress;
// Quand l'utilisateur remonte, le snapshot visible reste strictement figé.
// Le store continue de tourner à 300 messages ; seuls ces anciens modèles
// restent retenus temporairement par displayedMessages jusqu'au retour en bas.
@property (nonatomic, assign) BOOL transcriptFrozen;
@property (nonatomic, strong) NSSet<NSString *> *lastObservedStoreMessageIDs;
@property (nonatomic, assign) NSUInteger lastObservedStoreGeneration;
// UITableViewDiffableDataSource ne doit recevoir qu'un apply à la fois. Les
// demandes concurrentes sont fusionnées dans les files différées existantes.
@property (nonatomic, assign) BOOL snapshotApplyInProgress;
@property (nonatomic, assign) BOOL widthReloadPending;
- (void)s7tv_dismissEmotePreview;
- (void)s7tv_observeAnimatedEmotePreview:(id<S7TVResolvedEmote>)emote;
- (nullable NSString *)s7tv_captureVisibleAnchorAmongIDs:(nullable NSSet<NSString *> *)allowedIDs
                                                viewportY:(CGFloat *)outViewportY;
- (void)s7tv_restoreVisibleAnchorID:(nullable NSString *)messageID viewportY:(CGFloat)viewportY;
- (void)s7tv_flushDeferredReloadIfNeeded;
- (void)s7tv_flushDeferredMessageReloads;
- (void)s7tv_observeAnimationsForCell:(S7TVChatCustomCell *)cell;
- (void)s7tv_queueFullReloadAnimated:(BOOL)animated completion:(nullable void (^)(void))completion;
- (void)s7tv_recordFrozenStoreMessages;
- (void)s7tv_finishSnapshotApply;
- (void)s7tv_reloadMessageWithID:(NSString *)messageID;
- (void)s7tv_reloadMessageWithID:(NSString *)messageID
                        animated:(BOOL)animated
                      completion:(nullable void (^)(void))completion;
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
        _deferredReloadCompletions = [NSMutableArray array];
        _deferredMessageReloadIDs = [NSMutableSet set];
        _deferredMessageReloadCompletions = [NSMutableArray array];
        _lastObservedStoreMessageIDs = [NSSet set];
        _lastObservedStoreGeneration = [store generation];
        _showsReplyBanners = YES;
        _usesThreadReplyIndent = NO;
        _freezesTranscriptWhenScrolled = YES;
        _renderingSuspended = NO;
        _automaticallyScrollsToBottom = YES;

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

        // Un seul recognizer pour toute la table : pas de geste recréé sur
        // chaque cellule réutilisée. Le callback partagé décide ensuite quoi
        // faire de la cible (chat principal = réponse, previews sans callback
        // = no-op), ce composant reste uniquement responsable du hit-testing.
        UILongPressGestureRecognizer *replyLongPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                           action:@selector(s7tv_handleMessageLongPress:)];
        replyLongPress.minimumPressDuration = 0.45;
        [_tableView addGestureRecognizer:replyLongPress];

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
    [self.emotePreviewFrameRequest cancel];
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:self.emotePreviewImageView];
    [self.emotePreviewOverlay removeFromSuperview];
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
        if (self.snapshotApplyInProgress) self.widthReloadPending = YES;
        else [self.tableView reloadData];
    }
}

// Filet de sécurité : si un ancêtre change la largeur visuellement visible
// sans jamais déclencher self.layoutSubviews (ex. transform appliqué par
// Twitch sur un conteneur parent lors d'un passage paysage/théâtre, qui ne
// propage pas nécessairement d'invalidation de layout jusqu'à cette vue),
// on revérifie explicitement après chaque rotation, avec un court délai
// pour laisser l'animation de rotation/repositionnement Twitch se stabiliser.
- (void)s7tv_handleDeviceOrientationChange:(NSNotification *)note {
    [self s7tv_dismissEmotePreview];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf setNeedsLayout];
        [weakSelf layoutIfNeeded];
    });
}

- (CGFloat)s7tvContentHeight {
    // self.layoutIfNeeded d'abord : c'est -layoutSubviews qui détecte un
    // changement de largeur (s7tv_actualVisibleWidth vs cachedContentWidth)
    // et déclenche le reloadData nécessaire aux cellules self-sizing.
    [self layoutIfNeeded];
    [self.tableView layoutIfNeeded];
    return self.tableView.contentSize.height;
}

- (void)setScrollingEnabled:(BOOL)enabled {
    self.tableView.scrollEnabled = enabled;
    self.tableView.bounces = enabled;
    self.tableView.alwaysBounceVertical = enabled;
}

- (void)setFreezesTranscriptWhenScrolled:(BOOL)freezesTranscriptWhenScrolled {
    _freezesTranscriptWhenScrolled = freezesTranscriptWhenScrolled;
    if (!freezesTranscriptWhenScrolled && self.transcriptFrozen) {
        self.transcriptFrozen = NO;
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];
        [self s7tv_flushDeferredReloadIfNeeded];
    }
}

- (void)setRenderingSuspended:(BOOL)renderingSuspended {
    if (_renderingSuspended == renderingSuspended) return;
    _renderingSuspended = renderingSuspended;
    if (!renderingSuspended) return;

    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    for (S7TVChatCustomCell *cell in self.tableView.visibleCells) {
        [cell s7tv_cancelAnimationFrameRequests];
        [engine removeObserver:cell.messageLabel];
    }
    [self s7tv_dismissEmotePreview];
}

- (void)resetTransientTranscriptState {
    NSAssert([NSThread isMainThread], @"resetTransientTranscriptState touche UIKit");
    self.transcriptFrozen = NO;
    self.isPinnedToBottom = YES;
    self.pendingNewMessagesCount = 0;
    self.messageInteractionInProgress = NO;
    self.reloadDeferredUntilScrollEnds = NO;
    self.deferredReloadAnimated = NO;
    [self.deferredReloadCompletions removeAllObjects];
    [self.deferredMessageReloadIDs removeAllObjects];
    [self.deferredMessageReloadCompletions removeAllObjects];
    self.deferredMessageReloadAnimated = NO;
    [self s7tv_hideNewMessagesBanner];
    [self s7tv_dismissEmotePreview];

    // Un fil peut être fermé pendant sa décélération puis rouvert aussitôt.
    // Annuler explicitement le geste empêche le nouveau reload de rester en
    // file en attendant un didEndDecelerating qui n'arriverait plus puisque
    // la vue a entre-temps été masquée.
    CGPoint stableOffset = self.tableView.contentOffset;
    if (!self.automaticallyScrollsToBottom) {
        // La racine épinglée d'un fil doit toujours repartir de sa première
        // ligne. Sans ce reset, la table réutilisée pouvait conserver le
        // contentOffset d'une ancienne racine longue et sembler vide/coupée.
        stableOffset.y = -self.tableView.adjustedContentInset.top;
    }
    [self.tableView setContentOffset:stableOffset animated:NO];
    self.tableView.panGestureRecognizer.enabled = NO;
    self.tableView.panGestureRecognizer.enabled = YES;

    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    for (S7TVChatCustomCell *cell in self.tableView.visibleCells) {
        [cell s7tv_cancelAnimationFrameRequests];
        [engine removeObserver:cell.messageLabel];
    }
}

- (void)reloadMessages {
    [self reloadMessagesAnimated:NO];
}

- (void)reloadMessagesAnimated:(BOOL)animated {
    [self s7tv_reloadMessagesAnimated:animated completion:nil];
}

- (void)reloadMessagesWithCompletion:(void (^)(void))completion {
    [self s7tv_reloadMessagesAnimated:NO completion:completion];
}

- (void)refreshVisibleMessageContentIfFrozen {
    NSAssert([NSThread isMainThread], @"Le refresh du transcript touche UIKit");
    if (!self.transcriptFrozen) return;

    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        NSString *messageID = [self.dataSource itemIdentifierForIndexPath:indexPath];
        if (messageID.length && self.messagesByID[messageID]) {
            [self.deferredMessageReloadIDs addObject:messageID];
        }
    }
    [self s7tv_flushDeferredMessageReloads];
}

- (nullable NSString *)s7tv_captureVisibleAnchorAmongIDs:(nullable NSSet<NSString *> *)allowedIDs
                                                viewportY:(CGFloat *)outViewportY {
    [self.tableView layoutIfNeeded];
    NSArray<NSIndexPath *> *visibleIndexPaths =
        [[self.tableView indexPathsForVisibleRows]
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *indexPath in visibleIndexPaths) {
        NSString *messageID = [self.dataSource itemIdentifierForIndexPath:indexPath];
        if (messageID.length == 0 || (allowedIDs && ![allowedIDs containsObject:messageID])) continue;
        CGRect rowRect = [self.tableView rectForRowAtIndexPath:indexPath];
        if (outViewportY) {
            *outViewportY = CGRectGetMinY(rowRect) - self.tableView.contentOffset.y;
        }
        return [messageID copy];
    }
    return nil;
}

- (void)s7tv_restoreVisibleAnchorID:(nullable NSString *)messageID viewportY:(CGFloat)viewportY {
    if (messageID.length == 0) return;
    NSIndexPath *indexPath = [self.dataSource indexPathForItemIdentifier:messageID];
    if (!indexPath) return;

    [self.tableView layoutIfNeeded];
    CGRect rowRect = [self.tableView rectForRowAtIndexPath:indexPath];
    CGFloat targetY = CGRectGetMinY(rowRect) - viewportY;
    CGFloat minimumY = -self.tableView.adjustedContentInset.top;
    CGFloat maximumY = MAX(minimumY,
        self.tableView.contentSize.height - self.tableView.bounds.size.height +
        self.tableView.adjustedContentInset.bottom);
    CGPoint offset = self.tableView.contentOffset;
    offset.y = MIN(maximumY, MAX(minimumY, targetY));
    [self.tableView setContentOffset:offset animated:NO];
}

- (void)s7tv_queueFullReloadAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.reloadDeferredUntilScrollEnds = YES;
    self.deferredReloadAnimated = self.deferredReloadAnimated || animated;
    if (completion) [self.deferredReloadCompletions addObject:[completion copy]];
}

- (void)s7tv_recordFrozenStoreMessages {
    NSArray<S7TVChatMessage *> *storeMessages = [self.store allMessages];
    NSMutableSet<NSString *> *currentStoreIDs =
        [NSMutableSet setWithCapacity:storeMessages.count];
    NSUInteger newlyObserved = 0;
    for (S7TVChatMessage *message in storeMessages) {
        if (!message.messageID.length) continue;
        [currentStoreIDs addObject:message.messageID];
        if (![self.lastObservedStoreMessageIDs containsObject:message.messageID]) newlyObserved++;
    }
    self.lastObservedStoreMessageIDs = [currentStoreIDs copy];
    if (newlyObserved > 0) self.pendingNewMessagesCount += newlyObserved;
    [self s7tv_updateNewMessagesBannerText];
    [self s7tv_showNewMessagesBanner];
}

- (void)s7tv_finishSnapshotApply {
    self.snapshotApplyInProgress = NO;
    if (self.widthReloadPending) {
        self.widthReloadPending = NO;
        [self.tableView reloadData];
        [self.tableView layoutIfNeeded];
    }
}

- (void)s7tv_flushDeferredReloadIfNeeded {
    BOOL tableInteractionActive = self.tableView.isTracking || self.tableView.isDragging ||
        self.tableView.isDecelerating;
    if (self.snapshotApplyInProgress || self.messageInteractionInProgress ||
        tableInteractionActive) return;

    // Le gel protège uniquement l'ordre et les IDs du transcript. Une cellule
    // déjà visible doit continuer à se reconfigurer (modération, image chargée,
    // favori), sinon son modèle change sans aucun retour visuel.
    if (self.transcriptFrozen) {
        [self s7tv_flushDeferredMessageReloads];
        return;
    }

    if (!self.reloadDeferredUntilScrollEnds) {
        [self s7tv_flushDeferredMessageReloads];
        return;
    }
    self.reloadDeferredUntilScrollEnds = NO;
    BOOL animated = self.deferredReloadAnimated;
    self.deferredReloadAnimated = NO;
    NSArray *completions = [self.deferredReloadCompletions copy];
    [self.deferredReloadCompletions removeAllObjects];

    [self s7tv_reloadMessagesAnimated:animated completion:^{
        [self s7tv_flushDeferredMessageReloads];
        for (id completionObject in completions) {
            void (^deferredCompletion)(void) = (void (^)(void))completionObject;
            if (deferredCompletion) deferredCompletion();
        }
    }];
}

- (void)s7tv_flushDeferredMessageReloads {
    if (self.deferredMessageReloadIDs.count == 0) return;
    if (self.snapshotApplyInProgress || self.messageInteractionInProgress ||
        self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating) return;
    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot = [self.dataSource snapshot];
    NSSet<NSString *> *snapshotIDs = [NSSet setWithArray:snapshot.itemIdentifiers];
    NSMutableArray<NSString *> *reloadIDs = [NSMutableArray array];
    for (NSString *messageID in self.deferredMessageReloadIDs) {
        if ([snapshotIDs containsObject:messageID] && self.messagesByID[messageID]) {
            [reloadIDs addObject:messageID];
        }
    }
    NSArray *completions = [self.deferredMessageReloadCompletions copy];
    [self.deferredMessageReloadCompletions removeAllObjects];
    [self.deferredMessageReloadIDs removeAllObjects];
    self.deferredMessageReloadAnimated = NO;
    if (reloadIDs.count == 0) {
        for (id completionObject in completions) {
            void (^deferredCompletion)(void) = (void (^)(void))completionObject;
            if (deferredCompletion) deferredCompletion();
        }
        return;
    }

    CGFloat anchorY = 0;
    NSString *anchorID = self.isPinnedToBottom ? nil
        : [self s7tv_captureVisibleAnchorAmongIDs:nil viewportY:&anchorY];
    [snapshot reloadItemsWithIdentifiers:reloadIDs];
    __weak typeof(self) weakSelf = self;
    self.snapshotApplyInProgress = YES;
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf s7tv_finishSnapshotApply];
        [strongSelf s7tv_restoreVisibleAnchorID:anchorID viewportY:anchorY];
        for (id completionObject in completions) {
            void (^deferredCompletion)(void) = (void (^)(void))completionObject;
            if (deferredCompletion) deferredCompletion();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf s7tv_flushDeferredReloadIfNeeded];
        });
    }];
}

- (void)s7tv_reloadMessagesAnimated:(BOOL)animated
                          completion:(void (^)(void))completion {
    NSAssert([NSThread isMainThread],
             @"reloadMessages doit être appelé depuis le main thread (touche UIKit)");

    NSUInteger currentStoreGeneration = [self.store generation];
    if (self.transcriptFrozen && self.lastObservedStoreGeneration != 0 &&
        currentStoreGeneration != self.lastObservedStoreGeneration) {
        // Un changement de chaîne / remplacement global doit toujours gagner
        // sur le gel local, sinon l'ancienne chaîne resterait visible jusqu'au
        // retour manuel en bas.
        self.transcriptFrozen = NO;
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];

        NSArray *queuedCompletions = [self.deferredReloadCompletions copy];
        [self.deferredReloadCompletions removeAllObjects];
        BOOL queuedAnimated = self.deferredReloadAnimated;
        self.reloadDeferredUntilScrollEnds = NO;
        self.deferredReloadAnimated = NO;
        void (^requestedCompletion)(void) = [completion copy];
        completion = ^{
            if (requestedCompletion) requestedCompletion();
            for (id completionObject in queuedCompletions) {
                void (^queuedCompletion)(void) = (void (^)(void))completionObject;
                if (queuedCompletion) queuedCompletion();
            }
        };
        animated = animated || queuedAnimated;
    }

    if (self.transcriptFrozen) {
        [self s7tv_recordFrozenStoreMessages];
        [self s7tv_queueFullReloadAnimated:animated completion:completion];
        return;
    }

    // Ne jamais modifier la structure diffable pendant que le doigt/l'inertie
    // pilote encore la table ou qu'un appui long sélectionne son contenu :
    // UIKit et notre restauration d'ancre corrigeraient alors simultanément
    // le contentOffset. Les messages restent reçus dans le store ; un seul
    // snapshot de rattrapage est appliqué à la fin de l'interaction.
    BOOL tableInteractionActive = self.tableView.isTracking || self.tableView.isDragging ||
        self.tableView.isDecelerating;
    if (self.snapshotApplyInProgress || self.messageInteractionInProgress ||
        tableInteractionActive) {
        [self s7tv_queueFullReloadAnimated:animated completion:completion];
        return;
    }

    NSArray<S7TVChatMessage *> *newMessages = [self.store allMessages];

    BOOL wasNearBottom = (self.displayedMessages.count == 0) || self.isPinnedToBottom;

    // Quand le store atteint sa limite (300 messages), chaque nouveau message
    // retire le plus ancien. Conserver seulement le contentOffset ne suffit
    // pas : la suppression d'une ligne au-dessus du viewport fait remonter
    // visuellement tout ce que l'utilisateur lit. On mémorise donc un message
    // visible qui survivra au nouveau snapshot ainsi que sa position exacte
    // dans le viewport, puis on le replacera au même endroit après le diff.
    NSString *visibleAnchorID = nil;
    CGFloat visibleAnchorViewportY = 0.0;
    if (!wasNearBottom && self.displayedMessages.count > 0) {
        NSMutableSet<NSString *> *newIDSet =
            [NSMutableSet setWithCapacity:newMessages.count];
        for (S7TVChatMessage *message in newMessages) {
            if (message.messageID) [newIDSet addObject:message.messageID];
        }

        visibleAnchorID = [self s7tv_captureVisibleAnchorAmongIDs:newIDSet
                                                        viewportY:&visibleAnchorViewportY];
    }

    NSMutableSet<NSString *> *oldIDs = [NSMutableSet setWithCapacity:self.displayedMessages.count];
    NSMutableArray<NSString *> *oldIdentifiers =
        [NSMutableArray arrayWithCapacity:self.displayedMessages.count];
    for (S7TVChatMessage *m in self.displayedMessages) {
        if (!m.messageID) continue;
        [oldIDs addObject:m.messageID];
        [oldIdentifiers addObject:m.messageID];
    }

    NSMutableDictionary<NSString *, S7TVChatMessage *> *byID =
        [NSMutableDictionary dictionaryWithCapacity:newMessages.count];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:newMessages.count];
    NSUInteger newlyAddedCount = 0;
    for (S7TVChatMessage *m in newMessages) {
        byID[m.messageID] = m;
        [identifiers addObject:m.messageID];
        if (!wasNearBottom && ![oldIDs containsObject:m.messageID]) newlyAddedCount++;
    }
    self.displayedMessages = newMessages;
    // Pendant applySnapshot, UIKit peut encore demander une cellule d'un ID
    // en cours de suppression. Conserver temporairement l'union des anciens
    // et nouveaux modèles évite une cellule blanche/fuyante durant ce court
    // passage ; la map exacte est rétablie dans la completion ci-dessous.
    NSMutableDictionary<NSString *, S7TVChatMessage *> *renderModels =
        [self.messagesByID mutableCopy] ?: [NSMutableDictionary dictionary];
    [renderModels addEntriesFromDictionary:byID];
    self.messagesByID = renderModels;
    self.lastObservedStoreMessageIDs = [NSSet setWithArray:identifiers];
    self.lastObservedStoreGeneration = currentStoreGeneration;

    if (wasNearBottom) {
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];
    } else {
        if (newlyAddedCount > 0) self.pendingNewMessagesCount += newlyAddedCount;
        [self s7tv_updateNewMessagesBannerText];
        [self s7tv_showNewMessagesBanner];
    }

    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot =
        [[NSDiffableDataSourceSnapshot alloc] init];
    [snapshot appendSectionsWithIdentifiers:@[@"main"]];
    [snapshot appendItemsWithIdentifiers:identifiers intoSectionWithIdentifier:@"main"];
    BOOL identifiersUnchanged = [oldIdentifiers isEqualToArray:identifiers];
    if (identifiersUnchanged) {
        // Un snapshot sans changement structurel correspond à une vraie
        // invalidation de contenu/apparence : reconfigurer les messages.
        [snapshot reloadItemsWithIdentifiers:identifiers];
    } else if (animated) {
        // Les mutations de modération peuvent coïncider avec une arrivée IRC.
        // Recharger uniquement les IDs conservés, jamais les nouveaux items.
        NSMutableArray<NSString *> *retainedIDs = [NSMutableArray array];
        for (NSString *messageID in identifiers) {
            if ([oldIDs containsObject:messageID]) [retainedIDs addObject:messageID];
        }
        if (retainedIDs.count) [snapshot reloadItemsWithIdentifiers:retainedIDs];
    }

    __weak typeof(self) weakSelf = self;
    self.snapshotApplyInProgress = YES;
    // Avec UITableViewAutomaticDimension, une animation diffable et le
    // recalcul de hauteur d'une ligne ne progressent pas toujours au même
    // rythme : l'ancienne et la nouvelle cellule peuvent alors se chevaucher
    // pendant la transition (~0,3-0,5 s). Le chat privilégie une mise à jour
    // atomique ; les animations des emotes restent naturellement actives.
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO completion:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            if (completion) completion();
            return;
        }
        [self s7tv_finishSnapshotApply];
        self.messagesByID = byID;

        if (!wasNearBottom && visibleAnchorID.length > 0) {
            [self s7tv_restoreVisibleAnchorID:visibleAnchorID
                                   viewportY:visibleAnchorViewportY];
        }

        [self s7tv_scrollToBottomIfNeeded:wasNearBottom];
        if (completion) completion();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self s7tv_flushDeferredReloadIfNeeded];
        });
    }];
}

- (void)s7tv_scrollToBottomIfNeeded:(BOOL)wasNearBottom {
    if (!self.automaticallyScrollsToBottom) return;
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
    // Un contenu supprimé, même révélé volontairement, ne conserve pas les
    // accents système/mention : l'atténuation doit rester le signal visuel
    // prioritaire et ne pas être confondue avec un message encore actif.
    if (msg.state == S7TVChatMessageStateNormal &&
        msg.type == S7TVChatMessageTypeChannelPointRedemption &&
        msg.channelPointRewardInfo) {
        [cell s7tv_configureChannelPointAccent];
    } else if (msg.state == S7TVChatMessageStateNormal &&
        msg.type == S7TVChatMessageTypeSystem && msg.systemInfo) {
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
                                 backgroundEnabled:cfg.systemMessageBackgroundsEnabled
                                highlightBadgeText:nil];
    } else if (msg.state == S7TVChatMessageStateNormal &&
               msg.isFirstMessage && cfg.showFirstMessageBadge) {
        // Même composant que "TE MENTIONNE", seule la couleur et le texte
        // changent. FIRST MESSAGE gagne si les deux flags sont présents.
        [cell s7tv_configureSystemAccentWithColor:cfg.firstMessageHighlightColor
                                          iconName:nil
                                 backgroundEnabled:YES
                               highlightBadgeText:L(@"first_message_badge_label")];
    } else if (msg.state == S7TVChatMessageStateNormal &&
               msg.mentionsCurrentViewer && cfg.selfMentionHighlightEnabled) {
        // Réutilise exactement le même mécanisme que les messages système
        // (barre d'accent + fond teinté à 12%) — voir
        // s7tv_configureSystemAccentWithColor:iconName:backgroundEnabled:highlightBadgeText:.
        // Pas d'icône (nil) : ce n'est pas un type de message, juste un
        // surlignage. backgroundEnabled toujours YES ici (pas de fond neutre
        // de repli comme pour systemMessageBackgroundsEnabled) — le toggle
        // cfg.selfMentionHighlightEnabled fait déjà tout ou rien au-dessus.
        // highlightBadgeText : ajoute la barre miroir à droite + le petit
        // label "TE MENTIONNE"/"MENTIONS YOU" propres à ce cas.
        [cell s7tv_configureSystemAccentWithColor:cfg.selfMentionHighlightColor
                                          iconName:nil
                                 backgroundEnabled:YES
                               highlightBadgeText:L(@"mention_badge_label")];
    } else {
        [cell s7tv_configureSystemAccentWithColor:nil iconName:nil backgroundEnabled:NO
                                highlightBadgeText:nil];
    }
    cell.messageLabel.attributedText = text;
    // L'atténuation d'un message supprimé révélé est appliquée aux
    // attributs du CORPS seulement (voir s7tv_appendNormalBodyForMessage:).
    // Le label reste opaque afin que pseudo et badges gardent leurs couleurs.
    cell.messageLabel.alpha = 1.0;
    [cell s7tv_setHistoryDividerEnabled:msg.type == S7TVChatMessageTypeHistoryDivider];
    // cfg.lineSpacing = espacement ENTRE deux messages (voir
    // 7tv-chat-appearance-config.h). Avec les self-sizing cells, il n'y a
    // plus de calcul de hauteur externe où l'ajouter (voir
    // tableView.rowHeight = UITableViewAutomaticDimension) — c'est donc ici,
    // en l'ajoutant au constant de la contrainte de bas de label, qu'il doit
    // être appliqué, puisque cette contrainte contribue directement à la
    // hauteur intrinsèque que UIKit va lire pour dimensionner la cellule.
    BOOL isChannelPointCard = msg.state == S7TVChatMessageStateNormal &&
        msg.type == S7TVChatMessageTypeChannelPointRedemption &&
        msg.channelPointRewardInfo != nil;
    CGFloat bottomPadding = isChannelPointCard ? 9.0 : 4.0;
    cell.messageLabelBottomConstraint.constant = -(bottomPadding + cfg.lineSpacing);
}

- (void)s7tv_observeAnimationsForCell:(S7TVChatCustomCell *)cell {
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    [engine removeObserver:cell.messageLabel];
    if (self.renderingSuspended || cell.animationKeys.count == 0 || !cell.window) return;
    __weak UILabel *weakLabel = cell.messageLabel;
    [engine addObserver:cell.messageLabel keys:cell.animationKeys redraw:^{
        [weakLabel setNeedsDisplay];
    }];
    // Pose immédiatement la frame déjà courante, sans attendre son prochain
    // changement — utile quand une cellule revient dans le viewport.
    [cell.messageLabel setNeedsDisplay];
}

- (UITableViewCell *)s7tv_cellForMessageID:(NSString *)messageID
                                atIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"cell"
                                                                     forIndexPath:indexPath];
    // Une reconfiguration diffable d'une cellule encore visible ne passe pas
    // forcément par prepareForReuse. Toujours détacher son ancien pipeline.
    [cell s7tv_cancelAnimationFrameRequests];
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:cell.messageLabel];
    S7TVChatMessage *msg = self.messagesByID[messageID];
    if (!msg) {
        // Une ancienne cellule ne doit jamais "fuir" dans la courte fenêtre
        // où un snapshot diffable et sa map de modèles se croisent.
        cell.onReplyBannerTap = nil;
        cell.onDeletedMessageTap = nil;
        cell.animationKeys = nil;
        cell.messageLabel.attributedText = [[NSAttributedString alloc] initWithString:@""];
        cell.messageLabel.alpha = 1.0;
        [cell s7tv_configureReplyBannerWithUsername:nil bodyPreview:nil];
        [cell s7tv_setThreadIndentEnabled:NO];
        [cell s7tv_setHistoryDividerEnabled:NO];
        [cell s7tv_configureSystemAccentWithColor:nil iconName:nil backgroundEnabled:NO
                                highlightBadgeText:nil];
        cell.messageLabelBottomConstraint.constant = -4.0;
        return cell;
    }

    NSMutableArray<id<S7TVResolvedEmote>> *uncachedEmotes = [NSMutableArray array];
    NSMutableArray<id<S7TVResolvedEmote>> *animatedEmotes = [NSMutableArray array];
    NSAttributedString *text = [self s7tv_buildAttributedStringForMessage:msg
                                                      collectUncachedEmotes:uncachedEmotes
                                                      collectAnimatedEmotes:animatedEmotes];
    [self s7tv_configureCell:cell forMessage:msg attributedText:text];

    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    BOOL isCollapsed = s7tv_shouldRenderDeletedCollapsed(msg, cfg);
    BOOL isReply = self.showsReplyBanners && !isCollapsed && msg.replyParentUsername.length > 0;
    [cell s7tv_configureReplyBannerWithUsername:isReply ? msg.replyParentUsername : nil
                                     bodyPreview:isReply ? msg.replyParentBodyPreview : nil];

    NSString *threadRootID = self.showsReplyBanners ? msg.replyThreadRootID : nil;
    NSString *tappedMessageID = msg.messageID;
    __weak typeof(self) weakSelfForReply = self;
    cell.onReplyBannerTap = threadRootID.length ? ^{
        __strong typeof(weakSelfForReply) strongSelf = weakSelfForReply;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(chatCustomView:didTapReplyBannerForThreadRootID:tappedMessageID:)]) {
            [strongSelf.delegate chatCustomView:strongSelf
              didTapReplyBannerForThreadRootID:threadRootID
                                 tappedMessageID:tappedMessageID];
        }
    } : nil;

    BOOL isDeleted = s7tv_isDeletedMessage(msg);
    BOOL allowsTapToReveal = isDeleted &&
        cfg.deletedMessageRevealMode == S7TVDeletedMessageRevealModeOnTap;
    NSString *deletedMessageID = msg.messageID;
    S7TVChatMessage *deletedMessage = msg;
    __weak typeof(self) weakSelfForDeletion = self;
    cell.onDeletedMessageTap = allowsTapToReveal ? ^{
        __strong typeof(weakSelfForDeletion) strongSelf = weakSelfForDeletion;
        if (!strongSelf) return;

        // Dans un thread, les modèles proviennent du store principal. Dans un
        // transcript principal figé, le modèle peut au contraire avoir déjà
        // quitté son FIFO. La variante objet choisit atomiquement le modèle
        // indexé quand il existe, puis retombe sur l'objet encore affiché.
        S7TVChatMessageStore *mainStore = [SevenTVManager sharedManager].chatMessageStore;
        S7TVChatMessageStore *mutationStore = [mainStore messageWithID:deletedMessageID]
            ? mainStore : strongSelf.store;
        [mutationStore toggleExpandedForMessage:deletedMessage completion:^(S7TVChatMessage *updated) {
            __strong typeof(weakSelfForDeletion) innerSelf = weakSelfForDeletion;
            if (!innerSelf) return;
            NSString *mode = (updated.state == S7TVChatMessageStateDeletedExpanded)
                ? @"révélé" : @"masqué";
            [[SevenTVManager sharedManager]
                log:@"🛡 Message supprimé %@ localement (id=%@)",
                    mode, deletedMessageID];
            s7tv_applyModerationStateToRetainedMessage(
                deletedMessageID, updated.state, updated.moderationKind,
                updated.moderationDurationSeconds);
            [innerSelf refreshMessageWithID:deletedMessageID animated:YES completion:^{
                SevenTVChatCustomView *activeView = s7tv_activeChatCustomView();
                if (activeView && activeView != innerSelf) {
                    [activeView refreshMessageWithID:deletedMessageID animated:YES];
                }
                // Cette completion correspond au vrai applySnapshot : le
                // panneau peut maintenant mesurer la nouvelle hauteur sans
                // timer arbitraire ni clignotement.
                [[S7TVReplyThreadPanel sharedPanel]
                    refreshMessageIfNeededWithID:deletedMessageID excludingView:innerSelf];
            }];
        }];
    } : nil;

    [cell s7tv_setThreadIndentEnabled:self.usesThreadReplyIndent];

    if (!self.renderingSuspended && animatedEmotes.count > 0) {
        NSMutableSet<NSString *> *animationKeys = [NSMutableSet setWithCapacity:animatedEmotes.count];
        NSMutableArray<S7TVEmoteFrameRequest *> *frameRequests = [NSMutableArray array];
        SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
        SevenTVEmoteImageCache *imgCache = [SevenTVEmoteImageCache sharedCache];
        for (id<S7TVResolvedEmote> emote in animatedEmotes) {
            NSString *key = emote.imageURL.absoluteString;
            if (!key.length || [animationKeys containsObject:key]) continue;
            [animationKeys addObject:key];
            if ([engine hasCompleteFramesForKey:key]) continue;
            S7TVEmoteAnimatedFrames *cachedFrames = [imgCache cachedFramesForResolvedEmote:emote];
            if (cachedFrames) {
                [engine registerFrames:cachedFrames forKey:key];
            } else {
                // Même demande annulable que le picker : une cellule partie
                // de l'écran ne laisse aucun décodage inutile dans la file.
                // La preview démarre vite ; la boucle complète la remplace
                // ensuite dans le moteur partagé sans dupliquer le renderer.
                S7TVEmoteFrameRequest *request = [imgCache framesForResolvedEmote:emote
                    preview:^(S7TVEmoteAnimatedFrames *previewFrames) {
                        if (![engine hasCompleteFramesForKey:key]) {
                            [engine registerFrames:previewFrames forKey:key];
                        }
                    }
                    completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
                        if (frames) [engine registerFrames:frames forKey:key];
                    }];
                if (request) [frameRequests addObject:request];
            }
        }
        cell.animationKeys = animationKeys;
        cell.animationFrameRequests = frameRequests;
    } else {
        cell.animationKeys = nil;
        cell.animationFrameRequests = nil;
    }

    if (!self.renderingSuspended && cell.window) [self s7tv_observeAnimationsForCell:cell];

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];
    __weak typeof(self) weakSelf = self;
    if (self.renderingSuspended) return cell;
    for (id<S7TVResolvedEmote> emote in uncachedEmotes) {
        [imageCache imageForResolvedEmote:emote completion:^(UIImage * _Nullable image) {
            if (!image) return;
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.renderingSuspended) return;
            NSIndexPath *path = [strongSelf.dataSource indexPathForItemIdentifier:messageID];
            // Hors écran, aucun snapshot n'est nécessaire : l'image est déjà
            // en cache et sera utilisée naturellement au prochain cellFor.
            // Cela évite des rechargements visuels tardifs pour des cellules
            // que l'utilisateur a quittées depuis longtemps.
            if (!path || ![[strongSelf.tableView indexPathsForVisibleRows] containsObject:path]) return;
            [strongSelf s7tv_reloadMessageWithID:messageID];
        }];
    }

    return cell;
}

- (void)s7tv_reloadMessageWithID:(NSString *)messageID {
    [self s7tv_reloadMessageWithID:messageID animated:NO completion:nil];
}

- (void)refreshMessageWithID:(NSString *)messageID animated:(BOOL)animated {
    [self refreshMessageWithID:messageID animated:animated completion:nil];
}

- (void)refreshMessageWithID:(NSString *)messageID
                    animated:(BOOL)animated
                  completion:(void (^)(void))completion {
    [self s7tv_reloadMessageWithID:messageID animated:animated completion:completion];
}

- (S7TVChatMessage *)displayedMessageWithID:(NSString *)messageID {
    return messageID.length ? self.messagesByID[messageID] : nil;
}

- (NSArray<S7TVChatMessage *> *)displayedMessagesForThreadRootID:(NSString *)threadRootID {
    if (!threadRootID.length) return @[];
    NSMutableArray<S7TVChatMessage *> *messages = [NSMutableArray array];
    for (S7TVChatMessage *message in self.displayedMessages) {
        if ([message.messageID isEqualToString:threadRootID] ||
            [message.replyThreadRootID isEqualToString:threadRootID]) {
            [messages addObject:message];
        }
    }
    return messages;
}

- (void)applyModerationState:(S7TVChatMessageState)state
  toDisplayedMessageWithID:(NSString *)messageID
             moderationKind:(S7TVChatModerationKind)moderationKind
            durationSeconds:(NSInteger)durationSeconds {
    NSAssert(NSThread.isMainThread, @"La modération d'une vue touche son snapshot UIKit");
    S7TVChatMessage *message = messageID.length ? self.messagesByID[messageID] : nil;
    if (!message) return;
    [message applyModerationState:state
                  moderationKind:moderationKind
                 durationSeconds:durationSeconds];
}

- (void)applyModerationToDisplayedMessagesForUserID:(NSString *)authorUserID
                                        authorLogin:(NSString *)authorLogin
                                      moderationKind:(S7TVChatModerationKind)moderationKind
                                     durationSeconds:(NSInteger)durationSeconds {
    NSAssert(NSThread.isMainThread, @"La modération d'une vue touche son snapshot UIKit");
    if (!authorUserID.length && !authorLogin.length) return;
    for (S7TVChatMessage *message in self.messagesByID.allValues) {
        BOOL matchesUserID = authorUserID.length &&
            [message.authorUserID isEqualToString:authorUserID];
        BOOL matchesFallbackLogin = !message.authorUserID.length && authorLogin.length &&
            [message.authorDisplayName caseInsensitiveCompare:authorLogin] == NSOrderedSame;
        if (!matchesUserID && !matchesFallbackLogin) continue;
        [message applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:moderationKind
                      durationSeconds:durationSeconds];
    }
}

- (void)applyModerationToAllDisplayedMessages {
    NSAssert(NSThread.isMainThread, @"La modération d'une vue touche son snapshot UIKit");
    for (S7TVChatMessage *message in self.messagesByID.allValues) {
        if (message.type == S7TVChatMessageTypeHistoryWelcome ||
            message.type == S7TVChatMessageTypeHistoryDivider) continue;
        [message applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:S7TVChatModerationKindChatCleared
                      durationSeconds:0];
    }
}

- (void)s7tv_reloadMessageWithID:(NSString *)messageID
                        animated:(BOOL)animated
                      completion:(void (^)(void))completion {
    if (!self.messagesByID[messageID]) {
        if (completion) completion();
        return;
    }
    BOOL tableInteractionActive = self.tableView.isTracking || self.tableView.isDragging ||
        self.tableView.isDecelerating;
    if (self.snapshotApplyInProgress || self.messageInteractionInProgress ||
        tableInteractionActive) {
        [self.deferredMessageReloadIDs addObject:messageID];
        self.deferredMessageReloadAnimated = self.deferredMessageReloadAnimated || animated;
        if (completion) [self.deferredMessageReloadCompletions addObject:[completion copy]];
        return;
    }

    CGFloat anchorY = 0;
    NSString *anchorID = self.isPinnedToBottom ? nil
        : [self s7tv_captureVisibleAnchorAmongIDs:nil viewportY:&anchorY];
    NSDiffableDataSourceSnapshot<NSString *, NSString *> *snapshot = [self.dataSource snapshot];
    if (![snapshot.itemIdentifiers containsObject:messageID]) {
        if (completion) completion();
        return;
    }
    [snapshot reloadItemsWithIdentifiers:@[messageID]];
    __weak typeof(self) weakSelf = self;
    self.snapshotApplyInProgress = YES;
    // Une image ou une modération peut modifier la hauteur self-sizing de la
    // ligne. Appliquer atomiquement évite le bref chevauchement UIKit.
    [self.dataSource applySnapshot:snapshot animatingDifferences:NO completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf s7tv_finishSnapshotApply];
        [strongSelf s7tv_restoreVisibleAnchorID:anchorID viewportY:anchorY];
        if (completion) completion();
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf s7tv_flushDeferredReloadIfNeeded];
        });
    }];
}

#pragma mark - UITableViewDelegate

- (void)s7tv_dismissEmotePreview {
    [self.emotePreviewFrameRequest cancel];
    self.emotePreviewFrameRequest = nil;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:self.emotePreviewImageView];
    [self.emotePreviewOverlay removeFromSuperview];
    self.emotePreviewOverlay = nil;
    self.previewedEmoteToken = nil;
    self.emotePreviewImageView = nil;
    self.emotePreviewFavoriteButton = nil;
}

- (void)s7tv_observeAnimatedEmotePreview:(id<S7TVResolvedEmote>)emote {
    UIImageView *imageView = self.emotePreviewImageView;
    NSString *animationKey = [emote.imageURL.absoluteString copy];
    if (!emote.isAnimated || !imageView || !animationKey.length) return;

    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    __weak typeof(self) weakSelf = self;
    __weak UIImageView *weakImageView = imageView;
    [engine addObserver:imageView keys:[NSSet setWithObject:animationKey] redraw:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UIImageView *strongImageView = weakImageView;
        if (!strongSelf || !strongImageView ||
            strongSelf.emotePreviewImageView != strongImageView) return;
        NSString *currentKey = strongSelf.previewedEmoteToken.resolvedEmote.imageURL.absoluteString;
        if (![currentKey isEqualToString:animationKey]) return;
        UIImage *frame = [[SevenTVEmoteAnimationEngine sharedEngine]
            currentFrameForKey:animationKey];
        if (frame) strongImageView.image = frame;
    }];

    UIImage *currentFrame = [engine currentFrameForKey:animationKey];
    if (currentFrame) imageView.image = currentFrame;
    if ([engine hasCompleteFramesForKey:animationKey]) return;

    SevenTVEmoteImageCache *imageCache = [SevenTVEmoteImageCache sharedCache];
    S7TVEmoteAnimatedFrames *cachedFrames = [imageCache cachedFramesForResolvedEmote:emote];
    if (cachedFrames) {
        [engine registerFrames:cachedFrames forKey:animationKey];
        return;
    }

    // Même pipeline que les cellules du chat : preview légère puis boucle
    // complète, toutes deux enregistrées dans l'unique moteur partagé.
    self.emotePreviewFrameRequest = [imageCache framesForResolvedEmote:emote
        preview:^(S7TVEmoteAnimatedFrames *previewFrames) {
            if (![engine hasCompleteFramesForKey:animationKey]) {
                [engine registerFrames:previewFrames forKey:animationKey];
            }
        }
        completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
            if (frames) [engine registerFrames:frames forKey:animationKey];
        }];
}

- (void)s7tv_refreshEmotePreviewFavoriteState {
    NSString *emoteID = self.previewedEmoteToken.providerEmoteID;
    BOOL favorited = [[SevenTVManager sharedManager] isEmoteFavorited:emoteID];
    UIImageSymbolConfiguration *starConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    NSString *symbolName = favorited ? @"star.fill" : @"star";
    [self.emotePreviewFavoriteButton
        setImage:[UIImage systemImageNamed:symbolName withConfiguration:starConfig]
        forState:UIControlStateNormal];
    self.emotePreviewFavoriteButton.accessibilityLabel = favorited
        ? L(@"chat_emote_remove_favorite") : L(@"chat_emote_add_favorite");
}

- (void)s7tv_togglePreviewedEmoteFavorite {
    S7TVChatToken *token = self.previewedEmoteToken;
    if (token.type != S7TVChatTokenTypeEmote7TV || !token.providerEmoteID.length) return;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    BOOL wasFavorited = [manager isEmoteFavorited:token.providerEmoteID];
    [manager setEmote:token.providerEmoteID favorited:!wasFavorited];
    NSString *logFormat = wasFavorited ? @"💔 Favori retiré depuis le chat : %@"
                                         : @"⭐ Favori ajouté depuis le chat : %@";
    [manager log:logFormat, token.text ?: token.providerEmoteID];
    [self s7tv_refreshEmotePreviewFavoriteState];

    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)s7tv_showEmotePreviewForToken:(S7TVChatToken *)token
                        atWindowPoint:(CGPoint)windowPoint {
    if (token.type != S7TVChatTokenTypeEmote7TV ||
        !token.providerEmoteID.length || !token.resolvedEmote) return;

    UIWindow *window = self.window;
    if (!window) return;
    [self s7tv_dismissEmotePreview];
    [[window viewWithTag:kS7TVChatEmotePreviewOverlayTag] removeFromSuperview];

    UIControl *overlay = [[UIControl alloc] initWithFrame:window.bounds];
    overlay.tag = kS7TVChatEmotePreviewOverlayTag;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.10];
    [overlay addTarget:self action:@selector(s7tv_dismissEmotePreview)
      forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:overlay];
    self.emotePreviewOverlay = overlay;
    self.previewedEmoteToken = token;

    const CGFloat cardWidth = 158.0;
    const CGFloat cardHeight = 150.0;
    UIEdgeInsets safeInsets = window.safeAreaInsets;
    CGFloat minX = safeInsets.left + 8.0;
    CGFloat maxX = window.bounds.size.width - safeInsets.right - cardWidth - 8.0;
    CGFloat cardX = MIN(MAX(windowPoint.x - cardWidth * 0.5, minX), MAX(minX, maxX));
    CGFloat minY = safeInsets.top + 8.0;
    CGFloat maxY = window.bounds.size.height - safeInsets.bottom - cardHeight - 8.0;
    CGFloat cardY = windowPoint.y - cardHeight - 12.0;
    if (cardY < minY) cardY = windowPoint.y + 12.0;
    cardY = MIN(MAX(cardY, minY), MAX(minY, maxY));

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardWidth, cardHeight)];
    card.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    card.layer.cornerRadius = 11.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.35;
    card.layer.shadowRadius = 8.0;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    [overlay addSubview:card];

    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:imageView];
    self.emotePreviewImageView = imageView;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.text = token.text ?: @"";
    nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:nameLabel];

    UIButton *favoriteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    favoriteButton.translatesAutoresizingMaskIntoConstraints = NO;
    favoriteButton.tintColor = [UIColor colorWithRed:0.65 green:0.45 blue:1.0 alpha:1.0];
    favoriteButton.backgroundColor = [UIColor clearColor];
    [favoriteButton addTarget:self action:@selector(s7tv_togglePreviewedEmoteFavorite)
             forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:favoriteButton];
    self.emotePreviewFavoriteButton = favoriteButton;

    [NSLayoutConstraint activateConstraints:@[
        [imageView.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [imageView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [imageView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [imageView.heightAnchor constraintEqualToConstant:96],

        [nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:favoriteButton.leadingAnchor constant:-8],
        [nameLabel.centerYAnchor constraintEqualToAnchor:favoriteButton.centerYAnchor],

        [favoriteButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10],
        [favoriteButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
        [favoriteButton.widthAnchor constraintEqualToConstant:26],
        [favoriteButton.heightAnchor constraintEqualToConstant:26],
    ]];

    id<S7TVResolvedEmote> emote = token.resolvedEmote;
    UIImage *previewImage = nil;
    if (emote.isAnimated) {
        previewImage = [[SevenTVEmoteAnimationEngine sharedEngine]
            currentFrameForKey:emote.imageURL.absoluteString];
    }
    if (!previewImage) {
        previewImage = [[SevenTVEmoteImageCache sharedCache] cachedImageForResolvedEmote:emote];
    }
    imageView.image = previewImage;
    if (!previewImage) {
        NSString *expectedEmoteID = [token.providerEmoteID copy];
        __weak typeof(self) weakSelf = self;
        [[SevenTVEmoteImageCache sharedCache] imageForResolvedEmote:emote
            completion:^(UIImage * _Nullable image) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf ||
                ![strongSelf.previewedEmoteToken.providerEmoteID isEqualToString:expectedEmoteID]) return;
            id<S7TVResolvedEmote> currentEmote = strongSelf.previewedEmoteToken.resolvedEmote;
            UIImage *currentFrame = currentEmote.isAnimated
                ? [[SevenTVEmoteAnimationEngine sharedEngine]
                    currentFrameForKey:currentEmote.imageURL.absoluteString]
                : nil;
            strongSelf.emotePreviewImageView.image = currentFrame ?: image;
        }];
    }

    [self s7tv_observeAnimatedEmotePreview:emote];

    [self s7tv_refreshEmotePreviewFavoriteState];
    [window bringSubviewToFront:overlay];
}

- (void)s7tv_handleMessageLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        self.messageInteractionInProgress = NO;
        [self s7tv_flushDeferredReloadIfNeeded];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    self.messageInteractionInProgress = YES;

    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;

    NSString *messageID = [self.dataSource itemIdentifierForIndexPath:indexPath];
    S7TVChatMessage *message = self.messagesByID[messageID];

    S7TVChatCustomCell *cell = (S7TVChatCustomCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    CGPoint labelPoint = cell ? [gesture locationInView:cell.messageLabel] : CGPointZero;
    NSUInteger characterIndex = cell
        ? [cell s7tv_characterIndexAtPointInMessageLabel:labelPoint requireGlyphHit:YES]
        : NSNotFound;
    if (characterIndex != NSNotFound) {
        S7TVChatToken *emoteToken = [cell.messageLabel.attributedText
            attribute:kS7TVChatEmoteTokenAttributeName
              atIndex:characterIndex
       effectiveRange:NULL];
        if ([emoteToken isKindOfClass:[S7TVChatToken class]]) {
            CGPoint windowPoint = [gesture locationInView:self.window];
            [self s7tv_showEmotePreviewForToken:emoteToken atWindowPoint:windowPoint];
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
            return;
        }
    }

    if (!self.onReplyTargetSelected) return;
    NSString *username = message.authorDisplayName;
    if (!messageID.length || !username.length) return;

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    self.onReplyTargetSelected(messageID, username);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating) {
        return;
    }
    CGFloat distanceFromBottom = scrollView.contentSize.height
        - (scrollView.contentOffset.y + scrollView.bounds.size.height);
    BOOL nowPinned = (distanceFromBottom < 80);
    if (nowPinned && !self.isPinnedToBottom) {
        self.transcriptFrozen = NO;
        self.pendingNewMessagesCount = 0;
        [self s7tv_hideNewMessagesBanner];
    } else if (!nowPinned && self.isPinnedToBottom) {
        self.transcriptFrozen = self.freezesTranscriptWhenScrolled;
        self.pendingNewMessagesCount = 0;
        if (self.freezesTranscriptWhenScrolled) {
            self.lastObservedStoreGeneration = [self.store generation];
            NSMutableSet<NSString *> *visibleSnapshotIDs =
                [NSMutableSet setWithCapacity:self.displayedMessages.count];
            for (S7TVChatMessage *message in self.displayedMessages) {
                if (message.messageID.length) [visibleSnapshotIDs addObject:message.messageID];
            }
            self.lastObservedStoreMessageIDs = [visibleSnapshotIDs copy];
            [self s7tv_updateNewMessagesBannerText];
            [self s7tv_showNewMessagesBanner];
        } else {
            [self s7tv_hideNewMessagesBanner];
        }
    }
    self.isPinnedToBottom = nowPinned;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.tableView || decelerate) return;
    [self s7tv_flushDeferredReloadIfNeeded];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.tableView) return;
    [self s7tv_flushDeferredReloadIfNeeded];
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
    self.transcriptFrozen = NO;
    self.isPinnedToBottom = YES;
    // Synchroniser d'abord avec les 300 messages courants. Le completion du
    // snapshot appelle s7tv_scrollToBottomIfNeeded: sans animation : aucun
    // long scroll à travers des cellules qui viennent simultanément d'être
    // remplacées, donc aucun chevauchement transitoire.
    if (self.reloadDeferredUntilScrollEnds) [self s7tv_flushDeferredReloadIfNeeded];
    else [self reloadMessages];
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    [self s7tv_observeAnimationsForCell:s7tvCell];
}

- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    S7TVChatCustomCell *s7tvCell = (S7TVChatCustomCell *)cell;
    [s7tvCell s7tv_cancelAnimationFrameRequests];
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
        // Dans un message supprimé révélé, textColor porte une alpha
        // réduite : les liens doivent suivre la même atténuation que le
        // reste du corps au lieu de redevenir bleu vif.
        UIColor *effectiveLinkColor = CGColorGetAlpha(textColor.CGColor) < 0.999
            ? textColor : linkColor;
        NSMutableDictionary *linkAttrs = [@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: effectiveLinkColor,
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

// Format compact mais lisible des secondes IRC. Twitch conserve certains
// presets en heures (24h/72h), donc on ne bascule en semaines qu'à partir de
// 7 jours. Deux composantes max évitent les durées techniques illisibles.
static NSString *s7tv_humanModerationDuration(NSInteger totalSeconds) {
    totalSeconds = MAX(0, totalSeconds);
    if (totalSeconds == 0) return @"";

    NSInteger weeks = totalSeconds / (7 * 24 * 60 * 60);
    if (weeks > 0) {
        NSString *weekText = weeks == 1
            ? L(@"chat_duration_week_one")
            : [NSString stringWithFormat:L(@"chat_duration_weeks_format"), (long)weeks];
        NSInteger remainingDays = (totalSeconds % (7 * 24 * 60 * 60)) / (24 * 60 * 60);
        if (remainingDays > 0) {
            NSString *daysAsHours = [NSString stringWithFormat:L(@"chat_duration_hours_format"),
                                                               (long)(remainingDays * 24)];
            return [NSString stringWithFormat:@"%@ %@", weekText, daysAsHours];
        }
        return weekText;
    }

    NSInteger hours = totalSeconds / 3600;
    if (hours > 0) {
        NSString *hoursText = [NSString stringWithFormat:L(@"chat_duration_hours_format"), (long)hours];
        NSInteger minutes = (totalSeconds % 3600) / 60;
        return minutes > 0
            ? [NSString stringWithFormat:@"%@ %@", hoursText,
                [NSString stringWithFormat:L(@"chat_duration_minutes_format"), (long)minutes]]
            : hoursText;
    }

    NSInteger minutes = totalSeconds / 60;
    if (minutes > 0) {
        NSString *minutesText = [NSString stringWithFormat:L(@"chat_duration_minutes_format"), (long)minutes];
        NSInteger seconds = totalSeconds % 60;
        return seconds > 0
            ? [NSString stringWithFormat:@"%@ %@", minutesText,
                [NSString stringWithFormat:L(@"chat_duration_seconds_format"), (long)seconds]]
            : minutesText;
    }
    return [NSString stringWithFormat:L(@"chat_duration_seconds_format"), (long)totalSeconds];
}

static NSString *s7tv_deletedPlaceholderForMessage(S7TVChatMessage *msg,
                                                    SevenTVChatAppearanceConfig *cfg) {
    if (!cfg.showModerationDetails) return L(@"chat_deleted_message_placeholder");

    NSString *detail = nil;
    if (msg.moderationKind == S7TVChatModerationKindTimeout) {
        NSString *duration = s7tv_humanModerationDuration(msg.moderationDurationSeconds);
        detail = duration.length
            ? [NSString stringWithFormat:L(@"chat_moderation_timeout_format"), duration]
            : L(@"chat_moderation_timeout");
    } else if (msg.moderationKind == S7TVChatModerationKindPermanentBan) {
        detail = L(@"chat_moderation_permanent_ban");
    }
    return detail.length
        ? [NSString stringWithFormat:L(@"chat_deleted_message_with_detail_format"), detail]
        : L(@"chat_deleted_message_placeholder");
}

static void s7tv_applyDeletedBodyStyle(NSMutableAttributedString *result,
                                       NSUInteger bodyStart,
                                       S7TVChatMessage *msg,
                                       SevenTVChatAppearanceConfig *cfg) {
    if (!s7tv_shouldRenderDeletedExpanded(msg, cfg) ||
        bodyStart >= result.length) return;
    if (cfg.deletedMessageStyle == S7TVDeletedMessageStyleStrikethrough ||
        cfg.deletedMessageStyle == S7TVDeletedMessageStyleDimmedAndStrikethrough) {
        [result addAttribute:NSStrikethroughStyleAttributeName
                       value:@(NSUnderlineStyleSingle)
                       range:NSMakeRange(bodyStart, result.length - bodyStart)];
    }
}

static NSString *s7tv_channelPointCostString(NSInteger cost) {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = YES;
    formatter.maximumFractionDigits = 0;
    formatter.locale = [S7TVLocalization shared].currentLanguage == S7TVLanguageFrench
        ? [NSLocale localeWithLocaleIdentifier:@"fr_FR"]
        : [NSLocale localeWithLocaleIdentifier:@"en_US"];
    return [formatter stringFromNumber:@(MAX(0, cost))] ?: [@(MAX(0, cost)) stringValue];
}

- (NSAttributedString *)s7tv_buildAttributedStringForMessage:(S7TVChatMessage *)msg
                                       collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes
                                       collectAnimatedEmotes:(nullable NSMutableArray<id<S7TVResolvedEmote>> *)outAnimatedEmotes {
    NSMutableAttributedString *result = [NSMutableAttributedString new];

    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    if (msg.type == S7TVChatMessageTypeHistoryWelcome) {
        NSString *channel = msg.rawText.length ? msg.rawText : @"";
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:L(@"chat_history_welcome_format"), channel]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:cfg.messageFontSize],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.82]}]];
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }
    if (msg.type == S7TVChatMessageTypeHistoryDivider) {
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:@" "
                attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:13]}]];
        return result;
    }

    // CLEARCHAT global peut aussi toucher un message système conservé dans
    // le store. Le placeholder doit alors remplacer TOUT son rendu, pas être
    // ajouté sous la bannière sub/gift originale.
    [self s7tv_appendTimestampForMessage:msg into:result];
    if (s7tv_shouldRenderDeletedCollapsed(msg, cfg)) {
        [self s7tv_appendNormalBodyForMessage:msg into:result
                        collectUncachedEmotes:outUncachedEmotes
                        collectAnimatedEmotes:outAnimatedEmotes];
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }

    if (msg.type == S7TVChatMessageTypeChannelPointRedemption &&
        msg.channelPointRewardInfo) {
        NSUInteger bannerStart = result.length;
        [self s7tv_appendChannelPointBannerForMessage:msg
                                                into:result
                              collectUncachedEmotes:outUncachedEmotes];
        if (msg.rawText.length) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
            NSUInteger bannerParagraphLength = result.length - bannerStart;
            [self s7tv_appendNormalBodyForMessage:msg into:result
                            collectUncachedEmotes:outUncachedEmotes
                            collectAnimatedEmotes:outAnimatedEmotes];
            s7tv_applyLineBreakParagraphStyle(result);
            NSMutableParagraphStyle *bannerStyle = [NSMutableParagraphStyle new];
            bannerStyle.lineBreakMode = NSLineBreakByWordWrapping;
            bannerStyle.paragraphSpacing = 6.0;
            [result addAttribute:NSParagraphStyleAttributeName
                           value:bannerStyle
                           range:NSMakeRange(bannerStart, bannerParagraphLength)];
            return result;
        }
        s7tv_applyLineBreakParagraphStyle(result);
        return result;
    }

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
// parser IRC (voir 7tv-chat-message.m). Le
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

// Ligne générique calquée sur Twitch PC : titre fourni par Twitch, icône de
// la récompense immédiatement avant le coût, puis éventuelle saisie rendue
// comme un message normal sur la ligne suivante. Le seul texte local est le
// connecteur grammatical pour les récompenses sans saisie.
- (void)s7tv_appendChannelPointBannerForMessage:(S7TVChatMessage *)msg
                                            into:(NSMutableAttributedString *)result
                          collectUncachedEmotes:(NSMutableArray<id<S7TVResolvedEmote>> *)outUncachedEmotes {
    S7TVChannelPointRewardInfo *info = msg.channelPointRewardInfo;
    if (!info) return;

    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    UIFont *font = [UIFont systemFontOfSize:cfg.messageFontSize];
    UIColor *color = [UIColor colorWithWhite:0.85 alpha:1.0];
    NSString *title = info.titleLocalizationKey.length
        ? L(info.titleLocalizationKey)
        : (info.title ?: @"");
    NSString *header = nil;
    if (info.isUserInputRequired) {
        header = [NSString stringWithFormat:L(@"chat_channel_points_used_format"), title];
    } else {
        NSString *displayName = msg.authorDisplayName.length ? msg.authorDisplayName : @"???";
        header = [NSString stringWithFormat:L(@"chat_channel_points_redeemed_format"),
                                               displayName, title];
    }
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:header
            attributes:@{NSFontAttributeName: font,
                         NSForegroundColorAttributeName: color}]];

    // Un PRIVMSG peut exceptionnellement arriver avant toute métadonnée de
    // récompense. Ne jamais afficher un faux coût « 0 » : PubSub/GQL apporte
    // normalement le vrai coût et l'icône dans la même fenêtre de fusion.
    NSURL *effectiveImageURL = info.imageURL;
    BOOL usesBits = info.pricingType.length > 0 &&
        [info.pricingType caseInsensitiveCompare:@"BITS"] == NSOrderedSame;
    if (!usesBits) {
        effectiveImageURL = s7tv_activeChannelPointCurrencyImageURL()
            ?: effectiveImageURL;
    }
    id<S7TVResolvedEmote> imageSource = info;
    if (effectiveImageURL.absoluteString.length &&
        ![effectiveImageURL.absoluteString isEqualToString:info.imageURL.absoluteString]) {
        S7TVChannelPointRewardInfo *adapter = [S7TVChannelPointRewardInfo new];
        adapter.rewardID = effectiveImageURL.absoluteString;
        adapter.imageURL = effectiveImageURL;
        imageSource = adapter;
    }

    if (info.cost > 0 && effectiveImageURL.absoluteString.length) {
        UIImage *image = [[SevenTVEmoteImageCache sharedCache]
            cachedImageForResolvedEmote:imageSource];
        if (image) {
            CGFloat side = MAX(12.0, cfg.messageFontSize * 1.05);
            NSTextAttachment *attachment = [NSTextAttachment new];
            attachment.image = image;
            attachment.bounds = CGRectMake(0, -2.5, side, side);
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
            [result appendAttributedString:
                [NSAttributedString attributedStringWithAttachment:attachment]];
        } else {
            [outUncachedEmotes addObject:imageSource];
        }
    }

    if (info.cost > 0) {
        NSString *cost = s7tv_channelPointCostString(info.cost);
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@" " stringByAppendingString:cost]
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: color}]];
    }
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
    // 7tv-chat-message.h) en gras pour ressortir dans le corps du
    // message, indépendamment de la couleur appliquée juste en dessous.
    UIFont *mentionFont  = [UIFont boldSystemFontOfSize:cfg.messageFontSize];
    UIColor *usernameColor = s7tv_readableColorOnDarkBackground(msg.authorColor);
    // /me : le corps entier prend la couleur du pseudo (comportement
    // Twitch) au lieu du blanc habituel — voir isActionMessage sur
    // S7TVChatMessage, déballé du CTCP ACTION par s7tv_parsePRIVMSG dans
    // 7tv-chat-message.m. Un seul point de bascule : messageColor est déjà
    // réutilisé pour tous les chemins du corps ci-dessous (fallback sans
    // tokens, texte brut, emote non résolue, texte hors mention).
    BOOL isDeletedExpanded = s7tv_shouldRenderDeletedExpanded(msg, cfg);
    BOOL usesDimming = (cfg.deletedMessageStyle != S7TVDeletedMessageStyleStrikethrough);
    CGFloat deletedOpacity = MIN(1.0, MAX(0.25, cfg.deletedMessageTextOpacity));
    UIColor *messageColor = (isDeletedExpanded && usesDimming)
        ? [UIColor colorWithWhite:1.0 alpha:deletedOpacity]
        : (msg.isActionMessage ? usernameColor : [UIColor whiteColor]);

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
    // Point de départ exact du corps : badges et pseudo sont volontairement
    // exclus de tous les styles de suppression configurables.
    NSUInteger messageBodyStart = result.length;

    if (s7tv_shouldRenderDeletedCollapsed(msg, cfg)) {
        [result appendAttributedString:[[NSAttributedString alloc]
            initWithString:s7tv_deletedPlaceholderForMessage(msg, cfg)
                attributes:@{NSFontAttributeName: [UIFont italicSystemFontOfSize:cfg.messageFontSize],
                             NSForegroundColorAttributeName: [UIColor grayColor]}]];
        return;
    }

    NSArray<S7TVChatToken *> *tokens = msg.tokens;
    if (!tokens.count) {
        s7tv_appendTextWithLinkDetection(result, msg.rawText ?: @"", messageFont, messageColor);
        s7tv_applyDeletedBodyStyle(result, messageBodyStart, msg, cfg);
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

            // Valeur 1:1 du picker : -6 affiché signifie réellement y=-6
            // dans les bounds, sans correction fixe ou échelle parallèle.
            CGFloat y = cfg.emoteVerticalOffset;
            attachment.bounds = CGRectMake(0, y, targetWidth, targetHeight);

            NSMutableAttributedString *attachmentText =
                [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
            // Le picker ne contient que les emotes 7TV : seules celles-ci
            // exposent donc l'action Favori. Une emote Twitch native garde
            // le comportement d'appui long normal (réponse à l'auteur).
            if (token.type == S7TVChatTokenTypeEmote7TV && attachmentText.length > 0) {
                [attachmentText addAttribute:kS7TVChatEmoteTokenAttributeName
                                       value:token
                                       range:NSMakeRange(0, attachmentText.length)];
            }
            [result appendAttributedString:attachmentText];
            continue;
        }

        if (token.type == S7TVChatTokenTypeMention) {
            // Couleur résolue par le tokenizer (voir
            // SevenTVChatUserColorRegistry) — même traitement de contraste
            // que le pseudo de l'auteur (s7tv_readableColorOnDarkBackground)
            // pour rester lisible sur fond sombre. nil (pseudo jamais vu
            // dans le chat) → couleur normale du texte, pas de couleur
            // devinée.
            UIColor *mentionColor = isDeletedExpanded ? messageColor : (token.mentionColor
                ? s7tv_readableColorOnDarkBackground(token.mentionColor)
                : messageColor);
            [result appendAttributedString:[[NSAttributedString alloc]
                initWithString:token.text ?: @""
                    attributes:@{NSFontAttributeName: mentionFont,
                                 NSForegroundColorAttributeName: mentionColor}]];
            continue;
        }

        s7tv_appendTextWithLinkDetection(result, token.text ?: @"", messageFont, messageColor);
    }
    s7tv_applyDeletedBodyStyle(result, messageBodyStart, msg, cfg);
}

- (void)s7tv_appendTimestampForMessage:(S7TVChatMessage *)msg
                                   into:(NSMutableAttributedString *)result {
    if (!msg.isHistorical || !msg.timestamp) return;
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm";
    });
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    CGFloat size = MAX(10.0, cfg.messageFontSize - 2.0);
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:size weight:UIFontWeightRegular];
    NSString *time = [[formatter stringFromDate:msg.timestamp] stringByAppendingString:@" "];
    [result appendAttributedString:[[NSAttributedString alloc]
        initWithString:time
            attributes:@{NSFontAttributeName: font,
                         NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.56]}]];
}

@end
