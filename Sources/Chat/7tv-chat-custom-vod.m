/* Adaptateur VOD du chat commun. */

#import "Chat/7tv-chat-custom-vod.h"
#import "Chat/7tv-chat-integration.h"
#import "Chat/7tv-chat-tokenizer.h"
#import "Emote/7tv-emote-provider.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <unistd.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uintptr_t first;
    uintptr_t second;
} S7TVNativeSwiftString;

typedef struct {
    size_t stride;
    size_t elementOffset;
    int32_t createdAtOffset;
    int32_t messageOffset;
} S7TVNativeVideoCommentLayout;

@protocol S7TVNativeChatBadge <NSObject>
- (NSString *)badgeSetName;
- (NSString *)versionName;
@end

enum {
    kS7TVNativeMessageEmoteFragmentsOffset = 0x18,
    kS7TVNativeMessageBadgesOffset = 0x20,
    kS7TVNativeMessageColorOffset = 0x28,
    kS7TVNativeEmoteRangeStride = 0x40,
};

typedef const void *(*S7TVTypeMetadataAccessor)(void *request);
typedef void (*S7TVReplayCommentsCallback)(void *syncManager,
                                           const void *commentsArray,
                                           double timestamp);

static S7TVNativeVideoCommentLayout s_videoCommentLayout;
static BOOL s_videoCommentLayoutReady = NO;
static S7TVReplayCommentsCallback s_originalReplayComments = NULL;
static BOOL s_nativeReplayHookInstalled = NO;

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    uintptr_t start;
    uintptr_t end;
    uintptr_t executableStart;
    uintptr_t executableEnd;
} S7TVReplayImageInfo;

static BOOL s7tv_replayAddressInRange(uintptr_t address,
                                      size_t length,
                                      uintptr_t start,
                                      uintptr_t end) {
    if (address < start || address > end) return NO;
    return length <= end - address;
}

static BOOL s7tv_replayImageInfoForClass(Class targetClass,
                                         S7TVReplayImageInfo *info) {
    if (!targetClass || !info) return NO;

    const char *classImageName = class_getImageName(targetClass);
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *imageName = _dyld_get_image_name(index);
        if (!imageName || (classImageName &&
            strcmp(imageName, classImageName) != 0)) {
            continue;
        }

        const struct mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) continue;

        const struct mach_header_64 *header64 =
            (const struct mach_header_64 *)header;
        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        uintptr_t imageStart = UINTPTR_MAX;
        uintptr_t imageEnd = 0;
        uintptr_t executableStart = UINTPTR_MAX;
        uintptr_t executableEnd = 0;

        struct load_command *command =
            (struct load_command *)((uint8_t *)header64 + sizeof(*header64));
        for (uint32_t commandIndex = 0;
             commandIndex < header64->ncmds;
             commandIndex++) {
            if (command->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *segment =
                    (struct segment_command_64 *)command;
                uintptr_t segmentStart =
                    (uintptr_t)(segment->vmaddr + slide);
                uintptr_t segmentEnd = segmentStart + segment->vmsize;
                if (segmentStart < imageStart) imageStart = segmentStart;
                if (segmentEnd > imageEnd) imageEnd = segmentEnd;
                if ((segment->initprot & VM_PROT_EXECUTE) != 0) {
                    if (segmentStart < executableStart) {
                        executableStart = segmentStart;
                    }
                    if (segmentEnd > executableEnd) {
                        executableEnd = segmentEnd;
                    }
                }
            }
            command = (struct load_command *)((uint8_t *)command +
                                               command->cmdsize);
        }

        if (imageStart == UINTPTR_MAX || imageEnd <= imageStart) continue;
        info->header = header64;
        info->slide = slide;
        info->start = imageStart;
        info->end = imageEnd;
        info->executableStart = executableStart;
        info->executableEnd = executableEnd;
        return YES;
    }
    return NO;
}

