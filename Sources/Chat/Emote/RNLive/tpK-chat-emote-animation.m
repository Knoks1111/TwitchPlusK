#import "Chat/Emote/tpK-chat-emotes.h"
#import "Core/tpK-core-manager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface TPKNativeAnimatedView : UIImageView
@property (nonatomic) NSUInteger currentFrameIndex;
@property (nonatomic) NSTimeInterval currentTime;
@property (nonatomic, strong) UIImage *currentFrame;
@property (nonatomic, strong) UIImage *animatedImage;
- (void)start;
- (void)stop;
- (void)displayDidRefresh:(CADisplayLink *)link;
- (BOOL)paused;
@end

@class TPKChatAnimationGroup;
static void Reconcile(TPKChatAnimationGroup *group);
@interface TPKChatAnimationMember : NSObject
@property (nonatomic, weak) TPKNativeAnimatedView *view;
@property (nonatomic, strong) TPKChatAnimationGroup *group;
@property (nonatomic) BOOL wantsAnimation;
@property (nonatomic, copy) NSString *identity;
@end
@implementation TPKChatAnimationMember
- (void)dealloc {
    TPKChatAnimationGroup *group = _group;
    dispatch_async(dispatch_get_main_queue(), ^{ Reconcile(group); });
}
@end

@protocol TPKNativeAnimationFrames <NSObject>
- (NSUInteger)animatedImageFrameCount;
- (NSUInteger)animatedImageLoopCount;
@end

@interface TPKChatAnimationGroup : NSObject
@property (nonatomic, strong) NSHashTable<TPKChatAnimationMember *> *members;
@property (nonatomic, weak) TPKChatAnimationMember *leader;
@property (nonatomic, strong) UIImage *frame;
@property (nonatomic) NSUInteger index;
@property (nonatomic) NSTimeInterval time;
@property (nonatomic) NSUInteger frameCount;
@end
@implementation TPKChatAnimationGroup
- (instancetype)init {
    if ((self = [super init])) _members = [NSHashTable weakObjectsHashTable];
    return self;
}
@end

static char memberKey, awaitingImageKey;
static NSMapTable<NSString *, TPKChatAnimationGroup *> *groups;
static void (*nativeSetImage)(id, SEL, UIImage *);
static void (*nativeStart)(id, SEL);
static void (*nativeStop)(id, SEL);
static void (*nativeRefresh)(id, SEL, CADisplayLink *);
static void (*nativeWindow)(id, SEL);
static void (*setStillFrame)(id, SEL, UIImage *);
static void (*nativeIdentifier)(id, SEL, NSString *);
static Class animatedViewClass;

static BOOL Active(TPKChatAnimationMember *member) {
    TPKNativeAnimatedView *view = member.view;
    return member.wantsAnimation && view.window;
}

static void CopyFrame(TPKChatAnimationGroup *group, TPKNativeAnimatedView *view) {
    if (group.frame && view.image != group.frame)
        setStillFrame(view, @selector(setImage:), group.frame);
}

static void Remember(TPKChatAnimationGroup *group, TPKNativeAnimatedView *view) {
    group.frame = view.currentFrame;
    group.index = view.currentFrameIndex;
    group.time = view.currentTime;
}

static void Reconcile(TPKChatAnimationGroup *group) {
    TPKChatAnimationMember *leader = group.leader;
    if (leader && Active(leader)) return;
    if (leader.view) {
        Remember(group, leader.view);
        nativeStop(leader.view, @selector(stop));
    }
    group.leader = nil;
    for (TPKChatAnimationMember *candidate in group.members) {
        if (!Active(candidate)) continue;
        TPKNativeAnimatedView *view = candidate.view;
        group.leader = candidate;
        if (group.frame) {
            view.currentFrameIndex = group.index;
            view.currentTime = group.time;
            view.currentFrame = group.frame;
            CopyFrame(group, view);
        }
        nativeStart(view, @selector(start));
        break;
    }
}

