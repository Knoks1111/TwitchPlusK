#import <Foundation/Foundation.h>

// Installs only the AVFoundation/Twitch runtime hooks owned by the adblock
// module. NSURLSession and Apollo are integrated in tpK-core-runtime-hooks.m
// because TwitchPlusK already owns those interception points.
void TPKAdblockInstallRuntimeHooks(void);

// Backup UI scan shared with the Discovery-feed layout hook. It only acts
// when the dedicated « Hide Go Ad-Free » preference is enabled.
void TPKAdblockHideAdFreeUpsellIfNeeded(void);
