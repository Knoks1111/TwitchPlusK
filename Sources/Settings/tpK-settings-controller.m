// TwitchPlusK settings UI.

#import "Settings/tpK-settings-controller.h"
#import "Core/tpK-core-manager.h"
#import "Core/tpK-channel-resolver.h"
#import "Logs/tpK-logs-controller.h"
#import "Emote/tpK-network-emote-cache.h"
#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-provider-settings.h"
#import "Picker/tpK-picker-resolved-emote.h"
#import "UI/7tv-ui-logo.h"
#import "UI/tpK-ui-logo.h"
#import "UI/bttv-ui-logo.h"
#import "UI/ffz-ui-logo.h"
#import "Chat/tpK-chat-appearance-config.h"
#import "Localization/tpK-localization-manager.h"
#import "System/tpK-system-native-behavior-hooks.h"
#import "System/tpK-system-player-gestures.h"
#import "System/tpK-system-player-reload.h"
#import "System/tpK-system-autoclaim.h"
#import "System/tpK-system-home-features.h"
#import "System/tpK-system-tab-visibility.h"
#import "Adblock/tpK-adblock-settings.h"
#import "Adblock/Emote/tpK-adblock-emote-proxy.h"
#import "Adblock/Combo/tpK-adblock-combo.h"
#import "Adblock/Proxy/tpK-adblock-proxy-status.h"
#import "Settings/tpK-hook-diagnostics.h"
#import "Settings/tpK-settings-transfer.h"
#import "UI/tpK-info-tooltip.h"
#import "UI/tpK-oled-mode.h"
#import "Adblock/Vaft/tpK-adblock-vaft.h"
#import <objc/runtime.h>
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"
static NSString *const kTPKFavoriteEmoteNamesKey = @"tpk_favorite_emote_names";
static NSString *const kTPKGitHubURL = @"https://github.com/Knoks1111/TwitchPlusK";
static NSString *const kTPKGitHubAvatarURL = @"https://github.com/Knoks1111.png?size=96";

// MARK: - Palette couleurs

// Main background; OLED uses pure black.
static UIColor *TPKBg(void) {
    if (TPKOLEDModeEnabled()) return UIColor.blackColor;
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}

// Cell background; keep grouped cells visible in OLED mode.
static UIColor *TPKCellBg(void) {
    if (TPKOLEDModeEnabled()) return [UIColor colorWithWhite:0.05 alpha:1.0];
    return [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23
}

// Table separators.
static UIColor *TPKSeparatorColor(void) {
    if (TPKOLEDModeEnabled()) return [UIColor colorWithWhite:0.12 alpha:1.0];
    return [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}

// Accent violet.
UIColor *TPKAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // #8E45E0
}

// Secondary gray.
static UIColor *TPKGray(void) {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

// Synchronises switch-icon color with its state.
static UIColor *TPKSwitchIconColor(UIColor *onColor, BOOL isOn) {
    return isOn ? onColor : [UIColor systemGrayColor];
}

// Builds visible rows from fixed and conditional logical indexes.
// Hidden child rows keep their stored defaults and are removed without animation.

// fixed = always visible rows; conditional = parent-dependent rows.
static NSArray<NSNumber *> *TPKVisibleRowIndexes(NSArray<NSNumber *> *fixed,
                                                  NSDictionary<NSNumber *, NSNumber *> *conditional) {
    NSMutableArray<NSNumber *> *visible = [fixed mutableCopy];
    for (NSNumber *row in conditional) {
        if (conditional[row].boolValue) [visible addObject:row];
    }
    return [visible sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
}

// Updates one row without rebuilding the header or shifting the table offset.
static void TPKReloadCellWithoutJump(UITableView *tableView, UIView *anchor) {
    if (!tableView || ![anchor isKindOfClass:UITableViewCell.class]) return;
    NSIndexPath *indexPath = [tableView indexPathForCell:(UITableViewCell *)anchor];
    if (!indexPath) return;

    CGPoint contentOffset = tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [tableView reloadRowsAtIndexPaths:@[indexPath]
                         withRowAnimation:UITableViewRowAnimationNone];
        [tableView layoutIfNeeded];
    }];
    [tableView setContentOffset:contentOffset animated:NO];
}

// Reloads a variable-length section without animation or scroll jumps.
static void TPKReloadSectionWithoutJump(UITableView *tableView, NSInteger section) {
    if (!tableView || section < 0 || section >= tableView.numberOfSections) return;
    CGPoint contentOffset = tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                  withRowAnimation:UITableViewRowAnimationNone];
        [tableView layoutIfNeeded];
    }];
    [tableView setContentOffset:contentOffset animated:NO];
}

// Reloads the table when a choice changes its section structure.
static void TPKReloadDataWithoutJump(UITableView *tableView) {
    if (!tableView) return;
    CGPoint contentOffset = tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [tableView reloadData];
        [tableView layoutIfNeeded];
    }];
    [tableView setContentOffset:contentOffset animated:NO];
}

// Reloads one dependent section after a parent switch.
static void TPKReloadSection(UITableView *tableView, NSInteger section) {
    TPKReloadSectionWithoutJump(tableView, section);
}

@interface TPKSettingsResolvedEmote : NSObject <TPKResolvedEmote>
@property (nonatomic, copy) NSString *emoteID;
@property (nonatomic, assign) CGSize nativeSize;
@property (nonatomic, assign) BOOL isAnimated;
@property (nonatomic, strong) NSURL *imageURL;
+ (instancetype)emoteWithID:(NSString *)emoteID;
@end

@implementation TPKSettingsResolvedEmote
+ (instancetype)emoteWithID:(NSString *)emoteID {
    TPKSettingsResolvedEmote *emote = [TPKSettingsResolvedEmote new];
    emote.emoteID = emoteID;
    emote.nativeSize = CGSizeMake(32.0, 32.0);
    emote.isAnimated = NO; // Les réglages n'affichent que la première frame.
    NSInteger resolution = [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
    resolution = MIN(4, MAX(1, resolution));
    emote.imageURL = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)resolution]];
    return emote;
}
@end

static void TPKLoadSettingsEmoteImage(NSString *emoteID, UIImageView *imageView) {
    if (!emoteID.length || !imageView) return;
    imageView.accessibilityIdentifier = emoteID;
    imageView.image = nil;
    TPKSettingsResolvedEmote *emote = [TPKSettingsResolvedEmote emoteWithID:emoteID];
    UIImage *cached = [[TPKEmoteImageCache sharedCache] cachedImageForResolvedEmote:emote];
    if (cached) {
        imageView.image = cached;
        return;
    }
    __weak UIImageView *weakImageView = imageView;
    [[TPKEmoteImageCache sharedCache] imageForResolvedEmote:emote completion:^(UIImage *image) {
        UIImageView *strongImageView = weakImageView;
        if ([strongImageView.accessibilityIdentifier isEqualToString:emoteID]) {
            strongImageView.image = image;
        }
    }];
}

// Favorite keys include their provider; reject malformed export values.
static BOOL TPKSettingsParseFavoriteKey(NSString *key,
                                         TPKEmoteProviderID *provider,
                                         NSString **emoteID) {
    if (!key.length) return NO;
    NSRange separator = [key rangeOfString:@":" options:0
                                     range:NSMakeRange(0, key.length)];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location >= key.length - 1) return NO;
    NSString *prefix = [[key substringToIndex:separator.location] lowercaseString];
    TPKEmoteProviderID parsedProvider;
    if ([prefix isEqualToString:@"7tv"]) parsedProvider = TPKEmoteProviderIDTPK;
    else if ([prefix isEqualToString:@"bttv"]) parsedProvider = TPKEmoteProviderIDBTTV;
    else if ([prefix isEqualToString:@"ffz"]) parsedProvider = TPKEmoteProviderIDFFZ;
    else return NO;
    if (provider) *provider = parsedProvider;
    if (emoteID) *emoteID = [key substringFromIndex:separator.location + 1];
    return YES;
}

static NSString *TPKSettingsCanonicalFavoriteKey(NSString *key) {
    if (!key.length) return nil;
    TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
    NSString *emoteID = nil;
    if (TPKSettingsParseFavoriteKey(key, &provider, &emoteID))
        return TPKEmoteFavoriteKey(provider, emoteID);
    // Accept legacy bare 7TV IDs during import.
    if (![key containsString:@":"])
        return TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, key);
    return nil;
}

// Settings adapter for provider-specific CDN URLs and resolutions.
@interface TPKSettingsCatalogResolvedEmote : NSObject <TPKResolvedEmote>
@property (nonatomic, strong) TPKEmoteDescriptor *descriptor;
@end

@implementation TPKSettingsCatalogResolvedEmote
- (NSString *)emoteID {
    return TPKEmoteFavoriteKey(self.descriptor.provider, self.descriptor.emoteID);
}
- (CGSize)nativeSize { return self.descriptor.nativeSize; }
- (BOOL)isAnimated { return self.descriptor.animated; }
- (NSURL *)imageURL {
    return [self.descriptor imageURLForResolution:
        [TPKChatAppearanceConfig sharedConfig].emoteImageResolution];
}
@end

static void TPKLoadSettingsCatalogEmoteImage(TPKEmoteDescriptor *descriptor,
                                               UIImageView *imageView) {
    if (!descriptor || !descriptor.emoteID.length || !imageView) return;
    NSString *key = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
    imageView.accessibilityIdentifier = key;
    imageView.image = nil;

    TPKSettingsCatalogResolvedEmote *resolved = [TPKSettingsCatalogResolvedEmote new];
    resolved.descriptor = descriptor;
    UIImage *cached = [[TPKEmoteImageCache sharedCache]
        cachedImageForResolvedEmote:resolved];
    if (cached) {
        imageView.image = cached;
        return;
    }
    __weak UIImageView *weakImageView = imageView;
    [[TPKEmoteImageCache sharedCache] imageForResolvedEmote:resolved
        completion:^(UIImage *image) {
        UIImageView *strongImageView = weakImageView;
        if ([strongImageView.accessibilityIdentifier isEqualToString:key])
            strongImageView.image = image;
    }];
}

static TPKEmoteDescriptor *TPKSettingsDescriptorForFavoriteKey(NSString *key) {
    TPKEmoteProviderID provider;
    NSString *emoteID = nil;
    if (!TPKSettingsParseFavoriteKey(key, &provider, &emoteID)) return nil;
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    for (TPKEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        if (descriptor.provider == provider &&
            [descriptor.emoteID isEqualToString:emoteID]) return descriptor;
    }
    for (TPKEmoteDescriptor *descriptor in [catalog allEmotesForProvider:provider]) {
        if ([descriptor.emoteID isEqualToString:emoteID]) return descriptor;
    }
    return nil;
}

static UIView *TPKFavoriteEmotePreview(NSArray<NSString *> *favoriteIDs) {
    UIView *preview = [[UIView alloc] init];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    NSUInteger count = MIN((NSUInteger)3, favoriteIDs.count);
    CGFloat width = count > 0 ? 26.0 + (count - 1) * 13.0 : 22.0;
    [NSLayoutConstraint activateConstraints:@[
        [preview.widthAnchor constraintEqualToConstant:width],
        [preview.heightAnchor constraintEqualToConstant:30.0],
    ]];
    for (NSUInteger index = 0; index < count; index++) {
        UIImageView *imageView = [[UIImageView alloc] init];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [preview addSubview:imageView];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.leadingAnchor constraintEqualToAnchor:preview.leadingAnchor constant:index * 13.0],
            [imageView.centerYAnchor constraintEqualToAnchor:preview.centerYAnchor],
            [imageView.widthAnchor constraintEqualToConstant:26.0],
            [imageView.heightAnchor constraintEqualToConstant:26.0],
        ]];
        NSString *rawKey = favoriteIDs[index];
        NSString *favoriteKey = TPKSettingsCanonicalFavoriteKey(rawKey);
        if (!favoriteKey.length) continue;
        TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
        NSString *emoteID = nil;
        BOOL qualified = TPKSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
        TPKEmoteDescriptor *descriptor =
            TPKSettingsDescriptorForFavoriteKey(favoriteKey);
        if (descriptor) TPKLoadSettingsCatalogEmoteImage(descriptor, imageView);
        else if (provider == TPKEmoteProviderIDTPK || !qualified)
            TPKLoadSettingsEmoteImage(emoteID ?: rawKey, imageView);
    }
    return preview;
}


// MARK: - Helpers UI

// SF Symbol icon view.
static UIImageView *TPKIcon(NSString *sfName, UIColor *tint) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:sfName withConfiguration:cfg];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = tint;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor  constraintEqualToConstant:22],
        [iv.heightAnchor constraintEqualToConstant:22],
    ]];
    return iv;
}

// Standard settings cell with icon, title, optional subtitle and info button.
static UITableViewCell *TPKNavCell(NSString *title,
                                     NSString *subtitle,
                                     NSString *sfName,
                                     UIColor  *iconTint,
                                     NSString *infoKey) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = TPKCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = TPKIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    // Match native Twitch settings typography.
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.numberOfLines = 1;
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *infoButton = infoKey.length > 0
        ? [TPKInfoTooltip infoButtonWithKey:infoKey] : nil;

    // Keep the info button inside contentView, before the accessory.
    if (infoButton) {
        infoButton.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:infoButton];
        [NSLayoutConstraint activateConstraints:@[
            [infoButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-4],
            [infoButton.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    if (subtitle.length > 0) {
        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.text = subtitle;
        // Subtitle styling.
        subLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subLbl.textColor = TPKGray();
        subLbl.numberOfLines = 0;
        subLbl.lineBreakMode = NSLineBreakByWordWrapping;
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;

        // Center the title/subtitle stack.
        UIStackView *stack = [[UIStackView alloc]
            initWithArrangedSubviews:@[titleLbl, subLbl]];
        stack.axis      = UILayoutConstraintAxisVertical;
        stack.spacing   = 2;
        stack.alignment = UIStackViewAlignmentLeading;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [stack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            // Keep the stack inside the cell.
            [stack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
            [stack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
        if (infoButton) {
            [NSLayoutConstraint activateConstraints:@[
                [stack.trailingAnchor constraintLessThanOrEqualToAnchor:infoButton.leadingAnchor constant:-4],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            ]];
        }
    } else {
        [cell.contentView addSubview:titleLbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
            // Sans sous-titre, la contrainte d'axe manquait : un titre long
            // débordait vers la gauche, hors de la cellule.
            [titleLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            // Required vertical constraints resolve multi-line labels.
            [titleLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [titleLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        if (infoButton) {
            [NSLayoutConstraint activateConstraints:@[
                [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:infoButton.leadingAnchor constant:-4],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [titleLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            ]];
        }
    }
    return cell;
}

// Ligne d'explication permanente d'un écran de réglages : le texte est relu via
// sa clé à chaque construction de cellule, donc à jour après un changement de langue.
static UITableViewCell *TPKDescriptionCell(NSString *key) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = TPKCellBg();

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(key);
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = UIColor.whiteColor;
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [lbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
    ]];
    return cell;
}

static void TPKLoadGitHubAvatar(UIImageView *imageView) {
    NSURL *url = [NSURL URLWithString:kTPKGitHubAvatarURL];
    __weak UIImageView *weakImageView = imageView;
    [[[NSURLSession sharedSession] dataTaskWithURL:url
                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *view = weakImageView;
            if (view) view.image = image;
        });
    }] resume];
}

static UITableViewCell *TPKGitHubRepositoryCell(void) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = TPKCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageSymbolConfiguration *starConfig = [UIImageSymbolConfiguration
        configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    UIImageView *star = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"star" withConfiguration:starConfig]];
    star.tintColor = TPKAccent();
    star.frame = CGRectMake(0, 0, 22, 22);
    cell.accessoryView = star;

    UIView *avatarRing = [[UIView alloc] init];
    avatarRing.translatesAutoresizingMaskIntoConstraints = NO;
    avatarRing.layer.cornerRadius = 19;
    avatarRing.layer.borderWidth = 2;
    avatarRing.layer.borderColor = TPKAccent().CGColor;
    avatarRing.clipsToBounds = YES;

    UIImageView *avatar = [[UIImageView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.layer.cornerRadius = 16;
    avatar.clipsToBounds = YES;
    [avatarRing addSubview:avatar];
    [cell.contentView addSubview:avatarRing];

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"settings_github_title");
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    title.textColor = UIColor.whiteColor;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = L(@"settings_github_subtitle");
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitle.textColor = TPKGray();
    subtitle.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [avatarRing.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:8],
        [avatarRing.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [avatarRing.widthAnchor constraintEqualToConstant:38],
        [avatarRing.heightAnchor constraintEqualToConstant:38],
        [avatar.leadingAnchor constraintEqualToAnchor:avatarRing.leadingAnchor constant:3],
        [avatar.trailingAnchor constraintEqualToAnchor:avatarRing.trailingAnchor constant:-3],
        [avatar.topAnchor constraintEqualToAnchor:avatarRing.topAnchor constant:3],
        [avatar.bottomAnchor constraintEqualToAnchor:avatarRing.bottomAnchor constant:-3],
        [stack.leadingAnchor constraintEqualToAnchor:avatarRing.trailingAnchor constant:6],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
        [stack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];
    TPKLoadGitHubAvatar(avatar);
    return cell;
}

// Choice cell with the current value on the right.
static UITableViewCell *TPKRightValueNavCell(NSString *title,
                                               NSString *value,
                                               NSString *sfName,
                                               UIColor *iconTint) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = TPKCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = TPKIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.numberOfLines = 1;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    valueLabel.textColor = TPKGray();
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.numberOfLines = 1;
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:valueLabel];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                            constant:16.0],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                                   constant:14.0],
        [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                    constant:-8.0],
        [valueLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:valueLabel.leadingAnchor
                                                              constant:-8.0],
    ]];
    return cell;
}

static char kTPKSwitchOnColorKey;

// Keeps a switch icon synchronized immediately after toggling.
@interface TPKSwitchIconUpdater : NSObject
+ (void)tpk_switchValueChanged:(UISwitch *)sw;
@end

@implementation TPKSwitchIconUpdater
+ (void)tpk_switchValueChanged:(UISwitch *)sw {
    UIView *view = sw;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    UITableViewCell *cell = (UITableViewCell *)view;
    if (!cell) return;

    UIImageView *icon = nil;
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UIImageView class]]) {
            icon = (UIImageView *)subview;
            break;
        }
    }
    if (!icon) return;

    UIColor *onColor = objc_getAssociatedObject(sw, &kTPKSwitchOnColorKey);
    if (!onColor) onColor = [UIColor systemGrayColor];
    icon.tintColor = sw.isOn ? onColor : [UIColor systemGrayColor];
}
@end

// Cell with a UISwitch and optional info button.
static UITableViewCell *TPKSwitchCell(NSString *title,
                                        NSString *sfName,
                                        UIColor  *iconTint,
                                        BOOL      isOn,
                                        id        target,
                                        SEL       action,
                                        NSString *infoKey) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = TPKCellBg();

    UIImageView *icon = TPKIcon(sfName, TPKSwitchIconColor(iconTint, isOn));
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    // Match native settings typography.
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor];
    // Allow long titles to wrap; callers provide automatic row height.
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on          = isOn;
    sw.onTintColor = TPKAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    // Icon color follows the switch state.
    objc_setAssociatedObject(sw, &kTPKSwitchOnColorKey, iconTint,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:[TPKSwitchIconUpdater class]
           action:@selector(tpk_switchValueChanged:)
 forControlEvents:UIControlEventValueChanged];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:sw];

    UIButton *infoButton = infoKey.length > 0
        ? [TPKInfoTooltip infoButtonWithKey:infoKey] : nil;
    if (infoButton) {
        infoButton.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:infoButton];
    }

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],

        // Fix the switch to the trailing edge; do not constrain its leading edge.
        [sw.trailingAnchor   constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [sw.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],

        // Bound the label by the switch so long text cannot move the switch.
        [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:13],
        [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-13],
    ]];

    if (infoButton) {
        [NSLayoutConstraint activateConstraints:@[
            [infoButton.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-6],
            [infoButton.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.trailingAnchor       constraintLessThanOrEqualToAnchor:infoButton.leadingAnchor constant:-4],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-12],
        ]];
    }
    return cell;
}

static char kTPKPlayerGestureSensitivityValueLabelKey;

// Sensitivity row with minus/plus controls.
static UITableViewCell *TPKPlayerGestureSensitivityCell(CGFloat value,
                                                          id target) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = TPKCellBg();

    UIImageView *icon = TPKIcon(@"speedometer", [UIColor colorWithRed:1.0 green:0.45 blue:0.35 alpha:1.0]);
    [cell.contentView addSubview:icon];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = L(@"player_gestures_sensitivity");
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:titleLabel];

    UIButton *minusButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButton *plusButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *buttonConfig = [UIImageSymbolConfiguration
        configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    [minusButton setImage:[UIImage systemImageNamed:@"minus"
                                  withConfiguration:buttonConfig]
                 forState:UIControlStateNormal];
    [plusButton setImage:[UIImage systemImageNamed:@"plus"
                                 withConfiguration:buttonConfig]
                forState:UIControlStateNormal];
    minusButton.tintColor = TPKAccent();
    plusButton.tintColor = TPKAccent();
    minusButton.accessibilityLabel = L(@"player_gestures_sensitivity_decrease");
    plusButton.accessibilityLabel = L(@"player_gestures_sensitivity_increase");
    minusButton.translatesAutoresizingMaskIntoConstraints = NO;
    plusButton.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
    valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    valueLabel.textColor = TPKGray();
    valueLabel.textAlignment = NSTextAlignmentCenter;
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:valueLabel];

    objc_setAssociatedObject(minusButton,
                             &kTPKPlayerGestureSensitivityValueLabelKey,
                             valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(plusButton,
                             &kTPKPlayerGestureSensitivityValueLabelKey,
                             valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [minusButton addTarget:target
                    action:@selector(playerGestureSensitivityDecrease:)
          forControlEvents:UIControlEventTouchUpInside];
    [plusButton addTarget:target
                   action:@selector(playerGestureSensitivityIncrease:)
         forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:minusButton];
    [cell.contentView addSubview:plusButton];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                            constant:16.0],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                                   constant:14.0],
        [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [plusButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                    constant:-12.0],
        [plusButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [plusButton.widthAnchor constraintEqualToConstant:30.0],
        [plusButton.heightAnchor constraintEqualToConstant:34.0],
        [valueLabel.trailingAnchor constraintEqualToAnchor:plusButton.leadingAnchor
                                                    constant:0.0],
        [valueLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [valueLabel.widthAnchor constraintEqualToConstant:30.0],
        [minusButton.trailingAnchor constraintEqualToAnchor:valueLabel.leadingAnchor
                                                     constant:0.0],
        [minusButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [minusButton.widthAnchor constraintEqualToConstant:30.0],
        [minusButton.heightAnchor constraintEqualToConstant:34.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:minusButton.leadingAnchor
                                                              constant:-8.0],
    ]];
    return cell;
}

// Twitch-style section header with optional logo and info button.
static UIView *TPKSectionHeader(NSString *title, BOOL withLogo, NSString *infoKey) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title.uppercaseString;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

    UIButton *infoButton = infoKey.length > 0
        ? [TPKInfoTooltip infoButtonWithKey:infoKey] : nil;
    if (infoButton) {
        infoButton.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:infoButton];
    }

    if (withLogo) {
        // TwitchPlusK logo.
        NSData *logoData = [[NSData alloc]
            initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *logoImg = [UIImage imageWithData:logoData scale:2.0];

        if (logoImg) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:logoImg];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [container addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
                [iv.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
                [iv.widthAnchor    constraintEqualToConstant:18],
                [iv.heightAnchor   constraintEqualToConstant:14],

                [lbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
                [lbl.bottomAnchor  constraintEqualToAnchor:container.bottomAnchor constant:-8],
                [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-16],
            ]];
            if (infoButton) {
                [NSLayoutConstraint activateConstraints:@[
                    [infoButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
                    [infoButton.centerYAnchor  constraintEqualToAnchor:lbl.centerYAnchor],
                    [lbl.trailingAnchor       constraintLessThanOrEqualToAnchor:infoButton.leadingAnchor constant:-4],
                ]];
            }
            return container;
        }
    }

    // Text-only header.
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];
    if (infoButton) {
        [NSLayoutConstraint activateConstraints:@[
            [infoButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
            [infoButton.centerYAnchor  constraintEqualToAnchor:lbl.centerYAnchor],
            [lbl.trailingAnchor       constraintLessThanOrEqualToAnchor:infoButton.leadingAnchor constant:-4],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        ]];
    }
    return container;
}

// MARK: - Méthode utilitaire commune pour styleTableView

static void TPKStyleTableView(UITableView *tv) {
    tv.backgroundColor   = TPKBg();
    tv.separatorColor    = TPKSeparatorColor();
    tv.separatorInset    = UIEdgeInsetsMake(0, 52, 0, 0);
    // Default to content-driven row heights; controllers can override.
    tv.rowHeight         = UITableViewAutomaticDimension;
    tv.estimatedRowHeight = 60;
}

