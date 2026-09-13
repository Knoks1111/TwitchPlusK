/* Player gesture settings and hooks. */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, S7TVPlayerGestureAssignment) {
    S7TVPlayerGestureAssignmentDisabled = 0,
    S7TVPlayerGestureAssignmentVolume = 1,
    S7TVPlayerGestureAssignmentBrightness = 2,
};

BOOL s7tv_playerGesturesEnabled(void);
void s7tv_setPlayerGesturesEnabled(BOOL enabled);

S7TVPlayerGestureAssignment s7tv_playerGesturesLeftAssignment(void);
void s7tv_setPlayerGesturesLeftAssignment(
    S7TVPlayerGestureAssignment assignment);

S7TVPlayerGestureAssignment s7tv_playerGesturesRightAssignment(void);
void s7tv_setPlayerGesturesRightAssignment(
    S7TVPlayerGestureAssignment assignment);

CGFloat s7tv_playerGesturesSensitivity(void);
void s7tv_setPlayerGesturesSensitivity(CGFloat sensitivity);

NSInteger s7tv_playerGesturesDeadZone(void);
void s7tv_setPlayerGesturesDeadZone(NSInteger deadZone);

// Called from UIView.didMoveToWindow.
void s7tv_handlePlayerGesturesViewLifecycle(UIView *view);

// Shows the shared player HUD.
void s7tv_showPlayerGestureOverlay(UIView *geometryView,
                                   NSString *text,
                                   NSString *iconName);
void s7tv_showPlayerGestureOverlayWithTint(UIView *geometryView,
                                           NSString *text,
                                           NSString *iconName,
                                           UIColor *iconTintColor);

// Returns the player geometry view used by gestures.
UIView *s7tv_playerGestureGeometryViewForControls(UIView *controlsView);

// Installs the UIKit hook and defaults.
void s7tv_playerGesturesSetup(void);

NS_ASSUME_NONNULL_END
