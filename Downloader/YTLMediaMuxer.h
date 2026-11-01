#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTLMuxCompletion)(NSURL *_Nullable outputURL, NSError *_Nullable error);

/// A running merge/remux; cancelling stops the underlying export.
@interface YTLMuxOperation : NSObject
- (void)cancel;
@end

/// Container work done with AVFoundation only (passthrough, no re-encoding, no FFmpeg).
/// Completion handlers run on a background queue.
@interface YTLMediaMuxer : NSObject
/// Combines a video-only and an audio-only MP4 stream into one file. The result is an .mp4,
/// or a .mov when the MP4 writer refuses the codec; the returned URL has the final extension.
+ (YTLMuxOperation *)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion;
/// Rewrites a DASH (fragmented MP4) audio stream into a regular .m4a file.
+ (YTLMuxOperation *)remuxAudioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion;
@end

NS_ASSUME_NONNULL_END
