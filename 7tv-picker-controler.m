/*
 * 7tv-picker-controler.m
 * Extrait de SevenTVManager.m (nettoyage picker).
 *
 * Picker d'emotes 7TV — grille + onglets (Favoris / 7TV) + recherche +
 * panneau des tailles (délégué à SevenTVPickerSizesPanel, composant enfant
 * instancié paresseusement, voir -sizesPanel ci-dessous).
 *
 * Entièrement indépendant du picker natif de Twitch : aucune donnée, aucun
 * onglet, aucune logique ne dépend des emotes natives Twitch.
 */

#import "7tv-picker-controler.h"
#import "SevenTVManager.h"
#import "7tv-picker-sizes.h"
#import "7tv-localization.h"
#import "7tv-picker-resolved-emote.h"
#import "7tv-picker-cell.h"
#import "SevenTVChatCustomView.h"
#import "SevenTVEmoteImageCache.h"
#import "SevenTVEmoteAnimationEngine.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"

@interface SevenTVEmotePickerController ()

// Panneau des tailles — composant enfant, créé paresseusement (voir -sizesPanel)
@property (nonatomic, strong) SevenTVPickerSizesPanel *sizesPanel;

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
@property (nonatomic, strong, readwrite) NSArray<SevenTVEmote *> *emotePickerAllEmotes;
// L'alerte de recherche emprunte temporairement le first responder au champ
// Twitch. Pendant ce transfert, UITextViewTextDidEndEditingNotification ne
// doit pas être interprétée comme une vraie fermeture du picker.
@property (nonatomic, assign) BOOL pickerSearchAlertActive;

// Arrays filtrés pour l'affichage dans le picker (3 sections)
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerChannelEmotes;
@property (nonatomic, strong, readwrite) NSArray<SevenTVEmote *> *emotePickerGlobalEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerOtherEmotes; // compatibilité

// Bouton ⚙️ du panneau des tailles (chrome du picker — voir SevenTVPickerSizesPanel
// pour la logique/les données du panneau lui-même)
@property (nonatomic, weak) UIButton *pickerSizesToggleBtn;
// Bouton réglages, collé au bouton des tailles — ouvre le même écran que le
// bouton flottant 7TV (voir -[SevenTVManager presentSettingsMenu]).
@property (nonatomic, weak) UIButton *pickerSettingsBtn;
// Capsule commune qui regroupe pickerSettingsBtn + pickerSizesToggleBtn dans
// un seul fond pilule partagé (même langage visuel que pickerTabCapsuleView /
// pickerTabCapsuleView, où plusieurs icônes flottent ensemble sur un
// seul fond) — les 2 boutons sont ainsi visuellement collés au lieu d'être
// 2 pastilles séparées avec un espace entre elles.
@property (nonatomic, weak) UIView   *pickerToolsCapsuleView;
@property (nonatomic, assign) BOOL   pickerSizesPanelVisible;

// Conteneur du faux chat (SevenTVPickerSizesPanel.fakeChatView), ajouté
// directement à la key window — pas à emotePickerView — car ce dernier EST
// l'inputView du clavier et ne peut pas héberger un aperçu positionné
// librement par-dessus le vrai chat. weak : la key window (superview) le
// retient, pas ce controller (même logique que emotePickerTextField).
@property (nonatomic, weak) UIView *pickerFakeChatPreviewView;

// ── Refonte tabbed + refonte visuelle du picker (style 7TV PC) ──────────
// Onglet actif : 0 = Favoris, 1 = 7TV (voir S7TVPickerTab*)
@property (nonatomic, assign) NSInteger pickerActiveTab;
// Mémorise l'onglet actif juste avant qu'une recherche démarre, pour le
// restaurer quand le champ de recherche redevient vide (la recherche
// bascule automatiquement Favoris → Channel → Globales, voir point 3).
@property (nonatomic, assign) BOOL      pickerIsSearching;
@property (nonatomic, assign) NSInteger pickerPreSearchTab;
// Plus de header, plus de dock plein fond : TOUT est flottant par-dessus la
// grille (comme la pastille fermer), même langage visuel partout → aucun
// bandeau opaque ne mange de la place, on voit plus d'emotes.
// Capsule unique bas-gauche à 3 boutons (Favoris / Channel / Globales) —
// fusion de l'ancienne capsule d'onglets (Favoris/7TV) et de l'ancienne
// capsule sous-choix (Chaîne/Globales, haut-gauche, supprimée).
@property (nonatomic, weak) UIButton  *pickerSubChoiceChannelBtn;    // bouton "Channel" de la capsule unique (avatar de chaîne)
@property (nonatomic, weak) UIView    *pickerTabCapsuleView;         // bas gauche (Favoris/Channel/Globales)
@property (nonatomic, strong) NSMutableArray<UIButton *> *pickerTabButtons;
@property (nonatomic, weak) UIView    *pickerTabIndicatorView;       // pastille violette qui glisse entre les 3 boutons
@property (nonatomic, weak) UIView    *pickerSearchCapsuleView;      // bas, pleine largeur (recherche)
@property (nonatomic, weak) UIButton  *pickerSearchClearBtn;         // petite croix à droite du champ, visible si texte non vide
// Pendant un drag/deceleration, les miniatures continuent de charger et chaque
// cellule visible demande immédiatement une preview animée annulable. Dès
// qu'elle sort de l'écran, didEndDisplayingCell coupe observation et décodage.
@property (nonatomic, assign) BOOL pickerScrollInProgress;

// ── Avatar de chaîne (bouton "Chaîne" de la capsule sous-choix) ────────────
// Cache mémoire simple par channelID — le controller vit toute la durée de
// l'app (jamais désalloué), donc pas besoin d'éviction : peu de chaînes
// visitées par session.
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *pickerChannelAvatarCache;
// ID de la chaîne dont l'avatar est actuellement en cours de fetch — évite
// de déclencher un 2e appel Helix si le picker est rouvert (ou la notif
// reçue à nouveau) pendant qu'une requête est déjà en vol pour cette chaîne.
@property (nonatomic, copy) NSString *pickerChannelAvatarFetchingID;

- (void)_s7tv_deactivateVisiblePickerAnimations;
- (void)_s7tv_activateVisiblePickerAnimations;
- (void)_s7tv_scheduleAnimationForPickerCell:(S7TVEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath;
- (void)_s7tv_scheduleStaticImageForPickerCell:(S7TVEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath;
- (BOOL)_s7tv_configureAnimatedPickerCell:(S7TVEmotePickerCell *)cell
                             resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode;

@end

@implementation SevenTVEmotePickerController

// Valeurs par défaut reprises telles quelles de l'ancien -[SevenTVManager setup]
// (avant l'extraction du picker dans ce fichier) : onglet Favoris au départ,
// sous-choix Channel pour l'onglet 7TV, tableau des boutons d'onglets prêt
// à être rempli par -_createEmotePickerViewWithFrame:.
- (instancetype)init {
    self = [super init];
    if (self) {
        _pickerActiveTab                  = 0; // S7TVPickerTabFavorites
        _pickerTabButtons                 = [NSMutableArray array];
        _emotePickerFavoriteEmotes = @[];
        _emotePickerChannelEmotes  = @[];
        _emotePickerGlobalEmotes   = @[];
        _emotePickerOtherEmotes    = @[];
        _pickerChannelAvatarCache  = [NSMutableDictionary dictionary];

        // Abonnement permanent à S7TVChannelJoined (postée depuis
        // s7tv_handleRoomState dans TweakSevenTV.m) — même logique que
        // SevenTVBadgeProvider : ce controller n'est jamais désalloué en
        // cours de vie de l'app (cleanupPickerForStreamClose masque juste la
        // vue, ne détruit pas l'objet), donc pas de -dealloc pour se
        // désabonner.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_channelJoinedNotification:)
                                                      name:@"S7TVChannelJoined"
                                                    object:nil];

        // Le TextEntryView de Twitch peut résigner le first responder sans
        // passer par notre bouton (ex: tap ailleurs dans l'app) — UIKit
        // retire alors l'inputView (notre picker) tout seul, SANS jamais
        // appeler _hideEmotePicker. Le faux chat flottant (attaché à la key
        // window, indépendant du clavier) restait donc affiché tant que le
        // picker n'était pas rouvert/refermé manuellement. On rattrape ça ici.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(_s7tv_textEntryDidEndEditing:)
                                                      name:UITextViewTextDidEndEditingNotification
                                                    object:nil];
    }
    return self;
}

- (void)_s7tv_textEntryDidEndEditing:(NSNotification *)note {
    if (note.object != self.emotePickerTextEntryView) return;
    if (!self.emotePickerView || self.emotePickerView.hidden) return; // picker déjà fermé, rien à faire
    if (self.pickerSearchAlertActive) return; // focus prêté à l'alerte de recherche

    // Pas de resignFirstResponder/reloadInputViews ici : la résignation est
    // déjà en cours côté UIKit (c'est elle qui a déclenché cette notif).
    // On se contente de remettre notre propre état à plat.
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
    self.emotePickerTextEntryView = nil;
    self.emotePickerTextField = nil;
    self.emotePickerView.hidden = YES;
    [self _hideFakeChatPreview];
}

// Panneau des tailles — composant enfant, créé à la demande la première fois
// qu'on y touche (toggle du bouton ⚙️ ou construction de la vue du picker).
- (SevenTVPickerSizesPanel *)sizesPanel {
    if (!_sizesPanel) {
        _sizesPanel = [[SevenTVPickerSizesPanel alloc] init];
        _sizesPanel.picker = self;
    }
    return _sizesPanel;
}

// ID de cellule pour la collection
static NSString *const kEmoteCellID = @"S7TVEmoteCell";

// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize = 40.0;

// ── Onglets du picker refondu (style 7TV PC) ──────────────────────────────
// 3 valeurs : Favoris / Channel / Globales, fusion de l'ancien tab
// (Favoris/7TV) et de l'ancien sous-choix (Chaîne/Globales).
typedef NS_ENUM(NSInteger, S7TVPickerTab) {
    S7TVPickerTabFavorites = 0,
    S7TVPickerTabChannel   = 1,
    S7TVPickerTabGlobal    = 2,
};

