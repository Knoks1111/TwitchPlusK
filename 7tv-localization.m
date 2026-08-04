/*
 * 7tv-localization.m
 *
 * Voir 7tv-localization.h pour le contexte. Dictionnaire tenu à plat (une
 * seule table clé → {fr, en}) plutôt qu'un fichier par langue : plus simple
 * à maintenir pour ce volume de strings, et évite un risque de désync entre
 * deux fichiers séparés (clé présente en fr mais oubliée en en, etc.).
 */

#import "7tv-localization.h"

NSString *const S7TVLanguageDidChangeNotification = @"S7TVLanguageDidChangeNotification";

static NSString *const kS7TVLanguageDefaultsKey = @"s7tv_language";

@implementation S7TVLocalization {
    NSDictionary<NSString *, NSArray<NSString *> *> *_table; // clé → @[fr, en]
}

+ (instancetype)shared {
    static S7TVLocalization *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [S7TVLocalization new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self s7tv_buildTable];

        NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kS7TVLanguageDefaultsKey];
        // Défaut : français, comportement historique de l'app avant le
        // support anglais — pas de détection automatique de la langue
        // système, le choix reste 100% manuel (voir header).
        _currentLanguage = stored ? (S7TVLanguage)stored.integerValue : S7TVLanguageFrench;
    }
    return self;
}

- (void)setCurrentLanguage:(S7TVLanguage)currentLanguage {
    if (_currentLanguage == currentLanguage) return;
    _currentLanguage = currentLanguage;
    [[NSUserDefaults standardUserDefaults] setInteger:currentLanguage forKey:kS7TVLanguageDefaultsKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLanguageDidChangeNotification object:nil];
    });
}

- (NSString *)stringForKey:(NSString *)key {
    if (!key.length) return @"";
    NSArray<NSString *> *pair = _table[key];
    if (!pair) return key; // filet de sécurité — voir header
    NSUInteger idx = (self.currentLanguage == S7TVLanguageEnglish) ? 1 : 0;
    return pair[idx] ?: key;
}

#pragma mark - Table des traductions

