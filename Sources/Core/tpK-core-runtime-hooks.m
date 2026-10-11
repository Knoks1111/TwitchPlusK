/*
 * tpK-core-runtime-hooks.m  —  Substrate-FREE version
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
 * (voir plan.txt). Le picker, les données 7TV et l'IRC restent inchangés.
 *
 * Note : la redirection CDN (TPKURLProtocol) et son enregistrement ont
 * aussi été retirés d'ici — ce mécanisme ne se déclenchait que via le tag
 * emotes= injecté dans les messages IRC, injection elle-même supprimée.
 * TPKURLProtocol reste utilisé ailleurs (TPKManager) comme simple
 * utilitaire de cache/prefetch, plus comme intercepteur.
 *
 * Note : tout le diagnostic de reverse-engineering du picker natif Twitch
 * (sniffer NSURLProtocol bas niveau, dump des opérations GQL, introspection
 * générique propriétés/ivars/méthodes, énumération de toutes les fenêtres,
 * watcher/heartbeat périodique, détection événementielle du picker natif) a
 * été retiré. Cette piste (exploiter le picker natif de Twitch) est
 * abandonnée : le picker 7TV personnalisé est désormais entièrement
 * indépendant du picker natif.
 *
 * Le Tap Logger, lui, a été remis en place indépendamment du picker : il
 * logue la vue touchée, son contrôleur et sa hiérarchie à chaque tap.
 */

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Core/tpK-core-manager.h"
#import "Core/tpK-channel-resolver.h"
#import "Settings/tpK-settings-controller.h"
#import "Chat/tpK-chat-message.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Chat/tpK-chat-integration.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-badge-provider.h"
#import "Picker/tpK-picker-controller.h"
#import "System/tpK-system-native-behavior-hooks.h"
#import "System/tpK-system-autoclaim.h"
#import "System/tpK-system-update-checker.h"
#import "System/tpK-system-home-features.h"
#import "Adblock/Proxy/tpK-adblock-data.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/tpK-adblock-runtime.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Settings/tpK-hook-diagnostics.h"
#import "Settings/tpK-tap-logger.h"
#import "UI/tpK-oled-mode.h"
#import "System/tpK-system-player-gestures.h"
#import "System/tpK-system-player-reload.h"


// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzle
// ────────────────────────────────────────────────────────────

void tpk_swizzle(Class targetClass,
                         Class sourceClass,
                         SEL   original,
                         SEL   swizzled) {
    if (!targetClass || !sourceClass) {
        [[TPKManager sharedManager] log:@"⚠️  swizzle ignoré (classe nil): %@",
         NSStringFromSelector(original)];
        return;
    }

    Method swizzledMethod = class_getInstanceMethod(sourceClass, swizzled);
    if (!swizzledMethod) {
        [[TPKManager sharedManager] log:@"⚠️  méthode swizzlée introuvable: %@",
         NSStringFromSelector(swizzled)];
        return;
    }
    class_addMethod(targetClass,
                    swizzled,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod));

    Method origMethod = class_getInstanceMethod(targetClass, original);
    if (!origMethod) {
        [[TPKManager sharedManager] log:@"⚠️  méthode originale introuvable sur %@: %@",
         NSStringFromClass(targetClass), NSStringFromSelector(original)];
        return;
    }

    Method swizzledOnTarget = class_getInstanceMethod(targetClass, swizzled);
    method_exchangeImplementations(origMethod, swizzledOnTarget);

}


// ────────────────────────────────────────────────────────────
// MARK: - Pont métadonnées Channel Points GQL → chat custom
// ────────────────────────────────────────────────────────────
//
// Parsing robuste : tags malformés ou absents → valeurs par défaut, jamais
// de crash (exigence Phase 1a). Tokenisation via TPKChatTokenizer
// (Phase 2) — emotes Twitch natives pas encore branchées (point d'extension
// naturel : parser le tag emotes= que Twitch envoie déjà tel quel côté
// serveur, jamais lu pour l'instant).

// ────────────────────────────────────────────────────────────
// MARK: - Routeur UIKit vers les modules UI

@interface UIView (TPKChatInputHook)
- (void)tpk_didMoveToWindow;
@end

@implementation UIView (TPKChatInputHook)

