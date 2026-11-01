#include "YTLSponsorBlockLogic.h"
#include <math.h>

const double YTLSBMinimumSegmentLength = 0.5;
const double YTLSBEndGuard = 0.5;
const double YTLSBHighlightOfferWindow = 10.0;
const double YTLSBHighlightAutoWindow = 3.0;
const double YTLSBDurationTolerance = 10.0;

bool YTLSBSegmentMatchesVideo(const YTLSBSegment *segment, double videoDuration) {
    if (segment->videoDuration <= 0 || videoDuration <= 0) return true;
    return fabs(segment->videoDuration - videoDuration) <= YTLSBDurationTolerance;
}

static bool YTLSBIsActive(const YTLSBSegment *segment, double videoDuration) {
    return segment->mode != YTLSBModeOff && !segment->handled && !segment->unskipped && YTLSBSegmentMatchesVideo(segment, videoDuration);
}

YTLSBAction YTLSBDecide(const YTLSBSegment *segments, size_t count, double currentTime, double videoDuration) {
    YTLSBAction none = {YTLSBActionNone, -1};
    // `!(x >= 0)` also rejects NaN.
    if (!segments || count == 0 || !(currentTime >= 0)) return none;

    // Ranges first: inside a segment, an auto-skip wins over a skip button; with overlapping
    // segments, the one reaching furthest is used.
    long skipIndex = -1, offerIndex = -1;
    for (size_t i = 0; i < count; i++) {
        const YTLSBSegment *segment = &segments[i];
        if (segment->isHighlight || !YTLSBIsActive(segment, videoDuration)) continue;

        double end = (videoDuration > 0 && segment->end > videoDuration) ? videoDuration : segment->end;
        if (end - segment->start < YTLSBMinimumSegmentLength) continue;
        if (currentTime < segment->start || currentTime >= end - YTLSBEndGuard) continue;

        if (segment->mode == YTLSBModeAuto) {
            if (skipIndex < 0 || segment->end > segments[skipIndex].end) skipIndex = (long)i;
        } else if (offerIndex < 0 || segment->end > segments[offerIndex].end) {
            offerIndex = (long)i;
        }
    }
    if (skipIndex >= 0) return (YTLSBAction){YTLSBActionSkip, skipIndex};
    if (offerIndex >= 0) return (YTLSBAction){YTLSBActionOfferSkip, offerIndex};

    // Highlights: only before the highlight, and only at the beginning of playback.
    for (size_t i = 0; i < count; i++) {
        const YTLSBSegment *segment = &segments[i];
        if (!segment->isHighlight || !YTLSBIsActive(segment, videoDuration)) continue;
        if (videoDuration > 0 && segment->start >= videoDuration) continue;
        if (currentTime >= segment->start - 1.0) continue;

        if (segment->mode == YTLSBModeAuto && currentTime < YTLSBHighlightAutoWindow) return (YTLSBAction){YTLSBActionJumpToHighlight, (long)i};
        if (segment->mode == YTLSBModeAsk && currentTime < YTLSBHighlightOfferWindow) return (YTLSBAction){YTLSBActionOfferHighlight, (long)i};
    }
    return none;
}
