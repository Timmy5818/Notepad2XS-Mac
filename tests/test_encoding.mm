// 編碼判斷／轉換測試：./tests/run_tests.sh
#import <Foundation/Foundation.h>
#import "TextEncoding.h"
#include "Scintilla.h"

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fails++; printf("✗ %s\n", msg); } else printf("✓ %s\n", msg); } while (0)

static NSData *Enc(NSString *s, CFStringEncoding cf) {
    return [s dataUsingEncoding:CFStringConvertEncodingToNSStringEncoding(cf)];
}

static void RoundTrip(NSString *text, NSData *raw, N2Encoding expect, const char *name) {
    N2Encoding enc = N2EncodingUTF8;
    NSData *utf8 = N2DecodeToUTF8(raw, &enc, YES);
    NSString *back = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
    char msg[256];
    snprintf(msg, sizeof msg, "%s：判斷為 %s", name, N2EncodingDisplayName(enc).UTF8String);
    CHECK(enc == expect, msg);
    snprintf(msg, sizeof msg, "%s：內容正確", name);
    CHECK([back isEqualToString:text], msg);
    NSData *saved = N2EncodeFromUTF8((const char *)utf8.bytes, utf8.length, enc, NULL);
    snprintf(msg, sizeof msg, "%s：存回後位元組完全相同", name);
    CHECK([saved isEqualToData:raw], msg);
}

int main() {
    @autoreleasepool {
        NSString *zh = @"悟空與達爾：かめはめ波！ Kamehameha\r\n第二行\r\n";
        NSString *ascii = @"hello world\nline 2\n";

        RoundTrip(ascii, [ascii dataUsingEncoding:NSUTF8StringEncoding], N2EncodingUTF8, "純 ASCII");
        RoundTrip(zh, [zh dataUsingEncoding:NSUTF8StringEncoding], N2EncodingUTF8, "UTF-8");
        NSMutableData *bom = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
        [bom appendData:[zh dataUsingEncoding:NSUTF8StringEncoding]];
        RoundTrip(zh, bom, N2EncodingUTF8BOM, "UTF-8 BOM");
        NSMutableData *le = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
        [le appendData:[zh dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
        RoundTrip(zh, le, N2EncodingUTF16LE, "UTF-16 LE BOM");
        NSMutableData *be = [NSMutableData dataWithBytes:"\xFE\xFF" length:2];
        [be appendData:[zh dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
        RoundTrip(zh, be, N2EncodingUTF16BE, "UTF-16 BE BOM");

        NSString *big5Text = @"專家記事本：七龍珠與星際大戰\r\n繁體中文測試\r\n";
        RoundTrip(big5Text, Enc(big5Text, kCFStringEncodingDOSChineseTrad), N2EncodingBig5, "Big5");
        // 倚天擴充字（日文假名在 C6xx）＋ CP950 的 € 混在同一個檔案
        const unsigned char mixed[] = { 0xB1,0x4D, 0xAE,0x61, ' ', 0xC6,0xAF, 0xC6,0xE5, ' ', 0xA3,0xE1, 0xF9,0xD6, '\r','\n' };
        RoundTrip(@"專家 かめ €碁\r\n", [NSData dataWithBytes:mixed length:sizeof mixed], N2EncodingBig5, "Big5 混合倚天擴充字與 €");
        // 重複字與 Windows 專有字要存成標準 CP950 位元組
        const char *dup = "十卅€⊙";
        NSData *dupOut = N2EncodeFromUTF8(dup, strlen(dup), N2EncodingBig5, NULL);
        const unsigned char dupExpect[] = { 0xA4,0x51, 0xA4,0xCA, 0xA3,0xE1, 0xA1,0xF3 };
        CHECK([dupOut isEqualToData:[NSData dataWithBytes:dupExpect length:sizeof dupExpect]], "十卅€⊙ 存成標準 CP950 位元組");
        NSString *latin = @"Café crème über\n";
        RoundTrip(latin, [latin dataUsingEncoding:NSWindowsCP1252StringEncoding], N2EncodingWindows1252, "Windows-1252");

        // 強制編碼重新載入
        NSString *sj = @"日本語のテキスト\n";
        N2Encoding forced = N2EncodingShiftJIS;
        NSData *u = N2DecodeToUTF8(Enc(sj, kCFStringEncodingDOSJapanese), &forced, NO);
        CHECK([[[NSString alloc] initWithData:u encoding:NSUTF8StringEncoding] isEqualToString:sj], "強制 Shift-JIS 重新載入");

        // 無法轉換時要回報錯誤，不可默默變成問號
        NSError *err = nil;
        const char *emoji = "Goku \xF0\x9F\x90\x89";
        NSData *bad = N2EncodeFromUTF8(emoji, strlen(emoji), N2EncodingBig5, &err);
        CHECK(bad == nil && err != nil, "Big5 存不下表情符號時回報錯誤");

        // UTF-8 驗證
        CHECK(!N2IsValidUTF8((const unsigned char *)"\xC0\xAF", 2), "拒絕過長 UTF-8 編碼");
        CHECK(!N2IsValidUTF8((const unsigned char *)"\xED\xA0\x80", 3), "拒絕代理字元");
        CHECK(N2IsValidUTF8((const unsigned char *)"\xF0\x9F\x90\x89", 4), "接受 4 位元組字元");

        // 換行判斷
        CHECK(N2DetectEOLMode("a\r\nb\r\n", 6, SC_EOL_LF) == SC_EOL_CRLF, "判斷 CRLF");
        CHECK(N2DetectEOLMode("a\nb\n", 4, SC_EOL_CRLF) == SC_EOL_LF, "判斷 LF");
        CHECK(N2DetectEOLMode("a\rb\r", 4, SC_EOL_LF) == SC_EOL_CR, "判斷 CR");
        CHECK(N2DetectEOLMode("abc", 3, SC_EOL_LF) == SC_EOL_LF, "沒有換行時用預設值");

        // 空檔案
        N2Encoding e0 = N2EncodingBig5;
        NSData *empty = N2DecodeToUTF8([NSData data], &e0, YES);
        CHECK(empty.length == 0 && e0 == N2EncodingUTF8, "空檔案視為 UTF-8");

        printf("\n%s（失敗 %d 項）\n", fails ? "有測試失敗" : "全部通過", fails);
    }
    return fails ? 1 : 0;
}
