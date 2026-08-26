/*
 * 7tv-settings-controller.m
 *
 * Style : copie pixel-perfect du style Twitch natif (InsetGrouped).
 *   - Fond          : #0E0E10  (noir profond, identique à l'app Twitch)
 *   - Cellules      : #1F1F23  (gris foncé)
 *   - Angles        : UITableViewStyleInsetGrouped (natif iOS)
 *   - Header 7TV    : logo + "7TV SETTINGS" gris clair (comme les autres sections Twitch)
 *   - Séparateurs   : couleur Twitch #2A2A2E
 *   - Texte         : blanc / gris secondaire
 *   - Accent        : violet 7TV rgb(142, 69, 224)
 */

#import "Settings/7tv-settings-controller.h"
#import "Core/7tv-core-manager.h"
#import "Logs/7tv-logs-controller.h"
#import "Network/7tv-network-emote-cache.h"
#import "Emote/7tv-emote-image-cache.h"
#import "UI/7tv-ui-logo.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Localization/7tv-localization-manager.h"
#import "System/7tv-system-native-behavior-hooks.h"
#import "System/7tv-system-home-features.h"
#import "Adblock/7tv-adblock-settings.h"
#import "Adblock/7tv-adblock-proxy-status.h"
#import "Diagnostics/7tv-hook-diagnostics.h"
#import "Settings/7tv-settings-transfer.h"
#import "UI/7tv-info-tooltip.h"
#import "UI/7tv-oled-mode.h"
#import <objc/runtime.h>
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"
static NSString *const kS7TVFavoriteEmoteNamesKey = @"s7tv_favorite_emote_names";

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Palette couleurs
// ─────────────────────────────────────────────────────────────────────────────

// Fond général de la tableView (noir profond Twitch). En mode OLED : noir pur.
static UIColor *S7TVBg(void) {
    if (S7TVOLEDModeEnabled()) return UIColor.blackColor;
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}

// Fond des cellules (gris foncé Twitch). En mode OLED : gris quasi noir pour
// garder les cellules InsetGrouped discernables sur le fond noir pur.
static UIColor *S7TVCellBg(void) {
    if (S7TVOLEDModeEnabled()) return [UIColor colorWithWhite:0.05 alpha:1.0];
    return [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23
}

// Séparateurs de table : #2A2A2E en mode normal, plus discrets en OLED.
static UIColor *S7TVSeparatorColor(void) {
    if (S7TVOLEDModeEnabled()) return [UIColor colorWithWhite:0.12 alpha:1.0];
    return [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
}

// Violet 7TV / Twitch
static UIColor *S7TVAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // #8E45E0
}

// Gris secondaire (sous-titres, icônes)
static UIColor *S7TVGray(void) {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

// Couleur d'icône d'un réglage à interrupteur : gris système quand l'option
// est désactivée, couleur propre à la fonction quand elle est activée.
// Règle ON/OFF centralisée pour ne pas la recoder dans chaque cellule.
static UIColor *S7TVSwitchIconColor(UIColor *onColor, BOOL isOn) {
    return isOn ? onColor : [UIColor systemGrayColor];
}

// Grise/dégrise une cellule dont l'icône doit refléter l'état d'une catégorie
// mère. Sous-options (switchs) désactivées quand la catégorie mère l'est :
// icône forcée en gris système quand `enabled` est NO ; quand YES, elle garde
// la couleur posée à la création (les cellules sont reconstruites à chaque
// cellForRow, donc jamais obsolètes).
static void S7TVApplyCellEnabledState(UITableViewCell *cell, BOOL enabled) {
    cell.userInteractionEnabled = enabled;
    cell.contentView.alpha = enabled ? 1.0 : 0.4;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UISwitch class]]) {
            ((UISwitch *)v).enabled = enabled;
        } else if (!enabled && [v isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)v).tintColor = [UIColor systemGrayColor];
        }
    }
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
    NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
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
        S7TVLoadSettingsEmoteImage(favoriteIDs[index], imageView);
    }
    return preview;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers UI
// ─────────────────────────────────────────────────────────────────────────────

// Icône SF Symbol 22×22 pts
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

// Cellule standard avec icône + titre + (optionnel) sous-titre + chevron
// Style taille police identique Twitch natif : titre 17pt Regular, sous-titre 12pt Regular gris
// infoKey (optionnel) : clé de description affichée derrière un bouton "i"
// placé avant le chevron — remplace les longues descriptions permanentes.
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
    // Twitch natif : 17pt Regular (même poids que les cellules Settings iOS)
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.numberOfLines = 1;
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *infoButton = infoKey.length > 0
        ? [S7TVInfoTooltip infoButtonWithKey:infoKey] : nil;

    // Le contentView se termine avant le chevron natif : un bouton ancré au
    // trailing du contentView ne chevauche donc jamais l'accessoire.
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
        // Sous-titre : 12pt Regular gris (identique Twitch)
        subLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subLbl.textColor = S7TVGray();
        subLbl.numberOfLines = 1;
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;

        // Stack vertical centré dans la cellule
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
            // Assure que le stack ne déborde pas verticalement
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
            // CRITIQUE : top+bottom pour que le label ait une hauteur résolue
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

static char kS7TVSwitchOnColorKey;

// Garde l'icône d'un interrupteur synchronisée avec son état réel : quand
// l'utilisateur bascule le switch, l'icône passe immédiatement en gris (OFF)
// ou en couleur (ON), sans attendre un reload de la table (la plupart des
// handlers de bascule ne relancent pas la tableView).
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

