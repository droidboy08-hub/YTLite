#import "YTLite.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "Downloader/YTLRuntime.h"

// Ad blocking, all behind the "Remove ads" switch (noAds).
//
// YouTube ads arrive inside the same InnerTube responses (and from the same googlevideo.com
// servers) as the content itself, so DNS/host blocking can't separate them. Instead the ads
// are removed from the decoded protobuf models before the app acts on them, layer by layer:
//   1. Video ads   – the player response's ad schedule and the ads playback coordinator
//   2. Feed ads    – promoted/ad element renderers in Home, Search, Watch next…
//   3. Shorts ads  – ad entries in the Shorts sequence
//   4. Shopping    – product lists, product overlays and "products in this video" panels
// See docs/Research.md for how each layer was chosen. Hook targets follow PoomSmart's
// YouTube-X (MIT, https://github.com/PoomSmart/YouTube-X), which tracks current YouTube builds.

#define YTLAdsBlocked() ytlBool(@"noAds")

@protocol YTLReelModelLike <NSObject>
@optional
- (int)videoType;
- (id)renderer;
@end

#pragma mark - Ad detection

// Layout identifiers that only ever appear on ad/promoted elements.
static NSArray <NSString *> *YTLAdElementIdentifiers(void) {
    static NSArray <NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[@"brand_promo", @"brand_video_shelf", @"carousel_footered_layout", @"carousel_headered_layout", @"eml.expandable_metadata.vpp", @"feed_ad_metadata", @"full_width_portrait_image_layout", @"full_width_square_image_layout", @"grid_ads_image_layout", @"landscape_image_wide_button_layout", @"product_carousel", @"product_engagement_panel", @"product_item", @"shopping_carousel", @"shopping_item_card_list", @"statement_banner", @"square_image_layout", @"text_image_button_layout", @"text_search_ad", @"video_display_full_layout", @"video_display_full_buttoned_layout"];
    });
    return identifiers;
}

// Protobuf fields come and go between YouTube versions; reading a field the build no longer
// has would be an unrecognized selector, so optional fields are read defensively.
static BOOL YTLProtoFlag(id object, NSString *key) {
    return [YTLProtoValue(object, key) boolValue];
}

static BOOL YTLIsAdElementRenderer(YTIElementRenderer *renderer) {
    if (![renderer isKindOfClass:%c(YTIElementRenderer)]) return NO;
    // Ads always carry ad logging data.
    if (YTLProtoFlag(renderer, @"hasCompatibilityOptions") && YTLProtoFlag(YTLProtoValue(renderer, @"compatibilityOptions"), @"hasAdLoggingData")) return YES;

    NSString *description = [renderer description];
    for (NSString *identifier in YTLAdElementIdentifiers()) {
        if ([description containsString:identifier]) return YES;
    }
    return NO;
}

static BOOL YTLIsPromotedVideo(YTIItemSectionSupportedRenderers *content) {
    return YTLProtoFlag(content, @"hasPromotedVideoRenderer") || YTLProtoFlag(content, @"hasCompactPromotedVideoRenderer") || YTLProtoFlag(content, @"hasPromotedVideoInlineMutedRenderer");
}

static BOOL YTLIsPromotedSectionContent(YTIItemSectionSupportedRenderers *content) {
    if (![content isKindOfClass:%c(YTIItemSectionSupportedRenderers)]) return NO;
    return YTLIsPromotedVideo(content) || YTLIsAdElementRenderer(YTLProtoValue(content, @"elementRenderer"));
}

static BOOL YTLIsAdSectionEntry(id entry) {
    if ([entry isKindOfClass:%c(YTIItemSectionSupportedRenderers)]) return YTLIsPromotedSectionContent(entry);
    return YTLIsAdElementRenderer(entry);
}

static NSArray *YTLFilteredSectionEntries(NSArray *entries) {
    if (!YTLAdsBlocked() || ![entries isKindOfClass:NSArray.class]) return entries;
    NSIndexSet *adIndexes = [entries indexesOfObjectsPassingTest:^BOOL(id entry, NSUInteger idx, BOOL *stop) {
        return YTLIsAdSectionEntry(entry);
    }];
    if (adIndexes.count == 0) return entries;
    NSMutableArray *filtered = [entries mutableCopy];
    [filtered removeObjectsAtIndexes:adIndexes];
    return filtered;
}

