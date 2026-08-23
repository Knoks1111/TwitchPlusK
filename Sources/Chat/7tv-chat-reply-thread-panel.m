/*
 * 7tv-chat-reply-thread-panel.m
 *
 * Panneau "Fil" (réponses) — flottant au-dessus du chat réel, montre tous
 * les messages d'un fil (S7TVChatMessage.replyThreadRootID) via deux
 * SevenTVChatCustomView dédiées (racine épinglée + réponses scrollables)
 * branchées sur des stores TEMPORAIRES peuplés via -seedReadOnlyWithMessages:
 * avec les mêmes instances de message que le store principal — aucun
 * recalcul, rendu strictement identique au chat principal.
 *
 * Écrire une réponse depuis ce panneau (poster vers Twitch) n'est PAS
 * encore implémenté — ça touche l'envoi WebSocket réel, prévu comme étape
 * séparée. Pour l'instant : consultation seule, fermeture via le bouton ✕.
 *
 * Extrait de 7tv-core-runtime-hooks.m (voir migration-panneau-fil.md). Les accès à la
 * barre de saisie et à la vue de chat active sont exposés par
 * 7tv-chat-custom-view.h, qui possède désormais leur cycle de vie.
 */

#import "Chat/7tv-chat-reply-thread-panel.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Chat/7tv-chat-message.h"
#import "Core/7tv-core-manager.h"
#import "Localization/7tv-localization-manager.h"
#import "Chat/7tv-chat-tokenizer.h"

