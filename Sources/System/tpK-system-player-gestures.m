/* Theater player gestures: brightness on one side, volume on the other. */

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <math.h>
#import "System/tpK-system-player-gestures.h"
#import "Localization/tpK-localization-manager.h"
#import "UI/tpK-oled-mode.h"

static NSString *const kTPKPlayerControlsClass =
    @"Twitch.TheaterPlayerControlsView";
static NSString *const kTPKPlayerTheaterViewClass =
    @"Twitch.TheaterView";
static NSString *const kTPKPlayerDirectionalPanClass =
    @"Twitch.DirectionalPanGestureRecognizer";
static NSString *const kTPKPlayerTheaterContainerControllerClass =
    @"Twitch.TheaterContainerViewController";
static NSString *const kTPKPlayerVideoPositionClass =
    @"Twitch.TheaterVideoPositionView";
static NSString *const kTPKPlayerIVSViewClass = @"TwitchIVSPlayerView";
static NSString *const kTPKPlayerGesturesEnabledKey =
    @"tpk_player_gestures_enabled";
static NSString *const kTPKPlayerGesturesSensitivityKey =
    @"tpk_player_gestures_sensitivity";
static NSString *const kTPKPlayerGesturesDeadZoneKey =
    @"tpk_player_gestures_dead_zone";
static NSString *const kTPKPlayerGesturesLeftAssignmentKey =
    @"tpk_player_gestures_left_assignment";
static NSString *const kTPKPlayerGesturesRightAssignmentKey =
    @"tpk_player_gestures_right_assignment";
static NSString *const kTPKPlayerGesturesLegacyBrightnessEnabledKey =
    @"tpk_player_gestures_brightness_enabled";
static NSString *const kTPKPlayerGesturesLegacyVolumeEnabledKey =
    @"tpk_player_gestures_volume_enabled";
static NSString *const kTPKPlayerGesturesLegacyBrightnessSideKey =
    @"tpk_player_gestures_brightness_side";
static NSString *const kTPKPlayerGesturesLegacyVolumeSideKey =
    @"tpk_player_gestures_volume_side";

static const CGFloat kTPKPlayerGesturesDefaultSensitivity = 1.0;
static const NSInteger kTPKPlayerGesturesDefaultDeadZone = 20;
static const CGFloat kTPKPlayerGesturesMinimumSensitivity = 1.0;
static const CGFloat kTPKPlayerGesturesMaximumSensitivity = 5.0;
static const CGFloat kTPKPlayerGestureVerticalTolerance = 0.75;
static const CGFloat kTPKPlayerGestureMinimumFakeBrightness = -0.70;
static const NSInteger kTPKPlayerGesturesMinimumDeadZone = 0;
static const NSInteger kTPKPlayerGesturesMaximumDeadZone = 100;

static const NSUInteger kTPKPlayerGestureMaxParentDepth = 4;
static const NSUInteger kTPKPlayerGestureMaxSurfaceSearchDepth = 8;

static char kTPKPlayerGestureRecognizerKey;
static char kTPKPlayerGestureDelegateKey;
static char kTPKPlayerGestureHandlerKey;
static char kTPKPlayerGestureStateKey;
static char kTPKPlayerGestureBindingKey;
static char kTPKPlayerGestureHostKey;
static char kTPKPlayerGestureOverlayKey;
static char kTPKPlayerGestureFakeBrightnessOverlayKey;

static MPVolumeView *tpk_playerGestureSystemVolumeView;
static UISlider *tpk_playerGestureSystemVolumeSlider;
static CGFloat tpk_playerGestureFakeBrightness = 0.0;
static __weak UIView *tpk_playerGestureFakeBrightnessOverlayHost;

typedef NS_ENUM(NSInteger, TPKPlayerGestureSide) {
    TPKPlayerGestureSideUnknown = 0,
    TPKPlayerGestureSideBrightness,
    TPKPlayerGestureSideVolume,
};

