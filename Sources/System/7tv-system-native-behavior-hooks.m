/*
 * 7tv-system-native-behavior-hooks.m
 *
 * Modules "100% autonomes" qui modifient un comportement natif de Twitch
 * sans rapport avec le rendu 7TV (emotes/chat/badges) :
 *
 *  1. Auto Collect Channel Points — détecte et réclame automatiquement les
 *     coffres de points de chaîne (deux voies de détection : GQL au join
 *     de la chaîne, et PubSub "claim-available" en cours de session), avec
 *     dédup, cooldown de retry, et plafond anti-spam.
 *
 *  2. Verrou d'orientation — hijack du bouton Share du lecteur theater pour
 *     verrouiller l'orientation de l'écran (requestGeometryUpdate iOS 16+,
 *     fallback setStatusBarOrientation: sinon), avec toast de confirmation.
 *
 * Extrait de 7tv-core-runtime-hooks.m. Le scan de la barre de saisie est partagé avec
 * SevenTVChatCustomView ; seuls l'utilitaire JSON et le helper de swizzle
 * restent fournis par le point d'entrée réseau.
 *
 * Fonctions exposées par ce fichier (déclarées dans 7tv-core-manager.h) pour
 * les points d'accroche restés dans 7tv-core-runtime-hooks.m :
 *  - s7tv_scanGQLResponseForChannelPointsClaim() — hooks NSURLSession
 *  - s7tv_scanWebSocketTextForChannelPointsClaimAvailable() — hook WebSocket
 *  - s7tv_setPendingChannelPointsClaimID() — confirmation Apollo (succès mutation)
 *  - s7tv_scanForChannelPointsLoop() — démarrage polling depuis le constructeur
 *  - s7tv_isOrientationLocked() — lecture seule, pour l'icône du bouton Share
 *    au moment du hijack (avant même le premier lock)
 *  - s7tv_swizzle_orientation_lock() — réactive l'observer d'auto-lock au
 *     lancement si nécessaire ; les swizzles s'installent au premier lock
 */

#import "System/7tv-system-native-behavior-hooks.h"
#import "Core/7tv-core-manager.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Localization/7tv-localization-manager.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Clé NSUserDefaults Auto Collect Channel Points — déplacée depuis le haut
// de 7tv-core-runtime-hooks.m (elle n'y était utilisée que par ce module).
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"
static NSString *const kS7TVOrientationLockButtonEnabled =
    @"s7tv_orientation_lock_button_enabled";
static NSString *const kS7TVAutoOrientationLockMode =
    @"s7tv_auto_orientation_lock_mode";

// Marque une instance ChatInputView déjà sous polling (associated object) —
// spécifique au module Channel Points, déplacée depuis le bloc "Clés
// associated objects" de 7tv-core-runtime-hooks.m où elle vivait aux côtés de clés
// sans rapport (kS7TVBitsHijacked, kS7TVShareHijacked, etc.).
static const char kS7TVChannelPointsPolling = 9;
static const char kS7TVShareHijacked = 8;
static const char kS7TVShareButtonSnapshot = 10;

@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end

static void s7tv_refreshOrientationObserver(void);
static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void);

@interface S7TVShareActionRecord : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end
@implementation S7TVShareActionRecord
@end

@interface S7TVShareButtonSnapshot : NSObject
@property (nonatomic, copy) NSArray<S7TVShareActionRecord *> *actions;
@property (nonatomic, copy) NSArray *images;
@property (nonatomic, strong) UIColor *tintColor;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic, copy) NSString *accessibilityIdentifier;
@end
@implementation S7TVShareButtonSnapshot
@end

static NSArray<NSNumber *> *s7tv_orientationButtonStates(void) {
    return @[@(UIControlStateNormal), @(UIControlStateHighlighted),
             @(UIControlStateSelected), @(UIControlStateDisabled)];
}

