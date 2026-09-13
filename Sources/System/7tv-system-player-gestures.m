/* Theater player gestures: brightness on one side, volume on the other. */

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <math.h>
#import "System/7tv-system-player-gestures.h"
#import "Localization/7tv-localization-manager.h"
#import "UI/7tv-oled-mode.h"

static NSString *const kS7TVPlayerControlsClass =
    @"Twitch.TheaterPlayerControlsView";
static NSString *const kS7TVPlayerTheaterViewClass =
    @"Twitch.TheaterView";
static NSString *const kS7TVPlayerDirectionalPanClass =
    @"Twitch.DirectionalPanGestureRecognizer";
static NSString *const kS7TVPlayerTheaterContainerControllerClass =
    @"Twitch.TheaterContainerViewController";
static NSString *const kS7TVPlayerVideoPositionClass =
    @"Twitch.TheaterVideoPositionView";
static NSString *const kS7TVPlayerGesturesEnabledKey =
    @"s7tv_player_gestures_enabled";
static NSString *const kS7TVPlayerGesturesSensitivityKey =
    @"s7tv_player_gestures_sensitivity";
static NSString *const kS7TVPlayerGesturesDeadZoneKey =
    @"s7tv_player_gestures_dead_zone";
static NSString *const kS7TVPlayerGesturesLeftAssignmentKey =
    @"s7tv_player_gestures_left_assignment";
static NSString *const kS7TVPlayerGesturesRightAssignmentKey =
    @"s7tv_player_gestures_right_assignment";
static NSString *const kS7TVPlayerGesturesLegacyBrightnessEnabledKey =
    @"s7tv_player_gestures_brightness_enabled";
static NSString *const kS7TVPlayerGesturesLegacyVolumeEnabledKey =
    @"s7tv_player_gestures_volume_enabled";
static NSString *const kS7TVPlayerGesturesLegacyBrightnessSideKey =
    @"s7tv_player_gestures_brightness_side";
static NSString *const kS7TVPlayerGesturesLegacyVolumeSideKey =
    @"s7tv_player_gestures_volume_side";

static const CGFloat kS7TVPlayerGesturesDefaultSensitivity = 1.0;
static const NSInteger kS7TVPlayerGesturesDefaultDeadZone = 20;
static const CGFloat kS7TVPlayerGesturesMinimumSensitivity = 1.0;
static const CGFloat kS7TVPlayerGesturesMaximumSensitivity = 5.0;
static const CGFloat kS7TVPlayerGestureVerticalTolerance = 0.75;
static const CGFloat kS7TVPlayerGestureAxisDecisionDistance = 4.0;
static const CGFloat kS7TVPlayerGestureMinimumFakeBrightness = -0.70;
static const NSInteger kS7TVPlayerGesturesMinimumDeadZone = 0;
static const NSInteger kS7TVPlayerGesturesMaximumDeadZone = 100;

static const NSUInteger kS7TVPlayerGestureMaxParentDepth = 4;
static const NSUInteger kS7TVPlayerGestureMaxSurfaceSearchDepth = 8;

static char kS7TVPlayerGestureRecognizerKey;
static char kS7TVPlayerGestureDelegateKey;
static char kS7TVPlayerGestureHandlerKey;
static char kS7TVPlayerGestureStateKey;
static char kS7TVPlayerGestureBindingKey;
static char kS7TVPlayerGestureHostKey;
static char kS7TVPlayerGestureOverlayKey;
static char kS7TVPlayerGestureFakeBrightnessOverlayKey;

static MPVolumeView *s7tv_playerGestureSystemVolumeView;
static UISlider *s7tv_playerGestureSystemVolumeSlider;
static CGFloat s7tv_playerGestureFakeBrightness = 0.0;
static __weak UIView *s7tv_playerGestureFakeBrightnessOverlayHost;

typedef NS_ENUM(NSInteger, S7TVPlayerGestureSide) {
    S7TVPlayerGestureSideUnknown = 0,
    S7TVPlayerGestureSideBrightness,
    S7TVPlayerGestureSideVolume,
};

static UIImage *s7tv_playerGestureCachedSystemImage(NSString *name) {
    if (!name.length) return nil;

    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
    });

    UIImage *image = [cache objectForKey:name];
    if (!image) {
        image = [UIImage systemImageNamed:name];
        if (image) [cache setObject:image forKey:name];
    }
    return image;
}

static Class s7tv_playerGestureControlsClass(void) {
    static Class controlsClass;
    if (!controlsClass) {
        controlsClass = NSClassFromString(kS7TVPlayerControlsClass);
    }
    return controlsClass;
}

// The rays track brightness continuously; negative values draw a moon.
@interface S7TVPlayerGestureBrightnessIconView : UIView
@property (nonatomic, assign) CGFloat brightnessValue;
@end

@implementation S7TVPlayerGestureBrightnessIconView

- (void)setBrightnessValue:(CGFloat)brightnessValue {
    _brightnessValue = MIN(1.0, MAX(-1.0, brightnessValue));
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    CGFloat size = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat value = MIN(1.0, MAX(-1.0, self.brightnessValue));
    CGFloat coreRadius = size * 0.19;
    CGFloat rayStartRadius = coreRadius + size * 0.13;
    CGFloat maxRayLength = size * 0.16;

    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, MAX(1.0, size * 0.075));
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetFillColorWithColor(context, UIColor.whiteColor.CGColor);

    if (value >= 0.0) {
        CGContextSetAlpha(context, 0.25 + (0.75 * value));
        for (NSUInteger index = 0; index < 8; index++) {
            CGFloat angle = (-(CGFloat)(M_PI * 0.5)) +
                ((CGFloat)index * (M_PI / 4.0));
            CGFloat rayLength = maxRayLength * value;
            if (rayLength <= 0.01) continue;

            CGPoint start = CGPointMake(
                center.x + cos(angle) * rayStartRadius,
                center.y + sin(angle) * rayStartRadius);
            CGPoint end = CGPointMake(
                center.x + cos(angle) * (rayStartRadius + rayLength),
                center.y + sin(angle) * (rayStartRadius + rayLength));
            CGContextMoveToPoint(context, start.x, start.y);
            CGContextAddLineToPoint(context, end.x, end.y);
            CGContextStrokePath(context);
        }
        CGContextSetAlpha(context, 1.0);
        CGContextAddArc(context, center.x, center.y, coreRadius,
                        0.0, (CGFloat)(M_PI * 2.0), 0);
        CGContextFillPath(context);
        return;
    }

    // Negative brightness turns the sun into a crescent moon.
    CGFloat moonProgress = MIN(1.0, MAX(
        0.0, -value / -kS7TVPlayerGestureMinimumFakeBrightness));
    CGContextAddArc(context, center.x, center.y, coreRadius,
                    0.0, (CGFloat)(M_PI * 2.0), 0);
    CGContextFillPath(context);

    if (moonProgress > 0.001) {
        CGContextSaveGState(context);
        CGContextSetBlendMode(context, kCGBlendModeClear);
        CGFloat cutoutRadius = coreRadius * moonProgress;
        CGPoint cutoutCenter = CGPointMake(
            center.x + (coreRadius * 0.78 * moonProgress), center.y);
        CGContextAddArc(context, cutoutCenter.x, cutoutCenter.y,
                        cutoutRadius, 0.0, (CGFloat)(M_PI * 2.0), 0);
        CGContextFillPath(context);
        CGContextRestoreGState(context);
    }
}

