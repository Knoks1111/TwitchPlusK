#import "Chat/Emote/tpK-chat-emotes.h"
#import "Chat/tpK-chat-runtime.h"
#import "Core/tpK-core-manager.h"
#import "Settings/tpK-chat-appearance-config.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>

static CGRect TPKUIKitEmoteBounds(CGRect native, CGSize image, CGFloat height) {
    if (!isfinite(native.origin.y) || !isfinite(native.size.width) || !isfinite(native.size.height) ||
        native.size.width <= 0 || native.size.height <= 0 || !isfinite(height) || height < 14 || height > 56) return native;
    height = fmin(35, height);
    CGFloat ratio = native.size.width / native.size.height;
    if (isfinite(image.width) && isfinite(image.height) && image.width > 0 && image.height > 0)
        ratio = image.width / image.height;
    ratio = fmin(5, fmax(.125, ratio));
    native.origin.y += (native.size.height - height) / 2;
    native.size = CGSizeMake(height * ratio, height);
    return native;
}

typedef CGSize __attribute__((swiftcall)) (*SizeFunction)(NSInteger, void * __attribute__((swift_context)));
static SizeFunction originalSize;
static SizeFunction originalChatSize;
static void (*originalSetBounds)(id, SEL, CGRect);
static uintptr_t placeholderCallers[2];
static char aspectKey;

@protocol TPKUIKitEmoteToken <NSObject>
- (NSString *)emoteId;
@end

static CGFloat TPKUIKitIdentifierAspect(const char *identifier) {
    if (!identifier || strncmp(identifier, "tpk_r", 5)) return 0;
    unsigned value = 0, digits = 0;
    const char *cursor = identifier + 5;
    while (*cursor >= '0' && *cursor <= '9') {
        if (++digits > 4) return 0;
        value = value * 10 + (*cursor++ - '0');
    }
    return digits && *cursor == '_' && value >= 125 && value <= 5000 ? value / 1000.0 : 0;
}

static CGSize AspectForMessage(void *context, NSInteger index) {
    NSDictionary *ratios = objc_getAssociatedObject((__bridge id)context, &aspectKey);
    CGFloat ratio = [ratios[@(index)] doubleValue];
    return ratio > 0 ? CGSizeMake(ratio, 1) : CGSizeZero;
}

static void SizeLog(NSString *message) {
    TPKManager *settings = TPKManager.sharedManager;
    if (settings.logsEnabled && settings.logChat) [settings log:@"[Chat] 🧪 Swift emote sizing: %@", message];
}

static void SizeWarning(NSString *message) {
    TPKManager *settings = TPKManager.sharedManager;
    if (settings.logsEnabled && settings.logErrors) [settings log:@"⚠️ Swift emote sizing: %@", message];
}

__attribute__((used, visibility("hidden")))
void TPKUIKitPlaceholderBounds(id attachment, SEL selector, CGRect bounds, void *modelPointer, void *tokenPointer, NSUInteger index) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if ((caller == placeholderCallers[0] || caller == placeholderCallers[1]) &&
        TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled) {
        CGSize aspect = CGSizeZero;
        if (caller == placeholderCallers[0]) {
            id model = (__bridge id)modelPointer, token = (__bridge id)tokenPointer;
            if ([model isKindOfClass:NSClassFromString(@"_TtC6Twitch13MessageString")] &&
                [token isKindOfClass:NSClassFromString(@"_TtC9TwitchKit19TWMessageEmoteToken")]) {
                NSString *identifier = [(id<TPKUIKitEmoteToken>)token emoteId];
                CGFloat ratio = TPKUIKitIdentifierAspect(identifier.UTF8String);
                NSDictionary *previous = objc_getAssociatedObject(model, &aspectKey);
                if (ratio || previous[@(index)]) {
                    NSMutableDictionary *ratios = previous ? [previous mutableCopy] : [NSMutableDictionary new];
                    if (ratio) ratios[@(index)] = @(ratio); else [ratios removeObjectForKey:@(index)];
                    objc_setAssociatedObject(model, &aspectKey, [ratios copy], OBJC_ASSOCIATION_RETAIN);
                }
                if (ratio) aspect = CGSizeMake(ratio, 1);
            }
        }
        bounds = TPKUIKitEmoteBounds(bounds, aspect, TPKNativeEmoteHeight());
        static dispatch_once_t reported;
        if (TPKManager.sharedManager.logsEnabled && TPKManager.sharedManager.logChat)
            dispatch_once(&reported, ^{ SizeLog(@"text placeholder sized before layout"); });
    }
    originalSetBounds(attachment, selector, bounds);
}

