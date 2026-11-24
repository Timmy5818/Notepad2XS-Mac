#pragma once

// Scintilla draws markers in numeric order. Draw manual circles over search marks.
enum { XS_SEARCH_BOOKMARK = 21, XS_BLUE_BOOKMARK = 22, XS_RED_BOOKMARK = 23 };
enum {
  XS_BLUE_BOOKMARK_MASK = 1u << XS_BLUE_BOOKMARK,
  XS_RED_BOOKMARK_MASK = 1u << XS_RED_BOOKMARK,
  XS_MANUAL_BOOKMARK_MASK = XS_BLUE_BOOKMARK_MASK | XS_RED_BOOKMARK_MASK
};
