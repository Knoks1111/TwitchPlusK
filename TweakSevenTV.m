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
#import "SevenTVEmoteImageCache.h"
#import "SevenTVChatTokenizer.h"
#import "SevenTVBadgeProvider.h"
#import "7tv-chat-ReplyThreadPanel.h"
#import "7tv-system-NativeBehaviorHooks.h"


// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVBitsHijacked    = 6;
static const char kS7TVOrigSectionCount = 7;
static const char kS7TVShareHijacked   = 8;   // verrou orientation

// Variable de compat : le Tap Logger (diagnostic de reverse-engineering du
// picker natif Twitch) a été retiré de ce fichier, mais SevenTVManager.m
// lit/écrit encore s_tapLogEnabled en le synchronisant avec le réglage
// logTap des paramètres — linkage externe (pas de mot-clé static), gardée
// ici pour ne pas casser ce pont. N'a plus aucun effet côté tweak : plus
// aucun code de ce fichier ne la consulte.
BOOL s_tapLogEnabled = NO;


// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzle
// ────────────────────────────────────────────────────────────

void s7tv_swizzle(Class targetClass,
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


// Recherche récursive d'une clé dans un JSON déjà parsé (NSDictionary/
// NSArray imbriqués). `*found` distingue "clé absente" de "clé présente
// mais valant null" — cette distinction compte : si la clé est absente,
// cette réponse GQL ne concerne pas ChannelPointsQuery et on ne doit rien
// en conclure ; si elle vaut explicitement null, c'est une confirmation
// positive qu'il n'y a PAS de coffre en attente.
id s7tv_findValueForKeyRecursive(id json, NSString *key, BOOL *found) {
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

// ────────────────────────────────────────────────────────────
// MARK: - Diagnostic ciblé récompenses de points de chaîne
// ────────────────────────────────────────────────────────────
//
// L'API publique ne permet pas à un simple viewer de lister les récompenses
// personnalisées d'une autre chaîne. Avant de figer un parser sur le schéma
// privé de Twitch, on capture donc uniquement les branches pertinentes des
// réponses que l'app charge déjà, ainsi que les événements IRC/WebSocket.
// Le tag explicite garde ces trois sources seules dans la catégorie
// ChatCustom pendant le diagnostic demandé par l'utilisateur.

// Cherche la première instance de Twitch.ChatInputView actuellement
// affichée, tous écrans/fenêtres connectés confondus (couvre normal,
// théâtre, et PiP si jamais Twitch y instancie sa propre ChatInputView).
UIView *s7tv_findChatInputView(void) {
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

// Getter en lecture seule vers s_activeChatCustomView, pour les fichiers
// externes (voir 7tv-chat-ReplyThreadPanel.m) — la variable elle-même reste
// privée à ce fichier, seule cette fonction est exposée (déclarée dans
// SevenTVManager.h).
SevenTVChatCustomView *s7tv_activeChatCustomView(void) {
    return s_activeChatCustomView;
}

// Appelée après un changement qui invalide l'affichage courant (nouveau
// message, changement de chaîne...). No-op silencieux si aucune vue custom
// n'est actuellement montée (kill switch désactivé, ou chat pas encore ouvert).
static void s7tv_reloadActiveChatCustomView(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view reloadMessages];
        // Un nouveau message peut appartenir au fil actuellement affiché
        // dans le panneau (quelqu'un vient de répondre) — no-op silencieux
        // si le panneau est fermé, voir S7TVReplyThreadPanel.refreshIfNeeded.
        [[S7TVReplyThreadPanel sharedPanel] refreshIfNeeded];
    });
}

// Mutations groupées de modération : même snapshot global que ci-dessus,
// mais avec transition visuelle. Jamais utilisé pour le flux IRC normal.
static void s7tv_reloadActiveChatCustomViewAnimated(void) {
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view reloadMessagesAnimated:YES];
        [[S7TVReplyThreadPanel sharedPanel] refreshIfNeeded];
    });
}

// CLEARMSG ne touche qu'un message : recharge uniquement son item diffable
// au lieu d'invalider les 300 messages potentiellement conservés en mémoire.
static void s7tv_reloadActiveChatMessage(NSString *messageID) {
    if (!messageID.length) return;
    SevenTVChatCustomView *view = s_activeChatCustomView;
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view refreshMessageWithID:messageID animated:YES];
        [[S7TVReplyThreadPanel sharedPanel] refreshIfNeeded];
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
            log:@"⚠️ ChatTranscriptView introuvable dans arrangedSubviews"];
        return;
    }

    chatView.hidden = YES;

    SevenTVChatCustomView *customView =
        [[SevenTVChatCustomView alloc] initWithStore:[SevenTVManager sharedManager].chatMessageStore];
    customView.delegate = [S7TVReplyThreadPanel sharedPanel];
    customView.onReplyTargetSelected = ^(NSString *messageID, NSString *username) {
        [[S7TVReplyThreadPanel sharedPanel]
            selectReplyTargetForMessageID:messageID username:username];
    };

    [stack insertArrangedSubview:customView atIndex:idx];
    objc_setAssociatedObject(chatView, &kS7TVChatCustomInstalledView, customView, OBJC_ASSOCIATION_RETAIN);
    s_activeChatCustomView = customView;

    [customView reloadMessages];

    [[SevenTVManager sharedManager]
        log:@"🏗 SevenTVChatCustomView insérée (index %ld du UIStackView, chat réel caché)",
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

// Conversion #RRGGBB partagée par les parseurs IRC et PubSub. Une valeur
// absente ou invalide reste nil : le renderer appliquera son fallback.
static UIColor * _Nullable s7tv_colorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 6) return nil;
    NSString *digits = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (digits.length != 6) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:digits];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// Décode l'échappement générique des valeurs de tags IRC (IRCv3 tag
// escaping) : \s = espace, \: = point-virgule, \\ = backslash, \r, \n.
// C'est ce qui manquait et causait l'affichage brut "Mais\sdu\sscoup\s..."
// dans le bandeau reply-parent-msg-body — le seul tag de ce fichier qui
// contient régulièrement des espaces, donc le seul où l'absence de décodage
// se voyait à l'écran. Les autres tags (badges=, emotes=, etc.) ne
// contiennent normalement aucun caractère à échapper → no-op pour eux.
static NSString *s7tv_unescapeIRCTagValue(NSString *value) {
    if (![value containsString:@"\\"]) return value; // fast path, cas le plus fréquent
    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    NSUInteger i = 0;
    NSUInteger len = value.length;
    while (i < len) {
        unichar c = [value characterAtIndex:i];
        if (c == '\\' && i + 1 < len) {
            unichar next = [value characterAtIndex:i + 1];
            switch (next) {
                case 's': [result appendString:@" "]; break;
                case ':': [result appendString:@";"]; break;
                case '\\': [result appendString:@"\\"]; break;
                case 'r': [result appendString:@"\r"]; break;
                case 'n': [result appendString:@"\n"]; break;
                // Séquence inconnue : on garde le caractère tel quel plutôt
                // que de planter (parsing tolérant, exigence Phase 1a).
                default: [result appendFormat:@"%C", next]; break;
            }
            i += 2;
        } else {
            [result appendFormat:@"%C", c];
            i += 1;
        }
    }
    return result;
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
        if (key.length) tags[key] = s7tv_unescapeIRCTagValue(val);
    }
    return tags;
}

// Twitch fournit tmi-sent-ts en millisecondes sur le flux live. Le service
// Recent Messages ajoute rm-received-ts aux lignes historiques ; on le
// préfère car il correspond au moment réellement observé par son relais.
static NSDate *s7tv_messageTimestampFromTags(NSDictionary<NSString *, NSString *> *tags) {
    NSString *milliseconds = s7tv_tagValue(tags, @"rm-received-ts", @"");
    if (!milliseconds.length) milliseconds = s7tv_tagValue(tags, @"tmi-sent-ts", @"");
    NSTimeInterval value = milliseconds.doubleValue;
    return value > 0 ? [NSDate dateWithTimeIntervalSince1970:value / 1000.0] : [NSDate date];
}

