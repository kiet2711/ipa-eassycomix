#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <dlfcn.h>
#import <unistd.h>
#import <fcntl.h>

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif
#ifndef SEG_AUTH_CONST
#define SEG_AUTH_CONST "__AUTH_CONST"
#endif
#ifndef SEG_AUTH
#define SEG_AUTH "__AUTH"
#endif

/**
 * EasyComix Gemini Tweak (Dylib)
 * - Chặn toàn diện 100% request dịch (Dịch Classic Chapter & Dịch Live Scroll/Paged) chuyển qua Gemini API
 * - Mở khóa vĩnh viễn hạn mức PRO (999,999 lượt cho cả Dịch thường & Dịch Live)
 * - Tự động tái tạo JSON đúng 100% theo kiểu Swift Decodable của EasyComix
 * - Tự động xoay Key khi gặp lỗi Rate Limit (HTTP 429) hoặc lỗi Key
 * - Tùy chọn model: gemini-3.5-flash-lite (mặc định), gemini-3.1-flash-lite
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref  = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";
static NSString *const kGemini35Model   = @"gemini-3.5-flash-lite"; // Mặc định
static NSString *const kGemini31Model   = @"gemini-3.1-flash-lite";

static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// QUẢN LÝ KEY POOL & MODEL
// =========================================================================

static NSArray<NSString *> *ParseAndCleanGeminiKeys(NSString *rawInput) {
    if (!rawInput || [rawInput length] == 0) return @[];
    
    // Tách theo nhiều loại ký tự phân cách: xuống dòng, tab, phẩy, chấm phẩy, khoảng trắng, gạch đứng, dấu nháy, ngoặc vuông/nhọn
    NSCharacterSet *delimiters = [NSCharacterSet characterSetWithCharactersInString:@"\r\n,;|\"'` \t[]{}()"];
    NSArray *components = [rawInput componentsSeparatedByCharactersInSet:delimiters];
    
    NSMutableArray<NSString *> *validKeys = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    
    for (NSString *item in components) {
        NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Loại bỏ các tiền tố như gạch đầu dòng, số thứ tự (ví dụ: "1.", "-", "*")
        while ([trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"*"] || [trimmed hasPrefix:@">"]) {
            trimmed = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        
        // Gemini API Key tiêu chuẩn thường bắt đầu bằng AIzaSy và có độ dài ~39 ký tự
        // Chấp nhận mọi chuỗi hợp lệ >= 20 ký tự không chứa khoảng trắng
        if ([trimmed length] >= 20 && ![seenKeys containsObject:trimmed]) {
            [validKeys addObject:trimmed];
            [seenKeys addObject:trimmed];
        }
    }
    return validKeys;
}

static NSArray<NSString *> *GetGeminiKeyPool(void) {
    NSString *rawKeys = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref];
    return ParseAndCleanGeminiKeys(rawKeys);
}

static NSString *GetSavedGeminiModel(void) {
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiModelPref];
    if ([model isEqualToString:kGemini31Model]) {
        return kGemini31Model;
    }
    return kGemini35Model;
}

static void SaveGeminiSettings(NSString *rawKeys, NSString *model) {
    NSArray<NSString *> *parsed = ParseAndCleanGeminiKeys(rawKeys);
    NSString *cleanKeysText = [parsed componentsJoinedByString:@"\n"];
    
    NSString *safeModel = [model isEqualToString:kGemini31Model] ? kGemini31Model : kGemini35Model;
    
    [[NSUserDefaults standardUserDefaults] setObject:cleanKeysText forKey:kGeminiKeysPref];
    [[NSUserDefaults standardUserDefaults] setObject:safeModel forKey:kGeminiModelPref];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    @synchronized (kGeminiKeysPref) {
        sCurrentKeyIndex = 0;
    }
    LOG(@"Đã lưu cấu hình: %lu keys, model: %@", (unsigned long)[parsed count], safeModel);
}

static NSString *GetKeyForAttempt(NSUInteger attempt, NSUInteger *outIndex, NSUInteger *outTotal) {
    NSArray<NSString *> *keys = GetGeminiKeyPool();
    if (outTotal) *outTotal = [keys count];
    if ([keys count] == 0) {
        if (outIndex) *outIndex = 0;
        return @"";
    }
    
    NSUInteger idx = 0;
    @synchronized (kGeminiKeysPref) {
        idx = (sCurrentKeyIndex + attempt) % [keys count];
    }
    if (outIndex) *outIndex = idx;
    return keys[idx];
}

static void RotateToNextKey(void) {
    NSArray<NSString *> *keys = GetGeminiKeyPool();
    if ([keys count] > 1) {
        @synchronized (kGeminiKeysPref) {
            sCurrentKeyIndex = (sCurrentKeyIndex + 1) % [keys count];
            LOG(@"Đã tự động xoay sang Key #%lu/%lu", (unsigned long)(sCurrentKeyIndex + 1), (unsigned long)[keys count]);
        }
    }
}

// =========================================================================
// GIAO DIỆN CÀI ĐẶT: POPUP QUẢN LÝ NHIỀU KEY & MODEL (MODAL TỰ TẠO)
// =========================================================================

@interface GeminiSettingsViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) UISegmentedControl *modelSegment;
@property (nonatomic, strong) UIButton *btnPaste;
@property (nonatomic, strong) UIButton *btnClean;
@property (nonatomic, strong) UIButton *btnClear;
@property (nonatomic, strong) UIButton *btnSave;
@property (nonatomic, strong) UIButton *btnClose;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterYConstraint;
@end

@implementation GeminiSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    
    // Tap ngoài để ẩn bàn phím
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
    
    // Khung Card
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1.0];
        }
        return [UIColor whiteColor];
    }];
    self.cardView.layer.cornerRadius = 18.0;
    self.cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardView.layer.shadowOffset = CGSizeMake(0, 8);
    self.cardView.layer.shadowRadius = 20.0;
    self.cardView.layer.shadowOpacity = 0.35;
    [self.view addSubview:self.cardView];
    
    // Stack chính
    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.spacing = 12.0;
    mainStack.layoutMargins = UIEdgeInsetsMake(18, 18, 18, 18);
    mainStack.layoutMarginsRelativeArrangement = YES;
    [self.cardView addSubview:mainStack];
    
    // Header Stack: Title + Close Button
    UIStackView *headerStack = [[UIStackView alloc] init];
    headerStack.axis = UILayoutConstraintAxisHorizontal;
    headerStack.alignment = UIStackViewAlignmentCenter;
    headerStack.distribution = UIStackViewDistributionFill;
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"🤖 Gemini Key Pool & Model";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.titleLabel.textColor = [UIColor labelColor];
    [headerStack addArrangedSubview:self.titleLabel];
    
    self.btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.btnClose setTitle:@"✕" forState:UIControlStateNormal];
    self.btnClose.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.btnClose setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [self.btnClose addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [self.btnClose setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [headerStack addArrangedSubview:self.btnClose];
    
    [mainStack addArrangedSubview:headerStack];
    
    // Status Label
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.statusLabel.numberOfLines = 2;
    [mainStack addArrangedSubview:self.statusLabel];
    
    // Text View Container (có placeholder)
    UIView *tvContainer = [[UIView alloc] init];
    tvContainer.translatesAutoresizingMaskIntoConstraints = NO;
    tvContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tvContainer.layer.cornerRadius = 10.0;
    tvContainer.layer.borderWidth = 0.8;
    tvContainer.layer.borderColor = [UIColor separatorColor].CGColor;
    tvContainer.clipsToBounds = YES;
    
    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.textColor = [UIColor labelColor];
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.spellCheckingType = UITextSpellCheckingTypeNo;
    self.textView.delegate = self;
    [tvContainer addSubview:self.textView];
    
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.text = @"Dán danh sách API Key tại đây...\n(AIzaSy...)\nMỗi dòng 1 key hoặc cách bằng dấu phẩy.";
    self.placeholderLabel.font = [UIFont systemFontOfSize:12];
    self.placeholderLabel.textColor = [UIColor placeholderTextColor];
    self.placeholderLabel.numberOfLines = 0;
    self.placeholderLabel.userInteractionEnabled = NO;
    [tvContainer addSubview:self.placeholderLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:tvContainer.topAnchor constant:4],
        [self.textView.leadingAnchor constraintEqualToAnchor:tvContainer.leadingAnchor constant:6],
        [self.textView.trailingAnchor constraintEqualToAnchor:tvContainer.trailingAnchor constant:-6],
        [self.textView.bottomAnchor constraintEqualToAnchor:tvContainer.bottomAnchor constant:-4],
        [self.textView.heightAnchor constraintEqualToConstant:120],
        
        [self.placeholderLabel.topAnchor constraintEqualToAnchor:tvContainer.topAnchor constant:12],
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:tvContainer.leadingAnchor constant:12],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:tvContainer.trailingAnchor constant:-12]
    ]];
    
    [mainStack addArrangedSubview:tvContainer];
    
    // Quick Actions Row
    UIStackView *actionsRow = [[UIStackView alloc] init];
    actionsRow.axis = UILayoutConstraintAxisHorizontal;
    actionsRow.distribution = UIStackViewDistributionFillEqually;
    actionsRow.spacing = 8.0;
    
    self.btnPaste = [self createSmallButton:@"📋 Dán Clipboard" action:@selector(handlePaste)];
    self.btnClean = [self createSmallButton:@"🧹 Dọn dẹp Key" action:@selector(handleClean)];
    self.btnClear = [self createSmallButton:@"🗑️ Xóa hết" action:@selector(handleClear)];
    
    [actionsRow addArrangedSubview:self.btnPaste];
    [actionsRow addArrangedSubview:self.btnClean];
    [actionsRow addArrangedSubview:self.btnClear];
    [mainStack addArrangedSubview:actionsRow];
    
    // Model Selection
    UILabel *modelTitle = [[UILabel alloc] init];
    modelTitle.text = @"Chọn Model Gemini:";
    modelTitle.font = [UIFont boldSystemFontOfSize:12];
    modelTitle.textColor = [UIColor secondaryLabelColor];
    [mainStack addArrangedSubview:modelTitle];
    
    self.modelSegment = [[UISegmentedControl alloc] initWithItems:@[ @"3.5 Flash Lite (Mặc định)", @"3.1 Flash Lite" ]];
    NSString *currentModel = GetSavedGeminiModel();
    if ([currentModel isEqualToString:kGemini31Model]) {
        self.modelSegment.selectedSegmentIndex = 1;
    } else {
        self.modelSegment.selectedSegmentIndex = 0; // gemini-3.5-flash-lite mặc định
    }
    [mainStack addArrangedSubview:self.modelSegment];
    
    // Save Button
    self.btnSave = [UIButton buttonWithType:UIButtonTypeSystem];
    self.btnSave.translatesAutoresizingMaskIntoConstraints = NO;
    [self.btnSave setTitle:@"💾 Lưu cấu hình" forState:UIControlStateNormal];
    self.btnSave.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.btnSave setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.btnSave.backgroundColor = [UIColor colorWithRed:0.08 green:0.52 blue:1.0 alpha:1.0];
    self.btnSave.layer.cornerRadius = 10.0;
    [self.btnSave addTarget:self action:@selector(handleSave) forControlEvents:UIControlEventTouchUpInside];
    [self.btnSave.heightAnchor constraintEqualToConstant:44].active = YES;
    [mainStack addArrangedSubview:self.btnSave];
    
    // Nạp dữ liệu hiện tại
    NSArray<NSString *> *existing = GetGeminiKeyPool();
    if ([existing count] > 0) {
        self.textView.text = [existing componentsJoinedByString:@"\n"];
    }
    [self updateKeyCountDisplay];
    
    // Layout Constraints cho Card
    self.cardCenterYConstraint = [self.cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.cardCenterYConstraint,
        [self.cardView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.cardView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.cardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.cardView.widthAnchor constraintLessThanOrEqualToConstant:400],
        [self.cardView.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        
        [mainStack.topAnchor constraintEqualToAnchor:self.cardView.topAnchor],
        [mainStack.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
        [mainStack.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor],
        [mainStack.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor]
    ]];
}

- (UIButton *)createSmallButton:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor tertiarySystemFillColor];
    btn.layer.cornerRadius = 6.0;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:28].active = YES;
    return btn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    CGRect kbFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    CGFloat offset = -(kbFrame.size.height / 2.0) + 30;
    self.cardCenterYConstraint.constant = offset;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    
    self.cardCenterYConstraint.constant = 0;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)textViewDidChange:(UITextView *)textView {
    [self updateKeyCountDisplay];
}

- (void)updateKeyCountDisplay {
    NSArray<NSString *> *keys = ParseAndCleanGeminiKeys(self.textView.text);
    NSUInteger count = [keys count];
    if (count == 0) {
        self.statusLabel.text = @"⚠️ Chưa có Key nào. Dán 1 hoặc nhiều key để dịch.";
        self.statusLabel.textColor = [UIColor systemOrangeColor];
        self.placeholderLabel.hidden = (self.textView.text.length > 0);
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ Đã nhận diện %lu Key hợp lệ (Tự động xoay vòng)", (unsigned long)count];
        self.statusLabel.textColor = [UIColor systemGreenColor];
        self.placeholderLabel.hidden = YES;
    }
}

- (void)handlePaste {
    NSString *pb = [UIPasteboard generalPasteboard].string;
    if (pb.length > 0) {
        if (self.textView.text.length > 0) {
            self.textView.text = [NSString stringWithFormat:@"%@\n%@", self.textView.text, pb];
        } else {
            self.textView.text = pb;
        }
        [self handleClean];
    }
}

- (void)handleClean {
    NSArray<NSString *> *keys = ParseAndCleanGeminiKeys(self.textView.text);
    self.textView.text = [keys componentsJoinedByString:@"\n"];
    [self updateKeyCountDisplay];
}

- (void)handleClear {
    self.textView.text = @"";
    [self updateKeyCountDisplay];
}

- (void)handleSave {
    [self dismissKeyboard];
    
    NSString *selectedModel = (self.modelSegment.selectedSegmentIndex == 1) ? kGemini31Model : kGemini35Model;
    
    SaveGeminiSettings(self.textView.text, selectedModel);
    
    [self.btnSave setTitle:@"✓ Đã lưu thành công!" forState:UIControlStateNormal];
    self.btnSave.backgroundColor = [UIColor systemGreenColor];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)handleClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIViewController *GetTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if ([w isKeyWindow]) {
            keyWindow = w;
            break;
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

static void ShowGeminiSettingsPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = GetTopViewController();
        if (!topVC) return;
        if ([topVC isKindOfClass:[GeminiSettingsViewController class]]) {
            return;
        }
        
        GeminiSettingsViewController *vc = [[GeminiSettingsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [topVC presentViewController:vc animated:YES completion:nil];
    });
}

// Nút nổi kéo thả trên màn hình
@interface GeminiFloatingButton : UIButton
@end

@implementation GeminiFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.52 blue:1.0 alpha:0.92];
        [self setTitle:@"🤖 Key" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.35;
        self.clipsToBounds = NO;
        
        [self addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)buttonTapped {
    ShowGeminiSettingsPopup();
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

static void AddFloatingButtonToWindow(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if ([w isKeyWindow]) {
                    keyWindow = w;
                    break;
                }
            }
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                GeminiFloatingButton *btn = [[GeminiFloatingButton alloc] initWithFrame:CGRectMake(16, 160, 52, 52)];
                [keyWindow addSubview:btn];
                [keyWindow bringSubviewToFront:btn];
                
                if ([GetGeminiKeyPool() count] == 0) {
                    ShowGeminiSettingsPopup();
                }
            }
        });
    });
}

// =========================================================================
// GỌI GOOGLE GEMINI REST API
// =========================================================================

static void CallGeminiTranslation(NSArray<NSString *> *texts,
                                  NSString *srcLang,
                                  NSString *tgtLang,
                                  NSString *userContext,
                                  NSUInteger attempt,
                                  NSUInteger maxTries,
                                  void (^completion)(NSArray<NSString *> *translatedTexts)) {
    
    if (!texts || [texts count] == 0) {
        completion(@[]);
        return;
    }
    
    NSUInteger keyIdx = 0;
    NSUInteger totalKeys = 0;
    NSString *currentKey = GetKeyForAttempt(attempt, &keyIdx, &totalKeys);
    NSString *model = GetSavedGeminiModel();
    
    if ([currentKey length] == 0) {
        ShowGeminiSettingsPopup();
        completion(texts);
        return;
    }
    
    LOG(@"[Gemini] Bắt đầu dịch %lu câu bằng Key #%lu/%lu (Model: %@)...", (unsigned long)[texts count], (unsigned long)(keyIdx + 1), (unsigned long)totalKeys, model);
    
    NSError *error = nil;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    NSString *contextLine = ([userContext isKindOfClass:[NSString class]] && [userContext length] > 0)
        ? [NSString stringWithFormat:@"\nNgữ cảnh truyện: %@\n", userContext]
        : @"";
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh / manga / webtoon chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"%@"
        @"Quy tắc dịch:\n"
        @"- Dịch văn phong tự nhiên, cảm xúc, chuẩn ngữ cảnh thoại truyện tranh.\n"
        @"- Trả về DUY NHẤT một JSON Array mảng chuỗi theo đúng thứ tự (ví dụ: [\"câu 1\", \"câu 2\"]).\n"
        @"- Số phần tử trong mảng kết quả BẮT BUỘC phải bằng đúng %lu.\n"
        @"- KHÔNG thêm bất kỳ markdown hoặc giải thích nào khác.\n\n"
        @"Danh sách cần dịch:\n%@",
        srcLang, tgtLang, contextLine, (unsigned long)[texts count], textsJsonString];
    
    NSDictionary *payload = @{
        @"contents": @[
            @{ @"parts": @[ @{ @"text": prompt } ] }
        ],
        @"generationConfig": @{
            @"responseMimeType": @"application/json",
            @"responseSchema": @{
                @"type": @"ARRAY",
                @"items": @{ @"type": @"STRING" },
                @"minItems": @([texts count]),
                @"maxItems": @([texts count])
            },
            @"temperature": @0.35
        }
    };
    
    NSString *geminiEndpoint = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent",
        model];
    
    NSMutableURLRequest *geminiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:geminiEndpoint]];
    [geminiReq setHTTPMethod:@"POST"];
    [geminiReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [geminiReq setValue:currentKey forHTTPHeaderField:@"x-goog-api-key"];
    [geminiReq setTimeoutInterval:45.0];
    [geminiReq setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil]];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    [[session dataTaskWithRequest:geminiReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *netError) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse ? httpResponse.statusCode : 0;
        
        LOG(@"Gemini (%@) response status: %ld", model, (long)statusCode);
        
        BOOL isKeyOrModelError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404);
        
        if ((isKeyOrModelError || netError) && attempt < maxTries - 1) {
            LOG(@"Lỗi gọi Gemini (HTTP %ld với Key #%lu/%lu). Đang xoay sang Key tiếp theo...", (long)statusCode, (unsigned long)(keyIdx + 1), (unsigned long)totalKeys);
            RotateToNextKey();
            CallGeminiTranslation(texts, srcLang, tgtLang, userContext, attempt + 1, maxTries, completion);
            return;
        }
        
        NSArray *translatedList = nil;
        if (!netError && data && statusCode == 200) {
            NSDictionary *geminiRes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *candidates = [geminiRes[@"candidates"] isKindOfClass:[NSArray class]] ? geminiRes[@"candidates"] : nil;
            NSDictionary *candidate = [candidates.firstObject isKindOfClass:[NSDictionary class]] ? candidates.firstObject : nil;
            NSDictionary *content = [candidate[@"content"] isKindOfClass:[NSDictionary class]] ? candidate[@"content"] : nil;
            NSArray *parts = [content[@"parts"] isKindOfClass:[NSArray class]] ? content[@"parts"] : nil;
            NSDictionary *part = [parts.firstObject isKindOfClass:[NSDictionary class]] ? parts.firstObject : nil;
            NSString *rawText = [part[@"text"] isKindOfClass:[NSString class]] ? part[@"text"] : nil;
            if (rawText) {
                NSString *cleanText = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([cleanText hasPrefix:@"```json"]) {
                    cleanText = [cleanText substringFromIndex:7];
                } else if ([cleanText hasPrefix:@"```"]) {
                    cleanText = [cleanText substringFromIndex:3];
                }
                if ([cleanText hasSuffix:@"```"]) {
                    cleanText = [cleanText substringToIndex:[cleanText length] - 3];
                }
                cleanText = [cleanText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                NSData *cleanData = [cleanText dataUsingEncoding:NSUTF8StringEncoding];
                id parsed = [NSJSONSerialization JSONObjectWithData:cleanData options:0 error:nil];
                if ([parsed isKindOfClass:[NSArray class]]) {
                    translatedList = (NSArray *)parsed;
                } else if ([parsed isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *pDict = (NSDictionary *)parsed;
                    for (NSString *k in @[@"translations", @"result", @"data", @"translated_texts"]) {
                        if ([pDict[k] isKindOfClass:[NSArray class]]) {
                            translatedList = (NSArray *)pDict[k];
                            break;
                        }
                    }
                }
            }
        }
        
        // Ghép bản dịch đảm bảo đủ số lượng phần tử của texts
        NSMutableArray<NSString *> *finalResult = [NSMutableArray array];
        for (NSUInteger i = 0; i < [texts count]; i++) {
            if (translatedList && i < [translatedList count] && [translatedList[i] isKindOfClass:[NSString class]]) {
                [finalResult addObject:translatedList[i]];
            } else {
                [finalResult addObject:texts[i]];
            }
        }
        
        LOG(@"Dịch hoàn tất %lu câu bằng Gemini (%@)!", (unsigned long)[finalResult count], model);
        completion(finalResult);
    }] resume];
}

// =========================================================================
// TIỆN ÍCH PHÂN TÍCH REQUEST BODY & TẠO RESPONSE QUOTA PRO VĨNH VIỄN
// =========================================================================

static NSData *RequestBodyData(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (body.length > 0) return body;

    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) return nil;

    NSMutableData *streamData = [NSMutableData data];
    uint8_t buffer[8192];
    [stream open];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count > 0) {
            [streamData appendBytes:buffer length:(NSUInteger)count];
        } else {
            break;
        }
    }
    [stream close];
    return streamData.length > 0 ? streamData : nil;
}

static NSDictionary *TranslationPayloadFromBodyData(NSData *bodyData) {
    if (bodyData.length == 0) return nil;
    id body = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    if (![body isKindOfClass:[NSDictionary class]]) return nil;
    id nestedData = ((NSDictionary *)body)[@"data"];
    return [nestedData isKindOfClass:[NSDictionary class]] ? nestedData : body;
}

static NSString *PayloadString(NSDictionary *payload, NSArray<NSString *> *keys, NSString *fallback) {
    for (NSString *key in keys) {
        id value = payload[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return fallback;
}

static NSString *ExtractTextFromBubble(id item) {
    if ([item isKindOfClass:[NSString class]]) return (NSString *)item;
    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)item;
        for (NSString *k in @[@"text", @"originalText", @"sourceText", @"recognizedText"]) {
            if ([d[k] isKindOfClass:[NSString class]] && [d[k] length] > 0) {
                return d[k];
            }
        }
    }
    return @"";
}

/**
 * Cấu trúc Response Quota PRO chuẩn theo đúng Decodable của Swift EasyComix:
 * QuotaUsageResponse: { quota: QuotaInfo, liveQuota: QuotaInfo }
 * QuotaInfo: { tier: "pro", remaining: 999999, resetAt: null }
 */