// Capture the verified constructor's model/token/index before the C prologue.
__attribute__((naked)) static void SetPlaceholderBounds(void) {
    __asm__ volatile("mov x2, x19\nmov x3, x20\nmov x4, x21\nb _TPKUIKitPlaceholderBounds");
}

static CGSize __attribute__((swiftcall)) EmoteSize(NSInteger index, void * __attribute__((swift_context)) context) {
    CGSize native = originalSize(index, context);
    if (!TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled || native.width <= 0 || native.height <= 0) return native;
    static dispatch_once_t reported;
    if (TPKManager.sharedManager.logsEnabled && TPKManager.sharedManager.logChat)
        dispatch_once(&reported, ^{ SizeLog(@"native calculation reached"); });
    return TPKUIKitEmoteBounds((CGRect){CGPointZero, native}, AspectForMessage(context, index), TPKNativeEmoteHeight()).size;
}

static CGSize __attribute__((swiftcall)) ChatEmoteSize(NSInteger index, void * __attribute__((swift_context)) context) {
    CGSize native = originalChatSize(index, context);
    if (!TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled) return native;
    // The base calculation excludes the subclass's badge and avatar maps.
    CGSize emote = originalSize(index, context);
    if (emote.width <= 0 || emote.height <= 0) return native;
    static dispatch_once_t reported;
    if (TPKManager.sharedManager.logsEnabled && TPKManager.sharedManager.logChat)
        dispatch_once(&reported, ^{ SizeLog(@"chat emote calculation reached"); });
    return TPKUIKitEmoteBounds((CGRect){CGPointZero, native}, AspectForMessage(context, index), TPKNativeEmoteHeight()).size;
}

static vm_prot_t SlotAccess(uintptr_t *slot) {
    vm_address_t address = (vm_address_t)slot;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || address > (uintptr_t)slot || size < sizeof(*slot) ||
        (uintptr_t)slot - address > size - sizeof(*slot)) return VM_PROT_NONE;
    return info.protection;
}

static const struct mach_header_64 *ApprovedImage(void) {
    static const uint8_t uuid[16] = {0x07,0x18,0x45,0xa7,0x12,0xdd,0x3b,0x69,0xaf,0xa2,0x9a,0x2b,0x66,0x33,0xc5,0x4b};
    for (uint32_t image = 0; image < _dyld_image_count(); ++image) {
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(image);
        if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 || header->sizeofcmds > 65536) continue;
        const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
        for (uint32_t command = 0; command < header->ncmds && (size_t)(end - cursor) >= sizeof(struct load_command); ++command) {
            const struct load_command *load = (const void *)cursor;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - cursor)) break;
            if (load->cmd == LC_UUID && load->cmdsize >= sizeof(struct uuid_command) &&
                memcmp(((const struct uuid_command *)load)->uuid, uuid, sizeof(uuid)) == 0) return header;
            cursor += load->cmdsize;
        }
    }
    return NULL;
}

void TPKChatUIKitEmoteSizeSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const struct mach_header_64 *image = ApprovedImage();
        if (!image) { SizeWarning(@"unsupported binary"); return; }
        static const uint8_t constructorDigest[CC_SHA256_DIGEST_LENGTH] = {0xe9,0x0a,0x23,0x50,0xe4,0x14,0xf6,0x53,0xc4,0x77,0xdd,0x1f,0xfe,0x64,0x71,0x83,0x2a,0x5c,0xc5,0xb8,0x66,0xf6,0x8e,0xf1,0x66,0x59,0x49,0x68,0x76,0x3c,0xfd,0x65};
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256((const uint8_t *)image + 0x41e4bcc, 0x22c, digest);
        if (memcmp(digest, constructorDigest, sizeof(digest))) { SizeWarning(@"constructor ABI mismatch"); return; }
        uintptr_t expected[] = {(uintptr_t)image + 0x41e2284, (uintptr_t)image + 0x1f37f00};
        uintptr_t replacements[] = {(uintptr_t)EmoteSize, (uintptr_t)ChatEmoteSize};
        static const uint32_t prologue[] = {0xd10203ff,0x6d032beb,0x6d0423e9,0xa90557f6};
        for (NSUInteger i = 0; i < 2; ++i)
            if (memcmp((const void *)expected[i], prologue, sizeof(prologue))) { SizeWarning(@"code mismatch"); return; }
        static const uint32_t placeholderCode[] = {0xaa1703e0,0x4ea81d02,0x4ea91d23,0x943d798c};
        static const uint32_t cheerCode[] = {0x1e679002,0x1e679003,0xaa1803e0,0x943d7eb5};
        if (memcmp((const uint8_t *)image + 0x41e4ca4, placeholderCode, sizeof(placeholderCode)) ||
            memcmp((const uint8_t *)image + 0x41e3800, cheerCode, sizeof(cheerCode))) {
            SizeWarning(@"placeholder code mismatch"); return;
        }
        Method boundsMethod = class_getInstanceMethod(NSTextAttachment.class, @selector(setBounds:));
        if (!boundsMethod || method_getNumberOfArguments(boundsMethod) != 3) { SizeWarning(@"placeholder setter unavailable"); return; }
        Class classes[] = {NSClassFromString(@"_TtC6Twitch13MessageString"), NSClassFromString(@"_TtC6Twitch17ChatMessageString")};
        uintptr_t *slots[2];
        for (NSUInteger i = 0; i < 2; ++i) {
            if (!classes[i]) { SizeWarning(@"class unavailable"); return; }
            // Twitch32 method descriptor: vtable offset21, method index23.
            slots[i] = (uintptr_t *)((uint8_t *)(__bridge void *)classes[i] + 0x160);
            vm_prot_t access = SlotAccess(slots[i]);
            NSString *name = NSStringFromClass(classes[i]);
            if (!(access & VM_PROT_READ)) { SizeWarning([name stringByAppendingString:@": table unreadable"]); return; }
            if (__atomic_load_n(slots[i], __ATOMIC_ACQUIRE) != expected[i]) {
                SizeWarning([name stringByAppendingString:@": entry mismatch"]); return;
            }
            if (!(access & VM_PROT_WRITE)) { SizeWarning([name stringByAppendingString:@": table read-only, entry verified"]); return; }
        }
        originalSize = (SizeFunction)expected[0];
        originalChatSize = (SizeFunction)expected[1];
        for (NSUInteger i = 0; i < 2; ++i) {
            uintptr_t current = expected[i];
            if (!__atomic_compare_exchange_n(slots[i], &current, replacements[i], NO, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                if (i) {
                    current = replacements[0];
                    __atomic_compare_exchange_n(slots[0], &current, expected[0], NO, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
                }
                SizeWarning(@"method table changed"); return;
            }
        }
        // Only native emote/Cheer constructors may resize text placeholders.
        placeholderCallers[0] = (uintptr_t)image + 0x41e4cb4;
        placeholderCallers[1] = (uintptr_t)image + 0x41e3810;
        originalSetBounds = (void *)method_getImplementation(boundsMethod);
        method_setImplementation(boundsMethod, (IMP)SetPlaceholderBounds);
        SizeLog(@"adapter ready");
    });
}
