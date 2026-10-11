/*
 * tpK-localization-manager.m
 *
 * Voir tpK-localization-manager.h pour le contexte. Dictionnaire tenu à plat (une
 * seule table clé → {fr, en}) plutôt qu'un fichier par langue : plus simple
 * à maintenir pour ce volume de strings, et évite un risque de désync entre
 * deux fichiers séparés (clé présente en fr mais oubliée en en, etc.).
 */

#import "Localization/tpK-localization-manager.h"

NSString *const TPKLanguageDidChangeNotification = @"TPKLanguageDidChangeNotification";

static NSString *const kTPKLanguageDefaultsKey = @"tpk_language";

@implementation TPKLocalization {
    NSDictionary<NSString *, NSArray<NSString *> *> *_table; // clé → @[fr, en]
}

+ (instancetype)shared {
    static TPKLocalization *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [TPKLocalization new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self tpk_buildTable];

        NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kTPKLanguageDefaultsKey];
        // Défaut : anglais — pas de détection automatique de la langue
        // système, le choix reste 100% manuel (voir header).
        _currentLanguage = stored ? (TPKLanguage)stored.integerValue : TPKLanguageEnglish;
    }
    return self;
}

- (void)setCurrentLanguage:(TPKLanguage)currentLanguage {
    if (_currentLanguage == currentLanguage) return;
    _currentLanguage = currentLanguage;
    [[NSUserDefaults standardUserDefaults] setInteger:currentLanguage forKey:kTPKLanguageDefaultsKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKLanguageDidChangeNotification object:nil];
    });
}

- (NSString *)stringForKey:(NSString *)key {
    if (!key.length) return @"";
    NSArray<NSString *> *pair = _table[key];
    // Filet de sécurité VISIBLE (voir header) : [clé] plutôt que la clé nue
    // ou une chaîne vide — repérable à l'œil pendant les tests sans avoir à
    // grep le code pour savoir quelle traduction manque encore.
    if (!pair) return [NSString stringWithFormat:@"[%@]", key];
    NSUInteger idx = (self.currentLanguage == TPKLanguageEnglish) ? 1 : 0;
    NSString *value = pair[idx];
    return value.length ? value : [NSString stringWithFormat:@"[%@]", key];
}

#pragma mark - Table des traductions

