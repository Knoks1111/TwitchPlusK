#import "Chat/tpK-chat-viewer-card.h"
#import "Chat/tpK-chat-custom-view.h"
#import "Core/tpK-channel-resolver.h"
#import "Core/tpK-core-manager.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#define JSI_EXPORT __attribute__((visibility("hidden")))
#include <jsi/jsi.h>
#include <atomic>

// JSI lifetime helpers from React Native 0.86.3; license in JSI/LICENSE.
namespace facebook::jsi {
Buffer::~Buffer() = default;
Value::~Value() {
    if (kind_ >= PointerKind) data_.pointer.~Pointer();
}
}

NSAttributedStringKey const TPKChatViewerCardUserIDAttribute = @"TPKChatViewerCardUserID";
static char kApprovedBundle, kInstalledBridge, kInvalidatedRuntime;
static NSHashTable *sRuntimes;
static NSURLSessionDataTask *sUserRequest;
static std::atomic<NSUInteger> sRequestGeneration{0};
static void (*sStart)(id, SEL);
static void (*sLoad)(id, SEL, id);
static void (*sInvalidate)(id, SEL);

@protocol TPKViewerCardRuntime <NSObject>
- (void)callFunctionOnBufferedRuntimeExecutor:(std::function<void(facebook::jsi::Runtime &)> &&)executor;
@end

static void TPKProfileEnqueue(id object, std::function<void(facebook::jsi::Runtime &)> &&work) {
    @synchronized(object) {
        if (![objc_getAssociatedObject(object, &kInvalidatedRuntime) boolValue])
            [(id<TPKViewerCardRuntime>)object callFunctionOnBufferedRuntimeExecutor:std::move(work)];
    }
}

static void TPKProfileLog(NSString *reason) {
    TPKManager *manager = TPKManager.sharedManager;
    if (manager.logsEnabled && manager.logChatCustom)
        [manager log:@"[ChatCustom] 👤 Profile: %@", reason];
}

static BOOL TPKProfileLogin(NSString *login) {
    if (![login isKindOfClass:NSString.class] || !login.length || login.length > 25) return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789_"].invertedSet;
    return [login rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL TPKProfileSourceVisible(UIView *view) {
    if (!view.window || !TPKManager.sharedManager.chatCustomTestEnabled) return NO;
    BOOL hasRNTranscript = NO;
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
        if ([cursor isKindOfClass:TPKChatCustomView.class]) {
            UIView *nativeView = ((TPKChatCustomView *)cursor).tpk_nativeTranscriptView;
            if (nativeView) hasRNTranscript = [NSStringFromClass(nativeView.class) isEqualToString:@"RCTScrollViewComponentView"];
        }
    }
    return hasRNTranscript;
}

class TPKProfileBuffer final : public facebook::jsi::Buffer {
    std::string text;
public:
    explicit TPKProfileBuffer(NSString *script) : text(script.UTF8String) {}
    size_t size() const override { return text.size(); }
    const uint8_t *data() const override { return reinterpret_cast<const uint8_t *>(text.data()); }
};

static BOOL TPKProfileEvaluate(facebook::jsi::Runtime &runtime, NSString *script) {
    try {
        auto result = runtime.evaluateJavaScript(std::make_shared<TPKProfileBuffer>(script),
                                                "twitchplusk-viewer-card.js");
        return result.isBool() && result.getBool();
    } catch (...) {
        TPKProfileLog(@"JavaScript request failed");
        return NO;
    }
}

// Install before ChatArea mounts; keep the hook order stable for the runtime lifetime.
static const char *kProfileAdapter = R"TPKPROFILE(
(function () {
  if (globalThis.__TPKViewerCard) return true;
  if (typeof globalThis.__r !== 'function') return false;
  const commands = __r(4650), module = __r(72), React = module.default || module;
  if (typeof commands.useChatCommands !== 'function' || typeof React.useEffect !== 'function') return false;
  const original = commands.useChatCommands, mounted = new Set();
  commands.useChatCommands = function (options) {
    const result = original.apply(this, arguments);
    const channelID = String(options.channelID || '');
    const channelLogin = String(options.channelLogin || '').toLowerCase();
    const open = options.openViewerCard;
    React.useEffect(() => {
      if (!/^[1-9][0-9]*$/.test(channelID) || !channelLogin || typeof open !== 'function') return;
      const record = {channelID, channelLogin, open};
      mounted.add(record);
      return () => mounted.delete(record);
    }, [channelID, channelLogin, open]);
    return result;
  };
  Object.defineProperty(globalThis, '__TPKViewerCard', {value: {
    open(request) {
      if (!request || typeof request.login !== 'string' || !/^[a-z0-9_]{1,25}$/.test(request.login)) return false;
      const matches = Array.from(mounted).filter(record => record.channelID === request.channelID &&
        record.channelLogin === request.channelLogin);
      if (matches.length !== 1) return false;
      matches[0].open(request.login);
      return true;
    }
  }});
  return true;
})()
)TPKPROFILE";