// ── Dimensions du picker refondu ────────────────────────────────────────
// Plus de header, plus de dock opaque : la grille occupe 100% du picker
// (y=0 à height) et TOUT flotte par-dessus (fermer / sous-choix en haut,
// onglets + ⚙️ + recherche en bas), façon pastilles translucides façon
// petit sélecteur 7TV PC. layout.sectionInset réserve juste assez de place
// en haut et en bas pour que les cellules ne passent jamais dessous.
static const CGFloat kS7TVPickerFloatSize    = 30.0; // diamètre/hauteur des pastilles flottantes (fermer, onglets, sous-choix, ⚙️)
static const CGFloat kS7TVPickerFloatMargin  = 8.0;  // marge entre une pastille et le bord du picker
static const CGFloat kS7TVPickerFloatGap     = 6.0;  // écart vertical entre 2 rangées de pastilles flottantes
static const CGFloat kS7TVPickerSearchH      = 38.0; // hauteur de la capsule de recherche
// Zone totale réservée en bas de la grille (sectionInset.bottom) pour ne
// jamais cacher une cellule sous les onglets/⚙️/recherche flottants :
// marge + ligne d'onglets + écart + recherche + marge.
static const CGFloat kS7TVPickerBottomZoneH  =
    kS7TVPickerFloatMargin + kS7TVPickerFloatSize + kS7TVPickerFloatGap + kS7TVPickerSearchH + kS7TVPickerFloatMargin;

static const CGFloat kS7TVPickerGridDefaultH =
    280.0; // hauteur du picker en mode grille — référence pour le mode "tailles" (point 5)
// (annulation lors du recyclage)
- (NSURLSession *)pickerImageSession {
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

- (UIImage *)decodePickerImageData:(NSData *)data wantsAnimated:(BOOL)wantsAnimated {
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

// ── Avatar de la chaîne (bouton "Chaîne" de la capsule sous-choix) ─────────
//
// Point d'entrée notif : S7TVChannelJoined n'est postée que pour un VRAI
// changement de broadcaster ID (voir s7tv_handleRoomState), jamais pour un
// simple re-join du même channel — pas de refetch inutile.
- (void)_s7tv_channelJoinedNotification:(NSNotification *)note {
    NSString *channelID = note.userInfo[@"channelID"];
    if (!channelID.length) return;

    // CRITIQUE : S7TVChannelJoined est postée depuis s7tv_handleRoomState
    // pendant le traitement des messages IRC (WebSocket), donc HORS main
    // thread. NSNotificationCenter exécute les observers de façon SYNCHRONE
    // sur le thread qui poste — sans ce dispatch, tout ce qui suit (UIButton
    // setImage:) s'exécute hors main thread : ça ne crashe pas forcément,
    // mais ça ne se rend pas de façon fiable (c'était la cause du bug "l'avatar
    // ne change pas au changement de chaîne").
    dispatch_async(dispatch_get_main_queue(), ^{
        // Le bouton n'existe que si le picker a déjà été construit une première fois.
        if (!self.pickerSubChoiceChannelBtn) return;

        UIImage *cached = self.pickerChannelAvatarCache[channelID];
        if (cached) {
            [self _s7tv_applyChannelAvatarImage:cached];
        } else {
            // Nouvelle chaîne pas encore en cache → on repasse immédiatement au
            // placeholder générique le temps du fetch, pour ne jamais laisser
            // affiché l'avatar de l'ancienne chaîne par erreur.
            [self _s7tv_resetChannelButtonToPlaceholder];
            [self _s7tv_loadChannelAvatarForChannelID:channelID];
        }
    });
}

// Appelé à CHAQUE ouverture du picker (voir -_buildAndShowEmotePickerForView:) :
// applique l'avatar déjà en cache pour la chaîne courante, ou lance le fetch
// sinon. C'est le filet de sécurité qui ne dépend pas du timing de la notif
// S7TVChannelJoined — utile si la chaîne a changé pendant que le picker
// était fermé (aucune autre occasion de revérifier dans ce cas).
- (void)_s7tv_refreshChannelAvatarIfNeeded {
    NSString *channelID = [SevenTVManager sharedManager].currentChannelTwitchID;
    if (!channelID.length) return; // pas encore de chaîne connue → fallback reste affiché

    UIImage *cached = self.pickerChannelAvatarCache[channelID];
    if (cached) {
        [self _s7tv_applyChannelAvatarImage:cached];
    } else {
        [self _s7tv_loadChannelAvatarForChannelID:channelID];
    }
}

// Fetch Helix Get Users (avatar) puis téléchargement/décodage de l'image via
// le pipeline partagé du picker (pickerImageSession / decodePickerImageData:),
// même pattern que les previews de SevenTVPickerSizesPanel. Échec silencieux
// à toutes les étapes : le placeholder SF Symbol reste affiché, jamais de
// bouton vide/crashé.
- (void)_s7tv_loadChannelAvatarForChannelID:(NSString *)channelID {
    if (!channelID.length) return;
    if ([self.pickerChannelAvatarFetchingID isEqualToString:channelID]) return; // déjà en vol

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSString *token    = mgr.twitchToken;    // déjà normalisé "Bearer <token>"
    NSString *clientID = mgr.twitchClientID;
    if (!token.length || !clientID.length) {
        [mgr log:@"⚠️ Avatar chaîne: token/Client-ID Twitch pas encore capturés — fallback conservé"];
        return;
    }

    self.pickerChannelAvatarFetchingID = channelID;

    NSString *encodedID = [channelID stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    if (!encodedID.length) {
        // Ne devrait jamais arriver (channelID est numérique), mais un id=
        // vide/absent ferait tomber Helix sur son fallback "token owner"
        // (retourne notre propre compte) — mieux vaut ne pas envoyer la
        // requête du tout que risquer d'afficher notre propre avatar.
        self.pickerChannelAvatarFetchingID = nil;
        [mgr log:@"❌ Avatar chaîne: échec encodage id=%@, requête annulée", channelID];
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"https://api.twitch.tv/helix/users?id=%@", encodedID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:token    forHTTPHeaderField:@"Authorization"];
    [req setValue:clientID forHTTPHeaderField:@"Client-Id"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        NSString *avatarURLString = nil;
        if (data && !error) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *users = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if ([users isKindOfClass:[NSArray class]] && users.count > 0) {
                NSDictionary *user = users.firstObject;
                if ([user isKindOfClass:[NSDictionary class]]) {
                    // Garde-fou : Helix "Get Users" retourne le token owner si
                    // le paramètre id= est absent/vide (comportement documenté
                    // de l'API). On vérifie explicitement que l'id retourné
                    // correspond bien à celui demandé — sans ça, un id= mal
                    // formé pourrait faire afficher NOTRE PROPRE avatar au lieu
                    // de celui de la chaîne, sans erreur réseau détectable.
                    id returnedID = user[@"id"];
                    BOOL idMatches = [returnedID isKindOfClass:[NSString class]]
                        && [returnedID isEqualToString:channelID];
                    if (idMatches) {
                        id urlVal = user[@"profile_image_url"];
                        if ([urlVal isKindOfClass:[NSString class]]) avatarURLString = urlVal;
                    } else {
                        [[SevenTVManager sharedManager] log:
                            @"❌ Avatar chaîne: id retourné (%@) ≠ id demandé (%@) — réponse ignorée",
                            returnedID, channelID];
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && [strongSelf.pickerChannelAvatarFetchingID isEqualToString:channelID]) {
                strongSelf.pickerChannelAvatarFetchingID = nil;
            }
        });

        if (!avatarURLString.length) {
            [[SevenTVManager sharedManager] log:@"⚠️ Avatar chaîne: échec Helix Get Users (id=%@)", channelID];
            return;
        }
        NSURL *avatarURL = [NSURL URLWithString:avatarURLString];
        if (!avatarURL) return;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURLSessionDataTask *imgTask = [[strongSelf pickerImageSession] dataTaskWithURL:avatarURL
            completionHandler:^(NSData *imgData, NSURLResponse *r, NSError *e) {
            if (!imgData) return;
            UIImage *decoded = [strongSelf decodePickerImageData:imgData wantsAnimated:NO];
            if (!decoded) return;

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                strongSelf2.pickerChannelAvatarCache[channelID] = decoded;
                // Garde-fou anti-course : la chaîne a pu changer pendant le
                // fetch (changement rapide) → n'appliquer que si toujours
                // d'actualité, jamais l'avatar d'une chaîne déjà quittée.
                if ([[SevenTVManager sharedManager].currentChannelTwitchID isEqualToString:channelID]) {
                    [strongSelf2 _s7tv_applyChannelAvatarImage:decoded];
                }
            });
        }];
        [imgTask resume];
    }];
    [task resume];
}

// Redécoupe/redimensionne l'avatar en un cercle plein cadre de `diameter`
// points, prêt à poser tel quel sur channelBtn. Nécessaire car channelBtn
// est en layout frame-based (pas d'autolayout) : UIButton ne redimensionne
// PAS automatiquement une image à la taille du bouton dans ce mode — sans ce
// pré-traitement, un avatar Twitch (souvent 300x300) s'afficherait à sa
// taille native et détonnerait la capsule.
- (UIImage *)_s7tv_circularAvatarFromImage:(UIImage *)source diameter:(CGFloat)diameter {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGSize targetSize = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] addClip];
        // Aspect-fill : centre le plus petit côté de la source sur le cadre cible.
        CGFloat scale = MAX(diameter / source.size.width, diameter / source.size.height);
        CGFloat drawW = source.size.width  * scale;
        CGFloat drawH = source.size.height * scale;
        CGRect drawRect = CGRectMake((diameter - drawW) / 2.0, (diameter - drawH) / 2.0, drawW, drawH);
        [source drawInRect:drawRect];
    }];
}

// Diamètre réel de l'avatar dessiné — volontairement plus petit que
// kS7TVPickerFloatSize (30pt, taille du bouton) pour laisser une marge
// cohérente avec le placeholder SF Symbol (14pt) et le logo 7TV du bouton
// voisin (insets 9pt) ; un cercle plein cadre 30pt collait aux bords et
// paraissait trop imposant dans la capsule.
static const CGFloat kS7TVPickerAvatarDiameter = 24.0;

- (void)_s7tv_applyChannelAvatarImage:(UIImage *)image {
    UIButton *btn = self.pickerSubChoiceChannelBtn;
    if (!btn || !image) return;
    UIImage *circular = [self _s7tv_circularAvatarFromImage:image diameter:kS7TVPickerAvatarDiameter];
    if (!circular) return;
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[circular imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
          forState:UIControlStateNormal];
}

