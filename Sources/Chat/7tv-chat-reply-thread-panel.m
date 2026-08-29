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
#import "Chat/7tv-chat-appearance-config.h"
#import "Chat/7tv-chat-message.h"
#import "Core/7tv-core-manager.h"
#import "Localization/7tv-localization-manager.h"
#import "Chat/7tv-chat-tokenizer.h"
#import "UI/7tv-oled-mode.h"

// Les overlays Fil/Réponse ne passent pas par la palette native. Ils restent
// volontairement un cran au-dessus du noir OLED afin de conserver leur rôle
// de contexte visuel, contrairement à la preview d'emote qui peut être noire.
static UIColor *s7tv_replyContextSurfaceColor(void) {
    return S7TVOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.04 alpha:1.0]
        : [UIColor colorWithWhite:0.08 alpha:1.0];
}

static UIColor *s7tv_contextMessageBackgroundColor(void) {
    return [UIColor colorWithWhite:1.0
                             alpha:S7TVOLEDModeEnabled() ? 0.025 : 0.04];
}

static UIColor *s7tv_replyContextBorderColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.14];
}

static CGFloat s7tv_replyContextBorderWidth(void) {
    return 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
}

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
// moment-là). Ici on fait un appui long dans le panneau Fil : le clavier est
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
// La ligne d'action reste compacte dans un thread. Dans le chat principal,
// la hauteur intrinsèque du message complet est ajoutée dynamiquement.
static const CGFloat kS7TVReplyTargetActionRowHeight = 30.0;

// Les overlays de réponse vivent dans UIWindow pour rester au-dessus du
// transcript, mais leur largeur doit suivre la colonne de chat Twitch. La
// vraie ChatInputView est la meilleure ancre : elle suit déjà les rotations,
// le mode paysage et les changements de disposition de Twitch. Le transcript
// custom sert de repli, puis seulement la fenêtre si les deux sont absents.
static UIView *s7tv_replyOverlayHorizontalAnchorView(UIWindow *window,
                                                      UIView *inputView) {
    if (inputView && inputView.window == window) return inputView;
    SevenTVChatCustomView *chatView = s7tv_activeChatCustomView();
    if (chatView && chatView.window == window) return chatView;
    return window;
}

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

static NSArray<NSString *> *s7tv_messageIDs(NSArray<S7TVChatMessage *> *messages) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:messages.count];
    for (S7TVChatMessage *message in messages) {
        if (message.messageID.length) [identifiers addObject:message.messageID];
    }
    return identifiers;
}

static BOOL s7tv_sameMessageInstances(NSArray<S7TVChatMessage *> *left,
                                      NSArray<S7TVChatMessage *> *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger index = 0; index < left.count; index++) {
        if (left[index] != right[index]) return NO;
    }
    return YES;
}

@interface S7TVReplyThreadPanel ()
@property (nonatomic, weak) UIView *containerView;
// Contraintes externes du panneau complet. Comme pour la barre autonome,
// son bas est relié directement au haut de la vraie saisie Twitch : aucun
// recalcul ponctuel de frame quand le clavier ou la hauteur du champ change.
@property (nonatomic, strong) NSLayoutConstraint *containerHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *containerPositionConstraints;
@property (nonatomic, weak) UIView *containerInputAnchorView;
@property (nonatomic, weak) UIView *containerHorizontalAnchorView;
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
// Identifie le dernier contexte réellement demandé. Chaque show/hide/refresh
// invalide les completions plus anciennes afin qu'un fil A ne puisse jamais
// redimensionner ou réafficher le panneau après le passage au fil B.
@property (nonatomic, assign) NSUInteger contentRequestGeneration;
@property (nonatomic, copy) NSString *loadedThreadRootID;
@property (nonatomic, copy) NSString *lastRequestedRootMessageID;
@property (nonatomic, copy) NSArray<NSString *> *lastRequestedReplyMessageIDs;
@property (nonatomic, strong) S7TVChatMessage *lastRequestedRootMessage;
@property (nonatomic, copy) NSArray<S7TVChatMessage *> *lastRequestedReplyMessages;
// Le conteneur reste volontairement caché pendant son premier snapshot. Si
// une modération, une image ou une réponse arrive dans cette fenêtre, on fait
// un unique passage de rattrapage avant l'affichage au lieu de perdre le refresh.
@property (nonatomic, assign) BOOL contentRefreshPendingWhileOpening;
// Tous les modèles du fil encore visibles au moment du tap restent
// disponibles, même s'ils ont déjà quitté le FIFO principal.
@property (nonatomic, copy) NSArray<S7TVChatMessage *> *openingTranscriptMessages;
// Le message sur lequel l'utilisateur a tapé pour OUVRIR ce fil — gardé en
// mémoire mais N'EST PLUS auto-sélectionné comme cible (voir demande :
// aucune sélection automatique à l'ouverture, l'utilisateur choisit
// explicitement par appui long sur le message de son choix).
@property (nonatomic, copy) NSString *pendingReplyTargetMessageID;
// Message du chat principal depuis lequel le Fil a été ouvert. Son voile
// reste visible tant que ce Fil est présenté, indépendamment d'une éventuelle
// cible de réponse choisie à l'intérieur du panneau.
@property (nonatomic, weak) SevenTVChatCustomView *threadSourceView;
@property (nonatomic, copy) NSString *threadSourceMessageID;

