/*
 * 7tv-chat-message.m
 *
 * Voir 7tv-chat-message.h pour le contexte général (Phase 1a).
 */

#import "Chat/7tv-chat-message.h"
#import "Core/7tv-core-manager.h"
#import "Chat/7tv-chat-tokenizer.h"
#import "Chat/7tv-chat-custom-view.h"
#import "Badge/7tv-badge-provider.h"
#import "Localization/7tv-localization-manager.h"

// ============================================================
// MARK: - S7TVChatUserColorRegistry
// ============================================================

@interface SevenTVChatUserColorRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIColor *> *colorsByLowercaseUsername;
// Même pattern que S7TVChatMessageStore.storeQueue plus bas dans ce
// fichier : queue concurrente dédiée, lecture en dispatch_sync, écriture
// en dispatch_barrier_async.
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation SevenTVChatUserColorRegistry

+ (instancetype)sharedRegistry {
    static SevenTVChatUserColorRegistry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVChatUserColorRegistry alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _colorsByLowercaseUsername = [NSMutableDictionary dictionary];
        _queue = dispatch_queue_create("tv.s7tv.chat-user-color-registry",
                                        DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)registerColor:(nullable UIColor *)color forUsername:(NSString *)username {
    if (!color || !username.length) return;
    NSString *key = username.lowercaseString;
    dispatch_barrier_async(self.queue, ^{
        self.colorsByLowercaseUsername[key] = color;
    });
}

- (nullable UIColor *)colorForUsername:(NSString *)username {
    if (!username.length) return nil;
    NSString *key = username.lowercaseString;
    __block UIColor *result;
    dispatch_sync(self.queue, ^{
        result = self.colorsByLowercaseUsername[key];
    });
    return result;
}

@end


// ============================================================
// MARK: - S7TVChatToken
// ============================================================

// Twitch envoie déjà l'URL complète de chaque GIF dans le tag IRC `gifs=`.
// Ce petit adaptateur permet de réutiliser sans duplication le cache d'images
// et le moteur d'animation qui attendent un objet S7TVResolvedEmote. Les GIFs
// n'appartiennent à aucun provider d'emotes et ne sont donc jamais proposés
// comme favoris ou résolus par nom.
@interface S7TVResolvedTwitchGIF : NSObject <S7TVResolvedEmote>
@property (nonatomic, copy, readonly) NSString *emoteID;
@property (nonatomic, assign, readonly) CGSize nativeSize;
@property (nonatomic, assign, readonly) BOOL isAnimated;
@property (nonatomic, strong, readonly) NSURL *imageURL;
@property (nonatomic, copy, readonly) NSString *providerIdentifier;
@property (nonatomic, copy, readonly) NSString *providerName;
- (instancetype)initWithGIFID:(NSString *)gifID URL:(NSURL *)URL;
@end

@implementation S7TVResolvedTwitchGIF
- (instancetype)initWithGIFID:(NSString *)gifID URL:(NSURL *)URL {
    if (!gifID.length || !URL.absoluteString.length) return nil;
    self = [super init];
    if (self) {
        _emoteID = [gifID copy];
        // Twitch ne transmet pas les dimensions dans `gifs=`. Le renderer
        // remplace ce ratio provisoire par celui de la première image décodée.
        _nativeSize = CGSizeMake(1.0, 1.0);
        _isAnimated = YES;
        _imageURL = URL;
        _providerIdentifier = @"twitch-gif";
        _providerName = @"Twitch GIF";
    }
    return self;
}
@end

@implementation S7TVChatToken

- (instancetype)init {
    self = [super init];
    if (self) _overlayTokens = @[];
    return self;
}

+ (instancetype)textToken:(NSString *)text {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeText;
    t.text = text;
    return t;
}

+ (instancetype)mentionToken:(NSString *)text color:(nullable UIColor *)color {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeMention;
    t.text = text;
    t.mentionColor = color;
    return t;
}

+ (instancetype)urlToken:(NSString *)text {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeURL;
    t.text = text;
    return t;
}

+ (instancetype)emoteToken:(NSString *)name
                   provider:(S7TVChatTokenType)providerType
                   emoteID:(NSString *)emoteID {
    NSAssert(providerType == S7TVChatTokenTypeEmote7TV ||
             providerType == S7TVChatTokenTypeEmoteTwitch,
             @"emoteToken: providerType doit être .emote7TV ou .emoteTwitch");
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = providerType;
    t.text = name;
    t.providerEmoteID = emoteID;
    return t;
}

+ (instancetype)gifToken:(NSString *)caption
                    gifID:(NSString *)gifID
                      url:(NSURL *)url {
    S7TVChatToken *t = [S7TVChatToken new];
    t.type = S7TVChatTokenTypeGIF;
    t.text = caption;
    t.providerEmoteID = [gifID copy];
    t.providerIdentifier = @"twitch-gif";
    t.providerName = @"Twitch GIF";
    t.resolvedEmote = [[S7TVResolvedTwitchGIF alloc] initWithGIFID:gifID URL:url];
    return t;
}

@end


// ============================================================
// MARK: - S7TVSystemMessageInfo (Phase 3)
// ============================================================

@implementation S7TVSystemMessageInfo
@end


// Extrait la valeur d'un tag IRC donné depuis le dictionnaire de tags déjà
// parsé. Retourne defaultValue (jamais nil) si absent/vide.
NSString *s7tv_tagValue(NSDictionary<NSString *, NSString *> *tags,
                                NSString *key,
                                NSString *defaultValue) {
    NSString *v = tags[key];
    return v.length ? v : defaultValue;
}

// Conversion #RRGGBB partagée par les parseurs IRC et PubSub. Une valeur
// absente ou invalide reste nil : le renderer appliquera son fallback.
UIColor * _Nullable s7tv_colorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 6) return nil;
    NSString *digits = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (digits.length != 6) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:digits];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// Décode l'échappement générique des valeurs de tags IRC (IRCv3 tag
// escaping) : \s = espace, \: = point-virgule, \\ = backslash, \r, \n.
// C'est ce qui manquait et causait l'affichage brut "Mais\sdu\sscoup\s..."
// dans le bandeau reply-parent-msg-body — le seul tag de ce fichier qui
// contient régulièrement des espaces, donc le seul où l'absence de décodage
// se voyait à l'écran. Les autres tags (badges=, emotes=, etc.) ne
// contiennent normalement aucun caractère à échapper → no-op pour eux.
static NSString *s7tv_unescapeIRCTagValue(NSString *value) {
    if (![value containsString:@"\\"]) return value; // fast path, cas le plus fréquent
    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    NSUInteger i = 0;
    NSUInteger len = value.length;
    while (i < len) {
        unichar c = [value characterAtIndex:i];
        if (c == '\\' && i + 1 < len) {
            unichar next = [value characterAtIndex:i + 1];
            switch (next) {
                case 's': [result appendString:@" "]; break;
                case ':': [result appendString:@";"]; break;
                case '\\': [result appendString:@"\\"]; break;
                case 'r': [result appendString:@"\r"]; break;
                case 'n': [result appendString:@"\n"]; break;
                // Séquence inconnue : on garde le caractère tel quel plutôt
                // que de planter (parsing tolérant, exigence Phase 1a).
                default: [result appendFormat:@"%C", next]; break;
            }
            i += 2;
        } else {
            [result appendFormat:@"%C", c];
            i += 1;
        }
    }
    return result;
}

// Parse le bloc de tags IRC "@key1=val1;key2=val2;... " en dictionnaire.
// Tolère les tags sans valeur (key= ou key seul) et les lignes sans tags.
NSDictionary<NSString *, NSString *> *s7tv_parseIRCTags(NSString *tagBlock) {
    NSMutableDictionary<NSString *, NSString *> *tags = [NSMutableDictionary dictionary];
    if (!tagBlock.length) return tags;

    for (NSString *pair in [tagBlock componentsSeparatedByString:@";"]) {
        if (pair.length == 0) continue;
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            tags[pair] = @""; // tag sans valeur (ex: présence simple)
            continue;
        }
        NSString *key = [pair substringToIndex:eq.location];
        NSString *val = [pair substringFromIndex:eq.location + 1];
        if (key.length) tags[key] = s7tv_unescapeIRCTagValue(val);
    }
    return tags;
}

// Twitch fournit tmi-sent-ts en millisecondes sur le flux live. Le service
// Recent Messages ajoute rm-received-ts aux lignes historiques ; on le
// préfère car il correspond au moment réellement observé par son relais.
NSDate *s7tv_messageTimestampFromTags(NSDictionary<NSString *, NSString *> *tags) {
    NSString *milliseconds = s7tv_tagValue(tags, @"rm-received-ts", @"");
    if (!milliseconds.length) milliseconds = s7tv_tagValue(tags, @"tmi-sent-ts", @"");
    NSTimeInterval value = milliseconds.doubleValue;
    return value > 0 ? [NSDate dateWithTimeIntervalSince1970:value / 1000.0] : [NSDate date];
}

// Twitch ajoute `source-room-id` à TOUS les messages émis pendant un Shared
// Chat : sur la chaîne source il est égal à `room-id`, et sur les autres
// chaînes il contient l'ID de la chaîne d'origine. Son absence est donc aussi
// le garde-fou natif qui empêche d'afficher l'avatar hors Shared Chat.
static NSString * _Nullable s7tv_sharedChatSourceChannelID(
    NSDictionary<NSString *, NSString *> *tags) {
    NSString *sourceRoomID = s7tv_tagValue(tags, @"source-room-id", @"");
    return sourceRoomID.length ? sourceRoomID : nil;
}


