#import <Foundation/Foundation.h>
#import <roothide.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSBundle (YTLite)

// Returns YTLite default bundle. Supports rootless if defined in compilation parameters
@property (class, nonatomic, readonly) NSBundle *ytl_defaultBundle;

// Localized string from YTLite.bundle. Falls back to English when the current language
// doesn't have the key yet (instead of showing the raw key).
+ (NSString *)ytl_localizedStringForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END

#define LOC(key) [NSBundle ytl_localizedStringForKey:(key)]
