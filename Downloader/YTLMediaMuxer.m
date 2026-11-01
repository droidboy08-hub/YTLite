#import "YTLMediaMuxer.h"
#import "YTLStreamResolver.h"
#import <AVFoundation/AVFoundation.h>

static NSError *YTLMergeError(NSString *reason, NSError *underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = underlying.localizedDescription ?: reason;
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:YTLDownloaderErrorDomain code:YTLDownloaderErrorMerge userInfo:userInfo];
}

static NSError *YTLCancelledError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
}

static NSDictionary *YTLAssetOptions(void) {
    return @{AVURLAssetPreferPreciseDurationAndTimingKey: @YES};
}

@interface YTLMuxOperation ()
- (BOOL)isCancelled;
- (BOOL)attachSession:(AVAssetExportSession *)session;
@end

@implementation YTLMuxOperation {
    AVAssetExportSession *_session;
    BOOL _cancelled;
}

- (BOOL)isCancelled {
    @synchronized (self) {
        return _cancelled;
    }
}

// Returns NO when the operation was cancelled before the export could start.
- (BOOL)attachSession:(AVAssetExportSession *)session {
    @synchronized (self) {
        _session = session;
        return !_cancelled;
    }
}

- (void)cancel {
    AVAssetExportSession *session;
    @synchronized (self) {
        _cancelled = YES;
        session = _session;
    }
    [session cancelExport];
}

@end

@implementation YTLMediaMuxer

// Tries each file type in order; used to fall back from MP4 to QuickTime for codecs the
// MP4 passthrough writer doesn't accept.
+ (void)exportAsset:(AVAsset *)asset outputURL:(NSURL *)outputURL fileTypes:(NSArray <AVFileType> *)fileTypes lastError:(NSError *)lastError operation:(YTLMuxOperation *)operation completion:(YTLMuxCompletion)completion {
    if (operation.isCancelled) {
        completion(nil, YTLCancelledError());
        return;
    }

    AVFileType fileType = fileTypes.firstObject;
    AVAssetExportSession *session = fileType ? [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough] : nil;
    if (!session) {
        completion(nil, YTLMergeError(@"Export failed", lastError));
        return;
    }

    NSArray <AVFileType> *remaining = [fileTypes subarrayWithRange:NSMakeRange(1, fileTypes.count - 1)];
    // Assigning an unsupported outputFileType raises NSInvalidArgumentException.
    if (![session.supportedFileTypes containsObject:fileType]) {
        [self exportAsset:asset outputURL:outputURL fileTypes:remaining lastError:lastError operation:operation completion:completion];
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
    if (![operation attachSession:session]) {
        completion(nil, YTLCancelledError());
        return;
    }

    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status == AVAssetExportSessionStatusCompleted) {
            completion(target, nil);
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:target error:nil];
        if (session.status == AVAssetExportSessionStatusCancelled || operation.isCancelled) {
            completion(nil, YTLCancelledError());
            return;
        }
        [self exportAsset:asset outputURL:outputURL fileTypes:remaining lastError:session.error ?: lastError operation:operation completion:completion];
    }];
}

+ (YTLMuxOperation *)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion {
    YTLMuxOperation *operation = [YTLMuxOperation new];
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

            [self exportAsset:composition outputURL:outputURL fileTypes:@[AVFileTypeMPEG4, AVFileTypeQuickTimeMovie] lastError:nil operation:operation completion:completion];
        }];
    }];
    return operation;
}

+ (YTLMuxOperation *)remuxAudioURL:(NSURL *)audioURL outputURL:(NSURL *)outputURL completion:(YTLMuxCompletion)completion {
    YTLMuxOperation *operation = [YTLMuxOperation new];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:audioURL options:YTLAssetOptions()];
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        if ([asset tracksWithMediaType:AVMediaTypeAudio].count == 0) {
            completion(nil, YTLMergeError(@"The downloaded audio could not be read", nil));
            return;
        }
        [self exportAsset:asset outputURL:outputURL fileTypes:@[AVFileTypeAppleM4A] lastError:nil operation:operation completion:completion];
    }];
    return operation;
}

@end
