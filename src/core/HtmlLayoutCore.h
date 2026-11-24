#pragma once
#include <string>
#include <string_view>
#include <vector>

namespace xs::html {

constexpr size_t limit = 4u * 1024u * 1024u; // UTF-16 units in the layout view
struct Block {
  size_t first, last;
  bool inlineOnly, inlineRun;
  std::wstring html;
};
struct Piece {
  size_t block;
  std::wstring tag; // Nonempty for a protected piece.
};
struct Layout {
  std::vector<Block> blocks;
  std::vector<Piece> pieces;
};
Layout project(std::wstring_view source);
std::wstring safeFragment(std::wstring_view html, bool inlineOnly);
std::wstring merge(std::wstring_view source, const Layout& layout,
                   const std::vector<std::wstring>& initial, const std::vector<std::wstring>& edited);
std::wstring table(unsigned rows, unsigned columns);
std::wstring escapeText(std::wstring_view text);

} // namespace xs::html
