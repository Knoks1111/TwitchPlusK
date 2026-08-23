/*
 * 7tv-chat-appearance-config.h
 *
 * Config centralisée du rendu du chat custom (Phase 1b du plan
 * chat-twitch-custom). Injectée dans le renderer — aucune constante de
 * taille ne doit être écrite en dur ailleurs dans le code de layout
 * (exigence transverse #1).
 *
 * IMPORTANT — état des valeurs par défaut :
 * emote7TVSize, badgeSize, usernameFontSize et messageFontSize ont été
 * mesurées (screenshot device natif 3x retina + dump de cellule native
 * in-app) — voir le détail dans 7tv-chat-appearance-config.m. emoteTwitchSize,
 * lineSpacing et usernameMessageSpacing restent des estimations "TODO mesure
 * réelle", pas encore confirmées.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Postée sur le main thread à chaque changement de valeur (via un setter
// custom ou après resetKeyToDefault:/resetAllToDefaults). Le chat custom en
// live (SevenTVChatCustomView) observe cette notification pour se
// redessiner immédiatement — utile pour la preview live du futur écran de
// réglages (Phase 6).
extern NSString *const S7TVChatAppearanceConfigDidChangeNotification;

typedef NS_ENUM(NSInteger, S7TVDeletedMessageStyle) {
    S7TVDeletedMessageStyleDimmed = 0,
    S7TVDeletedMessageStyleStrikethrough,
    S7TVDeletedMessageStyleDimmedAndStrikethrough,
};

typedef NS_ENUM(NSInteger, S7TVDeletedMessageRevealMode) {
    S7TVDeletedMessageRevealModeNever = 0,       // reste replié, tap désactivé
    S7TVDeletedMessageRevealModeOnTap,           // comportement actuel
    S7TVDeletedMessageRevealModeAlways,          // contenu affiché directement
};

@interface SevenTVChatAppearanceConfig : NSObject

+ (instancetype)sharedConfig;

// --- Tailles (points, pas pixels) — chacune indépendante, pas de facteur
// d'échelle global unique (exigence transverse #1). ---

// Mesurée (screenshot 3x retina) — voir .m.
@property (nonatomic, assign) CGFloat emote7TVSize;        // hauteur cible emote 7TV
// TODO mesure réelle — pas d'emote Twitch native isolée dans le screenshot dispo.
@property (nonatomic, assign) CGFloat emoteTwitchSize;     // hauteur cible emote Twitch native
// Mesurée (screenshot 3x retina) — voir .m.
@property (nonatomic, assign) CGFloat badgeSize;           // hauteur cible badge (sub/mod/VIP/custom)
// Mesurée (screenshot 3x retina) — voir .m.
@property (nonatomic, assign) CGFloat usernameFontSize;    // taille texte pseudo
// Mesurée (screenshot 3x retina) — voir .m.
@property (nonatomic, assign) CGFloat messageFontSize;     // taille texte message

// Espacements — ajoutés dès 1b comme prévu par le plan (§1, "à étendre
// pendant la Phase 1"). TODO mesure réelle également.
@property (nonatomic, assign) CGFloat lineSpacing;             // entre deux messages
@property (nonatomic, assign) CGFloat usernameMessageSpacing;  // entre pseudo et texte du message

// Décalage vertical des emotes (7TV + Twitch natives) dans la ligne de
// message — fine-tune du bounds des attachments. Négatif = emote plus
// haute, positif = plus basse. N'affecte PAS les badges.
// Valeur réelle appliquée directement aux bounds du NSTextAttachment, sans
// correction cachée. Défaut -6, identique à la valeur affichée dans le picker.
@property (nonatomic, assign) CGFloat emoteVerticalOffset;

// --- Résolution d'image emotes 7TV (1x/2x/3x/4x — voir Phase 2) ---
// Défaut technique x2, pas une mesure Twitch (n'a pas d'équivalent natif à
// mesurer, c'est un choix de compromis netteté/mémoire — voir Phase 2).
@property (nonatomic, assign) NSInteger emote7TVResolution;

// --- Fonds colorés des messages système (sub/resub/prime/gift) ---
// Toggle unique : la barre d'accent (gauche) et l'icône (couronne/étoile/
// cadeau) restent TOUJOURS affichées et colorées, quel que soit l'état de
// ce toggle — seul le fond teinté (contentView.backgroundColor à 12%
// d'opacité) est concerné. Défaut YES = comportement historique.
@property (nonatomic, assign) BOOL systemMessageBackgroundsEnabled;

// Une couleur configurable par catégorie. Défauts = anciennes couleurs en
// dur de 7tv-chat-custom-view.m (vert/violet/rose).
@property (nonatomic, strong) UIColor *subResubAccentColor;  // sub/resub non-Prime
@property (nonatomic, strong) UIColor *primeAccentColor;     // sub/resub Prime
@property (nonatomic, strong) UIColor *giftAccentColor;      // gift communautaire

// --- Highlight "vous êtes mentionné" ---
// Même mécanique visuelle que les fonds système ci-dessus (barre d'accent +
// fond teinté à 12%, voir 7tv-chat-custom-view.m,
// s7tv_configureSystemAccentWithColor:iconName:backgroundEnabled:),
// appliquée quand S7TVChatMessage.mentionsCurrentViewer == YES (viewer
// connecté cité par quelqu'un d'autre — @pseudo ou pseudo nu). Toggle
// unique combiné à la couleur (pas de fond neutre de repli comme pour
// systemMessageBackgroundsEnabled) : off = aucun effet visuel du tout,
// message rendu comme un message normal.
@property (nonatomic, assign) BOOL selfMentionHighlightEnabled;
@property (nonatomic, strong) UIColor *selfMentionHighlightColor;

// --- Badge FIRST MESSAGE ---
// Réutilise exactement le même composant visuel que le highlight de mention
// (deux barres, fond teinté, petit libellé en haut à droite), avec son toggle
// et sa couleur indépendants. Le modèle conserve toujours first-msg=1.
@property (nonatomic, assign) BOOL showFirstMessageBadge;
@property (nonatomic, strong) UIColor *firstMessageHighlightColor;

// --- Messages supprimés / modération ---
// Affiche la sanction IRC dans le placeholder replié (timeout avec durée
// humaine, ou ban permanent). Le corps révélé peut être atténué, barré
// ou les deux sans toucher au pseudo ni aux badges ; son opacité est
// réglable de 0.25 à 1.0 pour les styles qui utilisent l'atténuation.
@property (nonatomic, assign) BOOL showModerationDetails;
@property (nonatomic, assign) S7TVDeletedMessageRevealMode deletedMessageRevealMode;
@property (nonatomic, assign) S7TVDeletedMessageStyle deletedMessageStyle;
@property (nonatomic, assign) CGFloat deletedMessageTextOpacity;

// --- Persistance ---
// Recharge à chaud depuis NSUserDefaults (ex: après un changement dans un
// futur écran de réglages custom — Phase 6). Les valeurs non trouvées en
// UserDefaults gardent leur défaut en mémoire (pas de reset silencieux).
- (void)reloadFromDefaults;
- (void)save;

// Réinitialise UNE valeur donnée à son défaut (bouton "réinitialiser aux
// valeurs Twitch" par élément — prévu explicitement en Phase 6, mais le
// point d'accroche est posé dès maintenant pour ne pas avoir à retoucher
// cette classe plus tard).
- (void)resetKeyToDefault:(NSString *)key;
- (void)resetAllToDefaults;

// Écriture d'une valeur de taille par sa clé (KVC) — sauvegarde et notifie
// automatiquement (voir S7TVChatAppearanceConfigDidChangeNotification). Point
// d'entrée unique utilisé par les sliders de réglages (Phase 6) plutôt que
// d'exposer un setter dédié par propriété.
- (void)setValue:(CGFloat)value forSizeKey:(NSString *)key;

// Valeur par défaut (mesurée ou estimée) pour une clé donnée — utilisé par
// l'UI de réglages (Phase 6) pour afficher "valeur par défaut Twitch: Xpt"
// à côté du contrôle, sans dupliquer les constantes ailleurs.
- (CGFloat)defaultValueForKey:(NSString *)key;

// Équivalents couleur de setValue:forSizeKey:/defaultValueForKey: — mêmes
// garanties (sauvegarde + notification), pour subResubAccentColor/
// primeAccentColor/giftAccentColor.
- (void)setColor:(UIColor *)color forColorKey:(NSString *)key;
- (nullable UIColor *)defaultColorForColorKey:(NSString *)key;
- (void)resetColorKeyToDefault:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
