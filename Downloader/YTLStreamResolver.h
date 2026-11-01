#import <Foundation/Foundation.h>
#import "YTLMediaFormat.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const YTLDownloaderErrorDomain;

typedef NS_ERROR_ENUM(YTLDownloaderErrorDomain, YTLDownloaderError) {
    YTLDownloaderErrorNoFormats = 1,   // nothing downloadable (SABR-only, unplayable, …)
    YTLDownloaderErrorUnplayable = 2,  // playability status was not OK; message carries YouTube's reason
    YTLDownloaderErrorLive = 3,        // live streams / premieres can't be downloaded
    YTLDownloaderErrorHTTP = 4,
    YTLDownloaderErrorMerge = 5,
    YTLDownloaderErrorNoSpace = 6,
    YTLDownloaderErrorFile = 7,
};

/// Everything needed to download one video.
@interface YTLStreamInfo : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSURL *thumbnailURL;
@property (nonatomic, assign) NSTimeInterval duration;
/// Only formats that carry a direct URL.
@property (nonatomic, copy) NSArray <YTLMediaFormat *> *formats;
/// Where the URLs came from: an InnerTube client profile name, or "APP" for the app's own response.
@property (nonatomic, copy) NSString *source;
/// User-Agent that must accompany media requests for these URLs.
@property (nonatomic, copy) NSString *userAgent;
@end

/// Finds directly downloadable stream URLs for a video.
///
/// Since YouTube moved its own iOS/Android clients to SABR (server-side adaptive bitrate),
/// the player response the app receives has no per-format URLs anymore. The resolver therefore
/// asks InnerTube for the same video with client profiles that still receive plain URLs
/// without a proof-of-origin token, and falls back to the app's own response when it does
/// carry URLs (older YouTube versions). See docs/Research.md for background.
@interface YTLStreamResolver : NSObject
/// `playerResponse` is the app's YTIPlayerResponse for the video (optional). Completion runs on the main queue.
+ (void)resolveVideoID:(NSString *)videoID playerResponse:(nullable id)playerResponse completion:(void (^)(YTLStreamInfo *_Nullable info, NSError *_Nullable error))completion;
/// Re-resolves with the same source and returns a fresh URL for `format` (URLs expire after a few hours). Completion runs on a background queue.
+ (void)refreshURLForFormat:(YTLMediaFormat *)format info:(YTLStreamInfo *)info completion:(void (^)(NSURL *_Nullable URL))completion;
@end

NS_ASSUME_NONNULL_END