@end

// Shared compact player HUD.
@interface S7TVPlayerGestureOverlayView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) S7TVPlayerGestureBrightnessIconView *brightnessIconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) dispatch_source_t hideTimer;
- (void)s7tv_updateAppearance;
- (void)showText:(NSString *)text
       iconName:(NSString *)iconName
 brightnessValue:(CGFloat)brightnessValue
    isBrightness:(BOOL)isBrightness
   iconTintColor:(UIColor *)iconTintColor;
@end

@implementation S7TVPlayerGestureOverlayView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 16.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor =
        [UIColor colorWithRed:0.569 green:0.278 blue:1.0 alpha:1.0].CGColor;
    self.clipsToBounds = YES;
    self.hidden = YES;
    self.alpha = 0.0;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    [self s7tv_updateAppearance];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.tintColor = UIColor.whiteColor;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;

    self.brightnessIconView = [[S7TVPlayerGestureBrightnessIconView alloc] init];
    self.brightnessIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.brightnessIconView.hidden = YES;

    self.label = [[UILabel alloc] init];
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    self.label.textColor = UIColor.whiteColor;
    self.label.font = [UIFont boldSystemFontOfSize:13.0];
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.adjustsFontSizeToFitWidth = YES;
    self.label.minimumScaleFactor = 0.85;
    self.label.numberOfLines = 1;

    [self addSubview:self.iconView];
    [self addSubview:self.brightnessIconView];
    [self addSubview:self.label];
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                     constant:11.0],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:14.0],
        [self.iconView.heightAnchor constraintEqualToConstant:14.0],
        [self.brightnessIconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                               constant:11.0],
        [self.brightnessIconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.brightnessIconView.widthAnchor constraintEqualToConstant:14.0],
        [self.brightnessIconView.heightAnchor constraintEqualToConstant:14.0],
        [self.label.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor
                                                  constant:6.0],
        [self.label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-10.0],
        [self.label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(s7tv_oledModeDidChange:)
               name:S7TVOLEDModeDidChangeNotification
             object:nil];
    return self;
}

- (void)dealloc {
    if (self.hideTimer) dispatch_source_cancel(self.hideTimer);
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:S7TVOLEDModeDidChangeNotification object:nil];
}

- (void)s7tv_updateAppearance {
    self.backgroundColor = S7TVOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.08 alpha:1.0];
}

- (void)s7tv_oledModeDidChange:(__unused NSNotification *)note {
    if (NSThread.isMainThread) {
        [self s7tv_updateAppearance];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self s7tv_updateAppearance];
        });
    }
}

- (void)showText:(NSString *)text
       iconName:(NSString *)iconName
 brightnessValue:(CGFloat)brightnessValue
   isBrightness:(BOOL)isBrightness
   iconTintColor:(UIColor *)iconTintColor {
    if (![self.label.text isEqualToString:text]) {
        self.label.text = text;
    }
    BOOL showsBrightnessIcon = isBrightness;
    if (self.iconView.hidden != showsBrightnessIcon) {
        self.iconView.hidden = showsBrightnessIcon;
    }
    if (self.brightnessIconView.hidden != !showsBrightnessIcon) {
        self.brightnessIconView.hidden = !showsBrightnessIcon;
    }
    if (showsBrightnessIcon) {
        if (fabs(self.brightnessIconView.brightnessValue - brightnessValue) >= 0.001) {
            self.brightnessIconView.brightnessValue = brightnessValue;
        }
    } else {
        UIColor *tintColor = iconTintColor ?: UIColor.whiteColor;
        if (![self.iconView.tintColor isEqual:tintColor]) {
            self.iconView.tintColor = tintColor;
        }
        UIImage *image = s7tv_playerGestureCachedSystemImage(iconName);
        if (self.iconView.image != image) {
            self.iconView.image = image;
        }
    }

    BOOL shouldFadeIn = self.hidden || self.alpha <= 0.01;
    if (self.hidden) {
        self.hidden = NO;
        self.alpha = 0.0;
    }
    [self.layer removeAllAnimations];
    if (shouldFadeIn) {
        [UIView animateWithDuration:0.12 animations:^{
            self.alpha = 1.0;
        }];
    } else {
        [UIView performWithoutAnimation:^{
            self.alpha = 1.0;
        }];
    }

    if (!self.hideTimer) {
        self.hideTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        __weak S7TVPlayerGestureOverlayView *weakSelf = self;
        dispatch_source_set_event_handler(self.hideTimer, ^{
            S7TVPlayerGestureOverlayView *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_source_set_timer(strongSelf.hideTimer,
                                      DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            [UIView animateWithDuration:0.18 animations:^{
                strongSelf.alpha = 0.0;
            } completion:^(BOOL finished) {
                (void)finished;
                strongSelf.hidden = YES;
            }];
        });
        dispatch_resume(self.hideTimer);
    }
    dispatch_source_set_timer(self.hideTimer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(0.85 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
}

@end

@interface S7TVPlayerGestureState : NSObject
@property (nonatomic, assign) S7TVPlayerGestureSide side;
@property (nonatomic, assign) CGFloat initialVolume;
@property (nonatomic, assign) CGFloat lastVolumeValue;
@property (nonatomic, assign) CGFloat initialBrightness;
@property (nonatomic, assign) CGFloat currentBrightness;
@property (nonatomic, assign) CGFloat currentFakeBrightness;
@property (nonatomic, assign) CGFloat lastBrightnessAdjustment;
@property (nonatomic, assign) CGFloat playerHeight;
@property (nonatomic, weak) UIView *geometryView;
@property (nonatomic, assign) BOOL axisDecided;
@property (nonatomic, assign) BOOL vertical;
@property (nonatomic, assign) CGFloat sensitivity;
@property (nonatomic, assign) NSInteger deadZone;
@end

@implementation S7TVPlayerGestureState
@end

static void s7tv_playerGestureRefreshExistingViews(void);

static NSUserDefaults *s7tv_playerGestureDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static S7TVPlayerGestureAssignment
s7tv_playerGesturesLegacyAssignmentForSide(NSUserDefaults *defaults,
                                           NSInteger side) {
    BOOL brightnessEnabled = [defaults
        objectForKey:kS7TVPlayerGesturesLegacyBrightnessEnabledKey]
        ? [defaults boolForKey:kS7TVPlayerGesturesLegacyBrightnessEnabledKey]
        : YES;
    BOOL volumeEnabled = [defaults
        objectForKey:kS7TVPlayerGesturesLegacyVolumeEnabledKey]
        ? [defaults boolForKey:kS7TVPlayerGesturesLegacyVolumeEnabledKey]
        : YES;
    NSInteger brightnessSide = [defaults
        objectForKey:kS7TVPlayerGesturesLegacyBrightnessSideKey]
        ? [defaults integerForKey:kS7TVPlayerGesturesLegacyBrightnessSideKey]
        : 0;
    NSInteger volumeSide = [defaults
        objectForKey:kS7TVPlayerGesturesLegacyVolumeSideKey]
        ? [defaults integerForKey:kS7TVPlayerGesturesLegacyVolumeSideKey]
        : 1;

    if (brightnessEnabled && brightnessSide == side)
        return S7TVPlayerGestureAssignmentBrightness;
    if (volumeEnabled && volumeSide == side)
        return S7TVPlayerGestureAssignmentVolume;
    return S7TVPlayerGestureAssignmentDisabled;
}

static void s7tv_playerGesturesMigrateLegacyAssignments(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = s7tv_playerGestureDefaults();
        if ([defaults objectForKey:kS7TVPlayerGesturesLeftAssignmentKey] ||
            [defaults objectForKey:kS7TVPlayerGesturesRightAssignmentKey]) {
            return;
        }

        BOOL hasLegacySettings =
            [defaults objectForKey:kS7TVPlayerGesturesLegacyBrightnessEnabledKey] ||
            [defaults objectForKey:kS7TVPlayerGesturesLegacyVolumeEnabledKey] ||
            [defaults objectForKey:kS7TVPlayerGesturesLegacyBrightnessSideKey] ||
            [defaults objectForKey:kS7TVPlayerGesturesLegacyVolumeSideKey];
        if (!hasLegacySettings) return;

        [defaults setInteger:s7tv_playerGesturesLegacyAssignmentForSide(
            defaults, 0) forKey:kS7TVPlayerGesturesLeftAssignmentKey];
        [defaults setInteger:s7tv_playerGesturesLegacyAssignmentForSide(
            defaults, 1) forKey:kS7TVPlayerGesturesRightAssignmentKey];
        [defaults synchronize];
    });
}

static void s7tv_playerGesturesRegisterDefaults(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s7tv_playerGesturesMigrateLegacyAssignments();
        [s7tv_playerGestureDefaults() registerDefaults:@{
            kS7TVPlayerGesturesEnabledKey: @NO,
            kS7TVPlayerGesturesLeftAssignmentKey:
                @(S7TVPlayerGestureAssignmentBrightness),
            kS7TVPlayerGesturesRightAssignmentKey:
                @(S7TVPlayerGestureAssignmentVolume),
            kS7TVPlayerGesturesSensitivityKey:
                @(kS7TVPlayerGesturesDefaultSensitivity),
            kS7TVPlayerGesturesDeadZoneKey:
                @(kS7TVPlayerGesturesDefaultDeadZone),
        }];
    });
}

