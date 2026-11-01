#import "YTLDownloadManager.h"
#import "YTLStreamResolver.h"
#import "YTLChunkedDownloader.h"
#import "YTLMediaMuxer.h"
#import "YTLDownloadHUD.h"
#import "../Utils/YTLUserDefaults.h"
#import "../Utils/NSBundle+YTLite.h"
#import <AVKit/AVKit.h>
#import <Photos/Photos.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>

static NSString *const kYTLSaveActionKey = @"downloadSaveAction";

@interface YTLDownloadOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong, nullable) YTLMediaFormat *video;
@property (nonatomic, strong, nullable) YTLMediaFormat *audio;
@end

@implementation YTLDownloadOption
@end

#pragma mark - UI helpers

static UIWindow *YTLKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIViewController *YTLTopViewController(void) {
    Class utils = NSClassFromString(@"YTUIUtils");
    SEL selector = NSSelectorFromString(@"topViewControllerForPresenting");
    if ([utils respondsToSelector:selector]) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(utils, selector);
        if ([controller isKindOfClass:UIViewController.class]) return controller;
    }

    UIViewController *controller = YTLKeyWindow().rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

// Uses YouTube's own snackbar when available.
static void YTLShowToast(NSString *message) {
    Class eventClass = NSClassFromString(@"YTToastResponderEvent");
    SEL eventSelector = NSSelectorFromString(@"eventWithMessage:firstResponder:");
    SEL sendSelector = NSSelectorFromString(@"send");
    UIViewController *responder = YTLTopViewController();
    if (responder && [eventClass respondsToSelector:eventSelector]) {
        id event = ((id (*)(id, SEL, NSString *, id))objc_msgSend)(eventClass, eventSelector, message, responder);
        if ([event respondsToSelector:sendSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(event, sendSelector);
            return;
        }
    }
    [[YTLDownloadHUD sharedHUD] flashMessage:message];
}

static void YTLConfigurePopover(UIViewController *controller, UIViewController *host, UIView *sourceView) {
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    if (!popover) return;
    if (sourceView.window) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    } else {
        popover.sourceView = host.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
}

static void YTLPresent(UIViewController *controller, UIView *sourceView) {
    UIViewController *host = YTLTopViewController();
    YTLConfigurePopover(controller, host, sourceView);
    [host presentViewController:controller animated:YES completion:nil];
}

static void YTLShowAlert(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"Done") style:UIAlertActionStyleCancel handler:nil]];
    YTLPresent(alert, nil);
}

static NSString *YTLMessageForError(NSError *error) {
    if ([error.domain isEqualToString:YTLDownloaderErrorDomain]) {
        if (error.code == YTLDownloaderErrorLive) return LOC(@"Error.TryLater");
        if (error.code == YTLDownloaderErrorNoFormats) return LOC(@"Downloads.NoFormats");
    }
    return error.localizedDescription ?: LOC(@"Error");
}

#pragma mark - Photos

static void YTLRequestPhotosAccess(void (^completion)(void)) {
    void (^handler)(PHAuthorizationStatus) = ^(PHAuthorizationStatus status) {
        // Whatever the answer, try: Photos returns a descriptive error when access is denied.
        dispatch_async(dispatch_get_main_queue(), completion);
    };
    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:handler];
    } else {
        [PHPhotoLibrary requestAuthorization:handler];
    }
}

static void YTLFinishPhotosChange(BOOL success, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (success) YTLShowToast(LOC(@"Saved"));
        else YTLShowAlert(LOC(@"Error"), error.localizedDescription ?: LOC(@"Error"));
    });
}

#pragma mark - Formats

static BOOL YTLDeviceSupportsAV1(void) {
    // AV1 only plays (and is only offered) on devices with a hardware decoder (A17 Pro / M3 and later).
    if (@available(iOS 17.0, *)) return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    return NO;
}

