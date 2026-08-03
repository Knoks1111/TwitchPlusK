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

// État global verrou d'orientation
static BOOL s_orientationLocked             = NO;
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
            // TEMP DEBUG — calibration couleurs lisibles : pseudo + hex brut,
            // pour comparer avec le rendu PC (option "couleurs lisibles").
            // À retirer une fois calibré.
            [[SevenTVManager sharedManager]
                log:@"[ChatCustom] 🏗 Couleur brute — %@ = %@", displayName, colorHex];
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
                shareBtn.accessibilityLabel      = @"Verrouiller l'orientation";
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
                [btn setTitle:@"7TV" forState:UIControlStateNormal];
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
// MARK: - Diagnostic TEMPORAIRE v2 : sniffer réseau bas niveau (NSURLProtocol)
// ────────────────────────────────────────────────────────────
//
// Le dump v1 (hook sur dataTaskWithRequest:completionHandler:, ci-dessous)
// n'a rien capté DU TOUT, même sans filtre — signe que le picker natif Twitch
// ne passe probablement pas par ce chemin précis (variante delegate-based
// -dataTaskWithRequest: sans completion handler, session/protocole
// différent, ou données déjà en cache au lancement avant l'installation du
// swizzle). Plutôt que de parier sur une méthode Obj-C précise, on
// s'enregistre au niveau du système de chargement d'URL lui-même
// (NSURLProtocol) : ça capte le trafic quel que soit le pattern interne
// utilisé côté Twitch (completion handler OU delegate), tant que ça passe
// par le URL Loading System standard — ce qui est le cas de l'immense
// majorité du code réseau iOS, contrairement au hook v1 qui suppose UNE
// implémentation précise.
//
// Restreint volontairement à gql.twitch.tv + api.twitch.tv (Helix) — PAS aux
// CDN vidéo/images (usher, jtvnw.net...) : on ne veut surtout pas relayer de
// gros segments vidéo à travers ce sniffer (risque de latence/stall sur la
// lecture du stream). Le trafic vidéo continue son chemin normal, non touché.
//
// Désactiver (retirer l'appel à +registerClass: dans TwitchSevenTVInit) une
// fois l'opération identifiée — un sniffer réseau qui reste actif en
// permanence n'a pas sa place dans une version "propre" du tweak.

// Déclarée ici, définie plus bas (section "dump des opérations GQL") — le
// sniffer NSURLProtocol l'utilise avant sa définition textuelle dans le fichier.
static void s7tv_dumpGQLOperation(NSURLRequest *request, NSData *responseData);

@interface S7TVGQLSnifferProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *relayTask;
@property (nonatomic, strong) NSMutableData *collectedData;
@end

static NSString *const kS7TVGQLSnifferHandledKey = @"S7TVGQLSnifferHandled";

// Hosts à ne JAMAIS intercepter : uniquement la VIDÉO (segments HLS) — un
// relai via notre session à part peut introduire assez de latence pour faire
// caler la lecture du stream. Les CDN images (emotes/badges, jtvnw.net) sont
// volontairement INCLUS malgré leur volume : même sans le JSON du catalogue,
// voir QUELLES URLs d'images sont demandées (et avec quel ID dans le
// chemin) au moment où le picker natif s'ouvre est une info utile en soi.
static BOOL s7tv_dumpShouldSkipHost(NSString *host) {
    if (!host.length) return YES;
    NSArray<NSString *> *skipSuffixes = @[
        @"ttvnw.net",           // vidéo (usher, segments HLS) — risque de stall si relayé
        @"7tv.app", @"7tv.io",  // notre propre trafic 7TV, pas Twitch
    ];
    for (NSString *suffix in skipSuffixes) {
        if ([host hasSuffix:suffix]) return YES;
    }
    return NO;
}

