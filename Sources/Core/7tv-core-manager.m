/*
 * 7tv-core-manager.m
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

#import "Core/7tv-core-manager.h"
#import "Chat/7tv-chat-message.h"
#import "Settings/7tv-settings-controller.h"
#import "Network/7tv-network-emote-cache.h"
#import "UI/7tv-ui-logo.h"
#import "Localization/7tv-localization-manager.h"
#import "Badge/7tv-badge-provider.h"
#import "Chat/7tv-chat-appearance-config.h"
#import "Emote/7tv-emote-image-cache.h"
#import "Emote/7tv-emote-animation-engine.h"
#import "Picker/7tv-picker-controller.h"
#import "Emote/7tv-emote-provider.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Chat/7tv-chat-reply-thread-panel.h"
#import "System/7tv-system-native-behavior-hooks.h"
#import <objc/runtime.h>

// ============================================================
// Constante de notification
// ============================================================
NSString *const S7TVLogsDidUpdateNotification = @"S7TVLogsDidUpdateNotification";
NSString *const S7TVEmoteCatalogDidUpdateNotification = @"S7TVEmoteCatalogDidUpdateNotification";
NSString *const S7TVChatCustomToggleDidChangeNotification = @"S7TVChatCustomToggleDidChangeNotification";
NSString *const S7TVFavoritesDidChangeNotification = @"S7TVFavoritesDidChangeNotification";
NSString *const S7TVTwitchCredentialsDidUpdateNotification = @"S7TVTwitchCredentialsDidUpdateNotification";

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
@interface SevenTVManager ()

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

// Picker d'emotes 7TV — composant séparé (voir 7tv-picker-controller.m),
// instancié paresseusement. Le manager ne garde que la façade publique
// (toggleEmotePickerForChatInputView:/cleanupPickerForStreamClose) + la
// donnée persistée (favoriteEmoteIDs ci-dessous) : tout le reste de l'UI du
// picker (grille, onglets, panneau des tailles) vit dans le picker lui-même.
@property (nonatomic, strong) SevenTVEmotePickerController *pickerController;

// Favoris : IDs 7TV des emotes mise en favoris (persisté dans NSUserDefaults)
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteEmoteIDs;

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Token OAuth Twitch + Client-ID — interceptés depuis les requêtes GQL
// (voir 7tv-core-runtime-hooks.m s7tv_dataTaskWithRequest:) pour pouvoir appeler
// l'API Helix (badges, etc.) sans enregistrer une app développeur.
@property (nonatomic, copy) NSString *twitchToken;
@property (nonatomic, copy) NSString *twitchClientID;
// Valeurs partielles en attendant d'avoir les deux (voir capture méthodes ci-dessous)
@property (nonatomic, copy) NSString *pendingAuthHeader;
@property (nonatomic, copy) NSString *pendingClientIDHeader;
@property (nonatomic, weak) id pendingAuthContext;
@property (nonatomic, weak) id pendingClientIDContext;

// Dossier racine du cache JSON (créé à la demande)
@property (nonatomic, strong) NSString *cacheDirectory;

// Timer heartbeat CDN — envoie un HEAD toutes les 20s pour garder
// la connexion TCP/TLS keep-alive ouverte vers cdn.7tv.app.
@property (nonatomic, strong) NSTimer *cdnHeartbeatTimer;

// Guard de déduplication pour _prefetchAllEmotes:setKey:label: (Fix L v1.7)
// Clé = twitchUserID pour les channels, "global" pour les globales.
// Protégé par @synchronized(self).
@property (nonatomic, strong) NSMutableSet<NSString *> *activePrefetchKeys;
// Après un vidage manuel, les images restent chargées à la demande jusqu'au
// prochain vrai changement de chaîne.
@property (nonatomic, assign) BOOL suppressBulkPrefetchAfterManualClear;

- (void)s7tv_notifyFavoritesChanged;
- (void)s7tv_clearChannelEmotesAndNotify;

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
        _showPickerAnimations  = YES;  // Activé par défaut
        _showPickerAnimationsFavoritesOnly = NO;
        _chatCustomTestEnabled = YES;  // Activé par défaut — c'est le mode de rendu du chat désormais
        _debugLogging          = (S7TV_DEBUG == 1);

        // Système de logs par catégorie — valeurs par défaut avant chargement
        // des préférences sauvegardées (voir loadPreferences ci-dessous).
        _logsEnabled       = YES;
        _logErrors         = YES;   // Erreurs/Avertissements visibles par défaut
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
        _logChannelPoints  = NO;    // OFF par défaut
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
        // Les ivars d'état du picker (onglets, sous-choix, arrays filtrées...)
        // sont initialisées dans SevenTVEmotePickerController, créé
        // paresseusement — voir -pickerController.

        [self loadPreferences];
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
    else _showFloatingButton = NO; // désactivé par défaut
    if ([prefs objectForKey:@"s7tv_chat_custom_test"]  != nil) _chatCustomTestEnabled  = [prefs boolForKey:@"s7tv_chat_custom_test"];

    // --- Logs : interrupteur global + catégories ---
    if ([prefs objectForKey:@"s7tv_logs_enabled"]      != nil) _logsEnabled           = [prefs boolForKey:@"s7tv_logs_enabled"];
    if ([prefs objectForKey:@"s7tv_log_errors"]        != nil) _logErrors             = [prefs boolForKey:@"s7tv_log_errors"];
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
    if ([prefs objectForKey:@"s7tv_log_channel_points"] != nil) _logChannelPoints     = [prefs boolForKey:@"s7tv_log_channel_points"];
    if ([prefs objectForKey:@"s7tv_log_dump"]          != nil) _logDump               = [prefs boolForKey:@"s7tv_log_dump"];

    // Charger les favoris (array d'IDs 7TV)
    NSArray *savedFavs = [prefs arrayForKey:@"s7tv_favorites"];
    if (savedFavs) {
        _favoriteEmoteIDs = [NSMutableSet setWithArray:savedFavs];
    }
}

- (void)reloadPreferencesFromDefaults {
    // Ne pas passer par les setters : chacun appelle -savePreferences et
    // écraserait une partie des valeurs venant juste d'être importées.
    [self loadPreferences];

    dispatch_async(dispatch_get_main_queue(), ^{
        // Ces deux réglages ont aussi un effet visuel immédiat dans une
        // session Twitch déjà ouverte.
        self.floatingWindow.hidden = !self.showFloatingButton;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVChatCustomToggleDidChangeNotification object:self];
    });
    [self s7tv_notifyFavoritesChanged];
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
    [prefs setBool:self.logChannelPoints     forKey:@"s7tv_log_channel_points"];
    [prefs setBool:self.logDump              forKey:@"s7tv_log_dump"];
    [prefs synchronize];
}

- (void)_saveFavorites {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:[self favoriteEmoteIDsSnapshot] forKey:@"s7tv_favorites"];
    [prefs synchronize];
}

// --- Favoris : API publique (voir 7tv-core-manager.h) ---
// La donnée (favoriteEmoteIDs) et sa persistance restent ici ; seule l'UI qui
// l'affiche/la modifie (grille du picker, long-press) vit dans
// SevenTVEmotePickerController.
- (BOOL)isEmoteFavorited:(NSString *)emoteID {
    if (!emoteID) return NO;
    @synchronized (self.favoriteEmoteIDs) {
        return [self.favoriteEmoteIDs containsObject:emoteID];
    }
}

- (void)setEmote:(NSString *)emoteID favorited:(BOOL)favorited {
    if (!emoteID.length) return;
    @synchronized (self.favoriteEmoteIDs) {
        if (favorited) {
            [self.favoriteEmoteIDs addObject:emoteID];
        } else {
            [self.favoriteEmoteIDs removeObject:emoteID];
        }
    }
    [self _saveFavorites];
    [self s7tv_notifyFavoritesChanged];
}

- (NSArray<NSString *> *)favoriteEmoteIDsSnapshot {
    @synchronized (self.favoriteEmoteIDs) {
        return self.favoriteEmoteIDs.allObjects;
    }
}

- (void)replaceFavoriteEmoteIDs:(NSArray<NSString *> *)emoteIDs {
    NSMutableSet<NSString *> *validIDs = [NSMutableSet set];
    for (id value in emoteIDs) {
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            [validIDs addObject:value];
        }
    }
    @synchronized (self.favoriteEmoteIDs) {
        [self.favoriteEmoteIDs setSet:validIDs];
    }
    [self _saveFavorites];
    [self s7tv_notifyFavoritesChanged];
}

- (void)s7tv_notifyFavoritesChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pickerController) [self->_pickerController favoritesDidChange];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVFavoritesDidChangeNotification object:self];
    });
}

- (void)setIsEnabled:(BOOL)v              { _isEnabled            = v; [self savePreferences]; }
- (void)setCurrentChannelTwitchID:(NSString *)channelID {
    BOOL changed = !((_currentChannelTwitchID == channelID) ||
                     [_currentChannelTwitchID isEqualToString:channelID]);
    _currentChannelTwitchID = [channelID copy];
    if (changed) {
        s7tv_channelPointsDidChangeChannel();
    } else {
        s7tv_channelPointsMarkChannelReady();
    }
    if (changed && channelID.length) {
        s7tv_activateChannelPointMetadataForChannelID(channelID, ^{
            s7tv_reloadActiveChatCustomViewForConfiguration();
        });
    }
    if (changed) {
        @synchronized (self) {
            self.suppressBulkPrefetchAfterManualClear = NO;
        }
    }
}
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
    [self log:@"🏗 Test chat custom %@", v ? @"ACTIVÉ" : @"désactivé"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVChatCustomToggleDidChangeNotification
                          object:self];
    });
}
- (void)setDebugLogging:(BOOL)v {
    _debugLogging  = v;
    [self savePreferences];
    // "Logs console" est un simple miroir NSLog, indépendant des catégories.
}

// --- Logs : interrupteur global ---
- (void)setLogsEnabled:(BOOL)v {
    _logsEnabled = v;
    [self savePreferences];
}

// --- Logs : catégories ---
- (void)setLogErrors:(BOOL)v         { _logErrors = v;         [self savePreferences]; }
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
- (void)setLogChannelPoints:(BOOL)v   { _logChannelPoints = v;   [self savePreferences]; }
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
        // Invalider le cache de tri du picker (variable interne à
        // SevenTVEmotePickerController désormais — on ne le crée pas juste
        // pour ça s'il n'existe pas encore, son cache serait déjà vide).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_pickerController) [self->_pickerController invalidateSortCache];
        });

        [self saveCacheForName:@"global" withEmotes:parsed];
        [self _prefetchAllEmotes:parsed setKey:@"global" label:@"globales (API)"];

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// ============================================================

- (void)s7tv_clearChannelEmotesAndNotify {
    dispatch_barrier_async(self.emoteQueue, ^{
        if (self.channelEmotes.count == 0) return;
        self.channelEmotes = @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];
        });
    });
}

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName.length) return;
    BOOL shouldResetChannelCatalog = !self.currentChannelName.length ||
        [self.currentChannelName caseInsensitiveCompare:channelName] != NSOrderedSame;
    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];
    if (shouldResetChannelCatalog) {
        s7tv_channelPointsWillChangeChannel();
    }
    self.currentChannelName = channelName;
    if (shouldResetChannelCatalog) [self s7tv_clearChannelEmotesAndNotify];

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
        // Même raisonnement pour les badges channel — voir
        // SevenTVBadgeProvider.resetChannelBadges.
        [[SevenTVBadgeProvider sharedProvider] resetChannelBadges];
        self.currentChannelTwitchID = cachedTwitchID;
        [self loadEmotesForChannelTwitchID:cachedTwitchID];
        // Fix bug badges channel manquants : sans cet appel, le catalogue
        // channel de SevenTVBadgeProvider ne se charge JAMAIS pour une
        // chaîne déjà visitée. Raison : le ROOMSTATE qui arrive juste après
        // trouvera roomID == currentChannelTwitchID (déjà fixé juste
        // au-dessus) et ne postera donc PAS S7TVChannelJoined (voir
        // -handleIRCRoomState: plus bas) — seul déclencheur dont
        // dépendait jusqu'ici le chargement des badges channel. Contrairement
        // au mapping channelID (persisté en NSUserDefaults), channelBadges
        // est tenu uniquement en mémoire (voir 7tv-badge-provider.h) : il
        // repart donc vide à chaque lancement du process, et sans cet appel
        // symétrique à celui des emotes, restait vide toute la session pour
        // toute chaîne déjà connue (c.-à-d. quasiment toujours, sauf la
        // toute première visite jamais faite d'une chaîne). loadBadgesForChannelID:
        // gère déjà ses propres garde-fous (token pas encore là, déjà
        // chargé) donc cet appel est sûr même en redondance avec un futur
        // ROOMSTATE.
        [[SevenTVBadgeProvider sharedProvider] loadBadgesForChannelID:cachedTwitchID];
        // Pas de dispatch_after nécessaire : le ROOMSTATE confirmera (ou corrigera)
        // l'ID quelques ms plus tard via s7tv_handleRoomState.
        return;
    }

    // Première visite : pas de mapping → attendre le ROOMSTATE.
    // Timeout de sécurité à 5s au cas où le ROOMSTATE n'arriverait pas.
    [self log:@"⏳ Pas de twitchID en cache pour %@, attente ROOMSTATE...", channelName];
    NSString *fallbackChannelName = [channelName copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!self.currentChannelName.length ||
            [self.currentChannelName caseInsensitiveCompare:fallbackChannelName] != NSOrderedSame) return;
        NSString *currentChannelID = [self.currentChannelTwitchID copy];
        if (currentChannelID.length) [self loadEmotesForChannelTwitchID:currentChannelID];
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

    @synchronized(self) {
        if (self.suppressBulkPrefetchAfterManualClear) {
            [self log:@"⏭️ Préfetch massif ignoré après vidage manuel (%@)", label];
            return;
        }
    }

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
        __block BOOL abortedForChannelSwitch = NO;
        NSLock *lock = [[NSLock alloc] init];
        BOOL channelScopedPrefetch = ![setKey isEqualToString:@"global"];

        for (SevenTVEmote *emote in allEmotes) {
            if (channelScopedPrefetch) {
                NSString *currentChannelID = self.currentChannelTwitchID;
                if (currentChannelID.length &&
                    ![currentChannelID isEqualToString:setKey]) {
                    abortedForChannelSwitch = YES;
                    break;
                }
            }
            // Skip si déjà en cache — zéro réseau
            if ([SevenTVURLProtocol isEmoteIDCached:emote.emoteID]) {
                [lock lock]; done++; skipped++; [lock unlock];
                continue;
            }

            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            // La chaîne peut changer pendant l'attente d'un slot. Rendre le
            // permis au sémaphore et ne plus planifier de requête pour l'ancien
            // catalogue; les quelques téléchargements déjà en vol se terminent.
            if (channelScopedPrefetch) {
                NSString *currentChannelID = self.currentChannelTwitchID;
                if (currentChannelID.length &&
                    ![currentChannelID isEqualToString:setKey]) {
                    dispatch_semaphore_signal(sem);
                    abortedForChannelSwitch = YES;
                    break;
                }
            }
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

        NSUInteger downloaded = done >= skipped ? done - skipped : 0;
        if (abortedForChannelSwitch) {
            [self log:@"⏹️ Prefetch %@ arrêté au changement de chaîne — %lu téléchargés, %lu déjà en cache",
             label, (unsigned long)downloaded, (unsigned long)skipped];
        } else {
            [self log:@"✅ Prefetch %@ terminé — %lu téléchargés, %lu déjà en cache",
             label, (unsigned long)downloaded, (unsigned long)skipped];
        }

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

    // Réserver atomiquement l'ID avant toute lecture du cache : deux appels
    // concurrents ne peuvent pas tous deux devenir propriétaires du fetch.
    @synchronized(self.fetchingChannelIDs) {
        if ([self.fetchingChannelIDs containsObject:twitchUserID]) {
            [self log:@"⏳ Fetch déjà en cours pour channel %@, ignoré", twitchUserID];
            return;
        }
        [self.fetchingChannelIDs addObject:twitchUserID];
    }

    NSString *cacheName = [NSString stringWithFormat:@"ch_%@", twitchUserID];

    // ── Étape 1: lire le cache immédiatement ──────────────────
    NSTimeInterval cacheAge = -1;
    NSDictionary *cached = [self loadCacheForName:cacheName age:&cacheAge];

    if (cached.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            if (self.currentChannelTwitchID.length &&
                ![self.currentChannelTwitchID isEqualToString:twitchUserID]) return;
            self.channelEmotes = cached;
            [self log:@"⚡️ %lu emotes channel depuis cache (âge: %.0fs)",
             (unsigned long)cached.count, cacheAge];
            [self _prefetchAllEmotes:cached
                              setKey:twitchUserID
                               label:@"channel (cache)"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_pickerController) [self->_pickerController invalidateSortCache];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];
            });
        });
    }

    // ── Étape 2: décider si un refresh réseau est nécessaire ──
    BOOL cacheIsFresh = (cached.count > 0 && cacheAge >= 0 && cacheAge < kCacheTTLChannel);

    if (cacheIsFresh) {
        [self log:@"✅ Cache channel frais (%.0fs < %.0fs), pas de refresh",
         cacheAge, kCacheTTLChannel];
        @synchronized(self.fetchingChannelIDs) {
            [self.fetchingChannelIDs removeObject:twitchUserID];
        }
        return;
    }

    // ── Étape 3: requête API en arrière-plan ──────────────────
    if (cacheAge > 0) {
        [self log:@"🔄 Cache channel périmé (%.0fs) → refresh API", cacheAge];
    } else {
        [self log:@"🌐 Pas de cache pour channel %@ → fetch API", twitchUserID];
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/users/twitch/%@", S7TV_API_BASE, twitchUserID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        @synchronized(self.fetchingChannelIDs) {
            [self.fetchingChannelIDs removeObject:twitchUserID];
        }
        return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSURLSessionDataTask *task = [session dataTaskWithURL:url
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
            if (self.currentChannelTwitchID.length &&
                ![self.currentChannelTwitchID isEqualToString:twitchUserID]) {
                [self log:@"ℹ️ Réponse emotes ignorée pour ancienne chaîne %@", twitchUserID];
                return;
            }
            self.channelEmotes = parsed;
            [self log:@"✅ %lu emotes du channel chargées depuis API", (unsigned long)parsed.count];
            [self _prefetchAllEmotes:parsed
                              setKey:twitchUserID
                               label:@"channel (API)"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_pickerController) [self->_pickerController invalidateSortCache];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];
            });
        });

        [self saveCacheForName:cacheName withEmotes:parsed];

    }];
    if (!task) {
        @synchronized(self.fetchingChannelIDs) {
            [self.fetchingChannelIDs removeObject:twitchUserID];
        }
        return;
    }
    [task resume];
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

// N'accepte que les deux schémas réellement utilisés par Twitch. L'adblock
// ajoute parfois un `Authorization: Basic ...` pour authentifier son proxy :
// cette valeur ne doit surtout jamais remplacer le token OAuth Twitch utilisé
// par Helix (badges, avatars, etc.).
static NSString *S7TVNormalizedTwitchBearerToken(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;

    NSRange separator = [trimmed rangeOfCharacterFromSet:
        NSCharacterSet.whitespaceCharacterSet];
    // Certaines versions de Twitch transmettent uniquement la valeur brute
    // dans Authorization. Elle est sûre ici car la capture finale est limitée
    // aux requêtes gql.twitch.tv. Les schémas tiers restent rejetés ci-dessous.
    if (separator.location == NSNotFound) {
        return [@"Bearer " stringByAppendingString:trimmed];
    }
    NSString *scheme = [trimmed substringToIndex:separator.location];
    if ([scheme caseInsensitiveCompare:@"OAuth"] != NSOrderedSame &&
        [scheme caseInsensitiveCompare:@"Bearer"] != NSOrderedSame) return nil;

    NSString *credential = [[trimmed substringFromIndex:separator.location + 1]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!credential.length) return nil;
    return [@"Bearer " stringByAppendingString:credential];
}

- (void)s7tv_captureAuthorizationHeader:(NSString *)value context:(id)context {
    NSString *normalized = S7TVNormalizedTwitchBearerToken(value);
    if (!normalized.length || !context) return;

    NSString *tokenToSave = nil;
    NSString *clientIDToSave = nil;
    @synchronized (self) {
        if (self.pendingClientIDHeader.length && self.pendingClientIDContext != context) {
            self.pendingClientIDHeader = nil;
            self.pendingClientIDContext = nil;
        }
        self.pendingAuthHeader = value;
        self.pendingAuthContext = context;
        if (self.pendingAuthHeader.length && self.pendingClientIDHeader.length &&
            self.pendingAuthContext == self.pendingClientIDContext) {
            tokenToSave = [self.pendingAuthHeader copy];
            clientIDToSave = [self.pendingClientIDHeader copy];
            self.pendingAuthHeader = nil;
            self.pendingClientIDHeader = nil;
            self.pendingAuthContext = nil;
            self.pendingClientIDContext = nil;
        }
    }
    if (tokenToSave.length && clientIDToSave.length) {
        [self saveTwitchToken:tokenToSave clientID:clientIDToSave];
    }
}

- (void)s7tv_captureClientIDHeader:(NSString *)value context:(id)context {
    if (!value.length || !context) return;

    NSString *tokenToSave = nil;
    NSString *clientIDToSave = nil;
    @synchronized (self) {
        if (self.pendingAuthHeader.length && self.pendingAuthContext != context) {
            self.pendingAuthHeader = nil;
            self.pendingAuthContext = nil;
        }
        self.pendingClientIDHeader = value;
        self.pendingClientIDContext = context;
        if (self.pendingAuthHeader.length && self.pendingClientIDHeader.length &&
            self.pendingAuthContext == self.pendingClientIDContext) {
            tokenToSave = [self.pendingAuthHeader copy];
            clientIDToSave = [self.pendingClientIDHeader copy];
            self.pendingAuthHeader = nil;
            self.pendingClientIDHeader = nil;
            self.pendingAuthContext = nil;
            self.pendingClientIDContext = nil;
        }
    }
    if (tokenToSave.length && clientIDToSave.length) {
        [self saveTwitchToken:tokenToSave clientID:clientIDToSave];
    }
}

- (NSDictionary<NSString *, NSString *> *)s7tv_twitchCredentialsSnapshot {
    @synchronized (self) {
        if (!self.twitchToken.length || !self.twitchClientID.length) return @{};
        return @{
            @"Authorization": self.twitchToken,
            @"Client-ID": self.twitchClientID
        };
    }
}

- (void)saveTwitchToken:(NSString *)token clientID:(NSString *)clientID {
    if (!token.length || !clientID.length) return;

    // Twitch pose généralement "OAuth" sur GQL ; Helix exige "Bearer".
    // Le normaliseur rejette également les credentials Basic du proxy vidéo.
    NSString *normalizedToken = S7TVNormalizedTwitchBearerToken(token);
    if (!normalizedToken.length) {
        [self log:@"⚠️ Credentials Twitch ignorés: schéma Authorization non OAuth/Bearer"];
        return;
    }
    BOOL credentialsChanged = NO;
    @synchronized (self) {
        // Une capture complète invalide toute valeur partielle précédente,
        // même si le couple est déjà celui actuellement stocké.
        self.pendingAuthHeader = nil;
        self.pendingClientIDHeader = nil;
        self.pendingAuthContext = nil;
        self.pendingClientIDContext = nil;
        credentialsChanged = !([normalizedToken isEqualToString:self.twitchToken] &&
                               [clientID isEqualToString:self.twitchClientID]);
        if (credentialsChanged) {
            self.twitchToken = normalizedToken;
            self.twitchClientID = clientID;
        }
    }
    if (!credentialsChanged) return;
    [self log:@"🏗 Badges: token normalisé OAuth→Bearer et sauvegardé"];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:S7TVTwitchCredentialsDidUpdateNotification object:self];
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

            // Ce hook voit toutes les réponses GQL de l'app. Une réponse
            // générique contient très souvent data.user = le compte du viewer
            // connecté, ce qui ne prouve absolument pas la chaîne affichée :
            // accepter ce login écraserait currentChannelName et ferait
            // rejeter tous les messages du chat ouvert (filtre PRIVMSG /
            // USERNOTICE → currentChannelName). Le JOIN IRC
            // (loadEmotesForChannelName:) est la source de vérité de la
            // chaîne affichée ; GQL ne peut ensuite que confirmer le même
            // login et fournir son broadcaster ID avant/avec le ROOMSTATE.
            if (!channelLogin.length || !self.currentChannelName.length ||
                [channelLogin caseInsensitiveCompare:self.currentChannelName] != NSOrderedSame) {
                [self log:@"ℹ️ Réponse GQL ignorée (login %@ ≠ chaîne jointe %@)",
                    channelLogin.length ? channelLogin : @"indéterminé",
                    self.currentChannelName.length ? self.currentChannelName : @"aucune"];
                continue;
            }

            if (channelLogin.length > 0) {
                self.currentChannelName = channelLogin;
                [self log:@"📡 Channel name extrait GQL: %@", channelLogin];
            }

            if (![broadcasterID isEqualToString:self.currentChannelTwitchID]) {
                [self log:@"📡 Nouveau broadcaster ID via GQL: %@ (ancien: %@)",
                 broadcasterID, self.currentChannelTwitchID ?: @"aucun"];

                NSString *oldID = self.currentChannelTwitchID;
                [self s7tv_clearChannelEmotesAndNotify];
                // Même raisonnement pour les badges channel — voir
                // SevenTVBadgeProvider.resetChannelBadges.
                [[SevenTVBadgeProvider sharedProvider] resetChannelBadges];
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
    NSInteger resolution = [SevenTVChatAppearanceConfig sharedConfig].emote7TVResolution;
    resolution = MIN(4, MAX(1, resolution));
    return [NSURL URLWithString:
            [NSString stringWithFormat:@"%@/%@/%ldx.webp",
             S7TV_CDN_BASE, emote.emoteID, (long)resolution]];
}


// ============================================================
// MARK: - Picker d'emotes 7TV (délégué à SevenTVEmotePickerController)
//
// Toute l'UI du picker (grille, onglets, recherche, panneau des tailles) vit
// désormais dans SevenTVEmotePickerController (+ SevenTVPickerSizesPanel en
// composant enfant) — voir ces fichiers. Le manager garde uniquement la
// donnée persistée (favoriteEmoteIDs, cf. plus haut) et cette façade, pour
// que 7tv-core-runtime-hooks.m n'ait rien à changer.
// ============================================================

- (SevenTVEmotePickerController *)pickerController {
    if (!_pickerController) {
        _pickerController = [[SevenTVEmotePickerController alloc] init];
    }
    return _pickerController;
}

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    [self.pickerController toggleEmotePickerForChatInputView:chatInputView];
}

- (void)cleanupPickerForStreamClose {
    [self.pickerController cleanupPickerForStreamClose];
}

- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView {
    [self.pickerController cleanupPickerForStreamCloseIfOwnedByChatInputView:chatInputView];
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
        // Respecter la préférence dès la création de la fenêtre. Sans cela,
        // le bouton apparaissait toujours au lancement, même si sa valeur par
        // défaut (ou la préférence enregistrée) était désactivée.
        floatingWin.hidden          = !self.showFloatingButton;

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
        [btn setTitle:L(@"label_7tv_badge") forState:UIControlStateNormal];
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
    [self presentSettingsMenu];
}

- (void)presentSettingsMenu {
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

    // 0. Diagnostic réseau TEMPORAIRE (dump picker natif Twitch) — priorité
    // ABSOLUE, vérifiée avant toute autre règle. Le contenu de ces lignes
    // inclut des données Twitch imprévisibles (noms d'opérations GQL, URLs)
    // qui pourraient sinon matcher n'importe quel mot-clé ci-dessous selon
    // ce que Twitch renvoie — un seul tag fixe garantit une catégorie stable
    // quel que soit le contenu. Retirer cette règle en même temps que le
    // reste du diagnostic (voir 7tv-core-runtime-hooks.m, S7TVGQLSnifferProtocol).
    if (has(@"[NetDump]")) return S7TVLogCategoryDump;

    // 1. Diagnostic temporaire des récompenses du chat custom. Priorité
    // absolue : le payload peut lui-même contenir "Channel Points", des
    // erreurs ou n'importe quel autre mot-clé de classification.
    if (has(@"[ChatCustom]")) return S7TVLogCategoryChatCustom;

    // 2. Channel Points (autoclaim) — priorité absolue, avant Erreurs :
    // tous les logs de l'autoclaim (succès 🎁 et échecs "Erreur ...") ont
    // leur propre catégorie dédiée, pas de dispersion en Erreurs/Dump.
    if (has(@"Channel Points")) return S7TVLogCategoryChannelPoints;

    // 3. Erreurs / Avertissements — priorité absolue
    if (has(@"❌") || has(@"⚠️")) return S7TVLogCategoryError;

    // 4. Dump (architecture/méthodes — très verbeux, à part)
    if (has(@"[DBG-DUMP]") || has(@"🩻")) return S7TVLogCategoryDump;

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
        case S7TVLogCategoryChannelPoints:   return self.logChannelPoints;
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


// ============================================================
// MARK: - Cache : vidage complet
// ============================================================

- (void)clearAllCaches {
    [self clearAllCachesWithCompletion:nil];
}

- (void)clearAllCachesWithCompletion:(void (^)(NSUInteger))completion {
    NSUInteger clearedEmoteCount = (NSUInteger)[SevenTVURLProtocol cachedEmoteCount];
    [self log:@"🗑️ Vidage complet du cache 7TV demandé (%lu emotes indexées)",
     (unsigned long)clearedEmoteCount];

    // Empêche tout téléchargement/décodage déjà en vol de repeupler les
    // caches après l'action utilisateur.
    [[SevenTVEmoteImageCache sharedCache] clearAllCaches];
    [[SevenTVEmoteAnimationEngine sharedEngine] clearAllCachedFrames];
    @synchronized (self) {
        [self.activePrefetchKeys removeAllObjects];
    }

    NSString *channelID = [self.currentChannelTwitchID copy];
    dispatch_group_t clearing = dispatch_group_create();
    @synchronized (self) {
        self.suppressBulkPrefetchAfterManualClear = YES;
    }

    dispatch_group_enter(clearing);
    void (^clearRawCache)(void) = ^{
        [SevenTVURLProtocol clearAllEmoteCachesWithCompletion:^(NSUInteger ignoredCount) {
            dispatch_group_leave(clearing);
        }];
    };
    if (self->_pickerController) {
        [self->_pickerController cancelPendingImageLoadsWithCompletion:clearRawCache];
    } else {
        clearRawCache();
    }

    // 1) Fichiers JSON du cache disque (Library/Caches/s7tv/*.json —
    // global.json, ch_<twitchID>.json...). Même file d'exécution que la
    // lecture/écriture du cache pour éviter toute course avec un
    // chargement en cours (voir _readCacheFile:/_writeCacheFile:withEmotes:).
    dispatch_group_async(clearing, self.fileIOQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *listErr = nil;
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:self.cacheDirectory error:&listErr];
        if (listErr) {
            [self log:@"⚠️ Impossible de lister le cache disque: %@", listErr.localizedDescription];
            return;
        }
        for (NSString *file in files) {
            NSError *rmErr = nil;
            NSString *path = [self.cacheDirectory stringByAppendingPathComponent:file];
            [fm removeItemAtPath:path error:&rmErr];
            if (rmErr) {
                [self log:@"⚠️ Suppression échouée pour %@: %@", file, rmErr.localizedDescription];
            }
        }
    });

    // 2) Dictionnaires d'emotes en mémoire — écriture protégée par
    // dispatch_barrier_async sur emoteQueue (même convention que le reste
    // du fichier, voir header de emoteQueue).
    dispatch_group_enter(clearing);
    dispatch_barrier_async(self.emoteQueue, ^{
        self.globalEmotes  = @{};
        self.channelEmotes = @{};
        dispatch_group_leave(clearing);
    });

    // 3) Ne relire les catalogues qu'une fois les fichiers réellement
    // supprimés. L'ancienne version lançait le reload immédiatement et
    // pouvait donc relire le JSON juste avant sa suppression.
    dispatch_group_notify(clearing, dispatch_get_main_queue(), ^{
        if (self->_pickerController) {
            [self->_pickerController invalidateSortCache];
            [self->_pickerController favoritesDidChange];
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVEmoteCatalogDidUpdateNotification object:self];

        [self loadGlobalEmotes];
        if (channelID.length) [self loadEmotesForChannelTwitchID:channelID];
        if (completion) completion(clearedEmoteCount);
    });
}

@end


// ============================================================
// MARK: - Session IRC (JOIN / ROOMSTATE / USERSTATE)
// ============================================================

// Passe à YES dès qu'un ROOMSTATE a confirmé le salon courant
// (currentChannelName) auprès du serveur. Sert à distinguer le JOIN
// technique du salon du viewer (Twitch joint #<login du compte connecté> à
// la connexion du chat, indépendamment de la chaîne affichée) d'un vrai
// changement de chaîne : tant que le salon courant n'est pas confirmé, ce
// JOIN technique ne doit pas pouvoir prendre la main.
static BOOL s7tv_currentChannelRoomStateConfirmed = NO;

@implementation SevenTVManager (IRCSessionState)

- (void)handleIRCUserState:(NSString *)ircLine {
    if (![ircLine hasPrefix:@"@"]) return;
    NSRange firstSpace = [ircLine rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return;
    NSDictionary<NSString *, NSString *> *tags = s7tv_parseIRCTags(
        [ircLine substringWithRange:NSMakeRange(1, firstSpace.location - 1)]);
    NSString *displayName = s7tv_tagValue(tags, @"display-name", @"");
    if (!displayName.length || [displayName isEqualToString:self.currentViewerDisplayName]) return;
    self.currentViewerDisplayName = displayName;
    [self log:@"👤 Pseudo viewer connecté détecté (USERSTATE): %@", displayName];
}

- (void)handleIRCRoomState:(NSString *)ircLine {
    NSRange roomStateCommand = [ircLine rangeOfString:@" ROOMSTATE #"];
    if (roomStateCommand.location != NSNotFound) {
        NSUInteger channelStart = NSMaxRange(roomStateCommand);
        NSRange tail = NSMakeRange(channelStart, ircLine.length - channelStart);
        NSRange channelEnd = [ircLine rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet options:0 range:tail];
        NSUInteger end = channelEnd.location == NSNotFound ? ircLine.length : channelEnd.location;
        NSString *roomChannel = [ircLine substringWithRange:
                                 NSMakeRange(channelStart, end - channelStart)];
        if (roomChannel.length && self.currentChannelName.length &&
            [roomChannel caseInsensitiveCompare:self.currentChannelName] != NSOrderedSame) {
            // Garde changement de chaîne : rejette le ROOMSTATE d'une autre
            // chaîne, SAUF si le salon courant n'est que le salon technique
            // du viewer (JOIN #<login du compte> pris avant que
            // GLOBALUSERSTATE ne soit traité) — le ROOMSTATE de la chaîne
            // réellement ouverte doit alors reprendre la main.
            if (!(self.currentViewerDisplayName.length &&
                  [self.currentChannelName caseInsensitiveCompare:self.currentViewerDisplayName] == NSOrderedSame)) {
                return;
            }
            self.currentChannelName = roomChannel;
            [self log:@"📡 Chaîne courante corrigée par ROOMSTATE: %@", roomChannel];
        }
        // Le serveur confirme le salon courant — voir
        // s7tv_currentChannelRoomStateConfirmed (JOIN technique du viewer).
        s7tv_currentChannelRoomStateConfirmed = YES;
    }

    NSRange roomIDRange = [ircLine rangeOfString:@"room-id="];
    if (roomIDRange.location == NSNotFound) return;
    NSString *afterRoomID = [ircLine substringFromIndex:NSMaxRange(roomIDRange)];
    NSMutableString *roomID = [NSMutableString string];
    for (NSUInteger index = 0; index < afterRoomID.length; index++) {
        unichar character = [afterRoomID characterAtIndex:index];
        if (character == ';' || character == ' ' || character == '\r' || character == '\n') break;
        [roomID appendFormat:@"%C", character];
    }
    if (!roomID.length) return;
    [self log:@"📡 room-id extrait depuis ROOMSTATE: %@", roomID];

    if (![roomID isEqualToString:self.currentChannelTwitchID]) {
        [self log:@"📡 Nouveau broadcaster ID (ROOMSTATE): %@ (ancien: %@)",
            roomID, self.currentChannelTwitchID ?: @"aucun"];
        [self s7tv_clearChannelEmotesAndNotify];
        self.currentChannelTwitchID = roomID;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[S7TVReplyThreadPanel sharedPanel] hide];
        });

        if (self.currentChannelName.length) {
            NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
            NSMutableDictionary *map = [([preferences dictionaryForKey:@"s7tv_channel_id_map"]
                                         ?: @{}) mutableCopy];
            map[self.currentChannelName.lowercaseString] = roomID;
            [preferences setObject:map.copy forKey:@"s7tv_channel_id_map"];
            [preferences synchronize];
            [self log:@"💾 Mapping sauvé: %@ → %@", self.currentChannelName, roomID];
        }
        [self loadEmotesForChannelTwitchID:roomID];
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"S7TVChannelJoined" object:nil
            userInfo:@{@"channelID": roomID}];
    }
    [self initializeRecentHistoryForChannel:self.currentChannelName force:NO];
}

- (BOOL)s7tv_handleIRCModerationEvent:(NSString *)ircLine {
    BOOL isClearMessage = [ircLine containsString:@" CLEARMSG "];
    BOOL isClearChat = [ircLine containsString:@" CLEARCHAT "];
    if (!isClearMessage && !isClearChat) return NO;

    NSDictionary<NSString *, NSString *> *tags = @{};
    NSString *rest = ircLine;
    if ([ircLine hasPrefix:@"@"]) {
        NSRange firstSpace = [ircLine rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            tags = s7tv_parseIRCTags([ircLine substringWithRange:
                                      NSMakeRange(1, firstSpace.location - 1)]);
            rest = [ircLine substringFromIndex:firstSpace.location + 1];
        }
    }

    NSString *command = isClearMessage ? @"CLEARMSG" : @"CLEARCHAT";
    NSRange commandRange = [rest rangeOfString:command];
    if (commandRange.location == NSNotFound) return YES;
    NSString *afterCommand = [[rest substringFromIndex:NSMaxRange(commandRange)]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!afterCommand.length) {
        [self log:@"⚠️ Modération %@ ignorée (channel absent)", command];
        return YES;
    }

    NSRange channelEnd = [afterCommand rangeOfCharacterFromSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *channelToken = channelEnd.location == NSNotFound
        ? afterCommand : [afterCommand substringToIndex:channelEnd.location];
    NSString *trailing = channelEnd.location == NSNotFound
        ? @"" : [afterCommand substringFromIndex:channelEnd.location + 1];
    trailing = [trailing stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trailing hasPrefix:@":"]) trailing = [trailing substringFromIndex:1];
    if ([channelToken hasPrefix:@"#"]) channelToken = [channelToken substringFromIndex:1];

    if (channelToken.length && self.currentChannelName.length &&
        [channelToken caseInsensitiveCompare:self.currentChannelName] != NSOrderedSame) {
        return YES;
    }

    S7TVChatMessageStore *store = self.chatMessageStore;
    if (isClearMessage) {
        NSString *targetMessageID = s7tv_tagValue(tags, @"target-msg-id", @"");
        if (!targetMessageID.length) {
            [self log:@"⚠️ CLEARMSG ignoré (target-msg-id absent)"];
            return YES;
        }
        [store markMessageDeletedByID:targetMessageID completion:^{
            [self log:@"🛡 CLEARMSG appliqué (message id=%@)", targetMessageID];
            s7tv_applyModerationStateToRetainedMessage(
                targetMessageID, S7TVChatMessageStateDeletedCollapsed,
                S7TVChatModerationKindMessageDeleted, 0);
            s7tv_reloadActiveChatMessage(targetMessageID);
        }];
        return YES;
    }

    NSString *targetUserID = s7tv_tagValue(tags, @"target-user-id", @"");
    if (targetUserID.length) {
        NSString *rawBanDuration = tags[@"ban-duration"];
        BOOL isTimeout = rawBanDuration != nil;
        NSInteger durationSeconds = isTimeout ? MAX(0, rawBanDuration.integerValue) : 0;
        S7TVChatModerationKind kind = isTimeout
            ? S7TVChatModerationKindTimeout : S7TVChatModerationKindPermanentBan;
        [store markAllMessagesDeletedForUserID:targetUserID
                                moderationKind:kind
                               durationSeconds:durationSeconds
                                     completion:^{
            s7tv_applyModerationToRetainedMessagesForUser(
                targetUserID, trailing, kind, durationSeconds);
            [self log:@"🛡 CLEARCHAT utilisateur appliqué (user-id=%@, login=%@, %@)",
                targetUserID, trailing.length ? trailing : @"inconnu",
                isTimeout ? [NSString stringWithFormat:@"timeout=%lds", (long)durationSeconds]
                          : @"ban permanent"];
            s7tv_reloadActiveChatCustomViewAnimated();
        }];
    } else if (trailing.length) {
        [self log:@"⚠️ CLEARCHAT ciblé ignoré (target-user-id absent, login=%@)",
            trailing];
    } else {
        [store markAllMessagesDeletedWithCompletion:^{
            s7tv_applyModerationToAllRetainedMessages();
            [self log:@"🛡 CLEARCHAT global appliqué"];
            s7tv_reloadActiveChatCustomViewAnimated();
        }];
    }
    return YES;
}

- (void)handleIncomingChatWebSocketText:(NSString *)text {
    if (!text.length) return;
    NSArray<id<S7TVEmoteProvider>> *providers = s7tv_chatEmoteProviders();
    BOOL addedMessage = NO;

    // Les notifications PubSub sont des enveloppes JSON, pas des lignes IRC.
    // Le store déduplique les abonnements Twitch grâce à redemption.id.
    for (S7TVChatMessage *rewardMessage in
         s7tv_channelPointMessagesFromWebSocketText(text, providers)) {
        [self.chatMessageStore addMessage:rewardMessage];
        addedMessage = YES;
    }

    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:
                               NSCharacterSet.newlineCharacterSet]) {
        NSString *ircLine = [rawLine stringByTrimmingCharactersInSet:
                             NSCharacterSet.newlineCharacterSet];
        if (!ircLine.length) continue;
        if ([ircLine containsString:@"ROOMSTATE"]) [self handleIRCRoomState:ircLine];
        // "USERSTATE" couvre aussi GLOBALUSERSTATE, qui se termine par ce mot.
        if ([ircLine containsString:@"USERSTATE"]) [self handleIRCUserState:ircLine];
        if ([self s7tv_handleIRCModerationEvent:ircLine]) continue;

        S7TVChatMessage *chatMessage = s7tv_parseChatMessage(ircLine, providers);
        if (!chatMessage) continue;
        if (chatMessage.channelPointRewardID.length) {
            // PubSub et IRC arrivent presque simultanément, parfois dans
            // l'ordre inverse. Seul le PRIVMSG de récompense attend 350 ms.
            S7TVChatMessage *pendingCompanion = chatMessage;
            S7TVChatMessageStore *rewardStore = self.chatMessageStore;
            NSUInteger storeGeneration = rewardStore.generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                           (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // Un JOIN intervenu entre-temps a reconstruit le store.
                if (rewardStore.generation != storeGeneration) return;
                if (s7tv_shouldSuppressChannelPointCompanion(pendingCompanion)) {
                    [rewardStore mergeChannelPointCompanionMessage:pendingCompanion
                        completion:^(NSString *mergedID) {
                        if (mergedID.length) {
                            s7tv_reloadActiveChatMessage(mergedID);
                        } else if (rewardStore.generation == storeGeneration) {
                            [rewardStore addMessage:pendingCompanion];
                            s7tv_scheduleChatCustomReload();
                        }
                    }];
                    return;
                }
                [rewardStore addMessage:pendingCompanion];
                s7tv_scheduleChatCustomReload();
            });
            continue;
        }
        [self.chatMessageStore addMessage:chatMessage];
        addedMessage = YES;
    }
    if (addedMessage) s7tv_scheduleChatCustomReload();
}

@end


// ============================================================
// MARK: - Historique récent au JOIN
// ============================================================

static NSUInteger s7tv_recentHistoryGeneration = 0;
static NSString *s7tv_recentHistoryInitializedChannel = nil;

static BOOL s7tv_recentHistoryRequestIsCurrent(NSString *channel,
                                                NSUInteger generation) {
    SevenTVManager *manager = [SevenTVManager sharedManager];
    @synchronized (manager) {
        return generation == s7tv_recentHistoryGeneration && channel.length &&
            [channel caseInsensitiveCompare:manager.currentChannelName ?: @""] == NSOrderedSame;
    }
}

static void s7tv_fetchRecentHistory(NSString *channel, NSUInteger generation) {
    if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
    NSString *urlString = [NSString stringWithFormat:
        @"https://recent-messages.robotty.de/api/v2/recent-messages/%@?limit=50&hideModerationMessages=true&hideModeratedMessages=true",
        channel.lowercaseString];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 8.0;
    [request setValue:@"TwitchPlusK/1.0" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 || !data.length) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ Historique récent indisponible pour %@ (%@, HTTP %ld)",
                channel, error.localizedDescription ?: @"réponse vide", (long)http.statusCode];
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:&jsonError];
        NSArray *rawMessages = [payload isKindOfClass:NSDictionary.class]
            ? payload[@"messages"] : nil;
        if (jsonError || ![rawMessages isKindOfClass:NSArray.class]) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ Historique récent invalide pour %@: %@",
                channel, jsonError.localizedDescription ?: @"champ messages absent"];
            return;
        }

        NSMutableArray<S7TVChatMessage *> *history =
            [NSMutableArray arrayWithCapacity:rawMessages.count];
        for (id value in rawMessages) {
            if (![value isKindOfClass:NSString.class]) continue;
            NSString *ircLine = [(NSString *)value stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            S7TVChatMessage *message = s7tv_parseChatMessage(
                ircLine, s7tv_chatEmoteProviders());
            if (!message) continue;
            message.isHistorical = YES;
            [history addObject:message];
        }
        [history sortUsingComparator:^NSComparisonResult(S7TVChatMessage *left,
                                                          S7TVChatMessage *right) {
            return [left.timestamp compare:right.timestamp];
        }];

        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
        [[SevenTVManager sharedManager].chatMessageStore
            prependHistoricalMessages:history
            ifCurrent:^BOOL{
                return s7tv_recentHistoryRequestIsCurrent(channel, generation);
            }
            completion:^{
                if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
                [[SevenTVManager sharedManager]
                    log:@"🕘 %lu messages historiques chargés pour %@",
                    (unsigned long)history.count, channel];
                s7tv_reloadActiveChatCustomView();
            }];
    }] resume];
}

static void s7tv_beginRecentHistory(NSString *channel, NSUInteger generation) {
    if (!channel.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[S7TVReplyThreadPanel sharedPanel] hide];
    });

    NSDate *now = NSDate.date;
    S7TVChatMessage *welcome = [[S7TVChatMessage alloc]
        initWithMessageID:[NSString stringWithFormat:@"s7tv-history-welcome-%lu",
                                                    (unsigned long)generation]
                timestamp:now authorUserID:@"" authorDisplayName:@"" rawText:channel];
    welcome.type = S7TVChatMessageTypeHistoryWelcome;
    S7TVChatMessage *divider = [[S7TVChatMessage alloc]
        initWithMessageID:[NSString stringWithFormat:@"s7tv-history-divider-%lu",
                                                    (unsigned long)generation]
                timestamp:now authorUserID:@"" authorDisplayName:@"" rawText:@""];
    divider.type = S7TVChatMessageTypeHistoryDivider;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    [manager.chatMessageStore replaceAllMessages:@[welcome, divider] completion:^{
        if (!s7tv_recentHistoryRequestIsCurrent(channel, generation)) return;
        [manager log:@"🏗 Chat initialisé pour %@ (historique en cours)", channel];
        s7tv_reloadActiveChatCustomView();
        s7tv_fetchRecentHistory(channel, generation);
    }];
}

@implementation SevenTVManager (RecentChatHistory)

- (void)initializeRecentHistoryForChannel:(NSString *)channel force:(BOOL)force {
    if (!channel.length) return;
    NSUInteger generation = 0;
    @synchronized (self) {
        BOOL alreadyInitialized = s7tv_recentHistoryInitializedChannel.length &&
            [s7tv_recentHistoryInitializedChannel caseInsensitiveCompare:channel] == NSOrderedSame;
        if (!force && alreadyInitialized) return;
        s7tv_recentHistoryInitializedChannel = channel.lowercaseString;
        generation = ++s7tv_recentHistoryGeneration;
    }
    s7tv_beginRecentHistory(channel, generation);
}

- (NSArray<NSString *> *)joinedChannelsInOutgoingWebSocketMessage:
    (NSURLSessionWebSocketMessage *)message {
    NSString *payload = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        payload = message.string;
    } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
        payload = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
    }
    if (!payload.length) return @[];

    NSMutableArray<NSString *> *channels = [NSMutableArray array];
    for (NSString *rawLine in [payload componentsSeparatedByCharactersInSet:
                               NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"JOIN #"]) continue;
        NSString *tail = [line substringFromIndex:6];
        NSRange end = [tail rangeOfCharacterFromSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *channel = end.location == NSNotFound
            ? tail : [tail substringToIndex:end.location];
        channel = [channel stringByTrimmingCharactersInSet:
                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (channel.length) [channels addObject:channel.lowercaseString];
    }
    return channels;
}

- (void)handleOutgoingChatWebSocketMessage:(NSURLSessionWebSocketMessage *)message {
    for (NSString *channel in [self joinedChannelsInOutgoingWebSocketMessage:message]) {
        NSString *previousChannel = [self.currentChannelName copy];
        BOOL switchingChannel = previousChannel.length &&
            [previousChannel caseInsensitiveCompare:channel] != NSOrderedSame;

        // Twitch rejoint aussi le salon technique du compte connecté
        // (JOIN #<login du viewer>) à la connexion du chat, indépendamment
        // de la chaîne affichée. Si ce JOIN technique arrive pendant qu'une
        // vraie chaîne occupe déjà la session et avant que son ROOMSTATE ne
        // l'ait confirmée, il écrase currentChannelName : le ROOMSTATE et
        // les PRIVMSG de la chaîne réellement ouverte sont alors rejetés
        // (aucun message affiché, picker sur le mauvais channel). On ignore
        // donc ce JOIN tant que le salon courant n'est pas confirmé. Une
        // fois confirmé, un JOIN du viewer est au contraire un vrai
        // changement vers sa propre chaîne et reste honoré.
        if (self.currentViewerDisplayName.length &&
            previousChannel.length &&
            [channel caseInsensitiveCompare:self.currentViewerDisplayName] == NSOrderedSame &&
            [previousChannel caseInsensitiveCompare:channel] != NSOrderedSame &&
            !s7tv_currentChannelRoomStateConfirmed) {
            [self log:@"ℹ️ JOIN technique du viewer ignoré (#%@, salon actif: %@)",
                channel, previousChannel];
            continue;
        }

        [self log:@"📺 Rejoint le channel: %@", channel];
        // Met currentChannelName à jour avant le reset et avant que
        // l'historique n'entre dans le parseur IRC.
        [self loadEmotesForChannelName:channel];
        // Le JOIN est la source de vérité de la transition : suppression des
        // anciens messages immédiate, sans attendre ROOMSTATE.
        [self initializeRecentHistoryForChannel:channel force:YES];

        if (switchingChannel) {
            // Nouveau salon : invalide la confirmation ROOMSTATE précédente
            // — le JOIN technique du viewer ne doit pas prendre la main
            // avant que le serveur n'ait confirmé ce nouveau salon.
            s7tv_currentChannelRoomStateConfirmed = NO;
        }
    }
}

@end