static const void *s7tv_replayResolveRelativePointer(
    const uint8_t *field,
    const S7TVReplayImageInfo *info,
    BOOL indirectable) {
    if (!field || !info ||
        !s7tv_replayAddressInRange((uintptr_t)field, sizeof(int32_t),
                                   info->start, info->end)) {
        return NULL;
    }

    int32_t relative = 0;
    memcpy(&relative, field, sizeof(relative));
    if (relative == 0) return NULL;

    uintptr_t target = (uintptr_t)(field + relative);
    if (indirectable && (relative & 1)) {
        target = (uintptr_t)(field + (relative & ~1));
        if (!s7tv_replayAddressInRange(target, sizeof(uintptr_t),
                                       info->start, info->end)) {
            return NULL;
        }
        uintptr_t indirectTarget = 0;
        memcpy(&indirectTarget, (const void *)target,
               sizeof(indirectTarget));
        target = indirectTarget;
    }

    if (!s7tv_replayAddressInRange(target, sizeof(uintptr_t),
                                   info->start, info->end)) {
        return NULL;
    }
    return (const void *)target;
}

static const char *s7tv_replayContextName(const void *descriptor,
                                           const S7TVReplayImageInfo *info) {
    uintptr_t descriptorAddress = (uintptr_t)descriptor;
    if (!s7tv_replayAddressInRange(descriptorAddress, 0x0C,
                                   info->start, info->end)) {
        return NULL;
    }

    const uint8_t *nameField = (const uint8_t *)(descriptorAddress + 0x08);
    const void *name = s7tv_replayResolveRelativePointer(nameField, info, NO);
    if (!name || !s7tv_replayAddressInRange((uintptr_t)name, 1,
                                            info->start, info->end)) {
        return NULL;
    }

    uintptr_t address = (uintptr_t)name;
    uintptr_t end = info->end;
    for (NSUInteger length = 0; address + length < end && length < 128;
         length++) {
        if (((const uint8_t *)name)[length] == '\0') return (const char *)name;
    }
    return NULL;
}

static BOOL s7tv_replayLooksExecutable(uintptr_t address,
                                       const S7TVReplayImageInfo *info) {
    return info->executableStart != UINTPTR_MAX &&
           address >= info->executableStart &&
           address < info->executableEnd;
}

static BOOL s7tv_findReplayWitnessTable(Class replayViewController,
                                        uintptr_t **witnessTableOut) {
    if (!replayViewController || !witnessTableOut) return NO;

    S7TVReplayImageInfo info = {0};
    if (!s7tv_replayImageInfoForClass(replayViewController, &info)) {
        return NO;
    }

    const struct section_64 *protocolSection =
        getsectbynamefromheader_64(info.header, "__TEXT", "__swift5_proto");
    if (!protocolSection || protocolSection->size < sizeof(int32_t)) {
        return NO;
    }

    const uint8_t *protocols = (const uint8_t *)(protocolSection->addr +
                                                  info.slide);
    if (!s7tv_replayAddressInRange((uintptr_t)protocols,
                                   protocolSection->size,
                                   info.start, info.end)) {
        return NO;
    }

    const char *wantedType = "ChatReplayViewController";
    const char *wantedProtocol = "ChatReplaySyncManagerDelegate";
    NSUInteger recordCount = protocolSection->size / sizeof(int32_t);
    for (NSUInteger index = 0; index < recordCount; index++) {
        const uint8_t *entry = protocols + index * sizeof(int32_t);
        const void *conformance =
            s7tv_replayResolveRelativePointer(entry, &info, NO);
        if (!conformance || !s7tv_replayAddressInRange(
                (uintptr_t)conformance, 16, info.start, info.end)) {
            continue;
        }

        const uint8_t *record = (const uint8_t *)conformance;
        const void *protocol =
            s7tv_replayResolveRelativePointer(record + 0x00, &info, YES);
        const void *type =
            s7tv_replayResolveRelativePointer(record + 0x04, &info, YES);
        const char *protocolName = s7tv_replayContextName(protocol, &info);
        const char *typeName = s7tv_replayContextName(type, &info);
        if (!protocolName || !typeName ||
            strcmp(protocolName, wantedProtocol) != 0 ||
            strcmp(typeName, wantedType) != 0) {
            continue;
        }

        const void *pattern =
            s7tv_replayResolveRelativePointer(record + 0x08, &info, NO);
        uintptr_t *witnessTable = (uintptr_t *)pattern;
        if (!witnessTable ||
            !s7tv_replayAddressInRange((uintptr_t)witnessTable,
                                       4 * sizeof(uintptr_t),
                                       info.start, info.end) ||
            !s7tv_replayLooksExecutable(witnessTable[1], &info) ||
            !s7tv_replayLooksExecutable(witnessTable[2], &info) ||
            !s7tv_replayLooksExecutable(witnessTable[3], &info)) {
            return NO;
        }

        *witnessTableOut = witnessTable;
        return YES;
    }

    return NO;
}

