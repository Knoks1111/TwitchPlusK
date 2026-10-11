#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"

NSString *const TPKAdblockEnabledKey            = @"tpk_adblock_enabled";
NSString *const TPKAdblockProxyEnabledKey       = @"tpk_adblock_proxy_enabled";
NSString *const TPKAdblockCustomProxyEnabledKey = @"tpk_adblock_custom_proxy_enabled";
NSString *const TPKAdblockCustomProxyKey        = @"tpk_adblock_custom_proxy";
NSString *const TPKAdblockDefaultProxyKey       = @"tpk_adblock_default_proxy";
NSString *const TPKAdblockHideAdFreeButtonKey  = @"tpk_adblock_hide_go_ad_free";
NSString *const TPKAdblockMethodKey             = @"tpk_adblock_method";
NSString *const TPKAdblockRuntimeStateDidChangeNotification =
    @"TPKAdblockRuntimeStateDidChangeNotification";

static NSUserDefaults *TPKAdblockDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

// Built-in en dernier (secours). Décodé uniquement au besoin.
static NSString *TPKAdblockBuiltinProxyAddress(void);

void TPKAdblockRegisterDefaults(void) {
    // Toggle maître : OFF par défaut (décision validée). Aucune migration :
    // les anciens utilisateurs qui reposaient sur l'ancien default implicite
    // ON sans jamais écrire la clé passent OFF après mise à jour (accepté).
    // Défaut : eu.luminous.dev (built-in = dernier recours).
    [TPKAdblockDefaults() registerDefaults:@{
        TPKAdblockEnabledKey: @NO,
        TPKAdblockProxyEnabledKey: @YES,
        TPKAdblockCustomProxyEnabledKey: @NO,
        TPKAdblockDefaultProxyKey: @"https://eu.luminous.dev",
        // Même valeur par défaut que TwitchAdBlock v0.1.13.
        TPKAdblockHideAdFreeButtonKey: @YES,
    }];
}

// ── Snapshots runtime ────────────────────────────────────────────────────────
// Lecture O(1) pour les hot paths (fishhooks weak, NSURLProtocol, callbacks
// réseau fréquents). Aucune lecture NSUserDefaults ni registerDefaults ici —
// c'est la leçon de la PR #2. Le snapshot enabled est rafraîchissable à chaud
// (setter + import) ; le snapshot méthode est figé au lancement.

static volatile BOOL s_method_snapshot_done = NO;
static volatile TPKAdblockMethod s_method_snapshot = TPKAdblockMethodDisabled;
static volatile BOOL s_enabled_snapshot = NO;
static volatile BOOL s_hide_ad_free_snapshot = YES;

static TPKAdblockMethod TPKAdblockMethodFromStored(NSString * _Nullable stored) {
    if ([stored isEqualToString:@"local"]) return TPKAdblockMethodLocalVaft;
    if ([stored isEqualToString:@"proxy"]) return TPKAdblockMethodProxy;
    if ([stored isEqualToString:@"combo"]) return TPKAdblockMethodProxyPlusLocal;
    /* Absente, "disabled" ou valeur inconnue/corrompue -> Disabled:
     * etat neutre et sur, aucun moteur n'agit sans choix explicite. */
    return TPKAdblockMethodDisabled;
}

void TPKAdblockRefreshRuntimeSnapshots(void) {
    TPKAdblockRegisterDefaults();
    NSUserDefaults *defaults = TPKAdblockDefaults();
    BOOL oldEnabled = s_enabled_snapshot;
    s_enabled_snapshot = [defaults boolForKey:TPKAdblockEnabledKey];
    s_hide_ad_free_snapshot = [defaults boolForKey:TPKAdblockHideAdFreeButtonKey];
    if (oldEnabled != s_enabled_snapshot) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKAdblockRuntimeStateDidChangeNotification
                          object:nil];
    }
}

BOOL TPKAdblockEnabledFast(void) {
    return s_enabled_snapshot;
}

BOOL TPKAdblockHideAdFreeButtonEnabledFast(void) {
    return s_hide_ad_free_snapshot;
}

