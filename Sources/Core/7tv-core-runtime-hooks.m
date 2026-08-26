/*
 * 7tv-core-runtime-hooks.m  —  Substrate-FREE version
 *
 * Point d'entrée bas niveau du tweak : installe les swizzles UIKit/réseau,
 * transmet leurs événements aux modules spécialisés, puis initialise les
 * intégrations. Le rendu, le picker, l'état IRC et les comportements natifs
 * vivent dans leurs fichiers respectifs.
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
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Core/7tv-core-manager.h"
#import "Settings/7tv-settings-controller.h"
#import "Chat/7tv-chat-message.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Badge/7tv-badge-provider.h"
#import "Picker/7tv-picker-controller.h"
#import "System/7tv-system-native-behavior-hooks.h"
#import "System/7tv-system-home-features.h"
#import "Adblock/Proxy/7tv-adblock-data.h"
#import "Adblock/Proxy/7tv-adblock-proxy.h"
#import "Adblock/7tv-adblock-runtime.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Diagnostics/7tv-hook-diagnostics.h"
#import "UI/7tv-oled-mode.h"


// Variable de compat : le Tap Logger (diagnostic de reverse-engineering du
// picker natif Twitch) a été retiré de ce fichier, mais 7tv-core-manager.m
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
// MARK: - Pont métadonnées Channel Points GQL → chat custom
// ────────────────────────────────────────────────────────────
//
// Parsing robuste : tags malformés ou absents → valeurs par défaut, jamais
// de crash (exigence Phase 1a). Tokenisation via SevenTVChatTokenizer
// (Phase 2) — emotes Twitch natives pas encore branchées (point d'extension
// naturel : parser le tag emotes= que Twitch envoie déjà tel quel côté
// serveur, jamais lu pour l'instant).

static void s7tv_collectChannelIDsFromGQLRequestObject(
    id object, NSMutableOrderedSet<NSString *> *channelIDs) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        static NSSet<NSString *> *channelIDKeys = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            channelIDKeys = [NSSet setWithArray:@[
                @"channelID", @"channelId", @"channel_id",
                @"broadcasterID", @"broadcasterId",
                @"broadcasterUserID", @"broadcaster_user_id"
            ]];
        });
        for (NSString *key in channelIDKeys) {
            id value = dictionary[key];
            NSString *channelID = nil;
            if ([value isKindOfClass:[NSString class]]) channelID = value;
            else if ([value isKindOfClass:[NSNumber class]]) channelID = [value stringValue];
            if (channelID.length) [channelIDs addObject:channelID];
        }
        for (id value in dictionary.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] ||
                [value isKindOfClass:[NSArray class]]) {
                s7tv_collectChannelIDsFromGQLRequestObject(value, channelIDs);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            s7tv_collectChannelIDsFromGQLRequestObject(value, channelIDs);
        }
    }
}

static NSString * _Nullable s7tv_channelIDFromGQLRequest(
    NSURLRequest *request, BOOL mayCaptureCurrentChannel,
    BOOL * _Nullable outAmbiguous) {
    if (outAmbiguous) *outAmbiguous = NO;
    NSData *body = request.HTTPBody;
    if (!body.length) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (!root) return nil;
    NSMutableOrderedSet<NSString *> *channelIDs = [NSMutableOrderedSet orderedSet];
    s7tv_collectChannelIDsFromGQLRequestObject(root, channelIDs);
    if (channelIDs.count == 1) return channelIDs.firstObject;
    if (channelIDs.count > 1) {
        if (outAmbiguous) *outAmbiguous = YES;
        return nil;
    }
    if (!mayCaptureCurrentChannel) return nil;

    // Certaines opérations persistées ne mettent aucun ID fort dans
    // variables. Capturer la chaîne au moment où LA REQUÊTE part reste sûr,
    // contrairement à relire la chaîne courante plusieurs secondes plus tard
    // dans le callback d'une réponse possiblement devenue obsolète.
    NSString *rawBody = [[NSString alloc] initWithData:body
                                               encoding:NSUTF8StringEncoding];
    BOOL isChannelPointRequest =
        [rawBody rangeOfString:@"channelpoint"
                       options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [rawBody rangeOfString:@"communitypoint"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
    return isChannelPointRequest
        ? [[SevenTVManager sharedManager].currentChannelTwitchID copy] : nil;
}

static void s7tv_ingestChannelPointMetadata(NSData *data,
                                             NSString *requestChannelID,
                                             BOOL requestChannelIDAmbiguous) {
    s7tv_ingestAutomaticRewardsFromGQLData(
        data, requestChannelID, requestChannelIDAmbiguous, ^{
        s7tv_reloadActiveChatCustomViewForConfiguration();
    });
}

// ────────────────────────────────────────────────────────────
// MARK: - Routeur UIKit vers les modules UI
// ────────────────────────────────────────────────────────────

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    s7tv_handleTheaterControlsViewLifecycle(self);
    s7tv_handleNativeChatViewLifecycle(self);

    s7tv_handleChatInputViewLifecycle(self);
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

// Définie plus bas avec le hook delegate Apollo. Le chemin NSURLSession sans
// completion est justement emprunté au moment où Apollo crée sa requête :
// c'est donc également le dernier point fiable pour installer son swizzle si
// le framework n'était pas encore chargé au constructeur du tweak.
static BOOL s7tv_try_swizzle_apollo_gql(void);
static char kS7TVGQLRequestChannelIDKey;
static char kS7TVGQLRequestAmbiguousKey;

static NSString *const kS7TVVAFTInternalHeader = @"X-TAS-Internal";

static BOOL s7tv_requestTargetsTwitchGQL(NSURLRequest *request) {
    // Les requêtes GQL privées de VAFT utilisent leur propre Client-ID : elles
    // ne doivent jamais alimenter le couple de credentials destiné à Helix.
    if ([request valueForHTTPHeaderField:kS7TVVAFTInternalHeader].length) return NO;
    return [request.URL.host caseInsensitiveCompare:@"gql.twitch.tv"] == NSOrderedSame;
}

static NSString *s7tv_HTTPHeaderValue(NSDictionary<NSString *, NSString *> *headers,
                                      NSString *expectedField) {
    for (NSString *field in headers) {
        if ([field caseInsensitiveCompare:expectedField] == NSOrderedSame) {
            NSString *value = headers[field];
            return [value isKindOfClass:[NSString class]] ? value : nil;
        }
    }
    return nil;
}

// Capture le couple provenant de LA MEME requête GQL. Sauvegarder les deux
// valeurs atomiquement est important : les hooks partiels peuvent sinon
// associer un nouveau token à un ancien Client-ID (Helix répond alors 401).
static void s7tv_captureTwitchCredentialsFromGQLRequest(NSURLRequest *request) {
    if (!s7tv_requestTargetsTwitchGQL(request)) return;

    NSDictionary<NSString *, NSString *> *headers = request.allHTTPHeaderFields;
    NSString *auth = s7tv_HTTPHeaderValue(headers, @"Authorization");
    NSString *clientID = s7tv_HTTPHeaderValue(headers, @"Client-ID");
    SevenTVManager *manager = [SevenTVManager sharedManager];
    if (auth.length && clientID.length) {
        [manager saveTwitchToken:auth clientID:clientID];
    } else {
        if (auth.length) [manager s7tv_captureAuthorizationHeader:auth];
        if (clientID.length) [manager s7tv_captureClientIDHeader:clientID];
    }
}

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
- (NSURLSessionUploadTask *)s7tv_uploadTaskWithRequest:(NSURLRequest *)request
                                              fromData:(NSData *)bodyData;
@end

@implementation NSURLSession (SevenTV)

- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request {
    // A proxy-configured fallback session re-enters this same concrete
    // NSURLSession class. Let it reach Apple's implementation directly.
    if (S7TVAdblockIsInternalProxyDispatch()) {
        return [self s7tv_dataTaskWithRequest:request];
    }
    s7tv_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = S7TVAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;

    // À cet instant Apollo.URLSessionClient est forcément chargé si cette
    // requête vient d'Apollo. Le hook sera en place avant la première réponse,
    // même si l'utilisateur ouvre son premier stream bien après les retries
    // bornés du démarrage.
    s7tv_try_swizzle_apollo_gql();
    NSString *requestChannelID = nil;
    BOOL requestChannelIDAmbiguous = NO;
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && request.HTTPBody) {
        requestChannelID = s7tv_channelIDFromGQLRequest(
            request, YES, &requestChannelIDAmbiguous);
        NSString *bodyStr = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if ([bodyStr containsString:@"ClaimCommunityPoints"] || [bodyStr containsString:@"claimCommunityPoints"]) {
            [[SevenTVManager sharedManager]
                log:@"🎁 Channel Points debug: requête ClaimChannelPointsMutation envoyée — corps :\n%@", bodyStr];
        }
    }
    NSURLSessionDataTask *task = S7TVAdblockCreateConnectTaskIfNeeded(self, request);
    if (!task) task = [self s7tv_dataTaskWithRequest:request];
    if (requestChannelID.length) {
        objc_setAssociatedObject(task, &kS7TVGQLRequestChannelIDKey,
                                 requestChannelID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (requestChannelIDAmbiguous) {
        objc_setAssociatedObject(task, &kS7TVGQLRequestAmbiguousKey,
                                 @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return task;
}
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (S7TVAdblockIsInternalProxyDispatch()) {
        return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
    }
    s7tv_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = S7TVAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        BOOL requestChannelIDAmbiguous = NO;
        NSString *requestChannelID = s7tv_channelIDFromGQLRequest(
            request, YES, &requestChannelIDAmbiguous);
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                NSData *filteredData = data && !error
                    ? S7TVAdblockTransformResponseData(data, request) : data;
                if (filteredData && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:filteredData];
                    s7tv_scanGQLResponseForChannelPointsClaim(filteredData);
                    s7tv_ingestChannelPointMetadata(
                        filteredData, requestChannelID, requestChannelIDAmbiguous);
                }
                completionHandler(filteredData, response, error);
            };
        return [self s7tv_dataTaskWithRequest:request completionHandler:wrapped];
    }
    NSURLSessionDataTask *proxyTask =
        S7TVAdblockCreateConnectTaskWithCompletionIfNeeded(
            self, request, completionHandler);
    if (proxyTask) return proxyTask;
    return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (S7TVAdblockIsEnabled() &&
        (S7TVAdblockIsAdHost(url.host) || S7TVAdblockIsMasterPlaylistHost(url.host))) {
        return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                       completionHandler:completionHandler];
    }
    if ([url.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                    s7tv_scanGQLResponseForChannelPointsClaim(data);
                    s7tv_ingestChannelPointMetadata(data, nil, NO);
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithURL:url completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithURL:url completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)s7tv_uploadTaskWithRequest:(NSURLRequest *)request
                                              fromData:(NSData *)bodyData {
    if (S7TVAdblockIsInternalProxyDispatch())
        return [self s7tv_uploadTaskWithRequest:request fromData:bodyData];
    s7tv_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = S7TVAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;
    NSData *preparedBody = S7TVAdblockTransformRequestData(bodyData, request);
    return [self s7tv_uploadTaskWithRequest:request fromData:preparedBody];
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

static char kS7TVApolloResponseBufferKey;

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
    NSURLRequest *request = dataTask.currentRequest ?: dataTask.originalRequest;
    NSData *filteredData = [host isEqualToString:@"gql.twitch.tv"]
        ? S7TVAdblockTransformResponseData(data, request) : data;
    if ([host isEqualToString:@"gql.twitch.tv"]) {
        @synchronized (dataTask) {
            NSMutableData *buf = objc_getAssociatedObject(
                dataTask, &kS7TVApolloResponseBufferKey);
            if (!buf) {
                buf = [NSMutableData data];
                objc_setAssociatedObject(dataTask, &kS7TVApolloResponseBufferKey,
                                         buf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [buf appendData:filteredData];
        }
    }
    // Appelle l'implémentation originale (échangée par le swizzle) —
    // indispensable pour qu'Apollo reçoive bien ses propres données.
    [self s7tv_apolloURLSession:session dataTask:dataTask didReceiveData:filteredData];
}

- (void)s7tv_apolloURLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
          didCompleteWithError:(NSError *)error {
    NSData *fullData = nil;
    @synchronized (task) {
        NSMutableData *buffer = objc_getAssociatedObject(
            task, &kS7TVApolloResponseBufferKey);
        fullData = [buffer copy];
        objc_setAssociatedObject(task, &kS7TVApolloResponseBufferKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (fullData.length > 0 && !error) {
        NSString *host = task.currentRequest.URL.host ?: task.originalRequest.URL.host;
        if ([host isEqualToString:@"gql.twitch.tv"]) {
            [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:fullData];
            s7tv_scanGQLResponseForChannelPointsClaim(fullData);
            NSString *requestChannelID = objc_getAssociatedObject(
                task, &kS7TVGQLRequestChannelIDKey);
            BOOL requestChannelIDAmbiguous = [objc_getAssociatedObject(
                task, &kS7TVGQLRequestAmbiguousKey) boolValue];
            if (!requestChannelID.length) {
                BOOL completionAmbiguous = NO;
                requestChannelID = s7tv_channelIDFromGQLRequest(
                    task.currentRequest ?: task.originalRequest, NO,
                    &completionAmbiguous);
                requestChannelIDAmbiguous |= completionAmbiguous;
            }
            s7tv_ingestChannelPointMetadata(
                fullData, requestChannelID, requestChannelIDAmbiguous);

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
static BOOL s_s7tvApolloGQLSwizzled = NO;
static BOOL s_s7tvApolloDeferredSuccessLogged = NO;

static BOOL s7tv_try_swizzle_apollo_gql(void) {
    @synchronized ([SevenTVManager class]) {
        if (s_s7tvApolloGQLSwizzled) return YES;

        Class apolloClass = NSClassFromString(@"Apollo.URLSessionClient");
        if (!apolloClass) return NO;

        SEL dataOriginal = @selector(URLSession:dataTask:didReceiveData:);
        SEL dataReplacement = @selector(s7tv_apolloURLSession:dataTask:didReceiveData:);
        SEL completionOriginal = @selector(URLSession:task:didCompleteWithError:);
        SEL completionReplacement = @selector(s7tv_apolloURLSession:task:didCompleteWithError:);
        if (!class_getInstanceMethod(apolloClass, dataOriginal) ||
            !class_getInstanceMethod(apolloClass, completionOriginal) ||
            !class_getInstanceMethod([NSObject class], dataReplacement) ||
            !class_getInstanceMethod([NSObject class], completionReplacement)) {
            return NO;
        }

        // Poser le garde avant les échanges : tous les essais sont exécutés
        // sur le main thread, mais le constructeur peut avoir commencé hors
        // main. Le bloc synchronized empêche aussi un double échange inverse.
        s_s7tvApolloGQLSwizzled = YES;
        s7tv_swizzle(apolloClass, [NSObject class], dataOriginal, dataReplacement);
        s7tv_swizzle(apolloClass, [NSObject class], completionOriginal, completionReplacement);
        return YES;
    }
}

static void s7tv_swizzle_apollo_gql(void) {
    if (s7tv_try_swizzle_apollo_gql()) return;

    [[SevenTVManager sharedManager]
        log:@"ℹ️ Channel Points: Apollo pas encore chargé, installation différée du hook GQL"];

    // TwitchApollo peut être chargé après le constructeur du tweak. Un échec
    // initial ne doit plus condamner l'acquisition des images de monnaie pour
    // toute la session. Les essais sont bornés et la fonction est idempotente.
    NSArray<NSNumber *> *delays = @[@0.5, @2.0, @5.0, @10.0];
    [delays enumerateObjectsUsingBlock:^(NSNumber *delay, NSUInteger index,
                                          __unused BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (s7tv_try_swizzle_apollo_gql()) {
                BOOL shouldLog = NO;
                @synchronized ([SevenTVManager class]) {
                    if (!s_s7tvApolloDeferredSuccessLogged) {
                        s_s7tvApolloDeferredSuccessLogged = YES;
                        shouldLog = YES;
                    }
                }
                if (shouldLog) {
                    [[SevenTVManager sharedManager]
                        log:@"✅ Channel Points: hook GQL Apollo installé après chargement différé"];
                }
            } else if (index == delays.count - 1) {
                [[SevenTVManager sharedManager]
                    log:@"⚠️ Channel Points: Apollo.URLSessionClient toujours introuvable — images de monnaie indisponibles"];
            }
        });
    }];
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
                    [[SevenTVManager sharedManager]
                        handleIncomingChatWebSocketText:textToProcess];
                }
            }
            completionHandler(message, error);
        };

    [self s7tv_receiveMessageWithCompletionHandler:wrappedHandler];
}

- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler {

    [[SevenTVManager sharedManager] handleOutgoingChatWebSocketMessage:message];
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
    // La capture globale voyait aussi l'Authorization Basic injectée par le
    // proxy adblock. Restreindre aux requêtes GQL empêche tout service tiers
    // (proxy compris) d'écraser le token Twitch destiné à Helix.
    if (value.length && s7tv_requestTargetsTwitchGQL(self)) {
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
    BOOL incomingVAFTInternal =
        s7tv_HTTPHeaderValue(headerFields, kS7TVVAFTInternalHeader).length > 0;
    if (!incomingVAFTInternal && s7tv_requestTargetsTwitchGQL(self)) {
        NSString *auth = s7tv_HTTPHeaderValue(headerFields, @"Authorization");
        NSString *clientID = s7tv_HTTPHeaderValue(headerFields, @"Client-ID");
        SevenTVManager *manager = [SevenTVManager sharedManager];
        if (auth.length && clientID.length) {
            [manager saveTwitchToken:auth clientID:clientID];
        } else {
            if (auth.length) [manager s7tv_captureAuthorizationHeader:auth];
            if (clientID.length) [manager s7tv_captureClientIDHeader:clientID];
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
    NSString *auth = s7tv_HTTPHeaderValue(headers, @"Authorization");
    NSString *clientID = s7tv_HTTPHeaderValue(headers, @"Client-ID");
    SevenTVManager *manager = [SevenTVManager sharedManager];
    if (auth.length && clientID.length) {
        [manager saveTwitchToken:auth clientID:clientID];
    } else {
        if (auth.length) [manager s7tv_captureAuthorizationHeader:auth];
        if (clientID.length) [manager s7tv_captureClientIDHeader:clientID];
    }
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
    SEL selUpload   = @selector(uploadTaskWithRequest:fromData:);
    SEL swizRequest = @selector(s7tv_dataTaskWithRequest:completionHandler:);
    SEL swizURL     = @selector(s7tv_dataTaskWithURL:completionHandler:);
    SEL swizReqOnly = @selector(s7tv_dataTaskWithRequest:);
    SEL swizUpload  = @selector(s7tv_uploadTaskWithRequest:fromData:);

    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession standard: %@",
     NSStringFromClass(classStd)];
    s7tv_swizzle(classStd, [NSURLSession class], selRequest, swizRequest);
    s7tv_swizzle(classStd, [NSURLSession class], selURL, swizURL);
    s7tv_swizzle(classStd, [NSURLSession class], selReqOnly, swizReqOnly);
    s7tv_swizzle(classStd, [NSURLSession class], selUpload, swizUpload);

    Class classShared = object_getClass([NSURLSession sharedSession]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession shared: %@",
     NSStringFromClass(classShared)];
    if (classShared != classStd) {
        s7tv_swizzle(classShared, [NSURLSession class], selRequest, swizRequest);
        s7tv_swizzle(classShared, [NSURLSession class], selURL, swizURL);
        s7tv_swizzle(classShared, [NSURLSession class], selReqOnly, swizReqOnly);
        s7tv_swizzle(classShared, [NSURLSession class], selUpload, swizUpload);
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

    // Doit être installé avant toute création de vue Twitch, notamment le
    // premier écran et les en-têtes de catégories au lancement.
    S7TVOLEDModeSetup();

    s7tv_setupChatCustomIntegration();

    // Adblock TwitchAdBlock-derived : AVFoundation, contrôleurs pub Swift et
    // hooks Twitch tardifs. Les interceptions NSURLSession/Apollo restent
    // volontairement dans ce fichier afin de ne jamais les swizzler deux fois.
    S7TVAdblockInstallRuntimeHooks();
    s7tv_installHomeFeatureRuntimeHooks();

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

    // Même registre de classes résolues que TwitchAdBlock : il rend visibles
    // les cibles qui auraient été renommées par une version de Twitch.
    S7TVHookDiagnosticsRegisterKnownTargets();

    // Auto Collect Channel Points — module 100% autonome (voir
    // 7tv-system-native-behavior-hooks.m), aucune dépendance avec les
    // swizzles ci-dessus. Démarré directement ici, pas via didMoveToWindow.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL autoCollectEnabled = [defaults objectForKey:@"TCDBGLiveAutoCollectChannelPoints"] != nil
        ? [defaults boolForKey:@"TCDBGLiveAutoCollectChannelPoints"] : YES;
    if (autoCollectEnabled) {
        s7tv_scanForChannelPointsLoop();
    }

    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        // Catalogue global + abonnement à S7TVChannelJoined, postée par le
        // gestionnaire de session IRC — voir 7tv-badge-provider.h.
        [SevenTVBadgeProvider setup];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt"];

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                [[SevenTVManager sharedManager] log:@"✅ Bouton 7TV ajouté"];
            }
        );
    });
}
