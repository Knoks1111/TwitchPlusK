#import "System/tpK-system-tab-visibility.h"
#import "Core/tpK-core-manager.h"
#import <objc/runtime.h>
#import <math.h>

static NSString *const kTPKTabKeyPrefix = @"tpk_tab_hidden_";
static NSString *const kTPKTabOrderKey = @"tpk_tab_order";

static size_t TPKTabNormalizeOrder(const NSInteger *input, size_t count, NSInteger *output) {
    BOOL seen[TPK_TAB_ITEM_COUNT] = {0};
    size_t used = 0;
    for (size_t i = 0; i < count; i++) {
        NSInteger item = input[i];
        if (item < 0 || item >= TPK_TAB_ITEM_COUNT || seen[item]) continue;
        seen[item] = YES;
        output[used++] = item;
    }
    for (NSInteger item = 0; item < TPK_TAB_ITEM_COUNT; item++)
        if (!seen[item]) output[used++] = item;
    return used;
}

static NSUInteger TPKTabVisibleIndex(const NSInteger *order, size_t count, unsigned hidden, NSUInteger stockIndex) {
    if (stockIndex >= TPK_TAB_ITEM_COUNT || (hidden & (1U << stockIndex))) return NSNotFound;
    NSUInteger index = 0;
    for (size_t i = 0; i < count; i++) {
        NSInteger item = order[i];
        if (item < 0 || item >= TPK_TAB_ITEM_COUNT || (hidden & (1U << item))) continue;
        if ((NSUInteger)item == stockIndex) return index;
        index++;
    }
    return NSNotFound;
}

static NSArray<NSNumber *> *TPKTabNormalizedOrder(id value) {
    NSArray *raw = [value isKindOfClass:NSArray.class] ? value : @[];
    NSMutableData *data = [NSMutableData dataWithLength:raw.count * sizeof(NSInteger)];
    NSInteger *input = data.mutableBytes;
    for (NSUInteger i = 0; i < raw.count; i++) {
        id item = raw[i];
        input[i] = [item isKindOfClass:NSNumber.class] && isfinite([item doubleValue]) &&
                   [item doubleValue] == [item integerValue] ? [item integerValue] : -1;
    }
    NSInteger output[TPK_TAB_ITEM_COUNT];
    size_t count = TPKTabNormalizeOrder(input, raw.count, output);
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [order addObject:@(output[i])];
    return order;
}

NSArray<NSNumber *> *tpk_tabItemOrder(void) {
    return TPKTabNormalizedOrder([NSUserDefaults.standardUserDefaults objectForKey:kTPKTabOrderKey]);
}

void tpk_setTabItemOrder(NSArray<NSNumber *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:TPKTabNormalizedOrder(order) forKey:kTPKTabOrderKey];
}

static NSString *TPKTabKey(TPKTabItem item) {
    return [kTPKTabKeyPrefix stringByAppendingFormat:@"%ld", (long)item];
}

void tpk_registerTabVisibilityDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        for (TPKTabItem item = 0; item < TPK_TAB_ITEM_COUNT; item++) {            defaults[TPKTabKey(item)] = @NO;
        }
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];
    });
}

BOOL tpk_tabItemHidden(TPKTabItem item) {
    if (item < 0 || item >= TPK_TAB_ITEM_COUNT) return NO;
    tpk_registerTabVisibilityDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:TPKTabKey(item)];
}

void tpk_setTabItemHidden(TPKTabItem item, BOOL hidden) {
    if (item < 0 || item >= TPK_TAB_ITEM_COUNT) return;
    tpk_registerTabVisibilityDefaults();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (hidden) {
        [defaults setBool:YES forKey:TPKTabKey(item)];
    } else {
        // Clé absente = aucune préférence.
        [defaults removeObjectForKey:TPKTabKey(item)];
    }
}

NSInteger tpk_tabVisibleCount(void) {
    NSInteger visible = 0;
    for (TPKTabItem item = 0; item < TPK_TAB_ITEM_COUNT; item++) {
        if (!tpk_tabItemHidden(item)) visible++;
    }
    return visible;
}