static void *s7tv_lookupSwiftSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol && name[0] == '_') {
        symbol = dlsym(RTLD_DEFAULT, name + 1);
    }
    return symbol;
}

static NSString *s7tv_smallSwiftString(S7TVNativeSwiftString value) {
    uint8_t bytes[sizeof(value)] = {0};
    memcpy(bytes, &value, sizeof(value));

    uint8_t marker = bytes[15];
    if ((marker & 0xF0) != 0xE0) return nil;

    NSUInteger length = marker & 0x0F;
    if (length > 15) return nil;
    return [[NSString alloc] initWithBytes:bytes
                                    length:length
                                  encoding:NSUTF8StringEncoding];
}

static NSString *s7tv_nativeSwiftString(S7TVNativeSwiftString value) {
    if (value.first == 0 && value.second == 0) return @"";

    static void *bridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bridge = s7tv_lookupSwiftSymbol(
            "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

#if defined(__aarch64__)
    if (bridge) {
        S7TVNativeSwiftString copy = value;
        NSString *result = nil;

        __asm__ volatile(
            "mov x20, %1\n"
            "mov x0, %3\n"
            "mov x1, %4\n"
            "blr %2\n"
            "mov %0, x0\n"
            : "=&r"(result)
            : "r"(&copy), "r"(bridge), "r"(value.first), "r"(value.second)
            : "x1", "x20", "x30", "memory");

        if (result) return result;
    }
#endif

    return s7tv_smallSwiftString(value);
}

static NSString *s7tv_nativeSwiftStringAt(const uint8_t *base,
                                          size_t offset) {
    if (!base) return @"";
    S7TVNativeSwiftString value = {0};
    memcpy(&value, base + offset, sizeof(value));
    return s7tv_nativeSwiftString(value);
}

static const uint8_t *s7tv_nativeArrayElements(const uint8_t *field,
                                                size_t elementSize,
                                                NSUInteger maxCount,
                                                NSUInteger *countOut) {
    if (!field || !elementSize || !countOut) return NULL;

    const uint8_t *storage = NULL;
    memcpy(&storage, field, sizeof(storage));
    if (!storage) return NULL;

    NSUInteger count = 0;
    memcpy(&count, storage + 0x10, sizeof(count));
    if (count == 0 || count > maxCount ||
        count > (SIZE_MAX - 0x20) / elementSize) {
        return NULL;
    }

    *countOut = count;
    return storage + 0x20;
}

static NSArray<NSString *> *s7tv_badgeIdentifiersFromNativeMessage(
    const uint8_t *message) {
    if (!message) return @[];

    NSUInteger count = 0;
    const uint8_t *elements = s7tv_nativeArrayElements(
        message + kS7TVNativeMessageBadgesOffset,
        sizeof(void *), 32, &count);
    if (!elements) return @[];

    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        const void *rawBadge = NULL;
        memcpy(&rawBadge,
               elements + index * sizeof(rawBadge),
               sizeof(rawBadge));
        if (!rawBadge) continue;

        id<S7TVNativeChatBadge> badge =
            (__bridge id<S7TVNativeChatBadge>)rawBadge;
        if (![badge respondsToSelector:@selector(badgeSetName)] ||
            ![badge respondsToSelector:@selector(versionName)]) {
            continue;
        }

        NSString *setName = [badge badgeSetName];
        NSString *versionName = [badge versionName];
        if (setName.length && versionName.length) {
            [identifiers addObject:
                [NSString stringWithFormat:@"%@/%@", setName, versionName]];
        }
    }
    return identifiers;
}

