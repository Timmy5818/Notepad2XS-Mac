// 編輯視窗的文字處理指令：大小寫、空白整理、排序、修改行、註解、行操作、編碼與解碼、插入
#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"
#import "SyntaxStyles.h"
#import "TextEncoding.h"
#import "TextTransforms.h"
#import "ScintillaView.h"
#include <string>

typedef NS_ENUM(NSInteger, N2LineScope) {
    N2ScopeWholeDocument,   // 沒有選取時作用在整份文件
    N2ScopeCurrentLine,     // 沒有選取時作用在目前行
    N2ScopeCurrentAndNext,  // 沒有選取時作用在目前行與下一行（合併行）
};

@implementation EditorWindowController (Commands)

#pragma mark - 共用工具

// NSString → UTF-8 位元組：保留中間的 NUL（UTF8String 會在第一個 NUL 截斷），
// 含落單代理字元等無法表示的內容時回傳 false（UTF8String 會回傳 NULL）
static bool ToUTF8(NSString *s, std::string &out) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!d) return false;
    out.assign((const char *)d.bytes, d.length);
    return true;
}

- (std::string)rangeText:(sptr_t)a to:(sptr_t)b {
    if (b <= a) return std::string();
    return std::string((const char *)[self send:SCI_GETRANGEPOINTER w:a l:b - a], (size_t)(b - a));
}

- (NSString *)eolString {
    switch ([self send:SCI_GETEOLMODE]) {
        case SC_EOL_CRLF: return @"\r\n";
        case SC_EOL_CR: return @"\r";
        default: return @"\n";
    }
}

// 矩形或多重選取不支援時提示並回傳 NO
- (BOOL)requireSimpleSelection {
    if ([self send:SCI_SELECTIONISRECTANGLE] || [self send:SCI_GETSELECTIONS] > 1) {
        [self showMessage:@"這個功能不支援矩形選取或多重選取。" info:@"請改用一般選取後再試一次。"];
        return NO;
    }
    return YES;
}

// 以 UTF-8 文字取代 [a, b)，整個動作一次復原；select=YES 時選取新內容
- (void)replaceFrom:(sptr_t)a to:(sptr_t)b with:(const std::string &)text select:(BOOL)select {
    if ([self rangeText:a to:b] == text) {
        if (select) [self send:SCI_SETSEL w:a l:b];
        return;
    }
    [self send:SCI_BEGINUNDOACTION];
    [self send:SCI_SETTARGETSTART w:a];
    [self send:SCI_SETTARGETEND w:b];
    [self send:SCI_REPLACETARGET w:text.size() l:(sptr_t)text.data()];
    [self send:SCI_ENDUNDOACTION];
    if (select) [self send:SCI_SETSEL w:a l:a + (sptr_t)text.size()];
    else [self send:SCI_GOTOPOS w:MIN(a + (sptr_t)text.size(), [self send:SCI_GETCURRENTPOS])];
    [self send:SCI_SCROLLCARET];
}

// 取得作用範圍（完整的行）：回傳起點、終點（不含最後的換行）
- (BOOL)lineBlock:(N2LineScope)scope start:(sptr_t *)outA end:(sptr_t *)outB hadSelection:(BOOL *)had {
    sptr_t selA = [self send:SCI_GETSELECTIONSTART], selB = [self send:SCI_GETSELECTIONEND];
    sptr_t lineCount = [self send:SCI_GETLINECOUNT];
    sptr_t first, last;
    *had = selB > selA;
    if (*had) {
        first = [self send:SCI_LINEFROMPOSITION w:selA];
        last = [self send:SCI_LINEFROMPOSITION w:selB];
        if (last > first && [self send:SCI_POSITIONFROMLINE w:last] == selB) last--;   // 選到下一行行首不算
    } else if (scope == N2ScopeWholeDocument) {
        first = 0;
        last = lineCount - 1;
        // 文件以換行結尾時，最後那個空行不參與（例如排序時不會跑到最前面）
        if (last > 0 && [self send:SCI_POSITIONFROMLINE w:last] == [self send:SCI_GETLENGTH]) last--;
    } else {
        first = last = [self send:SCI_LINEFROMPOSITION w:[self send:SCI_GETCURRENTPOS]];
        if (scope == N2ScopeCurrentAndNext && last + 1 < lineCount) last++;
    }
    *outA = [self send:SCI_POSITIONFROMLINE w:first];
    *outB = [self send:SCI_GETLINEENDPOSITION w:last];
    return YES;
}