static void s7tv_restoreNativeShareButton(UIButton *button) {
    S7TVShareButtonSnapshot *snapshot =
        objc_getAssociatedObject(button, &kS7TVShareButtonSnapshot);
    if (!snapshot) return;

    [button removeTarget:[SevenTVManager sharedManager]
                  action:@selector(s7tv_toggleOrientationLock:)
        forControlEvents:UIControlEventTouchUpInside];
    for (S7TVShareActionRecord *record in snapshot.actions) {
        if (record.target && record.action) {
            [button addTarget:record.target action:record.action
               forControlEvents:UIControlEventTouchUpInside];
        }
    }
    NSArray<NSNumber *> *states = s7tv_orientationButtonStates();
    for (NSUInteger index = 0; index < states.count; index++) {
        id storedImage = index < snapshot.images.count ? snapshot.images[index] : NSNull.null;
        [button setImage:(storedImage == NSNull.null ? nil : storedImage)
                forState:states[index].unsignedIntegerValue];
    }
    button.tintColor = snapshot.tintColor;
    button.accessibilityLabel = snapshot.accessibilityLabel;
    button.accessibilityIdentifier = snapshot.accessibilityIdentifier ?: @"share_button";
    objc_setAssociatedObject(button, &kS7TVShareButtonSnapshot, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *ancestor = button.superview;
    while (ancestor &&
           ![NSStringFromClass(ancestor.class)
               isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
        ancestor = ancestor.superview;
    }
    if (ancestor) {
        objc_setAssociatedObject(ancestor, &kS7TVShareHijacked, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void s7tv_handleTheaterControlsViewLifecycle(UIView *view) {
    if (!s7tv_orientationLockButtonEnabled()) return;
    if (![NSStringFromClass(view.class) isEqualToString:@"Twitch.TheaterPlayerControlsView"] ||
        !view.window || objc_getAssociatedObject(view, &kS7TVShareHijacked)) return;

    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *controls = weakView;
        if (!s7tv_orientationLockButtonEnabled() || !controls || !controls.window ||
            ![NSStringFromClass(controls.window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"] ||
            objc_getAssociatedObject(controls, &kS7TVShareHijacked)) return;
        objc_setAssociatedObject(controls, &kS7TVShareHijacked, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIButton *shareButton = nil;
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:controls];
        while (views.count > 0) {
            UIView *candidate = views.firstObject;
            [views removeObjectAtIndex:0];
            if ([candidate isKindOfClass:UIButton.class] &&
                [candidate.accessibilityIdentifier isEqualToString:@"share_button"]) {
                shareButton = (UIButton *)candidate;
                break;
            }
            [views addObjectsFromArray:candidate.subviews];
        }
        if (!shareButton) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ share_button introuvable dans TheaterPlayerControlsView"];
            return;
        }

        S7TVShareButtonSnapshot *snapshot = [S7TVShareButtonSnapshot new];
        NSMutableArray<S7TVShareActionRecord *> *savedActions = [NSMutableArray array];
        for (id target in shareButton.allTargets) {
            for (NSString *actionName in [shareButton actionsForTarget:target
                                                        forControlEvent:UIControlEventTouchUpInside]) {
                S7TVShareActionRecord *record = [S7TVShareActionRecord new];
                record.target = target;
                record.action = NSSelectorFromString(actionName);
                [savedActions addObject:record];
            }
        }
        NSMutableArray *savedImages = [NSMutableArray array];
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            UIImage *image = [shareButton imageForState:state.unsignedIntegerValue];
            [savedImages addObject:image ?: NSNull.null];
        }
        snapshot.actions = savedActions;
        snapshot.images = savedImages;
        snapshot.tintColor = shareButton.tintColor;
        snapshot.accessibilityLabel = shareButton.accessibilityLabel;
        snapshot.accessibilityIdentifier = shareButton.accessibilityIdentifier;
        objc_setAssociatedObject(shareButton, &kS7TVShareButtonSnapshot, snapshot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        for (id target in shareButton.allTargets) {
            for (NSString *action in [shareButton actionsForTarget:target
                                                   forControlEvent:UIControlEventTouchUpInside]) {
                [shareButton removeTarget:target action:NSSelectorFromString(action)
                         forControlEvents:UIControlEventTouchUpInside];
                [[SevenTVManager sharedManager] log:@"🔌 Share: action retirée — %@->%@",
                    NSStringFromClass([target class]), action];
            }
        }

        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
            configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        NSString *symbol = s7tv_isOrientationLocked()
            ? @"lock.rotation" : @"lock.rotation.open";
        UIImage *icon = [UIImage systemImageNamed:symbol withConfiguration:configuration];
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            [shareButton setImage:icon forState:state.unsignedIntegerValue];
        }
        shareButton.tintColor = s7tv_isOrientationLocked()
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : UIColor.whiteColor;
        shareButton.accessibilityLabel = s7tv_isOrientationLocked()
            ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
        shareButton.accessibilityIdentifier = @"s7tv_lock_button";
        [shareButton addTarget:[SevenTVManager sharedManager]
                        action:@selector(s7tv_toggleOrientationLock:)
              forControlEvents:UIControlEventTouchUpInside];
        [[SevenTVManager sharedManager]
            log:@"✅ Bouton Share hijacké → verrou orientation"];
        s7tv_refreshOrientationObserver();
    });
}

// ────────────────────────────────────────────────────────────
// MARK: - Auto Collect Channel Points (module 100% autonome)
// ────────────────────────────────────────────────────────────
//
// Volontairement indépendant de tout le reste du fichier (pas de swizzle
// partagé avec le hijack Bits ou le verrou d'orientation, sauf le hook
// GQL Apollo ci-dessous qui lui est indispensable).
//
// ARCHITECTURE FINALE (après plusieurs itérations, voir historique git
// pour le détail des approches écartées — UI/valueForKey:, GlowView,
// CALayer.animationKeys : toutes invalidées par des tests réels) :
//
//  1. s7tv_swizzle_apollo_gql() — hook sur Apollo.URLSessionClient
//     (TwitchApollo.framework), le vrai client GraphQL de Twitch. Pilote
//     ses requêtes via l'API DELEGATE de NSURLSession
//     (-URLSession:dataTask:didReceiveData:/-URLSession:task:
//     didCompleteWithError:), invisible à un swizzle sur les méthodes à
//     completion handler de NSURLSession. Accumule les chunks par
//     taskIdentifier et transmet le corps complet une fois assemblé.
//
//  2. s7tv_scanGQLResponseForChannelPointsClaim() — scanne chaque réponse
//     gql.twitch.tv (gate rapide par octets avant tout parsing JSON) pour
//     le champ `CommunityPoints.availableClaim` : non-null seulement
//     quand un coffre est réclamable — c'est le booléen `showsClaim`
//     interne de Twitch, mais exposé en JSON brut, donc indépendant de
//     Swift/KVC/UI. Dès qu'un nouvel ID de coffre est détecté, déclenche
//     IMMÉDIATEMENT (main thread) — pas d'attente du prochain tick.
//
//  3. s7tv_triggerChannelPointsClaimIfNeeded() — logique unique de
//     déclenchement (dédup par ID, vérif pref utilisateur, appel natif).
//     Appelle -[ChatInputView handleChannelPointsButtonTapped] (méthode
//     @objc réelle, le vrai handler UIControl branché en target/action
//     sur le bouton) — Twitch envoie alors lui-même la vraie mutation
//     GraphQL authentifiée (ClaimChannelPointsMutation). On ne reconstruit
//     jamais aucune requête réseau nous-mêmes.
//
//  4. s7tv_pollChannelPointsClaim()/s7tv_scanForChannelPointsLoop() —
//     filet de sécurité silencieux (1.5s/2s) pour le seul cas où le
//     déclenchement immédiat n'a pas trouvé de ChatInputView au bon
//     moment (ex: stream encore en cours de chargement réseau).

// État global : ID du dernier coffre détecté comme réclamable via GQL
// (nil si aucun), et ID du dernier coffre effectivement déclenché, pour
// dédupliquer sans dépendre d'un associated object sur une vue UI qui
// n'est plus nécessaire à la détection. Protégé par @synchronized car
// écrit depuis le thread réseau (completion handler NSURLSession) et lu
// depuis le main thread (boucle de polling).
static NSString *s_s7tvPendingChannelPointsClaimID = nil;

// Dédup PAR COOLDOWN, pas permanente : on retente le même ID toutes les
// S7TVChannelPointsClaimRetryCooldown secondes tant que le GQL continue de le signaler
// (voir s7tv_scanGQLResponseForChannelPointsClaim). Nécessaire car
// performSelector peut s'exécuter "avec succès" (aucune exception) sans
// que Twitch envoie réellement la mutation — observé en conditions réelles
// juste après un lancement d'app : la ChatInputView existe déjà et répond
// au sélecteur, mais son câblage interne (bindings Channel Points) n'est
// pas encore prêt. Le seul signal fiable de succès réel est la
// confirmation serveur (availableClaim redevient null) — donc tant qu'elle
// n'arrive pas, on continue d'essayer plutôt que d'abandonner après une
// tentative qui n'a peut-être rien fait.
static NSString      *s_s7tvLastTriggeredChannelPointsClaimID = nil;
static NSTimeInterval  s_s7tvLastTriggerAttemptTime = 0;
const NSTimeInterval S7TVChannelPointsClaimRetryCooldown = 4.0;

// Garde-fou anti-spam : plafond de tentatives par coffre. Sans lui, un
// coffre dont le tap natif ne produit jamais de requête réseau (observé en
// conditions réelles : handleChannelPointsButtonTapped exécuté sans
// exception mais AUCUNE requête ClaimChannelPointsMutation envoyée sur 30+
// tentatives) fait ouvrir/fermer en boucle le panneau de dépense des
// Channel Points — Twitch route apparemment le tap vers cette action au
// lieu du claim quand son état interne ne considère pas (encore, ou plus)
// ce coffre comme actif, même si notre détection réseau externe (GQL/
// PubSub) le signale toujours comme disponible. On abandonne après
// kS7TVMaxRetryDuration secondes de tentatives infructueuses sur le MÊME
// ID, et on efface pendingClaimID pour que le polling arrête de le
// retenter — une détection ultérieure authentique du même ID (nouvel
// événement GQL/PubSub) réarmera le compteur.
static NSString      *s_s7tvClaimIDBeingTimed = nil;
static NSTimeInterval  s_s7tvFirstAttemptTimeForCurrentClaim = 0;
static const NSTimeInterval kS7TVMaxRetryDuration = 60.0;

void s7tv_setPendingChannelPointsClaimID(NSString *claimID) {
    @synchronized ([SevenTVManager class]) {
        s_s7tvPendingChannelPointsClaimID = [claimID copy];
    }
}

static NSString *s7tv_getPendingChannelPointsClaimID(void) {
    @synchronized ([SevenTVManager class]) {
        return s_s7tvPendingChannelPointsClaimID;
    }
}

// Appelé sur CHAQUE réponse gql.twitch.tv interceptée (thread réseau).
// Gate rapide par recherche d'octets bruts avant de payer le coût d'un
// parsing JSON complet — la quasi-totalité des réponses GQL n'ont rien à
// voir avec les Channel Points (chat, badges, métadonnées stream...).
static void s7tv_triggerChannelPointsClaimIfNeeded(NSString *claimID); // forward decl, définie plus bas

void s7tv_scanGQLResponseForChannelPointsClaim(NSData *data) {
    if (data.length == 0) return;

    static NSData *s_needle = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_needle = [@"availableClaim" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([data rangeOfData:s_needle options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
        return;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || !json) return;

    BOOL found = NO;
    id claim = s7tv_findValueForKeyRecursive(json, @"availableClaim", &found);
    if (!found) return;

    if (!claim || [claim isKindOfClass:[NSNull class]]) {
        s7tv_setPendingChannelPointsClaimID(nil);
        return;
    }

    if ([claim isKindOfClass:[NSDictionary class]]) {
        NSString *claimID = claim[@"id"];
        if (!claimID.length) claimID = @"unknown";
        s7tv_setPendingChannelPointsClaimID(claimID);

        // Déclenchement immédiat (main thread) plutôt que d'attendre le
        // prochain tick du polling de secours — latence minimale entre la
        // détection réseau et la collecte réelle.
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_triggerChannelPointsClaimIfNeeded(claimID);
        });
    }
}
// DIAGNOSTIC — recense TOUTES les instances de Twitch.ChatInputView
// actuellement en mémoire (pas seulement la première trouvée), avec leur
// fenêtre et leur état isKeyWindow/hidden. Sert à vérifier l'hypothèse
// qu'on puisse taper sur une instance orpheline/inactive quand plusieurs
// coexistent (ex: transition PiP, changement d'écran). Appelé uniquement
// juste avant un vrai tap (pas à chaque poll) pour rester peu bavard.
static void s7tv_logAllChatInputViewInstances(void) {
    NSMutableArray<UIView *> *allFound = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:window];
            while (bfs.count > 0) {
                UIView *v = bfs.firstObject;
                [bfs removeObjectAtIndex:0];
                if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.ChatInputView"]) {
                    [allFound addObject:v];
                }
                [bfs addObjectsFromArray:v.subviews];
            }
        }
    }

    if (allFound.count <= 1) {
        [[SevenTVManager sharedManager]
            log:@"🎁 Channel Points debug: %lu instance(s) de ChatInputView en mémoire", (unsigned long)allFound.count];
        return;
    }

    NSMutableString *desc = [NSMutableString stringWithFormat:
        @"🎁 Channel Points debug: %lu instances de ChatInputView trouvées simultanément :\n", (unsigned long)allFound.count];
    for (UIView *v in allFound) {
        [desc appendFormat:@"  - window=%@ isKeyWindow=%d hidden=%d alpha=%.2f frame=%@\n",
            NSStringFromClass([v.window class]),
            v.window.isKeyWindow,
            v.hidden,
            v.alpha,
            NSStringFromCGRect(v.frame)];
    }
    [[SevenTVManager sharedManager] log:@"%@", desc];
}