// Re-style and reload settings screens after an OLED-mode change.
static void TPKApplyOLEDStyle(UITableViewController *controller) {
    TPKStyleTableView(controller.tableView);
    TPKReloadDataWithoutJump(controller.tableView);
}

// Registers the shared OLED-mode observer for a settings controller.
static void TPKRegisterOLEDObserver(id observer) {
    [[NSNotificationCenter defaultCenter] addObserver:observer
        selector:@selector(tpk_oledModeDidChange)
            name:TPKOLEDModeDidChangeNotification object:nil];
}

// Reads a boolean preference with an explicit default value.
static BOOL TPKBoolDefaultYes(NSString *key) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    return [prefs objectForKey:key] != nil ? [prefs boolForKey:key] : YES;
}
static void TPKSetBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Mirrors the default emote resolution from the appearance config.
static const NSInteger kTPKDefaultEmoteResolution = 2;

// Adds a default-value suffix to choice subtitles when useful.
static NSString *TPKValueWithDefaultMark(NSString *value, BOOL isDefault) {
    if (!isDefault) return value;
    if ([value isEqualToString:L(@"launch_default")]) return value;
    return [value stringByAppendingString:L(@"common_default_suffix")];
}

// Alertes/sheets avec boutons en accent.
static void TPKPresentAlert(UIViewController *presenter, UIViewController *alert) {
    alert.view.tintColor = TPKAccent();
    [presenter presentViewController:alert animated:YES completion:nil];
}

// Alerte à un bouton, partagée par les pages de réglages.
static void TPKShowAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                          style:UIAlertActionStyleDefault handler:nil]];
    TPKPresentAlert(presenter, a);
}

typedef NS_ENUM(NSInteger, TPKPickerAnimationsMode) {
    TPKPickerAnimationsModeDisabled = 0,
    TPKPickerAnimationsModeEnabled = 1,
    TPKPickerAnimationsModeFavoritesOnly = 2,
};

static TPKPickerAnimationsMode TPKCurrentPickerAnimationsMode(void) {
    TPKManager *manager = [TPKManager sharedManager];
    if (!manager.showPickerAnimations) return TPKPickerAnimationsModeDisabled;
    return manager.showPickerAnimationsFavoritesOnly
        ? TPKPickerAnimationsModeFavoritesOnly
        : TPKPickerAnimationsModeEnabled;
}

static NSString *TPKPickerAnimationsModeTitle(TPKPickerAnimationsMode mode) {
    switch (mode) {
        case TPKPickerAnimationsModeDisabled:
            return L(@"picker_animations_disabled");
        case TPKPickerAnimationsModeFavoritesOnly:
            return L(@"picker_animations_favorites_only");
        case TPKPickerAnimationsModeEnabled:
        default:
            return L(@"picker_animations_enabled");
    }
}


// MARK: - Intégration dans les paramètres Twitch natifs

static NSInteger tpk_settingsOriginalSection(NSInteger section) {
    return section - 1;
}

static NSInteger tpk_settingsNumberOfSections(id self, SEL cmd, UITableView *tableView) {
    SEL original = NSSelectorFromString(@"tpk_numberOfSectionsInTableView:");
    NSInteger (*implementation)(id, SEL, UITableView *) =
        (NSInteger (*)(id, SEL, UITableView *))[self methodForSelector:original];
    return implementation(self, original, tableView) + 1;
}

static NSInteger tpk_settingsNumberOfRows(id self, SEL cmd, UITableView *tableView,
                                            NSInteger section) {
    if (section == 0) return 1;
    SEL original = NSSelectorFromString(@"tpk_tableView:numberOfRowsInSection:");
    NSInteger (*implementation)(id, SEL, UITableView *, NSInteger) =
        (NSInteger (*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
}

static NSString *tpk_settingsHeaderTitle(id self, SEL cmd, UITableView *tableView,
                                           NSInteger section) {
    if (section == 0) return nil;
    SEL original = NSSelectorFromString(@"tpk_tableView:titleForHeaderInSection:");
    NSString *(*implementation)(id, SEL, UITableView *, NSInteger) =
        (NSString *(*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
}

static UIView *tpk_settingsHeaderView(id self, SEL cmd, UITableView *tableView,
                                        NSInteger section) {
    if (section != 0) {
        SEL original = NSSelectorFromString(@"tpk_tableView:viewForHeaderInSection:");
        UIView *(*implementation)(id, SEL, UITableView *, NSInteger) =
            (UIView *(*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
        return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
    }

    // The cell title and logo identify the tweak; no duplicate section header.
    return [UIView new];
}

static CGFloat tpk_settingsHeaderHeight(id self, SEL cmd, UITableView *tableView,
                                          NSInteger section) {
    if (section == 0) return 8.0;
    SEL original = NSSelectorFromString(@"tpk_tableView:heightForHeaderInSection:");
    CGFloat (*implementation)(id, SEL, UITableView *, NSInteger) =
        (CGFloat (*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
}

static UITableViewCell *tpk_settingsCell(id self, SEL cmd, UITableView *tableView,
                                          NSIndexPath *indexPath) {
    if (indexPath.section != 0) {
        NSIndexPath *originalIndexPath = [NSIndexPath indexPathForRow:indexPath.row
            inSection:tpk_settingsOriginalSection(indexPath.section)];
        SEL original = NSSelectorFromString(@"tpk_tableView:cellForRowAtIndexPath:");
        UITableViewCell *(*implementation)(id, SEL, UITableView *, NSIndexPath *) =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
                [self methodForSelector:original];
        return implementation(self, original, tableView, originalIndexPath);
    }

    static NSString *reuseIdentifier = @"TPKSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        Class cellClass = NSClassFromString(@"Twitch.SettingsDisclosureCell")
            ?: NSClassFromString(@"_TtC6Twitch22SettingsDisclosureCell");
        if (cellClass) {
            cell = [[cellClass alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:reuseIdentifier];
        }
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:reuseIdentifier];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = L(@"title_7tv_settings");
    cell.textLabel.numberOfLines = 0;
    // TwitchPlusK logo.
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = [UIImage imageWithData:logoData scale:6.0];
    if (logo) cell.imageView.image = logo;
    return cell;
}

static void tpk_settingsDidSelect(id self, SEL cmd, UITableView *tableView,
                                    NSIndexPath *indexPath) {
    if (indexPath.section != 0) {
        NSIndexPath *originalIndexPath = [NSIndexPath indexPathForRow:indexPath.row
            inSection:tpk_settingsOriginalSection(indexPath.section)];
        SEL original = NSSelectorFromString(@"tpk_tableView:didSelectRowAtIndexPath:");
        void (*implementation)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))[self methodForSelector:original];
        implementation(self, original, tableView, originalIndexPath);
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    TPKSettingsController *controller = [TPKSettingsController new];
    [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
}

// Section 0 is ours: native delegate methods that use section indexes must
// receive remapped values, otherwise the native model array goes out of
// bounds (Swift trap in willDisplayCell on recent Twitch versions).
static void tpk_settingsWillDisplay(id self, SEL cmd, UITableView *tableView,
                                     UITableViewCell *cell, NSIndexPath *indexPath) {
    if (indexPath.section == 0) return;
    NSIndexPath *originalIndexPath = [NSIndexPath indexPathForRow:indexPath.row
        inSection:tpk_settingsOriginalSection(indexPath.section)];
    SEL original = NSSelectorFromString(@"tpk_tableView:willDisplayCell:forRowAtIndexPath:");
    void (*implementation)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) =
        (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))
            [self methodForSelector:original];
    implementation(self, original, tableView, cell, originalIndexPath);
}

static CGFloat tpk_settingsFooterHeight(id self, SEL cmd, UITableView *tableView,
                                         NSInteger section) {
    if (section == 0) return 0.0;
    SEL original = NSSelectorFromString(@"tpk_tableView:heightForFooterInSection:");
    CGFloat (*implementation)(id, SEL, UITableView *, NSInteger) =
        (CGFloat (*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
}

static UIView *tpk_settingsFooterView(id self, SEL cmd, UITableView *tableView,
                                       NSInteger section) {
    if (section == 0) return nil;
    SEL original = NSSelectorFromString(@"tpk_tableView:viewForFooterInSection:");
    UIView *(*implementation)(id, SEL, UITableView *, NSInteger) =
        (UIView *(*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, tpk_settingsOriginalSection(section));
}

static void tpk_settingsExchangeMethod(Class target, SEL originalSelector,
                                         SEL replacementSelector, IMP replacement,
                                         const char *types) {
    Method inheritedMethod = class_getInstanceMethod(target, originalSelector);
    if (!inheritedMethod) return;
    class_addMethod(target, originalSelector, method_getImplementation(inheritedMethod),
                    method_getTypeEncoding(inheritedMethod));
    class_addMethod(target, replacementSelector, replacement, types);
    Method originalMethod = class_getInstanceMethod(target, originalSelector);
    Method replacementMethod = class_getInstanceMethod(target, replacementSelector);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

// MARK: - TPKSettingsController  (Hub principal)

typedef NS_ENUM(NSInteger, TPKHomeSection) {
    TPKHomeSectionMain     = 0,  // Apparence, Contenu, Adblock, Avancé
    TPKHomeSectionLanguage = 1,
};

@implementation TPKSettingsController

+ (void)installTwitchSettingsIntegration {
    Class target = NSClassFromString(@"_TtC6Twitch25AccountMenuViewController");
    if (!target) {
        [[TPKManager sharedManager]
            log:@"⚠️ _TtC6Twitch25AccountMenuViewController introuvable — swizzle ignoré"];
        return;
    }
    tpk_settingsExchangeMethod(target, @selector(numberOfSectionsInTableView:),
        NSSelectorFromString(@"tpk_numberOfSectionsInTableView:"),
        (IMP)tpk_settingsNumberOfSections, "q@:@");
    tpk_settingsExchangeMethod(target, @selector(tableView:numberOfRowsInSection:),
        NSSelectorFromString(@"tpk_tableView:numberOfRowsInSection:"),
        (IMP)tpk_settingsNumberOfRows, "q@:@q");
    tpk_settingsExchangeMethod(target, @selector(tableView:titleForHeaderInSection:),
        NSSelectorFromString(@"tpk_tableView:titleForHeaderInSection:"),
        (IMP)tpk_settingsHeaderTitle, "@@:@q");
    tpk_settingsExchangeMethod(target, @selector(tableView:viewForHeaderInSection:),
        NSSelectorFromString(@"tpk_tableView:viewForHeaderInSection:"),
        (IMP)tpk_settingsHeaderView, "@@:@q");
    tpk_settingsExchangeMethod(target, @selector(tableView:heightForHeaderInSection:),
        NSSelectorFromString(@"tpk_tableView:heightForHeaderInSection:"),
        (IMP)tpk_settingsHeaderHeight, "d@:@q");
    tpk_settingsExchangeMethod(target, @selector(tableView:cellForRowAtIndexPath:),
        NSSelectorFromString(@"tpk_tableView:cellForRowAtIndexPath:"),
        (IMP)tpk_settingsCell, "@@:@@");
    tpk_settingsExchangeMethod(target, @selector(tableView:willDisplayCell:forRowAtIndexPath:),
        NSSelectorFromString(@"tpk_tableView:willDisplayCell:forRowAtIndexPath:"),
        (IMP)tpk_settingsWillDisplay, "v@:@@@");
    tpk_settingsExchangeMethod(target, @selector(tableView:didSelectRowAtIndexPath:),
        NSSelectorFromString(@"tpk_tableView:didSelectRowAtIndexPath:"),
        (IMP)tpk_settingsDidSelect, "v@:@@");
    tpk_settingsExchangeMethod(target, @selector(tableView:heightForFooterInSection:),
        NSSelectorFromString(@"tpk_tableView:heightForFooterInSection:"),
        (IMP)tpk_settingsFooterHeight, "d@:@q");
    tpk_settingsExchangeMethod(target, @selector(tableView:viewForFooterInSection:),
        NSSelectorFromString(@"tpk_tableView:viewForFooterInSection:"),
        (IMP)tpk_settingsFooterView, "@@:@q");
}

- (instancetype)init {
    // Match native Twitch settings.
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    TPKStyleTableView(self.tableView);
    [self buildNavBar];

    // Refresh visible text when the language changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(tpk_languageDidChange)
            name:TPKLanguageDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(tpk_channelDidChange:)
            name:TPKChannelResolverDidChangeNotification
          object:[TPKChannelResolver sharedResolver]];
    TPKRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)tpk_languageDidChange {
    [self buildNavBar];
    [self.tableView reloadData];
}

- (void)tpk_channelDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded || !self.view.window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isViewLoaded && self.view.window) [self.tableView reloadData];
    });
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)buildNavBar {
    // Navigation title and logo.
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = [UIImage imageWithData:logoData scale:2.0];

    if (logo) {
        UIView *tv = [[UIView alloc] init];
        UIImageView *iv = [[UIImageView alloc] initWithImage:logo];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.translatesAutoresizingMaskIntoConstraints = NO;

        NSString *badgeText = L(@"label_twitchplusk_badge");
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = badgeText;
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        lbl.textColor = TPKAccent();
        lbl.translatesAutoresizingMaskIntoConstraints = NO;

        [tv addSubview:iv]; [tv addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:tv.leadingAnchor],
            [iv.centerYAnchor  constraintEqualToAnchor:tv.centerYAnchor],
                [iv.widthAnchor    constraintEqualToConstant:24],
                [iv.heightAnchor   constraintEqualToConstant:18],
            [lbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
            [lbl.centerYAnchor constraintEqualToAnchor:tv.centerYAnchor],
            [lbl.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        ]];
        CGFloat w = 24 + 6 + [badgeText sizeWithAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightBold]
        }].width;
        tv.frame = CGRectMake(0, 0, w, 20);
        self.navigationItem.titleView = tv;
    } else {
        self.title = L(@"title_7tv_settings");
    }

    if (self.openedAsModal) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self action:@selector(closeTapped)];
        self.navigationItem.rightBarButtonItem = close;
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"TPKMenuDidDismiss" object:nil];
    }];
}

// Table view.

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case TPKHomeSectionMain:     return 4; // Apparence / Contenu / Adblock / Avancé
        case TPKHomeSectionLanguage: return 2;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == TPKHomeSectionLanguage && ip.row == 1) {
        return UITableViewAutomaticDimension;
    }
    return 60;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == TPKHomeSectionMain ? 44 : 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case TPKHomeSectionMain:     return TPKSectionHeader(L(@"title_7tv_settings"), YES, nil);
        case TPKHomeSectionLanguage: return TPKSectionHeader(L(@"section_langue"), NO, nil);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return s == TPKHomeSectionMain ? UITableViewAutomaticDimension : 8;
}

// Read-only summary shown at the bottom of the main settings page.
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (s != TPKHomeSectionMain) {
        UIView *v = [[UIView alloc] init];
        v.backgroundColor = [UIColor clearColor];
        return v;
    }

    TPKManager *mgr = [TPKManager sharedManager];
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    NSUInteger total = 0;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        total += [catalog allEmotesForProvider:(TPKEmoteProviderID)provider].count;
    }
    TPKChannelContext *context = TPKCurrentChannelContext();
    NSString *channel = mgr.currentChannelName.length
        ? mgr.currentChannelName
        : (context.channelName.length ? context.channelName : context.displayName);
    if (!channel.length && context.channelID != 0) {
        channel = [NSString stringWithFormat:@"ID %u", context.channelID];
    }
    if (!channel.length) channel = L(@"stats_no_channel");

    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = [NSString stringWithFormat:L(@"summary_emotes_channel_format"),
                (unsigned long)total, channel];
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = TPKGray();
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Refresh emote counters when returning to the main page.
    [self.tableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Main sections: Appearance / Content / Adblock / Advanced.
    if (ip.section == TPKHomeSectionMain) {
        NSString *sfName, *title, *subtitle;
        UIColor *iconTint;
        switch (ip.row) {
            case 0: sfName=@"paintbrush.fill";            title=L(@"title_apparence"); subtitle=L(@"menu_apparence_subtitle"); iconTint=TPKAccent(); break;
            case 1: sfName=@"folder.fill";                 title=L(@"title_contenu");   subtitle=L(@"menu_contenu_subtitle"); iconTint=UIColor.systemBlueColor; break;
            case 2: sfName=@"shield.slash.fill";           title=L(@"title_adblock");   subtitle=L(@"menu_adblock_subtitle"); iconTint=UIColor.systemRedColor; break;
            case 3: sfName=@"wrench.and.screwdriver.fill"; title=L(@"title_avance");    subtitle=L(@"menu_avance_subtitle"); iconTint=UIColor.systemIndigoColor; break;
            default: return [[UITableViewCell alloc] init];
        }
        // Keep concise category summaries visible.
        return TPKNavCell(title, subtitle, sfName, iconTint, nil);
    }

    // Language selection uses a FR/EN segmented control.
    if (ip.section == TPKHomeSectionLanguage && ip.row == 1) {
        return TPKGitHubRepositoryCell();
    }

    if (ip.section == TPKHomeSectionLanguage) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = TPKCellBg();

        UIImageView *icon = TPKIcon(@"globe", UIColor.systemTealColor);
        [cell.contentView addSubview:icon];

        UISegmentedControl *seg = [[UISegmentedControl alloc]
            initWithItems:@[@"Français", @"English"]];
        seg.selectedSegmentIndex = ([TPKLocalization shared].currentLanguage == TPKLanguageEnglish) ? 1 : 0;
        seg.selectedSegmentTintColor = TPKAccent();
        [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                            forState:UIControlStateSelected];
        [seg addTarget:self action:@selector(languageSegmentChanged:)
              forControlEvents:UIControlEventValueChanged];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:seg];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [seg.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [seg.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [seg.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

// Persists the selected language and refreshes open settings screens.
- (void)languageSegmentChanged:(UISegmentedControl *)seg {
    [TPKLocalization shared].currentLanguage =
        (seg.selectedSegmentIndex == 1) ? TPKLanguageEnglish : TPKLanguageFrench;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == TPKHomeSectionLanguage && ip.row == 1) {
        NSURL *url = [NSURL URLWithString:kTPKGitHubURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:nil];
        }
        return;
    }

    UIViewController *dest = nil;
    if (ip.section == TPKHomeSectionMain) {
        switch (ip.row) {
            case 0: dest = [[TPKAppearancePageController alloc] init]; break;
            case 1: dest = [[TPKContentPageController    alloc] init]; break;
            case 2: dest = [[TPKAdblockPageController    alloc] init]; break;
            case 3: dest = [[TPKAdvancedPageController   alloc] init]; break;
        }
    }
    if (dest) [self.navigationController pushViewController:dest animated:YES];
}

@end


// MARK: - TPKAdblockPageController
// TwitchAdBlock method and proxy settings.

@interface TPKAdblockPageController () <UITextFieldDelegate>
@property (nonatomic, assign) TPKAdblockProxyStatus proxyStatus;
@property (nonatomic, strong) NSMutableArray<NSString *> *proxies;
// Ignores probe callbacks from an older request.
@property (nonatomic, assign) NSUInteger proxyStatusGeneration;
// Sélection emotes indépendante du proxy vidéo (même structure).
@property (nonatomic, strong) NSMutableArray<NSString *> *emoteProxies;
@property (nonatomic, assign) TPKAdblockProxyStatus emoteProxyStatus;
@property (nonatomic, assign) NSUInteger emoteProxyStatusGeneration;
// Liste combo séparée (relais RTE + customs combo, jamais la liste vidéo).
@property (nonatomic, strong) NSMutableArray<NSString *> *comboProxies;
@property (nonatomic, assign) TPKAdblockProxyStatus comboProxyStatus;
@property (nonatomic, assign) NSUInteger comboProxyStatusGeneration;
@end

static const NSInteger kTPKProxyTextFieldTag = 0x7A01;
static const NSInteger kTPKProxyUpButtonTag  = 0x7A02;
static const NSInteger kTPKProxyDownButtonTag = 0x7A03;
static const NSInteger kTPKProxyDeleteButtonTag = 0x7A04;

static NSString *TPKAdblockDefaultProxyDisplayName(NSString *address) {
    NSArray<NSString *> *addresses = TPKAdblockDefaultProxyAddresses();
    if (addresses.count > 0 && [address isEqualToString:addresses[0]])
        return L(@"adblock_proxy_eu");
    if (addresses.count > 1 && [address isEqualToString:addresses[1]])
        return L(@"adblock_proxy_eu2");
    if (addresses.count > 2 && [address isEqualToString:addresses[2]])
        return L(@"adblock_proxy_builtin");
    if ([address rangeOfString:@"proxy4.rte.net.ru"].location != NSNotFound)
        return L(@"adblock_proxy_rte4");
    if ([address rangeOfString:@"proxy5.rte.net.ru"].location != NSNotFound)
        return L(@"adblock_proxy_rte5");
    if ([address rangeOfString:@"proxy6.rte.net.ru"].location != NSNotFound)
        return L(@"adblock_proxy_rte6");
    if ([address rangeOfString:@"proxy7.rte.net.ru"].location != NSNotFound)
        return L(@"adblock_proxy_rte7");
    return address.length ? address : L(@"adblock_proxy_eu");
}

// General-section rows (ajout en fin : préserve les index).
typedef NS_ENUM(NSInteger, TPKAdblockGeneralRow) {
    TPKAdblockGeneralRowMethod = 0,
    TPKAdblockGeneralRowHideTurbo = 1,
    TPKAdblockGeneralRowEmoteProxy = 2,
};

@implementation TPKAdblockPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _proxyStatus = TPKAdblockProxyStatusUnknown;
        _proxies = TPKAdblockCustomProxyAddresses().mutableCopy;
        _emoteProxyStatus = TPKAdblockProxyStatusUnknown;
        _emoteProxies = TPKEmoteProxyCustomAddresses().mutableCopy;
        _comboProxyStatus = TPKAdblockProxyStatusUnknown;
        _comboProxies = TPKAdblockComboProxyCustomAddresses().mutableCopy;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_adblock");
    TPKStyleTableView(self.tableView);
    TPKRegisterOLEDObserver(self);
    TPKAdblockRegisterDefaults();
    TPKEmoteProxyRegisterDefaults();
    TPKAdblockComboProxyRegisterDefaults();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Probe on entry or explicit changes; no periodic timer.
    if (TPKAdblockConfiguredMethod() == TPKAdblockMethodProxy &&
        TPKAdblockProxyIsEnabled()) {
        [self refreshProxyStatus];
    } else if (TPKAdblockConfiguredMethod() == TPKAdblockMethodProxyPlusLocal &&
        TPKAdblockProxyIsEnabled()) {
        [self refreshComboProxyStatus];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [TPKInfoTooltip dismiss];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Emotes d'abord : son index vaut 1 quand la section vidéo est masquée.
    if (section == [self tpk_emoteSectionIndex] && [self tpk_emoteSectionVisible]) {
        return TPKEmoteProxyCustomIsEnabled() ? 4 + self.emoteProxies.count : 3;
    }
    if (section == 0) {
        // Method selector: Disabled, Proxy or Local (VAFT).
        return [self tpk_visibleGeneralRows].count;
    }
    // Local (VAFT) shows an informational row; it has no proxy settings.
    if ([self tpk_localVaftSectionVisible]) return 1;
    // Combo : même structure que la section vidéo, liste séparée, + ligne info.
    if ([self tpk_comboSectionVisible]) {
        NSInteger base = TPKAdblockComboProxyCustomIsEnabled() ? 4 + self.comboProxies.count : 3;
        return base + 1;
    }
    if (![self tpk_proxySectionVisible]) return 0;
    // Custom mode adds one editable row per configured address.
    return TPKAdblockCustomProxyIsEnabled() ? 4 + self.proxies.count : 3;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == [self tpk_emoteSectionIndex] && [self tpk_emoteSectionVisible]) {
        return TPKSectionHeader(L(@"adblock_emote_section"), NO,
                                 @"adblock_emote_proxy_footer");
    }
    if (section == 1 && [self tpk_localVaftSectionVisible]) {
        // Local mode replaces the proxy header with an informational note.
        UIView *empty = [[UIView alloc] init];
        empty.backgroundColor = UIColor.clearColor;
        return empty;
    }
    if (section == 1 && [self tpk_comboSectionVisible]) {
        return TPKSectionHeader(L(@"adblock_combo_section"), NO, nil);
    }
    // Proxy details are shown from the header info button.
    return TPKSectionHeader(section == 0 ? L(@"section_general")
                                          : L(@"adblock_section_proxy"), NO,
                             section == 0 ? nil : @"adblock_proxy_privacy_footer");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 1 && [self tpk_localVaftSectionVisible]) return 8.0;
    return 44.0;
}

// Visible General rows; the method selector replaces the old master toggle.
// Toggle emotes ici : visible toute méthode.
- (NSArray<NSNumber *> *)tpk_visibleGeneralRows {
    return @[@(TPKAdblockGeneralRowMethod),
             @(TPKAdblockGeneralRowHideTurbo),
             @(TPKAdblockGeneralRowEmoteProxy)];
}

