/*
 * tpK-chat-reply-thread-panel.m — Panneau "Fil" flottant (racine épinglée +
 * réponses), stores temporaires en lecture seule. Écriture vers Twitch non
 * implémentée (envoi WebSocket réel) : consultation seule pour l'instant.
 */

#import "Chat/tpK-chat-reply-thread-panel.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Chat/tpK-chat-message.h"
#import "Core/tpK-core-manager.h"
#import "Localization/tpK-localization-manager.h"
#import "Chat/tpK-chat-tokenizer.h"
#import "Emote/tpK-emote-provider.h"
#import "UI/tpK-oled-mode.h"

// Overlays volontairement un cran au-dessus du noir OLED (contexte visuel).
static UIColor *tpk_replyContextSurfaceColor(void) {
    return TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.04 alpha:1.0]
        : [UIColor colorWithWhite:0.08 alpha:1.0];
}

static UIColor *tpk_contextMessageBackgroundColor(void) {
    return [UIColor colorWithWhite:1.0
                             alpha:TPKOLEDModeEnabled() ? 0.025 : 0.04];
}

static UIColor *tpk_replyContextBorderColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.14];
}

static CGFloat tpk_replyContextBorderWidth(void) {
    return 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
}

// "@pseudo " en tête de la saisie native, SANS ouvrir le clavier.
// Mutation directe de .text + notification manuelle : c'est elle (pas
// paste:) qui prévient le binding SwiftUI côté Twitch. No-op si la mention
// est déjà en tête. Préfère le candidat avec un delegate (les autres sont
// des vues décoratives UIKit non liées au binding).
static UITextView *tpk_findActiveChatTextView(UITextField * _Nullable * _Nullable outTextField) {
    UIView *inputRoot = tpk_findChatInputView();
    if (!inputRoot) return nil;

    NSMutableArray<UITextView *> *allTextViews = [NSMutableArray array];
    UITextField *textField = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:inputRoot];
    while (queue.count > 0) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:v.subviews];
        if ([v isKindOfClass:[UITextView class]]) [allTextViews addObject:(UITextView *)v];
        if (!textField && [v isKindOfClass:[UITextField class]]) textField = (UITextField *)v;
    }
    if (outTextField) *outTextField = textField;

    UITextView *textView = nil;
    for (UITextView *tv in allTextViews) {
        if (tv.delegate != nil) { textView = tv; break; }
    }
    if (!textView) {
        for (UITextView *tv in allTextViews) {
            if (!tv.hidden && tv.alpha > 0.01 && !CGRectIsEmpty(tv.frame)) { textView = tv; break; }
        }
    }
    if (!textView) textView = allTextViews.firstObject;
    return textView;
}

// Insère "@pseudo " au tout début du texte, SANS ouvrir le clavier (voir
// commentaires plus haut sur becomeFirstResponder). Retourne le texte
// RÉELLEMENT inséré tel qu'il apparaît après coup — Twitch transforme
// automatiquement "@pseudo" en lien markdown "[@pseudo](https://t.me/pseudo)"
// dès que son delegate traite le changement (confirmé par les logs), donc ce
// n'est PAS le même texte que ce qu'on a écrit. On calcule ce texte par
// différence de longueur (nouveau texte moins ancien texte = préfixe ajouté)
// plutôt que de deviner le format transformé — c'est ce texte exact qu'il
// faut mémoriser pour pouvoir le retirer proprement plus tard (voir
// tpk_removeExactPrefixFromChatInput ci-dessous). nil si rien n'a été
// inséré (vue introuvable, ou la transformation a fait quelque chose
// d'imprévisible qu'on ne peut pas retirer en confiance).
static NSString *tpk_insertMentionAtStartOfChatInput(NSString *username) {
    if (!username.length) return nil;

    UITextField *textField = nil;
    UITextView *textView = tpk_findActiveChatTextView(&textField);
    NSString *mention = [NSString stringWithFormat:@"@%@ ", username];

    if (textView) {
        NSString *current = textView.text ?: @"";

        textView.text = [mention stringByAppendingString:current];
        textView.selectedRange = NSMakeRange(mention.length, 0);

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextViewTextDidChangeNotification
                          object:textView];
        if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [textView.delegate textViewDidChange:textView];
        }

        NSString *finalText = textView.text ?: @"";
        NSInteger insertedLength = (NSInteger)finalText.length - (NSInteger)current.length;

        if (insertedLength <= 0 || insertedLength > (NSInteger)finalText.length) {
            return mention;
        }
        return [finalText substringToIndex:insertedLength];
    } else if (textField) {
        NSString *current = textField.text ?: @"";

        textField.text = [mention stringByAppendingString:current];

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextFieldTextDidChangeNotification
                          object:textField];
        if ([textField.delegate respondsToSelector:@selector(textFieldDidChangeSelection:)]) {
            [textField.delegate textFieldDidChangeSelection:textField];
        }

        NSString *finalText = textField.text ?: @"";
        NSInteger insertedLength = (NSInteger)finalText.length - (NSInteger)current.length;
        if (insertedLength <= 0 || insertedLength > (NSInteger)finalText.length) return mention;
        return [finalText substringToIndex:insertedLength];
    }

    return nil;
}

// Retire exactement `exactPrefix` (déjà transformé par Twitch) en tête.
// No-op si l'utilisateur a édité entre-temps : on ne devine jamais.
static void tpk_removeExactPrefixFromChatInput(NSString *exactPrefix) {
    if (!exactPrefix.length) return;

    UITextField *textField = nil;
    UITextView *textView = tpk_findActiveChatTextView(&textField);

    if (textView) {
        NSString *current = textView.text ?: @"";
        if (![current hasPrefix:exactPrefix]) return;

        textView.text = [current substringFromIndex:exactPrefix.length];
        textView.selectedRange = NSMakeRange(0, 0);

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextViewTextDidChangeNotification
                          object:textView];
        if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [textView.delegate textViewDidChange:textView];
        }
    } else if (textField) {
        NSString *current = textField.text ?: @"";
        if (![current hasPrefix:exactPrefix]) return;

        textField.text = [current substringFromIndex:exactPrefix.length];

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextFieldTextDidChangeNotification
                          object:textField];
        if ([textField.delegate respondsToSelector:@selector(textFieldDidChangeSelection:)]) {
            [textField.delegate textFieldDidChangeSelection:textField];
        }
    }
}
// MARK: - Panneau "Fil" (réponses)
static const CGFloat kTPKReplyThreadTitleHeight = 26.0;
static const CGFloat kTPKReplyThreadSeparatorHeight = 1.0;
static const CGFloat kTPKReplyThreadBottomPadding = 8.0;
static const CGFloat kTPKReplyTargetActionRowHeight = 26.0;
static const NSUInteger kTPKReplyThreadPortraitVisibleLineCount = 5;
static const NSUInteger kTPKReplyThreadLandscapeVisibleLineCount = 4;
static const NSUInteger kTPKReplyThreadPortraitMinimumReplyLineCount = 1;
static const NSUInteger kTPKReplyThreadLandscapeMinimumReplyLineCount = 2;

static NSAttributedString *tpk_buildReplyTargetBarText(NSString *username) {
    NSDictionary *regularAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.6],
    };
    NSDictionary *boldAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85],
    };

    NSMutableAttributedString *result =
        [[NSMutableAttributedString alloc] initWithString:L(@"chat_reply_target_bar_prefix")
                                                 attributes:regularAttrs];
    [result appendAttributedString:
        [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"@%@", username]
                                          attributes:boldAttrs]];
    [result appendAttributedString:
        [[NSAttributedString alloc] initWithString:@"   •   " attributes:boldAttrs]];
    return result;
}

static NSArray<NSString *> *tpk_messageIDs(NSArray<TPKChatMessage *> *messages) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:messages.count];
    for (TPKChatMessage *message in messages) {
        if (message.messageID.length) [identifiers addObject:message.messageID];
    }
    return identifiers;
}

static BOOL tpk_sameMessageInstances(NSArray<TPKChatMessage *> *left,
                                      NSArray<TPKChatMessage *> *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger index = 0; index < left.count; index++) {
        if (left[index] != right[index]) return NO;
    }
    return YES;
}

