#import "YTLMediaFormat.h"
#import "YTLRuntime.h"

static NSString *YTLJSONString(NSDictionary *json, NSString *key) {
    id value = json[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// InnerTube encodes 64-bit numbers (contentLength, approxDurationMs) as strings.
static long long YTLJSONLongLong(NSDictionary *json, NSString *key) {
    id value = json[key];
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return [value longLongValue];
    return 0;
}

// "Stable volume" (dynamic range compressed) audio variants carry `drc=1` or an xtags entry.
static BOOL YTLURLIsDRC(NSURL *URL) {
    if (!URL) return NO;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"drc"] && [item.value isEqualToString:@"1"]) return YES;
        if ([item.name isEqualToString:@"xtags"] && [item.value containsString:@"drc"]) return YES;
    }
    return NO;
}

static BOOL YTLProtoHas(id object, NSString *field) {
    NSString *capitalized = [[field substringToIndex:1].uppercaseString stringByAppendingString:[field substringFromIndex:1]];
    id has = YTLProtoValue(object, [@"has" stringByAppendingString:capitalized]);
    // Fields without a `has` accessor are always considered present.
    return has ? [has boolValue] : YES;
}

@implementation YTLMediaFormat

- (instancetype)init {
    self = [super init];
    if (self) {
        _mimeType = @"";
        _qualityLabel = @"";
    }
    return self;
}

+ (instancetype)formatWithJSON:(NSDictionary *)json muxed:(BOOL)muxed {
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    YTLMediaFormat *format = [self new];
    format.itag = [json[@"itag"] integerValue];
    format.muxed = muxed;

    NSString *URLString = YTLJSONString(json, @"url");
    format.URL = URLString.length ? [NSURL URLWithString:URLString] : nil;
    format.mimeType = YTLJSONString(json, @"mimeType") ?: @"";
    format.qualityLabel = YTLJSONString(json, @"qualityLabel") ?: (YTLJSONString(json, @"audioQuality") ?: @"");
    format.width = [json[@"width"] integerValue];
    format.height = [json[@"height"] integerValue];
    format.fps = [json[@"fps"] integerValue];
    format.bitrate = [json[@"averageBitrate"] integerValue] ?: [json[@"bitrate"] integerValue];
    format.audioChannels = [json[@"audioChannels"] integerValue];
    format.contentLength = YTLJSONLongLong(json, @"contentLength");
    format.approxDurationMs = YTLJSONLongLong(json, @"approxDurationMs");
    format.DRC = [json[@"isDrc"] boolValue] || YTLURLIsDRC(format.URL);

    NSDictionary *audioTrack = json[@"audioTrack"];
    if ([audioTrack isKindOfClass:NSDictionary.class]) {
        format.audioTrackID = YTLJSONString(audioTrack, @"id");
        format.audioTrackName = YTLJSONString(audioTrack, @"displayName");
        format.audioTrackIsDefault = [audioTrack[@"audioIsDefault"] boolValue];
    }

    return format.itag > 0 ? format : nil;
}

+ (instancetype)formatWithFormatStream:(id)stream muxed:(BOOL)muxed {
    if (!stream) return nil;

    YTLMediaFormat *format = [self new];
    format.itag = [YTLProtoValue(stream, @"itag") integerValue];
    format.muxed = muxed;

    id URL = YTLProtoValue(stream, @"URL");
    if ([URL isKindOfClass:NSURL.class]) format.URL = URL;
    else if ([URL isKindOfClass:NSString.class] && [URL length]) format.URL = [NSURL URLWithString:URL];

    id mimeType = YTLProtoValue(stream, @"mimeType");
    format.mimeType = [mimeType isKindOfClass:NSString.class] ? mimeType : @"";
    id qualityLabel = YTLProtoValue(stream, @"qualityLabel");
    format.qualityLabel = [qualityLabel isKindOfClass:NSString.class] ? qualityLabel : @"";
    format.width = [YTLProtoValue(stream, @"width") integerValue];
    format.height = [YTLProtoValue(stream, @"height") integerValue];
    format.fps = [YTLProtoValue(stream, @"fps") integerValue];
    format.bitrate = [YTLProtoValue(stream, @"averageBitrate") integerValue] ?: [YTLProtoValue(stream, @"bitrate") integerValue];
    format.audioChannels = [YTLProtoValue(stream, @"audioChannels") integerValue];
    format.contentLength = [YTLProtoValue(stream, @"contentLength") longLongValue];
    format.approxDurationMs = [YTLProtoValue(stream, @"approxDurationMs") longLongValue];
    format.DRC = [YTLProtoValue(stream, @"isDrc") boolValue] || YTLURLIsDRC(format.URL);

    if (YTLProtoHas(stream, @"audioTrack")) {
        id audioTrack = YTLProtoValue(stream, @"audioTrack");
        id trackID = YTLProtoValue(audioTrack, @"id_p");
        id trackName = YTLProtoValue(audioTrack, @"displayName");
        format.audioTrackID = [trackID isKindOfClass:NSString.class] && [trackID length] ? trackID : nil;
        format.audioTrackName = [trackName isKindOfClass:NSString.class] && [trackName length] ? trackName : nil;
        format.audioTrackIsDefault = [YTLProtoValue(audioTrack, @"audioIsDefault") boolValue];
    }

    return format.itag > 0 ? format : nil;
}

- (BOOL)isVideo {
    return [self.mimeType hasPrefix:@"video/"];
}

- (BOOL)isAudio {
    return [self.mimeType hasPrefix:@"audio/"];
}

- (BOOL)isMP4Container {
    return [self.mimeType hasPrefix:@"video/mp4"] || [self.mimeType hasPrefix:@"audio/mp4"];
}

- (NSString *)codecs {
    NSString *lower = self.mimeType.lowercaseString;
    NSRange range = [lower rangeOfString:@"codecs=\""];
    if (range.location == NSNotFound) return lower;
    NSString *rest = [lower substringFromIndex:NSMaxRange(range)];
    NSRange end = [rest rangeOfString:@"\""];
    return end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
}

- (BOOL)isH264 {
    return [self.codecs containsString:@"avc1"];
}

- (BOOL)isAV1 {
    return [self.codecs containsString:@"av01"];
}

- (BOOL)isAAC {
    return [self.codecs containsString:@"mp4a"];
}

- (BOOL)isHDR {
    return [self.qualityLabel.uppercaseString containsString:@"HDR"];
}

- (NSString *)codecName {
    NSString *codecs = self.codecs;
    NSMutableArray <NSString *> *names = [NSMutableArray array];
    if ([codecs containsString:@"avc1"]) [names addObject:@"H.264"];
    if ([codecs containsString:@"av01"]) [names addObject:@"AV1"];
    if ([codecs containsString:@"vp9"] || [codecs containsString:@"vp09"]) [names addObject:@"VP9"];
    if ([codecs containsString:@"hev1"] || [codecs containsString:@"hvc1"]) [names addObject:@"HEVC"];
    if ([codecs containsString:@"mp4a"]) [names addObject:@"AAC"];
    if ([codecs containsString:@"opus"]) [names addObject:@"Opus"];
    return names.count ? [names componentsJoinedByString:@" + "] : codecs;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ itag=%ld %@ %@ %lldB url=%@>", NSStringFromClass(self.class), (long)self.itag, self.qualityLabel, self.mimeType, self.contentLength, self.URL ? @"yes" : @"no"];
}

@end
