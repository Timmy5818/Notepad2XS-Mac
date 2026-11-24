// 編輯 → 排版模式（對應 Windows 版 R136）：HTML／HTM 在獨立的排版畫布調整文字、段落與表格，確定後寫回主編輯區
// - 解析、安全檢查與合併沿用 Windows 版 HtmlLayoutCore：只把可安全編輯的區塊放進畫布，
//   <head>、樣式表、腳本、受保護的標籤與沒有改動的區塊原始碼都保持原樣
// - 畫布使用 WebKit（WKWebView）；不載入原頁的腳本、樣式表、圖片或其他外部資源
// - 確定後整次變更一次復原；唯讀文件只能預覽；已鎖定的加密文件要先解密
#import "HtmlLayoutWindow.h"
#import "EditorWindowController.h"
#import "Document.h"
#import "N2Common.h"
#import "Localization.h"
#import <WebKit/WebKit.h>
#include "HtmlLayoutCore.h"

using namespace xs::html;

// 畫布裡的腳本：記住最後一個在可編輯區塊中的選取範圍，排版指令都作用在那裡
static const char *const kCanvasScript = R"JS(
(function () {
  let saved = null;
  const regions = () => Array.from(document.querySelectorAll('.region'));
  const regionOf = (node) => {
    for (let n = node; n; n = n.parentNode) if (n.classList && n.classList.contains('region')) return n;
    return null;
  };
  document.addEventListener('selectionchange', () => {
    const s = document.getSelection();
    if (s.rangeCount && regionOf(s.anchorNode) && regionOf(s.focusNode) === regionOf(s.anchorNode)) saved = s.getRangeAt(0).cloneRange();
  });
  const restore = () => {
    if (!saved || !regionOf(saved.startContainer)) return null;
    const s = document.getSelection();
    s.removeAllRanges();
    s.addRange(saved);
    regionOf(saved.startContainer).focus();
    return regionOf(saved.startContainer);
  };
  const escapeText = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const insertPlain = (text) => {
    const html = text.split(/\r\n|\r|\n/).map(escapeText).join('<br>');
    if (html) document.execCommand('insertHTML', false, html);
  };
  // 貼上一律當成純文字；不接受拖放進來的內容（例如圖片）
  document.addEventListener('paste', (e) => {
    if (!regionOf(e.target)) return;
    e.preventDefault();
    insertPlain(e.clipboardData.getData('text/plain') || '');
  });
  document.addEventListener('drop', (e) => e.preventDefault());
  document.addEventListener('dragover', (e) => e.preventDefault());
  // 只允許行內樣式的區塊：Enter 插入換行（<br>），不建立新的段落
  document.addEventListener('keydown', (e) => {
    const r = regionOf(e.target);
    if (r && r.dataset.inline === '1' && e.key === 'Enter') { e.preventDefault(); document.execCommand('insertLineBreak'); }
  });
  window.n2exec = (command, value, blockCommand) => {
    const r = restore();
    if (!r) return 'noregion';
    if (blockCommand && r.dataset.inline === '1') return 'inline';
    if (!document.execCommand(command, false, value)) return 'failed';
    return '';
  };
  window.n2paste = (text) => {
    if (!restore()) return 'noregion';
    insertPlain(text);
    return '';
  };
  window.n2insertTable = (html) => {
    const r = restore();
    if (!r) return 'noregion';
    if (r.dataset.inline === '1') return 'inline';
    r.insertAdjacentHTML('beforeend', html);
    return '';
  };
  // 表格列欄增刪：只支援 40 列、20 欄以內、沒有合併儲存格的表格
  window.n2tableOp = (op) => {
    if (!restore()) return 'noregion';
    let cell = saved.startContainer;
    while (cell && !(cell.nodeName === 'TD' || cell.nodeName === 'TH')) cell = cell.parentNode;
    if (!cell) return 'nocell';
    const row = cell.parentNode, table = row.closest('table');
    if (!table || !regionOf(table)) return 'nocell';
    const rows = Array.from(table.rows);
    const width = rows.length ? rows[0].cells.length : 0;
    if (rows.length < 1 || rows.length > 40) return 'shape';
    for (const r of rows) {
      if (r.cells.length !== width || width < 1 || width > 20) return 'shape';
      for (const c of r.cells) if (c.colSpan !== 1 || c.rowSpan !== 1) return 'shape';
    }
    const col = cell.cellIndex, ri = row.rowIndex;
    if ((op === 'addrow' && rows.length === 40) || (op === 'addcol' && width === 20) ||
        (op === 'delrow' && rows.length === 1) || (op === 'delcol' && width === 1)) return 'limit';
    if (op === 'addrow') { const n = table.insertRow(ri + 1); for (let i = 0; i < width; i++) n.insertCell(-1).innerHTML = '&nbsp;'; }
    else if (op === 'delrow') table.deleteRow(ri);
    else for (const r of rows) { if (op === 'addcol') r.insertCell(col + 1).innerHTML = '&nbsp;'; else r.deleteCell(col); }
    saved = null;
    return '';
  };
  // WebKit 產生的樣式與屬性整理成原版允許的寫法（例如縮排的 margin 簡寫）
  const allowed = new Set(['color','background-color','font-family','font-size','font-style','font-weight','text-decoration',
    'text-align','vertical-align','margin-left','margin-right','margin-bottom','margin-top','text-indent','line-height',
    'border','border-color','border-width','border-style','border-collapse','width','height','padding','padding-left',
    'list-style-type','white-space']);
  const blockTags = new Set(['UL','OL','TABLE','DIV','H1','H2','H3','H4','H5','H6','BLOCKQUOTE','PRE','ADDRESS','HR','P','CENTER']);
  const tidy = (root) => {
    // <p> 裡不能放清單、表格等區塊元素（WebKit 的清單指令會產生這種結構）：拆掉外層的 <p>
    for (const p of Array.from(root.querySelectorAll('p'))) {
      if (Array.from(p.children).some((c) => blockTags.has(c.nodeName))) {
        while (p.firstChild) p.parentNode.insertBefore(p.firstChild, p);
        p.remove();
      }
    }
    for (const el of root.querySelectorAll('*')) {
      for (const a of Array.from(el.attributes)) {
        const n = a.name.toLowerCase();
        if (n === 'class' || n === 'id' || n.startsWith('data-') || n === 'contenteditable' || n === 'spellcheck') el.removeAttribute(a.name);
      }
      if (!el.hasAttribute('style')) continue;
      const st = el.style, out = [];
      for (let i = 0; i < st.length; i++) {
        const p = st[i];
        if (allowed.has(p)) out.push(p + ': ' + st.getPropertyValue(p));
      }
      if (out.length) el.setAttribute('style', out.join('; ')); else el.removeAttribute('style');
    }
  };
  window.n2capture = () => regions().map((r) => {
    const copy = r.cloneNode(true);
    // 拿掉畫布自己加的 <p>；空白區塊只剩 <br> 時視為空
    // 只有在區塊內仍是單一一層時才拿掉（使用者按 Enter 分出多個段落時，保留段落結構）
    // 空的包裝段落（例如在最後的空白區塊插入表格後）直接移除
    for (const w of Array.from(copy.querySelectorAll('p[data-wrap]')))
      if ((w.innerHTML === '<br>' || w.innerHTML === '') && copy.childNodes.length > 1) w.remove();
    const wraps = copy.querySelectorAll('p[data-wrap]');
    const top = Array.from(copy.childNodes).filter((n) => !(n.nodeType === 3 && !n.data.trim()));
    if (wraps.length === 1 && top.length === 1 && top[0] === wraps[0]) {
      const w = wraps[0];
      if (w.innerHTML === '<br>') w.innerHTML = '';
      while (w.firstChild) w.parentNode.insertBefore(w.firstChild, w);
      w.remove();
    }
    tidy(copy);
    return copy.innerHTML;
  });
  window.n2enable = (editable) => { for (const r of regions()) r.contentEditable = editable ? 'true' : 'false'; };
})();
)JS";