void TPKAdblockTakeRuntimeMethodSnapshot(void) {
    s_method_snapshot = TPKAdblockMethodFromStored(
        [TPKAdblockDefaults() stringForKey:TPKAdblockMethodKey]);
    s_method_snapshot_done = YES;
}

TPKAdblockMethod TPKAdblockActiveMethod(void) {
    if (!s_method_snapshot_done) TPKAdblockTakeRuntimeMethodSnapshot();
    return s_method_snapshot;
}

BOOL TPKAdblockActiveMethodIsLocal(void) {
    return TPKAdblockActiveMethod() == TPKAdblockMethodLocalVaft;
}

BOOL TPKAdblockActiveMethodIsProxy(void) {
    return TPKAdblockActiveMethod() == TPKAdblockMethodProxy;
}

BOOL TPKAdblockActiveMethodUsesProxy(void) {
    TPKAdblockMethod method = TPKAdblockActiveMethod();
    return method == TPKAdblockMethodProxy || method == TPKAdblockMethodProxyPlusLocal;
}

BOOL TPKAdblockActiveMethodUsesLocal(void) {
    TPKAdblockMethod method = TPKAdblockActiveMethod();
    return method == TPKAdblockMethodLocalVaft || method == TPKAdblockMethodProxyPlusLocal;
}

// ── Méthode configurée (settings / persistance uniquement) ──────────────────

TPKAdblockMethod TPKAdblockConfiguredMethod(void) {
    return TPKAdblockMethodFromStored(
        [TPKAdblockDefaults() stringForKey:TPKAdblockMethodKey]);
}

BOOL TPKAdblockConfiguredMethodIsLocal(void) {
    return TPKAdblockConfiguredMethod() == TPKAdblockMethodLocalVaft;
}

void TPKAdblockSetConfiguredMethod(TPKAdblockMethod method) {
    NSString *value;
    switch (method) {
        case TPKAdblockMethodDisabled:  value = @"disabled"; break;
        case TPKAdblockMethodLocalVaft: value = @"local";    break;
        case TPKAdblockMethodProxyPlusLocal: value = @"combo"; break;
        case TPKAdblockMethodProxy:
        default:                         value = @"proxy";    break;
    }
    [TPKAdblockDefaults() setObject:value forKey:TPKAdblockMethodKey];
    // Fiabilise le test terrain « sélection puis relaunch immédiat ».
    [TPKAdblockDefaults() synchronize];
}

BOOL TPKAdblockIsEnabled(void) {
    TPKAdblockRegisterDefaults();
    return [TPKAdblockDefaults() boolForKey:TPKAdblockEnabledKey];
}

BOOL TPKAdblockProxyIsEnabled(void) {
    TPKAdblockRegisterDefaults();
    return [TPKAdblockDefaults() boolForKey:TPKAdblockProxyEnabledKey];
}

BOOL TPKAdblockCustomProxyIsEnabled(void) {
    TPKAdblockRegisterDefaults();
    return [TPKAdblockDefaults() boolForKey:TPKAdblockCustomProxyEnabledKey];
}

BOOL TPKAdblockHideAdFreeButtonIsEnabled(void) {
    TPKAdblockRegisterDefaults();
    return [TPKAdblockDefaults() boolForKey:TPKAdblockHideAdFreeButtonKey];
}

NSString *TPKAdblockCustomProxyAddress(void) {
    return [TPKAdblockDefaults() stringForKey:TPKAdblockCustomProxyKey];
}

NSArray<NSString *> *TPKAdblockCustomProxyAddresses(void) {
    NSString *raw = TPKAdblockCustomProxyAddress();
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

void TPKAdblockSetEnabled(BOOL enabled) {
    [TPKAdblockDefaults() setBool:enabled forKey:TPKAdblockEnabledKey];
    BOOL changed = s_enabled_snapshot != enabled;
    s_enabled_snapshot = enabled;
    if (changed) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKAdblockRuntimeStateDidChangeNotification
                          object:nil];
    }
}

void TPKAdblockSetEnabledForNextLaunch(BOOL enabled) {
    // La méthode active est figée au lancement. Quand l'utilisateur choisit
    // une autre méthode, on prépare son activation sans allumer par erreur
    // le moteur actuellement installé avant le redémarrage demandé.
    [TPKAdblockDefaults() setBool:enabled forKey:TPKAdblockEnabledKey];
    [TPKAdblockDefaults() synchronize];
}

