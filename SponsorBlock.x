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
// Right after our own seek the player may still report the old position.
static const CFTimeInterval kYTLSeekSettleTime = 2.0;
// A failed lookup (or every category off) is tried again after this long.
static const CFTimeInterval kYTLRetryDelay = 10.0;

typedef NS_ENUM(NSInteger, YTLPillPurpose) {
    YTLPillPurposeNone,
    YTLPillPurposeOffer,   // "Skip segment" / "Jump to highlight"
    YTLPillPurposeNotice,  // "… has been skipped · Unskip"
};

@interface YTLSponsorBlockState : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSArray <YTLSponsorSegment *> *segments;  // nil until loaded
@property (nonatomic) BOOL loading;
@property (nonatomic) CFTimeInterval retryAt;
@property (nonatomic, strong) NSMutableSet <NSString *> *handled;      // skipped, or skipped by the user
@property (nonatomic, strong) NSMutableSet <NSString *> *unskipped;    // the user chose to watch it
@property (nonatomic) double lastTime;
@property (nonatomic) CFTimeInterval lastSeekAt;
@property (nonatomic) double lastSeekTarget;
@property (nonatomic, strong) YTLSponsorPill *pill;
@property (nonatomic) YTLPillPurpose pillPurpose;
@property (nonatomic, copy) NSString *pillSegmentUUID;
@property (nonatomic) CFTimeInterval noticeUntil;
- (void)resetForVideoID:(NSString *)videoID;
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

- (void)resetForVideoID:(NSString *)videoID {
    _videoID = [videoID copy];
    _segments = nil;
    _loading = NO;
    _retryAt = 0;
    _lastTime = 0;
    _lastSeekAt = 0;
    [_handled removeAllObjects];
    [_unskipped removeAllObjects];
    [self hidePill];
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

static id YTLSendIfResponds(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL YTLPlayerFlag(id player, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [player respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(player, selector);
}

// The ID of the video a time update belongs to, so segments are never compared against
// another video's timeline while the player switches videos.
static NSString *YTLVideoIDForSingleVideo(YTSingleVideoController *video) {
    id singleVideo = YTLSendIfResponds(video, @"singleVideo") ?: YTLSendIfResponds(video, @"videoData");
    id videoID = YTLSendIfResponds(singleVideo, @"videoId");
    return [videoID isKindOfClass:NSString.class] && [videoID length] ? videoID : nil;
}

// The regular watch player only: not Shorts, not muted previews in the feed, not during an ad.
static BOOL YTLSponsorBlockApplies(YTPlayerViewController *player) {
    if (![YTLSponsorBlock isEnabled]) return NO;
    Class reelClass = %c(YTReelPlayerViewController);
    if (reelClass && [player.parentViewController isKindOfClass:reelClass]) return NO;
    return !YTLPlayerFlag(player, @"isInlinePlaybackActive") && !YTLPlayerFlag(player, @"isPlayingAd");
}

static void YTLSponsorSeek(YTPlayerViewController *player, YTLSponsorBlockState *state, double time) {
    state.lastSeekAt = CACurrentMediaTime();
    state.lastSeekTarget = time;
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
        YTLSponsorSeek(strongPlayer, current, undoTime);
        [current hidePill];
    });
    state.noticeUntil = CACurrentMediaTime() + kYTLNoticeDuration;

    // Time updates stop when playback stops (paused, or a skip reached the end of the video),
    // so the notice also hides itself.
    __weak YTLSponsorBlockState *weakState = state;
    NSString *UUID = segment.UUID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kYTLNoticeDuration + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTLSponsorBlockState *current = weakState;
        if (current.pillPurpose == YTLPillPurposeNotice && [current.pillSegmentUUID isEqualToString:UUID] && CACurrentMediaTime() >= current.noticeUntil) {
            [current hidePill];
        }
    });
}

static void YTLSponsorSkip(YTPlayerViewController *player, YTLSponsorBlockState *state, YTLSponsorSegment *segment, double duration, BOOL automatic) {
    [state.handled addObject:segment.UUID];
    YTLSponsorSeek(player, state, duration > 0 ? MIN(segment.end, duration) : segment.end);
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
    YTLSponsorSeek(player, state, segment.start);
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

static void YTLSponsorLoadSegments(YTLSponsorBlockState *state, NSString *videoID) {
    if (![state.videoID isEqualToString:videoID]) [state resetForVideoID:videoID];
    if (state.segments || state.loading || CACurrentMediaTime() < state.retryAt) return;

    state.loading = YES;
    __weak YTLSponsorBlockState *weakState = state;
    [YTLSponsorBlock fetchSegmentsForVideoID:videoID completion:^(NSArray <YTLSponsorSegment *> *segments) {
        YTLSponsorBlockState *current = weakState;
        // Drop answers for a video that is no longer playing.
        if (![current.videoID isEqualToString:videoID]) return;
        current.loading = NO;
        if (segments) current.segments = segments;
        else current.retryAt = CACurrentMediaTime() + kYTLRetryDelay;
    }];
}

static void YTLSponsorUpdate(YTPlayerViewController *player, YTSingleVideoController *video, double currentTime) {
    if (!YTLSponsorBlockApplies(player)) {
        [YTLExistingSponsorState(player) hidePill];
        return;
    }

    NSString *videoID = YTLVideoIDForSingleVideo(video) ?: player.contentVideoID;
    if (videoID.length == 0) return;
    YTLSponsorBlockState *state = YTLSponsorState(player);
    YTLSponsorLoadSegments(state, videoID);

    CFTimeInterval now = CACurrentMediaTime();
    BOOL settling = now - state.lastSeekAt < kYTLSeekSettleTime;
    BOOL ownSeek = settling && fabs(currentTime - state.lastSeekTarget) < 1.5;
    // Replay, loop or seeking back to the very start begins a fresh viewing: forget what was
    // skipped or unskipped. Our own "Unskip" seek back to the start doesn't count.
    BOOL restarted = currentTime < 1.0 && state.lastTime > 5.0 && !ownSeek;
    state.lastTime = currentTime;

    NSArray <YTLSponsorSegment *> *segments = state.segments;
    if (segments.count == 0) return;

    if (restarted) {
        [state.handled removeAllObjects];
        [state.unskipped removeAllObjects];
    } else if (!settling) {
        // Rewinding before a segment arms it again, so it is skipped again when reached.
        for (YTLSponsorSegment *segment in segments) {
            if (![segment.actionType isEqualToString:@"poi"] && currentTime < segment.start - 1.0) [state.handled removeObject:segment.UUID];
        }
    }

    double duration = video.totalMediaTime;
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
// A (re)activated video starts fresh: the next time update loads its segments again (from the
// cache when possible) and nothing carries over from a previous viewing.
- (void)playbackController:(id)playbackController didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    [YTLExistingSponsorState(self) resetForVideoID:nil];
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
