#include "SqlResults.h"
#include "SqlSelection.h"
#include <algorithm>
#include <stdexcept>
namespace {
std::size_t textSize(const std::u16string &s) { return s.size() * sizeof(char16_t); }
std::string escapedHtml(const std::string &s) {
  std::string out;
  for (char raw : s) {
    const auto c = static_cast<unsigned char>(raw);
    switch (c) {
    case '&': out += "&amp;"; break;
    case '<': out += "&lt;"; break;
    case '>': out += "&gt;"; break;
    case '"': out += "&quot;"; break;
    case '\'': out += "&#39;"; break;
    case 0: out += "\\0"; break;
    default: out += static_cast<char>(c); break;
    }
  }
  return out;
}
void rowText(const std::vector<xs::SqlCell> &row, const xs::SqlResultSink &sink) {
  std::string line;
  for (std::size_t i = 0; i < row.size(); ++i) {
    if (i) line += '\t';
    line += xs::sqlResultCell(row[i]);
  }
  sink(line + "\r\n");
}
void headerText(const xs::SqlResultSet &set, const xs::SqlResultSink &sink) {
  std::string line;
  for (std::size_t i = 0; i < set.columns.size(); ++i) {
    if (i) line += '\t';
    line += xs::sqlCell(set.columns[i]);
  }
  sink(line + "\r\n");
}
} // namespace
namespace xs {
bool SqlReport::beginTable(const std::vector<std::u16string> &columns) {
  if (sets.size() >= 64 || columns.size() > 256) return false;
  std::size_t bytes = sizeof(SqlResultSet) + columns.size() * sizeof(std::u16string);
  for (const auto &c : columns) bytes += textSize(c);
  if (bytes > maxStorage - storage) return false;
  SqlResultSet set;
  set.columns = columns;
  sets.push_back(std::move(set));
  storage += bytes;
  return true;
}
bool SqlReport::appendRow(std::vector<SqlCell> row) {
  if (sets.empty() || !sets.back().table || row.size() != sets.back().columns.size())
    throw std::logic_error("SQL row does not match its result set");
  std::size_t bytes = sizeof(row) + row.size() * sizeof(SqlCell);
  for (const auto &c : row) bytes += textSize(c.text);
  if (bytes > maxStorage - storage) return false;
  sets.back().rows.push_back(std::move(row));
  storage += bytes;
  return true;
}
bool SqlReport::addAffected(std::optional<std::int64_t> count) {
  if (sets.size() >= 64 || sizeof(SqlResultSet) > maxStorage - storage) return false;
  SqlResultSet set;
  set.table = false;
  set.affected = count;
  sets.push_back(std::move(set));
  storage += sizeof(SqlResultSet);
  return true;
}
std::string sqlResultCell(const SqlCell &cell) {
  if (cell.kind == SqlCellKind::Null) return "NULL";
  return cell.kind == SqlCellKind::Binary ? sqlUtf8(cell.text) : sqlCell(cell.text);
}
std::u16string sqlDisplayCell(const SqlCell &cell, bool preview) {
  if (cell.kind == SqlCellKind::Null) return u"NULL（空值）";
  if (cell.text.empty()) return u"\"\"（空字串）";
  std::u16string text;
  const auto limit = preview ? std::min<std::size_t>(cell.text.size(), 512) : cell.text.size();
  for (std::size_t i = 0; i < limit; ++i) {
    const auto c = cell.text[i];
    if (preview && i + 1 == limit && c >= 0xd800 && c <= 0xdbff) break;
    if (!c) text += u"\\0";
    else if (preview && (c == u'\r' || c == u'\n')) {
      text += u" ↵ ";
      if (c == u'\r' && i + 1 < limit && cell.text[i + 1] == u'\n') ++i;
    } else if (preview && c == u'\t') text += u" ⇥ ";
    else text += c;
  }
  if (preview && cell.text.size() > limit) text += u"…";
  return text;
}
const char *sqlStatusName(SqlResultStatus status) {
  switch (status) {
  case SqlResultStatus::Success: return "成功";
  case SqlResultStatus::Cancelled: return "已停止／取消";
  case SqlResultStatus::Truncated: return "結果已截斷";
  default: return "未正常完成";
  }
}
void copySqlRows(const SqlResultSet &set, const std::vector<std::size_t> &indices,
                 const SqlResultSink &sink) {
  if (!set.table) return;
  headerText(set, sink);
  for (auto index : indices) {
    if (index >= set.rows.size()) throw std::out_of_range("SQL row index");
    rowText(set.rows[index], sink);
  }
}
void exportSqlReport(const SqlReport &report, bool html, const SqlResultSink &sink) {
  auto esc = [&](const std::u16string &s) { return escapedHtml(sqlUtf8(s)); };
  if (html) {
    sink("<!doctype html><html lang=\"zh-Hant-TW\"><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
         "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"
         "<title>" + esc(report.title) + "</title><style>body{font:15px/1.6 'Microsoft JhengHei',sans-serif;color:#111;margin:24px}"
         "table{border-collapse:collapse;width:100%}td,th{border:1px solid #aaa;padding:6px;text-align:left;vertical-align:top;white-space:pre-wrap;overflow-wrap:anywhere}"
         "th{background:#eee}tr:nth-child(even){background:#f7f7f7}.scroll{overflow:auto}pre{white-space:pre-wrap;overflow-wrap:anywhere}.null{color:#666;font-style:italic}</style></head><body><h1>" + esc(report.title) + "</h1>");
    sink("<p>" + esc(report.sourceLabel) + "：" + esc(report.dsn) + "<br>開始時間：" + esc(report.started) +
         "<br>狀態：" + escapedHtml(sqlStatusName(report.status)) +
         "<br>耗時：" + std::to_string(report.elapsedMs) + " 毫秒</p>");
  } else {
    sink(sqlUtf8(report.title) + "\r\n" + sqlUtf8(report.sourceLabel) + "：" + sqlUtf8(report.dsn) +
         "\r\n開始時間：" + sqlUtf8(report.started) + "\r\n狀態：" +
         sqlStatusName(report.status) + "\r\n耗時：" +
         std::to_string(report.elapsedMs) + " 毫秒\r\n");
  }
  for (std::size_t n = 0; n < report.sets.size(); ++n) {
    const auto &set = report.sets[n];
    const auto title = "結果集 " + std::to_string(n + 1);
    sink(html ? "<h2>" + title + "</h2>" : "\r\n" + title + "\r\n");
    if (!set.table) {
      const auto count = set.affected ? std::to_string(*set.affected) : "驅動未提供";
      sink(html ? "<p>影響筆數：" + count + "</p>" : "影響筆數：" + count + "\r\n");
      continue;
    }
    if (!html) {
      headerText(set, sink);
      for (const auto &row : set.rows) rowText(row, sink);
      sink("資料列：" + std::to_string(set.rows.size()) + "\r\n");
    } else {
      sink("<p>資料列：" + std::to_string(set.rows.size()) + "</p><div class=\"scroll\"><table><thead><tr>");
      for (const auto &c : set.columns) sink("<th>" + esc(c) + "</th>");
      sink("</tr></thead><tbody>");
      for (const auto &row : set.rows) {
        sink("<tr>");
        for (const auto &cell : row) {
          if (cell.kind == SqlCellKind::Null) sink("<td class=\"null\">NULL（空值）</td>");
          else if (cell.kind == SqlCellKind::Text && cell.text.empty()) sink("<td>\"\"（空字串）</td>");
          else sink("<td>" + esc(cell.text) + "</td>");
        }
        sink("</tr>");
      }
      sink("</tbody></table></div>");
    }
  }
  sink(html ? "<h2>執行訊息</h2><pre>" + escapedHtml(report.notes) + "</pre></body></html>"
            : "\r\n執行訊息\r\n" + report.notes);
}
} // namespace xs