@implementation S7TVGQLSnifferProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Marqueur anti-boucle : la requête relayée par -startLoading passe elle
    // aussi par le URL Loading System — sans ce garde-fou, on s'intercepterait
    // nous-même indéfiniment.
    if ([NSURLProtocol propertyForKey:kS7TVGQLSnifferHandledKey inRequest:request]) return NO;

    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return NO;

    NSString *host = request.URL.host.lowercaseString;
    if (s7tv_dumpShouldSkipHost(host)) return NO;

    NSString *path = request.URL.path.lowercaseString;
    // Filet de sécurité supplémentaire par extension, au cas où un flux
    // vidéo/segment passerait par un host non listé ci-dessus. Les extensions
    // d'image (webp/png/jpg/gif) sont volontairement PAS filtrées ici — voir
    // commentaire sur s7tv_dumpShouldSkipHost.
    NSArray<NSString *> *skipExtensions = @[@".ts", @".m3u8", @".mp4"];
    for (NSString *ext in skipExtensions) {
        if ([path hasSuffix:ext]) return NO;
    }

    // Capture large et volontairement AGNOSTIQUE du host : on ne sait pas à
    // l'avance quel domaine Twitch utilise pour peupler son picker natif
    // (pas forcément gql.twitch.tv/api.twitch.tv — ça pourrait être un autre
    // sous-domaine interne). Tout le reste du trafic "petit/texte probable"
    // passe par ici, log générique ci-dessous.
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *marked = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kS7TVGQLSnifferHandledKey inRequest:marked];
    self.collectedData = [NSMutableData data];

    // Session dédiée éphémère, PAS la session swizzlée v1 — on utilise la
    // variante delegate-based (pas de completion handler) volontairement,
    // pour ne pas dépendre du même mécanisme que celui qui vient d'échouer.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *relaySession = [NSURLSession sessionWithConfiguration:cfg
                                                                 delegate:self
                                                            delegateQueue:nil];
    self.relayTask = [relaySession dataTaskWithRequest:marked];
    [self.relayTask resume];
}

- (void)stopLoading {
    [self.relayTask cancel];
}

// Relaie intégralement la réponse au vrai client — sans ça, TOUT le trafic
// intercepté cesserait de fonctionner silencieusement (on ne veut PAS casser
// l'app, juste observer son trafic en passant).
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.client URLProtocol:self didReceiveResponse:response
             cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.collectedData appendData:data];
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }
    // Log générique pour TOUT ce qui passe ici, quel que soit le host —
    // on ne présuppose plus que c'est forcément du GQL sur gql.twitch.tv.
    s7tv_dumpGQLOperation(self.request, self.collectedData);
    [self.client URLProtocolDidFinishLoading:self];
}

@end



// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────
// MARK: - Diagnostic TEMPORAIRE : dump des opérations GQL (picker Twitch natif)
// ────────────────────────────────────────────────────────────
//
// But : identifier quelle(s) opération(s) GQL Twitch utilise pour peupler
// SON PROPRE picker d'emotes natif (sets par chaîne abonnée, follower
// emotes, bits, global) — voir plan "picker 7TV = remplacement complet du
// picker natif avec catégories dynamiques". Aucun hook réseau nouveau :
// on se branche sur le hook GQL déjà en place plus bas (s7tv_dataTaskWithRequest:).
//
// Mettre à 0 une fois le dump terminé et l'opération identifiée — ce n'est
// pas un feature à garder active en permanence (bruit de log + parsing JSON
// sur CHAQUE requête GQL de l'app, pas juste celles du picker).
#define S7TV_DUMP_GQL_OPERATIONS 1

// Ne logue que si l'opération a un nom qui "sent" les emotes/le picker —
// évite de noyer les logs avec les dizaines d'opérations GQL sans rapport
// qui partent en permanence (Whispers, Follows, Ads, etc.). Passe à NO pour
// tout voir sans filtre si le nom de l'opération recherchée est inconnu.
#define S7TV_DUMP_GQL_FILTER_KEYWORDS NO

static BOOL s7tv_dumpNameLooksRelevant(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *keywords = @[
        @"emote", @"picker", @"availableemotes", @"emoteset", @"emotepicker",
        @"channel", @"subscription", @"emoji"
    ];
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

// Extrait le/les operationName d'un body de requête GQL Twitch — souvent un
// objet unique, parfois un TABLEAU d'opérations batchées en un seul POST.
static NSArray<NSString *> *s7tv_operationNamesFromRequestBody(NSData *body) {
    if (!body.length) return @[];
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([root isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)root) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                NSString *n = ((NSDictionary *)item)[@"operationName"];
                if ([n isKindOfClass:[NSString class]] && n.length) [names addObject:n];
            }
        }
    } else if ([root isKindOfClass:[NSDictionary class]]) {
        NSString *n = ((NSDictionary *)root)[@"operationName"];
        if ([n isKindOfClass:[NSString class]] && n.length) [names addObject:n];
    }
    return names;
}