static NSDictionary *ProQuotaInfoDict(void) {
    return @{
        @"tier": @"pro",
        @"remaining": @999999,
        @"resetAt": [NSNull null]
    };
}

static NSDictionary *ProQuotaUsageResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"quota": ProQuotaInfoDict(),
            @"liveQuota": ProQuotaInfoDict(),
            @"novelQuota": ProQuotaInfoDict()
        },
        @"meta": @{
            @"quota": ProQuotaInfoDict()
        }
    };
}

static NSDictionary *ProQuotaConfigResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tiers": @{
                @"free": @{ @"maxCalls": @999999 },
                @"trial": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            },
            @"live": @{
                @"free": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            },
            @"novel": @{
                @"free": @{ @"maxCalls": @999999 },
                @"pro": @{ @"maxCalls": @999999 }
            }
        }
    };
}



/**
 * Phản hồi Subscriber giả lập RevenueCat v1 (Hiển thị PRO Lifetime trên toàn bộ UI)
 */
static NSDictionary *RevenueCatProSubscriberResponse(void) {
    NSString *futureDate = @"2099-12-31T23:59:59Z";
    NSString *pastDate   = @"2024-01-01T00:00:00Z";
    NSString *productId  = @"com.easycomix.pro.yearly";
    
    NSDictionary *entitlementInfo = @{
        @"expires_date": futureDate,
        @"grace_period_expires_date": [NSNull null],
        @"product_identifier": productId,
        @"purchase_date": pastDate
    };
    
    NSDictionary *subscriptionInfo = @{
        @"billing_issues_detected_at": [NSNull null],
        @"expires_date": futureDate,
        @"grace_period_expires_date": [NSNull null],
        @"is_sandbox": @NO,
        @"original_purchase_date": pastDate,
        @"ownership_type": @"PURCHASED",
        @"period_type": @"normal",
        @"purchase_date": pastDate,
        @"store": @"app_store",
        @"unsubscribe_detected_at": [NSNull null]
    };
    
    return @{
        @"request_date": @"2026-09-01T05:00:00Z",
        @"request_date_ms": @1788220800000,
        @"entitlement_verification": @1,
        @"schema_version": @"3",
        @"original_source": @"main",
        @"subscriber": @{
            @"original_app_user_id": @"$RCAnonymousID:easycomix_gemini_pro",
            @"original_application_version": @"1.0",
            @"original_purchase_date": pastDate,
            @"first_seen": pastDate,
            @"last_seen": @"2026-09-01T05:00:00Z",
            @"management_url": @"https://apps.apple.com/account/subscriptions",
            @"entitlements": @{
                @"EasyComix Pro": entitlementInfo,
                @"pro": entitlementInfo,
                @"premium": entitlementInfo,
                @"easycomix_pro": entitlementInfo,
                @"full_access": entitlementInfo
            },
            @"subscriptions": @{
                productId: subscriptionInfo,
                @"com.easycomix.pro.monthly": subscriptionInfo,
                @"com.easycomix.pro.weekly": subscriptionInfo
            },
            @"non_subscriptions": @{},
            @"other_purchases": @{}
        }
    };
}

