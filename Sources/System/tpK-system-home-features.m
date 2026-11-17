#import "System/tpK-system-home-features.h"
#import "System/tpK-system-tab-visibility.h"
#import "Adblock/tpK-adblock-runtime.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Proxy/tpK-adblock-data.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <limits.h>
#import <os/log.h>
#include <stdlib.h>
#include <string.h>

static NSString *const TPKLaunchDestinationKey = @"tpk_launch_destination";
static NSString *const TPKKeepLiveFeedPlayingKey = @"tpk_keep_live_feed_playing";
static NSString *const TPKHideFollowedRecapsKey = @"tpk_hide_followed_recaps";
static TPKLaunchDestination TPKNativeLaunchDestination;
static void TPKRefreshFollowedRecaps(void);

static NSUserDefaults *TPKHomeFeatureDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

void tpk_registerHomeFeatureDefaults(void) {
    [TPKHomeFeatureDefaults() registerDefaults:@{
        TPKLaunchDestinationKey: @(TPKLaunchDestinationHomeLive),
        TPKKeepLiveFeedPlayingKey: @YES,
        TPKHideFollowedRecapsKey: @NO,
    }];
}

TPKLaunchDestination tpk_launchDestination(void) {
    tpk_registerHomeFeatureDefaults();
    NSInteger value = [TPKHomeFeatureDefaults() integerForKey:TPKLaunchDestinationKey];
    if (value <= TPKLaunchDestinationDefault || value > TPKLaunchDestinationProfile) {
        return TPKLaunchDestinationHomeLive;
    }
    return (TPKLaunchDestination)value;
}

void tpk_setLaunchDestination(TPKLaunchDestination destination) {
    if (destination <= TPKLaunchDestinationDefault ||
        destination > TPKLaunchDestinationProfile) {
        destination = TPKLaunchDestinationHomeLive;
    }
    [TPKHomeFeatureDefaults() setInteger:destination forKey:TPKLaunchDestinationKey];
}

BOOL tpk_keepLiveFeedPlayingEnabled(void) {
    tpk_registerHomeFeatureDefaults();
    return [TPKHomeFeatureDefaults() boolForKey:TPKKeepLiveFeedPlayingKey];
}

void tpk_setKeepLiveFeedPlayingEnabled(BOOL enabled) {
    [TPKHomeFeatureDefaults() setBool:enabled forKey:TPKKeepLiveFeedPlayingKey];
}

BOOL tpk_hideFollowedRecapsEnabled(void) {
    return [TPKHomeFeatureDefaults() boolForKey:TPKHideFollowedRecapsKey];
}

void tpk_setHideFollowedRecapsEnabled(BOOL enabled) {
    [TPKHomeFeatureDefaults() setBool:enabled forKey:TPKHideFollowedRecapsKey];
    if (NSThread.isMainThread) TPKRefreshFollowedRecaps();
    else dispatch_async(dispatch_get_main_queue(), ^{ TPKRefreshFollowedRecaps(); });
}

static BOOL TPKHomeExchangeInstanceMethod(Class target, Class source,
                                            SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(target, original);
    Method replacementMethod = class_getInstanceMethod(source, replacement);
    if (!originalMethod || !replacementMethod) return NO;

    // Copier la méthode héritée sur la classe cible avant de l’échanger.
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


@interface TPKFollowedRecapState : NSObject
@property (nonatomic, weak) UIView *shelf;
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic) UIEdgeInsets baseInsets;
@property (nonatomic) CGFloat writtenTop;
@property (nonatomic) BOOL originalHidden;
@property (nonatomic) BOOL updating;
@end

@implementation TPKFollowedRecapState
@end

static char TPKRecapStateKey;
static NSHashTable<TPKFollowedRecapState *> *TPKRecapStates;
static NSString *const TPKRecapShelfID = @"feed-recaps-shelf-absorb";

