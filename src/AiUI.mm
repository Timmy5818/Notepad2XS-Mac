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

#pragma mark - HTTP

struct AiCancelled {};

@interface N2NoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation N2NoRedirect
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r
        newRequest:(NSURLRequest *)req completionHandler:(void (^)(NSURLRequest *))h { h(nil); }   // 不跟隨重新導向
@end

// 與 Windows 版 aiHttp 相同：固定主機與路徑、HTTPS、120 秒、不跟隨轉址、不用 Cookie、回應上限 2 MiB
static std::pair<unsigned, std::string> AiHttp(xs::AiProvider provider, const std::string &key, const std::string &body,
                                               xs::AiOperation op, const std::string &model, const std::string &page,
                                               std::shared_ptr<std::atomic<bool>> cancel) {
    if (!xs::validOrKey(key)) throw std::runtime_error(u8"請先在「人工智慧連接設定」輸入有效的 API Key。");
    xs::AiEndpoint ep = xs::aiEndpoint(provider, op, model, page);
    NSURL *url = [NSURL URLWithString:N2FromUTF8("https://" + ep.host + ep.path)];
    if (!url) throw std::runtime_error(u8"服務位址不正確。");
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:120];
    req.HTTPMethod = N2FromUTF8(ep.method);
    req.HTTPShouldHandleCookies = NO;
    if (!body.empty()) req.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    if (provider == xs::AiProvider::google) [req setValue:N2FromUTF8(key) forHTTPHeaderField:@"x-goog-api-key"];
    else [req setValue:[@"Bearer " stringByAppendingString:N2FromUTF8(key)] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (provider == xs::AiProvider::openRouter) {
        [req setValue:@"https://dz.jplopsoft.idv.tw/" forHTTPHeaderField:@"HTTP-Referer"];
        [req setValue:@"notepad2xs" forHTTPHeaderField:@"X-Title"];
    }
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 120;
    cfg.timeoutIntervalForResource = 120;
    cfg.HTTPCookieStorage = nil;
    cfg.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:[N2NoRedirect new] delegateQueue:nil];
    __block NSData *data = nil;
    __block NSHTTPURLResponse *resp = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = (NSHTTPURLResponse *)r; err = e;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (cancel && *cancel) [task cancel];
    }
    [session finishTasksAndInvalidate];
    if (cancel && *cancel) throw AiCancelled{};
    if (err) {
        if (err.code == NSURLErrorTimedOut) throw std::runtime_error(u8"人工智慧請求超過 120 秒，原文未變更。");
        throw std::runtime_error(std::string(u8"無法連線到 ") + xs::aiProviderName(provider) + u8"：" + N2ToUTF8(err.localizedDescription));
    }
    if (data.length > xs::orResponseLimit) throw std::runtime_error(u8"人工智慧回應超過 2 MiB，原文未變更。");
    return {(unsigned)resp.statusCode, std::string((const char *)data.bytes, data.length)};
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
static const xs::AiProvider kProviders[] = {xs::AiProvider::openRouter, xs::AiProvider::google,
                                            xs::AiProvider::nvidia, xs::AiProvider::deepseek};

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

#pragma mark - 套用結果

struct AiSnapshot {
    std::string bytes;     // 整份文件（UTF-8）
    std::string text;      // 要處理的文字
    long start = 0, end = 0;
    int eol = SC_EOL_LF;
};

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
    NSPopUpButton *_history, *_templates, *_output;
    NSButton *_run;
    NSTextField *_service;
    xs::AiOutputMode _mode;
    NSInteger _templateIndex;   // -1 = 自訂
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
    pv.frame = NSMakeRect(16, 354, 400, 18);
    pv.autoresizingMask = NSViewMinYMargin;
    [v addSubview:pv];
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

- (void)textDidChange:(NSNotification *)n {
    if (_templateIndex >= 0) { _templateIndex = -1; [self rebuildMenus]; }
    [self updatePreview];
}

