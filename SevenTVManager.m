/*
 * SevenTVManager.m
 * Implémentation du gestionnaire 7TV.
 *
 * CORRECTIFS v1.8 — Keyboard-replacement mode:
 *   Fix M — inputView = picker : le picker remplace le clavier (s'affiche en dessous).
 *   Fix N — _hideEmotePicker : inputView=nil restaure le clavier natif.
 *
 * CORRECTIFS v1.4:
 *   Fix C — Injection IRC multi-lignes.
 *   Fix D — Logs de diagnostic étendus.
 *
 * NOUVEAUTÉS v1.5 — Cache & Préchargement:
 *   Fix E — Cache fichier JSON.
 *   Fix F — Stratégie cache-first + refresh arrière-plan.
 *   Fix G — Protection anti-doublons (fetchingChannelIDs).
 *
 * CORRECTIFS v1.6 — Format IRC + Positions:
 *   Fix H — Trimming messageText (\r\n only).
 *   Fix I — Format tag emotes= conforme Twitch IRC.
 *   Fix J — Séparateur "/" entre IDs différents.
 *   Fix K — Écriture cache: retry si dossier purgé par iOS.
 *
 * NOUVEAUTÉS v1.7 — Prefetch massif au JOIN:
 *   Fix L — Au JOIN, toutes les images d'emotes sont téléchargées en
 *            arrière-plan (20 downloads simultanés, HIGH priority).
 *            Guard de déduplication (_activePrefetchKeys) : le même set
 *            ne peut être prefetché qu'une seule fois à la fois, même si
 *            loadEmotesForChannelTwitchID: est appelé plusieurs fois de
 *            suite (ROOMSTATE + GQL + timeout 5s).
 *            Résultat : zéro doublon, zéro contention réseau.
 */

#import "SevenTVManager.h"
#import "SevenTVChatMessage.h"
#import "SevenTVSettingsController.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVBadgeProvider.h"
#import "SevenTVChatAppearanceConfig.h"
#import "SevenTVEmoteImageCache.h"
#import "SevenTVEmoteAnimationEngine.h"
#import <objc/runtime.h>

// ============================================================
// Constante de notification
// ============================================================
NSString *const S7TVLogsDidUpdateNotification = @"S7TVLogsDidUpdateNotification";
NSString *const S7TVEmoteCatalogDidUpdateNotification = @"S7TVEmoteCatalogDidUpdateNotification";
NSString *const S7TVChatCustomToggleDidChangeNotification = @"S7TVChatCustomToggleDidChangeNotification";

// ============================================================
// TTL du cache en secondes
//   Globales : 1h  (elles changent très rarement)
//   Channel  : 30 min (le streamer peut ajouter/retirer des emotes)
// ============================================================
static const NSTimeInterval kCacheTTLGlobal  = 3600.0;   // 1 heure
static const NSTimeInterval kCacheTTLChannel = 1800.0;   // 30 minutes


// ============================================================
// Implémentation de SevenTVEmote
// ============================================================
@implementation SevenTVEmote
@end


// ============================================================
// SevenTVManager (privé)
// ============================================================
@interface SevenTVManager () <UITextFieldDelegate>

// IDs de channels dont un fetch réseau est EN COURS (anti-doublon concurrent)
// Ne bloque PAS les futurs refreshs — seulement les requêtes simultanées.
@property (nonatomic, strong) NSMutableSet<NSString *> *fetchingChannelIDs;

// File de dispatch pour la thread-safety des données d'emotes
@property (nonatomic, strong, readwrite) dispatch_queue_t emoteQueue;
@property (nonatomic, strong, readwrite) S7TVChatMessageStore *chatMessageStore;

// File série pour les I/O fichier (lecture/écriture cache JSON)
// Série = pas de concurrent file access, pas besoin de lock séparé.
@property (nonatomic, strong) dispatch_queue_t fileIOQueue;

// Bouton flottant des paramètres
@property (nonatomic, weak)   UIButton *settingsButton;
// Fenêtre dédiée au bouton flottant (strong = reste en vie toute la session)
@property (nonatomic, strong) UIWindow *floatingWindow;
// Fenêtre dédiée au menu settings (créée au tap, détruite à la fermeture)
@property (nonatomic, strong) UIWindow *menuWindow;

// Picker d'emotes inline (affiché au-dessus de la barre de saisie)
@property (nonatomic, strong) UIView              *emotePickerView;
// FORT (pas weak) — doit rester valide jusqu'au tap sur l'emote.
// Un weak pointer devient nil dès que Twitch recycle la vue → insertion silencieuse.
@property (nonatomic, weak)   UIView              *emotePickerTextField;
// Référence forte au _TtC6Twitch...TextEntryView — reste firstResponder pendant le picker.
@property (nonatomic, weak)   UITextView          *emotePickerTextEntryView;
@property (nonatomic, strong) UICollectionView    *emoteCollectionView;
@property (nonatomic, strong) UITextField         *emoteSearchField;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerAllEmotes;

// Favoris : IDs 7TV des emotes mise en favoris (persisté dans NSUserDefaults)
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteEmoteIDs;
// Arrays filtrés pour l'affichage dans le picker (3 sections)
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerChannelEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerGlobalEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerOtherEmotes; // compatibilité

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Token OAuth Twitch + Client-ID — interceptés depuis les requêtes GQL
// (voir TweakSevenTV.m s7tv_dataTaskWithRequest:) pour pouvoir appeler
// l'API Helix (badges, etc.) sans enregistrer une app développeur.
@property (nonatomic, copy) NSString *twitchToken;
@property (nonatomic, copy) NSString *twitchClientID;
// Valeurs partielles en attendant d'avoir les deux (voir capture méthodes ci-dessous)
@property (nonatomic, copy) NSString *pendingAuthHeader;
@property (nonatomic, copy) NSString *pendingClientIDHeader;

// Dossier racine du cache JSON (créé à la demande)
@property (nonatomic, strong) NSString *cacheDirectory;

// Timer heartbeat CDN — envoie un HEAD toutes les 20s pour garder
// la connexion TCP/TLS keep-alive ouverte vers cdn.7tv.app.
@property (nonatomic, strong) NSTimer *cdnHeartbeatTimer;

// Guard de déduplication pour _prefetchAllEmotes:setKey:label: (Fix L v1.7)
// Clé = twitchUserID pour les channels, "global" pour les globales.
// Protégé par @synchronized(self).
@property (nonatomic, strong) NSMutableSet<NSString *> *activePrefetchKeys;

// Panneau des 5 tailles — remplace la grille d'emotes (pas un menu/action-sheet)
// quand on tape sur ⚙️. Toutes les lignes sont empilées et réglables en même
// temps, chacune avec son slider + une preview live à droite.
@property (nonatomic, weak) UIView   *pickerHeaderView;
@property (nonatomic, weak) UIView   *pickerHeaderNormalContent; // logo+titre+search
@property (nonatomic, weak) UILabel  *pickerHeaderTitleLabel;    // "Emotes" ↔ "Tailles"
@property (nonatomic, weak) UIButton *pickerSizesToggleBtn;      // bouton ⚙️ (change de couleur selon l'état)
@property (nonatomic, weak) UIView   *pickerSizesPanelView;      // scrollview des 5 lignes
@property (nonatomic, assign) BOOL   pickerSizesPanelVisible;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISlider *> *pickerSizeSliders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *>  *pickerSizeValueLabels;   // label "Nom — XX pt"
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *>   *pickerSizePreviewViews;  // contenu de chaque preview


@end


// ============================================================
// MARK: - S7TVPresentationController
//
// UIPresentationController custom : positionne le menu 7TV dans
// le coin inférieur droit, taille fixe 360×520pt.
// Fonctionne en portrait ET paysage, sur iOS 13+, dans n'importe
// quelle app hôte — indépendant du rootViewController de Twitch.
//
// Pourquoi pas UISheetPresentationController / FormSheet :
//   - Sur iPhone, iOS ignore preferredContentSize pour FormSheet.
//   - sheetPresentationController.detents custom (iOS 16+) donne
//     50% en paysage sur certains appareils car la hauteur de
//     résolution est celle de l'écran physique, pas du contenu.
//   - UIPresentationController est la seule API qui donne un
//     contrôle total sur la frame finale du modal.
// ============================================================

static const CGFloat kS7TVMenuWidth  = 360.0;
static const CGFloat kS7TVMenuHeight = 520.0;

@interface S7TVPresentationController : UIPresentationController
@property (nonatomic, strong) UIView *dimmingView;
@end

@implementation S7TVPresentationController

- (void)presentationTransitionWillBegin {
    // Fond semi-transparent derrière le menu
    UIView *dim = [[UIView alloc] initWithFrame:self.containerView.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    dim.alpha = 0;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.containerView insertSubview:dim atIndex:0];
    self.dimmingView = dim;

    // Tap sur le fond → dismiss
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dimmingTapped)];
    [dim addGestureRecognizer:tap];

    id<UIViewControllerTransitionCoordinator> coord = self.presentingViewController.transitionCoordinator;
    if (coord) {
        [coord animateAlongsideTransition:^(id ctx) { dim.alpha = 1; } completion:nil];
    } else {
        dim.alpha = 1;
    }
}

- (void)dismissalTransitionWillBegin {
    id<UIViewControllerTransitionCoordinator> coord = self.presentingViewController.transitionCoordinator;
    if (coord) {
        [coord animateAlongsideTransition:^(id ctx) { self.dimmingView.alpha = 0; } completion:nil];
    } else {
        self.dimmingView.alpha = 0;
    }
}

- (void)dimmingTapped {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"S7TVMenuDidDismiss" object:nil];
    }];
}

// Frame du menu : plein écran avec marges de sécurité (safe area).
- (CGRect)frameOfPresentedViewInContainerView {
    CGRect container = self.containerView.bounds;
    // Inset de 16pt de chaque côté pour un aspect "carte" sur iPad,
    // et plein écran sur iPhone (containerView = plein écran de menuWindow).
    CGFloat hInset = (container.size.width > 500) ? 16.0 : 0.0;
    CGFloat vInset = (container.size.height > 700) ? 16.0 : 0.0;
    return CGRectInset(container, hInset, vInset);
}

- (void)containerViewWillLayoutSubviews {
    [super containerViewWillLayoutSubviews];
    self.dimmingView.frame     = self.containerView.bounds;
    self.presentedView.frame   = [self frameOfPresentedViewInContainerView];
    // Coins arrondis sur le menu
    self.presentedView.layer.cornerRadius  = 16;
    self.presentedView.layer.masksToBounds = YES;
}

@end


// ============================================================
// MARK: - S7TVSettingsNavController
//
// UINavigationController qui fournit son propre transitioningDelegate
// → utilise S7TVPresentationController pour un placement et une
//   taille totalement contrôlés (360×520pt, centré).
// ============================================================
@interface S7TVSettingsNavController : UINavigationController <UIViewControllerTransitioningDelegate>
@end

@implementation S7TVSettingsNavController

- (instancetype)initWithRootViewController:(UIViewController *)root {
    self = [super initWithRootViewController:root];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationCustom;
        self.transitioningDelegate  = self;
    }
    return self;
}

- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                      presentingViewController:(UIViewController *)presenting
                                                          sourceViewController:(UIViewController *)source {
    return [[S7TVPresentationController alloc]
        initWithPresentedViewController:presented presentingViewController:presenting];
}

@end


// ============================================================
// MARK: - SevenTVFloatingWindow
//
// UIWindow dont le hitTest ne capte les touches QUE si une
// vraie sous-vue (le bouton 7TV) est touchée.
// Si le fond transparent est touché → retourne nil → iOS
// transmet le touch à la fenêtre Twitch en dessous.
// ============================================================
@interface SevenTVFloatingWindow : UIWindow
@end

@implementation SevenTVFloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // On ne capture la touche QUE si elle tombe sur le bouton ou l'un
    // de ses sous-vues (label, etc.). Le fond transparent (self) et
    // la rootVC.view passent toujours à Twitch → nil = ignore.
    if (hit == nil || hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end


// ============================================================
// MARK: - S7TVPickerResolvedEmote
//
// Adaptateur léger : fait correspondre une SevenTVEmote (modèle du picker)
// au protocole S7TVResolvedEmote attendu par SevenTVEmoteImageCache /
// SevenTVEmoteAnimationEngine (Phase 2, chat custom). Permet au picker de
// PARTAGER ces deux caches avec le chat custom au lieu de dupliquer son
// propre pipeline de décodage (une emote vue dans le chat est déjà décodée
// pour le picker, et inversement). Ne modifie pas SevenTVEmote elle-même
// (modèle utilisé ailleurs dans le code) : reste un wrapper local au picker.
// ============================================================
@interface S7TVPickerResolvedEmote : NSObject <S7TVResolvedEmote>
- (instancetype)initWithEmote:(SevenTVEmote *)emote;
@end

@implementation S7TVPickerResolvedEmote {
    SevenTVEmote *_sourceEmote;
    NSURL        *_cachedImageURL;
}

- (instancetype)initWithEmote:(SevenTVEmote *)emote {
    self = [super init];
    if (self) _sourceEmote = emote;
    return self;
}

- (NSString *)emoteID {
    return _sourceEmote.emoteID;
}

- (CGSize)nativeSize {
    return CGSizeMake(_sourceEmote.width, _sourceEmote.height);
}

- (NSURL *)imageURL {
    if (!_cachedImageURL) {
        _cachedImageURL = [[SevenTVManager sharedManager] cdnURLForEmote:_sourceEmote];
    }
    return _cachedImageURL;
}

- (BOOL)isAnimated {
    return _sourceEmote.isAnimated;
}

@end


// ============================================================
// MARK: - S7TVEmotePickerCell
//
// Cellule dédiée du picker — remplace le UICollectionViewCell générique
// utilisé jusqu'ici. L'UIImageView et l'étoile favoris sont créés UNE SEULE
// FOIS ici (dans -initWithFrame:), jamais recréés à chaque dequeue : sur
// l'ancienne version, cellForItemAtIndexPath: retirait puis reconstruisait
// tous les subviews à chaque réapparition de cellule pendant le scroll,
// ajoutant de l'alloc/dealloc pour rien. Ici, prepareForReuse: se contente
// de vider l'image et de se désinscrire de l'engine d'animation.
// ============================================================
@interface S7TVEmotePickerCell : UICollectionViewCell
@property (nonatomic, strong, readonly) UIImageView *emoteImageView;
@property (nonatomic, strong, readonly) UIImageView *favoriteStarView;
// Clé (URL absolue) de l'emote actuellement affichée par cette cellule.
// Sert à valider qu'un callback asynchrone arrivant après un recyclage
// concerne toujours la bonne emote avant d'appliquer une image/frame.
@property (nonatomic, copy) NSString *currentEmoteKey;
@end

@implementation S7TVEmotePickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _emoteImageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _emoteImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _emoteImageView.contentMode = UIViewContentModeScaleAspectFit;
        _emoteImageView.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_emoteImageView];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:6 weight:UIImageSymbolWeightMedium];
        _favoriteStarView = [[UIImageView alloc] init];
        _favoriteStarView.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        _favoriteStarView.tintColor = [[UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]
                                        colorWithAlphaComponent:0.7];
        _favoriteStarView.hidden = YES;
        [self.contentView addSubview:_favoriteStarView];

        self.clipsToBounds = YES;
        CGFloat onePixel = 1.0 / [UIScreen mainScreen].scale;
        self.layer.borderWidth = onePixel;
        self.layer.borderColor = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0].CGColor; // #2A2A2E
        self.backgroundColor = [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize cs = self.bounds.size;
    self.favoriteStarView.frame = CGRectMake(cs.width - 9, 1, 8, 8);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.emoteImageView.image = nil;
    self.favoriteStarView.hidden = YES;
    self.currentEmoteKey = nil;
    // Se retire de l'engine d'animation : sans ça, une cellule recyclée pour
    // une AUTRE emote continuerait de recevoir les redraws de l'ancienne
    // (l'engine ne sait pas qu'elle a changé de contenu tant qu'on ne le lui
    // dit pas explicitement).
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:self];
}

@end


