#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Rounded button shown in the bottom-right corner of the video player for SponsorBlock
/// actions ("Skip …", "Highlight", "… has been skipped · Unskip").
@interface YTLSponsorPill : UIControl
@property (nonatomic, copy, nullable) void (^actionHandler)(void);
@property (nonatomic, readonly, getter=isShowing) BOOL showing;
- (void)setSymbolName:(NSString *)symbolName text:(NSString *)text;
/// Adds the pill to `container` (or moves it there) and fades it in. It stays anchored to
/// the bottom-right corner when the player resizes, and hides itself in very small players.
- (void)showInView:(UIView *)container;
- (void)hide;
@end

NS_ASSUME_NONNULL_END
