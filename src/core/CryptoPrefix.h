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
} // namespace xs
