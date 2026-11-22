# Notepad2XS for macOS — 移植計畫

> 來源：`Notepad2XS_R133_Fullscreen_Source.zip`（專家記事本 / NotePad2-XS R133，Windows／Win32／C、C++）
> 目標：在 macOS 上做出功能對等的原生編輯器
> 建立日期：2026-11-21

---

## 1. 現況分析

| 項目 | 內容 |
|---|---|
| 原始程式 | `source/src/` 約 8.8 萬行（含 `Extension/` 約 4 萬行），另有 Scintilla 約 3.8 萬行、測試約 1.4 萬行 |
| 編輯核心 | 修改版 Scintilla 3.11.2（有 Boost.Regex 搜尋擴充），原包只有 Win32 平台層 |
| Windows 綁定 | `HWND`、`SendMessage`、`CreateWindow`、`WM_*` 等呼叫超過 3,200 處；選單、對話框都用 `.rc` 資源 |
| Windows 專屬服務 | WinHTTP、BCrypt、DPAPI、CryptProtectMemory、登錄檔、檔案關聯、WMI、ODBC、Shell API |
| 可直接沿用 | 不碰 Win32 的演算法：AES／EXES 核心、中文金額、CSV 解析、數學運算（tinyexpr）、Base64／QP／Hex／URL 編碼、JPEG 註解格式 |

結論：**畫面與系統服務要重寫，核心演算法盡量搬過去重用**。

## 2. 技術選擇

| 項目 | 選擇 | 理由 |
|---|---|---|
| 畫面 | Objective-C++ ＋ AppKit | Scintilla 的 Cocoa 層就是 Objective-C++，接起來最直接；可直接呼叫原本的 C／C++ 程式碼 |
| 編輯核心 | 官方 Scintilla **3.11.2**（含 Cocoa 層） | 與原版同一版，之後可以把原版的修改（Boost.Regex 等）逐步合併過來 |
| 文件架構 | `NSDocument` | 開啟、儲存、另存、最近檔案、未存檔提示、多視窗都由系統處理 |
| 建置 | Shell 腳本 ＋ clang（不依賴 Xcode 專案檔） | 好維護、好看懂，可以在終端機一行指令建置 |
| 架構 | **先做 x86_64**，之後再加 arm64 做成 Universal Binary（已完成） | 開發機是 Intel Mac |
| 最低系統 | macOS 11 | |
| 密碼保存 | Windows DPAPI → macOS 鑰匙圈（Keychain） | |
| 網路 | WinHTTP → `NSURLSession` | |
| 加密函式 | BCrypt → CommonCrypto／CryptoKit | |
| 設定檔 | INI → `NSUserDefaults`（之後視需要支援匯入原版 INI） | |

## 3. 階段與步驟（9 個階段、30 步）

狀態：✅ 完成　🚧 進行中　⬜ 未開始

### 階段 0：準備（估 300萬～600萬 token）
- ✅ 0-2 建立建置流程：下載 Scintilla 3.11.2、編成靜態函式庫、打包成 `.app`
- ✅ 0-1 從原始碼分出不碰 Win32 的核心程式碼（src/core：加密、AI、F5、CSV、搜尋、JPEG 等）

### 階段 1：能用的編輯器 ⭐（估 3,000萬～6,000萬 token）
- ✅ 1-1 主視窗＋接上 Mac 版 Scintilla
- ✅ 1-2 開檔、存檔、另存新檔、文字編碼（自動判斷＋手動指定）、換行格式（CRLF／LF／CR）
- ✅ 1-3 繁中選單、快捷鍵、狀態列（行、欄、選取、編碼、換行、縮放）
- ✅ 1-4 尋找、取代、全部取代、跳到指定行
- ✅ 1-5 設定保存（字型、自動換行、行號、狀態列）、基本語法上色（依副檔名）
- ⬜ 1-6 （後補）合併原版 Scintilla 的 Boost.Regex 搜尋修改

