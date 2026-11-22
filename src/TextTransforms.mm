#import "TextTransforms.h"
#include <random>
#include <unordered_map>

namespace n2 {

static const char kHexUpper[] = "0123456789ABCDEF";

static int HexVal(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static void PushHex(std::string &out, unsigned char c) {
    out += kHexUpper[c >> 4];
    out += kHexUpper[c & 0xF];
}

// 略過 0x20 以下的字元（空白、Tab、換行），取出有效字元
static std::string Literal(const std::string &s) {
    std::string r;
    r.reserve(s.size());
    for (unsigned char c : s) if (c >= 0x21) r += (char)c;
    return r;
}

// ---- Base64 ----
static const char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string Base64Encode(const std::string &in) {
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 3 <= in.size(); i += 3) {
        unsigned v = (unsigned char)in[i] << 16 | (unsigned char)in[i + 1] << 8 | (unsigned char)in[i + 2];
        out += kB64[v >> 18 & 63]; out += kB64[v >> 12 & 63]; out += kB64[v >> 6 & 63]; out += kB64[v & 63];
    }
    size_t rest = in.size() - i;
    if (rest == 1) {
        unsigned v = (unsigned char)in[i] << 16;
        out += kB64[v >> 18 & 63]; out += kB64[v >> 12 & 63]; out += "==";
    } else if (rest == 2) {
        unsigned v = (unsigned char)in[i] << 16 | (unsigned char)in[i + 1] << 8;
        out += kB64[v >> 18 & 63]; out += kB64[v >> 12 & 63]; out += kB64[v >> 6 & 63]; out += '=';
    }
    return out;
}

bool Base64Decode(const std::string &text, std::string &out) {
    int table[256];
    for (int &t : table) t = -1;
    for (int k = 0; k < 64; k++) table[(unsigned char)kB64[k]] = k;
    std::string s = Literal(text);
    if (s.size() % 4) return false;
    out.clear();
    for (size_t i = 0; i < s.size(); i += 4) {
        int pad = 0, v[4];
        for (int k = 0; k < 4; k++) {
            unsigned char c = s[i + k];
            if (c == '=') {
                // '=' 只能出現在最後一組的最後一或兩個位置
                if (i + 4 != s.size() || k < 2) return false;
                pad++; v[k] = 0;
            } else {
                if (pad) return false;
                v[k] = table[c];
                if (v[k] < 0) return false;
            }
        }
        out += (char)(v[0] << 2 | v[1] >> 4);
        if (pad < 2) out += (char)((v[1] & 15) << 4 | v[2] >> 2);
        if (pad < 1) out += (char)((v[2] & 3) << 6 | v[3]);
    }
    return true;
}

// ---- URL ----
static bool URLSafe(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
           c == '-' || c == '_' || c == '.' || c == '~';
}

std::string URLEncode(const std::string &in) {
    std::string out;
    out.reserve(in.size() * 3);
    for (unsigned char c : in) {
        if (URLSafe(c)) out += (char)c;
        else { out += '%'; PushHex(out, c); }
    }
    return out;
}

std::string URLDecode(const std::string &in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); i++) {
        if (in[i] == '%' && i + 2 < in.size()) {
            int a = HexVal(in[i + 1]), b = HexVal(in[i + 2]);
            if (a >= 0 && b >= 0) { out += (char)(a << 4 | b); i += 2; continue; }
        }
        out += in[i];
    }
    return out;
}

// ---- Hex ----
std::string HexEncode(const std::string &in) {
    std::string out;
    out.reserve(in.size() * 2);
    for (unsigned char c : in) PushHex(out, c);
    return out;
}

bool HexDecode(const std::string &text, std::string &out) {
    std::string s = Literal(text);
    if (s.size() % 2) return false;
    out.clear();
    for (size_t i = 0; i < s.size(); i += 2) {
        int a = HexVal(s[i]), b = HexVal(s[i + 1]);
        if (a < 0 || b < 0) return false;
        out += (char)(a << 4 | b);
    }
    return true;
}

