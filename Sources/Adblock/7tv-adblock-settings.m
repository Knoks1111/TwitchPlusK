#import "Adblock/7tv-adblock-settings.h"

NSString *const S7TVAdblockEnabledKey            = @"s7tv_adblock_enabled";
NSString *const S7TVAdblockProxyEnabledKey       = @"s7tv_adblock_proxy_enabled";
NSString *const S7TVAdblockCustomProxyEnabledKey = @"s7tv_adblock_custom_proxy_enabled";
NSString *const S7TVAdblockCustomProxyKey        = @"s7tv_adblock_custom_proxy";
NSString *const S7TVAdblockHideAdFreeButtonKey  = @"s7tv_adblock_hide_go_ad_free";

static NSUserDefaults *S7TVAdblockDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

void S7TVAdblockRegisterDefaults(void) {
    [S7TVAdblockDefaults() registerDefaults:@{
        S7TVAdblockEnabledKey: @YES,
        S7TVAdblockProxyEnabledKey: @YES,
        S7TVAdblockCustomProxyEnabledKey: @NO,
        // Même valeur par défaut que TwitchAdBlock v0.1.13.
        S7TVAdblockHideAdFreeButtonKey: @YES,
    }];
}

BOOL S7TVAdblockIsEnabled(void) {
    S7TVAdblockRegisterDefaults();
    return [S7TVAdblockDefaults() boolForKey:S7TVAdblockEnabledKey];
}

BOOL S7TVAdblockProxyIsEnabled(void) {
    S7TVAdblockRegisterDefaults();
    return [S7TVAdblockDefaults() boolForKey:S7TVAdblockProxyEnabledKey];
}

BOOL S7TVAdblockCustomProxyIsEnabled(void) {
    S7TVAdblockRegisterDefaults();
    return [S7TVAdblockDefaults() boolForKey:S7TVAdblockCustomProxyEnabledKey];
}

BOOL S7TVAdblockHideAdFreeButtonIsEnabled(void) {
    S7TVAdblockRegisterDefaults();
    return [S7TVAdblockDefaults() boolForKey:S7TVAdblockHideAdFreeButtonKey];
}

NSString *S7TVAdblockCustomProxyAddress(void) {
    return [S7TVAdblockDefaults() stringForKey:S7TVAdblockCustomProxyKey];
}

void S7TVAdblockSetEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockEnabledKey];
}

void S7TVAdblockSetProxyEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockProxyEnabledKey];
}

void S7TVAdblockSetCustomProxyEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockCustomProxyEnabledKey];
}

void S7TVAdblockSetHideAdFreeButtonEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockHideAdFreeButtonKey];
}

void S7TVAdblockSetCustomProxyAddress(NSString *address) {
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length) [S7TVAdblockDefaults() setObject:clean forKey:S7TVAdblockCustomProxyKey];
    else [S7TVAdblockDefaults() removeObjectForKey:S7TVAdblockCustomProxyKey];
}

// Exact XOR-obfuscated default proxy shipped by TwitchAdBlock v0.1.13.
// Keeping the bytes unchanged avoids inventing or substituting infrastructure.
NSString *S7TVAdblockDefaultProxyAddress(void) {
    static const uint8_t key = 0xA5;
    static const uint8_t bytes[] = {
        0xf2, 0xd1, 0xe8, 0xe1, 0xee, 0xc3, 0x9f, 0x90, 0xf4, 0x95,
        0xed, 0x93, 0xf3, 0xe5, 0x94, 0x93, 0x9d, 0x8b, 0x9c, 0x95,
        0x8b, 0x94, 0x9c, 0x93, 0x8b, 0x94, 0x90, 0x93, 0x9f, 0x9d,
        0x95, 0x95, 0x95,
    };
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t count = sizeof(bytes);
        char decoded[count + 1];
        for (size_t index = 0; index < count; index++) decoded[index] = bytes[index] ^ key;
        decoded[count] = '\0';
        cached = [NSString stringWithUTF8String:decoded];
    });
    return cached;
}

NSString *S7TVAdblockEffectiveProxyAddress(void) {
    return S7TVAdblockCustomProxyIsEnabled()
        ? S7TVAdblockCustomProxyAddress()
        : S7TVAdblockDefaultProxyAddress();
}

NSArray<NSString *> *S7TVAdblockEffectiveProxyAddresses(void) {
    NSString *raw = S7TVAdblockEffectiveProxyAddress();
    if (!raw.length) return @[];
    NSMutableCharacterSet *separators =
        [NSMutableCharacterSet characterSetWithCharactersInString:@","];
    [separators formUnionWithCharacterSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByCharactersInSet:separators]) {
        NSString *clean = [part stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [result addObject:clean];
    }
    return result.copy;
}

NSURL *S7TVAdblockNormalizedProxyURL(NSString *address) {
    if (!address.length) return nil;
    NSString *normalized = address;
    if (![normalized hasPrefix:@"http://"] && ![normalized hasPrefix:@"https://"]) {
        normalized = [@"http://" stringByAppendingString:normalized];
    }
    NSURL *url = [NSURL URLWithString:normalized];
    return (url.host.length && [url.scheme hasPrefix:@"http"]) ? url : nil;
}

BOOL S7TVAdblockUserIsAdExempt(NSString *queryString) {
    if (!queryString.length) return NO;
    NSURLComponents *components = [NSURLComponents new];
    components.percentEncodedQuery = queryString;
    NSString *token = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"token"]) {
            token = item.value;
            break;
        }
    }
    if (!token.length) return NO;
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *payload = data
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (![payload isKindOfClass:NSDictionary.class]) return NO;
    return [payload[@"subscriber"] boolValue] || [payload[@"turbo"] boolValue];
}
