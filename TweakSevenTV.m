/*
 * TweakSevenTV.m  —  Substrate-FREE version
 *
 * Gère :
 *   - Injection du bouton 7TV dans la barre de chat (hijack bouton Bits)
 *   - Picker d'emotes 7TV (favoris + recherche)
 *   - Interception IRC WebSocket (ROOMSTATE → chargement emotes channel)
 *   - Interception GQL Twitch (broadcaster ID → chargement emotes channel)
 *   - Section 7TV Settings dans les paramètres Twitch (AccountMenuViewController)
 *   - Tap logger de diagnostic
 *
 * Note : l'ancien pipeline de resize/ratio pour le rendu natif du chat
 * (hooks CoreText, displayLayer:, willDisplayCell BFS, NetworkImageRequester...)
 * a été retiré. Il est devenu inutile suite au passage prévu à un rendu de
 * chat maison qui connaît les dimensions des emotes dès la construction
 * (voir plan.txt). Le picker, les données 7TV, l'IRC et le GQL restent inchangés.
 *
 * Note : la redirection CDN (SevenTVURLProtocol) et son enregistrement ont
 * aussi été retirés d'ici — ce mécanisme ne se déclenchait que via le tag
 * emotes= injecté dans les messages IRC, injection elle-même supprimée.
 * SevenTVURLProtocol reste utilisé ailleurs (SevenTVManager) comme simple
 * utilitaire de cache/prefetch, plus comme intercepteur.
 *
 * Note : tout le diagnostic de reverse-engineering du picker natif Twitch
 * (sniffer NSURLProtocol bas niveau, dump des opérations GQL, Tap Logger,
 * introspection générique propriétés/ivars/méthodes, énumération de toutes
 * les fenêtres, watcher/heartbeat périodique, détection événementielle du
 * picker natif) a été retiré. Cette piste (exploiter le picker natif de
 * Twitch) est abandonnée : le picker 7TV personnalisé est désormais
 * entièrement indépendant du picker natif.
 */

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVManager.h"
#import "SevenTVLogo.h"
#import "SevenTVSettingsController.h"
#import "SevenTVChatMessage.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVChatCustomView.h"
#import "7tv-localization.h"
#import "SevenTVEmoteProvider.h"
#import "SevenTVChatTokenizer.h"
#import "SevenTVBadgeProvider.h"
// Cle NSUserDefaults Auto Collect Channel Points
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"


// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVBitsHijacked    = 6;
static const char kS7TVOrigSectionCount = 7;
static const char kS7TVShareHijacked   = 8;   // verrou orientation
static const char kS7TVChannelPointsPolling  = 9;  // marque une instance ChatInputView déjà sous polling

// État global verrou d'orientation
static BOOL s_orientationLocked             = NO;

// Variable de compat : le Tap Logger (diagnostic de reverse-engineering du
// picker natif Twitch) a été retiré de ce fichier, mais SevenTVManager.m
// lit/écrit encore s_tapLogEnabled en le synchronisant avec le réglage
// logTap des paramètres — linkage externe (pas de mot-clé static), gardée
// ici pour ne pas casser ce pont. N'a plus aucun effet côté tweak : plus
// aucun code de ce fichier ne la consulte.
BOOL s_tapLogEnabled = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;


// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzle
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle(Class targetClass,
                         Class sourceClass,
                         SEL   original,
                         SEL   swizzled) {
    if (!targetClass || !sourceClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  swizzle ignoré (classe nil): %@",
         NSStringFromSelector(original)];
        return;
    }

    Method swizzledMethod = class_getInstanceMethod(sourceClass, swizzled);
    if (!swizzledMethod) {
        [[SevenTVManager sharedManager] log:@"⚠️  méthode swizzlée introuvable: %@",
         NSStringFromSelector(swizzled)];
        return;
    }
    class_addMethod(targetClass,
                    swizzled,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod));

    Method origMethod = class_getInstanceMethod(targetClass, original);
    if (!origMethod) {
        [[SevenTVManager sharedManager] log:@"⚠️  méthode originale introuvable sur %@: %@",
         NSStringFromClass(targetClass), NSStringFromSelector(original)];
        return;
    }

    Method swizzledOnTarget = class_getInstanceMethod(targetClass, swizzled);
    method_exchangeImplementations(origMethod, swizzledOnTarget);

    [[SevenTVManager sharedManager] log:@"✅ swizzle OK [%@] %@",
     NSStringFromClass(targetClass), NSStringFromSelector(original)];
}


// ────────────────────────────────────────────────────────────
// MARK: - Wrapper weak pour associated objects (brise les retain cycles)
// ────────────────────────────────────────────────────────────

// objc_setAssociatedObject ne supporte pas les weak refs nativement.
// On emballe la référence faible dans cet objet pour éviter le retain cycle
// bitsBtn (subview) → chatInputView (superview) qui empêche la libération
// de la vue au moment de la fermeture du stream.
@interface S7TVWeakRef : NSObject
@property (nonatomic, weak) id object;
+ (instancetype)refWithObject:(id)object;
@end
@implementation S7TVWeakRef
+ (instancetype)refWithObject:(id)object {
    S7TVWeakRef *r = [S7TVWeakRef new];
    r.object = object;
    return r;
}
@end


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
// kS7TVClaimRetryCooldown secondes tant que le GQL continue de le signaler
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
static const NSTimeInterval kS7TVClaimRetryCooldown = 2.0;

static void s7tv_setPendingChannelPointsClaimID(NSString *claimID) {
    @synchronized ([SevenTVManager class]) {
        s_s7tvPendingChannelPointsClaimID = [claimID copy];
    }
}

static NSString *s7tv_getPendingChannelPointsClaimID(void) {
    @synchronized ([SevenTVManager class]) {
        return s_s7tvPendingChannelPointsClaimID;
    }
}

// Recherche récursive d'une clé dans un JSON déjà parsé (NSDictionary/
// NSArray imbriqués). `*found` distingue "clé absente" de "clé présente
// mais valant null" — cette distinction compte : si la clé est absente,
// cette réponse GQL ne concerne pas ChannelPointsQuery et on ne doit rien
// en conclure ; si elle vaut explicitement null, c'est une confirmation
// positive qu'il n'y a PAS de coffre en attente.
static id s7tv_findValueForKeyRecursive(id json, NSString *key, BOOL *found) {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        if (dict[key] != nil) {
            *found = YES;
            return dict[key];
        }
        for (id value in dict.allValues) {
            id result = s7tv_findValueForKeyRecursive(value, key, found);
            if (*found) return result;
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            id result = s7tv_findValueForKeyRecursive(item, key, found);
            if (*found) return result;
        }
    }
    return nil;
}

// Appelé sur CHAQUE réponse gql.twitch.tv interceptée (thread réseau).
// Gate rapide par recherche d'octets bruts avant de payer le coût d'un
// parsing JSON complet — la quasi-totalité des réponses GQL n'ont rien à
// voir avec les Channel Points (chat, badges, métadonnées stream...).
static void s7tv_triggerChannelPointsClaimIfNeeded(NSString *claimID); // forward decl, définie plus bas

static void s7tv_scanGQLResponseForChannelPointsClaim(NSData *data) {
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

// Cherche la première instance de Twitch.ChatInputView actuellement
// affichée, tous écrans/fenêtres connectés confondus (couvre normal,
// théâtre, et PiP si jamais Twitch y instancie sa propre ChatInputView).
static UIView *s7tv_findChatInputView(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:window];
            while (bfs.count > 0) {
                UIView *v = bfs.firstObject;
                [bfs removeObjectAtIndex:0];

                if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.ChatInputView"]) {
                    return v;
                }
                [bfs addObjectsFromArray:v.subviews];
            }
        }
    }
    return nil;
}

// Logique unique de déclenchement, appelée à la fois immédiatement depuis
// le hook réseau (cas normal, latence minimale) et depuis le polling de
// secours (cas où aucune ChatInputView n'était encore trouvable au moment
// de la détection réseau — ex: tout début de chargement du stream).
// Dédup par COOLDOWN (pas permanente) : voir le commentaire sur
// kS7TVClaimRetryCooldown plus haut — un performSelector "réussi" (aucune
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
        && (now - lastAttemptTime) < kS7TVClaimRetryCooldown;
    if (recentlyAttemptedSameClaim) return;

    UIView *chatInputView = s7tv_findChatInputView();
    if (!chatInputView || !chatInputView.window) return; // retentera au prochain déclencheur

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

    [[SevenTVManager sharedManager] log:@"🎁 Channel Points: coffre réclamé automatiquement (id=%@)", claimID];
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
static void s7tv_scanForChannelPointsLoop(void) {
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


// ────────────────────────────────────────────────────────────
// MARK: - Diagnostic Phase 0 : dump hiérarchie ChatTranscriptView
// ────────────────────────────────────────────────────────────
//
// Objectif : identifier le view controller parent exact, la hiérarchie de
// vues (Auto Layout / anchors), et si elle diffère entre mode normal,
// théâtre, et Picture-in-Picture — sans Mac/LLDB/Reveal, uniquement via
// le système de logs in-app existant (voir écran de logs → catégorie
// "Chat Custom"). Lecture seule, aucune modification de comportement.

static void s7tv_dumpChatHierarchy(UIView *chatView, NSString *reason) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"[ChatCustom] 🏗 ── Dump hiérarchie (%@) ──────────────────", reason];

    // Chaîne de superviews jusqu'à la fenêtre.
    UIView *v = chatView;
    NSInteger depth = 0;
    while (v) {
        [mgr log:@"[ChatCustom] 🏗 %@ superview[%ld] = %@ | frame=%@ | hidden=%@ | alpha=%.2f",
            (depth == 0 ? @"→" : @"  "),
            (long)depth,
            NSStringFromClass([v class]),
            NSStringFromCGRect(v.frame),
            v.isHidden ? @"OUI" : @"NON",
            v.alpha];
        v = v.superview;
        depth++;
    }

    // Fenêtre porteuse — distingue normal/théâtre (UIWindow standard) de PiP
    // (Twitch.PictureInPictureWindow, déjà identifiée ailleurs dans ce fichier).
    UIWindow *window = chatView.window;
    [mgr log:@"[ChatCustom] 🏗 window = %@ | windowScene = %@",
        window ? NSStringFromClass([window class]) : @"nil",
        window.windowScene ? NSStringFromClass([window.windowScene class]) : @"nil"];

    // Remonte la responder chain pour trouver le(s) UIViewController porteur(s).
    UIResponder *r = chatView.nextResponder;
    NSInteger vcDepth = 0;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)r;
            [mgr log:@"[ChatCustom] 🏗 viewController[%ld] = %@ | parent=%@ | presentingVC=%@",
                (long)vcDepth,
                NSStringFromClass([vc class]),
                vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"nil",
                vc.presentingViewController ? NSStringFromClass([vc.presentingViewController class]) : @"nil"];
            vcDepth++;
        }
        r = r.nextResponder;
    }
    if (vcDepth == 0) {
        [mgr log:@"[ChatCustom] ⚠️ Aucun UIViewController trouvé dans la responder chain"];
    }

    [mgr log:@"[ChatCustom] 🏗 ── Fin dump (%@) ──────────────────", reason];
}