static std::wstring W(NSString *s) { return N2ToWide(s ?: @""); }
static NSString *S(const std::wstring &w) { return N2FromWide(w); }

@interface N2HtmlLayoutWindow : NSWindowController <WKNavigationDelegate>
@end

@implementation N2HtmlLayoutWindow {
    __weak EditorWindowController *_editor;
    std::string _bytes;            // 開啟時主編輯區的全文（UTF-8）
    std::wstring _original;
    Layout _layout;
    std::vector<std::wstring> _baseline;
    BOOL _readonly, _ready;
    WKWebView *_web;
    NSPopUpButton *_font, *_size, *_color, *_block;
    NSTextField *_rows, *_cols, *_status;
    NSButton *_ok;
    NSMutableArray<NSControl *> *_tools;
}

static NSMutableSet *gLayoutWindows;

- (instancetype)initWithEditor:(EditorWindowController *)ed text:(const std::string &)bytes original:(const std::wstring &)original
                        layout:(Layout &&)layout readonly:(BOOL)readonly {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 620)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    w.minSize = NSMakeSize(720, 420);
    w.title = N2L(@"排版模式");
    if ((self = [super initWithWindow:w])) {
        _editor = ed;
        _bytes = bytes;
        _original = original;
        _layout = std::move(layout);
        _readonly = readonly;
        _tools = [NSMutableArray array];
        [self build];
        [self loadCanvas];
    }
    return self;
}