// Fallback propre — remet le symbole générique d'origine (mêmes réglages
// qu'à la création de channelBtn).
- (void)_s7tv_resetChannelButtonToPlaceholder {
    UIButton *btn = self.pickerSubChoiceChannelBtn;
    if (!btn) return;
    UIImageSymbolConfiguration *avCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    [btn setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:avCfg]
          forState:UIControlStateNormal];
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
        [[SevenTVManager sharedManager] log:@"⚠️ emotePickerTextEntryView orphelin (window=nil) → reset cache"];
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
                [[SevenTVManager sharedManager] log:@"✅ TextEntryView trouvé: %@", cn];
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
                    [[SevenTVManager sharedManager] log:@"⚠️ TextEntryView fallback UITextView: %@", NSStringFromClass([v class])];
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
    self.pickerSearchAlertActive = NO;
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
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
    [self _hideFakeChatPreview];
}
- (void)cleanupPickerForStreamClose {
    [[SevenTVManager sharedManager] log:@"🔒 cleanupPickerForStreamClose → nettoyage picker"];
    self.pickerSearchAlertActive = NO;
    [self _s7tv_deactivateVisiblePickerAnimations];
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
    self.pickerScrollInProgress = NO;
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
    [self _hideFakeChatPreview];
}

// IVar de cache pour le tri — invalidé quand globalEmotes/channelEmotes changent
// Accédé UNIQUEMENT depuis le main thread (picker).
static NSArray<SevenTVEmote *> *s_cachedSortedEmotes    = nil;
static NSString                *s_cachedSortKey          = nil; // hash des deux sets

// Appelée par SevenTVManager quand le catalogue d'emotes change (nouveau
// channel, refresh global/channel) — sans ça le picker réafficherait un tri
// obsolète (anciennes emotes) au prochain -toggleEmotePickerForChatInputView:.
- (void)invalidateSortCache {
    s_cachedSortedEmotes = nil;
    s_cachedSortKey = nil;
}

- (void)cancelPendingImageLoadsWithCompletion:(void (^)(void))completion {
    [[self pickerImageSession] getAllTasksWithCompletionHandler:
        ^(NSArray<__kindof NSURLSessionTask *> *tasks) {
            for (NSURLSessionTask *task in tasks) [task cancel];
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        }];
}

- (void)favoritesDidChange {
    NSAssert([NSThread isMainThread], @"SevenTVEmotePickerController: main thread uniquement");
    NSString *query = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:query];
    if (self.emoteCollectionView) {
        [self _s7tv_deactivateVisiblePickerAnimations];
        [self.emoteCollectionView reloadData];
    }
}

