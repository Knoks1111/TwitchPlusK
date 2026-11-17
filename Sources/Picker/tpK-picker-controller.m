// Extrait de tpK-core-manager.m : picker 7TV indépendant du picker Twitch.

#import "Picker/tpK-picker-controller.h"
#import "Core/tpK-core-manager.h"
#import "Settings/tpK-settings-controller.h"
#import "Localization/tpK-localization-manager.h"
#import "Picker/tpK-picker-resolved-emote.h"
#import "Picker/tpK-picker-cell.h"
#import "Settings/tpK-chat-appearance-config.h"
#import "Picker/tpK-picker-channel-avatar.h"
#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-catalog.h"
#import "Picker/tpK-picker-settings.h"
#import "Emote/tpK-emote-animation-engine.h"
#import "UI/7tv-ui-logo.h"
#import "UI/tpK-ui-logo.h"
#import "UI/bttv-ui-logo.h"
#import "UI/ffz-ui-logo.h"
#import "UI/tpK-oled-mode.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const char kTPKPickerHostAssociation = 5;
static __weak UIView *tpk_pickerChatButtonNative = nil;
static __weak UIView *tpk_pickerChatButtonEmote = nil;
static __weak UIButton *tpk_pickerChatButtonReplacement = nil;

static UIImage *TPKPickerScaledProviderLogo(UIImage *image, CGFloat pointSize);
static UIImage *TPKPickerAspectFitProviderLogo(UIImage *image, CGFloat maxWidth, CGFloat maxHeight);

// Décode les logos en arrière-plan avant la première ouverture.
static UIImage *s_tpkPickerTabLogo = nil;
static UIImage *s_tpkPickerBTTVLogo = nil;
static UIImage *s_tpkPickerFFZLogo = nil;
static UIImage *s_tpkPickerTPKLogo = nil;

static void tpk_pickerPrewarmProviderLogos(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *tabData = [[NSData alloc]
                initWithBase64EncodedString:kTPKLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            s_tpkPickerTabLogo = [[UIImage imageWithData:tabData scale:3.0]
                imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            NSData *bttvData = [[NSData alloc]
                initWithBase64EncodedString:kTPKBTTVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *bttvImg = [[UIImage imageWithData:bttvData scale:3.0]
                imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            s_tpkPickerBTTVLogo = TPKPickerScaledProviderLogo(bttvImg, 16.0);
            NSData *ffzData = [[NSData alloc]
                initWithBase64EncodedString:kTPKFFZLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *ffzImg = [[UIImage imageWithData:ffzData scale:3.0]
                imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            s_tpkPickerFFZLogo = TPKPickerScaledProviderLogo(ffzImg, 16.0);
            NSData *tpkData = [[NSData alloc]
                initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
            s_tpkPickerTPKLogo = TPKPickerAspectFitProviderLogo(
                [UIImage imageWithData:tpkData scale:UIScreen.mainScreen.scale], 22.0, 14.0);
        });
    });
}

static UIImage *tpk_pickerLogoImage(CGFloat targetHeight) {
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *icon = [UIImage imageWithData:logoData scale:1.0];
    if (!icon) return nil;
    if (targetHeight < 12.0) targetHeight = 18.0;
    CGFloat targetWidth = targetHeight * (icon.size.width / MAX(icon.size.height, 1.0));
    UIGraphicsBeginImageContextWithOptions(
        CGSizeMake(targetWidth, targetHeight), NO, UIScreen.mainScreen.scale);
    [icon drawInRect:CGRectMake(0, 0, targetWidth, targetHeight)];
    UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedIcon ?: icon;
}

// ── Palette du picker (mode normal / OLED) ───────────────────────────────
// Palette du picker, avec un fond noir en mode OLED.
static UIColor *tpk_pickerBgColor(void) {
    return TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}
static UIColor *tpk_pickerCardColor(void) {
    return TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.05 alpha:1.0]
        : [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
}
static UIColor *tpk_pickerSepColor(void) {
    return TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:0.12 alpha:1.0]
        : [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}
static UIColor *tpk_pickerAccentColor(void) {
    return [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
}

// Attend l'attachement à la fenêtre avant de créer les cellules.
@interface TPKPickerContainerView : UIView
@property (nonatomic, copy) dispatch_block_t didAttachToWindow;
// L'inputView respecte la hauteur Auto Layout annoncée par preferredHeight.
@property (nonatomic, assign) CGFloat preferredHeight;
@end

@implementation TPKPickerContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _preferredHeight = frame.size.height;
    }
    return self;
}

- (void)setPreferredHeight:(CGFloat)preferredHeight {
    if (fabs(_preferredHeight - preferredHeight) < 0.5) return;
    _preferredHeight = preferredHeight;
    [self invalidateIntrinsicContentSize];
}

- (CGSize)intrinsicContentSize {
    // Garde une hauteur non nulle et laisse la largeur sans contrainte.
    return CGSizeMake(CGFLOAT_MAX,
                      _preferredHeight > 0 ? _preferredHeight
                                           : CGRectGetHeight(self.bounds));
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && self.didAttachToWindow) self.didAttachToWindow();
}
@end

@interface TPKPickerWeakRef : NSObject
@property (nonatomic, weak) id object;
+ (instancetype)refWithObject:(id)object;
@end

@implementation TPKPickerWeakRef
+ (instancetype)refWithObject:(id)object {
    TPKPickerWeakRef *reference = [TPKPickerWeakRef new];
    reference.object = object;
    return reference;
}
@end

// Section du catalogue affichée séparément de la liste aplatie.
@interface TPKPickerDisplaySection : NSObject
@property (nonatomic, assign) TPKEmoteProviderID provider;
@property (nonatomic, assign) TPKEmoteSectionKind kind;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<TPKEmote *> *items;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL empty;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end

@implementation TPKPickerDisplaySection
@end

// En-tête avec une seule cible VoiceOver et tactile.
@interface TPKPickerSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *retryButton;
@end

@implementation TPKPickerSectionHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;

    _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _toggleButton.frame = self.bounds;
    _toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    // Garde le chevron aligné à droite du bouton pleine largeur.
    _toggleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    _toggleButton.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8.0);
    _toggleButton.accessibilityTraits = UIAccessibilityTraitButton;
    [self addSubview:_toggleButton];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    _countLabel.textAlignment = NSTextAlignmentRight;
    _countLabel.userInteractionEnabled = NO;
    [self addSubview:_countLabel];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
    _stateLabel.textAlignment = NSTextAlignmentRight;
    _stateLabel.userInteractionEnabled = NO;
    _stateLabel.hidden = YES;
    [self addSubview:_stateLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
        configurationWithPointSize:11.0 weight:UIImageSymbolWeightMedium];
    [_retryButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"
                              withConfiguration:config]
                   forState:UIControlStateNormal];
    _retryButton.accessibilityLabel = @"Retry";
    _retryButton.hidden = YES;
    [self addSubview:_retryButton];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = 8.0;
    CGFloat retryWidth = self.retryButton.hidden ? 0.0 : 26.0;
    self.retryButton.frame = CGRectMake(self.bounds.size.width - inset - retryWidth,
                                        0, retryWidth, self.bounds.size.height);
    CGFloat chevronWidth = 24.0;
    self.toggleButton.frame = self.bounds;
    self.titleLabel.frame = CGRectMake(inset, 0,
                                       MAX(0, self.bounds.size.width - inset * 2 - retryWidth - chevronWidth),
                                       self.bounds.size.height);
    CGFloat right = self.bounds.size.width - inset - retryWidth - chevronWidth;
    CGFloat stateWidth = self.stateLabel.hidden ? 0.0 : MIN(110.0, right * 0.40);
    self.stateLabel.frame = CGRectMake(MAX(inset, right - stateWidth), 0,
                                       stateWidth, self.bounds.size.height);
    self.countLabel.frame = CGRectMake(MAX(inset, right - stateWidth - 46.0), 0,
                                       46.0, self.bounds.size.height);
}
@end

@interface TPKManager (TPKChatBarButton)
- (void)tpk_emoteButtonTappedForButton:(UIButton *)sender;
@end

@implementation TPKManager (TPKChatBarButton)
- (void)tpk_emoteButtonTappedForButton:(UIButton *)sender {
    if (!TPKChatAppearanceConfig.sharedConfig.pickerButtonEnabled) return;
    id association = objc_getAssociatedObject(sender, &kTPKPickerHostAssociation);
    UIView *chatInputView = [association isKindOfClass:TPKPickerWeakRef.class]
        ? ((TPKPickerWeakRef *)association).object : association;
    if (!chatInputView || !chatInputView.window) return;
    [self toggleEmotePickerForChatInputView:chatInputView];
}
@end

static UIView *tpk_pickerHostForBitsView(UIView *bitsView) {
    for (UIView *current = bitsView.superview; current; current = current.superview) {
        NSString *className = NSStringFromClass(current.class);
        if ([className containsString:@"RNSScreenContentWrapper"] ||
            [className containsString:@"KeyboardControllerView"] ||
            [className containsString:@"ChatInput"]) return current;
    }
    return bitsView.window ?: bitsView;
}

BOOL TPKPickerChatButtonReady(void) {
    UIButton *replacement = tpk_pickerChatButtonReplacement;
    return replacement != nil && replacement.window != nil &&
        replacement.superview != nil && !replacement.hidden;
}

// Le bouton est un sibling dans le container pour rester hittable hors bounds.
// Retire les anciennes cibles UIKit après la migration RN.
static UIView *tpk_legacyPickerInputForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview)
        if ([NSStringFromClass(cursor.class) isEqualToString:@"Twitch.ChatInputView"]) return cursor;
    return nil;
}

static BOOL tpk_isLegacyBitsButton(UIView *view) {
    return [NSStringFromClass(view.class).lowercaseString containsString:@"bitsbutton"] ||
           [view.accessibilityIdentifier isEqualToString:@"chat_input_bits_button"];
}

static UIView *tpk_legacyPickerBitsForView(UIView *view) {
    UIView *input = tpk_legacyPickerInputForView(view);
    if (!input) return nil;
    if (tpk_isLegacyBitsButton(view)) return view;
    if (view != input && ![NSStringFromClass(view.class).lowercaseString containsString:@"emoticon"]) return nil;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithArray:input.subviews];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *candidate = views[i];
        if (tpk_isLegacyBitsButton(candidate)) return candidate;
        [views addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL tpk_isNativeEmoteButton(UIView *view) {
    return [view.accessibilityIdentifier isEqualToString:@"chat-tray-button-emote"] ||
        (tpk_legacyPickerInputForView(view) &&
         [NSStringFromClass(view.class).lowercaseString containsString:@"emoticon"]);
}

static UIView *tpk_findRNTraySibling(UIView *view, NSString *identifier) {
    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 4; depth++, cursor = cursor.superview)
        for (UIView *sibling in cursor.subviews)
            if (sibling.window && [sibling.accessibilityIdentifier isEqualToString:identifier]) return sibling;
    return nil;
}

static UIView * _Nullable tpk_findNativeEmoteButton(UIView *bitsNative) {
    if (tpk_isNativeEmoteButton(bitsNative)) return bitsNative;
    UIView *input = tpk_legacyPickerInputForView(bitsNative);
    if (input) {
        NSMutableArray<UIView *> *views = [NSMutableArray arrayWithArray:input.subviews];
        for (NSUInteger i = 0; i < views.count; i++) {
            UIView *candidate = views[i];
            if ([NSStringFromClass(candidate.class).lowercaseString containsString:@"emoticon"]) return candidate;
            [views addObjectsFromArray:candidate.subviews];
        }
        return nil;
    }
    return tpk_findRNTraySibling(bitsNative, @"chat-tray-button-emote");
}

// Synchronise la pastille avec le container à chaque layout.
@interface TPKPickerSlotObserverView : UIView
@property (nonatomic, copy, nullable) void (^onHostLayout)(UIView *view);
@end
@implementation TPKPickerSlotObserverView
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.onHostLayout) self.onHostLayout(self);
}
@end

static __weak TPKPickerSlotObserverView *tpk_pickerSlotObserver = nil;

// Suit aussi les déplacements RN qui ne déclenchent pas de layout.
static IMP s_tpkPickerOrigSetFrame = NULL;
static IMP s_tpkPickerOrigSetBounds = NULL;
static IMP s_tpkPickerOrigSetCenter = NULL;

static void tpk_attachPassivePickerButton(UIView * _Nullable native);

static void tpk_pickerGeometryChanged(id self) {
    UIView *tracked = tpk_pickerChatButtonNative;
    if (!tracked || (self != tracked && self != tpk_pickerChatButtonEmote)) return;
    tpk_attachPassivePickerButton(tracked);
}

static void tpk_pickerSetFrameHook(id self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))s_tpkPickerOrigSetFrame)(self, _cmd, frame);
    tpk_pickerGeometryChanged(self);
}

static void tpk_pickerSetBoundsHook(id self, SEL _cmd, CGRect bounds) {
    ((void (*)(id, SEL, CGRect))s_tpkPickerOrigSetBounds)(self, _cmd, bounds);
    tpk_pickerGeometryChanged(self);
}

static void tpk_pickerSetCenterHook(id self, SEL _cmd, CGPoint center) {
    ((void (*)(id, SEL, CGPoint))s_tpkPickerOrigSetCenter)(self, _cmd, center);
    tpk_pickerGeometryChanged(self);
}

static void tpk_pickerInstallGeometryHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"RCTViewComponentView");
        if (!cls) return;
        Method mf = class_getInstanceMethod(cls, @selector(setFrame:));
        if (mf) {
            s_tpkPickerOrigSetFrame = method_getImplementation(mf);
            class_replaceMethod(cls, @selector(setFrame:),
                                (IMP)tpk_pickerSetFrameHook,
                                method_getTypeEncoding(mf));
        }
        Method mb = class_getInstanceMethod(cls, @selector(setBounds:));
        if (mb) {
            s_tpkPickerOrigSetBounds = method_getImplementation(mb);
            class_replaceMethod(cls, @selector(setBounds:),
                                (IMP)tpk_pickerSetBoundsHook,
                                method_getTypeEncoding(mb));
        }
        Method mc = class_getInstanceMethod(cls, @selector(setCenter:));
        if (mc) {
            s_tpkPickerOrigSetCenter = method_getImplementation(mc);
            class_replaceMethod(cls, @selector(setCenter:),
                                (IMP)tpk_pickerSetCenterHook,
                                method_getTypeEncoding(mc));
        }
    });
}

static void tpk_attachPassivePickerButton(UIView * _Nullable native) {
    if (native && native != tpk_pickerChatButtonNative) return;
    TPKManager *manager = [TPKManager sharedManager];
    UIButton *button = tpk_pickerChatButtonReplacement;
    BOOL usable = TPKChatAppearanceConfig.sharedConfig.pickerButtonEnabled && native && native.window &&
        ([native.accessibilityIdentifier isEqualToString:@"chat-tray-button-bits"] ||
         (tpk_legacyPickerInputForView(native) && tpk_isLegacyBitsButton(native)) ||
         tpk_isNativeEmoteButton(native));
    UIView *emote = usable ? tpk_findNativeEmoteButton(native) : nil;
    if (!usable || !emote) {
        if ([button isKindOfClass:[UIButton class]]) [button removeFromSuperview];
        if (tpk_pickerChatButtonReplacement) tpk_pickerChatButtonReplacement = nil;
        if (native) native.userInteractionEnabled = YES;
        TPKPickerSlotObserverView *deadSlotObserver = tpk_pickerSlotObserver;
        if (deadSlotObserver) [deadSlotObserver removeFromSuperview];
        return;
    }
    tpk_pickerChatButtonEmote = emote;
    BOOL replacesBits = native != emote;
    if (![button isKindOfClass:[UIButton class]]) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.accessibilityLabel = L(@"label_7tv_emotes");
        button.accessibilityIdentifier = @"tpk_emote_picker_button";
        CGFloat side = MIN(native.bounds.size.height, native.bounds.size.width);
        UIImage *icon = tpk_pickerLogoImage(MAX(side, 1.0) * 0.60);
        if (icon) {
            for (NSNumber *state in @[@(UIControlStateNormal),
                                      @(UIControlStateHighlighted),
                                      @(UIControlStateSelected),
                                      @(UIControlStateDisabled)]) {
                [button setImage:icon forState:state.unsignedIntegerValue];
            }
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            button.tintColor = UIColor.whiteColor;
        }
        [button addTarget:manager
                   action:@selector(tpk_emoteButtonTappedForButton:)
         forControlEvents:UIControlEventTouchUpInside];
        tpk_pickerChatButtonReplacement = button;
    }
    // OLED noir sinon #27262c : recouvre sans masquer.
    button.backgroundColor = TPKOLEDModeEnabled()
        ? UIColor.blackColor
        : [UIColor colorWithRed:39.0/255.0 green:38.0/255.0 blue:44.0/255.0 alpha:1.0];
    // Keep the native emote button usable when disabling Bits.
    if (replacesBits) native.userInteractionEnabled = NO;
    tpk_pickerInstallGeometryHooks();
    // Use a hittable sibling in the parent, not an out-of-bounds child.
    UIView *slotParent = emote.superview ?: native.superview;
    if (!slotParent) {
        if ([button isKindOfClass:[UIButton class]]) [button removeFromSuperview];
        if (native) native.userInteractionEnabled = YES;
        return;
    }
    CGRect slot = [native convertRect:native.bounds toView:slotParent];
    // Reserve the same slot beside the emote button when Bits is absent.
    if (!replacesBits) slot.origin.x -= slot.size.width;
    button.frame = slot;
    button.autoresizingMask = UIViewAutoresizingNone;
    TPKPickerSlotObserverView *slotObserver = tpk_pickerSlotObserver;
    if (!slotObserver || slotObserver.superview != slotParent) {
        [slotObserver removeFromSuperview];
        slotObserver = [TPKPickerSlotObserverView new];
        slotObserver.userInteractionEnabled = NO;
        slotObserver.backgroundColor = UIColor.clearColor;
        slotObserver.accessibilityIdentifier = @"tpk_picker_slot_observer";
        slotObserver.frame = slotParent.bounds;
        slotObserver.autoresizingMask = UIViewAutoresizingFlexibleWidth
            | UIViewAutoresizingFlexibleHeight;
        [slotParent addSubview:slotObserver];
        tpk_pickerSlotObserver = slotObserver;
    }
    __weak UIView *weakNative = native;
    slotObserver.onHostLayout = ^(__unused UIView *v) {
        UIView *strongNative = weakNative;
        if (!strongNative) return;
        // Refresh the anchor after layout when Bits changes visibility.
        dispatch_async(dispatch_get_main_queue(), ^{
            tpk_attachPassivePickerButton(strongNative);
        });
    };
    if (button.superview != slotParent) {
        [slotParent addSubview:button];
    } else if (slotParent.subviews.lastObject != (UIView *)button &&
               slotParent.subviews.lastObject != (UIView *)slotObserver) {
        [slotParent addSubview:button];
    }
    button.hidden = NO;
    UIView *host = tpk_pickerHostForBitsView(native);
    objc_setAssociatedObject(button, &kTPKPickerHostAssociation,
                             [TPKPickerWeakRef refWithObject:host],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void TPKPickerSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __block BOOL previous = TPKChatAppearanceConfig.sharedConfig.pickerButtonEnabled;
        [NSNotificationCenter.defaultCenter addObserverForName:TPKChatAppearanceConfigDidChangeNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                BOOL enabled = TPKChatAppearanceConfig.sharedConfig.pickerButtonEnabled;
                if (previous == enabled) return;
                previous = enabled;
                tpk_attachPassivePickerButton(tpk_pickerChatButtonNative);
            }];
    });
}