// Proxy rows follow the selected method.
- (BOOL)tpk_proxySectionVisible {
    return TPKAdblockConfiguredMethod() == TPKAdblockMethodProxy;
}

// Combo rows follow the selected method (liste séparée, jamais la vidéo).
- (BOOL)tpk_comboSectionVisible {
    return TPKAdblockConfiguredMethod() == TPKAdblockMethodProxyPlusLocal;
}

// Local (VAFT) uses the dependent-section mechanism without proxy rows.
- (BOOL)tpk_localVaftSectionVisible {
    return TPKAdblockConfiguredMethod() == TPKAdblockMethodLocalVaft;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSInteger base = ([self tpk_proxySectionVisible] || [self tpk_localVaftSectionVisible] ||
                      [self tpk_comboSectionVisible]) ? 2 : 1;
    // Section emotes visible dès que son toggle est ON, toute méthode.
    return base + ([self tpk_emoteSectionVisible] ? 1 : 0);
}

// Index dynamique : 1 quand la section vidéo est masquée, 2 sinon.
- (NSInteger)tpk_emoteSectionIndex {
    return ([self tpk_proxySectionVisible] || [self tpk_localVaftSectionVisible] ||
            [self tpk_comboSectionVisible]) ? 2 : 1;
}

- (BOOL)tpk_emoteSectionVisible {
    return TPKEmoteProxyIsEnabled();
}

- (NSInteger)proxyIndexForRow:(NSInteger)row {
    if (!TPKAdblockCustomProxyIsEnabled() || row < 2 ||
        row >= 2 + (NSInteger)self.proxies.count) return -1;
    return row - 2;
}

- (NSInteger)addProxyRowIndex {
    return 2 + self.proxies.count;
}

- (NSInteger)statusRowIndex {
    return TPKAdblockCustomProxyIsEnabled() ? 3 + self.proxies.count : 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray<NSNumber *> *visible = [self tpk_visibleGeneralRows];
        if (indexPath.row >= (NSInteger)visible.count) {
            return [[UITableViewCell alloc] init];
        }
        switch (visible[indexPath.row].integerValue) {
            case TPKAdblockGeneralRowMethod: {
                // Configured method: Disabled / Proxy / Local (VAFT) / Combo.
                TPKAdblockMethod configured = TPKAdblockConfiguredMethod();
                NSString *valueKey = configured == TPKAdblockMethodLocalVaft
                    ? @"adblock_method_value_local"
                    : configured == TPKAdblockMethodProxyPlusLocal
                        ? @"adblock_method_value_combo"
                    : configured == TPKAdblockMethodProxy
                        ? @"adblock_method_value_proxy"
                        : @"adblock_method_value_disabled";
                return TPKNavCell(L(@"adblock_cell_title"), L(valueKey),
                    @"shield.lefthalf.filled", TPKAccent(), @"adblock_engine_footer");
            }
            case TPKAdblockGeneralRowHideTurbo:
                return TPKSwitchCell(L(@"adblock_hide_go_ad_free"), @"rectangle.slash",
                    [UIColor colorWithRed:0.95 green:0.45 blue:0.25 alpha:1.0],
                    TPKAdblockHideAdFreeButtonEnabledFast(), self,
                    @selector(toggleHideGoAdFree:), nil);
            case TPKAdblockGeneralRowEmoteProxy:
            default:
                return TPKSwitchCell(L(@"adblock_emote_proxy"), @"globe",
                    UIColor.systemTealColor,
                    TPKEmoteProxyIsEnabled(), self,
                    @selector(toggleEmoteProxy:), @"adblock_emote_proxy_info");
        }
    }

    if (indexPath.section == [self tpk_emoteSectionIndex] &&
        [self tpk_emoteSectionVisible]) {
        if (indexPath.row == 0) {
            return TPKNavCell(L(@"adblock_emote_default_proxy"),
                               TPKAdblockDefaultProxyDisplayName(
                                   TPKEmoteProxyDefaultAddress()),
                               @"network", TPKAccent(), nil);
        }
        if (indexPath.row == 1) {
            return TPKSwitchCell(L(@"adblock_custom_proxy"),
                @"server.rack", UIColor.systemTealColor,
                TPKEmoteProxyCustomIsEnabled(), self,
                @selector(toggleEmoteCustomProxy:), nil);
        }
        if (!TPKEmoteProxyCustomIsEnabled()) return [self emoteProxyStatusCell];
        NSInteger emoteProxyIndex = [self emoteProxyIndexForRow:indexPath.row];
        if (emoteProxyIndex >= 0) return [self emoteProxyRowCellForIndex:emoteProxyIndex];
        if (indexPath.row == [self addEmoteProxyRowIndex]) return [self addProxyCell];
        return [self emoteProxyStatusCell];
    }

    if (indexPath.section == 1 && [self tpk_localVaftSectionVisible]) {
        // Reuse a multi-line descriptive cell without an inner scroll view.
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = TPKCellBg();

        UILabel *label = [[UILabel alloc] init];
        label.text = L(@"adblock_local_no_proxy");
        label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
        label.textColor = UIColor.whiteColor;
        label.numberOfLines = 0;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
            [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
            [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12.0],
            [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12.0],
        ]];
        return cell;
    }

    // Keep Proxy rows hidden while the configured method is not Proxy.
    if (indexPath.section == 1 && [self tpk_comboSectionVisible]) {
        if (indexPath.row == 0) {
            return [self comboDefaultProxyCell];
        }
        if (indexPath.row == 1) {
            return TPKSwitchCell(L(@"adblock_custom_proxy"),
                @"server.rack", UIColor.systemTealColor,
                TPKAdblockComboProxyCustomIsEnabled(), self,
                @selector(toggleComboCustomProxy:), nil);
        }
        if (indexPath.row == [self comboStatusRowIndex]) return [self comboStatusCell];
        if (indexPath.row == [self comboInfoRowIndex]) return [self comboInfoCell];
        if (!TPKAdblockComboProxyCustomIsEnabled()) return [self comboStatusCell];
        NSInteger comboIndex = [self comboProxyIndexForRow:indexPath.row];
        if (comboIndex >= 0) return [self comboProxyRowCellForIndex:comboIndex];
        if (indexPath.row == [self addComboProxyRowIndex]) return [self addProxyCell];
        return [self comboStatusCell];
    }
    if (indexPath.section != 1 || ![self tpk_proxySectionVisible]) {
        return [[UITableViewCell alloc] init];
    }

    if (indexPath.row == 0) {
        return [self defaultProxyCell];
    }
    if (indexPath.row == 1) {
        return TPKSwitchCell(L(@"adblock_custom_proxy"),
            @"server.rack", UIColor.systemTealColor,
            TPKAdblockCustomProxyIsEnabled(), self,
            @selector(toggleAdblockCustomProxy:), nil);
    }

    if (!TPKAdblockCustomProxyIsEnabled()) return [self proxyStatusCell];
    NSInteger proxyIndex = [self proxyIndexForRow:indexPath.row];
    if (proxyIndex >= 0) return [self proxyRowCellForIndex:proxyIndex];
    if (indexPath.row == [self addProxyRowIndex]) return [self addProxyCell];
    return [self proxyStatusCell];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && [self tpk_localVaftSectionVisible]) return;
    if (indexPath.section == 1 && [self tpk_comboSectionVisible] &&
        indexPath.row == 0) {
        [self presentComboDefaultProxyPickerFromCell:
            [tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 1 && [self tpk_comboSectionVisible] &&
        TPKAdblockComboProxyCustomIsEnabled() &&
        indexPath.row == [self addComboProxyRowIndex]) {
        [self.comboProxies addObject:@""];
        [self saveComboProxies];
        TPKReloadSectionWithoutJump(self.tableView, 1);
    }
    if (indexPath.section == 1 && [self tpk_proxySectionVisible] &&
        indexPath.row == 0) {
        [self presentDefaultProxyPickerFromCell:
            [tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 1 && [self tpk_proxySectionVisible] &&
        TPKAdblockProxyIsEnabled() && TPKAdblockCustomProxyIsEnabled() &&
        indexPath.row == [self addProxyRowIndex]) {
        [self.proxies addObject:@""];
        [self saveProxies];
        TPKReloadSectionWithoutJump(self.tableView, 1);
    }
    if (indexPath.section == [self tpk_emoteSectionIndex] &&
        [self tpk_emoteSectionVisible] &&
        indexPath.row == 0) {
        [self presentEmoteDefaultProxyPickerFromCell:
            [tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == [self tpk_emoteSectionIndex] &&
        [self tpk_emoteSectionVisible] &&
        TPKEmoteProxyCustomIsEnabled() &&
        indexPath.row == [self addEmoteProxyRowIndex]) {
        [self.emoteProxies addObject:@""];
        [self saveEmoteProxies];
        TPKReloadSectionWithoutJump(self.tableView, [self tpk_emoteSectionIndex]);
    }
    NSArray<NSNumber *> *visibleGeneral = [self tpk_visibleGeneralRows];
    if (indexPath.section == 0 && indexPath.row < (NSInteger)visibleGeneral.count &&
        visibleGeneral[indexPath.row].integerValue == TPKAdblockGeneralRowMethod) {
        [self presentMethodActionSheetFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

// Method action sheet. Selection changes the configured method only.
- (void)presentMethodActionSheetFromCell:(UITableViewCell *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_method_title")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    TPKAdblockMethod configured = TPKAdblockConfiguredMethod();
    NSArray *choices = @[
        @[L(@"adblock_method_value_disabled"), @(TPKAdblockMethodDisabled)],
        @[L(@"adblock_method_value_local"), @(TPKAdblockMethodLocalVaft)],
        @[L(@"adblock_method_value_proxy"), @(TPKAdblockMethodProxy)],
        @[L(@"adblock_method_value_combo"), @(TPKAdblockMethodProxyPlusLocal)],
    ];
    for (NSArray *choice in choices) {
        TPKAdblockMethod method = (TPKAdblockMethod)[choice[1] integerValue];
        NSString *title = [choice[0] isKindOfClass:NSString.class] ? choice[0] : @"";
        if (method == configured) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self tpk_applyConfiguredMethod:method];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    TPKPresentAlert(self, sheet);
}

- (void)tpk_applyConfiguredMethod:(TPKAdblockMethod)method {
    TPKAdblockSetConfiguredMethod(method);
    // Keep the legacy proxy flag synchronized when Proxy or Combo is selected.
    if (method == TPKAdblockMethodProxy || method == TPKAdblockMethodProxyPlusLocal) {
        TPKAdblockSetProxyEnabled(YES);
    }
    TPKAdblockMethod active = TPKAdblockActiveMethod();
    if (method == TPKAdblockMethodDisabled) {
        // Disable the currently loaded engine immediately.
        TPKAdblockSetEnabled(NO);
    } else if (method == active) {
        // The active method can be applied without a restart.
        TPKAdblockSetEnabled(YES);
    } else {
        // Keep the active snapshot until restart when switching engines.
        TPKAdblockSetEnabledForNextLaunch(YES);
    }
    // The number of sections depends on the selected method.
    TPKReloadDataWithoutJump(self.tableView);

    // Revalidate the endpoint when Proxy or Combo is already active.
    if ((method == TPKAdblockMethodProxy || method == TPKAdblockMethodProxyPlusLocal) &&
        method == active && TPKAdblockProxyIsEnabled()) {
        self.proxyStatus = TPKAdblockProxyStatusUnknown;
        [self refreshProxyStatus];
        self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
        [self refreshComboProxyStatus];
    }

    // A configured/active mismatch requires a Twitch restart.
    if (method == active) return;

    NSString *message;
    switch (method) {
        case TPKAdblockMethodLocalVaft:
            message = L(@"adblock_restart_local_msg"); break;
        case TPKAdblockMethodDisabled:
            message = L(@"adblock_restart_disabled_msg"); break;
        case TPKAdblockMethodProxyPlusLocal:
            message = L(@"adblock_restart_combo_msg"); break;
        case TPKAdblockMethodProxy:
        default:
            message = L(@"adblock_restart_proxy_msg"); break;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"adblock_restart_title")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    TPKPresentAlert(self, alert);
}

- (void)toggleHideGoAdFree:(UISwitch *)sender {
    TPKAdblockSetHideAdFreeButtonEnabled(sender.isOn);
}

- (void)toggleAdblockProxy:(UISwitch *)sender {
    TPKAdblockSetProxyEnabled(sender.isOn);
    self.proxyStatus = TPKAdblockProxyStatusUnknown;
    if ([self tpk_proxySectionVisible]) {
        TPKReloadSectionWithoutJump(self.tableView, 1);
    } else {
        TPKReloadDataWithoutJump(self.tableView);
    }
    if (sender.isOn) [self refreshProxyStatus];
}

- (void)toggleAdblockCustomProxy:(UISwitch *)sender {
    TPKAdblockSetCustomProxyEnabled(sender.isOn);
    self.proxyStatus = TPKAdblockProxyStatusUnknown;
    if ([self tpk_proxySectionVisible]) {
        TPKReloadSectionWithoutJump(self.tableView, 1);
    } else {
        TPKReloadDataWithoutJump(self.tableView);
    }
    [self refreshProxyStatus];
}

- (void)toggleEmoteProxy:(UISwitch *)sender {
    TPKEmoteProxySetEnabled(sender.isOn);
    // La section apparaît/disparaît : recharge complète.
    TPKReloadDataWithoutJump(self.tableView);
    // URLs proxifiées = entrées cache séparées : purge pour recharger aussitôt.
    [[TPKManager sharedManager] clearAllCaches];
    if (sender.isOn) [self refreshEmoteProxyStatus];
}

- (void)toggleEmoteCustomProxy:(UISwitch *)sender {
    TPKEmoteProxySetCustomEnabled(sender.isOn);
    self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
    TPKReloadSectionWithoutJump(self.tableView, [self tpk_emoteSectionIndex]);
    [self refreshEmoteProxyStatus];
}

- (UITableViewCell *)defaultProxyCell {
    return TPKNavCell(L(@"adblock_default_proxy"),
                       TPKAdblockDefaultProxyDisplayName(
                           TPKAdblockDefaultProxyAddress()),
                       @"network", TPKAccent(), nil);
}

- (void)presentDefaultProxyPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *addresses = TPKAdblockDefaultProxyAddresses();
    NSString *current = TPKAdblockDefaultProxyAddress();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_default_proxy")
                          message:L(@"adblock_default_proxy_footer")
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    __weak typeof(self) weakSelf = self;
    for (NSString *address in addresses) {
        NSString *title = TPKAdblockDefaultProxyDisplayName(address);
        if ([address isEqualToString:current])
            title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            TPKAdblockSetDefaultProxyAddress(address);
            self.proxyStatus = TPKAdblockProxyStatusUnknown;
            TPKReloadCellWithoutJump(self.tableView, anchor);
            [self refreshProxyStatus];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

// ── Section combo : liste séparée RTE + customs combo ──

- (NSInteger)comboProxyIndexForRow:(NSInteger)row {
    if (!TPKAdblockComboProxyCustomIsEnabled() || row < 2 ||
        row >= 2 + (NSInteger)self.comboProxies.count) return -1;
    return row - 2;
}

- (NSInteger)addComboProxyRowIndex {
    return 2 + self.comboProxies.count;
}

- (NSInteger)comboStatusRowIndex {
    return TPKAdblockComboProxyCustomIsEnabled() ? 3 + self.comboProxies.count : 2;
}

- (NSInteger)comboInfoRowIndex {
    return [self comboStatusRowIndex] + 1;
}

- (void)toggleComboCustomProxy:(UISwitch *)sender {
    TPKAdblockComboProxySetCustomEnabled(sender.isOn);
    self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
    if ([self tpk_comboSectionVisible]) {
        TPKReloadSectionWithoutJump(self.tableView, 1);
    } else {
        TPKReloadDataWithoutJump(self.tableView);
    }
    [self refreshComboProxyStatus];
}

- (void)saveComboProxies {
    TPKAdblockComboProxySetCustomAddresses(self.comboProxies);
}

- (UITableViewCell *)comboDefaultProxyCell {
    return TPKNavCell(L(@"adblock_combo_default_proxy"),
                       TPKAdblockDefaultProxyDisplayName(
                           TPKAdblockComboProxyDefaultAddress()),
                       @"network", TPKAccent(), nil);
}

- (void)presentComboDefaultProxyPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *addresses = TPKAdblockComboProxyAddresses();
    NSString *current = TPKAdblockComboProxyDefaultAddress();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_combo_default_proxy")
                         message:L(@"adblock_combo_footer")
                    preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    __weak typeof(self) weakSelf = self;
    for (NSString *address in addresses) {
        NSString *title = TPKAdblockDefaultProxyDisplayName(address);
        if ([address isEqualToString:current])
            title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            TPKAdblockComboProxySetDefaultAddress(address);
            self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
            TPKReloadCellWithoutJump(self.tableView, anchor);
            [self refreshComboProxyStatus];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

- (UITableViewCell *)comboProxyRowCellForIndex:(NSInteger)index {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKProxyRowCell"];
    UIButton *up = nil;
    UIButton *down = nil;
    UIButton *deleteButton = nil;
    UITextField *field = nil;
    if (cell) {
        up = (UIButton *)[cell.contentView viewWithTag:kTPKProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDownButtonTag];
        deleteButton = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDeleteButtonTag];
        field = (UITextField *)[cell.contentView viewWithTag:kTPKProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"TPKProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up = [self proxyArrowButton:@"chevron.up" tag:kTPKProxyUpButtonTag
                             action:@selector(comboUpTapped:)];
        down = [self proxyArrowButton:@"chevron.down" tag:kTPKProxyDownButtonTag
                               action:@selector(comboDownTapped:)];
        deleteButton = [self proxyArrowButton:@"xmark.circle.fill"
                                          tag:kTPKProxyDeleteButtonTag
                                       action:@selector(comboDeleteTapped:)];
        deleteButton.accessibilityLabel = L(@"adblock_proxy_delete");
        field = [[UITextField alloc] init];
        field.tag = kTPKProxyTextFieldTag;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.placeholder = @"user:pass@host:port";
        field.textColor = UIColor.whiteColor;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
        field.returnKeyType = UIReturnKeyDone;
        field.font = [UIFont systemFontOfSize:15];
        field.delegate = self;
        [field addTarget:self action:@selector(proxyFieldChanged:)
        forControlEvents:UIControlEventEditingChanged];
        [cell.contentView addSubview:up];
        [cell.contentView addSubview:down];
        [cell.contentView addSubview:deleteButton];
        [cell.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [up.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [up.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [up.widthAnchor constraintEqualToConstant:30],
            [up.heightAnchor constraintEqualToConstant:30],
            [down.leadingAnchor constraintEqualToAnchor:up.trailingAnchor constant:2],
            [down.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [down.widthAnchor constraintEqualToConstant:30],
            [down.heightAnchor constraintEqualToConstant:30],
            [field.leadingAnchor constraintEqualToAnchor:down.trailingAnchor constant:10],
            [deleteButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [deleteButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [deleteButton.widthAnchor constraintEqualToConstant:28],
            [deleteButton.heightAnchor constraintEqualToConstant:30],
            [field.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-6],
            [field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [field.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    cell.backgroundColor = TPKCellBg();
    field.text = index < (NSInteger)self.comboProxies.count ? self.comboProxies[index] : @"";
    BOOL canMoveUp = index > 0;
    BOOL canMoveDown = index < (NSInteger)self.comboProxies.count - 1;
    up.enabled = canMoveUp;
    up.alpha = canMoveUp ? 1.0 : 0.25;
    down.enabled = canMoveDown;
    down.alpha = canMoveDown ? 1.0 : 0.25;
    return cell;
}

- (void)removeComboProxyAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.comboProxies.count) return;
    [self.comboProxies removeObjectAtIndex:index];
    [self saveComboProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshComboProxyStatus];
}

- (void)comboUpTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self comboProxyIndexForRow:path.row];
    if (index <= 0) return;
    [self.comboProxies exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self saveComboProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshComboProxyStatus];
}

- (void)comboDownTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self comboProxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.comboProxies.count - 1) return;
    [self.comboProxies exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self saveComboProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.comboProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshComboProxyStatus];
}

- (void)comboDeleteTapped:(UIButton *)button {
    UITableViewCell *cell = [self cellForProxySubview:button];
    NSIndexPath *path = cell ? [self.tableView indexPathForCell:cell] : nil;
    if (!path) return;
    NSInteger index = [self comboProxyIndexForRow:path.row];
    [self removeComboProxyAtIndex:index];
}

- (UITableViewCell *)comboInfoCell {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = TPKCellBg();

    UILabel *label = [[UILabel alloc] init];
    label.text = L(@"adblock_combo_footer");
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    label.textColor = UIColor.systemRedColor;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12.0],
        [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12.0],
    ]];
    return cell;
}

- (UITableViewCell *)comboStatusCell {    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKComboProxyStatusCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"TPKComboProxyStatusCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = TPKAdblockComboProxyCustomIsEnabled()
        ? L(@"adblock_proxy_custom_status") : L(@"adblock_proxy_default_status");
    cell.textLabel.textColor = UIColor.whiteColor;
    switch (self.comboProxyStatus) {
        case TPKAdblockProxyStatusOnline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_online");
            cell.detailTextLabel.textColor = UIColor.systemGreenColor;
            break;
        case TPKAdblockProxyStatusOffline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_offline");
            cell.detailTextLabel.textColor = UIColor.systemRedColor;
            break;
        case TPKAdblockProxyStatusChecking:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_checking");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
        default:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_unknown");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
    }

    UIButton *pingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *pingSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                          weight:UIImageSymbolWeightSemibold];
    [pingButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"
                                   withConfiguration:pingSymbolConfiguration]
                   forState:UIControlStateNormal];
    pingButton.titleLabel.font = [UIFont systemFontOfSize:13.0
                                                     weight:UIFontWeightSemibold];
    pingButton.tintColor = TPKAccent();
    pingButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    pingButton.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
    pingButton.accessibilityLabel = L(@"adblock_proxy_status_ping");
    [pingButton addTarget:self action:@selector(manualComboPing:)
          forControlEvents:UIControlEventTouchUpInside];
    BOOL canPing = TPKAdblockConfiguredMethod() == TPKAdblockMethodProxyPlusLocal &&
                   TPKAdblockProxyIsEnabled();
    pingButton.enabled = canPing &&
                         self.comboProxyStatus != TPKAdblockProxyStatusChecking;
    cell.accessoryView = pingButton;
    return cell;
}

- (void)manualComboPing:(UIButton *)sender {
    (void)sender;
    if (TPKAdblockConfiguredMethod() != TPKAdblockMethodProxyPlusLocal ||
        !TPKAdblockProxyIsEnabled() ||
        self.comboProxyStatus == TPKAdblockProxyStatusChecking) {
        return;
    }
    [self refreshComboProxyStatus];
}

- (void)refreshComboProxyStatus {
    if (![self tpk_comboSectionVisible] || !TPKAdblockProxyIsEnabled()) return;
    NSUInteger generation = ++self.comboProxyStatusGeneration;
    NSString *address = nil;
    if (TPKAdblockComboProxyCustomIsEnabled()) {
        for (NSString *proxy in self.comboProxies) {
            NSString *clean = [proxy stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet];
            if (clean.length) {
                address = clean;
                break;
            }
        }
        if (!address) {
            self.comboProxyStatus = TPKAdblockProxyStatusOffline;
            [self reloadComboProxyStatusRow];
            return;
        }
    } else {
        address = TPKAdblockComboProxyDefaultAddress();
    }
    self.comboProxyStatus = TPKAdblockProxyStatusChecking;
    [self reloadComboProxyStatusRow];
    __weak typeof(self) weakSelf = self;
    TPKAdblockCheckProxyStatus(address, ^(TPKAdblockProxyStatus status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.comboProxyStatusGeneration) return;
        self.comboProxyStatus = status;
        [self reloadComboProxyStatusRow];
    });
}

- (void)reloadComboProxyStatusRow {
    if (![self tpk_comboSectionVisible]) return;
    NSInteger section = 1;
    NSInteger row = [self comboStatusRowIndex];
    if (section >= [self.tableView numberOfSections] ||
        row >= [self.tableView numberOfRowsInSection:section]) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
    [self.tableView reloadRowsAtIndexPaths:@[path]
                          withRowAnimation:UITableViewRowAnimationNone];
}


// ── Section emotes : sélection indépendante du proxy vidéo ──

- (NSInteger)emoteProxyIndexForRow:(NSInteger)row {
    if (!TPKEmoteProxyCustomIsEnabled() || row < 2 ||
        row >= 2 + (NSInteger)self.emoteProxies.count) return -1;
    return row - 2;
}

- (NSInteger)addEmoteProxyRowIndex {
    return 2 + self.emoteProxies.count;
}

- (NSInteger)emoteStatusRowIndex {
    return TPKEmoteProxyCustomIsEnabled() ? 3 + self.emoteProxies.count : 2;
}

- (void)presentEmoteDefaultProxyPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *addresses = TPKAdblockDefaultProxyAddresses();
    NSString *current = TPKEmoteProxyDefaultAddress();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_emote_default_proxy")
                          message:L(@"adblock_default_proxy_footer")
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    __weak typeof(self) weakSelf = self;
    for (NSString *address in addresses) {
        NSString *title = TPKAdblockDefaultProxyDisplayName(address);
        if ([address isEqualToString:current])
            title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            TPKEmoteProxySetDefaultAddress(address);
            self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
            TPKReloadCellWithoutJump(self.tableView, anchor);
            [self refreshEmoteProxyStatus];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

- (UITableViewCell *)emoteProxyStatusCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKEmoteProxyStatusCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"TPKEmoteProxyStatusCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = TPKEmoteProxyCustomIsEnabled()
        ? L(@"adblock_proxy_custom_status") : L(@"adblock_proxy_default_status");
    cell.textLabel.textColor = UIColor.whiteColor;
    switch (self.emoteProxyStatus) {
        case TPKAdblockProxyStatusOnline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_online");
            cell.detailTextLabel.textColor = UIColor.systemGreenColor;
            break;
        case TPKAdblockProxyStatusOffline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_offline");
            cell.detailTextLabel.textColor = UIColor.systemRedColor;
            break;
        case TPKAdblockProxyStatusChecking:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_checking");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
        default:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_unknown");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
    }

    UIButton *pingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *pingSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                         weight:UIImageSymbolWeightSemibold];
    [pingButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"
                                  withConfiguration:pingSymbolConfiguration]
                  forState:UIControlStateNormal];
    pingButton.titleLabel.font = [UIFont systemFontOfSize:13.0
                                                   weight:UIFontWeightSemibold];
    pingButton.tintColor = TPKAccent();
    pingButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    pingButton.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
    pingButton.accessibilityLabel = L(@"adblock_proxy_status_ping");
    [pingButton addTarget:self action:@selector(manualEmoteProxyPing:)
          forControlEvents:UIControlEventTouchUpInside];
    pingButton.enabled = TPKEmoteProxyIsEnabled() &&
                         self.emoteProxyStatus != TPKAdblockProxyStatusChecking;
    cell.accessoryView = pingButton;
    return cell;
}

- (void)manualEmoteProxyPing:(UIButton *)sender {
    (void)sender;
    if (!TPKEmoteProxyIsEnabled()) return;
    self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshEmoteProxyStatus];
}

- (UITableViewCell *)emoteProxyRowCellForIndex:(NSInteger)index {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKEmoteProxyRowCell"];
    UIButton *up = nil;
    UIButton *down = nil;
    UIButton *deleteButton = nil;
    UITextField *field = nil;
    if (cell) {
        up = (UIButton *)[cell.contentView viewWithTag:kTPKProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDownButtonTag];
        deleteButton = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDeleteButtonTag];
        field = (UITextField *)[cell.contentView viewWithTag:kTPKProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"TPKEmoteProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up = [self proxyArrowButton:@"chevron.up" tag:kTPKProxyUpButtonTag
                             action:@selector(emoteProxyUpTapped:)];
        down = [self proxyArrowButton:@"chevron.down" tag:kTPKProxyDownButtonTag
                               action:@selector(emoteProxyDownTapped:)];
        deleteButton = [self proxyArrowButton:@"xmark.circle.fill"
                                          tag:kTPKProxyDeleteButtonTag
                                       action:@selector(emoteProxyDeleteTapped:)];
        deleteButton.accessibilityLabel = L(@"adblock_proxy_delete");
        field = [[UITextField alloc] init];
        field.tag = kTPKProxyTextFieldTag;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.placeholder = @"user:pass@host:port";
        field.textColor = UIColor.whiteColor;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
        field.returnKeyType = UIReturnKeyDone;
        field.font = [UIFont systemFontOfSize:15];
        field.delegate = self;
        [field addTarget:self action:@selector(proxyFieldChanged:)
        forControlEvents:UIControlEventEditingChanged];
        [cell.contentView addSubview:up];
        [cell.contentView addSubview:down];
        [cell.contentView addSubview:deleteButton];
        [cell.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [up.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [up.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [up.widthAnchor constraintEqualToConstant:30],
            [up.heightAnchor constraintEqualToConstant:30],
            [down.leadingAnchor constraintEqualToAnchor:up.trailingAnchor constant:2],
            [down.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [down.widthAnchor constraintEqualToConstant:30],
            [down.heightAnchor constraintEqualToConstant:30],
            [field.leadingAnchor constraintEqualToAnchor:down.trailingAnchor constant:10],
            [deleteButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [deleteButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [deleteButton.widthAnchor constraintEqualToConstant:28],
            [deleteButton.heightAnchor constraintEqualToConstant:30],
            [field.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-6],
            [field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [field.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    cell.backgroundColor = TPKCellBg();
    field.text = index < (NSInteger)self.emoteProxies.count ? self.emoteProxies[index] : @"";
    BOOL canMoveUp = index > 0;
    BOOL canMoveDown = index < (NSInteger)self.emoteProxies.count - 1;
    up.enabled = canMoveUp;
    up.alpha = canMoveUp ? 1.0 : 0.25;
    down.enabled = canMoveDown;
    down.alpha = canMoveDown ? 1.0 : 0.25;
    return cell;
}

- (void)saveEmoteProxies {
    TPKEmoteProxySetCustomAddresses(self.emoteProxies);
}

- (void)emoteProxyUpTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    if (!path) return;
    NSInteger index = [self emoteProxyIndexForRow:path.row];
    if (index <= 0) return;
    [self.emoteProxies exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self saveEmoteProxies];
    TPKReloadSectionWithoutJump(self.tableView, [self tpk_emoteSectionIndex]);
    self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshEmoteProxyStatus];
}

- (void)emoteProxyDownTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    if (!path) return;
    NSInteger index = [self emoteProxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.emoteProxies.count - 1) return;
    [self.emoteProxies exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self saveEmoteProxies];
    TPKReloadSectionWithoutJump(self.tableView, [self tpk_emoteSectionIndex]);
    self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshEmoteProxyStatus];
}

- (void)removeEmoteProxyAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.emoteProxies.count) return;
    [self.emoteProxies removeObjectAtIndex:index];
    [self saveEmoteProxies];
    TPKReloadSectionWithoutJump(self.tableView, [self tpk_emoteSectionIndex]);
    self.emoteProxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshEmoteProxyStatus];
}

- (void)emoteProxyDeleteTapped:(UIButton *)button {
    UITableViewCell *cell = [self cellForProxySubview:button];
    NSIndexPath *path = cell ? [self.tableView indexPathForCell:cell] : nil;
    if (!path) return;
    NSInteger index = [self emoteProxyIndexForRow:path.row];
    [self removeEmoteProxyAtIndex:index];
}

- (void)refreshEmoteProxyStatus {
    if (![self tpk_emoteSectionVisible]) return;
    NSUInteger generation = ++self.emoteProxyStatusGeneration;
    NSString *address = nil;
    if (TPKEmoteProxyCustomIsEnabled()) {
        for (NSString *proxy in self.emoteProxies) {
            NSString *clean = [proxy stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet];
            if (clean.length) {
                address = clean;
                break;
            }
        }
        if (!address) {
            self.emoteProxyStatus = TPKAdblockProxyStatusOffline;
            [self reloadEmoteProxyStatusRow];
            return;
        }
    } else {
        address = TPKEmoteProxyDefaultAddress();
    }
    self.emoteProxyStatus = TPKAdblockProxyStatusChecking;
    [self reloadEmoteProxyStatusRow];
    __weak typeof(self) weakSelf = self;
    TPKAdblockCheckProxyStatus(address, ^(TPKAdblockProxyStatus status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.emoteProxyStatusGeneration) return;
        self.emoteProxyStatus = status;
        [self reloadEmoteProxyStatusRow];
    });
}

- (void)reloadEmoteProxyStatusRow {
    if (![self tpk_emoteSectionVisible]) return;
    NSInteger section = [self tpk_emoteSectionIndex];
    NSInteger row = [self emoteStatusRowIndex];
    if (section >= [self.tableView numberOfSections] ||
        row >= [self.tableView numberOfRowsInSection:section]) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
    [self.tableView reloadRowsAtIndexPaths:@[path]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (UITableViewCell *)proxyStatusCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKProxyStatusCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"TPKProxyStatusCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = TPKAdblockCustomProxyIsEnabled()
        ? L(@"adblock_proxy_custom_status") : L(@"adblock_proxy_default_status");
    cell.textLabel.textColor = UIColor.whiteColor;
    switch (self.proxyStatus) {
        case TPKAdblockProxyStatusOnline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_online");
            cell.detailTextLabel.textColor = UIColor.systemGreenColor;
            break;
        case TPKAdblockProxyStatusOffline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_offline");
            cell.detailTextLabel.textColor = UIColor.systemRedColor;
            break;
        case TPKAdblockProxyStatusChecking:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_checking");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
        default:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_unknown");
            cell.detailTextLabel.textColor = UIColor.systemGrayColor;
            break;
    }

    // Keep the manual probe next to its result and use the authenticated check.
    UIButton *pingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *pingSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                         weight:UIImageSymbolWeightSemibold];
    [pingButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"
                                  withConfiguration:pingSymbolConfiguration]
                  forState:UIControlStateNormal];
    pingButton.titleLabel.font = [UIFont systemFontOfSize:13.0
                                                     weight:UIFontWeightSemibold];
    pingButton.tintColor = TPKAccent();
    pingButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    // Explicitly size the accessory for Twitch cell styles.
    pingButton.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
    pingButton.accessibilityLabel = L(@"adblock_proxy_status_ping");
    [pingButton addTarget:self action:@selector(manualProxyPing:)
          forControlEvents:UIControlEventTouchUpInside];
    BOOL canPing = TPKAdblockConfiguredMethod() == TPKAdblockMethodProxy &&
                   TPKAdblockProxyIsEnabled();
    pingButton.enabled = canPing &&
                         self.proxyStatus != TPKAdblockProxyStatusChecking;
    cell.accessoryView = pingButton;
    return cell;
}

- (void)manualProxyPing:(UIButton *)sender {
    (void)sender;
    if (TPKAdblockConfiguredMethod() != TPKAdblockMethodProxy ||
        !TPKAdblockProxyIsEnabled() ||
        self.proxyStatus == TPKAdblockProxyStatusChecking) {
        return;
    }

    // Disable the button while the asynchronous probe is running.
    [self refreshProxyStatus];
}

- (UIButton *)proxyArrowButton:(NSString *)symbol tag:(NSInteger)tag action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = TPKAccent();
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITableViewCell *)proxyRowCellForIndex:(NSInteger)index {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TPKProxyRowCell"];
    UIButton *up = nil;
    UIButton *down = nil;
    UIButton *deleteButton = nil;
    UITextField *field = nil;
    if (cell) {
        up = (UIButton *)[cell.contentView viewWithTag:kTPKProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDownButtonTag];
        deleteButton = (UIButton *)[cell.contentView viewWithTag:kTPKProxyDeleteButtonTag];
        field = (UITextField *)[cell.contentView viewWithTag:kTPKProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"TPKProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up = [self proxyArrowButton:@"chevron.up" tag:kTPKProxyUpButtonTag
                             action:@selector(proxyUpTapped:)];
        down = [self proxyArrowButton:@"chevron.down" tag:kTPKProxyDownButtonTag
                               action:@selector(proxyDownTapped:)];
        deleteButton = [self proxyArrowButton:@"xmark.circle.fill"
                                          tag:kTPKProxyDeleteButtonTag
                                       action:@selector(proxyDeleteTapped:)];
        deleteButton.accessibilityLabel = L(@"adblock_proxy_delete");
        field = [[UITextField alloc] init];
        field.tag = kTPKProxyTextFieldTag;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.placeholder = @"user:pass@host:port";
        field.textColor = UIColor.whiteColor;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
        field.returnKeyType = UIReturnKeyDone;
        field.font = [UIFont systemFontOfSize:15];
        field.delegate = self;
        [field addTarget:self action:@selector(proxyFieldChanged:)
        forControlEvents:UIControlEventEditingChanged];
        [cell.contentView addSubview:up];
        [cell.contentView addSubview:down];
        [cell.contentView addSubview:deleteButton];
        [cell.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [up.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [up.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [up.widthAnchor constraintEqualToConstant:30],
            [up.heightAnchor constraintEqualToConstant:30],
            [down.leadingAnchor constraintEqualToAnchor:up.trailingAnchor constant:2],
            [down.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [down.widthAnchor constraintEqualToConstant:30],
            [down.heightAnchor constraintEqualToConstant:30],
            [field.leadingAnchor constraintEqualToAnchor:down.trailingAnchor constant:10],
            [deleteButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [deleteButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [deleteButton.widthAnchor constraintEqualToConstant:28],
            [deleteButton.heightAnchor constraintEqualToConstant:30],
            [field.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-6],
            [field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [field.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    cell.backgroundColor = TPKCellBg();
    field.text = index < (NSInteger)self.proxies.count ? self.proxies[index] : @"";
    BOOL canMoveUp = index > 0;
    BOOL canMoveDown = index < (NSInteger)self.proxies.count - 1;
    up.enabled = canMoveUp;
    up.alpha = canMoveUp ? 1.0 : 0.25;
    down.enabled = canMoveDown;
    down.alpha = canMoveDown ? 1.0 : 0.25;
    return cell;
}

- (UITableViewCell *)addProxyCell {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = L(@"adblock_proxy_add");
    cell.textLabel.textColor = TPKAccent();
    return cell;
}

- (UITableViewCell *)cellForProxySubview:(UIView *)view {
    UIView *candidate = view;
    while (candidate && ![candidate isKindOfClass:UITableViewCell.class]) {
        candidate = candidate.superview;
    }
    return (UITableViewCell *)candidate;
}

- (void)saveProxies {
    TPKAdblockSetCustomProxyAddresses(self.proxies);
}

- (void)proxyUpTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index <= 0) return;
    [self.proxies exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self saveProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshProxyStatus];
}

- (void)proxyDownTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.proxies.count - 1) return;
    [self.proxies exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self saveProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshProxyStatus];
}

- (void)removeProxyAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.proxies.count) return;
    [self.proxies removeObjectAtIndex:index];
    [self saveProxies];
    TPKReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = TPKAdblockProxyStatusUnknown;
    [self refreshProxyStatus];
}

- (void)proxyDeleteTapped:(UIButton *)button {
    UITableViewCell *cell = [self cellForProxySubview:button];
    NSIndexPath *path = cell ? [self.tableView indexPathForCell:cell] : nil;
    if (!path) return;
    NSInteger index = [self proxyIndexForRow:path.row];
    [self removeProxyAtIndex:index];
}

- (void)proxyFieldChanged:(UITextField *)field {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:field]];
    if (!path) return;
    if (path.section == [self tpk_emoteSectionIndex] && [self tpk_emoteSectionVisible]) {
        NSInteger emoteIndex = [self emoteProxyIndexForRow:path.row];
        if (emoteIndex < 0 || emoteIndex >= (NSInteger)self.emoteProxies.count) return;
        self.emoteProxies[emoteIndex] = field.text ?: @"";
        [self saveEmoteProxies];
        return;
    }
    if (path.section == 1 && [self tpk_comboSectionVisible]) {
        NSInteger comboIndex = [self comboProxyIndexForRow:path.row];
        if (comboIndex < 0 || comboIndex >= (NSInteger)self.comboProxies.count) return;
        self.comboProxies[comboIndex] = field.text ?: @"";
        [self saveComboProxies];
        return;
    }
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.proxies.count) return;
    self.proxies[index] = field.text ?: @"";
    [self saveProxies];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == [self tpk_emoteSectionIndex] &&
        [self tpk_emoteSectionVisible]) {
        return [self emoteProxyIndexForRow:indexPath.row] >= 0;
    }
    if (indexPath.section == 1 && [self tpk_comboSectionVisible]) {
        return [self comboProxyIndexForRow:indexPath.row] >= 0;
    }
    return indexPath.section == 1 && [self proxyIndexForRow:indexPath.row] >= 0;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section == [self tpk_emoteSectionIndex] &&
        [self tpk_emoteSectionVisible]) {
        [self removeEmoteProxyAtIndex:[self emoteProxyIndexForRow:indexPath.row]];
        return;
    }
    if (indexPath.section == 1 && [self tpk_comboSectionVisible]) {
        [self removeComboProxyAtIndex:[self comboProxyIndexForRow:indexPath.row]];
        return;
    }
    NSInteger index = [self proxyIndexForRow:indexPath.row];
    [self removeProxyAtIndex:index];
}

