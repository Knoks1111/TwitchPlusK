/*
 * 7tv-picker-resolved-emote.h
 *
 * Adaptateur léger : fait correspondre une SevenTVEmote (modèle du picker)
 * au protocole S7TVResolvedEmote attendu par SevenTVEmoteImageCache /
 * SevenTVEmoteAnimationEngine (Phase 2, chat custom). Permet au picker de
 * PARTAGER ces deux caches avec le chat custom au lieu de dupliquer son
 * propre pipeline de décodage (une emote vue dans le chat est déjà décodée
 * pour le picker, et inversement). Ne modifie pas SevenTVEmote elle-même
 * (modèle utilisé ailleurs dans le code) : reste un wrapper local au picker.
 *
 * Extrait de 7tv-core-manager.m (nettoyage picker).
 */

#import <Foundation/Foundation.h>
#import "Core/7tv-core-manager.h"
#import "Emote/7tv-emote-image-cache.h"
#import "Emote/7tv-emote-catalog.h"

// Pont de compatibilité pour la collection view historique : le picker garde
// un objet SevenTVEmote, mais le descriptor conserve provider, set, alias et
// URLs propres au CDN sélectionné.
@interface S7TVPickerCatalogEmote : SevenTVEmote
@property (nonatomic, strong, readonly) S7TVEmoteDescriptor *descriptor;
- (instancetype)initWithDescriptor:(S7TVEmoteDescriptor *)descriptor;
@end

@interface S7TVPickerResolvedEmote : NSObject <S7TVResolvedEmote>
- (instancetype)initWithEmote:(SevenTVEmote *)emote;
@end
