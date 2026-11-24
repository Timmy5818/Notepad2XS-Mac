// 編輯導覽（對應 Windows 版 R137～R141、R151）
// - 行書籤：⌘F2 循環切換（無 → 藍 → 紅 → 無）、⌥F2／⌥⇧F2 前後跳、清除；書籤欄左鍵藍色、右鍵紅色
// - 尋找視窗「標記符合的行」：搜尋書籤（每次搜尋取代上一次的搜尋書籤，手動書籤保留）
// - 區塊折疊：檢視 → 大綱；C/C++ 系列、Python、HTML/XML、JSON、Shell、SQL
// - 工具 → JSON 處理：格式化（兩個空格縮排）／壓縮，沿用換行格式，一次復原
// - 編輯 → 顯示字元資訊；設定的「自動補括號」「自動補引號」
// - 書籤與檢視狀態存在文件旁的 .2xs（BookmarkStore）
#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"
#import "Localization.h"
#import "BookmarkStore.h"
#import "ScintillaView.h"
#import "ArchiveEdit.h"
#import "HtmlLayoutWindow.h"
#import <objc/runtime.h>
#include "SciLexer.h"
#include "JsonFormatCore.h"
#include <string>
#include <vector>

enum { N2FoldMargin = 2, N2BookmarkMargin = 3 };
static const int N2AutoPairIndicator = 29;   // 自動補上的閉合符號（看不見的標記，值＝符號本身）

static sptr_t S(ScintillaView *v, unsigned int m, uptr_t w = 0, sptr_t l = 0) { return [v message:m wParam:w lParam:l]; }
static constexpr long RGB(int r, int g, int b) { return r | (g << 8) | (b << 16); }

#pragma mark - 自動補括號／引號（取代 Scintilla 的文字輸入，只處理鍵盤輸入的單一字元）

@interface N2SCIContentView : SCIContentView
@end

static BOOL N2AutoPair(ScintillaView *v, unichar key);

@implementation N2SCIContentView
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *s = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    NSEvent *e = NSApp.currentEvent;
    // 輸入法組字中（有標記文字）、指定取代範圍、非鍵盤事件都交給原本的流程
    if ([s isKindOfClass:NSString.class] && s.length == 1 && !self.hasMarkedText &&
        replacementRange.location == NSNotFound && e.type == NSEventTypeKeyDown &&
        (N2Settings.autoPairBrackets || N2Settings.autoPairQuotes)) {
        ScintillaView *owner = (ScintillaView *)self.superview;
        while (owner && ![owner isKindOfClass:ScintillaView.class]) owner = (ScintillaView *)owner.superview;
        if (owner && N2AutoPair(owner, [s characterAtIndex:0])) return;
    }
    [super insertText:string replacementRange:replacementRange];
}
@end

static void SetPairMark(ScintillaView *v, sptr_t pos, int value) {
    sptr_t previous = S(v, SCI_GETINDICATORCURRENT);
    S(v, SCI_SETINDICATORCURRENT, N2AutoPairIndicator);
    if (value) {
        S(v, SCI_SETINDICATORVALUE, value);
        S(v, SCI_INDICATORFILLRANGE, pos, 1);
    } else {
        S(v, SCI_INDICATORCLEARRANGE, pos, 1);
    }
    S(v, SCI_SETINDICATORCURRENT, previous);
}

