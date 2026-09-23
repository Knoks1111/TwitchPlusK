// TwitchPlusK settings UI.

#import "Settings/7tv-settings-controller.h"
#import "Core/7tv-core-manager.h"
#import "Core/7tv-channel-resolver.h"
#import "Logs/7tv-logs-controller.h"
#import "Network/7tv-network-emote-cache.h"
#import "Emote/7tv-emote-image-cache.h"
#import "Emote/7tv-emote-catalog.h"
#import "Emote/7tv-provider-settings.h"
#import "Picker/7tv-picker-resolved-emote.h"
#import "UI/7tv-ui-logo.h"
#import "UI/7tv-twitchplusk-logo.h"
#import "UI/bttv-ui-logo.h"
#import "UI/ffz-ui-logo.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Localization/7tv-localization-manager.h"
#import "System/7tv-system-native-behavior-hooks.h"
#import "System/7tv-system-chat-top-banner.h"
#import "System/7tv-system-player-gestures.h"
#import "System/7tv-system-player-reload.h"
#import "System/7tv-system-autoclaim.h"
#import "System/7tv-system-home-features.h"
#import "System/7tv-system-tab-visibility.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Adblock/Proxy/7tv-adblock-proxy-status.h"
#import "Diagnostics/7tv-hook-diagnostics.h"
#import "Settings/7tv-settings-transfer.h"
#import "UI/7tv-info-tooltip.h"
#import "UI/7tv-oled-mode.h"
#import "Adblock/Vaft/7tv-adblock-vaft.h"
#import <objc/runtime.h>
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"
static NSString *const kS7TVFavoriteEmoteNamesKey = @"s7tv_favorite_emote_names";
static NSString *const kS7TVGitHubURL = @"https://github.com/Knoks1111/TwitchPlusK";
static NSString *const kS7TVGitHubAvatarURL = @"https://github.com/Knoks1111.png?size=96";

// MARK: - Palette couleurs

// Main background; OLED uses pure black.
static UIColor *S7TVBg(void) {
    if (S7TVOLEDModeEnabled()) return UIColor.blackColor;
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}

// Cell background; keep grouped cells visible in OLED mode.
static UIColor *S7TVCellBg(void) {
    if (S7TVOLEDModeEnabled()) return [UIColor colorWithWhite:0.05 alpha:1.0];
    return [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23
}

// Table separators.
static UIColor *S7TVSeparatorColor(void) {
    if (S7TVOLEDModeEnabled()) return [UIColor colorWithWhite:0.12 alpha:1.0];
    return [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}

// Accent violet.
UIColor *S7TVAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // #8E45E0
}

// Secondary gray.
static UIColor *S7TVGray(void) {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

// Synchronises switch-icon color with its state.
static UIColor *S7TVSwitchIconColor(UIColor *onColor, BOOL isOn) {
    return isOn ? onColor : [UIColor systemGrayColor];
}

// Builds visible rows from fixed and conditional logical indexes.
// Hidden child rows keep their stored defaults and are removed without animation.

// fixed = always visible rows; conditional = parent-dependent rows.
static NSArray<NSNumber *> *S7TVVisibleRowIndexes(NSArray<NSNumber *> *fixed,
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
static void S7TVReloadCellWithoutJump(UITableView *tableView, UIView *anchor) {
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
static void S7TVReloadSectionWithoutJump(UITableView *tableView, NSInteger section) {
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
static void S7TVReloadDataWithoutJump(UITableView *tableView) {
    if (!tableView) return;
    CGPoint contentOffset = tableView.contentOffset;
    [UIView performWithoutAnimation:^{
        [tableView reloadData];
        [tableView layoutIfNeeded];
    }];
    [tableView setContentOffset:contentOffset animated:NO];
}

// Reloads one dependent section after a parent switch.
static void S7TVReloadSection(UITableView *tableView, NSInteger section) {
    S7TVReloadSectionWithoutJump(tableView, section);
}

@interface S7TVSettingsResolvedEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy) NSString *emoteID;
@property (nonatomic, assign) CGSize nativeSize;
@property (nonatomic, assign) BOOL isAnimated;
@property (nonatomic, strong) NSURL *imageURL;
+ (instancetype)emoteWithID:(NSString *)emoteID;
@end

@implementation S7TVSettingsResolvedEmote
+ (instancetype)emoteWithID:(NSString *)emoteID {
    S7TVSettingsResolvedEmote *emote = [S7TVSettingsResolvedEmote new];
    emote.emoteID = emoteID;
    emote.nativeSize = CGSizeMake(32.0, 32.0);
    emote.isAnimated = NO; // Les réglages n'affichent que la première frame.
    NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
    resolution = MIN(4, MAX(1, resolution));
    emote.imageURL = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://cdn.7tv.app/emote/%@/%ldx.webp", emoteID, (long)resolution]];
    return emote;
}
@end

static void S7TVLoadSettingsEmoteImage(NSString *emoteID, UIImageView *imageView) {
    if (!emoteID.length || !imageView) return;
    imageView.accessibilityIdentifier = emoteID;
    imageView.image = nil;
    S7TVSettingsResolvedEmote *emote = [S7TVSettingsResolvedEmote emoteWithID:emoteID];
    UIImage *cached = [[SevenTVEmoteImageCache sharedCache] cachedImageForResolvedEmote:emote];
    if (cached) {
        imageView.image = cached;
        return;
    }
    __weak UIImageView *weakImageView = imageView;
    [[SevenTVEmoteImageCache sharedCache] imageForResolvedEmote:emote completion:^(UIImage *image) {
        UIImageView *strongImageView = weakImageView;
        if ([strongImageView.accessibilityIdentifier isEqualToString:emoteID]) {
            strongImageView.image = image;
        }
    }];
}

// Favorite keys include their provider; reject malformed export values.
static BOOL S7TVSettingsParseFavoriteKey(NSString *key,
                                         S7TVEmoteProviderID *provider,
                                         NSString **emoteID) {
    if (!key.length) return NO;
    NSRange separator = [key rangeOfString:@":" options:0
                                     range:NSMakeRange(0, key.length)];
    if (separator.location == NSNotFound || separator.location == 0 ||
        separator.location >= key.length - 1) return NO;
    NSString *prefix = [[key substringToIndex:separator.location] lowercaseString];
    S7TVEmoteProviderID parsedProvider;
    if ([prefix isEqualToString:@"7tv"]) parsedProvider = S7TVEmoteProviderIDSevenTV;
    else if ([prefix isEqualToString:@"bttv"]) parsedProvider = S7TVEmoteProviderIDBTTV;
    else if ([prefix isEqualToString:@"ffz"]) parsedProvider = S7TVEmoteProviderIDFFZ;
    else return NO;
    if (provider) *provider = parsedProvider;
    if (emoteID) *emoteID = [key substringFromIndex:separator.location + 1];
    return YES;
}

static NSString *S7TVSettingsCanonicalFavoriteKey(NSString *key) {
    if (!key.length) return nil;
    S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
    NSString *emoteID = nil;
    if (S7TVSettingsParseFavoriteKey(key, &provider, &emoteID))
        return S7TVEmoteFavoriteKey(provider, emoteID);
    // Accept legacy bare 7TV IDs during import.
    if (![key containsString:@":"])
        return S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, key);
    return nil;
}

// Settings adapter for provider-specific CDN URLs and resolutions.
@interface S7TVSettingsCatalogResolvedEmote : NSObject <S7TVResolvedEmote>
@property (nonatomic, strong) S7TVEmoteDescriptor *descriptor;
@end

@implementation S7TVSettingsCatalogResolvedEmote
- (NSString *)emoteID {
    return S7TVEmoteFavoriteKey(self.descriptor.provider, self.descriptor.emoteID);
}
- (CGSize)nativeSize { return self.descriptor.nativeSize; }
- (BOOL)isAnimated { return self.descriptor.animated; }
- (NSURL *)imageURL {
    return [self.descriptor imageURLForResolution:
        [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution];
}
@end

static void S7TVLoadSettingsCatalogEmoteImage(S7TVEmoteDescriptor *descriptor,
                                               UIImageView *imageView) {
    if (!descriptor || !descriptor.emoteID.length || !imageView) return;
    NSString *key = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
    imageView.accessibilityIdentifier = key;
    imageView.image = nil;

    S7TVSettingsCatalogResolvedEmote *resolved = [S7TVSettingsCatalogResolvedEmote new];
    resolved.descriptor = descriptor;
    UIImage *cached = [[SevenTVEmoteImageCache sharedCache]
        cachedImageForResolvedEmote:resolved];
    if (cached) {
        imageView.image = cached;
        return;
    }
    __weak UIImageView *weakImageView = imageView;
    [[SevenTVEmoteImageCache sharedCache] imageForResolvedEmote:resolved
        completion:^(UIImage *image) {
        UIImageView *strongImageView = weakImageView;
        if ([strongImageView.accessibilityIdentifier isEqualToString:key])
            strongImageView.image = image;
    }];
}

static S7TVEmoteDescriptor *S7TVSettingsDescriptorForFavoriteKey(NSString *key) {
    S7TVEmoteProviderID provider;
    NSString *emoteID = nil;
    if (!S7TVSettingsParseFavoriteKey(key, &provider, &emoteID)) return nil;
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    for (S7TVEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        if (descriptor.provider == provider &&
            [descriptor.emoteID isEqualToString:emoteID]) return descriptor;
    }
    for (S7TVEmoteDescriptor *descriptor in [catalog allEmotesForProvider:provider]) {
        if ([descriptor.emoteID isEqualToString:emoteID]) return descriptor;
    }
    return nil;
}

static UIView *S7TVFavoriteEmotePreview(NSArray<NSString *> *favoriteIDs) {
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
        NSString *favoriteKey = S7TVSettingsCanonicalFavoriteKey(rawKey);
        if (!favoriteKey.length) continue;
        S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
        NSString *emoteID = nil;
        BOOL qualified = S7TVSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
        S7TVEmoteDescriptor *descriptor =
            S7TVSettingsDescriptorForFavoriteKey(favoriteKey);
        if (descriptor) S7TVLoadSettingsCatalogEmoteImage(descriptor, imageView);
        else if (provider == S7TVEmoteProviderIDSevenTV || !qualified)
            S7TVLoadSettingsEmoteImage(emoteID ?: rawKey, imageView);
    }
    return preview;
}


// MARK: - Helpers UI

// SF Symbol icon view.
static UIImageView *S7TVIcon(NSString *sfName, UIColor *tint) {
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
static UITableViewCell *S7TVNavCell(NSString *title,
                                     NSString *subtitle,
                                     NSString *sfName,
                                     UIColor  *iconTint,
                                     NSString *infoKey) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = S7TVIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    // Match native Twitch settings typography.
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.numberOfLines = 1;
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *infoButton = infoKey.length > 0
        ? [S7TVInfoTooltip infoButtonWithKey:infoKey] : nil;

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
        subLbl.textColor = S7TVGray();
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
static UITableViewCell *S7TVDescriptionCell(NSString *key) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();

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

static void S7TVLoadGitHubAvatar(UIImageView *imageView) {
    NSURL *url = [NSURL URLWithString:kS7TVGitHubAvatarURL];
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

static UITableViewCell *S7TVGitHubRepositoryCell(void) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageSymbolConfiguration *starConfig = [UIImageSymbolConfiguration
        configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    UIImageView *star = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"star" withConfiguration:starConfig]];
    star.tintColor = S7TVAccent();
    star.frame = CGRectMake(0, 0, 22, 22);
    cell.accessoryView = star;

    UIView *avatarRing = [[UIView alloc] init];
    avatarRing.translatesAutoresizingMaskIntoConstraints = NO;
    avatarRing.layer.cornerRadius = 19;
    avatarRing.layer.borderWidth = 2;
    avatarRing.layer.borderColor = S7TVAccent().CGColor;
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
    subtitle.textColor = S7TVGray();
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
    S7TVLoadGitHubAvatar(avatar);
    return cell;
}

// Choice cell with the current value on the right.
static UITableViewCell *S7TVRightValueNavCell(NSString *title,
                                               NSString *value,
                                               NSString *sfName,
                                               UIColor *iconTint) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = S7TVIcon(sfName, iconTint);
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
    valueLabel.textColor = S7TVGray();
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

static char kS7TVSwitchOnColorKey;

// Keeps a switch icon synchronized immediately after toggling.
@interface S7TVSwitchIconUpdater : NSObject
+ (void)s7tv_switchValueChanged:(UISwitch *)sw;
@end

@implementation S7TVSwitchIconUpdater
+ (void)s7tv_switchValueChanged:(UISwitch *)sw {
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

    UIColor *onColor = objc_getAssociatedObject(sw, &kS7TVSwitchOnColorKey);
    if (!onColor) onColor = [UIColor systemGrayColor];
    icon.tintColor = sw.isOn ? onColor : [UIColor systemGrayColor];
}
@end

// Cell with a UISwitch and optional info button.
static UITableViewCell *S7TVSwitchCell(NSString *title,
                                        NSString *sfName,
                                        UIColor  *iconTint,
                                        BOOL      isOn,
                                        id        target,
                                        SEL       action,
                                        NSString *infoKey) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();

    UIImageView *icon = S7TVIcon(sfName, S7TVSwitchIconColor(iconTint, isOn));
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
    sw.onTintColor = S7TVAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    // Icon color follows the switch state.
    objc_setAssociatedObject(sw, &kS7TVSwitchOnColorKey, iconTint,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:[S7TVSwitchIconUpdater class]
           action:@selector(s7tv_switchValueChanged:)
 forControlEvents:UIControlEventValueChanged];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:sw];

    UIButton *infoButton = infoKey.length > 0
        ? [S7TVInfoTooltip infoButtonWithKey:infoKey] : nil;
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

static char kS7TVPlayerGestureSensitivityValueLabelKey;

// Sensitivity row with minus/plus controls.
static UITableViewCell *S7TVPlayerGestureSensitivityCell(CGFloat value,
                                                          id target) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();

    UIImageView *icon = S7TVIcon(@"speedometer", S7TVAccent());
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
    minusButton.tintColor = S7TVAccent();
    plusButton.tintColor = S7TVAccent();
    minusButton.accessibilityLabel = L(@"player_gestures_sensitivity_decrease");
    plusButton.accessibilityLabel = L(@"player_gestures_sensitivity_increase");
    minusButton.translatesAutoresizingMaskIntoConstraints = NO;
    plusButton.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
    valueLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    valueLabel.textColor = S7TVGray();
    valueLabel.textAlignment = NSTextAlignmentCenter;
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:valueLabel];

    objc_setAssociatedObject(minusButton,
                             &kS7TVPlayerGestureSensitivityValueLabelKey,
                             valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(plusButton,
                             &kS7TVPlayerGestureSensitivityValueLabelKey,
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
static UIView *S7TVSectionHeader(NSString *title, BOOL withLogo, NSString *infoKey) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title.uppercaseString;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

    UIButton *infoButton = infoKey.length > 0
        ? [S7TVInfoTooltip infoButtonWithKey:infoKey] : nil;
    if (infoButton) {
        infoButton.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:infoButton];
    }

    if (withLogo) {
        // TwitchPlusK logo.
        NSData *logoData = [[NSData alloc]
            initWithBase64EncodedString:kS7TVTwitchPlusKLogoBase64
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

static void S7TVStyleTableView(UITableView *tv) {
    tv.backgroundColor   = S7TVBg();
    tv.separatorColor    = S7TVSeparatorColor();
    tv.separatorInset    = UIEdgeInsetsMake(0, 52, 0, 0);
    // Default to content-driven row heights; controllers can override.
    tv.rowHeight         = UITableViewAutomaticDimension;
    tv.estimatedRowHeight = 60;
}

// Re-style and reload settings screens after an OLED-mode change.
static void S7TVApplyOLEDStyle(UITableViewController *controller) {
    S7TVStyleTableView(controller.tableView);
    S7TVReloadDataWithoutJump(controller.tableView);
}

// Registers the shared OLED-mode observer for a settings controller.
static void S7TVRegisterOLEDObserver(id observer) {
    [[NSNotificationCenter defaultCenter] addObserver:observer
        selector:@selector(s7tv_oledModeDidChange)
            name:S7TVOLEDModeDidChangeNotification object:nil];
}

// Reads a boolean preference with an explicit default value.
static BOOL S7TVBoolDefaultYes(NSString *key) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    return [prefs objectForKey:key] != nil ? [prefs boolForKey:key] : YES;
}
static void S7TVSetBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Mirrors the default emote resolution from the appearance config.
static const NSInteger kS7TVDefaultEmoteResolution = 2;

// Adds a default-value suffix to choice subtitles when useful.
static NSString *S7TVValueWithDefaultMark(NSString *value, BOOL isDefault) {
    if (!isDefault) return value;
    if ([value isEqualToString:L(@"launch_default")]) return value;
    return [value stringByAppendingString:L(@"common_default_suffix")];
}

// Alerte à un bouton, partagée par les pages de réglages.
static void S7TVShowAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                          style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:a animated:YES completion:nil];
}

typedef NS_ENUM(NSInteger, S7TVPickerAnimationsMode) {
    S7TVPickerAnimationsModeDisabled = 0,
    S7TVPickerAnimationsModeEnabled = 1,
    S7TVPickerAnimationsModeFavoritesOnly = 2,
};

static S7TVPickerAnimationsMode S7TVCurrentPickerAnimationsMode(void) {
    SevenTVManager *manager = [SevenTVManager sharedManager];
    if (!manager.showPickerAnimations) return S7TVPickerAnimationsModeDisabled;
    return manager.showPickerAnimationsFavoritesOnly
        ? S7TVPickerAnimationsModeFavoritesOnly
        : S7TVPickerAnimationsModeEnabled;
}

static NSString *S7TVPickerAnimationsModeTitle(S7TVPickerAnimationsMode mode) {
    switch (mode) {
        case S7TVPickerAnimationsModeDisabled:
            return L(@"picker_animations_disabled");
        case S7TVPickerAnimationsModeFavoritesOnly:
            return L(@"picker_animations_favorites_only");
        case S7TVPickerAnimationsModeEnabled:
        default:
            return L(@"picker_animations_enabled");
    }
}


// MARK: - Intégration dans les paramètres Twitch natifs

static NSInteger s7tv_settingsOriginalSection(NSInteger section) {
    return section - 1;
}

static NSInteger s7tv_settingsNumberOfSections(id self, SEL cmd, UITableView *tableView) {
    SEL original = NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:");
    NSInteger (*implementation)(id, SEL, UITableView *) =
        (NSInteger (*)(id, SEL, UITableView *))[self methodForSelector:original];
    return implementation(self, original, tableView) + 1;
}

static NSInteger s7tv_settingsNumberOfRows(id self, SEL cmd, UITableView *tableView,
                                            NSInteger section) {
    if (section == 0) return 1;
    SEL original = NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:");
    NSInteger (*implementation)(id, SEL, UITableView *, NSInteger) =
        (NSInteger (*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, s7tv_settingsOriginalSection(section));
}

static NSString *s7tv_settingsHeaderTitle(id self, SEL cmd, UITableView *tableView,
                                           NSInteger section) {
    if (section == 0) return nil;
    SEL original = NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:");
    NSString *(*implementation)(id, SEL, UITableView *, NSInteger) =
        (NSString *(*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, s7tv_settingsOriginalSection(section));
}

static UIView *s7tv_settingsHeaderView(id self, SEL cmd, UITableView *tableView,
                                        NSInteger section) {
    if (section != 0) {
        SEL original = NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:");
        UIView *(*implementation)(id, SEL, UITableView *, NSInteger) =
            (UIView *(*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
        return implementation(self, original, tableView, s7tv_settingsOriginalSection(section));
    }

    // The cell title and logo identify the tweak; no duplicate section header.
    return [UIView new];
}

static CGFloat s7tv_settingsHeaderHeight(id self, SEL cmd, UITableView *tableView,
                                          NSInteger section) {
    if (section == 0) return 8.0;
    SEL original = NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:");
    CGFloat (*implementation)(id, SEL, UITableView *, NSInteger) =
        (CGFloat (*)(id, SEL, UITableView *, NSInteger))[self methodForSelector:original];
    return implementation(self, original, tableView, s7tv_settingsOriginalSection(section));
}

static UITableViewCell *s7tv_settingsCell(id self, SEL cmd, UITableView *tableView,
                                          NSIndexPath *indexPath) {
    if (indexPath.section != 0) {
        NSIndexPath *originalIndexPath = [NSIndexPath indexPathForRow:indexPath.row
            inSection:s7tv_settingsOriginalSection(indexPath.section)];
        SEL original = NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:");
        UITableViewCell *(*implementation)(id, SEL, UITableView *, NSIndexPath *) =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
                [self methodForSelector:original];
        return implementation(self, original, tableView, originalIndexPath);
    }

    static NSString *reuseIdentifier = @"S7TVSettingsCell";
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
        initWithBase64EncodedString:kS7TVTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = [UIImage imageWithData:logoData scale:6.0];
    if (logo) cell.imageView.image = logo;
    return cell;
}

static void s7tv_settingsDidSelect(id self, SEL cmd, UITableView *tableView,
                                    NSIndexPath *indexPath) {
    if (indexPath.section != 0) {
        NSIndexPath *originalIndexPath = [NSIndexPath indexPathForRow:indexPath.row
            inSection:s7tv_settingsOriginalSection(indexPath.section)];
        SEL original = NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:");
        void (*implementation)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))[self methodForSelector:original];
        implementation(self, original, tableView, originalIndexPath);
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SevenTVSettingsController *controller = [SevenTVSettingsController new];
    [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
}

static void s7tv_settingsExchangeMethod(Class target, SEL originalSelector,
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

// MARK: - SevenTVSettingsController  (Hub principal)

typedef NS_ENUM(NSInteger, S7TVHomeSection) {
    S7TVHomeSectionMain     = 0,  // Apparence, Contenu, Adblock, Avancé
    S7TVHomeSectionLanguage = 1,
};

@implementation SevenTVSettingsController

+ (void)installTwitchSettingsIntegration {
    Class target = NSClassFromString(@"_TtC6Twitch25AccountMenuViewController");
    if (!target) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ _TtC6Twitch25AccountMenuViewController introuvable — swizzle ignoré"];
        return;
    }
    s7tv_settingsExchangeMethod(target, @selector(numberOfSectionsInTableView:),
        NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:"),
        (IMP)s7tv_settingsNumberOfSections, "q@:@");
    s7tv_settingsExchangeMethod(target, @selector(tableView:numberOfRowsInSection:),
        NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:"),
        (IMP)s7tv_settingsNumberOfRows, "q@:@q");
    s7tv_settingsExchangeMethod(target, @selector(tableView:titleForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:"),
        (IMP)s7tv_settingsHeaderTitle, "@@:@q");
    s7tv_settingsExchangeMethod(target, @selector(tableView:viewForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:"),
        (IMP)s7tv_settingsHeaderView, "@@:@q");
    s7tv_settingsExchangeMethod(target, @selector(tableView:heightForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:"),
        (IMP)s7tv_settingsHeaderHeight, "d@:@q");
    s7tv_settingsExchangeMethod(target, @selector(tableView:cellForRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:"),
        (IMP)s7tv_settingsCell, "@@:@@");
    s7tv_settingsExchangeMethod(target, @selector(tableView:didSelectRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:"),
        (IMP)s7tv_settingsDidSelect, "v@:@@");
}

- (instancetype)init {
    // Match native Twitch settings.
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    S7TVStyleTableView(self.tableView);
    [self buildNavBar];

    // Refresh visible text when the language changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(s7tv_languageDidChange)
            name:S7TVLanguageDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(s7tv_channelDidChange:)
            name:S7TVChannelResolverDidChangeNotification
          object:[S7TVChannelResolver sharedResolver]];
    S7TVRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)s7tv_languageDidChange {
    [self buildNavBar];
    [self.tableView reloadData];
}

- (void)s7tv_channelDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded || !self.view.window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isViewLoaded && self.view.window) [self.tableView reloadData];
    });
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)buildNavBar {
    // Navigation title and logo.
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVTwitchPlusKLogoBase64
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
        lbl.textColor = S7TVAccent();
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
            postNotificationName:@"S7TVMenuDidDismiss" object:nil];
    }];
}

// Table view.

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVHomeSectionMain:     return 4; // Apparence / Contenu / Adblock / Avancé
        case S7TVHomeSectionLanguage: return 2;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == S7TVHomeSectionLanguage && ip.row == 1) {
        return UITableViewAutomaticDimension;
    }
    return 60;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == S7TVHomeSectionMain ? 44 : 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVHomeSectionMain:     return S7TVSectionHeader(L(@"title_7tv_settings"), YES, nil);
        case S7TVHomeSectionLanguage: return S7TVSectionHeader(L(@"section_langue"), NO, nil);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return s == S7TVHomeSectionMain ? UITableViewAutomaticDimension : 8;
}

