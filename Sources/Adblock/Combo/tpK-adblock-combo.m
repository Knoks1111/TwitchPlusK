#import "Adblock/Combo/tpK-adblock-combo.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/tpK-adblock-settings.h"

static NSString *const kTPKComboProxyDefaultKey = @"tpk_adblock_combo_proxy_default";
static NSString *const kTPKComboProxyCustomEnabledKey = @"tpk_adblock_combo_proxy_custom_enabled";
static NSString *const kTPKComboProxyCustomKey = @"tpk_adblock_combo_proxy_custom";

static NSUserDefaults *TPKComboProxyDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void TPKAdblockComboProxyRegisterDefaults(void) {
    TPKAdblockRegisterDefaults();
    [TPKComboProxyDefaults() registerDefaults:@{
        kTPKComboProxyDefaultKey: @"https://proxy4.rte.net.ru/",
        kTPKComboProxyCustomEnabledKey: @NO,
    }];
}

NSArray<NSString *> *TPKAdblockComboProxyAddresses(void) {
    return @[@"https://proxy4.rte.net.ru/",
             @"https://proxy5.rte.net.ru/",
             @"https://proxy6.rte.net.ru/",
             @"https://proxy7.rte.net.ru/"];
}

NSString *TPKAdblockComboProxyDefaultAddress(void) {
    NSString *selected =
        [TPKComboProxyDefaults() stringForKey:kTPKComboProxyDefaultKey];
    for (NSString *address in TPKAdblockComboProxyAddresses()) {
        if ([address isEqualToString:selected]) return address;
    }
    return TPKAdblockComboProxyAddresses().firstObject;
}

void TPKAdblockComboProxySetDefaultAddress(NSString *address) {
    NSString *clean = [address stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *candidate in TPKAdblockComboProxyAddresses()) {
        if ([candidate isEqualToString:clean]) {
            [TPKComboProxyDefaults() setObject:clean forKey:kTPKComboProxyDefaultKey];
            [TPKComboProxyDefaults() synchronize];
            TPKAdblockInvalidateProxyDetectionCache();
            return;
        }
    }
}

static NSArray<NSString *> *TPKComboProxyParseAddresses(NSString *raw) {
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

NSArray<NSString *> *TPKAdblockComboProxyCustomAddresses(void) {
    return TPKComboProxyParseAddresses(
        [TPKComboProxyDefaults() stringForKey:kTPKComboProxyCustomKey]);
}

void TPKAdblockComboProxySetCustomAddresses(NSArray<NSString *> *addresses) {
    NSMutableArray<NSString *> *cleanAddresses = [NSMutableArray array];
    for (NSString *address in addresses) {
        NSString *clean = [address stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length) [cleanAddresses addObject:clean];
    }
    NSString *joined = [cleanAddresses componentsJoinedByString:@"\n"];
    if (joined.length) {
        [TPKComboProxyDefaults() setObject:joined forKey:kTPKComboProxyCustomKey];
    } else {
        [TPKComboProxyDefaults() removeObjectForKey:kTPKComboProxyCustomKey];
    }
    [TPKComboProxyDefaults() synchronize];
    TPKAdblockInvalidateProxyDetectionCache();
}

BOOL TPKAdblockComboProxyCustomIsEnabled(void) {
    return [TPKComboProxyDefaults() boolForKey:kTPKComboProxyCustomEnabledKey];
}

void TPKAdblockComboProxySetCustomEnabled(BOOL enabled) {
    [TPKComboProxyDefaults() setBool:enabled forKey:kTPKComboProxyCustomEnabledKey];
    [TPKComboProxyDefaults() synchronize];
    TPKAdblockInvalidateProxyDetectionCache();
}

NSArray<NSString *> *TPKAdblockComboProxyEffectiveAddresses(void) {
    if (TPKAdblockComboProxyCustomIsEnabled()) {
        NSArray<NSString *> *customs = TPKAdblockComboProxyCustomAddresses();
        if (customs.count) return customs;
    }
    NSString *def = TPKAdblockComboProxyDefaultAddress();
    return def.length ? @[def] : @[];
}
