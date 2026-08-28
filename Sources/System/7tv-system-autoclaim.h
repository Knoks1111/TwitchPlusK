/*
 * 7tv-system-autoclaim.h
 *
 * Native Auto Claim Channel Points integration. The implementation follows
 * Twitch's live chat view hierarchy and deliberately has no dependency on
 * the network scanners used by the former implementation.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const S7TVAutoClaimRuntimeStateDidChangeNotification;

// Installs the lifecycle hooks and resumes Auto Claim for an already-visible
// ChannelChatViewController when the preference is enabled.
void S7TVAutoClaimSetup(void);

// Called after the existing Auto Collect preference has been persisted.
// OFF stops the active watcher immediately; ON starts it for the visible
// controller without requiring a Twitch restart.
void S7TVAutoClaimSettingsDidChange(void);

// YES uniquement lorsque la préférence Auto Claim est ON mais qu'un moteur
// Proxy/VAFT est réellement actif dans le processus courant.
BOOL S7TVAutoClaimIsSuspendedByAdblock(void);

NS_ASSUME_NONNULL_END
