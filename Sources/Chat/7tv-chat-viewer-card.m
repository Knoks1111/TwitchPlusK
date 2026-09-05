#import "Chat/7tv-chat-viewer-card.h"
#import "Chat/7tv-chat-custom-view.h"
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL s7tv_isChannelChatViewController(id object) {
    if (!object) return NO;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if ([name isEqualToString:@"Twitch.ChannelChatViewController"] ||
            [name isEqualToString:@"_TtC6Twitch25ChannelChatViewController"]) {
            return YES;
        }
    }
    return NO;
}

static UIViewController *s7tv_channelChatViewControllerFromResponder(UIResponder *responder) {
    for (NSUInteger depth = 0; responder && depth < 64; depth++) {
        if ([responder isKindOfClass:[UIViewController class]] &&
            s7tv_isChannelChatViewController(responder)) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIViewController *s7tv_channelChatViewControllerInTree(
    UIViewController *controller,
    NSMutableSet<NSValue *> *visited) {
    if (!controller) return nil;

    NSValue *identity = [NSValue valueWithNonretainedObject:controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    if (s7tv_isChannelChatViewController(controller)) return controller;

    UIViewController *found = s7tv_channelChatViewControllerInTree(
        controller.presentedViewController, visited);
    if (found) return found;

    for (UIViewController *child in controller.childViewControllers) {
        found = s7tv_channelChatViewControllerInTree(child, visited);
        if (found) return found;
    }
    return nil;
}

static UIViewController *s7tv_findChannelChatViewController(UIView *sourceView) {
    UIViewController *controller = s7tv_channelChatViewControllerFromResponder(sourceView);
    if (controller) return controller;

    UIWindow *window = sourceView.window;
    if (!window.rootViewController) return nil;
    return s7tv_channelChatViewControllerInTree(
        window.rootViewController, [NSMutableSet set]);
}

BOOL s7tv_openViewerCardForUsername(NSString *username, UIView *sourceView) {
    if (![username isKindOfClass:[NSString class]] || username.length == 0) {
        return NO;
    }

    if (![NSThread isMainThread]) {
        NSString *name = [username copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            s7tv_openViewerCardForUsername(name, sourceView);
        });
        return YES;
    }

    UIView *contextView = sourceView ?: s7tv_activeChatCustomView();
    UIViewController *controller = s7tv_findChannelChatViewController(contextView);
    SEL selector = NSSelectorFromString(
        @"channelChatConnectionController:wantsToShowViewerCardForUser:");
    if (!controller || ![controller respondsToSelector:selector]) return NO;

    typedef void (*S7TVViewerCardCallback)(id, SEL, id, id);
    S7TVViewerCardCallback callback = (S7TVViewerCardCallback)objc_msgSend;
    // Le premier argument objet est conservé par Twitch mais n'est pas lu par
    // le callback reverse-engineeré ; nil suffit donc pour déclencher la carte.
    callback(controller, selector, nil, username);
    return YES;
}
