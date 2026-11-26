// 文字編碼判斷與轉換。編輯器內部一律使用 UTF-8。
#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, N2Encoding) {
    N2EncodingUTF8 = 0,
    N2EncodingUTF8BOM,
    N2EncodingUTF16LE,     // 含 BOM
    N2EncodingUTF16BE,     // 含 BOM
    N2EncodingBig5,        // Windows CP950（繁中 ANSI）
    N2EncodingGB18030,
    N2EncodingShiftJIS,    // Windows CP932
    N2EncodingWindows1252,
    N2EncodingCount
};

// 顯示用名稱（狀態列、選單）
NSString *N2EncodingDisplayName(N2Encoding enc);

// 把檔案原始位元組解成 UTF-8（不含 BOM）。
// autodetect=YES 時自動判斷並把結果寫回 *ioEncoding；NO 時強制用 *ioEncoding。
// 強制的編碼無法解碼時回傳 nil。
NSData *N2DecodeToUTF8(NSData *raw, N2Encoding *ioEncoding, BOOL autodetect);

// 把 UTF-8 位元組轉成指定編碼（含必要 BOM）。有字元無法轉換時回傳 nil 並設定 error。
NSData *N2EncodeFromUTF8(const char *utf8, size_t length, N2Encoding enc, NSError **error);

// 依內容判斷換行格式，回傳 Scintilla 的 SC_EOL_CRLF / SC_EOL_CR / SC_EOL_LF；沒有換行時回傳 defaultMode。
int N2DetectEOLMode(const char *utf8, size_t length, int defaultMode);

// 嚴格檢查是否為合法 UTF-8
BOOL N2IsValidUTF8(const unsigned char *p, size_t n);

// 個別檔案開檔編碼（R155）：與 Windows 版編碼資源 ID（61000 起）互換
// BOM 版本與無 BOM 版本使用同一個 ID（讀取時 BOM 會自動判斷）
int N2EncodingReadResource(N2Encoding enc);
BOOL N2EncodingForReadResource(int resource, N2Encoding *enc);   // 不支援的編碼回傳 NO