// ── Sélection de cible de réponse (appui long sur un message) ───────
// Non-nil uniquement quand l'utilisateur a explicitement maintenu un message
// — voir selectReplyTargetForMessageID:username:. C'est LÀ
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
// Même renderer que le message racine d'un fil : une vue de chat dédiée,
// alimentée avec l'instance exacte du message (badges/emotes compris).
@property (nonatomic, strong) S7TVChatMessageStore *replyTargetMessageStore;
@property (nonatomic, strong) SevenTVChatCustomView *replyTargetMessageView;
@property (nonatomic, strong) NSLayoutConstraint *replyTargetMessageViewHeightConstraint;
@property (nonatomic, weak) UILabel *replyTargetBarLabel;
@property (nonatomic, weak) UIView *threadReplyTargetBarHostView;
@property (nonatomic, strong) NSLayoutConstraint *replyTargetBarHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *standaloneReplyBarHeightConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *standaloneReplyBarConstraints;
@property (nonatomic, weak) SevenTVChatCustomView *replyTargetSourceView;
@property (nonatomic, assign) BOOL panelLayoutInProgress;
@property (nonatomic, assign) BOOL panelRelayoutPending;
@property (nonatomic, assign) BOOL standaloneResizeInProgress;
@property (nonatomic, assign) BOOL standaloneResizePending;
@property (nonatomic, assign) BOOL contentLayoutScheduled;
- (void)s7tv_clearReplyTargetRemovingMention;
- (void)s7tv_clearThreadSourceHighlight;
- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID
     retainedThreadMessages:(NSArray<S7TVChatMessage *> *)retainedThreadMessages
                  sourceView:(SevenTVChatCustomView *)sourceView;
- (void)s7tv_finishOpeningThreadRootID:(NSString *)threadRootID
                                window:(UIWindow *)window
                      allowsCatchUpPass:(BOOL)allowsCatchUpPass;
- (void)s7tv_layoutPanelContentInWindow:(UIWindow *)window;
- (void)s7tv_resizeStandaloneReplyTargetBarInWindow:(UIWindow *)window;
- (void)s7tv_contentHeightChangedForView:(SevenTVChatCustomView *)view;
- (void)s7tv_scheduleContentLayoutForView:(SevenTVChatCustomView *)view;
- (void)s7tv_applyOLEDColors;
@end

@implementation S7TVReplyThreadPanel

+ (instancetype)sharedPanel {
    static S7TVReplyThreadPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [S7TVReplyThreadPanel new]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(s7tv_handleDeviceOrientationChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(s7tv_oledModeDidChange:)
                   name:S7TVOLEDModeDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:UIDeviceOrientationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:S7TVOLEDModeDidChangeNotification object:nil];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)s7tv_oledModeDidChange:(__unused NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self s7tv_applyOLEDColors];
    });
}

- (void)s7tv_applyOLEDColors {
    self.containerView.backgroundColor = s7tv_replyContextSurfaceColor();
    self.containerView.layer.borderWidth = s7tv_replyContextBorderWidth();
    self.containerView.layer.borderColor = s7tv_replyContextBorderColor().CGColor;
    self.rootChatView.backgroundColor = s7tv_contextMessageBackgroundColor();
    self.replyTargetMessageView.backgroundColor = s7tv_contextMessageBackgroundColor();
    if (self.replyTargetBarView.superview == self.threadReplyTargetBarHostView) {
        self.replyTargetBarView.backgroundColor = UIColor.clearColor;
        self.replyTargetBarView.layer.borderWidth = 0;
        self.replyTargetBarView.layer.borderColor = UIColor.clearColor.CGColor;
    } else {
        self.replyTargetBarView.backgroundColor = s7tv_replyContextSurfaceColor();
        self.replyTargetBarView.layer.borderWidth = s7tv_replyContextBorderWidth();
        self.replyTargetBarView.layer.borderColor = s7tv_replyContextBorderColor().CGColor;
    }
    [self.replyTargetSourceView
        setReplyTargetHighlightedMessageID:self.selectedReplyTargetMessageID];
    [self.threadSourceView
        setReplyTargetHighlightedMessageID:self.threadSourceMessageID];
}

- (void)s7tv_handleDeviceOrientationChange:(__unused NSNotification *)note {
    BOOL threadIsVisible = self.containerView.window &&
        !self.containerView.hidden && self.currentThreadRootID.length > 0;
    BOOL standaloneReplyIsVisible = self.replyTargetBarView.window &&
        self.replyTargetBarView.superview == self.replyTargetBarView.window &&
        !self.replyTargetBarView.hidden && !self.replyTargetMessageView.hidden;
    UIWindow *window = threadIsVisible
        ? self.containerView.window : self.replyTargetBarView.window;
    if (!window || (!threadIsVisible && !standaloneReplyIsVisible)) return;

    // Twitch termine le redimensionnement de sa colonne après la notification
    // physique. Recalculer une fois l'animation stabilisée garantit aussi que
    // les cellules self-sizing utilisent la nouvelle largeur du thread.
    NSUInteger requestToken = self.contentRequestGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || requestToken != strongSelf.contentRequestGeneration) return;
        if (threadIsVisible) {
            if (strongSelf.containerView.hidden || strongSelf.containerView.window != window) return;
            [strongSelf s7tv_layoutPanelContentInWindow:window];
        } else {
            [strongSelf s7tv_resizeStandaloneReplyTargetBarInWindow:window];
        }
    });
}

- (void)chatCustomView:(SevenTVChatCustomView *)view
    didTapReplyBannerForThreadRootID:(NSString *)threadRootID
                       tappedMessageID:(NSString *)tappedMessageID {
    [self showForThreadRootID:threadRootID
              tappedMessageID:tappedMessageID
       retainedThreadMessages:[view displayedMessagesForThreadRootID:threadRootID]
                    sourceView:view];
}

- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID {
    NSArray<S7TVChatMessage *> *messages = [[SevenTVManager sharedManager].chatMessageStore
        messagesForThreadRootID:threadRootID];
    [self showForThreadRootID:threadRootID
              tappedMessageID:tappedMessageID
       retainedThreadMessages:messages ?: @[]
                    sourceView:s7tv_activeChatCustomView()];
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

    self.replyTargetMessageStore = [S7TVChatMessageStore new];
    self.replyTargetMessageView = [[SevenTVChatCustomView alloc]
        initWithStore:self.replyTargetMessageStore];
    self.replyTargetMessageView.showsReplyBanners = NO;
    self.replyTargetMessageView.freezesTranscriptWhenScrolled = NO;
    self.replyTargetMessageView.automaticallyScrollsToBottom = NO;
    [self.replyTargetMessageView setScrollingEnabled:NO];
    self.replyTargetMessageView.userInteractionEnabled = NO;
    self.replyTargetMessageView.backgroundColor = s7tv_contextMessageBackgroundColor();
    self.replyTargetMessageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.replyTargetMessageView.hidden = YES;
    self.replyTargetMessageView.renderingSuspended = YES;
    __weak typeof(self) weakSelfForPreviewHeight = self;
    self.replyTargetMessageView.onContentHeightChanged =
        ^(SevenTVChatCustomView *view) {
        [weakSelfForPreviewHeight s7tv_contentHeightChangedForView:view];
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
    [cancelButton addTarget:self action:@selector(s7tv_cancelReplyTargetTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [replyBar addSubview:cancelButton];
    self.cancelButton = cancelButton;

    [NSLayoutConstraint activateConstraints:@[
        [separator.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:replyBar.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:replyBar.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:kS7TVReplyThreadSeparatorHeight],

        [self.replyTargetMessageView.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor],
        [self.replyTargetMessageView.trailingAnchor constraintEqualToAnchor:replyBar.trailingAnchor],
        [self.replyTargetMessageView.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        self.replyTargetMessageViewHeightConstraint,

        [label.leadingAnchor constraintEqualToAnchor:replyBar.leadingAnchor constant:12],
        [label.topAnchor constraintEqualToAnchor:self.replyTargetMessageView.bottomAnchor constant:2],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:replyBar.bottomAnchor constant:-4],

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
    self.replyTargetBarView.layer.borderWidth = 0;
    self.replyTargetBarView.layer.borderColor = UIColor.clearColor.CGColor;
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
    self.replyTargetBarView.backgroundColor = s7tv_replyContextSurfaceColor();
    self.replyTargetBarView.layer.cornerRadius = 10;
    self.replyTargetBarView.layer.borderWidth = s7tv_replyContextBorderWidth();
    self.replyTargetBarView.layer.borderColor = s7tv_replyContextBorderColor().CGColor;
    self.replyTargetBarView.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

    [window addSubview:self.replyTargetBarView];
    UIView *inputView = s7tv_findChatInputView();
    if (inputView.window != window) inputView = nil;
    UIView *horizontalAnchorView =
        s7tv_replyOverlayHorizontalAnchorView(window, inputView);
    NSLayoutYAxisAnchor *bottomAnchor = inputView
        ? inputView.topAnchor
        : window.safeAreaLayoutGuide.bottomAnchor;
    self.standaloneReplyBarHeightConstraint =
        [self.replyTargetBarView.heightAnchor constraintEqualToConstant:
            kS7TVReplyTargetActionRowHeight + self.replyTargetMessageViewHeightConstraint.constant];
    self.standaloneReplyBarConstraints = @[
        [self.replyTargetBarView.leadingAnchor
            constraintEqualToAnchor:horizontalAnchorView.leadingAnchor],
        [self.replyTargetBarView.trailingAnchor
            constraintEqualToAnchor:horizontalAnchorView.trailingAnchor],
        [self.replyTargetBarView.bottomAnchor constraintEqualToAnchor:bottomAnchor],
        self.standaloneReplyBarHeightConstraint,
    ];
    [NSLayoutConstraint activateConstraints:self.standaloneReplyBarConstraints];
    // La barre reste masquée jusqu'à ce que le snapshot soit appliqué et que
    // la cellule ait été mesurée à la largeur finale. Cela évite d'exposer
    // une hauteur intermédiaire (0 pt) lors de la toute première réponse.
    self.replyTargetBarView.hidden = YES;
    [window bringSubviewToFront:self.replyTargetBarView];
}

- (void)s7tv_resizeStandaloneReplyTargetBarInWindow:(UIWindow *)window {
    if (!window || self.replyTargetBarView.window != window ||
        self.replyTargetBarView.hidden || self.replyTargetMessageView.hidden) return;

    if (self.standaloneResizeInProgress) {
        self.standaloneResizePending = YES;
        return;
    }

    self.standaloneResizeInProgress = YES;
    BOOL wasHidden = self.replyTargetBarView.hidden;
    // La barre est déjà attachée : elle reste invisible pendant la transaction
    // de mesure, évitant d'exposer une hauteur estimée entre deux layouts.
    self.replyTargetBarView.hidden = YES;

    [window layoutIfNeeded];
    UIView *inputView = s7tv_findChatInputView();
    CGFloat availableHeight = CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom;
    if (inputView.window == window) {
        CGRect inputFrame = [inputView convertRect:inputView.bounds toView:window];
        availableHeight = CGRectGetMinY(inputFrame);
    }
    availableHeight = MAX(44.0, availableHeight);

    // Donner une vraie fenêtre de layout au UITableView permet à UIKit de
    // créer et self-dimensionner la cellule avant de lire contentSize. Il ne
    // s'agit pas d'un délai : toute la mesure reste dans la même transaction
    // Auto Layout, puis la contrainte reçoit la hauteur intrinsèque réelle.
    self.replyTargetMessageViewHeightConstraint.constant = availableHeight;
    self.standaloneReplyBarHeightConstraint.constant =
        kS7TVReplyTargetActionRowHeight + availableHeight;
    [window layoutIfNeeded];
    CGFloat messageHeight = ceil(MAX([self.replyTargetMessageView s7tvContentHeight], 0));
    self.replyTargetMessageViewHeightConstraint.constant = messageHeight;
    self.standaloneReplyBarHeightConstraint.constant =
        kS7TVReplyTargetActionRowHeight + messageHeight;
    [window layoutIfNeeded];

    self.replyTargetBarView.hidden = wasHidden;
    self.standaloneResizeInProgress = NO;
    if (self.standaloneResizePending) {
        self.standaloneResizePending = NO;
        [self s7tv_scheduleContentLayoutForView:self.replyTargetMessageView];
    }
}

- (void)s7tv_updateContainerPositionConstraintsInWindow:(UIWindow *)window {
    UIView *container = self.containerView;
    if (!container || !window) return;

    UIView *inputView = s7tv_findChatInputView();
    if (inputView.window != window) inputView = nil;
    UIView *horizontalAnchorView =
        s7tv_replyOverlayHorizontalAnchorView(window, inputView);
    if (self.containerPositionConstraints.count > 0 &&
        self.containerInputAnchorView == inputView &&
        self.containerHorizontalAnchorView == horizontalAnchorView) return;

    [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
    self.containerInputAnchorView = inputView;
    self.containerHorizontalAnchorView = horizontalAnchorView;
    NSLayoutYAxisAnchor *bottomAnchor = inputView
        ? inputView.topAnchor
        : window.safeAreaLayoutGuide.bottomAnchor;
    self.containerPositionConstraints = @[
        [container.leadingAnchor constraintEqualToAnchor:horizontalAnchorView.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:horizontalAnchorView.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.containerPositionConstraints];
}

- (void)s7tv_contentHeightChangedForView:(SevenTVChatCustomView *)view {
    if (!view) return;

    BOOL isThreadView = (view == self.rootChatView || view == self.repliesChatView);
    BOOL isStandalonePreview = (view == self.replyTargetMessageView);
    BOOL threadVisible = isThreadView && self.containerView.window &&
        !self.containerView.hidden && self.currentThreadRootID.length > 0;
    BOOL standaloneVisible = isStandalonePreview && self.replyTargetBarView.window &&
        self.replyTargetBarView.superview == self.replyTargetBarView.window &&
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
    [self s7tv_scheduleContentLayoutForView:view];
}

- (void)s7tv_scheduleContentLayoutForView:(SevenTVChatCustomView *)view {
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
            [strongSelf s7tv_layoutPanelContentInWindow:strongSelf.containerView.window];
        } else if (view == strongSelf.replyTargetMessageView &&
                   strongSelf.replyTargetBarView.window &&
                   strongSelf.replyTargetBarView.superview == strongSelf.replyTargetBarView.window &&
                   !strongSelf.replyTargetBarView.hidden &&
                   !strongSelf.replyTargetMessageView.hidden) {
            [strongSelf s7tv_resizeStandaloneReplyTargetBarInWindow:
                strongSelf.replyTargetBarView.window];
        }
    });
}

- (void)s7tv_ensureContainerInWindow:(UIWindow *)window {
    if (self.containerView.window == window) {
        [self s7tv_applyOLEDColors];
        [self s7tv_updateContainerPositionConstraintsInWindow:window];
        return;
    }
    [NSLayoutConstraint deactivateConstraints:self.containerPositionConstraints ?: @[]];
    self.containerPositionConstraints = nil;
    self.containerHeightConstraint = nil;
    self.containerInputAnchorView = nil;
    self.containerHorizontalAnchorView = nil;
    [self.containerView removeFromSuperview];

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = s7tv_replyContextSurfaceColor(); // opaque (pas 0.97) : évite tout effet de transparence qui laissait deviner le chat derrière
    container.layer.cornerRadius = 14;
    container.layer.borderWidth = s7tv_replyContextBorderWidth();
    container.layer.borderColor = s7tv_replyContextBorderColor().CGColor;
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
    self.rootChatView.freezesTranscriptWhenScrolled = NO;
    self.rootChatView.automaticallyScrollsToBottom = NO;
    [self.rootChatView setScrollingEnabled:NO];
    self.rootChatView.renderingSuspended = YES;
    self.rootChatView.translatesAutoresizingMaskIntoConstraints = NO;
    // Les gestes restent actifs malgré le scroll désactivé : l'appui long
    // part donc dans le même pipeline de réponse que le chat principal.
    [container addSubview:self.rootChatView];

    // Léger fond distinct pour lire "racine" comme un bloc titre séparé des
    // réponses en dessous, sans casser le thème sombre existant.
    self.rootChatView.backgroundColor = s7tv_contextMessageBackgroundColor();

    UIView *midSeparator = [[UIView alloc] init];
    midSeparator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    midSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:midSeparator];

    // ── Réponses scrollables ──────────────────────────────────────────────
    self.repliesStore = [S7TVChatMessageStore new];
    self.repliesChatView = [[SevenTVChatCustomView alloc] initWithStore:self.repliesStore];
    self.repliesChatView.showsReplyBanners = NO;
    self.repliesChatView.freezesTranscriptWhenScrolled = NO;
    self.repliesChatView.renderingSuspended = YES;
    // Décalage + barre grise continue à gauche pour bien distinguer chaque
    // réponse de la racine épinglée au-dessus (fond distinct, voir
    // rootChatView.backgroundColor) — demande explicite.
    self.repliesChatView.usesThreadReplyIndent = YES;
    self.repliesChatView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelfForThreadHeight = self;
    self.rootChatView.onContentHeightChanged =
        ^(SevenTVChatCustomView *view) {
        [weakSelfForThreadHeight s7tv_contentHeightChangedForView:view];
    };
    self.repliesChatView.onContentHeightChanged =
        ^(SevenTVChatCustomView *view) {
        [weakSelfForThreadHeight s7tv_contentHeightChangedForView:view];
    };
    [container addSubview:self.repliesChatView];

    // Une seule interaction de réponse partout : l'appui long déjà géré
    // par SevenTVChatCustomView. Aucune flèche parallèle n'est ajoutée.
    __weak typeof(self) weakSelfForTarget = self;
    __weak SevenTVChatCustomView *weakRootChatView = self.rootChatView;
    self.rootChatView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        SevenTVChatCustomView *sourceView = weakRootChatView;
        if (!sourceView) return;
        [weakSelfForTarget selectReplyTargetForMessageID:messageID
                                                username:username
                                              sourceView:sourceView];
    };
    __weak SevenTVChatCustomView *weakRepliesChatView = self.repliesChatView;
    self.repliesChatView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        SevenTVChatCustomView *sourceView = weakRepliesChatView;
        if (!sourceView) return;
        [weakSelfForTarget selectReplyTargetForMessageID:messageID
                                                username:username
                                              sourceView:sourceView];
    };

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
        [closeButton.leadingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:4],
        [closeButton.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight / 2],
        [closeButton.widthAnchor constraintEqualToConstant:26],
        [closeButton.heightAnchor constraintEqualToConstant:26],

        [titleIcon.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:2],
        [titleIcon.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight / 2],
        [titleIcon.widthAnchor constraintEqualToConstant:15],
        [titleIcon.heightAnchor constraintEqualToConstant:15],

        [title.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:6],
        [title.centerYAnchor constraintEqualToAnchor:container.topAnchor constant:kS7TVReplyThreadTitleHeight / 2],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-12],

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

// Retourne YES uniquement lorsqu'un vrai reload a été lancé. Les refreshs
// ordinaires du chat passent force=NO : un message sans rapport avec ce fil
// ne redémarre donc plus ses cellules, images et animations toutes les 150 ms.
- (BOOL)s7tv_reloadThreadMessagesForce:(BOOL)force
                            completion:(void (^)(void))completion {
    NSString *threadRootID = [self.currentThreadRootID copy];
    if (!threadRootID.length) return NO;

    S7TVChatMessageStore *mainStore = [SevenTVManager sharedManager].chatMessageStore;
    NSArray<S7TVChatMessage *> *threadMessages = [mainStore messagesForThreadRootID:threadRootID];
    S7TVChatMessage *rootFromMainStore = [mainStore messageWithID:threadRootID];
    NSMutableArray<S7TVChatMessage *> *newReplies = [NSMutableArray array];
    for (S7TVChatMessage *message in threadMessages) {
        if ([message.messageID isEqualToString:threadRootID]) {
            if (!rootFromMainStore) rootFromMainStore = message;
        } else if (message.messageID.length) {
            [newReplies addObject:message];
        }
    }

    for (S7TVChatMessage *openingMessage in self.openingTranscriptMessages) {
        if ([openingMessage.messageID isEqualToString:threadRootID]) {
            if (!rootFromMainStore) rootFromMainStore = openingMessage;
        } else if ([openingMessage.replyThreadRootID isEqualToString:threadRootID] &&
                   openingMessage.messageID.length) {
            BOOL alreadyPresent = NO;
            for (S7TVChatMessage *message in newReplies) {
                if ([message.messageID isEqualToString:openingMessage.messageID]) {
                    alreadyPresent = YES;
                    break;
                }
            }
            if (!alreadyPresent) [newReplies addObject:openingMessage];
        }
    }
    [newReplies sortUsingComparator:^NSComparisonResult(S7TVChatMessage *left,
                                                         S7TVChatMessage *right) {
        NSComparisonResult dateOrder = [left.timestamp compare:right.timestamp];
        if (dateOrder != NSOrderedSame) return dateOrder;
        return [left.messageID compare:right.messageID];
    }];

    BOOL preservesOpenContext = [self.loadedThreadRootID isEqualToString:threadRootID];
    S7TVChatMessage *existingRoot = preservesOpenContext ? self.rootStore.allMessages.firstObject : nil;
    NSArray<S7TVChatMessage *> *existingReplies = preservesOpenContext
        ? self.repliesStore.allMessages : @[];

    // Tant que le panneau reste ouvert, ses objets déjà visibles survivent à
    // la purge FIFO du chat principal. On ajoute les nouvelles réponses sans
    // retirer celles que l'utilisateur est précisément en train de lire.
    NSMutableDictionary<NSString *, S7TVChatMessage *> *currentRepliesByID =
        [NSMutableDictionary dictionaryWithCapacity:newReplies.count];
    for (S7TVChatMessage *message in newReplies) {
        if (message.messageID.length) currentRepliesByID[message.messageID] = message;
    }
    NSMutableArray<S7TVChatMessage *> *replies =
        [NSMutableArray arrayWithCapacity:existingReplies.count + newReplies.count];
    NSMutableSet<NSString *> *knownReplyIDs = [NSMutableSet set];
    for (S7TVChatMessage *existingMessage in existingReplies) {
        NSString *messageID = existingMessage.messageID;
        if (!messageID.length || [knownReplyIDs containsObject:messageID]) continue;
        // Le store principal peut reconstruire son contenu avec de nouvelles
        // instances portant les mêmes IDs. Préférer alors l'objet courant ;
        // conserver l'ancien uniquement s'il a réellement été purgé du FIFO.
        [replies addObject:currentRepliesByID[messageID] ?: existingMessage];
        [knownReplyIDs addObject:messageID];
    }
    for (S7TVChatMessage *message in newReplies) {
        if (![knownReplyIDs containsObject:message.messageID]) {
            [replies addObject:message];
            [knownReplyIDs addObject:message.messageID];
        }
    }
    [replies sortUsingComparator:^NSComparisonResult(S7TVChatMessage *left,
                                                      S7TVChatMessage *right) {
        NSComparisonResult dateOrder = [left.timestamp compare:right.timestamp];
        if (dateOrder != NSOrderedSame) return dateOrder;
        return [left.messageID compare:right.messageID];
    }];

    S7TVChatMessage *root = rootFromMainStore ?: existingRoot;
    if (!root) {
        S7TVChatMessage *rootMetadataCarrier = nil;
        for (S7TVChatMessage *message in replies) {
            if ([message.replyParentMessageID isEqualToString:threadRootID]) {
                rootMetadataCarrier = message;
                break;
            }
        }
        root = [self s7tv_resolveRootMessageForThreadRootID:threadRootID
                                        anyMessageInThread:rootMetadataCarrier ?: replies.firstObject];
    }
    NSString *rootMessageID = root.messageID ?: @"";
    NSArray<NSString *> *replyMessageIDs = s7tv_messageIDs(replies);
    BOOL contextChanged = ![self.loadedThreadRootID isEqualToString:threadRootID];
    BOOL rootChanged = force || contextChanged ||
        ![self.lastRequestedRootMessageID isEqualToString:rootMessageID] ||
        self.lastRequestedRootMessage != root;
    BOOL repliesChanged = force || contextChanged ||
        ![self.lastRequestedReplyMessageIDs isEqualToArray:replyMessageIDs] ||
        !s7tv_sameMessageInstances(self.lastRequestedReplyMessages ?: @[], replies);
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

// Calcule les hauteurs réelles (racine épinglée + réponses). La position du
// panneau est désormais assurée en continu par une contrainte vers la VRAIE
// barre de saisie Twitch (voir s7tv_updateContainerPositionConstraints...),
// et non plus par une frame figée calculée ici.
- (void)s7tv_layoutPanelContentInWindow:(UIWindow *)window {
    if (!window || !self.containerView || !self.rootChatView || !self.repliesChatView) return;
    if (self.panelLayoutInProgress) {
        self.panelRelayoutPending = YES;
        return;
    }
    self.panelLayoutInProgress = YES;
    [self s7tv_updateContainerPositionConstraintsInWindow:window];
    // Force la résolution des nouvelles ancres avant de mesurer les cellules :
    // leur hauteur self-sizing dépend directement de la largeur du panneau.
    [window layoutIfNeeded];

    UIView *inputView = s7tv_findChatInputView();
    CGFloat inputTopY = window.bounds.size.height; // repli si la barre de saisie est introuvable (cas extrême)
    if (inputView && inputView.window == window) {
        CGRect inputFrameInWindow = [inputView convertRect:inputView.bounds toView:window];
        inputTopY = inputFrameInWindow.origin.y;
    }

    // replyTargetBarHeightConstraint.constant vaut déjà 0 (masquée) ou
    // kS7TVReplyTargetActionRowHeight (visible) au moment où cette fonction est
    // appelée — selectReplyTargetForMessageID:/s7tv_cancelReplyTargetTapped la
    // règlent AVANT d'appeler ce recalcul.
    CGFloat replyBarHeight = self.replyTargetBarHeightConstraint.constant;

    CGFloat chromeHeight = kS7TVReplyThreadTitleHeight + kS7TVReplyThreadSeparatorHeight * 2
                          + kS7TVReplyThreadBottomPadding + replyBarHeight;
    CGFloat availableContentHeight = MAX(inputTopY - chromeHeight, 0);

    // Budget déterministe : cinq lignes rendues en portrait, trois en
    // paysage. Une "ligne" suit la police et l'espacement réels du chat,
    // jamais un pourcentage arbitraire de l'écran.
    BOOL isLandscape = window.bounds.size.width > window.bounds.size.height;
    NSUInteger visibleLineCount = isLandscape ? 3 : 5;
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    CGFloat glyphLineHeight = [UIFont systemFontOfSize:cfg.messageFontSize].lineHeight;
    CGFloat renderedLineHeight = ceil(glyphLineHeight + MAX(cfg.lineSpacing, 0) + 8.0);
    CGFloat lineBudgetHeight = renderedLineHeight * visibleLineCount;

    // Première phase : donner à la racine une vraie largeur et toute la
    // hauteur disponible. Auto Layout peut ainsi créer sa cellule et calculer
    // sa hauteur intrinsèque, même lors de la toute première ouverture.
    self.containerHeightConstraint.constant = chromeHeight + availableContentHeight;
    self.rootChatViewHeightConstraint.constant = availableContentHeight;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    CGFloat rootContentHeight = MAX([self.rootChatView s7tvContentHeight], 0);

    // Deuxième phase : libérer la zone de la racine pour que la table des
    // réponses obtienne à son tour sa largeur/viewport final et ses hauteurs
    // self-sizing réelles. Les deux mesures sont donc faites avec les
    // contraintes finales, jamais avec un frame manuel ou une estimation.
    self.rootChatViewHeightConstraint.constant = 0;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    CGFloat repliesContentHeight = [self.repliesChatView s7tvContentHeight];
    repliesContentHeight = MAX(repliesContentHeight, 0);

    CGFloat allContentHeight = rootContentHeight + repliesContentHeight;
    CGFloat desiredContentHeight = MIN(allContentHeight, lineBudgetHeight);
    // Un message racine multiligne reste toujours entier. S'il consomme à
    // lui seul le budget 5/3 lignes, on conserve aussi une ligne de réponses
    // lorsqu'il en existe, puis on ne borne que par l'espace physique réel.
    desiredContentHeight = MAX(desiredContentHeight, rootContentHeight);
    if (rootContentHeight > 0 && repliesContentHeight > 0) {
        desiredContentHeight = MAX(desiredContentHeight,
            rootContentHeight + MIN(repliesContentHeight, renderedLineHeight));
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

    // La position verticale n'est plus écrite ici : bottomAnchor suit en
    // permanence inputView.topAnchor. Seule la hauteur calculée du contenu
    // change, donc l'ouverture du clavier et l'agrandissement du champ ne
    // peuvent plus désynchroniser le panneau de la chat box.
    self.containerHeightConstraint.constant = totalHeight;
    [self.containerView setNeedsLayout];
    [self.containerView layoutIfNeeded];
    self.panelLayoutInProgress = NO;
    if (self.panelRelayoutPending) {
        self.panelRelayoutPending = NO;
        [self s7tv_scheduleContentLayoutForView:self.rootChatView];
    }
}

- (void)s7tv_finishOpeningThreadRootID:(NSString *)threadRootID
                                window:(UIWindow *)window
                      allowsCatchUpPass:(BOOL)allowsCatchUpPass {
    if (!window || self.containerView.window != window ||
        ![self.currentThreadRootID isEqualToString:threadRootID]) return;

    if (allowsCatchUpPass && self.contentRefreshPendingWhileOpening) {
        self.contentRefreshPendingWhileOpening = NO;
        __weak typeof(self) weakSelf = self;
        BOOL started = [self s7tv_reloadThreadMessagesForce:YES completion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf s7tv_finishOpeningThreadRootID:threadRootID
                                                window:window
                                      allowsCatchUpPass:NO];
        }];
        if (started) return;
    }

    [self.containerView layoutIfNeeded];
    [self s7tv_layoutPanelContentInWindow:window];
    self.containerView.hidden = NO;
    [window bringSubviewToFront:self.containerView];

    // Un événement arrivé pendant l'unique passage de rattrapage sera traité
    // immédiatement maintenant que les guards de panneau visible s'appliquent.
    if (self.contentRefreshPendingWhileOpening) {
        self.contentRefreshPendingWhileOpening = NO;
        [self forceRefreshIfNeeded];
    }
}

- (void)showForThreadRootID:(NSString *)threadRootID
            tappedMessageID:(NSString *)tappedMessageID
     retainedThreadMessages:(NSArray<S7TVChatMessage *> *)retainedThreadMessages
                  sourceView:(SevenTVChatCustomView *)sourceView {
    if (!threadRootID.length) return;
    UIView *hostChatView = s7tv_activeChatCustomView();
    UIWindow *window = hostChatView.window;
    if (!hostChatView || !window) return;

    // Un seul contexte flottant à la fois : fermer d'abord une éventuelle
    // réponse autonome (et retirer sa mention) avant de préparer le Fil.
    [self s7tv_clearReplyTargetRemovingMention];
    [self s7tv_clearThreadSourceHighlight];
    [self s7tv_ensureContainerInWindow:window];
    [self s7tv_attachReplyTargetBarToThreadHost];
    self.contentRequestGeneration += 1; // invalide immédiatement show/refresh précédent
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
    self.titleLabel.text = L(@"chat_reply_thread_panel_title"); // relu à chaque ouverture, voir commentaire sur titleLabel
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.currentThreadRootID = threadRootID;
    self.pendingReplyTargetMessageID = tappedMessageID;
    self.threadSourceView = sourceView;
    self.threadSourceMessageID = tappedMessageID;
    [sourceView setReplyTargetHighlightedMessageID:tappedMessageID];
    self.rootChatView.renderingSuspended = NO;
    self.repliesChatView.renderingSuspended = NO;

    // Aucune sélection automatique : le panneau s'ouvre en pure
    // consultation, l'utilisateur choisit explicitement une cible par appui
    // long sur le message de son choix (même geste que le chat principal, voir
    // selectReplyTargetForMessageID:username: plus bas) — demande explicite,
    // l'auto-insertion précédente gênait quand on ouvrait juste pour lire.
    // Le contenu doit être RÉELLEMENT appliqué (pas juste "reload appelé")
    // avant de mesurer sa hauteur — sinon le panneau se dimensionne sur du
    // vide et se corrige seulement au refresh suivant (clignotement
    // visible à l'ouverture, corrigé ici).
    __weak typeof(self) weakSelf = self;
    [self s7tv_reloadThreadMessagesForce:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.containerView.window != window ||
            ![strongSelf.currentThreadRootID isEqualToString:threadRootID]) return;
        [strongSelf s7tv_finishOpeningThreadRootID:threadRootID
                                            window:window
                                  allowsCatchUpPass:YES];
    }];
}

