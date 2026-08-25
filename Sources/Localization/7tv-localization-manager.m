/*
 * 7tv-localization-manager.m
 *
 * Voir 7tv-localization-manager.h pour le contexte. Dictionnaire tenu à plat (une
 * seule table clé → {fr, en}) plutôt qu'un fichier par langue : plus simple
 * à maintenir pour ce volume de strings, et évite un risque de désync entre
 * deux fichiers séparés (clé présente en fr mais oubliée en en, etc.).
 */

#import "Localization/7tv-localization-manager.h"

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
    // Filet de sécurité VISIBLE (voir header) : [clé] plutôt que la clé nue
    // ou une chaîne vide — repérable à l'œil pendant les tests sans avoir à
    // grep le code pour savoir quelle traduction manque encore.
    if (!pair) return [NSString stringWithFormat:@"[%@]", key];
    NSUInteger idx = (self.currentLanguage == S7TVLanguageEnglish) ? 1 : 0;
    NSString *value = pair[idx];
    return value.length ? value : [NSString stringWithFormat:@"[%@]", key];
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
        @"title_apparence":                 @[@"Apparence", @"Appearance"],
        @"title_contenu":                   @[@"Contenu", @"Content"],
        @"title_adblock":                   @[@"Adblock", @"Adblock"], // terme déjà utilisé tel quel en français
        @"title_avance":                    @[@"Avancé", @"Advanced"],
        @"title_mes_favoris":               @[@"Mes favoris", @"My Favorites"],
        @"title_debogage":                  @[@"Débogage", @"Debug"],
        @"title_logs_7tv":                  @[@"Logs 7TV", @"7TV Logs"],

        // ── Bouton flottant / header (SevenTVSettingsController + TweakSevenTV) ──
        @"label_7tv_badge":                 @[@"7TV", @"7TV"],
        @"header_7tv_settings_caps":        @[@"7TV SETTINGS", @"7TV SETTINGS"],

        // ── Cache (accueil → Avancé) ─────────────────────────────────────
        @"action_clear_cache":              @[@"Vider le cache", @"Clear cache"],
        @"cache_emote_count_format":        @[@"%ld emotes · %ldx", @"%ld emotes · %ldx"],
        @"alert_cache_cleared_title":       @[@"Cache vidé", @"Cache cleared"],
        @"alert_cache_cleared_message_format": @[@"%lu emotes ont été supprimées du cache. Elles se rechargeront à la demande.",
                                                   @"%lu emotes were removed from the cache. They will reload on demand."],

        // ── Résumé accueil (remplace l'ancien écran Statistiques) ────────
        @"summary_emotes_channel_format":   @[@"%lu emotes chargées · %@", @"%lu emotes loaded · %@"],

        // ── Contenu : section Stream ──────────────────────────────────────
        @"section_stream":                  @[@"Stream", @"Stream"], // anglicisme déjà courant en français
        @"switch_auto_collect_title":       @[@"Récupération auto des points de chaîne", @"Auto Collect Channel Points"],
        @"desc_auto_collect":               @[@"Réclame automatiquement le coffre de points de chaîne quand il apparaît dans le chat.",
                                               @"Automatically claims the live channel-points chest when it appears in chat."],

        // ── Contenu : accueil et lecture (TwitchAdBlock) ────────────────
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
        @"desc_home_playback_settings":     @[@"Le fil Live ne sera plus interrompu par l’écran Regarder/Suivre. Les changements de l’écran de lancement et des stories s’appliquent au prochain démarrage.",
                                               @"The Live feed will no longer be interrupted by the Watch/Follow screen. Launch Screen and Stories changes apply after restarting."],

        // ── Contenu : verrouillage de rotation ───────────────────────────
        @"section_rotation":                @[@"Rotation", @"Rotation"],
        @"switch_orientation_lock_button":  @[@"Bouton de verrouillage", @"Rotation lock button"],
        @"setting_orientation_auto_lock":   @[@"Verrouillage automatique", @"Automatic locking"],
        @"orientation_auto_off":            @[@"Désactivé", @"Off"],
        @"orientation_left":                @[@"Gauche", @"Left"],
        @"orientation_right":               @[@"Droite", @"Right"],
        @"orientation_both":                @[@"Les deux", @"Both"],
        @"desc_orientation_lock_settings":  @[@"Une fois activé, le bouton apparaît sur le lecteur. L’auto-lock fonctionne à gauche, à droite ou des deux côtés.",
                                               @"Once enabled, the button appears on the player. Auto-lock works on the left, right, or both sides."],

        // ── Adblock vidéo / proxy ────────────────────────────────────────
        @"adblock_enable":                  @[@"Activer l’adblock", @"Enable adblock"],
        @"adblock_hide_go_ad_free":         @[@"Masquer Twitch Turbo", @"Hide Twitch Turbo"],
        @"adblock_section_proxy":           @[@"Proxy vidéo", @"Video proxy"],
        @"adblock_video_proxy":             @[@"Utiliser le proxy vidéo", @"Use video proxy"],
        @"adblock_custom_proxy":            @[@"Proxy personnalisé", @"Custom proxy"],
        @"adblock_proxy_default_status":     @[@"Proxy par défaut", @"Default proxy"],
        @"adblock_proxy_custom_status":      @[@"Proxy personnalisé", @"Custom proxy"],
        @"adblock_proxy_status_online":      @[@"● En ligne", @"● Online"],
        @"adblock_proxy_status_offline":     @[@"● Hors ligne", @"● Offline"],
        @"adblock_proxy_status_checking":    @[@"Vérification…", @"Checking…"],
        @"adblock_proxy_status_unknown":     @[@"—", @"—"],
        @"adblock_proxy_add":                @[@"+ Ajouter un proxy", @"+ Add proxy"],
        @"adblock_engine_footer":           @[@"Bloque les domaines publicitaires, modifie les jetons de lecture et peut masquer la promotion Twitch Turbo dans Abonnements.",
                                               @"Blocks ad domains, adjusts playback tokens, and can hide the Twitch Turbo promotion in Following."],
        @"adblock_proxy_privacy_footer":    @[@"Le proxy sert à récupérer les playlists vidéo sans publicité. En mode personnalisé, chaque proxy occupe une ligne et l’ordre définit leur priorité.",
                                               @"The proxy fetches ad-free video playlists. In custom mode, each proxy has its own row and the order defines priority."],

        // ── Menu principal (Apparence / Contenu / Adblock / Avancé) ──────
        @"menu_apparence_subtitle":         @[@"Chat custom, animations", @"Custom chat, animations"],
        @"menu_contenu_subtitle":           @[@"Favoris, accueil, lecture", @"Favorites, home, playback"],
        @"menu_adblock_subtitle":           @[@"Pubs vidéo, proxy", @"Video ads, proxy"],
        @"menu_avance_subtitle":            @[@"Cache, logs, options", @"Cache, logs, options"],

        // ── En-têtes de section ──────────────────────────────────────────
        @"section_general":                 @[@"Général", @"General"],
        @"section_affichage":               @[@"Affichage", @"Display"],
        @"section_favoris":                 @[@"Favoris", @"Favorites"],
        @"section_options":                 @[@"Options", @"Options"],
        @"section_logs":                    @[@"Logs", @"Logs"],
        @"section_danger":                  @[@"Danger", @"Danger"],
        @"section_langue":                  @[@"Langue", @"Language"],

        // ── Switchs de réglages ───────────────────────────────────────────
        @"switch_chat_custom":              @[@"Chat custom", @"Custom chat"],
        @"switch_animations_picker":        @[@"Animations dans le picker", @"Animations in picker"],
        @"switch_animations_favorites_only":@[@"Animations uniquement pour les favoris", @"Animations for favorites only"],
        @"setting_emote_resolution":        @[@"Résolution des emotes 7TV", @"7TV emote resolution"],
        @"setting_resolution_clears_cache": @[
            @"Une résolution élevée est plus nette, mais utilise plus de stockage et de mémoire et peut provoquer des ralentissements. Le changement vide le cache et s'applique sans redémarrage.",
            @"Higher resolutions look sharper, but use more storage and memory and may cause lag. Changing it clears the cache and applies without restarting."
        ],
        @"switch_floating_button":          @[@"Bouton flottant 7TV", @"7TV floating button"],
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
        @"log_cat_channel_points":          @[@"Channel Points", @"Channel Points"],
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
        @"title_emotes_7tv":                @[@"Emotes 7TV", @"7TV emotes"],
        @"size_label_emote_twitch":         @[@"Emotes Twitch", @"Twitch Emotes"],
        @"size_label_badges":               @[@"Badges", @"Badges"],
        @"size_label_username":             @[@"Texte pseudo", @"Username text"],
        @"size_label_message":              @[@"Texte message", @"Message text"],
        @"size_label_line_spacing":         @[@"Espacement des messages", @"Message spacing"],
        @"size_label_emote_offset":         @[@"Alignement des emotes", @"Emote alignment"],
        @"preview_7tv_prefix":              @[@"7TV: ", @"7tv: "],
        @"preview_username":                @[@"Pseudo", @"Username"],
        @"preview_greeting":                @[@"Salut !", @"Hi!"],
        @"sizes_preview_section_title":     @[@"Aperçu", @"Preview"],
        @"sizes_colors_section_title":      @[@"Couleurs des messages système", @"System message colors"],
        @"sizes_colors_toggle_label":       @[@"Fonds colorés", @"Colored backgrounds"],
        @"sizes_color_sub_resub":           @[@"Abonnement", @"Subscription"],
        @"sizes_color_prime":               @[@"Prime", @"Prime"],
        @"sizes_color_gift":                @[@"Cadeau collectif", @"Community gift"],
        // Ligne fondue dans la section ci-dessus (plus de section dédiée —
        // voir 7tv-picker-settings-panel.m, _buildSelfMentionSectionInScrollView:).
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
        @"preview_sub_phrase":              @[@"a pris un abonnement Tier 1. C'est son 3e mois d'abonnement !",
                                               @"subscribed at Tier 1. This is their 3rd month!"],
        @"preview_prime_phrase":            @[@"s'est abonné(e) avec Prime. C'est son 24e mois d'abonnement !",
                                               @"subscribed with Prime. This is their 24th month!"],
        @"preview_gift_phrase":             @[@"offre 5 abonnements à la communauté !",
                                               @"is gifting 5 subs to the community!"],
        @"preview_deleted_message":         @[@"message de test", @"test message"],
        // Cible du message de démo "mention de soi" (mentionsCurrentViewer)
        // du faux chat — voir 7tv-picker-settings-panel.m, _populateFakeChatStore:.
        @"preview_mention_target":          @[@"@Toi", @"@You"],
        @"preview_username_2":              @[@"Viewer_92", @"Viewer_92"],
        @"preview_username_3":              @[@"Modo_Chill", @"Modo_Chill"],
        @"preview_message_2":               @[@"quelqu'un a vu le dernier clip ?", @"anyone see the latest clip?"],
        @"preview_first_message_username":  @[@"NouveauViewer", @"NewViewer"],
        @"preview_first_message_text":      @[@"c'est mon premier message ici !", @"this is my first message here!"],
        @"preview_sub_comment":             @[@"trop hype ce stream", @"this stream is so hype"],
        @"preview_prime_comment":           @[@"24 mois, toujours là !", @"24 months, still here!"],

        // ── Messages système sub/resub/gift (7tv-core-runtime-hooks.m,
        // s7tv_buildSystemMessagePhrase) — reconstruits nous-mêmes depuis les
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
        // Détail optionnel injecté dans le placeholder replié.
        @"chat_deleted_message_with_detail_format": @[@"– Supprimé · %@", @"– Deleted · %@"],
        @"chat_moderation_timeout":          @[@"Timeout", @"Timeout"],
        @"chat_moderation_timeout_format":   @[@"Timeout %@", @"Timeout %@"],
        @"chat_moderation_permanent_ban":    @[@"Ban permanent", @"Permanent ban"],
        @"chat_duration_seconds_format":     @[@"%lds", @"%lds"],
        @"chat_duration_minutes_format":     @[@"%ldm", @"%ldm"],
        @"chat_duration_hours_format":       @[@"%ldh", @"%ldh"],
        @"chat_duration_week_one":           @[@"1 semaine", @"1 week"],
        @"chat_duration_weeks_format":       @[@"%ld semaines", @"%ld weeks"],
        // %@ 1 = pseudo répondu, %@ 2 = extrait du message parent (déjà
        // tronqué côté appelant, voir 7tv-chat-custom-view.m
        // s7tv_configureReplyBannerWithUsername:bodyPreview:).
        @"chat_reply_banner_format":        @[@"Répond à @%@ : %@", @"Replying to @%@: %@"],
        @"chat_reply_thread_panel_title":   @[@"Fil", @"Thread"],
        // %@ = pseudo de la cible sélectionnée (bouton flèche sur un message)
        // Préfixe seul — @pseudo et le séparateur sont ajoutés en gras via
        // NSAttributedString côté code (voir s7tv_selectReplyTarget:username:
        // dans 7tv-core-runtime-hooks.m), pas via ce format string.
        @"chat_reply_target_bar_prefix":    @[@"Réponse à ", @"Reply to "],
        @"chat_reply_cancel_button":        @[@"Annuler", @"Cancel"],
        // Petit badge en haut à droite d'un message qui cite le viewer
        // connecté (voir S7TVChatCustomView.m,
        // s7tv_configureSystemAccentWithColor:iconName:backgroundEnabled:highlightBadgeText:).
        @"mention_badge_label":              @[@"TE MENTIONNE", @"MENTIONS YOU"],
        @"first_message_badge_label":        @[@"PREMIER MESSAGE", @"FIRST MESSAGE"],

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
    return [[S7TVLocalization shared] stringForKey:key];
}