static NSString *s7tv_twitchEmotesTagFromNativeMessage(
    const uint8_t *message, NSString *body) {
    if (!message || !body.length) return @"";

    NSUInteger count = 0;
    const uint8_t *elements = s7tv_nativeArrayElements(
        message + kS7TVNativeMessageEmoteFragmentsOffset,
        kS7TVNativeEmoteRangeStride, 64, &count);
    if (!elements) return @"";

    NSMutableArray<NSString *> *blocks =
        [NSMutableArray arrayWithCapacity:count];
    NSUInteger searchLocation = 0;
    for (NSUInteger index = 0; index < count; index++) {
        const uint8_t *range =
            elements + index * kS7TVNativeEmoteRangeStride;
        NSString *identifier = s7tv_nativeSwiftStringAt(range, 0x00);
        NSString *emoteID = s7tv_nativeSwiftStringAt(range, 0x10);
        if (!emoteID.length) continue;

        if (!identifier.length || searchLocation >= body.length) continue;
        NSRange searchRange = NSMakeRange(searchLocation,
                                          body.length - searchLocation);
        NSRange found = [body rangeOfString:identifier
                                    options:NSLiteralSearch
                                      range:searchRange];
        if (found.location == NSNotFound || found.length == 0) continue;

        NSUInteger end = NSMaxRange(found) - 1;
        [blocks addObject:[NSString stringWithFormat:@"%@:%lu-%lu",
                           emoteID,
                           (unsigned long)found.location,
                           (unsigned long)end]];
        searchLocation = NSMaxRange(found);
    }
    return [blocks componentsJoinedByString:@"/"];
}

static BOOL s7tv_prepareVideoCommentLayout(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        S7TVTypeMetadataAccessor accessor =
            (S7TVTypeMetadataAccessor)s7tv_lookupSwiftSymbol(
                "_$s9TwitchKit12VideoCommentVMa");
        if (!accessor) return;

        const uint8_t *metadata = accessor(NULL);
        if (!metadata) return;

        const uint8_t *witnessTable =
            *(const uint8_t * const *)(metadata - sizeof(void *));
        if (!witnessTable) return;

        size_t valueSize = *(const size_t *)(witnessTable + 0x40);
        size_t stride = *(const size_t *)(witnessTable + 0x48);
        size_t alignmentMask = *(const size_t *)(witnessTable + 0x50);
        int32_t createdAtOffset = *(const int32_t *)(metadata + 0x18);
        int32_t messageOffset = *(const int32_t *)(metadata + 0x24);

        if (valueSize == 0 || stride < valueSize || stride > 0x1000 ||
            createdAtOffset < 0 || messageOffset < 0 ||
            (size_t)createdAtOffset + sizeof(double) > valueSize ||
            (size_t)messageOffset + 0x30 > valueSize) {
            return;
        }

        size_t elementOffset = (alignmentMask + 0x20) & ~alignmentMask;
        if (elementOffset < 0x20 || elementOffset > 0x1000) return;

        s_videoCommentLayout.stride = stride;
        s_videoCommentLayout.elementOffset = elementOffset;
        s_videoCommentLayout.createdAtOffset = createdAtOffset;
        s_videoCommentLayout.messageOffset = messageOffset;
        s_videoCommentLayoutReady = YES;
    });
    return s_videoCommentLayoutReady;
}

static S7TVChatMessage *s7tv_messageFromNativeVideoComment(
    const uint8_t *comment) {
    if (!comment || !s7tv_prepareVideoCommentLayout()) return nil;

    const S7TVNativeVideoCommentLayout layout = s_videoCommentLayout;
    NSString *messageID = s7tv_nativeSwiftStringAt(comment, 0x00);
    const uint8_t *identity = comment + 0x10;
    uint32_t authorID = *(const uint32_t *)(identity + 0x00);
    NSString *displayName = s7tv_nativeSwiftStringAt(identity, 0x28);
    if (!displayName.length) {
        displayName = s7tv_nativeSwiftStringAt(identity, 0x08);
    }

    const uint8_t *message = comment + layout.messageOffset;
    NSString *body = s7tv_nativeSwiftStringAt(message, 0x00);
    if (!messageID.length || !body.length || !displayName.length) return nil;

    double createdAt = *(const double *)(comment + layout.createdAtOffset);
    NSDate *timestamp = isfinite(createdAt)
        ? [NSDate dateWithTimeIntervalSinceReferenceDate:createdAt]
        : [NSDate date];

    S7TVChatMessage *result = [[S7TVChatMessage alloc]
        initWithMessageID:messageID
                timestamp:timestamp
             authorUserID:authorID ? [NSString stringWithFormat:@"%u", authorID] : @""
        authorDisplayName:displayName
                  rawText:body];
    result.isHistorical = YES;

    __unsafe_unretained UIColor *authorColor = nil;
    memcpy(&authorColor, message + kS7TVNativeMessageColorOffset,
           sizeof(authorColor));
    result.authorColor = authorColor;
    result.badgeIdentifiers = s7tv_badgeIdentifiersFromNativeMessage(message);
    result.twitchEmotesTag =
        s7tv_twitchEmotesTagFromNativeMessage(message, body);
    result.tokens = [SevenTVChatTokenizer tokenizeText:body
                                      twitchEmotesTag:result.twitchEmotesTag
                                            providers:s7tv_chatEmoteProviders()];
    return result;
}