// Retrouve la même instance que celle affichée, y compris lorsqu'un transcript
// figé la retient après sa purge du FIFO principal.
- (nullable S7TVChatMessage *)s7tv_messageForReplyTargetID:(NSString *)messageID {
    S7TVChatMessage *message = [self.rootStore messageWithID:messageID];
    if (!message) message = [self.repliesStore messageWithID:messageID];
    if (!message) message = [s7tv_activeChatCustomView() displayedMessageWithID:messageID];
    if (!message) {
        message = [[SevenTVManager sharedManager].chatMessageStore messageWithID:messageID];
    }
    return message;
}

// L'appui long du chat principal et celui des vues du thread arrivent tous
// ici. L'insertion de mention et la barre d'annulation restent donc uniques.
- (void)selectReplyTargetForMessageID:(NSString *)messageID username:(NSString *)username {
    SevenTVChatCustomView *sourceView = s7tv_activeChatCustomView();
    if (!sourceView) return;
    [self selectReplyTargetForMessageID:messageID
                               username:username
                             sourceView:sourceView];
}

- (void)selectReplyTargetForMessageID:(NSString *)messageID
                             username:(NSString *)username
                           sourceView:(SevenTVChatCustomView *)sourceView {
    if (!messageID.length || !username.length) return;

    BOOL replyComesFromThread =
        sourceView == self.rootChatView || sourceView == self.repliesChatView;

    // Un changement de cible passe par le même nettoyage qu'« Annuler » :
    // l'ancien préfixe exact et son surlignage sont retirés avant d'insérer
    // puis de peindre la nouvelle sélection. Si la nouvelle réponse vient du
    // chat principal alors qu'un Fil est ouvert, hide invalide aussi toutes
    // les completions asynchrones du Fil avant d'afficher la réponse autonome.
    if (!replyComesFromThread && self.currentThreadRootID.length) {
        [self hide];
    } else {
        [self s7tv_clearReplyTargetRemovingMention];
    }

    self.selectedReplyTargetMessageID = messageID;
    self.selectedReplyTargetUsername = username;
    self.replyTargetSourceView = sourceView;
    [sourceView setReplyTargetHighlightedMessageID:messageID];
    [self s7tv_ensureReplyTargetBar];
    [self.cancelButton setTitle:L(@"chat_reply_cancel_button") forState:UIControlStateNormal];
    self.replyTargetBarLabel.attributedText = s7tv_buildReplyTargetBarText(username);

    if (replyComesFromThread) {
        // Dans un fil, le message sélectionné est déjà visible juste au-dessus
        // et reste surligné : aucune copie/preview supplémentaire.
        self.replyTargetMessageView.hidden = YES;
        self.replyTargetMessageView.renderingSuspended = YES;
        self.replyTargetMessageViewHeightConstraint.constant = 0;
        [self s7tv_attachReplyTargetBarToThreadHost];
        self.replyTargetBarHeightConstraint.constant = kS7TVReplyTargetActionRowHeight;
        self.replyTargetBarView.hidden = NO;
    } else {
        S7TVChatMessage *message = [sourceView displayedMessageWithID:messageID];
        if (!message) message = [self s7tv_messageForReplyTargetID:messageID];

        self.replyTargetBarHeightConstraint.constant = 0;
        self.replyTargetMessageView.hidden = NO;
        self.replyTargetMessageView.renderingSuspended = NO;
        self.replyTargetMessageViewHeightConstraint.constant = 0;
        [self.replyTargetMessageView resetTransientTranscriptState];
        [self.replyTargetMessageStore seedReadOnlyWithMessages:message ? @[message] : @[]];

        UIWindow *window = sourceView.window ?: s7tv_activeChatCustomView().window;
        [self s7tv_showStandaloneReplyTargetBarInWindow:window];

        // Même séquence que la racine épinglée d'un fil : attendre le vrai
        // snapshot, mesurer à la largeur finale, puis donner exactement la
        // hauteur intrinsèque au UITableView non scrollable.
        NSString *requestedMessageID = [messageID copy];
        __weak typeof(self) weakSelf = self;
        [self.replyTargetMessageView reloadMessagesWithCompletion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf ||
                ![strongSelf.selectedReplyTargetMessageID isEqualToString:requestedMessageID] ||
                strongSelf.replyTargetSourceView != sourceView) return;

            // Le snapshot et le self-sizing sont maintenant terminés : la
            // barre peut être révélée après sa mesure atomique.
            strongSelf.replyTargetBarView.hidden = NO;
            [strongSelf s7tv_resizeStandaloneReplyTargetBarInWindow:window];
        }];
    }

    self.lastInsertedMentionText = s7tv_insertMentionAtStartOfChatInput(username);

    if (replyComesFromThread) {
        [self s7tv_layoutPanelContentInWindow:self.containerView.window];
    }
}

