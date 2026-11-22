#import "CryptoUI.h"
#import "N2Common.h"
#import <Security/Security.h>
#include "ExAlgorithms.h"
#include "KeyFileCore.h"
#include "CryptoPrefix.h"
#include "CryptoProgressState.h"
#include "PasswordGenerator.h"
#include <atomic>
#include <memory>
#include <sys/mman.h>

#pragma mark - 共用

NSString *N2CryptoName(N2CryptoAlgorithm a) {
    return a == N2CryptoEXES ? @"EXES" : a == N2CryptoAES ? @"AES" : @"";
}

N2CryptoAlgorithm N2CryptoDetect(const char *text, size_t length) {
    switch (xs::cryptoPrefix(text, length)) {
        case xs::AutoDecryptKind::Exes: return N2CryptoEXES;
        case xs::AutoDecryptKind::Aes: return N2CryptoAES;
        default: return N2CryptoNone;
    }
}

// 原版 PasswordGenerator.h 的正式入口：以系統安全亂數產生 20 字元密碼
namespace xs {
std::wstring generatePassword() {
    return generatePassword([]() -> unsigned {
        uint8_t b = 0;
        if (SecRandomCopyBytes(kSecRandomDefault, 1, &b) != errSecSuccess) throw std::runtime_error("rng");
        return b;
    });
}
}

static NSString *GeneratePassword(void) {
    std::wstring w = xs::generatePassword();
    std::string s(w.begin(), w.end());   // 字元集全是 ASCII
    return [NSString stringWithUTF8String:s.c_str()];
}

#pragma mark - N2Credential

@implementation N2Credential {
    char *_buf;
    size_t _len;
    size_t _cap;   // 以整頁配置：mlock／munlock 以頁為單位且不計次數，各憑證獨占自己的頁面才不會互相解鎖
}
- (instancetype)initWithUTF8:(const char *)bytes length:(size_t)length {
    if ((self = [super init])) {
        _len = length;
        size_t page = (size_t)getpagesize();
        _cap = (MAX(length, (size_t)1) + page - 1) / page * page;
        void *p = NULL;
        if (posix_memalign(&p, page, _cap) == 0) {
            _buf = (char *)p;
            mlock(_buf, _cap);   // 不讓密碼被換出到磁碟
            memcpy(_buf, bytes, length);
        } else {
            _len = 0;
        }
    }
    return self;
}
- (std::string)secret { return _buf ? std::string(_buf, _len) : std::string(); }
- (void)dealloc {
    if (_buf) {
        volatile char *p = _buf;   // volatile：避免編譯器省略覆寫
        for (size_t i = 0; i < _cap; i++) p[i] = 0;
        munlock(_buf, _cap);
        free(_buf);
    }
}
@end

#pragma mark - 預設密鑰（鑰匙圈）

static NSString *const kKeychainService = @"Notepad2XS 預設密鑰";
static NSString *const kKeychainAccount = @"default";

@implementation N2DefaultKeys

+ (N2DefaultKeys *)load {
    N2DefaultKeys *k = [N2DefaultKeys new];
    NSData *data = N2KeychainRead(kKeychainService, kKeychainAccount);
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([d isKindOfClass:NSDictionary.class]) {
        k.textPassword = d[@"password"];
        k.keyFilePath = d[@"keyFile"];
        k.keyURL = d[@"url"];
    }
    return k;
}

- (BOOL)save:(NSError **)error {
    BOOL empty = !self.textPassword.length && !self.keyFilePath.length && !self.keyURL.length;
    NSData *data = empty ? nil : [NSJSONSerialization dataWithJSONObject:@{@"password": self.textPassword ?: @"",
                                                                           @"keyFile": self.keyFilePath ?: @"",
                                                                           @"url": self.keyURL ?: @""} options:0 error:nil];
    OSStatus st = N2KeychainWrite(kKeychainService, kKeychainAccount, data);   // 全部清空時刪除項目
    if (st != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:st userInfo:@{
            NSLocalizedDescriptionKey: @"無法寫入鑰匙圈。"}];
        return NO;
    }
    return YES;
}
@end

#pragma mark - 金鑰來源載入（檔案／網址）