void tpk_handleChatTrayButtonLifecycle(UIView *view) {
    if (view == tpk_pickerChatButtonNative && !view.window) {
        __weak UIView *remainingEmote = tpk_pickerChatButtonEmote;
        id reference = objc_getAssociatedObject(tpk_pickerChatButtonReplacement, &kTPKPickerHostAssociation);
        UIView *host = [reference isKindOfClass:TPKPickerWeakRef.class] ? ((TPKPickerWeakRef *)reference).object : nil;
        if (host) [[TPKManager sharedManager] cleanupPickerForStreamCloseIfOwnedByChatInputView:host];
        view.userInteractionEnabled = YES;
        tpk_pickerChatButtonNative = nil;
        tpk_attachPassivePickerButton(nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *emote = remainingEmote;
            if (emote.window) tpk_handleChatTrayButtonLifecycle(emote);
        });
        return;
    }
    BOOL isEmote = tpk_isNativeEmoteButton(view);
    UIView *native = [view.accessibilityIdentifier isEqualToString:@"chat-tray-button-bits"] ? view :
        (isEmote && !tpk_legacyPickerInputForView(view) ?
         tpk_findRNTraySibling(view, @"chat-tray-button-bits") : tpk_legacyPickerBitsForView(view));
    if (!native.window && isEmote) native = view;
    if (!native.window) return;
    UIView *previous = tpk_pickerChatButtonNative;
    if (previous != native) previous.userInteractionEnabled = YES;
    tpk_pickerChatButtonNative = native;
    tpk_attachPassivePickerButton(native);
}

@interface TPKEmotePickerController ()


// Picker d'emotes inline (affiché au-dessus de la barre de saisie)
@property (nonatomic, strong) UIView              *emotePickerView;
// Strong reference keeps the input view alive until selection.
@property (nonatomic, weak)   UIView              *emotePickerTextField;
// Strong reference to observe TextDidEndEditing.
@property (nonatomic, strong) UITextView          *emotePickerTextEntryView;
@property (nonatomic, strong) UICollectionView    *emoteCollectionView;
@property (nonatomic, strong) UITextField         *emoteSearchField;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerEmotes;
@property (nonatomic, strong, readwrite) NSArray<TPKEmote *> *emotePickerAllEmotes;
// Ignore TextDidEndEditing while the search alert takes focus.
@property (nonatomic, assign) BOOL pickerSearchAlertActive;

// Filtered arrays shown in the picker.
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerChannelEmotes;
@property (nonatomic, strong, readwrite) NSArray<TPKEmote *> *emotePickerGlobalEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *emotePickerOtherEmotes; // compatibilité
// Catalogue par fournisseur.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<TPKEmote *> *> *pickerProviderEmotes;
@property (nonatomic, strong) NSArray<TPKEmote *> *pickerCatalogFavorites;
@property (nonatomic, copy) NSSet<NSString *> *pickerFavoriteKeySet;
// Channel/Global wrappers reuse the legacy cell and animation path.
@property (nonatomic, strong) NSDictionary<NSNumber *, NSArray<TPKPickerDisplaySection *> *> *pickerProviderSections;
@property (nonatomic, strong) NSArray<TPKPickerDisplaySection *> *pickerDisplaySections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pickerCollapsedSections;
// Restore section collapse choices when search is cleared.
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pickerCollapseStateBeforeSearch;
@property (nonatomic, assign) BOOL pickerCatalogSearchActive;
@property (nonatomic, assign) BOOL pickerUsesCatalogSections;

// Ouvre les paramètres du tweak.
@property (nonatomic, weak) UIButton *pickerSettingsBtn;
// Capsule du bouton de paramètres.
@property (nonatomic, weak) UIView   *pickerToolsCapsuleView;


// ── Refonte tabbed + refonte visuelle du picker (style 7TV PC) ──────────
// Tabs: Favorites, All, 7TV, BTTV, and FFZ. All combines enabled providers.
@property (nonatomic, assign) NSInteger pickerActiveTab;
// Restore the selected tab when search is cleared.
@property (nonatomic, assign) BOOL      pickerIsSearching;
@property (nonatomic, assign) NSInteger pickerPreSearchTab;
// Provider and Channel/Global capsules float over the grid.
@property (nonatomic, weak) UIView    *pickerSubcategoryCapsuleView;
@property (nonatomic, weak) UIButton  *pickerSubcategoryChannelBtn;
@property (nonatomic, weak) UIButton  *pickerSubcategoryGlobalBtn;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pickerSubcategoryByProvider;
@property (nonatomic, weak) UIView    *pickerTabCapsuleView;         // bas gauche (Favoris/Tous/7TV/BTTV/FFZ)
@property (nonatomic, strong) NSMutableArray<UIButton *> *pickerTabButtons;
@property (nonatomic, weak) UIView    *pickerTabIndicatorView;       // pastille violette qui glisse entre les 5 boutons
@property (nonatomic, weak) UIView    *pickerSearchCapsuleView;      // bas, pleine largeur (recherche)
@property (nonatomic, weak) UIButton  *pickerSearchClearBtn;         // petite croix à droite du champ, visible si texte non vide
// Drag previews are cancellable when a cell leaves the screen.
@property (nonatomic, assign) BOOL pickerScrollInProgress;
@property (nonatomic, assign) BOOL pickerCatalogReloadPending;
// Coalesce rapid updates into one pending refresh.
@property (nonatomic, assign) CFTimeInterval pickerCatalogLastApplyTime;
@property (nonatomic, assign) BOOL pickerCatalogCoalesceFlushArmed;
@property (nonatomic, assign) NSUInteger pickerOrientationGeneration;
// On first open, select the first nonempty provider unless the user chose a tab.
@property (nonatomic, assign) BOOL pickerInitialProviderSelectionPending;
// Rebuild flattened wrappers only when catalogue snapshots change.
@property (nonatomic, assign) BOOL pickerCatalogArraysDirty;
// Keep an explicit settings choice over automatic tab selection.
@property (nonatomic, assign) BOOL pickerOpeningLocationExplicit;

- (void)_tpk_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection;
- (void)_tpk_emoteCatalogDidUpdate:(NSNotification *)notification;
- (void)_tpk_twitchCredentialsDidUpdate:(NSNotification *)notification;
- (void)_tpk_badgesCatalogDidUpdate:(NSNotification *)notification;
- (void)_tpk_deviceOrientationDidChange:(NSNotification *)notification;
- (void)_tpk_applyCatalogUpdateNow;
- (void)_tpk_prewarmPickerViewportImages;
- (void)_tpk_normalizeActivePickerTab;
- (BOOL)_tpk_selectInitialProviderIfNeeded;
- (TPKEmoteProviderID)_tpk_providerForPickerTab:(NSInteger)tab;
- (void)_tpk_updateSubcategoryCapsule;
- (void)_pickerSubcategoryTapped:(UIButton *)sender;
- (BOOL)_tpk_sectionIsChannel:(TPKPickerDisplaySection *)section;
- (BOOL)_tpk_sectionIsGlobal:(TPKPickerDisplaySection *)section;
- (BOOL)_tpk_pickerTabIsProvider:(NSInteger)tab;
- (void)_tpk_updatePickerTabButtonLayout;
- (NSArray<NSNumber *> *)_tpk_providerIDsInPriorityOrder;
- (void)_tpk_persistLastPickerLocation;
- (BOOL)_tpk_applyConfiguredPickerOpeningLocation;
- (void)_tpk_oledModeDidChange:(NSNotification *)notification;
- (void)_tpk_applyOLEDColors;
- (void)_tpk_relayoutPickerForSize:(CGSize)size;
- (CGFloat)_tpk_resolvedGridHeight;
- (void)_tpk_deactivateVisiblePickerAnimations;
- (void)_tpk_activateVisiblePickerAnimations;
- (void)_tpk_scheduleAnimationForPickerCell:(TPKEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath;
- (void)_tpk_scheduleStaticImageForPickerCell:(TPKEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath;
- (BOOL)_tpk_configureAnimatedPickerCell:(TPKEmotePickerCell *)cell
                                      URL:(NSURL *)imageURL
                                animated:(BOOL)animated
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode;
- (void)_pickerSectionHeaderTapped:(UIButton *)sender;
- (void)_pickerSectionRetryTapped:(UIButton *)sender;

@end

@implementation TPKEmotePickerController

// Preserve the defaults from -[TPKManager setup].
- (instancetype)init {
    self = [super init];
    if (self) {
        _pickerActiveTab                  = 0; // TPKPickerTabFavorites
        _pickerTabButtons                 = [NSMutableArray array];
        _emotePickerFavoriteEmotes = @[];
        _emotePickerChannelEmotes  = @[];
        _emotePickerGlobalEmotes   = @[];
        _emotePickerOtherEmotes    = @[];
        _pickerProviderEmotes      = @{};
        _pickerCatalogFavorites    = @[];
        _pickerFavoriteKeySet      = [NSSet set];
        _pickerProviderSections    = @{};
        _pickerDisplaySections     = @[];
        _pickerCollapsedSections   = [NSMutableDictionary dictionary];
        _pickerSubcategoryByProvider = [NSMutableDictionary dictionary];
        _pickerCollapseStateBeforeSearch = nil;
        _pickerCatalogSearchActive = NO;
        _pickerUsesCatalogSections = NO;
        _pickerInitialProviderSelectionPending = NO;
        _pickerCatalogArraysDirty = YES;
        _pickerOpeningLocationExplicit = NO;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_tpk_appearanceDidChange:)
            name:TPKChatAppearanceConfigDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKEmoteCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKProviderCatalogDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_emoteCatalogDidUpdate:)
                                                      name:TPKEmoteProviderSettingsDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_twitchCredentialsDidUpdate:)
                                                      name:TPKTwitchCredentialsDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_badgesCatalogDidUpdate:)
                                                      name:TPKPickerChannelAvatarDidUpdateNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_deviceOrientationDidChange:)
                                                      name:UIDeviceOrientationDidChangeNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_oledModeDidChange:)
                                                      name:TPKOLEDModeDidChangeNotification
                                                    object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_keyboardFrameDidChange:)
                                                      name:UIKeyboardDidChangeFrameNotification
                                                    object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_tpk_textEntryDidEndEditing:)
                                                      name:UITextViewTextDidEndEditingNotification
                                                    object:nil];
        // Decode logos in the background before the first open.
        tpk_pickerPrewarmProviderLogos();
    }
    return self;
}

- (void)_tpk_oledModeDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _tpk_applyOLEDColors];
        if (tpk_pickerChatButtonNative) tpk_attachPassivePickerButton(tpk_pickerChatButtonNative);
    });
}

- (void)_tpk_applyOLEDColors {
    if (!self.emotePickerView) return;

    UIColor *backgroundColor = tpk_pickerBgColor();
    UIColor *cardColor       = tpk_pickerCardColor();
    UIColor *sepColor        = tpk_pickerSepColor();

    self.emotePickerView.backgroundColor = backgroundColor;
    self.emoteCollectionView.backgroundColor = backgroundColor;

    // Match floating capsule backgrounds to the cells.
    UIColor *capsuleColor = [cardColor colorWithAlphaComponent:0.92];
    self.pickerTabCapsuleView.backgroundColor   = capsuleColor;
    self.pickerSubcategoryCapsuleView.backgroundColor = capsuleColor;
    self.pickerToolsCapsuleView.backgroundColor = capsuleColor;
    self.pickerSearchCapsuleView.backgroundColor = capsuleColor;

    // Recolor visible cells now; reused cells update when dequeued.
    for (TPKEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell tpk_applyOLEDColors];
    }
    UIColor *headerColor = TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:1.0 alpha:0.035]
        : [UIColor colorWithWhite:1.0 alpha:0.055];
    for (TPKPickerSectionHeaderView *header in
         [self.emoteCollectionView visibleSupplementaryViewsOfKind:
             UICollectionElementKindSectionHeader]) {
        header.backgroundColor = headerColor;
    }



    // Aperçu du chat flottant.
}

- (void)_tpk_keyboardFrameDidChange:(NSNotification *)notification {
    if (tpk_pickerChatButtonNative) tpk_attachPassivePickerButton(tpk_pickerChatButtonNative);
    UIView *pickerView = self.emotePickerView;
    if (!pickerView.window || pickerView.hidden) return;
    CGFloat height = [self _tpk_resolvedGridHeight];
    if (fabs(pickerView.bounds.size.height - height) >= 0.5) {
        CGRect frame = pickerView.frame;
        frame.size.height = height;
        pickerView.frame = frame;
        [self _tpk_relayoutPickerForSize:frame.size];
        [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    }
}

- (void)_tpk_textEntryDidEndEditing:(NSNotification *)note {
    if (note.object != self.emotePickerTextEntryView) return;
    if (!self.emotePickerView || self.emotePickerView.hidden) return; // picker déjà fermé, rien à faire
    if (self.pickerSearchAlertActive) return; // focus prêté à l'alerte de recherche

    // UIKit already resigned the input view; reset picker state only.
    [self _tpk_deactivateVisiblePickerAnimations];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    self.pickerOrientationGeneration += 1;
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
}



static NSString *const kEmoteCellID = @"TPKEmoteCell";

// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize = 40.0;

// ── Onglets du picker refondu (style 7TV PC) ──────────────────────────────
// Tabs: Favorites, All, 7TV, BTTV, and FFZ; All aggregates enabled providers.
typedef NS_ENUM(NSInteger, TPKPickerTab) {
    TPKPickerTabFavorites = 0,
    TPKPickerTabAll       = 1,
    TPKPickerTabTPK   = 2,
    TPKPickerTabBTTV      = 3,
    TPKPickerTabFFZ       = 4,
};

// ── Dimensions du picker refondu ────────────────────────────────────────
// The grid fills the picker; section insets reserve space for floating controls.
static const CGFloat kTPKPickerFloatSize    = 28.0; // diamètre/hauteur des pastilles flottantes (fermer, onglets, sous-choix, ⚙️)
static const CGFloat kTPKPickerFloatMargin  = 8.0;  // marge entre une pastille et le bord du picker
static const CGFloat kTPKPickerFloatGap     = 6.0;  // écart vertical entre 2 rangées de pastilles flottantes
static const CGFloat kTPKPickerSubcategoryGap = 4.0; // écart preview entre Channel/Global et les providers
static const CGFloat kTPKPickerSearchH      = 38.0; // hauteur de la capsule de recherche
// Reserve bottom inset space so floating controls never cover cells.
static const CGFloat kTPKPickerBottomZoneH  =
    kTPKPickerFloatMargin + kTPKPickerFloatSize + kTPKPickerFloatGap + kTPKPickerSearchH + kTPKPickerFloatMargin;

// Minimum height fits the bottom controls and one emote row.
static const CGFloat kTPKPickerMinUsableH = 120.0;
// Space reserved above the picker for the safe area and chat bar.
static const CGFloat kTPKPickerChromeReserveH = 120.0;
// (annulation lors du recyclage)
- (void)_tpk_refreshChannelAvatarIfNeeded {
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    if (!channelID.length) {
        [self _tpk_resetChannelButtonToPlaceholder];
        return;
    }

    // Load the shared Channel-tab avatar.
    NSURL *avatarURL = [[TPKPickerChannelAvatarProvider sharedProvider]
        channelAvatarURLForChannelID:channelID];
    if (!avatarURL) {
        [self _tpk_resetChannelButtonToPlaceholder];
        return; // The avatar update notification refreshes this view.
    }

    TPKEmoteImageCache *imageCache = [TPKEmoteImageCache sharedCache];
    UIImage *cached = [imageCache cachedImageForURL:avatarURL];
    if (cached) {
        [self _tpk_applyChannelAvatarImage:cached];
        return;
    }

    [self _tpk_resetChannelButtonToPlaceholder];
    NSString *requestedChannelID = [channelID copy];
    __weak typeof(self) weakSelf = self;
    [imageCache imageForURL:avatarURL completion:^(UIImage * _Nullable image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // Ignore stale avatar responses from a previous channel.
        if (![[TPKManager sharedManager].currentChannelTwitchID
              isEqualToString:requestedChannelID]) return;
        [strongSelf _tpk_applyChannelAvatarImage:image];
    }];
}

// Retry avatar loading when credentials arrive after the picker opens.
- (void)_tpk_twitchCredentialsDidUpdate:(__unused NSNotification *)notification {
    self.pickerCatalogArraysDirty = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _tpk_refreshChannelAvatarIfNeeded];
    });
}

// Resolve the Helix avatar URL through the shared image cache.
- (void)_tpk_badgesCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pickerSubcategoryChannelBtn) return;
        [self _tpk_refreshChannelAvatarIfNeeded];
    });
}

- (void)_tpk_deviceOrientationDidChange:(__unused NSNotification *)notification {
    if (tpk_pickerChatButtonNative) tpk_attachPassivePickerButton(tpk_pickerChatButtonNative);
    NSUInteger generation = ++self.pickerOrientationGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.pickerOrientationGeneration ||
            !strongSelf.emotePickerView || strongSelf.emotePickerView.hidden) return;
        // Don't restore a floating preview after rotation if inputView was lost.
        BOOL pickerAttachedAsInputView = strongSelf.emotePickerTextEntryView &&
            strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView;
        BOOL pickerVisibleAsWindowFallback = !strongSelf.emotePickerTextEntryView &&
            strongSelf.emotePickerView.window &&
            strongSelf.emotePickerView.superview == strongSelf.emotePickerView.window;
        if (!pickerAttachedAsInputView && !pickerVisibleAsWindowFallback) return;
        UIWindow *hostWindow = strongSelf.emotePickerTextField.window
            ?: strongSelf.emotePickerTextEntryView.window;
        CGFloat width = hostWindow.bounds.size.width;
        if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
        CGFloat targetHeight = [strongSelf _tpk_resolvedGridHeight];
        BOOL attachedAsInputView = strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView;
        CGFloat originY = 0;
        if (!attachedAsInputView && strongSelf.emotePickerView.superview == hostWindow) {
            // Keep the fallback view anchored to the bottom after rotation.
            originY = MAX(hostWindow.safeAreaInsets.top,
                hostWindow.bounds.size.height - targetHeight - 56.0);
        }
        strongSelf.emotePickerView.frame = CGRectMake(0, originY, width, targetHeight);
        [strongSelf _tpk_relayoutPickerForSize:strongSelf.emotePickerView.bounds.size];
        if (strongSelf.emotePickerTextEntryView.window &&
            strongSelf.emotePickerTextEntryView.inputView == strongSelf.emotePickerView) {
            [strongSelf.emotePickerTextEntryView reloadInputViews];
        }

    });
}