- (void)s7tv_clearReplyTargetRemovingMention {
    [self.replyTargetSourceView setReplyTargetHighlightedMessageID:nil];
    self.replyTargetSourceView = nil;
    self.selectedReplyTargetMessageID = nil;
    self.selectedReplyTargetUsername = nil;
    self.replyTargetMessageView.hidden = YES;
    self.replyTargetMessageView.renderingSuspended = YES;
    self.replyTargetMessageViewHeightConstraint.constant = 0;
    self.standaloneReplyBarHeightConstraint.constant = kS7TVReplyTargetActionRowHeight;
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

- (void)s7tv_clearThreadSourceHighlight {
    [self.threadSourceView setReplyTargetHighlightedMessageID:nil];
    self.threadSourceView = nil;
    self.threadSourceMessageID = nil;
}

- (void)s7tv_cancelReplyTargetTapped {
    UIWindow *window = self.containerView.window;
    BOOL shouldRelayoutThread = self.currentThreadRootID.length > 0 &&
        window && !self.containerView.hidden;
    [self s7tv_clearReplyTargetRemovingMention];
    if (shouldRelayoutThread) [self s7tv_layoutPanelContentInWindow:window];
}

- (void)hide {
    self.contentRequestGeneration += 1;
    self.containerView.hidden = YES;
    self.rootChatView.renderingSuspended = YES;
    self.repliesChatView.renderingSuspended = YES;
    self.currentThreadRootID = nil;
    self.pendingReplyTargetMessageID = nil;
    self.loadedThreadRootID = nil;
    self.lastRequestedRootMessageID = nil;
    self.lastRequestedReplyMessageIDs = nil;
    self.lastRequestedRootMessage = nil;
    self.lastRequestedReplyMessages = nil;
    self.contentRefreshPendingWhileOpening = NO;
    self.openingTranscriptMessages = nil;
    [self.rootChatView resetTransientTranscriptState];
    [self.repliesChatView resetTransientTranscriptState];
    [self s7tv_clearThreadSourceHighlight];
    // Fermer le panneau retire aussi la mention en cours — demande
    // explicite : contrairement à la version précédente, fermer sans
    // "Annuler" doit quand même nettoyer le texte, pas le laisser en place.
    [self s7tv_clearReplyTargetRemovingMention];
}

- (void)refreshIfNeeded {
    if (!self.currentThreadRootID.length) return;
    if (self.containerView.hidden) {
        self.contentRefreshPendingWhileOpening = YES;
        return;
    }
    UIWindow *window = self.containerView.window;
    __weak typeof(self) weakSelf = self;
    [self s7tv_reloadThreadMessagesForce:NO completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !window || strongSelf.containerView.hidden) return;
        [strongSelf s7tv_layoutPanelContentInWindow:window];
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
    [self s7tv_reloadThreadMessagesForce:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !window || strongSelf.containerView.hidden) return;
        [strongSelf s7tv_layoutPanelContentInWindow:window];
    }];
}