// Overlay dont le layout pilote le re-budget (modèle pastille).
@interface TPKHostLayoutView : UIView
@property (nonatomic, copy, nullable) void (^onHostLayout)(TPKHostLayoutView *view);
@end
@implementation TPKHostLayoutView
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.onHostLayout) self.onHostLayout(self);
}
@end

@interface TPKReplyThreadPanel ()
@property (nonatomic, strong) TPKHostLayoutView *containerView;
// Ancré sur notre chat (position gratuite via Auto Layout) + hauteur mesurée.
@property (nonatomic, weak) TPKChatCustomView *anchorChatView;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *containerPositionConstraints;
@property (nonatomic, strong) NSLayoutConstraint *containerHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *standalonePositionConstraints;
@property (nonatomic, strong) NSLayoutConstraint *standaloneReplyBarHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *threadHostPositionConstraints;
// Titre relu à chaque ouverture (panneau réutilisé, sinon langue figée).
@property (nonatomic, weak) UILabel *titleLabel;
// Idem : titre du bouton posé une seule fois à la création.
@property (nonatomic, weak) UIButton *cancelButton;
// Racine épinglée, jamais scrollable (0 ou 1 message).
@property (nonatomic, strong) TPKChatCustomView *rootChatView;
@property (nonatomic, strong) TPKChatMessageStore *rootStore;
@property (nonatomic, strong) NSLayoutConstraint *rootChatViewHeightConstraint;
@property (nonatomic, strong) TPKChatCustomView *repliesChatView;
@property (nonatomic, strong) TPKChatMessageStore *repliesStore;
@property (nonatomic, copy) NSString *currentThreadRootID;
// Chaque show/hide/refresh invalide les completions plus anciennes.
@property (nonatomic, assign) NSUInteger contentRequestGeneration;
@property (nonatomic, copy) NSString *loadedThreadRootID;
@property (nonatomic, copy) NSString *lastRequestedRootMessageID;
@property (nonatomic, copy) NSArray<NSString *> *lastRequestedReplyMessageIDs;
@property (nonatomic, strong) TPKChatMessage *lastRequestedRootMessage;
@property (nonatomic, copy) NSArray<TPKChatMessage *> *lastRequestedReplyMessages;
// Caché pendant le premier snapshot : un seul rattrapage avant affichage.
@property (nonatomic, assign) BOOL contentRefreshPendingWhileOpening;
@property (nonatomic, copy) NSArray<TPKChatMessage *> *openingTranscriptMessages;
@property (nonatomic, weak) TPKChatCustomView *threadSourceView;
@property (nonatomic, copy) NSString *threadSourceMessageID;

// ── Cible de réponse (appui long) : la mention @X ne s'insère qu'ici.
@property (nonatomic, copy) NSString *selectedReplyTargetMessageID;
@property (nonatomic, copy) NSString *selectedReplyTargetUsername;
// Texte exact déjà transformé par Twitch : seul lui permet un retrait propre.
@property (nonatomic, copy) NSString *lastInsertedMentionText;
// Dernière géométrie mesurée (garde anti-boucle du re-budget).
@property (nonatomic, assign) CGFloat measuredContainerWidth;
@property (nonatomic, assign) CGFloat measuredHostMaxY;
@property (nonatomic, assign) CGFloat measuredStandaloneWidth;
// Barre "Répondre à @X · Annuler", hauteur 0 = masquée. Instance unique
// déplacée entre le Fil et le chat selon l'origine de la réponse.
@property (nonatomic, strong) TPKHostLayoutView *replyTargetBarView;
@property (nonatomic, strong) TPKChatMessageStore *replyTargetMessageStore;
@property (nonatomic, strong) TPKChatCustomView *replyTargetMessageView;
@property (nonatomic, strong) NSLayoutConstraint *replyTargetMessageViewHeightConstraint;
@property (nonatomic, weak) UILabel *replyTargetBarLabel;
@property (nonatomic, weak) UIView *threadReplyTargetBarHostView;
@property (nonatomic, strong) NSLayoutConstraint *replyTargetBarHeightConstraint;
@property (nonatomic, weak) TPKChatCustomView *replyTargetSourceView;
@property (nonatomic, assign) BOOL panelLayoutInProgress;
@property (nonatomic, assign) BOOL panelRelayoutPending;
@property (nonatomic, assign) BOOL standaloneResizeInProgress;
@property (nonatomic, assign) BOOL standaloneResizePending;
@property (nonatomic, assign) BOOL contentLayoutScheduled;
- (void)tpk_clearReplyTargetRemovingMention;
- (void)tpk_clearThreadSourceHighlight;
- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID
     retainedThreadMessages:(NSArray<TPKChatMessage *> *)retainedThreadMessages
                  sourceView:(TPKChatCustomView *)sourceView;
- (void)tpk_finishOpeningThreadRootID:(NSString *)threadRootID
                                window:(UIWindow *)window
                      allowsCatchUpPass:(BOOL)allowsCatchUpPass;
- (void)tpk_layoutPanelContentInWindow:(UIWindow *)window;
- (void)tpk_resizeStandaloneForChatView:(TPKChatCustomView *)hostView;
- (void)tpk_containerHostDidLayout:(TPKHostLayoutView *)container;
- (void)tpk_standaloneHostDidLayout:(TPKHostLayoutView *)barView;
- (void)tpk_contentHeightChangedForView:(TPKChatCustomView *)view;
- (void)tpk_scheduleContentLayoutForView:(TPKChatCustomView *)view;
- (void)tpk_applyOLEDColors;
@end

@implementation TPKReplyThreadPanel

+ (instancetype)sharedPanel {
    static TPKReplyThreadPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [TPKReplyThreadPanel new]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(tpk_oledModeDidChange:)
                   name:TPKOLEDModeDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:TPKOLEDModeDidChangeNotification object:nil];
}

- (void)tpk_oledModeDidChange:(__unused NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self tpk_applyOLEDColors];
    });
}

- (void)tpk_applyOLEDColors {
    self.containerView.backgroundColor = tpk_replyContextSurfaceColor();
    self.containerView.layer.borderWidth = tpk_replyContextBorderWidth();
    self.containerView.layer.borderColor = tpk_replyContextBorderColor().CGColor;
    self.rootChatView.backgroundColor = tpk_contextMessageBackgroundColor();
    self.replyTargetMessageView.backgroundColor = tpk_contextMessageBackgroundColor();
    if (self.replyTargetBarView.superview == self.threadReplyTargetBarHostView) {
        self.replyTargetBarView.backgroundColor = UIColor.clearColor;
        self.replyTargetBarView.layer.borderWidth = 0;
        self.replyTargetBarView.layer.borderColor = UIColor.clearColor.CGColor;
    } else {
        self.replyTargetBarView.backgroundColor = tpk_replyContextSurfaceColor();
        self.replyTargetBarView.layer.borderWidth = tpk_replyContextBorderWidth();
        self.replyTargetBarView.layer.borderColor = tpk_replyContextBorderColor().CGColor;
    }
    [self.replyTargetSourceView
        setReplyTargetHighlightedMessageID:self.selectedReplyTargetMessageID];
    [self.threadSourceView
        setReplyTargetHighlightedMessageID:self.threadSourceMessageID];
}

