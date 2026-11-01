#import "YTLDownloadHUD.h"

#pragma mark - Window plumbing

static UIWindowScene *YTLActiveWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

static UIWindow *YTLAppKeyWindow(UIWindow *excluding) {
    for (UIWindow *window in YTLActiveWindowScene().windows) {
        if (window.isKeyWindow && window != excluding) return window;
    }
    return nil;
}

static UIViewController *YTLStatusBarController(UIViewController *controller, BOOL forHidden) {
    UIViewController *child = forHidden ? controller.childViewControllerForStatusBarHidden : controller.childViewControllerForStatusBarStyle;
    return child ? YTLStatusBarController(child, forHidden) : controller;
}

// Touches that don't land on the card fall through to YouTube's own window.
@interface YTLHUDWindow : UIWindow
@end

@implementation YTLHUDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

// Leaves status bar and rotation decisions to the app.
@interface YTLHUDViewController : UIViewController
@end

@implementation YTLHUDViewController
- (UIViewController *)appController {
    UIViewController *controller = YTLAppKeyWindow(self.view.window).rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (BOOL)prefersStatusBarHidden {
    UIViewController *app = [self appController];
    return app ? YTLStatusBarController(app, YES).prefersStatusBarHidden : NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    UIViewController *app = [self appController];
    return app ? YTLStatusBarController(app, NO).preferredStatusBarStyle : UIStatusBarStyleDefault;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *app = [self appController];
    return app ? app.supportedInterfaceOrientations : UIInterfaceOrientationMaskAll;
}
@end

#pragma mark - HUD

@implementation YTLDownloadHUD {
    YTLHUDWindow *_window;
    UIVisualEffectView *_card;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIProgressView *_progressView;
    UIActivityIndicatorView *_spinner;
    UIButton *_cancelButton;
    void (^_cancelHandler)(void);
    NSUInteger _generation;
}

+ (instancetype)sharedHUD {
    static YTLDownloadHUD *hud;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hud = [YTLDownloadHUD new];
    });
    return hud;
}

- (void)buildIfNeeded {
    UIWindowScene *scene = YTLActiveWindowScene();
    if (_window && (!scene || _window.windowScene == scene)) return;

    _window = scene ? [[YTLHUDWindow alloc] initWithWindowScene:scene] : [[YTLHUDWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.windowLevel = UIWindowLevelNormal + 10;
    _window.backgroundColor = UIColor.clearColor;

    YTLHUDViewController *controller = [YTLHUDViewController new];
    controller.view.backgroundColor = UIColor.clearColor;
    _window.rootViewController = controller;

    _card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 14;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [controller.view addSubview:_card];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.numberOfLines = 2;

    _detailLabel = [UILabel new];
    _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = [UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    _cancelButton.tintColor = UIColor.secondaryLabelColor;
    _cancelButton.accessibilityLabel = @"Cancel";
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel, _progressView]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 6;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_spinner, texts, _cancelButton]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_card.contentView addSubview:row];

    UILayoutGuide *safeArea = controller.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [_card.widthAnchor constraintEqualToConstant:480];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [_card.leadingAnchor constraintGreaterThanOrEqualToAnchor:safeArea.leadingAnchor constant:16],
        [_card.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor constant:-16],
        preferredWidth,
        // Sit above YouTube's tab bar / mini player.
        [_card.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-60],
        [row.leadingAnchor constraintEqualToAnchor:_card.contentView.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:_card.contentView.trailingAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:_card.contentView.topAnchor constant:12],
        [row.bottomAnchor constraintEqualToAnchor:_card.contentView.bottomAnchor constant:-12],
        [_cancelButton.widthAnchor constraintEqualToConstant:28],
        [_cancelButton.heightAnchor constraintEqualToConstant:28],
    ]];

    _window.hidden = YES;
}

- (void)cancelTapped {
    void (^handler)(void) = _cancelHandler;
    if (handler) handler();
}

- (void)presentCard {
    if (!_window.hidden) return;
    _window.hidden = NO;
    _card.alpha = 0;
    _card.transform = CGAffineTransformMakeTranslation(0, 16);
    [UIView animateWithDuration:0.25 animations:^{
        self->_card.alpha = 1;
        self->_card.transform = CGAffineTransformIdentity;
    }];
}

- (void)showWithTitle:(NSString *)title cancelHandler:(void (^)(void))cancelHandler {
    [self buildIfNeeded];
    _generation++;
    _cancelHandler = [cancelHandler copy];
    _cancelButton.hidden = cancelHandler == nil;
    [self updateTitle:title detail:nil progress:-1];
    [self presentCard];
}

- (void)updateTitle:(NSString *)title detail:(NSString *)detail progress:(float)progress {
    if (title) _titleLabel.text = title;
    _detailLabel.text = detail;
    _detailLabel.hidden = detail.length == 0;

    BOOL indeterminate = progress < 0;
    _progressView.hidden = indeterminate;
    if (!indeterminate) [_progressView setProgress:MIN(progress, 1.0f) animated:NO];
    indeterminate ? [_spinner startAnimating] : [_spinner stopAnimating];
}

- (void)flashMessage:(NSString *)message {
    [self buildIfNeeded];
    NSUInteger generation = ++_generation;
    _cancelHandler = nil;
    _cancelButton.hidden = YES;
    _titleLabel.text = message;
    _detailLabel.hidden = YES;
    _progressView.hidden = YES;
    [_spinner stopAnimating];
    [self presentCard];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_generation == generation) [self dismiss];
    });
}

- (void)dismiss {
    if (!_window || _window.hidden) return;
    _cancelHandler = nil;
    NSUInteger generation = _generation;
    [UIView animateWithDuration:0.2 animations:^{
        self->_card.alpha = 0;
    } completion:^(BOOL finished) {
        // A new message may have been shown while fading out.
        if (self->_generation == generation) self->_window.hidden = YES;
        else self->_card.alpha = 1;
    }];
}

@end