// Index d'origine → index réel.
NSUInteger tpk_tabVisibilityIndexForStockIndex(NSUInteger stockIndex) {
    NSInteger order[TPK_TAB_ITEM_COUNT];
    NSArray<NSNumber *> *items = tpk_tabItemOrder();
    unsigned hidden = 0;
    for (NSUInteger i = 0; i < TPK_TAB_ITEM_COUNT; i++) {
        order[i] = items[i].integerValue;
        if (tpk_tabItemHidden((TPKTabItem)i)) hidden |= 1U << i;
    }
    return TPKTabVisibleIndex(order, TPK_TAB_ITEM_COUNT, hidden, stockIndex);
}

// Contrôleurs d'origine (Twitch).
static NSArray<UIViewController *> *s_stockControllers = nil;
static BOOL TPKTabApplying;

static BOOL TPKTabVisibilityAnythingHidden(void) {
    for (TPKTabItem item = 0; item < TPK_TAB_ITEM_COUNT; item++) {
        if (tpk_tabItemHidden(item)) return YES;
    }
    return NO;
}

// Référence sans les onglets masqués.
static NSArray<UIViewController *> *TPKDesiredControllers(void) {
    if (!s_stockControllers.count) return @[];
    NSMutableArray<UIViewController *> *desired = [NSMutableArray array];
    for (NSNumber *raw in tpk_tabItemOrder()) {
        NSUInteger i = raw.unsignedIntegerValue;
        if (i < s_stockControllers.count && !tpk_tabItemHidden((TPKTabItem)i))
            [desired addObject:s_stockControllers[i]];
    }
    return desired;
}

// Liste incomplète : intacte.
static NSArray<UIViewController *> *TPKFilterStockControllers(
    NSArray<UIViewController *> *incoming) {
    if (TPKTabApplying || incoming.count != TPK_TAB_ITEM_COUNT) return incoming;
    if (s_stockControllers.count && [incoming isEqualToArray:TPKDesiredControllers()]) return incoming;

    // Nouvelle référence.
    s_stockControllers = [incoming copy];

    NSArray<UIViewController *> *desired = TPKDesiredControllers();
    return desired.count ? desired : incoming;   // jamais zéro onglet
}

// Barre déjà réduite par le masquage ?
static BOOL TPKIsManagedTabBar(UITabBarController *controller) {
    if (!TPKTabVisibilityAnythingHidden()) return NO;
    NSUInteger count = controller.viewControllers.count;
    return count > 0 && count == (NSUInteger)tpk_tabVisibleCount();
}

@interface TPKTabVisibilityHooks : NSObject
- (void)tpk_setViewControllers:(NSArray<UIViewController *> *)viewControllers;
- (void)tpk_setViewControllers:(NSArray<UIViewController *> *)viewControllers
                       animated:(BOOL)animated;
- (void)tpk_setSelectedIndex:(NSUInteger)selectedIndex;
- (void)tpk_setSelectedViewController:(UIViewController *)viewController;
@end

@implementation TPKTabVisibilityHooks

- (void)tpk_setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    [self tpk_setViewControllers:TPKFilterStockControllers(viewControllers)];
}

- (void)tpk_setViewControllers:(NSArray<UIViewController *> *)viewControllers
                       animated:(BOOL)animated {
    [self tpk_setViewControllers:TPKFilterStockControllers(viewControllers)
                         animated:animated];
}

// Index hors liste filtrée : vient de l'ordre d'origine, à traduire.
- (void)tpk_setSelectedIndex:(NSUInteger)selectedIndex {
    UITabBarController *controller = (UITabBarController *)self;
    NSUInteger visible = controller.viewControllers.count;

    if (TPKIsManagedTabBar(controller) && selectedIndex >= visible) {
        NSUInteger translated = tpk_tabVisibilityIndexForStockIndex(selectedIndex);
        if (translated != NSNotFound && translated < visible) {
            [self tpk_setSelectedIndex:translated];
            return;
        }
        // Masqué : ignorer.
        return;
    }
    [self tpk_setSelectedIndex:selectedIndex];
}

// Contrôleur absent de la barre : ignorer.
- (void)tpk_setSelectedViewController:(UIViewController *)viewController {
    UITabBarController *controller = (UITabBarController *)self;
    NSArray<UIViewController *> *list = controller.viewControllers;
    BOOL inList = list.count &&
        [list indexOfObjectIdenticalTo:viewController] != NSNotFound;

    if (viewController && !inList && TPKTabVisibilityAnythingHidden()) return;
    [self tpk_setSelectedViewController:viewController];
}

