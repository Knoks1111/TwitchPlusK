#import <UIKit/UIKit.h>
#import "Emote/tpK-emote-image-cache.h"

NS_ASSUME_NONNULL_BEGIN
// Main-thread playback for visible picker animations.
@interface TPKEmoteAnimationEngine : NSObject
+ (instancetype)sharedEngine;
@property (nonatomic) NSInteger maxSimultaneousAnimations;
- (void)registerFrames:(TPKEmoteAnimatedFrames *)frames forKey:(NSString *)key;
- (BOOL)hasFramesForKey:(NSString *)key;
- (BOOL)hasCompleteFramesForKey:(NSString *)key;
- (nullable UIImage *)currentFrameForKey:(NSString *)key;
- (void)addObserver:(id)observer keys:(NSSet<NSString *> *)keys redraw:(void (^)(void))redraw;
- (void)removeObserver:(id)observer;
- (void)clearAllCachedFrames;
@end
NS_ASSUME_NONNULL_END
