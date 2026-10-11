#import "UI/tpK-oled-mode.h"
#import "Core/tpK-core-manager.h"
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdbool.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

NSString *const TPKOLEDModePreferenceKey = @"tpk_oled_mode";
NSString *const TPKOLEDModeDidChangeNotification = @"TPKOLEDModeDidChange";

static NSString *const kTPKNativeThemeDidChangeNotification =
    @"ThemeManagerCurrentThemeDidChangeNotification";

typedef UIColor *(*TPKOLEDColorRedIMP)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef void (*TPKOLEDViewBackgroundIMP)(id, SEL, UIColor *);
typedef void (*TPKOLEDViewDidAppearIMP)(id, SEL, BOOL);

typedef struct {
    Class targetClass;
    TPKOLEDViewBackgroundIMP original;
} TPKOLEDReactBackgroundHook;

static const NSUInteger kTPKOLEDMaxReactBackgroundHooks = 4;
static TPKOLEDReactBackgroundHook tpk_oledReactBackgroundHooks[4];
static NSUInteger tpk_oledReactBackgroundHookCount = 0;

static _Atomic(bool) tpk_oledEnabled = false;
static BOOL tpk_oledRuntimeHooksInstalled = NO;
static BOOL tpk_oledViewControllerHookInstalled = NO;
static uintptr_t tpk_oledTwitchImageStart = 0;
static uintptr_t tpk_oledTwitchImageEnd = 0;
static TPKOLEDColorRedIMP tpk_oledOriginalColorWithRed = NULL;
static TPKOLEDColorRedIMP tpk_oledOriginalInitWithRed = NULL;
static TPKOLEDViewBackgroundIMP tpk_oledNativeSetBackgroundColor = NULL;
static TPKOLEDViewDidAppearIMP tpk_oledOriginalViewDidAppear = NULL;
static id tpk_lastThemeManager = nil;
static const char kTPKOLEDOriginalReactBackgroundKey = 0;

static void tpk_oledInstallReactBackgroundHooks(void);
static void tpk_oledApplyReactBackgrounds(UIView *view);
static void tpk_oledRestoreReactBackgrounds(UIView *view);
static void tpk_oledRefreshReactBackgrounds(void);
static void tpk_oledInstallViewControllerHook(void);
static Method tpk_oledMethodDeclaredOnClass(Class targetClass, SEL selector);

BOOL TPKOLEDModeEnabled(void) {
    return atomic_load_explicit(&tpk_oledEnabled, memory_order_relaxed);
}

static BOOL tpk_oledApplyEnabled(void) {
    return TPKOLEDModeEnabled();
}

static void tpk_oledFindTwitchImage(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || (strcmp(name, "Twitch") != 0 && !strstr(name, ".app/Twitch"))) continue;

        const struct mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        uintptr_t start = (uintptr_t)header;
        uintptr_t end = start;
        const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                uintptr_t segmentEnd = (uintptr_t)(segment->vmaddr + slide + segment->vmsize);
                if (segmentEnd > end) end = segmentEnd;
            }
            cursor += command->cmdsize;
        }
        if (end > start) {
            tpk_oledTwitchImageStart = start;
            tpk_oledTwitchImageEnd = end;
            return;
        }
    }
}

static BOOL tpk_oledCallerInTwitchImage(uintptr_t caller) {
    return tpk_oledTwitchImageStart && caller >= tpk_oledTwitchImageStart &&
        caller < tpk_oledTwitchImageEnd;
}

static BOOL tpk_oledColorMatches(CGFloat value, CGFloat expected) {
    return fabs(value - expected) <= 0.002;
}

static BOOL tpk_oledShouldMapColor(CGFloat red, CGFloat green, CGFloat blue,
                                     uintptr_t caller) {
    if (!tpk_oledApplyEnabled() || !tpk_oledCallerInTwitchImage(caller)) return NO;

    CGFloat body = 14.0 / 255.0;
    CGFloat base = 24.0 / 255.0;
    CGFloat alt = 31.0 / 255.0;
    BOOL isBody = tpk_oledColorMatches(red, body) &&
        tpk_oledColorMatches(green, body) &&
        tpk_oledColorMatches(blue, 16.0 / 255.0);
    BOOL isBase = tpk_oledColorMatches(red, base) &&
        tpk_oledColorMatches(green, base) &&
        tpk_oledColorMatches(blue, 27.0 / 255.0);
    BOOL isAlt = tpk_oledColorMatches(red, alt) &&
        tpk_oledColorMatches(green, alt) &&
        tpk_oledColorMatches(blue, 35.0 / 255.0);
    return isBody || isBase || isAlt;
}