// Logique unique de déclenchement, appelée à la fois immédiatement depuis
// le hook réseau (cas normal, latence minimale) et depuis le polling de
// secours (cas où aucune ChatInputView n'était encore trouvable au moment
// de la détection réseau — ex: tout début de chargement du stream).
// Dédup par COOLDOWN (pas permanente) : voir le commentaire sur
// S7TVChannelPointsClaimRetryCooldown plus haut — un performSelector "réussi" (aucune
// exception) ne garantit pas qu'une vraie requête soit partie.
static void s7tv_triggerChannelPointsClaimIfNeeded(NSString *claimID) {
    if (!claimID.length) return;

    NSString *lastTriggeredClaimID;
    NSTimeInterval lastAttemptTime;
    @synchronized ([SevenTVManager class]) {
        lastTriggeredClaimID = s_s7tvLastTriggeredChannelPointsClaimID;
        lastAttemptTime = s_s7tvLastTriggerAttemptTime;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL recentlyAttemptedSameClaim = [claimID isEqualToString:lastTriggeredClaimID]
        && (now - lastAttemptTime) < S7TVChannelPointsClaimRetryCooldown;
    if (recentlyAttemptedSameClaim) return;

    // Plafond anti-spam : voir kS7TVMaxRetryDuration plus haut.
    NSTimeInterval firstAttemptTime;
    NSString *claimIDBeingTimed;
    @synchronized ([SevenTVManager class]) {
        claimIDBeingTimed = s_s7tvClaimIDBeingTimed;
        firstAttemptTime = s_s7tvFirstAttemptTimeForCurrentClaim;
    }
    if (![claimID isEqualToString:claimIDBeingTimed]) {
        // Nouveau coffre (ou premier essai) — on démarre le chrono.
        @synchronized ([SevenTVManager class]) {
            s_s7tvClaimIDBeingTimed = claimID;
            s_s7tvFirstAttemptTimeForCurrentClaim = now;
        }
    } else if ((now - firstAttemptTime) > kS7TVMaxRetryDuration) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ Channel Points: abandon après %.0fs de tentatives infructueuses (id=%@) — le tap natif ne produit aucune requête de claim, probablement ouverture du panneau de dépense côté Twitch",
            kS7TVMaxRetryDuration, claimID];
        s7tv_setPendingChannelPointsClaimID(nil); // stoppe le polling pour cet ID
        @synchronized ([SevenTVManager class]) {
            s_s7tvClaimIDBeingTimed = nil;
            s_s7tvFirstAttemptTimeForCurrentClaim = 0;
        }
        return;
    }

    UIView *chatInputView = s7tv_findChatInputView();
    if (!chatInputView || !chatInputView.window) return; // retentera au prochain déclencheur

    s7tv_logAllChatInputViewInstances();

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL autoCollectEnabled = [prefs objectForKey:kTCLiveAutoCollectChannelPoints] != nil
        ? [prefs boolForKey:kTCLiveAutoCollectChannelPoints]
        : YES; // défaut ON, comme dans les réglages
    if (!autoCollectEnabled) return;

    SEL claimSel = NSSelectorFromString(@"handleChannelPointsButtonTapped");
    if (![chatInputView respondsToSelector:claimSel]) {
        [[SevenTVManager sharedManager]
            log:@"Erreur Channel Points: sélecteur 'handleChannelPointsButtonTapped' introuvable sur ChatInputView"];
        return;
    }

    // Marqué AVANT l'appel (évite un double-déclenchement immédiat si le
    // hook réseau et le polling de secours se chevauchent), mais le
    // cooldown ci-dessus permet un retry automatique si cette tentative
    // s'avère infructueuse — pas de blocage définitif.
    @synchronized ([SevenTVManager class]) {
        s_s7tvLastTriggeredChannelPointsClaimID = claimID;
        s_s7tvLastTriggerAttemptTime = now;
    }

    [[SevenTVManager sharedManager]
        log:@"🎁 Channel Points: coffre réclamé automatiquement (id=%@) — chatInputView.window=%@ frame=%@",
        claimID, NSStringFromClass([chatInputView.window class]), NSStringFromCGRect(chatInputView.frame)];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [chatInputView performSelector:claimSel];
    #pragma clang diagnostic pop
}

