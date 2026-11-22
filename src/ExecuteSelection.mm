// F5 執行選取（macOS 版）與中文金額
// 辨識順序與 Windows 版相同：腳本 → SSH → FTP → HTTP(S) → 路徑 → WQL／系統資訊 → SQL → 數學
#import "EditorWindowController.h"
#import "N2Common.h"
#import "Document.h"
#import "ResultWindow.h"
#import "ScintillaView.h"
#include "SqlSelection.h"
#include "SqlResults.h"
#include "ChineseMoney.h"
#include "ExecuteCore.h"
#include <chrono>
#include <dlfcn.h>


static NSString *RandomName(NSString *suffix) {
    return [NSString stringWithFormat:@"%u%@", arc4random_uniform(900000000) + 100000000, suffix];
}
static NSString *ShellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

#pragma mark - ODBC（動態載入 unixODBC／iODBC；使用 UTF-8 的窄字元 API）

namespace {
typedef short SQLRETURN; typedef void *SQLHANDLE; typedef short SQLSMALLINT; typedef unsigned short SQLUSMALLINT;
typedef long SQLLEN; typedef unsigned long SQLULEN; typedef int SQLINTEGER;
const SQLSMALLINT kEnv = 1, kDbc = 2, kStmt = 3;
const SQLSMALLINT kCChar = 1, kCBinary = -2;
const SQLLEN kNullData = -1, kNoTotal = -4;
inline bool Ok(SQLRETURN r) { return r == 0 || r == 1; }

struct Odbc {
    void *lib = nullptr;
    SQLRETURN (*AllocHandle)(SQLSMALLINT, SQLHANDLE, SQLHANDLE *);
    SQLRETURN (*FreeHandle)(SQLSMALLINT, SQLHANDLE);
    SQLRETURN (*SetEnvAttr)(SQLHANDLE, SQLINTEGER, void *, SQLINTEGER);
    SQLRETURN (*DataSources)(SQLHANDLE, SQLUSMALLINT, unsigned char *, SQLSMALLINT, SQLSMALLINT *, unsigned char *, SQLSMALLINT, SQLSMALLINT *);
    SQLRETURN (*DriverConnect)(SQLHANDLE, void *, unsigned char *, SQLSMALLINT, unsigned char *, SQLSMALLINT, SQLSMALLINT *, SQLUSMALLINT);
    SQLRETURN (*Disconnect)(SQLHANDLE);
    SQLRETURN (*Prepare)(SQLHANDLE, unsigned char *, SQLINTEGER);
    SQLRETURN (*Execute)(SQLHANDLE);
    SQLRETURN (*NumResultCols)(SQLHANDLE, SQLSMALLINT *);
    SQLRETURN (*DescribeCol)(SQLHANDLE, SQLUSMALLINT, unsigned char *, SQLSMALLINT, SQLSMALLINT *, SQLSMALLINT *, SQLULEN *, SQLSMALLINT *, SQLSMALLINT *);
    SQLRETURN (*Fetch)(SQLHANDLE);
    SQLRETURN (*GetData)(SQLHANDLE, SQLUSMALLINT, SQLSMALLINT, void *, SQLLEN, SQLLEN *);
    SQLRETURN (*RowCount)(SQLHANDLE, SQLLEN *);
    SQLRETURN (*MoreResults)(SQLHANDLE);
    SQLRETURN (*GetDiagRec)(SQLSMALLINT, SQLHANDLE, SQLSMALLINT, unsigned char *, SQLINTEGER *, unsigned char *, SQLSMALLINT, SQLSMALLINT *);

