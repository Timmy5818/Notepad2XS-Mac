#import "Settings.h"
#include "Scintilla.h"

NSString *const N2SettingsChangedNotification = @"N2SettingsChangedNotification";
NSString *const N2SettingsChangedKeys = @"keys";

NSString *const N2KeyFontName = @"FontName";
NSString *const N2KeyFontSize = @"FontSize";
NSString *const N2KeyWordWrap = @"WordWrap";
NSString *const N2KeyLineNumbers = @"ShowLineNumbers";
NSString *const N2KeyStatusBar = @"ShowStatusBar";
NSString *const N2KeyTabWidth = @"TabWidth";
NSString *const N2KeyTabsAsSpaces = @"TabsAsSpaces";
NSString *const N2KeyAutoIndent = @"AutoIndent";
NSString *const N2KeyShowWhitespace = @"ShowWhitespace";
NSString *const N2KeyShowEOL = @"ShowEOL";
NSString *const N2KeyWrapSymbols = @"ShowWrapSymbols";
NSString *const N2KeyIndentGuides = @"ShowIndentGuides";
NSString *const N2KeyLongLineMarker = @"LongLineMarker";
NSString *const N2KeyLongLineColumn = @"LongLineColumn";
NSString *const N2KeyMatchBraces = @"MatchBraces";
NSString *const N2KeyHighlightLine = @"HighlightCurrentLine";
NSString *const N2KeyHighlightSelection = @"HighlightSelection";
NSString *const N2KeyInvertColors = @"InvertColors";
NSString *const N2KeyNewEncoding = @"NewDocumentEncoding";
NSString *const N2KeyNewEOL = @"NewDocumentEOL";
NSString *const N2KeyHistoryEnabled = @"HistoryEnabled";
NSString *const N2KeyHistoryKeep = @"HistoryKeep";
NSString *const N2KeyHistoryFolder = @"HistoryFolder";
NSString *const N2KeyUILanguage = @"UILanguage";
NSString *const N2KeyOpenInTabs = @"OpenInTabs";
NSString *const N2KeyAlwaysShowTabBar = @"AlwaysShowTabBar";

static NSUserDefaults *UD(void) { return NSUserDefaults.standardUserDefaults; }

// 監看所有設定鍵，同一輪事件迴圈內的多次變更只送出一次通知
@interface N2SettingsObserver : NSObject
@end
@implementation N2SettingsObserver {
    NSMutableSet<NSString *> *_changed;   // 這一輪變更過的鍵，隨通知送出（userInfo[N2SettingsChangedKeys]）
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (_changed) { [_changed addObject:keyPath]; return; }
    _changed = [NSMutableSet setWithObject:keyPath];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSSet *keys = [self->_changed copy];
        self->_changed = nil;
        [NSNotificationCenter.defaultCenter postNotificationName:N2SettingsChangedNotification object:nil
                                                        userInfo:@{N2SettingsChangedKeys: keys}];
    });
}
@end

static N2SettingsObserver *gObserver;

static BOOL B(NSString *k) { return [UD() boolForKey:k]; }
static void SetB(NSString *k, BOOL v) { [UD() setBool:v forKey:k]; }

@implementation N2Settings

