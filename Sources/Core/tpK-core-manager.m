/*
 * tpK-core-manager.m
 * Implémentation du gestionnaire 7TV.
 *
 * CORRECTIFS v1.8 — Keyboard-replacement mode:
 *   Fix M — inputView = picker : le picker remplace le clavier (s'affiche en dessous).
 *   Fix N — _hideEmotePicker : inputView=nil restaure le clavier natif.
 *
 * CORRECTIFS v1.4:
 *   Fix C — Injection IRC multi-lignes.
 *
 * Depuis la migration multi-provider, le catalogue commun possède seul les
 * caches et les requêtes d'emotes. Le manager ne garde qu'une façade de
 * compatibilité pour les anciens appelants.
 *
 * CORRECTIFS v1.6 — Format IRC + Positions:
 *   Fix H — Trimming messageText (\r\n only).
 *   Fix I — Format tag emotes= conforme Twitch IRC.
 *   Fix J — Séparateur "/" entre IDs différents.
 *   Fix K — Écriture cache: retry si dossier purgé par iOS.
 *
 */

#import "Core/tpK-core-manager.h"
#import "Core/tpK-channel-resolver.h"
#import "Settings/tpK-settings-controller.h"
#import "Emote/tpK-emote-image-transport.h"
#import "UI/7tv-ui-logo.h"
#import "UI/tpK-ui-logo.h"
#import "Localization/tpK-localization-manager.h"
#import "Settings/tpK-chat-appearance-config.h"
#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-animation-engine.h"
#import "Picker/tpK-picker-controller.h"
#import "Emote/tpK-emote-catalog.h"
#import <objc/runtime.h>

// ============================================================
// Constante de notification
// ============================================================
NSString *const TPKLogsDidUpdateNotification = @"TPKLogsDidUpdateNotification";
NSString *const TPKEmoteCatalogDidUpdateNotification = @"TPKEmoteCatalogDidUpdateNotification";
NSString *const TPKFavoritesDidChangeNotification = @"TPKFavoritesDidChangeNotification";
NSString *const TPKTwitchCredentialsDidUpdateNotification = @"TPKTwitchCredentialsDidUpdateNotification";

// ============================================================
// Implémentation de TPKEmote
// ============================================================
@implementation TPKEmote
@end

// Keep the old public TPKEmote shape available to callers that have not
// moved to TPKEmoteDescriptor yet.  The catalogue remains the only source
// of network/cache data; this is just a cheap compatibility projection.
static TPKEmote *TPKLegacyEmoteFromDescriptor(TPKEmoteDescriptor *descriptor) {
    if (!descriptor || !descriptor.emoteID.length || !descriptor.name.length) return nil;
    TPKEmote *emote = [[TPKEmote alloc] init];
    emote.emoteID = descriptor.emoteID;
    emote.emoteName = descriptor.name;
    emote.isAnimated = descriptor.animated;
    emote.zeroWidth = descriptor.zeroWidth;
    emote.width = MAX(0, (NSInteger)descriptor.nativeSize.width);
    emote.height = MAX(0, (NSInteger)descriptor.nativeSize.height);
    return emote;
}


// ============================================================
// TPKManager (privé)
// ============================================================
@interface TPKManager ()

// File de dispatch pour la thread-safety des données d'emotes
@property (nonatomic, strong, readwrite) dispatch_queue_t emoteQueue;

// Bouton flottant des paramètres
@property (nonatomic, weak)   UIButton *settingsButton;
// Fenêtre dédiée au bouton flottant (strong = reste en vie toute la session)
@property (nonatomic, strong) UIWindow *floatingWindow;
// Fenêtre dédiée au menu settings (créée au tap, détruite à la fermeture)
@property (nonatomic, strong) UIWindow *menuWindow;

// Picker d'emotes 7TV — composant séparé (voir tpK-picker-controller.m),
// instancié paresseusement. Le manager ne garde que la façade publique
// (toggleEmotePickerForChatInputView:/cleanupPickerForStreamClose) + la
// donnée persistée (favoriteEmoteIDs ci-dessous) : tout le reste de l'UI du
@property (nonatomic, strong) TPKEmotePickerController *pickerController;