static UIImage *tpk_playerGestureCachedSystemImage(NSString *name) {
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

static Class tpk_playerGestureControlsClass(void) {
    static Class controlsClass;
    if (!controlsClass) {
        controlsClass = NSClassFromString(kTPKPlayerControlsClass);
    }
    return controlsClass;
}

static BOOL tpk_playerGestureIsIVSPlayerView(UIView *view) {
    if (!view) return NO;
    Class ivsClass = NSClassFromString(kTPKPlayerIVSViewClass);
    return (ivsClass && [view isKindOfClass:ivsClass]) ||
        [NSStringFromClass(view.class) containsString:kTPKPlayerIVSViewClass];
}

static void tpk_playerGestureRefreshExistingViews(void);

// Count player-controls-* views per window: only the channel page mounts them.
static char kTPKPlayerGestureControlsWindowKey;
static char kTPKPlayerGestureControlsCountKey;

static void tpk_playerGestureControlsAttach(UIView *view) {
    UIWindow *window = view.window;
    if (!window) return;
    UIWindow *counted = objc_getAssociatedObject(
        view, &kTPKPlayerGestureControlsWindowKey);
    if (counted == window) return;
    if (counted) {
        NSNumber *old = objc_getAssociatedObject(
            counted, &kTPKPlayerGestureControlsCountKey);
        NSInteger value = MAX(0, old.integerValue - 1);
        objc_setAssociatedObject(counted, &kTPKPlayerGestureControlsCountKey,
                                 value ? @(value) : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(view, &kTPKPlayerGestureControlsWindowKey,
                             window, OBJC_ASSOCIATION_ASSIGN);
    NSNumber *count = objc_getAssociatedObject(
        window, &kTPKPlayerGestureControlsCountKey);
    NSInteger value = count.integerValue + 1;
    objc_setAssociatedObject(window, &kTPKPlayerGestureControlsCountKey,
                             @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (value == 1) {
        tpk_playerGestureRefreshExistingViews();
    }
}

static void tpk_playerGestureControlsDetach(UIView *view) {
    UIWindow *counted = objc_getAssociatedObject(
        view, &kTPKPlayerGestureControlsWindowKey);
    if (!counted) return;
    NSNumber *old = objc_getAssociatedObject(
        counted, &kTPKPlayerGestureControlsCountKey);
    NSInteger value = MAX(0, old.integerValue - 1);
    objc_setAssociatedObject(counted, &kTPKPlayerGestureControlsCountKey,
                             value ? @(value) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kTPKPlayerGestureControlsWindowKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL tpk_playerGestureHasWatchChrome(UIView *view) {
    if (!view || !view.window) return NO;
    NSNumber *count = objc_getAssociatedObject(
        view.window, &kTPKPlayerGestureControlsCountKey);
    return count.integerValue > 0;
}

static BOOL tpk_playerGestureIsRealStreamIVSView(UIView *view) {
    if (!view || !view.window) return NO;
    NSString *identifier = view.accessibilityIdentifier;
    NSString *windowClass = NSStringFromClass(view.window.class);
    BOOL knownWindow = [windowClass isEqualToString:@"Twitch.PictureInPictureWindow"] ||
        [windowClass isEqualToString:@"TWWindow"];
    if (!knownWindow) return NO;
    if ([identifier isEqualToString:@"video-player"]) return YES;
    // Feed IDs can persist after recycling; gestures are gated by watch chrome.
    return [identifier hasPrefix:@"feed-player-"];
}

@interface TPKPlayerGestureBrightnessIconView : UIView
@property (nonatomic, assign) CGFloat brightnessValue;
@end

@implementation TPKPlayerGestureBrightnessIconView

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

    CGFloat moonProgress = MIN(1.0, MAX(
        0.0, -value / -kTPKPlayerGestureMinimumFakeBrightness));
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

@interface TPKPlayerGestureOverlayView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) TPKPlayerGestureBrightnessIconView *brightnessIconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) dispatch_source_t hideTimer;
@property (nonatomic, strong) CADisplayLink *positionDisplayLink;
@property (nonatomic, weak) UIView *geometryView;
@property (nonatomic, assign) BOOL bottomAligned;
@property (nonatomic, assign) BOOL screenAlignedToWindow;
- (void)tpk_updateAppearance;
- (void)tpk_updateFrame;
- (void)tpk_updateFrameFromDisplayLink:(CADisplayLink *)displayLink;
- (void)tpk_stopPositionUpdates;
- (void)attachToGeometryView:(UIView *)geometryView
               bottomAligned:(BOOL)bottomAligned
        screenAlignedToWindow:(BOOL)screenAlignedToWindow;
- (void)showText:(NSString *)text
       iconName:(NSString *)iconName
 brightnessValue:(CGFloat)brightnessValue
    isBrightness:(BOOL)isBrightness
   iconTintColor:(UIColor *)iconTintColor;
@end

@implementation TPKPlayerGestureOverlayView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.layer.cornerRadius = 16.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor =
        [UIColor colorWithRed:0.569 green:0.278 blue:1.0 alpha:1.0].CGColor;
    self.clipsToBounds = YES;
    self.hidden = YES;
    self.alpha = 0.0;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    [self tpk_updateAppearance];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.tintColor = UIColor.whiteColor;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;

    self.brightnessIconView = [[TPKPlayerGestureBrightnessIconView alloc] init];
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
           selector:@selector(tpk_oledModeDidChange:)
               name:TPKOLEDModeDidChangeNotification
             object:nil];
    return self;
}

- (void)dealloc {
    if (self.hideTimer) dispatch_source_cancel(self.hideTimer);
    [self.positionDisplayLink invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:TPKOLEDModeDidChangeNotification object:nil];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self tpk_stopPositionUpdates];
}

- (void)tpk_updateAppearance {
    self.backgroundColor = TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithWhite:0.08 alpha:1.0];
}

- (void)tpk_oledModeDidChange:(__unused NSNotification *)note {
    if (NSThread.isMainThread) {
        [self tpk_updateAppearance];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self tpk_updateAppearance];
        });
    }
}

- (void)attachToGeometryView:(UIView *)geometryView
               bottomAligned:(BOOL)bottomAligned
        screenAlignedToWindow:(BOOL)screenAlignedToWindow {
    if (!geometryView) return;
    self.geometryView = geometryView;
    self.bottomAligned = bottomAligned;
    self.screenAlignedToWindow = screenAlignedToWindow;
    [self tpk_updateFrame];
}

// Frame from the video's live rect on each show: anchors break on rotation.
- (void)tpk_updateFrame {
    UIWindow *window = self.window;
    if (!window) return;
    CGRect bounds = window.bounds;
    CGRect videoRect = !self.screenAlignedToWindow && self.geometryView
        ? [self.geometryView convertRect:self.geometryView.bounds toView:window]
        : bounds;
    if (CGRectIsNull(videoRect) || CGRectIsEmpty(videoRect)) videoRect = bounds;
    CGFloat x = CGRectGetMidX(videoRect) - 156.0 / 2.0;
    CGFloat topInset = self.screenAlignedToWindow
        ? window.safeAreaInsets.top : 0.0;
    CGFloat y = self.bottomAligned
        ? CGRectGetMaxY(videoRect) - 32.0 - 8.0
        : MAX(CGRectGetMinY(videoRect) + 8.0, topInset + 8.0);
    x = MIN(MAX(x, 8.0), MAX(8.0, bounds.size.width - 156.0 - 8.0));
    y = MIN(MAX(y, 8.0), MAX(8.0, bounds.size.height - 32.0 - 8.0));
    CGRect frame = CGRectMake(x, y, 156.0, 32.0);
    if (!CGRectEqualToRect(self.frame, frame)) self.frame = frame;
}

- (void)tpk_updateFrameFromDisplayLink:(__unused CADisplayLink *)displayLink {
    [self tpk_updateFrame];
}

