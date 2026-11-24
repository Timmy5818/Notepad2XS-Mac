#import "PreferencesWindow.h"
#import "Settings.h"
#import "TextEncoding.h"
#import "Localization.h"
#include "Scintilla.h"

@implementation N2PreferencesWindow {
    NSTextField *_fontLabel, *_historyLabel;
}

+ (N2PreferencesWindow *)shared {
    static N2PreferencesWindow *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [[N2PreferencesWindow alloc] init]; });
    return w;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 426)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    win.title = N2L(@"偏好設定");
    if ((self = [super initWithWindow:win])) {
        [self build];
        [win center];
        win.frameAutosaveName = @"Notepad2XSPreferences";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateFontLabel)
                                                   name:N2SettingsChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// 數字後面的單位（版、欄）只在中文介面顯示；其他語言的標籤已經包含意思
static NSString *ChineseUnit(NSString *zh) {
    NSString *lang = N2CurrentLanguage();
    if ([lang isEqualToString:@"zh-Hant"]) return zh;
    if ([lang isEqualToString:@"zh-Hans"]) return [zh isEqualToString:@"欄"] ? @"栏" : zh;
    return @"";
}

static NSUserDefaultsController *UDC(void) { return NSUserDefaultsController.sharedUserDefaultsController; }
static NSString *KP(NSString *key) { return [@"values." stringByAppendingString:key]; }

- (NSButton *)check:(NSString *)title key:(NSString *)key at:(CGFloat)y in:(NSView *)v {
    NSButton *b = [NSButton checkboxWithTitle:N2L(title) target:nil action:nil];
    b.frame = NSMakeRect(24, y, 520, 20);
    [b bind:NSValueBinding toObject:UDC() withKeyPath:KP(key) options:nil];
    [v addSubview:b];
    return b;
}

- (NSTextField *)label:(NSString *)s at:(NSRect)r in:(NSView *)v {
    NSTextField *l = [NSTextField labelWithString:N2L(s)];
    l.frame = r;
    l.alignment = NSTextAlignmentRight;
    // 翻譯較長時縮小字級，避免被截斷
    for (CGFloat size = NSFont.systemFontSize; size > 9 && l.attributedStringValue.size.width > NSWidth(r) - 4; size -= 0.5)
        l.font = [NSFont systemFontOfSize:size - 0.5];
    [v addSubview:l];
    return l;
}

// 數字欄位＋上下箭頭，繫結到同一個設定
- (void)number:(NSString *)key min:(double)mn max:(double)mx at:(NSPoint)p in:(NSView *)v {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(p.x, p.y, 56, 22)];
    NSNumberFormatter *nf = [NSNumberFormatter new];
    nf.minimum = @(mn); nf.maximum = @(mx); nf.allowsFloats = NO;
    f.formatter = nf;
    [f bind:NSValueBinding toObject:UDC() withKeyPath:KP(key) options:@{NSContinuouslyUpdatesValueBindingOption: @YES}];
    NSStepper *st = [[NSStepper alloc] initWithFrame:NSMakeRect(p.x + 60, p.y - 1, 19, 24)];
    st.minValue = mn; st.maxValue = mx; st.increment = 1; st.valueWraps = NO;
    [st bind:NSValueBinding toObject:UDC() withKeyPath:KP(key) options:nil];
    [v addSubview:f];
    [v addSubview:st];
}

- (NSPopUpButton *)popup:(NSArray<NSArray *> *)items key:(NSString *)key at:(NSRect)r in:(NSView *)v {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:r pullsDown:NO];
    for (NSArray *it in items) {
        [p addItemWithTitle:it[0]];
        p.lastItem.tag = [it[1] integerValue];
    }
    [p bind:NSSelectedTagBinding toObject:UDC() withKeyPath:KP(key) options:nil];
    [v addSubview:p];
    return p;
}

// 每頁內容固定靠上（座標以 330 高為準；「一般」頁多一列，用 356 高）
- (NSView *)tabView:(NSTabView *)tabs title:(NSString *)title {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:title];
    item.label = N2L(title);
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 356)];
    BOOL tall = [title isEqualToString:@"一般"];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, tall ? 0 : 26, 560, tall ? 356 : 330)];
    v.autoresizingMask = NSViewMinYMargin;
    [container addSubview:v];
    item.view = container;
    [tabs addTabViewItem:item];
    return v;
}

