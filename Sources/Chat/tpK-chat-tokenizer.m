/*
 * tpK-chat-tokenizer.m
 *
 * Voir tpK-chat-tokenizer.h pour le contexte (Phase 2).
 */

#import "Chat/tpK-chat-tokenizer.h"
#import "Emote/tpK-provider-settings.h"

static BOOL tpk_tokenIsEmote(TPKChatToken *token) {
    return token.type == TPKChatTokenTypeEmote7TV ||
           token.type == TPKChatTokenTypeEmoteTwitch;
}

static BOOL tpk_tokenIsWhitespace(TPKChatToken *token) {
    if (token.type != TPKChatTokenTypeText || !token.text.length) return NO;
    return [token.text rangeOfCharacterFromSet:
        [[NSCharacterSet whitespaceAndNewlineCharacterSet]
            invertedSet]].location == NSNotFound;
}

// Attach consecutive 7TV Zero-Width layers to the nearest preceding emote.
// Spaces are retained in the token stream until a composition is known to be
// possible; the renderer can therefore still show the original words when an
// image download fails.  A Zero-Width with no anchor deliberately falls back
// to normal width, as specified by the chat contract.
static void tpk_groupZeroWidthTokens(NSMutableArray<TPKChatToken *> *tokens) {
    for (NSUInteger i = 0; i < tokens.count; i++) {
        TPKChatToken *layer = tokens[i];
        // The native-range tokenizer delegates non-native spans to
        // tokenizeText:, which already performs this pass. Do not attach an
        // already grouped layer a second time when the outer pass runs.
        if (!tpk_tokenIsEmote(layer) || !layer.zeroWidth || layer.isOverlayLayer) continue;

        NSInteger anchorIndex = (NSInteger)i - 1;
        while (anchorIndex >= 0 && tpk_tokenIsWhitespace(tokens[(NSUInteger)anchorIndex])) {
            anchorIndex--;
        }
        // Walk through an already attached layer so base + layer1 + layer2
        // all share the same root attachment.
        while (anchorIndex >= 0 &&
               tpk_tokenIsEmote(tokens[(NSUInteger)anchorIndex]) &&
               tokens[(NSUInteger)anchorIndex].isOverlayLayer) {
            anchorIndex--;
            while (anchorIndex >= 0 && tpk_tokenIsWhitespace(tokens[(NSUInteger)anchorIndex])) {
                anchorIndex--;
            }
        }
        if (anchorIndex < 0 || !tpk_tokenIsEmote(tokens[(NSUInteger)anchorIndex])) {
            continue;
        }

        TPKChatToken *anchor = tokens[(NSUInteger)anchorIndex];
        // An unanchored Zero-Width token is rendered at normal width.  It
        // must not become the base for a later Zero-Width token, otherwise a
        // sequence made only of overlays would incorrectly collapse the
        // second word into the first one.
        if (anchor.zeroWidth && !anchor.isOverlayLayer) {
            continue;
        }
        NSMutableArray<TPKChatToken *> *layers = [anchor.overlayTokens mutableCopy];
        if (!layers) layers = [NSMutableArray array];
        layer.isOverlayLayer = YES;
        [layers addObject:layer];
        anchor.overlayTokens = [layers copy];

        // The separator is part of the Zero-Width sequence, not visible chat
        // content.  Keep it marked rather than deleting it so the fallback
        // path can reconstruct the exact original text if needed.
        for (NSInteger j = anchorIndex + 1; j < (NSInteger)i; j++) {
            TPKChatToken *between = tokens[(NSUInteger)j];
            if (tpk_tokenIsWhitespace(between)) between.isSuppressedByOverlay = YES;
        }
    }
}

static void tpk_copyResolvedMetadata(TPKChatToken *token,
                                      id<TPKResolvedEmote> resolved) {
    if ([resolved respondsToSelector:@selector(providerIdentifier)]) {
        token.providerIdentifier = resolved.providerIdentifier;
    }
    if ([resolved respondsToSelector:@selector(providerName)]) {
        token.providerName = resolved.providerName;
    }
    if ([resolved respondsToSelector:@selector(zeroWidth)]) {
        token.zeroWidth = resolved.zeroWidth &&
            [TPKEmoteProviderSettings zeroWidthEnabled];
    }
}

@implementation TPKChatTokenizer

