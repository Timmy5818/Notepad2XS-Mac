// 加解密測試（正式參數：EXES 60,000 次、AES 600,000 次）
// 用法：test_crypto <XSExesKdfVectors.json> <輸出 AES 密文檔（給 CryptoKit 交叉驗證）>
#import <Foundation/Foundation.h>
#include "ExAlgorithms.h"
#include "AesAlgorithms.h"
#include "KeyFileCore.h"
#include "CryptoPrefix.h"
#include <chrono>

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fails++; printf("✗ %s\n", msg); } else printf("✓ %s\n", msg); } while (0)
template <class F> static bool Throws(F f) { try { f(); } catch (...) { return true; } return false; }
static std::string S(NSString *s) { NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding]; return std::string((const char *)d.bytes, d.length); }

int main(int argc, const char **argv) {
    @autoreleasepool {
        // EX_MD3 已知答案（原版 XSAlgorithmsTests）
        CHECK(xs::exmd3(u"abc") == "GFiReiA6ettMrAQtAEEr676aFhHredT8DrtdTLLQDTATAfMGMTMRdy7EeeGf7GFi6TFLLf443urDt6ejrFtMdG383Le3ddhEtbTGjRHm6MTeaDtmamAHyDGjerdGut8f7yrdMDDRdE7tDDiQGfmtna67FierAede46eryyAHQfLE3E87fu6mmjh7mH37nrGE3neGR76tHh64QReAL",
              "EX_MD3 已知答案（abc）");

        // EXES：原始 JS 產生的 60,000 次向量
        NSData *json = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        uint8_t random48[48];
        for (int i = 0; i < 48; i++) random48[i] = (uint8_t)[d[@"random48"][i] intValue];
        for (NSDictionary *v in d[@"vectors"]) {
            std::string pw = S(v[@"password"]), plain = S(v[@"plaintext"]), cipher = S(v[@"ciphertext"]);
            auto t0 = std::chrono::steady_clock::now();
            std::string enc = xs::exesEncrypt(plain, pw, random48);
            double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            char msg[200];
            snprintf(msg, sizeof msg, "EXES 向量 %s：加密結果與原始 JS 完全相同（%.2f 秒）", [v[@"name"] UTF8String], sec);
            CHECK(enc == cipher, msg);
            snprintf(msg, sizeof msg, "EXES 向量 %s：解密", [v[@"name"] UTF8String]);
            CHECK(xs::exesDecrypt(cipher, pw) == plain, msg);
        }
        std::string exesPw = S(d[@"vectors"][0][@"password"]);
        std::string exesCipher = S(d[@"vectors"][0][@"ciphertext"]);
        CHECK(Throws([&] { xs::exesDecrypt(exesCipher, exesPw + "x"); }), "EXES 錯誤密碼拒絕");
        std::string tampered = exesCipher; tampered[tampered.size() - 5] ^= 1;
        CHECK(Throws([&] { xs::exesDecrypt(tampered, exesPw); }), "EXES 竄改密文拒絕");
        const char uniBytes[] = "繁體中文\r\n😀\0尾端";
        std::string uni(uniBytes, sizeof uniBytes - 1);
        std::string e1 = xs::exesEncrypt(uni, "密碼"), e2 = xs::exesEncrypt(uni, "密碼");
        CHECK(e1 != e2 && xs::exesDecrypt(e1, "密碼") == uni, "EXES 隨機 Salt、Unicode／NUL 往返");
        CHECK(xs::exesDecrypt(xs::exesEncrypt("", "pw"), "pw").empty(), "EXES 空文件");

        // KEY FILE：原始位元組 → Base64 → EX_MD3
        std::string keyBytes(150, '\0');
        for (int i = 0; i < 150; i++) keyBytes[i] = (char)(i * 7);
        xs::KeyFileInput kf(keyBytes.size());
        kf.append((const unsigned char *)keyBytes.data(), keyBytes.size());
        kf.complete();
        NSData *kd = [NSData dataWithBytes:keyBytes.data() length:keyBytes.size()];
        NSString *b64 = [kd base64EncodedStringWithOptions:0];
        std::u16string b64u(b64.length, 0);
        [b64 getCharacters:(unichar *)b64u.data() range:NSMakeRange(0, b64.length)];
        CHECK(kf.password() == xs::exmd3(b64u) && kf.password().size() == 209, "KEY FILE 衍生（Base64 → EX_MD3，209 字元）");
        CHECK(Throws([] { xs::KeyFileInput x(99); }) && Throws([] { xs::KeyFileInput x(104857601ULL); }), "KEY FILE 大小界線");

        // AES 正式參數
        auto t0 = std::chrono::steady_clock::now();
        std::string aes = xs::aesEncrypt(uni, "密碼🔑");
        double aesSec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        char amsg[120];
        snprintf(amsg, sizeof amsg, "AES 正式加解密往返（PBKDF2 600,000 次，%.2f 秒）", aesSec);
        CHECK(xs::aesDecrypt(aes, "密碼🔑") == uni, amsg);
        CHECK(aes.rfind("nb2XSAeSGcMveR1", 0) == 0 && xs::aesEncrypt(uni, "密碼🔑") != aes, "AES 標記與隨機 Salt／Nonce");
        CHECK(Throws([&] { xs::aesDecrypt(aes, "wrong"); }), "AES 錯誤密碼拒絕");
        std::string at = aes; at[at.size() - 6] = at[at.size() - 6] == 'A' ? 'B' : 'A';
        CHECK(Throws([&] { xs::aesDecrypt(at, "密碼🔑"); }), "AES 竄改拒絕");
        std::string big(100000, 'x');
        for (size_t i = 0; i < big.size(); i++) big[i] = (char)('a' + i % 26);
        std::string bigCipher = xs::aesEncrypt(big, "pw");
        CHECK(xs::aesDecrypt(bigCipher, "pw") == big, "AES 多區塊（100,000 位元組）往返");

        // 前綴判斷
        CHECK(xs::cryptoPrefix("X60abc", 6) == xs::AutoDecryptKind::Exes &&
              xs::cryptoPrefix("nb2XSAeSGcMveR1xx", 17) == xs::AutoDecryptKind::Aes &&
              xs::cryptoPrefix(" X60", 4) == xs::AutoDecryptKind::None &&
              xs::cryptoPrefix("x60", 3) == xs::AutoDecryptKind::None, "自動解密前綴判斷（區分大小寫、前置空白不算）");

        // 輸出給 CryptoKit 交叉驗證：密文、密碼、明文
        if (argc > 2) {
            NSDictionary *out = @{@"cipher": [NSString stringWithUTF8String:bigCipher.c_str()], @"password": @"pw",
                                  @"plain": [NSString stringWithUTF8String:big.c_str()],
                                  @"cipherUni": [NSString stringWithUTF8String:aes.c_str()], @"passwordUni": @"密碼🔑",
                                  @"plainUni": [[NSString alloc] initWithBytes:uni.data() length:uni.size() encoding:NSUTF8StringEncoding]};
            [[NSJSONSerialization dataWithJSONObject:out options:0 error:nil] writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
        }
        printf("\n%s（失敗 %d 項）\n", fails ? "有測試失敗" : "全部通過", fails);
    }
    return fails ? 1 : 0;
}
