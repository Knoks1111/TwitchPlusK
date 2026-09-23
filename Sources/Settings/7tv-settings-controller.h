// TwitchPlusK settings pages and native Twitch integration.

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT UIColor *S7TVAccent(void);

// Main settings page.
@interface SevenTVSettingsController : UITableViewController

// YES when presented modally; controls the navigation-bar close button.
@property (nonatomic, assign) BOOL openedAsModal;

// Installs the settings section in native Twitch settings.
+ (void)installTwitchSettingsIntegration;

@end

// Settings pages.
@interface SevenTVAppearancePageController : UITableViewController @end  // Apparence
@interface SevenTVContentPageController    : UITableViewController @end  // Contenu
@interface SevenTVTabBarSettingsController : UITableViewController @end  // Onglets + écran de lancement
@interface SevenTVAdblockPageController    : UITableViewController @end  // Adblock vidéo + proxy
@interface SevenTVAdvancedPageController   : UITableViewController @end  // Avancé
@interface SevenTVFavoritesListController  : UITableViewController @end