// ────────────────────────────────────────────────────────────
// MARK: - Modération IRC live (CLEARMSG / CLEARCHAT, Phase 5)
// ────────────────────────────────────────────────────────────
//
// CLEARMSG  : suppression d'un message précis via target-msg-id.
// CLEARCHAT : avec target-user-id = timeout/ban d'un utilisateur ; sans
//             cible = vidage global. Dans tous les cas, le store conserve
//             rawText/tokens et ne change que l'état d'affichage local.
//
// Retourne YES dès que la ligne est une commande de modération, même si elle
// est malformée ou vise une ancienne chaîne. L'appelant ne doit alors pas la
// faire passer dans les parseurs de messages normaux.
static BOOL s7tv_handleModerationEvent(NSString *ircLine) {
    BOOL isClearMessage = [ircLine containsString:@" CLEARMSG "];
    BOOL isClearChat    = [ircLine containsString:@" CLEARCHAT "];
    if (!isClearMessage && !isClearChat) return NO;

    NSDictionary<NSString *, NSString *> *tags = @{};
    NSString *rest = ircLine;
    if ([ircLine hasPrefix:@"@"] ) {
        NSRange firstSpace = [ircLine rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            tags = s7tv_parseIRCTags([ircLine substringWithRange:
                NSMakeRange(1, firstSpace.location - 1)]);
            rest = [ircLine substringFromIndex:firstSpace.location + 1];
        }
    }

    NSString *command = isClearMessage ? @"CLEARMSG" : @"CLEARCHAT";
    NSRange commandRange = [rest rangeOfString:command];
    if (commandRange.location == NSNotFound) return YES;

    NSString *afterCommand = [rest substringFromIndex:NSMaxRange(commandRange)];
    afterCommand = [afterCommand stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!afterCommand.length) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ Modération %@ ignorée (channel absent)", command];
        return YES;
    }

    NSRange channelEnd = [afterCommand rangeOfCharacterFromSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *channelToken = (channelEnd.location == NSNotFound)
        ? afterCommand : [afterCommand substringToIndex:channelEnd.location];
    NSString *trailing = (channelEnd.location == NSNotFound)
        ? @"" : [afterCommand substringFromIndex:channelEnd.location + 1];
    trailing = [trailing stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trailing hasPrefix:@":"]) trailing = [trailing substringFromIndex:1];
    if ([channelToken hasPrefix:@"#"]) channelToken = [channelToken substringFromIndex:1];

    // Même garde-fou que PRIVMSG/USERNOTICE : une commande tardive provenant
    // de l'ancienne chaîne ne doit jamais modifier le store de la nouvelle.
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (channelToken.length && mgr.currentChannelName.length &&
        [channelToken caseInsensitiveCompare:mgr.currentChannelName] != NSOrderedSame) {
        return YES;
    }

    S7TVChatMessageStore *store = mgr.chatMessageStore;
    if (isClearMessage) {
        NSString *targetMessageID = s7tv_tagValue(tags, @"target-msg-id", @"");
        if (!targetMessageID.length) {
            [mgr log:@"⚠️ CLEARMSG ignoré (target-msg-id absent)"];
            return YES;
        }
        [store markMessageDeletedByID:targetMessageID completion:^{
            [mgr log:@"🛡 CLEARMSG appliqué (message id=%@)", targetMessageID];
            s7tv_reloadActiveChatMessage(targetMessageID);
        }];
        return YES;
    }

    NSString *targetUserID = s7tv_tagValue(tags, @"target-user-id", @"");
    if (targetUserID.length) {
        // Twitch envoie `ban-duration` (secondes) uniquement pour un
        // timeout. Son absence sur un CLEARCHAT ciblé signifie ban
        // permanent. On conserve cette distinction dans chaque message.
        NSString *rawBanDuration = tags[@"ban-duration"];
        BOOL isTimeout = (rawBanDuration != nil);
        NSInteger durationSeconds = isTimeout ? MAX(0, rawBanDuration.integerValue) : 0;
        S7TVChatModerationKind kind = isTimeout
            ? S7TVChatModerationKindTimeout
            : S7TVChatModerationKindPermanentBan;
        [store markAllMessagesDeletedForUserID:targetUserID
                                moderationKind:kind
                               durationSeconds:durationSeconds
                                     completion:^{
            [mgr log:@"🛡 CLEARCHAT utilisateur appliqué (user-id=%@, login=%@, %@)",
                targetUserID, trailing.length ? trailing : @"inconnu",
                isTimeout ? [NSString stringWithFormat:@"timeout=%lds", (long)durationSeconds]
                          : @"ban permanent"];
            s7tv_reloadActiveChatCustomViewAnimated();
        }];
    } else if (trailing.length) {
        // Une cible textuelle sans id indique une ligne ciblée malformée.
        // Ne surtout pas la confondre avec un CLEARCHAT global, qui
        // masquerait par erreur tout le transcript.
        [mgr log:@"⚠️ CLEARCHAT ciblé ignoré (target-user-id absent, login=%@)",
            trailing];
    } else {
        [store markAllMessagesDeletedWithCompletion:^{
            [mgr log:@"🛡 CLEARCHAT global appliqué"];
            s7tv_reloadActiveChatCustomViewAnimated();
        }];
    }
    return YES;
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

// Défini plus bas avec l'ingestion du catalogue GQL. Le parseur IRC reste
// l'unique constructeur des messages et lui demande simplement si son
// msg-id correspond à une récompense automatique actuellement configurée.
static S7TVChannelPointRewardInfo * _Nullable
s7tv_automaticRewardInfoForIRCMessageID(NSString *messageID);

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
    // chaînes, même après le reset fait au JOIN (voir
    // s7tv_sendMessage:completionHandler:) puisque de nouveaux messages de l'ancienne
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

    // /me (Twitch l'encode en CTCP ACTION IRC standard) : le texte brut est
    // enveloppé "\x01ACTION texte\x01". Déballage AVANT tokenisation —
    // emotesTag utilise des offsets relatifs au texte réellement affiché
    // (sans le wrapper ACTION), donc décaler l'appel à
    // s7tv_tokenizeMessageWithNativeEmotes: plus bas casserait l'alignement
    // des emotes si on ne déballait qu'après.
    static NSString *const kS7TVActionPrefix = @"\001ACTION ";
    static NSString *const kS7TVActionSuffix = @"\001";
    BOOL isActionMessage = NO;
    if (messageText.length > kS7TVActionPrefix.length &&
        [messageText hasPrefix:kS7TVActionPrefix] &&
        [messageText hasSuffix:kS7TVActionSuffix]) {
        isActionMessage = YES;
        messageText = [messageText substringWithRange:NSMakeRange(
            kS7TVActionPrefix.length,
            messageText.length - kS7TVActionPrefix.length - kS7TVActionSuffix.length)];
    }

    NSString *messageID    = s7tv_tagValue(tags, @"id", [[NSUUID UUID] UUIDString]);
    NSString *userID       = s7tv_tagValue(tags, @"user-id", @"");
    NSString *displayName  = s7tv_tagValue(tags, @"display-name", @"???");
    NSString *colorHex     = s7tv_tagValue(tags, @"color", @"");
    NSString *emotesTag    = s7tv_tagValue(tags, @"emotes", @"");
    NSString *badgesTag    = s7tv_tagValue(tags, @"badges", @"");
    NSString *customRewardID = s7tv_tagValue(tags, @"custom-reward-id", @"");
    NSString *ircMessageID = s7tv_tagValue(tags, @"msg-id", @"");

    // ── Réponses / fils de discussion ───────────────────────────────────
    // reply-parent-msg-id = message immédiatement au-dessus (juste pour le
    // bandeau "Répond à @X"). reply-thread-parent-msg-id = racine du fil
    // ENTIER, fournie par Twitch séparément dès le 2e niveau de réponse —
    // c'est CE champ (jamais reply-parent-msg-id) qui doit servir à
    // regrouper les messages d'un même fil, voir SevenTVChatMessage.h.
    // Absent → pas une réponse (defaultValue @"" == non trouvé, testé via
    // .length ci-dessous plutôt que comparé à une chaîne magique).
    NSString *replyParentMsgID  = s7tv_tagValue(tags, @"reply-parent-msg-id", @"");
    NSString *replyThreadRootID = s7tv_tagValue(tags, @"reply-thread-parent-msg-id", @"");
    if (!replyThreadRootID.length) replyThreadRootID = replyParentMsgID; // 1er niveau = racine

    S7TVChatMessage *msg = [[S7TVChatMessage alloc] initWithMessageID:messageID
                                                             timestamp:s7tv_messageTimestampFromTags(tags)
                                                          authorUserID:userID
                                                     authorDisplayName:displayName
                                                               rawText:messageText];
    msg.isActionMessage = isActionMessage;
    msg.channelPointRewardID = customRewardID.length ? customRewardID : nil;
    if (replyParentMsgID.length) {
        msg.replyParentMessageID   = replyParentMsgID;
        // reply-parent-user-login est le pseudo de connexion (minuscules,
        // pas le display-name avec casse/accents) — display-name est ce
        // qu'on affiche partout ailleurs dans ce fichier, donc on le
        // préfère ici s'il est présent pour rester cohérent visuellement,
        // avec repli sur user-login sinon.
        NSString *parentDisplayName = s7tv_tagValue(tags, @"reply-parent-display-name", @"");
        msg.replyParentUsername = parentDisplayName.length
            ? parentDisplayName
            : s7tv_tagValue(tags, @"reply-parent-user-login", @"");
        msg.replyParentBodyPreview = s7tv_tagValue(tags, @"reply-parent-msg-body", @"");
        msg.replyThreadRootID = replyThreadRootID;
    }
    msg.authorColor = s7tv_colorFromHexString(colorHex);

    // Tokenisation à la construction, pas au rendu (Phase 2) : chaque emote
    // du message (7TV comme Twitch native) a déjà ses dimensions connues
    // avant même le premier passage dans la table — c'est ce qui permet de
    // réserver l'espace exact dès le départ côté renderer, sans jamais avoir
    // à resize après coup une fois l'image chargée.
    msg.tokens = s7tv_tokenizeMessageWithNativeEmotes(messageText, emotesTag);
    msg.twitchEmotesTag = emotesTag;
    msg.badgeIdentifiers = s7tv_parseBadgesTag(badgesTag);
    msg.isFirstMessage = [s7tv_tagValue(tags, @"first-msg", @"0") isEqualToString:@"1"];

    // Les récompenses automatiques (highlight, contournement du mode sub)
    // marquent directement leur PRIVMSG avec un msg-id fixe. Le chemin
    // PubSub construit aussi leur bandeau riche ; celui-ci sert de repli
    // immédiat et apporte surtout les badges/emotes lors de la fusion.
    S7TVChannelPointRewardInfo *automaticReward =
        s7tv_automaticRewardInfoForIRCMessageID(ircMessageID);
    if (automaticReward) {
        msg.type = S7TVChatMessageTypeChannelPointRedemption;
        msg.channelPointRewardInfo = automaticReward;
        // Même clé que l'événement PubSub automatique : le PRIVMSG attend
        // brièvement celui-ci afin de fusionner ses badges/emotes dans le
        // bandeau riche au lieu d'afficher deux lignes.
        msg.channelPointRewardID = automaticReward.rewardID;
    }

    // Détection self-mention : scan des tokens .mention déjà résolus par le
    // tokenizer (@pseudo ET pseudo nu — voir S7TVChatToken), comparés au
    // pseudo du viewer connecté (voir s7tv_handleUserState plus bas dans ce
    // fichier). nil/vide tant qu'aucun USERSTATE n'a encore été observé →
    // mentionsCurrentViewer reste NO par défaut, jamais de faux positif.
    NSString *viewerName = [SevenTVManager sharedManager].currentViewerDisplayName;
    if (viewerName.length) {
        for (S7TVChatToken *token in msg.tokens) {
            if (token.type != S7TVChatTokenTypeMention) continue;
            NSString *mentionedName = token.text ?: @"";
            if ([mentionedName hasPrefix:@"@"]) {
                mentionedName = [mentionedName substringFromIndex:1];
            }
            if ([mentionedName caseInsensitiveCompare:viewerName] == NSOrderedSame) {
                msg.mentionsCurrentViewer = YES;
                break;
            }
        }
    }

    return msg;
}