// Favoris : IDs 7TV des emotes mise en favoris (persisté dans NSUserDefaults)
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteEmoteIDs;

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Token OAuth Twitch + Client-ID — interceptés depuis les requêtes GQL
// (voir tpK-core-runtime-hooks.m tpk_dataTaskWithRequest:) pour pouvoir appeler
// l'API Helix (badges, etc.) sans enregistrer une app développeur.
@property (nonatomic, copy) NSString *twitchToken;
@property (nonatomic, copy) NSString *twitchClientID;
// Valeurs partielles en attendant d'avoir les deux (voir capture méthodes ci-dessous)
@property (nonatomic, copy) NSString *pendingAuthHeader;
@property (nonatomic, copy) NSString *pendingClientIDHeader;
@property (nonatomic, weak) id pendingAuthContext;
@property (nonatomic, weak) id pendingClientIDContext;


- (void)tpk_notifyFavoritesChanged;
- (void)tpk_catalogDidUpdate:(NSNotification *)notification;
- (void)tpk_syncLegacyEmoteViews;

@end


// ============================================================
// MARK: - TPKPresentationController
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

static const CGFloat kTPKMenuWidth  = 360.0;
static const CGFloat kTPKMenuHeight = 520.0;

@interface TPKPresentationController : UIPresentationController
@property (nonatomic, strong) UIView *dimmingView;
@end

@implementation TPKPresentationController

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
            postNotificationName:@"TPKMenuDidDismiss" object:nil];
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
// MARK: - TPKSettingsNavController
//
// UINavigationController qui fournit son propre transitioningDelegate
// → utilise TPKPresentationController pour un placement et une
//   taille totalement contrôlés (360×520pt, centré).
// ============================================================
@interface TPKSettingsNavController : UINavigationController <UIViewControllerTransitioningDelegate>
@end

@implementation TPKSettingsNavController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = TPKAccent();
}

- (instancetype)initWithRootViewController:(UIViewController *)root {
    self = [super initWithRootViewController:root];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationCustom;
        self.transitioningDelegate  = self;
        // Flèche et libellé « Retour » à la couleur du tweak sur tous les écrans.
        self.navigationBar.tintColor = TPKAccent();
    }
    return self;
}

- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                      presentingViewController:(UIViewController *)presenting
                                                          sourceViewController:(UIViewController *)source {
    return [[TPKPresentationController alloc]
        initWithPresentedViewController:presented presentingViewController:presenting];
}

@end


// ============================================================
// MARK: - TPKFloatingWindow
//
// UIWindow dont le hitTest ne capte les touches QUE si une
// vraie sous-vue (le bouton 7TV) est touchée.
// Si le fond transparent est touché → retourne nil → iOS
// transmet le touch à la fenêtre Twitch en dessous.
// ============================================================
@interface TPKFloatingWindow : UIWindow
@end

@implementation TPKFloatingWindow
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
@implementation TPKManager

// ============================================================
// MARK: - Singleton
// ============================================================

+ (instancetype)sharedManager {
    static TPKManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TPKManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _showPickerAnimations  = YES;  // Activé par défaut
        _showPickerAnimationsFavoritesOnly = NO;
        _debugLogging          = (TPK_DEBUG == 1);

        // Valeurs par défaut des logs.
        _logsEnabled       = YES;
        _logErrors         = YES;   // Erreurs/Avertissements visibles par défaut
        _logChat     = NO;    // Désactivé par défaut
        _logChannelPoints  = NO;    // OFF par défaut
        _logTap            = NO;    // OFF par défaut (verbeux)
        _logChannelResolver = NO;

        _globalEmotes      = @{};
        _channelEmotes     = @{};

        _emoteQueue  = dispatch_queue_create("tv.s7tv.emote-queue",  DISPATCH_QUEUE_CONCURRENT);

        // Cache image RAM : 40 MB max — environ 1000 emotes statiques 40×40pt décompressées.
        // NSCache évicte automatiquement sous pression mémoire → jamais de crash OOM.


        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        _favoriteEmoteIDs        = [NSMutableSet set];
        // Les ivars d'état du picker (onglets, sous-choix, arrays filtrées...)
        // sont initialisées dans TPKEmotePickerController, créé
        // paresseusement — voir -pickerController.

        [self loadPreferences];
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(tpk_catalogDidUpdate:)
                   name:TPKProviderCatalogDidUpdateNotification
                 object:nil];
    }
    return self;
}


// ============================================================
// MARK: - Initialisation
// ============================================================

- (void)setup {
    [[TPKEmoteCatalog sharedCatalog] loadGlobalProviders];
    [self tpk_syncLegacyEmoteViews];
}