- (void)refreshProxyStatus {
    if (![self tpk_proxySectionVisible] || !TPKAdblockProxyIsEnabled()) return;
    NSUInteger generation = ++self.proxyStatusGeneration;
    NSString *address = nil;
    if (TPKAdblockCustomProxyIsEnabled()) {
        for (NSString *proxy in self.proxies) {
            NSString *clean = [proxy stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet];
            if (clean.length) {
                address = clean;
                break;
            }
        }
        if (!address) {
            self.proxyStatus = TPKAdblockProxyStatusOffline;
            [self reloadProxyStatusRow];
            return;
        }
    } else {
        address = TPKAdblockDefaultProxyAddress();
    }
    self.proxyStatus = TPKAdblockProxyStatusChecking;
    [self reloadProxyStatusRow];
    __weak typeof(self) weakSelf = self;
    TPKAdblockCheckProxyStatus(address, ^(TPKAdblockProxyStatus status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.proxyStatusGeneration) return;
        self.proxyStatus = status;
        [self reloadProxyStatusRow];
    });
}

- (void)reloadProxyStatusRow {
    if (![self tpk_proxySectionVisible] || !TPKAdblockProxyIsEnabled()) return;
    NSInteger row = [self statusRowIndex];
    if (self.tableView.numberOfSections <= 1 ||
        row >= [self.tableView numberOfRowsInSection:1]) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:1];
    [self.tableView reloadRowsAtIndexPaths:@[path]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:textField]];
    if (!path) return;
    if (path.section == [self tpk_emoteSectionIndex] && [self tpk_emoteSectionVisible]) {
        NSInteger emoteIndex = [self emoteProxyIndexForRow:path.row];
        if (emoteIndex >= 0 && emoteIndex < (NSInteger)self.emoteProxies.count) {
            self.emoteProxies[emoteIndex] = textField.text ?: @"";
            [self saveEmoteProxies];
        }
        if (TPKEmoteProxyCustomIsEnabled()) {
            [self refreshEmoteProxyStatus];
        }
        return;
    }
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index >= 0 && index < (NSInteger)self.proxies.count) {
        self.proxies[index] = textField.text ?: @"";
        [self saveProxies];
    }
    if (TPKAdblockProxyIsEnabled() && TPKAdblockCustomProxyIsEnabled()) {
        [self refreshProxyStatus];
    }
}

@end


// MARK: - TPKAppearancePageController  (ex-TPKEmotesPageController)
// Emote animation and CDN resolution settings.
typedef NS_ENUM(NSInteger, TPKAppearanceSection) {
    TPKAppearanceSectionIntro = 0,
    TPKAppearanceSectionInterface = 1,
    TPKAppearanceSectionEmotes = 2,
};

//    Rows logiques de la section Émotes.
typedef NS_ENUM(NSInteger, TPKAppearanceEmoteRow) {
    TPKAppearanceEmoteRowResolution = 0,
    TPKAppearanceEmoteRowPickerAnimations = 1,
    TPKAppearanceEmoteRowProviders = 2,
    TPKAppearanceEmoteRowProviderPriority = 3,
    TPKAppearanceEmoteRowPickerOpening = 4,
    TPKAppearanceEmoteRowMixedPicker = 5,
};

// Rows logiques de la section Interface (affichage, onglets).
typedef NS_ENUM(NSInteger, TPKAppearanceInterfaceRow) {
    TPKAppearanceInterfaceRowTheme = 0,        // mode OLED
    TPKAppearanceInterfaceRowTabBar = 1,
};

static NSString *TPKPickerOpeningModeTitle(NSString *mode) {
    if ([mode isEqualToString:TPKEmotePickerOpeningModeTPKChannel]) return L(@"picker_opening_7tv_channel");
    if ([mode isEqualToString:TPKEmotePickerOpeningModeBTTVChannel]) return L(@"picker_opening_bttv_channel");
    if ([mode isEqualToString:TPKEmotePickerOpeningModeFFZChannel]) return L(@"picker_opening_ffz_channel");
    if ([mode isEqualToString:TPKEmotePickerOpeningModeLastUsed]) return L(@"picker_opening_last_used");
    return L(@"picker_opening_favorites");
}

static NSArray<NSNumber *> *TPKExternalProviderValues(void) {
    return @[
        @(TPKExternalEmoteProvider7TV),
        @(TPKExternalEmoteProviderBTTV),
        @(TPKExternalEmoteProviderFFZ),
    ];
}

static NSString *TPKExternalProviderDisplayName(TPKExternalEmoteProvider provider) {
    switch (provider) {
        case TPKExternalEmoteProviderBTTV: return @"BetterTTV";
        case TPKExternalEmoteProviderFFZ: return @"FrankerFaceZ";
        case TPKExternalEmoteProvider7TV:
        default: return @"7TV";
    }
}

static UIImage *TPKExternalProviderLogo(TPKExternalEmoteProvider provider) {
    NSString *base64 = nil;
    switch (provider) {
        case TPKExternalEmoteProviderBTTV: base64 = kTPKBTTVLogoBase64; break;
        case TPKExternalEmoteProviderFFZ: base64 = kTPKFFZLogoBase64; break;
        case TPKExternalEmoteProvider7TV:
        default: base64 = kTPKLogoBase64; break;
    }
    if (!base64.length) return nil;
    NSData *data = [[NSData alloc]
        initWithBase64EncodedString:base64
                             options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data.length) return nil;
    // Use each provider asset's native scale to normalize logo sizes.
    CGFloat logicalScale = provider == TPKExternalEmoteProvider7TV ? 3.5 : 16.0;
    UIImage *image = [UIImage imageWithData:data scale:logicalScale];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static NSString *TPKEnabledExternalProviderSummary(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSNumber *value in TPKExternalProviderValues()) {
        TPKExternalEmoteProvider provider = (TPKExternalEmoteProvider)value.integerValue;
        if ([TPKEmoteProviderSettings isProviderEnabled:provider])
            [names addObject:TPKExternalProviderDisplayName(provider)];
    }
    return names.count > 0
        ? [names componentsJoinedByString:@" · "]
        : L(@"setting_emote_providers_none");
}

// Reusable multi-selection screen used by providers and chat elements.
@interface TPKMultiSelectionOption : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, copy) BOOL (^isEnabled)(void);
@property (nonatomic, copy) void (^setEnabled)(BOOL enabled);
@end

@implementation TPKMultiSelectionOption
@end

static NSArray<TPKMultiSelectionOption *> *TPKExternalProviderSelectionOptions(void) {
    NSMutableArray<TPKMultiSelectionOption *> *options = [NSMutableArray arrayWithCapacity:3];
    for (NSNumber *value in TPKExternalProviderValues()) {
        TPKExternalEmoteProvider provider =
            (TPKExternalEmoteProvider)value.integerValue;
        TPKExternalEmoteProvider selectedProvider = provider;
        TPKMultiSelectionOption *option = [TPKMultiSelectionOption new];
        option.identifier = TPKEmoteProviderIdentifier(provider);
        option.title = TPKExternalProviderDisplayName(provider);
        option.image = TPKExternalProviderLogo(provider);
        option.isEnabled = ^BOOL {
            return [TPKEmoteProviderSettings isProviderEnabled:selectedProvider];
        };
        option.setEnabled = ^(BOOL enabled) {
            [TPKEmoteProviderSettings setProvider:selectedProvider enabled:enabled];
        };
        [options addObject:option];
    }
    return options;
}

@interface TPKMultiSelectionController : UITableViewController
@property (nonatomic, copy, nullable) void (^onFinish)(void);
- (instancetype)initWithTitle:(NSString *)title
                       options:(NSArray<TPKMultiSelectionOption *> *)options;
@end

@interface TPKMultiSelectionController ()
@property (nonatomic, copy) NSString *selectionTitle;
@property (nonatomic, copy) NSArray<TPKMultiSelectionOption *> *options;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledByIdentifier;
@end

@implementation TPKMultiSelectionController

