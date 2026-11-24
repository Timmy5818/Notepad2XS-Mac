// 檔案搜尋核心（Windows 版 XSFileSearchCoreTests.cpp 中與 Mac 版相關的部分：內容條件 AND／OR／引號、檔名萬用字元）
#include "FileSearchCore.h"
#undef NDEBUG
#include <cassert>
#include <cwctype>
#include <cstdio>
#include <vector>

using namespace xs::fileSearch;
static bool equal(wchar_t a, wchar_t b) { return std::towupper(a) == std::towupper(b); }

int main() {
  using Terms = std::vector<std::wstring>;
  using Ends = std::vector<std::size_t>;
  assert(parseContent(L"").terms.empty() && parseContent(L"*").terms.empty());
  assert(parseContent(L"  exact phrase  ").terms == Terms({L"  exact phrase  "}));
  assert(parseContent(L"\"*\"").terms == Terms({L"*"}));
  assert(parseContent(L"/root/and/or").terms == Terms({L"/root/and/or"}));
  assert(parseContent(L"and").terms == Terms({L"and"}));
  const auto mixed = parseContent(L" 連線逾時 oR login AND 失敗　Or　\"rock and roll\" ");
  assert(mixed.error == ContentError::none && mixed.alternativeEnds == Ends({1, 3, 4}));
  assert(mixed.terms == Terms({L"連線逾時", L"login", L"失敗", L"rock and roll"}));
  assert(mixed.overlap == std::wstring_view(L"rock and roll").size() - 1);
  const auto quoted = parseContent(L"\" \"\"quoted\"\" OR text \" aNd service restarted");
  assert(quoted.error == ContentError::none && quoted.alternativeEnds == Ends({2}));
  assert(quoted.terms == Terms({L" \"quoted\" OR text ", L"service restarted"}));
  assert(parseContent(L"登入 AND").error == ContentError::missingAnd);
  assert(parseContent(L"OR 登入").error == ContentError::missingOr);
  assert(parseContent(L"登入 OR AND 失敗").error == ContentError::missingOr);
  assert(parseContent(L"登入 OR \"timeout").error == ContentError::invalidQuote);
  assert(parseContent(L"\"\"").error == ContentError::invalidQuote);
  
  assert(patterns(L" *.xls, *.doc, , ") == std::vector<std::wstring>({L"*.xls",L"*.doc"}));
  assert(patterns(L" , , ") == std::vector<std::wstring>({L"*"}));
  assert(patterns(L"") == std::vector<std::wstring>({L"*"}));
  for (const auto &bad : {L"C:\\*.xls",L"foo/bar",L"*.x?",L"\"abc\"",L"*.xls,../*"}) assert(patterns(bad).empty());
  const auto filters = patterns(L"*.xls,*.doc");
  for (const auto &name : {L"a.xls",L"a.doc",L"中文.XLS",L"日本語.DOC"}) assert(matchesAny(name,filters,equal));
  for (const auto &name : {L"a.xlsx",L"a.docx",L"a.xls.bak",L"abc"}) assert(!matchesAny(name,filters,equal));
  assert(matches(L"abc.xls",L"abc.xls",equal));
  assert(!matches(L"abc.xlsx",L"abc.xls",equal));
  assert(matches(L"abc",L"a**b*c*",equal));
  assert(matches(L"",L"**",equal));
  assert(!matches(L"",L"*a",equal));
  assert(matches(L"README",L"*.*",equal));
  printf("全部通過（內容條件與檔名萬用字元）\n");
  return 0;
}
