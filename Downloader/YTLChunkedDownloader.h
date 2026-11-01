#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Downloads one stream URL to a file using parallel HTTP Range requests.
///
/// googlevideo.com throttles long single requests, so the file is fetched in chunks of a few
/// megabytes (the same strategy yt-dlp uses). Failed chunks are retried; when the server
/// answers 403/410 (expired URL) `URLRefresher` is asked for a fresh URL.
@interface YTLChunkedDownloader : NSObject
- (instancetype)initWithURL:(NSURL *)URL destination:(NSURL *)destination expectedLength:(long long)expectedLength userAgent:(NSString *)userAgent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called on the main queue, at most ~10 times per second.
@property (nonatomic, copy, nullable) void (^progressHandler)(long long receivedBytes, long long totalBytes);
/// Optional. Called on a background queue; call `completion` (from any queue) with a fresh URL or nil.
@property (nonatomic, copy, nullable) void (^URLRefresher)(void (^completion)(NSURL *_Nullable freshURL));

/// `completion` is called once, on the main queue.
- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
