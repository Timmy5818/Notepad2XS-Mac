#import "TextEncoding.h"
#include "Scintilla.h"
#include <iconv.h>
#include <unordered_map>
#include <vector>

// ---- Big5 對照表 ----
// Apple 的 CP950 缺少倚天擴充字（如 C6xx 的日文假名），iconv 的 BIG5 又缺少 CP950 的 €。
// 所以自己建一張表：每個雙位元組先查 Apple CP950，查不到再用 iconv BIG5。
// 解碼與存檔都用這張表，確保存回去的位元組不變。
namespace {
struct Big5Table {
    std::vector<uint32_t> toUnicode;                 // index = lead<<8|trail，0 = 無對應
    std::unordered_map<uint32_t, uint16_t> fromUnicode;

    Big5Table() : toUnicode(65536, 0) {
        iconv_t cd = iconv_open("UTF-32LE", "BIG5");
        for (int lead = 0x81; lead <= 0xFE; lead++) {
            for (int trail = 0x40; trail <= 0xFE; trail++) {
                if (trail > 0x7E && trail < 0xA1) continue;
                unsigned char pair[2] = { (unsigned char)lead, (unsigned char)trail };
                uint32_t cp = 0;
                CFStringRef str = CFStringCreateWithBytes(NULL, pair, 2, kCFStringEncodingDOSChineseTrad, false);
                if (str) {
                    CFIndex n = CFStringGetLength(str);
                    UniChar u[2] = {0, 0};
                    if (n == 1) { CFStringGetCharacters(str, CFRangeMake(0, 1), u); cp = u[0]; }
                    else if (n == 2) {
                        CFStringGetCharacters(str, CFRangeMake(0, 2), u);
                        if (CFStringIsSurrogateHighCharacter(u[0])) cp = CFStringGetLongCharacterForSurrogatePair(u[0], u[1]);
                    }
                    CFRelease(str);
                }
                if (!cp && cd != (iconv_t)-1) {
                    char *in = (char *)pair; size_t inLeft = 2;
                    uint32_t out[2] = {0, 0}; char *op = (char *)out; size_t outLeft = sizeof out;
                    iconv(cd, NULL, NULL, NULL, NULL);
                    if (iconv(cd, &in, &inLeft, &op, &outLeft) != (size_t)-1 && inLeft == 0 && outLeft == 4) cp = out[0];
                }
                if (cp && cp != 0xFFFD) {
                    uint16_t code = (uint16_t)(lead << 8 | trail);
                    toUnicode[code] = cp;
                    fromUnicode.emplace(cp, code);   // 重複字保留第一個（編碼較小者）
                }
            }
        }
        if (cd != (iconv_t)-1) iconv_close(cd);

        // 與 Windows CP950 對齊（已和完整 CP950 表逐字比對，只差這 4 個）
        auto setOnly = [&](uint16_t code, uint32_t cp) {      // 只改解碼方向
            uint32_t old = toUnicode[code];
            auto it = fromUnicode.find(old);
            if (it != fromUnicode.end() && it->second == code) fromUnicode.erase(it);
            toUnicode[code] = cp;
        };
        setOnly(0xA3E1, 0x20AC); fromUnicode[0x20AC] = 0xA3E1;   // €
        setOnly(0xA1F3, 0x2299); fromUnicode[0x2299] = 0xA1F3;   // ⊙
        setOnly(0xA2CC, 0x5341);   // 十（重複字，存檔用標準的 A451）
        setOnly(0xA2CE, 0x5345);   // 卅（重複字，存檔用標準的 A4CA）
    }
};

const Big5Table &Big5() {
    static Big5Table *t = new Big5Table();
    return *t;
}

void AppendUTF8(std::string &out, uint32_t cp) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | cp >> 6); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | cp >> 12); out += (char)(0x80 | (cp >> 6 & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | cp >> 18); out += (char)(0x80 | (cp >> 12 & 0x3F)); out += (char)(0x80 | (cp >> 6 & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}
}

static NSData *DecodeBig5(const unsigned char *p, size_t n) {
    const Big5Table &t = Big5();
    std::string out;
    out.reserve(n * 3 / 2);
    for (size_t i = 0; i < n; ) {
        unsigned char c = p[i];
        if (c < 0x80) { out += (char)c; i++; continue; }
        if (i + 1 >= n) return nil;
        uint32_t cp = t.toUnicode[(size_t)c << 8 | p[i + 1]];
        if (!cp) return nil;
        AppendUTF8(out, cp);
        i += 2;
    }
    return [NSData dataWithBytes:out.data() length:out.size()];
}

static NSData *EncodeBig5(const unsigned char *s, size_t n) {
    const Big5Table &t = Big5();
    NSMutableData *out = [NSMutableData dataWithCapacity:n];
    for (size_t i = 0; i < n; ) {
        unsigned char c = s[i];
        uint32_t cp; size_t len;
        if (c < 0x80) { cp = c; len = 1; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; len = 2; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; len = 3; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; len = 4; }
        else return nil;
        if (i + len > n) return nil;
        for (size_t k = 1; k < len; k++) cp = cp << 6 | (s[i + k] & 0x3F);
        i += len;
        if (cp < 0x80) { unsigned char b = (unsigned char)cp; [out appendBytes:&b length:1]; continue; }
        auto it = t.fromUnicode.find(cp);
        if (it == t.fromUnicode.end()) return nil;
        unsigned char pair[2] = { (unsigned char)(it->second >> 8), (unsigned char)(it->second & 0xFF) };
        [out appendBytes:pair length:2];
    }
    return out;
}

static NSStringEncoding NSEnc(N2Encoding enc) {
    switch (enc) {
        case N2EncodingUTF8:
        case N2EncodingUTF8BOM:      return NSUTF8StringEncoding;
        case N2EncodingUTF16LE:      return NSUTF16LittleEndianStringEncoding;
        case N2EncodingUTF16BE:      return NSUTF16BigEndianStringEncoding;
        case N2EncodingBig5:         return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseTrad);
        case N2EncodingGB18030:      return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        case N2EncodingShiftJIS:     return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSJapanese);
        case N2EncodingWindows1252:  return NSWindowsCP1252StringEncoding;
        default:                     return NSUTF8StringEncoding;
    }
}

