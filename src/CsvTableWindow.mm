// 編輯 → 表格模式（CSV／TSV）：解析、儲存格編輯、列／欄增刪與套用沿用 Windows 版 CsvTableCore.h
#import "EditorWindowController.h"
#import "N2Common.h"
#import "Document.h"
#include "CsvTableCore.h"


@interface N2CsvTableWindow : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation N2CsvTableWindow {
    __weak EditorWindowController *_editor;
    std::wstring _source, _eol;
    xs::csv::Table _table;
    xs::csv::Changes _changes;
    wchar_t _delim;
    BOOL _dirty, _readOnly, _parsed;
    NSInteger _activeColumn;
    NSTableView *_tv;
    NSPopUpButton *_delimiter;
    NSButton *_header;
    NSTextField *_status;
    NSArray<NSButton *> *_editButtons;
}

static NSMutableSet *gCsvWindows;

+ (void)showForEditor:(EditorWindowController *)ed {
    N2CsvTableWindow *w = [[N2CsvTableWindow alloc] initWithEditor:ed];
    if (!w) return;
    if (!gCsvWindows) gCsvWindows = [NSMutableSet set];
    [gCsvWindows addObject:w];
    // 表格視窗不超過文件視窗的內容區（含分頁列時可用高度較小），避免底部按鈕被裁掉
    NSSize avail = ed.window.contentLayoutRect.size;
    NSSize want = w.window.frame.size;
    [w.window setContentSize:NSMakeSize(MAX(MIN(want.width, avail.width - 20), w.window.minSize.width),
                                        MAX(MIN(want.height, avail.height - 20), w.window.minSize.height))];
    [ed.window beginSheet:w.window completionHandler:nil];
}

- (instancetype)initWithEditor:(EditorWindowController *)ed {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    win.minSize = NSMakeSize(640, 360);
    if ((self = [super initWithWindow:win])) {
        _editor = ed;
        NSData *u8 = ed.textAsUTF8;
        if (u8.length > xs::csv::maxInputBytes) { [ed showMessage:@"文件超過 16 MiB，無法以表格模式開啟。" info:nil]; return nil; }
        NSString *text = [[NSString alloc] initWithData:u8 encoding:NSUTF8StringEncoding];
        // 解碼失敗不能當成空表格：否則「套用」會把整份文件換成空白表格
        if (!text) { [ed showMessage:@"文件含有無效的文字，無法以表格模式開啟。" info:@"請先用正確的編碼重新載入。"]; return nil; }
        _source = N2ToWide(text);
        int eol = (int)[ed send:SCI_GETEOLMODE];
        _eol = eol == SC_EOL_CRLF ? L"\r\n" : eol == SC_EOL_CR ? L"\r" : L"\n";
        _delim = [ed.doc.fileURL.pathExtension.lowercaseString isEqualToString:@"tsv"] ? L'\t' : L',';
        _readOnly = [ed send:SCI_GETREADONLY] != 0;
        [self build];
        [self reparse];
    }
    return self;
}

- (void)build {
    NSView *v = self.window.contentView;
    NSTextField *l = [NSTextField labelWithString:@"分隔符："];
    l.frame = NSMakeRect(16, 528, 60, 18); l.autoresizingMask = NSViewMinYMargin;
    [v addSubview:l];
    _delimiter = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(76, 522, 110, 26) pullsDown:NO];
    [_delimiter addItemsWithTitles:@[@"逗號 ,", @"Tab", @"分號 ;"]];
    [_delimiter selectItemAtIndex:_delim == L'\t' ? 1 : 0];
    _delimiter.target = self; _delimiter.action = @selector(delimiterChanged:);
    _delimiter.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_delimiter];
    _header = [NSButton checkboxWithTitle:@"第一筆作為標題" target:self action:@selector(headerChanged:)];
    _header.frame = NSMakeRect(196, 526, 140, 20); _header.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_header];
    NSArray *ops = @[@"新增列", @"插入列", @"刪除列", @"新增欄", @"插入欄", @"刪除欄"];
    NSMutableArray *btns = [NSMutableArray array];
    CGFloat x = 344;
    for (NSUInteger i = 0; i < ops.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:ops[i] target:self action:@selector(structure:)];
        b.tag = (NSInteger)i;
        b.frame = NSMakeRect(x, 518, 88, 32);
        b.autoresizingMask = NSViewMinYMargin;
        [v addSubview:b];
        [btns addObject:b];
        x += 90;
    }
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 74, 868, 438)];
    sv.hasVerticalScroller = YES; sv.hasHorizontalScroller = YES; sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    _tv.dataSource = self; _tv.delegate = self;
    _tv.allowsMultipleSelection = YES;
    _tv.usesAlternatingRowBackgroundColors = YES;
    _tv.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    _tv.target = self; _tv.action = @selector(clicked:); _tv.doubleAction = @selector(editCell:);
    sv.documentView = _tv;
    [v addSubview:sv];
    _status = [NSTextField labelWithString:@""];
    _status.frame = NSMakeRect(16, 50, 868, 18);
    _status.textColor = NSColor.secondaryLabelColor;
    _status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [v addSubview:_status];
    NSButton *edit = [NSButton buttonWithTitle:@"編輯儲存格" target:self action:@selector(editCell:)];
    edit.frame = NSMakeRect(16, 12, 110, 32);
    NSButton *copy = [NSButton buttonWithTitle:@"拷貝選取列" target:self action:@selector(copyRows:)];
    copy.frame = NSMakeRect(130, 12, 110, 32);
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(686, 12, 96, 32); cancel.keyEquivalent = @"\033"; cancel.autoresizingMask = NSViewMinXMargin;
    NSButton *apply = [NSButton buttonWithTitle:@"套用" target:self action:@selector(apply:)];
    apply.frame = NSMakeRect(788, 12, 96, 32); apply.autoresizingMask = NSViewMinXMargin;
    for (NSView *b in @[edit, copy, cancel, apply]) [v addSubview:b];
    _editButtons = [btns arrayByAddingObjectsFromArray:@[edit, apply]];
}