// Crops the source image to a circle of the requested diameter.
- (UIImage *)_tpk_circularAvatarFromImage:(UIImage *)source diameter:(CGFloat)diameter {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGSize targetSize = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] addClip];
        // Aspect-fill and center-crop the source image.
        CGFloat scale = MAX(diameter / source.size.width, diameter / source.size.height);
        CGFloat drawW = source.size.width  * scale;
        CGFloat drawH = source.size.height * scale;
        CGRect drawRect = CGRectMake((diameter - drawW) / 2.0, (diameter - drawH) / 2.0, drawW, drawH);
        [source drawInRect:drawRect];
    }];
}

// Keep the provider logo clear of the capsule edges.
static const CGFloat kTPKPickerAvatarDiameter = 22.0;

- (void)_tpk_applyChannelAvatarImage:(UIImage *)image {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn || !image) return;
    UIImage *circular = [self _tpk_circularAvatarFromImage:image diameter:kTPKPickerAvatarDiameter];
    if (!circular) return;
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[circular imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
          forState:UIControlStateNormal];
}

// Fallback propre — remet le symbole d'origine (mêmes réglages qu'à la création).
- (void)_tpk_resetChannelButtonToPlaceholder {
    UIButton *btn = self.pickerSubcategoryChannelBtn;
    if (!btn) return;
    UIImageSymbolConfiguration *avCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:avCfg]
          forState:UIControlStateNormal];
}

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    // Run synchronously so UIKit doesn't resign before reloadInputViews.

    // ── Invalider le cache si le TextEntryView n'est plus dans une fenêtre ──
    // A channel change rebuilds the hierarchy, so discard orphaned input views.
    if (self.emotePickerTextEntryView && !self.emotePickerTextEntryView.window) {
        [[TPKManager sharedManager] log:@"⚠️ emotePickerTextEntryView orphelin (window=nil) → reset cache"];
        self.emotePickerTextEntryView = nil;
    }

    // ── Trouver le champ de saisie (UITextView RN) via BFS ──────────────────
    if (!self.emotePickerTextEntryView && chatInputView) {
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:chatInputView];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            if ([v isKindOfClass:[UITextView class]]) {
                self.emotePickerTextEntryView = (UITextView *)v;
                [[TPKManager sharedManager] log:@"⚠️ TextEntryView UITextView: %@", NSStringFromClass([v class])];
                break;
            }
        }
    }

    // ── Basculer : picker déjà affiché → retirer ────────────────────────────
    // Only hide an existing picker; otherwise the first tap cannot open it.
    BOOL pickerAttachedAsInputView = self.emotePickerView &&
        self.emotePickerTextEntryView &&
        self.emotePickerTextEntryView.inputView == self.emotePickerView;
    BOOL pickerVisibleAsWindowFallback = self.emotePickerView &&
        self.emotePickerView.window && !self.emotePickerView.hidden &&
        !pickerAttachedAsInputView;
    if (pickerAttachedAsInputView || pickerVisibleAsWindowFallback) {
        [self _hideEmotePicker];
        return;
    }

    self.emotePickerTextField = chatInputView;
    [self _buildAndShowEmotePickerForView:chatInputView];
}

- (void)_hideEmotePicker {
    self.pickerSearchAlertActive = NO;
    // Ignore deferred layout work after the picker closes.
    self.pickerOrientationGeneration += 1;
    [self _tpk_deactivateVisiblePickerAnimations];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Clear inputView without resigning when there is no window.
            tv.inputView = nil;
            tv.inputAccessoryView = nil;
            if (tv.window) {
                [tv resignFirstResponder];
                [tv reloadInputViews];
            }
        } @catch (...) {}
    }
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
}
- (void)cleanupPickerForStreamClose {
    self.pickerSearchAlertActive = NO;
    self.pickerOrientationGeneration += 1;
    [self _tpk_deactivateVisiblePickerAnimations];
    self.pickerScrollInProgress = NO;
    self.pickerCatalogReloadPending = NO;
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Avoid changing the responder chain without a window.
            tv.inputView = nil;
            tv.inputAccessoryView = nil;
        } @catch (...) {}
    }
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
}

- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView {
    // Ignore detach events from a previous channel's input view.
    if (self.emotePickerTextField && self.emotePickerTextField != chatInputView) return;
    [self cleanupPickerForStreamClose];
}

// Compatibility hook; sorting now uses the provider-aware catalogue.
- (void)invalidateSortCache {
    // There is no legacy emote cache to clear.
}

- (void)favoritesDidChange {
    NSAssert([NSThread isMainThread], @"TPKEmotePickerController: main thread uniquement");
    self.pickerCatalogArraysDirty = YES;
    [self _tpk_reloadCatalogSnapshotReloadCollection:
        (self.emotePickerView && !self.emotePickerView.hidden)];
}

- (TPKEmote *)_pickerEmoteForDescriptor:(TPKEmoteDescriptor *)descriptor {
    if (!descriptor.emoteID.length || !descriptor.name.length) return nil;
    return [[TPKPickerCatalogEmote alloc] initWithDescriptor:descriptor];
}

static NSString *TPKPickerStableEmoteKey(TPKEmote *emote) {
    if (!emote.emoteID.length) return @"";
    if ([emote isKindOfClass:[TPKPickerCatalogEmote class]]) {
        TPKEmoteDescriptor *descriptor = [(TPKPickerCatalogEmote *)emote descriptor];
        if (descriptor.emoteID.length)
            return TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
    }
    return TPKEmoteFavoriteKey(TPKEmoteProviderIDTPK, emote.emoteID);
}

// Legacy order: square emotes, smaller area, then name.
static NSComparisonResult TPKPickerCompareEmotes(id firstObject,
                                                   id secondObject,
                                                   BOOL includeProviderTieBreak) {
    TPKEmote *a = (TPKEmote *)firstObject;
    TPKEmote *b = (TPKEmote *)secondObject;
    if (a == b) return NSOrderedSame;

    BOOL aSquare = (a.width > 0 && a.height > 0 && a.width == a.height);
    BOOL bSquare = (b.width > 0 && b.height > 0 && b.width == b.height);
    if (aSquare != bSquare) return aSquare ? NSOrderedAscending : NSOrderedDescending;

    NSInteger aArea = a.width * a.height;
    NSInteger bArea = b.width * b.height;
    if (aArea == 0 && bArea == 0) {
        NSComparisonResult result = [(a.emoteName ?: @"")
            compare:(b.emoteName ?: @"")
            options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (result != NSOrderedSame) return result;
    } else {
        if (aArea == 0) return NSOrderedDescending;
        if (bArea == 0) return NSOrderedAscending;
        if (aArea < bArea) return NSOrderedAscending;
        if (aArea > bArea) return NSOrderedDescending;

        NSString *aName = a.emoteName ?: @"";
        NSString *bName = b.emoteName ?: @"";
        NSUInteger len = MIN(aName.length, bName.length);
        for (NSUInteger i = 0; i < len; i++) {
            unichar ac = [aName characterAtIndex:i];
            unichar bc = [bName characterAtIndex:i];
            if (ac >= 'a' && ac <= 'z') ac -= 32;
            if (bc >= 'a' && bc <= 'z') bc -= 32;
            if (ac < bc) return NSOrderedAscending;
            if (ac > bc) return NSOrderedDescending;
        }
        if (aName.length < bName.length) return NSOrderedAscending;
        if (aName.length > bName.length) return NSOrderedDescending;
    }

    if (includeProviderTieBreak) {
        NSInteger aProvider = -1;
        NSInteger bProvider = -1;
        if ([a isKindOfClass:[TPKPickerCatalogEmote class]])
            aProvider = [(TPKPickerCatalogEmote *)a descriptor].provider;
        if ([b isKindOfClass:[TPKPickerCatalogEmote class]])
            bProvider = [(TPKPickerCatalogEmote *)b descriptor].provider;
        if (aProvider < bProvider) return NSOrderedAscending;
        if (aProvider > bProvider) return NSOrderedDescending;
    }

    return [(a.emoteID ?: @"") compare:(b.emoteID ?: @"")
        options:NSCaseInsensitiveSearch | NSNumericSearch];
}

static NSComparator TPKPickerEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return TPKPickerCompareEmotes(firstObject, secondObject, YES);
};

static NSComparator TPKPickerMixedEmoteSizeComparator = ^NSComparisonResult(
    id firstObject, id secondObject) {
    return TPKPickerCompareEmotes(firstObject, secondObject, NO);
};

// Rasterize large logos to the 28pt slot size.
static UIImage *TPKPickerScaledProviderLogo(UIImage *image, CGFloat pointSize) {
    if (!image || pointSize <= 0) return image;
    CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 2.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(pointSize, pointSize) format:format];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, pointSize, pointSize)];
    }];
    return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// Fit wide logos without stretching them.
static UIImage *TPKPickerAspectFitProviderLogo(UIImage *image, CGFloat maxWidth, CGFloat maxHeight) {
    if (!image || maxWidth <= 0 || maxHeight <= 0) return image;
    CGSize src = image.size;
    if (src.width <= 0 || src.height <= 0) return image;
    CGFloat ratio = MIN(maxWidth / src.width, maxHeight / src.height);
    CGSize dst = CGSizeMake(src.width * ratio, src.height * ratio);
    CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 2.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(maxWidth, maxHeight) format:format];
    UIImage *fitted = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake((maxWidth - dst.width) / 2.0,
                                     (maxHeight - dst.height) / 2.0,
                                     dst.width, dst.height)];
    }];
    return [fitted imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)_tpk_applyProviderCatalogArrays {
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    NSMutableDictionary *providerArrays = [NSMutableDictionary dictionary];
    NSMutableDictionary *providerSections = [NSMutableDictionary dictionary];
    NSMutableArray *favorites = [NSMutableArray array];
    NSMutableSet *seenFavoriteKeys = [NSMutableSet set];
    NSMutableSet *currentCatalogKeys = [NSMutableSet set];
    // Read favorites once instead of querying UserDefaults for every emote.
    NSSet<NSString *> *favoriteKeySet = [NSSet setWithArray:[catalog favoriteKeysSnapshot]];
    self.pickerFavoriteKeySet = favoriteKeySet;
    BOOL hasSyntheticProviderState = NO;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        NSMutableArray *items = [NSMutableArray array];
        NSMutableDictionary<NSString *, TPKEmote *> *itemsByID = [NSMutableDictionary dictionary];
        NSMutableArray<TPKPickerDisplaySection *> *displaySections = [NSMutableArray array];
        TPKEmoteProviderSnapshot *snapshot =
            [catalog snapshotForProvider:(TPKEmoteProviderID)provider];
        BOOL providerLoading = snapshot.state == TPKEmoteProviderStateLoading;
        NSString *providerError = snapshot.state == TPKEmoteProviderStateError
            ? snapshot.errorMessage : nil;
        // Show loading sections while the initial catalogue request runs.
        if (snapshot.state == TPKEmoteProviderStateIdle &&
            snapshot.sections.count == 0) {
            TPKPickerDisplaySection *initialLoading = [TPKPickerDisplaySection new];
            initialLoading.provider = (TPKEmoteProviderID)provider;
            initialLoading.kind = TPKEmoteSectionKindSet;
            initialLoading.identifier = @"provider-state";
            initialLoading.title = TPKEmoteProviderName((TPKEmoteProviderID)provider);
            initialLoading.items = @[];
            initialLoading.loaded = NO;
            initialLoading.loading = YES;
            initialLoading.empty = NO;
            [displaySections addObject:initialLoading];
            hasSyntheticProviderState = YES;
        }
        for (TPKEmoteDescriptor *descriptor in
             [catalog allEmotesForProvider:(TPKEmoteProviderID)provider]) {
            TPKEmote *item = [self _pickerEmoteForDescriptor:descriptor];
            if (!item) continue;
            NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
            if (stableKey.length) [currentCatalogKeys addObject:stableKey];
            if (!itemsByID[stableKey]) {
                itemsByID[stableKey] = item;
                [items addObject:item];
            }
            if ([favoriteKeySet containsObject:stableKey]) {
                if (![seenFavoriteKeys containsObject:stableKey]) {
                    [seenFavoriteKeys addObject:stableKey];
                    [favorites addObject:item];
                }
            }
        }
        for (TPKEmoteSection *section in
             [catalog sectionsForProvider:(TPKEmoteProviderID)provider]) {
            NSMutableArray<TPKEmote *> *sectionItems = [NSMutableArray array];
            NSMutableSet<NSString *> *sectionSeenKeys = [NSMutableSet set];
            for (TPKEmoteDescriptor *descriptor in section.emotes) {
                NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
                TPKEmote *item = itemsByID[stableKey];
                if (item && ![sectionSeenKeys containsObject:stableKey]) {
                    [sectionSeenKeys addObject:stableKey];
                    [sectionItems addObject:item];
                }
            }
            [sectionItems sortUsingComparator:TPKPickerEmoteSizeComparator];
            // Hide loaded empty sections; keep loading and error sections visible.
            if (!sectionItems.count && section.loaded && !section.loading && !section.errorMessage.length)
                continue;
            TPKPickerDisplaySection *display = [TPKPickerDisplaySection new];
            display.provider = section.provider;
            display.kind = section.kind;
            display.identifier = section.identifier ?: @"";
            display.title = section.title.length ? section.title : @"Emotes";
            display.items = sectionItems.copy;
            display.loaded = section.loaded;
            // Keep cached sections visible after a failed refresh and show their state.
            display.loading = section.loading || providerLoading;
            display.empty = NO;
            display.errorMessage = section.errorMessage ?: providerError;
            [displaySections addObject:display];
        }
        [items sortUsingComparator:TPKPickerEmoteSizeComparator];
        providerArrays[@(provider)] = items.copy;
        providerSections[@(provider)] = displaySections.copy;
    }
    // Skip stale channel favorites but keep current global favorites.
    for (TPKEmoteDescriptor *descriptor in [catalog favoriteDescriptorsSnapshot]) {
        NSString *stableKey = TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID);
        if (![currentCatalogKeys containsObject:stableKey]) continue;
        if (!stableKey.length || [seenFavoriteKeys containsObject:stableKey]) continue;
        TPKEmote *item = [self _pickerEmoteForDescriptor:descriptor];
        if (!item) continue;
        [seenFavoriteKeys addObject:stableKey];
        [favorites addObject:item];
    }
    [favorites sortUsingComparator:TPKPickerEmoteSizeComparator];
    BOOL hasProviderEmotes = NO;
    for (NSArray *items in providerArrays.allValues) {
        if (items.count) { hasProviderEmotes = YES; break; }
    }
    BOOL hasProviderState = hasSyntheticProviderState;
    for (NSInteger provider = TPKEmoteProviderIDTPK;
         provider <= TPKEmoteProviderIDFFZ; provider++) {
        TPKEmoteProviderState state =
            [catalog snapshotForProvider:(TPKEmoteProviderID)provider].state;
        if (state != TPKEmoteProviderStateIdle) { hasProviderState = YES; break; }
    }
    // Keep provider tabs available while loading; never show 7TV cache under BTTV or FFZ.
    BOOL useProviderCatalog = hasProviderEmotes || hasProviderState;
    self.pickerProviderEmotes = useProviderCatalog ? providerArrays.copy : @{};
    self.pickerProviderSections = useProviderCatalog ? providerSections.copy : @{};
    self.pickerCatalogFavorites = favorites.copy;
    // Keep legacy favorites in sync so removed items leave the Favorites tab.
    if (useProviderCatalog) self.emotePickerFavoriteEmotes = favorites.copy;
    self.pickerCatalogArraysDirty = NO;
    [self _tpk_normalizeActivePickerTab];
}

