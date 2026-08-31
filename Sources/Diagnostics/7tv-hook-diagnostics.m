/*
 * Hook diagnostics adapted from TwitchAdBlock's diagnostics registry
 * (Tweak.x / TWABSettingsVC.m, MIT). See THIRD_PARTY_NOTICES.md.
 */

#import "Diagnostics/7tv-hook-diagnostics.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import <objc/runtime.h>
#import <os/log.h>

// Same ordered registry model as TwitchAdBlock: a descriptor is registered
// once at startup, then the settings page shows which target classes/selectors
// resolved. Selector checks are intentionally kept here rather than in the UI
// so every diagnostic consumer sees the same runtime truth.
static NSMutableArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticStore(void) {
    static NSMutableArray<NSDictionary<NSString *, id> *> *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableArray array]; });
    return store;
}

static BOOL S7TVHookDiagnosticTargetPresent(NSArray<NSString *> *classNames,
                                            NSString *selectorName,
                                            BOOL classMethod) {
    for (NSString *className in classNames) {
        Class targetClass = objc_getClass(className.UTF8String);
        if (!targetClass) continue;
        if (!selectorName.length) return YES;

        SEL selector = NSSelectorFromString(selectorName);
        Method method = classMethod
            ? class_getClassMethod(targetClass, selector)
            : class_getInstanceMethod(targetClass, selector);
        if (method) return YES;
    }
    return NO;
}

// Les deux moteurs ne sont pas installés en même temps.  Le snapshot de la
// méthode active est celui utilisé par le runtime AdBlock ; le réutiliser ici
// évite de présenter comme KO les cibles de l'autre moteur (ou des deux
// moteurs lorsque l'AdBlock est désactivé).
static BOOL S7TVHookDiagnosticGroupIsApplicable(S7TVHookDiagnosticGroup group) {
    switch (group) {
        case S7TVHookDiagnosticGroupProxyAdBlock:
            return S7TVAdblockActiveMethodIsProxy();
        case S7TVHookDiagnosticGroupLocalVaftAdBlock:
            return S7TVAdblockActiveMethodIsLocal();
        case S7TVHookDiagnosticGroupTwitchPlusK:
        default:
            return YES;
    }
}

// Direct adaptation of twab_checkClass, extended with a selector check for
// hooks whose target class can exist while the actual method was renamed.
// A selector is represented by its own row so the broken point is immediately
// visible instead of collapsing several independent hooks into one status.
static void S7TVHookDiagnosticRegister(NSString *displayName,
                                       NSArray<NSString *> *classNames,
                                       NSString * _Nullable selectorName,
                                       BOOL classMethod,
                                       S7TVHookDiagnosticGroup group) {
    BOOL present = S7TVHookDiagnosticTargetPresent(classNames, selectorName,
                                                    classMethod);
    [S7TVHookDiagnosticStore() addObject:@{
        @"name": displayName,
        @"classNames": classNames,
        @"selector": selectorName ?: @"",
        @"classMethod": @(classMethod),
        @"group": @(group),
        @"present": @(present),
    }];
    if (!present && S7TVHookDiagnosticGroupIsApplicable(group)) {
        os_log_error(OS_LOG_DEFAULT,
            "[S7TV-Diagnostics] missing hook target: %{public}@ (Twitch may have renamed it)",
            displayName);
    }
}

