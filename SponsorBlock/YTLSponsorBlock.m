#import "YTLSponsorBlock.h"
#import "../Utils/YTLUserDefaults.h"
#import "../Utils/NSBundle+YTLite.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

static NSString *const kYTLSponsorBlockAPI = @"https://sponsor.ajay.app/api/";

#pragma mark - Categories

@implementation YTLSponsorCategory

- (instancetype)initWithIdentifier:(NSString *)identifier titleKey:(NSString *)titleKey segmentNameKey:(NSString *)segmentNameKey highlight:(BOOL)highlight defaultMode:(YTLSBMode)defaultMode {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _titleKey = [titleKey copy];
        _segmentNameKey = [segmentNameKey copy];
        _isHighlight = highlight;
        _defaultMode = defaultMode;
    }
    return self;
}

// Defaults follow the official extension: only sponsors are skipped automatically; categories
// that are often wanted get a skip button; the rest stays off until enabled.
+ (NSArray <YTLSponsorCategory *> *)allCategories {
    static NSArray <YTLSponsorCategory *> *categories;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        categories = @[
            [[self alloc] initWithIdentifier:@"sponsor" titleKey:@"Sponsor" segmentNameKey:@"sb_sponsor" highlight:NO defaultMode:YTLSBModeAuto],
            [[self alloc] initWithIdentifier:@"selfpromo" titleKey:@"SelfPromo" segmentNameKey:@"sb_selfpromo" highlight:NO defaultMode:YTLSBModeAsk],
            [[self alloc] initWithIdentifier:@"interaction" titleKey:@"Interaction" segmentNameKey:@"sb_interaction" highlight:NO defaultMode:YTLSBModeAsk],
            [[self alloc] initWithIdentifier:@"poi_highlight" titleKey:@"Highlight" segmentNameKey:@"sb_poi_highlight" highlight:YES defaultMode:YTLSBModeAsk],
            [[self alloc] initWithIdentifier:@"intro" titleKey:@"Intro" segmentNameKey:@"sb_intro" highlight:NO defaultMode:YTLSBModeOff],
            [[self alloc] initWithIdentifier:@"outro" titleKey:@"Endcards" segmentNameKey:@"sb_outro" highlight:NO defaultMode:YTLSBModeOff],
            [[self alloc] initWithIdentifier:@"preview" titleKey:@"Preview" segmentNameKey:@"sb_preview" highlight:NO defaultMode:YTLSBModeOff],
            [[self alloc] initWithIdentifier:@"filler" titleKey:@"Jokes" segmentNameKey:@"sb_filler" highlight:NO defaultMode:YTLSBModeOff],
            [[self alloc] initWithIdentifier:@"music_offtopic" titleKey:@"MusicOfftopic" segmentNameKey:@"sb_music_offtopic" highlight:NO defaultMode:YTLSBModeOff],
        ];
    });
    return categories;
}

+ (YTLSponsorCategory *)categoryWithIdentifier:(NSString *)identifier {
    for (YTLSponsorCategory *category in [self allCategories]) {
        if ([category.identifier isEqualToString:identifier]) return category;
    }
    return nil;
}

- (NSString *)modeKey {
    return [@"sbMode_" stringByAppendingString:self.identifier];
}

- (YTLSBMode)mode {
    id stored = [YTLUserDefaults.standardUserDefaults objectForKey:[self modeKey]];
    if (![stored isKindOfClass:NSNumber.class]) return self.defaultMode;
    NSInteger mode = [stored integerValue];
    return mode >= YTLSBModeOff && mode <= YTLSBModeAuto ? (YTLSBMode)mode : self.defaultMode;
}

- (void)setMode:(YTLSBMode)mode {
    [YTLUserDefaults.standardUserDefaults setInteger:mode forKey:[self modeKey]];
}

@end

@implementation YTLSponsorSegment
@end

#pragma mark - Client

static NSURLSession *YTLSponsorSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 10;
        configuration.timeoutIntervalForResource = 15;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static NSCache <NSString *, NSArray <YTLSponsorSegment *> *> *YTLSponsorCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    return cache;
}

