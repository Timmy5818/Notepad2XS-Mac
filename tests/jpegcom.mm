// 測試工具：讀出 JPEG 的 Notepad2XS COM（模式與內容）
#include "JpegCommentFormat.h"
#include <fstream>
#include <iostream>
#include <iterator>
int main(int argc, char **argv) {
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<uint8_t> v((std::istreambuf_iterator<char>(f)), {});
    xs::jpeg::Payload p; std::string err;
    if (!xs::jpeg::extract(v, p, err)) { std::cout << "ERROR " << err << "\n"; return 1; }
    const char *modes[] = {"Text", "Aes", "Exes"};
    std::cout << (p.found ? "found" : "none") << " mode=" << modes[(int)p.mode] << " bytes=" << p.bytes.size() << "\n" << p.bytes.substr(0, 60) << "\n";
}
