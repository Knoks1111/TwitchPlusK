#import <Foundation/Foundation.h>

// Installs only the AVFoundation/Twitch runtime hooks owned by the adblock
// module. NSURLSession and Apollo are integrated in 7tv-core-runtime-hooks.m
// because TwitchPlusK already owns those interception points.
void S7TVAdblockInstallRuntimeHooks(void);