// ────────────────────────────────────────────────────────────
// MARK: - Diagnostic Phase 1b : mesure des tailles réelles du rendu natif
// ────────────────────────────────────────────────────────────
//
// Exigence transverse #1 du plan : les défauts de SevenTVChatAppearanceConfig
// sont pour l'instant des estimations ("TODO mesure réelle"), pas les vraies
// valeurs Twitch. Contrairement à s7tv_dumpChatHierarchy (qui remonte les
// superviews), cette fonction DESCEND dans les subviews pour trouver les
// UILabel/UIImageView réellement affichés dans une cellule de message et
// logguer leur frame + police — lecture seule, aucune modification de
// comportement. Uniquement via le système de logs in-app existant (catégorie
// "Chat Custom"), pas besoin de Mac/LLDB/Reveal.

// Twitch.MessageStringView n'a pas de UILabel enfant (constaté en dump réel :
// la vue dessine son texte elle-même). Lire ses ivars bruts s'est révélé
// risqué : les classes Swift exposent des encodages de type VIDES via
// ivar_getTypeEncoding (constaté en dump réel : "()" partout, y compris sur
// des BOOL/CGFloat/CGSize) — donc impossible de distinguer un ivar objet
// d'un scalaire avant de le lire, et object_getIvar sur un scalaire peut
// planter l'app (tentative de retain sur un pointeur invalide).
//
// Approche sûre à la place :
//   1. view.layer — accesseur UIKit standard, toujours valide, zéro risque.
//   2. class_copyPropertyList sur cette layer — introspection de métadonnées
//      pure, aucun appel de méthode, zéro risque.
//   3. Lecture de valeur via KVC (valueForKey:) UNIQUEMENT pour les
//      propriétés dont l'attribut commence par "T@" (objet, encodage fiable
//      pour les propriétés @objc déclarées, contrairement aux ivars bruts),
//      protégée par @try/@catch.
static void s7tv_dumpProperties(id obj, NSString *label) {
    if (!obj) return;
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    Class cls = [obj class];
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    [mgr log:@"[ChatCustom] 🏗   ── Propriétés %@ (%@) — %u propriétés ──",
        label, NSStringFromClass(cls), count];
    for (unsigned int i = 0; i < count; i++) {
        objc_property_t p = props[i];
        const char *name = property_getName(p);
        const char *attrs = property_getAttributes(p);
        NSString *attrStr = attrs ? [NSString stringWithUTF8String:attrs] : @"";
        NSString *valueDesc = @"(non-objet, ignoré)";
        if ([attrStr hasPrefix:@"T@"]) {
            @try {
                id value = [obj valueForKey:[NSString stringWithUTF8String:name]];
                if ([value isKindOfClass:[UIFont class]]) {
                    UIFont *f = (UIFont *)value;
                    valueDesc = [NSString stringWithFormat:@"UIFont %@ %.1fpt", f.fontName, f.pointSize];
                } else if ([value isKindOfClass:[NSAttributedString class]]) {
                    NSAttributedString *a = (NSAttributedString *)value;
                    UIFont *f = a.length > 0
                        ? [a attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
                    valueDesc = [NSString stringWithFormat:@"NSAttributedString len=%lu font=%@ %.1fpt",
                        (unsigned long)a.length, f.fontName ?: @"?", f.pointSize];
                } else if (value) {
                    valueDesc = NSStringFromClass([value class]);
                } else {
                    valueDesc = @"nil";
                }
            } @catch (NSException *ex) {
                valueDesc = [NSString stringWithFormat:@"<exception: %@>", ex.reason];
            }
        }
        [mgr log:@"[ChatCustom] 🏗     %s (%@) = %@", name, attrStr, valueDesc];
    }
    free(props);

    // .layer — très souvent, une vue qui dessine son propre contenu (comme
    // ici) le fait via un CALayer custom défini par +layerClass. Zéro risque
    // à lire view.layer (accesseur UIKit standard).
    if ([obj isKindOfClass:[UIView class]]) {
        CALayer *layer = ((UIView *)obj).layer;
        if (layer && ![layer isMemberOfClass:[CALayer class]]) {
            [mgr log:@"[ChatCustom] 🏗   layer réel = %@", NSStringFromClass([layer class])];
            unsigned int lcount = 0;
            objc_property_t *lprops = class_copyPropertyList([layer class], &lcount);
            [mgr log:@"[ChatCustom] 🏗   ── Propriétés layer (%@) — %u propriétés ──",
                NSStringFromClass([layer class]), lcount];
            for (unsigned int i = 0; i < lcount; i++) {
                const char *name = property_getName(lprops[i]);
                const char *attrs = property_getAttributes(lprops[i]);
                NSString *attrStr = attrs ? [NSString stringWithUTF8String:attrs] : @"";
                NSString *valueDesc = @"(non-objet, ignoré)";
                if ([attrStr hasPrefix:@"T@"]) {
                    @try {
                        id value = [layer valueForKey:[NSString stringWithUTF8String:name]];
                        if ([value isKindOfClass:[UIFont class]]) {
                            UIFont *f = (UIFont *)value;
                            valueDesc = [NSString stringWithFormat:@"UIFont %@ %.1fpt", f.fontName, f.pointSize];
                        } else if ([value isKindOfClass:[NSAttributedString class]]) {
                            NSAttributedString *a = (NSAttributedString *)value;
                            UIFont *f = a.length > 0
                                ? [a attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
                            valueDesc = [NSString stringWithFormat:@"NSAttributedString len=%lu font=%@ %.1fpt",
                                (unsigned long)a.length, f.fontName ?: @"?", f.pointSize];
                        } else if (value) {
                            valueDesc = NSStringFromClass([value class]);
                        } else {
                            valueDesc = @"nil";
                        }
                    } @catch (NSException *ex) {
                        valueDesc = [NSString stringWithFormat:@"<exception: %@>", ex.reason];
                    }
                }
                [mgr log:@"[ChatCustom] 🏗     %s (%@) = %@", name, attrStr, valueDesc];
            }
            free(lprops);
        }
    }
}

static void s7tv_dumpViewSubtree(UIView *view, NSString *indent, NSInteger maxDepth,
                                  NSInteger *ivarDumpsRemaining) {
    if (maxDepth <= 0) return;
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // Plafonné à 2 dumps d'ivars par appel (pas un par cellule visible) —
    // largement assez pour comparer un message court et un message qui wrap
    // sur plusieurs lignes, sans noyer les logs.
    if ([NSStringFromClass([view class]) isEqualToString:@"Twitch.MessageStringView"] &&
        ivarDumpsRemaining && *ivarDumpsRemaining > 0) {
        (*ivarDumpsRemaining)--;
        s7tv_dumpProperties(view, [NSString stringWithFormat:@"frame=%@", NSStringFromCGRect(view.frame)]);
    }

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        [mgr log:@"[ChatCustom] 🏗 %@UILabel frame=%@ font=%@ %.1fpt texte=\"%@\"",
            indent, NSStringFromCGRect(lbl.frame), lbl.font.fontName,
            lbl.font.pointSize,
            lbl.text.length > 24 ? [lbl.text substringToIndex:24] : (lbl.text ?: @"")];
    } else if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        [mgr log:@"[ChatCustom] 🏗 %@UIImageView frame=%@ imageSize=%@",
            indent, NSStringFromCGRect(iv.frame), NSStringFromCGSize(iv.image.size)];
    } else {
        [mgr log:@"[ChatCustom] 🏗 %@%@ frame=%@",
            indent, NSStringFromClass([view class]), NSStringFromCGRect(view.frame)];
    }

    NSString *childIndent = [indent stringByAppendingString:@"  "];
    for (UIView *sub in view.subviews) {
        s7tv_dumpViewSubtree(sub, childIndent, maxDepth - 1, ivarDumpsRemaining);
    }
}

// Profondeur bornée à 8 : suffisant pour atteindre les UILabel/UIImageView
// d'une cellule sans produire un dump illisible sur une hiérarchie profonde.
// Délai avant appel (voir site d'appel) : au moment de didMoveToWindow, la
// table est généralement encore vide — le temps de laisser au moins une
// cellule de message se peupler avant de descendre l'arbre.
static void s7tv_dumpNativeCellMetrics(UIView *chatView, NSString *reason) {
    // One-shot par lancement d'app — ce dump est un outil de mesure ponctuel
    // (Phase 1b), pas un diagnostic à rejouer en continu. Le laisser se
    // redéclencher à chaque changement de chaîne (chaque didMoveToWindow)
    // ajoute une traversée récursive + des appels valueForKey: à un moment
    // où la vue peut être en cours de démontage (changement rapide de
    // chaîne) — charge et risque inutiles une fois la mesure obtenue.
    static BOOL s_alreadyDumped = NO;
    if (s_alreadyDumped) return;
    s_alreadyDumped = YES;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"[ChatCustom] 🏗 ── Mesure cellule native (%@) ──────────────────", reason];
    NSInteger ivarDumpsRemaining = 2;
    s7tv_dumpViewSubtree(chatView, @"", 8, &ivarDumpsRemaining);
    [mgr log:@"[ChatCustom] 🏗 ── Fin mesure (%@) ──────────────────", reason];
}

// ── Test de validation Phase 0/1c (kill switch : Settings → Débogage) ───────
//
// Cache la VRAIE ChatTranscriptView (superview == UIStackView, alpha=1 sur
// toute la chaîne — voir dump) et insère SevenTVChatCustomView à sa place
// dans le même UIStackView, au même index. Ne touche PAS à l'instance
// fantôme hébergée via Twitch.ChatTranscriptViewRepresentable (pont SwiftUI).
//
// UIStackView retire automatiquement du layout ses arranged subviews dont
// isHidden == YES — donc masquer suffit, pas besoin de la retirer du stack
// (plus sûr : Twitch garde sa référence forte intacte, rien ne casse côté
// état interne si jamais on désactive le test).

static const char kS7TVChatCustomInstalledView = 21;

// Référence faible vers la vue actuellement affichée à l'écran, pour que le
// hook IRC (ci-dessous) puisse la notifier d'un nouveau message sans avoir
// à la retrouver dans la hiérarchie à chaque fois. Une seule vue visible à
// la fois en pratique (normal OU théâtre, jamais les deux en même temps).
static __weak SevenTVChatCustomView *s_activeChatCustomView = nil;
static __weak UIView *s_activeNativeChatView = nil;