static Method tpk_oledMethodDeclaredOnClass(Class targetClass, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    Method result = NULL;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL tpk_oledReactBackgroundView(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass([view class]);
    if ([className rangeOfString:@"Text"].location != NSNotFound ||
        [className rangeOfString:@"Label"].location != NSNotFound ||
        [className rangeOfString:@"Button"].location != NSNotFound ||
        [className rangeOfString:@"Image"].location != NSNotFound ||
        [className rangeOfString:@"Icon"].location != NSNotFound ||
        [className rangeOfString:@"Avatar"].location != NSNotFound ||
        [className rangeOfString:@"Badge"].location != NSNotFound) return NO;
    if ([className rangeOfString:@"RCTViewComponentView"].location != NSNotFound ||
        [className rangeOfString:@"RNSScreenContentWrapper"].location != NSNotFound) return YES;
    Class componentClass = NSClassFromString(@"RCTViewComponentView");
    return componentClass && [view isKindOfClass:componentClass];
}

static BOOL tpk_oledReactBackgroundColor(UIColor *color) {
    if (!color) return NO;
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 1.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] &&
        ![color getWhite:&red alpha:&alpha]) return NO;
    if (alpha < 0.95) return NO;
    CGFloat maximum = MAX(red, MAX(green, blue));
    CGFloat minimum = MIN(red, MIN(green, blue));
    return maximum > 0.01 && maximum - minimum <= 0.04;
}

static const TPKOLEDReactBackgroundHook *tpk_oledReactBackgroundHookForReceiver(id receiver) {
    for (Class currentClass = object_getClass(receiver); currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        for (NSUInteger index = 0; index < tpk_oledReactBackgroundHookCount; index++) {
            TPKOLEDReactBackgroundHook *hook = &tpk_oledReactBackgroundHooks[index];
            if (hook->targetClass == currentClass) return hook;
        }
    }
    return NULL;
}