### 階段 2：編輯器完整化（估 2,000萬～3,500萬 token）
- ✅ 2-1 檢視：全螢幕、反向色彩、分割視窗（上下／左右）、空白／換行字元、縮排輔助線、長行標記、括號配對、醒目提示目前行／相同文字
- ✅ 2-2 文字工具：排序／移除重複行、大小寫 5 種、空白整理、Tab／空格轉換、合併／拆分行、依欄寬換行、修改行、前後加字、行註解／區塊註解、行操作、編碼與解碼（Base64／URL／Hex／QP／C 十六進位／C 逸出／HTML）、插入日期／檔名
- ✅ 2-3 列印（含語法顏色、頁首頁碼）、頁面設定
- ✅ 2-4 偏好設定視窗（一般／編輯／檢視）

### 階段 3：加解密（估 1,500萬～3,000萬 token）
- ✅ 3-1 AES-256-GCM 核心（PBKDF2-HMAC-SHA256 600,000 次）＋鑰匙圈保存
- ✅ 3-2 密碼視窗、隨機密碼產生、預設密碼
- ✅ 3-3 KEY FILE、網址密鑰（EX_MD3 衍生）
- ✅ 3-4 `.u2f`／`.x60` 格式、開檔自動解密（JPEG AES COM 移到 7-4）

### 階段 4：壓縮檔（估 800萬～1,500萬 token）
- ✅ 4-1 ZIP／7Z 讀取＋成員選擇視窗（單一清單＋篩選）
- ✅ 4-2 回存、TAR／tar.gz／tar.bz2／tar.xz；其他格式轉 ZIP（改用系統 zip／unzip／bsdtar）

### 階段 5：AI（估 800萬～1,500萬 token）
- ✅ 5-1 AI 連線（OpenRouter、Google、NVIDIA、DeepSeek）＋設定＋連線測試
- ✅ 5-2 指令範本管理、四種輸出方式

### 階段 6：F5 執行選取（估 1,500萬～3,000萬 token）
- ✅ 6-1 數學計算（tinyexpr）、中文金額
- ✅ 6-2 開啟網址（curl）、路徑、SSH／FTP、腳本（[SHCMD]／[PSCMD]／[JAVASCRIPT]）
- ✅ 6-3 SQL 查詢（macOS 內建 iODBC）＋結果表格與匯出
- ✅ 6-4 WQL 替代：[SYSINFO]（system_profiler 查詢，結果進同一個表格）

### 階段 7：其他工具（估 1,500萬～3,000萬 token）
- ✅ 7-1 CSV 表格模式（儲存格編輯、新增／插入／刪除列欄、套用時全部加雙引號）
- ✅ 7-2 檔案搜尋（萬用字元、日期、大小、背景搜尋、排序、匯出 CSV）
- ✅ 7-3 安全刪除（覆寫＋F_FULLFSYNC＋回讀驗證＋刪除；說明 APFS／SSD 限制）
- ✅ 7-4 JPEG 註解（明文／AES／EXES）、版本歷史

### 階段 8：收尾（估 1,500萬～3,500萬 token）
- ✅ 8-1 八種介面語言（選單、狀態列、尋找視窗、偏好設定標題；預設繁中）
- ✅ 8-2 檔案類型宣告（.x60／.u2f 由本程式開啟，其他文字檔在「打開方式」）、App 圖示、關於視窗
- ✅ 8-3 Universal Binary（x86_64＋arm64）、全面測試、ad-hoc 簽章、打包 `.dmg`

**合計估算：約 1.3 億～2.6 億 token**（大多是重複讀取的內容，實際寫出的程式碼約 300 萬～500 萬 token）

## 4. 檢查點

- **階段 1 結束**：先實際用一陣子，再決定後面要做哪些
- 第 3～7 階段彼此獨立，可以照使用頻率調整順序，用不到的可以跳過

