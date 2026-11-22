// 全域設定（保存在 NSUserDefaults）。
// 任何下列設定改變（包含偏好設定視窗的繫結）都會合併送出一次 N2SettingsChangedNotification。
#pragma once
#import <Cocoa/Cocoa.h>
#import "TextEncoding.h"

extern NSString *const N2SettingsChangedNotification;
extern NSString *const N2SettingsChangedKeys;   // 通知的 userInfo：NSSet<NSString *>，變更過的設定鍵

// NSUserDefaults 鍵名（偏好設定視窗用來繫結）
extern NSString *const N2KeyFontName, *const N2KeyFontSize, *const N2KeyWordWrap, *const N2KeyLineNumbers,
    *const N2KeyStatusBar, *const N2KeyTabWidth, *const N2KeyTabsAsSpaces, *const N2KeyAutoIndent,
    *const N2KeyShowWhitespace, *const N2KeyShowEOL, *const N2KeyWrapSymbols, *const N2KeyIndentGuides,
    *const N2KeyLongLineMarker, *const N2KeyLongLineColumn, *const N2KeyMatchBraces, *const N2KeyHighlightLine,
    *const N2KeyHighlightSelection, *const N2KeyInvertColors, *const N2KeyNewEncoding, *const N2KeyNewEOL,
    *const N2KeyHistoryEnabled, *const N2KeyHistoryKeep, *const N2KeyHistoryFolder, *const N2KeyUILanguage,
    *const N2KeyOpenInTabs, *const N2KeyAlwaysShowTabBar;

@interface N2Settings : NSObject
+ (void)registerDefaults;

@property (class, nonatomic, copy) NSString *fontName;
@property (class, nonatomic) CGFloat fontSize;
@property (class, nonatomic) BOOL wordWrap;
@property (class, nonatomic) BOOL showLineNumbers;
@property (class, nonatomic) BOOL showStatusBar;
@property (class, nonatomic) NSInteger tabWidth;
@property (class, nonatomic) BOOL tabsAsSpaces;
@property (class, nonatomic) BOOL autoIndent;
@property (class, nonatomic) BOOL showWhitespace;
@property (class, nonatomic) BOOL showEOL;
@property (class, nonatomic) BOOL wrapSymbols;
@property (class, nonatomic) BOOL indentGuides;
@property (class, nonatomic) BOOL longLineMarker;
@property (class, nonatomic) NSInteger longLineColumn;
@property (class, nonatomic) BOOL matchBraces;
@property (class, nonatomic) BOOL highlightCurrentLine;
@property (class, nonatomic) BOOL highlightSelection;
@property (class, nonatomic) BOOL invertColors;
@property (class, nonatomic) N2Encoding newDocumentEncoding;
@property (class, nonatomic) int newDocumentEOL;   // SC_EOL_*
@property (class, nonatomic, readonly) BOOL alwaysShowTabBar;   // 只有一個分頁時也顯示分頁列
@property (class, nonatomic, readonly) BOOL openInTabs;         // 開啟／新增文件時加入目前視窗的分頁（預設），否則開新視窗
@property (class, nonatomic, readonly) BOOL historyEnabled;     // 本機版本歷史（預設關閉）
@property (class, nonatomic, readonly) NSInteger historyKeep;   // 每個檔案保留版本數（1～1000，預設 30）
@property (class, nonatomic, readonly) NSString *historyFolder;

// 同時設定字型名稱與大小（只送出一次通知）
+ (void)setFontName:(NSString *)name size:(CGFloat)size;   // 大小限制在 4～200 pt
@property (class, nonatomic, readonly) NSFont *editorFont;
+ (void)showFontPanelForTarget:(id)target;   // target 需實作 changeEditorFont:
+ (void)applyFontChange:(id)fontManager;
@end