// Attache un overlay en subview du chat (position gratuite, modèle pastille).
// Retourne les contraintes de position ; l'appelant les stocke pour purge.
- (NSArray<NSLayoutConstraint *> *)tpk_attachOverlayView:(UIView *)view toChatView:(TPKChatCustomView *)hostView {
    [view removeFromSuperview];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [hostView addSubview:view];
    NSArray<NSLayoutConstraint *> *position = @[
        [view.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
        [view.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:position];
    return position;
}

// Re-budgète la hauteur quand la géométrie de l'hôte change (rotation,
// clavier). L'hôte mort (vue détachée) ferme le panneau, sans backup.
- (void)tpk_containerHostDidLayout:(TPKHostLayoutView *)container {
    if (container != self.containerView || !self.currentThreadRootID.length || container.hidden) return;
    TPKChatCustomView *host = [container.superview isKindOfClass:[TPKChatCustomView class]]
        ? (TPKChatCustomView *)container.superview : nil;
    UIWindow *window = container.window;
    if (!host || !window) { [self hide]; return; }
    CGFloat width = CGRectGetWidth(container.bounds);
    CGFloat hostMaxY = CGRectGetMaxY([host convertRect:host.bounds toView:window]);
    if (fabs(width - self.measuredContainerWidth) < 0.5 &&
        fabs(hostMaxY - self.measuredHostMaxY) < 0.5) return;
    [self tpk_layoutPanelContentInWindow:window];
}

// L'autonome suit la largeur (hauteur = contenu, pas de budget).
- (void)tpk_standaloneHostDidLayout:(TPKHostLayoutView *)barView {
    if (barView != self.replyTargetBarView || barView.hidden ||
        self.replyTargetMessageView.hidden) return;
    if (barView.superview == self.threadReplyTargetBarHostView) return;
    TPKChatCustomView *host = [barView.superview isKindOfClass:[TPKChatCustomView class]]
        ? (TPKChatCustomView *)barView.superview : nil;
    if (!host || !barView.window) {
        if (!barView.window) [self tpk_clearReplyTargetRemovingMention];
        return;
    }
    CGFloat width = CGRectGetWidth(barView.bounds);
    if (fabs(width - self.measuredStandaloneWidth) < 0.5) return;
    [self tpk_resizeStandaloneForChatView:host];
}

- (void)chatCustomView:(TPKChatCustomView *)view
    didTapReplyBannerForThreadRootID:(NSString *)threadRootID
                       tappedMessageID:(NSString *)tappedMessageID {
    [self showForThreadRootID:threadRootID
              tappedMessageID:tappedMessageID
       retainedThreadMessages:[view displayedMessagesForThreadRootID:threadRootID]
                    sourceView:view];
}

- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID {
    NSArray<TPKChatMessage *> *messages = [[TPKManager sharedManager].chatMessageStore
        messagesForThreadRootID:threadRootID];
    [self showForThreadRootID:threadRootID
              tappedMessageID:tappedMessageID
       retainedThreadMessages:messages ?: @[]
                    sourceView:tpk_activeChatCustomView()];
}

- (void)tpk_ensureReplyTargetBar {
    if (self.replyTargetBarView) return;

    TPKHostLayoutView *replyBar = [[TPKHostLayoutView alloc] init];
    replyBar.clipsToBounds = YES;
    replyBar.hidden = YES;
    self.replyTargetBarView = replyBar;
    __weak typeof(self) weakSelfForStandaloneLayout = self;
    replyBar.onHostLayout = ^(TPKHostLayoutView *view) {
        [weakSelfForStandaloneLayout tpk_standaloneHostDidLayout:view];
    };

    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [replyBar addSubview:separator];

    self.replyTargetMessageStore = [TPKChatMessageStore new];
    self.replyTargetMessageView = [[TPKChatCustomView alloc]
        initWithStore:self.replyTargetMessageStore];
    self.replyTargetMessageView.showsReplyBanners = NO;
    self.replyTargetMessageView.freezesTranscriptWhenScrolled = NO;
    self.replyTargetMessageView.automaticallyScrollsToBottom = NO;
    [self.replyTargetMessageView setScrollingEnabled:NO];
    self.replyTargetMessageView.userInteractionEnabled = NO;
    self.replyTargetMessageView.backgroundColor = tpk_contextMessageBackgroundColor();
    self.replyTargetMessageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.replyTargetMessageView.hidden = YES;
    self.replyTargetMessageView.renderingSuspended = YES;
    __weak typeof(self) weakSelfForPreviewHeight = self;
    self.replyTargetMessageView.onContentHeightChanged =
        ^(TPKChatCustomView *view) {
        [weakSelfForPreviewHeight tpk_contentHeightChangedForView:view];
    };
    [replyBar addSubview:self.replyTargetMessageView];

    self.replyTargetMessageViewHeightConstraint =
        [self.replyTargetMessageView.heightAnchor constraintEqualToConstant:0];

    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [replyBar addSubview:label];
    self.replyTargetBarLabel = label;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [cancelButton setTitleColor:[UIColor colorWithRed:0.65 green:0.45 blue:1.0 alpha:1.0]
                        forState:UIControlStateNormal];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton addTarget:self action:@selector(tpk_cancelReplyTargetTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [replyBar addSubview:cancelButton];
    self.cancelButton = cancelButton;

    [NSLayoutConstraint activateConstraints:@[
        [separator.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:replyBar.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:replyBar.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:kTPKReplyThreadSeparatorHeight],

        [self.replyTargetMessageView.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor],
        [self.replyTargetMessageView.trailingAnchor constraintEqualToAnchor:replyBar.trailingAnchor],
        [self.replyTargetMessageView.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        self.replyTargetMessageViewHeightConstraint,

        [label.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:self.replyTargetMessageView.bottomAnchor
                                           constant:kTPKReplyTargetActionRowHeight / 2],

        [cancelButton.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8],
        [cancelButton.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [cancelButton.trailingAnchor constraintLessThanOrEqualToAnchor:replyBar.trailingAnchor constant:-12],
    ]];
}

- (void)tpk_attachReplyTargetBarToThreadHost {
    UIView *host = self.threadReplyTargetBarHostView;
    if (!host) return;
    [self tpk_ensureReplyTargetBar];
    [NSLayoutConstraint deactivateConstraints:self.standalonePositionConstraints ?: @[]];
    self.standalonePositionConstraints = nil;
    [NSLayoutConstraint deactivateConstraints:self.threadHostPositionConstraints ?: @[]];
    self.threadHostPositionConstraints = nil;
    if (self.standaloneReplyBarHeightConstraint) {
        self.standaloneReplyBarHeightConstraint.active = NO;
    }
    [self.replyTargetBarView removeFromSuperview];
    self.replyTargetBarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.replyTargetBarView.backgroundColor = [UIColor clearColor];
    self.replyTargetBarView.layer.cornerRadius = 0;
    self.replyTargetBarView.layer.borderWidth = 0;
    self.replyTargetBarView.layer.borderColor = UIColor.clearColor.CGColor;
    [host addSubview:self.replyTargetBarView];
    // Contraintes pures comme l'autonome : pin haut/gauche/droite sur l'hôte
    // + hauteur explicite (même ligne d'action). Plus de frame/autoresizing.
    self.threadHostPositionConstraints = @[
        [self.replyTargetBarView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [self.replyTargetBarView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [self.replyTargetBarView.topAnchor constraintEqualToAnchor:host.topAnchor],
        [self.replyTargetBarView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.threadHostPositionConstraints];
}

- (void)tpk_showStandaloneForChatView:(TPKChatCustomView *)hostView {
    if (!hostView || !hostView.window) return;
    [self tpk_ensureReplyTargetBar];
    [NSLayoutConstraint deactivateConstraints:self.standalonePositionConstraints ?: @[]];
    self.standalonePositionConstraints = nil;
    [NSLayoutConstraint deactivateConstraints:self.threadHostPositionConstraints ?: @[]];
    self.threadHostPositionConstraints = nil;
    self.anchorChatView = hostView;
    self.standalonePositionConstraints =
        [self tpk_attachOverlayView:self.replyTargetBarView toChatView:hostView];
    self.replyTargetBarView.backgroundColor = tpk_replyContextSurfaceColor();
    self.replyTargetBarView.layer.cornerRadius = 10;
    self.replyTargetBarView.layer.borderWidth = tpk_replyContextBorderWidth();
    self.replyTargetBarView.layer.borderColor = tpk_replyContextBorderColor().CGColor;
    self.replyTargetBarView.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

    // Révélée seulement après mesure à la largeur finale (pas de flash 0 pt).
    self.replyTargetBarView.hidden = YES;
    [hostView bringSubviewToFront:self.replyTargetBarView];
}

- (void)tpk_resizeStandaloneForChatView:(TPKChatCustomView *)hostView {
    UIView *barView = self.replyTargetBarView;
    if (!hostView || !hostView.window || barView.hidden || self.replyTargetMessageView.hidden) return;

    if (self.standaloneResizeInProgress) {
        self.standaloneResizePending = YES;
        return;
    }

    self.standaloneResizeInProgress = YES;
    BOOL wasHidden = barView.hidden;
    barView.hidden = YES;

    if (barView.superview != hostView || self.anchorChatView != hostView) {
        [NSLayoutConstraint deactivateConstraints:self.standalonePositionConstraints ?: @[]];
        self.anchorChatView = hostView;
        self.standalonePositionConstraints =
            [self tpk_attachOverlayView:barView toChatView:hostView];
    }
    [hostView.window layoutIfNeeded];
    CGFloat availableHeight = MAX(44.0, CGRectGetHeight(hostView.bounds));

    self.replyTargetMessageViewHeightConstraint.constant = availableHeight;
    if (!self.standaloneReplyBarHeightConstraint) {
        self.standaloneReplyBarHeightConstraint =
            [barView.heightAnchor constraintEqualToConstant:
                kTPKReplyTargetActionRowHeight + availableHeight];
        self.standaloneReplyBarHeightConstraint.active = YES;
    } else {
        self.standaloneReplyBarHeightConstraint.constant =
            kTPKReplyTargetActionRowHeight + availableHeight;
        self.standaloneReplyBarHeightConstraint.active = YES;
    }
    [barView layoutIfNeeded];
    CGFloat messageHeight = ceil(MAX([self.replyTargetMessageView tpkContentHeight], 0));
    self.replyTargetMessageViewHeightConstraint.constant = messageHeight;
    self.standaloneReplyBarHeightConstraint.constant =
        kTPKReplyTargetActionRowHeight + messageHeight;
    self.measuredStandaloneWidth = CGRectGetWidth(barView.bounds);
    [hostView bringSubviewToFront:barView];

    barView.hidden = wasHidden;
    self.standaloneResizeInProgress = NO;
    if (self.standaloneResizePending) {
        self.standaloneResizePending = NO;
        [self tpk_scheduleContentLayoutForView:self.replyTargetMessageView];
    }
}

- (void)tpk_contentHeightChangedForView:(TPKChatCustomView *)view {
    if (!view) return;

    BOOL isThreadView = (view == self.rootChatView || view == self.repliesChatView);
    BOOL isStandalonePreview = (view == self.replyTargetMessageView);
    BOOL threadVisible = isThreadView && self.containerView.window &&
        !self.containerView.hidden && self.currentThreadRootID.length > 0;
    BOOL standaloneVisible = isStandalonePreview && self.replyTargetBarView.window &&
        [self.replyTargetBarView.superview isKindOfClass:[TPKChatCustomView class]] &&
        !self.replyTargetBarView.hidden && !self.replyTargetMessageView.hidden;
    if (!threadVisible && !standaloneVisible) return;

    if (threadVisible && self.panelLayoutInProgress) {
        self.panelRelayoutPending = YES;
        return;
    }
    if (standaloneVisible && self.standaloneResizeInProgress) {
        self.standaloneResizePending = YES;
        return;
    }
    [self tpk_scheduleContentLayoutForView:view];
}

- (void)tpk_scheduleContentLayoutForView:(TPKChatCustomView *)view {
    if (!view || self.contentLayoutScheduled) return;
    self.contentLayoutScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.contentLayoutScheduled = NO;

        if ((view == strongSelf.rootChatView || view == strongSelf.repliesChatView) &&
            strongSelf.containerView.window && !strongSelf.containerView.hidden &&
            strongSelf.currentThreadRootID.length > 0) {
            [strongSelf tpk_layoutPanelContentInWindow:strongSelf.containerView.window];
        } else if (view == strongSelf.replyTargetMessageView &&
                   strongSelf.replyTargetBarView.window &&
                   [strongSelf.replyTargetBarView.superview isKindOfClass:[TPKChatCustomView class]] &&
                   !strongSelf.replyTargetBarView.hidden &&
                   !strongSelf.replyTargetMessageView.hidden) {
            [strongSelf tpk_resizeStandaloneForChatView:
                (TPKChatCustomView *)strongSelf.replyTargetBarView.superview];
        }
    });
}

- (void)tpk_ensureContainerInChatView:(TPKChatCustomView *)hostView {
    if (!hostView || !hostView.window) return;
    if (self.containerView.superview == hostView) {
        [self tpk_applyOLEDColors];
        [hostView bringSubviewToFront:self.containerView];
        return;
    }
    [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
    [self.containerView removeFromSuperview];
    self.containerView = nil;
    self.containerPositionConstraints = nil;
    self.containerHeightConstraint = nil;
    self.anchorChatView = nil;

    TPKHostLayoutView *container = [[TPKHostLayoutView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = tpk_replyContextSurfaceColor();
    container.layer.cornerRadius = 14;
    container.layer.borderWidth = tpk_replyContextBorderWidth();
    container.layer.borderColor = tpk_replyContextBorderColor().CGColor;
    container.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    container.clipsToBounds = YES;
    container.hidden = YES;
    CGFloat initialHeight = kTPKReplyThreadTitleHeight +
        kTPKReplyThreadSeparatorHeight * 2 +
        kTPKReplyThreadBottomPadding + 44.0;
    self.containerView = container;
    __weak typeof(self) weakSelfForContainerLayout = self;
    container.onHostLayout = ^(TPKHostLayoutView *view) {
        [weakSelfForContainerLayout tpk_containerHostDidLayout:view];
    };
    self.containerHeightConstraint =
        [container.heightAnchor constraintEqualToConstant:initialHeight];
    self.containerHeightConstraint.active = YES;
    self.anchorChatView = hostView;
    self.containerPositionConstraints =
        [self tpk_attachOverlayView:container toChatView:hostView];

    UIImageView *titleIcon = [[UIImageView alloc] init];
    UIImageSymbolConfiguration *titleIconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    // bubble.left.fill est quasi carré : aspectFit garde ses proportions.
    titleIcon.image = [UIImage systemImageNamed:@"bubble.left.fill"
                             withConfiguration:titleIconConfig];
    titleIcon.contentMode = UIViewContentModeScaleAspectFit;
    titleIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:titleIcon];

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"chat_reply_thread_panel_title");
    self.titleLabel = title;
    title.font = [UIFont boldSystemFontOfSize:12];
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:title];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *closeIconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    [closeButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:closeIconConfig]
                  forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton addTarget:self action:@selector(tpk_closeTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:closeButton];

    UIView *topSeparator = [[UIView alloc] init];
    topSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:topSeparator];

    self.rootStore = [TPKChatMessageStore new];
    self.rootChatView = [[TPKChatCustomView alloc] initWithStore:self.rootStore];
    self.rootChatView.showsReplyBanners = NO;
    self.rootChatView.freezesTranscriptWhenScrolled = NO;
    self.rootChatView.automaticallyScrollsToBottom = NO;
    [self.rootChatView setScrollingEnabled:NO];
    self.rootChatView.renderingSuspended = YES;
    self.rootChatView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.rootChatView];

    self.rootChatView.backgroundColor = tpk_contextMessageBackgroundColor();

    UIView *midSeparator = [[UIView alloc] init];
    midSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    midSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:midSeparator];

    self.repliesStore = [TPKChatMessageStore new];
    self.repliesChatView = [[TPKChatCustomView alloc] initWithStore:self.repliesStore];
    self.repliesChatView.showsReplyBanners = NO;
    self.repliesChatView.freezesTranscriptWhenScrolled = NO;
    self.repliesChatView.renderingSuspended = YES;
    self.repliesChatView.usesThreadReplyIndent = YES;
    self.repliesChatView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelfForThreadHeight = self;
    self.rootChatView.onContentHeightChanged =
        ^(TPKChatCustomView *view) {
        [weakSelfForThreadHeight tpk_contentHeightChangedForView:view];
    };
    self.repliesChatView.onContentHeightChanged =
        ^(TPKChatCustomView *view) {
        [weakSelfForThreadHeight tpk_contentHeightChangedForView:view];
    };
    [container addSubview:self.repliesChatView];

    __weak typeof(self) weakSelfForTarget = self;
    __weak TPKChatCustomView *weakRootChatView = self.rootChatView;
    self.rootChatView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        TPKChatCustomView *sourceView = weakRootChatView;
        if (!sourceView) return;
        [weakSelfForTarget selectReplyTargetForMessageID:messageID
                                                username:username
                                              sourceView:sourceView];
    };
    __weak TPKChatCustomView *weakRepliesChatView = self.repliesChatView;
    self.repliesChatView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        TPKChatCustomView *sourceView = weakRepliesChatView;
        if (!sourceView) return;
        [weakSelfForTarget selectReplyTargetForMessageID:messageID
                                                username:username
                                              sourceView:sourceView];
    };

    UIView *replyBarHost = [[UIView alloc] init];
    replyBarHost.translatesAutoresizingMaskIntoConstraints = NO;
    replyBarHost.clipsToBounds = YES;
    [container addSubview:replyBarHost];
    self.threadReplyTargetBarHostView = replyBarHost;
    [self tpk_attachReplyTargetBarToThreadHost];

    self.replyTargetBarHeightConstraint =
        [replyBarHost.heightAnchor constraintEqualToConstant:0];

    self.rootChatViewHeightConstraint =
        [self.rootChatView.heightAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [closeButton.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:4],
        [closeButton.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kTPKReplyThreadTitleHeight / 2],
        [closeButton.widthAnchor constraintEqualToConstant:26],
        [closeButton.heightAnchor constraintEqualToConstant:26],

        [titleIcon.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:2],
        [titleIcon.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kTPKReplyThreadTitleHeight / 2],
        [titleIcon.widthAnchor constraintEqualToConstant:15],
        [titleIcon.heightAnchor constraintEqualToConstant:15],

        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:6],
        [title.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kTPKReplyThreadTitleHeight / 2],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-12],

        [topSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [topSeparator.topAnchor constraintEqualToAnchor:container.topAnchor constant:kTPKReplyThreadTitleHeight],
        [topSeparator.heightAnchor constraintEqualToConstant:kTPKReplyThreadSeparatorHeight],

        [self.rootChatView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.rootChatView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.rootChatView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
        self.rootChatViewHeightConstraint,

        [midSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [midSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [midSeparator.topAnchor constraintEqualToAnchor:self.rootChatView.bottomAnchor],
        [midSeparator.heightAnchor constraintEqualToConstant:kTPKReplyThreadSeparatorHeight],

        [self.repliesChatView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.repliesChatView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.repliesChatView.topAnchor constraintEqualToAnchor:midSeparator.bottomAnchor],
        [self.repliesChatView.bottomAnchor constraintEqualToAnchor:replyBarHost.topAnchor],

        [replyBarHost.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [replyBarHost.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [replyBarHost.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-kTPKReplyThreadBottomPadding],
        self.replyTargetBarHeightConstraint,
    ]];
}

- (void)tpk_closeTapped {
    [self hide];
}

// Racine synthétique depuis les tags dupliqués par Twitch sur chaque
// réponse (survit à la purge FIFO, sans emotes/badges).
- (TPKChatMessage *)tpk_resolveRootMessageForThreadRootID:(NSString *)threadRootID
                                         anyMessageInThread:(nullable TPKChatMessage *)anyMessage {
    TPKChatMessageStore *mainStore = [TPKManager sharedManager].chatMessageStore;
    TPKChatMessage *root = [mainStore messageWithID:threadRootID];
    if (root) return root;
    if (!anyMessage.replyParentUsername.length) return nil;

    TPKChatMessage *fallback =
        [[TPKChatMessage alloc] initWithMessageID:threadRootID
                                          timestamp:anyMessage.timestamp
                                       authorUserID:@""
                                  authorDisplayName:anyMessage.replyParentUsername
                                            rawText:anyMessage.replyParentBodyPreview ?: @""];
    // Même registre de providers que le chat live (emotes + Zero-Width).
    fallback.tokens = [TPKChatTokenizer tokenizeText:fallback.rawText
                                               providers:tpk_chatEmoteProviders()];
    return fallback;
}

// YES seulement si un vrai reload est lancé (force=NO pour les refreshs
// sans rapport avec ce fil).
- (BOOL)tpk_reloadThreadMessagesForce:(BOOL)force
                            completion:(void (^)(void))completion {
    NSString *threadRootID = [self.currentThreadRootID copy];
    if (!threadRootID.length) return NO;

    TPKChatMessageStore *mainStore = [TPKManager sharedManager].chatMessageStore;
    NSArray<TPKChatMessage *> *threadMessages = [mainStore messagesForThreadRootID:threadRootID];
    TPKChatMessage *rootFromMainStore = [mainStore messageWithID:threadRootID];
    NSMutableArray<TPKChatMessage *> *newReplies = [NSMutableArray array];
    for (TPKChatMessage *message in threadMessages) {
        if ([message.messageID isEqualToString:threadRootID]) {
            if (!rootFromMainStore) rootFromMainStore = message;
        } else if (message.messageID.length) {
            [newReplies addObject:message];
        }
    }

    for (TPKChatMessage *openingMessage in self.openingTranscriptMessages) {
        if ([openingMessage.messageID isEqualToString:threadRootID]) {
            if (!rootFromMainStore) rootFromMainStore = openingMessage;
        } else if ([openingMessage.replyThreadRootID isEqualToString:threadRootID] &&
                   openingMessage.messageID.length) {
            BOOL alreadyPresent = NO;
            for (TPKChatMessage *message in newReplies) {
                if ([message.messageID isEqualToString:openingMessage.messageID]) {
                    alreadyPresent = YES;
                    break;
                }
            }
            if (!alreadyPresent) [newReplies addObject:openingMessage];
        }
    }
    [newReplies sortUsingComparator:^NSComparisonResult(TPKChatMessage *left,
                                                         TPKChatMessage *right) {
        NSComparisonResult dateOrder = [left.timestamp compare:right.timestamp];
        if (dateOrder != NSOrderedSame) return dateOrder;
        return [left.messageID compare:right.messageID];
    }];

    BOOL preservesOpenContext = [self.loadedThreadRootID isEqualToString:threadRootID];
    TPKChatMessage *existingRoot = preservesOpenContext ? self.rootStore.allMessages.firstObject : nil;
    NSArray<TPKChatMessage *> *existingReplies = preservesOpenContext
        ? self.repliesStore.allMessages : @[];

    // Les visibles survivent à la purge FIFO ; on ajoute sans retirer.
    NSMutableDictionary<NSString *, TPKChatMessage *> *currentRepliesByID =
        [NSMutableDictionary dictionaryWithCapacity:newReplies.count];
    for (TPKChatMessage *message in newReplies) {
        if (message.messageID.length) currentRepliesByID[message.messageID] = message;
    }
    NSMutableArray<TPKChatMessage *> *replies =
        [NSMutableArray arrayWithCapacity:existingReplies.count + newReplies.count];
    NSMutableSet<NSString *> *knownReplyIDs = [NSMutableSet set];
    for (TPKChatMessage *existingMessage in existingReplies) {
        NSString *messageID = existingMessage.messageID;
        if (!messageID.length || [knownReplyIDs containsObject:messageID]) continue;
        // Préfère l'instance courante du store ; garde l'ancienne si purgée.
        [replies addObject:currentRepliesByID[messageID] ?: existingMessage];
        [knownReplyIDs addObject:messageID];
    }
    for (TPKChatMessage *message in newReplies) {
        if (![knownReplyIDs containsObject:message.messageID]) {
            [replies addObject:message];
            [knownReplyIDs addObject:message.messageID];
        }
    }
    [replies sortUsingComparator:^NSComparisonResult(TPKChatMessage *left,
                                                      TPKChatMessage *right) {
        NSComparisonResult dateOrder = [left.timestamp compare:right.timestamp];
        if (dateOrder != NSOrderedSame) return dateOrder;
        return [left.messageID compare:right.messageID];
    }];

    TPKChatMessage *root = rootFromMainStore ?: existingRoot;
    if (!root) {
        TPKChatMessage *rootMetadataCarrier = nil;
        for (TPKChatMessage *message in replies) {
            if ([message.replyParentMessageID isEqualToString:threadRootID]) {
                rootMetadataCarrier = message;
                break;
            }
        }
        root = [self tpk_resolveRootMessageForThreadRootID:threadRootID
                                        anyMessageInThread:rootMetadataCarrier ?: replies.firstObject];
    }
    NSString *rootMessageID = root.messageID ?: @"";
    NSArray<NSString *> *replyMessageIDs = tpk_messageIDs(replies);
    BOOL contextChanged = ![self.loadedThreadRootID isEqualToString:threadRootID];
    BOOL rootChanged = force || contextChanged ||
        ![self.lastRequestedRootMessageID isEqualToString:rootMessageID] ||
        self.lastRequestedRootMessage != root;
    BOOL repliesChanged = force || contextChanged ||
        ![self.lastRequestedReplyMessageIDs isEqualToArray:replyMessageIDs] ||
        !tpk_sameMessageInstances(self.lastRequestedReplyMessages ?: @[], replies);
    if (!rootChanged && !repliesChanged) return NO;

    NSUInteger requestToken = ++self.contentRequestGeneration;
    self.loadedThreadRootID = threadRootID;
    self.lastRequestedRootMessageID = rootMessageID;
    self.lastRequestedReplyMessageIDs = replyMessageIDs;
    self.lastRequestedRootMessage = root;
    self.lastRequestedReplyMessages = [replies copy];

    if (rootChanged) [self.rootStore seedReadOnlyWithMessages:root ? @[root] : @[]];
    if (repliesChanged) [self.repliesStore seedReadOnlyWithMessages:replies];

    __block BOOL rootDone = !rootChanged;
    __block BOOL repliesDone = !repliesChanged;
    __weak typeof(self) weakSelf = self;
    void (^maybeFinish)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !rootDone || !repliesDone) return;
        if (requestToken != strongSelf.contentRequestGeneration ||
            ![strongSelf.currentThreadRootID isEqualToString:threadRootID]) return;
        if (completion) completion();
    };

    if (rootChanged) {
        [self.rootChatView reloadMessagesWithCompletion:^{
            rootDone = YES;
            maybeFinish();
        }];
    }
    if (repliesChanged) {
        [self.repliesChatView reloadMessagesWithCompletion:^{
            repliesDone = YES;
            maybeFinish();
        }];
    }
    return YES;
}

// Mesure la hauteur réelle ; la position suit notre chat toute seule.
// Hôte mort (détaché) = on ferme, sans backup.
- (void)tpk_layoutPanelContentInWindow:(UIWindow *)window {
    TPKHostLayoutView *container = self.containerView;
    if (!window || !container || !self.rootChatView || !self.repliesChatView) return;
    if (self.panelLayoutInProgress) {
        self.panelRelayoutPending = YES;
        return;
    }
    TPKChatCustomView *hostView = [container.superview isKindOfClass:[TPKChatCustomView class]]
        ? (TPKChatCustomView *)container.superview : nil;
    if (!hostView || hostView.window != window) {
        hostView = tpk_activeChatCustomView();
    }
    if (!hostView || hostView.hidden || hostView.bounds.size.width < 50 ||
        hostView.window != window) {
        [self hide];
        return;
    }
    if (container.superview != hostView || self.anchorChatView != hostView) {
        [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
        self.anchorChatView = hostView;
        self.containerPositionConstraints =
            [self tpk_attachOverlayView:container toChatView:hostView];
    }
    self.panelLayoutInProgress = YES;
    [window layoutIfNeeded];
    CGFloat inputTopY = CGRectGetMaxY([hostView convertRect:hostView.bounds toView:window]);

    // Réglée par select/cancel AVANT ce recalcul.
    CGFloat replyBarHeight = self.replyTargetBarHeightConstraint.constant;

    CGFloat chromeHeight = kTPKReplyThreadTitleHeight + kTPKReplyThreadSeparatorHeight * 2
                          + kTPKReplyThreadBottomPadding + replyBarHeight;
    CGFloat availableContentHeight = MAX(inputTopY - chromeHeight, 0);

    // La racine reste entière même hors budget ; seules les réponses sont
    // réduites.
    BOOL isLandscape = window.bounds.size.width > window.bounds.size.height;
    NSUInteger visibleLineCount = isLandscape
        ? kTPKReplyThreadLandscapeVisibleLineCount
        : kTPKReplyThreadPortraitVisibleLineCount;
    NSUInteger minimumReplyLineCount = isLandscape
        ? kTPKReplyThreadLandscapeMinimumReplyLineCount
        : kTPKReplyThreadPortraitMinimumReplyLineCount;
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    CGFloat glyphLineHeight = [UIFont systemFontOfSize:cfg.messageFontSize].lineHeight;
    CGFloat renderedLineHeight = ceil(glyphLineHeight + MAX(cfg.lineSpacing, 0) + 8.0);
    CGFloat lineBudgetHeight = renderedLineHeight * visibleLineCount;

    // Phase 1 : hauteur max pour mesurer la racine.
    CGFloat phaseHeight = chromeHeight + availableContentHeight;
    self.containerHeightConstraint.constant = phaseHeight;
    self.rootChatViewHeightConstraint.constant = availableContentHeight;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    CGFloat rootContentHeight = MAX([self.rootChatView tpkContentHeight], 0);

    // Phase 2 : racine à 0 pour mesurer les réponses à leur viewport final.
    self.rootChatViewHeightConstraint.constant = 0;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    CGFloat repliesContentHeight = [self.repliesChatView tpkContentHeight];
    repliesContentHeight = MAX(repliesContentHeight, 0);

    CGFloat allContentHeight = rootContentHeight + repliesContentHeight;
    CGFloat desiredContentHeight = MIN(allContentHeight, lineBudgetHeight);
    // Racine entière + minimum de réponses, borné par l'espace réel.
    desiredContentHeight = MAX(desiredContentHeight, rootContentHeight);
    if (rootContentHeight > 0 && repliesContentHeight > 0) {
        CGFloat minimumRepliesHeight = MIN(repliesContentHeight,
            renderedLineHeight * minimumReplyLineCount);
        desiredContentHeight = MAX(desiredContentHeight,
            rootContentHeight + minimumRepliesHeight);
    }
    desiredContentHeight = MIN(desiredContentHeight, availableContentHeight);

    CGFloat rootHeight = MIN(rootContentHeight, desiredContentHeight);
    CGFloat remainingForReplies = MAX(desiredContentHeight - rootHeight, 0);
    CGFloat repliesHeight = MIN(repliesContentHeight, remainingForReplies);
    self.rootChatViewHeightConstraint.constant = rootHeight;

    CGFloat totalHeight = chromeHeight + rootHeight + repliesHeight;
    if (rootHeight + repliesHeight <= 0) {
        totalHeight = chromeHeight + MIN(renderedLineHeight, availableContentHeight);
    }
    totalHeight = MIN(totalHeight, inputTopY);

    self.containerHeightConstraint.constant = totalHeight;
    self.measuredContainerWidth = CGRectGetWidth(self.containerView.bounds);
    self.measuredHostMaxY = inputTopY;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    self.panelLayoutInProgress = NO;
    if (self.panelRelayoutPending) {
        self.panelRelayoutPending = NO;
        [self tpk_scheduleContentLayoutForView:self.rootChatView];
    }
}

- (void)tpk_finishOpeningThreadRootID:(NSString *)threadRootID
                                window:(UIWindow *)window
                      allowsCatchUpPass:(BOOL)allowsCatchUpPass {
    if (!window || self.containerView.window != window ||
        ![self.currentThreadRootID isEqualToString:threadRootID]) return;

    if (allowsCatchUpPass && self.contentRefreshPendingWhileOpening) {
        self.contentRefreshPendingWhileOpening = NO;
        __weak typeof(self) weakSelf = self;
        BOOL started = [self tpk_reloadThreadMessagesForce:YES completion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf tpk_finishOpeningThreadRootID:threadRootID
                                                window:window
                                      allowsCatchUpPass:NO];
        }];
        if (started) return;
    }

    [self.containerView layoutIfNeeded];
    [self tpk_layoutPanelContentInWindow:window];
    self.containerView.hidden = NO;
    [self.containerView.superview bringSubviewToFront:self.containerView];

    // Rattrapage d'un événement arrivé pendant l'ouverture.
    if (self.contentRefreshPendingWhileOpening) {
        self.contentRefreshPendingWhileOpening = NO;
        [self forceRefreshIfNeeded];
    }
}

- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID
     retainedThreadMessages:(NSArray<TPKChatMessage *> *)retainedThreadMessages
                   sourceView:(TPKChatCustomView *)sourceView {
    if (!threadRootID.length) return;
    TPKChatCustomView *hostChatView = tpk_activeChatCustomView();
    UIWindow *window = hostChatView.window;
    if (!hostChatView || !window) return;

    [self tpk_clearReplyTargetRemovingMention];
    [self tpk_clearThreadSourceHighlight];
    [self tpk_ensureContainerInChatView:hostChatView];
    [self tpk_attachReplyTargetBarToThreadHost];
    self.contentRequestGeneration += 1;
    self.containerView.hidden = YES;
    self.rootChatView.renderingSuspended = YES;
    self.repliesChatView.renderingSuspended = YES;
    [self.rootChatView resetTransientTranscriptState];
    [self.repliesChatView resetTransientTranscriptState];
    self.loadedThreadRootID = nil;
    self.lastRequestedRootMessageID = nil;
    self.lastRequestedReplyMessageIDs = nil;
    self.lastRequestedRootMessage = nil;
    self.lastRequestedReplyMessages = nil;
    self.contentRefreshPendingWhileOpening = NO;
    self.openingTranscriptMessages = [retainedThreadMessages copy] ?: @[];
    self.titleLabel.text = L(@"chat_reply_thread_panel_title");
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.currentThreadRootID = threadRootID;
    self.threadSourceView = sourceView;
    self.threadSourceMessageID = tappedMessageID;
    [sourceView setReplyTargetHighlightedMessageID:tappedMessageID];
    self.rootChatView.renderingSuspended = NO;
    self.repliesChatView.renderingSuspended = NO;

    // Pas de sélection auto ; le contenu doit être appliqué avant mesure
    // (sinon dimensionné sur du vide + flash au refresh suivant).
    __weak typeof(self) weakSelf = self;
    [self tpk_reloadThreadMessagesForce:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.containerView.window != window ||
            ![strongSelf.currentThreadRootID isEqualToString:threadRootID]) return;
        [strongSelf tpk_finishOpeningThreadRootID:threadRootID
                                            window:window
                                  allowsCatchUpPass:YES];
    }];
}

