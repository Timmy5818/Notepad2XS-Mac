// R137 JSON 工具、R138～R141 書籤檔格式、.2xs 書籤設定檔（實際 Scintilla 編輯區）
// JSON 與書籤格式的測試案例取自 Windows 版 XSJsonFormatTests.cpp／XSR138BookmarksTests.cpp
#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"
#import "BookmarkStore.h"
#include "JsonFormatCore.h"
#include "BookmarkFile.h"
#include <cassert>
#include <climits>
#include <iostream>
#include <sys/stat.h>

#undef NDEBUG
using xs::json::format;
using xs::json::Error;
using xs::json::ErrorKind;

static int fails = 0, passes = 0;
static void Check(bool ok, const char *name) {
    if (ok) { passes++; printf("  ✓ %s\n", name); } else { fails++; printf("  ✗ %s\n", name); }
}

static void rejects(std::wstring_view input, ErrorKind kind, std::size_t position = std::wstring_view::npos) {
  try {
    (void)format(input, true, L"\n");
  } catch (const Error& error) {
    assert(error.kind == kind);
    assert(position == std::wstring_view::npos || error.position == position);
    return;
  }
  throw std::runtime_error("accepted invalid JSON");
}

static void WindowsJsonTests() {
  const std::wstring exact = LR"({"z":-0,"a":1.000E+000,"z":[true,null,{},[],{"text":" 中文 😀 \u0061 \/ \\ \" "}],"huge":12345678901234567890,"tiny":1e-400})";
  const std::wstring out = format(exact, true, L"\r\n");
  assert(out.find(L"\r\n  \"z\": -0,") != std::wstring::npos);
  assert(out.find(L"\r\n      \"text\":") != std::wstring::npos);
  assert(format(out, false, L"\n") == exact);
  assert(format(out, true, L"\r\n") == out);
  assert(format(L" [1, 2] \r\n", false, L"\r\n") == L"[1,2]\r\n");
  assert(format(L" [ 1, 2 ]\r", true, L"\r") == L"[\r  1,\r  2\r]\r");
  assert(format(L" true \t", false, L"\n") == L"true");
  assert(format(LR"("token with spaces \uD800 \b\f\n\r\t")", true, L"\n") ==
         LR"("token with spaces \uD800 \b\f\n\r\t")");
  assert(format(LR"(["[" , "]", "a  b", "a:b", "a,b",{}])", false, L"\n") ==
         LR"(["[","]","a  b","a:b","a,b",{}])");

  rejects(L"", ErrorKind::syntax, 0);
  rejects(L"   ", ErrorKind::syntax, 3);
  rejects(L"{\"x\" 1}", ErrorKind::syntax, 5);
  rejects(L"{\"x\":3,}", ErrorKind::syntax, 7);
  rejects(L"[1,  ]", ErrorKind::syntax, 5);
  rejects(L"[01]", ErrorKind::syntax, 2);
  rejects(L"3e+", ErrorKind::syntax, 3);
  rejects(L"5.", ErrorKind::syntax, 2);
  rejects(L"-", ErrorKind::syntax, 1);
  rejects(L"\"\\uQ000\"", ErrorKind::syntax, 3);
  rejects(L"\"x\ny\"", ErrorKind::syntax, 2);
  rejects(L"\"not closed", ErrorKind::syntax, 11);
  rejects(L"\ftrue", ErrorKind::syntax, 0);
  rejects(L"true false", ErrorKind::syntax, 5);
  rejects(L"[// comment\n1]", ErrorKind::syntax, 1);
  rejects(std::wstring(L"true\0", 5), ErrorKind::syntax, 4);

  const auto depth = xs::json::depthLimit;
  const auto maximum = std::wstring(depth, L'[') + L"0" + std::wstring(depth, L']');
  assert(format(maximum, false, L"\n") == maximum);
  rejects(L"[" + maximum + L"]", ErrorKind::limit, depth);
  rejects(std::wstring(xs::json::textLimit + 1, L' '), ErrorKind::limit, 0);

  std::wstring many = std::wstring(depth, L'[');
  for (int i = 0; i < 34000; ++i)
    many += L"0,";
  many += L"1" + std::wstring(depth, L']');
  rejects(many, ErrorKind::limit);
  assert(format(many, false, L"\n") == many);
}

static bool RejectsUtf8(std::string_view input, size_t position) {
    try { (void)xs::json::formatUtf8(input, true, "\n"); }
    catch (const Error &e) { return e.kind == ErrorKind::syntax && e.position == position; }
    return false;
}