BOOL s7tv_playerGesturesEnabled(void) {
    s7tv_playerGesturesRegisterDefaults();
    return [s7tv_playerGestureDefaults()
        boolForKey:kS7TVPlayerGesturesEnabledKey];
}

void s7tv_setPlayerGesturesEnabled(BOOL enabled) {
    s7tv_playerGesturesRegisterDefaults();
    [s7tv_playerGestureDefaults() setBool:enabled
                                   forKey:kS7TVPlayerGesturesEnabledKey];
    [s7tv_playerGestureDefaults() synchronize];
    s7tv_playerGestureRefreshExistingViews();
}

static S7TVPlayerGestureAssignment
s7tv_playerGesturesNormalizedAssignment(NSInteger assignment) {
    if (assignment == S7TVPlayerGestureAssignmentVolume)
        return S7TVPlayerGestureAssignmentVolume;
    if (assignment == S7TVPlayerGestureAssignmentBrightness)
        return S7TVPlayerGestureAssignmentBrightness;
    return S7TVPlayerGestureAssignmentDisabled;
}

S7TVPlayerGestureAssignment s7tv_playerGesturesLeftAssignment(void) {
    s7tv_playerGesturesRegisterDefaults();
    return s7tv_playerGesturesNormalizedAssignment([s7tv_playerGestureDefaults()
        integerForKey:kS7TVPlayerGesturesLeftAssignmentKey]);
}

void s7tv_setPlayerGesturesLeftAssignment(
    S7TVPlayerGestureAssignment assignment) {
    s7tv_playerGesturesRegisterDefaults();
    assignment = s7tv_playerGesturesNormalizedAssignment(assignment);
    [s7tv_playerGestureDefaults() setInteger:assignment
                                      forKey:kS7TVPlayerGesturesLeftAssignmentKey];
    [s7tv_playerGestureDefaults() synchronize];
}

S7TVPlayerGestureAssignment s7tv_playerGesturesRightAssignment(void) {
    s7tv_playerGesturesRegisterDefaults();
    return s7tv_playerGesturesNormalizedAssignment([s7tv_playerGestureDefaults()
        integerForKey:kS7TVPlayerGesturesRightAssignmentKey]);
}

void s7tv_setPlayerGesturesRightAssignment(
    S7TVPlayerGestureAssignment assignment) {
    s7tv_playerGesturesRegisterDefaults();
    assignment = s7tv_playerGesturesNormalizedAssignment(assignment);
    [s7tv_playerGestureDefaults() setInteger:assignment
                                      forKey:kS7TVPlayerGesturesRightAssignmentKey];
    [s7tv_playerGestureDefaults() synchronize];
}

CGFloat s7tv_playerGesturesSensitivity(void) {
    s7tv_playerGesturesRegisterDefaults();
    CGFloat value = [s7tv_playerGestureDefaults()
        floatForKey:kS7TVPlayerGesturesSensitivityKey];
    return MIN(kS7TVPlayerGesturesMaximumSensitivity,
               MAX(kS7TVPlayerGesturesMinimumSensitivity, value));
}

void s7tv_setPlayerGesturesSensitivity(CGFloat sensitivity) {
    s7tv_playerGesturesRegisterDefaults();
    sensitivity = MIN(kS7TVPlayerGesturesMaximumSensitivity,
                       MAX(kS7TVPlayerGesturesMinimumSensitivity,
                           sensitivity));
    [s7tv_playerGestureDefaults() setFloat:(float)sensitivity
                                    forKey:kS7TVPlayerGesturesSensitivityKey];
    [s7tv_playerGestureDefaults() synchronize];
}

