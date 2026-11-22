#!/bin/bash
# 編譯 Scintilla 3.11.2（Cocoa）成靜態函式庫 build/libscintilla.a
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCI="$ROOT/vendor/scintilla3112"
ARCHFLAGS="${ARCHFLAGS:--arch x86_64}"
OUT="$ROOT/build/scintilla$(echo $ARCHFLAGS | tr -d ' -' | sed s/arch/_/g)"
MINOS="${MINOS:-11.0}"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$OUT"

FLAGS="$ARCHFLAGS -mmacosx-version-min=$MINOS -std=c++17 -O2 -DNDEBUG -DSCI_LEXER \
-I$SCI/include -I$SCI/src -I$SCI/lexlib -I$SCI/cocoa -w"

# 每個檔案：比 .o 新才重編；.mm 用手動記憶體管理（Scintilla 3.x 不支援 ARC）
ls "$SCI"/src/*.cxx "$SCI"/lexlib/*.cxx "$SCI"/lexers/*.cxx \
   "$SCI"/cocoa/PlatCocoa.mm "$SCI"/cocoa/ScintillaCocoa.mm "$SCI"/cocoa/ScintillaView.mm "$SCI"/cocoa/InfoBar.mm |
  OUT="$OUT" FLAGS="$FLAGS" xargs -n1 -P "$JOBS" sh -c '
    src="$1"; obj="$OUT/$(basename "$src").o"
    [ "$obj" -nt "$src" ] && exit 0
    case "$src" in *.mm) extra="-fno-objc-arc";; *) extra="";; esac
    clang++ $FLAGS $extra -c "$src" -o "$obj" || { echo "FAILED: $src" >&2; exit 255; }
  ' _

rm -f "$ROOT/build/libscintilla.a"
libtool -static -o "$ROOT/build/libscintilla.a" "$OUT"/*.o
echo "OK: $ROOT/build/libscintilla.a"
