#import "AiUI.h"
#import "N2Common.h"
#import "EditorWindowController.h"
#import "Document.h"
#import "ScintillaView.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#include "OrCore.h"
#include <atomic>
#include <memory>
#include <mutex>

#pragma mark - 設定保存（鑰匙圈；格式沿用 Windows 版 orSavePreferences v4）

static NSString *const kAiService = @"Notepad2XS 人工智慧設定";

static NSString *ErrText(const std::exception &e) { return N2FromUTF8(e.what()); }

static xs::OrPreferences &Prefs() {
    static xs::OrPreferences *prefs;
    if (!prefs) {
        prefs = new xs::OrPreferences();
        if (NSData *d = N2KeychainRead(kAiService, @"default")) {
            try { *prefs = xs::orLoadPreferences(std::string((const char *)d.bytes, d.length)); }
            catch (...) { /* 設定損毀：使用預設值（含七個預設範本） */ }
        }
    }
    return *prefs;
}

static BOOL SavePrefs(NSString **error) {
    std::string json;
    try { json = xs::orSavePreferences(Prefs()); }
    catch (const std::exception &e) { if (error) *error = ErrText(e); return NO; }
    NSData *data = [NSData dataWithBytes:json.data() length:json.size()];
    std::fill(json.begin(), json.end(), '\0');
    OSStatus st = N2KeychainWrite(kAiService, @"default", data);
    if (st != errSecSuccess) { if (error) *error = @"無法寫入鑰匙圈。"; return NO; }
    return YES;
}

void N2AiClearApiKeys(void) {
    xs::OrPreferences &p = Prefs();
    std::vector<std::string *> keys = {&p.key, &p.googleKey, &p.nvidia.key, &p.deepseek.key};
    for (auto &service : p.additional) keys.push_back(&service.key);
    for (std::string *k : keys) {
        std::fill(k->begin(), k->end(), '\0');
        k->clear();
    }
    SavePrefs(nil);
}

#pragma mark - HTTP

struct AiCancelled {};


// 接收回應：限制大小、可取消；串流服務（R134 新增的六家）邊收邊解析並回報目前文字
@interface N2AiReceiver : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) BOOL streaming;
@end
@implementation N2AiReceiver {
@public
    std::unique_ptr<xs::AiStream> _stream;
    std::string _body;
    size_t _received;
    BOOL _tooLarge;
    std::string _streamError;   // 串流解析失敗的說明（不能讓 C++ 例外穿過系統的委派呼叫）
    NSHTTPURLResponse *_response;
    NSError *_error;
    dispatch_semaphore_t _done;
    std::function<void(const std::string &)> _progress;
    CFAbsoluteTime _lastUpdate;
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r
        newRequest:(NSURLRequest *)req completionHandler:(void (^)(NSURLRequest *))h { h(nil); }   // 不跟隨重新導向
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r
 completionHandler:(void (^)(NSURLSessionResponseDisposition))h {
    _response = (NSHTTPURLResponse *)r;
    h(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    if (_tooLarge || !_streamError.empty()) return;
    _received += data.length;
    BOOL streaming = _stream && _response.statusCode == 200;
    // 串流的每段都帶有 JSON 外框，原始位元組比答覆大很多：答覆本身由 AiStream 限制在 1 MiB
    if (_received > (streaming ? 32 * xs::orResponseLimit : xs::orResponseLimit)) { _tooLarge = YES; [t cancel]; return; }
    if (streaming) {
        __block bool changed = false;
        try {
            [data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) {
                changed = self->_stream->feed((const char *)bytes, range.length) || changed;
            }];
        } catch (const std::exception &e) {
            _streamError = e.what();
            [t cancel];
            return;
        } catch (...) {
            _streamError = u8"AI 串流回答未正常結束，原文未變更。";
            [t cancel];
            return;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (changed && _progress && now - _lastUpdate >= 0.08) { _progress(_stream->text()); _lastUpdate = now; }
    } else {
        _body.append((const char *)data.bytes, data.length);
    }
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    _error = error;
    dispatch_semaphore_signal(_done);
}
@end

// 與 Windows 版 aiHttp 相同：固定主機與路徑、HTTPS（本機 Ollama 只用 127.0.0.1 的 HTTP）、120 秒、不跟隨轉址、
// 不用 Cookie、回應上限 2 MiB；progress 不為空時以串流接收（只有新服務）
static std::pair<unsigned, std::string> AiHttp(xs::AiProvider provider, const std::string &key, const std::string &body,
                                               xs::AiOperation op, const std::string &model, const std::string &page,
                                               std::shared_ptr<std::atomic<bool>> cancel, const std::string &endpoint = {},
                                               std::function<void(const std::string &)> progress = nullptr) {
    if (xs::aiRequiresKey(provider) && !xs::validOrKey(key)) throw std::runtime_error(u8"請先在「人工智慧連接設定」輸入有效的 API Key。");
    xs::AiEndpoint ep = xs::aiEndpoint(provider, op, model, page, endpoint);
    std::string origin = (ep.secure ? "https://" : "http://") + ep.host;
    if (!ep.secure || ep.port != 443) origin += ":" + std::to_string(ep.port);
    NSURL *url = [NSURL URLWithString:N2FromUTF8(origin + ep.path)];
    if (!url) throw std::runtime_error(u8"服務位址不正確。");
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:120];
    req.HTTPMethod = N2FromUTF8(ep.method);
    req.HTTPShouldHandleCookies = NO;
    if (!body.empty()) req.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    if (xs::aiRequiresKey(provider)) {
        NSString *k = N2FromUTF8(key);
        if (provider == xs::AiProvider::google) [req setValue:k forHTTPHeaderField:@"x-goog-api-key"];
        else if (provider == xs::AiProvider::claude) [req setValue:k forHTTPHeaderField:@"x-api-key"];
        else if (provider == xs::AiProvider::azure) [req setValue:k forHTTPHeaderField:@"api-key"];
        else [req setValue:[@"Bearer " stringByAppendingString:k] forHTTPHeaderField:@"Authorization"];
    }
    if (provider == xs::AiProvider::claude) [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:progress ? @"text/event-stream, application/x-ndjson" : @"application/json" forHTTPHeaderField:@"Accept"];
    if (provider == xs::AiProvider::openRouter) {
        [req setValue:@"https://dz.jplopsoft.idv.tw/" forHTTPHeaderField:@"HTTP-Referer"];
        [req setValue:@"notepad2xs" forHTTPHeaderField:@"X-Title"];
    }
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 120;
    cfg.timeoutIntervalForResource = 120;
    cfg.HTTPCookieStorage = nil;
    cfg.URLCache = nil;
    if (!ep.secure) cfg.connectionProxyDictionary = @{};   // 本機服務不經過 Proxy
    N2AiReceiver *rx = [N2AiReceiver new];
    rx->_done = dispatch_semaphore_create(0);
    if (progress) { rx->_stream = std::make_unique<xs::AiStream>(provider); rx->_progress = progress; }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:rx delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
    [task resume];
    while (dispatch_semaphore_wait(rx->_done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (cancel && *cancel) [task cancel];
    }
    [session finishTasksAndInvalidate];
    if (cancel && *cancel) throw AiCancelled{};
    if (!rx->_streamError.empty()) throw std::runtime_error(rx->_streamError);
    if (rx->_tooLarge) throw std::runtime_error(u8"人工智慧回應超過 2 MiB，原文未變更。");
    if (rx->_error) {
        if (rx->_error.code == NSURLErrorTimedOut) throw std::runtime_error(u8"人工智慧請求超過 120 秒，原文未變更。");
        throw std::runtime_error(std::string(u8"無法連線到 ") + xs::aiProviderName(provider) + u8"：" + N2ToUTF8(rx->_error.localizedDescription));
    }
    unsigned status = (unsigned)rx->_response.statusCode;
    if (rx->_stream && status == 200) return {status, rx->_stream->finish()};
    return {status, rx->_body};
}

#pragma mark - 進度（可取消）

// 按鈕動作改用 block
@interface N2BlockTarget : NSObject
@property (nonatomic, copy) void (^block)(id sender);
+ (instancetype)attach:(NSControl *)control block:(void (^)(id sender))block;
@end
@implementation N2BlockTarget
+ (instancetype)attach:(NSControl *)control block:(void (^)(id))block {
    N2BlockTarget *t = [N2BlockTarget new];
    t.block = block;
    control.target = t;
    control.action = @selector(fire:);
    objc_setAssociatedObject(control, "n2target", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // 跟著按鈕存活
    return t;
}
- (void)fire:(id)sender { if (self.block) self.block(sender); }
@end

static void RunAiJob(NSWindow *parent, NSString *title, std::string (^work)(std::shared_ptr<std::atomic<bool>>),
                     void (^done)(BOOL ok, const std::string &result, NSString *error)) {
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 100) styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:YES];
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 52, 24, 24)];
    spin.style = NSProgressIndicatorStyleSpinning;
    [spin startAnimation:nil];
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = NSMakeRect(54, 56, 310, 18);
    NSButton *stop = [NSButton buttonWithTitle:@"取消" target:nil action:nil];
    stop.frame = NSMakeRect(270, 10, 96, 32);
    stop.keyEquivalent = @"\033";
    [N2BlockTarget attach:stop block:^(id sender) {
        *cancel = true;
        label.stringValue = @"正在取消…";
    }];
    for (NSView *v in @[spin, label, stop]) [panel.contentView addSubview:v];
    [parent beginSheet:panel completionHandler:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string result;
        NSString *error = nil;
        BOOL ok = NO;
        try { result = work(cancel); ok = YES; }
        catch (const AiCancelled &) { error = nil; }
        catch (const std::exception &e) { error = ErrText(e); }
        catch (...) { error = @"發生未知錯誤，原文未變更。"; }
        BOOL cancelled = *cancel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [parent endSheet:panel];
            if (cancelled) done(NO, std::string(), nil);   // 取消：不套用、不提示
            else done(ok, result, error);
        });
    });
}