- (void)_tpk_reloadCatalogSnapshotReloadCollection:(BOOL)reloadCollection {
    NSAssert([NSThread isMainThread], @"Le snapshot du picker touche UIKit");
    UICollectionView *collectionView = self.emoteCollectionView;
    NSString *anchorEmoteKey = nil;
    CGFloat anchorViewportY = 0;
    CGPoint previousOffset = collectionView.contentOffset;
    if (reloadCollection && collectionView && !collectionView.hidden) {
        NSArray<NSIndexPath *> *visible = [collectionView.indexPathsForVisibleItems
            sortedArrayUsingSelector:@selector(compare:)];
        NSIndexPath *anchorPath = visible.firstObject;
        TPKEmote *anchorEmote = anchorPath
            ? [self _emoteForIndexPath:anchorPath] : nil;
        UICollectionViewLayoutAttributes *attributes = anchorPath
            ? [collectionView layoutAttributesForItemAtIndexPath:anchorPath] : nil;
        NSString *stableAnchorKey = TPKPickerStableEmoteKey(anchorEmote);
        if (stableAnchorKey.length && attributes) {
            anchorEmoteKey = [stableAnchorKey copy];
            anchorViewportY = CGRectGetMinY(attributes.frame) - collectionView.contentOffset.y;
        }
    }

    // Les snapshots provider-aware sont la seule source de vérité du picker.
    if (self.pickerCatalogArraysDirty || !self.pickerProviderSections.count)
        [self _tpk_applyProviderCatalogArrays];
    // Recheck the initial tab after each snapshot; preserve explicit tab choices.
    [self _tpk_selectInitialProviderIfNeeded];
    NSMutableArray *catalogAll = [NSMutableArray array];
    for (NSArray *items in self.pickerProviderEmotes.allValues)
        [catalogAll addObjectsFromArray:items];
    self.emotePickerAllEmotes = catalogAll.count ? catalogAll.copy : @[];
    self.emotePickerEmotes    = self.emotePickerAllEmotes;
    [self _updatePickerArraysForSearch:self.emoteSearchField.text ?: @""];
    if (collectionView) {
        UICollectionViewFlowLayout *flowLayout =
            (UICollectionViewFlowLayout *)collectionView.collectionViewLayout;
        flowLayout.headerReferenceSize = CGSizeZero;
    }
    if (reloadCollection && self.emoteCollectionView) {
        [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
        [self.emoteCollectionView.collectionViewLayout invalidateLayout];
        [self.emoteCollectionView layoutIfNeeded];

        CGFloat targetY = previousOffset.y;
        if (anchorEmoteKey.length) {
            NSIndexPath *newPath = nil;
            if (self.pickerUsesCatalogSections) {
                for (NSInteger sectionIndex = 0;
                     sectionIndex < (NSInteger)self.pickerDisplaySections.count && !newPath;
                     sectionIndex++) {
                    TPKPickerDisplaySection *section =
                        self.pickerDisplaySections[(NSUInteger)sectionIndex];
                    NSString *sectionKey = [self _tpk_displaySectionKey:section];
                    if ([self.pickerCollapsedSections[sectionKey] boolValue]) continue;
                    NSUInteger itemIndex = [section.items indexOfObjectPassingTest:
                        ^BOOL(TPKEmote *emote, __unused NSUInteger index, __unused BOOL *stop) {
                            return [TPKPickerStableEmoteKey(emote)
                                isEqualToString:anchorEmoteKey];
                        }];
                    if (itemIndex != NSNotFound)
                        newPath = [NSIndexPath indexPathForItem:(NSInteger)itemIndex
                                                      inSection:sectionIndex];
                }
            } else {
                NSUInteger newIndex = [self.emotePickerEmotes
                    indexOfObjectPassingTest:^BOOL(TPKEmote *emote,
                                                    __unused NSUInteger index,
                                                    __unused BOOL *stop) {
                        return [TPKPickerStableEmoteKey(emote)
                            isEqualToString:anchorEmoteKey];
                    }];
                if (newIndex != NSNotFound)
                    newPath = [NSIndexPath indexPathForItem:(NSInteger)newIndex inSection:0];
            }
            if (newPath) {
                UICollectionViewLayoutAttributes *attributes =
                    [self.emoteCollectionView layoutAttributesForItemAtIndexPath:newPath];
                if (attributes) targetY = CGRectGetMinY(attributes.frame) - anchorViewportY;
            }
        }
        UIEdgeInsets inset = self.emoteCollectionView.adjustedContentInset;
        CGFloat minimumY = -inset.top;
        CGFloat maximumY = MAX(minimumY,
            self.emoteCollectionView.contentSize.height - self.emoteCollectionView.bounds.size.height +
            inset.bottom);
        CGPoint restoredOffset = self.emoteCollectionView.contentOffset;
        restoredOffset.y = MIN(maximumY, MAX(minimumY, targetY));
        [self.emoteCollectionView setContentOffset:restoredOffset animated:NO];
    }
}

- (void)_tpk_applyCatalogUpdateNow {
    self.pickerCatalogReloadPending = NO;
    [self _tpk_reloadCatalogSnapshotReloadCollection:YES];
    [self _tpk_prewarmPickerViewportImages];

    // Avoid a duplicate layout pass; the reload already schedules one.
}

- (void)_tpk_appearanceDidChange:(NSNotification *)notification {
    if (!TPKChatAppearanceConfig.sharedConfig.pickerButtonEnabled &&
        self.emotePickerView && !self.emotePickerView.hidden) [self _hideEmotePicker];
}

- (void)_tpk_emoteCatalogDidUpdate:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pickerCatalogArraysDirty = YES;
        [self invalidateSortCache];
        if (!self.emotePickerView || self.emotePickerView.hidden) return;
        if (self.pickerScrollInProgress || self.emoteCollectionView.isTracking ||
            self.emoteCollectionView.isDragging || self.emoteCollectionView.isDecelerating) {
            self.pickerCatalogReloadPending = YES;
            return;
        }
        // Apply the first update immediately and coalesce the rest.
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - self.pickerCatalogLastApplyTime < 0.3) {
            self.pickerCatalogReloadPending = YES;
            if (!self.pickerCatalogCoalesceFlushArmed) {
                self.pickerCatalogCoalesceFlushArmed = YES;
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    strongSelf.pickerCatalogCoalesceFlushArmed = NO;
                    if (!strongSelf.pickerCatalogReloadPending) return;
                    if (!strongSelf.emotePickerView || strongSelf.emotePickerView.hidden) return;
                    if (strongSelf.pickerScrollInProgress || strongSelf.emoteCollectionView.isTracking ||
                        strongSelf.emoteCollectionView.isDragging || strongSelf.emoteCollectionView.isDecelerating) {
                        return; // Apply the pending update after scrolling.
                    }
                    [strongSelf _tpk_applyCatalogUpdateNow];
                    [strongSelf _tpk_activateVisiblePickerAnimations];
                    strongSelf.pickerCatalogLastApplyTime = CFAbsoluteTimeGetCurrent();
                });
            }
            return;
        }
        [self _tpk_applyCatalogUpdateNow];
        [self _tpk_activateVisiblePickerAnimations];
        self.pickerCatalogLastApplyTime = now;
    });
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // Discard deferred updates on close; reopening rebuilds the snapshot.
    self.pickerCatalogReloadPending = NO;
    // Reset state first so an empty search can't restore a stale tab.
    self.emoteSearchField.text = @"";
    self.pickerIsSearching = NO;
    // Choose the opening tab before provider notifications arrive.
    self.pickerOpeningLocationExplicit = [self _tpk_applyConfiguredPickerOpeningLocation];
    self.pickerInitialProviderSelectionPending = !self.pickerOpeningLocationExplicit;
    if (!self.pickerOpeningLocationExplicit) {
        self.pickerActiveTab = [TPKEmoteProviderSettings mixedPickerEnabled]
            ? TPKPickerTabAll : TPKPickerTabTPK;
    }

    // Build the cached snapshot before scheduling network requests.
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    [self _tpk_reloadCatalogSnapshotReloadCollection:NO];

    // Request providers after showing the cached snapshot.
    [catalog loadGlobalProviders];
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    if (channelID.length) [catalog loadChannelProvidersForTwitchID:channelID];

    // ── Onglet de départ : Favoris s'il y a un favori de la chaîne courante, sinon 7TV/Channel — revérifié à CHAQUE ouverture.
    if (!self.pickerOpeningLocationExplicit &&
        (self.pickerCatalogFavorites.count > 0 || self.emotePickerFavoriteEmotes.count > 0)) {
        self.pickerActiveTab = TPKPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
    }
    // Resolve the initial tab before creating the picker view.
    [self _tpk_selectInitialProviderIfNeeded];
    [self _tpk_normalizeActivePickerTab];
    [self _updatePickerArraysForSearch:@""]; // Refresh the array for the selected tab.

    // ── Créer le picker si besoin ─────────────────────────────────────
    // Recalculate size for the current orientation.
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGFloat pickerH = [self _tpk_resolvedGridHeight];
    CGRect pickerFrame = CGRectMake(0, 0, screenSz.width, pickerH);
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame];
    }
    self.emotePickerView.frame = pickerFrame;
    // Refresh the channel avatar when opening the picker.
    [self _tpk_refreshChannelAvatarIfNeeded];
    // Reposition the grid and controls for the current orientation and tab.
    [self _tpk_relayoutPickerForSize:pickerFrame.size];

    // Clear search; the tab's model is already up to date.
    self.emoteSearchField.text = @"";
    [self _tpk_updateSearchClearVisibility];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    // Restore the content offset after presentation.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    [self _tpk_prewarmPickerViewportImages];

    // ── inputView = picker (keyboard-replacement mode) ──────────────────────
    // Use the picker as inputView while keeping TextEntryView first responder.
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        // Set the picker as the keyboard input view.
        self.emotePickerView.hidden = NO;
        self.emotePickerView.translatesAutoresizingMaskIntoConstraints = NO;
        tv.inputView = self.emotePickerView;
        tv.inputAccessoryView = nil;
        // Become first responder to show the picker.
        if (!tv.isFirstResponder) {
            [tv becomeFirstResponder];
        }
        // Reload to apply the new input view.
        [tv reloadInputViews];
        // Restore the top offset after UIKit lays out the input view.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.emoteCollectionView) return;
            [strongSelf.emoteCollectionView setContentOffset:CGPointZero animated:NO];
            [strongSelf _tpk_activateVisiblePickerAnimations];
        });
    } else {
        [[TPKManager sharedManager] log:@"⚠️ TextEntryView nil — fallback fenêtre flottante"];
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (keyWindow) {
            // Use frame-based layout when the picker is a window subview.
            self.emotePickerView.translatesAutoresizingMaskIntoConstraints = YES;
            CGFloat ph = [self _tpk_resolvedGridHeight];
            self.emotePickerView.frame = CGRectMake(0,
                keyWindow.bounds.size.height - ph - 56,
                keyWindow.bounds.size.width, ph);
            [keyWindow addSubview:self.emotePickerView];
            self.emotePickerView.hidden = NO;
            [self _tpk_relayoutPickerForSize:self.emotePickerView.bounds.size];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _tpk_activateVisiblePickerAnimations];
            });
        }
    }
}
- (void)_createEmotePickerViewWithFrame:(CGRect)frame {

    // ── Palette ─────────────────────────────────────────────────────────
    // Use the shared picker palette and Twitch accent.
    UIColor *bgColor   = tpk_pickerBgColor();
    UIColor *cardColor = tpk_pickerCardColor();
    UIColor *sepColor  = tpk_pickerSepColor();
    UIColor *textColor = [UIColor whiteColor];
    UIColor *subColor  = [UIColor colorWithWhite:0.55 alpha:1.0];
    UIColor *accent    = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];    // violet Twitch

    // ── Conteneur principal ────────────────────────────────────────────────
    TPKPickerContainerView *picker =
        [[TPKPickerContainerView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    self.emotePickerView = picker;

    __weak typeof(self) weakSelf = self;
    __weak TPKPickerContainerView *weakPicker = picker;
    picker.didAttachToWindow = ^{
        // Create cells after the keyboard finishes attaching the picker.
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            TPKPickerContainerView *strongPicker = weakPicker;
            if (!strongSelf || !strongPicker.window ||
                strongSelf.emotePickerView != strongPicker || strongPicker.hidden) return;
            [strongSelf.emoteCollectionView layoutIfNeeded];
            [strongSelf _tpk_activateVisiblePickerAnimations];
        });
    };

    // ── Collection View — occupe 100% du picker ─────────────────────────────
    // Reserve space for floating controls with section insets.
    CGFloat topInset = kTPKPickerFloatMargin; // Keep the first row below floating controls.
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection         = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 3;
    layout.minimumLineSpacing      = 3;
    layout.sectionInset            = UIEdgeInsetsMake(topInset, 6, kTPKPickerBottomZoneH, 6);
    // Sous-catégories = capsules flottantes : aucune ligne d'en-tête réservée dans la grille.
    layout.headerReferenceSize     = CGSizeZero;

    UICollectionView *cv = [[UICollectionView alloc]
        initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)
 collectionViewLayout:layout];
    cv.backgroundColor        = bgColor;
    cv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cv.dataSource             = (id<UICollectionViewDataSource>)self;
    cv.delegate               = (id<UICollectionViewDelegate>)self;
    cv.alwaysBounceVertical   = YES;
    cv.alwaysBounceHorizontal = NO;
    cv.showsHorizontalScrollIndicator = NO;
    cv.showsVerticalScrollIndicator   = YES;
    // Load images only for cells handled by cellFor and willDisplay.
    if (@available(iOS 10.0, *)) cv.prefetchingEnabled = NO;

    [cv registerClass:[TPKEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellID];
    [cv registerClass:[TPKPickerSectionHeaderView class]
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
           withReuseIdentifier:@"TPKPickerSectionHeader"];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    // ── Capsule provider (flottante, bas gauche) — Favoris / Tous / 7TV / BTTV / FFZ ──
    BOOL mixedPicker = [TPKEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kTPKPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    CGFloat bottomRowY = frame.size.height - kTPKPickerFloatMargin - kTPKPickerSearchH
                          - kTPKPickerFloatGap - kTPKPickerFloatSize;
    UIView *tabCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin, bottomRowY, tabCapsuleW, kTPKPickerFloatSize)];
    tabCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    tabCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    tabCapsule.clipsToBounds = YES;
    tabCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerTabCapsuleView = tabCapsule;
    [picker addSubview:tabCapsule];

    UIView *tabIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize)];
    tabIndicator.backgroundColor = accent;
    tabIndicator.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    [tabCapsule addSubview:tabIndicator];
    self.pickerTabIndicatorView = tabIndicator;

    UIImage *_tabLogoImg = s_tpkPickerTabLogo;
    if (!_tabLogoImg) {
        NSData *_tabLogoData = [[NSData alloc]
            initWithBase64EncodedString:kTPKLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        _tabLogoImg = [[UIImage imageWithData:_tabLogoData scale:3.0]
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    NSData *_bttvLogoData = nil, *_ffzLogoData = nil;
    UIImage *_bttvLogoImg = nil, *_ffzLogoImg = nil;
    if (!s_tpkPickerBTTVLogo || !s_tpkPickerFFZLogo) {
        _bttvLogoData = [[NSData alloc]
            initWithBase64EncodedString:kTPKBTTVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        _bttvLogoImg = [[UIImage imageWithData:_bttvLogoData scale:3.0]
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        _ffzLogoData = [[NSData alloc]
            initWithBase64EncodedString:kTPKFFZLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        _ffzLogoImg = [[UIImage imageWithData:_ffzLogoData scale:3.0]
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    // Slightly enlarge BTTV and FFZ logos to match the 7TV mark visually.
    UIImage *bttvLogo = s_tpkPickerBTTVLogo ?: TPKPickerScaledProviderLogo(_bttvLogoImg, 16.0);
    UIImage *ffzLogo = s_tpkPickerFFZLogo ?: TPKPickerScaledProviderLogo(_ffzLogoImg, 16.0);
    UIImageSymbolConfiguration *providerFallbackCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    UIImage *bttvFallback = [UIImage systemImageNamed:@"b.circle.fill"
                                      withConfiguration:providerFallbackCfg];
    UIImage *ffzFallback = [UIImage systemImageNamed:@"f.circle.fill"
                                      withConfiguration:providerFallbackCfg];

    [self.pickerTabButtons removeAllObjects];

    // Bouton 1 — Favoris
    UIImageSymbolConfiguration *starCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    UIButton *favBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    favBtn.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
    favBtn.tag = TPKPickerTabFavorites;
    [favBtn setImage:[UIImage systemImageNamed:@"star.fill" withConfiguration:starCfg] forState:UIControlStateNormal];
    [favBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:favBtn];
    [self.pickerTabButtons addObject:favBtn];

    // Bouton 2 — Tous (logo TwitchPlusK).
    UIButton *allBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    allBtn.frame = CGRectMake(kTPKPickerFloatSize, 0,
                              kTPKPickerFloatSize, kTPKPickerFloatSize);
    allBtn.tag = TPKPickerTabAll;
    NSData *tpkData = nil;
    UIImage *tpkLogo = s_tpkPickerTPKLogo;
    if (!tpkLogo) {
        tpkData = [[NSData alloc]
            initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
        tpkLogo = TPKPickerAspectFitProviderLogo(
            [UIImage imageWithData:tpkData scale:UIScreen.mainScreen.scale], 22.0, 14.0);
    }
    if (!tpkLogo) {
        UIImageSymbolConfiguration *allCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        tpkLogo = [UIImage systemImageNamed:@"square.stack.3d.up.fill"
                              withConfiguration:allCfg];
    }
    [allBtn setImage:tpkLogo forState:UIControlStateNormal];
    allBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [allBtn addTarget:self action:@selector(_pickerTabTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:allBtn];
    [self.pickerTabButtons addObject:allBtn];

    // Bouton 3 — 7TV (logo provider).
    UIButton *channelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    channelBtn.frame = CGRectMake(kTPKPickerFloatSize * 2.0, 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
    channelBtn.tag = TPKPickerTabTPK;
    [channelBtn setImage:_tabLogoImg forState:UIControlStateNormal];
    channelBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [channelBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:channelBtn];
    [self.pickerTabButtons addObject:channelBtn];
    // BTTV and FFZ use bundled logos with SF Symbol fallbacks.
    NSArray *providerButtons = @[
        @[@(TPKPickerTabBTTV), bttvLogo ?: bttvFallback],
        @[@(TPKPickerTabFFZ), ffzLogo ?: ffzFallback],
    ];
    for (NSUInteger idx = 0; idx < providerButtons.count; idx++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(kTPKPickerFloatSize * (idx + 3), 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
        button.tag = [providerButtons[idx][0] integerValue];
        [button setImage:providerButtons[idx][1] forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [button addTarget:self action:@selector(_pickerTabTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [tabCapsule addSubview:button];
        [self.pickerTabButtons addObject:button];
    }

    // Channel/Global subcategory capsule; Shared and Sets are combined.
    UIView *subcategoryCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin,
                   bottomRowY - kTPKPickerSubcategoryGap - kTPKPickerFloatSize,
                   kTPKPickerFloatSize * 2.0,
                   kTPKPickerFloatSize)];
    subcategoryCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    subcategoryCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    subcategoryCapsule.clipsToBounds = YES;
    subcategoryCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerSubcategoryCapsuleView = subcategoryCapsule;
    [picker addSubview:subcategoryCapsule];

    UIButton *subcategoryChannel = [UIButton buttonWithType:UIButtonTypeSystem];
    subcategoryChannel.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
    subcategoryChannel.tag = 1;
    subcategoryChannel.accessibilityLabel = @"Channel emotes";
    subcategoryChannel.imageView.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *subcategoryIconCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [subcategoryChannel setImage:[UIImage systemImageNamed:@"person.crop.circle.fill"
                                         withConfiguration:subcategoryIconCfg]
                         forState:UIControlStateNormal];
    [subcategoryChannel addTarget:self action:@selector(_pickerSubcategoryTapped:)
                   forControlEvents:UIControlEventTouchUpInside];
    [subcategoryCapsule addSubview:subcategoryChannel];
    self.pickerSubcategoryChannelBtn = subcategoryChannel;

    UIButton *subcategoryGlobal = [UIButton buttonWithType:UIButtonTypeSystem];
    subcategoryGlobal.frame = CGRectMake(kTPKPickerFloatSize, 0,
                                         kTPKPickerFloatSize,
                                         kTPKPickerFloatSize);
    subcategoryGlobal.tag = 2;
    subcategoryGlobal.accessibilityLabel = @"Global emotes";
    subcategoryGlobal.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [subcategoryGlobal addTarget:self action:@selector(_pickerSubcategoryTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    [subcategoryCapsule addSubview:subcategoryGlobal];
    self.pickerSubcategoryGlobalBtn = subcategoryGlobal;
    [self _tpk_resetChannelButtonToPlaceholder];

    [self _tpk_updateTabButtonHighlight];

    CGFloat toolsCapsuleW = kTPKPickerFloatSize;
    UIView *toolsCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(frame.size.width - kTPKPickerFloatMargin - toolsCapsuleW, bottomRowY,
                   toolsCapsuleW, kTPKPickerFloatSize)];
    toolsCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    toolsCapsule.layer.cornerRadius = kTPKPickerFloatSize / 2.0;
    toolsCapsule.clipsToBounds = YES;
    toolsCapsule.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.pickerToolsCapsuleView = toolsCapsule;
    [picker addSubview:toolsCapsule];

    // Open settings after closing the picker.
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 0, kTPKPickerFloatSize, kTPKPickerFloatSize);
    UIImageSymbolConfiguration *settingsCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:settingsCfg]
                 forState:UIControlStateNormal];
    settingsBtn.tintColor = subColor;
    [settingsBtn addTarget:self action:@selector(_pickerSettingsTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:settingsBtn];
    self.pickerSettingsBtn = settingsBtn;



    // ── Capsule de recherche (flottante, tout en bas, pleine largeur) ──────
    CGFloat searchY = frame.size.height - kTPKPickerFloatMargin - kTPKPickerSearchH;
    UIView *searchCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kTPKPickerFloatMargin, searchY, frame.size.width - kTPKPickerFloatMargin * 2, kTPKPickerSearchH)];
    searchCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    searchCapsule.layer.cornerRadius = kTPKPickerSearchH / 2.0;
    searchCapsule.clipsToBounds = YES;
    searchCapsule.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.pickerSearchCapsuleView = searchCapsule;
    [picker addSubview:searchCapsule];

    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(0, 0, searchCapsule.bounds.size.width, kTPKPickerSearchH)];
    search.placeholder     = L(@"placeholder_search_picker");
    search.font            = [UIFont systemFontOfSize:13];
    search.returnKeyType   = UIReturnKeyDone;
    search.clearButtonMode = UITextFieldViewModeNever; // Use the custom clear button below.
    search.backgroundColor = [UIColor clearColor];
    search.textColor       = textColor;
    search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:L(@"placeholder_search_picker")
            attributes:@{NSForegroundColorAttributeName: subColor}];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Icône loupe intégrée à gauche du champ
    UIImageSymbolConfiguration *searchCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    UIImageView *searchIcon = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:searchCfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    searchIcon.tintColor = subColor;
    searchIcon.contentMode = UIViewContentModeCenter;
    UIView *searchLeftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 20)];
    searchIcon.frame = CGRectMake(12, 0, 16, 20);
    [searchLeftView addSubview:searchIcon];
    search.leftView = searchLeftView;
    search.leftViewMode = UITextFieldViewModeAlways;

    // Show the clear button only when search text is present.
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(0, 0, 28, kTPKPickerSearchH);
    UIImageSymbolConfiguration *clearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [clearBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:clearCfg]
              forState:UIControlStateNormal];
    clearBtn.tintColor = subColor;
    clearBtn.hidden = YES;
    [clearBtn addTarget:self action:@selector(_pickerSearchClearTapped)
       forControlEvents:UIControlEventTouchUpInside];
    self.pickerSearchClearBtn = clearBtn;
    UIView *searchRightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, kTPKPickerSearchH)];
    clearBtn.frame = CGRectMake(2, 0, 28, kTPKPickerSearchH);
    [searchRightView addSubview:clearBtn];
    search.rightView = searchRightView;
    search.rightViewMode = UITextFieldViewModeAlways;

    // Intercept focus changes so search doesn't close the picker.
    search.delegate = (id<UITextFieldDelegate>)self;
    [search addTarget:self action:@selector(_emoteSearchChanged:)
     forControlEvents:UIControlEventEditingChanged];
    self.emoteSearchField = search;
    [searchCapsule addSubview:search];

    [picker bringSubviewToFront:tabCapsule];
    [picker bringSubviewToFront:subcategoryCapsule];
    [picker bringSubviewToFront:toolsCapsule];

    // UIKit attaches this view as inputView.
}

// Create a floating circular button matching the picker capsules.
- (UIButton *)_tpk_makeFloatingPillWithFrame:(CGRect)frame cardColor:(UIColor *)cardColor {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    btn.layer.cornerRadius = frame.size.height / 2.0;
    btn.clipsToBounds = YES;
    return btn;
}

// ── Barre d'onglets — helpers ────────────────────────────────────────────

// Keep the selected tab valid when providers or catalogue contents change.
// Mixed mode reuses the five buttons and hides unavailable providers.
- (void)_tpk_updatePickerTabButtonLayout {
    if (!self.pickerTabCapsuleView || !self.pickerTabButtons.count) return;

    BOOL mixedMode = [TPKEmoteProviderSettings mixedPickerEnabled];
    NSArray<NSNumber *> *visibleTags = mixedMode
        ? @[@(TPKPickerTabFavorites), @(TPKPickerTabAll)]
        : @[@(TPKPickerTabFavorites), @(TPKPickerTabTPK),
            @(TPKPickerTabBTTV), @(TPKPickerTabFFZ)];
    NSInteger slot = 0;
    for (UIButton *button in self.pickerTabButtons) {
        BOOL visible = [visibleTags containsObject:@(button.tag)];
        button.hidden = !visible;
        if (!visible) continue;
        button.frame = CGRectMake(kTPKPickerFloatSize * slot, 0,
                                  kTPKPickerFloatSize, kTPKPickerFloatSize);
        slot++;
    }

    CGRect capsuleFrame = self.pickerTabCapsuleView.frame;
    capsuleFrame.size.width = kTPKPickerFloatSize * slot;
    self.pickerTabCapsuleView.frame = capsuleFrame;
}

- (void)_tpk_normalizeActivePickerTab {
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    BOOL mixedMode = [TPKEmoteProviderSettings mixedPickerEnabled];
    BOOL (^available)(NSInteger) = ^BOOL(NSInteger tab) {
        // Let provider order choose a tab when Favorites is empty.
        if (tab == TPKPickerTabFavorites)
            return self.pickerCatalogFavorites.count > 0 ||
                   self.emotePickerFavoriteEmotes.count > 0;
        if (tab == TPKPickerTabAll) {
            if (!mixedMode) return NO;
            if (!providerMode && !self.pickerOpeningLocationExplicit &&
                !self.emotePickerAllEmotes.count) return NO;
            return YES;
        }
        if (mixedMode || ![self _tpk_pickerTabIsProvider:tab]) return NO;
        NSInteger provider = tab == TPKPickerTabTPK
            ? TPKEmoteProviderIDTPK
            : (tab == TPKPickerTabBTTV ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
        // Never show legacy 7TV items under BTTV or FFZ.
        return providerMode || self.pickerOpeningLocationExplicit ||
            provider == TPKEmoteProviderIDTPK;
    };

    if (available(self.pickerActiveTab)) return;
    NSInteger fallback = TPKPickerTabFavorites;
    if (!(self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count)) {
        if (mixedMode && available(TPKPickerTabAll)) {
            fallback = TPKPickerTabAll;
        } else {
        for (NSNumber *providerNumber in [self _tpk_providerIDsInPriorityOrder]) {
            TPKEmoteProviderID provider = (TPKEmoteProviderID)providerNumber.integerValue;
            NSInteger tab = provider == TPKEmoteProviderIDTPK
                ? TPKPickerTabTPK
                : (provider == TPKEmoteProviderIDBTTV
                   ? TPKPickerTabBTTV : TPKPickerTabFFZ);
            if (available(tab)) { fallback = tab; break; }
        }
        }
    }
    self.pickerActiveTab = fallback;
}

- (BOOL)_tpk_selectInitialProviderIfNeeded {
    if (self.pickerOpeningLocationExplicit) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    if (!self.pickerInitialProviderSelectionPending || self.pickerIsSearching)
        return NO;

    // Select Favorites once when late-arriving favorites appear.
    if (self.pickerCatalogFavorites.count || self.emotePickerFavoriteEmotes.count) {
        BOOL changed = self.pickerActiveTab != TPKPickerTabFavorites;
        self.pickerActiveTab = TPKPickerTabFavorites;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // Keep All selected initially in aggregate mode.
    if ([TPKEmoteProviderSettings mixedPickerEnabled] &&
        (self.pickerProviderEmotes.count || self.emotePickerAllEmotes.count)) {
        BOOL changed = self.pickerActiveTab != TPKPickerTabAll;
        self.pickerActiveTab = TPKPickerTabAll;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }

    // A legacy-only snapshot already represents the 7TV fallback.
    if (!self.pickerProviderEmotes.count) {
        if (self.emotePickerAllEmotes.count || self.emotePickerEmotes.count)
            self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    if (self.pickerActiveTab == TPKPickerTabAll) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }
    TPKEmoteProviderID activeProvider = [self _tpk_providerForPickerTab:
        self.pickerActiveTab];
    NSArray *activeItems = self.pickerProviderEmotes[@(activeProvider)] ?: @[];
    if (activeItems.count) {
        self.pickerInitialProviderSelectionPending = NO;
        return NO;
    }

    // Prefer the first provider with emotes in 7TV, BTTV, FFZ order.
    for (NSNumber *providerNumber in [self _tpk_providerIDsInPriorityOrder]) {
        TPKEmoteProviderID provider = (TPKEmoteProviderID)providerNumber.integerValue;
        NSArray *items = self.pickerProviderEmotes[@((TPKEmoteProviderID)provider)] ?: @[];
        if (!items.count) continue;
        NSInteger tab = provider == TPKEmoteProviderIDTPK
            ? TPKPickerTabTPK
            : (provider == TPKEmoteProviderIDBTTV
               ? TPKPickerTabBTTV : TPKPickerTabFFZ);
        BOOL changed = self.pickerActiveTab != tab;
        self.pickerActiveTab = tab;
        self.pickerInitialProviderSelectionPending = NO;
        return changed;
    }
    return NO;
}

// Update tab icon tint and the selected-tab indicator.
- (void)_tpk_updateTabButtonHighlight {
    [self _tpk_updatePickerTabButtonLayout];
    [self _tpk_normalizeActivePickerTab];
    BOOL providerMode = self.pickerProviderEmotes.count > 0 || self.pickerUsesCatalogSections;
    UIColor *activeTint   = [UIColor whiteColor];
    UIColor *inactiveTint = [UIColor colorWithWhite:0.55 alpha:1.0];
    for (UIButton *btn in self.pickerTabButtons) {
        BOOL isActive = (btn.tag == self.pickerActiveTab);
        if (btn.tag == TPKPickerTabFavorites) {
            // Keep Favorites visible but dimmed when the current channel has none.
            BOOL hasFavorites = self.pickerCatalogFavorites.count > 0 ||
                self.emotePickerFavoriteEmotes.count > 0;
            btn.enabled = hasFavorites;
            btn.alpha = hasFavorites ? 1.0 : 0.25;
            btn.tintColor = (hasFavorites && isActive) ? activeTint : inactiveTint;
            continue;
        }
        if ([self _tpk_pickerTabIsProvider:btn.tag]) {
            NSInteger provider = btn.tag == TPKPickerTabTPK
                ? TPKEmoteProviderIDTPK
                : (btn.tag == TPKPickerTabBTTV ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
            BOOL enabled = providerMode || provider == TPKEmoteProviderIDTPK;
            btn.enabled = enabled;
            if (!enabled) { btn.alpha = 0.25; continue; }
            // Reset alpha when re-enabling a tab button.
            btn.alpha = 1.0;
        }
        if ([self _tpk_pickerTabIsProvider:btn.tag]) {
            // Use opacity to indicate provider-tab availability.
            btn.alpha = isActive ? 1.0 : 0.55;
        } else {
            btn.tintColor = isActive ? activeTint : inactiveTint;
        }
    }
    for (UIButton *btn in self.pickerTabButtons) {
        if (btn.tag == self.pickerActiveTab) {
            self.pickerTabIndicatorView.frame = btn.frame;
            break;
        }
    }
    [self _tpk_updateSubcategoryCapsule];
}

- (CGSize)pickerHostSize {
    UIWindow *hostWindow = self.emotePickerTextEntryView.window
        ?: self.emotePickerTextField.window
        ?: self.emotePickerView.window;
return hostWindow ? hostWindow.bounds.size : UIScreen.mainScreen.bounds.size;
}

- (BOOL)pickerHostIsLandscape {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (screen.width > 0 && screen.height > 0) return screen.width > screen.height;
    CGSize host = [self pickerHostSize];
    return host.width > host.height;
}

// Return the grid height available in the current orientation.
- (CGFloat)_tpk_resolvedGridHeight {
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    CGFloat wanted = [self pickerHostIsLandscape]
        ? cfg.pickerHeightLandscape : cfg.pickerHeightPortrait;
    // Bound the grid using the window height.
    CGFloat ceiling = MAX(kTPKPickerMinUsableH,
                          [self pickerHostSize].height - kTPKPickerChromeReserveH);
    return MIN(wanted, ceiling);
}

// Recalculate picker frames after orientation or tab changes.
- (void)_tpk_relayoutPickerForSize:(CGSize)size {
    if (!self.emotePickerView) return;

    // Refresh the container's Auto Layout height when its size changes.
    [(TPKPickerContainerView *)self.emotePickerView setPreferredHeight:size.height];
    // Invalidate cached cell sizes after a resize.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    self.emoteCollectionView.frame = CGRectMake(0, 0, size.width, size.height);

    CGFloat bottomRowY = size.height - kTPKPickerFloatMargin - kTPKPickerSearchH
                          - kTPKPickerFloatGap - kTPKPickerFloatSize;
    BOOL mixedPicker = [TPKEmoteProviderSettings mixedPickerEnabled];
    CGFloat tabCapsuleW = kTPKPickerFloatSize * (mixedPicker ? 2.0 : 4.0);
    self.pickerTabCapsuleView.frame = CGRectMake(kTPKPickerFloatMargin, bottomRowY, tabCapsuleW, kTPKPickerFloatSize);
    self.pickerSubcategoryCapsuleView.frame = CGRectMake(
        kTPKPickerFloatMargin,
        bottomRowY - kTPKPickerSubcategoryGap - kTPKPickerFloatSize,
        kTPKPickerFloatSize * 2.0,
        kTPKPickerFloatSize);
    // Move the settings button between grid and settings layouts.
    CGFloat toolsCapsuleW = kTPKPickerFloatSize;
    CGFloat toolsX = size.width - kTPKPickerFloatMargin - toolsCapsuleW;
    CGFloat toolsY = bottomRowY;
    self.pickerToolsCapsuleView.frame = CGRectMake(toolsX, toolsY, toolsCapsuleW, kTPKPickerFloatSize);
    [self _tpk_updateTabButtonHighlight];

    CGFloat searchY = size.height - kTPKPickerFloatMargin - kTPKPickerSearchH;
    self.pickerSearchCapsuleView.frame = CGRectMake(kTPKPickerFloatMargin, searchY,
                                                      size.width - kTPKPickerFloatMargin * 2, kTPKPickerSearchH);
    self.emoteSearchField.frame = CGRectMake(0, 0, self.pickerSearchCapsuleView.bounds.size.width, kTPKPickerSearchH);

}

// ── Onglets — sélection ───────────────────────────────────────────────────

- (void)_pickerTabTapped:(UIButton *)sender {
// Preserve an explicit tab choice when network results arrive.
    self.pickerInitialProviderSelectionPending = NO;
    self.pickerOpeningLocationExplicit = NO;
    if (self.pickerActiveTab == sender.tag) {
        [self _tpk_persistLastPickerLocation];
        [self _tpk_updateSubcategoryCapsule];
        return; // déjà actif
    }
    self.pickerActiveTab = sender.tag;
    [self _tpk_persistLastPickerLocation];
    [self _tpk_updateTabButtonHighlight];

    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// Clear search and update results without showing the alert.
- (void)_pickerSearchClearTapped {
    self.emoteSearchField.text = @"";
    self.pickerSearchClearBtn.hidden = YES;
    [self _applySearchQuery:@""];
}

// Return the emotes for the active tab.
- (NSArray<TPKEmote *> *)_tpk_currentTabEmotes {
    if (self.pickerProviderEmotes.count > 0) {
        if (self.pickerActiveTab == TPKPickerTabFavorites)
            return self.pickerCatalogFavorites ?: @[];
        if (self.pickerActiveTab == TPKPickerTabAll) {
            NSMutableArray<TPKEmote *> *all = [NSMutableArray array];
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (NSNumber *provider in [self _tpk_providerIDsInPriorityOrder]) {
                for (TPKEmote *item in self.pickerProviderEmotes[provider] ?: @[]) {
                    NSString *key = TPKPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [all addObject:item];
                }
            }
            // Preserve source order for equal items in the aggregate tab.
            [all sortUsingComparator:TPKPickerMixedEmoteSizeComparator];
            return all.copy;
        }
        NSInteger provider = self.pickerActiveTab == TPKPickerTabTPK
            ? TPKEmoteProviderIDTPK
            : (self.pickerActiveTab == TPKPickerTabBTTV
               ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
        return self.pickerProviderEmotes[@(provider)] ?: @[];
    }
    switch (self.pickerActiveTab) {
        case TPKPickerTabAll:
            return self.emotePickerAllEmotes ?: @[];
        case TPKPickerTabTPK:
            // Use the legacy 7TV cache until the provider catalogue loads.
            return self.emotePickerAllEmotes ?: self.emotePickerChannelEmotes;
        case TPKPickerTabBTTV:
        case TPKPickerTabFFZ:
            // Keep legacy 7TV items out of other provider tabs.
            return @[];
        case TPKPickerTabFavorites:
        default:
            return self.emotePickerFavoriteEmotes;
    }
}

// ── Recherche ──────────────────────────────────────────────────────────────

// Filter emotes and update the visible sections.

- (void)_updatePickerArraysForSearch:(NSString *)query {
    // Only typed search queries can trigger automatic tab selection.
    [self _updatePickerArraysForSearch:query autoSelectTab:NO];
}

- (TPKEmoteProviderID)_tpk_providerForPickerTab:(NSInteger)tab {
    switch (tab) {
        case TPKPickerTabBTTV: return TPKEmoteProviderIDBTTV;
        case TPKPickerTabFFZ: return TPKEmoteProviderIDFFZ;
        case TPKPickerTabTPK:
        default: return TPKEmoteProviderIDTPK;
    }
}

- (BOOL)_tpk_pickerTabIsProvider:(NSInteger)tab {
    return tab == TPKPickerTabTPK || tab == TPKPickerTabBTTV ||
        tab == TPKPickerTabFFZ;
}

- (NSArray<NSNumber *> *)_tpk_providerIDsInPriorityOrder {
    return TPKEmoteCatalog.sharedCatalog.providerPriority;
}

- (void)_tpk_persistLastPickerLocation {
    NSString *location = nil;
    NSString *subcategory = nil;
    NSNumber *selectionKey = nil;
    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        location = @"favorites";
    } else if (self.pickerActiveTab == TPKPickerTabAll) {
        subcategory = self.pickerSubcategoryByProvider[@(-1)] ?: @"channel";
        location = [NSString stringWithFormat:@"all:%@", subcategory];
    } else if ([self _tpk_pickerTabIsProvider:self.pickerActiveTab]) {
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:self.pickerActiveTab];
        selectionKey = @(provider);
        subcategory = self.pickerSubcategoryByProvider[selectionKey] ?: @"channel";
        location = [NSString stringWithFormat:@"%@:%@",
                    TPKEmoteProviderKey(provider), subcategory];
    }
    if (location.length)
        [TPKEmoteProviderSettings setLastPickerLocation:location];
}

- (BOOL)_tpk_applyConfiguredPickerOpeningLocation {
    NSString *mode = [TPKEmoteProviderSettings pickerOpeningMode];
    if (!mode.length) return NO;
    self.pickerOpeningLocationExplicit = YES;
    if ([mode isEqualToString:TPKEmotePickerOpeningModeFavorites]) {
        self.pickerActiveTab = TPKPickerTabFavorites;
        return YES;
    }
    if ([mode isEqualToString:TPKEmotePickerOpeningModeTPKChannel] ||
        [mode isEqualToString:TPKEmotePickerOpeningModeBTTVChannel] ||
        [mode isEqualToString:TPKEmotePickerOpeningModeFFZChannel]) {
        if ([TPKEmoteProviderSettings mixedPickerEnabled]) {
            // Open All in aggregate mode to preserve Channel selection.
            self.pickerActiveTab = TPKPickerTabAll;
            self.pickerSubcategoryByProvider[@(-1)] = @"channel";
            return YES;
        }
        NSInteger tab = [mode hasPrefix:@"7tv"] ? TPKPickerTabTPK
            : ([mode hasPrefix:@"bttv"] ? TPKPickerTabBTTV : TPKPickerTabFFZ);
        self.pickerActiveTab = tab;
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:tab];
        self.pickerSubcategoryByProvider[@(provider)] = @"channel";
        return YES;
    }
    if ([mode isEqualToString:TPKEmotePickerOpeningModeLastUsed]) {
        NSString *location = [TPKEmoteProviderSettings lastPickerLocation];
        if ([location isEqualToString:@"favorites"]) {
            self.pickerActiveTab = TPKPickerTabFavorites;
            return YES;
        }
        NSArray<NSString *> *parts = [location componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            NSString *providerKey = parts[0].lowercaseString;
            NSString *subcategory = [parts[1].lowercaseString isEqualToString:@"global"]
                ? @"global" : @"channel";
            if ([providerKey isEqualToString:@"all"]) {
                self.pickerActiveTab = TPKPickerTabAll;
                self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                return YES;
            }
            TPKEmoteProviderID provider = TPKEmoteProviderFromIdentifier(providerKey);
            if (provider >= TPKEmoteProviderIDTPK && provider <= TPKEmoteProviderIDFFZ) {
                if ([TPKEmoteProviderSettings mixedPickerEnabled]) {
                    self.pickerActiveTab = TPKPickerTabAll;
                    self.pickerSubcategoryByProvider[@(-1)] = subcategory;
                    return YES;
                }
                self.pickerActiveTab = provider == TPKEmoteProviderIDTPK
                    ? TPKPickerTabTPK
                    : (provider == TPKEmoteProviderIDBTTV ? TPKPickerTabBTTV : TPKPickerTabFFZ);
                self.pickerSubcategoryByProvider[@(provider)] = subcategory;
                return YES;
            }
        }
        // Default to Favorites when no prior tab is saved.
        self.pickerOpeningLocationExplicit = NO;
        return NO;
    }
    self.pickerOpeningLocationExplicit = NO;
    return NO;
}

- (NSString *)_tpk_displaySectionKey:(TPKPickerDisplaySection *)section {
    NSInteger provider = section.provider;
    return [NSString stringWithFormat:@"%ld:%@", (long)provider,
            section.identifier ?: @""];
}

- (BOOL)_tpk_sectionIsChannel:(TPKPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    // Keep BTTV Shared and Set emotes in the Channel section.
    if (section.kind == TPKEmoteSectionKindChannel ||
        section.kind == TPKEmoteSectionKindShared) return YES;
    if (section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier.lowercaseString hasPrefix:@"global-set:"]) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"channel"] || [identifier containsString:@"channel"];
}

- (BOOL)_tpk_sectionIsGlobal:(TPKPickerDisplaySection *)section {
    if (!section || [section.identifier isEqualToString:@"provider-state"]) return NO;
    if (section.kind == TPKEmoteSectionKindGlobal) return YES;
    NSString *title = section.title.lowercaseString ?: @"";
    NSString *identifier = section.identifier.lowercaseString ?: @"";
    return [title containsString:@"global"] || [identifier containsString:@"global"];
}

- (void)_tpk_updateSubcategoryCapsule {
    UIView *capsule = self.pickerSubcategoryCapsuleView;
    UIButton *channelButton = self.pickerSubcategoryChannelBtn;
    UIButton *globalButton = self.pickerSubcategoryGlobalBtn;
    if (!capsule || !channelButton || !globalButton) return;

    BOOL providerTab = [self _tpk_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
    BOOL visible = (providerTab || allTab) && YES;
    capsule.hidden = !visible;
    if (!visible) return;

    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _tpk_providerForPickerTab:self.pickerActiveTab]);
    BOOL hasChannel = NO;
    BOOL hasGlobal = NO;
    NSArray<NSNumber *> *providers = allTab
        ? [self _tpk_providerIDsInPriorityOrder]
        : @[selectionKey];
    for (NSNumber *providerNumber in providers) {
        for (TPKPickerDisplaySection *section in
             self.pickerProviderSections[providerNumber] ?: @[]) {
            BOOL usable = section.items.count > 0 || !section.loaded ||
                section.loading || section.errorMessage.length;
            if (!usable) continue;
            hasChannel |= [self _tpk_sectionIsChannel:section];
            hasGlobal |= [self _tpk_sectionIsGlobal:section];
        }
    }

    // Keep the Channel capsule visible when empty, but disable it.
    channelButton.hidden = NO;
    channelButton.enabled = hasChannel;
    globalButton.hidden = !hasGlobal;
    globalButton.enabled = hasGlobal;

    NSString *selected = self.pickerSubcategoryByProvider[selectionKey];
    // Convert legacy section IDs to Channel or Global.
    BOOL selectedIsChannel = [selected isEqualToString:@"channel"] ||
        (selected.length && ![selected isEqualToString:@"global"] && hasChannel &&
         ![selected.lowercaseString containsString:@"global"]);
    BOOL selectedIsGlobal = [selected isEqualToString:@"global"] ||
        (selected.length && [selected.lowercaseString containsString:@"global"] && hasGlobal);
    selectedIsChannel &= hasChannel;
    selectedIsGlobal &= hasGlobal;
    if (!selectedIsChannel && !selectedIsGlobal) {
        // Prefer Channel when populated; keep Global available while it loads.
        BOOL channelHasItems = NO;
        BOOL globalHasItems = NO;
        for (NSNumber *providerNumber in providers) {
            for (TPKPickerDisplaySection *section in
                 self.pickerProviderSections[providerNumber] ?: @[]) {
                if ([self _tpk_sectionIsChannel:section] && section.items.count) channelHasItems = YES;
                if ([self _tpk_sectionIsGlobal:section] && section.items.count) globalHasItems = YES;
            }
        }
        selected = channelHasItems ? @"channel" :
            (globalHasItems ? @"global" : (hasChannel ? @"channel" : @"global"));
        if (selected.length) self.pickerSubcategoryByProvider[selectionKey] = selected;
        selectedIsChannel = [selected isEqualToString:@"channel"] && hasChannel;
        selectedIsGlobal = [selected isEqualToString:@"global"] && hasGlobal;
    }

    UIColor *accent = tpk_pickerAccentColor();
    UIColor *inactive = [UIColor colorWithWhite:1.0 alpha:0.58];
    channelButton.backgroundColor = selectedIsChannel ? accent : UIColor.clearColor;
    globalButton.backgroundColor = selectedIsGlobal ? accent : UIColor.clearColor;
    channelButton.tintColor = selectedIsChannel ? UIColor.whiteColor : inactive;
    globalButton.tintColor = selectedIsGlobal ? UIColor.whiteColor : inactive;
    channelButton.alpha = hasChannel ? (selectedIsChannel ? 1.0 : 0.55) : 0.25;
    globalButton.alpha = hasGlobal ? (selectedIsGlobal ? 1.0 : 0.55) : 0.25;

    // Global uses the provider logo; All uses a globe.
    UIImage *providerLogo = nil;
    if (!allTab) {
        for (UIButton *providerButton in self.pickerTabButtons) {
            if (providerButton.tag == self.pickerActiveTab) {
                providerLogo = [providerButton imageForState:UIControlStateNormal];
                break;
            }
        }
    }
    if (!providerLogo) {
        UIImageSymbolConfiguration *globalCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        providerLogo = [UIImage systemImageNamed:@"globe" withConfiguration:globalCfg];
    }
    [globalButton setImage:[providerLogo imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                  forState:UIControlStateNormal];
    globalButton.imageView.contentMode = UIViewContentModeScaleAspectFit;

    // Keep the channel avatar visible across provider tabs.
    [self _tpk_refreshChannelAvatarIfNeeded];
}

- (void)_pickerSubcategoryTapped:(UIButton *)sender {
    BOOL providerTab = [self _tpk_pickerTabIsProvider:self.pickerActiveTab];
    BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
    if ((!providerTab && !allTab) || sender.hidden || !sender.enabled) return;
    BOOL wantChannel = sender == self.pickerSubcategoryChannelBtn;
    NSNumber *selectionKey = allTab ? @(-1) :
        @([self _tpk_providerForPickerTab:self.pickerActiveTab]);
    self.pickerSubcategoryByProvider[selectionKey] = wantChannel ? @"channel" : @"global";
    [self _tpk_persistLastPickerLocation];
    [self _tpk_updateSubcategoryCapsule];
    NSString *query = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:query];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

- (void)_tpk_rebuildCatalogDisplaySectionsForQueryLegacy:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;

    // Restore section collapse choices after search.
    BOOL hasQuery = lower.length > 0;
    if (hasQuery && !self.pickerCatalogSearchActive) {
        self.pickerCollapseStateBeforeSearch = self.pickerCollapsedSections.copy ?: @{};
        self.pickerCatalogSearchActive = YES;
    } else if (!hasQuery && self.pickerCatalogSearchActive) {
        self.pickerCollapsedSections =
            [self.pickerCollapseStateBeforeSearch mutableCopy] ?: [NSMutableDictionary dictionary];
        self.pickerCollapseStateBeforeSearch = nil;
        self.pickerCatalogSearchActive = NO;
    }

    NSMutableArray<TPKPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        if (self.pickerCatalogFavorites.count) {
            NSMutableArray *items = [NSMutableArray array];
            for (TPKEmote *item in self.pickerCatalogFavorites) {
                TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                    ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // Hide the Favorites header when filtering removes all items.
            if (items.count) {
                TPKPickerDisplaySection *favorites = [TPKPickerDisplaySection new];
                favorites.provider = TPKEmoteProviderIDTPK;
                favorites.kind = TPKEmoteSectionKindFavorites;
                favorites.identifier = @"favorites";
                favorites.title = @"Favorites";
                favorites.items = items.copy;
                favorites.loaded = YES;
                [display addObject:favorites];
            }
        }
    } else {
        TPKEmoteProviderID provider = [self _tpk_providerForPickerTab:self.pickerActiveTab];
        NSArray<TPKPickerDisplaySection *> *source = self.pickerProviderSections[@(provider)];
        TPKEmoteProviderSnapshot *snapshot = [[TPKEmoteCatalog sharedCatalog]
            snapshotForProvider:provider];

        // Show loading or retry state before sections are available.
        if (!source.count && (snapshot.state == TPKEmoteProviderStateLoading ||
                              snapshot.state == TPKEmoteProviderStateLoaded ||
                              snapshot.state == TPKEmoteProviderStateError)) {
            TPKPickerDisplaySection *stateSection = [TPKPickerDisplaySection new];
            stateSection.provider = provider;
            stateSection.kind = TPKEmoteSectionKindSet;
            stateSection.identifier = @"provider-state";
            stateSection.title = TPKEmoteProviderName(provider);
            stateSection.items = @[];
            stateSection.loaded = snapshot.state == TPKEmoteProviderStateLoaded;
            stateSection.loading = snapshot.state == TPKEmoteProviderStateLoading;
            stateSection.empty = snapshot.state == TPKEmoteProviderStateLoaded;
            stateSection.errorMessage = snapshot.errorMessage;
            [display addObject:stateSection];
        }

        for (TPKPickerDisplaySection *original in source) {
            NSMutableArray *items = [NSMutableArray array];
            for (TPKEmote *item in original.items) {
                TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                    ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
                BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
                if (!matches && descriptor) {
                    for (NSString *alias in descriptor.aliases) {
                        if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                    }
                }
                if (matches) [items addObject:item];
            }
            // Hide sections only after a successful empty response.
            if (!items.count && original.loaded && !original.loading && !original.errorMessage.length) continue;
            TPKPickerDisplaySection *current = [TPKPickerDisplaySection new];
            current.provider = original.provider;
            current.kind = original.kind;
            current.identifier = original.identifier;
            current.title = original.title;
            current.items = items.copy;
            current.loaded = original.loaded;
            current.loading = original.loading;
            current.empty = original.empty;
            current.errorMessage = original.errorMessage;
            [display addObject:current];
        }
    }

    // Open one new section by default, or all sections during search.
    BOOL openedOne = NO;
    for (TPKPickerDisplaySection *section in display) {
        NSString *key = [self _tpk_displaySectionKey:section];
        BOOL canDisplayContent = section.items.count > 0 ||
            section.loading || section.errorMessage.length ||
            section.kind == TPKEmoteSectionKindSet;
        if (lower.length) {
            self.pickerCollapsedSections[key] = @NO;
        } else if (!self.pickerCollapsedSections[key]) {
            BOOL shouldCollapse = openedOne && canDisplayContent;
            self.pickerCollapsedSections[key] = @(shouldCollapse);
        }
        if (canDisplayContent && ![self.pickerCollapsedSections[key] boolValue])
            openedOne = YES;
    }

    self.pickerDisplaySections = display.copy;
    self.pickerUsesCatalogSections = display.count > 0;
    // Update the flow header immediately after switching tabs.
    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) {
        flowLayout.headerReferenceSize = CGSizeZero;
    }
    // Keep the flat array in sync with visible sections.
    NSMutableArray<TPKEmote *> *visibleItems = [NSMutableArray array];
    for (TPKPickerDisplaySection *section in display) {
        NSString *key = [self _tpk_displaySectionKey:section];
        if (![self.pickerCollapsedSections[key] boolValue])
            [visibleItems addObjectsFromArray:section.items ?: @[]];
    }
    self.emotePickerEmotes = visibleItems.copy;
}