- (void)tpk_stopPositionUpdates {
    [self.positionDisplayLink invalidate];
    self.positionDisplayLink = nil;
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
        UIImage *image = tpk_playerGestureCachedSystemImage(iconName);
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
        __weak TPKPlayerGestureOverlayView *weakSelf = self;
        dispatch_source_set_event_handler(self.hideTimer, ^{
            TPKPlayerGestureOverlayView *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_source_set_timer(strongSelf.hideTimer,
                                      DISPATCH_TIME_FOREVER,
                                      DISPATCH_TIME_FOREVER, 0);
            [UIView animateWithDuration:0.18 animations:^{
                strongSelf.alpha = 0.0;
            } completion:^(BOOL finished) {
                if (finished && strongSelf.alpha <= 0.01) {
                    strongSelf.hidden = YES;
                    [strongSelf tpk_stopPositionUpdates];
                }
            }];
        });
        dispatch_resume(self.hideTimer);
    }
    if (!self.positionDisplayLink) {
        self.positionDisplayLink = [CADisplayLink
            displayLinkWithTarget:self
                         selector:@selector(tpk_updateFrameFromDisplayLink:)];
        [self.positionDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                       forMode:NSRunLoopCommonModes];
    }
    dispatch_source_set_timer(self.hideTimer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(0.85 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
}

@end

@interface TPKPlayerGestureState : NSObject
@property (nonatomic, assign) TPKPlayerGestureSide side;
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

@implementation TPKPlayerGestureState
@end

static void tpk_playerGestureRefreshExistingViews(void);

static NSUserDefaults *tpk_playerGestureDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static TPKPlayerGestureAssignment
tpk_playerGesturesLegacyAssignmentForSide(NSUserDefaults *defaults,
                                           NSInteger side) {
    BOOL brightnessEnabled = [defaults
        objectForKey:kTPKPlayerGesturesLegacyBrightnessEnabledKey]
        ? [defaults boolForKey:kTPKPlayerGesturesLegacyBrightnessEnabledKey]
        : YES;
    BOOL volumeEnabled = [defaults
        objectForKey:kTPKPlayerGesturesLegacyVolumeEnabledKey]
        ? [defaults boolForKey:kTPKPlayerGesturesLegacyVolumeEnabledKey]
        : YES;
    NSInteger brightnessSide = [defaults
        objectForKey:kTPKPlayerGesturesLegacyBrightnessSideKey]
        ? [defaults integerForKey:kTPKPlayerGesturesLegacyBrightnessSideKey]
        : 0;
    NSInteger volumeSide = [defaults
        objectForKey:kTPKPlayerGesturesLegacyVolumeSideKey]
        ? [defaults integerForKey:kTPKPlayerGesturesLegacyVolumeSideKey]
        : 1;

    if (brightnessEnabled && brightnessSide == side)
        return TPKPlayerGestureAssignmentBrightness;
    if (volumeEnabled && volumeSide == side)
        return TPKPlayerGestureAssignmentVolume;
    return TPKPlayerGestureAssignmentDisabled;
}

static void tpk_playerGesturesMigrateLegacyAssignments(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = tpk_playerGestureDefaults();
        if ([defaults objectForKey:kTPKPlayerGesturesLeftAssignmentKey] ||
            [defaults objectForKey:kTPKPlayerGesturesRightAssignmentKey]) {
            return;
        }

        BOOL hasLegacySettings =
            [defaults objectForKey:kTPKPlayerGesturesLegacyBrightnessEnabledKey] ||
            [defaults objectForKey:kTPKPlayerGesturesLegacyVolumeEnabledKey] ||
            [defaults objectForKey:kTPKPlayerGesturesLegacyBrightnessSideKey] ||
            [defaults objectForKey:kTPKPlayerGesturesLegacyVolumeSideKey];
        if (!hasLegacySettings) return;

        [defaults setInteger:tpk_playerGesturesLegacyAssignmentForSide(
            defaults, 0) forKey:kTPKPlayerGesturesLeftAssignmentKey];
        [defaults setInteger:tpk_playerGesturesLegacyAssignmentForSide(
            defaults, 1) forKey:kTPKPlayerGesturesRightAssignmentKey];
        [defaults synchronize];
    });
}

static void tpk_playerGesturesRegisterDefaults(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tpk_playerGesturesMigrateLegacyAssignments();
        [tpk_playerGestureDefaults() registerDefaults:@{
            kTPKPlayerGesturesEnabledKey: @NO,
            kTPKPlayerGesturesLeftAssignmentKey:
                @(TPKPlayerGestureAssignmentBrightness),
            kTPKPlayerGesturesRightAssignmentKey:
                @(TPKPlayerGestureAssignmentVolume),
            kTPKPlayerGesturesSensitivityKey:
                @(kTPKPlayerGesturesDefaultSensitivity),
            kTPKPlayerGesturesDeadZoneKey:
                @(kTPKPlayerGesturesDefaultDeadZone),
        }];
    });
}

BOOL tpk_playerGesturesEnabled(void) {
    tpk_playerGesturesRegisterDefaults();
    return [tpk_playerGestureDefaults()
        boolForKey:kTPKPlayerGesturesEnabledKey];
}

void tpk_setPlayerGesturesEnabled(BOOL enabled) {
    tpk_playerGesturesRegisterDefaults();
    [tpk_playerGestureDefaults() setBool:enabled
                                   forKey:kTPKPlayerGesturesEnabledKey];
    [tpk_playerGestureDefaults() synchronize];
    tpk_playerGestureRefreshExistingViews();
}

static TPKPlayerGestureAssignment
tpk_playerGesturesNormalizedAssignment(NSInteger assignment) {
    if (assignment == TPKPlayerGestureAssignmentVolume)
        return TPKPlayerGestureAssignmentVolume;
    if (assignment == TPKPlayerGestureAssignmentBrightness)
        return TPKPlayerGestureAssignmentBrightness;
    return TPKPlayerGestureAssignmentDisabled;
}

TPKPlayerGestureAssignment tpk_playerGesturesLeftAssignment(void) {
    tpk_playerGesturesRegisterDefaults();
    return tpk_playerGesturesNormalizedAssignment([tpk_playerGestureDefaults()
        integerForKey:kTPKPlayerGesturesLeftAssignmentKey]);
}

void tpk_setPlayerGesturesLeftAssignment(
    TPKPlayerGestureAssignment assignment) {
    tpk_playerGesturesRegisterDefaults();
    assignment = tpk_playerGesturesNormalizedAssignment(assignment);
    [tpk_playerGestureDefaults() setInteger:assignment
                                      forKey:kTPKPlayerGesturesLeftAssignmentKey];
    [tpk_playerGestureDefaults() synchronize];
}

TPKPlayerGestureAssignment tpk_playerGesturesRightAssignment(void) {
    tpk_playerGesturesRegisterDefaults();
    return tpk_playerGesturesNormalizedAssignment([tpk_playerGestureDefaults()
        integerForKey:kTPKPlayerGesturesRightAssignmentKey]);
}

void tpk_setPlayerGesturesRightAssignment(
    TPKPlayerGestureAssignment assignment) {
    tpk_playerGesturesRegisterDefaults();
    assignment = tpk_playerGesturesNormalizedAssignment(assignment);
    [tpk_playerGestureDefaults() setInteger:assignment
                                      forKey:kTPKPlayerGesturesRightAssignmentKey];
    [tpk_playerGestureDefaults() synchronize];
}

