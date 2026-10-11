/*
 * Hook diagnostics adapted from TwitchAdBlock's diagnostics registry
 * (Tweak.x / TWABSettingsVC.m, MIT). See THIRD_PARTY_NOTICES.md.
 */

#import "Settings/tpK-hook-diagnostics.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-provider-settings.h"
#import "Picker/tpK-picker-controller.h"
#import <objc/runtime.h>
#import <os/log.h>

// Same ordered registry model as TwitchAdBlock: a descriptor is registered
// once at startup, then the settings page shows which target classes/selectors
// resolved. Selector checks are intentionally kept here rather than in the UI
// so every diagnostic consumer sees the same runtime truth.
static NSMutableArray<NSDictionary<NSString *, id> *> *TPKHookDiagnosticStore(void) {
    static NSMutableArray<NSDictionary<NSString *, id> *> *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableArray array]; });
    return store;
}

static BOOL TPKHookDiagnosticTargetPresent(NSArray<NSString *> *classNames,
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

// Les moteurs Proxy et Local peuvent tourner ensemble en combo. Le snapshot
// de la méthode active est celui utilisé par le runtime AdBlock ; le
// réutiliser ici évite de présenter comme KO les cibles d'un moteur inactif.
static BOOL TPKHookDiagnosticGroupIsApplicable(TPKHookDiagnosticGroup group) {
    switch (group) {
        case TPKHookDiagnosticGroupProxyAdBlock:
            return TPKAdblockActiveMethodUsesProxy();
        case TPKHookDiagnosticGroupLocalVaftAdBlock:
            return TPKAdblockActiveMethodUsesLocal();
        case TPKHookDiagnosticGroupTwitchPlusK:
        default:
            return YES;
    }
}

// Direct adaptation of twab_checkClass, extended with a selector check for
// hooks whose target class can exist while the actual method was renamed.
// A selector is represented by its own row so the broken point is immediately
// visible instead of collapsing several independent hooks into one status.
static void TPKHookDiagnosticRegister(NSString *displayName,
                                       NSArray<NSString *> *classNames,
                                       NSString * _Nullable selectorName,
                                       BOOL classMethod,
                                       TPKHookDiagnosticGroup group) {
    BOOL present = TPKHookDiagnosticTargetPresent(classNames, selectorName,
                                                    classMethod);
    [TPKHookDiagnosticStore() addObject:@{
        @"name": displayName,
        @"classNames": classNames,
        @"selector": selectorName ?: @"",
        @"classMethod": @(classMethod),
        @"group": @(group),
        @"present": @(present),
    }];
    if (!present && TPKHookDiagnosticGroupIsApplicable(group)) {
        os_log_error(OS_LOG_DEFAULT,
            "[TPK-Diagnostics] missing hook target: %{public}@ (Twitch may have renamed it)",
            displayName);
    }
}

void TPKHookDiagnosticsRegisterKnownTargets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ────────────────────────────────────────────────────────────────
        // Proxy AdBlock — cibles hookées uniquement lorsque la méthode
        // active est Proxy. Les cibles home/Turbo (TabBar, Browse,
        // DiscoveryFeed, StandardButton) sont installées dans les deux
        // moteurs et déjà listées dans le groupe TwitchPlusK : pas de
        // doublon ici.
        // ────────────────────────────────────────────────────────────────
        TPKHookDiagnosticRegister(
            @"[TwitchAdBlock] AVURLAsset", @[@"AVURLAsset"], nil, NO,
            TPKHookDiagnosticGroupProxyAdBlock);
        TPKHookDiagnosticRegister(
            @"[TwitchAdBlock] AVPlayer", @[@"AVPlayer"], nil, NO,
            TPKHookDiagnosticGroupProxyAdBlock);
        TPKHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch23FollowingViewController",
            @[@"_TtC6Twitch23FollowingViewController"], nil, NO,
            TPKHookDiagnosticGroupProxyAdBlock);
        TPKHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch27HeadlinerFollowingAdManager",
            @[@"_TtC6Twitch27HeadlinerFollowingAdManager"], nil, NO,
            TPKHookDiagnosticGroupProxyAdBlock);
        TPKHookDiagnosticRegister(
            @"[TwitchAdBlock] URLSessionClient (TK or Apollo)",
            @[@"_TtC9TwitchKit18TKURLSessionClient", @"Apollo.URLSessionClient"],
            nil, NO, TPKHookDiagnosticGroupProxyAdBlock);


        // ────────────────────────────────────────────────────────────────
        // Local (VAFT) AdBlock — chaque classe dynamique et chaque selector
        // ajouté/swizzlé par vaft_initialize() est déclaré ici. Les classes
        // AVFoundation/NSURLSession communes au Proxy sont volontairement
        // répétées : chaque moteur se diagnostique indépendamment.
        // ────────────────────────────────────────────────────────────────
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol +canInitWithRequest:",
            @[@"TASURLProtocol"], @"canInitWithRequest:", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol +canonicalRequestForRequest:",
            @[@"TASURLProtocol"], @"canonicalRequestForRequest:", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol -startLoading",
            @[@"TASURLProtocol"], @"startLoading", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASURLProtocol -stopLoading",
            @[@"TASURLProtocol"], @"stopLoading", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASAssetResourceLoaderDelegate -resourceLoader:shouldWaitForLoadingOfRequestedResource:",
            @[@"TASAssetResourceLoaderDelegate"],
            @"resourceLoader:shouldWaitForLoadingOfRequestedResource:", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] TASAssetResourceLoaderDelegate -resourceLoader:shouldWaitForRenewalOfRequestedResource:",
            @[@"TASAssetResourceLoaderDelegate"],
            @"resourceLoader:shouldWaitForRenewalOfRequestedResource:", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] AVURLAsset -initWithURL:options:",
            @[@"AVURLAsset"], @"initWithURL:options:", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLProtocol +registerClass: (API cible)",
            @[@"NSURLProtocol"], @"registerClass:", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSessionConfiguration +defaultSessionConfiguration",
            @[@"NSURLSessionConfiguration"], @"defaultSessionConfiguration", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSessionConfiguration +ephemeralSessionConfiguration",
            @[@"NSURLSessionConfiguration"], @"ephemeralSessionConfiguration", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession +sessionWithConfiguration:",
            @[@"NSURLSession"], @"sessionWithConfiguration:", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession +sessionWithConfiguration:delegate:delegateQueue:",
            @[@"NSURLSession"], @"sessionWithConfiguration:delegate:delegateQueue:", YES,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession -dataTaskWithRequest:",
            @[@"NSURLSession"], @"dataTaskWithRequest:", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);
        TPKHookDiagnosticRegister(
            @"[Local (VAFT) AdBlock] NSURLSession -dataTaskWithRequest:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithRequest:completionHandler:", NO,
            TPKHookDiagnosticGroupLocalVaftAdBlock);

        // ────────────────────────────────────────────────────────────────
        // TwitchPlusK — uniquement les hooks propres au tweak ou aux
        // fonctionnalités indépendantes des deux moteurs AdBlock.
        // ────────────────────────────────────────────────────────────────
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -numberOfSectionsInTableView:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"numberOfSectionsInTableView:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:numberOfRowsInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:numberOfRowsInSection:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:titleForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:titleForHeaderInSection:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:viewForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:viewForHeaderInSection:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:heightForHeaderInSection:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:heightForHeaderInSection:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:cellForRowAtIndexPath:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:cellForRowAtIndexPath:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] AccountMenuViewController -tableView:didSelectRowAtIndexPath:",
            @[@"_TtC6Twitch25AccountMenuViewController"],
            @"tableView:didSelectRowAtIndexPath:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        // ChannelResolver : résolution de la chaîne courante (live + VOD).
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] ChannelChatConnectionController",
            @[@"Twitch.ChannelChatConnectionController",
              @"_TtC6Twitch31ChannelChatConnectionController"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.MessageString (VOD chat)",
            @[@"Twitch.MessageString", @"_TtC6Twitch13MessageString"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] TabBarController -viewDidAppear:",
            @[@"_TtC6Twitch16TabBarController"], @"viewDidAppear:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] BrowseViewController -viewDidAppear:",
            @[@"_TtC6Twitch20BrowseViewController"], @"viewDidAppear:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] DiscoveryFeedTabViewController -viewDidLayoutSubviews",
            @[@"_TtC6Twitch30DiscoveryFeedTabViewController"],
            @"viewDidLayoutSubviews", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] DiscoveryFeedShelfContainerViewController -viewDidLayoutSubviews",
            @[@"_TtC6Twitch41DiscoveryFeedShelfContainerViewController"],
            @"viewDidLayoutSubviews", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] StandardButton -didMoveToWindow (Twitch Turbo)",
            @[@"_TtC12TwitchCoreUI14StandardButton"], @"didMoveToWindow", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] StandardButton -layoutSubviews (Twitch Turbo)",
            @[@"_TtC12TwitchCoreUI14StandardButton"], @"layoutSubviews", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] FollowingViewController -viewDidLayoutSubviews (Twitch Turbo)",
            @[@"_TtC6Twitch23FollowingViewController"], @"viewDidLayoutSubviews", NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        // Lecteur : gestes, boutons delay/stats et rechargement du stream.
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.TheaterPlayerControlsView (player)",
            @[@"Twitch.TheaterPlayerControlsView",
              @"_TtC6Twitch25TheaterPlayerControlsView"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] IVSPlayer (reload/delay)",
            @[@"IVSPlayer"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.PlayerCoreVideoPlayer (reload)",
            @[@"Twitch.PlayerCoreVideoPlayer"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        // GQL/WebSocket : ces interceptions alimentent les emotes, le chat,
        // Channel Points et keepLiveFeedPlaying, quel que soit l'AdBlock.
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] _TtC9TwitchKit18TKURLSessionClient -URLSession:dataTask:didReceiveData:",
            @[@"_TtC9TwitchKit18TKURLSessionClient"],
            @"URLSession:dataTask:didReceiveData:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Apollo.URLSessionClient -URLSession:dataTask:didReceiveData:",
            @[@"Apollo.URLSessionClient"], @"URLSession:dataTask:didReceiveData:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Apollo.URLSessionClient -URLSession:task:didCompleteWithError:",
            @[@"Apollo.URLSessionClient"], @"URLSession:task:didCompleteWithError:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithRequest:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithRequest:completionHandler:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithURL:completionHandler:",
            @[@"NSURLSession"], @"dataTaskWithURL:completionHandler:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -dataTaskWithRequest:",
            @[@"NSURLSession"], @"dataTaskWithRequest:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSession -uploadTaskWithRequest:fromData:",
            @[@"NSURLSession"], @"uploadTaskWithRequest:fromData:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSMutableURLRequest -setValue:forHTTPHeaderField:",
            @[@"NSMutableURLRequest"], @"setValue:forHTTPHeaderField:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSMutableURLRequest -setAllHTTPHeaderFields:",
            @[@"NSMutableURLRequest"], @"setAllHTTPHeaderFields:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionConfiguration -setHTTPAdditionalHeaders:",
            @[@"NSURLSessionConfiguration"], @"setHTTPAdditionalHeaders:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionWebSocketTask -receiveMessageWithCompletionHandler:",
            @[@"NSURLSessionWebSocketTask"], @"receiveMessageWithCompletionHandler:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionWebSocketTask -sendMessage:completionHandler:",
            @[@"NSURLSessionWebSocketTask"], @"sendMessage:completionHandler:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIView -didMoveToWindow (chat/picker)",
            @[@"UIView"], @"didMoveToWindow", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        // These views are observed through UIView.didMoveToWindow, then used
        // as the concrete insertion points for custom chat and picker.
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] Twitch.ChatTranscriptView (chat custom)",
            @[@"Twitch.ChatTranscriptView"], nil, NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] RCTWebSocketModule -webSocket:didReceiveMessage:",
            @[@"RCTWebSocketModule"], @"webSocket:didReceiveMessage:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        // Orientation : les trois swizzles sont installés à la demande au
        // premier verrouillage, mais leurs vrais points d'accroche restent
        // diagnostiquables dès l'ouverture de l'écran.
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIApplication -supportedInterfaceOrientationsForWindow:",
            @[@"UIApplication"], @"supportedInterfaceOrientationsForWindow:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIViewController -supportedInterfaceOrientations",
            @[@"UIViewController"], @"supportedInterfaceOrientations", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIViewController -prefersInterfaceOrientationLocked",
            @[@"UIViewController"], @"prefersInterfaceOrientationLocked", NO,
            TPKHookDiagnosticGroupTwitchPlusK);

        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIColor +colorWithRed:green:blue:alpha: (OLED)",
            @[@"UIColor"], @"colorWithRed:green:blue:alpha:", YES,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] UIColor -initWithRed:green:blue:alpha: (OLED)",
            @[@"UIColor"], @"initWithRed:green:blue:alpha:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] RCTViewComponentView -setBackgroundColor: (OLED)",
            @[@"RCTViewComponentView"], @"setBackgroundColor:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
        TPKHookDiagnosticRegister(
            @"[TwitchPlusK] RNSScreenContentWrapper -setBackgroundColor: (OLED)",
            @[@"RNSScreenContentWrapper"], @"setBackgroundColor:", NO,
            TPKHookDiagnosticGroupTwitchPlusK);
    });
}

