/*
 * 7tv-oled-mode.m
 *
 * Gestion du mode OLED et des fonds ciblés de Twitch.
 */

#import "UI/7tv-oled-mode.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdbool.h>
#import <stdatomic.h>
#import <stdlib.h>

NSString *const S7TVOLEDModePreferenceKey = @"s7tv_oled_mode";
NSString *const S7TVOLEDModeDidChangeNotification = @"S7TVOLEDModeDidChange";

// Notification du gestionnaire de thème natif Twitch.
static NSString *const kS7TVNativeThemeDidChangeNotification =
    @"ThemeManagerCurrentThemeDidChangeNotification";

typedef UIColor *(*S7TVOLEDColorGetterIMP)(id, SEL);

typedef struct {
    Class targetClass;
    SEL selector;
    S7TVOLEDColorGetterIMP original;
} S7TVOLEDHook;

// CoreUIDarkTheme porte la palette commune et DarkMobileUITheme les getters
// propres aux écrans mobiles, dont screenExtendedBackgroundColor.
static const NSUInteger kS7TVOLEDMaxHooks = 32;
static S7TVOLEDHook s7tv_oledHooks[32];
static NSUInteger s7tv_oledHookCount = 0;
static _Atomic(bool) s7tv_oledEnabled = false;
static id s7tv_lastThemeManager = nil;
static NSHashTable<UIViewController *> *s7tv_oledHostingControllers;
static const char kS7TVOLEDHostingControllerState = 0;
static IMP s7tv_originalViewWillAppear = NULL;

static const char * const kS7TVOLEDDarkThemeClassNames[] = {
    "_TtC12TwitchCoreUI15CoreUIDarkTheme",
    "_TtC12TwitchCoreUI17DarkMobileUITheme",
};

// Résoudre les sélecteurs au moment de l'installation.
static const char * const kS7TVOLEDBackgroundSelectorNames[] = {
    // Fond étendu de DarkMobileUITheme.
    "screenExtendedBackgroundColor",
    // Fonds principaux.
    "backgroundBaseColor",
    "backgroundBodyColor",
    "backgroundAltColor",
    "backgroundAlt2Color",
    // Fonds secondaires, modaux et surfaces du chat.
    "backgroundFloatColor",
    "backgroundModalColor",
    "backgroundOverlayBaseColor",
    "backgroundOverlayAltColor",
    "backgroundChatColor",
    "backgroundChatAltColor",
    "backgroundChatHeaderColor",
    "backgroundTopNavColor",
    "backgroundSocialColumnColor",
};

BOOL S7TVOLEDModeEnabled(void) {
    return atomic_load_explicit(&s7tv_oledEnabled, memory_order_relaxed);
}

static BOOL s7tv_oledHookExists(Class targetClass, SEL selector) {
    for (NSUInteger index = 0; index < s7tv_oledHookCount; index++) {
        S7TVOLEDHook hook = s7tv_oledHooks[index];
        if (hook.targetClass == targetClass && hook.selector == selector) return YES;
    }
    return NO;
}

static BOOL s7tv_oledSuperclassAlreadyHooked(Class targetClass, SEL selector) {
    for (Class superclass = class_getSuperclass(targetClass); superclass != Nil;
         superclass = class_getSuperclass(superclass)) {
        if (s7tv_oledHookExists(superclass, selector)) return YES;
    }
    return NO;
}

