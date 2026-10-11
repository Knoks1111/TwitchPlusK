// Lancement, Stories, fil Live (dérivé de TwitchAdBlock, MIT).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPKLaunchDestination) {
    TPKLaunchDestinationDefault = 0,
    TPKLaunchDestinationHomeFollowing,
    TPKLaunchDestinationHomeLive,
    TPKLaunchDestinationHomeClips,
    TPKLaunchDestinationBrowseCategories,
    TPKLaunchDestinationBrowseLiveChannels,
    TPKLaunchDestinationActivity,
    TPKLaunchDestinationProfile,
};

void tpk_registerHomeFeatureDefaults(void);

TPKLaunchDestination tpk_launchDestination(void);
void tpk_setLaunchDestination(TPKLaunchDestination destination);

// Onglet de la barre visé par une destination, -1 si aucune.
NSInteger tpk_launchDestinationTab(TPKLaunchDestination destination);

BOOL tpk_hideTwitchStoriesEnabled(void);
void tpk_setHideTwitchStoriesEnabled(BOOL enabled);

BOOL tpk_keepLiveFeedPlayingEnabled(void);
void tpk_setKeepLiveFeedPlayingEnabled(BOOL enabled);

// Installe les hooks. Watch limit : voir tpK-adblock-data.m.
void tpk_installHomeFeatureRuntimeHooks(void);

NS_ASSUME_NONNULL_END
