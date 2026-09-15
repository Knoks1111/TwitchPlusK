/* Orientation lock button and auto-lock API. */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Orientation lock API used by the runtime hooks.

typedef NS_ENUM(NSInteger, S7TVAutoOrientationLockMode) {
    S7TVAutoOrientationLockModeDisabled = 0,
    S7TVAutoOrientationLockModeLandscapeLeft,
    S7TVAutoOrientationLockModeLandscapeRight,
    S7TVAutoOrientationLockModeBothLandscapes,
};

// Disabled by default. Disabling removes the custom button and stops auto-lock.
BOOL s7tv_orientationLockButtonEnabled(void);
void s7tv_setOrientationLockButtonEnabled(BOOL enabled);
S7TVAutoOrientationLockMode s7tv_autoOrientationLockMode(void);
void s7tv_setAutoOrientationLockMode(S7TVAutoOrientationLockMode mode);

// Current state of the custom player button.
BOOL s7tv_isOrientationLocked(void);

// Called when Twitch.TheaterPlayerControlsView enters a window.
void s7tv_handleTheaterControlsViewLifecycle(UIView *view);

// Restores the auto-lock observer at launch when enabled.
void s7tv_swizzle_orientation_lock(void);

NS_ASSUME_NONNULL_END
