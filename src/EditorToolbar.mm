// 視窗工具列：對應 Windows 版 tbbMainWnd（預設 18 個按鈕、分 7 組），其餘按鈕可從「自訂工具列…」加入
// 使用 macOS 原生 NSToolbar：右鍵 → 自訂工具列，可拖曳新增／移除／排序；排列自動保存，所有視窗同步
#import "EditorWindowController.h"
#import "Document.h"
#import "Localization.h"
#include "Scintilla.h"

namespace {
struct ToolDef {
    const char *ident;   // 工具列項目識別碼（也用於保存排列）
    SEL action;
    const char *symbol;  // SF Symbols 名稱（名稱與快捷鍵取自主選單裡的同一指令）
};

// 原版 37 個可用按鈕中，Mac 版有對應功能的部分，再加上 Mac 版已有的常用指令
const ToolDef kTools[] = {
    {"new",        @selector(newDocument:),          "doc.badge.plus"},
    {"open",       @selector(openDocument:),         "folder"},
    {"save",       @selector(saveDocument:),         "square.and.arrow.down"},
    {"print",      @selector(printDocument:),        "printer"},
    {"undo",       @selector(undo:),                 "arrow.uturn.backward"},
    {"redo",       @selector(redo:),                 "arrow.uturn.forward"},
    {"cut",        @selector(cut:),                  "scissors"},
    {"copy",       @selector(copy:),                 "doc.on.doc"},
    {"paste",      @selector(paste:),                "doc.on.clipboard"},
    {"find",       @selector(showFindPanel:),        "magnifyingglass"},
    {"replace",    @selector(showReplacePanel:),     "arrow.left.arrow.right"},
    {"wrap",       @selector(toggleWordWrap:),       "arrow.turn.down.left"},
    {"zoomin",     @selector(zoomInText:),           "plus.magnifyingglass"},
    {"zoomout",    @selector(zoomOutText:),          "minus.magnifyingglass"},
    {"exec",       @selector(executeSelection:),     "play.fill"},
    {"ai",         @selector(runAI:),                "bubble.left.and.bubble.right"},
    {"exesenc",    @selector(exesEncrypt:),          "lock.fill"},
    {"exesdec",    @selector(exesDecrypt:),          "lock.open.fill"},
    // 以下預設不顯示，可從自訂工具列加入
    {"saveas",     @selector(saveDocumentAs:),       "square.and.arrow.down.on.square"},
    {"revert",     @selector(revertDocumentToSaved:),"arrow.clockwise"},
    {"history",    @selector(showVersionHistory:),   "clock.arrow.circlepath"},
    {"filesearch", @selector(showFileSearch:),       "doc.text.magnifyingglass"},
    {"clear",      @selector(clear:),                "delete.left"},
    {"findnext",   @selector(findNextText:),         "chevron.down"},
    {"findprev",   @selector(findPreviousText:),     "chevron.up"},
    {"goto",       @selector(goToLine:),             "arrow.down.to.line"},
    {"sort",       @selector(sortLines:),            "arrow.up.arrow.down"},
    {"csv",        @selector(showCsvTable:),         "tablecells"},
    {"aesenc",     @selector(aesEncrypt:),           "lock.shield"},
    {"aesdec",     @selector(aesDecrypt:),           "lock.open"},
    {"exmd3",      @selector(exmd3Hash:),            "number"},
    {"zoomreset",  @selector(zoomResetText:),        "1.magnifyingglass"},
    {"linenum",    @selector(toggleLineNumbers:),    "list.number"},
    {"invert",     @selector(toggleInvertColors:),   "circle.lefthalf.fill"},
    {"font",       @selector(showEditorFont:),       "textformat"},
    {"splitv",     @selector(splitVertical:),        "rectangle.split.2x1"},
    {"splith",     @selector(splitHorizontal:),      "rectangle.split.1x2"},
    {"splitnone",  @selector(splitNone:),            "rectangle"},
    {"ontop",      @selector(toggleAlwaysOnTop:),    "pin"},
    {"fullscreen", @selector(toggleFullScreen:),     "arrow.up.left.and.arrow.down.right"},
    {"settings",   @selector(showPreferences:),      "gearshape"},
    {"erase",      @selector(secureEraseFile:),      "trash"},
};

NSString *Ident(const ToolDef &t) { return [@"n2." stringByAppendingString:@(t.ident)]; }

const ToolDef *FindTool(NSString *ident) {
    for (auto &t : kTools) if ([Ident(t) isEqualToString:ident]) return &t;
    return nullptr;
}

// 分隔線：對應原版 TBSTYLE_SEP。NSToolbarSeparatorItemIdentifier／SpaceItemIdentifier 自 macOS 11 起已棄用，
// 改用自訂項目；同一識別碼只能出現一次，因此準備多個編號
const int kSeparatorCount = 12;
NSString *SeparatorIdent(int i) { return [NSString stringWithFormat:@"n2.sep.%d", i]; }
BOOL IsSeparator(NSString *ident) { return [ident hasPrefix:@"n2.sep."]; }

// 原版預設：檔案｜復原｜剪貼簿｜搜尋｜閱讀｜執行｜加解密（組與組之間是分隔線）
NSArray<NSString *> *DefaultIdents() {
    NSMutableArray *a = [NSMutableArray array];
    const char *groups[][4] = {{"new", "open", "save", "print"}, {"undo", "redo"}, {"cut", "copy", "paste"},
                               {"find", "replace"}, {"wrap", "zoomin", "zoomout"}, {"exec", "ai"}, {"exesenc", "exesdec"}};
    int sep = 0;
    for (auto &g : groups) {
        if (a.count) [a addObject:SeparatorIdent(++sep)];
        for (const char *n : g) if (n) [a addObject:[@"n2." stringByAppendingString:@(n)]];
    }
    return a;
}

// 從主選單找同一指令：沿用已翻譯的名稱與快捷鍵，選單改了工具列也跟著一致
NSMenuItem *MenuItemFor(NSMenu *menu, SEL action) {
    for (NSMenuItem *it in menu.itemArray) {
        if (it.action == action) return it;
        if (it.submenu) if (NSMenuItem *f = MenuItemFor(it.submenu, action)) return f;
    }
    return nil;
}

NSString *ShortcutText(NSMenuItem *it) {
    if (!it.keyEquivalent.length) return nil;
    NSEventModifierFlags m = it.keyEquivalentModifierMask;
    NSMutableString *s = [NSMutableString string];
    if (m & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption) [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift) [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    unichar c = [it.keyEquivalent characterAtIndex:0];
    if (c >= NSF1FunctionKey && c <= NSF12FunctionKey) [s appendFormat:@"F%d", c - NSF1FunctionKey + 1];
    else if (c == ' ') [s appendString:@"Space"];
    else [s appendString:it.keyEquivalent.uppercaseString];
    return s;
}
}

// 分隔線外觀：置中的一條細直線
@interface N2ToolbarSeparatorView : NSView
@end
@implementation N2ToolbarSeparatorView
- (NSSize)intrinsicContentSize { return NSMakeSize(11, 22); }
- (void)drawRect:(NSRect)r {
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(floor(NSMidX(self.bounds)), 3, 1, NSHeight(self.bounds) - 6));
}
@end