static void Alert(NSWindow *w, NSString *msg, NSString *info) {
    NSAlert *a = [NSAlert new];
    a.messageText = msg;
    if (info) a.informativeText = info;
    if (w) [a beginSheetModalForWindow:w completionHandler:nil]; else [a runModal];
}

static NSString *OutputName(xs::AiOutputMode m) { return N2FromUTF8(xs::aiOutputName(m)); }
static const xs::AiOutputMode kOutputs[] = {xs::AiOutputMode::replace, xs::AiOutputMode::insertBelow,
                                            xs::AiOutputMode::newWindow, xs::AiOutputMode::displayOnly};
static const int kProviderCount = (int)xs::AiProvider::count;
// 讀取服務網址：一定要用 const 版本（非 const 版本在固定網址的服務會拋出例外，只能用來寫入）
static std::string Endpoint(const xs::OrPreferences &p) { return p.activeEndpoint(); }   // 10 家：原有 4 家＋R134 新增 6 家

static NSScrollView *TextArea(NSRect r, NSTextView **out, BOOL editable) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:r];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.autoresizingMask = NSViewWidthSizable;
    tv.richText = NO;
    tv.editable = editable;
    tv.font = [NSFont systemFontOfSize:13];
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.textContainerInset = NSMakeSize(4, 4);
    sv.documentView = tv;
    *out = tv;
    return sv;
}

// 串流顯示（R134 新服務）：處理視窗即時更新收到的文字，「停止」中斷
static void RunAiStreamJob(NSWindow *parent, NSString *title,
                           std::string (^work)(std::shared_ptr<std::atomic<bool>>, std::function<void(const std::string &)>),
                           void (^done)(BOOL ok, const std::string &result, NSString *error)) {
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 340)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered defer:YES];
    NSView *v = panel.contentView;
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(16, 306, 18, 18)];
    spin.style = NSProgressIndicatorStyleSpinning;
    spin.controlSize = NSControlSizeSmall;
    spin.autoresizingMask = NSViewMinYMargin;
    [spin startAnimation:nil];
    NSTextField *label = [NSTextField labelWithString:title];
    label.frame = NSMakeRect(40, 306, 500, 18);
    label.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
    NSTextView *tv = nil;
    NSScrollView *sv = TextArea(NSMakeRect(16, 56, 528, 242), &tv, NO);
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSButton *stop = [NSButton buttonWithTitle:@"停止" target:nil action:nil];
    stop.frame = NSMakeRect(448, 12, 96, 32);
    stop.autoresizingMask = NSViewMinXMargin;
    stop.keyEquivalent = @"\033";
    [N2BlockTarget attach:stop block:^(id sender) {
        *cancel = true;
        label.stringValue = @"正在停止…";
    }];
    for (NSView *x in @[spin, label, sv, stop]) [v addSubview:x];
    [parent beginSheet:panel completionHandler:nil];
    // 背景收到新文字時只記下最新內容，由主執行緒定時顯示
    auto latest = std::make_shared<std::string>();
    auto lock = std::make_shared<std::mutex>();
    auto shown = std::make_shared<size_t>(0);
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        std::string text;
        { std::lock_guard<std::mutex> g(*lock); if (latest->size() == *shown) return; text = *latest; }
        *shown = text.size();
        tv.string = N2FromUTF8(xs::orNormalizeEol(text, SC_EOL_LF)) ?: @"";
        [tv scrollToEndOfDocument:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string result;
        NSString *error = nil;
        BOOL ok = NO;
        try {
            result = work(cancel, [latest, lock](const std::string &text) { std::lock_guard<std::mutex> g(*lock); *latest = text; });
            ok = YES;
        }
        catch (const AiCancelled &) { error = nil; }
        catch (const std::exception &e) { error = ErrText(e); }
        catch (...) { error = @"發生未知錯誤，原文未變更。"; }
        BOOL cancelled = *cancel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            [parent endSheet:panel];
            if (cancelled) done(NO, std::string(), nil);   // 停止：不套用、不提示
            else done(ok, result, error);
        });
    });
}

#pragma mark - 結果顯示視窗

