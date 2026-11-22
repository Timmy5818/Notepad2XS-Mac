// 各視窗共用的小工具：字串轉換（保留中間的 NUL）、記錄資料夾、鑰匙圈讀寫
// 只給 Objective-C++（.mm）使用
#pragma once
#import <Foundation/Foundation.h>
#include <string>
#include <string_view>

// wchar_t 在 macOS 是 32 位元（UTF-32）
inline std::wstring N2ToWide(NSString *s) {
    NSData *d = [s ?: @"" dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    return std::wstring((const wchar_t *)d.bytes, d.length / sizeof(wchar_t));
}
inline NSString *N2FromWide(std::wstring_view w) {
    return [[NSString alloc] initWithBytes:w.data() length:w.size() * sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}
inline std::u16string N2ToU16(NSString *s) {
    std::u16string u(s.length, 0);
    [s getCharacters:(unichar *)u.data() range:NSMakeRange(0, s.length)];
    return u;
}
inline NSString *N2FromU16(const std::u16string &s) { return [NSString stringWithCharacters:(const unichar *)s.data() length:s.size()]; }
// 以長度轉換，不會在第一個 NUL 截斷；無效的 UTF-8 回傳空字串
inline NSString *N2FromUTF8(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
inline std::string N2ToUTF8(NSString *s) {
    NSData *d = [s ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    return std::string((const char *)d.bytes, d.length);
}

NSString *N2LogsDirectory(void);   // ~/Library/Application Support/Notepad2XS/logs（不存在就建立）

// 鑰匙圈（一般密碼項目，僅限本機、解鎖時可讀）
NSData *N2KeychainRead(NSString *service, NSString *account);
// data 為 nil 時刪除；成功回傳 errSecSuccess
OSStatus N2KeychainWrite(NSString *service, NSString *account, NSData *data);