    bool load() {
        for (const char *p : {"/opt/homebrew/lib/libodbc.2.dylib", "/usr/local/lib/libodbc.2.dylib",
                              "/opt/homebrew/opt/unixodbc/lib/libodbc.2.dylib", "/usr/local/opt/unixodbc/lib/libodbc.2.dylib",
                              "/opt/homebrew/lib/libiodbc.2.dylib", "/usr/local/lib/libiodbc.2.dylib", "/usr/lib/libiodbc.2.dylib"}) {
            if ((lib = dlopen(p, RTLD_NOW | RTLD_LOCAL))) break;
        }
        if (!lib) return false;
#define SYM(name) *(void **)&name = dlsym(lib, "SQL" #name); if (!name) return false;
        SYM(AllocHandle) SYM(FreeHandle) SYM(SetEnvAttr) SYM(DataSources) SYM(DriverConnect) SYM(Disconnect)
        SYM(Prepare) SYM(Execute) SYM(NumResultCols) SYM(DescribeCol) SYM(Fetch) SYM(GetData) SYM(RowCount)
        SYM(MoreResults) SYM(GetDiagRec)
#undef SYM
        return true;
    }
    std::string diag(SQLSMALLINT type, SQLHANDLE h) {
        std::string out;
        unsigned char state[8], msg[1024];
        SQLINTEGER native = 0;
        SQLSMALLINT len = 0;
        for (SQLSMALLINT i = 1; i <= 5 && Ok(GetDiagRec(type, h, i, state, &native, msg, sizeof msg, &len)); i++) {
            out += "[" + std::string((char *)state, 5) + "] " + std::string((char *)msg) + " (" + std::to_string(native) + ")\n";
        }
        return out;
    }
};
}

static std::u16string Now16() {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return N2ToU16([f stringFromDate:NSDate.date]);
}

// 在背景執行 SQL，結果放進 SqlReport（自動提交，與 Windows 版相同）
static xs::SqlReport RunSql(const xs::SqlSelection &sel) {
    xs::SqlReport report;
    report.dsn = sel.dsn;
    report.started = Now16();
    auto t0 = std::chrono::steady_clock::now();
    Odbc odbc;
    if (!odbc.load()) {
        report.notes = u8"找不到 ODBC 驅動管理員（iODBC／unixODBC）。請安裝後再執行。";
        return report;
    }
    SQLHANDLE env = nullptr, dbc = nullptr, stmt = nullptr;
    odbc.AllocHandle(kEnv, nullptr, &env);
    odbc.SetEnvAttr(env, 200 /*SQL_ATTR_ODBC_VERSION*/, (void *)3, 0);
    std::string dsn = xs::sqlUtf8(sel.dsn);
    // 先確認 DSN 存在
    bool found = false;
    unsigned char name[256], desc[512];
    SQLSMALLINT nl = 0, dl = 0;
    for (SQLUSMALLINT dir = 2 /*SQL_FETCH_FIRST*/; Ok(odbc.DataSources(env, dir, name, sizeof name, &nl, desc, sizeof desc, &dl)); dir = 1) {
        if (dsn == std::string((char *)name, (size_t)nl)) { found = true; break; }
    }
    if (!found) {
        report.notes = u8"找不到名稱為「" + dsn + u8"」的 ODBC 資料來源（DSN）。\n"
                       u8"macOS 內建 iODBC：請先安裝對應的資料庫 ODBC 驅動，再於 ~/Library/ODBC/odbc.ini（使用者）"
                       u8"或 /Library/ODBC/odbc.ini（系統）設定 DSN。";
        odbc.FreeHandle(kEnv, env);
        return report;
    }
    odbc.AllocHandle(kDbc, env, &dbc);
    std::string conn = "DSN=" + dsn + ";";
    SQLRETURN r = odbc.DriverConnect(dbc, nullptr, (unsigned char *)conn.c_str(), (SQLSMALLINT)conn.size(), nullptr, 0, nullptr, 0 /*NOPROMPT*/);
    if (!Ok(r)) {
        report.notes = u8"連線失敗：\n" + odbc.diag(kDbc, dbc);
    } else {
        odbc.AllocHandle(kStmt, dbc, &stmt);
        std::string sql = xs::sqlUtf8(sel.statement);
        report.submitted = true;
        r = odbc.Prepare(stmt, (unsigned char *)sql.c_str(), (SQLINTEGER)sql.size());
        if (Ok(r)) r = odbc.Execute(stmt);
        if (!Ok(r) && r != 100 /*NO_DATA*/) {
            report.notes = u8"執行失敗：\n" + odbc.diag(kStmt, stmt);
        } else {
            report.executed = true;
            report.status = xs::SqlResultStatus::Success;
            int sets = 0;
            do {
                if (++sets > 64) break;
                SQLSMALLINT cols = 0;
                odbc.NumResultCols(stmt, &cols);
                if (cols <= 0) {
                    SQLLEN count = -1;
                    odbc.RowCount(stmt, &count);
                    report.addAffected(count >= 0 ? std::optional<std::int64_t>(count) : std::nullopt);
                    continue;
                }
                cols = std::min<SQLSMALLINT>(cols, 256);
                std::vector<std::u16string> names;
                std::vector<bool> binary;
                for (SQLUSMALLINT c = 1; c <= (SQLUSMALLINT)cols; c++) {
                    unsigned char cn[512]; SQLSMALLINT cl = 0, type = 0, dec = 0, nullable = 0; SQLULEN size = 0;
                    odbc.DescribeCol(stmt, c, cn, sizeof cn, &cl, &type, &size, &dec, &nullable);
                    names.push_back(N2ToU16(N2FromUTF8(std::string((char *)cn, (size_t)std::min<SQLSMALLINT>(cl, 511)))));
                    binary.push_back(type == -2 || type == -3 || type == -4);
                }
                if (!report.beginTable(names)) break;
                while (Ok(odbc.Fetch(stmt))) {
                    if (report.rowCount >= 10000) { report.status = xs::SqlResultStatus::Truncated; break; }
                    std::vector<xs::SqlCell> row;
                    for (SQLUSMALLINT c = 1; c <= (SQLUSMALLINT)cols; c++) {
                        std::string data;
                        char buf[8192];
                        SQLLEN ind = 0;
                        bool isNull = false;
                        for (;;) {
                            SQLRETURN g = odbc.GetData(stmt, c, binary[c - 1] ? kCBinary : kCChar, buf, sizeof buf, &ind);
                            if (g == 100 || !Ok(g)) break;
                            if (ind == kNullData) { isNull = true; break; }
                            size_t got = binary[c - 1] ? ((ind == kNoTotal || ind > (SQLLEN)sizeof buf) ? sizeof buf : (size_t)ind)
                                                       : ((ind == kNoTotal || ind >= (SQLLEN)sizeof buf) ? sizeof buf - 1 : (size_t)ind);
                            data.append(buf, got);
                            if (g == 0) break;   // SQL_SUCCESS：讀完
                        }
                        xs::SqlCell cell;
                        if (isNull) cell.kind = xs::SqlCellKind::Null;
                        else if (binary[c - 1]) {
                            cell.kind = xs::SqlCellKind::Binary;
                            static const char *hx = "0123456789ABCDEF";
                            std::u16string h;
                            for (unsigned char b : data) { h += (char16_t)hx[b >> 4]; h += (char16_t)hx[b & 15]; }
                            cell.text = h;
                        } else cell.text = N2ToU16(N2FromUTF8(data));
                        row.push_back(std::move(cell));
                    }
                    if (!report.appendRow(std::move(row))) { report.status = xs::SqlResultStatus::Truncated; break; }
                    report.rowCount++;
                }
            } while (Ok(odbc.MoreResults(stmt)));
        }
    }
    if (stmt) odbc.FreeHandle(kStmt, stmt);
    if (dbc) { odbc.Disconnect(dbc); odbc.FreeHandle(kDbc, dbc); }
    odbc.FreeHandle(kEnv, env);
    report.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    return report;
}

