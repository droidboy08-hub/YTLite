#ifndef YTL_SPONSORBLOCK_LOGIC_H
#define YTL_SPONSORBLOCK_LOGIC_H

// Pure C decision core for SponsorBlock: given the segments of the playing video and the
// current playback time, decide what to do. Kept free of UIKit/YouTube types so it can be
// unit-tested on its own.

#include <stdbool.h>
#include <stddef.h>

typedef enum {
    YTLSBModeOff = 0,
    YTLSBModeAsk = 1,   // show a button; for highlights: offer to jump
    YTLSBModeAuto = 2,  // skip automatically; for highlights: jump at the start of the video
} YTLSBMode;

typedef struct {
    double start;
    double end;
    double videoDuration;  // duration the segment was submitted for, 0 if unknown
    YTLSBMode mode;
    bool isHighlight;      // poi_highlight: a single point (start), not a range
    bool handled;          // already skipped / jumped to / skipped by the user
    bool unskipped;        // the user chose to watch it
} YTLSBSegment;

typedef enum {
    YTLSBActionNone = 0,
    YTLSBActionSkip,             // seek to segments[index].end
    YTLSBActionOfferSkip,        // show a "skip" button for segments[index]
    YTLSBActionJumpToHighlight,  // seek to segments[index].start
    YTLSBActionOfferHighlight,   // show a "jump to highlight" button
} YTLSBActionKind;

typedef struct {
    YTLSBActionKind kind;
    long index;  // -1 when kind == YTLSBActionNone
} YTLSBAction;

// Segments shorter than this, or whose end is closer than this, are left alone.
extern const double YTLSBMinimumSegmentLength;
extern const double YTLSBEndGuard;
// Highlights are offered during the first seconds of playback only.
extern const double YTLSBHighlightOfferWindow;
extern const double YTLSBHighlightAutoWindow;
// Segments submitted for a different cut of the video (duration differs by more than this)
// would skip the wrong part, so they are ignored.
extern const double YTLSBDurationTolerance;

bool YTLSBSegmentMatchesVideo(const YTLSBSegment *segment, double videoDuration);
YTLSBAction YTLSBDecide(const YTLSBSegment *segments, size_t count, double currentTime, double videoDuration);

#endif