// Xử lý và tạo Response Dịch thuật cho cả Live và Classic
static void ProcessTranslatePayload(NSDictionary *payload, void (^completion)(NSDictionary *responseObject)) {
    NSString *source = PayloadString(payload, @[ @"sourceLanguage", @"sourceLang", @"srcLang" ], @"auto");
    NSString *target = PayloadString(payload, @[ @"targetLanguage", @"targetLang", @"tgtLang" ], @"vi");
    NSString *userContext = PayloadString(payload, @[ @"userContext", @"storyContext", @"context" ], @"");
    
    // A0. DỊCH TIỂU THUYẾT (Novel Reader) gửi mảng 'paragraphs' [{ "id": 0, "text": "..." }]
    id rawParagraphs = payload[@"paragraphs"];
    if ([rawParagraphs isKindOfClass:[NSArray class]]) {
        NSArray *paragraphs = (NSArray *)rawParagraphs;
        if ([paragraphs count] == 0) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": @[],
                    @"sourceLang": source ?: @"auto",
                    @"sessionRemainingChars": @999999,
                    @"context": userContext ?: @""
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
            return;
        }
        
        NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
        for (id item in paragraphs) {
            NSString *t = ExtractTextFromBubble(item);
            [textsToTranslate addObject:t];
        }
        
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(textsToTranslate, source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            NSMutableArray *translatedItems = [NSMutableArray array];
            for (NSUInteger i = 0; i < [paragraphs count]; i++) {
                id item = paragraphs[i];
                NSNumber *pId = @(i);
                if ([item isKindOfClass:[NSDictionary class]] && item[@"id"] != nil) {
                    pId = @([item[@"id"] longLongValue]);
                }
                NSString *transText = (i < [translatedTexts count]) ? translatedTexts[i] : @"";
                if ([transText length] == 0) {
                    transText = ExtractTextFromBubble(item);
                }
                [translatedItems addObject:@{
                    @"id": pId,
                    @"text": transText ?: @""
                }];
            }
            
            NSMutableDictionary *dataDict = [NSMutableDictionary dictionary];
            dataDict[@"translations"] = translatedItems;
            dataDict[@"sourceLang"] = source ?: @"auto";
            dataDict[@"sessionRemainingChars"] = @999999;
            if ([userContext length] > 0) {
                dataDict[@"context"] = userContext;
            }
            
            completion(@{
                @"success": @YES,
                @"data": dataDict,
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // A. DỊCH LIVE (hoặc Chapter Backend) gửi mảng 'bubbles' [{ "id": 0, "text": "..." }]
    id rawBubbles = payload[@"bubbles"];
    if ([rawBubbles isKindOfClass:[NSArray class]]) {
        NSArray *bubbles = (NSArray *)rawBubbles;
        if ([bubbles count] == 0) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": @[],
                    @"context": userContext ?: @""
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
            return;
        }
        
        NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
        for (id item in bubbles) {
            NSString *t = ExtractTextFromBubble(item);
            [textsToTranslate addObject:t];
        }
        
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(textsToTranslate, source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            NSMutableArray *translatedItems = [NSMutableArray array];
            for (NSUInteger i = 0; i < [bubbles count]; i++) {
                id item = bubbles[i];
                NSNumber *bubbleId = @(i);
                if ([item isKindOfClass:[NSDictionary class]] && item[@"id"] != nil) {
                    bubbleId = @([item[@"id"] longLongValue]);
                }
                NSString *transText = (i < [translatedTexts count]) ? translatedTexts[i] : @"";
                if ([transText length] == 0) {
                    transText = ExtractTextFromBubble(item);
                }
                [translatedItems addObject:@{
                    @"id": bubbleId,
                    @"text": transText ?: @""
                }];
            }
            
            NSMutableDictionary *dataDict = [NSMutableDictionary dictionary];
            dataDict[@"translations"] = translatedItems;
            if ([userContext length] > 0) {
                dataDict[@"context"] = userContext;
            }
            
            completion(@{
                @"success": @YES,
                @"data": dataDict,
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // B. DỊCH CLASSIC / SINGLE PAGE / CHAPTER: gửi mảng 'texts' ["câu 1", "câu 2"]
    id rawTexts = payload[@"texts"];
    if ([rawTexts isKindOfClass:[NSArray class]]) {
        NSArray *texts = (NSArray *)rawTexts;
        if ([texts count] == 0) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
            return;
        }
        
        NSMutableArray<NSString *> *textsToTranslate = [NSMutableArray array];
        for (id item in texts) {
            NSString *t = ExtractTextFromBubble(item);
            [textsToTranslate addObject:t];
        }
        
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(textsToTranslate, source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedTexts ?: @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // C. SINGLE TEXT:
    NSString *singleText = payload[@"text"] ?: @"";
    if ([singleText length] > 0) {
        NSUInteger keyCount = [GetGeminiKeyPool() count];
        CallGeminiTranslation(@[ singleText ], source, target, userContext, 0, MAX((NSUInteger)1, keyCount), ^(NSArray<NSString *> *translatedTexts) {
            completion(@{
                @"success": @YES,
                @"data": @{
                    @"translations": translatedTexts ?: @[]
                },
                @"meta": @{ @"quota": ProQuotaInfoDict() }
            });
        });
        return;
    }

    // D. FALLBACK RỖNG
    completion(@{
        @"success": @YES,
        @"data": @{
            @"translations": @[]
        },
        @"meta": @{ @"quota": ProQuotaInfoDict() }
    });
}

// =========================================================================
// NSURLPROTOCOL: INTERCEPT MỌI REQUEST CỦA EASYCOMIX
// =========================================================================

static NSString *const kEasyComixProtocolHandledKey = @"EasyComixGeminiProtocolHandled";

static BOOL IsGeminiInterceptRequest(NSURLRequest *request) {
    if ([NSURLProtocol propertyForKey:kEasyComixProtocolHandledKey inRequest:request]) {
        return NO;
    }
    NSURL *url = request.URL;
    NSString *host = [url.host lowercaseString] ?: @"";
    if ([host containsString:@"easycomix.app"] ||
        [host containsString:@"revenuecat.com"] ||
        [host containsString:@"8-lives-cat.io"]) {
        return YES;
    }
    return NO;
}

@interface EasyComixGeminiURLProtocol : NSURLProtocol
@property (atomic, assign) BOOL ecStopped;
@end

@implementation EasyComixGeminiURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return IsGeminiInterceptRequest(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

static NSString *const kMockEd25519SignatureBase64 = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

static NSString *GetRequestSignatureNonce(NSURLRequest *request) {
    if (!request) return @"";
    NSString *nonce = [request valueForHTTPHeaderField:@"X-Signature-Nonce"];
    if (nonce.length > 0) return nonce;
    for (NSString *key in [request.allHTTPHeaderFields allKeys]) {
        if ([key caseInsensitiveCompare:@"X-Signature-Nonce"] == NSOrderedSame) {
            return request.allHTTPHeaderFields[key];
        }
    }
    return @"";
}

- (void)finishWithJSONObject:(NSDictionary *)object {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    
    NSString *reqNonce = GetRequestSignatureNonce(self.request);
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{
        @"Content-Type": @"application/json",
        @"Access-Control-Allow-Origin": @"*",
        @"X-Signature": kMockEd25519SignatureBase64
    }];
    if (reqNonce.length > 0) {
        headers[@"X-Signature-Nonce"] = reqNonce;
    }
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)finishWithJSONArray:(NSArray *)array {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    
    NSString *reqNonce = GetRequestSignatureNonce(self.request);
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{
        @"Content-Type": @"application/json",
        @"Access-Control-Allow-Origin": @"*",
        @"X-Signature": kMockEd25519SignatureBase64
    }];
    if (reqNonce.length > 0) {
        headers[@"X-Signature-Nonce"] = reqNonce;
    }
    
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSString *host = [self.request.URL.host lowercaseString] ?: @"";
    NSString *path = self.request.URL.path ?: @"";
    LOG(@"NSURLProtocol intercepted: %@%@", host, path);

    // 0. REVENUECAT IN-APP PURCHASE FAKE (HIỂN THỊ PRO LIFETIME TRÊN UI)
    if ([host containsString:@"revenuecat.com"] || [host containsString:@"8-lives-cat.io"]) {
        if ([path containsString:@"/product_entitlement_mapping"]) {
            [self finishWithJSONObject:@{
                @"product_entitlement_mapping": @{
                    @"com.easycomix.pro.yearly": @{
                        @"product_identifier": @"com.easycomix.pro.yearly",
                        @"entitlements": @[ @"EasyComix Pro", @"pro", @"premium", @"easycomix_pro", @"full_access" ]
                    },
                    @"com.easycomix.pro.monthly": @{
                        @"product_identifier": @"com.easycomix.pro.monthly",
                        @"entitlements": @[ @"EasyComix Pro", @"pro", @"premium", @"easycomix_pro", @"full_access" ]
                    }
                }
            }];
            return;
        }
        [self finishWithJSONObject:RevenueCatProSubscriberResponse()];
        return;
    }

    // 2. USER PROFILE TRÊN EASYCOMIX BACKEND
    if ([path containsString:@"/user/profile"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"id": @"00000000-0000-0000-0000-000000000001",
                @"userId": @"00000000-0000-0000-0000-000000000001",
                @"email": @"geminipro@easycomix.app",
                @"isPro": @YES,
                @"tier": @"pro",
                @"timezoneOffset": @7,
                @"createdAt": @"2024-01-01T00:00:00Z",
                @"updatedAt": @"2026-09-01T00:00:00Z"
            }
        }];
        return;
    }

    // 3. Cấu hình hạn mức (Quota Config)
    if ([path containsString:@"/quota/config"]) {
        [self finishWithJSONObject:ProQuotaConfigResponse()];
        return;
    }

    // 4. Hạn mức hiện tại (Quota Usage)
    if ([path containsString:@"/quota"]) {
        [self finishWithJSONObject:ProQuotaUsageResponse()];
        return;
    }

    // 5. Site Support (Bản 1.0.23 mới)
    if ([path containsString:@"/site-support"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"version": @1,
                @"unsupportedDomains": @[]
            }
        }];
        return;
    }

    // 6. Quy tắc chặn quảng cáo (Ad Rules)
    if ([path containsString:@"/ad-rules"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"version": @1,
                @"rules": @[]
            }
        }];
        return;
    }

    // 7. Whitelist & App Version Config
    if ([path containsString:@"/whitelist"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"emails": @[ @"geminipro@easycomix.app" ]
            }
        }];
        return;
    }

    if ([path containsString:@"/app-version"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"minVersion": @"1.0.0",
                @"latestVersion": @"1.0.26",
                @"whatsNew": @"EasyComix Gemini PRO Enabled"
            }
        }];
        return;
    }

    // 8. Sự kiện ghé thăm trang & phản hồi (Events / Feedback)
    if ([path containsString:@"/events/"] || [path containsString:@"/feedback"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{}
        }];
        return;
    }

    // 9. Endpoint dịch thuật (/translate, /translate/chapter, /api/v1/translate,...)
    if ([path containsString:@"/translate"]) {
        NSData *bodyData = RequestBodyData(self.request);
        NSDictionary *payload = TranslationPayloadFromBodyData(bodyData);
        ProcessTranslatePayload(payload, ^(NSDictionary *responseObject) {
            [self finishWithJSONObject:responseObject];
        });
        return;
    }

    // Các request khác đến api.easycomix.app
    [self finishWithJSONObject:@{
        @"success": @YES,
        @"data": @{}
    }];
}