static NSString *s7tv_emoteSetKey(NSDictionary *global, NSDictionary *channel) {
    // Clé simple = count@channel|count@global — si les deux counts n'ont pas changé,
    // la liste est identique dans la grande majorité des cas.
    return [NSString stringWithFormat:@"%lu|%lu",
            (unsigned long)channel.count, (unsigned long)global.count];
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // ── Rassembler toutes les emotes (channel d'abord, puis globales) ──────
    __block NSDictionary *global, *channel;
    dispatch_sync([SevenTVManager sharedManager].emoteQueue, ^{
        global  = [SevenTVManager sharedManager].globalEmotes  ?: @{};
        channel = [SevenTVManager sharedManager].channelEmotes ?: @{};
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

    // ── Choix de l'onglet de départ : Favoris s'il y a au moins un favori
    // (sur la chaîne courante), sinon 7TV/Channel. Revérifié à CHAQUE
    // ouverture — pas seulement quand on était déjà sur Favoris — pour
    // refléter les favoris ajoutés/retirés ou un changement de chaîne
    // depuis la dernière ouverture du picker.
    if (self.emotePickerFavoriteEmotes.count > 0) {
        self.pickerActiveTab = S7TVPickerTabFavorites;
    } else {
        self.pickerActiveTab = S7TVPickerTabChannel;
    }
    [self _updatePickerArraysForSearch:@""]; // recalcule emotePickerEmotes pour l'onglet choisi

    // ── Créer le picker si besoin ─────────────────────────────────────
    // Recalcule la taille à chaque ouverture pour s'adapter à l'orientation courante.
    CGSize screenSz = UIScreen.mainScreen.bounds.size;
    CGFloat pickerH = kS7TVPickerGridDefaultH;
    CGRect pickerFrame = CGRectMake(0, 0, screenSz.width, pickerH);
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame];
    } else if (self.pickerSizesPanelVisible) {
        // Le picker existait déjà et avait été laissé sur le panneau des
        // tailles lors de la dernière fermeture → on revient toujours en
        // mode grille à l'ouverture (pas d'animation, c'est un état initial).
        self.pickerSizesPanelVisible = NO;
        self.sizesPanel.panelView.hidden = YES;
        self.emoteCollectionView.hidden = NO;
        self.pickerSearchCapsuleView.hidden = NO;
        self.pickerTabCapsuleView.hidden = NO;
        for (UIButton *btn in self.pickerTabButtons) btn.hidden = NO;
        self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        // Remettre l'icône ⚙️ (pas juste la couleur) — sans ça le bouton
        // gardait visuellement la flèche "retour" du panneau des tailles
        // alors qu'on vient de revenir en mode grille.
        UIImageSymbolConfiguration *resetCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        [self.pickerSizesToggleBtn setImage:[UIImage systemImageNamed:@"textformat.size"
                                                      withConfiguration:resetCfg]
                                    forState:UIControlStateNormal];
    }
    self.emotePickerView.frame = pickerFrame;
    // Revérifie l'avatar de chaîne à CHAQUE ouverture (pas seulement à la
    // création du picker) : si la chaîne a changé pendant que le picker
    // était fermé, c'est le seul filet de sécurité qui ne dépend pas du
    // timing de la notif S7TVChannelJoined. No-op si déjà à jour (cache hit).
    [self _s7tv_refreshChannelAvatarIfNeeded];
    // Repositionne toutes les zones (grille / pastilles flottantes / panneau
    // des tailles) — s'adapte à l'orientation courante et à l'onglet actif,
    // et resynchronise au passage le surlignage des onglets + la capsule
    // sous-choix (utile si l'onglet a changé automatiquement ci-dessus).
    [self _s7tv_relayoutPickerForSize:pickerFrame.size];

    // Reset la recherche
    self.emoteSearchField.text = @"";
    [self _s7tv_updateSearchClearVisibility];
    [self _updatePickerArraysForSearch:@""];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    // À ce stade la collection view n'est pas encore présentée (inputView pas
    // encore assigné/becomeFirstResponder pas encore appelé plus bas) → son
    // contentSize n'est pas garanti calculé, donc un setContentOffset ici peut
    // être un no-op silencieux. On force le layout pour rendre l'appel fiable.
    [self.emoteCollectionView.collectionViewLayout invalidateLayout];
    [self.emoteCollectionView layoutIfNeeded];
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
            [[SevenTVManager sharedManager] log:@"ℹ️ tv pas firstResponder → becomeFirstResponder"];
            [tv becomeFirstResponder];
        }
        // Étape 3 : recharger pour appliquer le nouvel inputView
        [tv reloadInputViews];
        [[SevenTVManager sharedManager] log:@"✅ picker en dessous de la chat bar (inputView) sur %@", NSStringFromClass([tv class])];
        // Étape 4 (Point 1) : ré-imposer l'offset en haut APRÈS la présentation
        // réelle. reloadInputViews déclenche la mise en fenêtre de l'inputView
        // et son propre passage de layout (safe area / adjustedContentInset),
        // qui peut annuler le setContentOffset fait plus haut avant que la vue
        // ne soit dans la fenêtre. On le refait une fois la présentation faite.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.emoteCollectionView) return;
            [strongSelf.emoteCollectionView setContentOffset:CGPointZero animated:NO];
            [strongSelf _s7tv_activateVisiblePickerAnimations];
        });
    } else {
        [[SevenTVManager sharedManager] log:@"⚠️ TextEntryView nil — fallback fenêtre flottante"];
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

    // ── Palette ─────────────────────────────────────────────────────────
    // bgColor = fond de la grille (le plus sombre). cardColor = tout ce qui
    // doit se détacher légèrement du fond (cellules + TOUTES les pastilles
    // flottantes, qui partagent maintenant exactement le même style — plus
    // aucun bandeau opaque qui mange de la place). accent = violet Twitch.
    // Twitch utilise #0E0E10 pour le fond de la chatbox (confirmé par
    // color picker directement sur l'app Twitch) — ce n'est PAS un gris pur,
    // il y a un léger biais bleu, contrairement à ce qu'on avait supposé.
    UIColor *bgColor = [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
    UIColor *cardColor  = [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
    UIColor *sepColor   = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
    UIColor *textColor  = [UIColor whiteColor];
    UIColor *subColor   = [UIColor colorWithWhite:0.55 alpha:1.0];
    UIColor *accent     = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];    // violet Twitch

    // ── Conteneur principal ────────────────────────────────────────────────
    UIView *picker = [[UIView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    self.emotePickerView = picker;

    // ── Collection View — occupe 100% du picker ─────────────────────────────
    // Plus de bandeau opaque en haut ni en bas : c'est layout.sectionInset qui
    // réserve la place nécessaire pour que les cellules ne passent jamais
    // sous les pastilles flottantes (fiable dès la 1ère ouverture, contrairement
    // à un contentInset + contentOffset manuel qui peut être ignoré tant que
    // le 1er layout de la collection view n'a pas eu lieu).
    CGFloat topInset = kS7TVPickerFloatMargin; // marge minimale seulement — la
    // 1ère ligne démarre quasiment au ras du haut du picker, sous les
    // pastilles flottantes qui sont ajoutées PAR-DESSUS (z-order) juste après :
    // effet recherché = la grille défile VISUELLEMENT DERRIÈRE ces pastilles
    // (comme sur 7TV PC), au lieu de laisser un bandeau vide réservé qui ne
    // fait qu'espacer la grille en dessous d'elles.
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection         = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 3;
    layout.minimumLineSpacing      = 3;
    layout.sectionInset            = UIEdgeInsetsMake(topInset, 6, kS7TVPickerBottomZoneH, 6);
    layout.headerReferenceSize     = CGSizeZero;

    UICollectionView *cv = [[UICollectionView alloc]
        initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.height)
 collectionViewLayout:layout];
    cv.backgroundColor        = bgColor;
    cv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cv.dataSource             = (id<UICollectionViewDataSource>)self;
    cv.delegate               = (id<UICollectionViewDelegate>)self;
    cv.alwaysBounceVertical   = YES;
    cv.alwaysBounceHorizontal = NO;
    cv.showsHorizontalScrollIndicator = NO;
    cv.showsVerticalScrollIndicator   = YES;
    // Aucun préchargement implicite : cellFor/willDisplay restent les seules
    // portes d'entrée du pipeline image, donc une emote hors écran ne peut pas
    // être activée par anticipation par UICollectionView.
    if (@available(iOS 10.0, *)) cv.prefetchingEnabled = NO;

    [cv registerClass:[S7TVEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellID];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    // ── Capsule unique d'onglets (flottante, bas gauche) — Favoris / Channel /
    // Globales ───────────────────────────────────────────────────────────
    // Fusion de l'ancienne capsule d'onglets (Favoris/7TV) et de l'ancienne
    // capsule sous-choix (Chaîne/Globales, haut-gauche) : 3 boutons sur un
    // seul fond pilule, pastille qui glisse entre les 3.
    CGFloat tabCapsuleW = kS7TVPickerFloatSize * 3.0;
    CGFloat bottomRowY = frame.size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH
                          - kS7TVPickerFloatGap - kS7TVPickerFloatSize;
    UIView *tabCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kS7TVPickerFloatMargin, bottomRowY, tabCapsuleW, kS7TVPickerFloatSize)];
    tabCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    tabCapsule.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    tabCapsule.clipsToBounds = YES;
    tabCapsule.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.pickerTabCapsuleView = tabCapsule;
    [picker addSubview:tabCapsule];

    UIView *tabIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize)];
    tabIndicator.backgroundColor = accent;
    tabIndicator.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    [tabCapsule addSubview:tabIndicator];
    self.pickerTabIndicatorView = tabIndicator;

    NSData *_tabLogoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_tabLogoImg = [[UIImage imageWithData:_tabLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];

    [self.pickerTabButtons removeAllObjects];

    // Bouton 1 — Favoris
    UIImageSymbolConfiguration *starCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    UIButton *favBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    favBtn.frame = CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    favBtn.tag = S7TVPickerTabFavorites;
    [favBtn setImage:[UIImage systemImageNamed:@"star.fill" withConfiguration:starCfg] forState:UIControlStateNormal];
    [favBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:favBtn];
    [self.pickerTabButtons addObject:favBtn];

    // Bouton 2 — Channel (avatar de la chaîne courante, placeholder générique
    // en attendant le fetch — voir _s7tv_applyChannelAvatarImage:/
    // _s7tv_resetChannelButtonToPlaceholder, inchangés).
    UIImageSymbolConfiguration *avCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    UIButton *channelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    channelBtn.frame = CGRectMake(kS7TVPickerFloatSize, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    channelBtn.tag = S7TVPickerTabChannel;
    [channelBtn setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:avCfg]
                 forState:UIControlStateNormal];
    [channelBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:channelBtn];
    [self.pickerTabButtons addObject:channelBtn];
    self.pickerSubChoiceChannelBtn = channelBtn;

    // Bouton 3 — Globales (logo 7TV)
    NSData *_capsuleLogoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_capsuleLogoImg = [[UIImage imageWithData:_capsuleLogoData scale:3.0]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIButton *globalBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    globalBtn.frame = CGRectMake(kS7TVPickerFloatSize * 2.0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    globalBtn.tag = S7TVPickerTabGlobal;
    [globalBtn setImage:_capsuleLogoImg forState:UIControlStateNormal];
    globalBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    // Insets calculés pour que le logo occupe kS7TVPickerAvatarDiameter (24pt)
    // dans le bouton 30pt — même taille visible que l'avatar de chaîne.
    CGFloat globalBtnInset = (kS7TVPickerFloatSize - kS7TVPickerAvatarDiameter) / 2.0;
    globalBtn.imageEdgeInsets = UIEdgeInsetsMake(globalBtnInset, globalBtnInset, globalBtnInset, globalBtnInset);
    [globalBtn addTarget:self action:@selector(_pickerTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [tabCapsule addSubview:globalBtn];
    [self.pickerTabButtons addObject:globalBtn];

    [self _s7tv_updateTabButtonHighlight];

    // ── Capsule tailles/réglages (flottante, bas droite) ────────────────────
    // Même langage visuel que la capsule d'onglets ci-dessus et la capsule
    // sous-choix : un seul fond pilule partagé pour les 2 boutons (au lieu de
    // 2 pastilles séparées avec un espace entre elles), pour qu'ils restent
    // toujours visuellement collés — même taille/forme que les boutons de
    // catégories (Favoris/7TV), qui utilisent déjà ce mécanisme.
    CGFloat toolsCapsuleW = kS7TVPickerFloatSize * 2.0;
    UIView *toolsCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(frame.size.width - kS7TVPickerFloatMargin - toolsCapsuleW, bottomRowY,
                   toolsCapsuleW, kS7TVPickerFloatSize)];
    toolsCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    toolsCapsule.layer.cornerRadius = kS7TVPickerFloatSize / 2.0;
    toolsCapsule.clipsToBounds = YES;
    toolsCapsule.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    self.pickerToolsCapsuleView = toolsCapsule;
    [picker addSubview:toolsCapsule];

    // Bouton réglages — slot gauche de la capsule (côté "intérieur", vers le
    // centre). Ouvre le même écran que le bouton flottant 7TV (voir
    // -[SevenTVManager presentSettingsMenu]) ; ferme d'abord le picker (voir
    // -_pickerSettingsTapped) pour ne pas laisser les 2 superposés.
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    UIImageSymbolConfiguration *settingsCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:settingsCfg]
                 forState:UIControlStateNormal];
    settingsBtn.tintColor = subColor;
    [settingsBtn addTarget:self action:@selector(_pickerSettingsTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:settingsBtn];
    self.pickerSettingsBtn = settingsBtn;

    // Bouton tailles — slot droit de la capsule (côté "extérieur", vers le
    // bord de l'écran). Icône "taille de texte" : représente vraiment ce que
    // fait ce bouton (régler des tailles), plutôt qu'un engrenage générique.
    UIButton *gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gearBtn.frame = CGRectMake(kS7TVPickerFloatSize, 0, kS7TVPickerFloatSize, kS7TVPickerFloatSize);
    UIImageSymbolConfiguration *gearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [gearBtn setImage:[UIImage systemImageNamed:@"textformat.size" withConfiguration:gearCfg]
             forState:UIControlStateNormal];
    gearBtn.tintColor = subColor;
    [gearBtn addTarget:self action:@selector(emotePickerSizesToggleTapped)
      forControlEvents:UIControlEventTouchUpInside];
    [toolsCapsule addSubview:gearBtn];
    self.pickerSizesToggleBtn = gearBtn;

    // ── Capsule de recherche (flottante, tout en bas, pleine largeur) ──────
    CGFloat searchY = frame.size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH;
    UIView *searchCapsule = [[UIView alloc] initWithFrame:
        CGRectMake(kS7TVPickerFloatMargin, searchY, frame.size.width - kS7TVPickerFloatMargin * 2, kS7TVPickerSearchH)];
    searchCapsule.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    searchCapsule.layer.cornerRadius = kS7TVPickerSearchH / 2.0;
    searchCapsule.clipsToBounds = YES;
    searchCapsule.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.pickerSearchCapsuleView = searchCapsule;
    [picker addSubview:searchCapsule];

    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(0, 0, searchCapsule.bounds.size.width, kS7TVPickerSearchH)];
    search.placeholder     = L(@"placeholder_search_picker");
    search.font            = [UIFont systemFontOfSize:13];
    search.returnKeyType   = UIReturnKeyDone;
    search.clearButtonMode = UITextFieldViewModeNever; // remplacé par notre propre bouton croix (point 4)
    search.backgroundColor = [UIColor clearColor];
    search.textColor       = textColor;
    search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:L(@"placeholder_search_picker")
            attributes:@{NSForegroundColorAttributeName: subColor}];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Icône loupe intégrée à gauche du champ
    UIImageSymbolConfiguration *searchCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    UIImageView *searchIcon = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:searchCfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    searchIcon.tintColor = subColor;
    searchIcon.contentMode = UIViewContentModeCenter;
    UIView *searchLeftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 20)];
    searchIcon.frame = CGRectMake(12, 0, 16, 20);
    [searchLeftView addSubview:searchIcon];
    search.leftView = searchLeftView;
    search.leftViewMode = UITextFieldViewModeAlways;

    // Petite croix à droite pour vider le champ d'un tap (point 4) — visible
    // uniquement si le champ contient du texte, voir _s7tv_updateSearchClearVisibility.
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(0, 0, 28, kS7TVPickerSearchH);
    UIImageSymbolConfiguration *clearCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [clearBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:clearCfg]
              forState:UIControlStateNormal];
    clearBtn.tintColor = subColor;
    clearBtn.hidden = YES;
    [clearBtn addTarget:self action:@selector(_pickerSearchClearTapped)
       forControlEvents:UIControlEventTouchUpInside];
    self.pickerSearchClearBtn = clearBtn;
    UIView *searchRightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, kS7TVPickerSearchH)];
    clearBtn.frame = CGRectMake(2, 0, 28, kS7TVPickerSearchH);
    [searchRightView addSubview:clearBtn];
    search.rightView = searchRightView;
    search.rightViewMode = UITextFieldViewModeAlways;

    // Déléguer à self pour intercepter le focus et éviter que le picker se ferme
    search.delegate = (id<UITextFieldDelegate>)self;
    [search addTarget:self action:@selector(_emoteSearchChanged:)
     forControlEvents:UIControlEventEditingChanged];
    self.emoteSearchField = search;
    [searchCapsule addSubview:search];

    // ── Panneau des tailles ─────────────────────────────────────────────
    // Délégué à SevenTVPickerSizesPanel (composant enfant) : construit ses
    // propres lignes/sliders/previews dans `picker`, avec le style visuel
    // résolu ci-dessus. Le picker garde la main sur l'affichage/masquage et
    // le redimensionnement (voir -emotePickerSizesToggleTapped).
    [self.sizesPanel buildInView:picker
                            frame:frame
                          bgColor:bgColor
                        textColor:textColor
                         subColor:subColor
                         sepColor:sepColor
                           accent:accent
                        cardColor:cardColor];

    // Point 3 — VRAIE CAUSE du bug "pas de bouton pour fermer/revenir" :
    // sizesPanel est un UIScrollView OPAQUE plein cadre ajouté APRÈS
    // toolsCapsule ci-dessus → il la recouvre visuellement ET intercepte ses
    // taps, même avec hidden=NO. On la repasse au premier plan explicitement
    // pour qu'elle reste visible et cliquable par-dessus le panneau des
    // tailles (bringSubviewToFront sur la capsule suffit pour les 2 boutons
    // qu'elle contient).
    [picker bringSubviewToFront:toolsCapsule];

    // NOTE: pas d'addSubview ici — la vue est attachée via inputView (remplace le clavier)
}

// Pastille flottante ronde générique (fond carte translucide) — utilisée pour
// fermer et ⚙️. Les capsules (sous-choix, onglets, recherche) sont construites
// à la main car elles contiennent plusieurs éléments, mais partagent le même style.
- (UIButton *)_s7tv_makeFloatingPillWithFrame:(CGRect)frame cardColor:(UIColor *)cardColor {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = [cardColor colorWithAlphaComponent:0.92];
    btn.layer.cornerRadius = frame.size.height / 2.0;
    btn.clipsToBounds = YES;
    return btn;
}

