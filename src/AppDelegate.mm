#import "AppDelegate.h"
#import "EditorWindowController.h"
#import "Settings.h"
#import "SyntaxStyles.h"
#import "TextEncoding.h"
#import "PreferencesWindow.h"
#import "Document.h"
#import "ArchiveEdit.h"
#import "AiUI.h"
#import "Localization.h"
#include "Scintilla.h"

// 選單動作大多實作在 EditorWindowController（含 EditorCommands.mm），經由 responder chain 傳遞

static NSMenuItem *Item(NSMenu *menu, NSString *title, SEL action, NSString *key,
                        NSEventModifierFlags mods = NSEventModifierFlagCommand, NSInteger tag = 0) {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:N2L(title) action:action keyEquivalent:key ?: @""];
    if (key.length) it.keyEquivalentModifierMask = mods;
    it.tag = tag;
    [menu addItem:it];
    return it;
}

static NSMenu *Submenu(NSMenu *parent, NSString *title) {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:N2L(title) action:nil keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:N2L(title)];
    it.submenu = m;
    [parent addItem:it];
    return m;
}

static void Sep(NSMenu *m) { [m addItem:NSMenuItem.separatorItem]; }
static NSString *Key(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

// 攔截壓縮檔：先選成員、解到暫存檔，再以一般文件開啟
void N2ShowFileSearch(void);

@interface N2DocumentController : NSDocumentController
@end

@implementation N2DocumentController
// 啟動時自動建立、還沒動過的空白文件：開啟檔案後關掉它（與 TextEdit 相同），不會留下多餘的「未命名」分頁
- (Document *)transientDocument {
    NSArray *docs = self.documents;
    if (docs.count != 1 || ![docs[0] isKindOfClass:Document.class]) return nil;
    Document *d = docs[0];
    if (d.fileURL || d.isDocumentEdited || d.editor.textAsUTF8.length) return nil;
    return d;
}

- (void)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display
                    completionHandler:(void (^)(NSDocument *, BOOL, NSError *))original {
    Document *transient = [self transientDocument];
    void (^handler)(NSDocument *, BOOL, NSError *) = ^(NSDocument *doc, BOOL already, NSError *e) {
        if (doc && !already && transient && doc != transient && !transient.isDocumentEdited) [transient close];
        original(doc, already, e);
    };
    if (N2ArchiveKindForURL(url) == N2ArchiveNone) {
        [super openDocumentWithContentsOfURL:url display:display completionHandler:handler];
        return;
    }
    [N2ArchiveLink openArchive:url completion:^(N2ArchiveLink *link, NSError *error) {
        if (!link) {
            if (error) [self presentError:error];
            handler(nil, NO, nil);
            return;
        }
        [super noteNewRecentDocumentURL:link.archiveURL];
        [super openDocumentWithContentsOfURL:link.workURL display:display
                           completionHandler:^(NSDocument *doc, BOOL already, NSError *e) {
            if ([doc isKindOfClass:Document.class]) {
                ((Document *)doc).archiveLink = link;
                for (NSWindowController *wc in doc.windowControllers) [wc synchronizeWindowTitleWithDocumentName];
            } else {
                [link cleanup];
            }
            handler(doc, already, e);
        }];
    }];
}

// 暫存工作檔不加入「最近使用的檔案」
- (void)noteNewRecentDocumentURL:(NSURL *)url {
    if (!N2IsArchiveWorkURL(url)) [super noteNewRecentDocumentURL:url];
}
@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)n {
    [N2DocumentController new];   // 第一個建立的 NSDocumentController 會成為共用實例
    [N2Settings registerDefaults];
    N2ApplyLanguagePreference();   // 系統的開啟／儲存視窗使用相同語言（下次啟動生效）
    [self buildMainMenu];
    N2InstallTabMiddleClick();
}

// 沒有任何文件視窗時按 ⌘T：開一份新文件
- (IBAction)newWindowForTab:(id)sender { [NSDocumentController.sharedDocumentController newDocument:sender]; }

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (IBAction)showPreferences:(id)sender { [N2PreferencesWindow.shared showWindow:sender]; }
- (IBAction)showAiSettings:(id)sender { [N2AiSettingsWindow show]; }
- (IBAction)showFileSearch:(id)sender { N2ShowFileSearch(); }