// Appelée après un changement qui invalide l'affichage courant (nouveau
// message, changement de chaîne...). No-op silencieux si aucune vue custom
// n'est actuellement montée (kill switch désactivé, ou chat pas encore ouvert).
static void s7tv_reloadActiveChatCustomView(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view reloadMessages];
    });
}

// ── Batching (exigence transverse #3) ────────────────────────────────────────
// Sur une chaîne à fort volume, un reload par message individuel devient
// coûteux (chaque reload retraverse toute la table). On regroupe donc les
// messages arrivés dans une fenêtre de ~150ms en un seul reload, plutôt que
// d'appeler s7tv_reloadActiveChatCustomView() à chaque message. Réservé au
// flux IRC — le changement de chaîne (rare, doit être immédiat) continue
// d'appeler la fonction non-batchée directement.
static BOOL s_chatReloadScheduled = NO;

static void s7tv_scheduleChatCustomReload(void) {
    if (s_chatReloadScheduled) return; // un reload est déjà en attente,
                                        // ce message y sera inclus
    s_chatReloadScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        s_chatReloadScheduled = NO;
        s7tv_reloadActiveChatCustomView();
    });
}

static void s7tv_applyChatCustomTest(UIView *chatView) {
    s_activeNativeChatView = chatView;
    UIStackView *stack = (UIStackView *)chatView.superview;
    if (!stack) return;

    // Déjà appliqué pour cette instance ? (évite un doublon si didMoveToWindow
    // se redéclenche, ex: passage normal ↔ théâtre)
    SevenTVChatCustomView *existing =
        objc_getAssociatedObject(chatView, &kS7TVChatCustomInstalledView);
    if (existing && existing.superview == stack) {
        chatView.hidden = YES;
        existing.hidden = NO;
        s_activeChatCustomView = existing;
        [existing reloadMessages];
        return;
    }

    NSInteger idx = [stack.arrangedSubviews indexOfObject:chatView];
    if (idx == NSNotFound) {
        [[SevenTVManager sharedManager]
            log:@"[ChatCustom] ⚠️ ChatTranscriptView introuvable dans arrangedSubviews"];
        return;
    }

    chatView.hidden = YES;

    SevenTVChatCustomView *customView =
        [[SevenTVChatCustomView alloc] initWithStore:[SevenTVManager sharedManager].chatMessageStore];

    [stack insertArrangedSubview:customView atIndex:idx];
    objc_setAssociatedObject(chatView, &kS7TVChatCustomInstalledView, customView, OBJC_ASSOCIATION_RETAIN);
    s_activeChatCustomView = customView;

    [customView reloadMessages];

    [[SevenTVManager sharedManager]
        log:@"[ChatCustom] 🏗 SevenTVChatCustomView insérée (index %ld du UIStackView, chat réel caché)",
        (long)idx];
}

static void s7tv_applyChatCustomToggle(void) {
    UIView *chatView = s_activeNativeChatView;
    if (!chatView || ![chatView.superview isKindOfClass:[UIStackView class]]) return;

    if ([SevenTVManager sharedManager].chatCustomTestEnabled) {
        s7tv_applyChatCustomTest(chatView);
        return;
    }

    SevenTVChatCustomView *customView =
        objc_getAssociatedObject(chatView, &kS7TVChatCustomInstalledView);
    chatView.hidden = NO;
    customView.hidden = YES;
    if (s_activeChatCustomView == customView) s_activeChatCustomView = nil;
}


// ────────────────────────────────────────────────────────────
// MARK: - Parsing IRC PRIVMSG (Phase 1c/2 — texte + emotes 7TV)
// ────────────────────────────────────────────────────────────
//
// Parsing robuste : tags malformés ou absents → valeurs par défaut, jamais
// de crash (exigence Phase 1a). Tokenisation via SevenTVChatTokenizer
// (Phase 2) — emotes Twitch natives pas encore branchées (point d'extension
// naturel : parser le tag emotes= que Twitch envoie déjà tel quel côté
// serveur, jamais lu pour l'instant).

// Liste ordonnée des fournisseurs d'emotes essayés pour chaque mot du
// message (architecture générique, voir SevenTVEmoteProvider.h). Un seul
// fournisseur pour l'instant (7TV) — l'ajout d'un futur fournisseur
// BTTV/FFZ se ferait uniquement ici, sans toucher au tokenizer.
static NSArray<id<S7TVEmoteProvider>> *s7tv_emoteProviders(void) {
    static NSArray<id<S7TVEmoteProvider>> *providers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        providers = @[ [S7TVSevenTVEmoteProvider new] ];
    });
    return providers;
}

// Extrait la valeur d'un tag IRC donné depuis le dictionnaire de tags déjà
// parsé. Retourne defaultValue (jamais nil) si absent/vide.
static NSString *s7tv_tagValue(NSDictionary<NSString *, NSString *> *tags,
                                NSString *key,
                                NSString *defaultValue) {
    NSString *v = tags[key];
    return v.length ? v : defaultValue;
}

// Parse le bloc de tags IRC "@key1=val1;key2=val2;... " en dictionnaire.
// Tolère les tags sans valeur (key= ou key seul) et les lignes sans tags.
static NSDictionary<NSString *, NSString *> *s7tv_parseIRCTags(NSString *tagBlock) {
    NSMutableDictionary<NSString *, NSString *> *tags = [NSMutableDictionary dictionary];
    if (!tagBlock.length) return tags;

    for (NSString *pair in [tagBlock componentsSeparatedByString:@";"]) {
        if (pair.length == 0) continue;
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            tags[pair] = @""; // tag sans valeur (ex: présence simple)
            continue;
        }
        NSString *key = [pair substringToIndex:eq.location];
        NSString *val = [pair substringFromIndex:eq.location + 1];
        if (key.length) tags[key] = val;
    }
    return tags;
}

// ────────────────────────────────────────────────────────────
// MARK: - Emotes Twitch natives (tag IRC emotes=)
// ────────────────────────────────────────────────────────────
//
// Contrairement à 7TV, Twitch fournit déjà l'ID exact ET la position de
// chaque emote native directement dans le tag IRC — pas de lookup par nom
// nécessaire, juste un splicing du texte autour de ces positions connues.

// Parse "emoteID1:start-end,start-end/emoteID2:start-end..." en liste triée
// par position de départ. Chaque entrée : @[emoteID, @(start), @(end)]
// (end inclusif, comme le format Twitch). Tolère les entrées malformées
// (les ignore silencieusement plutôt que planter — exigence Phase 1a).
static NSArray<NSArray *> *s7tv_parseTwitchEmotesTag(NSString *tagValue) {
    NSMutableArray<NSArray *> *ranges = [NSMutableArray array];
    if (!tagValue.length) return ranges;

    for (NSString *emoteBlock in [tagValue componentsSeparatedByString:@"/"]) {
        NSRange colonRange = [emoteBlock rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;
        NSString *emoteID = [emoteBlock substringToIndex:colonRange.location];
        NSString *positionsStr = [emoteBlock substringFromIndex:colonRange.location + 1];
        if (!emoteID.length) continue;

        for (NSString *pos in [positionsStr componentsSeparatedByString:@","]) {
            NSRange dashRange = [pos rangeOfString:@"-"];
            if (dashRange.location == NSNotFound) continue;
            NSInteger start = [[pos substringToIndex:dashRange.location] integerValue];
            NSInteger end   = [[pos substringFromIndex:dashRange.location + 1] integerValue];
            if (end < start || start < 0) continue;
            [ranges addObject:@[emoteID, @(start), @(end)]];
        }
    }

    [ranges sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [(NSNumber *)a[1] compare:(NSNumber *)b[1]];
    }];
    return ranges;
}

// Tokenise le texte du message en épissant les emotes Twitch natives (position
// exacte connue via le tag) avec le tokenizer 7TV existant (mots, résolution
// par nom) pour tout le texte autour. Chemin le plus fréquent (aucune emote
// native dans le message) : identique à avant, aucun coût supplémentaire.
static NSArray<S7TVChatToken *> *s7tv_tokenizeMessageWithNativeEmotes(NSString *text,
                                                                        NSString *emotesTag) {
    NSArray<NSArray *> *ranges = s7tv_parseTwitchEmotesTag(emotesTag);
    if (ranges.count == 0) {
        return [SevenTVChatTokenizer tokenizeText:text providers:s7tv_emoteProviders()];
    }

    NSMutableArray<S7TVChatToken *> *tokens = [NSMutableArray array];
    NSInteger cursor = 0; // position courante dans text (unités UTF-16, comme NSString)

    for (NSArray *range in ranges) {
        NSString *emoteID = range[0];
        NSInteger start = [(NSNumber *)range[1] integerValue];
        NSInteger end   = [(NSNumber *)range[2] integerValue]; // inclusif

        // Garde-fou : jamais faire confiance à 100% à des positions reçues du
        // réseau (exigence Phase 1a "parsing robuste, jamais de crash").
        if (start < cursor || start >= (NSInteger)text.length || end >= (NSInteger)text.length) {
            continue;
        }

        if (start > cursor) {
            NSString *span = [text substringWithRange:NSMakeRange(cursor, start - cursor)];
            [tokens addObjectsFromArray:
                [SevenTVChatTokenizer tokenizeText:span providers:s7tv_emoteProviders()]];
        }

        NSString *emoteText = [text substringWithRange:NSMakeRange(start, end - start + 1)];
        id<S7TVResolvedEmote> resolved =
            [S7TVTwitchNativeEmoteFactory resolvedEmoteForTwitchEmoteID:emoteID];
        if (resolved) {
            S7TVChatToken *token = [S7TVChatToken emoteToken:emoteText
                                                     provider:S7TVChatTokenTypeEmoteTwitch
                                                      emoteID:emoteID];
            token.resolvedEmote = resolved;
            [tokens addObject:token];
        } else {
            [tokens addObject:[S7TVChatToken textToken:emoteText]];
        }

        cursor = end + 1;
    }

    if (cursor < (NSInteger)text.length) {
        NSString *span = [text substringFromIndex:cursor];
        [tokens addObjectsFromArray:
            [SevenTVChatTokenizer tokenizeText:span providers:s7tv_emoteProviders()]];
    }

    return tokens;
}

// ────────────────────────────────────────────────────────────
// MARK: - Badges (tag IRC badges=)
// ────────────────────────────────────────────────────────────
//
// Format "setID1/version1,setID2/version2,..." — contrairement au tag
// emotes=, pas de position à gérer : c'est déjà exactement la liste
// d'identifiants attendue par SevenTVBadgeProvider.resolvedBadgeForIdentifier:.
// Parsing tolérant (exigence Phase 1a) : entrées vides/malformées ignorées
// silencieusement plutôt que de planter.
static NSArray<NSString *> *s7tv_parseBadgesTag(NSString *tagValue) {
    if (!tagValue.length) return @[];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (NSString *entry in [tagValue componentsSeparatedByString:@","]) {
        if (entry.length && [entry containsString:@"/"]) {
            [identifiers addObject:entry];
        }
    }
    return identifiers;
}