// 與 Windows 版 ScintillaWin::AutoPairCharacter 相同的規則
static BOOL N2AutoPair(ScintillaView *v, unichar key) {
    if (key > 0x7F || S(v, SCI_GETSELECTIONS) != 1 || S(v, SCI_GETSELECTIONMODE) != SC_SEL_STREAM ||
        S(v, SCI_GETREADONLY) || S(v, SCI_GETOVERTYPE) || S(v, SCI_AUTOCACTIVE))
        return NO;
    char closing = 0;
    switch (key) {
        case '(': closing = ')'; break;
        case '[': closing = ']'; break;
        case '{': closing = '}'; break;
        case '\'': case '"': closing = (char)key; break;
        case ')': case ']': case '}': break;
        default: return NO;
    }
    const BOOL quote = key == '\'' || key == '"';
    if (quote ? !N2Settings.autoPairQuotes : !N2Settings.autoPairBrackets) return NO;
    if (S(v, SCI_GETSELECTIONNCARETVIRTUALSPACE, 0) || S(v, SCI_GETSELECTIONNANCHORVIRTUALSPACE, 0)) return NO;
    sptr_t caret = S(v, SCI_GETCURRENTPOS), anchor = S(v, SCI_GETANCHOR);
    sptr_t start = MIN(caret, anchor), end = MAX(caret, anchor);
    if (start == end) {
        if (quote) {   // 前面是奇數個反斜線：這個引號是跳脫字元的一部分
            BOOL escaped = NO;
            for (sptr_t pos = start; pos > 0 && S(v, SCI_GETCHARAT, pos - 1) == '\\'; pos--) escaped = !escaped;
            if (escaped) return NO;
        }
        // 剛自動補上的閉合符號：直接跳過，不重複輸入
        if (start < S(v, SCI_GETLENGTH) && S(v, SCI_GETCHARAT, start) == key &&
            S(v, SCI_INDICATORVALUEAT, N2AutoPairIndicator, start) == key) {
            SetPairMark(v, start, 0);
            S(v, SCI_SETEMPTYSELECTION, start + 1);
            S(v, SCI_SCROLLCARET);
            S(v, SCI_CHOOSECARETX);
            return YES;
        }
        if (!closing) return NO;
        if (key == '\'' && start > 0) {   // 英文縮寫（don't）不補
            sptr_t prev = S(v, SCI_POSITIONBEFORE, start);
            int c = (int)(unsigned char)S(v, SCI_GETCHARAT, prev);
            if (c >= 0x80 || isalnum(c) || c == '_') return NO;
        }
        char pair[3] = {(char)key, closing, 0};
        S(v, SCI_BEGINUNDOACTION);
        S(v, SCI_INSERTTEXT, start, (sptr_t)pair);
        S(v, SCI_ENDUNDOACTION);
        SetPairMark(v, start + 1, closing);
        S(v, SCI_SETEMPTYSELECTION, start + 1);
    } else {
        if (!closing) return NO;
        char open[2] = {(char)key, 0}, close[2] = {closing, 0};
        S(v, SCI_BEGINUNDOACTION);
        S(v, SCI_INSERTTEXT, end, (sptr_t)close);
        S(v, SCI_INSERTTEXT, start, (sptr_t)open);
        S(v, SCI_ENDUNDOACTION);
        // 保留原本選取的文字與方向
        S(v, SCI_SETSELECTION, caret + 1, anchor + 1);
    }
    S(v, SCI_SCROLLCARET);
    S(v, SCI_CHOOSECARETX);
    return YES;
}

void N2InstallAutoPair(ScintillaView *v) {
    // 子類別沒有新增成員變數，可以安全替換
    if (object_getClass(v.content) == SCIContentView.class) object_setClass(v.content, N2SCIContentView.class);
    S(v, SCI_INDICSETSTYLE, N2AutoPairIndicator, INDIC_HIDDEN);
}

@implementation EditorWindowController (Navigation)

#pragma mark - 邊界與折疊

static BOOL SupportsFolding(ScintillaView *v) {
    switch (S(v, SCI_GETLEXER)) {
        case SCLEX_PYTHON: case SCLEX_HTML: case SCLEX_XML: case SCLEX_JSON:
        case SCLEX_CPP: case SCLEX_BASH: case SCLEX_SQL:
            return YES;
        default:
            return NO;
    }
}