- (IBAction)showAbout:(id)sender {
    NSString *credits =
        @"專家記事本 NotePad2-XS 的 macOS 移植版\n\n"
        @"以 Notepad2（Florian Balmer）、Notepad2e 與 NotePad2-XS 為基礎，BSD 授權。\n"
        @"編輯元件：Scintilla 3.11.2（Neil Hodgson，HPND 授權）\n"
        @"JSON：Boost.JSON 1.85（Boost Software License）\n"
        @"數學運算：tinyexpr（zlib 授權）\n\n"
        @"EXES／AES／EX_MD3 加密格式與 Windows 版相容。";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSAttributedString *c = [[NSAttributedString alloc] initWithString:credits attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11], NSParagraphStyleAttributeName: ps,
        NSForegroundColorAttributeName: NSColor.labelColor}];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionCredits: c,
        NSAboutPanelOptionApplicationName: @"Notepad2XS"}];
}
- (IBAction)showAiTemplates:(id)sender { [N2AiTemplateWindow showWithCompletion:nil]; }

- (void)buildMainMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    NSString *appName = @"Notepad2XS";
    const NSEventModifierFlags C = NSEventModifierFlagCommand, S = NSEventModifierFlagShift,
                               O = NSEventModifierFlagOption, K = NSEventModifierFlagControl;

    // App
    NSMenu *app = Submenu(main, appName);
    Item(app, [NSString stringWithFormat:N2L(@"關於 %@"), appName], @selector(showAbout:), nil);
    Sep(app);
    Item(app, @"設定…", @selector(showPreferences:), @",");
    Sep(app);
    NSMenu *services = Submenu(app, @"服務");
    NSApp.servicesMenu = services;
    Sep(app);
    Item(app, [NSString stringWithFormat:N2L(@"隱藏 %@"), appName], @selector(hide:), @"h");
    Item(app, @"隱藏其他", @selector(hideOtherApplications:), @"h", C | O);
    Item(app, @"全部顯示", @selector(unhideAllApplications:), nil);
    Sep(app);
    Item(app, [NSString stringWithFormat:N2L(@"結束 %@"), appName], @selector(terminate:), @"q");

    // 檔案
    NSMenu *file = Submenu(main, @"檔案");
    Item(file, @"新增", @selector(newDocument:), @"n");
    Item(file, @"新增分頁", @selector(newWindowForTab:), @"t");
    Item(file, @"開啟…", @selector(openDocument:), @"o");
    NSMenu *recent = Submenu(file, @"打開最近使用的檔案");
    Item(recent, @"清除選單", @selector(clearRecentDocuments:), nil);   // 系統會自動填入最近檔案
    Sep(file);
    Item(file, @"關閉", @selector(performClose:), @"w");
    Item(file, @"儲存", @selector(saveDocument:), @"s");
    Item(file, @"另存新檔…", @selector(saveDocumentAs:), @"s", C | S);
    Item(file, @"回復到已儲存", @selector(revertDocumentToSaved:), nil);
    Sep(file);
    NSMenu *enc = Submenu(file, @"編碼（存檔用）");
    NSMenu *reopen = Submenu(file, @"以指定編碼重新載入");
    for (NSInteger e = 0; e < N2EncodingCount; e++) {
        Item(enc, N2EncodingDisplayName((N2Encoding)e), @selector(setSaveEncoding:), nil, 0, e);
        Item(reopen, N2EncodingDisplayName((N2Encoding)e), @selector(reopenWithEncoding:), nil, 0, e);
    }
    NSMenu *eol = Submenu(file, @"換行格式");
    Item(eol, @"Windows（CRLF）", @selector(setLineEnding:), nil, 0, SC_EOL_CRLF);
    Item(eol, @"Unix / macOS（LF）", @selector(setLineEnding:), nil, 0, SC_EOL_LF);
    Item(eol, @"舊版 Mac（CR）", @selector(setLineEnding:), nil, 0, SC_EOL_CR);
    Sep(file);
    Item(file, @"搜尋檔案…", @selector(showFileSearch:), @"f", C | S);
    Item(file, @"版本歷史…", @selector(showVersionHistory:), nil);
    Item(file, @"安全刪除目前檔案…", @selector(secureEraseFile:), nil);
    Sep(file);
    Item(file, @"頁面設定…", @selector(runPageLayout:), @"p", C | S);
    Item(file, @"列印…", @selector(printDocument:), @"p");

    // 編輯
    NSMenu *edit = Submenu(main, @"編輯");
    Item(edit, @"復原", @selector(undo:), @"z");
    Item(edit, @"重做", @selector(redo:), @"z", C | S);
    Sep(edit);
    Item(edit, @"剪下", @selector(cut:), @"x");
    Item(edit, @"拷貝", @selector(copy:), @"c");
    Item(edit, @"貼上", @selector(paste:), @"v");
    Item(edit, @"刪除", @selector(clear:), nil);
    Item(edit, @"全選", @selector(selectAll:), @"a");
    Sep(edit);
    Item(edit, @"尋找…", @selector(showFindPanel:), @"f");
    Item(edit, @"取代…", @selector(showReplacePanel:), @"f", C | O);
    Item(edit, @"找下一個", @selector(findNextText:), @"g");
    Item(edit, @"找上一個", @selector(findPreviousText:), @"g", C | S);
    Item(edit, @"使用選取的文字尋找", @selector(useSelectionForFind:), @"e");
    Item(edit, @"跳至行…", @selector(goToLine:), @"l");
    Sep(edit);
    Item(edit, @"表格模式（CSV／TSV）…", @selector(showCsvTable:), nil);
    Sep(edit);
    NSMenu *lineOps = Submenu(edit, @"行操作");
    Item(lineOps, @"上移", @selector(moveLineUp:), Key(NSUpArrowFunctionKey), C | O);
    Item(lineOps, @"下移", @selector(moveLineDown:), Key(NSDownArrowFunctionKey), C | O);
    Item(lineOps, @"在上方新增一行", @selector(newLineAbove:), @"\r", C | S);
    Item(lineOps, @"在下方新增一行", @selector(newLineBelow:), @"\r", C);
    Sep(lineOps);
    Item(lineOps, @"複製目前行", @selector(duplicateLine:), @"d", C | S);
    Item(lineOps, @"剪下目前行", @selector(cutLine:), nil);
    Item(lineOps, @"拷貝目前行", @selector(copyLine:), nil);
    Item(lineOps, @"刪除目前行", @selector(deleteLine:), @"k", K | S);
    NSMenu *block = Submenu(edit, @"區塊編輯");
    Item(block, @"在選取範圍前後加入文字…", @selector(encloseSelection:), nil);
    Item(block, @"複製選取範圍", @selector(duplicateSelection:), nil);
    NSMenu *comment = Submenu(edit, @"註解");
    Item(comment, @"切換行註解", @selector(toggleLineComment:), @"/");
    Item(comment, @"區塊註解", @selector(toggleBlockComment:), @"/", C | O);
    Sep(edit);
    Item(edit, @"開始聽寫…", @selector(startDictation:), nil);
    Item(edit, @"表情符號與符號", @selector(orderFrontCharacterPalette:), @" ", C | K);

    // 檢視
    NSMenu *view = Submenu(main, @"檢視");
    Item(view, @"進入全螢幕", @selector(toggleFullScreen:), @"f", C | K);
    Item(view, @"最上層顯示", @selector(toggleAlwaysOnTop:), nil);
    Sep(view);
    Item(view, @"工具列", @selector(toggleToolbarVisible:), @"t", C | O);
    Item(view, @"自訂工具列…", @selector(customizeToolbar:), nil);
    Item(view, @"重設工具列", @selector(resetToolbar:), nil);
    Item(view, @"狀態列", @selector(toggleStatusBar:), nil);
    Item(view, @"行號", @selector(toggleLineNumbers:), nil);
    Item(view, @"縮排輔助線", @selector(toggleIndentGuides:), nil);
    Item(view, @"長行標記", @selector(toggleLongLineMarker:), nil);
    NSMenu *marks = Submenu(view, @"顯示字元與符號");
    Item(marks, @"空白字元", @selector(toggleWhitespace:), nil);
    Item(marks, @"換行字元", @selector(toggleEOLMarks:), nil);
    Item(marks, @"自動換行符號", @selector(toggleWrapSymbols:), nil);
    Sep(view);
    Item(view, @"標示對應括號", @selector(toggleMatchBraces:), nil);
    Item(view, @"醒目提示目前行", @selector(toggleHighlightLine:), nil);
    Item(view, @"醒目提示相同文字", @selector(toggleHighlightSelection:), nil);
    Item(view, @"反向色彩", @selector(toggleInvertColors:), nil);
    Sep(view);
    NSMenu *split = Submenu(view, @"分割視窗");
    Item(split, @"不分割", @selector(splitNone:), nil);
    Item(split, @"上下分割", @selector(splitHorizontal:), nil);
    Item(split, @"左右分割", @selector(splitVertical:), nil);
    Sep(view);
    Item(view, @"放大", @selector(zoomInText:), @"=");
    Item(view, @"縮小", @selector(zoomOutText:), @"-");
    Item(view, @"實際大小", @selector(zoomResetText:), @"0");

    // 插入
    NSMenu *insert = Submenu(main, @"插入");
    Item(insert, @"時間／日期（簡短）", @selector(insertDateTime:), nil);
    Item(insert, @"時間／日期（完整）", @selector(insertLongDateTime:), nil);
    Sep(insert);
    Item(insert, @"檔案名稱", @selector(insertFileName:), nil);
    Item(insert, @"路徑與檔案名稱", @selector(insertFilePath:), nil);

    // 格式
    NSMenu *format = Submenu(main, @"格式");
    Item(format, @"字型…", @selector(showEditorFont:), @"t", C | K);   // ⌘T 讓給「新增分頁」
    NSMenu *lang = Submenu(format, @"語法上色");
    Item(lang, @"自動（依副檔名）", @selector(selectLanguage:), nil, 0, -1);
    Sep(lang);
    NSArray *ids = N2SyntaxLanguageIDs();
    for (NSInteger i = 0; i < (NSInteger)ids.count; i++)
        Item(lang, N2SyntaxDisplayName(ids[i]), @selector(selectLanguage:), nil, 0, i);
    Sep(format);
    Item(format, @"自動換行", @selector(toggleWordWrap:), nil);
    NSMenu *wrap = Submenu(format, @"換行與段落");
    Item(wrap, @"依欄寬換行…", @selector(wrapToColumn:), nil);
    Item(wrap, @"依視窗寬度拆分行", @selector(splitLinesToWindow:), nil);
    Sep(wrap);
    Item(wrap, @"合併行", @selector(joinLines:), @"j");
    Item(wrap, @"合併行（不加空格）", @selector(joinLinesNoSpace:), @"j", C | O);
    Item(wrap, @"合併段落", @selector(joinParagraphs:), @"j", C | S);
    Item(wrap, @"合併段落（不加空格）", @selector(joinParagraphsNoSpace:), @"j", C | O | S);
    NSMenu *indent = Submenu(format, @"縮排與定位字元");
    Item(indent, @"增加縮排", @selector(indentLines:), @"]");
    Item(indent, @"減少縮排", @selector(unindentLines:), @"[");
    Item(indent, @"自動縮排", @selector(toggleAutoIndent:), nil);
    Item(indent, @"以空格代替定位字元", @selector(toggleTabsAsSpaces:), nil);
    Sep(indent);
    Item(indent, @"將空格轉為定位字元", @selector(convertSpacesToTabs:), nil);
    Item(indent, @"將定位字元轉為空格", @selector(convertTabsToSpaces:), nil);
    Item(indent, @"將縮排空格轉為定位字元", @selector(convertIndentSpacesToTabs:), nil);
    Item(indent, @"將縮排定位字元轉為空格", @selector(convertIndentTabsToSpaces:), nil);
    NSMenu *cases = Submenu(format, @"大小寫");
    Item(cases, @"轉為大寫", @selector(makeUpperCase:), @"u", C | S);
    Item(cases, @"轉為小寫", @selector(makeLowerCase:), @"u", C | O);
    Item(cases, @"切換大小寫", @selector(invertCase:), nil);
    Item(cases, @"每個字首大寫", @selector(titleCase:), nil);
    Item(cases, @"句首大寫", @selector(sentenceCase:), nil);
    NSMenu *ws = Submenu(format, @"空白與字元整理");
    Item(ws, @"以空格補齊", @selector(padWithSpaces:), nil);
    Item(ws, @"移除首字元", @selector(stripFirstChar:), nil);
    Item(ws, @"移除末字元", @selector(stripLastChar:), nil);
    Sep(ws);
    Item(ws, @"移除行尾空白", @selector(trimTrailingWhitespace:), nil);
    Item(ws, @"壓縮空白字元", @selector(compressWhitespace:), nil);
    Item(ws, @"合併空白行", @selector(mergeBlankLines:), nil);
    Item(ws, @"移除空白行", @selector(removeBlankLines:), nil);
    NSMenu *money = Submenu(format, @"數字轉換");
    Item(money, @"數字轉中文金額", @selector(moneyCommon:), nil);
    Item(money, @"數字轉中文大寫金額", @selector(moneyFinancial:), nil);
    NSMenu *sort = Submenu(format, @"對齊與排序");
    Item(sort, @"修改行…", @selector(modifyLines:), nil);
    Item(sort, @"排序／移除重複行…", @selector(sortLines:), nil);

    // 工具
    NSMenu *tools = Submenu(main, @"工具");
    Item(tools, @"執行選取", @selector(executeSelection:), Key(NSF5FunctionKey), 0);
    Sep(tools);
    NSMenu *ai = Submenu(tools, @"人工智慧");
    Item(ai, @"執行人工智慧指令…", @selector(runAI:), @"a", C | K);
    Sep(ai);
    Item(ai, @"連接設定…", @selector(showAiSettings:), nil);
    Item(ai, @"指令範本…", @selector(showAiTemplates:), nil);
    Sep(tools);
    NSMenu *crypto = Submenu(tools, @"加解密");
    Item(crypto, @"EXES 加密…", @selector(exesEncrypt:), nil);
    Item(crypto, @"EXES 解密…", @selector(exesDecrypt:), nil);
    Sep(crypto);
    Item(crypto, @"AES 加密…", @selector(aesEncrypt:), nil);
    Item(crypto, @"AES 解密…", @selector(aesDecrypt:), nil);
    Sep(crypto);
    Item(crypto, @"預設密鑰…", @selector(showDefaultKeys:), nil);
    NSMenu *hash = Submenu(tools, @"雜湊計算");
    Item(hash, @"EXMD3 雜湊", @selector(exmd3Hash:), nil);
    Sep(tools);
    NSMenu *codec = Submenu(tools, @"編碼與解碼");
    Item(codec, @"Base64 編碼", @selector(base64Encode:), nil);
    Item(codec, @"Base64 解碼", @selector(base64Decode:), nil);
    Sep(codec);
    Item(codec, @"URL 編碼", @selector(urlEncode:), nil);
    Item(codec, @"URL 解碼", @selector(urlDecode:), nil);
    Sep(codec);
    Item(codec, @"字串轉為十六進位", @selector(hexEncode:), nil);
    Item(codec, @"十六進位轉為字串", @selector(hexDecode:), nil);
    Sep(codec);
    Item(codec, @"QP 編碼", @selector(qpEncode:), nil);
    Item(codec, @"QP 解碼", @selector(qpDecode:), nil);
    Sep(codec);
    Item(codec, @"字元轉為 C 十六進位", @selector(charToCHex:), nil);
    Item(codec, @"C 十六進位轉為字元", @selector(cHexToChar:), nil);
    Sep(codec);
    Item(codec, @"逸出 C 字元", @selector(escapeCChars:), nil);
    Item(codec, @"還原 C 逸出字元", @selector(unescapeCChars:), nil);
    NSMenu *html = Submenu(tools, @"HTML 處理");
    Item(html, @"移除 HTML 標籤", @selector(stripHTMLTags:), nil);
    Item(html, @"逸出 HTML 標籤", @selector(escapeHTML:), nil);

    // 視窗
    NSMenu *window = Submenu(main, @"視窗");
    Item(window, @"最小化", @selector(performMiniaturize:), @"m");
    Item(window, @"縮放", @selector(performZoom:), nil);
    Sep(window);
    // 分頁（動作由 NSWindow 處理；⌃Tab／⌃⇧Tab 系統內建也可以切換）
    Item(window, @"上一個分頁", @selector(selectPreviousTab:), @"{");
    Item(window, @"下一個分頁", @selector(selectNextTab:), @"}");
    // ⌃Tab／⌃⇧Tab：系統慣用的分頁切換鍵，以隱藏項目提供（選單只顯示上面兩項）
    unichar tabKey = NSTabCharacter, backTab = NSBackTabCharacter;
    NSMenuItem *ctrlTab = Item(window, @"下一個分頁", @selector(selectNextTab:), [NSString stringWithCharacters:&tabKey length:1], K);
    NSMenuItem *ctrlShiftTab = Item(window, @"上一個分頁", @selector(selectPreviousTab:), [NSString stringWithCharacters:&backTab length:1], K | S);
    for (NSMenuItem *it in @[ctrlTab, ctrlShiftTab]) { it.hidden = YES; it.allowsKeyEquivalentWhenHidden = YES; }
    NSMenu *tabNumbers = Submenu(window, @"切換到分頁");
    for (int i = 1; i <= 9; i++)
        Item(tabNumbers, i == 9 ? N2L(@"最後一個分頁") : [NSString stringWithFormat:N2L(@"第 %d 個分頁"), i],
             @selector(selectTabByNumber:), [NSString stringWithFormat:@"%d", i], C, i);
    Item(window, @"顯示所有分頁", @selector(toggleTabOverview:), @"\\", C | S);
    Item(window, @"將分頁移至新視窗", @selector(moveTabToNewWindow:), nil);
    Item(window, @"合併所有視窗", @selector(mergeAllWindows:), nil);
    Sep(window);
    Item(window, @"將此程式所有視窗移至最前", @selector(arrangeInFront:), nil);
    NSApp.windowsMenu = window;

    // 說明
    NSMenu *help = Submenu(main, @"說明");
    NSApp.helpMenu = help;

    NSApp.mainMenu = main;
}

@end