// Parse une ligne IRC complète et retourne un S7TVChatMessage si c'est un
// PRIVMSG exploitable, nil sinon (autre type de commande, ou PRIVMSG dont
// le texte n'a pas pu être isolé — on ne construit jamais de message à
// moitié rempli).
static S7TVChatMessage * _Nullable s7tv_parsePRIVMSG(NSString *ircLine) {
    if (![ircLine containsString:@"PRIVMSG"]) return nil;

    // Bloc de tags : tout ce qui précède le premier espace, s'il commence
    // par '@'. Absent sur certains messages (tags malformés/désactivés
    // côté serveur) — on tolère et on retombe sur des defaults.
    NSDictionary<NSString *, NSString *> *tags = @{};
    NSString *rest = ircLine;
    if ([ircLine hasPrefix:@"@"]) {
        NSRange firstSpace = [ircLine rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            NSString *tagBlock = [ircLine substringWithRange:
                NSMakeRange(1, firstSpace.location - 1)];
            tags = s7tv_parseIRCTags(tagBlock);
            rest = [ircLine substringFromIndex:firstSpace.location + 1];
        }
    }

    // Le texte du message suit toujours " :" après "PRIVMSG #channel" —
    // on cherche la PREMIÈRE occurrence de " :" après "PRIVMSG" précisément
    // pour ne pas confondre avec un ':' qui apparaîtrait dans le pseudo
    // (":nick!user@host") plus tôt dans la ligne.
    NSRange privmsgRange = [rest rangeOfString:@"PRIVMSG"];
    if (privmsgRange.location == NSNotFound) return nil;

    NSRange searchRange = NSMakeRange(privmsgRange.location,
                                       rest.length - privmsgRange.location);
    NSRange textMarker = [rest rangeOfString:@" :" options:0 range:searchRange];
    if (textMarker.location == NSNotFound) return nil; // pas de texte exploitable

    // Fix mélange de chaînes au changement de channel : le WebSocket IRC
    // peut continuer à livrer des PRIVMSG de l'ANCIENNE chaîne juste après
    // un switch (chevauchement JOIN/PART sur le même socket, reconnexion,
    // etc.) — sans ce filtre, s7tv_parsePRIVMSG les acceptait tous sans
    // distinction et le store se retrouvait avec un mélange des deux
    // chaînes, même après le reset fait au ROOMSTATE (voir
    // s7tv_handleRoomState) puisque de nouveaux messages de l'ancienne
    // chaîne continuaient d'arriver ENSUITE. Le nom de chaîne ("#xxx") est
    // toujours présent entre "PRIVMSG " et " :" — on l'extrait et on
    // compare à la chaîne actuellement affichée (mgr.currentChannelName,
    // déjà à jour de façon synchrone dès l'envoi de "JOIN #channel", voir
    // s7tv_sendMessage:completionHandler: plus bas). Si ça ne correspond
    // pas → message ignoré, jamais construit ni ajouté au store. Si
    // currentChannelName n'est pas encore connu (tout premier message avant
    // le tout premier JOIN observé), on laisse passer par sécurité plutôt
    // que de risquer de perdre le tout début de l'historique.
    NSUInteger channelTokenStart = privmsgRange.location + privmsgRange.length + 1; // +1 = espace après "PRIVMSG"
    if (channelTokenStart <= textMarker.location) {
        NSString *channelToken = [rest substringWithRange:
            NSMakeRange(channelTokenStart, textMarker.location - channelTokenStart)];
        channelToken = [channelToken stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([channelToken hasPrefix:@"#"]) {
            channelToken = [channelToken substringFromIndex:1];
        }
        NSString *activeChannel = [SevenTVManager sharedManager].currentChannelName;
        if (channelToken.length && activeChannel.length &&
            [channelToken caseInsensitiveCompare:activeChannel] != NSOrderedSame) {
            return nil; // message d'une autre chaîne — jamais ajouté au store
        }
    }

    NSString *messageText = [rest substringFromIndex:textMarker.location + 2];
    if (!messageText.length) return nil;

    NSString *messageID    = s7tv_tagValue(tags, @"id", [[NSUUID UUID] UUIDString]);
    NSString *userID       = s7tv_tagValue(tags, @"user-id", @"");
    NSString *displayName  = s7tv_tagValue(tags, @"display-name", @"???");
    NSString *colorHex     = s7tv_tagValue(tags, @"color", @"");
    NSString *emotesTag    = s7tv_tagValue(tags, @"emotes", @"");
    NSString *badgesTag    = s7tv_tagValue(tags, @"badges", @"");

    S7TVChatMessage *msg = [[S7TVChatMessage alloc] initWithMessageID:messageID
                                                             timestamp:[NSDate date]
                                                          authorUserID:userID
                                                     authorDisplayName:displayName
                                                               rawText:messageText];
    if (colorHex.length >= 7) {
        // Format "#RRGGBB" — parsing tolérant : couleur nil (fallback blanc
        // côté rendu) si le hex ne parse pas plutôt que crasher.
        unsigned int rgb = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[colorHex substringFromIndex:1]];
        if ([scanner scanHexInt:&rgb]) {
            msg.authorColor = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                               green:((rgb >> 8)  & 0xFF) / 255.0
                                                blue:(rgb         & 0xFF) / 255.0
                                               alpha:1.0];
        }
    }

    // Tokenisation à la construction, pas au rendu (Phase 2) : chaque emote
    // du message (7TV comme Twitch native) a déjà ses dimensions connues
    // avant même le premier passage dans la table — c'est ce qui permet de
    // réserver l'espace exact dès le départ côté renderer, sans jamais avoir
    // à resize après coup une fois l'image chargée.
    msg.tokens = s7tv_tokenizeMessageWithNativeEmotes(messageText, emotesTag);
    msg.twitchEmotesTag = emotesTag;
    msg.badgeIdentifiers = s7tv_parseBadgesTag(badgesTag);

    return msg;
}