## 5. 無法完全對等的功能

| Windows 功能 | Mac 做法 |
|---|---|
| 登錄檔、INI | `NSUserDefaults`／plist |
| 檔案關聯（登錄檔寫入） | Info.plist 宣告＋Launch Services |
| WMI／WQL | 沒有對應，改用其他系統查詢方式 |
| DPAPI、CryptProtectMemory | 鑰匙圈、`mlock`＋手動清除 |
| Image File Execution Options（取代系統記事本） | 沒有對應，只能設為預設開啟程式 |
| F11 全螢幕 | Mac 的 F11 是「顯示桌面」，改用 ⌃⌘F |

---

## 6. 階段 1 實作紀錄

### 專案結構
```
Notepad2XS-Mac/
├── PLAN.md                     本計畫
├── build.sh                    一鍵建置（Scintilla ＋ App）
├── scripts/build_scintilla.sh  編譯 Scintilla 靜態函式庫
├── resources/Info.plist        App 設定、可開啟的檔案類型
├── src/                        Mac 版程式碼（Objective-C++，ARC）
│   ├── main.mm
│   ├── AppDelegate.*           繁中選單、全域設定
│   ├── Document.*              NSDocument：讀檔、存檔、編碼、換行
│   ├── TextEncoding.*          編碼判斷與轉換
│   ├── EditorWindowController.* 編輯視窗、狀態列、選單動作
│   ├── FindPanel.*             尋找／取代浮動視窗
│   ├── Settings.*              全域設定（NSUserDefaults）
│   ├── SyntaxStyles.*          依副檔名的語法上色、反向色彩、註解符號
│   ├── EditorCommands.mm       文字處理指令（格式、工具、插入、行操作）
│   ├── TextTransforms.*        文字轉換純函式（可單元測試）
│   └── PreferencesWindow.*     偏好設定視窗
├── tests/                      單元測試（./tests/run_tests.sh）
├── vendor/scintilla3112/       官方 Scintilla 3.11.2（SourceForge 下載）
└── build/                      建置產物（Notepad2XS.app）
```

### 建置
```bash
./build.sh            # 產生 build/Notepad2XS.app（Universal：x86_64＋arm64）
./build.sh dmg        # 另外打包 build/Notepad2XS.dmg
ARCH=x86_64 ./build.sh  # 只編 Intel 版（較快）
open build/Notepad2XS.app
./tests/run_tests.sh  # 單元測試
```

### 階段 1 已完成的功能
- 新增、開啟、儲存、另存新檔、回復到已儲存、最近使用的檔案、多視窗、拖曳檔案到 Dock 圖示開啟
- 編碼自動判斷：BOM（UTF-8／UTF-16 LE／BE）→ 合法 UTF-8 → Big5（CP950＋倚天擴充字）→ GB18030 → Shift-JIS → Windows-1252
- 手動指定存檔編碼、以指定編碼重新載入
- 換行格式判斷與轉換（Windows CRLF／Unix LF／舊 Mac CR）
- 復原、重做、剪下、複製、貼上、刪除、全選
- 尋找（大小寫、全字、正規表示式、反向、繞回）、取代、全部取代、找下一個／上一個
- 跳至行、插入時間／日期、轉大寫／小寫
- 自動換行、字型選擇、行號、狀態列、放大縮小、全螢幕
- 語法上色：C／C++、Objective-C、Java、Kotlin、C#、JavaScript、TypeScript、Swift、JSON、Python、PHP、HTML、XML、CSS、SQL、Shell、Batch、INI、Markdown、Makefile、Diff（也可從「格式 → 語法上色」手動選）
- 設定保存：字型、字級、自動換行、行號、狀態列