// ── Barre d'onglets — helpers ────────────────────────────────────────────

// Met à jour la teinte/opacité de chaque icône + déplace la pastille
// violette derrière l'onglet actif, dans la capsule flottante bas-gauche à
// 3 boutons (Favoris / Channel / Globales).
- (void)_s7tv_updateTabButtonHighlight {
    UIColor *activeTint   = [UIColor whiteColor];
    UIColor *inactiveTint = [UIColor colorWithWhite:0.55 alpha:1.0];
    for (UIButton *btn in self.pickerTabButtons) {
        BOOL isActive = (btn.tag == self.pickerActiveTab);
        if (btn.tag == S7TVPickerTabGlobal || btn.tag == S7TVPickerTabChannel) {
            // Logo 7TV PNG et avatar de chaîne = images non-template (AlwaysOriginal)
            // → opacité plutôt que teinte (le placeholder SF Symbol du bouton
            // Channel avant fetch réagit aussi bien à l'opacité).
            btn.alpha = isActive ? 1.0 : 0.55;
        } else {
            btn.tintColor = isActive ? activeTint : inactiveTint;
        }
    }
    for (UIButton *btn in self.pickerTabButtons) {
        if (btn.tag == self.pickerActiveTab) {
            self.pickerTabIndicatorView.frame = btn.frame;
            break;
        }
    }
}

// Recalcule et applique les frames de toutes les zones du picker (grille /
// pastilles flottantes / panneau des tailles) — appelé à chaque ouverture,
// changement d'orientation, et changement d'onglet. Plus de dock : tout est
// flottant, ancré aux 4 coins/bords via des calculs explicites (fiable même
// quand la hauteur du picker change, ex. panneau des tailles — point 5).
- (void)_s7tv_relayoutPickerForSize:(CGSize)size {
    if (!self.emotePickerView) return;

    self.emoteCollectionView.frame = CGRectMake(0, 0, size.width, size.height);

    CGFloat bottomRowY = size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH
                          - kS7TVPickerFloatGap - kS7TVPickerFloatSize;
    CGFloat tabCapsuleW = kS7TVPickerFloatSize * 3.0;
    self.pickerTabCapsuleView.frame = CGRectMake(kS7TVPickerFloatMargin, bottomRowY, tabCapsuleW, kS7TVPickerFloatSize);
    // Dans la grille, la capsule reste en bas à droite. Dans les réglages,
    // elle rejoint la ligne des trois catégories en haut à droite. Seule sa
    // position change : son apparence reste exactement celle du picker.
    CGFloat toolsCapsuleW = kS7TVPickerFloatSize * 2.0;
    CGFloat toolsX = size.width - kS7TVPickerFloatMargin - toolsCapsuleW;
    CGFloat toolsY = self.pickerSizesPanelVisible ? 9.0 : bottomRowY;
    self.pickerToolsCapsuleView.frame = CGRectMake(toolsX, toolsY, toolsCapsuleW, kS7TVPickerFloatSize);
    [self _s7tv_updateTabButtonHighlight];

    CGFloat searchY = size.height - kS7TVPickerFloatMargin - kS7TVPickerSearchH;
    self.pickerSearchCapsuleView.frame = CGRectMake(kS7TVPickerFloatMargin, searchY,
                                                      size.width - kS7TVPickerFloatMargin * 2, kS7TVPickerSearchH);
    self.emoteSearchField.frame = CGRectMake(0, 0, self.pickerSearchCapsuleView.bounds.size.width, kS7TVPickerSearchH);

    self.sizesPanel.panelView.frame = CGRectMake(0, 0, size.width, size.height);
}

// ── Onglets — sélection ───────────────────────────────────────────────────

- (void)_pickerTabTapped:(UIButton *)sender {
    if (self.pickerActiveTab == sender.tag) return; // déjà actif
    self.pickerActiveTab = sender.tag;
    [self _s7tv_updateTabButtonHighlight];

    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// Tap sur la petite croix à droite du champ de recherche (point 4) — vide le
// champ et relance la recherche immédiatement, sans passer par l'alerte.
- (void)_pickerSearchClearTapped {
    self.emoteSearchField.text = @"";
    self.pickerSearchClearBtn.hidden = YES;
    [self _applySearchQuery:@""];
}

// Retourne l'array d'emotes correspondant à l'onglet actif.
- (NSArray<SevenTVEmote *> *)_s7tv_currentTabEmotes {
    switch (self.pickerActiveTab) {
        case S7TVPickerTabChannel:
            return self.emotePickerChannelEmotes;
        case S7TVPickerTabGlobal:
            return self.emotePickerGlobalEmotes;
        case S7TVPickerTabFavorites:
        default:
            return self.emotePickerFavoriteEmotes;
    }
}

// ── Recherche ──────────────────────────────────────────────────────────────

// ── Méthode centrale de filtrage : met à jour les 2 sections ──────────────

- (void)_updatePickerArraysForSearch:(NSString *)query {
    // Wrapper de compat : appelé partout où on ne veut PAS que l'onglet actif
    // soit ré-imposé automatiquement (ouverture du picker, tap manuel sur un
    // onglet/sous-choix, toggle favori). Seul _applySearchQuery: (déclenché
    // par une vraie frappe dans le champ de recherche) doit pouvoir changer
    // l'onglet tout seul → voir _updatePickerArraysForSearch:autoSelectTab:.
    [self _updatePickerArraysForSearch:query autoSelectTab:NO];
}

- (void)_updatePickerArraysForSearch:(NSString *)query autoSelectTab:(BOOL)autoSelectTab {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    NSMutableArray<SevenTVEmote *> *favs    = [NSMutableArray array];
    NSMutableArray<SevenTVEmote *> *channel = [NSMutableArray array];
    NSMutableArray<SevenTVEmote *> *global  = [NSMutableArray array];
    // Anti-doublon Favoris : une chaîne peut ajouter une emote globale à son
    // propre emote-set sous un nom différent (alias/renommage) — le
    // dédoublonnage channel/global en amont (par NOM) ne fusionne alors pas
    // les deux objets, qui partagent pourtant le même emoteID 7TV. Comme le
    // favori est stocké par ID, les deux passeraient isEmoteFavorited: et
    // l'emote apparaîtrait 2x dans l'onglet Favoris. On ne garde donc que la
    // première occurrence de chaque ID favori.
    NSMutableSet<NSString *> *seenFavoriteIDs = [NSMutableSet set];

    // Snapshot des dicts pour distinguer channel vs global
    __block NSDictionary *channelDict;
    dispatch_sync([SevenTVManager sharedManager].emoteQueue, ^{
        channelDict = [SevenTVManager sharedManager].channelEmotes ?: @{};
    });

    for (SevenTVEmote *e in self.emotePickerAllEmotes) {
        BOOL matches = (q.length == 0) || [e.emoteName.lowercaseString containsString:lower];
        if (!matches) continue;
        // Non-exclusif : une emote favorite reste dans son onglet 7TV normal
        // (channel/globales) avec l'étoile affichée — elle apparaît aussi
        // dans l'onglet Favoris. C'est l'onglet actif qui choisit quel array
        // afficher, pas une appartenance à une section unique comme avant.
        if ([[SevenTVManager sharedManager] isEmoteFavorited:e.emoteID]
            && e.emoteID.length > 0
            && ![seenFavoriteIDs containsObject:e.emoteID]) {
            [seenFavoriteIDs addObject:e.emoteID];
            [favs addObject:e];
        }
        if (channelDict[e.emoteName] != nil) {
            [channel addObject:e];
        } else {
            [global addObject:e];
        }
    }

    // ── Tri par pertinence pendant une recherche ────────────────────────────
    // 1. Nom exact  2. Nom qui commence par la recherche  3. Nom qui la
    // contient (le reste) — sortedArrayUsingComparator: utilise un tri
    // stable, donc à l'intérieur d'un même rang on garde l'ordre d'origine
    // (taille/alpha) comme départage.
    if (q.length > 0) {
        NSComparator relevance = ^NSComparisonResult(SevenTVEmote *a, SevenTVEmote *b) {
            NSInteger ra = [self _s7tv_relevanceRankForEmoteName:a.emoteName query:lower];
            NSInteger rb = [self _s7tv_relevanceRankForEmoteName:b.emoteName query:lower];
            if (ra < rb) return NSOrderedAscending;
            if (ra > rb) return NSOrderedDescending;
            return NSOrderedSame;
        };
        favs    = [[favs    sortedArrayUsingComparator:relevance] mutableCopy];
        channel = [[channel sortedArrayUsingComparator:relevance] mutableCopy];
        global  = [[global  sortedArrayUsingComparator:relevance] mutableCopy];
    }

    self.emotePickerFavoriteEmotes = [favs copy];
    self.emotePickerChannelEmotes  = [channel copy];
    self.emotePickerGlobalEmotes   = [global copy];
    // Maintenir emotePickerOtherEmotes pour compatibilité
    self.emotePickerOtherEmotes    = self.emotePickerChannelEmotes;

    // ── Bascule automatique Favoris → Channel → Globales pendant la recherche ──
    // On mémorise l'onglet d'avant recherche pour le restaurer dès que le
    // champ redevient vide (point 3).
    if (q.length > 0 && !self.pickerIsSearching) {
        self.pickerIsSearching = YES;
        self.pickerPreSearchTab = self.pickerActiveTab;
    } else if (q.length == 0 && self.pickerIsSearching) {
        self.pickerIsSearching = NO;
        self.pickerActiveTab = self.pickerPreSearchTab;
    }
    // ── Auto-sélection du meilleur onglet — UNIQUEMENT quand la recherche
    // vient de démarrer (1ère lettre tapée), jamais quand l'utilisateur a
    // manuellement changé d'onglet pendant qu'une recherche est déjà en
    // cours. Sans ce garde-fou, _pickerTabTapped: qui appelle cette méthode
    // juste après avoir choisi l'onglet voyait son choix immédiatement
    // écrasé ci-dessous → impossible de changer de catégorie pendant une
    // recherche (ex: rester bloqué sur Channel alors que le meilleur
    // résultat est dans Global).
    if (q.length > 0 && autoSelectTab) {
        // Le choix de l'onglet doit se baser sur la QUALITÉ du meilleur match
        // de chaque groupe (rang 0=exact, 1=commence par, 2=contient), pas
        // juste sur "y a-t-il au moins un résultat". Sans ça, une simple
        // correspondance faible dans Channel (ex: "quelqueChoseEZ", rang 2)
        // gagnait à tort contre une correspondance exacte dans Global
        // (ex: "EZ", rang 0) — d'où le blocage sur Channel avec des
        // résultats hors-sujet pendant qu'un meilleur match existait ailleurs.
        // Les 3 arrays sont déjà triés par pertinence juste au-dessus, donc
        // leur firstObject est déjà le meilleur match de chaque groupe.
        NSInteger favsRank    = favs.count    > 0 ? [self _s7tv_relevanceRankForEmoteName:favs.firstObject.emoteName    query:lower] : NSIntegerMax;
        NSInteger channelRank = channel.count > 0 ? [self _s7tv_relevanceRankForEmoteName:channel.firstObject.emoteName query:lower] : NSIntegerMax;
        NSInteger globalRank  = global.count  > 0 ? [self _s7tv_relevanceRankForEmoteName:global.firstObject.emoteName  query:lower] : NSIntegerMax;

        // Priorité Favoris > Channel > Global à qualité de match égale
        // (ex-aequo) — sinon c'est le meilleur rang qui gagne.
        if (favs.count > 0 && favsRank <= channelRank && favsRank <= globalRank) {
            self.pickerActiveTab = S7TVPickerTabFavorites;
        } else if (channel.count > 0 && channelRank <= globalRank) {
            self.pickerActiveTab = S7TVPickerTabChannel;
        } else if (global.count > 0) {
            self.pickerActiveTab = S7TVPickerTabGlobal;
        }
        // Sinon : aucun résultat nulle part, on ne change pas d'onglet (la
        // grille affichera simplement 0 résultat pour l'onglet courant).
    }

    // Array réellement affiché dans la grille = celui de l'onglet actif
    self.emotePickerEmotes = [self _s7tv_currentTabEmotes];

    // Synchroniser la capsule d'onglets avec le nouvel état (peut avoir
    // changé automatiquement ci-dessus).
    [self _s7tv_updateTabButtonHighlight];

}

// Rang de pertinence d'un nom d'emote pour une requête (déjà en minuscules,
// déjà garantie non-vide par l'appelant) : 0 = correspondance exacte,
// 1 = commence par la recherche, 2 = la contient ailleurs.
- (NSInteger)_s7tv_relevanceRankForEmoteName:(NSString *)name query:(NSString *)lowerQuery {
    NSString *lowerName = name.lowercaseString;
    if ([lowerName isEqualToString:lowerQuery]) return 0;
    if ([lowerName hasPrefix:lowerQuery]) return 1;
    return 2;
}

// ── UITextFieldDelegate — intercepte le focus du champ de recherche ────────
//
// PROBLÈME : quand emoteSearchField appelle becomeFirstResponder, UIKit
// résigne automatiquement l'ancien firstResponder (TextEntryView).
// Cela retire l'inputView du TextEntryView → le picker disparaît et
// les frappes suivantes vont directement dans la chatbox de Twitch.
//
// SOLUTION : bloquer becomeFirstResponder sur le champ intégré (retourner NO
// dans le delegate), puis afficher un UIAlertController avec un champ texte.
// Son clavier natif emprunte temporairement le first responder au TextEntryView
// Twitch ; pickerSearchAlertActive empêche de prendre ce transfert pour une
// fermeture. À la validation, on recharge la grille puis on restaure le picker.
//
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField != self.emoteSearchField) return YES;
    if (self.pickerSearchAlertActive) return NO;

    // Capturer la query courante pour pré-remplir l'alerte
    NSString *currentQuery = textField.text ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:L(@"alert_search_emote_title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *alertField) {
        alertField.placeholder   = L(@"placeholder_emote_name");
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
        actionWithTitle:L(@"action_search")
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
        NSString *query = alert.textFields.firstObject.text ?: @"";
        // Mettre à jour le texte du champ affiché pour feedback visuel
        textField.text = query;
        if (query.length == 0) {
            UIColor *subColor = [UIColor colorWithWhite:0.55 alpha:1.0];
            textField.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:L(@"placeholder_search_picker")
                    attributes:@{NSForegroundColorAttributeName: subColor}];
        }
        [self _applySearchQuery:query];
        // Reste du clignotement : même en callant _restorePickerFocus pile au
        // bon moment, il y avait ENCORE 2 animations qui s'enchaînaient l'une
        // après l'autre — la fermeture de l'alerte (+ son clavier natif qui
        // se replie), PUIS la réapparition du picker une fois celle-ci finie.
        // iOS ne permet pas de vraiment les superposer (un seul firstResponder
        // à la fois pendant une transition modale). En désactivant l'animation
        // de fermeture de l'alerte (dismiss instantané), il ne reste plus que
        // l'animation de réapparition du picker — un seul mouvement au lieu
        // de deux qui se suivent.
        [alert dismissViewControllerAnimated:NO completion:^{
            [self _restorePickerFocus];
            self.pickerSearchAlertActive = NO;
        }];
    }];

    UIAlertAction *cancelAction = [UIAlertAction
        actionWithTitle:L(@"common_cancel")
                  style:UIAlertActionStyleCancel
                handler:^(UIAlertAction *action) {
        // Même chose à l'annulation (voir searchAction ci-dessus) : dismiss
        // sans animation pour ne garder qu'une seule transition visible.
        [alert dismissViewControllerAnimated:NO completion:^{
            [self _restorePickerFocus];
            self.pickerSearchAlertActive = NO;
        }];
    }];

    [alert addAction:searchAction];
    [alert addAction:cancelAction];
    alert.preferredAction = searchAction;

    // Présenter depuis le topViewController (le picker est inputView, pas un VC).
    // Le flag doit être levé AVANT la présentation : le champ de l'alerte va
    // immédiatement faire résigner le TextEntryView de Twitch.
    UIViewController *presenter = [self topViewController];
    if (!presenter) return NO;
    self.pickerSearchAlertActive = YES;
    [presenter presentViewController:alert animated:YES completion:nil];

    // Bloquer le becomeFirstResponder → le picker reste affiché
    return NO;
}