static void TPKRestoreRecapState(TPKFollowedRecapState *state) {
    if (!state || state.updating) return;
    state.updating = YES;
    UIView *shelf = state.shelf;
    UIScrollView *scroll = state.scroll;
    if (objc_getAssociatedObject(shelf, &TPKRecapStateKey) == state)
        objc_setAssociatedObject(shelf, &TPKRecapStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(scroll, &TPKRecapStateKey) == state) {
        objc_setAssociatedObject(scroll, &TPKRecapStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIEdgeInsets restored = scroll.contentInset;
        if (fabs(restored.top - state.writtenTop) < 0.5) restored.top = state.baseInsets.top;
        CGPoint position = scroll.contentOffset;
        BOOL nearTop = position.y <= -scroll.adjustedContentInset.top + 1.0;
        scroll.contentInset = restored;
        if (nearTop) scroll.contentOffset = CGPointMake(position.x, -scroll.adjustedContentInset.top);
    }
    shelf.hidden = state.originalHidden;
    state.updating = NO;
}

static void TPKApplyRecapShelf(UIView *shelf) {
    TPKFollowedRecapState *state = objc_getAssociatedObject(shelf, &TPKRecapStateKey);
    if (state.updating) return;
    if (!tpk_hideFollowedRecapsEnabled() || !shelf.window ||
        ![shelf.accessibilityIdentifier isEqualToString:TPKRecapShelfID]) {
        TPKRestoreRecapState(state);
        return;
    }
    UIScrollView *scroll = nil;
    UIView *feedRoot = nil;
    for (UIView *parent = shelf.superview; parent; parent = parent.superview) {
        if (!scroll && [parent isKindOfClass:UIScrollView.class]) scroll = (UIScrollView *)parent;
        if ([parent.accessibilityIdentifier isEqualToString:@"feed-list"]) { feedRoot = parent; break; }
    }
    if (feedRoot && !scroll) {
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithArray:feedRoot.subviews];
        Class scrollClass = NSClassFromString(@"RCTEnhancedScrollView");
        for (NSUInteger i = 0; i < views.count && i < 128; i++) {
            UIView *candidate = views[i];
            if (scrollClass && [candidate isKindOfClass:scrollClass]) { scroll = (UIScrollView *)candidate; break; }
            [views addObjectsFromArray:candidate.subviews];
        }
    }
    CGFloat height = CGRectGetHeight(shelf.bounds);
    if (!feedRoot || !scroll || !isfinite(height) || height <= 0) {
        TPKRestoreRecapState(state);
        return;
    }
    if (state && state.scroll != scroll) { TPKRestoreRecapState(state); state = nil; }
    if (!state) {
        TPKFollowedRecapState *previous = objc_getAssociatedObject(scroll, &TPKRecapStateKey);
        TPKRestoreRecapState(previous);
        state = [TPKFollowedRecapState new];
        state.shelf = shelf;
        state.scroll = scroll;
        state.baseInsets = scroll.contentInset;
        state.writtenTop = state.baseInsets.top;
        state.originalHidden = shelf.hidden;
        if (!TPKRecapStates) TPKRecapStates = [NSHashTable weakObjectsHashTable];
        [TPKRecapStates addObject:state];
        objc_setAssociatedObject(shelf, &TPKRecapStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(scroll, &TPKRecapStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.updating = YES;
    UIEdgeInsets current = scroll.contentInset;
    if (fabs(current.top - state.writtenTop) >= 0.5) state.baseInsets = current;
    current.top = state.baseInsets.top - height;
    state.writtenTop = current.top;
    shelf.hidden = YES;
    if (!UIEdgeInsetsEqualToEdgeInsets(current, scroll.contentInset)) scroll.contentInset = current;
    CGFloat minimum = -scroll.adjustedContentInset.top;
    if (!scroll.tracking && !scroll.dragging && !scroll.decelerating && scroll.contentOffset.y < minimum)
        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, minimum);
    state.updating = NO;
}

static CGPoint TPKRecapAllowedOffset(UIScrollView *scroll, CGPoint proposed) {
    TPKFollowedRecapState *state = objc_getAssociatedObject(scroll, &TPKRecapStateKey);
    if (state && !state.updating && tpk_hideFollowedRecapsEnabled() &&
        !scroll.tracking && !scroll.dragging && !scroll.decelerating &&
        proposed.y < -scroll.adjustedContentInset.top) proposed.y = -scroll.adjustedContentInset.top;
    return proposed;
}

static void TPKRefreshFollowedRecaps(void) {
    for (TPKFollowedRecapState *state in TPKRecapStates.allObjects) {
        if (state.shelf) TPKApplyRecapShelf(state.shelf);
        else TPKRestoreRecapState(state);
    }
    if (!tpk_hideFollowedRecapsEnabled()) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden) continue;
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
        for (NSUInteger i = 0; i < views.count && i < 4096; i++) {
            UIView *view = views[i];
            if ([view.accessibilityIdentifier isEqualToString:TPKRecapShelfID]) TPKApplyRecapShelf(view);
            [views addObjectsFromArray:view.subviews];
        }
    }
}

