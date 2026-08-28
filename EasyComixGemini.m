#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib) - Direct NSURLSession Swizzling
 * Tự động xóa sạch Cache Quota cũ khi khởi động app
 * Bắt toàn diện mọi endpoint Quota, Live Quota, Single Translate & Chapter Translate
 * Cho phép chọn: gemini-2.5-flash-lite hoặc gemini-3.5-flash-lite
 * Mặc định: gemini-2.5-flash-lite
 */

#define LOG(fmt, ...) NSLog(@"[EasyComixGemini] " fmt, ##__VA_ARGS__)

static NSString *const kGeminiKeysPref  = @"EasyComix_Gemini_Key_Pool";
static NSString *const kGeminiModelPref = @"EasyComix_Gemini_Model_Name";
static NSString *const kGemini25Model   = @"gemini-2.5-flash-lite";
static NSString *const kGemini35Model   = @"gemini-3.5-flash-lite";
static NSUInteger sCurrentKeyIndex = 0;

// =========================================================================
// QUẢN LÝ KEY POOL & MODEL
// =========================================================================

static NSArray<NSString *> *GetGeminiKeyPool(void) {
    NSString *rawKeys = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref];
    if (!rawKeys || [rawKeys length] == 0) {
        return [NSArray array];
    }
    
    NSArray *components = [rawKeys componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n,"]];
    NSMutableArray *validKeys = [NSMutableArray array];
    
    for (NSString *k in components) {
        NSString *trimmed = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length] > 0) {
            [validKeys addObject:trimmed];
        }
    }
    return validKeys;
}

static NSString *GetActiveGeminiKey(void) {
    NSArray *keys = GetGeminiKeyPool();
    if ([keys count] == 0) return @"";
    return keys[sCurrentKeyIndex % [keys count]];
}

static void RotateToNextKey(void) {
    NSArray *keys = GetGeminiKeyPool();
    if ([keys count] > 1) {
        sCurrentKeyIndex = (sCurrentKeyIndex + 1) % [keys count];
        LOG(@"Đã tự động xoay sang Key #%lu/%lu", (unsigned long)(sCurrentKeyIndex + 1), (unsigned long)[keys count]);
    }
}

static NSString *GetSavedGeminiModel(void) {
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiModelPref];
    if ([model isEqualToString:kGemini35Model]) return kGemini35Model;
    return kGemini25Model;
}

static void SaveGeminiSettings(NSString *rawKeys, NSString *model) {
    NSString *trimmedKeys = [rawKeys ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *safeModel = [model isEqualToString:kGemini35Model] ? kGemini35Model : kGemini25Model;
    [[NSUserDefaults standardUserDefaults] setObject:trimmedKeys forKey:kGeminiKeysPref];
    [[NSUserDefaults standardUserDefaults] setObject:safeModel forKey:kGeminiModelPref];
    [[NSUserDefaults standardUserDefaults] synchronize];
    sCurrentKeyIndex = 0;
    LOG(@"Đã cập nhật cấu hình: %lu keys, model: %@", (unsigned long)[GetGeminiKeyPool() count], safeModel);
}

// =========================================================================
// GIAO DIỆN CÀI ĐẶT: POPUP NHẬP NHIỀU KEY & NÚT NỔI
// =========================================================================

static void ShowGeminiSettingsPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
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
        
        NSArray *currentKeys = GetGeminiKeyPool();
        NSString *currentKeysText = [[NSUserDefaults standardUserDefaults] stringForKey:kGeminiKeysPref] ?: @"";
        NSString *activeModel = GetSavedGeminiModel();
        NSString *message = [NSString stringWithFormat:@"Đang có %lu key. Model hiện tại: %@\nDán nhiều key, phân cách bằng dấu phẩy hoặc xuống dòng.", (unsigned long)[currentKeys count], activeModel];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Gemini Key Pool & Model"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"AIza... , AIza...";
            textField.text = currentKeysText;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
        }];

        NSString *title25 = [activeModel isEqualToString:kGemini25Model]
            ? @"✓ Gemini 2.5 Flash Lite" : @"Gemini 2.5 Flash Lite";
        NSString *title35 = [activeModel isEqualToString:kGemini35Model]
            ? @"✓ Gemini 3.5 Flash Lite" : @"Gemini 3.5 Flash Lite";

        [alert addAction:[UIAlertAction actionWithTitle:title25
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            SaveGeminiSettings(alert.textFields.firstObject.text, kGemini25Model);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:title35
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            SaveGeminiSettings(alert.textFields.firstObject.text, kGemini35Model);
        }]];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Đóng"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        
        [alert addAction:cancelAction];
        
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// Nút nổi kéo thả trên màn hình
@interface GeminiFloatingButton : UIButton
@end