- (size_t)headerRows { return _header.state == NSControlStateValueOn && !_table.rows.empty() ? 1 : 0; }

- (void)reparse {
    try {
        _table = xs::csv::parse(_source, _delim);
        _parsed = YES;
    } catch (const xs::csv::ParseError &e) {
        _table = xs::csv::Table();
        _parsed = NO;
        NSString *why = e.kind == xs::csv::ErrorKind::Nul ? @"內容含有 NUL 字元，不支援。"
                      : e.kind == xs::csv::ErrorKind::Limit ? @"超過表格大小上限。"
                      : [NSString stringWithFormat:@"格式錯誤：第 %zu 筆、第 %zu 欄（可試著改選分隔符）。", e.row, e.column];
        _status.stringValue = why;
        _status.textColor = NSColor.systemRedColor;
    }
    [self rebuildColumns];
}

- (void)rebuildColumns {
    while (_tv.tableColumns.count) [_tv removeTableColumn:_tv.tableColumns.lastObject];
    size_t header = self.headerRows;
    for (size_t c = 0; c < _table.columns; c++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%zu", c]];
        NSString *title = header ? N2FromWide(xs::csv::displayed(_table, _changes, 0, c)) : @"";
        col.title = title.length ? title : [NSString stringWithFormat:@"欄 %zu", c + 1];
        col.width = 140;
        [_tv addTableColumn:col];
    }
    [_tv reloadData];
    [self updateStatus];
}

- (void)updateStatus {
    BOOL locked = !_changes.empty() || _dirty;
    _delimiter.enabled = !locked;   // 有待套用的修改時鎖定分隔符，避免重新解析遺失編輯
    for (NSButton *b in _editButtons) b.enabled = !_readOnly && _parsed;
    if (!_parsed) return;
    _status.textColor = NSColor.secondaryLabelColor;
    NSMutableString *s = [NSMutableString stringWithFormat:@"%zu 筆資料、%zu 欄　作用欄：%ld",
                          _table.rows.size() - self.headerRows, _table.columns, (long)_activeColumn + 1];
    if (_table.uneven) [s appendString:@"　（各筆欄位數不一致，缺少的欄位以空白顯示）"];
    if (!_changes.empty()) [s appendFormat:@"　待套用的儲存格：%zu", _changes.size()];
    if (_readOnly) [s appendString:@"　（文件唯讀，只能查看與拷貝）"];
    _status.stringValue = s;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)(_table.rows.size() - self.headerRows); }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    size_t r = (size_t)row + self.headerRows, c = (size_t)col.identifier.integerValue;
    NSString *s = N2FromWide(xs::csv::displayed(_table, _changes, r, c));
    // 表格內換行／Tab 以空白顯示，完整內容在編輯視窗
    return [[s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n\t"]] componentsJoinedByString:@" "];
}

- (void)clicked:(id)sender {
    if (_tv.clickedColumn >= 0) { _activeColumn = _tv.clickedColumn; [self updateStatus]; }
}

- (void)delimiterChanged:(id)sender {
    _delim = _delimiter.indexOfSelectedItem == 1 ? L'\t' : _delimiter.indexOfSelectedItem == 2 ? L';' : L',';
    [self reparse];
}
- (void)headerChanged:(id)sender { [self rebuildColumns]; }

- (void)editCell:(id)sender {
    NSInteger row = sender == _tv ? _tv.clickedRow : _tv.selectedRow;
    NSInteger col = sender == _tv ? _tv.clickedColumn : _activeColumn;
    if (row < 0 || col < 0 || (NSUInteger)col >= _tv.tableColumns.count) return;
    size_t r = (size_t)row + self.headerRows, c = (size_t)col;
    if (c >= _table.rows[r].size()) { NSBeep(); return; }   // 不整齊資料中不存在的欄位
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"第 %ld 筆、%@", (long)row + 1, _tv.tableColumns[(NSUInteger)col].title];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 460, 200)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.richText = NO;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.string = N2FromWide(xs::csv::displayed(_table, _changes, r, c));
    tv.editable = !_readOnly;
    sv.documentView = tv;
    a.accessoryView = sv;
    [a addButtonWithTitle:_readOnly ? @"關閉" : @"確定"];
    if (!_readOnly) [a addButtonWithTitle:@"取消"];
    [a addButtonWithTitle:@"拷貝內容"];
    a.window.initialFirstResponder = tv;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn && !self->_readOnly) {
            xs::csv::stage(self->_table, self->_changes, r, c, N2ToWide(tv.string));
            [self rebuildColumns];
        } else if ((self->_readOnly && resp == NSAlertSecondButtonReturn) || resp == NSAlertThirdButtonReturn) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:tv.string forType:NSPasteboardTypeString];
        }
    }];
}