// 由原始位元組算出來源憑證：Base64 → EX_MD3（與 Windows 版 KeyFileCore 相同）
static std::string KeySourcePassword(NSData *data, std::shared_ptr<std::atomic<bool>> cancelled) {
    xs::KeyFileInput input(data.length);
    input.append((const unsigned char *)data.bytes, data.length);
    input.complete();
    return input.password([cancelled](unsigned) { if (*cancelled) throw std::runtime_error("cancelled"); });
}

static NSData *ReadKeyFile(NSString *path, NSString **error) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attrs || ![attrs.fileType isEqualToString:NSFileTypeRegular]) { *error = @"找不到金鑰檔案，或它不是一般檔案。"; return nil; }
    unsigned long long size = attrs.fileSize;
    if (!xs::validKeyFileSize(size)) { *error = @"金鑰檔案大小需要在 100 位元組到 100 MiB 之間。"; return nil; }
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSDictionary *after = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!data || data.length != size || after.fileSize != size ||
        ![after.fileModificationDate isEqualToDate:attrs.fileModificationDate]) {
        *error = @"讀取金鑰檔案時發生錯誤，或檔案在讀取期間被修改。";
        return nil;
    }
    return data;
}

#pragma mark - 密碼視窗

typedef NS_ENUM(NSInteger, N2KeyMode) { N2KeyModeText = 0, N2KeyModeFile, N2KeyModeURL };

@interface N2PasswordDialog () <NSURLSessionTaskDelegate, NSTextFieldDelegate>
@end

@implementation N2PasswordDialog {
    N2CryptoAlgorithm _algorithm;
    BOOL _encrypt;
    void (^_completion)(N2Credential *);
    NSSegmentedControl *_mode;
    NSView *_textView, *_fileView, *_urlView;
    NSSecureTextField *_pw, *_pw2;
    NSTextField *_pwPlain, *_pw2Plain;
    NSButton *_show, *_generate, *_ok;
    NSTextField *_filePath, *_fileStatus, *_urlField, *_urlStatus;
    NSProgressIndicator *_fileSpin, *_urlSpin;
    N2Credential *_sourceCredential;   // 已載入的檔案／網址憑證
    N2KeyMode _sourceMode;
    std::shared_ptr<std::atomic<bool>> _cancelled;
    NSUInteger _token;
    NSURLSessionDataTask *_task;
    NSURLSession *_session;
}

static NSMutableSet *gOpenDialogs;

+ (void)runForWindow:(NSWindow *)parent algorithm:(N2CryptoAlgorithm)algorithm encrypt:(BOOL)encrypt
          completion:(void (^)(N2Credential *))completion {
    N2PasswordDialog *d = [[N2PasswordDialog alloc] initWithAlgorithm:algorithm encrypt:encrypt];
    d->_completion = [completion copy];
    if (!gOpenDialogs) gOpenDialogs = [NSMutableSet set];
    [gOpenDialogs addObject:d];
    if (parent) [parent beginSheet:d.window completionHandler:nil];
    else { [d.window center]; [d.window makeKeyAndOrderFront:nil]; }   // 沒有父視窗時改成獨立視窗，completion 仍會被呼叫
    [d applyDefaults];
}

- (instancetype)initWithAlgorithm:(N2CryptoAlgorithm)algorithm encrypt:(BOOL)encrypt {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 290) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    if ((self = [super initWithWindow:w])) {
        _algorithm = algorithm;
        _encrypt = encrypt;
        _cancelled = std::make_shared<std::atomic<bool>>(false);
        [self build];
    }
    return self;
}

static NSTextField *Lbl(NSString *s, NSRect r) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.frame = r;
    return l;
}

