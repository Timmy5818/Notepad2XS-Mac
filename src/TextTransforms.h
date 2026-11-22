// 文字轉換（純函式，不碰 UI；可單元測試）
// 位元組層級的轉換規則與 Windows 版 NotePad2-XS（StrToBase64/URL/Hex/QP.c）一致：
//   - 十六進位一律大寫
//   - URL：只保留 A-Z a-z 0-9 - _ . ~，其餘位元組轉成 %XX
//   - QP：33–60、62–126 原樣；空白／Tab 只有不在結尾時原樣；其餘 =XX；每行 76 字元前插入軟換行 "=\r\n"
//   - 解碼時略過空白與換行（ASCII 0x20 以下）
#pragma once
#import <Foundation/Foundation.h>
#include <string>
#include <vector>

namespace n2 {

std::string Base64Encode(const std::string &bytes);
bool Base64Decode(const std::string &text, std::string &out);

std::string URLEncode(const std::string &bytes);
std::string URLDecode(const std::string &text);

std::string HexEncode(const std::string &bytes);
bool HexDecode(const std::string &text, std::string &out);
// UTF-16 文件：每個 UTF-16 單位輸出 4 位十六進位。bigEndianDigits=YES 時 "A" → "0041"
std::string HexEncodeUTF16(const std::u16string &units, bool bigEndianDigits);
bool HexDecodeUTF16(const std::string &text, bool bigEndianDigits, std::u16string &out);

std::string QPEncode(const std::string &bytes);
std::string QPDecode(const std::string &text);

}  // namespace n2

// ---- 字串層級 ----
NSString *N2EscapeCChars(NSString *s);
NSString *N2UnescapeCChars(NSString *s);
NSString *N2EscapeHTML(NSString *s);
NSString *N2StripHTMLTags(NSString *s);
NSString *N2InvertCase(NSString *s);
NSString *N2TitleCase(NSString *s);
NSString *N2SentenceCase(NSString *s);
// 單一字元 → \xNN 或 \uNNNN；不是單一字元時回傳 nil
NSString *N2CharToCHex(NSString *s);
// \xNN、\uNNNN、0xNN、xNN、NN → 字元；格式不對回傳 nil
NSString *N2CHexToChar(NSString *s);

// ---- 行處理（傳入的行不含換行字元） ----
typedef NS_ENUM(NSInteger, N2SortOrder) {
    N2SortAscending = 0,
    N2SortDescending,
    N2SortShuffle,
    N2SortKeepOrder,
    N2SortReverse,
};

typedef struct {
    N2SortOrder order;
    BOOL mergeDuplicates;    // 合併重複行（保留一行）
    BOOL removeDuplicates;   // 移除重複行（全部移除）
    BOOL removeUnique;       // 移除不重複的行
    BOOL caseInsensitive;
    BOOL logical;            // 依數值邏輯比較（類似 Finder 排序：file2 < file10）
} N2SortOptions;

NSArray<NSString *> *N2SortLines(NSArray<NSString *> *lines, N2SortOptions opt);

NSArray<NSString *> *N2TrimTrailingWhitespace(NSArray<NSString *> *lines);
NSArray<NSString *> *N2CompressWhitespace(NSArray<NSString *> *lines);   // 連續空白壓成一個，並去頭尾
NSArray<NSString *> *N2RemoveBlankLines(NSArray<NSString *> *lines, BOOL mergeOnly);
NSArray<NSString *> *N2StripFirstChar(NSArray<NSString *> *lines);
NSArray<NSString *> *N2StripLastChar(NSArray<NSString *> *lines);
NSArray<NSString *> *N2PadWithSpaces(NSArray<NSString *> *lines);        // 補到最長行的寬度
NSArray<NSString *> *N2TabsToSpaces(NSArray<NSString *> *lines, NSInteger tabWidth, BOOL indentOnly);
NSArray<NSString *> *N2SpacesToTabs(NSArray<NSString *> *lines, NSInteger tabWidth, BOOL indentOnly);
// 修改行：前綴／後綴，支援 $(L) $(0L) 行號、$(N) $(0N) 從 1 起算、$(I) $(0I) 從 0 起算
NSArray<NSString *> *N2ModifyLines(NSArray<NSString *> *lines, NSString *prefix, NSString *suffix, NSInteger firstLineNumber);
// 合併段落：以空白行分段，段內各行合併
NSArray<NSString *> *N2JoinParagraphs(NSArray<NSString *> *lines, BOOL noSpace);
NSArray<NSString *> *N2JoinLines(NSArray<NSString *> *lines, BOOL noSpace);
// 依欄寬換行（以字元寬度計算，全形字算 2）
NSArray<NSString *> *N2WrapToColumn(NSArray<NSString *> *lines, NSInteger column);
// 切換行註解；token 例如 "//"、"#"
NSArray<NSString *> *N2ToggleLineComment(NSArray<NSString *> *lines, NSString *token);

// 拆行／合併（以任一種換行分割）
NSArray<NSString *> *N2SplitLines(NSString *text);