// Parse une ligne IRC complète et retourne un S7TVChatMessage si c'est un
// PRIVMSG exploitable, nil sinon (autre type de commande, ou PRIVMSG dont
// le texte n'a pas pu être isolé — on ne construit jamais de message à
// moitié rempli).
S7TVChatMessage * _Nullable s7tv_parsePRIVMSG(
    NSString *ircLine, NSArray<id<S7TVEmoteProvider>> *providers,
    S7TVAutomaticRewardResolver _Nullable automaticRewardResolver) {
    if (![ircLine containsString:@"PRIVMSG"]) return nil;

    // Bloc de tags : tout ce qui précède le premier espace, s'il commence
    // par '@'. Absent sur certains messages (tags malformés/désactivés
    // côté serveur) — on tolère et on retombe sur des defaults.
    NSDictionary<NSString *, NSString *> *tags = @{};
    NSString *rest = ircLine;
    if ([ircLine hasPrefix:@"@"]) {
        NSRange firstSpace = [ircLine rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            NSString *tagBlock = [ircLine substringWithRange:
                NSMakeRange(1, firstSpace.location - 1)];
            tags = s7tv_parseIRCTags(tagBlock);
            rest = [ircLine substringFromIndex:firstSpace.location + 1];
        }
    }

    // Le texte du message suit toujours " :" après "PRIVMSG #channel" —
    // on cherche la PREMIÈRE occurrence de " :" après "PRIVMSG" précisément
    // pour ne pas confondre avec un ':' qui apparaîtrait dans le pseudo
    // (":nick!user@host") plus tôt dans la ligne.
    NSRange privmsgRange = [rest rangeOfString:@"PRIVMSG"];
    if (privmsgRange.location == NSNotFound) return nil;

    NSRange searchRange = NSMakeRange(privmsgRange.location,
                                       rest.length - privmsgRange.location);
    NSRange textMarker = [rest rangeOfString:@" :" options:0 range:searchRange];
    if (textMarker.location == NSNotFound) return nil; // pas de texte exploitable

    // Fix mélange de chaînes au changement de channel : le WebSocket IRC
    // peut continuer à livrer des PRIVMSG de l'ANCIENNE chaîne juste après
    // un switch (chevauchement JOIN/PART sur le même socket, reconnexion,
    // etc.) — sans ce filtre, s7tv_parsePRIVMSG les acceptait tous sans
    // distinction et le store se retrouvait avec un mélange des deux
    // chaînes, même après le reset fait au JOIN (voir
    // s7tv_sendMessage:completionHandler:) puisque de nouveaux messages de l'ancienne
    // chaîne continuaient d'arriver ENSUITE. Le nom de chaîne ("#xxx") est
    // toujours présent entre "PRIVMSG " et " :" — on l'extrait et on
    // compare à la chaîne actuellement affichée (mgr.currentChannelName,
    // déjà à jour de façon synchrone dès l'envoi de "JOIN #channel", voir
    // s7tv_sendMessage:completionHandler: plus bas). Si ça ne correspond
    // pas → message ignoré, jamais construit ni ajouté au store. Si
    // currentChannelName n'est pas encore connu (tout premier message avant
    // le tout premier JOIN observé), on laisse passer par sécurité plutôt
    // que de risquer de perdre le tout début de l'historique.
    NSUInteger channelTokenStart = privmsgRange.location + privmsgRange.length + 1; // +1 = espace après "PRIVMSG"
    if (channelTokenStart <= textMarker.location) {
        NSString *channelToken = [rest substringWithRange:
            NSMakeRange(channelTokenStart, textMarker.location - channelTokenStart)];
        channelToken = [channelToken stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([channelToken hasPrefix:@"#"]) {
            channelToken = [channelToken substringFromIndex:1];
        }
        NSString *activeChannel = [SevenTVManager sharedManager].currentChannelName;
        if (channelToken.length && activeChannel.length &&
            [channelToken caseInsensitiveCompare:activeChannel] != NSOrderedSame) {
            return nil; // message d'une autre chaîne — jamais ajouté au store
        }
    }

    NSString *messageText = [rest substringFromIndex:textMarker.location + 2];
    if (!messageText.length) return nil;

    // /me (Twitch l'encode en CTCP ACTION IRC standard) : le texte brut est
    // enveloppé "\x01ACTION texte\x01". Déballage AVANT tokenisation —
    // emotesTag/gifsTag utilisent des offsets relatifs au texte réellement
    // affiché (sans le wrapper ACTION), donc décaler l'appel à la tokenisation
    // plus bas casserait l'alignement des médias si on ne déballait qu'après.
    static NSString *const kS7TVActionPrefix = @"\001ACTION ";
    static NSString *const kS7TVActionSuffix = @"\001";
    BOOL isActionMessage = NO;
    if (messageText.length > kS7TVActionPrefix.length &&
        [messageText hasPrefix:kS7TVActionPrefix] &&
        [messageText hasSuffix:kS7TVActionSuffix]) {
        isActionMessage = YES;
        messageText = [messageText substringWithRange:NSMakeRange(
            kS7TVActionPrefix.length,
            messageText.length - kS7TVActionPrefix.length - kS7TVActionSuffix.length)];
    }

    NSString *messageID    = s7tv_tagValue(tags, @"id", [[NSUUID UUID] UUIDString]);
    NSString *userID       = s7tv_tagValue(tags, @"user-id", @"");
    NSString *displayName  = s7tv_tagValue(tags, @"display-name", @"???");
    NSString *colorHex     = s7tv_tagValue(tags, @"color", @"");
    NSString *emotesTag    = s7tv_tagValue(tags, @"emotes", @"");
    NSString *gifsTag      = s7tv_tagValue(tags, @"gifs", @"");
    NSString *badgesTag    = s7tv_tagValue(tags, @"badges", @"");
    NSString *customRewardID = s7tv_tagValue(tags, @"custom-reward-id", @"");
    NSString *ircMessageID = s7tv_tagValue(tags, @"msg-id", @"");
    BOOL hasChannelPointTags = customRewardID.length > 0 || ircMessageID.length > 0;

    // ── Réponses / fils de discussion ───────────────────────────────────
    // reply-parent-msg-id = message immédiatement au-dessus (juste pour le
    // bandeau "Répond à @X"). reply-thread-parent-msg-id = racine du fil
    // ENTIER, fournie par Twitch séparément dès le 2e niveau de réponse —
    // c'est CE champ (jamais reply-parent-msg-id) qui doit servir à
    // regrouper les messages d'un même fil, voir 7tv-chat-message.h.
    // Absent → pas une réponse (defaultValue @"" == non trouvé, testé via
    // .length ci-dessous plutôt que comparé à une chaîne magique).
    NSString *replyParentMsgID  = s7tv_tagValue(tags, @"reply-parent-msg-id", @"");
    NSString *replyThreadRootID = s7tv_tagValue(tags, @"reply-thread-parent-msg-id", @"");
    if (!replyThreadRootID.length) replyThreadRootID = replyParentMsgID; // 1er niveau = racine

    S7TVChatMessage *msg = [[S7TVChatMessage alloc] initWithMessageID:messageID
                                                             timestamp:s7tv_messageTimestampFromTags(tags)
                                                          authorUserID:userID
                                                     authorDisplayName:displayName
                                                               rawText:messageText];
    msg.isActionMessage = isActionMessage;
    msg.channelPointRewardID = customRewardID.length ? customRewardID : nil;
    msg.sharedChatSourceChannelID = s7tv_sharedChatSourceChannelID(tags);
    if (replyParentMsgID.length) {
        msg.replyParentMessageID   = replyParentMsgID;
        // reply-parent-user-login est le pseudo de connexion (minuscules,
        // pas le display-name avec casse/accents) — display-name est ce
        // qu'on affiche partout ailleurs dans ce fichier, donc on le
        // préfère ici s'il est présent pour rester cohérent visuellement,
        // avec repli sur user-login sinon.
        NSString *parentDisplayName = s7tv_tagValue(tags, @"reply-parent-display-name", @"");
        msg.replyParentUsername = parentDisplayName.length
            ? parentDisplayName
            : s7tv_tagValue(tags, @"reply-parent-user-login", @"");
        msg.replyParentBodyPreview = s7tv_tagValue(tags, @"reply-parent-msg-body", @"");
        msg.replyThreadRootID = replyThreadRootID;
    }
    msg.authorColor = s7tv_colorFromHexString(colorHex);

    // Tokenisation à la construction, pas au rendu (Phase 2) : chaque emote
    // du message (7TV comme Twitch native) a déjà ses dimensions connues
    // avant même le premier passage dans la table — c'est ce qui permet de
    // réserver l'espace exact dès le départ côté renderer, sans jamais avoir
    // à resize après coup une fois l'image chargée.
    msg.tokens = [SevenTVChatTokenizer tokenizeText:messageText
                                  twitchEmotesTag:emotesTag
                                      twitchGIFsTag:gifsTag
                                        providers:providers];
    msg.twitchEmotesTag = emotesTag;
    msg.twitchGIFsTag = gifsTag;
    msg.badgeIdentifiers = [SevenTVBadgeProvider identifiersFromIRCTag:badgesTag];
    msg.isFirstMessage = [s7tv_tagValue(tags, @"first-msg", @"0") isEqualToString:@"1"];

    // Les récompenses automatiques (highlight, contournement du mode sub)
    // marquent directement leur PRIVMSG avec un msg-id fixe. Le chemin
    // PubSub construit aussi leur bandeau riche ; celui-ci sert de repli
    // immédiat et apporte surtout les badges/emotes lors de la fusion.
    S7TVChannelPointRewardInfo *automaticReward =
        (automaticRewardResolver ? automaticRewardResolver(ircMessageID) : nil);
    if (automaticReward) {
        msg.type = S7TVChatMessageTypeChannelPointRedemption;
        msg.channelPointRewardInfo = automaticReward;
        // Même clé que l'événement PubSub automatique : le PRIVMSG attend
        // brièvement celui-ci afin de fusionner ses badges/emotes dans le
        // bandeau riche au lieu d'afficher deux lignes.
        msg.channelPointRewardID = automaticReward.rewardID;
    }

    // Diagnostic ponctuel pour identifier le transport réellement utilisé par
    // Twitch. Ne journalise jamais le texte du message : seuls les tags
    // techniques et le résultat de résolution sont nécessaires pour corriger
    // le coût/l'icône des récompenses.
    if (hasChannelPointTags) {
        S7TVChannelPointRewardInfo *resolvedInfo = msg.channelPointRewardInfo;
        [[SevenTVManager sharedManager]
            log:@"[ChatCustom] 🧭 Channel Points IRC: msg-id=%@ custom-reward-id=%@ classified=%@ reward-id=%@",
            ircMessageID.length ? ircMessageID : @"<none>",
            customRewardID.length ? customRewardID : @"<none>",
            resolvedInfo ? @"yes" : @"no",
            msg.channelPointRewardID.length ? msg.channelPointRewardID : @"<none>"];
    }

    // Détection self-mention : scan des tokens .mention déjà résolus par le
    // tokenizer (@pseudo ET pseudo nu — voir S7TVChatToken), comparés au
    // pseudo du viewer connecté (alimenté par SevenTVManager via USERSTATE).
    // nil/vide tant qu'aucun USERSTATE n'a encore été observé →
    // mentionsCurrentViewer reste NO par défaut, jamais de faux positif.
    NSString *viewerName = [SevenTVManager sharedManager].currentViewerDisplayName;
    if (viewerName.length) {
        for (S7TVChatToken *token in msg.tokens) {
            if (token.type != S7TVChatTokenTypeMention) continue;
            NSString *mentionedName = token.text ?: @"";
            if ([mentionedName hasPrefix:@"@"]) {
                mentionedName = [mentionedName substringFromIndex:1];
            }
            if ([mentionedName caseInsensitiveCompare:viewerName] == NSOrderedSame) {
                msg.mentionsCurrentViewer = YES;
                break;
            }
        }
    }

    return msg;
}

// ────────────────────────────────────────────────────────────
// MARK: - Parsing IRC USERNOTICE (Phase 3 — sub / resub / gift sub)
// ────────────────────────────────────────────────────────────
//
// system-msg= n'est PAS utilisé comme source du texte affiché : c'est un
// fallback généré serveur, alors que le rendu natif Twitch (screenshots
// Knoks, Phase 3) est reconstruit en français à partir des msg-param-*.
// Périmètre actuel : sub/resub + gift communautaire (submysterygift).
// Subgift ciblé (1 destinataire nommé) hors périmètre — pas de screenshot
// de référence pour cette formulation, voir plan §Phase 3.

static NSString *s7tv_pluralize(NSInteger count, NSString *singular, NSString *plural) {
    return (count == 1) ? singular : plural;
}

static NSInteger s7tv_tierFromSubPlan(NSString *subPlan) {
    if ([subPlan isEqualToString:@"2000"]) return 2;
    if ([subPlan isEqualToString:@"3000"]) return 3;
    return 1; // "1000", "Prime", ou absent → niveau 1
}

// Ordinal du mois d'abonnement — "24e" en français, "24th" en anglais.
// Seul le compte de mois cumulés (celui qui exprime "c'est son Ne mois")
// utilise un ordinal ; le streak (voir sysmsg_streak_clause_format) est
// resté en nombre cardinal simple dans les deux langues — l'ancien code
// appliquait aussi un "e" français au streak ("dont 6e mois consécutifs"),
// peu naturel, corrigé au passage de la localisation ("dont 6 mois
// consécutifs").
static NSString *s7tv_ordinalMonthString(NSInteger months) {
    if ([S7TVLocalization shared].currentLanguage == S7TVLanguageEnglish) {
        NSInteger mod100 = months % 100;
        NSString *suffix;
        if (mod100 >= 11 && mod100 <= 13) {
            suffix = @"th";
        } else {
            switch (months % 10) {
                case 1:  suffix = @"st"; break;
                case 2:  suffix = @"nd"; break;
                case 3:  suffix = @"rd"; break;
                default: suffix = @"th"; break;
            }
        }
        return [NSString stringWithFormat:@"%ld%@", (long)months, suffix];
    }
    return [NSString stringWithFormat:@"%lde", (long)months];
}

// Reproduit les formulations observées sur screenshots (voir 7tv-localization-manager.m,
// section "Messages système sub/resub/gift", pour le détail des deux langues) :
//   - resub payant : "<verbe> <plan>. C'est son Ne mois d'abonnement, dont S
//     mois consécutifs !" (clause streak seulement si should-share-streak=1)
//   - resub Prime : "<verbe> avec Prime. C'est son Ne mois d'abonnement !"
//   - premier sub (cumulative<=1) : même verbe/plan, sans la phrase "Ne mois".
//   - gift communautaire : "offre N abonnement(s) de niveau X à la
//     communauté de {chaîne}. Cet utilisateur a déjà offert M abonnement(s)
//     sur cette chaîne !"
// Localisé via L() (suit le toggle FR/EN interne du tweak) plutôt que lu
// depuis system-msg= IRC — voir le commentaire en tête de fichier sur ce
// choix : system-msg est un texte de secours serveur non stylable (pseudo
// non extractible pour le gras/couleur) et pas garanti dans la langue voulue,
// alors que le natif Twitch lui-même reconstruit cette phrase depuis les
// mêmes champs msg-param-* qu'on utilise ici.
static NSString *s7tv_buildSystemMessagePhrase(S7TVSystemMessageInfo *info) {
    if (info.kind == S7TVSystemMessageKindCommunityGift) {
        NSString *giftWord   = s7tv_pluralize(info.massGiftCount,
            L(@"sysmsg_word_sub_singular"), L(@"sysmsg_word_sub_plural"));
        NSString *senderWord = s7tv_pluralize(info.senderTotalGiftCount,
            L(@"sysmsg_word_sub_singular"), L(@"sysmsg_word_sub_plural"));
        return [NSString stringWithFormat:L(@"sysmsg_gift_format"),
            (long)info.massGiftCount, giftWord, (long)info.tier,
            info.channelDisplayName ?: L(@"sysmsg_fallback_channel"),
            (long)info.senderTotalGiftCount, senderWord];
    }

    NSString *planPhrase = info.isPrime
        ? L(@"sysmsg_plan_prime")
        : [NSString stringWithFormat:L(@"sysmsg_plan_tier_format"), (long)info.tier];
    NSString *verb = info.isPrime ? L(@"sysmsg_verb_sub_prime") : L(@"sysmsg_verb_sub_tier");

    if (info.cumulativeMonths <= 1) {
        return [NSString stringWithFormat:L(@"sysmsg_first_sub_format"), verb, planPhrase];
    }

    NSString *streakClause = (info.streakMonths > 0)
        ? [NSString stringWithFormat:L(@"sysmsg_streak_clause_format"), (long)info.streakMonths]
        : @"";
    NSString *monthOrdinal = s7tv_ordinalMonthString(info.cumulativeMonths);
    return [NSString stringWithFormat:L(@"sysmsg_resub_format"),
        verb, planPhrase, monthOrdinal, streakClause];
}

// Parse une ligne IRC complète et retourne un S7TVChatMessage de type
// .system si c'est un USERNOTICE exploitable (sub/resub/gift communautaire),
// nil sinon — même contrat que s7tv_parsePRIVMSG (jamais de message à
// moitié rempli).
S7TVChatMessage * _Nullable s7tv_parseUSERNOTICE(
    NSString *ircLine, NSArray<id<S7TVEmoteProvider>> *providers) {
    if (![ircLine containsString:@"USERNOTICE"]) return nil;
    if (![ircLine hasPrefix:@"@"]) return nil; // pas de tags → pas de msg-id exploitable

    NSRange firstSpace = [ircLine rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return nil;
    NSDictionary<NSString *, NSString *> *tags =
        s7tv_parseIRCTags([ircLine substringWithRange:NSMakeRange(1, firstSpace.location - 1)]);
    NSString *rest = [ircLine substringFromIndex:firstSpace.location + 1];

    NSString *msgID = s7tv_tagValue(tags, @"msg-id", @"");
    S7TVSystemMessageKind kind;
    if ([msgID isEqualToString:@"sub"] || [msgID isEqualToString:@"resub"]) {
        kind = S7TVSystemMessageKindSubOrResub;
    } else if ([msgID isEqualToString:@"submysterygift"]) {
        kind = S7TVSystemMessageKindCommunityGift;
    } else {
        return nil; // subgift ciblé, raid, giftpaidupgrade... hors périmètre pour l'instant
    }

    // Même garde-fou changement de chaîne que s7tv_parsePRIVMSG — voir le
    // commentaire détaillé là-bas.
    NSRange usernoticeRange = [rest rangeOfString:@"USERNOTICE"];
    if (usernoticeRange.location == NSNotFound) return nil;
    NSRange searchRange = NSMakeRange(usernoticeRange.location, rest.length - usernoticeRange.location);
    NSRange textMarker = [rest rangeOfString:@" :" options:0 range:searchRange];
    NSUInteger channelTokenEnd = (textMarker.location != NSNotFound) ? textMarker.location : rest.length;
    NSUInteger channelTokenStart = usernoticeRange.location + usernoticeRange.length + 1;
    // Le texte après " :" est optionnel pour un USERNOTICE (commentaire de
    // l'utilisateur ajouté à son propre resub, ex: "ouais") — contrairement
    // à PRIVMSG où son absence invalide le message.
    NSString *messageText = (textMarker.location != NSNotFound)
        ? [rest substringFromIndex:textMarker.location + 2] : @"";

    if (channelTokenStart <= channelTokenEnd) {
        NSString *channelToken = [rest substringWithRange:
            NSMakeRange(channelTokenStart, channelTokenEnd - channelTokenStart)];
        channelToken = [channelToken stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([channelToken hasPrefix:@"#"]) channelToken = [channelToken substringFromIndex:1];
        NSString *activeChannel = [SevenTVManager sharedManager].currentChannelName;
        if (channelToken.length && activeChannel.length &&
            [channelToken caseInsensitiveCompare:activeChannel] != NSOrderedSame) {
            return nil;
        }
    }

    NSString *messageID   = s7tv_tagValue(tags, @"id", [[NSUUID UUID] UUIDString]);
    NSString *userID      = s7tv_tagValue(tags, @"user-id", @"");
    NSString *displayName = s7tv_tagValue(tags, @"display-name", @"???");
    NSString *colorHex    = s7tv_tagValue(tags, @"color", @"");
    NSString *badgesTag   = s7tv_tagValue(tags, @"badges", @"");
    NSString *emotesTag   = s7tv_tagValue(tags, @"emotes", @"");
    NSString *gifsTag     = s7tv_tagValue(tags, @"gifs", @"");
    NSString *subPlan     = s7tv_tagValue(tags, @"msg-param-sub-plan", @"1000");

    S7TVSystemMessageInfo *info = [S7TVSystemMessageInfo new];
    info.kind    = kind;
    info.isPrime = [subPlan isEqualToString:@"Prime"];
    info.tier    = s7tv_tierFromSubPlan(subPlan);

    if (kind == S7TVSystemMessageKindSubOrResub) {
        info.cumulativeMonths = [s7tv_tagValue(tags, @"msg-param-cumulative-months", @"1") integerValue];
        BOOL shareStreak = [s7tv_tagValue(tags, @"msg-param-should-share-streak", @"0") integerValue] != 0;
        info.streakMonths = shareStreak
            ? [s7tv_tagValue(tags, @"msg-param-streak-months", @"0") integerValue] : 0;
    } else {
        info.massGiftCount = MAX(1, [s7tv_tagValue(tags, @"msg-param-mass-gift-count", @"1") integerValue]);
        info.senderTotalGiftCount = [s7tv_tagValue(tags, @"msg-param-sender-count", @"0") integerValue];
        info.channelDisplayName = [SevenTVManager sharedManager].currentChannelName ?: L(@"sysmsg_fallback_channel");
    }

    S7TVChatMessage *msg = [[S7TVChatMessage alloc] initWithMessageID:messageID
                                                             timestamp:s7tv_messageTimestampFromTags(tags)
                                                          authorUserID:userID
                                                     authorDisplayName:displayName
                                                               rawText:messageText];
    msg.type         = S7TVChatMessageTypeSystem;
    msg.systemInfo   = info;
    msg.systemPhrase = s7tv_buildSystemMessagePhrase(info);
    msg.sharedChatSourceChannelID = s7tv_sharedChatSourceChannelID(tags);

    msg.authorColor = s7tv_colorFromHexString(colorHex);

    // Commentaire optionnel attaché (ex: resub avec message) — tokenisé
    // comme un message normal, rendu sous la bannière système (voir
    // SevenTVChatCustomView, s7tv_appendNormalBodyForMessage:into:...).
    if (messageText.length) {
        msg.tokens = [SevenTVChatTokenizer tokenizeText:messageText
                                      twitchEmotesTag:emotesTag
                                          twitchGIFsTag:gifsTag
                                            providers:providers];
    }
    msg.twitchEmotesTag = emotesTag;
    msg.twitchGIFsTag = gifsTag;
    msg.badgeIdentifiers = [SevenTVBadgeProvider identifiersFromIRCTag:badgesTag];

    return msg;
}




// ────────────────────────────────────────────────────────────
// MARK: - Récompenses de points de chaîne (PubSub reward-redeemed)
// ────────────────────────────────────────────────────────────

static id _Nullable s7tv_JSONValueForKeys(NSDictionary *dictionary,
                                           NSArray<NSString *> *keys) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (value && value != [NSNull null]) return value;
    }
    return nil;
}

static NSString *s7tv_JSONStringForKeys(NSDictionary *dictionary,
                                        NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static NSDictionary * _Nullable s7tv_JSONDictionaryForKeys(NSDictionary *dictionary,
                                                            NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static BOOL s7tv_JSONBoolForKeys(NSDictionary *dictionary,
                                 NSArray<NSString *> *keys) {
    id value = s7tv_JSONValueForKeys(dictionary, keys);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

// Les messages PubSub et les tags IRC peuvent employer des clés snake_case ou
// camelCase. Ces helpers gardent une lecture tolérante sans charger de
// métadonnées d'image ou de prix.

static NSString * _Nullable s7tv_automaticRewardTitleLocalizationKey(NSString *type) {
    if ([type isEqualToString:@"SINGLE_MESSAGE_BYPASS_SUB_MODE"])
        return @"channel_points_auto_bypass_sub_mode";
    if ([type isEqualToString:@"SEND_HIGHLIGHTED_MESSAGE"])
        return @"channel_points_auto_highlight_message";
    return nil;
}

static NSString *s7tv_normalizedAutomaticRewardType(NSString *rawType) {
    if (!rawType.length) return @"";
    NSString *type = rawType.uppercaseString;
    type = [type stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    type = [type stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    if ([type isEqualToString:@"SKIP_SUBS_MODE_MESSAGE"] ||
        [type isEqualToString:@"SINGLE_MESSAGE_BYPASS_SUBS_MODE"]) {
        return @"SINGLE_MESSAGE_BYPASS_SUB_MODE";
    }
    if ([type isEqualToString:@"HIGHLIGHTED_MESSAGE"]) {
        return @"SEND_HIGHLIGHTED_MESSAGE";
    }
    return type;
}

static NSString * _Nullable s7tv_automaticRewardTypeForIRCMessageID(NSString *messageID) {
    NSString *type = s7tv_normalizedAutomaticRewardType(messageID);
    return s7tv_automaticRewardTitleLocalizationKey(type).length ? type : nil;
}

static S7TVChannelPointRewardInfo * _Nullable
s7tv_automaticRewardInfoForType(NSString *rawType) {
    NSString *type = s7tv_normalizedAutomaticRewardType(rawType);
    if (!type.length) return nil;
    NSString *titleKey = s7tv_automaticRewardTitleLocalizationKey(type);
    if (!titleKey.length) return nil;

    // Le msg-id IRC suffit à identifier les deux récompenses automatiques
    // publiques. Aucun catalogue GQL ni métadonnée d'image n'est requis.
    S7TVChannelPointRewardInfo *info = [S7TVChannelPointRewardInfo new];
    info.rewardID = type;
    info.title = @"";
    info.titleLocalizationKey = titleKey;
    info.isUserInputRequired = YES;
    return info;
}

static S7TVChannelPointRewardInfo * _Nullable
s7tv_automaticRewardInfoForIRCMessageID(NSString *messageID) {
    NSString *type = s7tv_automaticRewardTypeForIRCMessageID(messageID);
    return type.length ? s7tv_automaticRewardInfoForType(type) : nil;
}

// Pont minimal entre le parseur IRC hébergé avec le modèle et les événements
// Channel Points reçus via PubSub.
S7TVChatMessage * _Nullable s7tv_parseChatMessage(
    NSString *ircLine, NSArray<id<S7TVEmoteProvider>> *providers) {
    S7TVChatMessage *message = s7tv_parsePRIVMSG(
        ircLine, providers,
        ^S7TVChannelPointRewardInfo *(NSString *messageID) {
            return s7tv_automaticRewardInfoForIRCMessageID(messageID);
        });
    return message ?: s7tv_parseUSERNOTICE(ircLine, providers);
}

#if 0 // Legacy GQL reward catalog and native currency image pipeline removed.
static void s7tv_collectAutomaticRewardDictionaries(id object,
                                                     NSMutableArray<NSDictionary *> *rewards) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        id automaticRewards = dictionary[@"automaticRewards"];
        if ([automaticRewards isKindOfClass:[NSArray class]]) {
            for (id reward in (NSArray *)automaticRewards) {
                if ([reward isKindOfClass:[NSDictionary class]]) [rewards addObject:reward];
            }
        }
        for (id value in dictionary.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] ||
                [value isKindOfClass:[NSArray class]]) {
                s7tv_collectAutomaticRewardDictionaries(value, rewards);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            s7tv_collectAutomaticRewardDictionaries(value, rewards);
        }
    }
}

void s7tv_ingestAutomaticRewardsFromGQLData(
    NSData *data, NSString * _Nullable requestChannelID,
    BOOL requestChannelIDAmbiguous,
    dispatch_block_t _Nullable refresh) {
    (void)refresh; // L'icône native ne dépend plus du fallback GQL.
    if (!data.length) return;
    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    BOOL containsAutomaticRewards = [raw containsString:@"automaticRewards"];
    BOOL containsPointSettings = [raw containsString:@"communityPointsSettings"] ||
                                 [raw containsString:@"community_points_settings"];
    NSString *lowerRaw = raw.lowercaseString;
    BOOL mentionsPointData = [lowerRaw containsString:@"channelpoint"] ||
                             [lowerRaw containsString:@"communitypoint"];
    if (!containsAutomaticRewards && !containsPointSettings) {
        if (mentionsPointData) {
            [manager log:@"[ChatCustom] 🧭 Channel Points GQL: payload reçu mais aucun champ automatiqueRewards/communityPointsSettings reconnu (bytes=%lu)",
                (unsigned long)data.length];
        }
        return;
    }

    [manager log:@"[ChatCustom] 🧭 Channel Points GQL: payload candidat (bytes=%lu automaticRewards=%@ communityPointsSettings=%@ request-channel=%@ ambiguous=%@)",
        (unsigned long)data.length,
        containsAutomaticRewards ? @"yes" : @"no",
        containsPointSettings ? @"yes" : @"no",
        requestChannelID.length ? requestChannelID : @"<none>",
        requestChannelIDAmbiguous ? @"yes" : @"no"];

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!root) {
        [manager log:@"[ChatCustom] 🧭 Channel Points GQL: JSON invalide (%@)",
            jsonError.localizedDescription ?: @"payload vide"];
        return;
    }

    // Un batch Apollo peut contenir plusieurs chaînes et peut arriver juste
    // AVANT la publication du nouveau broadcaster ID. Chaque settings est
    // donc indexé par son propre channelID à la capture ; le rendu choisit
    // ensuite la chaîne active. Aucun payload valide n'est rejeté à cause du
    // timing d'un changement de chaîne.
    NSMutableArray<NSDictionary *> *settingsCandidates = [NSMutableArray array];
    NSMutableArray<NSString *> *channelIDs = [NSMutableArray array];
    s7tv_collectCommunityPointSettingsDictionaries(root, settingsCandidates, channelIDs);
    if (!settingsCandidates.count) {
        [manager log:@"[ChatCustom] 🧭 Channel Points GQL: aucun dictionnaire de settings trouvé"];
        return;
    }

    [manager log:@"[ChatCustom] 🧭 Channel Points GQL: %lu dictionnaire(s) de settings trouvé(s)",
        (unsigned long)settingsCandidates.count];

    NSString *currentChannelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    NSMutableDictionary *catalogs = s7tv_automaticRewardCatalogsByChannel();

    for (NSUInteger candidateIndex = 0;
         candidateIndex < settingsCandidates.count; candidateIndex++) {
        NSDictionary *settings = settingsCandidates[candidateIndex];
        NSString *payloadChannelID = channelIDs[candidateIndex];
        NSString *resolvedChannelID = payloadChannelID.length
            ? payloadChannelID : requestChannelID;
        // Un batch qui porte plusieurs broadcaster IDs n'offre aucun repli
        // fiable pour un settings dépourvu de son propre ID. Même au tout
        // premier chargement (currentChannelID encore nil), ne jamais ranger
        // ce candidat dans le bucket temporaire puis le migrer au hasard.
        if (!payloadChannelID.length && requestChannelIDAmbiguous) continue;
        // Si une réponse sans ID arrive après un changement de chaîne et que
        // la requête ne permet pas non plus de l'identifier, l'attribuer au
        // currentChannelID du callback serait arbitraire. On l'ignore plutôt
        // que de polluer durablement le catalogue/icône de la nouvelle chaîne.
        if (!resolvedChannelID.length && currentChannelID.length) continue;
        NSString *channelKey = s7tv_rewardChannelKey(resolvedChannelID);
        UIImage *nativeImage = nil;
        @synchronized (catalogs) {
            nativeImage = s7tv_channelPointNativeImagesByChannel()[channelKey];
        }

        NSMutableArray<NSDictionary *> *rawRewards = [NSMutableArray array];
        if (containsAutomaticRewards) {
            // Partir du settings sélectionné, jamais de la racine du batch :
            // les automaticRewards d'une autre chaîne ne peuvent ainsi être
            // mélangés au logo/coût de celle-ci.
            s7tv_collectAutomaticRewardDictionaries(settings, rawRewards);
        }
        if (!rawRewards.count) {
            [manager log:@"[ChatCustom] 🧭 Channel Points GQL: settings channel=%@ sans automatic reward exploitable",
                resolvedChannelID.length ? resolvedChannelID : @"<none>"];
        }
        NSMutableDictionary<NSString *, S7TVChannelPointRewardInfo *> *nextCatalog =
            [NSMutableDictionary dictionary];
        for (NSDictionary *reward in rawRewards) {
            NSString *type = s7tv_normalizedAutomaticRewardType(
                s7tv_JSONStringForKeys(reward, @[@"type"]));
            if (!type.length) continue;
            S7TVChannelPointRewardInfo *info = [S7TVChannelPointRewardInfo new];
            info.rewardID = type;
            info.title = @"";
            info.titleLocalizationKey = s7tv_automaticRewardTitleLocalizationKey(type);
            info.pricingType = s7tv_JSONStringForKeys(
                reward, @[@"pricingType", @"pricing_type"]);
            BOOL usesBits = info.pricingType.length > 0 &&
                [info.pricingType caseInsensitiveCompare:@"BITS"] == NSOrderedSame;
            info.cost = usesBits
                ? s7tv_JSONIntegerForKeys(reward, @[@"bitsCost", @"bits_cost"])
                : s7tv_JSONIntegerForKeys(reward, @[@"cost"]);
            if (info.cost <= 0) {
                info.cost = usesBits
                    ? s7tv_JSONIntegerForKeys(
                        reward, @[@"defaultBitsCost", @"default_bits_cost"])
                    : s7tv_JSONIntegerForKeys(
                        reward, @[@"defaultCost", @"default_cost"]);
            }
            NSString *backgroundHex = s7tv_JSONStringForKeys(
                reward, @[@"backgroundColor", @"background_color"]);
            if (!backgroundHex.length) {
                backgroundHex = s7tv_JSONStringForKeys(
                    reward, @[@"defaultBackgroundColor", @"default_background_color"]);
            }
            info.accentColor = s7tv_colorFromHexString(backgroundHex);
            if (usesBits) {
                NSURL *imageURL = s7tv_channelPointImageURL(reward);
                if (imageURL) info.imageURL = imageURL;
            } else {
                info.nativeImage = nativeImage;
            }
            info.isUserInputRequired = info.titleLocalizationKey.length > 0;
            nextCatalog[type] = info;
            [manager log:@"[ChatCustom] 🧭 Channel Points GQL reward: channel=%@ type=%@ cost=%ld pricing=%@",
                resolvedChannelID.length ? resolvedChannelID : @"<none>",
                type,
                (long)info.cost,
                info.pricingType.length ? info.pricingType : @"<none>"];
        }

        @synchronized (catalogs) {
            if (nextCatalog.count) {
                catalogs[channelKey] = nextCatalog;
            }
        }
        [manager log:@"[ChatCustom] 🧭 Channel Points GQL: catalogue channel=%@ %@ (%lu reward(s))",
            resolvedChannelID.length ? resolvedChannelID : @"<none>",
            nextCatalog.count ? @"stored" : @"empty",
            (unsigned long)nextCatalog.count];
    }
}

void s7tv_activateChannelPointMetadataForChannelID(
    NSString *channelID, dispatch_block_t _Nullable refresh) {
    if (!channelID.length) return;
    // L'icône est fournie par le bouton natif de la barre de chat, qui peut
    // apparaître après le changement d'ID et indépendamment de la réponse
    // GQL. Déclencher la recherche ici couvre les deux ordres d'arrivée.
    s7tv_scheduleNativeChannelPointsButtonScan(refresh);
    NSMutableDictionary *catalogs = s7tv_automaticRewardCatalogsByChannel();
    UIImage *nativeImage = nil;
    @synchronized (catalogs) {
        NSString *channelKey = s7tv_rewardChannelKey(channelID);
        NSMutableDictionary *images = s7tv_channelPointNativeImagesByChannel();
        // Une réponse GQL ou l'apparition du bouton peut précéder le premier
        // broadcaster ID de quelques millisecondes. L'entrée "unknown" est
        // liée une fois au premier ID connu, puis supprimée pour éviter toute
        // fuite vers la chaîne suivante.
        if (!catalogs[channelKey] && catalogs[kS7TVUnknownRewardChannelKey]) {
            catalogs[channelKey] = catalogs[kS7TVUnknownRewardChannelKey];
        }
        if (!images[channelKey] && images[kS7TVUnknownRewardChannelKey]) {
            images[channelKey] = images[kS7TVUnknownRewardChannelKey];
        }
        [catalogs removeObjectForKey:kS7TVUnknownRewardChannelKey];
        [images removeObjectForKey:kS7TVUnknownRewardChannelKey];
        nativeImage = images[channelKey];
    }
    if (!nativeImage) return;
    [[SevenTVManager sharedManager].chatMessageStore
        updateChannelPointCurrencyImage:nativeImage completion:refresh];
}

#endif
static NSDate *s7tv_channelPointTimestamp(NSString *rawTimestamp) {
    if (!rawTimestamp.length) return [NSDate date];
    static NSISO8601DateFormatter *withFractions = nil;
    static NSISO8601DateFormatter *withoutFractions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        withFractions = [NSISO8601DateFormatter new];
        withFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                      NSISO8601DateFormatWithFractionalSeconds;
        withoutFractions = [NSISO8601DateFormatter new];
        withoutFractions.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    NSDate *date = nil;
    @synchronized (withFractions) {
        date = [withFractions dateFromString:rawTimestamp];
        if (!date) date = [withoutFractions dateFromString:rawTimestamp];
    }
    return date ?: [NSDate date];
}

// Une récompense avec saisie produit généralement deux transports pour le
// même contenu : reward-redeemed (PubSub, riche en métadonnées) puis un
// PRIVMSG custom-reward-id (IRC, riche en badges/emotes). On mémorise
// brièvement le couple utilisateur/récompense déjà rendu par PubSub pour
// supprimer uniquement son PRIVMSG compagnon, jamais le chat normal.
static NSString *s7tv_channelPointCompanionKey(NSString *userID, NSString *rewardID) {
    if (!userID.length || !rewardID.length) return @"";
    return [NSString stringWithFormat:@"%@|%@", userID, rewardID];
}

static NSMutableDictionary<NSString *, NSDate *> *s7tv_recentChannelPointCompanions(void) {
    static NSMutableDictionary<NSString *, NSDate *> *entries = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ entries = [NSMutableDictionary dictionary]; });
    return entries;
}