### 技術筆記
- **Big5 對照表**：Apple 的 CP950 缺倚天擴充字（C6xx 假名等），iconv 的 BIG5 缺 €。
  `TextEncoding.mm` 合併兩者建表，再修正 4 個與 Windows 不同的字（€ ⊙ 十 卅），已與完整 CP950 表逐字比對一致；存檔用同一張表，位元組不變。
- **行號欄被蓋住**：新版 macOS 的 NSScrollView 讓尺規浮在內容上，並自動加左內距，Scintilla 3.x 會誤判成水平捲動。
  `EditorWindowController.mm` 的 `N2ScintillaScrollView` 在排版時把內距歸零並縮小 clip view（執行時替換類別，不改 Scintilla 原始碼）。
- **macOS 14 裁切**：新 SDK 預設 `clipsToBounds = NO`，已對編輯區與狀態列開啟裁切。

### 驗證紀錄（2026-11-21，macOS 26.6 x86_64，Xcode 26.5）
- 編碼單元測試 35 項全過（BOM、UTF-16、Big5＋倚天擴充＋€ 位元組完全還原、Windows-1252、強制編碼、存不下的字回報錯誤、換行判斷）
- 實機操作：開啟 Big5 檔正確顯示假名 → 輸入 → 存檔仍為 Big5＋CRLF；「全部取代」後存檔位元組正確；C 檔語法上色、行號、狀態列正常；新文件另存視窗為中文、預設「未命名.txt」

### 已知限制（之後處理）
- 新文件預設為 UTF-8、LF；之後可在偏好設定改成 CRLF
- 尚未支援深色模式（編輯區固定白底）
- 中日文輸入法由 Scintilla Cocoa 處理，尚未做完整實機測試
- 尚未合併原版 Scintilla 的 Boost.Regex 修改，正規表示式用 Scintilla 內建引擎

---

## 7. 階段 2 實作紀錄（2026-11-21）

### 與 Windows 版一致的規則（已讀原始碼確認）
- 編碼與解碼作用在**文件編碼的位元組**：UTF-8 文件用 UTF-8，Big5 文件用 Big5 位元組；UTF-16 文件的十六進位每字 4 位
- 十六進位一律大寫；URL 只保留 `A-Z a-z 0-9 - _ . ~`；QP 每行 76 字元前插入 `=\r\n` 軟換行
- 解碼時略過空白與換行；沒有選取時作用在整份文件
- 排序對話框選項與原版相同（遞增／遞減／隨機／保留／反轉、合併重複、移除重複、移除不重複、不分大小寫、數值邏輯比較）；不分大小寫時只差大小寫的行視為相同並保持原順序
- 修改行支援 `$(L)` `$(N)` `$(I)` 與補零版 `$(0L)` 等變數
- 反向色彩：所有樣式 RGB 反轉，只影響編輯區，不影響列印

### 與 Windows 版不同的地方
- 快捷鍵改用 Mac 慣例（Ctrl→⌘、Alt→⌥），避開 ⌘W／⌘Q 等系統鍵；多數轉換功能沒有預設快捷鍵
- Base64／十六進位解碼遇到無效資料會提示錯誤並不修改文件（原版會部分解碼）
- 「依欄排序與合併（矩形選取）」與「起始行號」尚未實作
- 「醒目提示目前選取範圍」只做一種模式（標示畫面上與選取相同的文字）

### 驗證紀錄
- 單元測試：編碼 35 項＋文字轉換 54 項全部通過（含 RFC 4648 Base64 向量）
- 實機操作：Base64 編碼／解碼往返；Big5 文件「悟空」轉十六進位得 `AEA9AAC5`（與 CP950 一致）並還原；排序對話框（合併重複＋數值邏輯）結果正確；
  左右分割＋反向色彩＋空白字元＋行號畫面正常；醒目提示相同文字正常；偏好設定變更即時套用；列印預覽含頁首、語法顏色與頁碼
- 修正：醒目提示填入標示會觸發內容更新通知而無限重繪（CPU 98%），改成只在選取或捲動改變時重算

