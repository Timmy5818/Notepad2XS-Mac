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

// 一份文件（一個分頁）的書籤狀態
@interface N2BookmarkContext : NSObject
// sidecarURL：計算 .2xs 檔案位置用的文件網址；member：壓縮檔內成員路徑（一般檔案為 nil）
- (void)loadInto:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked;
- (void)loadAfterUnlock:(ScintillaView *)v;   // 解密成功後才套用書籤
- (void)reset;
// 回傳 YES：「只存書籤」的情況已處理（包含寫入失敗而略過）；NO：沒有需要寫入的變動
- (BOOL)save:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked mode:(N2BookmarkSaveMode)mode;
@end

NSURL *N2BookmarkSidecarURL(NSURL *url, NSString *member);   // 測試與搬移用