@interface NSObject (TPKHomeFeaturesRuntime)
- (UIView *)tpk_home_viewWithModuleName:(NSString *)moduleName initialProperties:(NSDictionary *)properties;
- (void)tpk_home_tabBarViewDidAppear:(BOOL)animated;
- (void)tpk_home_browseViewDidAppear:(BOOL)animated;
- (void)tpk_home_recapComponentLayout;
- (void)tpk_home_recapComponentMoved;
- (void)tpk_home_recapComponentHidden:(BOOL)hidden;
- (void)tpk_home_recapScrollLayout;
- (void)tpk_home_recapOffset:(CGPoint)offset;
- (void)tpk_home_recapOffset:(CGPoint)offset animated:(BOOL)animated;
- (void)tpk_home_tabBarViewDidLayoutSubviews;
- (void)tpk_home_discoveryViewDidLayoutSubviews;
@end


@implementation NSObject (TPKHomeFeaturesRuntime)

- (UIView *)tpk_home_viewWithModuleName:(NSString *)moduleName initialProperties:(NSDictionary *)properties {
    if (![moduleName isEqualToString:@"TwitchRNDiscoveryFeed"] ||
        ![properties isKindOfClass:NSDictionary.class]) {
        return [self tpk_home_viewWithModuleName:moduleName initialProperties:properties];
    }

    __block NSDictionary *initialProperties = properties;
    static dispatch_once_t firstHome;
    dispatch_once(&firstHome, ^{
        if (![properties[@"isAppLaunchDestination"] isEqual:@YES] ||
            [properties[@"isFromDeeplink"] isEqual:@YES] ||
            tpk_tabVisibilityIndexForStockIndex(TPKTabItemHome) == NSNotFound) return;
        for (NSString *key in @[@"subfeedSlug", @"clipSlug", @"seedClipSlug"]) {
            id value = properties[key];
            if ([value isKindOfClass:NSString.class] && [value length]) return;
        }

        NSString *tab;
        switch (tpk_launchDestination()) {
            case TPKLaunchDestinationHomeFollowing: tab = @"following"; break;
            case TPKLaunchDestinationHomeLive:      tab = @"live"; break;
            case TPKLaunchDestinationHomeClips:     tab = @"clips"; break;
            default: return;
        }
        // Twitch initialise lui-même la page et ses données avant le premier affichage.
        NSMutableDictionary *updated = [properties mutableCopy];
        updated[@"subfeedTab"] = tab;
        initialProperties = updated;
    });
    return [self tpk_home_viewWithModuleName:moduleName initialProperties:initialProperties];
}

- (void)tpk_home_recapComponentLayout {
    [self tpk_home_recapComponentLayout];
    UIView *view = (UIView *)self;
    if (objc_getAssociatedObject(view, &TPKRecapStateKey) ||
        [view.accessibilityIdentifier isEqualToString:TPKRecapShelfID]) TPKApplyRecapShelf(view);
}

- (void)tpk_home_recapComponentMoved {
    [self tpk_home_recapComponentMoved];
    UIView *view = (UIView *)self;
    if (objc_getAssociatedObject(view, &TPKRecapStateKey) ||
        [view.accessibilityIdentifier isEqualToString:TPKRecapShelfID]) TPKApplyRecapShelf(view);
}

- (void)tpk_home_recapComponentHidden:(BOOL)hidden {
    UIView *view = (UIView *)self;
    TPKFollowedRecapState *state = objc_getAssociatedObject(view, &TPKRecapStateKey);
    if (state && !state.updating && tpk_hideFollowedRecapsEnabled() &&
        [view.accessibilityIdentifier isEqualToString:TPKRecapShelfID]) {
        state.originalHidden = hidden;
        hidden = YES;
    }
    [self tpk_home_recapComponentHidden:hidden];
}

- (void)tpk_home_recapScrollLayout {
    [self tpk_home_recapScrollLayout];
    TPKFollowedRecapState *state = objc_getAssociatedObject(self, &TPKRecapStateKey);
    if (state.shelf) TPKApplyRecapShelf(state.shelf);
    else if (state) TPKRestoreRecapState(state);
}

- (void)tpk_home_recapOffset:(CGPoint)offset {
    [self tpk_home_recapOffset:TPKRecapAllowedOffset((UIScrollView *)self, offset)];
}

- (void)tpk_home_recapOffset:(CGPoint)offset animated:(BOOL)animated {
    [self tpk_home_recapOffset:TPKRecapAllowedOffset((UIScrollView *)self, offset) animated:animated];
}

- (void)tpk_home_tabBarViewDidAppear:(BOOL)animated {
    [self tpk_home_tabBarViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger tab = tpk_launchDestinationTab(TPKNativeLaunchDestination);
        if (tab < 0 || tab == TPKTabItemHome) return;
        NSUInteger index = tpk_tabVisibilityIndexForStockIndex((NSUInteger)tab);
        UITabBarController *controller = (UITabBarController *)self;
        if (index != NSNotFound && index < controller.viewControllers.count)
            controller.selectedIndex = index;
    });
}

