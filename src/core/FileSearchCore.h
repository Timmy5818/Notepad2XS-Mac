#pragma once
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace xs { namespace fileSearch {
// All times are UTC FILETIME ticks. The UI formats local time separately.
inline std::uint64_t minimumSize(int choice) {
  const std::uint64_t mb = 1024ull * 1024;
  const std::uint64_t values[] = {0, mb, 10 * mb, 100 * mb, 1024 * mb, 10240 * mb};
  return choice >= 0 && choice < 6 ? values[choice] : 0;
}
inline std::uint64_t ageTicks(int choice) {
  const std::uint64_t seconds[] = {0, 3600, 86400, 604800, 2592000, 31536000};
  return choice >= 0 && choice < 6 ? seconds[choice] * 10000000ull : 0;
}
inline bool passes(std::uint64_t size, std::uint64_t modified,
                   std::uint64_t now, int dateChoice, int sizeChoice) {
  const auto age = ageTicks(dateChoice);
  return (!sizeChoice || size > minimumSize(sizeChoice)) &&
         (!age || (modified <= now && now - modified <= age));
}
inline std::vector<std::wstring> patterns(const std::wstring &input) {
  std::vector<std::wstring> result;
  std::size_t begin = 0;
  do {
    const auto end = input.find(L',', begin);
    const auto piece = input.substr(begin, end == std::wstring::npos ? end : end - begin);
    const auto first = piece.find_first_not_of(L" \t\r\n");
    if (first != std::wstring::npos) {
      auto pattern = piece.substr(first, piece.find_last_not_of(L" \t\r\n") - first + 1);
      // A name pattern is never a path or a shell command.
      if (pattern.find_first_of(L"\\/:\"<>|?") != std::wstring::npos) return {};
      result.push_back(std::move(pattern));
    }
    if (end == std::wstring::npos) break;
    begin = end + 1;
  } while (begin <= input.size());
  if (result.empty()) result.push_back(L"*");
  return result;
}
inline bool formatFilterAvailable(const std::vector<std::wstring> &filters) {
  if (filters.empty()) return false; // Includes invalid input rejected by patterns().
  for (const auto &filter : filters)
    if (filter != L"*" && (filter.size() < 2 || filter.compare(filter.size() - 2, 2, L".*") != 0)) return false;
  return true;
}
inline bool formatFilterApplies(const std::vector<std::wstring> &filters, bool checked) {
  return checked && formatFilterAvailable(filters);
}
// '*' matches zero or more UTF-16 code units. Character equality is supplied
// by Windows ordinal comparison; do not use locale-dependent DOS 8.3 matching.
template<class Equal>
bool matches(const std::wstring &name, const std::wstring &pattern, Equal equal) {
  if (pattern == L"*.*") return true; // Win32's all-files spelling also includes extensionless names.
  std::size_t n = 0, p = 0, star = std::wstring::npos, retry = 0;
  while (n < name.size()) {
    if (p < pattern.size() && pattern[p] != L'*' && equal(name[n], pattern[p])) { ++n; ++p; }
    else if (p < pattern.size() && pattern[p] == L'*') { star = p++; retry = n; }
    else if (star != std::wstring::npos) { p = star + 1; n = ++retry; }
    else return false;
  }
  while (p < pattern.size() && pattern[p] == L'*') ++p;
  return p == pattern.size();
}
template<class Equal>
bool matchesAny(const std::wstring &name, const std::vector<std::wstring> &filters, Equal equal) {
  for (const auto &filter : filters) if (matches(name, filter, equal)) return true;
  return false;
}
inline std::wstring csvCell(std::wstring value) {
  // Quoting alone does not stop Excel evaluating an untrusted filename.
  const auto first = value.find_first_not_of(L" \t\r\n");
  if (first != std::wstring::npos && std::wstring(L"=+-@").find(value[first]) != std::wstring::npos)
    value.insert(value.begin(), L'\'');
  std::wstring out = L"\"";
  for (const auto c : value) { if (c == L'"') out += L'"'; out += c; }
  return out + L'"';
}
} }
