/*
 * Launch Screen and Hide Twitch Stories are adapted from TwitchAdBlock by
 * level3tjg/gunnerkidBT (MIT). See THIRD_PARTY_NOTICES.md.
 */

#import "System/tpK-system-home-features.h"
#import "System/tpK-system-tab-visibility.h"
#import "System/tpK-system-autoclaim.h"
#import "Adblock/tpK-adblock-runtime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <limits.h>

static NSString *const TPKLaunchDestinationKey = @"tpk_launch_destination";
static NSString *const TPKHideTwitchStoriesKey = @"tpk_hide_twitch_stories";
static NSString *const TPKKeepLiveFeedPlayingKey = @"tpk_keep_live_feed_playing";

static NSUserDefaults *TPKHomeFeatureDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

void tpk_registerHomeFeatureDefaults(void) {
    [TPKHomeFeatureDefaults() registerDefaults:@{
        TPKLaunchDestinationKey: @(TPKLaunchDestinationDefault),
        TPKHideTwitchStoriesKey: @NO,
        // Actif par défaut (défaut TwitchAdBlock).
        TPKKeepLiveFeedPlayingKey: @YES,
    }];
}

TPKLaunchDestination tpk_launchDestination(void) {
    tpk_registerHomeFeatureDefaults();
    NSInteger value = [TPKHomeFeatureDefaults() integerForKey:TPKLaunchDestinationKey];
    if (value < TPKLaunchDestinationDefault || value > TPKLaunchDestinationProfile) {
        return TPKLaunchDestinationDefault;
    }
    return (TPKLaunchDestination)value;
}

void tpk_setLaunchDestination(TPKLaunchDestination destination) {
    if (destination < TPKLaunchDestinationDefault ||
        destination > TPKLaunchDestinationProfile) {
        destination = TPKLaunchDestinationDefault;
    }
    [TPKHomeFeatureDefaults() setInteger:destination forKey:TPKLaunchDestinationKey];
}

BOOL tpk_hideTwitchStoriesEnabled(void) {
    tpk_registerHomeFeatureDefaults();
    return [TPKHomeFeatureDefaults() boolForKey:TPKHideTwitchStoriesKey];
}

void tpk_setHideTwitchStoriesEnabled(BOOL enabled) {
    [TPKHomeFeatureDefaults() setBool:enabled forKey:TPKHideTwitchStoriesKey];
}

BOOL tpk_keepLiveFeedPlayingEnabled(void) {
    tpk_registerHomeFeatureDefaults();
    return [TPKHomeFeatureDefaults() boolForKey:TPKKeepLiveFeedPlayingKey];
}

void tpk_setKeepLiveFeedPlayingEnabled(BOOL enabled) {
    [TPKHomeFeatureDefaults() setBool:enabled forKey:TPKKeepLiveFeedPlayingKey];
}

static BOOL TPKHomeExchangeInstanceMethod(Class target, Class source,
                                            SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(target, original);
    Method replacementMethod = class_getInstanceMethod(source, replacement);
    if (!originalMethod || !replacementMethod) return NO;

    // Jamais échanger une méthode héritée.
    class_addMethod(target, original, method_getImplementation(originalMethod),
                    method_getTypeEncoding(originalMethod));
    class_addMethod(target, replacement, method_getImplementation(replacementMethod),
                    method_getTypeEncoding(replacementMethod));
    Method concreteOriginal = class_getInstanceMethod(target, original);
    Method concreteReplacement = class_getInstanceMethod(target, replacement);
    if (!concreteOriginal || !concreteReplacement) return NO;
    method_exchangeImplementations(concreteOriginal, concreteReplacement);
    return YES;
}

NSInteger tpk_launchDestinationTab(TPKLaunchDestination destination) {
    switch (destination) {
        case TPKLaunchDestinationHomeFollowing:
        case TPKLaunchDestinationHomeLive:
        case TPKLaunchDestinationHomeClips:
            return TPKTabItemHome;
        case TPKLaunchDestinationBrowseCategories:
        case TPKLaunchDestinationBrowseLiveChannels:
            return TPKTabItemExplore;
        case TPKLaunchDestinationActivity:
            return TPKTabItemActivity;
        case TPKLaunchDestinationProfile:
            return TPKTabItemProfile;
        case TPKLaunchDestinationDefault:
            break;
    }
    return -1;
}

// Sous-page visée, -1 si aucune.
static NSInteger TPKLaunchDestinationSubTab(TPKLaunchDestination destination) {
    switch (destination) {
        case TPKLaunchDestinationHomeFollowing:       return 0;
        case TPKLaunchDestinationHomeLive:            return 1;
        case TPKLaunchDestinationHomeClips:           return 2;
        case TPKLaunchDestinationBrowseCategories:    return 0;
        case TPKLaunchDestinationBrowseLiveChannels:  return 1;
        default:                                       return -1;
    }
}

