#pragma once
#include <algorithm>
#include <cstddef>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace xs { namespace csv {
// Preview limits bound both parsing time and native control/memory use. A
// limit error rejects the whole preview; never silently show partial data.
constexpr std::size_t maxInputBytes = 16 * 1024 * 1024;
struct Limits {
  std::size_t rows = 100000, columns = 256, cells = 1000000;
  std::size_t fieldUnits = 1024 * 1024;
};
enum class ErrorKind { Syntax, Limit, Nul };
struct ParseError : std::runtime_error {
  ErrorKind kind;
  std::size_t row, column;
  ParseError(ErrorKind value, std::size_t r, std::size_t c)
      : std::runtime_error("CSV preview parse error"), kind(value), row(r), column(c) {}
};
struct Cell {
  std::size_t offset, length;
  // Exact token range in the decoded source, including enclosing quotes.
  std::size_t sourceOffset, sourceLength;
};
struct Table {
  std::wstring text;
  std::vector<std::vector<Cell>> rows;
  std::size_t columns = 0;
  bool uneven = false;
  std::wstring_view cell(std::size_t row, std::size_t column) const {
    if (row >= rows.size() || column >= rows[row].size()) return {};
    const auto &value = rows[row][column];
    return std::wstring_view(text).substr(value.offset, value.length);
  }
};

// The loader owns character decoding. This parser consumes decoded text and
// never converts numbers/dates, trims spaces or evaluates spreadsheet formulas.
inline Table parse(std::wstring_view input, wchar_t delimiter = L',', Limits limits = {}) {
  if (delimiter != L',' && delimiter != L'\t' && delimiter != L';')
    throw std::invalid_argument("Unsupported delimiter");
  Table table;
  std::size_t pos = !input.empty() && input.front() == L'\ufeff' ? 1 : 0;
  if (input.size() > maxInputBytes) throw ParseError(ErrorKind::Limit, 1, 1);
  std::size_t cells = 0;
  while (pos < input.size()) {
    if (table.rows.size() >= limits.rows)
      throw ParseError(ErrorKind::Limit, table.rows.size() + 1, 1);
    std::vector<Cell> row;
    bool endRow = false;
    while (!endRow) {
      const auto fail = [&](ErrorKind kind) {
        throw ParseError(kind, table.rows.size() + 1, row.size() + 1);
      };
      if (row.size() >= limits.columns || cells >= limits.cells) fail(ErrorKind::Limit);
      const auto start = table.text.size();
      const auto sourceStart = pos;
      const auto append = [&](wchar_t ch) {
        if (!ch) fail(ErrorKind::Nul);
        if (table.text.size() - start >= limits.fieldUnits) fail(ErrorKind::Limit);
        table.text.push_back(ch);
      };
      if (pos < input.size() && input[pos] == L'"') {
        ++pos;
        bool closed = false;
        while (pos < input.size()) {
          const auto ch = input[pos++];
          if (ch == L'"') {
            if (pos < input.size() && input[pos] == L'"') { ++pos; append(L'"'); }
            else { closed = true; break; }
          } else append(ch);
        }
        if (!closed) fail(ErrorKind::Syntax);
        if (pos < input.size() && input[pos] != delimiter && input[pos] != L'\r' && input[pos] != L'\n')
          fail(ErrorKind::Syntax);
      } else {
        while (pos < input.size() && input[pos] != delimiter && input[pos] != L'\r' && input[pos] != L'\n') {
          if (input[pos] == L'"') fail(ErrorKind::Syntax);
          append(input[pos++]);
        }
      }
      row.push_back({start, table.text.size() - start, sourceStart, pos - sourceStart});
      ++cells;
      if (pos < input.size() && input[pos] == delimiter) { ++pos; continue; }
      endRow = true;
      if (pos < input.size()) {
        if (input[pos++] == L'\r' && pos < input.size() && input[pos] == L'\n') ++pos;
      }
    }
    if (!table.rows.empty() && row.size() != table.rows.front().size()) table.uneven = true;
    table.columns = (std::max)(table.columns, row.size());
    table.rows.push_back(std::move(row));
  }
  return table;
}