- (void)build {
    UDC().appliesImmediately = YES;
    NSView *content = self.window.contentView;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(content.bounds, 12, 12)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tabs];

    // 一般
    NSView *g = [self tabView:tabs title:@"一般"];
    [self label:@"新文件編碼：" at:NSMakeRect(0, 316, 186, 20) in:g];
    NSMutableArray *encs = [NSMutableArray array];
    for (NSInteger e = 0; e < N2EncodingCount; e++) [encs addObject:@[N2EncodingDisplayName((N2Encoding)e), @(e)]];
    [self popup:encs key:N2KeyNewEncoding at:NSMakeRect(192, 311, 240, 26) in:g];
    [self label:@"新文件換行：" at:NSMakeRect(0, 280, 186, 20) in:g];
    [self popup:@[@[@"Unix / macOS（LF）", @(SC_EOL_LF)], @[@"Windows（CRLF）", @(SC_EOL_CRLF)], @[@"舊版 Mac（CR）", @(SC_EOL_CR)]]
            key:N2KeyNewEOL at:NSMakeRect(192, 275, 240, 26) in:g];
    // 介面語言（重新啟動後生效）
    [self label:N2L(@"介面語言：") at:NSMakeRect(0, 244, 186, 20) in:g];
    NSPopUpButton *langs = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(192, 239, 240, 26) pullsDown:NO];
    for (NSArray *c in N2LanguageChoices()) { [langs addItemWithTitle:c[1]]; langs.lastItem.representedObject = c[0]; }
    for (NSMenuItem *it in langs.itemArray) if ([it.representedObject isEqual:[NSUserDefaults.standardUserDefaults stringForKey:N2KeyUILanguage] ?: @""]) [langs selectItem:it];
    langs.target = self; langs.action = @selector(languageChanged:);
    [g addSubview:langs];
    NSTextField *note = [NSTextField wrappingLabelWithString:
        N2L(@"開啟既有檔案時，會自動判斷檔案的編碼與換行格式；這裡只影響新增的空白文件，以及沒有換行的檔案。")];
    note.frame = NSMakeRect(24, 188, 520, 48);
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;
    [g addSubview:note];
    // 版本歷史
    [self check:@"啟用本機版本歷史（存檔時先備份被覆蓋的舊檔）" key:N2KeyHistoryEnabled at:166 in:g];
    [self label:@"每個檔案保留：" at:NSMakeRect(0, 134, 186, 20) in:g];
    [self number:N2KeyHistoryKeep min:1 max:1000 at:NSMakePoint(192, 132) in:g];
    NSTextField *ver = [NSTextField labelWithString:ChineseUnit(@"版")];
    ver.frame = NSMakeRect(276, 134, 30, 20);
    [g addSubview:ver];
    [self label:@"備份位置：" at:NSMakeRect(0, 102, 186, 20) in:g];
    _historyLabel = [NSTextField labelWithString:N2Settings.historyFolder];
    _historyLabel.frame = NSMakeRect(192, 102, 254, 20);
    _historyLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [g addSubview:_historyLabel];
    NSButton *pick = [NSButton buttonWithTitle:N2L(@"選擇…") target:self action:@selector(chooseHistoryFolder:)];
    pick.frame = NSMakeRect(448, 95, 100, 32);
    [g addSubview:pick];
    // 開啟文件的方式：分頁或新視窗（只影響之後開啟的文件）
    [self label:@"開啟文件：" at:NSMakeRect(0, 56, 186, 20) in:g];
    [self popup:@[@[N2L(@"在分頁中開啟"), @1], @[N2L(@"在新視窗中開啟"), @0]] key:N2KeyOpenInTabs
             at:NSMakeRect(192, 51, 240, 26) in:g];
    [self check:N2L(@"永遠顯示分頁列（只有一個分頁時也顯示）") key:N2KeyAlwaysShowTabBar at:28 in:g];
    [self check:N2L(@"重新開啟時還原上次的分頁（只還原已存檔的文件）") key:N2KeyRestoreSession at:4 in:g];

    // 編輯
    NSView *e = [self tabView:tabs title:@"編輯"];
    [self label:@"編輯區字型：" at:NSMakeRect(0, 290, 186, 20) in:e];
    _fontLabel = [NSTextField labelWithString:@""];
    _fontLabel.frame = NSMakeRect(192, 290, 240, 20);
    [e addSubview:_fontLabel];
    NSButton *fontBtn = [NSButton buttonWithTitle:N2L(@"選擇…") target:self action:@selector(chooseFont:)];
    fontBtn.frame = NSMakeRect(448, 283, 100, 32);
    [e addSubview:fontBtn];
    [self updateFontLabel];
    [self label:@"定位字元寬度：" at:NSMakeRect(0, 254, 186, 20) in:e];
    [self number:N2KeyTabWidth min:1 max:16 at:NSMakePoint(192, 252) in:e];
    [self check:@"以空格代替定位字元（Tab）" key:N2KeyTabsAsSpaces at:220 in:e];
    [self check:@"自動縮排（新行沿用上一行的縮排）" key:N2KeyAutoIndent at:194 in:e];
    [self check:@"自動換行" key:N2KeyWordWrap at:168 in:e];
    [self check:@"自動補括號（輸入 ( [ { 時補上閉合符號）" key:N2KeyAutoPairBrackets at:142 in:e];
    [self check:@"自動補引號（輸入 ' \" 時補上閉合符號）" key:N2KeyAutoPairQuotes at:116 in:e];

    // 檢視
    NSView *v = [self tabView:tabs title:@"檢視"];
    CGFloat y = 292;
    NSArray *viewChecks = @[
        @[@"顯示行號", N2KeyLineNumbers], @[@"顯示狀態列", N2KeyStatusBar],
        @[@"醒目提示目前行", N2KeyHighlightLine], @[@"標示對應括號", N2KeyMatchBraces],
        @[@"醒目提示與選取相同的文字", N2KeyHighlightSelection], @[@"顯示縮排輔助線", N2KeyIndentGuides],
        @[@"顯示空白字元", N2KeyShowWhitespace], @[@"顯示換行字元", N2KeyShowEOL],
        @[@"顯示自動換行符號", N2KeyWrapSymbols], @[@"顯示書籤欄", N2KeyBookmarkMargin], @[@"顯示折疊邊界", N2KeyCodeFolding], @[@"反向色彩（編輯區黑白互換，不影響列印）", N2KeyInvertColors],
    ];
    for (NSArray *c in viewChecks) { [self check:c[0] key:c[1] at:y in:v]; y -= 24; }
    NSButton *longLine = [self check:@"顯示長行標記，位置在第" key:N2KeyLongLineMarker at:y in:v];
    [longLine sizeToFit];   // 數字欄位接在文字後面（各語言長度不同）
    CGFloat nx = NSMaxX(longLine.frame) + 6;
    [self number:N2KeyLongLineColumn min:1 max:4096 at:NSMakePoint(nx, y - 1) in:v];
    NSTextField *col = [NSTextField labelWithString:ChineseUnit(@"欄")];
    col.frame = NSMakeRect(nx + 84, y, 30, 20);
    [v addSubview:col];
}

- (void)languageChanged:(NSPopUpButton *)sender {
    NSString *code = sender.selectedItem.representedObject ?: @"";
    [NSUserDefaults.standardUserDefaults setObject:code forKey:N2KeyUILanguage];
    N2ApplyLanguagePreference();
    NSAlert *a = [NSAlert new];
    a.messageText = N2L(@"變更介面語言後，請重新啟動 Notepad2XS。");
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)chooseHistoryFolder:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO; p.canChooseDirectories = YES; p.canCreateDirectories = YES;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        [NSUserDefaults.standardUserDefaults setObject:p.URL.path forKey:N2KeyHistoryFolder];
        self->_historyLabel.stringValue = N2Settings.historyFolder;
    }];
}

- (void)updateFontLabel {
    _fontLabel.stringValue = [NSString stringWithFormat:@"%@　%g pt", N2Settings.fontName, N2Settings.fontSize];
}

- (void)chooseFont:(id)sender { [N2Settings showFontPanelForTarget:self]; }

- (void)changeEditorFont:(id)sender { [N2Settings applyFontChange:sender]; }

@end
