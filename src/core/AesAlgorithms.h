#pragma once
#include <cstdint>
#include <string>
namespace xs {
// Notepad2XS AES-GCM v1 password format. New ciphertexts are always
// AES-256-GCM with PBKDF2-HMAC-SHA256, a 16-byte salt, 12-byte nonce and
// 16-byte authentication tag. Deterministic nonce injection exists only in
// XS_AES_TESTING builds and is absent from production declarations.
#ifdef XS_AES_TESTING
std::string aesEncrypt(const std::string &utf8, const std::string &password,
                       const uint8_t *fixedSalt16 = nullptr,
                       const uint8_t *fixedNonce12 = nullptr);
#else
std::string aesEncrypt(const std::string &utf8, const std::string &password);
#endif
std::string aesDecrypt(const std::string &cipher, const std::string &password);
} // namespace xs
