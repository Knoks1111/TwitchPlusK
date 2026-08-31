/*
 * 7tv-chat-tokenizer.m
 *
 * Voir 7tv-chat-tokenizer.h pour le contexte (Phase 2).
 */

#import "Chat/7tv-chat-tokenizer.h"
#import "Emote/7tv-provider-settings.h"

static BOOL s7tv_tokenIsEmote(S7TVChatToken *token) {
    return token.type == S7TVChatTokenTypeEmote7TV ||
           token.type == S7TVChatTokenTypeEmoteTwitch;
}

static BOOL s7tv_tokenIsWhitespace(S7TVChatToken *token) {
    if (token.type != S7TVChatTokenTypeText || !token.text.length) return NO;
    return [token.text rangeOfCharacterFromSet:
        [[NSCharacterSet whitespaceAndNewlineCharacterSet]
            invertedSet]].location == NSNotFound;
}

// Attach consecutive 7TV Zero-Width layers to the nearest preceding emote.
// Spaces are retained in the token stream until a composition is known to be
// possible; the renderer can therefore still show the original words when an
// image download fails.  A Zero-Width with no anchor deliberately falls back
// to normal width, as specified by the chat contract.
static void s7tv_groupZeroWidthTokens(NSMutableArray<S7TVChatToken *> *tokens) {
    for (NSUInteger i = 0; i < tokens.count; i++) {
        S7TVChatToken *layer = tokens[i];
        // The native-range tokenizer delegates non-native spans to
        // tokenizeText:, which already performs this pass. Do not attach an
        // already grouped layer a second time when the outer pass runs.
        if (!s7tv_tokenIsEmote(layer) || !layer.zeroWidth || layer.isOverlayLayer) continue;

        NSInteger anchorIndex = (NSInteger)i - 1;
        while (anchorIndex >= 0 && s7tv_tokenIsWhitespace(tokens[(NSUInteger)anchorIndex])) {
            anchorIndex--;
        }
        // Walk through an already attached layer so base + layer1 + layer2
        // all share the same root attachment.
        while (anchorIndex >= 0 &&
               s7tv_tokenIsEmote(tokens[(NSUInteger)anchorIndex]) &&
               tokens[(NSUInteger)anchorIndex].isOverlayLayer) {
            anchorIndex--;
            while (anchorIndex >= 0 && s7tv_tokenIsWhitespace(tokens[(NSUInteger)anchorIndex])) {
                anchorIndex--;
            }
        }
        if (anchorIndex < 0 || !s7tv_tokenIsEmote(tokens[(NSUInteger)anchorIndex])) {
            continue;
        }

        S7TVChatToken *anchor = tokens[(NSUInteger)anchorIndex];
        // An unanchored Zero-Width token is rendered at normal width.  It
        // must not become the base for a later Zero-Width token, otherwise a
        // sequence made only of overlays would incorrectly collapse the
        // second word into the first one.
        if (anchor.zeroWidth && !anchor.isOverlayLayer) {
            continue;
        }
        NSMutableArray<S7TVChatToken *> *layers = [anchor.overlayTokens mutableCopy];
        if (!layers) layers = [NSMutableArray array];
        layer.isOverlayLayer = YES;
        [layers addObject:layer];
        anchor.overlayTokens = [layers copy];

        // The separator is part of the Zero-Width sequence, not visible chat
        // content.  Keep it marked rather than deleting it so the fallback
        // path can reconstruct the exact original text if needed.
        for (NSInteger j = anchorIndex + 1; j < (NSInteger)i; j++) {
            S7TVChatToken *between = tokens[(NSUInteger)j];
            if (s7tv_tokenIsWhitespace(between)) between.isSuppressedByOverlay = YES;
        }
    }
}

static void s7tv_copyResolvedMetadata(S7TVChatToken *token,
                                      id<S7TVResolvedEmote> resolved) {
    if ([resolved respondsToSelector:@selector(providerIdentifier)]) {
        token.providerIdentifier = resolved.providerIdentifier;
    }
    if ([resolved respondsToSelector:@selector(providerName)]) {
        token.providerName = resolved.providerName;
    }
    if ([resolved respondsToSelector:@selector(zeroWidth)]) {
        token.zeroWidth = resolved.zeroWidth &&
            [S7TVEmoteProviderSettings zeroWidthEnabled];
    }
}

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
            [tokens addObject:[S7TVChatToken textToken:segment]];
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
            s7tv_copyResolvedMetadata(token, emote);
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

    s7tv_groupZeroWidthTokens(tokens);
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
            s7tv_copyResolvedMetadata(token, resolved);
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
    s7tv_groupZeroWidthTokens(tokens);
    return tokens;
}

@end
