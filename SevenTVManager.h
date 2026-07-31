/*
 * SevenTVManager.h
 * Gestionnaire principal de tout ce qui concerne 7TV.
 * C'est un "singleton" = une seule instance existe dans toute l'app.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class S7TVChatMessageStore;

// ============================================================
// CONFIGURATION - Modifie ces valeurs selon tes besoins
// ============================================================

// Mettre à 1 pour activer les logs de débogage dans la console
// (visible avec Console.app sur Mac ou via syslog)
#define S7TV_DEBUG 0

// Préfixe utilisé pour nos faux IDs d'emotes dans Twitch
// NE PAS MODIFIER - doit correspondre à SevenTVURLProtocol.m
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
// Catégories de logs
// ============================================================
// Chaque ligne loguée via -log: est classée automatiquement dans une de ces
// catégories (par analyse du contenu du message, voir s7tv_categoryForMessage:
// dans SevenTVManager.m). Chaque catégorie peut être activée/désactivée
// indépendamment depuis SevenTVDebugPageController.
typedef NS_ENUM(NSInteger, S7TVLogCategory) {
    S7TVLogCategoryError = 0,        // 🚨 Erreurs / Avertissements (❌ ⚠️) — toujours prioritaire
    S7TVLogCategoryTap,              // 👆 Tap Logger
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
@property (nonatomic, assign) BOOL showPickerAnimations;  // Animer les emotes dans le picker (favoris seulement)
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
@property (nonatomic, assign) BOOL logTap;                // 👆 Tap Logger
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
@property (nonatomic, assign) BOOL logDump;                // 🗑️ Dump

// --- Données des emotes ---
// Dictionnaire: @{ "KEKW": SevenTVEmote*, "Pog": SevenTVEmote*, ... }
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *globalEmotes;
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *channelEmotes;
@property (nonatomic, strong) NSString *currentChannelName;
@property (nonatomic, strong) NSString *currentChannelTwitchID;

// File de dispatch protégeant globalEmotes/channelEmotes (concurrent).
// Utiliser dispatch_sync(mgr.emoteQueue, ^{ ... }) pour lire,
// dispatch_barrier_async(mgr.emoteQueue, ^{ ... }) pour écrire.
@property (nonatomic, strong, readonly) dispatch_queue_t emoteQueue;

// --- Chat custom (Phase 1a+) ---
// Store des messages du chat en cours. Réinitialisé automatiquement à
// chaque changement de chaîne détecté (voir handleRoomState dans
// TweakSevenTV.m) pour éviter qu'un message de l'ancienne chaîne fuite
// dans la nouvelle (exigence Phase 0).
@property (nonatomic, strong, readonly) S7TVChatMessageStore *chatMessageStore;

// --- Initialisation ---
- (void)setup;

// --- Chargement des emotes ---
- (void)loadGlobalEmotes;
- (void)loadEmotesForChannelName:(NSString *)channelName;
- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID;

// --- Extraction depuis réponses Twitch GQL ---
- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData;

// --- Accès aux emotes ---
// Retourne l'emote 7TV correspondant au nom, ou nil si pas trouvée
- (SevenTVEmote *)emoteForName:(NSString *)name;

// URL CDN pour une emote (taille 4x pour Retina)
- (NSURL *)cdnURLForEmote:(SevenTVEmote *)emote;

// --- UI ---
- (void)addSettingsButton;

// Affiche/masque le picker d'emotes 7TV au-dessus de la barre de saisie.
// chatInputView: la Twitch.ChatInputView (pour positionner le picker et insérer le nom).
- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;

// Appelé par TweakSevenTV quand le stream se ferme (ChatInputView.window → nil).
// Nettoie le picker sans toucher au responder chain (UIKit crashe sans fenêtre).
- (void)cleanupPickerForStreamClose;

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

@end
