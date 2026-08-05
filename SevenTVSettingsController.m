/*
 * SevenTVSettingsController.m
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

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVChatAppearanceConfig.h"
#import "7tv-localization.h"
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Palette couleurs
// ─────────────────────────────────────────────────────────────────────────────

// Fond général de la tableView (noir profond Twitch)
static UIColor *S7TVBg(void) {
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}

// Fond des cellules (gris foncé Twitch)
static UIColor *S7TVCellBg(void) {
    return [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23
}

// Violet 7TV / Twitch
static UIColor *S7TVAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // #8E45E0
}

// Gris secondaire (sous-titres, icônes)
static UIColor *S7TVGray(void) {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
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
static UITableViewCell *S7TVNavCell(NSString *title,
                                     NSString *subtitle,
                                     NSString *sfName,
                                     UIColor  *iconTint) {
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
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            // Assure que le stack ne déborde pas verticalement
            [stack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
            [stack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
    } else {
        [cell.contentView addSubview:titleLbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [titleLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [titleLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            // CRITIQUE : top+bottom pour que le label ait une hauteur résolue
            [titleLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [titleLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
    }
    return cell;
}

// Cellule avec UISwitch
// Titre 17pt Regular (identique Twitch natif), switch violet 7TV
static UITableViewCell *S7TVSwitchCell(NSString *title,
                                        NSString *sfName,
                                        UIColor  *iconTint,
                                        BOOL      isOn,
                                        id        target,
                                        SEL       action) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();

    UIImageView *icon = S7TVIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    // 17pt Regular = taille standard iOS Settings / Twitch natif
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on          = isOn;
    sw.onTintColor = S7TVAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:sw];

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
        [lbl.trailingAnchor  constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-12],
        [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:13],
        [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-13],
    ]];
    return cell;
}

// Header de section style Twitch : logo (optionnel) + texte gris uppercase
// Identique visuellement au header "7TV SETTINGS" de la capture
static UIView *S7TVSectionHeader(NSString *title, BOOL withLogo) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title.uppercaseString;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

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
                [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
            ]];
            return container;
        }
    }

    // Header texte seul (sans logo)
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];
    return container;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Méthode utilitaire commune pour styleTableView
// ─────────────────────────────────────────────────────────────────────────────

static void S7TVStyleTableView(UITableView *tv) {
    tv.backgroundColor   = S7TVBg();
    tv.separatorColor    = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0];
    tv.separatorInset    = UIEdgeInsetsMake(0, 52, 0, 0);
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


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVSettingsController  (Hub principal)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVHomeSection) {
    S7TVHomeSectionMain     = 0,  // 4 catégories : Apparence / Contenu / Adblock / Avancé
    S7TVHomeSectionLanguage = 1,
};

@implementation SevenTVSettingsController

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
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)s7tv_languageDidChange {
    [self buildNavBar];
    [self.tableView reloadData];
}

- (void)buildNavBar {
    // Titre nav bar : logo 7TV + "7TV"
    NSData *d = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = d ? [UIImage imageWithData:d scale:2.0] : nil;

    if (logo) {
        UIView *tv = [[UIView alloc] init];
        UIImageView *iv = [[UIImageView alloc] initWithImage:logo];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = L(@"label_7tv_badge");
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
        CGFloat w = 28 + 6 + [@"7TV" sizeWithAttributes:@{
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
        case S7TVHomeSectionMain:     return S7TVSectionHeader(L(@"title_7tv_settings"), YES);
        case S7TVHomeSectionLanguage: return S7TVSectionHeader(L(@"section_langue"), NO);
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
        UIColor *iconTint = [UIColor colorWithWhite:0.75 alpha:1.0];
        switch (ip.row) {
            case 0: sfName=@"paintbrush.fill";            title=L(@"title_apparence"); subtitle=L(@"menu_apparence_subtitle"); iconTint=S7TVAccent(); break;
            case 1: sfName=@"folder.fill";                 title=L(@"title_contenu");   subtitle=L(@"menu_contenu_subtitle"); break;
            case 2: sfName=@"shield.slash.fill";           title=L(@"title_adblock");   subtitle=L(@"menu_adblock_subtitle"); break;
            case 3: sfName=@"wrench.and.screwdriver.fill"; title=L(@"title_avance");    subtitle=L(@"menu_avance_subtitle"); break;
            default: return [[UITableViewCell alloc] init];
        }
        return S7TVNavCell(title, subtitle, sfName, iconTint);
    }

    // Section Langue — segmented control FR/EN, pas un simple switch : il y a
    // deux valeurs possibles (pas juste ON/OFF), un segmented rend l'état
    // actuel immédiatement lisible sans avoir à lire un libellé à côté.
    if (ip.section == S7TVHomeSectionLanguage) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();

        UIImageView *icon = S7TVIcon(@"globe", [UIColor colorWithWhite:0.75 alpha:1.0]);
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
// Catégorie réservée pour les futures options d'adblock — volontairement
// vide pour l'instant, juste l'entrée de navigation depuis l'accueil.
// ─────────────────────────────────────────────────────────────────────────────

@implementation SevenTVAdblockPageController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_adblock");
    self.view.backgroundColor = S7TVBg();

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(@"adblock_coming_soon");
    lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray();
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [lbl.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [lbl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
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
}

// Section 0 : Chat custom (promu depuis Débogage — ce n'est plus un test,
// c'est le mode de rendu du chat)
// Section 1 : Animations (picker + sous-option favoris uniquement)
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : 2;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return S7TVSectionHeader(s == 0 ? L(@"section_general") : L(@"section_affichage"), NO);
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
    if (ip.section == 0) {
        return S7TVSwitchCell(L(@"switch_chat_custom"),
                              @"message.badge.filled.fill",
                              S7TVAccent(),
                              mgr.chatCustomTestEnabled,
                              self, @selector(toggleChatCustom:));
    }
    switch (ip.row) {
        case 0: return S7TVSwitchCell(L(@"switch_animations_picker"),
                    @"photo.stack",
                    [UIColor colorWithWhite:0.75 alpha:1.0],
                    mgr.showPickerAnimations,
                    self, @selector(togglePickerAnimations:));
        case 1: {
            UITableViewCell *cell = S7TVSwitchCell(L(@"switch_animations_favorites_only"),
                        @"star.circle",
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.showPickerAnimationsFavoritesOnly,
                        self, @selector(togglePickerAnimationsFavoritesOnly:));
            [self s7tv_applyPickerAnimSubOptionEnabledState:cell];
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

// Kill switch Phase 0 (plan chat custom) — voir SevenTVManager.h. Réutilise
// la propriété chatCustomTestEnabled existante ; seul le libellé/l'écran
// changent dans cette passe (câblage plus profond laissé pour plus tard).
- (void)toggleChatCustom:(UISwitch *)sw { [SevenTVManager sharedManager].chatCustomTestEnabled = sw.isOn; }

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

// Grise visuellement la sous-option quand "Animations dans le picker" est
// désactivé, sans jamais modifier sa valeur stockée en NSUserDefaults —
// même pattern que s7tv_applyEnabledState: dans SevenTVDebugPageController,
// mais dépendant ici de showPickerAnimations plutôt que de logsEnabled.
- (void)s7tv_applyPickerAnimSubOptionEnabledState:(UITableViewCell *)cell {
    BOOL enabled = [SevenTVManager sharedManager].showPickerAnimations;
    cell.userInteractionEnabled = enabled;
    cell.contentView.alpha = enabled ? 1.0 : 0.4;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UISwitch class]]) {
            ((UISwitch *)v).enabled = enabled;
            break;
        }
    }
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
};

@interface SevenTVContentPageController () <UIDocumentPickerDelegate>
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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Rafraîchit le compteur de favoris à chaque retour sur cet écran.
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVContentSectionFavorites: return 2;
        case S7TVContentSectionStream:    return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == S7TVContentSectionFavorites ? 52 : 60;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVContentSectionFavorites: return S7TVSectionHeader(L(@"section_favoris"), NO);
        case S7TVContentSectionStream:    return S7TVSectionHeader(L(@"section_stream"), NO);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return s == S7TVContentSectionStream ? UITableViewAutomaticDimension : 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    if (s != S7TVContentSectionStream) {
        UIView *v = [[UIView alloc] init];
        v.backgroundColor = [UIColor clearColor];
        return v;
    }
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = L(@"desc_auto_collect");
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

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // ── Section Stream : Auto Collect Channel Points ──────────────────────
    if (ip.section == S7TVContentSectionStream) {
        return S7TVSwitchCell(L(@"switch_auto_collect_title"),
                    @"giftcard.fill", [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0],
                    S7TVBoolDefaultYes(kTCLiveAutoCollectChannelPoints), self, @selector(toggleAutoCollect:));
    }

    // ── Section Favoris ─────────────────────────────────────────────────────
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSArray *favs = [prefs arrayForKey:@"s7tv_favorites"] ?: @[];

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

        UIImageView *icon = S7TVIcon(@"star.fill",
            [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]);
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
    }
}

- (void)toggleAutoCollect:(UISwitch *)sw { S7TVSetBool(kTCLiveAutoCollectChannelPoints, sw.isOn); }

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

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *existing = [prefs arrayForKey:@"s7tv_favorites"] ?: @[];
    NSMutableOrderedSet<NSString *> *merged =
        [NSMutableOrderedSet orderedSetWithArray:existing];
    NSUInteger beforeCount = merged.count;
    [merged addObjectsFromArray:newIDs];
    [prefs setObject:merged.array forKey:@"s7tv_favorites"];
    [prefs synchronize];

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

@implementation SevenTVFavoritesListController {
    NSArray<NSString *> *_favIDs;      // IDs purs (sans préfixe)
    NSDictionary<NSString *, NSString *> *_idToName; // emoteID → emoteName
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_mes_favoris");
    S7TVStyleTableView(self.tableView);
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFavs];
}

- (void)reloadFavs {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    _favIDs = [[prefs arrayForKey:@"s7tv_favorites"] ?: @[] copy];

    // Construire le dictionnaire id → nom à partir des emotes chargées
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
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

    [self.tableView reloadData];
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
        ? [NSString stringWithFormat:@"%lu emote(s) en favoris", (unsigned long)_favIDs.count]
        : @"Favoris";
    return S7TVSectionHeader(title, NO);
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

    // Essayer de trouver l'image en cache
    NSString *urlStr = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/1x.webp", emoteID];
    NSURL *cdnURL = [NSURL URLWithString:urlStr];
    NSURLRequest *req = [NSURLRequest requestWithURL:cdnURL];
    NSCachedURLResponse *cached = [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
    if (cached) {
        UIImage *img = [UIImage imageWithData:cached.data];
        thumb.image = img;
    } else {
        // Placeholder étoile violette
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        thumb.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        thumb.tintColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];

        // Télécharge en arrière-plan et met à jour si la cellule est encore visible
        NSIndexPath *indexPath = ip;
        [SevenTVURLProtocol prefetchEmoteID:emoteID completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *visible = [tv cellForRowAtIndexPath:indexPath];
                if (!visible) return;
                UIImageView *iv = (UIImageView *)[visible.contentView viewWithTag:7700];
                NSCachedURLResponse *r = [[SevenTVURLProtocol sharedEmoteCache]
                    cachedResponseForRequest:req];
                if (r) iv.image = [UIImage imageWithData:r.data];
            });
        }];
    }
    thumb.tag = 7700;

    // Labels
    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name ?: @"(emote non chargée)";
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
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSMutableArray *cur = [([prefs arrayForKey:@"s7tv_favorites"] ?: @[]) mutableCopy];
    [cur removeObject:removedID];
    [prefs setObject:cur forKey:@"s7tv_favorites"];
    [prefs synchronize];
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
    alert.message = [NSString stringWithFormat:@"Supprimer les %lu emotes en favoris ?",
                     (unsigned long)_favIDs.count];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_empty_action")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
            [prefs removeObjectForKey:@"s7tv_favorites"];
            [prefs synchronize];
            [self reloadFavs];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end



// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVAdvancedPageController  (ex-SevenTVDebugPageController)
// Diagnostic — reste un vrai menu utilisateur (projet open source, les logs
// servent aussi à d'autres personnes pour remonter des bugs), pas un mode
// caché type "tap x5". "Test chat custom" est parti dans Apparence. "Vider
// le cache" (ex-"Recharger les emotes" de l'accueil) atterrit ici en premier.
// ─────────────────────────────────────────────────────────────────────────────

@implementation SevenTVAdvancedPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"title_avance");
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

// Section 0 = Cache (vider le cache)
// Section 1 = Options (bouton flottant)
// Section 2 = Logs (activer logs, voir les logs, logs console, puis 13 catégories)
// Section 3 = Danger (effacer les logs)
#define S7TV_SECTION_CACHE        0
#define S7TV_SECTION_OPTIONS      1
#define S7TV_SECTION_LOGS         2
#define S7TV_SECTION_DANGER       3

#define S7TV_LOGS_ROW_ENABLE      0
#define S7TV_LOGS_ROW_VIEW        1
#define S7TV_LOGS_ROW_CONSOLE     2
#define S7TV_LOGS_ROW_FIRST_CAT   3
#define S7TV_LOGS_CAT_COUNT       13
#define S7TV_LOGS_ROW_COUNT       (S7TV_LOGS_ROW_FIRST_CAT + S7TV_LOGS_CAT_COUNT)

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TV_SECTION_CACHE:   return 1;
        case S7TV_SECTION_OPTIONS: return 1;
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
        case S7TV_SECTION_OPTIONS: return S7TVSectionHeader(L(@"section_options"), NO);
        case S7TV_SECTION_LOGS:    return S7TVSectionHeader(L(@"section_logs"), NO);
        case S7TV_SECTION_DANGER:  return S7TVSectionHeader(L(@"section_danger"), NO);
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
                                      [UIColor colorWithWhite:0.75 alpha:1.0]);
        [cell.contentView addSubview:icon];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = L(@"action_clear_cache");
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 1;
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [lbl.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        return cell;
    }

    if (ip.section == S7TV_SECTION_OPTIONS) {
        // Bouton flottant uniquement — "Test chat custom" a déménagé dans Apparence.
        return S7TVSwitchCell(L(@"switch_floating_button"),
                    @"circle.grid.2x1.fill",
                    [UIColor colorWithWhite:0.75 alpha:1.0],
                    mgr.showFloatingButton,
                    self, @selector(toggleFloatingButton:));
    }

    if (ip.section == S7TV_SECTION_LOGS) {
        NSInteger row = ip.row;

        // --- Activer les logs (interrupteur global) ---
        if (row == S7TV_LOGS_ROW_ENABLE) {
            return S7TVSwitchCell(L(@"switch_enable_logs"),
                        @"bolt.fill",
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.logsEnabled,
                        self, @selector(toggleLogsEnabled:));
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
                                          [UIColor colorWithWhite:0.75 alpha:1.0]);
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
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.debugLogging,
                        self, @selector(toggleDebug:));
            [self s7tv_applyEnabledState:cell];
            return cell;
        }

        // --- Catégories de logs ---
        NSInteger catIdx = row - S7TV_LOGS_ROW_FIRST_CAT;
        NSArray<NSString *> *titles = @[
            L(@"log_cat_errors"), L(@"log_cat_tap"), L(@"log_cat_swizzle"),
            L(@"log_cat_cache"), L(@"log_cat_prefetch"), L(@"log_cat_api"), L(@"log_cat_irc"),
            L(@"log_cat_ui_picker"), L(@"section_favoris"),
            L(@"log_cat_orientation"), L(@"log_cat_cdn"), L(@"log_cat_chat_custom"), L(@"log_cat_dump"),
        ];
        NSArray<NSString *> *icons = @[
            @"exclamationmark.triangle.fill", @"hand.tap.fill", @"bolt.horizontal.circle.fill",
            @"network", @"arrow.down.circle.fill", @"globe", @"antenna.radiowaves.left.and.right",
            @"paintbrush.fill", @"star.fill",
            @"lock.rotation", @"photo.fill", @"hammer.fill", @"trash.fill",
        ];
        NSArray<NSNumber *> *values = @[
            @(mgr.logErrors), @(mgr.logTap), @(mgr.logSwizzle), @(mgr.logCache),
            @(mgr.logPrefetch), @(mgr.logAPI), @(mgr.logIRCChannel),
            @(mgr.logUIPicker), @(mgr.logFavorites), @(mgr.logOrientation),
            @(mgr.logImageConversion), @(mgr.logChatCustom), @(mgr.logDump),
        ];
        NSArray *selectors = @[
            @"toggleLogErrors:", @"toggleLogTap:", @"toggleLogSwizzle:", @"toggleLogCache:",
            @"toggleLogPrefetch:", @"toggleLogAPI:", @"toggleLogIRCChannel:",
            @"toggleLogUIPicker:", @"toggleLogFavorites:", @"toggleLogOrientation:",
            @"toggleLogImageConversion:", @"toggleLogChatCustom:", @"toggleLogDump:",
        ];

        UITableViewCell *cell = S7TVSwitchCell(titles[catIdx],
                    icons[catIdx],
                    [UIColor colorWithWhite:0.75 alpha:1.0],
                    values[catIdx].boolValue,
                    self, NSSelectorFromString(selectors[catIdx]));
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
    [mgr clearAllCaches];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_cache_cleared_title")
                         message:L(@"alert_cache_cleared_message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"common_ok")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Grise visuellement une cellule de catégorie/console quand logsEnabled == NO,
// sans jamais modifier la valeur stockée dans NSUserDefaults.
- (void)s7tv_applyEnabledState:(UITableViewCell *)cell {
    BOOL enabled = [SevenTVManager sharedManager].logsEnabled;
    cell.userInteractionEnabled = enabled;
    cell.contentView.alpha = enabled ? 1.0 : 0.4;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UISwitch class]]) {
            ((UISwitch *)v).enabled = enabled;
            break;
        }
    }
}

- (void)toggleLogsEnabled:(UISwitch *)sw {
    [SevenTVManager sharedManager].logsEnabled = sw.isOn;
    // Reload pour griser/dégriser les autres lignes de la section Logs
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:S7TV_SECTION_LOGS]
                   withRowAnimation:UITableViewRowAnimationNone];
}
- (void)toggleDebug:(UISwitch *)sw                  { [SevenTVManager sharedManager].debugLogging        = sw.isOn; }
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
- (void)toggleLogDump:(UISwitch *)sw             { [SevenTVManager sharedManager].logDump             = sw.isOn; }

@end