// Parse "emoteID1:start-end,start-end/emoteID2:start-end..." en plages
// triées. Twitch exprime les bornes de fin de manière inclusive. Les entrées
// réseau malformées sont ignorées pour que la tokenisation ne puisse jamais
// provoquer une sortie de plage dans NSString.
+ (NSArray<NSArray *> *)tpk_twitchEmoteRangesFromTag:(NSString *)tagValue {
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

// Twitch GIF Keyboard ajoute un tag `gifs=` sur le PRIVMSG. Chaque entrée est
// `start-end|gifID|gifURL`; la virgule sépare plusieurs GIFs. Les URLs peuvent
// contenir d'autres caractères, donc on ne découpe que les deux premiers `|`.
+ (NSArray<NSArray *> *)tpk_twitchGIFRangesFromTag:(NSString *)tagValue {
    NSMutableArray<NSArray *> *ranges = [NSMutableArray array];
    if (!tagValue.length) return ranges;

    for (NSString *gifBlock in [tagValue componentsSeparatedByString:@","]) {
        NSRange firstPipe = [gifBlock rangeOfString:@"|"];
        if (firstPipe.location == NSNotFound) continue;
        NSRange secondPipeSearch = NSMakeRange(firstPipe.location + 1,
                                                gifBlock.length - firstPipe.location - 1);
        NSRange secondPipe = [gifBlock rangeOfString:@"|"
                                              options:0
                                                range:secondPipeSearch];
        if (secondPipe.location == NSNotFound) continue;

        NSString *position = [gifBlock substringToIndex:firstPipe.location];
        NSRange dash = [position rangeOfString:@"-"];
        if (dash.location == NSNotFound) continue;
        NSString *startString = [position substringToIndex:dash.location];
        NSString *endString = [position substringFromIndex:dash.location + 1];
        if (!startString.length || !endString.length) continue;

        NSInteger start = startString.integerValue;
        NSInteger end = endString.integerValue;
        if (start < 0 || end < start) continue;

        NSString *gifID = [gifBlock substringWithRange:NSMakeRange(
            firstPipe.location + 1,
            secondPipe.location - firstPipe.location - 1)];
        NSString *urlString = [gifBlock substringFromIndex:secondPipe.location + 1];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!gifID.length || !url.absoluteString.length ||
            !([url.scheme.lowercaseString isEqualToString:@"http"] ||
              [url.scheme.lowercaseString isEqualToString:@"https"])) continue;

        [ranges addObject:@[gifID, @(start), @(end), url]];
    }

    [ranges sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        NSComparisonResult result = [(NSNumber *)left[1] compare:(NSNumber *)right[1]];
        if (result != NSOrderedSame) return result;
        return [(NSNumber *)left[2] compare:(NSNumber *)right[2]];
    }];
    return ranges;
}

+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                                  providers:(NSArray<id<TPKEmoteProvider>> *)providers {
    NSMutableArray<TPKChatToken *> *tokens = [NSMutableArray array];
    if (!text.length) return tokens;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger cursor = 0;
    while (cursor < text.length) {
        // Keep every separator verbatim (spaces, tabs and newlines).  Splitting
        // only on ASCII spaces made an emote after a tab/newline impossible to
        // resolve and could also change the original message when rendered.
        NSUInteger start = cursor;
        BOOL isWhitespace = [whitespace characterIsMember:[text characterAtIndex:cursor]];
        cursor++;
        while (cursor < text.length) {
            BOOL nextIsWhitespace = [whitespace characterIsMember:[text characterAtIndex:cursor]];
            if (nextIsWhitespace != isWhitespace) break;
            cursor++;
        }

        NSString *segment = [text substringWithRange:NSMakeRange(start, cursor - start)];
        if (isWhitespace) {
            [tokens addObject:[TPKChatToken textToken:segment]];
            continue;
        }
        NSString *word = segment;

        // Mention : détection simple par préfixe. La mise en forme visuelle
        // distincte (highlight du message si on est mentionné) arrive en
        // Phase 6 — ici on se contente d'identifier le token et de résoudre
        // sa couleur (comportement 7TV PC : couleur du pseudo mentionné,
        // si on l'a déjà vue passer dans le chat).
        if ([word hasPrefix:@"@"] && word.length > 1) {
            NSString *username = [word substringFromIndex:1];
            UIColor *color = [[TPKChatUserColorRegistry sharedRegistry]
                colorForUsername:username];
            [tokens addObject:[TPKChatToken mentionToken:word color:color]];
            continue;
        }

        BOOL resolved = NO;
        for (id<TPKEmoteProvider> provider in providers) {
            id<TPKResolvedEmote> emote = [provider resolveEmoteNamed:word];
            if (!emote) continue;

            TPKChatToken *token = [TPKChatToken emoteToken:word
                                                     provider:(TPKChatTokenType)provider.tokenType
                                                      emoteID:emote.emoteID];
            token.resolvedEmote = emote;
            tpk_copyResolvedMetadata(token, emote);
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
            UIColor *color = [[TPKChatUserColorRegistry sharedRegistry]
                colorForUsername:word];
            if (color) {
                [tokens addObject:[TPKChatToken mentionToken:word color:color]];
            } else {
                [tokens addObject:[TPKChatToken textToken:word]];
            }
        }
    }

    tpk_groupZeroWidthTokens(tokens);
    return tokens;
}