// ============================================================
@implementation SevenTVManager

// ============================================================
// MARK: - Singleton
// ============================================================

+ (instancetype)sharedManager {
    static SevenTVManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isEnabled             = YES;
        _showAnimated          = YES;
        _showPickerAnimations  = NO;   // Désactivé par défaut (perf)
        _showPickerAnimationsFavoritesOnly = NO;
        _debugLogging          = (S7TV_DEBUG == 1);

        // Système de logs par catégorie — valeurs par défaut avant chargement
        // des préférences sauvegardées (voir loadPreferences ci-dessous).
        _logsEnabled       = YES;
        _logErrors         = YES;   // Erreurs/Avertissements visibles par défaut
        _logTap            = NO;
        _logSwizzle        = NO;
        _logCache          = NO;
        _logPrefetch       = NO;
        _logAPI            = NO;
        _logIRCChannel     = NO;
        _logUIPicker       = NO;
        _logFavorites      = NO;
        _logOrientation    = NO;
        _logImageConversion = NO;
        _logChatCustom     = YES;   // ON par défaut pendant le dev du chat custom (Phase 0+)
        _logDump           = NO;

        _globalEmotes      = @{};
        _channelEmotes     = @{};
        _fetchingChannelIDs  = [NSMutableSet set];
        _activePrefetchKeys  = [NSMutableSet set];

        _emoteQueue  = dispatch_queue_create("tv.s7tv.emote-queue",  DISPATCH_QUEUE_CONCURRENT);
        _chatMessageStore = [[S7TVChatMessageStore alloc] init];
        _fileIOQueue = dispatch_queue_create("tv.s7tv.file-io-queue", DISPATCH_QUEUE_SERIAL);

        // Cache image RAM : 40 MB max — environ 1000 emotes statiques 40×40pt décompressées.
        // NSCache évicte automatiquement sous pression mémoire → jamais de crash OOM.


        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        _favoriteEmoteIDs        = [NSMutableSet set];
        _emotePickerFavoriteEmotes = @[];
        _emotePickerChannelEmotes  = @[];
        _emotePickerGlobalEmotes   = @[];
        _emotePickerOtherEmotes    = @[];

        [self loadPreferences];
        // Synchroniser s_tapLogEnabled avec les préférences chargées.
        // Sans ça, s_tapLogEnabled reste à sa valeur par défaut (TweakSevenTV.m)
        // même si l'utilisateur a une autre préférence sauvegardée.
        extern BOOL s_tapLogEnabled;
        s_tapLogEnabled = _logsEnabled && _logTap;
        [self ensureCacheDirectory];
    }
    return self;
}


// ============================================================
// MARK: - Cache JSON sur disque (Library/Caches/s7tv/)
//
// Format de chaque fichier:
//   {
//     "ts": 1718000000,          ← timestamp Unix de la dernière mise à jour
//     "emotes": {
//       "KEKW": { "id": "...", "a": true },
//       "Pog":  { "id": "...", "a": false },
//       ...
//     }
//   }
//
// Noms de fichiers:
//   global.json          ← emotes globales 7TV
//   ch_155601320.json    ← emotes du channel Twitch ID 155601320
// ============================================================

- (void)ensureCacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = paths.firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"s7tv"];

    NSError *err;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    if (err) {
        // Ne pas utiliser [self log:] ici — on est dans init avant que debugLogging soit chargé.
        // Erreur silencieuse : le cache sera simplement non disponible.
        (void)err;
    }
    self.cacheDirectory = dir;
}

// Chemin complet d'un fichier cache
- (NSString *)cacheFilePathForName:(NSString *)name {
    return [self.cacheDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", name]];
}

// ── Lecture synchrone (sur fileIOQueue) ───────────────────────────────────────
// Retourne le dictionnaire d'emotes et via outAge l'âge du cache en secondes.
// outAge = -1 si le fichier n'existe pas.
// APPELER DEPUIS fileIOQueue UNIQUEMENT (ou via dispatch_sync(fileIOQueue, ...))

- (NSDictionary<NSString *, SevenTVEmote *> *)_readCacheFile:(NSString *)path
                                                          age:(NSTimeInterval *)outAge {
    if (outAge) *outAge = -1;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return nil;

    // Âge du cache
    NSNumber *ts = root[@"ts"];
    if ([ts isKindOfClass:[NSNumber class]] && outAge) {
        *outAge = [NSDate date].timeIntervalSince1970 - ts.doubleValue;
    }

    NSDictionary *emotesDict = root[@"emotes"];
    if (![emotesDict isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:emotesDict.count];
    for (NSString *name in emotesDict) {
        NSDictionary *d = emotesDict[name];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *emoteID = d[@"id"];
        if (![emoteID isKindOfClass:[NSString class]] || !emoteID.length) continue;

        SevenTVEmote *e = [[SevenTVEmote alloc] init];
        e.emoteName  = name;
        e.emoteID    = emoteID;
        e.isAnimated = [d[@"a"] boolValue];
        // Dimensions 1x (optionnel — absent dans les anciennes entrées cache)
        id dw = d[@"w"], dh = d[@"h"];
        if ([dw isKindOfClass:[NSNumber class]]) e.width  = [dw integerValue];
        if ([dh isKindOfClass:[NSNumber class]]) e.height = [dh integerValue];
        result[name] = e;
    }

    return result.count ? [result copy] : nil;
}

// ── Écriture asynchrone (sur fileIOQueue) ────────────────────────────────────
// Appelé depuis n'importe quel thread — dispatché sur fileIOQueue en interne.

- (void)_writeCacheFile:(NSString *)path
              withEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes {
    if (!emotes.count || !path) return;

    // Sérialiser
    NSMutableDictionary *emotesDict = [NSMutableDictionary dictionaryWithCapacity:emotes.count];
    for (NSString *name in emotes) {
        SevenTVEmote *e = emotes[name];
        // Inclure les dimensions si disponibles (rétrocompatible: champ absent = 0)
        if (e.width > 0 && e.height > 0) {
            emotesDict[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated),
                                  @"w": @(e.width),  @"h": @(e.height) };
        } else {
            emotesDict[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated) };
        }
    }

    NSDictionary *root = @{
        @"ts":     @([NSDate date].timeIntervalSince1970),
        @"emotes": [emotesDict copy]
    };

    NSError *err;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!data || err) {
        [self log:@"⚠️ Impossible de sérialiser le cache: %@", err.localizedDescription];
        return;
    }

    dispatch_async(self.fileIOQueue, ^{
        BOOL ok = [data writeToFile:path atomically:YES];
        if (!ok) {
            // Retry: le dossier a peut-être été purgé par iOS entre temps
            [[NSFileManager defaultManager]
                createDirectoryAtPath:[path stringByDeletingLastPathComponent]
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
            ok = [data writeToFile:path atomically:YES];
            if (!ok) {
                [self log:@"⚠️ Écriture cache échouée (retry): %@", path.lastPathComponent];
            }
        }
    });
}

// ── API publique: charger depuis le cache ────────────────────────────────────
// Retourne les emotes immédiatement (synchrone sur l'appelant via dispatch_sync).
// outAge = âge en secondes (-1 = pas de cache).

- (NSDictionary<NSString *, SevenTVEmote *> *)loadCacheForName:(NSString *)name
                                                            age:(NSTimeInterval *)outAge {
    NSString *path = [self cacheFilePathForName:name];
    __block NSDictionary *result = nil;
    __block NSTimeInterval age = -1;

    dispatch_sync(self.fileIOQueue, ^{
        result = [self _readCacheFile:path age:&age];
    });

    if (outAge) *outAge = age;
    return result;
}

// ── API publique: sauvegarder dans le cache (async) ──────────────────────────

- (void)saveCacheForName:(NSString *)name
              withEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes {
    NSString *path = [self cacheFilePathForName:name];
    [self _writeCacheFile:path withEmotes:emotes];
}


// ============================================================
// MARK: - Initialisation
// ============================================================

- (void)setup {
    [self log:@"SevenTVManager: setup démarré"];

    // 1. Charger les emotes globales depuis le cache fichier (instantané)
    NSTimeInterval globalAge = -1;
    NSDictionary *cachedGlobal = [self loadCacheForName:@"global" age:&globalAge];

    if (cachedGlobal.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = cachedGlobal;
        });
        if (globalAge >= 0) {
            [self log:@"⚡️ %lu emotes globales depuis cache (âge: %.0fs)",
             (unsigned long)cachedGlobal.count, globalAge];
        }
        [self _prefetchAllEmotes:cachedGlobal setKey:@"global" label:@"globales (cache)"];
    }

    // 2. Refresh API si cache absent ou périmé
    if (globalAge < 0 || globalAge > kCacheTTLGlobal) {
        if (globalAge > kCacheTTLGlobal) {
            [self log:@"🔄 Cache global périmé (%.0fs) → refresh", globalAge];
        }
        [self loadGlobalEmotes];
    } else {
        [self log:@"✅ Cache global frais, pas de refresh réseau"];
    }

    // 3. Préchauffer la connexion TCP/TLS vers cdn.7tv.app
    //    → élimine le délai de 4-5s sur la 1ère emote chargée.
    //    On le fait systématiquement, cache frais ou non.
    [SevenTVURLProtocol prewarmCDNConnection];
    [self log:@"🔥 Préchauffage connexion CDN lancé"];
}


// ============================================================
// MARK: - Préférences utilisateur (NSUserDefaults — petit, OK ici)
// ============================================================

- (void)loadPreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs objectForKey:@"s7tv_enabled"]           != nil) _isEnabled            = [prefs boolForKey:@"s7tv_enabled"];
    if ([prefs objectForKey:@"s7tv_animated"]          != nil) _showAnimated          = [prefs boolForKey:@"s7tv_animated"];
    if ([prefs objectForKey:@"s7tv_picker_anim"]       != nil) _showPickerAnimations  = [prefs boolForKey:@"s7tv_picker_anim"];
    if ([prefs objectForKey:@"s7tv_picker_anim_favs"]  != nil) _showPickerAnimationsFavoritesOnly = [prefs boolForKey:@"s7tv_picker_anim_favs"];
    if ([prefs objectForKey:@"s7tv_debug"]             != nil) _debugLogging          = [prefs boolForKey:@"s7tv_debug"];
    if ([prefs objectForKey:@"s7tv_floating_btn"]      != nil) _showFloatingButton     = [prefs boolForKey:@"s7tv_floating_btn"];
    else _showFloatingButton = YES; // activé par défaut
    if ([prefs objectForKey:@"s7tv_chat_custom_test"]  != nil) _chatCustomTestEnabled  = [prefs boolForKey:@"s7tv_chat_custom_test"];

    // --- Logs : interrupteur global + catégories ---
    if ([prefs objectForKey:@"s7tv_logs_enabled"]      != nil) _logsEnabled           = [prefs boolForKey:@"s7tv_logs_enabled"];
    if ([prefs objectForKey:@"s7tv_log_errors"]        != nil) _logErrors             = [prefs boolForKey:@"s7tv_log_errors"];
    if ([prefs objectForKey:@"s7tv_log_tap"]           != nil) _logTap                = [prefs boolForKey:@"s7tv_log_tap"];
    if ([prefs objectForKey:@"s7tv_log_swizzle"]       != nil) _logSwizzle            = [prefs boolForKey:@"s7tv_log_swizzle"];
    if ([prefs objectForKey:@"s7tv_log_cache"]         != nil) _logCache              = [prefs boolForKey:@"s7tv_log_cache"];
    if ([prefs objectForKey:@"s7tv_log_prefetch"]      != nil) _logPrefetch           = [prefs boolForKey:@"s7tv_log_prefetch"];
    if ([prefs objectForKey:@"s7tv_log_api"]           != nil) _logAPI                = [prefs boolForKey:@"s7tv_log_api"];
    if ([prefs objectForKey:@"s7tv_log_irc_channel"]   != nil) _logIRCChannel         = [prefs boolForKey:@"s7tv_log_irc_channel"];
    if ([prefs objectForKey:@"s7tv_log_ui_picker"]     != nil) _logUIPicker           = [prefs boolForKey:@"s7tv_log_ui_picker"];
    if ([prefs objectForKey:@"s7tv_log_favorites"]     != nil) _logFavorites          = [prefs boolForKey:@"s7tv_log_favorites"];
    if ([prefs objectForKey:@"s7tv_log_orientation"]   != nil) _logOrientation        = [prefs boolForKey:@"s7tv_log_orientation"];
    if ([prefs objectForKey:@"s7tv_log_image_conv"]    != nil) _logImageConversion    = [prefs boolForKey:@"s7tv_log_image_conv"];
    if ([prefs objectForKey:@"s7tv_log_chat_custom"]   != nil) _logChatCustom         = [prefs boolForKey:@"s7tv_log_chat_custom"];
    if ([prefs objectForKey:@"s7tv_log_dump"]          != nil) _logDump               = [prefs boolForKey:@"s7tv_log_dump"];

    // Charger les favoris (array d'IDs 7TV)
    NSArray *savedFavs = [prefs arrayForKey:@"s7tv_favorites"];
    if (savedFavs) {
        _favoriteEmoteIDs = [NSMutableSet setWithArray:savedFavs];
    }
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.isEnabled            forKey:@"s7tv_enabled"];
    [prefs setBool:self.showAnimated         forKey:@"s7tv_animated"];
    [prefs setBool:self.showPickerAnimations forKey:@"s7tv_picker_anim"];
    [prefs setBool:self.showPickerAnimationsFavoritesOnly forKey:@"s7tv_picker_anim_favs"];
    [prefs setBool:self.debugLogging         forKey:@"s7tv_debug"];
    [prefs setBool:self.showFloatingButton   forKey:@"s7tv_floating_btn"];
    [prefs setBool:self.chatCustomTestEnabled forKey:@"s7tv_chat_custom_test"];

    [prefs setBool:self.logsEnabled          forKey:@"s7tv_logs_enabled"];
    [prefs setBool:self.logErrors            forKey:@"s7tv_log_errors"];
    [prefs setBool:self.logTap               forKey:@"s7tv_log_tap"];
    [prefs setBool:self.logSwizzle           forKey:@"s7tv_log_swizzle"];
    [prefs setBool:self.logCache             forKey:@"s7tv_log_cache"];
    [prefs setBool:self.logPrefetch          forKey:@"s7tv_log_prefetch"];
    [prefs setBool:self.logAPI               forKey:@"s7tv_log_api"];
    [prefs setBool:self.logIRCChannel        forKey:@"s7tv_log_irc_channel"];
    [prefs setBool:self.logUIPicker          forKey:@"s7tv_log_ui_picker"];
    [prefs setBool:self.logFavorites         forKey:@"s7tv_log_favorites"];
    [prefs setBool:self.logOrientation       forKey:@"s7tv_log_orientation"];
    [prefs setBool:self.logImageConversion   forKey:@"s7tv_log_image_conv"];
    [prefs setBool:self.logChatCustom        forKey:@"s7tv_log_chat_custom"];
    [prefs setBool:self.logDump              forKey:@"s7tv_log_dump"];
    [prefs synchronize];
}

- (void)_saveFavorites {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:self.favoriteEmoteIDs.allObjects forKey:@"s7tv_favorites"];
    [prefs synchronize];
}

- (void)setIsEnabled:(BOOL)v              { _isEnabled            = v; [self savePreferences]; }
- (void)setShowAnimated:(BOOL)v           { _showAnimated          = v; [self savePreferences]; }
- (void)setShowPickerAnimations:(BOOL)v   { _showPickerAnimations  = v; [self savePreferences]; }
- (void)setShowPickerAnimationsFavoritesOnly:(BOOL)v { _showPickerAnimationsFavoritesOnly = v; [self savePreferences]; }
- (void)setShowFloatingButton:(BOOL)v {
    _showFloatingButton = v;
    [self savePreferences];
    // Afficher/masquer le bouton flottant en temps réel
    dispatch_async(dispatch_get_main_queue(), ^{
        self.floatingWindow.hidden = !v;
    });
}
- (void)setChatCustomTestEnabled:(BOOL)v {
    _chatCustomTestEnabled = v;
    [self savePreferences];
    [self log:@"[ChatCustom] 🏗 Test chat custom %@", v ? @"ACTIVÉ" : @"désactivé"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVChatCustomToggleDidChangeNotification
                          object:self];
    });
}
- (void)setDebugLogging:(BOOL)v {
    _debugLogging  = v;
    [self savePreferences];
    // NOTE : ceci ne touche plus s_tapLogEnabled — c'était le bug.
    // "Logs console" est un simple miroir NSLog, indépendant des catégories.
}

