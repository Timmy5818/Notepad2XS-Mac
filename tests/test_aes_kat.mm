// AES 已知答案（原版 XSAesTests：測試建置 1,000 次迭代、固定 Salt／Nonce）
#include "AesAlgorithms.h"
#include <cstdio>
#include <string>
int main() {
    uint8_t salt[16], nonce[12];
    for (int i = 0; i < 16; i++) salt[i] = (uint8_t)i;
    for (int i = 0; i < 12; i++) nonce[i] = (uint8_t)(0xa0 + i);
    const std::string kat = "nb2XSAeSGcMveR1TjJHMQEBEBAMAOgDAAAAAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqsKyjZ25/OLoryOe+jp9XETHlK0aw==";
    std::string enc = xs::aesEncrypt("TEST", "password", salt, nonce);
    bool ok1 = enc == kat, ok2 = xs::aesDecrypt(kat, "password") == "TEST";
    printf("%s AES-GCM 已知答案向量（與 Windows 版位元組相同）\n", ok1 ? "✓" : "✗");
    printf("%s AES 已知答案解密\n", ok2 ? "✓" : "✗");
    if (!ok1) printf("  實際：%s\n", enc.c_str());
    return ok1 && ok2 ? 0 : 1;
}