// Filet de sécurité silencieux : re-tente toutes les 1.5s au cas où le
// déclenchement immédiat depuis le hook réseau n'ait pas pu trouver de
// ChatInputView au bon moment (ex: stream encore en train de charger).
// Aucun log en fonctionnement normal — seul s7tv_triggerChannelPointsClaimIfNeeded
// logue, et seulement en cas de collecte réelle ou d'erreur.
static void s7tv_pollChannelPointsClaim(UIView *chatInputView) {
    if (!chatInputView || !chatInputView.window) return;

    NSString *pendingClaimID = s7tv_getPendingChannelPointsClaimID();
    if (pendingClaimID.length > 0) {
        s7tv_triggerChannelPointsClaimIfNeeded(pendingClaimID);
    }

    __weak UIView *weakChatInputView = chatInputView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongChatInputView = weakChatInputView;
        if (strongChatInputView) {
            s7tv_pollChannelPointsClaim(strongChatInputView);
        }
    });
}

// Boucle de fond permanente : cherche une ChatInputView pas encore sous
// polling toutes les 2s. Tourne pour toute la durée de vie de l'app,
// coût négligeable (un BFS peu profond sur la hiérarchie de fenêtres,
// une fois toutes les 2 secondes). Silencieuse sauf à la découverte
// effective d'une nouvelle instance.
void s7tv_scanForChannelPointsLoop(void) {
    UIView *chatInputView = s7tv_findChatInputView();

    if (chatInputView && !objc_getAssociatedObject(chatInputView, &kS7TVChannelPointsPolling)) {
        objc_setAssociatedObject(chatInputView, &kS7TVChannelPointsPolling, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[SevenTVManager sharedManager] log:@"🎁 Channel Points: ChatInputView trouvée — démarrage du polling"];
        s7tv_pollChannelPointsClaim(chatInputView);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        s7tv_scanForChannelPointsLoop();
    });
}
// Parsing de l'événement PubSub "claim-available" (nouveau coffre qui
// spawn en cours de session — PAS le cas déjà couvert par le GQL initial
// au join de la chaîne). Format confirmé par capture réelle en conditions
// de test sur les événements jumeaux "points-earned"/"claim-claimed" de la
// même famille (classe Twitch.ChannelPoints.PubSub) :
//   {"notification":{"pubsub":"{\"type\":\"claim-claimed\",\"data\":{...,\"claim\":{\"id\":\"...\"}}}"}}
// Double encodage JSON : le champ "pubsub" est une STRING contenant du
// JSON, pas un objet direct — on parse donc en deux temps.
void s7tv_scanWebSocketTextForChannelPointsClaimAvailable(NSString *text) {
    if (!text.length) return;
    if (![text containsString:@"claim-available"]) return; // gate rapide, évite un parsing JSON sur chaque trame WS

    NSData *outerData = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!outerData) return;

    NSError *err = nil;
    id outerJSON = [NSJSONSerialization JSONObjectWithData:outerData options:0 error:&err];
    if (err || !outerJSON) return;

    BOOL foundPubsubField = NO;
    id pubsubValue = s7tv_findValueForKeyRecursive(outerJSON, @"pubsub", &foundPubsubField);
    if (!foundPubsubField || ![pubsubValue isKindOfClass:[NSString class]]) return;

    NSData *innerData = [(NSString *)pubsubValue dataUsingEncoding:NSUTF8StringEncoding];
    if (!innerData) return;

    id innerJSON = [NSJSONSerialization JSONObjectWithData:innerData options:0 error:&err];
    if (err || ![innerJSON isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *innerDict = innerJSON;
    if (![innerDict[@"type"] isEqualToString:@"claim-available"]) return;

    BOOL foundClaim = NO;
    id claim = s7tv_findValueForKeyRecursive(innerDict[@"data"], @"claim", &foundClaim);
    if (!foundClaim || ![claim isKindOfClass:[NSDictionary class]]) return;

    NSString *claimID = claim[@"id"];
    if (!claimID.length) return;

    // VÉRIFICATION CHANNEL_ID — probablement la vraie cause des échecs
    // systématiques (0 requête/60s) observés sur certains coffres. Notre
    // hook WebSocket est branché sur la classe concrète NSURLSessionWebSocketTask
    // et capte donc TOUTES les connexions, tous channels confondus (y
    // compris une souscription PubSub restée active pour une chaîne
    // visitée plus tôt dans la session). Si l'événement concerne une
    // chaîne différente de celle actuellement affichée, taper sur le
    // bouton de la chaîne AFFICHÉE ne peut jamais réclamer un coffre
    // d'une AUTRE chaîne — Twitch ouvre alors le panneau à la place,
    // sans jamais envoyer de requête de claim, quel que soit le nombre de
    // tentatives. Le champ existe et est déjà confirmé par capture réelle
    // sur les événements jumeaux "claim-claimed"/"points-earned".
    NSString *claimChannelID = claim[@"channel_id"];
    NSString *currentChannelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    if (claimChannelID.length && currentChannelID.length
        && ![claimChannelID isEqualToString:currentChannelID]) {
        [[SevenTVManager sharedManager]
            log:@"🎁 Channel Points debug: événement claim-available ignoré — channel_id=%@ ≠ chaîne actuelle=%@",
            claimChannelID, currentChannelID];
        return;
    }

    s7tv_setPendingChannelPointsClaimID(claimID);

    // Délai volontaire avant la 1ère tentative (uniquement pour ce chemin
    // PubSub) : on intercepte les octets bruts de la trame AVANT que le
    // pipeline interne de Twitch (son propre observer ChannelPoints.PubSub
    // sur cette même trame) ait eu le temps de mettre à jour l'état interne
    // du bouton (showsClaim). Sans ce délai, handleChannelPointsButtonTapped
    // ouvre le panneau de dépense au lieu de claim (0 requête réseau
    // observée sur 30 tentatives en conditions réelles). Le chemin GQL (au
    // join) n'a pas ce problème — l'état y est déjà cohérent dès la
    // construction de la vue — donc pas de délai ajouté là-bas.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        s7tv_triggerChannelPointsClaimIfNeeded(claimID);
    });
}
// État global verrou d'orientation — déplacées depuis le haut de
// 7tv-core-runtime-hooks.m (section "Clés associated objects") où elles vivaient sans
// rapport avec les autres clés qui y restent. s_orientationLocked est lue en
// lecture seule par le hijack du bouton Share ci-dessus, avant même le
// premier lock, pour l'état initial de l'icône) via s7tv_isOrientationLocked().
static BOOL s_orientationLocked = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
static UIDeviceOrientation s_lastAutoLockCandidate = UIDeviceOrientationUnknown;

