/*
 * tpK-system-autoclaim.h
 *
 * Auto Claim Channel Points sur le chat RN (theater) : le watcher surveille
 * le coffre réclamable et l'active. Boucle 1 s, latch anti-double,
 * préférence persistée, logs Channel Points et état diagnostics.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const TPKAutoClaimRuntimeStateDidChangeNotification;

typedef NS_ENUM(NSInteger, TPKAutoClaimEffectiveState) {
    TPKAutoClaimEffectiveStateActive = 0,
    TPKAutoClaimEffectiveStateDisabledByUser,
};

// Snapshot read-only destiné à l'écran Diagnostics. La lecture n'effectue
// aucun claim, ne démarre ni n'arrête le watcher et n'expose aucun détail
// interne (offset, adresse, metadata ou credential).
@interface TPKAutoClaimDiagnosticsState : NSObject
@property (nonatomic, assign) BOOL rnChatHostDetected;
@property (nonatomic, assign) BOOL rnChestDetected;
@property (nonatomic, assign) BOOL rnBalanceKnown;
@property (nonatomic, assign) int64_t rnBalance;
@property (nonatomic, assign) BOOL watcherActive;
@property (nonatomic, assign) TPKAutoClaimEffectiveState effectiveState;
@end

// Installs les hooks de cycle de vie et relance l'Auto Claim pour un hôte
// RN déjà visible quand la préférence est activée.
void TPKAutoClaimSetup(void);

// Called after the existing Auto Collect preference has been persisted.
// OFF stops the active watcher immediately; ON starts it for the visible
// controller without requiring a Twitch restart.
void TPKAutoClaimSettingsDidChange(void);

// Renvoie l'état instantané utilisé par Diagnostics. L'appel est thread-safe
// et est synchronisé sur la file principale lorsque nécessaire.
TPKAutoClaimDiagnosticsState *TPKAutoClaimDiagnosticsCurrentState(void);

// Livre un touch au handler RN de la vue (même mécanisme que l'autoclaim).
// Utilisé par le masquage des bannières (toggle Masquer/Développer).
BOOL TPKRNTapView(UIView *view);

NS_ASSUME_NONNULL_END