NSInteger s7tv_playerGesturesDeadZone(void) {
    s7tv_playerGesturesRegisterDefaults();
    NSInteger value = [s7tv_playerGestureDefaults()
        integerForKey:kS7TVPlayerGesturesDeadZoneKey];
    return MIN(kS7TVPlayerGesturesMaximumDeadZone,
               MAX(kS7TVPlayerGesturesMinimumDeadZone, value));
}

void s7tv_setPlayerGesturesDeadZone(NSInteger deadZone) {
    s7tv_playerGesturesRegisterDefaults();
    deadZone = MIN(kS7TVPlayerGesturesMaximumDeadZone,
                   MAX(kS7TVPlayerGesturesMinimumDeadZone, deadZone));
    [s7tv_playerGestureDefaults() setInteger:deadZone
                                      forKey:kS7TVPlayerGesturesDeadZoneKey];
    [s7tv_playerGestureDefaults() synchronize];
}

static void s7tv_playerGestureInstallRecognizer(UIView *view,
                                                UIView *geometryView);
static void s7tv_playerGestureRemoveRecognizer(UIView *view);

@interface S7TVPlayerGestureBinding : NSObject
@property (nonatomic, weak) UIView *geometryView;
@end

@implementation S7TVPlayerGestureBinding
@end

static BOOL s7tv_playerGestureIsControlsView(UIView *view);

static UIView *s7tv_playerGestureOverlayHostForGeometryView(
    UIView *geometryView) {
    if (!geometryView) return nil;

    // Use the window so dimming covers the app and the HUD stays above it.
    return geometryView.window;
}

static void s7tv_playerGestureUpdateFakeBrightnessOverlay(
    UIView *geometryView) {
    if (!geometryView || !geometryView.window) return;

    UIView *overlayHost =
        s7tv_playerGestureOverlayHostForGeometryView(geometryView);
    if (!overlayHost) return;

    UIView *previousHost = s7tv_playerGestureFakeBrightnessOverlayHost;
    if (previousHost && previousHost != overlayHost) {
        UIView *previousOverlay = objc_getAssociatedObject(
            previousHost, &kS7TVPlayerGestureFakeBrightnessOverlayKey);
        previousOverlay.hidden = YES;
        previousOverlay.alpha = 0.0;
    }
    s7tv_playerGestureFakeBrightnessOverlayHost = overlayHost;

    UIView *fakeOverlay = objc_getAssociatedObject(
        overlayHost, &kS7TVPlayerGestureFakeBrightnessOverlayKey);
    if (!fakeOverlay) {
        fakeOverlay = [[UIView alloc] initWithFrame:CGRectZero];
        fakeOverlay.backgroundColor = UIColor.blackColor;
        fakeOverlay.userInteractionEnabled = NO;
        fakeOverlay.accessibilityElementsHidden = YES;
        fakeOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        fakeOverlay.layer.zPosition = 999.0;
        [overlayHost addSubview:fakeOverlay];
        objc_setAssociatedObject(overlayHost,
                                 &kS7TVPlayerGestureFakeBrightnessOverlayKey,
                                 fakeOverlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Fake brightness covers the whole app window.
    CGRect hostBounds = overlayHost.bounds;
    if (!CGRectEqualToRect(fakeOverlay.frame, hostBounds)) {
        fakeOverlay.frame = hostBounds;
    }

    CGFloat opacity = MIN(0.70,
                          MAX(0.0, -s7tv_playerGestureFakeBrightness));
    BOOL hidden = opacity <= 0.001;
    if (fakeOverlay.hidden != hidden) fakeOverlay.hidden = hidden;
    if (fabs(fakeOverlay.alpha - opacity) >= 0.001) {
        [UIView performWithoutAnimation:^{
            fakeOverlay.alpha = opacity;
        }];
    }
}

static void s7tv_playerGestureResetFakeBrightness(void) {
    s7tv_playerGestureFakeBrightness = 0.0;
    UIView *host = s7tv_playerGestureFakeBrightnessOverlayHost;
    UIView *overlay = objc_getAssociatedObject(
        host, &kS7TVPlayerGestureFakeBrightnessOverlayKey);
    overlay.hidden = YES;
    overlay.alpha = 0.0;
    s7tv_playerGestureFakeBrightnessOverlayHost = nil;
}

static void s7tv_playerGestureRegisterFakeBrightnessReset(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        s7tv_playerGestureResetFakeBrightness();
                    }];
    });
}

