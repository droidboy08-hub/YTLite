#import "YTLMediaMuxer.h"
#import "YTLStreamResolver.h"
#import <AVFoundation/AVFoundation.h>

static NSError *YTLMergeError(NSString *reason, NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = underlying.localizedDescription ?: reason;
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:YTLDownloaderErrorDomain code:YTLDownloaderErrorMerge userInfo:userInfo];
}

static NSDictionary *YTLAssetOptions(void) {
    return @{AVURLAssetPreferPreciseDurationAndTimingKey: @YES};
}

@implementation YTLMediaMuxer

// Tries each file type in order; used to fall back from MP4 to QuickTime for codecs the
// MP4 passthrough writer doesn't accept.
+ (void)exportAsset:(AVAsset *)asset outputURL:(NSURL *)outputURL fileTypes:(NSArray <AVFileType> *)fileTypes lastError:(NSError *)lastError completion:(YTLMuxCompletion)completion {
    AVFileType fileType = fileTypes.firstObject;
    AVAssetExportSession *session = fileType ? [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough] : nil;
    if (!session) {
        completion(nil, YTLMergeError(@"Export failed", lastError));
        return;
    }

    NSURL *target = outputURL;
    if ([fileType isEqualToString:AVFileTypeQuickTimeMovie]) {
        target = [[outputURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"mov"];
    }
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];

    session.outputURL = target;
    session.outputFileType = fileType;
    session.shouldOptimizeForNetworkUse = YES;

    NSArray <AVFileType> *remaining = [fileTypes subarrayWithRange:NSMakeRange(1, fileTypes.count - 1)];
    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status == AVAssetExportSessionStatusCompleted) {
            completion(target, nil);
        } else {
            [NSFileManager.defaultManager removeItemAtURL:target error:nil];
            [self exportAsset:asset outputURL:outputURL fileTypes:remaining lastError:session.error ?: lastError completion:completion];
        }
    }];
}

+ (void)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion {
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:YTLAssetOptions()];
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioURL options:YTLAssetOptions()];

    [videoAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        [audioAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
            AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            if (!videoTrack || !audioTrack) {
                completion(nil, YTLMergeError(@"The downloaded streams could not be read", nil));
                return;
            }

            AVMutableComposition *composition = [AVMutableComposition composition];
            AVMutableCompositionTrack *compositionVideo = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            AVMutableCompositionTrack *compositionAudio = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];

            CMTimeRange videoRange = videoTrack.timeRange;
            CMTimeRange audioRange = audioTrack.timeRange;
            // DASH audio usually runs a few milliseconds past the video; keep them aligned.
            if (CMTIME_IS_NUMERIC(videoRange.duration) && CMTimeCompare(audioRange.duration, videoRange.duration) > 0) {
                audioRange.duration = videoRange.duration;
            }

            NSError *error = nil;
            BOOL inserted = [compositionVideo insertTimeRange:videoRange ofTrack:videoTrack atTime:kCMTimeZero error:&error]
                         && [compositionAudio insertTimeRange:audioRange ofTrack:audioTrack atTime:kCMTimeZero error:&error];
            if (!inserted) {
                completion(nil, YTLMergeError(@"Merge failed", error));
                return;
            }
            compositionVideo.preferredTransform = videoTrack.preferredTransform;

            [self exportAsset:composition outputURL:outputURL fileTypes:@[AVFileTypeMPEG4, AVFileTypeQuickTimeMovie] lastError:nil completion:completion];
        }];
    }];
}

+ (void)remuxAudioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:audioURL options:YTLAssetOptions()];
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        if ([asset tracksWithMediaType:AVMediaTypeAudio].count == 0) {
            completion(nil, YTLMergeError(@"The downloaded audio could not be read", nil));
            return;
        }
        [self exportAsset:asset outputURL:outputURL fileTypes:@[AVFileTypeAppleM4A] lastError:nil completion:completion];
    }];
}

@end
