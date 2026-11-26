// 雲端 X60 檔案（對應 Windows 版 CloudFiles.cpp，API v2；伺服器為 notepad2xs_cloud_fils_system.php）
#import "CloudFiles.h"
#import "Localization.h"
#import "SyntaxStyles.h"
#include "CloudCore.h"
#include "ExAlgorithms.h"
#include <map>
#include <string>
#include <vector>

using namespace xs::cloud;

static NSString *const kCloudBaseKey = @"CloudApiPath";
static NSString *const kCloudViewKey = @"CloudFileView";              // Details／Icons
static NSString *const kCloudColumnsVisibleKey = @"CloudFileColumnsVisible";
static NSString *const kCloudColumnsOrderKey = @"CloudFileColumnsOrder";
static NSString *const kCloudColumnsWidthsKey = @"CloudFileColumnsWidths";
static NSString *const kCloudSortKey = @"CloudFileSort";
static NSString *const kCloudSortAscendingKey = @"CloudFileSortAscending";

#pragma mark - 錯誤

namespace {
struct Issue {
    NSString *text;
    NSInteger status = 0;
};
[[noreturn]] void Fail(NSString *zh, NSInteger status = 0) { throw Issue{N2L(zh), status}; }

NSString *IssueText(const Issue &issue) {
    if (!issue.status) return issue.text;
    return [NSString stringWithFormat:@"%@ (HTTP %ld)", issue.text, (long)issue.status];
}

std::u16string U16(NSString *s) {
    std::u16string r(s.length, u'\0');
    [s getCharacters:(unichar *)r.data() range:NSMakeRange(0, s.length)];
    return r;
}
bool ValidName(NSString *name) { return name && validName(U16(name)); }
bool ValidId(NSString *s) { return s && validId(s.UTF8String ?: ""); }
bool ValidFolder(NSString *s) { return s && validFolder(s.UTF8String ?: ""); }
bool ValidRevision(NSString *s) { return s && validRevision(s.UTF8String ?: ""); }
NSString *Encode(NSString *s) {
    std::string e = encode(s.UTF8String ?: "");
    return [NSString stringWithUTF8String:e.c_str()];
}
}

void N2CloudMessage(NSWindow *parent, NSString *text) {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = N2L(@"雲端檔案");
    a.informativeText = text ?: @"";
    [a addButtonWithTitle:N2L(@"確定")];
    [a runModal];
}

static void ShowIssue(const Issue &issue) { N2CloudMessage(nil, IssueText(issue)); }

#pragma mark - N2CloudFile

@implementation N2CloudFile
- (BOOL)isSameFile:(N2CloudFile *)other {
    return other && [self.api isEqualToString:other.api] && [self.fileID isEqualToString:other.fileID];
}
@end

#pragma mark - HTTP

namespace {
struct Reply {
    NSInteger status = 0;
    NSData *body;
    NSString *revision;   // X-Notepad2XS-Revision（download）
};

struct Location {
    NSString *base, *api;
};

Location LocationFor(NSString *base) {
    if (!base.length || ![base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
        Fail(@"請先在「雲端設定」填寫 API 路徑。");
    Endpoint e = endpoint(base.UTF8String ?: "");
    if (!e.ok) Fail(@"請輸入 HTTP 或 HTTPS 的資料夾網址。");
    return {[NSString stringWithUTF8String:e.base.c_str()], [NSString stringWithUTF8String:e.api.c_str()]};
}

bool gTerminating = false;   // 結束程式中：縮短逾時、不跳出訊息
}

// 不跟隨轉址（與 Windows 版相同）：3xx 直接當成回應，避免 POST 變成 GET 或把密文送到其他主機
@interface N2CloudNoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation N2CloudNoRedirect
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

void N2CloudPrepareForTermination(void) { gTerminating = true; }

namespace {
NSURLSession *Session(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        c.URLCache = nil;
        c.HTTPCookieStorage = nil;
        c.timeoutIntervalForRequest = 60;
        c.timeoutIntervalForResource = 600;
        session = [NSURLSession sessionWithConfiguration:c delegate:[N2CloudNoRedirect new] delegateQueue:nil];
    });
    return session;
}

// 同步送出（與 Windows 版相同：操作期間等候伺服器回應）；不跟隨轉址
Reply Request(const Location &loc, NSString *query, BOOL post = NO, NSData *body = nil,
              NSString *contentType = nil, NSUInteger limit = 5 * 1024 * 1024) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?func=%@", loc.api, query]];
    if (!url) Fail(@"請輸入 HTTP 或 HTTPS 的資料夾網址。");
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = post ? @"POST" : @"GET";
    if (gTerminating) r.timeoutInterval = 8;
    [r setValue:@"application/json, text/plain" forHTTPHeaderField:@"Accept"];
    if (post) {
        [r setValue:contentType ?: @"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        r.HTTPBody = body ?: [NSData data];
    }
    __block Reply reply;
    __block BOOL failed = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSCursor *previous = NSCursor.currentCursor;
    [NSCursor.operationNotAllowedCursor set];
    NSURLSessionDataTask *task = [Session() dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (err || !http) failed = YES;
        else {
            reply.status = http.statusCode;
            reply.body = data ?: [NSData data];
            reply.revision = [http valueForHTTPHeaderField:@"X-Notepad2XS-Revision"];
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [previous set];
    if (failed) Fail(@"連線失敗或逾時，請檢查 API 路徑與連線。");
    if (reply.body.length > limit) Fail(@"檔案超過可處理的大小。");
    return reply;
}

NSDictionary *Parse(const Reply &reply) {
    id value = reply.body.length ? [NSJSONSerialization JSONObjectWithData:reply.body options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) Fail(@"伺服器回應有誤或未完成操作。");
    return value;
}

void Verify(const Reply &reply) {
    if (reply.status == 200 || reply.status == 201) return;
    NSString *zh = @"伺服器回應有誤或未完成操作。";
    switch (reply.status) {
        case 401: case 403: zh = @"伺服器拒絕存取。請檢查來源 IP 白名單。"; break;
        case 404: zh = @"找不到指定的雲端檔案或 API。"; break;
        case 409: zh = @"雲端已有同名檔案。"; break;
        case 413: zh = @"檔案超過可處理的大小。"; break;
        case 422: zh = @"檔案內容不符合 X60 格式。"; break;
        default: break;
    }
    if (reply.status == 404 || reply.status == 409) {
        id value = reply.body.length ? [NSJSONSerialization JSONObjectWithData:reply.body options:0 error:nil] : nil;
        NSString *code = [value isKindOfClass:NSDictionary.class] ? value[@"error"] : nil;
        if ([code isKindOfClass:NSString.class]) {
            NSDictionary *reasons = @{
                @"revision_conflict": @"雲端檔案在開啟後已變更。請重新開啟並比對內容。",
                @"folder_not_found": @"找不到資料夾。請重新整理清單。",
                @"folder_not_empty": @"請先移出這個資料夾中的檔案與子資料夾。",
                @"folder_exists": @"這個位置已有同名資料夾。",
                @"folder_limit": @"已達到資料夾數量或層級上限。",
                @"folder_cycle": @"請選擇這個資料夾及其子資料夾以外的位置。",
                @"preferences_conflict": @"雲端檔案或逐檔設定已更新，這次逐檔設定未寫入。",
            };
            if (reasons[code]) zh = reasons[code];
        }
    }
    Fail(zh, reply.status);
}

NSDictionary *JsonResult(const Reply &reply) {
    Verify(reply);
    NSDictionary *o = Parse(reply);
    NSNumber *ok = o[@"ok"];
    if (![ok isKindOfClass:NSNumber.class] || !ok.boolValue) Fail(@"伺服器回應有誤或未完成操作。");
    return o;
}

NSString *String(NSDictionary *o, NSString *key) {
    id v = o[key];
    if (![v isKindOfClass:NSString.class]) Fail(@"伺服器回應有誤或未完成操作。");
    return v;
}

uint64_t Number(NSDictionary *o, NSString *key) {
    id v = o[key];
    if (![v isKindOfClass:NSNumber.class] || [v doubleValue] < 0) Fail(@"伺服器回應有誤或未完成操作。");
    return [v unsignedLongLongValue];
}

NSString *NamedQuery(NSString *folder, NSString *name) {
    return [NSString stringWithFormat:@"folder=%@&name=%@", folder, Encode(name)];
}

NSData *Form(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

NSDictionary *Upload(const Location &loc, NSString *target, NSString *revision, NSData *bytes) {
    if (bytes.length > cipherLimit) Fail(@"檔案超過可處理的大小。");
    NSString *q = [@"update&" stringByAppendingString:target];
    if (revision.length) q = [q stringByAppendingFormat:@"&overwrite=1&revision=%@", revision];
    return JsonResult(Request(loc, q, YES, bytes, @"text/plain; charset=US-ASCII", 5 * 1024 * 1024));
}

NSString *CloudTitle(NSString *name, NSString *path) {
    return [NSString stringWithFormat:@"%@.x60 [%@%@]", name, N2L(@"雲端"), path.length ? [@" · " stringByAppendingString:path] : @""];
}

N2CloudFile *MetadataFile(const Location &loc, NSDictionary *result) {
    NSDictionary *o = result[@"file"];
    if (![o isKindOfClass:NSDictionary.class]) Fail(@"伺服器回應有誤或未完成操作。");
    N2CloudFile *f = [N2CloudFile new];
    f.base = loc.base;
    f.api = loc.api;
    f.fileID = String(o, @"id");
    f.name = String(o, @"name");
    f.folder = String(o, @"folder");
    f.revision = String(o, @"revision");
    if (!ValidId(f.fileID) || !ValidName(f.name) || !ValidFolder(f.folder) || !ValidRevision(f.revision))
        Fail(@"伺服器回應有誤或未完成操作。");
    f.title = CloudTitle(f.name, String(o, @"folder_path"));
    return f;
}

Location LocationOf(N2CloudFile *f) { return {f.base, f.api}; }
}

NSString *N2CloudConfiguredBase(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:kCloudBaseKey] ?: @"";
}

BOOL N2CloudCanSaveX60(NSData *text) {
    return text.length && xs::validX60Envelope(std::string_view((const char *)text.bytes, text.length));
}

#pragma mark - 簡易表單視窗（設定、檔名、目的地、資料夾、衝突處理）

@interface N2CloudForm : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSStackView *rows;
@property (nonatomic, strong) NSStackView *buttons;
@property (nonatomic) NSInteger result;
@property (nonatomic, copy) BOOL (^validate)(NSInteger code);   // 回傳 NO：不關閉
@end

@implementation N2CloudForm {
    NSMutableDictionary<NSNumber *, NSButton *> *_byCode;
}

+ (instancetype)formWithTitle:(NSString *)title {
    N2CloudForm *f = [N2CloudForm new];
    f->_byCode = [NSMutableDictionary dictionary];
    f.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 120)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered defer:NO];
    f.panel.title = title;
    f.panel.delegate = f;
    f.panel.releasedWhenClosed = NO;
    f.rows = [NSStackView stackViewWithViews:@[]];
    f.rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    f.rows.alignment = NSLayoutAttributeLeading;
    f.rows.spacing = 10;
    f.buttons = [NSStackView stackViewWithViews:@[]];
    f.buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    f.buttons.spacing = 8;
    NSStackView *all = [NSStackView stackViewWithViews:@[f.rows, f.buttons]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeTrailing;
    all.spacing = 18;
    all.edgeInsets = NSEdgeInsetsMake(18, 20, 16, 20);
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [f.panel.contentView addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.leadingAnchor constraintEqualToAnchor:f.panel.contentView.leadingAnchor],
        [all.trailingAnchor constraintEqualToAnchor:f.panel.contentView.trailingAnchor],
        [all.topAnchor constraintEqualToAnchor:f.panel.contentView.topAnchor],
        [all.bottomAnchor constraintEqualToAnchor:f.panel.contentView.bottomAnchor],
        [f.rows.leadingAnchor constraintEqualToAnchor:all.leadingAnchor constant:20],
        [f.buttons.trailingAnchor constraintEqualToAnchor:all.trailingAnchor constant:-20],
        [f.rows.widthAnchor constraintGreaterThanOrEqualToConstant:380],
    ]];
    return f;
}