- (void)transformLines:(N2LineScope)scope with:(NSArray<NSString *> *(^)(NSArray<NSString *> *lines))f {
    if (![self requireSimpleSelection]) return;
    sptr_t a, b; BOOL had;
    [self lineBlock:scope start:&a end:&b hadSelection:&had];
    std::string old = [self rangeText:a to:b];
    NSString *text = [[NSString alloc] initWithBytes:old.data() length:old.size() encoding:NSUTF8StringEncoding];
    if (!text) { [self showMessage:@"選取範圍含有無效的文字。" info:nil]; return; }
    NSArray *lines = f(N2SplitLines(text));
    NSString *joined = [lines componentsJoinedByString:self.eolString];
    std::string out;
    if (!ToUTF8(joined, out)) { [self showMessage:@"轉換結果含有無法表示的字元，已取消。" info:nil]; return; }
    [self replaceFrom:a to:b with:out select:had];
}

// 選取文字轉換；沒有選取時 wholeDoc=YES 作用在整份文件，否則提示
- (void)transformSelection:(BOOL)wholeDoc with:(NSString *(^)(NSString *text, NSString **error))f {
    if (![self requireSimpleSelection]) return;
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    if (a == b) {
        if (!wholeDoc) { [self showMessage:@"請先選取要轉換的文字。" info:nil]; return; }
        a = 0; b = [self send:SCI_GETLENGTH];
    }
    std::string old = [self rangeText:a to:b];
    NSString *text = [[NSString alloc] initWithBytes:old.data() length:old.size() encoding:NSUTF8StringEncoding];
    if (!text) { [self showMessage:@"選取範圍含有無效的文字。" info:nil]; return; }
    NSString *err = nil;
    NSString *result = f(text, &err);
    if (!result) { if (err) [self showMessage:err info:nil]; else NSBeep(); return; }
    std::string out;
    if (!ToUTF8(result, out)) { [self showMessage:@"轉換結果含有無法表示的字元（例如落單的 UTF-16 代理字元），已取消。" info:nil]; return; }
    [self replaceFrom:a to:b with:out select:YES];
}

#pragma mark - 文件編碼的位元組（與 Windows 版相同：轉換作用在檔案編碼的位元組上）

- (N2Encoding)docEncoding { return self.doc ? self.doc.encoding : N2EncodingUTF8; }

static BOOL IsUnicodeEncoding(N2Encoding e) {
    return e == N2EncodingUTF8 || e == N2EncodingUTF8BOM || e == N2EncodingUTF16LE || e == N2EncodingUTF16BE;
}

- (BOOL)docBytes:(const std::string &)utf8 out:(std::string &)out {
    N2Encoding e = self.docEncoding;
    if (IsUnicodeEncoding(e)) { out = utf8; return YES; }
    NSData *d = N2EncodeFromUTF8(utf8.data(), utf8.size(), e, NULL);
    if (!d) return NO;
    out.assign((const char *)d.bytes, d.length);
    return YES;
}

- (BOOL)utf8FromDocBytes:(const std::string &)bytes out:(std::string &)out {
    N2Encoding e = self.docEncoding;
    if (IsUnicodeEncoding(e)) {
        if (!N2IsValidUTF8((const unsigned char *)bytes.data(), bytes.size())) return NO;
        out = bytes;
        return YES;
    }
    NSData *d = N2DecodeToUTF8([NSData dataWithBytes:bytes.data() length:bytes.size()], &e, NO);
    if (!d) return NO;
    out.assign((const char *)d.bytes, d.length);
    return YES;
}