std::string HexEncodeUTF16(const std::u16string &units, bool bigEndianDigits) {
    std::string out;
    out.reserve(units.size() * 4);
    for (char16_t u : units) {
        unsigned char hi = u >> 8, lo = u & 0xFF;
        if (bigEndianDigits) { PushHex(out, hi); PushHex(out, lo); }
        else { PushHex(out, lo); PushHex(out, hi); }
    }
    return out;
}

bool HexDecodeUTF16(const std::string &text, bool bigEndianDigits, std::u16string &out) {
    std::string bytes;
    if (!HexDecode(text, bytes) || bytes.size() % 2) return false;
    out.clear();
    for (size_t i = 0; i < bytes.size(); i += 2) {
        unsigned char a = bytes[i], b = bytes[i + 1];
        out += bigEndianDigits ? (char16_t)(a << 8 | b) : (char16_t)(b << 8 | a);
    }
    return true;
}

// ---- Quoted-Printable ----
std::string QPEncode(const std::string &in) {
    std::string out;
    int linePos = 0;
    auto need = [&](int chars) {
        if (linePos + chars >= 76) { out += "=\r\n"; linePos = 0; }
        linePos += chars;
    };
    for (size_t i = 0; i < in.size(); i++) {
        unsigned char c = in[i];
        bool tail = (i + 1 < in.size());
        bool plain = (c >= 33 && c <= 60) || (c >= 62 && c <= 126) || ((c == ' ' || c == '\t') && tail);
        if (plain) { need(1); out += (char)c; }
        else { need(3); out += '='; PushHex(out, c); }
    }
    return out;
}

std::string QPDecode(const std::string &in) {
    // 與 Windows 版 QP_Decode 相同：'=' 後至少要有 2 個字元才處理
    auto lineEnd = [](char c) { return c == '\r' || c == '\n'; };
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); i++) {
        char c = in[i];
        if (c == '=' && in.size() - i >= 3) {
            char a = in[i + 1], b = in[i + 2];
            if (lineEnd(a)) {                         // 軟換行
                i += lineEnd(b) ? 2 : 1;
                continue;
            }
            int x = HexVal(a), y = HexVal(b);
            if (x >= 0 && y >= 0) out += (char)(x << 4 | y);
            else { out += c; out += a; out += b; }
            i += 2;
            continue;
        }
        out += c;
    }
    return out;
}

}  // namespace n2

// ---- 字串層級 ----

static NSString *ReplaceAll(NSString *s, NSArray<NSArray<NSString *> *> *pairs) {
    for (NSArray *p in pairs) s = [s stringByReplacingOccurrencesOfString:p[0] withString:p[1]];
    return s;
}

NSString *N2EscapeCChars(NSString *s) {
    return ReplaceAll(s, @[@[@"\\", @"\\\\"], @[@"\"", @"\\\""], @[@"'", @"\\'"]]);
}

NSString *N2UnescapeCChars(NSString *s) {
    return ReplaceAll(s, @[@[@"\\\\", @"\\"], @[@"\\\"", @"\""], @[@"\\'", @"'"]]);
}

NSString *N2EscapeHTML(NSString *s) {
    return ReplaceAll(s, @[@[@"&", @"&amp;"], @[@"<", @"&lt;"], @[@">", @"&gt;"]]);
}

NSString *N2StripHTMLTags(NSString *s) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<[^<>]*>" options:0 error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
}

NSString *N2InvertCase(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        NSString *up = ch.uppercaseString, *lo = ch.lowercaseString;
        if ([ch isEqualToString:up] && ![ch isEqualToString:lo]) [out appendString:lo];
        else if ([ch isEqualToString:lo] && ![ch isEqualToString:up]) [out appendString:up];
        else [out appendString:ch];
    }];
    return out;
}

static BOOL IsWordChar(unichar c) {
    return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c] || c == '\'' || c == 0x2019;
}

NSString *N2TitleCase(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    __block BOOL inWord = NO;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        BOOL word = IsWordChar([ch characterAtIndex:0]);
        [out appendString:word ? (inWord ? ch.lowercaseString : ch.uppercaseString) : ch];
        inWord = word;
    }];
    return out;
}