// ────────────────────────────────────────────────────────────
// MARK: - Parsing IRC USERNOTICE (Phase 3 — sub / resub / gift sub)
// ────────────────────────────────────────────────────────────
//
// system-msg= n'est PAS utilisé comme source du texte affiché : c'est un
// fallback généré serveur, alors que le rendu natif Twitch (screenshots
// Knoks, Phase 3) est reconstruit en français à partir des msg-param-*.
// Périmètre actuel : sub/resub + gift communautaire (submysterygift).
// Subgift ciblé (1 destinataire nommé) hors périmètre — pas de screenshot
// de référence pour cette formulation, voir plan §Phase 3.

static NSString *s7tv_pluralize(NSInteger count, NSString *singular, NSString *plural) {
    return (count == 1) ? singular : plural;
}

static NSInteger s7tv_tierFromSubPlan(NSString *subPlan) {
    if ([subPlan isEqualToString:@"2000"]) return 2;
    if ([subPlan isEqualToString:@"3000"]) return 3;
    return 1; // "1000", "Prime", ou absent → niveau 1
}

// Ordinal du mois d'abonnement — "24e" en français, "24th" en anglais.
// Seul le compte de mois cumulés (celui qui exprime "c'est son Ne mois")
// utilise un ordinal ; le streak (voir sysmsg_streak_clause_format) est
// resté en nombre cardinal simple dans les deux langues — l'ancien code
// appliquait aussi un "e" français au streak ("dont 6e mois consécutifs"),
// peu naturel, corrigé au passage de la localisation ("dont 6 mois
// consécutifs").
static NSString *s7tv_ordinalMonthString(NSInteger months) {
    if ([S7TVLocalization shared].currentLanguage == S7TVLanguageEnglish) {
        NSInteger mod100 = months % 100;
        NSString *suffix;
        if (mod100 >= 11 && mod100 <= 13) {
            suffix = @"th";
        } else {
            switch (months % 10) {
                case 1:  suffix = @"st"; break;
                case 2:  suffix = @"nd"; break;
                case 3:  suffix = @"rd"; break;
                default: suffix = @"th"; break;
            }
        }
        return [NSString stringWithFormat:@"%ld%@", (long)months, suffix];
    }
    return [NSString stringWithFormat:@"%lde", (long)months];
}

// Reproduit les formulations observées sur screenshots (voir 7tv-localization.m,
// section "Messages système sub/resub/gift", pour le détail des deux langues) :
//   - resub payant : "<verbe> <plan>. C'est son Ne mois d'abonnement, dont S
//     mois consécutifs !" (clause streak seulement si should-share-streak=1)
//   - resub Prime : "<verbe> avec Prime. C'est son Ne mois d'abonnement !"
//   - premier sub (cumulative<=1) : même verbe/plan, sans la phrase "Ne mois".
//   - gift communautaire : "offre N abonnement(s) de niveau X à la
//     communauté de {chaîne}. Cet utilisateur a déjà offert M abonnement(s)
//     sur cette chaîne !"
// Localisé via L() (suit le toggle FR/EN interne du tweak) plutôt que lu
// depuis system-msg= IRC — voir le commentaire en tête de fichier sur ce
// choix : system-msg est un texte de secours serveur non stylable (pseudo
// non extractible pour le gras/couleur) et pas garanti dans la langue voulue,
// alors que le natif Twitch lui-même reconstruit cette phrase depuis les
// mêmes champs msg-param-* qu'on utilise ici.
static NSString *s7tv_buildSystemMessagePhrase(S7TVSystemMessageInfo *info) {
    if (info.kind == S7TVSystemMessageKindCommunityGift) {
        NSString *giftWord   = s7tv_pluralize(info.massGiftCount,
            L(@"sysmsg_word_sub_singular"), L(@"sysmsg_word_sub_plural"));
        NSString *senderWord = s7tv_pluralize(info.senderTotalGiftCount,
            L(@"sysmsg_word_sub_singular"), L(@"sysmsg_word_sub_plural"));
        return [NSString stringWithFormat:L(@"sysmsg_gift_format"),
            (long)info.massGiftCount, giftWord, (long)info.tier,
            info.channelDisplayName ?: L(@"sysmsg_fallback_channel"),
            (long)info.senderTotalGiftCount, senderWord];
    }

    NSString *planPhrase = info.isPrime
        ? L(@"sysmsg_plan_prime")
        : [NSString stringWithFormat:L(@"sysmsg_plan_tier_format"), (long)info.tier];
    NSString *verb = info.isPrime ? L(@"sysmsg_verb_sub_prime") : L(@"sysmsg_verb_sub_tier");

    if (info.cumulativeMonths <= 1) {
        return [NSString stringWithFormat:L(@"sysmsg_first_sub_format"), verb, planPhrase];
    }

    NSString *streakClause = (info.streakMonths > 0)
        ? [NSString stringWithFormat:L(@"sysmsg_streak_clause_format"), (long)info.streakMonths]
        : @"";
    NSString *monthOrdinal = s7tv_ordinalMonthString(info.cumulativeMonths);
    return [NSString stringWithFormat:L(@"sysmsg_resub_format"),
        verb, planPhrase, monthOrdinal, streakClause];
}

// Parse une ligne IRC complète et retourne un S7TVChatMessage de type
// .system si c'est un USERNOTICE exploitable (sub/resub/gift communautaire),
// nil sinon — même contrat que s7tv_parsePRIVMSG (jamais de message à
// moitié rempli).
static S7TVChatMessage * _Nullable s7tv_parseUSERNOTICE(NSString *ircLine) {
    if (![ircLine containsString:@"USERNOTICE"]) return nil;
    if (![ircLine hasPrefix:@"@"]) return nil; // pas de tags → pas de msg-id exploitable

    NSRange firstSpace = [ircLine rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return nil;
    NSDictionary<NSString *, NSString *> *tags =
        s7tv_parseIRCTags([ircLine substringWithRange:NSMakeRange(1, firstSpace.location - 1)]);
    NSString *rest = [ircLine substringFromIndex:firstSpace.location + 1];

    NSString *msgID = s7tv_tagValue(tags, @"msg-id", @"");
    S7TVSystemMessageKind kind;
    if ([msgID isEqualToString:@"sub"] || [msgID isEqualToString:@"resub"]) {
        kind = S7TVSystemMessageKindSubOrResub;
    } else if ([msgID isEqualToString:@"submysterygift"]) {
        kind = S7TVSystemMessageKindCommunityGift;
    } else {
        return nil; // subgift ciblé, raid, giftpaidupgrade... hors périmètre pour l'instant
    }

    // Même garde-fou changement de chaîne que s7tv_parsePRIVMSG — voir le
    // commentaire détaillé là-bas.
    NSRange usernoticeRange = [rest rangeOfString:@"USERNOTICE"];
    if (usernoticeRange.location == NSNotFound) return nil;
    NSRange searchRange = NSMakeRange(usernoticeRange.location, rest.length - usernoticeRange.location);
    NSRange textMarker = [rest rangeOfString:@" :" options:0 range:searchRange];
    NSUInteger channelTokenEnd = (textMarker.location != NSNotFound) ? textMarker.location : rest.length;
    NSUInteger channelTokenStart = usernoticeRange.location + usernoticeRange.length + 1;
    // Le texte après " :" est optionnel pour un USERNOTICE (commentaire de
    // l'utilisateur ajouté à son propre resub, ex: "ouais") — contrairement
    // à PRIVMSG où son absence invalide le message.
    NSString *messageText = (textMarker.location != NSNotFound)
        ? [rest substringFromIndex:textMarker.location + 2] : @"";

    if (channelTokenStart <= channelTokenEnd) {
        NSString *channelToken = [rest substringWithRange:
            NSMakeRange(channelTokenStart, channelTokenEnd - channelTokenStart)];
        channelToken = [channelToken stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([channelToken hasPrefix:@"#"]) channelToken = [channelToken substringFromIndex:1];
        NSString *activeChannel = [SevenTVManager sharedManager].currentChannelName;
        if (channelToken.length && activeChannel.length &&
            [channelToken caseInsensitiveCompare:activeChannel] != NSOrderedSame) {
            return nil;
        }
    }

    NSString *messageID   = s7tv_tagValue(tags, @"id", [[NSUUID UUID] UUIDString]);
    NSString *userID      = s7tv_tagValue(tags, @"user-id", @"");
    NSString *displayName = s7tv_tagValue(tags, @"display-name", @"???");
    NSString *colorHex    = s7tv_tagValue(tags, @"color", @"");
    NSString *badgesTag   = s7tv_tagValue(tags, @"badges", @"");
    NSString *subPlan     = s7tv_tagValue(tags, @"msg-param-sub-plan", @"1000");

    S7TVSystemMessageInfo *info = [S7TVSystemMessageInfo new];
    info.kind    = kind;
    info.isPrime = [subPlan isEqualToString:@"Prime"];
    info.tier    = s7tv_tierFromSubPlan(subPlan);

    if (kind == S7TVSystemMessageKindSubOrResub) {
        info.cumulativeMonths = [s7tv_tagValue(tags, @"msg-param-cumulative-months", @"1") integerValue];
        BOOL shareStreak = [s7tv_tagValue(tags, @"msg-param-should-share-streak", @"0") integerValue] != 0;
        info.streakMonths = shareStreak
            ? [s7tv_tagValue(tags, @"msg-param-streak-months", @"0") integerValue] : 0;
    } else {
        info.massGiftCount = MAX(1, [s7tv_tagValue(tags, @"msg-param-mass-gift-count", @"1") integerValue]);
        info.senderTotalGiftCount = [s7tv_tagValue(tags, @"msg-param-sender-count", @"0") integerValue];
        info.channelDisplayName = [SevenTVManager sharedManager].currentChannelName ?: L(@"sysmsg_fallback_channel");
    }

    S7TVChatMessage *msg = [[S7TVChatMessage alloc] initWithMessageID:messageID
                                                             timestamp:s7tv_messageTimestampFromTags(tags)
                                                          authorUserID:userID
                                                     authorDisplayName:displayName
                                                               rawText:messageText];
    msg.type         = S7TVChatMessageTypeSystem;
    msg.systemInfo   = info;
    msg.systemPhrase = s7tv_buildSystemMessagePhrase(info);

    msg.authorColor = s7tv_colorFromHexString(colorHex);

    // Commentaire optionnel attaché (ex: resub avec message) — tokenisé
    // comme un message normal, rendu sous la bannière système (voir
    // SevenTVChatCustomView, s7tv_appendNormalBodyForMessage:into:...).
    if (messageText.length) {
        msg.tokens = s7tv_tokenizeMessageWithNativeEmotes(messageText,
                                                            s7tv_tagValue(tags, @"emotes", @""));
    }
    msg.badgeIdentifiers = s7tv_parseBadgesTag(badgesTag);

    return msg;
}


// ────────────────────────────────────────────────────────────
// MARK: - Récompenses de points de chaîne (PubSub reward-redeemed)
// ────────────────────────────────────────────────────────────

static id _Nullable s7tv_JSONValueForKeys(NSDictionary *dictionary,
                                           NSArray<NSString *> *keys) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (value && value != [NSNull null]) return value;
    }
    return nil;
}