static BOOL TPKLaunchDestinationParts(TPKLaunchDestination destination,
                                       NSInteger *tab, NSInteger *subTab) {
    NSInteger resolvedTab = tpk_launchDestinationTab(destination);
    if (tab) *tab = resolvedTab;
    if (subTab) *subTab = TPKLaunchDestinationSubTab(destination);
    return resolvedTab >= 0;
}

@interface NSObject (TPKHomeFeaturesRuntime)
- (void)tpk_home_tabBarViewDidAppear:(BOOL)animated;
- (void)tpk_home_tabBarViewDidLayoutSubviews;
- (void)tpk_home_discoveryViewDidLayoutSubviews;
- (void)tpk_home_browseViewDidAppear:(BOOL)animated;
- (void)tpk_home_storiesViewDidLayoutSubviews;
@end

static NSString *TPKFeedTabAccIDForSubTab(NSInteger subTab) {
    switch (subTab) {
        case 0: return @"feed-tabs-following";
        case 1: return @"feed-tabs-live";
        case 2: return @"feed-tabs-clips";
        default: return nil;
    }
}

// Segment cible par accessibilityIdentifier.
static UIView *TPKFindHomeFeedSegment(UIWindow *window, NSString *accID) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 8000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (accID.length &&
            [accID isEqualToString:view.accessibilityIdentifier] &&
            view.window && !view.hidden && view.alpha > 0.0) {
            return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

// Tap du segment, retenté (fil construit en différé).
static void TPKApplyHomeFeedSubTab(NSInteger subTab, NSUInteger attempt) {
    if (subTab < 0 || attempt >= 30) return;
    NSString *accID = TPKFeedTabAccIDForSubTab(subTab);
    if (!accID.length) return;
    BOOL tapped = NO;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha <= 0.0) continue;
        UIView *segment = TPKFindHomeFeedSegment(window, accID);
        if (segment) {
            tapped = TPKRNTapView(segment);
            break;
        }
    }
    if (tapped) return;
    if (attempt + 1 >= 30) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TPKApplyHomeFeedSubTab(subTab, attempt + 1);
    });
}

@implementation NSObject (TPKHomeFeaturesRuntime)- (void)tpk_home_tabBarViewDidAppear:(BOOL)animated {
    [self tpk_home_tabBarViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger stockTab = -1;
        if (!TPKLaunchDestinationParts(tpk_launchDestination(), &stockTab, NULL)) return;
        if (stockTab < 0) return;

        // Ordre d'origine → index réel.
        NSUInteger index = tpk_tabVisibilityIndexForStockIndex((NSUInteger)stockTab);
        if (index == NSNotFound) return;

        UITabBarController *controller = (UITabBarController *)self;
        if (index < controller.viewControllers.count) controller.selectedIndex = index;

        // Sous-onglets RN de l'accueil (Suivis/Live/Clips).
        NSInteger homeSubTab = -1;
        TPKLaunchDestinationParts(tpk_launchDestination(), NULL, &homeSubTab);
        if (stockTab == 0 && homeSubTab >= 0) {
            TPKApplyHomeFeedSubTab(homeSubTab, 0);
        }
    });
}

- (void)tpk_home_tabBarViewDidLayoutSubviews {
    [self tpk_home_tabBarViewDidLayoutSubviews];
    tpk_tabVisibilityApply((UITabBarController *)self);
}

- (void)tpk_home_discoveryViewDidLayoutSubviews {
    [self tpk_home_discoveryViewDidLayoutSubviews];
    // Le bouton vit parfois dans l'en-tête du fil.
    TPKAdblockHideAdFreeUpsellIfNeeded();
}

- (void)tpk_home_browseViewDidAppear:(BOOL)animated {
    [self tpk_home_browseViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger tab = -1;
        NSInteger subTab = -1;
        if (!TPKLaunchDestinationParts(tpk_launchDestination(), &tab, &subTab) ||
            tab != 1 || subTab < 0) return;
        SEL selector = NSSelectorFromString(@"selectViewControllerAtIndex:animated:");
        if ([self respondsToSelector:selector]) {
            ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(
                self, selector, subTab, NO);
        }
    });
}

static UIViewController *TPKFindChildControllerMatching(UIViewController *parent,
                                                         NSString *needle) {
    for (UIViewController *child in parent.childViewControllers) {
        if ([NSStringFromClass(child.class) containsString:needle]) return child;
        UIViewController *found = TPKFindChildControllerMatching(child, needle);
        if (found) return found;
    }
    return nil;
}