// --- Logs : interrupteur global ---
- (void)setLogsEnabled:(BOOL)v {
    _logsEnabled = v;
    [self savePreferences];
    extern BOOL s_tapLogEnabled;
    s_tapLogEnabled = v && _logTap;
}

// --- Logs : catégories ---
- (void)setLogErrors:(BOOL)v         { _logErrors = v;         [self savePreferences]; }
- (void)setLogTap:(BOOL)v {
    _logTap = v;
    [self savePreferences];
    extern BOOL s_tapLogEnabled;
    s_tapLogEnabled = _logsEnabled && v;
}
- (void)setLogSwizzle:(BOOL)v         { _logSwizzle = v;         [self savePreferences]; }
- (void)setLogCache:(BOOL)v           { _logCache = v;           [self savePreferences]; }
- (void)setLogPrefetch:(BOOL)v        { _logPrefetch = v;        [self savePreferences]; }
- (void)setLogAPI:(BOOL)v             { _logAPI = v;             [self savePreferences]; }
- (void)setLogIRCChannel:(BOOL)v      { _logIRCChannel = v;      [self savePreferences]; }
- (void)setLogUIPicker:(BOOL)v        { _logUIPicker = v;        [self savePreferences]; }
- (void)setLogFavorites:(BOOL)v       { _logFavorites = v;       [self savePreferences]; }
- (void)setLogOrientation:(BOOL)v     { _logOrientation = v;     [self savePreferences]; }
- (void)setLogImageConversion:(BOOL)v { _logImageConversion = v; [self savePreferences]; }
- (void)setLogChatCustom:(BOOL)v      { _logChatCustom = v;      [self savePreferences]; }
- (void)setLogDump:(BOOL)v            { _logDump = v;            [self savePreferences]; }


// ============================================================
// MARK: - Chargement des emotes globales 7TV
// API: GET https://7tv.io/v3/emote-sets/global
// ============================================================

- (void)loadGlobalEmotes {
    [self log:@"🌍 Chargement emotes globales depuis API..."];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emote-sets/global", S7TV_API_BASE]];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error || !data) {
            [self log:@"❌ Erreur emotes globales: %@", error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) { [self log:@"❌ JSON invalide (globales)"]; return; }

        NSDictionary *parsed = [self parseEmoteSetJSON:json];
        if (!parsed.count) { [self log:@"⚠️ Aucune emote globale parsée"]; return; }

        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = parsed;
            [self log:@"✅ %lu emotes globales chargées depuis API", (unsigned long)parsed.count];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];
            });
        });
        // Invalider le cache de tri du picker
        dispatch_async(dispatch_get_main_queue(), ^{
            extern NSArray *s_cachedSortedEmotes;
            extern NSString *s_cachedSortKey;
            s_cachedSortedEmotes = nil;
            s_cachedSortKey = nil;
        });

        [self saveCacheForName:@"global" withEmotes:parsed];
        [self _prefetchAllEmotes:parsed setKey:@"global" label:@"globales (API)"];

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// ============================================================

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName.length) return;
    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];
    self.currentChannelName = channelName;

    // Préchauffer la connexion CDN maintenant — les messages arrivent
    // ~1-2s après le JOIN, donc la connexion sera chaude à temps.
    [SevenTVURLProtocol prewarmCDNConnection];
    [self log:@"🔥 Prewarm CDN au JOIN de %@", channelName];

    // Démarrer (ou redémarrer) le heartbeat pour garder la connexion vivante.
    [self startCDNHeartbeat];

    // ── Fix cache: lookup immédiat du twitchID depuis le mapping sauvé ───────
    // Première visite : pas de mapping → attend le ROOMSTATE (< 200ms).
    // Visites suivantes : l'ID est connu → prefetch et cache démarre AVANT
    // le ROOMSTATE, les emotes sont prêtes dès le 1er message du chat.
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSDictionary *channelIDMap = [prefs dictionaryForKey:@"s7tv_channel_id_map"];
    NSString *cachedTwitchID = channelIDMap[channelName.lowercaseString];

    if (cachedTwitchID.length > 0) {
        [self log:@"⚡️ twitchID en cache pour %@: %@ → prefetch immédiat",
         channelName, cachedTwitchID];
        // Vider les emotes du channel précédent AVANT de charger les nouvelles.
        // Sans ce reset, un message ultra-rapide pourrait injecter une emote
        // de l'ancien channel pendant les ~100ms avant que loadEmotesForChannelTwitchID:
        // ne soit terminé.
        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = @{};
        });
        self.currentChannelTwitchID = cachedTwitchID;
        [self loadEmotesForChannelTwitchID:cachedTwitchID];
        // Pas de dispatch_after nécessaire : le ROOMSTATE confirmera (ou corrigera)
        // l'ID quelques ms plus tard via s7tv_handleRoomState.
        return;
    }

    // Première visite : pas de mapping → attendre le ROOMSTATE.
    // Timeout de sécurité à 5s au cas où le ROOMSTATE n'arriverait pas.
    [self log:@"⏳ Pas de twitchID en cache pour %@, attente ROOMSTATE...", channelName];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.currentChannelTwitchID) {
            [self loadEmotesForChannelTwitchID:self.currentChannelTwitchID];
        }
    });
}


// ============================================================
// MARK: - Heartbeat CDN
//
// Envoie un HEAD toutes les 20s vers cdn.7tv.app pour garder
// la connexion TCP/TLS keep-alive ouverte.
// iOS ferme les connexions inactives après ~30s → sans heartbeat,
// la 1ère emote après une pause repart à froid.
// Le timer est invalidé et recréé à chaque JOIN de channel,
// ce qui remet aussi le compteur à zéro.
// ============================================================

- (void)startCDNHeartbeat {
    // Invalider l'ancien timer s'il existe (changement de channel, etc.)
    [self.cdnHeartbeatTimer invalidate];

    // NSTimer doit tourner sur le main thread (runloop main)
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cdnHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                                  target:self
                                                                selector:@selector(cdnHeartbeatTick)
                                                                userInfo:nil
                                                                 repeats:YES];
        // Tolérance de 2s pour économiser la batterie (iOS peut grouper les timers)
        self.cdnHeartbeatTimer.tolerance = 2.0;
    });
}

- (void)cdnHeartbeatTick {
    [SevenTVURLProtocol prewarmCDNConnection];
}


// ============================================================
// MARK: - Prefetch massif (Fix L v1.7)
//
// setKey  : clé de dédup (@"global" ou twitchUserID du channel).
//           Si un prefetch avec cette clé est déjà actif → skip immédiat.
//           La clé est retirée du set à la fin du prefetch, ce qui permet
//           un re-prefetch après changement du set (nouvelles emotes).
//
// Stratégie :
//   • 20 downloads simultanés — DISPATCH_QUEUE_PRIORITY_HIGH
//   • dispatch_semaphore pour brider la concurrence
//   • isEmoteIDCached: check synchrone → skip réseau si déjà en cache
//   • Log tous les 50 emotes + au final
// ============================================================

- (void)_prefetchAllEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes
                    setKey:(NSString *)setKey
                     label:(NSString *)label {
    if (!emotes.count || !setKey.length) return;

    // ── Déduplication : une seule session de prefetch par setKey ─────────────
    @synchronized(self) {
        if ([self.activePrefetchKeys containsObject:setKey]) {
            [self log:@"⏭️ Prefetch %@ déjà actif (key:%@), skip", label, setKey];
            return;
        }
        [self.activePrefetchKeys addObject:setKey];
    }

    NSArray<SevenTVEmote *> *allEmotes = emotes.allValues;
    NSUInteger total = allEmotes.count;
    [self log:@"🚀 Prefetch %@ — %lu emotes", label, (unsigned long)total];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // 6 connexions simultanées — limite adaptée à HTTP/2 sur mobile.
        // cdn.7tv.app multiplex sur une seule connexion TCP : au-delà de ~8
        // streams le CDN throttle et iOS annule les requêtes en attente après
        // 10s → timeouts en cascade → emotes jamais cachées.
        // 6 est le sweet spot : débit maximal sans perte sur Wi-Fi et 4G/5G.
        dispatch_semaphore_t sem = dispatch_semaphore_create(6);
        dispatch_group_t group   = dispatch_group_create();

        __block NSUInteger done    = 0;
        __block NSUInteger skipped = 0;
        NSLock *lock = [[NSLock alloc] init];

        for (SevenTVEmote *emote in allEmotes) {
            // Skip si déjà en cache — zéro réseau
            if ([SevenTVURLProtocol isEmoteIDCached:emote.emoteID]) {
                [lock lock]; done++; skipped++; [lock unlock];
                continue;
            }

            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_group_enter(group);

            NSString *eid = emote.emoteID;
            [SevenTVURLProtocol prefetchEmoteID:eid completion:^{
                dispatch_semaphore_signal(sem);
                dispatch_group_leave(group);

                [lock lock];
                NSUInteger current = ++done;
                [lock unlock];

                if (current % 50 == 0 || current == total) {
                    [self log:@"📦 Prefetch %@ — %lu/%lu (skip:%lu)",
                     label, (unsigned long)current,
                     (unsigned long)total, (unsigned long)skipped];
                }
            }];
        }

        // Attendre la fin (timeout 60s)
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC));

        [self log:@"✅ Prefetch %@ terminé — %lu téléchargés, %lu déjà en cache",
         label,
         (unsigned long)(total - skipped),
         (unsigned long)skipped];

        // Bilan des emotes mises en cache — compteur tenu par SevenTVURLProtocol.
        NSInteger cachedCount = [SevenTVURLProtocol cachedEmoteCount];
        [self log:@"📊 Bilan : %ld emotes mises en cache en WebP natif depuis le démarrage",
         (long)cachedCount];

        // Libérer la clé → permettre un re-prefetch si le set change
        @synchronized(self) {
            [self.activePrefetchKeys removeObject:setKey];
        }
    });
}




// ============================================================
// MARK: - Chargement des emotes d'un channel par ID Twitch
//
// Stratégie cache-first (Fix F):
//   1. Lire le cache fichier IMMÉDIATEMENT (synchrone sur fileIOQueue)
//      → les emotes sont dispo AVANT le 1er message du chat
//   2. Si cache frais (< 30 min) → on s'arrête là, pas de réseau
//   3. Si cache absent ou périmé → requête API en arrière-plan
//      → mise à jour transparente pendant que le chat tourne
// ============================================================

- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID {
    if (!twitchUserID.length) return;

    // Anti-doublon concurrent: si une requête réseau est déjà en cours → ignorer
    @synchronized(self.fetchingChannelIDs) {
        if ([self.fetchingChannelIDs containsObject:twitchUserID]) {
            [self log:@"⏳ Fetch déjà en cours pour channel %@, ignoré", twitchUserID];
            return;
        }
    }

    NSString *cacheName = [NSString stringWithFormat:@"ch_%@", twitchUserID];

    // ── Étape 1: lire le cache immédiatement ──────────────────
    NSTimeInterval cacheAge = -1;
    NSDictionary *cached = [self loadCacheForName:cacheName age:&cacheAge];

    if (cached.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = cached;
        });
        [self log:@"⚡️ %lu emotes channel depuis cache (âge: %.0fs)",
         (unsigned long)cached.count, cacheAge];
        [self _prefetchAllEmotes:cached setKey:twitchUserID label:@"channel (cache)"];
    }

    // ── Étape 2: décider si un refresh réseau est nécessaire ──
    BOOL cacheIsFresh = (cached.count > 0 && cacheAge >= 0 && cacheAge < kCacheTTLChannel);

    if (cacheIsFresh) {
        [self log:@"✅ Cache channel frais (%.0fs < %.0fs), pas de refresh",
         cacheAge, kCacheTTLChannel];
        return;
    }

    // ── Étape 3: requête API en arrière-plan ──────────────────
    if (cacheAge > 0) {
        [self log:@"🔄 Cache channel périmé (%.0fs) → refresh API", cacheAge];
    } else {
        [self log:@"🌐 Pas de cache pour channel %@ → fetch API", twitchUserID];
    }

    @synchronized(self.fetchingChannelIDs) {
        [self.fetchingChannelIDs addObject:twitchUserID];
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/users/twitch/%@", S7TV_API_BASE, twitchUserID];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        // Retirer de fetchingChannelIDs dans tous les cas
        @synchronized(self.fetchingChannelIDs) {
            [self.fetchingChannelIDs removeObject:twitchUserID];
        }

        if (error || !data) {
            [self log:@"❌ Erreur emotes channel %@: %@", twitchUserID, error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;

        id rawEmoteSet = json[@"emote_set"];
        NSDictionary *emoteSet = [rawEmoteSet isKindOfClass:[NSDictionary class]] ? rawEmoteSet : nil;
        if (!emoteSet) {
            [self log:@"Pas d'emote_set pour channel %@ (pas sur 7TV?)", twitchUserID];
            return;
        }

        NSDictionary *parsed = [self parseEmoteSetJSON:emoteSet];
        if (!parsed.count) return;

        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = parsed;
            [self log:@"✅ %lu emotes du channel chargées depuis API", (unsigned long)parsed.count];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];
            });
        });
        // Invalider le cache de tri du picker — les nouvelles emotes doivent apparaître
        dispatch_async(dispatch_get_main_queue(), ^{
            extern NSArray *s_cachedSortedEmotes;
            extern NSString *s_cachedSortKey;
            s_cachedSortedEmotes = nil;
            s_cachedSortKey = nil;
        });

        [self saveCacheForName:cacheName withEmotes:parsed];
        [self _prefetchAllEmotes:parsed setKey:twitchUserID label:@"channel (API)"];

    }] resume];
}


// ============================================================
// MARK: - Parsing JSON d'un emote-set 7TV
// ============================================================

- (NSDictionary<NSString *, SevenTVEmote *> *)parseEmoteSetJSON:(NSDictionary *)json {
    NSArray *emotesList = json[@"emotes"];
    if (![emotesList isKindOfClass:[NSArray class]]) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:emotesList.count];

    for (id item in emotesList) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSString *name   = item[@"name"];
        NSString *itemID = item[@"id"];
        if (![name   isKindOfClass:[NSString class]]) name   = nil;
        if (![itemID isKindOfClass:[NSString class]]) itemID = nil;

        id rawData = item[@"data"];
        NSDictionary *data = [rawData isKindOfClass:[NSDictionary class]] ? rawData : nil;

        id rawEmoteID  = data[@"id"];
        NSString *emoteID = [rawEmoteID isKindOfClass:[NSString class]] ? rawEmoteID : itemID;

        id rawAnimated = data[@"animated"];
        BOOL animated  = [rawAnimated isKindOfClass:[NSNumber class]] && [rawAnimated boolValue];

        if (!name || !emoteID) continue;

        // ── Dimensions 1x depuis data.host.files ──────────────────────────────
        // L'API 7TV v3 retourne un tableau de fichiers par taille (1x, 2x, 3x, 4x).
        // On prend le fichier "1x" : c'est la taille d'affichage cible en points.
        // Exemple pour KEKW : 1x = 28×28pt, 4x = 112×112px.
        NSInteger emoteW = 0, emoteH = 0;
        id rawHost = data[@"host"];
        if ([rawHost isKindOfClass:[NSDictionary class]]) {
            id rawFiles = rawHost[@"files"];
            if ([rawFiles isKindOfClass:[NSArray class]]) {
                for (NSDictionary *file in (NSArray *)rawFiles) {
                    if (![file isKindOfClass:[NSDictionary class]]) continue;
                    NSString *fname = file[@"name"];
                    // "1x.webp", "1x.avif", "1x.gif" → premier fichier 1x trouvé
                    if ([fname hasPrefix:@"1x"]) {
                        id fw = file[@"width"], fh = file[@"height"];
                        if ([fw isKindOfClass:[NSNumber class]]) emoteW = [fw integerValue];
                        if ([fh isKindOfClass:[NSNumber class]]) emoteH = [fh integerValue];
                        break;
                    }
                }
                // Fallback: si aucun fichier "1x" → utiliser le premier disponible
                if (emoteW == 0 && [(NSArray *)rawFiles count] > 0) {
                    NSDictionary *first = ((NSArray *)rawFiles)[0];
                    if ([first isKindOfClass:[NSDictionary class]]) {
                        id fw = first[@"width"], fh = first[@"height"];
                        if ([fw isKindOfClass:[NSNumber class]]) emoteW = [fw integerValue];
                        if ([fh isKindOfClass:[NSNumber class]]) emoteH = [fh integerValue];
                    }
                }
            }
        }

        SevenTVEmote *emote = [[SevenTVEmote alloc] init];
        emote.emoteID    = emoteID;
        emote.emoteName  = name;
        emote.isAnimated = animated;
        emote.width      = emoteW;
        emote.height     = emoteH;
        result[name] = emote;
    }

    return [result copy];
}