// ────────────────────────────────────────────────────────────
// MARK: - Verrou d'orientation (bouton Share hijacké)
// Approche : requestGeometryUpdate (iOS 16+) pour forcer l'orientation
// de la scène au niveau système — c'est la seule API qui contrôle
// réellement la rotation visuelle sur les apps SwiftUI modernes.
// Combiné avec shouldAutorotate=NO pour bloquer UIKit en parallèle.
// ────────────────────────────────────────────────────────────

// ── Orientation verrouillée capturée au moment du lock ───────────────────────
static UIInterfaceOrientation s_lockedOrientation = UIInterfaceOrientationUnknown;

// ── Observer rotation physique ───────────────────────────────────────────────
static id s_orientationObserver = nil;
static void s7tv_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast);

BOOL s7tv_orientationLockButtonEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kS7TVOrientationLockButtonEnabled] != nil
        ? [defaults boolForKey:kS7TVOrientationLockButtonEnabled] : YES;
}

S7TVAutoOrientationLockMode s7tv_autoOrientationLockMode(void) {
    NSInteger rawMode = [NSUserDefaults.standardUserDefaults
        integerForKey:kS7TVAutoOrientationLockMode];
    if (rawMode < S7TVAutoOrientationLockModeDisabled ||
        rawMode > S7TVAutoOrientationLockModeBothLandscapes) {
        return S7TVAutoOrientationLockModeDisabled;
    }
    return (S7TVAutoOrientationLockMode)rawMode;
}