static void tpk_oledSetReactBackgroundColor(id self, SEL _cmd, UIColor *color) {
    const TPKOLEDReactBackgroundHook *hook =
        tpk_oledReactBackgroundHookForReceiver(self);
    UIView *view = (UIView *)self;
    UIColor *effectiveColor = color;
    BOOL eligible = tpk_oledReactBackgroundView(view) &&
        tpk_oledReactBackgroundColor(color);

    if (eligible && tpk_oledApplyEnabled()) {
        objc_setAssociatedObject(view, &kTPKOLEDOriginalReactBackgroundKey,
                                 color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        effectiveColor = UIColor.blackColor;
    } else {
        objc_setAssociatedObject(view, &kTPKOLEDOriginalReactBackgroundKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (hook && hook->original) {
        hook->original(self, _cmd, effectiveColor);
    } else if (tpk_oledNativeSetBackgroundColor) {
        tpk_oledNativeSetBackgroundColor(self, _cmd, effectiveColor);
    }
}

static BOOL tpk_oledInstallReactBackgroundHook(Class targetClass) {
    if (!targetClass || tpk_oledReactBackgroundHookCount >= kTPKOLEDMaxReactBackgroundHooks) return NO;
    for (NSUInteger index = 0; index < tpk_oledReactBackgroundHookCount; index++) {
        if (tpk_oledReactBackgroundHooks[index].targetClass == targetClass) return YES;
    }

    SEL selector = @selector(setBackgroundColor:);
    Method declaredMethod = tpk_oledMethodDeclaredOnClass(targetClass, selector);
    Method method = class_getInstanceMethod(targetClass, selector);
    if (!method) return NO;
    IMP currentImplementation = method_getImplementation(method);
    if (!currentImplementation || currentImplementation == (IMP)tpk_oledSetReactBackgroundColor) {
        return currentImplementation == (IMP)tpk_oledSetReactBackgroundColor;
    }

    if (declaredMethod) {
        method_setImplementation(declaredMethod, (IMP)tpk_oledSetReactBackgroundColor);
    } else if (!class_addMethod(targetClass, selector,
                                 (IMP)tpk_oledSetReactBackgroundColor,
                                 method_getTypeEncoding(method))) {
        return NO;
    }

    tpk_oledReactBackgroundHooks[tpk_oledReactBackgroundHookCount++] =
        (TPKOLEDReactBackgroundHook){
            .targetClass = targetClass,
            .original = (TPKOLEDViewBackgroundIMP)currentImplementation,
        };
    return YES;
}

static void tpk_oledInstallReactBackgroundHooks(void) {
    tpk_oledInstallReactBackgroundHook(NSClassFromString(@"RCTViewComponentView"));
    tpk_oledInstallReactBackgroundHook(NSClassFromString(@"RNSScreenContentWrapper"));
}

static void tpk_oledApplyReactBackgrounds(UIView *view) {
    if (!view) return;
    UIColor *color = view.backgroundColor;
    if (tpk_oledReactBackgroundView(view) && tpk_oledReactBackgroundColor(color)) {
        tpk_oledSetReactBackgroundColor(view, @selector(setBackgroundColor:), color);
    }
    for (UIView *subview in view.subviews) {
        tpk_oledApplyReactBackgrounds(subview);
    }
}

static void tpk_oledRestoreReactBackgrounds(UIView *view) {
    if (!view) return;
    UIColor *originalColor = objc_getAssociatedObject(view,
                                                       &kTPKOLEDOriginalReactBackgroundKey);
    if (originalColor && tpk_oledReactBackgroundView(view)) {
        const TPKOLEDReactBackgroundHook *hook =
            tpk_oledReactBackgroundHookForReceiver(view);
        SEL selector = @selector(setBackgroundColor:);
        if (hook && hook->original) {
            hook->original(view, selector, originalColor);
        } else if (tpk_oledNativeSetBackgroundColor) {
            tpk_oledNativeSetBackgroundColor(view, selector, originalColor);
        }
        objc_setAssociatedObject(view, &kTPKOLEDOriginalReactBackgroundKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *subview in view.subviews) {
        tpk_oledRestoreReactBackgrounds(subview);
    }
}

static void tpk_oledRefreshReactBackgrounds(void) {
    void (^refresh)(void) = ^{
        tpk_oledInstallReactBackgroundHooks();
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (tpk_oledApplyEnabled()) {
                tpk_oledApplyReactBackgrounds(window);
            } else {
                tpk_oledRestoreReactBackgrounds(window);
            }
        }
    };
    if ([NSThread isMainThread]) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

static void tpk_oledViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (tpk_oledOriginalViewDidAppear) {
        tpk_oledOriginalViewDidAppear(self, _cmd, animated);
    }
    if (!tpk_oledApplyEnabled()) return;
    __weak UIViewController *controller = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = controller;
        if (!strongController) return;
        tpk_oledInstallReactBackgroundHooks();
        tpk_oledApplyReactBackgrounds(strongController.view);
    });
}

static void tpk_oledInstallViewControllerHook(void) {
    if (tpk_oledViewControllerHookInstalled) return;
    Method method = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (!method) return;
    tpk_oledOriginalViewDidAppear =
        (TPKOLEDViewDidAppearIMP)method_getImplementation(method);
    method_setImplementation(method, (IMP)tpk_oledViewDidAppear);
    tpk_oledViewControllerHookInstalled = YES;
}

static UIColor *tpk_oledColorWithRed(id self, SEL _cmd, CGFloat red, CGFloat green,
                                      CGFloat blue, CGFloat alpha) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    BOOL replace = tpk_oledShouldMapColor(red, green, blue, caller);
    return tpk_oledOriginalColorWithRed
        ? tpk_oledOriginalColorWithRed(self, _cmd, replace ? 0.0 : red,
                                       replace ? 0.0 : green, replace ? 0.0 : blue, alpha)
        : nil;
}