- (void)stopLoading {
    self.ecStopped = YES;
}

@end

// =========================================================================
// SWIZZLE TẤT CẢ CÁC CÁCH KHỞI TẠO NSURLSESSION TRONG SWIFT & OBJC
// =========================================================================

static void PrependGeminiProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration) return;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[EasyComixGeminiURLProtocol class]]) return;
    configuration.protocolClasses = [@[ [EasyComixGeminiURLProtocol class] ] arrayByAddingObjectsFromArray:existing];
}

static void SwizzleMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (origMethod && newMethod) {
        method_exchangeImplementations(origMethod, newMethod);
    }
}

static void SwizzleClassMethod(Class cls, SEL origSel, SEL newSel) {
    SwizzleMethod(object_getClass(cls), origSel, newSel);
}

@interface NSURLSessionConfiguration (EasyComixGeminiConfig)
+ (NSURLSessionConfiguration *)ec_defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)ec_ephemeralSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (EasyComixGeminiConfig)

+ (NSURLSessionConfiguration *)ec_defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self ec_defaultSessionConfiguration];
    PrependGeminiProtocol(configuration);
    return configuration;
}

+ (NSURLSessionConfiguration *)ec_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self ec_ephemeralSessionConfiguration];
    PrependGeminiProtocol(configuration);
    return configuration;
}