// Vérifier si le sélecteur est déclaré localement.
static Method s7tv_oledMethodDeclaredOnClass(Class targetClass, SEL selector) {
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

static const S7TVOLEDHook *s7tv_oledHookForReceiver(id receiver, SEL selector) {
    for (Class currentClass = object_getClass(receiver); currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        for (NSUInteger index = 0; index < s7tv_oledHookCount; index++) {
            S7TVOLEDHook *hook = &s7tv_oledHooks[index];
            if (hook->targetClass == currentClass && hook->selector == selector) {
                return hook;
            }
        }
    }
    return NULL;
}

static UIColor *s7tv_oledBackgroundColorGetter(id self, SEL _cmd) {
    const S7TVOLEDHook *hook = s7tv_oledHookForReceiver(self, _cmd);
    if (!hook || !hook->original) return nil;

    // Ces classes appartiennent au thème sombre de Twitch.
    if (S7TVOLEDModeEnabled()) return UIColor.blackColor;
    return hook->original(self, _cmd);
}

static void s7tv_installOLEDHook(Class targetClass, SEL selector) {
    if (!targetClass || s7tv_oledHookCount >= kS7TVOLEDMaxHooks ||
        s7tv_oledHookExists(targetClass, selector)) return;

    Method declaredMethod = s7tv_oledMethodDeclaredOnClass(targetClass, selector);
    // Éviter de modifier un parent partagé avec le thème clair.
    if (!declaredMethod && s7tv_oledSuperclassAlreadyHooked(targetClass, selector)) return;

    Method inheritedOrDeclaredMethod = class_getInstanceMethod(targetClass, selector);
    if (!inheritedOrDeclaredMethod) return;

    S7TVOLEDColorGetterIMP original =
        (S7TVOLEDColorGetterIMP)method_getImplementation(inheritedOrDeclaredMethod);
    if (!original) return;

    if (declaredMethod) {
        method_setImplementation(declaredMethod, (IMP)s7tv_oledBackgroundColorGetter);
    } else if (!class_addMethod(targetClass, selector,
                                (IMP)s7tv_oledBackgroundColorGetter,
                                method_getTypeEncoding(inheritedOrDeclaredMethod))) {
        // Ne pas modifier un parent partagé sans override local.
        return;
    }

    s7tv_oledHooks[s7tv_oledHookCount++] = (S7TVOLEDHook){
        .targetClass = targetClass,
        .selector = selector,
        .original = original,
    };
}

static void s7tv_installOLEDHooksForThemeClasses(const char * const *classNames,
                                                  NSUInteger themeCount) {
    const NSUInteger selectorCount = sizeof(kS7TVOLEDBackgroundSelectorNames) /
        sizeof(kS7TVOLEDBackgroundSelectorNames[0]);

    for (NSUInteger themeIndex = 0; themeIndex < themeCount; themeIndex++) {
        Class themeClass = objc_getClass(classNames[themeIndex]);
        if (!themeClass) continue;
        for (NSUInteger selectorIndex = 0; selectorIndex < selectorCount; selectorIndex++) {
            SEL selector = sel_registerName(kS7TVOLEDBackgroundSelectorNames[selectorIndex]);
            s7tv_installOLEDHook(themeClass, selector);
        }
    }
}

static void s7tv_installOLEDPaletteHooks(void) {
    s7tv_installOLEDHooksForThemeClasses(
        kS7TVOLEDDarkThemeClassNames,
        sizeof(kS7TVOLEDDarkThemeClassNames) / sizeof(kS7TVOLEDDarkThemeClassNames[0]));
}

static BOOL s7tv_isUIHostingController(UIViewController *controller) {
    for (Class cls = object_getClass(controller); cls; cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if ([name rangeOfString:@"UIHostingController"].location != NSNotFound) return YES;
    }
    return NO;
}

static void s7tv_updateOLEDHostingController(UIViewController *controller) {
    if (!s7tv_isUIHostingController(controller)) return;

    [s7tv_oledHostingControllers addObject:controller];

    NSDictionary *state = objc_getAssociatedObject(controller,
                                                     &kS7TVOLEDHostingControllerState);
    if (!S7TVOLEDModeEnabled()) {
        if (!state) return;
        controller.overrideUserInterfaceStyle = [state[@"style"] integerValue];
        id backgroundColor = state[@"backgroundColor"];
        controller.view.backgroundColor = [backgroundColor isKindOfClass:[NSNull class]]
            ? nil : backgroundColor;
        objc_setAssociatedObject(controller, &kS7TVOLEDHostingControllerState,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!state) {
        objc_setAssociatedObject(controller, &kS7TVOLEDHostingControllerState,
            @{ @"style": @(controller.overrideUserInterfaceStyle),
               @"backgroundColor": controller.view.backgroundColor ?: [NSNull null] },
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    controller.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    controller.view.backgroundColor = UIColor.blackColor;
}

static void s7tv_updateOLEDHostingControllers(void) {
    void (^update)(void) = ^{
        for (UIViewController *controller in s7tv_oledHostingControllers.allObjects) {
            s7tv_updateOLEDHostingController(controller);
        }
    };

    if ([NSThread isMainThread]) update();
    else dispatch_async(dispatch_get_main_queue(), update);
}

static void s7tv_oledViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (s7tv_originalViewWillAppear) {
        ((void (*)(id, SEL, BOOL))s7tv_originalViewWillAppear)(self, _cmd, animated);
    }
    if (S7TVOLEDModeEnabled() ||
        objc_getAssociatedObject(self, &kS7TVOLEDHostingControllerState)) {
        s7tv_updateOLEDHostingController((UIViewController *)self);
    }
}

static void s7tv_installOLEDHostingControllerHook(void) {
    if (s7tv_originalViewWillAppear) return;
    Method method = class_getInstanceMethod([UIViewController class], @selector(viewWillAppear:));
    if (!method) return;
    s7tv_originalViewWillAppear = method_getImplementation(method);
    method_setImplementation(method, (IMP)s7tv_oledViewWillAppear);
}

// Clavier OLED.
//
// Les vues du clavier sont traitées uniquement quand le mode OLED est actif.

typedef struct {
    Class targetClass;
    SEL selector;
    IMP original;
} S7TVOLEDKeyboardHook;

static const NSUInteger kS7TVOLEDMaxKeyboardHooks = 8;
static S7TVOLEDKeyboardHook s7tv_oledKeyboardHooks[8];
static NSUInteger s7tv_oledKeyboardHookCount = 0;

static BOOL s7tv_oledKeyboardHookExists(Class targetClass, SEL selector) {
    for (NSUInteger index = 0; index < s7tv_oledKeyboardHookCount; index++) {
        S7TVOLEDKeyboardHook hook = s7tv_oledKeyboardHooks[index];
        if (hook.targetClass == targetClass && hook.selector == selector) return YES;
    }
    return NO;
}

static BOOL s7tv_oledKeyboardSuperclassAlreadyHooked(Class targetClass, SEL selector) {
    for (Class superclass = class_getSuperclass(targetClass); superclass != Nil;
         superclass = class_getSuperclass(superclass)) {
        if (s7tv_oledKeyboardHookExists(superclass, selector)) return YES;
    }
    return NO;
}

static const S7TVOLEDKeyboardHook *s7tv_oledKeyboardHookForReceiver(id receiver,
                                                                    SEL selector) {
    for (Class currentClass = object_getClass(receiver); currentClass != Nil;
         currentClass = class_getSuperclass(currentClass)) {
        for (NSUInteger index = 0; index < s7tv_oledKeyboardHookCount; index++) {
            S7TVOLEDKeyboardHook *hook = &s7tv_oledKeyboardHooks[index];
            if (hook->targetClass == currentClass && hook->selector == selector) {
                return hook;
            }
        }
    }
    return NULL;
}

static BOOL s7tv_oledKeyboardViewIsDark(id view) {
    if (!view) return NO;

    // Certaines vues clavier n'exposent pas un UIViewController classique.
    SEL mapkitDarkModeSelector = sel_registerName("_mapkit_isDarkModeEnabled");
    if ([view respondsToSelector:mapkitDarkModeSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(view, mapkitDarkModeSelector);
    }

    id controller = nil;
    SEL ancestorControllerSelector = sel_registerName("_viewControllerForAncestor");
    if ([view respondsToSelector:ancestorControllerSelector]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(view, ancestorControllerSelector);
    }

    id traitsOwner = controller ?: view;
    if (![traitsOwner respondsToSelector:@selector(traitCollection)]) return NO;
    UITraitCollection *traits = ((id (*)(id, SEL))objc_msgSend)(
        traitsOwner, @selector(traitCollection));
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark;
}

static BOOL s7tv_oledKeyboardShouldUseBlack(id view) {
    return S7TVOLEDModeEnabled() && s7tv_oledKeyboardViewIsDark(view);
}

static void s7tv_applyOLEDKeyboardBackground(UIView *view) {
    if (!view || !S7TVOLEDModeEnabled()) return;
    view.backgroundColor = s7tv_oledKeyboardViewIsDark(view)
        ? UIColor.blackColor
        : UIColor.clearColor;
}

static void s7tv_installOLEDKeyboardHook(Class targetClass, SEL selector, IMP replacement) {
    if (!targetClass || !selector || !replacement ||
        s7tv_oledKeyboardHookCount >= kS7TVOLEDMaxKeyboardHooks ||
        s7tv_oledKeyboardHookExists(targetClass, selector)) return;

    Method declaredMethod = s7tv_oledMethodDeclaredOnClass(targetClass, selector);
    // Éviter les hooks dupliqués sur les sous-classes.
    if (!declaredMethod && s7tv_oledKeyboardSuperclassAlreadyHooked(targetClass, selector)) {
        return;
    }

    Method inheritedOrDeclaredMethod = class_getInstanceMethod(targetClass, selector);
    if (!inheritedOrDeclaredMethod) return;

    IMP original = method_getImplementation(inheritedOrDeclaredMethod);
    if (!original) return;

    if (declaredMethod) {
        method_setImplementation(declaredMethod, replacement);
    } else if (!class_addMethod(targetClass, selector, replacement,
                                method_getTypeEncoding(inheritedOrDeclaredMethod))) {
        return;
    }

    s7tv_oledKeyboardHooks[s7tv_oledKeyboardHookCount++] = (S7TVOLEDKeyboardHook){
        .targetClass = targetClass,
        .selector = selector,
        .original = original,
    };
}

typedef void (*S7TVOLEDKeyboardVoidObjectIMP)(id, SEL, id);
typedef void (*S7TVOLEDKeyboardVoidIMP)(id, SEL);
typedef id (*S7TVOLEDKeyboardObjectIMP)(id, SEL);

static void s7tv_oledKeyboardDisplayLayer(id self, SEL _cmd, id layer) {
    const S7TVOLEDKeyboardHook *hook =
        s7tv_oledKeyboardHookForReceiver(self, _cmd);
    if (hook && hook->original) {
        ((S7TVOLEDKeyboardVoidObjectIMP)hook->original)(self, _cmd, layer);
    }
    s7tv_applyOLEDKeyboardBackground((UIView *)self);
}

static id s7tv_oledKeyboardCurrentTextSuggestions(id self, SEL _cmd) {
    const S7TVOLEDKeyboardHook *hook =
        s7tv_oledKeyboardHookForReceiver(self, _cmd);

    id keyboard = nil;
    Class keyboardClass = objc_getClass("UIKeyboard");
    SEL activeKeyboardSelector = sel_registerName("activeKeyboard");
    if (keyboardClass && [keyboardClass respondsToSelector:activeKeyboardSelector]) {
        keyboard = ((id (*)(id, SEL))objc_msgSend)(keyboardClass, activeKeyboardSelector);
    }

    if (S7TVOLEDModeEnabled()) {
        BOOL dark = s7tv_oledKeyboardViewIsDark(keyboard ?: self);
        UIView *predictionView = [(UIViewController *)self view];
        predictionView.backgroundColor = dark ? UIColor.blackColor : UIColor.clearColor;
        if (keyboard) {
            [(UIView *)keyboard setBackgroundColor:
                dark ? UIColor.blackColor : UIColor.clearColor];
        }
    }

    if (!hook || !hook->original) return nil;
    return ((S7TVOLEDKeyboardObjectIMP)hook->original)(self, _cmd);
}

static void s7tv_oledKeyboardDockLayoutSubviews(id self, SEL _cmd) {
    const S7TVOLEDKeyboardHook *hook =
        s7tv_oledKeyboardHookForReceiver(self, _cmd);
    if (hook && hook->original) {
        ((S7TVOLEDKeyboardVoidIMP)hook->original)(self, _cmd);
    }
    s7tv_applyOLEDKeyboardBackground((UIView *)self);
}

static void s7tv_oledKeyboardInputViewLayoutSubviews(id self, SEL _cmd) {
    const S7TVOLEDKeyboardHook *hook =
        s7tv_oledKeyboardHookForReceiver(self, _cmd);
    if (hook && hook->original) {
        ((S7TVOLEDKeyboardVoidIMP)hook->original)(self, _cmd);
    }

    Class emojiSearchClass = NSClassFromString(@"TUIEmojiSearchInputView");
    Class autofillClass = NSClassFromString(@"_SFAutoFillInputView");
    if ((emojiSearchClass && [self isKindOfClass:emojiSearchClass]) ||
        (autofillClass && [self isKindOfClass:autofillClass])) {
        s7tv_applyOLEDKeyboardBackground((UIView *)self);
    }
}

static void s7tv_oledKeyboardVisualEffectLayoutSubviews(id self, SEL _cmd) {
    const S7TVOLEDKeyboardHook *hook =
        s7tv_oledKeyboardHookForReceiver(self, _cmd);
    if (hook && hook->original) {
        ((S7TVOLEDKeyboardVoidIMP)hook->original)(self, _cmd);
    }

    if (!s7tv_oledKeyboardShouldUseBlack(self)) return;

    SEL setBackgroundEffectsSelector = sel_registerName("setBackgroundEffects:");
    if ([self respondsToSelector:setBackgroundEffectsSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, setBackgroundEffectsSelector, nil);
    }
    [(UIView *)self setBackgroundColor:UIColor.blackColor];
}

static void s7tv_installOLEDKeyboardHooks(void) {
    Class keyboardClass = objc_getClass("UIKeyboard");
    s7tv_installOLEDKeyboardHook(keyboardClass,
        sel_registerName("displayLayer:"), (IMP)s7tv_oledKeyboardDisplayLayer);

    Class predictionClass = objc_getClass("UIPredictionViewController");
    s7tv_installOLEDKeyboardHook(predictionClass,
        sel_registerName("_currentTextSuggestions"),
        (IMP)s7tv_oledKeyboardCurrentTextSuggestions);

    Class dockClass = objc_getClass("UIKeyboardDockView");
    s7tv_installOLEDKeyboardHook(dockClass,
        @selector(layoutSubviews), (IMP)s7tv_oledKeyboardDockLayoutSubviews);

    Class inputViewClass = objc_getClass("UIInputView");
    s7tv_installOLEDKeyboardHook(inputViewClass,
        @selector(layoutSubviews), (IMP)s7tv_oledKeyboardInputViewLayoutSubviews);

    Class visualEffectClass = objc_getClass("UIKBVisualEffectView");
    s7tv_installOLEDKeyboardHook(visualEffectClass,
        @selector(layoutSubviews), (IMP)s7tv_oledKeyboardVisualEffectLayoutSubviews);
}

static id s7tv_activeThemeManager(void) {
    if (s7tv_lastThemeManager) return s7tv_lastThemeManager;

    id appDelegate = UIApplication.sharedApplication.delegate;
    SEL themeManagerSelector = NSSelectorFromString(@"themeManager");
    if (appDelegate && [appDelegate respondsToSelector:themeManagerSelector]) {
        id themeManager = ((id (*)(id, SEL))objc_msgSend)(appDelegate, themeManagerSelector);
        if (themeManager) s7tv_lastThemeManager = themeManager;
    }
    return s7tv_lastThemeManager;
}

static void s7tv_requestNativeThemeRefresh(void) {
    // Le changement de thème est envoyé sur le thread principal.
    void (^refresh)(void) = ^{
        id themeManager = s7tv_activeThemeManager();
        if (!themeManager) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kS7TVNativeThemeDidChangeNotification
                          object:themeManager];
    };

    if ([NSThread isMainThread]) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

void S7TVOLEDModeSetEnabled(BOOL enabled) {
    S7TVOLEDModeSetup();
    BOOL previous = S7TVOLEDModeEnabled();
    if (previous == enabled) return;

    atomic_store_explicit(&s7tv_oledEnabled, enabled, memory_order_relaxed);
    s7tv_updateOLEDHostingControllers();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:enabled forKey:S7TVOLEDModePreferenceKey];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVOLEDModeDidChangeNotification object:nil];
    s7tv_requestNativeThemeRefresh();
}

void S7TVOLEDModeReloadFromDefaults(void) {
    S7TVOLEDModeSetup();
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:S7TVOLEDModePreferenceKey];
    BOOL changed = S7TVOLEDModeEnabled() != enabled;
    atomic_store_explicit(&s7tv_oledEnabled, enabled, memory_order_relaxed);
    if (changed) {
        s7tv_updateOLEDHostingControllers();
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVOLEDModeDidChangeNotification object:nil];
        s7tv_requestNativeThemeRefresh();
    }
}

void S7TVOLEDModeSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s7tv_oledHostingControllers = [NSHashTable weakObjectsHashTable];
        atomic_store_explicit(&s7tv_oledEnabled,
                              [NSUserDefaults.standardUserDefaults
                                  boolForKey:S7TVOLEDModePreferenceKey],
                              memory_order_relaxed);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:kS7TVNativeThemeDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            if (note.object) s7tv_lastThemeManager = note.object;
        }];

        // Installer les hooks avant la création des premiers écrans Twitch.
        s7tv_installOLEDPaletteHooks();
        s7tv_installOLEDKeyboardHooks();
        s7tv_installOLEDHostingControllerHook();

        // Réessayer lorsque les classes clavier sont chargées.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIKeyboardWillShowNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            s7tv_installOLEDKeyboardHooks();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            // Second passage pour les classes Swift chargées tardivement.
            s7tv_installOLEDPaletteHooks();
            s7tv_installOLEDKeyboardHooks();
            s7tv_activeThemeManager();
            if (S7TVOLEDModeEnabled()) s7tv_requestNativeThemeRefresh();
        });
    });
}