// Read-only summary shown at the bottom of the main settings page.
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (s != S7TVHomeSectionMain) {
        UIView *v = [[UIView alloc] init];
        v.backgroundColor = [UIColor clearColor];
        return v;
    }

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    NSUInteger total = 0;
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        total += [catalog allEmotesForProvider:(S7TVEmoteProviderID)provider].count;
    }
    S7TVChannelContext *context = S7TVCurrentChannelContext();
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
    lbl.textColor = S7TVGray();
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
    if (ip.section == S7TVHomeSectionMain) {
        NSString *sfName, *title, *subtitle;
        UIColor *iconTint;
        switch (ip.row) {
            case 0: sfName=@"paintbrush.fill";            title=L(@"title_apparence"); subtitle=L(@"menu_apparence_subtitle"); iconTint=S7TVAccent(); break;
            case 1: sfName=@"folder.fill";                 title=L(@"title_contenu");   subtitle=L(@"menu_contenu_subtitle"); iconTint=UIColor.systemBlueColor; break;
            case 2: sfName=@"shield.slash.fill";           title=L(@"title_adblock");   subtitle=L(@"menu_adblock_subtitle"); iconTint=UIColor.systemRedColor; break;
            case 3: sfName=@"wrench.and.screwdriver.fill"; title=L(@"title_avance");    subtitle=L(@"menu_avance_subtitle"); iconTint=UIColor.systemIndigoColor; break;
            default: return [[UITableViewCell alloc] init];
        }
        // Keep concise category summaries visible.
        return S7TVNavCell(title, subtitle, sfName, iconTint, nil);
    }

    // Language selection uses a FR/EN segmented control.
    if (ip.section == S7TVHomeSectionLanguage && ip.row == 1) {
        return S7TVGitHubRepositoryCell();
    }

    if (ip.section == S7TVHomeSectionLanguage) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();

        UIImageView *icon = S7TVIcon(@"globe", UIColor.systemTealColor);
        [cell.contentView addSubview:icon];

        UISegmentedControl *seg = [[UISegmentedControl alloc]
            initWithItems:@[@"Français", @"English"]];
        seg.selectedSegmentIndex = ([S7TVLocalization shared].currentLanguage == S7TVLanguageEnglish) ? 1 : 0;
        seg.selectedSegmentTintColor = S7TVAccent();
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
    [S7TVLocalization shared].currentLanguage =
        (seg.selectedSegmentIndex == 1) ? S7TVLanguageEnglish : S7TVLanguageFrench;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == S7TVHomeSectionLanguage && ip.row == 1) {
        NSURL *url = [NSURL URLWithString:kS7TVGitHubURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:nil];
        }
        return;
    }

    UIViewController *dest = nil;
    if (ip.section == S7TVHomeSectionMain) {
        switch (ip.row) {
            case 0: dest = [[SevenTVAppearancePageController alloc] init]; break;
            case 1: dest = [[SevenTVContentPageController    alloc] init]; break;
            case 2: dest = [[SevenTVAdblockPageController    alloc] init]; break;
            case 3: dest = [[SevenTVAdvancedPageController   alloc] init]; break;
        }
    }
    if (dest) [self.navigationController pushViewController:dest animated:YES];
}

@end


// MARK: - SevenTVAdblockPageController
// TwitchAdBlock method and proxy settings.

@interface SevenTVAdblockPageController () <UITextFieldDelegate>
@property (nonatomic, assign) S7TVAdblockProxyStatus proxyStatus;
@property (nonatomic, strong) NSMutableArray<NSString *> *proxies;
// Ignores probe callbacks from an older request.
@property (nonatomic, assign) NSUInteger proxyStatusGeneration;
@end

static const NSInteger kS7TVProxyTextFieldTag = 0x7A01;
static const NSInteger kS7TVProxyUpButtonTag  = 0x7A02;
static const NSInteger kS7TVProxyDownButtonTag = 0x7A03;
static const NSInteger kS7TVProxyDeleteButtonTag = 0x7A04;

static NSString *S7TVAdblockDefaultProxyDisplayName(NSString *address) {
    NSArray<NSString *> *addresses = S7TVAdblockDefaultProxyAddresses();
    if (addresses.count > 0 && [address isEqualToString:addresses[0]])
        return L(@"adblock_proxy_builtin");
    if (addresses.count > 1 && [address isEqualToString:addresses[1]])
        return L(@"adblock_proxy_eu");
    if (addresses.count > 2 && [address isEqualToString:addresses[2]])
        return L(@"adblock_proxy_eu2");
    return address.length ? address : L(@"adblock_proxy_builtin");
}

// General-section rows.
typedef NS_ENUM(NSInteger, S7TVAdblockGeneralRow) {
    S7TVAdblockGeneralRowMethod = 0,
    S7TVAdblockGeneralRowHideTurbo = 1,
};

@implementation SevenTVAdblockPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _proxyStatus = S7TVAdblockProxyStatusUnknown;
        _proxies = S7TVAdblockCustomProxyAddresses().mutableCopy;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_adblock");
    S7TVStyleTableView(self.tableView);
    S7TVRegisterOLEDObserver(self);
    S7TVAdblockRegisterDefaults();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Probe on entry or explicit changes; no periodic timer.
    if (S7TVAdblockConfiguredMethod() == S7TVAdblockMethodProxy &&
        S7TVAdblockProxyIsEnabled()) {
        [self refreshProxyStatus];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [S7TVInfoTooltip dismiss];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        // Method selector: Disabled, Proxy or Local (VAFT).
        return [self s7tv_visibleGeneralRows].count;
    }
    // Local (VAFT) shows an informational row; it has no proxy settings.
    if ([self s7tv_localVaftSectionVisible]) return 1;
    if (![self s7tv_proxySectionVisible]) return 0;
    // Custom mode adds one editable row per configured address.
    return S7TVAdblockCustomProxyIsEnabled() ? 4 + self.proxies.count : 3;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 1 && [self s7tv_localVaftSectionVisible]) {
        // Local mode replaces the proxy header with an informational note.
        UIView *empty = [[UIView alloc] init];
        empty.backgroundColor = UIColor.clearColor;
        return empty;
    }
    // Proxy details are shown from the header info button.
    return S7TVSectionHeader(section == 0 ? L(@"section_general")
                                          : L(@"adblock_section_proxy"), NO,
                             section == 0 ? nil : @"adblock_proxy_privacy_footer");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 1 && [self s7tv_localVaftSectionVisible]) return 8.0;
    return 44.0;
}

// Visible General rows; the method selector replaces the old master toggle.
- (NSArray<NSNumber *> *)s7tv_visibleGeneralRows {
    return @[@(S7TVAdblockGeneralRowMethod),
             @(S7TVAdblockGeneralRowHideTurbo)];
}

// Proxy rows follow the selected method.
- (BOOL)s7tv_proxySectionVisible {
    return S7TVAdblockConfiguredMethod() == S7TVAdblockMethodProxy;
}

// Local (VAFT) uses the dependent-section mechanism without proxy rows.
- (BOOL)s7tv_localVaftSectionVisible {
    return S7TVAdblockConfiguredMethod() == S7TVAdblockMethodLocalVaft;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ([self s7tv_proxySectionVisible] || [self s7tv_localVaftSectionVisible]) ? 2 : 1;
}

- (NSInteger)proxyIndexForRow:(NSInteger)row {
    if (!S7TVAdblockCustomProxyIsEnabled() || row < 2 ||
        row >= 2 + (NSInteger)self.proxies.count) return -1;
    return row - 2;
}

- (NSInteger)addProxyRowIndex {
    return 2 + self.proxies.count;
}

