#import "Adblock/Emote/7tv-adblock-emote-proxy.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Adblock/Proxy/7tv-adblock-proxy.h"

static NSString *const kS7TVEmoteProxyEnabledKey = @"s7tv_emote_proxy_enabled";
static NSString *const kS7TVEmoteProxyDefaultKey = @"s7tv_emote_proxy_default";
static NSString *const kS7TVEmoteProxyCustomEnabledKey = @"s7tv_emote_proxy_custom_enabled";
static NSString *const kS7TVEmoteProxyCustomKey = @"s7tv_emote_proxy_custom";
static NSString *const kS7TVEmoteProxySeededKey = @"s7tv_emote_proxy_seeded";

static NSUserDefaults *S7TVEmoteProxyDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

// 1er usage : hérite de la config vidéo, ensuite indépendant.
static void S7TVEmoteProxyEnsureSeeded(void) {
    NSUserDefaults *defaults = S7TVEmoteProxyDefaults();
    if ([defaults boolForKey:kS7TVEmoteProxySeededKey]) return;
    if (![defaults stringForKey:kS7TVEmoteProxyDefaultKey].length) {
        NSString *videoDefault = S7TVAdblockDefaultProxyAddress();
        if (videoDefault.length)
            [defaults setObject:videoDefault forKey:kS7TVEmoteProxyDefaultKey];
    }
    if (![defaults stringForKey:kS7TVEmoteProxyCustomKey]) {
        NSArray<NSString *> *videoCustoms = S7TVAdblockCustomProxyAddresses();
        if (videoCustoms.count) {
            [defaults setObject:[videoCustoms componentsJoinedByString:@"\n"]
                         forKey:kS7TVEmoteProxyCustomKey];
            [defaults setBool:S7TVAdblockCustomProxyIsEnabled()
                      forKey:kS7TVEmoteProxyCustomEnabledKey];
        }
    }
    [defaults setBool:YES forKey:kS7TVEmoteProxySeededKey];
    [defaults synchronize];
}

void S7TVEmoteProxyRegisterDefaults(void) {
    S7TVAdblockRegisterDefaults();
    [S7TVEmoteProxyDefaults() registerDefaults:@{
        kS7TVEmoteProxyEnabledKey: @NO,
        kS7TVEmoteProxyCustomEnabledKey: @NO,
    }];
    S7TVEmoteProxyEnsureSeeded();
}

BOOL S7TVEmoteProxyIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kS7TVEmoteProxyEnabledKey];
}

void S7TVEmoteProxySetEnabled(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kS7TVEmoteProxyEnabledKey];
    [defaults synchronize];
}

NSString *S7TVEmoteProxyDefaultAddress(void) {
    S7TVEmoteProxyEnsureSeeded();
    NSString *selected =
        [S7TVEmoteProxyDefaults() stringForKey:kS7TVEmoteProxyDefaultKey];
    for (NSString *address in S7TVAdblockDefaultProxyAddresses()) {
        if ([address isEqualToString:selected]) return address;
    }
    return S7TVAdblockDefaultProxyAddresses().firstObject;
}

void S7TVEmoteProxySetDefaultAddress(NSString *address) {
    S7TVEmoteProxyEnsureSeeded();
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *candidate in S7TVAdblockDefaultProxyAddresses()) {
        if ([candidate isEqualToString:clean]) {
            [S7TVEmoteProxyDefaults() setObject:clean forKey:kS7TVEmoteProxyDefaultKey];
            [S7TVEmoteProxyDefaults() synchronize];
            S7TVAdblockInvalidateProxyDetectionCache();
            return;
        }
    }
}

static NSArray<NSString *> *S7TVEmoteProxyParseAddresses(NSString *raw) {
    if (!raw.length) return @[];
    NSMutableCharacterSet *separators =
        [NSMutableCharacterSet characterSetWithCharactersInString:@","];
    [separators formUnionWithCharacterSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *addresses = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByCharactersInSet:separators]) {
        NSString *clean = [part stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [addresses addObject:clean];
    }
    return addresses.copy;
}