- (void)build {
    NSView *v = self.window.contentView;
    NSTextField *title = Lbl([NSString stringWithFormat:@"%@ %@", N2CryptoName(_algorithm), _encrypt ? @"加密" : @"解密"],
                             NSMakeRect(20, 250, 460, 22));
    title.font = [NSFont boldSystemFontOfSize:15];
    [v addSubview:title];

    _mode = [NSSegmentedControl segmentedControlWithLabels:@[@"文字密碼", @"金鑰檔案", @"網址"]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    _mode.frame = NSMakeRect(20, 212, 300, 26);
    _mode.selectedSegment = 0;
    [v addSubview:_mode];

    NSRect area = NSMakeRect(20, 60, 460, 140);
    // 文字密碼
    _textView = [[NSView alloc] initWithFrame:area];
    [_textView addSubview:Lbl(@"密碼：", NSMakeRect(0, 106, 60, 20))];
    _pw = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(64, 104, 390, 24)];
    _pwPlain = [[NSTextField alloc] initWithFrame:_pw.frame];
    [_textView addSubview:_pw]; [_textView addSubview:_pwPlain];
    if (_encrypt) {
        [_textView addSubview:Lbl(@"確認：", NSMakeRect(0, 72, 60, 20))];
        _pw2 = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(64, 70, 390, 24)];
        _pw2Plain = [[NSTextField alloc] initWithFrame:_pw2.frame];
        [_textView addSubview:_pw2]; [_textView addSubview:_pw2Plain];
    }
    for (NSTextField *f in @[_pw, _pwPlain]) f.delegate = self;
    if (_pw2) for (NSTextField *f in @[_pw2, _pw2Plain]) f.delegate = self;
    _pwPlain.hidden = YES; _pw2Plain.hidden = YES;
    _show = [NSButton checkboxWithTitle:@"顯示密碼" target:self action:@selector(toggleShow:)];
    _show.frame = NSMakeRect(62, 38, 120, 20);
    [_textView addSubview:_show];
    if (_encrypt) {
        _generate = [NSButton buttonWithTitle:@"隨機生成密碼" target:self action:@selector(generate:)];
        _generate.frame = NSMakeRect(190, 31, 140, 32);
        [_textView addSubview:_generate];
    }
    // 金鑰檔案
    _fileView = [[NSView alloc] initWithFrame:area];
    _filePath = Lbl(@"尚未選擇檔案", NSMakeRect(0, 106, 454, 20));
    _filePath.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_fileView addSubview:_filePath];
    NSButton *browse = [NSButton buttonWithTitle:@"瀏覽檔案…" target:self action:@selector(browse:)];
    browse.frame = NSMakeRect(-6, 66, 120, 32);
    [_fileView addSubview:browse];
    _fileSpin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 38, 16, 16)];
    _fileSpin.style = NSProgressIndicatorStyleSpinning; _fileSpin.displayedWhenStopped = NO;
    [_fileView addSubview:_fileSpin];
    _fileStatus = Lbl(@"金鑰檔案需為 100 位元組到 100 MiB；內容必須和加密時完全相同。", NSMakeRect(22, 36, 432, 20));
    _fileStatus.textColor = NSColor.secondaryLabelColor;
    [_fileView addSubview:_fileStatus];
    // 網址
    _urlView = [[NSView alloc] initWithFrame:area];
    [_urlView addSubview:Lbl(@"網址：", NSMakeRect(0, 106, 60, 20))];
    _urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(64, 104, 390, 24)];
    _urlField.placeholderString = @"https://";
    _urlField.delegate = self;
    [_urlView addSubview:_urlField];
    NSButton *load = [NSButton buttonWithTitle:@"載入" target:self action:@selector(loadURL:)];
    load.frame = NSMakeRect(58, 66, 90, 32);
    [_urlView addSubview:load];
    _urlSpin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 38, 16, 16)];
    _urlSpin.style = NSProgressIndicatorStyleSpinning; _urlSpin.displayedWhenStopped = NO;
    [_urlView addSubview:_urlSpin];
    _urlStatus = Lbl(@"支援 HTTP／HTTPS，回應內容需為 100 位元組到 100 MiB。", NSMakeRect(22, 36, 432, 20));
    _urlStatus.textColor = NSColor.secondaryLabelColor;
    [_urlView addSubview:_urlStatus];

    for (NSView *x in @[_textView, _fileView, _urlView]) [v addSubview:x];

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(290, 14, 96, 32);
    cancel.keyEquivalent = @"\033";
    _ok = [NSButton buttonWithTitle:@"確定" target:self action:@selector(confirm:)];
    _ok.frame = NSMakeRect(390, 14, 96, 32);
    _ok.keyEquivalent = @"\r";
    [v addSubview:cancel]; [v addSubview:_ok];
    [self modeChanged:nil];
}

// 預選順序：已設定的金鑰檔案 → 網址 → 文字密碼（預填預設文字密碼）
- (void)applyDefaults {
    N2DefaultKeys *k = [N2DefaultKeys load];
    if (k.keyFilePath.length) {
        _mode.selectedSegment = N2KeyModeFile;
        [self modeChanged:nil];
        [self loadKeyFile:k.keyFilePath];
    } else if (k.keyURL.length) {
        _mode.selectedSegment = N2KeyModeURL;
        _urlField.stringValue = k.keyURL;
        [self modeChanged:nil];
        [self loadURL:nil];
    } else if (k.textPassword.length) {
        [self setPassword:k.textPassword];
    }
    [self.window makeFirstResponder:_mode.selectedSegment == N2KeyModeText ? (NSView *)_pw : nil];
}