static void ShowResult(NSWindow *parent, const std::string &answer, NSString *note) {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 620, 440)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:YES];
    NSView *v = p.contentView;
    NSTextField *title = [NSTextField labelWithString:note ?: @"AI 結果（只顯示，不修改原文）"];
    title.frame = NSMakeRect(16, 404, 588, 20);
    title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [v addSubview:title];
    NSTextView *tv = nil;
    NSScrollView *sv = TextArea(NSMakeRect(16, 56, 588, 340), &tv, NO);
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.string = N2FromUTF8(answer);
    tv.selectable = YES;
    [v addSubview:sv];
    NSButton *copy = [NSButton buttonWithTitle:@"全部拷貝" target:nil action:nil];
    copy.frame = NSMakeRect(392, 12, 110, 32);
    copy.autoresizingMask = NSViewMinXMargin;
    NSButton *close = [NSButton buttonWithTitle:@"關閉" target:nil action:nil];
    close.frame = NSMakeRect(504, 12, 100, 32);
    close.keyEquivalent = @"\r";
    close.autoresizingMask = NSViewMinXMargin;
    [v addSubview:copy]; [v addSubview:close];
    NSString *text = tv.string;
    [N2BlockTarget attach:copy block:^(id sender) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    }];
    [N2BlockTarget attach:close block:^(NSButton *sender) { [sender.window.sheetParent endSheet:sender.window]; }];
    [parent beginSheet:p completionHandler:nil];
}

// 完整接收後的預覽：可拷貝，或按「（結果處理方式）」套用
static void ReviewResult(NSWindow *parent, const std::string &answer, NSString *action, void (^apply)(void)) {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 620, 440)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:YES];
    NSView *v = p.contentView;
    NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:@"AI 結果預覽：確認後「%@」", action]];
    title.frame = NSMakeRect(16, 404, 588, 20);
    title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [v addSubview:title];
    NSTextView *tv = nil;
    NSScrollView *sv = TextArea(NSMakeRect(16, 56, 588, 340), &tv, NO);
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.string = N2FromUTF8(xs::orNormalizeEol(answer, SC_EOL_LF)) ?: @"";
    tv.selectable = YES;
    [v addSubview:sv];
    NSButton *copy = [NSButton buttonWithTitle:@"全部拷貝" target:nil action:nil];
    copy.frame = NSMakeRect(16, 12, 110, 32);
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:nil action:nil];
    cancel.frame = NSMakeRect(372, 12, 100, 32);
    cancel.keyEquivalent = @"\033";
    cancel.autoresizingMask = NSViewMinXMargin;
    NSButton *ok = [NSButton buttonWithTitle:action target:nil action:nil];
    ok.frame = NSMakeRect(476, 12, 128, 32);
    ok.keyEquivalent = @"\r";
    ok.autoresizingMask = NSViewMinXMargin;
    for (NSView *x in @[copy, cancel, ok]) [v addSubview:x];
    NSString *text = tv.string;
    [N2BlockTarget attach:copy block:^(id sender) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    }];
    [N2BlockTarget attach:cancel block:^(NSButton *sender) { [sender.window.sheetParent endSheet:sender.window]; }];
    void (^applyCopy)(void) = [apply copy];
    [N2BlockTarget attach:ok block:^(NSButton *sender) {
        [sender.window.sheetParent endSheet:sender.window];
        dispatch_async(dispatch_get_main_queue(), applyCopy);
    }];
    [parent beginSheet:p completionHandler:nil];
}

#pragma mark - 套用結果

struct AiSnapshot {
    std::string bytes;     // 整份文件（UTF-8）
    std::string text;      // 要處理的文字
    long start = 0, end = 0;
    long selStart = 0, selEnd = 0, caret = 0;
    int eol = SC_EOL_LF;
};

// 送出範圍（R134）：整份文件、選取文字、只送出指令（結果插入在原游標位置）
enum { N2AiScopeDocument = 0, N2AiScopeSelection = 1, N2AiScopeInstruction = 2 };

// 依範圍設定要處理的文字與寫回位置；不合限制時回傳錯誤說明
static NSString *ApplyScope(AiSnapshot &s, int scope) {
    if (scope == N2AiScopeInstruction) { s.start = s.end = s.caret; s.text.clear(); return nil; }
    if (scope == N2AiScopeSelection) { s.start = s.selStart; s.end = s.selEnd; }
    else { s.start = 0; s.end = (long)s.bytes.size(); }
    s.text = s.bytes.substr((size_t)s.start, (size_t)(s.end - s.start));
    if (s.text.size() > xs::orInputLimit) return @"待處理文字超過 128 KiB，請縮小選取範圍。";
    if (s.text.find('\0') != std::string::npos) return @"待處理文字包含 NUL 或超過 128 KiB。";
    return nil;
}

static void OpenAnswerFile(const std::string &answer, NSWindow *parent) {
    NSString *path = [N2LogsDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_ai_log.txt", NSUUID.UUID.UUIDString]];
    NSMutableData *d = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [d appendBytes:answer.data() length:answer.size()];
    if (![d writeToFile:path options:NSDataWritingWithoutOverwriting error:nil]) {
        Alert(parent, @"無法建立 AI 結果檔，請檢查權限與磁碟空間。", nil);
        return;
    }
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:path] display:YES
                                                               completionHandler:^(NSDocument *doc, BOOL a, NSError *e) {}];
}

static void ApplyAnswer(EditorWindowController *ed, const AiSnapshot &s, xs::AiOutputMode mode, const std::string &answer) {
    NSWindow *w = ed.window;
    if (mode == xs::AiOutputMode::newWindow) { OpenAnswerFile(answer, w); return; }
    if (mode == xs::AiOutputMode::displayOnly) { ShowResult(w, answer, nil); return; }
    // 等待期間文件被修改、或變成唯讀：不覆蓋原文，改為顯示結果
    NSData *now = ed.textAsUTF8;
    BOOL same = now.length == s.bytes.size() && memcmp(now.bytes, s.bytes.data(), s.bytes.size()) == 0;
    if (!same || [ed send:SCI_GETREADONLY] || ed.doc.isCryptoLocked || [ed send:SCI_GETEOLMODE] != s.eol) {
        ShowResult(w, answer, @"等待期間文件已變更或已無法編輯，原文未被覆蓋。結果如下，可拷貝使用：");
        return;
    }
    std::string bytes = xs::orNormalizeEol(answer, s.eol);
    long start = s.start, end = s.end;
    if (mode == xs::AiOutputMode::insertBelow) {
        if (end > 0 && (size_t)end < s.bytes.size() && s.bytes[end - 1] == '\r' && s.bytes[end] == '\n') ++end;
        start = end;
        std::string eol = s.eol == SC_EOL_CRLF ? "\r\n" : s.eol == SC_EOL_CR ? "\r" : "\n";
        size_t pos = (size_t)end;
        if (pos && s.bytes[pos - 1] != '\r' && s.bytes[pos - 1] != '\n') bytes.insert(0, eol);
        if (pos < s.bytes.size() && s.bytes[pos] != '\r' && s.bytes[pos] != '\n' && !bytes.empty() &&
            bytes.back() != '\r' && bytes.back() != '\n')
            bytes += eol;
    }
    [ed send:SCI_BEGINUNDOACTION];
    [ed send:SCI_SETTARGETSTART w:(uptr_t)start];
    [ed send:SCI_SETTARGETEND w:(uptr_t)end];
    [ed send:SCI_REPLACETARGET w:bytes.size() l:(sptr_t)bytes.data()];
    [ed send:SCI_ENDUNDOACTION];
    [ed send:SCI_SETSEL w:(uptr_t)start l:(sptr_t)(start + (long)bytes.size())];
    [ed send:SCI_SCROLLCARET];
}