// Section renderers of an InnerTube list (Home, Search, Watch next, Subscriptions…).
static NSArray *YTLFilteredSectionRenderers(NSArray *sections) {
    if (!YTLAdsBlocked() || ![sections isKindOfClass:NSArray.class]) return sections;
    Class shelfClass = %c(YTIShelfRenderer);
    Class itemSectionClass = %c(YTIItemSectionRenderer);

    NSMutableArray *filtered = [sections mutableCopy];
    NSIndexSet *adIndexes = [filtered indexesOfObjectsPassingTest:^BOOL(id section, NSUInteger idx, BOOL *stop) {
        // Horizontal shelves: drop ad items, keep the shelf.
        if (shelfClass && [section isKindOfClass:shelfClass]) {
            NSMutableArray *items = YTLProtoValueForPath(section, @"content.horizontalListRenderer.itemsArray");
            if ([items isKindOfClass:NSMutableArray.class]) {
                [items removeObjectsAtIndexes:[items indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger itemIdx, BOOL *itemStop) {
                    return YTLIsAdElementRenderer(YTLProtoValue(item, @"elementRenderer"));
                }]];
            }
            return NO;
        }
        if (!itemSectionClass || ![section isKindOfClass:itemSectionClass]) return NO;

        NSMutableArray <YTIItemSectionSupportedRenderers *> *contents = ((YTIItemSectionRenderer *)section).contentsArray;
        if (contents.count > 1) {
            [contents removeObjectsAtIndexes:[contents indexesOfObjectsPassingTest:^BOOL(YTIItemSectionSupportedRenderers *content, NSUInteger contentIdx, BOOL *contentStop) {
                return YTLIsPromotedSectionContent(content);
            }]];
        }
        return YTLIsPromotedSectionContent(contents.firstObject);
    }];
    [filtered removeObjectsAtIndexes:adIndexes];
    return filtered;
}

static BOOL YTLIsAdReel(id model) {
    if ([model respondsToSelector:@selector(videoType)]) return [(id <YTLReelModelLike>)model videoType] == 3;
    Class nonVideoClass = %c(YTReelNonVideoContentModel);
    if (nonVideoClass && [model isKindOfClass:nonVideoClass] && [model respondsToSelector:@selector(renderer)]) {
        id customData = YTLProtoValue([(id <YTLReelModelLike>)model renderer], @"customData");
        return [[customData description] containsString:@"YTIReelNonVideoAdsCustomData_reelNonVideoAdsCustomData"];
    }
    return NO;
}

static BOOL YTLIsProductListCommand(id command) {
    SEL selector = NSSelectorFromString(@"yt_showEngagementPanelEndpoint");
    if (![command respondsToSelector:selector]) return NO;
    id endpoint = ((id (*)(id, SEL))objc_msgSend)(command, selector);
    NSString *tag = YTLProtoValueForPath(endpoint, @"identifier.tag");
    return [tag isEqualToString:@"PAproduct_list"];
}

