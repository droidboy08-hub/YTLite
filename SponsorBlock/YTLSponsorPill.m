#import "YTLSponsorPill.h"

static const CGFloat kYTLPillHeight = 34;
static const CGFloat kYTLPillMargin = 12;
static const CGFloat kYTLPillLeading = 12;
static const CGFloat kYTLPillTrailing = 14;
static const CGFloat kYTLPillIconSize = 16;
static const CGFloat kYTLPillSpacing = 6;

@implementation YTLSponsorPill {
    UIVisualEffectView *_background;
    UIImageView *_iconView;
    UILabel *_label;
    BOOL _showing;
    CGSize _laidOutContainerSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _background = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        _background.userInteractionEnabled = NO;
        _background.layer.cornerRadius = kYTLPillHeight / 2;
        _background.clipsToBounds = YES;
        [self addSubview:_background];

        _iconView = [UIImageView new];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.whiteColor;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        self.alpha = 0;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        // Stays in the bottom-right corner while the player resizes (fullscreen, rotation).
        self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)tapped {
    if (self.actionHandler) self.actionHandler();
}

- (BOOL)isShowing {
    return _showing;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.transform = highlighted ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity;
}

- (void)setSymbolName:(NSString *)symbolName text:(NSString *)text {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    _iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    _label.text = text;
    self.accessibilityLabel = text;
    if (self.superview) [self layoutInContainer:self.superview];
}

- (void)layoutInContainer:(UIView *)container {
    CGRect bounds = container.bounds;
    UIEdgeInsets safeArea = container.safeAreaInsets;
    CGFloat contentInset = kYTLPillLeading + kYTLPillIconSize + kYTLPillSpacing + kYTLPillTrailing;
    CGFloat maxWidth = MAX(0, CGRectGetWidth(bounds) - safeArea.left - safeArea.right - 2 * kYTLPillMargin);
    CGFloat textWidth = ceil([_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, kYTLPillHeight)].width);
    CGFloat width = MIN(maxWidth, contentInset + textWidth);
    // Above the progress bar / bottom controls, which take more room in bigger players.
    CGFloat bottomInset = MAX(48, CGRectGetHeight(bounds) * 0.18) + safeArea.bottom;

    _laidOutContainerSize = bounds.size;
    self.transform = CGAffineTransformIdentity;
    self.frame = CGRectMake(CGRectGetWidth(bounds) - width - kYTLPillMargin - safeArea.right, CGRectGetHeight(bounds) - kYTLPillHeight - bottomInset, width, kYTLPillHeight);
    _background.frame = self.bounds;
    _iconView.frame = CGRectMake(kYTLPillLeading, (kYTLPillHeight - kYTLPillIconSize) / 2, kYTLPillIconSize, kYTLPillIconSize);
    CGFloat labelX = kYTLPillLeading + kYTLPillIconSize + kYTLPillSpacing;
    _label.frame = CGRectMake(labelX, 0, MAX(0, width - labelX - kYTLPillTrailing), kYTLPillHeight);
}

- (void)showInView:(UIView *)container {
    // Called on every playback-time update while visible: only lay out when something changed.
    BOOL needsLayout = self.superview != container || !CGSizeEqualToSize(_laidOutContainerSize, container.bounds.size);
    if (self.superview != container) [container addSubview:self];
    if (needsLayout) [self layoutInContainer:container];
    if (container.subviews.lastObject != self) [container bringSubviewToFront:self];
    // The mini player is too small for it; keep the state and show it again when it grows.
    self.hidden = CGRectGetWidth(container.bounds) < 260 || CGRectGetHeight(container.bounds) < 140;

    _showing = YES;
    if (self.alpha < 1) {
        [UIView animateWithDuration:0.2 animations:^{
            self.alpha = 1;
        }];
    }
}

- (void)hide {
    if (!_showing) return;
    _showing = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        // It may have been shown again while fading out.
        if (!self->_showing) [self removeFromSuperview];
    }];
}

@end