- (void)tpk_didMoveToWindow {
    [self tpk_didMoveToWindow]; // appel original

    tpk_handlePlayerGesturesViewLifecycle(self);
    tpk_handlePlayerReloadViewLifecycle(self);
    tpk_handleTheaterControlsViewLifecycle(self);
    tpk_handleNativeChatViewLifecycle(self);

    tpk_handleChatTrayButtonLifecycle(self);
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

// Définie plus bas avec le hook delegate Apollo. Le chemin NSURLSession sans
// completion est justement emprunté au moment où Apollo crée sa requête :
// c'est donc également le dernier point fiable pour installer son swizzle si
// le framework n'était pas encore chargé au constructeur du tweak.
static BOOL tpk_try_swizzle_apollo_gql(void);

static NSString *const kTPKVAFTInternalHeader = @"X-TAS-Internal";

static BOOL tpk_requestTargetsTwitchGQL(NSURLRequest *request) {
    // Les requêtes GQL privées de VAFT utilisent leur propre Client-ID : elles
    // ne doivent jamais alimenter le couple de credentials destiné à Helix.
    if ([request valueForHTTPHeaderField:kTPKVAFTInternalHeader].length) return NO;
    return [request.URL.host caseInsensitiveCompare:@"gql.twitch.tv"] == NSOrderedSame;
}

static NSString *tpk_HTTPHeaderValue(NSDictionary<NSString *, NSString *> *headers,
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
static void tpk_captureTwitchCredentialsFromGQLRequest(NSURLRequest *request) {
    if (!tpk_requestTargetsTwitchGQL(request)) return;

    NSDictionary<NSString *, NSString *> *headers = request.allHTTPHeaderFields;
    NSString *auth = tpk_HTTPHeaderValue(headers, @"Authorization");
    NSString *clientID = tpk_HTTPHeaderValue(headers, @"Client-ID");
    TPKManager *manager = [TPKManager sharedManager];
    if (auth.length && clientID.length) {
        [manager saveTwitchToken:auth clientID:clientID];
    } else {
        if (auth.length) [manager tpk_captureAuthorizationHeader:auth context:request];
        if (clientID.length) [manager tpk_captureClientIDHeader:clientID context:request];
    }
}

@interface NSURLSession (TPK)
- (NSURLSessionDataTask *)tpk_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)tpk_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
// Variante SANS completion handler — c'est celle-ci qu'utilise Apollo en
// interne pour ses requêtes delegate-based (voir plus bas, hook
// Apollo.URLSessionClient). Les hooks delegate ne donnent ensuite accès qu'à
// la réponse, pas au corps de la requête sortante.
- (NSURLSessionDataTask *)tpk_dataTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionUploadTask *)tpk_uploadTaskWithRequest:(NSURLRequest *)request
                                              fromData:(NSData *)bodyData;
@end

@implementation NSURLSession (TPK)