- (void)tpk_buildTable {
    _table = @{
        @"update_title": @[@"Mise à jour disponible", @"Update available"],
        @"update_message": @[@"TwitchPlusK %@ est disponible.\nVersion installée : %@.\nConsultez la release pour l’installation.", @"TwitchPlusK %@ is available.\nInstalled version: %@.\nSee the release for installation instructions."],
        @"update_open": @[@"Voir la mise à jour", @"View update"],
        @"update_later": @[@"Plus tard", @"Later"],
        @"update_ignore": @[@"Ignorer cette version", @"Skip this version"],

        // ── Générique / réutilisé partout ──────────────────────────────
        @"common_ok":                       @[@"OK", @"OK"],
        @"common_cancel":                   @[@"Annuler", @"Cancel"],
        @"common_clear":                    @[@"Effacer", @"Clear"],
        @"common_empty_action":             @[@"Vider", @"Clear"],
        @"common_default_suffix":           @[@" - Par défaut", @" - Default"],

        // ── Titres de page ──────────────────────────────────────────────
        @"title_7tv_settings":              @[@"TwitchPlusK Settings", @"TwitchPlusK Settings"],
        @"title_apparence":                 @[@"Apparence", @"Appearance"],
        @"title_contenu":                   @[@"Contenu", @"Content"],
        @"title_adblock":                   @[@"Adblock", @"Adblock"], // terme déjà utilisé tel quel en français
        @"title_avance":                    @[@"Avancé", @"Advanced"],
        @"title_mes_favoris":               @[@"Mes favoris", @"My Favorites"],
        @"title_debogage":                  @[@"Débogage", @"Debug"],
        @"title_logs_7tv":                  @[@"Logs 7TV", @"7TV Logs"],

        // ── Bouton flottant / header (TPKSettingsController + TweakTPK) ──
        @"label_7tv_badge":                 @[@"7TV", @"7TV"],
        @"label_7tv_emotes":                @[@"Emotes 7TV", @"7TV Emotes"],
        @"label_twitchplusk_badge":         @[@"TwitchPlusK", @"TwitchPlusK"],
        @"header_7tv_settings_caps":        @[@"TWITCHPLUSK SETTINGS", @"TWITCHPLUSK SETTINGS"],

        // ── Cache (accueil → Avancé) ─────────────────────────────────────
        @"action_clear_cache":              @[@"Vider le cache", @"Clear cache"],
        @"cache_emote_count_format":        @[@"%ld emotes · %ldx", @"%ld emotes · %ldx"],
        @"alert_cache_cleared_title":       @[@"Cache vidé", @"Cache cleared"],
        @"alert_cache_cleared_message_format": @[@"%lu emotes ont été supprimées du cache. Elles se rechargeront à la demande.",
                                                   @"%lu emotes were removed from the cache. They will reload on demand."],

        // ── Résumé accueil (remplace l'ancien écran Statistiques) ────────
        @"summary_emotes_channel_format":   @[@"%lu emotes chargées · %@", @"%lu emotes loaded · %@"],

        // ── Contenu : accueil et lecture (TwitchAdBlock) ────────────────
        // La récupération auto des points (ex-section Stream) vit désormais
        // dans cette section.
        @"switch_auto_collect_title":       @[@"Récupération auto des points de chaîne", @"Auto Collect Channel Points"],
        @"desc_auto_collect":               @[@"Réclame automatiquement le coffre de points de chaîne quand il apparaît dans le chat.",
                                               @"Automatically claims the live channel-points chest when it appears in chat."],
        @"section_home_playback":           @[@"Accueil et lecture", @"Home & Playback"],
        @"setting_launch_screen":           @[@"Écran au lancement", @"Launch Screen"],
        @"launch_default":                  @[@"Par défaut", @"Default"],
        @"launch_home_following":           @[@"Accueil → Abonnements", @"Home → Following"],
        @"launch_home_live":                @[@"Accueil → Live", @"Home → Live"],
        @"launch_home_clips":               @[@"Accueil → Clips", @"Home → Clips"],
        @"launch_browse_categories":        @[@"Parcourir → Catégories", @"Browse → Categories"],
        @"launch_browse_live_channels":     @[@"Parcourir → Chaînes en direct", @"Browse → Live Channels"],
        @"launch_activity":                 @[@"Activité", @"Activity"],
        @"launch_profile":                  @[@"Profil", @"Profile"],
        @"switch_hide_twitch_stories":      @[@"Masquer les stories Twitch", @"Hide Twitch Stories"],
        @"switch_keep_live_feed_playing":   @[@"Continuer la lecture du fil Live", @"Keep Live Feed Playing"],

        // ── Barre d’onglets et écran de lancement (page Apparence) ──
        @"section_tab_bar":                 @[@"Barre d’onglets et lancement", @"Tab Bar & Launch"],
        @"tab_bar_header_launch":           @[@"Lancement", @"Launch"],
        @"tab_bar_header_visible":          @[@"Visibles", @"Visible"],
        @"tab_bar_open_with":               @[@"ouvre :", @"opens:"],
        @"tab_name_home":                   @[@"Accueil", @"Home"],
        @"tab_name_explore":                @[@"Parcourir", @"Browse"],
        @"tab_name_create":                 @[@"Création", @"Create"],
        @"tab_name_activity":               @[@"Activité", @"Activity"],
        @"tab_name_profile":                @[@"Profil", @"Profile"],
        @"tab_page_following":              @[@"Abonnements", @"Following"],
        @"tab_page_live":                   @[@"Live", @"Live"],
        @"tab_page_clips":                  @[@"Clips", @"Clips"],
        @"tab_page_categories":             @[@"Catégories", @"Categories"],
        @"tab_page_live_channels":          @[@"Chaînes live", @"Live Channels"],
        @"desc_tab_bar":                    @[@"Les onglets masqués sont retirés de la barre et les autres se répartissent d’eux-mêmes. Il reste toujours au moins un onglet. Si l’onglet utilisé comme écran de lancement est masqué, la destination bascule sur un onglet visible. Le nouvel écran de lancement s’applique au prochain démarrage.",
                                               @"Hidden tabs are removed from the bar and the remaining ones lay themselves out. At least one tab always stays visible. If the tab used as Launch Screen is hidden, the destination moves to a visible tab. The new Launch Screen applies after restarting."],
        @"alert_tab_bar_min_message":       @[@"Au moins un onglet doit rester visible.", @"At least one tab must stay visible."],
        @"tab_hidden_badge":               @[@"Masqué", @"Hidden"],
        @"alert_launch_destination_moved":  @[@"L’onglet utilisé comme écran de lancement est masqué : la destination a été déplacée vers « %@ ».",
                                               @"The tab used as Launch Screen is hidden: the destination moved to \"%@\"."],
        @"desc_home_playback_settings":     @[@"Le fil Live ne sera plus interrompu par l’écran Regarder/Suivre. Les changements des stories s’appliquent au prochain démarrage.",
                                               @"The Live feed will no longer be interrupted by the Watch/Follow screen. Stories changes apply after restarting."],
        @"section_player_controls":         @[@"Lecteur et contrôles", @"Player & Controls"],
        @"player_tools_enable":             @[@"Bouton pour rattraper le délai", @"Button to reduce stream delay"],
        @"desc_player_tools":               @[@"Affiche un bouton pour rattraper le délai du stream et revenir au direct.",
                                               @"Show a button to reduce stream delay and return to live."],
        @"player_stats_enable":             @[@"Video player stats", @"Video player stats"],
        @"desc_player_stats":               @[@"Affiche les statistiques du lecteur vidéo.",
                                               @"Show video player statistics."],
        @"player_gestures_enable":          @[@"Gestes sur le lecteur", @"Player gestures"],
        @"player_gestures_left_side":       @[@"Côté gauche", @"Left side"],
        @"player_gestures_right_side":      @[@"Côté droit", @"Right side"],
        @"player_gestures_assignment_disabled": @[@"Désactivé", @"Disabled"],
        @"player_gestures_assignment_volume":   @[@"Volume", @"Volume"],
        @"player_gestures_assignment_brightness": @[@"Luminosité", @"Brightness"],
        @"player_gestures_sensitivity":     @[@"Sensibilité des gestes", @"Gesture sensitivity"],
        @"player_gestures_sensitivity_decrease": @[@"Diminuer la sensibilité", @"Decrease sensitivity"],
        @"player_gestures_sensitivity_increase": @[@"Augmenter la sensibilité", @"Increase sensitivity"],
        @"player_gestures_dead_zone":       @[@"Zone morte", @"Dead zone"],
        @"desc_player_gestures":            @[@"Faites glisser verticalement sur la vidéo. Les côtés et les fonctions se règlent ci-dessous.",
                                               @"Swipe vertically on the video. Configure the sides and features below."],
        @"player_gestures_sensitivity_message": @[@"Réglez la variation par pourcentage avec les boutons − et +, de 1 à 5 %.",
                                                    @"Adjust the percentage change with the − and + buttons, from 1 to 5%."],
        @"player_gestures_dead_zone_message": @[@"Distance minimale à parcourir avant que le geste agisse.",
                                                   @"Minimum distance before the gesture takes effect."],
        @"player_gestures_volume_format":    @[@"Volume : %.0f%%", @"Volume: %.0f%%"],
        @"player_gestures_brightness_format": @[@"Luminosité : %.0f%%", @"Brightness: %.0f%%"],

        // ── Contenu : verrouillage de rotation (fusionné dans « Accueil et
        //    lecture » ; le bouton de verrouillage reprend la description) ──
        @"switch_orientation_lock_button":  @[@"Bouton de verrouillage", @"Rotation lock button"],
        @"setting_orientation_auto_lock":   @[@"Verrouillage automatique", @"Automatic locking"],
        @"orientation_mode_disabled":        @[@"Désactivé", @"Disabled"],
        @"orientation_mode_manual":          @[@"Manuel", @"Manual"],
        @"orientation_mode_auto_left":       @[@"Automatique à gauche", @"Automatic left"],
        @"orientation_mode_auto_right":      @[@"Automatique à droite", @"Automatic right"],
        @"orientation_mode_auto_both":       @[@"Automatique des deux côtés", @"Automatic both sides"],
        @"orientation_auto_off":            @[@"Désactivé", @"Off"],
        @"orientation_left":                @[@"Gauche", @"Left"],
        @"orientation_right":               @[@"Droite", @"Right"],
        @"orientation_both":                @[@"Les deux", @"Both"],
        @"desc_orientation_lock_settings":  @[@"Lorsqu’il est activé, le bouton apparaît sur le lecteur. Choisissez le mode manuel ou le verrouillage automatique à gauche, à droite ou des deux côtés.",
                                               @"When enabled, the button appears on the player. Choose manual locking or automatic locking on the left, right, or both sides."],

        // ── Adblock vidéo / proxy ────────────────────────────────────────
        @"adblock_enable":                  @[@"Activer l’adblock", @"Enable adblock"],
        @"adblock_cell_title":              @[@"AdBlock", @"AdBlock"],
        @"adblock_hide_go_ad_free":         @[@"Masquer Twitch Turbo", @"Hide Twitch Turbo"],
        @"adblock_section_proxy":           @[@"Proxy vidéo", @"Video proxy"],
        @"adblock_video_proxy":             @[@"Utiliser le proxy vidéo", @"Use video proxy"],
        @"adblock_default_proxy":           @[@"Proxy vidéo par défaut", @"Default video proxy"],
        @"adblock_proxy_builtin":            @[@"proxy instable (secours)", @"unstable proxy (backup)"],
        @"adblock_proxy_eu":                 @[@"eu.luminous.dev", @"eu.luminous.dev"],
        @"adblock_proxy_eu2":                @[@"eu2.luminous.dev", @"eu2.luminous.dev"],
        @"adblock_proxy_rte4":               @[@"proxy4.rte.net.ru", @"proxy4.rte.net.ru"],
        @"adblock_proxy_rte5":               @[@"proxy5.rte.net.ru", @"proxy5.rte.net.ru"],
        @"adblock_proxy_rte6":               @[@"proxy6.rte.net.ru", @"proxy6.rte.net.ru"],
        @"adblock_proxy_rte7":               @[@"proxy7.rte.net.ru", @"proxy7.rte.net.ru"],
        @"adblock_default_proxy_footer":     @[@"Les proxys par défaut sont publics : ils peuvent être temporairement indisponibles ou instables.",
                                                @"Default proxies are public and may be temporarily unavailable or unstable."],
        @"adblock_custom_proxy":            @[@"Proxy personnalisé", @"Custom proxy"],
        @"adblock_emote_proxy":             @[@"Proxy emotes", @"Emote proxy"],
        @"adblock_emote_proxy_info":        @[@"À activer uniquement si votre pays bloque 7TV, BTTV ou FFZ. Sinon, laissez désactivé.",
                                               @"Enable only if your country blocks 7TV, BTTV, or FFZ. Otherwise, leave it off."],
        @"adblock_emote_section":            @[@"Proxy emotes", @"Emote proxy"],
        @"adblock_emote_default_proxy":      @[@"Proxy emotes par défaut", @"Default emote proxy"],
        @"adblock_emote_proxy_footer":       @[@"Indépendant du proxy vidéo : les emotes peuvent passer par un proxy différent. Seuls les proxys de style préfixe sont utilisés, les autres choix restent en direct.",
                                                @"Independent from the video proxy: emotes can use a different proxy. Only prefix-style proxies are used, other choices stay direct."],
        @"adblock_proxy_default_status":     @[@"Proxy par défaut", @"Default proxy"],
        @"adblock_proxy_custom_status":      @[@"Proxy personnalisé", @"Custom proxy"],
        @"adblock_proxy_status_online":      @[@"● En ligne", @"● Online"],
        @"adblock_proxy_status_offline":     @[@"● Hors ligne", @"● Offline"],
        @"adblock_proxy_status_checking":    @[@"Vérification…", @"Checking…"],
        @"adblock_proxy_status_unknown":     @[@"—", @"—"],
        @"adblock_proxy_status_ping":        @[@"Tester", @"Ping"],
        @"adblock_proxy_delete":             @[@"Supprimer ce proxy", @"Delete this proxy"],
        @"adblock_proxy_add":                @[@"+ Ajouter un proxy", @"+ Add proxy"],
        @"adblock_local_no_proxy":            @[@"Cette méthode d’AdBlock ne nécessite aucune configuration supplémentaire.",
                                                 @"This AdBlock method requires no additional configuration."],

        // ── Méthode AdBlock : Proxy / Local (VAFT) ────────────────────────
        // La méthode configurée ne s'applique qu'au prochain démarrage.
        @"adblock_method_title":             @[@"Méthode AdBlock", @"AdBlock Method"],
        @"adblock_method_value_proxy":       @[@"Proxy", @"Proxy"],
        @"adblock_method_value_disabled":    @[@"Disabled", @"Disabled"],
        @"adblock_method_value_local":       @[@"Local (VAFT)", @"Local (VAFT)"],
        @"adblock_method_value_combo":       @[@"Proxy + Local (VAFT)", @"Proxy + Local (VAFT)"],
        @"adblock_restart_title":            @[@"Redémarrage requis", @"Restart required"],
        @"adblock_restart_disabled_msg":     @[@"Pour activer Disabled, redémarrez Twitch.",
                                              @"To activate Disabled, restart Twitch."],
        @"adblock_restart_proxy_msg":        @[@"Pour activer Proxy, redémarrez Twitch.",
                                                @"To activate Proxy, restart Twitch."],
        @"adblock_restart_local_msg":        @[@"Pour activer Local (VAFT), redémarrez Twitch.",
                                                @"To activate Local (VAFT), restart Twitch."],
        @"adblock_restart_combo_msg":        @[@"Pour activer Proxy + Local (VAFT), redémarrez Twitch.",
                                                @"To activate Proxy + Local (VAFT), restart Twitch."],
        @"adblock_combo_section":            @[@"Proxy combo", @"Combo proxy"],
        @"adblock_combo_default_proxy":      @[@"Proxy relais", @"Relay proxy"],
        @"adblock_combo_footer":             @[@"Mode expert : proxy (accès qualité max) + VAFT (AdBlock). Inutile sauf si votre pays bloque Twitch ou la 1440p, sinon utilisez les autres modes.",
                                                @"Expert mode: proxy (max quality access) + VAFT (AdBlock). Useless unless your country blocks Twitch or 1440p, otherwise prefer the other modes."],

        // ── Diagnostics VAFT (moteur TASDiagnostics distinct) ─────────────
        @"vaft_diag_header":                 @[@"Diagnostics VAFT", @"VAFT Diagnostics"],
        @"vaft_diag_scope_note":             @[@"Ces diagnostics couvrent le moteur Local (VAFT).",
                                                @"These diagnostics cover the Local (VAFT) engine."],
        @"vaft_diag_logging":                @[@"Journal de diagnostic", @"Diagnostic Logging"],
        @"vaft_diag_view":                   @[@"Voir le rapport de diagnostic", @"View Diagnostic Report"],
        @"vaft_diag_view_sub":               @[@"Résumé de session et journal assaini",
                                                @"Session summary and sanitized event log"],
        @"vaft_diag_copy":                   @[@"Copier le rapport de diagnostic", @"Copy Diagnostic Report"],
        @"vaft_diag_copy_sub":               @[@"Copie le rapport complet vers le presse-papiers",
                                                @"Copies the complete report to the clipboard"],
        @"vaft_diag_clear":                  @[@"Effacer le journal de diagnostic", @"Clear Diagnostic Log"],
        @"vaft_diag_cleared_title":          @[@"Effacé", @"Cleared"],
        @"vaft_diag_cleared_msg":            @[@"Le journal de diagnostic a été effacé.",
                                                @"The stored diagnostic event log was cleared."],
        @"vaft_diag_copied_title":           @[@"Copié", @"Copied"],
        @"vaft_diag_copied_msg":             @[@"Le rapport de diagnostic a été copié.",
                                                @"The diagnostic report was copied to the clipboard."],
        @"vaft_diag_footer":                 @[@"Enregistre les chemins de requêtes assainis, les statuts de réponse, les résumés de marqueurs de manifest et les décisions VAFT. Les query strings, en-têtes, tokens d'accès et contenus de manifest ne sont jamais stockés. Le journal est limité à 512 Ko.",
                                                @"Records sanitized request paths, response status, manifest marker summaries, and VAFT decisions. Query strings, headers, access tokens, and manifest contents are never stored. The log is capped at 512 KiB."],
        @"vaft_report_title":                @[@"Rapport de diagnostic", @"Diagnostic Report"],
        @"adblock_engine_footer":           @[@"Trois méthodes de blocage vidéo : Proxy (tout-en-un), Local VAFT (tout-en-local), ou Combo (proxy relais non filtrant pour l’accès/qualité + VAFT pour l’anti-pub).",
                                               @"Three video ad-blocking methods: Proxy (all-in-one), Local VAFT (all-local), or Combo (non-filtering relay proxy for access/quality + VAFT for ad decisions)."],
        @"adblock_proxy_privacy_footer":    @[@"Le proxy sert à récupérer les playlists vidéo sans publicité. En mode personnalisé, chaque proxy occupe une ligne et l’ordre définit leur priorité.",
                                               @"The proxy fetches ad-free video playlists. In custom mode, each proxy has its own row and the order defines priority."],

        // ── Menu principal (Apparence / Contenu / Adblock / Avancé) ──────
        @"menu_apparence_subtitle":         @[@"Émotes et thème", @"Emotes and theme"],
        @"menu_contenu_subtitle":           @[@"Favoris, lecture et plus", @"Favorites, playback, and more"],
        @"menu_adblock_subtitle":           @[@"Proxy, Local ou Combo", @"Proxy, Local or Combo"],
        @"menu_avance_subtitle":            @[@"Cache, logs et plus", @"Cache, logs, and more"],

        // ── Page Apparence : où trouver les réglages du chat custom ──────
        @"desc_chat_custom_location":       @[
            @"Les réglages du chat custom se trouvent dans le chat d’une chaîne : appuie sur le bouton 7TV à côté de la barre de saisie, puis sur « Aa » en bas à droite du sélecteur d’emotes.",
            @"Custom chat settings are found in a channel’s chat: tap the 7TV button next to the input bar, then tap “Aa” at the bottom right of the emote picker."
        ],

        // ── En-têtes de section ──────────────────────────────────────────
        @"section_general":                 @[@"Général", @"General"],
        @"section_emotes":                  @[@"Émotes", @"Emotes"],
        @"section_interface":               @[@"Interface", @"Interface"],
        @"section_tools":                   @[@"Outils", @"Tools"],
        @"section_favoris":                 @[@"Favoris", @"Favorites"],
        @"section_options":                 @[@"Options", @"Options"],
        @"section_settings_backup":         @[@"Sauvegarde", @"Backup"],
        @"section_logs":                    @[@"Logs", @"Logs"],
        @"section_langue":                  @[@"Langue et GitHub", @"Language & GitHub"],
        @"settings_github_title":           @[@"GitHub repository", @"GitHub repository"],
        @"settings_github_subtitle":        @[@"Ajoute une étoile, signale un bug ou propose une idée.",
                                               @"Star, report bugs, or suggest improvements."],

        // ── Switchs de réglages ───────────────────────────────────────────
        @"switch_chat_custom":              @[@"Chat custom (debug)", @"Custom chat (debug)"],
        @"switch_oled_mode":                @[@"Mode OLED", @"OLED Mode"],
        @"desc_oled_mode":                  @[
            @"Remplace les fonds du thème sombre de Twitch par du noir pur. Le thème clair n'est pas modifié.",
            @"Replaces Twitch's dark-theme backgrounds with pure black. Light theme is unchanged."
        ],
        @"oled_restart_title":              @[@"Redémarrage requis", @"Restart required"],
        @"oled_restart_message":            @[
            @"Redémarrez Twitch pour appliquer complètement le changement du mode OLED.",
            @"Restart Twitch to fully apply the OLED mode change."
        ],
        @"switch_animations_picker":        @[@"Animations dans le picker", @"Animations in picker"],
        @"switch_animations_favorites_only":@[@"Animations uniquement pour les favoris", @"Animations for favorites only"],
        @"picker_animations_message":       @[@"Choisissez quand les emotes animées doivent être affichées.", @"Choose when animated emotes should be displayed."],
        @"picker_animations_disabled":      @[@"Désactivées", @"Disabled"],
        @"picker_animations_enabled":       @[@"Activées", @"Enabled"],
        @"picker_animations_favorites_only":@[@"Activées uniquement pour les favoris", @"Enabled for favorites only"],
        @"setting_emote_resolution":        @[@"Résolution des emotes", @"Emote resolution"],
        @"setting_emote_zero_width":        @[@"Emotes 7TV Zero-Width", @"7TV Zero-Width emotes"],
        @"setting_emote_providers":          @[@"Fournisseurs d’emotes", @"Emote providers"],
        @"setting_emote_providers_none":     @[@"Aucun provider", @"No providers"],
        @"setting_emote_provider_priority": @[@"Priorité des providers", @"Provider priority"],
        @"setting_emote_provider_priority_message": @[@"Choisissez quel provider gagne en cas de doublon.", @"Choose which provider wins when emote names collide."],
        @"setting_emote_picker_opening":    @[@"Ouverture du picker", @"Picker opening"],
        @"setting_emote_picker_opening_message": @[@"Choisissez l'onglet affiché à l'ouverture du picker.", @"Choose which tab is shown when the picker opens."],
        @"setting_emote_picker_mixed":       @[@"Tous les providers dans un onglet", @"All providers in one tab"],
        @"picker_opening_favorites":        @[@"Favoris", @"Favorites"],
        @"picker_opening_7tv_channel":      @[@"7TV — Channel", @"7TV — Channel"],
        @"picker_opening_bttv_channel":     @[@"BTTV — Channel", @"BTTV — Channel"],
        @"picker_opening_ffz_channel":      @[@"FFZ — Channel", @"FFZ — Channel"],
        @"picker_opening_last_used":        @[@"Dernier menu utilisé", @"Last used menu"],
        @"common_done":                      @[@"Terminé", @"Done"],
        @"setting_resolution_clears_cache": @[
            @"Une résolution élevée est plus nette, mais utilise plus de stockage et de mémoire et peut provoquer des ralentissements. Le changement vide le cache et s'applique sans redémarrage.",
            @"Higher resolutions look sharper, but use more storage and memory and may cause lag. Changing it clears the cache and applies without restarting."
        ],
        @"switch_floating_button":          @[@"Bouton flottant", @"Floating button"],
        @"switch_enable_logs":              @[@"Activer les logs", @"Enable logs"],
        @"switch_logs_console":             @[@"Logs console (Console.app)", @"Console logs (Console.app)"],

        // ── Sauvegarde / restauration des réglages ────────────────────────
        @"settings_export":                 @[@"Exporter les réglages", @"Export settings"],
        @"settings_export_subtitle":        @[@"Tous les réglages, favoris et proxy", @"All settings, favorites, and proxy"],
        @"settings_import":                 @[@"Importer les réglages", @"Import settings"],
        @"settings_import_subtitle":        @[@"Restaurer un fichier TwitchPlusK", @"Restore a TwitchPlusK file"],
        @"settings_export_failed_title":    @[@"Export impossible", @"Couldn't export"],
        @"settings_export_failed_message":  @[@"Impossible de créer le fichier de réglages.", @"Couldn't create the settings file."],
        @"settings_import_failed_title":    @[@"Import impossible", @"Couldn't import"],
        @"settings_import_invalid_file":    @[@"Ce fichier n'est pas une sauvegarde TwitchPlusK valide.", @"This file isn't a valid TwitchPlusK backup."],
        @"settings_import_success_title":   @[@"Import terminé", @"Import complete"],
        @"settings_import_success_message_format": @[@"%lu réglages importés.", @"%lu settings imported."],

        // ── Diagnostics des hooks ─────────────────────────────────────────
        @"diagnostics_title":               @[@"Diagnostics", @"Diagnostics"],
        @"diagnostics_subtitle":            @[@"Vérifier les APIs d'emotes et les hooks Twitch détectés", @"Check emote APIs and detected Twitch hooks"],
        @"diagnostics_autoclaim_group":     @[@"Auto Claim", @"Auto Claim"],
        @"diagnostics_autoclaim_subtitle":  @[@"État du watcher et du coffre RN", @"RN watcher and chest state"],
        @"diagnostics_autoclaim_rn_host":    @[@"Hôte chat RN détecté", @"RN chat host detected"],
        @"diagnostics_autoclaim_rn_chest":   @[@"Coffre RN réclamable visible", @"RN claimable chest visible"],
        @"diagnostics_autoclaim_watcher":    @[@"Watcher Auto Claim actif", @"Auto Claim watcher active"],
        @"diagnostics_autoclaim_balance":    @[@"Solde Channel Points", @"Channel Points balance"],
        @"diagnostics_autoclaim_yes":        @[@"Oui", @"Yes"],
        @"diagnostics_autoclaim_no":         @[@"Non", @"No"],
        @"diagnostics_header":              @[@"Classes Twitch hookées (cette version)", @"Hooked Twitch classes (this build)"],
        @"diagnostics_group_emote_providers": @[@"APIs des emotes", @"Emote APIs"],
        @"diagnostics_group_proxy":          @[@"Proxy AdBlock", @"AdBlock Proxy"],
        @"diagnostics_group_vaft":           @[@"Local (VAFT) AdBlock", @"Local (VAFT) AdBlock"],
        @"diagnostics_group_twitchplusk":    @[@"TwitchPlusK", @"TwitchPlusK"],
        @"diagnostics_ok":                  @[@"✓ OK", @"✓ OK"],
        @"diagnostics_missing":             @[@"✗ absente", @"✗ missing"],
        @"diagnostics_inactive":            @[@"— non actif", @"— inactive"],
        @"diagnostics_api_loading":         @[@"Chargement…", @"Loading…"],
        @"diagnostics_api_not_loaded":      @[@"Non chargé", @"Not loaded"],
        @"diagnostics_api_error":            @[@"Erreur", @"Error"],
        @"diagnostics_api_ok_count":        @[@"✓ OK · %ld emotes", @"✓ OK · %ld emotes"],
        @"diagnostics_footer":              @[@"✓ = la classe et le selector ciblés sont résolus (compatibilité de la cible uniquement ; pour une classe dynamique, cela confirme sa création). ✗ = cible attendue absente alors que le moteur est actif. — = moteur non actif, donc non applicable.",
                                               @"✓ = the target class and selector resolved (target compatibility only; for a dynamic class, this confirms its creation). ✗ = expected target absent while the engine is active. — = engine inactive, therefore not applicable."],

        // ── Catégories de logs ────────────────────────────────────────────
        @"log_cat_errors":                  @[@"Erreurs / Avertissements", @"Errors / Warnings"],
        @"log_cat_chat_custom":             @[@"Chat Custom", @"Custom Chat"],
        @"log_cat_channel_points":          @[@"Channel Points", @"Channel Points"],
        @"log_cat_tap":                     @[@"Tap Logger", @"Tap Logger"],

        // ── Page Favoris ──────────────────────────────────────────────────
        @"action_import_from_pc":           @[@"Importer depuis PC", @"Import from PC"],
        @"subtitle_import_from_pc":         @[@"7TV on PC ( Settings → Export )",
                                               @"7TV on PC ( Settings → Export )"],
        @"error_cant_read_file":            @[@"Impossible de lire le fichier.", @"Couldn't read the file."],
        @"error_invalid_json":              @[@"Le fichier n'est pas un JSON valide.", @"The file isn't valid JSON."],
        @"error_missing_favorites_key":     @[@"Clé « ui.emote_menu.favorites » introuvable.\nVérifie que c'est bien un export 7TV PC.",
                                               @"Key \"ui.emote_menu.favorites\" not found.\nMake sure this is a genuine 7TV PC export."],
        @"error_no_favorites_in_file":      @[@"Ce fichier ne contient pas d'emotes 7TV en favoris.",
                                               @"This file doesn't contain any favorited 7TV emotes."],
        @"empty_no_favorites":              @[@"Aucun favori pour l'instant.", @"No favorites yet."],
        @"favorites_count_format":          @[@"%lu emote(s) en favoris", @"%lu favorited emote(s)"],
        @"favorite_emote_unknown":          @[@"Emote non chargée", @"Emote not loaded"],
        @"favorite_emote_loading":          @[@"Chargement du nom…", @"Loading name…"],
        @"chat_emote_add_favorite":         @[@"Ajouter aux favoris", @"Add to favorites"],
        @"chat_emote_remove_favorite":      @[@"Retirer des favoris", @"Remove from favorites"],
        @"alert_clear_favorites_title":     @[@"Vider les favoris", @"Clear favorites"],
        @"alert_clear_favorites_message":   @[@"Supprimer les %lu emotes en favoris ?",
                                               @"Remove %lu favorited emotes?"],

        // ── Page Logs (settings) ─────────────────────────────────────────
        @"view_logs":                       @[@"Voir les logs", @"View logs"],
        @"logs_copy_empty":                 @[@"Aucun log à copier", @"No logs to copy"],
        @"logs_copy_success":               @[@"✅ Logs copiés !", @"✅ Logs copied!"],
        // L'effacement des logs vit dans l'écran « Voir les logs » (bouton
        // « Effacer », voir TPKLogsController).

        // ── TPKLogsController ────────────────────────────────────────
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
        @"title_emotes_7tv":                @[@"Emotes 7TV", @"7TV emotes"],
        @"size_label_emote_twitch":         @[@"Emotes Twitch", @"Twitch Emotes"],
        @"size_label_gif":                   @[@"GIFs Twitch", @"Twitch GIFs"],
        @"size_label_badges":               @[@"Badges", @"Badges"],
        @"size_label_username":             @[@"Texte pseudo", @"Username text"],
        @"size_label_message":              @[@"Texte message", @"Message text"],
        @"size_label_line_spacing":         @[@"Espacement des messages", @"Message spacing"],
        @"size_label_username_message_spacing": @[@"Espacement pseudo/texte", @"Username/message spacing"],
        @"size_label_emote_offset":         @[@"Alignement des emotes", @"Emote alignment"],
        @"size_label_picker_height":        @[@"Taille du picker", @"Picker size"],
        @"size_label_picker_emote_size":   @[@"Taille des emotes", @"Emote size in picker"],
        @"picker_orientation_portrait":     @[@"Portrait", @"Portrait"],
        @"picker_orientation_landscape":    @[@"Paysage", @"Landscape"],
        @"preview_7tv_prefix":              @[@"7TV: ", @"7tv: "],
        @"preview_username":                @[@"Pseudo", @"Username"],
        @"preview_greeting":                @[@"Salut !", @"Hi!"],
        @"preview_gif_username":            @[@"GIFViewer", @"GIFViewer"],
        @"preview_gif_text":                @[@"regardez ce GIF !", @"check out this GIF!"],
        @"sizes_preview_section_title":     @[@"Aperçu", @"Preview"],
        @"sizes_colors_section_title":      @[@"Couleurs des messages système", @"System message colors"],
        @"sizes_colors_toggle_label":       @[@"Fonds colorés", @"Colored backgrounds"],
        @"sizes_color_sub_resub":           @[@"Abonnement", @"Subscription"],
        @"sizes_color_prime":               @[@"Prime", @"Prime"],
        @"sizes_color_gift":                @[@"Cadeau collectif", @"Community gift"],
        // Ligne fondue dans la section ci-dessus (plus de section dédiée —
        // voir tpK-picker-settings-panel.m, _buildSelfMentionSectionInScrollView:).
        @"sizes_self_mention_row_label":    @[@"Vous êtes mentionné", @"You're mentioned"],
        @"sizes_first_message_row_label":   @[@"Premier message", @"First message"],
        @"sizes_shared_chat_avatars_label": @[@"Avatars du chat partagé", @"Shared Chat avatars"],
        @"sizes_moderation_section_title":  @[@"Messages supprimés", @"Deleted messages"],
        @"sizes_deleted_preview_label":     @[@"Preview", @"Preview"],
        @"sizes_deleted_preview_disabled":  @[@"Désactivé", @"Disabled"],
        @"sizes_deleted_preview_tap":       @[@"Au toucher", @"On tap"],
        @"sizes_deleted_preview_revealed":  @[@"Révélé", @"Revealed"],
        @"sizes_deleted_style_label":       @[@"Style du message révélé", @"Revealed message style"],
        @"sizes_deleted_style_dimmed":      @[@"Atténué", @"Dimmed"],
        @"sizes_deleted_style_struck":      @[@"Barré", @"Struck"],
        @"sizes_deleted_style_both":        @[@"Les deux", @"Both"],
        @"sizes_moderation_details_label":  @[@"Afficher timeout / ban", @"Show timeout / ban"],
        @"sizes_deleted_opacity_label":     @[@"Opacité du message révélé", @"Revealed message opacity"],
        @"sizes_category_sizes":            @[@"Tailles", @"Sizes"],
        @"sizes_category_appearance":       @[@"Apparence", @"Appearance"],
        @"sizes_category_moderation":       @[@"Modération", @"Moderation"],
        @"preview_sub_phrase":              @[@"a pris un abonnement de niveau 1. C'est son 3e mois d'abonnement !",
                                               @"subscribed at Tier 1. This is their 3rd month!"],
        @"preview_prime_phrase":            @[@"s'est abonné(e) avec Prime. C'est son 24e mois d'abonnement !",
                                               @"subscribed with Prime. This is their 24th month!"],
        @"preview_gift_phrase":             @[@"offre 5 abonnements à la communauté !",
                                               @"is gifting 5 subs to the community!"],
        @"preview_deleted_message":         @[@"message de test", @"test message"],
        // Cible du message de démo "mention de soi" (mentionsCurrentViewer)
        // du faux chat — voir tpK-picker-settings-panel.m, _populateFakeChatStore:.
        @"preview_mention_target":          @[@"@Toi", @"@You"],
        @"preview_username_2":              @[@"Viewer_92", @"Viewer_92"],
        @"preview_username_3":              @[@"Modo_Chill", @"Modo_Chill"],
        @"preview_message_2":               @[@"quelqu'un a vu le dernier clip ?", @"anyone see the latest clip?"],
        @"preview_first_message_username":  @[@"NouveauViewer", @"NewViewer"],
        @"preview_first_message_text":      @[@"c'est mon premier message ici !", @"this is my first message here!"],
        @"preview_sub_comment":             @[@"trop hype ce stream", @"this stream is so hype"],
        @"preview_prime_comment":           @[@"24 mois, toujours là !", @"24 months, still here!"],

        // ── Messages système sub/resub/gift (tpK-core-runtime-hooks.m,
        // tpk_buildSystemMessagePhrase) — reconstruits nous-mêmes depuis les
        // champs IRC msg-param-*, pas depuis system-msg= (voir commentaire de
        // la fonction). %ld/%@ dans l'ordre où le code les insère.
        @"sysmsg_verb_sub_tier":            @[@"a pris un abonnement", @"subscribed"],
        @"sysmsg_verb_sub_prime":           @[@"s'est abonné(e)", @"subscribed"],
        @"sysmsg_plan_prime":               @[@"avec Prime", @"with Prime"],
        @"sysmsg_plan_tier_format":         @[@"de niveau %ld", @"at Tier %ld"],
        @"sysmsg_first_sub_format":         @[@"%@ %@ !", @"%@ %@!"],
        @"sysmsg_resub_format":             @[@"%@ %@. C'est son %@ mois d'abonnement%@ !",
                                               @"%@ %@. This is their %@ month subscribed%@!"],
        @"sysmsg_streak_clause_format":     @[@", dont %ld mois consécutifs",
                                               @", including a %ld-month streak"],
        @"sysmsg_word_sub_singular":        @[@"abonnement", @"subscription"],
        @"sysmsg_word_sub_plural":          @[@"abonnements", @"subscriptions"],
        @"sysmsg_gift_format":              @[@"offre %ld %@ de niveau %ld à la communauté de %@. Cet utilisateur a déjà offert %ld %@ sur cette chaîne !",
                                               @"is gifting %ld %@ at Tier %ld to %@'s community! They've already gifted %ld %@ on this channel!"],
        @"sysmsg_targeted_gift_format":      @[@"offre un abonnement de niveau %ld à %@ !",
                                               @"is gifting a Tier %ld subscription to %@!"],
        @"sysmsg_fallback_channel":         @[@"la chaîne", @"the channel"],

        // ── Picker : recherche ────────────────────────────────────────────
        @"alert_search_emote_title":        @[@"Rechercher une emote", @"Search for an emote"],
        @"action_search":                   @[@"Rechercher", @"Search"],
        @"placeholder_search_picker":       @[@"Rechercher…", @"Search…"],
        @"placeholder_emote_name":          @[@"Nom de l'emote…", @"Emote name…"],

        // ── Résumé accueil ────────────────────────────────────────────────
        @"stats_no_channel":                @[@"Aucun channel", @"No channel"],
        @"alert_error_title":               @[@"Erreur", @"Error"],
        @"alert_invalid_format_title":      @[@"Format invalide", @"Invalid format"],
        @"alert_unknown_format_title":      @[@"Format inconnu", @"Unknown format"],
        @"alert_no_7tv_favorites_title":    @[@"Aucun favori 7TV", @"No 7TV favorites"],
        @"alert_import_success_title_format":   @[@"%lu emote(s) ajoutée(s)", @"%lu emote(s) added"],
        @"alert_import_success_message_format": @[@"%lu nouvelle(s) importée(s), %lu déjà en favoris.",
                                                    @"%lu newly imported, %lu already favorited."],

        // ── Chat custom (rendu live + faux chat de preview) ───────────────
        @"chat_deleted_message_placeholder": @[@"– Supprimé", @"– Deleted"],
        @"chat_moderated_message_placeholder": @[@"– Modéré", @"– Moderated"],
        // Détail optionnel injecté dans le placeholder timeout/ban.
        @"chat_moderation_message_with_detail_format": @[@"– %@", @"– %@"],
        @"chat_moderation_timeout":          @[@"Timeout", @"Timeout"],
        @"chat_moderation_timeout_format":   @[@"Timeout %@", @"Timeout %@"],
        @"chat_moderation_permanent_ban":    @[@"Ban permanent", @"Permanent ban"],
        @"chat_duration_seconds_format":     @[@"%lds", @"%lds"],
        @"chat_duration_minutes_format":     @[@"%ldm", @"%ldm"],
        @"chat_duration_hours_format":       @[@"%ldh", @"%ldh"],
        @"chat_duration_days_format":        @[@"%ldj", @"%ldd"],
        @"chat_duration_week_one":           @[@"1 semaine", @"1 week"],
        @"chat_duration_weeks_format":       @[@"%ld semaines", @"%ld weeks"],
        // %@ 1 = pseudo répondu, %@ 2 = extrait du message parent (déjà
        // tronqué côté appelant, voir tpK-chat-custom-view.m
        // tpk_configureReplyBannerWithUsername:bodyPreview:).
        @"chat_reply_banner_format":        @[@"Répond à @%@ : %@", @"Replying to @%@: %@"],
        @"chat_reply_thread_panel_title":   @[@"Fil", @"Thread"],
        // %@ = pseudo de la cible sélectionnée (bouton flèche sur un message)
        // Préfixe seul — @pseudo et le séparateur sont ajoutés en gras via
        // NSAttributedString côté code (voir tpk_selectReplyTarget:username:
        // dans tpK-core-runtime-hooks.m), pas via ce format string.
        @"chat_reply_target_bar_prefix":    @[@"Réponse à ", @"Reply to "],
        @"chat_reply_cancel_button":        @[@"Annuler", @"Cancel"],
        // Petit badge en haut à droite d'un message qui cite le viewer
        // connecté (voir TPKChatCustomView.m,
        // tpk_configureSystemAccentWithColor:iconName:backgroundEnabled:highlightBadgeText:).
        @"mention_badge_label":              @[@"TE MENTIONNE", @"MENTIONS YOU"],
        @"first_message_badge_label":        @[@"PREMIER MESSAGE", @"FIRST MESSAGE"],
        @"announcement_badge_label":         @[@"ANNONCE", @"ANNOUNCEMENT"],

        // ── Bannière "nouveaux messages" (chat custom) ────────────────────
        @"banner_new_messages_generic":     @[@"nouveaux messages", @"new messages"],
        @"banner_new_messages_one":         @[@"1 nouveau message", @"1 new message"],
        @"banner_new_messages_format":      @[@"%lu nouveaux messages", @"%lu new messages"],
        // Frontière historique/live affichée au JOIN du chat custom.
        @"chat_history_welcome_format":      @[@"Bienvenue sur le chat de %@ !", @"Welcome to %@'s chat!"],
        @"chat_history_new_messages":        @[@"Nouveau message", @"New messages"],
        // %@ 1 = utilisateur, %@ 2 = titre exact reçu de Twitch. Les
        // récompenses avec saisie affichent directement leur titre au-dessus
        // du message et n'utilisent donc pas ce connecteur.
        @"chat_channel_points_redeemed_format": @[@"%@ a récupéré : %@", @"%@ redeemed: %@"],
        @"chat_channel_points_used_format": @[@"%@ utilisé", @"%@ used"],
        // Twitch ne renvoie que le type technique de ses récompenses
        // automatiques ; ces deux libellés correspondent aux msg-id IRC qui
        // accompagnent réellement un message de chat.
        @"channel_points_auto_bypass_sub_mode": @[@"Envoyer un message sur le chat réservé aux abonnés",
                                                    @"Send a message in sub-only mode"],
        @"channel_points_auto_highlight_message": @[@"Surligner mon message",
                                                      @"Highlight My Message"],

        // ── Verrouillage de rotation ──────────────────────────────────────
        @"lock_locked":                     @[@"Verrouillé", @"Locked"],
        @"lock_unlocked":                   @[@"Déverrouillé", @"Unlocked"],
        @"a11y_lock_orientation":           @[@"Verrouiller la rotation", @"Lock rotation"],
        @"a11y_unlock_orientation":         @[@"Déverrouiller la rotation", @"Unlock rotation"],
    };
}

@end

NSString *L(NSString *key) {
    return [[TPKLocalization shared] stringForKey:key];
}
