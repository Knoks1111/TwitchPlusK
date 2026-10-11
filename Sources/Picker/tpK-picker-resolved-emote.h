/*
 * tpK-picker-resolved-emote.h
 *
 * Adaptateur léger : fait correspondre une TPKEmote (modèle du picker)
 * au protocole TPKResolvedEmote attendu par TPKEmoteImageCache /
 * TPKEmoteAnimationEngine (Phase 2, chat custom). Permet au picker de
 * PARTAGER ces deux caches avec le chat custom au lieu de dupliquer son
 * propre pipeline de décodage (une emote vue dans le chat est déjà décodée
 * pour le picker, et inversement). Ne modifie pas TPKEmote elle-même
 * (modèle utilisé ailleurs dans le code) : reste un wrapper local au picker.
 *
 * Extrait de tpK-core-manager.m (nettoyage picker).
 */

#import <Foundation/Foundation.h>
#import "Core/tpK-core-manager.h"
#import "Emote/tpK-emote-image-cache.h"
#import "Emote/tpK-emote-catalog.h"

// Pont de compatibilité pour la collection view historique : le picker garde
// un objet TPKEmote, mais le descriptor conserve provider, set, alias et
// URLs propres au CDN sélectionné.
@interface TPKPickerCatalogEmote : TPKEmote
@property (nonatomic, strong, readonly) TPKEmoteDescriptor *descriptor;
- (instancetype)initWithDescriptor:(TPKEmoteDescriptor *)descriptor;
@end

@interface TPKPickerResolvedEmote : NSObject <TPKResolvedEmote>
- (instancetype)initWithEmote:(TPKEmote *)emote;
@end