#pragma mark - 指令視窗

@interface N2AiPromptWindow : NSWindowController <NSTextViewDelegate>
@end

@implementation N2AiPromptWindow {
    __weak EditorWindowController *_editor;
    AiSnapshot _snap;
    NSTextView *_prompt, *_preview;
    NSPopUpButton *_history, *_templates, *_output, *_scope;
    NSButton *_run;
    NSTextField *_service;
    xs::AiOutputMode _mode;
    NSInteger _templateIndex;   // -1 = 自訂
    NSString *_scopeError;
}

static NSMutableSet *gPromptWindows;

- (instancetype)initWithEditor:(EditorWindowController *)ed snapshot:(const AiSnapshot &)snap {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 540)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:YES];
    w.minSize = NSMakeSize(560, 420);
    if ((self = [super initWithWindow:w])) {
        _editor = ed;
        _snap = snap;
        _mode = xs::AiOutputMode::replace;
        _templateIndex = -1;
        [self build];
        [self loadInitialPrompt];
    }
    return self;
}

- (NSPopUpButton *)pulldown:(NSString *)title frame:(NSRect)r {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:r pullsDown:YES];
    [p addItemWithTitle:title];
    p.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    return p;
}

- (void)build {
    NSView *v = self.window.contentView;
    NSTextField *t = [NSTextField labelWithString:@"AI 指令（Prompt）：　⌘↩ 執行"];
    t.frame = NSMakeRect(16, 512, 400, 18);
    t.autoresizingMask = NSViewMinYMargin;
    [v addSubview:t];
    NSTextView *promptView = nil;
    NSScrollView *ps = TextArea(NSMakeRect(16, 380, 520, 126), &promptView, YES);
    _prompt = promptView;
    ps.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _prompt.delegate = self;
    [v addSubview:ps];
    _run = [NSButton buttonWithTitle:@"執行" target:self action:@selector(run:)];
    _run.frame = NSMakeRect(546, 474, 140, 32);
    _run.keyEquivalent = @"\r";
    _run.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    _run.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [v addSubview:_run];
    _history = [self pulldown:@"歷史紀錄" frame:NSMakeRect(546, 442, 140, 26)];
    _templates = [self pulldown:@"指令範本" frame:NSMakeRect(546, 412, 140, 26)];
    _output = [self pulldown:@"結果處理設定" frame:NSMakeRect(546, 382, 140, 26)];
    for (NSPopUpButton *p in @[_history, _templates, _output]) [v addSubview:p];

    NSTextField *pv = [NSTextField labelWithString:@"實際送出的內容（預覽）："];
    pv.frame = NSMakeRect(16, 354, 300, 18);
    pv.autoresizingMask = NSViewMinYMargin;
    [v addSubview:pv];
    // 送出範圍：有選取時預設「選取文字」，沒有選取時預設「整份文件」
    NSTextField *sl = [NSTextField labelWithString:@"送出："];
    sl.frame = NSMakeRect(420, 354, 50, 18);
    sl.alignment = NSTextAlignmentRight;
    sl.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [v addSubview:sl];
    _scope = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(472, 348, 216, 26) pullsDown:NO];
    _scope.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    BOOL hasSelection = _snap.selEnd > _snap.selStart;
    [_scope addItemWithTitle:@"整份文件"]; _scope.lastItem.tag = N2AiScopeDocument;
    if (hasSelection) { [_scope addItemWithTitle:@"選取文字"]; _scope.lastItem.tag = N2AiScopeSelection; }
    [_scope addItemWithTitle:@"只送出指令"]; _scope.lastItem.tag = N2AiScopeInstruction;
    [_scope selectItemWithTag:hasSelection ? N2AiScopeSelection : N2AiScopeDocument];
    _scope.target = self; _scope.action = @selector(scopeChanged:);
    [v addSubview:_scope];
    NSTextView *previewView = nil;
    NSScrollView *vs = TextArea(NSMakeRect(16, 52, 670, 298), &previewView, NO);
    _preview = previewView;
    vs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _preview.font = [NSFont userFixedPitchFontOfSize:12];
    [v addSubview:vs];

    _service = [NSTextField labelWithString:@""];
    _service.frame = NSMakeRect(16, 20, 460, 18);
    _service.textColor = NSColor.secondaryLabelColor;
    _service.lineBreakMode = NSLineBreakByTruncatingTail;
    _service.autoresizingMask = NSViewWidthSizable;
    [v addSubview:_service];
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(586, 12, 100, 32);
    cancel.keyEquivalent = @"\033";
    cancel.autoresizingMask = NSViewMinXMargin;
    [v addSubview:cancel];
    [self rebuildMenus];
}