- (void)encodeWith:(std::string (^)(const std::string &bytes))f {
    if (![self requireSimpleSelection]) return;
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    if (a == b) { a = 0; b = [self send:SCI_GETLENGTH]; }
    std::string bytes;
    if (![self docBytes:[self rangeText:a to:b] out:bytes]) {
        [self showMessage:[NSString stringWithFormat:@"選取範圍有字元無法用「%@」表示。", N2EncodingDisplayName(self.docEncoding)]
                     info:@"請先把文件編碼改成 UTF-8。"];
        return;
    }
    [self replaceFrom:a to:b with:f(bytes) select:YES];
}

- (void)decodeWith:(BOOL (^)(const std::string &text, std::string &bytes))f name:(NSString *)name {
    if (![self requireSimpleSelection]) return;
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    if (a == b) { a = 0; b = [self send:SCI_GETLENGTH]; }
    std::string input, bytes, utf8;
    // 先轉成文件編碼的位元組再解碼：URL／QP 選取範圍中沒被編碼的非 ASCII 字元，才會和 %XX 解出的位元組用同一種編碼
    if (![self docBytes:[self rangeText:a to:b] out:input]) {
        [self showMessage:[NSString stringWithFormat:@"選取範圍有字元無法用「%@」表示。", N2EncodingDisplayName(self.docEncoding)]
                     info:@"請先把文件編碼改成 UTF-8。"];
        return;
    }
    if (!f(input, bytes)) {
        [self showMessage:[NSString stringWithFormat:@"不是有效的 %@ 資料。", name] info:@"請確認選取範圍只包含編碼後的內容。"];
        return;
    }
    if (![self utf8FromDocBytes:bytes out:utf8]) {
        [self showMessage:@"解碼結果不是有效的文字。"
                     info:[NSString stringWithFormat:@"可能是二進位資料，或原本不是用「%@」編碼。", N2EncodingDisplayName(self.docEncoding)]];
        return;
    }
    [self replaceFrom:a to:b with:utf8 select:YES];
}

#pragma mark - 工具 → 編碼與解碼

- (IBAction)base64Encode:(id)sender { [self encodeWith:^(const std::string &s) { return n2::Base64Encode(s); }]; }
- (IBAction)base64Decode:(id)sender {
    [self decodeWith:^BOOL(const std::string &t, std::string &o) { return n2::Base64Decode(t, o); } name:@"Base64"];
}
- (IBAction)urlEncode:(id)sender { [self encodeWith:^(const std::string &s) { return n2::URLEncode(s); }]; }
- (IBAction)urlDecode:(id)sender {
    [self decodeWith:^BOOL(const std::string &t, std::string &o) { o = n2::URLDecode(t); return YES; } name:@"URL"];
}
- (IBAction)qpEncode:(id)sender { [self encodeWith:^(const std::string &s) { return n2::QPEncode(s); }]; }
- (IBAction)qpDecode:(id)sender {
    [self decodeWith:^BOOL(const std::string &t, std::string &o) { o = n2::QPDecode(t); return YES; } name:@"QP"];
}

// UTF-16 文件：每個字以 4 位十六進位表示（與 Windows 版相同）
- (IBAction)hexEncode:(id)sender {
    N2Encoding e = self.docEncoding;
    if (e == N2EncodingUTF16LE || e == N2EncodingUTF16BE) {
        BOOL big = (e == N2EncodingUTF16LE);
        [self transformSelection:YES with:^NSString *(NSString *text, NSString **err) {
            std::u16string u((const char16_t *)[text cStringUsingEncoding:NSUTF16LittleEndianStringEncoding], text.length);
            return [NSString stringWithUTF8String:n2::HexEncodeUTF16(u, big).c_str()];
        }];
        return;
    }
    [self encodeWith:^(const std::string &s) { return n2::HexEncode(s); }];
}