@implementation GeminiFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:0.9];
        [self setTitle:@"🤖 Key" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.3;
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if ([w isKeyWindow]) {
                    keyWindow = w;
                    break;
                }
            }
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
            if (keyWindow) {
                GeminiFloatingButton *btn = [[GeminiFloatingButton alloc] initWithFrame:CGRectMake(20, 150, 50, 50)];
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

static void CallGeminiTranslation(NSArray *texts,
                                  NSString *srcLang,
                                  NSString *tgtLang,
                                  NSUInteger attempt,
                                  NSUInteger maxTries,
                                  void (^completion)(NSArray *translatedTexts)) {
    
    NSString *currentKey = GetActiveGeminiKey();
    NSString *model = GetSavedGeminiModel();
    
    if ([currentKey length] == 0) {
        ShowGeminiSettingsPopup();
        completion(texts);
        return;
    }
    
    NSError *error;
    NSData *textsJsonData = [NSJSONSerialization dataWithJSONObject:texts options:0 error:&error];
    NSString *textsJsonString = [[NSString alloc] initWithData:textsJsonData encoding:NSUTF8StringEncoding];
    
    NSString *prompt = [NSString stringWithFormat:
        @"Bạn là dịch giả truyện tranh chuyên nghiệp.\n"
        @"Hãy dịch danh sách các câu thoại sau từ ngôn ngữ '%@' sang '%@'.\n"
        @"Quy tắc:\n"
        @"- Dịch mượt mà, cảm xúc tự nhiên, đúng ngữ cảnh thoại truyện tranh.\n"
        @"- Trả về DUY NHẤT một JSON Array mảng chuỗi theo đúng thứ tự (ví dụ: [\"câu 1\", \"câu 2\"]).\n"
        @"- KHÔNG thêm bất kỳ markdown hoặc giải thích nào.\n\n"
        @"Danh sách:\n%@", srcLang, tgtLang, textsJsonString];
    
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
        NSInteger statusCode = httpResponse.statusCode;
        
        LOG(@"Gemini (%@) response status: %ld", model, (long)statusCode);
        
        BOOL isKeyOrModelError = (statusCode == 429 || statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404);
        
        if ((isKeyOrModelError || netError) && attempt < maxTries - 1) {
            LOG(@"Lỗi gọi Gemini (HTTP %ld). Đang xoay sang Key tiếp theo để thử lại...", (long)statusCode);
            RotateToNextKey();
            CallGeminiTranslation(texts, srcLang, tgtLang, attempt + 1, maxTries, completion);
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
                if ([parsed isKindOfClass:[NSArray class]] && [(NSArray *)parsed count] == [texts count]) {
                    translatedList = (NSArray *)parsed;
                }
            }
        }
        
        if (!translatedList || [translatedList count] == 0) {
            LOG(@"Không parse được bản dịch từ Gemini, trả về text gốc.");
            translatedList = texts;
        } else {
            LOG(@"Dịch thành công %lu câu bằng Gemini (%@)!", (unsigned long)[translatedList count], model);
        }
        
        completion(translatedList);
    }] resume];
}

// =========================================================================
// NSURLPROTOCOL: BẮT CẢ URLSESSION ASYNC/AWAIT CỦA SWIFT
// =========================================================================