- (void)rebuildMenus {
    xs::OrPreferences &p = Prefs();
    // 歷史紀錄
    while (_history.numberOfItems > 1) [_history removeItemAtIndex:1];
    for (size_t i = 0; i < p.prompts.size(); i++) {
        NSString *full = N2FromUTF8(p.prompts[i]);
        NSString *shortText = [[full stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@""];
        if (shortText.length > 60) shortText = [[shortText substringToIndex:60] stringByAppendingString:@"…"];
        NSMenuItem *it = [_history.menu addItemWithTitle:shortText action:@selector(pickHistory:) keyEquivalent:@""];
        it.target = self; it.tag = (NSInteger)i;
    }
    if (p.prompts.empty()) [_history.menu addItemWithTitle:@"（沒有歷史紀錄）" action:nil keyEquivalent:@""];
    else {
        [_history.menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *c = [_history.menu addItemWithTitle:@"清除歷史紀錄" action:@selector(clearHistory:) keyEquivalent:@""];
        c.target = self;
    }
    // 指令範本
    while (_templates.numberOfItems > 1) [_templates removeItemAtIndex:1];
    for (size_t i = 0; i < p.templates.size(); i++) {
        NSMenuItem *it = [_templates.menu addItemWithTitle:N2FromUTF8(p.templates[i].name) action:@selector(pickTemplate:) keyEquivalent:@""];
        it.target = self; it.tag = (NSInteger)i;
        it.state = (NSInteger)i == _templateIndex ? NSControlStateValueOn : NSControlStateValueOff;
    }
    NSMenuItem *custom = [_templates.menu addItemWithTitle:@"自訂指令" action:nil keyEquivalent:@""];
    custom.state = _templateIndex < 0 ? NSControlStateValueOn : NSControlStateValueOff;
    [_templates.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *manage = [_templates.menu addItemWithTitle:@"管理範本…" action:@selector(manageTemplates:) keyEquivalent:@""];
    manage.target = self;
    // 結果處理
    while (_output.numberOfItems > 1) [_output removeItemAtIndex:1];
    for (int i = 0; i < 4; i++) {
        NSMenuItem *it = [_output.menu addItemWithTitle:OutputName(kOutputs[i]) action:@selector(pickOutput:) keyEquivalent:@""];
        it.target = self; it.tag = i;
        it.state = kOutputs[i] == _mode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [_output itemAtIndex:0].title = [NSString stringWithFormat:@"結果：%@", OutputName(_mode)];
    std::string model = xs::aiSelectedModel(p);
    _service.stringValue = [NSString stringWithFormat:@"服務：%@　模型：%@", N2FromUTF8(xs::aiProviderName(p.provider)),
                            model.empty() ? @"（尚未選擇）" : N2FromUTF8(model)];
}

- (void)loadInitialPrompt {
    xs::OrPreferences &p = Prefs();
    if (p.prompts.empty() && !p.templates.empty()) {
        _templateIndex = 0;
        _prompt.string = N2FromUTF8(p.templates[0].instruction);
        _mode = p.templates[0].output;
    } else {
        _prompt.string = N2FromUTF8(xs::orDefaultPrompt(p));
    }
    [self rebuildMenus];
    [self updatePreview];
}

- (void)scopeChanged:(id)sender { [self updatePreview]; }

- (void)textDidChange:(NSNotification *)n {
    if (_templateIndex >= 0) { _templateIndex = -1; [self rebuildMenus]; }
    [self updatePreview];
}

- (void)updatePreview {
    xs::OrPreferences &p = Prefs();
    _scopeError = ApplyScope(_snap, (int)_scope.selectedTag);
    if (_scopeError) {
        _preview.string = _scopeError;
        _preview.textColor = NSColor.systemRedColor;
        _run.enabled = NO;
        return;
    }
    try {
        std::string req = xs::aiRequest(p.provider, N2ToUTF8(_prompt.string), _snap.text, xs::aiSelectedModel(p),
                                        xs::aiIsNewProvider(p.provider));
        auto contents = xs::aiPromptContents(p.provider, req);
        _preview.string = [NSString stringWithFormat:@"【系統指令（system）】\n%@\n\n【使用者內容（user）】\n%@",
                           N2FromUTF8(contents.first), N2FromUTF8(contents.second)];
        _preview.textColor = NSColor.textColor;
        _run.enabled = N2ToUTF8(_prompt.string).find_first_not_of(" \t\r\n") != std::string::npos;
    } catch (const std::exception &e) {
        _preview.string = ErrText(e);
        _preview.textColor = NSColor.systemRedColor;
        _run.enabled = NO;
    }
}

- (void)pickHistory:(NSMenuItem *)it {
    xs::OrPreferences &p = Prefs();
    if ((size_t)it.tag < p.prompts.size()) {
        _prompt.string = N2FromUTF8(p.prompts[(size_t)it.tag]);   // 只帶入指令，不改結果處理方式
        _templateIndex = -1;
        [self rebuildMenus];
        [self updatePreview];
    }
}

- (void)clearHistory:(id)sender {
    Prefs().prompts.clear();
    NSString *err = nil;
    if (!SavePrefs(&err)) Alert(self.window, err, nil);
    [self rebuildMenus];
}

- (void)pickTemplate:(NSMenuItem *)it {
    xs::OrPreferences &p = Prefs();
    if ((size_t)it.tag >= p.templates.size()) return;
    _templateIndex = it.tag;
    _prompt.string = N2FromUTF8(p.templates[(size_t)it.tag].instruction);
    _mode = p.templates[(size_t)it.tag].output;
    [self rebuildMenus];
    [self updatePreview];
}

- (void)pickOutput:(NSMenuItem *)it {
    _mode = kOutputs[it.tag];
    [self rebuildMenus];
}

- (void)manageTemplates:(id)sender {
    [N2AiTemplateWindow showWithCompletion:^{ [self rebuildMenus]; }];
}

- (void)finish {
    [self.window.sheetParent endSheet:self.window];
    [gPromptWindows removeObject:self];
}

- (void)cancel:(id)sender { [self finish]; }

- (void)run:(id)sender {
    [self updatePreview];
    if (!_run.enabled) { NSBeep(); return; }
    EditorWindowController *ed = _editor;
    xs::OrPreferences &p = Prefs();
    std::string instruction = N2ToUTF8(_prompt.string), request;
    BOOL streaming = xs::aiIsNewProvider(p.provider);
    try { request = xs::aiRequest(p.provider, instruction, _snap.text, xs::aiSelectedModel(p), streaming); }
    catch (const std::exception &e) { Alert(self.window, ErrText(e), nil); return; }
    xs::orRemember(p, instruction);
    NSString *err = nil;
    if (!SavePrefs(&err)) NSLog(@"AI 歷史保存失敗：%@", err);
    xs::AiProvider provider = p.provider;
    std::string key = p.activeKey(), model = xs::aiSelectedModel(p), endpoint = Endpoint(p);
    AiSnapshot snap = _snap;
    xs::AiOutputMode mode = _mode;
    [self finish];
    if (!ed) return;
    NSString *title = [NSString stringWithFormat:@"%@ 處理中…", N2FromUTF8(xs::aiProviderName(provider))];
    if (streaming) {
        // 新服務：邊收邊顯示，可按「停止」；完整接收後先預覽，再確認套用
        RunAiStreamJob(ed.window, title, ^std::string(std::shared_ptr<std::atomic<bool>> cancel, std::function<void(const std::string &)> progress) {
            auto reply = AiHttp(provider, key, request, xs::AiOperation::generate, model, {}, cancel, endpoint, progress);
            if (reply.first == 200) return reply.second;
            return xs::aiAnswer(provider, reply.first, reply.second);   // 錯誤狀態：取得服務的錯誤說明
        }, ^(BOOL ok, const std::string &answer, NSString *error) {
            if (!ok) { if (error) Alert(ed.window, @"人工智慧處理失敗。", error); return; }
            if (mode == xs::AiOutputMode::displayOnly) { ShowResult(ed.window, answer, nil); return; }
            std::string result = answer;   // 區塊會在稍後執行：複製一份（不能保留參數的參考）
            ReviewResult(ed.window, result, OutputName(mode), ^{ ApplyAnswer(ed, snap, mode, result); });
        });
        return;
    }
    RunAiJob(ed.window, title, ^std::string(std::shared_ptr<std::atomic<bool>> cancel) {
        auto reply = AiHttp(provider, key, request, xs::AiOperation::generate, model, {}, cancel);
        return xs::aiAnswer(provider, reply.first, reply.second);
    }, ^(BOOL ok, const std::string &answer, NSString *error) {
        if (!ok) { if (error) Alert(ed.window, @"人工智慧處理失敗。", error); return; }
        ApplyAnswer(ed, snap, mode, answer);
    });
}

@end

void N2AiRunForEditor(EditorWindowController *ed) {
    if ([ed send:SCI_SELECTIONISRECTANGLE] || [ed send:SCI_GETSELECTIONS] != 1) {
        Alert(ed.window, @"人工智慧請使用單一、連續的文字選取範圍。", nil);
        return;
    }
    AiSnapshot s;
    NSData *all = ed.textAsUTF8;
    s.bytes.assign((const char *)all.bytes, all.length);
    s.selStart = [ed send:SCI_GETSELECTIONSTART];
    s.selEnd = [ed send:SCI_GETSELECTIONEND];
    s.caret = [ed send:SCI_GETCURRENTPOS];
    s.eol = (int)[ed send:SCI_GETEOLMODE];
    if (!xs::aiConnectionReady(Prefs())) {
        Alert(ed.window, @"請先在「工具 → 人工智慧 → 連接設定」完成所選服務的連接設定。", nil);
        return;
    }
    N2AiPromptWindow *w = [[N2AiPromptWindow alloc] initWithEditor:ed snapshot:s];
    if (!gPromptWindows) gPromptWindows = [NSMutableSet set];
    [gPromptWindows addObject:w];
    [ed.window beginSheet:w.window completionHandler:nil];
    [w.window makeFirstResponder:nil];
}

#pragma mark - 連接設定視窗

@implementation N2AiSettingsWindow {
    xs::OrPreferences _draft;
    NSPopUpButton *_provider, *_model;
    NSSecureTextField *_key;
    NSTextField *_endpoint, *_endpointLabel, *_modelText, *_modelTextLabel, *_modelLabel, *_note;
    NSButton *_refresh, *_test, *_keyPage;
    NSTextField *_status;
    NSProgressIndicator *_spin;
    BOOL _busy, _rendering;
}

+ (void)show {
    static N2AiSettingsWindow *w;
    if (!w) w = [[N2AiSettingsWindow alloc] init];
    [w reload];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 392)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    win.title = @"人工智慧連接設定";
    if ((self = [super initWithWindow:win])) { [self build]; [win center]; }
    return self;
}

static NSTextField *L(NSString *s, NSRect r) { NSTextField *l = [NSTextField labelWithString:s]; l.frame = r; l.alignment = NSTextAlignmentRight; return l; }

- (void)build {
    NSView *v = self.window.contentView;
    [v addSubview:L(@"服務：", NSMakeRect(10, 344, 110, 20))];
    _provider = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(124, 339, 250, 26) pullsDown:NO];
    for (int i = 0; i < kProviderCount; i++) [_provider addItemWithTitle:N2FromUTF8(xs::aiProviderName((xs::AiProvider)i))];
    _provider.target = self; _provider.action = @selector(providerChanged:);
    [v addSubview:_provider];
    _keyPage = [NSButton buttonWithTitle:@"申請 TOKEN KEY" target:self action:@selector(openKeyPage:)];
    _keyPage.frame = NSMakeRect(380, 336, 164, 32);
    [v addSubview:_keyPage];

    // 服務網址（Ollama、Azure OpenAI）
    _endpointLabel = L(@"服務網址：", NSMakeRect(10, 304, 110, 20));
    [v addSubview:_endpointLabel];
    _endpoint = [[NSTextField alloc] initWithFrame:NSMakeRect(126, 300, 414, 24)];
    _endpoint.usesSingleLineMode = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fieldEdited:) name:NSControlTextDidChangeNotification object:_endpoint];
    [v addSubview:_endpoint];

    [v addSubview:L(@"API Key：", NSMakeRect(10, 264, 110, 20))];
    _key = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(126, 260, 414, 24)];
    _key.target = self; _key.action = @selector(keyChanged:);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyEdited:) name:NSControlTextDidChangeNotification object:_key];
    [v addSubview:_key];

    _modelLabel = L(@"模型清單：", NSMakeRect(10, 224, 110, 20));
    [v addSubview:_modelLabel];
    _model = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(124, 219, 280, 26) pullsDown:NO];
    _model.target = self; _model.action = @selector(modelChanged:);
    [v addSubview:_model];
    _refresh = [NSButton buttonWithTitle:@"重新取得模型清單" target:self action:@selector(refreshModels:)];
    _refresh.frame = NSMakeRect(404, 216, 144, 32);
    [v addSubview:_refresh];

    // 新服務：可手動輸入模型 ID（Azure 為部署名稱）
    _modelTextLabel = L(@"模型 ID：", NSMakeRect(10, 184, 110, 20));
    [v addSubview:_modelTextLabel];
    _modelText = [[NSTextField alloc] initWithFrame:NSMakeRect(126, 180, 414, 24)];
    _modelText.usesSingleLineMode = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fieldEdited:) name:NSControlTextDidChangeNotification object:_modelText];
    [v addSubview:_modelText];

    _note = [NSTextField wrappingLabelWithString:@""];
    _note.frame = NSMakeRect(126, 140, 414, 34);
    _note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _note.textColor = NSColor.secondaryLabelColor;
    [v addSubview:_note];

    _test = [NSButton buttonWithTitle:@"測試連線" target:self action:@selector(test:)];
    _test.frame = NSMakeRect(120, 100, 120, 32);
    [v addSubview:_test];
    _spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(248, 108, 16, 16)];
    _spin.style = NSProgressIndicatorStyleSpinning; _spin.displayedWhenStopped = NO;
    [v addSubview:_spin];
    _status = [NSTextField wrappingLabelWithString:@""];
    _status.frame = NSMakeRect(126, 52, 414, 46);
    _status.textColor = NSColor.secondaryLabelColor;
    [v addSubview:_status];

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(close)];
    cancel.frame = NSMakeRect(344, 12, 96, 32);
    cancel.keyEquivalent = @"\033";
    NSButton *ok = [NSButton buttonWithTitle:@"確定" target:self action:@selector(save:)];
    ok.frame = NSMakeRect(444, 12, 96, 32);
    ok.keyEquivalent = @"\r";
    [v addSubview:cancel]; [v addSubview:ok];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)reload {
    _draft = Prefs();
    _status.stringValue = @"";
    [self showDraft];
}