// H.264 is preferred whenever it exists: it plays everywhere and can be saved to Photos.
static NSInteger YTLVideoRank(YTLMediaFormat *format) {
    return format.isH264 ? 2 : 1;
}

static NSString *YTLSizeSuffix(long long bytes) {
    return bytes > 0 ? [@" · " stringByAppendingString:[YTLDownloadManager formattedSize:(unsigned long long)bytes]] : @"";
}

static NSString *YTLSanitizedFileName(NSString *title) {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r\t"];
    NSString *clean = [[title componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length > 120) clean = [clean substringWithRange:[clean rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 120)]];
    if ([clean hasPrefix:@"."]) clean = [@"_" stringByAppendingString:clean];
    return clean.length ? clean : @"YouTube";
}

@implementation YTLDownloadManager {
    YTLChunkedDownloader *_currentDownloader;
    NSURL *_workDirectory;
    NSUInteger _jobID;
    BOOL _cancelled;
    UIBackgroundTaskIdentifier _backgroundTask;
}

+ (instancetype)sharedManager {
    static YTLDownloadManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [YTLDownloadManager new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) _backgroundTask = UIBackgroundTaskInvalid;
    return self;
}

#pragma mark - Options

// AAC in MP4 only (Opus/WebM would need FFmpeg). Default track, stereo and higher bitrate first.
- (NSArray <YTLMediaFormat *> *)audioFormatsForInfo:(YTLStreamInfo *)info {
    NSMutableArray <YTLMediaFormat *> *audios = [NSMutableArray array];
    for (YTLMediaFormat *format in info.formats) {
        if (format.isAudio && !format.isMuxed && format.isMP4Container && format.isAAC) [audios addObject:format];
    }

    // Drop "stable volume" duplicates when the regular variant exists.
    NSMutableArray <YTLMediaFormat *> *filtered = [NSMutableArray array];
    for (YTLMediaFormat *format in audios) {
        BOOL hasRegular = NO;
        if (format.isDRC) {
            for (YTLMediaFormat *other in audios) {
                BOOL sameTrack = (!format.audioTrackID && !other.audioTrackID) || [other.audioTrackID isEqualToString:format.audioTrackID];
                if (!other.isDRC && other.itag == format.itag && sameTrack) hasRegular = YES;
            }
        }
        if (!hasRegular) [filtered addObject:format];
    }

    [filtered sortUsingComparator:^NSComparisonResult(YTLMediaFormat *a, YTLMediaFormat *b) {
        BOOL aDefault = a.audioTrackIsDefault || !a.audioTrackID, bDefault = b.audioTrackIsDefault || !b.audioTrackID;
        if (aDefault != bDefault) return aDefault ? NSOrderedAscending : NSOrderedDescending;
        BOOL aStereo = a.audioChannels <= 2, bStereo = b.audioChannels <= 2;
        if (aStereo != bStereo) return aStereo ? NSOrderedAscending : NSOrderedDescending;
        if (a.bitrate != b.bitrate) return a.bitrate > b.bitrate ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return filtered;
}

- (NSArray <YTLDownloadOption *> *)optionsForInfo:(YTLStreamInfo *)info {
    NSMutableArray <YTLDownloadOption *> *options = [NSMutableArray array];
    NSArray <YTLMediaFormat *> *audios = [self audioFormatsForInfo:info];
    YTLMediaFormat *mergeAudio = audios.firstObject;

    // Video-only DASH streams, one per quality label, merged with the best audio track.
    BOOL allowAV1 = YTLDeviceSupportsAV1();
    NSMutableDictionary <NSString *, YTLMediaFormat *> *byLabel = [NSMutableDictionary dictionary];
    for (YTLMediaFormat *format in info.formats) {
        if (!format.isVideo || format.isMuxed || !format.isMP4Container || format.isHDR) continue;
        if (!format.isH264 && !(format.isAV1 && allowAV1)) continue;
        NSString *label = format.qualityLabel.length ? format.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)format.height];
        YTLMediaFormat *current = byLabel[label];
        if (!current || YTLVideoRank(format) > YTLVideoRank(current) || (YTLVideoRank(format) == YTLVideoRank(current) && format.bitrate > current.bitrate)) {
            byLabel[label] = format;
        }
    }
    NSArray <YTLMediaFormat *> *videos = [byLabel.allValues sortedArrayUsingComparator:^NSComparisonResult(YTLMediaFormat *a, YTLMediaFormat *b) {
        if (a.height != b.height) return a.height > b.height ? NSOrderedAscending : NSOrderedDescending;
        if (a.fps != b.fps) return a.fps > b.fps ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (mergeAudio) {
        for (YTLMediaFormat *video in videos) {
            YTLDownloadOption *option = [YTLDownloadOption new];
            option.video = video;
            option.audio = mergeAudio;
            long long size = video.contentLength > 0 && mergeAudio.contentLength > 0 ? video.contentLength + mergeAudio.contentLength : 0;
            NSString *label = video.qualityLabel.length ? video.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)video.height];
            option.title = [NSString stringWithFormat:@"%@ · %@%@", label, video.codecName, YTLSizeSuffix(size)];
            [options addObject:option];
        }
    }

    // Progressive MP4 (video + audio in one file) when no DASH pair can be built.
    if (options.count == 0) {
        for (YTLMediaFormat *format in info.formats) {
            if (!format.isMuxed || !format.isMP4Container || !format.isH264) continue;
            YTLDownloadOption *option = [YTLDownloadOption new];
            option.video = format;
            NSString *label = format.qualityLabel.length ? format.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)format.height];
            option.title = [NSString stringWithFormat:@"%@ · %@%@", label, format.codecName, YTLSizeSuffix(format.contentLength)];
            [options addObject:option];
        }
    }

    // Audio only: one entry per audio track (dubbed videos have several languages).
    NSMutableSet <NSString *> *seenTracks = [NSMutableSet set];
    NSMutableArray <YTLMediaFormat *> *trackAudios = [NSMutableArray array];
    for (YTLMediaFormat *format in audios) {
        NSString *track = format.audioTrackID ?: @"";
        if ([seenTracks containsObject:track]) continue;
        [seenTracks addObject:track];
        [trackAudios addObject:format];
    }
    for (YTLMediaFormat *audio in trackAudios) {
        YTLDownloadOption *option = [YTLDownloadOption new];
        option.audio = audio;
        NSString *detail = trackAudios.count > 1 && audio.audioTrackName ? audio.audioTrackName : [NSString stringWithFormat:@"AAC %ld kbps", (long)lround(audio.bitrate / 1000.0)];
        option.title = [NSString stringWithFormat:@"%@ · %@%@", LOC(@"AudioOnly"), detail, YTLSizeSuffix(audio.contentLength)];
        [options addObject:option];
    }

    return options;
}