### 已知限制
- 第一次列印時 macOS 會詢問是否允許尋找區域網路裝置（找印表機用），由使用者決定

---

## 8. 階段 3～6 實作紀錄（2026-11-21）

### 沿用原版程式碼（src/core，未改演算法）
| 檔案 | 用途 | Mac 修改 |
|---|---|---|
| ExAlgorithms.cpp | EX_MD3、EXES（60,000 次加鹽衍生） | 無（亂數用 /dev/urandom，原版已支援） |
| AesAlgorithms.cpp | Notepad2XS AES-GCM v1 | 新增 Apple 後端：CommonCrypto PBKDF2＋AES，GCM（CTR＋常數時間 GHASH）自行組合 |
| KeyFileCore.h、CryptoPrefix.h、PasswordGenerator.h | 金鑰檔案衍生、前綴判斷、隨機密碼 | 無 |
| OrCore.cpp | AI 請求組裝、回應解析、範本、設定格式 v4 | 無（Boost.JSON 只取用到的 285 個標頭，vendor/boost 2.8 MB） |
| MathSelection.cpp、tinyexpr.c | F5 數學區塊與變數 | tinyexpr 補上 `_countof`／`strcpy_s` 相容定義 |
| SqlSelection.cpp、SqlResults.cpp | F5 標記解析、WHERE 檢查、報表與匯出 | 無 |
| ChineseMoney.h | 中文金額 | 無 |

### 與 Windows 版的互通驗證
- AES：測試建置已知答案向量與 Windows 版位元組完全相同；正式 600,000 次密文由 Apple CryptoKit 獨立解密成功
- EXES：三組原始 JS 產生的 60,000 次向量（ASCII、中文＋Emoji＋NUL、金鑰檔案）加密結果完全相同
- 實機：開啟 Windows 向量產生的 X60 檔 → 自動要求密碼 → 解密 → 修改存檔 → 仍為 EXES 密文且可解；`.u2f` 存檔要求密碼並寫成 AES；金鑰檔案模式加密後以獨立工具解密成功

### Mac 版做法說明
- 密碼／預設密鑰／AI 設定（含 API Key）存在 macOS 鑰匙圈（取代 DPAPI）；開發版每次重新建置簽章會改變，鑰匙圈可能再詢問一次授權
- 壓縮檔：ZIP 用系統 `zip` 只替換單一成員並比對其他成員 CRC32；7Z／TAR 系列用 `bsdtar` 重建後完整解開逐檔比對；RAR、ISO、CAB、CPIO 等轉成 ZIP，原檔改名 `.bak`；WIM 不支援
- F5：Windows 專用的 `[DOSCMD]`、`[VBSCRIPT]`、`[WQL]` 會提示替代方案；新增 `[SHCMD]`（zsh）與 `[SYSINFO]`（system_profiler）；`[JAVASCRIPT]` 改用 macOS JavaScript for Automation；`[PSCMD]` 需安裝 PowerShell 7
- 腳本與 SSH 在「終端機」執行，runner 保存在 `~/Library/Application Support/Notepad2XS/logs`，結束後顯示結束代碼並等待 Enter
- 數學答案格式與 Windows 狀態列十進位模式相同（整數千分位、小數 2 位、太小改 6 位）；十六進位／二進位等模式尚未提供切換

### 驗證紀錄
- 單元測試：編碼 35＋文字轉換 54＋加解密 19＋AES 已知答案 2＋CryptoKit 交叉 2＋F5 14 項（共 126 項），全部通過（`./tests/run_tests.sh`）
- 實機：EXES／AES 自動解密與重新加密存檔、金鑰檔案、ZIP 單一／多成員回寫（其他成員 CRC 不變）、7z／tar.gz 回寫（二進位成員雜湊不變）、cpio 轉 ZIP、
  AI 指令視窗預覽與連線錯誤處理（假金鑰，未儲存）、數學多行變數、中文金額、系統資訊查詢、curl、[SHCMD] 結束代碼與等待、SQL 找不到 DSN 的提示

