/*
 * SevenTVChatTokenizer.m
 *
 * Voir SevenTVChatTokenizer.h pour le contexte (Phase 2).
 */

#import "SevenTVChatTokenizer.h"

@implementation SevenTVChatTokenizer

// Parse "emoteID1:start-end,start-end/emoteID2:start-end..." en plages
// triées. Twitch exprime les bornes de fin de manière inclusive. Les entrées
// réseau malformées sont ignorées pour que la tokenisation ne puisse jamais
// provoquer une sortie de plage dans NSString.
+ (NSArray<NSArray *> *)s7tv_twitchEmoteRangesFromTag:(NSString *)tagValue {
    NSMutableArray<NSArray *> *ranges = [NSMutableArray array];
    if (!tagValue.length) return ranges;

    for (NSString *emoteBlock in [tagValue componentsSeparatedByString:@"/"]) {
        NSRange colonRange = [emoteBlock rangeOfString:@":"];
        if (colonRange.location == NSNotFound) continue;
        NSString *emoteID = [emoteBlock substringToIndex:colonRange.location];
        NSString *positions = [emoteBlock substringFromIndex:colonRange.location + 1];
        if (!emoteID.length) continue;

        for (NSString *position in [positions componentsSeparatedByString:@","]) {
            NSRange dashRange = [position rangeOfString:@"-"];
            if (dashRange.location == NSNotFound) continue;
            NSInteger start = [[position substringToIndex:dashRange.location] integerValue];
            NSInteger end = [[position substringFromIndex:dashRange.location + 1] integerValue];
            if (start < 0 || end < start) continue;
            [ranges addObject:@[emoteID, @(start), @(end)]];
        }
    }

    [ranges sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        return [(NSNumber *)left[1] compare:(NSNumber *)right[1]];
    }];
    return ranges;
}

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

+ (NSArray<S7TVChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(NSString * _Nullable)emotesTag
                                providers:(NSArray<id<S7TVEmoteProvider>> *)providers {
    NSArray<NSArray *> *ranges = [self s7tv_twitchEmoteRangesFromTag:emotesTag ?: @""];
    if (ranges.count == 0) return [self tokenizeText:text providers:providers];

    NSMutableArray<S7TVChatToken *> *tokens = [NSMutableArray array];
    NSInteger cursor = 0;

    for (NSArray *range in ranges) {
        NSString *emoteID = range[0];
        NSInteger start = [(NSNumber *)range[1] integerValue];
        NSInteger end = [(NSNumber *)range[2] integerValue];

        if (start < cursor || start >= (NSInteger)text.length ||
            end >= (NSInteger)text.length) {
            continue;
        }

        if (start > cursor) {
            NSString *span = [text substringWithRange:NSMakeRange(cursor, start - cursor)];
            [tokens addObjectsFromArray:[self tokenizeText:span providers:providers]];
        }

        NSString *emoteText = [text substringWithRange:NSMakeRange(start, end - start + 1)];
        id<S7TVResolvedEmote> resolved =
            [S7TVTwitchNativeEmoteFactory resolvedEmoteForTwitchEmoteID:emoteID];
        if (resolved) {
            S7TVChatToken *token = [S7TVChatToken emoteToken:emoteText
                                                     provider:S7TVChatTokenTypeEmoteTwitch
                                                      emoteID:emoteID];
            token.resolvedEmote = resolved;
            [tokens addObject:token];
        } else {
            [tokens addObject:[S7TVChatToken textToken:emoteText]];
        }
        cursor = end + 1;
    }

    if (cursor < (NSInteger)text.length) {
        NSString *span = [text substringFromIndex:cursor];
        [tokens addObjectsFromArray:[self tokenizeText:span providers:providers]];
    }
    return tokens;
}

@end