// Channel and Global are the only sections; Shared and Set are combined.
- (void)_tpk_rebuildCatalogDisplaySectionsForQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;
    NSMutableArray<TPKPickerDisplaySection *> *display = [NSMutableArray array];

    if (self.pickerActiveTab == TPKPickerTabFavorites) {
        NSMutableArray<TPKEmote *> *items = [NSMutableArray array];
        for (TPKEmote *item in self.pickerCatalogFavorites ?: @[]) {
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
            BOOL matches = !lower.length || [item.emoteName.lowercaseString containsString:lower];
            if (!matches && descriptor) {
                for (NSString *alias in descriptor.aliases) {
                    if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                }
            }
            if (matches) [items addObject:item];
        }
        [items sortUsingComparator:TPKPickerEmoteSizeComparator];
        if (items.count) {
            TPKPickerDisplaySection *favorites = [TPKPickerDisplaySection new];
            favorites.provider = TPKEmoteProviderIDTPK;
            favorites.kind = TPKEmoteSectionKindFavorites;
            favorites.identifier = @"favorites";
            favorites.title = @"Favorites";
            favorites.items = items.copy;
            favorites.loaded = YES;
            [display addObject:favorites];
        }
    } else {
        BOOL allTab = self.pickerActiveTab == TPKPickerTabAll;
        TPKEmoteProviderID provider = allTab
            ? TPKEmoteProviderIDTPK
            : [self _tpk_providerForPickerTab:self.pickerActiveTab];
        NSNumber *selectionKey = allTab ? @(-1) : @(provider);
        NSArray<NSNumber *> *providers = allTab
            ? [self _tpk_providerIDsInPriorityOrder]
            : @[@(provider)];
        NSMutableArray<TPKEmote *> *channelItems = [NSMutableArray array];
        NSMutableArray<TPKEmote *> *globalItems = [NSMutableArray array];
        NSMutableSet<NSString *> *seenChannel = [NSMutableSet set];
        NSMutableSet<NSString *> *seenGlobal = [NSMutableSet set];
        BOOL channelLoading = NO, globalLoading = NO;
        BOOL channelError = NO, globalError = NO;
        NSString *channelErrorMessage = nil, *globalErrorMessage = nil;
        BOOL anyProviderLoading = NO, anyProviderError = NO;
        NSString *anyProviderErrorMessage = nil;

        BOOL (^matchesQuery)(TPKEmote *) = ^BOOL(TPKEmote *item) {
            if (!lower.length) return YES;
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
            if ([item.emoteName.lowercaseString containsString:lower]) return YES;
            for (NSString *alias in descriptor.aliases)
                if ([alias.lowercaseString containsString:lower]) return YES;
            return NO;
        };

        for (NSNumber *providerNumber in providers) {
            NSArray<TPKPickerDisplaySection *> *source =
                self.pickerProviderSections[providerNumber] ?: @[];
            for (TPKPickerDisplaySection *original in source) {
                BOOL isChannel = [self _tpk_sectionIsChannel:original];
                BOOL isGlobal = [self _tpk_sectionIsGlobal:original];
                if (!isChannel && !isGlobal) {
                    if (original.loading) anyProviderLoading = YES;
                    if (original.errorMessage.length) {
                        anyProviderError = YES;
                        if (!anyProviderErrorMessage.length) anyProviderErrorMessage = original.errorMessage;
                    }
                    continue;
                }
                BOOL pending = !original.loaded || original.loading;
                if (isChannel) {
                    channelLoading |= pending;
                    if (original.errorMessage.length) {
                        channelError = YES;
                        if (!channelErrorMessage.length) channelErrorMessage = original.errorMessage;
                    }
                } else {
                    globalLoading |= pending;
                    if (original.errorMessage.length) {
                        globalError = YES;
                        if (!globalErrorMessage.length) globalErrorMessage = original.errorMessage;
                    }
                }
                NSMutableArray *target = isChannel ? channelItems : globalItems;
                NSMutableSet *seen = isChannel ? seenChannel : seenGlobal;
                for (TPKEmote *item in original.items ?: @[]) {
                    if (!matchesQuery(item)) continue;
                    NSString *key = TPKPickerStableEmoteKey(item);
                    if (!key.length || [seen containsObject:key]) continue;
                    [seen addObject:key];
                    [target addObject:item];
                }
            }
        }

        // Sort after combining providers so sizes interleave.
        [channelItems sortUsingComparator:TPKPickerMixedEmoteSizeComparator];
        [globalItems sortUsingComparator:TPKPickerMixedEmoteSizeComparator];

        BOOL (^addCategory)(BOOL, NSArray<TPKEmote *> *, BOOL, BOOL, NSString *, NSString *) =
            ^BOOL(BOOL isChannel, NSArray<TPKEmote *> *items, BOOL loading,
                  BOOL hasError, NSString *errorMessage, NSString *identifier) {
            if (!items.count && !loading && !hasError) return NO;
            TPKPickerDisplaySection *section = [TPKPickerDisplaySection new];
            section.provider = provider;
            section.kind = isChannel ? TPKEmoteSectionKindChannel : TPKEmoteSectionKindGlobal;
            section.identifier = identifier;
            section.title = isChannel ? @"Channel Emotes" : @"Global Emotes";
            section.items = items ?: @[];
            section.loaded = !loading;
            section.loading = loading;
            section.empty = !items.count && !hasError && !loading;
            section.errorMessage = errorMessage;
            [display addObject:section];
            return YES;
        };
        BOOL hasChannelCategory = addCategory(YES, channelItems, channelLoading,
            channelError, channelErrorMessage, allTab ? @"all-channel" : @"channel");
        BOOL hasGlobalCategory = addCategory(NO, globalItems, globalLoading,
            globalError, globalErrorMessage, allTab ? @"all-global" : @"global");

        // Default to Channel, then Global; restore the saved choice.
        NSString *selectedID = [self.pickerSubcategoryByProvider[selectionKey] lowercaseString];
        BOOL wantsChannel = [selectedID isEqualToString:@"channel"] ||
            (selectedID.length && ![selectedID containsString:@"global"] && hasChannelCategory);
        BOOL wantsGlobal = [selectedID isEqualToString:@"global"] ||
            ([selectedID containsString:@"global"] && hasGlobalCategory);
        TPKPickerDisplaySection *selected = nil;
        TPKPickerDisplaySection *channelSection = display.firstObject;
        TPKPickerDisplaySection *globalSection = display.count > 1 ? display[1] :
            (hasGlobalCategory ? display.firstObject : nil);
        if (wantsChannel && hasChannelCategory) selected = channelSection;
        if (wantsGlobal && hasGlobalCategory) selected = globalSection;
        if (!selected && !lower.length) {
            if (channelItems.count) selected = hasChannelCategory ? channelSection : nil;
            if (!selected && globalItems.count) selected = hasGlobalCategory ? globalSection : nil;
            if (!selected && hasChannelCategory) selected = channelSection;
            if (!selected && hasGlobalCategory) selected = globalSection;
        }
        if (!selected && lower.length) {
            if (channelItems.count && hasChannelCategory) selected = channelSection;
            else if (globalItems.count && hasGlobalCategory) selected = globalSection;
        }
        if (selected) {
            if (!lower.length)
                self.pickerSubcategoryByProvider[selectionKey] =
                    [selected.identifier hasSuffix:@"global"] ? @"global" : @"channel";
            // Show only the selected virtual section.
            [display removeAllObjects];
            [display addObject:selected];
        } else if (anyProviderLoading || anyProviderError || !providers.count) {
            TPKPickerDisplaySection *state = [TPKPickerDisplaySection new];
            state.provider = provider;
            state.kind = TPKEmoteSectionKindSet;
            state.identifier = allTab ? @"all-provider-state" : @"provider-state";
            state.title = allTab ? @"All providers" : TPKEmoteProviderName(provider);
            state.items = @[];
            state.loading = anyProviderLoading;
            state.loaded = !anyProviderLoading;
            state.empty = !anyProviderLoading && !anyProviderError;
            state.errorMessage = anyProviderErrorMessage;
            [display addObject:state];
        }
    }

    self.pickerDisplaySections = display.copy;
    self.pickerUsesCatalogSections = display.count > 0;
    [self.pickerCollapsedSections removeAllObjects];
    for (TPKPickerDisplaySection *section in display)
        self.pickerCollapsedSections[[self _tpk_displaySectionKey:section]] = @NO;

    UICollectionViewFlowLayout *flowLayout =
        (UICollectionViewFlowLayout *)self.emoteCollectionView.collectionViewLayout;
    if (flowLayout) flowLayout.headerReferenceSize = CGSizeZero;

    self.emotePickerEmotes = display.count ? display.firstObject.items : @[];
    [self _tpk_updateSubcategoryCapsule];
}