static UIColor *tpk_oledInitWithRed(id self, SEL _cmd, CGFloat red, CGFloat green,
                                     CGFloat blue, CGFloat alpha) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    BOOL replace = tpk_oledShouldMapColor(red, green, blue, caller);
    return tpk_oledOriginalInitWithRed
        ? tpk_oledOriginalInitWithRed(self, _cmd, replace ? 0.0 : red,
                                       replace ? 0.0 : green, replace ? 0.0 : blue, alpha)
        : nil;
}

static void tpk_oledInstallRuntimeHooks(void) {
    if (tpk_oledRuntimeHooksInstalled) return;
    tpk_oledFindTwitchImage();

    SEL colorSelector = sel_registerName("colorWithRed:green:blue:alpha:");
    Method colorMethod = class_getClassMethod([UIColor class], colorSelector);
    if (colorMethod) {
        tpk_oledOriginalColorWithRed =
            (TPKOLEDColorRedIMP)method_getImplementation(colorMethod);
        method_setImplementation(colorMethod, (IMP)tpk_oledColorWithRed);
    }

    SEL initSelector = sel_registerName("initWithRed:green:blue:alpha:");
    Method initMethod = class_getInstanceMethod([UIColor class], initSelector);
    if (initMethod) {
        tpk_oledOriginalInitWithRed =
            (TPKOLEDColorRedIMP)method_getImplementation(initMethod);
        method_setImplementation(initMethod, (IMP)tpk_oledInitWithRed);
    }

    Method backgroundMethod = class_getInstanceMethod([UIView class],
                                                       @selector(setBackgroundColor:));
    if (backgroundMethod) {
        tpk_oledNativeSetBackgroundColor =
            (TPKOLEDViewBackgroundIMP)method_getImplementation(backgroundMethod);
    }

    tpk_oledInstallReactBackgroundHooks();
    tpk_oledInstallViewControllerHook();
    tpk_oledRuntimeHooksInstalled = YES;
}

static id tpk_activeThemeManager(void) {
    if (tpk_lastThemeManager) return tpk_lastThemeManager;
    id appDelegate = UIApplication.sharedApplication.delegate;
    SEL themeManagerSelector = NSSelectorFromString(@"themeManager");
    if (appDelegate && [appDelegate respondsToSelector:themeManagerSelector]) {
        id themeManager = ((id (*)(id, SEL))objc_msgSend)(appDelegate, themeManagerSelector);
        if (themeManager) tpk_lastThemeManager = themeManager;
    }
    return tpk_lastThemeManager;
}

static void tpk_requestNativeThemeRefresh(void) {
    void (^refresh)(void) = ^{
        id themeManager = tpk_activeThemeManager();
        if (!themeManager) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kTPKNativeThemeDidChangeNotification
                          object:themeManager];
    };
    if ([NSThread isMainThread]) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

void TPKOLEDModeSetEnabled(BOOL enabled) {
    TPKOLEDModeSetup();
    BOOL previous = TPKOLEDModeEnabled();
    if (previous == enabled) return;

    atomic_store_explicit(&tpk_oledEnabled, enabled, memory_order_relaxed);
    tpk_oledRefreshReactBackgrounds();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:TPKOLEDModePreferenceKey];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKOLEDModeDidChangeNotification object:nil];
    if (tpk_oledApplyEnabled()) tpk_requestNativeThemeRefresh();
}

void TPKOLEDModeReloadFromDefaults(void) {
    TPKOLEDModeSetup();
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:TPKOLEDModePreferenceKey];
    BOOL changed = TPKOLEDModeEnabled() != enabled;
    atomic_store_explicit(&tpk_oledEnabled, enabled, memory_order_relaxed);
    if (changed) {
        tpk_oledRefreshReactBackgrounds();
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKOLEDModeDidChangeNotification object:nil];
        if (tpk_oledApplyEnabled()) tpk_requestNativeThemeRefresh();
    }
}

void TPKOLEDModeSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        atomic_store_explicit(&tpk_oledEnabled,
                              [NSUserDefaults.standardUserDefaults
                                  boolForKey:TPKOLEDModePreferenceKey],
                              memory_order_relaxed);
        [[NSNotificationCenter defaultCenter]
            addObserverForName:kTPKNativeThemeDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            if (note.object) tpk_lastThemeManager = note.object;
        }];
        tpk_oledInstallRuntimeHooks();
    });
}