// ── Force la géométrie de toutes les scènes actives ─────────────────────────
static void s7tv_forceSceneOrientation(UIInterfaceOrientationMask mask) {
    // iOS 16+ : UIWindowScene requestGeometryUpdate:errorHandler:
    // Appelé via objc_msgSend pour éviter les erreurs de header manquant dans le SDK Theos
    SEL reqSel   = NSSelectorFromString(@"requestGeometryUpdate:errorHandler:");
    Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;

        if (prefsCls && [ws respondsToSelector:reqSel]) {
            id prefs = [[prefsCls alloc] initWithInterfaceOrientations:mask];
            ((void(*)(id, SEL, id, id))objc_msgSend)(ws, reqSel, prefs, nil);
        } else {
            // Fallback iOS < 16 : setStatusBarOrientation:animated: (déprécié)
            UIInterfaceOrientation target = UIInterfaceOrientationPortrait;
            if (mask == UIInterfaceOrientationMaskLandscapeLeft)               target = UIInterfaceOrientationLandscapeLeft;
            else if (mask == UIInterfaceOrientationMaskLandscapeRight)         target = UIInterfaceOrientationLandscapeRight;
            else if (mask == UIInterfaceOrientationMaskPortraitUpsideDown)     target = UIInterfaceOrientationPortraitUpsideDown;
            SEL fbSel = NSSelectorFromString(@"setStatusBarOrientation:animated:");
            ((void(*)(id, SEL, UIInterfaceOrientation, BOOL))objc_msgSend)(
                [UIApplication sharedApplication], fbSel, target, NO);
        }
    }
}

static UIInterfaceOrientation s7tv_interfaceOrientationForDeviceOrientation(
    UIDeviceOrientation deviceOrientation) {
    // Les enums device et interface sont inversés : lorsque le haut physique
    // du téléphone pointe à gauche, le contenu UIKit est en LandscapeRight.
    if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationUnknown;
}

static BOOL s7tv_autoModeAcceptsInterfaceOrientation(
    S7TVAutoOrientationLockMode mode, UIInterfaceOrientation orientation) {
    if (mode == S7TVAutoOrientationLockModeBothLandscapes) return YES;
    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        return mode == S7TVAutoOrientationLockModeLandscapeLeft;
    }
    if (orientation == UIInterfaceOrientationLandscapeRight) {
        return mode == S7TVAutoOrientationLockModeLandscapeRight;
    }
    return NO;
}

static void s7tv_handlePhysicalOrientationChange(void) {
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    if (deviceOrientation == UIDeviceOrientationPortrait ||
        deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
        // Le retour en portrait réarme l'auto-lock. Un déverrouillage manuel
        // en restant exactement du même côté ne reboucle donc pas.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_orientationLocked || !s7tv_orientationLockButtonEnabled() ||
        !s7tv_hasOrientationLockButtonInActivePlayer()) return;

    UIInterfaceOrientation target =
        s7tv_interfaceOrientationForDeviceOrientation(deviceOrientation);
    S7TVAutoOrientationLockMode mode = s7tv_autoOrientationLockMode();
    if (target == UIInterfaceOrientationUnknown) return;
    if (!s7tv_autoModeAcceptsInterfaceOrientation(mode, target)) {
        // Quitter le côté sélectionné vers l'autre paysage réarme aussi la
        // détection, sans exiger un passage artificiel par le portrait.
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        return;
    }
    if (s_lastAutoLockCandidate == deviceOrientation) return;

    s_lastAutoLockCandidate = deviceOrientation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (s_orientationLocked || !s7tv_orientationLockButtonEnabled() ||
            !s7tv_hasOrientationLockButtonInActivePlayer() ||
            UIDevice.currentDevice.orientation != deviceOrientation ||
            !s7tv_autoModeAcceptsInterfaceOrientation(
                s7tv_autoOrientationLockMode(), target)) return;
        s7tv_setOrientationLockState(YES, target, YES);
    });
}