- (void)addRow:(NSView *)view { [self.rows addArrangedSubview:view]; }

- (void)addText:(NSString *)text {
    NSTextField *t = [NSTextField wrappingLabelWithString:text];
    t.selectable = YES;
    t.preferredMaxLayoutWidth = 400;
    [self addRow:t];
}

// 「標籤：欄位（＋後綴）」一列
- (void)addLabel:(NSString *)label field:(NSView *)field suffix:(NSString *)suffix {
    NSTextField *l = [NSTextField labelWithString:label];
    [l setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray *views = [NSMutableArray arrayWithObjects:l, field, nil];
    if (suffix) [views addObject:[NSTextField labelWithString:suffix]];
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.spacing = 8;
    [field.widthAnchor constraintGreaterThanOrEqualToConstant:300].active = YES;
    [self addRow:row];
}

- (NSButton *)addButton:(NSString *)title code:(NSInteger)code key:(NSString *)key {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(pressed:)];
    b.tag = code;
    if (key) b.keyEquivalent = key;
    [self.buttons insertArrangedSubview:b atIndex:0];   // 先加入的按鈕在最右邊（與 NSAlert 相同）
    _byCode[@(code)] = b;
    return b;
}

- (void)pressed:(NSButton *)b {
    if (self.validate && !self.validate(b.tag)) return;
    self.result = b.tag;
    [NSApp stopModalWithCode:b.tag];
}

- (BOOL)windowShouldClose:(NSWindow *)w {
    self.result = NSModalResponseCancel;
    [NSApp stopModalWithCode:NSModalResponseCancel];
    return NO;
}

- (NSInteger)run {
    [self.panel layoutIfNeeded];
    NSSize fit = self.panel.contentView.fittingSize;
    [self.panel setContentSize:NSMakeSize(MAX(fit.width, 440), fit.height)];
    [self.panel center];
    self.result = NSModalResponseCancel;
    [NSApp runModalForWindow:self.panel];
    [self.panel orderOut:nil];
    return self.result;
}
@end

static NSTextField *EditField(NSString *value) {
    NSTextField *f = [NSTextField textFieldWithString:value ?: @""];
    f.lineBreakMode = NSLineBreakByTruncatingHead;
    return f;
}

#pragma mark - 雲端設定

void N2CloudShowSettings(NSWindow *parent) {
    N2CloudForm *f = [N2CloudForm formWithTitle:N2L(@"雲端設定")];
    NSTextField *url = EditField(N2CloudConfiguredBase());
    url.placeholderString = @"https://example.org/exes/";
    [f addLabel:N2L(@"API 路徑") field:url suffix:nil];
    [f addText:N2L(@"輸入放置 notepad2xs_cloud_fils_system.php 的資料夾網址，程式會自動補上 PHP 檔名。")];
    [f addButton:N2L(@"確定") code:NSModalResponseOK key:@"\r"];
    [f addButton:N2L(@"取消") code:NSModalResponseCancel key:@"\e"];
    [f addButton:N2L(@"測試連線") code:2 key:nil];
    f.validate = ^BOOL(NSInteger code) {
        if (code == NSModalResponseCancel) return YES;
        try {
            Location loc = LocationFor(url.stringValue);
            if (code == 2) {
                NSDictionary *r = JsonResult(Request(loc, @"ping"));
                NSAlert *a = [NSAlert new];
                a.messageText = N2L(@"已連線至 Notepad2XS 雲端 API。");
                a.informativeText = [NSString stringWithFormat:@"%@  %llu\n%@  %llu B", N2L(@"API 版本"), Number(r, @"api_version"),
                                     N2L(@"單檔上傳上限"), Number(r, @"max_upload_bytes")];
                [a addButtonWithTitle:N2L(@"確定")];
                [a runModal];
                return NO;
            }
            [NSUserDefaults.standardUserDefaults setObject:loc.base forKey:kCloudBaseKey];
            return YES;
        } catch (const Issue &issue) {
            ShowIssue(issue);
            return NO;
        }
    };
    [f run];
}

#pragma mark - 資料夾

@interface N2CloudFolder : NSObject
@property (nonatomic, copy) NSString *folderID, *parent, *name, *path;
@end
@implementation N2CloudFolder
@end

typedef NSDictionary<NSString *, N2CloudFolder *> N2CloudFolders;

namespace {
N2CloudFolders *ReadFolders(NSDictionary *result) {
    id list = result[@"folders"];
    if (!list) Fail(@"請更新伺服器上的 Notepad2XS 雲端 PHP。");
    if (![list isKindOfClass:NSArray.class] || [list count] > 1000) Fail(@"伺服器回應有誤或未完成操作。");
    NSMutableDictionary *folders = [NSMutableDictionary dictionary];
    N2CloudFolder *root = [N2CloudFolder new];
    root.folderID = @"root"; root.parent = @""; root.name = @""; root.path = N2L(@"根目錄");
    folders[@"root"] = root;
    for (id value in list) {
        if (![value isKindOfClass:NSDictionary.class]) Fail(@"伺服器回應有誤或未完成操作。");
        N2CloudFolder *f = [N2CloudFolder new];
        f.folderID = String(value, @"id");
        f.parent = String(value, @"parent");
        f.name = String(value, @"name");
        if (!ValidId(f.folderID) || !ValidFolder(f.parent) || !ValidName(f.name) || folders[f.folderID])
            Fail(@"伺服器回應有誤或未完成操作。");
        folders[f.folderID] = f;
    }
    for (N2CloudFolder *f in folders.allValues) {
        if ([f.folderID isEqualToString:@"root"]) continue;
        NSString *parent = f.folderID, *path = @"";
        for (int depth = 0; ![parent isEqualToString:@"root"]; ++depth) {
            N2CloudFolder *part = folders[parent];
            if (depth == 16 || !part) Fail(@"伺服器回應有誤或未完成操作。");
            path = path.length ? [NSString stringWithFormat:@"%@ / %@", part.name, path] : part.name;
            parent = part.parent;
        }
        f.path = path;
    }
    return folders;
}

bool IsWithinFolder(N2CloudFolders *folders, NSString *candidate, NSString *ancestor) {
    for (int guard = 0; guard < 32; ++guard) {
        if ([candidate isEqualToString:ancestor]) return true;
        if ([candidate isEqualToString:@"root"] || !folders[candidate]) return false;
        candidate = folders[candidate].parent;
    }
    return false;
}

// 資料夾選單：根目錄在最前面，其他依路徑排序
NSPopUpButton *FolderPopup(N2CloudFolders *folders, NSString *selected, NSString *exclude) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26) pullsDown:NO];
    NSMutableArray<N2CloudFolder *> *ordered = [NSMutableArray array];
    for (N2CloudFolder *f in folders.allValues)
        if (!exclude.length || !IsWithinFolder(folders, f.folderID, exclude)) [ordered addObject:f];
    [ordered sortUsingComparator:^NSComparisonResult(N2CloudFolder *a, N2CloudFolder *b) {
        BOOL ra = [a.folderID isEqualToString:@"root"], rb = [b.folderID isEqualToString:@"root"];
        if (ra != rb) return ra ? NSOrderedAscending : NSOrderedDescending;
        return [a.path localizedStandardCompare:b.path];
    }];
    for (N2CloudFolder *f in ordered) {
        [p addItemWithTitle:@""];
        p.lastItem.title = f.path;
        p.lastItem.representedObject = f.folderID;
        if ([f.folderID isEqualToString:selected]) [p selectItem:p.lastItem];
    }
    return p;
}

