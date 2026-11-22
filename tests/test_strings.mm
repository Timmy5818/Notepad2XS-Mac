// N2Common.h 的字串轉換：中間有 NUL 不截斷、落單代理字元不當掉
#import <Foundation/Foundation.h>
#import "N2Common.h"
static int fails = 0, passes = 0;
static void Check(bool ok, const char *name) { ok ? passes++ : fails++; printf("  %s %s\n", ok ? "✓" : "✗", name); }
int main() {
    @autoreleasepool {
        std::string withNul("a\0b中", 6);
        NSString *s = N2FromUTF8(withNul);
        Check(s.length == 4, "N2FromUTF8 保留中間的 NUL");
        Check(N2ToUTF8(s) == withNul, "N2ToUTF8 來回轉換相同");
        unichar lone = 0xD800;
        NSString *bad = [NSString stringWithCharacters:&lone length:1];
        Check(bad.UTF8String == NULL, "落單代理字元的 UTF8String 是 NULL（舊寫法會當掉的原因）");
        Check([bad dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO] == nil, "改用 dataUsingEncoding 可偵測（回傳 nil）");
        Check(N2FromWide(N2ToWide(@"表格😀")) .length == 4, "寬字元來回轉換（含 emoji）");
        Check([N2FromU16(N2ToU16(@"中文")) isEqualToString:@"中文"], "UTF-16 來回轉換");
        printf(fails ? "失敗 %d 項\n" : "全部通過（%d 項）\n", fails ? fails : passes);
        return fails ? 1 : 0;
    }
}
