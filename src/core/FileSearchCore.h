#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace xs { namespace fileSearch {
enum class ContentError { none, missingAnd, missingOr, invalidQuote };

struct ContentQuery {
  std::vector<std::wstring> terms;
  std::vector<std::size_t> alternativeEnds; // AND within each range, OR between ranges.
  std::size_t overlap = 0;
  ContentError error = ContentError::none;
};

inline wchar_t lowerAscii(wchar_t ch) {
  return ch >= L'A' && ch <= L'Z' ? static_cast<wchar_t>(ch + (L'a' - L'A')) : ch;
}

inline std::wstring_view trimContent(std::wstring_view text) {
  constexpr std::wstring_view spaces = L" \t\u3000";
  const auto first = text.find_first_not_of(spaces);
  if (first == std::wstring_view::npos) return {};
  return text.substr(first, text.find_last_not_of(spaces) - first + 1);
}

inline std::size_t contentQuoteEnd(std::wstring_view text, std::size_t start) {
  for (auto quote = text.find(L'"', start + 1); quote != std::wstring_view::npos;
       quote = text.find(L'"', quote + 2)) {
    if (quote + 1 == text.size() || text[quote + 1] != L'"') return quote;
  }
  return std::wstring_view::npos;
}

inline bool contentOperator(std::wstring_view text, std::size_t pos, std::wstring_view token) {
  const auto end = pos + token.size();
  return end <= text.size() && (end == text.size() || trimContent(text.substr(end, 1)).empty()) &&
      std::equal(token.begin(), token.end(), text.begin() + pos,
                 [](wchar_t left, wchar_t right) { return left == lowerAscii(right); });
}

inline ContentQuery parseContent(std::wstring_view input) {
  ContentQuery query;
  if (input.empty() || input == L"*") return query;
  auto addTerm = [&](std::wstring_view spelling) {
    const auto trimmed = trimContent(spelling);
    std::wstring term;
    if (!trimmed.empty() && trimmed.front() == L'"' &&
        contentQuoteEnd(trimmed, 0) == trimmed.size() - 1) {
      for (std::size_t i = 1; i < trimmed.size() - 1; ++i) {
        term += trimmed[i];
        if (trimmed[i] == L'"') ++i; // A doubled quote represents one literal quote.
      }
    } else {
      term = spelling;
    }
    if (term.empty()) {
      query.error = ContentError::invalidQuote;
      return false;
    }
    query.overlap = std::max(query.overlap, term.size() - 1);
    query.terms.push_back(std::move(term));
    return true;
  };
  std::size_t begin = 0;
  ContentError previous = ContentError::none;
  for (std::size_t i = 0; i < input.size(); ++i) {
    if (input[i] == L'"') {
      const auto end = contentQuoteEnd(input, i);
      if (end == std::wstring_view::npos) {
        query.error = ContentError::invalidQuote;
        return query;
      }
      i = end;
      continue;
    }
    if (i && !trimContent(input.substr(i - 1, 1)).empty()) continue;
    const bool isOr = contentOperator(input, i, L"or");
    if (!isOr && !contentOperator(input, i, L"and")) continue;
    const auto length = isOr ? 2u : 3u;
    const auto term = trimContent(input.substr(begin, i - begin));
    const auto missing = isOr ? ContentError::missingOr : ContentError::missingAnd;
    if (term.empty()) {
      // A lone "and" or "or" is still an ordinary search term.
      if (previous == ContentError::none && trimContent(input).size() == length) break;
      query.error = previous == ContentError::none ? missing : previous;
      return query;
    }
    if (!addTerm(term)) return query;
    if (isOr) query.alternativeEnds.push_back(query.terms.size());
    previous = missing;
    begin = i + length;
    i = begin - 1;
  }
  const auto last = previous == ContentError::none ? input : trimContent(input.substr(begin));
  if (last.empty()) {
    query.error = previous;
    return query;
  }
  if (addTerm(last)) query.alternativeEnds.push_back(query.terms.size());
  return query;
}

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