// 輸入檔名或資料夾名稱；取消回傳 nil
NSString *AskName(NSString *title, NSString *initial, bool isFile) {
    N2CloudForm *f = [N2CloudForm formWithTitle:title];
    NSTextField *field = EditField(initial);
    [f addLabel:N2L(@"檔名") field:field suffix:isFile ? @".x60" : nil];
    [f addButton:N2L(@"確定") code:NSModalResponseOK key:@"\r"];
    [f addButton:N2L(@"取消") code:NSModalResponseCancel key:@"\e"];
    f.validate = ^BOOL(NSInteger code) {
        if (code != NSModalResponseOK || ValidName(field.stringValue)) return YES;
        N2CloudMessage(nil, N2L(@"請輸入有效檔名並省略 .x60 副檔名。"));
        return NO;
    };
    [f.panel makeFirstResponder:field];
    return [f run] == NSModalResponseOK ? field.stringValue : nil;
}

struct Destination { NSString *folder = @"root"; NSString *name = @""; };

bool ChooseDestination(NSString *title, N2CloudFolders *folders, Destination &value) {
    N2CloudForm *f = [N2CloudForm formWithTitle:title];
    NSPopUpButton *popup = FolderPopup(folders, value.folder, nil);
    NSTextField *field = EditField(value.name);
    [f addLabel:N2L(@"資料夾") field:popup suffix:nil];
    [f addLabel:N2L(@"檔名") field:field suffix:@".x60"];
    [f addButton:N2L(@"確定") code:NSModalResponseOK key:@"\r"];
    [f addButton:N2L(@"取消") code:NSModalResponseCancel key:@"\e"];
    f.validate = ^BOOL(NSInteger code) {
        if (code != NSModalResponseOK || (popup.selectedItem && ValidName(field.stringValue))) return YES;
        N2CloudMessage(nil, N2L(@"請輸入有效檔名並省略 .x60 副檔名。"));
        return NO;
    };
    [f.panel makeFirstResponder:field];
    if ([f run] != NSModalResponseOK) return false;
    value.folder = popup.selectedItem.representedObject;
    value.name = field.stringValue;
    return true;
}

bool PickFolder(NSString *title, N2CloudFolders *folders, NSString **destination, NSString *exclude) {
    N2CloudForm *f = [N2CloudForm formWithTitle:title];
    NSPopUpButton *popup = FolderPopup(folders, *destination, exclude);
    [f addLabel:N2L(@"資料夾") field:popup suffix:nil];
    [f addButton:N2L(@"確定") code:NSModalResponseOK key:@"\r"];
    [f addButton:N2L(@"取消") code:NSModalResponseCancel key:@"\e"];
    if ([f run] != NSModalResponseOK || !popup.selectedItem) return false;
    *destination = popup.selectedItem.representedObject;
    return true;
}

bool ConfirmDelete(NSString *title, NSString *prompt, NSString *name) {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = title;
    a.informativeText = [NSString stringWithFormat:@"%@\n\n%@", prompt, name];
    [a addButtonWithTitle:N2L(@"刪除")];
    [a addButtonWithTitle:N2L(@"取消")];
    a.buttons[1].keyEquivalent = @"\e";
    a.buttons[0].keyEquivalent = @"";
    a.buttons[1].keyEquivalent = @"\r";   // 預設按鈕是「取消」（與 Windows 版相同）
    return [a runModal] == NSAlertFirstButtonReturn;
}

void ShowText(NSString *title, NSString *text) {
    N2CloudForm *f = [N2CloudForm formWithTitle:title];
    [f addText:text];
    [f addButton:N2L(@"確定") code:NSModalResponseOK key:@"\r"];
    [f run];
}

enum class SaveOutcome { Saved, Retry, Cancel };

// 存到雲端／上傳：同名時確認覆蓋（是＝覆蓋、否＝重新選擇、取消＝放棄）
SaveOutcome SaveNewTarget(NSString *title, const Location &loc, const Destination &target, NSData *bytes,
                          BOOL (^isOpen)(N2CloudFile *), BOOL (^unchanged)(void), N2CloudFile **saved) {
    auto ensure = [&] { if (unchanged && !unchanged()) Fail(@"雲端儲存未完成，請確認後重試。"); };
    ensure();
    NSString *query = NamedQuery(target.folder, target.name);
    try {
        *saved = MetadataFile(loc, Upload(loc, query, nil, bytes));
        return SaveOutcome::Saved;
    } catch (const Issue &issue) {
        if (issue.status != 409 || ![issue.text isEqualToString:N2L(@"雲端已有同名檔案。")]) throw;
    }
    N2CloudFile *existing = MetadataFile(loc, JsonResult(Request(loc, [@"stat&" stringByAppendingString:query])));
    if (isOpen && isOpen(existing)) {
        N2CloudMessage(nil, N2L(@"這個檔案已在另一個分頁開啟。請選擇其他檔名。"));
        return SaveOutcome::Retry;
    }
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = title;
    a.informativeText = [NSString stringWithFormat:@"%@\n\n%@", N2L(@"要覆蓋這份雲端檔案嗎？"), existing.title];
    [a addButtonWithTitle:N2L(@"覆蓋")];
    [a addButtonWithTitle:N2L(@"重新選擇")];
    [a addButtonWithTitle:N2L(@"取消")];
    a.buttons[0].keyEquivalent = @"";
    a.buttons[1].keyEquivalent = @"\r";
    NSModalResponse r = [a runModal];
    if (r == NSAlertThirdButtonReturn) return SaveOutcome::Cancel;
    if (r != NSAlertFirstButtonReturn) return SaveOutcome::Retry;
    ensure();
    N2CloudFile *updated = MetadataFile(loc, Upload(loc, query, existing.revision, bytes));
    if (![updated.fileID isEqualToString:existing.fileID]) Fail(@"伺服器回應有誤或未完成操作。");
    *saved = updated;
    return SaveOutcome::Saved;
}

NSData *ReadX60(NSURL *url) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (!attrs) Fail(@"無法讀取本機檔案。");
    unsigned long long size = attrs.fileSize;
    if (size < 203) Fail(@"檔案內容不符合 X60 格式。");
    if (size > cipherLimit) Fail(@"檔案超過可處理的大小。");
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data) Fail(@"無法讀取本機檔案。");
    if (!N2CloudCanSaveX60(data)) Fail(@"檔案內容不符合 X60 格式。");
    return data;
}

bool HasX60Extension(NSString *name) { return name && hasX60Extension(U16(name)); }
}

#pragma mark - 存到雲端、存檔、逐檔設定

N2CloudFile *N2CloudSaveNew(NSWindow *parent, NSData *cipher, BOOL (^isOpen)(N2CloudFile *), BOOL (^unchanged)(void)) {
    NSString *title = N2L(@"存到雲端…");
    try {
        if (!N2CloudCanSaveX60(cipher)) Fail(@"檔案內容不符合 X60 格式。");
        Location loc = LocationFor(N2CloudConfiguredBase());
        Reply folders = Request(loc, @"folders");
        if (folders.status == 400) Fail(@"請更新伺服器上的 Notepad2XS 雲端 PHP。");
        N2CloudFolders *all = ReadFolders(JsonResult(folders));
        Destination target;
        while (ChooseDestination(title, all, target)) {
            N2CloudFile *saved = nil;
            SaveOutcome outcome = SaveNewTarget(title, loc, target, cipher, isOpen, unchanged, &saved);
            if (outcome == SaveOutcome::Retry) continue;
            if (outcome == SaveOutcome::Cancel) return nil;
            if (unchanged && !unchanged()) Fail(@"雲端儲存未完成，請確認後重試。");
            return saved;
        }
    } catch (const Issue &issue) {
        ShowIssue(issue);
    }
    return nil;
}

BOOL N2CloudUpload(NSWindow *parent, N2CloudFile *file, NSData *cipher) {
    try {
        N2CloudFile *updated = MetadataFile(LocationOf(file), Upload(LocationOf(file), [@"id=" stringByAppendingString:file.fileID], file.revision, cipher));
        if (![updated.fileID isEqualToString:file.fileID]) Fail(@"伺服器回應有誤或未完成操作。");
        file.name = updated.name;
        file.folder = updated.folder;
        file.title = updated.title;
        file.revision = updated.revision;
        return YES;
    } catch (const Issue &issue) {
        ShowIssue(issue);
    }
    return NO;
}

NSData *N2CloudLoadState(NSWindow *parent, N2CloudFile *file) {
    try {
        NSDictionary *r = JsonResult(Request(LocationOf(file), [NSString stringWithFormat:@"prefs_get&id=%@&revision=%@", file.fileID, file.revision]));
        NSString *state = String(r, @"state");
        NSString *revision = String(r, @"prefs_revision");
        NSData *bytes = [state dataUsingEncoding:NSUTF8StringEncoding];
        if (bytes.length > 1048576 || !ValidRevision(revision)) Fail(@"伺服器回應有誤或未完成操作。");
        file.prefsState = bytes;
        file.prefsRevision = revision;
        return bytes;
    } catch (const Issue &) {
        N2CloudMessage(parent, N2L(@"無法讀取這份雲端檔案的逐檔設定。"));
    }
    return nil;
}

BOOL N2CloudSaveState(NSWindow *parent, N2CloudFile *file, NSData *state) {
    if (!file.prefsRevision.length || !state) return NO;
    if ([state isEqualToData:file.prefsState ?: [NSData data]]) return YES;
    try {
        NSString *q = [NSString stringWithFormat:@"prefs_set&id=%@&revision=%@&prefs_revision=%@", file.fileID, file.revision, file.prefsRevision];
        NSDictionary *r = JsonResult(Request(LocationOf(file), q, YES, state, @"text/plain; charset=US-ASCII"));
        NSString *revision = String(r, @"prefs_revision");
        if (!ValidRevision(revision)) Fail(@"伺服器回應有誤或未完成操作。");
        file.prefsRevision = revision;
        file.prefsState = state;
        return YES;
    } catch (const Issue &issue) {
        if (gTerminating) return NO;
        BOOL conflict = [issue.text isEqualToString:N2L(@"雲端檔案或逐檔設定已更新，這次逐檔設定未寫入。")] ||
                        [issue.text isEqualToString:N2L(@"雲端檔案在開啟後已變更。請重新開啟並比對內容。")];
        N2CloudMessage(parent, conflict ? N2L(@"雲端檔案或逐檔設定已更新，這次逐檔設定未寫入。")
                                        : N2L(@"無法儲存此檔案的個別設定。本次開啟期間仍會套用。"));
    }
    return NO;
}

