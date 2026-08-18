/*
 * SevenTVChatTokenizer.m
 *
 * Voir SevenTVChatTokenizer.h pour le contexte (Phase 2).
 */

#import "SevenTVChatTokenizer.h"

@implementation SevenTVChatTokenizer

+ (NSArray<S7TVChatToken *> *)tokenizeText:(NSString *)text
                                  providers:(NSArray<id<S7TVEmoteProvider>> *)providers {
    NSMutableArray<S7TVChatToken *> *tokens = [NSMutableArray array];
    if (!text.length) return tokens;

    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];

    for (NSUInteger i = 0; i < words.count; i++) {
        // Réinsère le séparateur d'espace entre chaque mot (perdu par
        // componentsSeparatedByString:) — sinon "KEKW KEKW" redeviendrait
        // "KEKWKEKW" à l'affichage.
        if (i > 0) {
            [tokens addObject:[S7TVChatToken textToken:@" "]];
        }

        NSString *word = words[i];
        if (word.length == 0) continue; // espaces multiples consécutifs

        // Mention : détection simple par préfixe. La mise en forme visuelle
        // distincte (highlight du message si on est mentionné) arrive en
        // Phase 6 — ici on se contente d'identifier le token et de résoudre
        // sa couleur (comportement 7TV PC : couleur du pseudo mentionné,
        // si on l'a déjà vue passer dans le chat).
        if ([word hasPrefix:@"@"] && word.length > 1) {
            NSString *username = [word substringFromIndex:1];
            UIColor *color = [[SevenTVChatUserColorRegistry sharedRegistry]
                colorForUsername:username];
            [tokens addObject:[S7TVChatToken mentionToken:word color:color]];
            continue;
        }

        BOOL resolved = NO;
        for (id<S7TVEmoteProvider> provider in providers) {
            id<S7TVResolvedEmote> emote = [provider resolveEmoteNamed:word];
            if (!emote) continue;

            S7TVChatToken *token = [S7TVChatToken emoteToken:word
                                                     provider:(S7TVChatTokenType)provider.tokenType
                                                      emoteID:emote.emoteID];
            token.resolvedEmote = emote;
            [tokens addObject:token];
            resolved = YES;
            break;
        }

        if (!resolved) {
            // Pseudo cité sans @ (comportement 7TV PC : un pseudo connu
            // écrit tel quel dans le message est coloré comme une mention,
            // pas seulement quand il est préfixé par @). On ne teste ce cas
            // qu'après les emotes pour ne jamais voler la priorité à une
            // emote dont le nom coïnciderait avec un pseudo.
            UIColor *color = [[SevenTVChatUserColorRegistry sharedRegistry]
                colorForUsername:word];
            if (color) {
                [tokens addObject:[S7TVChatToken mentionToken:word color:color]];
            } else {
                [tokens addObject:[S7TVChatToken textToken:word]];
            }
        }
    }

    return tokens;
}

@end
