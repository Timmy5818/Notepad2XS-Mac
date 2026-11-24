#include "HtmlLayoutCore.h"
#include <algorithm>
#include <stdexcept>

namespace xs::html {
namespace {
using Text = std::wstring_view;
constexpr size_t absent = std::wstring::npos;
wchar_t lower(wchar_t c) { return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + 32) : c; }
std::wstring folded(Text s) {
  std::wstring result(s);
  std::transform(result.begin(), result.end(), result.begin(), lower);
  return result;
}
bool space(wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == L'\f'; }
Text trim(Text s) {
  while (!s.empty() && space(s.front())) s.remove_prefix(1);
  while (!s.empty() && space(s.back())) s.remove_suffix(1);
  return s;
}
bool word(wchar_t c) {
  c = lower(c);
  return (c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'-' || c == L':' || c == L'_';
}
bool in(Text value, std::initializer_list<Text> values) {
  return std::find(values.begin(), values.end(), value) != values.end();
}
bool isVoid(Text tag) {
  return in(tag,{L"area",L"base",L"br",L"col",L"embed",L"hr",L"img",L"input",L"link",L"meta",
                 L"param",L"source",L"track",L"wbr",L"keygen"});
}
bool isRaw(Text tag) {
  return in(tag,{L"script",L"style",L"title",L"textarea",L"iframe",L"xmp",L"noembed",L"noframes"});
}
bool inlineTag(Text tag) {
  return in(tag,{L"b",L"strong",L"i",L"em",L"u",L"s",L"strike",L"sup",L"sub",L"span",
                 L"font",L"small",L"big",L"code",L"mark",L"br",L"del",L"ins"});
}
bool plainTag(Text tag) {
  return inlineTag(tag) || in(tag,{L"p",L"div",L"h1",L"h2",L"h3",L"h4",L"h5",L"h6",L"hr",
      L"blockquote",L"pre",L"address",L"ul",L"ol",L"li",L"table",L"tbody",L"thead",L"tfoot",
      L"tr",L"td",L"th",L"caption",L"center"});
}
bool walkTag(Text tag) {
  return plainTag(tag) || in(tag,{L"main",L"section",L"article",L"aside",L"header",L"footer",L"nav",
                                L"figure",L"figcaption",L"a",L"label"});
}
bool inlineContainer(Text tag) {
  return inlineTag(tag) || in(tag,{L"p",L"h1",L"h2",L"h3",L"h4",L"h5",L"h6",L"a",L"label",L"pre"});
}
struct Attribute { std::wstring name; std::wstring value; };
struct Node {
  size_t first = 0, opening = 0, closing = 0, last = 0;
  std::wstring tag;
  std::vector<Attribute> attrs;
  std::vector<Node> children;
  bool text = false;
};
bool mayOmitEnd(Text tag, Text next, bool atClose) {
  if (atClose) return in(tag,{L"html",L"head",L"body",L"p",L"li",L"dt",L"dd",L"td",L"th",
                              L"tr",L"thead",L"tbody",L"tfoot",L"colgroup",L"option",L"optgroup"});
  if (tag==L"head") return !in(next,{L"base",L"link",L"meta",L"title",L"style",L"script",L"noscript",L"template"});
  if (tag==L"p") return in(next,{L"address",L"article",L"aside",L"blockquote",L"details",L"div",L"dl",L"fieldset",
      L"figcaption",L"figure",L"footer",L"form",L"h1",L"h2",L"h3",L"h4",L"h5",L"h6",L"header",L"hr",
      L"main",L"menu",L"nav",L"ol",L"p",L"pre",L"section",L"table",L"ul"});
  if (tag==L"li") return next==tag;
  if (in(tag,{L"dt",L"dd"})) return in(next,{L"dt",L"dd"});
  if (in(tag,{L"td",L"th"})) return in(next,{L"td",L"th",L"tr",L"thead",L"tbody",L"tfoot"});
  if (tag==L"tr") return in(next,{L"tr",L"thead",L"tbody",L"tfoot"});
  if (in(tag,{L"thead",L"tbody",L"tfoot"})) return in(next,{L"thead",L"tbody",L"tfoot"});
  if (tag==L"option") return in(next,{L"option",L"optgroup"});
  if (tag==L"optgroup") return next==tag;
  return tag==L"colgroup" && next!=L"col";
}
struct Parser {
  Text source;
  size_t pos = 0, count = 0;
  [[noreturn]] static void invalid() { throw std::runtime_error("Unsupported or invalid HTML structure"); }
  void whitespace() { while (pos < source.size() && space(source[pos])) ++pos; }
  std::wstring name() {
    const auto begin = pos;
    while (pos < source.size() && word(source[pos])) ++pos;
    if (begin == pos) invalid();
    return folded(source.substr(begin, pos - begin));
  }
  bool begins(Text text) const { return source.substr(pos,text.size()) == text; }
  bool beginsFolded(Text text) const {
    return pos + text.size() <= source.size() &&
      std::equal(text.begin(),text.end(),source.begin() + static_cast<std::ptrdiff_t>(pos),
        [](wchar_t a,wchar_t b){return a==lower(b);});
  }
  bool endsTag(Text tag) const {
    const auto next = pos + tag.size() + 2;
    return begins(L"</") && next < source.size() &&
      std::equal(tag.begin(),tag.end(),source.begin() + static_cast<std::ptrdiff_t>(pos+2),
        [](wchar_t a,wchar_t b){return a==lower(b);}) &&
      (source[next] == L'>' || space(source[next]));
  }
  void endTag(Text tag) {
    if (!endsTag(tag)) invalid();
    pos += tag.size()+2;
    whitespace();
    if (pos == source.size() || source[pos++] != L'>') invalid();
  }
  bool openingTag() const {
    if (pos + 1 >= source.size() || source[pos] != L'<') return false;
    const auto ch = lower(source[pos+1]);
    return ch >= L'a' && ch <= L'z';
  }
  Node node(unsigned depth) {
    if (depth > 96 || ++count > 100000) invalid();
    Node n;
    n.first = pos;
    if (begins(L"<!--")) {
      const auto end = source.find(L"-->",pos+4);
      if (end == absent) invalid();
      pos = end+3;
      n.tag = L"!comment";
    } else if (begins(L"<![CDATA[")) {
      const auto end = source.find(L"]]>",pos+9);
      if (end == absent) invalid();
      pos = end+3;
      n.tag = L"!declaration";
    } else if (beginsFolded(L"<!doctype") || begins(L"<?")) {
      wchar_t quote = 0;
      bool ended = false;
      while (++pos < source.size()) {
        const auto c = source[pos];
        if (quote) { if (c==quote) quote=0; }
        else if (c==L'\''||c==L'"') quote=c;
        else if (c==L'>') { ++pos; ended=true; break; }
      }
      if (!ended) invalid();
      n.tag = L"!declaration";
    } else if (!openingTag()) {
      if (begins(L"</") || begins(L"<!")) invalid();
      n.text = true;
      do { ++pos; }
      while (pos < source.size() && !openingTag() && !begins(L"</") && !begins(L"<!") && !begins(L"<?"));
    } else {
      ++pos;
      n.tag = name();
      bool selfClose = false;
      for (;;) {
        whitespace();
        if (begins(L"/>")) { pos+=2; selfClose=true; break; }
        if (begins(L">")) { ++pos; break; }
        const auto attr = name();
        whitespace();
        Text value;
        if (begins(L"=")) {
          ++pos; whitespace();
          if (pos >= source.size()) invalid();
          const auto quote = source[pos];
          if (quote == L'"' || quote == L'\'') {
            const auto end = source.find(quote,++pos);
            if (end == absent) invalid();
            value=source.substr(pos,end-pos); pos=end+1;
          } else {
            const auto begin=pos;
            while (pos<source.size() && !space(source[pos]) && source[pos]!=L'>' && !begins(L"/>")) {
              if (in(source.substr(pos,1),{L"<",L"=",L"'",L"\"",L"`"})) invalid();
              ++pos;
            }
            if (begin==pos) invalid();
            value=source.substr(begin,pos-begin);
          }
        }
        std::wstring decoded;
        for (size_t i=0;i<value.size();) {
          if (value.substr(i,6)==L"&quot;") { decoded+=L'"';i+=6; }
          else if (value.substr(i,5)==L"&#39;") { decoded+=L'\'';i+=5; }
          else decoded+=value[i++];
        }
        n.attrs.push_back({attr,std::move(decoded)});
        if (n.attrs.size()>128) invalid();
      }
      n.opening=pos;
      if (selfClose && plainTag(n.tag) && !isVoid(n.tag)) invalid();
      if (!isVoid(n.tag) && !selfClose) {
        if (isRaw(n.tag)) {
          while (pos < source.size() && !endsTag(n.tag)) ++pos;
        } else {
          while (pos<source.size() && !endsTag(n.tag)) {
            if (begins(L"</") && mayOmitEnd(n.tag,{},true)) break;
            if (openingTag()) {
              const auto save=pos++;
              const auto next=name();
              pos=save;
              if (mayOmitEnd(n.tag,next,false)) break;
            }
            n.children.push_back(node(depth+1));
          }
        }
        n.closing=pos;
        if (endsTag(n.tag)) endTag(n.tag);
        else if (isRaw(n.tag) || (pos==source.size() && !mayOmitEnd(n.tag,{},true))) invalid();
      }
    }
    n.last=pos;
    return n;
  }
  std::vector<Node> parse() {
    if (source.size()>limit || source.find(L'\0')!=absent) invalid();
    std::vector<Node> nodes;
    while (pos<source.size()) nodes.push_back(node(0));
    return nodes;
  }
};

bool attrChars(Text val, bool css) {
  if (val.size()>2048) return false;
  for (auto c:val) {
    if (c>=0x80 || (c>=L'A' && c<=L'Z') || (c>=L'a' && c<=L'z') ||
       (c>=L'0' && c<=L'9') || space(c) || c==L'#' || c==L'%' || c==L'.' ||
       c==L',' || c==L'-' || c==L'_' || (css && (c==L'\'' || c==L'"'))) continue;
    return false;
  }
  return true;
}
bool styleSafe(Text style) {
  while (!style.empty()) {
    const auto semi = style.find(L';');
    const auto entry = trim(style.substr(0,semi));
    if (!entry.empty()) {
      const auto colon=entry.find(L':');
      if (colon==absent) return false;
      const auto prop=folded(trim(entry.substr(0,colon)));
      const auto value=trim(entry.substr(colon+1));
      if (!in(prop,{L"color",L"background-color",L"font-family",L"font-size",L"font-style",L"font-weight",
                    L"text-decoration",L"text-align",L"vertical-align",L"margin-left",L"margin-right",
                    L"margin-bottom",L"margin-top",L"text-indent",L"line-height",
                    L"border",L"border-color",L"border-width",L"border-style",L"border-collapse",L"width",
                    L"height",L"padding",L"padding-left",L"list-style-type",L"white-space"})) return false;
      if (!attrChars(value,true)) {
        const auto color=folded(value);
        const auto prefix=color.compare(0,4,L"rgb(")==0?4u:color.compare(0,5,L"rgba(")==0?5u:0u;
        if (!in(prop,{L"color",L"background-color",L"border-color"}) || !prefix || color.back()!=L')')
          return false;
        const auto inside=Text(color).substr(prefix,color.size()-prefix-1);
        if (inside.empty() || inside.find_first_not_of(L"0123456789.,% ")!=absent) return false;
      }
    }
    if (semi==absent) break;
    style.remove_prefix(semi+1);
  }
  return true;
}
bool allowedAttribute(Text tag, const Attribute& a) {
  if (a.name==L"style") return styleSafe(a.value);
  if (in(a.name,{L"align",L"valign",L"dir"})) return attrChars(a.value,false);
  if (tag==L"font" && in(a.name,{L"face",L"size",L"color"})) return attrChars(a.value,false);
  if (in(tag,{L"table",L"td",L"th",L"tr",L"hr"}) &&
      in(a.name,{L"width",L"height",L"border",L"cellpadding",L"cellspacing",L"colspan",L"rowspan",L"bgcolor"}))
    return attrChars(a.value,false);
  if (in(tag,{L"ol",L"ul",L"li"}) && in(a.name,{L"start",L"type",L"value"})) return attrChars(a.value,false);
  return false;
}
bool safe(const Node& n, bool onlyInline) {
  if (n.text) return true;
  return (onlyInline ? inlineTag(n.tag) : plainTag(n.tag)) &&
    std::all_of(n.attrs.begin(),n.attrs.end(),[&](const Attribute& a){return allowedAttribute(n.tag,a);}) &&
    std::all_of(n.children.begin(),n.children.end(),[&](const Node& child){return safe(child,onlyInline || inlineContainer(n.tag));});
}
void appendSafe(const Node& node, Text source, std::wstring& out) {
  if (node.text) {
    // A tokenized '<' in plain text must stay plain text in the renderer.
    for (wchar_t ch : source.substr(node.first,node.last-node.first))
      if (ch==L'<') out+=L"&lt;"; else out+=ch;
    return;
  }
  out+=L"<"+node.tag;
  for (const auto& attr:node.attrs)
    out+=L" "+attr.name+L"=\""+escapeText(attr.value)+L"\"";
  out+=L">";
  if (isVoid(node.tag)) return;
  for (const auto& child:node.children) appendSafe(child,source,out);
  out+=L"</"+node.tag+L">";
}
void addBlock(Layout& out, const std::vector<Node>& nodes, size_t first, size_t end, Text source, bool onlyInline) {
  if (out.blocks.size()>=8192) Parser::invalid();
  std::wstring html;
  for (size_t i=first;i<end;++i) appendSafe(nodes[i],source,html);
  out.pieces.push_back({out.blocks.size(),{}});
  out.blocks.push_back({nodes[first].first,nodes[end-1].last,onlyInline,
                        nodes[first].text || inlineTag(nodes[first].tag),std::move(html)});
}
void partition(Layout& out, const std::vector<Node>& nodes, Text source, bool onlyInline) {
  for (size_t i=0;i<nodes.size();) {
    const auto& n=nodes[i];
    if (n.text && trim(source.substr(n.first,n.last-n.first)).empty()) { ++i; continue; }
    const bool splitDiv=n.tag==L"div" &&
        std::any_of(n.children.begin(),n.children.end(),[](const Node& child){
          return !child.text && walkTag(child.tag) && !inlineTag(child.tag);
        });
    if (!splitDiv && safe(n,onlyInline)) {
      size_t end=i+1;
      // Keep neighboring inline markup in the same editor block so a word
      // that spans several inline nodes remains visually continuous.
      if (n.text || inlineTag(n.tag))
        while (end<nodes.size() && (nodes[end].text || inlineTag(nodes[end].tag)) && safe(nodes[end],onlyInline)) ++end;
      addBlock(out,nodes,i,end,source,onlyInline);
      i=end;
      continue;
    }
    if (walkTag(n.tag) && !n.children.empty() &&
        !in(n.tag,{L"table",L"thead",L"tbody",L"tfoot",L"tr",L"ul",L"ol",L"li"})) {
      partition(out,n.children,source,onlyInline || inlineContainer(n.tag));
    } else if (!in(n.tag,{L"script",L"style",L"!comment",L"!declaration"})) {
      if (out.pieces.size()>=16000) Parser::invalid();
      out.pieces.push_back({0,n.tag});
    }
    ++i;
  }
}
} // namespace

std::wstring escapeText(Text text) {
  std::wstring out;
  for (auto ch:text) switch(ch) {
    case L'&': out+=L"&amp;"; break;
    case L'<': out+=L"&lt;"; break;
    case L'>': out+=L"&gt;"; break;
    case L'"': out+=L"&quot;"; break;
    default: out+=ch;
  }
  return out;
}
Layout project(Text source) {
  auto nodes=Parser{source}.parse();
  const auto* bodyNodes=&nodes;
  size_t insert=source.size();
  const Node* body=nullptr;
  const Node* root=nullptr;
  for (const auto& node:nodes) if (node.tag==L"html") {
    if (root) Parser::invalid();
    root=&node;
  }
  if (root) { bodyNodes=&root->children; insert=root->closing; }
  for (const auto& node:*bodyNodes) if (node.tag==L"body") {
    if (body) Parser::invalid();
    body=&node;
  }
  if (body) { bodyNodes=&body->children; insert=body->closing; }
  Layout out;
  if (body) {
    partition(out,*bodyNodes,source,false);
  } else {
    // Valid HTML can omit the BODY start tag. Keep the implicit head prefix
    // exactly as authored, then project the remaining top-level content.
    auto first=bodyNodes->begin();
    while (first!=bodyNodes->end() &&
           (in(first->tag,{L"head",L"base",L"link",L"meta",L"title",L"style",L"script",L"!comment",L"!declaration"}) ||
             (first->text && trim(source.substr(first->first,first->last-first->first)).empty()))) ++first;
    std::vector<Node> bodyContent(first,bodyNodes->end());
    partition(out,bodyContent,source,false);
  }
  // The final empty block permits inserting a table into an empty document
  // or after protected content without ever rewriting that content.
  out.pieces.push_back({out.blocks.size(),{}});
  out.blocks.push_back({insert,insert,false,true,{}});
  return out;
}
std::wstring safeFragment(Text html, bool onlyInline) {
  const auto nodes=Parser{html}.parse();
  std::wstring result;
  for (const auto& node:nodes) {
    if (!safe(node,onlyInline)) Parser::invalid();
    appendSafe(node,html,result);
  }
  if (result.size()>limit) Parser::invalid();
  return result;
}
std::wstring merge(Text source, const Layout& layout,
                   const std::vector<std::wstring>& initial, const std::vector<std::wstring>& edited) {
  if (edited.size()!=layout.blocks.size() || initial.size()!=edited.size()) Parser::invalid();
  std::wstring result;
  size_t pos=0;
  for (size_t i=0;i<edited.size();++i) {
    const auto& block=layout.blocks[i];
    if (block.first<pos || block.last<block.first || block.last>source.size()) Parser::invalid();
    if (initial[i]==edited[i]) continue;
    result+=source.substr(pos,block.first-pos);
    result+=safeFragment(edited[i],block.inlineOnly);
    pos=block.last;
    if (result.size()>limit) Parser::invalid();
  }
  result+=source.substr(pos);
  if (result.size()>limit) Parser::invalid();
  return result;
}
std::wstring table(unsigned rows, unsigned columns) {
  if (!rows || !columns || rows>40 || columns>20) Parser::invalid();
  std::wstring result=L"<table border=\"1\" cellpadding=\"5\" style=\"border-collapse: collapse\"><tbody>";
  for (unsigned row=0;row<rows;++row) {
    result+=L"<tr>";
    for (unsigned column=0;column<columns;++column) result+=L"<td>&nbsp;</td>";
    result+=L"</tr>";
  }
  return result+L"</tbody></table>";
}
} // namespace xs::html