#pragma mark - Flow

- (void)presentDownloadOptionsForVideoID:(NSString *)videoID playerResponse:(id)playerResponse fromViewController:(UIViewController *)presenter sourceView:(UIView *)sourceView {
    if (videoID.length == 0) return;
    if (_busy) {
        YTLShowToast(LOC(@"Error.Multidownloading"));
        return;
    }

    _busy = YES;
    _cancelled = NO;
    NSUInteger jobID = ++_jobID;
    __weak typeof(self) weakSelf = self;
    [[YTLDownloadHUD sharedHUD] showWithTitle:LOC(@"FetchingData") cancelHandler:^{
        [weakSelf cancel];
    }];

    [YTLStreamResolver resolveVideoID:videoID playerResponse:playerResponse completion:^(YTLStreamInfo *info, NSError *error) {
        YTLDownloadManager *strongSelf = weakSelf;
        if (!strongSelf || jobID != strongSelf->_jobID || strongSelf->_cancelled) return;

        strongSelf->_busy = NO;
        [[YTLDownloadHUD sharedHUD] dismiss];
        if (!info) {
            YTLShowAlert(LOC(@"Error"), YTLMessageForError(error));
            return;
        }
        [strongSelf presentOptionsForInfo:info sourceView:sourceView];
    }];
}