@end

@interface NSURLSession (EasyComixGeminiSession)
+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id<NSURLSessionDelegate>)delegate
                                delegateQueue:(NSOperationQueue *)queue;
+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
@end

@implementation NSURLSession (EasyComixGeminiSession)

+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id<NSURLSessionDelegate>)delegate
                                delegateQueue:(NSOperationQueue *)queue {
    PrependGeminiProtocol(configuration);
    return [self ec_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

+ (NSURLSession *)ec_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    PrependGeminiProtocol(configuration);
    return [self ec_sessionWithConfiguration:configuration];
}

@end

// =========================================================================
// SWIZZLE NSFILEMANAGER: CHUYỂN HƯỚNG APP GROUP (HỖ TRỢ DỊCH LIVE / LIVE TRANSLATE)
// =========================================================================

static NSString * const kOriginalAppGroup = @"group.app.easycomix";
static NSString * const kTargetAppGroup = @"group.7RS63NZFBW.cvN";

@interface NSFileManager (EasyComixAppGroup)
- (NSURL *)ec_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (EasyComixAppGroup)

- (NSURL *)ec_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if ([groupIdentifier isEqualToString:kOriginalAppGroup]) {
        NSURL *newURL = [self ec_containerURLForSecurityApplicationGroupIdentifier:kTargetAppGroup];
        if (newURL) {
            LOG(@"[AppGroup Redirect] Chuyển hướng App Group từ %@ sang %@", groupIdentifier, kTargetAppGroup);
            return newURL;
        }
    }
    return [self ec_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
}

@end

@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
    
    if ([self isKindOfClass:NSClassFromString(@"GeminiSettingsViewController")]) {
        return;
    }
    
    AddFloatingButtonToWindow();
    
    NSString *className = NSStringFromClass([self class]);
    // Nếu màn hình Login hoặc Paywall hoặc TrialFlow hiển thị dạng sheet/modal đè lên reader, tự động đóng nó
    if ([className containsString:@"LoginView"] ||
        [className containsString:@"PaywallView"] ||
        [className containsString:@"TrialFlow"] ||
        [className containsString:@"PopupViewController"]) {
        LOG(@"Tự động bỏ qua màn hình chặn đăng nhập / mua gói: %@", className);
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

// =========================================================================
// HOOK RUNTIME REVENUECAT & SUBSCRIPTION
// =========================================================================

static NSSet *Hook_activeSubscriptions(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSSet setWithObjects:@"com.easycomix.pro.yearly", @"com.easycomix.pro.monthly", nil];
}

static NSSet *Hook_allPurchasedProductIdentifiers(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSSet setWithObjects:@"com.easycomix.pro.yearly", @"com.easycomix.pro.monthly", nil];
}