// Copy rows as TSV using the same quote/escape convention. This is a user
// clipboard operation only; the document and its encryption state are untouched.
inline void appendField(std::wstring &out, std::wstring_view value, wchar_t delimiter) {
  const bool quote = value.empty() || value.find_first_of(std::wstring{delimiter, L'"', L'\r', L'\n'}) != std::wstring_view::npos;
  if (quote) out.push_back(L'"');
  for (const auto ch : value) {
    out.push_back(ch);
    if (quote && ch == L'"') out.push_back(L'"');
  }
  if (quote) out.push_back(L'"');
}

using Address = std::pair<std::size_t, std::size_t>;
using Changes = std::map<Address, std::wstring>;
inline std::wstring_view displayed(const Table &table, const Changes &changes, std::size_t row, std::size_t column) {
  const auto found = changes.find({row, column});
  return found == changes.end() ? table.cell(row, column) : std::wstring_view(found->second);
}
inline void stage(const Table &table, Changes &changes, std::size_t row, std::size_t column, std::wstring value) {
  if (row >= table.rows.size() || column >= table.rows[row].size())
    throw std::out_of_range("Missing CSV cell");
  if (value.size() > Limits{}.fieldUnits) throw ParseError(ErrorKind::Limit, row + 1, column + 1);
  if (value.find(L'\0') != std::wstring::npos) throw ParseError(ErrorKind::Nul, row + 1, column + 1);
  if (value == table.cell(row, column)) changes.erase({row, column});
  else changes.insert_or_assign({row, column}, std::move(value));
}
inline std::wstring withLineEndings(std::wstring_view input, std::wstring_view eol) {
  std::wstring out;
  for (std::size_t i = 0; i < input.size(); ++i) {
    if (input[i] == L'\r' || input[i] == L'\n') {
      if (input[i] == L'\r' && i + 1 < input.size() && input[i + 1] == L'\n') ++i;
      out.append(eol);
    } else out.push_back(input[i]);
  }
  return out;
}
// After an actual edit, normalize every field to quoted CSV/TSV. Record
// separators, BOM and final-newline presence remain exactly as in the source.
// A no-op or cancelled edit never normalizes the document.
inline std::wstring applyChanges(std::wstring_view source, const Table &table,
    const Changes &changes, wchar_t delimiter) {
  if (changes.empty()) return std::wstring(source);
  for (const auto &entry : changes) {
    if (entry.first.first >= table.rows.size() || entry.first.second >= table.rows[entry.first.first].size())
      throw std::out_of_range("Missing CSV cell");
  }
  std::wstring out;
  std::size_t end = 0;
  for (std::size_t row = 0; row < table.rows.size(); ++row) {
    for (std::size_t column = 0; column < table.rows[row].size(); ++column) {
      const auto &cell = table.rows[row][column];
      if (cell.sourceOffset < end || cell.sourceOffset > source.size() ||
          cell.sourceLength > source.size() - cell.sourceOffset)
        throw std::out_of_range("CSV source range");
      out.append(source.substr(end, cell.sourceOffset - end));
      const auto value = displayed(table, changes, row, column);
      out.push_back(L'"');
      for (const auto ch : value) { out.push_back(ch); if (ch == L'"') out.push_back(ch); }
      out.push_back(L'"');
      end = cell.sourceOffset + cell.sourceLength;
      if (out.size() > maxInputBytes) throw ParseError(ErrorKind::Limit, row + 1, column + 1);
    }
  }
  out.append(source.substr(end));
  if (out.size() > maxInputBytes) throw ParseError(ErrorKind::Limit, 1, 1);
  (void)parse(out, delimiter);
  return out;
}

