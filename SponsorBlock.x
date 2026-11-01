#import "YTLite.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "SponsorBlock/YTLSponsorBlock.h"
#import "SponsorBlock/YTLSponsorPill.h"

// SponsorBlock: skips sponsored segments and other parts of videos submitted by the
// SponsorBlock community (https://sponsor.ajay.app). Segments are fetched when a video starts;
// on every playback-time update YTLSBDecide() (SponsorBlock/YTLSponsorBlockLogic.c) decides
// whether to skip, offer a skip button, or do nothing. Hook points match the ones current
// SponsorBlock implementations use on recent YouTube versions.

static const CFTimeInterval kYTLNoticeDuration = 5.0;
// Right after our own seek the player may still report the old position: don't re-arm then.
static const CFTimeInterval kYTLRearmCooldown = 2.0;

typedef NS_ENUM(NSInteger, YTLPillPurpose) {
    YTLPillPurposeNone,
    YTLPillPurposeOffer,   // "Skip segment" / "Jump to highlight"
    YTLPillPurposeNotice,  // "… has been skipped · Unskip"
};

@interface YTLSponsorBlockState : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSArray <YTLSponsorSegment *> *segments;
@property (nonatomic, strong) NSMutableSet <NSString *> *handled;    // skipped, or skipped by the user
@property (nonatomic, strong) NSMutableSet <NSString *> *unskipped;  // the user chose to watch it
@property (nonatomic, strong) YTLSponsorPill *pill;
@property (nonatomic) YTLPillPurpose pillPurpose;
@property (nonatomic, copy) NSString *pillSegmentUUID;
@property (nonatomic) CFTimeInterval noticeUntil;
@property (nonatomic) CFTimeInterval lastActionAt;
- (void)hidePill;
@end

@implementation YTLSponsorBlockState
- (instancetype)init {
    self = [super init];
    if (self) {
        _handled = [NSMutableSet set];
        _unskipped = [NSMutableSet set];
    }
    return self;
}

- (YTLSponsorPill *)pill {
    if (!_pill) _pill = [YTLSponsorPill new];
    return _pill;
}

- (void)hidePill {
    [_pill hide];
    _pillPurpose = YTLPillPurposeNone;
    _pillSegmentUUID = nil;
    _noticeUntil = 0;
}
@end

#pragma mark - Helpers

static const void *kYTLSponsorStateKey = &kYTLSponsorStateKey;

static YTLSponsorBlockState *YTLExistingSponsorState(YTPlayerViewController *player) {
    return player ? objc_getAssociatedObject(player, kYTLSponsorStateKey) : nil;
}