static S7TVPlayerGestureOverlayView *s7tv_playerGesturePrepareOverlay(
    UIView *geometryView,
    BOOL bottomAligned) {
    if (!geometryView) return nil;
    UIWindow *window = geometryView.window;
    if (!window) return nil;

    UIView *overlayHost =
        s7tv_playerGestureOverlayHostForGeometryView(geometryView);
    if (!overlayHost) return nil;

    S7TVPlayerGestureOverlayView *overlay = objc_getAssociatedObject(
        overlayHost, &kS7TVPlayerGestureOverlayKey);
    if (!overlay) {
        overlay = [[S7TVPlayerGestureOverlayView alloc] init];
        overlay.translatesAutoresizingMaskIntoConstraints = YES;
        overlay.layer.zPosition = 1000.0;
        [overlayHost addSubview:overlay];
        objc_setAssociatedObject(overlayHost, &kS7TVPlayerGestureOverlayKey,
                                 overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGRect geometryRect = [geometryView convertRect:geometryView.bounds
                                             toView:overlayHost];
    CGFloat overlayWidth = 156.0;
    CGFloat overlayHeight = 32.0;
    CGFloat overlayX = CGRectGetMidX(geometryRect) - (overlayWidth * 0.5);
    CGFloat overlayY = bottomAligned
        ? CGRectGetMaxY(geometryRect) - overlayHeight - 8.0
        : CGRectGetMinY(geometryRect) + 8.0;
    if (!isfinite(overlayX) || !isfinite(overlayY)) return nil;
    CGRect frame = CGRectMake(overlayX, overlayY,
                              overlayWidth, overlayHeight);
    if (!CGRectEqualToRect(overlay.frame, frame)) {
        overlay.frame = frame;
    }
    if (overlayHost.subviews.lastObject != overlay) {
        [overlayHost bringSubviewToFront:overlay];
    }
    return overlay;
}

static void s7tv_playerGestureShowOverlayAtPosition(
    UIView *geometryView,
    S7TVPlayerGestureSide side,
    CGFloat value,
    BOOL bottomAligned) {
    if (!geometryView || side == S7TVPlayerGestureSideUnknown) return;
    s7tv_playerGestureUpdateFakeBrightnessOverlay(geometryView);

    S7TVPlayerGestureOverlayView *overlay =
        s7tv_playerGesturePrepareOverlay(geometryView, bottomAligned);
    if (!overlay) return;

    NSString *formatKey = side == S7TVPlayerGestureSideBrightness
        ? @"player_gestures_brightness_format"
        : @"player_gestures_volume_format";
    NSString *iconName = nil;
    CGFloat brightnessValue = 0.0;
    BOOL isBrightness = side == S7TVPlayerGestureSideBrightness;
    if (side == S7TVPlayerGestureSideBrightness) {
        brightnessValue = value;
    } else if (value <= 0.001) {
        iconName = @"speaker.slash.fill";
    } else if (value < 0.34) {
        iconName = @"speaker.wave.1.fill";
    } else if (value < 0.67) {
        iconName = @"speaker.wave.2.fill";
    } else {
        iconName = @"speaker.wave.3.fill";
    }
    CGFloat displayedValue = value;
    if (side == S7TVPlayerGestureSideBrightness &&
        s7tv_playerGestureFakeBrightness < -0.001) {
        displayedValue = s7tv_playerGestureFakeBrightness;
        brightnessValue = displayedValue;
    }
    CGFloat minimumDisplayedValue = side == S7TVPlayerGestureSideBrightness
        ? kS7TVPlayerGestureMinimumFakeBrightness : 0.0;
    NSString *text = [NSString stringWithFormat:L(formatKey),
                      (double)(MIN(1.0, MAX(minimumDisplayedValue,
                                             displayedValue)) * 100.0)];
    [overlay showText:text
            iconName:iconName
      brightnessValue:brightnessValue
         isBrightness:isBrightness
        iconTintColor:UIColor.whiteColor];
}

static void s7tv_playerGestureShowOverlay(UIView *geometryView,
                                          S7TVPlayerGestureSide side,
                                          CGFloat value) {
    s7tv_playerGestureShowOverlayAtPosition(geometryView, side, value, NO);
}

void s7tv_showPlayerGestureOverlay(UIView *geometryView,
                                   NSString *text,
                                   NSString *iconName) {
    s7tv_showPlayerGestureOverlayWithTint(geometryView, text, iconName,
                                          UIColor.whiteColor);
}

void s7tv_showPlayerGestureOverlayWithTint(UIView *geometryView,
                                           NSString *text,
                                           NSString *iconName,
                                           UIColor *iconTintColor) {
    if (!geometryView || !text.length || !iconName.length) return;

    UIWindow *window = geometryView.window;
    if (!window) return;

    s7tv_playerGestureUpdateFakeBrightnessOverlay(geometryView);

    S7TVPlayerGestureOverlayView *overlay =
        s7tv_playerGesturePrepareOverlay(geometryView, YES);
    if (!overlay) return;

    [overlay showText:text
            iconName:iconName
      brightnessValue:0.0
         isBrightness:NO
        iconTintColor:iconTintColor ?: UIColor.whiteColor];
}

static UISlider *s7tv_playerGestureFindSlider(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"MPVolumeSlider"])
        return (UISlider *)view;
    if ([view isKindOfClass:UISlider.class]) return (UISlider *)view;
    for (UIView *subview in view.subviews) {
        UISlider *slider = s7tv_playerGestureFindSlider(subview);
        if (slider) return slider;
    }
    return nil;
}

static UISlider *s7tv_playerGestureVolumeSlider(UIWindow *window) {
    if (!window) return nil;

    if (!s7tv_playerGestureSystemVolumeView) {
        s7tv_playerGestureSystemVolumeView = [[MPVolumeView alloc] initWithFrame:
            CGRectMake(-120.0, -32.0, 120.0, 32.0)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        s7tv_playerGestureSystemVolumeView.showsRouteButton = NO;
#pragma clang diagnostic pop
        s7tv_playerGestureSystemVolumeView.showsVolumeSlider = YES;
        s7tv_playerGestureSystemVolumeView.alpha = 0.01;
        s7tv_playerGestureSystemVolumeView.userInteractionEnabled = NO;
        s7tv_playerGestureSystemVolumeView.accessibilityElementsHidden = YES;
    }
    if (s7tv_playerGestureSystemVolumeView.superview != window) {
        [s7tv_playerGestureSystemVolumeView removeFromSuperview];
        [window addSubview:s7tv_playerGestureSystemVolumeView];
        [s7tv_playerGestureSystemVolumeView setNeedsLayout];
        [s7tv_playerGestureSystemVolumeView layoutIfNeeded];
        s7tv_playerGestureSystemVolumeSlider = nil;
    }
    if (!s7tv_playerGestureSystemVolumeSlider ||
        !s7tv_playerGestureSystemVolumeSlider.superview) {
        s7tv_playerGestureSystemVolumeSlider =
            s7tv_playerGestureFindSlider(s7tv_playerGestureSystemVolumeView);
    }
    return s7tv_playerGestureSystemVolumeSlider;
}

static NSUInteger s7tv_playerGestureVolumeDetachGeneration;

static void s7tv_playerGestureCancelVolumeDetach(void) {
    s7tv_playerGestureVolumeDetachGeneration += 1;
}

static void s7tv_playerGestureDetachVolumeView(void) {
    [s7tv_playerGestureSystemVolumeView removeFromSuperview];
    s7tv_playerGestureSystemVolumeSlider = nil;
}

static void s7tv_playerGestureScheduleVolumeDetach(void) {
    NSUInteger generation = ++s7tv_playerGestureVolumeDetachGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != s7tv_playerGestureVolumeDetachGeneration) return;
        s7tv_playerGestureDetachVolumeView();
    });
}

