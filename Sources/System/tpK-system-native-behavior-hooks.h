/* Orientation lock button and auto-lock API. */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Orientation lock API used by the runtime hooks.

typedef NS_ENUM(NSInteger, TPKAutoOrientationLockMode) {
    TPKAutoOrientationLockModeDisabled = 0,
    TPKAutoOrientationLockModeLandscapeLeft,
    TPKAutoOrientationLockModeLandscapeRight,
    TPKAutoOrientationLockModeBothLandscapes,
};

// Disabled by default. Disabling removes the custom button and stops auto-lock.
BOOL tpk_orientationLockButtonEnabled(void);
void tpk_setOrientationLockButtonEnabled(BOOL enabled);
TPKAutoOrientationLockMode tpk_autoOrientationLockMode(void);
void tpk_setAutoOrientationLockMode(TPKAutoOrientationLockMode mode);

// Current state of the custom player button.
BOOL tpk_isOrientationLocked(void);

// Called when Twitch.TheaterPlayerControlsView enters a window.
void tpk_handleTheaterControlsViewLifecycle(UIView *view);

// Restores the auto-lock observer at launch when enabled.
void tpk_swizzle_orientation_lock(void);

NS_ASSUME_NONNULL_END