static NSString *s7tv_JSONStringForKeys(NSDictionary *dictionary,
                                        NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static NSDictionary * _Nullable s7tv_JSONDictionaryForKeys(NSDictionary *dictionary,
                                                            NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSInteger s7tv_JSONIntegerForKeys(NSDictionary *dictionary,
                                         NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static BOOL s7tv_JSONBoolForKeys(NSDictionary *dictionary,
                                 NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

// Twitch alterne snake_case (PubSub) et camelCase (GQL) pour les mêmes
// images. Cette sélection unique accepte les deux schémas, préfère le 2x
// adapté à la petite icône du chat, puis retombe proprement sur 1x/4x.
static NSString *s7tv_channelPointImageURLString(NSDictionary *image) {
    return s7tv_JSONStringForKeys(image, @[
        @"url_2x", @"url2x", @"url", @"url_1x", @"url1x", @"url_4x", @"url4x"
    ]);
}

static NSURL * _Nullable s7tv_channelPointImageURL(NSDictionary *reward) {
    NSDictionary *image = s7tv_JSONDictionaryForKeys(reward, @[@"image"]);
    NSString *urlString = s7tv_channelPointImageURLString(image);
    if (!urlString.length) {
        NSDictionary *defaultImage = s7tv_JSONDictionaryForKeys(reward,
            @[@"default_image", @"defaultImage"]);
        urlString = s7tv_channelPointImageURLString(defaultImage);
    }
    return urlString.length ? [NSURL URLWithString:urlString] : nil;
}

static NSDictionary * _Nullable s7tv_findCommunityPointSettingsDictionary(
    id object, NSString * _Nullable * _Nullable outChannelID) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        NSDictionary *settings = s7tv_JSONDictionaryForKeys(dictionary,
            @[@"communityPointsSettings", @"community_points_settings"]);
        if (settings.count) {
            if (outChannelID) {
                NSString *channelID = s7tv_JSONStringForKeys(dictionary, @[
                    @"id", @"channelID", @"channel_id",
                    @"broadcasterUserID", @"broadcaster_user_id"
                ]);
                *outChannelID = channelID.length ? channelID : nil;
            }
            return settings;
        }
        if ([dictionary[@"automaticRewards"] isKindOfClass:[NSArray class]] ||
            [dictionary[@"customRewards"] isKindOfClass:[NSArray class]]) {
            return dictionary;
        }
        for (id value in dictionary.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] ||
                [value isKindOfClass:[NSArray class]]) {
                NSDictionary *found =
                    s7tv_findCommunityPointSettingsDictionary(value, outChannelID);
                if (found) return found;
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            NSDictionary *found =
                s7tv_findCommunityPointSettingsDictionary(value, outChannelID);
            if (found) return found;
        }
    }
    return nil;
}

// Champ confirmé sur le payload Twitch réel : communityPointsSettings.image.
// Il contient l'icône de monnaie personnalisée de la chaîne. Ne jamais
// parcourir automaticRewards/customRewards : leurs images appartiennent au
// picker (stylo, highlight, etc.), pas au coût affiché dans le chat.
static NSURL * _Nullable s7tv_findChannelPointCurrencyImageURL(
    id object, NSString * _Nullable * _Nullable outChannelID) {
    NSDictionary *settings =
        s7tv_findCommunityPointSettingsDictionary(object, outChannelID);
    NSDictionary *image = s7tv_JSONDictionaryForKeys(settings, @[@"image"]);
    NSString *urlString = s7tv_channelPointImageURLString(image);
    return urlString.length ? [NSURL URLWithString:urlString] : nil;
}

// Amorcer le cache dès la réponse GQL évite que le premier redemption doive
// attendre son propre cycle cellule -> téléchargement -> reconfiguration.
// L'adaptateur et le cache utilisent l'URL Twitch reçue à l'exécution : aucune
// URL ni aucune icône de chaîne n'est codée en dur.
static void s7tv_preloadChannelPointCurrencyImage(NSURL *imageURL) {
    if (!imageURL.absoluteString.length) return;
    S7TVChannelPointRewardInfo *imageAdapter = [S7TVChannelPointRewardInfo new];
    imageAdapter.rewardID = imageURL.absoluteString;
    imageAdapter.imageURL = imageURL;
    [[SevenTVEmoteImageCache sharedCache]
        imageForResolvedEmote:imageAdapter
        completion:^(UIImage * _Nullable image) {
            if (image) s7tv_scheduleChatCustomReload();
        }];
}

// ── Catalogue des récompenses automatiques Twitch ──────────────────────
// ChannelPointsQuery fournit coût/image/couleur des récompenses automatiques;
// le type de protocole relie ce catalogue aux événements PubSub et msg-id IRC.

static NSMutableDictionary<NSString *, S7TVChannelPointRewardInfo *> *
s7tv_automaticRewardCatalog(void) {
    static NSMutableDictionary<NSString *, S7TVChannelPointRewardInfo *> *catalog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ catalog = [NSMutableDictionary dictionary]; });
    return catalog;
}

static NSString *s7tv_automaticRewardCatalogChannelID = nil;
static NSURL *s7tv_automaticRewardCurrencyImageURL = nil;

static NSURL * _Nullable s7tv_currentChannelPointCurrencyImageURL(void) {
    NSMutableDictionary *catalog = s7tv_automaticRewardCatalog();
    @synchronized (catalog) {
        NSString *currentChannelID = [SevenTVManager sharedManager].currentChannelTwitchID;
        BOOL sameChannel = !currentChannelID.length ||
            !s7tv_automaticRewardCatalogChannelID.length ||
            [currentChannelID isEqualToString:s7tv_automaticRewardCatalogChannelID];
        return sameChannel ? [s7tv_automaticRewardCurrencyImageURL copy] : nil;
    }
}

static NSString * _Nullable s7tv_automaticRewardTitleLocalizationKey(NSString *type) {
    if ([type isEqualToString:@"SINGLE_MESSAGE_BYPASS_SUB_MODE"])
        return @"channel_points_auto_bypass_sub_mode";
    if ([type isEqualToString:@"SEND_HIGHLIGHTED_MESSAGE"])
        return @"channel_points_auto_highlight_message";
    return nil;
}

static NSString *s7tv_normalizedAutomaticRewardType(NSString *rawType) {
    if (!rawType.length) return @"";
    NSString *type = rawType.uppercaseString;
    type = [type stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    type = [type stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    if ([type isEqualToString:@"SKIP_SUBS_MODE_MESSAGE"] ||
        [type isEqualToString:@"SINGLE_MESSAGE_BYPASS_SUBS_MODE"]) {
        return @"SINGLE_MESSAGE_BYPASS_SUB_MODE";
    }
    if ([type isEqualToString:@"HIGHLIGHTED_MESSAGE"]) {
        return @"SEND_HIGHLIGHTED_MESSAGE";
    }
    return type;
}

static NSString * _Nullable s7tv_automaticRewardTypeForIRCMessageID(NSString *messageID) {
    NSString *type = s7tv_normalizedAutomaticRewardType(messageID);
    return s7tv_automaticRewardTitleLocalizationKey(type).length ? type : nil;
}

static S7TVChannelPointRewardInfo * _Nullable s7tv_copyChannelPointRewardInfo(
    S7TVChannelPointRewardInfo * _Nullable source) {
    if (!source) return nil;
    S7TVChannelPointRewardInfo *copy = [S7TVChannelPointRewardInfo new];
    copy.rewardID = source.rewardID ?: @"";
    copy.title = source.title ?: @"";
    copy.titleLocalizationKey = source.titleLocalizationKey;
    copy.prompt = source.prompt;
    copy.cost = source.cost;
    copy.pricingType = source.pricingType ?: @"";
    copy.isUserInputRequired = source.isUserInputRequired;
    copy.userInput = source.userInput;
    copy.accentColor = source.accentColor;
    if (source.imageURL) copy.imageURL = source.imageURL;
    return copy;
}

static S7TVChannelPointRewardInfo * _Nullable
s7tv_automaticRewardInfoForType(NSString *rawType) {
    NSString *type = s7tv_normalizedAutomaticRewardType(rawType);
    if (!type.length) return nil;
    NSString *titleKey = s7tv_automaticRewardTitleLocalizationKey(type);
    if (!titleKey.length) return nil;

    NSMutableDictionary *catalog = s7tv_automaticRewardCatalog();
    S7TVChannelPointRewardInfo *info = nil;
    NSURL *currencyImageURL = nil;
    @synchronized (catalog) {
        NSString *currentChannelID = [SevenTVManager sharedManager].currentChannelTwitchID;
        BOOL catalogMatchesChannel = !currentChannelID.length ||
            !s7tv_automaticRewardCatalogChannelID.length ||
            [currentChannelID isEqualToString:s7tv_automaticRewardCatalogChannelID];
        if (catalogMatchesChannel) {
            info = s7tv_copyChannelPointRewardInfo(catalog[type]);
            currencyImageURL = [s7tv_automaticRewardCurrencyImageURL copy];
        }
    }

    // Le PRIVMSG peut précéder ChannelPointsQuery, ou cette requête peut ne
    // jamais être rejouée après l'installation du tweak. Le type IRC suffit
    // à identifier l'action : on rend donc immédiatement le bandeau, puis
    // l'événement PubSub l'enrichit avec son coût et le catalogue avec son
    // image/couleur lorsqu'ils sont disponibles.
    if (!info) info = [S7TVChannelPointRewardInfo new];
    info.rewardID = type;
    info.title = @"";
    info.titleLocalizationKey = titleKey;
    if (!info.pricingType.length) info.pricingType = @"CHANNEL_POINTS";
    info.isUserInputRequired = YES;
    if (currencyImageURL) info.imageURL = currencyImageURL;
    return info;
}

static S7TVChannelPointRewardInfo * _Nullable
s7tv_automaticRewardInfoForIRCMessageID(NSString *messageID) {
    NSString *type = s7tv_automaticRewardTypeForIRCMessageID(messageID);
    return type.length ? s7tv_automaticRewardInfoForType(type) : nil;
}

static void s7tv_collectAutomaticRewardDictionaries(id object,
                                                     NSMutableArray<NSDictionary *> *rewards) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        id automaticRewards = dictionary[@"automaticRewards"];
        if ([automaticRewards isKindOfClass:[NSArray class]]) {
            for (id reward in (NSArray *)automaticRewards) {
                if ([reward isKindOfClass:[NSDictionary class]]) [rewards addObject:reward];
            }
        }
        for (id value in dictionary.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] ||
                [value isKindOfClass:[NSArray class]]) {
                s7tv_collectAutomaticRewardDictionaries(value, rewards);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            s7tv_collectAutomaticRewardDictionaries(value, rewards);
        }
    }
}