static void s7tv_consumeNativeReplayComments(const void *commentsArray) {
    if (!commentsArray || !s7tv_prepareVideoCommentLayout()) return;

    const uint8_t *storage = (const uint8_t *)commentsArray;
    NSUInteger count = *(const NSUInteger *)(storage + 0x10);
    if (count == 0 || count > 4096) return;

    size_t elementOffset = s_videoCommentLayout.elementOffset;
    size_t stride = s_videoCommentLayout.stride;
    if (count > (SIZE_MAX - elementOffset) / stride) return;

    const uint8_t *comment = storage + elementOffset;
    for (NSUInteger index = 0; index < count; index++) {
        S7TVChatMessage *message =
            s7tv_messageFromNativeVideoComment(comment);
        if (message) s7tv_receiveVODMessage(message);
        comment += stride;
    }
}

static void s7tv_callOriginalReplayComments(void *syncManager,
                                             const void *commentsArray,
                                             double timestamp,
                                             void *protocolSelf) {
    S7TVReplayCommentsCallback original = s_originalReplayComments;
    if (!original) return;

#if defined(__aarch64__)
    // Le witness Swift reçoit self dans x20.
    __asm__ volatile(
        "mov x20, %0\n"
        "mov x0, %1\n"
        "mov x1, %2\n"
        "fmov d0, %d3\n"
        "blr %4\n"
        :
        : "r"(protocolSelf), "r"(syncManager), "r"(commentsArray),
          "w"(timestamp), "r"(original)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8",
          "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16",
          "x17", "x20", "x30", "d0", "d1", "d2", "d3", "d4", "d5",
          "d6", "d7", "memory");
#else
    original(syncManager, commentsArray, timestamp);
#endif
}

void s7tv_replayCommentsHookBody(void *syncManager,
                                 const void *commentsArray,
                                 double timestamp,
                                 void *protocolSelf) {
    // Alimenter le store custom avant le callback Twitch.
    s7tv_consumeNativeReplayComments(commentsArray);
    s7tv_callOriginalReplayComments(syncManager, commentsArray, timestamp,
                                     protocolSelf);
}

#if defined(__aarch64__)
__attribute__((naked)) static void s7tv_replayCommentsHook(void) {
    __asm__ volatile(
        "mov x2, x20\n"
        "b _s7tv_replayCommentsHookBody\n");
}
#else
static void s7tv_replayCommentsHook(void *syncManager,
                                     const void *commentsArray,
                                     double timestamp) {
    s7tv_replayCommentsHookBody(syncManager, commentsArray, timestamp, NULL);
}
#endif

void s7tv_installNativeReplayChatHook(void) {
    if (s_nativeReplayHookInstalled) return;

    Class replayViewController =
        NSClassFromString(@"Twitch.ChatReplayViewController");
    if (!replayViewController) return;

    uintptr_t *witnessTable = NULL;
    if (!s7tv_findReplayWitnessTable(replayViewController, &witnessTable)) {
        return;
    }

    size_t pageSize = (size_t)getpagesize();
    uintptr_t page = (uintptr_t)witnessTable & ~(pageSize - 1);
    kern_return_t writableResult = vm_protect(
        mach_task_self(),
        (vm_address_t)page,
        (vm_size_t)pageSize,
        0,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (writableResult != KERN_SUCCESS) return;

    s_originalReplayComments =
        (S7TVReplayCommentsCallback)witnessTable[1];
    witnessTable[1] = (uintptr_t)&s7tv_replayCommentsHook;
    vm_protect(mach_task_self(),
               (vm_address_t)page,
               (vm_size_t)pageSize,
               0,
               VM_PROT_READ);
    s_nativeReplayHookInstalled = YES;
}