// Retrouve l'instance affichée, même purgée du FIFO (transcript figé).
- (nullable TPKChatMessage *)tpk_messageForReplyTargetID:(NSString *)messageID {
    TPKChatMessage *message = [self.rootStore messageWithID:messageID];
    if (!message) message = [self.repliesStore messageWithID:messageID];
    if (!message) message = [tpk_activeChatCustomView() displayedMessageWithID:messageID];
    if (!message) {
        message = [[TPKManager sharedManager].chatMessageStore messageWithID:messageID];
    }
    return message;
}

- (void)selectReplyTargetForMessageID:(NSString *)messageID username:(NSString *)username {
    TPKChatCustomView *sourceView = tpk_activeChatCustomView();
    if (!sourceView) return;
    [self selectReplyTargetForMessageID:messageID
                               username:username
                             sourceView:sourceView];
}

- (void)selectReplyTargetForMessageID:(NSString *)messageID
                             username:(NSString *)username
                           sourceView:(TPKChatCustomView *)sourceView {
    if (!messageID.length || !username.length) return;

    BOOL replyComesFromThread =
        sourceView == self.rootChatView || sourceView == self.repliesChatView;

    // Changement de cible = même nettoyage qu'« Annuler ». Depuis le chat
    // principal avec un Fil ouvert, hide invalide aussi les completions du Fil.
    if (!replyComesFromThread && self.currentThreadRootID.length) {
        [self hide];
    } else {
        [self tpk_clearReplyTargetRemovingMention];
    }

    self.selectedReplyTargetMessageID = messageID;
    self.selectedReplyTargetUsername = username;
    self.replyTargetSourceView = sourceView;
    [sourceView setReplyTargetHighlightedMessageID:messageID];
    [self tpk_ensureReplyTargetBar];
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.replyTargetBarLabel.attributedText = tpk_buildReplyTargetBarText(username);

    if (replyComesFromThread) {
        self.replyTargetMessageView.hidden = YES;
        self.replyTargetMessageView.renderingSuspended = YES;
        self.replyTargetMessageViewHeightConstraint.constant = 0;
        [self tpk_attachReplyTargetBarToThreadHost];
        self.replyTargetBarHeightConstraint.constant = kTPKReplyTargetActionRowHeight;
        self.replyTargetBarView.hidden = NO;
    } else {
        TPKChatMessage *message = [sourceView displayedMessageWithID:messageID];
        if (!message) message = [self tpk_messageForReplyTargetID:messageID];

        self.replyTargetBarHeightConstraint.constant = 0;
        self.replyTargetMessageView.hidden = NO;
        self.replyTargetMessageView.renderingSuspended = NO;
        self.replyTargetMessageViewHeightConstraint.constant = 0;
        [self.replyTargetMessageView resetTransientTranscriptState];
        [self.replyTargetMessageStore seedReadOnlyWithMessages:message ? @[message] : @[]];

        TPKChatCustomView *hostView = sourceView;
        [self tpk_showStandaloneForChatView:hostView];

        // Attendre le vrai snapshot, mesurer à la largeur finale.
        NSString *requestedMessageID = [messageID copy];
        __weak typeof(self) weakSelf = self;
        [self.replyTargetMessageView reloadMessagesWithCompletion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf ||
                ![strongSelf.selectedReplyTargetMessageID isEqualToString:requestedMessageID] ||
                strongSelf.replyTargetSourceView != sourceView) return;

            strongSelf.replyTargetBarView.hidden = NO;
            if ([strongSelf.replyTargetBarView.superview isKindOfClass:[TPKChatCustomView class]]) {
                [strongSelf tpk_resizeStandaloneForChatView:
                    (TPKChatCustomView *)strongSelf.replyTargetBarView.superview];
            }
        }];
    }

    self.lastInsertedMentionText = tpk_insertMentionAtStartOfChatInput(username);

    if (replyComesFromThread) {
        [self tpk_layoutPanelContentInWindow:self.containerView.window];
    }
}

