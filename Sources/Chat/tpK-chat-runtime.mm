#import "Chat/tpK-chat-runtime.h"
#import "Chat/Emote/tpK-chat-emotes.h"
#import "Core/tpK-core-manager.h"
#import "Chat/FirstChatter/tpK-native-first-chatter.h"
#import "Chat/DeletedMessages/tpK-native-deleted-messages.h"
#import "Settings/tpK-chat-appearance-config.h"
#import "Localization/tpK-localization-manager.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#define JSI_EXPORT __attribute__((visibility("hidden")))
#include <jsi/jsi.h>

namespace jsi = facebook::jsi;
namespace facebook::jsi {
Buffer::~Buffer() = default;
Value::~Value() { if (kind_ >= PointerKind) data_.pointer.~Pointer(); }
}

CGFloat TPKNativeEmoteHeight(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    CGFloat value = [defaults objectForKey:@"tpk_native_emote_size"]
        ? [defaults doubleForKey:@"tpk_native_emote_size"] : 28;
    return isfinite(value) ? MIN(56, MAX(14, value)) : 28;
}

void TPKNativeSetEmoteHeight(CGFloat height) {
    if (!isfinite(height) || height < 14 || height > 56) return;
    [NSUserDefaults.standardUserDefaults setDouble:height forKey:@"tpk_native_emote_size"];
    [NSNotificationCenter.defaultCenter postNotificationName:TPKChatAppearanceConfigDidChangeNotification object:nil];
}

static char approvedKey, invalidKey;
static NSHashTable *runtimes;
static BOOL refreshPending;
static void (*originalStart)(id, SEL);
static void (*originalLoad)(id, SEL, id);
static void (*originalInvalidate)(id, SEL);

@protocol TPKChatRuntime <NSObject>
- (void)callFunctionOnBufferedRuntimeExecutor:(std::function<void(jsi::Runtime &)> &&)work;
@end

class TPKChatRuntimeBuffer final : public jsi::Buffer {
    std::string text;
public:
    explicit TPKChatRuntimeBuffer(const char *value) : text(value) {}
    size_t size() const override { return text.size(); }
    const uint8_t *data() const override { return (const uint8_t *)text.data(); }
};

static void NativeLog(NSString *message) {
    TPKManager *manager = TPKManager.sharedManager;
    if (manager.logsEnabled && manager.logChat)
        [manager log:@"[Chat] 🧪 Native chat: %@", message];
}

static void NativeWarning(NSString *message) {
    TPKManager *manager = TPKManager.sharedManager;
    if (manager.logsEnabled && manager.logErrors)
        [manager log:@"⚠️ Native chat: %@", message];
}

static void NativeInstallLog(BOOL installed, NSString *success, NSString *failure) {
    if (installed) NativeLog(success);
    else NativeWarning(failure);
}

static BOOL Evaluate(jsi::Runtime &runtime, const char *script) {
    try {
        auto result = runtime.evaluateJavaScript(std::make_shared<TPKChatRuntimeBuffer>(script),
                                                 "twitchplusk-chat-runtime.js");
        return result.isBool() && result.getBool();
    } catch (...) { NativeWarning(@"JavaScript integration failed"); return NO; }
}

static void Enqueue(id object, std::function<void(jsi::Runtime &)> &&work) {
    @synchronized(object) {
        if (![objc_getAssociatedObject(object, &invalidKey) boolValue])
            [(id<TPKChatRuntime>)object callFunctionOnBufferedRuntimeExecutor:std::move(work)];
    }
}

static BOOL Approved(id source) {
    auto versionFunction = (NSDictionary *(*)(void))dlsym(RTLD_DEFAULT, "RCTGetReactNativeVersion");
    NSDictionary *version = versionFunction ? versionFunction() : nil;
    if ([version[@"major"] integerValue] != 0 || [version[@"minor"] integerValue] != 86 ||
        [version[@"patch"] integerValue] != 3) return NO;
    if (![source respondsToSelector:@selector(data)]) return NO;
    NSData *data = [source valueForKey:@"data"];
    if (![data isKindOfClass:NSData.class] || data.length != 29678860) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (unsigned char byte : digest) [hash appendFormat:@"%02x", byte];
    return [hash isEqualToString:@"1866099398b36a4fc98717dca5715547d6f16785bfa3dc8f74605fe98d1755d8"];
}

static void Start(id self, SEL selector) {
    originalStart(self, selector);
    @synchronized(runtimes) { [runtimes addObject:self]; }
    __weak id weakObject = self;
    Enqueue(self, [weakObject](jsi::Runtime &runtime) {
        id object = weakObject;
        if (!object || ![objc_getAssociatedObject(object, &approvedKey) boolValue]) return;
        NativeInstallLog(TPKChatEmoteSizeInstall(runtime), @"emote-size adapter ready", @"unsupported emote-size export");
        NativeInstallLog(TPKNativeFirstChatterInstall(runtime), @"first-chatter adapter ready (native flag)", @"unsupported first-chatter export");
        NativeInstallLog(TPKNativeDeletedMessagesInstall(runtime), @"deleted-message adapter ready", @"unsupported deleted-message exports");
    });
}

static void Load(id self, SEL selector, id source) {
    BOOL approved = Approved(source);
    objc_setAssociatedObject(self, &approvedKey, @(approved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!approved) NativeWarning(@"unsupported bundle or React ABI");
    originalLoad(self, selector, source);
}

static void Invalidate(id self, SEL selector) {
    @synchronized(self) {
        objc_setAssociatedObject(self, &invalidKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(runtimes) { [runtimes removeObject:self]; }
        originalInvalidate(self, selector);
    }
}

void TPKChatRuntimeSetup(void) {
    TPKChatEmoteAnimationSetup();
    TPKChatUIKitEmoteSizeSetup();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"RCTInstance");
        Method start = class_getInstanceMethod(cls, NSSelectorFromString(@"_start"));
        Method load = class_getInstanceMethod(cls, NSSelectorFromString(@"_loadScriptFromSource:"));
        Method invalidate = class_getInstanceMethod(cls, @selector(invalidate));
        if (!start || !load || !invalidate || !class_getInstanceMethod(cls,
            @selector(callFunctionOnBufferedRuntimeExecutor:))) return;
        runtimes = [NSHashTable weakObjectsHashTable];
        originalStart = (void (*)(id, SEL))method_setImplementation(start, (IMP)Start);
        originalLoad = (void (*)(id, SEL, id))method_setImplementation(load, (IMP)Load);
        originalInvalidate = (void (*)(id, SEL))method_setImplementation(invalidate, (IMP)Invalidate);
        for (NSNotificationName name in @[TPKChatAppearanceConfigDidChangeNotification, TPKLanguageDidChangeNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    if (refreshPending) return;
                    refreshPending = YES;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        refreshPending = NO;
                        NSArray *objects;
                        @synchronized(runtimes) { objects = runtimes.allObjects; }
                        for (id object in objects) Enqueue(object, [object](jsi::Runtime &runtime) {
                            if (![objc_getAssociatedObject(object, &approvedKey) boolValue]) return;
                            Evaluate(runtime, "!!(globalThis.__TPKEmoteSize && __TPKEmoteSize.refresh())");
                            Evaluate(runtime, "!!(globalThis.__TPKNativeFirstChatter && __TPKNativeFirstChatter.refresh())");
                            Evaluate(runtime, "!!(globalThis.__TPKNativeDeleted && __TPKNativeDeleted.refresh())");
                        });
                    });
                }];
    });
}