- (void)presentOptionsForInfo:(YTLStreamInfo *)info sourceView:(UIView *)sourceView {
    NSArray <YTLDownloadOption *> *options = [self optionsForInfo:info];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:info.title message:info.author preferredStyle:UIAlertControllerStyleActionSheet];

    for (YTLDownloadOption *option in options) {
        [sheet addAction:[UIAlertAction actionWithTitle:option.title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self startOption:option info:info sourceView:sourceView];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"DownloadThumbnail") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self saveThumbnailForInfo:info];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    if (options.count == 0) sheet.message = LOC(@"Downloads.NoFormats");
    YTLPresent(sheet, sourceView);
}

- (BOOL)checkFreeSpaceForBytes:(long long)bytes {
    NSNumber *available = nil;
    [[NSURL fileURLWithPath:NSHomeDirectory()] getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    if (!available || bytes <= 0) return YES;

    // The streams and the merged copy exist at the same time, plus some headroom.
    long long required = bytes * 2 + 50LL * 1024 * 1024;
    if (available.longLongValue >= required) return YES;

    NSString *missing = [YTLDownloadManager formattedSize:(unsigned long long)(required - available.longLongValue)];
    NSString *free = [YTLDownloadManager formattedSize:available.unsignedLongLongValue];
    YTLShowAlert(LOC(@"Error"), [NSString stringWithFormat:LOC(@"Error.NoSpace"), missing, free]);
    return NO;
}

- (void)startOption:(YTLDownloadOption *)option info:(YTLStreamInfo *)info sourceView:(UIView *)sourceView {
    if (_busy) {
        YTLShowToast(LOC(@"Error.Multidownloading"));
        return;
    }

    NSMutableArray <YTLMediaFormat *> *streams = [NSMutableArray array];
    if (option.video) [streams addObject:option.video];
    if (option.audio) [streams addObject:option.audio];
    long long totalBytes = 0;
    for (YTLMediaFormat *stream in streams) {
        if (stream.contentLength <= 0) {
            totalBytes = 0;
            break;
        }
        totalBytes += stream.contentLength;
    }
    if (![self checkFreeSpaceForBytes:totalBytes]) return;

    _busy = YES;
    _cancelled = NO;
    NSUInteger jobID = ++_jobID;
    NSString *directoryName = [@"YTLiteDownload-" stringByAppendingString:NSUUID.UUID.UUIDString];
    _workDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:directoryName] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_workDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [self beginBackgroundTask];

    __weak typeof(self) weakSelf = self;
    [[YTLDownloadHUD sharedHUD] showWithTitle:LOC(option.video ? @"DownloadingVideo" : @"DownloadingAudio") cancelHandler:^{
        [weakSelf cancel];
    }];

    [self downloadStreams:streams index:0 info:info jobID:jobID files:[NSMutableArray array] doneBytes:0 totalBytes:totalBytes completion:^(NSArray <NSURL *> *files) {
        [weakSelf finalizeOption:option info:info files:files jobID:jobID sourceView:sourceView];
    }];
}

- (BOOL)isCurrentJob:(NSUInteger)jobID {
    return jobID == _jobID && !_cancelled && _busy;
}