// ============================================================
// ============================================================
// MARK: - Stockage token Twitch (intercepté depuis requêtes GQL)
// ============================================================

- (void)s7tv_captureAuthorizationHeader:(NSString *)value {
    if (!value.length || [value isEqualToString:self.twitchToken]) return;
    self.pendingAuthHeader = value;
    [self s7tv_tryFinalizeTokenCapture];
}

- (void)s7tv_captureClientIDHeader:(NSString *)value {
    if (!value.length || [value isEqualToString:self.twitchClientID]) return;
    self.pendingClientIDHeader = value;
    [self s7tv_tryFinalizeTokenCapture];
}

- (void)s7tv_tryFinalizeTokenCapture {
    if (self.pendingAuthHeader.length && self.pendingClientIDHeader.length) {
        [self saveTwitchToken:self.pendingAuthHeader clientID:self.pendingClientIDHeader];
    }
}

- (void)saveTwitchToken:(NSString *)token clientID:(NSString *)clientID {
    if (!token.length || !clientID.length) return;

    // Twitch pose son Authorization en GQL au format "OAuth <token>", mais
    // l'API Helix (utilisée pour les badges) exige le format "Bearer <token>"
    // — même token sous-jacent, juste un préfixe de schéma différent. Sans
    // cette conversion, Helix rejette silencieusement la requête (pas
    // d'erreur réseau, juste un JSON sans "data" → parsé comme 0 sets).
    NSString *normalizedToken = token;
    if ([token hasPrefix:@"OAuth "]) {
        normalizedToken = [@"Bearer " stringByAppendingString:[token substringFromIndex:6]];
    } else if (![token hasPrefix:@"Bearer "]) {
        normalizedToken = [@"Bearer " stringByAppendingString:token];
    }

    if ([normalizedToken isEqualToString:self.twitchToken]) return; // déjà à jour
    self.twitchToken   = normalizedToken;
    self.twitchClientID = clientID;
    [self log:@"[ChatCustom] 🏗 Badges: token normalisé OAuth→Bearer et sauvegardé"];
    // Déclencher le chargement des badges maintenant qu'on a le token
    [[SevenTVBadgeProvider sharedProvider] loadGlobalBadges];
    if (self.currentChannelTwitchID.length) {
        [[SevenTVBadgeProvider sharedProvider] loadBadgesForChannelID:self.currentChannelTwitchID];
    }
}

// ============================================================
// MARK: - Extraction du broadcaster ID depuis les réponses GQL Twitch
// ============================================================

- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData {
    if (!responseData) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
        if (!json) return;

        NSArray *responses = [json isKindOfClass:[NSArray class]] ? json : @[json];

        for (NSDictionary *response in responses) {
            if (![response isKindOfClass:[NSDictionary class]]) continue;

            NSString *channelLogin = nil;
            NSString *broadcasterID = [self findBroadcasterIDInObject:response
                                                         channelLogin:&channelLogin];
            if (!broadcasterID) continue;

            if (channelLogin.length > 0) {
                self.currentChannelName = channelLogin;
                [self log:@"📡 Channel name extrait GQL: %@", channelLogin];
            }

            if (![broadcasterID isEqualToString:self.currentChannelTwitchID]) {
                [self log:@"📡 Nouveau broadcaster ID via GQL: %@ (ancien: %@)",
                 broadcasterID, self.currentChannelTwitchID ?: @"aucun"];

                NSString *oldID = self.currentChannelTwitchID;
                dispatch_barrier_async(self.emoteQueue, ^{
                    self.channelEmotes = @{};
                });
                @synchronized(self.fetchingChannelIDs) {
                    if (oldID) [self.fetchingChannelIDs removeObject:oldID];
                }
                self.currentChannelTwitchID = broadcasterID;
                [self loadEmotesForChannelTwitchID:broadcasterID];
                break;
            }
        }
    });
}

- (NSString *)findBroadcasterIDInObject:(id)obj channelLogin:(NSString **)outLogin {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        NSArray *channelKeys = @[@"channel", @"broadcaster", @"user", @"streamer", @"owner"];

        for (NSString *key in channelKeys) {
            id value = dict[key];
            if ([value isKindOfClass:[NSDictionary class]]) {
                NSString *foundID = value[@"id"];
                if ([self isTwitchUserID:foundID]) {
                    if (outLogin) {
                        id rawLogin = value[@"login"] ?: value[@"name"];
                        if ([rawLogin isKindOfClass:[NSString class]] && [rawLogin length] > 0)
                            *outLogin = rawLogin;
                    }
                    return foundID;
                }
            }
        }

        for (NSString *key in dict) {
            if ([key.lowercaseString containsString:@"broadcast"] ||
                [key.lowercaseString containsString:@"channel"]) {
                NSString *result = [self findBroadcasterIDInObject:dict[key] channelLogin:outLogin];
                if (result) return result;
            }
        }
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSString *result = [self findBroadcasterIDInObject:item channelLogin:outLogin];
            if (result) return result;
        }
    }
    return nil;
}

- (BOOL)isTwitchUserID:(id)value {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *str = value;
    if (str.length < 4 || str.length > 15) return NO;
    return ([str rangeOfCharacterFromSet:
             [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound);
}


// ============================================================
// MARK: - Accès aux emotes
// ============================================================

- (SevenTVEmote *)emoteForName:(NSString *)name {
    __block SevenTVEmote *emote = nil;
    dispatch_sync(self.emoteQueue, ^{
        emote = self.channelEmotes[name] ?: self.globalEmotes[name];
    });
    return emote;
}

- (NSURL *)cdnURLForEmote:(SevenTVEmote *)emote {
    if (!emote) return nil;
    return [NSURL URLWithString:
            [NSString stringWithFormat:@"%@/%@/2x.webp", S7TV_CDN_BASE, emote.emoteID]];
}

// ============================================================
// MARK: - Picker d'emotes 7TV
//
// Affiché au-dessus de la barre de saisie Twitch quand l'utilisateur
// tape sur le bouton 7TV intégré dans la barre.
// Interface : grille de cellules (emoji-like) + barre de recherche.
// Tap sur une emote → insère le nom dans le TextField.
// ============================================================

// ID de cellule pour la collection
static NSString *const kEmoteCellID = @"S7TVEmoteCell";

// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize = 40.0;

// Clé pour stocker la NSURLSessionDataTask courante dans chaque cellule
// (annulation lors du recyclage)
static const char kS7TVTaskKey = 0;
static const char kS7TVRowKeyTag = 0; // associe un UISlider/UIButton de ligne à sa clé SevenTVChatAppearanceConfig

// ── Session partagée pour le chargement des images du picker ─────────────────
//
// Une seule session persistante avec cache NSURLCache partagé.
// Avantages :
//   • Réutilisation des connexions TCP/TLS (HTTP keep-alive)
//   • Pas de création/destruction de session à chaque cellule
//   • requestCachePolicy = ReturnCacheDataElseLoad → zéro réseau si déjà en cache
//
// NOTE : la grille d'emotes elle-même (cellForItemAtIndexPath:) ne passe
// PLUS par ce pipeline — elle utilise SevenTVEmoteImageCache /
// SevenTVEmoteAnimationEngine (partagés avec le chat custom, voir
// S7TVPickerResolvedEmote ci-dessus). Ce pipeline reste utilisé uniquement
// pour les 3 previews du panneau "Tailles" (_emotePickerLoadPreviewImageFromURL:),
// qui chargent aussi des URLs Twitch/badge ne correspondant à aucune
// SevenTVEmote et ne peuvent donc pas passer par le protocole S7TVResolvedEmote.
//
- (NSURLSession *)_pickerImageSession {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ephemeralSessionConfiguration : isolation totale du sharedURLCache iOS
        // (que Twitch peut vider à tout moment) → on branche sur notre cache dédié.
        // protocolClasses = @[] : SevenTVURLProtocol n'intercepte pas ses propres
        // requêtes CDN → pas de boucle d'interception.
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache                      = [SevenTVURLProtocol sharedEmoteCache];
        cfg.requestCachePolicy            = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses               = @[];
        cfg.HTTPMaximumConnectionsPerHost = 6;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

// ── Queue série pour le décodage des animations ───────────────────────────────
//
// CRITIQUE : ne PAS utiliser dispatch_get_global_queue pour les animations.
// Chaque frame WebP 4x décodée = ~160 KB RAM non compressée.
// 30 frames × 20 emotes visibles × threads concurrent = spike ~100 MB → OOM kill.
// Une queue SÉRIE garantit qu'un seul décodage tourne à la fois.
//
- (dispatch_queue_t)_animationDecodeQueue {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("tv.s7tv.anim-decode", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// ── Décodage image pour le picker ─────────────────────────────────────────────
//
// wantsAnimated=YES ET showPickerAnimations=YES → UIImage animée (toutes frames)
// sinon → frame 0 uniquement (rapide, économe en RAM)
//
// ── Force-decode hors thread principal ─────────────────────────────────────
//
// CGImageSourceCreateImageAtIndex crée une image "lazy" : les octets
// compressés (PNG/WebP/GIF) ne sont réellement décompressés qu'au premier
// rendu — c'est-à-dire quand UIKit assigne l'image à un CALayer, sur le
// MAIN THREAD. Résultat : même si tout ce qui précède tourne déjà en
// arrière-plan (decodeQ), UIKit refait un vrai travail de décodage
// synchrone au moment de l'affichage → micro-freeze/saccade au scroll.
//
// Fix : redessiner l'image dans un contexte bitmap ICI (donc toujours en
// arrière-plan, cette méthode n'est jamais appelée depuis le main thread)
// force la décompression complète immédiatement. Le UIImage renvoyé est
// déjà "prêt à afficher" — assigner .image sur le main thread ne coûte
// plus qu'un memcpy.
- (UIImage *)_forceDecodedImage:(UIImage *)img {
    if (!img || img.size.width < 1 || img.size.height < 1) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale  = img.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:img.size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawAtPoint:CGPointZero];
    }];
}

- (UIImage *)_decodePickerImageData:(NSData *)data wantsAnimated:(BOOL)wantsAnimated {
    if (!data) return nil;

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return [self _forceDecodedImage:[UIImage imageWithData:data]];

    // ── Animé : décoder toutes les frames ──────────────────────────────────
    if (wantsAnimated) {
        NSUInteger count = CGImageSourceGetCount(src);
        if (count > 1) {
            // Cap à 24 frames — au-delà les gains visuels sont nuls mais
            // la RAM explose (chaque frame 4x ≈ 160 KB décompressé).
            NSUInteger maxFrames = MIN(count, 24);
            NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:maxFrames];
            NSTimeInterval duration = 0.0;

            for (NSUInteger i = 0; i < maxFrames; i++) {
                // @autoreleasepool : libère le CGImage immédiatement après
                // chaque itération → pic mémoire = 1 frame, pas N frames.
                @autoreleasepool {
                    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                    if (!cgImg) continue;

                    UIImage *frame = [UIImage imageWithCGImage:cgImg];
                    CGImageRelease(cgImg);
                    [frames addObject:[self _forceDecodedImage:frame]];

                    NSDictionary *props = CFBridgingRelease(
                        CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
                    NSDictionary *gifProps  = props[@"{GIF}"];
                    NSDictionary *webpProps = props[@"{WebP}"];
                    NSNumber *delay = gifProps[@"UnclampedDelayTime"]
                                   ?: gifProps[@"DelayTime"]
                                   ?: webpProps[@"DelayTime"];
                    duration += (delay && delay.doubleValue > 0.01)
                                ? delay.doubleValue : 0.1;
                }
            }

            CFRelease(src);

            if (frames.count > 1) {
                return [UIImage animatedImageWithImages:frames
                                              duration:MAX(duration, 0.5)];
            }
            return frames.firstObject;
        }
    }

    // ── Statique : frame 0 uniquement ──────────────────────────────────────
    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    UIImage *img = nil;
    if (cgImg) { img = [UIImage imageWithCGImage:cgImg]; CGImageRelease(cgImg); }
    CFRelease(src);
    img = img ?: [UIImage imageWithData:data];
    return [self _forceDecodedImage:img];
}

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    // Appel synchrone : on est déjà sur le main thread (tap UIButton).
    // Le dispatch_async précédent créait une race : UIKit pouvait résigner
    // le firstResponder entre le tap et l'exécution du bloc, rendant
    // reloadInputViews inopérant (NO-OP si pas firstResponder).

    // ── Invalider le cache si le TextEntryView n'est plus dans une fenêtre ──
    // Twitch reconstruit sa hiérarchie lors d'un changement de channel.
    // Sans cette invalidation, le BFS est skippé et on utilise une vue orpheline
    // dont isFirstResponder est toujours NO → picker jamais affiché.
    if (self.emotePickerTextEntryView && !self.emotePickerTextEntryView.window) {
        [self log:@"⚠️ emotePickerTextEntryView orphelin (window=nil) → reset cache"];
        self.emotePickerTextEntryView = nil;
    }

    // ── Trouver le TextEntryView (UITextView de Twitch) via BFS ─────────────
    // C'est _TtC6Twitch...TextEntryView qui reste firstResponder pendant
    // l'inputAccessoryView — exactement comme le picker d'emotes natif Twitch.
    // Clé : dans UIRemoteKeyboardWindow, tapper une emote ne fait PAS résigner
    // le TextEntryView. On reproduit ça en utilisant inputAccessoryView.
    if (!self.emotePickerTextEntryView && chatInputView) {
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithObject:chatInputView];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass([v class]);
            // Chercher la sous-classe TextEntryView de Twitch (UITextView)
            if ([v isKindOfClass:[UITextView class]] && [cn containsString:@"TextEntryView"]) {
                self.emotePickerTextEntryView = (UITextView *)v;
                [self log:@"✅ TextEntryView trouvé: %@", cn];
                break;
            }
        }
        // Fallback : n'importe quel UITextView dans ChatInputView
        if (!self.emotePickerTextEntryView) {
            NSMutableArray<UIView *> *bfs2 = [NSMutableArray arrayWithObject:chatInputView];
            while (bfs2.count > 0) {
                UIView *v = bfs2.firstObject; [bfs2 removeObjectAtIndex:0];
                [bfs2 addObjectsFromArray:v.subviews];
                if ([v isKindOfClass:[UITextView class]]) {
                    self.emotePickerTextEntryView = (UITextView *)v;
                    [self log:@"⚠️ TextEntryView fallback UITextView: %@", NSStringFromClass([v class])];
                    break;
                }
            }
        }
    }

    // ── Basculer : picker déjà affiché → retirer ────────────────────────────
    // GUARD : self.emotePickerView doit être non-nil en premier.
    // Sans ce guard, si emotePickerView == nil, la comparaison
    // tv.inputAccessoryView == nil == self.emotePickerView → TRUE au premier tap →
    // _hideEmotePicker est appelé avant même que le picker ait été créé → bug d'ouverture.
    if (self.emotePickerView &&
        self.emotePickerTextEntryView &&
        self.emotePickerTextEntryView.inputView == self.emotePickerView) {
        [self _hideEmotePicker];
        return;
    }

    self.emotePickerTextField = chatInputView;
    [self _buildAndShowEmotePickerForView:chatInputView];
}