- (instancetype)initWithTitle:(NSString *)title
                       options:(NSArray<TPKMultiSelectionOption *> *)options {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _selectionTitle = [title copy];
        _options = [options copy];
        _enabledByIdentifier = [NSMutableDictionary dictionaryWithCapacity:options.count];
        for (TPKMultiSelectionOption *option in _options) {
            _enabledByIdentifier[option.identifier] = @(option.isEnabled());
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.selectionTitle;
    TPKStyleTableView(self.tableView);
    self.view.tintColor = TPKAccent();
    self.tableView.tintColor = TPKAccent();
    self.navigationController.navigationBar.tintColor = TPKAccent();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(tpk_cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(tpk_finish)];
    TPKRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.row >= (NSInteger)self.options.count)
        return [[UITableViewCell alloc] init];
    TPKMultiSelectionOption *option = self.options[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = option.title;
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    cell.textLabel.textColor = UIColor.whiteColor;
    // Let long option titles wrap to multiple lines instead of truncating.
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.imageView.image = option.image;
    cell.accessoryType = [self.enabledByIdentifier[option.identifier] boolValue]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.options.count) return;
    TPKMultiSelectionOption *option = self.options[indexPath.row];
    BOOL enabled = [self.enabledByIdentifier[option.identifier] boolValue];
    self.enabledByIdentifier[option.identifier] = @(!enabled);
    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tpk_cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)tpk_finish {
    for (TPKMultiSelectionOption *option in self.options) {
        BOOL oldValue = option.isEnabled();
        BOOL newValue = [self.enabledByIdentifier[option.identifier] boolValue];
        if (oldValue != newValue) option.setEnabled(newValue);
    }
    void (^finish)(void) = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:finish];
}

@end

