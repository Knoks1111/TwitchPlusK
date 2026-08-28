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

typedef NS_ENUM(NSInteger, S7TVAutoClaimEffectiveState) {
    S7TVAutoClaimEffectiveStateActive = 0,
    S7TVAutoClaimEffectiveStateSuspendedByAdblock,
    S7TVAutoClaimEffectiveStateDisabledByUser,
};

// Snapshot read-only destiné à l'écran Diagnostics. La lecture n'effectue
// aucun claim, ne démarre ni n'arrête le watcher et n'expose aucun détail
// interne (offset, adresse, metadata ou credential).
@interface S7TVAutoClaimDiagnosticsState : NSObject
@property (nonatomic, assign) BOOL channelChatViewControllerDetected;
@property (nonatomic, assign) BOOL nativeChainResolved;
@property (nonatomic, assign) BOOL showsClaimAvailable;
@property (nonatomic, assign) BOOL claimSelectorAvailable;
@property (nonatomic, assign) BOOL balanceAvailable;
@property (nonatomic, assign) BOOL watcherActive;
@property (nonatomic, assign) S7TVAutoClaimEffectiveState effectiveState;
@end

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

// Renvoie l'état instantané utilisé par Diagnostics. L'appel est thread-safe
// et est synchronisé sur la file principale lorsque nécessaire.
S7TVAutoClaimDiagnosticsState *S7TVAutoClaimDiagnosticsCurrentState(void);

NS_ASSUME_NONNULL_END
