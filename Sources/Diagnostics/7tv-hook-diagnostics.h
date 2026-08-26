/*
 * Hook diagnostics adapted from TwitchAdBlock's diagnostics registry
 * (Tweak.x / TWABSettingsVC.m, MIT). See THIRD_PARTY_NOTICES.md.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Les trois moteurs/surfaces diagnostiqués dans le même écran. L'ordre est
// volontaire : il correspond à l'ordre d'affichage dans Avancé > Diagnostics.
typedef NS_ENUM(NSInteger, S7TVHookDiagnosticGroup) {
    S7TVHookDiagnosticGroupProxyAdBlock = 0,
    S7TVHookDiagnosticGroupLocalVaftAdBlock = 1,
    S7TVHookDiagnosticGroupTwitchPlusK = 2,
};

// Registers the stable Twitch, TwitchKit and Apollo class targets used by
// TwitchAdBlock-derived and TwitchPlusK hooks. Safe to call repeatedly.
void S7TVHookDiagnosticsRegisterKnownTargets(void);

// [{ @"name": NSString, @"present": @(BOOL), @"applicable": @(BOOL),
//    @"group": @(NSInteger) }, ...].
// A descriptor may also carry a selector; in that case both the target class
// and the selector are sampled again for each call so late-loaded Twitch
// frameworks and VAFT's dynamically-created classes are reflected.
NSArray<NSDictionary<NSString *, id> *> *S7TVHookDiagnosticItems(void);

NS_ASSUME_NONNULL_END