- (void)dealloc {
    std::fill(_bytes.begin(), _bytes.end(), '\0');
    std::fill(_original.begin(), _original.end(), L'\0');
}

- (NSPopUpButton *)popup:(NSArray<NSString *> *)titles at:(NSRect)r action:(SEL)a {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:r pullsDown:NO];
    for (NSString *t in titles) [p addItemWithTitle:N2L(t)];
    p.target = self; p.action = a;
    p.autoresizingMask = NSViewMinYMargin;
    [self.window.contentView addSubview:p];
    [_tools addObject:p];
    return p;
}

- (NSButton *)tool:(NSString *)title symbol:(NSString *)symbol at:(NSRect)r action:(SEL)a {
    NSButton *b = [NSButton buttonWithTitle:N2L(title) target:self action:a];
    if (symbol) {
        NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:N2L(title)];
        if (img) { b.image = img; b.imagePosition = NSImageOnly; }
        b.toolTip = N2L(title);
    }
    b.frame = r;
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.autoresizingMask = NSViewMinYMargin;
    [self.window.contentView addSubview:b];
    [_tools addObject:b];
    return b;
}

- (void)build {
    NSView *v = self.window.contentView;
    CGFloat top = NSHeight(v.bounds);
    // 第一列：字型、字級、顏色、段落／標題、粗體、斜體、底線、對齊
    CGFloat y = top - 36, x = 12;
    _font = [self popup:@[@"字型", @"PingFang TC", @"Helvetica Neue", @"Arial", @"Times New Roman", @"Menlo"]
                     at:NSMakeRect(x, y, 140, 26) action:@selector(fontChanged:)];
    x += 144;
    _size = [self popup:@[@"字級", @"8 pt", @"10 pt", @"12 pt", @"14 pt", @"18 pt", @"24 pt", @"36 pt"]
                     at:NSMakeRect(x, y, 90, 26) action:@selector(sizeChanged:)];
    x += 94;
    _color = [self popup:@[@"文字顏色", @"黑色", @"灰色", @"紅色", @"藍色", @"綠色", @"紫色"]
                      at:NSMakeRect(x, y, 104, 26) action:@selector(colorChanged:)];
    x += 108;
    _block = [self popup:@[@"段落樣式", @"段落", @"標題 1", @"標題 2", @"標題 3"]
                      at:NSMakeRect(x, y, 104, 26) action:@selector(blockChanged:)];
    x += 112;
    NSArray *row1 = @[@[@"粗體", @"bold", @"bold:"], @[@"斜體", @"italic", @"italic:"], @[@"底線", @"underline", @"underline:"],
                      @[@"靠左", @"text.alignleft", @"alignLeft:"], @[@"置中", @"text.aligncenter", @"alignCenter:"],
                      @[@"靠右", @"text.alignright", @"alignRight:"], @[@"左右對齊", @"text.justify", @"alignJustify:"]];
    for (NSArray *t in row1) { [self tool:t[0] symbol:t[1] at:NSMakeRect(x, y, 32, 26) action:NSSelectorFromString(t[2])]; x += 34; }
    // 第二列：縮排、清單、表格、列欄、貼上純文字
    y = top - 70; x = 12;
    NSArray *row2 = @[@[@"增加縮排", @"increase.indent", @"indent:"], @[@"減少縮排", @"decrease.indent", @"outdent:"],
                      @[@"項目清單", @"list.bullet", @"bulletList:"], @[@"編號清單", @"list.number", @"numberList:"]];
    for (NSArray *t in row2) { [self tool:t[0] symbol:t[1] at:NSMakeRect(x, y, 32, 26) action:NSSelectorFromString(t[2])]; x += 34; }
    x += 10;
    NSTextField *rl = [NSTextField labelWithString:N2L(@"列")];
    rl.frame = NSMakeRect(x, y + 4, 20, 18); rl.autoresizingMask = NSViewMinYMargin; [v addSubview:rl];
    _rows = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 20, y + 2, 34, 22)];
    _rows.stringValue = @"3"; _rows.autoresizingMask = NSViewMinYMargin; [v addSubview:_rows]; [_tools addObject:_rows];
    NSTextField *cl = [NSTextField labelWithString:N2L(@"欄")];
    cl.frame = NSMakeRect(x + 58, y + 4, 20, 18); cl.autoresizingMask = NSViewMinYMargin; [v addSubview:cl];
    _cols = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 78, y + 2, 34, 22)];
    _cols.stringValue = @"3"; _cols.autoresizingMask = NSViewMinYMargin; [v addSubview:_cols]; [_tools addObject:_cols];
    x += 118;
    [self tool:@"插入表格" symbol:nil at:NSMakeRect(x, y, 90, 26) action:@selector(insertTable:)]; x += 94;
    [self tool:@"新增列" symbol:nil at:NSMakeRect(x, y, 70, 26) action:@selector(addRow:)]; x += 72;
    [self tool:@"刪除列" symbol:nil at:NSMakeRect(x, y, 70, 26) action:@selector(deleteRow:)]; x += 72;
    [self tool:@"新增欄" symbol:nil at:NSMakeRect(x, y, 70, 26) action:@selector(addColumn:)]; x += 72;
    [self tool:@"刪除欄" symbol:nil at:NSMakeRect(x, y, 70, 26) action:@selector(deleteColumn:)]; x += 76;
    [self tool:@"貼上純文字" symbol:nil at:NSMakeRect(x, y, 100, 26) action:@selector(pastePlain:)];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;   // 不留下 Cookie、快取
    cfg.suppressesIncrementalRendering = YES;
    _web = [[WKWebView alloc] initWithFrame:NSMakeRect(12, 52, NSWidth(v.bounds) - 24, top - 52 - 82) configuration:cfg];
    _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _web.navigationDelegate = self;
    [v addSubview:_web];

    _status = [NSTextField labelWithString:@""];
    _status.frame = NSMakeRect(14, 20, NSWidth(v.bounds) - 250, 18);
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    _status.textColor = NSColor.secondaryLabelColor;
    _status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [v addSubview:_status];
    NSButton *cancel = [NSButton buttonWithTitle:N2L(@"取消") target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(NSWidth(v.bounds) - 220, 12, 100, 32);
    cancel.keyEquivalent = @"\033";
    cancel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [v addSubview:cancel];
    _ok = [NSButton buttonWithTitle:N2L(@"確定") target:self action:@selector(confirm:)];
    _ok.frame = NSMakeRect(NSWidth(v.bounds) - 114, 12, 100, 32);
    _ok.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    _ok.enabled = NO;
    [v addSubview:_ok];
    [self enableTools:NO];
    _status.stringValue = N2L(@"正在準備排版畫布…");
}

