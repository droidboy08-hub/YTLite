#import "YTLStreamResolver.h"
#import "YTLRuntime.h"
#import "../Utils/YTLUserDefaults.h"
#import <UIKit/UIKit.h>

NSErrorDomain const YTLDownloaderErrorDomain = @"YTLDownloaderErrorDomain";

static NSString *const kYTLInnerTubeBase = @"https://youtubei.googleapis.com/youtubei/v1/";
static NSString *const kYTLVisitorDataKey = @"downloaderVisitorData";
static NSString *const kYTLVisitorDateKey = @"downloaderVisitorDate";
static const NSTimeInterval kYTLVisitorLifetime = 6 * 24 * 60 * 60;

@implementation YTLStreamInfo
@end

#pragma mark - Helpers

static NSDictionary *YTLDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *YTLArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSString *YTLString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSError *YTLError(YTLDownloaderError code, NSString *message) {
    return [NSError errorWithDomain:YTLDownloaderErrorDomain code:code userInfo:message ? @{NSLocalizedDescriptionKey: message} : nil];
}

#pragma mark - Client profiles

// InnerTube client profiles that (as of late 2026) still receive plain, PO-token-free stream URLs.
// The YouTube app's own IOS/ANDROID clients only get SABR streams, TV/web clients need a JS
// player for signatures. If YouTube changes this, update these profiles (see docs/Research.md).
static NSArray <NSDictionary *> *YTLClientProfiles(void) {
    static NSArray <NSDictionary *> *profiles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *safariUA = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
        NSString *questUA = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";
        profiles = @[
            @{
                @"name": @"VISIONOS",
                @"userAgent": safariUA,
                @"headers": @{},
                @"client": @{
                    @"clientName": @"VISIONOS",
                    @"clientVersion": @"1.02",
                    @"osName": @"visionOS",
                    @"osVersion": @"26.5.23O471",
                    @"deviceMake": @"Apple",
                    @"deviceModel": @"RealityDevice17,1",
                    @"userAgent": safariUA
                }
            },
            @{
                @"name": @"ANDROID_VR",
                @"userAgent": questUA,
                @"headers": @{@"X-YouTube-Client-Name": @"28", @"X-YouTube-Client-Version": @"1.65.10"},
                @"client": @{
                    @"clientName": @"ANDROID_VR",
                    @"clientVersion": @"1.65.10",
                    @"deviceMake": @"Oculus",
                    @"deviceModel": @"Quest 3",
                    @"androidSdkVersion": @32,
                    @"osName": @"Android",
                    @"osVersion": @"12L",
                    @"userAgent": questUA
                }
            }
        ];
    });
    return profiles;
}

static NSDictionary *YTLProfileNamed(NSString *name) {
    for (NSDictionary *profile in YTLClientProfiles()) {
        if ([profile[@"name"] isEqualToString:name]) return profile;
    }
    return nil;
}

#pragma mark - Networking

static NSURLSession *YTLAPISession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Ephemeral: never attach the user's YouTube/Google cookies to these requests.
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 40;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static NSDictionary *YTLClientContext(NSDictionary *profile, NSString *visitorData) {
    NSMutableDictionary *client = [profile[@"client"] mutableCopy];
    client[@"hl"] = NSLocale.currentLocale.languageCode ?: @"en";
    client[@"gl"] = NSLocale.currentLocale.countryCode ?: @"US";
    if (visitorData.length) client[@"visitorData"] = visitorData;
    return @{@"client": client};
}

// Synchronous POST; only ever called from a background queue.
static NSDictionary *YTLPostJSON(NSString *path, NSDictionary *body, NSDictionary *profile, NSString *visitorData, NSError **errorOut) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kYTLInnerTubeBase stringByAppendingString:path]]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:profile[@"userAgent"] forHTTPHeaderField:@"User-Agent"];
    [(NSDictionary *)profile[@"headers"] enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:field];
    }];
    if (visitorData.length) [request setValue:visitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];

    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    __block NSInteger statusCode = 0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[YTLAPISession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseData = data;
        responseError = error;
        if ([response isKindOfClass:NSHTTPURLResponse.class]) statusCode = ((NSHTTPURLResponse *)response).statusCode;
        dispatch_semaphore_signal(semaphore);
    }] resume];
    // The session's resource timeout bounds the wait.
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    id json = responseData.length ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        if (errorOut) *errorOut = responseError ?: YTLError(YTLDownloaderErrorHTTP, [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
        return nil;
    }
    return json;
}