- (void)structure:(NSButton *)sender {
    using K = xs::csv::StructureKind;
    static const K kinds[] = {K::AddRow, K::InsertRow, K::DeleteRows, K::AddColumn, K::InsertColumn, K::DeleteColumn};
    xs::csv::StructureAction act;
    act.kind = kinds[sender.tag];
    size_t header = self.headerRows;
    if (act.kind == K::InsertRow) act.index = _tv.selectedRow >= 0 ? (size_t)_tv.selectedRow + header : _table.rows.size();
    else if (act.kind == K::DeleteRows) {
        NSIndexSet *sel = _tv.selectedRowIndexes;
        if (!sel.count) { NSBeep(); return; }
        for (NSUInteger i = sel.firstIndex; i != NSNotFound; i = [sel indexGreaterThanIndex:i]) act.selectedRows.push_back(i + header);
    } else if (act.kind == K::InsertColumn || act.kind == K::DeleteColumn) {
        if (_table.columns == 0) { NSBeep(); return; }
        act.index = (size_t)MIN(MAX(_activeColumn, 0), (NSInteger)_table.columns - 1);
    }
    try {
        _source = xs::csv::restructure(_source, _table, _changes, _delim, _eol, act);
        _changes.clear();
        _dirty = YES;
        BOOL hadHeader = header > 0;
        [self reparse];
        if (hadHeader && _table.rows.empty()) _header.state = NSControlStateValueOff;
        if (act.kind == K::AddRow) [_tv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)MAX(0, _tv.numberOfRows - 1)] byExtendingSelection:NO];
    } catch (const std::exception &e) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"無法執行這個操作（可能超過表格大小上限）。";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (void)copyRows:(id)sender {
    NSIndexSet *sel = _tv.selectedRowIndexes;
    if (!sel.count) { NSBeep(); return; }
    std::wstring out;
    for (NSUInteger i = sel.firstIndex; i != NSNotFound; i = [sel indexGreaterThanIndex:i]) {
        size_t r = i + self.headerRows;
        for (size_t c = 0; c < _table.rows[r].size(); c++) {
            if (c) out += L'\t';
            xs::csv::appendField(out, xs::csv::displayed(_table, _changes, r, c), L'\t');
        }
        out += L"\r\n";
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:N2FromWide(out) forType:NSPasteboardTypeString];
}

- (void)finish {
    [self.window.sheetParent endSheet:self.window];
    [gCsvWindows removeObject:self];
}

- (void)cancel:(id)sender { [self finish]; }

// 套用：整份資料一次回寫編輯區（一次復原）；有修改時全部欄位統一加雙引號
- (void)apply:(id)sender {
    EditorWindowController *ed = _editor;
    if (!ed || _readOnly || (!_dirty && _changes.empty())) { [self finish]; return; }
    std::wstring final;
    try { final = _changes.empty() ? _source : xs::csv::applyChanges(_source, _table, _changes, _delim); }
    catch (const std::exception &) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"套用失敗，原文沒有修改。";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    std::string bytes = N2FromWide(final).UTF8String;
    [ed send:SCI_BEGINUNDOACTION];
    [ed send:SCI_SETTARGETSTART w:0];
    [ed send:SCI_SETTARGETEND w:(uptr_t)[ed send:SCI_GETLENGTH]];
    [ed send:SCI_REPLACETARGET w:bytes.size() l:(sptr_t)bytes.data()];
    [ed send:SCI_ENDUNDOACTION];
    [self finish];
}

@end

@implementation EditorWindowController (CsvTable)

- (IBAction)showCsvTable:(id)sender {
    NSString *ext = self.doc.fileURL.pathExtension.lowercaseString;
    if (!([ext isEqualToString:@"csv"] || [ext isEqualToString:@"tsv"]) || self.doc.isCryptoLocked) {
        [self showMessage:@"表格模式只適用於已開啟的 .csv／.tsv 檔案。" info:@"加密的 CSV 需要先解密。"];
        return;
    }
    [N2CsvTableWindow showForEditor:self];
}

@end
