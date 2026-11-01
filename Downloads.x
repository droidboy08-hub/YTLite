#import "YTLite.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "Downloader/YTLDownloadManager.h"

// Entry points for the downloader: a button in the video player overlay and one in the
// Shorts player. The heavy lifting lives in Downloader/ (plain Objective-C).

static const NSInteger kYTLDownloadButtonTag = 0x59544C44; // 'YTLD'

static UIImage *YTLDownloadIcon(CGFloat pointSize) {
    UIImage *image = [UIImage imageNamed:@"yt_outline_download_24pt" inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil];
    if (!image) {
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightMedium];
        image = [UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:configuration];
    }
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Called from layoutSubviews: check the ivar exists first instead of letting KVC throw.
static id YTLIvarValue(id object, NSString *name) {
    if (!object || !class_getInstanceVariable(object_getClass(object), name.UTF8String)) return nil;
    @try {
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Works for the regular player (overlay → YTPlayerView → YTPlayerViewController) and for
// Shorts (overlay → YTReelContentView → YTReelPlayerViewController.player).
static YTPlayerViewController *YTLPlayerForView(UIView *view) {
    Class playerClass = %c(YTPlayerViewController);
    Class reelClass = %c(YTReelPlayerViewController);
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (playerClass && [responder isKindOfClass:playerClass]) return (YTPlayerViewController *)responder;
        if (reelClass && [responder isKindOfClass:reelClass]) {
            YTPlayerViewController *player = ((YTReelPlayerViewController *)responder).player;
            if (player) return player;
        }
    }
    return nil;
}

static id YTLPlayerDataForPlayer(YTPlayerViewController *player) {
    id response = nil;
    SEL contentSelector = NSSelectorFromString(@"contentPlayerResponse");
    if ([player respondsToSelector:contentSelector]) response = ((id (*)(id, SEL))objc_msgSend)(player, contentSelector);
    if (!response) response = player.playerResponse;
    return [response respondsToSelector:@selector(playerData)] ? [response playerData] : nil;
}

static void YTLPresentDownloads(YTPlayerViewController *player, UIView *sender) {
    NSString *videoID = player.contentVideoID;
    SEL currentSelector = NSSelectorFromString(@"currentVideoID");
    if (!videoID.length && [player respondsToSelector:currentSelector]) videoID = ((id (*)(id, SEL))objc_msgSend)(player, currentSelector);
    if (!videoID.length) {
        [[%c(YTToastResponderEvent) eventWithMessage:LOC(@"Downloads.NoFormats") firstResponder:[%c(YTUIUtils) topViewControllerForPresenting]] send];
        return;
    }
    [[YTLDownloadManager sharedManager] presentDownloadOptionsForVideoID:videoID playerResponse:YTLPlayerDataForPlayer(player) fromViewController:player sourceView:sender];
}

static YTQTMButton *YTLMakeDownloadButton(id target, SEL action, CGFloat iconSize) {
    YTQTMButton *button = [%c(YTQTMButton) iconButton];
    button.tag = kYTLDownloadButtonTag;
    button.accessibilityLabel = LOC(@"Download");
    button.tintColor = [UIColor whiteColor];
    button.exclusiveTouch = YES;
    [button setImage:YTLDownloadIcon(iconSize) forState:UIControlStateNormal];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    if ([button respondsToSelector:@selector(enableNewTouchFeedback)]) [button enableNewTouchFeedback];
    return button;
}

// Right-most button of the overlay's top row (settings / overflow), searched recursively
// because YouTube nests those buttons in containers. Faded-out buttons still count: the
// controls are often faded when layout happens, and the anchor must stay put.
static void YTLFindTopRightButton(UIView *view, UIView *overlay, CGFloat maxY, CGRect *best) {
    for (UIView *subview in view.subviews) {
        if (subview.tag == kYTLDownloadButtonTag) continue;
        if ([subview isKindOfClass:%c(YTQTMButton)]) {
            CGRect frame = [subview convertRect:subview.bounds toView:overlay];
            BOOL inTopRow = !CGRectIsEmpty(frame) && CGRectGetMidY(frame) <= maxY;
            if (inTopRow && (CGRectIsNull(*best) || CGRectGetMidX(frame) > CGRectGetMidX(*best))) *best = frame;
        }
        YTLFindTopRightButton(subview, overlay, maxY, best);
    }
}

@interface YTMainAppControlsOverlayView (YTLDownloads)
- (void)ytl_didTapDownloadButton:(UIButton *)sender;
@end

@interface YTReelWatchPlaybackOverlayView (YTLDownloads)
- (void)ytl_didTapShortsDownloadButton:(UIButton *)sender;
@end

%hook YTMainAppControlsOverlayView
- (void)layoutSubviews {
    %orig;

    UIView *button = [self viewWithTag:kYTLDownloadButtonTag];
    if (!ytlBool(@"downloadButton")) {
        [button removeFromSuperview];
        return;
    }

    if (!button) {
        button = YTLMakeDownloadButton(self, @selector(ytl_didTapDownloadButton:), 20);
        SEL visibleSelector = NSSelectorFromString(@"isOverlayVisible");
        if ([self respondsToSelector:visibleSelector]) button.hidden = !((BOOL (*)(id, SEL))objc_msgSend)(self, visibleSelector);
        [self addSubview:button];
    }

    // Directly below the top-right button, so it never collides with the video title.
    CGFloat size = 40;
    CGRect anchor = CGRectNull;
    YTLFindTopRightButton(self, self, CGRectGetHeight(self.bounds) * 0.25, &anchor);
    CGFloat centerX = CGRectIsNull(anchor) ? CGRectGetWidth(self.bounds) - size / 2 - 8 : CGRectGetMidX(anchor);
    CGFloat top = CGRectIsNull(anchor) ? 8 : CGRectGetMaxY(anchor) + 4;
    button.frame = CGRectMake(centerX - size / 2, top, size, size);
    [self bringSubviewToFront:button];
}

- (void)setOverlayVisible:(BOOL)visible {
    %orig;
    [self viewWithTag:kYTLDownloadButtonTag].hidden = !visible;
}

%new
- (void)ytl_didTapDownloadButton:(UIButton *)sender {
    YTPlayerViewController *player = YTLPlayerForView(self) ?: self.playerViewController;
    YTLPresentDownloads(player, sender);
}
%end

%hook YTReelWatchPlaybackOverlayView
- (void)layoutSubviews {
    %orig;

    UIView *button = [self viewWithTag:kYTLDownloadButtonTag];
    UIView *actionBar = YTLIvarValue(self, @"_actionBarComponentView");
    if (!ytlBool(@"shortsDownloadButton") || ![actionBar isKindOfClass:UIView.class] || !actionBar.superview) {
        [button removeFromSuperview];
        return;
    }

    if (!button) {
        button = YTLMakeDownloadButton(self, @selector(ytl_didTapShortsDownloadButton:), 26);
        button.layer.shadowColor = [UIColor blackColor].CGColor;
        button.layer.shadowOpacity = 0.35;
        button.layer.shadowRadius = 3;
        button.layer.shadowOffset = CGSizeZero;
        [self addSubview:button];
    }

    // Above the like/dislike/comment column on the right.
    CGFloat size = 48;
    CGRect bar = [actionBar.superview convertRect:actionBar.frame toView:self];
    button.frame = CGRectMake(CGRectGetMidX(bar) - size / 2, CGRectGetMinY(bar) - size - 8, size, size);
    button.hidden = actionBar.hidden || actionBar.alpha < 0.01;
    [self bringSubviewToFront:button];
}

%new
- (void)ytl_didTapShortsDownloadButton:(UIButton *)sender {
    YTLPresentDownloads(YTLPlayerForView(self), sender);
}
%end

%ctor {
    %init;
    // No download can be running yet: drop work folders left by a killed app.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [YTLDownloadManager removeStaleTemporaryFiles];
    });
}