// Streams are fetched one after another; each one is split into parallel range requests.
- (void)downloadStreams:(NSArray <YTLMediaFormat *> *)streams index:(NSUInteger)index info:(YTLStreamInfo *)info jobID:(NSUInteger)jobID files:(NSMutableArray <NSURL *> *)files doneBytes:(long long)doneBytes totalBytes:(long long)totalBytes completion:(void (^)(NSArray <NSURL *> *files))completion {
    if (![self isCurrentJob:jobID]) return;
    if (index >= streams.count) {
        completion(files);
        return;
    }

    YTLMediaFormat *stream = streams[index];
    NSString *name = [NSString stringWithFormat:@"stream%lu.%@", (unsigned long)index, stream.isAudio ? @"m4a" : @"mp4"];
    NSURL *file = [_workDirectory URLByAppendingPathComponent:name];

    YTLChunkedDownloader *downloader = [[YTLChunkedDownloader alloc] initWithURL:stream.URL destination:file expectedLength:stream.contentLength userAgent:info.userAgent];
    downloader.URLRefresher = ^(void (^done)(NSURL *)) {
        [YTLStreamResolver refreshURLForFormat:stream info:info completion:done];
    };

    __weak typeof(self) weakSelf = self;
    downloader.progressHandler = ^(long long received, long long expected) {
        [weakSelf updateProgressWithReceived:doneBytes + received total:totalBytes jobID:jobID];
    };

    _currentDownloader = downloader;
    [downloader startWithCompletion:^(NSError *error) {
        YTLDownloadManager *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf isCurrentJob:jobID]) return;
        strongSelf->_currentDownloader = nil;
        if (error) {
            [strongSelf failWithError:error];
            return;
        }

        [files addObject:file];
        NSNumber *size = nil;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [strongSelf downloadStreams:streams index:index + 1 info:info jobID:jobID files:files doneBytes:doneBytes + size.longLongValue totalBytes:totalBytes completion:completion];
    }];
}

- (void)updateProgressWithReceived:(long long)received total:(long long)total jobID:(NSUInteger)jobID {
    if (![self isCurrentJob:jobID]) return;
    NSString *receivedText = [YTLDownloadManager formattedSize:(unsigned long long)MAX(received, 0)];
    if (total > 0) {
        double fraction = MIN(1.0, (double)received / (double)total);
        NSString *detail = [NSString stringWithFormat:@"%d%% · %@ / %@", (int)(fraction * 100), receivedText, [YTLDownloadManager formattedSize:(unsigned long long)total]];
        [[YTLDownloadHUD sharedHUD] updateTitle:nil detail:detail progress:(float)fraction];
    } else {
        [[YTLDownloadHUD sharedHUD] updateTitle:nil detail:receivedText progress:-1];
    }
}

- (void)finalizeOption:(YTLDownloadOption *)option info:(YTLStreamInfo *)info files:(NSArray <NSURL *> *)files jobID:(NSUInteger)jobID sourceView:(UIView *)sourceView {
    if (![self isCurrentJob:jobID]) return;
    [[YTLDownloadHUD sharedHUD] updateTitle:LOC(@"Converting") detail:nil progress:-1];

    __weak typeof(self) weakSelf = self;
    BOOL isVideo = option.video != nil;
    YTLMuxCompletion done = ^(NSURL *output, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishJob:jobID withFile:output error:error info:info isVideo:isVideo sourceView:sourceView];
        });
    };

    if (option.video && option.audio) {
        [YTLMediaMuxer mergeVideoURL:files[0] audioURL:files[1] outputURL:[_workDirectory URLByAppendingPathComponent:@"output.mp4"] completion:done];
    } else if (option.video) {
        done(files[0], nil);  // progressive MP4, already complete
    } else {
        NSURL *raw = files[0];
        [YTLMediaMuxer remuxAudioURL:raw outputURL:[_workDirectory URLByAppendingPathComponent:@"output.m4a"] completion:^(NSURL *output, NSError *error) {
            // The DASH .m4a plays fine on its own; keep it when the remux fails.
            done(output ?: raw, nil);
        }];
    }
}

- (void)finishJob:(NSUInteger)jobID withFile:(NSURL *)file error:(NSError *)error info:(YTLStreamInfo *)info isVideo:(BOOL)isVideo sourceView:(UIView *)sourceView {
    if (![self isCurrentJob:jobID]) return;
    if (error || !file) {
        [self failWithError:error];
        return;
    }

    NSURL *destination = [self destinationForTitle:info.title extension:file.pathExtension];
    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:file toURL:destination error:&moveError]) {
        [self failWithError:moveError];
        return;
    }

    [self endJob];
    [[YTLDownloadHUD sharedHUD] dismiss];
    [self performSaveActionForFile:destination isVideo:isVideo sourceView:sourceView];
}