- (IBAction)hexDecode:(id)sender {
    N2Encoding e = self.docEncoding;
    if (e == N2EncodingUTF16LE || e == N2EncodingUTF16BE) {
        BOOL big = (e == N2EncodingUTF16LE);
        [self transformSelection:YES with:^NSString *(NSString *text, NSString **err) {
            std::u16string u;
            if (!n2::HexDecodeUTF16(text.UTF8String, big, u)) { *err = @"不是有效的十六進位資料（UTF-16 文件每個字需要 4 位）。"; return nil; }
            return [[NSString alloc] initWithCharacters:(const unichar *)u.data() length:u.size()];
        }];
        return;
    }
    [self decodeWith:^BOOL(const std::string &t, std::string &o) { return n2::HexDecode(t, o); } name:@"十六進位"];
}

- (IBAction)charToCHex:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **err) {
        NSString *r = N2CharToCHex(t);
        if (!r) *err = @"請只選取一個字元。";
        return r;
    }];
}

- (IBAction)cHexToChar:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **err) {
        NSString *r = N2CHexToChar(t);
        if (!r) *err = @"請選取 \\xNN、\\uNNNN 或 0xNN 格式的十六進位碼。";
        return r;
    }];
}

- (IBAction)escapeCChars:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **err) { return N2EscapeCChars(t); }];
}
- (IBAction)unescapeCChars:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **err) { return N2UnescapeCChars(t); }];
}
- (IBAction)stripHTMLTags:(id)sender {
    [self transformSelection:YES with:^NSString *(NSString *t, NSString **err) { return N2StripHTMLTags(t); }];
}
- (IBAction)escapeHTML:(id)sender {
    [self transformSelection:YES with:^NSString *(NSString *t, NSString **err) { return N2EscapeHTML(t); }];
}

#pragma mark - 格式 → 大小寫

- (IBAction)makeUpperCase:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) { return t.uppercaseString; }];
}
- (IBAction)makeLowerCase:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) { return t.lowercaseString; }];
}
- (IBAction)invertCase:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) { return N2InvertCase(t); }];
}
- (IBAction)titleCase:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) { return N2TitleCase(t); }];
}
- (IBAction)sentenceCase:(id)sender {
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) { return N2SentenceCase(t); }];
}

#pragma mark - 格式 → 空白與字元整理

- (IBAction)trimTrailingWhitespace:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2TrimTrailingWhitespace(l); }];
}
- (IBAction)compressWhitespace:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2CompressWhitespace(l); }];
}
- (IBAction)mergeBlankLines:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2RemoveBlankLines(l, YES); }];
}
- (IBAction)removeBlankLines:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2RemoveBlankLines(l, NO); }];
}
- (IBAction)stripFirstChar:(id)sender {
    [self transformLines:N2ScopeCurrentLine with:^(NSArray *l) { return N2StripFirstChar(l); }];
}
- (IBAction)stripLastChar:(id)sender {
    [self transformLines:N2ScopeCurrentLine with:^(NSArray *l) { return N2StripLastChar(l); }];
}
- (IBAction)padWithSpaces:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2PadWithSpaces(l); }];
}

#pragma mark - 格式 → 縮排與定位字元

- (IBAction)indentLines:(id)sender { [self send:SCI_TAB]; }
- (IBAction)unindentLines:(id)sender { [self send:SCI_BACKTAB]; }
- (IBAction)convertTabsToSpaces:(id)sender {
    NSInteger w = N2Settings.tabWidth;
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2TabsToSpaces(l, w, NO); }];
}
- (IBAction)convertSpacesToTabs:(id)sender {
    NSInteger w = N2Settings.tabWidth;
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2SpacesToTabs(l, w, NO); }];
}
- (IBAction)convertIndentTabsToSpaces:(id)sender {
    NSInteger w = N2Settings.tabWidth;
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2TabsToSpaces(l, w, YES); }];
}
- (IBAction)convertIndentSpacesToTabs:(id)sender {
    NSInteger w = N2Settings.tabWidth;
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2SpacesToTabs(l, w, YES); }];
}

#pragma mark - 格式 → 換行與段落