@implementation TPKAppearancePageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_apparence");
    TPKStyleTableView(self.tableView);
    TPKRegisterOLEDObserver(self);
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Visible emote rows; legacy animation preferences remain compatible.
- (NSArray<NSNumber *> *)tpk_visibleEmoteRows {
    return TPKVisibleRowIndexes(@[
        @(TPKAppearanceEmoteRowResolution),
        @(TPKAppearanceEmoteRowPickerAnimations),
        @(TPKAppearanceEmoteRowProviders),
        @(TPKAppearanceEmoteRowProviderPriority),
        @(TPKAppearanceEmoteRowPickerOpening),
        @(TPKAppearanceEmoteRowMixedPicker),
    ], @{});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == TPKAppearanceSectionIntro) return 1;
    if (s == TPKAppearanceSectionEmotes) return [self tpk_visibleEmoteRows].count;
    if (s == TPKAppearanceSectionInterface) return 2;
    return 0;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return (s == TPKAppearanceSectionIntro) ? 8 : 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (s == TPKAppearanceSectionIntro) return [[UIView alloc] init];
    if (s == TPKAppearanceSectionEmotes) return TPKSectionHeader(L(@"section_emotes"), NO, nil);
    if (s == TPKAppearanceSectionInterface) return TPKSectionHeader(L(@"section_interface"), NO, nil);
    return [[UIView alloc] init];
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    // Resolution details are shown from the row info button.
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == TPKAppearanceSectionIntro) {
        // Chat settings are available from the picker ("Aa").
        return TPKDescriptionCell(@"desc_chat_custom_location");
    }
    if (ip.section == TPKAppearanceSectionEmotes) {
        NSArray<NSNumber *> *visible = [self tpk_visibleEmoteRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case TPKAppearanceEmoteRowPickerAnimations:
                return TPKNavCell(L(@"switch_animations_picker"),
                    TPKValueWithDefaultMark(
                        TPKPickerAnimationsModeTitle(
                            TPKCurrentPickerAnimationsMode()),
                        TPKCurrentPickerAnimationsMode() ==
                            TPKPickerAnimationsModeEnabled),
                    @"sparkles", TPKAccent(), nil);
            case TPKAppearanceEmoteRowPickerOpening: {
                NSString *mode = [TPKEmoteProviderSettings pickerOpeningMode];
                return TPKNavCell(L(@"setting_emote_picker_opening"),
                    TPKPickerOpeningModeTitle(mode),
                    @"rectangle.portrait.and.arrow.forward", TPKAccent(), nil);
            }
            case TPKAppearanceEmoteRowMixedPicker: {
                UITableViewCell *cell = TPKSwitchCell(L(@"setting_emote_picker_mixed"),
                    @"square.stack.3d.up.fill", UIColor.systemPurpleColor,
                    [TPKEmoteProviderSettings mixedPickerEnabled],
                    self, @selector(toggleMixedPicker:), nil);
                // Logo TwitchPlusK à la place du symbole.
                NSData *tpkData = [[NSData alloc]
                    initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
                UIImage *tpkImg = [UIImage imageWithData:tpkData scale:2.0];
                if (tpkImg) {
                    for (UIView *subview in cell.contentView.subviews) {
                        if ([subview isKindOfClass:UIImageView.class]) {
                            ((UIImageView *)subview).image =
                                [tpkImg imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
                            break;
                        }
                    }
                }
                return cell;
            }
            case TPKAppearanceEmoteRowProviders:
                return TPKNavCell(L(@"setting_emote_providers"),
                    TPKEnabledExternalProviderSummary(),
                    @"person.3.fill", TPKAccent(), nil);
            case TPKAppearanceEmoteRowProviderPriority: {
                NSArray *priority = [TPKEmoteProviderSettings providerPriority];
                NSString *subtitle = [priority componentsJoinedByString:@" > "];
                return TPKNavCell(L(@"setting_emote_provider_priority"), subtitle,
                    @"arrow.up.arrow.down.circle", TPKAccent(), nil);
            }
            case TPKAppearanceEmoteRowResolution:
            default: {
                // Use the standard choice sheet; details are behind the info button.
                NSInteger current = [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
                current = MIN(4, MAX(1, current));
                return TPKNavCell(L(@"setting_emote_resolution"),
                    TPKValueWithDefaultMark(
                        [NSString stringWithFormat:@"%ldx", (long)current],
                        current == kTPKDefaultEmoteResolution),
                    @"photo.stack.fill", TPKAccent(),
                    @"setting_resolution_clears_cache");
            }
        }
    }
    if (ip.section == TPKAppearanceSectionInterface) {
        switch ((TPKAppearanceInterfaceRow)ip.row) {
            case TPKAppearanceInterfaceRowTheme:
                return TPKSwitchCell(L(@"switch_oled_mode"),
                            @"circle.lefthalf.filled",
                            UIColor.systemIndigoColor,
                            TPKOLEDModeEnabled(),
                            self, @selector(toggleOLEDMode:), @"desc_oled_mode");
            case TPKAppearanceInterfaceRowTabBar:
                // Les deux réglages sont liés : ils se règlent sur l'écran dédié.
                return TPKNavCell(L(@"section_tab_bar"), nil,
                    @"rectangle.split.3x1.fill", TPKAccent(), @"desc_tab_bar");
            default:
                break;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == TPKAppearanceSectionInterface) {
        if (ip.row == TPKAppearanceInterfaceRowTabBar) {
            [self.navigationController pushViewController:
                [[TPKTabBarSettingsController alloc] init] animated:YES];
        }
        return;
    }
    if (ip.section != TPKAppearanceSectionEmotes) return;
    NSArray<NSNumber *> *visible = [self tpk_visibleEmoteRows];
    if (ip.row >= (NSInteger)visible.count) return;
    UITableViewCell *anchor = [tv cellForRowAtIndexPath:ip];
    if (visible[ip.row].integerValue == TPKAppearanceEmoteRowPickerAnimations) {
        [self presentPickerAnimationsPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == TPKAppearanceEmoteRowResolution) {
        [self presentResolutionPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == TPKAppearanceEmoteRowProviders) {
        TPKMultiSelectionController *providers =
            [[TPKMultiSelectionController alloc]
                initWithTitle:L(@"setting_emote_providers")
                       options:TPKExternalProviderSelectionOptions()];
        __weak typeof(self) weakSelf = self;
        providers.onFinish = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            TPKReloadCellWithoutJump(strongSelf.tableView, anchor);
        };
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:providers];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:navigation animated:YES completion:nil];
    } else if (visible[ip.row].integerValue == TPKAppearanceEmoteRowProviderPriority) {
        [self presentProviderPriorityPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == TPKAppearanceEmoteRowPickerOpening) {
        [self presentPickerOpeningPickerFromCell:anchor];
    }
}

- (void)toggleOLEDMode:(UISwitch *)sw {
    BOOL changed = TPKOLEDModeEnabled() != sw.isOn;
    TPKOLEDModeSetEnabled(sw.isOn);
    if (!changed) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"oled_restart_title")
                         message:L(@"oled_restart_message")
                  preferredStyle:UIAlertControllerStyleAlert];
    alert.view.tintColor = TPKAccent();
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    TPKPresentAlert(self, alert);
}

- (void)presentPickerAnimationsPickerFromCell:(UIView *)anchor {
    TPKPickerAnimationsMode current = TPKCurrentPickerAnimationsMode();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"switch_animations_picker")
                         message:L(@"picker_animations_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    NSArray<NSNumber *> *modes = @[
        @(TPKPickerAnimationsModeDisabled),
        @(TPKPickerAnimationsModeEnabled),
        @(TPKPickerAnimationsModeFavoritesOnly),
    ];
    for (NSNumber *value in modes) {
        TPKPickerAnimationsMode mode =
            (TPKPickerAnimationsMode)value.integerValue;
        NSString *title = TPKValueWithDefaultMark(
            TPKPickerAnimationsModeTitle(mode),
            mode == TPKPickerAnimationsModeEnabled);
        if (mode == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            TPKManager *manager = [TPKManager sharedManager];
            manager.showPickerAnimations =
                mode != TPKPickerAnimationsModeDisabled;
            manager.showPickerAnimationsFavoritesOnly =
                mode == TPKPickerAnimationsModeFavoritesOnly;
            TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

- (void)toggleMixedPicker:(UISwitch *)sw {
    [TPKEmoteProviderSettings setMixedPickerEnabled:sw.isOn];
}

- (void)presentPickerOpeningPickerFromCell:(UIView *)anchor {
    NSString *current = [TPKEmoteProviderSettings pickerOpeningMode];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_picker_opening")
                         message:L(@"setting_emote_picker_opening_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();
    NSArray<NSArray<NSString *> *> *options = @[
        @[TPKEmotePickerOpeningModeFavorites, L(@"picker_opening_favorites")],
        @[TPKEmotePickerOpeningModeTPKChannel, L(@"picker_opening_7tv_channel")],
        @[TPKEmotePickerOpeningModeBTTVChannel, L(@"picker_opening_bttv_channel")],
        @[TPKEmotePickerOpeningModeFFZChannel, L(@"picker_opening_ffz_channel")],
        @[TPKEmotePickerOpeningModeLastUsed, L(@"picker_opening_last_used")],
    ];
    __weak typeof(self) weakSelf = self;
    for (NSArray<NSString *> *option in options) {
        NSString *mode = option[0];
        NSString *title = [mode isEqualToString:current]
            ? [NSString stringWithFormat:@"✓  %@", option[1]] : option[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [TPKEmoteProviderSettings setPickerOpeningMode:mode];
            TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

- (void)presentProviderPriorityPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *current = [TPKEmoteProviderSettings providerPriority];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_provider_priority")
                         message:L(@"setting_emote_provider_priority_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();
    NSArray<NSString *> *labels = @[@"7TV", @"BetterTTV", @"FrankerFaceZ"];
    // Use explicit presets for VoiceOver compatibility.
    NSArray<NSArray<NSString *> *> *orders = @[
        @[@"7tv", @"bttv", @"ffz"],
        @[@"bttv", @"7tv", @"ffz"],
        @[@"ffz", @"7tv", @"bttv"],
        @[@"7tv", @"ffz", @"bttv"],
        @[@"bttv", @"ffz", @"7tv"],
        @[@"ffz", @"bttv", @"7tv"],
    ];
    for (NSUInteger index = 0; index < orders.count; index++) {
        NSArray *order = orders[index];
        NSString *title = @"";
        // Keep provider names explicit and ordered.
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *identifier in order) {
            TPKExternalEmoteProvider p = TPKEmoteProviderFromIdentifier(identifier);
            [names addObject:labels[p]];
        }
        title = [names componentsJoinedByString:@" > "];
        if ([order isEqualToArray:current]) title = [title stringByAppendingString:@" ✓"];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                (void)action;
                [TPKEmoteProviderSettings setProviderPriority:order];
                TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    TPKPresentAlert(self, sheet);
}

// Emote-resolution choice sheet; clear the cache when the value changes.
- (void)presentResolutionPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_resolution")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();
        NSInteger current = [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
    current = MIN(4, MAX(1, current));
    for (NSInteger resolution = 1; resolution <= 4; resolution++) {
        NSString *title = [NSString stringWithFormat:@"%ldx", (long)resolution];
        if (resolution == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf tpk_applyEmoteResolution:resolution anchor:anchor];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    TPKPresentAlert(self, sheet);
}

- (void)tpk_applyEmoteResolution:(NSInteger)resolution anchor:(UIView *)anchor {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    if (resolution == cfg.emoteImageResolution) return;

    // Persist through the shared setter so aliases and UI notifications stay in sync.
    [cfg setValue:(CGFloat)resolution forSizeKey:@"emoteImageResolution"];
    __weak typeof(self) weakSelf = self;
    [[TPKManager sharedManager] clearAllCachesWithCompletion:^(NSUInteger clearedCount) {
        (void)clearedCount;
        TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
    }];
}

@end



// MARK: - TPKContentPageController  (ex-Statistiques + ex-Contrôle du stream)
// Favorites, stream options and player settings.

typedef NS_ENUM(NSInteger, TPKContentSection) {
    TPKContentSectionFavorites = 0,  // Favorites and import
    TPKContentSectionHome      = 1,  // Home, points and rotation
    TPKContentSectionPlayer    = 2,  // Player and gestures
};

// Noms et icônes des onglets de la barre (une ligne par onglet, ordre réel).
static NSString *TPKTabItemName(TPKTabItem item) {
    switch (item) {
        case TPKTabItemHome:     return L(@"tab_name_home");
        case TPKTabItemExplore:  return L(@"tab_name_explore");
        case TPKTabItemCreate:   return L(@"tab_name_create");
        case TPKTabItemActivity: return L(@"tab_name_activity");
        case TPKTabItemProfile:  return L(@"tab_name_profile");
    }
    return @"";
}

// Nom court de la sous-page d'une destination (« Live », « Catégories »…),
// nil pour les destinations qui n'en ont pas.
static NSString *TPKTabPageTitle(TPKLaunchDestination destination) {
    switch (destination) {
        case TPKLaunchDestinationHomeFollowing:      return L(@"tab_page_following");
        case TPKLaunchDestinationHomeLive:           return L(@"tab_page_live");
        case TPKLaunchDestinationHomeClips:          return L(@"tab_page_clips");
        case TPKLaunchDestinationBrowseCategories:   return L(@"tab_page_categories");
        case TPKLaunchDestinationBrowseLiveChannels: return L(@"tab_page_live_channels");
        default:                                      return nil;
    }
}

static NSString *TPKTabItemIcon(TPKTabItem item) {
    switch (item) {
        case TPKTabItemHome:     return @"house.fill";
        case TPKTabItemExplore:  return @"safari.fill";
        case TPKTabItemCreate:   return @"plus.circle.fill";
        case TPKTabItemActivity: return @"bell.fill";
        case TPKTabItemProfile:  return @"person.crop.circle.fill";
    }
    return @"circle.fill";
}

// Couleur propre à chaque onglet ; un onglet masqué reste gris.
static UIColor *TPKTabItemColor(TPKTabItem item) {
    switch (item) {
        case TPKTabItemHome:     return TPKAccent();                                             // violet Twitch
        case TPKTabItemExplore:  return [UIColor colorWithRed:0.30 green:0.62 blue:1.00 alpha:1.0]; // bleu
        case TPKTabItemCreate:   return [UIColor colorWithRed:0.30 green:0.75 blue:0.45 alpha:1.0]; // vert
        case TPKTabItemActivity: return [UIColor colorWithRed:0.95 green:0.35 blue:0.50 alpha:1.0]; // rose
        case TPKTabItemProfile:  return [UIColor colorWithRed:0.25 green:0.70 blue:0.95 alpha:1.0]; // cyan
    }
    return TPKAccent();
}

// La ligne « Défaut » n'est pas un onglet : elle porte la couleur du tweak.
static UIColor *TPKTabItemColorDefaultRow(void) {
    return TPKAccent();
}

// L'onglet visé par une destination de lancement est-il masqué ? Dans cet état,
// la destination ne peut pas être honorée au démarrage.
static BOOL TPKLaunchDestinationTabHidden(TPKLaunchDestination destination) {
    NSInteger tab = tpk_launchDestinationTab(destination);
    return tab >= 0 && tpk_tabItemHidden((TPKTabItem)tab);
}

// Destination par défaut d'un onglet : sert de repli quand l'onglet choisi
// comme écran de lancement vient d'être masqué.
static TPKLaunchDestination TPKDefaultDestinationForTab(TPKTabItem item) {
    switch (item) {
        case TPKTabItemHome:     return TPKLaunchDestinationHomeFollowing;
        case TPKTabItemExplore:  return TPKLaunchDestinationBrowseCategories;
        case TPKTabItemActivity: return TPKLaunchDestinationActivity;
        case TPKTabItemProfile:  return TPKLaunchDestinationProfile;
        case TPKTabItemCreate:   break;
    }
    return TPKLaunchDestinationDefault;
}

// Repli : l'onglet visible le plus proche du masqué, en commençant par le
// voisin de gauche (le plus proche dans l'ordre de la barre).
static TPKLaunchDestination TPKNearestVisibleDestination(TPKTabItem item) {
    for (NSInteger delta = 1; delta < TPK_TAB_ITEM_COUNT; delta++) {
        NSInteger before = (NSInteger)item - delta;
        if (before >= 0 && !tpk_tabItemHidden((TPKTabItem)before)) {
            TPKLaunchDestination destination =
                TPKDefaultDestinationForTab((TPKTabItem)before);
            if (destination != TPKLaunchDestinationDefault) return destination;
        }
        NSInteger after = (NSInteger)item + delta;
        if (after < TPK_TAB_ITEM_COUNT && !tpk_tabItemHidden((TPKTabItem)after)) {
            TPKLaunchDestination destination =
                TPKDefaultDestinationForTab((TPKTabItem)after);
            if (destination != TPKLaunchDestinationDefault) return destination;
        }
    }
    return TPKLaunchDestinationDefault;
}

// Rows for the Home and Playback section. L'écran de lancement est réglé dans la
// section de la barre d'onglets, avec laquelle il est lié.
typedef NS_ENUM(NSInteger, TPKContentHomeRow) {
    TPKContentHomeRowHideStories    = 0,
    TPKContentHomeRowKeepLiveFeed   = 1,
    TPKContentHomeRowAutoCollect    = 2,
};

typedef NS_ENUM(NSInteger, TPKContentPlayerRow) {
    TPKContentPlayerRowDelay = 0,
    TPKContentPlayerRowStats = 1,
    TPKContentPlayerRowLockButton = 2,
    TPKContentPlayerRowGestures = 3,
    TPKContentPlayerRowLeftSide = 4,
    TPKContentPlayerRowRightSide = 5,
    TPKContentPlayerRowSensitivity = 6,
    TPKContentPlayerRowDeadZone = 7,
};

static NSString *TPKPlayerGestureAssignmentTitle(
    TPKPlayerGestureAssignment assignment) {
    switch (assignment) {
        case TPKPlayerGestureAssignmentVolume:
            return L(@"player_gestures_assignment_volume");
        case TPKPlayerGestureAssignmentBrightness:
            return L(@"player_gestures_assignment_brightness");
        case TPKPlayerGestureAssignmentDisabled:
        default:
            return L(@"player_gestures_assignment_disabled");
    }
}

// Maps the four display modes to the two legacy runtime preferences.
typedef NS_ENUM(NSInteger, TPKOrientationLockSetting) {
    TPKOrientationLockSettingDisabled = 0,
    TPKOrientationLockSettingManual,
    TPKOrientationLockSettingAutoLeft,
    TPKOrientationLockSettingAutoRight,
    TPKOrientationLockSettingAutoBoth,
};

static NSString *TPKLaunchDestinationTitle(TPKLaunchDestination destination) {
    switch (destination) {
        case TPKLaunchDestinationHomeFollowing:      return L(@"launch_home_following");
        case TPKLaunchDestinationHomeLive:           return L(@"launch_home_live");
        case TPKLaunchDestinationHomeClips:          return L(@"launch_home_clips");
        case TPKLaunchDestinationBrowseCategories:   return L(@"launch_browse_categories");
        case TPKLaunchDestinationBrowseLiveChannels: return L(@"launch_browse_live_channels");
        case TPKLaunchDestinationActivity:            return L(@"launch_activity");
        case TPKLaunchDestinationProfile:             return L(@"launch_profile");
        case TPKLaunchDestinationDefault:             return L(@"launch_default");
    }
    return L(@"launch_default");
}

static TPKOrientationLockSetting TPKCurrentOrientationLockSetting(void) {
    if (!tpk_orientationLockButtonEnabled()) {
        return TPKOrientationLockSettingDisabled;
    }
    switch (tpk_autoOrientationLockMode()) {
        case TPKAutoOrientationLockModeLandscapeLeft:
            return TPKOrientationLockSettingAutoLeft;
        case TPKAutoOrientationLockModeLandscapeRight:
            return TPKOrientationLockSettingAutoRight;
        case TPKAutoOrientationLockModeBothLandscapes:
            return TPKOrientationLockSettingAutoBoth;
        case TPKAutoOrientationLockModeDisabled:
        default:
            return TPKOrientationLockSettingManual;
    }
}

static NSString *TPKOrientationLockSettingTitle(TPKOrientationLockSetting setting) {
    switch (setting) {
        case TPKOrientationLockSettingManual:
            return L(@"orientation_mode_manual");
        case TPKOrientationLockSettingAutoLeft:
            return L(@"orientation_mode_auto_left");
        case TPKOrientationLockSettingAutoRight:
            return L(@"orientation_mode_auto_right");
        case TPKOrientationLockSettingAutoBoth:
            return L(@"orientation_mode_auto_both");
        case TPKOrientationLockSettingDisabled:
        default:
            return L(@"orientation_mode_disabled");
    }
}

static NSString *const kTPKPCFavoritesKey = @"ui.emote_menu.favorites";

// Supports known 7TV PC export nesting without relying on a format number.
static NSArray *TPKFindPCFavoritesArray(id object, NSUInteger depth) {
    if (depth > 24) return nil;

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        id directValue = dictionary[kTPKPCFavoritesKey];
        if ([directValue isKindOfClass:NSArray.class]) return directValue;

        for (id value in dictionary.allValues) {
            NSArray *candidate = TPKFindPCFavoritesArray(value, depth + 1);
            if (candidate) return candidate;
        }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            NSArray *candidate = TPKFindPCFavoritesArray(value, depth + 1);
            if (candidate) return candidate;
        }
    }
    return nil;
}

static NSArray *TPKPCFavoritesArrayFromJSON(id json) {
    if ([json isKindOfClass:NSArray.class]) return json;
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *root = (NSDictionary *)json;

    // Current format: { "scopes": { "global": { ... } } }.
    NSDictionary *scopes = [root[@"scopes"] isKindOfClass:NSDictionary.class]
        ? root[@"scopes"] : nil;
    NSDictionary *global = [scopes[@"global"] isKindOfClass:NSDictionary.class]
        ? scopes[@"global"] : nil;
    id favorites = global[kTPKPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    // Previous known formats.
    NSDictionary *settings = [root[@"settings"] isKindOfClass:NSDictionary.class]
        ? root[@"settings"] : nil;
    favorites = settings[kTPKPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    favorites = root[kTPKPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    // Bounded fallback for future nesting changes.
    return TPKFindPCFavoritesArray(root, 0);
}

static NSArray<NSString *> *TPKTPKIDsFromPCFavorites(NSArray *rawFavorites) {
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSet];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (id entry in rawFavorites) {
        if (![entry isKindOfClass:NSString.class]) continue;
        NSString *value = [(NSString *)entry stringByTrimmingCharactersInSet:whitespace];
        NSRange separator = [value rangeOfString:@":"];
        if (separator.location == NSNotFound || separator.location == 0 ||
            separator.location == value.length - 1) continue;

        NSString *provider = [value substringToIndex:separator.location];
        if ([provider caseInsensitiveCompare:@"7TV"] != NSOrderedSame) continue;

        NSString *emoteID = [value substringFromIndex:separator.location + 1];
        emoteID = [emoteID stringByTrimmingCharactersInSet:whitespace];
        if (emoteID.length) [ids addObject:emoteID];
    }
    return ids.array;
}

@interface TPKContentPageController () <UIDocumentPickerDelegate>
- (void)presentOrientationLockSettingPickerFromCell:(UIView *)anchor;
- (void)presentPlayerGestureAssignmentPickerFromCell:(UIView *)anchor
                                                side:(BOOL)leftSide;
- (void)presentPlayerGestureDeadZonePickerFromCell:(UIView *)anchor;
- (void)playerGestureSensitivityDecrease:(UIButton *)button;
- (void)playerGestureSensitivityIncrease:(UIButton *)button;
- (void)togglePlayerTools:(UISwitch *)sw;
- (void)togglePlayerStats:(UISwitch *)sw;
@end

@implementation TPKContentPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_contenu");
    TPKStyleTableView(self.tableView);
    TPKRegisterOLEDObserver(self);
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(tpk_autoClaimRuntimeStateDidChange:)
            name:TPKAutoClaimRuntimeStateDidChangeNotification object:nil];
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)tpk_autoClaimRuntimeStateDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded || !self.view.window) return;
    [TPKInfoTooltip dismiss];
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Refresh the favorite count when returning to this screen.
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [TPKInfoTooltip dismiss];
}

// Visible Home and Playback rows.
- (NSArray<NSNumber *> *)tpk_visibleHomeRows {
    return TPKVisibleRowIndexes(@[
        @(TPKContentHomeRowHideStories),
        @(TPKContentHomeRowKeepLiveFeed),
        @(TPKContentHomeRowAutoCollect),
    ], @{});
}

- (NSArray<NSNumber *> *)tpk_visiblePlayerRows {
    return TPKVisibleRowIndexes(@[
        @(TPKContentPlayerRowDelay),
        @(TPKContentPlayerRowLockButton),
        @(TPKContentPlayerRowGestures),
    ], @{
        @(TPKContentPlayerRowStats): @(tpk_playerToolsEnabled()),
        @(TPKContentPlayerRowLeftSide): @(tpk_playerGesturesEnabled()),
        @(TPKContentPlayerRowRightSide): @(tpk_playerGesturesEnabled()),
        @(TPKContentPlayerRowSensitivity): @(tpk_playerGesturesEnabled()),
        @(TPKContentPlayerRowDeadZone): @(tpk_playerGesturesEnabled()),
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == TPKContentSectionFavorites) return 1;
    if (s == TPKContentSectionHome) return [self tpk_visibleHomeRows].count;
    if (s == TPKContentSectionPlayer) return [self tpk_visiblePlayerRows].count;
    return 0;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    // Favorites row: title and export subtitle.
    if (ip.section == TPKContentSectionFavorites) return 60;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case TPKContentSectionFavorites: return TPKSectionHeader(L(@"section_favoris"), NO, nil);
        // Section details are available from the header info button.
        case TPKContentSectionHome:      return TPKSectionHeader(L(@"section_home_playback"), NO,
                                              @"desc_home_playback_settings");
        case TPKContentSectionPlayer:    return TPKSectionHeader(L(@"section_player_controls"), NO, nil);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    // Section details are shown through header or row info buttons.
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    if (ip.section == TPKContentSectionHome) {
        NSArray<NSNumber *> *visible = [self tpk_visibleHomeRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case TPKContentHomeRowHideStories:
                return TPKSwitchCell(L(@"switch_hide_twitch_stories"),
                    @"circle.slash", [UIColor colorWithRed:0.95 green:0.35 blue:0.50 alpha:1.0],
                    tpk_hideTwitchStoriesEnabled(), self, @selector(toggleHideTwitchStories:), nil);
            case TPKContentHomeRowKeepLiveFeed:
                return TPKSwitchCell(L(@"switch_keep_live_feed_playing"),
                    @"play.circle.fill", [UIColor colorWithRed:0.30 green:0.75 blue:0.45 alpha:1.0],
                    tpk_keepLiveFeedPlayingEnabled(), self, @selector(toggleKeepLiveFeedPlaying:), nil);
            case TPKContentHomeRowAutoCollect:
                return TPKSwitchCell(
                    L(@"switch_auto_collect_title"),
                    @"giftcard.fill",
                    [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0],
                    TPKBoolDefaultYes(kTCLiveAutoCollectChannelPoints),
                    self,
                    @selector(toggleAutoCollect:),
                    nil);
        }
        return [[UITableViewCell alloc] init];
    }

    if (ip.section == TPKContentSectionPlayer) {
        NSArray<NSNumber *> *visible = [self tpk_visiblePlayerRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case TPKContentPlayerRowDelay:
                return TPKSwitchCell(L(@"player_tools_enable"),
                    @"clock.arrow.circlepath", [UIColor colorWithRed:1.0 green:0.62 blue:0.20 alpha:1.0],
                    tpk_playerToolsEnabled(), self,
                    @selector(togglePlayerTools:), @"desc_player_tools");
            case TPKContentPlayerRowStats:
                return TPKSwitchCell(L(@"player_stats_enable"),
                    @"chart.bar.xaxis", [UIColor colorWithRed:0.35 green:0.60 blue:1.0 alpha:1.0],
                    tpk_playerStatsEnabled(), self,
                    @selector(togglePlayerStats:), @"desc_player_stats");
            case TPKContentPlayerRowLockButton: {
                TPKOrientationLockSetting setting = TPKCurrentOrientationLockSetting();
                return TPKNavCell(L(@"switch_orientation_lock_button"),
                    TPKValueWithDefaultMark(TPKOrientationLockSettingTitle(setting),
                        setting == TPKOrientationLockSettingDisabled),
                    @"lock.rotation", [UIColor colorWithRed:0.60 green:0.63 blue:0.70 alpha:1.0], @"desc_orientation_lock_settings");
            }
            case TPKContentPlayerRowGestures:
                return TPKSwitchCell(L(@"player_gestures_enable"),
                    @"hand.tap.fill", [UIColor colorWithRed:0.25 green:0.80 blue:0.55 alpha:1.0],
                    tpk_playerGesturesEnabled(), self,
                    @selector(togglePlayerGestures:), @"desc_player_gestures");
            case TPKContentPlayerRowLeftSide: {
                TPKPlayerGestureAssignment assignment =
                    tpk_playerGesturesLeftAssignment();
                return TPKRightValueNavCell(L(@"player_gestures_left_side"),
                    TPKPlayerGestureAssignmentTitle(assignment),
                    @"arrow.left.circle.fill", [UIColor colorWithRed:0.40 green:0.70 blue:1.0 alpha:1.0]);
            }
            case TPKContentPlayerRowRightSide: {
                TPKPlayerGestureAssignment assignment =
                    tpk_playerGesturesRightAssignment();
                return TPKRightValueNavCell(L(@"player_gestures_right_side"),
                    TPKPlayerGestureAssignmentTitle(assignment),
                    @"arrow.right.circle.fill", [UIColor colorWithRed:0.55 green:0.55 blue:1.0 alpha:1.0]);
            }
            case TPKContentPlayerRowSensitivity:
                return TPKPlayerGestureSensitivityCell(
                    tpk_playerGesturesSensitivity(), self);
            case TPKContentPlayerRowDeadZone:
                return TPKNavCell(L(@"player_gestures_dead_zone"),
                    TPKValueWithDefaultMark(
                        [NSString stringWithFormat:@"%ld%%",
                         (long)tpk_playerGesturesDeadZone()],
                        tpk_playerGesturesDeadZone() == 20),
                    @"circle", [UIColor colorWithRed:1.0 green:0.78 blue:0.25 alpha:1.0], nil);
        }
        return [[UITableViewCell alloc] init];
    }

    // Favorites section: list, count and integrated import.
    NSArray *favs = [[TPKEmoteCatalog sharedCatalog] favoriteKeysSnapshot];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = TPKCellBg();
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    UIView *icon = TPKFavoriteEmotePreview(favs);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(@"section_favoris");
    lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.text = L(@"subtitle_import_from_pc");
    subLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    subLbl.textColor = TPKGray();
    subLbl.numberOfLines = 1;
    subLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *textStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[lbl, subLbl]];
    textStack.axis      = UILayoutConstraintAxisVertical;
    textStack.spacing   = 2;
    textStack.alignment = UIStackViewAlignmentLeading;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *countLbl = [[UILabel alloc] init];
    countLbl.text = [NSString stringWithFormat:@"%lu", (unsigned long)favs.count];
    countLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    countLbl.textColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];
    countLbl.translatesAutoresizingMaskIntoConstraints = NO;

    // Integrated import uses the existing file picker.
    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *importCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
    [importBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.down"
                         withConfiguration:importCfg]
               forState:UIControlStateNormal];
    importBtn.tintColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];
    importBtn.accessibilityLabel = L(@"action_import_from_pc");
    importBtn.showsTouchWhenHighlighted = YES;
    importBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [importBtn addTarget:self action:@selector(importFavoritesFromFile)
       forControlEvents:UIControlEventTouchUpInside];

    [cell.contentView addSubview:textStack];
    [cell.contentView addSubview:countLbl];
    [cell.contentView addSubview:importBtn];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [textStack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [textStack.topAnchor    constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [importBtn.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
        [importBtn.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [importBtn.widthAnchor    constraintEqualToConstant:30],
        [importBtn.heightAnchor   constraintEqualToConstant:30],
        [countLbl.trailingAnchor constraintEqualToAnchor:importBtn.leadingAnchor constant:-10],
        [countLbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:countLbl.leadingAnchor constant:-8],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == TPKContentSectionFavorites && ip.row == 0) {
        TPKFavoritesListController *favsVC = [[TPKFavoritesListController alloc] init];
        [self.navigationController pushViewController:favsVC animated:YES];
        return;
    }
    UITableViewCell *anchor = [tv cellForRowAtIndexPath:ip];
    if (ip.section == TPKContentSectionPlayer) {
        NSArray<NSNumber *> *visible = [self tpk_visiblePlayerRows];
        if (ip.row >= (NSInteger)visible.count) return;
        NSInteger logicalRow = visible[ip.row].integerValue;
        if (logicalRow == TPKContentPlayerRowLockButton) {
            [self presentOrientationLockSettingPickerFromCell:anchor];
            return;
        }
        if (logicalRow == TPKContentPlayerRowLeftSide) {
            [self presentPlayerGestureAssignmentPickerFromCell:anchor side:YES];
            return;
        }
        if (logicalRow == TPKContentPlayerRowRightSide) {
            [self presentPlayerGestureAssignmentPickerFromCell:anchor side:NO];
            return;
        }
        if (logicalRow == TPKContentPlayerRowDeadZone) {
            [self presentPlayerGestureDeadZonePickerFromCell:anchor];
        }
        return;
    }
}

- (void)toggleAutoCollect:(UISwitch *)sw {
    TPKSetBool(kTCLiveAutoCollectChannelPoints, sw.isOn);
    TPKAutoClaimSettingsDidChange();
}
- (void)toggleHideTwitchStories:(UISwitch *)sw {
    tpk_setHideTwitchStoriesEnabled(sw.isOn);
}
- (void)toggleKeepLiveFeedPlaying:(UISwitch *)sw {
    tpk_setKeepLiveFeedPlayingEnabled(sw.isOn);
}

- (void)togglePlayerGestures:(UISwitch *)sw {
    tpk_setPlayerGesturesEnabled(sw.isOn);
    TPKReloadSectionWithoutJump(self.tableView, TPKContentSectionPlayer);
}

- (void)togglePlayerTools:(UISwitch *)sw {
    tpk_setPlayerToolsEnabled(sw.isOn);
    TPKReloadSectionWithoutJump(self.tableView, TPKContentSectionPlayer);
}

- (void)togglePlayerStats:(UISwitch *)sw {
    tpk_setPlayerStatsEnabled(sw.isOn);
}

- (void)presentPlayerGestureAssignmentPickerFromCell:(UIView *)anchor
                                                side:(BOOL)leftSide {
    TPKPlayerGestureAssignment current = leftSide
        ? tpk_playerGesturesLeftAssignment()
        : tpk_playerGesturesRightAssignment();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(leftSide
            ? L(@"player_gestures_left_side")
            : L(@"player_gestures_right_side"))
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    NSArray<NSNumber *> *assignments = @[
        @(TPKPlayerGestureAssignmentDisabled),
        @(TPKPlayerGestureAssignmentVolume),
        @(TPKPlayerGestureAssignmentBrightness),
    ];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *rawAssignment in assignments) {
        TPKPlayerGestureAssignment assignment =
            (TPKPlayerGestureAssignment)rawAssignment.integerValue;
        NSString *title = TPKPlayerGestureAssignmentTitle(assignment);
        if (assignment == current) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (leftSide) {
                tpk_setPlayerGesturesLeftAssignment(assignment);
            } else {
                tpk_setPlayerGesturesRightAssignment(assignment);
            }
            TPKReloadSectionWithoutJump(self.tableView,
                                         TPKContentSectionPlayer);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    TPKPresentAlert(self, sheet);
}

- (void)playerGestureSensitivityDecrease:(UIButton *)button {
    CGFloat value = MAX(1.0, tpk_playerGesturesSensitivity() - 1.0);
    tpk_setPlayerGesturesSensitivity(value);
    UILabel *valueLabel = objc_getAssociatedObject(
        button, &kTPKPlayerGestureSensitivityValueLabelKey);
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
}

- (void)playerGestureSensitivityIncrease:(UIButton *)button {
    CGFloat value = MIN(5.0, tpk_playerGesturesSensitivity() + 1.0);
    tpk_setPlayerGesturesSensitivity(value);
    UILabel *valueLabel = objc_getAssociatedObject(
        button, &kTPKPlayerGestureSensitivityValueLabelKey);
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
}

- (void)presentPlayerGestureDeadZonePickerFromCell:(UIView *)anchor {
    NSInteger current = tpk_playerGesturesDeadZone();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"player_gestures_dead_zone")
                         message:L(@"player_gestures_dead_zone_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();

    for (NSInteger value = 0; value <= 100; value += 10) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value];
        if (value == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            tpk_setPlayerGesturesDeadZone(value);
            TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    TPKPresentAlert(self, sheet);
}

// Orientation-lock choice sheet; apply immediately and refresh the row.
- (void)presentOrientationLockSettingPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"switch_orientation_lock_button")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();
    TPKOrientationLockSetting current = TPKCurrentOrientationLockSetting();
    NSArray<NSNumber *> *settings = @[
        @(TPKOrientationLockSettingDisabled),
        @(TPKOrientationLockSettingManual),
        @(TPKOrientationLockSettingAutoLeft),
        @(TPKOrientationLockSettingAutoRight),
        @(TPKOrientationLockSettingAutoBoth),
    ];
    for (NSNumber *value in settings) {
        TPKOrientationLockSetting setting = (TPKOrientationLockSetting)value.integerValue;
        NSString *title = TPKOrientationLockSettingTitle(setting);
        if (setting == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            TPKAutoOrientationLockMode mode = TPKAutoOrientationLockModeDisabled;
            switch (setting) {
                case TPKOrientationLockSettingAutoLeft:
                    mode = TPKAutoOrientationLockModeLandscapeLeft;
                    break;
                case TPKOrientationLockSettingAutoRight:
                    mode = TPKAutoOrientationLockModeLandscapeRight;
                    break;
                case TPKOrientationLockSettingAutoBoth:
                    mode = TPKAutoOrientationLockModeBothLandscapes;
                    break;
                case TPKOrientationLockSettingDisabled:
                case TPKOrientationLockSettingManual:
                default:
                    mode = TPKAutoOrientationLockModeDisabled;
                    break;
            }
            tpk_setAutoOrientationLockMode(mode);
            tpk_setOrientationLockButtonEnabled(
                setting != TPKOrientationLockSettingDisabled);
            TPKReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    TPKPresentAlert(self, sheet);
}

// Import favorites from a 7TV PC JSON export.

- (void)importFavoritesFromFile {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.json", @"public.text", @"public.data"]
                       inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle  = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        [self tpk_showAlert:L(@"alert_error_title")
                     message:L(@"error_cant_read_file")];
        return;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!json) {
        [self tpk_showAlert:L(@"alert_invalid_format_title")
                     message:L(@"error_invalid_json")];
        return;
    }

    NSArray *rawFavs = TPKPCFavoritesArrayFromJSON(json);

    if (!rawFavs) {
        [self tpk_showAlert:L(@"alert_unknown_format_title")
                     message:L(@"error_missing_favorites_key")];
        return;
    }

    // Keep 7TV IDs and ignore PLATFORM entries.
    NSArray<NSString *> *newIDs = TPKTPKIDsFromPCFavorites(rawFavs);

    if (newIDs.count == 0) {
        [self tpk_showAlert:L(@"alert_no_7tv_favorites_title")
                     message:L(@"error_no_favorites_in_file")];
        return;
    }

    TPKManager *manager = [TPKManager sharedManager];
    NSArray<NSString *> *existing = [manager favoriteEmoteIDsSnapshot];
    NSMutableOrderedSet<NSString *> *merged =
        [NSMutableOrderedSet orderedSetWithArray:existing];
    NSUInteger beforeCount = merged.count;
    [merged addObjectsFromArray:newIDs];
    [manager replaceFavoriteEmoteIDs:merged.array];

    NSUInteger added = merged.count - beforeCount;
    NSUInteger skipped = newIDs.count - added;
    [self.tableView reloadData];
    [self tpk_showAlert:[NSString stringWithFormat:L(@"alert_import_success_title_format"), (unsigned long)added]
                 message:[NSString stringWithFormat:
                          L(@"alert_import_success_message_format"),
                          (unsigned long)added,
                          (unsigned long)skipped]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { }

- (void)tpk_showAlert:(NSString *)title message:(NSString *)msg {
    TPKShowAlert(self, title, msg);
}
@end// Ligne de l'écran barre d'onglets : radio (écran de lancement) et interrupteur
// (onglet visible) sur la même ligne. `tabIndex` < 0 décrit « Défaut ». Création
// n'a pas de radio : aucune destination de lancement ne la vise. `subPageTitle`
// ajoute une seconde ligne optionnelle (sous-page ouverte, ou « masqué »).
static UITableViewCell *TPKTabOptionCell(NSInteger tabIndex,
                                         NSString *title,
                                         NSString *sfName,
                                         NSString *subPageTitle,
                                         BOOL isLaunch,
                                         BOOL isVisible,
                                         id target,
                                         SEL switchAction,
                                         SEL subPageAction) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    // Ligne de lancement : fond gris neutre (un cercle seul se repère mal).
    cell.backgroundColor = isLaunch ? [UIColor colorWithWhite:1.0 alpha:0.08]
                                    : TPKCellBg();

    UIImageView *radio = nil;
    if (tabIndex != TPKTabItemCreate) {
        UIImageSymbolConfiguration *radioCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        radio = [[UIImageView alloc] initWithImage:[UIImage
            systemImageNamed:(isLaunch ? @"largecircle.fill.circle" : @"circle")
            withConfiguration:radioCfg]];
        radio.tintColor = isLaunch ? TPKAccent() : TPKGray();
        radio.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:radio];
    }

    UIImageView *icon = nil;
    if (sfName.length) {
        UIColor *tint = tabIndex >= 0 ? TPKTabItemColor((TPKTabItem)tabIndex)
                                      : TPKTabItemColorDefaultRow();
        icon = TPKIcon(sfName, isVisible ? tint : TPKGray());
        [cell.contentView addSubview:icon];
    }

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    // Match native settings typography.
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = isVisible ? [UIColor whiteColor] : TPKGray();
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = nil;
    if (tabIndex >= 0) {
        sw = [[UISwitch alloc] init];
        sw.on          = isVisible;
        sw.onTintColor = TPKAccent();
        sw.tag         = tabIndex;
        sw.accessibilityLabel = title;
        [sw addTarget:target action:switchAction
     forControlEvents:UIControlEventValueChanged];
        sw.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:sw];
    }

    // Seconde ligne : sous-page à choisir, ou simple mention (« masqué »).
    UIView *secondLine = nil;
    if (subPageTitle.length) {
        if (subPageAction) {
            // Assemblé à la main : sur un bouton système, le chevron garde sa
            // couleur propre et se cale sur les métriques du bouton.
            UIColor *subColor = TPKAccent();
            UIControl *control = [[UIControl alloc] init];
            control.tag = tabIndex;
            [control addTarget:target action:subPageAction
              forControlEvents:UIControlEventTouchUpInside];

            UILabel *subLabel = [[UILabel alloc] init];
            subLabel.text = [NSString stringWithFormat:@"%@ %@",
                             L(@"tab_bar_open_with"), subPageTitle];
            subLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            subLabel.textColor = subColor;
            subLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [control addSubview:subLabel];

            UIImageSymbolConfiguration *chevronCfg = [UIImageSymbolConfiguration
                configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
            UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage
                systemImageNamed:@"chevron.right" withConfiguration:chevronCfg]];
            chevron.tintColor = subColor;
            chevron.translatesAutoresizingMaskIntoConstraints = NO;
            [control addSubview:chevron];

            [NSLayoutConstraint activateConstraints:@[
                [subLabel.leadingAnchor constraintEqualToAnchor:control.leadingAnchor],
                [subLabel.topAnchor constraintEqualToAnchor:control.topAnchor],
                [subLabel.bottomAnchor constraintEqualToAnchor:control.bottomAnchor],
                [chevron.leadingAnchor constraintEqualToAnchor:subLabel.trailingAnchor
                                                      constant:5],
                // Centré sur la hauteur de capitale du texte, pas sur sa boîte.
                [chevron.centerYAnchor constraintEqualToAnchor:subLabel.firstBaselineAnchor
                                                      constant:-4],
                [chevron.trailingAnchor constraintEqualToAnchor:control.trailingAnchor],
            ]];
            secondLine = control;
        } else {
            UILabel *note = [[UILabel alloc] init];
            note.text = subPageTitle;
            note.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
            note.textColor = TPKGray();
            secondLine = note;
        }
        secondLine.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:secondLine];
    }

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    if (radio) {
        [constraints addObjectsFromArray:@[
            [radio.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                                constant:16],
            [radio.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
            [radio.widthAnchor   constraintEqualToConstant:22],
            [radio.heightAnchor  constraintEqualToConstant:22],
        ]];
    }
    [constraints addObject:[lbl.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                         constant:12]];
    // Sans radio (Création), la place est conservée pour garder les colonnes alignées.
    if (icon) {
        [constraints addObject:radio
            ? [icon.leadingAnchor constraintEqualToAnchor:radio.trailingAnchor constant:10]
            : [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                                 constant:48]];
        [constraints addObjectsFromArray:@[
            [icon.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
            [lbl.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        ]];
    } else {
        [constraints addObject:radio
            ? [lbl.leadingAnchor constraintEqualToAnchor:radio.trailingAnchor constant:12]
            : [lbl.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor
                                                constant:48]];
    }
    if (sw) {
        [constraints addObjectsFromArray:@[
            [sw.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                              constant:-16],
            [sw.centerYAnchor  constraintEqualToAnchor:lbl.centerYAnchor],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor
                                                         constant:-12],
        ]];
    } else {
        [constraints addObject:[lbl.trailingAnchor
            constraintLessThanOrEqualToAnchor:cell.contentView.trailingAnchor constant:-16]];
    }
    if (secondLine) {
        [constraints addObjectsFromArray:@[
            [secondLine.leadingAnchor constraintEqualToAnchor:lbl.leadingAnchor],
            [secondLine.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:3],
            [secondLine.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                                    constant:-12],
            [secondLine.trailingAnchor
                constraintLessThanOrEqualToAnchor:cell.contentView.trailingAnchor
                                         constant:-16],
        ]];
    } else {
        [constraints addObject:[lbl.bottomAnchor
            constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return cell;
}

// MARK: - TPKTabBarSettingsController
// Masquage des onglets de la barre principale et écran de lancement. Les deux
// réglages sont liés : une destination dont l'onglet est masqué ne peut pas être
// honorée. Ils partagent donc un même écran, atteint par une seule ligne dans le
// menu Contenu.

// Deux sections : l'explication permanente, puis les réglages eux-mêmes.
typedef NS_ENUM(NSInteger, TPKTabBarSettingsSection) {
    TPKTabBarSettingsSectionIntro = 0,
    TPKTabBarSettingsSectionOptions = 1,
};

typedef NS_ENUM(NSInteger, TPKTabBarSettingsRow) {
    TPKTabBarSettingsRowDefault = 0,   // « Défaut » : aucun onglet imposé
    TPKTabBarSettingsRowFirstTab,      // puis un onglet par ligne, ordre réel
};

@implementation TPKTabBarSettingsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"section_tab_bar");
    TPKStyleTableView(self.tableView);
    TPKRegisterOLEDObserver(self);
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == TPKTabBarSettingsSectionIntro) return 1;
    return TPKTabBarSettingsRowFirstTab + TPK_TAB_ITEM_COUNT;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return (s == TPKTabBarSettingsSectionIntro) ? 8 : 34;
}

// Annonce les deux colonnes : radio (départ) à gauche, interrupteur (visible)
// à droite.
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    if (s == TPKTabBarSettingsSectionIntro) return [[UIView alloc] init];

    UILabel *launch = [[UILabel alloc] init];
    launch.text = L(@"tab_bar_header_launch").uppercaseString;
    UILabel *visible = [[UILabel alloc] init];
    visible.text = L(@"tab_bar_header_visible").uppercaseString;
    for (UILabel *lbl in @[launch, visible]) {
        lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        // En-têtes de colonnes à la couleur du tweak.
        lbl.textColor = TPKAccent();
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:lbl];
    }
    visible.textAlignment = NSTextAlignmentRight;
    [NSLayoutConstraint activateConstraints:@[
        [launch.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:20],
        [launch.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [visible.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [visible.bottomAnchor  constraintEqualToAnchor:launch.bottomAnchor],
    ]];
    return container;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TPKLaunchDestination destination = tpk_launchDestination();
    NSInteger launchTab = tpk_launchDestinationTab(destination);

    if (ip.section == TPKTabBarSettingsSectionIntro) {
        return TPKDescriptionCell(@"desc_tab_bar");
    }

    if (ip.row == TPKTabBarSettingsRowDefault) {
        return TPKTabOptionCell(-1, L(@"launch_default"), @"star.fill", nil,
            launchTab < 0, YES, self, nil, NULL);
    }

    NSInteger tabRow = ip.row - TPKTabBarSettingsRowFirstTab;
    if (tabRow < 0 || tabRow >= TPK_TAB_ITEM_COUNT) {
        return [[UITableViewCell alloc] init];
    }
    TPKTabItem item = (TPKTabItem)tabRow;
    BOOL isVisible = !tpk_tabItemHidden(item);
    BOOL isLaunch = launchTab == tabRow && !TPKLaunchDestinationTabHidden(destination);

    // L'onglet de départ affiche la sous-page qu'il ouvrira. Un onglet masqué
    // n'affiche rien, sauf s'il est la destination (cas d'un import de réglages).
    NSString *subPage = nil;
    SEL subPageAction = NULL;
    if (isLaunch) {
        subPage = TPKTabPageTitle(destination);
        subPageAction = @selector(openTabPagePicker:);
    } else if (!isVisible && launchTab == tabRow) {
        subPage = L(@"tab_hidden_badge");
    }

    return TPKTabOptionCell(tabRow, TPKTabItemName(item), TPKTabItemIcon(item),
        subPage, isLaunch, isVisible, self,
        @selector(toggleTabSwitch:), subPageAction);
}

- (NSIndexPath *)tableView:(UITableView *)tv willSelectRowAtIndexPath:(NSIndexPath *)ip {
    // Le test porte sur la SECTION : la première ligne des réglages porte aussi
    // le numéro 0, et elle doit rester sélectionnable.
    if (ip.section == TPKTabBarSettingsSectionIntro) return nil;
    if (ip.row == TPKTabBarSettingsRowDefault) return ip;
    NSInteger tabRow = ip.row - TPKTabBarSettingsRowFirstTab;
    if (tabRow < 0 || tabRow >= TPK_TAB_ITEM_COUNT) return nil;
    // Création (feuille de composition) et les onglets masqués ne peuvent pas
    // être l'écran de lancement : leur ligne est inerte.
    if (tabRow == TPKTabItemCreate) return nil;
    return tpk_tabItemHidden((TPKTabItem)tabRow) ? nil : ip;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != TPKTabBarSettingsSectionOptions) return;
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger tabRow = ip.row - TPKTabBarSettingsRowFirstTab;
    [self tpk_setLaunchTab:ip.row == TPKTabBarSettingsRowDefault ? -1 : tabRow];
}

// La radio fixe l'écran de lancement ; la sous-page déjà réglée est conservée.
- (void)tpk_setLaunchTab:(NSInteger)tab {
    if (tab < 0) {
        tpk_setLaunchDestination(TPKLaunchDestinationDefault);
    } else {
        TPKLaunchDestination current = tpk_launchDestination();
        tpk_setLaunchDestination(tpk_launchDestinationTab(current) == tab
            ? current
            : TPKDefaultDestinationForTab((TPKTabItem)tab));
    }
    TPKReloadSectionWithoutJump(self.tableView, TPKTabBarSettingsSectionOptions);
}

// Choix de la sous-page ouverte par l'onglet de départ.
- (void)openTabPagePicker:(UIControl *)control {
    TPKTabItem item = (TPKTabItem)control.tag;
    NSArray<NSNumber *> *options = nil;
    if (item == TPKTabItemHome) {
        options = @[@(TPKLaunchDestinationHomeFollowing),
                    @(TPKLaunchDestinationHomeLive),
                    @(TPKLaunchDestinationHomeClips)];
    } else if (item == TPKTabItemExplore) {
        options = @[@(TPKLaunchDestinationBrowseCategories),
                    @(TPKLaunchDestinationBrowseLiveChannels)];
    }
    if (!options.count) return;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:TPKTabItemName(item)
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = TPKAccent();
    TPKLaunchDestination current = tpk_launchDestination();
    for (NSNumber *raw in options) {
        TPKLaunchDestination destination = (TPKLaunchDestination)raw.integerValue;
        NSString *title = TPKTabPageTitle(destination);
        if (destination == current) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            tpk_setLaunchDestination(destination);
            TPKReloadSectionWithoutJump(self.tableView, TPKTabBarSettingsSectionOptions);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = control;
    sheet.popoverPresentationController.sourceRect = control.bounds;
    TPKPresentAlert(self, sheet);
}

// ── Onglets ───────────────────────────────────────────

// L'interrupteur porte la visibilité : allumé = onglet visible.
- (void)tpk_applyTabSwitch:(UISwitch *)sw forItem:(TPKTabItem)item {
    BOOL hide = !sw.isOn;
    if (hide && tpk_tabVisibleCount() <= 1) {
        sw.on = YES;
        TPKShowAlert(self, L(@"section_tab_bar"), L(@"alert_tab_bar_min_message"));
        return;
    }
    tpk_setTabItemHidden(item, hide);
    // La destination suit le masquage au lieu de retomber ailleurs en silence.
    if (hide &&
        tpk_launchDestinationTab(tpk_launchDestination()) == (NSInteger)item) {
        TPKLaunchDestination replacement = TPKNearestVisibleDestination(item);
        tpk_setLaunchDestination(replacement);
        TPKShowAlert(self, L(@"setting_launch_screen"),
            [NSString stringWithFormat:L(@"alert_launch_destination_moved"),
             TPKLaunchDestinationTitle(replacement)]);
    }
    // La barre ne rejoue pas son layout tant que cet écran est présenté.
    tpk_tabVisibilityApplyNow();
    // Le repère de départ, la mention « masqué » et les sous-pages ont pu bouger.
    TPKReloadSectionWithoutJump(self.tableView, TPKTabBarSettingsSectionOptions);
}

- (void)toggleTabSwitch:(UISwitch *)sw {
    [self tpk_applyTabSwitch:sw forItem:(TPKTabItem)sw.tag];
}

@end



// MARK: - TPKFavoritesListController

// Favorite emotes with provider-qualified keys and resolved names.

@interface TPKFavoritesListController ()
- (void)tpk_scheduleFavoriteNameCacheSave;
- (void)tpk_scheduleFavoriteNameRowsReload;
- (void)tpk_resolveMissingFavoriteNames;
- (void)tpk_catalogDidUpdate:(NSNotification *)notification;
@end

@implementation TPKFavoritesListController {
    NSArray<NSString *> *_favKeys;     // Provider-qualified keys.
    NSDictionary<NSString *, TPKEmoteDescriptor *> *_keyToDescriptor;
    NSDictionary<NSString *, NSString *> *_idToName; // Key/ID to name.
    NSMutableDictionary<NSString *, NSString *> *_favoriteNameCache;
    NSMutableSet<NSString *> *_nameFetchesInFlight;
    NSURLSession *_favoriteNameSession;
    BOOL _favoriteNameSaveScheduled;
    BOOL _favoriteNameReloadScheduled;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_mes_favoris");
    TPKStyleTableView(self.tableView);
    TPKRegisterOLEDObserver(self);
    NSDictionary *savedNames = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kTPKFavoriteEmoteNamesKey] ?: @{};
    _favoriteNameCache = [savedNames mutableCopy];
    _nameFetchesInFlight = [NSMutableSet set];
    NSURLSessionConfiguration *nameConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    nameConfig.HTTPMaximumConnectionsPerHost = 4;
    nameConfig.timeoutIntervalForRequest = 15.0;
    _favoriteNameSession = [NSURLSession sessionWithConfiguration:nameConfig];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tpk_catalogDidUpdate:)
                                                 name:TPKProviderCatalogDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tpk_catalogDidUpdate:)
                                                 name:TPKFavoritesDidChangeNotification
                                               object:nil];
    [[TPKEmoteCatalog sharedCatalog] loadGlobalProviders];
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    if (channelID.length)
        [[TPKEmoteCatalog sharedCatalog] loadChannelProvidersForTwitchID:channelID];
    [self reloadFavs];

    // Clear button.
    UIBarButtonItem *clear = [[UIBarButtonItem alloc]
        initWithTitle:L(@"common_empty_action")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(clearAllFavs)];
    clear.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItem = clear;
}

