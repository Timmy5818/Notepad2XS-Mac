// 排版模式核心（Windows 版 XSHtmlLayoutCoreTests.cpp 原樣移植）
#include "HtmlLayoutCore.h"
#undef NDEBUG
#include <cassert>
#include <iostream>

using namespace xs::html;
template<class F> void rejects(F test) {
  bool failure=false;
  try { test(); } catch (const std::exception&) { failure=true; }
  assert(failure);
}
int main() {
  const std::wstring original=L"<!DOCTYPE html>\r\n<html lang='zh-TW'><head><style>p { color: pink; }</style>"
      L"<script>if(x < 3) console.log('</body>')</script><title>原頁</title></head>"
      L"<body data-react=\"value\"><div id='layout' data-config='a>b'>\r\n"
      L"<P>第一段 <I>文字</I></P>  \r\n<P Class='theme'>保留格式 <span>文字</span></P>"
      L"<img src='https://example.test/should-not-load' onload='fn()'>"
      L"<script type='application/json'>{\"token\":\"opaque\"}</script><!-- marker -->"
      L"</div></body></html>\r\n";
  const auto view=project(original);
  assert(view.blocks.size()==3); // two editable blocks plus the empty insertion block
  std::vector<std::wstring> before;
  for (const auto& block:view.blocks) {
    before.push_back(block.html);
    assert(block.html.find(L"<script")==std::wstring::npos);
    assert(block.html.find(L"onload")==std::wstring::npos);
    assert(block.html.find(L"example.test")==std::wstring::npos);
  }
  assert(merge(original,view,before,before)==original);
  auto edited=before;
  edited[0]=L"<p ALIGN=center><strong>修改後的繁體中文</strong></p>";
  auto expected=original;
  const auto start=expected.find(L"<P>第一段"), finish=expected.find(L"</P>",start)+4;
  expected.replace(start,finish-start,L"<p align=\"center\"><strong>修改後的繁體中文</strong></p>");
  assert(merge(original,view,before,edited)==expected);
  assert(view.blocks[1].inlineOnly);
  edited[1]=table(3,4);
  rejects([&]{merge(original,view,before,edited);});
  edited[1]=before[1];
  edited.back()=table(2,2);
  const auto result=merge(original,view,before,edited);
  assert(result.find(L"<table border=\"1\"")>result.find(L"<!-- marker -->"));
  assert(result.find(L"</table>")<result.find(L"</body></html>"));
  assert(project(L"").blocks.size()==1);
  for (const auto* source:{L"<p>a<p>b",L"<!doctype html><title>title</title><p>start",
                            L"<html><head><title>Test</title><body><p>A</html>"}) {
    const auto projected=project(source);
    assert(projected.blocks.size()>=2);
    std::vector<std::wstring> raw;
    for (const auto& block:projected.blocks) raw.push_back(block.html);
    assert(merge(source,projected,raw,raw)==source);
  }
  assert(safeFragment(L"<P style=\"COLOR: rgb(100, 200, 0); FONT-FAMILY: &quot;Segoe UI&quot;\">A &lt;B</P>",false)
    ==L"<p style=\"COLOR: rgb(100, 200, 0); FONT-FAMILY: &quot;Segoe UI&quot;\">A &lt;B</p>");
  for (const auto* bad:{L"<script>alert(1)</script>",L"<img src=local>",L"<span onclick='x'>a</span>",
                        L"<svg><script>test</script></svg>",L"<a href='javascript:code'>b</a>",
                        L"<p style='color: expression(exec)'>x</p>",L"<p style='color: rgb(expression(1))'>x</p>",
                        L"<DIV STYLE='background-image: url(local)'>x</DIV>",L"<p style='color: &amp;#1;'><b>x</b></p>",
                        L"<span id=n2xs-edit-1>x</span>",L"<div><b>x</div>",L"<object data='x'></object>"})
    rejects([&]{safeFragment(bad,false);});
  assert(project(L"<body><textarea>preserved\n<textarea>x</textarea><p>ok</p></body>").blocks.size()==2);
  rejects([]{project(L"<body><script>unclosed</body>");});
  rejects([]{table(0,1);});
  rejects([]{table(41,1);});
  rejects([]{table(20,21);});
  auto slightlyLarger=std::wstring(limit+1,L'a');
  rejects([&]{project(slightlyLarger);});
  assert(escapeText(L"<>&\"") == L"&lt;&gt;&amp;&quot;");
  std::cout<<"PASS: isolated HTML model, Unicode, per-block edits, implicit HTML tags, plain-text escape, table bounds and exact preservation of surrounding source.\n";
}