- (NSInteger)statusRowIndex {
    return S7TVAdblockCustomProxyIsEnabled() ? 3 + self.proxies.count : 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray<NSNumber *> *visible = [self s7tv_visibleGeneralRows];
        if (indexPath.row >= (NSInteger)visible.count) {
            return [[UITableViewCell alloc] init];
        }
        switch (visible[indexPath.row].integerValue) {
            case S7TVAdblockGeneralRowMethod: {
                // Configured method: Disabled / Proxy / Local (VAFT).
                S7TVAdblockMethod configured = S7TVAdblockConfiguredMethod();
                NSString *valueKey = configured == S7TVAdblockMethodLocalVaft
                    ? @"adblock_method_value_local"
                    : configured == S7TVAdblockMethodProxy
                        ? @"adblock_method_value_proxy"
                        : @"adblock_method_value_disabled";
                return S7TVNavCell(L(@"adblock_cell_title"), L(valueKey),
                    @"shield.lefthalf.filled", S7TVAccent(), @"adblock_engine_footer");
            }
            case S7TVAdblockGeneralRowHideTurbo:
            default:
                return S7TVSwitchCell(L(@"adblock_hide_go_ad_free"), @"rectangle.slash",
                    [UIColor colorWithRed:0.95 green:0.45 blue:0.25 alpha:1.0],
                    S7TVAdblockHideAdFreeButtonEnabledFast(), self,
                    @selector(toggleHideGoAdFree:), nil);
        }
    }

    if (indexPath.section == 1 && [self s7tv_localVaftSectionVisible]) {
        // Reuse a multi-line descriptive cell without an inner scroll view.
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();

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
    if (indexPath.section != 1 || ![self s7tv_proxySectionVisible]) {
        return [[UITableViewCell alloc] init];
    }

    if (indexPath.row == 0) {
        return [self defaultProxyCell];
    }
    if (indexPath.row == 1) {
        return S7TVSwitchCell(L(@"adblock_custom_proxy"),
            @"server.rack", UIColor.systemTealColor,
            S7TVAdblockCustomProxyIsEnabled(), self,
            @selector(toggleAdblockCustomProxy:), nil);
    }

    if (!S7TVAdblockCustomProxyIsEnabled()) return [self proxyStatusCell];
    NSInteger proxyIndex = [self proxyIndexForRow:indexPath.row];
    if (proxyIndex >= 0) return [self proxyRowCellForIndex:proxyIndex];
    if (indexPath.row == [self addProxyRowIndex]) return [self addProxyCell];
    return [self proxyStatusCell];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && [self s7tv_localVaftSectionVisible]) return;
    if (indexPath.section == 1 && [self s7tv_proxySectionVisible] &&
        indexPath.row == 0) {
        [self presentDefaultProxyPickerFromCell:
            [tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 1 && [self s7tv_proxySectionVisible] &&
        S7TVAdblockProxyIsEnabled() && S7TVAdblockCustomProxyIsEnabled() &&
        indexPath.row == [self addProxyRowIndex]) {
        [self.proxies addObject:@""];
        [self saveProxies];
        S7TVReloadSectionWithoutJump(self.tableView, 1);
    }
    NSArray<NSNumber *> *visibleGeneral = [self s7tv_visibleGeneralRows];
    if (indexPath.section == 0 && indexPath.row < (NSInteger)visibleGeneral.count &&
        visibleGeneral[indexPath.row].integerValue == S7TVAdblockGeneralRowMethod) {
        [self presentMethodActionSheetFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

// Method action sheet. Selection changes the configured method only.
- (void)presentMethodActionSheetFromCell:(UITableViewCell *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_method_title")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();

    S7TVAdblockMethod configured = S7TVAdblockConfiguredMethod();
    NSArray *choices = @[
        @[L(@"adblock_method_value_disabled"), @(S7TVAdblockMethodDisabled)],
        @[L(@"adblock_method_value_local"), @(S7TVAdblockMethodLocalVaft)],
        @[L(@"adblock_method_value_proxy"), @(S7TVAdblockMethodProxy)],
    ];
    for (NSArray *choice in choices) {
        S7TVAdblockMethod method = (S7TVAdblockMethod)[choice[1] integerValue];
        NSString *title = [choice[0] isKindOfClass:NSString.class] ? choice[0] : @"";
        if (method == configured) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self s7tv_applyConfiguredMethod:method];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)s7tv_applyConfiguredMethod:(S7TVAdblockMethod)method {
    S7TVAdblockSetConfiguredMethod(method);
    // Keep the legacy proxy flag synchronized when Proxy is selected.
    if (method == S7TVAdblockMethodProxy) S7TVAdblockSetProxyEnabled(YES);
    S7TVAdblockMethod active = S7TVAdblockActiveMethod();
    if (method == S7TVAdblockMethodDisabled) {
        // Disable the currently loaded engine immediately.
        S7TVAdblockSetEnabled(NO);
    } else if (method == active) {
        // The active method can be applied without a restart.
        S7TVAdblockSetEnabled(YES);
    } else {
        // Keep the active snapshot until restart when switching engines.
        S7TVAdblockSetEnabledForNextLaunch(YES);
    }
    // The number of sections depends on the selected method.
    S7TVReloadDataWithoutJump(self.tableView);

    // Revalidate the endpoint when Proxy is already active.
    if (method == S7TVAdblockMethodProxy && method == active &&
        S7TVAdblockProxyIsEnabled()) {
        self.proxyStatus = S7TVAdblockProxyStatusUnknown;
        [self refreshProxyStatus];
    }

    // A configured/active mismatch requires a Twitch restart.
    if (method == active) return;

    NSString *message;
    switch (method) {
        case S7TVAdblockMethodLocalVaft:
            message = L(@"adblock_restart_local_msg"); break;
        case S7TVAdblockMethodDisabled:
            message = L(@"adblock_restart_disabled_msg"); break;
        case S7TVAdblockMethodProxy:
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
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleHideGoAdFree:(UISwitch *)sender {
    S7TVAdblockSetHideAdFreeButtonEnabled(sender.isOn);
}

- (void)toggleAdblockProxy:(UISwitch *)sender {
    S7TVAdblockSetProxyEnabled(sender.isOn);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    if ([self s7tv_proxySectionVisible]) {
        S7TVReloadSectionWithoutJump(self.tableView, 1);
    } else {
        S7TVReloadDataWithoutJump(self.tableView);
    }
    if (sender.isOn) [self refreshProxyStatus];
}

- (void)toggleAdblockCustomProxy:(UISwitch *)sender {
    S7TVAdblockSetCustomProxyEnabled(sender.isOn);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    if ([self s7tv_proxySectionVisible]) {
        S7TVReloadSectionWithoutJump(self.tableView, 1);
    } else {
        S7TVReloadDataWithoutJump(self.tableView);
    }
    [self refreshProxyStatus];
}

- (UITableViewCell *)defaultProxyCell {
    return S7TVNavCell(L(@"adblock_default_proxy"),
                       S7TVAdblockDefaultProxyDisplayName(
                           S7TVAdblockDefaultProxyAddress()),
                       @"network", S7TVAccent(), nil);
}

- (void)presentDefaultProxyPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *addresses = S7TVAdblockDefaultProxyAddresses();
    NSString *current = S7TVAdblockDefaultProxyAddress();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"adblock_default_proxy")
                          message:L(@"adblock_default_proxy_footer")
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();

    __weak typeof(self) weakSelf = self;
    for (NSString *address in addresses) {
        NSString *title = S7TVAdblockDefaultProxyDisplayName(address);
        if ([address isEqualToString:current])
            title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            S7TVAdblockSetDefaultProxyAddress(address);
            self.proxyStatus = S7TVAdblockProxyStatusUnknown;
            S7TVReloadCellWithoutJump(self.tableView, anchor);
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
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UITableViewCell *)proxyStatusCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"S7TVProxyStatusCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"S7TVProxyStatusCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = S7TVCellBg();
    cell.textLabel.text = S7TVAdblockCustomProxyIsEnabled()
        ? L(@"adblock_proxy_custom_status") : L(@"adblock_proxy_default_status");
    cell.textLabel.textColor = UIColor.whiteColor;
    switch (self.proxyStatus) {
        case S7TVAdblockProxyStatusOnline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_online");
            cell.detailTextLabel.textColor = UIColor.systemGreenColor;
            break;
        case S7TVAdblockProxyStatusOffline:
            cell.detailTextLabel.text = L(@"adblock_proxy_status_offline");
            cell.detailTextLabel.textColor = UIColor.systemRedColor;
            break;
        case S7TVAdblockProxyStatusChecking:
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
    pingButton.tintColor = S7TVAccent();
    pingButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    // Explicitly size the accessory for Twitch cell styles.
    pingButton.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
    pingButton.accessibilityLabel = L(@"adblock_proxy_status_ping");
    [pingButton addTarget:self action:@selector(manualProxyPing:)
          forControlEvents:UIControlEventTouchUpInside];
    BOOL canPing = S7TVAdblockConfiguredMethod() == S7TVAdblockMethodProxy &&
                   S7TVAdblockProxyIsEnabled();
    pingButton.enabled = canPing &&
                         self.proxyStatus != S7TVAdblockProxyStatusChecking;
    cell.accessoryView = pingButton;
    return cell;
}

- (void)manualProxyPing:(UIButton *)sender {
    (void)sender;
    if (S7TVAdblockConfiguredMethod() != S7TVAdblockMethodProxy ||
        !S7TVAdblockProxyIsEnabled() ||
        self.proxyStatus == S7TVAdblockProxyStatusChecking) {
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
    button.tintColor = S7TVAccent();
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITableViewCell *)proxyRowCellForIndex:(NSInteger)index {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"S7TVProxyRowCell"];
    UIButton *up = nil;
    UIButton *down = nil;
    UIButton *deleteButton = nil;
    UITextField *field = nil;
    if (cell) {
        up = (UIButton *)[cell.contentView viewWithTag:kS7TVProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kS7TVProxyDownButtonTag];
        deleteButton = (UIButton *)[cell.contentView viewWithTag:kS7TVProxyDeleteButtonTag];
        field = (UITextField *)[cell.contentView viewWithTag:kS7TVProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"S7TVProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up = [self proxyArrowButton:@"chevron.up" tag:kS7TVProxyUpButtonTag
                             action:@selector(proxyUpTapped:)];
        down = [self proxyArrowButton:@"chevron.down" tag:kS7TVProxyDownButtonTag
                               action:@selector(proxyDownTapped:)];
        deleteButton = [self proxyArrowButton:@"xmark.circle.fill"
                                          tag:kS7TVProxyDeleteButtonTag
                                       action:@selector(proxyDeleteTapped:)];
        deleteButton.accessibilityLabel = L(@"adblock_proxy_delete");
        field = [[UITextField alloc] init];
        field.tag = kS7TVProxyTextFieldTag;
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
    cell.backgroundColor = S7TVCellBg();
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
    cell.backgroundColor = S7TVCellBg();
    cell.textLabel.text = L(@"adblock_proxy_add");
    cell.textLabel.textColor = S7TVAccent();
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
    S7TVAdblockSetCustomProxyAddresses(self.proxies);
}

- (void)proxyUpTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index <= 0) return;
    [self.proxies exchangeObjectAtIndex:index withObjectAtIndex:index - 1];
    [self saveProxies];
    S7TVReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    [self refreshProxyStatus];
}

- (void)proxyDownTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.proxies.count - 1) return;
    [self.proxies exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self saveProxies];
    S7TVReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    [self refreshProxyStatus];
}

- (void)removeProxyAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.proxies.count) return;
    [self.proxies removeObjectAtIndex:index];
    [self saveProxies];
    S7TVReloadSectionWithoutJump(self.tableView, 1);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
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
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.proxies.count) return;
    self.proxies[index] = field.text ?: @"";
    [self saveProxies];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && [self proxyIndexForRow:indexPath.row] >= 0;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger index = [self proxyIndexForRow:indexPath.row];
    [self removeProxyAtIndex:index];
}

- (void)refreshProxyStatus {
    if (![self s7tv_proxySectionVisible] || !S7TVAdblockProxyIsEnabled()) return;
    NSUInteger generation = ++self.proxyStatusGeneration;
    NSString *address = nil;
    if (S7TVAdblockCustomProxyIsEnabled()) {
        for (NSString *proxy in self.proxies) {
            NSString *clean = [proxy stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet];
            if (clean.length) {
                address = clean;
                break;
            }
        }
        if (!address) {
            self.proxyStatus = S7TVAdblockProxyStatusOffline;
            [self reloadProxyStatusRow];
            return;
        }
    } else {
        address = S7TVAdblockDefaultProxyAddress();
    }
    self.proxyStatus = S7TVAdblockProxyStatusChecking;
    [self reloadProxyStatusRow];
    __weak typeof(self) weakSelf = self;
    S7TVAdblockCheckProxyStatus(address, ^(S7TVAdblockProxyStatus status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.proxyStatusGeneration) return;
        self.proxyStatus = status;
        [self reloadProxyStatusRow];
    });
}

- (void)reloadProxyStatusRow {
    if (![self s7tv_proxySectionVisible] || !S7TVAdblockProxyIsEnabled()) return;
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
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index >= 0 && index < (NSInteger)self.proxies.count) {
        self.proxies[index] = textField.text ?: @"";
        [self saveProxies];
    }
    if (S7TVAdblockProxyIsEnabled() && S7TVAdblockCustomProxyIsEnabled()) {
        [self refreshProxyStatus];
    }
}

@end


// MARK: - SevenTVAppearancePageController  (ex-SevenTVEmotesPageController)
// Emote animation and CDN resolution settings.
typedef NS_ENUM(NSInteger, S7TVAppearanceSection) {
    S7TVAppearanceSectionIntro = 0,
    S7TVAppearanceSectionInterface = 1,
    S7TVAppearanceSectionEmotes = 2,
};

//    Rows logiques de la section Émotes.
typedef NS_ENUM(NSInteger, S7TVAppearanceEmoteRow) {
    S7TVAppearanceEmoteRowResolution = 0,
    S7TVAppearanceEmoteRowPickerAnimations = 1,
    S7TVAppearanceEmoteRowProviders = 2,
    S7TVAppearanceEmoteRowProviderPriority = 3,
    S7TVAppearanceEmoteRowPickerOpening = 4,
    S7TVAppearanceEmoteRowMixedPicker = 5,
};

// Rows logiques de la section Interface (affichage, bannières, onglets).
typedef NS_ENUM(NSInteger, S7TVAppearanceInterfaceRow) {
    S7TVAppearanceInterfaceRowTheme = 0,        // mode OLED
    S7TVAppearanceInterfaceRowChatBanners = 1,
    S7TVAppearanceInterfaceRowTabBar = 2,
};

static NSString *S7TVPickerOpeningModeTitle(NSString *mode) {
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeSevenTVChannel]) return L(@"picker_opening_7tv_channel");
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeBTTVChannel]) return L(@"picker_opening_bttv_channel");
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeFFZChannel]) return L(@"picker_opening_ffz_channel");
    if ([mode isEqualToString:S7TVEmotePickerOpeningModeLastUsed]) return L(@"picker_opening_last_used");
    return L(@"picker_opening_favorites");
}

static NSArray<NSNumber *> *S7TVExternalProviderValues(void) {
    return @[
        @(S7TVExternalEmoteProvider7TV),
        @(S7TVExternalEmoteProviderBTTV),
        @(S7TVExternalEmoteProviderFFZ),
    ];
}

static NSString *S7TVExternalProviderDisplayName(S7TVExternalEmoteProvider provider) {
    switch (provider) {
        case S7TVExternalEmoteProviderBTTV: return @"BetterTTV";
        case S7TVExternalEmoteProviderFFZ: return @"FrankerFaceZ";
        case S7TVExternalEmoteProvider7TV:
        default: return @"7TV";
    }
}

static UIImage *S7TVExternalProviderLogo(S7TVExternalEmoteProvider provider) {
    NSString *base64 = nil;
    switch (provider) {
        case S7TVExternalEmoteProviderBTTV: base64 = kS7TVBTTVLogoBase64; break;
        case S7TVExternalEmoteProviderFFZ: base64 = kS7TVFFZLogoBase64; break;
        case S7TVExternalEmoteProvider7TV:
        default: base64 = kS7TVLogoBase64; break;
    }
    if (!base64.length) return nil;
    NSData *data = [[NSData alloc]
        initWithBase64EncodedString:base64
                             options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data.length) return nil;
    // Use each provider asset's native scale to normalize logo sizes.
    CGFloat logicalScale = provider == S7TVExternalEmoteProvider7TV ? 3.5 : 16.0;
    UIImage *image = [UIImage imageWithData:data scale:logicalScale];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static NSString *S7TVEnabledExternalProviderSummary(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSNumber *value in S7TVExternalProviderValues()) {
        S7TVExternalEmoteProvider provider = (S7TVExternalEmoteProvider)value.integerValue;
        if ([S7TVEmoteProviderSettings isProviderEnabled:provider])
            [names addObject:S7TVExternalProviderDisplayName(provider)];
    }
    return names.count > 0
        ? [names componentsJoinedByString:@" · "]
        : L(@"setting_emote_providers_none");
}

// Reusable multi-selection screen used by providers and chat elements.
@interface S7TVMultiSelectionOption : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, copy) BOOL (^isEnabled)(void);
@property (nonatomic, copy) void (^setEnabled)(BOOL enabled);
@end

@implementation S7TVMultiSelectionOption
@end

static NSArray<S7TVMultiSelectionOption *> *S7TVExternalProviderSelectionOptions(void) {
    NSMutableArray<S7TVMultiSelectionOption *> *options = [NSMutableArray arrayWithCapacity:3];
    for (NSNumber *value in S7TVExternalProviderValues()) {
        S7TVExternalEmoteProvider provider =
            (S7TVExternalEmoteProvider)value.integerValue;
        S7TVExternalEmoteProvider selectedProvider = provider;
        S7TVMultiSelectionOption *option = [S7TVMultiSelectionOption new];
        option.identifier = S7TVEmoteProviderIdentifier(provider);
        option.title = S7TVExternalProviderDisplayName(provider);
        option.image = S7TVExternalProviderLogo(provider);
        option.isEnabled = ^BOOL {
            return [S7TVEmoteProviderSettings isProviderEnabled:selectedProvider];
        };
        option.setEnabled = ^(BOOL enabled) {
            [S7TVEmoteProviderSettings setProvider:selectedProvider enabled:enabled];
        };
        [options addObject:option];
    }
    return options;
}

