#import <UIKit/UIKit.h>

@class TPKEmote;

void tpk_handleChatTrayButtonLifecycle(UIView *view);
void TPKPickerSetup(void);
BOOL TPKPickerChatButtonReady(void);

@interface TPKEmotePickerController : NSObject <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;
- (void)cleanupPickerForStreamClose;
- (void)cleanupPickerForStreamCloseIfOwnedByChatInputView:(UIView *)chatInputView;

@property (nonatomic, strong, readonly) NSArray<TPKEmote *> *emotePickerAllEmotes;
@property (nonatomic, strong, readonly) NSArray<TPKEmote *> *emotePickerGlobalEmotes;

- (CGSize)pickerHostSize;

- (BOOL)pickerHostIsLandscape;

- (void)invalidateSortCache;

- (void)favoritesDidChange;

@end
