#import "Adblock/Emote/tpK-adblock-emote-proxy.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/Combo/tpK-adblock-combo.h"

static NSString *const kTPKEmoteProxyEnabledKey = @"tpk_emote_proxy_enabled";
static NSString *const kTPKEmoteProxyDefaultKey = @"tpk_emote_proxy_default";
static NSString *const kTPKEmoteProxyCustomEnabledKey = @"tpk_emote_proxy_custom_enabled";
static NSString *const kTPKEmoteProxyCustomKey = @"tpk_emote_proxy_custom";
static NSString *const kTPKEmoteProxySeededKey = @"tpk_emote_proxy_seeded";

static NSUserDefaults *TPKEmoteProxyDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

// 1er usage : hérite du défaut combo (RTE), ensuite indépendant.
static void TPKEmoteProxyEnsureSeeded(void) {
    NSUserDefaults *defaults = TPKEmoteProxyDefaults();
    if ([defaults boolForKey:kTPKEmoteProxySeededKey]) return;
    if (![defaults stringForKey:kTPKEmoteProxyDefaultKey].length) {
        NSString *comboDefault = TPKAdblockComboProxyDefaultAddress();
        if (comboDefault.length)
            [defaults setObject:comboDefault forKey:kTPKEmoteProxyDefaultKey];
    }
    if (![defaults stringForKey:kTPKEmoteProxyCustomKey]) {
        NSArray<NSString *> *comboCustoms = TPKAdblockComboProxyCustomAddresses();
        if (comboCustoms.count) {
            [defaults setObject:[comboCustoms componentsJoinedByString:@"\n"]
                         forKey:kTPKEmoteProxyCustomKey];
            [defaults setBool:TPKAdblockComboProxyCustomIsEnabled()
                       forKey:kTPKEmoteProxyCustomEnabledKey];
        }
    }
    [defaults setBool:YES forKey:kTPKEmoteProxySeededKey];
    [defaults synchronize];
}

void TPKEmoteProxyRegisterDefaults(void) {
    TPKAdblockRegisterDefaults();
    [TPKEmoteProxyDefaults() registerDefaults:@{
        kTPKEmoteProxyEnabledKey: @NO,
        kTPKEmoteProxyCustomEnabledKey: @NO,
    }];
    TPKEmoteProxyEnsureSeeded();
}

BOOL TPKEmoteProxyIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kTPKEmoteProxyEnabledKey];
}

void TPKEmoteProxySetEnabled(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kTPKEmoteProxyEnabledKey];
    [defaults synchronize];
}

NSString *TPKEmoteProxyDefaultAddress(void) {
    TPKEmoteProxyEnsureSeeded();
    NSString *selected =
        [TPKEmoteProxyDefaults() stringForKey:kTPKEmoteProxyDefaultKey];
    for (NSString *address in TPKAdblockComboProxyAddresses()) {
        if ([address isEqualToString:selected]) return address;
    }
    return TPKAdblockComboProxyAddresses().firstObject;
}

void TPKEmoteProxySetDefaultAddress(NSString *address) {
    TPKEmoteProxyEnsureSeeded();
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *candidate in TPKAdblockComboProxyAddresses()) {
        if ([candidate isEqualToString:clean]) {
            [TPKEmoteProxyDefaults() setObject:clean forKey:kTPKEmoteProxyDefaultKey];
            [TPKEmoteProxyDefaults() synchronize];
            TPKAdblockInvalidateProxyDetectionCache();
            return;
        }
    }
}

static NSArray<NSString *> *TPKEmoteProxyParseAddresses(NSString *raw) {
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

NSArray<NSString *> *TPKEmoteProxyCustomAddresses(void) {
    TPKEmoteProxyEnsureSeeded();
    return TPKEmoteProxyParseAddresses(
        [TPKEmoteProxyDefaults() stringForKey:kTPKEmoteProxyCustomKey]);
}

void TPKEmoteProxySetCustomAddresses(NSArray<NSString *> *addresses) {
    TPKEmoteProxyEnsureSeeded();
    NSMutableArray<NSString *> *cleanAddresses = [NSMutableArray array];
    for (NSString *address in addresses) {
        NSString *clean = [address stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cleanAddresses addObject:clean];
    }
    NSString *joined = [cleanAddresses componentsJoinedByString:@"\n"];
    if (joined.length) {
        [TPKEmoteProxyDefaults() setObject:joined forKey:kTPKEmoteProxyCustomKey];
    } else {
        [TPKEmoteProxyDefaults() removeObjectForKey:kTPKEmoteProxyCustomKey];
    }
    TPKAdblockInvalidateProxyDetectionCache();
}

BOOL TPKEmoteProxyCustomIsEnabled(void) {
    TPKEmoteProxyEnsureSeeded();
    return [TPKEmoteProxyDefaults() boolForKey:kTPKEmoteProxyCustomEnabledKey];
}

void TPKEmoteProxySetCustomEnabled(BOOL enabled) {
    TPKEmoteProxyEnsureSeeded();
    [TPKEmoteProxyDefaults() setBool:enabled forKey:kTPKEmoteProxyCustomEnabledKey];
    TPKAdblockInvalidateProxyDetectionCache();
}

NSArray<NSString *> *TPKEmoteProxyEffectiveAddresses(void) {
    if (TPKEmoteProxyCustomIsEnabled()) {
        NSArray<NSString *> *customs = TPKEmoteProxyCustomAddresses();
        if (customs.count) return customs;
    }
    NSString *def = TPKEmoteProxyDefaultAddress();
    return def.length ? @[def] : @[];
}

// Hosts emotes uniquement : jamais usher/gql/Helix/CDN Twitch.
static BOOL TPKEmoteProxyIsEmoteHost(NSString *host) {
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

NSURL *TPKEmoteProxyRewriteURL(NSURL *URL) {
    if (!URL || !TPKEmoteProxyIsEnabled()) return URL;
    if (!TPKEmoteProxyIsEmoteHost(URL.host)) return URL;
    NSString *original = URL.absoluteString;
    if (!original.length) return URL;
    // Premier proxy préfixe utilisable gagne.
    for (NSString *address in TPKEmoteProxyEffectiveAddresses()) {
        NSURL *proxyURL = TPKAdblockNormalizedProxyURL(address);
        if (!proxyURL) continue;
        // Luminous ignoré : ne sait pas forwarder.
        if (!TPKAdblockProxyIsPrefixStyle(proxyURL)) continue;
        NSString *base = proxyURL.absoluteString ?: @"";
        if (!base.length) continue;
        if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
        if ([original hasPrefix:base]) return URL;
        NSURL *rewritten = [NSURL URLWithString:[base stringByAppendingString:original]];
        if (rewritten) return rewritten;
    }
    return URL;
}
