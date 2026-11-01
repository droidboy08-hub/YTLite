#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One downloadable stream (a video-only, audio-only or muxed format) of a YouTube video.
@interface YTLMediaFormat : NSObject
@property (nonatomic, assign) NSInteger itag;
@property (nonatomic, strong, nullable) NSURL *URL;
@property (nonatomic, copy) NSString *mimeType;          // e.g. video/mp4; codecs="avc1.640028"
@property (nonatomic, copy) NSString *qualityLabel;      // e.g. 1080p60 (video) or AUDIO_QUALITY_MEDIUM (audio)
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) NSInteger bitrate;
@property (nonatomic, assign) NSInteger audioChannels;
@property (nonatomic, assign) long long contentLength;   // 0 when unknown
@property (nonatomic, assign) long long approxDurationMs;
@property (nonatomic, copy, nullable) NSString *audioTrackID;
@property (nonatomic, copy, nullable) NSString *audioTrackName;
@property (nonatomic, assign) BOOL audioTrackIsDefault;
@property (nonatomic, assign, getter=isDRC) BOOL DRC;     // "stable volume" variant
@property (nonatomic, assign, getter=isMuxed) BOOL muxed; // contains both audio and video

@property (nonatomic, readonly) BOOL isVideo;
@property (nonatomic, readonly) BOOL isAudio;
/// True for MP4/M4A containers, the only ones AVFoundation can remux without FFmpeg.
@property (nonatomic, readonly) BOOL isMP4Container;
/// Human readable codec name: H.264, AV1, VP9, HEVC, AAC, Opus.
@property (nonatomic, readonly) NSString *codecName;
@property (nonatomic, readonly) BOOL isH264;
@property (nonatomic, readonly) BOOL isAV1;
@property (nonatomic, readonly) BOOL isAAC;
@property (nonatomic, readonly) BOOL isHDR;

/// Parses a format dictionary from an InnerTube JSON `/player` response.
+ (nullable instancetype)formatWithJSON:(NSDictionary *)json muxed:(BOOL)muxed;
/// Reads a format from the app's own protobuf `YTIFormatStream` object (accessed dynamically).
+ (nullable instancetype)formatWithFormatStream:(id)stream muxed:(BOOL)muxed;
@end

NS_ASSUME_NONNULL_END
