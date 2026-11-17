#import "Chat/Appearance/tpK-chat-event-appearance.h"
#import "Localization/tpK-localization-manager.h"
#import <math.h>
#import <string.h>

NSString *const TPKChatEventAppearanceDidChangeNotification = @"TPKChatEventAppearanceDidChange";
const CGFloat TPKChatHighlightBackgroundOpacity = 0.12;

TPKChatEventGroup TPKChatEventGroupForIdentifier(const char *identifier) {
    if (!identifier) return TPKChatEventGroupNone;
    static const struct { const char *identifier; TPKChatEventGroup group; } containers[] = {
        {"chat-subscription-line", TPKChatEventGroupSubscriptions},
        {"chat-resub-line", TPKChatEventGroupSubscriptions},
        {"chat-extendsub-line", TPKChatEventGroupSubscriptions},
        {"chat-primepaidupgrade-line", TPKChatEventGroupSubscriptions},
        {"chat-subgift-line", TPKChatEventGroupGifts},
        {"chat-communitygift-line", TPKChatEventGroupGifts},
        {"chat-giftpaidupgrade-line", TPKChatEventGroupGifts},
        {"chat-payforward-line", TPKChatEventGroupGifts},
        {"chat-firstcheer-line", TPKChatEventGroupBits},
        {"chat-bitsbadgetier-line", TPKChatEventGroupBits},
        {"chat-powercheer-line", TPKChatEventGroupBits},
        {"chat-channelpointsreward-line", TPKChatEventGroupPoints},
        {"chat-communitychallengecontribution-line", TPKChatEventGroupPoints},
        {"chat-rewardgift-line", TPKChatEventGroupPoints},
        {"chat-raid-line", TPKChatEventGroupRaids},
        {"chat-unraid-line", TPKChatEventGroupRaids},
        {"chat-announcement-line", TPKChatEventGroupAnnouncements},
        {"chat-viewermilestone-line", TPKChatEventGroupMilestones},
        {"chat-charitydonation-line", TPKChatEventGroupOther},
        {"chat-modiversary-line", TPKChatEventGroupOther},
        {"chat-creatorgoal-line", TPKChatEventGroupOther},
        {"tpk-deleted-message", TPKChatEventGroupDeleted},
    };
    for (size_t index = 0; index < sizeof(containers) / sizeof(containers[0]); index++) {
        if (strcmp(identifier, containers[index].identifier) == 0) return containers[index].group;
    }
    return TPKChatEventGroupNone;
}

static NSInteger TPKChatBackgroundSource(TPKChatEventGroup group, BOOL customEnabled, BOOL oled) {
    if (group < 0 || group >= TPKChatEventGroupCount) return 0;
    if (group == TPKChatEventGroupDeleted && !customEnabled) return 0;
    return customEnabled ? 2 : oled ? 1 : 0;
}

NSString *TPKChatColorToHexString(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        if (![color getWhite:&r alpha:&a]) return @"FFFFFFFF";
        g = b = r;
    }
    return [NSString stringWithFormat:@"%02lX%02lX%02lX%02lX",
        (long)lround(r * 255), (long)lround(g * 255), (long)lround(b * 255), (long)lround(a * 255)];
}

UIColor *TPKChatColorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:NSString.class] || (hex.length != 6 && hex.length != 8)) return nil;
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
    if (hex.length == 6) value = (value << 8) | 255;
    return [UIColor colorWithRed:((value >> 24) & 255) / 255.0 green:((value >> 16) & 255) / 255.0
                           blue:((value >> 8) & 255) / 255.0 alpha:(value & 255) / 255.0];
}

void TPKChatAttachColorControl(UITableViewCell *cell, UIColor *color, id target, SEL action) {
    UISwitch *toggle = nil;
    UILabel *label = nil;
    for (UIView *view in cell.contentView.subviews) {
        if ([view isKindOfClass:UISwitch.class]) toggle = (UISwitch *)view;
        if ([view isKindOfClass:UILabel.class]) label = (UILabel *)view;
    }
    if (!toggle || !label) return;
    UIColorWell *well = [[UIColorWell alloc] init];
    well.supportsAlpha = NO;
    well.selectedColor = color;
    well.tag = toggle.tag;
    well.accessibilityLabel = [NSString stringWithFormat:@"%@ — %@", label.text, L(@"appearance_color")];
    well.translatesAutoresizingMaskIntoConstraints = NO;
    [well addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:well];
    [NSLayoutConstraint activateConstraints:@[
        [well.widthAnchor constraintEqualToConstant:32], [well.heightAnchor constraintEqualToConstant:32],
        [well.trailingAnchor constraintEqualToAnchor:toggle.leadingAnchor constant:-12],
        [well.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:well.leadingAnchor constant:-12],
    ]];
}

static NSArray<NSString *> *TPKGroupKeys(void) {
    return @[@"subscriptions", @"gifts", @"bits", @"points", @"raids", @"announcements", @"milestones", @"other", @"deleted"];
}