static NSString *YTLSHA256Hex(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *YTLJSONArrayString(NSArray <NSString *> *strings) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:strings options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

static YTLSponsorSegment *YTLSegmentFromJSON(id json) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *dict = json;

    NSString *category = dict[@"category"];
    NSString *actionType = [dict[@"actionType"] isKindOfClass:NSString.class] ? dict[@"actionType"] : @"skip";
    NSArray *range = dict[@"segment"];
    if (![category isKindOfClass:NSString.class] || ![YTLSponsorCategory categoryWithIdentifier:category]) return nil;
    if (![actionType isEqualToString:@"skip"] && ![actionType isEqualToString:@"poi"]) return nil;
    if (![range isKindOfClass:NSArray.class] || range.count < 2 || ![range[0] isKindOfClass:NSNumber.class] || ![range[1] isKindOfClass:NSNumber.class]) return nil;

    YTLSponsorSegment *segment = [YTLSponsorSegment new];
    segment.UUID = [dict[@"UUID"] isKindOfClass:NSString.class] ? dict[@"UUID"] : NSUUID.UUID.UUIDString;
    segment.category = category;
    segment.actionType = actionType;
    segment.start = [range[0] doubleValue];
    segment.end = [range[1] doubleValue];
    segment.videoDuration = [dict[@"videoDuration"] isKindOfClass:NSNumber.class] ? [dict[@"videoDuration"] doubleValue] : 0;
    if (!(segment.start >= 0) || segment.end < segment.start) return nil;
    return segment;
}

@implementation YTLSponsorBlock

+ (BOOL)isEnabled {
    return [YTLUserDefaults.standardUserDefaults boolForKey:@"sponsorBlock"];
}

+ (void)fetchSegmentsForVideoID:(NSString *)videoID completion:(void (^)(NSArray <YTLSponsorSegment *> *))completion {
    void (^finish)(NSArray *) = ^(NSArray *segments) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(segments);
        });
    };

    BOOL anyEnabled = NO;
    for (YTLSponsorCategory *category in [YTLSponsorCategory allCategories]) {
        if (category.mode != YTLSBModeOff) anyEnabled = YES;
    }
    if (videoID.length == 0 || !anyEnabled) {
        finish(nil);  // nothing to look up yet; asked again once a category is enabled
        return;
    }

    NSArray *cached = [YTLSponsorCache() objectForKey:videoID];
    if (cached) {
        finish(cached);
        return;
    }

    // Every supported category is requested, so changing a category's mode applies at once.
    NSArray <NSString *> *categories = [[YTLSponsorCategory allCategories] valueForKey:@"identifier"];
    NSString *prefix = [YTLSHA256Hex(videoID) substringToIndex:4];
    NSURLComponents *components = [NSURLComponents componentsWithString:[kYTLSponsorBlockAPI stringByAppendingFormat:@"skipSegments/%@", prefix]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"categories" value:YTLJSONArrayString(categories)],
        [NSURLQueryItem queryItemWithName:@"actionTypes" value:YTLJSONArrayString(@[@"skip", @"poi"])]
    ];
    if (!components.URL) {
        finish(nil);
        return;
    }

    [[YTLSponsorSession() dataTaskWithURL:components.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status == 404 && !error) {
            // No segments for any video with this prefix.
            [YTLSponsorCache() setObject:@[] forKey:videoID];
            finish(@[]);
            return;
        }

        id json = !error && status == 200 && data.length && data.length <= 2 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSArray.class]) {
            finish(nil);  // network error, rate limit, captive portal…: not cached, retried later
            return;
        }

        // The response lists every video whose hash starts with the prefix.
        NSMutableArray <YTLSponsorSegment *> *segments = [NSMutableArray array];
        for (id entry in (NSArray *)json) {
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"videoID"] isEqual:videoID]) continue;
            NSArray *items = entry[@"segments"];
            for (id item in [items isKindOfClass:NSArray.class] ? items : @[]) {
                YTLSponsorSegment *segment = YTLSegmentFromJSON(item);
                if (segment) [segments addObject:segment];
            }
        }

        [YTLSponsorCache() setObject:[segments copy] forKey:videoID];
        finish(segments);
    }] resume];
}

+ (void)reportSkippedSegment:(YTLSponsorSegment *)segment {
    if (segment.UUID.length == 0 || ![YTLUserDefaults.standardUserDefaults boolForKey:@"sbCountSkips"]) return;
    NSURLComponents *components = [NSURLComponents componentsWithString:[kYTLSponsorBlockAPI stringByAppendingString:@"viewedVideoSponsorTime"]];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"UUID" value:segment.UUID]];
    if (!components.URL) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.HTTPMethod = @"POST";
    [[YTLSponsorSession() dataTaskWithRequest:request] resume];
}

+ (void)playSkipFeedback {
    YTLUserDefaults *defaults = YTLUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"sbSkipHaptic"]) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    if ([defaults boolForKey:@"sbSkipAudio"]) {
        static AVAudioPlayer *player;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSURL *sound = [NSBundle.ytl_defaultBundle URLForResource:@"SponsorAudio" withExtension:@"m4a"];
            if (sound) player = [[AVAudioPlayer alloc] initWithContentsOfURL:sound error:nil];
            [player prepareToPlay];
        });
        player.currentTime = 0;
        [player play];
    }
}

@end