+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                                  twitchEmotesTag:(NSString * _Nullable)emotesTag
                                providers:(NSArray<id<TPKEmoteProvider>> *)providers {
    return [self tokenizeText:text
             twitchEmotesTag:emotesTag
                 twitchGIFsTag:nil
                   providers:providers];
}

+ (NSArray<TPKChatToken *> *)tokenizeText:(NSString *)text
                          twitchEmotesTag:(NSString * _Nullable)emotesTag
                              twitchGIFsTag:(NSString * _Nullable)gifsTag
                                providers:(NSArray<id<TPKEmoteProvider>> *)providers {
    NSArray<NSArray *> *ranges = [self tpk_twitchEmoteRangesFromTag:emotesTag ?: @""];
    NSArray<NSArray *> *gifRanges = [self tpk_twitchGIFRangesFromTag:gifsTag ?: @""];
    if (ranges.count == 0 && gifRanges.count == 0)
        return [self tokenizeText:text providers:providers];

    // Un seul flux trié permet de conserver les positions IRC exactes sans
    // dupliquer le pipeline de tokenisation des spans texte. Le type 0 est
    // une emote native Twitch, le type 1 un GIF Twitch. En cas de position
    // identique, l'emote native passe d'abord et garde sa priorité.
    NSMutableArray<NSArray *> *mediaRanges = [NSMutableArray arrayWithCapacity:
        ranges.count + gifRanges.count];
    for (NSArray *range in ranges) {
        [mediaRanges addObject:@[@0, range[1], range[2], range[0]]];
    }
    for (NSArray *range in gifRanges) {
        NSInteger gifStart = [(NSNumber *)range[1] integerValue];
        NSInteger gifEnd = [(NSNumber *)range[2] integerValue];
        BOOL overlapsNative = NO;
        for (NSArray *nativeRange in ranges) {
            NSInteger nativeStart = [(NSNumber *)nativeRange[1] integerValue];
            NSInteger nativeEnd = [(NSNumber *)nativeRange[2] integerValue];
            if (gifStart <= nativeEnd && nativeStart <= gifEnd) {
                overlapsNative = YES;
                break;
            }
        }
        if (!overlapsNative) {
            [mediaRanges addObject:@[@1, range[1], range[2], range[0], range[3]]];
        }
    }
    [mediaRanges sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        NSComparisonResult result = [(NSNumber *)left[1] compare:(NSNumber *)right[1]];
        if (result != NSOrderedSame) return result;
        result = [(NSNumber *)left[0] compare:(NSNumber *)right[0]];
        if (result != NSOrderedSame) return result;
        return [(NSNumber *)left[2] compare:(NSNumber *)right[2]];
    }];

    NSMutableArray<TPKChatToken *> *tokens = [NSMutableArray array];
    NSInteger cursor = 0;

    for (NSArray *range in mediaRanges) {
        BOOL isGIF = [(NSNumber *)range[0] integerValue] == 1;
        NSString *mediaID = range[3];
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
        if (isGIF) {
            NSURL *gifURL = range.count > 4 ? range[4] : nil;
            TPKChatToken *token = [TPKChatToken gifToken:emoteText
                                                     gifID:mediaID
                                                       url:gifURL];
            [tokens addObject:token];
        } else {
            id<TPKResolvedEmote> resolved =
                [TPKTwitchNativeEmoteFactory resolvedEmoteForTwitchEmoteID:mediaID];
            if (resolved) {
                TPKChatToken *token = [TPKChatToken emoteToken:emoteText
                                                         provider:TPKChatTokenTypeEmoteTwitch
                                                          emoteID:mediaID];
                token.resolvedEmote = resolved;
                tpk_copyResolvedMetadata(token, resolved);
                [tokens addObject:token];
            } else {
                [tokens addObject:[TPKChatToken textToken:emoteText]];
            }
        }
        cursor = end + 1;
    }

    if (cursor < (NSInteger)text.length) {
        NSString *span = [text substringFromIndex:cursor];
        [tokens addObjectsFromArray:[self tokenizeText:span providers:providers]];
    }
    tpk_groupZeroWidthTokens(tokens);
    return tokens;
}

@end