- (void)tpk_clearReplyTargetRemovingMention {
    [self.replyTargetSourceView setReplyTargetHighlightedMessageID:nil];
    self.replyTargetSourceView = nil;
    self.selectedReplyTargetMessageID = nil;
    self.selectedReplyTargetUsername = nil;
    self.replyTargetMessageView.hidden = YES;
    self.replyTargetMessageView.renderingSuspended = YES;
    self.replyTargetMessageViewHeightConstraint.constant = 0;
    self.replyTargetBarView.hidden = YES;
    self.replyTargetBarHeightConstraint.constant = 0;

    if (self.lastInsertedMentionText.length) {
        tpk_removeExactPrefixFromChatInput(self.lastInsertedMentionText);
        self.lastInsertedMentionText = nil;
    }

    // Vue masquée hors Fil : retirée pour ne jamais intercepter les taps.
    if (self.replyTargetBarView.superview != self.threadReplyTargetBarHostView) {
        [NSLayoutConstraint deactivateConstraints:self.standalonePositionConstraints ?: @[]];
        self.standalonePositionConstraints = nil;
        if (self.standaloneReplyBarHeightConstraint) {
            self.standaloneReplyBarHeightConstraint.active = NO;
        }
        [self.replyTargetBarView removeFromSuperview];
    }
}