- (void)failWithError:(NSError *)error {
    [self endJob];
    [[YTLDownloadHUD sharedHUD] dismiss];
    YTLShowAlert(LOC(@"Error"), YTLMessageForError(error));
}

- (void)cancel {
    if (!_busy || _cancelled) return;
    _cancelled = YES;
    [_currentDownloader cancel];
    [self endJob];
    [[YTLDownloadHUD sharedHUD] flashMessage:LOC(@"Cancelled")];
}

- (void)endJob {
    _busy = NO;
    _currentDownloader = nil;
    if (_workDirectory) [NSFileManager.defaultManager removeItemAtURL:_workDirectory error:nil];
    _workDirectory = nil;
    [self endBackgroundTask];
}

// Gives the download extra time to finish when the user leaves the app.
- (void)beginBackgroundTask {
    [self endBackgroundTask];
    __weak typeof(self) weakSelf = self;
    _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"YTLite download" expirationHandler:^{
        [weakSelf endBackgroundTask];
    }];
}

- (void)endBackgroundTask {
    if (_backgroundTask == UIBackgroundTaskInvalid) return;
    [UIApplication.sharedApplication endBackgroundTask:_backgroundTask];
    _backgroundTask = UIBackgroundTaskInvalid;
}

#pragma mark - Saving

- (NSURL *)destinationForTitle:(NSString *)title extension:(NSString *)extension {
    NSURL *directory = [YTLDownloadManager downloadsDirectory];
    NSString *base = YTLSanitizedFileName(title);
    NSString *ext = extension.length ? extension : @"mp4";
    NSURL *candidate = [directory URLByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
    for (NSUInteger index = 2; [NSFileManager.defaultManager fileExistsAtPath:candidate.path]; index++) {
        NSString *name = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)index];
        candidate = [directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
    }
    return candidate;
}

- (void)performSaveActionForFile:(NSURL *)file isVideo:(BOOL)isVideo sourceView:(UIView *)sourceView {
    YTLDownloadSaveAction action = [YTLUserDefaults.standardUserDefaults integerForKey:kYTLSaveActionKey];
    if (action == YTLDownloadSaveActionPhotos && !isVideo) action = YTLDownloadSaveActionAsk;

    switch (action) {
        case YTLDownloadSaveActionPhotos:
            [self saveVideoToPhotos:file];
            break;
        case YTLDownloadSaveActionFiles:
            [self exportFileToFiles:file];
            break;
        case YTLDownloadSaveActionShare:
            [self shareFile:file sourceView:sourceView];
            break;
        case YTLDownloadSaveActionKeepInApp:
            YTLShowToast(LOC(@"Downloads.SavedInApp"));
            break;
        case YTLDownloadSaveActionAsk:
        default: {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:LOC(@"DownloadCompleted") message:file.lastPathComponent preferredStyle:UIAlertControllerStyleActionSheet];
            if (isVideo) {
                [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.Menu.SaveToPhotos") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    [self saveVideoToPhotos:file];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.SaveToFiles") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self exportFileToFiles:file];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.Menu.Share") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self shareFile:file sourceView:sourceView];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Done") style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                YTLShowToast(LOC(@"Downloads.SavedInApp"));
            }]];
            YTLPresent(sheet, sourceView);
            break;
        }
    }
}

- (void)saveVideoToPhotos:(NSURL *)file {
    YTLRequestPhotosAccess(^{
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
        } completionHandler:^(BOOL success, NSError *error) {
            YTLFinishPhotosChange(success, error);
        }];
    });
}

