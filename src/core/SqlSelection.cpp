#include "SqlSelection.h"
#include <algorithm>
#include <cstdint>
#include <vector>
namespace {
std::u16string trim(const std::u16string &s, const char16_t *spaces = u" \t") {
  auto a = s.find_first_not_of(spaces);
  if (a == std::u16string::npos)
    return {};
  return s.substr(a, s.find_last_not_of(spaces) - a + 1);
}
// A conservative single-statement check, not a database SQL grammar parser.
// The driver still prepares/validates the actual dialect before execution.
void oneStatement(const std::u16string &sql) {
  char16_t quote = 0;
  bool comment = false, lineComment = false, ended = false, hasCode = false;
  for (std::size_t i = 0; i < sql.size(); ++i) {
    const char16_t c = sql[i], next = i + 1 < sql.size() ? sql[i + 1] : 0;
    if (lineComment) {
      if (c == u'\n')
        lineComment = false;
      continue;
    }
    if (comment) {
      if (c == u'*' && next == u'/') {
        comment = false;
        ++i;
      }
      continue;
    }
    if (quote) {
      if (c == u'\\' && quote != u']') {
        if (next)
          ++i;
        continue;
      }
      if (c == quote) {
        if (next == quote)
          ++i;
        else
          quote = 0;
      }
      continue;
    }
    if (c == u' ' || c == u'\t' || c == u'\n')
      continue;
    if ((c == u'-' && next == u'-' &&
         (i + 2 == sql.size() || sql[i + 2] <= u' ')) ||
        c == u'#') {
      lineComment = true;
      continue;
    }
    if (c == u'/' && next == u'*') {
      if (i + 2 < sql.size() && (sql[i + 2] == u'!' || sql[i + 2] == u'M'))
        throw xs::SqlInputError(u"不支援可執行註解，請直接寫出單一 SQL 指令。");
      comment = true;
      ++i;
      continue;
    }
    if (ended)
      throw xs::SqlInputError(u"SQL 可跨多行，但不支援以分號分隔的多個指令。");
    if (c == u';') {
      ended = true;
      continue;
    }
    hasCode = true;
    if (c == u'\'' || c == u'"' || c == u'`')
      quote = c;
    else if (c == u'[')
      quote = u']';
  }
  if (quote || comment)
    throw xs::SqlInputError(u"SQL 的引號或註解未結束，請檢查 SQL 內容。");
  if (!hasCode)
    throw xs::SqlInputError(u"資料來源標記後必須包含 SQL 指令。");
}
// Keep these types at namespace scope: MSVC 14.51 fails to resolve the
// enclosing function-local enums in a local Scope default constructor.
namespace sqlWhere {
enum class Command { Unknown, Other, Select, Insert, Merge, Update, Delete };
enum class Recent { Other, For, No, Key, Do, Then, On, Duplicate };
struct Scope {
  Command command = Command::Unknown;
  bool where = false, dot = false, insertSource = false;
  Recent last = Recent::Other, previous = Recent::Other,
         third = Recent::Other;
  void barrier() {
    last = previous = third = Recent::Other;
    dot = false;
  }
};
} // namespace sqlWhere
} // namespace
namespace xs {
std::optional<std::string> selectedDosBatch(const std::u16string &text) {
  const auto markerEnd = text.find_first_of(u"\r\n");
  auto marker = trim(text.substr(0, markerEnd));
  if (!marker.empty() && marker.front() == 0xfeff)
    marker = trim(marker.substr(1));
  if (marker != u"[DOSCMD]")
    return std::nullopt;
  if (text.size() > 524288)
    throw SqlInputError(
        u"DOSCMD 選取內容過長，最多可處理 1 MiB 的 UTF-16 文字。");
  if (markerEnd == text.npos)
    throw SqlInputError(u"[DOSCMD] 後面至少需要一行批次命令。");
  std::size_t start = markerEnd + 1;
  if (text[markerEnd] == u'\r' && start < text.size() && text[start] == u'\n')
    ++start;
  std::u16string body;
  bool hasContent = false;
  for (std::size_t i = start; i < text.size(); ++i) {
    char16_t c = text[i];
    if (!c)
      throw SqlInputError(u"DOSCMD 內容不能包含 NUL 字元。");
    if (c == u'\r') {
      if (i + 1 < text.size() && text[i + 1] == u'\n')
        ++i;
      c = u'\n';
    }
    if (c == u'\n')
      body += u"\r\n";
    else {
      body += c;
      if (c != u' ' && c != u'\t')
        hasContent = true;
    }
  }
  if (!hasContent)
    throw SqlInputError(u"[DOSCMD] 後面不能只有空白，請填入批次命令。");
  // The console wrapper sets the active code page and waits after the child
  // CMD exits. Keep the user's BAT body free of injected chcp/pause commands.
  if (body.size() < 2 || body.substr(body.size() - 2) != u"\r\n")
    body += u"\r\n";
  return sqlUtf8(body);
}
std::u16string dosCommandLine(const std::u16string &systemCmd) {
  // Only the fixed runner path is expanded by CMD. File paths are transported
  // in a private child environment variable, not interpolated into this line.
  return quoteWindowsArgument(systemCmd) +
         u" /d /v:off /s /c \"\"%_NP2XS_RUNNER_FILE%\"\"";
}
std::optional<std::string> selectedPowerShell(const std::u16string &text) {
  const auto markerEnd = text.find_first_of(u"\r\n");
  auto marker = trim(text.substr(0, markerEnd));
  if (!marker.empty() && marker.front() == 0xfeff)
    marker = trim(marker.substr(1));
  if (marker != u"[PSCMD]")
    return std::nullopt;
  if (text.size() > 524288)
    throw SqlInputError(u"PSCMD 選取內容過長，最多可處理 1 MiB 的 UTF-16 文字。");
  if (markerEnd == text.npos)
    throw SqlInputError(u"[PSCMD] 後面至少需要一行 PowerShell 指令。");
  std::size_t start = markerEnd + 1;
  if (text[markerEnd] == u'\r' && start < text.size() && text[start] == u'\n')
    ++start;
  std::u16string script;
  bool hasContent = false;
  for (std::size_t i = start; i < text.size(); ++i) {
    char16_t c = text[i];
    if (!c)
      throw SqlInputError(u"PSCMD 內容不能包含 NUL 字元。");
    if (c == u'\r') {
      if (i + 1 < text.size() && text[i + 1] == u'\n')
        ++i;
      c = u'\n';
    }
    if (c == u'\n')
      script += u"\r\n";
    else {
      script += c;
      if (c != u' ' && c != u'\t')
        hasContent = true;
    }
  }
  if (!hasContent)
    throw SqlInputError(u"[PSCMD] 後面不能只有空白，請填入 PowerShell 指令。");
  // UTF-8 BOM is required for non-ASCII source in Windows PowerShell 5.1.
  // Preserve param/using placement, here-strings, indentation and script scope.
  return std::string("\xEF\xBB\xBF") + sqlUtf8(script);
}
namespace {
std::optional<std::string> selectedWshScript(const std::u16string &text,
                                             const char16_t *marker,
                                             const char16_t *language) {
  const auto markerEnd = text.find_first_of(u"\r\n");
  auto selectedMarker = trim(text.substr(0, markerEnd));
  if (!selectedMarker.empty() && selectedMarker.front() == 0xfeff)
    selectedMarker = trim(selectedMarker.substr(1));
  if (selectedMarker != marker)
    return std::nullopt;
  if (text.size() > 524288)
    throw SqlInputError(std::u16string(language) +
                        u" 選取內容過長，最多可處理 1 MiB 的 UTF-16 文字。");
  if (markerEnd == text.npos)
    throw SqlInputError(std::u16string(marker) +
                        u" 後面至少需要一行腳本內容。");
  std::size_t start = markerEnd + 1;
  if (text[markerEnd] == u'\r' && start < text.size() && text[start] == u'\n')
    ++start;
  std::u16string script;
  bool hasContent = false;
  for (std::size_t i = start; i < text.size(); ++i) {
    char16_t c = text[i];
    if (!c)
      throw SqlInputError(std::u16string(language) + u" 內容不能包含 NUL 字元。");
    if (c == u'\r') {
      if (i + 1 < text.size() && text[i + 1] == u'\n')
        ++i;
      c = u'\n';
    }
    if (c == u'\n')
      script += u"\r\n";
    else {
      script += c;
      if (c != u' ' && c != u'\t')
        hasContent = true;
    }
  }
  if (!hasContent)
    throw SqlInputError(std::u16string(marker) +
                        u" 後面不能只有空白，請填入腳本內容。");
  // WSH reliably recognizes UTF-16LE source with a BOM. Validate surrogate
  // pairs before emitting explicit little-endian bytes, independent of host.
  static_cast<void>(sqlUtf8(script));
  std::string encoded("\xFF\xFE", 2);
  encoded.reserve(2 + script.size() * 2);
  for (char16_t c : script) {
    encoded += static_cast<char>(c & 0xff);
    encoded += static_cast<char>((c >> 8) & 0xff);
  }
  return encoded;
}
} // namespace
std::optional<std::string> selectedJavaScript(const std::u16string &text) {
  return selectedWshScript(text, u"[JAVASCRIPT]", u"JScript");
}
std::optional<std::string> selectedVBScript(const std::u16string &text) {
  return selectedWshScript(text, u"[VBSCRIPT]", u"VBScript");
}
namespace {
bool wqlTokenEqual(const std::u16string &text, std::size_t begin,
                   std::size_t end, const char16_t *token) {
  std::size_t n = 0;
  while (token[n]) ++n;
  if (end - begin != n) return false;
  for (std::size_t i = 0; i < n; ++i) {
    char16_t a = text[begin + i];
    char16_t b = token[i];
    if (a >= u'a' && a <= u'z') a = static_cast<char16_t>(a - 32);
    if (a != b) return false;
  }
  return true;
}
std::vector<std::pair<std::size_t, std::size_t>> wqlTokens(
    const std::u16string &text) {
  std::vector<std::pair<std::size_t, std::size_t>> result;
  char16_t quote = 0;
  for (std::size_t i = 0; i < text.size();) {
    const char16_t c = text[i];
    if (quote) {
      if (c == quote) {
        if (i + 1 < text.size() && text[i + 1] == quote) i += 2;
        else { quote = 0; ++i; }
      } else if (c == u'\\' && i + 1 < text.size()) i += 2;
      else ++i;
      continue;
    }
    if (c == u'\'' || c == u'"') { quote = c; ++i; continue; }
    const bool start = (c >= u'A' && c <= u'Z') ||
                       (c >= u'a' && c <= u'z') || c == u'_';
    if (!start) { ++i; continue; }
    const auto begin = i++;
    while (i < text.size()) {
      const auto x = text[i];
      if ((x >= u'A' && x <= u'Z') || (x >= u'a' && x <= u'z') ||
          (x >= u'0' && x <= u'9') || x == u'_') ++i;
      else break;
    }
    result.emplace_back(begin, i);
  }
  return result;
}
} // namespace
std::optional<WqlSelection> parseWqlSelection(const std::u16string &text) {
  const auto markerEnd = text.find_first_of(u"\r\n");
  auto marker = trim(text.substr(0, markerEnd));
  if (!marker.empty() && marker.front() == 0xfeff)
    marker = trim(marker.substr(1));
  if (marker != u"[WQL]") return std::nullopt;
  if (text.size() > 524288)
    throw SqlInputError(u"WQL 選取內容過長，最多可處理 1 MiB 的 UTF-16 文字。");
  if (markerEnd == text.npos)
    throw SqlInputError(u"[WQL] 後面至少需要一行 WMI 查詢。");
  std::size_t start = markerEnd + 1;
  if (text[markerEnd] == u'\r' && start < text.size() && text[start] == u'\n')
    ++start;
  std::u16string statement;
  bool hasContent = false;
  for (std::size_t i = start; i < text.size(); ++i) {
    char16_t c = text[i];
    if (!c) throw SqlInputError(u"WQL 內容不能包含 NUL 字元。");
    if (c == u'\r') {
      if (i + 1 < text.size() && text[i + 1] == u'\n') ++i;
      c = u'\n';
    }
    if (c == u'\n') statement += u"\r\n";
    else {
      statement += c;
      if (c != u' ' && c != u'\t') hasContent = true;
    }
  }
  if (!hasContent)
    throw SqlInputError(u"[WQL] 後面不能只有空白，請填入 WMI 查詢。");
  // Validate UTF-16 before passing the query to SysAllocStringLen.
  static_cast<void>(sqlUtf8(statement));
  const auto kind = classifyWqlQuery(statement);
  if (kind == WqlQueryKind::Event)
    throw SqlInputError(u"[WQL] 第一階段不支援持續監聽型 Event Query（事件類別／WITHIN）。目前支援資料查詢、Schema Query 及 ASSOCIATORS／REFERENCES 關聯查詢。");
  if (kind == WqlQueryKind::Unsupported)
    throw SqlInputError(u"[WQL] 目前支援 SELECT、Schema Query、ASSOCIATORS OF 與 REFERENCES OF。");
  return WqlSelection{u"ROOT\\CIMV2", std::move(statement)};
}
std::optional<WqlProjection> parseWqlProjection(const std::u16string &statement) {
  const auto tokens = wqlTokens(statement);
  if (tokens.size() < 3) return std::nullopt;
  const auto [firstBegin, firstEnd] = tokens.front();
  if (!wqlTokenEqual(statement, firstBegin, firstEnd, u"SELECT"))
    return std::nullopt;
  std::size_t fromIndex = tokens.size();
  for (std::size_t i = 1; i + 1 < tokens.size(); ++i) {
    if (wqlTokenEqual(statement, tokens[i].first, tokens[i].second, u"FROM")) {
      fromIndex = i;
      break;
    }
  }
  if (fromIndex == tokens.size()) return std::nullopt;
  const auto [classBegin, classEnd] = tokens[fromIndex + 1];
  WqlProjection result;
  result.className = statement.substr(classBegin, classEnd - classBegin);
  auto projection = trim(statement.substr(firstEnd,
      tokens[fromIndex].first > firstEnd ? tokens[fromIndex].first - firstEnd : 0), u" \t\r\n");
  const auto projectionTokens = wqlTokens(projection);
  if (!projectionTokens.empty() && projectionTokens.front().first == 0 &&
      wqlTokenEqual(projection, projectionTokens.front().first,
                    projectionTokens.front().second, u"DISTINCT"))
    projection = trim(projection.substr(projectionTokens.front().second), u" \t\r\n");
  if (projection == u"*") {
    result.allProperties = true;
    return result;
  }
  if (projection.empty()) return std::nullopt;
  std::size_t begin = 0;
  while (begin <= projection.size()) {
    const auto comma = projection.find(u',', begin);
    const auto end = comma == projection.npos ? projection.size() : comma;
    const auto property = trim(projection.substr(begin, end - begin), u" \t\r\n");
    if (property.empty()) return std::nullopt;
    for (std::size_t i = 0; i < property.size(); ++i) {
      const auto c = property[i];
      const bool valid = (c >= u'A' && c <= u'Z') ||
                         (c >= u'a' && c <= u'z') || c == u'_' ||
                         (i && c >= u'0' && c <= u'9');
      if (!valid) return std::nullopt;
    }
    if (std::find(result.properties.begin(), result.properties.end(), property) == result.properties.end())
      result.properties.push_back(property);
    if (comma == projection.npos) break;
    begin = comma + 1;
  }
  return result.properties.empty() ? std::nullopt : std::optional<WqlProjection>(std::move(result));
}

WqlQueryKind classifyWqlQuery(const std::u16string &statement) {
  const auto tokens = wqlTokens(statement);
  if (tokens.empty()) return WqlQueryKind::Unsupported;
  const auto [firstBegin, firstEnd] = tokens.front();
  if (wqlTokenEqual(statement, firstBegin, firstEnd, u"ASSOCIATORS") ||
      wqlTokenEqual(statement, firstBegin, firstEnd, u"REFERENCES")) {
    // SchemaOnly changes ASSOCIATORS/REFERENCES from instance relationships
    // to class-definition relationships. Keep that distinction for result
    // materialization so the runner can include WMI system properties.
    bool whereSeen = false;
    for (const auto &[begin, end] : tokens) {
      if (!whereSeen) {
        whereSeen = wqlTokenEqual(statement, begin, end, u"WHERE");
        continue;
      }
      if (wqlTokenEqual(statement, begin, end, u"SCHEMAONLY"))
        return WqlQueryKind::AssociationSchema;
    }
    return WqlQueryKind::Association;
  }
  if (!wqlTokenEqual(statement, firstBegin, firstEnd, u"SELECT"))
    return WqlQueryKind::Unsupported;
  std::size_t fromIndex = tokens.size();
  for (std::size_t i = 1; i + 1 < tokens.size(); ++i) {
    if (wqlTokenEqual(statement, tokens[i].first, tokens[i].second, u"FROM")) {
      fromIndex = i;
      break;
    }
  }
  if (fromIndex == tokens.size()) return WqlQueryKind::Unsupported;
  const auto [classBegin, classEnd] = tokens[fromIndex + 1];
  const auto classLength = classEnd - classBegin;
  const bool classEndsEvent = classLength >= 5 &&
      wqlTokenEqual(statement, classEnd - 5, classEnd, u"EVENT");
  // Win32_NTLogEvent is a normal data class despite its suffix. Do not block
  // ordinary event-log inventory queries as event subscriptions.
  const bool isNtLogDataClass =
      wqlTokenEqual(statement, classBegin, classEnd, u"WIN32_NTLOGEVENT");
  // Intrinsic event subscriptions place WITHIN or GROUP WITHIN between the
  // event class and WHERE. Do not mistake ordinary GROUP/HAVING property names
  // later in a data-query WHERE clause for an event subscription.
  const bool eventClause = fromIndex + 2 < tokens.size() &&
      (wqlTokenEqual(statement, tokens[fromIndex + 2].first,
                     tokens[fromIndex + 2].second, u"WITHIN") ||
       wqlTokenEqual(statement, tokens[fromIndex + 2].first,
                     tokens[fromIndex + 2].second, u"GROUP"));
  if ((classEndsEvent && !isNtLogDataClass) || eventClause)
    return WqlQueryKind::Event;
  for (std::size_t i = 1; i + 1 < tokens.size(); ++i) {
    if (wqlTokenEqual(statement, tokens[i].first, tokens[i].second, u"FROM")) {
      const auto [nextBegin, nextEnd] = tokens[i + 1];
      return wqlTokenEqual(statement, nextBegin, nextEnd, u"META_CLASS")
                 ? WqlQueryKind::Schema : WqlQueryKind::Data;
    }
  }
  return WqlQueryKind::Unsupported;
}

std::u16string selectedUrl(const std::u16string &text) {
  const auto first = text.find_first_not_of(u" \t\r\n");
  if (first == text.npos)
    return {};
  auto value =
      text.substr(first, text.find_last_not_of(u" \t\r\n") - first + 1);
  auto lower = [](char16_t c) {
    return c >= u'A' && c <= u'Z' ? static_cast<char16_t>(c + 32) : c;
  };
  auto starts = [&](const char16_t *prefix) {
    std::size_t n = 0;
    while (prefix[n]) {
      if (n >= value.size() || lower(value[n]) != prefix[n])
        return false;
      ++n;
    }
    return true;
  };
  if (!starts(u"http://") && !starts(u"https://"))
    return {};
  if (value.size() > 8192)
    throw SqlInputError(u"網址過長，最多支援 8192 個 UTF-16 字元。");
  for (char16_t c : value)
    if (c <= 0x20 || c == 0x7f || c == u'"' || c == u'\\')
      throw SqlInputError(
          u"網址必須是單一字串，不可包含空白、換行或未編碼的引號。");
  sqlUtf8(value);
  return value;
}
namespace {
std::u16string selectionTrim(const std::u16string &text) {
  const auto first = text.find_first_not_of(u" \t\r\n");
  if (first == text.npos)
    return {};
  return text.substr(first, text.find_last_not_of(u" \t\r\n") - first + 1);
}
bool startsAsciiInsensitive(const std::u16string &value,
                             const char16_t *prefix) {
  std::size_t i = 0;
  for (; prefix[i]; ++i) {
    if (i >= value.size())
      return false;
    char16_t c = value[i];
    if (c >= u'A' && c <= u'Z')
      c = static_cast<char16_t>(c + (u'a' - u'A'));
    if (c != prefix[i])
      return false;
  }
  return true;
}
int hexDigit(char16_t c) {
  if (c >= u'0' && c <= u'9') return c - u'0';
  if (c >= u'a' && c <= u'f') return c - u'a' + 10;
  if (c >= u'A' && c <= u'F') return c - u'A' + 10;
  return -1;
}
void appendUtf8(std::string &out, std::uint32_t c) {
  if (c <= 0x7f) out.push_back(static_cast<char>(c));
  else if (c <= 0x7ff) {
    out.push_back(static_cast<char>(0xc0 | (c >> 6)));
    out.push_back(static_cast<char>(0x80 | (c & 63)));
  } else if (c <= 0xffff) {
    out.push_back(static_cast<char>(0xe0 | (c >> 12)));
    out.push_back(static_cast<char>(0x80 | ((c >> 6) & 63)));
    out.push_back(static_cast<char>(0x80 | (c & 63)));
  } else {
    out.push_back(static_cast<char>(0xf0 | (c >> 18)));
    out.push_back(static_cast<char>(0x80 | ((c >> 12) & 63)));
    out.push_back(static_cast<char>(0x80 | ((c >> 6) & 63)));
    out.push_back(static_cast<char>(0x80 | (c & 63)));
  }
}
std::u16string decodeUriComponent(const std::u16string &input) {
  std::string bytes;
  bytes.reserve(input.size());
  for (std::size_t i = 0; i < input.size(); ++i) {
    const char16_t c = input[i];
    if (c == u'%') {
      if (i + 2 >= input.size() || hexDigit(input[i + 1]) < 0 ||
          hexDigit(input[i + 2]) < 0)
        throw SqlInputError(u"URI 百分比編碼不完整或不正確。");
      bytes.push_back(static_cast<char>((hexDigit(input[i + 1]) << 4) |
                                         hexDigit(input[i + 2])));
      i += 2;
    } else if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 >= input.size() || input[i + 1] < 0xdc00 ||
          input[i + 1] > 0xdfff)
        throw SqlInputError(u"URI 包含不完整的 Unicode 字元。");
      const std::uint32_t cp = 0x10000 +
          ((static_cast<std::uint32_t>(c) - 0xd800) << 10) +
          (static_cast<std::uint32_t>(input[++i]) - 0xdc00);
      appendUtf8(bytes, cp);
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      throw SqlInputError(u"URI 包含不完整的 Unicode 字元。");
    } else {
      appendUtf8(bytes, c);
    }
  }
  std::u16string result;
  for (std::size_t i = 0; i < bytes.size();) {
    const auto first = static_cast<unsigned char>(bytes[i++]);
    std::uint32_t cp = 0;
    unsigned continuation = 0;
    if (first <= 0x7f) cp = first;
    else if (first >= 0xc2 && first <= 0xdf) { cp = first & 0x1f; continuation = 1; }
    else if (first >= 0xe0 && first <= 0xef) { cp = first & 0x0f; continuation = 2; }
    else if (first >= 0xf0 && first <= 0xf4) { cp = first & 0x07; continuation = 3; }
    else throw SqlInputError(u"URI 百分比編碼不是有效的 UTF-8。");
    if (i + continuation > bytes.size())
      throw SqlInputError(u"URI 百分比編碼不是有效的 UTF-8。");
    for (unsigned j = 0; j < continuation; ++j) {
      const auto next = static_cast<unsigned char>(bytes[i++]);
      if ((next & 0xc0) != 0x80)
        throw SqlInputError(u"URI 百分比編碼不是有效的 UTF-8。");
      cp = (cp << 6) | (next & 0x3f);
    }
    if ((continuation == 1 && cp < 0x80) ||
        (continuation == 2 && cp < 0x800) ||
        (continuation == 3 && cp < 0x10000) || cp > 0x10ffff ||
        (cp >= 0xd800 && cp <= 0xdfff))
      throw SqlInputError(u"URI 百分比編碼不是有效的 UTF-8。");
    if (cp <= 0xffff) result.push_back(static_cast<char16_t>(cp));
    else {
      cp -= 0x10000;
      result.push_back(static_cast<char16_t>(0xd800 + (cp >> 10)));
      result.push_back(static_cast<char16_t>(0xdc00 + (cp & 0x3ff)));
    }
  }
  return result;
}
void validateUriComponent(const std::u16string &value) {
  for (std::size_t i = 0; i < value.size(); ++i) {
    const char16_t c = value[i];
    if (c <= 0x20 || c == 0x7f || c == u'"' || c == u'\\')
      throw SqlInputError(u"URI 不可包含未編碼的空白、控制字元、引號或反斜線。");
    if (c == u'%') {
      if (i + 2 >= value.size() || hexDigit(value[i + 1]) < 0 ||
          hexDigit(value[i + 2]) < 0)
        throw SqlInputError(u"URI 百分比編碼不完整或不正確。");
      i += 2;
    }
  }
  // Also validates UTF-16 surrogate pairing.
  sqlUtf8(value);
}
struct AuthorityParts {
  std::u16string userEncoded;
  std::u16string hostPort;
  bool passwordProvided = false;
};
AuthorityParts parseAuthority(const std::u16string &authority,
                              const char16_t *schemeName) {
  if (authority.empty())
    throw SqlInputError(std::u16string(schemeName) + u" URI 缺少主機名稱。");
  AuthorityParts result;
  auto at = authority.find(u'@');
  std::u16string hostPort = authority;
  if (at != authority.npos) {
    if (authority.find(u'@', at + 1) != authority.npos)
      throw SqlInputError(u"URI 帳號欄位包含未編碼的 @ 字元。");
    const auto userInfo = authority.substr(0, at);
    const auto colon = userInfo.find(u':');
    result.userEncoded = userInfo.substr(0, colon);
    result.passwordProvided = colon != userInfo.npos;
    if (result.userEncoded.empty())
      throw SqlInputError(u"URI 帳號名稱不可為空白。");
    const auto decodedUser = decodeUriComponent(result.userEncoded);
    for (char16_t c : decodedUser)
      if (c <= 0x20 || c == 0x7f || c == u'@' || c == u':' ||
          c == u'/' || c == u'\\' || c == u'"')
        throw SqlInputError(u"URI 帳號名稱包含不支援的字元。");
    hostPort = authority.substr(at + 1);
  }
  result.hostPort = hostPort;
  return result;
}
std::pair<std::u16string, unsigned short> parseHostPort(
    const std::u16string &hostPort, unsigned short defaultPort,
    const char16_t *schemeName) {
  std::u16string host;
  std::u16string portText;
  if (!hostPort.empty() && hostPort.front() == u'[') {
    const auto close = hostPort.find(u']');
    if (close == hostPort.npos || close == 1)
      throw SqlInputError(u"IPv6 URI 主機名稱格式不正確。");
    host = hostPort.substr(0, close + 1);
    if (close + 1 < hostPort.size()) {
      if (hostPort[close + 1] != u':')
        throw SqlInputError(u"URI 主機名稱與連接埠格式不正確。");
      portText = hostPort.substr(close + 2);
    }
    for (std::size_t i = 1; i < close; ++i) {
      const char16_t c = hostPort[i];
      if (!((c >= u'0' && c <= u'9') || (c >= u'a' && c <= u'f') ||
            (c >= u'A' && c <= u'F') || c == u':' || c == u'.'))
        throw SqlInputError(u"IPv6 URI 主機名稱包含不支援的字元。");
    }
  } else {
    const auto colon = hostPort.find(u':');
    if (colon != hostPort.npos) {
      if (hostPort.find(u':', colon + 1) != hostPort.npos)
        throw SqlInputError(u"IPv6 位址必須使用方括號，例如 [2001:db8::1]。");
      host = hostPort.substr(0, colon);
      portText = hostPort.substr(colon + 1);
    } else host = hostPort;
    if (host.empty() || host.front() == u'-')
      throw SqlInputError(std::u16string(schemeName) + u" URI 主機名稱格式不正確。");
    for (char16_t c : host)
      if (!((c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') ||
            (c >= u'0' && c <= u'9') || c == u'.' || c == u'-' || c == u'_'))
        throw SqlInputError(u"URI 主機名稱包含不支援的字元；國際網域請先轉成 Punycode。");
  }
  unsigned port = defaultPort;
  if (!portText.empty()) {
    port = 0;
    for (char16_t c : portText) {
      if (c < u'0' || c > u'9' || port > 6553)
        throw SqlInputError(u"URI 連接埠必須是 1 到 65535 的整數。");
      port = port * 10 + static_cast<unsigned>(c - u'0');
    }
    if (!port || port > 65535)
      throw SqlInputError(u"URI 連接埠必須是 1 到 65535 的整數。");
  } else if (!hostPort.empty() && hostPort.back() == u':') {
    throw SqlInputError(u"URI 連接埠不可為空白。");
  }
  return {host, static_cast<unsigned short>(port)};
}
std::u16string uriRemainder(const std::u16string &value,
                            std::size_t authorityStart) {
  const auto pathStart = value.find(u'/', authorityStart);
  if (pathStart == value.npos)
    return {};
  const auto path = value.substr(pathStart);
  if (path.find(u'?') != path.npos || path.find(u'#') != path.npos)
    throw SqlInputError(u"目前不支援 FTP／SSH URI 的 Query String 或 Fragment。");
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (path[i] == u'%') {
      if (i + 2 >= path.size() || hexDigit(path[i + 1]) < 0 ||
          hexDigit(path[i + 2]) < 0)
        throw SqlInputError(u"URI 百分比編碼不完整或不正確。");
      i += 2;
    }
  }
  return path;
}
} // namespace
std::optional<FtpSelection> selectedFtpUrl(const std::u16string &text) {
  auto value = selectionTrim(text);
  if (!startsAsciiInsensitive(value, u"ftp://"))
    return std::nullopt;
  if (value.size() > 8192)
    throw SqlInputError(u"FTP URI 過長，最多支援 8192 個 UTF-16 字元。");
  validateUriComponent(value);
  const auto authorityStart = std::size_t{6};
  auto authorityEnd = value.find(u'/', authorityStart);
  if (authorityEnd == value.npos) authorityEnd = value.size();
  const auto authority = value.substr(authorityStart,
                                      authorityEnd - authorityStart);
  const auto parts = parseAuthority(authority, u"FTP");
  const auto parsedHost = parseHostPort(parts.hostPort, 21, u"FTP");
  const auto path = uriRemainder(value, authorityEnd);
  FtpSelection result;
  result.passwordProvided = parts.passwordProvided;
  result.url = u"ftp://";
  if (!parts.userEncoded.empty()) result.url += parts.userEncoded + u"@";
  result.url += parts.hostPort;
  result.url += path;
  (void)parsedHost;
  return result;
}
std::optional<SshSelection> selectedSshUrl(const std::u16string &text) {
  auto value = selectionTrim(text);
  if (!startsAsciiInsensitive(value, u"ssh://"))
    return std::nullopt;
  if (value.size() > 8192)
    throw SqlInputError(u"SSH URI 過長，最多支援 8192 個 UTF-16 字元。");
  validateUriComponent(value);
  const auto authorityStart = std::size_t{6};
  auto authorityEnd = value.find(u'/', authorityStart);
  if (authorityEnd == value.npos) authorityEnd = value.size();
  const auto authority = value.substr(authorityStart,
                                      authorityEnd - authorityStart);
  const auto parts = parseAuthority(authority, u"SSH");
  auto parsedHost = parseHostPort(parts.hostPort, 22, u"SSH");
  SshSelection result;
  if (!parts.userEncoded.empty()) {
    result.username = decodeUriComponent(parts.userEncoded);
    if (!result.username.empty() && result.username.front() == u'-')
      throw SqlInputError(u"SSH URI 帳號不可使用連字號開頭，以避免命令列選項混淆。");
    if (result.username.find(u'%') != result.username.npos)
      throw SqlInputError(u"SSH URI 帳號不可包含百分號，以避免 Windows 命令環境展開歧義。");
  }
  result.host = std::move(parsedHost.first);
  result.port = parsedHost.second;
  result.passwordProvided = parts.passwordProvided;
  const auto encodedPath = uriRemainder(value, authorityEnd);
  if (!encodedPath.empty()) {
    result.remoteDirectory = decodeUriComponent(encodedPath);
    if (result.remoteDirectory.empty() || result.remoteDirectory.front() != u'/')
      throw SqlInputError(u"SSH 遠端目錄必須是以 / 開頭的絕對路徑。");
    for (char16_t c : result.remoteDirectory)
      if (c < 0x20 || c == 0x7f || c == u'\\' || c == u'\"' || c == u'%')
        throw SqlInputError(u"SSH 遠端目錄包含控制字元、引號、反斜線或百分號。");
  }
  return result;
}
std::optional<std::u16string> selectedWindowsPath(
    const std::u16string &text) {
  auto value = selectionTrim(text);
  if (value.size() >= 2 &&
      ((value.front() == u'"' && value.back() == u'"') ||
       (value.front() == u'\'' && value.back() == u'\'')))
    value = value.substr(1, value.size() - 2);
  const bool drive = value.size() >= 3 &&
      ((value[0] >= u'a' && value[0] <= u'z') ||
       (value[0] >= u'A' && value[0] <= u'Z')) && value[1] == u':' &&
      (value[2] == u'\\' || value[2] == u'/');
  const bool unc = value.size() >= 5 && value[0] == u'\\' &&
      value[1] == u'\\' && value[2] != u'?' && value[2] != u'.';
  if (!drive && !unc)
    return std::nullopt;
  if (value.size() >= 32767)
    throw SqlInputError(u"Windows 路徑過長，目前最多支援 32766 個 UTF-16 字元。");
  for (char16_t c : value)
    if (c < 0x20 || c == 0x7f || c == u'"' || c == u'<' || c == u'>' ||
        c == u'|' || c == u'*' || c == u'?')
      throw SqlInputError(u"Windows 路徑包含不合法的字元或萬用字元。");
  if (drive) {
    for (std::size_t i = 2; i < value.size(); ++i)
      if (value[i] == u'/') value[i] = u'\\';
  } else {
    if (value.find(u'/') != value.npos)
      for (auto &c : value) if (c == u'/') c = u'\\';
    const auto serverEnd = value.find(u'\\', 2);
    const auto shareEnd = serverEnd == value.npos ? value.npos :
                          value.find(u'\\', serverEnd + 1);
    if (serverEnd == value.npos || serverEnd == 2 ||
        serverEnd + 1 >= value.size() || shareEnd == serverEnd + 1)
      throw SqlInputError(u"UNC 路徑必須包含伺服器名稱及共用名稱，例如 \\\\Server\\Share\\。");
  }
  return value;
}
std::u16string quoteWindowsArgument(const std::u16string &value) {
  std::u16string out = u"\"";
  unsigned slashes = 0;
  for (char16_t c : value) {
    if (c == u'\\') {
      ++slashes;
      continue;
    }
    if (c == u'"')
      out.append(slashes * 2 + 1, u'\\');
    else
      out.append(slashes, u'\\');
    out += c;
    slashes = 0;
  }
  out.append(slashes * 2, u'\\');
  return out + u"\"";
}
SqlSelection parseSqlSelection(const std::u16string &text) {
  if (text.empty() || text.size() > 524288)
    throw SqlInputError(u"請選取資料來源標記與 SQL，選取內容不得超過 1 MiB。");
  std::u16string s;
  s.reserve(text.size());
  for (std::size_t i = 0; i < text.size(); ++i) {
    char16_t c = text[i];
    if (c == 0)
      throw SqlInputError(u"選取文字不能含有 NUL 字元。");
    if (c == u'\r') {
      if (i + 1 < text.size() && text[i + 1] == u'\n')
        ++i;
      c = u'\n';
    }
    s += c;
  }
  // Only the first logical line is the DSN header. Keep all internal SQL
  // newlines (normalized to LF), including indentation, literals and comments.
  const auto newline = s.find(u'\n');
  if (newline == std::u16string::npos)
    throw SqlInputError(
        u"第一行為 [DB:ODBC資料來源名稱]，第二行起可填入多行 SQL。");
  auto header = trim(s.substr(0, newline));
  if (!header.empty() && header[0] == 0xfeff)
    header = trim(header.substr(1));
  if (header.size() < 6 || header.compare(0, 4, u"[DB:") != 0 ||
      header.back() != u']')
    throw SqlInputError(
        u"第一行格式必須是 [DB:ODBC資料來源名稱]，例如 [DB:測試資料庫]。");
  auto dsn = trim(header.substr(4, header.size() - 5));
  if (dsn.empty() || dsn.size() > 32)
    throw SqlInputError(u"ODBC 資料來源名稱須為 1～32 個 UTF-16 字元。");
  for (char16_t c : dsn)
    if (c < 0x20 || c == 0x7f ||
        std::u16string(u"[]{}(),;?*=!@\\").find(c) != std::u16string::npos)
      throw SqlInputError(u"ODBC 資料來源名稱含有不支援的符號，請使用有效的 "
                          u"Windows DSN 名稱。");
  auto sql = trim(s.substr(newline + 1), u" \t\n");
  if (sql.empty())
    throw SqlInputError(u"資料來源標記後不能只有空白，請填入 SQL 指令。");
  for (char16_t c : sql)
    if (c < 0x20 && c != u'\t' && c != u'\n')
      throw SqlInputError(u"SQL 包含不支援的控制字元。");
  oneStatement(sql);
  // Validate all UTF-16 now, before making any ODBC calls.
  sqlUtf8(dsn);
  sqlUtf8(sql);
  return {std::move(dsn), std::move(sql)};
}
bool sqlNeedsWhereConfirmation(const std::u16string &sql) {
  using sqlWhere::Command;
  using sqlWhere::Recent;
  using sqlWhere::Scope;
  std::vector<Scope> scopes(1);
  auto unsafe = [](const Scope &s) {
    return (s.command == Command::Update || s.command == Command::Delete) &&
           !s.where;
  };
  auto wordChar = [](char16_t c) {
    return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') ||
           (c >= u'0' && c <= u'9') || c == u'_' || c == u'$' || c == u'@' ||
           c == u':' || c >= 128;
  };
  for (std::size_t i = 0; i < sql.size();) {
    const char16_t c = sql[i], next = i + 1 < sql.size() ? sql[i + 1] : 0;
    if (c == u' ' || c == u'\t' || c == u'\r' || c == u'\n') {
      ++i;
      continue;
    }
    // Treat every -- form as a comment for this conservative warning, covering
    // SQL Server/PostgreSQL as well as MySQL's whitespace-required form.
    if ((c == u'-' && next == u'-') || c == u'#') {
      while (i < sql.size() && sql[i] != u'\r' && sql[i] != u'\n')
        ++i;
      continue;
    }
    if (c == u'/' && next == u'*') {
      unsigned depth = 1;
      i += 2;
      while (i < sql.size() && depth) {
        if (i + 1 < sql.size() && sql[i] == u'/' && sql[i + 1] == u'*') {
          ++depth;
          i += 2;
        } else if (i + 1 < sql.size() && sql[i] == u'*' && sql[i + 1] == u'/') {
          --depth;
          i += 2;
        } else
          ++i;
      }
      continue;
    }
    // PostgreSQL dollar-quoted text, including tagged delimiters.
    if (c == u'$') {
      auto end = i + 1;
      while (end < sql.size() &&
             ((sql[end] >= u'A' && sql[end] <= u'Z') ||
              (sql[end] >= u'a' && sql[end] <= u'z') || sql[end] == u'_' ||
              (end > i + 1 && sql[end] >= u'0' && sql[end] <= u'9')))
        ++end;
      if (end < sql.size() && sql[end] == u'$') {
        const auto delimiter = sql.substr(i, end - i + 1);
        const auto close = sql.find(delimiter, end + 1);
        i = close == sql.npos ? sql.size() : close + delimiter.size();
        scopes.back().barrier();
        continue;
      }
    }
    // Oracle alternative quoting q'[text]', q'{text}', q'(text)', q'<text>'.
    if ((c == u'q' || c == u'Q') && next == u'\'' && i + 2 < sql.size()) {
      char16_t close = sql[i + 2];
      if (close == u'[')
        close = u']';
      else if (close == u'{')
        close = u'}';
      else if (close == u'(')
        close = u')';
      else if (close == u'<')
        close = u'>';
      const auto at = sql.find(std::u16string{close, u'\''}, i + 3);
      i = at == sql.npos ? sql.size() : at + 2;
      scopes.back().barrier();
      continue;
    }
    if (c == u'\'' || c == u'"' || c == u'`' || c == u'[') {
      const auto close = c == u'[' ? u']' : c;
      ++i;
      while (i < sql.size()) {
        if (sql[i] == u'\\' && close != u']') {
          i += (i + 1 < sql.size() ? 2 : 1);
          continue;
        }
        if (sql[i++] == close) {
          if (i < sql.size() && sql[i] == close) {
            ++i;
            continue;
          }
          break;
        }
      }
      scopes.back().barrier();
      continue;
    }
    if (c == u'(') {
      scopes.back().barrier();
      scopes.emplace_back();
      ++i;
      continue;
    }
    if (c == u')') {
      if (unsafe(scopes.back()))
        return true;
      if (scopes.size() > 1)
        scopes.pop_back();
      scopes.back().barrier();
      ++i;
      continue;
    }
    if (wordChar(c)) {
      const auto start = i++;
      while (i < sql.size() && wordChar(sql[i]))
        ++i;
      auto word = sql.substr(start, i - start);
      for (auto &ch : word)
        if (ch >= u'a' && ch <= u'z')
          ch = static_cast<char16_t>(ch - 32);
      auto &scope = scopes.back();
      if (!scope.dot) {
        const bool mutation = word == u"UPDATE" || word == u"DELETE";
        const bool other = word == u"SELECT" || word == u"INSERT" ||
                           word == u"MERGE" || word == u"CREATE" ||
                           word == u"ALTER" || word == u"DROP" ||
                           word == u"SHOW" || word == u"CALL" ||
                           word == u"EXEC" || word == u"EXECUTE";
        const bool rowLock =
            word == u"UPDATE" && scope.command == Command::Select &&
            (scope.last == Recent::For ||
             (scope.last == Recent::Key && scope.previous == Recent::No &&
              scope.third == Recent::For));
        const bool upsert =
            word == u"UPDATE" &&
            (scope.command == Command::Insert || scope.insertSource) &&
            (scope.last == Recent::Do || (scope.last == Recent::Key &&
                                          scope.previous == Recent::Duplicate &&
                                          scope.third == Recent::On));
        const bool mergeAction = mutation && scope.command == Command::Merge &&
                                 scope.last == Recent::Then;
        const bool insertQuery =
            word == u"SELECT" &&
            (scope.command == Command::Insert || scope.insertSource);
        // A later statement cannot lend its WHERE to an earlier mutation.
        if ((mutation && !rowLock && !upsert && !mergeAction) || other) {
          if (unsafe(scope))
            return true;
          scope = Scope{};
          scope.insertSource = insertQuery;
          if (mutation)
            scope.command =
                word == u"UPDATE" ? Command::Update : Command::Delete;
          else if (word == u"SELECT")
            scope.command = Command::Select;
          else if (word == u"INSERT")
            scope.command = Command::Insert;
          else if (word == u"MERGE")
            scope.command = Command::Merge;
          else
            scope.command = Command::Other;
        }
        if (word == u"WHERE" && (scope.command == Command::Update ||
                                 scope.command == Command::Delete))
          scope.where = true;
      }
      scope.third = scope.previous;
      scope.previous = scope.last;
      scope.last = word == u"FOR"         ? Recent::For
                   : word == u"NO"        ? Recent::No
                   : word == u"KEY"       ? Recent::Key
                   : word == u"DO"        ? Recent::Do
                   : word == u"THEN"      ? Recent::Then
                   : word == u"ON"        ? Recent::On
                   : word == u"DUPLICATE" ? Recent::Duplicate
                                          : Recent::Other;
      scope.dot = false;
      continue;
    }
    if (c == u';') {
      if (unsafe(scopes.back()))
        return true;
      scopes.back() = Scope{};
    }
    scopes.back().barrier();
    scopes.back().dot = c == u'.';
    ++i;
  }
  for (const auto &scope : scopes)
    if (unsafe(scope))
      return true;
  return false;
}
std::string sqlUtf8(const std::u16string &s) {
  std::string out;
  for (std::size_t i = 0; i < s.size(); ++i) {
    std::uint32_t c = s[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 == s.size() || s[i + 1] < 0xdc00 || s[i + 1] > 0xdfff)
        throw SqlInputError(u"文字包含不完整的 Unicode 字元。");
      c = 0x10000 + ((c - 0xd800) << 10) + (s[++i] - 0xdc00);
    } else if (c >= 0xdc00 && c <= 0xdfff)
      throw SqlInputError(u"文字包含不完整的 Unicode 字元。");
    if (c < 0x80)
      out += static_cast<char>(c);
    else if (c < 0x800) {
      out += static_cast<char>(0xc0 | (c >> 6));
      out += static_cast<char>(0x80 | (c & 63));
    } else if (c < 0x10000) {
      out += static_cast<char>(0xe0 | (c >> 12));
      out += static_cast<char>(0x80 | ((c >> 6) & 63));
      out += static_cast<char>(0x80 | (c & 63));
    } else {
      out += static_cast<char>(0xf0 | (c >> 18));
      out += static_cast<char>(0x80 | ((c >> 12) & 63));
      out += static_cast<char>(0x80 | ((c >> 6) & 63));
      out += static_cast<char>(0x80 | (c & 63));
    }
  }
  return out;
}
std::string sqlCell(const std::u16string &s) {
  std::u16string escaped = u"\"";
  constexpr char16_t hex[] = u"0123456789ABCDEF";
  for (char16_t c : s) {
    switch (c) {
    case u'\\':
      escaped += u"\\\\";
      break;
    case u'"':
      escaped += u"\\\"";
      break;
    case u'\t':
      escaped += u"\\t";
      break;
    case u'\r':
      escaped += u"\\r";
      break;
    case u'\n':
      escaped += u"\\n";
      break;
    default:
      if (c < 0x20 || c == 0x7f) {
        escaped += u"\\u00";
        escaped += hex[(c >> 4) & 15];
        escaped += hex[c & 15];
      } else
        escaped += c;
    }
  }
  escaped += u'"';
  return sqlUtf8(escaped);
}
} // namespace xs