static void s7tv_registerChannelPointCompanionToSuppress(NSString *userID,
                                                          NSString *rewardID) {
    NSString *key = s7tv_channelPointCompanionKey(userID, rewardID);
    if (!key.length) return;
    NSMutableDictionary *entries = s7tv_recentChannelPointCompanions();
    @synchronized (entries) {
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8.0];
        for (NSString *existingKey in [entries.allKeys copy]) {
            if ([entries[existingKey] compare:cutoff] == NSOrderedAscending) {
                [entries removeObjectForKey:existingKey];
            }
        }
        entries[key] = [NSDate date];
    }
}

BOOL s7tv_shouldSuppressChannelPointCompanion(S7TVChatMessage *message) {
    NSString *key = s7tv_channelPointCompanionKey(message.authorUserID,
                                                   message.channelPointRewardID);
    if (!key.length) return NO;
    NSMutableDictionary *entries = s7tv_recentChannelPointCompanions();
    @synchronized (entries) {
        NSDate *date = entries[key];
        return date && [[NSDate date] timeIntervalSinceDate:date] <= 8.0;
    }
}

static S7TVChatMessage * _Nullable s7tv_channelPointMessageFromRedemption(
    NSDictionary *redemption, NSArray<id<S7TVEmoteProvider>> *providers) {
    if (![redemption isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
    NSDictionary *user = s7tv_JSONDictionaryForKeys(redemption, @[@"user"]);
    NSString *redemptionID = s7tv_JSONStringForKeys(redemption, @[@"id"]);
    NSString *rewardID = s7tv_JSONStringForKeys(reward, @[@"id"]);
    NSString *title = s7tv_JSONStringForKeys(reward, @[@"title"]);
    if (!redemptionID.length || !rewardID.length || !title.length) return nil;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSString *channelID = s7tv_JSONStringForKeys(redemption, @[@"channel_id", @"channelID"]);
    if (!channelID.length) {
        channelID = s7tv_JSONStringForKeys(reward, @[@"channel_id", @"channelID"]);
    }
    if (channelID.length && manager.currentChannelTwitchID.length &&
        ![channelID isEqualToString:manager.currentChannelTwitchID]) {
        return nil;
    }

    NSString *userID = s7tv_JSONStringForKeys(user, @[@"id"]);
    NSString *displayName = s7tv_JSONStringForKeys(user, @[@"display_name", @"displayName"]);
    if (!displayName.length) displayName = s7tv_JSONStringForKeys(user, @[@"login"]);
    if (!displayName.length) displayName = @"???";

    S7TVChannelPointRewardInfo *info = [S7TVChannelPointRewardInfo new];
    info.rewardID = rewardID;
    info.title = title;
    info.prompt = s7tv_JSONStringForKeys(reward, @[@"prompt"]);
    info.isUserInputRequired = s7tv_JSONBoolForKeys(reward,
        @[@"is_user_input_required", @"isUserInputRequired"]);
    NSString *userInput = s7tv_JSONStringForKeys(redemption,
        @[@"user_input", @"userInput"]);
    info.userInput = userInput.length ? userInput : nil;
    info.accentColor = s7tv_colorFromHexString(s7tv_JSONStringForKeys(reward,
        @[@"background_color", @"backgroundColor"]));
    NSString *rawTimestamp = s7tv_JSONStringForKeys(redemption,
        @[@"redeemed_at", @"redeemedAt"]);
    S7TVChatMessage *message = [[S7TVChatMessage alloc]
        initWithMessageID:redemptionID
                timestamp:s7tv_channelPointTimestamp(rawTimestamp)
             authorUserID:userID ?: @""
        authorDisplayName:displayName
                  rawText:userInput ?: @""];
    message.type = S7TVChatMessageTypeChannelPointRedemption;
    message.channelPointRewardInfo = info;
    message.channelPointRewardID = rewardID;
    message.authorColor = [[SevenTVChatUserColorRegistry sharedRegistry]
        colorForUsername:displayName];
    if (userInput.length) {
        message.tokens = [SevenTVChatTokenizer tokenizeText:userInput
                                          twitchEmotesTag:@""
                                                providers:providers];
        s7tv_registerChannelPointCompanionToSuppress(userID, rewardID);
    }
    return message;
}

static S7TVChatMessage * _Nullable s7tv_channelPointMessageFromAutomaticRedemption(
    NSDictionary *redemption, NSArray<id<S7TVEmoteProvider>> *providers) {
    if (![redemption isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
    NSString *automaticType = s7tv_normalizedAutomaticRewardType(
        s7tv_JSONStringForKeys(reward, @[@"type", @"id"]));
    S7TVChannelPointRewardInfo *info =
        s7tv_automaticRewardInfoForType(automaticType);
    if (!info) return nil; // Les unlocks personnels ne créent pas de ligne publique.

    NSString *redemptionID = s7tv_JSONStringForKeys(redemption, @[@"id"]);
    if (!redemptionID.length) return nil;

    SevenTVManager *manager = [SevenTVManager sharedManager];
    NSString *channelID = s7tv_JSONStringForKeys(redemption,
        @[@"channel_id", @"channelID", @"broadcaster_user_id", @"broadcasterUserID"]);
    if (!channelID.length) {
        channelID = s7tv_JSONStringForKeys(reward, @[@"channel_id", @"channelID"]);
    }
    if (channelID.length && manager.currentChannelTwitchID.length &&
        ![channelID isEqualToString:manager.currentChannelTwitchID]) {
        return nil;
    }

    NSDictionary *user = s7tv_JSONDictionaryForKeys(redemption, @[@"user"]);
    NSString *userID = s7tv_JSONStringForKeys(user, @[@"id"]);
    if (!userID.length) {
        userID = s7tv_JSONStringForKeys(redemption, @[@"user_id", @"userID"]);
    }
    NSString *displayName = s7tv_JSONStringForKeys(user,
        @[@"display_name", @"displayName", @"login"]);
    if (!displayName.length) {
        displayName = s7tv_JSONStringForKeys(redemption,
            @[@"user_name", @"userName", @"user_login", @"userLogin"]);
    }
    if (!displayName.length) displayName = @"???";

    NSString *userInput = s7tv_JSONStringForKeys(redemption,
        @[@"user_input", @"userInput"]);
    NSDictionary *messagePayload = s7tv_JSONDictionaryForKeys(redemption, @[@"message"]);
    if (!userInput.length) {
        userInput = s7tv_JSONStringForKeys(messagePayload, @[@"text"]);
    }
    info.userInput = userInput.length ? userInput : nil;
    info.isUserInputRequired = YES;

    NSString *rawTimestamp = s7tv_JSONStringForKeys(redemption,
        @[@"redeemed_at", @"redeemedAt"]);
    S7TVChatMessage *message = [[S7TVChatMessage alloc]
        initWithMessageID:redemptionID
                timestamp:s7tv_channelPointTimestamp(rawTimestamp)
             authorUserID:userID ?: @""
        authorDisplayName:displayName
                  rawText:userInput ?: @""];
    message.type = S7TVChatMessageTypeChannelPointRedemption;
    message.channelPointRewardInfo = info;
    message.channelPointRewardID = automaticType;
    message.authorColor = [[SevenTVChatUserColorRegistry sharedRegistry]
        colorForUsername:displayName];
    if (userInput.length) {
        message.tokens = [SevenTVChatTokenizer tokenizeText:userInput
                                          twitchEmotesTag:@""
                                                providers:providers];
        s7tv_registerChannelPointCompanionToSuppress(userID, automaticType);
    }
    return message;
}

static void s7tv_collectChannelPointMessages(id object,
                                              NSMutableArray<S7TVChatMessage *> *messages,
                                              NSArray<id<S7TVEmoteProvider>> *providers) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        NSString *type = s7tv_JSONStringForKeys(dictionary, @[@"type"]);
        if ([type isEqualToString:@"reward-redeemed"] ||
            [type isEqualToString:@"reward_redeemed"]) {
            NSDictionary *data = s7tv_JSONDictionaryForKeys(dictionary, @[@"data"]);
            NSDictionary *redemption = s7tv_JSONDictionaryForKeys(data, @[@"redemption"]);
            NSDictionary *reward = s7tv_JSONDictionaryForKeys(redemption, @[@"reward"]);
            NSString *possibleAutomaticType = s7tv_normalizedAutomaticRewardType(
                s7tv_JSONStringForKeys(reward, @[@"type", @"id"]));
            BOOL isAutomatic =
                s7tv_automaticRewardTitleLocalizationKey(possibleAutomaticType).length > 0;
            S7TVChatMessage *message = isAutomatic
                ? s7tv_channelPointMessageFromAutomaticRedemption(redemption, providers)
                : s7tv_channelPointMessageFromRedemption(redemption, providers);
            if (message) [messages addObject:message];
            return;
        }
        NSString *lowerType = type.lowercaseString;
        BOOL isAutomaticRedemption =
            [lowerType containsString:@"automatic"] &&
            [lowerType containsString:@"reward"] &&
            [lowerType containsString:@"redeem"];
        if (isAutomaticRedemption) {
            NSDictionary *data = s7tv_JSONDictionaryForKeys(dictionary, @[@"data"]);
            NSDictionary *redemption = s7tv_JSONDictionaryForKeys(data, @[@"redemption"]);
            if (!redemption.count) redemption = s7tv_JSONDictionaryForKeys(data, @[@"event"]);
            if (!redemption.count) redemption = data;
            S7TVChatMessage *message =
                s7tv_channelPointMessageFromAutomaticRedemption(redemption, providers);
            if (message) [messages addObject:message];
            return;
        }

        // EventSub place parfois le type de notification dans metadata et
        // livre directement l'objet event ici. Son reward.type est alors le
        // seul marqueur présent dans cette branche du JSON.
        NSDictionary *directReward = s7tv_JSONDictionaryForKeys(dictionary, @[@"reward"]);
        NSString *directAutomaticType = s7tv_normalizedAutomaticRewardType(
            s7tv_JSONStringForKeys(directReward, @[@"type"]));
        BOOL isDirectAutomaticEvent =
            s7tv_automaticRewardTitleLocalizationKey(directAutomaticType).length > 0 &&
            s7tv_JSONStringForKeys(dictionary, @[@"id"]).length > 0 &&
            s7tv_JSONStringForKeys(dictionary, @[@"redeemed_at", @"redeemedAt"]).length > 0;
        if (isDirectAutomaticEvent) {
            S7TVChatMessage *message =
                s7tv_channelPointMessageFromAutomaticRedemption(dictionary, providers);
            if (message) [messages addObject:message];
            return;
        }

        [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            // L'enveloppe WebSocket Twitch place le vrai payload PubSub dans
            // une chaîne JSON. On ne reparcourt comme JSON que ce champ afin
            // de ne pas tenter de décoder chaque titre/prompt utilisateur.
            if ([key isKindOfClass:[NSString class]] &&
                [key caseInsensitiveCompare:@"pubsub"] == NSOrderedSame &&
                [value isKindOfClass:[NSString class]]) {
                NSData *nestedData = [value dataUsingEncoding:NSUTF8StringEncoding];
                id nested = nestedData.length
                    ? [NSJSONSerialization JSONObjectWithData:nestedData options:0 error:nil]
                    : nil;
                if (nested) s7tv_collectChannelPointMessages(nested, messages, providers);
            } else if ([value isKindOfClass:[NSDictionary class]] ||
                       [value isKindOfClass:[NSArray class]]) {
                s7tv_collectChannelPointMessages(value, messages, providers);
            }
        }];
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            s7tv_collectChannelPointMessages(value, messages, providers);
        }
    }
}

