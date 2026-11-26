// 雲端 X60 檔案（Windows 版 R159～R166 CloudFiles.cpp）中不碰視窗的規則：
// 檔名／UUID／版本檢查、API 網址解析、欄位設定解析
#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>

namespace xs::cloud {

constexpr std::size_t cipherLimit = 111848313;          // 64 MiB 明文的 X60 密文上限（與 PHP 相同）
constexpr const char* script = "notepad2xs_cloud_fils_system.php";
constexpr std::size_t columnCount = 6;                  // 名稱、類型、大小、最後修改時間、路徑、副檔名
constexpr std::array<int, columnCount> defaultColumnWidths{190, 105, 82, 132, 190, 78};
constexpr unsigned defaultVisibleColumns = 0x0f;
constexpr int defaultSort = 3;                          // 依最後修改時間遞減

inline char16_t fold(char16_t ch) { return ch >= u'A' && ch <= u'Z' ? char16_t(ch + 32) : ch; }

inline bool equalsIgnoreCase(std::u16string_view a, std::u16string_view b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (fold(a[i]) != fold(b[i])) return false;
  return true;
}

inline bool hasX60Extension(std::u16string_view name) {
  return name.size() >= 4 && equalsIgnoreCase(name.substr(name.size() - 4), u".x60");
}

// UTF-16 轉 UTF-8 的位元組數；遇到不成對的代理字元回傳 SIZE_MAX
inline std::size_t utf8Length(std::u16string_view text) {
  std::size_t bytes = 0;
  for (std::size_t i = 0; i < text.size(); ++i) {
    const char16_t ch = text[i];
    if (ch < 0x80) bytes += 1;
    else if (ch < 0x800) bytes += 2;
    else if (ch >= 0xD800 && ch <= 0xDBFF) {
      if (i + 1 >= text.size() || text[i + 1] < 0xDC00 || text[i + 1] > 0xDFFF) return SIZE_MAX;
      bytes += 4;
      ++i;
    } else if (ch >= 0xDC00 && ch <= 0xDFFF) return SIZE_MAX;
    else bytes += 3;
  }
  return bytes;
}

// 檔名與資料夾名稱規則（與 Windows 版 validName、PHP nx_valid_name 相同）
inline bool validName(std::u16string_view name) {
  if (name.empty() || name.size() > 240 || name.front() == u'.' || name.front() == u' ' ||
      name.back() == u'.' || name.back() == u' ' || hasX60Extension(name) ||
      name.find_first_of(u"\\/:\"<>|?*") != std::u16string_view::npos ||
      std::any_of(name.begin(), name.end(), [](char16_t ch) { return ch < 32 || ch == 127; }))
    return false;
  const auto leaf = name.substr(0, name.find(u'.'));
  for (const auto* reserved : {u"CON", u"PRN", u"AUX", u"NUL"})
    if (equalsIgnoreCase(leaf, reserved)) return false;
  if (leaf.size() == 4 && leaf.back() >= u'1' && leaf.back() <= u'9' &&
      (equalsIgnoreCase(leaf.substr(0, 3), u"COM") || equalsIgnoreCase(leaf.substr(0, 3), u"LPT")))
    return false;
  return utf8Length(name) <= 240;
}

inline bool validRevision(std::string_view revision) {
  return revision.size() == 40 && revision.find_first_not_of("0123456789abcdef") == std::string_view::npos;
}

inline bool validId(std::string_view id) {
  if (id.size() != 36) return false;
  for (std::size_t i = 0; i < id.size(); ++i) {
    const char ch = id[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (ch != '-') return false;
    } else if (!(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f')) return false;
  }
  return true;
}

inline bool validFolder(std::string_view id) { return id == "root" || validId(id); }

struct Endpoint {
  std::string base;   // 使用者輸入的資料夾網址（結尾補上 /）
  std::string api;    // base + PHP 檔名
  std::string scheme, host;
  int port = 0;
  bool ok = false;
};

// 解析「設定 → 雲端設定」輸入的資料夾網址；只接受 http／https，不可含帳密、查詢字串或 .php
inline Endpoint endpoint(std::string_view input) {
  Endpoint result;
  const auto first = input.find_first_not_of(" \t\r\n");
  if (first == std::string_view::npos) return result;
  const auto last = input.find_last_not_of(" \t\r\n");
  std::string base(input.substr(first, last - first + 1));
  if (base.size() > 2000 || base.find_first_of("|?#\\ \t\r\n") != std::string::npos ||
      std::any_of(base.begin(), base.end(), [](unsigned char ch) { return ch < 32 || ch == 127; }))
    return result;
  const auto colon = base.find("://");
  if (colon == std::string::npos) return result;
  std::string scheme = base.substr(0, colon);
  std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char c) { return (char)std::tolower(c); });
  if (scheme != "http" && scheme != "https") return result;
  const auto rest = base.substr(colon + 3);
  const auto slash = rest.find('/');
  const std::string authority = rest.substr(0, slash);
  std::string path = slash == std::string::npos ? std::string() : rest.substr(slash);
  if (authority.empty() || authority.find('@') != std::string::npos) return result;
  std::string host = authority;
  int port = scheme == "https" ? 443 : 80;
  if (authority.front() == '[') {   // IPv6
    const auto close = authority.find(']');
    if (close == std::string::npos || close == 1) return result;
    host = authority.substr(1, close - 1);
    const auto tail = authority.substr(close + 1);
    if (!tail.empty()) {
      if (tail.front() != ':' || tail.size() == 1) return result;
      if (tail.find_first_not_of("0123456789", 1) != std::string::npos || tail.size() > 6) return result;
      port = std::stoi(tail.substr(1));
    }
  } else if (const auto p = authority.rfind(':'); p != std::string::npos) {
    host = authority.substr(0, p);
    const auto digits = authority.substr(p + 1);
    if (digits.empty() || digits.size() > 5 || digits.find_first_not_of("0123456789") != std::string::npos) return result;
    port = std::stoi(digits);
  }
  if (host.empty() || port <= 0 || port > 65535) return result;
  if (path.size() >= 4) {
    std::string tail = path.substr(path.size() - 4);
    std::transform(tail.begin(), tail.end(), tail.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    if (tail == ".php") return result;
  }
  while (!path.empty() && path.back() == '/') path.pop_back();
  while (!base.empty() && base.back() == '/') base.pop_back();
  result.base = base + "/";
  result.api = scheme + "://" + authority + path + "/" + script;
  result.scheme = scheme;
  result.host = host;
  result.port = port;
  result.ok = true;
  return result;
}

// 百分比編碼（RFC 3986 未保留字元以外全部編碼）
inline std::string encode(std::string_view utf8) {
  static constexpr char hex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char byte : utf8) {
    if ((byte >= '0' && byte <= '9') || (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
        byte == '-' || byte == '_' || byte == '.' || byte == '~') {
      out += static_cast<char>(byte);
    } else {
      out += '%';
      out += hex[byte >> 4];
      out += hex[byte & 15];
    }
  }
  return out;
}

// 「1,2,3」形式的整數清單（欄位順序與寬度）；格式不對回傳 false
template <std::size_t N>
bool parseIntegerList(std::string_view text, std::array<int, N>& values) {
  std::size_t pos = 0;
  for (std::size_t i = 0; i < N; ++i) {
    std::size_t start = pos;
    while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') ++pos;
    if (pos == start || pos - start > 5) return false;
    const int value = std::stoi(std::string(text.substr(start, pos - start)));
    if (value > 10000) return false;
    values[i] = value;
    if (i + 1 < N) {
      if (pos >= text.size() || text[pos] != ',') return false;
      ++pos;
    }
  }
  while (pos < text.size() && (text[pos] == ' ' || text[pos] == '\t')) ++pos;
  return pos == text.size();
}

template <std::size_t N>
std::string integerList(const std::array<int, N>& values) {
  std::string result;
  for (std::size_t i = 0; i < N; ++i) {
    if (i) result += ',';
    result += std::to_string(values[i]);
  }
  return result;
}

struct ColumnSettings {
  unsigned visible = defaultVisibleColumns;
  std::array<int, columnCount> order{0, 1, 2, 3, 4, 5};
  std::array<int, columnCount> widths = defaultColumnWidths;
  int sort = defaultSort;
  bool ascending = false;
};

// 讀取 [Cloud] 的欄位設定；不合法的值改用預設值（名稱欄一律顯示）
inline ColumnSettings readColumnSettings(long visible, std::string_view order, std::string_view widths,
                                         long sort, long ascending) {
  ColumnSettings s;
  const unsigned all = (1u << columnCount) - 1u;
  s.visible = (visible < 0 ? defaultVisibleColumns : static_cast<unsigned>(visible)) & all;
  s.visible |= 1u;
  std::array<int, columnCount> parsed{};
  if (parseIntegerList(order, parsed)) {
    unsigned seen = 0;
    bool valid = true;
    for (const int column : parsed) {
      if (column < 0 || column >= static_cast<int>(columnCount) || (seen & (1u << column))) { valid = false; break; }
      seen |= 1u << column;
    }
    if (valid && seen == all) s.order = parsed;
  }
  if (parseIntegerList(widths, parsed))
    for (std::size_t i = 0; i < columnCount; ++i) s.widths[i] = std::clamp(parsed[i], 32, 1200);
  s.sort = sort >= 0 && sort < static_cast<long>(columnCount) ? static_cast<int>(sort) : defaultSort;
  s.ascending = ascending != 0;
  return s;
}

// 點選欄位標題：同一欄反轉方向；換欄時文字欄預設遞增，大小與修改時間預設遞減
inline void clickSort(ColumnSettings& s, int column) {
  if (column < 0 || column >= static_cast<int>(columnCount)) return;
  if (s.sort == column) s.ascending = !s.ascending;
  else {
    s.sort = column;
    s.ascending = column != 2 && column != 3;
  }
}

// 重新整理時送給伺服器的排序提示（API 只認得 file／date／size）
inline const char* serverSort(int column) { return column == 2 ? "size" : column == 3 ? "date" : "file"; }

inline std::string formatFileSize(std::uint64_t bytes) {
  static constexpr const char* units[] = {"B", "KB", "MB", "GB", "TB"};
  if (bytes < 1024) return std::to_string(bytes) + " B";
  double value = static_cast<double>(bytes);
  std::size_t unit = 0;
  do {
    value /= 1024.0;
    ++unit;
  } while (value >= 1024.0 && unit + 1 < sizeof(units) / sizeof(units[0]));
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%.1f %s", value, units[unit]);
  return buffer;
}

}  // namespace xs::cloud
