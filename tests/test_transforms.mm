// 文字轉換測試
#import <Foundation/Foundation.h>
#import "TextTransforms.h"

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fails++; printf("✗ %s\n", msg); } else printf("✓ %s\n", msg); } while (0)
static std::string U8(NSString *s) { return std::string(s.UTF8String); }
static NSArray *L(NSString *s) { return N2SplitLines(s); }
static NSString *J(NSArray *a) { return [a componentsJoinedByString:@"\n"]; }

int main() {
    @autoreleasepool {
        using namespace n2;
        // Base64（RFC 4648 測試向量）
        CHECK(Base64Encode("") == "" && Base64Encode("f") == "Zg==" && Base64Encode("fo") == "Zm8=" &&
              Base64Encode("foobar") == "Zm9vYmFy", "Base64 編碼（RFC 4648 向量）");
        std::string out;
        CHECK(Base64Decode("Zm9v\r\nYmFy", out) && out == "foobar", "Base64 解碼略過換行");
        CHECK(Base64Decode(Base64Encode(U8(@"悟空かめはめ波")), out) && out == U8(@"悟空かめはめ波"), "Base64 中日文往返");
        CHECK(!Base64Decode("Zm9v!", out), "Base64 非法字元回報錯誤");
        CHECK(!Base64Decode("Zg=a", out), "Base64 '=' 位置錯誤回報錯誤");

        // URL
        CHECK(URLEncode(U8(@"a b/悟~-_.")) == "a%20b%2F%E6%82%9F~-_.", "URL 編碼（保留 A-Z a-z 0-9 - _ . ~，大寫十六進位）");
        CHECK(URLDecode("a%20b%2f%E6%82%9F%zz%") == U8(@"a b/悟%zz%"), "URL 解碼（大小寫皆可、無效序列原樣保留）");

        // Hex
        CHECK(HexEncode("AB\n") == "41420A", "Hex 編碼");
        CHECK(HexDecode("41 42\r\n0a", out) && out == "AB\n", "Hex 解碼略過空白");
        CHECK(!HexDecode("414", out) && !HexDecode("4G", out), "Hex 長度或字元錯誤回報錯誤");
        std::u16string u16 = u"A悟";
        CHECK(HexEncodeUTF16(u16, true) == "0041609F", "UTF-16 文件 Hex（LE 文件，高位在前）");
        CHECK(HexEncodeUTF16(u16, false) == "41009F60", "UTF-16 文件 Hex（BE 文件，低位在前）");
        std::u16string back;
        CHECK(HexDecodeUTF16("0041609F", true, back) && back == u16, "UTF-16 Hex 解碼");

        // QP
        CHECK(QPEncode(U8(@"café=1")) == "caf=C3=A9=3D1", "QP 編碼（非 ASCII 與 '='）");
        CHECK(QPEncode("a b ") == "a b=20", "QP 結尾空白編碼");
        CHECK(QPEncode("x\r\n") == "x=0D=0A", "QP 換行編碼（與原版一致）");
        std::string longIn(100, 'a');
        std::string qp = QPEncode(longIn);
        CHECK(qp.find("=\r\n") == 75 && QPDecode(qp) == longIn, "QP 76 字元軟換行與往返");
        CHECK(QPDecode("caf=C3=A9=3D1=\r\nX") == U8(@"café=1X"), "QP 解碼含軟換行");

        // C 逸出、HTML
        CHECK([N2EscapeCChars(@"a\\b\"c'd") isEqualToString:@"a\\\\b\\\"c\\'d"], "逸出 C 字元");
        CHECK([N2UnescapeCChars(@"a\\\\b\\\"c\\'d") isEqualToString:@"a\\b\"c'd"], "還原 C 逸出字元");
        CHECK([N2EscapeHTML(@"<a href=\"x\">&</a>") isEqualToString:@"&lt;a href=\"x\"&gt;&amp;&lt;/a&gt;"], "逸出 HTML");
        CHECK([N2StripHTMLTags(@"<p>七<b>龍</b>珠</p>") isEqualToString:@"七龍珠"], "移除 HTML 標籤");
        CHECK([N2CharToCHex(@"A") isEqualToString:@"\\x41"] && [N2CharToCHex(@"悟") isEqualToString:@"\\u609F"] &&
              N2CharToCHex(@"AB") == nil, "字元轉 C 十六進位");
        CHECK([N2CHexToChar(@"\\u609F") isEqualToString:@"悟"] && [N2CHexToChar(@"0x41") isEqualToString:@"A"] &&
              N2CHexToChar(@"zz") == nil, "C 十六進位轉字元");

        // 大小寫
        CHECK([N2InvertCase(@"Goku 悟空") isEqualToString:@"gOKU 悟空"], "切換大小寫");
        CHECK([N2TitleCase(@"hello WORLD, it's goku") isEqualToString:@"Hello World, It's Goku"], "每個字首大寫");
        CHECK([N2SentenceCase(@"HELLO. how ARE you? fine") isEqualToString:@"Hello. How are you? Fine"], "句首大寫");

        // 排序
        NSArray *src = L(@"file10\nFile2\nfile2\nb\na\nb");
        N2SortOptions o = {N2SortAscending, NO, NO, NO, NO, NO};
        o.logical = YES; o.caseInsensitive = YES;
        CHECK([J(N2SortLines(src, o)) isEqualToString:@"a\nb\nb\nFile2\nfile2\nfile10"], "排序：遞增＋邏輯數值＋不分大小寫（穩定）");
        o = (N2SortOptions){N2SortKeepOrder, YES, NO, NO, YES, NO};
        CHECK([J(N2SortLines(src, o)) isEqualToString:@"file10\nFile2\nb\na"], "合併重複行（保留順序、不分大小寫）");
        o = (N2SortOptions){N2SortKeepOrder, NO, YES, NO, NO, NO};
        CHECK([J(N2SortLines(src, o)) isEqualToString:@"file10\nFile2\nfile2\na"], "移除重複行（全部移除）");
        o = (N2SortOptions){N2SortKeepOrder, NO, NO, YES, NO, NO};
        CHECK([J(N2SortLines(src, o)) isEqualToString:@"b\nb"], "移除不重複的行");
        o = (N2SortOptions){N2SortReverse, NO, NO, NO, NO, NO};
        CHECK([J(N2SortLines(L(@"1\n2\n3"), o)) isEqualToString:@"3\n2\n1"], "反轉行順序");
        o = (N2SortOptions){N2SortShuffle, NO, NO, NO, NO, NO};
        NSArray *sh = N2SortLines(L(@"1\n2\n3\n4\n5"), o);
        CHECK(sh.count == 5 && [[NSSet setWithArray:sh] isEqualToSet:[NSSet setWithArray:L(@"1\n2\n3\n4\n5")]], "隨機排列保留所有行");
        o = (N2SortOptions){N2SortDescending, NO, NO, NO, NO, YES};
        CHECK([J(N2SortLines(L(@"x2\nx10\nx1"), o)) isEqualToString:@"x10\nx2\nx1"], "遞減＋邏輯數值");

        // 空白與行
        CHECK([J(N2TrimTrailingWhitespace(L(@"a  \nb\t\n c"))) isEqualToString:@"a\nb\n c"], "移除行尾空白");
        CHECK([J(N2CompressWhitespace(L(@"  a   b\t\tc  "))) isEqualToString:@"a b c"], "壓縮空白字元");
        CHECK([J(N2RemoveBlankLines(L(@"a\n\n \nb\n\nc"), NO)) isEqualToString:@"a\nb\nc"], "移除空白行");
        CHECK([J(N2RemoveBlankLines(L(@"a\n\n \nb\n\nc"), YES)) isEqualToString:@"a\n\nb\n\nc"], "合併空白行");
        CHECK([J(N2StripFirstChar(L(@"abc\n🐉x\n"))) isEqualToString:@"bc\nx\n"], "移除首字元（含表情符號）");
        CHECK([J(N2StripLastChar(L(@"abc\nx🐉\n"))) isEqualToString:@"ab\nx\n"], "移除末字元");
        CHECK([J(N2PadWithSpaces(L(@"ab\n悟\nabcd"))) isEqualToString:@"ab  \n悟  \nabcd"], "以空格補齊（全形算 2）");
        CHECK([J(N2TabsToSpaces(L(@"\ta\tb"), 4, NO)) isEqualToString:@"    a   b"], "Tab 轉空格（依欄位）");
        CHECK([J(N2TabsToSpaces(L(@"\ta\tb"), 4, YES)) isEqualToString:@"    a\tb"], "只轉縮排的 Tab");
        CHECK([J(N2SpacesToTabs(L(@"        a   b"), 4, NO)) isEqualToString:@"\t\ta\tb"], "空格轉 Tab");
        CHECK([J(N2SpacesToTabs(L(@"    a    b"), 4, YES)) isEqualToString:@"\ta    b"], "只轉縮排的空格");
        CHECK([J(N2ModifyLines(L(@"a\nb\nc"), @"$(0N). ", @" [$(L)/$(I)]", 9)) isEqualToString:@"1. a [9/0]\n2. b [10/1]\n3. c [11/2]"],
              "修改行：編號變數");
        CHECK([J(N2JoinLines(L(@"a \n  b\nc"), NO)) isEqualToString:@"a b c"], "合併行");
        CHECK([J(N2JoinLines(L(@"七\n龍\n珠"), YES)) isEqualToString:@"七龍珠"], "合併行（不加空格）");
        CHECK([J(N2JoinParagraphs(L(@"a\nb\n\nc\nd"), NO)) isEqualToString:@"a b\n\nc d"], "合併段落");
        CHECK([J(N2WrapToColumn(L(@"aaa bbb ccc"), 7)) isEqualToString:@"aaa bbb\nccc"], "依欄寬換行（英文）");
        CHECK([J(N2WrapToColumn(L(@"悟空與達爾"), 4)) isEqualToString:@"悟空\n與達\n爾"], "依欄寬換行（中文全形）");
        CHECK([J(N2ToggleLineComment(L(@"  a\n\n    b"), @"//")) isEqualToString:@"  // a\n\n  //   b"], "加上行註解");
        CHECK([J(N2ToggleLineComment(L(@"  // a\n\n  //   b"), @"//")) isEqualToString:@"  a\n\n    b"], "移除行註解");
        CHECK([J(N2SplitLines(@"a\r\nb\rc\nd")) isEqualToString:@"a\nb\nc\nd"], "拆行（CRLF／CR／LF 混合）");

        printf("\n%s（失敗 %d 項）\n", fails ? "有測試失敗" : "全部通過", fails);
    }
    return fails ? 1 : 0;
}