- (void)dealloc {
    [_favoriteNameSession invalidateAndCancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFavs];
}

- (void)tpk_catalogDidUpdate:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isViewLoaded) [self reloadFavs];
    });
}

- (void)reloadFavs {
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    _favKeys = [[catalog favoriteKeysSnapshot] copy];

    // Start with persisted names; imported favorites may be offline or channel-specific.
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *descriptorMap = [NSMutableDictionary dictionary];
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        for (TPKEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(TPKEmoteProviderID)provider]) {
            NSString *key = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (key.length) descriptorMap[key] = descriptor;
        }
    }
    // Merge provider metadata so offline or other-channel favorites keep their names and URLs.
    for (TPKEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        NSString *key = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
        if (!key.length) continue;
        descriptorMap[key] = descriptor;
    }
    for (NSString *rawFavoriteKey in _favKeys) {
        NSString *favoriteKey = TPKSettingsCanonicalFavoriteKey(rawFavoriteKey);
        if (!favoriteKey.length) continue;
        TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
        NSString *emoteID = nil;
        BOOL valid = TPKSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
        if (!valid) continue;
        NSString *qualifiedKey = TPKEmoteFavoriteKey(provider, emoteID);
        TPKEmoteDescriptor *descriptor = descriptorMap[qualifiedKey];
        if (descriptor) {
            descriptorMap[qualifiedKey] = descriptor;
            map[qualifiedKey] = descriptor.name;
        }
        if (valid && provider == TPKEmoteProviderIDTPK) {
            NSString *cachedName = _favoriteNameCache[emoteID] ?:
                _favoriteNameCache[qualifiedKey] ?: _favoriteNameCache[rawFavoriteKey];
            if (cachedName.length) map[qualifiedKey] = cachedName;
        }
    }

    _keyToDescriptor = descriptorMap.copy;
    _idToName = [map copy];
    [_favoriteNameCache addEntriesFromDictionary:map];
    [self tpk_scheduleFavoriteNameCacheSave];

    [self.tableView reloadData];
    [self tpk_resolveMissingFavoriteNames];
}

- (void)tpk_scheduleFavoriteNameCacheSave {
    if (_favoriteNameSaveScheduled) return;
    _favoriteNameSaveScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_favoriteNameSaveScheduled = NO;
        [[NSUserDefaults standardUserDefaults]
            setObject:[strongSelf->_favoriteNameCache copy]
               forKey:kTPKFavoriteEmoteNamesKey];
    });
}

- (void)tpk_scheduleFavoriteNameRowsReload {
    if (_favoriteNameReloadScheduled) return;
    _favoriteNameReloadScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_favoriteNameReloadScheduled = NO;
        [strongSelf.tableView reloadData];
    });
}

- (void)tpk_resolveMissingFavoriteNames {
    for (NSString *rawFavoriteKey in _favKeys) {
        NSString *favoriteKey = TPKSettingsCanonicalFavoriteKey(rawFavoriteKey);
        if (!favoriteKey.length) continue;
        TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
        NSString *emoteID = nil;
        if (!TPKSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID) ||
            provider != TPKEmoteProviderIDTPK) continue;
        if (_idToName[favoriteKey].length || [_nameFetchesInFlight containsObject:favoriteKey]) continue;
        [_nameFetchesInFlight addObject:favoriteKey];

        NSString *escapedID = [emoteID stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emotes/%@",
                                          TPK_API_BASE, escapedID ?: emoteID]];
        if (!url) {
            [_nameFetchesInFlight removeObject:favoriteKey];
            continue;
        }

        __weak typeof(self) weakSelf = self;
        [[_favoriteNameSession dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *resolvedName = nil;
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (!error && data.length && status >= 200 && status < 300) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                id nameValue = [json isKindOfClass:[NSDictionary class]] ? json[@"name"] : nil;
                if ([nameValue isKindOfClass:[NSString class]] && [nameValue length]) {
                    resolvedName = nameValue;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf->_nameFetchesInFlight removeObject:favoriteKey];
                if (!resolvedName.length || ![strongSelf->_favKeys containsObject:favoriteKey]) return;

                strongSelf->_favoriteNameCache[emoteID] = resolvedName;
                NSMutableDictionary *names = [strongSelf->_idToName mutableCopy] ?: [NSMutableDictionary dictionary];
                names[favoriteKey] = resolvedName;
                strongSelf->_idToName = [names copy];
                [strongSelf tpk_scheduleFavoriteNameCacheSave];
                [strongSelf tpk_scheduleFavoriteNameRowsReload];
            });
        }] resume];
    }
}

// Table view.

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _favKeys.count == 0 ? 1 : (NSInteger)_favKeys.count;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *title = _favKeys.count > 0
        ? [NSString stringWithFormat:L(@"favorites_count_format"), (unsigned long)_favKeys.count]
        : L(@"section_favoris");
    return TPKSectionHeader(title, NO, nil);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Empty state.
    if (_favKeys.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = TPKCellBg();
        cell.textLabel.text  = L(@"empty_no_favorites");
        cell.textLabel.textColor = TPKGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }

    NSString *favoriteKey = TPKSettingsCanonicalFavoriteKey(_favKeys[ip.row]);
    if (!favoriteKey.length) favoriteKey = @"7tv:unknown";
    TPKEmoteDescriptor *descriptor = _keyToDescriptor[favoriteKey];
    TPKEmoteProviderID provider = TPKEmoteProviderIDTPK;
    NSString *emoteID = nil;
    BOOL validKey = TPKSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
    if (!validKey) {
        provider = TPKEmoteProviderIDTPK;
        emoteID = favoriteKey;
        favoriteKey = TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emoteID);
        descriptor = _keyToDescriptor[favoriteKey];
    }
    NSString *name = descriptor.name ?: _idToName[favoriteKey];
    NSString *providerName = descriptor.providerName ?: TPKEmoteProviderName(provider);

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.backgroundColor = TPKCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    // Emote image, using URLCache when available.
    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.contentMode = UIViewContentModeScaleAspectFit;
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.clipsToBounds = YES;
    [cell.contentView addSubview:thumb];

    if (descriptor) TPKLoadSettingsCatalogEmoteImage(descriptor, thumb);
    else if (provider == TPKEmoteProviderIDTPK) TPKLoadSettingsEmoteImage(emoteID, thumb);

    // Labels.
    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name.length ? name : providerName;
    nameLbl.font = [UIFont systemFontOfSize:15 weight:
        name.length ? UIFontWeightRegular : UIFontWeightLight];
    nameLbl.textColor = name.length ? [UIColor whiteColor] : TPKGray();
    nameLbl.numberOfLines = 1;
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:nameLbl];

    UILabel *idLbl = [[UILabel alloc] init];
    // Keep long IDs within the cell.
    NSString *shortID = emoteID.length > 14
        ? [NSString stringWithFormat:@"%@…", [emoteID substringToIndex:14]]
        : emoteID;
    idLbl.text = [NSString stringWithFormat:@"%@ · %@", providerName, shortID ?: @"—"];
    idLbl.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    idLbl.textColor = TPKGray();
    idLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:idLbl];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[nameLbl, idLbl]];
    stack.axis      = UILayoutConstraintAxisVertical;
    stack.spacing   = 2;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];

    // Delete button; swipe-to-delete is handled by editingStyle.
    [NSLayoutConstraint activateConstraints:@[
        [thumb.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [thumb.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [thumb.widthAnchor    constraintEqualToConstant:32],
        [thumb.heightAnchor   constraintEqualToConstant:32],
        [stack.leadingAnchor  constraintEqualToAnchor:thumb.trailingAnchor constant:14],
        [stack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [stack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
        [stack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];

    return cell;
}

// Swipe-to-delete.
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return _favKeys.count > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv
           editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return _favKeys.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tv
commitEditingStyle:(UITableViewCellEditingStyle)es
forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    NSString *removedKey = _favKeys[ip.row];
    if (!TPKSettingsParseFavoriteKey(removedKey, NULL, NULL)) return;
    [[TPKEmoteCatalog sharedCatalog] setFavoriteKey:removedKey favorited:NO];
    [self reloadFavs];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

// Clear button.
- (void)clearAllFavs {
    if (_favKeys.count == 0) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_clear_favorites_title")
                         message:L(@"alert_clear_favorites_message")
        preferredStyle:UIAlertControllerStyleActionSheet];
    alert.message = [NSString stringWithFormat:L(@"alert_clear_favorites_message"),
                     (unsigned long)_favKeys.count];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_empty_action")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
            for (NSString *favoriteKey in self->_favKeys) {
                if (TPKSettingsParseFavoriteKey(favoriteKey, NULL, NULL))
                    [catalog setFavoriteKey:favoriteKey favorited:NO];
            }
            [self reloadFavs];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    TPKPresentAlert(self, alert);
}

@end



// MARK: - TPKHookDiagnosticsController
// Reports whether targeted classes and selectors resolve in this Twitch build.

@interface TPKHookDiagnosticsController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *items;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *providerItems;
@property (nonatomic, strong) TPKAutoClaimDiagnosticsState *autoClaimState;
@end

@implementation TPKHookDiagnosticsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"diagnostics_title");
    TPKStyleTableView(self.tableView);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(tpk_providerDiagnosticsDidUpdate:)
                   name:TPKProviderCatalogDidUpdateNotification object:nil];
    [center addObserver:self
               selector:@selector(tpk_providerDiagnosticsDidUpdate:)
                   name:TPKEmoteProviderSettingsDidChangeNotification object:nil];
    [self reloadDiagnostics];

    // If presented without navigation, Done closes this screen.
    BOOL presentedRoot = self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController != nil;
    if (presentedRoot) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self action:@selector(closeDiagnostics)];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Read the shared hook registry after all runtime hooks are installed.
    [self reloadDiagnostics];
}

- (void)closeDiagnostics {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadDiagnostics {
    self.items = TPKHookDiagnosticItems();
    self.providerItems = TPKEmoteProviderDiagnosticItems();
    self.autoClaimState = TPKAutoClaimDiagnosticsCurrentState();
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)tpk_providerDiagnosticsDidUpdate:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf tpk_providerDiagnosticsDidUpdate:nil];
        });
        return;
    }
    if (!self.isViewLoaded || !self.view.window) return;
    [self reloadDiagnostics];
}

- (NSArray<NSString *> *)tpk_autoClaimDiagnosticTitles {
    return @[
        L(@"diagnostics_autoclaim_rn_host"),
        L(@"diagnostics_autoclaim_rn_chest"),
        L(@"diagnostics_autoclaim_balance"),
        L(@"diagnostics_autoclaim_watcher"),
    ];
}

- (NSArray<NSString *> *)tpk_autoClaimDiagnosticValues {
    TPKAutoClaimDiagnosticsState *state = self.autoClaimState;
    NSString *(^yesNo)(BOOL) = ^NSString *(BOOL value) {
        return L(value ? @"diagnostics_autoclaim_yes"
                       : @"diagnostics_autoclaim_no");
    };

    NSString *balanceText = L(@"diagnostics_autoclaim_no");
    if (state.rnBalanceKnown) {
        balanceText = [NSString stringWithFormat:@"%lld", (long long)state.rnBalance];
    }

    return @[
        yesNo(state.rnChatHostDetected),
        yesNo(state.rnChestDetected),
        balanceText,
        yesNo(state.watcherActive),
    ];
}

- (UITableViewCell *)tpk_autoClaimDiagnosticCellForRow:(NSInteger)row
                                               tableView:(UITableView *)tableView {
    static NSString *reuseIdentifier = @"TPKAutoClaimDiagnosticCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSArray<NSString *> *titles = [self tpk_autoClaimDiagnosticTitles];
    NSArray<NSString *> *values = [self tpk_autoClaimDiagnosticValues];
    if (row < 0 || row >= (NSInteger)titles.count || row >= (NSInteger)values.count) {
        return cell;
    }

    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = titles[row];
    cell.textLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = values[row];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    cell.detailTextLabel.numberOfLines = 0;

    UIColor *valueColor = TPKGray();
    if (row < 4) {
        switch (row) {
            case 0: valueColor = self.autoClaimState.rnChatHostDetected
                ? UIColor.systemGreenColor : UIColor.systemRedColor; break;
            case 1: valueColor = self.autoClaimState.rnChestDetected
                ? UIColor.systemGreenColor : UIColor.systemRedColor; break;
            case 2: valueColor = self.autoClaimState.rnBalanceKnown
                ? UIColor.systemGreenColor : UIColor.systemGrayColor; break;
            case 3: valueColor = self.autoClaimState.watcherActive
                ? UIColor.systemGreenColor : UIColor.systemRedColor; break;
            default: break;
        }
    }
    cell.detailTextLabel.textColor = valueColor;
    return cell;
}

- (NSArray<NSDictionary<NSString *, id> *> *)tpk_itemsForGroup:(NSInteger)group {
    // Sections 0 and 3 are reserved for provider API and Auto Claim rows.
    if (group < 1 || group > 4 || group == 3) return @[];
    NSInteger hookGroup = group <= 2 ? group - 1 : group - 2;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary<NSString *, id> *item, NSDictionary *bindings) {
            (void)bindings;
            return item[@"group"] != nil &&
                [item[@"group"] integerValue] == hookGroup;
        }];
    return [self.items filteredArrayUsingPredicate:predicate];
}

- (NSArray<NSDictionary<NSString *, id> *> *)tpk_emoteProviderItems {
    return self.providerItems ?: @[];
}

- (NSDictionary<NSString *, id> *)tpk_itemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *providerItems = [self tpk_emoteProviderItems];
        return indexPath.row < (NSInteger)providerItems.count
            ? providerItems[indexPath.row] : nil;
    }
    NSArray<NSDictionary<NSString *, id> *> *groupItems =
        [self tpk_itemsForGroup:indexPath.section];
    return indexPath.row < (NSInteger)groupItems.count ? groupItems[indexPath.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [self tpk_emoteProviderItems].count;
    if (section == 3) return 4;
    return [self tpk_itemsForGroup:section].count;
}

- (UITableViewCell *)tpk_emoteProviderDiagnosticCellForRow:(NSInteger)row
                                                   tableView:(UITableView *)tableView {
    static NSString *reuseIdentifier = @"TPKEmoteProviderDiagnosticCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSArray<NSDictionary<NSString *, id> *> *providerItems =
        [self tpk_emoteProviderItems];
    if (row < 0 || row >= (NSInteger)providerItems.count) return cell;
    NSDictionary<NSString *, id> *item = providerItems[row];
    BOOL enabled = [item[@"enabled"] boolValue];
    TPKEmoteProviderState state =
        (TPKEmoteProviderState)[item[@"state"] integerValue];
    NSUInteger count = [item[@"count"] unsignedIntegerValue];
    NSString *status = nil;
    UIColor *statusColor = UIColor.systemGrayColor;

    if (!enabled) {
        status = L(@"diagnostics_inactive");
    } else {
        switch (state) {
            case TPKEmoteProviderStateLoading:
                status = L(@"diagnostics_api_loading");
                statusColor = UIColor.systemOrangeColor;
                break;
            case TPKEmoteProviderStateLoaded:
                status = [NSString stringWithFormat:
                    L(@"diagnostics_api_ok_count"), (long)count];
                statusColor = UIColor.systemGreenColor;
                break;
            case TPKEmoteProviderStateError: {
                status = L(@"diagnostics_api_error");
                NSString *detail = item[@"errorMessage"];
                if (detail.length) {
                    // Keep API errors useful without unbounded row height.
                    if (detail.length > 96)
                        detail = [[detail substringToIndex:96]
                            stringByAppendingString:@"…"];
                    status = [NSString stringWithFormat:@"%@ · %@",
                              status, detail];
                }
                statusColor = UIColor.systemRedColor;
                break;
            }
            case TPKEmoteProviderStateIdle:
            default:
                status = L(@"diagnostics_api_not_loaded");
                statusColor = UIColor.systemGrayColor;
                break;
        }
    }

    cell.backgroundColor = TPKCellBg();
    cell.textLabel.text = item[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:14.0
                                             weight:UIFontWeightRegular];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.text = status;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0
                                                   weight:UIFontWeightMedium];
    cell.detailTextLabel.textColor = statusColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessibilityValue = status;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return [self tpk_emoteProviderDiagnosticCellForRow:indexPath.row
                                                   tableView:tableView];
    }
    if (indexPath.section == 3) {
        return [self tpk_autoClaimDiagnosticCellForRow:indexPath.row
                                              tableView:tableView];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TPKHookDiagnosticCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"TPKHookDiagnosticCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = TPKCellBg();
    NSDictionary<NSString *, id> *item = [self tpk_itemAtIndexPath:indexPath];
    if (!item) return cell;
    BOOL applicable = [item[@"applicable"] boolValue];
    BOOL present = [item[@"present"] boolValue];
    NSString *status = !applicable ? L(@"diagnostics_inactive") :
        (present ? L(@"diagnostics_ok") : L(@"diagnostics_missing"));
    UIColor *color = !applicable ? UIColor.systemGrayColor :
        (present ? UIColor.systemGreenColor : UIColor.systemRedColor);
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *configuration = [cell defaultContentConfiguration];
        configuration.text = item[@"name"];
        configuration.textProperties.font = [UIFont monospacedSystemFontOfSize:11
                                                                          weight:UIFontWeightRegular];
        configuration.textProperties.color = UIColor.whiteColor;
        configuration.textProperties.numberOfLines = 0;
        configuration.secondaryText = status;
        configuration.secondaryTextProperties.color = color;
        [cell setContentConfiguration:configuration];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = item[@"name"];
        cell.textLabel.font = [UIFont systemFontOfSize:11];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = status;
        cell.detailTextLabel.textColor = color;
    }
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *keys = @[
        @"diagnostics_group_emote_providers",
        @"diagnostics_group_proxy",
        @"diagnostics_group_vaft",
        @"diagnostics_autoclaim_group",
        @"diagnostics_group_twitchplusk",
    ];
    return section < (NSInteger)keys.count ? L(keys[section]) : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 3) return L(@"diagnostics_autoclaim_subtitle");
    // Show the playback note once below the last group.
    return section == 4 ? L(@"diagnostics_footer") : nil;
}