static BOOL TPKProfileApprovedSource(id source) {
    typedef NSDictionary *(*VersionFunction)(void);
    auto getVersion = (VersionFunction)dlsym(RTLD_DEFAULT, "RCTGetReactNativeVersion");
    NSDictionary *version = getVersion ? getVersion() : nil;
    if ([version[@"major"] integerValue] != 0 || [version[@"minor"] integerValue] != 86 ||
        [version[@"patch"] integerValue] != 3) return NO;
    if (![source respondsToSelector:@selector(data)]) return NO;
    NSData *data = [source valueForKey:@"data"];
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > UINT32_MAX) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (unsigned char byte : digest) [hash appendFormat:@"%02x", byte];
    return [hash isEqualToString:@"03ba6fb465afc98725cf53b8c3fa733c050cedd5c36b5ab1a998422e3049e453"];
}

static void TPKProfileStart(id self, SEL selector) {
    sStart(self, selector);
    @synchronized(sRuntimes) { [sRuntimes addObject:self]; }
    __weak id weakRuntime = self;
    TPKProfileEnqueue(self,
        [weakRuntime](facebook::jsi::Runtime &runtime) {
            id object = weakRuntime;
            if (!object || ![objc_getAssociatedObject(object, &kApprovedBundle) boolValue]) return;
            BOOL installed = TPKProfileEvaluate(runtime, [NSString stringWithUTF8String:kProfileAdapter]);
            objc_setAssociatedObject(object, &kInstalledBridge, @(installed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TPKProfileLog(installed ? @"RN bridge ready" : @"unsupported RN exports");
        });
}

static void TPKProfileLoad(id self, SEL selector, id source) {
    BOOL approved = TPKProfileApprovedSource(source);
    objc_setAssociatedObject(self, &kApprovedBundle, @(approved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!approved) TPKProfileLog(@"unsupported React version or bundle");
    sLoad(self, selector, source);
}

static void TPKProfileInvalidate(id self, SEL selector) {
    @synchronized(self) {
        objc_setAssociatedObject(self, &kInvalidatedRuntime, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kApprovedBundle, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(sRuntimes) { [sRuntimes removeObject:self]; }
        sInvalidate(self, selector);
    }
}

static id TPKProfileRuntime(void) {
    NSMutableArray *matches = [NSMutableArray array];
    @synchronized(sRuntimes) {
        for (id runtime in sRuntimes)
            if ([objc_getAssociatedObject(runtime, &kApprovedBundle) boolValue] &&
                [objc_getAssociatedObject(runtime, &kInstalledBridge) boolValue]) [matches addObject:runtime];
    }
    return matches.count == 1 ? matches.firstObject : nil;
}

void TPKChatViewerCardOpen(NSString *userID, UIView *sourceView) {
    if (!NSThread.isMainThread) return;
    if (!TPKProfileSourceVisible(sourceView)) return;
    if (![userID isKindOfClass:NSString.class] || !userID.length || userID.length > 20 ||
        [userID rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return;
    [sUserRequest cancel];
    sUserRequest = nil;
    NSUInteger requestGeneration = ++sRequestGeneration;
    TPKChannelContext *context = TPKCurrentChannelContext();
    if (!context.channelID || !TPKProfileLogin(context.channelName) || !TPKProfileRuntime()) {
        TPKProfileLog(@"no unambiguous active RN chat");
        return;
    }
    NSDictionary *credentials = [TPKManager.sharedManager tpk_twitchCredentialsSnapshot];
    if (!credentials[@"Authorization"] || !credentials[@"Client-ID"]) {
        TPKProfileLog(@"user lookup credentials unavailable");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://api.twitch.tv/helix/users?id=" stringByAppendingString:userID]]];
    request.timeoutInterval = 8;
    [request setValue:credentials[@"Authorization"] forHTTPHeaderField:@"Authorization"];
    [request setValue:credentials[@"Client-ID"] forHTTPHeaderField:@"Client-ID"];
    __weak UIView *weakSource = sourceView;
    sUserRequest = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            id json = !error && data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            id users = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
            id user = [users isKindOfClass:NSArray.class] && [users count] == 1 ? users[0] : nil;
            NSString *login = [user isKindOfClass:NSDictionary.class] ? user[@"login"] : nil;
            BOOL valid = [response isKindOfClass:NSHTTPURLResponse.class] &&
                ((NSHTTPURLResponse *)response).statusCode == 200 && TPKProfileLogin(login) &&
                [user[@"id"] isKindOfClass:NSString.class] && [user[@"id"] isEqualToString:userID];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (requestGeneration != sRequestGeneration) return;
                sUserRequest = nil;
                if (!TPKChannelContextIsCurrent(context) || !TPKProfileSourceVisible(weakSource)) return;
                id runtimeObject = TPKProfileRuntime();
                if (!valid || !runtimeObject) { TPKProfileLog(@"user lookup or runtime unavailable"); return; }
                NSDictionary *payload = @{@"login": login, @"channelID": @(context.channelID).stringValue,
                                          @"channelLogin": context.channelName};
                NSData *encoded = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                NSString *script = [NSString stringWithFormat:
                    @"!!(globalThis.__TPKViewerCard && globalThis.__TPKViewerCard.open(%@))",
                    [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]];
                TPKProfileEnqueue(runtimeObject,
                    [context, script, requestGeneration, runtimeObject](facebook::jsi::Runtime &runtime) {
                        if (requestGeneration != sRequestGeneration || !TPKChannelContextIsCurrent(context) ||
                            !TPKManager.sharedManager.chatCustomTestEnabled ||
                            ![objc_getAssociatedObject(runtimeObject, &kApprovedBundle) boolValue]) return;
                        BOOL sent = TPKProfileEvaluate(runtime, script);
                        TPKProfileLog(sent ? @"viewer-card request sent" : @"no unique mounted profile handler");
                    });
            });
        }];
    [sUserRequest resume];
}

void TPKChatViewerCardSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"RCTInstance");
        Method start = class_getInstanceMethod(cls, NSSelectorFromString(@"_start"));
        Method load = class_getInstanceMethod(cls, NSSelectorFromString(@"_loadScriptFromSource:"));
        Method invalidate = class_getInstanceMethod(cls, @selector(invalidate));
        if (!start || !load || !invalidate ||
            !class_getInstanceMethod(cls, @selector(callFunctionOnBufferedRuntimeExecutor:))) return;
        sRuntimes = [NSHashTable weakObjectsHashTable];
        sStart = (void (*)(id, SEL))method_setImplementation(start, (IMP)TPKProfileStart);
        sLoad = (void (*)(id, SEL, id))method_setImplementation(load, (IMP)TPKProfileLoad);
        sInvalidate = (void (*)(id, SEL))method_setImplementation(invalidate, (IMP)TPKProfileInvalidate);
        for (NSNotificationName name in @[TPKChannelResolverDidChangeNotification,
                                         TPKChatCustomToggleDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    ++sRequestGeneration;
                    [sUserRequest cancel];
                    sUserRequest = nil;
                }];
        }
    });
}