- (NSURLSessionDataTask *)tpk_dataTaskWithRequest:(NSURLRequest *)request {
    // A proxy-configured fallback session re-enters this same concrete
    // NSURLSession class. Let it reach Apple's implementation directly.
    if (TPKAdblockIsInternalProxyDispatch()) {
        return [self tpk_dataTaskWithRequest:request];
    }
    tpk_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = TPKAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;

    // Apollo uses the delegate API, so install its response hook before the
    // first request is sent.
    tpk_try_swizzle_apollo_gql();
    NSURLSessionDataTask *task = TPKAdblockCreateConnectTaskIfNeeded(self, request);
    if (!task) task = [self tpk_dataTaskWithRequest:request];
    return task;
}
- (NSURLSessionDataTask *)tpk_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (TPKAdblockIsInternalProxyDispatch()) {
        return [self tpk_dataTaskWithRequest:request completionHandler:completionHandler];
    }
    tpk_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = TPKAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                NSData *filteredData = data && !error
                    ? TPKAdblockTransformResponseData(data, request) : data;
                completionHandler(filteredData, response, error);
            };
        return [self tpk_dataTaskWithRequest:request completionHandler:wrapped];
    }
    NSURLSessionDataTask *proxyTask =
        TPKAdblockCreateConnectTaskWithCompletionIfNeeded(
            self, request, completionHandler);
    if (proxyTask) return proxyTask;
    return [self tpk_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)tpk_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (TPKAdblockIsEnabled() &&
        (TPKAdblockIsAdHost(url.host) || TPKAdblockIsMasterPlaylistHost(url.host))) {
        return [self dataTaskWithRequest:[NSURLRequest requestWithURL:url]
                       completionHandler:completionHandler];
    }
    return [self tpk_dataTaskWithURL:url completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)tpk_uploadTaskWithRequest:(NSURLRequest *)request
                                              fromData:(NSData *)bodyData {
    if (TPKAdblockIsInternalProxyDispatch())
        return [self tpk_uploadTaskWithRequest:request fromData:bodyData];
    tpk_captureTwitchCredentialsFromGQLRequest(request);
    BOOL blocked = NO;
    request = TPKAdblockPrepareRequest(request, &blocked);
    if (blocked) return nil;
    NSData *preparedBody = TPKAdblockTransformRequestData(bodyData, request);
    return [self tpk_uploadTaskWithRequest:request fromData:preparedBody];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook Apollo.URLSessionClient (GraphQL réel, delegate-based)
// ────────────────────────────────────────────────────────────
//
// Le client Apollo de Twitch utilise l'API delegate de NSURLSession pour les
// réponses GraphQL, ce qui nécessite un hook séparé de celui des callbacks.
//
// Raison confirmée dans le binaire (pas une hypothèse) :
//   @rpath/TwitchApollo.framework/TwitchApollo
//   Apollo.URLSessionClient                          (classe réelle)
//   TwitchKit.TKGraphQL.urlSessionClient              (Twitch s'en sert)
//   URLSession:dataTask:didReceiveData:                (sélecteur réel)
//   urlSession(_:task:didCompleteWithError:)           (signature réelle)
//
// Twitch embarque son propre framework Apollo (le client GraphQL open-source
// standard), et Apollo-iOS pilote ses requêtes via l'API delegate.

@interface NSObject (TPKApolloDelegate)
- (void)tpk_apolloURLSession:(NSURLSession *)session
                      dataTask:(NSURLSessionDataTask *)dataTask
                didReceiveData:(NSData *)data;
- (void)tpk_apolloURLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
          didCompleteWithError:(NSError *)error;
@end

@implementation NSObject (TPKApolloDelegate)

- (void)tpk_apolloURLSession:(NSURLSession *)session
                      dataTask:(NSURLSessionDataTask *)dataTask
                didReceiveData:(NSData *)data {
    NSString *host = dataTask.currentRequest.URL.host ?: dataTask.originalRequest.URL.host;
    NSURLRequest *request = dataTask.currentRequest ?: dataTask.originalRequest;
    NSData *filteredData = [host isEqualToString:@"gql.twitch.tv"]
        ? TPKAdblockTransformResponseData(data, request) : data;
    // Pass the transformed data to Apollo's original delegate implementation.
    [self tpk_apolloURLSession:session dataTask:dataTask didReceiveData:filteredData];
}

- (void)tpk_apolloURLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
          didCompleteWithError:(NSError *)error {
    [self tpk_apolloURLSession:session task:task didCompleteWithError:error];
}

@end

// Swizzle direct sur Apollo.URLSessionClient — classe concrète connue par
// son nom exact (confirmé dans le binaire), pas besoin de sonder une
// instance comme pour NSURLSessionWebSocketTask (qui est un vrai cluster
// de classes abstrait ; Apollo.URLSessionClient est une classe concrète
// normale, instanciée directement par Apollo).
static BOOL s_tpkApolloGQLSwizzled = NO;

static BOOL tpk_try_swizzle_apollo_gql(void) {
    @synchronized ([TPKManager class]) {
        if (s_tpkApolloGQLSwizzled) return YES;

        Class apolloClass = NSClassFromString(@"Apollo.URLSessionClient");
        if (!apolloClass) return NO;

        SEL dataOriginal = @selector(URLSession:dataTask:didReceiveData:);
        SEL dataReplacement = @selector(tpk_apolloURLSession:dataTask:didReceiveData:);
        SEL completionOriginal = @selector(URLSession:task:didCompleteWithError:);
        SEL completionReplacement = @selector(tpk_apolloURLSession:task:didCompleteWithError:);
        if (!class_getInstanceMethod(apolloClass, dataOriginal) ||
            !class_getInstanceMethod(apolloClass, completionOriginal) ||
            !class_getInstanceMethod([NSObject class], dataReplacement) ||
            !class_getInstanceMethod([NSObject class], completionReplacement)) {
            return NO;
        }

        // Poser le garde avant les échanges : tous les essais sont exécutés
        // sur le main thread, mais le constructeur peut avoir commencé hors
        // main. Le bloc synchronized empêche aussi un double échange inverse.
        s_tpkApolloGQLSwizzled = YES;
        tpk_swizzle(apolloClass, [NSObject class], dataOriginal, dataReplacement);
        tpk_swizzle(apolloClass, [NSObject class], completionOriginal, completionReplacement);
        return YES;
    }
}

static void tpk_swizzle_apollo_gql(void) {
    if (tpk_try_swizzle_apollo_gql()) return;

    // TwitchApollo peut être chargé après le constructeur du tweak. Un échec
    // initial ne doit plus condamner l'acquisition des images de monnaie pour
    // toute la session. Les essais sont bornés et la fonction est idempotente.
    NSArray<NSNumber *> *delays = @[@0.5, @2.0, @5.0, @10.0];
    [delays enumerateObjectsUsingBlock:^(NSNumber *delay, NSUInteger index,
                                          __unused BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!tpk_try_swizzle_apollo_gql() && index == delays.count - 1) {
                [[TPKManager sharedManager]
                    log:@"⚠️ Apollo.URLSessionClient toujours introuvable — images de monnaie indisponibles"];
            }
        });
    }];
}


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSessionWebSocketTask (chat IRC Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSessionWebSocketTask (TPK)
- (void)tpk_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler;
- (void)tpk_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler;
@end

@implementation NSURLSessionWebSocketTask (TPK)

- (void)tpk_receiveMessageWithCompletionHandler:
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
                    [[TPKManager sharedManager]
                        handleIncomingChatWebSocketText:textToProcess];
                }
            }
            completionHandler(message, error);
        };
    [self tpk_receiveMessageWithCompletionHandler:wrappedHandler];
}

