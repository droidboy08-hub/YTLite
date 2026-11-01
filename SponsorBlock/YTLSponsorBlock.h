#import <Foundation/Foundation.h>
#import "YTLSponsorBlockLogic.h"

NS_ASSUME_NONNULL_BEGIN

/// A SponsorBlock category and its user setting (Off / Ask / Auto-skip).
@interface YTLSponsorCategory : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;      // API name, e.g. "sponsor"
@property (nonatomic, readonly, copy) NSString *titleKey;        // localization key; "<key>Desc" is the description
@property (nonatomic, readonly, copy) NSString *segmentNameKey;  // localization key used in notices, e.g. "sb_sponsor"
@property (nonatomic, readonly) BOOL isHighlight;                // poi_highlight: a point to jump to, not a range
@property (nonatomic, readonly) YTLSBMode defaultMode;
/// Reads and writes the preference (falls back to `defaultMode`).
@property (nonatomic) YTLSBMode mode;

+ (NSArray <YTLSponsorCategory *> *)allCategories;
+ (nullable YTLSponsorCategory *)categoryWithIdentifier:(NSString *)identifier;
@end

/// One segment returned by the SponsorBlock API.
@interface YTLSponsorSegment : NSObject
@property (nonatomic, copy) NSString *UUID;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *actionType;
@property (nonatomic) double start;
@property (nonatomic) double end;
@property (nonatomic) double videoDuration;
@end

/// Client for the SponsorBlock API (https://sponsor.ajay.app).
///
/// Lookups use the privacy-preserving hash-prefix endpoint: only the first 4 hex characters
/// of SHA-256(videoID) are sent, so the server can't tell which video is being watched.
@interface YTLSponsorBlock : NSObject
+ (BOOL)isEnabled;
/// Segments of every supported category for `videoID`: an empty array when there are none,
/// nil when the lookup failed or every category is off (try again later). Completion runs on
/// the main queue; successful answers are cached for the session.
+ (void)fetchSegmentsForVideoID:(NSString *)videoID completion:(void (^)(NSArray <YTLSponsorSegment *> *_Nullable segments))completion;
/// Counts a skip for the segment's submitters (SponsorBlock's view counter) when the user
/// allowed it: the segment ID tells the server which video was watched. Fire and forget.
+ (void)reportSkippedSegment:(YTLSponsorSegment *)segment;
/// Optional sound / haptic after a skip.
+ (void)playSkipFeedback;
@end

NS_ASSUME_NONNULL_END