- (void)updatePreview {
    xs::OrPreferences &p = Prefs();
    try {
        std::string req = xs::aiRequest(p.provider, N2ToUTF8(_prompt.string), _snap.text, xs::aiSelectedModel(p));
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
    try { request = xs::aiRequest(p.provider, instruction, _snap.text, xs::aiSelectedModel(p)); }
    catch (const std::exception &e) { Alert(self.window, ErrText(e), nil); return; }
    xs::orRemember(p, instruction);
    NSString *err = nil;
    if (!SavePrefs(&err)) NSLog(@"AI 歷史保存失敗：%@", err);
    xs::AiProvider provider = p.provider;
    std::string key = p.activeKey(), model = xs::aiSelectedModel(p);
    AiSnapshot snap = _snap;
    xs::AiOutputMode mode = _mode;
    [self finish];
    if (!ed) return;
    NSString *title = [NSString stringWithFormat:@"%@ 處理中…", N2FromUTF8(xs::aiProviderName(provider))];
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
    s.start = [ed send:SCI_GETSELECTIONSTART];
    s.end = [ed send:SCI_GETSELECTIONEND];
    if (s.start == s.end) { s.start = 0; s.end = (long)s.bytes.size(); }
    s.text = s.bytes.substr((size_t)s.start, (size_t)(s.end - s.start));
    s.eol = (int)[ed send:SCI_GETEOLMODE];
    if (s.text.size() > xs::orInputLimit || s.text.find('\0') != std::string::npos) {
        Alert(ed.window, @"待處理文字包含 NUL 或超過 128 KiB，請縮小選取範圍。", nil);
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
    NSButton *_refresh, *_test, *_keyPage;
    NSTextField *_status;
    NSProgressIndicator *_spin;
    BOOL _busy;
}

+ (void)show {
    static N2AiSettingsWindow *w;
    if (!w) w = [[N2AiSettingsWindow alloc] init];
    [w reload];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 300)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    win.title = @"人工智慧連接設定";
    if ((self = [super initWithWindow:win])) { [self build]; [win center]; }
    return self;
}

static NSTextField *L(NSString *s, NSRect r) { NSTextField *l = [NSTextField labelWithString:s]; l.frame = r; l.alignment = NSTextAlignmentRight; return l; }

- (void)build {
    NSView *v = self.window.contentView;
    [v addSubview:L(@"服務：", NSMakeRect(10, 252, 90, 20))];
    _provider = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, 247, 260, 26) pullsDown:NO];
    for (auto pv : kProviders) [_provider addItemWithTitle:N2FromUTF8(xs::aiProviderName(pv))];
    _provider.target = self; _provider.action = @selector(providerChanged:);
    [v addSubview:_provider];
    _keyPage = [NSButton buttonWithTitle:@"申請 TOKEN KEY" target:self action:@selector(openKeyPage:)];
    _keyPage.frame = NSMakeRect(370, 244, 170, 32);
    [v addSubview:_keyPage];

    [v addSubview:L(@"API Key：", NSMakeRect(10, 212, 90, 20))];
    _key = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(106, 208, 434, 24)];
    _key.target = self; _key.action = @selector(keyChanged:);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyEdited:) name:NSControlTextDidChangeNotification object:_key];
    [v addSubview:_key];

    [v addSubview:L(@"模型：", NSMakeRect(10, 172, 90, 20))];
    _model = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, 167, 300, 26) pullsDown:NO];
    _model.target = self; _model.action = @selector(modelChanged:);
    [v addSubview:_model];
    _refresh = [NSButton buttonWithTitle:@"重新取得模型清單" target:self action:@selector(refreshModels:)];
    _refresh.frame = NSMakeRect(404, 164, 140, 32);
    [v addSubview:_refresh];

    _test = [NSButton buttonWithTitle:@"測試連線" target:self action:@selector(test:)];
    _test.frame = NSMakeRect(100, 124, 120, 32);
    [v addSubview:_test];
    _spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(228, 132, 16, 16)];
    _spin.style = NSProgressIndicatorStyleSpinning; _spin.displayedWhenStopped = NO;
    [v addSubview:_spin];
    _status = [NSTextField wrappingLabelWithString:@""];
    _status.frame = NSMakeRect(106, 64, 434, 56);
    _status.textColor = NSColor.secondaryLabelColor;
    [v addSubview:_status];

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(close)];
    cancel.frame = NSMakeRect(344, 14, 96, 32);
    cancel.keyEquivalent = @"\033";
    NSButton *ok = [NSButton buttonWithTitle:@"確定" target:self action:@selector(save:)];
    ok.frame = NSMakeRect(444, 14, 96, 32);
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
    for (int i = 0; i < 4; i++) if (kProviders[i] == _draft.provider) [_provider selectItemAtIndex:i];
    _key.stringValue = N2FromUTF8(_draft.activeKey());
    [_model removeAllItems];
    BOOL fixed = _draft.provider == xs::AiProvider::openRouter;
    if (fixed) {
        [_model addItemWithTitle:@"openrouter/free（固定）"];
    } else {
        [_model addItemWithTitle:@"（請選擇模型）"];
        for (auto &m : _draft.activeModels()) {
            NSString *title = m.label.empty() || m.label == m.id ? N2FromUTF8(m.id) : [NSString stringWithFormat:@"%@（%@）", N2FromUTF8(m.label), N2FromUTF8(m.id)];
            [_model addItemWithTitle:title];
            _model.lastItem.representedObject = N2FromUTF8(m.id);
        }
        NSString *cur = N2FromUTF8(_draft.activeModel());
        for (NSMenuItem *it in _model.itemArray) if ([it.representedObject isEqual:cur]) [_model selectItem:it];
    }
    _model.enabled = !fixed && !_busy;
    _refresh.enabled = !fixed && !_busy;
    _test.enabled = !_busy;
    _provider.enabled = !_busy;
}