static NSArray<S7TVMultiSelectionOption *> *S7TVChatTopBannerSelectionOptions(void) {
    NSArray<NSDictionary *> *definitions = @[
        @{
            @"id": @"messages-and-announcements",
            @"title": L(@"chat_top_hide_messages_announcements"),
            @"image": @"pin.fill",
        },
        @{
            @"id": @"goals-and-leaderboard",
            @"title": L(@"chat_top_hide_goals_leaderboard"),
            @"image": @"list.number",
        },
    ];

    NSArray<BOOL (^)(void)> *readers = @[
        ^BOOL { return s7tv_hideChatMessagesAndAnnouncementsEnabled(); },
        ^BOOL { return s7tv_hideChatGoalsAndLeaderboardEnabled(); },
    ];
    NSArray<void (^)(BOOL)> *writers = @[
        ^(BOOL enabled) { s7tv_setHideChatMessagesAndAnnouncementsEnabled(enabled); },
        ^(BOOL enabled) { s7tv_setHideChatGoalsAndLeaderboardEnabled(enabled); },
    ];

    NSMutableArray<S7TVMultiSelectionOption *> *options =
        [NSMutableArray arrayWithCapacity:definitions.count];
    [definitions enumerateObjectsUsingBlock:^(NSDictionary *definition,
                                               NSUInteger index,
                                               BOOL *stop) {
        (void)stop;
        S7TVMultiSelectionOption *option = [S7TVMultiSelectionOption new];
        option.identifier = definition[@"id"];
        option.title = definition[@"title"];
        option.image = [UIImage systemImageNamed:definition[@"image"]];
        option.isEnabled = readers[index];
        option.setEnabled = writers[index];
        [options addObject:option];
    }];
    return options;
}

static NSString *S7TVEnabledChatTopBannerSummary(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (S7TVMultiSelectionOption *option in S7TVChatTopBannerSelectionOptions()) {
        if (option.isEnabled()) [names addObject:option.title];
    }
    return names.count > 0
        ? [names componentsJoinedByString:@" · "]
        : L(@"setting_chat_top_banners_none");
}

@interface S7TVMultiSelectionController : UITableViewController
@property (nonatomic, copy, nullable) void (^onFinish)(void);
- (instancetype)initWithTitle:(NSString *)title
                       options:(NSArray<S7TVMultiSelectionOption *> *)options;
@end

@interface S7TVMultiSelectionController ()
@property (nonatomic, copy) NSString *selectionTitle;
@property (nonatomic, copy) NSArray<S7TVMultiSelectionOption *> *options;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledByIdentifier;
@end

@implementation S7TVMultiSelectionController

- (instancetype)initWithTitle:(NSString *)title
                       options:(NSArray<S7TVMultiSelectionOption *> *)options {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _selectionTitle = [title copy];
        _options = [options copy];
        _enabledByIdentifier = [NSMutableDictionary dictionaryWithCapacity:options.count];
        for (S7TVMultiSelectionOption *option in _options) {
            _enabledByIdentifier[option.identifier] = @(option.isEnabled());
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.selectionTitle;
    S7TVStyleTableView(self.tableView);
    self.view.tintColor = S7TVAccent();
    self.tableView.tintColor = S7TVAccent();
    self.navigationController.navigationBar.tintColor = S7TVAccent();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(s7tv_cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(s7tv_finish)];
    S7TVRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
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
    S7TVMultiSelectionOption *option = self.options[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
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
    S7TVMultiSelectionOption *option = self.options[indexPath.row];
    BOOL enabled = [self.enabledByIdentifier[option.identifier] boolValue];
    self.enabledByIdentifier[option.identifier] = @(!enabled);
    [tableView reloadRowsAtIndexPaths:@[indexPath]
                     withRowAnimation:UITableViewRowAnimationNone];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)s7tv_cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)s7tv_finish {
    for (S7TVMultiSelectionOption *option in self.options) {
        BOOL oldValue = option.isEnabled();
        BOOL newValue = [self.enabledByIdentifier[option.identifier] boolValue];
        if (oldValue != newValue) option.setEnabled(newValue);
    }
    void (^finish)(void) = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:finish];
}

@end

@implementation SevenTVAppearancePageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_apparence");
    S7TVStyleTableView(self.tableView);
    S7TVRegisterOLEDObserver(self);
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Visible emote rows; legacy animation preferences remain compatible.
- (NSArray<NSNumber *> *)s7tv_visibleEmoteRows {
    return S7TVVisibleRowIndexes(@[
        @(S7TVAppearanceEmoteRowResolution),
        @(S7TVAppearanceEmoteRowPickerAnimations),
        @(S7TVAppearanceEmoteRowProviders),
        @(S7TVAppearanceEmoteRowProviderPriority),
        @(S7TVAppearanceEmoteRowPickerOpening),
        @(S7TVAppearanceEmoteRowMixedPicker),
    ], @{});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == S7TVAppearanceSectionIntro) return 1;
    if (s == S7TVAppearanceSectionEmotes) return [self s7tv_visibleEmoteRows].count;
    if (s == S7TVAppearanceSectionInterface) return 3;
    return 0;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return (s == S7TVAppearanceSectionIntro) ? 8 : 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (s == S7TVAppearanceSectionIntro) return [[UIView alloc] init];
    if (s == S7TVAppearanceSectionEmotes) return S7TVSectionHeader(L(@"section_emotes"), NO, nil);
    if (s == S7TVAppearanceSectionInterface) return S7TVSectionHeader(L(@"section_interface"), NO, nil);
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
    if (ip.section == S7TVAppearanceSectionIntro) {
        // Chat settings are available from the picker ("Aa").
        return S7TVDescriptionCell(@"desc_chat_custom_location");
    }
    if (ip.section == S7TVAppearanceSectionEmotes) {
        NSArray<NSNumber *> *visible = [self s7tv_visibleEmoteRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case S7TVAppearanceEmoteRowPickerAnimations:
                return S7TVNavCell(L(@"switch_animations_picker"),
                    S7TVValueWithDefaultMark(
                        S7TVPickerAnimationsModeTitle(
                            S7TVCurrentPickerAnimationsMode()),
                        S7TVCurrentPickerAnimationsMode() ==
                            S7TVPickerAnimationsModeEnabled),
                    @"sparkles", S7TVAccent(), nil);
            case S7TVAppearanceEmoteRowPickerOpening: {
                NSString *mode = [S7TVEmoteProviderSettings pickerOpeningMode];
                return S7TVNavCell(L(@"setting_emote_picker_opening"),
                    S7TVPickerOpeningModeTitle(mode),
                    @"rectangle.portrait.and.arrow.forward", S7TVAccent(), nil);
            }
            case S7TVAppearanceEmoteRowMixedPicker:
                return S7TVSwitchCell(L(@"setting_emote_picker_mixed"),
                    @"square.stack.3d.up.fill", UIColor.systemPurpleColor,
                    [S7TVEmoteProviderSettings mixedPickerEnabled],
                    self, @selector(toggleMixedPicker:), nil);
            case S7TVAppearanceEmoteRowProviders:
                return S7TVNavCell(L(@"setting_emote_providers"),
                    S7TVEnabledExternalProviderSummary(),
                    @"person.3.fill", S7TVAccent(), nil);
            case S7TVAppearanceEmoteRowProviderPriority: {
                NSArray *priority = [S7TVEmoteProviderSettings providerPriority];
                NSString *subtitle = [priority componentsJoinedByString:@" > "];
                return S7TVNavCell(L(@"setting_emote_provider_priority"), subtitle,
                    @"arrow.up.arrow.down.circle", S7TVAccent(), nil);
            }
            case S7TVAppearanceEmoteRowResolution:
            default: {
                // Use the standard choice sheet; details are behind the info button.
                NSInteger current = [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
                current = MIN(4, MAX(1, current));
                return S7TVNavCell(L(@"setting_emote_resolution"),
                    S7TVValueWithDefaultMark(
                        [NSString stringWithFormat:@"%ldx", (long)current],
                        current == kS7TVDefaultEmoteResolution),
                    @"photo.stack.fill", S7TVAccent(),
                    @"setting_resolution_clears_cache");
            }
        }
    }
    if (ip.section == S7TVAppearanceSectionInterface) {
        switch ((S7TVAppearanceInterfaceRow)ip.row) {
            case S7TVAppearanceInterfaceRowTheme:
                return S7TVSwitchCell(L(@"switch_oled_mode"),
                            @"circle.lefthalf.filled",
                            UIColor.systemIndigoColor,
                            S7TVOLEDModeEnabled(),
                            self, @selector(toggleOLEDMode:), @"desc_oled_mode");
            case S7TVAppearanceInterfaceRowTabBar:
                // Les deux réglages sont liés : ils se règlent sur l'écran dédié.
                return S7TVNavCell(L(@"section_tab_bar"), nil,
                    @"rectangle.split.3x1.fill", S7TVAccent(), @"desc_tab_bar");
            case S7TVAppearanceInterfaceRowChatBanners:
            default:
                return S7TVNavCell(L(@"setting_chat_top_banners"),
                    S7TVEnabledChatTopBannerSummary(),
                    @"rectangle.stack.fill", S7TVAccent(), nil);
        }
    }
    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == S7TVAppearanceSectionInterface) {
        if (ip.row == S7TVAppearanceInterfaceRowTabBar) {
            [self.navigationController pushViewController:
                [[SevenTVTabBarSettingsController alloc] init] animated:YES];
            return;
        }
        // Le mode OLED est un interrupteur : rien à ouvrir.
        if (ip.row != S7TVAppearanceInterfaceRowChatBanners) return;
        UITableViewCell *anchor = [tv cellForRowAtIndexPath:ip];
        S7TVMultiSelectionController *banners =
            [[S7TVMultiSelectionController alloc]
                initWithTitle:L(@"setting_chat_top_banners")
                       options:S7TVChatTopBannerSelectionOptions()];
        __weak typeof(self) weakSelf = self;
        banners.onFinish = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            S7TVReloadCellWithoutJump(strongSelf.tableView, anchor);
        };
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:banners];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:navigation animated:YES completion:nil];
        return;
    }
    if (ip.section != S7TVAppearanceSectionEmotes) return;
    NSArray<NSNumber *> *visible = [self s7tv_visibleEmoteRows];
    if (ip.row >= (NSInteger)visible.count) return;
    UITableViewCell *anchor = [tv cellForRowAtIndexPath:ip];
    if (visible[ip.row].integerValue == S7TVAppearanceEmoteRowPickerAnimations) {
        [self presentPickerAnimationsPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == S7TVAppearanceEmoteRowResolution) {
        [self presentResolutionPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == S7TVAppearanceEmoteRowProviders) {
        S7TVMultiSelectionController *providers =
            [[S7TVMultiSelectionController alloc]
                initWithTitle:L(@"setting_emote_providers")
                       options:S7TVExternalProviderSelectionOptions()];
        __weak typeof(self) weakSelf = self;
        providers.onFinish = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            S7TVReloadCellWithoutJump(strongSelf.tableView, anchor);
        };
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:providers];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:navigation animated:YES completion:nil];
    } else if (visible[ip.row].integerValue == S7TVAppearanceEmoteRowProviderPriority) {
        [self presentProviderPriorityPickerFromCell:anchor];
    } else if (visible[ip.row].integerValue == S7TVAppearanceEmoteRowPickerOpening) {
        [self presentPickerOpeningPickerFromCell:anchor];
    }
}

