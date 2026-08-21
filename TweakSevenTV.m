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

static void s7tv_ingestChannelPointMetadata(NSData *data) {
    s7tv_ingestAutomaticRewardsFromGQLData(data, ^{
        s7tv_scheduleChatCustomReload();
    });
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
            S7TVChatMessage *message =
                s7tv_parseChatMessage(ircLine, s7tv_emoteProviders());
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
                    s7tv_ingestChannelPointMetadata(data);
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
                    s7tv_ingestChannelPointMetadata(data);
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
            s7tv_ingestChannelPointMetadata(fullData);

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
                         s7tv_channelPointMessagesFromWebSocketText(textToProcess,
                                                                     s7tv_emoteProviders())) {
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

                        S7TVChatMessage *chatMsg =
                            s7tv_parseChatMessage(ircLine, s7tv_emoteProviders());
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
            return [SevenTVChatTokenizer tokenizeText:message.rawText ?: @""
                                      twitchEmotesTag:message.twitchEmotesTag ?: @""
                                            providers:s7tv_emoteProviders()];
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
    [SevenTVSettingsController installTwitchSettingsIntegration];

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