NSString *N2EncodingDisplayName(N2Encoding enc) {
    switch (enc) {
        case N2EncodingUTF8:         return @"UTF-8";
        case N2EncodingUTF8BOM:      return @"UTF-8 BOM";
        case N2EncodingUTF16LE:      return @"UTF-16 LE BOM";
        case N2EncodingUTF16BE:      return @"UTF-16 BE BOM";
        case N2EncodingBig5:         return @"Big5";
        case N2EncodingGB18030:      return @"GB18030";
        case N2EncodingShiftJIS:     return @"Shift-JIS (CP932)";
        case N2EncodingWindows1252:  return @"Windows-1252";
        default:                     return @"?";
    }
}

BOOL N2IsValidUTF8(const unsigned char *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = p[i];
        if (c < 0x80) { i++; continue; }
        size_t len; unsigned int cp;
        if (c >= 0xC2 && c <= 0xDF)      { len = 2; cp = c & 0x1F; }
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; cp = c & 0x0F; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; cp = c & 0x07; }
        else return NO;
        if (i + len > n) return NO;
        for (size_t k = 1; k < len; k++) {
            if ((p[i + k] & 0xC0) != 0x80) return NO;
            cp = (cp << 6) | (p[i + k] & 0x3F);
        }
        if ((len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF))) return NO;
        if (cp >= 0xD800 && cp <= 0xDFFF) return NO;
        i += len;
    }
    return YES;
}

// 沒有 BOM 的 UTF-16：ASCII 為主的文字，每兩個位元組有一個 0
static int GuessBOMlessUTF16(const unsigned char *p, size_t n) {
    if (n < 4 || (n & 1)) return 0;
    size_t sample = MIN(n, (size_t)8192) & ~(size_t)1;
    size_t evenZero = 0, oddZero = 0;
    for (size_t i = 0; i < sample; i += 2) {
        if (p[i] == 0) evenZero++;
        if (p[i + 1] == 0) oddZero++;
    }
    size_t pairs = sample / 2;
    if (oddZero * 10 > pairs * 4 && evenZero * 20 < pairs) return 1;   // LE
    if (evenZero * 10 > pairs * 4 && oddZero * 20 < pairs) return 2;   // BE
    return 0;
}

static NSData *DecodeWith(const void *bytes, size_t n, NSStringEncoding nsenc) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:n encoding:nsenc];
    if (!s) return nil;
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