- (void)enableTools:(BOOL)on { for (NSControl *c in _tools) c.enabled = on; }

static NSString *RegionId(size_t i) { return [NSString stringWithFormat:@"n2xs-edit-%zu", i]; }

// 畫布：可編輯區塊＋受保護內容的標示；CSP 禁止載入任何外部資源
- (void)loadCanvas {
    NSMutableString *html = [NSMutableString stringWithString:
        @"<!doctype html><html><head><meta charset=\"utf-8\">"
        @"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'\">"
        @"<style>body{margin:18px;color:#1b2430;font:15px -apple-system,'PingFang TC',sans-serif;}"
        @".region{min-height:1.35em;border-left:2px solid #dbe3eb;padding:2px 8px;margin:3px 0;}"
        @".region:focus{border-left-color:#246bb1;outline:1px solid #b8d4ed;}"
        @".protected{padding:4px 8px;color:#526275;background:#f3f5f7;margin:3px 0;}"
        @"td,th{min-width:2em;border:1px solid #8d9aab;}td:empty,th:empty{height:1em;}"
        @"@media (prefers-color-scheme: dark){body{background:#1e1e1e;color:#e6e6e6}.protected{background:#2a2d31;color:#9aa7b5}}</style>"
        @"</head><body>"];
    NSString *protectedText = S(escapeText(W(N2L(@"保留的 HTML 內容"))));
    for (const auto &piece : _layout.pieces) {
        if (!piece.tag.empty()) {
            [html appendFormat:@"<div class=\"protected\" contenteditable=\"false\">%@ · %@</div>", protectedText, S(escapeText(piece.tag))];
            continue;
        }
        const auto &block = _layout.blocks[piece.block];
        [html appendFormat:@"<div class=\"region\" id=\"%@\" data-inline=\"%d\">", RegionId(piece.block), block.inlineOnly ? 1 : 0];
        // 行內文字為主的區塊在畫布上包一層 <p> 方便編輯（data-wrap），擷取時會拿掉，不寫回原始碼
        if (block.inlineRun && !block.inlineOnly) [html appendFormat:@"<p data-wrap=\"1\">%@</p>", block.html.empty() ? @"<br>" : S(block.html)];
        else [html appendString:S(block.html)];
        [html appendString:@"</div>"];
    }
    [html appendFormat:@"<script>%@</script></body></html>", @(kCanvasScript)];
    [_web loadHTMLString:html baseURL:nil];
}

