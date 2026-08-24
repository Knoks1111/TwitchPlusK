/*
 * Launch Screen and Hide Twitch Stories are adapted from TwitchAdBlock by
 * level3tjg/gunnerkidBT (MIT). See THIRD_PARTY_NOTICES.md.
 */

#import "System/7tv-system-home-features.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <math.h>
#import <limits.h>

static NSString *const S7TVLaunchDestinationKey = @"s7tv_launch_destination";
static NSString *const S7TVHideTwitchStoriesKey = @"s7tv_hide_twitch_stories";
static NSString *const S7TVKeepLiveFeedPlayingKey = @"s7tv_keep_live_feed_playing";

static NSUserDefaults *S7TVHomeFeatureDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

void s7tv_registerHomeFeatureDefaults(void) {
    [S7TVHomeFeatureDefaults() registerDefaults:@{
        S7TVLaunchDestinationKey: @(S7TVLaunchDestinationDefault),
        S7TVHideTwitchStoriesKey: @NO,
        // Même valeur par défaut que TwitchAdBlock : la limite du fil Live
        // est neutralisée sans configuration supplémentaire.
        S7TVKeepLiveFeedPlayingKey: @YES,
    }];
}

S7TVLaunchDestination s7tv_launchDestination(void) {
    s7tv_registerHomeFeatureDefaults();
    NSInteger value = [S7TVHomeFeatureDefaults() integerForKey:S7TVLaunchDestinationKey];
    if (value < S7TVLaunchDestinationDefault || value > S7TVLaunchDestinationProfile) {
        return S7TVLaunchDestinationDefault;
    }
    return (S7TVLaunchDestination)value;
}

void s7tv_setLaunchDestination(S7TVLaunchDestination destination) {
    if (destination < S7TVLaunchDestinationDefault ||
        destination > S7TVLaunchDestinationProfile) {
        destination = S7TVLaunchDestinationDefault;
    }
    [S7TVHomeFeatureDefaults() setInteger:destination forKey:S7TVLaunchDestinationKey];
}

BOOL s7tv_hideTwitchStoriesEnabled(void) {
    s7tv_registerHomeFeatureDefaults();
    return [S7TVHomeFeatureDefaults() boolForKey:S7TVHideTwitchStoriesKey];
}

void s7tv_setHideTwitchStoriesEnabled(BOOL enabled) {
    [S7TVHomeFeatureDefaults() setBool:enabled forKey:S7TVHideTwitchStoriesKey];
}

BOOL s7tv_keepLiveFeedPlayingEnabled(void) {
    s7tv_registerHomeFeatureDefaults();
    return [S7TVHomeFeatureDefaults() boolForKey:S7TVKeepLiveFeedPlayingKey];
}

void s7tv_setKeepLiveFeedPlayingEnabled(BOOL enabled) {
    [S7TVHomeFeatureDefaults() setBool:enabled forKey:S7TVKeepLiveFeedPlayingKey];
}

static BOOL S7TVHomeExchangeInstanceMethod(Class target, Class source,
                                            SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(target, original);
    Method replacementMethod = class_getInstanceMethod(source, replacement);
    if (!originalMethod || !replacementMethod) return NO;

    // Crée d'abord des implémentations propres à la classe cible afin de ne
    // jamais échanger une méthode héritée sur UIViewController/NSObject.
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

static BOOL S7TVLaunchDestinationParts(S7TVLaunchDestination destination,
                                       NSInteger *tab, NSInteger *subTab) {
    NSInteger resolvedTab = -1;
    NSInteger resolvedSubTab = -1;
    switch (destination) {
        case S7TVLaunchDestinationHomeFollowing:       resolvedTab = 0; resolvedSubTab = 0; break;
        case S7TVLaunchDestinationHomeLive:            resolvedTab = 0; resolvedSubTab = 1; break;
        case S7TVLaunchDestinationHomeClips:           resolvedTab = 0; resolvedSubTab = 2; break;
        case S7TVLaunchDestinationBrowseCategories:    resolvedTab = 1; resolvedSubTab = 0; break;
        case S7TVLaunchDestinationBrowseLiveChannels:  resolvedTab = 1; resolvedSubTab = 1; break;
        case S7TVLaunchDestinationActivity:             resolvedTab = 3; break;
        case S7TVLaunchDestinationProfile:              resolvedTab = 4; break;
        case S7TVLaunchDestinationDefault:              break;
    }
    if (tab) *tab = resolvedTab;
    if (subTab) *subTab = resolvedSubTab;
    return resolvedTab >= 0;
}

static UIScrollView *S7TVFindPagedScrollView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:UIScrollView.class]) {
        UIScrollView *scrollView = (UIScrollView *)root;
        if (scrollView.contentSize.width > scrollView.bounds.size.width + 1.0) {
            return scrollView;
        }
    }
    for (UIView *subview in root.subviews) {
        UIScrollView *found = S7TVFindPagedScrollView(subview);
        if (found) return found;
    }
    return nil;
}