- (void)s7tv_buildTable {
    _table = @{

        // ── Générique / réutilisé partout ──────────────────────────────
        @"common_ok":                       @[@"OK", @"OK"],
        @"common_cancel":                   @[@"Annuler", @"Cancel"],
        @"common_clear":                    @[@"Effacer", @"Clear"],
        @"common_empty_action":             @[@"Vider", @"Clear"],

        // ── Titres de page ──────────────────────────────────────────────
        @"title_7tv_settings":              @[@"7TV Settings", @"7TV Settings"],
        @"title_live_stream_control":       @[@"Live Stream Control", @"Live Stream Control"],
        @"title_emotes_7tv":                @[@"Emotes 7TV", @"7TV Emotes"],
        @"title_statistiques":              @[@"Statistiques", @"Statistics"],
        @"title_mes_favoris":               @[@"Mes favoris", @"My Favorites"],
        @"title_debogage":                  @[@"Débogage", @"Debug"],
        @"title_logs_7tv":                  @[@"Logs 7TV", @"7TV Logs"],

        // ── Bouton flottant / header (SevenTVSettingsController + TweakSevenTV) ──
        @"label_7tv_badge":                 @[@"7TV", @"7TV"],
        @"header_7tv_settings_caps":        @[@"7TV SETTINGS", @"7TV SETTINGS"],

        // ── Rechargement des emotes ─────────────────────────────────────
        @"action_reload_emotes":            @[@"Recharger les emotes", @"Reload emotes"],
        @"alert_reload_started_title":      @[@"Rechargement lancé", @"Reload started"],
        @"alert_reload_started_message":    @[@"Les emotes seront disponibles dans quelques secondes.",
                                               @"Emotes will be available in a few seconds."],

        // ── Live Stream Control ─────────────────────────────────────────
        @"subtitle_auto_collect":           @[@"Auto collect channel points", @"Auto collect channel points"],
        @"switch_auto_collect_title":       @[@"Auto Collect Channel Points", @"Auto Collect Channel Points"],
        @"desc_auto_collect":               @[@"Réclame automatiquement le coffre de points de chaîne quand il apparaît dans le chat.",
                                               @"Automatically claims the live channel-points chest when it appears in chat."],

        // ── Menu principal (Emotes / Stats / Debug) ─────────────────────
        @"menu_emotes_subtitle":            @[@"Animées, picker", @"Animated, picker"],
        @"menu_stats_subtitle":             @[@"Emotes chargées, channel actif", @"Loaded emotes, active channel"],
        @"menu_debug_subtitle":             @[@"Logs, tap logger, bouton flottant", @"Logs, tap logger, floating button"],

        // ── En-têtes de section ──────────────────────────────────────────
        @"section_general":                 @[@"Général", @"General"],
        @"section_affichage":               @[@"Affichage", @"Display"],
        @"section_channel_actif":           @[@"Channel actif", @"Active channel"],
        @"section_emotes_chargees":         @[@"Emotes chargées", @"Loaded emotes"],
        @"section_favoris":                 @[@"Favoris", @"Favorites"],
        @"section_options":                 @[@"Options", @"Options"],
        @"section_logs":                    @[@"Logs", @"Logs"],
        @"section_danger":                  @[@"Danger", @"Danger"],
        @"section_langue":                  @[@"Langue", @"Language"],

        // ── Switchs de réglages ───────────────────────────────────────────
        @"switch_enable_7tv":               @[@"Activer les emotes 7TV", @"Enable 7TV emotes"],
        @"switch_animated_chat":            @[@"Emotes animées dans le chat", @"Animated emotes in chat"],
        @"switch_animations_picker":        @[@"Animations dans le picker", @"Animations in picker"],
        @"switch_animations_favorites_only":@[@"Animations uniquement pour les favoris", @"Animations for favorites only"],
        @"switch_floating_button":          @[@"Bouton flottant 7TV", @"7TV floating button"],
        @"switch_chat_custom_test":         @[@"⚠️ Test chat custom (expérimental)", @"⚠️ Custom chat test (experimental)"],
        @"switch_enable_logs":              @[@"Activer les logs", @"Enable logs"],
        @"switch_logs_console":             @[@"Logs console (Console.app)", @"Console logs (Console.app)"],

        // ── Catégories de logs ────────────────────────────────────────────
        @"log_cat_errors":                  @[@"Erreurs / Avertissements", @"Errors / Warnings"],
        @"log_cat_tap":                     @[@"Tap Logger", @"Tap Logger"],
        @"log_cat_swizzle":                 @[@"Swizzle / Boot", @"Swizzle / Boot"],
        @"log_cat_cache":                   @[@"Cache / Réseau", @"Cache / Network"],
        @"log_cat_prefetch":                @[@"Prefetch", @"Prefetch"],
        @"log_cat_api":                     @[@"API Emotes", @"Emotes API"],
        @"log_cat_irc":                     @[@"IRC / Channel", @"IRC / Channel"],
        @"log_cat_ui_picker":               @[@"UI / Picker", @"UI / Picker"],
        @"log_cat_orientation":             @[@"Orientation Lock", @"Orientation Lock"],
        @"log_cat_cdn":                     @[@"CDN / Cache emotes", @"CDN / Emote cache"],
        @"log_cat_chat_custom":             @[@"Chat Custom", @"Custom Chat"],
        @"log_cat_dump":                    @[@"Dump", @"Dump"],

        // ── Page Favoris ──────────────────────────────────────────────────
        @"action_import_from_pc":           @[@"Importer depuis PC", @"Import from PC"],
        @"subtitle_import_from_pc":         @[@"Export JSON 7TV (Settings → … → Export)",
                                               @"7TV JSON export (Settings → … → Export)"],
        @"error_cant_read_file":            @[@"Impossible de lire le fichier.", @"Couldn't read the file."],
        @"error_invalid_json":              @[@"Le fichier n'est pas un JSON valide.", @"The file isn't valid JSON."],
        @"error_missing_favorites_key":     @[@"Clé « ui.emote_menu.favorites » introuvable.\nVérifie que c'est bien un export 7TV PC.",
                                               @"Key \"ui.emote_menu.favorites\" not found.\nMake sure this is a genuine 7TV PC export."],
        @"error_no_favorites_in_file":      @[@"Ce fichier ne contient pas d'emotes 7TV en favoris.",
                                               @"This file doesn't contain any favorited 7TV emotes."],
        @"empty_no_favorites":              @[@"Aucun favori pour l'instant.", @"No favorites yet."],
        @"alert_clear_favorites_title":     @[@"Vider les favoris", @"Clear favorites"],
        @"alert_clear_favorites_message":   @[@"Supprimer les %lu emotes en favoris ?",
                                               @"Remove %lu favorited emotes?"],

        // ── Page Logs (settings) ─────────────────────────────────────────
        @"view_logs":                       @[@"Voir les logs", @"View logs"],
        @"action_clear_all_logs":           @[@"Effacer tous les logs", @"Clear all logs"],
        @"alert_clear_logs_title":          @[@"Effacer les logs", @"Clear logs"],
        @"alert_irreversible":              @[@"Cette action est irréversible.", @"This action can't be undone."],

        // ── SevenTVLogsController ────────────────────────────────────────
        @"empty_no_logs":                   @[@"Aucun log pour l'instant.\nLes messages apparaîtront ici en temps réel.",
                                               @"No logs yet.\nMessages will appear here in real time."],
        @"button_copy_all":                 @[@"Copier tout", @"Copy all"],
        @"alert_clear_logs_confirm_title":  @[@"Effacer les logs ?", @"Clear logs?"],
        @"alert_clear_logs_confirm_message":@[@"Toutes les lignes seront supprimées du buffer.",
                                               @"All lines will be removed from the buffer."],
        @"buffer_empty":                    @[@"buffer vide", @"buffer empty"],
        @"buffer_one_line":                 @[@"1 ligne", @"1 line"],
        @"buffer_n_lines_format":           @[@"%ld lignes", @"%ld lines"],

        // ── Panneau des tailles (picker) ──────────────────────────────────
        @"size_label_emote_twitch":         @[@"Emotes Twitch", @"Twitch Emotes"],
        @"size_label_badges":               @[@"Badges", @"Badges"],
        @"size_label_username":             @[@"Texte pseudo", @"Username text"],
        @"size_label_message":              @[@"Texte message", @"Message text"],
        @"preview_username":                @[@"Pseudo", @"Username"],
        @"preview_greeting":                @[@"Salut !", @"Hi!"],

        // ── Picker : recherche ────────────────────────────────────────────
        @"alert_search_emote_title":        @[@"Rechercher une emote", @"Search for an emote"],
        @"action_search":                   @[@"Rechercher", @"Search"],
    };
}

@end

NSString *L(NSString *key) {
    return [[S7TVLocalization shared] stringForKey:key];
}
