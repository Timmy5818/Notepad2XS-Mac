#pragma once
#include "ExAlgorithms.h"
#include "BookmarkMarker.h"
#include <algorithm>
#include <charconv>
#include <climits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

namespace xs::bookmarks {
constexpr std::size_t fileLimit = 1024u * 1024u;
constexpr std::string_view header = "[Bookmarks]\r\nVersion=1\r\nLines=";
constexpr std::string_view colorHeader = "[Bookmarks]\r\nVersion=2\r\nLines=";
constexpr std::string_view viewHeader = "[View]\r\n";
constexpr int zoomLimit = 100;

struct LineBookmark {
  int line;
  bool red = false;

  bool operator==(const LineBookmark& other) const {
    return line == other.line && red == other.red;
  }
};

struct ViewState {
  int topLine = 0;
  int wrappedLine = 0;
  int horizontalOffset = 0;
  int caretLine = 0;
  int caretColumn = 0;
  int zoom = 0;

  bool operator==(const ViewState& other) const {
    return std::tie(topLine, wrappedLine, horizontalOffset, caretLine, caretColumn, zoom) ==
           std::tie(other.topLine, other.wrappedLine, other.horizontalOffset,
                    other.caretLine, other.caretColumn, other.zoom);
  }
  bool operator!=(const ViewState& other) const { return !(*this == other); }
};

inline constexpr struct ViewField {
  std::string_view key;
  int ViewState::*value;
} viewFields[] = {
  {"TopLine=", &ViewState::topLine}, {"WrappedLine=", &ViewState::wrappedLine},
  {"HorizontalOffset=", &ViewState::horizontalOffset}, {"CaretLine=", &ViewState::caretLine},
  {"CaretColumn=", &ViewState::caretColumn}, {"Zoom=", &ViewState::zoom},
};

inline std::string sidecarName(const std::u16string& name) {
  return xs::exmd3(name) + ".ini";
}

inline std::string serialize(const std::vector<LineBookmark>& lines,
                             const std::optional<ViewState>& view = std::nullopt) {
  const bool hasRed = std::any_of(lines.begin(), lines.end(),
                                [](const LineBookmark& bookmark) { return bookmark.red; });
  std::string result(hasRed ? colorHeader : header);
  int previous = 0;
  for (const auto& bookmark : lines) {
    if (bookmark.line <= previous)
      throw std::invalid_argument("bookmark list order");
    if (previous)
      result += ',';
    result += std::to_string(bookmark.line);
    if (bookmark.red)
      result += 'r';
    previous = bookmark.line;
    if (result.size() > fileLimit - 2)
      throw std::length_error("bookmark list too large");
  }
  result += "\r\n";
  if (view) {
    result += viewHeader;
    for (const auto& field : viewFields) {
      result += field.key;
      result += std::to_string((*view).*field.value);
      result += "\r\n";
    }
    if (result.size() > fileLimit)
      throw std::length_error("document state file too large");
  }
  return result;
}

inline std::optional<ViewState> parseView(std::string_view input) {
  ViewState view;
  for (const auto& field : viewFields) {
    const auto end = input.find("\r\n");
    if (end == std::string_view::npos || input.substr(0, field.key.size()) != field.key ||
        end <= field.key.size())
      return std::nullopt;
    auto& value = view.*field.value;
    const auto parsed = std::from_chars(input.data() + field.key.size(), input.data() + end, value);
    if (parsed.ec != std::errc{} || parsed.ptr != input.data() + end ||
        (field.value != &ViewState::zoom && value < 0))
      return std::nullopt;
    input.remove_prefix(end + 2);
  }
  if (!input.empty() || view.zoom < -zoomLimit || view.zoom > zoomLimit)
    return std::nullopt;
  return view;
}

inline bool parse(std::string_view input, std::vector<LineBookmark>& output,
                  std::optional<ViewState>* view = nullptr) {
  if (input.size() > fileLimit)
    return false;
  std::optional<ViewState> parsedView;
  const auto section = input.find(viewHeader);
  if (section != std::string_view::npos && section >= 2 &&
      input.substr(section - 2, 2) == "\r\n") {
    parsedView = parseView(input.substr(section + viewHeader.size()));
    input = input.substr(0, section);
  }
  const bool hasColor = input.substr(0, colorHeader.size()) == colorHeader;
  const auto prefix = hasColor ? colorHeader : header;
  if (input.size() < prefix.size() + 2 || input.substr(0, prefix.size()) != prefix ||
      input.substr(input.size() - 2) != "\r\n")
    return false;
  input.remove_prefix(prefix.size());
  input.remove_suffix(2);
  std::vector<LineBookmark> lines;
  int previous = 0;
  while (!input.empty()) {
    int number = 0;
    const auto end = input.data() + input.size();
    const auto parsed = std::from_chars(input.data(), end, number);
    if (parsed.ec != std::errc{} || number <= previous)
      return false;
    auto cursor = parsed.ptr;
    const bool red = hasColor && cursor != end && *cursor == 'r';
    if (red)
      ++cursor;
    lines.push_back({number, red});
    previous = number;
    if (cursor == end)
      break;
    if (*cursor != ',' || cursor + 1 == end)
      return false;
    input.remove_prefix(static_cast<std::size_t>(cursor + 1 - input.data()));
  }
  output.swap(lines);
  if (view)
    *view = parsedView;
  return true;
}
}
