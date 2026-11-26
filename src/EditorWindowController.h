// 編輯視窗：Scintilla 編輯區（可分割成兩個，共用同一份文件）＋狀態列，以及大部分選單動作
#pragma once
#import <Cocoa/Cocoa.h>
#include "Scintilla.h"

#import "BookmarkStore.h"
#import "TextEncoding.h"

@class ScintillaView, Document;

typedef NS_OPTIONS(NSUInteger, N2FindOptions) {
    N2FindMatchCase = 1 << 0,
    N2FindWholeWord = 1 << 1,
    N2FindRegex     = 1 << 2,
    N2FindWrap      = 1 << 3,
};

typedef NS_ENUM(NSInteger, N2FindResult) {
    N2FindNotFound = 0,
    N2FindFound,
    N2FindFoundWrapped,
    N2FindInvalidPattern,
};

typedef NS_ENUM(NSInteger, N2SplitMode) {
    N2SplitNone = 0,
    N2SplitHorizontal,   // 上下
    N2SplitVertical,     // 左右
};

static const NSInteger N2ReplaceAllReadOnly = -2;   // replaceAll：文件唯讀（已鎖定），沒有取代

@interface EditorWindowController : NSWindowController

@property (nonatomic, readonly) ScintillaView *sci;       // 目前作用中的編輯區
@property (nonatomic, readonly) ScintillaView *primarySci;
@property (nonatomic, readonly) Document *doc;
@property (nonatomic, readonly) NSArray<ScintillaView *> *allViews;   // 主要編輯區＋分割出來的第二個編輯區
@property (nonatomic, readonly) N2BookmarkContext *bookmarks;          // 這份文件的書籤與檢視狀態（.2xs）

- (void)loadDocumentText;      // 把 Document.loadedText 放進編輯區
- (NSData *)textAsUTF8;        // 目前全文（UTF-8）
@property (nonatomic, readonly) NSUInteger modificationCount;   // 內容每次插入／刪除就加一
- (void)markSavedAtModification:(NSUInteger)count;
- (void)markDirtyWithoutUndo;   // 清空復原紀錄，但文件維持「未儲存」直到存檔（加解密後使用）   // 存檔成功後：內容在取文字之後沒再變動才設定儲存點
- (void)applyLanguage;         // 依文件語言重新上色
- (NSString *)selectedText;
- (void)updateStatus;
- (BOOL)isActionAvailable:(SEL)action;   // 選單與工具列共用的停用規則
- (BOOL)rejectIfReadOnly;                 // 文件鎖定時顯示提示並回傳 YES
- (void)retile:(ScintillaView *)v;        // 邊界寬度改變後重新排版

// 對作用中編輯區送 Scintilla 訊息
- (sptr_t)send:(unsigned int)msg;
- (sptr_t)send:(unsigned int)msg w:(uptr_t)w;
- (sptr_t)send:(unsigned int)msg w:(uptr_t)w l:(sptr_t)l;

// 顯示錯誤／提示（視窗上的 sheet）
- (void)showMessage:(NSString *)message info:(NSString *)info;

// 尋找／取代
- (N2FindResult)findString:(NSString *)text options:(N2FindOptions)options forward:(BOOL)forward;
- (N2FindResult)replaceString:(NSString *)text with:(NSString *)replacement options:(N2FindOptions)options;
- (NSInteger)replaceAll:(NSString *)text with:(NSString *)replacement options:(N2FindOptions)options;   // 取代數量；-1＝無效樣式

// 列印用：含語法顏色的全文（不受反向色彩影響）
- (NSAttributedString *)attributedTextForPrinting;

@end

// 加密狀態（實作在 EditorCrypto.mm）
@interface EditorWindowController (Crypto)
- (void)applyLockAppearance:(ScintillaView *)v;
- (void)updateCryptoAppearance;
- (void)runPendingAutoDecrypt;
@end

// 書籤、折疊、字元資訊、JSON、自動補括號（實作在 EditorNavigation.mm）
@interface EditorWindowController (Navigation)
- (void)applyNavigation:(ScintillaView *)v;
- (void)refreshNavigationMargins:(ScintillaView *)v;
- (void)navigationMarginClick:(SCNotification *)scn view:(ScintillaView *)v right:(BOOL)right;
- (NSInteger)bookmarkLinesMatching:(NSString *)text options:(N2FindOptions)options;   // 行數；-1 規則有誤；-3 失敗
- (void)loadBookmarks;
- (void)loadBookmarksAfterUnlock;
- (BOOL)saveBookmarks:(N2BookmarkSaveMode)mode;
- (NSString *)characterInfoText;
@end
void N2InstallAutoPair(ScintillaView *v);

// 個別檔案設定：語法、開檔編碼、自動換行（R155；實作在 EditorFilePrefs.mm）
@interface EditorWindowController (FilePrefs)
@property (nonatomic, readonly) BOOL effectiveWordWrap;   // 此檔案的換行設定（沒有時跟隨全域設定）
- (void)installFilePreferenceHook;
- (void)applyFilePreferences;
- (void)fileEncodingSaved;
- (void)finalizeDocumentState;                           // 關閉分頁／結束程式時保存書籤與檢視（R156）
- (void)rememberSelectedLanguage;
- (void)rememberReadEncoding:(N2Encoding)enc;
- (BOOL)validateFilePreferenceItem:(NSMenuItem *)item handled:(BOOL *)handled;
@end

// 雲端 X60 檔案（R159～R166；實作在 EditorCloud.mm）
@interface EditorWindowController (Cloud)
- (void)saveCloudDocument:(void (^)(BOOL ok))completion;
- (void)saveCloudViewIncludingBookmarks:(BOOL)includeBookmarks;
- (void)rememberStateBeforeEncryption;
- (BOOL)validateCloudItem:(NSMenuItem *)item handled:(BOOL *)handled;
@end
void N2OpenCloudFiles(EditorWindowController *anchor);   // anchor 為 nil 時開在新視窗

// 多分頁（實作在 EditorTabs.mm）
@interface EditorWindowController (Tabs)
- (void)setupTabbing;
- (void)ensureTabBarShown;
@end
void N2InstallTabMiddleClick(void);   // 滑鼠中鍵點分頁即關閉、分頁列右鍵選單
void N2SaveAllDocuments(void);
void N2CloseAllDocuments(void (^completion)(BOOL closed));
void N2SaveSession(void);
BOOL N2HasSessionToRestore(void);
void N2RestoreSession(void (^done)(BOOL restored));
void N2RememberClosedDocument(Document *doc);            // R158：最近關閉的 32 個分頁
BOOL N2HasClosedDocuments(void);
void N2ReopenClosedDocument(void);

// 工具列（實作在 EditorToolbar.mm）
@interface EditorWindowController (Toolbar) <NSToolbarDelegate>
- (void)setupToolbar;
@end