- (void)tpk_home_browseViewDidAppear:(BOOL)animated {
    [self tpk_home_browseViewDidAppear:animated];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (TPKNativeLaunchDestination != TPKLaunchDestinationBrowseCategories &&
            TPKNativeLaunchDestination != TPKLaunchDestinationBrowseLiveChannels) return;
        SEL select = NSSelectorFromString(@"selectViewControllerAtIndex:animated:");
        if ([self respondsToSelector:select])
            ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(self, select,
                TPKNativeLaunchDestination == TPKLaunchDestinationBrowseLiveChannels ? 1 : 0, NO);
    });
}

- (void)tpk_home_tabBarViewDidLayoutSubviews {
    [self tpk_home_tabBarViewDidLayoutSubviews];
    tpk_tabVisibilityApply((UITabBarController *)self);
}

- (void)tpk_home_discoveryViewDidLayoutSubviews {
    [self tpk_home_discoveryViewDidLayoutSubviews];

    TPKAdblockHideAdFreeUpsellIfNeeded(((UIViewController *)self).viewIfLoaded);
}

@end

static BOOL TPKTabLayoutHookInstalled = NO;
static BOOL TPKDiscoveryHookInstalled = NO;
static BOOL TPKHomeRootHookInstalled = NO;
static BOOL TPKLaunchTabHookInstalled = NO, TPKBrowseLaunchHookInstalled = NO;
static BOOL TPKRecapComponentLayoutInstalled, TPKRecapComponentMovedInstalled, TPKRecapComponentHiddenInstalled;
static BOOL TPKRecapScrollLayoutInstalled, TPKRecapOffsetInstalled, TPKRecapAnimatedOffsetInstalled;

static void TPKTryInstallHomeFeatureHooks(void) {
    @synchronized (NSObject.class) {
        if (!TPKHomeRootHookInstalled)
            TPKHomeRootHookInstalled = TPKHomeExchangeInstanceMethod(
                NSClassFromString(@"RCTRootViewFactory"), NSObject.class,
                @selector(viewWithModuleName:initialProperties:),
                @selector(tpk_home_viewWithModuleName:initialProperties:));
        if (!TPKLaunchTabHookInstalled)
            TPKLaunchTabHookInstalled = TPKHomeExchangeInstanceMethod(
                NSClassFromString(@"_TtC6Twitch16TabBarController"), NSObject.class,
                @selector(viewDidAppear:), @selector(tpk_home_tabBarViewDidAppear:));
        if (!TPKBrowseLaunchHookInstalled)
            TPKBrowseLaunchHookInstalled = TPKHomeExchangeInstanceMethod(
                NSClassFromString(@"_TtC6Twitch20BrowseViewController"), NSObject.class,
                @selector(viewDidAppear:), @selector(tpk_home_browseViewDidAppear:));
        Class component = NSClassFromString(@"RCTViewComponentView");
        Class scroll = NSClassFromString(@"RCTEnhancedScrollView");
        if (!TPKRecapComponentLayoutInstalled)
            TPKRecapComponentLayoutInstalled = TPKHomeExchangeInstanceMethod(component, NSObject.class,
                @selector(layoutSubviews), @selector(tpk_home_recapComponentLayout));
        if (!TPKRecapComponentMovedInstalled)
            TPKRecapComponentMovedInstalled = TPKHomeExchangeInstanceMethod(component, NSObject.class,
                @selector(didMoveToWindow), @selector(tpk_home_recapComponentMoved));
        if (!TPKRecapComponentHiddenInstalled)
            TPKRecapComponentHiddenInstalled = TPKHomeExchangeInstanceMethod(component, NSObject.class,
                @selector(setHidden:), @selector(tpk_home_recapComponentHidden:));
        if (!TPKRecapScrollLayoutInstalled)
            TPKRecapScrollLayoutInstalled = TPKHomeExchangeInstanceMethod(scroll, NSObject.class,
                @selector(layoutSubviews), @selector(tpk_home_recapScrollLayout));
        if (!TPKRecapOffsetInstalled)
            TPKRecapOffsetInstalled = TPKHomeExchangeInstanceMethod(scroll, NSObject.class,
                @selector(setContentOffset:), @selector(tpk_home_recapOffset:));
        if (!TPKRecapAnimatedOffsetInstalled)
            TPKRecapAnimatedOffsetInstalled = TPKHomeExchangeInstanceMethod(scroll, NSObject.class,
                @selector(setContentOffset:animated:), @selector(tpk_home_recapOffset:animated:));
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
    }
}