// Cellule avec UISwitch
// Titre 17pt Regular (identique Twitch natif), switch violet 7TV
// infoKey (optionnel) : clé de description derrière un bouton "i" placé
// entre le label et le switch (remplace les footers descriptifs).
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
    // 17pt Regular = taille standard iOS Settings / Twitch natif
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor];
    // 0 = illimité (pas de troncature) — un libellé trop long pour tenir sur
    // une ligne passe à la ligne au lieu d'être coupé avec "…". La hauteur de
    // la cellule doit être en UITableViewAutomaticDimension côté delegate
    // pour que ça s'affiche correctement (voir heightForRowAtIndexPath des
    // controllers qui utilisent cette cellule).
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on          = isOn;
    sw.onTintColor = S7TVAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    // Icône synchronisée avec l'état réel du switch (gris quand OFF, couleur
    // quand ON) — voir S7TVSwitchIconUpdater.
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

        // Switch d'abord : taille intrinsèque fixe (UISwitch ne se redimensionne
        // jamais), positionné uniquement par son trailing + centerY. Aucune
        // contrainte de leading dessus — sinon un texte long crée un conflit
        // avec le trailing fixe (constraint requise vs requise), qu'AutoLayout
        // résout de façon imprévisible : c'était la cause du switch poussé hors
        // de la cellule (et donc non tappable).
        [sw.trailingAnchor   constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [sw.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],

        // Label : borné par le switch via un <= (pas un >= côté switch) — se
        // compresse et tronque proprement (numberOfLines=1 + "…") si le texte
        // est trop long pour la largeur disponible, sans jamais pousser le
        // switch ni entrer en conflit avec sa position fixe ci-dessus.
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

// Header de section style Twitch : logo (optionnel) + texte gris uppercase
// Identique visuellement au header "7TV SETTINGS" de la capture
// infoKey (optionnel) : clé de description derrière un bouton "i" aligné à
// droite du header (pour les descriptions qui concernent toute la section).
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
        // Petit logo 7TV à gauche du texte, comme sur la capture
        NSData *d = [[NSData alloc]
            initWithBase64EncodedString:kS7TVLogoBase64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *logoImg = d ? [UIImage imageWithData:d scale:2.0] : nil;

        if (logoImg) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:logoImg];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [container addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
                [iv.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
                [iv.widthAnchor    constraintEqualToConstant:22],
                [iv.heightAnchor   constraintEqualToConstant:16],

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

    // Header texte seul (sans logo)
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Méthode utilitaire commune pour styleTableView
// ─────────────────────────────────────────────────────────────────────────────

static void S7TVStyleTableView(UITableView *tv) {
    tv.backgroundColor   = S7TVBg();
    tv.separatorColor    = S7TVSeparatorColor();
    tv.separatorInset    = UIEdgeInsetsMake(0, 52, 0, 0);
    // Défaut : hauteur de ligne auto-calculée à partir du contenu (nécessaire
    // pour que S7TVSwitchCell puisse s'étendre sur 2 lignes — voir son
    // commentaire numberOfLines=0). Les controllers qui ont besoin d'une
    // hauteur fixe pour une section donnée (ex: liste de favoris à 52pt)
    // gardent la priorité via leur propre heightForRowAtIndexPath: — cette
    // valeur n'est qu'un filet de sécurité pour l'estimation initiale.
    tv.rowHeight         = UITableViewAutomaticDimension;
    tv.estimatedRowHeight = 60;
}

// Re-style + reload un écran de réglages quand le mode OLED bascule : les
// couleurs S7TVBg()/S7TVCellBg()/S7TVSeparatorColor() sont OLED-aware, mais
// la table (fond + séparateurs) et ses cellules doivent être re-rendues pour
// refléter la nouvelle palette.
static void S7TVApplyOLEDStyle(UITableViewController *controller) {
    S7TVStyleTableView(controller.tableView);
    [controller.tableView reloadData];
}

// Enregistre l'observateur de bascule OLED commun à tous les écrans de
// réglages 7TV (chaque controller fournit son propre -s7tv_oledModeDidChange).
static void S7TVRegisterOLEDObserver(id observer) {
    [[NSNotificationCenter defaultCenter] addObserver:observer
        selector:@selector(s7tv_oledModeDidChange)
            name:S7TVOLEDModeDidChangeNotification object:nil];
}

// Helper NSUserDefaults
// Variante avec défaut ON : utilisée pour les clés qui doivent démarrer
// activées tant que l'utilisateur n'a jamais touché au switch (ex. Auto
// Collect Channel Points). boolForKey: seul renverrait NO en l'absence de
// la clé, ce qui ne correspond pas au comportement par défaut souhaité.
static BOOL S7TVBoolDefaultYes(NSString *key) {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    return [prefs objectForKey:key] != nil ? [prefs boolForKey:key] : YES;
}
static void S7TVSetBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Résolution d'emote d'origine (miroir de kDefaultEmote7TVResolution dans
// 7tv-chat-appearance-config.m — valeur non exportée).
static const NSInteger kS7TVDefaultEmoteResolution = 2;

// Suffixe "- Par défaut" / "- Default" pour les sous-titres des réglages à
// menu de choix : aide à reconnaître la valeur d'origine. Ignoré quand le
// titre est déjà exactement le mot "Par défaut" (écran au lancement), où le
// marqueur serait purement redondant.
static NSString *S7TVValueWithDefaultMark(NSString *value, BOOL isDefault) {
    if (!isDefault) return value;
    if ([value isEqualToString:L(@"launch_default")]) return value;
    return [value stringByAppendingString:L(@"common_default_suffix")];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Intégration dans les paramètres Twitch natifs
// ============================================================

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

    // Pas de header de section : le titre "TwitchPlusK Settings" de la
    // cellule suffit (un header au-dessus doublait le nom). Le logo 7TV est
    // directement dans la cellule pour identifier d'un coup d'œil les
    // paramètres du tweak.
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
    // Logo 7TV à gauche du titre : identifie immédiatement les paramètres
    // du tweak dans la liste native.
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (logoData) cell.imageView.image = [UIImage imageWithData:logoData scale:2.0];
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
    [[SevenTVManager sharedManager] log:@"✅ 7TV Settings ouvert depuis les paramètres Twitch"];
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

// ============================================================
// MARK: - SevenTVSettingsController  (Hub principal)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVHomeSection) {
    S7TVHomeSectionMain     = 0,  // 4 catégories : Apparence / Contenu / Adblock / Avancé
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
    [[SevenTVManager sharedManager]
        log:@"✅ AccountMenuViewController swizzlé — section 7TV Settings injectée"];
}

- (instancetype)init {
    // InsetGrouped = angles arrondis natifs iOS, identique aux paramètres Twitch
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    S7TVStyleTableView(self.tableView);
    [self buildNavBar];

    // Rafraîchit immédiatement titres/headers/labels si la langue change
    // pendant que cet écran est affiché (toggle juste en dessous, section
    // Langue) — pas besoin de fermer/rouvrir l'écran pour voir l'effet.
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(s7tv_languageDidChange)
            name:S7TVLanguageDidChangeNotification object:nil];
    S7TVRegisterOLEDObserver(self);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)s7tv_languageDidChange {
    [self buildNavBar];
    [self.tableView reloadData];
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)buildNavBar {
    // Titre nav bar : logo 7TV + "TwitchPlusK"
    NSData *d = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = d ? [UIImage imageWithData:d scale:2.0] : nil;

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
            [iv.widthAnchor    constraintEqualToConstant:28],
            [iv.heightAnchor   constraintEqualToConstant:20],
            [lbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
            [lbl.centerYAnchor constraintEqualToAnchor:tv.centerYAnchor],
            [lbl.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        ]];
        CGFloat w = 28 + 6 + [badgeText sizeWithAttributes:@{
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

// ── TableView ──

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVHomeSectionMain:     return 4; // Apparence / Contenu / Adblock / Avancé
        case S7TVHomeSectionLanguage: return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
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

// Résumé en pied de la section principale (remplace l'ancien écran
// "Statistiques" séparé — ce n'était que du contenu en lecture seule, pas
// un réglage. Recalculé à chaque affichage de l'écran (viewWillAppear),
// pas de rafraîchissement en continu.
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (s != S7TVHomeSectionMain) {
        UIView *v = [[UIView alloc] init];
        v.backgroundColor = [UIColor clearColor];
        return v;
    }

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSUInteger total = mgr.globalEmotes.count + mgr.channelEmotes.count;
    NSString *channel = mgr.currentChannelName ?: L(@"stats_no_channel");

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
    // Rafraîchit le résumé (compteurs d'emotes) à chaque retour sur l'accueil.
    [self.tableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Section Main : Apparence / Contenu / Adblock / Avancé
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
        // Sous-titres courts de navigation (résumés de catégories) : gardés
        // volontairement visibles, ils aident à comprendre le menu.
        return S7TVNavCell(title, subtitle, sfName, iconTint, nil);
    }

    // Section Langue — segmented control FR/EN, pas un simple switch : il y a
    // deux valeurs possibles (pas juste ON/OFF), un segmented rend l'état
    // actuel immédiatement lisible sans avoir à lire un libellé à côté.
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

// Bascule la langue globale de l'app — persistée immédiatement (voir
// S7TVLocalization.setCurrentLanguage:) et notifiée à tous les écrans de
// réglages actuellement ouverts via S7TVLanguageDidChangeNotification
// (voir s7tv_languageDidChange ci-dessus). Pas de redémarrage nécessaire.
- (void)languageSegmentChanged:(UISegmentedControl *)seg {
    [S7TVLocalization shared].currentLanguage =
        (seg.selectedSegmentIndex == 1) ? S7TVLanguageEnglish : S7TVLanguageFrench;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

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


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVAdblockPageController
// Réglages du moteur TwitchAdBlock importé : le moteur et le proxy restent
// séparables, et l'adresse intégrée peut être remplacée sans toucher au code.
// ─────────────────────────────────────────────────────────────────────────────

@interface SevenTVAdblockPageController () <UITextFieldDelegate>
@property (nonatomic, assign) S7TVAdblockProxyStatus proxyStatus;
@property (nonatomic, strong) NSMutableArray<NSString *> *proxies;
@end

static const NSInteger kS7TVProxyTextFieldTag = 0x7A01;
static const NSInteger kS7TVProxyUpButtonTag  = 0x7A02;
static const NSInteger kS7TVProxyDownButtonTag = 0x7A03;

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
    if (S7TVAdblockIsEnabled() && S7TVAdblockProxyIsEnabled()) {
        [self refreshProxyStatus];
    }
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [S7TVInfoTooltip dismiss];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (!S7TVAdblockIsEnabled()) return 0;
    if (!S7TVAdblockProxyIsEnabled()) return 1;
    return S7TVAdblockCustomProxyIsEnabled() ? 4 + self.proxies.count : 3;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    // Le footer descriptif du proxy vit désormais derrière le "i" du header.
    return S7TVSectionHeader(section == 0 ? L(@"section_general")
                                          : L(@"adblock_section_proxy"), NO,
                             section == 0 ? nil : @"adblock_proxy_privacy_footer");
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
        if (indexPath.row == 0) {
            // La description du moteur (ex-footer de section) est derrière
            // le "i" de la ligne d'activation.
            return S7TVSwitchCell(L(@"adblock_enable"), @"shield.lefthalf.filled",
                S7TVAccent(), S7TVAdblockIsEnabled(), self, @selector(toggleAdblock:),
                @"adblock_engine_footer");
        }
        return S7TVSwitchCell(L(@"adblock_hide_go_ad_free"), @"rectangle.slash",
            [UIColor colorWithRed:0.95 green:0.45 blue:0.25 alpha:1.0],
            S7TVAdblockHideAdFreeButtonIsEnabled(), self,
            @selector(toggleHideGoAdFree:), nil);
    }

    BOOL proxyEnabled = S7TVAdblockProxyIsEnabled();
    if (indexPath.row == 0) {
        return S7TVSwitchCell(L(@"adblock_video_proxy"),
            @"network", UIColor.systemBlueColor, proxyEnabled,
            self, @selector(toggleAdblockProxy:), nil);
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
    if (indexPath.section == 1 && S7TVAdblockIsEnabled() &&
        S7TVAdblockProxyIsEnabled() && S7TVAdblockCustomProxyIsEnabled() &&
        indexPath.row == [self addProxyRowIndex]) {
        [self.proxies addObject:@""];
        [self saveProxies];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (void)toggleAdblock:(UISwitch *)sender {
    S7TVAdblockSetEnabled(sender.isOn);
    [self.tableView reloadData];
    if (sender.isOn && S7TVAdblockProxyIsEnabled()) [self refreshProxyStatus];
}

- (void)toggleHideGoAdFree:(UISwitch *)sender {
    S7TVAdblockSetHideAdFreeButtonEnabled(sender.isOn);
}

- (void)toggleAdblockProxy:(UISwitch *)sender {
    S7TVAdblockSetProxyEnabled(sender.isOn);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
    if (sender.isOn) [self refreshProxyStatus];
}

- (void)toggleAdblockCustomProxy:(UISwitch *)sender {
    S7TVAdblockSetCustomProxyEnabled(sender.isOn);
    self.proxyStatus = S7TVAdblockProxyStatusUnknown;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
    [self refreshProxyStatus];
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
    return cell;
}

- (UIButton *)proxyArrowButton:(NSString *)symbol tag:(NSInteger)tag action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITableViewCell *)proxyRowCellForIndex:(NSInteger)index {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"S7TVProxyRowCell"];
    UIButton *up = nil;
    UIButton *down = nil;
    UITextField *field = nil;
    if (cell) {
        up = (UIButton *)[cell.contentView viewWithTag:kS7TVProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kS7TVProxyDownButtonTag];
        field = (UITextField *)[cell.contentView viewWithTag:kS7TVProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"S7TVProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up = [self proxyArrowButton:@"chevron.up" tag:kS7TVProxyUpButtonTag
                             action:@selector(proxyUpTapped:)];
        down = [self proxyArrowButton:@"chevron.down" tag:kS7TVProxyDownButtonTag
                               action:@selector(proxyDownTapped:)];
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
            [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
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
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)proxyDownTapped:(UIButton *)button {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:button]];
    NSInteger index = [self proxyIndexForRow:path.row];
    if (index < 0 || index >= (NSInteger)self.proxies.count - 1) return;
    [self.proxies exchangeObjectAtIndex:index withObjectAtIndex:index + 1];
    [self saveProxies];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)proxyFieldChanged:(UITextField *)field {
    NSIndexPath *path = [self.tableView indexPathForCell:
        [self cellForProxySubview:field]];
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
    if (index < 0 || index >= (NSInteger)self.proxies.count) return;
    [self.proxies removeObjectAtIndex:index];
    [self saveProxies];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    [self refreshProxyStatus];
}

- (void)refreshProxyStatus {
    if (!S7TVAdblockIsEnabled() || !S7TVAdblockProxyIsEnabled()) return;
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
        if (!self) return;
        self.proxyStatus = status;
        [self reloadProxyStatusRow];
    });
}

- (void)reloadProxyStatusRow {
    if (!S7TVAdblockIsEnabled() || !S7TVAdblockProxyIsEnabled()) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:[self statusRowIndex] inSection:1];
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


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVAppearancePageController  (ex-SevenTVEmotesPageController)
// ─────────────────────────────────────────────────────────────────────────────

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

// Affichage des emotes (animations + résolution CDN 7TV). Le kill switch du
// renderer est désormais rangé dans Avancé : ce n'est pas un réglage visuel.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    // Section 0 = description d'introduction, section 1 = réglages.
    return (s == 0) ? 1 : 4;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return (s == 0) ? 8 : 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (s == 0) return [[UIView alloc] init];
    return S7TVSectionHeader(L(@"section_affichage"), NO, nil);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    // L'explication "résolution élevée = plus net mais plus lourd" vit
    // désormais derrière le bouton "i" de la ligne de résolution.
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        // Description d'introduction : les réglages du chat custom vivent
        // dans le panneau du picker (bouton « Aa »), pas dans cette page.
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = L(@"desc_chat_custom_location");
        lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        lbl.textColor = S7TVGray();
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
    if (ip.section != 1) return [[UITableViewCell alloc] init];
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    switch (ip.row) {
        case 0: return S7TVSwitchCell(L(@"switch_oled_mode"),
                    @"circle.lefthalf.filled",
                    UIColor.systemIndigoColor,
                    S7TVOLEDModeEnabled(),
                    self, @selector(toggleOLEDMode:), @"desc_oled_mode");
        case 1: return S7TVSwitchCell(L(@"switch_animations_picker"),
                    @"photo.stack",
                    UIColor.systemIndigoColor,
                    mgr.showPickerAnimations,
                    self, @selector(togglePickerAnimations:), nil);
        case 2: {
            UITableViewCell *cell = S7TVSwitchCell(L(@"switch_animations_favorites_only"),
                        @"star.circle",
                        UIColor.systemYellowColor,
                        mgr.showPickerAnimationsFavoritesOnly,
                        self, @selector(togglePickerAnimationsFavoritesOnly:), nil);
            [self s7tv_applyPickerAnimSubOptionEnabledState:cell];
            return cell;
        }
        case 3: {
            // Menu de choix (action sheet) plutôt qu'un segmented : même
            // logique que "Écran au lancement" — la valeur courante sert de
            // sous-titre (marquée "- Par défaut" quand c'est celle d'origine),
            // le tap ouvre la liste des résolutions. La longue explication
            // (cache vidé, impact mémoire) est derrière le bouton "i".
            NSInteger current = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
            current = MIN(4, MAX(1, current));
            return S7TVNavCell(L(@"setting_emote_resolution"),
                S7TVValueWithDefaultMark(
                    [NSString stringWithFormat:@"%ldx", (long)current],
                    current == kS7TVDefaultEmoteResolution),
                @"photo.stack.fill", S7TVAccent(),
                @"setting_resolution_clears_cache");
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && ip.row == 3) {
        [self presentResolutionPickerFromCell:[tv cellForRowAtIndexPath:ip]];
    }
}

- (void)toggleOLEDMode:(UISwitch *)sw {
    S7TVOLEDModeSetEnabled(sw.isOn);
}
- (void)togglePickerAnimations:(UISwitch *)sw {
    [SevenTVManager sharedManager].showPickerAnimations = sw.isOn;
    // Reload pour griser/dégriser la sous-option "Favoris uniquement", qui
    // dépend de ce réglage.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                   withRowAnimation:UITableViewRowAnimationNone];
}
- (void)togglePickerAnimationsFavoritesOnly:(UISwitch *)sw {
    [SevenTVManager sharedManager].showPickerAnimationsFavoritesOnly = sw.isOn;
}

// Menu de choix de la résolution des emotes (action sheet, même logique que
// le picker "Écran au lancement" de la page Contenu) : ✓ sur la valeur
// courante, Annuler, puis vidage du cache si la résolution change.
- (void)presentResolutionPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_emote_resolution")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
    NSInteger current = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
    current = MIN(4, MAX(1, current));
    for (NSInteger resolution = 1; resolution <= 4; resolution++) {
        NSString *title = [NSString stringWithFormat:@"%ldx", (long)resolution];
        if (resolution == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf s7tv_applyEmoteResolution:resolution];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)s7tv_applyEmoteResolution:(NSInteger)resolution {
    SevenTVChatAppearanceConfig *cfg = [SevenTVChatAppearanceConfig sharedConfig];
    if (resolution == cfg.emote7TVResolution) return;

    // Enregistrer d'abord : tout nouveau chargement créé pendant le refresh
    // utilisera immédiatement l'URL /Nx.webp choisie.
    [cfg setValue:(CGFloat)resolution forSizeKey:@"emote7TVResolution"];
    __weak typeof(self) weakSelf = self;
    [[SevenTVManager sharedManager] clearAllCachesWithCompletion:^(NSUInteger clearedCount) {
        (void)clearedCount;
        [weakSelf.tableView reloadData];
    }];
}

// Grise visuellement la sous-option quand "Animations dans le picker" est
// désactivé, sans jamais modifier sa valeur stockée en NSUserDefaults —
// même pattern que s7tv_applyEnabledState: dans SevenTVDebugPageController,
// mais dépendant ici de showPickerAnimations plutôt que de logsEnabled.
- (void)s7tv_applyPickerAnimSubOptionEnabledState:(UITableViewCell *)cell {
    S7TVApplyCellEnabledState(cell, [SevenTVManager sharedManager].showPickerAnimations);
}

@end



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVContentPageController  (ex-Statistiques + ex-Contrôle du stream)
// Favoris (liste + import) et réglages liés au stream, regroupés sous
// "Contenu" — l'ancien écran Statistiques n'affichait que du contenu en
// lecture seule (déplacé en résumé sur l'accueil) ; Auto Collect Channel
// Points, seul réglage de l'ancien écran "Contrôle du stream", rejoint ici.
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVContentSection) {
    S7TVContentSectionFavorites = 0,  // Mes favoris (nav) + Importer depuis PC
    S7TVContentSectionStream    = 1,  // Auto Collect Channel Points
    S7TVContentSectionHome      = 2,  // Launch Screen + Stories + fil Live
    S7TVContentSectionRotation  = 3,  // Bouton + auto-lock gauche/droite
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

static NSString *S7TVAutoOrientationLockModeTitle(S7TVAutoOrientationLockMode mode) {
    switch (mode) {
        case S7TVAutoOrientationLockModeLandscapeLeft:  return L(@"orientation_left");
        case S7TVAutoOrientationLockModeLandscapeRight: return L(@"orientation_right");
        case S7TVAutoOrientationLockModeBothLandscapes: return L(@"orientation_both");
        case S7TVAutoOrientationLockModeDisabled:
        default:                                        return L(@"orientation_auto_off");
    }
}

@interface SevenTVContentPageController () <UIDocumentPickerDelegate>
- (void)presentLaunchDestinationPickerFromCell:(UIView *)anchor;
- (void)presentAutoOrientationLockPickerFromCell:(UIView *)anchor;
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
}

- (void)s7tv_oledModeDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        S7TVApplyOLEDStyle(self);
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Rafraîchit le compteur de favoris à chaque retour sur cet écran.
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [S7TVInfoTooltip dismiss];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVContentSectionFavorites: return 2;
        case S7TVContentSectionStream:    return 1;
        case S7TVContentSectionHome:      return 3;
        case S7TVContentSectionRotation:  return 2;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == S7TVContentSectionFavorites) return 52;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVContentSectionFavorites: return S7TVSectionHeader(L(@"section_favoris"), NO, nil);
        case S7TVContentSectionStream:    return S7TVSectionHeader(L(@"section_stream"), NO, nil);
        // Descriptions de section déplacées derrière le "i" du header
        // (ex-footers descriptifs affichés en permanence).
        case S7TVContentSectionHome:      return S7TVSectionHeader(L(@"section_home_playback"), NO,
                                              @"desc_home_playback_settings");
        case S7TVContentSectionRotation:  return S7TVSectionHeader(L(@"section_rotation"), NO,
                                              @"desc_orientation_lock_settings");
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    // Les descriptions de section (auto-collect, accueil/lecture, rotation)
    // vivent désormais derrière les boutons "i" des headers/lignes.
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // ── Section Stream : Auto Collect Channel Points ──────────────────────
    if (ip.section == S7TVContentSectionStream) {
        // La description (ex-footer de section) est derrière le "i" de la ligne.
        return S7TVSwitchCell(L(@"switch_auto_collect_title"),
                    @"giftcard.fill", [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0],
                    S7TVBoolDefaultYes(kTCLiveAutoCollectChannelPoints), self,
                    @selector(toggleAutoCollect:), @"desc_auto_collect");
    }

    // ── Section Accueil et lecture : fonctionnalités TwitchAdBlock ──────
    if (ip.section == S7TVContentSectionHome) {
        if (ip.row == 0) {
            S7TVLaunchDestination destination = s7tv_launchDestination();
            return S7TVNavCell(L(@"setting_launch_screen"),
                S7TVValueWithDefaultMark(S7TVLaunchDestinationTitle(destination),
                    destination == S7TVLaunchDestinationDefault),
                @"rectangle.stack.fill", S7TVAccent(), nil);
        }
        if (ip.row == 1) {
            return S7TVSwitchCell(L(@"switch_hide_twitch_stories"),
                @"circle.slash", [UIColor colorWithRed:0.95 green:0.35 blue:0.50 alpha:1.0],
                s7tv_hideTwitchStoriesEnabled(), self, @selector(toggleHideTwitchStories:), nil);
        }
        return S7TVSwitchCell(L(@"switch_keep_live_feed_playing"),
            @"play.circle.fill", [UIColor colorWithRed:0.30 green:0.75 blue:0.45 alpha:1.0],
            s7tv_keepLiveFeedPlayingEnabled(), self, @selector(toggleKeepLiveFeedPlaying:), nil);
    }

    // ── Section Rotation : bouton manuel + détection automatique ─────────
    if (ip.section == S7TVContentSectionRotation) {
        if (ip.row == 0) {
            return S7TVSwitchCell(L(@"switch_orientation_lock_button"),
                        @"lock.rotation", S7TVAccent(),
                        s7tv_orientationLockButtonEnabled(), self,
                        @selector(toggleOrientationLockButton:), nil);
        }

        // Menu de choix (action sheet) plutôt qu'un segmented : même logique
        // que "Écran au lancement" — la valeur courante sert de sous-titre
        // (marquée "- Par défaut" quand c'est le mode d'origine), le tap
        // ouvre la liste des modes. Grisé si le bouton est désactivé.
        S7TVAutoOrientationLockMode mode = s7tv_autoOrientationLockMode();
        UITableViewCell *cell = S7TVNavCell(L(@"setting_orientation_auto_lock"),
            S7TVValueWithDefaultMark(S7TVAutoOrientationLockModeTitle(mode),
                mode == S7TVAutoOrientationLockModeDisabled),
            @"iphone.gen3.radiowaves.left.and.right", S7TVAccent(), nil);
        BOOL enabled = s7tv_orientationLockButtonEnabled();
        S7TVApplyCellEnabledState(cell, enabled);
        return cell;
    }

    // ── Section Favoris ─────────────────────────────────────────────────────
    NSArray *favs = [[SevenTVManager sharedManager] favoriteEmoteIDsSnapshot];

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = S7TVGray();
    cell.detailTextLabel.numberOfLines = 0;

    if (ip.row == 0) {
        // Cellule tappable : ouvre la liste des favoris
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
        [cell.contentView addSubview:lbl];

        UILabel *countLbl = [[UILabel alloc] init];
        countLbl.text = [NSString stringWithFormat:@"%lu", (unsigned long)favs.count];
        countLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        countLbl.textColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];
        countLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:countLbl];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor      constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [lbl.topAnchor          constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [lbl.bottomAnchor       constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [countLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [countLbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    // Row 1 : Importer depuis fichier PC
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *importIcon = S7TVIcon(@"square.and.arrow.down",
        [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]);
    [cell.contentView addSubview:importIcon];

    UILabel *importLbl = [[UILabel alloc] init];
    importLbl.text = L(@"action_import_from_pc");
    importLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    importLbl.textColor = [UIColor whiteColor];
    importLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *importSub = [[UILabel alloc] init];
    importSub.text = L(@"subtitle_import_from_pc");
    importSub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    importSub.textColor = S7TVGray();
    importSub.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *importStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[importLbl, importSub]];
    importStack.axis      = UILayoutConstraintAxisVertical;
    importStack.spacing   = 2;
    importStack.alignment = UIStackViewAlignmentLeading;
    importStack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:importStack];

    [NSLayoutConstraint activateConstraints:@[
        [importIcon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [importIcon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [importStack.leadingAnchor  constraintEqualToAnchor:importIcon.trailingAnchor constant:14],
        [importStack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [importStack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
        [importStack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
        [importStack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
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
    if (ip.section == S7TVContentSectionFavorites && ip.row == 1) {
        [self importFavoritesFromFile];
        return;
    }
    if (ip.section == S7TVContentSectionHome && ip.row == 0) {
        [self presentLaunchDestinationPickerFromCell:[tv cellForRowAtIndexPath:ip]];
        return;
    }
    if (ip.section == S7TVContentSectionRotation && ip.row == 1) {
        [self presentAutoOrientationLockPickerFromCell:[tv cellForRowAtIndexPath:ip]];
    }
}

- (void)toggleAutoCollect:(UISwitch *)sw { S7TVSetBool(kTCLiveAutoCollectChannelPoints, sw.isOn); }
- (void)toggleHideTwitchStories:(UISwitch *)sw {
    s7tv_setHideTwitchStoriesEnabled(sw.isOn);
}
- (void)toggleKeepLiveFeedPlaying:(UISwitch *)sw {
    s7tv_setKeepLiveFeedPlayingEnabled(sw.isOn);
}
- (void)toggleOrientationLockButton:(UISwitch *)sw {
    s7tv_setOrientationLockButtonEnabled(sw.isOn);
    [self.tableView reloadSections:
        [NSIndexSet indexSetWithIndex:S7TVContentSectionRotation]
                     withRowAnimation:UITableViewRowAnimationNone];
}

// Menu de choix du mode d'auto-lock (action sheet, même logique que le picker
// "Écran au lancement") : ✓ sur le mode courant, Annuler, puis application
// immédiate et rechargement de la section pour rafraîchir le sous-titre.
- (void)presentAutoOrientationLockPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_orientation_auto_lock")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.view.tintColor = S7TVAccent();
    S7TVAutoOrientationLockMode current = s7tv_autoOrientationLockMode();
    for (NSInteger raw = S7TVAutoOrientationLockModeDisabled;
         raw <= S7TVAutoOrientationLockModeBothLandscapes; raw++) {
        S7TVAutoOrientationLockMode mode = (S7TVAutoOrientationLockMode)raw;
        NSString *title = S7TVAutoOrientationLockModeTitle(mode);
        if (mode == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            s7tv_setAutoOrientationLockMode(mode);
            [weakSelf.tableView reloadSections:
                [NSIndexSet indexSetWithIndex:S7TVContentSectionRotation]
                         withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentLaunchDestinationPickerFromCell:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:L(@"setting_launch_screen")
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    // Textes des actions en violet (accent des settings) au lieu du bleu
    // système — s'applique à toutes les actions non-destructives du menu.
    sheet.view.tintColor = S7TVAccent();
    S7TVLaunchDestination current = s7tv_launchDestination();
    for (NSInteger raw = S7TVLaunchDestinationDefault;
         raw <= S7TVLaunchDestinationProfile; raw++) {
        S7TVLaunchDestination destination = (S7TVLaunchDestination)raw;
        NSString *title = S7TVLaunchDestinationTitle(destination);
        if (destination == current) title = [@"✓  " stringByAppendingString:title];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            s7tv_setLaunchDestination(destination);
            [weakSelf.tableView reloadSections:
                [NSIndexSet indexSetWithIndex:S7TVContentSectionHome]
                         withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// ── Import favoris depuis fichier JSON 7TV PC (inchangé, déplacé depuis
// l'ancien SevenTVStatsPageController) ──────────────────────────────────────

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

    // L'export 7TV PC peut avoir deux structures :
    //   - Tableau directement : [ "7TV:xxx", ... ]
    //   - Dict racine avec "ui.emote_menu.favorites" (format v0 hypothétique)
    //   - Dict racine avec "settings" → "ui.emote_menu.favorites" (format réel v1)
    NSArray *rawFavs = nil;
    if ([json isKindOfClass:[NSArray class]]) {
        rawFavs = (NSArray *)json;
    } else if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        // Format réel : { "settings": { "ui.emote_menu.favorites": [...] } }
        NSDictionary *settings = dict[@"settings"];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            rawFavs = settings[@"ui.emote_menu.favorites"];
        }
        // Fallback : clé à la racine (format alternatif)
        if (!rawFavs) {
            rawFavs = dict[@"ui.emote_menu.favorites"];
        }
    }

    if (!rawFavs) {
        [self s7tv_showAlert:L(@"alert_unknown_format_title")
                     message:L(@"error_missing_favorites_key")];
        return;
    }

    // Filtrer les entrées "7TV:<id>" — ignorer "PLATFORM:..."
    NSMutableArray<NSString *> *newIDs = [NSMutableArray array];
    for (id entry in rawFavs) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *s = (NSString *)entry;
        if ([s hasPrefix:@"7TV:"]) {
            [newIDs addObject:[s substringFromIndex:4]];
        }
    }

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
    [[SevenTVManager sharedManager] log:@"📥 Import favoris 7TV : %lu total, %lu ajoutés",
     (unsigned long)merged.count, (unsigned long)added];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { }

- (void)s7tv_showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                          style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVFavoritesListController
// Liste de toutes les emotes en favoris (IDs 7TV + noms résolus).
// ─────────────────────────────────────────────────────────────────────────────

@interface SevenTVFavoritesListController ()
- (void)s7tv_scheduleFavoriteNameCacheSave;
- (void)s7tv_scheduleFavoriteNameRowsReload;
- (void)s7tv_resolveMissingFavoriteNames;
@end

@implementation SevenTVFavoritesListController {
    NSArray<NSString *> *_favIDs;      // IDs purs (sans préfixe)
    NSDictionary<NSString *, NSString *> *_idToName; // emoteID → emoteName
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
    [self reloadFavs];

    // Bouton Vider
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

- (void)reloadFavs {
    _favIDs = [[[SevenTVManager sharedManager] favoriteEmoteIDsSnapshot] copy];

    // Commencer par les noms persistés : un favori importé peut ne pas faire
    // partie des emotes globales ou de la chaîne actuellement ouverte.
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *emoteID in _favIDs) {
        NSString *cachedName = _favoriteNameCache[emoteID];
        if (cachedName.length) map[emoteID] = cachedName;
    }

    // Les catalogues chargés localement restent prioritaires et évitent tout
    // appel réseau pour leurs emotes.
    void (^scan)(NSDictionary<NSString *, SevenTVEmote *> *) = ^(NSDictionary *dict) {
        [dict enumerateKeysAndObjectsUsingBlock:^(NSString *name, SevenTVEmote *emote, BOOL *stop) {
            if (emote.emoteID) map[emote.emoteID] = name;
        }];
    };
    dispatch_sync(mgr.emoteQueue, ^{
        scan(mgr.globalEmotes ?: @{});
        scan(mgr.channelEmotes ?: @{});
    });
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
    for (NSString *emoteID in _favIDs) {
        if (_idToName[emoteID].length || [_nameFetchesInFlight containsObject:emoteID]) continue;
        [_nameFetchesInFlight addObject:emoteID];

        NSString *escapedID = [emoteID stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emotes/%@",
                                          S7TV_API_BASE, escapedID ?: emoteID]];
        if (!url) {
            [_nameFetchesInFlight removeObject:emoteID];
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
                [strongSelf->_nameFetchesInFlight removeObject:emoteID];
                if (!resolvedName.length || ![strongSelf->_favIDs containsObject:emoteID]) return;

                strongSelf->_favoriteNameCache[emoteID] = resolvedName;
                NSMutableDictionary *names = [strongSelf->_idToName mutableCopy] ?: [NSMutableDictionary dictionary];
                names[emoteID] = resolvedName;
                strongSelf->_idToName = [names copy];
                [strongSelf s7tv_scheduleFavoriteNameCacheSave];
                [strongSelf s7tv_scheduleFavoriteNameRowsReload];
            });
        }] resume];
    }
}

// ── TableView ──

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _favIDs.count == 0 ? 1 : (NSInteger)_favIDs.count;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *title = _favIDs.count > 0
        ? [NSString stringWithFormat:L(@"favorites_count_format"), (unsigned long)_favIDs.count]
        : L(@"section_favoris");
    return S7TVSectionHeader(title, NO, nil);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Cas liste vide
    if (_favIDs.count == 0) {
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

    NSString *emoteID = _favIDs[ip.row];
    NSString *name    = _idToName[emoteID];   // nil si emote pas chargée

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    // Image emote (chargée via URLCache si dispo)
    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.contentMode = UIViewContentModeScaleAspectFit;
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.clipsToBounds = YES;
    [cell.contentView addSubview:thumb];

    S7TVLoadSettingsEmoteImage(emoteID, thumb);

    // Labels
    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name ?: L(@"favorite_emote_loading");
    nameLbl.font = [UIFont systemFontOfSize:15 weight:
        name ? UIFontWeightRegular : UIFontWeightLight];
    nameLbl.textColor = name ? [UIColor whiteColor] : S7TVGray();
    nameLbl.numberOfLines = 1;
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:nameLbl];

    UILabel *idLbl = [[UILabel alloc] init];
    // Tronquer l'ID pour ne pas déborder
    NSString *shortID = emoteID.length > 14
        ? [NSString stringWithFormat:@"%@…", [emoteID substringToIndex:14]]
        : emoteID;
    idLbl.text = shortID;
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

    // Bouton supprimer (swipe to delete géré via editingStyle, mais on ajoute aussi un bouton trash)
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

// Swipe-to-delete
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return _favIDs.count > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv
           editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return _favIDs.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tv
commitEditingStyle:(UITableViewCellEditingStyle)es
forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    NSString *removedID = _favIDs[ip.row];
    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSMutableArray *cur = [[manager favoriteEmoteIDsSnapshot] mutableCopy];
    [cur removeObject:removedID];
    [manager replaceFavoriteEmoteIDs:cur];
    [self reloadFavs];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

// Bouton Vider
- (void)clearAllFavs {
    if (_favIDs.count == 0) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_clear_favorites_title")
                         message:L(@"alert_clear_favorites_message")
        preferredStyle:UIAlertControllerStyleActionSheet];
    alert.message = [NSString stringWithFormat:L(@"alert_clear_favorites_message"),
                     (unsigned long)_favIDs.count];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_empty_action")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[SevenTVManager sharedManager] replaceFavoriteEmoteIDs:@[]];
            [self reloadFavs];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVHookDiagnosticsController
// Reprise de TWABDiagnosticsVC (TwitchAdBlock) : les lignes indiquent si les
// classes ciblées par les hooks se résolvent dans cette version de Twitch.
// ─────────────────────────────────────────────────────────────────────────────

@interface S7TVHookDiagnosticsController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *items;
@end

@implementation S7TVHookDiagnosticsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"diagnostics_title");
    S7TVStyleTableView(self.tableView);
    [self reloadDiagnostics];

    // Même comportement que TwitchAdBlock si l'écran est présenté sans pile
    // de navigation : le bouton Done ferme uniquement cet écran.
    BOOL presentedRoot = self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController != nil;
    if (presentedRoot) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self action:@selector(closeDiagnostics)];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // TwitchPlusK installe certains hooks après le chargement d'un framework ;
    // relire le même registre ici reflète leur état réel au moment consulté.
    [self reloadDiagnostics];
}

- (void)closeDiagnostics {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadDiagnostics {
    self.items = S7TVHookDiagnosticItems();
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"S7TVHookDiagnosticCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"S7TVHookDiagnosticCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = S7TVCellBg();
    NSDictionary<NSString *, id> *item = self.items[indexPath.row];
    BOOL present = [item[@"present"] boolValue];
    NSString *status = present ? L(@"diagnostics_ok") : L(@"diagnostics_missing");
    UIColor *color = present ? UIColor.systemGreenColor : UIColor.systemRedColor;
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *configuration = [cell defaultContentConfiguration];
        configuration.text = item[@"name"];
        configuration.textProperties.font = [UIFont monospacedSystemFontOfSize:11
                                                                          weight:UIFontWeightRegular];
        configuration.textProperties.color = UIColor.whiteColor;
        configuration.secondaryText = status;
        configuration.secondaryTextProperties.color = color;
        [cell setContentConfiguration:configuration];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = item[@"name"];
        cell.textLabel.font = [UIFont systemFontOfSize:11];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.text = status;
        cell.detailTextLabel.textColor = color;
    }
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return L(@"diagnostics_header");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return L(@"diagnostics_footer");
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVAdvancedPageController  (ex-SevenTVDebugPageController)
// Diagnostic — reste un vrai menu utilisateur (projet open source, les logs
// servent aussi à d'autres personnes pour remonter des bugs), pas un mode
// caché type "tap x5". Le kill switch du chat custom vit dans Options afin
// de rester disponible sans occuper la page Apparence. "Vider le cache"
// (ex-"Recharger les emotes" de l'accueil) atterrit ici en premier.
// ─────────────────────────────────────────────────────────────────────────────

@interface SevenTVAdvancedPageController () <UIDocumentPickerDelegate>
- (void)s7tv_exportSettingsFromAnchor:(UIView *)anchor;
- (void)s7tv_importSettingsFromFile;
- (void)s7tv_importSettingsAtURL:(NSURL *)url;
- (void)s7tv_applyImportedSettings;
- (void)s7tv_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation SevenTVAdvancedPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_avance");
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
    [self.tableView reloadData];
    [SevenTVURLProtocol refreshCachedEmoteCountWithCompletion:^(NSInteger count) {
        if (self.view.window) {
            NSIndexPath *cacheRow = [NSIndexPath indexPathForRow:0 inSection:0];
            [self.tableView reloadRowsAtIndexPaths:@[cacheRow]
                                  withRowAnimation:UITableViewRowAnimationNone];
        }
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 6; }

// Section 0 = Cache (vider le cache)
// Section 1 = Options (chat custom + bouton flottant)
// Section 2 = Sauvegarde (export / import de tous les réglages)
// Section 3 = Diagnostics (état des hooks Twitch)
// Section 4 = Logs (activer logs, voir les logs, logs console, puis 14 catégories)
// Section 5 = Danger (effacer les logs)
#define S7TV_SECTION_CACHE        0
#define S7TV_SECTION_OPTIONS      1
#define S7TV_SECTION_TRANSFER     2
#define S7TV_SECTION_DIAGNOSTICS  3
#define S7TV_SECTION_LOGS         4
#define S7TV_SECTION_DANGER       5

#define S7TV_LOGS_ROW_ENABLE      0
#define S7TV_LOGS_ROW_VIEW        1
#define S7TV_LOGS_ROW_CONSOLE     2
#define S7TV_LOGS_ROW_FIRST_CAT   3
#define S7TV_LOGS_CAT_COUNT       14
#define S7TV_LOGS_ROW_COUNT       (S7TV_LOGS_ROW_FIRST_CAT + S7TV_LOGS_CAT_COUNT)

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TV_SECTION_CACHE:   return 1;
        case S7TV_SECTION_OPTIONS: return 2;
        case S7TV_SECTION_TRANSFER: return 2;
        case S7TV_SECTION_DIAGNOSTICS: return 1;
        case S7TV_SECTION_LOGS:    return S7TV_LOGS_ROW_COUNT;
        case S7TV_SECTION_DANGER:  return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == S7TV_SECTION_CACHE ? 8 : 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TV_SECTION_CACHE:   return [[UIView alloc] init]; // pas de header : action isolée, comme l'ancien "Recharger" de l'accueil
        case S7TV_SECTION_OPTIONS: return S7TVSectionHeader(L(@"section_options"), NO, nil);
        case S7TV_SECTION_TRANSFER: return S7TVSectionHeader(L(@"section_settings_backup"), NO, nil);
        case S7TV_SECTION_DIAGNOSTICS: return S7TVSectionHeader(L(@"section_diagnostics"), NO, nil);
        case S7TV_SECTION_LOGS:    return S7TVSectionHeader(L(@"section_logs"), NO, nil);
        case S7TV_SECTION_DANGER:  return S7TVSectionHeader(L(@"section_danger"), NO, nil);
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

    // ── Section Cache : Vider le cache ──────────────────────────────────────
    if (ip.section == S7TV_SECTION_CACHE) {
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
        NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
        resolution = MIN(4, MAX(1, resolution));
        countLbl.text = [NSString stringWithFormat:L(@"cache_emote_count_format"),
                         (long)[SevenTVURLProtocol cachedEmoteCount], (long)resolution];
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
                    self, @selector(toggleChatCustom:), nil);
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

    if (ip.section == S7TV_SECTION_DIAGNOSTICS) {
        return S7TVNavCell(L(@"diagnostics_title"), L(@"diagnostics_subtitle"),
            @"stethoscope", UIColor.systemPinkColor, nil);
    }

    if (ip.section == S7TV_SECTION_LOGS) {
        NSInteger row = ip.row;

        // --- Activer les logs (interrupteur global) ---
        if (row == S7TV_LOGS_ROW_ENABLE) {
            return S7TVSwitchCell(L(@"switch_enable_logs"),
                        @"bolt.fill",
                        UIColor.systemYellowColor,
                        mgr.logsEnabled,
                        self, @selector(toggleLogsEnabled:), nil);
        }

        // --- Voir les logs (toujours accessible, même si logsEnabled == NO) ---
        if (row == S7TV_LOGS_ROW_VIEW) {
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

        // --- Logs console (Console.app) — grisé si logsEnabled == NO ---
        if (row == S7TV_LOGS_ROW_CONSOLE) {
            UITableViewCell *cell = S7TVSwitchCell(L(@"switch_logs_console"),
                        @"terminal.fill",
                        UIColor.systemGreenColor,
                        mgr.debugLogging,
                        self, @selector(toggleDebug:), nil);
            [self s7tv_applyEnabledState:cell];
            return cell;
        }

        // --- Catégories de logs ---
        NSInteger catIdx = row - S7TV_LOGS_ROW_FIRST_CAT;
        NSArray<NSString *> *titles = @[
            L(@"log_cat_errors"), L(@"log_cat_chat_custom"), L(@"log_cat_channel_points"),
            L(@"log_cat_tap"), L(@"log_cat_swizzle"),
            L(@"log_cat_cache"), L(@"log_cat_prefetch"), L(@"log_cat_api"), L(@"log_cat_irc"),
            L(@"log_cat_ui_picker"), L(@"section_favoris"),
            L(@"log_cat_orientation"), L(@"log_cat_cdn"),
            L(@"log_cat_dump"),
        ];
        NSArray<NSString *> *icons = @[
            @"exclamationmark.triangle.fill", @"hammer.fill", @"gift.fill",
            @"hand.tap.fill", @"bolt.horizontal.circle.fill",
            @"network", @"arrow.down.circle.fill", @"globe", @"antenna.radiowaves.left.and.right",
            @"paintbrush.fill", @"star.fill",
            @"lock.rotation", @"photo.fill",
            @"trash.fill",
        ];
        // Couleur ON de chaque catégorie (même ordre que "icons" / "values").
        NSArray<UIColor *> *colors = @[
            UIColor.systemRedColor,     UIColor.systemOrangeColor, UIColor.systemYellowColor,
            UIColor.systemGreenColor,   UIColor.systemTealColor,
            UIColor.systemBlueColor,    UIColor.systemIndigoColor, UIColor.systemPurpleColor, UIColor.systemPinkColor,
            UIColor.systemBrownColor,   UIColor.systemYellowColor,
            UIColor.systemBlueColor,    UIColor.systemTealColor,
            UIColor.systemRedColor,
        ];
        NSArray<NSNumber *> *values = @[
            @(mgr.logErrors), @(mgr.logChatCustom), @(mgr.logChannelPoints),
            @(mgr.logTap), @(mgr.logSwizzle), @(mgr.logCache),
            @(mgr.logPrefetch), @(mgr.logAPI), @(mgr.logIRCChannel),
            @(mgr.logUIPicker), @(mgr.logFavorites), @(mgr.logOrientation),
            @(mgr.logImageConversion),
            @(mgr.logDump),
        ];
        NSArray *selectors = @[
            @"toggleLogErrors:", @"toggleLogChatCustom:", @"toggleLogChannelPoints:",
            @"toggleLogTap:", @"toggleLogSwizzle:", @"toggleLogCache:",
            @"toggleLogPrefetch:", @"toggleLogAPI:", @"toggleLogIRCChannel:",
            @"toggleLogUIPicker:", @"toggleLogFavorites:", @"toggleLogOrientation:",
            @"toggleLogImageConversion:",
            @"toggleLogDump:",
        ];

        UITableViewCell *cell = S7TVSwitchCell(titles[catIdx],
                    icons[catIdx],
                    colors[catIdx],
                    values[catIdx].boolValue,
                    self, NSSelectorFromString(selectors[catIdx]), nil);
        [self s7tv_applyEnabledState:cell];
        return cell;
    }

    // Section Danger : Effacer les logs
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = S7TVIcon(@"trash.fill", [UIColor systemRedColor]);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(@"action_clear_all_logs");
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor systemRedColor];
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == S7TV_SECTION_CACHE) { [self clearCache]; return; }

    if (ip.section == S7TV_SECTION_TRANSFER) {
        if (ip.row == 0) [self s7tv_exportSettingsFromAnchor:[tv cellForRowAtIndexPath:ip]];
        else [self s7tv_importSettingsFromFile];
        return;
    }

    if (ip.section == S7TV_SECTION_DIAGNOSTICS) {
        [self.navigationController pushViewController:[S7TVHookDiagnosticsController new]
                                             animated:YES];
        return;
    }

    if (ip.section == S7TV_SECTION_LOGS && ip.row == S7TV_LOGS_ROW_VIEW) {
        [self.navigationController
            pushViewController:[[SevenTVLogsController alloc] init] animated:YES];
        return;
    }

    if (ip.section == S7TV_SECTION_DANGER && ip.row == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:L(@"alert_clear_logs_title")
                             message:L(@"alert_irreversible")
                      preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"common_clear")
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                [[SevenTVManager sharedManager] clearLogs];
                [tv reloadData];
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// Vide entièrement le cache 7TV (disque + mémoire + badges) via
// SevenTVManager, puis relance le chargement des emotes.
- (void)clearCache {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    __weak typeof(self) weakSelf = self;
    [mgr clearAllCachesWithCompletion:^(NSUInteger clearedCount) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
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

// ── Sauvegarde des réglages TwitchPlusK ─────────────────────────────────────

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

    NSUInteger importedCount = S7TVSettingsImportData(data, &error);
    if (importedCount == NSNotFound) {
        [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_import_failed_title")
                                              message:L(@"settings_import_invalid_file")];
        return;
    }

    [self s7tv_applyImportedSettings];
    [self.tableView reloadData];
    [self s7tv_showSettingsTransferAlertWithTitle:L(@"settings_import_success_title")
                                          message:[NSString stringWithFormat:
                                              L(@"settings_import_success_message_format"),
                                              (unsigned long)importedCount]];
}

- (void)s7tv_applyImportedSettings {
    // Les préférences générales vivent aussi en mémoire dans le singleton.
    // Cette méthode les relit sans repasser par les setters (qui réécrivent
    // immédiatement NSUserDefaults et risqueraient de modifier le backup).
    [[SevenTVManager sharedManager] reloadPreferencesFromDefaults];

    SevenTVChatAppearanceConfig *chatConfig = [SevenTVChatAppearanceConfig sharedConfig];
    [chatConfig reloadFromDefaults];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVChatAppearanceConfigDidChangeNotification object:chatConfig];
    S7TVOLEDModeReloadFromDefaults();

    NSInteger language = [NSUserDefaults.standardUserDefaults integerForKey:@"s7tv_language"];
    if (language != S7TVLanguageFrench) language = S7TVLanguageEnglish;
    [S7TVLocalization shared].currentLanguage = (S7TVLanguage)language;
    self.title = L(@"title_avance");

    // Les setters réinstallent/retirent l'observateur de rotation et mettent
    // à jour le bouton du lecteur déjà présent, ce qu'une simple écriture
    // dans NSUserDefaults ne ferait pas.
    s7tv_setOrientationLockButtonEnabled(s7tv_orientationLockButtonEnabled());
    s7tv_setAutoOrientationLockMode(s7tv_autoOrientationLockMode());
}

- (void)s7tv_showSettingsTransferAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
                                               style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Grise visuellement une cellule de catégorie/console quand logsEnabled == NO,
// sans jamais modifier la valeur stockée dans NSUserDefaults.
- (void)s7tv_applyEnabledState:(UITableViewCell *)cell {
    S7TVApplyCellEnabledState(cell, [SevenTVManager sharedManager].logsEnabled);
}

- (void)toggleLogsEnabled:(UISwitch *)sw {
    [SevenTVManager sharedManager].logsEnabled = sw.isOn;
    // Reload pour griser/dégriser les autres lignes de la section Logs
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:S7TV_SECTION_LOGS]
                   withRowAnimation:UITableViewRowAnimationNone];
}
- (void)toggleDebug:(UISwitch *)sw                  { [SevenTVManager sharedManager].debugLogging        = sw.isOn; }
- (void)toggleChatCustom:(UISwitch *)sw             { [SevenTVManager sharedManager].chatCustomTestEnabled = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw         { [SevenTVManager sharedManager].showFloatingButton  = sw.isOn; }

- (void)toggleLogErrors:(UISwitch *)sw           { [SevenTVManager sharedManager].logErrors           = sw.isOn; }
- (void)toggleLogTap:(UISwitch *)sw              { [SevenTVManager sharedManager].logTap              = sw.isOn; }
- (void)toggleLogSwizzle:(UISwitch *)sw          { [SevenTVManager sharedManager].logSwizzle          = sw.isOn; }
- (void)toggleLogCache:(UISwitch *)sw            { [SevenTVManager sharedManager].logCache            = sw.isOn; }
- (void)toggleLogPrefetch:(UISwitch *)sw         { [SevenTVManager sharedManager].logPrefetch         = sw.isOn; }
- (void)toggleLogAPI:(UISwitch *)sw              { [SevenTVManager sharedManager].logAPI              = sw.isOn; }
- (void)toggleLogIRCChannel:(UISwitch *)sw       { [SevenTVManager sharedManager].logIRCChannel       = sw.isOn; }
- (void)toggleLogUIPicker:(UISwitch *)sw         { [SevenTVManager sharedManager].logUIPicker         = sw.isOn; }
- (void)toggleLogFavorites:(UISwitch *)sw        { [SevenTVManager sharedManager].logFavorites        = sw.isOn; }
- (void)toggleLogOrientation:(UISwitch *)sw      { [SevenTVManager sharedManager].logOrientation      = sw.isOn; }
- (void)toggleLogImageConversion:(UISwitch *)sw  { [SevenTVManager sharedManager].logImageConversion  = sw.isOn; }
- (void)toggleLogChatCustom:(UISwitch *)sw       { [SevenTVManager sharedManager].logChatCustom       = sw.isOn; }
- (void)toggleLogChannelPoints:(UISwitch *)sw    { [SevenTVManager sharedManager].logChannelPoints    = sw.isOn; }
- (void)toggleLogDump:(UISwitch *)sw             { [SevenTVManager sharedManager].logDump             = sw.isOn; }

@end
