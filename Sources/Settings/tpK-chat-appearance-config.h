#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const TPKChatAppearanceConfigDidChangeNotification;
FOUNDATION_EXPORT CGFloat TPKPickerOptionMinForKey(NSString *key);
FOUNDATION_EXPORT CGFloat TPKPickerOptionMaxForKey(NSString *key);
FOUNDATION_EXPORT NSString *TPKChatModerationDurationText(NSInteger totalSeconds);

typedef NS_ENUM(NSInteger, TPKDeletedMessageStyle) {
    TPKDeletedMessageStyleDimmed = 0,
    TPKDeletedMessageStyleStrikethrough,
    TPKDeletedMessageStyleDimmedAndStrikethrough,
};
typedef NS_ENUM(NSInteger, TPKDeletedMessageRevealMode) {
    TPKDeletedMessageRevealModeNever = 0,
    TPKDeletedMessageRevealModeOnTap,
    TPKDeletedMessageRevealModeAlways,
};

@interface TPKChatAppearanceConfig : NSObject
+ (instancetype)sharedConfig;
@property (nonatomic) BOOL nativeEmotesEnabled;
@property (nonatomic) BOOL pickerButtonEnabled;
@property (nonatomic) CGFloat pickerHeightPortrait;
@property (nonatomic) CGFloat pickerHeightLandscape;
@property (nonatomic) CGFloat pickerEmoteScalePortrait;
@property (nonatomic) CGFloat pickerEmoteScaleLandscape;
@property (nonatomic) NSInteger emoteImageResolution;
@property (nonatomic) BOOL showFirstMessageBadge;
@property (nonatomic, strong) UIColor *firstMessageHighlightColor;
@property (nonatomic) TPKDeletedMessageRevealMode deletedMessageRevealMode;
@property (nonatomic) TPKDeletedMessageStyle deletedMessageStyle;
@property (nonatomic) CGFloat deletedMessageTextOpacity;
- (void)reloadFromDefaults;
- (void)save;
- (void)setValue:(CGFloat)value forSizeKey:(NSString *)key;
- (void)setColor:(UIColor *)color forColorKey:(NSString *)key;
@end
NS_ASSUME_NONNULL_END