- (void)_updatePickerArraysForSearch:(NSString *)query autoSelectTab:(BOOL)autoSelectTab {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    // Use the provider catalogue, even while it is loading.
    {
        NSMutableArray *providerItems = [NSMutableArray array];
        if (self.pickerActiveTab == TPKPickerTabFavorites) {
            [providerItems addObjectsFromArray:self.pickerCatalogFavorites ?: @[]];
        } else if (self.pickerActiveTab == TPKPickerTabAll) {
            // Keep the mixed comparator's provider order.
            [providerItems addObjectsFromArray:[self _tpk_currentTabEmotes]];
        } else {
            NSInteger provider = self.pickerActiveTab == TPKPickerTabTPK
                ? TPKEmoteProviderIDTPK
                : (self.pickerActiveTab == TPKPickerTabBTTV
                   ? TPKEmoteProviderIDBTTV : TPKEmoteProviderIDFFZ);
            [providerItems addObjectsFromArray:self.pickerProviderEmotes[@(provider)] ?: @[]];
        }
        NSMutableArray *filtered = [NSMutableArray array];
        for (TPKEmote *item in providerItems) {
            TPKEmoteDescriptor *descriptor = [item isKindOfClass:[TPKPickerCatalogEmote class]]
                ? [(TPKPickerCatalogEmote *)item descriptor] : nil;
            BOOL matches = !q.length || [item.emoteName.lowercaseString containsString:lower];
            if (!matches && descriptor) {
                for (NSString *alias in descriptor.aliases) {
                    if ([alias.lowercaseString containsString:lower]) { matches = YES; break; }
                }
            }
            if (matches)
                [filtered addObject:item];
        }
        if (q.length > 0) {
            [filtered sortUsingComparator:^NSComparisonResult(TPKEmote *a, TPKEmote *b) {
                NSInteger ra = [self _tpk_relevanceRankForEmoteName:a.emoteName query:lower];
                NSInteger rb = [self _tpk_relevanceRankForEmoteName:b.emoteName query:lower];
                return ra == rb ? NSOrderedSame : (ra < rb ? NSOrderedAscending : NSOrderedDescending);
            }];
        }
        if (self.pickerActiveTab == TPKPickerTabFavorites)
            self.emotePickerFavoriteEmotes = filtered;
        else {
            self.emotePickerChannelEmotes = filtered;
            self.emotePickerGlobalEmotes = filtered;
        }
        self.emotePickerOtherEmotes = filtered;
        [self _tpk_rebuildCatalogDisplaySectionsForQuery:q];
        [self _tpk_updateTabButtonHighlight];
        return;
    }
}