- (IBAction)splitLinesToWindow:(id)sender {
    // 依視窗寬度拆分選取的行
    if (![self requireSimpleSelection]) return;
    sptr_t a, b; BOOL had;
    [self lineBlock:N2ScopeCurrentLine start:&a end:&b hadSelection:&had];
    [self send:SCI_BEGINUNDOACTION];
    [self send:SCI_SETTARGETSTART w:a];
    [self send:SCI_SETTARGETEND w:b];
    [self send:SCI_LINESSPLIT w:0];
    [self send:SCI_ENDUNDOACTION];
}
- (IBAction)joinLines:(id)sender {
    [self transformLines:N2ScopeCurrentAndNext with:^(NSArray *l) { return N2JoinLines(l, NO); }];
}
- (IBAction)joinLinesNoSpace:(id)sender {
    [self transformLines:N2ScopeCurrentAndNext with:^(NSArray *l) { return N2JoinLines(l, YES); }];
}
- (IBAction)joinParagraphs:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2JoinParagraphs(l, NO); }];
}
- (IBAction)joinParagraphsNoSpace:(id)sender {
    [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2JoinParagraphs(l, YES); }];
}

- (IBAction)wrapToColumn:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger last = [ud integerForKey:@"WrapToColumn"] ?: 80;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    field.stringValue = [NSString stringWithFormat:@"%ld", (long)last];
    [self runForm:@"依欄寬換行" info:@"輸入每行最多幾個字元寬（全形字算 2）。" accessory:field first:field ok:^{
        NSInteger col = field.integerValue;
        if (col < 1 || col > 10000) { NSBeep(); return; }
        [ud setInteger:col forKey:@"WrapToColumn"];
        [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2WrapToColumn(l, col); }];
    }];
}

#pragma mark - 對話框

- (void)runForm:(NSString *)title info:(NSString *)info accessory:(NSView *)view first:(NSView *)first ok:(void (^)(void))ok {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    if (info) a.informativeText = info;
    a.accessoryView = view;
    [a addButtonWithTitle:@"確定"];
    [a addButtonWithTitle:@"取消"];
    if (first) a.window.initialFirstResponder = first;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) ok();
    }];
}

static NSTextField *Label(NSString *s, NSRect r) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.frame = r;
    return l;
}

static NSTextField *Field(NSRect r, NSString *value) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:r];
    f.stringValue = value ?: @"";
    return f;
}

- (IBAction)sortLines:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [ud dictionaryForKey:@"SortOptions"] ?: @{};
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 232)];
    NSArray *orders = @[@"遞增排序", @"遞減排序", @"隨機排列", @"保留行順序", @"反轉行順序"];
    NSInteger savedOrder = [saved[@"order"] integerValue];
    NSMutableArray<NSButton *> *radios = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)orders.count; i++) {
        NSButton *r = [NSButton radioButtonWithTitle:orders[i] target:self action:@selector(n2SortRadio:)];
        r.frame = NSMakeRect(0, 210 - i * 22, 300, 18);
        r.tag = i;
        r.state = (i == savedOrder) ? NSControlStateValueOn : NSControlStateValueOff;
        [v addSubview:r];
        [radios addObject:r];
    }
    NSArray *checkTitles = @[@"合併重複行（保留一行）", @"移除重複行（全部移除）", @"移除不重複的行", @"不區分大小寫", @"依數值邏輯比較（file2 排在 file10 前）"];
    NSArray *checkKeys = @[@"merge", @"removeDup", @"removeUnique", @"caseInsensitive", @"logical"];
    NSMutableArray<NSButton *> *checks = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)checkTitles.count; i++) {
        NSButton *c = [NSButton checkboxWithTitle:checkTitles[i] target:nil action:nil];
        c.frame = NSMakeRect(0, 92 - i * 22 - (i >= 3 ? 8 : 0), 300, 18);
        c.state = [saved[checkKeys[i]] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [v addSubview:c];
        [checks addObject:c];
    }
    [self runForm:@"排序／移除重複行" info:@"有選取時處理選取的行，沒有選取時處理整份文件。" accessory:v first:nil ok:^{
        N2SortOptions o = {};
        for (NSButton *r in radios) if (r.state == NSControlStateValueOn) o.order = (N2SortOrder)r.tag;
        o.mergeDuplicates = checks[0].state == NSControlStateValueOn;
        o.removeDuplicates = checks[1].state == NSControlStateValueOn;
        o.removeUnique = checks[2].state == NSControlStateValueOn;
        o.caseInsensitive = checks[3].state == NSControlStateValueOn;
        o.logical = checks[4].state == NSControlStateValueOn;
        [ud setObject:@{@"order": @(o.order), @"merge": @(o.mergeDuplicates), @"removeDup": @(o.removeDuplicates),
                        @"removeUnique": @(o.removeUnique), @"caseInsensitive": @(o.caseInsensitive), @"logical": @(o.logical)}
               forKey:@"SortOptions"];
        [self transformLines:N2ScopeWholeDocument with:^(NSArray *l) { return N2SortLines(l, o); }];
    }];
}