static BOOL IsGeminiInterceptPath(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (![[url.host lowercaseString] isEqualToString:@"api.easycomix.app"]) return NO;
    NSString *path = url.path ?: @"";
    return [path isEqualToString:@"/api/v1/translate"] ||
           [path isEqualToString:@"/api/v1/translate/quota"] ||
           [path isEqualToString:@"/api/v1/translate/quota/config"];
}

static NSDictionary *LocalQuotaResponse(void) {
    return @{
        @"success": @YES,
        @"data": @{
            @"tier": @"free",
            @"remaining": @999999,
            @"resetAt": @"2099-01-01T00:00:00.000Z"
        },
        @"meta": @{
            @"quota": @{
                @"tier": @"free",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            },
            @"liveQuota": @{
                @"tier": @"free",
                @"remaining": @999999,
                @"resetAt": @"2099-01-01T00:00:00.000Z"
            }
        }
    };
}

@interface EasyComixGeminiURLProtocol : NSURLProtocol
@property (atomic, assign) BOOL ecStopped;
@end

@implementation EasyComixGeminiURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return IsGeminiInterceptPath(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)finishWithJSONObject:(NSDictionary *)object {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:@{ @"Content-Type": @"application/json; charset=utf-8" }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSString *path = self.request.URL.path ?: @"";
    LOG(@"NSURLProtocol intercepted: %@", path);

    if ([path isEqualToString:@"/api/v1/translate/quota/config"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"tiers": @{
                    @"trial": @{ @"maxCalls": @999999 },
                    @"free": @{ @"maxCalls": @999999 },
                    @"pro": @{ @"maxCalls": @999999 }
                },
                @"live": @{
                    @"free": @{ @"maxCalls": @999999 },
                    @"pro": @{ @"maxCalls": @999999 }
                }
            }
        }];
        return;
    }

    if ([path isEqualToString:@"/api/v1/translate/quota"]) {
        [self finishWithJSONObject:LocalQuotaResponse()];
        return;
    }

    NSData *bodyData = self.request.HTTPBody;
    NSDictionary *body = bodyData ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : nil;
    NSArray *texts = [body[@"texts"] isKindOfClass:[NSArray class]] ? body[@"texts"] : nil;
    NSString *source = [body[@"sourceLanguage"] isKindOfClass:[NSString class]] ? body[@"sourceLanguage"] : @"auto";
    NSString *target = [body[@"targetLanguage"] isKindOfClass:[NSString class]] ? body[@"targetLanguage"] : @"vi";

    if ([texts count] == 0) {
        NSError *error = [NSError errorWithDomain:@"EasyComixGemini"
                                             code:1001
                                         userInfo:@{NSLocalizedDescriptionKey: @"Request dịch không có texts"}];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    NSUInteger keyCount = [GetGeminiKeyPool() count];
    CallGeminiTranslation(texts, source, target, 0, MAX((NSUInteger)1, keyCount), ^(NSArray *translatedTexts) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{ @"translations": translatedTexts },
            @"meta": LocalQuotaResponse()[@"meta"]
        }];
    });
}

- (void)stopLoading {
    self.ecStopped = YES;
}

@end


static void PrependGeminiProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration) return;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[EasyComixGeminiURLProtocol class]]) return;
    configuration.protocolClasses = [@[ [EasyComixGeminiURLProtocol class] ] arrayByAddingObjectsFromArray:existing];
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

// =========================================================================
// METHOD SWIZZLING TRỰC TIẾP TRÊN NSURLSESSION
// =========================================================================

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

@interface NSURLSession (EasyComixDirectHook)
@end

@implementation NSURLSession (EasyComixDirectHook)