// 每次設定語法上色（會重設樣式與標記顏色）之後呼叫
- (void)applyNavigation:(ScintillaView *)v {
    BOOL previous = (S(v, SCI_GETAUTOMATICFOLD) & SC_AUTOMATICFOLD_CLICK) != 0;
    BOOL folding = N2Settings.codeFolding && SupportsFolding(v);
    if (previous && !folding) S(v, SCI_FOLDALL, SC_FOLDACTION_EXPAND);
    S(v, SCI_SETPROPERTY, (uptr_t)"fold", (sptr_t)(folding ? "1" : "0"));
    if (S(v, SCI_GETLEXER) == SCLEX_HTML || S(v, SCI_GETLEXER) == SCLEX_XML)
        S(v, SCI_SETPROPERTY, (uptr_t)"fold.html", (sptr_t)"1");
    S(v, SCI_SETAUTOMATICFOLD, folding ? SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CHANGE | SC_AUTOMATICFOLD_CLICK : 0);

    // 原本的選取邊界（1）不顯示標記；折疊（2）與書籤（3）各自一欄
    S(v, SCI_SETMARGINMASKN, 1, 0);
    S(v, SCI_SETMARGINTYPEN, N2FoldMargin, SC_MARGIN_SYMBOL);
    S(v, SCI_SETMARGINMASKN, N2FoldMargin, SC_MASK_FOLDERS);
    S(v, SCI_SETMARGINSENSITIVEN, N2FoldMargin, 1);
    S(v, SCI_SETMARGINCURSORN, N2FoldMargin, SC_CURSORARROW);
    S(v, SCI_SETMARGINTYPEN, N2BookmarkMargin, SC_MARGIN_SYMBOL);
    S(v, SCI_SETMARGINMASKN, N2BookmarkMargin, N2BookmarkMask);
    S(v, SCI_SETMARGINSENSITIVEN, N2BookmarkMargin, 1);
    S(v, SCI_SETMARGINCURSORN, N2BookmarkMargin, SC_CURSORARROW);
    S(v, SCI_USEPOPUP, SC_POPUP_TEXT);   // 邊界上按右鍵用來設紅色書籤，不跳出選單

    static const int foldSymbols[] = {SC_MARK_BOXPLUSCONNECTED, SC_MARK_BOXMINUSCONNECTED, SC_MARK_TCORNER,
                                      SC_MARK_LCORNER, SC_MARK_VLINE, SC_MARK_BOXPLUS, SC_MARK_BOXMINUS};
    for (int i = 0; i < 7; i++) {
        int marker = SC_MARKNUM_FOLDEREND + i;
        S(v, SCI_MARKERDEFINE, marker, foldSymbols[i]);
        S(v, SCI_MARKERSETFORE, marker, S(v, SCI_STYLEGETBACK, STYLE_LINENUMBER));
        S(v, SCI_MARKERSETBACK, marker, S(v, SCI_STYLEGETFORE, STYLE_LINENUMBER));
    }
    S(v, SCI_SETFOLDMARGINCOLOUR, 1, S(v, SCI_STYLEGETBACK, STYLE_LINENUMBER));
    S(v, SCI_SETFOLDMARGINHICOLOUR, 1, S(v, SCI_STYLEGETBACK, STYLE_LINENUMBER));
    S(v, SCI_MARKERSETFORE, N2BlueBookmark, RGB(30, 76, 129));
    S(v, SCI_MARKERSETBACK, N2BlueBookmark, RGB(45, 140, 223));
    S(v, SCI_MARKERSETFORE, N2RedBookmark, RGB(141, 38, 49));
    S(v, SCI_MARKERSETBACK, N2RedBookmark, RGB(229, 66, 82));
    S(v, SCI_MARKERSETFORE, N2SearchBookmark, RGB(125, 68, 7));
    S(v, SCI_MARKERSETBACK, N2SearchBookmark, RGB(236, 163, 47));
    [self refreshNavigationMargins:v];
}

// 邊界寬度隨字高（縮放）改變
- (void)refreshNavigationMargins:(ScintillaView *)v {
    sptr_t height = S(v, SCI_TEXTHEIGHT, 0);
    sptr_t width = MAX(height, 9);
    BOOL folding = (S(v, SCI_GETAUTOMATICFOLD) & SC_AUTOMATICFOLD_CLICK) != 0;
    BOOL bookmarks = N2Settings.bookmarkMargin;
    // 欄位隱藏時標記不畫出來（寬度 0 的欄位仍會把標記畫到文字上）
    int manual = bookmarks ? SC_MARK_CIRCLE : SC_MARK_EMPTY, search = bookmarks ? SC_MARK_SMALLRECT : SC_MARK_EMPTY;
    if (S(v, SCI_MARKERSYMBOLDEFINED, N2BlueBookmark) != manual) S(v, SCI_MARKERDEFINE, N2BlueBookmark, manual);
    if (S(v, SCI_MARKERSYMBOLDEFINED, N2RedBookmark) != manual) S(v, SCI_MARKERDEFINE, N2RedBookmark, manual);
    if (S(v, SCI_MARKERSYMBOLDEFINED, N2SearchBookmark) != search) S(v, SCI_MARKERDEFINE, N2SearchBookmark, search);
    sptr_t fw = folding ? width : 0, bw = bookmarks ? width : 0;
    BOOL changed = S(v, SCI_GETMARGINWIDTHN, N2FoldMargin) != fw || S(v, SCI_GETMARGINWIDTHN, N2BookmarkMargin) != bw;
    S(v, SCI_SETMARGINWIDTHN, N2FoldMargin, fw);
    S(v, SCI_SETMARGINWIDTHN, N2BookmarkMargin, bw);
    if (changed) [self retile:v];
}