- (void)tpk_clearThreadSourceHighlight {
    [self.threadSourceView setReplyTargetHighlightedMessageID:nil];
    self.threadSourceView = nil;
    self.threadSourceMessageID = nil;
}

- (void)tpk_cancelReplyTargetTapped {
    UIWindow *window = self.containerView.window;
    BOOL shouldRelayoutThread = self.currentThreadRootID.length > 0 &&
        window && !self.containerView.hidden;
    [self tpk_clearReplyTargetRemovingMention];
    if (shouldRelayoutThread) [self tpk_layoutPanelContentInWindow:window];
}

- (void)hide {
    self.contentRequestGeneration += 1;
    self.containerView.hidden = YES;
    self.rootChatView.renderingSuspended = YES;
    self.repliesChatView.renderingSuspended = YES;
    self.currentThreadRootID = nil;
    self.loadedThreadRootID = nil;
    self.lastRequestedRootMessageID = nil;
    self.lastRequestedReplyMessageIDs = nil;
    self.lastRequestedRootMessage = nil;
    self.lastRequestedReplyMessages = nil;
    self.contentRefreshPendingWhileOpening = NO;
    self.openingTranscriptMessages = nil;
    [self.rootChatView resetTransientTranscriptState];
    [self.repliesChatView resetTransientTranscriptState];
    [self tpk_clearThreadSourceHighlight];
    [self tpk_clearReplyTargetRemovingMention];
}