- (void)_applySearchQuery:(NSString *)query {
    // Seul point d'entrée où l'onglet peut être choisi automatiquement
    // (nouvelle frappe = nouveaux résultats à faire découvrir).
    [self _updatePickerArraysForSearch:query autoSelectTab:YES];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
    [self _s7tv_updateSearchClearVisibility];
}

// Affiche/masque la petite croix à droite du champ de recherche selon que le
// champ contient du texte ou non (point 4).
- (void)_s7tv_updateSearchClearVisibility {
    self.pickerSearchClearBtn.hidden = (self.emoteSearchField.text.length == 0);
}

// Restaure le picker après fermeture de l'UIAlertController — appelée depuis
// le completion du dismiss (voir searchAction/cancelAction ci-dessus), donc
// exactement quand l'alerte a fini de disparaître. La fermeture de l'alerte
// déclenche parfois un resign/become du firstResponder sur le TextEntryView,
// ce qui efface son inputView et affiche le clavier natif un court instant :
// on réassigne inputView = picker et on force reloadInputViews pour reprendre
// la main immédiatement.
- (void)_restorePickerFocus {
    UITextView *tv = self.emotePickerTextEntryView;
    UIView *pickerView = self.emotePickerView;
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
    // reloadData pendant la recherche coupe volontairement les anciens
    // observateurs d'animation. Une fois l'inputView réellement remonté,
    // réactiver immédiatement les seules cellules désormais visibles.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf _s7tv_activateVisiblePickerAnimations];
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

    BOOL isFav = [[SevenTVManager sharedManager] isEmoteFavorited:emote.emoteID];
    [[SevenTVManager sharedManager] setEmote:emote.emoteID favorited:!isFav];
    if (isFav) {
        [[SevenTVManager sharedManager] log:@"💔 Favori retiré : %@", emote.emoteName];
    } else {
        [[SevenTVManager sharedManager] log:@"⭐ Favori ajouté : %@", emote.emoteName];
    }

    // Haptique
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // Rebuild les arrays et recharger
    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self _s7tv_deactivateVisiblePickerAnimations];
    [self.emoteCollectionView reloadData];
}

// ── Helper : emote à partir d'un indexPath ─────────────────────────────────
// Section unique désormais (voir _s7tv_currentTabEmotes) — plus de sections
// favoris/channel/globales empilées, l'onglet actif choisit l'array affiché.

- (SevenTVEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0) return nil;
    if ((NSUInteger)ip.item < self.emotePickerEmotes.count)
        return self.emotePickerEmotes[(NSUInteger)ip.item];
    return nil;
}

// ── Faux chat flottant (preview live du panneau ⚙️ Tailles) ────────────────
// Le panneau des tailles est le panelView de SevenTVPickerSizesPanel, qui EST
// l'inputView du clavier (voir -_buildAndShowEmotePickerForView:) : impossible
// d'y positionner un aperçu librement au milieu de l'écran. Solution : un
// conteneur séparé ajouté directement à la key window, même technique que le
// fallback "TextEntryView nil" plus haut (-toggleEmotePickerForChatInputView:)
// qui fait déjà un addSubview: direct sur keyWindow.
// Créé une seule fois ; repositionné/affiché à chaque ouverture du panneau
// (l'orientation ou la hauteur de chatInputView peuvent avoir changé).
- (UIView *)_ensureFakeChatPreviewContainer {
    if (self.pickerFakeChatPreviewView) return self.pickerFakeChatPreviewView;

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.97];
    container.layer.cornerRadius = 12;
    container.clipsToBounds = YES;
    container.hidden = YES;
    // La preview est interactive et ce conteneur opaque doit aussi absorber
    // toute touche dans ses marges : aucun tap ne traverse vers le vrai chat,
    // le lecteur ou une autre vue Twitch placée derrière.
    container.userInteractionEnabled = YES;

    SevenTVChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:chatView];

    self.pickerFakeChatPreviewView = container;
    return container;
}