### 尚未實機驗證
- 實際 AI 回答的套用（需要你的 API Key）
- 實際 SQL 查詢（需要安裝資料庫 ODBC 驅動並設定 DSN）
- SSH 連線、FTP（Finder）、[PSCMD]、[JAVASCRIPT]、網址密鑰下載

---

## 9. 階段 7～8 實作紀錄（2026-11-21）

### 沿用原版程式碼（src/core）
CsvTableCore.h（CSV 解析、儲存格暫存、列欄增刪、全欄位加引號）、FileSearchCore.h（檔名比對、日期與大小條件、CSV 儲存格）、
SecureEraseCore.h（覆寫／同步／回讀驗證／刪除流程）、JpegCommentFormat.cpp（N2XSJPG1 COM 讀寫），均未修改演算法。
版本歷史原版用 Windows API，Mac 版依相同規則重寫（History.mm）。

### Mac 版做法
- 表格模式：編輯 → 表格模式（只限 .csv／.tsv，加密文件需先解密），套用是一個復原步驟
- 檔案搜尋：位置可選家目錄、整台電腦（略過 /System 等系統資料夾）或外接磁碟；上限 100,000 筆
- 安全刪除：同一個檔案描述子從檢查到刪除，拒絕符號連結與多個硬連結；壓縮檔內文件會刪除整個壓縮檔；完成後關閉文件
- JPEG：TXT 模式為權威標記；加密模式開檔自動要求密碼；新建 JPEG 用原版預設底圖（SHA-256 550c836c…）；圖片位元組不重新編碼
- 版本歷史：預設關閉；備份位置預設 ~/Library/Application Support/Notepad2XS/history，可在偏好設定變更；備份失敗就停止存檔
- 介面語言：選單、狀態列、尋找視窗、偏好設定分頁與標題已翻譯 8 種語言；**對話框與錯誤訊息仍是繁體中文**
- 檔案類型：.x60／.u2f 宣告為本程式擁有的類型（雙擊開啟）；txt、程式碼、CSV、JSON、XML、JPEG、ZIP、7z、tar 出現在「打開方式」
- 簽章：ad-hoc（沒有 Apple Developer ID）。在其他 Mac 第一次開啟需在 Finder 按右鍵 →「打開」，或到「系統設定 → 隱私權與安全性」允許

### 驗證紀錄
- 單元測試：126 項全部通過
- 實機：JPEG 明文存檔（圖片尺寸不變）、AES 加密存檔（COM 模式 Aes）、重開自動解密；CSV 新增欄列＋套用（全部加引號、含逗號欄位正確）；
  版本歷史備份兩版、還原舊版後存檔；安全刪除 200 KB 檔案（覆寫驗證並刪除）；檔案搜尋家目錄找到測試檔（28.5 秒）；
  日文介面選單與狀態列；關於視窗；Universal Binary 在 Intel Mac 上執行正常
- arm64 版只確認有編進去（lipo），沒有在 Apple 晶片 Mac 上實際執行

### 仍未完成／與 Windows 版不同
- WIM 編輯、JPEG 以外的圖片轉文字（R121～R123 圖片轉文字）、系統資訊選單（MIS 工具）、開始選單、Windows 檔案關聯精靈等 Windows 專屬功能未移植
- 對話框訊息的多語系、數學答案的十六進位／二進位模式、矩形選取依欄排序、起始行號

## 10. 補充：視窗工具列（2026-11-22）