- (void)setPassword:(NSString *)p {
    _pw.stringValue = p; _pwPlain.stringValue = p;
    _pw2.stringValue = _encrypt ? p : @""; _pw2Plain.stringValue = _pw2.stringValue;
    [self validate];
}

- (NSString *)passwordValue { return _show.state == NSControlStateValueOn ? _pwPlain.stringValue : _pw.stringValue; }
- (NSString *)confirmValue { return _show.state == NSControlStateValueOn ? _pw2Plain.stringValue : _pw2.stringValue; }

- (void)modeChanged:(id)sender {
    N2KeyMode m = (N2KeyMode)_mode.selectedSegment;
    _textView.hidden = m != N2KeyModeText;
    _fileView.hidden = m != N2KeyModeFile;
    _urlView.hidden = m != N2KeyModeURL;
    [self validate];
}

- (void)toggleShow:(id)sender {
    BOOL show = _show.state == NSControlStateValueOn;
    if (show) { _pwPlain.stringValue = _pw.stringValue; _pw2Plain.stringValue = _pw2.stringValue ?: @""; }
    else { _pw.stringValue = _pwPlain.stringValue; _pw2.stringValue = _pw2Plain.stringValue ?: @""; }
    _pw.hidden = show; _pwPlain.hidden = !show;
    if (_pw2) { _pw2.hidden = show; _pw2Plain.hidden = !show; }
}

- (void)generate:(id)sender {
    [self setPassword:GeneratePassword()];
    _show.state = NSControlStateValueOn;
    [self toggleShow:nil];
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object == _urlField) [self abandonURLLoad];
    [self validate];
}

- (void)validate {
    N2KeyMode m = (N2KeyMode)_mode.selectedSegment;
    BOOL ok;
    if (m == N2KeyModeText) {
        NSString *p = self.passwordValue;
        ok = p.length > 0 && [p lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024 * 1024 &&
             (!_encrypt || [p isEqualToString:self.confirmValue]);
    } else {
        ok = _sourceCredential != nil && _sourceMode == m;
    }
    _ok.enabled = ok;
}

// 網址改了：作廢進行中的下載與計算（遞增 token，舊結果回來會被忽略）
- (void)abandonURLLoad {
    if (_sourceMode != N2KeyModeURL) return;
    _cancelled->store(true);
    _cancelled = std::make_shared<std::atomic<bool>>(false);
    _token++;
    [_task cancel];
    _task = nil;
    [_session invalidateAndCancel];
    _session = nil;
    _sourceCredential = nil;
    [_urlSpin stopAnimation:nil];
    _mode.enabled = YES;
    _urlStatus.stringValue = @"按「載入」下載金鑰內容。";
    _urlStatus.textColor = NSColor.secondaryLabelColor;
    [self validate];
}

- (void)beginLoading:(N2KeyMode)mode status:(NSString *)status {
    _cancelled->store(true);
    _cancelled = std::make_shared<std::atomic<bool>>(false);
    _token++;
    _sourceCredential = nil;
    _sourceMode = mode;
    NSTextField *label = mode == N2KeyModeFile ? _fileStatus : _urlStatus;
    label.stringValue = status;
    label.textColor = NSColor.secondaryLabelColor;
    [(mode == N2KeyModeFile ? _fileSpin : _urlSpin) startAnimation:nil];
    _mode.enabled = NO;   // 計算期間不能切換模式
    [self validate];
}

- (void)finishLoading:(N2KeyMode)mode token:(NSUInteger)token credential:(N2Credential *)cred error:(NSString *)err {
    if (token != _token) return;
    [(mode == N2KeyModeFile ? _fileSpin : _urlSpin) stopAnimation:nil];
    _mode.enabled = YES;
    NSTextField *label = mode == N2KeyModeFile ? _fileStatus : _urlStatus;
    if (cred) {
        _sourceCredential = cred;
        label.stringValue = mode == N2KeyModeFile ? @"已載入金鑰檔案，按「確定」繼續。" : @"已載入網址內容，按「確定」繼續。";
        label.textColor = NSColor.systemGreenColor;
    } else {
        label.stringValue = err ?: @"載入失敗。";
        label.textColor = NSColor.systemRedColor;
    }
    [self validate];
}

- (void)computeFromData:(NSData *)data mode:(N2KeyMode)mode token:(NSUInteger)token {
    auto cancelled = _cancelled;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        N2Credential *cred = nil;
        NSString *err = nil;
        try {
            std::string a = KeySourcePassword(data, cancelled);
            cred = [[N2Credential alloc] initWithUTF8:a.data() length:a.size()];
            std::fill(a.begin(), a.end(), '\0');
        } catch (const std::length_error &) {
            err = @"內容大小需要在 100 位元組到 100 MiB 之間。";
        } catch (...) {
            err = *cancelled ? nil : @"計算金鑰時發生錯誤。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishLoading:mode token:token credential:cred error:err]; });
    });
}

