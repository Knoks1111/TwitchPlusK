/*
 * tpK-picker-resolved-emote.h
 *
 * Adaptateur du catalogue pour la collection du picker.
 *
 * Extrait de tpK-core-manager.m (nettoyage picker).
 */

#import <Foundation/Foundation.h>
#import "Core/tpK-core-manager.h"
#import "Emote/tpK-emote-catalog.h"

// Conserve les métadonnées du catalogue dans l'interface TPKEmote historique.
@interface TPKPickerCatalogEmote : TPKEmote
@property (nonatomic, strong, readonly) TPKEmoteDescriptor *descriptor;
- (instancetype)initWithDescriptor:(TPKEmoteDescriptor *)descriptor;
@end

NSURL *TPKPickerImageURLForEmote(TPKEmote *emote);
