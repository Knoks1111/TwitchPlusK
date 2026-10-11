/*
 * tpK-info-tooltip.m
 *
 * Implémentation du tooltip décrit dans tpK-info-tooltip.h. Une seule bulle
 * peut exister à la fois dans toute l'app (état statique) : les boutons "i"
 * vivent dans des cellules recréées à chaque reloadData, un singleton par
 * écran serait plus lourd pour un comportement identique.
 */

#import "UI/tpK-info-tooltip.h"
#import "Localization/tpK-localization-manager.h"

@interface TPKInfoButton ()
@property (nonatomic, copy, readwrite) NSString *tpk_localizationKey;
@end

// État global : un seul tooltip ouvert à la fois.
static TPKInfoButton *_tpk_visibleInfoButton = nil;
static UIView *_tpk_overlay = nil;
static UIScrollView *_tpk_hostScrollView = nil;

@implementation TPKInfoButton
@end

@implementation TPKInfoTooltip

+ (void)initialize {
    if (self != [TPKInfoTooltip class]) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    // Une bulle ouverte pendant un changement de langue afficherait un texte
    // périmé (résolu une seule fois à l'ouverture) → fermeture, l'utilisateur
    // peut la rouvrir aussitôt dans la nouvelle langue.
    [center addObserver:[TPKInfoTooltip class]
               selector:@selector(dismiss)
                   name:TPKLanguageDidChangeNotification
                 object:nil];
    // Rotation : la position calculée ne serait plus valide.
    [center addObserver:[TPKInfoTooltip class]
               selector:@selector(dismiss)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
}

+ (UIButton *)infoButtonWithKey:(NSString *)key {
    TPKInfoButton *button = [TPKInfoButton buttonWithType:UIButtonTypeSystem];
    button.tpk_localizationKey = key;

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:@"info.circle"
                             withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];

    // Zone tactile élargie sans grossir l'icône visible.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
#pragma clang diagnostic pop

    [button addTarget:[TPKInfoTooltip class]
               action:@selector(tpk_buttonTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

+ (UIButton *)warningButtonWithKey:(NSString *)key {
    // Réutilise exactement le même bouton, la même zone tactile et le même
    // gestionnaire de tooltip ; seule la présentation de l'icône change.
    TPKInfoButton *button = (TPKInfoButton *)[self infoButtonWithKey:key];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    [button setImage:[UIImage systemImageNamed:@"exclamationmark.circle"
                             withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.systemRedColor;
    return button;
}

+ (void)dismiss {
    if (!_tpk_overlay) return;

    if (_tpk_hostScrollView) {
        [_tpk_hostScrollView.panGestureRecognizer
            removeTarget:[TPKInfoTooltip class]
                  action:@selector(tpk_scrollDismissed)];
        _tpk_hostScrollView = nil;
    }
    _tpk_visibleInfoButton = nil;
    UIView *overlay = _tpk_overlay;
    _tpk_overlay = nil;

    [UIView animateWithDuration:0.15
        animations:^{
            overlay.alpha = 0.0;
        }
        completion:^(BOOL finished) {
            [overlay removeFromSuperview];
        }];
}

// ── Internes ────────────────────────────────────────────────────────────────

+ (void)tpk_buttonTapped:(TPKInfoButton *)sender {
    // Re-tap sur le même "i" = toggle.
    if (_tpk_visibleInfoButton == sender) {
        [self dismiss];
        return;
    }
    // Autre "i" pressé pendant qu'une bulle est ouverte : remplacer.
    [self dismiss];
    [self tpk_showForButton:sender];
}

+ (void)tpk_scrollDismissed {
    [self dismiss];
}

+ (void)tpk_noop {
    // Absorbe les taps dans la bulle pour ne pas la refermer.
}

+ (void)tpk_showForButton:(TPKInfoButton *)sender {
    UIWindow *window = sender.window;
    if (!window) return;

    // Résolu ICI, jamais à la création du bouton → toujours la langue active.
    NSString *text = L(sender.tpk_localizationKey);
    if (!text.length) return;

    // Overlay plein écran transparent : le premier tap n'importe où le
    // referme (comportement popover natif).
    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    UITapGestureRecognizer *outsideTap = [[UITapGestureRecognizer alloc]
        initWithTarget:[TPKInfoTooltip class] action:@selector(dismiss)];
    [overlay addGestureRecognizer:outsideTap];

    // ── Bulle, style dark des settings (fond cellule + bordure discrète) ──
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    label.numberOfLines = 0;

    UIView *bubble = [[UIView alloc] init];
    bubble.backgroundColor = [UIColor colorWithRed:0.122 green:0.122 blue:0.137
                                             alpha:1.0]; // #1F1F23
    bubble.layer.cornerRadius = 12.0;
    bubble.layer.borderWidth = 1.0;
    bubble.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    bubble.layer.shadowColor = [UIColor blackColor].CGColor;
    bubble.layer.shadowOpacity = 0.4;
    bubble.layer.shadowRadius = 12.0;
    bubble.layer.shadowOffset = CGSizeMake(0, 4);

    CGFloat inset = 12.0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor  constraintEqualToAnchor:bubble.leadingAnchor constant:inset],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-inset],
        [label.topAnchor      constraintEqualToAnchor:bubble.topAnchor constant:10],
        [label.bottomAnchor   constraintEqualToAnchor:bubble.bottomAnchor constant:-10],
    ]];
    [overlay addSubview:bubble];

    // ── Taille : largeur plafonnée, hauteur auto, garde-fou anti-bulle XXL ──
    CGFloat maxBubbleWidth = MIN(280.0, window.bounds.size.width - 24.0);
    [bubble setNeedsLayout];
    [bubble layoutIfNeeded];
    // 1re mesure : largeur naturelle du texte (UILayoutFittingCompressedSize
    // EST un CGSize, on ne le repasse pas comme hauteur).
    CGSize bubbleSize = [bubble systemLayoutSizeFittingSize:
        UILayoutFittingCompressedSize];
    if (bubbleSize.width > maxBubbleWidth) {
        // 2e mesure : texte long → largeur forcée au plafond, le label
        // wrappe et la hauteur s'adapte au nombre de lignes.
        bubbleSize = [bubble systemLayoutSizeFittingSize:
            CGSizeMake(maxBubbleWidth, 0)
            withHorizontalFittingPriority:UILayoutPriorityRequired
                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    }
    bubbleSize.height = MIN(bubbleSize.height, window.bounds.size.height * 0.6);
    bubble.frame = CGRectMake(0, 0, bubbleSize.width, bubbleSize.height);

    // ── Position : ancrée au bouton, clampée aux safe areas ──
    CGRect anchor = [sender convertRect:sender.bounds toView:window];
    CGFloat margin = 12.0;
    CGFloat safeTop = window.safeAreaInsets.top + 4.0;
    CGFloat safeBottom = window.bounds.size.height - MAX(window.safeAreaInsets.bottom, 4.0);

    CGFloat x = CGRectGetMidX(anchor) - bubbleSize.width / 2.0;
    x = MIN(MAX(x, margin), window.bounds.size.width - margin - bubbleSize.width);

    CGFloat yAbove = CGRectGetMinY(anchor) - 8.0 - bubbleSize.height;
    CGFloat yBelow = CGRectGetMaxY(anchor) + 8.0;
    CGFloat y;
    if (yAbove >= safeTop) {
        y = yAbove;
    } else if (yBelow + bubbleSize.height <= safeBottom) {
        y = yBelow;
    } else {
        // Aucune place ni au-dessus ni en dessous : centré, clampé.
        y = CGRectGetMidY(anchor) - bubbleSize.height / 2.0;
        y = MIN(MAX(y, safeTop), safeBottom - bubbleSize.height);
    }
    bubble.frame = CGRectMake(x, y, bubbleSize.width, bubbleSize.height);

    // Un tap DANS la bulle ne doit pas refermer : geste absorbant sans effet.
    [bubble addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:[TPKInfoTooltip class] action:@selector(tpk_noop)]];

    // ── Fermeture au scroll de la table hôte (remonter les superviews) ──
    UIView *crawler = sender;
    while (crawler && ![crawler isKindOfClass:[UIScrollView class]]) {
        crawler = crawler.superview;
    }
    if ([crawler isKindOfClass:[UIScrollView class]]) {
        _tpk_hostScrollView = (UIScrollView *)crawler;
        [_tpk_hostScrollView.panGestureRecognizer
            addTarget:[TPKInfoTooltip class]
               action:@selector(tpk_scrollDismissed)];
    }

    _tpk_visibleInfoButton = sender;
    _tpk_overlay = overlay;
    [window addSubview:overlay];

    // ── Animation discrète et native (fade + micro-zoom) ──
    overlay.alpha = 0.0;
    bubble.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.18
        delay:0.0
        options:UIViewAnimationOptionCurveEaseOut |
                UIViewAnimationOptionAllowUserInteraction |
                UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            overlay.alpha = 1.0;
            bubble.transform = CGAffineTransformIdentity;
        }
        completion:nil];
}

@end