void S7TVHookDiagnosticsRegisterKnownTargets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ────────────────────────────────────────────────────────────────
        // Proxy AdBlock — registre historique de TwitchAdBlock.  On conserve
        // volontairement ces 10 entrées globales (sans détailler les selectors)
        // pour garder le diagnostic Proxy identique à l'ancien écran.
        // ────────────────────────────────────────────────────────────────
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] AVURLAsset", @[@"AVURLAsset"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] AVPlayer", @[@"AVPlayer"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch23FollowingViewController",
            @[@"_TtC6Twitch23FollowingViewController"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch27HeadlinerFollowingAdManager",
            @[@"_TtC6Twitch27HeadlinerFollowingAdManager"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC12TwitchCoreUI14StandardButton",
            @[@"_TtC12TwitchCoreUI14StandardButton"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] URLSessionClient (TK or Apollo)",
            @[@"_TtC9TwitchKit18TKURLSessionClient", @"Apollo.URLSessionClient"],
            nil, NO, S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch16TabBarController",
            @[@"_TtC6Twitch16TabBarController"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch20BrowseViewController",
            @[@"_TtC6Twitch20BrowseViewController"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch30DiscoveryFeedTabViewController",
            @[@"_TtC6Twitch30DiscoveryFeedTabViewController"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch41DiscoveryFeedShelfContainerViewController",
            @[@"_TtC6Twitch41DiscoveryFeedShelfContainerViewController"], nil, NO,
            S7TVHookDiagnosticGroupProxyAdBlock);

        // ────────────────────────────────────────────────────────────────
        // Local (VAFT) AdBlock — chaque classe dynamique et chaque selector
        // ajouté/swizzlé par vaft_initialize() est déclaré ici. Les classes
        // AVFoundation/NSURLSession communes au Proxy sont volontairement
        // répétées : chaque moteur se diagnostique indépendamment.
        // ────────────────────────────────────────────────────────────────
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol +canInitWithRequest:",
            @[@"TASURLProtocol"], @"canInitWithRequest:", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol +canonicalRequestForRequest:",
            @[@"TASURLProtocol"], @"canonicalRequestForRequest:", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol -startLoading",
            @[@"TASURLProtocol"], @"startLoading", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol -stopLoading",
            @[@"TASURLProtocol"], @"stopLoading", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASAssetResourceLoaderDelegate -resourceLoader:shouldWaitForLoadingOfRequestedResource:",
            @[@"TASAssetResourceLoaderDelegate"],
            @"resourceLoader:shouldWaitForLoadingOfRequestedResource:", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASAssetResourceLoaderDelegate -resourceLoader:shouldWaitForRenewalOfRequestedResource:",
            @[@"TASAssetResourceLoaderDelegate"],
            @"resourceLoader:shouldWaitForRenewalOfRequestedResource:", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] AVURLAsset -initWithURL:options:",
            @[@"AVURLAsset"], @"initWithURL:options:", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLProtocol +registerClass: (API cible)",
            @[@"NSURLProtocol"], @"registerClass:", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSessionConfiguration +defaultSessionConfiguration",
            @[@"NSURLSessionConfiguration"], @"defaultSessionConfiguration", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSessionConfiguration +ephemeralSessionConfiguration",
            @[@"NSURLSessionConfiguration"], @"ephemeralSessionConfiguration", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession +sessionWithConfiguration:",
            @[@"NSURLSession"], @"sessionWithConfiguration:", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession +sessionWithConfiguration:delegate:delegateQueue:",
            @[@"NSURLSession"], @"sessionWithConfiguration:delegate:delegateQueue:", YES,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession -dataTaskWithRequest:",
            @[@"NSURLSession"], @"dataTaskWithRequest:", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);
        S7TVHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession -dataTaskWithRequest:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithRequest:completionHandler:", NO,
            S7TVHookDiagnosticGroupLocalVaftAdBlock);

        // ────────────────────────────────────────────────────────────────
        // TwitchPlusK — uniquement les hooks propres au tweak ou aux
        // fonctionnalités indépendantes des deux moteurs AdBlock.
        // ────────────────────────────────────────────────────────────────
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -numberOfSectionsInTableView:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"numberOfSectionsInTableView:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:numberOfRowsInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:numberOfRowsInSection:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:titleForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:titleForHeaderInSection:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:viewForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:viewForHeaderInSection:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:heightForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:heightForHeaderInSection:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:cellForRowAtIndexPath:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:cellForRowAtIndexPath:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:didSelectRowAtIndexPath:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:didSelectRowAtIndexPath:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);

        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] TabBarController -viewDidAppear:",
            @[@"_TtC6Twitch16TabBarController"], @"viewDidAppear:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] BrowseViewController -viewDidAppear:",
            @[@"_TtC6Twitch20BrowseViewController"], @"viewDidAppear:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] DiscoveryFeedTabViewController -viewDidLayoutSubviews",
            @[@"_TtC6Twitch30DiscoveryFeedTabViewController"],
            @"viewDidLayoutSubviews", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] DiscoveryFeedShelfContainerViewController -viewDidLayoutSubviews",
            @[@"_TtC6Twitch41DiscoveryFeedShelfContainerViewController"],
            @"viewDidLayoutSubviews", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] StandardButton -didMoveToWindow (Twitch Turbo)",
            @[@"_TtC12TwitchCoreUI14StandardButton"], @"didMoveToWindow", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] StandardButton -layoutSubviews (Twitch Turbo)",
            @[@"_TtC12TwitchCoreUI14StandardButton"], @"layoutSubviews", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] FollowingViewController -viewDidLayoutSubviews (Twitch Turbo)",
            @[@"_TtC6Twitch23FollowingViewController"], @"viewDidLayoutSubviews", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);

        // GQL/WebSocket : ces interceptions alimentent les emotes, le chat,
        // Channel Points et keepLiveFeedPlaying, quel que soit l'AdBlock.
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] _TtC9TwitchKit18TKURLSessionClient -URLSession:dataTask:didReceiveData:",
            @[@"_TtC9TwitchKit18TKURLSessionClient"],
            @"URLSession:dataTask:didReceiveData:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] Apollo.URLSessionClient -URLSession:dataTask:didReceiveData:",
            @[@"Apollo.URLSessionClient"], @"URLSession:dataTask:didReceiveData:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] Apollo.URLSessionClient -URLSession:task:didCompleteWithError:",
            @[@"Apollo.URLSessionClient"], @"URLSession:task:didCompleteWithError:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithRequest:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithRequest:completionHandler:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithURL:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithURL:completionHandler:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithRequest:",
            @[@"NSURLSession"], @"dataTaskWithRequest:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -uploadTaskWithRequest:fromData:",
            @[@"NSURLSession"], @"uploadTaskWithRequest:fromData:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSMutableURLRequest -setValue:forHTTPHeaderField:",
            @[@"NSMutableURLRequest"], @"setValue:forHTTPHeaderField:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSMutableURLRequest -setAllHTTPHeaderFields:",
            @[@"NSMutableURLRequest"], @"setAllHTTPHeaderFields:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionConfiguration -setHTTPAdditionalHeaders:",
            @[@"NSURLSessionConfiguration"], @"setHTTPAdditionalHeaders:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionWebSocketTask -receiveMessageWithCompletionHandler:",
            @[@"NSURLSessionWebSocketTask"], @"receiveMessageWithCompletionHandler:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionWebSocketTask -sendMessage:completionHandler:",
            @[@"NSURLSessionWebSocketTask"], @"sendMessage:completionHandler:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] UIView -didMoveToWindow (chat/picker)",
            @[@"UIView"], @"didMoveToWindow", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        // These views are observed through UIView.didMoveToWindow, then used
        // as the concrete insertion points for custom chat and picker.
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.ChatTranscriptView (chat custom)",
            @[@"Twitch.ChatTranscriptView"], nil, NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.ChatInputView (bouton picker)",
            @[@"Twitch.ChatInputView"], nil, NO,
            S7TVHookDiagnosticGroupTwitchPlusK);

        // Orientation : les trois swizzles sont installés à la demande au
        // premier verrouillage, mais leurs vrais points d'accroche restent
        // diagnostiquables dès l'ouverture de l'écran.
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] UIApplication -supportedInterfaceOrientationsForWindow:",
            @[@"UIApplication"], @"supportedInterfaceOrientationsForWindow:", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] UIViewController -supportedInterfaceOrientations",
            @[@"UIViewController"], @"supportedInterfaceOrientations", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] UIViewController -shouldAutorotate",
            @[@"UIViewController"], @"shouldAutorotate", NO,
            S7TVHookDiagnosticGroupTwitchPlusK);

        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] CoreUIDarkTheme (OLED)",
            @[@"_TtC12TwitchCoreUI15CoreUIDarkTheme"], nil, NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] DarkMobileUITheme (OLED)",
            @[@"_TtC12TwitchCoreUI17DarkMobileUITheme"], nil, NO,
            S7TVHookDiagnosticGroupTwitchPlusK);
    });
}

NSArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticItems(void) {
    S7TVHookDiagnosticsRegisterKnownTargets();
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *descriptor in S7TVHookDiagnosticStore()) {
        NSArray<NSString *> *classNames = descriptor[@"classNames"];
        NSString *selectorName = descriptor[@"selector"];
        BOOL classMethod = [descriptor[@"classMethod"] boolValue];
        S7TVHookDiagnosticGroup group =
            (S7TVHookDiagnosticGroup)[descriptor[@"group"] integerValue];
        [items addObject:@{
            @"name": descriptor[@"name"],
            @"group": @(group),
            @"applicable": @(S7TVHookDiagnosticGroupIsApplicable(group)),
            @"present": @(S7TVHookDiagnosticTargetPresent(classNames,
                                                            selectorName,
                                                            classMethod)),
        }];
    }
    return items.copy;
}

NSArray<NSDictionary<NSString *, id> *> *S7TVEmoteProviderDiagnosticItems(void) {
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    NSArray<NSNumber *> *providers = @[
        @(S7TVEmoteProviderIDSevenTV),
        @(S7TVEmoteProviderIDBTTV),
        @(S7TVEmoteProviderIDFFZ),
    ];
    NSMutableArray<NSDictionary<NSString *, id> *> *items =
        [NSMutableArray arrayWithCapacity:providers.count];

    for (NSNumber *providerNumber in providers) {
        S7TVEmoteProviderID provider =
            (S7TVEmoteProviderID)providerNumber.integerValue;
        S7TVEmoteProviderSnapshot *snapshot =
            [catalog snapshotForProvider:provider];
        S7TVExternalEmoteProvider settingsProvider =
            (S7TVExternalEmoteProvider)provider;
        BOOL enabled =
            [S7TVEmoteProviderSettings isProviderEnabled:settingsProvider];
        NSUInteger count = [catalog allEmotesForProvider:provider].count;

        NSMutableDictionary<NSString *, id> *item = [@{
            @"name": [NSString stringWithFormat:@"%@ API",
                      S7TVEmoteProviderName(provider)],
            @"provider": providerNumber,
            @"enabled": @(enabled),
            @"state": @(snapshot.state),
            @"count": @(count),
        } mutableCopy];
        if (snapshot.errorMessage.length) {
            item[@"errorMessage"] = snapshot.errorMessage;
        }
        [items addObject:item.copy];
    }
    return items.copy;
}
