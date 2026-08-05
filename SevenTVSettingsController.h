/*
 * SevenTVSettingsController.h
 * Page d'accueil des paramètres 7TV.
 * Chaque section ouvre une nouvelle page (push) dans la navigation.
 */

#import <UIKit/UIKit.h>

// ─── Page principale ──────────────────────────────────────────────────────────
@interface SevenTVSettingsController : UITableViewController

// YES quand le VC est présenté en modal (via le bouton flottant 7TV).
// NO quand il est push depuis les paramètres Twitch natifs.
// Contrôle l'affichage du bouton "Fermer" dans la nav bar.
@property (nonatomic, assign) BOOL openedAsModal;

@end

// ─── Sous-pages 7TV (architecture v3 — 4 catégories larges et évolutives) ─────
@interface SevenTVAppearancePageController : UITableViewController @end  // Apparence
@interface SevenTVContentPageController    : UITableViewController @end  // Contenu
@interface SevenTVAdblockPageController    : UIViewController      @end  // Adblock (vide pour l'instant)
@interface SevenTVAdvancedPageController   : UITableViewController @end  // Avancé
@interface SevenTVFavoritesListController  : UITableViewController @end