// ────────────────────────────────────────────────────────────
// MARK: - Hijack du bouton Bits → bouton 7TV (+ diagnostic Phase 0 chat)
// ────────────────────────────────────────────────────────────

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    NSString *selfClass = NSStringFromClass([self class]);

    // ── Hijack bouton Share → verrou orientation ──────────────────────────────
    if ([selfClass isEqualToString:@"Twitch.TheaterPlayerControlsView"] && self.window) {
        if (!objc_getAssociatedObject(self, &kS7TVShareHijacked)) {
            __weak UIView *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *controls = weakSelf;
                if (!controls || !controls.window) return;

                // Guard : uniquement dans la PictureInPictureWindow (player theater)
                if (![NSStringFromClass([controls.window class])
                        isEqualToString:@"Twitch.PictureInPictureWindow"]) return;

                // Flag posé ICI, après le guard — pas avant
                if (objc_getAssociatedObject(controls, &kS7TVShareHijacked)) return;
                objc_setAssociatedObject(controls, &kS7TVShareHijacked, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                // Trouver le bouton Share par accID
                UIButton *shareBtn = nil;
                NSMutableArray *q = [NSMutableArray arrayWithObject:controls];
                while (q.count > 0) {
                    UIView *v = q[0]; [q removeObjectAtIndex:0];
                    if ([v isKindOfClass:[UIButton class]] &&
                        [[v accessibilityIdentifier] isEqualToString:@"share_button"]) {
                        shareBtn = (UIButton *)v;
                        break;
                    }
                    [q addObjectsFromArray:v.subviews];
                }
                if (!shareBtn) {
                    [[SevenTVManager sharedManager]
                        log:@"⚠️ share_button introuvable dans TheaterPlayerControlsView"];
                    return;
                }

                // Retirer shareButtonTapped original
                NSSet *targets = [shareBtn allTargets];
                for (id tgt in [targets allObjects]) {
                    NSArray *actions = [shareBtn actionsForTarget:tgt
                                            forControlEvent:UIControlEventTouchUpInside];
                    for (NSString *action in actions) {
                        [shareBtn removeTarget:tgt action:NSSelectorFromString(action)
                              forControlEvents:UIControlEventTouchUpInside];
                        [[SevenTVManager sharedManager]
                            log:@"🔌 Share: action retirée — %@->%@",
                            NSStringFromClass([tgt class]), action];
                    }
                }

                // Icône cadenas
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                    configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
                NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
                UIImage *lockIcon = [UIImage systemImageNamed:sym withConfiguration:cfg];

                for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                                        @(UIControlStateSelected), @(UIControlStateDisabled)]) {
                    [shareBtn setImage:lockIcon forState:st.unsignedIntegerValue];
                }
                shareBtn.tintColor              = s_orientationLocked
                    ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
                    : [UIColor whiteColor];
                shareBtn.accessibilityLabel      = s_orientationLocked
                    ? L(@"a11y_unlock_orientation") : L(@"a11y_lock_orientation");
                shareBtn.accessibilityIdentifier = @"s7tv_lock_button";

                [shareBtn addTarget:[SevenTVManager sharedManager]
                             action:@selector(s7tv_toggleOrientationLock:)
                   forControlEvents:UIControlEventTouchUpInside];

                [[SevenTVManager sharedManager]
                    log:@"✅ Bouton Share hijacké → verrou orientation"];
            });
        }
    }

    // ── Diagnostic Phase 0 : dump hiérarchie ChatTranscriptView ──────────────
    // Lecture seule. Se redéclenche à chaque fois que la vue change de fenêtre
    // (donc typiquement aussi lors d'un passage en PiP, où Twitch déplace ses
    // vues vers Twitch.PictureInPictureWindow) — permet de comparer les 3
    // contextes (normal/théâtre/PiP) directement depuis les logs in-app.
    if ([selfClass isEqualToString:@"Twitch.ChatTranscriptView"] && self.window) {
        s7tv_dumpChatHierarchy(self, @"didMoveToWindow");

        // Test de validation Phase 0 — gardé par le kill switch des Settings.
        // Ne cible QUE l'instance réelle (superview == UIStackView, alpha=1
        // sur toute la chaîne) — pas l'instance fantôme du pont SwiftUI
        // (Twitch.ChatTranscriptViewRepresentable), qu'on laisse intacte.
        if ([self.superview isKindOfClass:[UIStackView class]]) {
            s_activeNativeChatView = self;
            s7tv_applyChatCustomToggle();

            // Mesure Phase 1b — délai 1s pour laisser au moins une cellule de
            // message se peupler avant de descendre l'arbre des subviews.
            __weak UIView *weakChatView = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *chatView = weakChatView;
                if (chatView && chatView.window) {
                    s7tv_dumpNativeCellMetrics(chatView, @"didMoveToWindow+1s");
                }
            });
        }
    }

    // ── Détection fermeture du stream ────────────────────────────────────────
    // Quand Twitch ferme le stream, ChatInputView quitte la fenêtre (window → nil).
    // On nettoie le picker AVANT que UIKit ne touche au responder chain.
    if ([selfClass isEqualToString:@"Twitch.ChatInputView"] && !self.window) {
        // Vérifie qu'on avait bien initialisé cette vue (associated object marqueur)
        if (objc_getAssociatedObject(self, &kS7TVTextFieldTagged)) {
            [[SevenTVManager sharedManager] cleanupPickerForStreamClose];
            // Reset le marqueur pour permettre une ré-initialisation au prochain stream
            objc_setAssociatedObject(self, &kS7TVTextFieldTagged, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    // (Ancien hack "_areEmoteAnimationsEnabled" via écriture mémoire brute
    //  supprimé : c'était la cause du crash swift_release / UITableView dealloc
    //  à la fermeture du stream — et la feature ne fonctionnait pas anyway.)

    // ── Hijack du bouton Bits → bouton 7TV ───────────────────────────────────
    if (![selfClass isEqualToString:@"Twitch.ChatInputView"]) return;
    UIView *chatInputView = self;

    if (objc_getAssociatedObject(chatInputView, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(chatInputView, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakChatInputView = chatInputView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *chatInputView = weakChatInputView;
        if (!chatInputView) return;
        SevenTVManager *mgr = [SevenTVManager sharedManager];

        __block UIButton *bitsBtn     = nil;
        __block UIView   *emoticonBtn = nil;
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithArray:chatInputView.subviews];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass([v class]);
            if ([cn containsString:@"BitsButton"] || [cn containsString:@"bitsButton"] ||
                [[v accessibilityIdentifier] isEqualToString:@"chat_input_bits_button"]) {
                bitsBtn = (UIButton *)v;
            }
            if ([cn containsString:@"Emoticon"] || [cn containsString:@"emoticon"]) {
                emoticonBtn = v;
            }
            if (bitsBtn && emoticonBtn) break;
        }

        // CAS A : Bouton Bits trouvé → HIJACK
        if (bitsBtn && ![objc_getAssociatedObject(bitsBtn, &kS7TVBitsHijacked) boolValue]) {

            objc_setAssociatedObject(bitsBtn, &kS7TVBitsHijacked, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            NSSet *targets = [bitsBtn allTargets];
            for (id tgt in targets) {
                NSArray *actions = [bitsBtn actionsForTarget:tgt
                                            forControlEvent:UIControlEventTouchUpInside];
                for (NSString *action in actions) {
                    [bitsBtn removeTarget:tgt
                                   action:NSSelectorFromString(action)
                         forControlEvents:UIControlEventTouchUpInside];
                    [mgr log:@"🔌 Bits: action retirée — %@->%@",
                     NSStringFromClass([tgt class]), action];
                }
            }

            NSData *logoData = [[NSData alloc]
                initWithBase64EncodedString:kS7TVLogoBase64
                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *icon7tv = [UIImage imageWithData:logoData scale:2.0];

            if (icon7tv) {
                CGFloat targetH = emoticonBtn
                    ? MIN(emoticonBtn.bounds.size.height, emoticonBtn.bounds.size.width) * 0.75
                    : 22.0;
                if (targetH < 14) targetH = 22.0;
                CGFloat targetW = targetH * (icon7tv.size.width / MAX(icon7tv.size.height, 1.0));
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(targetW, targetH), NO, [UIScreen mainScreen].scale);
                [icon7tv drawInRect:CGRectMake(0, 0, targetW, targetH)];
                UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (resizedIcon) icon7tv = resizedIcon;

                for (NSNumber *stateNum in @[@(UIControlStateNormal),
                                             @(UIControlStateHighlighted),
                                             @(UIControlStateSelected),
                                             @(UIControlStateDisabled)]) {
                    [bitsBtn setImage:icon7tv forState:stateNum.unsignedIntegerValue];
                }
                bitsBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
                bitsBtn.tintColor = [UIColor whiteColor];
            }

            bitsBtn.accessibilityLabel = @"7TV Emotes";

            // Weak ref pour éviter le retain cycle :
            // bitsBtn (subview) retenait chatInputView (superview) → fuite mémoire.
            objc_setAssociatedObject(bitsBtn, &kS7TVTextFieldTagged,
                                     [S7TVWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [bitsBtn addTarget:mgr
                        action:@selector(s7tv_emoteButtonTappedForButton:)
              forControlEvents:UIControlEventTouchUpInside];

            [mgr log:@"✅ Bouton Bits hijacké → 7TV (frame=%.0f,%.0f,%.0f,%.0f)",
             bitsBtn.frame.origin.x, bitsBtn.frame.origin.y,
             bitsBtn.frame.size.width, bitsBtn.frame.size.height];

        // CAS B : Pas de bouton Bits → Fallback
        } else if (!bitsBtn) {

            [mgr log:@"⚠️ ChatInputViewBitsButton introuvable — fallback injection"];

            UIView *target = emoticonBtn.superview ?: chatInputView;

            for (UIView *sub in target.subviews) {
                if (sub.tag == 0x7777) return;
            }

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = 0x7777;

            UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
                configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
            UIImage *icon = [UIImage systemImageNamed:@"sparkles" withConfiguration:symCfg];
            UIColor *purple = [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0];

            if (icon) {
                [btn setImage:icon forState:UIControlStateNormal];
                btn.tintColor = purple;
            } else {
                [btn setTitle:L(@"label_7tv_badge") forState:UIControlStateNormal];
                [btn setTitleColor:purple forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
            }

            CGFloat btnSize = 36.0;
            CGFloat btnX = emoticonBtn
                ? (emoticonBtn.frame.origin.x - btnSize - 4.0)
                : MAX(0, target.frame.size.width - btnSize - 4.0);
            CGFloat btnY = emoticonBtn
                ? (emoticonBtn.frame.origin.y + (emoticonBtn.frame.size.height - btnSize) / 2.0)
                : (target.frame.size.height - btnSize) / 2.0;
            if (btnX < 0) btnX = 0;

            btn.frame = CGRectMake(btnX, btnY, btnSize, btnSize);
            btn.autoresizingMask = UIViewAutoresizingFlexibleRightMargin
                                 | UIViewAutoresizingFlexibleTopMargin
                                 | UIViewAutoresizingFlexibleBottomMargin;

            // Weak ref pour éviter le retain cycle bouton → chatInputView.
            objc_setAssociatedObject(btn, &kS7TVTextFieldTagged,
                                     [S7TVWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [btn addTarget:mgr
                    action:@selector(s7tv_emoteButtonTappedForButton:)
          forControlEvents:UIControlEventTouchUpInside];

            [target addSubview:btn];
            [target bringSubviewToFront:btn];

            [mgr log:@"🎹 Bouton 7TV fallback injecté — x=%.0f y=%.0f", btnX, btnY];

        } else {
            [mgr log:@"ℹ️ Bouton Bits déjà hijacké, rien à faire"];
        }
    });
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Catégorie SevenTVManager pour le tap du bouton barre
// ────────────────────────────────────────────────────────────

@interface SevenTVManager (ChatBarButton)
- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender;
@end

@implementation SevenTVManager (ChatBarButton)

- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender {
    id assoc = objc_getAssociatedObject(sender, &kS7TVTextFieldTagged);
    UIView *chatInputView = nil;
    // Support S7TVWeakRef (nouveau) et UIView direct (legacy/compatibilité)
    if ([assoc isKindOfClass:[S7TVWeakRef class]]) {
        chatInputView = ((S7TVWeakRef *)assoc).object;
    } else {
        chatInputView = assoc;
    }
    if (!chatInputView || !chatInputView.window) return;
    [self toggleEmotePickerForChatInputView:chatInputView];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSession (SevenTV)
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
// Variante SANS completion handler — c'est celle-ci qu'utilise Apollo en
// interne pour ses requêtes delegate-based (voir plus bas, hook
// Apollo.URLSessionClient). On ne peut voir le corps de la requête SORTANTE
// (donc confirmer qu'une ClaimChannelPointsMutation part bien) qu'ici —
// didReceiveData:/didCompleteWithError: ne donnent que la réponse.
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request;
@end

@implementation NSURLSession (SevenTV)

- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request {
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && request.HTTPBody) {
        NSString *bodyStr = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if ([bodyStr containsString:@"ClaimCommunityPoints"] || [bodyStr containsString:@"claimCommunityPoints"]) {
            [[SevenTVManager sharedManager]
                log:@"🎁 Channel Points debug: requête ClaimChannelPointsMutation envoyée — corps :\n%@", bodyStr];
        }
    }
    return [self s7tv_dataTaskWithRequest:request];
}

- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        // Capture de secours : si les headers Authorization/Client-ID sont
        // posés directement sur l'objet request (plutôt que via
        // setValue:/setAllHTTPHeaderFields:/setHTTPAdditionalHeaders:, déjà
        // captés en amont), on les récupère quand même ici.
        NSDictionary *headers = request.allHTTPHeaderFields;
        NSString *auth = headers[@"Authorization"];
        NSString *clientID = headers[@"Client-ID"];
        if (auth.length && clientID.length) {
            [[SevenTVManager sharedManager] saveTwitchToken:auth clientID:clientID];
        }
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                    s7tv_scanGQLResponseForChannelPointsClaim(data);
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithRequest:request completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([url.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                    s7tv_scanGQLResponseForChannelPointsClaim(data);
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithURL:url completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithURL:url completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook Apollo.URLSessionClient (GraphQL réel, delegate-based)
// ────────────────────────────────────────────────────────────
//
// DÉCOUVERTE : le swizzle ci-dessus sur -[NSURLSession dataTaskWithRequest:
// completionHandler:]/dataTaskWithURL:completionHandler: ne voit JAMAIS les
// requêtes GraphQL réelles de Twitch (ChannelPointsQuery incluse) — confirmé
// par des dizaines de ticks de logs sans le moindre "availableClaim", même
// avec un coffre déjà présent à l'arrivée sur la chaîne.
//
// Raison confirmée dans le binaire (pas une hypothèse) :
//   @rpath/TwitchApollo.framework/TwitchApollo
//   Apollo.URLSessionClient                          (classe réelle)
//   TwitchKit.TKGraphQL.urlSessionClient              (Twitch s'en sert)
//   URLSession:dataTask:didReceiveData:                (sélecteur réel)
//   urlSession(_:task:didCompleteWithError:)           (signature réelle)
//
// Twitch embarque son propre framework Apollo (le client GraphQL open-source
// standard), et Apollo-iOS pilote ses requêtes via l'API DELEGATE de
// NSURLSession (-URLSession:dataTask:didReceiveData:, -URLSession:task:
// didCompleteWithError:), pas l'API à completion handler qu'on avait
// swizzlée. C'est un mécanisme de requête entièrement différent, invisible
// à l'ancien hook — pas un problème de format JSON, de timing, ou de nom de
// champ. On corrige en swizzlant directement les méthodes délégué
// d'Apollo.URLSessionClient : didReceiveData: peut être appelé plusieurs
// fois par tâche (réponse en chunks), donc on accumule par
// taskIdentifier, puis on traite le corps complet une fois assemblé à
// didCompleteWithError: (si error == nil).

static NSMutableDictionary<NSNumber *, NSMutableData *> *s7tv_apolloBuffers(void) {
    static NSMutableDictionary *buffers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ buffers = [NSMutableDictionary dictionary]; });
    return buffers;
}

@interface NSObject (SevenTVApolloDelegate)
- (void)s7tv_apolloURLSession:(NSURLSession *)session
                      dataTask:(NSURLSessionDataTask *)dataTask
                didReceiveData:(NSData *)data;
- (void)s7tv_apolloURLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
          didCompleteWithError:(NSError *)error;
@end

@implementation NSObject (SevenTVApolloDelegate)

- (void)s7tv_apolloURLSession:(NSURLSession *)session
                      dataTask:(NSURLSessionDataTask *)dataTask
                didReceiveData:(NSData *)data {
    NSString *host = dataTask.currentRequest.URL.host ?: dataTask.originalRequest.URL.host;
    if ([host isEqualToString:@"gql.twitch.tv"]) {
        @synchronized (s7tv_apolloBuffers()) {
            NSNumber *key = @(dataTask.taskIdentifier);
            NSMutableData *buf = s7tv_apolloBuffers()[key];
            if (!buf) {
                buf = [NSMutableData data];
                s7tv_apolloBuffers()[key] = buf;
            }
            [buf appendData:data];
        }
    }
    // Appelle l'implémentation originale (échangée par le swizzle) —
    // indispensable pour qu'Apollo reçoive bien ses propres données.
    [self s7tv_apolloURLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)s7tv_apolloURLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
          didCompleteWithError:(NSError *)error {
    NSNumber *key = @(task.taskIdentifier);
    NSData *fullData = nil;
    @synchronized (s7tv_apolloBuffers()) {
        fullData = [s7tv_apolloBuffers()[key] copy];
        [s7tv_apolloBuffers() removeObjectForKey:key];
    }

    if (fullData.length > 0 && !error) {
        NSString *host = task.currentRequest.URL.host ?: task.originalRequest.URL.host;
        if ([host isEqualToString:@"gql.twitch.tv"]) {
            [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:fullData];
            s7tv_scanGQLResponseForChannelPointsClaim(fullData);

            // Preuve directe du résultat serveur de la mutation de claim —
            // permet de voir un éventuel champ "error" renvoyé par Twitch
            // (ex: coffre déjà expiré, déjà réclamé...) plutôt que de
            // déduire l'échec indirectement.
            // Preuve directe du résultat serveur de la mutation de claim —
            // c'est la source d'arrêt de la boucle de retry : dès que
            // Twitch confirme un succès (claim.id + error:null), on efface
            // pendingClaimID nous-mêmes. On ne peut pas compter sur un
            // futur ChannelPointsQuery pour le faire : rien ne garantit
            // que Twitch le rejoue juste après une mutation réussie (vu en
            // conditions réelles : sans ce correctif, retry en boucle
            // indéfiniment après un succès confirmé).
            static NSData *s_claimNeedle = nil;
            static dispatch_once_t claimOnce;
            dispatch_once(&claimOnce, ^{
                s_claimNeedle = [@"claimCommunityPoints" dataUsingEncoding:NSUTF8StringEncoding];
            });
            if ([fullData rangeOfData:s_claimNeedle options:0 range:NSMakeRange(0, fullData.length)].location != NSNotFound) {
                NSError *jsonErr = nil;
                id json = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:&jsonErr];
                BOOL found = NO;
                id payload = (!jsonErr && json)
                    ? s7tv_findValueForKeyRecursive(json, @"claimCommunityPoints", &found)
                    : nil;

                if (found && [payload isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *payloadDict = payload;
                    id claimObj = payloadDict[@"claim"];
                    id errorObj = payloadDict[@"error"];
                    BOOL success = [claimObj isKindOfClass:[NSDictionary class]]
                        && (!errorObj || [errorObj isKindOfClass:[NSNull class]]);

                    if (success) {
                        NSString *confirmedID = [(NSDictionary *)claimObj objectForKey:@"id"];
                        NSNumber *pointsEarned = [(NSDictionary *)claimObj objectForKey:@"pointsEarnedTotal"];
                        s7tv_setPendingChannelPointsClaimID(nil); // stoppe le retry — succès confirmé
                        [[SevenTVManager sharedManager]
                            log:@"🎁 Channel Points: coffre confirmé collecté par Twitch (id=%@, +%@ points)",
                            confirmedID, pointsEarned];
                    } else {
                        // Échec confirmé côté serveur (ex: integrity check) — on NE
                        // touche PAS pendingClaimID, le cooldown fera réessayer.
                        [[SevenTVManager sharedManager]
                            log:@"🎁 Channel Points debug: mutation refusée par Twitch, nouvel essai dans %.0fs — %@",
                            kS7TVClaimRetryCooldown, payloadDict];
                    }
                } else if (found && (!payload || [payload isKindOfClass:[NSNull class]])) {
                    // "data":{"claimCommunityPoints":null} — cas du
                    // IntegrityCheckFailed observé : la mutation entière a
                    // échoué avant même de produire un payload. On laisse
                    // le retry cooldown reprendre la main.
                    [[SevenTVManager sharedManager]
                        log:@"🎁 Channel Points debug: mutation rejetée par Twitch (claimCommunityPoints=null), nouvel essai dans %.0fs",
                        kS7TVClaimRetryCooldown];
                }
            }
        }
    } else if (error) {
        NSString *host = task.currentRequest.URL.host ?: task.originalRequest.URL.host;
        if ([host isEqualToString:@"gql.twitch.tv"]) {
            [[SevenTVManager sharedManager]
                log:@"🎁 Channel Points debug: requête gql.twitch.tv terminée en erreur réseau : %@", error];
        }
    }

    [self s7tv_apolloURLSession:session task:task didCompleteWithError:error];
}

@end

// Swizzle direct sur Apollo.URLSessionClient — classe concrète connue par
// son nom exact (confirmé dans le binaire), pas besoin de sonder une
// instance comme pour NSURLSessionWebSocketTask (qui est un vrai cluster
// de classes abstrait ; Apollo.URLSessionClient est une classe concrète
// normale, instanciée directement par Apollo).
static void s7tv_swizzle_apollo_gql(void) {
    Class apolloClass = NSClassFromString(@"Apollo.URLSessionClient");
    if (!apolloClass) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ Channel Points: Apollo.URLSessionClient introuvable — hook GQL delegate non posé"];
        return;
    }

    s7tv_swizzle(apolloClass, [NSObject class],
                 @selector(URLSession:dataTask:didReceiveData:),
                 @selector(s7tv_apolloURLSession:dataTask:didReceiveData:));
    s7tv_swizzle(apolloClass, [NSObject class],
                 @selector(URLSession:task:didCompleteWithError:),
                 @selector(s7tv_apolloURLSession:task:didCompleteWithError:));
}


// ────────────────────────────────────────────────────────────
// MARK: - Fix A: Extraction room-id depuis ROOMSTATE
// ────────────────────────────────────────────────────────────

static void s7tv_handleRoomState(NSString *ircMessage) {
    NSRange roomIDRange = [ircMessage rangeOfString:@"room-id="];
    if (roomIDRange.location == NSNotFound) return;

    NSString *afterRoomID = [ircMessage substringFromIndex:roomIDRange.location + 8];
    NSMutableString *roomID = [NSMutableString string];
    for (NSUInteger i = 0; i < afterRoomID.length; i++) {
        unichar c = [afterRoomID characterAtIndex:i];
        if (c == ';' || c == ' ' || c == '\r' || c == '\n') break;
        [roomID appendFormat:@"%C", c];
    }
    if (roomID.length == 0) return;

    [[SevenTVManager sharedManager] log:@"📡 room-id extrait depuis ROOMSTATE: %@", roomID];
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    if (![roomID isEqualToString:mgr.currentChannelTwitchID]) {
        [[SevenTVManager sharedManager]
            log:@"📡 Nouveau broadcaster ID (ROOMSTATE): %@ (ancien: %@)",
            roomID, mgr.currentChannelTwitchID ?: @"aucun"];
        mgr.currentChannelTwitchID = roomID;

        // Changement de chaîne détecté → vider le store pour éviter qu'un
        // message de l'ancienne chaîne fuite dans la nouvelle (exigence
        // Phase 0 : nettoyage au changement rapide de chaîne).
        [mgr.chatMessageStore removeAllMessages];
        [[SevenTVManager sharedManager] log:@"[ChatCustom] 🏗 Store de messages vidé (changement de chaîne)"];
        s7tv_reloadActiveChatCustomView();

        if (mgr.currentChannelName.length > 0) {
            NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
            NSMutableDictionary *map =
                [([prefs dictionaryForKey:@"s7tv_channel_id_map"] ?: @{}) mutableCopy];
            map[mgr.currentChannelName.lowercaseString] = roomID;
            [prefs setObject:[map copy] forKey:@"s7tv_channel_id_map"];
            [prefs synchronize];
            [[SevenTVManager sharedManager] log:@"💾 Mapping sauvé: %@ → %@",
             mgr.currentChannelName, roomID];
        }
        [mgr loadEmotesForChannelTwitchID:roomID];

        // Notifier pour charger les badges channel-specific (abonné, bits, etc.)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"S7TVChannelJoined"
                          object:nil
                        userInfo:@{@"channelID": roomID}];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSessionWebSocketTask (chat IRC Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSessionWebSocketTask (SevenTV)
- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler;
- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler;
@end

@implementation NSURLSessionWebSocketTask (SevenTV)

- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler {

    void (^wrappedHandler)(NSURLSessionWebSocketMessage *, NSError *) =
        ^(NSURLSessionWebSocketMessage *message, NSError *error) {

            if (!error && message) {
                NSString *textToProcess = nil;
                if (message.type == NSURLSessionWebSocketMessageTypeString) {
                    textToProcess = message.string;
                } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
                    textToProcess = [[NSString alloc] initWithData:message.data
                                                          encoding:NSUTF8StringEncoding];
                }

                if (textToProcess) {
                    BOOL addedMessage = NO;
                    NSArray<NSString *> *ircLines = [textToProcess
                        componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    for (NSString *rawLine in ircLines) {
                        NSString *ircLine = [rawLine stringByTrimmingCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]];
                        if (!ircLine.length) continue;
                        if ([ircLine containsString:@"ROOMSTATE"]) {
                            s7tv_handleRoomState(ircLine);
                        }

                        S7TVChatMessage *chatMsg = s7tv_parsePRIVMSG(ircLine);
                        if (!chatMsg) continue;
                        [[SevenTVManager sharedManager].chatMessageStore addMessage:chatMsg];
                        addedMessage = YES;
                    }
                    if (addedMessage) s7tv_scheduleChatCustomReload();
                }
            }
            completionHandler(message, error);
        };

    [self s7tv_receiveMessageWithCompletionHandler:wrappedHandler];
}

- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler {

    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        NSString *text = message.string;
        if ([text hasPrefix:@"JOIN #"]) {
            NSString *channel = [[text substringFromIndex:6]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [[SevenTVManager sharedManager] log:@"📺 Rejoint le channel: %@", channel];
            [[SevenTVManager sharedManager] loadEmotesForChannelName:channel];
        }
    }
    [self s7tv_sendMessage:message completionHandler:completionHandler];
}

@end



// ────────────────────────────────────────────────────────────
// MARK: - AccountMenuViewController — injection section 7TV
// ────────────────────────────────────────────────────────────

static NSInteger s7tv_imp_numberOfSections(id self, SEL _cmd, UITableView *tv) {
    SEL origSel = NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:");
    NSInteger (*origIMP)(id, SEL, UITableView *) =
        (NSInteger (*)(id, SEL, UITableView *))
        [self methodForSelector:origSel];
    NSInteger orig = origIMP(self, origSel, tv);
    objc_setAssociatedObject(self, &kS7TVOrigSectionCount,
                             @(orig), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return orig + 1;
}

static NSInteger s7tv_origSection(NSInteger displayedSection) {
    return displayedSection - 1;
}

static NSInteger s7tv_imp_numberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return 1;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:");
    NSInteger (*origIMP)(id, SEL, UITableView *, NSInteger) =
        (NSInteger (*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static NSString *s7tv_imp_titleForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return nil;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:");
    NSString *(*origIMP)(id, SEL, UITableView *, NSInteger) =
        (NSString *(*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static UIView *s7tv_imp_viewForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section != 0) {
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:");
        UIView *(*origIMP)(id, SEL, UITableView *, NSInteger) =
            (UIView *(*)(id, SEL, UITableView *, NSInteger))
            [self methodForSelector:origSel];
        return origIMP(self, origSel, tv, s7tv_origSection(section));
    }

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImageView *logoView = [[UIImageView alloc] init];
    if (logoData) logoView.image = [UIImage imageWithData:logoData scale:2.0];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:logoView];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(@"header_7tv_settings_caps");
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor secondaryLabelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [logoView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [logoView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [logoView.widthAnchor constraintEqualToConstant:26],
        [logoView.heightAnchor constraintEqualToConstant:19],
        [lbl.leadingAnchor constraintEqualToAnchor:logoView.trailingAnchor constant:6],
        [lbl.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    return container;
}

static CGFloat s7tv_imp_heightForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return 38.0;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:");
    CGFloat (*origIMP)(id, SEL, UITableView *, NSInteger) =
        (CGFloat (*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static UITableViewCell *s7tv_imp_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section != 0) {
        NSIndexPath *origIP = [NSIndexPath indexPathForRow:ip.row
                                                 inSection:s7tv_origSection(ip.section)];
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:");
        UITableViewCell *(*origIMP)(id, SEL, UITableView *, NSIndexPath *) =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
            [self methodForSelector:origSel];
        return origIMP(self, origSel, tv, origIP);
    }

    static NSString *rID = @"S7TVSettingsCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rID];
    if (!cell) {
        Class disclosureClass = NSClassFromString(@"Twitch.SettingsDisclosureCell")
                              ?: NSClassFromString(@"_TtC6Twitch22SettingsDisclosureCell");
        if (disclosureClass) {
            cell = [[disclosureClass alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rID];
        }
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rID];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    cell.textLabel.text = L(@"title_7tv_settings");
    cell.textLabel.numberOfLines = 0;

    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (logoData) {
        UIImage *logo = [UIImage imageWithData:logoData scale:2.0];
        if (logo) cell.imageView.image = logo;
    }

    return cell;
}

static void s7tv_imp_didSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section != 0) {
        NSIndexPath *origIP = [NSIndexPath indexPathForRow:ip.row
                                                 inSection:s7tv_origSection(ip.section)];
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:");
        void (*origIMP)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))
            [self methodForSelector:origSel];
        origIMP(self, origSel, tv, origIP);
        return;
    }

    [tv deselectRowAtIndexPath:ip animated:YES];
    SevenTVSettingsController *vc = [[SevenTVSettingsController alloc] init];
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    [nav pushViewController:vc animated:YES];
    [[SevenTVManager sharedManager] log:@"✅ 7TV Settings ouvert depuis les paramètres Twitch"];
}

static void s7tv_swizzle_account_menu(void) {
    Class target = NSClassFromString(@"_TtC6Twitch25AccountMenuViewController");
    if (!target) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ _TtC6Twitch25AccountMenuViewController introuvable — swizzle ignoré"];
        return;
    }

    void (^swizzleWithIMP)(SEL, SEL, IMP, const char *) =
        ^(SEL origSel, SEL newSel, IMP newIMP, const char *types) {
            Method origMethod = class_getInstanceMethod(target, origSel);
            if (!origMethod) return;
            // CRITICAL FIX: if the method is only *inherited* (not defined directly on
            // target), class_getInstanceMethod returns the superclass's Method object.
            // Calling method_exchangeImplementations on it would modify the superclass,
            // affecting ALL subclasses including SearchTopResultsViewController → crash.
            // Solution: add the original IMP directly on target first so the exchange
            // only touches target's own method table.
            class_addMethod(target, origSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
            // Add our replacement under the s7tv_ selector
            class_addMethod(target, newSel, newIMP, types);
            // Re-fetch: origMethod now points to target's own copy (not superclass)
            Method orig = class_getInstanceMethod(target, origSel);
            Method repl = class_getInstanceMethod(target, newSel);
            if (orig && repl) method_exchangeImplementations(orig, repl);
        };

    swizzleWithIMP(@selector(numberOfSectionsInTableView:),
        NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:"),
        (IMP)s7tv_imp_numberOfSections, "q@:@");
    swizzleWithIMP(@selector(tableView:numberOfRowsInSection:),
        NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:"),
        (IMP)s7tv_imp_numberOfRows, "q@:@q");
    swizzleWithIMP(@selector(tableView:titleForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:"),
        (IMP)s7tv_imp_titleForHeader, "@@:@q");
    swizzleWithIMP(@selector(tableView:viewForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:"),
        (IMP)s7tv_imp_viewForHeader, "@@:@q");
    swizzleWithIMP(@selector(tableView:heightForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:"),
        (IMP)s7tv_imp_heightForHeader, "d@:@q");
    swizzleWithIMP(@selector(tableView:cellForRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:"),
        (IMP)s7tv_imp_cellForRow, "@@:@@");
    swizzleWithIMP(@selector(tableView:didSelectRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:"),
        (IMP)s7tv_imp_didSelect, "v@:@@");

    [[SevenTVManager sharedManager]
        log:@"✅ AccountMenuViewController swizzlé — section 7TV Settings injectée"];
}


// ────────────────────────────────────────────────────────────
// MARK: - Interception du token Twitch (2 points de capture)
// ────────────────────────────────────────────────────────────
//
// Le hook sur dataTaskWithRequest: ne voit QUE les headers posés directement
// sur l'objet NSURLRequest. Si Twitch configure Authorization/Client-ID au
// niveau de la session (HTTPAdditionalHeaders), ils n'apparaissent jamais
// sur la requête individuelle. On capture donc à la source, aux deux
// endroits possibles où ces headers peuvent être écrits.

@interface NSMutableURLRequest (S7TVTokenCapture)
- (void)s7tv_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)s7tv_setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields;
@end

@implementation NSMutableURLRequest (S7TVTokenCapture)
- (void)s7tv_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (value.length) {
        if ([field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) {
            [[SevenTVManager sharedManager] s7tv_captureAuthorizationHeader:value];
        } else if ([field caseInsensitiveCompare:@"Client-ID"] == NSOrderedSame) {
            [[SevenTVManager sharedManager] s7tv_captureClientIDHeader:value];
        }
    }
    [self s7tv_setValue:value forHTTPHeaderField:field];
}

// Beaucoup de code (surtout en Swift : `request.allHTTPHeaderFields = [...]`)
// pose TOUS les headers d'un coup via cette méthode plutôt que field par
// field — sans ce hook, ce cas échappe complètement à setValue:forHTTPHeaderField:.
- (void)s7tv_setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields {
    for (NSString *field in headerFields) {
        NSString *value = headerFields[field];
        if (!value.length) continue;
        if ([field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) {
            [[SevenTVManager sharedManager] s7tv_captureAuthorizationHeader:value];
        } else if ([field caseInsensitiveCompare:@"Client-ID"] == NSOrderedSame) {
            [[SevenTVManager sharedManager] s7tv_captureClientIDHeader:value];
        }
    }
    [self s7tv_setAllHTTPHeaderFields:headerFields];
}
@end

@interface NSURLSessionConfiguration (S7TVTokenCapture)
- (void)s7tv_setHTTPAdditionalHeaders:(NSDictionary *)headers;
@end

@implementation NSURLSessionConfiguration (S7TVTokenCapture)
- (void)s7tv_setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSString *auth = headers[@"Authorization"] ?: headers[@"authorization"];
    NSString *clientID = headers[@"Client-ID"] ?: headers[@"client-id"];
    if (auth.length)     [[SevenTVManager sharedManager] s7tv_captureAuthorizationHeader:auth];
    if (clientID.length) [[SevenTVManager sharedManager] s7tv_captureClientIDHeader:clientID];
    [self s7tv_setHTTPAdditionalHeaders:headers];
}
@end

static void s7tv_swizzle_token_capture(void) {
    // NSMutableURLRequest est un class cluster : l'instance réelle créée par
    // Twitch est une sous-classe privée d'Apple qui a SA PROPRE implémentation
    // de setValue:forHTTPHeaderField: — swizzler la classe publique de base
    // ne sert à rien (même piège que NSURLSession, cf. s7tv_swizzle_session).
    // On sonde donc la vraie classe concrète avant de swizzler.
    NSMutableURLRequest *probeReq = [[NSMutableURLRequest alloc]
                                      initWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/"]];
    Class classReq = object_getClass(probeReq);
    [[SevenTVManager sharedManager] log:@"🔍 NSMutableURLRequest concret: %@",
     NSStringFromClass(classReq)];
    s7tv_swizzle(classReq, [NSMutableURLRequest class],
                 @selector(setValue:forHTTPHeaderField:),
                 @selector(s7tv_setValue:forHTTPHeaderField:));
    s7tv_swizzle(classReq, [NSMutableURLRequest class],
                 @selector(setAllHTTPHeaderFields:),
                 @selector(s7tv_setAllHTTPHeaderFields:));

    // NSURLSessionConfiguration n'est PAS un class cluster (classe concrète
    // normale) mais on sonde quand même par prudence/cohérence — et on
    // couvre les deux variantes (default + ephemeral) au cas où Twitch en
    // utilise une différente pour ses requêtes GQL.
    Class classCfgDefault = object_getClass([NSURLSessionConfiguration defaultSessionConfiguration]);
    Class classCfgEphemeral = object_getClass([NSURLSessionConfiguration ephemeralSessionConfiguration]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSessionConfiguration default: %@ / ephemeral: %@",
     NSStringFromClass(classCfgDefault), NSStringFromClass(classCfgEphemeral)];

    s7tv_swizzle(classCfgDefault, [NSURLSessionConfiguration class],
                 @selector(setHTTPAdditionalHeaders:),
                 @selector(s7tv_setHTTPAdditionalHeaders:));
    if (classCfgEphemeral != classCfgDefault) {
        s7tv_swizzle(classCfgEphemeral, [NSURLSessionConfiguration class],
                     @selector(setHTTPAdditionalHeaders:),
                     @selector(s7tv_setHTTPAdditionalHeaders:));
    }

    [[SevenTVManager sharedManager] log:@"🔌 Token capture (request + session config) installé"];
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSession (classe concrète via sonde)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_session(void) {
    SEL selRequest  = @selector(dataTaskWithRequest:completionHandler:);
    SEL selURL      = @selector(dataTaskWithURL:completionHandler:);
    SEL selReqOnly  = @selector(dataTaskWithRequest:);
    SEL swizRequest = @selector(s7tv_dataTaskWithRequest:completionHandler:);
    SEL swizURL     = @selector(s7tv_dataTaskWithURL:completionHandler:);
    SEL swizReqOnly = @selector(s7tv_dataTaskWithRequest:);

    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession standard: %@",
     NSStringFromClass(classStd)];
    s7tv_swizzle(classStd, [NSURLSession class], selRequest, swizRequest);
    s7tv_swizzle(classStd, [NSURLSession class], selURL, swizURL);
    s7tv_swizzle(classStd, [NSURLSession class], selReqOnly, swizReqOnly);

    Class classShared = object_getClass([NSURLSession sharedSession]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession shared: %@",
     NSStringFromClass(classShared)];
    if (classShared != classStd) {
        s7tv_swizzle(classShared, [NSURLSession class], selRequest, swizRequest);
        s7tv_swizzle(classShared, [NSURLSession class], selURL, swizURL);
        s7tv_swizzle(classShared, [NSURLSession class], selReqOnly, swizReqOnly);
    } else {
        [[SevenTVManager sharedManager] log:@"ℹ️  sharedSession même classe que standard"];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSessionWebSocketTask (classe concrète)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_websocket(void) {
    Class wsAbstractClass = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (!wsAbstractClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  NSURLSessionWebSocketTask introuvable"];
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *probeURL = [NSURL URLWithString:@"wss://irc-ws.chat.twitch.tv/irc"];
    NSURLSessionWebSocketTask *probeTask = [probeSession webSocketTaskWithURL:probeURL];
    Class realWSClass = object_getClass(probeTask);
    [probeTask cancel];

    [[SevenTVManager sharedManager] log:@"🔍 WebSocketTask classe concrète: %@",
     NSStringFromClass(realWSClass)];

    s7tv_swizzle(realWSClass, wsAbstractClass,
                 @selector(receiveMessageWithCompletionHandler:),
                 @selector(s7tv_receiveMessageWithCompletionHandler:));
    s7tv_swizzle(realWSClass, wsAbstractClass,
                 @selector(sendMessage:completionHandler:),
                 @selector(s7tv_sendMessage:completionHandler:));
}

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

// ── Démarre l'observer qui journalise les rotations physiques ────────────────
// Note : le blocage visuel est assuré par supportedInterfaceOrientationsForWindow:
// On n'appelle plus requestGeometryUpdate ici — c'était lui qui causait le flash
// "rotate puis snap back" en jouant une animation de retour inutile.
static void s7tv_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        if (!s_orientationLocked) return;
        [[SevenTVManager sharedManager] log:@"🔒 Rotation physique bloquée (verrou actif)"];
    }];
}

static void s7tv_stopOrientationObserver(void) {
    if (!s_orientationObserver) return;
    [[NSNotificationCenter defaultCenter] removeObserver:s_orientationObserver];
    s_orientationObserver = nil;
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
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
@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end
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

- (void)s7tv_toggleOrientationLock:(UIButton *)sender {
    s_orientationLocked = !s_orientationLocked;

    if (s_orientationLocked) {
        // Installer les swizzles seulement maintenant, pas au lancement
        s7tv_install_orientation_swizzles();

        // Capturer l'orientation courante de la scène
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        UIInterfaceOrientation current = activeScene
            ? activeScene.interfaceOrientation
            : UIInterfaceOrientationPortrait;

        s_lockedOrientation = current;
        switch (current) {
            case UIInterfaceOrientationLandscapeLeft:
                s_lockedOrientationMask = UIInterfaceOrientationMaskLandscapeLeft;  break;
            case UIInterfaceOrientationLandscapeRight:
                s_lockedOrientationMask = UIInterfaceOrientationMaskLandscapeRight; break;
            case UIInterfaceOrientationPortraitUpsideDown:
                s_lockedOrientationMask = UIInterfaceOrientationMaskPortraitUpsideDown; break;
            default:
                s_lockedOrientationMask = UIInterfaceOrientationMaskPortrait; break;
        }

        // Le mask est posé — supportedInterfaceOrientationsForWindow: bloque dès maintenant.
        // On n'appelle PAS requestGeometryUpdate ici : l'utilisateur est déjà dans la bonne
        // orientation, un appel inutile ouvre une fenêtre où la première rotation physique
        // peut passer avant que le cycle de géométrie soit stabilisé.
        s7tv_startOrientationObserver();
        [self log:@"🔒 Orientation verrouillée (orientation=%ld)", (long)current];

    } else {
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation     = UIInterfaceOrientationUnknown;
        s7tv_stopOrientationObserver();
        // Libérer toutes les orientations → iOS reprend la main
        s7tv_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        [UIViewController attemptRotationToDeviceOrientation];
        [self log:@"🔓 Orientation déverrouillée"];
    }

    // Mettre à jour l'icône du bouton
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                            @(UIControlStateSelected), @(UIControlStateDisabled)]) {
        [sender setImage:icon forState:st.unsignedIntegerValue];
    }
    sender.tintColor = tint;

    s7tv_showOrientationToast(s_orientationLocked);
}

@end

static void s7tv_swizzle_orientation_lock(void) {
    // Swizzles installés à la demande au premier lock, pas au lancement.
}

// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée __attribute__((constructor))
// ────────────────────────────────────────────────────────────


__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"🔌 Chargement TwitchSevenTV v2.0 (substrate-free)..."];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:S7TVChatCustomToggleDidChangeNotification
                    object:mgr
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        s7tv_applyChatCustomToggle();
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:S7TVEmoteCatalogDidUpdateNotification
                    object:mgr
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        [mgr.chatMessageStore retokenizeMessagesUsingBlock:^NSArray<S7TVChatToken *> *(S7TVChatMessage *message) {
            return s7tv_tokenizeMessageWithNativeEmotes(message.rawText ?: @"",
                                                        message.twitchEmotesTag ?: @"");
        } completion:^{
            s7tv_reloadActiveChatCustomView();
        }];
    }];

    // Verrou d'orientation (bouton Share hijacké)
    s7tv_swizzle_orientation_lock();

    // Injection bouton dans ChatInputView
    s7tv_swizzle([UIView class],
                 [UIView class],
                 @selector(didMoveToWindow),
                 @selector(s7tv_didMoveToWindow));

    // Interception réponses GQL Twitch
    s7tv_swizzle_token_capture();
    s7tv_swizzle_session();
    s7tv_swizzle_apollo_gql();

    // Interception IRC WebSocket
    s7tv_swizzle_websocket();

    // Note historique : l'ancien pipeline de resize/ratio pour le rendu natif
    // (NetworkImageRequester, attachmentBoundsForTextContainer:,
    // setAttachmentSize:forGlyphRange:, displayLayer:, willDisplayCell BFS...)
    // a été retiré — il est devenu inutile avec le passage à un rendu de chat
    // maison qui connaît les dimensions dès la construction (voir plan.txt).
    //
    // Note historique 2 : l'interception NSURLProtocol des requêtes image
    // Twitch (redirection CDN 7TV via faux ID "7tv_") a aussi été retirée.
    // Elle ne se déclenchait que grâce au tag emotes= injecté dans les
    // messages IRC — injection elle-même retirée. Le cache et le prefetch
    // (SevenTVURLProtocol) restent actifs : ils sont alimentés directement
    // par le join de channel, indépendamment du chat.

    // Section 7TV dans les paramètres Twitch
    s7tv_swizzle_account_menu();

    // Auto Collect Channel Points — module 100% autonome (voir sa section
    // dédiée plus haut dans ce fichier), aucune dépendance avec les
    // swizzles ci-dessus. Démarré directement ici, pas via didMoveToWindow.
    s7tv_scanForChannelPointsLoop();

    // Blocked URLs + HLS Sanitizer


    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        // Catalogue global + abonnement à S7TVChannelJoined (déjà postée
        // plus bas dans ce fichier depuis s7tv_handleRoomState, jamais
        // consommée jusqu'ici) — voir SevenTVBadgeProvider.h.
        [SevenTVBadgeProvider setup];
        // Le fetch du catalogue badges est async : un message peut se rendre
        // avant que le catalogue (global ou channel) ait fini de charger, et
        // dans ce cas resolvedBadgeForIdentifier: retourne nil sans retry
        // automatique (contrairement à une image manquante). On force un
        // reload complet dès que le catalogue devient disponible pour que
        // ces messages déjà affichés récupèrent leurs badges.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:S7TVBadgesCatalogUpdatedNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            s7tv_reloadActiveChatCustomView();
        }];
        // Preview live du futur écran de réglages (tailles emotes/badges/
        // texte, Phase 6) : chaque changement de valeur redessine le chat
        // en direct immédiatement, sans attendre un nouveau message —
        // même mécanisme que le reload badges ci-dessus.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:S7TVChatAppearanceConfigDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            s7tv_reloadActiveChatCustomView();
        }];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt"];

        // Démarrer le local proxy si activé

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                [[SevenTVManager sharedManager] log:@"✅ Bouton 7TV ajouté"];
            }
        );
    });
}