CGFloat tpk_playerGesturesSensitivity(void) {
    tpk_playerGesturesRegisterDefaults();
    CGFloat value = [tpk_playerGestureDefaults()
        floatForKey:kTPKPlayerGesturesSensitivityKey];
    return MIN(kTPKPlayerGesturesMaximumSensitivity,
               MAX(kTPKPlayerGesturesMinimumSensitivity, value));
}

void tpk_setPlayerGesturesSensitivity(CGFloat sensitivity) {
    tpk_playerGesturesRegisterDefaults();
    sensitivity = MIN(kTPKPlayerGesturesMaximumSensitivity,
                       MAX(kTPKPlayerGesturesMinimumSensitivity,
                           sensitivity));
    [tpk_playerGestureDefaults() setFloat:(float)sensitivity
                                    forKey:kTPKPlayerGesturesSensitivityKey];
    [tpk_playerGestureDefaults() synchronize];
}

NSInteger tpk_playerGesturesDeadZone(void) {
    tpk_playerGesturesRegisterDefaults();
    NSInteger value = [tpk_playerGestureDefaults()
        integerForKey:kTPKPlayerGesturesDeadZoneKey];
    return MIN(kTPKPlayerGesturesMaximumDeadZone,
               MAX(kTPKPlayerGesturesMinimumDeadZone, value));
}

void tpk_setPlayerGesturesDeadZone(NSInteger deadZone) {
    tpk_playerGesturesRegisterDefaults();
    deadZone = MIN(kTPKPlayerGesturesMaximumDeadZone,
                   MAX(kTPKPlayerGesturesMinimumDeadZone, deadZone));
    [tpk_playerGestureDefaults() setInteger:deadZone
                                      forKey:kTPKPlayerGesturesDeadZoneKey];
    [tpk_playerGestureDefaults() synchronize];
}

static void tpk_playerGestureInstallRecognizer(UIView *view,
                                                UIView *geometryView);
static void tpk_playerGestureRemoveRecognizer(UIView *view);

@interface TPKPlayerGestureBinding : NSObject
@property (nonatomic, weak) UIView *geometryView;
@end

@implementation TPKPlayerGestureBinding
@end

static BOOL tpk_playerGestureIsControlsView(UIView *view);

static UIView *tpk_playerGestureOverlayHostForGeometryView(
    UIView *geometryView) {
    if (!geometryView) return nil;

    // Use the window so dimming covers the app and the HUD stays above it.
    return geometryView.window;
}

static void tpk_playerGestureUpdateFakeBrightnessOverlay(
    UIView *geometryView) {
    if (!geometryView || !geometryView.window) return;

    UIView *overlayHost =
        tpk_playerGestureOverlayHostForGeometryView(geometryView);
    if (!overlayHost) return;

    UIView *previousHost = tpk_playerGestureFakeBrightnessOverlayHost;
    if (previousHost && previousHost != overlayHost) {
        UIView *previousOverlay = objc_getAssociatedObject(
            previousHost, &kTPKPlayerGestureFakeBrightnessOverlayKey);
        previousOverlay.hidden = YES;
        previousOverlay.alpha = 0.0;
    }
    tpk_playerGestureFakeBrightnessOverlayHost = overlayHost;

    UIView *fakeOverlay = objc_getAssociatedObject(
        overlayHost, &kTPKPlayerGestureFakeBrightnessOverlayKey);
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
                                 &kTPKPlayerGestureFakeBrightnessOverlayKey,
                                 fakeOverlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Fake brightness covers the whole app window.
    CGRect hostBounds = overlayHost.bounds;
    if (!CGRectEqualToRect(fakeOverlay.frame, hostBounds)) {
        fakeOverlay.frame = hostBounds;
    }

    CGFloat opacity = MIN(0.70,
                          MAX(0.0, -tpk_playerGestureFakeBrightness));
    BOOL hidden = opacity <= 0.001;
    if (fakeOverlay.hidden != hidden) fakeOverlay.hidden = hidden;
    if (fabs(fakeOverlay.alpha - opacity) >= 0.001) {
        [UIView performWithoutAnimation:^{
            fakeOverlay.alpha = opacity;
        }];
    }
}

static void tpk_playerGestureResetFakeBrightness(void) {
    tpk_playerGestureFakeBrightness = 0.0;
    UIView *host = tpk_playerGestureFakeBrightnessOverlayHost;
    UIView *overlay = objc_getAssociatedObject(
        host, &kTPKPlayerGestureFakeBrightnessOverlayKey);
    overlay.hidden = YES;
    overlay.alpha = 0.0;
    tpk_playerGestureFakeBrightnessOverlayHost = nil;
}

static void tpk_playerGestureRegisterFakeBrightnessReset(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
                        tpk_playerGestureResetFakeBrightness();
                    }];
    });
}