- (void)navigationMarginClick:(SCNotification *)scn view:(ScintillaView *)v right:(BOOL)right {
    if (scn->margin != N2BookmarkMargin) return;
    [self toggleBookmarkLine:(sptr_t)S(v, SCI_LINEFROMPOSITION, scn->position) view:v color:right ? N2RedBookmark : N2BlueBookmark];
}

- (IBAction)toggleCodeFolding:(id)sender { N2Settings.codeFolding = !N2Settings.codeFolding; }
- (IBAction)toggleBookmarkMargin:(id)sender { N2Settings.bookmarkMargin = !N2Settings.bookmarkMargin; }
- (IBAction)toggleAutoPairBrackets:(id)sender { N2Settings.autoPairBrackets = !N2Settings.autoPairBrackets; }
- (IBAction)toggleAutoPairQuotes:(id)sender { N2Settings.autoPairQuotes = !N2Settings.autoPairQuotes; }

- (BOOL)foldingActive { return S(self.sci, SCI_GETMARGINWIDTHN, N2FoldMargin) > 0; }

- (IBAction)toggleFoldBlock:(id)sender {
    ScintillaView *v = self.sci;
    if (!self.foldingActive) { NSBeep(); return; }
    sptr_t line = S(v, SCI_LINEFROMPOSITION, S(v, SCI_GETCURRENTPOS));
    S(v, SCI_FOLDLINE, line, SC_FOLDACTION_TOGGLE);
}

- (IBAction)expandAllFolds:(id)sender {
    if (!self.foldingActive) { NSBeep(); return; }
    S(self.sci, SCI_FOLDALL, SC_FOLDACTION_EXPAND);
}

#pragma mark - 行書籤

// color < 0：循環（無 → 藍 → 紅 → 無）；指定顏色：同色再點一次取消，不同色換色
- (void)toggleBookmarkLine:(sptr_t)line view:(ScintillaView *)v color:(int)requested {
    if (line < 0 || line >= S(v, SCI_GETLINECOUNT)) return;
    unsigned marks = (unsigned)S(v, SCI_MARKERGET, line);
    // 兩個有書籤的行合併後，同一行可能有兩種顏色；以畫在上面的紅色為準
    int current = (marks & (1u << N2RedBookmark)) ? N2RedBookmark : (marks & (1u << N2BlueBookmark)) ? N2BlueBookmark : -1;
    int cycle = current < 0 ? N2BlueBookmark : current == N2BlueBookmark ? N2RedBookmark : -1;
    int next = requested < 0 ? cycle : (requested == current ? -1 : requested);
    if (next >= 0 && !(marks & (1u << next)) && S(v, SCI_MARKERADD, line, next) < 0) return;
    if (next != N2BlueBookmark && (marks & (1u << N2BlueBookmark))) S(v, SCI_MARKERDELETE, line, N2BlueBookmark);
    if (next != N2RedBookmark && (marks & (1u << N2RedBookmark))) S(v, SCI_MARKERDELETE, line, N2RedBookmark);
}

- (IBAction)toggleBookmark:(id)sender {
    ScintillaView *v = self.sci;
    [self toggleBookmarkLine:S(v, SCI_LINEFROMPOSITION, S(v, SCI_GETCURRENTPOS)) view:v color:-1];
}

