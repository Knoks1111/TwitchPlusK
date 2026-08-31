/*
 * 7tv-picker-resolved-emote.m
 * Extrait de 7tv-core-manager.m (nettoyage picker).
 */

#import "Picker/7tv-picker-resolved-emote.h"
#import "Chat/7tv-chat-appearance-config.h"

@implementation S7TVPickerCatalogEmote {
    S7TVEmoteDescriptor *_descriptor;
}

- (instancetype)initWithDescriptor:(S7TVEmoteDescriptor *)descriptor {
    self = [super init];
    if (self) {
        _descriptor = descriptor;
        self.emoteID = descriptor.emoteID;
        self.emoteName = descriptor.name;
        self.isAnimated = descriptor.animated;
        self.zeroWidth = descriptor.zeroWidth;
        self.width = (NSInteger)descriptor.nativeSize.width;
        self.height = (NSInteger)descriptor.nativeSize.height;
    }
    return self;
}

- (S7TVEmoteDescriptor *)descriptor { return _descriptor; }
@end

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
        if ([_sourceEmote isKindOfClass:[S7TVPickerCatalogEmote class]]) {
            S7TVEmoteDescriptor *descriptor = [(S7TVPickerCatalogEmote *)_sourceEmote descriptor];
            _cachedImageURL = [descriptor imageURLForResolution:
                [SevenTVChatAppearanceConfig sharedConfig].emoteImageResolution];
        } else {
            _cachedImageURL = [[SevenTVManager sharedManager] cdnURLForEmote:_sourceEmote];
        }
    }
    return _cachedImageURL;
}

- (NSString *)providerIdentifier {
    if ([_sourceEmote isKindOfClass:[S7TVPickerCatalogEmote class]])
        return [(S7TVPickerCatalogEmote *)_sourceEmote descriptor].providerIdentifier;
    return @"7tv";
}

- (NSString *)providerName {
    if ([_sourceEmote isKindOfClass:[S7TVPickerCatalogEmote class]])
        return S7TVEmoteProviderName([(S7TVPickerCatalogEmote *)_sourceEmote descriptor].provider);
    return @"7TV";
}

- (BOOL)zeroWidth {
    if ([_sourceEmote isKindOfClass:[S7TVPickerCatalogEmote class]])
        return [(S7TVPickerCatalogEmote *)_sourceEmote descriptor].zeroWidth;
    return NO;
}

- (BOOL)isAnimated {
    return _sourceEmote.isAnimated;
}

@end
