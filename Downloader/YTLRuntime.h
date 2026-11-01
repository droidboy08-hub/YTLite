#import <Foundation/Foundation.h>

// Reads a property of one of YouTube's own objects without depending on its headers.
// `respondsToSelector:` also triggers GPBMessage's lazy accessor resolution, so dynamic
// protobuf properties are found, and KVC boxes scalar fields with their real type.
static inline id YTLProtoValue(id object, NSString *key) {
    if (!object || key.length == 0 || ![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Follows a dotted key path ("streamingData.adaptiveFormatsArray") with YTLProtoValue.
static inline id YTLProtoValueForPath(id object, NSString *path) {
    id current = object;
    for (NSString *key in [path componentsSeparatedByString:@"."]) {
        current = YTLProtoValue(current, key);
        if (!current) return nil;
    }
    return current;
}

static inline NSString *YTLProtoString(id object, NSString *key) {
    id value = YTLProtoValue(object, key);
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}