// Logue, pour une réponse GQL donnée : le(s) nom(s) d'opération de la
// requête associée + les clés top-level de `data` dans la réponse (une
// entrée par opération si batché) — suffisant pour repérer quelle opération
// correspond aux emote sets sans reproduire tout le payload (potentiellement
// volumineux) dans les logs.
static void s7tv_dumpGQLOperation(NSURLRequest *request, NSData *responseData) {
#if S7TV_DUMP_GQL_OPERATIONS
    NSArray<NSString *> *opNames = s7tv_operationNamesFromRequestBody(request.HTTPBody);

    if (S7TV_DUMP_GQL_FILTER_KEYWORDS) {
        BOOL anyRelevant = NO;
        for (NSString *n in opNames) {
            if (s7tv_dumpNameLooksRelevant(n)) { anyRelevant = YES; break; }
        }
        if (opNames.count > 0 && !anyRelevant) return; // opération connue mais hors-sujet
    }

    NSString *opsJoined = opNames.count ? [opNames componentsJoinedByString:@", "] : @"(operationName introuvable — HTTPBody vide/stream ?)";

    id respRoot = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    NSMutableArray<NSString *> *dataKeysPerOp = [NSMutableArray array];
    NSArray *respItems = [respRoot isKindOfClass:[NSArray class]] ? respRoot : @[respRoot ?: @{}];
    for (id item in respItems) {
        if (![item isKindOfClass:[NSDictionary class]]) { [dataKeysPerOp addObject:@"?"]; continue; }
        id dataField = ((NSDictionary *)item)[@"data"];
        if ([dataField isKindOfClass:[NSDictionary class]]) {
            [dataKeysPerOp addObject:[[(NSDictionary *)dataField allKeys] componentsJoinedByString:@"+"]];
        } else {
            [dataKeysPerOp addObject:@"(pas de data)"];
        }
    }

    [[SevenTVManager sharedManager]
        log:@"[NetDump] op=[%@] clés=%@ (%lu bytes) — %@",
        opsJoined,
        [dataKeysPerOp componentsJoinedByString:@" | "],
        (unsigned long)responseData.length,
        request.URL.absoluteString];
#endif
}

@interface NSURLSession (SevenTV)
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation NSURLSession (SevenTV)

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
                    // Diagnostic temporaire — voir S7TV_DUMP_GQL_OPERATIONS en
                    // haut de ce bloc. N'affecte pas le comportement normal.
                    s7tv_dumpGQLOperation(request, data);
                    // Détecter pub dans HLS
                    NSString *path = request.URL.path.lowercaseString;
                    if ([path hasSuffix:@".m3u8"] || [path containsString:@"m3u8"]) {
                        NSString *pl = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    }
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
                if (data && !error)
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithURL:url completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithURL:url completionHandler:completionHandler];
}

@end


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
// MARK: - Tap Logger
// ────────────────────────────────────────────────────────────

BOOL s_tapLogEnabled = NO;
static NSInteger s_tapLogCount = 0;

static NSString *s7tv_viewExtra(UIView *v) {
    NSMutableString *extra = [NSMutableString string];

    if (v.accessibilityLabel.length > 0)
        [extra appendFormat:@" accLabel='%@'", v.accessibilityLabel];

    if (v.accessibilityIdentifier.length > 0)
        [extra appendFormat:@" accID='%@'", v.accessibilityIdentifier];

    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        NSArray *states = @[@(UIControlStateNormal), @(UIControlStateSelected),
                            @(UIControlStateHighlighted), @(UIControlStateDisabled)];
        NSArray *stateNames = @[@"normal", @"selected", @"highlighted", @"disabled"];
        for (NSUInteger i = 0; i < states.count; i++) {
            UIControlState st = ((NSNumber *)states[i]).unsignedIntegerValue;
            NSString *title = [btn titleForState:st];
            UIImage  *img   = [btn imageForState:st];
            if (title.length > 0)
                [extra appendFormat:@" btnTitle[%@]='%@'", stateNames[i], title];
            if (img)
                [extra appendFormat:@" btnImg[%@]=(%@)", stateNames[i], img.description];
        }
        NSSet *targets = [btn allTargets];
        for (id target in targets) {
            NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (actions.count > 0)
                [extra appendFormat:@" action=%@->%@",
                 NSStringFromClass([target class]), [actions componentsJoinedByString:@","]];
        }
    }

    if ([v isKindOfClass:[UITextField class]])
        [extra appendFormat:@" ph='%@'", ((UITextField *)v).placeholder ?: @""];

    if ([v isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)v).text;
        if (txt.length > 0 && txt.length <= 40)
            [extra appendFormat:@" text='%@'", txt];
    }

    return [extra copy];
}

