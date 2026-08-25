/*
 * Hook diagnostics adapted from TwitchAdBlock's diagnostics registry
 * (Tweak.x / TWABSettingsVC.m, MIT). See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Registers the stable Twitch, TwitchKit and Apollo class targets used by
// TwitchAdBlock-derived and TwitchPlusK hooks. Safe to call repeatedly.
void S7TVHookDiagnosticsRegisterKnownTargets(void);

// [{ @"name": NSString, @"present": @(BOOL) }, ...]. Class presence is
// sampled again for each call so late-loaded Twitch frameworks are reflected.
NSArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticItems(void);

NS_ASSUME_NONNULL_END
