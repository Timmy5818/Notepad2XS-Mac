#import "N2Common.h"
#import <Security/Security.h>

NSString *N2LogsDirectory(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"Notepad2XS/logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSDictionary *KeychainBase(NSString *service, NSString *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account};
}

NSData *N2KeychainRead(NSString *service, NSString *account) {
    NSMutableDictionary *q = [KeychainBase(service, account) mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) != errSecSuccess || !data) return nil;
    return (__bridge_transfer NSData *)data;
}

OSStatus N2KeychainWrite(NSString *service, NSString *account, NSData *data) {
    NSDictionary *base = KeychainBase(service, account);
    if (!data) {
        OSStatus st = SecItemDelete((__bridge CFDictionaryRef)base);
        return st == errSecItemNotFound ? errSecSuccess : st;
    }
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)base, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (st != errSecItemNotFound) return st;
    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}