- (void)toggleOLEDMode:(UISwitch *)sw {
    BOOL changed = S7TVOLEDModeEnabled() != sw.isOn;
    S7TVOLEDModeSetEnabled(sw.isOn);
    if (!changed) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"oled_restart_title")
                         message:L(@"oled_restart_message")
                  preferredStyle:UIAlertControllerStyleAlert];
    alert.view.tintColor = S7TVAccent();
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentPickerAnimationsPickerFromCell:(UIView *)anchor {
    S7TVPickerAnimationsMode current = S7TVCurrentPickerAnimationsMode();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"switch_animations_picker")
                         message:L(@"picker_animations_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();

    NSArray<NSNumber *> *modes = @[
        @(S7TVPickerAnimationsModeDisabled),
        @(S7TVPickerAnimationsModeEnabled),
        @(S7TVPickerAnimationsModeFavoritesOnly),
    ];
    for (NSNumber *value in modes) {
        S7TVPickerAnimationsMode mode =
            (S7TVPickerAnimationsMode)value.integerValue;
        NSString *title = S7TVValueWithDefaultMark(
            S7TVPickerAnimationsModeTitle(mode),
            mode == S7TVPickerAnimationsModeEnabled);
        if (mode == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            SevenTVManager *manager = [SevenTVManager sharedManager];
            manager.showPickerAnimations =
                mode != S7TVPickerAnimationsModeDisabled;
            manager.showPickerAnimationsFavoritesOnly =
                mode == S7TVPickerAnimationsModeFavoritesOnly;
            S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)toggleMixedPicker:(UISwitch *)sw {
    [S7TVEmoteProviderSettings setMixedPickerEnabled:sw.isOn];
}

- (void)presentPickerOpeningPickerFromCell:(UIView *)anchor {
    NSString *current = [S7TVEmoteProviderSettings pickerOpeningMode];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_picker_opening")
                         message:L(@"setting_emote_picker_opening_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
    NSArray<NSArray<NSString *> *> *options = @[
        @[S7TVEmotePickerOpeningModeFavorites, L(@"picker_opening_favorites")],
        @[S7TVEmotePickerOpeningModeSevenTVChannel, L(@"picker_opening_7tv_channel")],
        @[S7TVEmotePickerOpeningModeBTTVChannel, L(@"picker_opening_bttv_channel")],
        @[S7TVEmotePickerOpeningModeFFZChannel, L(@"picker_opening_ffz_channel")],
        @[S7TVEmotePickerOpeningModeLastUsed, L(@"picker_opening_last_used")],
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
            [S7TVEmoteProviderSettings setPickerOpeningMode:mode];
            S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentProviderPriorityPickerFromCell:(UIView *)anchor {
    NSArray<NSString *> *current = [S7TVEmoteProviderSettings providerPriority];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_provider_priority")
                         message:L(@"setting_emote_provider_priority_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
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
            S7TVExternalEmoteProvider p = S7TVEmoteProviderFromIdentifier(identifier);
            [names addObject:labels[p]];
        }
        title = [names componentsJoinedByString:@" > "];
        if ([order isEqualToArray:current]) title = [title stringByAppendingString:@" ✓"];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                (void)action;
                [S7TVEmoteProviderSettings setProviderPriority:order];
                S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) {
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// Emote-resolution choice sheet; clear the cache when the value changes.
- (void)presentResolutionPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_resolution")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
        NSInteger current = [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
    current = MIN(4, MAX(1, current));
    for (NSInteger resolution = 1; resolution <= 4; resolution++) {
        NSString *title = [NSString stringWithFormat:@"%ldx", (long)resolution];
        if (resolution == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf s7tv_applyEmoteResolution:resolution anchor:anchor];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)s7tv_applyEmoteResolution:(NSInteger)resolution anchor:(UIView *)anchor {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    if (resolution == cfg.emoteImageResolution) return;

    // Persist through the shared setter so aliases and UI notifications stay in sync.
    [cfg setValue:(CGFloat)resolution forSizeKey:@"emoteImageResolution"];
    __weak typeof(self) weakSelf = self;
    [[SevenTVManager sharedManager] clearAllCachesWithCompletion:^(NSUInteger clearedCount) {
        (void)clearedCount;
        S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
    }];
}

@end



// MARK: - SevenTVContentPageController  (ex-Statistiques + ex-Contrôle du stream)
// Favorites, stream options and player settings.

typedef NS_ENUM(NSInteger, S7TVContentSection) {
    S7TVContentSectionFavorites = 0,  // Favorites and import
    S7TVContentSectionHome      = 1,  // Home, points and rotation
    S7TVContentSectionPlayer    = 2,  // Player and gestures
};

// Noms et icônes des onglets de la barre (une ligne par onglet, ordre réel).
static NSString *S7TVTabItemName(S7TVTabItem item) {
    switch (item) {
        case S7TVTabItemHome:     return L(@"tab_name_home");
        case S7TVTabItemExplore:  return L(@"tab_name_explore");
        case S7TVTabItemCreate:   return L(@"tab_name_create");
        case S7TVTabItemActivity: return L(@"tab_name_activity");
        case S7TVTabItemProfile:  return L(@"tab_name_profile");
    }
    return @"";
}

// Nom court de la sous-page d'une destination (« Live », « Catégories »…),
// nil pour les destinations qui n'en ont pas.
static NSString *S7TVTabPageTitle(S7TVLaunchDestination destination) {
    switch (destination) {
        case S7TVLaunchDestinationHomeFollowing:      return L(@"tab_page_following");
        case S7TVLaunchDestinationHomeLive:           return L(@"tab_page_live");
        case S7TVLaunchDestinationHomeClips:          return L(@"tab_page_clips");
        case S7TVLaunchDestinationBrowseCategories:   return L(@"tab_page_categories");
        case S7TVLaunchDestinationBrowseLiveChannels: return L(@"tab_page_live_channels");
        default:                                      return nil;
    }
}

static NSString *S7TVTabItemIcon(S7TVTabItem item) {
    switch (item) {
        case S7TVTabItemHome:     return @"house.fill";
        case S7TVTabItemExplore:  return @"safari.fill";
        case S7TVTabItemCreate:   return @"plus.circle.fill";
        case S7TVTabItemActivity: return @"bell.fill";
        case S7TVTabItemProfile:  return @"person.crop.circle.fill";
    }
    return @"circle.fill";
}

// Couleur propre à chaque onglet ; un onglet masqué reste gris.
static UIColor *S7TVTabItemColor(S7TVTabItem item) {
    switch (item) {
        case S7TVTabItemHome:     return S7TVAccent();                                             // violet Twitch
        case S7TVTabItemExplore:  return [UIColor colorWithRed:0.30 green:0.62 blue:1.00 alpha:1.0]; // bleu
        case S7TVTabItemCreate:   return [UIColor colorWithRed:0.30 green:0.75 blue:0.45 alpha:1.0]; // vert
        case S7TVTabItemActivity: return [UIColor colorWithRed:0.95 green:0.35 blue:0.50 alpha:1.0]; // rose
        case S7TVTabItemProfile:  return [UIColor colorWithRed:0.25 green:0.70 blue:0.95 alpha:1.0]; // cyan
    }
    return S7TVAccent();
}

// La ligne « Défaut » n'est pas un onglet : elle porte la couleur du tweak.
static UIColor *S7TVTabItemColorDefaultRow(void) {
    return S7TVAccent();
}

// L'onglet visé par une destination de lancement est-il masqué ? Dans cet état,
// la destination ne peut pas être honorée au démarrage.
static BOOL S7TVLaunchDestinationTabHidden(S7TVLaunchDestination destination) {
    NSInteger tab = s7tv_launchDestinationTab(destination);
    return tab >= 0 && s7tv_tabItemHidden((S7TVTabItem)tab);
}

// Destination par défaut d'un onglet : sert de repli quand l'onglet choisi
// comme écran de lancement vient d'être masqué.
static S7TVLaunchDestination S7TVDefaultDestinationForTab(S7TVTabItem item) {
    switch (item) {
        case S7TVTabItemHome:     return S7TVLaunchDestinationHomeFollowing;
        case S7TVTabItemExplore:  return S7TVLaunchDestinationBrowseCategories;
        case S7TVTabItemActivity: return S7TVLaunchDestinationActivity;
        case S7TVTabItemProfile:  return S7TVLaunchDestinationProfile;
        case S7TVTabItemCreate:   break;
    }
    return S7TVLaunchDestinationDefault;
}

// Repli : l'onglet visible le plus proche du masqué, en commençant par le
// voisin de gauche (le plus proche dans l'ordre de la barre).
static S7TVLaunchDestination S7TVNearestVisibleDestination(S7TVTabItem item) {
    for (NSInteger delta = 1; delta < S7TV_TAB_ITEM_COUNT; delta++) {
        NSInteger before = (NSInteger)item - delta;
        if (before >= 0 && !s7tv_tabItemHidden((S7TVTabItem)before)) {
            S7TVLaunchDestination destination =
                S7TVDefaultDestinationForTab((S7TVTabItem)before);
            if (destination != S7TVLaunchDestinationDefault) return destination;
        }
        NSInteger after = (NSInteger)item + delta;
        if (after < S7TV_TAB_ITEM_COUNT && !s7tv_tabItemHidden((S7TVTabItem)after)) {
            S7TVLaunchDestination destination =
                S7TVDefaultDestinationForTab((S7TVTabItem)after);
            if (destination != S7TVLaunchDestinationDefault) return destination;
        }
    }
    return S7TVLaunchDestinationDefault;
}

// Rows for the Home and Playback section. L'écran de lancement est réglé dans la
// section de la barre d'onglets, avec laquelle il est lié.
typedef NS_ENUM(NSInteger, S7TVContentHomeRow) {
    S7TVContentHomeRowHideStories    = 0,
    S7TVContentHomeRowKeepLiveFeed   = 1,
    S7TVContentHomeRowAutoCollect    = 2,
};

typedef NS_ENUM(NSInteger, S7TVContentPlayerRow) {
    S7TVContentPlayerRowDelay = 0,
    S7TVContentPlayerRowStats = 1,
    S7TVContentPlayerRowLockButton = 2,
    S7TVContentPlayerRowGestures = 3,
    S7TVContentPlayerRowLeftSide = 4,
    S7TVContentPlayerRowRightSide = 5,
    S7TVContentPlayerRowSensitivity = 6,
    S7TVContentPlayerRowDeadZone = 7,
};

static NSString *S7TVPlayerGestureAssignmentTitle(
    S7TVPlayerGestureAssignment assignment) {
    switch (assignment) {
        case S7TVPlayerGestureAssignmentVolume:
            return L(@"player_gestures_assignment_volume");
        case S7TVPlayerGestureAssignmentBrightness:
            return L(@"player_gestures_assignment_brightness");
        case S7TVPlayerGestureAssignmentDisabled:
        default:
            return L(@"player_gestures_assignment_disabled");
    }
}

// Maps the four display modes to the two legacy runtime preferences.
typedef NS_ENUM(NSInteger, S7TVOrientationLockSetting) {
    S7TVOrientationLockSettingDisabled = 0,
    S7TVOrientationLockSettingManual,
    S7TVOrientationLockSettingAutoLeft,
    S7TVOrientationLockSettingAutoRight,
    S7TVOrientationLockSettingAutoBoth,
};

static NSString *S7TVLaunchDestinationTitle(S7TVLaunchDestination destination) {
    switch (destination) {
        case S7TVLaunchDestinationHomeFollowing:      return L(@"launch_home_following");
        case S7TVLaunchDestinationHomeLive:           return L(@"launch_home_live");
        case S7TVLaunchDestinationHomeClips:          return L(@"launch_home_clips");
        case S7TVLaunchDestinationBrowseCategories:   return L(@"launch_browse_categories");
        case S7TVLaunchDestinationBrowseLiveChannels: return L(@"launch_browse_live_channels");
        case S7TVLaunchDestinationActivity:            return L(@"launch_activity");
        case S7TVLaunchDestinationProfile:             return L(@"launch_profile");
        case S7TVLaunchDestinationDefault:             return L(@"launch_default");
    }
    return L(@"launch_default");
}

static S7TVOrientationLockSetting S7TVCurrentOrientationLockSetting(void) {
    if (!s7tv_orientationLockButtonEnabled()) {
        return S7TVOrientationLockSettingDisabled;
    }
    switch (s7tv_autoOrientationLockMode()) {
        case S7TVAutoOrientationLockModeLandscapeLeft:
            return S7TVOrientationLockSettingAutoLeft;
        case S7TVAutoOrientationLockModeLandscapeRight:
            return S7TVOrientationLockSettingAutoRight;
        case S7TVAutoOrientationLockModeBothLandscapes:
            return S7TVOrientationLockSettingAutoBoth;
        case S7TVAutoOrientationLockModeDisabled:
        default:
            return S7TVOrientationLockSettingManual;
    }
}

static NSString *S7TVOrientationLockSettingTitle(S7TVOrientationLockSetting setting) {
    switch (setting) {
        case S7TVOrientationLockSettingManual:
            return L(@"orientation_mode_manual");
        case S7TVOrientationLockSettingAutoLeft:
            return L(@"orientation_mode_auto_left");
        case S7TVOrientationLockSettingAutoRight:
            return L(@"orientation_mode_auto_right");
        case S7TVOrientationLockSettingAutoBoth:
            return L(@"orientation_mode_auto_both");
        case S7TVOrientationLockSettingDisabled:
        default:
            return L(@"orientation_mode_disabled");
    }
}

static NSString *const kS7TVPCFavoritesKey = @"ui.emote_menu.favorites";

// Supports known 7TV PC export nesting without relying on a format number.
static NSArray *S7TVFindPCFavoritesArray(id object, NSUInteger depth) {
    if (depth > 24) return nil;

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        id directValue = dictionary[kS7TVPCFavoritesKey];
        if ([directValue isKindOfClass:NSArray.class]) return directValue;

        for (id value in dictionary.allValues) {
            NSArray *candidate = S7TVFindPCFavoritesArray(value, depth + 1);
            if (candidate) return candidate;
        }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            NSArray *candidate = S7TVFindPCFavoritesArray(value, depth + 1);
            if (candidate) return candidate;
        }
    }
    return nil;
}

static NSArray *S7TVPCFavoritesArrayFromJSON(id json) {
    if ([json isKindOfClass:NSArray.class]) return json;
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *root = (NSDictionary *)json;

    // Current format: { "scopes": { "global": { ... } } }.
    NSDictionary *scopes = [root[@"scopes"] isKindOfClass:NSDictionary.class]
        ? root[@"scopes"] : nil;
    NSDictionary *global = [scopes[@"global"] isKindOfClass:NSDictionary.class]
        ? scopes[@"global"] : nil;
    id favorites = global[kS7TVPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    // Previous known formats.
    NSDictionary *settings = [root[@"settings"] isKindOfClass:NSDictionary.class]
        ? root[@"settings"] : nil;
    favorites = settings[kS7TVPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    favorites = root[kS7TVPCFavoritesKey];
    if ([favorites isKindOfClass:NSArray.class]) return favorites;

    // Bounded fallback for future nesting changes.
    return S7TVFindPCFavoritesArray(root, 0);
}

static NSArray<NSString *> *S7TVSevenTVIDsFromPCFavorites(NSArray *rawFavorites) {
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

@interface SevenTVContentPageController () <UIDocumentPickerDelegate>
- (void)presentOrientationLockSettingPickerFromCell:(UIView *)anchor;
- (void)presentPlayerGestureAssignmentPickerFromCell:(UIView *)anchor
                                                side:(BOOL)leftSide;
- (void)presentPlayerGestureDeadZonePickerFromCell:(UIView *)anchor;
- (void)playerGestureSensitivityDecrease:(UIButton *)button;
- (void)playerGestureSensitivityIncrease:(UIButton *)button;
- (void)togglePlayerTools:(UISwitch *)sw;
- (void)togglePlayerStats:(UISwitch *)sw;
@end

@implementation SevenTVContentPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_contenu");
    S7TVStyleTableView(self.tableView);
    S7TVRegisterOLEDObserver(self);
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(s7tv_autoClaimRuntimeStateDidChange:)
            name:S7TVAutoClaimRuntimeStateDidChangeNotification object:nil];
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)s7tv_autoClaimRuntimeStateDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded || !self.view.window) return;
    [S7TVInfoTooltip dismiss];
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
    [S7TVInfoTooltip dismiss];
}

// Visible Home and Playback rows.
- (NSArray<NSNumber *> *)s7tv_visibleHomeRows {
    return S7TVVisibleRowIndexes(@[
        @(S7TVContentHomeRowHideStories),
        @(S7TVContentHomeRowKeepLiveFeed),
        @(S7TVContentHomeRowAutoCollect),
    ], @{});
}

- (NSArray<NSNumber *> *)s7tv_visiblePlayerRows {
    return S7TVVisibleRowIndexes(@[
        @(S7TVContentPlayerRowDelay),
        @(S7TVContentPlayerRowLockButton),
        @(S7TVContentPlayerRowGestures),
    ], @{
        @(S7TVContentPlayerRowStats): @(s7tv_playerToolsEnabled()),
        @(S7TVContentPlayerRowLeftSide): @(s7tv_playerGesturesEnabled()),
        @(S7TVContentPlayerRowRightSide): @(s7tv_playerGesturesEnabled()),
        @(S7TVContentPlayerRowSensitivity): @(s7tv_playerGesturesEnabled()),
        @(S7TVContentPlayerRowDeadZone): @(s7tv_playerGesturesEnabled()),
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == S7TVContentSectionFavorites) return 1;
    if (s == S7TVContentSectionHome) return [self s7tv_visibleHomeRows].count;
    if (s == S7TVContentSectionPlayer) return [self s7tv_visiblePlayerRows].count;
    return 0;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    // Favorites row: title and export subtitle.
    if (ip.section == S7TVContentSectionFavorites) return 60;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVContentSectionFavorites: return S7TVSectionHeader(L(@"section_favoris"), NO, nil);
        // Section details are available from the header info button.
        case S7TVContentSectionHome:      return S7TVSectionHeader(L(@"section_home_playback"), NO,
                                              @"desc_home_playback_settings");
        case S7TVContentSectionPlayer:    return S7TVSectionHeader(L(@"section_player_controls"), NO, nil);
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

    if (ip.section == S7TVContentSectionHome) {
        NSArray<NSNumber *> *visible = [self s7tv_visibleHomeRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case S7TVContentHomeRowHideStories:
                return S7TVSwitchCell(L(@"switch_hide_twitch_stories"),
                    @"circle.slash", [UIColor colorWithRed:0.95 green:0.35 blue:0.50 alpha:1.0],
                    s7tv_hideTwitchStoriesEnabled(), self, @selector(toggleHideTwitchStories:), nil);
            case S7TVContentHomeRowKeepLiveFeed:
                return S7TVSwitchCell(L(@"switch_keep_live_feed_playing"),
                    @"play.circle.fill", [UIColor colorWithRed:0.30 green:0.75 blue:0.45 alpha:1.0],
                    s7tv_keepLiveFeedPlayingEnabled(), self, @selector(toggleKeepLiveFeedPlaying:), nil);
            case S7TVContentHomeRowAutoCollect:
                return S7TVSwitchCell(
                    L(@"switch_auto_collect_title"),
                    @"giftcard.fill",
                    [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0],
                    S7TVBoolDefaultYes(kTCLiveAutoCollectChannelPoints),
                    self,
                    @selector(toggleAutoCollect:),
                    nil);
        }
        return [[UITableViewCell alloc] init];
    }

    if (ip.section == S7TVContentSectionPlayer) {
        NSArray<NSNumber *> *visible = [self s7tv_visiblePlayerRows];
        if (ip.row >= (NSInteger)visible.count) return [[UITableViewCell alloc] init];
        switch (visible[ip.row].integerValue) {
            case S7TVContentPlayerRowDelay:
                return S7TVSwitchCell(L(@"player_tools_enable"),
                    @"clock.arrow.circlepath", S7TVAccent(),
                    s7tv_playerToolsEnabled(), self,
                    @selector(togglePlayerTools:), @"desc_player_tools");
            case S7TVContentPlayerRowStats:
                return S7TVSwitchCell(L(@"player_stats_enable"),
                    @"chart.bar.xaxis", S7TVAccent(),
                    s7tv_playerStatsEnabled(), self,
                    @selector(togglePlayerStats:), @"desc_player_stats");
            case S7TVContentPlayerRowLockButton: {
                S7TVOrientationLockSetting setting = S7TVCurrentOrientationLockSetting();
                return S7TVNavCell(L(@"switch_orientation_lock_button"),
                    S7TVValueWithDefaultMark(S7TVOrientationLockSettingTitle(setting),
                        setting == S7TVOrientationLockSettingDisabled),
                    @"lock.rotation", S7TVAccent(), @"desc_orientation_lock_settings");
            }
            case S7TVContentPlayerRowGestures:
                return S7TVSwitchCell(L(@"player_gestures_enable"),
                    @"arrow.up.and.down.circle.fill", S7TVAccent(),
                    s7tv_playerGesturesEnabled(), self,
                    @selector(togglePlayerGestures:), @"desc_player_gestures");
            case S7TVContentPlayerRowLeftSide: {
                S7TVPlayerGestureAssignment assignment =
                    s7tv_playerGesturesLeftAssignment();
                return S7TVRightValueNavCell(L(@"player_gestures_left_side"),
                    S7TVPlayerGestureAssignmentTitle(assignment),
                    @"arrow.left.circle.fill", S7TVAccent());
            }
            case S7TVContentPlayerRowRightSide: {
                S7TVPlayerGestureAssignment assignment =
                    s7tv_playerGesturesRightAssignment();
                return S7TVRightValueNavCell(L(@"player_gestures_right_side"),
                    S7TVPlayerGestureAssignmentTitle(assignment),
                    @"arrow.right.circle.fill", S7TVAccent());
            }
            case S7TVContentPlayerRowSensitivity:
                return S7TVPlayerGestureSensitivityCell(
                    s7tv_playerGesturesSensitivity(), self);
            case S7TVContentPlayerRowDeadZone:
                return S7TVNavCell(L(@"player_gestures_dead_zone"),
                    S7TVValueWithDefaultMark(
                        [NSString stringWithFormat:@"%ld%%",
                         (long)s7tv_playerGesturesDeadZone()],
                        s7tv_playerGesturesDeadZone() == 20),
                    @"circle", S7TVAccent(), nil);
        }
        return [[UITableViewCell alloc] init];
    }

    // Favorites section: list, count and integrated import.
    NSArray *favs = [[S7TVEmoteCatalog sharedCatalog] favoriteKeysSnapshot];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    UIView *icon = S7TVFavoriteEmotePreview(favs);
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
    subLbl.textColor = S7TVGray();
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
    if (ip.section == S7TVContentSectionFavorites && ip.row == 0) {
        SevenTVFavoritesListController *favsVC = [[SevenTVFavoritesListController alloc] init];
        [self.navigationController pushViewController:favsVC animated:YES];
        return;
    }
    UITableViewCell *anchor = [tv cellForRowAtIndexPath:ip];
    if (ip.section == S7TVContentSectionPlayer) {
        NSArray<NSNumber *> *visible = [self s7tv_visiblePlayerRows];
        if (ip.row >= (NSInteger)visible.count) return;
        NSInteger logicalRow = visible[ip.row].integerValue;
        if (logicalRow == S7TVContentPlayerRowLockButton) {
            [self presentOrientationLockSettingPickerFromCell:anchor];
            return;
        }
        if (logicalRow == S7TVContentPlayerRowLeftSide) {
            [self presentPlayerGestureAssignmentPickerFromCell:anchor side:YES];
            return;
        }
        if (logicalRow == S7TVContentPlayerRowRightSide) {
            [self presentPlayerGestureAssignmentPickerFromCell:anchor side:NO];
            return;
        }
        if (logicalRow == S7TVContentPlayerRowDeadZone) {
            [self presentPlayerGestureDeadZonePickerFromCell:anchor];
        }
        return;
    }
}

- (void)toggleAutoCollect:(UISwitch *)sw {
    S7TVSetBool(kTCLiveAutoCollectChannelPoints, sw.isOn);
    S7TVAutoClaimSettingsDidChange();
}
- (void)toggleHideTwitchStories:(UISwitch *)sw {
    s7tv_setHideTwitchStoriesEnabled(sw.isOn);
}
- (void)toggleKeepLiveFeedPlaying:(UISwitch *)sw {
    s7tv_setKeepLiveFeedPlayingEnabled(sw.isOn);
}

- (void)togglePlayerGestures:(UISwitch *)sw {
    s7tv_setPlayerGesturesEnabled(sw.isOn);
    S7TVReloadSectionWithoutJump(self.tableView, S7TVContentSectionPlayer);
}

- (void)togglePlayerTools:(UISwitch *)sw {
    s7tv_setPlayerToolsEnabled(sw.isOn);
    S7TVReloadSectionWithoutJump(self.tableView, S7TVContentSectionPlayer);
}

- (void)togglePlayerStats:(UISwitch *)sw {
    s7tv_setPlayerStatsEnabled(sw.isOn);
}

- (void)presentPlayerGestureAssignmentPickerFromCell:(UIView *)anchor
                                                side:(BOOL)leftSide {
    S7TVPlayerGestureAssignment current = leftSide
        ? s7tv_playerGesturesLeftAssignment()
        : s7tv_playerGesturesRightAssignment();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(leftSide
            ? L(@"player_gestures_left_side")
            : L(@"player_gestures_right_side"))
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();

    NSArray<NSNumber *> *assignments = @[
        @(S7TVPlayerGestureAssignmentDisabled),
        @(S7TVPlayerGestureAssignmentVolume),
        @(S7TVPlayerGestureAssignmentBrightness),
    ];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *rawAssignment in assignments) {
        S7TVPlayerGestureAssignment assignment =
            (S7TVPlayerGestureAssignment)rawAssignment.integerValue;
        NSString *title = S7TVPlayerGestureAssignmentTitle(assignment);
        if (assignment == current) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (leftSide) {
                s7tv_setPlayerGesturesLeftAssignment(assignment);
            } else {
                s7tv_setPlayerGesturesRightAssignment(assignment);
            }
            S7TVReloadSectionWithoutJump(self.tableView,
                                         S7TVContentSectionPlayer);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)playerGestureSensitivityDecrease:(UIButton *)button {
    CGFloat value = MAX(1.0, s7tv_playerGesturesSensitivity() - 1.0);
    s7tv_setPlayerGesturesSensitivity(value);
    UILabel *valueLabel = objc_getAssociatedObject(
        button, &kS7TVPlayerGestureSensitivityValueLabelKey);
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
}

- (void)playerGestureSensitivityIncrease:(UIButton *)button {
    CGFloat value = MIN(5.0, s7tv_playerGesturesSensitivity() + 1.0);
    s7tv_setPlayerGesturesSensitivity(value);
    UILabel *valueLabel = objc_getAssociatedObject(
        button, &kS7TVPlayerGestureSensitivityValueLabelKey);
    valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value];
}

- (void)presentPlayerGestureDeadZonePickerFromCell:(UIView *)anchor {
    NSInteger current = s7tv_playerGesturesDeadZone();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"player_gestures_dead_zone")
                         message:L(@"player_gestures_dead_zone_message")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();

    for (NSInteger value = 0; value <= 100; value += 10) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value];
        if (value == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            s7tv_setPlayerGesturesDeadZone(value);
            S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Orientation-lock choice sheet; apply immediately and refresh the row.
- (void)presentOrientationLockSettingPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"switch_orientation_lock_button")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
    S7TVOrientationLockSetting current = S7TVCurrentOrientationLockSetting();
    NSArray<NSNumber *> *settings = @[
        @(S7TVOrientationLockSettingDisabled),
        @(S7TVOrientationLockSettingManual),
        @(S7TVOrientationLockSettingAutoLeft),
        @(S7TVOrientationLockSettingAutoRight),
        @(S7TVOrientationLockSettingAutoBoth),
    ];
    for (NSNumber *value in settings) {
        S7TVOrientationLockSetting setting = (S7TVOrientationLockSetting)value.integerValue;
        NSString *title = S7TVOrientationLockSettingTitle(setting);
        if (setting == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            S7TVAutoOrientationLockMode mode = S7TVAutoOrientationLockModeDisabled;
            switch (setting) {
                case S7TVOrientationLockSettingAutoLeft:
                    mode = S7TVAutoOrientationLockModeLandscapeLeft;
                    break;
                case S7TVOrientationLockSettingAutoRight:
                    mode = S7TVAutoOrientationLockModeLandscapeRight;
                    break;
                case S7TVOrientationLockSettingAutoBoth:
                    mode = S7TVAutoOrientationLockModeBothLandscapes;
                    break;
                case S7TVOrientationLockSettingDisabled:
                case S7TVOrientationLockSettingManual:
                default:
                    mode = S7TVAutoOrientationLockModeDisabled;
                    break;
            }
            s7tv_setAutoOrientationLockMode(mode);
            s7tv_setOrientationLockButtonEnabled(
                setting != S7TVOrientationLockSettingDisabled);
            S7TVReloadCellWithoutJump(weakSelf.tableView, anchor);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
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
        [self s7tv_showAlert:L(@"alert_error_title")
                     message:L(@"error_cant_read_file")];
        return;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!json) {
        [self s7tv_showAlert:L(@"alert_invalid_format_title")
                     message:L(@"error_invalid_json")];
        return;
    }

    NSArray *rawFavs = S7TVPCFavoritesArrayFromJSON(json);

    if (!rawFavs) {
        [self s7tv_showAlert:L(@"alert_unknown_format_title")
                     message:L(@"error_missing_favorites_key")];
        return;
    }

    // Keep 7TV IDs and ignore PLATFORM entries.
    NSArray<NSString *> *newIDs = S7TVSevenTVIDsFromPCFavorites(rawFavs);

    if (newIDs.count == 0) {
        [self s7tv_showAlert:L(@"alert_no_7tv_favorites_title")
                     message:L(@"error_no_favorites_in_file")];
        return;
    }

    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSArray<NSString *> *existing = [manager favoriteEmoteIDsSnapshot];
    NSMutableOrderedSet<NSString *> *merged =
        [NSMutableOrderedSet orderedSetWithArray:existing];
    NSUInteger beforeCount = merged.count;
    [merged addObjectsFromArray:newIDs];
    [manager replaceFavoriteEmoteIDs:merged.array];

    NSUInteger added = merged.count - beforeCount;
    NSUInteger skipped = newIDs.count - added;
    [self.tableView reloadData];
    [self s7tv_showAlert:[NSString stringWithFormat:L(@"alert_import_success_title_format"), (unsigned long)added]
                 message:[NSString stringWithFormat:
                          L(@"alert_import_success_message_format"),
                          (unsigned long)added,
                          (unsigned long)skipped]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { }

- (void)s7tv_showAlert:(NSString *)title message:(NSString *)msg {
    S7TVShowAlert(self, title, msg);
}
@end// Ligne de l'écran barre d'onglets : radio (écran de lancement) et interrupteur
// (onglet visible) sur la même ligne. `tabIndex` < 0 décrit « Défaut ». Création
// n'a pas de radio : aucune destination de lancement ne la vise. `subPageTitle`
// ajoute une seconde ligne optionnelle (sous-page ouverte, ou « masqué »).
static UITableViewCell *S7TVTabOptionCell(NSInteger tabIndex,
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
                                    : S7TVCellBg();

    UIImageView *radio = nil;
    if (tabIndex != S7TVTabItemCreate) {
        UIImageSymbolConfiguration *radioCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        radio = [[UIImageView alloc] initWithImage:[UIImage
            systemImageNamed:(isLaunch ? @"largecircle.fill.circle" : @"circle")
            withConfiguration:radioCfg]];
        radio.tintColor = isLaunch ? S7TVAccent() : S7TVGray();
        radio.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:radio];
    }

    UIImageView *icon = nil;
    if (sfName.length) {
        UIColor *tint = tabIndex >= 0 ? S7TVTabItemColor((S7TVTabItem)tabIndex)
                                      : S7TVTabItemColorDefaultRow();
        icon = S7TVIcon(sfName, isVisible ? tint : S7TVGray());
        [cell.contentView addSubview:icon];
    }

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    // Match native settings typography.
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = isVisible ? [UIColor whiteColor] : S7TVGray();
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = nil;
    if (tabIndex >= 0) {
        sw = [[UISwitch alloc] init];
        sw.on          = isVisible;
        sw.onTintColor = S7TVAccent();
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
            UIColor *subColor = S7TVAccent();
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
            note.textColor = S7TVGray();
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

// MARK: - SevenTVTabBarSettingsController
// Masquage des onglets de la barre principale et écran de lancement. Les deux
// réglages sont liés : une destination dont l'onglet est masqué ne peut pas être
// honorée. Ils partagent donc un même écran, atteint par une seule ligne dans le
// menu Contenu.

// Deux sections : l'explication permanente, puis les réglages eux-mêmes.
typedef NS_ENUM(NSInteger, S7TVTabBarSettingsSection) {
    S7TVTabBarSettingsSectionIntro = 0,
    S7TVTabBarSettingsSectionOptions = 1,
};

typedef NS_ENUM(NSInteger, S7TVTabBarSettingsRow) {
    S7TVTabBarSettingsRowDefault = 0,   // « Défaut » : aucun onglet imposé
    S7TVTabBarSettingsRowFirstTab,      // puis un onglet par ligne, ordre réel
};

@implementation SevenTVTabBarSettingsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"section_tab_bar");
    S7TVStyleTableView(self.tableView);
    S7TVRegisterOLEDObserver(self);
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == S7TVTabBarSettingsSectionIntro) return 1;
    return S7TVTabBarSettingsRowFirstTab + S7TV_TAB_ITEM_COUNT;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return (s == S7TVTabBarSettingsSectionIntro) ? 8 : 34;
}

// Annonce les deux colonnes : radio (départ) à gauche, interrupteur (visible)
// à droite.
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    if (s == S7TVTabBarSettingsSectionIntro) return [[UIView alloc] init];

    UILabel *launch = [[UILabel alloc] init];
    launch.text = L(@"tab_bar_header_launch").uppercaseString;
    UILabel *visible = [[UILabel alloc] init];
    visible.text = L(@"tab_bar_header_visible").uppercaseString;
    for (UILabel *lbl in @[launch, visible]) {
        lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        // En-têtes de colonnes à la couleur du tweak.
        lbl.textColor = S7TVAccent();
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
    S7TVLaunchDestination destination = s7tv_launchDestination();
    NSInteger launchTab = s7tv_launchDestinationTab(destination);

    if (ip.section == S7TVTabBarSettingsSectionIntro) {
        return S7TVDescriptionCell(@"desc_tab_bar");
    }

    if (ip.row == S7TVTabBarSettingsRowDefault) {
        return S7TVTabOptionCell(-1, L(@"launch_default"), @"star.fill", nil,
            launchTab < 0, YES, self, nil, NULL);
    }

    NSInteger tabRow = ip.row - S7TVTabBarSettingsRowFirstTab;
    if (tabRow < 0 || tabRow >= S7TV_TAB_ITEM_COUNT) {
        return [[UITableViewCell alloc] init];
    }
    S7TVTabItem item = (S7TVTabItem)tabRow;
    BOOL isVisible = !s7tv_tabItemHidden(item);
    BOOL isLaunch = launchTab == tabRow && !S7TVLaunchDestinationTabHidden(destination);

    // L'onglet de départ affiche la sous-page qu'il ouvrira. Un onglet masqué
    // n'affiche rien, sauf s'il est la destination (cas d'un import de réglages).
    NSString *subPage = nil;
    SEL subPageAction = NULL;
    if (isLaunch) {
        subPage = S7TVTabPageTitle(destination);
        subPageAction = @selector(openTabPagePicker:);
    } else if (!isVisible && launchTab == tabRow) {
        subPage = L(@"tab_hidden_badge");
    }

    return S7TVTabOptionCell(tabRow, S7TVTabItemName(item), S7TVTabItemIcon(item),
        subPage, isLaunch, isVisible, self,
        @selector(toggleTabSwitch:), subPageAction);
}

- (NSIndexPath *)tableView:(UITableView *)tv willSelectRowAtIndexPath:(NSIndexPath *)ip {
    // Le test porte sur la SECTION : la première ligne des réglages porte aussi
    // le numéro 0, et elle doit rester sélectionnable.
    if (ip.section == S7TVTabBarSettingsSectionIntro) return nil;
    if (ip.row == S7TVTabBarSettingsRowDefault) return ip;
    NSInteger tabRow = ip.row - S7TVTabBarSettingsRowFirstTab;
    if (tabRow < 0 || tabRow >= S7TV_TAB_ITEM_COUNT) return nil;
    // Création (feuille de composition) et les onglets masqués ne peuvent pas
    // être l'écran de lancement : leur ligne est inerte.
    if (tabRow == S7TVTabItemCreate) return nil;
    return s7tv_tabItemHidden((S7TVTabItem)tabRow) ? nil : ip;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != S7TVTabBarSettingsSectionOptions) return;
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger tabRow = ip.row - S7TVTabBarSettingsRowFirstTab;
    [self s7tv_setLaunchTab:ip.row == S7TVTabBarSettingsRowDefault ? -1 : tabRow];
}

// La radio fixe l'écran de lancement ; la sous-page déjà réglée est conservée.
- (void)s7tv_setLaunchTab:(NSInteger)tab {
    if (tab < 0) {
        s7tv_setLaunchDestination(S7TVLaunchDestinationDefault);
    } else {
        S7TVLaunchDestination current = s7tv_launchDestination();
        s7tv_setLaunchDestination(s7tv_launchDestinationTab(current) == tab
            ? current
            : S7TVDefaultDestinationForTab((S7TVTabItem)tab));
    }
    S7TVReloadSectionWithoutJump(self.tableView, S7TVTabBarSettingsSectionOptions);
}

// Choix de la sous-page ouverte par l'onglet de départ.
- (void)openTabPagePicker:(UIControl *)control {
    S7TVTabItem item = (S7TVTabItem)control.tag;
    NSArray<NSNumber *> *options = nil;
    if (item == S7TVTabItemHome) {
        options = @[@(S7TVLaunchDestinationHomeFollowing),
                    @(S7TVLaunchDestinationHomeLive),
                    @(S7TVLaunchDestinationHomeClips)];
    } else if (item == S7TVTabItemExplore) {
        options = @[@(S7TVLaunchDestinationBrowseCategories),
                    @(S7TVLaunchDestinationBrowseLiveChannels)];
    }
    if (!options.count) return;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:S7TVTabItemName(item)
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
    S7TVLaunchDestination current = s7tv_launchDestination();
    for (NSNumber *raw in options) {
        S7TVLaunchDestination destination = (S7TVLaunchDestination)raw.integerValue;
        NSString *title = S7TVTabPageTitle(destination);
        if (destination == current) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            s7tv_setLaunchDestination(destination);
            S7TVReloadSectionWithoutJump(self.tableView, S7TVTabBarSettingsSectionOptions);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = control;
    sheet.popoverPresentationController.sourceRect = control.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// ── Onglets ───────────────────────────────────────────

// L'interrupteur porte la visibilité : allumé = onglet visible.
- (void)s7tv_applyTabSwitch:(UISwitch *)sw forItem:(S7TVTabItem)item {
    BOOL hide = !sw.isOn;
    if (hide && s7tv_tabVisibleCount() <= 1) {
        sw.on = YES;
        S7TVShowAlert(self, L(@"section_tab_bar"), L(@"alert_tab_bar_min_message"));
        return;
    }
    s7tv_setTabItemHidden(item, hide);
    // La destination suit le masquage au lieu de retomber ailleurs en silence.
    if (hide &&
        s7tv_launchDestinationTab(s7tv_launchDestination()) == (NSInteger)item) {
        S7TVLaunchDestination replacement = S7TVNearestVisibleDestination(item);
        s7tv_setLaunchDestination(replacement);
        S7TVShowAlert(self, L(@"setting_launch_screen"),
            [NSString stringWithFormat:L(@"alert_launch_destination_moved"),
             S7TVLaunchDestinationTitle(replacement)]);
    }
    // La barre ne rejoue pas son layout tant que cet écran est présenté.
    s7tv_tabVisibilityApplyNow();
    // Le repère de départ, la mention « masqué » et les sous-pages ont pu bouger.
    S7TVReloadSectionWithoutJump(self.tableView, S7TVTabBarSettingsSectionOptions);
}

- (void)toggleTabSwitch:(UISwitch *)sw {
    [self s7tv_applyTabSwitch:sw forItem:(S7TVTabItem)sw.tag];
}

@end



// MARK: - SevenTVFavoritesListController

// Favorite emotes with provider-qualified keys and resolved names.

@interface SevenTVFavoritesListController ()
- (void)s7tv_scheduleFavoriteNameCacheSave;
- (void)s7tv_scheduleFavoriteNameRowsReload;
- (void)s7tv_resolveMissingFavoriteNames;
- (void)s7tv_catalogDidUpdate:(NSNotification *)notification;
@end

@implementation SevenTVFavoritesListController {
    NSArray<NSString *> *_favKeys;     // Provider-qualified keys.
    NSDictionary<NSString *, S7TVEmoteDescriptor *> *_keyToDescriptor;
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
    S7TVStyleTableView(self.tableView);
    S7TVRegisterOLEDObserver(self);
    NSDictionary *savedNames = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kS7TVFavoriteEmoteNamesKey] ?: @{};
    _favoriteNameCache = [savedNames mutableCopy];
    _nameFetchesInFlight = [NSMutableSet set];
    NSURLSessionConfiguration *nameConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    nameConfig.HTTPMaximumConnectionsPerHost = 4;
    nameConfig.timeoutIntervalForRequest = 15.0;
    _favoriteNameSession = [NSURLSession sessionWithConfiguration:nameConfig];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(s7tv_catalogDidUpdate:)
                                                 name:S7TVProviderCatalogDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(s7tv_catalogDidUpdate:)
                                                 name:S7TVFavoritesDidChangeNotification
                                               object:nil];
    [[S7TVEmoteCatalog sharedCatalog] loadGlobalProviders];
    NSString *channelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    if (channelID.length)
        [[S7TVEmoteCatalog sharedCatalog] loadChannelProvidersForTwitchID:channelID];
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

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFavs];
}

- (void)s7tv_catalogDidUpdate:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isViewLoaded) [self reloadFavs];
    });
}