static void s7tv_playerGestureSetSystemVolume(CGFloat value, UIWindow *window) {
    s7tv_playerGestureCancelVolumeDetach();
    UISlider *slider = s7tv_playerGestureVolumeSlider(window);
    value = MIN(1.0, MAX(0.0, value));
    if (!slider) {
        // MPVolumeView may create its slider on the next run loop.
        NSUInteger generation = s7tv_playerGestureVolumeDetachGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != s7tv_playerGestureVolumeDetachGeneration) return;
            UISlider *retrySlider = s7tv_playerGestureVolumeSlider(window);
            if (!retrySlider) return;
            [retrySlider setValue:(float)value animated:NO];
            [retrySlider sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
        return;
    }
    [slider setValue:(float)value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// Sensitivity is also the visible percentage step.
static CGFloat s7tv_playerGestureValueForDistance(CGFloat initialValue,
                                                  CGFloat signedDistance,
                                                  CGFloat playerHeight,
                                                  CGFloat sensitivity) {
    CGFloat rawValue = initialValue +
        ((signedDistance / MAX(1.0, playerHeight)) * sensitivity);
    CGFloat step = sensitivity / 100.0;
    CGFloat steppedValue = initialValue +
        (round((rawValue - initialValue) / step) * step);
    return MIN(1.0, MAX(0.0, steppedValue));
}

static S7TVPlayerGestureSide
s7tv_playerGestureSideForOrigin(UIView *geometryView, CGPoint origin) {
    if (!geometryView) return S7TVPlayerGestureSideUnknown;

    BOOL isLeft = origin.x < CGRectGetMidX(geometryView.bounds);
    S7TVPlayerGestureAssignment assignment = isLeft
        ? s7tv_playerGesturesLeftAssignment()
        : s7tv_playerGesturesRightAssignment();
    switch (assignment) {
        case S7TVPlayerGestureAssignmentBrightness:
            return S7TVPlayerGestureSideBrightness;
        case S7TVPlayerGestureAssignmentVolume:
            return S7TVPlayerGestureSideVolume;
        case S7TVPlayerGestureAssignmentDisabled:
        default:
            return S7TVPlayerGestureSideUnknown;
    }
}

static BOOL s7tv_playerGestureIsControlsView(UIView *view);

static BOOL s7tv_playerGestureIsVideoPositionView(UIView *view) {
    return view &&
        [NSStringFromClass(view.class) isEqualToString:kS7TVPlayerVideoPositionClass];
}

static BOOL s7tv_playerGestureIsDockPan(UIGestureRecognizer *recognizer) {
    if (!recognizer ||
        ![recognizer isKindOfClass:UIPanGestureRecognizer.class]) {
        return NO;
    }

    NSString *recognizerClass = NSStringFromClass(recognizer.class);
    if ([recognizerClass isEqualToString:kS7TVPlayerDirectionalPanClass] ||
        [recognizerClass hasSuffix:@".DirectionalPanGestureRecognizer"] ||
        [recognizerClass hasSuffix:@"DirectionalPanGestureRecognizer"]) {
        return YES;
    }

    // Some versions expose the dock gesture only as a UIPanGestureRecognizer.
    UIView *view = recognizer.view;
    if (s7tv_playerGestureIsControlsView(view)) return YES;

    if ([NSStringFromClass(view.nextResponder.class)
            isEqualToString:kS7TVPlayerTheaterContainerControllerClass]) {
        return YES;
    }
    return NO;
}

static BOOL s7tv_playerGestureIsNativeOverlayGesture(
    UIGestureRecognizer *recognizer) {
    if (!recognizer ||
        [recognizer isKindOfClass:UIHoverGestureRecognizer.class]) {
        return NO;
    }

    // Twitch uses a tap for the controls overlay and a pan for dock/PIP.
    return s7tv_playerGestureIsDockPan(recognizer) ||
        [recognizer isKindOfClass:UITapGestureRecognizer.class];
}

static BOOL s7tv_playerGestureTouchIsBlocked(UIView *view, UIView *surface) {
    UIView *candidate = view;
    while (candidate) {
        if (s7tv_playerGestureIsVideoPositionView(candidate) ||
            [candidate isKindOfClass:UIControl.class]) {
            return YES;
        }
        if (candidate == surface) break;
        candidate = candidate.superview;
    }
    return NO;
}

static BOOL s7tv_playerGestureTouchIsInsideVideo(UITouch *touch,
                                                 UIView *geometryView,
                                                 UIView *surface) {
    if (!touch || !geometryView || !surface) return NO;

    CGRect geometryRect = [geometryView convertRect:geometryView.bounds
                                             toView:surface];
    if (CGRectIsEmpty(geometryRect) ||
        CGRectGetWidth(geometryRect) < 1.0 ||
        CGRectGetHeight(geometryRect) < 1.0) {
        // Keep the recognizer during zero-size layout transitions.
        return YES;
    }
    return CGRectContainsPoint(geometryRect, [touch locationInView:surface]);
}

@interface S7TVPlayerVerticalPanGestureRecognizer : UIPanGestureRecognizer
@property (nonatomic, assign) CGPoint s7tv_startLocation;
@property (nonatomic, assign) BOOL s7tv_axisDecided;
@end

@implementation S7TVPlayerVerticalPanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) self.s7tv_startLocation = [touch locationInView:self.view];
    self.s7tv_axisDecided = NO;
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible &&
        !self.s7tv_axisDecided) {
        UITouch *touch = touches.anyObject;
        CGPoint current = [touch locationInView:self.view];
        CGFloat dx = current.x - self.s7tv_startLocation.x;
        CGFloat dy = current.y - self.s7tv_startLocation.y;
        CGFloat horizontal = fabs(dx);
        CGFloat vertical = fabs(dy);

        if (hypot(horizontal, vertical) >=
            kS7TVPlayerGestureAxisDecisionDistance) {
            if (vertical < (horizontal * kS7TVPlayerGestureVerticalTolerance)) {
                self.state = UIGestureRecognizerStateFailed;
                return;
            }
            self.s7tv_axisDecided = YES;
        }
    }

    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches
           withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.s7tv_axisDecided = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches
               withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.s7tv_axisDecided = NO;
}

@end

@interface S7TVPlayerGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation S7TVPlayerGestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (!s7tv_playerGesturesEnabled()) return NO;
    UIView *surface = gestureRecognizer.view;
    if (!surface || s7tv_playerGestureTouchIsBlocked(touch.view, surface))
        return NO;

    S7TVPlayerGestureBinding *binding = objc_getAssociatedObject(
        gestureRecognizer, &kS7TVPlayerGestureBindingKey);
    UIView *geometryView = binding.geometryView ?: surface;
    if (!s7tv_playerGestureTouchIsInsideVideo(touch, geometryView, surface))
        return NO;

    CGPoint location = [touch locationInView:geometryView];
    return s7tv_playerGestureSideForOrigin(geometryView, location) !=
        S7TVPlayerGestureSideUnknown;
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)gestureRecognizer {
    if (!s7tv_playerGesturesEnabled()) return NO;

    S7TVPlayerGestureBinding *binding = objc_getAssociatedObject(
        gestureRecognizer, &kS7TVPlayerGestureBindingKey);
    UIView *geometryView = binding.geometryView ?: gestureRecognizer.view;
    CGPoint location = [gestureRecognizer locationInView:geometryView];
    return s7tv_playerGestureSideForOrigin(geometryView, location) !=
        S7TVPlayerGestureSideUnknown;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (gestureRecognizer == other) return NO;
    if (s7tv_playerGestureIsNativeOverlayGesture(other) ||
        s7tv_playerGestureIsVideoPositionView(other.view)) {
        return NO;
    }
    // Keep taps and pinch independent; native pans are handled below.
    return YES;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // Native dock pans wait for our vertical decision.
    return s7tv_playerGestureIsNativeOverlayGesture(other);
}

@end

@interface S7TVPlayerGestureHandler : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)gestureRecognizer;
@end

@implementation S7TVPlayerGestureHandler