- (NSURLSessionDataTask *)hook_dataTaskWithRequest:(NSURLRequest *)request
                                completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler {
    
    NSString *urlString = request.URL.absoluteString;
    
    // 1. Chặn Endpoint Quota (GET/POST /api/v1/translate/quota)
    if ([urlString containsString:@"api.easycomix.app"] &&
        [urlString containsString:@"/quota"] &&
        ![urlString containsString:@"/quota/config"]) {
        
        LOG(@"Directly Hooked Quota Request: %@", urlString);
        if (completionHandler) {
            NSDictionary *fakeQuota = @{
                @"success": @YES,
                @"data": @{
                    @"tier": @"free",
                    @"remaining": @999999,
                    @"resetAt": @"2099-01-01T00:00:00.000Z",
                    @"quota": @{
                        @"tier": @"free",
                        @"remaining": @999999,
                        @"resetAt": @"2099-01-01T00:00:00.000Z"
                    },
                    @"liveQuota": @{
                        @"tier": @"free",
                        @"remaining": @999999,
                        @"resetAt": @"2099-01-01T00:00:00.000Z"
                    }
                },
                @"meta": @{
                    @"quota": @{
                        @"tier": @"free",
                        @"remaining": @999999,
                        @"resetAt": @"2099-01-01T00:00:00.000Z"
                    },
                    @"liveQuota": @{
                        @"tier": @"free",
                        @"remaining": @999999,
                        @"resetAt": @"2099-01-01T00:00:00.000Z"
                    }
                }
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:fakeQuota options:0 error:nil];
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{
                                                                        @"Content-Type": @"application/json; charset=utf-8",
                                                                        @"Access-Control-Allow-Origin": @"*"
                                                                    }];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(data, fakeResp, nil);
            });
        }
        return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
    }
    
    // 2. Chặn Endpoint Dịch thuật (/api/v1/translate và /translate/chapter)
    if ([urlString containsString:@"api.easycomix.app"] && [urlString containsString:@"/translate"]) {
        LOG(@"Directly Hooked Translate Request: %@", urlString);
        
        NSData *bodyData = request.HTTPBody;
        if (bodyData && completionHandler) {
            NSDictionary *bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            NSArray *texts = bodyJson[@"texts"];
            NSString *srcLang = bodyJson[@"sourceLanguage"] ?: @"auto";
            NSString *tgtLang = bodyJson[@"targetLanguage"] ?: @"vi";
            
            if (texts && [texts count] > 0) {
                NSArray *keys = GetGeminiKeyPool();
                NSUInteger maxTries = [keys count] > 0 ? [keys count] : 1;
                
                CallGeminiTranslation(texts, srcLang, tgtLang, 0, maxTries, ^(NSArray *translatedTexts) {
                    NSDictionary *finalRespDict = @{
                        @"success": @YES,
                        @"data": @{
                            @"translations": translatedTexts
                        },
                        @"meta": @{
                            @"quota": @{
                                @"tier": @"free",
                                @"remaining": @999999,
                                @"resetAt": @"2099-01-01T00:00:00.000Z"
                            },
                            @"liveQuota": @{
                                @"tier": @"free",
                                @"remaining": @999999,
                                @"resetAt": @"2099-01-01T00:00:00.000Z"
                            }
                        }
                    };
                    
                    NSData *resData = [NSJSONSerialization dataWithJSONObject:finalRespDict options:0 error:nil];
                    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                              statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1"
                                                                            headerFields:@{
                                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                                @"Access-Control-Allow-Origin": @"*"
                                                                            }];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionHandler(resData, fakeResp, nil);
                    });
                });
                
                return [self hook_dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]] completionHandler:nil];
            }
        }
    }
    
    return [self hook_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end

@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
    AddFloatingButtonToWindow();
}

@end

// =========================================================================
// KHỞI TẠO TWEAK & XÓA CACHE QUOTA CŨ
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini Direct Hook initialized. Model: %@", GetSavedGeminiModel());
    
    // Tự động xóa cache hạn mức cũ trong UserDefaults của app
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in [defaultsDict allKeys]) {
        if ([key containsString:@"quota"] || [key containsString:@"Quota"] || [key containsString:@"limit"]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    SwizzleMethod([NSURLSession class],
                  @selector(dataTaskWithRequest:completionHandler:),
                  @selector(hook_dataTaskWithRequest:completionHandler:));

    [NSURLProtocol registerClass:[EasyComixGeminiURLProtocol class]];
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(defaultSessionConfiguration),
                       @selector(ec_defaultSessionConfiguration));
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(ephemeralSessionConfiguration),
                       @selector(ec_ephemeralSessionConfiguration));
                  
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
}
