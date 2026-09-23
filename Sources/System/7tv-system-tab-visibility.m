#import "System/7tv-system-tab-visibility.h"
#import "Core/7tv-core-manager.h"
#import <objc/runtime.h>

static NSString *const kS7TVTabKeyPrefix = @"s7tv_tab_hidden_";

static NSString *S7TVTabKey(S7TVTabItem item) {
    return [kS7TVTabKeyPrefix stringByAppendingFormat:@"%ld", (long)item];
}

void s7tv_registerTabVisibilityDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        for (S7TVTabItem item = 0; item < S7TV_TAB_ITEM_COUNT; item++) {            defaults[S7TVTabKey(item)] = @NO;
        }
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];
    });
}

BOOL s7tv_tabItemHidden(S7TVTabItem item) {
    if (item < 0 || item >= S7TV_TAB_ITEM_COUNT) return NO;
    s7tv_registerTabVisibilityDefaults();
    return [NSUserDefaults.standardUserDefaults boolForKey:S7TVTabKey(item)];
}

void s7tv_setTabItemHidden(S7TVTabItem item, BOOL hidden) {
    if (item < 0 || item >= S7TV_TAB_ITEM_COUNT) return;
    s7tv_registerTabVisibilityDefaults();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (hidden) {
        [defaults setBool:YES forKey:S7TVTabKey(item)];
    } else {
        // Clé absente = aucune préférence.
        [defaults removeObjectForKey:S7TVTabKey(item)];
    }
}

NSInteger s7tv_tabVisibleCount(void) {
    NSInteger visible = 0;
    for (S7TVTabItem item = 0; item < S7TV_TAB_ITEM_COUNT; item++) {
        if (!s7tv_tabItemHidden(item)) visible++;
    }
    return visible;
}

// Index d'origine → index réel.
NSUInteger s7tv_tabVisibilityIndexForStockIndex(NSUInteger stockIndex) {
    if (stockIndex >= S7TV_TAB_ITEM_COUNT) return NSNotFound;
    if (s7tv_tabItemHidden((S7TVTabItem)stockIndex)) return NSNotFound;

    NSUInteger index = 0;
    for (NSUInteger i = 0; i < stockIndex; i++) {
        if (!s7tv_tabItemHidden((S7TVTabItem)i)) index++;
    }
    return index;
}

// Contrôleurs d'origine (Twitch).
static NSArray<UIViewController *> *s_stockControllers = nil;

static BOOL S7TVTabVisibilityAnythingHidden(void) {
    for (S7TVTabItem item = 0; item < S7TV_TAB_ITEM_COUNT; item++) {
        if (s7tv_tabItemHidden(item)) return YES;
    }
    return NO;
}

// Référence sans les onglets masqués.
static NSArray<UIViewController *> *S7TVDesiredControllers(void) {
    if (!s_stockControllers.count) return @[];
    NSMutableArray<UIViewController *> *desired = [NSMutableArray array];
    for (NSUInteger i = 0; i < s_stockControllers.count; i++) {
        BOOL hidden = i < (NSUInteger)S7TV_TAB_ITEM_COUNT &&
                      s7tv_tabItemHidden((S7TVTabItem)i);
        if (!hidden) [desired addObject:s_stockControllers[i]];
    }
    return desired;
}

// Liste incomplète : intacte.
static NSArray<UIViewController *> *S7TVFilterStockControllers(
    NSArray<UIViewController *> *incoming) {
    if (incoming.count != S7TV_TAB_ITEM_COUNT) return incoming;

    // Nouvelle référence.
    s_stockControllers = [incoming copy];
    if (!S7TVTabVisibilityAnythingHidden()) return incoming;

    NSArray<UIViewController *> *desired = S7TVDesiredControllers();
    return desired.count ? desired : incoming;   // jamais zéro onglet
}

// Barre déjà réduite par le masquage ?
static BOOL S7TVIsManagedTabBar(UITabBarController *controller) {
    if (!S7TVTabVisibilityAnythingHidden()) return NO;
    NSUInteger count = controller.viewControllers.count;
    return count > 0 && count == (NSUInteger)s7tv_tabVisibleCount();
}

@interface S7TVTabVisibilityHooks : NSObject
- (void)s7tv_setViewControllers:(NSArray<UIViewController *> *)viewControllers;
- (void)s7tv_setViewControllers:(NSArray<UIViewController *> *)viewControllers
                       animated:(BOOL)animated;
- (void)s7tv_setSelectedIndex:(NSUInteger)selectedIndex;
- (void)s7tv_setSelectedViewController:(UIViewController *)viewController;
@end

@implementation S7TVTabVisibilityHooks

- (void)s7tv_setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    [self s7tv_setViewControllers:S7TVFilterStockControllers(viewControllers)];
}

- (void)s7tv_setViewControllers:(NSArray<UIViewController *> *)viewControllers
                       animated:(BOOL)animated {
    [self s7tv_setViewControllers:S7TVFilterStockControllers(viewControllers)
                         animated:animated];
}

