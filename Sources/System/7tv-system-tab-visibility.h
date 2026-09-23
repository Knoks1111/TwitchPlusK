// Masquage d'onglets au niveau modèle (viewControllers).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Ordre des onglets.
typedef NS_ENUM(NSInteger, S7TVTabItem) {
    S7TVTabItemHome = 0,   // Accueil
    S7TVTabItemExplore,    // Parcourir
    S7TVTabItemCreate,     // Création (bouton sans titre)
    S7TVTabItemActivity,   // Activité
    S7TVTabItemProfile,    // Profil
};

#define S7TV_TAB_ITEM_COUNT 5

void s7tv_registerTabVisibilityDefaults(void);

// YES = masqué.
BOOL s7tv_tabItemHidden(S7TVTabItem item);
void s7tv_setTabItemHidden(S7TVTabItem item, BOOL hidden);

NSInteger s7tv_tabVisibleCount(void);

void s7tv_tabVisibilityApply(UITabBarController *controller);

// Filtre les listes posées par Twitch.
void s7tv_installTabVisibilityHooks(void);

// Applique maintenant (barre sous écrans présentés).
void s7tv_tabVisibilityApplyNow(void);

// Index d'origine → index réel. NSNotFound si masqué.
NSUInteger s7tv_tabVisibilityIndexForStockIndex(NSUInteger stockIndex);

NS_ASSUME_NONNULL_END