static void s7tv_ingestAutomaticRewardsFromGQLData(NSData *data) {
    if (!data.length) return;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    BOOL containsAutomaticRewards = [raw containsString:@"automaticRewards"];
    BOOL containsPointSettings = [raw containsString:@"communityPointsSettings"] ||
                                 [raw containsString:@"community_points_settings"];
    if (!containsAutomaticRewards && !containsPointSettings) return;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!root) return;
    NSString *payloadChannelID = nil;
    NSURL *currencyImageURL =
        s7tv_findChannelPointCurrencyImageURL(root, &payloadChannelID);

    NSMutableArray<NSDictionary *> *rawRewards = [NSMutableArray array];
    if (containsAutomaticRewards) {
        s7tv_collectAutomaticRewardDictionaries(root, rawRewards);
    }

    NSMutableDictionary *catalog = s7tv_automaticRewardCatalog();
    NSString *currentChannelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    NSString *resolvedChannelID = payloadChannelID.length
        ? payloadChannelID : currentChannelID;
    NSURL *resolvedCurrencyImageURL = currencyImageURL;
    @synchronized (catalog) {
        BOOL sameChannel = !resolvedChannelID.length ||
            !s7tv_automaticRewardCatalogChannelID.length ||
            [resolvedChannelID isEqualToString:s7tv_automaticRewardCatalogChannelID];
        if (!resolvedCurrencyImageURL && sameChannel) {
            resolvedCurrencyImageURL = [s7tv_automaticRewardCurrencyImageURL copy];
        }
        if (!rawRewards.count && currencyImageURL) {
            if (!sameChannel) [catalog removeAllObjects];
            s7tv_automaticRewardCatalogChannelID = [resolvedChannelID copy] ?: @"";
            s7tv_automaticRewardCurrencyImageURL = [currencyImageURL copy];
            for (S7TVChannelPointRewardInfo *existingInfo in catalog.allValues) {
                if ([existingInfo.pricingType caseInsensitiveCompare:@"BITS"] != NSOrderedSame) {
                    existingInfo.imageURL = currencyImageURL;
                }
            }
        }
    }
    if (!rawRewards.count) {
        if (currencyImageURL) {
            s7tv_preloadChannelPointCurrencyImage(currencyImageURL);
            BOOL payloadMatchesCurrentChannel = !payloadChannelID.length ||
                !currentChannelID.length ||
                [payloadChannelID isEqualToString:currentChannelID];
            if (payloadMatchesCurrentChannel) {
                [[SevenTVManager sharedManager].chatMessageStore
                    updateChannelPointCurrencyImageURL:currencyImageURL
                    completion:^{ s7tv_scheduleChatCustomReload(); }];
            }
        }
        return;
    }

    NSMutableDictionary<NSString *, S7TVChannelPointRewardInfo *> *nextCatalog =
        [NSMutableDictionary dictionary];
    for (NSDictionary *reward in rawRewards) {
        NSString *type = s7tv_normalizedAutomaticRewardType(
            s7tv_JSONStringForKeys(reward, @[@"type"]));
        if (!type.length) continue;
        S7TVChannelPointRewardInfo *info = [S7TVChannelPointRewardInfo new];
        info.rewardID = type;
        info.title = @"";
        info.titleLocalizationKey = s7tv_automaticRewardTitleLocalizationKey(type);
        info.pricingType = s7tv_JSONStringForKeys(reward, @[@"pricingType", @"pricing_type"]);
        BOOL usesBits = [info.pricingType caseInsensitiveCompare:@"BITS"] == NSOrderedSame;
        info.cost = usesBits
            ? s7tv_JSONIntegerForKeys(reward, @[@"bitsCost", @"bits_cost"])
            : s7tv_JSONIntegerForKeys(reward, @[@"cost"]);
        if (info.cost <= 0) {
            info.cost = usesBits
                ? s7tv_JSONIntegerForKeys(reward, @[@"defaultBitsCost", @"default_bits_cost"])
                : s7tv_JSONIntegerForKeys(reward, @[@"defaultCost", @"default_cost"]);
        }
        NSString *backgroundHex = s7tv_JSONStringForKeys(reward,
            @[@"backgroundColor", @"background_color"]);
        if (!backgroundHex.length) {
            backgroundHex = s7tv_JSONStringForKeys(reward,
                @[@"defaultBackgroundColor", @"default_background_color"]);
        }
        info.accentColor = s7tv_colorFromHexString(backgroundHex);
        // Pour les récompenses payées en points, Twitch PC affiche l'icône
        // de la monnaie de la chaîne devant le coût. L'image automatique
        // (highlight/subsonly) appartient au picker et ne doit pas apparaître
        // dans la ligne de chat. Les Power-ups Bits conservent leur image.
        NSURL *imageURL = usesBits
            ? s7tv_channelPointImageURL(reward)
            : resolvedCurrencyImageURL;
        if (imageURL) info.imageURL = imageURL;
        // Ces msg-id accompagnent toujours le texte saisi par l'utilisateur.
        info.isUserInputRequired = info.titleLocalizationKey.length > 0;
        nextCatalog[type] = info;
    }

    if (!nextCatalog.count) return;
    @synchronized (catalog) {
        [catalog setDictionary:nextCatalog];
        s7tv_automaticRewardCatalogChannelID = [resolvedChannelID copy] ?: @"";
        s7tv_automaticRewardCurrencyImageURL = [resolvedCurrencyImageURL copy];
    }
    if (resolvedCurrencyImageURL) {
        s7tv_preloadChannelPointCurrencyImage(resolvedCurrencyImageURL);
        BOOL payloadMatchesCurrentChannel = !payloadChannelID.length ||
            !currentChannelID.length ||
            [payloadChannelID isEqualToString:currentChannelID];
        if (payloadMatchesCurrentChannel) {
            [[SevenTVManager sharedManager].chatMessageStore
                updateChannelPointCurrencyImageURL:resolvedCurrencyImageURL
                completion:^{ s7tv_scheduleChatCustomReload(); }];
        }
    }
}

static NSDate *s7tv_channelPointTimestamp(NSString *rawTimestamp) {
    if (!rawTimestamp.length) return [NSDate date];
    static NSISO8601DateFormatter *withFractions = nil;
    static NSISO8601DateFormatter *withoutFractions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        withFractions = [NSISO8601DateFormatter new];
        withFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                      NSISO8601DateFormatWithFractionalSeconds;
        withoutFractions = [NSISO8601DateFormatter new];
        withoutFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    NSDate *date = nil;
    @synchronized (withFractions) {
        date = [withFractions dateFromString:rawTimestamp];
        if (!date) date = [withoutFractions dateFromString:rawTimestamp];
    }
    return date ?: [NSDate date];
}

// Une récompense avec saisie produit généralement deux transports pour le
// même contenu : reward-redeemed (PubSub, riche en métadonnées) puis un
// PRIVMSG custom-reward-id (IRC, riche en badges/emotes). On mémorise
// brièvement le couple utilisateur/récompense déjà rendu par PubSub pour
// supprimer uniquement son PRIVMSG compagnon, jamais le chat normal.
static NSString *s7tv_channelPointCompanionKey(NSString *userID, NSString *rewardID) {
    if (!userID.length || !rewardID.length) return @"";
    return [NSString stringWithFormat:@"%@|%@", userID, rewardID];
}

static NSMutableDictionary<NSString *, NSDate *> *s7tv_recentChannelPointCompanions(void) {
    static NSMutableDictionary<NSString *, NSDate *> *entries = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ entries = [NSMutableDictionary dictionary]; });
    return entries;
}

static void s7tv_registerChannelPointCompanionToSuppress(NSString *userID,
                                                          NSString *rewardID) {
    NSString *key = s7tv_channelPointCompanionKey(userID, rewardID);
    if (!key.length) return;
    NSMutableDictionary *entries = s7tv_recentChannelPointCompanions();
    @synchronized (entries) {
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8.0];
        for (NSString *existingKey in [entries.allKeys copy]) {
            if ([entries[existingKey] compare:cutoff] == NSOrderedAscending) {
                [entries removeObjectForKey:existingKey];
            }
        }
        entries[key] = [NSDate date];
    }
}

