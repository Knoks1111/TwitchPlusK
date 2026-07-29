/*
 * SevenTVChatAppearanceConfig.h
 *
 * Config centralisée du rendu du chat custom (Phase 1b du plan
 * chat-twitch-custom). Injectée dans le renderer — aucune constante de
 * taille ne doit être écrite en dur ailleurs dans le code de layout
 * (exigence transverse #1).
 *
 * IMPORTANT — valeurs par défaut non encore mesurées :
 * L'exigence transverse #1 du plan demande de mesurer les tailles RÉELLES
 * rendues par Twitch.ChatTranscriptView avant d'écrire le moindre défaut.
 * Cette mesure n'a pas encore été faite (nécessite d'inspecter le rendu
 * natif en marche — candidat naturel : étendre le hook de diagnostic
 * didMoveToWindow de TweakSevenTV.m pour dumper les tailles de police/frame
 * des UILabel/UIImageView réels d'une cellule native). Toutes les valeurs
 * ci-dessous sont donc marquées "TODO mesure réelle" et sont des estimations
 * raisonnables temporaires, PAS des défauts Twitch confirmés — à corriger
 * dès que la mesure sera faite, avant de considérer la Phase 1b terminée.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface SevenTVChatAppearanceConfig : NSObject

+ (instancetype)sharedConfig;

// --- Tailles (points, pas pixels) — chacune indépendante, pas de facteur
// d'échelle global unique (exigence transverse #1). ---

// TODO mesure réelle — estimation temporaire.
@property (nonatomic, assign) CGFloat emote7TVSize;        // hauteur cible emote 7TV
// TODO mesure réelle — estimation temporaire.
@property (nonatomic, assign) CGFloat emoteTwitchSize;     // hauteur cible emote Twitch native
// TODO mesure réelle — estimation temporaire.
@property (nonatomic, assign) CGFloat badgeSize;           // hauteur cible badge (sub/mod/VIP/custom)
// TODO mesure réelle — estimation temporaire.
@property (nonatomic, assign) CGFloat usernameFontSize;    // taille texte pseudo
// TODO mesure réelle — estimation temporaire.
@property (nonatomic, assign) CGFloat messageFontSize;     // taille texte message

// Espacements — ajoutés dès 1b comme prévu par le plan (§1, "à étendre
// pendant la Phase 1"). TODO mesure réelle également.
@property (nonatomic, assign) CGFloat lineSpacing;             // entre deux messages
@property (nonatomic, assign) CGFloat usernameMessageSpacing;  // entre pseudo et texte du message

// --- Résolution d'image emotes 7TV (1x/2x/3x/4x — voir Phase 2) ---
// Défaut technique x2, pas une mesure Twitch (n'a pas d'équivalent natif à
// mesurer, c'est un choix de compromis netteté/mémoire — voir Phase 2).
@property (nonatomic, assign) NSInteger emote7TVResolution;

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

@end

NS_ASSUME_NONNULL_END