// Every InnerTube client identifies its (logged-out) session with visitor data. It is requested
// once and reused until it ages out, exactly like the official clients do.
static NSString *YTLVisitorData(void) {
    YTLUserDefaults *defaults = YTLUserDefaults.standardUserDefaults;
    NSString *cached = [defaults stringForKey:kYTLVisitorDataKey];
    NSDate *date = [defaults objectForKey:kYTLVisitorDateKey];
    if (cached.length && [date isKindOfClass:NSDate.class] && -date.timeIntervalSinceNow < kYTLVisitorLifetime) return cached;

    NSDictionary *profile = YTLClientProfiles().firstObject;
    NSDictionary *json = YTLPostJSON(@"guide?prettyPrint=false&fields=responseContext.visitorData", @{@"context": YTLClientContext(profile, nil)}, profile, nil, NULL);
    NSString *visitorData = YTLString(YTLDict(json[@"responseContext"])[@"visitorData"]);
    if (!visitorData) return cached;

    [defaults setObject:visitorData forKey:kYTLVisitorDataKey];
    [defaults setObject:[NSDate date] forKey:kYTLVisitorDateKey];
    return visitorData;
}

#pragma mark - Parsing

static YTLStreamInfo *YTLResolveWithProfile(NSString *videoID, NSDictionary *profile, NSError **errorOut) {
    NSString *visitorData = YTLVisitorData();
    NSDictionary *body = @{
        @"context": YTLClientContext(profile, visitorData),
        @"videoId": videoID,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES
    };

    NSError *requestError = nil;
    NSDictionary *json = YTLPostJSON(@"player?prettyPrint=false", body, profile, visitorData, &requestError);
    if (!json) {
        if (errorOut) *errorOut = requestError;
        return nil;
    }

    NSDictionary *details = YTLDict(json[@"videoDetails"]);
    if ([details[@"isLive"] boolValue] || [details[@"isUpcoming"] boolValue]) {
        if (errorOut) *errorOut = YTLError(YTLDownloaderErrorLive, nil);
        return nil;
    }

    NSDictionary *playability = YTLDict(json[@"playabilityStatus"]);
    NSString *status = YTLString(playability[@"status"]);
    if (![status isEqualToString:@"OK"]) {
        NSString *reason = YTLString(playability[@"reason"]) ?: status;
        if (errorOut) *errorOut = YTLError(YTLDownloaderErrorUnplayable, reason);
        return nil;
    }

    NSDictionary *streamingData = YTLDict(json[@"streamingData"]);
    NSMutableArray <YTLMediaFormat *> *formats = [NSMutableArray array];
    for (NSDictionary *formatJSON in YTLArray(streamingData[@"formats"])) {
        YTLMediaFormat *format = [YTLMediaFormat formatWithJSON:formatJSON muxed:YES];
        if (format.URL) [formats addObject:format];
    }
    for (NSDictionary *formatJSON in YTLArray(streamingData[@"adaptiveFormats"])) {
        YTLMediaFormat *format = [YTLMediaFormat formatWithJSON:formatJSON muxed:NO];
        if (format.URL) [formats addObject:format];
    }
    if (formats.count == 0) {
        if (errorOut) *errorOut = YTLError(YTLDownloaderErrorNoFormats, nil);
        return nil;
    }

    YTLStreamInfo *info = [YTLStreamInfo new];
    info.videoID = YTLString(details[@"videoId"]) ?: videoID;
    info.title = YTLString(details[@"title"]) ?: videoID;
    info.author = YTLString(details[@"author"]);
    info.duration = [details[@"lengthSeconds"] doubleValue];
    NSString *thumbnail = YTLString(YTLDict(YTLArray(YTLDict(details[@"thumbnail"])[@"thumbnails"]).lastObject)[@"url"]);
    info.thumbnailURL = thumbnail ? [NSURL URLWithString:thumbnail] : nil;
    info.formats = formats;
    info.source = profile[@"name"];
    info.userAgent = profile[@"userAgent"];
    return info;
}

