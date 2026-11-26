// 雲端 X60 檔案（Windows 版 R159～R166）：
// - 「雲端設定」：輸入放 notepad2xs_cloud_fils_system.php 的資料夾網址，可測試連線
// - 「雲端檔案」：瀏覽、搜尋、排序、欄位顯示／順序／寬度、圖示檢視、資料夾、上傳、拖曳上傳、
//   更名、複製、搬移、刪除、屬性；開啟後在新分頁解密編輯，⌘S 以原密碼 EXES 加密後存回雲端
// - 「存到雲端」：把已 EXES 加密的未命名分頁上傳到指定資料夾
// - 逐檔設定（書籤、游標、捲動、縮放、語法、編碼、換行）存在雲端檔案旁的 INI
#pragma once
#import <Cocoa/Cocoa.h>

// 一份雲端檔案（分頁開啟期間的連線與版本資訊）
@interface N2CloudFile : NSObject
@property (nonatomic, copy) NSString *base;          // 資料夾網址（結尾為 /）
@property (nonatomic, copy) NSString *api;           // base + PHP 檔名
@property (nonatomic, copy) NSString *fileID;        // UUID
@property (nonatomic, copy) NSString *name;          // 不含 .x60
@property (nonatomic, copy) NSString *folder;        // root 或資料夾 UUID
@property (nonatomic, copy) NSString *title;         // 「名稱.x60 [雲端 · 路徑]」
@property (nonatomic, copy) NSString *revision;      // 內容版本（SHA-1）
@property (nonatomic, copy) NSString *prefsRevision; // 逐檔設定版本
@property (nonatomic, copy) NSData *prefsState;      // 上次讀寫的逐檔設定
@property (nonatomic, strong) NSData *payload;       // 開啟時下載的密文（放進分頁後清除）
- (BOOL)isSameFile:(N2CloudFile *)other;
@end

// 「雲端設定」視窗
void N2CloudShowSettings(NSWindow *parent);

// 「雲端檔案」視窗：回傳要開啟的檔案（含 payload），關閉則回傳 nil。
// updateTab：重新整理、更名或搬移時通知已開啟的分頁更新標題
N2CloudFile *N2CloudBrowse(NSWindow *parent, void (^updateTab)(N2CloudFile *metadata));

// 內容是否為完整的 X60 密文（「存到雲端」可用）
BOOL N2CloudCanSaveX60(NSData *text);

// 「存到雲端」：選擇資料夾與檔名後上傳。isOpen：同名檔案已在其他分頁開啟；
// unchanged：上傳前後確認分頁內容沒有變動。取消或失敗回傳 nil（失敗時已顯示訊息）
N2CloudFile *N2CloudSaveNew(NSWindow *parent, NSData *cipher, BOOL (^isOpen)(N2CloudFile *file),
                            BOOL (^unchanged)(void));

// 以 revision 覆蓋雲端內容（⌘S）；成功時更新 file 的名稱、位置與版本
BOOL N2CloudUpload(NSWindow *parent, N2CloudFile *file, NSData *cipher);

// 讀取逐檔設定；失敗回傳 nil（已顯示訊息）
NSData *N2CloudLoadState(NSWindow *parent, N2CloudFile *file);
// 寫入逐檔設定；狀態沒變時不送出。失敗時顯示訊息並回傳 NO
BOOL N2CloudSaveState(NSWindow *parent, N2CloudFile *file, NSData *state);

// 結束程式時呼叫：之後的請求縮短逾時，逐檔設定寫入失敗不跳出訊息
void N2CloudPrepareForTermination(void);

// 雲端訊息（標題為「雲端檔案」）
void N2CloudMessage(NSWindow *parent, NSString *text);

// 測試與設定共用：使用者設定的資料夾網址
NSString *N2CloudConfiguredBase(void);
