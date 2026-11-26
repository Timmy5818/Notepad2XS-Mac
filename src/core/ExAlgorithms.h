#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <functional>
namespace xs {
std::string exmd3(const std::u16string &text);
// Callback may throw to cancel; output is identical to exmd3(text).
std::string exmd3WithProgress(const std::u16string& text, const std::function<void(unsigned)>& progress);
// Strict UTF-8 input/password. Every credential source is stretched with
// ex_md3n("notepad2xs_exes_" + lowercaseHex(salt24) + password, 60000)
// before the EXES key derivation, in both directions. X60 envelope unchanged;
// no unstretched/legacy decryption fallback. fixedRandom48 is test-only.
std::string exesEncrypt(const std::string &text, const std::string &password,
                        const uint8_t *fixedRandom48 = nullptr);
std::string exesDecrypt(const std::string &cipher, const std::string &password);
} // namespace xs

namespace xs {
bool validX60Envelope(std::string_view cipher) noexcept;
}