#pragma mark - 系統資訊（取代 Windows 的 WQL）

static xs::SqlReport RunSysInfo(NSString *dataType) {
    xs::SqlReport report;
    report.title = u"系統資訊查詢結果";
    report.sourceLabel = u"資料類型";
    report.exportPrefix = u"sysinfo";
    report.dsn = N2ToU16(dataType);
    report.started = Now16();
    auto t0 = std::chrono::steady_clock::now();
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/system_profiler"];
    t.arguments = @[@"-json", @"-detailLevel", @"mini", dataType];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) { report.notes = u8"無法執行 system_profiler。"; return report; }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *items = [json isKindOfClass:NSDictionary.class] ? json[dataType] : nil;
    if (![items isKindOfClass:NSArray.class]) {
        report.notes = u8"查不到這個資料類型。可用類型可在終端機執行：system_profiler -listDataTypes";
        return report;
    }
    NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *it in items) if ([it isKindOfClass:NSDictionary.class]) [keys addObjectsFromArray:it.allKeys];
    std::vector<std::u16string> cols;
    for (NSString *k in keys) cols.push_back(N2ToU16(k));
    report.beginTable(cols);
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:NSDictionary.class]) continue;
        std::vector<xs::SqlCell> row;
        for (NSString *k in keys) {
            id v = it[k];
            xs::SqlCell cell;
            if (!v) cell.kind = xs::SqlCellKind::Null;
            else if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) cell.text = N2ToU16([v description]);
            else {
                NSData *d = [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingSortedKeys error:nil];
                cell.text = N2ToU16([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [v description]);
            }
            row.push_back(cell);
        }
        if (report.appendRow(std::move(row))) report.rowCount++;
    }
    report.status = xs::SqlResultStatus::Success;
    report.executed = true;
    report.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    return report;
}

