#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Small progress card shown at the bottom of the screen while a download runs.
/// It lives in its own pass-through window so YouTube's sheets and players never cover it.
@interface YTLDownloadHUD : NSObject
+ (instancetype)sharedHUD;
/// Shows the card. A cancel button is displayed when `cancelHandler` is set.
- (void)showWithTitle:(NSString *)title cancelHandler:(nullable void (^)(void))cancelHandler;
/// `progress` in 0…1; pass a negative value for an indeterminate spinner.
- (void)updateTitle:(nullable NSString *)title detail:(nullable NSString *)detail progress:(float)progress;
/// Shows a short message that disappears by itself.
- (void)flashMessage:(NSString *)message;
- (void)dismiss;
@end

NS_ASSUME_NONNULL_END