static NSDate *Hook_latestExpirationDate(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSDate dateWithTimeIntervalSince1970:4102444800]; // 2100-01-01
}

static BOOL Hook_isTrue(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static NSInteger Hook_verification(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 1; // Verified
}

static NSString *Hook_productIdentifier(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"com.easycomix.pro.yearly";
}

static NSString *Hook_entitlementIdentifier(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"EasyComix Pro";
}

static NSDate *Hook_distantFutureDate(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [NSDate dateWithTimeIntervalSince1970:4102444800];
}

static void HookRevenueCatClasses(void) {
    NSArray *customerInfoClasses = @[ @"RCCustomerInfo", @"_TtC10RevenueCat12CustomerInfo" ];
    for (NSString *className in customerInfoClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            class_replaceMethod(cls, sel_registerName("activeSubscriptions"), (IMP)Hook_activeSubscriptions, "@@:");
            class_replaceMethod(cls, sel_registerName("allPurchasedProductIdentifiers"), (IMP)Hook_allPurchasedProductIdentifiers, "@@:");
            class_replaceMethod(cls, sel_registerName("latestExpirationDate"), (IMP)Hook_latestExpirationDate, "@@:");
            class_replaceMethod(cls, sel_registerName("entitlementVerification"), (IMP)Hook_verification, "q@:");
            LOG(@"Đã hook %@ (activeSubscriptions, allPurchasedProductIdentifiers, latestExpirationDate, entitlementVerification)", className);
        }
    }
    
    NSArray *entitlementInfoClasses = @[ @"RCEntitlementInfo", @"_TtC10RevenueCat15EntitlementInfo" ];
    for (NSString *className in entitlementInfoClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            class_replaceMethod(cls, sel_registerName("isActive"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("willRenew"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("isActiveInAnyEnvironment"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("isActiveInCurrentEnvironment"), (IMP)Hook_isTrue, "B@:");
            class_replaceMethod(cls, sel_registerName("expirationDate"), (IMP)Hook_distantFutureDate, "@@:");
            class_replaceMethod(cls, sel_registerName("verification"), (IMP)Hook_verification, "q@:");
            class_replaceMethod(cls, sel_registerName("productIdentifier"), (IMP)Hook_productIdentifier, "@@:");
            class_replaceMethod(cls, sel_registerName("identifier"), (IMP)Hook_entitlementIdentifier, "@@:");
            LOG(@"Đã hook %@ (isActive, willRenew, expirationDate, verification, productIdentifier, identifier)", className);
        }
    }
}


// =========================================================================
// DIRECT GOT PATCHING & DYNAMIC CHAINED FIXUPS RESOLUTION
// Bypass CryptoKit isValidSignature (Ed25519)
// =========================================================================
// EasyComix sử dụng LC_DYLD_CHAINED_FIXUPS (iOS 15+ / Xcode 14+)
// khiến indirect symbol table rỗng (nindirectsyms=0).
// Fishhook KHÔNG THỂ hoạt động vì nó dựa vào bảng này.
// Giải pháp:
// 1. Dò tìm địa chỉ GOT Entry của `isValidSignature` tự động qua LC_DYLD_CHAINED_FIXUPS trên binary.
// 2. Fallback ghi trực tiếp vào các GOT entry đã biết:
//    - EasyComix 1.0.26: 0x100582cd0
//    - EasyComix 1.0.23: 0x100516aa8
// =========================================================================

// Hook function: luôn trả về true (1) cho isValidSignature
// ARM64 calling convention: return value trong w0
static bool Hook_CryptoKit_isValidSignature(void) {
    return true;
}

#define CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1026 0x100582cd0ULL
#define CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1023 0x100516aa8ULL

struct ec_dyld_chained_fixups_header {
    uint32_t fixups_version;
    uint32_t starts_offset;
    uint32_t imports_offset;
    uint32_t symbols_offset;
    uint32_t imports_count;
    uint32_t imports_format;
    uint32_t symbols_format;
};

struct ec_dyld_chained_starts_in_image {
    uint32_t seg_count;
    uint32_t seg_info_offset[1];
};

struct ec_dyld_chained_starts_in_segment {
    uint32_t size;
    uint16_t page_size;
    uint16_t pointer_format;
    uint64_t segment_offset;
    uint32_t max_valid_pointer;
    uint16_t page_count;
    uint16_t page_start[1];
};

static void PatchDirectPointer(void **entry_ptr, void *new_func_ptr) {
    if (!entry_ptr) return;
    
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    if (page_size == 0) page_size = 16384;
    
    uintptr_t page_start = (uintptr_t)entry_ptr & ~(page_size - 1);
    mach_port_t task = mach_task_self();
    
    // Phương pháp 1: vm_protect trực tiếp (bỏ VM_PROT_COPY vì XNU kernel hiện đại từ chối cờ này)
    kern_return_t kr = vm_protect(
        task,
        (vm_address_t)page_start,
        (vm_size_t)page_size,
        0,
        VM_PROT_READ | VM_PROT_WRITE
    );
    
    if (kr == KERN_SUCCESS) {
        void *old_value = *entry_ptr;
        *entry_ptr = new_func_ptr;
        vm_protect(task, (vm_address_t)page_start, (vm_size_t)page_size, 0, VM_PROT_READ);
        LOG(@"[GOT Patch] vm_protect thành công tại %p: %p -> %p", entry_ptr, old_value, new_func_ptr);
        return;
    }
    
    // Phương pháp 2: vm_write (Mach kernel primitive)
    kr = vm_write(
        task,
        (vm_address_t)entry_ptr,
        (vm_offset_t)&new_func_ptr,
        (mach_msg_type_number_t)sizeof(void *)
    );
    if (kr == KERN_SUCCESS) {
        LOG(@"[GOT Patch] vm_write thành công tại %p -> %p", entry_ptr, new_func_ptr);
        return;
    }
    
    // Phương pháp 3: mprotect POSIX fallback
    int mp = mprotect((void *)page_start, page_size, PROT_READ | PROT_WRITE);
    if (mp == 0) {
        void *old_value = *entry_ptr;
        *entry_ptr = new_func_ptr;
        mprotect((void *)page_start, page_size, PROT_READ);
        LOG(@"[GOT Patch] mprotect thành công tại %p: %p -> %p", entry_ptr, old_value, new_func_ptr);
        return;
    }
    
    LOG(@"[GOT Patch] CẢNH BÁO: Tất cả kỹ thuật memory patch đều thất bại tại %p (kr=%d, errno=%d).", entry_ptr, kr, errno);
}

static uintptr_t FindGOTVirtualAddressFromMachO(const char *filePath, const char *symbolSubstr) {
    if (!filePath || !symbolSubstr) return 0;
    
    int fd = open(filePath, O_RDONLY);
    if (fd < 0) {
        LOG(@"[Dynamic GOT] Không thể mở file binary: %s", filePath);
        return 0;
    }
    
    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof(mh), 0) != sizeof(mh)) {
        close(fd);
        return 0;
    }
    
    if (mh.magic != MH_MAGIC_64) {
        close(fd);
        return 0;
    }
    
    uint8_t *cmds_buf = (uint8_t *)malloc(mh.sizeofcmds);
    if (!cmds_buf) {
        close(fd);
        return 0;
    }
    
    if (pread(fd, cmds_buf, mh.sizeofcmds, sizeof(mh)) != (ssize_t)mh.sizeofcmds) {
        free(cmds_buf);
        close(fd);
        return 0;
    }
    
    uint64_t data_const_vmaddr = 0;
    uint64_t data_const_fileoff = 0;
    uint32_t fixup_dataoff = 0;
    uint32_t fixup_datasize = 0;
    
    uint8_t *cursor = cmds_buf;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
            if (strcmp(seg->segname, SEG_DATA_CONST) == 0) {
                data_const_vmaddr = seg->vmaddr;
                data_const_fileoff = seg->fileoff;
            }
        } else if (lc->cmd == 0x80000034) { // LC_DYLD_CHAINED_FIXUPS
            struct linkedit_data_command *ldc = (struct linkedit_data_command *)cursor;
            fixup_dataoff = ldc->dataoff;
            fixup_datasize = ldc->datasize;
        }
        cursor += lc->cmdsize;
    }
    free(cmds_buf);
    
    if (fixup_dataoff == 0 || fixup_datasize == 0 || data_const_vmaddr == 0) {
        close(fd);
        return 0;
    }
    
    uint8_t *fixup_buf = (uint8_t *)malloc(fixup_datasize);
    if (!fixup_buf) {
        close(fd);
        return 0;
    }
    
    if (pread(fd, fixup_buf, fixup_datasize, fixup_dataoff) != (ssize_t)fixup_datasize) {
        free(fixup_buf);
        close(fd);
        return 0;
    }
    
    struct ec_dyld_chained_fixups_header *fh = (struct ec_dyld_chained_fixups_header *)fixup_buf;
    const char *symbols_pool = (const char *)(fixup_buf + fh->symbols_offset);
    const uint8_t *imports_base = fixup_buf + fh->imports_offset;
    
    int32_t target_ordinal = -1;
    for (uint32_t i = 0; i < fh->imports_count; i++) {
        uint32_t name_offset = 0;
        if (fh->imports_format == 1) { // DYLD_CHAINED_IMPORT
            uint32_t val = *(const uint32_t *)(imports_base + i * 4);
            name_offset = val >> 9;
        } else if (fh->imports_format == 2) { // DYLD_CHAINED_IMPORT_ADDEND
            uint32_t val = *(const uint32_t *)(imports_base + i * 8);
            name_offset = val >> 9;
        } else if (fh->imports_format == 3) { // DYLD_CHAINED_IMPORT_ADDEND64
            uint64_t val = *(const uint64_t *)(imports_base + i * 16);
            name_offset = (uint32_t)(val >> 32);
        } else {
            break;
        }
        
        if (fh->symbols_offset + name_offset < fixup_datasize) {
            const char *sym_name = symbols_pool + name_offset;
            if (strstr(sym_name, symbolSubstr) != NULL) {
                target_ordinal = (int32_t)i;
                LOG(@"[Dynamic GOT] Tìm thấy symbol %s tại import #%d", sym_name, target_ordinal);
                break;
            }
        }
    }
    
    if (target_ordinal < 0) {
        free(fixup_buf);
        close(fd);
        return 0;
    }
    
    struct ec_dyld_chained_starts_in_image *starts_img =
        (struct ec_dyld_chained_starts_in_image *)(fixup_buf + fh->starts_offset);
    
    uintptr_t found_va = 0;
    for (uint32_t s = 0; s < starts_img->seg_count && found_va == 0; s++) {
        uint32_t seg_info_off = starts_img->seg_info_offset[s];
        if (seg_info_off == 0) continue;
        
        struct ec_dyld_chained_starts_in_segment *starts_seg =
            (struct ec_dyld_chained_starts_in_segment *)(fixup_buf + fh->starts_offset + seg_info_off);
        
        uint16_t page_size = starts_seg->page_size;
        uint16_t ptr_format = starts_seg->pointer_format;
        uint64_t seg_file_offset = starts_seg->segment_offset;
        
        for (uint16_t p = 0; p < starts_seg->page_count && found_va == 0; p++) {
            uint16_t pstart = starts_seg->page_start[p];
            if (pstart == 0xFFFF) continue;
            
            off_t cur_file_off = (off_t)(seg_file_offset + (uint64_t)p * page_size + pstart);
            while (1) {
                uint64_t val = 0;
                if (pread(fd, &val, sizeof(val), cur_file_off) != sizeof(val)) break;
                
                uint64_t bind_bit = (val >> 63) & 1;
                uint64_t next_stride = 0;
                
                if (ptr_format == 2 || ptr_format == 6) { // DYLD_CHAINED_PTR_64 / DYLD_CHAINED_PTR_64_OFFSET
                    next_stride = ((val >> 51) & 0xFFF) * 4;
                    if (bind_bit == 1) {
                        uint32_t ordinal = (uint32_t)(val & 0xFFFFFF);
                        if ((int32_t)ordinal == target_ordinal) {
                            found_va = data_const_vmaddr + ((uint64_t)cur_file_off - data_const_fileoff);
                            LOG(@"[Dynamic GOT] Tìm thấy GOT entry tại file offset 0x%llx -> VA 0x%lx", (unsigned long long)cur_file_off, (unsigned long)found_va);
                            break;
                        }
                    }
                } else if (ptr_format == 1) { // DYLD_CHAINED_PTR_ARM64E
                    next_stride = ((val >> 51) & 0x7FF) * 8;
                    uint64_t bind_arm64e = (val >> 62) & 1;
                    if (bind_arm64e == 1) {
                        uint32_t ordinal = (uint32_t)(val & 0xFFFF);
                        if ((int32_t)ordinal == target_ordinal) {
                            found_va = data_const_vmaddr + ((uint64_t)cur_file_off - data_const_fileoff);
                            LOG(@"[Dynamic GOT] Tìm thấy ARM64E GOT entry tại file offset 0x%llx -> VA 0x%lx", (unsigned long long)cur_file_off, (unsigned long)found_va);
                            break;
                        }
                    }
                } else {
                    break;
                }
                
                if (next_stride == 0) break;
                cur_file_off += next_stride;
            }
        }
    }
    
    free(fixup_buf);
    close(fd);
    return found_va;
}