#pragma mark - 指令

@implementation EditorWindowController (Execute)

- (void)fail:(NSString *)message { [self showMessage:message info:nil]; }

// 標記在第一行（允許 BOM 與兩側空白），回傳其後的內容
static NSString *MarkedBody(NSString *text, NSString *marker) {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"﻿"]];
    NSRange nl = [t rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    NSString *first = nl.location == NSNotFound ? t : [t substringToIndex:nl.location];
    if ([[first stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] caseInsensitiveCompare:marker] != NSOrderedSame) return nil;
    return nl.location == NSNotFound ? @"" : [t substringFromIndex:NSMaxRange(nl)];
}

- (NSString *)workingDirectory {
    NSURL *u = self.doc.fileURL;
    if (u && !N2IsArchiveWorkURL(u)) return u.URLByDeletingLastPathComponent.path;
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory();
}

// 在「終端機」執行：腳本與外層 runner 都保存在 logs 資料夾，結束後顯示結束代碼並等待 Enter
- (void)runInTerminal:(NSString *)command {
    NSString *runner = [N2LogsDirectory() stringByAppendingPathComponent:RandomName(@"_script_runner.command")];
    NSString *body = [NSString stringWithFormat:
        @"#!/bin/zsh\ncd %@ 2>/dev/null\n%@\ncode=$?\necho\nif [ $code -eq 0 ]; then echo \"結束代碼：0\"; else echo \"結束代碼：$code（失敗）\"; fi\n"
        @"read -r \"?按 Enter 關閉…\"\n", ShellQuote(self.workingDirectory), command];
    if (![body writeToFile:runner atomically:YES encoding:NSUTF8StringEncoding error:nil]) { [self fail:@"無法建立執行檔，請檢查磁碟空間。"]; return; }
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0700} ofItemAtPath:runner error:nil];
    NSURL *terminal = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"];
    [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:runner]] withApplicationAtURL:terminal
                            configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)runScript:(NSString *)body interpreter:(NSString *)interp args:(NSString *)args ext:(NSString *)ext {
    NSString *script = [N2LogsDirectory() stringByAppendingPathComponent:RandomName(ext)];
    NSString *normalized = [[body stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    if (![normalized writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil]) { [self fail:@"無法寫入腳本檔。"]; return; }
    [self runInTerminal:[NSString stringWithFormat:@"%@ %@ %@", ShellQuote(interp), args, ShellQuote(script)]];
}

- (void)runCurl:(NSString *)url {
    NSString *log = [N2LogsDirectory() stringByAppendingPathComponent:RandomName(@"_curl_log.txt")];
    NSWindow *w = self.window;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
        t.arguments = @[@"-q", @"-sS", @"-L", @"--max-redirs", @"10", @"--max-time", @"120", @"-w", @"\n\u001F%{http_code}", @"--", url];
        NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
        t.standardOutput = out; t.standardError = err; t.standardInput = NSFileHandle.fileHandleWithNullDevice;
        NSMutableString *text = [NSMutableString stringWithFormat:@"URL：%@\n時間：%@\n", url, [NSDate.date descriptionWithLocale:NSLocale.currentLocale]];
        if ([t launchAndReturnError:nil]) {
            __block NSData *errData = nil;
            dispatch_group_t g = dispatch_group_create();
            dispatch_group_async(g, dispatch_get_global_queue(0, 0), ^{ errData = [err.fileHandleForReading readDataToEndOfFile]; });
            NSData *d = [out.fileHandleForReading readDataToEndOfFile];
            dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
            [t waitUntilExit];
            // 最後一段是 HTTP 狀態碼
            NSData *marker = [@"\n\u001F" dataUsingEncoding:NSUTF8StringEncoding];
            NSRange m = [d rangeOfData:marker options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];
            NSData *body = m.location == NSNotFound ? d : [d subdataWithRange:NSMakeRange(0, m.location)];
            NSString *status = m.location == NSNotFound ? @"?" : [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(NSMaxRange(m), d.length - NSMaxRange(m))] encoding:NSUTF8StringEncoding];
            [text appendFormat:@"HTTP 狀態碼：%@\ncurl 結束碼：%d\n", status, t.terminationStatus];
            NSString *e = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
            if (e.length) [text appendFormat:@"錯誤：%@", e];
            [text appendString:@"\n----------------------------------------\n"];
            NSString *bodyText = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (bodyText) [text appendString:bodyText];
            else {   // 非 UTF-8：以十六進位顯示
                const unsigned char *b = (const unsigned char *)body.bytes;
                for (NSUInteger i = 0; i < body.length; i++) [text appendFormat:@"%02X%@", b[i], (i % 32 == 31) ? @"\n" : @" "];
            }
        } else {
            [text appendString:@"無法執行 /usr/bin/curl。\n"];
        }
        [text writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)w;
            [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:log] display:YES
                                                                       completionHandler:^(NSDocument *d, BOOL a, NSError *e) {}];
        });
    });
}