- (void)tpk_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler {
    [self tpk_sendMessage:message completionHandler:completionHandler];
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

@interface NSMutableURLRequest (TPKTokenCapture)
- (void)tpk_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)tpk_setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields;
@end

@implementation NSMutableURLRequest (TPKTokenCapture)
- (void)tpk_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    // La capture globale voyait aussi l'Authorization Basic injectée par le
    // proxy adblock. Restreindre aux requêtes GQL empêche tout service tiers
    // (proxy compris) d'écraser le token Twitch destiné à Helix.
    if (value.length && tpk_requestTargetsTwitchGQL(self)) {
        if ([field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) {
            [[TPKManager sharedManager] tpk_captureAuthorizationHeader:value context:self];
        } else if ([field caseInsensitiveCompare:@"Client-ID"] == NSOrderedSame) {
            [[TPKManager sharedManager] tpk_captureClientIDHeader:value context:self];
        }
    }
    [self tpk_setValue:value forHTTPHeaderField:field];
}

// Beaucoup de code (surtout en Swift : `request.allHTTPHeaderFields = [...]`)
// pose TOUS les headers d'un coup via cette méthode plutôt que field par
// field — sans ce hook, ce cas échappe complètement à setValue:forHTTPHeaderField:.
- (void)tpk_setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields {
    BOOL incomingVAFTInternal =
        tpk_HTTPHeaderValue(headerFields, kTPKVAFTInternalHeader).length > 0;
    if (!incomingVAFTInternal && tpk_requestTargetsTwitchGQL(self)) {
        NSString *auth = tpk_HTTPHeaderValue(headerFields, @"Authorization");
        NSString *clientID = tpk_HTTPHeaderValue(headerFields, @"Client-ID");
        TPKManager *manager = [TPKManager sharedManager];
        if (auth.length && clientID.length) {
            [manager saveTwitchToken:auth clientID:clientID];
        } else {
            if (auth.length) [manager tpk_captureAuthorizationHeader:auth context:self];
            if (clientID.length) [manager tpk_captureClientIDHeader:clientID context:self];
        }
    }
    [self tpk_setAllHTTPHeaderFields:headerFields];
}
@end

@interface NSURLSessionConfiguration (TPKTokenCapture)
- (void)tpk_setHTTPAdditionalHeaders:(NSDictionary *)headers;
@end

