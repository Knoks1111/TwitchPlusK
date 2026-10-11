// Masquage d'onglets au niveau modèle (viewControllers).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Ordre des onglets.
typedef NS_ENUM(NSInteger, TPKTabItem) {
    TPKTabItemHome = 0,   // Accueil
    TPKTabItemExplore,    // Parcourir
    TPKTabItemCreate,     // Création (bouton sans titre)
    TPKTabItemActivity,   // Activité
    TPKTabItemProfile,    // Profil
};

#define TPK_TAB_ITEM_COUNT 5

void tpk_registerTabVisibilityDefaults(void);

// YES = masqué.
BOOL tpk_tabItemHidden(TPKTabItem item);
void tpk_setTabItemHidden(TPKTabItem item, BOOL hidden);

NSInteger tpk_tabVisibleCount(void);

void tpk_tabVisibilityApply(UITabBarController *controller);

// Filtre les listes posées par Twitch.
void tpk_installTabVisibilityHooks(void);

// Applique maintenant (barre sous écrans présentés).
void tpk_tabVisibilityApplyNow(void);

// Index d'origine → index réel. NSNotFound si masqué.
NSUInteger tpk_tabVisibilityIndexForStockIndex(NSUInteger stockIndex);

NS_ASSUME_NONNULL_END