static Ivar S7TVFindIvar(id object, const char *name) {
    Class current = object_getClass(object);
    while (current && current != NSObject.class) {
        Ivar ivar = class_getInstanceVariable(current, name);
        if (ivar) return ivar;
        current = class_getSuperclass(current);
    }
    return NULL;
}

static UIViewController *S7TVFindChildControllerMatching(UIViewController *parent,
                                                         NSString *needle) {
    for (UIViewController *child in parent.childViewControllers) {
        if ([NSStringFromClass(child.class) containsString:needle]) return child;
        UIViewController *found = S7TVFindChildControllerMatching(child, needle);
        if (found) return found;
    }
    return nil;
}

static UIView *S7TVFindSubviewMatching(UIView *root, NSString *needle) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) containsString:needle]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = S7TVFindSubviewMatching(subview, needle);
        if (found) return found;
    }
    return nil;
}

static void S7TVRemoveAndCollapseSlot(UIView *view) {
    UIView *parent = view.superview;
    [view removeFromSuperview];
    if (!parent) return;
    parent.hidden = YES;
    NSLayoutConstraint *zeroHeight = [parent.heightAnchor constraintEqualToConstant:0.0];
    zeroHeight.priority = UILayoutPriorityRequired;
    zeroHeight.active = YES;
}

static BOOL S7TVTryHideStories(UIViewController *controller) {
    static NSString *const needle = @"StoryViewerListCollapsibleView";
    UIView *targetView = S7TVFindSubviewMatching(controller.view, needle);
    if (targetView) {
        S7TVRemoveAndCollapseSlot(targetView);
        os_log(OS_LOG_DEFAULT, "[S7TV-Home] Twitch Stories view hidden");
        return YES;
    }

    UIViewController *targetController =
        S7TVFindChildControllerMatching(controller, needle);
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
    os_log(OS_LOG_DEFAULT, "[S7TV-Home] Twitch Stories controller hidden");
    return YES;
}

static char S7TVStoriesHiddenKey;
static char S7TVStoriesRetriesScheduledKey;

@interface NSObject (S7TVHomeFeaturesRuntime)
- (void)s7tv_home_tabBarViewDidAppear:(BOOL)animated;
- (void)s7tv_home_discoveryViewDidLayoutSubviews;
- (void)s7tv_home_browseViewDidAppear:(BOOL)animated;
- (void)s7tv_home_storiesViewDidLayoutSubviews;
@end

@implementation NSObject (S7TVHomeFeaturesRuntime)

- (void)s7tv_home_tabBarViewDidAppear:(BOOL)animated {
    [self s7tv_home_tabBarViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger tab = -1;
        if (!S7TVLaunchDestinationParts(s7tv_launchDestination(), &tab, NULL)) return;
        UITabBarController *controller = (UITabBarController *)self;
        if (tab >= 0 && tab < (NSInteger)controller.viewControllers.count) {
            controller.selectedIndex = (NSUInteger)tab;
            os_log(OS_LOG_DEFAULT, "[S7TV-Home] launch tab selected=%ld", (long)tab);
        }
    });
}

