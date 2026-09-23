// Lancement, Stories, fil Live (dérivé de TwitchAdBlock, MIT).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVLaunchDestination) {
    S7TVLaunchDestinationDefault = 0,
    S7TVLaunchDestinationHomeFollowing,
    S7TVLaunchDestinationHomeLive,
    S7TVLaunchDestinationHomeClips,
    S7TVLaunchDestinationBrowseCategories,
    S7TVLaunchDestinationBrowseLiveChannels,
    S7TVLaunchDestinationActivity,
    S7TVLaunchDestinationProfile,
};

void s7tv_registerHomeFeatureDefaults(void);

S7TVLaunchDestination s7tv_launchDestination(void);
void s7tv_setLaunchDestination(S7TVLaunchDestination destination);

// Onglet de la barre visé par une destination, -1 si aucune.
NSInteger s7tv_launchDestinationTab(S7TVLaunchDestination destination);

BOOL s7tv_hideTwitchStoriesEnabled(void);
void s7tv_setHideTwitchStoriesEnabled(BOOL enabled);

BOOL s7tv_keepLiveFeedPlayingEnabled(void);
void s7tv_setKeepLiveFeedPlayingEnabled(BOOL enabled);

// Installe les hooks. Watch limit : voir 7tv-adblock-data.m.
void s7tv_installHomeFeatureRuntimeHooks(void);

NS_ASSUME_NONNULL_END