static YTLSponsorBlockState *YTLSponsorState(YTPlayerViewController *player) {
    YTLSponsorBlockState *state = YTLExistingSponsorState(player);
    if (!state) {
        state = [YTLSponsorBlockState new];
        objc_setAssociatedObject(player, kYTLSponsorStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL YTLPlayerFlag(id player, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [player respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(player, selector);
}

// The regular watch player only: not Shorts, not muted previews in the feed, not during an ad.
static BOOL YTLSponsorBlockApplies(YTPlayerViewController *player) {
    if (![YTLSponsorBlock isEnabled]) return NO;
    Class reelClass = %c(YTReelPlayerViewController);
    if (reelClass && [player.parentViewController isKindOfClass:reelClass]) return NO;
    return !YTLPlayerFlag(player, @"isInlinePlaybackActive") && !YTLPlayerFlag(player, @"isPlayingAd");
}

static void YTLSponsorSeek(YTPlayerViewController *player, double time) {
    for (NSString *name in @[@"seekToTime:", @"scrubToTime:"]) {
        SEL selector = NSSelectorFromString(name);
        if ([player respondsToSelector:selector]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(player, selector, (CGFloat)time);
            return;
        }
    }
}

static NSString *YTLSegmentName(YTLSponsorSegment *segment) {
    YTLSponsorCategory *category = [YTLSponsorCategory categoryWithIdentifier:segment.category];
    return category ? LOC(category.segmentNameKey) : segment.category;
}

static void YTLSponsorShowPill(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLPillPurpose purpose, YTLSponsorSegment *segment, NSString *symbolName, NSString *text, void (^handler)(void)) {
    YTLSponsorPill *pill = state.pill;
    if (state.pillPurpose != purpose || ![state.pillSegmentUUID isEqualToString:segment.UUID] || !pill.isShowing) {
        [pill setSymbolName:symbolName text:text];
        pill.actionHandler = handler;
        state.pillPurpose = purpose;
        state.pillSegmentUUID = segment.UUID;
    }
    if (player.view.window) [pill showInView:player.view];
}

#pragma mark - Actions

static void YTLSponsorShowNotice(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLSponsorSegment *segment, NSString *message, double undoTime) {
    if (!ytlBool(@"sbShowNotifications")) {
        [state hidePill];
        return;
    }
    __weak YTPlayerViewController *weakPlayer = player;
    NSString *text = [NSString stringWithFormat:@"%@ · %@", message, LOC(@"Unskip")];
    YTLSponsorShowPill(player, state, YTLPillPurposeNotice, segment, @"arrow.uturn.backward", text, ^{
        YTPlayerViewController *strongPlayer = weakPlayer;
        YTLSponsorBlockState *current = YTLExistingSponsorState(strongPlayer);
        if (!current) return;
        [current.unskipped addObject:segment.UUID];
        current.lastActionAt = CACurrentMediaTime();
        YTLSponsorSeek(strongPlayer, undoTime);
        [current hidePill];
    });
    state.noticeUntil = CACurrentMediaTime() + kYTLNoticeDuration;
}

static void YTLSponsorSkip(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLSponsorSegment *segment, double duration, BOOL automatic) {
    [state.handled addObject:segment.UUID];
    state.lastActionAt = CACurrentMediaTime();
    YTLSponsorSeek(player, duration > 0 ? MIN(segment.end, duration) : segment.end);
    [YTLSponsorBlock reportSkippedSegment:segment];
    [YTLSponsorBlock playSkipFeedback];

    if (automatic) {
        NSString *message = [NSString stringWithFormat:LOC(@"SegmentSkipped"), YTLSegmentName(segment)];
        YTLSponsorShowNotice(player, state, segment, message, segment.start);
    } else {
        [state hidePill];
    }
}

static void YTLSponsorJumpToHighlight(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLSponsorSegment *segment, double currentTime, BOOL automatic) {
    [state.handled addObject:segment.UUID];
    state.lastActionAt = CACurrentMediaTime();
    YTLSponsorSeek(player, segment.start);
    [YTLSponsorBlock playSkipFeedback];

    if (automatic) {
        NSString *message = [NSString stringWithFormat:LOC(@"SkippedToSegment"), YTLSegmentName(segment)];
        YTLSponsorShowNotice(player, state, segment, message, currentTime);
    } else {
        [state hidePill];
    }
}

static void YTLSponsorOffer(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLSponsorSegment *segment, BOOL highlight, double duration) {
    __weak YTPlayerViewController *weakPlayer = player;
    NSString *symbol = highlight ? @"star.fill" : @"forward.end.fill";
    YTLSponsorShowPill(player, state, YTLPillPurposeOffer, segment, symbol, YTLSegmentName(segment), ^{
        YTPlayerViewController *strongPlayer = weakPlayer;
        YTLSponsorBlockState *current = YTLExistingSponsorState(strongPlayer);
        if (!current) return;
        if (highlight) YTLSponsorJumpToHighlight(strongPlayer, current, segment, 0, NO);
        else YTLSponsorSkip(strongPlayer, current, segment, duration, NO);
    });
}

#pragma mark - Playback

static void YTLSponsorPrepare(YTPlayerViewController *player) {
    NSString *videoID = player.contentVideoID;
    if (videoID.length == 0) return;
    YTLSponsorBlockState *state = YTLSponsorState(player);
    if ([state.videoID isEqualToString:videoID]) return;

    state.videoID = videoID;
    state.segments = nil;
    [state.handled removeAllObjects];
    [state.unskipped removeAllObjects];
    state.lastActionAt = 0;
    [state hidePill];

    __weak YTPlayerViewController *weakPlayer = player;
    [YTLSponsorBlock fetchSegmentsForVideoID:videoID completion:^(NSArray <YTLSponsorSegment *> *segments) {
        YTLSponsorBlockState *current = YTLExistingSponsorState(weakPlayer);
        // Drop answers for a video that is no longer playing.
        if ([current.videoID isEqualToString:videoID]) current.segments = segments;
    }];
}

static void YTLSponsorUpdate(YTPlayerViewController *player, YTSingleVideoController *video, double currentTime) {
    if (!YTLSponsorBlockApplies(player)) {
        [YTLExistingSponsorState(player) hidePill];
        return;
    }

    YTLSponsorPrepare(player);
    YTLSponsorBlockState *state = YTLSponsorState(player);
    NSArray <YTLSponsorSegment *> *segments = state.segments;
    if (segments.count == 0) return;

    CFTimeInterval now = CACurrentMediaTime();
    double duration = video.totalMediaTime;

    // Rewinding before a segment arms it again, so it is skipped again when reached.
    if (now - state.lastActionAt > kYTLRearmCooldown) {
        for (YTLSponsorSegment *segment in segments) {
            if (![segment.actionType isEqualToString:@"poi"] && currentTime < segment.start - 1.0) [state.handled removeObject:segment.UUID];
        }
    }

    NSUInteger count = MIN(segments.count, (NSUInteger)128);
    YTLSBSegment candidates[count];
    for (NSUInteger i = 0; i < count; i++) {
        YTLSponsorSegment *segment = segments[i];
        YTLSponsorCategory *category = [YTLSponsorCategory categoryWithIdentifier:segment.category];
        candidates[i] = (YTLSBSegment){
            .start = segment.start,
            .end = segment.end,
            .videoDuration = segment.videoDuration,
            .mode = category ? category.mode : YTLSBModeOff,
            .isHighlight = [segment.actionType isEqualToString:@"poi"] || category.isHighlight,
            .handled = [state.handled containsObject:segment.UUID],
            .unskipped = [state.unskipped containsObject:segment.UUID],
        };
    }

    YTLSBAction action = YTLSBDecide(candidates, count, currentTime, duration);
    YTLSponsorSegment *segment = action.index >= 0 ? segments[(NSUInteger)action.index] : nil;
    // An "Unskip" notice stays for a few seconds; offers wait until it's gone.
    BOOL noticeVisible = state.pillPurpose == YTLPillPurposeNotice && now < state.noticeUntil;

    switch (action.kind) {
        case YTLSBActionSkip:
            YTLSponsorSkip(player, state, segment, duration, YES);
            break;
        case YTLSBActionJumpToHighlight:
            YTLSponsorJumpToHighlight(player, state, segment, currentTime, YES);
            break;
        case YTLSBActionOfferSkip:
        case YTLSBActionOfferHighlight:
            if (!noticeVisible) YTLSponsorOffer(player, state, segment, action.kind == YTLSBActionOfferHighlight, duration);
            break;
        case YTLSBActionNone:
            if (!noticeVisible) [state hidePill];
            break;
    }
}

%hook YTPlayerViewController
- (void)playbackController:(id)playbackController didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    if (YTLSponsorBlockApplies(self)) YTLSponsorPrepare(self);
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    YTLSponsorUpdate(self, video, time.time);
}

- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    YTLSponsorUpdate(self, video, time.time);
}
%end