- (void)s7tv_home_discoveryViewDidLayoutSubviews {
    [self s7tv_home_discoveryViewDidLayoutSubviews];

    NSInteger tab = -1;
    NSInteger subTab = -1;
    if (!S7TVLaunchDestinationParts(s7tv_launchDestination(), &tab, &subTab) ||
        tab != 0 || subTab < 0) return;

    static NSInteger attempts = 0;
    if (attempts >= 5) return;
    UIView *view = ((UIViewController *)self).view;
    UIScrollView *scrollView = S7TVFindPagedScrollView(view);
    CGFloat pageWidth = scrollView.bounds.size.width;
    if (!scrollView || pageWidth <= 0.0) return;

    CGFloat desiredX = pageWidth * (CGFloat)subTab;
    if (fabs(scrollView.contentOffset.x - desiredX) < 1.0) {
        attempts = INT_MAX;
        return;
    }

    attempts++;
    [scrollView setContentOffset:CGPointMake(desiredX, 0.0) animated:NO];
    Ivar selectedIndex = S7TVFindIvar(self, "selectedContentViewControllerIndex");
    if (selectedIndex) {
        NSInteger *pointer = (NSInteger *)((char *)(__bridge void *)self +
                                           ivar_getOffset(selectedIndex));
        *pointer = subTab;
    }
}

- (void)s7tv_home_browseViewDidAppear:(BOOL)animated {
    [self s7tv_home_browseViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger tab = -1;
        NSInteger subTab = -1;
        if (!S7TVLaunchDestinationParts(s7tv_launchDestination(), &tab, &subTab) ||
            tab != 1 || subTab < 0) return;
        SEL selector = NSSelectorFromString(@"selectViewControllerAtIndex:animated:");
        if ([self respondsToSelector:selector]) {
            ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(
                self, selector, subTab, NO);
        }
    });
}

- (void)s7tv_home_storiesViewDidLayoutSubviews {
    [self s7tv_home_storiesViewDidLayoutSubviews];
    if (!s7tv_hideTwitchStoriesEnabled() ||
        [objc_getAssociatedObject(self, &S7TVStoriesHiddenKey) boolValue]) return;

    UIViewController *controller = (UIViewController *)self;
    if (S7TVTryHideStories(controller)) {
        objc_setAssociatedObject(self, &S7TVStoriesHiddenKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if ([objc_getAssociatedObject(self, &S7TVStoriesRetriesScheduledKey) boolValue]) return;
    objc_setAssociatedObject(self, &S7TVStoriesRetriesScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakController = controller;
    for (NSNumber *milliseconds in @[@500, @1500, @3000, @5000]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            milliseconds.longLongValue * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (!strongController || !s7tv_hideTwitchStoriesEnabled() ||
                [objc_getAssociatedObject(strongController, &S7TVStoriesHiddenKey) boolValue]) return;
            if (S7TVTryHideStories(strongController)) {
                objc_setAssociatedObject(strongController, &S7TVStoriesHiddenKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    }
}

@end

static BOOL S7TVLaunchTabHookInstalled = NO;
static BOOL S7TVDiscoveryHookInstalled = NO;
static BOOL S7TVBrowseHookInstalled = NO;
static BOOL S7TVStoriesHookInstalled = NO;

static void S7TVTryInstallHomeFeatureHooks(void) {
    @synchronized (NSObject.class) {
        if (!S7TVLaunchTabHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch16TabBarController");
            if (target) {
                S7TVLaunchTabHookInstalled = S7TVHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidAppear:),
                    @selector(s7tv_home_tabBarViewDidAppear:));
            }
        }
        if (!S7TVDiscoveryHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch30DiscoveryFeedTabViewController");
            if (target) {
                S7TVDiscoveryHookInstalled = S7TVHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidLayoutSubviews),
                    @selector(s7tv_home_discoveryViewDidLayoutSubviews));
            }
        }
        if (!S7TVBrowseHookInstalled) {
            Class target = NSClassFromString(@"_TtC6Twitch20BrowseViewController");
            if (target) {
                S7TVBrowseHookInstalled = S7TVHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidAppear:),
                    @selector(s7tv_home_browseViewDidAppear:));
            }
        }
        if (!S7TVStoriesHookInstalled) {
            Class target = NSClassFromString(
                @"_TtC6Twitch41DiscoveryFeedShelfContainerViewController");
            if (target) {
                S7TVStoriesHookInstalled = S7TVHomeExchangeInstanceMethod(
                    target, NSObject.class, @selector(viewDidLayoutSubviews),
                    @selector(s7tv_home_storiesViewDidLayoutSubviews));
            }
        }
    }
}

void s7tv_installHomeFeatureRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s7tv_registerHomeFeatureDefaults();
        S7TVTryInstallHomeFeatureHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ S7TVTryInstallHomeFeatureHooks(); });
        }
    });
}