- (void)_hideEmotePicker {
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Toujours nettoyer inputView, même si tv.window == nil (stream fermé).
            // Ne pas appeler reloadInputViews/resignFirstResponder sans fenêtre →
            // UIKit crashe. On retire juste le custom inputView proprement.
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

// Appelé par TweakSevenTV quand ChatInputView quitte la fenêtre (stream fermé).
- (void)cleanupPickerForStreamClose {
    [self log:@"🔒 cleanupPickerForStreamClose → nettoyage picker"];
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        @try {
            // Pas de window → ne pas toucher au responder chain.
            tv.inputView = nil;
            tv.inputAccessoryView = nil;
        } @catch (...) {}
    }
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
}

// IVar de cache pour le tri — invalidé quand globalEmotes/channelEmotes changent
// Accédé UNIQUEMENT depuis le main thread (picker).
static NSArray<SevenTVEmote *> *s_cachedSortedEmotes    = nil;
static NSString                *s_cachedSortKey          = nil; // hash des deux sets

static NSString *s7tv_emoteSetKey(NSDictionary *global, NSDictionary *channel) {
    // Clé simple = count@channel|count@global — si les deux counts n'ont pas changé,
    // la liste est identique dans la grande majorité des cas.
    return [NSString stringWithFormat:@"%lu|%lu",
            (unsigned long)channel.count, (unsigned long)global.count];
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // ── Rassembler toutes les emotes (channel d'abord, puis globales) ──────
    __block NSDictionary *global, *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    // ── Tri mis en cache ─────────────────────────────────────────────────────
    // Le tri de 500 emotes sur main thread prend ~20-40ms → lag visible à chaque ouverture.
    // On le met en cache et on ne retrie que si les sets ont changé.
    NSString *setKey = s7tv_emoteSetKey(global, channel);
    if (!s_cachedSortedEmotes || ![setKey isEqualToString:s_cachedSortKey]) {
        NSMutableArray<SevenTVEmote *> *all = [NSMutableArray array];
        // Channel en premier (plus pertinent)
        for (NSString *key in [channel.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
            [all addObject:channel[key]];
        for (NSString *key in [global.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            if (!channel[key]) [all addObject:global[key]]; // pas de doublons
        }
        NSArray<SevenTVEmote *> *sorted = [all sortedArrayUsingComparator:
            ^NSComparisonResult(SevenTVEmote *a, SevenTVEmote *b) {
                BOOL aSquare = (a.width > 0 && a.height > 0 && a.width == a.height);
                BOOL bSquare = (b.width > 0 && b.height > 0 && b.width == b.height);
                if (aSquare != bSquare) return aSquare ? NSOrderedAscending : NSOrderedDescending;
                NSInteger aArea = a.width * a.height;
                NSInteger bArea = b.width * b.height;
                if (aArea == 0 && bArea == 0)
                    return [a.emoteName compare:b.emoteName options:NSCaseInsensitiveSearch|NSNumericSearch];
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
                return NSOrderedSame;
            }];
        s_cachedSortedEmotes = sorted;
        s_cachedSortKey      = setKey;
    }
    self.emotePickerAllEmotes = s_cachedSortedEmotes;
    self.emotePickerEmotes    = self.emotePickerAllEmotes;
    [self _updatePickerArraysForSearch:@""];

    // ── Créer le picker si besoin ─────────────────────────────────────
    // Recalcule la taille à chaque ouverture pour s'adapter à l'orientation courante.
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGFloat pickerH = 280.0;
    CGRect pickerFrame = CGRectMake(0, 0, screenSz.width, pickerH);
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame];
    }
    self.emotePickerView.frame = pickerFrame;
    // Mettre à jour la frame de la collectionView aussi (elle est déjà en sous-vue)
    CGFloat headerH = 48.0;
    self.emoteCollectionView.frame = CGRectMake(0, headerH, screenSz.width, pickerH - headerH);

    // Reset la recherche
    self.emoteSearchField.text = @"";
    [self _updatePickerArraysForSearch:@""];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];

    // ── inputView = picker (keyboard-replacement mode) ──────────────────────
    // STRATÉGIE "clavier remplacé" :
    //   inputView remplace entièrement le clavier natif.
    //   Le picker s'affiche EN DESSOUS de la chat bar (comme le picker d'emojis iOS).
    //   Le TextEntryView reste firstResponder → insertText: fonctionne normalement.
    //
    // ORDRE CRITIQUE :
    //   1. inputView = picker     → substitue le clavier par notre picker
    //   2. inputAccessoryView nil → pas de barre accessoire superflue
    //   3. becomeFirstResponder   → affiche l'inputView (picker) à la place du clavier
    //   4. reloadInputViews       → UIKit re-render avec inputView = picker
    UITextView *tv = self.emotePickerTextEntryView;
    if (tv) {
        // Étape 1 : le picker DEVIENT le clavier (affiché en dessous de la chat bar)
        self.emotePickerView.hidden = NO;
        tv.inputView = self.emotePickerView;
        tv.inputAccessoryView = nil;
        // Étape 2 : devenir firstResponder → UIKit affiche inputView (notre picker)
        if (!tv.isFirstResponder) {
            [self log:@"ℹ️ tv pas firstResponder → becomeFirstResponder"];
            [tv becomeFirstResponder];
        }
        // Étape 3 : recharger pour appliquer le nouvel inputView
        [tv reloadInputViews];
        [self log:@"✅ picker en dessous de la chat bar (inputView) sur %@", NSStringFromClass([tv class])];
    } else {
        [self log:@"⚠️ TextEntryView nil — fallback fenêtre flottante"];
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
        if (keyWindow) {
            CGFloat ph = 280.0;
            self.emotePickerView.frame = CGRectMake(0,
                keyWindow.bounds.size.height - ph - 56,
                keyWindow.bounds.size.width, ph);
            [keyWindow addSubview:self.emotePickerView];
            self.emotePickerView.hidden = NO;
        }
    }
}
- (void)_createEmotePickerViewWithFrame:(CGRect)frame {

    // ── Couleurs alignées sur la palette des paramètres 7TV ───────────────
    // Identiques à S7TVBg(), S7TVCellBg(), S7TVAccent(), S7TVGray()
    UIColor *bgColor     = [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10 — S7TVBg
    UIColor *headerColor = [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23 — S7TVCellBg
    UIColor *sepColor    = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E — séparateur Twitch
    UIColor *textColor   = [UIColor whiteColor];
    UIColor *subColor    = [UIColor colorWithWhite:0.55 alpha:1.0];                        // S7TVGray
    UIColor *searchBg    = [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23 — S7TVCellBg

    // ── Conteneur principal ────────────────────────────────────────────────
    UIView *picker = [[UIView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    self.emotePickerView = picker;

    // ── Header ─────────────────────────────────────────────────────────────
    CGFloat headerH = 56.0;
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, headerH)];
    headerView.backgroundColor = headerColor;
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Séparateur bas du header
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, headerH - 0.5, frame.size.width, 0.5)];
    sep.backgroundColor = sepColor;
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:sep];

    // ── Conteneur "normal" : logo + titre + search ─────────────────────────
    UIView *normalContent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, headerH)];
    normalContent.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.pickerHeaderNormalContent = normalContent;

    // Logo 7TV (PNG base64, ratio correct) + label "Emotes"
    // PNG : 76×56 px → @2x = 38×28 pt
    NSData *_logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_logoImg = [UIImage imageWithData:_logoData scale:2.0];
    // UIImageView centré verticalement dans le header, respecte le ratio naturel du PNG.
    // Réduction de 20% par rapport à la taille naturelle du PNG (38×28 pt → 30×22 pt).
    CGFloat _logoW = _logoImg ? _logoImg.size.width  * 0.8 : 30.0;
    CGFloat _logoH = _logoImg ? _logoImg.size.height * 0.8 : 22.0;
    CGFloat _logoY = (headerH - _logoH) / 2.0;
    UIImageView *_logoIV = [[UIImageView alloc] initWithFrame:CGRectMake(12, _logoY, _logoW, _logoH)];
    _logoIV.image = _logoImg;
    _logoIV.contentMode = UIViewContentModeScaleAspectFit;
    [normalContent addSubview:_logoIV];

    // Label "Emotes" à droite du logo
    CGFloat _lblX = 12 + _logoW + 4;
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(_lblX, 0, 80, headerH)];
    titleLbl.text = @"Emotes";
    titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    titleLbl.textColor = textColor;
    self.pickerHeaderTitleLabel = titleLbl;
    [normalContent addSubview:titleLbl];

    // Champ de recherche
    // X = logo(38) + gap(4) + label(~60) + gap(6) = ~108 → on prend 110
    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(110, 9, frame.size.width - 110 - 48 - 44, 30)];
    search.placeholder     = @"Rechercher une emote…";
    search.font            = [UIFont systemFontOfSize:13];
    search.returnKeyType   = UIReturnKeyDone;
    search.clearButtonMode = UITextFieldViewModeWhileEditing;
    search.backgroundColor = searchBg;
    search.textColor       = textColor;
    search.layer.cornerRadius = 8;
    search.clipsToBounds   = YES;
    // Padding gauche
    search.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,1)];
    search.leftViewMode = UITextFieldViewModeAlways;
    search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Rechercher…"
            attributes:@{NSForegroundColorAttributeName: subColor}];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // Déléguer à self pour intercepter le focus et éviter que le picker se ferme
    search.delegate = (id<UITextFieldDelegate>)self;
    [search addTarget:self action:@selector(_emoteSearchChanged:)
     forControlEvents:UIControlEventEditingChanged];
    self.emoteSearchField = search;
    [normalContent addSubview:search];

    // Bouton slider (à gauche du ×)
    UIButton *sliderBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sliderBtn.frame = CGRectMake(frame.size.width - 44 - 44, 0, 44, headerH);
    sliderBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *sliderCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [sliderBtn setImage:[UIImage systemImageNamed:@"slider.horizontal.3" withConfiguration:sliderCfg]
               forState:UIControlStateNormal];
    sliderBtn.tintColor = subColor;
    [sliderBtn addTarget:self action:@selector(_emotePickerSizesToggleTapped)
        forControlEvents:UIControlEventTouchUpInside];
    self.pickerSizesToggleBtn = sliderBtn;
    [normalContent addSubview:sliderBtn];

    [headerView addSubview:normalContent];
    self.pickerHeaderView = headerView;

    // Bouton fermer ×
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(frame.size.width - 44, 0, 44, headerH);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *xCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:xCfg]
              forState:UIControlStateNormal];
    closeBtn.tintColor = subColor;
    [closeBtn addTarget:self action:@selector(_emotePickerCloseTapped)
       forControlEvents:UIControlEventTouchUpInside];
    [normalContent addSubview:closeBtn];

    [picker addSubview:headerView];

    // ── Collection View — SCROLL VERTICAL UNIQUEMENT ───────────────────────
    //
    // Chaque cellule a sa propre taille (ratio de l'emote).
    // La hauteur de référence = screenWidth / 6 → environ 6 emotes carrées par ligne.
    // Les emotes larges (ratio > 1) prennent plus de largeur → moins par ligne.
    // Les emotes étroites (ratio < 1) prennent moins → plus par ligne.
    //
    // Bordure : 1 pixel physique (1/scale pt) sur CHAQUE cellule via layer.border.
    // → La bordure épouse exactement la forme de la cellule, y compris les
    //   rangées incomplètes (pas de fond commun qui déborde).
    //
    // Espacement inter-cellule = 0 : les bordures adjacentes forment 2 pixels
    // visuels, ce qui est propre et compact.

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection         = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing      = 0;
    layout.sectionInset            = UIEdgeInsetsZero;
    layout.headerReferenceSize     = CGSizeMake(frame.size.width, 28.0);

    UICollectionView *cv = [[UICollectionView alloc]
        initWithFrame:CGRectMake(0, headerH, frame.size.width, frame.size.height - headerH)
 collectionViewLayout:layout];
    // Fond sombre = même couleur que les cellules.
    // La bordure blanche est sur chaque cellule (layer.border), pas sur le fond.
    cv.backgroundColor        = bgColor;
    cv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cv.dataSource             = (id<UICollectionViewDataSource>)self;
    cv.delegate               = (id<UICollectionViewDelegate>)self;
    // SCROLL VERTICAL — pas d'horizontal
    cv.alwaysBounceVertical   = YES;
    cv.alwaysBounceHorizontal = NO;
    cv.showsHorizontalScrollIndicator = NO;
    cv.showsVerticalScrollIndicator   = YES;

    [cv registerClass:[S7TVEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellID];
    [cv registerClass:[UICollectionReusableView class]
   forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
          withReuseIdentifier:@"S7TVSectionHeader"];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    // ── Panneau des tailles ──────────────────────────────────────────────
    // Remplace la grille (pas un menu séparé) quand on tape sur ⚙️. Les 5
    // tailles sont empilées et réglables en même temps, chacune avec une
    // preview live à droite qui reflète la valeur du slider.
    UIScrollView *sizesPanel = [[UIScrollView alloc] initWithFrame:
        CGRectMake(0, headerH, frame.size.width, frame.size.height - headerH)];
    sizesPanel.backgroundColor = bgColor;
    sizesPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sizesPanel.hidden = YES;
    self.pickerSizesPanelView   = sizesPanel;
    self.pickerSizeSliders      = [NSMutableDictionary dictionary];
    self.pickerSizeValueLabels  = [NSMutableDictionary dictionary];
    self.pickerSizePreviewViews = [NSMutableDictionary dictionary];

    CGFloat rowH = 84.0, rowY = 4.0;
    CGFloat previewW = 64.0, previewH = 44.0;
    for (NSArray *entry in self._emotePickerSizeOptionsTable) {
        NSString *key = entry[0], *label = entry[1];
        CGFloat minVal = [entry[2] doubleValue], maxVal = [entry[3] doubleValue];
        CGFloat current = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
        if (current < minVal || current > maxVal) current = minVal;

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, rowY, frame.size.width, rowH)];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UIView *rowSep = [[UIView alloc] initWithFrame:CGRectMake(12, rowH - 0.5, frame.size.width - 24, 0.5)];
        rowSep.backgroundColor = sepColor;
        rowSep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addSubview:rowSep];

        // Nom de la propriété (juste le nom, la valeur va dans la pill à côté)
        UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 9, 130, 16)];
        nameLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        nameLbl.textColor = textColor;
        nameLbl.text = label;
        [row addSubview:nameLbl];

        // Pill de valeur — même langage visuel que le pill "au-dessus du
        // thumb" de l'ancien slider unique (violet Twitch, texte blanc bold).
        UILabel *valuePill = [[UILabel alloc] initWithFrame:CGRectMake(12 + 130 + 6, 7, 44, 20)];
        valuePill.font = [UIFont boldSystemFontOfSize:11];
        valuePill.textColor = [UIColor whiteColor];
        valuePill.textAlignment = NSTextAlignmentCenter;
        valuePill.backgroundColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
        valuePill.layer.cornerRadius = 6;
        valuePill.layer.masksToBounds = YES;
        valuePill.text = [NSString stringWithFormat:@"%ld pt", (long)llround(current)];
        [row addSubview:valuePill];
        self.pickerSizeValueLabels[key] = valuePill;

        // Reset (valeur par défaut de cette ligne uniquement)
        UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        resetBtn.frame = CGRectMake(frame.size.width - 32, 4, 28, 24);
        resetBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        UIImageSymbolConfiguration *rCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
        [resetBtn setImage:[UIImage systemImageNamed:@"arrow.counterclockwise" withConfiguration:rCfg]
                  forState:UIControlStateNormal];
        resetBtn.tintColor = subColor;
        objc_setAssociatedObject(resetBtn, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [resetBtn addTarget:self action:@selector(_emotePickerRowResetTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:resetBtn];

        // Preview à droite — placée SOUS la zone nom/pill/reset (y=34) pour
        // ne jamais passer devant le bouton reset. Même traitement visuel
        // que les cellules de la grille (fond bgColor + bordure 1px sepColor).
        CGFloat previewX = frame.size.width - previewW - 8;
        UIView *previewBox = [[UIView alloc] initWithFrame:CGRectMake(previewX, 34, previewW, previewH)];
        previewBox.backgroundColor = bgColor;
        previewBox.layer.cornerRadius = 8;
        previewBox.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        previewBox.layer.borderColor = sepColor.CGColor;
        previewBox.clipsToBounds = YES;
        previewBox.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [row addSubview:previewBox];
        [self _emotePickerBuildPreviewContentForKey:key inBox:previewBox value:current];

        // Slider — occupe le reste de la largeur à gauche de la preview
        CGFloat sliderX = 12, sliderW = previewX - 8 - sliderX;
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, 36, sliderW, 22)];
        slider.minimumValue = minVal;
        slider.maximumValue = maxVal;
        slider.value = (float)current;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
        slider.maximumTrackTintColor = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
        slider.thumbTintColor        = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
        slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        objc_setAssociatedObject(slider, &kS7TVRowKeyTag, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [slider addTarget:self action:@selector(_emotePickerRowSliderChanged:)
          forControlEvents:UIControlEventValueChanged];
        [row addSubview:slider];
        self.pickerSizeSliders[key] = slider;

        [sizesPanel addSubview:row];
        rowY += rowH;
    }
    sizesPanel.contentSize = CGSizeMake(frame.size.width, rowY);
    [picker addSubview:sizesPanel];

    // NOTE: pas d'addSubview ici — la vue est attachée via inputView (remplace le clavier)
}