static UIViewController *s7tv_vcForView(UIView *v) {
    UIResponder *r = v.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// Dump COMPLET de tout ce qui est affiché à l'écran, réutilisable (appelé
// aussi bien par le tap manuel que par le watcher automatique ci-dessous).
// Filtre sur le CONTENU (texte/image/accessibilité présents), pas sur un nom
// de classe deviné à l'avance.
static void s7tv_performFullScreenDump(UIWindow *window, NSString *reason) {
    if (!window) return;
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    [mgr log:@"[NetDump] ── DUMP ÉCRAN COMPLET (%@) ──────────────", reason];
    NSMutableArray<UIView *> *pqueue = [NSMutableArray arrayWithObject:window];
    NSInteger pcount = 0;
    while (pqueue.count > 0 && pcount < 6000) {
        UIView *sv = pqueue.firstObject; [pqueue removeObjectAtIndex:0];
        pcount++;
        [pqueue addObjectsFromArray:sv.subviews];
        CGRect frameInWindow = [sv convertRect:sv.bounds toView:nil];
        NSString *cn = NSStringFromClass([sv class]);

        // Comptage structurel des UICollectionView (grille d'emotes) via
        // l'API PUBLIQUE de UICollectionViewDataSource — numberOfSections/
        // numberOfItemsInSection donne la structure COMPLÈTE (y compris les
        // sections pas encore scrollées à l'écran), en lecture seule, sans
        // toucher à aucun ivar privé ni manipuler la vue.
        if ([sv isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)sv;
            id<UICollectionViewDataSource> ds = cv.dataSource;
            if (ds) {
                NSInteger sections = 1;
                if ([ds respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
                    sections = [ds numberOfSectionsInCollectionView:cv];
                }
                NSMutableArray<NSString *> *perSection = [NSMutableArray array];
                for (NSInteger s = 0; s < sections; s++) {
                    NSInteger items = 0;
                    @try {
                        items = [ds collectionView:cv numberOfItemsInSection:s];
                    } @catch (__unused NSException *ex) {}
                    [perSection addObject:[NSString stringWithFormat:@"section%ld=%ld items", (long)s, (long)items]];
                }
                [mgr log:@"[NetDump] 📊 %@ dataSource=%@ → %ld section(s) : %@",
                    cn, NSStringFromClass([ds class]), (long)sections,
                    [perSection componentsJoinedByString:@" | "]];
            }
        }

        NSString *extra = s7tv_viewExtra(sv);
        BOOL hasImage = [sv isKindOfClass:[UIImageView class]] && ((UIImageView *)sv).image != nil;
        BOOL hasExtra = extra.length > 0;
        if (!hasImage && !hasExtra) continue;
        NSString *imgInfo = @"";
        if (hasImage) {
            UIImage *img = ((UIImageView *)sv).image;
            imgInfo = [NSString stringWithFormat:@" imgSize=(%.0f×%.0f) imgDesc=%@",
                img.size.width, img.size.height, img.description];
        }
        [mgr log:@"[NetDump] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@%@",
            cn,
            frameInWindow.origin.x, frameInWindow.origin.y,
            frameInWindow.size.width, frameInWindow.size.height,
            imgInfo, extra];
    }
    [mgr log:@"[NetDump] ── FIN DUMP ÉCRAN (%ld vues inspectées) ──────────────", (long)pcount];
}

static UIWindow *s7tv_frontmostWindow(void) {
    UIWindow *found = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { found = w; break; }
    }
    if (!found) found = [UIApplication sharedApplication].windows.firstObject;
    return found;
}

// ────────────────────────────────────────────────────────────
// MARK: - Énumération générique de TOUTES les fenêtres connues
// ────────────────────────────────────────────────────────────
//
// s7tv_frontmostWindow() (ci-dessus) ne retourne qu'UNE fenêtre — c'était la
// cause racine du bug "picker_trouvé=non" : si le picker natif vit dans une
// fenêtre qui n'est ni key ni first, le watcher ne la scannait tout
// simplement jamais, quel que soit son nom de classe. Ici on récupère TOUTES
// les fenêtres, depuis deux sources complémentaires, sans jamais nommer une
// classe de fenêtre précise :
//   1) [UIApplication sharedApplication].windows — couvre encore la plupart
//      des fenêtres attachées au process, y compris certaines fenêtres
//      "système" hébergées côté app (clavier, effets de texte, etc.).
//   2) chaque UIWindowScene connectée → sa propre liste .windows — utile
//      sur les configurations multi-fenêtres/multi-scène (iPad, Stage
//      Manager) où (1) seul peut être incomplet.
// Dédoublonnage par identité de pointeur (comportement par défaut de
// NSMutableOrderedSet pour un UIWindow qui ne surcharge pas isEqual:).
static NSArray<UIWindow *> *s7tv_allKnownWindows(void) {
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w) [set addObject:w];
    }

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w) [set addObject:w];
        }
    }

    return set.array;
}

