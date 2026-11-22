#pragma once
#include <algorithm>
#include <stdexcept>
#include <string>

namespace xs {
// Exclude visually ambiguous characters, whitespace, quotes and backslash so
// generated passwords remain practical to read, copy and re-enter.
inline constexpr char passwordUpper[] = "ABCDEFGHJKLMNPQRSTUVWXYZ";
inline constexpr char passwordLower[] = "abcdefghijkmnopqrstuvwxyz";
inline constexpr char passwordDigits[] = "23456789";
inline constexpr char passwordSymbols[] = "!#$%&()*+,-./:;<=>?@[]^_{|}~";
inline constexpr char passwordAlphabet[] =
    "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#$%&()*+,-./:;<=>?@[]^_{|}~";

// Rejection sampling avoids modulo bias for every alphabet size up to 256.
template<class Draw>
unsigned passwordRandomBelow(Draw& draw, unsigned bound) {
  if (!bound || bound > 256) throw std::out_of_range("invalid random bound");
  const unsigned limit = (256u / bound) * bound;
  for (;;) {
    const unsigned byte = draw();
    if (byte >= 256) throw std::out_of_range("invalid random byte");
    if (byte < limit) return byte % bound;
  }
}

// Production UI entry points share this single OS-backed function. The
// overload below accepts an injected byte source for deterministic tests.
std::wstring generatePassword();

template<class Draw>
std::wstring generatePassword(Draw draw) {
  constexpr unsigned count = sizeof(passwordAlphabet) - 1;
  constexpr std::size_t passwordLength = 20;
  std::wstring out;
  out.reserve(passwordLength);
  bool upper = false, lower = false, digit = false, symbol = false;
  // Rejection sampling makes the output uniform over valid 20-character
  // strings: at least one character from each of the four character classes.
  do {
    out.clear();
    upper = lower = digit = symbol = false;
    while (out.size() < passwordLength) {
      const auto index = passwordRandomBelow(draw, count);
      const wchar_t c = static_cast<wchar_t>(passwordAlphabet[index]);
      out.push_back(c);
      upper = upper || std::find(passwordUpper, passwordUpper + sizeof(passwordUpper) - 1, c) != passwordUpper + sizeof(passwordUpper) - 1;
      lower = lower || std::find(passwordLower, passwordLower + sizeof(passwordLower) - 1, c) != passwordLower + sizeof(passwordLower) - 1;
      digit = digit || std::find(passwordDigits, passwordDigits + sizeof(passwordDigits) - 1, c) != passwordDigits + sizeof(passwordDigits) - 1;
      symbol = symbol || std::find(passwordSymbols, passwordSymbols + sizeof(passwordSymbols) - 1, c) != passwordSymbols + sizeof(passwordSymbols) - 1;
    }
  } while (!upper || !lower || !digit || !symbol);
  return out;
}
}