- (void)refreshIfNeeded {
    if (!self.currentThreadRootID.length) return;
    if (self.containerView.hidden) {
        self.contentRefreshPendingWhileOpening = YES;
        return;
    }
    UIWindow *window = self.containerView.window;
    __weak typeof(self) weakSelf = self;
    [self tpk_reloadThreadMessagesForce:NO completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !window || strongSelf.containerView.hidden) return;
        [strongSelf tpk_layoutPanelContentInWindow:window];
    }];
}

- (void)forceRefreshIfNeeded {
    if (!self.currentThreadRootID.length) return;
    if (self.containerView.hidden) {
        self.contentRefreshPendingWhileOpening = YES;
        return;
    }
    UIWindow *window = self.containerView.window;
    __weak typeof(self) weakSelf = self;
    [self tpk_reloadThreadMessagesForce:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !window || strongSelf.containerView.hidden) return;
        [strongSelf tpk_layoutPanelContentInWindow:window];
    }];
}

- (void)retokenizeVisibleMessagesWithCompletion:(void (^)(void))completion {
    // Instances partagées avec le store principal, sauf racine synthétique
    // et preview autonome : inclure les 3 stores contre les tokens périmés.
    NSMutableArray<TPKChatMessageStore *> *stores = [NSMutableArray arrayWithCapacity:3];
    if (self.rootStore) [stores addObject:self.rootStore];
    if (self.repliesStore) [stores addObject:self.repliesStore];
    if (self.replyTargetMessageStore) [stores addObject:self.replyTargetMessageStore];

    if (!stores.count) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }

    NSArray<id<TPKEmoteProvider>> *providers = tpk_chatEmoteProviders();
    dispatch_group_t group = dispatch_group_create();
    for (TPKChatMessageStore *store in stores) {
        dispatch_group_enter(group);
        [store retokenizeMessagesUsingBlock:^NSArray<TPKChatToken *> *(TPKChatMessage *message) {
            return [TPKChatTokenizer tokenizeText:message.rawText ?: @""
                                      twitchEmotesTag:message.twitchEmotesTag ?: @""
                                          twitchGIFsTag:message.twitchGIFsTag ?: @""
                                            providers:providers];
        } completion:^{
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // La preview autonome n'est pas dans le reload du fil : refresh explicite.
        if (self.replyTargetMessageView &&
            self.replyTargetMessageStore.allMessages.count > 0 &&
            !self.replyTargetMessageView.hidden) {
            [self.replyTargetMessageView reloadMessagesWithCompletion:^{
                if (completion) completion();
            }];
        } else if (completion) {
            completion();
        }
    });
}