// Recherche générique d'une vue dont le nom de classe contient
// "EmoticonPalette" (constat empirique du dump manuel — c'est la seule
// signature qu'on utilise, jamais une classe de fenêtre). BFS plafonné pour
// borner le coût même sur une hiérarchie profonde.
static UIView *s7tv_findPaletteRoot(UIView *root, NSInteger nodeCap) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger count = 0;
    while (queue.count > 0 && count < nodeCap) {
        UIView *sv = queue.firstObject; [queue removeObjectAtIndex:0];
        count++;
        [queue addObjectsFromArray:sv.subviews];
        if ([NSStringFromClass([sv class]) rangeOfString:@"EmoticonPalette"].location != NSNotFound) {
            return sv;
        }
    }
    return nil;
}

// ────────────────────────────────────────────────────────────
// MARK: - Watcher automatique du picker natif (diagnostic TEMPORAIRE)
// ────────────────────────────────────────────────────────────
//
// Plutôt que de dépendre d'un tap manuel à chaque fois qu'on veut capturer
// un nouvel état (après un scroll, un changement d'onglet), ce timer scanne
// périodiquement l'écran, détecte si le picker natif ("EmoticonPalette" dans
// le nom de classe) est présent, et redéclenche un dump COMPLET
// automatiquement dès que ce qui est visible a changé (fingerprint = titres
// des sections actuellement visibles). Purement passif — aucune manipulation
// du picker (pas de scroll forcé, pas d'appel à ses méthodes internes), donc
// pas une "injection" : on lit ce que l'utilisateur fait défiler lui-même.
static NSString *s_pickerWatchLastFingerprint = nil;

// Fenêtre hôte du picker, confirmée soit par le scan périodique, soit (de
// façon plus fiable et plus rapide) par le hook événementiel sur
// sendEvent: ci-dessous. weak : on ne veut surtout pas prolonger la vie
// d'une fenêtre système par accident — si elle est libérée, la variable
// redevient nil naturellement et le prochain check retombe sur le scan
// complet.
static __weak UIWindow *s_pickerConfirmedHostWindow = nil;

static NSString *s7tv_pickerVisibleFingerprint(UIView *root) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger count = 0;
    while (queue.count > 0 && count < 3000) {
        UIView *sv = queue.firstObject; [queue removeObjectAtIndex:0];
        count++;
        [queue addObjectsFromArray:sv.subviews];
        if ([sv isKindOfClass:[UILabel class]] &&
            [sv.accessibilityIdentifier isEqualToString:@"emoticon_palette_header_view_title_label"]) {
            NSString *txt = ((UILabel *)sv).text;
            if (txt.length) [titles addObject:txt];
        }
    }
    [titles sortUsingSelector:@selector(compare:)];
    return [titles componentsJoinedByString:@"|"];
}

static NSInteger s_pickerWatchTickCount = 0;

// Vérifie UNE fenêtre donnée : si elle contient toujours le picker, compare
// le fingerprint (titres de sections visibles) à la dernière valeur connue
// et ne redéclenche un dump complet QUE si quelque chose a changé (nouveau
// scroll, changement d'onglet...). Partagée entre le tick périodique et le
// déclenchement événementiel (sendEvent:) pour ne pas dupliquer la logique.
static void s7tv_pickerCheckWindow(UIWindow *window, NSString *triggerReason) {
    if (!window) return;

    UIView *paletteRoot = s7tv_findPaletteRoot(window, 4000);
    if (!paletteRoot) {
        // Picker plus présent dans cette fenêtre : si c'était notre fenêtre
        // hôte confirmée, on la relâche pour retomber sur le scan complet
        // au prochain tick/événement (couvre le cas où le picker change de
        // fenêtre porteuse d'une ouverture à l'autre).
        if (s_pickerConfirmedHostWindow == window) s_pickerConfirmedHostWindow = nil;
        if (s_pickerWatchLastFingerprint) s_pickerWatchLastFingerprint = nil;
        return;
    }

    NSString *fingerprint = s7tv_pickerVisibleFingerprint(paletteRoot);
    if ([fingerprint isEqualToString:s_pickerWatchLastFingerprint]) return; // rien de nouveau visible

    s_pickerWatchLastFingerprint = fingerprint;
    s7tv_performFullScreenDump(window,
        [NSString stringWithFormat:@"%@, sections visibles=[%@]", triggerReason, fingerprint]);
}