// ── Recherche ──────────────────────────────────────────────────────────────

// ── Méthode centrale de filtrage : met à jour les 2 sections ──────────────

- (void)_updatePickerArraysForSearch:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    NSMutableArray<SevenTVEmote *> *favs    = [NSMutableArray array];
    NSMutableArray<SevenTVEmote *> *channel = [NSMutableArray array];
    NSMutableArray<SevenTVEmote *> *global  = [NSMutableArray array];

    // Snapshot des dicts pour distinguer channel vs global
    __block NSDictionary *channelDict;
    dispatch_sync(self.emoteQueue, ^{
        channelDict = self.channelEmotes ?: @{};
    });

    for (SevenTVEmote *e in self.emotePickerAllEmotes) {
        BOOL matches = (q.length == 0) || [e.emoteName.lowercaseString containsString:lower];
        if (!matches) continue;
        if ([self.favoriteEmoteIDs containsObject:e.emoteID]) {
            [favs addObject:e];
        } else if (channelDict[e.emoteName] != nil) {
            [channel addObject:e];
        } else {
            [global addObject:e];
        }
    }
    self.emotePickerFavoriteEmotes = [favs copy];
    self.emotePickerChannelEmotes  = [channel copy];
    self.emotePickerGlobalEmotes   = [global copy];
    // Maintenir emotePickerOtherEmotes pour compatibilité
    self.emotePickerOtherEmotes    = self.emotePickerChannelEmotes;
    self.emotePickerEmotes         = self.emotePickerOtherEmotes;

    // Préchauffage des favoris : décodage lancé dès que la liste est connue,
    // avant même que la 1ère cellule ne les demande. La section Favoris est
    // la plus consultée (toujours en haut, souvent rouverte) — ce préchauffage
    // rend son affichage quasi instantané à l'ouverture du picker.
    [self _s7tv_prewarmPickerImagesForEmotes:self.emotePickerFavoriteEmotes];
}

// Préchauffe le cache décodé (SevenTVEmoteImageCache) — et, si les animations
// sont activées, l'engine d'animation — pour une liste d'emotes, sans bloquer
// l'UI ni forcer d'affichage. Idempotent : une emote déjà en cache ou déjà en
// cours de chargement (dédup gérée en interne par SevenTVEmoteImageCache)
// n'est jamais retéléchargée/redécodée en double.
- (void)_s7tv_prewarmPickerImagesForEmotes:(NSArray<SevenTVEmote *> *)emotes {
    if (emotes.count == 0) return;
    SevenTVEmoteImageCache *cache = [SevenTVEmoteImageCache sharedCache];
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];
    BOOL wantsAnimated = self.showPickerAnimations;

    for (SevenTVEmote *emote in emotes) {
        S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
        NSString *key = resolved.imageURL.absoluteString;

        if (emote.isAnimated && wantsAnimated) {
            if (![cache cachedFramesForResolvedEmote:resolved]) {
                [cache framesForResolvedEmote:resolved completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
                    if (frames) [engine registerFrames:frames forKey:key];
                }];
            }
        } else if (![cache cachedImageForResolvedEmote:resolved]) {
            [cache imageForResolvedEmote:resolved completion:^(UIImage * _Nullable image) {
                // Rien à faire ici : le seul but est de peupler le cache
                // avant que cellForItemAtIndexPath: en ait besoin.
            }];
        }
    }
}

// ── UITextFieldDelegate — intercepte le focus du champ de recherche ────────
//
// PROBLÈME : quand emoteSearchField appelle becomeFirstResponder, UIKit
// résigne automatiquement l'ancien firstResponder (TextEntryView).
// Cela retire l'inputView du TextEntryView → le picker disparaît et
// les frappes suivantes vont directement dans la chatbox de Twitch.
//
// SOLUTION : bloquer becomeFirstResponder (retourner NO dans le delegate),
// et afficher à la place un UIAlertController avec un champ texte.
// L'UIAlertController est une fenêtre modale iOS → le TextEntryView reste
// firstResponder en arrière-plan, son inputView (le picker) ne bouge pas.
// Quand l'utilisateur valide, on applique la recherche et on recharge la grille.
//
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField != self.emoteSearchField) return YES;

    // Capturer la query courante pour pré-remplir l'alerte
    NSString *currentQuery = textField.text ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rechercher une emote"
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *alertField) {
        alertField.placeholder   = @"Nom de l'emote…";
        alertField.text          = currentQuery;
        alertField.returnKeyType = UIReturnKeySearch;
        alertField.clearButtonMode = UITextFieldViewModeWhileEditing;
        // Sélectionner tout le texte existant pour faciliter la réécriture
        if (currentQuery.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [alertField selectAll:nil];
            });
        }
    }];

    UIAlertAction *searchAction = [UIAlertAction
        actionWithTitle:@"Rechercher"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
        NSString *query = alert.textFields.firstObject.text ?: @"";
        // Mettre à jour le texte du champ affiché pour feedback visuel
        textField.text = query;
        if (query.length == 0) {
            UIColor *subColor = [UIColor colorWithWhite:0.55 alpha:1.0];
            textField.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:@"Rechercher…"
                    attributes:@{NSForegroundColorAttributeName: subColor}];
        }
        [self _applySearchQuery:query];
        // Restaurer le picker : l'alerte a pris le focus → le clavier natif
        // est apparu. On force le TextEntryView à redevenir firstResponder
        // avec son inputView = picker, ce qui efface le clavier et réaffiche le picker.
        [self _restorePickerFocus];
    }];

    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:@"Annuler"
                  style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *action) {
        // Même chose à l'annulation : restaurer le picker
        [self _restorePickerFocus];
    }];

    [alert addAction:searchAction];
    [alert addAction:cancelAction];
    alert.preferredAction = searchAction;

    // Présenter depuis le topViewController (le picker est inputView, pas un VC)
    [[self topViewController] presentViewController:alert animated:YES completion:nil];

    // Bloquer le becomeFirstResponder → le picker reste affiché
    return NO;
}

- (void)_applySearchQuery:(NSString *)query {
    [self _updatePickerArraysForSearch:query];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// Restaure le picker après fermeture de l'UIAlertController.
// La fermeture de l'alerte déclenche parfois un resign/become du firstResponder
// sur le TextEntryView, ce qui efface son inputView et affiche le clavier natif.
// On attend la fin de l'animation de fermeture (~0.35s) puis on réassigne
// inputView = picker et on force reloadInputViews.
- (void)_restorePickerFocus {
    __weak UITextView *weakTV = self.emotePickerTextEntryView;
    __weak UIView *weakPicker = self.emotePickerView;
    if (!weakTV || !weakPicker) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UITextView *tv = weakTV;
        UIView *pickerView = weakPicker;
        // Guard : si le stream a été fermé entre temps, tv.window == nil
        if (!tv || !tv.window || !pickerView) return;
        // Réassigner l'inputView au cas où il aurait été effacé
        tv.inputView = pickerView;
        tv.inputAccessoryView = nil;
        pickerView.hidden = NO;
        if (!tv.isFirstResponder) {
            [tv becomeFirstResponder];
        }
        [tv reloadInputViews];
    });
}

// Appelé par UIControlEventEditingChanged (cas où le champ est modifié
// programmatiquement — en pratique bloqué par textFieldShouldBeginEditing:)
- (void)_emoteSearchChanged:(UITextField *)field {
    [self _applySearchQuery:field.text ?: @""];
}



// ── Long press → toggle favori ─────────────────────────────────────────────

- (void)_handleLongPressOnPicker:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    CGPoint pt = [gr locationInView:self.emoteCollectionView];
    NSIndexPath *ip = [self.emoteCollectionView indexPathForItemAtPoint:pt];
    if (!ip) return;

    SevenTVEmote *emote = [self _emoteForIndexPath:ip];
    if (!emote) return;

    BOOL isFav = [self.favoriteEmoteIDs containsObject:emote.emoteID];
    if (isFav) {
        [self.favoriteEmoteIDs removeObject:emote.emoteID];
        [self log:@"💔 Favori retiré : %@", emote.emoteName];
    } else {
        [self.favoriteEmoteIDs addObject:emote.emoteID];
        [self log:@"⭐ Favori ajouté : %@", emote.emoteName];
    }
    [self _saveFavorites];

    // Haptique
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // Rebuild les arrays et recharger
    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self.emoteCollectionView reloadData];
}

// ── Helper : emote à partir d'un indexPath (section 0=favs, 1=others) ──────

- (SevenTVEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        if ((NSUInteger)ip.item < self.emotePickerFavoriteEmotes.count)
            return self.emotePickerFavoriteEmotes[(NSUInteger)ip.item];
    } else if (ip.section == 1) {
        if ((NSUInteger)ip.item < self.emotePickerChannelEmotes.count)
            return self.emotePickerChannelEmotes[(NSUInteger)ip.item];
    } else {
        if ((NSUInteger)ip.item < self.emotePickerGlobalEmotes.count)
            return self.emotePickerGlobalEmotes[(NSUInteger)ip.item];
    }
    return nil;
}

// ── Slider taille des emotes ───────────────────────────────────────────────

// Table nom-de-clé → (nom affiché, min, max) — une seule source pour le menu
// de sélection, l'ouverture du slider et le label de propriété. Bornes
// choisies pour couvrir large sans avoir à les retoucher plus tard (~2x le
// défaut mesuré pour chaque élément, voir SevenTVChatAppearanceConfig.m).
- (NSArray<NSArray *> *)_emotePickerSizeOptionsTable {
    return @[
        @[@"emote7TVSize",     @"Emotes 7TV",     @12, @56],
        @[@"emoteTwitchSize",  @"Emotes Twitch",  @12, @56],
        @[@"badgeSize",        @"Badges",         @8,  @34],
        @[@"usernameFontSize", @"Texte pseudo",   @8,  @28],
        @[@"messageFontSize",  @"Texte message",  @8,  @28],
    ];
}

// Bascule grille ↔ panneau des tailles. Plus de menu de sélection : les 5
// lignes sont toutes visibles et réglables en même temps.
- (void)_emotePickerSizesToggleTapped {
    BOOL show = !self.pickerSizesPanelVisible;
    self.pickerSizesPanelVisible = show;
    self.pickerSizesPanelView.hidden = !show;
    self.emoteCollectionView.hidden  = show;
    self.emoteSearchField.hidden     = show;
    self.pickerHeaderTitleLabel.text = show ? @"Tailles" : @"Emotes";
    self.pickerSizesToggleBtn.tintColor = show
        ? [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0]
        : [UIColor colorWithWhite:0.55 alpha:1.0];
    if (show) [self _emotePickerLoadRealPreviewAssetsIfNeeded];
}

- (void)_emotePickerRowSliderChanged:(UISlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, &kS7TVRowKeyTag);
    if (!key) return;
    NSInteger val = (NSInteger)roundf(slider.value);
    slider.value = (float)val; // snap au pas 1

    // Branché sur la vraie config du chat custom (SevenTVChatAppearanceConfig)
    // — setValue:forSizeKey: sauvegarde ET notifie automatiquement le chat
    // en direct pour la clé concernée.
    [[SevenTVChatAppearanceConfig sharedConfig] setValue:(CGFloat)val forSizeKey:key];
    [self _emotePickerRefreshRowDisplayForKey:key value:val];
}

- (void)_emotePickerRowResetTapped:(UIButton *)btn {
    NSString *key = objc_getAssociatedObject(btn, &kS7TVRowKeyTag);
    if (!key) return;
    [[SevenTVChatAppearanceConfig sharedConfig] resetKeyToDefault:key];
    CGFloat val = [[[SevenTVChatAppearanceConfig sharedConfig] valueForKey:key] doubleValue];
    self.pickerSizeSliders[key].value = (float)val;
    [self _emotePickerRefreshRowDisplayForKey:key value:val];
}

// Met à jour la pill "XX pt" + la preview d'une ligne donnée
- (void)_emotePickerRefreshRowDisplayForKey:(NSString *)key value:(CGFloat)val {
    self.pickerSizeValueLabels[key].text = [NSString stringWithFormat:@"%ld pt", (long)llround(val)];
    [self _emotePickerUpdatePreviewForKey:key value:val];
}

// "image" = vraie image (aspect ratio d'origine) : emote 7TV globale, vraie
// emote Twitch (Kappa, CDN officiel), vrai badge Twitch (Modérateur, CDN
// officiel). "text" = mot d'exemple rendu à la taille réglée (pseudo / message).
- (NSString *)_emotePickerPreviewKindForKey:(NSString *)key {
    if ([key isEqualToString:@"usernameFontSize"] || [key isEqualToString:@"messageFontSize"]) return @"text";
    return @"image";
}

- (void)_emotePickerBuildPreviewContentForKey:(NSString *)key inBox:(UIView *)box value:(CGFloat)value {
    NSString *kind = [self _emotePickerPreviewKindForKey:key];
    UIView *content = nil;
    if ([kind isEqualToString:@"text"]) {
        UILabel *lbl = [[UILabel alloc] init];
        BOOL isUsername = [key isEqualToString:@"usernameFontSize"];
        lbl.text = isUsername ? @"Pseudo" : @"Salut !";
        lbl.textColor = isUsername
            ? [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]
            : [UIColor whiteColor];
        content = lbl;
    } else {
        // Image réelle chargée async par _emotePickerLoadRealPreviewAssetsIfNeeded
        // (ou déjà en cache si le panneau a déjà été ouvert une fois).
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        content = iv;
    }
    [box addSubview:content];
    self.pickerSizePreviewViews[key] = content;
    [self _emotePickerUpdatePreviewForKey:key value:value];
}

- (void)_emotePickerUpdatePreviewForKey:(NSString *)key value:(CGFloat)value {
    UIView *content = self.pickerSizePreviewViews[key];
    UIView *box = content.superview;
    if (!content || !box) return;
    CGFloat boxW = box.bounds.size.width, boxH = box.bounds.size.height;

    if ([[self _emotePickerPreviewKindForKey:key] isEqualToString:@"text"]) {
        UILabel *lbl = (UILabel *)content;
        BOOL isUsername = [key isEqualToString:@"usernameFontSize"];
        lbl.font = isUsername ? [UIFont boldSystemFontOfSize:value] : [UIFont systemFontOfSize:value];
        [lbl sizeToFit];
        if (lbl.bounds.size.width > boxW - 8) {
            CGRect f = lbl.frame; f.size.width = boxW - 8; lbl.frame = f;
        }
        lbl.center = CGPointMake(boxW / 2.0, boxH / 2.0);
    } else {
        // Image réelle — aspect ratio d'origine, grandit/rétrécit avec la valeur
        UIImageView *iv = (UIImageView *)content;
        UIImage *img = iv.image;
        CGFloat ratio = (img && img.size.height > 0) ? (img.size.width / img.size.height) : 1.0;
        CGFloat targetH = MIN(value, boxH - 6);
        CGFloat targetW = MIN(targetH * ratio, boxW - 6);
        targetH = targetW / ratio;
        iv.frame = CGRectMake(0, 0, targetW, targetH);
        iv.center = CGPointMake(boxW / 2.0, boxH / 2.0);
    }
}