- (void)gotoBookmark:(BOOL)forward {
    ScintillaView *v = self.sci;
    sptr_t current = S(v, SCI_LINEFROMPOSITION, S(v, SCI_GETCURRENTPOS));
    sptr_t lines = S(v, SCI_GETLINECOUNT);
    unsigned msg = forward ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS;
    sptr_t start = current + (forward ? 1 : -1);
    sptr_t dest = start >= 0 && start < lines ? S(v, msg, start, N2BookmarkMask) : -1;
    if (dest < 0) dest = S(v, msg, forward ? 0 : lines - 1, N2BookmarkMask);   // 循環
    if (dest < 0) { NSBeep(); return; }
    S(v, SCI_ENSUREVISIBLEENFORCEPOLICY, dest);
    S(v, SCI_GOTOLINE, dest);
}

- (IBAction)nextBookmark:(id)sender { [self gotoBookmark:YES]; }
- (IBAction)previousBookmark:(id)sender { [self gotoBookmark:NO]; }

- (IBAction)clearBookmarks:(id)sender {
    for (int m : {N2BlueBookmark, N2RedBookmark, N2SearchBookmark}) S(self.primarySci, SCI_MARKERDELETEALL, m);
}

// 尋找視窗「標記符合的行」：回傳標記的行數；-1 規則有誤；-3 無法完成（原有書籤保留）
- (NSInteger)bookmarkLinesMatching:(NSString *)text options:(N2FindOptions)options {
    NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!needle.length) return 0;
    ScintillaView *v = self.sci;
    int flags = 0;
    if (options & N2FindMatchCase) flags |= SCFIND_MATCHCASE;
    if (options & N2FindWholeWord) flags |= SCFIND_WHOLEWORD;
    if (options & N2FindRegex) flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    sptr_t length = S(v, SCI_GETLENGTH);
    sptr_t savedStart = S(v, SCI_GETTARGETSTART), savedEnd = S(v, SCI_GETTARGETEND);
    std::vector<sptr_t> lines;
    sptr_t pos = 0, previousLine = -1;
    NSInteger result = 0;
    S(v, SCI_SETSEARCHFLAGS, flags);
    S(v, SCI_SETSTATUS, SC_STATUS_OK);
    while (pos <= length) {
        S(v, SCI_SETTARGETSTART, pos);
        S(v, SCI_SETTARGETEND, length);
        sptr_t found = S(v, SCI_SEARCHINTARGET, needle.length, (sptr_t)needle.bytes);
        sptr_t status = S(v, SCI_GETSTATUS);
        if (status == SC_STATUS_WARN_REGEX) { result = -1; break; }
        if (status != SC_STATUS_OK) { result = -3; break; }
        if (found < 0) break;
        sptr_t line = S(v, SCI_LINEFROMPOSITION, found);
        if (line != previousLine) { lines.push_back(line); previousLine = line; }
        sptr_t matchEnd = S(v, SCI_GETTARGETEND);
        if (matchEnd > found) pos = matchEnd;
        else {   // 空字串符合（^、$ 等）：往後移一個字元
            sptr_t next = S(v, SCI_POSITIONAFTER, found);
            if (next <= found || next > length) break;
            pos = next;
        }
    }
    S(v, SCI_SETSTATUS, SC_STATUS_OK);
    S(v, SCI_SETTARGETSTART, savedStart);
    S(v, SCI_SETTARGETEND, savedEnd);
    if (result < 0) return result;

    // 先補上新的標記，失敗時還原，保留上一次的搜尋結果
    const unsigned mask = 1u << N2SearchBookmark;
    std::vector<sptr_t> added;
    for (sptr_t line : lines) {
        if (S(v, SCI_MARKERGET, line) & mask) continue;
        if (S(v, SCI_MARKERADD, line, N2SearchBookmark) < 0) {
            for (sptr_t a : added) S(v, SCI_MARKERDELETE, a, N2SearchBookmark);
            return -3;
        }
        added.push_back(line);
    }
    // 移除不在這次結果中的舊搜尋標記
    size_t keep = 0;
    for (sptr_t line = S(v, SCI_MARKERNEXT, 0, mask); line >= 0; line = S(v, SCI_MARKERNEXT, line + 1, mask)) {
        while (keep < lines.size() && lines[keep] < line) keep++;
        if (keep == lines.size() || lines[keep] != line) S(v, SCI_MARKERDELETE, line, N2SearchBookmark);
    }
    return (NSInteger)lines.size();
}

