// TwitchPlusK settings pages and native Twitch integration.

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT UIColor *TPKAccent(void);

// Main settings page.
@interface TPKSettingsController : UITableViewController

// YES when presented modally; controls the navigation-bar close button.
@property (nonatomic, assign) BOOL openedAsModal;

// Installs the settings section in native Twitch settings.
+ (void)installTwitchSettingsIntegration;

@end

// Settings pages.
@interface TPKAppearancePageController : UITableViewController @end  // Apparence
@interface TPKContentPageController    : UITableViewController @end  // Contenu
@interface TPKTabBarSettingsController : UITableViewController @end  // Onglets + écran de lancement
@interface TPKAdblockPageController    : UITableViewController @end  // Adblock vidéo + proxy
@interface TPKAdvancedPageController   : UITableViewController @end  // Avancé
@interface TPKFavoritesListController  : UITableViewController @end