- (void)handlePan:(UIPanGestureRecognizer *)gestureRecognizer {
    UIView *surface = gestureRecognizer.view;
    if (!surface) return;

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        S7TVPlayerGestureState *state = [S7TVPlayerGestureState new];
        S7TVPlayerGestureBinding *binding = objc_getAssociatedObject(
            gestureRecognizer, &kS7TVPlayerGestureBindingKey);
        UIView *geometryView = binding.geometryView ?: surface;
        state.geometryView = geometryView;
        CGPoint origin = [gestureRecognizer locationInView:geometryView];
        state.initialVolume = AVAudioSession.sharedInstance.outputVolume;
        state.initialBrightness = UIScreen.mainScreen.brightness;
        state.currentBrightness = state.initialBrightness;
        state.currentFakeBrightness = s7tv_playerGestureFakeBrightness;
        state.lastBrightnessAdjustment = 0.0;
        state.side = s7tv_playerGestureSideForOrigin(geometryView, origin);
        state.playerHeight = MAX(1.0, CGRectGetHeight(geometryView.bounds));
        // Cache settings for the duration of this gesture.
        state.sensitivity = s7tv_playerGesturesSensitivity();
        state.deadZone = s7tv_playerGesturesDeadZone();
        if (state.side == S7TVPlayerGestureSideVolume) {
            // Prepare the volume slider before movement.
            s7tv_playerGestureCancelVolumeDetach();
            UISlider *slider = s7tv_playerGestureVolumeSlider(surface.window);
            if (slider) state.initialVolume = slider.value;
            state.lastVolumeValue = state.initialVolume;
        }
        objc_setAssociatedObject(gestureRecognizer, &kS7TVPlayerGestureStateKey,
                                 state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    S7TVPlayerGestureState *state = objc_getAssociatedObject(
        gestureRecognizer, &kS7TVPlayerGestureStateKey);
    if (!state) return;

    if (gestureRecognizer.state == UIGestureRecognizerStateChanged) {
        UIView *geometryView = state.geometryView ?: surface;
        CGPoint translation = [gestureRecognizer translationInView:geometryView];
        CGFloat verticalDistance = fabs(translation.y);
        CGFloat horizontalDistance = fabs(translation.x);
        CGFloat deadZone = state.playerHeight *
            ((CGFloat)state.deadZone / 100.0);

        if (!state.axisDecided) {
            CGFloat directionThreshold = MAX(deadZone, 4.0);
            if (MAX(verticalDistance, horizontalDistance) < directionThreshold)
                return;
            state.axisDecided = YES;
            // Accept a slightly diagonal start when vertical movement dominates.
            state.vertical = verticalDistance > 0.0 &&
                verticalDistance >=
                    (horizontalDistance * kS7TVPlayerGestureVerticalTolerance);
        }
        if (!state.vertical || verticalDistance <= deadZone) return;

        CGFloat effectiveDistance = verticalDistance - deadZone;
        CGFloat signedDistance = translation.y < 0.0
            ? effectiveDistance : -effectiveDistance;
        CGFloat value;
        if (state.side == S7TVPlayerGestureSideBrightness) {
            CGFloat adjustment =
                (signedDistance / MAX(1.0, state.playerHeight)) *
                state.sensitivity;
            CGFloat delta = adjustment - state.lastBrightnessAdjustment;
            state.lastBrightnessAdjustment = adjustment;

            CGFloat systemValue = state.currentBrightness;
            CGFloat fakeValue = state.currentFakeBrightness;
            if (delta > 0.0) {
                // Remove fake dimming before raising system brightness.
                CGFloat fakeIncrease = MIN(delta, -fakeValue);
                fakeValue += fakeIncrease;
                systemValue = MIN(1.0, systemValue + (delta - fakeIncrease));
            } else if (delta < 0.0) {
                // Lower system brightness before applying fake dimming.
                CGFloat decrease = -delta;
                CGFloat systemDecrease = MIN(decrease, systemValue);
                systemValue -= systemDecrease;
                decrease -= systemDecrease;
                fakeValue = MAX(kS7TVPlayerGestureMinimumFakeBrightness,
                                fakeValue - decrease);
            }

            systemValue = MIN(1.0, MAX(0.0, systemValue));
            fakeValue = MIN(0.0, MAX(
                kS7TVPlayerGestureMinimumFakeBrightness, fakeValue));
            BOOL systemChanged =
                fabs(state.currentBrightness - systemValue) >= 0.001;
            BOOL fakeChanged =
                fabs(state.currentFakeBrightness - fakeValue) >= 0.001;
            if (!systemChanged && !fakeChanged) return;

            state.currentBrightness = systemValue;
            state.currentFakeBrightness = fakeValue;
            s7tv_playerGestureFakeBrightness = fakeValue;
            if (systemChanged) UIScreen.mainScreen.brightness = systemValue;
            s7tv_playerGestureUpdateFakeBrightnessOverlay(geometryView);
            value = systemValue;
        } else if (state.side == S7TVPlayerGestureSideVolume) {
            value = s7tv_playerGestureValueForDistance(
                state.initialVolume, signedDistance, state.playerHeight,
                state.sensitivity);
            // Compare with the target because iOS updates outputVolume later.
            if (fabs(state.lastVolumeValue - value) < 0.001)
                return;
            s7tv_playerGestureSetSystemVolume(value, surface.window);
            state.lastVolumeValue = value;
        } else {
            return;
        }
        s7tv_playerGestureShowOverlay(geometryView, state.side, value);
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded ||
        gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
        gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        // Keep the volume view briefly, then restore the native HUD.
        s7tv_playerGestureScheduleVolumeDetach();
        objc_setAssociatedObject(gestureRecognizer,
                                 &kS7TVPlayerGestureStateKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end

static void s7tv_playerGestureRequireDockGestureToFail(
    UIPanGestureRecognizer *gestureRecognizer,
    UIView *view,
    NSUInteger depth) {
    if (!gestureRecognizer || !view ||
        depth > kS7TVPlayerGestureMaxSurfaceSearchDepth) return;

    for (UIGestureRecognizer *other in view.gestureRecognizers) {
        if (other == gestureRecognizer ||
            !s7tv_playerGestureIsNativeOverlayGesture(other)) continue;
        // Native dock gestures wait for ours, preventing accidental PIP.
        [other requireGestureRecognizerToFail:gestureRecognizer];
    }

    for (UIView *subview in view.subviews) {
        s7tv_playerGestureRequireDockGestureToFail(
            gestureRecognizer, subview, depth + 1);
    }
}

static void s7tv_playerGesturePrioritizeDockGesture(
    UIPanGestureRecognizer *gestureRecognizer,
    UIView *view) {
    if (!gestureRecognizer || !view) return;

    // Search both descendants and ancestors for Twitch's dock pan.
    s7tv_playerGestureRequireDockGestureToFail(
        gestureRecognizer, view, 0);
    UIView *ancestor = view.superview;
    for (NSUInteger depth = 0;
         ancestor && depth <= kS7TVPlayerGestureMaxParentDepth;
        depth++, ancestor = ancestor.superview) {
        for (UIGestureRecognizer *other in ancestor.gestureRecognizers) {
            if (other == gestureRecognizer ||
                !s7tv_playerGestureIsNativeOverlayGesture(other)) continue;
            [other requireGestureRecognizerToFail:gestureRecognizer];
        }
    }
}

static void s7tv_playerGestureInstallRecognizer(UIView *view,
                                                UIView *geometryView) {
    if (!view || !s7tv_playerGesturesEnabled()) return;

    UIPanGestureRecognizer *existing = objc_getAssociatedObject(
        view, &kS7TVPlayerGestureRecognizerKey);
    if (existing) {
        S7TVPlayerGestureBinding *binding = objc_getAssociatedObject(
            existing, &kS7TVPlayerGestureBindingKey);
        if (!binding) {
            binding = [S7TVPlayerGestureBinding new];
            objc_setAssociatedObject(existing, &kS7TVPlayerGestureBindingKey,
                                     binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        binding.geometryView = geometryView;
        existing.enabled = YES;
        existing.cancelsTouchesInView = YES;
        existing.delaysTouchesBegan = YES;
        existing.delaysTouchesEnded = YES;
        s7tv_playerGesturePrioritizeDockGesture(existing, view);
        if (geometryView != view) {
            s7tv_playerGesturePrioritizeDockGesture(existing, geometryView);
        }
        return;
    }

    S7TVPlayerGestureDelegate *delegate = [S7TVPlayerGestureDelegate new];
    S7TVPlayerGestureHandler *handler = [S7TVPlayerGestureHandler new];
    S7TVPlayerGestureBinding *binding = [S7TVPlayerGestureBinding new];
    binding.geometryView = geometryView;
    UIPanGestureRecognizer *recognizer =
        [[S7TVPlayerVerticalPanGestureRecognizer alloc]
        initWithTarget:handler action:@selector(handlePan:)];
    recognizer.delegate = delegate;
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesBegan = YES;
    recognizer.delaysTouchesEnded = YES;
    recognizer.minimumNumberOfTouches = 1;
    recognizer.maximumNumberOfTouches = 1;
    [view addGestureRecognizer:recognizer];

    objc_setAssociatedObject(view, &kS7TVPlayerGestureRecognizerKey,
                             recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kS7TVPlayerGestureDelegateKey,
                             delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kS7TVPlayerGestureHandlerKey,
                             handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kS7TVPlayerGestureBindingKey,
                             binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    s7tv_playerGesturePrioritizeDockGesture(recognizer, view);
    if (geometryView != view) {
        s7tv_playerGesturePrioritizeDockGesture(recognizer, geometryView);
    }
}

static void s7tv_playerGestureRemoveRecognizer(UIView *view) {
    s7tv_playerGestureCancelVolumeDetach();
    s7tv_playerGestureDetachVolumeView();
    UIPanGestureRecognizer *recognizer = objc_getAssociatedObject(
        view, &kS7TVPlayerGestureRecognizerKey);
    if (!recognizer) return;
    recognizer.enabled = NO;
    [view removeGestureRecognizer:recognizer];
    objc_setAssociatedObject(view, &kS7TVPlayerGestureRecognizerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL s7tv_playerGestureIsControlsView(UIView *view) {
    Class controlsClass = s7tv_playerGestureControlsClass();
    return view && controlsClass && view.class == controlsClass;
}

static UIView *s7tv_playerGestureHostForControlsView(UIView *controlsView) {
    if (!controlsView) return nil;

    UIView *theaterView = nil;
    UIView *candidate = controlsView.superview;
    for (NSUInteger depth = 0;
         candidate && depth <= kS7TVPlayerGestureMaxParentDepth + 4;
         depth++, candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                isEqualToString:kS7TVPlayerTheaterViewClass]) {
            theaterView = candidate;
            break;
        }
    }

    // TheaterView is the stable video ancestor; avoid the controls overlay.
    if (theaterView && CGRectGetWidth(theaterView.bounds) > 0.0 &&
        CGRectGetHeight(theaterView.bounds) > 0.0) {
        return theaterView;
    }

    // During transitions, use the first usable ancestor.
    candidate = theaterView ? theaterView.superview : controlsView.superview;
    for (NSUInteger depth = 0;
         candidate && depth <= kS7TVPlayerGestureMaxParentDepth + 4;
         depth++, candidate = candidate.superview) {
        if (s7tv_playerGestureIsControlsView(candidate)) continue;
        if (CGRectGetWidth(candidate.bounds) > 0.0 &&
            CGRectGetHeight(candidate.bounds) > 0.0 &&
            candidate.window) {
            return candidate;
        }
    }

    return theaterView ?: controlsView.superview ?: controlsView;
}

static UIView *s7tv_playerGestureGeometryForControlsView(UIView *controlsView,
                                                         UIView *host) {
    if (controlsView && CGRectGetWidth(controlsView.bounds) > 0.0 &&
        CGRectGetHeight(controlsView.bounds) > 0.0) {
        return controlsView;
    }
    if (host && CGRectGetWidth(host.bounds) > 0.0 &&
        CGRectGetHeight(host.bounds) > 0.0) {
        return host;
    }
    return controlsView ?: host;
}

UIView *s7tv_playerGestureGeometryViewForControls(UIView *controlsView) {
    if (!controlsView) return nil;
    UIView *host = s7tv_playerGestureHostForControlsView(controlsView);
    return s7tv_playerGestureGeometryForControlsView(controlsView, host);
}

void s7tv_handlePlayerGesturesViewLifecycle(UIView *view) {
    if (!view || !s7tv_playerGestureIsControlsView(view) || !view.window) return;

    UIView *host = s7tv_playerGestureHostForControlsView(view);
    UIView *previousHost = objc_getAssociatedObject(
        view, &kS7TVPlayerGestureHostKey);
    if (previousHost && previousHost != host) {
        s7tv_playerGestureRemoveRecognizer(previousHost);
    }
    objc_setAssociatedObject(view, &kS7TVPlayerGestureHostKey, host,
                             OBJC_ASSOCIATION_ASSIGN);

    UIView *geometryView = s7tv_playerGestureGeometryForControlsView(view, host);
    if (s7tv_playerGesturesEnabled()) {
        s7tv_playerGestureInstallRecognizer(host, geometryView);
    } else {
        s7tv_playerGestureRemoveRecognizer(host);
    }
}

static void s7tv_playerGestureVisitView(UIView *view) {
    if (!view) return;
    if (s7tv_playerGestureIsControlsView(view)) {
        s7tv_handlePlayerGesturesViewLifecycle(view);
    }
    for (UIView *subview in view.subviews) {
        s7tv_playerGestureVisitView(subview);
    }
}

static void s7tv_playerGestureRefreshExistingViews(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_playerGestureRefreshExistingViews();
        });
        return;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            s7tv_playerGestureVisitView(window);
        }
    }
}

void s7tv_playerGesturesSetup(void) {
    s7tv_playerGesturesRegisterDefaults();
    s7tv_playerGestureRegisterFakeBrightnessReset();
    s7tv_playerGestureRefreshExistingViews();
}