// L'observer reste vivant lorsque le verrou est actif OU lorsqu'une détection
// automatique est configurée. Il est entièrement supprimé dans les autres cas
// pour ne laisser aucun travail permanent inutile en arrière-plan.
static void s7tv_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        if (s_orientationLocked) {
            [[SevenTVManager sharedManager] log:@"🔒 Rotation physique bloquée (verrou actif)"];
            return;
        }
        s7tv_handlePhysicalOrientationChange();
    }];
}

static void s7tv_stopOrientationObserver(void) {
    if (!s_orientationObserver) return;
    [[NSNotificationCenter defaultCenter] removeObserver:s_orientationObserver];
    s_orientationObserver = nil;
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

static void s7tv_refreshOrientationObserver(void) {
    BOOL autoLockActive = s7tv_orientationLockButtonEnabled() &&
        s7tv_autoOrientationLockMode() != S7TVAutoOrientationLockModeDisabled;
    if (s_orientationLocked || autoLockActive) {
        s7tv_startOrientationObserver();
        if (!s_orientationLocked && autoLockActive) {
            s7tv_handlePhysicalOrientationChange();
        }
    } else {
        s7tv_stopOrientationObserver();
    }
}

// ── Toast ─────────────────────────────────────────────────────────────────────
// Fenêtre dédiée au toast — niveau UIWindowLevelAlert pour passer au-dessus
// du player Twitch qui tourne sur une fenêtre de niveau supérieur à Normal.
static UIWindow *s_toastWindow = nil;

static void s7tv_showOrientationToast(BOOL locked) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Trouver la UIWindowScene active
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!activeScene) return;

        // Créer une fenêtre dédiée au niveau Alert — au-dessus du player Twitch
        UIWindow *toastWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        toastWindow.windowLevel = UIWindowLevelAlert;
        toastWindow.backgroundColor = [UIColor clearColor];
        toastWindow.userInteractionEnabled = NO;
        // Rootvc minimal pour pouvoir addSubview
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        toastWindow.rootViewController = rootVC;
        toastWindow.hidden = NO;
        s_toastWindow = toastWindow; // retain

        UIView *container = toastWindow.rootViewController.view;
        CGFloat winW = toastWindow.bounds.size.width;
        CGFloat winH = toastWindow.bounds.size.height;

        NSString *symbol = locked ? @"lock.rotation"      : @"lock.rotation.open";
        NSString *label  = locked ? L(@"lock_locked") : L(@"lock_unlocked");

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.62];
        toast.layer.cornerRadius = 14;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:toast];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.tintColor   = locked
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : [UIColor colorWithRed:0.6  green:0.6  blue:0.65 alpha:1.0];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:iconView];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text      = label;
        lbl.font      = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:lbl];

        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor  constraintEqualToAnchor:toast.leadingAnchor  constant:12],
            [iconView.centerYAnchor  constraintEqualToAnchor:toast.centerYAnchor],
            [iconView.widthAnchor    constraintEqualToConstant:18],
            [iconView.heightAnchor   constraintEqualToConstant:18],
            [lbl.leadingAnchor       constraintEqualToAnchor:iconView.trailingAnchor constant:8],
            [lbl.trailingAnchor      constraintEqualToAnchor:toast.trailingAnchor    constant:-12],
            [lbl.centerYAnchor       constraintEqualToAnchor:toast.centerYAnchor],
            [toast.heightAnchor      constraintEqualToConstant:38],
            [toast.centerXAnchor     constraintEqualToAnchor:container.centerXAnchor],
            [toast.bottomAnchor      constraintEqualToAnchor:container.bottomAnchor constant:-(winH * 0.12)],
        ]];

        [container layoutIfNeeded];

        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1.0; } completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL ff) {
                    [toast removeFromSuperview];
                    s_toastWindow.hidden = YES;
                    s_toastWindow = nil; // libérer
                }];
            });
        }];
    });
}

// ── Hook principal : UIApplication.supportedInterfaceOrientationsForWindow: ──
// C'est le check système qui prime sur toutes les overrides Twitch dans les VCs.
@interface UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window;
@end
@implementation UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientationsForWindow:window];
}
@end

// ── Garde UIViewController au cas où (certains chemins UIKit passent par là) ──
@interface UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations;
@end
@implementation UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientations];
}
@end

@interface UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate;
@end
@implementation UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate {
    if (s_orientationLocked) return NO;
    return [self s7tv_shouldAutorotate];
}
@end

// ── Action toggle ─────────────────────────────────────────────────────────────
@implementation SevenTVManager (OrientationLock)

static void s7tv_install_orientation_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s7tv_swizzle([UIApplication class],
                     [UIApplication class],
                     @selector(supportedInterfaceOrientationsForWindow:),
                     NSSelectorFromString(@"s7tv_supportedInterfaceOrientationsForWindow:"));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(supportedInterfaceOrientations),
                     @selector(s7tv_supportedInterfaceOrientations));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(shouldAutorotate),
                     @selector(s7tv_shouldAutorotate));
        [[SevenTVManager sharedManager] log:@"✅ Swizzles verrou orientation installés (premier lock)"];
    });
}

static void s7tv_enumerateActiveViews(void (^visit)(UIView *view)) {
    if (!visit) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
            while (pending.count) {
                UIView *view = pending.firstObject;
                [pending removeObjectAtIndex:0];
                visit(view);
                [pending addObjectsFromArray:view.subviews];
            }
        }
    }
}