- (void)refreshMessageIfNeededWithID:(NSString *)messageID
                       excludingView:(TPKChatCustomView *)excludedView {
    if (!messageID.length || !self.currentThreadRootID.length) return;
    if (self.containerView.hidden) {
        self.contentRefreshPendingWhileOpening = YES;
        return;
    }
    BOOL rootContainsMessage = [self.rootStore messageWithID:messageID] != nil;
    BOOL repliesContainMessage = [self.repliesStore messageWithID:messageID] != nil;
    BOOL reloadRoot = rootContainsMessage && self.rootChatView != excludedView;
    BOOL reloadReplies = repliesContainMessage && self.repliesChatView != excludedView;
    BOOL excludedViewAlreadyReloaded =
        (rootContainsMessage && self.rootChatView == excludedView) ||
        (repliesContainMessage && self.repliesChatView == excludedView);
    if (!reloadRoot && !reloadReplies && !excludedViewAlreadyReloaded) return;

    __block NSUInteger pendingReloads = (reloadRoot ? 1 : 0) + (reloadReplies ? 1 : 0);
    NSUInteger requestToken = self.contentRequestGeneration;
    NSString *threadRootID = [self.currentThreadRootID copy];
    UIWindow *window = self.containerView.window;
    __weak typeof(self) weakSelf = self;
    void (^relayoutIfCurrent)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || requestToken != strongSelf.contentRequestGeneration ||
            strongSelf.containerView.hidden || strongSelf.containerView.window != window ||
            ![strongSelf.currentThreadRootID isEqualToString:threadRootID]) return;
        [strongSelf tpk_layoutPanelContentInWindow:window];
    };
    void (^oneReloadFinished)(void) = ^{
        if (pendingReloads > 0) pendingReloads -= 1;
        if (pendingReloads == 0) relayoutIfCurrent();
    };

    if (reloadRoot) {
        [self.rootChatView refreshMessageWithID:messageID animated:YES
                                      completion:oneReloadFinished];
    }
    if (reloadReplies) {
        [self.repliesChatView refreshMessageWithID:messageID animated:YES
                                         completion:oneReloadFinished];
    }
    if (!reloadRoot && !reloadReplies) relayoutIfCurrent();
}

- (void)applyModerationState:(TPKChatMessageState)state
   toRetainedMessageWithID:(NSString *)messageID
             moderationKind:(TPKChatModerationKind)moderationKind
            durationSeconds:(NSInteger)durationSeconds {
    if (!messageID.length) return;
    [self.rootChatView applyModerationState:state
                toDisplayedMessageWithID:messageID
                         moderationKind:moderationKind
                        durationSeconds:durationSeconds];
    [self.repliesChatView applyModerationState:state
                   toDisplayedMessageWithID:messageID
                            moderationKind:moderationKind
                           durationSeconds:durationSeconds];

    NSMutableArray<TPKChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (TPKChatMessage *message in retained) {
        if (![message.messageID isEqualToString:messageID]) continue;
        [message applyModerationState:state
                       moderationKind:moderationKind
                      durationSeconds:durationSeconds];
    }
}

- (void)applyModerationToRetainedMessagesForUserID:(NSString *)authorUserID
                                      authorLogin:(NSString *)authorLogin
                                    moderationKind:(TPKChatModerationKind)moderationKind
                                   durationSeconds:(NSInteger)durationSeconds {
    if (!authorUserID.length && !authorLogin.length) return;
    [self.rootChatView applyModerationToDisplayedMessagesForUserID:authorUserID
                                                       authorLogin:authorLogin
                                                    moderationKind:moderationKind
                                                   durationSeconds:durationSeconds];
    [self.repliesChatView applyModerationToDisplayedMessagesForUserID:authorUserID
                                                          authorLogin:authorLogin
                                                       moderationKind:moderationKind
                                                      durationSeconds:durationSeconds];

    NSMutableArray<TPKChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (TPKChatMessage *message in retained) {
        BOOL matchesUserID = authorUserID.length &&
            [message.authorUserID isEqualToString:authorUserID];
        BOOL matchesFallbackLogin = !message.authorUserID.length && authorLogin.length &&
            [message.authorDisplayName caseInsensitiveCompare:authorLogin] == NSOrderedSame;
        if (!matchesUserID && !matchesFallbackLogin) continue;
        [message applyModerationState:TPKChatMessageStateDeletedCollapsed
                       moderationKind:moderationKind
                      durationSeconds:durationSeconds];
    }
}

- (void)applyModerationToAllRetainedMessages {
    [self.rootChatView applyModerationToAllDisplayedMessages];
    [self.repliesChatView applyModerationToAllDisplayedMessages];

    NSMutableArray<TPKChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (TPKChatMessage *message in retained) {
        if (message.type == TPKChatMessageTypeHistoryWelcome ||
            message.type == TPKChatMessageTypeHistoryDivider) continue;
        [message applyModerationState:TPKChatMessageStateDeletedCollapsed
                       moderationKind:TPKChatModerationKindChatCleared
                      durationSeconds:0];
    }
}

@end