NSData *N2DecodeToUTF8(NSData *raw, N2Encoding *ioEncoding, BOOL autodetect) {
    const unsigned char *p = (const unsigned char *)raw.bytes;
    size_t n = raw.length;

    if (!autodetect) {
        N2Encoding enc = *ioEncoding;
        size_t skip = 0;
        if ((enc == N2EncodingUTF8 || enc == N2EncodingUTF8BOM) && n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) skip = 3;
        if (enc == N2EncodingUTF16LE && n >= 2 && p[0] == 0xFF && p[1] == 0xFE) skip = 2;
        if (enc == N2EncodingUTF16BE && n >= 2 && p[0] == 0xFE && p[1] == 0xFF) skip = 2;
        if (enc == N2EncodingUTF8 || enc == N2EncodingUTF8BOM) {
            // UTF-8 原樣交給 Scintilla（不合法的位元組也保留）
            return [NSData dataWithBytes:p + skip length:n - skip];
        }
        if (enc == N2EncodingBig5) return DecodeBig5(p, n);
        size_t len = n - skip;
        if ((enc == N2EncodingUTF16LE || enc == N2EncodingUTF16BE) && (len & 1)) len--;
        return DecodeWith(p + skip, len, NSEnc(enc));
    }

    // 1. BOM
    if (n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
        *ioEncoding = N2EncodingUTF8BOM;
        return [NSData dataWithBytes:p + 3 length:n - 3];
    }
    if (n >= 2 && p[0] == 0xFF && p[1] == 0xFE) {
        NSData *d = DecodeWith(p + 2, (n - 2) & ~(size_t)1, NSUTF16LittleEndianStringEncoding);
        if (d) { *ioEncoding = N2EncodingUTF16LE; return d; }
    }
    if (n >= 2 && p[0] == 0xFE && p[1] == 0xFF) {
        NSData *d = DecodeWith(p + 2, (n - 2) & ~(size_t)1, NSUTF16BigEndianStringEncoding);
        if (d) { *ioEncoding = N2EncodingUTF16BE; return d; }
    }
    // 2. 沒有 BOM 的 UTF-16
    int u16 = GuessBOMlessUTF16(p, n);
    if (u16) {
        NSData *d = DecodeWith(p, n, u16 == 1 ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding);
        if (d) { *ioEncoding = (u16 == 1) ? N2EncodingUTF16LE : N2EncodingUTF16BE; return d; }
    }
    // 3. 合法 UTF-8（純 ASCII 也算）
    if (N2IsValidUTF8(p, n)) {
        *ioEncoding = N2EncodingUTF8;
        return raw;
    }
    // 4. 常見 ANSI 編碼，依序嘗試；Windows-1252 一定成功
    const N2Encoding fallbacks[] = { N2EncodingBig5, N2EncodingGB18030, N2EncodingShiftJIS, N2EncodingWindows1252 };
    for (N2Encoding enc : fallbacks) {
        NSData *d = (enc == N2EncodingBig5) ? DecodeBig5(p, n) : DecodeWith(p, n, NSEnc(enc));
        if (d) { *ioEncoding = enc; return d; }
    }
    *ioEncoding = N2EncodingUTF8;
    return raw;
}

NSData *N2EncodeFromUTF8(const char *utf8, size_t length, N2Encoding enc, NSError **error) {
    if (enc == N2EncodingUTF8) return [NSData dataWithBytes:utf8 length:length];
    if (enc == N2EncodingUTF8BOM) {
        NSMutableData *d = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
        [d appendBytes:utf8 length:length];
        return d;
    }
    NSData *body = nil;
    if (enc == N2EncodingBig5) {
        body = EncodeBig5((const unsigned char *)utf8, length);
    } else {
        NSString *s = [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding];
        body = s ? [s dataUsingEncoding:NSEnc(enc) allowLossyConversion:NO] : nil;
    }
    if (!body) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"文件中有字元無法用「%@」編碼儲存。", N2EncodingDisplayName(enc)];
            *error = [NSError errorWithDomain:@"Notepad2XS" code:1 userInfo:@{
                NSLocalizedDescriptionKey: msg,
                NSLocalizedRecoverySuggestionErrorKey: @"請從「檔案 → 編碼」改成 UTF-8 再儲存。"
            }];
        }
        return nil;
    }
    if (enc == N2EncodingUTF16LE) {
        NSMutableData *d = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
        [d appendData:body];
        return d;
    }
    if (enc == N2EncodingUTF16BE) {
        NSMutableData *d = [NSMutableData dataWithBytes:"\xFE\xFF" length:2];
        [d appendData:body];
        return d;
    }
    return body;
}

int N2DetectEOLMode(const char *s, size_t n, int defaultMode) {
    size_t crlf = 0, lf = 0, cr = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\r') {
            if (i + 1 < n && s[i + 1] == '\n') { crlf++; i++; }
            else cr++;
        } else if (s[i] == '\n') {
            lf++;
        }
    }
    if (crlf == 0 && lf == 0 && cr == 0) return defaultMode;
    if (crlf >= lf && crlf >= cr) return SC_EOL_CRLF;
    if (lf >= cr) return SC_EOL_LF;
    return SC_EOL_CR;
}