static BOOL s7tv_shouldSuppressChannelPointCompanion(S7TVChatMessage *message) {
    NSString *key = s7tv_channelPointCompanionKey(message.authorUserID,
                                                   message.channelPointRewardID);
    if (!key.length) return NO;
    NSMutableDictionary *entries = s7tv_recentChannelPointCompanions();
    @synchronized (entries) {
        NSDate *date = entries[key];
        return date && [[NSDate date] timeIntervalSinceDate:date] <= 8.0;
    }
}

static S7TVChatMessage * _Nullable s7tv_channelPointMessageFromRedemption(
    NSDictionary *redemption) {
    if (![redemption isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
    NSDictionary *user = s7tv_JSONDictionaryForKeys(redemption, @[@"user"]);
    NSString *redemptionID = s7tv_JSONStringForKeys(redemption, @[@"id"]);
    NSString *rewardID = s7tv_JSONStringForKeys(reward, @[@"id"]);
    NSString *title = s7tv_JSONStringForKeys(reward, @[@"title"]);
    if (!redemptionID.length || !rewardID.length || !title.length) return nil;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSString *channelID = s7tv_JSONStringForKeys(redemption, @[@"channel_id", @"channelID"]);
    if (!channelID.length) {
        channelID = s7tv_JSONStringForKeys(reward, @[@"channel_id", @"channelID"]);
    }
    if (channelID.length && manager.currentChannelTwitchID.length &&
        ![channelID isEqualToString:manager.currentChannelTwitchID]) {
        return nil;
    }

    NSString *userID = s7tv_JSONStringForKeys(user, @[@"id"]);
    NSString *displayName = s7tv_JSONStringForKeys(user, @[@"display_name", @"displayName"]);
    if (!displayName.length) displayName = s7tv_JSONStringForKeys(user, @[@"login"]);
    if (!displayName.length) displayName = @"???";

    S7TVChannelPointRewardInfo *info = [S7TVChannelPointRewardInfo new];
    info.rewardID = rewardID;
    info.title = title;
    info.prompt = s7tv_JSONStringForKeys(reward, @[@"prompt"]);
    info.pricingType = s7tv_JSONStringForKeys(reward, @[@"pricing_type", @"pricingType"]);
    info.cost = s7tv_JSONIntegerForKeys(reward, @[@"cost"]);
    if (info.cost <= 0 && [info.pricingType caseInsensitiveCompare:@"BITS"] == NSOrderedSame) {
        info.cost = s7tv_JSONIntegerForKeys(reward, @[@"bits_cost", @"bitsCost"]);
    }
    info.isUserInputRequired = s7tv_JSONBoolForKeys(reward,
        @[@"is_user_input_required", @"isUserInputRequired"]);
    NSString *userInput = s7tv_JSONStringForKeys(redemption,
        @[@"user_input", @"userInput"]);
    info.userInput = userInput.length ? userInput : nil;
    info.accentColor = s7tv_colorFromHexString(s7tv_JSONStringForKeys(reward,
        @[@"background_color", @"backgroundColor"]));
    // Même visuel que les récompenses automatiques dans le chat Twitch PC :
    // l'icône de la monnaie de la chaîne, jamais l'illustration du bouton de
    // récompense personnalisée affichée dans le picker.
    NSURL *currencyImageURL = s7tv_currentChannelPointCurrencyImageURL();
    if (currencyImageURL) info.imageURL = currencyImageURL;

    NSString *rawTimestamp = s7tv_JSONStringForKeys(redemption,
        @[@"redeemed_at", @"redeemedAt"]);
    S7TVChatMessage *message = [[S7TVChatMessage alloc]
        initWithMessageID:redemptionID
                timestamp:s7tv_channelPointTimestamp(rawTimestamp)
             authorUserID:userID ?: @""
        authorDisplayName:displayName
                  rawText:userInput ?: @""];
    message.type = S7TVChatMessageTypeChannelPointRedemption;
    message.channelPointRewardInfo = info;
    message.channelPointRewardID = rewardID;
    message.authorColor = [[SevenTVChatUserColorRegistry sharedRegistry]
        colorForUsername:displayName];
    if (userInput.length) {
        message.tokens = s7tv_tokenizeMessageWithNativeEmotes(userInput, @"");
        s7tv_registerChannelPointCompanionToSuppress(userID, rewardID);
    }
    return message;
}

static S7TVChatMessage * _Nullable s7tv_channelPointMessageFromAutomaticRedemption(
    NSDictionary *redemption) {
    if (![redemption isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
    NSString *automaticType = s7tv_normalizedAutomaticRewardType(
        s7tv_JSONStringForKeys(reward, @[@"type", @"id"]));
    S7TVChannelPointRewardInfo *info =
        s7tv_automaticRewardInfoForType(automaticType);
    if (!info) return nil; // Les unlocks personnels ne créent pas de ligne publique.

    NSString *redemptionID = s7tv_JSONStringForKeys(redemption, @[@"id"]);
    if (!redemptionID.length) return nil;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSString *channelID = s7tv_JSONStringForKeys(redemption,
        @[@"channel_id", @"channelID", @"broadcaster_user_id", @"broadcasterUserID"]);
    if (!channelID.length) {
        channelID = s7tv_JSONStringForKeys(reward, @[@"channel_id", @"channelID"]);
    }
    if (channelID.length && manager.currentChannelTwitchID.length &&
        ![channelID isEqualToString:manager.currentChannelTwitchID]) {
        return nil;
    }

    NSDictionary *user = s7tv_JSONDictionaryForKeys(redemption, @[@"user"]);
    NSString *userID = s7tv_JSONStringForKeys(user, @[@"id"]);
    if (!userID.length) {
        userID = s7tv_JSONStringForKeys(redemption, @[@"user_id", @"userID"]);
    }
    NSString *displayName = s7tv_JSONStringForKeys(user,
        @[@"display_name", @"displayName", @"login"]);
    if (!displayName.length) {
        displayName = s7tv_JSONStringForKeys(redemption,
            @[@"user_name", @"userName", @"user_login", @"userLogin"]);
    }
    if (!displayName.length) displayName = @"???";

    NSInteger eventCost = s7tv_JSONIntegerForKeys(reward,
        @[@"channel_points", @"channelPoints", @"cost"]);
    if (eventCost > 0) info.cost = eventCost;
    // Ne pas remplacer l'icône de monnaie par defaultImage de la récompense
    // automatique (le stylo/subsonly affiché dans le picker Twitch).
    NSString *backgroundHex = s7tv_JSONStringForKeys(reward,
        @[@"background_color", @"backgroundColor"]);
    UIColor *eventColor = s7tv_colorFromHexString(backgroundHex);
    if (eventColor) info.accentColor = eventColor;

    NSString *userInput = s7tv_JSONStringForKeys(redemption,
        @[@"user_input", @"userInput"]);
    NSDictionary *messagePayload = s7tv_JSONDictionaryForKeys(redemption, @[@"message"]);
    if (!userInput.length) {
        userInput = s7tv_JSONStringForKeys(messagePayload, @[@"text"]);
    }
    info.userInput = userInput.length ? userInput : nil;
    info.isUserInputRequired = YES;

    NSString *rawTimestamp = s7tv_JSONStringForKeys(redemption,
        @[@"redeemed_at", @"redeemedAt"]);
    S7TVChatMessage *message = [[S7TVChatMessage alloc]
        initWithMessageID:redemptionID
                timestamp:s7tv_channelPointTimestamp(rawTimestamp)
             authorUserID:userID ?: @""
        authorDisplayName:displayName
                  rawText:userInput ?: @""];
    message.type = S7TVChatMessageTypeChannelPointRedemption;
    message.channelPointRewardInfo = info;
    message.channelPointRewardID = automaticType;
    message.authorColor = [[SevenTVChatUserColorRegistry sharedRegistry]
        colorForUsername:displayName];
    if (userInput.length) {
        message.tokens = s7tv_tokenizeMessageWithNativeEmotes(userInput, @"");
        s7tv_registerChannelPointCompanionToSuppress(userID, automaticType);
    }
    return message;
}

static void s7tv_collectChannelPointMessages(id object,
                                              NSMutableArray<S7TVChatMessage *> *messages) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        NSString *type = s7tv_JSONStringForKeys(dictionary, @[@"type"]);
        if ([type isEqualToString:@"reward-redeemed"] ||
            [type isEqualToString:@"reward_redeemed"]) {
            NSDictionary *data = s7tv_JSONDictionaryForKeys(dictionary, @[@"data"]);
            NSDictionary *redemption = s7tv_JSONDictionaryForKeys(data, @[@"redemption"]);
            NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
            NSString *possibleAutomaticType = s7tv_normalizedAutomaticRewardType(
                s7tv_JSONStringForKeys(reward, @[@"type", @"id"]));
            BOOL isAutomatic =
                s7tv_automaticRewardTitleLocalizationKey(possibleAutomaticType).length > 0;
            S7TVChatMessage *message = isAutomatic
                ? s7tv_channelPointMessageFromAutomaticRedemption(redemption)
                : s7tv_channelPointMessageFromRedemption(redemption);
            if (message) [messages addObject:message];
            return;
        }
        NSString *lowerType = type.lowercaseString;
        BOOL isAutomaticRedemption =
            [lowerType containsString:@"automatic"] &&
            [lowerType containsString:@"reward"] &&
            [lowerType containsString:@"redeem"];
        if (isAutomaticRedemption) {
            NSDictionary *data = s7tv_JSONDictionaryForKeys(dictionary, @[@"data"]);
            NSDictionary *redemption = s7tv_JSONDictionaryForKeys(data, @[@"redemption"]);
            if (!redemption.count) redemption = s7tv_JSONDictionaryForKeys(data, @[@"event"]);
            if (!redemption.count) redemption = data;
            S7TVChatMessage *message =
                s7tv_channelPointMessageFromAutomaticRedemption(redemption);
            if (message) [messages addObject:message];
            return;
        }

        // EventSub place parfois le type de notification dans metadata et
        // livre directement l'objet event ici. Son reward.type est alors le
        // seul marqueur présent dans cette branche du JSON.
        NSDictionary *directReward = s7tv_JSONDictionaryForKeys(dictionary, @[@"reward"]);
        NSString *directAutomaticType = s7tv_normalizedAutomaticRewardType(
            s7tv_JSONStringForKeys(directReward, @[@"type"]));
        BOOL isDirectAutomaticEvent =
            s7tv_automaticRewardTitleLocalizationKey(directAutomaticType).length > 0 &&
            s7tv_JSONStringForKeys(dictionary, @[@"id"]).length > 0 &&
            s7tv_JSONStringForKeys(dictionary, @[@"redeemed_at", @"redeemedAt"]).length > 0;
        if (isDirectAutomaticEvent) {
            S7TVChatMessage *message =
                s7tv_channelPointMessageFromAutomaticRedemption(dictionary);
            if (message) [messages addObject:message];
            return;
        }

        [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            // L'enveloppe WebSocket Twitch place le vrai payload PubSub dans
            // une chaîne JSON. On ne reparcourt comme JSON que ce champ afin
            // de ne pas tenter de décoder chaque titre/prompt utilisateur.
            if ([key isKindOfClass:[NSString class]] &&
                [key caseInsensitiveCompare:@"pubsub"] == NSOrderedSame &&
                [value isKindOfClass:[NSString class]]) {
                NSData *nestedData = [value dataUsingEncoding:NSUTF8StringEncoding];
                id nested = nestedData.length
                    ? [NSJSONSerialization JSONObjectWithData:nestedData options:0 error:nil]
                    : nil;
                if (nested) s7tv_collectChannelPointMessages(nested, messages);
            } else if ([value isKindOfClass:[NSDictionary class]] ||
                       [value isKindOfClass:[NSArray class]]) {
                s7tv_collectChannelPointMessages(value, messages);
            }
        }];
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            s7tv_collectChannelPointMessages(value, messages);
        }
    }
}