- (void)refreshMessageIfNeededWithID:(NSString *)messageID
                       excludingView:(SevenTVChatCustomView *)excludedView {
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
        [strongSelf s7tv_layoutPanelContentInWindow:window];
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

- (void)applyModerationState:(S7TVChatMessageState)state
   toRetainedMessageWithID:(NSString *)messageID
             moderationKind:(S7TVChatModerationKind)moderationKind
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

    NSMutableArray<S7TVChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (S7TVChatMessage *message in retained) {
        if (![message.messageID isEqualToString:messageID]) continue;
        [message applyModerationState:state
                       moderationKind:moderationKind
                      durationSeconds:durationSeconds];
    }
}

- (void)applyModerationToRetainedMessagesForUserID:(NSString *)authorUserID
                                      authorLogin:(NSString *)authorLogin
                                    moderationKind:(S7TVChatModerationKind)moderationKind
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

    NSMutableArray<S7TVChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (S7TVChatMessage *message in retained) {
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

- (void)applyModerationToAllRetainedMessages {
    [self.rootChatView applyModerationToAllDisplayedMessages];
    [self.repliesChatView applyModerationToAllDisplayedMessages];

    NSMutableArray<S7TVChatMessage *> *retained = [NSMutableArray array];
    [retained addObjectsFromArray:self.rootStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.repliesStore.allMessages ?: @[]];
    [retained addObjectsFromArray:self.openingTranscriptMessages ?: @[]];
    if (self.lastRequestedRootMessage) [retained addObject:self.lastRequestedRootMessage];
    [retained addObjectsFromArray:self.lastRequestedReplyMessages ?: @[]];
    for (S7TVChatMessage *message in retained) {
        if (message.type == S7TVChatMessageTypeHistoryWelcome ||
            message.type == S7TVChatMessageTypeHistoryDivider) continue;
        [message applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:S7TVChatModerationKindChatCleared
                      durationSeconds:0];
    }
}

@end