- (void)reloadFavs {
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    _favKeys = [[catalog favoriteKeysSnapshot] copy];

    // Start with persisted names; imported favorites may be offline or channel-specific.
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *descriptorMap = [NSMutableDictionary dictionary];
    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        for (S7TVEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(S7TVEmoteProviderID)provider]) {
            NSString *key = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (key.length) descriptorMap[key] = descriptor;
        }
    }
    // Merge provider metadata so offline or other-channel favorites keep their names and URLs.
    for (S7TVEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        NSString *key = S7TVEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
        if (!key.length) continue;
        descriptorMap[key] = descriptor;
    }
    for (NSString *rawFavoriteKey in _favKeys) {
        NSString *favoriteKey = S7TVSettingsCanonicalFavoriteKey(rawFavoriteKey);
        if (!favoriteKey.length) continue;
        S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
        NSString *emoteID = nil;
        BOOL valid = S7TVSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
        if (!valid) continue;
        NSString *qualifiedKey = S7TVEmoteFavoriteKey(provider, emoteID);
        S7TVEmoteDescriptor *descriptor = descriptorMap[qualifiedKey];
        if (descriptor) {
            descriptorMap[qualifiedKey] = descriptor;
            map[qualifiedKey] = descriptor.name;
        }
        if (valid && provider == S7TVEmoteProviderIDSevenTV) {
            NSString *cachedName = _favoriteNameCache[emoteID] ?:
                _favoriteNameCache[qualifiedKey] ?: _favoriteNameCache[rawFavoriteKey];
            if (cachedName.length) map[qualifiedKey] = cachedName;
        }
    }

    _keyToDescriptor = descriptorMap.copy;
    _idToName = [map copy];
    [_favoriteNameCache addEntriesFromDictionary:map];
    [self s7tv_scheduleFavoriteNameCacheSave];

    [self.tableView reloadData];
    [self s7tv_resolveMissingFavoriteNames];
}

