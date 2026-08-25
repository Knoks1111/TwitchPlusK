/*
 * 7tv-oled-mode.m
 *
 * Architecture inspirée des tweaks OLED YouTube : remplacer les couleurs à
 * leur source, dans la palette de thème, puis ne traiter séparément que les
 * écrans qui contournent cette palette. Pour Twitch 30.6, le getter mobile
 * screenExtendedBackgroundColor complète les tokens de palette ; aucun hook
 * UIView global n'est nécessaire.
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

// Nom publié par TwitchCoreUI/ThemeManager.swift. Les composants Twitch
// réappliquent leur ThemeProtocol lorsqu'ils reçoivent cette notification.
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

static const char * const kS7TVOLEDDarkThemeClassNames[] = {
    "_TtC12TwitchCoreUI15CoreUIDarkTheme",
    "_TtC12TwitchCoreUI17DarkMobileUITheme",
};

// @selector(...) cannot be used in a C static initializer with the older
// clang/Theos toolchain. Keep the names static, then resolve the selectors
// once while installing the hooks.
static const char * const kS7TVOLEDBackgroundSelectorNames[] = {
    // Getter déclaré par DarkMobileUITheme pour Accueil, Suivis, Live et
    // Clips. Il ne fait pas partie de la palette background... commune.
    "screenExtendedBackgroundColor",
    // Fonds de page et de sections.
    "backgroundBaseColor",
    "backgroundBodyColor",
    "backgroundAltColor",
    "backgroundAlt2Color",
    // Fonds des écrans et composants qui ne passent pas par les quatre
    // tokens principaux : modales, menus, barres et surfaces du chat natif.
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

// class_getInstanceMethod: remonte aussi les superclasses. Pour ne jamais
// changer une palette claire qui partagerait un parent avec un thème sombre,
// il faut savoir si le thème cible déclare réellement ce sélecteur.
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

    // Les deux classes ciblées sont exclusivement les variantes sombres de
    // TwitchCoreUI ; une seule lecture atomique suffit donc ici.
    if (S7TVOLEDModeEnabled()) return UIColor.blackColor;
    return hook->original(self, _cmd);
}

static void s7tv_installOLEDHook(Class targetClass, SEL selector) {
    if (!targetClass || s7tv_oledHookCount >= kS7TVOLEDMaxHooks ||
        s7tv_oledHookExists(targetClass, selector)) return;

    Method declaredMethod = s7tv_oledMethodDeclaredOnClass(targetClass, selector);
    // Si le sous-type n'a pas son propre getter, il hérite déjà du hook du
    // parent. En revanche, un override doit toujours être couvert.
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
        // Sans override local sûr, ne jamais modifier une éventuelle classe
        // parente partagée avec le thème clair.
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
    // Le switch est manipulé sur le main thread ; conserver explicitement ce
    // contexte protège aussi les imports de préférences appelés hors UI.
    dispatch_async(dispatch_get_main_queue(), ^{
        id themeManager = s7tv_activeThemeManager();
        if (!themeManager) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:kS7TVNativeThemeDidChangeNotification
                          object:themeManager];
    });
}

void S7TVOLEDModeSetEnabled(BOOL enabled) {
    S7TVOLEDModeSetup();
    BOOL previous = S7TVOLEDModeEnabled();
    if (previous == enabled) return;

    atomic_store_explicit(&s7tv_oledEnabled, enabled, memory_order_relaxed);
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
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVOLEDModeDidChangeNotification object:nil];
        s7tv_requestNativeThemeRefresh();
    }
}

void S7TVOLEDModeSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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

        // Exécuté dans le constructeur du tweak, avant la création du premier
        // écran Twitch : les fonds du lancement et des catégories ne peuvent
        // donc pas conserver une couleur mise en cache avant le hook.
        s7tv_installOLEDPaletteHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            // Le second passage est idempotent et couvre une éventuelle
            // classe Swift enregistrée juste après le constructeur.
            s7tv_installOLEDPaletteHooks();
            s7tv_activeThemeManager();
            if (S7TVOLEDModeEnabled()) s7tv_requestNativeThemeRefresh();
        });
    });
}
