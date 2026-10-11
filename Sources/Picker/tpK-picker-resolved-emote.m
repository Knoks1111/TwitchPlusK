/*
 * tpK-picker-resolved-emote.m
 * Extrait de tpK-core-manager.m (nettoyage picker).
 */

#import "Picker/tpK-picker-resolved-emote.h"
#import "Chat/tpK-chat-appearance-config.h"

@implementation TPKPickerCatalogEmote {
    TPKEmoteDescriptor *_descriptor;
}

- (instancetype)initWithDescriptor:(TPKEmoteDescriptor *)descriptor {
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

- (TPKEmoteDescriptor *)descriptor { return _descriptor; }
@end

@implementation TPKPickerResolvedEmote {
    TPKEmote *_sourceEmote;
    NSURL        *_cachedImageURL;
}

- (instancetype)initWithEmote:(TPKEmote *)emote {
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
        if ([_sourceEmote isKindOfClass:[TPKPickerCatalogEmote class]]) {
            TPKEmoteDescriptor *descriptor = [(TPKPickerCatalogEmote *)_sourceEmote descriptor];
            _cachedImageURL = [descriptor imageURLForResolution:
                [TPKChatAppearanceConfig sharedConfig].emoteImageResolution];
        } else {
            _cachedImageURL = [[TPKManager sharedManager] cdnURLForEmote:_sourceEmote];
        }
    }
    return _cachedImageURL;
}

- (NSString *)providerIdentifier {
    if ([_sourceEmote isKindOfClass:[TPKPickerCatalogEmote class]])
        return [(TPKPickerCatalogEmote *)_sourceEmote descriptor].providerIdentifier;
    return @"7tv";
}

- (NSString *)providerName {
    if ([_sourceEmote isKindOfClass:[TPKPickerCatalogEmote class]])
        return TPKEmoteProviderName([(TPKPickerCatalogEmote *)_sourceEmote descriptor].provider);
    return @"7TV";
}

- (BOOL)zeroWidth {
    if ([_sourceEmote isKindOfClass:[TPKPickerCatalogEmote class]])
        return [(TPKPickerCatalogEmote *)_sourceEmote descriptor].zeroWidth;
    return NO;
}

- (BOOL)isAnimated {
    return _sourceEmote.isAnimated;
}

@end