- (void)showDraft {
    _rendering = YES;
    xs::AiProvider pv = _draft.provider;
    BOOL manual = xs::aiIsNewProvider(pv), needsKey = xs::aiRequiresKey(pv), usesEndpoint = xs::aiUsesEndpoint(pv);
    BOOL azure = pv == xs::AiProvider::azure, ollama = pv == xs::AiProvider::ollama;
    [_provider selectItemAtIndex:(NSInteger)pv];
    _key.stringValue = N2FromUTF8(_draft.activeKey());
    _key.enabled = needsKey && !_busy;
    _key.placeholderString = needsKey ? @"" : @"本機 Ollama 不需要 API Key";
    _endpoint.hidden = _endpointLabel.hidden = !usesEndpoint;
    _endpointLabel.stringValue = azure ? @"Azure Endpoint：" : @"Ollama 服務網址：";
    _endpoint.placeholderString = azure ? @"https://<資源>.openai.azure.com" : @"http://127.0.0.1:11434";
    if (usesEndpoint && ![_endpoint.stringValue isEqualToString:N2FromUTF8(Endpoint(_draft))])
        _endpoint.stringValue = N2FromUTF8(Endpoint(_draft));
    _modelText.hidden = _modelTextLabel.hidden = !manual;
    _modelTextLabel.stringValue = azure ? @"部署名稱：" : @"模型 ID：";
    if (manual && ![_modelText.stringValue isEqualToString:N2FromUTF8(_draft.activeModel())])
        _modelText.stringValue = N2FromUTF8(_draft.activeModel());
    _model.hidden = _modelLabel.hidden = _refresh.hidden = azure;
    _keyPage.title = azure ? @"開啟 Azure" : ollama ? @"下載 Ollama" : @"申請 TOKEN KEY";
    _note.stringValue = azure ? @"輸入 Azure 資源網址及部署名稱。請選用支援 v1 Chat Completions 文字輸出的部署。"
                      : ollama ? @"網址留空使用 http://127.0.0.1:11434。請先啟動 Ollama 並安裝模型；只連到本機。"
                      : manual ? @"可手動輸入模型 ID，或從清單選擇。測試連線會請模型生成一小段文字，可能使用 API 額度。"
                      : @"";
    [_model removeAllItems];
    BOOL fixed = pv == xs::AiProvider::openRouter;
    if (fixed) {
        [_model addItemWithTitle:@"openrouter/free（固定）"];
    } else {
        [_model addItemWithTitle:manual ? @"（從清單選擇）" : @"（請選擇模型）"];
        for (auto &m : _draft.activeModels()) {
            NSString *title = m.label.empty() || m.label == m.id ? N2FromUTF8(m.id) : [NSString stringWithFormat:@"%@（%@）", N2FromUTF8(m.label), N2FromUTF8(m.id)];
            [_model addItemWithTitle:title];
            _model.lastItem.representedObject = N2FromUTF8(m.id);
        }
        NSString *cur = N2FromUTF8(_draft.activeModel());
        for (NSMenuItem *it in _model.itemArray) if ([it.representedObject isEqual:cur]) [_model selectItem:it];
    }
    _model.enabled = !fixed && !_busy;
    _refresh.enabled = xs::aiListsModels(pv) && !_busy;
    _test.enabled = !_busy;
    _provider.enabled = !_busy;
    _endpoint.enabled = _modelText.enabled = !_busy;
    _rendering = NO;
}