- (void)tpk_catalogDidUpdate:(NSNotification *)notification {
    (void)notification;
    [self tpk_syncLegacyEmoteViews];
}

- (void)tpk_syncLegacyEmoteViews {
    // Build the compatibility dictionaries from the provider-aware snapshot.
    // This projection is deliberately read-only from the manager's point of
    // view: all network, cache and collision resolution work stays in the
    // common catalogue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TPKEmoteCatalog *catalog = [TPKEmoteCatalog sharedCatalog];
        NSArray<TPKEmoteDescriptor *> *descriptors =
            [catalog allEmotesForProvider:TPKEmoteProviderIDTPK];
        NSMutableDictionary<NSString *, TPKEmote *> *channel =
            [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, TPKEmote *> *global =
            [NSMutableDictionary dictionary];

        for (TPKEmoteDescriptor *descriptor in descriptors) {
            if (descriptor.sectionKind != TPKEmoteSectionKindChannel ||
                !descriptor.name.length) continue;
            TPKEmote *emote = TPKLegacyEmoteFromDescriptor(descriptor);
            if (emote) channel[descriptor.name] = emote;
        }
        for (TPKEmoteDescriptor *descriptor in descriptors) {
            if (descriptor.sectionKind == TPKEmoteSectionKindChannel ||
                !descriptor.name.length || channel[descriptor.name]) continue;
            TPKEmote *emote = TPKLegacyEmoteFromDescriptor(descriptor);
            if (emote) global[descriptor.name] = emote;
        }

        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = channel.copy;
            self.globalEmotes = global.copy;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_pickerController)
                    [self->_pickerController invalidateSortCache];
                // Preserve the notification used by older chat integrations;
                // the common catalogue notification remains the canonical one.
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:TPKEmoteCatalogDidUpdateNotification
                                  object:self];
            });
        });
    });
}


// ============================================================
// MARK: - Préférences utilisateur (NSUserDefaults — petit, OK ici)
// ============================================================

- (void)loadPreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs objectForKey:@"tpk_picker_anim"]       != nil) _showPickerAnimations  = [prefs boolForKey:@"tpk_picker_anim"];
    if ([prefs objectForKey:@"tpk_picker_anim_favs"]  != nil) _showPickerAnimationsFavoritesOnly = [prefs boolForKey:@"tpk_picker_anim_favs"];
    if ([prefs objectForKey:@"tpk_debug"]             != nil) _debugLogging          = [prefs boolForKey:@"tpk_debug"];
    if ([prefs objectForKey:@"tpk_floating_btn"]      != nil) _showFloatingButton     = [prefs boolForKey:@"tpk_floating_btn"];
    else _showFloatingButton = NO; // désactivé par défaut

    // --- Logs : interrupteur global + catégories ---
    if ([prefs objectForKey:@"tpk_logs_enabled"]      != nil) _logsEnabled           = [prefs boolForKey:@"tpk_logs_enabled"];
    if ([prefs objectForKey:@"tpk_log_errors"]        != nil) _logErrors             = [prefs boolForKey:@"tpk_log_errors"];
    if ([prefs objectForKey:@"tpk_log_chat_custom"]   != nil) _logChat         = [prefs boolForKey:@"tpk_log_chat_custom"];
    if ([prefs objectForKey:@"tpk_log_channel_points"] != nil) _logChannelPoints     = [prefs boolForKey:@"tpk_log_channel_points"];
    if ([prefs objectForKey:@"tpk_log_tap"]           != nil) _logTap               = [prefs boolForKey:@"tpk_log_tap"];
    if ([prefs objectForKey:@"tpk_log_channel_resolver"] != nil) _logChannelResolver = [prefs boolForKey:@"tpk_log_channel_resolver"];

    // Supprimer les anciennes préférences de logs.
    for (NSString *key in @[
        @"tpk_log_swizzle", @"tpk_log_cache", @"tpk_log_prefetch",
        @"tpk_log_api", @"tpk_log_irc_channel", @"tpk_log_ui_picker",
        @"tpk_log_favorites", @"tpk_log_orientation", @"tpk_log_image_conv",
        @"tpk_log_dump"
    ]) {
        [prefs removeObjectForKey:key];
    }

    // Charger les favoris (array d'IDs 7TV)
    NSArray *savedFavs = [prefs arrayForKey:@"tpk_favorites"];
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
            postNotificationName:TPKChatAppearanceConfigDidChangeNotification object:self];
    });
    [self tpk_notifyFavoritesChanged];
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.showPickerAnimations forKey:@"tpk_picker_anim"];
    [prefs setBool:self.showPickerAnimationsFavoritesOnly forKey:@"tpk_picker_anim_favs"];
    [prefs setBool:self.debugLogging         forKey:@"tpk_debug"];
    [prefs setBool:self.showFloatingButton   forKey:@"tpk_floating_btn"];

    [prefs setBool:self.logsEnabled          forKey:@"tpk_logs_enabled"];
    [prefs setBool:self.logErrors            forKey:@"tpk_log_errors"];
    [prefs setBool:self.logChat        forKey:@"tpk_log_chat_custom"];
    [prefs setBool:self.logChannelPoints     forKey:@"tpk_log_channel_points"];
    [prefs setBool:self.logTap               forKey:@"tpk_log_tap"];
    [prefs setBool:self.logChannelResolver   forKey:@"tpk_log_channel_resolver"];
    [prefs synchronize];
}