static void Leave(TPKNativeAnimatedView *view) {
    TPKChatAnimationMember *member = objc_getAssociatedObject(view, &memberKey);
    if (!member) return;
    TPKChatAnimationGroup *group = member.group;
    member.wantsAnimation = NO;
    [group.members removeObject:member];
    Reconcile(group);
    objc_setAssociatedObject(view, &memberKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ImageIdentity(UIView *view) {
    // Fabric's animated UIImageView is inside the image component carrying testID.
    for (NSUInteger depth = 0; view && depth < 3; ++depth, view = view.superview) {
        NSString *identifier = view.accessibilityIdentifier;
        if (![identifier hasPrefix:@"chat-emote-tpk_"] || identifier.length > 1500) continue;
        return [identifier substringFromIndex:@"chat-emote-".length];
    }
    return nil;
}

static void Join(TPKNativeAnimatedView *view) {
    if (objc_getAssociatedObject(view, &memberKey) || objc_getAssociatedObject(view, &awaitingImageKey)) return;
    NSString *identity = ImageIdentity(view);
    id<TPKNativeAnimationFrames> image = (id)view.animatedImage;
    if (!identity || ![image respondsToSelector:@selector(animatedImageFrameCount)] ||
        ![image respondsToSelector:@selector(animatedImageLoopCount)] ||
        image.animatedImageFrameCount < 2 || image.animatedImageLoopCount != 0) return;
    TPKChatAnimationGroup *group = [groups objectForKey:identity];
    if (!group) {
        if (groups.count >= 256) {
            for (NSString *key in groups.keyEnumerator.allObjects)
                if (![groups objectForKey:key]) [groups removeObjectForKey:key];
        }
        if (groups.count >= 256) return;
        group = [TPKChatAnimationGroup new];
        group.frameCount = image.animatedImageFrameCount;
        [groups setObject:group forKey:identity];
    }
    if (group.frameCount != image.animatedImageFrameCount || group.members.count >= 256) return;
    TPKChatAnimationMember *member = [TPKChatAnimationMember new];
    member.view = view;
    member.group = group;
    member.wantsAnimation = !view.paused;
    member.identity = identity;
    [group.members addObject:member];
    objc_setAssociatedObject(view, &memberKey, member, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nativeStop(view, @selector(stop));
    Reconcile(group);
    if (group.leader != member) CopyFrame(group, view);
    static BOOL logged;
    TPKManager *manager = TPKManager.sharedManager;
    if (!logged && manager.logsEnabled && manager.logChat) {
        logged = YES;
        [manager log:@"[Chat] 🧪 Native animation: custom emote attached"];
    }
}

static void SetImage(TPKNativeAnimatedView *view, SEL selector, UIImage *image) {
    if (!NSThread.isMainThread) { nativeSetImage(view, selector, image); return; }
    TPKChatAnimationMember *member = objc_getAssociatedObject(view, &memberKey);
    if (member && image == view.animatedImage) { nativeSetImage(view, selector, image); return; }
    Leave(view);
    nativeSetImage(view, selector, image);
    objc_setAssociatedObject(view, &awaitingImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Join(view);
}

static void Start(TPKNativeAnimatedView *view, SEL selector) {
    TPKChatAnimationMember *member = NSThread.isMainThread ? objc_getAssociatedObject(view, &memberKey) : nil;
    if (!member) { nativeStart(view, selector); return; }
    member.wantsAnimation = YES;
    Reconcile(member.group);
    if (member.group.leader == member) nativeStart(view, selector);
    else CopyFrame(member.group, view);
}

static void Stop(TPKNativeAnimatedView *view, SEL selector) {
    TPKChatAnimationMember *member = NSThread.isMainThread ? objc_getAssociatedObject(view, &memberKey) : nil;
    nativeStop(view, selector);
    if (!member) return;
    member.wantsAnimation = NO;
    Reconcile(member.group);
}

static void Refresh(TPKNativeAnimatedView *view, SEL selector, CADisplayLink *link) {
    TPKChatAnimationMember *member = objc_getAssociatedObject(view, &memberKey);
    if (!member || !NSThread.isMainThread) { nativeRefresh(view, selector, link); return; }
    TPKChatAnimationGroup *group = member.group;
    Reconcile(group);
    if (group.leader != member) return;
    UIImage *previous = group.frame;
    nativeRefresh(view, selector, link);
    if (group.leader != member) return;
    Remember(group, view);
    if (group.frame == previous) return;
    for (TPKChatAnimationMember *follower in group.members)
        if (follower != member && Active(follower)) CopyFrame(group, follower.view);
}

static void Window(TPKNativeAnimatedView *view, SEL selector) {
    nativeWindow(view, selector);
    if (!NSThread.isMainThread) return;
    Join(view);
    TPKChatAnimationMember *member = objc_getAssociatedObject(view, &memberKey);
    if (member) Reconcile(member.group);
}

static void Identifier(UIView *component, SEL selector, NSString *identifier) {
    NSString *previous = component.accessibilityIdentifier;
    nativeIdentifier(component, selector, identifier);
    if (!NSThread.isMainThread) return;
    for (TPKNativeAnimatedView *view in component.subviews) {
        if (![view isKindOfClass:animatedViewClass]) continue;
        TPKChatAnimationMember *member = objc_getAssociatedObject(view, &memberKey);
        if (member && [member.identity isEqualToString:ImageIdentity(view)]) continue;
        // A recycled component can still display the previous source while its new image loads.
        if (previous.length && ![previous isEqualToString:identifier])
            objc_setAssociatedObject(view, &awaitingImageKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (member) {
            BOOL resume = member.wantsAnimation;
            Leave(view);
            if (resume) nativeStart(view, @selector(start));
        }
        Join(view);
    }
}

void TPKChatEmoteAnimationSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"RCTUIImageViewAnimated");
        Class component = NSClassFromString(@"RCTImageComponentView");
        Method identifier = class_getInstanceMethod(component, @selector(setAccessibilityIdentifier:));
        if (!identifier) return;
        SEL selectors[] = {@selector(setImage:), @selector(start), @selector(stop),
            @selector(displayDidRefresh:), @selector(didMoveToWindow), @selector(animatedImage),
            @selector(currentFrame), @selector(currentFrameIndex), @selector(currentTime),
            @selector(setCurrentFrame:), @selector(setCurrentFrameIndex:), @selector(setCurrentTime:), @selector(paused)};
        for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(*selectors); ++i)
            if (!class_getInstanceMethod(cls, selectors[i])) return;
        groups = [NSMapTable strongToWeakObjectsMapTable];
        animatedViewClass = cls;
        setStillFrame = (void *)class_getMethodImplementation(UIImageView.class, @selector(setImage:));
        nativeSetImage = (void *)method_setImplementation(class_getInstanceMethod(cls, selectors[0]), (IMP)SetImage);
        nativeStart = (void *)method_setImplementation(class_getInstanceMethod(cls, selectors[1]), (IMP)Start);
        nativeStop = (void *)method_setImplementation(class_getInstanceMethod(cls, selectors[2]), (IMP)Stop);
        nativeRefresh = (void *)method_setImplementation(class_getInstanceMethod(cls, selectors[3]), (IMP)Refresh);
        Method window = class_getInstanceMethod(cls, @selector(didMoveToWindow));
        nativeWindow = (void *)method_getImplementation(window);
        if (!class_addMethod(cls, @selector(didMoveToWindow), (IMP)Window, method_getTypeEncoding(window)))
            method_setImplementation(window, (IMP)Window);
        nativeIdentifier = (void *)method_getImplementation(identifier);
        if (!class_addMethod(component, @selector(setAccessibilityIdentifier:), (IMP)Identifier, method_getTypeEncoding(identifier)))
            method_setImplementation(identifier, (IMP)Identifier);
    });
}