- (void)s7tv_scheduleFavoriteNameCacheSave {
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
               forKey:kS7TVFavoriteEmoteNamesKey];
    });
}

- (void)s7tv_scheduleFavoriteNameRowsReload {
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

- (void)s7tv_resolveMissingFavoriteNames {
    for (NSString *rawFavoriteKey in _favKeys) {
        NSString *favoriteKey = S7TVSettingsCanonicalFavoriteKey(rawFavoriteKey);
        if (!favoriteKey.length) continue;
        S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
        NSString *emoteID = nil;
        if (!S7TVSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID) ||
            provider != S7TVEmoteProviderIDSevenTV) continue;
        if (_idToName[favoriteKey].length || [_nameFetchesInFlight containsObject:favoriteKey]) continue;
        [_nameFetchesInFlight addObject:favoriteKey];

        NSString *escapedID = [emoteID stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emotes/%@",
                                          S7TV_API_BASE, escapedID ?: emoteID]];
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
                [strongSelf s7tv_scheduleFavoriteNameCacheSave];
                [strongSelf s7tv_scheduleFavoriteNameRowsReload];
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
    return S7TVSectionHeader(title, NO, nil);
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
        cell.backgroundColor = S7TVCellBg();
        cell.textLabel.text  = L(@"empty_no_favorites");
        cell.textLabel.textColor = S7TVGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }

    NSString *favoriteKey = S7TVSettingsCanonicalFavoriteKey(_favKeys[ip.row]);
    if (!favoriteKey.length) favoriteKey = @"7tv:unknown";
    S7TVEmoteDescriptor *descriptor = _keyToDescriptor[favoriteKey];
    S7TVEmoteProviderID provider = S7TVEmoteProviderIDSevenTV;
    NSString *emoteID = nil;
    BOOL validKey = S7TVSettingsParseFavoriteKey(favoriteKey, &provider, &emoteID);
    if (!validKey) {
        provider = S7TVEmoteProviderIDSevenTV;
        emoteID = favoriteKey;
        favoriteKey = S7TVEmoteFavoriteKey(S7TVEmoteProviderIDSevenTV, emoteID);
        descriptor = _keyToDescriptor[favoriteKey];
    }
    NSString *name = descriptor.name ?: _idToName[favoriteKey];
    NSString *providerName = descriptor.providerName ?: S7TVEmoteProviderName(provider);

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    // Emote image, using URLCache when available.
    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.contentMode = UIViewContentModeScaleAspectFit;
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.clipsToBounds = YES;
    [cell.contentView addSubview:thumb];

    if (descriptor) S7TVLoadSettingsCatalogEmoteImage(descriptor, thumb);
    else if (provider == S7TVEmoteProviderIDSevenTV) S7TVLoadSettingsEmoteImage(emoteID, thumb);

    // Labels.
    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name.length ? name : providerName;
    nameLbl.font = [UIFont systemFontOfSize:15 weight:
        name.length ? UIFontWeightRegular : UIFontWeightLight];
    nameLbl.textColor = name.length ? [UIColor whiteColor] : S7TVGray();
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
    idLbl.textColor = S7TVGray();
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
    if (!S7TVSettingsParseFavoriteKey(removedKey, NULL, NULL)) return;
    [[S7TVEmoteCatalog sharedCatalog] setFavoriteKey:removedKey favorited:NO];
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
            S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
            for (NSString *favoriteKey in self->_favKeys) {
                if (S7TVSettingsParseFavoriteKey(favoriteKey, NULL, NULL))
                    [catalog setFavoriteKey:favoriteKey favorited:NO];
            }
            [self reloadFavs];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end



// MARK: - S7TVHookDiagnosticsController
// Reports whether targeted classes and selectors resolve in this Twitch build.

@interface S7TVHookDiagnosticsController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *items;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *providerItems;
@property (nonatomic, strong) S7TVAutoClaimDiagnosticsState *autoClaimState;
@end

@implementation S7TVHookDiagnosticsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"diagnostics_title");
    S7TVStyleTableView(self.tableView);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(s7tv_providerDiagnosticsDidUpdate:)
                   name:S7TVProviderCatalogDidUpdateNotification object:nil];
    [center addObserver:self
               selector:@selector(s7tv_providerDiagnosticsDidUpdate:)
                   name:S7TVEmoteProviderSettingsDidChangeNotification object:nil];
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
    self.items = S7TVHookDiagnosticItems();
    self.providerItems = S7TVEmoteProviderDiagnosticItems();
    self.autoClaimState = S7TVAutoClaimDiagnosticsCurrentState();
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)s7tv_providerDiagnosticsDidUpdate:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf s7tv_providerDiagnosticsDidUpdate:nil];
        });
        return;
    }
    if (!self.isViewLoaded || !self.view.window) return;
    [self reloadDiagnostics];
}

- (NSArray<NSString *> *)s7tv_autoClaimDiagnosticTitles {
    return @[
        L(@"diagnostics_autoclaim_chat_controller"),
        L(@"diagnostics_autoclaim_native_chain"),
        L(@"diagnostics_autoclaim_shows_claim"),
        L(@"diagnostics_autoclaim_selector"),
        L(@"diagnostics_autoclaim_balance"),
        L(@"diagnostics_autoclaim_watcher"),
        L(@"diagnostics_autoclaim_effective_state"),
    ];
}

- (NSArray<NSString *> *)s7tv_autoClaimDiagnosticValues {
    S7TVAutoClaimDiagnosticsState *state = self.autoClaimState;
    NSString *(^yesNo)(BOOL) = ^NSString *(BOOL value) {
        return L(value ? @"diagnostics_autoclaim_yes"
                       : @"diagnostics_autoclaim_no");
    };

    NSString *effectiveState = nil;
    switch (state.effectiveState) {
        case S7TVAutoClaimEffectiveStateActive:
            effectiveState = L(@"diagnostics_autoclaim_state_active");
            break;
        case S7TVAutoClaimEffectiveStateDisabledByUser:
        default:
            effectiveState = L(@"diagnostics_autoclaim_state_disabled");
            break;
    }

    return @[
        yesNo(state.channelChatViewControllerDetected),
        yesNo(state.nativeChainResolved),
        yesNo(state.showsClaimAvailable),
        yesNo(state.claimSelectorAvailable),
        yesNo(state.balanceAvailable),
        yesNo(state.watcherActive),
        effectiveState,
    ];
}

- (UITableViewCell *)s7tv_autoClaimDiagnosticCellForRow:(NSInteger)row
                                               tableView:(UITableView *)tableView {
    static NSString *reuseIdentifier = @"S7TVAutoClaimDiagnosticCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSArray<NSString *> *titles = [self s7tv_autoClaimDiagnosticTitles];
    NSArray<NSString *> *values = [self s7tv_autoClaimDiagnosticValues];
    if (row < 0 || row >= (NSInteger)titles.count || row >= (NSInteger)values.count) {
        return cell;
    }

    cell.backgroundColor = S7TVCellBg();
    cell.textLabel.text = titles[row];
    cell.textLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = values[row];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    cell.detailTextLabel.numberOfLines = 0;

    UIColor *valueColor = S7TVGray();
    if (row < 6) {
        BOOL available = NO;
        switch (row) {
            case 0: available = self.autoClaimState.channelChatViewControllerDetected; break;
            case 1: available = self.autoClaimState.nativeChainResolved; break;
            case 2: available = self.autoClaimState.showsClaimAvailable; break;
            case 3: available = self.autoClaimState.claimSelectorAvailable; break;
            case 4: available = self.autoClaimState.balanceAvailable; break;
            case 5: available = self.autoClaimState.watcherActive; break;
        }
        valueColor = available ? UIColor.systemGreenColor : UIColor.systemRedColor;
    } else if (row == 6) {
        switch (self.autoClaimState.effectiveState) {
            case S7TVAutoClaimEffectiveStateActive:
                valueColor = UIColor.systemGreenColor;
                break;
            case S7TVAutoClaimEffectiveStateDisabledByUser:
            default:
                valueColor = UIColor.systemGrayColor;
                break;
        }
    }
    cell.detailTextLabel.textColor = valueColor;
    return cell;
}

- (NSArray<NSDictionary<NSString *, id> *> *)s7tv_itemsForGroup:(NSInteger)group {
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

- (NSArray<NSDictionary<NSString *, id> *> *)s7tv_emoteProviderItems {
    return self.providerItems ?: @[];
}

- (NSDictionary<NSString *, id> *)s7tv_itemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *providerItems = [self s7tv_emoteProviderItems];
        return indexPath.row < (NSInteger)providerItems.count
            ? providerItems[indexPath.row] : nil;
    }
    NSArray<NSDictionary<NSString *, id> *> *groupItems =
        [self s7tv_itemsForGroup:indexPath.section];
    return indexPath.row < (NSInteger)groupItems.count ? groupItems[indexPath.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [self s7tv_emoteProviderItems].count;
    if (section == 3) return 7;
    return [self s7tv_itemsForGroup:section].count;
}

- (UITableViewCell *)s7tv_emoteProviderDiagnosticCellForRow:(NSInteger)row
                                                   tableView:(UITableView *)tableView {
    static NSString *reuseIdentifier = @"S7TVEmoteProviderDiagnosticCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSArray<NSDictionary<NSString *, id> *> *providerItems =
        [self s7tv_emoteProviderItems];
    if (row < 0 || row >= (NSInteger)providerItems.count) return cell;
    NSDictionary<NSString *, id> *item = providerItems[row];
    BOOL enabled = [item[@"enabled"] boolValue];
    S7TVEmoteProviderState state =
        (S7TVEmoteProviderState)[item[@"state"] integerValue];
    NSUInteger count = [item[@"count"] unsignedIntegerValue];
    NSString *status = nil;
    UIColor *statusColor = UIColor.systemGrayColor;

    if (!enabled) {
        status = L(@"diagnostics_inactive");
    } else {
        switch (state) {
            case S7TVEmoteProviderStateLoading:
                status = L(@"diagnostics_api_loading");
                statusColor = UIColor.systemOrangeColor;
                break;
            case S7TVEmoteProviderStateLoaded:
                status = [NSString stringWithFormat:
                    L(@"diagnostics_api_ok_count"), (long)count];
                statusColor = UIColor.systemGreenColor;
                break;
            case S7TVEmoteProviderStateError: {
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
            case S7TVEmoteProviderStateIdle:
            default:
                status = L(@"diagnostics_api_not_loaded");
                statusColor = UIColor.systemGrayColor;
                break;
        }
    }

    cell.backgroundColor = S7TVCellBg();
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
        return [self s7tv_emoteProviderDiagnosticCellForRow:indexPath.row
                                                   tableView:tableView];
    }
    if (indexPath.section == 3) {
        return [self s7tv_autoClaimDiagnosticCellForRow:indexPath.row
                                              tableView:tableView];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"S7TVHookDiagnosticCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"S7TVHookDiagnosticCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = S7TVCellBg();
    NSDictionary<NSString *, id> *item = [self s7tv_itemAtIndexPath:indexPath];
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


// MARK: - SevenTVAdvancedPageController  (ex-SevenTVDebugPageController)
// Diagnostics, cache, options and settings transfer.

// Returns all image URLs known by the shared provider-aware catalogue.
static NSArray<NSURL *> *S7TVAdvancedKnownEmoteImageURLs(void) {
    S7TVEmoteCatalog *catalog = [S7TVEmoteCatalog sharedCatalog];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^appendDescriptor)(S7TVEmoteDescriptor *) = ^(S7TVEmoteDescriptor *descriptor) {
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
                [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution];
            NSString *key = url.absoluteString;
            if (key.length && ![seen containsObject:key]) {
                [seen addObject:key];
                [urls addObject:url];
            }
        }
    };

    for (NSInteger provider = S7TVEmoteProviderIDSevenTV;
         provider <= S7TVEmoteProviderIDFFZ; provider++) {
        for (S7TVEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(S7TVEmoteProviderID)provider]) {
            appendDescriptor(descriptor);
        }
    }
    for (S7TVEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        appendDescriptor(descriptor);
    }
    return urls.copy;
}