static NSArray<NSDictionary *> *TPKGroupSettings;

@implementation TPKChatEventAppearance
+ (void)reload {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"tpk_chat_event_backgrounds"];
    NSMutableArray *settings = [NSMutableArray arrayWithCapacity:TPKChatEventGroupCount];
    for (NSString *key in TPKGroupKeys()) {
        NSDictionary *entry = [stored[key] isKindOfClass:NSDictionary.class] ? stored[key] : @{};
        UIColor *color = TPKChatColorFromHexString(entry[@"color"]) ?: [UIColor colorWithWhite:8.0 / 255.0 alpha:1];
        BOOL enabled = [entry[@"enabled"] respondsToSelector:@selector(boolValue)] && [entry[@"enabled"] boolValue];
        [settings addObject:@{@"color":color, @"enabled":@(enabled)}];
    }
    TPKGroupSettings = settings.copy;
    [NSNotificationCenter.defaultCenter postNotificationName:TPKChatEventAppearanceDidChangeNotification object:nil];
}
+ (NSDictionary *)settingsForGroup:(TPKChatEventGroup)group {
    if (!TPKGroupSettings) [self reload];
    return group >= 0 && group < TPKChatEventGroupCount ? TPKGroupSettings[group] : nil;
}
+ (BOOL)enabledForGroup:(TPKChatEventGroup)group { return [[self settingsForGroup:group][@"enabled"] boolValue]; }
+ (UIColor *)colorForGroup:(TPKChatEventGroup)group { return [self settingsForGroup:group][@"color"]; }
+ (BOOL)hasCustomBackgrounds {
    for (NSInteger group = 0; group < TPKChatEventGroupCount; group++) if ([self enabledForGroup:group]) return YES;
    return NO;
}
+ (UIColor *)backgroundForGroup:(TPKChatEventGroup)group oled:(BOOL)oled {
    NSInteger source = TPKChatBackgroundSource(group, [self enabledForGroup:group], oled);
    if (source == 2) {
        UIColor *color = [[self colorForGroup:group] resolvedColorWithTraitCollection:
            [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
        return [color colorWithAlphaComponent:CGColorGetAlpha(color.CGColor) * TPKChatHighlightBackgroundOpacity];
    }
    return source == 1 ? [UIColor colorWithWhite:8.0 / 255.0 alpha:1] : nil;
}
+ (void)saveGroup:(TPKChatEventGroup)group color:(UIColor *)color enabled:(BOOL)enabled {
    if (group < 0 || group >= TPKChatEventGroupCount || !color) return;
    NSMutableArray *settings = [TPKGroupSettings mutableCopy];
    settings[group] = @{@"color":color, @"enabled":@(enabled)};
    TPKGroupSettings = settings.copy;
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    [TPKGroupKeys() enumerateObjectsUsingBlock:^(NSString *key, NSUInteger index, BOOL *stop) {
        NSDictionary *entry = TPKGroupSettings[index];
        stored[key] = @{@"color":TPKChatColorToHexString(entry[@"color"]), @"enabled":entry[@"enabled"]};
    }];
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:@"tpk_chat_event_backgrounds"];
    [NSNotificationCenter.defaultCenter postNotificationName:TPKChatEventAppearanceDidChangeNotification object:nil];
}
+ (NSString *)titleForGroup:(TPKChatEventGroup)group {
    NSArray *keys = @[@"event_color_subscriptions", @"event_color_gifts", @"event_color_bits", @"event_color_points",
        @"event_color_raids", @"event_color_announcements", @"event_color_milestones", @"event_color_other", @"sizes_moderation_section_title"];
    return L(keys[group]);
}
+ (NSString *)iconForGroup:(TPKChatEventGroup)group {
    return @[@"crown", @"gift", @"sparkles", @"star.circle", @"person.3", @"megaphone", @"flame", @"bell", @"trash"][group];
}
+ (UIColor *)tintForGroup:(TPKChatEventGroup)group {
    return @[UIColor.systemPurpleColor, UIColor.systemPinkColor, UIColor.systemOrangeColor, UIColor.systemTealColor,
        UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.systemYellowColor, UIColor.systemIndigoColor, UIColor.systemRedColor][group];
}
+ (void)configureCell:(UITableViewCell *)cell forGroup:(TPKChatEventGroup)group {
    for (UIView *view in cell.contentView.subviews) if ([view isKindOfClass:UISwitch.class]) view.tag = group;
    TPKChatAttachColorControl(cell, [self colorForGroup:group], self, @selector(colorChanged:));
}
+ (void)toggleGroup:(UISwitch *)toggle {
    [self saveGroup:toggle.tag color:[self colorForGroup:toggle.tag] enabled:toggle.isOn];
}
+ (void)colorChanged:(UIColorWell *)well {
    [self saveGroup:well.tag color:well.selectedColor enabled:[self enabledForGroup:well.tag]];
}
@end
