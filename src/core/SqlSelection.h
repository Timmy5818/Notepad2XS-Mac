#pragma once
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
namespace xs {
struct SqlInputError : std::runtime_error {
  std::u16string message;
  explicit SqlInputError(std::u16string text)
      : std::runtime_error("invalid SQL selection"), message(std::move(text)) {}
};
struct SqlSelection {
  std::u16string dsn, statement;
};
struct WqlSelection {
  std::u16string nameSpace = u"ROOT\\CIMV2";
  std::u16string statement;
};
struct FtpSelection {
  // Passwords are deliberately removed before passing the URI to Explorer.
  std::u16string url;
  bool passwordProvided = false;
};
struct SshSelection {
  std::u16string username;
  std::u16string host; // IPv6 literals retain their surrounding brackets.
  unsigned short port = 22;
  std::u16string remoteDirectory; // Empty means use the remote login directory.
  bool passwordProvided = false; // Password is never retained or passed to ssh.exe.
};
enum class WqlQueryKind {
  Data,
  Schema,
  Association,
  AssociationSchema,
  Event,
  Unsupported
};
struct WqlProjection {
  std::u16string className;
  bool allProperties = false;
  std::vector<std::u16string> properties;
};
// WQL is executed through the native WMI COM API, not WMIC.exe.
std::optional<WqlSelection> parseWqlSelection(const std::u16string &text);
WqlQueryKind classifyWqlQuery(const std::u16string &statement);
// Extracts the single class and projection used by SELECT. This metadata lets
// WQL show its column headings even when the query returns zero instances.
std::optional<WqlProjection> parseWqlProjection(const std::u16string &statement);
// DOSCMD returns only the UTF-8/CRLF user BAT body; the common outer runner
// owns the console status line and Enter wait. Other markers return nullopt.
std::optional<std::string> selectedDosBatch(const std::u16string &text);
std::u16string dosCommandLine(const std::u16string &systemCmd);
// PSCMD keeps the script body intact (including top-level param/using).
// The launcher, not the user's PS1, supplies the final Read-Host.
std::optional<std::string> selectedPowerShell(const std::u16string &text);
// Windows Script Host source is written as UTF-16LE with a BOM.
std::optional<std::string> selectedJavaScript(const std::u16string &text);
std::optional<std::string> selectedVBScript(const std::u16string &text);
std::u16string selectedUrl(const std::u16string &text);
std::optional<FtpSelection> selectedFtpUrl(const std::u16string &text);
std::optional<SshSelection> selectedSshUrl(const std::u16string &text);
// Only absolute drive paths and ordinary UNC paths are classified. File type
// and existence are resolved by the Windows launcher using GetFileAttributesW.
std::optional<std::u16string> selectedWindowsPath(const std::u16string &text);
std::u16string quoteWindowsArgument(const std::u16string &text);
SqlSelection parseSqlSelection(const std::u16string &text);
// Lexical warning only: ignores quoted text/comments and nested query WHEREs.
bool sqlNeedsWhereConfirmation(const std::u16string &statement);
std::string sqlUtf8(const std::u16string &text);
std::string sqlCell(const std::u16string &text);
} // namespace xs