static void s7tv_pickerAutoWatchTick(void) {
    // Aucune dépendance au Tap Logger — ce watcher est indépendant. Par
    // contre, pas de raison de scanner la hiérarchie de vues toutes les
    // 1.2s si le résultat serait de toute façon jeté silencieusement par
    // -[SevenTVManager log:] faute de catégorie activée — on vérifie donc
    // ici en amont, avant même de commencer le scan.
    SevenTVManager *earlyCheckMgr = [SevenTVManager sharedManager];
    if (!earlyCheckMgr.logsEnabled || !earlyCheckMgr.logDump) return;

    s_pickerWatchTickCount++;
    // Heartbeat INCONDITIONNEL (une ligne toutes les ~3.6s) — sert
    // uniquement à vérifier que le timer se déclenche bien. À retirer une
    // fois le diagnostic terminé.
    BOOL shouldHeartbeat = (s_pickerWatchTickCount % 3 == 0);

    // Raccourci : si le hook événementiel (sendEvent:, voir plus bas) a déjà
    // confirmé une fenêtre hôte et qu'elle contient toujours le picker, on
    // l'utilise directement — évite de rescanner TOUTES les fenêtres à
    // chaque tick une fois le picker localisé.
    UIWindow *hostWindow = s_pickerConfirmedHostWindow;
    BOOL foundPicker = NO;
    NSArray<UIWindow *> *allWindows = nil;

    if (hostWindow && s7tv_findPaletteRoot(hostWindow, 4000)) {
        foundPicker = YES;
    } else {
        hostWindow = nil;
        s_pickerConfirmedHostWindow = nil;

        // Scan complet et générique : TOUTES les fenêtres connues (voir
        // s7tv_allKnownWindows), pas seulement une "frontmost" — c'était le
        // bug initial. Le picker peut très bien vivre dans une fenêtre qui
        // n'est ni key ni first (clavier, overlay, PiP, etc.), quelle que
        // soit sa classe : on ne filtre jamais par NSStringFromClass sur la
        // fenêtre elle-même, uniquement sur la vue du picker qu'elle
        // contient.
        allWindows = s7tv_allKnownWindows();
        for (UIWindow *w in allWindows) {
            if (s7tv_findPaletteRoot(w, 4000)) {
                foundPicker = YES;
                hostWindow = w;
                s_pickerConfirmedHostWindow = w;
                break;
            }
        }
    }

    if (shouldHeartbeat) {
        NSArray<UIWindow *> *listForLog = allWindows ?: s7tv_allKnownWindows();
        NSMutableArray<NSString *> *classNames = [NSMutableArray array];
        for (UIWindow *w in listForLog) [classNames addObject:NSStringFromClass([w class])];
        [earlyCheckMgr log:@"[NetDump] 💓 tick #%ld — %ld fenêtre(s)=[%@] picker_trouvé=%@ host=%@",
            (long)s_pickerWatchTickCount,
            (long)listForLog.count,
            [classNames componentsJoinedByString:@", "],
            foundPicker ? @"OUI" : @"non",
            hostWindow ? NSStringFromClass([hostWindow class]) : @"—"];
    }

    if (!foundPicker) {
        if (s_pickerWatchLastFingerprint) {
            s_pickerWatchLastFingerprint = nil; // picker fermé — reset pour la prochaine ouverture
        }
        return;
    }

    s7tv_pickerCheckWindow(hostWindow, @"auto-watch (timer)");
}