- (void)providerChanged:(id)sender {
    [self syncFields];
    _draft.provider = (xs::AiProvider)_provider.indexOfSelectedItem;
    _status.stringValue = @"";
    _endpoint.stringValue = @"";
    _modelText.stringValue = @"";
    [self showDraft];
}

// 新服務：把網址與手動模型 ID 寫回草稿；網址改變時清除模型清單
- (void)syncFields {
    if (_rendering || !xs::aiIsNewProvider(_draft.provider)) return;
    if (xs::aiUsesEndpoint(_draft.provider)) {
        std::string ep = N2ToUTF8(_endpoint.stringValue);
        if (ep != Endpoint(_draft)) { _draft.activeEndpoint() = ep; _draft.activeModels().clear(); }
    }
    _draft.activeModel() = N2ToUTF8(_modelText.stringValue);
}

- (void)fieldEdited:(NSNotification *)n { [self syncFields]; }

// 修改金鑰會清除該服務的模型清單與選擇（不影響其他服務；新服務保留手動輸入的模型 ID）
- (void)keyEdited:(NSNotification *)n { [self keyChanged:nil]; }
- (void)keyChanged:(id)sender {
    [self syncFields];
    if (!xs::aiRequiresKey(_draft.provider)) return;
    std::string k = N2ToUTF8(_key.stringValue);
    if (k == _draft.activeKey()) return;
    _draft.activeKey() = k;
    if (_draft.provider != xs::AiProvider::openRouter) {
        _draft.activeModels().clear();
        if (!xs::aiIsNewProvider(_draft.provider)) _draft.activeModel().clear();
        [self showDraft];
    }
}

- (void)modelChanged:(id)sender {
    NSString *m = _model.selectedItem.representedObject;
    if (xs::aiIsNewProvider(_draft.provider)) {
        if (m) { _modelText.stringValue = m; [self syncFields]; }
        return;
    }
    _draft.activeModel() = N2ToUTF8(m ?: @"");
}

- (void)openKeyPage:(id)sender {
    NSURL *u = [NSURL URLWithString:N2FromUTF8(xs::aiKeyPage(_draft.provider))];
    if (u) [NSWorkspace.sharedWorkspace openURL:u];
}

- (void)setBusy:(BOOL)busy status:(NSString *)status {
    _busy = busy;
    if (busy) [_spin startAnimation:nil]; else [_spin stopAnimation:nil];
    _status.stringValue = status ?: @"";
    _status.textColor = NSColor.secondaryLabelColor;
    [self showDraft];
}

- (BOOL)checkEndpoint {
    if (xs::aiValidEndpoint(_draft.provider, Endpoint(_draft))) return YES;
    _status.stringValue = @"請輸入有效的 AI 服務網址。";
    _status.textColor = NSColor.systemRedColor;
    return NO;
}

- (void)refreshModels:(id)sender {
    [self keyChanged:nil];
    if (![self checkEndpoint]) return;
    xs::AiProvider provider = _draft.provider;
    std::string key = _draft.activeKey(), endpoint = Endpoint(_draft);
    [self setBusy:YES status:@"正在取得模型清單…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<xs::AiModel> models;
        NSString *err = nil;
        try {
            models = xs::aiModels(provider, [&](const std::string &page) {
                return AiHttp(provider, key, {}, xs::AiOperation::listModels, {}, page, nullptr, endpoint);
            });
        } catch (const std::exception &e) { err = ErrText(e); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_draft.provider == provider && self->_draft.activeKey() == key && !err) {
                std::string keep = self->_draft.activeModel();
                self->_draft.activeModels() = models;
                bool exists = false;
                for (auto &m : models) if (m.id == keep) exists = true;
                // 已不存在的選擇清空（新服務保留手動輸入的模型 ID）；首次不自動選第一筆
                if (!exists && !xs::aiIsNewProvider(provider)) self->_draft.activeModel().clear();
            }
            [self setBusy:NO status:err ?: [NSString stringWithFormat:@"模型清單已更新（%lu 筆），請選擇模型後測試連線或按確定。", (unsigned long)models.size()]];
            if (err) self->_status.textColor = NSColor.systemRedColor;
        });
    });
}

- (void)test:(id)sender {
    [self keyChanged:nil];
    if (![self checkEndpoint]) return;
    xs::AiProvider provider = _draft.provider;
    std::string key = _draft.activeKey(), model = xs::aiSelectedModel(_draft), endpoint = Endpoint(_draft);
    if (provider != xs::AiProvider::openRouter && !xs::validAiModel(provider, model)) {
        _status.stringValue = xs::aiIsNewProvider(provider) ? @"請選擇或輸入要測試的模型。" : @"請先取得所選服務的模型清單，並選擇要測試的模型。";
        _status.textColor = NSColor.systemRedColor;
        return;
    }
    [self setBusy:YES status:provider == xs::AiProvider::openRouter ? @"正在驗證金鑰…" : @"正在以所選模型送出簡短測試（可能使用額度）…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        try {
            if (provider == xs::AiProvider::openRouter) {
                auto r = AiHttp(provider, key, {}, xs::AiOperation::checkKey, {}, {}, nullptr);
                xs::orCheckKey(r.first, r.second);
            } else {
                std::string req = xs::aiRequest(provider, u8"請只回覆 OK", u8"連線測試", model);
                auto r = AiHttp(provider, key, req, xs::AiOperation::generate, model, {}, nullptr, endpoint);
                xs::aiAnswer(provider, r.first, r.second);
            }
        } catch (const std::exception &e) { err = ErrText(e); }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusy:NO status:err ?: @"所選服務／模型連線測試成功。"];
            self->_status.textColor = err ? NSColor.systemRedColor : NSColor.systemGreenColor;
        });
    });
}