// Affiche le conteneur, positionné juste au-dessus de chatInputView
// (self.emotePickerTextField), ~50% de la hauteur d'écran, pleine largeur —
// peut recouvrir le vrai chat (comportement validé). Repris à chaque appel
// pour suivre l'orientation/la position courante de chatInputView plutôt que
// figé à la première ouverture.
- (void)_showFakeChatPreviewAboveInputView {
    UIView *inputRoot = self.emotePickerTextField;
    UIWindow *keyWindow = inputRoot.window;
    if (!keyWindow) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { keyWindow = w; break; }
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    if (!keyWindow) {
        [[SevenTVManager sharedManager] log:@"⚠️ _showFakeChatPreviewAboveInputView: pas de key window"];
        return;
    }

    UIView *container = [self _ensureFakeChatPreviewContainer];
    if (container.superview != keyWindow) {
        [container removeFromSuperview];
        [keyWindow addSubview:container];
    }

    CGFloat width     = keyWindow.bounds.size.width;
    CGFloat maxHeight = keyWindow.bounds.size.height * 0.5; // plafond, jamais dépassé
    static const CGFloat kFakeChatInset = 8.0; // même valeur que CGRectInset(container.bounds, 8, 8) plus bas

    // ── Hauteur réelle du contenu ────────────────────────────────────────
    // Avant, la hauteur était fixée à 50% de l'écran quel que soit le
    // nombre de messages factices → gros vide en dessous du dernier message.
    // On fixe d'abord la largeur du chatView (nécessaire pour que sa collection
    // calcule le wrapping du texte et donc sa vraie hauteur de contenu), on
    // force le layout, puis on lit contentSize.height. SevenTVChatCustomView
    // est une UICollectionView (diffable data source) → UIScrollView.contentSize
    // reflète exactement la hauteur des 7 messages empilés.
    SevenTVChatCustomView *chatView = self.sizesPanel.fakeChatView;
    chatView.frame = CGRectMake(0, 0, width - kFakeChatInset * 2, maxHeight);
    CGFloat contentHeight = [chatView s7tvContentHeight];

    CGFloat height = (contentHeight > 0)
        ? MIN(contentHeight + kFakeChatInset * 2, maxHeight)
        : maxHeight; // fallback si contentSize indisponible (pas encore layoutée)

    // inputRoot peut être nil (picker jamais ouvert sur ce chat) — dans ce
    // cas on colle simplement en bas de l'écran plutôt que de planter/ne
    // rien afficher.
    CGFloat inputTopY = keyWindow.bounds.size.height;
    if (inputRoot) {
        CGRect inputFrameInWindow = [inputRoot convertRect:inputRoot.bounds toView:keyWindow];
        inputTopY = inputFrameInWindow.origin.y;
    }
    CGFloat y = MAX(0, inputTopY - height);

    container.frame = CGRectMake(0, y, width, height);
    self.sizesPanel.fakeChatView.frame = CGRectInset(container.bounds, kFakeChatInset, kFakeChatInset);
    container.hidden = NO;
    [keyWindow bringSubviewToFront:container];
}

- (void)_hideFakeChatPreview {
    self.pickerFakeChatPreviewView.hidden = YES;
}

// ── Slider taille des emotes ───────────────────────────────────────────────

// Table nom-de-clé → (nom affiché, min, max) — une seule source pour le menu
// de sélection, l'ouverture du slider et le label de propriété. Bornes
// choisies pour couvrir large sans avoir à les retoucher plus tard (~2x le
// défaut mesuré pour chaque élément, voir SevenTVChatAppearanceConfig.m).
- (void)emotePickerSizesToggleTapped {
    BOOL show = !self.pickerSizesPanelVisible;
    if (show) {
        [self _s7tv_deactivateVisiblePickerAnimations];
        [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
        [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
        [[SevenTVEmoteImageCache sharedCache] setDecodingSuspended:NO];
        self.pickerScrollInProgress = NO;
    }
    self.pickerSizesPanelVisible = show;
    self.sizesPanel.panelView.hidden = !show;
    self.emoteCollectionView.hidden  = show;
    self.pickerSearchCapsuleView.hidden = show;
    // Masque le conteneur ET les icônes (pas juste les icônes) : la capsule
    // vide se retrouverait sinon sous la paire tailles/réglages quand elle
    // passe à gauche dans le panneau des tailles.
    self.pickerTabCapsuleView.hidden = show;
    for (UIButton *btn in self.pickerTabButtons) btn.hidden = show;
    self.pickerSizesToggleBtn.tintColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    // L'émoticône reprend l'icône de retour historique du picker : la capsule
    // garde ainsi le même langage visuel dans les deux pages.
    UIImageSymbolConfiguration *backCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [self.pickerSizesToggleBtn setImage:
        [UIImage systemImageNamed:(show ? @"face.smiling" : @"textformat.size")
                withConfiguration:backCfg]
                                forState:UIControlStateNormal];

    // ── Point 5 : adapter la hauteur du picker au panneau où on se trouve ──
    // Le panneau des tailles n'a que 5 lignes courtes : pas besoin de garder
    // la hauteur de la grille (qui laissait un grand vide en dessous) si le
    // contenu réel est plus court. On ne dépasse jamais la hauteur "grille"
    // pour rester dans une zone confortable à l'écran.
    // Toujours ré-appeler le relayout (pas seulement si la hauteur change) :
    // c'est lui qui replace la capsule tailles/réglages du bon côté selon
    // pickerSizesPanelVisible (à droite en grille, à gauche dans le panneau
    // des tailles) — sans ça, sur un contenu de hauteur identique par
    // coïncidence, les boutons resteraient du mauvais côté.
    // Instantané (pas d'animation) : le déplacement de la capsule d'un côté à
    // l'autre doit être immédiat, pas un glissement visible.
    CGRect f = self.emotePickerView.frame;
    CGFloat targetH = show
        ? MIN(MAX(self.sizesPanel.contentHeight, 160.0), kS7TVPickerGridDefaultH)
        : kS7TVPickerGridDefaultH;
    f.size.height = targetH;
    self.emotePickerView.frame = f;
    [self _s7tv_relayoutPickerForSize:f.size];
    // Force UIKit à relire la nouvelle taille de l'inputView (sinon la zone
    // réservée au clavier peut rester figée à l'ancienne hauteur).
    [self.emotePickerTextEntryView reloadInputViews];

    if (show) {
        [self.sizesPanel loadRealPreviewAssetsIfNeeded];
        [self _showFakeChatPreviewAboveInputView];
    } else {
        [self _hideFakeChatPreview];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _s7tv_activateVisiblePickerAnimations];
        });
    }
}

// Ouvre l'écran de réglages complet depuis le picker (même écran que le
// bouton flottant 7TV) — ferme d'abord le picker (clavier custom + inputView)
// pour ne pas laisser le menu de réglages s'ouvrir par-dessus le picker
// encore affiché en arrière-plan.
- (void)_pickerSettingsTapped {
    [self _hideEmotePicker];
    [[SevenTVManager sharedManager] presentSettingsMenu];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return 1; // Section unique — l'onglet actif détermine l'array affiché (voir _s7tv_currentTabEmotes)
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.emotePickerEmotes.count;
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

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    S7TVEmotePickerCell *cell = (S7TVEmotePickerCell *)
        [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID forIndexPath:indexPath];

    // Une cellule peut être reconfigurée sans passer immédiatement par
    // prepareForReuse. On coupe donc ici l'ancienne observation, exactement
    // comme le chat custom le fait avant son willDisplayCell.
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:cell];
    [cell.animationFrameRequest cancel];
    cell.animationFrameRequest = nil;
    cell.imageLoadGeneration += 1;
    cell.animationGeneration += 1;
    cell.wantsAnimation = NO;
    cell.currentEmoteKey = nil;
    cell.emoteImageView.image = nil;
    cell.favoriteStarView.hidden = YES;

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Étoile favoris — la vue existe déjà sur la cellule (créée une fois
    // dans S7TVEmotePickerCell), on ne fait que l'afficher/masquer ici.
    // Basée sur l'appartenance réelle aux favoris (et non plus sur la
    // section) puisqu'une emote favorite reste visible dans son onglet 7TV
    // normal (channel/globales) en plus de l'onglet Favoris.
    BOOL isFavorite = [[SevenTVManager sharedManager] isEmoteFavorited:emote.emoteID];
    cell.favoriteStarView.hidden = !isFavorite;

    // Le réglage s'applique à tout le picker, pas seulement aux favoris —
    // sauf si la sous-option "Animations uniquement pour les favoris" est
    // active, auquel cas seul l'onglet Favoris anime, le reste reste statique.
    BOOL wantsAnimated = emote.isAnimated && [SevenTVManager sharedManager].showPickerAnimations &&
        (![SevenTVManager sharedManager].showPickerAnimationsFavoritesOnly || self.pickerActiveTab == S7TVPickerTabFavorites);

    S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
    NSString *key = resolved.imageURL.absoluteString;
    cell.currentEmoteKey = key;
    cell.wantsAnimation = wantsAnimated;

    // cellFor ne démarre aucun travail. Un cache hit est posé immédiatement ;
    // sinon willDisplay attend que la cellule soit stable avant de demander
    // sa miniature et, éventuellement, ses frames animées.
    cell.emoteImageView.image = [[SevenTVEmoteImageCache sharedCache]
        cachedImageForResolvedEmote:resolved];

    return cell;
}