static id YTLIvar(id object, NSString *name) {
    if (!object || !class_getInstanceVariable(object_getClass(object), name.UTF8String)) return nil;
    @try {
        return [object valueForKey:name];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark - 1. Video ads

%hook YTIPlayerResponse
- (BOOL)isMonetized { return YTLAdsBlocked() ? NO : %orig; }
%end

// The ad schedule of a video (playerAds / adSlots / adPlacements) are protobuf fields of the
// player response. GPBMessage creates their getters lazily, so they are hooked at runtime in
// the constructor below (see YTLOverrideGetter) instead of with %hook.
static IMP origPlayerAdsArray, origAdSlotsArray, origAdPlacementsArray, origEnableSkippableAd;

static id YTLCallGetter(IMP original, id self, SEL _cmd) {
    return original ? ((id (*)(id, SEL))original)(self, _cmd) : [NSMutableArray array];
}

static id YTLPlayerAdsArray(id self, SEL _cmd) {
    return YTLAdsBlocked() ? [NSMutableArray array] : YTLCallGetter(origPlayerAdsArray, self, _cmd);
}

static id YTLAdSlotsArray(id self, SEL _cmd) {
    return YTLAdsBlocked() ? [NSMutableArray array] : YTLCallGetter(origAdSlotsArray, self, _cmd);
}

static id YTLAdPlacementsArray(id self, SEL _cmd) {
    return YTLAdsBlocked() ? [NSMutableArray array] : YTLCallGetter(origAdPlacementsArray, self, _cmd);
}

// Lets cast (MDX) sessions skip ads the receiver still schedules.
static BOOL YTLEnableSkippableAd(id self, SEL _cmd) {
    if (YTLAdsBlocked()) return YES;
    return origEnableSkippableAd ? ((BOOL (*)(id, SEL))origEnableSkippableAd)(self, _cmd) : NO;
}

static void YTLOverrideGetter(NSString *className, NSString *selectorName, IMP replacement, IMP *original, const char *types) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL selector = NSSelectorFromString(selectorName);
    // class_getInstanceMethod runs +resolveInstanceMethod:, which is how GPBMessage installs a
    // protobuf property getter, so after this call the getter exists and can be swapped.
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        class_addMethod(cls, selector, replacement, types);
        return;
    }
    IMP previous = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        previous = method_setImplementation(method, replacement);
    }
    if (original) *original = previous;
}

%hook YTLocalPlaybackController
- (id)createAdsPlaybackCoordinator { return YTLAdsBlocked() ? nil : %orig; }
%end

%hook MDXSession
- (void)adPlaying:(id)ad { if (!YTLAdsBlocked()) %orig; }
%end

%hook MDXSessionImpl
- (void)adPlaying:(id)ad { if (!YTLAdsBlocked()) %orig; }
%end

// Ad targeting signals sent with every request.
%hook YTDataUtils
+ (id)spamSignalsDictionary { return YTLAdsBlocked() ? @{@"ms": @""} : %orig; }
+ (id)spamSignalsDictionaryWithoutIDFA { return YTLAdsBlocked() ? @{} : %orig; }
%end

%hook YTAdShieldUtils
+ (id)spamSignalsDictionary { return YTLAdsBlocked() ? @{} : %orig; }
+ (id)spamSignalsDictionaryWithoutIDFA { return YTLAdsBlocked() ? @{} : %orig; }
%end

%hook YTAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!YTLAdsBlocked()) %orig; }
%end

%hook YTAccountScopedAdsInnerTubeContextDecorator
- (void)decorateContext:(id)context { if (!YTLAdsBlocked()) %orig; }
%end

%hook YTHotConfig
- (BOOL)clientInfraClientConfigIosEnableFillingEncodedHacksInnertubeContext { return YTLAdsBlocked() ? NO : %orig; }
%end

#pragma mark - 2. Feed ads

%hook YTInnerTubeCollectionViewController
- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    if (YTLAdsBlocked()) {
        NSArray *sections = YTLIvar((id)self, @"_sectionRenderers");
        if ([sections isKindOfClass:NSArray.class]) {
            @try {
                [(id)self setValue:[YTLFilteredSectionRenderers(sections) mutableCopy] forKey:@"_sectionRenderers"];
            } @catch (__unused NSException *exception) {}
        }
    }
    %orig;
}

- (void)addSectionsFromArray:(NSArray *)array {
    %orig(YTLFilteredSectionRenderers(array));
}
%end

%hook YTArraySectionViewModel
- (id)initWithEntries:(NSArray *)entries {
    return %orig(YTLFilteredSectionEntries(entries));
}

- (id)initWithTransform:(id)transform entries:(NSArray *)entries {
    return %orig(transform, YTLFilteredSectionEntries(entries));
}

- (void)insertEntries:(NSArray *)entries atIndex:(NSUInteger)index {
    NSArray *filtered = YTLFilteredSectionEntries(entries);
    if (filtered.count || !YTLAdsBlocked()) %orig(filtered, index);
}

- (void)replaceEntry:(id)oldEntry withEntry:(id)newEntry {
    if (YTLAdsBlocked() && YTLIsAdSectionEntry(newEntry)) return;
    %orig;
}
%end

// Inline feed ads are inserted later through externally managed ad slots.
%hook YTAdElementsCellExternallyManagedSlotAdapterImpl
- (BOOL)isValidSlotType:(int)type { return YTLAdsBlocked() ? NO : %orig; }
%end

