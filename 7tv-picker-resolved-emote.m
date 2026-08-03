/*
 * 7tv-picker-resolved-emote.m
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import "7tv-picker-resolved-emote.h"

@implementation S7TVPickerResolvedEmote {
    SevenTVEmote *_sourceEmote;
    NSURL        *_cachedImageURL;
}

- (instancetype)initWithEmote:(SevenTVEmote *)emote {
    self = [super init];
    if (self) _sourceEmote = emote;
    return self;
}

- (NSString *)emoteID {
    return _sourceEmote.emoteID;
}

- (CGSize)nativeSize {
    return CGSizeMake(_sourceEmote.width, _sourceEmote.height);
}

- (NSURL *)imageURL {
    if (!_cachedImageURL) {
        _cachedImageURL = [[SevenTVManager sharedManager] cdnURLForEmote:_sourceEmote];
    }
    return _cachedImageURL;
}

- (BOOL)isAnimated {
    return _sourceEmote.isAnimated;
}

@end