static NSArray<S7TVChatMessage *> *s7tv_channelPointMessagesFromWebSocketText(
    NSString *text) {
    NSString *lower = text.lowercaseString;
    BOOL containsCustomRedemption = [lower containsString:@"reward-redeemed"] ||
                                    [lower containsString:@"reward_redeemed"];
    BOOL containsAutomaticRedemption = [lower containsString:@"automatic"] &&
                                       [lower containsString:@"reward"] &&
                                       [lower containsString:@"redeem"];
    if (!containsCustomRedemption && !containsAutomaticRedemption) return @[];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id root = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (!root) return @[];
    NSMutableArray<S7TVChatMessage *> *messages = [NSMutableArray array];
    s7tv_collectChannelPointMessages(root, messages);
    return messages;
}


// ────────────────────────────────────────────────────────────
// MARK: - Historique récent au JOIN
// ────────────────────────────────────────────────────────────
// Twitch IRC/Helix ne renvoie pas les messages antérieurs à la connexion.
// Recent Messages expose ces mêmes lignes au format IRC : elles repassent
// donc dans s7tv_parsePRIVMSG/s7tv_parseUSERNOTICE ci-dessus, sans second
// parseur ni rendu spécial pour les badges/emotes/réponses.
static NSUInteger s7tv_recentHistoryGeneration = 0;
// Dernier salon pour lequel le store a réellement été réinitialisé. Distinct
// de currentChannelTwitchID : ce dernier peut être prérempli par le cache ou
// GQL AVANT ROOMSTATE et ne constitue donc pas un signal de transition fiable.
static NSString *s7tv_recentHistoryInitializedChannel = nil;

static BOOL s7tv_recentHistoryRequestIsCurrent(NSString *channel, NSUInteger generation) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    @synchronized (mgr) {
        return generation == s7tv_recentHistoryGeneration &&
            channel.length &&
            [channel caseInsensitiveCompare:mgr.currentChannelName ?: @""] == NSOrderedSame;
    }
}

static void s7tv_fetchRecentHistory(NSString *channel, NSUInteger generation) {
    if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;

    NSString *urlString = [NSString stringWithFormat:
        @"https://recent-messages.robotty.de/api/v2/recent-messages/%@?limit=50&hideModerationMessages=true&hideModeratedMessages=true",
        channel.lowercaseString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 8.0;
    [request setValue:@"TwitchPlusK/1.0" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 || !data.length) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ Historique récent indisponible pour %@ (%@, HTTP %ld)",
                    channel, error.localizedDescription ?: @"réponse vide", (long)http.statusCode];
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSArray *rawMessages = [payload isKindOfClass:[NSDictionary class]] ? payload[@"messages"] : nil;
        if (jsonError || ![rawMessages isKindOfClass:[NSArray class]]) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ Historique récent invalide pour %@: %@",
                    channel, jsonError.localizedDescription ?: @"champ messages absent"];
            return;
        }

        NSMutableArray<S7TVChatMessage *> *history = [NSMutableArray arrayWithCapacity:rawMessages.count];
        for (id value in rawMessages) {
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *ircLine = [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
            S7TVChatMessage *message = s7tv_parsePRIVMSG(ircLine);
            if (!message) message = s7tv_parseUSERNOTICE(ircLine);
            if (message) {
                // Les messages live ont eux aussi un timestamp IRC. Ce flag
                // est donc la seule source fiable pour limiter l'affichage
                // HH:mm aux anciennes lignes chargées lors du JOIN.
                message.isHistorical = YES;
                [history addObject:message];
            }
        }
        [history sortUsingComparator:^NSComparisonResult(S7TVChatMessage *left,
                                                          S7TVChatMessage *right) {
            return [left.timestamp compare:right.timestamp];
        }];

        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
        [[SevenTVManager sharedManager].chatMessageStore
            prependHistoricalMessages:history completion:^{
                if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
                [[SevenTVManager sharedManager]
                    log:@"🕘 %lu messages historiques chargés pour %@",
                        (unsigned long)history.count, channel];
                s7tv_reloadActiveChatCustomView();
            }];
    }] resume];
}

static void s7tv_beginRecentHistory(NSString *channel, NSUInteger generation) {
    if (!channel.length) return;
    // Un fil ouvert appartient au store précédent, même quand le nouvel ID
    // broadcaster avait déjà été préchargé depuis le cache avant ROOMSTATE.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[S7TVReplyThreadPanel sharedPanel] hide];
    });
    NSDate *now = [NSDate date];
    S7TVChatMessage *welcome = [[S7TVChatMessage alloc]
        initWithMessageID:[NSString stringWithFormat:@"s7tv-history-welcome-%lu", (unsigned long)generation]
                timestamp:now
             authorUserID:@""
        authorDisplayName:@""
                  rawText:channel];
    welcome.type = S7TVChatMessageTypeHistoryWelcome;

    S7TVChatMessage *divider = [[S7TVChatMessage alloc]
        initWithMessageID:[NSString stringWithFormat:@"s7tv-history-divider-%lu", (unsigned long)generation]
                timestamp:now
             authorUserID:@""
        authorDisplayName:@""
                  rawText:@""];
    divider.type = S7TVChatMessageTypeHistoryDivider;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr.chatMessageStore replaceAllMessages:@[welcome, divider] completion:^{
        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
        [mgr log:@"🏗 Chat initialisé pour %@ (historique en cours)", channel];
        s7tv_reloadActiveChatCustomView();
        s7tv_fetchRecentHistory(channel, generation);
    }];
}

// Enregistre atomiquement une transition de salon et renvoie sa génération.
// `force=YES` correspond à un JOIN réellement envoyé : même une reconnexion
// au salon courant repart sur un transcript propre. ROOMSTATE utilise NO et
// ne sert que de filet de sécurité si le JOIN n'a exceptionnellement pas été
// observable par le hook.
static NSUInteger s7tv_registerRecentHistoryChannel(NSString *channel, BOOL force) {
    if (!channel.length) return 0;
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    @synchronized (mgr) {
        BOOL alreadyInitialized = s7tv_recentHistoryInitializedChannel.length &&
            [s7tv_recentHistoryInitializedChannel caseInsensitiveCompare:channel] == NSOrderedSame;
        if (!force && alreadyInitialized) return 0;
        s7tv_recentHistoryInitializedChannel = channel.lowercaseString;
        return ++s7tv_recentHistoryGeneration;
    }
}

static void s7tv_initializeRecentHistoryForChannel(NSString *channel, BOOL force) {
    NSUInteger generation = s7tv_registerRecentHistoryChannel(channel, force);
    if (generation > 0) {
        s7tv_beginRecentHistory(channel, generation);
    }
}