- (void)_saveFavorites {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:[self favoriteEmoteIDsSnapshot] forKey:@"tpk_favorites"];
    [prefs synchronize];
}

// --- Favoris : API publique (voir tpK-core-manager.h) ---
// La donnée (favoriteEmoteIDs) et sa persistance restent ici ; seule l'UI qui
// l'affiche/la modifie (grille du picker, long-press) vit dans
// TPKEmotePickerController.
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
    [[TPKEmoteCatalog sharedCatalog]
        setLegacyTPKFavoriteID:emoteID favorited:favorited];
    [self tpk_notifyFavoritesChanged];
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
    [[TPKEmoteCatalog sharedCatalog]
        replaceLegacyTPKFavoriteIDs:validIDs.allObjects];
    [self tpk_notifyFavoritesChanged];
}

- (void)tpk_notifyFavoritesChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pickerController) [self->_pickerController favoritesDidChange];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKFavoritesDidChangeNotification object:self];
    });
}

- (NSString *)currentChannelName {
    if (_currentChannelName.length) return _currentChannelName;

    TPKChannelContext *context = TPKCurrentChannelContext();
    return context.channelName.length ? context.channelName : context.displayName;
}
- (void)setCurrentChannelTwitchID:(NSString *)channelID {
    _currentChannelTwitchID = [channelID copy];
}
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
- (void)setLogChat:(BOOL)v      { _logChat = v;      [self savePreferences]; }
- (void)setLogChannelPoints:(BOOL)v   { _logChannelPoints = v;   [self savePreferences]; }
- (void)setLogTap:(BOOL)v             { _logTap = v;             [self savePreferences]; }
- (void)setLogChannelResolver:(BOOL)v { _logChannelResolver = v; [self savePreferences]; }


// ============================================================
// MARK: - Chargement des emotes globales
// ============================================================