NSString *N2SentenceCase(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    __block BOOL capNext = YES;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        unichar c = [ch characterAtIndex:0];
        if ([NSCharacterSet.letterCharacterSet characterIsMember:c]) {
            [out appendString:capNext ? ch.uppercaseString : ch.lowercaseString];
            capNext = NO;
        } else {
            [out appendString:ch];
            // 句號、驚嘆號、問號（含全形）之後的第一個字母大寫
            if (c == '.' || c == '!' || c == '?' || c == 0x3002 || c == 0xFF01 || c == 0xFF1F) capNext = YES;
        }
    }];
    return out;
}

NSString *N2CharToCHex(NSString *s) {
    if (s.length == 0) return nil;
    NSRange first = [s rangeOfComposedCharacterSequenceAtIndex:0];
    if (first.length != s.length || s.length > 2) return nil;
    UTF32Char cp = [s characterAtIndex:0];
    if (s.length == 2) {
        unichar hi = [s characterAtIndex:0], lo = [s characterAtIndex:1];
        if (!CFStringIsSurrogateHighCharacter(hi)) return nil;
        cp = CFStringGetLongCharacterForSurrogatePair(hi, lo);
    }
    if (cp <= 0xFF) return [NSString stringWithFormat:@"\\x%02X", cp];
    if (cp <= 0xFFFF) return [NSString stringWithFormat:@"\\u%04X", cp];
    return [NSString stringWithFormat:@"\\U%08X", cp];
}

NSString *N2CHexToChar(NSString *s) {
    NSString *t = s;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n-"]].location != NSNotFound) return nil;
    NSString *lower = t.lowercaseString;
    for (NSString *prefix in @[@"\\x", @"\\u", @"0x", @"x", @"u"]) {
        if ([lower hasPrefix:prefix]) { t = [t substringFromIndex:prefix.length]; break; }
    }
    if (t.length == 0 || t.length > 8) return nil;
    unsigned long long v = 0;
    NSScanner *sc = [NSScanner scannerWithString:t];
    if (![sc scanHexLongLong:&v] || !sc.isAtEnd) return nil;
    if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) return nil;
    UTF32Char cp = (UTF32Char)v;
    return [[NSString alloc] initWithBytes:&cp length:4 encoding:NSUTF32LittleEndianStringEncoding];
}

// ---- 行處理 ----

NSArray<NSString *> *N2SplitLines(NSString *text) {
    NSMutableArray *lines = [NSMutableArray array];
    NSUInteger len = text.length, start = 0;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\r' || c == '\n') {
            [lines addObject:[text substringWithRange:NSMakeRange(start, i - start)]];
            if (c == '\r' && i + 1 < len && [text characterAtIndex:i + 1] == '\n') i++;
            start = i + 1;
        }
    }
    [lines addObject:[text substringFromIndex:start]];
    return lines;
}

NSArray<NSString *> *N2SortLines(NSArray<NSString *> *lines, N2SortOptions opt) {
    NSString *(^key)(NSString *) = ^NSString *(NSString *l) {
        return opt.caseInsensitive ? l.lowercaseString : l;
    };

    // 計算每行（依比較鍵）出現次數
    NSCountedSet *counts = [NSCountedSet new];
    for (NSString *l in lines) [counts addObject:key(l)];

    NSMutableArray<NSString *> *work = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *l in lines) {
        NSString *k = key(l);
        NSUInteger n = [counts countForObject:k];
        if (opt.removeDuplicates && n > 1) continue;
        if (opt.removeUnique && n == 1) continue;
        if (opt.mergeDuplicates) {
            if ([seen containsObject:k]) continue;
            [seen addObject:k];
        }
        [work addObject:l];
    }

    NSComparator cmp = ^NSComparisonResult(NSString *a, NSString *b) {
        NSComparisonResult r;
        // 不分大小寫時，只差大小寫的兩行視為相同（維持原順序），與 Windows StrCmpLogicalW 一致
        NSStringCompareOptions o = 0;
        if (opt.logical) o |= NSNumericSearch;
        if (opt.caseInsensitive) o |= NSCaseInsensitiveSearch;
        r = [a compare:b options:o range:NSMakeRange(0, a.length) locale:NSLocale.currentLocale];
        return r;
    };

    switch (opt.order) {
        case N2SortAscending:
            return [work sortedArrayWithOptions:NSSortStable usingComparator:cmp];
        case N2SortDescending:
            return [work sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) { return cmp(b, a); }];
        case N2SortShuffle: {
            std::random_device rd;
            std::mt19937 gen(rd());
            for (NSUInteger i = work.count; i > 1; i--) {
                std::uniform_int_distribution<NSUInteger> d(0, i - 1);
                [work exchangeObjectAtIndex:i - 1 withObjectAtIndex:d(gen)];
            }
            return work;
        }
        case N2SortReverse:
            return work.reverseObjectEnumerator.allObjects;
        case N2SortKeepOrder:
        default:
            return work;
    }
}