NSArray<S7TVChatMessage *> *s7tv_channelPointMessagesFromWebSocketText(
    NSString *text, NSArray<id<S7TVEmoteProvider>> *providers) {
    NSString *lower = text.lowercaseString;
    BOOL containsCustomRedemption = [lower containsString:@"reward-redeemed"] ||
                                    [lower containsString:@"reward_redeemed"];
    BOOL containsAutomaticRedemption = [lower containsString:@"automatic"] &&
                                       [lower containsString:@"reward"] &&
                                       [lower containsString:@"redeem"];
    if (!containsCustomRedemption && !containsAutomaticRedemption) return @[];

    SevenTVManager *manager = [SevenTVManager sharedManager];
    [manager log:@"[ChatCustom] 🧭 Channel Points WebSocket: reward marker detected (custom=%@ automatic=%@ bytes=%lu)",
        containsCustomRedemption ? @"yes" : @"no",
        containsAutomaticRedemption ? @"yes" : @"no",
        (unsigned long)text.length];

    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id root = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]
        : nil;
    if (!root) {
        [manager log:@"[ChatCustom] 🧭 Channel Points WebSocket: JSON invalide (%@)",
            jsonError.localizedDescription ?: @"payload vide"];
        return @[];
    }
    NSMutableArray<S7TVChatMessage *> *messages = [NSMutableArray array];
    s7tv_collectChannelPointMessages(root, messages, providers);
    if (!messages.count) {
        [manager log:@"[ChatCustom] 🧭 Channel Points WebSocket: aucun événement reward reconnu"];
    } else {
        [manager log:@"[ChatCustom] 🧭 Channel Points WebSocket: %lu événement(s) reconnu(s)",
            (unsigned long)messages.count];
        for (S7TVChatMessage *message in messages) {
            S7TVChannelPointRewardInfo *info = message.channelPointRewardInfo;
            [manager log:@"[ChatCustom] 🧭 Channel Points WebSocket reward: id=%@",
                info.rewardID.length ? info.rewardID : @"<none>"];
        }
    }
    return messages;
}



