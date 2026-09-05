/*
 * 7tv-chat-tokenizer.h
 *
 * Découpe le texte brut d'un message en tokens texte/emote/mention (Phase 2
 * du plan chat-twitch-custom), en s'appuyant sur la liste de fournisseurs
 * fournie (architecture générique — voir 7tv-emote-provider.h).
 */

#import <Foundation/Foundation.h>
#import "Chat/7tv-chat-message.h"
#import "Emote/7tv-emote-provider.h"

NS_ASSUME_NONNULL_BEGIN

@interface SevenTVChatTokenizer : NSObject

// providers : essayés dans l'ordre pour chaque mot ; le premier qui résout
// le nom gagne. Découpage par espace simple — les espaces multiples
// consécutifs sont préservés en tokens texte vides pour ne pas altérer le
// rendu (exigence Phase 1c : ne jamais perdre de contenu du message original).
+ (NSArray<S7TVChatToken *> *)tokenizeText:(NSString *)text
                                  providers:(NSArray<id<S7TVEmoteProvider>> *)providers;

// Variante utilisée pour les messages Twitch : le tag IRC `emotes=` fournit
// l'identifiant et les positions exactes des emotes natives. Les portions de
// texte restantes suivent le même pipeline générique que ci-dessus, afin de
// continuer à résoudre les emotes 7TV et les mentions sans dupliquer cette
// logique dans le hook réseau.
+ (NSArray<S7TVChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(nullable NSString *)emotesTag
                                providers:(NSArray<id<S7TVEmoteProvider>> *)providers;

// Variante complète des messages Twitch : `gifs=` est une liste de plages
// `start-end|gifID|gifURL` fournie directement par Twitch. Les GIFs sont
// insérés à leur position exacte et le texte couvert reste dans le token pour
// servir de fallback si l'image ne peut pas être chargée.
+ (NSArray<S7TVChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(nullable NSString *)emotesTag
                              twitchGIFsTag:(nullable NSString *)gifsTag
                                providers:(NSArray<id<S7TVEmoteProvider>> *)providers;

@end

NS_ASSUME_NONNULL_END