+ (void)registerDefaults {
    // 與 Windows 版首次啟動預設一致：自動換行開、行號關、狀態列開
    NSDictionary *defaults = @{
        N2KeyFontName: @"Menlo",
        N2KeyFontSize: @13.0,
        N2KeyWordWrap: @YES,
        N2KeyLineNumbers: @NO,
        N2KeyStatusBar: @YES,
        N2KeyTabWidth: @4,
        N2KeyTabsAsSpaces: @NO,
        N2KeyAutoIndent: @YES,
        N2KeyShowWhitespace: @NO,
        N2KeyShowEOL: @NO,
        N2KeyWrapSymbols: @NO,
        N2KeyIndentGuides: @NO,
        N2KeyLongLineMarker: @NO,
        N2KeyLongLineColumn: @80,
        N2KeyMatchBraces: @YES,
        N2KeyHighlightLine: @YES,
        N2KeyHighlightSelection: @YES,
        N2KeyInvertColors: @NO,
        N2KeyNewEncoding: @(N2EncodingUTF8),
        N2KeyNewEOL: @(SC_EOL_LF),
        N2KeyHistoryEnabled: @NO,
        N2KeyHistoryKeep: @30,
        N2KeyHistoryFolder: @"",
        N2KeyOpenInTabs: @YES,
        N2KeyAlwaysShowTabBar: @YES,   // 只有一個分頁時也顯示分頁列（含「＋」）   // 開啟文件：YES＝分頁、NO＝新視窗
        N2KeyUILanguage: @"zh-Hant",   // 與 Windows 版相同，預設繁體中文；空字串＝跟隨系統
    };
    [UD() registerDefaults:defaults];
    if (!gObserver) {
        gObserver = [N2SettingsObserver new];
        for (NSString *key in defaults)
            [UD() addObserver:gObserver forKeyPath:key options:0 context:NULL];
    }
}

+ (NSString *)fontName {
    NSString *n = [UD() stringForKey:N2KeyFontName];
    return n.length ? n : @"Menlo";
}
+ (void)setFontName:(NSString *)v { [UD() setObject:v forKey:N2KeyFontName]; }

+ (CGFloat)fontSize {
    double s = [UD() doubleForKey:N2KeyFontSize];
    return (s >= 4 && s <= 200) ? s : 13.0;
}
// 讀取時只接受 4～200 pt；寫入時也限制在同一範圍，避免存了 288 卻默默顯示成 13
static CGFloat ClampFontSize(CGFloat v) { return MIN(MAX(v, 4.0), 200.0); }
+ (void)setFontSize:(CGFloat)v { [UD() setDouble:ClampFontSize(v) forKey:N2KeyFontSize]; }

+ (void)setFontName:(NSString *)name size:(CGFloat)size {
    [UD() setObject:name forKey:N2KeyFontName];
    [UD() setDouble:ClampFontSize(size) forKey:N2KeyFontSize];
}

+ (NSFont *)editorFont {
    return [NSFont fontWithName:self.fontName size:self.fontSize] ?: [NSFont userFixedPitchFontOfSize:13];
}

// 編輯視窗與偏好設定共用：字型面板改變時呼叫 target 的 changeEditorFont:，再交給 applyFontChange:
+ (void)showFontPanelForTarget:(id)target {
    NSFontManager *fm = NSFontManager.sharedFontManager;
    fm.target = target;
    fm.action = @selector(changeEditorFont:);
    [fm setSelectedFont:self.editorFont isMultiple:NO];
    [fm orderFrontFontPanel:target];
}

+ (void)applyFontChange:(id)fontManager {
    NSFont *f = [fontManager convertFont:self.editorFont];
    if (f) [self setFontName:f.fontName size:f.pointSize];
}

+ (BOOL)wordWrap { return B(N2KeyWordWrap); }
+ (void)setWordWrap:(BOOL)v { SetB(N2KeyWordWrap, v); }
+ (BOOL)showLineNumbers { return B(N2KeyLineNumbers); }
+ (void)setShowLineNumbers:(BOOL)v { SetB(N2KeyLineNumbers, v); }
+ (BOOL)showStatusBar { return B(N2KeyStatusBar); }
+ (void)setShowStatusBar:(BOOL)v { SetB(N2KeyStatusBar, v); }

+ (NSInteger)tabWidth {
    NSInteger w = [UD() integerForKey:N2KeyTabWidth];
    return (w >= 1 && w <= 16) ? w : 4;
}
+ (void)setTabWidth:(NSInteger)v { [UD() setInteger:v forKey:N2KeyTabWidth]; }