static sptr_t S(ScintillaView *v, unsigned int m, uptr_t w = 0, sptr_t l = 0) { return [v message:m wParam:w lParam:l]; }

static ScintillaView *Editor(const char *text) {
    ScintillaView *v = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    S(v, SCI_SETCODEPAGE, SC_CP_UTF8);
    S(v, SCI_SETTEXT, 0, (sptr_t)text);
    return v;
}

static unsigned Marks(ScintillaView *v, int line) { return (unsigned)S(v, SCI_MARKERGET, line) & N2BookmarkMask; }

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        printf("== JSON（Windows 版測試案例）==\n");
        bool windowsOk = true;
        try { WindowsJsonTests(); } catch (...) { windowsOk = false; }
        Check(windowsOk, "格式化／壓縮、保留原寫法、錯誤位置、換行、深度與大小上限");

        printf("== JSON（UTF-8，Mac 版編輯區使用的格式）==\n");
        std::string in = "{\"名稱\":\"中文 😀\",\"a\":[1,2,{\"b\":null}],\"e\":\"\\u0041\"}";
        std::string pretty = xs::json::formatUtf8(in, true, "\n");
        Check(pretty == "{\n  \"名稱\": \"中文 😀\",\n  \"a\": [\n    1,\n    2,\n    {\n      \"b\": null\n    }\n  ],\n  \"e\": \"\\u0041\"\n}",
              "格式化：兩個空格縮排，中文與表情符號原樣保留");
        Check(xs::json::formatUtf8(pretty, false, "\n") == in, "壓縮後與原文相同");
        Check(xs::json::formatUtf8("[1]\r\n", true, "\r\n") == "[\r\n  1\r\n]\r\n", "沿用 CRLF 並保留結尾換行");
        Check(RejectsUtf8("{\"中\":1,}", 9), "錯誤位置以位元組計算（中文佔 3 個位元組）");
        Check(RejectsUtf8("\"\x01\"", 1), "字串內的控制字元是錯誤");

        printf("== 書籤檔格式（Windows 版測試案例）==\n");
        using namespace xs::bookmarks;
        const auto key = sidecarName(u"ex_md3.txt");
        Check(key.size() == 213 && key == xs::exmd3(u"ex_md3.txt") + ".ini", "檔名＝EX_MD3(檔名).ini（209＋4 字元）");
        Check(sidecarName(u"測試.txt") != sidecarName(u"測試.md"), "副檔名不同，設定檔不同");
        std::vector<LineBookmark> numbers{{99}};
        const std::vector<LineBookmark> mixed{{1}, {6, true}};
        Check(parse(serialize({{1}, {4}, {INT_MAX}}), numbers) && numbers == std::vector<LineBookmark>({{1}, {4}, {INT_MAX}}), "讀寫一般書籤");
        bool invalidOk = true;
        for (const auto *invalid : {"1,", "0", "1,1", "4,2", "2147483648", "abc", "1, 2", "1r"})
            if (parse(std::string(header) + invalid + "\r\n", numbers) || numbers.size() != 3) invalidOk = false;
        Check(invalidOk, "拒絕格式錯誤的書籤，原資料不變");
        Check(serialize(mixed) == std::string(colorHeader) + "1,6r\r\n", "有紅色書籤時使用 Version=2");
        std::optional<ViewState> parsedView;
        const ViewState reading{3, 0, 125, 4, 9, -2};
        Check(parse(serialize(mixed, reading), numbers, &parsedView) && numbers == mixed && parsedView == reading, "書籤＋檢視狀態");
        Check(parse(serialize({{1}, {6}}) + "[View]\r\nZoom=1000\r\n", numbers, &parsedView) && !parsedView, "縮放超出範圍時忽略檢視狀態");

        printf("== .2xs 書籤設定檔（實際編輯區）==\n");
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"n2bm-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *docPath = [dir stringByAppendingPathComponent:@"工作筆記.txt"];
        [@"a\nb\nc\nd\ne\nf\ng\nh\n" writeToFile:docPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSURL *doc = [NSURL fileURLWithPath:docPath];
        ScintillaView *v = Editor("a\nb\nc\nd\ne\nf\ng\nh\n");
        N2BookmarkContext *ctx = [N2BookmarkContext new];
        [ctx loadInto:v url:doc member:nil locked:NO];
        NSString *folder = [dir stringByAppendingPathComponent:@".2xs"];
        struct stat st;
        BOOL hidden = stat(folder.fileSystemRepresentation, &st) == 0 && (st.st_flags & UF_HIDDEN);
        Check(hidden, "開檔就建立隱藏的 .2xs 資料夾");
        NSString *readme = [NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"readme.txt"] encoding:NSUTF8StringEncoding error:nil];
        NSData *readmeBytes = [NSData dataWithContentsOfFile:[[dir stringByAppendingPathComponent:@".2xs"] stringByAppendingPathComponent:@"readme.txt"]];
        BOOL ascii = readmeBytes.length > 0;
        for (NSUInteger i = 0; i < readmeBytes.length; i++) if (((const unsigned char *)readmeBytes.bytes)[i] >= 0x80) ascii = NO;
        Check(ascii && [readme hasPrefix:@"Notepad2XS Per-File Settings\r\n"] &&
              [readme containsString:@"syntax highlighting, opening encoding, and word wrap"] &&
              [readme containsString:@"Official website\r\nhttps://dz.jplopsoft.idv.tw/\r\n"] &&
              [readme containsString:@"Contact email\r\nhawl.remotek@gmail.com\r\n"], "readme.txt 是英文 ASCII 說明（R157）");
        NSURL *ini = N2BookmarkSidecarURL(doc, nil);
        NSString *expectName = [[NSString alloc] initWithUTF8String:sidecarName(u"工作筆記.txt").c_str()];
        Check([ini.lastPathComponent isEqualToString:expectName], "設定檔名稱與 Windows 版相同（EX_MD3(工作筆記.txt).ini）");
        NSString *empty = [NSString stringWithContentsOfURL:ini encoding:NSUTF8StringEncoding error:nil];
        Check([empty isEqualToString:@"[Bookmarks]\r\nVersion=1\r\nLines=\r\n"], "第一次開檔建立空白書籤檔");

        S(v, SCI_MARKERADD, 1, N2BlueBookmark);
        S(v, SCI_MARKERADD, 4, N2RedBookmark);
        S(v, SCI_MARKERADD, 6, N2SearchBookmark);   // 搜尋書籤不保存
        S(v, SCI_GOTOPOS, S(v, SCI_POSITIONFROMLINE, 3) + 1);
        Check([ctx save:v url:doc member:nil locked:NO mode:N2BookmarkSaveChanged], "只改書籤：⌘S 已處理");
        NSString *saved = [NSString stringWithContentsOfURL:ini encoding:NSUTF8StringEncoding error:nil];
        Check([saved hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=2,5r\r\n[View]\r\n"] && [saved containsString:@"CaretLine=3\r\nCaretColumn=1\r\n"],
              "寫入藍色第 2 行、紅色第 5 行與游標位置");
        Check(![ctx save:v url:doc member:nil locked:NO mode:N2BookmarkSaveChanged], "沒有變動時不寫入（交給一般存檔）");

        ScintillaView *v2 = Editor("a\nb\nc\nd\ne\nf\ng\nh\n");
        N2BookmarkContext *ctx2 = [N2BookmarkContext new];
        [ctx2 loadInto:v2 url:doc member:nil locked:NO];
        Check(Marks(v2, 1) == (1u << N2BlueBookmark) && Marks(v2, 4) == (1u << N2RedBookmark) && Marks(v2, 6) == 0,
              "重新開檔恢復雙色書籤（不含搜尋書籤）");
        Check(S(v2, SCI_LINEFROMPOSITION, S(v2, SCI_GETCURRENTPOS)) == 3, "恢復游標位置");

        ScintillaView *v3 = Editor("a\nb\n");
        N2BookmarkContext *ctx3 = [N2BookmarkContext new];
        [ctx3 loadInto:v3 url:doc member:nil locked:YES];
        Check(Marks(v3, 1) == 0, "密文（鎖定）時不套用書籤");
        S(v3, SCI_SETTEXT, 0, (sptr_t)"a\nb\nc\nd\ne\nf\n");
        [ctx3 loadAfterUnlock:v3];
        Check(Marks(v3, 1) == (1u << N2BlueBookmark) && Marks(v3, 4) == (1u << N2RedBookmark), "解密後才套用書籤");

        NSString *other = [dir stringByAppendingPathComponent:@"另存.md"];
        [@"x\ny\n" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ScintillaView *v4 = Editor("x\ny\n");
        S(v4, SCI_MARKERADD, 1, N2RedBookmark);
        [ctx save:v4 url:[NSURL fileURLWithPath:other] member:nil locked:NO mode:N2BookmarkSaveNewTarget];
        NSString *otherIni = [NSString stringWithContentsOfURL:N2BookmarkSidecarURL([NSURL fileURLWithPath:other], nil) encoding:NSUTF8StringEncoding error:nil];
        Check([otherIni hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=2r\r\n"], "另存新檔把書籤帶到新文件");

        NSURL *arc = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"包.zip"]];
        NSString *expectMember = [[NSString alloc] initWithUTF8String:sidecarName(u"包.zip|sub/說明.txt").c_str()];
        Check([N2BookmarkSidecarURL(arc, @"sub/說明.txt").lastPathComponent isEqualToString:expectMember], "壓縮檔內文件：名稱為「壓縮檔名|成員路徑」");
        NSString *nfd = [@"é.txt" decomposedStringWithCanonicalMapping];
        Check([N2BookmarkSidecarURL([NSURL fileURLWithPath:[dir stringByAppendingPathComponent:nfd]], nil).lastPathComponent
               isEqualToString:[[NSString alloc] initWithUTF8String:sidecarName(u"é.txt").c_str()]], "分解形式的檔名先轉成組合形式");

        // .2xs 是符號連結時不使用
        NSString *dir2 = [dir stringByAppendingPathComponent:@"link"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir2 withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager createSymbolicLinkAtPath:[dir2 stringByAppendingPathComponent:@".2xs"] withDestinationPath:dir error:nil];
        NSString *doc5 = [dir2 stringByAppendingPathComponent:@"z.txt"];
        [@"z\n" writeToFile:doc5 atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ScintillaView *v5 = Editor("z\n");
        S(v5, SCI_MARKERADD, 0, N2BlueBookmark);
        [[N2BookmarkContext new] save:v5 url:[NSURL fileURLWithPath:doc5] member:nil locked:NO mode:N2BookmarkSaveNewTarget];
        Check(![NSFileManager.defaultManager fileExistsAtPath:N2BookmarkSidecarURL([NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"z.txt"]], nil).path],
              ".2xs 是符號連結時不寫入");

        // R155 個別檔案設定（測試案例取自 Windows 版 XSR138BookmarksTests.cpp）
        constexpr int javascript = 63010, big5 = 61022;
        const FilePreferences custom{javascript, big5, 0};
        FilePreferences parsedPrefs = automaticPreferences;
        std::vector<LineBookmark> mixed2{{1}, {6, true}};
        ViewState reading2{3, 1, 0, 4, 2, 1};
        Check(parse(serialize(mixed2, reading2, custom), numbers, &parsedView, &parsedPrefs) && numbers == mixed2 &&
              parsedView == reading2 && parsedPrefs == custom, "[FileSettings] 與書籤、檢視狀態並存");
        Check(parse(serialize(mixed2, reading2) + "[FileSettings]\r\nSyntax=bad\r\nOpenEncoding=61022\r\nWordWrap=999\r\n",
                    numbers, &parsedView, &parsedPrefs) && parsedPrefs == FilePreferences({-1, big5, -1}), "不合法的設定值改回自動");
        Check(parse(serialize(mixed2, reading2), numbers, &parsedView, &parsedPrefs) && parsedPrefs == automaticPreferences,
              "舊版設定檔沒有 [FileSettings]");

        NSString *prefsDoc = [dir stringByAppendingPathComponent:@"app.txt"];
        [@"a\nb\nc\n" writeToFile:prefsDoc atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSURL *prefsURL = [NSURL fileURLWithPath:prefsDoc];
        N2BookmarkContext *pc = [N2BookmarkContext new];
        __block int applied = 0;
        pc.applyPreferences = ^{ applied++; };
        ScintillaView *pv = Editor("a\nb\nc\n");
        [pc loadInto:pv url:prefsURL member:nil locked:NO];
        Check(applied == 1 && [pc preference:N2FilePrefSyntax] == -1, "開檔時讀取設定（預設為自動）");
        Check([pc setPreference:N2FilePrefSyntax value:javascript url:prefsURL member:nil] &&
              [pc setPreference:N2FilePrefEncoding value:big5 url:prefsURL member:nil] &&
              [pc setPreference:N2FilePrefWordWrap value:1 url:prefsURL member:nil], "設定語法、開檔編碼、換行並立即寫入");
        Check(![pc setPreference:N2FilePrefWordWrap value:2 url:prefsURL member:nil], "拒絕不合法的換行值");
        Check([N2BookmarkContext encodingPreferenceForURL:prefsURL member:nil] == big5, "開檔前讀取指定的開檔編碼");
        Check([N2BookmarkContext encodingPreferenceForURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"none.txt"]] member:nil] == -1,
              "沒有設定的檔案回傳 -1");
        NSString *prefsIni = [NSString stringWithContentsOfURL:N2BookmarkSidecarURL(prefsURL, nil) encoding:NSUTF8StringEncoding error:nil];
        Check([prefsIni hasSuffix:@"[FileSettings]\r\nSyntax=63010\r\nOpenEncoding=61022\r\nWordWrap=1\r\n"], "設定檔格式與 Windows 版相同");
        S(pv, SCI_MARKERADD, 1, N2RedBookmark);
        [pc save:pv url:prefsURL member:nil locked:NO mode:N2BookmarkSaveChanged];
        prefsIni = [NSString stringWithContentsOfURL:N2BookmarkSidecarURL(prefsURL, nil) encoding:NSUTF8StringEncoding error:nil];
        Check([prefsIni hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=2r\r\n"] && [prefsIni containsString:@"Syntax=63010"],
              "存書籤時保留個別設定");
        [pc setPreference:N2FilePrefEncoding value:-1 url:prefsURL member:nil];
        N2BookmarkContext *pc2 = [N2BookmarkContext new];
        [pc2 loadInto:Editor("a\nb\nc\n") url:prefsURL member:nil locked:NO];
        Check([pc2 preference:N2FilePrefSyntax] == javascript && [pc2 preference:N2FilePrefEncoding] == -1 &&
              [pc2 preference:N2FilePrefWordWrap] == 1, "重新開啟後恢復設定；恢復自動的欄位不再寫入");

        // R161 雲端逐檔設定：與 .2xs 相同格式，解密後才套用
        N2BookmarkContext *cc = [N2BookmarkContext new];
        std::string cloudState = serialize({{2}, {3, true}}, ViewState{0, 0, 0, 2, 1, 2}, FilePreferences{63034, -1, 0});
        __block int cloudApplied = 0;
        cc.applyPreferences = ^{ cloudApplied++; };
        Check([cc stageCloudState:[NSData dataWithBytes:cloudState.data() length:cloudState.size()]] && cloudApplied == 0 &&
              [cc preference:N2FilePrefSyntax] == 63034, "雲端設定先暫存，不立即套用");
        Check(![cc stageCloudState:[@"[Bookmarks]\r\nVersion=9\r\n" dataUsingEncoding:NSUTF8StringEncoding]], "拒絕格式錯誤的雲端設定");
        [cc stageCloudState:[NSData dataWithBytes:cloudState.data() length:cloudState.size()]];
        ScintillaView *cv = Editor("1\n2\n3\n4\n");
        [cc loadAfterUnlock:cv];
        Check(cloudApplied == 1 && Marks(cv, 1) == (1u << N2BlueBookmark) && Marks(cv, 2) == (1u << N2RedBookmark) &&
              S(cv, SCI_GETZOOM) == 2, "解密後套用雲端書籤、縮放與設定");
        S(cv, SCI_MARKERADD, 0, N2BlueBookmark);
        NSData *withMarks = [cc cloudSnapshot:cv includeBookmarks:YES];
        NSData *kept = [cc cloudSnapshot:cv includeBookmarks:NO];
        NSString *withText = [[NSString alloc] initWithData:withMarks encoding:NSUTF8StringEncoding];
        NSString *keptText = [[NSString alloc] initWithData:kept encoding:NSUTF8StringEncoding];
        Check([withText hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=1,2,3r\r\n"] && [withText hasSuffix:@"[FileSettings]\r\nSyntax=63034\r\nWordWrap=0\r\n"],
              "雲端快照包含目前書籤與設定");
        Check([keptText hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=2,3r\r\n"], "捨棄修改時保留上次儲存的書籤");
        [cc commitCloudSnapshot:withMarks];
        Check([[[NSString alloc] initWithData:[cc cloudSnapshot:cv includeBookmarks:NO] encoding:NSUTF8StringEncoding] hasPrefix:@"[Bookmarks]\r\nVersion=2\r\nLines=1,2,3r"],
              "寫入成功後以新書籤為準");

        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        printf(fails ? "失敗 %d 項\n" : "全部通過（%d 項）\n", fails ? fails : passes);
        return fails ? 1 : 0;
    }
}