@end


// MARK: - TPKAdvancedPageController  (ex-TPKDebugPageController)
// Diagnostics, cache, options and settings transfer.

// Returns all image URLs known by the shared provider-aware catalogue.
static NSArray<NSURL *> *TPKAdvancedKnownEmoteImageURLs(void) {
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^appendDescriptor)(TPKEmoteDescriptor *) = ^(TPKEmoteDescriptor *descriptor) {
        if (!descriptor) return;

        // Count each emote once across all cached scales.
        [descriptor.imageURLs enumerateKeysAndObjectsUsingBlock:
            ^(NSNumber *scale, NSString *urlString, BOOL *stop) {
                (void)scale;
                NSURL *url = [NSURL URLWithString:urlString];
                NSString *key = url.absoluteString;
                if (!key.length || [seen containsObject:key]) return;
                [seen addObject:key];
                [urls addObject:url];
            }];

        // Include offline favorites when only their best URL is available.
        if (!descriptor.imageURLs.count) {
            NSURL *url = [descriptor imageURLForResolution:
                [TPKChatAppearanceConfig sharedConfig].emoteImageResolution];
            NSString *key = url.absoluteString;
            if (key.length && ![seen containsObject:key]) {
                [seen addObject:key];
                [urls addObject:url];
            }
        }
    };

    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        for (TPKEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(TPKEmoteProviderID)provider]) {
            appendDescriptor(descriptor);
        }
    }
    for (TPKEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        appendDescriptor(descriptor);
    }
    return urls.copy;
}

@interface TPKAdvancedPageController () <UIDocumentPickerDelegate>
- (void)tpk_exportSettingsFromAnchor:(UIView *)anchor;
- (void)tpk_importSettingsFromFile;
- (void)tpk_importSettingsAtURL:(NSURL *)url;
- (void)tpk_applyImportedSettingsWithLegacyFavorites:(BOOL)hasLegacyFavorites;
- (void)tpk_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message;
@property (nonatomic, assign) NSInteger displayedCachedEmoteCount;
@end

@implementation TPKAdvancedPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_avance");
    self.displayedCachedEmoteCount = [TPKURLProtocol cachedEmoteCount];
    TPKStyleTableView(self.tableView);
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(tpk_cacheCountDidChange:)
        name:TPKEmoteCacheCountDidChangeNotification object:nil];
    TPKRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)tpk_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        TPKApplyOLEDStyle(self);
    });
}

- (void)tpk_cacheCountDidChange:(NSNotification *)notification {
    if (!self.isViewLoaded || !self.view.window) return;
    NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:0];
    [self.tableView reloadRowsAtIndexPaths:@[cacheRow]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.displayedCachedEmoteCount = [TPKURLProtocol cachedEmoteCount];
    [self.tableView reloadData];

    // Use the shared provider-aware cache refresh path.
    __weak typeof(self) weakSelf = self;
    void (^applyCount)(NSInteger) = ^(NSInteger count) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.displayedCachedEmoteCount = count;
        if (strongSelf.isViewLoaded && strongSelf.view.window) {
            NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:0];
            [strongSelf.tableView reloadRowsAtIndexPaths:@[cacheRow]
                                        withRowAnimation:UITableViewRowAnimationNone];
        }
    };
    [TPKURLProtocol refreshCachedEmoteCountWithCompletion:^(NSInteger count) {
        applyCount(count);

        // Backfill older cache entries without replacing known identities.
        NSArray<NSURL *> *knownImageURLs = TPKAdvancedKnownEmoteImageURLs();
        if (knownImageURLs.count) {
            [TPKURLProtocol refreshCachedEmoteCountForImageURLs:knownImageURLs
                                                          completion:applyCount];
        }
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

// Sections: Tools, Transfer, Options and Logs.
#define TPK_SECTION_TOOLS        0
#define TPK_SECTION_TRANSFER     1
#define TPK_SECTION_OPTIONS      2
#define TPK_SECTION_LOGS         3

#define TPK_TOOLS_ROW_CACHE       0
#define TPK_TOOLS_ROW_DIAGNOSTICS 1

// Log-section rows.
typedef NS_ENUM(NSInteger, TPKLogsRow) {
    TPKLogsRowEnable   = 0,
    TPKLogsRowView     = 1,
    TPKLogsRowConsole  = 2,
    TPKLogsRowFirstCat = 3,
};

#define TPK_LOGS_CAT_COUNT       4

// Log detail rows are visible only when logging is enabled.
- (NSArray<NSNumber *> *)tpk_visibleLogsRows {
    BOOL logsOn = [TPKManager sharedManager].logsEnabled;
    NSMutableDictionary<NSNumber *, NSNumber *> *conditional = [NSMutableDictionary dictionary];
    conditional[@(TPKLogsRowView)]    = @(logsOn);
    conditional[@(TPKLogsRowConsole)] = @(logsOn);
    for (NSInteger cat = 0; cat < TPK_LOGS_CAT_COUNT; cat++) {
        conditional[@(TPKLogsRowFirstCat + cat)] = @(logsOn);
    }
    return TPKVisibleRowIndexes(@[@(TPKLogsRowEnable)], conditional);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case TPK_SECTION_TOOLS:    return 2;
        case TPK_SECTION_TRANSFER: return 2;
        case TPK_SECTION_OPTIONS:  return 2;
        case TPK_SECTION_LOGS:     return [self tpk_visibleLogsRows].count + 4; /* + bloc Diagnostics VAFT */
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case TPK_SECTION_TOOLS:    return TPKSectionHeader(L(@"section_tools"), NO, nil);
        case TPK_SECTION_TRANSFER: return TPKSectionHeader(L(@"section_settings_backup"), NO, nil);
        case TPK_SECTION_OPTIONS:  return TPKSectionHeader(L(@"section_options"), NO, nil);
        case TPK_SECTION_LOGS:     return TPKSectionHeader(L(@"section_logs"), NO, nil);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TPKManager *mgr = [TPKManager sharedManager];

    // Tools: clear cache and hook diagnostics.
    if (ip.section == TPK_SECTION_TOOLS) {
        if (ip.row == TPK_TOOLS_ROW_DIAGNOSTICS) {
            return TPKNavCell(L(@"diagnostics_title"), L(@"diagnostics_subtitle"),
                @"stethoscope", UIColor.systemPinkColor, nil);
        }

        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = TPKCellBg();
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.06];
        UIImageView *icon = TPKIcon(@"trash.circle",
                                      UIColor.systemOrangeColor);
        [cell.contentView addSubview:icon];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = L(@"action_clear_cache");
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 1;
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];

        UILabel *countLbl = [[UILabel alloc] init];
        NSInteger resolution = [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
        resolution = MIN(4, MAX(1, resolution));
        NSInteger cachedCount = self.displayedCachedEmoteCount >= 0
            ? self.displayedCachedEmoteCount
            : [TPKURLProtocol cachedEmoteCount];
        countLbl.text = [NSString stringWithFormat:L(@"cache_emote_count_format"),
                         (long)cachedCount, (long)resolution];
        countLbl.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        countLbl.textColor = TPKGray();
        countLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:countLbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [lbl.trailingAnchor  constraintLessThanOrEqualToAnchor:countLbl.leadingAnchor constant:-8],
            [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [countLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [countLbl.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    if (ip.section == TPK_SECTION_OPTIONS) {
        if (ip.row == 0) {
        return TPKSwitchCell(L(@"switch_chat_custom"),
                    @"message.badge.filled.fill",
                    TPKAccent(),
                    mgr.chatCustomTestEnabled,
                    self, @selector(toggleChatCustom:), nil);
        }
        return TPKSwitchCell(L(@"switch_floating_button"),
                    @"circle.grid.2x1.fill",
                    UIColor.systemOrangeColor,
                    mgr.showFloatingButton,
                    self, @selector(toggleFloatingButton:), nil);
    }

    if (ip.section == TPK_SECTION_TRANSFER) {
        if (ip.row == 0) {
        return TPKNavCell(L(@"settings_export"), L(@"settings_export_subtitle"),
            @"square.and.arrow.up", TPKAccent(), nil);
        }
        return TPKNavCell(L(@"settings_import"), L(@"settings_import_subtitle"),
            @"square.and.arrow.down", UIColor.systemGreenColor, nil);
    }

    if (ip.section == TPK_SECTION_LOGS) {
        NSArray<NSNumber *> *visible = [self tpk_visibleLogsRows];
        NSInteger visibleCount = (NSInteger)visible.count;

        // VAFT diagnostics are independent of TwitchPlusK logs and AdBlock.
        if (ip.row >= visibleCount) {
            switch (ip.row - visibleCount) {
                case 0:
                    return TPKSwitchCell(L(@"vaft_diag_logging"),
                                @"record.circle",
                                UIColor.systemTealColor,
                                tas_diagnostics_logging_enabled(),
                                self, @selector(toggleVaftDiagnosticLogging:), nil);
                case 1:
                    return TPKNavCell(L(@"vaft_diag_view"),
                                L(@"vaft_diag_view_sub"),
                                @"doc.plaintext", UIColor.systemBlueColor, nil);
                case 2: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                    cell.backgroundColor = TPKCellBg();
                    cell.selectedBackgroundView = [[UIView alloc] init];
                    cell.selectedBackgroundView.backgroundColor =
                        [UIColor colorWithWhite:1.0 alpha:0.06];
                    UIImageView *icon = TPKIcon(@"doc.on.doc", TPKAccent());
                    [cell.contentView addSubview:icon];
                    UILabel *lbl = [[UILabel alloc] init];
                    lbl.text = L(@"vaft_diag_copy");
                    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
                    lbl.textColor = [UIColor whiteColor];
                    lbl.numberOfLines = 1;
                    lbl.translatesAutoresizingMaskIntoConstraints = NO;
                    [cell.contentView addSubview:lbl];
                    UILabel *sub = [[UILabel alloc] init];
                    sub.text = L(@"vaft_diag_copy_sub");
                    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
                    sub.textColor = TPKGray();
                    sub.numberOfLines = 1;
                    sub.translatesAutoresizingMaskIntoConstraints = NO;
                    [cell.contentView addSubview:sub];
                    [NSLayoutConstraint activateConstraints:@[
                        [icon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                        [icon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
                        [icon.widthAnchor     constraintEqualToConstant:22],
                        [icon.heightAnchor    constraintEqualToConstant:22],
                        [lbl.leadingAnchor    constraintEqualToAnchor:icon.trailingAnchor constant:14],
                        [lbl.topAnchor        constraintEqualToAnchor:cell.contentView.topAnchor constant:11],
                        [sub.leadingAnchor    constraintEqualToAnchor:icon.trailingAnchor constant:14],
                        [sub.topAnchor        constraintEqualToAnchor:lbl.bottomAnchor constant:1],
                        [sub.bottomAnchor     constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
                    ]];
                    return cell;
                }
                case 3:
                default: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                    cell.backgroundColor = TPKCellBg();
                    cell.selectedBackgroundView = [[UIView alloc] init];
                    cell.selectedBackgroundView.backgroundColor =
                        [UIColor colorWithWhite:1.0 alpha:0.06];
                    UIImageView *icon = TPKIcon(@"trash", UIColor.systemRedColor);
                    [cell.contentView addSubview:icon];
                    UILabel *lbl = [[UILabel alloc] init];
                    lbl.text = L(@"vaft_diag_clear");
                    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
                    lbl.textColor = UIColor.systemRedColor;
                    lbl.numberOfLines = 1;
                    lbl.translatesAutoresizingMaskIntoConstraints = NO;
                    [cell.contentView addSubview:lbl];
                    [NSLayoutConstraint activateConstraints:@[
                        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                        [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
                        [lbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
                    ]];
                    return cell;
                }
            }
        }

        if (ip.row >= visibleCount) return [[UITableViewCell alloc] init];
        NSInteger row = visible[ip.row].integerValue;

        // Enable logs.
        if (row == TPKLogsRowEnable) {
            return TPKSwitchCell(L(@"switch_enable_logs"),
                        @"bolt.fill",
                        UIColor.systemYellowColor,
                        mgr.logsEnabled,
                        self, @selector(toggleLogsEnabled:), nil);
        }

        // View logs when logging is enabled.
        if (row == TPKLogsRowView) {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
            cell.backgroundColor = TPKCellBg();
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.selectedBackgroundView.backgroundColor =
                [UIColor colorWithWhite:1.0 alpha:0.06];

            UIImageView *icon = TPKIcon(@"doc.text.magnifyingglass",
                                          UIColor.systemBlueColor);
            [cell.contentView addSubview:icon];

            UILabel *nameLbl = [[UILabel alloc] init];
            nameLbl.text = L(@"view_logs");
            nameLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
            nameLbl.textColor = [UIColor whiteColor];
            nameLbl.numberOfLines = 1;
            nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:nameLbl];

            NSUInteger n = [mgr allLogs].count;
            UILabel *badge = [[UILabel alloc] init];
            badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)n];
            badge.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            badge.textColor = TPKGray();
            badge.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:badge];

            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor    constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [icon.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [nameLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
                [nameLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [nameLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
                [nameLbl.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8],
                [badge.trailingAnchor   constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
                [badge.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
            ]];
            return cell;
        }

        // Console logging when logging is enabled.
        if (row == TPKLogsRowConsole) {
            return TPKSwitchCell(L(@"switch_logs_console"),
                        @"terminal.fill",
                        UIColor.systemGreenColor,
                        mgr.debugLogging,
                        self, @selector(toggleDebug:), nil);
        }

        // Log categories.
        NSInteger catIdx = row - TPKLogsRowFirstCat;
        NSArray<NSString *> *titles = @[
            L(@"log_cat_errors"), L(@"log_cat_chat_custom"),
            L(@"log_cat_channel_points"), L(@"log_cat_tap"),
        ];
        NSArray<NSString *> *icons = @[
            @"exclamationmark.triangle.fill", @"hammer.fill", @"gift.fill",
            @"hand.tap.fill",
        ];
        // Couleurs correspondantes.
        NSArray<UIColor *> *colors = @[
            UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemYellowColor,
            UIColor.systemGreenColor,
        ];
        NSArray<NSNumber *> *values = @[
            @(mgr.logErrors), @(mgr.logChatCustom), @(mgr.logChannelPoints),
            @(mgr.logTap),
        ];
        NSArray *selectors = @[
            @"toggleLogErrors:", @"toggleLogChatCustom:", @"toggleLogChannelPoints:",
            @"toggleLogTap:",
        ];

        UITableViewCell *cell = TPKSwitchCell(titles[catIdx],
                    icons[catIdx],
                    colors[catIdx],
                    values[catIdx].boolValue,
                    self, NSSelectorFromString(selectors[catIdx]), nil);
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == TPK_SECTION_TOOLS) {
        if (ip.row == TPK_TOOLS_ROW_CACHE) [self clearCache];
        else [self.navigationController pushViewController:[TPKHookDiagnosticsController new]
                                                 animated:YES];
        return;
    }

    if (ip.section == TPK_SECTION_TRANSFER) {
        if (ip.row == 0) [self tpk_exportSettingsFromAnchor:[tv cellForRowAtIndexPath:ip]];
        else [self tpk_importSettingsFromFile];
        return;
    }

    if (ip.section == TPK_SECTION_LOGS) {
        NSArray<NSNumber *> *visible = [self tpk_visibleLogsRows];
        NSInteger visibleCount = (NSInteger)visible.count;

        // VAFT diagnostics block.
        if (ip.row >= visibleCount) {
            switch (ip.row - visibleCount) {
                case 1: {
                    // Push the TASDiagnostics report screen.
                    id viewer = tas_create_diagnostic_log_viewer();
                    if (!viewer) return;
                    [viewer setTitle:L(@"vaft_report_title")];
                    [self.navigationController pushViewController:viewer
                                                         animated:YES];
                    return;
                }
                case 2: {
                    tas_copy_diagnostic_report_to_clipboard();
                    [self tpk_showVaftDiagNotice:L(@"vaft_diag_copied_title")
                                          message:L(@"vaft_diag_copied_msg")];
                    return;
                }
                case 3: {
                    tas_perform_clear_diagnostic_log();
                    [tv reloadData];
                    [self tpk_showVaftDiagNotice:L(@"vaft_diag_cleared_title")
                                          message:L(@"vaft_diag_cleared_msg")];
                    return;
                }
                default: return;
            }
        }

        NSInteger row = visible[ip.row].integerValue;
        if (row == TPKLogsRowView) {
            // Log clearing is handled by this screen.
            [self.navigationController
                pushViewController:[[TPKLogsController alloc] init] animated:YES];
        }
        return;
    }
}

// Clears the 7TV disk/memory/badge cache and reloads emotes.
- (void)clearCache {
    TPKManager *mgr = [TPKManager sharedManager];
    __weak typeof(self) weakSelf = self;
    [mgr clearAllCachesWithCompletion:^(NSUInteger clearedCount) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.displayedCachedEmoteCount = 0;
        [strongSelf.tableView reloadData];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:L(@"alert_cache_cleared_title")
                             message:[NSString stringWithFormat:L(@"alert_cache_cleared_message_format"),
                                      (unsigned long)clearedCount]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
            style:UIAlertActionStyleDefault handler:nil]];
        TPKPresentAlert(strongSelf, alert);
    }];
}

// Settings export/import.

- (void)tpk_exportSettingsFromAnchor:(UIView *)anchor {
    NSError *error = nil;
    NSData *data = TPKSettingsExportData(&error);
    if (!data) {
        [self tpk_showSettingsTransferAlertWithTitle:L(@"settings_export_failed_title")
                                              message:L(@"settings_export_failed_message")];
        return;
    }

    NSURL *directoryURL = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *fileURL = [directoryURL URLByAppendingPathComponent:TPKSettingsExportFileName()];
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
        [self tpk_showSettingsTransferAlertWithTitle:L(@"settings_export_failed_title")
                                              message:L(@"settings_export_failed_message")];
        return;
    }

    UIActivityViewController *sheet = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    UIView *source = anchor ?: self.view;
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    TPKPresentAlert(self, sheet);
}

- (void)tpk_importSettingsFromFile {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"com.apple.property-list", @"public.data"]
                       inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url) [self tpk_importSettingsAtURL:url];
}

- (void)tpk_importSettingsAtURL:(NSURL *)url {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data) {
        [self tpk_showSettingsTransferAlertWithTitle:L(@"settings_import_failed_title")
                                              message:L(@"error_cant_read_file")];
        return;
    }

    // Detect legacy favorites before importing to avoid overwriting the current 7TV slice.
    BOOL hasLegacyFavorites = NO;
    id archive = [NSPropertyListSerialization propertyListWithData:data
                                                              options:NSPropertyListImmutable
                                                               format:nil
                                                                error:NULL];
    if ([archive isKindOfClass:NSDictionary.class]) {
        NSDictionary *values = archive[@"values"];
        hasLegacyFavorites = [values isKindOfClass:NSDictionary.class] &&
            values[@"tpk_favorites"] != nil;
    }

    NSUInteger importedCount = TPKSettingsImportData(data, &error);
    if (importedCount == NSNotFound) {
        [self tpk_showSettingsTransferAlertWithTitle:L(@"settings_import_failed_title")
                                              message:L(@"settings_import_invalid_file")];
        return;
    }

    [self tpk_applyImportedSettingsWithLegacyFavorites:hasLegacyFavorites];
    [self.tableView reloadData];
    [self tpk_showSettingsTransferAlertWithTitle:L(@"settings_import_success_title")
                                          message:[NSString stringWithFormat:
                                              L(@"settings_import_success_message_format"),
                                              (unsigned long)importedCount]];
}

- (void)tpk_applyImportedSettingsWithLegacyFavorites:(BOOL)hasLegacyFavorites {
    // Reload singleton preferences without rewriting the imported backup.
    [[TPKManager sharedManager] reloadPreferencesFromDefaults];
    // Replace only the legacy 7TV slice; keep BTTV/FFZ favorites untouched.
    if (hasLegacyFavorites) {
        [[TPKEmoteCatalog sharedCatalog]
            replaceLegacyTPKFavoriteIDs:
                [TPKManager sharedManager].favoriteEmoteIDsSnapshot];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKProviderCatalogDidUpdateNotification
                      object:[TPKEmoteCatalog sharedCatalog]
                    userInfo:@{@"favorites": @YES}];
    // Normalize multi-provider settings and apply the v1 migration after import.
    [TPKEmoteProviderSettings migrateLegacySettings];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKEmoteProviderSettingsDidChangeNotification object:nil];

    TPKChatAppearanceConfig *chatConfig = [TPKChatAppearanceConfig sharedConfig];
    [chatConfig reloadFromDefaults];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKChatAppearanceConfigDidChangeNotification object:chatConfig];
    TPKOLEDModeReloadFromDefaults();

    NSInteger language = [NSUserDefaults.standardUserDefaults integerForKey:@"tpk_language"];
    if (language != TPKLanguageFrench) language = TPKLanguageEnglish;
    [TPKLocalization shared].currentLanguage = (TPKLanguage)language;
    self.title = L(@"title_avance");

    // Use setters to refresh the rotation observer and existing player button.
    tpk_setOrientationLockButtonEnabled(tpk_orientationLockButtonEnabled());
    tpk_setAutoOrientationLockMode(tpk_autoOrientationLockMode());

    // Refresh the AdBlock configured snapshot; the active method stays fixed until restart.
    TPKAdblockRefreshRuntimeSnapshots();

    // A configured/active mismatch requires a Twitch restart; hooks are unchanged here.
    if (TPKAdblockConfiguredMethod() != TPKAdblockActiveMethod()) {
        TPKAdblockMethod configured = TPKAdblockConfiguredMethod();
        NSString *message;
        switch (configured) {
            case TPKAdblockMethodLocalVaft:
                message = L(@"adblock_restart_local_msg"); break;
            case TPKAdblockMethodDisabled:
                message = L(@"adblock_restart_disabled_msg"); break;
            case TPKAdblockMethodProxy:
            default:
                message = L(@"adblock_restart_proxy_msg"); break;
        }
        [self tpk_showSettingsTransferAlertWithTitle:L(@"adblock_restart_title")
                                              message:message];
    }
}

- (void)tpk_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                               style:UIAlertActionStyleDefault handler:nil]];
    TPKPresentAlert(self, alert);
}

- (void)toggleLogsEnabled:(UISwitch *)sw {
    [TPKManager sharedManager].logsEnabled = sw.isOn;
    // Refresh dependent log rows.
    TPKReloadSection(self.tableView, TPK_SECTION_LOGS);
}

// VAFT diagnostics use the separate TASDiagnostics engine.

- (void)toggleVaftDiagnosticLogging:(UISwitch *)sw {
    tas_diagnostics_set_logging_enabled(sw.isOn);
}

- (void)tpk_showVaftDiagNotice:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    TPKPresentAlert(self, alert);
}
- (void)toggleDebug:(UISwitch *)sw                  { [TPKManager sharedManager].debugLogging        = sw.isOn; }
- (void)toggleChatCustom:(UISwitch *)sw             { [TPKManager sharedManager].chatCustomTestEnabled = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw         { [TPKManager sharedManager].showFloatingButton  = sw.isOn; }

- (void)toggleLogErrors:(UISwitch *)sw           { [TPKManager sharedManager].logErrors           = sw.isOn; }
- (void)toggleLogChatCustom:(UISwitch *)sw       { [TPKManager sharedManager].logChatCustom       = sw.isOn; }
- (void)toggleLogChannelPoints:(UISwitch *)sw    { [TPKManager sharedManager].logChannelPoints    = sw.isOn; }
- (void)toggleLogTap:(UISwitch *)sw              { [TPKManager sharedManager].logTap              = sw.isOn; }

@end
