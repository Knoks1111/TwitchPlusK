#import "Adblock/7tv-adblock-settings.h"

NSString *const S7TVAdblockEnabledKey            = @"s7tv_adblock_enabled";
NSString *const S7TVAdblockProxyEnabledKey       = @"s7tv_adblock_proxy_enabled";
NSString *const S7TVAdblockCustomProxyEnabledKey = @"s7tv_adblock_custom_proxy_enabled";
NSString *const S7TVAdblockCustomProxyKey        = @"s7tv_adblock_custom_proxy";
NSString *const S7TVAdblockHideAdFreeButtonKey  = @"s7tv_adblock_hide_go_ad_free";
NSString *const S7TVAdblockMethodKey             = @"s7tv_adblock_method";

static NSUserDefaults *S7TVAdblockDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

void S7TVAdblockRegisterDefaults(void) {
    // Toggle maître : OFF par défaut (décision validée). Aucune migration :
    // les anciens utilisateurs qui reposaient sur l'ancien default implicite
    // ON sans jamais écrire la clé passent OFF après mise à jour (accepté).
    [S7TVAdblockDefaults() registerDefaults:@{
        S7TVAdblockEnabledKey: @NO,
        S7TVAdblockProxyEnabledKey: @YES,
        S7TVAdblockCustomProxyEnabledKey: @NO,
        // Même valeur par défaut que TwitchAdBlock v0.1.13.
        S7TVAdblockHideAdFreeButtonKey: @YES,
    }];
}

// ── Snapshots runtime ────────────────────────────────────────────────────────
// Lecture O(1) pour les hot paths (fishhooks weak, NSURLProtocol, callbacks
// réseau fréquents). Aucune lecture NSUserDefaults ni registerDefaults ici —
// c'est la leçon de la PR #2. Le snapshot enabled est rafraîchissable à chaud
// (setter + import) ; le snapshot méthode est figé au lancement.

static volatile BOOL s_method_snapshot_done = NO;
static volatile BOOL s_method_is_local_snapshot = NO;
static volatile BOOL s_enabled_snapshot = NO;
static volatile BOOL s_hide_ad_free_snapshot = YES;

void S7TVAdblockRefreshRuntimeSnapshots(void) {
    S7TVAdblockRegisterDefaults();
    NSUserDefaults *defaults = S7TVAdblockDefaults();
    s_enabled_snapshot = [defaults boolForKey:S7TVAdblockEnabledKey];
    s_hide_ad_free_snapshot = [defaults boolForKey:S7TVAdblockHideAdFreeButtonKey];
}

BOOL S7TVAdblockEnabledFast(void) {
    return s_enabled_snapshot;
}

BOOL S7TVAdblockHideAdFreeButtonEnabledFast(void) {
    return s_hide_ad_free_snapshot;
}

void S7TVAdblockTakeRuntimeMethodSnapshot(void) {
    NSString *method = [S7TVAdblockDefaults() stringForKey:S7TVAdblockMethodKey];
    // Valeur absente/invalide → fallback déterministe Proxy. Ne fait rien
    // tant que le toggle maître est OFF.
    s_method_is_local_snapshot = [method isEqualToString:@"local"];
    s_method_snapshot_done = YES;
}

BOOL S7TVAdblockActiveMethodIsLocal(void) {
    if (!s_method_snapshot_done) S7TVAdblockTakeRuntimeMethodSnapshot();
    return s_method_is_local_snapshot;
}

S7TVAdblockMethod S7TVAdblockActiveMethod(void) {
    return S7TVAdblockActiveMethodIsLocal() ? S7TVAdblockMethodLocalVaft
                                            : S7TVAdblockMethodProxy;
}

// ── Méthode configurée (settings / persistance uniquement) ──────────────────

BOOL S7TVAdblockConfiguredMethodIsLocal(void) {
    NSString *method = [S7TVAdblockDefaults() stringForKey:S7TVAdblockMethodKey];
    return [method isEqualToString:@"local"];
}

S7TVAdblockMethod S7TVAdblockConfiguredMethod(void) {
    return S7TVAdblockConfiguredMethodIsLocal() ? S7TVAdblockMethodLocalVaft
                                                : S7TVAdblockMethodProxy;
}

void S7TVAdblockSetConfiguredMethod(S7TVAdblockMethod method) {
    NSString *value = (method == S7TVAdblockMethodLocalVaft) ? @"local" : @"proxy";
    [S7TVAdblockDefaults() setObject:value forKey:S7TVAdblockMethodKey];
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

NSArray<NSString *> *S7TVAdblockCustomProxyAddresses(void) {
    NSString *raw = S7TVAdblockCustomProxyAddress();
    if (!raw.length) return @[];
    // TwitchAdBlock accepte aussi les virgules pour migrer sans perte les
    // anciennes valeurs, mais les nouvelles sauvegardes utilisent des lignes.
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

void S7TVAdblockSetEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockEnabledKey];
    s_enabled_snapshot = enabled;
}

void S7TVAdblockSetProxyEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockProxyEnabledKey];
}

void S7TVAdblockSetCustomProxyEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockCustomProxyEnabledKey];
}

void S7TVAdblockSetHideAdFreeButtonEnabled(BOOL enabled) {
    [S7TVAdblockDefaults() setBool:enabled forKey:S7TVAdblockHideAdFreeButtonKey];
    s_hide_ad_free_snapshot = enabled;
}

void S7TVAdblockSetCustomProxyAddress(NSString *address) {
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length) [S7TVAdblockDefaults() setObject:clean forKey:S7TVAdblockCustomProxyKey];
    else [S7TVAdblockDefaults() removeObjectForKey:S7TVAdblockCustomProxyKey];
}

void S7TVAdblockSetCustomProxyAddresses(NSArray<NSString *> *addresses) {
    NSMutableArray<NSString *> *cleanAddresses = [NSMutableArray array];
    for (NSString *address in addresses) {
        NSString *clean = [address stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cleanAddresses addObject:clean];
    }
    S7TVAdblockSetCustomProxyAddress([cleanAddresses componentsJoinedByString:@"\n"]);
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
    return S7TVAdblockEffectiveProxyAddresses().firstObject;
}

NSArray<NSString *> *S7TVAdblockEffectiveProxyAddresses(void) {
    return S7TVAdblockCustomProxyIsEnabled()
        ? S7TVAdblockCustomProxyAddresses()
        : @[S7TVAdblockDefaultProxyAddress()];
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
