#pragma once
#include <cstddef>
#include <cstring>
namespace xs {
enum class AutoDecryptKind { None, Exes, Aes };
inline AutoDecryptKind cryptoPrefix(const char *text, std::size_t length) {
  if (!text)
    return AutoDecryptKind::None;
  if (length >= 3 && std::memcmp(text, "X60", 3) == 0)
    return AutoDecryptKind::Exes;
  constexpr char aesPrefix[] = "nb2XSAeSGcMveR1";
  constexpr std::size_t aesPrefixLength = sizeof(aesPrefix) - 1;
  if (length >= aesPrefixLength &&
      std::memcmp(text, aesPrefix, aesPrefixLength) == 0)
    return AutoDecryptKind::Aes;
  return AutoDecryptKind::None;
}
// Recognize the same prefix in raw disk bytes before applying an encoding override.
inline bool hasEncodedCryptoPrefix(const char* bytes, std::size_t size) {
  const auto hasPrefix = [](const char* text, std::size_t length) {
    return cryptoPrefix(text, length) != AutoDecryptKind::None;
  };
  if (!bytes || size < 3)
    return false;
  if (std::memcmp(bytes, "\xEF\xBB\xBF", 3) == 0)
    return hasPrefix(bytes + 3, size - 3);
  if (hasPrefix(bytes, size))
    return true;
  if (std::memcmp(bytes, "\xFF\xFE", 2) == 0 || std::memcmp(bytes, "\xFE\xFF", 2) == 0) {
    bytes += 2;
    size -= 2;
  }
  if (size < 6 || (bytes[0] != 0 && bytes[1] != 0))
    return false;
  const std::size_t character = bytes[0] == 0 ? 1 : 0;
  char ascii[15];
  std::size_t length = 0;
  while (length < sizeof(ascii) && length < size / 2 && bytes[length * 2 + 1 - character] == 0) {
    ascii[length] = bytes[length * 2 + character];
    ++length;
  }
  return hasPrefix(ascii, length);
}
} // namespace xs
