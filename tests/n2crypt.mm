// 測試用命令列工具：n2crypt enc|dec exes|aes <檔案> <密碼>（結果輸出到 stdout）
#include "ExAlgorithms.h"
#include "AesAlgorithms.h"
#include "KeyFileCore.h"
#include <fstream>
#include <iostream>
#include <sstream>
int main(int argc, char **argv) {
    if (argc != 5) { std::cerr << "usage: n2crypt enc|dec exes|aes file password\n"; return 2; }
    std::ifstream f(argv[3], std::ios::binary);
    std::stringstream ss; ss << f.rdbuf();
    std::string in = ss.str(), mode = argv[1], alg = argv[2], pw = argv[4];
    if (pw.rfind("keyfile:", 0) == 0) {   // 金鑰檔案：原始位元組 → Base64 → EX_MD3
        std::ifstream k(pw.substr(8), std::ios::binary);
        std::stringstream ks; ks << k.rdbuf();
        std::string kb = ks.str();
        xs::KeyFileInput input(kb.size());
        input.append((const unsigned char *)kb.data(), kb.size());
        input.complete();
        pw = input.password();
    }
    try {
        std::string out = mode == "enc" ? (alg == "exes" ? xs::exesEncrypt(in, pw) : xs::aesEncrypt(in, pw))
                                        : (alg == "exes" ? xs::exesDecrypt(in, pw) : xs::aesDecrypt(in, pw));
        std::cout << out;
    } catch (const std::exception &e) { std::cerr << "FAILED: " << e.what() << "\n"; return 1; }
    return 0;
}