static void s7tv_startPickerAutoWatch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // NSRunLoopCommonModes plutôt que scheduledTimerWithTimeInterval:
        // (qui utilise NSDefaultRunLoopMode) — sinon ce timer serait
        // silencieusement suspendu pendant tout scroll/tracking tactile
        // (UIKit bascule alors sur UITrackingRunLoopMode), c'est-à-dire
        // précisément pendant qu'on fait défiler le picker natif.
        NSTimer *watchTimer = [NSTimer timerWithTimeInterval:1.2
                                                       repeats:YES
                                                         block:^(NSTimer * _Nonnull timer) {
            s7tv_pickerAutoWatchTick();
        }];
        [[NSRunLoop mainRunLoop] addTimer:watchTimer forMode:NSRunLoopCommonModes];
        [[SevenTVManager sharedManager] log:@"[NetDump] Watcher automatique du picker natif démarré (1.2s)"];
    });
}



// ────────────────────────────────────────────────────────────
// MARK: - Détection événementielle générique du picker natif
// ────────────────────────────────────────────────────────────
//
// C'est l'approche privilégiée par rapport au polling pur : sendEvent: est
// déjà swizzlé sur UIWindow (méthode d'instance), donc CETTE fonction se
// déclenche sur n'importe quelle instance de fenêtre qui reçoit un touch —
// key window, PiP, overlay, clavier, etc. — sans qu'on ait jamais besoin de
// connaître ou nommer sa classe à l'avance. On se contente de vérifier si la
// vue effectivement touchée (ou un de ses ancêtres) appartient au picker
// natif ("EmoticonPalette" dans le nom de classe, seule signature stable
// identifiée par le dump manuel). Si oui, "self" — la fenêtre qui a
// réellement reçu l'event — devient la fenêtre hôte confirmée.
//
// Lecture seule : on ne fait qu'observer hitTest:/la hiérarchie déjà
// produite par le système pour ce touch, aucun appel n'altère la gestion de
// l'event ni son acheminement au picker natif.
static void s7tv_pickerDetectFromEvent(UIWindow *window, UIEvent *event) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!mgr.logsEnabled || !mgr.logDump) return; // même garde que le watcher — pas de coût si diagnostic désactivé
    if (event.type != UIEventTypeTouches) return;

    UITouch *touch = event.allTouches.anyObject;
    if (!touch) return;
    // Began pour détecter une nouvelle ouverture / un nouveau tap, Moved
    // pour suivre un scroll en quasi temps réel sans multiplier les checks
    // à chaque micro-mouvement (Moved seul suffit, pas besoin de Stationary).
    if (touch.phase != UITouchPhaseBegan && touch.phase != UITouchPhaseMoved) return;

    CGPoint pt = [touch locationInView:window];
    UIView *hit = [window hitTest:pt withEvent:nil];
    if (!hit) return;

    BOOL isPalette = NO;
    UIView *v = hit;
    for (int d = 0; d < 25 && v; d++, v = v.superview) {
        if ([NSStringFromClass([v class]) rangeOfString:@"EmoticonPalette"].location != NSNotFound) {
            isPalette = YES;
            break;
        }
    }
    if (!isPalette) return;

    if (s_pickerConfirmedHostWindow != window) {
        s_pickerConfirmedHostWindow = window;
        [mgr log:@"[NetDump] 🎯 Picker natif confirmé par événement — fenêtre hôte = %@ (classe détectée dynamiquement, jamais hardcodée)",
            NSStringFromClass([window class])];
    }

    // Redéclenche un check immédiat (fingerprint + dump si changement) au
    // lieu d'attendre le prochain tick du timer (jusqu'à 1.2s de latence) —
    // capture les scrolls/changements d'onglet en quasi temps réel.
    __weak UIWindow *weakWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *strongWindow = weakWindow;
        if (!strongWindow) return;
        s7tv_pickerCheckWindow(strongWindow, @"événement (touch sur le picker)");
    });
}

@implementation UIWindow (S7TVTapLogger)

