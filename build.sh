#!/bin/bash
# 一鍵建置 Notepad2XS.app（預設 x86_64）
#   ./build.sh            建置
#   ./build.sh clean      清除建置產物
#   ./build.sh dmg        建置後打包成 build/Notepad2XS.dmg
#   ARCH=x86_64 ./build.sh 只編 Intel 版（預設同時編 x86_64 與 arm64）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCI="$ROOT/vendor/scintilla3112"
ARCH="${ARCH:-x86_64 arm64}"   # 預設 Universal Binary；ARCH=x86_64 ./build.sh 只編 Intel 版
ARCHFLAGS=""; for a in $ARCH; do ARCHFLAGS="$ARCHFLAGS -arch $a"; done
MINOS="${MINOS:-11.0}"
BUILD="$ROOT/build"
APP="$BUILD/Notepad2XS.app"

if [[ "${1:-}" == "clean" ]]; then rm -rf "$BUILD"; echo "已清除 $BUILD"; exit 0; fi

if [[ ! -d "$SCI/cocoa" ]]; then
  echo "找不到 Scintilla 3.11.2，正在下載…"
  mkdir -p "$ROOT/vendor"
  curl -fsSL -o "$ROOT/vendor/scintilla3112.tgz" \
    "https://sourceforge.net/projects/scintilla/files/scintilla/3.11.2/scintilla3112.tgz/download"
  tar xzf "$ROOT/vendor/scintilla3112.tgz" -C "$ROOT/vendor"
fi

ARCHFLAGS="$ARCHFLAGS" MINOS="$MINOS" "$ROOT/scripts/build_scintilla.sh"

OBJ="$BUILD/app"
mkdir -p "$OBJ"
FLAGS=($ARCHFLAGS -mmacosx-version-min="$MINOS" -std=c++17 -O2 -g -fobjc-arc -DSCI_LEXER
  -I"$SCI/include" -I"$SCI/src" -I"$SCI/lexlib" -I"$SCI/cocoa" -I"$ROOT/src" -I"$ROOT/src/core"
  -Wall -Wno-unused-function -Wno-deprecated-declarations)

OBJS=()
# 原版 NotePad2-XS 的加密核心（C++，含 Apple 後端）
for src in "$ROOT"/src/core/*.cpp; do
  obj="$OBJ/core_$(basename "$src").o"
  clang++ $ARCHFLAGS -mmacosx-version-min="$MINOS" -std=c++17 -O2 -g -I"$ROOT/src/core" -I"$ROOT/vendor/boost" -Wall -c "$src" -o "$obj"
  OBJS+=("$obj")
done
for src in "$ROOT"/src/core/*.c; do
  obj="$OBJ/core_$(basename "$src").o"
  clang $ARCHFLAGS -mmacosx-version-min="$MINOS" -O2 -g -w -c "$src" -o "$obj"
  OBJS+=("$obj")
done
for src in "$ROOT"/src/*.mm; do
  obj="$OBJ/$(basename "$src").o"
  clang++ "${FLAGS[@]}" -c "$src" -o "$obj"
  OBJS+=("$obj")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh_TW.lproj"
clang++ $ARCHFLAGS -mmacosx-version-min="$MINOS" "${OBJS[@]}" "$BUILD/libscintilla.a" \
  -framework Cocoa -framework QuartzCore -framework Carbon -framework Security -liconv -lz \
  -o "$APP/Contents/MacOS/Notepad2XS"

cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
# Scintilla 需要的游標圖（它找 .tiff）
for n in mac_cursor_busy mac_cursor_flipped info_bar_bg; do
  tiffutil -cathidpicheck "$SCI/cocoa/res/$n.png" "$SCI/cocoa/res/$n@2x.png" \
    -out "$APP/Contents/Resources/$n.tiff" >/dev/null 2>&1
done
# 8 種語言：讓系統的開啟／儲存等視窗也以對應語言顯示
for l in zh_TW en ja zh_CN ko fr de ru; do
  mkdir -p "$APP/Contents/Resources/$l.lproj"
  echo '"CFBundleName" = "Notepad2XS";' > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"
done
cp "$ROOT/resources/JpegDefaultArtwork.jpg" "$ROOT/resources/AppIcon.icns" "$APP/Contents/Resources/"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "OK: ${APP}（$(lipo -archs "$APP/Contents/MacOS/Notepad2XS")）"

# 打包 DMG：./build.sh dmg
if [[ "${1:-}" == "dmg" ]]; then
  STAGE="$BUILD/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$BUILD/Notepad2XS.dmg"
  hdiutil create -volname "Notepad2XS" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/Notepad2XS.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "OK: $BUILD/Notepad2XS.dmg"
fi
