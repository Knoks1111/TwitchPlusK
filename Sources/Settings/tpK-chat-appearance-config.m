#import "Settings/tpK-chat-appearance-config.h"
#import "Chat/Appearance/tpK-chat-event-appearance.h"
#import "Localization/tpK-localization-manager.h"
#import <math.h>

NSString *const TPKChatAppearanceConfigDidChangeNotification = @"TPKChatAppearanceConfigDidChangeNotification";

CGFloat TPKPickerOptionMinForKey(NSString *key) {
    return [key hasPrefix:@"pickerEmoteScale"] ? 0.5 : 120;
}
CGFloat TPKPickerOptionMaxForKey(NSString *key) {
    return [key hasPrefix:@"pickerEmoteScale"] ? 2 : ([key hasSuffix:@"Landscape"] ? 260 : 400);
}

@implementation TPKChatAppearanceConfig
+ (instancetype)sharedConfig {
    static TPKChatAppearanceConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) [self reloadFromDefaults];
    return self;
}
- (void)reloadFromDefaults {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    _nativeEmotesEnabled = [prefs objectForKey:@"tpk_native_chat_emotes_enabled"] ? [prefs boolForKey:@"tpk_native_chat_emotes_enabled"] : YES;
    _pickerButtonEnabled = [prefs objectForKey:@"tpk_picker_button_enabled"] ? [prefs boolForKey:@"tpk_picker_button_enabled"] : YES;
    _pickerHeightPortrait = [prefs objectForKey:@"tpk_cfg_picker_height_portrait"] ? [prefs doubleForKey:@"tpk_cfg_picker_height_portrait"] : 260;
    _pickerHeightLandscape = [prefs objectForKey:@"tpk_cfg_picker_height_landscape"] ? [prefs doubleForKey:@"tpk_cfg_picker_height_landscape"] : 160;
    _pickerEmoteScalePortrait = [prefs objectForKey:@"tpk_cfg_picker_emote_scale_portrait"] ? [prefs doubleForKey:@"tpk_cfg_picker_emote_scale_portrait"] : 1;
    _pickerEmoteScaleLandscape = [prefs objectForKey:@"tpk_cfg_picker_emote_scale_landscape"] ? [prefs doubleForKey:@"tpk_cfg_picker_emote_scale_landscape"] : 1;
    _pickerHeightPortrait = isfinite(_pickerHeightPortrait) ? MIN(400, MAX(120, _pickerHeightPortrait)) : 260;
    _pickerHeightLandscape = isfinite(_pickerHeightLandscape) ? MIN(260, MAX(120, _pickerHeightLandscape)) : 160;
    _pickerEmoteScalePortrait = isfinite(_pickerEmoteScalePortrait) ? MIN(2, MAX(0.5, _pickerEmoteScalePortrait)) : 1;
    _pickerEmoteScaleLandscape = isfinite(_pickerEmoteScaleLandscape) ? MIN(2, MAX(0.5, _pickerEmoteScaleLandscape)) : 1;
    NSString *resolutionKey = [prefs objectForKey:@"tpk_cfg_emote_resolution"] ? @"tpk_cfg_emote_resolution" : @"tpk_cfg_emote_7tv_resolution";
    _emoteImageResolution = [prefs objectForKey:resolutionKey] ? MIN(4, MAX(1, [prefs integerForKey:resolutionKey])) : 2;
    _showFirstMessageBadge = [prefs objectForKey:@"tpk_cfg_first_message_enabled"] ? [prefs boolForKey:@"tpk_cfg_first_message_enabled"] : YES;
    _firstMessageHighlightColor = TPKChatColorFromHexString([prefs stringForKey:@"tpk_cfg_color_first_message"]) ?: [UIColor colorWithRed:0.82 green:0.18 blue:0.86 alpha:1];
    _deletedMessageRevealMode = [prefs objectForKey:@"tpk_cfg_deleted_reveal_mode"] ? (TPKDeletedMessageRevealMode)MIN(2, MAX(0, [prefs integerForKey:@"tpk_cfg_deleted_reveal_mode"])) : TPKDeletedMessageRevealModeOnTap;
    _deletedMessageStyle = (TPKDeletedMessageStyle)MIN(2, MAX(0, [prefs integerForKey:@"tpk_cfg_deleted_message_style"]));
    _deletedMessageTextOpacity = [prefs objectForKey:@"tpk_cfg_deleted_message_opacity"] ? [prefs doubleForKey:@"tpk_cfg_deleted_message_opacity"] : 0.5;
    _deletedMessageTextOpacity = isfinite(_deletedMessageTextOpacity) ? MIN(1, MAX(0.25, _deletedMessageTextOpacity)) : 0.5;
}
- (void)save {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    [prefs setBool:self.nativeEmotesEnabled forKey:@"tpk_native_chat_emotes_enabled"];
    [prefs setBool:self.pickerButtonEnabled forKey:@"tpk_picker_button_enabled"];
    [prefs setDouble:self.pickerHeightPortrait forKey:@"tpk_cfg_picker_height_portrait"];
    [prefs setDouble:self.pickerHeightLandscape forKey:@"tpk_cfg_picker_height_landscape"];
    [prefs setDouble:self.pickerEmoteScalePortrait forKey:@"tpk_cfg_picker_emote_scale_portrait"];
    [prefs setDouble:self.pickerEmoteScaleLandscape forKey:@"tpk_cfg_picker_emote_scale_landscape"];
    [prefs setInteger:self.emoteImageResolution forKey:@"tpk_cfg_emote_resolution"];
    [prefs setBool:self.showFirstMessageBadge forKey:@"tpk_cfg_first_message_enabled"];
    [prefs setObject:TPKChatColorToHexString(self.firstMessageHighlightColor) forKey:@"tpk_cfg_color_first_message"];
    [prefs setInteger:self.deletedMessageRevealMode forKey:@"tpk_cfg_deleted_reveal_mode"];
    [prefs setInteger:self.deletedMessageStyle forKey:@"tpk_cfg_deleted_message_style"];
    [prefs setDouble:self.deletedMessageTextOpacity forKey:@"tpk_cfg_deleted_message_opacity"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:TPKChatAppearanceConfigDidChangeNotification object:self];
    });
}
- (void)setValue:(CGFloat)value forSizeKey:(NSString *)key {
    if (!isfinite(value)) return;
    if ([key isEqualToString:@"emoteImageResolution"]) value = MIN(4, MAX(1, round(value)));
    else if ([@[@"pickerHeightPortrait", @"pickerHeightLandscape", @"pickerEmoteScalePortrait", @"pickerEmoteScaleLandscape"] containsObject:key])
        value = MIN(TPKPickerOptionMaxForKey(key), MAX(TPKPickerOptionMinForKey(key), value));
    else return;
    [self setValue:@(value) forKey:key];
    [self save];
}
- (void)setColor:(UIColor *)color forColorKey:(NSString *)key {
    if (!color || ![key isEqualToString:@"firstMessageHighlightColor"]) return;
    self.firstMessageHighlightColor = color;
    [self save];
}
@end