- (void)s7tv_sendEvent:(UIEvent *)event {
    [self s7tv_sendEvent:event];

    // Détection événementielle du picker — volontairement AVANT le early
    // return sur s_tapLogEnabled ci-dessous : elle doit rester active même
    // si le diagnostic "Tap Logger" (verbeux, un dump complet par tap) est
    // désactivé. C'est un mécanisme indépendant.
    s7tv_pickerDetectFromEvent(self, event);

    if (!s_tapLogEnabled) return;
    if (event.type != UIEventTypeTouches) return;

    UITouch *touch = event.allTouches.anyObject;
    if (!touch || touch.phase != UITouchPhaseBegan) return;

    s_tapLogCount++;
    CGPoint pt = [touch locationInView:self];

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"👆 TAP #%ld @ (%.0f, %.0f)", (long)s_tapLogCount, pt.x, pt.y];

    UIView *keyWindow = self;
    UIResponder *currentFR = nil;
    {
        NSMutableArray<UIView *> *frQueue = [NSMutableArray arrayWithObject:keyWindow];
        while (frQueue.count > 0) {
            UIView *fv = frQueue.firstObject; [frQueue removeObjectAtIndex:0];
            if (fv.isFirstResponder) { currentFR = fv; break; }
            for (UIView *sub in fv.subviews) [frQueue addObject:sub];
        }
    }
    if (currentFR) {
        NSString *frExtra = @"";
        if ([currentFR isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)currentFR;
            frExtra = [NSString stringWithFormat:@" text='%@' selectedRange={%lu,%lu}",
                       tv.text ?: @"",
                       (unsigned long)tv.selectedRange.location,
                       (unsigned long)tv.selectedRange.length];
        }
        [mgr log:@"  FIRST_RESPONDER: %@%@",
         NSStringFromClass([currentFR class]), frExtra];
    } else {
        [mgr log:@"  FIRST_RESPONDER: (aucun)"];
    }

    UIView *hit = [self hitTest:pt withEvent:nil];
    if (!hit) {
        [mgr log:@"  HIT: (nil)"];
        return;
    }

    [mgr log:@"  HIT: %@ frame=(%.0f,%.0f,%.0f,%.0f) tag=%ld%@",
     NSStringFromClass([hit class]),
     hit.frame.origin.x, hit.frame.origin.y,
     hit.frame.size.width, hit.frame.size.height,
     (long)hit.tag,
     s7tv_viewExtra(hit)];

    UIViewController *vc = s7tv_vcForView(hit);
    if (vc) [mgr log:@"  VC: %@", NSStringFromClass([vc class])];

    UIView *v = hit.superview;
    for (int d = 1; d <= 15 && v; d++, v = v.superview) {
        [mgr log:@"  [%02d] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
         d, NSStringFromClass([v class]),
         v.frame.origin.x, v.frame.origin.y,
         v.frame.size.width, v.frame.size.height,
         s7tv_viewExtra(v)];
    }
    [mgr log:@"  ── fin hiérarchie ──"];

    __weak UIWindow *weakWindow = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *strongWindow = weakWindow;
        if (!strongWindow) return;
        s7tv_performFullScreenDump(strongWindow,
            [NSString stringWithFormat:@"tap manuel @ (%.0f,%.0f)", pt.x, pt.y]);
    });
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
    lbl.text = @"7TV SETTINGS";
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

    cell.textLabel.text = @"7TV Settings";
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
    SEL swizRequest = @selector(s7tv_dataTaskWithRequest:completionHandler:);
    SEL swizURL     = @selector(s7tv_dataTaskWithURL:completionHandler:);

    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession standard: %@",
     NSStringFromClass(classStd)];
    s7tv_swizzle(classStd, [NSURLSession class], selRequest, swizRequest);
    s7tv_swizzle(classStd, [NSURLSession class], selURL, swizURL);

    Class classShared = object_getClass([NSURLSession sharedSession]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession shared: %@",
     NSStringFromClass(classShared)];
    if (classShared != classStd) {
        s7tv_swizzle(classShared, [NSURLSession class], selRequest, swizRequest);
        s7tv_swizzle(classShared, [NSURLSession class], selURL, swizURL);
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
        NSString *label  = locked ? @"Verrouillé" : @"Déverrouillé";

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

    // Tap logger
    s7tv_swizzle([UIWindow class],
                 [UIWindow class],
                 @selector(sendEvent:),
                 @selector(s7tv_sendEvent:));

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

    // Diagnostic TEMPORAIRE v2 — sniffer bas niveau, indépendant de la
    // méthode NSURLSession utilisée en interne par Twitch (voir
    // S7TVGQLSnifferProtocol ci-dessus). Retirer cette ligne une fois
    // l'opération du picker natif identifiée.
    [NSURLProtocol registerClass:[S7TVGQLSnifferProtocol class]];
    [[SevenTVManager sharedManager] log:@"[NetDump] Sonde réseau active pour capturer les catégories du menu emote natif"];

    // Watcher automatique du picker natif — voir s7tv_startPickerAutoWatch
    // (diagnostic temporaire, indépendant du sniffer réseau ci-dessus).
    s7tv_startPickerAutoWatch();

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