// 畫布載入完成：記下各區塊的初始內容（判斷哪些區塊有改動）
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *js = [NSString stringWithFormat:@"n2enable(%@); n2capture()", _readonly ? @"false" : @"true"];
    [_web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        NSArray *arr = [result isKindOfClass:NSArray.class] ? result : nil;
        if (!arr || arr.count != self->_layout.blocks.size()) { [self fail:N2L(@"無法建立排版畫布。")]; return; }
        self->_baseline.clear();
        for (NSString *h in arr) self->_baseline.push_back(W([h isKindOfClass:NSString.class] ? h : @""));
        self->_ready = YES;
        [self enableTools:!self->_readonly];
        self->_ok.enabled = YES;
        self->_status.stringValue = N2L(self->_readonly ? @"文件唯讀，可以預覽及複製。" : @"先點選內容再排版。版面只顯示可編輯內容與行內樣式。");
    }];
}

// 不允許畫布導覽到其他網址（例如點連結）
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    decisionHandler(action.navigationType == WKNavigationTypeOther && [action.request.URL.absoluteString isEqualToString:@"about:blank"]
                    ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)fail:(NSString *)message {
    _status.stringValue = message;
    _status.textColor = NSColor.systemRedColor;
}

- (void)warn:(NSString *)message {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = N2L(@"排版模式");
    a.informativeText = N2L(message);
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

static NSString *JSString(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:nil];
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

// 執行畫布指令；回傳的錯誤代碼轉成提示
- (void)run:(NSString *)js {
    if (!_ready || _readonly) return;
    [_web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        NSString *code = [result isKindOfClass:NSString.class] ? result : (error ? @"failed" : @"");
        NSDictionary *messages = @{
            @"noregion": @"請先在可編輯區塊中點選或選取文字。",
            @"inline": @"這個區塊只支援行內文字樣式。",
            @"failed": @"無法對目前的選取範圍執行此排版操作。",
            @"nocell": @"請先點選表格裡的儲存格。",
            @"shape": @"列欄操作只支援 40 列、20 欄以內的無合併表格。",
            @"limit": @"表格最少保留一列一欄，最多 40 列、20 欄。",
        };
        if (code.length) [self warn:messages[code] ?: messages[@"failed"]];
    }];
}