// 同一個 superview 裡 action 相同的 radio 按鈕會自動互斥；這個方法只是讓它們有共同的 action
- (IBAction)n2SortRadio:(id)sender {}

- (IBAction)modifyLines:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 150)];
    [v addSubview:Label(@"加在行首：", NSMakeRect(0, 124, 340, 18))];
    NSTextField *prefix = Field(NSMakeRect(0, 98, 340, 24), [ud stringForKey:@"ModifyLinesPrefix"]);
    [v addSubview:prefix];
    [v addSubview:Label(@"加在行尾：", NSMakeRect(0, 72, 340, 18))];
    NSTextField *suffix = Field(NSMakeRect(0, 46, 340, 24), [ud stringForKey:@"ModifyLinesSuffix"]);
    [v addSubview:suffix];
    NSTextField *hint = Label(@"$(L) 行號　$(N) 從 1 編號　$(I) 從 0 編號\n加 0 補零，例如 $(0N)", NSMakeRect(0, 0, 340, 36));
    hint.textColor = NSColor.secondaryLabelColor;
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [v addSubview:hint];
    [self runForm:@"修改行" info:@"有選取時處理選取的行，沒有選取時處理目前行。" accessory:v first:prefix ok:^{
        [ud setObject:prefix.stringValue forKey:@"ModifyLinesPrefix"];
        [ud setObject:suffix.stringValue forKey:@"ModifyLinesSuffix"];
        sptr_t a, b; BOOL had;
        [self lineBlock:N2ScopeCurrentLine start:&a end:&b hadSelection:&had];
        NSInteger firstLine = [self send:SCI_LINEFROMPOSITION w:a] + 1;
        NSString *p = prefix.stringValue, *s = suffix.stringValue;
        [self transformLines:N2ScopeCurrentLine with:^(NSArray *l) { return N2ModifyLines(l, p, s, firstLine); }];
    }];
}

- (IBAction)encloseSelection:(id)sender {
    if (![self requireSimpleSelection]) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 104)];
    [v addSubview:Label(@"加在前面：", NSMakeRect(0, 82, 340, 18))];
    NSTextField *before = Field(NSMakeRect(0, 56, 340, 24), [ud stringForKey:@"EncloseBefore"]);
    [v addSubview:before];
    [v addSubview:Label(@"加在後面：", NSMakeRect(0, 30, 340, 18))];
    NSTextField *after = Field(NSMakeRect(0, 4, 340, 24), [ud stringForKey:@"EncloseAfter"]);
    [v addSubview:after];
    [self runForm:@"在選取範圍前後加入文字" info:nil accessory:v first:before ok:^{
        [ud setObject:before.stringValue forKey:@"EncloseBefore"];
        [ud setObject:after.stringValue forKey:@"EncloseAfter"];
        sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
        std::string inner = [self rangeText:a to:b];
        std::string pre = before.stringValue.UTF8String, post = after.stringValue.UTF8String;
        [self send:SCI_BEGINUNDOACTION];
        [self replaceFrom:a to:b with:pre + inner + post select:NO];
        [self send:SCI_SETSEL w:a + (sptr_t)pre.size() l:a + (sptr_t)(pre.size() + inner.size())];
        [self send:SCI_ENDUNDOACTION];
    }];
}

- (IBAction)duplicateSelection:(id)sender { [self send:SCI_SELECTIONDUPLICATE]; }