static TPKPlayerGestureOverlayView *tpk_playerGesturePrepareOverlay(
    UIView *geometryView,
    BOOL bottomAligned,
    BOOL screenAlignedToWindow) {
    if (!geometryView) return nil;
    UIWindow *window = geometryView.window;
    if (!window) return nil;

    UIView *overlayHost =
        tpk_playerGestureOverlayHostForGeometryView(geometryView);
    if (!overlayHost) return nil;

    TPKPlayerGestureOverlayView *overlay = objc_getAssociatedObject(
        overlayHost, &kTPKPlayerGestureOverlayKey);
    if (!overlay) {
        overlay = [[TPKPlayerGestureOverlayView alloc] init];
        overlay.layer.zPosition = 1000.0;
        [overlayHost addSubview:overlay];
        objc_setAssociatedObject(overlayHost, &kTPKPlayerGestureOverlayKey,
                                 overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (overlay.superview != overlayHost) {
        [overlayHost addSubview:overlay];
    }

    [overlay attachToGeometryView:geometryView
                    bottomAligned:bottomAligned
             screenAlignedToWindow:screenAlignedToWindow];
    if (overlayHost.subviews.lastObject != overlay) {
        [overlayHost bringSubviewToFront:overlay];
    }
    return overlay;
}

static void tpk_playerGestureShowOverlayAtPosition(
    UIView *geometryView,
    TPKPlayerGestureSide side,
    CGFloat value,
    BOOL bottomAligned) {
    if (!geometryView || side == TPKPlayerGestureSideUnknown) return;
    tpk_playerGestureUpdateFakeBrightnessOverlay(geometryView);

    TPKPlayerGestureOverlayView *overlay =
        tpk_playerGesturePrepareOverlay(geometryView, bottomAligned, NO);
    if (!overlay) return;

    NSString *formatKey = side == TPKPlayerGestureSideBrightness
        ? @"player_gestures_brightness_format"
        : @"player_gestures_volume_format";
    NSString *iconName = nil;
    CGFloat brightnessValue = 0.0;
    BOOL isBrightness = side == TPKPlayerGestureSideBrightness;
    if (side == TPKPlayerGestureSideBrightness) {
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
    if (side == TPKPlayerGestureSideBrightness &&
        tpk_playerGestureFakeBrightness < -0.001) {
        displayedValue = tpk_playerGestureFakeBrightness;
        brightnessValue = displayedValue;
    }
    CGFloat minimumDisplayedValue = side == TPKPlayerGestureSideBrightness
        ? kTPKPlayerGestureMinimumFakeBrightness : 0.0;
    NSString *text = [NSString stringWithFormat:L(formatKey),
                      (double)(MIN(1.0, MAX(minimumDisplayedValue,
                                             displayedValue)) * 100.0)];
    [overlay showText:text
            iconName:iconName
      brightnessValue:brightnessValue
         isBrightness:isBrightness
        iconTintColor:UIColor.whiteColor];
}

static void tpk_playerGestureShowOverlay(UIView *geometryView,
                                          TPKPlayerGestureSide side,
                                          CGFloat value) {
    tpk_playerGestureShowOverlayAtPosition(geometryView, side, value, NO);
}

void tpk_showPlayerGestureOverlay(UIView *geometryView,
                                   NSString *text,
                                   NSString *iconName) {
    tpk_showPlayerGestureOverlayWithTint(geometryView, text, iconName,
                                          UIColor.whiteColor);
}

void tpk_showPlayerGestureOverlayWithTint(UIView *geometryView,
                                           NSString *text,
                                           NSString *iconName,
                                           UIColor *iconTintColor) {
    if (!geometryView || !text.length || !iconName.length) return;

    UIWindow *window = geometryView.window;
    if (!window) return;

    tpk_playerGestureUpdateFakeBrightnessOverlay(geometryView);

    TPKPlayerGestureOverlayView *overlay =
        tpk_playerGesturePrepareOverlay(geometryView, NO, YES);
    if (!overlay) return;

    [overlay showText:text
            iconName:iconName
      brightnessValue:0.0
         isBrightness:NO
        iconTintColor:iconTintColor ?: UIColor.whiteColor];
}

static UISlider *tpk_playerGestureFindSlider(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"MPVolumeSlider"])
        return (UISlider *)view;
    if ([view isKindOfClass:UISlider.class]) return (UISlider *)view;
    for (UIView *subview in view.subviews) {
        UISlider *slider = tpk_playerGestureFindSlider(subview);
        if (slider) return slider;
    }
    return nil;
}

static UISlider *tpk_playerGestureVolumeSlider(UIWindow *window) {
    if (!window) return nil;

    if (!tpk_playerGestureSystemVolumeView) {
        tpk_playerGestureSystemVolumeView = [[MPVolumeView alloc] initWithFrame:
            CGRectMake(-120.0, -32.0, 120.0, 32.0)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        tpk_playerGestureSystemVolumeView.showsRouteButton = NO;
#pragma clang diagnostic pop
        tpk_playerGestureSystemVolumeView.showsVolumeSlider = YES;
        tpk_playerGestureSystemVolumeView.alpha = 0.01;
        tpk_playerGestureSystemVolumeView.userInteractionEnabled = NO;
        tpk_playerGestureSystemVolumeView.accessibilityElementsHidden = YES;
    }
    if (tpk_playerGestureSystemVolumeView.superview != window) {
        [tpk_playerGestureSystemVolumeView removeFromSuperview];
        [window addSubview:tpk_playerGestureSystemVolumeView];
        [tpk_playerGestureSystemVolumeView setNeedsLayout];
        [tpk_playerGestureSystemVolumeView layoutIfNeeded];
        tpk_playerGestureSystemVolumeSlider = nil;
    }
    if (!tpk_playerGestureSystemVolumeSlider ||
        !tpk_playerGestureSystemVolumeSlider.superview) {
        tpk_playerGestureSystemVolumeSlider =
            tpk_playerGestureFindSlider(tpk_playerGestureSystemVolumeView);
    }
    return tpk_playerGestureSystemVolumeSlider;
}

static NSUInteger tpk_playerGestureVolumeDetachGeneration;

static void tpk_playerGestureCancelVolumeDetach(void) {
    tpk_playerGestureVolumeDetachGeneration += 1;
}

static void tpk_playerGestureDetachVolumeView(void) {
    [tpk_playerGestureSystemVolumeView removeFromSuperview];
    tpk_playerGestureSystemVolumeSlider = nil;
}

static void tpk_playerGestureScheduleVolumeDetach(void) {
    NSUInteger generation = ++tpk_playerGestureVolumeDetachGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != tpk_playerGestureVolumeDetachGeneration) return;
        tpk_playerGestureDetachVolumeView();
    });
}

