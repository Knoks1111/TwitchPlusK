/*
 * tpK-picker-resolved-emote.m
 * Extrait de tpK-core-manager.m lors du nettoyage du picker.
 */

#import "Picker/tpK-picker-resolved-emote.h"
#import "Settings/tpK-chat-appearance-config.h"
#import "Core/tpK-core-manager.h"

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

NSURL *TPKPickerImageURLForEmote(TPKEmote *emote) {
    if (!emote) return nil;
    if ([emote isKindOfClass:[TPKPickerCatalogEmote class]]) {
        TPKEmoteDescriptor *descriptor = [(TPKPickerCatalogEmote *)emote descriptor];
        return [descriptor imageURLForResolution:
            [TPKChatAppearanceConfig sharedConfig].emoteImageResolution];
    }
    return [[TPKManager sharedManager] cdnURLForEmote:emote];
}