- (void)exportFileToFiles:(NSURL *)file {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[file] asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithURL:file inMode:UIDocumentPickerModeExportToService];
    }
    YTLPresent(picker, nil);
}

- (void)shareFile:(NSURL *)file sourceView:(UIView *)sourceView {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    YTLPresent(share, sourceView);
}

- (void)saveThumbnailForInfo:(YTLStreamInfo *)info {
    NSMutableArray <NSURL *> *candidates = [NSMutableArray array];
    NSURL *maxRes = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", info.videoID]];
    if (maxRes) [candidates addObject:maxRes];
    if (info.thumbnailURL) [candidates addObject:info.thumbnailURL];
    [self saveFirstImageFromURLs:candidates];
}

- (void)saveFirstImageFromURLs:(NSArray <NSURL *> *)URLs {
    NSURL *URL = URLs.firstObject;
    if (!URL) {
        YTLShowAlert(LOC(@"Error"), LOC(@"Downloads.NoFormats"));
        return;
    }
    NSArray <NSURL *> *remaining = [URLs subarrayWithRange:NSMakeRange(1, URLs.count - 1)];
    [[NSURLSession.sharedSession dataTaskWithURL:URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = status == 200 && data.length ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
                [self saveFirstImageFromURLs:remaining];
                return;
            }
            YTLRequestPhotosAccess(^{
                [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                    [PHAssetChangeRequest creationRequestForAssetFromImage:image];
                } completionHandler:^(BOOL success, NSError *photosError) {
                    YTLFinishPhotosChange(success, photosError);
                }];
            });
        });
    }] resume];
}

#pragma mark - Files

+ (NSURL *)downloadsDirectory {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory.path]) {
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        // Videos are large and can be downloaded again: keep them out of iCloud backups.
        [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    return directory;
}

+ (NSArray <NSURL *> *)downloadedFiles {
    NSArray <NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLCreationDateKey, NSURLFileSizeKey];
    NSArray <NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self downloadsDirectory] includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];

    NSMutableArray <NSURL *> *files = [NSMutableArray array];
    for (NSURL *URL in contents) {
        NSNumber *isFile = nil;
        [URL getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:nil];
        if (isFile.boolValue) [files addObject:URL];
    }

    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *aDate = nil, *bDate = nil;
        [a getResourceValue:&aDate forKey:NSURLCreationDateKey error:nil];
        [b getResourceValue:&bDate forKey:NSURLCreationDateKey error:nil];
        return [bDate ?: NSDate.distantPast compare:aDate ?: NSDate.distantPast];
    }];
    return files;
}

+ (unsigned long long)downloadsSize {
    unsigned long long total = 0;
    for (NSURL *file in [self downloadedFiles]) {
        NSNumber *size = nil;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

+ (void)deleteAllDownloads {
    for (NSURL *file in [self downloadedFiles]) {
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    }
}

+ (NSString *)formattedSize:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)presentActionsForFile:(NSURL *)fileURL fromViewController:(UIViewController *)presenter sourceView:(UIView *)sourceView completion:(void (^)(void))completion {
    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    BOOL isVideo = ![fileURL.pathExtension.lowercaseString isEqualToString:@"m4a"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:fileURL.lastPathComponent message:[YTLDownloadManager formattedSize:size.unsignedLongLongValue] preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.Menu.Play") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        AVPlayerViewController *playerController = [AVPlayerViewController new];
        playerController.player = [AVPlayer playerWithURL:fileURL];
        YTLPresent(playerController, nil);
        [playerController.player play];
    }]];
    if (isVideo) {
        [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.Menu.SaveToPhotos") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self saveVideoToPhotos:fileURL];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.SaveToFiles") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self exportFileToFiles:fileURL];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Downloads.Menu.Share") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self shareFile:fileURL sourceView:sourceView];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
        YTLShowToast(LOC(@"Downloads.Deleted"));
        if (completion) completion();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    YTLConfigurePopover(sheet, presenter, sourceView);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end