static UIWindow *tpk_playerGestureSystemWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (@available(iOS 15.0, *)) {
            if (windowScene.keyWindow) return windowScene.keyWindow;
        }
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static void tpk_playerGestureSetSystemVolume(CGFloat value, UIWindow *window) {
    tpk_playerGestureCancelVolumeDetach();
    UIWindow *targetWindow = tpk_playerGestureSystemWindow() ?: window;
    UISlider *slider = tpk_playerGestureVolumeSlider(targetWindow);
    value = MIN(1.0, MAX(0.0, value));
    if (!slider) {
        // MPVolumeView may create its slider on the next run loop.
        NSUInteger generation = tpk_playerGestureVolumeDetachGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != tpk_playerGestureVolumeDetachGeneration) return;
            UISlider *retrySlider = tpk_playerGestureVolumeSlider(targetWindow);
            if (!retrySlider) return;
            [retrySlider setValue:(float)value animated:NO];
            [retrySlider sendActionsForControlEvents:UIControlEventValueChanged];
            [retrySlider sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
        return;
    }
    [slider setValue:(float)value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// Sensitivity is also the visible percentage step.
static CGFloat tpk_playerGestureValueForDistance(CGFloat initialValue,
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

static TPKPlayerGestureSide
tpk_playerGestureSideForOrigin(UIView *geometryView, CGPoint origin) {
    if (!geometryView) return TPKPlayerGestureSideUnknown;

    BOOL isLeft = origin.x < CGRectGetMidX(geometryView.bounds);
    TPKPlayerGestureAssignment assignment = isLeft
        ? tpk_playerGesturesLeftAssignment()
        : tpk_playerGesturesRightAssignment();
    switch (assignment) {
        case TPKPlayerGestureAssignmentBrightness:
            return TPKPlayerGestureSideBrightness;
        case TPKPlayerGestureAssignmentVolume:
            return TPKPlayerGestureSideVolume;
        case TPKPlayerGestureAssignmentDisabled:
        default:
            return TPKPlayerGestureSideUnknown;
    }
}

static BOOL tpk_playerGestureIsControlsView(UIView *view);

static BOOL tpk_playerGestureIsVideoPositionView(UIView *view) {
    return view &&
        [NSStringFromClass(view.class) isEqualToString:kTPKPlayerVideoPositionClass];
}

static BOOL tpk_playerGestureIsDockPan(UIGestureRecognizer *recognizer) {
    if (!recognizer ||
        ![recognizer isKindOfClass:UIPanGestureRecognizer.class]) {
        return NO;
    }

    NSString *recognizerClass = NSStringFromClass(recognizer.class);
    if ([recognizerClass isEqualToString:kTPKPlayerDirectionalPanClass] ||
        [recognizerClass hasSuffix:@".DirectionalPanGestureRecognizer"] ||
        [recognizerClass hasSuffix:@"DirectionalPanGestureRecognizer"]) {
        return YES;
    }

    // Some versions expose the dock gesture only as a UIPanGestureRecognizer.
    UIView *view = recognizer.view;
    if (tpk_playerGestureIsControlsView(view)) return YES;

    if ([NSStringFromClass(view.nextResponder.class)
            isEqualToString:kTPKPlayerTheaterContainerControllerClass]) {
        return YES;
    }
    return NO;
}

static BOOL tpk_playerGestureIsNativeOverlayGesture(
    UIGestureRecognizer *recognizer) {
    if (!recognizer ||
        [recognizer isKindOfClass:UIHoverGestureRecognizer.class]) {
        return NO;
    }

    // Twitch uses a tap for the controls overlay and a pan for dock/PIP.
    return tpk_playerGestureIsDockPan(recognizer) ||
        [recognizer isKindOfClass:UITapGestureRecognizer.class];
}

static BOOL tpk_playerGestureTouchIsBlocked(UIView *view, UIView *surface) {
    UIView *candidate = view;
    while (candidate) {
        if ([candidate.accessibilityIdentifier
                isEqualToString:@"tpk_player_stats_panel"]) return YES;
        if ([candidate.accessibilityIdentifier
                isEqualToString:@"tpk_fake_chat_preview"]) return YES;
        if (tpk_playerGestureIsVideoPositionView(candidate) ||
            [candidate isKindOfClass:UIControl.class]) {
            return YES;
        }
        if (candidate == surface) break;
        candidate = candidate.superview;
    }
    return NO;
}

static BOOL tpk_playerGestureTouchIsInsideVideo(UITouch *touch,
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

static UIView *tpk_playerGestureResolveGeometry(UIView *touchView) {
    UIView *node = touchView;
    while (node) {
        if (tpk_playerGestureIsIVSPlayerView(node)) return node;
        NSString *identifier = node.accessibilityIdentifier;
        if ([identifier isEqualToString:@"video-player"] ||
            [identifier hasPrefix:@"feed-player-"]) {
            return node;
        }
        for (UIView *child in node.subviews) {
            if (tpk_playerGestureIsIVSPlayerView(child)) return node;
            NSString *childId = child.accessibilityIdentifier;
            if ([childId isEqualToString:@"video-player"] ||
                [childId hasPrefix:@"feed-player-"]) {
                return node;
            }
        }
        node = node.superview;
    }
    return nil;
}

@interface TPKPlayerVerticalPanGestureRecognizer : UIPanGestureRecognizer
@end

@implementation TPKPlayerVerticalPanGestureRecognizer

// Total lock: never stopped, and we cancel everything else on begin.
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

@end

@interface TPKPlayerGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation TPKPlayerGestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (!tpk_playerGesturesEnabled()) return NO;
    UIView *surface = gestureRecognizer.view;
    if (!surface || tpk_playerGestureTouchIsBlocked(touch.view, surface))
        return NO;

    // Live geometry from the touch each time; stored binding is fallback.
    TPKPlayerGestureBinding *binding = objc_getAssociatedObject(
        gestureRecognizer, &kTPKPlayerGestureBindingKey);
    UIView *geometryView = tpk_playerGestureResolveGeometry(touch.view)
        ?: binding.geometryView
        ?: surface;
    if (binding) binding.geometryView = geometryView;
    if (!tpk_playerGestureTouchIsInsideVideo(touch, geometryView, surface))
        return NO;

    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)gestureRecognizer {
    if (!tpk_playerGesturesEnabled()) return NO;

    // Claim only on the channel page or PIP; home stays fully native.
    TPKPlayerGestureBinding *binding = objc_getAssociatedObject(
        gestureRecognizer, &kTPKPlayerGestureBindingKey);
    UIView *geometryView = binding.geometryView ?: gestureRecognizer.view;
    BOOL inPip = [NSStringFromClass(geometryView.window.class)
        isEqualToString:@"Twitch.PictureInPictureWindow"];
    if (!inPip && !tpk_playerGestureHasWatchChrome(geometryView)) {
        return NO;
    }

    return YES;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (BOOL)       gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // Native recognizers wait for us: claimed = blocked, declined = untouched.
    if (other == gestureRecognizer) return NO;
    if ([other isKindOfClass:TPKPlayerVerticalPanGestureRecognizer.class]) {
        return NO;
    }
    return YES;
}

@end

@interface TPKPlayerGestureHandler : NSObject
- (void)handlePan:(UIPanGestureRecognizer *)gestureRecognizer;
@end

@implementation TPKPlayerGestureHandler

- (void)handlePan:(UIPanGestureRecognizer *)gestureRecognizer {
    UIView *surface = gestureRecognizer.view;
    if (!surface) return;

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        TPKPlayerGestureState *state = [TPKPlayerGestureState new];
        TPKPlayerGestureBinding *binding = objc_getAssociatedObject(
            gestureRecognizer, &kTPKPlayerGestureBindingKey);
        UIView *geometryView = binding.geometryView ?: surface;
        state.geometryView = geometryView;
        CGPoint origin = [gestureRecognizer locationInView:geometryView];
        state.initialVolume = AVAudioSession.sharedInstance.outputVolume;
        state.initialBrightness = UIScreen.mainScreen.brightness;
        state.currentBrightness = state.initialBrightness;
        state.currentFakeBrightness = tpk_playerGestureFakeBrightness;
        state.lastBrightnessAdjustment = 0.0;
        TPKPlayerGestureSide side =
            tpk_playerGestureSideForOrigin(geometryView, origin);
        if (side != TPKPlayerGestureSideUnknown) {
            BOOL inPip = [NSStringFromClass(geometryView.window.class)
                isEqualToString:@"Twitch.PictureInPictureWindow"];
            if (!inPip && !tpk_playerGestureHasWatchChrome(geometryView)) {
                side = TPKPlayerGestureSideUnknown;
            }
        }
        state.side = side;
        state.playerHeight = MAX(1.0, CGRectGetHeight(geometryView.bounds));
        state.sensitivity = tpk_playerGesturesSensitivity();
        state.deadZone = tpk_playerGesturesDeadZone();
        if (state.side == TPKPlayerGestureSideVolume) {
            // Prepare the volume slider before movement.
            tpk_playerGestureCancelVolumeDetach();
            UISlider *slider = tpk_playerGestureVolumeSlider(surface.window);
            if (slider) state.initialVolume = slider.value;
            state.lastVolumeValue = state.initialVolume;
        }
        objc_setAssociatedObject(gestureRecognizer, &kTPKPlayerGestureStateKey,
                                 state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    TPKPlayerGestureState *state = objc_getAssociatedObject(
        gestureRecognizer, &kTPKPlayerGestureStateKey);
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
                    (horizontalDistance * kTPKPlayerGestureVerticalTolerance);
        }
        if (!state.vertical || verticalDistance <= deadZone) return;

        CGFloat effectiveDistance = verticalDistance - deadZone;
        CGFloat signedDistance = translation.y < 0.0
            ? effectiveDistance : -effectiveDistance;
        CGFloat value;
        if (state.side == TPKPlayerGestureSideBrightness) {
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
                fakeValue = MAX(kTPKPlayerGestureMinimumFakeBrightness,
                                fakeValue - decrease);
            }

            systemValue = MIN(1.0, MAX(0.0, systemValue));
            fakeValue = MIN(0.0, MAX(
                kTPKPlayerGestureMinimumFakeBrightness, fakeValue));
            BOOL systemChanged =
                fabs(state.currentBrightness - systemValue) >= 0.001;
            BOOL fakeChanged =
                fabs(state.currentFakeBrightness - fakeValue) >= 0.001;
            if (!systemChanged && !fakeChanged) return;

            state.currentBrightness = systemValue;
            state.currentFakeBrightness = fakeValue;
            tpk_playerGestureFakeBrightness = fakeValue;
            if (systemChanged) UIScreen.mainScreen.brightness = systemValue;
            tpk_playerGestureUpdateFakeBrightnessOverlay(geometryView);
            value = systemValue;
        } else if (state.side == TPKPlayerGestureSideVolume) {
            value = tpk_playerGestureValueForDistance(
                state.initialVolume, signedDistance, state.playerHeight,
                state.sensitivity);
            // Compare with the target because iOS updates outputVolume later.
            if (fabs(state.lastVolumeValue - value) < 0.001)
                return;
            tpk_playerGestureSetSystemVolume(value, surface.window);
            state.lastVolumeValue = value;
        } else {
            return;
        }
        tpk_playerGestureShowOverlay(geometryView, state.side, value);
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded ||
        gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
        gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        // Keep the volume view briefly, then restore the native HUD.
        tpk_playerGestureScheduleVolumeDetach();
        objc_setAssociatedObject(gestureRecognizer,
                                 &kTPKPlayerGestureStateKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end

static void tpk_playerGestureRequireDockGestureToFail(
    UIPanGestureRecognizer *gestureRecognizer,
    UIView *view,
    NSUInteger depth) {
    if (!gestureRecognizer || !view ||
        depth > kTPKPlayerGestureMaxSurfaceSearchDepth) return;

    for (UIGestureRecognizer *other in view.gestureRecognizers) {
        if (other == gestureRecognizer ||
            !tpk_playerGestureIsNativeOverlayGesture(other)) continue;
        // Native dock gestures wait for ours, preventing accidental PIP.
        [other requireGestureRecognizerToFail:gestureRecognizer];
    }

    for (UIView *subview in view.subviews) {
        tpk_playerGestureRequireDockGestureToFail(
            gestureRecognizer, subview, depth + 1);
    }
}

static void tpk_playerGesturePrioritizeDockGesture(
    UIPanGestureRecognizer *gestureRecognizer,
    UIView *view) {
    if (!gestureRecognizer || !view) return;

    // Search both descendants and ancestors for Twitch's dock pan.
    tpk_playerGestureRequireDockGestureToFail(
        gestureRecognizer, view, 0);
    UIView *ancestor = view.superview;
    for (NSUInteger depth = 0;
         ancestor && depth <= kTPKPlayerGestureMaxParentDepth;
        depth++, ancestor = ancestor.superview) {
        for (UIGestureRecognizer *other in ancestor.gestureRecognizers) {
            if (other == gestureRecognizer ||
                !tpk_playerGestureIsNativeOverlayGesture(other)) continue;
            [other requireGestureRecognizerToFail:gestureRecognizer];
        }
    }
}

static void tpk_playerGestureInstallRecognizer(UIView *view,
                                                UIView *geometryView) {
    if (!view || !tpk_playerGesturesEnabled()) return;

    UIPanGestureRecognizer *existing = objc_getAssociatedObject(
        view, &kTPKPlayerGestureRecognizerKey);
    if (existing) {
        TPKPlayerGestureBinding *binding = objc_getAssociatedObject(
            existing, &kTPKPlayerGestureBindingKey);
        if (!binding) {
            binding = [TPKPlayerGestureBinding new];
            objc_setAssociatedObject(existing, &kTPKPlayerGestureBindingKey,
                                     binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (geometryView) binding.geometryView = geometryView;
        existing.enabled = YES;
        existing.cancelsTouchesInView = YES;
        existing.delaysTouchesBegan = YES;
        existing.delaysTouchesEnded = YES;
        tpk_playerGesturePrioritizeDockGesture(existing, view);
        if (geometryView != view) {
            tpk_playerGesturePrioritizeDockGesture(existing, geometryView);
        }
        return;
    }

    TPKPlayerGestureDelegate *delegate = [TPKPlayerGestureDelegate new];
    TPKPlayerGestureHandler *handler = [TPKPlayerGestureHandler new];
    TPKPlayerGestureBinding *binding = [TPKPlayerGestureBinding new];
    binding.geometryView = geometryView;
    UIPanGestureRecognizer *recognizer =
        [[TPKPlayerVerticalPanGestureRecognizer alloc]
        initWithTarget:handler action:@selector(handlePan:)];
    recognizer.delegate = delegate;
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesBegan = YES;
    recognizer.delaysTouchesEnded = YES;
    recognizer.minimumNumberOfTouches = 1;
    recognizer.maximumNumberOfTouches = 1;
    [view addGestureRecognizer:recognizer];

    objc_setAssociatedObject(view, &kTPKPlayerGestureRecognizerKey,
                             recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kTPKPlayerGestureDelegateKey,
                             delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kTPKPlayerGestureHandlerKey,
                             handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, &kTPKPlayerGestureBindingKey,
                             binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tpk_playerGesturePrioritizeDockGesture(recognizer, view);
    if (geometryView != view) {
        tpk_playerGesturePrioritizeDockGesture(recognizer, geometryView);
    }
}

static void tpk_playerGestureRemoveRecognizer(UIView *view) {
    tpk_playerGestureCancelVolumeDetach();
    tpk_playerGestureDetachVolumeView();
    UIPanGestureRecognizer *recognizer = objc_getAssociatedObject(
        view, &kTPKPlayerGestureRecognizerKey);
    if (!recognizer) return;
    recognizer.enabled = NO;
    [view removeGestureRecognizer:recognizer];
    objc_setAssociatedObject(view, &kTPKPlayerGestureRecognizerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL tpk_playerGestureIsControlsView(UIView *view) {
    Class controlsClass = tpk_playerGestureControlsClass();
    return view && controlsClass && view.class == controlsClass;
}

static UIView *tpk_playerGestureHostForControlsView(UIView *controlsView) {
    if (!controlsView) return nil;

    UIView *theaterView = nil;
    UIView *candidate = controlsView.superview;
    for (NSUInteger depth = 0;
         candidate && depth <= kTPKPlayerGestureMaxParentDepth + 4;
         depth++, candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                isEqualToString:kTPKPlayerTheaterViewClass]) {
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
         candidate && depth <= kTPKPlayerGestureMaxParentDepth + 4;
         depth++, candidate = candidate.superview) {
        if (tpk_playerGestureIsControlsView(candidate)) continue;
        if (CGRectGetWidth(candidate.bounds) > 0.0 &&
            CGRectGetHeight(candidate.bounds) > 0.0 &&
            candidate.window) {
            return candidate;
        }
    }

    return theaterView ?: controlsView.superview ?: controlsView;
}

static UIView *tpk_playerGestureGeometryForControlsView(UIView *controlsView,
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

UIView *tpk_playerGestureGeometryViewForControls(UIView *controlsView) {
    if (!controlsView) return nil;
    UIView *host = tpk_playerGestureHostForControlsView(controlsView);
    return tpk_playerGestureGeometryForControlsView(controlsView, host);
}

static void tpk_playerGestureRefreshExistingViews(void);

void tpk_handlePlayerGesturesViewLifecycle(UIView *view) {
    if (!view) return;

    // Detach arrives with window == nil, so count chrome before the early-return.
    UIWindow *countedControls = objc_getAssociatedObject(
        view, &kTPKPlayerGestureControlsWindowKey);
    if (countedControls ||
        [view.accessibilityIdentifier hasPrefix:@"player-controls-"]) {
        if (view.window) {
            tpk_playerGestureControlsAttach(view);
        } else {
            tpk_playerGestureControlsDetach(view);
        }
    }

    if (!view.window) return;

    BOOL legacyTarget = tpk_playerGestureIsControlsView(view);
    BOOL ivsTarget = tpk_playerGestureIsIVSPlayerView(view) &&
        tpk_playerGestureIsRealStreamIVSView(view);
    if (!legacyTarget && !ivsTarget) return;

    UIView *host = legacyTarget
        ? tpk_playerGestureHostForControlsView(view)
        : view.window;
    UIView *previousHost = objc_getAssociatedObject(
        view, &kTPKPlayerGestureHostKey);
    if (previousHost && previousHost != host) {
        tpk_playerGestureRemoveRecognizer(previousHost);
    }
    objc_setAssociatedObject(view, &kTPKPlayerGestureHostKey, host,
                             OBJC_ASSOCIATION_ASSIGN);

    UIView *geometryView = legacyTarget
        ? tpk_playerGestureGeometryForControlsView(view, host)
        : view;
    if (tpk_playerGesturesEnabled()) {
        tpk_playerGestureInstallRecognizer(host, geometryView);
    } else {
        tpk_playerGestureRemoveRecognizer(host);
    }
}

static void tpk_playerGestureVisitView(UIView *view) {
    if (!view) return;
    if (tpk_playerGestureIsControlsView(view) ||
        tpk_playerGestureIsIVSPlayerView(view)) {
        tpk_handlePlayerGesturesViewLifecycle(view);
    }
    for (UIView *subview in view.subviews) {
        tpk_playerGestureVisitView(subview);
    }
}

static void tpk_playerGestureRefreshExistingViews(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_playerGestureRefreshExistingViews();
        });
        return;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            // Always present on every window; geometry is resolved per touch.
            tpk_playerGestureInstallRecognizer(window, nil);
            tpk_playerGestureVisitView(window);
        }
    }
}

void tpk_playerGesturesSetup(void) {
    tpk_playerGesturesRegisterDefaults();
    tpk_playerGestureRegisterFakeBrightnessReset();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
                    tpk_playerGestureRefreshExistingViews();
                }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
                    tpk_playerGestureRefreshExistingViews();
                }];
    tpk_playerGestureRefreshExistingViews();
}