// ============================================================
// MARK: - S7TVChannelPointRewardInfo
// ============================================================

@implementation S7TVChannelPointRewardInfo

// Adaptateur minimal vers le cache d'images générique. Les récompenses sont
// carrées dans les payloads Twitch et statiques ; la taille finale est
// choisie par le renderer, seul le ratio 1:1 importe ici.
@end


// ============================================================
// MARK: - S7TVChatMessage
// ============================================================

@implementation S7TVChatMessage

- (instancetype)initWithMessageID:(NSString *)messageID
                       timestamp:(NSDate *)timestamp
                    authorUserID:(NSString *)authorUserID
                 authorDisplayName:(NSString *)authorDisplayName
                         rawText:(NSString *)rawText {
    self = [super init];
    if (self) {
        _messageID         = [messageID copy];
        _timestamp         = timestamp;
        _authorUserID      = [authorUserID copy];
        _authorDisplayName = [authorDisplayName copy];
        _rawText           = [rawText copy];
        _twitchEmotesTag   = @"";
        _twitchGIFsTag     = @"";
        _badgeIdentifiers  = @[];
        _type              = S7TVChatMessageTypeNormal;
        _state             = S7TVChatMessageStateNormal;
        _moderationKind    = S7TVChatModerationKindNone;
        _moderationDurationSeconds = 0;
    }
    return self;
}