+ (BOOL)tabsAsSpaces { return B(N2KeyTabsAsSpaces); }
+ (void)setTabsAsSpaces:(BOOL)v { SetB(N2KeyTabsAsSpaces, v); }
+ (BOOL)autoIndent { return B(N2KeyAutoIndent); }
+ (void)setAutoIndent:(BOOL)v { SetB(N2KeyAutoIndent, v); }
+ (BOOL)showWhitespace { return B(N2KeyShowWhitespace); }
+ (void)setShowWhitespace:(BOOL)v { SetB(N2KeyShowWhitespace, v); }
+ (BOOL)showEOL { return B(N2KeyShowEOL); }
+ (void)setShowEOL:(BOOL)v { SetB(N2KeyShowEOL, v); }
+ (BOOL)wrapSymbols { return B(N2KeyWrapSymbols); }
+ (void)setWrapSymbols:(BOOL)v { SetB(N2KeyWrapSymbols, v); }
+ (BOOL)indentGuides { return B(N2KeyIndentGuides); }
+ (void)setIndentGuides:(BOOL)v { SetB(N2KeyIndentGuides, v); }
+ (BOOL)longLineMarker { return B(N2KeyLongLineMarker); }
+ (void)setLongLineMarker:(BOOL)v { SetB(N2KeyLongLineMarker, v); }

+ (NSInteger)longLineColumn {
    NSInteger c = [UD() integerForKey:N2KeyLongLineColumn];
    return (c >= 1 && c <= 4096) ? c : 80;
}
+ (void)setLongLineColumn:(NSInteger)v { [UD() setInteger:v forKey:N2KeyLongLineColumn]; }

+ (BOOL)matchBraces { return B(N2KeyMatchBraces); }
+ (void)setMatchBraces:(BOOL)v { SetB(N2KeyMatchBraces, v); }
+ (BOOL)highlightCurrentLine { return B(N2KeyHighlightLine); }
+ (void)setHighlightCurrentLine:(BOOL)v { SetB(N2KeyHighlightLine, v); }
+ (BOOL)highlightSelection { return B(N2KeyHighlightSelection); }
+ (void)setHighlightSelection:(BOOL)v { SetB(N2KeyHighlightSelection, v); }
+ (BOOL)invertColors { return B(N2KeyInvertColors); }
+ (void)setInvertColors:(BOOL)v { SetB(N2KeyInvertColors, v); }

+ (N2Encoding)newDocumentEncoding {
    NSInteger e = [UD() integerForKey:N2KeyNewEncoding];
    return (e >= 0 && e < N2EncodingCount) ? (N2Encoding)e : N2EncodingUTF8;
}
+ (void)setNewDocumentEncoding:(N2Encoding)v { [UD() setInteger:v forKey:N2KeyNewEncoding]; }

+ (int)newDocumentEOL {
    NSInteger e = [UD() integerForKey:N2KeyNewEOL];
    return (e == SC_EOL_CRLF || e == SC_EOL_CR || e == SC_EOL_LF) ? (int)e : SC_EOL_LF;
}
+ (void)setNewDocumentEOL:(int)v { [UD() setInteger:v forKey:N2KeyNewEOL]; }

+ (BOOL)historyEnabled { return B(N2KeyHistoryEnabled); }
+ (BOOL)openInTabs { return B(N2KeyOpenInTabs); }
+ (BOOL)alwaysShowTabBar { return B(N2KeyAlwaysShowTabBar); }
+ (NSInteger)historyKeep {
    NSInteger n = [UD() integerForKey:N2KeyHistoryKeep];
    return (n >= 1 && n <= 1000) ? n : 30;
}
+ (NSString *)historyFolder {
    NSString *f = [UD() stringForKey:N2KeyHistoryFolder];
    if (f.length) return f.stringByExpandingTildeInPath;
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"Notepad2XS/history"];
}

@end