static UIView *TPKFindSubviewMatching(UIView *root, NSString *needle) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) containsString:needle]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = TPKFindSubviewMatching(subview, needle);
        if (found) return found;
    }
    return nil;
}

static void TPKRemoveAndCollapseSlot(UIView *view) {
    UIView *parent = view.superview;
    [view removeFromSuperview];
    if (!parent) return;
    parent.hidden = YES;
    NSLayoutConstraint *zeroHeight = [parent.heightAnchor constraintEqualToConstant:0.0];
    zeroHeight.priority = UILayoutPriorityRequired;
    zeroHeight.active = YES;
}

static BOOL TPKTryHideStories(UIViewController *controller) {
    static NSString *const needle = @"StoryViewerListCollapsibleView";
    UIView *targetView = TPKFindSubviewMatching(controller.view, needle);
    if (targetView) {
        TPKRemoveAndCollapseSlot(targetView);
        return YES;
    }

    UIViewController *targetController =
        TPKFindChildControllerMatching(controller, needle);
    if (!targetController) return NO;

    UIView *parent = targetController.view.superview;
    [targetController willMoveToParentViewController:nil];
    [targetController.view removeFromSuperview];
    [targetController removeFromParentViewController];
    if (parent) {
        parent.hidden = YES;
        NSLayoutConstraint *zeroHeight = [parent.heightAnchor constraintEqualToConstant:0.0];
        zeroHeight.priority = UILayoutPriorityRequired;
        zeroHeight.active = YES;
    }
    return YES;
}

static char TPKStoriesHiddenKey;
static char TPKStoriesRetriesScheduledKey;

- (void)tpk_home_storiesViewDidLayoutSubviews {
    [self tpk_home_storiesViewDidLayoutSubviews];
    if (!tpk_hideTwitchStoriesEnabled() ||
        [objc_getAssociatedObject(self, &TPKStoriesHiddenKey) boolValue]) return;

    UIViewController *controller = (UIViewController *)self;
    if (TPKTryHideStories(controller)) {
        objc_setAssociatedObject(self, &TPKStoriesHiddenKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if ([objc_getAssociatedObject(self, &TPKStoriesRetriesScheduledKey) boolValue]) return;
    objc_setAssociatedObject(self, &TPKStoriesRetriesScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakController = controller;
    for (NSNumber *milliseconds in @[@500, @1500, @3000, @5000]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            milliseconds.longLongValue * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (!strongController || !tpk_hideTwitchStoriesEnabled() ||
                [objc_getAssociatedObject(strongController, &TPKStoriesHiddenKey) boolValue]) return;
            if (TPKTryHideStories(strongController)) {
                objc_setAssociatedObject(strongController, &TPKStoriesHiddenKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    }
}

@end

static BOOL TPKLaunchTabHookInstalled = NO;
static BOOL TPKTabLayoutHookInstalled = NO;
static BOOL TPKDiscoveryHookInstalled = NO;
static BOOL TPKBrowseHookInstalled = NO;
static BOOL TPKStoriesHookInstalled = NO;

static void TPKTryInstallHomeFeatureHooks(void) {
    @synchronized (NSObject.class) {
        if (!TPKLaunchTabHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch16TabBarController");
            if (target) {
                TPKLaunchTabHookInstalled = TPKHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidAppear:),
                    @selector(tpk_home_tabBarViewDidAppear:));
            }
        }
        if (!TPKTabLayoutHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch16TabBarController");
            if (target) {
                TPKTabLayoutHookInstalled = TPKHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidLayoutSubviews),
                    @selector(tpk_home_tabBarViewDidLayoutSubviews));
            }
        }
        tpk_installTabVisibilityHooks();
        if (!TPKDiscoveryHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch30DiscoveryFeedTabViewController");
            if (target) {
                TPKDiscoveryHookInstalled = TPKHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidLayoutSubviews),
                    @selector(tpk_home_discoveryViewDidLayoutSubviews));
            }
        }
        if (!TPKBrowseHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch20BrowseViewController");
            if (target) {
                TPKBrowseHookInstalled = TPKHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidAppear:),
                    @selector(tpk_home_browseViewDidAppear:));
            }
        }
        if (!TPKStoriesHookInstalled) {
            Class target = NSClassFromString(
                @"_TtC6Twitch41DiscoveryFeedShelfContainerViewController");
            if (target) {
                TPKStoriesHookInstalled = TPKHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidLayoutSubviews),
                    @selector(tpk_home_storiesViewDidLayoutSubviews));
            }
        }
    }
}

void tpk_installHomeFeatureRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tpk_registerHomeFeatureDefaults();
        TPKTryInstallHomeFeatureHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ TPKTryInstallHomeFeatureHooks(); });
        }
    });
}