#pragma mark - 註解

- (IBAction)toggleLineComment:(id)sender {
    NSString *token = N2SyntaxLineComment(self.doc.effectiveLanguageID);
    if (!token) { [self showMessage:@"這個語言沒有行註解符號。" info:@"可以從「格式 → 語法上色」選擇語言。"]; return; }
    [self transformLines:N2ScopeCurrentLine with:^(NSArray *l) { return N2ToggleLineComment(l, token); }];
}

- (IBAction)toggleBlockComment:(id)sender {
    NSArray *pair = N2SyntaxBlockComment(self.doc.effectiveLanguageID);
    if (!pair) { [self showMessage:@"這個語言沒有區塊註解符號。" info:nil]; return; }
    [self transformSelection:NO with:^NSString *(NSString *t, NSString **e) {
        NSString *open = pair[0], *close = pair[1];
        if ([t hasPrefix:open] && [t hasSuffix:close] && t.length >= open.length + close.length)
            return [t substringWithRange:NSMakeRange(open.length, t.length - open.length - close.length)];
        return [NSString stringWithFormat:@"%@%@%@", open, t, close];
    }];
}

#pragma mark - 編輯 → 行操作

- (IBAction)moveLineUp:(id)sender { [self send:SCI_MOVESELECTEDLINESUP]; }
- (IBAction)moveLineDown:(id)sender { [self send:SCI_MOVESELECTEDLINESDOWN]; }
- (IBAction)duplicateLine:(id)sender { [self send:SCI_LINEDUPLICATE]; }
- (IBAction)cutLine:(id)sender { [self send:SCI_LINECUT]; }
- (IBAction)copyLine:(id)sender { [self send:SCI_LINECOPY]; }
- (IBAction)deleteLine:(id)sender { [self send:SCI_LINEDELETE]; }

- (IBAction)newLineAbove:(id)sender {
    sptr_t line = [self send:SCI_LINEFROMPOSITION w:[self send:SCI_GETCURRENTPOS]];
    sptr_t start = [self send:SCI_POSITIONFROMLINE w:line];
    std::string eol = self.eolString.UTF8String;
    [self send:SCI_BEGINUNDOACTION];
    [self send:SCI_INSERTTEXT w:start l:(sptr_t)eol.c_str()];
    [self send:SCI_GOTOPOS w:start];
    [self send:SCI_ENDUNDOACTION];
}

- (IBAction)newLineBelow:(id)sender {
    sptr_t line = [self send:SCI_LINEFROMPOSITION w:[self send:SCI_GETCURRENTPOS]];
    sptr_t end = [self send:SCI_GETLINEENDPOSITION w:line];
    std::string eol = self.eolString.UTF8String;
    [self send:SCI_BEGINUNDOACTION];
    [self send:SCI_INSERTTEXT w:end l:(sptr_t)eol.c_str()];
    [self send:SCI_GOTOPOS w:end + (sptr_t)eol.size()];
    [self send:SCI_ENDUNDOACTION];
}

#pragma mark - 插入

- (void)insertString:(NSString *)s {
    [self send:SCI_REPLACESEL w:0 l:(sptr_t)s.UTF8String];
}

- (IBAction)insertDateTime:(id)sender {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_TW"];
    f.dateFormat = @"ah:mm yyyy/M/d";
    [self insertString:[f stringFromDate:NSDate.date]];
}

- (IBAction)insertLongDateTime:(id)sender {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_TW"];
    f.dateStyle = NSDateFormatterFullStyle;
    f.timeStyle = NSDateFormatterMediumStyle;
    [self insertString:[f stringFromDate:NSDate.date]];
}

- (IBAction)insertFileName:(id)sender {
    NSURL *u = self.doc.fileURL;
    [self insertString:u ? u.lastPathComponent : self.doc.displayName];
}

- (IBAction)insertFilePath:(id)sender {
    NSURL *u = self.doc.fileURL;
    if (!u) { [self showMessage:@"這份文件還沒有儲存。" info:@"儲存後才有完整路徑。"]; return; }
    [self insertString:u.path];
}

@end
