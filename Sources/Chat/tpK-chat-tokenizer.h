/*
 * tpK-chat-tokenizer.h
 *
 * Découpe le texte brut d'un message en tokens texte/emote/mention (Phase 2
 * du plan chat-twitch-custom), en s'appuyant sur la liste de fournisseurs
 * fournie (architecture générique — voir tpK-emote-provider.h).
 */

#import <Foundation/Foundation.h>
#import "Chat/tpK-chat-message.h"
#import "Emote/tpK-emote-provider.h"

NS_ASSUME_NONNULL_BEGIN

@interface TPKChatTokenizer : NSObject

// providers : essayés dans l'ordre pour chaque mot ; le premier qui résout
// le nom gagne. Découpage par espace simple — les espaces multiples
// consécutifs sont préservés en tokens texte vides pour ne pas altérer le
// rendu (exigence Phase 1c : ne jamais perdre de contenu du message original).
+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                                  providers:(NSArray<id<TPKEmoteProvider>> *)providers;

// Variante utilisée pour les messages Twitch : le tag IRC `emotes=` fournit
// l'identifiant et les positions exactes des emotes natives. Les portions de
// texte restantes suivent le même pipeline générique que ci-dessus, afin de
// continuer à résoudre les emotes 7TV et les mentions sans dupliquer cette
// logique dans le hook réseau.
+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(nullable NSString *)emotesTag
                                providers:(NSArray<id<TPKEmoteProvider>> *)providers;

// Variante complète des messages Twitch : `gifs=` est une liste de plages
// `start-end|gifID|gifURL` fournie directement par Twitch. Les GIFs sont
// insérés à leur position exacte et le texte couvert reste dans le token pour
// servir de fallback si l'image ne peut pas être chargée.
+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(nullable NSString *)emotesTag
                              twitchGIFsTag:(nullable NSString *)gifsTag
                                providers:(NSArray<id<TPKEmoteProvider>> *)providers;

@end

NS_ASSUME_NONNULL_END