static NSArray *Map(NSArray<NSString *> *lines, NSString *(^f)(NSString *)) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *l in lines) [out addObject:f(l)];
    return out;
}

static NSCharacterSet *HSpace(void) { return [NSCharacterSet characterSetWithCharactersInString:@" \t　"]; }

NSArray<NSString *> *N2TrimTrailingWhitespace(NSArray<NSString *> *lines) {
    return Map(lines, ^NSString *(NSString *l) {
        NSUInteger end = l.length;
        while (end > 0 && [HSpace() characterIsMember:[l characterAtIndex:end - 1]]) end--;
        return [l substringToIndex:end];
    });
}

NSArray<NSString *> *N2CompressWhitespace(NSArray<NSString *> *lines) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[ \\t]+" options:0 error:nil];
    return Map(lines, ^NSString *(NSString *l) {
        NSString *r = [re stringByReplacingMatchesInString:l options:0 range:NSMakeRange(0, l.length) withTemplate:@" "];
        return [r stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" "]];
    });
}

static BOOL IsBlank(NSString *l) {
    return [l stringByTrimmingCharactersInSet:HSpace()].length == 0;
}

NSArray<NSString *> *N2RemoveBlankLines(NSArray<NSString *> *lines, BOOL mergeOnly) {
    NSMutableArray *out = [NSMutableArray array];
    BOOL prevBlank = NO;
    for (NSString *l in lines) {
        BOOL blank = IsBlank(l);
        if (blank && (!mergeOnly || prevBlank)) { prevBlank = YES; continue; }
        [out addObject:l];
        prevBlank = blank;
    }
    return out;
}

NSArray<NSString *> *N2StripFirstChar(NSArray<NSString *> *lines) {
    return Map(lines, ^NSString *(NSString *l) {
        if (!l.length) return l;
        return [l substringFromIndex:NSMaxRange([l rangeOfComposedCharacterSequenceAtIndex:0])];
    });
}

NSArray<NSString *> *N2StripLastChar(NSArray<NSString *> *lines) {
    return Map(lines, ^NSString *(NSString *l) {
        if (!l.length) return l;
        return [l substringToIndex:[l rangeOfComposedCharacterSequenceAtIndex:l.length - 1].location];
    });
}

// 顯示寬度：東亞全形字算 2
static NSInteger DisplayWidth(NSString *s) {
    __block NSInteger w = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        UTF32Char c = [ch characterAtIndex:0];
        if (ch.length >= 2 && CFStringIsSurrogateHighCharacter([ch characterAtIndex:0]))
            c = CFStringGetLongCharacterForSurrogatePair([ch characterAtIndex:0], [ch characterAtIndex:1]);
        BOOL wide = (c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
                    (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60) ||
                    (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x1F300 && c <= 0x1FAFF) || (c >= 0x20000 && c <= 0x3FFFD);
        w += wide ? 2 : 1;
    }];
    return w;
}

NSArray<NSString *> *N2PadWithSpaces(NSArray<NSString *> *lines) {
    NSInteger maxW = 0;
    for (NSString *l in lines) maxW = MAX(maxW, DisplayWidth(l));
    return Map(lines, ^NSString *(NSString *l) {
        NSInteger pad = maxW - DisplayWidth(l);
        return pad > 0 ? [l stringByPaddingToLength:l.length + pad withString:@" " startingAtIndex:0] : l;
    });
}