// Match rank: exact, prefix, then substring.
- (NSInteger)_tpk_relevanceRankForEmoteName:(NSString *)name query:(NSString *)lowerQuery {
    NSString *lowerName = name.lowercaseString;
    if ([lowerName isEqualToString:lowerQuery]) return 0;
    if ([lowerName hasPrefix:lowerQuery]) return 1;
    return 2;
}

// ── UITextFieldDelegate — intercepte le focus du champ de recherche ────────
// Keep the picker open by handling search focus with an alert.
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField != self.emoteSearchField) return YES;
    if (self.pickerSearchAlertActive) return NO;

    // Prefill the alert with the current query.
    NSString *currentQuery = textField.text ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_search_emote_title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    alert.view.tintColor = TPKAccent();

    [alert addTextFieldWithConfigurationHandler:^(UITextField *alertField) {
        alertField.placeholder   = L(@"placeholder_emote_name");
        alertField.text          = currentQuery;
        alertField.returnKeyType = UIReturnKeySearch;
        alertField.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Select existing text for easy replacement.
        if (currentQuery.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [alertField selectAll:nil];
            });
        }
    }];

    UIAlertAction *searchAction = [UIAlertAction
        actionWithTitle:L(@"action_search")
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
        NSString *query = alert.textFields.firstObject.text ?: @"";
        // Update the visible search text.
        textField.text = query;
        if (query.length == 0) {
            UIColor *subColor = [UIColor colorWithWhite:0.55 alpha:1.0];
            textField.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:L(@"placeholder_search_picker")
                    attributes:@{NSForegroundColorAttributeName: subColor}];
        }
        [self _applySearchQuery:query];
        // Dismiss without animation to avoid chained focus transitions.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:L(@"common_cancel")
                  style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *action) {
        // Dismiss without animation on cancel too.
        [alert dismissViewControllerAnimated:NO completion:^{
            self.pickerSearchAlertActive = NO;
            [self _restorePickerFocus];
        }];
    }];

    [alert addAction:searchAction];
    [alert addAction:cancelAction];
    alert.preferredAction = searchAction;

    // Set the flag before presenting the alert, which resigns TextEntryView.
    UIViewController *presenter = [self topViewController];
    if (!presenter) return NO;
    [self _tpk_deactivateVisiblePickerAnimations];
    self.pickerSearchAlertActive = YES;
    [presenter presentViewController:alert animated:YES completion:nil];

    // Keep the picker visible by rejecting becomeFirstResponder.
    return NO;
}

- (void)_applySearchQuery:(NSString *)query {
    // This is the only entry point for automatic tab selection.
    [self _updatePickerArraysForSearch:query autoSelectTab:YES];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    [self _tpk_updateSearchClearVisibility];
}

// Show the clear button when search text is present.
- (void)_tpk_updateSearchClearVisibility {
    self.pickerSearchClearBtn.hidden = (self.emoteSearchField.text.length == 0);
}

// Restore the picker inputView after dismissing the alert.
- (void)_restorePickerFocus {
    UITextView *tv = self.emotePickerTextEntryView;
    UIView *pickerView = self.emotePickerView;
    if (!pickerView) return;
    if (tv && tv.window) {
        // Restore inputView if UIKit cleared it.
        tv.inputView = pickerView;
        tv.inputAccessoryView = nil;
        pickerView.hidden = NO;
        if (!tv.isFirstResponder) [tv becomeFirstResponder];
        [tv reloadInputViews];
    } else if (pickerView.window) {
        // Floating-window mode has no TextEntryView or animation observers.
        pickerView.hidden = NO;
    } else {
        return;
    }
    // Resume animations after the picker inputView returns.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf _tpk_activateVisiblePickerAnimations];
    });
}

// Handle programmatic search-field changes.
- (void)_emoteSearchChanged:(UITextField *)field {
    [self _applySearchQuery:field.text ?: @""];
}



// ── Long press → toggle favori ─────────────────────────────────────────────

- (void)_handleLongPressOnPicker:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    CGPoint pt = [gr locationInView:self.emoteCollectionView];
    NSIndexPath *ip = [self.emoteCollectionView indexPathForItemAtPoint:pt];
    if (!ip) return;

    TPKEmote *emote = [self _emoteForIndexPath:ip];
    if (!emote) return;

    TPKEmoteDescriptor *descriptor = [emote isKindOfClass:[TPKPickerCatalogEmote class]]
        ? [(TPKPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFav = descriptor
        ? [[TPKEmoteCatalog sharedCatalog] isEmoteFavorited:descriptor]
        : [[TPKManager sharedManager] isEmoteFavorited:emote.emoteID];
    if (descriptor && descriptor.provider == TPKEmoteProviderIDTPK) {
        // Keep the legacy 7TV favorites set in sync.
        [[TPKManager sharedManager] setEmote:descriptor.emoteID favorited:!isFav];
    } else if (descriptor) {
        [[TPKEmoteCatalog sharedCatalog] setEmote:descriptor favorited:!isFav];
    } else {
        [[TPKManager sharedManager] setEmote:emote.emoteID favorited:!isFav];
    }
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // setEmote:favorited: already reloads the picker.
}

// ── Helper : emote à partir d'un indexPath ─────────────────────────────────
// The active tab selects the emote array.

// Prewarm the displayed emotes after sorting; cellFor and willDisplay update cells.
static void tpk_warmEmoteForPicker(TPKEmoteImageCache *cache, TPKEmote *emote) {
    if (!emote) return;
    NSURL *imageURL = TPKPickerImageURLForEmote(emote);
    if (!imageURL) return;
    if (![cache cachedImageForURL:imageURL]) {
        [cache imageForURL:imageURL completion:^(__unused UIImage *image) {}];
    }
    if (emote.isAnimated && ![cache cachedFramesForURL:imageURL]) {
        [cache framesForURL:imageURL animated:emote.isAnimated preview:nil
            completion:^(__unused TPKEmoteAnimatedFrames *frames) {}];
    }
}

- (void)_tpk_prewarmPickerViewportImages {
    TPKEmoteImageCache *warmCache = [TPKEmoteImageCache sharedCache];
    NSUInteger warmed = 0;
    if (self.emoteCollectionView.window && !CGRectIsEmpty(self.emoteCollectionView.bounds)) {
        for (NSIndexPath *ip in self.emoteCollectionView.indexPathsForVisibleItems) {
            if (warmed >= 40) break;
            tpk_warmEmoteForPicker(warmCache, [self _emoteForIndexPath:ip]);
            warmed++;
        }
        if (warmed >= 40) return;
    }
    if (self.pickerUsesCatalogSections) {
        for (TPKPickerDisplaySection *section in self.pickerDisplaySections) {
            if ([self.pickerCollapsedSections[[self _tpk_displaySectionKey:section]] boolValue]) continue;
            for (TPKEmote *emote in section.items) {
                if (warmed >= 40) return;
                tpk_warmEmoteForPicker(warmCache, emote);
                warmed++;
            }
        }
    } else {
        for (TPKEmote *emote in self.emotePickerEmotes) {
            if (warmed >= 40) return;
            tpk_warmEmoteForPicker(warmCache, emote);
            warmed++;
        }
    }
}

- (TPKEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (self.pickerUsesCatalogSections) {
        if (ip.section < 0 || ip.section >= (NSInteger)self.pickerDisplaySections.count) return nil;
        TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)ip.section];
        NSString *key = [self _tpk_displaySectionKey:section];
        if ([self.pickerCollapsedSections[key] boolValue]) return nil;
        if (ip.item < 0 || ip.item >= (NSInteger)section.items.count) return nil;
        return section.items[(NSUInteger)ip.item];
    }
    if (ip.section != 0) return nil;
    if ((NSUInteger)ip.item < self.emotePickerEmotes.count)
        return self.emotePickerEmotes[(NSUInteger)ip.item];
    return nil;
}