NSArray<NSDictionary<NSString *, id> *> *TPKHookDiagnosticItems(void) {
    TPKHookDiagnosticsRegisterKnownTargets();
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *descriptor in TPKHookDiagnosticStore()) {
        NSArray<NSString *> *classNames = descriptor[@"classNames"];
        NSString *selectorName = descriptor[@"selector"];
        BOOL classMethod = [descriptor[@"classMethod"] boolValue];
        TPKHookDiagnosticGroup group =
            (TPKHookDiagnosticGroup)[descriptor[@"group"] integerValue];
        [items addObject:@{
            @"name": descriptor[@"name"],
            @"group": @(group),
            @"applicable": @(TPKHookDiagnosticGroupIsApplicable(group)),
            @"present": @(TPKHookDiagnosticTargetPresent(classNames,
                                                            selectorName,
                                                            classMethod)),
        }];
    }
    [items addObject:@{
        @"name": @"[TwitchPlusK] Picker chat button (chat-tray-button-bits)",
        @"group": @(TPKHookDiagnosticGroupTwitchPlusK),
        @"applicable": @YES,
        @"present": @(TPKPickerChatButtonReady()),
    }];
    return items.copy;
}

NSArray<NSDictionary<NSString *, id> *> *TPKEmoteProviderDiagnosticItems(void) {
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    NSArray<NSNumber *> *providers = @[
        @(TPKEmoteProviderIDTPK),
        @(TPKEmoteProviderIDBTTV),
        @(TPKEmoteProviderIDFFZ),
    ];
    NSMutableArray<NSDictionary<NSString *, id> *> *items =
        [NSMutableArray arrayWithCapacity:providers.count];

    for (NSNumber *providerNumber in providers) {
        TPKEmoteProviderID provider =
            (TPKEmoteProviderID)providerNumber.integerValue;
        TPKEmoteProviderSnapshot *snapshot =
            [catalog snapshotForProvider:provider];
        TPKExternalEmoteProvider settingsProvider =
            (TPKExternalEmoteProvider)provider;
        BOOL enabled =
            [TPKEmoteProviderSettings isProviderEnabled:settingsProvider];
        NSUInteger count = [catalog allEmotesForProvider:provider].count;

        NSMutableDictionary<NSString *, id> *item = [@{
            @"name": [NSString stringWithFormat:@"%@ API",
                      TPKEmoteProviderName(provider)],
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
