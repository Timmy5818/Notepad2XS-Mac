#pragma once
#include <string>
#include <string_view>

namespace xs {
enum class MoneyStyle { common, financial };
enum class MoneyLine { converted, blank, invalid };

inline bool moneySpace(wchar_t c) {
  return c == L' ' || c == L'\t' || c == L'\u3000';
}

// Use decimal strings throughout: no floating-point rounding or integer overflow.
// One four-digit section per 萬/億/兆; at most 16 significant integer digits.
inline std::wstring moneyInteger(std::wstring_view digits, MoneyStyle style) {
  const bool financial = style == MoneyStyle::financial;
  const wchar_t* names = financial ? L"零壹貳參肆伍陸柒捌玖" : L"零一二三四五六七八九";
  const wchar_t* units = financial ? L"\0拾佰仟" : L"\0十百千";
  const wchar_t* groups[] = { L"", L"萬", L"億", L"兆" };
  std::wstring out;
  bool gap = false;
  for (std::size_t pos = 0; pos < digits.size();) {
    const std::size_t length = pos == 0 ? (digits.size() - 1) % 4 + 1 : 4;
    const auto section = digits.substr(pos, length);
    const auto first = section.find_first_not_of(L'0');
    pos += length;
    if (first == std::wstring_view::npos) {
      gap = !out.empty();
      continue;
    }
    if (!out.empty() && (gap || length - first < 4)) out += L'零';
    gap = false;
    bool zero = false;
    for (std::size_t i = first; i < length; ++i) {
      const unsigned digit = static_cast<unsigned>(section[i] - L'0');
      const std::size_t power = length - i - 1;
      if (!digit) { zero = true; continue; }
      if (zero) out += L'零';
      zero = false;
      // 十、十一... only at the start; 一百一十 keeps the second 一.
      if (financial || digit != 1 || power != 1 || !out.empty()) out += names[digit];
      if (power) out += units[power];
    }
    out += groups[(digits.size() - pos) / 4];
  }
  return out.empty() ? L"零" : out;
}

inline MoneyLine convertMoneyLine(std::wstring_view line, MoneyStyle style,
                                  std::wstring& converted) {
  std::size_t begin = 0, end = line.size();
  while (begin < end && moneySpace(line[begin])) ++begin;
  while (end > begin && moneySpace(line[end - 1])) --end;
  if (begin == end) return MoneyLine::blank;
  auto number = line.substr(begin, end - begin);
  bool negative = false;
  if (number.front() == L'-' || number.front() == L'+') {
    negative = number.front() == L'-';
    number.remove_prefix(1);
  }
  if (number.empty()) return MoneyLine::invalid;
  const auto point = number.find(L'.');
  const auto integer = number.substr(0, point);
  auto fraction = point == std::wstring_view::npos ? std::wstring_view{} : number.substr(point + 1);
  if (integer.empty() || (point != std::wstring_view::npos && (fraction.empty() || fraction.size() > 2)))
    return MoneyLine::invalid;
  for (wchar_t c : fraction) if (c < L'0' || c > L'9') return MoneyLine::invalid;
  std::wstring digits;
  std::size_t group = 0;
  bool comma = false;
  for (wchar_t c : integer) {
    if (c >= L'0' && c <= L'9') {
      // Discard leading zeros without limiting the size of their input spelling.
      if (c != L'0' || !digits.empty()) digits += c;
      if (digits.size() > 16) return MoneyLine::invalid;
      ++group;
    } else if (c == L',') {
      if (!group || (comma ? group != 3 : group > 3)) return MoneyLine::invalid;
      comma = true;
      group = 0;
    } else return MoneyLine::invalid;
  }
  if (!group || (comma && group != 3)) return MoneyLine::invalid;
  if (digits.empty()) digits = L"0";
  const unsigned jiao = fraction.empty() ? 0 : static_cast<unsigned>(fraction[0] - L'0');
  const unsigned fen = fraction.size() < 2 ? 0 : static_cast<unsigned>(fraction[1] - L'0');
  const wchar_t* names = style == MoneyStyle::financial ? L"零壹貳參肆伍陸柒捌玖" : L"零一二三四五六七八九";
  std::wstring money;
  if (negative && (digits != L"0" || jiao || fen)) money += L'負';
  money += moneyInteger(digits, style);
  money += L'元';
  if (!jiao && !fen) money += L'整';
  else {
    if (jiao) { money += names[jiao]; money += L'角'; }
    else if (digits != L"0") money += L'零';
    if (fen) { money += names[fen]; money += L'分'; }
  }
  converted.assign(line.substr(0, begin));
  converted += money;
  converted.append(line.substr(end));
  return MoneyLine::converted;
}

struct MoneyBatch {
  std::wstring text;
  std::size_t converted = 0, skipped = 0;
};

inline MoneyBatch convertMoney(std::wstring_view input, MoneyStyle style) {
  MoneyBatch result;
  for (std::size_t pos = 0; pos < input.size();) {
    auto end = input.find_first_of(L"\r\n", pos);
    if (end == std::wstring_view::npos) end = input.size();
    const auto line = input.substr(pos, end - pos);
    std::wstring converted;
    const auto status = convertMoneyLine(line, style, converted);
    if (status == MoneyLine::converted) { result.text += converted; ++result.converted; }
    else { result.text.append(line); if (status == MoneyLine::invalid) ++result.skipped; }
    pos = end;
    if (pos < input.size()) {
      const wchar_t eol = input[pos++];
      result.text += eol;
      if (eol == L'\r' && pos < input.size() && input[pos] == L'\n') result.text += input[pos++];
    }
  }
  return result;
}
}