#pragma mark - 雲端檔案視窗

@interface N2CloudItem : NSObject
@property (nonatomic) BOOL isFolder;
@property (nonatomic, copy) NSString *itemID, *name, *parent;
@property (nonatomic) uint64_t size, modified;
@property (nonatomic) int syntax;
@end
@implementation N2CloudItem
@end

// 圖示檢視的項目
@interface N2CloudIconItem : NSCollectionViewItem
@end
@implementation N2CloudIconItem
- (void)loadView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 112, 96)];
    v.wantsLayer = YES;
    v.layer.cornerRadius = 6;
    NSImageView *image = [NSImageView imageViewWithImage:[NSImage imageNamed:NSImageNameFolder]];
    image.frame = NSMakeRect(32, 40, 48, 48);
    image.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.frame = NSMakeRect(4, 2, 104, 36);
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:11];
    label.maximumNumberOfLines = 2;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [v addSubview:image];
    [v addSubview:label];
    self.view = v;
    self.imageView = image;
    self.textField = label;
}
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.view.layer.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.CGColor : NSColor.clearColor.CGColor;
    self.textField.textColor = selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
}
@end

@class N2CloudBrowser;

// 表格：Return 開啟、F2 更名、Delete 刪除、F5 重新整理、⌥↑／⌘↑ 上一層
@interface N2CloudTable : NSTableView
@property (nonatomic, weak) N2CloudBrowser *browser;
@end
@interface N2CloudCollection : NSCollectionView
@property (nonatomic, weak) N2CloudBrowser *browser;
@end

@interface N2CloudBrowser : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                      NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate>
- (BOOL)handleKey:(NSEvent *)e;
- (void)openSelected;
- (NSMenu *)menuForItem:(N2CloudItem *)item;
- (N2CloudItem *)itemAtRow:(NSInteger)row;
- (NSDragOperation)validateDropFor:(NSArray<NSURL *> *)urls;
- (void)uploadDropped:(NSArray<NSURL *> *)urls toFolder:(NSString *)folder;
@end

@implementation N2CloudTable
- (void)keyDown:(NSEvent *)e { if (![self.browser handleKey:e]) [super keyDown:e]; }
- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSInteger row = [self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (row >= 0) [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    else [self deselectAll:nil];
    return [self.browser menuForItem:[self.browser itemAtRow:row]];
}
@end

@implementation N2CloudCollection
- (void)keyDown:(NSEvent *)e { if (![self.browser handleKey:e]) [super keyDown:e]; }
- (void)mouseDown:(NSEvent *)e {
    [super mouseDown:e];
    if (e.clickCount == 2 && self.selectionIndexPaths.count) [self.browser openSelected];
}
- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSIndexPath *p = [self indexPathForItemAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    self.selectionIndexPaths = p ? [NSSet setWithObject:p] : [NSSet set];
    return [self.browser menuForItem:p ? [self.browser itemAtRow:p.item] : nil];
}
@end

@implementation N2CloudBrowser {
    Location _loc;
    N2CloudFolders *_folders;
    NSArray<N2CloudItem *> *_rows;      // 所有檔案（伺服器回傳）
    NSArray<N2CloudItem *> *_visible;   // 目前顯示的項目（資料夾在前）
    NSString *_folder;
    ColumnSettings _columns;
    BOOL _icons, _busy, _loaded;
    NSPanel *_panel;
    N2CloudTable *_table;
    NSScrollView *_tableScroll, *_iconScroll;
    N2CloudCollection *_collection;
    NSPathControl *_path;
    NSArray<NSString *> *_pathIDs;
    NSSearchField *_search;
    NSButton *_searchAll, *_up, *_open, *_rename, *_copy, *_move, *_delete, *_newFolder, *_upload;
    NSPopUpButton *_view;
    NSTextField *_status;
    NSMutableDictionary<NSNumber *, NSImage *> *_syntaxIcons;
@public
    void (^_updateTab)(N2CloudFile *);
    N2CloudFile *_opened;
}

static NSString *ColumnTitle(NSInteger column) {
    static NSString *const titles[] = {@"檔名", @"類型", @"大小", @"最後修改時間", @"路徑", @"副檔名"};
    return N2L(titles[column]);
}

- (instancetype)initWithLocation:(const Location &)loc {
    if ((self = [super init])) {
        _loc = loc;
        _folder = @"root";
        _folders = @{};
        _rows = @[];
        _visible = @[];
        _syntaxIcons = [NSMutableDictionary dictionary];
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        _icons = [[d stringForKey:kCloudViewKey] isEqualToString:@"Icons"];
        // 設定值型別不對時（例如被改成文字）integerForKey 會盡量轉換，不會丟出例外
        BOOL hasVisible = [d objectForKey:kCloudColumnsVisibleKey] != nil, hasSort = [d objectForKey:kCloudSortKey] != nil;
        _columns = readColumnSettings(hasVisible ? (long)[d integerForKey:kCloudColumnsVisibleKey] : (long)defaultVisibleColumns,
                                      [d stringForKey:kCloudColumnsOrderKey].UTF8String ?: "",
                                      [d stringForKey:kCloudColumnsWidthsKey].UTF8String ?: "",
                                      hasSort ? (long)[d integerForKey:kCloudSortKey] : defaultSort, [d boolForKey:kCloudSortAscendingKey]);
        [self buildWindow];
    }
    return self;
}

#pragma mark 建立視窗

- (NSButton *)button:(NSString *)zh action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:N2L(zh) target:self action:action];
    b.controlSize = NSControlSizeRegular;
    return b;
}

