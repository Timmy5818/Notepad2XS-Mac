// 雲端 X60 檔案（R159～R166）：檔名與 UUID 規則、API 網址、欄位設定、排序、X60 結構檢查
// 規則對照 Windows 版 CloudFiles.cpp 與伺服器 notepad2xs_cloud_fils_system.php
#include "CloudCore.h"
#include "ExAlgorithms.h"
#include <cstdio>

using namespace xs::cloud;

static int fails = 0, passes = 0;
static void Check(bool ok, const char *name) {
    if (ok) { passes++; printf("  ✓ %s\n", name); } else { fails++; printf("  ✗ %s\n", name); }
}

int main() {
    // 檔名
    Check(validName(u"工作筆記") && validName(u"notes.v2") && validName(u"a"), "一般檔名可用");
    bool badOk = true;
    for (const char16_t *bad : {u"", u".hidden", u"end.", u" lead", u"trail ", u"x.x60", u"X.X60", u"a/b", u"a\\b", u"a:b",
                                u"a\"b", u"a<b", u"a>b", u"a|b", u"a?b", u"a*b", u"tab\tname", u"CON", u"con.txt", u"PRN",
                                u"AUX", u"NUL", u"COM1", u"lpt9.log"})
        if (validName(bad)) badOk = false;
    Check(badOk, "拒絕保留名稱、特殊字元、.x60 副檔名與前後空白／句點");
    Check(validName(u"COM0") && validName(u"COM10") && validName(u"CONSOLE"), "只拒絕完全相同的保留名稱");
    Check(validName(std::u16string(240, u'a')) && !validName(std::u16string(241, u'a')), "最多 240 字元");
    Check(validName(std::u16string(80, u'中')) && !validName(std::u16string(81, u'中')), "UTF-8 最多 240 位元組（中文 80 字）");
    Check(!validName(u"\xD800x"), "拒絕不成對的代理字元");

    // UUID 與版本
    Check(validId("0f8fad5b-d9cb-469f-a165-70867728950e"), "合法 UUID");
    Check(!validId("0F8FAD5B-D9CB-469F-A165-70867728950E") && !validId("0f8fad5bd9cb469fa16570867728950e") && !validId("root"),
          "UUID 需為小寫、含連字號");
    Check(validFolder("root") && validFolder("0f8fad5b-d9cb-469f-a165-70867728950e") && !validFolder(""), "資料夾：root 或 UUID");
    Check(validRevision(std::string(40, 'a')) && !validRevision(std::string(39, 'a')) && !validRevision(std::string(40, 'A')),
          "版本為 40 個小寫十六進位字元");

    // API 網址
    auto e = endpoint("  http://127.0.0.1/exes/  ");
    Check(e.ok && e.base == "http://127.0.0.1/exes/" && e.api == "http://127.0.0.1/exes/notepad2xs_cloud_fils_system.php" && e.port == 80,
          "資料夾網址自動補上 PHP 檔名");
    e = endpoint("https://example.org:8443/a/b///");
    Check(e.ok && e.api == "https://example.org:8443/a/b/notepad2xs_cloud_fils_system.php" && e.port == 8443 && e.host == "example.org",
          "HTTPS 與自訂連接埠，多餘的斜線去掉");
    e = endpoint("http://[::1]:8080");
    Check(e.ok && e.host == "::1" && e.api == "http://[::1]:8080/notepad2xs_cloud_fils_system.php", "IPv6 位址");
    bool rejectOk = true;
    for (const char *bad : {"", "   ", "ftp://x/", "example.org/exes", "http://user:pw@x/", "http://x/a.php", "http://x/A.PHP",
                            "http://x/?a=1", "http://x/#f", "http://x/a b", "http:///path", "http://x:99999/", "http://x:/"})
        if (endpoint(bad).ok) rejectOk = false;
    Check(rejectOk, "拒絕非 HTTP、帳密、.php、查詢字串、空白與錯誤連接埠");

    Check(encode("工作 筆記") == "%E5%B7%A5%E4%BD%9C%20%E7%AD%86%E8%A8%98" && encode("a-b_c.d~") == "a-b_c.d~", "百分比編碼");

    // 欄位設定（[Cloud] FileColumns*）
    auto s = readColumnSettings(-1, "", "", 3, 0);
    Check(s.visible == 0x0f && s.order == std::array<int, 6>{0, 1, 2, 3, 4, 5} && s.widths == defaultColumnWidths && s.sort == 3 && !s.ascending,
          "預設：名稱、類型、大小、修改時間，依修改時間遞減");
    s = readColumnSettings(0x30, "5,4,3,2,1,0", "10,2000,100,100,100,100", 1, 1);
    Check(s.visible == 0x31 && s.order == std::array<int, 6>{5, 4, 3, 2, 1, 0} && s.widths[0] == 32 && s.widths[1] == 1200 &&
          s.sort == 1 && s.ascending, "名稱欄一律顯示、欄寬限制在 32～1200");
    s = readColumnSettings(0xff, "0,1,1,3,4,5", "1,2,3", 9, 0);
    Check(s.visible == 0x3f && s.order == std::array<int, 6>{0, 1, 2, 3, 4, 5} && s.widths == defaultColumnWidths && s.sort == 3,
          "重複的順序、數量不對的寬度、不存在的排序欄都改回預設");
    std::array<int, 6> list{};
    Check(parseIntegerList("1,2,3,4,5,6 ", list) && !parseIntegerList("1,2,3,4,5", list) && !parseIntegerList("1,2,3,4,5,x", list) &&
          !parseIntegerList("1,2,3,4,5,6,7", list), "整數清單解析");
    Check(integerList(std::array<int, 6>{0, 1, 2, 3, 4, 5}) == "0,1,2,3,4,5", "整數清單輸出");

    ColumnSettings sort;
    clickSort(sort, 3);
    Check(sort.sort == 3 && sort.ascending, "再點同一欄反轉方向");
    clickSort(sort, 0);
    Check(sort.sort == 0 && sort.ascending, "換到文字欄：預設遞增");
    clickSort(sort, 2);
    Check(sort.sort == 2 && !sort.ascending, "換到大小欄：預設遞減");
    Check(std::string(serverSort(0)) == "file" && std::string(serverSort(2)) == "size" && std::string(serverSort(3)) == "date" &&
          std::string(serverSort(4)) == "file", "伺服器排序提示只有 file／date／size");

    Check(formatFileSize(0) == "0 B" && formatFileSize(1023) == "1023 B" && formatFileSize(1024) == "1.0 KB" &&
          formatFileSize(1536) == "1.5 KB" && formatFileSize(5ull * 1024 * 1024) == "5.0 MB", "檔案大小顯示");

    // X60 結構（與 PHP nx_is_x60 相同的檢查）
    std::string cipher = xs::exesEncrypt("雲端測試", "pw");
    Check(xs::validX60Envelope(cipher), "EXES 密文通過 X60 結構檢查");
    Check(!xs::validX60Envelope(cipher.substr(0, cipher.size() - 5)) && !xs::validX60Envelope("X60" + std::string(199, '0')) &&
          !xs::validX60Envelope("Y60" + cipher.substr(3)) && !xs::validX60Envelope(cipher + "0"), "截斷、長度錯誤、開頭錯誤都拒絕");
    std::string broken = cipher;
    broken[100] = '!';
    Check(!xs::validX60Envelope(broken), "非 Base62 字元拒絕");

    printf(fails ? "失敗 %d 項\n" : "全部通過（%d 項）\n", fails ? fails : passes);
    return fails ? 1 : 0;
}
