#pragma once
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>
namespace xs {
enum class SqlCellKind { Text, Null, Binary };
struct SqlCell {
  SqlCellKind kind = SqlCellKind::Text;
  std::u16string text;
};
enum class SqlResultStatus { Failed, Success, Cancelled, Truncated };
struct SqlResultSet {
  bool table = true;
  std::vector<std::u16string> columns;
  std::vector<std::vector<SqlCell>> rows;
  std::optional<std::int64_t> affected;
};
struct SqlReport {
  // Shared by ODBC SQL and WMI/WQL reports. Defaults preserve the SQL UI.
  std::u16string title = u"SQL結果顯示";
  std::u16string sourceLabel = u"資料來源";
  std::u16string exportPrefix = u"sql";
  std::u16string dsn, started;
  std::string notes;
  std::vector<SqlResultSet> sets;
  SqlResultStatus status = SqlResultStatus::Failed;
  bool submitted = false, executed = false;
  std::uint64_t rowCount = 0;
  std::int64_t elapsedMs = 0;
  std::size_t storage = 0;
  static constexpr std::size_t maxStorage = 20 * 1024 * 1024;
  bool beginTable(const std::vector<std::u16string> &columns);
  bool appendRow(std::vector<SqlCell> row);
  bool addAffected(std::optional<std::int64_t> count);
};
std::string sqlResultCell(const SqlCell &cell);
std::u16string sqlDisplayCell(const SqlCell &cell, bool preview);
const char *sqlStatusName(SqlResultStatus status);
using SqlResultSink = std::function<void(const std::string &)>;
// Stream the whole report; no file or browser operation is performed here.
void exportSqlReport(const SqlReport &report, bool html, const SqlResultSink &sink);
void copySqlRows(const SqlResultSet &set, const std::vector<std::size_t> &indices,
                 const SqlResultSink &sink);
} // namespace xs