NSArray<NSString *> *S7TVEmoteProxyCustomAddresses(void) {
    S7TVEmoteProxyEnsureSeeded();
    return S7TVEmoteProxyParseAddresses(
        [S7TVEmoteProxyDefaults() stringForKey:kS7TVEmoteProxyCustomKey]);
}

void S7TVEmoteProxySetCustomAddresses(NSArray<NSString *> *addresses) {
    S7TVEmoteProxyEnsureSeeded();
    NSMutableArray<NSString *> *cleanAddresses = [NSMutableArray array];
    for (NSString *address in addresses) {
        NSString *clean = [address stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cleanAddresses addObject:clean];
    }
    NSString *joined = [cleanAddresses componentsJoinedByString:@"\n"];
    if (joined.length) {
        [S7TVEmoteProxyDefaults() setObject:joined forKey:kS7TVEmoteProxyCustomKey];
    } else {
        [S7TVEmoteProxyDefaults() removeObjectForKey:kS7TVEmoteProxyCustomKey];
    }
    S7TVAdblockInvalidateProxyDetectionCache();
}

BOOL S7TVEmoteProxyCustomIsEnabled(void) {
    S7TVEmoteProxyEnsureSeeded();
    return [S7TVEmoteProxyDefaults() boolForKey:kS7TVEmoteProxyCustomEnabledKey];
}

void S7TVEmoteProxySetCustomEnabled(BOOL enabled) {
    S7TVEmoteProxyEnsureSeeded();
    [S7TVEmoteProxyDefaults() setBool:enabled forKey:kS7TVEmoteProxyCustomEnabledKey];
    S7TVAdblockInvalidateProxyDetectionCache();
}

NSArray<NSString *> *S7TVEmoteProxyEffectiveAddresses(void) {
    if (S7TVEmoteProxyCustomIsEnabled()) {
        NSArray<NSString *> *customs = S7TVEmoteProxyCustomAddresses();
        if (customs.count) return customs;
    }
    NSString *def = S7TVEmoteProxyDefaultAddress();
    return def.length ? @[def] : @[];
}

// Hosts emotes uniquement : jamais usher/gql/Helix/CDN Twitch.
static BOOL S7TVEmoteProxyIsEmoteHost(NSString *host) {
    if (!host.length) return NO;
    NSString *h = host.lowercaseString;
    static NSSet<NSString *> *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithObjects:
            @"7tv.io",
            @"cdn.7tv.app", @"cdn.7tv.io",
            @"api.betterttv.net", @"cdn.betterttv.net",
            @"api.frankerfacez.com", @"cdn.frankerfacez.com", nil];
    });
    if ([exact containsObject:h]) return YES;
    return [h hasSuffix:@".7tv.app"] || [h hasSuffix:@".7tv.io"] ||
           [h hasSuffix:@".betterttv.net"] || [h hasSuffix:@".frankerfacez.com"];
}

NSURL *S7TVEmoteProxyRewriteURL(NSURL *URL) {
    if (!URL || !S7TVEmoteProxyIsEnabled()) return URL;
    if (!S7TVEmoteProxyIsEmoteHost(URL.host)) return URL;
    NSString *original = URL.absoluteString;
    if (!original.length) return URL;
    // Premier proxy préfixe utilisable gagne.
    for (NSString *address in S7TVEmoteProxyEffectiveAddresses()) {
        NSURL *proxyURL = S7TVAdblockNormalizedProxyURL(address);
        if (!proxyURL) continue;
        // Luminous ignoré : ne sait pas forwarder.
        if (!S7TVAdblockProxyIsPrefixStyle(proxyURL)) continue;
        NSString *base = proxyURL.absoluteString ?: @"";
        if (!base.length) continue;
        if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
        if ([original hasPrefix:base]) return URL;
        NSURL *rewritten = [NSURL URLWithString:[base stringByAppendingString:original]];
        if (rewritten) return rewritten;
    }
    return URL;
}
