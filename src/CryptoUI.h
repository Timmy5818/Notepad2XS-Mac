// 加解密介面：密碼視窗（文字密碼／金鑰檔案／網址）、預設密鑰（鑰匙圈）、背景執行與進度
#pragma once
#import <Cocoa/Cocoa.h>
#include <string>

typedef NS_ENUM(NSInteger, N2CryptoAlgorithm) {
    N2CryptoNone = 0,
    N2CryptoEXES,
    N2CryptoAES,
};

NSString *N2CryptoName(N2CryptoAlgorithm a);   // "EXES" / "AES"

// 依內容開頭判斷（區分大小寫、前面不可有空白）
N2CryptoAlgorithm N2CryptoDetect(const char *text, size_t length);

// 密碼（來源憑證 a）在記憶體中的保存：鎖定分頁不換出，釋放時覆寫
@interface N2Credential : NSObject
- (instancetype)initWithUTF8:(const char *)bytes length:(size_t)length;
- (std::string)secret;   // 取出明碼（呼叫端用完應盡快釋放）
@end

// 預設密鑰（存在 macOS 鑰匙圈，不寫入設定檔）
@interface N2DefaultKeys : NSObject
@property (nonatomic, copy) NSString *textPassword;
@property (nonatomic, copy) NSString *keyFilePath;
@property (nonatomic, copy) NSString *keyURL;
+ (N2DefaultKeys *)load;
- (BOOL)save:(NSError **)error;
@end

// 密碼視窗：以 sheet 顯示，完成時回傳來源憑證（nil = 取消）
@interface N2PasswordDialog : NSWindowController
+ (void)runForWindow:(NSWindow *)parent algorithm:(N2CryptoAlgorithm)algorithm encrypt:(BOOL)encrypt
          completion:(void (^)(N2Credential *credential))completion;
@end

// 在背景執行加解密並顯示進度 sheet。work 回傳結果；拋出例外視為失敗（error 為說明文字）。
void N2RunCryptoJob(NSWindow *parent, NSString *title, std::string (^work)(void),
                    void (^completion)(BOOL ok, const std::string &result, NSString *error));

// 預設密鑰設定視窗
@interface N2DefaultKeyWindow : NSWindowController
+ (void)show;
@end