// =========================================================================
// KHỞI TẠO TWEAK: GỠ BỎ GIỚI HẠN & KÍCH HOẠT PRO VĨNH VIỄN
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini PRO Hook initialized. Model: %@", GetSavedGeminiModel());
    
    // 1. BYPASS CHỮ KÝ ED25519: Patch trực tiếp GOT entry của CryptoKit isValidSignature
    //    Tìm main executable image (index 0 = dyld, thường main app là image chứa đường dẫn app)
    uint32_t image_count = _dyld_image_count();
    intptr_t slide = 0;
    const char *appPath = NULL;
    BOOL found = NO;
    
    for (uint32_t i = 0; i < image_count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "EasyComix") && !strstr(name, "EasyComixGemini")) {
            slide = _dyld_get_image_vmaddr_slide(i);
            appPath = name;
            found = YES;
            LOG(@"[GOT Patch] Tìm thấy EasyComix image tại index %u (%s), ASLR slide = 0x%lx", i, name, (unsigned long)slide);
            break;
        }
    }
    if (!found) {
        slide = _dyld_get_image_vmaddr_slide(0);
        appPath = _dyld_get_image_name(0);
        LOG(@"[GOT Patch] Dùng image index 0 (%s), slide = 0x%lx", appPath ?: "unknown", (unsigned long)slide);
    }
    
    BOOL dynamicPatched = NO;
    if (appPath != NULL) {
        uintptr_t dynamicVA = FindGOTVirtualAddressFromMachO(appPath, "isValidSignature");
        if (dynamicVA != 0) {
            PatchDirectPointer((void **)(dynamicVA + (uintptr_t)slide), (void *)Hook_CryptoKit_isValidSignature);
            dynamicPatched = YES;
            LOG(@"[GOT Patch] Đã bypass CryptoKit isValidSignature qua Dynamic Chained Fixups tại VA 0x%lx", (unsigned long)dynamicVA);
        }
    }
    
    // Luôn luôn áp dụng Known GOT VAs dự phòng để bảo đảm 100% không sót
    LOG(@"[GOT Patch] Áp dụng Known GOT VAs dự phòng (1.0.26: 0x%llx, 1.0.23: 0x%llx)...", (unsigned long long)CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1026, (unsigned long long)CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1023);
    PatchDirectPointer((void **)(CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1026 + (uintptr_t)slide), (void *)Hook_CryptoKit_isValidSignature);
    PatchDirectPointer((void **)(CRYPTOKIT_ISVALIDSIGNATURE_GOT_VA_1023 + (uintptr_t)slide), (void *)Hook_CryptoKit_isValidSignature);

    // 2. Tự động xóa cache hạn mức cũ trong UserDefaults của app
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in [defaultsDict allKeys]) {
        if ([key containsString:@"quota"] || [key containsString:@"Quota"] || [key containsString:@"limit"] || [key containsString:@"Tier"]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 3. Xóa cache RevenueCat cũ bị lỗi verification để nạp mới
    NSUserDefaults *rcDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.revenuecat.user_defaults"];
    if (rcDefaults) {
        NSDictionary *rcDict = [rcDefaults dictionaryRepresentation];
        for (NSString *k in [rcDict allKeys]) {
            if ([k containsString:@"purchaserInfo"] || [k containsString:@"PurchaserInfo"]) {
                [rcDefaults removeObjectForKey:k];
            }
        }
        [rcDefaults synchronize];
    }
    
    // 4. Hook RevenueCat Runtime
    HookRevenueCatClasses();
    
    // 5. Đăng ký NSURLProtocol
    [NSURLProtocol registerClass:[EasyComixGeminiURLProtocol class]];
    
    // 6. Swizzle các hàm tạo session configuration & session instance
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(defaultSessionConfiguration),
                       @selector(ec_defaultSessionConfiguration));
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(ephemeralSessionConfiguration),
                       @selector(ec_ephemeralSessionConfiguration));
    SwizzleClassMethod([NSURLSession class],
                       @selector(sessionWithConfiguration:delegate:delegateQueue:),
                       @selector(ec_sessionWithConfiguration:delegate:delegateQueue:));
    SwizzleClassMethod([NSURLSession class],
                       @selector(sessionWithConfiguration:),
                       @selector(ec_sessionWithConfiguration:));
                  
    // 7. Gắn nút cài đặt nổi trên UI & Tự động đóng modal chặn
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
                  
    // 8. Swizzle NSFileManager containerURLForSecurityApplicationGroupIdentifier: (Dự phòng Live Translate)
    SwizzleMethod([NSFileManager class],
                  @selector(containerURLForSecurityApplicationGroupIdentifier:),
                  @selector(ec_containerURLForSecurityApplicationGroupIdentifier:));
}