- (void)exec:(NSString *)command value:(NSString *)value block:(BOOL)block {
    [self run:[NSString stringWithFormat:@"n2exec(%@, %@, %@)", JSString(command), value ? JSString(value) : @"null", block ? @"true" : @"false"]];
}

- (void)fontChanged:(NSPopUpButton *)p {
    if (p.indexOfSelectedItem > 0) [self exec:@"fontName" value:p.titleOfSelectedItem block:NO];
    [p selectItemAtIndex:0];
}
- (void)sizeChanged:(NSPopUpButton *)p {
    // 七級 HTML 字級（與 Windows 版相同）
    if (p.indexOfSelectedItem > 0) [self exec:@"fontSize" value:[NSString stringWithFormat:@"%ld", (long)p.indexOfSelectedItem] block:NO];
    [p selectItemAtIndex:0];
}
- (void)colorChanged:(NSPopUpButton *)p {
    static NSArray *values = @[@"#000000", @"#555555", @"#AD2433", @"#195297", @"#197649", @"#72428B"];
    if (p.indexOfSelectedItem > 0) [self exec:@"foreColor" value:values[(NSUInteger)p.indexOfSelectedItem - 1] block:NO];
    [p selectItemAtIndex:0];
}
- (void)blockChanged:(NSPopUpButton *)p {
    static NSArray *values = @[@"<p>", @"<h1>", @"<h2>", @"<h3>"];
    if (p.indexOfSelectedItem > 0) [self exec:@"formatBlock" value:values[(NSUInteger)p.indexOfSelectedItem - 1] block:YES];
    [p selectItemAtIndex:0];
}
- (void)bold:(id)s { [self exec:@"bold" value:nil block:NO]; }
- (void)italic:(id)s { [self exec:@"italic" value:nil block:NO]; }
- (void)underline:(id)s { [self exec:@"underline" value:nil block:NO]; }
- (void)alignLeft:(id)s { [self exec:@"justifyLeft" value:nil block:YES]; }
- (void)alignCenter:(id)s { [self exec:@"justifyCenter" value:nil block:YES]; }
- (void)alignRight:(id)s { [self exec:@"justifyRight" value:nil block:YES]; }
- (void)alignJustify:(id)s { [self exec:@"justifyFull" value:nil block:YES]; }
- (void)indent:(id)s { [self exec:@"indent" value:nil block:YES]; }
- (void)outdent:(id)s { [self exec:@"outdent" value:nil block:YES]; }
- (void)bulletList:(id)s { [self exec:@"insertUnorderedList" value:nil block:YES]; }
- (void)numberList:(id)s { [self exec:@"insertOrderedList" value:nil block:YES]; }

- (void)insertTable:(id)sender {
    NSInteger rows = _rows.integerValue, cols = _cols.integerValue;
    if (rows < 1 || cols < 1 || rows > 40 || cols > 20) { [self warn:@"表格最少保留一列一欄，最多 40 列、20 欄。"]; return; }
    [self run:[NSString stringWithFormat:@"n2insertTable(%@)", JSString(S(table((unsigned)rows, (unsigned)cols)))]];
}
- (void)addRow:(id)s { [self run:@"n2tableOp('addrow')"]; }
- (void)deleteRow:(id)s { [self run:@"n2tableOp('delrow')"]; }
- (void)addColumn:(id)s { [self run:@"n2tableOp('addcol')"]; }
- (void)deleteColumn:(id)s { [self run:@"n2tableOp('delcol')"]; }

- (void)pastePlain:(id)sender {
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!text.length) { [self warn:@"剪貼簿沒有可貼上的文字。"]; return; }
    if (text.length > limit) { [self warn:@"HTML 文件超過排版模式的大小上限。"]; return; }
    [self run:[NSString stringWithFormat:@"n2paste(%@)", JSString(text)]];
}

- (void)finish {
    [self.window.sheetParent endSheet:self.window];
    [gLayoutWindows removeObject:self];
}

- (void)cancel:(id)sender { [self finish]; }   // 放棄畫布上的修改