NSArray<NSString *> *N2TabsToSpaces(NSArray<NSString *> *lines, NSInteger tabWidth, BOOL indentOnly) {
    if (tabWidth < 1) tabWidth = 4;
    return Map(lines, ^NSString *(NSString *l) {
        NSMutableString *out = [NSMutableString string];
        NSInteger col = 0;
        BOOL inIndent = YES;
        for (NSUInteger i = 0; i < l.length; i++) {
            unichar c = [l characterAtIndex:i];
            if (c != ' ' && c != '\t') inIndent = NO;
            if (c == '\t' && (!indentOnly || inIndent)) {
                NSInteger n = tabWidth - col % tabWidth;
                for (NSInteger k = 0; k < n; k++) [out appendString:@" "];
                col += n;
            } else {
                [out appendFormat:@"%C", c];
                col = (c == '\t') ? col + tabWidth - col % tabWidth : col + 1;
            }
        }
        return out;
    });
}

NSArray<NSString *> *N2SpacesToTabs(NSArray<NSString *> *lines, NSInteger tabWidth, BOOL indentOnly) {
    if (tabWidth < 1) tabWidth = 4;
    return Map(lines, ^NSString *(NSString *l) {
        NSMutableString *out = [NSMutableString string];
        NSInteger col = 0, spaces = 0;
        BOOL inIndent = YES;
        for (NSUInteger i = 0; i <= l.length; i++) {
            unichar c = i < l.length ? [l characterAtIndex:i] : 0;
            if (c == ' ' && (!indentOnly || inIndent)) {
                spaces++; col++;
                if (col % tabWidth == 0) {
                    [out appendString:spaces > 1 ? @"\t" : @" "];
                    spaces = 0;
                }
                continue;
            }
            for (NSInteger k = 0; k < spaces; k++) [out appendString:@" "];
            spaces = 0;
            if (i == l.length) break;
            if (c != ' ' && c != '\t') inIndent = NO;
            [out appendFormat:@"%C", c];
            col = (c == '\t') ? col + tabWidth - col % tabWidth : col + 1;
        }
        return out;
    });
}

NSArray<NSString *> *N2ModifyLines(NSArray<NSString *> *lines, NSString *prefix, NSString *suffix, NSInteger firstLineNumber) {
    NSUInteger n = lines.count;
    NSInteger lastLine = firstLineNumber + (NSInteger)n - 1;
    int wL = (int)[NSString stringWithFormat:@"%ld", (long)MAX(lastLine, 1)].length;
    int wN = (int)[NSString stringWithFormat:@"%lu", (unsigned long)MAX(n, (NSUInteger)1)].length;
    int wI = (int)[NSString stringWithFormat:@"%lu", (unsigned long)(n ? n - 1 : 0)].length;
    NSString *(^expand)(NSString *, NSUInteger) = ^NSString *(NSString *t, NSUInteger idx) {
        if (t.length == 0 || [t rangeOfString:@"$("].location == NSNotFound) return t;
        NSInteger L = firstLineNumber + (NSInteger)idx, N = (NSInteger)idx + 1, I = (NSInteger)idx;
        NSString *r = t;
        r = [r stringByReplacingOccurrencesOfString:@"$(0L)" withString:[NSString stringWithFormat:@"%0*ld", wL, (long)L]];
        r = [r stringByReplacingOccurrencesOfString:@"$(L)" withString:[NSString stringWithFormat:@"%ld", (long)L]];
        r = [r stringByReplacingOccurrencesOfString:@"$(0N)" withString:[NSString stringWithFormat:@"%0*ld", wN, (long)N]];
        r = [r stringByReplacingOccurrencesOfString:@"$(N)" withString:[NSString stringWithFormat:@"%ld", (long)N]];
        r = [r stringByReplacingOccurrencesOfString:@"$(0I)" withString:[NSString stringWithFormat:@"%0*ld", wI, (long)I]];
        r = [r stringByReplacingOccurrencesOfString:@"$(I)" withString:[NSString stringWithFormat:@"%ld", (long)I]];
        return r;
    };
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    [lines enumerateObjectsUsingBlock:^(NSString *l, NSUInteger idx, BOOL *stop) {
        [out addObject:[NSString stringWithFormat:@"%@%@%@", expand(prefix ?: @"", idx), l, expand(suffix ?: @"", idx)]];
    }];
    return out;
}