- (void)browse:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = @"選擇金鑰檔案（可以是圖片、ZIP 或任何檔案）";
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) [self loadKeyFile:p.URL.path];
    }];
}

- (void)loadKeyFile:(NSString *)path {
    _filePath.stringValue = path;
    [self beginLoading:N2KeyModeFile status:@"讀取與計算中…"];
    NSUInteger token = _token;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSData *data = ReadKeyFile(path, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!data) [self finishLoading:N2KeyModeFile token:token credential:nil error:err];
            else [self computeFromData:data mode:N2KeyModeFile token:token];
        });
    });
}

- (void)loadURL:(id)sender {
    NSURL *url = [NSURL URLWithString:[_urlField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || !url.host.length || url.user || url.password) {
        [self beginLoading:N2KeyModeURL status:@""];   // 作廢先前的下載（遞增 token）
        [_task cancel];
        [self finishLoading:N2KeyModeURL token:_token credential:nil error:@"請輸入有效的 http:// 或 https:// 網址（不支援內嵌帳號密碼）。"];
        return;
    }
    [self beginLoading:N2KeyModeURL status:@"下載中…"];
    NSUInteger token = _token;
    [_task cancel];
    [_session invalidateAndCancel];   // session 會強引用 delegate（self），舊的不釋放會一直抓著這個視窗
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 60;
    cfg.timeoutIntervalForResource = 300;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _task = [_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSString *err = nil;
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (error) err = error.code == NSURLErrorCancelled ? nil : [NSString stringWithFormat:@"下載失敗：%@", error.localizedDescription];
        else if (http.statusCode != 200) err = [NSString stringWithFormat:@"網址回應不是 200（實際為 %ld）。", (long)http.statusCode];
        else if (!xs::validKeyFileSize(data.length)) err = @"下載內容大小需要在 100 位元組到 100 MiB 之間。";
        else if (resp.expectedContentLength >= 0 && (unsigned long long)resp.expectedContentLength != data.length) err = @"網址回傳的檔案長度不正確。";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) [self finishLoading:N2KeyModeURL token:token credential:nil error:err ?: @"下載失敗。"];
            else [self computeFromData:data mode:N2KeyModeURL token:token];
        });
    }];
    [_task resume];
}

// 轉址：最多 5 次，且不允許 HTTPS 降級成 HTTP
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    static NSString *const kCount = @"N2RedirectCount";
    NSInteger count = [[NSURLProtocol propertyForKey:kCount inRequest:task.currentRequest] integerValue] + 1;
    BOOL downgrade = [task.originalRequest.URL.scheme.lowercaseString isEqualToString:@"https"] &&
                     ![request.URL.scheme.lowercaseString isEqualToString:@"https"];
    if (count > 5 || downgrade) { completionHandler(nil); return; }
    NSMutableURLRequest *next = [request mutableCopy];
    [NSURLProtocol setProperty:@(count) forKey:kCount inRequest:next];
    completionHandler(next);
}

- (void)finish:(N2Credential *)cred {
    _cancelled->store(true);
    [_task cancel];
    [_session invalidateAndCancel];
    _pw.stringValue = @""; _pwPlain.stringValue = @""; _pw2.stringValue = @""; _pw2Plain.stringValue = @"";
    if (self.window.sheetParent) [self.window.sheetParent endSheet:self.window];
    else [self.window orderOut:nil];
    void (^done)(N2Credential *) = _completion;
    _completion = nil;
    [gOpenDialogs removeObject:self];
    if (done) done(cred);
}

- (void)cancel:(id)sender { [self finish:nil]; }