- (void)applyModerationState:(S7TVChatMessageState)state
              moderationKind:(S7TVChatModerationKind)moderationKind
             durationSeconds:(NSInteger)durationSeconds {
    self.state = state;
    self.moderationKind = moderationKind;
    self.moderationDurationSeconds = MAX(0, durationSeconds);
}

@end


// ============================================================
// MARK: - S7TVChatMessageStore
// ============================================================

@interface S7TVChatMessageStore ()
// Ordre chronologique d'ajout — source de vérité pour l'affichage et pour
// la purge FIFO au-delà de maxMessageCount.
@property (nonatomic, strong) NSMutableArray<S7TVChatMessage *> *orderedMessages;
// Index messageID → message, pour retrouver/mettre à jour en O(1) plutôt
// qu'un scan de orderedMessages à chaque suppression (important : un
// timeout peut viser plusieurs dizaines de messages d'un coup sur une
// grosse chaîne, voir exigence transverse #3).
@property (nonatomic, strong) NSMutableDictionary<NSString *, S7TVChatMessage *> *messagesByID;
// Index authorUserID → ensemble de messageID actuellement en mémoire pour
// cet utilisateur. Alimente markAllMessagesDeletedForUserID: sans scan.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *messageIDsByUserID;
// threadRootID → messageID de réponse, dans l'ordre chronologique d'ajout
// (le message racine lui-même n'est PAS dans ce tableau, seulement ses
// réponses — voir -messagesForThreadRootID: qui reconstitue l'ordre complet
// via orderedMessages si besoin, mais s'appuie d'abord sur cet index pour
// savoir QUELS ids appartiennent au fil sans scanner tout le store).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *replyIDsByThreadRootID;
@property (nonatomic, strong, readwrite) dispatch_queue_t storeQueue;
@property (nonatomic, assign) NSUInteger storeGeneration;
@end