enum class StructureKind { AddRow, InsertRow, DeleteRows, AddColumn, InsertColumn, DeleteColumn };
struct StructureAction {
  StructureKind kind;
  std::size_t index = 0;
  std::vector<std::size_t> selectedRows;
};
inline bool sameData(const Table &a, const Table &b) {
  if (a.rows.size() != b.rows.size()) return false;
  for (std::size_t r = 0; r < a.rows.size(); ++r) {
    if (a.rows[r].size() != b.rows[r].size()) return false;
    for (std::size_t c = 0; c < a.rows[r].size(); ++c) if (a.cell(r, c) != b.cell(r, c)) return false;
  }
  return true;
}
// Build a complete candidate off to the side. A failed allocation, parse or
// capacity check never modifies the caller's staged table/cell edits.
inline std::wstring restructure(std::wstring_view source, const Table &table, const Changes &changes,
    wchar_t delimiter, std::wstring_view eol, const StructureAction &action, Limits limits = {}) {
  if (eol != L"\r\n" && eol != L"\n" && eol != L"\r") throw std::invalid_argument("CSV record separator");
  using Row = std::vector<std::wstring_view>;
  std::vector<Row> rows;
  rows.reserve(table.rows.size());
  for (std::size_t r = 0; r < table.rows.size(); ++r) {
    Row row;
    row.reserve(table.rows[r].size());
    for (std::size_t c = 0; c < table.rows[r].size(); ++c) row.push_back(displayed(table, changes, r, c));
    rows.push_back(std::move(row));
  }
  const auto fail = [] { throw ParseError(ErrorKind::Limit, 1, 1); };
  auto width = table.columns;
  switch (action.kind) {
  case StructureKind::AddRow:
  case StructureKind::InsertRow: {
    const auto index = action.kind == StructureKind::AddRow ? rows.size() : action.index;
    if (index > rows.size()) throw std::out_of_range("CSV insertion row");
    width = (std::max)(std::size_t{1}, width);
    if (rows.size() >= limits.rows || width > limits.columns) fail();
    rows.insert(rows.begin() + static_cast<std::ptrdiff_t>(index), Row(width));
    break;
  }
  case StructureKind::DeleteRows: {
    if (action.selectedRows.empty()) throw std::invalid_argument("No CSV rows selected");
    std::vector<bool> remove(rows.size(), false);
    for (const auto index : action.selectedRows) {
      if (index >= rows.size()) throw std::out_of_range("CSV deletion row");
      remove[index] = true;
    }
    std::vector<Row> kept;
    kept.reserve(rows.size());
    for (std::size_t r = 0; r < rows.size(); ++r) if (!remove[r]) kept.push_back(std::move(rows[r]));
    rows = std::move(kept);
    break;
  }
  case StructureKind::AddColumn:
  case StructureKind::InsertColumn: {
    const auto index = action.kind == StructureKind::AddColumn ? width : action.index;
    if (index > width) throw std::out_of_range("CSV insertion column");
    if (width >= limits.columns) fail();
    if (rows.empty()) rows.emplace_back(width);
    if (rows.size() > limits.cells / (width + 1)) fail();
    for (auto &row : rows) {
      row.resize(width); // Fill missing cells in ragged records before inserting.
      row.insert(row.begin() + static_cast<std::ptrdiff_t>(index), std::wstring_view{});
    }
    break;
  }
  case StructureKind::DeleteColumn:
    if (action.index >= width) throw std::out_of_range("CSV deletion column");
    // CSV has no representation for a record with zero fields. Removing the
    // final column empties the table; the user can still cancel this operation.
    if (width == 1) rows.clear();
    else {
      if (rows.size() > limits.cells / (width - 1)) fail();
      for (auto &row : rows) {
        row.resize(width);
        row.erase(row.begin() + static_cast<std::ptrdiff_t>(action.index));
      }
    }
    break;
  }
  std::size_t cells = 0;
  if (rows.size() > limits.rows) fail();
  std::wstring out;
  if (!source.empty() && source.front() == L'\ufeff') out.push_back(L'\ufeff');
  for (std::size_t r = 0; r < rows.size(); ++r) {
    if (r) out.append(eol);
    if (rows[r].size() > limits.columns || rows[r].size() > limits.cells - cells) fail();
    cells += rows[r].size();
    for (std::size_t c = 0; c < rows[r].size(); ++c) {
      if (c) out.push_back(delimiter);
      if (rows[r][c].size() > limits.fieldUnits) fail();
      out.push_back(L'"');
      for (const auto ch : rows[r][c]) { out.push_back(ch); if (ch == L'"') out.push_back(ch); }
      out.push_back(L'"');
      if (out.size() > maxInputBytes) fail();
    }
  }
  if (!rows.empty() && !source.empty() && (source.back() == L'\r' || source.back() == L'\n')) out.append(eol);
  (void)parse(out, delimiter, limits);
  return out;
}
} }