@end

// Fige l'implémentation héritée avant swizzle.
static void TPKTabPinOriginalMethod(Class target, SEL selector) {
    Method method = class_getInstanceMethod(target, selector);
    if (!method) return;
    class_addMethod(target, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
}

static BOOL TPKTabSelectionHooksInstalled = NO;
static BOOL TPKTabFilterHooksInstalled = NO;

void tpk_installTabVisibilityHooks(void) {
    @synchronized (NSObject.class) {
        if (!TPKTabSelectionHooksInstalled) {
            TPKTabSelectionHooksInstalled = YES;
            TPKTabPinOriginalMethod(UITabBarController.class,
                                     @selector(setSelectedIndex:));
            TPKTabPinOriginalMethod(UITabBarController.class,
                                     @selector(setSelectedViewController:));
            tpk_swizzle(UITabBarController.class, TPKTabVisibilityHooks.class,
                         @selector(setSelectedIndex:),
                         @selector(tpk_setSelectedIndex:));
            tpk_swizzle(UITabBarController.class, TPKTabVisibilityHooks.class,
                         @selector(setSelectedViewController:),
                         @selector(tpk_setSelectedViewController:));
        }

        Class target = NSClassFromString(@"_TtC6Twitch16TabBarController");
        if (!target) return;
        if (TPKTabFilterHooksInstalled) return;
        TPKTabFilterHooksInstalled = YES;

        TPKTabPinOriginalMethod(target, @selector(setViewControllers:));
        TPKTabPinOriginalMethod(target, @selector(setViewControllers:animated:));
        tpk_swizzle(target, TPKTabVisibilityHooks.class,
                     @selector(setViewControllers:),
                     @selector(tpk_setViewControllers:));
        tpk_swizzle(target, TPKTabVisibilityHooks.class,
                     @selector(setViewControllers:animated:),
                     @selector(tpk_setViewControllers:animated:));
    }
}

void tpk_tabVisibilityApply(UITabBarController *controller) {
    if (![controller isKindOfClass:UITabBarController.class]) return;

    NSArray<UIViewController *> *current = controller.viewControllers;
    if (!current.count) return;

    // Barre complète = nouvelle référence.
    if (current.count == TPK_TAB_ITEM_COUNT) {
        BOOL sameControllers = s_stockControllers.count == current.count;
        for (UIViewController *candidate in current)
            if ([s_stockControllers indexOfObjectIdenticalTo:candidate] == NSNotFound) sameControllers = NO;
        if (!sameControllers) s_stockControllers = [current copy];
    }
    if (!s_stockControllers.count) return;

    NSArray<UIViewController *> *desired = TPKDesiredControllers();
    if (!desired.count || [current isEqualToArray:desired]) return;

    // Barre inconnue : ne rien toucher.
    BOOL recognised = NO;
    for (UIViewController *candidate in current) {
        if ([s_stockControllers indexOfObjectIdenticalTo:candidate] != NSNotFound) {
            recognised = YES;
            break;
        }
    }
    if (!recognised) return;

    // La sélection suit le contrôleur, pas l'index.
    UIViewController *selected = controller.selectedViewController;
    TPKTabApplying = YES;
    controller.viewControllers = desired;
    TPKTabApplying = NO;
    NSUInteger index = selected ? [desired indexOfObjectIdenticalTo:selected] : NSNotFound;
    controller.selectedIndex = (index == NSNotFound) ? 0 : index;
}

// Barre principale, même sous un écran présenté.
static UITabBarController *TPKFindTabBarController(UIViewController *root) {
    if (!root) return nil;

    if ([root isKindOfClass:UITabBarController.class]) {
        Class twitchClass = NSClassFromString(@"_TtC6Twitch16TabBarController");
        if (!twitchClass || [root isKindOfClass:twitchClass]) {
            return (UITabBarController *)root;
        }
    }

    UITabBarController *found = TPKFindTabBarController(root.presentedViewController);
    if (found) return found;
    for (UIViewController *child in root.childViewControllers) {
        found = TPKFindTabBarController(child);
        if (found) return found;
    }
    return nil;
}

void tpk_tabVisibilityApplyNow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UITabBarController *controller =
                TPKFindTabBarController(window.rootViewController);
            if (controller) {
                tpk_tabVisibilityApply(controller);
                return;
            }
        }
    }
}