// The YouTube app's own player response. It only carries per-format URLs on versions that
// predate SABR, so this is a fallback.
static YTLStreamInfo *YTLInfoFromPlayerResponse(id playerResponse, NSString *videoID) {
    id streamingData = YTLProtoValue(playerResponse, @"streamingData");
    if (!streamingData) return nil;

    NSMutableArray <YTLMediaFormat *> *formats = [NSMutableArray array];
    for (id stream in YTLArray(YTLProtoValue(streamingData, @"formatsArray"))) {
        YTLMediaFormat *format = [YTLMediaFormat formatWithFormatStream:stream muxed:YES];
        if (format.URL) [formats addObject:format];
    }
    for (id stream in YTLArray(YTLProtoValue(streamingData, @"adaptiveFormatsArray"))) {
        YTLMediaFormat *format = [YTLMediaFormat formatWithFormatStream:stream muxed:NO];
        if (format.URL) [formats addObject:format];
    }
    if (formats.count == 0) return nil;

    id details = YTLProtoValue(playerResponse, @"videoDetails");
    NSString *appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"21.0.0";
    NSString *systemVersion = [UIDevice.currentDevice.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];

    YTLStreamInfo *info = [YTLStreamInfo new];
    info.videoID = YTLProtoString(details, @"videoId") ?: videoID;
    info.title = YTLProtoString(details, @"title") ?: videoID;
    info.author = YTLProtoString(details, @"author");
    info.duration = [YTLProtoValue(details, @"lengthSeconds") doubleValue];
    info.thumbnailURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", info.videoID]];
    info.formats = formats;
    info.source = @"APP";
    info.userAgent = [NSString stringWithFormat:@"com.google.ios.youtube/%@ (%@; U; CPU iOS %@ like Mac OS X;)", appVersion, UIDevice.currentDevice.model, systemVersion];
    return info;
}

#pragma mark - Public

@implementation YTLStreamResolver

+ (void)resolveVideoID:(NSString *)videoID playerResponse:(id)playerResponse completion:(void (^)(YTLStreamInfo *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        YTLStreamInfo *info = nil;
        NSError *error = nil;

        for (NSDictionary *profile in YTLClientProfiles()) {
            NSError *profileError = nil;
            info = YTLResolveWithProfile(videoID, profile, &profileError);
            if (info) break;
            // Keep the most informative error (YouTube's own playability reason beats a generic one).
            if (!error || profileError.code == YTLDownloaderErrorUnplayable || profileError.code == YTLDownloaderErrorLive) error = profileError;
            if (profileError.code == YTLDownloaderErrorLive) break;
        }

        if (!info && error.code != YTLDownloaderErrorLive) {
            info = YTLInfoFromPlayerResponse(playerResponse, videoID);
        }

        NSError *finalError = info ? nil : (error ?: YTLError(YTLDownloaderErrorNoFormats, nil));
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(info, finalError);
        });
    });
}

+ (void)refreshURLForFormat:(YTLMediaFormat *)format info:(YTLStreamInfo *)info completion:(void (^)(NSURL *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *profile = YTLProfileNamed(info.source);
        YTLStreamInfo *fresh = profile ? YTLResolveWithProfile(info.videoID, profile, NULL) : nil;

        NSURL *URL = nil;
        for (YTLMediaFormat *candidate in fresh.formats) {
            BOOL sameTrack = !format.audioTrackID || [candidate.audioTrackID isEqualToString:format.audioTrackID];
            if (candidate.itag == format.itag && candidate.isDRC == format.isDRC && sameTrack) {
                URL = candidate.URL;
                break;
            }
        }
        completion(URL);
    });
}

@end