@interface SevenTVAdvancedPageController () <UIDocumentPickerDelegate>
- (void)s7tv_exportSettingsFromAnchor:(UIView *)anchor;
- (void)s7tv_importSettingsFromFile;
- (void)s7tv_importSettingsAtURL:(NSURL *)url;
- (void)s7tv_applyImportedSettingsWithLegacyFavorites:(BOOL)hasLegacyFavorites;
- (void)s7tv_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message;
@property (nonatomic, assign) NSInteger displayedCachedEmoteCount;
@end

@implementation SevenTVAdvancedPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_avance");
    self.displayedCachedEmoteCount = [SevenTVURLProtocol cachedEmoteCount];
    S7TVStyleTableView(self.tableView);
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(s7tv_cacheCountDidChange:)
        name:S7TVEmoteCacheCountDidChangeNotification object:nil];
    S7TVRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)s7tv_cacheCountDidChange:(NSNotification *)notification {
    if (!self.isViewLoaded || !self.view.window) return;
    NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:0];
    [self.tableView reloadRowsAtIndexPaths:@[cacheRow]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.displayedCachedEmoteCount = [SevenTVURLProtocol cachedEmoteCount];
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
    [SevenTVURLProtocol refreshCachedEmoteCountWithCompletion:^(NSInteger count) {
        applyCount(count);

        // Backfill older cache entries without replacing known identities.
        NSArray<NSURL *> *knownImageURLs = S7TVAdvancedKnownEmoteImageURLs();
        if (knownImageURLs.count) {
            [SevenTVURLProtocol refreshCachedEmoteCountForImageURLs:knownImageURLs
                                                          completion:applyCount];
        }
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

// Sections: Tools, Transfer, Options and Logs.
#define S7TV_SECTION_TOOLS        0
#define S7TV_SECTION_TRANSFER     1
#define S7TV_SECTION_OPTIONS      2
#define S7TV_SECTION_LOGS         3

#define S7TV_TOOLS_ROW_CACHE       0
#define S7TV_TOOLS_ROW_DIAGNOSTICS 1

// Log-section rows.
typedef NS_ENUM(NSInteger, S7TVLogsRow) {
    S7TVLogsRowEnable   = 0,
    S7TVLogsRowView     = 1,
    S7TVLogsRowConsole  = 2,
    S7TVLogsRowFirstCat = 3,
};

#define S7TV_LOGS_CAT_COUNT       3

// Log detail rows are visible only when logging is enabled.
- (NSArray<NSNumber *> *)s7tv_visibleLogsRows {
    BOOL logsOn = [SevenTVManager sharedManager].logsEnabled;
    NSMutableDictionary<NSNumber *, NSNumber *> *conditional = [NSMutableDictionary dictionary];
    conditional[@(S7TVLogsRowView)]    = @(logsOn);
    conditional[@(S7TVLogsRowConsole)] = @(logsOn);
    for (NSInteger cat = 0; cat < S7TV_LOGS_CAT_COUNT; cat++) {
        conditional[@(S7TVLogsRowFirstCat + cat)] = @(logsOn);
    }
    return S7TVVisibleRowIndexes(@[@(S7TVLogsRowEnable)], conditional);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TV_SECTION_TOOLS:    return 2;
        case S7TV_SECTION_TRANSFER: return 2;
        case S7TV_SECTION_OPTIONS:  return 2;
        case S7TV_SECTION_LOGS:     return [self s7tv_visibleLogsRows].count + 4; /* + bloc Diagnostics VAFT */
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TV_SECTION_TOOLS:    return S7TVSectionHeader(L(@"section_tools"), NO, nil);
        case S7TV_SECTION_TRANSFER: return S7TVSectionHeader(L(@"section_settings_backup"), NO, nil);
        case S7TV_SECTION_OPTIONS:  return S7TVSectionHeader(L(@"section_options"), NO, nil);
        case S7TV_SECTION_LOGS:     return S7TVSectionHeader(L(@"section_logs"), NO, nil);
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
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // Tools: clear cache and hook diagnostics.
    if (ip.section == S7TV_SECTION_TOOLS) {
        if (ip.row == S7TV_TOOLS_ROW_DIAGNOSTICS) {
            return S7TVNavCell(L(@"diagnostics_title"), L(@"diagnostics_subtitle"),
                @"stethoscope", UIColor.systemPinkColor, nil);
        }

        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = S7TVCellBg();
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.06];
        UIImageView *icon = S7TVIcon(@"trash.circle",
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
        NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution;
        resolution = MIN(4, MAX(1, resolution));
        NSInteger cachedCount = self.displayedCachedEmoteCount >= 0
            ? self.displayedCachedEmoteCount
            : [SevenTVURLProtocol cachedEmoteCount];
        countLbl.text = [NSString stringWithFormat:L(@"cache_emote_count_format"),
                         (long)cachedCount, (long)resolution];
        countLbl.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        countLbl.textColor = S7TVGray();
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

    if (ip.section == S7TV_SECTION_OPTIONS) {
        if (ip.row == 0) {
        return S7TVSwitchCell(L(@"switch_chat_custom"),
                    @"message.badge.filled.fill",
                    S7TVAccent(),
                    mgr.chatCustomTestEnabled,
                    self, @selector(toggleChatCustom:), @"chat_custom_info");
        }
        return S7TVSwitchCell(L(@"switch_floating_button"),
                    @"circle.grid.2x1.fill",
                    UIColor.systemOrangeColor,
                    mgr.showFloatingButton,
                    self, @selector(toggleFloatingButton:), nil);
    }

    if (ip.section == S7TV_SECTION_TRANSFER) {
        if (ip.row == 0) {
        return S7TVNavCell(L(@"settings_export"), L(@"settings_export_subtitle"),
            @"square.and.arrow.up", S7TVAccent(), nil);
        }
        return S7TVNavCell(L(@"settings_import"), L(@"settings_import_subtitle"),
            @"square.and.arrow.down", UIColor.systemGreenColor, nil);
    }

    if (ip.section == S7TV_SECTION_LOGS) {
        NSArray<NSNumber *> *visible = [self s7tv_visibleLogsRows];
        NSInteger visibleCount = (NSInteger)visible.count;

        // VAFT diagnostics are independent of TwitchPlusK logs and AdBlock.
        if (ip.row >= visibleCount) {
            switch (ip.row - visibleCount) {
                case 0:
                    return S7TVSwitchCell(L(@"vaft_diag_logging"),
                                @"record.circle",
                                UIColor.systemTealColor,
                                tas_diagnostics_logging_enabled(),
                                self, @selector(toggleVaftDiagnosticLogging:), nil);
                case 1:
                    return S7TVNavCell(L(@"vaft_diag_view"),
                                L(@"vaft_diag_view_sub"),
                                @"doc.plaintext", UIColor.systemBlueColor, nil);
                case 2: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                    cell.backgroundColor = S7TVCellBg();
                    cell.selectedBackgroundView = [[UIView alloc] init];
                    cell.selectedBackgroundView.backgroundColor =
                        [UIColor colorWithWhite:1.0 alpha:0.06];
                    UIImageView *icon = S7TVIcon(@"doc.on.doc", S7TVAccent());
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
                    sub.textColor = S7TVGray();
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
                    cell.backgroundColor = S7TVCellBg();
                    cell.selectedBackgroundView = [[UIView alloc] init];
                    cell.selectedBackgroundView.backgroundColor =
                        [UIColor colorWithWhite:1.0 alpha:0.06];
                    UIImageView *icon = S7TVIcon(@"trash", UIColor.systemRedColor);
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
        if (row == S7TVLogsRowEnable) {
            return S7TVSwitchCell(L(@"switch_enable_logs"),
                        @"bolt.fill",
                        UIColor.systemYellowColor,
                        mgr.logsEnabled,
                        self, @selector(toggleLogsEnabled:), nil);
        }

        // View logs when logging is enabled.
        if (row == S7TVLogsRowView) {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
            cell.backgroundColor = S7TVCellBg();
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.selectedBackgroundView.backgroundColor =
                [UIColor colorWithWhite:1.0 alpha:0.06];

            UIImageView *icon = S7TVIcon(@"doc.text.magnifyingglass",
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
            badge.textColor = S7TVGray();
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
        if (row == S7TVLogsRowConsole) {
            return S7TVSwitchCell(L(@"switch_logs_console"),
                        @"terminal.fill",
                        UIColor.systemGreenColor,
                        mgr.debugLogging,
                        self, @selector(toggleDebug:), nil);
        }

        // Log categories.
        NSInteger catIdx = row - S7TVLogsRowFirstCat;
        NSArray<NSString *> *titles = @[
            L(@"log_cat_errors"), L(@"log_cat_chat_custom"),
            L(@"log_cat_channel_points"),
        ];
        NSArray<NSString *> *icons = @[
            @"exclamationmark.triangle.fill", @"hammer.fill", @"gift.fill",
        ];
        // Couleurs correspondantes.
        NSArray<UIColor *> *colors = @[
            UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemYellowColor,
        ];
        NSArray<NSNumber *> *values = @[
            @(mgr.logErrors), @(mgr.logChatCustom), @(mgr.logChannelPoints),
        ];
        NSArray *selectors = @[
            @"toggleLogErrors:", @"toggleLogChatCustom:", @"toggleLogChannelPoints:",
        ];

        UITableViewCell *cell = S7TVSwitchCell(titles[catIdx],
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

    if (ip.section == S7TV_SECTION_TOOLS) {
        if (ip.row == S7TV_TOOLS_ROW_CACHE) [self clearCache];
        else [self.navigationController pushViewController:[S7TVHookDiagnosticsController new]
                                                 animated:YES];
        return;
    }

    if (ip.section == S7TV_SECTION_TRANSFER) {
        if (ip.row == 0) [self s7tv_exportSettingsFromAnchor:[tv cellForRowAtIndexPath:ip]];
        else [self s7tv_importSettingsFromFile];
        return;
    }

    if (ip.section == S7TV_SECTION_LOGS) {
        NSArray<NSNumber *> *visible = [self s7tv_visibleLogsRows];
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
                    [self s7tv_showVaftDiagNotice:L(@"vaft_diag_copied_title")
                                          message:L(@"vaft_diag_copied_msg")];
                    return;
                }
                case 3: {
                    tas_perform_clear_diagnostic_log();
                    [tv reloadData];
                    [self s7tv_showVaftDiagNotice:L(@"vaft_diag_cleared_title")
                                          message:L(@"vaft_diag_cleared_msg")];
                    return;
                }
                default: return;
            }
        }

        NSInteger row = visible[ip.row].integerValue;
        if (row == S7TVLogsRowView) {
            // Log clearing is handled by this screen.
            [self.navigationController
                pushViewController:[[SevenTVLogsController alloc] init] animated:YES];
        }
        return;
    }
}

// Clears the 7TV disk/memory/badge cache and reloads emotes.
- (void)clearCache {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
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
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

// Settings export/import.

- (void)s7tv_exportSettingsFromAnchor:(UIView *)anchor {
    NSError *error = nil;
    NSData *data = S7TVSettingsExportData(&error);
    if (!data) {
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_export_failed_title")
                                              message:L(@"settings_export_failed_message")];
        return;
    }

    NSURL *directoryURL = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *fileURL = [directoryURL URLByAppendingPathComponent:S7TVSettingsExportFileName()];
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_export_failed_title")
                                              message:L(@"settings_export_failed_message")];
        return;
    }

    UIActivityViewController *sheet = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    UIView *source = anchor ?: self.view;
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)s7tv_importSettingsFromFile {
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
    if (url) [self s7tv_importSettingsAtURL:url];
}

- (void)s7tv_importSettingsAtURL:(NSURL *)url {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data) {
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_import_failed_title")
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
            values[@"s7tv_favorites"] != nil;
    }

    NSUInteger importedCount = S7TVSettingsImportData(data, &error);
    if (importedCount == NSNotFound) {
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_import_failed_title")
                                              message:L(@"settings_import_invalid_file")];
        return;
    }

    [self s7tv_applyImportedSettingsWithLegacyFavorites:hasLegacyFavorites];
    [self.tableView reloadData];
    [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_import_success_title")
                                          message:[NSString stringWithFormat:
                                              L(@"settings_import_success_message_format"),
                                              (unsigned long)importedCount]];
}

- (void)s7tv_applyImportedSettingsWithLegacyFavorites:(BOOL)hasLegacyFavorites {
    // Reload singleton preferences without rewriting the imported backup.
    [[SevenTVManager sharedManager] reloadPreferencesFromDefaults];
    // Replace only the legacy 7TV slice; keep BTTV/FFZ favorites untouched.
    if (hasLegacyFavorites) {
        [[S7TVEmoteCatalog sharedCatalog]
            replaceLegacySevenTVFavoriteIDs:
                [SevenTVManager sharedManager].favoriteEmoteIDsSnapshot];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVProviderCatalogDidUpdateNotification
                      object:[S7TVEmoteCatalog sharedCatalog]
                    userInfo:@{@"favorites": @YES}];
    // Normalize multi-provider settings and apply the v1 migration after import.
    [S7TVEmoteProviderSettings migrateLegacySettings];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVEmoteProviderSettingsDidChangeNotification object:nil];

    SevenTVChatAppearanceConfig *chatConfig = [SevenTVChatAppearanceConfig sharedConfig];
    [chatConfig reloadFromDefaults];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVChatAppearanceConfigDidChangeNotification object:chatConfig];
    S7TVOLEDModeReloadFromDefaults();

    NSInteger language = [NSUserDefaults.standardUserDefaults integerForKey:@"s7tv_language"];
    if (language != S7TVLanguageFrench) language = S7TVLanguageEnglish;
    [S7TVLocalization shared].currentLanguage = (S7TVLanguage)language;
    self.title = L(@"title_avance");

    // Use setters to refresh the rotation observer and existing player button.
    s7tv_setOrientationLockButtonEnabled(s7tv_orientationLockButtonEnabled());
    s7tv_setAutoOrientationLockMode(s7tv_autoOrientationLockMode());

    // Refresh the AdBlock configured snapshot; the active method stays fixed until restart.
    S7TVAdblockRefreshRuntimeSnapshots();

    // A configured/active mismatch requires a Twitch restart; hooks are unchanged here.
    if (S7TVAdblockConfiguredMethod() != S7TVAdblockActiveMethod()) {
        S7TVAdblockMethod configured = S7TVAdblockConfiguredMethod();
        NSString *message;
        switch (configured) {
            case S7TVAdblockMethodLocalVaft:
                message = L(@"adblock_restart_local_msg"); break;
            case S7TVAdblockMethodDisabled:
                message = L(@"adblock_restart_disabled_msg"); break;
            case S7TVAdblockMethodProxy:
            default:
                message = L(@"adblock_restart_proxy_msg"); break;
        }
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"adblock_restart_title")
                                              message:message];
    }
}

- (void)s7tv_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                               style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleLogsEnabled:(UISwitch *)sw {
    [SevenTVManager sharedManager].logsEnabled = sw.isOn;
    // Refresh dependent log rows.
    S7TVReloadSection(self.tableView, S7TV_SECTION_LOGS);
}

// VAFT diagnostics use the separate TASDiagnostics engine.

- (void)toggleVaftDiagnosticLogging:(UISwitch *)sw {
    tas_diagnostics_set_logging_enabled(sw.isOn);
}

- (void)s7tv_showVaftDiagNotice:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)toggleDebug:(UISwitch *)sw                  { [SevenTVManager sharedManager].debugLogging        = sw.isOn; }
- (void)toggleChatCustom:(UISwitch *)sw             { [SevenTVManager sharedManager].chatCustomTestEnabled = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw         { [SevenTVManager sharedManager].showFloatingButton  = sw.isOn; }

- (void)toggleLogErrors:(UISwitch *)sw           { [SevenTVManager sharedManager].logErrors           = sw.isOn; }
- (void)toggleLogChatCustom:(UISwitch *)sw       { [SevenTVManager sharedManager].logChatCustom       = sw.isOn; }
- (void)toggleLogChannelPoints:(UISwitch *)sw    { [SevenTVManager sharedManager].logChannelPoints    = sw.isOn; }

@end
