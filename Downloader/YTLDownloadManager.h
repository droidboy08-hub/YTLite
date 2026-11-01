#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What happens after a download finishes (`downloadSaveAction` preference).
typedef NS_ENUM(NSInteger, YTLDownloadSaveAction) {
    YTLDownloadSaveActionAsk = 0,
    YTLDownloadSaveActionPhotos = 1,
    YTLDownloadSaveActionFiles = 2,
    YTLDownloadSaveActionShare = 3,
    YTLDownloadSaveActionKeepInApp = 4,
};

/// Downloads videos/audio of YouTube videos to local storage.
///
/// Finished files are written to Documents/Downloads inside the app container (excluded from
/// iCloud backup). With `UIFileSharingEnabled` in the app's Info.plist that folder shows up in
/// the Files app under "On My iPhone › YouTube"; files can also be sent to Photos, exported to
/// any Files location or shared.
@interface YTLDownloadManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

/// Fetches the available formats and shows the quality picker.
/// `playerResponse` is the app's YTIPlayerResponse (optional, used as a fallback source).
- (void)presentDownloadOptionsForVideoID:(NSString *)videoID playerResponse:(nullable id)playerResponse fromViewController:(nullable UIViewController *)presenter sourceView:(nullable UIView *)sourceView;

/// Play / save / share / delete menu for a downloaded file.
- (void)presentActionsForFile:(NSURL *)fileURL fromViewController:(UIViewController *)presenter sourceView:(nullable UIView *)sourceView completion:(nullable void (^)(void))completion;

+ (NSURL *)downloadsDirectory;
/// Newest first.
+ (NSArray <NSURL *> *)downloadedFiles;
+ (unsigned long long)downloadsSize;
+ (void)deleteAllDownloads;
/// Removes work folders left behind when the app was killed mid-download. Call at launch only.
+ (void)removeStaleTemporaryFiles;
+ (NSString *)formattedSize:(unsigned long long)bytes;
@end

NS_ASSUME_NONNULL_END
