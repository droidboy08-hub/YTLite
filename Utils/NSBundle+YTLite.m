#import "NSBundle+YTLite.h"

@implementation NSBundle (YTLite)

+ (NSBundle *)ytl_defaultBundle {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTLite" ofType:@"bundle"];
        NSString *kBundlePath = jbroot(@"/Library/Application Support/YTLite.bundle");

        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: kBundlePath];
    });

    return bundle;
}

+ (NSString *)ytl_localizedStringForKey:(NSString *)key {
    NSString *string = [self.ytl_defaultBundle localizedStringForKey:key value:nil table:nil];
    if (string.length && ![string isEqualToString:key]) return string;

    static NSBundle *englishBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [self.ytl_defaultBundle pathForResource:@"en" ofType:@"lproj"];
        if (path) englishBundle = [NSBundle bundleWithPath:path];
    });

    return [englishBundle localizedStringForKey:key value:key table:nil] ?: key;
}

@end