// 確定：把改動的區塊合併回原始碼，整份替換成一次可復原的動作
- (void)confirm:(id)sender {
    if (!_ready) return;
    if (_readonly) { [self finish]; return; }
    _ok.enabled = NO;
    [_web evaluateJavaScript:@"n2capture()" completionHandler:^(id result, NSError *error) {
        self->_ok.enabled = YES;
        NSArray *arr = [result isKindOfClass:NSArray.class] ? result : nil;
        if (!arr || arr.count != self->_layout.blocks.size()) { [self warn:@"排版結果含有不支援的 HTML。請修正後再確定。"]; return; }
        std::vector<std::wstring> edited;
        size_t total = 0;
        for (NSString *h in arr) {
            edited.push_back(W([h isKindOfClass:NSString.class] ? h : @""));
            total += edited.back().size();
        }
        if (total > limit) { [self warn:@"HTML 文件超過排版模式的大小上限。"]; return; }
        if (edited == self->_baseline) { [self finish]; return; }   // 沒有修改：原始碼維持原樣
        std::wstring output;
        try { output = merge(self->_original, self->_layout, self->_baseline, edited); }
        catch (...) { [self warn:@"排版結果含有不支援的 HTML。請修正後再確定。"]; return; }
        NSData *utf8 = [S(output) dataUsingEncoding:NSUTF8StringEncoding];
        std::string bytes((const char *)utf8.bytes, utf8.length);
        if (bytes == self->_bytes) { [self finish]; return; }
        EditorWindowController *ed = self->_editor;
        NSData *now = ed.textAsUTF8;
        BOOL same = ed && now.length == self->_bytes.size() && memcmp(now.bytes, self->_bytes.data(), now.length) == 0;
        if (!same || [ed send:SCI_GETREADONLY] || ed.doc.isCryptoLocked) {
            [self warn:@"主編輯區的文件或編碼已變更，請重新開啟排版模式。"];
            return;
        }
        sptr_t anchor = [ed send:SCI_GETANCHOR], caret = [ed send:SCI_GETCURRENTPOS];
        [ed send:SCI_BEGINUNDOACTION];
        [ed send:SCI_SETTARGETSTART w:0];
        [ed send:SCI_SETTARGETEND w:(uptr_t)self->_bytes.size()];
        [ed send:SCI_REPLACETARGET w:bytes.size() l:(sptr_t)bytes.data()];
        [ed send:SCI_ENDUNDOACTION];
        NSData *after = ed.textAsUTF8;
        if (after.length != bytes.size() || memcmp(after.bytes, bytes.data(), bytes.size()) != 0) {
            [ed send:SCI_UNDO];
            [self warn:@"排版套用失敗，已保留原文。"];
            return;
        }
        sptr_t end = (sptr_t)bytes.size();
        [ed send:SCI_SETSEL w:(uptr_t)MIN(anchor, end) l:MIN(caret, end)];
        [self finish];
    }];
}

@end

void N2ShowHtmlLayout(EditorWindowController *ed) {
    Document *doc = ed.doc;
    if (doc.isCryptoLocked) { [ed showMessage:N2L(@"排版模式") info:N2L(@"已鎖定的加密文件要先解密。")]; return; }
    NSData *d = ed.textAsUTF8;
    if (d.length > limit * 4) { [ed showMessage:N2L(@"排版模式") info:N2L(@"HTML 文件超過排版模式的大小上限。")]; return; }
    std::string bytes((const char *)d.bytes, d.length);
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!text) { [ed showMessage:N2L(@"排版模式") info:N2L(@"文字無法依原文件編碼無損轉換。")]; return; }
    std::wstring original = W(text);
    Layout layout;
    try { layout = project(original); }
    catch (...) {
        [ed showMessage:N2L(@"排版模式") info:N2L(@"無法安全辨識這份 HTML 的標籤結構，原文件未變更。請檢查 HTML。")];
        return;
    }
    BOOL readonly = [ed send:SCI_GETREADONLY] != 0;
    N2HtmlLayoutWindow *w = [[N2HtmlLayoutWindow alloc] initWithEditor:ed text:bytes original:original layout:std::move(layout) readonly:readonly];
    if (!gLayoutWindows) gLayoutWindows = [NSMutableSet set];
    [gLayoutWindows addObject:w];
    [ed.window beginSheet:w.window completionHandler:nil];
}
