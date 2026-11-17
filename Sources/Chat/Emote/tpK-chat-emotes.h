#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

FOUNDATION_EXPORT id TPKChatEmotesReceive(id socket, id message);
FOUNDATION_EXPORT NSURLSessionWebSocketMessage *TPKChatEmotesReceiveLegacy(NSURLSessionWebSocketTask *task, NSURLSessionWebSocketMessage *message);
FOUNDATION_EXPORT NSURLRequest *TPKChatEmotesImageRequest(NSURLRequest *request);
FOUNDATION_EXPORT void TPKChatEmoteAnimationSetup(void);
FOUNDATION_EXPORT void TPKChatUIKitEmoteSizeSetup(void);
FOUNDATION_EXPORT NSString *TPKChatEmoteIdentifier(NSURL *url, CGSize size);

#ifdef __cplusplus
namespace facebook { namespace jsi { class Runtime; } }
bool TPKChatEmoteSizeInstall(facebook::jsi::Runtime &runtime);
#endif