typedef void (^TPKFeedRNResolve)(id result);
typedef void (^TPKFeedRNReject)(NSString *code, NSString *message, NSError *error);

static NSUInteger TPKPreloadLimitsNulled;

static id TPKNullLiveFeedWatchLimits(id obj, NSUInteger depth) {
  if (!obj || depth > 40) return obj;
  if ([obj isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *d = [(NSDictionary *)obj mutableCopy];
    for (id key in [d allKeys]) {
      if ([key isEqual:@"maxStreamWatchSeconds"] || [key isEqual:@"maxWatchSeconds"]) {
        if (d[key] != (id)kCFNull) {
          os_log(OS_LOG_DEFAULT, "[TPK-Home] feed preload: %{public}@ %{public}@ -> null", key, d[key]);
          d[key] = (id)kCFNull;
          TPKPreloadLimitsNulled++;
        }
      } else {
        d[key] = TPKNullLiveFeedWatchLimits(d[key], depth + 1);
      }
    }
    return d;
  }
  if ([obj isKindOfClass:NSArray.class]) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
    for (id v in (NSArray *)obj) [a addObject:TPKNullLiveFeedWatchLimits(v, depth + 1) ?: (id)kCFNull];
    return a;
  }
  if ([obj isKindOfClass:NSString.class] && [(NSString *)obj containsString:@"atchSeconds"]) {

    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      re = [NSRegularExpression regularExpressionWithPattern:
              @"(\\\\?\"(?:maxStreamWatchSeconds|maxWatchSeconds)\\\\?\"\\s*:\\s*)\\d+" options:0 error:nil];
    });
    NSString *s = obj;
    NSUInteger before = [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!before) return obj;
    os_log(OS_LOG_DEFAULT, "[TPK-Home] feed preload: nulled %lu watch limit(s) in JSON text", (unsigned long)before);
    TPKPreloadLimitsNulled += before;
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length)
                                   withTemplate:@"$1null"];
  }
  return obj;
}

static void TPKInstallFeedPreloadHooks(void) {
  SEL sel = NSSelectorFromString(@"awaitFeedPreload:rejecter:");
  BOOL found = NO;
  unsigned int count = 0;
  const char **names = objc_copyClassNamesForImage(NSBundle.mainBundle.executablePath.UTF8String, &count);
  for (unsigned int i = 0; i < count; i++) {

    if (!strstr(names[i], "RN") && !strstr(names[i], "Preload") && !strstr(names[i], "Feed")) continue;
    Class cls = objc_getClass(names[i]);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) continue;
    Class sup = class_getSuperclass(cls);
    if (sup && class_getInstanceMethod(sup, sel) == m) continue;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, TPKFeedRNResolve resolve, TPKFeedRNReject reject) {
      TPKFeedRNResolve wrapped = resolve;
      BOOL filterPreloadAds = TPKAdblockFeedAdsFilteringEnabled();
      if (resolve && (filterPreloadAds || tpk_keepLiveFeedPlayingEnabled())) {
        wrapped = ^(id result) {

          // La première page préchargée contourne les hooks réseau.
          id clean = TPKAdblockFeedAdsFilteringEnabled()
              ? TPKAdblockStripPreloadFeedAds(result, 0) : result;
          if (!tpk_keepLiveFeedPlayingEnabled()) {
            resolve(clean);
            return;
          }
          NSUInteger before = TPKPreloadLimitsNulled;
          id out = TPKNullLiveFeedWatchLimits(clean, 0);
          os_log(OS_LOG_DEFAULT, "[TPK-Home] feed preload resolved (%{public}@), limits nulled: %lu",
                 NSStringFromClass([result class]), (unsigned long)(TPKPreloadLimitsNulled - before));
          resolve(out);
        };
      }
      ((void (*)(id, SEL, TPKFeedRNResolve, TPKFeedRNReject))orig)(self, sel, wrapped, reject);
    }));
    os_log(OS_LOG_DEFAULT, "[TPK-Home] hooked feed preload bridge on %{public}s", names[i]);
    found = YES;
  }
  free(names);
  if (!found)
    os_log(OS_LOG_DEFAULT, "[TPK-Home] no class implements awaitFeedPreload:rejecter: (pre-31 Twitch?)");
}

void tpk_installHomeFeatureRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tpk_registerHomeFeatureDefaults();
        TPKNativeLaunchDestination = tpk_launchDestination();
        TPKInstallFeedPreloadHooks();
        TPKTryInstallHomeFeatureHooks();
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ TPKTryInstallHomeFeatureHooks(); });
        }
    });
}
