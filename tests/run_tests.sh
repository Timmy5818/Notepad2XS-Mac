#!/bin/bash
# 單元測試：編碼、文字轉換、加解密（含原版向量與 CryptoKit 交叉驗證）、F5、壓縮檔編輯、字串轉換
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"; mkdir -p "$OUT"
C="$ROOT/src/core"
CXX=(clang++ -arch x86_64 -std=c++17 -O2 -fobjc-arc -I"$ROOT/src" -I"$C" -I"$ROOT/vendor/scintilla3112/include")
set -e
"${CXX[@]}" "$ROOT/tests/test_encoding.mm" "$ROOT/src/TextEncoding.mm" -framework Foundation -liconv -o "$OUT/test_encoding"
"${CXX[@]}" "$ROOT/tests/test_transforms.mm" "$ROOT/src/TextTransforms.mm" -framework Foundation -o "$OUT/test_transforms"
"${CXX[@]}" "$ROOT/tests/test_crypto.mm" "$C/ExAlgorithms.cpp" "$C/AesAlgorithms.cpp" -framework Foundation -framework Security -o "$OUT/test_crypto"
clang -arch x86_64 -O2 -w -c "$C/tinyexpr.c" -o "$OUT/tinyexpr.o"
"${CXX[@]}" "$ROOT/tests/test_f5.mm" "$ROOT/src/ExecuteCore.mm" "$C/MathSelection.cpp" "$C/SqlSelection.cpp" "$OUT/tinyexpr.o" -framework Foundation -o "$OUT/test_f5"
"${CXX[@]}" -DXS_AES_TESTING "$ROOT/tests/test_aes_kat.mm" "$C/AesAlgorithms.cpp" -framework Security -o "$OUT/test_aes_kat"
"${CXX[@]}" "$ROOT/tests/test_archive.mm" "$ROOT/src/ArchiveEdit.mm" -framework Cocoa -lz -o "$OUT/test_archive"
"${CXX[@]}" "$ROOT/tests/test_strings.mm" -framework Foundation -o "$OUT/test_strings"
"${CXX[@]}" "$ROOT/tests/test_filesearch.cpp" -o "$OUT/test_filesearch"
"${CXX[@]}" "$ROOT/tests/test_htmllayout.cpp" "$C/HtmlLayoutCore.cpp" -o "$OUT/test_htmllayout"
"${CXX[@]}" "$ROOT/tests/test_cloud.cpp" "$C/ExAlgorithms.cpp" -o "$OUT/test_cloud"
"${CXX[@]}" "$ROOT/tests/test_image.mm" "$C/ImageCommentFormat.cpp" "$C/JpegCommentFormat.cpp" -framework Foundation -framework ImageIO -framework CoreGraphics -o "$OUT/test_image"
SCI="$ROOT/vendor/scintilla3112"
[ -f "$ROOT/build/libscintilla.a" ] || ARCHFLAGS="-arch x86_64" "$ROOT/scripts/build_scintilla.sh" >/dev/null
"${CXX[@]}" -DSCI_LEXER -I"$SCI/cocoa" -I"$SCI/src" -I"$ROOT/vendor/boost" "$ROOT/tests/test_navigation.mm" "$ROOT/src/BookmarkStore.mm" "$C/ExAlgorithms.cpp" \
  "$ROOT/build/libscintilla.a" -framework Cocoa -framework QuartzCore -o "$OUT/test_navigation"
set +e
rc=0
echo "== 編碼 =="; "$OUT/test_encoding" | tail -1 || rc=1
echo "== 文字轉換 =="; "$OUT/test_transforms" | grep -E "✗|通過|失敗" || rc=1
echo "== 加解密 =="; "$OUT/test_aes_kat" | grep -E "✗" ; "$OUT/test_aes_kat" >/dev/null || rc=1
"$OUT/test_crypto" "$ROOT/tests/vectors/XSExesKdfVectors.json" "$OUT/aes_cross.json" | grep -E "✗|通過|失敗" || rc=1
swift "$ROOT/tests/verify_gcm.swift" "$OUT/aes_cross.json" | grep -E "✗" ; swift "$ROOT/tests/verify_gcm.swift" "$OUT/aes_cross.json" >/dev/null || rc=1
echo "== F5 執行選取 =="; "$OUT/test_f5" | grep -E "✗|通過|失敗" || rc=1
echo "== 壓縮檔編輯 =="; "$OUT/test_archive" | grep -E "✗|通過|失敗" || rc=1
echo "== 字串轉換 =="; "$OUT/test_strings" | grep -E "✗|通過|失敗" || rc=1
echo "== 檔案搜尋條件 =="; "$OUT/test_filesearch" | grep -E "✗|通過|失敗" || rc=1
echo "== 排版模式核心 =="; "$OUT/test_htmllayout" | grep -E "PASS|✗" || rc=1
echo "== 圖片內嵌文字 =="; "$OUT/test_image" "$ROOT/resources" | grep -E "✗|通過|失敗" || rc=1
echo "== 雲端檔案 =="; "$OUT/test_cloud" | grep -E "✗|通過|失敗" || rc=1
echo "== JSON 與書籤 =="; "$OUT/test_navigation" | grep -E "✗|通過|失敗" || rc=1
[ $rc = 0 ] && echo "全部測試通過" || echo "有測試失敗"
exit $rc