@implementation S7TVChatMessageStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxMessageCount     = 300;
        _orderedMessages     = [NSMutableArray array];
        _messagesByID        = [NSMutableDictionary dictionary];
        _messageIDsByUserID  = [NSMutableDictionary dictionary];
        _replyIDsByThreadRootID = [NSMutableDictionary dictionary];
        _storeGeneration = 1;
        // Même pattern que SevenTVManager.emoteQueue : concurrente, lectures
        // en dispatch_sync, écritures en dispatch_barrier_async.
        _storeQueue = dispatch_queue_create("tv.s7tv.chat-message-store",
                                            DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

#pragma mark - Écriture

// Doit être appelé sous une barrière storeQueue. Centralise l'indexation afin
// que l'ingestion IRC normale et la reconstruction historique ne puissent pas
// diverger (couleurs, utilisateurs et fils de discussion compris).
- (BOOL)s7tv_appendMessageIfUnique:(S7TVChatMessage *)message {
    if (!message.messageID.length || self.messagesByID[message.messageID]) return NO;

    if (message.authorColor && message.authorDisplayName.length) {
        [[SevenTVChatUserColorRegistry sharedRegistry]
            registerColor:message.authorColor forUsername:message.authorDisplayName];
    }

    [self.orderedMessages addObject:message];
    self.messagesByID[message.messageID] = message;

    if (message.authorUserID.length) {
        NSMutableSet<NSString *> *set = self.messageIDsByUserID[message.authorUserID];
        if (!set) {
            set = [NSMutableSet set];
            self.messageIDsByUserID[message.authorUserID] = set;
        }
        [set addObject:message.messageID];
    }

    if (message.replyThreadRootID.length) {
        NSMutableArray<NSString *> *replies = self.replyIDsByThreadRootID[message.replyThreadRootID];
        if (!replies) {
            replies = [NSMutableArray array];
            self.replyIDsByThreadRootID[message.replyThreadRootID] = replies;
        }
        [replies addObject:message.messageID];
        S7TVChatMessage *root = self.messagesByID[message.replyThreadRootID];
        root.replyCount += 1;
    }
    return YES;
}

- (void)s7tv_clearAllMessagesAndIndexes {
    [self.orderedMessages removeAllObjects];
    [self.messagesByID removeAllObjects];
    [self.messageIDsByUserID removeAllObjects];
    [self.replyIDsByThreadRootID removeAllObjects];
}

- (void)s7tv_rebuildWithMessages:(NSArray<S7TVChatMessage *> *)messages {
    [self s7tv_clearAllMessagesAndIndexes];
    // Les instances live peuvent déjà avoir un replyCount calculé. Il faut
    // repartir de zéro avant de rejouer l'indexation du lot fusionné.
    for (S7TVChatMessage *message in messages) message.replyCount = 0;
    for (S7TVChatMessage *message in messages) {
        [self s7tv_appendMessageIfUnique:message];
    }
    [self s7tv_purgeIfNeeded];
}

- (void)addMessage:(S7TVChatMessage *)message {
    if (!message.messageID.length) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ addMessage: ignoré (messageID vide)"];
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        BOOL added = [self s7tv_appendMessageIfUnique:message];
        if (added) {
            [self s7tv_purgeIfNeeded];
        }
    });
}

// Doit être appelé depuis l'intérieur d'un bloc déjà sur storeQueue
// (barrier) — pas de dispatch supplémentaire ici pour éviter un deadlock.
- (void)s7tv_purgeIfNeeded {
    while (self.orderedMessages.count > self.maxMessageCount) {
        S7TVChatMessage *oldest = self.orderedMessages.firstObject;
        if (!oldest) break;
        [self.orderedMessages removeObjectAtIndex:0];
        [self.messagesByID removeObjectForKey:oldest.messageID];
        if (oldest.authorUserID.length) {
            NSMutableSet<NSString *> *set = self.messageIDsByUserID[oldest.authorUserID];
            [set removeObject:oldest.messageID];
            if (set.count == 0) {
                [self.messageIDsByUserID removeObjectForKey:oldest.authorUserID];
            }
        }
        // Retire cette réponse de l'index de son fil si elle en a un — sinon
        // messagesForThreadRootID: renverrait un id purgé (message
        // introuvable dans messagesByID, filtré à la lecture de toute façon,
        // mais autant garder l'index propre plutôt que de compter dessus).
        if (oldest.replyThreadRootID.length) {
            NSMutableArray<NSString *> *replies = self.replyIDsByThreadRootID[oldest.replyThreadRootID];
            [replies removeObject:oldest.messageID];
            if (replies.count == 0) {
                [self.replyIDsByThreadRootID removeObjectForKey:oldest.replyThreadRootID];
            }
        }
    }
}

- (void)markMessageDeletedByID:(NSString *)messageID {
    [self markMessageDeletedByID:messageID completion:nil];
}