// Charge les 3 vraies images utilisées comme previews (une seule fois, mises
// en cache dans les UIImageView elles-mêmes — pas de refetch aux toggles
// suivants) :
//  - "Emotes 7TV"    → l'emote globale EZ, même pipeline que la grille
//  - "Emotes Twitch" → Kappa (emote globale Twitch, ID stable et public)
//  - "Badges"        → le badge Modérateur Twitch (asset public du CDN officiel)
- (void)_emotePickerLoadRealPreviewAssetsIfNeeded {
    UIImageView *ivEZ = (UIImageView *)self.pickerSizePreviewViews[@"emote7TVSize"];
    if ([ivEZ isKindOfClass:[UIImageView class]] && !ivEZ.image) {
        SevenTVEmote *ez = nil;
        for (SevenTVEmote *e in self.emotePickerAllEmotes) {
            if ([e.emoteName isEqualToString:@"EZ"]) { ez = e; break; }
        }
        if (!ez) ez = self.emotePickerGlobalEmotes.firstObject ?: self.emotePickerAllEmotes.firstObject;
        if (ez) [self _emotePickerLoadPreviewImageFromURL:[self cdnURLForEmote:ez] forKey:@"emote7TVSize"];
    }

    UIImageView *ivKappa = (UIImageView *)self.pickerSizePreviewViews[@"emoteTwitchSize"];
    if ([ivKappa isKindOfClass:[UIImageView class]] && !ivKappa.image) {
        NSURL *kappaURL = [NSURL URLWithString:@"https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/3.0"];
        [self _emotePickerLoadPreviewImageFromURL:kappaURL forKey:@"emoteTwitchSize"];
    }

    UIImageView *ivBadge = (UIImageView *)self.pickerSizePreviewViews[@"badgeSize"];
    if ([ivBadge isKindOfClass:[UIImageView class]] && !ivBadge.image) {
        NSURL *badgeURL = [NSURL URLWithString:
            @"https://static-cdn.jtvnw.net/badges/v1/3267646d-33f0-4b17-b3df-f923a41db1d0/3"];
        [self _emotePickerLoadPreviewImageFromURL:badgeURL forKey:@"badgeSize"];
    }
}

// Fetch + décodage générique (même pipeline réseau que la grille :
// cdnURLForEmote:/_pickerImageSession/_decodePickerImageData:) réutilisé
// pour les 3 previews, quelle que soit leur source.
- (void)_emotePickerLoadPreviewImageFromURL:(NSURL *)url forKey:(NSString *)key {
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[self _pickerImageSession] dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data) return;
        UIImage *img = [weakSelf _decodePickerImageData:data wantsAnimated:NO];
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            UIImageView *iv = (UIImageView *)strongSelf.pickerSizePreviewViews[key];
            if (![iv isKindOfClass:[UIImageView class]]) return;
            iv.image = img;
            CGFloat val = strongSelf.pickerSizeSliders[key].value;
            [strongSelf _emotePickerUpdatePreviewForKey:key value:val];
        });
    }];
    [task resume];
}

- (void)_emotePickerCloseTapped {
    [self _hideEmotePicker];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return 3; // Section 0 = favoris, Section 1 = emotes de channel, Section 2 = emotes globales
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.emotePickerFavoriteEmotes.count;
    if (section == 1) return (NSInteger)self.emotePickerChannelEmotes.count;
    return (NSInteger)self.emotePickerGlobalEmotes.count;
}

// ── Headers de section ────────────────────────────────────────────────────

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    UICollectionReusableView *header = [cv dequeueReusableSupplementaryViewOfKind:kind
                                                               withReuseIdentifier:@"S7TVSectionHeader"
                                                                      forIndexPath:indexPath];
    // Nettoyer
    for (UIView *sub in header.subviews) [sub removeFromSuperview];

    UIColor *sepColor  = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E — séparateur Twitch
    UIColor *textColor = [UIColor colorWithWhite:0.55 alpha:1.0];                        // S7TVGray
    header.backgroundColor = [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10 — S7TVBg

    if (indexPath.section == 0 && self.emotePickerFavoriteEmotes.count > 0) {
        // Séparateur haut
        UIView *topSep = [[UIView alloc] initWithFrame:CGRectMake(8, 0, cv.bounds.size.width - 16, 0.5)];
        topSep.backgroundColor = sepColor;
        [header addSubview:topSep];

        // Étoile ★ violette style Twitch
        UIImageView *star = [[UIImageView alloc] initWithFrame:CGRectMake(14, 6, 13, 13)];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:10 weight:UIImageSymbolWeightBold];
        star.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        star.tintColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]; // violet Twitch
        [header addSubview:star];

        // Label "Favoris" violet Twitch
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(31, 5, 120, 18)];
        lbl.text      = @"Favoris";
        lbl.font      = [UIFont boldSystemFontOfSize:11];
        lbl.textColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]; // violet Twitch
        [header addSubview:lbl];

        // Compteur aligné à droite
        UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(8, 5, cv.bounds.size.width - 16, 18)];
        count.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.emotePickerFavoriteEmotes.count];
        count.font = [UIFont systemFontOfSize:10];
        count.textColor = [UIColor colorWithWhite:0.40 alpha:1.0];
        count.textAlignment = NSTextAlignmentRight;
        [header addSubview:count];

        // Séparateur bas
        UIView *botSep = [[UIView alloc] initWithFrame:CGRectMake(8, 27.5, cv.bounds.size.width - 16, 0.5)];
        botSep.backgroundColor = sepColor;
        [header addSubview:botSep];

    } else if (indexPath.section == 1) {
        // Header "Emotes de channel"
        UIView *topSep = [[UIView alloc] initWithFrame:CGRectMake(8, 0, cv.bounds.size.width - 16, 0.5)];
        topSep.backgroundColor = sepColor;
        [header addSubview:topSep];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 4, 200, 20)];
        lbl.text      = @"Emotes de channel";
        lbl.font      = [UIFont boldSystemFontOfSize:11];
        lbl.textColor = textColor;
        [header addSubview:lbl];

        // Compteur aligné à droite
        UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, cv.bounds.size.width - 16, 20)];
        count.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.emotePickerChannelEmotes.count];
        count.font = [UIFont systemFontOfSize:10];
        count.textColor = [UIColor colorWithWhite:0.40 alpha:1.0];
        count.textAlignment = NSTextAlignmentRight;
        [header addSubview:count];

        UIView *botSep = [[UIView alloc] initWithFrame:CGRectMake(8, 27.5, cv.bounds.size.width - 16, 0.5)];
        botSep.backgroundColor = sepColor;
        [header addSubview:botSep];

    } else if (indexPath.section == 2 && self.emotePickerGlobalEmotes.count > 0) {
        // Header "Emotes globales" tout en bas
        UIView *topSep = [[UIView alloc] initWithFrame:CGRectMake(8, 0, cv.bounds.size.width - 16, 0.5)];
        topSep.backgroundColor = sepColor;
        [header addSubview:topSep];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 4, 200, 20)];
        lbl.text      = @"Emotes globales";
        lbl.font      = [UIFont boldSystemFontOfSize:11];
        lbl.textColor = textColor;
        [header addSubview:lbl];

        // Compteur aligné à droite
        UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, cv.bounds.size.width - 16, 20)];
        count.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.emotePickerGlobalEmotes.count];
        count.font = [UIFont systemFontOfSize:10];
        count.textColor = [UIColor colorWithWhite:0.40 alpha:1.0];
        count.textAlignment = NSTextAlignmentRight;
        [header addSubview:count];

        UIView *botSep = [[UIView alloc] initWithFrame:CGRectMake(8, 27.5, cv.bounds.size.width - 16, 0.5)];
        botSep.backgroundColor = sepColor;
        [header addSubview:botSep];
    }

    return header;
}

// ── Taille variable par emote ─────────────────────────────────────────────
//
// Hauteur de référence = screenWidth / 6  (→ environ 6 carrés par ligne).
// Largeur = hauteur × ratio de l'emote   (si ratio > 1 → plus large).
// La cellule épouse le ratio naturel de l'emote, exactement comme sur 7TV PC.
//
// Contraintes :
//   • largeur min : cellH * 0.25   (évite les emotes ultra-étroites)
//   • largeur max : cv.bounds.width (pas de débordement)
//   • hauteur min : 32 pt

// Nombre de colonnes de référence — plus élevé en paysage pour des cellules plus petites.
// Portrait  : 6 cols → cellules ~65pt (iPhone 390pt wide)
// Paysage   : 10 cols → cellules ~84pt (iPhone 844pt wide) — taille réduite voulue
static CGFloat S7TVRefCols(void) {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    return screen.width > screen.height ? 10.0 : 6.0;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    CGFloat cvW   = cv.bounds.size.width > 0 ? cv.bounds.size.width : 390.0;
    CGFloat cellH = MAX(32.0, floor(cvW / S7TVRefCols()));

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote || emote.width <= 0 || emote.height <= 0) {
        // Pas de dimensions connues → carré
        return CGSizeMake(cellH, cellH);
    }

    CGFloat ratio = (CGFloat)emote.width / (CGFloat)emote.height;
    CGFloat cellW = cellH * ratio;

    // Contraintes
    cellW = MAX(cellH * 0.25, cellW);   // min 25% de la hauteur
    cellW = MIN(cvW, cellW);            // max = pleine largeur
    cellW = ceil(cellW);
    cellH = ceil(cellH);

    return CGSizeMake(cellW, cellH);
}

// ── Hauteur des headers (0 si inutile) ────────────────────────────────────

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
referenceSizeForHeaderInSection:(NSInteger)section {
    CGSize headerSize = CGSizeMake(cv.bounds.size.width, 28);
    if (section == 0) {
        return self.emotePickerFavoriteEmotes.count > 0 ? headerSize : CGSizeZero;
    }
    if (section == 1) {
        return self.emotePickerChannelEmotes.count > 0 ? headerSize : CGSizeZero;
    }
    // Section 2 (globales) — header visible si au moins une emote globale
    return self.emotePickerGlobalEmotes.count > 0 ? headerSize : CGSizeZero;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    S7TVEmotePickerCell *cell = (S7TVEmotePickerCell *)
        [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID forIndexPath:indexPath];

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Étoile favoris (section 0 uniquement) — la vue existe déjà sur la
    // cellule (créée une fois dans S7TVEmotePickerCell), on ne fait que
    // l'afficher/masquer ici.
    cell.favoriteStarView.hidden = (indexPath.section != 0);

    // Bug historique conservé corrigé : le réglage s'applique à tout le
    // picker, pas seulement aux favoris — sauf si la nouvelle sous-option
    // "Animations uniquement pour les favoris" est active, auquel cas seule
    // la section 0 (Favoris) anime, le reste reste statique.
    BOOL wantsAnimated = emote.isAnimated && self.showPickerAnimations &&
        (!self.showPickerAnimationsFavoritesOnly || indexPath.section == 0);

    S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
    NSString *key = resolved.imageURL.absoluteString;
    cell.currentEmoteKey = key;

    if (wantsAnimated) {
        [self _s7tv_configureAnimatedPickerCell:cell resolvedEmote:resolved key:key];
    } else {
        [self _s7tv_configureStaticPickerCell:cell resolvedEmote:resolved key:key];
    }

    return cell;
}

// ── Chemin statique : sert l'image depuis SevenTVEmoteImageCache ──────────
//
// Cache hit (déjà décodée — par le picker OU par le chat custom, le cache
// est partagé) → affichage synchrone immédiat, ZÉRO réseau, ZÉRO décodage.
// C'est le principal gain de perf au scroll : avant, chaque réapparition de
// cellule relançait un fetch + un décodage complet même pour une emote déjà
// vue quelques cellules plus haut.
- (void)_s7tv_configureStaticPickerCell:(S7TVEmotePickerCell *)cell
                           resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                     key:(NSString *)key {
    SevenTVEmoteImageCache *cache = [SevenTVEmoteImageCache sharedCache];

    UIImage *cachedImg = [cache cachedImageForResolvedEmote:resolved];
    if (cachedImg) {
        cell.emoteImageView.image = cachedImg;
        return;
    }

    cell.emoteImageView.image = nil;
    [cache imageForResolvedEmote:resolved completion:^(UIImage * _Nullable image) {
        if (!image) return;
        // La cellule peut avoir été recyclée pour une autre emote pendant le
        // chargement async — on vérifie la clé avant d'appliquer l'image.
        if ([cell.currentEmoteKey isEqualToString:key]) {
            cell.emoteImageView.image = image;
        }
    }];
}