// ── Chemin animé : frames servies par le cache, lecture pilotée par
// SevenTVEmoteAnimationEngine (même CADisplayLink centralisé que le chat
// custom, déjà throttlé à maxSimultaneousAnimations) au lieu que chaque
// cellule fasse tourner sa propre boucle d'animation UIImage indépendante.
- (BOOL)_s7tv_configureAnimatedPickerCell:(S7TVEmotePickerCell *)cell
                             resolvedEmote:(S7TVPickerResolvedEmote *)resolved
                                       key:(NSString *)key
                                generation:(NSUInteger)generation
                               allowDecode:(BOOL)allowDecode {
    SevenTVEmoteImageCache *cache   = [SevenTVEmoteImageCache sharedCache];
    SevenTVEmoteAnimationEngine *engine = [SevenTVEmoteAnimationEngine sharedEngine];

    __weak typeof(self) weakSelfForActivity = self;
    __weak S7TVEmotePickerCell *weakCellForActivity = cell;
    BOOL (^cellIsStillActive)(void) = ^BOOL{
        SevenTVEmotePickerController *strongSelf = weakSelfForActivity;
        S7TVEmotePickerCell *strongCell = weakCellForActivity;
        return strongSelf && strongCell &&
               strongCell.window != nil &&
               !strongSelf.emotePickerView.hidden &&
               !strongSelf.emoteCollectionView.hidden &&
               strongCell.wantsAnimation &&
               strongCell.animationGeneration == generation &&
               [strongCell.currentEmoteKey isEqualToString:key];
    };
    if (!cellIsStillActive()) return NO;

    __weak S7TVEmotePickerCell *weakCell = cell;
    void (^redraw)(void) = ^{
        __strong S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongCell || ![strongCell.currentEmoteKey isEqualToString:key]) return;
        UIImage *frame = [engine currentFrameForKey:key];
        if (frame) strongCell.emoteImageView.image = frame;
    };

    // Toute frame déjà enregistrée (y compris une preview courte) est affichée
    // immédiatement. Seule une boucle COMPLÈTE autorise toutefois un retour
    // anticipé : une preview ne doit plus bloquer à vie le vrai décodage.
    if ([engine hasFramesForKey:key]) {
        if (!cellIsStillActive()) return NO;
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw(); // pose la frame courante immédiatement, sans attendre le prochain tick
        if ([engine hasCompleteFramesForKey:key]) return YES;
    }

    // Frames décodées et en cache (ex: vues dans le chat) mais pas encore
    // enregistrées auprès de l'engine → enregistrement direct, toujours pas
    // de redécodage.
    S7TVEmoteAnimatedFrames *cachedFrames = [cache cachedFramesForResolvedEmote:resolved];
    if (cachedFrames) {
        if (!cellIsStillActive()) return NO;
        [engine registerFrames:cachedFrames forKey:key];
        [engine addObserver:cell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
        return YES;
    }

    // Premier passage depuis willDisplay : les cache hits ci-dessus doivent
    // démarrer immédiatement, même pendant un flick. En revanche, un nouveau
    // décodage multi-frames n'est autorisé qu'après le court délai de stabilité
    // appliqué par _s7tv_scheduleAnimationForPickerCell:atIndexPath:. Cela
    // évite de remplir la file série avec les emotes seulement traversées.
    if (!allowDecode) return NO;

    // Rien en cache : afficher au moins la frame statique déjà connue (si
    // elle existe) pendant que les frames animées se décodent en arrière-plan,
    // plutôt qu'une cellule vide.
    UIImage *staticCached = [cache cachedImageForResolvedEmote:resolved];
    if (staticCached) cell.emoteImageView.image = staticCached;

    __weak S7TVEmotePickerCell *weakCellForLoad = cell;
    void (^applyFrames)(S7TVEmoteAnimatedFrames *) = ^(S7TVEmoteAnimatedFrames *frames) {
        if (!frames.images.count) return;
        S7TVEmotePickerCell *strongCell = weakCellForLoad;
        if (!strongCell || !cellIsStillActive()) return;
        // La file de preview et la file complète sont indépendantes. Si la
        // complète a gagné la course, ignorer une preview arrivée plus tard.
        if (frames.isPreview && [engine hasCompleteFramesForKey:key]) return;
        [engine registerFrames:frames forKey:key];
        [engine addObserver:strongCell keys:[NSSet setWithObject:key] redraw:redraw];
        redraw();
    };

    cell.animationFrameRequest = [cache framesForResolvedEmote:resolved
        preview:^(S7TVEmoteAnimatedFrames *previewFrames) {
            // Boucle légère (12 frames max) : rend l'animation visible sans
            // attendre le décodage complet du WebP.
            applyFrames(previewFrames);
        }
        completion:^(S7TVEmoteAnimatedFrames * _Nullable frames) {
            S7TVEmotePickerCell *strongCell = weakCellForLoad;
            if (frames) applyFrames(frames);
            if (strongCell && cellIsStillActive()) {
                strongCell.animationFrameRequest = nil;
            }
        }];
    return YES;
}

// ── Visibilité réelle / scroll ─────────────────────────────────────────────

- (void)_s7tv_scheduleStaticImageForPickerCell:(S7TVEmotePickerCell *)cell
                                    atIndexPath:(NSIndexPath *)indexPath {
    if (self.emoteCollectionView.hidden) return;
    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.imageLoadGeneration;
    __weak typeof(self) weakSelf = self;
    __weak S7TVEmotePickerCell *weakCell = cell;

    // Un flick rapide ne doit pas remplir la file de décodage avec des
    // cellules déjà parties. Après 40 ms de stabilité, seule une cellule
    // encore visible est autorisée à demander sa première frame.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell ||
            strongSelf.emotePickerView.hidden || strongSelf.emoteCollectionView.hidden) return;
        if (strongCell.imageLoadGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        SevenTVEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote) return;
        S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;

        SevenTVEmoteImageCache *cache = [SevenTVEmoteImageCache sharedCache];
        UIImage *cached = [cache cachedImageForResolvedEmote:resolved];
        if (cached) {
            strongCell.emoteImageView.image = cached;
            return;
        }
        [cache imageForResolvedEmote:resolved completion:^(UIImage * _Nullable image) {
            S7TVEmotePickerCell *completionCell = weakCell;
            if (!image || !completionCell || !completionCell.window ||
                completionCell.imageLoadGeneration != generation ||
                ![completionCell.currentEmoteKey isEqualToString:key]) return;
            completionCell.emoteImageView.image = image;
        }];
    });
}

- (void)_s7tv_scheduleAnimationForPickerCell:(S7TVEmotePickerCell *)cell
                                  atIndexPath:(NSIndexPath *)indexPath {
    if (!cell.wantsAnimation || self.emoteCollectionView.hidden) return;
    if (cell.animationFrameRequest) return; // décodage courant déjà lié à cette cellule

    NSString *key = [cell.currentEmoteKey copy];
    if (!key.length) return;
    NSUInteger generation = ++cell.animationGeneration;
    __weak typeof(self) weakSelf = self;
    __weak S7TVEmotePickerCell *weakCell = cell;

    SevenTVEmote *initialEmote = [self _emoteForIndexPath:indexPath];
    if (!initialEmote || !initialEmote.isAnimated) return;
    S7TVPickerResolvedEmote *initialResolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:initialEmote];
    if (![initialResolved.imageURL.absoluteString isEqualToString:key]) return;

    // Un cache hit doit s'animer tout de suite. Cette première passe ne peut
    // jamais lancer de décodage lourd : elle ne fait que brancher les frames
    // déjà présentes dans le moteur ou le cache.
    BOOL attachedFromCache = [self _s7tv_configureAnimatedPickerCell:cell
                                                        resolvedEmote:initialResolved
                                                                  key:key
                                                           generation:generation
                                                          allowDecode:NO];
    if (attachedFromCache) return;

    // Les requêtes sont désormais annulables dans didEndDisplayingCell : plus
    // besoin d'attendre 80/120 ms pour filtrer un flick. Toute cellule visible
    // demande sa preview animée dès le prochain passage du run loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        S7TVEmotePickerCell *strongCell = weakCell;
        if (!strongSelf || !strongCell) return;
        if (strongCell.animationGeneration != generation ||
            ![strongCell.currentEmoteKey isEqualToString:key] ||
            [strongSelf.emoteCollectionView cellForItemAtIndexPath:indexPath] != strongCell) return;

        SevenTVEmote *emote = [strongSelf _emoteForIndexPath:indexPath];
        if (!emote || !emote.isAnimated) return;
        S7TVPickerResolvedEmote *resolved = [[S7TVPickerResolvedEmote alloc] initWithEmote:emote];
        if (![resolved.imageURL.absoluteString isEqualToString:key]) return;
        [strongSelf _s7tv_configureAnimatedPickerCell:strongCell
                                        resolvedEmote:resolved
                                                  key:key
                                           generation:generation
                                          allowDecode:YES];
    });
}

- (void)_s7tv_deactivateVisiblePickerAnimations {
    for (S7TVEmotePickerCell *cell in self.emoteCollectionView.visibleCells) {
        [cell.animationFrameRequest cancel];
        cell.animationFrameRequest = nil;
        cell.imageLoadGeneration += 1;
        cell.animationGeneration += 1;
        [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:cell];
    }
}

- (void)_s7tv_activateVisiblePickerAnimations {
    if (self.pickerScrollInProgress || self.emoteCollectionView.hidden || self.emotePickerView.hidden) return;
    for (NSIndexPath *indexPath in self.emoteCollectionView.indexPathsForVisibleItems) {
        S7TVEmotePickerCell *cell = (S7TVEmotePickerCell *)
            [self.emoteCollectionView cellForItemAtIndexPath:indexPath];
        if (cell) {
            [self _s7tv_scheduleStaticImageForPickerCell:cell atIndexPath:indexPath];
            [self _s7tv_scheduleAnimationForPickerCell:cell atIndexPath:indexPath];
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView
        willDisplayCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    S7TVEmotePickerCell *pickerCell = (S7TVEmotePickerCell *)cell;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
    [self _s7tv_scheduleStaticImageForPickerCell:pickerCell atIndexPath:indexPath];
    [self _s7tv_scheduleAnimationForPickerCell:pickerCell atIndexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView
 didEndDisplayingCell:(UICollectionViewCell *)cell
  forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView != self.emoteCollectionView) return;
    S7TVEmotePickerCell *pickerCell = (S7TVEmotePickerCell *)cell;
    [pickerCell.animationFrameRequest cancel];
    pickerCell.animationFrameRequest = nil;
    pickerCell.imageLoadGeneration += 1;
    pickerCell.animationGeneration += 1;
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:pickerCell];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = YES;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:YES];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:YES];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.emoteCollectionView || decelerate) return;
    self.pickerScrollInProgress = NO;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [self _s7tv_activateVisiblePickerAnimations];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.emoteCollectionView) return;
    self.pickerScrollInProgress = NO;
    [[SevenTVEmoteAnimationEngine sharedEngine] setScrollingPerformanceMode:NO];
    [[SevenTVEmoteImageCache sharedCache] setScrollingPerformanceMode:NO];
    [self _s7tv_activateVisiblePickerAnimations];
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // ── Étape 1: trouver la ChatInputView ────────────────────────────────────
    // On cherche d'abord dans la référence stockée, puis dans toute la fenêtre.
    UIView *inputRoot = self.emotePickerTextField;

    if (!inputRoot) {
        [[SevenTVManager sharedManager] log:@"⚠️ didSelect: emotePickerTextField nil → BFS fenêtre"];
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

    [[SevenTVManager sharedManager] log:@"🔍 didSelect — textView:%@ textField:%@ keyInput:%@",
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
            [[SevenTVManager sharedManager] log:@"✅ paste: emote → «%@»", emote.emoteName];
        } else {
            // Ultime fallback
            [textView insertText:toAppend];
            inserted = YES;
            [[SevenTVManager sharedManager] log:@"⚠️ paste: non dispo → insertText: fallback"];
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
        [[SevenTVManager sharedManager] log:@"✅ insertText: UITextField → «%@»", toAppend];
        inserted = YES;
    } else if (keyInput) {
        [(UIView *)keyInput becomeFirstResponder];
        [(id<UIKeyInput>)keyInput insertText:toAppend];
        [[SevenTVManager sharedManager] log:@"✅ insertText: UIKeyInput → «%@»", toAppend];
        inserted = YES;
    }

    if (!inserted) {
        [[SevenTVManager sharedManager] log:@"❌ didSelect: aucun champ texte trouvé — emote=%@", emote.emoteName];
    }

        // Feedback haptique léger
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
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
@end