// Older YouTube versions: promoted videos in section lists.
%hook YTSectionListViewController
- (void)loadWithModel:(YTISectionListRenderer *)model {
    if (YTLAdsBlocked()) {
        NSMutableArray <YTISectionListSupportedRenderers *> *contentsArray = model.contentsArray;
        NSIndexSet *removeIndexes = [contentsArray indexesOfObjectsPassingTest:^BOOL(YTISectionListSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
            return YTLIsPromotedVideo(renderers.itemSectionRenderer.contentsArray.firstObject);
        }];
        [contentsArray removeObjectsAtIndexes:removeIndexes];
    }
    %orig;
}
%end

#pragma mark - 3. Shorts ads

%hook YTReelDataSource
- (id)makeContentModelForEntry:(id)entry {
    id model = %orig;
    return YTLAdsBlocked() && YTLIsAdReel(model) ? nil : model;
}
%end

%hook YTReelContentModel
+ (id)makeContentModelForEntry:(id)entry {
    id model = %orig;
    return YTLAdsBlocked() && YTLIsAdReel(model) ? nil : model;
}
%end

%hook YTReelInfinitePlaybackDataSource
- (id)makeContentModelForEntry:(id)entry {
    id model = %orig;
    return YTLAdsBlocked() && YTLIsAdReel(model) ? nil : model;
}

- (void)setReels:(NSMutableOrderedSet *)reels {
    if (YTLAdsBlocked() && [reels isKindOfClass:NSMutableOrderedSet.class]) {
        [reels removeObjectsAtIndexes:[reels indexesOfObjectsPassingTest:^BOOL(id reel, NSUInteger idx, BOOL *stop) {
            return YTLIsAdReel(reel);
        }]];
    }
    %orig;
}
%end

#pragma mark - 4. Shopping and product placements

// "Products in this video" panel that opens by itself on the watch page.
%hook YTWatchNextResponseViewController
- (void)loadWithModel:(id)model {
    if (YTLAdsBlocked()) {
        id onUiReady = YTLProtoValue(model, @"onUiReady");
        SEL executorSelector = NSSelectorFromString(@"yt_commandExecutorCommand");
        if ([onUiReady respondsToSelector:executorSelector]) {
            id executor = ((id (*)(id, SEL))objc_msgSend)(onUiReady, executorSelector);
            NSMutableArray *commands = YTLProtoValue(executor, @"commandsArray");
            if ([commands isKindOfClass:NSMutableArray.class]) {
                [commands removeObjectsAtIndexes:[commands indexesOfObjectsPassingTest:^BOOL(id command, NSUInteger idx, BOOL *stop) {
                    return YTLIsProductListCommand(command);
                }]];
            }
        }
        if (YTLIsProductListCommand(onUiReady)) {
            @try {
                [model setValue:nil forKey:@"onUiReady"];
            } @catch (__unused NSException *exception) {}
        }
    }
    %orig;
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)playerOverlayProvider:(YTPlayerOverlayProvider *)provider didInsertPlayerOverlay:(YTPlayerOverlay *)overlay {
    if (YTLAdsBlocked() && [[overlay overlayIdentifier] isEqualToString:@"player_overlay_product_in_video"]) return;
    %orig;
}
%end

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:@"eml.expandable_metadata.vpp"] && YTLAdsBlocked()) [self removeFromSuperview];
}
%end

%ctor {
    %init;
    YTLOverrideGetter(@"YTIPlayerResponse", @"playerAdsArray", (IMP)YTLPlayerAdsArray, &origPlayerAdsArray, "@@:");
    YTLOverrideGetter(@"YTIPlayerResponse", @"adSlotsArray", (IMP)YTLAdSlotsArray, &origAdSlotsArray, "@@:");
    YTLOverrideGetter(@"YTIPlayerResponse", @"adPlacementsArray", (IMP)YTLAdPlacementsArray, &origAdPlacementsArray, "@@:");
    YTLOverrideGetter(@"YTIClientMdxGlobalConfig", @"enableSkippableAd", (IMP)YTLEnableSkippableAd, &origEnableSkippableAd, "B@:");
}
