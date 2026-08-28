/*
 * 7tv-core-manager.h
 * Gestionnaire principal de tout ce qui concerne 7TV.
 * C'est un "singleton" = une seule instance existe dans toute l'app.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const S7TVFavoritesDidChangeNotification;
// Publiée quand un couple OAuth Twitch + Client-ID valide est disponible.
// Les consommateurs Helix qui ont tenté trop tôt peuvent alors se relancer.
FOUNDATION_EXPORT NSString *const S7TVTwitchCredentialsDidUpdateNotification;

@class S7TVChatMessageStore;

// ============================================================
// CONFIGURATION - Modifie ces valeurs selon tes besoins
// ============================================================

// Mettre à 1 pour activer les logs de débogage dans la console
// (visible avec Console.app sur Mac ou via syslog)
#define S7TV_DEBUG 0

// Préfixe utilisé pour nos faux IDs d'emotes dans Twitch
// NE PAS MODIFIER - doit correspondre à 7tv-network-emote-cache.m
#define S7TV_EMOTE_ID_PREFIX @"7tv_"

// URLs de l'API 7TV
#define S7TV_API_BASE        @"https://7tv.io/v3"
#define S7TV_CDN_BASE        @"https://cdn.7tv.app/emote"

// Nombre maximum de lignes conservées dans le buffer de logs in-app
#define S7TV_LOG_BUFFER_MAX  5000

// Nom de la notification postée quand une nouvelle ligne est ajoutée au buffer
// SevenTVLogsController écoute cette notification pour se rafraîchir.
extern NSString *const S7TVLogsDidUpdateNotification;
extern NSString *const S7TVEmoteCatalogDidUpdateNotification;
extern NSString *const S7TVChatCustomToggleDidChangeNotification;

// ============================================================
// Fonctions C partagées encore définies dans 7tv-core-runtime-hooks.m
// ============================================================
// Helper swizzle partagé par tout le tweak (échange les implémentations de
// `original` et `swizzled` entre sourceClass et targetClass). Utilisé par
// 7tv-core-runtime-hooks.m ET par le module verrou d'orientation (voir
// 7tv-system-native-behavior-hooks.m) pour installer ses propres swizzles
// UIApplication/UIViewController à la demande, au premier lock.
void s7tv_swizzle(Class targetClass, Class sourceClass, SEL original, SEL swizzled);


// ============================================================
// Catégories de logs
// ============================================================
// Chaque ligne loguée via -log: est classée automatiquement dans une de ces
// catégories (par analyse du contenu du message, voir s7tv_categoryForMessage:
// dans 7tv-core-manager.m). Chaque catégorie peut être activée/désactivée
// indépendamment depuis SevenTVDebugPageController.
typedef NS_ENUM(NSInteger, S7TVLogCategory) {
    S7TVLogCategoryError = 0,        // 🚨 Erreurs / Avertissements (❌ ⚠️) — toujours prioritaire
    S7TVLogCategorySwizzle,          // 🔌 Swizzle / Boot
    S7TVLogCategoryCache,            // ⚡️ Cache / Réseau
    S7TVLogCategoryPrefetch,         // 🚀 Prefetch
    S7TVLogCategoryAPI,              // 🌍 API Emotes
    S7TVLogCategoryIRCChannel,       // 📡 IRC / Channel
    S7TVLogCategoryUIPicker,         // 🎨 UI / Picker
    S7TVLogCategoryFavorites,        // ⭐ Favoris
    S7TVLogCategoryOrientation,      // 🔒 Orientation Lock
    S7TVLogCategoryImageConversion,  // 🖼 CDN / Cache emotes
    S7TVLogCategoryChatCustom,       // 🏗 Chat Custom (diagnostic Phase 0+)
    S7TVLogCategoryChannelPoints,    // 🎁 Channel Points (autoclaim)
    S7TVLogCategoryDump,             // 🗑️ Dump (et tout ce qui n'est pas classé)
};
#define S7TV_LOG_CATEGORY_COUNT 13


// ============================================================
// Structure d'une emote 7TV
// ============================================================
@interface SevenTVEmote : NSObject
@property (nonatomic, strong) NSString *emoteID;   // ID 7TV (ex: "63071bb9464de28875c52531")
@property (nonatomic, strong) NSString *emoteName;  // Nom (ex: "KEKW")
@property (nonatomic, assign) BOOL isAnimated;      // Si c'est un GIF/animé
// Dimensions 1x en points (extraites de data.host.files dans l'API 7TV).
// Correspondent à la taille d'affichage cible dans le chat.
// 0 si non disponibles (anciennes entrées cache sans dimensions).
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@end

// ============================================================
// Interface principale du gestionnaire
// ============================================================
@interface SevenTVManager : NSObject

// Accès au singleton
+ (instancetype)sharedManager;

// --- Configuration ---
@property (nonatomic, assign) BOOL isEnabled;             // 7TV activé/désactivé
@property (nonatomic, assign) BOOL showAnimated;          // Afficher les emotes animées dans le chat
@property (nonatomic, assign) BOOL showPickerAnimations;  // Animer les emotes dans le picker
// Sous-option de showPickerAnimations : quand YES, seules les emotes de la
// section Favoris du picker sont animées (le reste reste statique). Sans
// effet si showPickerAnimations == NO (les deux réglages dépendent l'un de
// l'autre — voir SevenTVSettingsController pour le grisage correspondant).
@property (nonatomic, assign) BOOL showPickerAnimationsFavoritesOnly;
@property (nonatomic, assign) BOOL showFloatingButton;    // Afficher/masquer le bouton flottant 7TV
// Kill switch Phase 0 (plan chat custom) : quand ON, cache la vraie
// ChatTranscriptView et pose une vue flashy à sa place dans son UIStackView
// parent — test de validation du point d'insertion. OFF par défaut.
@property (nonatomic, assign) BOOL chatCustomTestEnabled;
@property (nonatomic, assign) BOOL debugLogging;          // NSLog console activé (mirroring Console.app)

// --- Logs : interrupteur global ---
// OFF = aucune ligne n'est enregistrée dans le buffer (peu importe les catégories
// ci-dessous), et les switches de catégories sont grisés dans l'UI — mais leurs
// valeurs restent inchangées en NSUserDefaults. "Voir les logs" reste accessible.
@property (nonatomic, assign) BOOL logsEnabled;

// --- Logs : catégories (chacune indépendante) ---
@property (nonatomic, assign) BOOL logErrors;            // 🚨 Erreurs / Avertissements — ON par défaut
@property (nonatomic, assign) BOOL logSwizzle;             // 🔌 Swizzle / Boot
@property (nonatomic, assign) BOOL logCache;               // ⚡️ Cache / Réseau
@property (nonatomic, assign) BOOL logPrefetch;            // 🚀 Prefetch
@property (nonatomic, assign) BOOL logAPI;                 // 🌍 API Emotes
@property (nonatomic, assign) BOOL logIRCChannel;          // 📡 IRC / Channel
@property (nonatomic, assign) BOOL logUIPicker;            // 🎨 UI / Picker
@property (nonatomic, assign) BOOL logFavorites;           // ⭐ Favoris
@property (nonatomic, assign) BOOL logOrientation;         // 🔒 Orientation Lock
@property (nonatomic, assign) BOOL logImageConversion;     // 🖼 CDN / Cache emotes
@property (nonatomic, assign) BOOL logChatCustom;           // 🏗 Chat Custom
@property (nonatomic, assign) BOOL logChannelPoints;         // 🎁 Channel Points
@property (nonatomic, assign) BOOL logDump;                // 🗑️ Dump

// --- Données des emotes ---
// Dictionnaire: @{ "KEKW": SevenTVEmote*, "Pog": SevenTVEmote*, ... }
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *globalEmotes;
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *channelEmotes;
@property (nonatomic, strong) NSString *currentChannelName;
@property (nonatomic, strong) NSString *currentChannelTwitchID;

// Pseudo Twitch (display-name) du viewer connecté dans l'app — alimenté par
// -handleIRCUserState: depuis les tags IRC USERSTATE/
// GLOBALUSERSTATE (envoyés par Twitch à la connexion et à chaque JOIN/
// message, tag display-name toujours présent). nil tant qu'aucun de ces
// deux messages IRC n'a encore été observé. Sert à détecter les mentions du
// viewer lui-même dans le chat (voir S7TVChatMessage.mentionsCurrentViewer).
@property (nonatomic, copy) NSString *currentViewerDisplayName;

// File de dispatch protégeant globalEmotes/channelEmotes (concurrent).
// Utiliser dispatch_sync(mgr.emoteQueue, ^{ ... }) pour lire,
// dispatch_barrier_async(mgr.emoteQueue, ^{ ... }) pour écrire.
@property (nonatomic, strong, readonly) dispatch_queue_t emoteQueue;

// --- Chat custom (Phase 1a+) ---
// Store des messages du chat en cours. Réinitialisé automatiquement à
// chaque changement de chaîne détecté (voir -handleIRCRoomState:) pour
// éviter qu'un message de l'ancienne chaîne fuite
// dans la nouvelle (exigence Phase 0).
@property (nonatomic, strong, readonly) S7TVChatMessageStore *chatMessageStore;

// --- Initialisation ---
- (void)setup;

// Relit les préférences déjà présentes dans NSUserDefaults sans les réécrire.
// Utilisé après l'import d'une sauvegarde pour appliquer immédiatement les
// réglages généraux, le bouton flottant, le chat custom et les favoris.
- (void)reloadPreferencesFromDefaults;

// --- Chargement des emotes ---
- (void)loadGlobalEmotes;
- (void)loadEmotesForChannelName:(NSString *)channelName;
- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID;

// --- Token Twitch (intercepté depuis les requêtes GQL) ---
// Stocké ici pour être réutilisé par SevenTVBadgeProvider (API Helix badges).
@property (nonatomic, copy, readonly) NSString *twitchToken;
@property (nonatomic, copy, readonly) NSString *twitchClientID;
- (void)saveTwitchToken:(NSString *)token clientID:(NSString *)clientID;

// Snapshot immuable du couple destiné à Helix. Les deux valeurs sont lues
// sous la même synchronisation et ne doivent pas être relues séparément.
- (NSDictionary<NSString *, NSString *> *)s7tv_twitchCredentialsSnapshot;

// Capture partielle : Authorization et Client-ID arrivent souvent via deux
// appels séparés (setValue:forHTTPHeaderField: appelé une fois par header).
// Chaque valeur est corrélée à l'objet source ; saveTwitchToken:clientID:
// n'est appelé en interne que lorsque les deux proviennent du même contexte.
- (void)s7tv_captureAuthorizationHeader:(NSString *)value context:(id)context;
- (void)s7tv_captureClientIDHeader:(NSString *)value context:(id)context;

// --- Extraction depuis réponses Twitch GQL ---
- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData;

// --- Favoris (IDs 7TV, persistés dans NSUserDefaults) ---
// Utilisé par SevenTVEmotePickerController — la donnée reste dans le manager,
// seule l'UI qui l'affiche/la modifie vit dans le picker.
- (BOOL)isEmoteFavorited:(NSString *)emoteID;
- (void)setEmote:(NSString *)emoteID favorited:(BOOL)favorited;
- (NSArray<NSString *> *)favoriteEmoteIDsSnapshot;
- (void)replaceFavoriteEmoteIDs:(NSArray<NSString *> *)emoteIDs;

// --- Accès aux emotes ---
// Retourne l'emote 7TV correspondant au nom, ou nil si pas trouvée
- (SevenTVEmote *)emoteForName:(NSString *)name;

// URL CDN pour une emote à la résolution 1x/2x/3x/4x choisie dans les
// réglages 7TV (2x par défaut).
- (NSURL *)cdnURLForEmote:(SevenTVEmote *)emote;

// --- UI ---
- (void)addSettingsButton;

// Ouvre l'écran de réglages (menu modal centré) — utilisé par le bouton
// flottant 7TV ET par le bouton réglages du picker d'emotes (voir
// 7tv-picker-controller.m), qui donne le même accès sans passer par le
// bouton flottant.
- (void)presentSettingsMenu;

// Affiche/masque le picker d'emotes 7TV au-dessus de la barre de saisie.
// chatInputView: la Twitch.ChatInputView (pour positionner le picker et insérer le nom).
- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;

// Appelé par le contrôleur du picker quand le stream se ferme
// (ChatInputView.window → nil).
// Nettoie le picker sans toucher au responder chain (UIKit crashe sans fenêtre).
- (void)cleanupPickerForStreamClose;
- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView;

// --- Logs ---
// log: classe automatiquement le message dans une S7TVLogCategory (par analyse
// du contenu — voir s7tv_categoryForMessage: dans le .m) puis :
//   - si logsEnabled == NO          → rien n'est enregistré
//   - si la catégorie correspondante == NO → rien n'est enregistré
//   - sinon → ajouté au buffer in-app, et envoyé à NSLog si debugLogging == YES
- (void)log:(NSString *)format, ...;

// Retourne une copie de toutes les lignes du buffer (thread-safe)
- (NSArray<NSString *> *)allLogs;

// Vide le buffer de logs
- (void)clearLogs;

// --- Cache ---
// Vide entièrement le cache des emotes 7TV : WebP mémoire/disque, images et
// animations décodées, chargements en cours, JSON des catalogues et
// dictionnaires en mémoire. Recharge ensuite les catalogues global/channel,
// tandis que les images ne reviennent qu'à la demande.
// N'affecte PAS les favoris (s7tv_favorites), les badges, ni les préférences
// de réglages.
- (void)clearAllCaches;
- (void)clearAllCachesWithCompletion:(void (^)(NSUInteger clearedEmoteCount))completion;

@end

// Cycle de vie de l'historique récent du salon. Le hook WebSocket transmet
// seulement les JOIN sortants ; le manager possède la génération, la requête
// réseau et la remise à zéro atomique du store.
@interface SevenTVManager (RecentChatHistory)
- (void)initializeRecentHistoryForChannel:(NSString *)channel force:(BOOL)force;
- (void)handleOutgoingChatWebSocketMessage:(NSURLSessionWebSocketMessage *)message;
@end

@interface SevenTVManager (IRCSessionState)
- (void)handleIncomingChatWebSocketText:(NSString *)text;
@end
