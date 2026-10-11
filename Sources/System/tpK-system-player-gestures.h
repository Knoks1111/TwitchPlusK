/* Player gesture settings and hooks. */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPKPlayerGestureAssignment) {
    TPKPlayerGestureAssignmentDisabled = 0,
    TPKPlayerGestureAssignmentVolume = 1,
    TPKPlayerGestureAssignmentBrightness = 2,
};

BOOL tpk_playerGesturesEnabled(void);
void tpk_setPlayerGesturesEnabled(BOOL enabled);

TPKPlayerGestureAssignment tpk_playerGesturesLeftAssignment(void);
void tpk_setPlayerGesturesLeftAssignment(
    TPKPlayerGestureAssignment assignment);

TPKPlayerGestureAssignment tpk_playerGesturesRightAssignment(void);
void tpk_setPlayerGesturesRightAssignment(
    TPKPlayerGestureAssignment assignment);

CGFloat tpk_playerGesturesSensitivity(void);
void tpk_setPlayerGesturesSensitivity(CGFloat sensitivity);

NSInteger tpk_playerGesturesDeadZone(void);
void tpk_setPlayerGesturesDeadZone(NSInteger deadZone);

// Called from UIView.didMoveToWindow.
void tpk_handlePlayerGesturesViewLifecycle(UIView *view);

// Shows the shared player HUD.
void tpk_showPlayerGestureOverlay(UIView *geometryView,
                                   NSString *text,
                                   NSString *iconName);
void tpk_showPlayerGestureOverlayWithTint(UIView *geometryView,
                                           NSString *text,
                                           NSString *iconName,
                                           UIColor *iconTintColor);

// Returns the player geometry view used by gestures.
UIView *tpk_playerGestureGeometryViewForControls(UIView *controlsView);

// Installs the UIKit hook and defaults.
void tpk_playerGesturesSetup(void);

NS_ASSUME_NONNULL_END