- (void)markMessageDeletedByID:(NSString *)messageID
                    completion:(void (^)(void))completion {
    if (!messageID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        S7TVChatMessage *msg = self.messagesByID[messageID];
        if (msg) {
            // Le contenu original reste intact : seul le mode d'affichage
            // change, conformément au comportement Phase 5.
            [msg applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:S7TVChatModerationKindMessageDeleted
                      durationSeconds:0];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID {
    [self markAllMessagesDeletedForUserID:authorUserID completion:nil];
}

- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID
                              completion:(void (^)(void))completion {
    [self markAllMessagesDeletedForUserID:authorUserID
                           moderationKind:S7TVChatModerationKindPermanentBan
                          durationSeconds:0
                                completion:completion];
}

- (void)markAllMessagesDeletedForUserID:(NSString *)authorUserID
                         moderationKind:(S7TVChatModerationKind)moderationKind
                        durationSeconds:(NSInteger)durationSeconds
                              completion:(void (^)(void))completion {
    if (!authorUserID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        NSSet<NSString *> *ids = self.messageIDsByUserID[authorUserID];
        for (NSString *msgID in ids) {
            S7TVChatMessage *msg = self.messagesByID[msgID];
            [msg applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:moderationKind
                      durationSeconds:durationSeconds];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)toggleExpandedForMessageID:(NSString *)messageID {
    [self toggleExpandedForMessageID:messageID completion:nil];
}

- (void)toggleExpandedForMessageID:(NSString *)messageID
                         completion:(void (^)(void))completion {
    if (!messageID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    S7TVChatMessage *message = [self messageWithID:messageID];
    if (!message) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    [self toggleExpandedForMessage:message completion:^(__unused S7TVChatMessage *updatedMessage) {
        if (completion) completion();
    }];
}

- (void)toggleExpandedForMessage:(S7TVChatMessage *)message
                      completion:(void (^)(S7TVChatMessage *updatedMessage))completion {
    if (!message.messageID.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(message); });
        }
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        // Le fallback est volontaire : pendant le gel du transcript, la vue
        // retient le modèle visible après sa purge FIFO. Son ID n'est alors
        // plus indexé dans le store, mais le contenu doit rester interactif.
        S7TVChatMessage *canonical = self.messagesByID[message.messageID];
        BOOL displayedIsDeleted = message.state == S7TVChatMessageStateDeletedCollapsed ||
                                  message.state == S7TVChatMessageStateDeletedExpanded;
        S7TVChatMessage *stateSource = displayedIsDeleted ? message : canonical;
        S7TVChatMessageState nextState = stateSource.state;
        if (stateSource.state == S7TVChatMessageStateDeletedCollapsed) {
            nextState = S7TVChatMessageStateDeletedExpanded;
        } else if (stateSource.state == S7TVChatMessageStateDeletedExpanded) {
            nextState = S7TVChatMessageStateDeletedCollapsed;
        }
        // Calculer une seule transition, puis la recopier sur l'instance
        // canonique ET celle réellement affichée. Les basculer séparément
        // ferait un double-toggle lorsqu'elles désignent le même objet.
        if (stateSource && nextState != S7TVChatMessageStateNormal) {
            [canonical applyModerationState:nextState
                             moderationKind:stateSource.moderationKind
                            durationSeconds:stateSource.moderationDurationSeconds];
            if (message != canonical) {
                [message applyModerationState:nextState
                               moderationKind:stateSource.moderationKind
                              durationSeconds:stateSource.moderationDurationSeconds];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(message);
            });
        }
    });
}

- (void)markAllMessagesDeleted {
    [self markAllMessagesDeletedWithCompletion:nil];
}

- (void)markAllMessagesDeletedWithCompletion:(void (^)(void))completion {
    dispatch_barrier_async(self.storeQueue, ^{
        for (S7TVChatMessage *msg in self.orderedMessages) {
            if (msg.type == S7TVChatMessageTypeHistoryWelcome ||
                msg.type == S7TVChatMessageTypeHistoryDivider) continue;
            [msg applyModerationState:S7TVChatMessageStateDeletedCollapsed
                       moderationKind:S7TVChatModerationKindChatCleared
                      durationSeconds:0];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)removeAllMessages {
    dispatch_barrier_async(self.storeQueue, ^{
        self.storeGeneration += 1;
        [self s7tv_clearAllMessagesAndIndexes];
    });
}

- (void)replaceAllMessages:(NSArray<S7TVChatMessage *> *)messages
                completion:(void (^)(void))completion {
    NSArray<S7TVChatMessage *> *snapshot = [messages copy] ?: @[];
    dispatch_barrier_async(self.storeQueue, ^{
        self.storeGeneration += 1;
        [self s7tv_rebuildWithMessages:snapshot];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)prependHistoricalMessages:(NSArray<S7TVChatMessage *> *)messages
                        completion:(void (^)(void))completion {
    [self prependHistoricalMessages:messages ifCurrent:nil completion:completion];
}

- (void)prependHistoricalMessages:(NSArray<S7TVChatMessage *> *)messages
                         ifCurrent:(BOOL (^)(void))isCurrent
                         completion:(void (^)(void))completion {
    NSArray<S7TVChatMessage *> *historical = [messages copy] ?: @[];
    dispatch_barrier_async(self.storeQueue, ^{
        NSArray<S7TVChatMessage *> *existing = [self.orderedMessages copy];
        NSMutableSet<NSString *> *existingIDs = [NSMutableSet setWithCapacity:existing.count];
        for (S7TVChatMessage *message in existing) {
            if (message.messageID.length) [existingIDs addObject:message.messageID];
        }
        NSMutableArray<S7TVChatMessage *> *merged = [NSMutableArray arrayWithCapacity:
            historical.count + existing.count];
        for (S7TVChatMessage *message in historical) {
            // La copie live gagne toujours : elle peut déjà avoir reçu un
            // CLEARMSG/timeout pendant que la requête historique finissait.
            if (message.messageID.length && ![existingIDs containsObject:message.messageID]) {
                [merged addObject:message];
            }
        }
        [merged addObjectsFromArray:existing];
        if (isCurrent && !isCurrent()) return;
        [self s7tv_rebuildWithMessages:merged];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)retokenizeMessagesUsingBlock:(NSArray<S7TVChatToken *> * (^)(S7TVChatMessage *message))tokenizer
                          completion:(void (^ _Nullable)(void))completion {
    if (!tokenizer) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        for (S7TVChatMessage *message in self.orderedMessages) {
            message.tokens = tokenizer(message);
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)mergeChannelPointCompanionMessage:(S7TVChatMessage *)companion
                                completion:(void (^ _Nullable)(NSString * _Nullable))completion {
    if (!companion.channelPointRewardID.length || !companion.authorUserID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    dispatch_barrier_async(self.storeQueue, ^{
        S7TVChatMessage *matched = nil;
        for (S7TVChatMessage *candidate in self.orderedMessages.reverseObjectEnumerator) {
            if (candidate.type != S7TVChatMessageTypeChannelPointRedemption) continue;
            if (![candidate.channelPointRewardID isEqualToString:companion.channelPointRewardID] ||
                ![candidate.authorUserID isEqualToString:companion.authorUserID]) continue;
            if (ABS([candidate.timestamp timeIntervalSinceDate:companion.timestamp]) > 8.0) continue;
            if (candidate.rawText.length && companion.rawText.length &&
                ![candidate.rawText isEqualToString:companion.rawText]) continue;
            matched = candidate;
            break;
        }

        if (matched) {
            if (companion.rawText.length) matched.rawText = companion.rawText;
            matched.tokens = companion.tokens;
            matched.twitchEmotesTag = companion.twitchEmotesTag ?: @"";
            matched.twitchGIFsTag = companion.twitchGIFsTag ?: @"";
            matched.badgeIdentifiers = companion.badgeIdentifiers ?: @[];
            if (companion.sharedChatSourceChannelID.length) {
                matched.sharedChatSourceChannelID = companion.sharedChatSourceChannelID;
            }
            if (companion.authorColor) matched.authorColor = companion.authorColor;
            matched.isActionMessage = companion.isActionMessage;
        }
        NSString *mergedID = [matched.messageID copy];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(mergedID); });
        }
    });
}

#pragma mark - Lecture

- (NSArray<S7TVChatMessage *> *)allMessages {
    __block NSArray<S7TVChatMessage *> *snapshot;
    dispatch_sync(self.storeQueue, ^{
        snapshot = [self.orderedMessages copy];
    });
    return snapshot;
}

- (NSUInteger)generation {
    __block NSUInteger generation;
    dispatch_sync(self.storeQueue, ^{
        generation = self.storeGeneration;
    });
    return generation;
}

- (nullable S7TVChatMessage *)messageWithID:(NSString *)messageID {
    if (!messageID.length) return nil;
    __block S7TVChatMessage *result;
    dispatch_sync(self.storeQueue, ^{
        result = self.messagesByID[messageID];
    });
    return result;
}

- (NSArray<S7TVChatMessage *> *)messagesForThreadRootID:(NSString *)threadRootID {
    if (!threadRootID.length) return @[];
    __block NSArray<S7TVChatMessage *> *result;
    dispatch_sync(self.storeQueue, ^{
        NSMutableArray<S7TVChatMessage *> *messages = [NSMutableArray array];
        // Le message racine lui-même compte comme premier message du fil
        // s'il est encore en mémoire.
        S7TVChatMessage *root = self.messagesByID[threadRootID];
        if (root) [messages addObject:root];
        NSArray<NSString *> *replyIDs = self.replyIDsByThreadRootID[threadRootID];
        for (NSString *msgID in replyIDs) {
            S7TVChatMessage *msg = self.messagesByID[msgID];
            if (msg) [messages addObject:msg]; // absent = purgé, on saute
        }
        result = messages;
    });
    return result;
}

- (void)seedReadOnlyWithMessages:(NSArray<S7TVChatMessage *> *)messages {
    dispatch_barrier_async(self.storeQueue, ^{
        [self.orderedMessages removeAllObjects];
        [self.messagesByID removeAllObjects];
        [self.messageIDsByUserID removeAllObjects];
        [self.replyIDsByThreadRootID removeAllObjects];
        for (S7TVChatMessage *msg in messages) {
            if (!msg.messageID.length) continue;
            [self.orderedMessages addObject:msg];
            self.messagesByID[msg.messageID] = msg;
        }
    });
}

@end