- (void)loadGlobalEmotes {
    [[TPKEmoteCatalog sharedCatalog]
        loadProvider:TPKEmoteProviderIDTPK
             global:YES
           channel:nil
         completion:nil];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par ID Twitch
// ============================================================

- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID {
    if (!twitchUserID.length) return;
    // The provider catalogue owns channel cancellation, cache-first loading,
    // parsing and publication for all three providers.
    [[TPKEmoteCatalog sharedCatalog]
        loadChannelProvidersForTwitchID:twitchUserID];
}


// ============================================================
// MARK: - Stockage token Twitch (intercepté depuis requêtes GQL)
// ============================================================

// N'accepte que les deux schémas réellement utilisés par Twitch. L'adblock
// ajoute parfois un `Authorization: Basic ...` pour authentifier son proxy :
// cette valeur ne doit surtout jamais remplacer le token OAuth Twitch utilisé
// par Helix (badges, avatars, etc.).
static NSString *TPKNormalizedTwitchBearerToken(NSString *value) {
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

- (void)tpk_captureAuthorizationHeader:(NSString *)value context:(id)context {
    NSString *normalized = TPKNormalizedTwitchBearerToken(value);
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

- (void)tpk_captureClientIDHeader:(NSString *)value context:(id)context {
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

- (NSDictionary<NSString *, NSString *> *)tpk_twitchCredentialsSnapshot {
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
    NSString *normalizedToken = TPKNormalizedTwitchBearerToken(token);
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
    [[NSNotificationCenter defaultCenter]
        postNotificationName:TPKTwitchCredentialsDidUpdateNotification object:self];
}


// ============================================================
// MARK: - Accès aux emotes
// ============================================================

- (TPKEmote *)emoteForName:(NSString *)name {
    TPKEmoteDescriptor *descriptor =
        [[TPKEmoteCatalog sharedCatalog]
            resolveEmoteNamed:name
                       provider:TPKEmoteProviderIDTPK];
    TPKEmote *catalogEmote = TPKLegacyEmoteFromDescriptor(descriptor);
    if (catalogEmote) return catalogEmote;

    // Keep a last-resort snapshot for callers racing the first catalogue
    // publication. It is never populated by a network request.
    __block TPKEmote *emote = nil;
    dispatch_sync(self.emoteQueue, ^{
        emote = self.channelEmotes[name] ?: self.globalEmotes[name];
    });
    return emote;
}

- (NSURL *)cdnURLForEmote:(TPKEmote *)emote {
    if (!emote) return nil;
    // Keep the compatibility CDN helper on the provider-agnostic setting.
    // emote7TVResolution is only an alias for old imports/exports.
    NSInteger resolution = [TPKChatAppearanceConfig sharedConfig].emoteImageResolution;
    resolution = MIN(4, MAX(1, resolution));
    return [NSURL URLWithString:
            [NSString stringWithFormat:@"%@/%@/%ldx.webp",
             TPK_CDN_BASE, emote.emoteID, (long)resolution]];
}


// ============================================================
// MARK: - Picker d'emotes 7TV (délégué à TPKEmotePickerController)
//
// désormais dans TPKEmotePickerController  — voir ces fichiers. Le manager garde uniquement la
// donnée persistée (favoriteEmoteIDs, cf. plus haut) et cette façade, pour
// que tpK-core-runtime-hooks.m n'ait rien à changer.
// ============================================================

- (TPKEmotePickerController *)pickerController {
    if (!_pickerController) {
        _pickerController = [[TPKEmotePickerController alloc] init];
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
        TPKFloatingWindow *floatingWin;
        if (windowScene) {
            floatingWin = [[TPKFloatingWindow alloc] initWithWindowScene:windowScene];
        } else {
            floatingWin = [[TPKFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
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
        static Class TPKFloatingRootVC = nil;
        static dispatch_once_t onceVC;
        dispatch_once(&onceVC, ^{
            TPKFloatingRootVC = objc_allocateClassPair([UIViewController class],
                                                           "TPKFloatingRootVC", 0);
            class_addMethod(TPKFloatingRootVC,
                @selector(supportedInterfaceOrientations),
                imp_implementationWithBlock(^UIInterfaceOrientationMask(id _){
                    return UIInterfaceOrientationMaskAll;
                }), "I@:");
            class_addMethod(TPKFloatingRootVC,
                @selector(shouldAutorotate),
                imp_implementationWithBlock(^BOOL(id _){ return YES; }),
                "B@:");
            objc_registerClassPair(TPKFloatingRootVC);
        });
        object_setClass(rootVC, TPKFloatingRootVC);

        floatingWin.rootViewController = rootVC;

        self.floatingWindow = floatingWin;

        // ── Créer le bouton ───────────────────────────────────────────────────
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat size = 44.0, margin = 16.0;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(screen.size.width  - size - margin,
                               screen.size.height - size - margin - 80.0,
                               size, size);
        btn.backgroundColor     = [UIColor colorWithWhite:0.0 alpha:0.92];
        btn.layer.cornerRadius  = size / 2.0;
        btn.layer.borderWidth   = 1.0;
        btn.layer.borderColor   = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        btn.layer.shadowColor   = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset  = CGSizeMake(0, 2);
        btn.layer.shadowRadius  = 4;
        btn.layer.shadowOpacity = 0.4;
        NSData *tpkData = [[NSData alloc]
            initWithBase64EncodedString:kTPKTwitchPlusKLogoBase64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *tpkImg = [UIImage imageWithData:tpkData scale:UIScreen.mainScreen.scale];
        if (tpkImg) {
            CGFloat maxSide = size - 16.0;
            CGSize src = tpkImg.size;
            CGFloat ratio = MIN(maxSide / MAX(src.width, 1.0), maxSide / MAX(src.height, 1.0));
            CGSize dst = CGSizeMake(src.width * ratio, src.height * ratio);
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
            format.opaque = NO;
            format.scale = UIScreen.mainScreen.scale;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                initWithSize:CGSizeMake(maxSide, maxSide) format:format];
            UIImage *fitted = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [tpkImg drawInRect:CGRectMake((maxSide - dst.width) / 2.0,
                                              (maxSide - dst.height) / 2.0,
                                              dst.width, dst.height)];
            }];
            UIImage *logo = [fitted imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            [btn setImage:logo forState:UIControlStateNormal];
            btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
        }
        [btn addTarget:self action:@selector(settingsButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSettingsButtonDrag:)]];

        [rootVC.view addSubview:btn];
        self.settingsButton = btn;

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
        object_setClass(rootVC, NSClassFromString(@"TPKFloatingRootVC"));
        menuWin.rootViewController = rootVC;
        menuWin.hidden = NO;
        self.menuWindow = menuWin; // retenu fortement jusqu'à la fermeture

        TPKSettingsController *vc = [[TPKSettingsController alloc] init];
        vc.openedAsModal = YES;
        // TPKSettingsNavController : UIModalPresentationCustom +
        // TPKPresentationController → 360×520pt centré dans menuWin.
        TPKSettingsNavController *nav = [[TPKSettingsNavController alloc] initWithRootViewController:vc];

        __weak typeof(self) weakSelf = self;
        [rootVC presentViewController:nav animated:YES completion:nil];

        // Libérer la fenêtre quand le menu est fermé
        // On observe la disparition du nav via viewDidDisappear dans une catégorie légère.
        // Méthode simple : polling via le completion du dismiss depuis le bouton Close.
        // Le bouton Close appelle dismissViewControllerAnimated:completion: →
        // on swizzle pas, on utilise un bloc de notification.
        __block id observer = nil;
        observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"TPKMenuDidDismiss"
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
// Seuls les marqueurs explicites sont reconnus.
static BOOL tpk_categoryForMessage(NSString *msg, TPKLogCategory *outCategory) {
    if (!msg.length || !outCategory) return NO;
    if ([msg hasPrefix:@"[ChannelResolver]"]) {
        *outCategory = TPKLogCategoryChannelResolver;
        return YES;
    }

    // Marqueurs explicites uniquement.
    if ([msg rangeOfString:@"[ChannelPoints]"].location != NSNotFound) {
        *outCategory = TPKLogCategoryChannelPoints;
        return YES;
    }
    if ([msg rangeOfString:@"[Chat]"].location != NSNotFound) {
        *outCategory = TPKLogCategoryChat;
        return YES;
    }
    if ([msg rangeOfString:@"❌"].location != NSNotFound ||
        [msg rangeOfString:@"⚠️"].location != NSNotFound) {
        *outCategory = TPKLogCategoryError;
        return YES;
    }
    // Tap Logger : ligne d'en-tête 👆 + sous-lignes indentées de 2 espaces
    // (FIRST_RESPONDER, HIT, VC, hiérarchie, fin de bloc).
    if ([msg hasPrefix:@"👆"] || [msg hasPrefix:@"  "] ||
        [msg rangeOfString:@"FIRST_RESPONDER"].location != NSNotFound ||
        [msg rangeOfString:@"HIT:"].location != NSNotFound ||
        [msg rangeOfString:@"fin hiérarchie"].location != NSNotFound) {
        *outCategory = TPKLogCategoryTap;
        return YES;
    }
    return NO;
}

- (BOOL)tpk_isCategoryEnabled:(TPKLogCategory)cat {
    switch (cat) {
        case TPKLogCategoryError:         return self.logErrors;
        case TPKLogCategoryChat:    return self.logChat;
        case TPKLogCategoryChannelPoints: return self.logChannelPoints;
        case TPKLogCategoryTap:           return self.logTap;
        case TPKLogCategoryChannelResolver: return self.logChannelResolver;
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

    // Interrupteur global.
    if (!self.logsEnabled) return;

    // Ignorer les lignes désactivées ou non reconnues.
    TPKLogCategory cat;
    if (!tpk_categoryForMessage(msg, &cat)) return;
    if (![self tpk_isCategoryEnabled:cat]) return;

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
            NSString *path = [docs.firstObject stringByAppendingPathComponent:@"tpk_logs.txt"];
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
    if (self.logBuffer.count > TPK_LOG_BUFFER_MAX) {
        [self.logBuffer removeObjectsInRange:
         NSMakeRange(0, self.logBuffer.count - TPK_LOG_BUFFER_MAX)];
    }
    [self.logLock unlock];

    // NSLog console uniquement si debugLogging activé (mirroring Console.app)
    if (self.debugLogging) {
        NSLog(@"[TwitchTPK] %@", msg);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKLogsDidUpdateNotification
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
            postNotificationName:TPKLogsDidUpdateNotification
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
    NSUInteger clearedEmoteCount = (NSUInteger)[TPKURLProtocol cachedEmoteCount];

    // Empêche tout téléchargement/décodage déjà en vol de repeupler les
    // caches après l'action utilisateur.
    [[TPKEmoteImageCache sharedCache] clearAllCaches];
    [[TPKEmoteAnimationEngine sharedEngine] clearAllCachedFrames];

    NSString *channelID = [self.currentChannelTwitchID copy];
    dispatch_group_t clearing = dispatch_group_create();

    dispatch_group_enter(clearing);
    [TPKURLProtocol clearAllEmoteCachesWithCompletion:^(NSUInteger ignoredCount) {
        dispatch_group_leave(clearing);
    }];

    // 1) Dictionnaires d'emotes en mémoire — écriture protégée par
    // dispatch_barrier_async sur emoteQueue (même convention que le reste
    // du fichier, voir header de emoteQueue).
    dispatch_group_enter(clearing);
    dispatch_barrier_async(self.emoteQueue, ^{
        self.globalEmotes  = @{};
        self.channelEmotes = @{};
        dispatch_group_leave(clearing);
    });

    // 2) Les providers BTTV/FFZ/7TV gardent leurs propres snapshots JSON.
    // Le catalogue annule les requêtes en vol et supprime aussi les anciens
    // fichiers s7tv/ migrés, puis publie une nouvelle génération.
    dispatch_group_enter(clearing);
    [[TPKEmoteCatalog sharedCatalog]
        clearCachedDataWithCompletion:^{
            dispatch_group_leave(clearing);
        }];

    // 3) Ne relire les catalogues qu'une fois les fichiers réellement
    // supprimés. L'ancienne version lançait le reload immédiatement et
    // pouvait donc relire le JSON juste avant sa suppression.
    dispatch_group_notify(clearing, dispatch_get_main_queue(), ^{
        if (self->_pickerController) {
            [self->_pickerController invalidateSortCache];
            [self->_pickerController favoritesDidChange];
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKEmoteCatalogDidUpdateNotification object:self];

        [[TPKEmoteCatalog sharedCatalog] loadGlobalProviders];
        if (channelID.length) [self loadEmotesForChannelTwitchID:channelID];
        if (completion) completion(clearedEmoteCount);
    });
}

@end


// ============================================================
// MARK: - Channel context from native IRC
static NSString *tpk_roomID(NSString *line) {
    if (![line hasPrefix:@"@"]) return nil;
    NSRange end = [line rangeOfString:@" "];
    if (end.location == NSNotFound) return nil;
    NSString *tags = [line substringWithRange:NSMakeRange(1, end.location - 1)];
    for (NSString *tag in [tags componentsSeparatedByString:@";"])
        if ([tag hasPrefix:@"room-id="]) return [tag substringFromIndex:8];
    return nil;
}
@implementation TPKManager (IRCSessionState)
- (void)handleIncomingChatWebSocketText:(NSString *)text {
    [self handleIncomingChatWebSocketText:text sourceObject:nil];
}
- (void)handleIncomingChatWebSocketText:(NSString *)text sourceObject:(id)sourceObject {
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *commandLine = line;
        if ([commandLine hasPrefix:@"@"]) {
            NSRange end = [commandLine rangeOfString:@" "];
            commandLine = end.location == NSNotFound ? @"" : [commandLine substringFromIndex:end.location + 1];
        }
        if ([commandLine hasPrefix:@":"]) {
            NSRange end = [commandLine rangeOfString:@" "];
            commandLine = end.location == NSNotFound ? @"" : [commandLine substringFromIndex:end.location + 1];
        }
        if (![commandLine hasPrefix:@"ROOMSTATE #"]) continue;
        NSString *tail = [commandLine substringFromIndex:11];
        NSString *channel = [[tail componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] firstObject];
        if (channel.length) TPKChannelResolverNoteChatRoom(channel, tpk_roomID(line), sourceObject);
    }
}
@end
