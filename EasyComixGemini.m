#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/**
 * EasyComix Gemini Tweak (Dylib)
 * - Chặn toàn diện 100% request dịch (Dịch Classic Chapter & Dịch Live Scroll/Paged) chuyển qua Gemini API
 * - Mở khóa vĩnh viễn hạn mức PRO (999,999 lượt cho cả Dịch thường & Dịch Live)
 * - Tự động tái tạo JSON đúng 100% theo kiểu Swift Decodable của EasyComix
 * - Tự động xoay Key khi gặp lỗi Rate Limit (HTTP 429) hoặc lỗi Key
 * - Tùy chọn 2 model: gemini-2.5-flash-lite và gemini-3.5-flash-lite
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
    
    NSArray *components = [rawKeys componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n,;"]];
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
    if ([model isEqualToString:kGemini35Model]) {
        return kGemini35Model;
    }
    return kGemini25Model;
}

static void SaveGeminiSettings(NSString *rawKeys, NSString *model) {
    NSString *trimmedKeys = [rawKeys ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *safeModel = [model isEqualToString:kGemini35Model] ? kGemini35Model : kGemini25Model;
    [[NSUserDefaults standardUserDefaults] setObject:trimmedKeys forKey:kGeminiKeysPref];
    [[NSUserDefaults standardUserDefaults] setObject:safeModel forKey:kGeminiModelPref];
    [[NSUserDefaults standardUserDefaults] synchronize];
    sCurrentKeyIndex = 0;
    LOG(@"Đã lưu cấu hình: %lu keys, model: %@", (unsigned long)[GetGeminiKeyPool() count], safeModel);
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
        NSString *message = [NSString stringWithFormat:@"Đang có %lu API key.\nModel đang dùng: %@\nDán nhiều key, phân cách bằng dấu phẩy hoặc xuống dòng để tự động xoay key khi quá tải.", (unsigned long)[currentKeys count], activeModel];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 Gemini Key Pool & Model"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Dán Gemini API Key (AIzaSy...)";
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
    
    NSString *currentKey = GetActiveGeminiKey();
    NSString *model = GetSavedGeminiModel();
    
    if ([currentKey length] == 0) {
        ShowGeminiSettingsPopup();
        completion(texts);
        return;
    }
    
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
            LOG(@"Lỗi gọi Gemini (HTTP %ld). Đang xoay sang Key tiếp theo...", (long)statusCode);
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
            @"liveQuota": ProQuotaInfoDict()
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
                @"com.easycomix.pro.monthly": subscriptionInfo
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
    if ([host isEqualToString:@"api.easycomix.app"] ||
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

- (void)finishWithJSONObject:(NSDictionary *)object {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Access-Control-Allow-Origin": @"*"
                                                            }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)finishWithJSONArray:(NSArray *)array {
    if (self.ecStopped) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Access-Control-Allow-Origin": @"*"
                                                            }];
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
    if ([path containsString:@"/api/v1/user/profile"]) {
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
    if ([path isEqualToString:@"/api/v1/translate/quota/config"]) {
        [self finishWithJSONObject:ProQuotaConfigResponse()];
        return;
    }

    // 4. Hạn mức hiện tại (Quota Usage)
    if ([path isEqualToString:@"/api/v1/translate/quota"]) {
        [self finishWithJSONObject:ProQuotaUsageResponse()];
        return;
    }

    // 5. Quy tắc chặn quảng cáo (Ad Rules)
    if ([path isEqualToString:@"/api/v1/config/ad-rules"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{
                @"version": @1,
                @"rules": @[]
            }
        }];
        return;
    }

    // 6. Sự kiện ghé thăm trang (Events)
    if ([path containsString:@"/events/"]) {
        [self finishWithJSONObject:@{
            @"success": @YES,
            @"data": @{}
        }];
        return;
    }

    // 7. Endpoint dịch thuật (/api/v1/translate, /api/v1/translate/chapter,...)
    if ([path hasPrefix:@"/api/v1/translate"]) {
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

@interface UIViewController (EasyComixHook)
@end

@implementation UIViewController (EasyComixHook)

- (void)hook_viewDidAppear:(BOOL)animated {
    [self hook_viewDidAppear:animated];
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
// KHỞI TẠO TWEAK: GỠ BỎ GIỚI HẠN & KÍCH HOẠT PRO VĨNH VIỄN
// =========================================================================

__attribute__((constructor))
static void InitEasyComixGeminiHook(void) {
    LOG(@"EasyComix Gemini PRO Hook initialized. Model: %@", GetSavedGeminiModel());
    
    // Tự động xóa cache hạn mức cũ trong UserDefaults của app
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *key in [defaultsDict allKeys]) {
        if ([key containsString:@"quota"] || [key containsString:@"Quota"] || [key containsString:@"limit"] || [key containsString:@"Tier"]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // Xóa cache RevenueCat cũ bị lỗi verification để nạp mới
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
    
    // Hook RevenueCat Runtime
    HookRevenueCatClasses();
    
    // Đăng ký NSURLProtocol
    [NSURLProtocol registerClass:[EasyComixGeminiURLProtocol class]];
    
    // Swizzle các hàm tạo session configuration
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(defaultSessionConfiguration),
                       @selector(ec_defaultSessionConfiguration));
    SwizzleClassMethod([NSURLSessionConfiguration class],
                       @selector(ephemeralSessionConfiguration),
                       @selector(ec_ephemeralSessionConfiguration));
                  
    // Gắn nút cài đặt nổi trên UI & Tự động đóng modal chặn
    SwizzleMethod([UIViewController class],
                  @selector(viewDidAppear:),
                  @selector(hook_viewDidAppear:));
}