// Index hors liste filtrée : vient de l'ordre d'origine, à traduire.
- (void)s7tv_setSelectedIndex:(NSUInteger)selectedIndex {
    UITabBarController *controller = (UITabBarController *)self;
    NSUInteger visible = controller.viewControllers.count;

    if (S7TVIsManagedTabBar(controller) && selectedIndex >= visible) {
        NSUInteger translated = s7tv_tabVisibilityIndexForStockIndex(selectedIndex);
        if (translated != NSNotFound && translated < visible) {
            [self s7tv_setSelectedIndex:translated];
            return;
        }
        // Masqué : ignorer.
        return;
    }
    [self s7tv_setSelectedIndex:selectedIndex];
}

// Contrôleur absent de la barre : ignorer.
- (void)s7tv_setSelectedViewController:(UIViewController *)viewController {
    UITabBarController *controller = (UITabBarController *)self;
    NSArray<UIViewController *> *list = controller.viewControllers;
    BOOL inList = list.count &&
        [list indexOfObjectIdenticalTo:viewController] != NSNotFound;

    if (viewController && !inList && S7TVTabVisibilityAnythingHidden()) return;
    [self s7tv_setSelectedViewController:viewController];
}

@end

// Fige l'implémentation héritée avant swizzle.
static void S7TVTabPinOriginalMethod(Class target, SEL selector) {
    Method method = class_getInstanceMethod(target, selector);
    if (!method) return;
    class_addMethod(target, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
}

static BOOL S7TVTabSelectionHooksInstalled = NO;
static BOOL S7TVTabFilterHooksInstalled = NO;

void s7tv_installTabVisibilityHooks(void) {
    @synchronized (NSObject.class) {
        if (!S7TVTabSelectionHooksInstalled) {
            S7TVTabSelectionHooksInstalled = YES;
            S7TVTabPinOriginalMethod(UITabBarController.class,
                                     @selector(setSelectedIndex:));
            S7TVTabPinOriginalMethod(UITabBarController.class,
                                     @selector(setSelectedViewController:));
            s7tv_swizzle(UITabBarController.class, S7TVTabVisibilityHooks.class,
                         @selector(setSelectedIndex:),
                         @selector(s7tv_setSelectedIndex:));
            s7tv_swizzle(UITabBarController.class, S7TVTabVisibilityHooks.class,
                         @selector(setSelectedViewController:),
                         @selector(s7tv_setSelectedViewController:));
        }

        Class target = NSClassFromString(@"_TtC6Twitch16TabBarController");
        if (!target) return;
        if (S7TVTabFilterHooksInstalled) return;
        S7TVTabFilterHooksInstalled = YES;

        S7TVTabPinOriginalMethod(target, @selector(setViewControllers:));
        S7TVTabPinOriginalMethod(target, @selector(setViewControllers:animated:));
        s7tv_swizzle(target, S7TVTabVisibilityHooks.class,
                     @selector(setViewControllers:),
                     @selector(s7tv_setViewControllers:));
        s7tv_swizzle(target, S7TVTabVisibilityHooks.class,
                     @selector(setViewControllers:animated:),
                     @selector(s7tv_setViewControllers:animated:));
    }
}

void s7tv_tabVisibilityApply(UITabBarController *controller) {
    if (![controller isKindOfClass:UITabBarController.class]) return;

    NSArray<UIViewController *> *current = controller.viewControllers;
    if (!current.count) return;

    // Barre complète = nouvelle référence.
    if (current.count == S7TV_TAB_ITEM_COUNT) s_stockControllers = [current copy];
    if (!s_stockControllers.count) return;

    NSArray<UIViewController *> *desired = S7TVDesiredControllers();
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
    controller.viewControllers = desired;
    NSUInteger index = selected ? [desired indexOfObjectIdenticalTo:selected] : NSNotFound;
    controller.selectedIndex = (index == NSNotFound) ? 0 : index;
}

// Barre principale, même sous un écran présenté.
static UITabBarController *S7TVFindTabBarController(UIViewController *root) {
    if (!root) return nil;

    if ([root isKindOfClass:UITabBarController.class]) {
        Class twitchClass = NSClassFromString(@"_TtC6Twitch16TabBarController");
        if (!twitchClass || [root isKindOfClass:twitchClass]) {
            return (UITabBarController *)root;
        }
    }

    UITabBarController *found = S7TVFindTabBarController(root.presentedViewController);
    if (found) return found;
    for (UIViewController *child in root.childViewControllers) {
        found = S7TVFindTabBarController(child);
        if (found) return found;
    }
    return nil;
}

void s7tv_tabVisibilityApplyNow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UITabBarController *controller =
                S7TVFindTabBarController(window.rootViewController);
            if (controller) {
                s7tv_tabVisibilityApply(controller);
                return;
            }
        }
    }
}