static NSString *JoinGroup(NSArray<NSString *> *group, BOOL noSpace) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *l in group) {
        NSString *t = s.length ? [l stringByTrimmingCharactersInSet:HSpace()] : l;
        if (s.length && t.length) {
            // 去掉前一段尾端空白再接
            while (s.length && [HSpace() characterIsMember:[s characterAtIndex:s.length - 1]])
                [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
            if (!noSpace) [s appendString:@" "];
        }
        [s appendString:t];
    }
    return s;
}

NSArray<NSString *> *N2JoinLines(NSArray<NSString *> *lines, BOOL noSpace) {
    return @[JoinGroup(lines, noSpace)];
}

NSArray<NSString *> *N2JoinParagraphs(NSArray<NSString *> *lines, BOOL noSpace) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *group = [NSMutableArray array];
    for (NSString *l in lines) {
        if (IsBlank(l)) {
            if (group.count) { [out addObject:JoinGroup(group, noSpace)]; [group removeAllObjects]; }
            [out addObject:l];
        } else {
            [group addObject:l];
        }
    }
    if (group.count) [out addObject:JoinGroup(group, noSpace)];
    return out;
}

NSArray<NSString *> *N2WrapToColumn(NSArray<NSString *> *lines, NSInteger column) {
    if (column < 1) return lines;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in lines) {
        if (DisplayWidth(line) <= column) { [out addObject:line]; continue; }
        NSMutableString *cur = [NSMutableString string];
        __block NSInteger curW = 0;
        __block NSUInteger lastBreak = NSNotFound;   // cur 中最後一個空白的位置
        [line enumerateSubstringsInRange:NSMakeRange(0, line.length) options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
            NSInteger w = DisplayWidth(ch);
            if ([ch isEqualToString:@" "] && curW + w > column) {   // 剛好在空格處超出：直接斷行
                [out addObject:[cur copy]];
                [cur setString:@""];
                curW = 0;
                lastBreak = NSNotFound;
                return;
            }
            if (curW + w > column && cur.length) {
                if (lastBreak != NSNotFound && lastBreak > 0) {
                    [out addObject:[cur substringToIndex:lastBreak]];
                    NSString *rest = [cur substringFromIndex:lastBreak + 1];
                    [cur setString:rest];
                    curW = DisplayWidth(cur);
                } else {
                    [out addObject:[cur copy]];
                    [cur setString:@""];
                    curW = 0;
                }
                lastBreak = NSNotFound;
                if ([ch isEqualToString:@" "] && cur.length == 0) return;   // 行首不留空白
            }
            if ([ch isEqualToString:@" "]) lastBreak = cur.length;
            // 全形字之後可以斷行
            else if (w == 2) lastBreak = NSNotFound;
            [cur appendString:ch];
            curW += w;
        }];
        if (cur.length) [out addObject:cur];
    }
    return out;
}

NSArray<NSString *> *N2ToggleLineComment(NSArray<NSString *> *lines, NSString *token) {
    // 所有非空白行都已註解 → 移除；否則在最小縮排處加上
    BOOL allCommented = YES;
    NSUInteger minIndent = NSUIntegerMax;
    for (NSString *l in lines) {
        if (IsBlank(l)) continue;
        NSUInteger i = 0;
        while (i < l.length && [HSpace() characterIsMember:[l characterAtIndex:i]]) i++;
        minIndent = MIN(minIndent, i);
        if (![[l substringFromIndex:i] hasPrefix:token]) allCommented = NO;
    }
    if (minIndent == NSUIntegerMax) return lines;   // 全是空白行
    return Map(lines, ^NSString *(NSString *l) {
        if (IsBlank(l)) return l;
        if (allCommented) {
            NSRange r = [l rangeOfString:token];
            NSUInteger end = NSMaxRange(r);
            if (end < l.length && [l characterAtIndex:end] == ' ') end++;
            return [l stringByReplacingCharactersInRange:NSMakeRange(r.location, end - r.location) withString:@""];
        }
        return [NSString stringWithFormat:@"%@%@ %@", [l substringToIndex:minIndent], token, [l substringFromIndex:minIndent]];
    });
}
