/*
 * Hook diagnostics adapted from TwitchAdBlock's diagnostics registry
 * (Tweak.x / TWABSettingsVC.m, MIT). See THIRD_PARTY_NOTICES.md.
 */

#import "Diagnostics/7tv-hook-diagnostics.h"
#import <objc/runtime.h>
#import <os/log.h>

// Same ordered registry model as TwitchAdBlock: a descriptor is registered
// once at startup, then the settings page shows which target classes resolved.
static NSMutableArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticStore(void) {
    static NSMutableArray<NSDictionary<NSString *, id> *> *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableArray array]; });
    return store;
}

static BOOL S7TVHookDiagnosticClassesPresent(NSArray<NSString *> *classNames) {
    for (NSString *className in classNames) {
        if (objc_getClass(className.UTF8String) != nil) return YES;
    }
    return NO;
}

// Direct adaptation of twab_checkClass: record the target at boot and emit a
// useful runtime log when Twitch has renamed or not yet loaded it.
static void S7TVHookDiagnosticRegister(NSString *displayName,
                                       NSArray<NSString *> *classNames) {
    BOOL present = S7TVHookDiagnosticClassesPresent(classNames);
    [S7TVHookDiagnosticStore() addObject:@{
        @"name": displayName,
        @"classNames": classNames,
        @"present": @(present),
    }];
    if (!present) {
        os_log_error(OS_LOG_DEFAULT,
            "[S7TV-Diagnostics] missing hook target: %{public}@ (Twitch may have renamed it)",
            displayName);
    }
}

void S7TVHookDiagnosticsRegisterKnownTargets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // TwitchAdBlock-derived hooks. The multi-candidate entry keeps the
        // source project's "TK or Apollo" compatibility check.
        S7TVHookDiagnosticRegister(@"[TwitchAdBlock] AVURLAsset", @[@"AVURLAsset"]);
        S7TVHookDiagnosticRegister(@"[TwitchAdBlock] AVPlayer", @[@"AVPlayer"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch27AssetResourceLoaderDelegate",
            @[@"_TtC6Twitch27AssetResourceLoaderDelegate"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch23FollowingViewController",
            @[@"_TtC6Twitch23FollowingViewController"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch27HeadlinerFollowingAdManager",
            @[@"_TtC6Twitch27HeadlinerFollowingAdManager"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC12TwitchCoreUI14StandardButton",
            @[@"_TtC12TwitchCoreUI14StandardButton"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] URLSessionClient (TK or Apollo)",
            @[@"_TtC9TwitchKit18TKURLSessionClient", @"Apollo.URLSessionClient"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch16TabBarController",
            @[@"_TtC6Twitch16TabBarController"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch20BrowseViewController",
            @[@"_TtC6Twitch20BrowseViewController"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch30DiscoveryFeedTabViewController",
            @[@"_TtC6Twitch30DiscoveryFeedTabViewController"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchAdBlock] _TtC6Twitch41DiscoveryFeedShelfContainerViewController",
            @[@"_TtC6Twitch41DiscoveryFeedShelfContainerViewController"]);

        // TwitchPlusK-specific targets, shown by the same source diagnostic.
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] _TtC6Twitch25AccountMenuViewController",
            @[@"_TtC6Twitch25AccountMenuViewController"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] Apollo.URLSessionClient",
            @[@"Apollo.URLSessionClient"]);
        S7TVHookDiagnosticRegister(
            @"[TwitchPlusK] NSURLSessionWebSocketTask",
            @[@"NSURLSessionWebSocketTask"]);
    });
}

NSArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticItems(void) {
    S7TVHookDiagnosticsRegisterKnownTargets();
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *descriptor in S7TVHookDiagnosticStore()) {
        NSArray<NSString *> *classNames = descriptor[@"classNames"];
        [items addObject:@{
            @"name": descriptor[@"name"],
            @"present": @(S7TVHookDiagnosticClassesPresent(classNames)),
        }];
    }
    return items.copy;
}