@implementation NSURLSessionConfiguration (TPKTokenCapture)
- (void)tpk_setHTTPAdditionalHeaders:(NSDictionary *)headers {
    NSString *auth = tpk_HTTPHeaderValue(headers, @"Authorization");
    NSString *clientID = tpk_HTTPHeaderValue(headers, @"Client-ID");
    TPKManager *manager = [TPKManager sharedManager];
    if (auth.length && clientID.length) {
        [manager saveTwitchToken:auth clientID:clientID];
    } else {
        if (auth.length) [manager tpk_captureAuthorizationHeader:auth context:self];
        if (clientID.length) [manager tpk_captureClientIDHeader:clientID context:self];
    }
    [self tpk_setHTTPAdditionalHeaders:headers];
}
@end

static void tpk_swizzle_token_capture(void) {
    // NSMutableURLRequest est un class cluster : l'instance réelle créée par
    // Twitch est une sous-classe privée d'Apple qui a SA PROPRE implémentation
    // de setValue:forHTTPHeaderField: — swizzler la classe publique de base
    // ne sert à rien (même piège que NSURLSession, cf. tpk_swizzle_session).
    // On sonde donc la vraie classe concrète avant de swizzler.
    NSMutableURLRequest *probeReq = [[NSMutableURLRequest alloc]
                                      initWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/"]];
    Class classReq = object_getClass(probeReq);
    tpk_swizzle(classReq, [NSMutableURLRequest class],
                 @selector(setValue:forHTTPHeaderField:),
                 @selector(tpk_setValue:forHTTPHeaderField:));
    tpk_swizzle(classReq, [NSMutableURLRequest class],
                 @selector(setAllHTTPHeaderFields:),
                 @selector(tpk_setAllHTTPHeaderFields:));

    // NSURLSessionConfiguration n'est PAS un class cluster (classe concrète
    // normale) mais on sonde quand même par prudence/cohérence — et on
    // couvre les deux variantes (default + ephemeral) au cas où Twitch en
    // utilise une différente pour ses requêtes GQL.
    Class classCfgDefault = object_getClass([NSURLSessionConfiguration defaultSessionConfiguration]);
    Class classCfgEphemeral = object_getClass([NSURLSessionConfiguration ephemeralSessionConfiguration]);

    tpk_swizzle(classCfgDefault, [NSURLSessionConfiguration class],
                 @selector(setHTTPAdditionalHeaders:),
                 @selector(tpk_setHTTPAdditionalHeaders:));
    if (classCfgEphemeral != classCfgDefault) {
        tpk_swizzle(classCfgEphemeral, [NSURLSessionConfiguration class],
                     @selector(setHTTPAdditionalHeaders:),
                     @selector(tpk_setHTTPAdditionalHeaders:));
    }

}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSession (classe concrète via sonde)
// ────────────────────────────────────────────────────────────

static void tpk_swizzle_session(void) {
    SEL selRequest  = @selector(dataTaskWithRequest:completionHandler:);
    SEL selURL      = @selector(dataTaskWithURL:completionHandler:);
    SEL selReqOnly  = @selector(dataTaskWithRequest:);
    SEL selUpload   = @selector(uploadTaskWithRequest:fromData:);
    SEL swizRequest = @selector(tpk_dataTaskWithRequest:completionHandler:);
    SEL swizURL     = @selector(tpk_dataTaskWithURL:completionHandler:);
    SEL swizReqOnly = @selector(tpk_dataTaskWithRequest:);
    SEL swizUpload  = @selector(tpk_uploadTaskWithRequest:fromData:);

    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    tpk_swizzle(classStd, [NSURLSession class], selRequest, swizRequest);
    tpk_swizzle(classStd, [NSURLSession class], selURL, swizURL);
    tpk_swizzle(classStd, [NSURLSession class], selReqOnly, swizReqOnly);
    tpk_swizzle(classStd, [NSURLSession class], selUpload, swizUpload);

    Class classShared = object_getClass([NSURLSession sharedSession]);
    if (classShared != classStd) {
        tpk_swizzle(classShared, [NSURLSession class], selRequest, swizRequest);
        tpk_swizzle(classShared, [NSURLSession class], selURL, swizURL);
        tpk_swizzle(classShared, [NSURLSession class], selReqOnly, swizReqOnly);
        tpk_swizzle(classShared, [NSURLSession class], selUpload, swizUpload);
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSessionWebSocketTask (classe concrète)
// ────────────────────────────────────────────────────────────

static void tpk_swizzle_websocket(void) {
    Class wsAbstractClass = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (!wsAbstractClass) {
        [[TPKManager sharedManager] log:@"⚠️  NSURLSessionWebSocketTask introuvable"];
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *probeURL = [NSURL URLWithString:@"wss://irc-ws.chat.twitch.tv/irc"];
    NSURLSessionWebSocketTask *probeTask = [probeSession webSocketTaskWithURL:probeURL];
    Class realWSClass = object_getClass(probeTask);
    [probeTask cancel];

    tpk_swizzle(realWSClass, wsAbstractClass,
                 @selector(receiveMessageWithCompletionHandler:),
                 @selector(tpk_receiveMessageWithCompletionHandler:));
    tpk_swizzle(realWSClass, wsAbstractClass,
                 @selector(sendMessage:completionHandler:),
                 @selector(tpk_sendMessage:completionHandler:));
}

// ────────────────────────────────────────────────────────────
// MARK: - Socket chat React Native (RCTWebSocketModule)
// ────────────────────────────────────────────────────────────
// Observateur seul : relaie le texte IRC vers le parser existant,
// sans altérer le chat natif. Inerte si la classe est absente (31.0.2).

@interface NSObject (TPKRNChatSocket)
- (void)tpk_rnChatWebSocket:(id)webSocket didReceiveMessage:(id)message;
@end

@implementation NSObject (TPKRNChatSocket)

- (void)tpk_rnChatWebSocket:(id)webSocket didReceiveMessage:(id)message {
    [self tpk_rnChatWebSocket:webSocket didReceiveMessage:message];
    NSString *text = nil;
    if ([message isKindOfClass:NSString.class]) {
        text = message;
    } else if ([message isKindOfClass:NSData.class]) {
        text = [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding];
    }
    if (!text.length) return;
    [[TPKManager sharedManager] handleIncomingChatWebSocketText:text];
}

@end

static void tpk_swizzle_rn_chat_socket(void) {
    Class moduleClass = NSClassFromString(@"RCTWebSocketModule");
    if (!moduleClass) return;
    if (![moduleClass instancesRespondToSelector:@selector(webSocket:didReceiveMessage:)]) return;
    tpk_swizzle(moduleClass, [NSObject class],
                 @selector(webSocket:didReceiveMessage:),
                 @selector(tpk_rnChatWebSocket:didReceiveMessage:));
}

// ────────────────────────────────────────────────────────────
// MARK: - Contexte de chaîne partagé
// ────────────────────────────────────────────────────────────

static BOOL s_tpkBoundChannelContext = NO;
static NSUUID *s_tpkBoundSessionID = nil;
static NSUInteger s_tpkBoundGeneration = 0;
static NSString *s_tpkBoundChannelName = nil;

static void tpk_applyResolvedChannelContext(TPKChannelContext *context) {
    // Une notification peut arriver après qu'un contexte plus récent a déjà
    // été résolu. Ne jamais réappliquer cet ancien contexte au store/UI.
    TPKChannelContext *currentContext = TPKCurrentChannelContext();
    if (context) {
        if (!TPKChannelContextIsCurrent(context)) return;
    } else if (currentContext) {
        return;
    }

    TPKManager *manager = [TPKManager sharedManager];
    NSString *channelID = context.channelID
        ? [NSString stringWithFormat:@"%u", context.channelID] : nil;
    NSString *channelName = context.channelName ?: context.displayName;

    manager.currentChannelTwitchID = channelID;
    manager.currentChannelName = channelName;

    BOOL sameSession = s_tpkBoundChannelContext && context &&
        [s_tpkBoundSessionID isEqual:context.sessionID] &&
        s_tpkBoundGeneration == context.generation;
    BOOL sameChannelName = (!s_tpkBoundChannelName.length && !channelName.length) ||
        (s_tpkBoundChannelName.length && channelName.length &&
         [s_tpkBoundChannelName caseInsensitiveCompare:channelName] == NSOrderedSame);
    if (sameSession && sameChannelName) return;

    // Le contexte peut d'abord arriver avec l'ID seul, puis être complété
    // par la cible IRC. Dans ce cas, conserver le même contexte mais lancer
    // l'historique dès que le nom devient disponible.
    if (sameSession) {
        s_tpkBoundChannelName = [channelName copy];
        if (context.mediaKind == TPKChannelMediaKindLive && channelName.length) {
            [manager initializeRecentHistoryForChannel:channelName force:YES];
        }
        return;
    }

    s_tpkBoundChannelContext = context != nil;
    s_tpkBoundSessionID = context.sessionID;
    s_tpkBoundGeneration = context.generation;
    s_tpkBoundChannelName = [channelName copy];

    [[TPKBadgeProvider sharedProvider] resetChannelBadges];
    dispatch_barrier_async(manager.emoteQueue, ^{
        manager.channelEmotes = @{};
    });
    BOOL isLiveContext = context.mediaKind == TPKChannelMediaKindLive;
    if (isLiveContext && channelName.length) {
        // Cette méthode vide le store puis charge l'historique récent. Elle
        // possède aussi son propre garde-fou de génération contre les
        // réponses HTTP d'une ancienne chaîne.
        [manager initializeRecentHistoryForChannel:channelName force:YES];
    } else {
        [manager.chatMessageStore replaceAllMessages:@[] completion:nil];
    }

    if (!channelID.length) {
        [[TPKEmoteCatalog sharedCatalog] clearActiveChannelScope];
        return;
    }
    [manager loadEmotesForChannelTwitchID:channelID];
    [[TPKBadgeProvider sharedProvider] loadBadgesForChannelID:channelID];
}

static void tpk_setupChannelResolverBindings(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:TPKChannelResolverDidChangeNotification
                            object:[TPKChannelResolver sharedResolver]
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            TPKChannelContext *context = note.userInfo[@"context"];
            tpk_applyResolvedChannelContext(context);
        }];
        tpk_applyResolvedChannelContext(TPKCurrentChannelContext());
    });
}

// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée __attribute__((constructor))
// ────────────────────────────────────────────────────────────


__attribute__((constructor))
static void TwitchTPKInit(void) {
    tpk_setupChannelResolverBindings();
    TPKChannelResolverSetup();

    // Gestes du lecteur.
    tpk_playerGesturesSetup();
    tpk_setupPlayerReloadRuntimeHooks();

    // Doit être installé avant toute création de vue Twitch, notamment le
    // premier écran et les en-têtes de catégories au lancement.
    TPKOLEDModeSetup();

    tpk_setupChatCustomIntegration();

    // Adblock TwitchAdBlock-derived : AVFoundation, contrôleurs pub Swift et
    // hooks Twitch tardifs. Les interceptions NSURLSession/Apollo restent
    // volontairement dans ce fichier afin de ne jamais les swizzler deux fois.
    TPKAdblockInstallRuntimeHooks();
    tpk_installHomeFeatureRuntimeHooks();

    // Verrou d'orientation (bouton ajouté à côté de Share)
    tpk_swizzle_orientation_lock();

    // Tap logger (diagnostic) — swizzle inerte tant que le réglage est OFF.
    TPKTapLoggerSetup();

    // Injection bouton dans ChatInputView
    tpk_swizzle([UIView class],
                 [UIView class],
                 @selector(didMoveToWindow),
                 @selector(tpk_didMoveToWindow));

    // Interception réponses GQL Twitch
    tpk_swizzle_token_capture();
    tpk_swizzle_session();
    tpk_swizzle_apollo_gql();

    // Interception IRC WebSocket
    tpk_swizzle_websocket();

    // Socket chat React Native (31.5) : observateur seul, inerte si absent.
    tpk_swizzle_rn_chat_socket();

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
    // (TPKURLProtocol) restent actifs : ils sont alimentés directement
    // par le join de channel, indépendamment du chat.

    // Section 7TV dans les paramètres Twitch
    [TPKSettingsController installTwitchSettingsIntegration];

    // Même registre de classes résolues que TwitchAdBlock : il rend visibles
    // les cibles qui auraient été renommées par une version de Twitch.
    TPKHookDiagnosticsRegisterKnownTargets();

    // Auto Claim Channel Points — module isolé, piloté par le cycle de vie
    // du ChannelChatViewController et sans scan global des fenêtres.
    TPKAutoClaimSetup();

    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TPKManager sharedManager] setup];
        TPKUpdateCheckerSetup();
        // Catalogue global.
        [TPKBadgeProvider setup];

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[TPKManager sharedManager] addSettingsButton];
            }
        );
    });
}