static BOOL s7tv_hasOrientationLockButtonInActivePlayer(void) {
    __block BOOL found = NO;
    s7tv_enumerateActiveViews(^(UIView *view) {
        if (found || ![view isKindOfClass:UIButton.class] ||
            ![view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) return;
        UIWindow *window = view.window;
        if (window && !window.hidden &&
            [NSStringFromClass(window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"]) {
            found = YES;
        }
    });
    return found;
}

static void s7tv_updateOrientationLockButtons(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    s7tv_enumerateActiveViews(^(UIView *view) {
        if (![view isKindOfClass:UIButton.class] ||
            ![view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) return;
        UIButton *button = (UIButton *)view;
        for (NSNumber *state in s7tv_orientationButtonStates()) {
            [button setImage:icon forState:state.unsignedIntegerValue];
        }
        button.tintColor = tint;
        button.accessibilityLabel = s_orientationLocked
            ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
    });
}

static UIInterfaceOrientationMask s7tv_maskForInterfaceOrientation(
    UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIInterfaceOrientationMaskLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:
            return UIInterfaceOrientationMaskLandscapeRight;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationMaskPortraitUpsideDown;
        default:
            return UIInterfaceOrientationMaskPortrait;
    }
}

static UIWindowScene *s7tv_activeWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void s7tv_setOrientationLockState(BOOL locked,
                                         UIInterfaceOrientation requestedOrientation,
                                         BOOL showToast) {
    if (locked == s_orientationLocked) return;

    if (locked) {
        s7tv_install_orientation_swizzles();
        UIWindowScene *activeScene = s7tv_activeWindowScene();
        UIInterfaceOrientation current = requestedOrientation;
        if (current == UIInterfaceOrientationUnknown) {
            current = activeScene ? activeScene.interfaceOrientation
                                  : UIInterfaceOrientationPortrait;
        }
        s_lockedOrientation = current;
        s_lockedOrientationMask = s7tv_maskForInterfaceOrientation(current);
        s_orientationLocked = YES;

        // L'auto-lock peut être notifié juste avant la fin de l'animation
        // UIKit. Dans ce seul cas, termine explicitement la rotation vers le
        // côté détecté avant que le masque ne la fige.
        if (requestedOrientation != UIInterfaceOrientationUnknown &&
            activeScene.interfaceOrientation != requestedOrientation) {
            s7tv_forceSceneOrientation(s_lockedOrientationMask);
        }
        [[SevenTVManager sharedManager]
            log:@"🔒 Orientation verrouillée (orientation=%ld)", (long)current];
    } else {
        s_orientationLocked = NO;
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation = UIInterfaceOrientationUnknown;
        UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
        s_lastAutoLockCandidate = UIDeviceOrientationIsLandscape(physical)
            ? physical : UIDeviceOrientationUnknown;
        s7tv_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        [UIViewController attemptRotationToDeviceOrientation];
        [[SevenTVManager sharedManager] log:@"🔓 Orientation déverrouillée"];
    }

    s7tv_refreshOrientationObserver();
    s7tv_updateOrientationLockButtons();
    if (showToast) s7tv_showOrientationToast(s_orientationLocked);
}

- (void)s7tv_toggleOrientationLock:(UIButton *)sender {
    if (!s7tv_orientationLockButtonEnabled()) return;
    s7tv_setOrientationLockState(!s_orientationLocked,
                                 UIInterfaceOrientationUnknown, YES);
}

@end

// Getter en lecture seule vers s_orientationLocked — utilisé par le hijack
// du bouton Share (icône/tint/label initiaux, avant
// même le premier lock). La variable elle-même reste privée à ce fichier.
BOOL s7tv_isOrientationLocked(void) {
    return s_orientationLocked;
}

void s7tv_setOrientationLockButtonEnabled(BOOL enabled) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:kS7TVOrientationLockButtonEnabled];
    [defaults synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!enabled) {
            if (s_orientationLocked) {
                s7tv_setOrientationLockState(NO, UIInterfaceOrientationUnknown, NO);
            }
            NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
            s7tv_enumerateActiveViews(^(UIView *view) {
                if ([view isKindOfClass:UIButton.class] &&
                    [view.accessibilityIdentifier isEqualToString:@"s7tv_lock_button"]) {
                    [buttons addObject:(UIButton *)view];
                }
            });
            for (UIButton *button in buttons) s7tv_restoreNativeShareButton(button);
            s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        } else {
            NSMutableArray<UIView *> *controlsViews = [NSMutableArray array];
            s7tv_enumerateActiveViews(^(UIView *view) {
                if ([NSStringFromClass(view.class)
                        isEqualToString:@"Twitch.TheaterPlayerControlsView"]) {
                    [controlsViews addObject:view];
                }
            });
            for (UIView *controls in controlsViews) {
                s7tv_handleTheaterControlsViewLifecycle(controls);
            }
        }
        s7tv_refreshOrientationObserver();
    });
}

void s7tv_setAutoOrientationLockMode(S7TVAutoOrientationLockMode mode) {
    if (mode < S7TVAutoOrientationLockModeDisabled ||
        mode > S7TVAutoOrientationLockModeBothLandscapes) {
        mode = S7TVAutoOrientationLockModeDisabled;
    }
    [NSUserDefaults.standardUserDefaults setInteger:mode
                                             forKey:kS7TVAutoOrientationLockMode];
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        s_lastAutoLockCandidate = UIDeviceOrientationUnknown;
        s7tv_refreshOrientationObserver();
    });
}

void s7tv_swizzle_orientation_lock(void) {
    // Les swizzles restent installés à la demande au premier verrouillage.
    // Seul l'observer physique démarre ici si l'auto-lock était déjà activé
    // dans les préférences d'une session précédente.
    dispatch_async(dispatch_get_main_queue(), ^{
        s7tv_refreshOrientationObserver();
    });
}
