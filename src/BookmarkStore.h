// 每份文件的手動書籤與檢視狀態（與 Windows 版 R138～R141 相同格式）
// 位置：文件（或壓縮檔）旁的隱藏資料夾 .2xs/<EX_MD3(檔名)>.ini，內有 readme.txt
// 壓縮檔內的文件：名稱為「壓縮檔名|成員路徑」
#pragma once
#import <Cocoa/Cocoa.h>

@class ScintillaView;

// Scintilla 依編號由小到大畫標記：手動書籤（圓點）畫在搜尋書籤（小方塊）上面
enum { N2SearchBookmark = 21, N2BlueBookmark = 22, N2RedBookmark = 23 };
static const unsigned N2ManualBookmarkMask = (1u << N2BlueBookmark) | (1u << N2RedBookmark);
static const unsigned N2BookmarkMask = N2ManualBookmarkMask | (1u << N2SearchBookmark);

typedef NS_ENUM(NSInteger, N2BookmarkSaveMode) {
    N2BookmarkSaveChanged,     // 文件沒修改時按 ⌘S：只在書籤或檢視狀態有變動時寫入
    N2BookmarkSaveSavedFile,   // 文件存檔成功後
    N2BookmarkSaveNewTarget,   // 另存新檔／未命名文件第一次存檔：一律寫入書籤
    N2BookmarkSaveViewOnly,    // 切換分頁、關閉：只記錄游標、捲動與縮放
};

// 個別檔案設定（R155）：與 Windows 版相同的 [FileSettings] 區段；-1 代表跟隨自動判斷或全域設定
typedef NS_ENUM(NSInteger, N2FilePreference) {
    N2FilePrefSyntax = 0,     // Windows 版語法資源 ID（63000 起）
    N2FilePrefEncoding = 1,   // Windows 版編碼資源 ID（61000 起）
    N2FilePrefWordWrap = 2,   // 0／1
};

// 一份文件（一個分頁）的書籤狀態
@interface N2BookmarkContext : NSObject
// 讀到 .2xs（或雲端逐檔設定）後、還原游標與書籤之前呼叫：先套用語法與換行，捲動位置才會正確
@property (nonatomic, copy) void (^applyPreferences)(void);
// sidecarURL：計算 .2xs 檔案位置用的文件網址；member：壓縮檔內成員路徑（一般檔案為 nil）
- (void)loadInto:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked;
- (void)loadAfterUnlock:(ScintillaView *)v;   // 解密成功後才套用書籤
- (void)reset;
// 回傳 YES：「只存書籤」的情況已處理（包含寫入失敗而略過）；NO：沒有需要寫入的變動
- (BOOL)save:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked mode:(N2BookmarkSaveMode)mode;

// 個別檔案設定：url 為 nil（雲端或未命名文件）時只記在這個分頁，之後由呼叫端另外保存
- (int)preference:(N2FilePreference)preference;
- (BOOL)setPreference:(N2FilePreference)preference value:(int)value url:(NSURL *)url member:(NSString *)member;
+ (int)encodingPreferenceForURL:(NSURL *)url member:(NSString *)member;   // 開檔前讀取指定的開檔編碼

// 雲端逐檔設定（R161）：內容與 .2xs 的 INI 相同
- (BOOL)stageCloudState:(NSData *)state;                                  // 解密後才套用（loadAfterUnlock）
- (NSData *)cloudSnapshot:(ScintillaView *)v includeBookmarks:(BOOL)includeBookmarks;
- (void)commitCloudSnapshot:(NSData *)state;
@property (nonatomic, readonly) BOOL hasPendingCloudState;                // 還沒解密：雲端設定尚未套用
@end

NSURL *N2BookmarkSidecarURL(NSURL *url, NSString *member);   // 測試與搬移用