// Un envoi WebSocket IRC peut contenir plusieurs commandes séparées par
// CRLF (typiquement PART puis JOIN) et peut être transporté comme String ou
// Data. Retourne tous les salons réellement rejoints dans l'ordre du paquet.
static NSArray<NSString *> *s7tv_joinedChannelsInOutgoingWebSocketMessage(
    NSURLSessionWebSocketMessage *message) {
    NSString *payload = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        payload = message.string;
    } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
        payload = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
    }
    if (!payload.length) return @[];

    NSMutableArray<NSString *> *channels = [NSMutableArray array];
    NSArray<NSString *> *lines = [payload componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![line hasPrefix:@"JOIN #"]) continue;
        NSString *tail = [line substringFromIndex:6];
        NSRange end = [tail rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *channel = end.location == NSNotFound ? tail : [tail substringToIndex:end.location];
        channel = [channel stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (channel.length) [channels addObject:channel.lowercaseString];
    }
    return channels;
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
                NSString *sym = s7tv_isOrientationLocked() ? @"lock.rotation" : @"lock.rotation.open";
                UIImage *lockIcon = [UIImage systemImageNamed:sym withConfiguration:cfg];

                for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                                        @(UIControlStateSelected), @(UIControlStateDisabled)]) {
                    [shareBtn setImage:lockIcon forState:st.unsignedIntegerValue];
                }
                shareBtn.tintColor              = s7tv_isOrientationLocked()
                    ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
                    : [UIColor whiteColor];
                shareBtn.accessibilityLabel      = s7tv_isOrientationLocked()
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

    // Test de validation Phase 0 — gardé par le kill switch des Settings.
    // Ne cible QUE l'instance réelle (superview == UIStackView, alpha=1
    // sur toute la chaîne) — pas l'instance fantôme du pont SwiftUI
    // (Twitch.ChatTranscriptViewRepresentable), qu'on laisse intacte.
    if ([selfClass isEqualToString:@"Twitch.ChatTranscriptView"] && self.window) {
        if ([self.superview isKindOfClass:[UIStackView class]]) {
            s_activeNativeChatView = self;
            s7tv_applyChatCustomToggle();
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
                    s7tv_ingestAutomaticRewardsFromGQLData(data);
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
                    s7tv_ingestAutomaticRewardsFromGQLData(data);
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
            s7tv_ingestAutomaticRewardsFromGQLData(fullData);

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
                            S7TVChannelPointsClaimRetryCooldown, payloadDict];
                    }
                } else if (found && (!payload || [payload isKindOfClass:[NSNull class]])) {
                    // "data":{"claimCommunityPoints":null} — cas du
                    // IntegrityCheckFailed observé : la mutation entière a
                    // échoué avant même de produire un payload. On laisse
                    // le retry cooldown reprendre la main.
                    [[SevenTVManager sharedManager]
                        log:@"🎁 Channel Points debug: mutation rejetée par Twitch (claimCommunityPoints=null), nouvel essai dans %.0fs",
                        S7TVChannelPointsClaimRetryCooldown];
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
// MARK: - Extraction pseudo local depuis USERSTATE / GLOBALUSERSTATE
// ────────────────────────────────────────────────────────────
//
// GLOBALUSERSTATE arrive une fois juste après l'auth IRC (CAP + PASS/NICK),
// USERSTATE arrive à chaque JOIN et après chaque message envoyé par nous —
// les deux portent le tag display-name du compte connecté. Une seule
// fonction pour les deux : le check "USERSTATE" (substring) matche déjà
// GLOBALUSERSTATE puisqu'il se termine par "USERSTATE", donc pas besoin de
// distinguer les deux commandes, le contenu du tag est identique.
static void s7tv_handleUserState(NSString *ircLine) {
    if (![ircLine hasPrefix:@"@"]) return; // pas de tags → rien d'exploitable
    NSRange firstSpace = [ircLine rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return;

    NSDictionary<NSString *, NSString *> *tags =
        s7tv_parseIRCTags([ircLine substringWithRange:NSMakeRange(1, firstSpace.location - 1)]);
    NSString *displayName = s7tv_tagValue(tags, @"display-name", @"");
    if (!displayName.length) return;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if ([displayName isEqualToString:mgr.currentViewerDisplayName]) return; // déjà à jour
    mgr.currentViewerDisplayName = displayName;
    [mgr log:@"👤 Pseudo viewer connecté détecté (USERSTATE): %@", displayName];
}

// ────────────────────────────────────────────────────────────
// MARK: - Fix A: Extraction room-id depuis ROOMSTATE
// ────────────────────────────────────────────────────────────

static void s7tv_handleRoomState(NSString *ircMessage) {
    // Lors d'un changement très rapide, l'ancien ROOMSTATE peut arriver
    // après le nouveau JOIN. Ne jamais l'utiliser pour confirmer/initialiser
    // le nouveau salon, ni enregistrer son room-id sous le mauvais login.
    NSRange roomStateCommand = [ircMessage rangeOfString:@" ROOMSTATE #"];
    if (roomStateCommand.location != NSNotFound) {
        NSUInteger channelStart = roomStateCommand.location + roomStateCommand.length;
        NSRange tail = NSMakeRange(channelStart, ircMessage.length - channelStart);
        NSRange channelEnd = [ircMessage rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet] options:0 range:tail];
        NSUInteger end = channelEnd.location == NSNotFound ? ircMessage.length : channelEnd.location;
        NSString *roomChannel = [ircMessage substringWithRange:NSMakeRange(channelStart, end - channelStart)];
        NSString *activeChannel = [SevenTVManager sharedManager].currentChannelName;
        if (roomChannel.length && activeChannel.length &&
            [roomChannel caseInsensitiveCompare:activeChannel] != NSOrderedSame) {
            return;
        }
    }

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

    BOOL didChangeBroadcaster = ![roomID isEqualToString:mgr.currentChannelTwitchID];
    if (didChangeBroadcaster) {
        [[SevenTVManager sharedManager]
            log:@"📡 Nouveau broadcaster ID (ROOMSTATE): %@ (ancien: %@)",
            roomID, mgr.currentChannelTwitchID ?: @"aucun"];
        mgr.currentChannelTwitchID = roomID;

        // Le fil actuellement affiché (s'il y en a un) référence des
        // messages de l'ancienne chaîne qui vont être remplacés dans le store
        // — plutôt que de laisser un panneau obsolète/vide ouvert, on le
        // ferme purement et simplement.
        [[S7TVReplyThreadPanel sharedPanel] hide];

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

    // Filet de sécurité seulement : le chemin normal initialise le store dès
    // le JOIN sortant. Cette vérification ne dépend volontairement PAS de
    // didChangeBroadcaster, puisque l'ID peut déjà provenir du cache/GQL.
    s7tv_initializeRecentHistoryForChannel(mgr.currentChannelName, NO);
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
                    s7tv_scanWebSocketTextForChannelPointsClaimAvailable(textToProcess);

                    BOOL addedMessage = NO;
                    // Les notifications PubSub sont des enveloppes JSON et
                    // non des lignes IRC. Elles doivent être extraites avant
                    // le split ci-dessous. Le store déduplique les deux
                    // abonnements Twitch grâce à redemption.id utilisé comme
                    // messageID.
                    for (S7TVChatMessage *rewardMessage in
                         s7tv_channelPointMessagesFromWebSocketText(textToProcess)) {
                        [[SevenTVManager sharedManager].chatMessageStore
                            addMessage:rewardMessage];
                        addedMessage = YES;
                    }
                    NSArray<NSString *> *ircLines = [textToProcess
                        componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    for (NSString *rawLine in ircLines) {
                        NSString *ircLine = [rawLine stringByTrimmingCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]];
                        if (!ircLine.length) continue;
                        if ([ircLine containsString:@"ROOMSTATE"]) {
                            s7tv_handleRoomState(ircLine);
                        }
                        // "USERSTATE" matche aussi GLOBALUSERSTATE (qui se
                        // termine par ce mot) — voir s7tv_handleUserState.
                        if ([ircLine containsString:@"USERSTATE"]) {
                            s7tv_handleUserState(ircLine);
                        }

                        if (s7tv_handleModerationEvent(ircLine)) {
                            continue;
                        }

                        S7TVChatMessage *chatMsg = s7tv_parsePRIVMSG(ircLine);
                        if (!chatMsg) chatMsg = s7tv_parseUSERNOTICE(ircLine);
                        if (!chatMsg) continue;

                        if (chatMsg.channelPointRewardID.length) {
                            // PubSub et IRC arrivent presque simultanément,
                            // parfois dans l'ordre inverse. Cette attente ne
                            // touche QUE le PRIVMSG d'une récompense avec
                            // message (personnalisée ou automatique) ; le
                            // chat ordinaire reste instantané.
                            S7TVChatMessage *pendingRewardCompanion = chatMsg;
                            S7TVChatMessageStore *rewardStore =
                                [SevenTVManager sharedManager].chatMessageStore;
                            NSUInteger rewardStoreGeneration = rewardStore.generation;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                           (int64_t)(0.35 * NSEC_PER_SEC)),
                                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                // Un JOIN intervenu pendant les 350 ms a
                                // reconstruit le store : ne jamais injecter
                                // le message retardé de l'ancienne chaîne.
                                if (rewardStore.generation != rewardStoreGeneration) return;
                                if (s7tv_shouldSuppressChannelPointCompanion(
                                        pendingRewardCompanion)) {
                                    [rewardStore mergeChannelPointCompanionMessage:
                                        pendingRewardCompanion completion:^(NSString *mergedID) {
                                            if (mergedID.length) {
                                                s7tv_reloadActiveChatMessage(mergedID);
                                            } else if (rewardStore.generation == rewardStoreGeneration) {
                                                // Filet de sécurité si le
                                                // PubSub a été vu mais sa
                                                // ligne n'a pas été stockée.
                                                [rewardStore addMessage:pendingRewardCompanion];
                                                s7tv_scheduleChatCustomReload();
                                            }
                                        }];
                                    return;
                                }
                                [rewardStore addMessage:pendingRewardCompanion];
                                s7tv_scheduleChatCustomReload();
                            });
                            continue;
                        }
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

    for (NSString *channel in s7tv_joinedChannelsInOutgoingWebSocketMessage(message)) {
        SevenTVManager *mgr = [SevenTVManager sharedManager];
        [mgr log:@"📺 Rejoint le channel: %@", channel];
        // Met currentChannelName à jour synchroniquement avant le reset et
        // avant que l'historique n'entre dans le parseur IRC.
        [mgr loadEmotesForChannelName:channel];
        // Le JOIN est la source de vérité de la transition : suppression des
        // anciens messages immédiate, sans attendre ROOMSTATE ni comparer un
        // broadcaster ID potentiellement déjà préchargé.
        s7tv_initializeRecentHistoryForChannel(channel, YES);
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

    // Auto Collect Channel Points — module 100% autonome (voir
    // 7tv-system-NativeBehaviorHooks.m), aucune dépendance avec les
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
        // Les placeholders de modération et leurs unités sont traduits au
        // moment du rendu. Un changement FR/EN doit donc invalider aussi le
        // vrai chat et le panneau de fil, sans redémarrage de l'application.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:S7TVLanguageDidChangeNotification
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
