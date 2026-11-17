#import <Foundation/Foundation.h>
@class UIView;

// Installs only the AVFoundation/Twitch runtime hooks owned by the adblock
// module. NSURLSession and Apollo are integrated in tpK-core-runtime-hooks.m
// because TwitchPlusK already owns those interception points.
void TPKAdblockInstallRuntimeHooks(void);

// Recherche locale par lots, regroupée lorsque le masquage Turbo est activé.
void TPKAdblockHideAdFreeUpsellIfNeeded(UIView *root);