// Insère "@pseudo " au tout DÉBUT du texte de la barre de saisie native
// (pas au curseur comme le picker d'emotes le fait pour les noms d'emotes)
// — utilisé pour le panneau Fil : à défaut d'un vrai tag reply-parent-msg-id
// (touche l'envoi WebSocket réel, gardé de côté pour l'instant), on @
// mentionne au moins la personne visée automatiquement, pour continuer la
// conversation sans taper le pseudo à la main.
//
// Même technique que 7tv-picker-controller.m (paste: sur le UITextView) :
// insertText: seul modifie le buffer UITextInput mais ne notifie pas le
// binding SwiftUI côté Twitch, paste: déclenche le pipeline complet.
// No-op si le texte commence déjà par cette mention (évite d'empiler les @
// si on rouvre le même fil plusieurs fois de suite).
// Insère "@pseudo " au tout DÉBUT du texte SANS ouvrir le clavier — pas de
// becomeFirstResponder (contrairement au picker d'emotes, où le textView
// était déjà premier répondant puisque le clavier était déjà ouvert à ce
// moment-là). Ici on tape la flèche depuis le panneau Fil : le clavier est
// fermé, et le faire apparaître via becomeFirstResponder posait 2 problèmes
// distincts, tous deux corrigés en le retirant :
//   1. Le panneau Fil ne se repositionne pas quand le clavier apparaît (pas
//      d'observer sur les notifications clavier) → il finissait recouvert.
//   2. becomeFirstResponder établit la session clavier de façon pas garantie
//      synchrone sur ce bridge SwiftUI — enchaîner selectedRange/paste juste
//      après pouvait s'exécuter avant que la session soit prête → no-op
//      silencieux (rien ne s'écrivait).
//
// Mutation directe de .text (plus de paste:/pasteboard, plus fiable et plus
// simple) + notification manuelle de changement : c'est CETTE notification
// (pas paste: en tant que tel) qui prévient le binding SwiftUI côté Twitch —
// déjà présente comme étape obligatoire après insertText: dans la version
// précédente, donc le mécanisme réellement nécessaire, indépendant du focus.
// Cherche le UITextView/UITextField réellement interactif dans
// ChatInputView. Le 1er UITextView trouvé n'est pas forcément le bon (logs
// du 20/08 : un candidat avait delegate=nil → vue décorative interne à
// UIKit, pas celle liée au binding SwiftUI de Twitch) — on liste tous les
// candidats et on privilégie celui qui a un delegate.
static UITextView *s7tv_findActiveChatTextView(UITextField * _Nullable * _Nullable outTextField) {
    UIView *inputRoot = s7tv_findChatInputView();
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
// s7tv_removeExactPrefixFromChatInput ci-dessous). nil si rien n'a été
// inséré (vue introuvable, ou la transformation a fait quelque chose
// d'imprévisible qu'on ne peut pas retirer en confiance).
static NSString *s7tv_insertMentionAtStartOfChatInput(NSString *username) {
    if (!username.length) return nil;

    UITextField *textField = nil;
    UITextView *textView = s7tv_findActiveChatTextView(&textField);
    NSString *mention = [NSString stringWithFormat:@"@%@ ", username];

    if (textView) {
        NSString *current = textView.text ?: @"";

        textView.text = [mention stringByAppendingString:current];
        textView.selectedRange = NSMakeRange(mention.length, 0); // curseur juste après la mention

        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextViewTextDidChangeNotification
                          object:textView];
        if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [textView.delegate textViewDidChange:textView];
        }

        NSString *finalText = textView.text ?: @"";
        NSInteger insertedLength = (NSInteger)finalText.length - (NSInteger)current.length;

        if (insertedLength <= 0 || insertedLength > (NSInteger)finalText.length) {
            return mention; // transformation imprévisible, repli sur le texte brut plutôt que planter
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

// Retire exactement `exactPrefix` (tel que retourné par
// s7tv_insertMentionAtStartOfChatInput — déjà transformé, pas le "@pseudo "
// brut) du début du texte actuel. No-op si le texte ne commence plus par ce
// préfixe précis (l'utilisateur a édité entre-temps) — on ne devine jamais,
// on ne touche à rien plutôt que de risquer de couper un texte qu'il a écrit
// lui-même.
static void s7tv_removeExactPrefixFromChatInput(NSString *exactPrefix) {
    if (!exactPrefix.length) return;

    UITextField *textField = nil;
    UITextView *textView = s7tv_findActiveChatTextView(&textField);

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
// ────────────────────────────────────────────────────────────
// MARK: - Panneau "Fil" (réponses) — lecture seule pour l'instant
// ────────────────────────────────────────────────────────────
//
// Flottant au-dessus du chat réel (même window que s_activeChatCustomView),
// montre tous les messages d'un fil (S7TVChatMessage.replyThreadRootID) via
// une SevenTVChatCustomView DÉDIÉE branchée sur un store TEMPORAIRE peuplé
// via -seedReadOnlyWithMessages: (pas -addMessage: — évite de recompter
// replyCount ou de perturber le registre couleur, voir 7tv-chat-message.m)
// avec les mêmes instances de message que le store principal : tokens,
// emotes, badges déjà résolus, aucun recalcul, rendu strictement identique
// au chat principal sans dupliquer la moindre logique de rendu.
//
// Écrire une réponse depuis ce panneau (poster vers Twitch) n'est PAS
// encore implémenté — ça touche l'envoi WebSocket réel, prévu comme étape
// séparée. Pour l'instant : consultation seule, fermeture via le bouton ✕.
static const CGFloat kS7TVReplyThreadTitleHeight = 26.0;   // ligne titre "Fil" + bouton fermer — resserré pour mobile
static const CGFloat kS7TVReplyThreadSeparatorHeight = 1.0;
static const CGFloat kS7TVReplyThreadBottomPadding = 8.0;
static const CGFloat kS7TVReplyTargetBarHeight = 34.0; // barre "Répondre à @X · Annuler", masquée (0) tant qu'aucune cible n'est choisie

// Construit "Réponse à @pseudo   •   " avec le pseudo ET le séparateur en
// gras, le reste normal — "annuler" reste un UIButton séparé juste après
// (voir s7tv_ensureReplyTargetBar), pas inclus ici.
static NSAttributedString *s7tv_buildReplyTargetBarText(NSString *username) {
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

@interface S7TVReplyThreadPanel ()
@property (nonatomic, weak) UIView *containerView;
// Contraintes externes du panneau complet. Comme pour la barre autonome,
// son bas est relié directement au haut de la vraie saisie Twitch : aucun
// recalcul ponctuel de frame quand le clavier ou la hauteur du champ change.
@property (nonatomic, strong) NSLayoutConstraint *containerHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *containerPositionConstraints;
@property (nonatomic, weak) UIView *containerInputAnchorView;
// Référence gardée pour rafraîchir le texte à chaque ouverture (voir
// s7tv_closeTapped... non, voir showForThreadRootID:) — sans ça, le titre
// restait figé dans la langue active AU MOMENT de la création du panneau
// (une seule fois, panneau réutilisé ensuite), donc un changement de langue
// en cours de session ne se voyait qu'après un restart de l'app.
@property (nonatomic, weak) UILabel *titleLabel;
// Même souci que titleLabel ci-dessus, même fix : le titre du bouton n'était
// posé qu'à la création du panneau (une seule fois) — jamais relu, donc
// figé dans la langue active à ce moment-là.
@property (nonatomic, weak) UIButton *cancelButton;
// Message racine, ÉPINGLÉ en haut, jamais scrollable — sa propre
// SevenTVChatCustomView contient TOUJOURS exactement 0 ou 1 message, donc
// sa table ne peut physiquement pas scroller (contentSize == bounds une
// fois la hauteur ajustée au contenu, voir s7tv_layoutPanelContent).
@property (nonatomic, strong) SevenTVChatCustomView *rootChatView;
@property (nonatomic, strong) S7TVChatMessageStore *rootStore;
@property (nonatomic, strong) NSLayoutConstraint *rootChatViewHeightConstraint;
// Réponses du fil (racine exclue), scrollables normalement (comportement
// UITableView natif, rien à faire de spécial).
@property (nonatomic, strong) SevenTVChatCustomView *repliesChatView;
@property (nonatomic, strong) S7TVChatMessageStore *repliesStore;
@property (nonatomic, copy) NSString *currentThreadRootID;
// Le message sur lequel l'utilisateur a tapé pour OUVRIR ce fil — gardé en
// mémoire mais N'EST PLUS auto-sélectionné comme cible (voir demande :
// aucune sélection automatique à l'ouverture, l'utilisateur choisit
// explicitement via le bouton flèche sur le message de son choix).
@property (nonatomic, copy) NSString *pendingReplyTargetMessageID;

// ── Sélection de cible de réponse (bouton flèche par message) ──────────
// Non-nil uniquement quand l'utilisateur a explicitement tapé le bouton
// flèche d'un message — voir selectReplyTargetForMessageID:username:. C'est LÀ
// (pas à l'ouverture) que la mention @X s'insère dans la barre de saisie.
@property (nonatomic, copy) NSString *selectedReplyTargetMessageID;
@property (nonatomic, copy) NSString *selectedReplyTargetUsername;
// Texte RÉELLEMENT inséré dans la barre de saisie, tel que renvoyé par
// s7tv_insertMentionAtStartOfChatInput (déjà transformé par Twitch — ex:
// "[@X](https://t.me/X) " plutôt que "@X " brut, voir cette fonction). C'est
// CE texte exact qu'il faut retirer pour annuler proprement, jamais une
// reconstruction devinée à partir du pseudo — la transformation n'est pas
// prévisible depuis ici.
@property (nonatomic, copy) NSString *lastInsertedMentionText;
// Barre du bas "Répondre à @X · Annuler" — masquée tant qu'aucune cible
// n'est sélectionnée. Hauteur pilotée par replyTargetBarHeightConstraint
// (0 = masquée) plutôt qu'un simple .hidden, pour que
// s7tv_layoutPanelContentInWindow: puisse recalculer la hauteur totale du
// panneau en conséquence (la barre prend de la place quand elle apparaît).
// Une seule et même barre est déplacée entre le panneau Fil et la fenêtre
// principale selon l'origine de la réponse. On ne duplique donc ni son UI,
// ni son état, ni ses actions.
@property (nonatomic, strong) UIView *replyTargetBarView;
@property (nonatomic, weak) UILabel *replyTargetBarLabel;
@property (nonatomic, weak) UIView *threadReplyTargetBarHostView;
@property (nonatomic, strong) NSLayoutConstraint *replyTargetBarHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *standaloneReplyBarConstraints;
- (void)s7tv_clearReplyTargetRemovingMention;
@end

@implementation S7TVReplyThreadPanel

+ (instancetype)sharedPanel {
    static S7TVReplyThreadPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [S7TVReplyThreadPanel new]; });
    return instance;
}

- (void)chatCustomView:(SevenTVChatCustomView *)view
    didTapReplyBannerForThreadRootID:(NSString *)threadRootID
                       tappedMessageID:(NSString *)tappedMessageID {
    [self showForThreadRootID:threadRootID tappedMessageID:tappedMessageID];
}

// Construit la barre de réponse une seule fois. Cette même instance est
// hébergée soit dans le bas du panneau Fil, soit directement au-dessus de
// la saisie Twitch pour une réponse initiée depuis le chat principal.
- (void)s7tv_ensureReplyTargetBar {
    if (self.replyTargetBarView) return;

    UIView *replyBar = [[UIView alloc] init];
    replyBar.clipsToBounds = YES;
    replyBar.hidden = YES;
    self.replyTargetBarView = replyBar;

    UIView *separator = [[UIView alloc] init];
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [replyBar addSubview:separator];

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
    [cancelButton addTarget:self action:@selector(s7tv_cancelReplyTargetTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [replyBar addSubview:cancelButton];
    self.cancelButton = cancelButton;

    [NSLayoutConstraint activateConstraints:@[
        [separator.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:replyBar.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:replyBar.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:kS7TVReplyThreadSeparatorHeight],

        [label.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:replyBar.centerYAnchor constant:2],

        [cancelButton.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8],
        [cancelButton.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [cancelButton.trailingAnchor constraintLessThanOrEqualToAnchor:replyBar.trailingAnchor constant:-12],
    ]];
}

- (void)s7tv_attachReplyTargetBarToThreadHost {
    UIView *host = self.threadReplyTargetBarHostView;
    if (!host) return;
    [self s7tv_ensureReplyTargetBar];
    [NSLayoutConstraint deactivateConstraints:self.standaloneReplyBarConstraints ?: @[]];
    self.standaloneReplyBarConstraints = nil;
    [self.replyTargetBarView removeFromSuperview];
    self.replyTargetBarView.translatesAutoresizingMaskIntoConstraints = YES;
    self.replyTargetBarView.backgroundColor = [UIColor clearColor];
    self.replyTargetBarView.layer.cornerRadius = 0;
    self.replyTargetBarView.frame = host.bounds;
    self.replyTargetBarView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:self.replyTargetBarView];
}

- (void)s7tv_showStandaloneReplyTargetBarInWindow:(UIWindow *)window {
    if (!window) return;
    [self s7tv_ensureReplyTargetBar];
    [NSLayoutConstraint deactivateConstraints:self.standaloneReplyBarConstraints ?: @[]];
    [self.replyTargetBarView removeFromSuperview];
    self.replyTargetBarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.replyTargetBarView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.replyTargetBarView.layer.cornerRadius = 10;
    self.replyTargetBarView.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

    [window addSubview:self.replyTargetBarView];
    UIView *inputView = s7tv_findChatInputView();
    NSLayoutYAxisAnchor *bottomAnchor = (inputView && inputView.window == window)
        ? inputView.topAnchor
        : window.safeAreaLayoutGuide.bottomAnchor;
    self.standaloneReplyBarConstraints = @[
        [self.replyTargetBarView.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [self.replyTargetBarView.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [self.replyTargetBarView.bottomAnchor constraintEqualToAnchor:bottomAnchor],
        [self.replyTargetBarView.heightAnchor constraintEqualToConstant:kS7TVReplyTargetBarHeight],
    ];
    [NSLayoutConstraint activateConstraints:self.standaloneReplyBarConstraints];
    self.replyTargetBarView.hidden = NO;
    [window bringSubviewToFront:self.replyTargetBarView];
}

- (void)s7tv_updateContainerPositionConstraintsInWindow:(UIWindow *)window {
    UIView *container = self.containerView;
    if (!container || !window) return;

    UIView *inputView = s7tv_findChatInputView();
    if (inputView.window != window) inputView = nil;
    if (self.containerPositionConstraints.count > 0 &&
        self.containerInputAnchorView == inputView) return;

    [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
    self.containerInputAnchorView = inputView;
    NSLayoutYAxisAnchor *bottomAnchor = inputView
        ? inputView.topAnchor
        : window.safeAreaLayoutGuide.bottomAnchor;
    self.containerPositionConstraints = @[
        [container.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.containerPositionConstraints];
}

- (void)s7tv_ensureContainerInWindow:(UIWindow *)window {
    if (self.containerView.window == window) {
        [self s7tv_updateContainerPositionConstraintsInWindow:window];
        return;
    }
    [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
    self.containerPositionConstraints = nil;
    self.containerHeightConstraint = nil;
    self.containerInputAnchorView = nil;
    [self.containerView removeFromSuperview];

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0]; // opaque (pas 0.97) : évite tout effet de transparence qui laissait deviner le chat derrière
    container.layer.cornerRadius = 14;
    container.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    container.clipsToBounds = YES;
    container.hidden = YES;
    [window addSubview:container];
    self.containerView = container;
    CGFloat initialHeight = kS7TVReplyThreadTitleHeight +
        kS7TVReplyThreadSeparatorHeight * 2 +
        kS7TVReplyThreadBottomPadding + 44.0;
    self.containerHeightConstraint =
        [container.heightAnchor constraintEqualToConstant:initialHeight];
    self.containerHeightConstraint.active = YES;
    [self s7tv_updateContainerPositionConstraintsInWindow:window];

    UIImageView *titleIcon = [[UIImageView alloc] init];
    UIImageSymbolConfiguration *titleIconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    // bubble.left.and.bubble.right est un symbole large (pas carré) — forcé
    // dans un cadre carré en mode étirement par défaut, ça l'écrasait.
    // bubble.left.fill est quasi carré, aspectFit garde ses proportions
    // dans tous les cas même si la police système change la forme exacte.
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
    [closeButton addTarget:self action:@selector(s7tv_closeTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:closeButton];

    UIView *topSeparator = [[UIView alloc] init];
    topSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:topSeparator];

    // ── Racine épinglée (jamais scrollable) ──────────────────────────────
    self.rootStore = [S7TVChatMessageStore new];
    self.rootChatView = [[SevenTVChatCustomView alloc] initWithStore:self.rootStore];
    self.rootChatView.showsReplyBanners = NO; // voir commentaire showsReplyBanners dans 7tv-chat-custom-view.h
    self.rootChatView.translatesAutoresizingMaskIntoConstraints = NO;
    // userInteractionEnabled reste YES (pas de = NO ici) : le bouton de
    // sélection de cible (showsReplyTargetButton ci-dessous) doit rester
    // tapable même sur la racine — on peut répondre au tout premier message
    // du fil aussi. Aucun risque de scroll accidentel : sa hauteur est
    // toujours exactement calée sur son contenu (0 ou 1 message), rien à
    // scroller physiquement même avec les interactions actives.
    [container addSubview:self.rootChatView];

    // Léger fond distinct pour lire "racine" comme un bloc titre séparé des
    // réponses en dessous, sans casser le thème sombre existant.
    self.rootChatView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];

    UIView *midSeparator = [[UIView alloc] init];
    midSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    midSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:midSeparator];

    // ── Réponses scrollables ──────────────────────────────────────────────
    self.repliesStore = [S7TVChatMessageStore new];
    self.repliesChatView = [[SevenTVChatCustomView alloc] initWithStore:self.repliesStore];
    self.repliesChatView.showsReplyBanners = NO;
    // Décalage + barre grise continue à gauche pour bien distinguer chaque
    // réponse de la racine épinglée au-dessus (fond distinct, voir
    // rootChatView.backgroundColor) — demande explicite.
    self.repliesChatView.usesThreadReplyIndent = YES;
    self.repliesChatView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.repliesChatView];

    // ── Bouton "répondre à ce message", sur CHAQUE message (racine incluse) ──
    self.rootChatView.showsReplyTargetButton = YES;
    self.repliesChatView.showsReplyTargetButton = YES;
    __weak typeof(self) weakSelfForTarget = self;
    void (^targetSelectedHandler)(NSString *, NSString *) = ^(NSString *messageID, NSString *username) {
        [weakSelfForTarget selectReplyTargetForMessageID:messageID username:username];
    };
    self.rootChatView.onReplyTargetSelected = targetSelectedHandler;
    self.repliesChatView.onReplyTargetSelected = targetSelectedHandler;

    // ── Barre du bas "Répondre à @X · Annuler" ──────────────────────────
    // Masquée par défaut (hauteur 0 via replyTargetBarHeightConstraint) tant
    // qu'aucune cible n'est sélectionnée — voir selectReplyTargetForMessageID:username:
    // et s7tv_cancelReplyTargetTapped.
    // Hôte vide dont seule la hauteur participe au layout du panneau. La
    // barre réelle est une instance unique, déplacée ici uniquement quand
    // la réponse provient du panneau Fil.
    UIView *replyBarHost = [[UIView alloc] init];
    replyBarHost.translatesAutoresizingMaskIntoConstraints = NO;
    replyBarHost.clipsToBounds = YES;
    [container addSubview:replyBarHost];
    self.threadReplyTargetBarHostView = replyBarHost;
    [self s7tv_attachReplyTargetBarToThreadHost];

    self.replyTargetBarHeightConstraint =
        [replyBarHost.heightAnchor constraintEqualToConstant:0];

    self.rootChatViewHeightConstraint =
        [self.rootChatView.heightAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [titleIcon.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [titleIcon.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight / 2],
        [titleIcon.widthAnchor constraintEqualToConstant:15],
        [titleIcon.heightAnchor constraintEqualToConstant:15],

        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:6],
        [title.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight / 2],

        [closeButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [closeButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [closeButton.widthAnchor constraintEqualToConstant:26],
        [closeButton.heightAnchor constraintEqualToConstant:26],

        [topSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [topSeparator.topAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight],
        [topSeparator.heightAnchor constraintEqualToConstant:kS7TVReplyThreadSeparatorHeight],

        [self.rootChatView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.rootChatView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.rootChatView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
        self.rootChatViewHeightConstraint,

        [midSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [midSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [midSeparator.topAnchor constraintEqualToAnchor:self.rootChatView.bottomAnchor],
        [midSeparator.heightAnchor constraintEqualToConstant:kS7TVReplyThreadSeparatorHeight],

        [self.repliesChatView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.repliesChatView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.repliesChatView.topAnchor constraintEqualToAnchor:midSeparator.bottomAnchor],
        [self.repliesChatView.bottomAnchor constraintEqualToAnchor:replyBarHost.topAnchor],

        [replyBarHost.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [replyBarHost.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [replyBarHost.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-kS7TVReplyThreadBottomPadding],
        self.replyTargetBarHeightConstraint,
    ]];
}

- (void)s7tv_closeTapped {
    [self hide];
}

// Reconstruit la racine même si elle a été purgée du store principal
// (chaîne à fort trafic, limite FIFO) : reply-parent-user-login/display-name
// et reply-parent-msg-body sont dupliqués par Twitch sur CHAQUE réponse du
// fil, donc toujours disponibles même sans le message d'origine en mémoire.
// Pas d'emotes/badges dans ce cas précis (on n'a que le texte brut), mais
// JAMAIS de racine manquante à l'écran — c'est le point que tu as signalé.
- (S7TVChatMessage *)s7tv_resolveRootMessageForThreadRootID:(NSString *)threadRootID
                                         anyMessageInThread:(nullable S7TVChatMessage *)anyMessage {
    S7TVChatMessageStore *mainStore = [SevenTVManager sharedManager].chatMessageStore;
    S7TVChatMessage *root = [mainStore messageWithID:threadRootID];
    if (root) return root;
    if (!anyMessage.replyParentUsername.length) return nil; // rien à reconstruire (cas quasi impossible : voir s7tv_parsePRIVMSG, replyParentUsername toujours rempli en même temps que replyThreadRootID)

    S7TVChatMessage *fallback =
        [[S7TVChatMessage alloc] initWithMessageID:threadRootID
                                          timestamp:anyMessage.timestamp
                                       authorUserID:@""
                                  authorDisplayName:anyMessage.replyParentUsername
                                            rawText:anyMessage.replyParentBodyPreview ?: @""];
    fallback.tokens = [SevenTVChatTokenizer tokenizeText:fallback.rawText providers:@[]];
    return fallback;
}

// completion : appelé une fois que rootChatView ET repliesChatView ont
// RÉELLEMENT appliqué leur contenu (pas juste "reloadMessages a été
// appelé") — les deux passent par reloadMessagesWithCompletion:, dont le
// completion ne se déclenche qu'après que le diffable data source ait fini
// d'appliquer sa snapshot (asynchrone même sans animation, voir
// 7tv-chat-custom-view.m). Mesurer le contenu (s7tvContentHeight) avant
// que ce completion soit passé lit une hauteur pas encore à jour — c'était
// la cause du clignotement à l'ouverture (panneau dimensionné sur un
// contenu vide, corrigé seulement au refresh suivant).
- (void)s7tv_reloadThreadMessagesWithCompletion:(void (^)(void))completion {
    if (!self.currentThreadRootID.length) {
        if (completion) completion();
        return;
    }
    S7TVChatMessageStore *mainStore = [SevenTVManager sharedManager].chatMessageStore;
    NSArray<S7TVChatMessage *> *threadMessages =
        [mainStore messagesForThreadRootID:self.currentThreadRootID];

    // threadMessages inclut déjà la racine EN PREMIER si elle est encore en
    // mémoire (voir -messagesForThreadRootID:) — on la retire d'ici pour la
    // traiter séparément (épinglée), et on s'en sert aussi comme source pour
    // reconstruire la racine si elle manque (n'importe quel message du fil
    // porte les mêmes reply-parent-*).
    NSMutableArray<S7TVChatMessage *> *replies = [threadMessages mutableCopy];
    S7TVChatMessage *rootFromMainStore = [mainStore messageWithID:self.currentThreadRootID];
    if (rootFromMainStore && replies.count && replies.firstObject == rootFromMainStore) {
        [replies removeObjectAtIndex:0];
    }

    S7TVChatMessage *root =
        [self s7tv_resolveRootMessageForThreadRootID:self.currentThreadRootID
                                    anyMessageInThread:replies.firstObject ?: rootFromMainStore];

    [self.rootStore seedReadOnlyWithMessages:root ? @[root] : @[]];
    [self.repliesStore seedReadOnlyWithMessages:replies];

    // Les deux reload sont indépendants (2 tables séparées) — on attend que
    // les DEUX aient fini avant d'appeler completion, sinon on mesurerait la
    // racine correctement mais les réponses pas encore, ou l'inverse.
    __block BOOL rootDone = NO;
    __block BOOL repliesDone = NO;
    void (^maybeFinish)(void) = ^{
        if (rootDone && repliesDone && completion) completion();
    };

    [self.rootChatView reloadMessagesWithCompletion:^{
        rootDone = YES;
        maybeFinish();
    }];
    [self.repliesChatView reloadMessagesWithCompletion:^{
        repliesDone = YES;
        maybeFinish();
    }];
}

// Conservé pour refreshIfNeeded (pas besoin d'attendre la complétion là où
// on ne redimensionne pas juste après — voir plus bas).
- (void)s7tv_reloadThreadMessages {
    [self s7tv_reloadThreadMessagesWithCompletion:nil];
}

// Calcule les hauteurs réelles (racine épinglée + réponses). La position du
// panneau est désormais assurée en continu par une contrainte vers la VRAIE
// barre de saisie Twitch (voir s7tv_updateContainerPositionConstraints...),
// et non plus par une frame figée calculée ici.
- (void)s7tv_layoutPanelContentInWindow:(UIWindow *)window {
    [self s7tv_updateContainerPositionConstraintsInWindow:window];
    CGFloat width = window.bounds.size.width;

    UIView *inputView = s7tv_findChatInputView();
    CGFloat inputTopY = window.bounds.size.height; // repli si la barre de saisie est introuvable (cas extrême)
    if (inputView && inputView.window == window) {
        CGRect inputFrameInWindow = [inputView convertRect:inputView.bounds toView:window];
        inputTopY = inputFrameInWindow.origin.y;
    }

    CGFloat maxTotalHeight = inputTopY * 0.25;

    // replyTargetBarHeightConstraint.constant vaut déjà 0 (masquée) ou
    // kS7TVReplyTargetBarHeight (visible) au moment où cette fonction est
    // appelée — selectReplyTargetForMessageID:/s7tv_cancelReplyTargetTapped la
    // règlent AVANT d'appeler ce recalcul.
    CGFloat replyBarHeight = self.replyTargetBarHeightConstraint.constant;

    CGFloat chromeHeight = kS7TVReplyThreadTitleHeight + kS7TVReplyThreadSeparatorHeight * 2
                          + kS7TVReplyThreadBottomPadding + replyBarHeight;
    CGFloat maxContentHeight = MAX(maxTotalHeight - chromeHeight, 60);

    // Racine : jamais coupée. On lui laisse d'abord toute la place possible
    // pour mesurer sa vraie hauteur ; si jamais elle dépassait à elle seule
    // maxContentHeight (message très long), on la borne quand même à
    // maxContentHeight plutôt que de faire disparaître les réponses, mais on
    // ne tronque JAMAIS le texte lui-même (self-sizing cell, pas de
    // troncature) — seule la fenêtre de scroll de la table racine
    // apparaîtrait dans ce cas extrême, ce qui reste conforme à "jamais de
    // texte coupé".
    self.rootChatView.frame = CGRectMake(0, 0, width, maxContentHeight);
    CGFloat rootHeight = MIN([self.rootChatView s7tvContentHeight], maxContentHeight);
    if (rootHeight <= 0) rootHeight = 0; // pas de racine du tout (cas extrême, cf. s7tv_resolveRootMessageForThreadRootID:)
    self.rootChatViewHeightConstraint.constant = rootHeight;

    CGFloat remainingForReplies = MAX(maxContentHeight - rootHeight, 44);
    self.repliesChatView.frame = CGRectMake(0, 0, width, remainingForReplies);
    CGFloat repliesContentHeight = [self.repliesChatView s7tvContentHeight];
    CGFloat repliesHeight = MIN(MAX(repliesContentHeight, 0), remainingForReplies);

    CGFloat totalHeight = chromeHeight + rootHeight + repliesHeight;
    totalHeight = MIN(MAX(totalHeight, chromeHeight + 44), maxTotalHeight);

    // La position verticale n'est plus écrite ici : bottomAnchor suit en
    // permanence inputView.topAnchor. Seule la hauteur calculée du contenu
    // change, donc l'ouverture du clavier et l'agrandissement du champ ne
    // peuvent plus désynchroniser le panneau de la chat box.
    self.containerHeightConstraint.constant = totalHeight;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
}

- (void)showForThreadRootID:(NSString *)threadRootID tappedMessageID:(NSString *)tappedMessageID {
    if (!threadRootID.length) return;
    UIView *hostChatView = s7tv_activeChatCustomView();
    UIWindow *window = hostChatView.window;
    if (!hostChatView || !window) return;

    [self s7tv_ensureContainerInWindow:window];
    [self s7tv_attachReplyTargetBarToThreadHost];
    self.titleLabel.text = L(@"chat_reply_thread_panel_title"); // relu à chaque ouverture, voir commentaire sur titleLabel
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.currentThreadRootID = threadRootID;
    self.pendingReplyTargetMessageID = tappedMessageID;

    // Aucune sélection automatique : le panneau s'ouvre en pure
    // consultation, l'utilisateur choisit explicitement une cible via le
    // bouton flèche sur le message de son choix (voir
    // selectReplyTargetForMessageID:username: plus bas) — demande explicite,
    // l'auto-insertion précédente gênait quand on ouvrait juste pour lire.
    // Si une mention d'une sélection précédente traînait encore (fil rouvert
    // sans être passé par -hide entre-temps), on la nettoie aussi.
    [self s7tv_clearReplyTargetRemovingMention];

    // Le contenu doit être RÉELLEMENT appliqué (pas juste "reload appelé")
    // avant de mesurer sa hauteur — sinon le panneau se dimensionne sur du
    // vide et se corrige seulement au refresh suivant (clignotement
    // visible à l'ouverture, corrigé ici).
    __weak typeof(self) weakSelf = self;
    [self s7tv_reloadThreadMessagesWithCompletion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.containerView.window != window) return; // fermé/changé entre-temps

        [strongSelf.containerView layoutIfNeeded]; // applique les contraintes AVANT de mesurer le contenu
        [strongSelf s7tv_layoutPanelContentInWindow:window];

        strongSelf.containerView.hidden = NO;
        [window bringSubviewToFront:strongSelf.containerView];
    }];
}

// Tap sur le bouton flèche d'UN message précis (racine ou réponse) — voir
// SevenTVChatCustomView.onReplyTargetSelected. Insertion IMMÉDIATE de la
// mention, pas de confirmation supplémentaire : si l'utilisateur tape la
// flèche, c'est qu'il veut répondre à cette personne. La barre du bas ne
// sert qu'à visualiser la sélection en cours et à l'annuler si besoin.
- (void)selectReplyTargetForMessageID:(NSString *)messageID username:(NSString *)username {
    if (!messageID.length || !username.length) return;

    // Un changement de cible passe par le même nettoyage qu'« Annuler » :
    // l'ancien préfixe exact est retiré avant d'insérer le nouveau.
    [self s7tv_clearReplyTargetRemovingMention];

    self.selectedReplyTargetMessageID = messageID;
    self.selectedReplyTargetUsername = username;
    [self s7tv_ensureReplyTargetBar];
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.replyTargetBarLabel.attributedText = s7tv_buildReplyTargetBarText(username);

    BOOL threadPanelIsVisible = self.currentThreadRootID.length > 0 &&
        self.containerView.window && !self.containerView.hidden;
    if (threadPanelIsVisible) {
        [self s7tv_attachReplyTargetBarToThreadHost];
        self.replyTargetBarHeightConstraint.constant = kS7TVReplyTargetBarHeight;
        self.replyTargetBarView.hidden = NO;
    } else {
        self.replyTargetBarHeightConstraint.constant = 0;
        SevenTVChatCustomView *chatView = s7tv_activeChatCustomView();
        UIWindow *window = chatView.window;
        [self s7tv_showStandaloneReplyTargetBarInWindow:window];
    }

    self.lastInsertedMentionText = s7tv_insertMentionAtStartOfChatInput(username);

    if (threadPanelIsVisible) {
        [self s7tv_layoutPanelContentInWindow:self.containerView.window];
    }
}

- (void)s7tv_clearReplyTargetRemovingMention {
    self.selectedReplyTargetMessageID = nil;
    self.selectedReplyTargetUsername = nil;
    self.replyTargetBarView.hidden = YES;
    self.replyTargetBarHeightConstraint.constant = 0;

    if (self.lastInsertedMentionText.length) {
        s7tv_removeExactPrefixFromChatInput(self.lastInsertedMentionText);
        self.lastInsertedMentionText = nil;
    }

    // Hors panneau Fil, la barre est directement dans UIWindow : on la
    // retire totalement pour qu'une vue masquée n'intercepte jamais les taps.
    if (self.replyTargetBarView.superview != self.threadReplyTargetBarHostView) {
        [NSLayoutConstraint deactivateConstraints:self.standaloneReplyBarConstraints ?: @[]];
        self.standaloneReplyBarConstraints = nil;
        [self.replyTargetBarView removeFromSuperview];
    }
}

- (void)s7tv_cancelReplyTargetTapped {
    UIWindow *window = self.containerView.window;
    BOOL shouldRelayoutThread = self.currentThreadRootID.length > 0 &&
        window && !self.containerView.hidden;
    [self s7tv_clearReplyTargetRemovingMention];
    if (shouldRelayoutThread) [self s7tv_layoutPanelContentInWindow:window];
}

- (void)hide {
    self.containerView.hidden = YES;
    self.currentThreadRootID = nil;
    self.pendingReplyTargetMessageID = nil;
    // Fermer le panneau retire aussi la mention en cours — demande
    // explicite : contrairement à la version précédente, fermer sans
    // "Annuler" doit quand même nettoyer le texte, pas le laisser en place.
    [self s7tv_clearReplyTargetRemovingMention];
}

- (void)refreshIfNeeded {
    if (!self.currentThreadRootID.length || self.containerView.hidden) return;
    UIWindow *window = self.containerView.window;
    __weak typeof(self) weakSelf = self;
    [self s7tv_reloadThreadMessagesWithCompletion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !window || strongSelf.containerView.hidden) return;
        [strongSelf s7tv_layoutPanelContentInWindow:window];
    }];
}

@end