- (void)_pickerSettingsTapped {
    [self _hideEmotePicker];
    [[TPKManager sharedManager] presentSettingsMenu];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    if (self.pickerUsesCatalogSections) return (NSInteger)self.pickerDisplaySections.count;
    return 1; // Compatibilité avec le catalogue legacy aplati.
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if (self.pickerUsesCatalogSections) {
        if (section < 0 || section >= (NSInteger)self.pickerDisplaySections.count) return 0;
        TPKPickerDisplaySection *display = self.pickerDisplaySections[(NSUInteger)section];
        NSString *key = [self _tpk_displaySectionKey:display];
        return [self.pickerCollapsedSections[key] boolValue] ? 0 : (NSInteger)display.items.count;
    }
    return (NSInteger)self.emotePickerEmotes.count;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView ||
        ![kind isEqualToString:UICollectionElementKindSectionHeader] ||
        !self.pickerUsesCatalogSections ||
        indexPath.section >= (NSInteger)self.pickerDisplaySections.count) {
        return [UICollectionReusableView new];
    }
    TPKPickerSectionHeaderView *header =
        (TPKPickerSectionHeaderView *)[collectionView
            dequeueReusableSupplementaryViewOfKind:kind
                               withReuseIdentifier:@"TPKPickerSectionHeader"
                                      forIndexPath:indexPath];
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)indexPath.section];
    NSString *sectionKey = [self _tpk_displaySectionKey:section];
    BOOL collapsed = [self.pickerCollapsedSections[sectionKey] boolValue];
    UIColor *textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    UIColor *subColor = [UIColor colorWithWhite:1.0 alpha:0.52];
    header.titleLabel.text = section.title ?: @"Emotes";
    header.titleLabel.textColor = textColor;
    header.countLabel.text = section.items.count ? [NSString stringWithFormat:@"%lu",
        (unsigned long)section.items.count] : @"—";
    header.countLabel.textColor = subColor;
    header.stateLabel.hidden = section.loaded && !section.loading && !section.empty &&
        !section.errorMessage.length;
    header.stateLabel.text = section.loading ? @"Loading…"
        : (section.errorMessage.length ? @"Unavailable"
           : (section.loaded ? @"No emotes" : @"Tap to load"));
    header.stateLabel.textColor = section.loading || section.empty || !section.loaded
        ? [UIColor colorWithWhite:1.0 alpha:0.45] : [UIColor systemOrangeColor];
    header.retryButton.hidden = !section.errorMessage.length;
    header.backgroundColor = TPKOLEDModeEnabled()
        ? [UIColor colorWithWhite:1.0 alpha:0.035]
        : [UIColor colorWithWhite:1.0 alpha:0.055];
    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration
        configurationWithPointSize:10.0 weight:UIImageSymbolWeightSemibold];
    [header.toggleButton setImage:[UIImage systemImageNamed:(collapsed
        ? @"chevron.right" : @"chevron.down") withConfiguration:chevronConfig]
                          forState:UIControlStateNormal];
    header.toggleButton.tintColor = subColor;
    header.toggleButton.tag = indexPath.section;
    header.retryButton.tag = indexPath.section;
    [header.toggleButton removeTarget:self action:@selector(_pickerSectionHeaderTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
    [header.toggleButton addTarget:self action:@selector(_pickerSectionHeaderTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    [header.retryButton removeTarget:self action:@selector(_pickerSectionRetryTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
    [header.retryButton addTarget:self action:@selector(_pickerSectionRetryTapped:)
                  forControlEvents:UIControlEventTouchUpInside];
    header.toggleButton.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        section.title ?: @"Emotes", collapsed ? @"Expand" : @"Collapse"];
    return header;
}

- (void)_pickerSectionHeaderTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pickerDisplaySections.count) return;
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    NSString *key = [self _tpk_displaySectionKey:section];
    BOOL willExpand = [self.pickerCollapsedSections[key] boolValue];
    self.pickerCollapsedSections[key] = @(!willExpand);
    if (willExpand && section.provider == TPKEmoteProviderIDTPK &&
        section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"] &&
        !section.items.count &&
        !section.loaded &&
        !section.loading && !section.errorMessage.length) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [TPKManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[TPKEmoteCatalog sharedCatalog] loadTPKEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
    }
    [self _tpk_rebuildCatalogDisplaySectionsForQuery:self.emoteSearchField.text ?: @""];
    [self _tpk_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
}

- (void)_pickerSectionRetryTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pickerDisplaySections.count) return;
    TPKPickerDisplaySection *section = self.pickerDisplaySections[(NSUInteger)index];
    if (section.provider == TPKEmoteProviderIDTPK &&
        section.kind == TPKEmoteSectionKindSet &&
        ![section.identifier isEqualToString:@"provider-state"]) {
        BOOL global = [section.identifier hasPrefix:@"global-set:"];
        NSString *channelID = global ? nil : [TPKManager sharedManager].currentChannelTwitchID;
        NSString *prefix = global ? @"global-set:" : @"set:";
        NSString *setID = [section.identifier hasPrefix:prefix]
            ? [section.identifier substringFromIndex:prefix.length] : nil;
        [[TPKEmoteCatalog sharedCatalog] loadTPKEmoteSetWithID:setID
                                                               global:global
                                                              channel:channelID];
        return;
    }
    NSString *channelID = [TPKManager sharedManager].currentChannelTwitchID;
    TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
    [catalog loadProvider:section.provider global:YES channel:nil completion:nil];
    if (channelID.length)
        [catalog loadProvider:section.provider global:NO channel:channelID completion:nil];
}

// ── Taille variable par emote ─────────────────────────────────────────────
// Cell height follows the emote ratio, with a 32pt minimum.

// Use six columns in portrait and ten in landscape.
- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    CGFloat cvW = cv.bounds.size.width > 0 ? cv.bounds.size.width : 390.0;
    CGFloat referenceColumns = [self pickerHostIsLandscape] ? 10.0 : 6.0;
    // Apply the size factor while keeping the 32pt minimum.
    TPKChatAppearanceConfig *cfg = [TPKChatAppearanceConfig sharedConfig];
    CGFloat scale = [self pickerHostIsLandscape] ? cfg.pickerEmoteScaleLandscape
                                                : cfg.pickerEmoteScalePortrait;
    CGFloat cellH = MAX(32.0, floor(cvW / referenceColumns) * scale);

    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote || emote.width <= 0 || emote.height <= 0) {
        // Pas de dimensions connues → carré
        return CGSizeMake(cellH, cellH);
    }

    CGFloat ratio = (CGFloat)emote.width / (CGFloat)emote.height;
    CGFloat cellW = cellH * ratio;

    cellW = MAX(cellH * 0.25, cellW);   // min 25% de la hauteur
    cellW = MIN(cvW, cellW);            // max = pleine largeur
    cellW = ceil(cellW);
    cellH = ceil(cellH);

    return CGSizeMake(cellW, cellH);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    TPKEmotePickerCell *cell = (TPKEmotePickerCell *)
        [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID forIndexPath:indexPath];
    // Reapply colors when reusing a cell.
    [cell tpk_applyOLEDColors];

    [cell resetContent];

    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Show the star for actual favorites, in every tab.
    TPKEmoteDescriptor *descriptor = [emote isKindOfClass:[TPKPickerCatalogEmote class]]
        ? [(TPKPickerCatalogEmote *)emote descriptor] : nil;
    BOOL isFavorite = descriptor
        ? [self.pickerFavoriteKeySet containsObject:
              TPKEmoteFavoriteKey(descriptor.provider, descriptor.emoteID)]
        : [[TPKManager sharedManager] isEmoteFavorited:emote.emoteID];
    cell.favoriteStarView.hidden = !isFavorite;
    cell.accessibilityLabel = emote.emoteName ?: @"Emote";
    if (descriptor && (self.pickerActiveTab == TPKPickerTabFavorites ||
                       self.pickerActiveTab == TPKPickerTabAll)) {
        cell.providerBadgeLabel.text = descriptor.providerIdentifier.uppercaseString;
        cell.providerBadgeLabel.hidden = NO;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",
            descriptor.name, descriptor.providerName ?: descriptor.providerIdentifier,
            descriptor.sectionTitle ?: @"Emotes"];
    }

    // Respect the global animation setting and Favorites-only option.
    BOOL wantsAnimated = emote.isAnimated && [TPKManager sharedManager].showPickerAnimations &&
        (![TPKManager sharedManager].showPickerAnimationsFavoritesOnly || self.pickerActiveTab == TPKPickerTabFavorites);

    NSURL *imageURL = TPKPickerImageURLForEmote(emote);
    NSString *key = imageURL.absoluteString;
    cell.currentEmoteKey = key;
    cell.wantsAnimation = wantsAnimated;

    // Start image loading in willDisplay, not cellFor.
    cell.emoteImageView.image = [[TPKEmoteImageCache sharedCache]
        cachedImageForURL:imageURL];

    return cell;
}

// Animated frames are driven by the shared display-link engine.
- (BOOL)_tpk_configureAnimatedPickerCell:(TPKEmotePickerCell *)cell
                                      URL:(NSURL *)imageURL
                                animated:(BOOL)animated
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode {
    TPKEmoteImageCache *cache   = [TPKEmoteImageCache sharedCache];
    TPKEmoteAnimationEngine *engine = [TPKEmoteAnimationEngine sharedEngine];

    __weak typeof(self) weakSelfForActivity = self;
    __weak TPKEmotePickerCell *weakCellForActivity = cell;
    BOOL (^cellIsStillActive)(void) = ^BOOL{
        TPKEmotePickerController *strongSelf = weakSelfForActivity;
        TPKEmotePickerCell *strongCell = weakCellForActivity;
        return strongSelf && strongCell &&
               strongCell.window != nil &&
               strongSelf.emotePickerView.window != nil &&
               !strongSelf.pickerSearchAlertActive &&
               !strongSelf.emotePickerView.hidden &&
               !strongSelf.emoteCollectionView.hidden &&
               strongCell.wantsAnimation &&
               strongCell.animationGeneration == generation &&
               [strongCell.currentEmoteKey isEqualToString:key];
    };
    if (!cellIsStillActive()) return NO;

    __weak TPKEmotePickerCell *weakCell = cell;
    void (^redraw)(void) = ^{
        __strong TPKEmotePickerCell *strongCell = weakCell;
        if (!strongCell || ![strongCell.currentEmoteKey isEqualToString:key]) return;
        UIImage *frame = [engine currentFrameForKey:key];
        if (frame) strongCell.emoteImageView.image = frame;
    };

    // Show cached frames; return to static only after a full loop.
    if ([engine hasFramesForKey:key]) {
        if (!cellIsStillActive()) return NO;
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw(); // Display the current frame immediately.
        if ([engine hasCompleteFramesForKey:key]) return YES;
    }

    // Reuse decoded frames from other views.
    TPKEmoteAnimatedFrames *cachedFrames = [cache cachedFramesForURL:imageURL];
    if (cachedFrames) {
        if (!cellIsStillActive()) return NO;
        [engine registerFrames:cachedFrames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
        return YES;
    }

    // Use cached frames now; delay new decoding until scrolling settles.
    if (!allowDecode) return NO;

    // Show the static image while decoding frames.
    UIImage *staticCached = [cache cachedImageForURL:imageURL];
    if (staticCached) cell.emoteImageView.image = staticCached;

    __weak TPKEmotePickerCell *weakCellForLoad = cell;
    void (^applyFrames)(TPKEmoteAnimatedFrames *) = ^(TPKEmoteAnimatedFrames *frames) {
        if (!frames.images.count) return;
        TPKEmotePickerCell *strongCell = weakCellForLoad;
        if (!strongCell || !cellIsStillActive()) return;
        // Ignore previews that arrive after the full animation.
        if (frames.isPreview && [engine hasCompleteFramesForKey:key]) return;
        [engine registerFrames:frames forKey:key];
        [engine addObserver:strongCell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
    };

    cell.animationFrameRequest = [cache framesForURL:imageURL animated:animated
        preview:^(TPKEmoteAnimatedFrames *previewFrames) {
            // Show a short preview while WebP decoding runs.
            applyFrames(previewFrames);
        }
        completion:^(TPKEmoteAnimatedFrames * _Nullable frames) {
            TPKEmotePickerCell *strongCell = weakCellForLoad;
            if (frames) applyFrames(frames);
            if (strongCell && cellIsStillActive()) {
                strongCell.animationFrameRequest = nil;
            }
        }];
    return YES;
}

// ── Visibilité réelle / scroll ─────────────────────────────────────────────

- (void)_tpk_scheduleStaticImageForPickerCell:(TPKEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden) return;
    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.imageLoadGeneration;
    __weak typeof(self) weakSelf = self;
    __weak TPKEmotePickerCell *weakCell = cell;

    // Request frames only after a visible cell remains stable for 40ms.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        TPKEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window ||
            strongSelf.emotePickerView.hidden || strongSelf.emoteCollectionView.hidden) return;
        if (strongCell.imageLoadGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        TPKEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote) return;
        NSURL *imageURL = TPKPickerImageURLForEmote(emote);
        if (![imageURL.absoluteString isEqualToString:key]) return;

        TPKEmoteImageCache *cache = [TPKEmoteImageCache sharedCache];
        UIImage *cached = [cache cachedImageForURL:imageURL];
        if (cached) {
            strongCell.emoteImageView.image = cached;
            return;
        }
        [cache imageForURL:imageURL completion:^(UIImage * _Nullable image) {
            TPKEmotePickerCell *completionCell = weakCell;
            TPKEmotePickerController *completionSelf = weakSelf;
            if (!image || !completionSelf || completionSelf.pickerSearchAlertActive ||
                !completionSelf.emotePickerView.window || !completionCell || !completionCell.window ||
                completionCell.imageLoadGeneration != generation ||
                ![completionCell.currentEmoteKey isEqualToString:key]) return;
            completionCell.emoteImageView.image = image;
        }];
    });
}

- (void)_tpk_scheduleAnimationForPickerCell:(TPKEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath {
    if (self.pickerSearchAlertActive || !self.emotePickerView.window ||
        !cell.wantsAnimation || self.emoteCollectionView.hidden) return;
    if (cell.animationFrameRequest) return; // A decode request is already active.

    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.animationGeneration;
    __weak typeof(self) weakSelf = self;
    __weak TPKEmotePickerCell *weakCell = cell;

    TPKEmote *initialEmote = [self _emoteForIndexPath:indexPath];
    if (!initialEmote || !initialEmote.isAnimated) return;
    NSURL *initialImageURL = TPKPickerImageURLForEmote(initialEmote);
    if (![initialImageURL.absoluteString isEqualToString:key]) return;

    // First pass observes cached frames without decoding.
    BOOL attachedFromCache = [self _tpk_configureAnimatedPickerCell:cell
                                                                  URL:initialImageURL
                                                            animated:initialEmote.isAnimated
                                                                  key:key
                                                           generation:generation
                                                          allowDecode:NO];
    if (attachedFromCache) return;

    // Cancel requests when cells leave the screen.
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        TPKEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell || strongSelf.pickerSearchAlertActive ||
            !strongSelf.emotePickerView.window) return;
        if (strongCell.animationGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        TPKEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote || !emote.isAnimated) return;
        NSURL *imageURL = TPKPickerImageURLForEmote(emote);
        if (![imageURL.absoluteString isEqualToString:key]) return;
        [strongSelf _tpk_configureAnimatedPickerCell:strongCell
                                                  URL:imageURL
                                            animated:emote.isAnimated
                                                  key:key
                                           generation:generation
                                          allowDecode:YES];
    });
}

- (void)_tpk_deactivateVisiblePickerAnimations {
    for (TPKEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell.animationFrameRequest cancel];
        cell.animationFrameRequest = nil;
        cell.imageLoadGeneration += 1;
        cell.animationGeneration += 1;
        [[TPKEmoteAnimationEngine sharedEngine] removeObserver:cell];
    }
}

- (void)_tpk_activateVisiblePickerAnimations {
    if (self.pickerSearchAlertActive || self.pickerScrollInProgress ||
        self.emoteCollectionView.isTracking || self.emoteCollectionView.isDragging ||
        self.emoteCollectionView.isDecelerating || !self.emotePickerView.window ||
        self.emoteCollectionView.hidden || self.emotePickerView.hidden) return;
    for (NSIndexPath *indexPath in self.emoteCollectionView.indexPathsForVisibleItems) {
        TPKEmotePickerCell *cell = (TPKEmotePickerCell *)
            [self.emoteCollectionView cellForItemAtIndexPath:indexPath];
        if (cell) {
            [self _tpk_scheduleStaticImageForPickerCell:cell atIndexPath:indexPath];
            [self _tpk_scheduleAnimationForPickerCell:cell atIndexPath:indexPath];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView
        willDisplayCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    TPKEmotePickerCell *pickerCell = (TPKEmotePickerCell *)cell;
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
    [self _tpk_scheduleStaticImageForPickerCell:pickerCell atIndexPath:indexPath];
    [self _tpk_scheduleAnimationForPickerCell:pickerCell atIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView
 didEndDisplayingCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    TPKEmotePickerCell *pickerCell = (TPKEmotePickerCell *)cell;
    [pickerCell.animationFrameRequest cancel];
    pickerCell.animationFrameRequest = nil;
    pickerCell.imageLoadGeneration += 1;
    pickerCell.animationGeneration += 1;
    [[TPKEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = YES;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.emoteCollectionView || decelerate) return;
    self.pickerScrollInProgress = NO;
    if (self.pickerCatalogReloadPending) [self _tpk_applyCatalogUpdateNow];
    [self _tpk_activateVisiblePickerAnimations];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = NO;
    if (self.pickerCatalogReloadPending) [self _tpk_applyCatalogUpdateNow];
    [self _tpk_activateVisiblePickerAnimations];
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    TPKEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // ── Étape 1 : trouver la ChatInputView (référence stockée, puis BFS fenêtre) ──
    UIView *inputRoot = self.emotePickerTextField;

    if (!inputRoot) {
        [[TPKManager sharedManager] log:@"⚠️ didSelect: emotePickerTextField nil → BFS fenêtre"];
        UIWindow *kw = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { kw = w; break; }
        if (!kw) kw = [UIApplication sharedApplication].windows.firstObject;
        if (kw) {
            NSMutableArray<UIView *> *bq = [NSMutableArray arrayWithObject:kw];
            while (bq.count > 0) {
                UIView *v = bq.firstObject; [bq removeObjectAtIndex:0];
                [bq addObjectsFromArray:v.subviews];
                if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.ChatInputView"]) {
                    inputRoot = v;
                    self.emotePickerTextField = v;
                    break;
                }
            }
        }
    }

    // ── Étape 2 : emotePickerTextEntryView (firstResponder) ; BFS en fallback si nil ──
    UITextView  *textView  = self.emotePickerTextEntryView;
    UITextField *textField = nil;
    id<UIKeyInput> keyInput = nil;

    if (!textView && inputRoot) {
        // Fallback BFS
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:inputRoot];
        while (queue.count > 0) {
            UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            [queue addObjectsFromArray:v.subviews];
            if (!textView  && [v isKindOfClass:[UITextView class]])  textView  = (UITextView *)v;
            if (!textField && [v isKindOfClass:[UITextField class]]) textField = (UITextField *)v;
            if (!keyInput  && [v conformsToProtocol:@protocol(UIKeyInput)]
                           && ![v isKindOfClass:[UIButton class]])   keyInput  = (id<UIKeyInput>)v;
        }
    }

    // ── Étape 3: construire le texte à insérer ────────────────────────────────
    NSString *currentText = @"";
    if (textView)       currentText = textView.text  ?: @"";
    else if (textField) currentText = textField.text ?: @"";

    NSString *prefix  = (currentText.length > 0 && ![currentText hasSuffix:@" "]) ? @" " : @"";
    NSString *emoteText = emote.emoteName ?: @"";
    NSString *stableKey = TPKPickerStableEmoteKey(emote);
    NSString *favoriteComposition = stableKey.length
        ? [[TPKEmoteCatalog sharedCatalog]
            favoriteCompositionTextForEmoteKey:stableKey] : nil;
    if (favoriteComposition.length) emoteText = favoriteComposition;
    NSString *toAppend = [NSString stringWithFormat:@"%@%@ ", prefix, emoteText];

    // ── Étape 4: insertion ─────────────────────────────────────────────────
    // Use paste: so SwiftUI receives the text change.
    BOOL inserted = NO;

    if (textView) {
        // Aller à la fin
        textView.selectedRange = NSMakeRange(textView.text.length, 0);

        // Save and replace the pasteboard.
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *savedString = pb.string;
        pb.string = toAppend;

        // paste: runs the UITextInput pipeline and notifies SwiftUI.
        if ([textView respondsToSelector:@selector(paste:)]) {
            [textView paste:nil];
            inserted = YES;
        } else {
            // Ultime fallback
            [textView insertText:toAppend];
            inserted = YES;
            [[TPKManager sharedManager] log:@"⚠️ paste: non dispo → insertText: fallback"];
        }

        // Restore the pasteboard after the paste animation.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            pb.string = savedString ?: @"";
        });
        // UIKit sends the delegate and notification callbacks for paste.
    } else if (textField) {
        [textField becomeFirstResponder];
        [(id<UIKeyInput>)textField insertText:toAppend];
        inserted = YES;
    } else if (keyInput) {
        [(UIView *)keyInput becomeFirstResponder];
        [(id<UIKeyInput>)keyInput insertText:toAppend];
        inserted = YES;
    }

    if (!inserted) {
        [[TPKManager sharedManager] log:@"❌ didSelect: aucun champ texte trouvé — emote=%@", emote.emoteName];
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { window = w; break; }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
@end