- (void)buildWindow {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 900, 540)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered defer:NO];
    _panel.title = N2L(@"雲端檔案");
    _panel.delegate = self;
    _panel.releasedWhenClosed = NO;
    _panel.minSize = NSMakeSize(720, 360);
    _panel.frameAutosaveName = @"N2CloudFilesWindow";
    NSView *content = _panel.contentView;

    _up = [self button:@"上一層" action:@selector(goUp:)];
    _path = [NSPathControl new];
    _path.pathStyle = NSPathStyleStandard;
    _path.target = self;
    _path.action = @selector(pathClicked:);
    _path.focusRingType = NSFocusRingTypeNone;
    [_path setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _search = [NSSearchField new];
    _search.placeholderString = N2L(@"搜尋檔名");
    _search.delegate = self;
    _search.sendsSearchStringImmediately = YES;
    [_search.widthAnchor constraintEqualToConstant:200].active = YES;
    _searchAll = [NSButton checkboxWithTitle:N2L(@"搜尋所有資料夾") target:self action:@selector(searchChanged:)];
    _view = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [_view addItemWithTitle:N2L(@"檢視")];
    [_view addItemWithTitle:N2L(@"詳細資料")];
    [_view addItemWithTitle:N2L(@"圖示")];
    _view.itemArray[1].target = self; _view.itemArray[1].action = @selector(showDetails:);
    _view.itemArray[2].target = self; _view.itemArray[2].action = @selector(showIcons:);
    NSStackView *top = [NSStackView stackViewWithViews:@[_up, _path, _search, _searchAll, _view]];
    top.spacing = 8;
    for (NSView *v in @[_up, _searchAll, _view]) {
        [v setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [v setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    [_path setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [top setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // 詳細資料：可排序、可隱藏、可拖曳換序與調整寬度的欄位
    _table = [N2CloudTable new];
    _table.browser = self;
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsColumnReordering = YES;
    _table.allowsColumnResizing = YES;
    _table.allowsMultipleSelection = NO;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    _table.doubleAction = @selector(tableDoubleClick:);
    _table.target = self;
    _table.style = NSTableViewStyleFullWidth;
    _table.rowHeight = 20;
    std::array<NSTableColumn *, columnCount> cols;
    for (NSInteger i = 0; i < (NSInteger)columnCount; ++i) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%ld", (long)i]];
        c.title = ColumnTitle(i);
        c.width = _columns.widths[(size_t)i];
        c.minWidth = 32;
        c.maxWidth = 1200;
        c.hidden = !(_columns.visible & (1u << i));
        if (i == 2) c.headerCell.alignment = NSTextAlignmentRight;
        cols[(size_t)i] = c;
    }
    for (int index : _columns.order) [_table addTableColumn:cols[(size_t)index]];
    NSMenu *header = [NSMenu new];
    header.delegate = self;
    _table.headerView.menu = header;
    [_table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [_table setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
    _tableScroll = [NSScrollView new];
    _tableScroll.documentView = _table;
    _tableScroll.hasVerticalScroller = YES;
    _tableScroll.hasHorizontalScroller = YES;
    _tableScroll.borderType = NSBezelBorder;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(columnsChanged:) name:NSTableViewColumnDidMoveNotification object:_table];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(columnsChanged:) name:NSTableViewColumnDidResizeNotification object:_table];

    // 圖示：大圖示排列，檔名在圖示下方
    NSCollectionViewFlowLayout *flow = [NSCollectionViewFlowLayout new];
    flow.itemSize = NSMakeSize(112, 96);
    flow.minimumInteritemSpacing = 8;
    flow.minimumLineSpacing = 8;
    flow.sectionInset = NSEdgeInsetsMake(10, 10, 10, 10);
    _collection = [N2CloudCollection new];
    _collection.browser = self;
    _collection.collectionViewLayout = flow;
    _collection.dataSource = self;
    _collection.delegate = self;
    _collection.selectable = YES;
    _collection.allowsMultipleSelection = NO;
    [_collection registerClass:N2CloudIconItem.class forItemWithIdentifier:@"icon"];
    [_collection registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    _collection.backgroundColors = @[NSColor.controlBackgroundColor];
    _iconScroll = [NSScrollView new];
    _iconScroll.documentView = _collection;
    _iconScroll.hasVerticalScroller = YES;
    _iconScroll.borderType = NSBezelBorder;

    _open = [self button:@"開啟" action:@selector(openPressed:)];
    _open.keyEquivalent = @"\r";
    _upload = [self button:@"上傳" action:@selector(uploadPressed:)];
    _newFolder = [self button:@"新增資料夾…" action:@selector(newFolderPressed:)];
    _rename = [self button:@"更名" action:@selector(renamePressed:)];
    _copy = [self button:@"複製" action:@selector(copyPressed:)];
    _move = [self button:@"搬移到…" action:@selector(movePressed:)];
    _delete = [self button:@"刪除" action:@selector(deletePressed:)];
    NSButton *refresh = [self button:@"重新整理" action:@selector(refreshPressed:)];
    NSButton *close = [self button:@"關閉" action:@selector(closePressed:)];
    close.keyEquivalent = @"\e";
    _status = [NSTextField labelWithString:@""];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.font = [NSFont systemFontOfSize:11];
    [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *bottom = [NSStackView stackViewWithViews:@[_open, _upload, _newFolder, _rename, _copy, _move, _delete, refresh, _status, spacer, close]];
    bottom.spacing = 6;

    for (NSView *v in @[top, _tableScroll, _iconScroll, bottom]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [top.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [top.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [_tableScroll.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:10],
        [_tableScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [_tableScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [_tableScroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-10],
        [_iconScroll.topAnchor constraintEqualToAnchor:_tableScroll.topAnchor],
        [_iconScroll.leadingAnchor constraintEqualToAnchor:_tableScroll.leadingAnchor],
        [_iconScroll.trailingAnchor constraintEqualToAnchor:_tableScroll.trailingAnchor],
        [_iconScroll.bottomAnchor constraintEqualToAnchor:_tableScroll.bottomAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [bottom.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [bottom.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
    ]];
    [self applyViewMode];
    [self updateSortIndicator];
}

- (void)applyViewMode {
    _tableScroll.hidden = _icons;
    _iconScroll.hidden = !_icons;
    [_view.itemArray[1] setState:_icons ? NSControlStateValueOff : NSControlStateValueOn];
    [_view.itemArray[2] setState:_icons ? NSControlStateValueOn : NSControlStateValueOff];
}

#pragma mark 資料

- (NSString *)folderPath:(NSString *)folderID { return _folders[folderID].path ?: N2L(@"根目錄"); }

- (N2CloudItem *)itemAtRow:(NSInteger)row {
    return row >= 0 && row < (NSInteger)_visible.count ? _visible[(NSUInteger)row] : nil;
}

- (N2CloudItem *)selected {
    if (_icons) {
        NSIndexPath *p = _collection.selectionIndexPaths.anyObject;
        return p ? [self itemAtRow:p.item] : nil;
    }
    return [self itemAtRow:_table.selectedRow];
}

- (BOOL)emptyFolder:(NSString *)folderID {
    for (N2CloudFolder *f in _folders.allValues) if ([f.parent isEqualToString:folderID]) return NO;
    for (N2CloudItem *r in _rows) if ([r.parent isEqualToString:folderID]) return NO;
    return YES;
}

static NSComparisonResult CompareText(NSString *a, NSString *b) {
    if (!a.length || !b.length) return !a.length ? (!b.length ? NSOrderedSame : NSOrderedAscending) : NSOrderedDescending;
    return [a localizedCaseInsensitiveCompare:b];
}

- (NSString *)typeOf:(N2CloudItem *)item { return item.isFolder ? N2L(@"資料夾") : N2L(@"X60 檔案"); }

// 依目前的搜尋、資料夾與排序重新顯示（只排列已下載的資料，不呼叫伺服器）
- (void)render:(NSString *)selectID {
    if (!selectID) selectID = self.selected.itemID;
    NSString *query = _search.stringValue;
    BOOL all = _searchAll.state == NSControlStateValueOn;
    NSMutableArray<N2CloudItem *> *visible = [NSMutableArray array];
    auto matches = [&](NSString *name) {
        return !query.length || [name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
    };
    for (N2CloudFolder *f in _folders.allValues) {
        if ([f.folderID isEqualToString:@"root"]) continue;
        if ((all || [f.parent isEqualToString:_folder]) && matches(f.name)) {
            N2CloudItem *it = [N2CloudItem new];
            it.isFolder = YES; it.itemID = f.folderID; it.name = f.name; it.parent = f.parent;
            [visible addObject:it];
        }
    }
    for (N2CloudItem *r in _rows)
        if ((all || [r.parent isEqualToString:_folder]) && matches(r.name)) [visible addObject:r];
    const int sort = _columns.sort;
    const bool ascending = _columns.ascending;
    [visible sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(N2CloudItem *a, N2CloudItem *b) {
        // 資料夾固定排在檔案前面（與 Windows 檔案總管相同）
        if (a.isFolder != b.isFolder) return a.isFolder ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult order = NSOrderedSame;
        switch (sort) {
            case 1: order = CompareText([self typeOf:a], [self typeOf:b]); break;
            case 2: if (!a.isFolder) order = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame; break;
            case 3: if (!a.isFolder) order = a.modified < b.modified ? NSOrderedAscending : a.modified > b.modified ? NSOrderedDescending : NSOrderedSame; break;
            case 4: order = CompareText([self folderPath:a.parent], [self folderPath:b.parent]); break;
            case 5: order = CompareText(a.isFolder ? @"" : @".x60", b.isFolder ? @"" : @".x60"); break;
            default: order = CompareText(a.name, b.name); break;
        }
        if (order != NSOrderedSame) return ascending ? order : (NSComparisonResult)-order;
        NSComparisonResult byName = CompareText(a.name, b.name);
        return byName != NSOrderedSame ? byName : [a.itemID compare:b.itemID];
    }];
    _visible = visible;
    [_table reloadData];
    [_collection reloadData];
    NSInteger restore = -1;
    for (NSUInteger i = 0; i < _visible.count; ++i) if ([_visible[i].itemID isEqualToString:selectID]) restore = (NSInteger)i;
    if (restore >= 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)restore] byExtendingSelection:NO];
        [_table scrollRowToVisible:restore];
        NSIndexPath *p = [NSIndexPath indexPathForItem:restore inSection:0];
        _collection.selectionIndexPaths = [NSSet setWithObject:p];
        [_collection scrollToItemsAtIndexPaths:[NSSet setWithObject:p] scrollPosition:NSCollectionViewScrollPositionNearestHorizontalEdge];
    } else {
        [_table deselectAll:nil];
        _collection.selectionIndexPaths = [NSSet set];
    }
    _status.stringValue = [NSString stringWithFormat:N2L(@"共 %lu 個項目"), (unsigned long)_visible.count];
    [self updateSortIndicator];
    [self enableButtons];
}

- (void)enableButtons {
    N2CloudItem *s = self.selected;
    BOOL ready = _loaded;
    _open.enabled = _rename.enabled = _move.enabled = s != nil;
    _copy.enabled = s && !s.isFolder;
    _delete.enabled = s && (!s.isFolder || [self emptyFolder:s.itemID]);
    _newFolder.enabled = _upload.enabled = ready;
    _up.enabled = ![_folder isEqualToString:@"root"];
}

- (void)updateBreadcrumb {
    NSMutableArray<N2CloudFolder *> *chain = [NSMutableArray array];
    for (N2CloudFolder *f = _folders[_folder]; f; f = _folders[f.parent]) {
        [chain insertObject:f atIndex:0];
        if ([f.folderID isEqualToString:@"root"]) break;
    }
    if (!chain.count) chain = [NSMutableArray arrayWithObject:_folders[@"root"] ?: [N2CloudFolder new]];
    NSMutableArray *items = [NSMutableArray array], *ids = [NSMutableArray array];
    for (N2CloudFolder *f in chain) {
        NSPathControlItem *it = [NSPathControlItem new];
        it.title = [f.folderID isEqualToString:@"root"] ? N2L(@"根目錄") : f.name;
        it.image = [NSImage imageNamed:NSImageNameFolder];
        [items addObject:it];
        [ids addObject:f.folderID ?: @"root"];
    }
    _path.pathItems = items;
    _pathIDs = ids;
}

- (NSImage *)iconFor:(N2CloudItem *)item {
    if (item.isFolder) return [NSImage imageNamed:NSImageNameFolder];
    // 依雲端儲存的語法顯示類型圖示（未指定時用 .x60 圖示）
    NSNumber *key = @(item.syntax);
    NSImage *cached = _syntaxIcons[key];
    if (cached) return cached;
    NSString *ext = @"x60";
    if (item.syntax > 0) {
        NSString *lang = N2LanguageForSyntaxResource(item.syntax, nil);
        static NSDictionary *exts = @{@"text": @"txt", @"c": @"c", @"objc": @"m", @"swift": @"swift", @"java": @"java",
            @"kotlin": @"kt", @"csharp": @"cs", @"js": @"js", @"ts": @"ts", @"json": @"json", @"python": @"py",
            @"php": @"php", @"html": @"html", @"xml": @"xml", @"css": @"css", @"sql": @"sql", @"bash": @"sh",
            @"batch": @"bat", @"ini": @"ini", @"markdown": @"md", @"makefile": @"mk", @"diff": @"diff"};
        if (lang && exts[lang]) ext = exts[lang];
    }
    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFileType:ext];
    _syntaxIcons[key] = icon;
    return icon;
}

static NSString *ModifiedText(uint64_t seconds) {
    if (seconds > 253402300799ull) return @"";
    static NSDateFormatter *f;
    if (!f) {
        f = [NSDateFormatter new];
        f.dateStyle = NSDateFormatterShortStyle;
        f.timeStyle = NSDateFormatterShortStyle;
    }
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)seconds]];
}

- (NSString *)cellText:(N2CloudItem *)item column:(NSInteger)column {
    BOOL all = _searchAll.state == NSControlStateValueOn;
    switch (column) {
        case 0: {
            BOOL pathShown = !_icons && (_columns.visible & (1u << 4));
            return all && !pathShown ? [NSString stringWithFormat:@"%@  ·  %@", item.name, [self folderPath:item.parent]] : item.name;
        }
        case 1: return [self typeOf:item];
        case 2: return item.isFolder ? @"" : [NSString stringWithUTF8String:formatFileSize(item.size).c_str()];
        case 3: return item.isFolder ? @"" : ModifiedText(item.modified);
        case 4: return [self folderPath:item.parent];
        case 5: return item.isFolder ? @"" : @".x60";
        default: return @"";
    }
}

#pragma mark 伺服器操作

- (BOOL)guarded:(void (^)(void))work {
    if (_busy) return NO;
    _busy = YES;
    BOOL ok = YES;
    try {
        work();
    } catch (const Issue &issue) {
        ShowIssue(issue);
        ok = NO;
    }
    _busy = NO;
    [self enableButtons];
    return ok;
}

- (void)refreshSelecting:(NSString *)selectID {
    NSString *q = [NSString stringWithFormat:@"list&all=1&sort=%s&order=%@", serverSort(_columns.sort), _columns.ascending ? @"asc" : @"desc"];
    NSDictionary *result = JsonResult(Request(_loc, q));
    N2CloudFolders *folders = ReadFolders(result);
    NSArray *values = result[@"files"];
    if (![values isKindOfClass:NSArray.class] || values.count > 10000) Fail(@"伺服器回應有誤或未完成操作。");
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:values.count];
    for (NSDictionary *o in values) {
        if (![o isKindOfClass:NSDictionary.class]) Fail(@"伺服器回應有誤或未完成操作。");
        N2CloudItem *r = [N2CloudItem new];
        r.itemID = String(o, @"id");
        r.name = String(o, @"name");
        r.parent = String(o, @"folder");
        r.size = Number(o, @"size_bytes");
        r.modified = Number(o, @"modified_at");
        id syntax = o[@"syntax"];
        r.syntax = [syntax isKindOfClass:NSNumber.class] && [syntax intValue] > 0 && [syntax intValue] <= 65535 ? [syntax intValue] : 0;
        if (!ValidId(r.itemID) || !ValidName(r.name) || !folders[r.parent]) Fail(@"伺服器回應有誤或未完成操作。");
        [rows addObject:r];
    }
    if (!selectID) selectID = self.selected.itemID;
    // 目前資料夾被刪除或搬走時，往上找還存在的資料夾
    while (!folders[_folder]) {
        N2CloudFolder *old = _folders[_folder];
        _folder = old && old.parent.length ? old.parent : @"root";
    }
    _rows = rows;
    _folders = folders;
    _loaded = YES;
    [self updateBreadcrumb];
    if (_updateTab) {
        for (N2CloudItem *r in _rows) {
            N2CloudFile *info = [N2CloudFile new];
            info.base = _loc.base; info.api = _loc.api;
            info.fileID = r.itemID; info.name = r.name; info.folder = r.parent;
            info.title = CloudTitle(r.name, [r.parent isEqualToString:@"root"] ? @"" : _folders[r.parent].path);
            _updateTab(info);
        }
    }
    [self render:selectID];
}

- (void)navigate:(NSString *)folder selecting:(NSString *)selectID {
    if (!_folders[folder]) return;
    _folder = folder;
    _searchAll.state = NSControlStateValueOff;
    _search.stringValue = @"";
    [self updateBreadcrumb];
    [self render:selectID ?: @""];
}

- (void)openItem:(N2CloudItem *)item {
    if (item.isFolder) { [self navigate:item.itemID selecting:@""]; return; }
    Reply r = Request(_loc, @"download", YES, Form([@"id=" stringByAppendingString:Encode(item.itemID)]), nil, cipherLimit);
    Verify(r);
    if (!ValidRevision(r.revision)) Fail(@"伺服器回應有誤或未完成操作。");
    if (!N2CloudCanSaveX60(r.body)) Fail(@"檔案內容不符合 X60 格式。");
    N2CloudFile *f = [N2CloudFile new];
    f.base = _loc.base; f.api = _loc.api;
    f.fileID = item.itemID; f.name = item.name; f.folder = item.parent;
    f.title = CloudTitle(item.name, [item.parent isEqualToString:@"root"] ? @"" : [self folderPath:item.parent]);
    f.revision = r.revision;
    f.payload = r.body;
    _opened = f;
    [self saveColumns];
    [NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)createFolderIn:(NSString *)parent {
    NSString *name = AskName(N2L(@"新增資料夾…"), @"", false);
    if (!name) return;
    NSDictionary *r = JsonResult(Request(_loc, @"folder_create", YES, Form([NSString stringWithFormat:@"parent=%@&name=%@", Encode(parent), Encode(name)])));
    NSDictionary *folder = r[@"folder"];
    if (![folder isKindOfClass:NSDictionary.class]) Fail(@"伺服器回應有誤或未完成操作。");
    NSString *fid = String(folder, @"id");
    if (!ValidId(fid)) Fail(@"伺服器回應有誤或未完成操作。");
    [self refreshSelecting:[parent isEqualToString:_folder] ? fid : parent];
}

- (void)renameItem:(N2CloudItem *)item {
    if (item.isFolder) {
        NSString *name = AskName(N2L(@"更名資料夾…"), item.name, false);
        if (!name || [name isEqualToString:item.name]) return;
        JsonResult(Request(_loc, @"folder_rename", YES, Form([NSString stringWithFormat:@"folder=%@&name=%@", Encode(item.itemID), Encode(name)])));
    } else {
        NSString *name = AskName(N2L(@"更名"), item.name, true);
        if (!name || [name isEqualToString:item.name]) return;
        JsonResult(Request(_loc, @"rename", YES, Form([NSString stringWithFormat:@"id=%@&new_name=%@", Encode(item.itemID), Encode(name)])));
    }
    [self refreshSelecting:item.itemID];
}

- (void)copyItem:(N2CloudItem *)item {
    if (item.isFolder) return;
    NSString *name = AskName(N2L(@"複製一份…"), item.name, true);
    if (!name) return;
    JsonResult(Request(_loc, @"copy", YES, Form([NSString stringWithFormat:@"id=%@&new_name=%@", Encode(item.itemID), Encode(name)])));
    [self refreshSelecting:item.itemID];
}

- (void)moveItem:(N2CloudItem *)item {
    if (item.isFolder) {
        NSString *destination = item.parent;
        while (PickFolder(N2L(@"搬移資料夾到…"), _folders, &destination, item.itemID)) {
            if ([destination isEqualToString:item.parent]) return;
            try {
                Reply r = Request(_loc, @"folder_move", YES, Form([NSString stringWithFormat:@"folder=%@&destination=%@", Encode(item.itemID), Encode(destination)]));
                if (r.status == 400) {
                    id o = [NSJSONSerialization JSONObjectWithData:r.body options:0 error:nil];
                    if ([o isKindOfClass:NSDictionary.class] && [o[@"error"] isEqual:@"invalid_function"]) Fail(@"請更新伺服器上的 Notepad2XS 雲端 PHP。");
                }
                JsonResult(r);
            } catch (const Issue &issue) {
                if (issue.status != 409 || ![issue.text isEqualToString:N2L(@"這個位置已有同名資料夾。")]) throw;
                N2CloudMessage(nil, N2L(@"目的地已有同名資料夾。請選其他位置，或先重新命名。"));
                continue;
            }
            [self refreshSelecting:item.itemID];
            return;
        }
        return;
    }
    Destination target;
    target.folder = item.parent;
    target.name = item.name;
    while (ChooseDestination(N2L(@"搬移檔案…"), _folders, target)) {
        if ([target.folder isEqualToString:item.parent] && [target.name isEqualToString:item.name]) return;
        try {
            NSDictionary *r = JsonResult(Request(_loc, @"move", YES, Form([NSString stringWithFormat:@"id=%@&destination=%@&new_name=%@",
                Encode(item.itemID), Encode(target.folder), Encode(target.name)])));
            if (_updateTab) _updateTab(MetadataFile(_loc, r));
        } catch (const Issue &issue) {
            if (issue.status != 409 || ![issue.text isEqualToString:N2L(@"雲端已有同名檔案。")]) throw;
            N2CloudMessage(nil, N2L(@"目的地已有同名檔案。請改名或選擇其他資料夾。"));
            continue;
        }
        [self refreshSelecting:item.itemID];
        return;
    }
}

- (void)deleteItem:(N2CloudItem *)item {
    if (item.isFolder) {
        if (![self emptyFolder:item.itemID]) { N2CloudMessage(nil, N2L(@"請先移出這個資料夾中的檔案與子資料夾。")); return; }
        if (!ConfirmDelete(N2L(@"刪除資料夾…"), N2L(@"確定要刪除這個資料夾嗎？"), [self folderPath:item.itemID])) return;
        JsonResult(Request(_loc, @"folder_delete", YES, Form([@"folder=" stringByAppendingString:Encode(item.itemID)])));
    } else {
        if (!ConfirmDelete(N2L(@"刪除"), N2L(@"要刪除這份雲端檔案嗎？"), [item.name stringByAppendingString:@".x60"])) return;
        JsonResult(Request(_loc, @"delete", YES, Form([@"id=" stringByAppendingString:Encode(item.itemID)])));
    }
    [self refreshSelecting:item.itemID];
}

- (void)showProperties:(N2CloudItem *)item {
    NSString *text = [NSString stringWithFormat:@"%@: %@\n%@: %@", N2L(@"檔名"), item.name, N2L(@"資料夾"), [self folderPath:item.parent]];
    if (!item.isFolder)
        text = [text stringByAppendingFormat:@"\n%@: %@\n%@: %llu B", N2L(@"最後修改時間"), ModifiedText(item.modified), N2L(@"大小"), item.size];
    ShowText(N2L(@"屬性"), text);
}

- (void)uploadLocal {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedFileTypes = @[@"x60"];
    p.allowsMultipleSelection = NO;
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    NSURL *url = p.URL;
    if (!HasX60Extension(url.lastPathComponent)) Fail(@"檔案內容不符合 X60 格式。");
    NSData *bytes = ReadX60(url);
    Destination target;
    target.folder = _folder;
    target.name = url.lastPathComponent.stringByDeletingPathExtension;
    while (ChooseDestination(N2L(@"上傳"), _folders, target)) {
        N2CloudFile *saved = nil;
        SaveOutcome outcome = SaveNewTarget(N2L(@"上傳"), _loc, target, bytes, nil, nil, &saved);
        if (outcome == SaveOutcome::Retry) continue;
        if (outcome == SaveOutcome::Saved) [self refreshSelecting:saved.fileID];
        return;
    }
}

// 拖曳上傳單一檔案：同名時可「更名／覆蓋／跳過」；回傳上傳後的檔名（跳過回傳 nil）
- (NSString *)uploadDroppedFile:(NSURL *)url folder:(NSString *)folder {
    NSString *leaf = url.lastPathComponent;
    if (!HasX60Extension(leaf)) Fail(@"檔案內容不符合 X60 格式。");
    NSData *bytes = ReadX60(url);
    NSString *name = leaf.stringByDeletingPathExtension;
    if (!ValidName(name)) name = AskName(N2L(@"上傳"), @"", true);
    while (name.length) {
        NSString *query = NamedQuery(folder, name);
        try {
            N2CloudFile *saved = MetadataFile(_loc, Upload(_loc, query, nil, bytes));
            return [saved.name stringByAppendingString:@".x60"];
        } catch (const Issue &issue) {
            if (issue.status != 409 || ![issue.text isEqualToString:N2L(@"雲端已有同名檔案。")]) throw;
        }
        N2CloudFile *current = MetadataFile(_loc, JsonResult(Request(_loc, [@"stat&" stringByAppendingString:query])));
        N2CloudForm *f = [N2CloudForm formWithTitle:N2L(@"上傳")];
        [f addText:[NSString stringWithFormat:@"%@\n\n%@", N2L(@"目的地已有同名檔案。請選擇如何處理。"), current.title]];
        [f addButton:N2L(@"跳過") code:3 key:@"\r"];
        [f addButton:N2L(@"覆蓋") code:2 key:nil];
        [f addButton:N2L(@"更名") code:1 key:nil];
        NSInteger action = [f run];
        if (action == 1) { name = AskName(N2L(@"更名"), name, true); continue; }
        if (action != 2) return nil;
        N2CloudFile *saved = MetadataFile(_loc, Upload(_loc, query, current.revision, bytes));
        if (![saved.fileID isEqualToString:current.fileID]) Fail(@"伺服器回應有誤或未完成操作。");
        return [saved.name stringByAppendingString:@".x60"];
    }
    return nil;
}

- (void)uploadDropped:(NSArray<NSURL *> *)urls toFolder:(NSString *)folder {
    if (_busy || !_loaded || !urls.count) return;
    _busy = YES;
    NSString *destination = folder ?: _folder;
    if (_searchAll.state == NSControlStateValueOn &&
        !PickFolder(N2L(@"確認上傳位置"), _folders, &destination, nil)) { _busy = NO; return; }
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@  %@\n\n", N2L(@"資料夾"), [self folderPath:destination]];
    NSUInteger uploaded = 0, failed = 0, skipped = 0;
    for (NSURL *url in urls) {
        try {
            NSString *saved = [self uploadDroppedFile:url folder:destination];
            if (saved) { ++uploaded; [detail appendFormat:@"%@  %@\n", N2L(@"已上傳"), saved]; }
            else { ++skipped; [detail appendFormat:@"%@  %@\n", N2L(@"已跳過"), url.lastPathComponent]; }
        } catch (const Issue &issue) {
            ++failed;
            [detail appendFormat:@"%@  %@  ·  %@\n", N2L(@"失敗"), url.lastPathComponent, issue.text];
        }
    }
    if (uploaded) {
        try { [self refreshSelecting:nil]; } catch (const Issue &issue) { ShowIssue(issue); }
    }
    _busy = NO;
    NSString *counts = [NSString stringWithFormat:@"%@ %lu     %@ %lu     %@ %lu", N2L(@"已上傳"), (unsigned long)uploaded,
                        N2L(@"失敗"), (unsigned long)failed, N2L(@"已跳過"), (unsigned long)skipped];
    ShowText(N2L(@"上傳結果"), [NSString stringWithFormat:@"%@\n\n%@", counts, detail]);
    [self enableButtons];
}

#pragma mark 按鈕與選單

- (void)perform:(void (^)(N2CloudItem *item))action needsItem:(BOOL)needsItem {
    N2CloudItem *item = self.selected;
    if (needsItem && !item) return;
    [self guarded:^{ action(item); }];
}

- (void)openSelected { [self perform:^(N2CloudItem *it) { [self openItem:it]; } needsItem:YES]; }
- (IBAction)openPressed:(id)sender { [self openSelected]; }
- (IBAction)tableDoubleClick:(id)sender { if (_table.clickedRow >= 0) [self openSelected]; }
- (IBAction)renamePressed:(id)sender { [self perform:^(N2CloudItem *it) { [self renameItem:it]; } needsItem:YES]; }
- (IBAction)copyPressed:(id)sender { [self perform:^(N2CloudItem *it) { [self copyItem:it]; } needsItem:YES]; }
- (IBAction)movePressed:(id)sender { [self perform:^(N2CloudItem *it) { [self moveItem:it]; } needsItem:YES]; }
- (IBAction)deletePressed:(id)sender { [self perform:^(N2CloudItem *it) { [self deleteItem:it]; } needsItem:YES]; }
- (IBAction)propertiesPressed:(id)sender { [self perform:^(N2CloudItem *it) { [self showProperties:it]; } needsItem:YES]; }
- (IBAction)newFolderPressed:(id)sender { if (_loaded) [self guarded:^{ [self createFolderIn:self->_folder]; }]; }
- (IBAction)newChildFolderPressed:(id)sender {
    [self perform:^(N2CloudItem *it) { if (it.isFolder) [self createFolderIn:it.itemID]; } needsItem:YES];
}
- (IBAction)uploadPressed:(id)sender { if (_loaded) [self guarded:^{ [self uploadLocal]; }]; }
- (IBAction)refreshPressed:(id)sender { [self guarded:^{ [self refreshSelecting:nil]; }]; }
- (IBAction)openLocationPressed:(id)sender {
    N2CloudItem *it = self.selected;
    if (it) [self navigate:it.parent selecting:it.itemID];
}
- (IBAction)goUp:(id)sender {
    if (_busy || [_folder isEqualToString:@"root"]) return;
    NSString *child = _folder;
    [self navigate:_folders[_folder].parent ?: @"root" selecting:child];
}
- (IBAction)closePressed:(id)sender { [self saveColumns]; [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (BOOL)windowShouldClose:(NSWindow *)w { [self closePressed:nil]; return NO; }
- (IBAction)pathClicked:(id)sender {
    NSPathControlItem *clicked = _path.clickedPathItem;
    NSUInteger i = clicked ? [_path.pathItems indexOfObject:clicked] : NSNotFound;
    if (i != NSNotFound && i < _pathIDs.count && !_busy) [self navigate:_pathIDs[i] selecting:@""];
}
- (IBAction)searchChanged:(id)sender { if (!_busy) [self render:nil]; }
- (void)controlTextDidChange:(NSNotification *)n { if (n.object == _search && !_busy) [self render:nil]; }

- (void)setIcons:(BOOL)icons {
    if (icons == _icons) return;
    NSString *selected = self.selected.itemID;
    _icons = icons;
    [self applyViewMode];
    [NSUserDefaults.standardUserDefaults setObject:icons ? @"Icons" : @"Details" forKey:kCloudViewKey];
    [self render:selected];
    [_panel makeFirstResponder:icons ? (NSView *)_collection : (NSView *)_table];
}
- (IBAction)showDetails:(id)sender { [self setIcons:NO]; }
- (IBAction)showIcons:(id)sender { [self setIcons:YES]; }

- (IBAction)sortPressed:(NSMenuItem *)sender {
    if (sender.tag >= 100) _columns.ascending = sender.tag == 100;
    else if (sender.tag != _columns.sort) { _columns.sort = (int)sender.tag; _columns.ascending = sender.tag != 2 && sender.tag != 3; }
    [self saveSort];
    [self render:nil];
}

- (NSMenuItem *)item:(NSMenu *)m title:(NSString *)zh action:(SEL)action key:(NSString *)key enabled:(BOOL)enabled {
    NSMenuItem *it = [m addItemWithTitle:N2L(zh) action:action keyEquivalent:key ?: @""];
    if (key.length) it.keyEquivalentModifierMask = 0;
    it.target = self;
    it.enabled = enabled;
    return it;
}

- (NSMenu *)menuForItem:(N2CloudItem *)item {
    if (_busy || !_loaded) return nil;
    NSMenu *m = [NSMenu new];
    m.autoenablesItems = NO;
    if (item) {
        [self item:m title:@"開啟" action:@selector(openPressed:) key:nil enabled:YES];
        if (_searchAll.state == NSControlStateValueOn) [self item:m title:@"開啟所在資料夾" action:@selector(openLocationPressed:) key:nil enabled:YES];
        [m addItem:NSMenuItem.separatorItem];
        if (item.isFolder) [self item:m title:@"新增子資料夾…" action:@selector(newChildFolderPressed:) key:nil enabled:YES];
        else [self item:m title:@"複製一份…" action:@selector(copyPressed:) key:nil enabled:YES];
        [self item:m title:@"搬移到…" action:@selector(movePressed:) key:nil enabled:YES];
        NSString *f2 = [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey];
        [self item:m title:item.isFolder ? @"更名資料夾…" : @"更名" action:@selector(renamePressed:) key:f2 enabled:YES];
        [m addItem:NSMenuItem.separatorItem];
        [self item:m title:item.isFolder ? @"刪除資料夾…" : @"刪除" action:@selector(deletePressed:) key:nil
           enabled:!item.isFolder || [self emptyFolder:item.itemID]];
        [m addItem:NSMenuItem.separatorItem];
        [self item:m title:@"屬性" action:@selector(propertiesPressed:) key:nil enabled:YES];
    } else {
        [self item:m title:@"新增資料夾…" action:@selector(newFolderPressed:) key:nil enabled:YES];
        NSString *f5 = [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey];
        [self item:m title:@"重新整理" action:@selector(refreshPressed:) key:f5 enabled:YES];
        NSMenuItem *sortItem = [m addItemWithTitle:N2L(@"排序方式") action:nil keyEquivalent:@""];
        NSMenu *sort = [NSMenu new];
        sort.autoenablesItems = NO;
        for (NSInteger i = 0; i < (NSInteger)columnCount; ++i) {
            NSMenuItem *it = [sort addItemWithTitle:ColumnTitle(i) action:@selector(sortPressed:) keyEquivalent:@""];
            it.target = self; it.tag = i;
            it.state = i == _columns.sort ? NSControlStateValueOn : NSControlStateValueOff;
        }
        [sort addItem:NSMenuItem.separatorItem];
        for (NSInteger dir = 0; dir < 2; ++dir) {
            NSMenuItem *it = [sort addItemWithTitle:N2L(dir == 0 ? @"遞增" : @"遞減") action:@selector(sortPressed:) keyEquivalent:@""];
            it.target = self; it.tag = 100 + dir;
            it.state = (dir == 0) == _columns.ascending ? NSControlStateValueOn : NSControlStateValueOff;
        }
        sortItem.submenu = sort;
    }
    return m;
}

- (BOOL)handleKey:(NSEvent *)e {
    if (_busy) return YES;
    NSString *ch = e.charactersIgnoringModifiers;
    unichar c = ch.length ? [ch characterAtIndex:0] : 0;
    NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (c == NSF5FunctionKey) { [self refreshPressed:nil]; return YES; }
    if (c == NSF2FunctionKey) { [self renamePressed:nil]; return YES; }
    if (c == NSUpArrowFunctionKey && (mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand))) { [self goUp:nil]; return YES; }
    if ((c == NSDeleteCharacter || c == NSDeleteFunctionKey || c == NSBackspaceCharacter) && self.selected) { [self deletePressed:nil]; return YES; }
    if ((c == '\r' || c == 3) && self.selected) { [self openSelected]; return YES; }
    return NO;
}

#pragma mark 欄位（顯示／隱藏、順序、寬度、排序）

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _table.headerView.menu) return;
    [menu removeAllItems];
    [menu addItemWithTitle:N2L(@"欄位") action:nil keyEquivalent:@""].enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    for (NSInteger i = 0; i < (NSInteger)columnCount; ++i) {
        NSMenuItem *it = [menu addItemWithTitle:ColumnTitle(i) action:i ? @selector(toggleColumn:) : nil keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.state = (_columns.visible & (1u << i)) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleColumn:)) return item.tag != 0;   // 名稱欄固定顯示
    return YES;
}

- (IBAction)toggleColumn:(NSMenuItem *)sender {
    if (sender.tag <= 0 || sender.tag >= (NSInteger)columnCount) return;
    NSTableColumn *c = [_table tableColumnWithIdentifier:[NSString stringWithFormat:@"%ld", (long)sender.tag]];
    c.hidden = !c.hidden;
    [self saveColumns];
    [self render:nil];   // 「搜尋所有資料夾」時，路徑欄隱藏後改在名稱後顯示位置
}

- (void)columnsChanged:(NSNotification *)n { if (_panel.isVisible) [self saveColumns]; }

- (void)saveColumns {
    unsigned visible = 1u;
    std::array<int, columnCount> order{};
    size_t i = 0;
    for (NSTableColumn *c in _table.tableColumns) {
        const int index = c.identifier.intValue;
        if (i < columnCount) order[i++] = index;
        if (!c.hidden) visible |= 1u << index;
        _columns.widths[(size_t)index] = std::clamp((int)lround(c.width), 32, 1200);
    }
    if (i == columnCount) _columns.order = order;
    _columns.visible = visible;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:_columns.visible forKey:kCloudColumnsVisibleKey];
    [d setObject:[NSString stringWithUTF8String:integerList(_columns.order).c_str()] forKey:kCloudColumnsOrderKey];
    [d setObject:[NSString stringWithUTF8String:integerList(_columns.widths).c_str()] forKey:kCloudColumnsWidthsKey];
}

- (void)saveSort {
    [NSUserDefaults.standardUserDefaults setInteger:_columns.sort forKey:kCloudSortKey];
    [NSUserDefaults.standardUserDefaults setBool:_columns.ascending forKey:kCloudSortAscendingKey];
}

- (void)updateSortIndicator {
    for (NSTableColumn *c in _table.tableColumns) {
        NSImage *image = nil;
        if (c.identifier.intValue == _columns.sort)
            image = [NSImage imageNamed:_columns.ascending ? @"NSAscendingSortIndicator" : @"NSDescendingSortIndicator"];
        [_table setIndicatorImage:image inTableColumn:c];
    }
}

- (void)tableView:(NSTableView *)t didClickTableColumn:(NSTableColumn *)c {
    if (_busy) return;
    clickSort(_columns, c.identifier.intValue);
    [self saveSort];
    [self render:nil];
}

#pragma mark 表格資料

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)_visible.count; }

- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    N2CloudItem *it = [self itemAtRow:row];
    return it ? [self cellText:it column:c.identifier.integerValue] : @"";
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSInteger column = c.identifier.integerValue;
    NSString *ident = column == 0 ? @"name" : @"text";
    NSTableCellView *cell = [t makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = ident;
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:text];
        cell.textField = text;
        if (column == 0) {
            NSImageView *image = [NSImageView new];
            image.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:image];
            cell.imageView = image;
            [NSLayoutConstraint activateConstraints:@[
                [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [image.widthAnchor constraintEqualToConstant:16],
                [image.heightAnchor constraintEqualToConstant:16],
                [text.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:5],
            ]];
        } else {
            [text.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2].active = YES;
        }
        [NSLayoutConstraint activateConstraints:@[
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    N2CloudItem *it = [self itemAtRow:row];
    cell.textField.stringValue = it ? [self cellText:it column:column] : @"";
    cell.textField.alignment = column == 2 ? NSTextAlignmentRight : NSTextAlignmentLeft;
    if (column == 0) cell.imageView.image = it ? [self iconFor:it] : nil;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n { [self enableButtons]; }

- (NSDragOperation)validateDropFor:(NSArray<NSURL *> *)urls {
    return !_busy && _loaded && urls.count ? NSDragOperationCopy : NSDragOperationNone;
}

static NSArray<NSURL *> *DroppedURLs(id<NSDraggingInfo> info) {
    return [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}

- (NSDragOperation)tableView:(NSTableView *)t validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
    N2CloudItem *it = [self itemAtRow:row];
    if (!(it && it.isFolder && op == NSTableViewDropOn)) [t setDropRow:-1 dropOperation:NSTableViewDropOn];
    return [self validateDropFor:DroppedURLs(info)];
}

- (BOOL)tableView:(NSTableView *)t acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
    N2CloudItem *it = op == NSTableViewDropOn ? [self itemAtRow:row] : nil;
    NSArray *urls = DroppedURLs(info);
    NSString *folder = it.isFolder ? it.itemID : nil;
    // 拖放結束後再處理（拖放期間不要開啟對話框）
    dispatch_async(dispatch_get_main_queue(), ^{ [self uploadDropped:urls toFolder:folder]; });
    return urls.count > 0;
}

#pragma mark 圖示資料

- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)section { return (NSInteger)_visible.count; }

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)p {
    N2CloudIconItem *item = [cv makeItemWithIdentifier:@"icon" forIndexPath:p];
    N2CloudItem *it = [self itemAtRow:p.item];
    item.textField.stringValue = it ? [self cellText:it column:0] : @"";
    item.imageView.image = it ? [self iconFor:it] : nil;
    item.selected = [cv.selectionIndexPaths containsObject:p];
    return item;
}

- (void)collectionView:(NSCollectionView *)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths { [self enableButtons]; }
- (void)collectionView:(NSCollectionView *)cv didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths { [self enableButtons]; }

- (NSDragOperation)collectionView:(NSCollectionView *)cv validateDrop:(id<NSDraggingInfo>)info
                proposedIndexPath:(NSIndexPath **)path dropOperation:(NSCollectionViewDropOperation *)op {
    N2CloudItem *it = path && *path ? [self itemAtRow:(*path).item] : nil;
    if (!(it.isFolder && *op == NSCollectionViewDropOn)) *op = NSCollectionViewDropBefore;
    return [self validateDropFor:DroppedURLs(info)];
}

- (BOOL)collectionView:(NSCollectionView *)cv acceptDrop:(id<NSDraggingInfo>)info indexPath:(NSIndexPath *)path
         dropOperation:(NSCollectionViewDropOperation)op {
    N2CloudItem *it = op == NSCollectionViewDropOn ? [self itemAtRow:path.item] : nil;
    NSArray *urls = DroppedURLs(info);
    NSString *folder = it.isFolder ? it.itemID : nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [self uploadDropped:urls toFolder:folder]; });
    return urls.count > 0;
}

#pragma mark 執行

- (N2CloudFile *)run {
    [_panel center];
    [self enableButtons];
    // 視窗出現後再讀取清單（失敗時仍可在視窗中按「重新整理」）
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshPressed:nil]; });
    [NSApp runModalForWindow:_panel];
    [_panel orderOut:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    return _opened;
}
@end

N2CloudFile *N2CloudBrowse(NSWindow *parent, void (^updateTab)(N2CloudFile *)) {
    try {
        Location loc = LocationFor(N2CloudConfiguredBase());
        N2CloudBrowser *b = [[N2CloudBrowser alloc] initWithLocation:loc];
        b->_updateTab = updateTab;
        return [b run];
    } catch (const Issue &issue) {
        ShowIssue(issue);
    }
    return nil;
}
