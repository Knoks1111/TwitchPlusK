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
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import <Foundation/Foundation.h>
#import "SevenTVManager.h"
#import "SevenTVEmoteImageCache.h"

@interface S7TVPickerResolvedEmote : NSObject <S7TVResolvedEmote>
- (instancetype)initWithEmote:(SevenTVEmote *)emote;
@end