- 對應原版 `tbbMainWnd`／`CLASSIC_MENU_TOOLBAR_zh-TW.md`：預設 18 個按鈕，分成 7 組（檔案｜復原｜剪貼簿｜搜尋｜閱讀｜執行｜加解密），組和組之間用空白隔開。
- 實作在 `src/EditorToolbar.mm`，使用 macOS 原生 NSToolbar。圖示用 SF Symbols；按鈕名稱和快捷鍵直接取自主選單，所以會跟著介面語言變。
- 自訂工具列：右鍵 →「自訂工具列…」，或「檢視 → 自訂工具列…」。另外可再加入 25 個按鈕，例如另存新檔、版本歷史、AES、分割視窗、最上層顯示、檔案搜尋、CSV 等。排列會自動保存，所有視窗同步。
- 「檢視 → 工具列」（⌥⌘T）可以顯示或隱藏工具列；「檢視 → 重設工具列」會還原成原版的預設排列；「檢視 → 最上層顯示」對應原版的 IDM_VIEW_ALWAYSONTOP。
- EXES／AES 按鈕在空白文件中停用（與原版相同）；人工智慧按鈕維持可用。
- 驗證：確認 18 個按鈕的名稱與順序正確，空白文件中的停用狀態正確，自動換行按鈕可以使用。
- 與 Windows 版的差異：自訂視窗是 macOS 系統內建的，它的文字跟隨系統語言，不會跟著 App 的介面語言。

## 11. 程式碼審查與修正（2026-11-22）

整個 `src/` 做了一次完整審查（找到 35 項），全部處理完畢：

| 類別 | 修正內容 |
|---|---|
| 安全性 | 壓縮檔成員名稱不再被當成 bsdtar／zip 的選項（`--`、`./` 前綴、`-nw`），ZIP 改為自行讀取中央目錄，不再把成員名稱交給 unzip；CSV 匯出加上公式注入防護；憑證改以整頁配置後 mlock |
| 中文檔名 | 外部工具改用 UTF-8 語系，壓縮檔內的中文成員名稱可正常列出、開啟、回存 |
| 唯讀／鎖定 | 唯讀時「全部取代」不再無限迴圈；鎖定時重新載入、回復到已儲存、改換行／編碼都正確處理 |
| 資料正確性 | 文字轉換保留 NUL；落單 UTF-16 代理字元不再當掉；URL／QP 解碼先轉成文件編碼；JPEG 不能用其他編碼重新載入；CSV 解碼失敗時不再變成空表格；硬連結 tar 可以回存 |
| 加解密 | 加解密後清空復原紀錄（避免 ⌘Z 讓內容與加密狀態不一致），文件維持「未儲存」直到存檔；儲存複本不改變原文件的加密設定；網址金鑰改網址後作廢舊下載；NSURLSession 不再洩漏 |
| 存檔 | 存檔改用修改次數判斷：存檔期間又有輸入時保持「未儲存」；壓縮檔回存改在背景執行，畫面不會卡住；開啟壓縮檔的列出／解出也在背景 |
| 效能 | AES-GCM 的 CTR 改用 CommonCrypto 整段處理（60 MiB 加密約 1.6 秒）；設定變更只在字型／反向色彩改變時重套語法樣式，且只上色一次 |
| 工具列 | 選單與工具列共用同一套停用規則；分隔線改用自訂項目（取代已棄用的 Space／Separator 識別碼） |
| 整理 | 共用的字串轉換、記錄資料夾、鑰匙圈讀寫集中到 `N2Common.h/.mm`；字型面板程式碼合併到 `N2Settings` |

新增測試：`tests/test_archive.mm`（中文成員、惡意成員名稱、`-` 開頭名稱、硬連結、7z、tar.gz、加密 ZIP，共 36 項）、`tests/test_strings.mm`（6 項）。

實機驗證：NUL 檔案移除行尾空白、UTF-16 解碼 D800、Big5 URL 解碼、鎖定文件全部取代／改換行、手動加密後回復、手動解密後 ⌘Z、JPEG 重新載入選單停用、空白文件選單停用、App 內 ZIP（中文成員）與 7z 回存、匯出切換格式時副檔名同步。