- (void)save:(id)sender {
    [self keyChanged:nil];
    if (xs::aiRequiresKey(_draft.provider) && !_draft.activeKey().empty() && !xs::validOrKey(_draft.activeKey())) {
        _status.stringValue = @"請輸入有效的 API Key（不可包含空白或換行）。";
        _status.textColor = NSColor.systemRedColor;
        return;
    }
    if (![self checkEndpoint]) return;
    // 其他服務留下的網址也要正確（儲存時會檢查全部服務），錯誤時指出是哪一家
    for (xs::AiProvider pv : {xs::AiProvider::ollama, xs::AiProvider::azure}) {
        xs::OrPreferences probe = _draft;
        probe.provider = pv;
        std::string ep = Endpoint(probe);
        if (!ep.empty() && !xs::aiValidEndpoint(pv, ep)) {
            _status.stringValue = [NSString stringWithFormat:@"「%@」的服務網址格式不正確，請修正或清空。", N2FromUTF8(xs::aiProviderName(pv))];
            _status.textColor = NSColor.systemRedColor;
            return;
        }
    }
    if (xs::aiIsNewProvider(_draft.provider) && !_draft.activeModel().empty() && !xs::validAiModel(_draft.provider, _draft.activeModel())) {
        _status.stringValue = @"模型 ID 格式不正確。";
        _status.textColor = NSColor.systemRedColor;
        return;
    }
    xs::aiCopySettings(Prefs(), _draft);   // 只更新連接欄位，保留範本與歷史
    NSString *err = nil;
    if (!SavePrefs(&err)) { _status.stringValue = err; _status.textColor = NSColor.systemRedColor; return; }
    [self close];
}

@end

#pragma mark - 範本管理

@interface N2AiTemplateWindow () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation N2AiTemplateWindow {
    std::vector<xs::AiTemplate> _draft;
    NSTableView *_table;
    void (^_completion)(void);
}

+ (void)showWithCompletion:(void (^)(void))completion {
    static N2AiTemplateWindow *w;
    if (!w) w = [[N2AiTemplateWindow alloc] init];
    w->_completion = [completion copy];
    w->_draft = Prefs().templates;
    [w->_table reloadData];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 380)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    win.title = @"人工智慧指令範本";
    if ((self = [super initWithWindow:win])) { [self build]; [win center]; }
    return self;
}

- (void)build {
    NSView *v = self.window.contentView;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 60, 400, 304)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    _table = [[NSTableView alloc] initWithFrame:sv.bounds];
    NSTableColumn *n = [[NSTableColumn alloc] initWithIdentifier:@"name"]; n.title = @"名稱"; n.width = 240;
    NSTableColumn *o = [[NSTableColumn alloc] initWithIdentifier:@"output"]; o.title = @"預設結果處理"; o.width = 130;
    [_table addTableColumn:n]; [_table addTableColumn:o];
    _table.dataSource = self; _table.delegate = self;
    _table.target = self; _table.doubleAction = @selector(edit:);
    sv.documentView = _table;
    [v addSubview:sv];
    NSArray *buttons = @[@[@"新增…", @"add:"], @[@"編輯…", @"edit:"], @[@"刪除", @"remove:"], @[@"上移", @"up:"], @[@"下移", @"down:"]];
    CGFloat y = 332;
    for (NSArray *b in buttons) {
        NSButton *btn = [NSButton buttonWithTitle:b[0] target:self action:NSSelectorFromString(b[1])];
        btn.frame = NSMakeRect(424, y, 120, 32);
        [v addSubview:btn];
        y -= 38;
    }
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(close)];
    cancel.frame = NSMakeRect(344, 12, 96, 32);
    cancel.keyEquivalent = @"\033";
    NSButton *save = [NSButton buttonWithTitle:@"儲存" target:self action:@selector(save:)];
    save.frame = NSMakeRect(444, 12, 96, 32);
    [v addSubview:cancel]; [v addSubview:save];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_draft.size(); }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    const auto &t = _draft[(size_t)r];
    return [c.identifier isEqualToString:@"name"] ? N2FromUTF8(t.name) : OutputName(t.output);
}

- (void)editTemplate:(NSInteger)index {
    xs::AiTemplate t = index >= 0 ? _draft[(size_t)index] : xs::AiTemplate{};
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 250)];
    NSTextField *nl = [NSTextField labelWithString:@"名稱："]; nl.frame = NSMakeRect(0, 226, 80, 18);
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 200, 440, 24)];
    name.stringValue = N2FromUTF8(t.name);
    NSTextField *il = [NSTextField labelWithString:@"指令："]; il.frame = NSMakeRect(0, 176, 80, 18);
    NSTextView *ins = nil;
    NSScrollView *is = TextArea(NSMakeRect(0, 40, 440, 134), &ins, YES);
    ins.string = N2FromUTF8(t.instruction);
    NSTextField *ol = [NSTextField labelWithString:@"預設結果處理："]; ol.frame = NSMakeRect(0, 10, 110, 18);
    NSPopUpButton *out = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 4, 200, 26) pullsDown:NO];
    for (int i = 0; i < 4; i++) { [out addItemWithTitle:OutputName(kOutputs[i])]; if (kOutputs[i] == t.output) [out selectItemAtIndex:i]; }
    for (NSView *x in @[nl, name, il, is, ol, out]) [box addSubview:x];
    NSAlert *a = [NSAlert new];
    a.messageText = index >= 0 ? @"編輯範本" : @"新增範本";
    a.accessoryView = box;
    [a addButtonWithTitle:@"確定"];
    [a addButtonWithTitle:@"取消"];
    a.window.initialFirstResponder = name;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        xs::AiTemplate nt{N2ToUTF8(name.stringValue), N2ToUTF8(ins.string), kOutputs[out.indexOfSelectedItem]};
        std::vector<xs::AiTemplate> test = self->_draft;
        if (index >= 0) test[(size_t)index] = nt; else test.push_back(nt);
        try { xs::aiValidateTemplates(test); }
        catch (const std::exception &e) { Alert(self.window, ErrText(e), nil); return; }
        self->_draft = test;
        [self->_table reloadData];
    }];
}

- (void)add:(id)sender { [self editTemplate:-1]; }
- (void)edit:(id)sender { if (_table.selectedRow >= 0) [self editTemplate:_table.selectedRow]; }
- (void)remove:(id)sender {
    NSInteger r = _table.selectedRow;
    if (r < 0) return;
    _draft.erase(_draft.begin() + r);
    [_table reloadData];
}
- (void)move:(NSInteger)delta {
    NSInteger r = _table.selectedRow, to = r + delta;
    if (r < 0 || to < 0 || to >= (NSInteger)_draft.size()) return;
    std::swap(_draft[(size_t)r], _draft[(size_t)to]);
    [_table reloadData];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)to] byExtendingSelection:NO];
}
- (void)up:(id)sender { [self move:-1]; }
- (void)down:(id)sender { [self move:1]; }

- (void)save:(id)sender {
    try { xs::aiValidateTemplates(_draft); }
    catch (const std::exception &e) { Alert(self.window, ErrText(e), nil); return; }
    Prefs().templates = _draft;   // 空清單也照樣保存，不補回預設
    NSString *err = nil;
    if (!SavePrefs(&err)) { Alert(self.window, err, nil); return; }
    [self close];
    if (_completion) _completion();
}

@end