void TPKAdblockSetProxyEnabled(BOOL enabled) {
    [TPKAdblockDefaults() setBool:enabled forKey:TPKAdblockProxyEnabledKey];
    TPKAdblockInvalidateProxyDetectionCache();
}

void TPKAdblockSetCustomProxyEnabled(BOOL enabled) {
    [TPKAdblockDefaults() setBool:enabled forKey:TPKAdblockCustomProxyEnabledKey];
    TPKAdblockInvalidateProxyDetectionCache();
}

void TPKAdblockSetHideAdFreeButtonEnabled(BOOL enabled) {
    [TPKAdblockDefaults() setBool:enabled forKey:TPKAdblockHideAdFreeButtonKey];
    s_hide_ad_free_snapshot = enabled;
}

void TPKAdblockSetCustomProxyAddress(NSString *address) {
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length) [TPKAdblockDefaults() setObject:clean forKey:TPKAdblockCustomProxyKey];
    else [TPKAdblockDefaults() removeObjectForKey:TPKAdblockCustomProxyKey];
    TPKAdblockInvalidateProxyDetectionCache();
}

void TPKAdblockSetCustomProxyAddresses(NSArray<NSString *> *addresses) {
    NSMutableArray<NSString *> *cleanAddresses = [NSMutableArray array];
    for (NSString *address in addresses) {
        NSString *clean = [address stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cleanAddresses addObject:clean];
    }
    TPKAdblockSetCustomProxyAddress([cleanAddresses componentsJoinedByString:@"\n"]);
}

// Exact XOR-obfuscated default proxy shipped by TwitchAdBlock v0.1.13.
// Keeping the bytes unchanged avoids inventing or substituting infrastructure.
static NSString *TPKAdblockBuiltinProxyAddress(void) {
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

NSArray<NSString *> *TPKAdblockDefaultProxyAddresses(void) {
    return @[@"https://eu.luminous.dev",
             @"https://eu2.luminous.dev",
             TPKAdblockBuiltinProxyAddress()];
}

NSString *TPKAdblockDefaultProxyAddress(void) {
    NSString *selected = [TPKAdblockDefaults() stringForKey:TPKAdblockDefaultProxyKey];
    NSArray<NSString *> *all = TPKAdblockDefaultProxyAddresses();
    for (NSString *address in all) {
        if ([address isEqualToString:selected]) return address;
    }
    return all.firstObject ?: TPKAdblockBuiltinProxyAddress();
}

void TPKAdblockSetDefaultProxyAddress(NSString *address) {
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL isSupported = NO;
    for (NSString *candidate in TPKAdblockDefaultProxyAddresses()) {
        if ([candidate isEqualToString:clean]) {
            isSupported = YES;
            break;
        }
    }
    if (!isSupported) return;
    [TPKAdblockDefaults() setObject:clean forKey:TPKAdblockDefaultProxyKey];
    [TPKAdblockDefaults() synchronize];
    TPKAdblockInvalidateProxyDetectionCache();
}

NSString *TPKAdblockEffectiveProxyAddress(void) {
    return TPKAdblockEffectiveProxyAddresses().firstObject;
}

NSArray<NSString *> *TPKAdblockEffectiveProxyAddresses(void) {
    return TPKAdblockCustomProxyIsEnabled()
        ? TPKAdblockCustomProxyAddresses()
        : @[TPKAdblockDefaultProxyAddress()];
}

NSURL *TPKAdblockNormalizedProxyURL(NSString *address) {
    if (!address.length) return nil;
    NSString *normalized = address;
    if (![normalized hasPrefix:@"http://"] && ![normalized hasPrefix:@"https://"]) {
        normalized = [@"http://" stringByAppendingString:normalized];
    }
    NSURL *url = [NSURL URLWithString:normalized];
    return (url.host.length && [url.scheme hasPrefix:@"http"]) ? url : nil;
}

BOOL TPKAdblockUserIsAdExempt(NSString *queryString) {
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