- (void)showReportInBackground:(xs::SqlReport (^)(void))work title:(NSString *)title {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 80) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 30, 24, 24)];
    spin.style = NSProgressIndicatorStyleSpinning;
    [spin startAnimation:nil];
    NSTextField *l = [NSTextField labelWithString:title];
    l.frame = NSMakeRect(54, 34, 270, 18);
    [panel.contentView addSubview:spin]; [panel.contentView addSubview:l];
    [self.window beginSheet:panel completionHandler:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        xs::SqlReport report = work();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.window endSheet:panel];
            [N2ResultWindow showReport:report];
        });
    });
}

- (void)openPath:(NSString *)path {
    NSString *full = path.stringByExpandingTildeInPath.stringByStandardizingPath;
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&dir]) { [self fail:[NSString stringWithFormat:@"找不到這個路徑：%@", full]]; return; }
    if (dir) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:full isDirectory:YES]];   // 資料夾交給 Finder
    else [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:full] display:YES
                                                                    completionHandler:^(NSDocument *d, BOOL a, NSError *e) { if (e) [NSApp presentError:e]; }];
}

// 單行 POSIX 絕對路徑（/…）或 ~/…
static NSString *SelectedPosixPath(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length || [t rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return nil;
    if (!([t hasPrefix:@"/"] || [t hasPrefix:@"~/"] || [t isEqualToString:@"~"])) return nil;
    if ([t rangeOfString:@"*"].location != NSNotFound || [t rangeOfString:@"?"].location != NSNotFound) return nil;
    return t;
}

- (IBAction)executeSelection:(id)sender {
    if ([self send:SCI_SELECTIONISRECTANGLE] || [self send:SCI_GETSELECTIONS] != 1) { [self fail:@"執行選取不支援矩形或多重選取，請使用單一連續選取範圍。"]; return; }
    BOOL hasSelection = [self send:SCI_GETSELECTIONEND] > [self send:SCI_GETSELECTIONSTART];
    NSString *text = self.selectedText;
    if (!hasSelection) {
        sptr_t line = [self send:SCI_LINEFROMPOSITION w:[self send:SCI_GETCURRENTPOS]];
        sptr_t a = [self send:SCI_POSITIONFROMLINE w:line], b = [self send:SCI_GETLINEENDPOSITION w:line];
        text = [[NSString alloc] initWithBytes:(const char *)[self send:SCI_GETRANGEPOINTER w:a l:b - a] length:(NSUInteger)(b - a) encoding:NSUTF8StringEncoding] ?: @"";
    }
    std::u16string u = N2ToU16(text);
    try {
        if (MarkedBody(text, @"[DOSCMD]") || MarkedBody(text, @"[VBSCRIPT]")) {
            [self showMessage:@"macOS 無法執行 Windows Batch／VBScript。" info:@"可改用 [SHCMD]（zsh 指令）或 [JAVASCRIPT]（macOS JavaScript for Automation）。"];
            return;
        }
        if (NSString *b = MarkedBody(text, @"[SHCMD]")) { [self runScript:b interpreter:@"/bin/zsh" args:@"" ext:@".zsh"]; return; }
        if (NSString *b = MarkedBody(text, @"[PSCMD]")) {
            NSString *pwsh = nil;
            for (NSString *p in @[@"/usr/local/bin/pwsh", @"/opt/homebrew/bin/pwsh"]) if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) pwsh = p;
            if (!pwsh) { [self showMessage:@"找不到 PowerShell（pwsh）。" info:@"macOS 沒有內建 PowerShell；安裝 PowerShell 7 後即可使用 [PSCMD]。"]; return; }
            [self runScript:b interpreter:pwsh args:@"-NoLogo -NoProfile -File" ext:@".ps1"];
            return;
        }
        if (NSString *b = MarkedBody(text, @"[JAVASCRIPT]")) { [self runScript:b interpreter:@"/usr/bin/osascript" args:@"-l JavaScript" ext:@".js"]; return; }
        if (auto ssh = xs::selectedSshUrl(u)) {
            NSString *target = ssh->username.empty() ? N2FromU16(ssh->host) : [NSString stringWithFormat:@"%@@%@", N2FromU16(ssh->username), N2FromU16(ssh->host)];
            NSMutableString *cmd = [NSMutableString string];
            if (ssh->passwordProvided) [cmd appendString:@"echo '提醒：網址中的密碼不會傳給 ssh，請在提示時輸入或改用 SSH 金鑰。'\n"];
            [cmd appendFormat:@"/usr/bin/ssh -p %u %@", ssh->port, ShellQuote(target)];
            if (!ssh->remoteDirectory.empty())
                [cmd appendFormat:@" -t %@", ShellQuote([NSString stringWithFormat:@"cd %@ && exec \"$SHELL\" -l", ShellQuote(N2FromU16(ssh->remoteDirectory))])];
            [self runInTerminal:cmd];
            return;
        }
        if (auto ftp = xs::selectedFtpUrl(u)) {
            NSURL *url = [NSURL URLWithString:N2FromU16(ftp->url)];
            if (!url || ![NSWorkspace.sharedWorkspace openURL:url]) [self fail:@"無法開啟 FTP 網址。"];
            return;
        }
        std::u16string web = xs::selectedUrl(u);
        if (!web.empty()) { [self runCurl:N2FromU16(web)]; return; }
        if (NSString *p = SelectedPosixPath(text)) { [self openPath:p]; return; }
        if (MarkedBody(text, @"[WQL]")) {
            [self showMessage:@"macOS 沒有 WMI，無法執行 WQL。" info:@"可改用 [SYSINFO]，第二行填 system_profiler 的資料類型，例如：\n[SYSINFO]\nSPHardwareDataType"];
            return;
        }
        if (NSString *b = MarkedBody(text, @"[SYSINFO]")) {
            NSString *type = [b stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!type.length) type = @"SPHardwareDataType";
            if ([type rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) { [self fail:@"資料類型只能包含英文與數字，例如 SPSoftwareDataType。"]; return; }
            [self showReportInBackground:^{ return RunSysInfo(type); } title:@"正在查詢系統資訊…"];
            return;
        }
        if ([[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"[DB"]) {
            xs::SqlSelection sel = xs::parseSqlSelection(u);
            void (^go)(void) = ^{ [self showReportInBackground:^{ return RunSql(sel); } title:@"正在執行 SQL…"]; };
            if (xs::sqlNeedsWhereConfirmation(sel.statement)) {
                NSAlert *a = [NSAlert new];
                a.messageText = @"UPDATE／DELETE 沒有 WHERE 條件";
                a.informativeText = [NSString stringWithFormat:@"可能會修改或刪除整張資料表。\n資料來源：%@\n確定要執行嗎？", N2FromU16(sel.dsn)];
                a.alertStyle = NSAlertStyleCritical;
                [a addButtonWithTitle:@"取消"];
                [a addButtonWithTitle:@"確定執行"];
                [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { if (r == NSAlertSecondButtonReturn) go(); }];
            } else go();
            return;
        }
    } catch (const xs::SqlInputError &e) {
        [self fail:N2FromU16(e.message)];
        return;
    } catch (const std::exception &e) {
        [self fail:[NSString stringWithUTF8String:e.what()]];
        return;
    }
    [self runMathFallback:hasSelection];
}

#pragma mark - 數學運算後備

- (void)runMathFallback:(BOOL)hasSelection {
    if ([self send:SCI_GETREADONLY] || self.doc.isCryptoLocked) { [self fail:@"目前文件為唯讀或受保護狀態，不能寫入數學答案。"]; return; }
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    sptr_t first = [self send:SCI_LINEFROMPOSITION w:hasSelection ? a : [self send:SCI_GETCURRENTPOS]];
    sptr_t last = hasSelection ? [self send:SCI_LINEFROMPOSITION w:b > a ? b - 1 : b] : first;
    xs::MathVariableContext ctx;
    struct Edit { sptr_t start, end; std::string text; };
    std::vector<Edit> edits;
    size_t assignments = 0;
    for (sptr_t line = first; line <= last; line++) {
        sptr_t ls = [self send:SCI_POSITIONFROMLINE w:line], le = [self send:SCI_GETLINEENDPOSITION w:line];
        if (le < ls || le - ls > 8192) continue;
        std::string bytes((const char *)[self send:SCI_GETRANGEPOINTER w:ls l:le - ls], (size_t)(le - ls));
        auto r = xs::evaluateMathBlockLine(bytes, (size_t)ls, ctx, N2EvaluateMath);
        if (r.state == xs::MathBlockLineState::Error) {
            NSString *why = r.error == xs::MathBlockLineError::UnknownVariable
                ? [NSString stringWithFormat:@"第 %ld 行使用了尚未宣告的變數「%s」。", (long)line + 1, r.identifier.c_str()]
                : [NSString stringWithFormat:@"第 %ld 行無法計算。", (long)line + 1];
            [self showMessage:@"數學運算失敗，文件沒有修改。" info:why];
            return;
        }
        if (r.state == xs::MathBlockLineState::Assignment) assignments++;
        if (r.edit) edits.push_back({(sptr_t)r.edit->start, (sptr_t)r.edit->end, r.edit->replacement});
    }
    if (edits.empty()) {
        [self showMessage:assignments ? @"只有變數指定，沒有要輸出答案的算式。" : @"沒有可計算的算式。"
                     info:@"例如輸入「1+2=」或多行「a=1、b=3、a+b=」後按 F5。"];
        return;
    }
    // 由後往前套用，位置才不會位移；整批是一個復原步驟
    [self send:SCI_BEGINUNDOACTION];
    for (auto it = edits.rbegin(); it != edits.rend(); ++it) {
        [self send:SCI_SETTARGETSTART w:it->start];
        [self send:SCI_SETTARGETEND w:it->end];
        [self send:SCI_REPLACETARGET w:it->text.size() l:(sptr_t)it->text.data()];
    }
    [self send:SCI_ENDUNDOACTION];
}

#pragma mark - 中文金額

- (void)convertMoney:(xs::MoneyStyle)style {
    if ([self send:SCI_GETREADONLY] || self.doc.isCryptoLocked) { NSBeep(); return; }
    if ([self send:SCI_SELECTIONISRECTANGLE] || [self send:SCI_GETSELECTIONS] != 1) { [self fail:@"請使用單一連續選取範圍。"]; return; }
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    if (b <= a) { [self fail:@"請先選取金額（每行一個）。"]; return; }
    if (b - a > 1024 * 1024) { [self fail:@"一次最多選取 1 MiB。"]; return; }
    NSString *sel = self.selectedText;
    NSData *w32 = [sel dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::wstring input((const wchar_t *)w32.bytes, w32.length / sizeof(wchar_t));
    auto result = xs::convertMoney(input, style);
    if (result.converted == 0) { [self showMessage:@"選取範圍裡沒有可轉換的金額，文件沒有修改。" info:@"接受半形數字、千分位與最多兩位小數，例如 1,500 或 200.50。"]; return; }
    NSString *out = [[NSString alloc] initWithBytes:result.text.data() length:result.text.size() * sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding];
    std::string bytes = out.UTF8String;
    [self send:SCI_BEGINUNDOACTION];
    [self send:SCI_SETTARGETSTART w:a];
    [self send:SCI_SETTARGETEND w:b];
    [self send:SCI_REPLACETARGET w:bytes.size() l:(sptr_t)bytes.data()];
    [self send:SCI_ENDUNDOACTION];
    [self send:SCI_SETSEL w:a l:a + (sptr_t)bytes.size()];
    if (result.skipped) [self showMessage:[NSString stringWithFormat:@"已轉換 %zu 行，略過 %zu 行無效內容。", result.converted, result.skipped] info:nil];
}

- (IBAction)moneyCommon:(id)sender { [self convertMoney:xs::MoneyStyle::common]; }
- (IBAction)moneyFinancial:(id)sender { [self convertMoney:xs::MoneyStyle::financial]; }

@end