// ── Chemin animé : frames servies par le cache, lecture pilotée par
// SevenTVEmoteAnimationEngine (même CADisplayLink centralisé que le chat
// custom, déjà throttlé à maxSimultaneousAnimations) au lieu que chaque
// cellule fasse tourner sa propre boucle d'animation UIImage indépendante.
- (void)_s7tv_configureAnimatedPickerCell:(S7TVEmotePickerCell *)cell
                             resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                       key:(NSString *)key {
    SevenTVEmoteImageCache *cache   = [SevenTVEmoteImageCache sharedCache];
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];

    __weak S7TVEmotePickerCell *weakCell = cell;
    void (^redraw)(void) = ^{
        __strong S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongCell || ![strongCell.currentEmoteKey isEqualToString:key]) return;
        UIImage *frame = [engine currentFrameForKey:key];
        if (frame) strongCell.emoteImageView.image = frame;
    };

    // Frames déjà enregistrées auprès de l'engine (emote déjà vue animée,
    // picker ou chat) → il ne reste qu'à s'abonner, pas de décodage à refaire.
    if ([engine hasFramesForKey:key]) {
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw(); // pose la frame courante immédiatement, sans attendre le prochain tick
        return;
    }

    // Frames décodées et en cache (ex: vues dans le chat) mais pas encore
    // enregistrées auprès de l'engine → enregistrement direct, toujours pas
    // de redécodage.
    S7TVEmoteAnimatedFrames *cachedFrames = [cache cachedFramesForResolvedEmote:resolved];
    if (cachedFrames) {
        [engine registerFrames:cachedFrames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
        return;
    }

    // Rien en cache : afficher au moins la frame statique déjà connue (si
    // elle existe) pendant que les frames animées se décodent en arrière-plan,
    // plutôt qu'une cellule vide.
    UIImage *staticCached = [cache cachedImageForResolvedEmote:resolved];
    if (staticCached) cell.emoteImageView.image = staticCached;

    [cache framesForResolvedEmote:resolved completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
        if (!frames) return;
        if (![cell.currentEmoteKey isEqualToString:key]) return; // cellule recyclée entre-temps
        [engine registerFrames:frames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
    }];
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // ── Étape 1: trouver la ChatInputView ────────────────────────────────────
    // On cherche d'abord dans la référence stockée, puis dans toute la fenêtre.
    UIView *inputRoot = self.emotePickerTextField;

    if (!inputRoot) {
        [self log:@"⚠️ didSelect: emotePickerTextField nil → BFS fenêtre"];
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

    // ── Étape 2: utiliser directement emotePickerTextEntryView ────────────
    // C’est lui qui est firstResponder (inputAccessoryView) — insertText: fonctionnera.
    // On garde le BFS en fallback si emotePickerTextEntryView est nil.
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

    [self log:@"🔍 didSelect — textView:%@ textField:%@ keyInput:%@",
     textView  ? NSStringFromClass([textView  class]) : @"nil",
     textField ? NSStringFromClass([textField class]) : @"nil",
     keyInput  ? NSStringFromClass([(UIView *)keyInput class]) : @"nil"];

    // ── Étape 3: construire le texte à insérer ────────────────────────────────
    NSString *currentText = @"";
    if (textView)       currentText = textView.text  ?: @"";
    else if (textField) currentText = textField.text ?: @"";

    NSString *prefix  = (currentText.length > 0 && ![currentText hasSuffix:@" "]) ? @" " : @"";
    NSString *toAppend = [NSString stringWithFormat:@"%@%@ ", prefix, emote.emoteName];

    // ── Étape 4: insertion ─────────────────────────────────────────────────
    // insertText: seul ne suffit pas : le UITextView de Twitch est un
    // composant SwiftUI bridgé. UITextInput/insertText: modifie le buffer
    // interne de UITextView mais ne déclenche PAS le @Binding SwiftUI ni
    // textViewDidChange: du côté natif de Twitch.
    //
    // Solution : simuler une saisie clavier complète —
    //   1. Copier le texte voulu dans le presse-papier
    //   2. Appeler paste: sur le firstResponder
    // paste: passe par UITextInput.insertText: ET déclenche le
    // UITextViewTextDidChangeNotification + le delegate textViewDidChange:
    // que Twitch observe → le binding SwiftUI est mis à jour.
    //
    // Effet de bord UIPasteboard : le contenu du presse-papier est temporairement
    // remplacé. On restaure l'ancien contenu juste après via dispatch_async.
    BOOL inserted = NO;

    if (textView) {
        // Aller à la fin
        textView.selectedRange = NSMakeRange(textView.text.length, 0);

        // Sauvegarder et remplacer le presse-papier
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSString *savedString = pb.string;
        pb.string = toAppend;

        // paste: déclenche le pipeline UITextInput complet + notifie SwiftUI
        if ([textView respondsToSelector:@selector(paste:)]) {
            [textView paste:nil];
            inserted = YES;
            [self log:@"✅ paste: emote → «%@»", emote.emoteName];
        } else {
            // Ultime fallback
            [textView insertText:toAppend];
            inserted = YES;
            [self log:@"⚠️ paste: non dispo → insertText: fallback"];
        }

        // Restaurer le presse-papier après l'animation de paste
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            pb.string = savedString ?: @"";
        });

        // Forcer la notification UITextViewTextDidChangeNotification
        // au cas où paste: ne l'aurait pas déclenchée (bridge SwiftUI parfois silencieux)
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UITextViewTextDidChangeNotification
                              object:textView];
            // Déclencher aussi le delegate si Twitch l'a assigné
            if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [textView.delegate textViewDidChange:textView];
            }
        });
    } else if (textField) {
        [textField becomeFirstResponder];
        [(id<UIKeyInput>)textField insertText:toAppend];
        [self log:@"✅ insertText: UITextField → «%@»", toAppend];
        inserted = YES;
    } else if (keyInput) {
        [(UIView *)keyInput becomeFirstResponder];
        [(id<UIKeyInput>)keyInput insertText:toAppend];
        [self log:@"✅ insertText: UIKeyInput → «%@»", toAppend];
        inserted = YES;
    }

    if (!inserted) {
        [self log:@"❌ didSelect: aucun champ texte trouvé — emote=%@", emote.emoteName];
    }

        // Feedback haptique léger
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}


// ============================================================
// MARK: - Bouton de paramètres flottant
// ============================================================

- (void)addSettingsButton {
    dispatch_async(dispatch_get_main_queue(), ^{

        // ── Trouver la UIWindowScene ──────────────────────────────────────────
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }

        // ── Créer la fenêtre flottante ────────────────────────────────────────
        // Une UIWindow dédiée à windowLevel StatusBar+1 flotte au-dessus de
        // TOUTES les pages de Twitch (navigation, stream, chat, settings...).
        // Contrairement à un addSubview:keyWindow, elle n'est jamais couverte
        // par les transitions de navigation.
        SevenTVFloatingWindow *floatingWin;
        if (windowScene) {
            floatingWin = [[SevenTVFloatingWindow alloc] initWithWindowScene:windowScene];
        } else {
            floatingWin = [[SevenTVFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        floatingWin.windowLevel     = UIWindowLevelStatusBar + 1;
        floatingWin.backgroundColor = [UIColor clearColor];
        floatingWin.hidden          = NO;

        // rootViewController requis sous iOS 13+
        // CRITICAL : doit retourner UIInterfaceOrientationMaskAll
        // sinon iOS bloque la rotation dans TOUTE l'app car il consulte
        // supportedInterfaceOrientations sur TOUTES les fenêtres visibles.
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];

        // Créer une sous-classe dynamique qui autorise toutes les orientations
        static Class SevenTVFloatingRootVC = nil;
        static dispatch_once_t onceVC;
        dispatch_once(&onceVC, ^{
            SevenTVFloatingRootVC = objc_allocateClassPair([UIViewController class],
                                                           "SevenTVFloatingRootVC", 0);
            class_addMethod(SevenTVFloatingRootVC,
                @selector(supportedInterfaceOrientations),
                imp_implementationWithBlock(^UIInterfaceOrientationMask(id _){
                    return UIInterfaceOrientationMaskAll;
                }), "I@:");
            class_addMethod(SevenTVFloatingRootVC,
                @selector(shouldAutorotate),
                imp_implementationWithBlock(^BOOL(id _){ return YES; }),
                "B@:");
            objc_registerClassPair(SevenTVFloatingRootVC);
        });
        object_setClass(rootVC, SevenTVFloatingRootVC);

        floatingWin.rootViewController = rootVC;

        self.floatingWindow = floatingWin;

        // ── Créer le bouton ───────────────────────────────────────────────────
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat size = 44.0, margin = 16.0;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(screen.size.width  - size - margin,
                               screen.size.height - size - margin - 80.0,
                               size, size);
        btn.backgroundColor     = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:0.88];
        btn.layer.cornerRadius  = size / 2.0;
        btn.layer.shadowColor   = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset  = CGSizeMake(0, 2);
        btn.layer.shadowRadius  = 4;
        btn.layer.shadowOpacity = 0.4;
        [btn setTitle:@"7TV" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(settingsButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSettingsButtonDrag:)]];

        [rootVC.view addSubview:btn];
        self.settingsButton = btn;

        [self log:@"✅ Bouton 7TV dans UIWindow flottante (level %.0f)",
            (double)floatingWin.windowLevel];
    });
}

- (void)settingsButtonTapped:(UIButton *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        // ── Créer une UIWindow dédiée au menu ────────────────────────────────
        // On présente depuis NOTRE fenêtre (pas Twitch) → le containerView du
        // UIPresentationController est 100% sous notre contrôle → taille fixe
        // respectée en portrait ET en paysage, quelle que soit la config Twitch.
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }

        UIWindow *menuWin = scene
            ? [[UIWindow alloc] initWithWindowScene:scene]
            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        menuWin.windowLevel     = UIWindowLevelStatusBar + 2; // au-dessus du bouton flottant
        menuWin.backgroundColor = [UIColor clearColor];

        // rootVC transparent — sert uniquement de présentateur
        // Même fix : supporter toutes les orientations
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        object_setClass(rootVC, NSClassFromString(@"SevenTVFloatingRootVC"));
        menuWin.rootViewController = rootVC;
        menuWin.hidden = NO;
        self.menuWindow = menuWin; // retenu fortement jusqu'à la fermeture

        SevenTVSettingsController *vc = [[SevenTVSettingsController alloc] init];
        vc.openedAsModal = YES;
        // S7TVSettingsNavController : UIModalPresentationCustom +
        // S7TVPresentationController → 360×520pt centré dans menuWin.
        S7TVSettingsNavController *nav = [[S7TVSettingsNavController alloc] initWithRootViewController:vc];

        __weak typeof(self) weakSelf = self;
        [rootVC presentViewController:nav animated:YES completion:nil];

        // Libérer la fenêtre quand le menu est fermé
        // On observe la disparition du nav via viewDidDisappear dans une catégorie légère.
        // Méthode simple : polling via le completion du dismiss depuis le bouton Close.
        // Le bouton Close appelle dismissViewControllerAnimated:completion: →
        // on swizzle pas, on utilise un bloc de notification.
        __block id observer = nil;
        observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"S7TVMenuDidDismiss"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            weakSelf.menuWindow.hidden = YES;
            weakSelf.menuWindow = nil;
            if (observer) {
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
                observer = nil;
            }
        }];
    });
}

- (void)handleSettingsButtonDrag:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view, *parent = btn.superview;
    if (!parent) return;
    CGPoint t = [gesture translationInView:parent];
    CGFloat hw = btn.bounds.size.width/2, hh = btn.bounds.size.height/2;
    btn.center = CGPointMake(
        MAX(hw, MIN(parent.bounds.size.width  - hw, btn.center.x + t.x)),
        MAX(hh, MIN(parent.bounds.size.height - hh, btn.center.y + t.y)));
    [gesture setTranslation:CGPointZero inView:parent];
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


// ============================================================
// MARK: - Classification automatique des logs par catégorie
// ============================================================
// Le message déjà formaté (après application des arguments) est analysé par
// simple recherche de sous-chaînes distinctives. L'ordre des tests fait foi :
// dès qu'une règle matche, la catégorie est retenue (pas de cumul).
//
// Erreurs/Avertissements est toujours testé en premier : un ❌/⚠️ dans un log
// IRC, picker, etc. tombe dans "Erreurs", pas dans sa catégorie d'origine —
// c'est volontaire (cf. discussion avec l'utilisateur).
static S7TVLogCategory s7tv_categoryForMessage(NSString *msg) {
    BOOL (^has)(NSString *) = ^BOOL(NSString *needle) {
        return [msg rangeOfString:needle].location != NSNotFound;
    };

    // 1. Erreurs / Avertissements — priorité absolue
    if (has(@"❌") || has(@"⚠️")) return S7TVLogCategoryError;

    // 2. Chat Custom (diagnostic Phase 0+ du chat maison — tag explicite,
    // avant le Dump générique pour ne pas y être noyé)
    if (has(@"[ChatCustom]")) return S7TVLogCategoryChatCustom;

    // 3. Dump (architecture/méthodes — très verbeux, à part)
    if (has(@"[DBG-DUMP]") || has(@"🩻")) return S7TVLogCategoryDump;

    // 4. Tap Logger
    if (has(@"👆") || has(@"FIRST_RESPONDER") || has(@"SCAN CHAT") ||
        has(@"FIN SCAN") || (has(@"HIT:") && has(@"frame=")) ||
        has(@"fin hiérarchie"))
        return S7TVLogCategoryTap;

    // 4. Orientation Lock
    if (has(@"Orientation") || has(@"orientation") || has(@"verrou") || has(@"Rotation"))
        return S7TVLogCategoryOrientation;

    // 5. CDN / Cache emotes (téléchargement + mise en cache WebP natif)
    if (has(@"WebP") || has(@"URLProtocol cache") || has(@"Réponse CDN") ||
        has(@"Préfetch") || has(@"Bilan :"))
        return S7TVLogCategoryImageConversion;

    // 6. Favoris
    if (has(@"Favori")) return S7TVLogCategoryFavorites;

    // 7. IRC / Channel
    if (has(@"ROOMSTATE") || has(@"room-id") || has(@"broadcaster ID") ||
        has(@"GQL") || has(@"Mapping sauvé") || has(@"Rejoint le channel") ||
        has(@"Channel rejoint") || has(@"twitchID en cache") || has(@"twitchID") ||
        has(@"Pas de twitchID"))
        return S7TVLogCategoryIRCChannel;

    // 8. Prefetch
    if (has(@"Prefetch") || has(@"Préfetch") || has(@"Fetch déjà en cours"))
        return S7TVLogCategoryPrefetch;

    // 11. Cache / Réseau
    if (has(@"cache hit") || has(@"cache miss") || has(@"Prewarm") ||
        has(@"Préchauffage") || has(@"Écriture cache") || has(@"sérialiser le cache") ||
        has(@"URLProtocol"))
        return S7TVLogCategoryCache;

    // 12. API Emotes
    if (has(@"emotes globales") || has(@"emotes channel") || has(@"emotes du channel") ||
        has(@"Chargement emotes") || has(@"emote_set") || has(@"JSON invalide"))
        return S7TVLogCategoryAPI;

    // 13. UI / Picker
    if (has(@"TextEntryView") || has(@"picker") || has(@"Picker") ||
        has(@"Bouton 7TV") || has(@"Bits") || has(@"insertText") ||
        has(@"paste:") || has(@"didSelect") || has(@"firstResponder") ||
        has(@"Settings ouvert"))
        return S7TVLogCategoryUIPicker;

    // 14. Swizzle / Boot
    if (has(@"swizzle") || has(@"Swizzle") || has(@"Hook ") || has(@"hooké") ||
        has(@"Chargement TwitchSevenTV") || has(@"SevenTVManager prêt") ||
        has(@"setup démarré") || has(@"NSURLSession") || has(@"WebSocketTask") ||
        has(@"sharedSession"))
        return S7TVLogCategorySwizzle;

    // Par défaut : non classé → Dump (pour ne rien perdre silencieusement)
    return S7TVLogCategoryDump;
}

- (BOOL)s7tv_isCategoryEnabled:(S7TVLogCategory)cat {
    switch (cat) {
        case S7TVLogCategoryError:           return self.logErrors;
        case S7TVLogCategoryTap:             return self.logTap;
        case S7TVLogCategorySwizzle:         return self.logSwizzle;
        case S7TVLogCategoryCache:           return self.logCache;
        case S7TVLogCategoryPrefetch:        return self.logPrefetch;
        case S7TVLogCategoryAPI:             return self.logAPI;
        case S7TVLogCategoryIRCChannel:      return self.logIRCChannel;
        case S7TVLogCategoryUIPicker:        return self.logUIPicker;
        case S7TVLogCategoryFavorites:       return self.logFavorites;
        case S7TVLogCategoryOrientation:     return self.logOrientation;
        case S7TVLogCategoryImageConversion: return self.logImageConversion;
        case S7TVLogCategoryChatCustom:      return self.logChatCustom;
        case S7TVLogCategoryDump:            return self.logDump;
    }
    return NO;
}

// ============================================================
// MARK: - Logging
// ============================================================

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Interrupteur global : si OFF, rien n'est enregistré (buffer, disque, NSLog).
    if (!self.logsEnabled) return;

    // Classification + filtre par catégorie : si la catégorie est désactivée,
    // on ignore complètement la ligne (elle n'est même pas écrite sur disque).
    S7TVLogCategory cat = s7tv_categoryForMessage(msg);
    if (![self s7tv_isCategoryEnabled:cat]) return;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                      [fmt stringFromDate:[NSDate date]], msg];

    // ── Écriture persistante sur disque ──────────────────────────────────
    {
        NSString *lineWithNL = [line stringByAppendingString:@"\n"];
        NSData *data = [lineWithNL dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *path = [docs.firstObject stringByAppendingPathComponent:@"s7tv_logs.txt"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
            } else {
                [data writeToFile:path atomically:NO];
            }
        });
    }

    // Toujours écrire dans le buffer in-app (visible dans l'écran Logs 7TV)
    [self.logLock lock];
    [self.logBuffer addObject:line];
    if (self.logBuffer.count > S7TV_LOG_BUFFER_MAX) {
        [self.logBuffer removeObjectsInRange:
         NSMakeRange(0, self.logBuffer.count - S7TV_LOG_BUFFER_MAX)];
    }
    [self.logLock unlock];

    // NSLog console uniquement si debugLogging activé (mirroring Console.app)
    if (self.debugLogging) {
        NSLog(@"[TwitchSevenTV] %@", msg);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self userInfo:@{@"line": line}];
    });
}

- (NSArray<NSString *> *)allLogs {
    [self.logLock lock];
    NSArray *copy = [self.logBuffer copy];
    [self.logLock unlock];
    return copy;
}

- (void)clearLogs {
    [self.logLock lock];
    [self.logBuffer removeAllObjects];
    [self.logLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self userInfo:@{@"cleared": @YES}];
    });
}

@end