- (void)confirm:(id)sender {
    [self validate];
    if (!_ok.enabled) { NSBeep(); return; }
    if (_mode.selectedSegment == N2KeyModeText) {
        NSData *d = [self.passwordValue dataUsingEncoding:NSUTF8StringEncoding];
        [self finish:[[N2Credential alloc] initWithUTF8:(const char *)d.bytes length:d.length]];
    } else {
        [self finish:_sourceCredential];
    }
}

@end

#pragma mark - 背景執行與進度

void N2RunCryptoJob(NSWindow *parent, NSString *title, std::string (^work)(void),
                    void (^completion)(BOOL ok, const std::string &result, NSString *error)) {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 110) styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:YES];
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = NSMakeRect(20, 72, 340, 20);
    label.font = [NSFont boldSystemFontOfSize:13];
    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 46, 340, 20)];
    bar.style = NSProgressIndicatorStyleBar;
    bar.indeterminate = YES;
    bar.minValue = 0; bar.maxValue = 1;
    [bar startAnimation:nil];
    NSTextField *detail = [NSTextField labelWithString:@"準備中…"];
    detail.frame = NSMakeRect(20, 18, 340, 18);
    detail.textColor = NSColor.secondaryLabelColor;
    for (NSView *x in @[label, bar, detail]) [panel.contentView addSubview:x];
    if (parent) [parent beginSheet:panel completionHandler:nil];
    else { [panel center]; [panel orderFront:nil]; }

    auto state = std::make_shared<xs::CryptoProgressState>();
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        xs::CryptoUpdate u = state->read();
        static NSArray *names = @[@"準備中…", @"衍生金鑰中…", @"加密中…", @"驗證中…", @"解密中…", @"編碼中…", @"儲存中…", @"完成"];
        NSString *stage = (size_t)u.stage < names.count ? names[(size_t)u.stage] : @"";
        if (u.stage == xs::CryptoStage::Deriving && u.total > 0) {
            bar.indeterminate = NO;
            bar.doubleValue = (double)u.completed / u.total;
            detail.stringValue = [NSString stringWithFormat:@"衍生金鑰 %u / %u（%.0f%%）", u.completed, u.total, 100.0 * u.completed / u.total];
        } else {
            if (!bar.indeterminate) { bar.indeterminate = YES; [bar startAnimation:nil]; }
            detail.stringValue = stage;
        }
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string result;
        NSString *err = nil;
        BOOL ok = NO;
        try {
            xs::CryptoObserver obs = [state](xs::CryptoUpdate u) { state->publish(u); };
            xs::CryptoObserverScope scope(obs);
            result = work();
            ok = YES;
        } catch (const std::exception &e) {
            err = [NSString stringWithUTF8String:e.what()] ?: @"error";
        } catch (...) {
            err = @"error";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            if (parent) [parent endSheet:panel];
            else [panel orderOut:nil];
            completion(ok, result, err);
        });
    });
}

#pragma mark - 預設密鑰設定視窗

@implementation N2DefaultKeyWindow {
    NSSecureTextField *_pw;
    NSTextField *_pwPlain, *_file, *_url;
    NSButton *_show;
}

+ (void)show {
    static N2DefaultKeyWindow *w;
    if (!w) w = [[N2DefaultKeyWindow alloc] init];
    [w reload];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 330)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    win.title = @"預設密鑰";
    if ((self = [super initWithWindow:win])) { [self build]; [win center]; }
    return self;
}