#pragma mark - .2xs 書籤與檢視狀態

// 書籤設定檔對應的文件：壓縮檔內文件用壓縮檔＋成員路徑
- (NSURL *)bookmarkURL:(NSString **)member {
    Document *doc = self.doc;
    *member = nil;
    if (doc.archiveLink && [doc.fileURL.path isEqualToString:doc.archiveLink.workURL.path]) {
        *member = doc.archiveLink.memberPath;
        return doc.archiveLink.archiveURL;
    }
    if (N2IsArchiveWorkURL(doc.fileURL)) return nil;   // 壓縮檔還在開啟中：成員資訊設定好後再載入
    return doc.fileURL;
}

- (void)loadBookmarks {
    NSString *member = nil;
    NSURL *url = [self bookmarkURL:&member];
    [self.bookmarks loadInto:self.primarySci url:url member:member locked:self.doc.isCryptoLocked];
}

- (void)loadBookmarksAfterUnlock { [self.bookmarks loadAfterUnlock:self.primarySci]; }

- (BOOL)saveBookmarks:(N2BookmarkSaveMode)mode {
    NSString *member = nil;
    NSURL *url = [self bookmarkURL:&member];
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return NO;
    // 分割檢視：以目前使用的窗格為準
    return [self.bookmarks save:self.sci url:url member:member locked:self.doc.isCryptoLocked mode:mode];
}

#pragma mark - 顯示字元資訊

static NSString *CharacterName(uint32_t cp) {
    switch (cp) {
        case ' ': return N2L(@"半形空白");
        case '\t': return N2L(@"定位字元（Tab）");
        case '\r': return N2L(@"歸位字元（CR）");
        case '\n': return N2L(@"換行字元（LF）");
        case 0x00A0: return N2L(@"不換行空白");
        case 0x200B: return N2L(@"零寬空白");
        case 0x3000: return N2L(@"全形空白");
        default:
            if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) || (cp >= 0x200C && cp <= 0x200F) ||
                (cp >= 0x2028 && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x206F) || cp == 0xFEFF)
                return N2L(@"控制或格式字元");
            return nil;
    }
}

- (NSString *)characterInfoText {
    ScintillaView *v = self.sci;
    sptr_t main = S(v, SCI_GETMAINSELECTION);
    sptr_t a = S(v, SCI_GETSELECTIONNSTART, main), b = S(v, SCI_GETSELECTIONNEND, main);
    sptr_t pos = a < b ? a : S(v, SCI_GETCURRENTPOS);
    if (pos < 0 || pos >= S(v, SCI_GETLENGTH)) return N2L(@"此處沒有可顯示的字元。");
    int first = (int)(unsigned char)S(v, SCI_GETCHARAT, pos);
    // Scintilla 把 CRLF 當成一步，CR 單獨檢視
    sptr_t next = first == '\r' ? pos + 1 : S(v, SCI_POSITIONAFTER, pos);
    if (next <= pos || next - pos > 4) return N2L(@"無法以目前的文件編碼解讀此字元。");
    std::string bytes((const char *)S(v, SCI_GETRANGEPOINTER, pos, next - pos), (size_t)(next - pos));
    NSString *glyph = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
    if (!glyph.length) return N2L(@"無法以目前的文件編碼解讀此字元。");
    uint32_t cp = 0;
    [glyph getBytes:&cp maxLength:4 usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0
              range:NSMakeRange(0, glyph.length) remainingRange:NULL];
    NSMutableArray *hex = [NSMutableArray array];
    for (unsigned char c : bytes) [hex addObject:[NSString stringWithFormat:@"%02X", c]];
    NSString *name = CharacterName(cp) ?: glyph;
    return [NSString stringWithFormat:@"%@: %@\n%@: U+%04X\nUTF-8: %@", N2L(@"字元"), name, N2L(@"Unicode 碼位"), cp,
            [hex componentsJoinedByString:@" "]];
}