@implementation EditorWindowController (Toolbar)

- (void)setupToolbar {
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"N2MainToolbar"];
    tb.delegate = self;
    tb.allowsUserCustomization = YES;
    tb.autosavesConfiguration = YES;          // 排列與顯示方式存在使用者偏好設定
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    if (@available(macOS 11.0, *)) self.window.toolbarStyle = NSWindowToolbarStyleExpanded;   // 標題在上、工具列在下
    self.window.toolbar = tb;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar { return DefaultIdents(); }

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    NSMutableArray *a = [NSMutableArray array];
    for (auto &t : kTools) [a addObject:Ident(t)];
    for (int i = 1; i <= kSeparatorCount; i++) [a addObject:SeparatorIdent(i)];
    [a addObject:NSToolbarFlexibleSpaceItemIdentifier];
    return a;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    if (IsSeparator(ident)) {
        NSToolbarItem *sep = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
        sep.view = [N2ToolbarSeparatorView new];
        sep.label = @"";
        sep.paletteLabel = N2L(@"分隔線");
        return sep;
    }
    const ToolDef *t = FindTool(ident);
    if (!t) return nil;
    NSMenuItem *mi = MenuItemFor(NSApp.mainMenu, t->action);
    NSString *name = mi.title.length ? mi.title : ident;
    if ([name hasSuffix:@"…"]) name = [name substringToIndex:name.length - 1];
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.label = name;
    item.paletteLabel = name;
    NSString *key = ShortcutText(mi);
    item.toolTip = key ? [NSString stringWithFormat:@"%@（%@）", name, key] : name;
    NSImage *img = [NSImage imageWithSystemSymbolName:@(t->symbol) accessibilityDescription:name];
    item.image = img ?: [NSImage imageNamed:NSImageNameActionTemplate];
    item.action = t->action;
    item.target = nil;                         // 經 responder chain：作用中的編輯區 → 視窗 → 文件 → App
    if (@available(macOS 11.0, *)) item.bordered = YES;
    return item;
}

// 與選單共用同一套規則（EditorWindowController 的 isActionAvailable:）
- (BOOL)validateToolbarItem:(NSToolbarItem *)item { return [self isActionAvailable:item.action]; }

#pragma mark - 選單：檢視 → 工具列
// 不直接用 NSWindow 的 toggleToolbarShown:／runToolbarCustomizationPalette:：
// NSWindow 驗證選單時會把標題改成系統語言的「Show/Hide Toolbar」，蓋掉 App 自己的介面語言

- (IBAction)toggleToolbarVisible:(id)sender {
    NSToolbar *tb = self.window.toolbar;
    tb.visible = !tb.visible;
}

- (IBAction)customizeToolbar:(id)sender { [self.window runToolbarCustomizationPalette:sender]; }

// 還原原版預設排列（同一識別碼的工具列會同步到所有視窗）
- (IBAction)resetToolbar:(id)sender {
    NSToolbar *tb = self.window.toolbar;
    while (tb.items.count) [tb removeItemAtIndex:0];
    NSArray *ids = DefaultIdents();
    for (NSUInteger i = 0; i < ids.count; i++) [tb insertItemWithItemIdentifier:ids[i] atIndex:(NSInteger)i];
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    tb.visible = YES;
}

- (IBAction)toggleAlwaysOnTop:(id)sender {
    self.window.level = self.window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
}

@end