- (void)build {
    NSView *v = self.window.contentView;
    NSTextField *info = [NSTextField wrappingLabelWithString:
        @"AES／EXES 的密碼視窗會依序預選：金鑰檔案 → 網址 → 文字密碼。這些設定保存在 macOS 鑰匙圈，不寫入設定檔；"
        @"金鑰檔案只保存路徑，不保存內容。"];
    info.frame = NSMakeRect(20, 266, 500, 48);
    info.textColor = NSColor.secondaryLabelColor;
    [v addSubview:info];

    [v addSubview:Lbl(@"預設文字密碼：", NSMakeRect(20, 232, 200, 20))];
    _pw = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 204, 500, 24)];
    _pwPlain = [[NSTextField alloc] initWithFrame:_pw.frame];
    _pwPlain.hidden = YES;
    [v addSubview:_pw]; [v addSubview:_pwPlain];
    _show = [NSButton checkboxWithTitle:@"顯示" target:self action:@selector(toggleShow:)];
    _show.frame = NSMakeRect(20, 176, 80, 20);
    [v addSubview:_show];
    NSButton *gen = [NSButton buttonWithTitle:@"隨機生成密碼" target:self action:@selector(generate:)];
    gen.frame = NSMakeRect(100, 170, 140, 32);
    [v addSubview:gen];
    NSButton *clr = [NSButton buttonWithTitle:@"清除" target:self action:@selector(clearPassword:)];
    clr.frame = NSMakeRect(240, 170, 80, 32);
    [v addSubview:clr];

    [v addSubview:Lbl(@"預設金鑰檔案：", NSMakeRect(20, 142, 200, 20))];
    _file = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 114, 330, 24)];
    _file.editable = NO;
    _file.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [v addSubview:_file];
    NSButton *browse = [NSButton buttonWithTitle:@"瀏覽…" target:self action:@selector(browse:)];
    browse.frame = NSMakeRect(352, 108, 90, 32);
    [v addSubview:browse];
    NSButton *clrFile = [NSButton buttonWithTitle:@"清除" target:self action:@selector(clearFile:)];
    clrFile.frame = NSMakeRect(440, 108, 86, 32);
    [v addSubview:clrFile];

    [v addSubview:Lbl(@"預設網址：", NSMakeRect(20, 84, 200, 20))];
    _url = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 56, 420, 24)];
    _url.placeholderString = @"https://";
    [v addSubview:_url];
    NSButton *clrURL = [NSButton buttonWithTitle:@"清除" target:self action:@selector(clearURL:)];
    clrURL.frame = NSMakeRect(440, 50, 86, 32);
    [v addSubview:clrURL];

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(close)];
    cancel.frame = NSMakeRect(326, 10, 96, 32);
    cancel.keyEquivalent = @"\033";
    NSButton *save = [NSButton buttonWithTitle:@"儲存" target:self action:@selector(save:)];
    save.frame = NSMakeRect(426, 10, 96, 32);
    save.keyEquivalent = @"\r";
    [v addSubview:cancel]; [v addSubview:save];
}

- (void)reload {
    N2DefaultKeys *k = [N2DefaultKeys load];
    _pw.stringValue = k.textPassword ?: @"";
    _pwPlain.stringValue = _pw.stringValue;
    _file.stringValue = k.keyFilePath ?: @"";
    _url.stringValue = k.keyURL ?: @"";
}

- (NSString *)passwordValue { return _show.state == NSControlStateValueOn ? _pwPlain.stringValue : _pw.stringValue; }

- (void)toggleShow:(id)sender {
    BOOL show = _show.state == NSControlStateValueOn;
    if (show) _pwPlain.stringValue = _pw.stringValue; else _pw.stringValue = _pwPlain.stringValue;
    _pw.hidden = show; _pwPlain.hidden = !show;
}
- (void)generate:(id)sender {
    NSString *p = GeneratePassword();
    _pw.stringValue = p; _pwPlain.stringValue = p;
    _show.state = NSControlStateValueOn;
    [self toggleShow:nil];
}
- (void)clearPassword:(id)sender { _pw.stringValue = @""; _pwPlain.stringValue = @""; }
- (void)clearFile:(id)sender { _file.stringValue = @""; }
- (void)clearURL:(id)sender { _url.stringValue = @""; }

- (void)browse:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = NO;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:p.URL.path error:nil] fileSize];
        if (!xs::validKeyFileSize(size)) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"金鑰檔案大小需要在 100 位元組到 100 MiB 之間。";
            [a beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        self->_file.stringValue = p.URL.path;
    }];
}

- (void)save:(id)sender {
    NSString *url = [_url.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSURL *u = url.length ? [NSURL URLWithString:url] : nil;
    if (url.length && (!u || !([u.scheme.lowercaseString isEqualToString:@"http"] || [u.scheme.lowercaseString isEqualToString:@"https"]) || !u.host.length)) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"請輸入有效的 http:// 或 https:// 網址。";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    N2DefaultKeys *k = [N2DefaultKeys new];
    k.textPassword = self.passwordValue;
    k.keyFilePath = _file.stringValue;
    k.keyURL = url;
    NSError *err = nil;
    if (![k save:&err]) { [self presentError:err modalForWindow:self.window delegate:nil didPresentSelector:nil contextInfo:NULL]; return; }
    [self close];
}

@end