NSString *TPKChatModerationDurationText(NSInteger totalSeconds) {
    totalSeconds = MAX(0, totalSeconds);
    if (totalSeconds == 0) return @"";

    NSInteger weeks = totalSeconds / (7 * 24 * 60 * 60);
    if (weeks > 0) {
        NSString *weekText = weeks == 1
            ? L(@"chat_duration_week_one")
            : [NSString stringWithFormat:L(@"chat_duration_weeks_format"), (long)weeks];
        NSInteger remainingSeconds = totalSeconds % (7 * 24 * 60 * 60);
        NSInteger remainingDays = remainingSeconds / (24 * 60 * 60);
        if (remainingDays > 0) {
            NSString *daysText = [NSString stringWithFormat:L(@"chat_duration_days_format"),
                                                           (long)remainingDays];
            return [NSString stringWithFormat:@"%@ %@", weekText, daysText];
        }
        NSInteger remainingHours = (remainingSeconds % (24 * 60 * 60)) / 3600;
        if (remainingHours > 0) {
            NSString *hoursText = [NSString stringWithFormat:L(@"chat_duration_hours_format"),
                                                               (long)remainingHours];
            return [NSString stringWithFormat:@"%@ %@", weekText, hoursText];
        }
        return weekText;
    }

    NSInteger days = totalSeconds / (24 * 60 * 60);
    if (days > 0) {
        NSString *daysText = [NSString stringWithFormat:L(@"chat_duration_days_format"),
                                                           (long)days];
        NSInteger hours = (totalSeconds % (24 * 60 * 60)) / 3600;
        return hours > 0
            ? [NSString stringWithFormat:@"%@ %@", daysText,
                [NSString stringWithFormat:L(@"chat_duration_hours_format"), (long)hours]]
            : daysText;
    }

    NSInteger hours = totalSeconds / 3600;
    if (hours > 0) {
        NSString *hoursText = [NSString stringWithFormat:L(@"chat_duration_hours_format"), (long)hours];
        NSInteger minutes = (totalSeconds % 3600) / 60;
        return minutes > 0
            ? [NSString stringWithFormat:@"%@ %@", hoursText,
                [NSString stringWithFormat:L(@"chat_duration_minutes_format"), (long)minutes]]
            : hoursText;
    }

    NSInteger minutes = totalSeconds / 60;
    if (minutes > 0) {
        NSString *minutesText = [NSString stringWithFormat:L(@"chat_duration_minutes_format"), (long)minutes];
        NSInteger seconds = totalSeconds % 60;
        return seconds > 0
            ? [NSString stringWithFormat:@"%@ %@", minutesText,
                [NSString stringWithFormat:L(@"chat_duration_seconds_format"), (long)seconds]]
            : minutesText;
    }
    return [NSString stringWithFormat:L(@"chat_duration_seconds_format"), (long)totalSeconds];
}