- (void)providerChanged:(id)sender {
    _draft.provider = kProviders[_provider.indexOfSelectedItem];
    _status.stringValue = @"";
    [self showDraft];
}

// 修改金鑰會清除該服務的模型清單與選擇（不影響其他服務）
- (void)keyEdited:(NSNotification *)n { [self keyChanged:nil]; }
- (void)keyChanged:(id)sender {
    std::string k = N2ToUTF8(_key.stringValue);
    if (k == _draft.activeKey()) return;
    _draft.activeKey() = k;
    if (_draft.provider != xs::AiProvider::openRouter) {
        _draft.activeModels().clear();
        _draft.activeModel().clear();
        [self showDraft];
    }
}

- (void)modelChanged:(id)sender {
    NSString *m = _model.selectedItem.representedObject;
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

- (void)refreshModels:(id)sender {
    [self keyChanged:nil];
    xs::AiProvider provider = _draft.provider;
    std::string key = _draft.activeKey();
    [self setBusy:YES status:@"正在取得模型清單…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<xs::AiModel> models;
        NSString *err = nil;
        try {
            models = xs::aiModels(provider, [&](const std::string &page) {
                return AiHttp(provider, key, {}, xs::AiOperation::listModels, {}, page, nullptr);
            });
        } catch (const std::exception &e) { err = ErrText(e); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_draft.provider == provider && self->_draft.activeKey() == key && !err) {
                std::string keep = self->_draft.activeModel();
                self->_draft.activeModels() = models;
                bool exists = false;
                for (auto &m : models) if (m.id == keep) exists = true;
                if (!exists) self->_draft.activeModel().clear();   // 已不存在的選擇清空；首次不自動選第一筆
            }
            [self setBusy:NO status:err ?: [NSString stringWithFormat:@"模型清單已更新（%lu 筆），請選擇模型後測試連線或按確定。", (unsigned long)models.size()]];
            if (err) self->_status.textColor = NSColor.systemRedColor;
        });
    });
}

- (void)test:(id)sender {
    [self keyChanged:nil];
    xs::AiProvider provider = _draft.provider;
    std::string key = _draft.activeKey(), model = xs::aiSelectedModel(_draft);
    if (provider != xs::AiProvider::openRouter && !xs::validAiModel(provider, model)) {
        _status.stringValue = @"請先取得所選服務的模型清單，並選擇要測試的模型。";
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
                auto r = AiHttp(provider, key, req, xs::AiOperation::generate, model, {}, nullptr);
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
    if (!_draft.activeKey().empty() && !xs::validOrKey(_draft.activeKey())) {
        _status.stringValue = @"請輸入有效的 API Key（不可包含空白或換行）。";
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