- (IBAction)showCharacterInfo:(id)sender {
    NSString *info = [self characterInfoText];
    NSAlert *a = [NSAlert new];
    a.messageText = N2L(@"顯示字元資訊");
    a.informativeText = info;
    [a addButtonWithTitle:N2L(@"關閉")];
    [a addButtonWithTitle:N2L(@"複製資訊")];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertSecondButtonReturn) return;
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:info forType:NSPasteboardTypeString];
    }];
}

#pragma mark - JSON 處理

- (void)jsonWarn:(NSString *)message {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = N2L(@"JSON 工具");
    a.informativeText = message;
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)formatJson:(BOOL)pretty {
    ScintillaView *v = self.sci;
    if (S(v, SCI_GETREADONLY)) { [self rejectIfReadOnly]; return; }
    if (S(v, SCI_GETSELECTIONMODE) != SC_SEL_STREAM || S(v, SCI_GETSELECTIONS) != 1 || !S(v, SCI_GETLENGTH)) { NSBeep(); return; }
    sptr_t length = S(v, SCI_GETLENGTH);
    sptr_t a = S(v, SCI_GETSELECTIONSTART), b = S(v, SCI_GETSELECTIONEND);
    BOOL selected = a != b;
    sptr_t start = selected ? a : 0, end = selected ? b : length;
    if ((size_t)(end - start) > xs::json::textLimit) { [self jsonWarn:N2L(@"JSON 超過大小或巢狀層數上限。原文未變更。")]; return; }
    std::string original((const char *)S(v, SCI_GETRANGEPOINTER, start, end - start), (size_t)(end - start));
    if (![[NSString alloc] initWithBytes:original.data() length:original.size() encoding:NSUTF8StringEncoding]) {
        [self jsonWarn:N2L(@"文字無法依文件編碼無損轉換。原文未變更。")];
        return;
    }
    int eol = (int)S(v, SCI_GETEOLMODE);
    std::string output;
    try {
        output = xs::json::formatUtf8(original, pretty, eol == SC_EOL_CRLF ? "\r\n" : eol == SC_EOL_CR ? "\r" : "\n");
    } catch (const xs::json::Error &e) {
        if (e.kind == xs::json::ErrorKind::limit) { [self jsonWarn:N2L(@"JSON 超過大小或巢狀層數上限。原文未變更。")]; return; }
        sptr_t p = start + (sptr_t)e.position;
        [self jsonWarn:[NSString stringWithFormat:N2L(@"JSON 語法錯誤，位置為第 %ld 行、第 %ld 欄。原文未變更。"),
                        (long)S(v, SCI_LINEFROMPOSITION, p) + 1, (long)S(v, SCI_GETCOLUMN, p) + 1]];
        return;
    } catch (...) {
        [self jsonWarn:N2L(@"無法完成 JSON 編輯。原文未變更。")];
        return;
    }
    if (output == original) return;
    sptr_t anchor = S(v, SCI_GETANCHOR), caret = S(v, SCI_GETCURRENTPOS);
    S(v, SCI_BEGINUNDOACTION);
    S(v, SCI_SETTARGETRANGE, start, end);
    S(v, SCI_REPLACETARGET, output.size(), (sptr_t)output.data());
    S(v, SCI_ENDUNDOACTION);
    // 確認內容正確寫入；不一致就復原
    BOOL ok = S(v, SCI_GETLENGTH) == length - (end - start) + (sptr_t)output.size() &&
              memcmp((const char *)S(v, SCI_GETRANGEPOINTER, start, output.size()), output.data(), output.size()) == 0;
    if (!ok) {
        S(v, SCI_UNDO);
        S(v, SCI_SETSEL, anchor, caret);
        [self jsonWarn:N2L(@"無法完成 JSON 編輯。原文未變更。")];
        return;
    }
    sptr_t newEnd = start + (sptr_t)output.size();
    if (selected) S(v, SCI_SETSEL, anchor <= caret ? start : newEnd, anchor <= caret ? newEnd : start);
    else S(v, SCI_GOTOPOS, start);
}

- (IBAction)formatJsonPretty:(id)sender { [self formatJson:YES]; }
- (IBAction)showHtmlLayout:(id)sender { N2ShowHtmlLayout(self); }
- (IBAction)formatJsonMinify:(id)sender { [self formatJson:NO]; }

@end
