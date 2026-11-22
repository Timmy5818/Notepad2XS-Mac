#import "ResultWindow.h"
#import "N2Common.h"
#include <memory>


@interface N2ResultWindow () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@interface N2ExportFormatHelper : NSObject
@property (nonatomic, weak) NSSavePanel *panel;
@property (nonatomic, copy) NSArray<NSString *> *exts;
@end

@implementation N2ExportFormatHelper
- (void)formatChanged:(NSPopUpButton *)sender {
    NSString *name = self.panel.nameFieldStringValue;
    NSString *base = name.stringByDeletingPathExtension.length ? name.stringByDeletingPathExtension : name;
    self.panel.nameFieldStringValue = [base stringByAppendingPathExtension:self.exts[(NSUInteger)sender.indexOfSelectedItem]];
}
@end

@implementation N2ResultWindow {
    std::shared_ptr<xs::SqlReport> _report;
    size_t _set;
    std::vector<size_t> _rows;   // 篩選、排序後顯示的列索引
    NSTableView *_table;
    NSPopUpButton *_sets;
    NSSearchField *_search;
    NSTextField *_header, *_status;
    NSTextView *_notes;
}

static NSMutableSet *gResultWindows;

+ (void)showReport:(const xs::SqlReport &)report {
    N2ResultWindow *w = [[N2ResultWindow alloc] initWithReport:report];
    if (!gResultWindows) gResultWindows = [NSMutableSet set];
    [gResultWindows addObject:w];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)initWithReport:(const xs::SqlReport &)report {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:YES];
    win.minSize = NSMakeSize(560, 360);
    win.title = N2FromU16(report.title);
    if ((self = [super initWithWindow:win])) {
        _report = std::make_shared<xs::SqlReport>(report);
        [self build];
        [self selectSet:0];
        [win center];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(closed:)
                                                     name:NSWindowWillCloseNotification object:win];
    }
    return self;
}

- (void)closed:(NSNotification *)n {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    dispatch_async(dispatch_get_main_queue(), ^{ [gResultWindows removeObject:self]; });
}

- (void)build {
    NSView *v = self.window.contentView;
    const xs::SqlReport &r = *_report;
    _header = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"%@：%@　　開始：%@　　狀態：%@　　耗時：%lld ms　　讀取：%llu 筆",
        N2FromU16(r.sourceLabel), N2FromU16(r.dsn), N2FromU16(r.started), N2FromUTF8(xs::sqlStatusName(r.status)), (long long)r.elapsedMs, (unsigned long long)r.rowCount]];
    _header.frame = NSMakeRect(16, 566, 868, 20);
    _header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [v addSubview:_header];

    _sets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 532, 240, 26) pullsDown:NO];
    _sets.autoresizingMask = NSViewMinYMargin;
    for (size_t i = 0; i < r.sets.size(); i++) {
        const auto &s = r.sets[i];
        [_sets addItemWithTitle:s.table ? [NSString stringWithFormat:@"結果集 %zu（%zu 列）", i + 1, s.rows.size()]
                                        : [NSString stringWithFormat:@"結果 %zu（影響 %lld 筆）", i + 1, (long long)s.affected.value_or(0)]];
    }
    if (r.sets.empty()) [_sets addItemWithTitle:@"（沒有結果）"];
    _sets.target = self; _sets.action = @selector(setChanged:);
    [v addSubview:_sets];
    _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(262, 534, 260, 22)];
    _search.placeholderString = @"篩選（任一欄位包含）";
    _search.delegate = self;
    _search.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_search];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 150, 868, 374)];
    sv.hasVerticalScroller = YES; sv.hasHorizontalScroller = YES; sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _table = [[NSTableView alloc] initWithFrame:sv.bounds];
    _table.dataSource = self; _table.delegate = self;
    _table.allowsMultipleSelection = YES;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    _table.target = self; _table.doubleAction = @selector(showCell:);
    sv.documentView = _table;
    [v addSubview:sv];

    _status = [NSTextField labelWithString:@""];
    _status.frame = NSMakeRect(16, 126, 600, 18);
    _status.textColor = NSColor.secondaryLabelColor;
    _status.autoresizingMask = NSViewMaxYMargin;
    [v addSubview:_status];

    NSScrollView *ns = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 52, 868, 68)];
    ns.hasVerticalScroller = YES; ns.borderType = NSBezelBorder;
    ns.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _notes = [[NSTextView alloc] initWithFrame:ns.bounds];
    _notes.editable = NO;
    _notes.font = [NSFont userFixedPitchFontOfSize:11];
    _notes.string = N2FromUTF8(r.notes);
    ns.documentView = _notes;
    [v addSubview:ns];

    NSArray *buttons = @[@[@"拷貝選取列", @"copyRows:"], @[@"拷貝完整記錄", @"copyAll:"], @[@"匯出…", @"exportReport:"]];
    CGFloat x = 16;
    for (NSArray *b in buttons) {
        NSButton *btn = [NSButton buttonWithTitle:b[0] target:self action:NSSelectorFromString(b[1])];
        btn.frame = NSMakeRect(x, 12, 130, 32);
        [v addSubview:btn];
        x += 136;
    }
}

- (const xs::SqlResultSet *)currentSet {
    return _set < _report->sets.size() ? &_report->sets[_set] : nullptr;
}

- (void)setChanged:(id)sender { [self selectSet:(size_t)MAX(0, _sets.indexOfSelectedItem)]; }

- (void)selectSet:(size_t)index {
    _set = index;
    while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];
    const xs::SqlResultSet *s = self.currentSet;
    if (s && s->table) {
        for (size_t c = 0; c < s->columns.size(); c++) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%zu", c]];
            col.title = N2FromU16(s->columns[c]);
            col.width = 140;
            col.minWidth = 40;
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:col.identifier ascending:YES];
            [_table addTableColumn:col];
        }
    }
    [self refilter];
}

- (NSString *)cell:(size_t)row col:(size_t)col preview:(BOOL)preview {
    const xs::SqlResultSet *s = self.currentSet;
    if (!s || row >= s->rows.size() || col >= s->rows[row].size()) return @"";
    return N2FromU16(xs::sqlDisplayCell(s->rows[row][col], preview));
}

- (void)refilter {
    _rows.clear();
    const xs::SqlResultSet *s = self.currentSet;
    NSString *q = _search.stringValue;
    if (s) {
        for (size_t r = 0; r < s->rows.size(); r++) {
            if (q.length) {
                BOOL hit = NO;
                for (size_t c = 0; c < s->rows[r].size() && !hit; c++)
                    hit = [[self cell:r col:c preview:NO] localizedCaseInsensitiveContainsString:q];
                if (!hit) continue;
            }
            _rows.push_back(r);
        }
    }
    NSSortDescriptor *sd = _table.sortDescriptors.firstObject;
    if (sd && s) {
        size_t col = (size_t)sd.key.integerValue;
        BOOL asc = sd.ascending;
        std::stable_sort(_rows.begin(), _rows.end(), [&](size_t a, size_t b) {
            NSComparisonResult c = [[self cell:a col:col preview:NO] localizedStandardCompare:[self cell:b col:col preview:NO]];
            return asc ? c == NSOrderedAscending : c == NSOrderedDescending;
        });
    }
    [_table reloadData];
    if (!s) _status.stringValue = @"";
    else if (!s->table) _status.stringValue = [NSString stringWithFormat:@"異動指令：影響 %lld 筆", (long long)s->affected.value_or(0)];
    else _status.stringValue = [NSString stringWithFormat:@"顯示 %zu / %zu 列（雙擊儲存格看完整內容；點欄名排序）", _rows.size(), s->rows.size()];
}

- (void)controlTextDidChange:(NSNotification *)n { [self refilter]; }
- (void)tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray *)old { [self refilter]; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_rows.size(); }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    return [self cell:_rows[(size_t)row] col:(size_t)col.identifier.integerValue preview:YES];
}

- (void)showCell:(id)sender {
    NSInteger row = _table.clickedRow, col = _table.clickedColumn;
    if (row < 0 || col < 0) return;
    NSString *full = [self cell:_rows[(size_t)row] col:(size_t)_table.tableColumns[col].identifier.integerValue preview:NO];
    NSAlert *a = [NSAlert new];
    a.messageText = _table.tableColumns[col].title;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
    sv.hasVerticalScroller = YES;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.editable = NO;
    tv.string = full;
    sv.documentView = tv;
    a.accessoryView = sv;
    [a addButtonWithTitle:@"關閉"];
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)copyString:(NSString *)s {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

- (void)copyRows:(id)sender {
    const xs::SqlResultSet *s = self.currentSet;
    if (!s || !_table.selectedRowIndexes.count) { NSBeep(); return; }
    std::vector<size_t> indices;
    NSIndexSet *sel = _table.selectedRowIndexes;
    for (NSUInteger i = sel.firstIndex; i != NSNotFound; i = [sel indexGreaterThanIndex:i]) indices.push_back(_rows[i]);
    std::string out;
    xs::copySqlRows(*s, indices, [&](const std::string &chunk) { out += chunk; });
    [self copyString:N2FromUTF8(out)];
}

- (void)copyAll:(id)sender {
    std::string out;
    xs::exportSqlReport(*_report, false, [&](const std::string &chunk) { out += chunk; });
    [self copyString:N2FromUTF8(out)];
}

// 與檔案搜尋的 csvCell 相同：第一個非空白字元是 = + - @ 時加上 '，避免 Excel 把儲存格當成公式執行
static NSString *Delimited(NSString *s, NSString *sep) {
    NSRange first = [s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet];
    if (first.location != NSNotFound && [@"=+-@" rangeOfString:[s substringWithRange:first]].location != NSNotFound)
        s = [@"'" stringByAppendingString:s];
    BOOL quote = [s rangeOfString:sep].location != NSNotFound || [s rangeOfString:@"\""].location != NSNotFound ||
                 [s rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound;
    if (!quote) return s;
    return [NSString stringWithFormat:@"\"%@\"", [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

- (void)exportReport:(id)sender {
    NSSavePanel *p = [NSSavePanel savePanel];
    NSPopUpButton *fmt = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 260, 26) pullsDown:NO];
    [fmt addItemsWithTitles:@[@"CSV（目前表格）", @"TSV（目前表格）", @"HTML（完整記錄）", @"TXT（完整記錄）"]];
    NSArray *exts = @[@"csv", @"tsv", @"html", @"txt"];
    NSString *prefix = N2FromU16(_report->exportPrefix);
    unsigned rnd = arc4random_uniform(900000000) + 100000000;
    p.nameFieldStringValue = [NSString stringWithFormat:@"%u_%@_log.csv", rnd, prefix];
    p.accessoryView = fmt;
    p.allowsOtherFileTypes = YES;
    // 切換格式時立即更新檔名的副檔名：讓儲存視窗對「實際要寫入的檔名」做覆寫確認
    N2ExportFormatHelper *helper = [N2ExportFormatHelper new];
    helper.panel = p;
    helper.exts = exts;
    fmt.target = helper;
    fmt.action = @selector(formatChanged:);
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        (void)helper;   // 讓 helper 活到視窗關閉
        if (r != NSModalResponseOK) return;
        NSInteger f = fmt.indexOfSelectedItem;
        NSURL *target = p.URL;   // 儲存視窗已確認過覆寫的路徑，不再自行改名
        NSMutableData *data = [NSMutableData data];
        if (f >= 2) {
            xs::exportSqlReport(*self->_report, f == 2, [&](const std::string &chunk) { [data appendBytes:chunk.data() length:chunk.size()]; });
        } else {
            const xs::SqlResultSet *s = self.currentSet;
            NSString *sep = f == 0 ? @"," : @"\t";
            NSMutableString *out = [NSMutableString stringWithString:@"﻿"];   // BOM：Excel 才會用 UTF-8 開啟
            if (s && s->table) {
                NSMutableArray *h = [NSMutableArray array];
                for (auto &c : s->columns) [h addObject:Delimited(N2FromU16(c), sep)];
                [out appendFormat:@"%@\r\n", [h componentsJoinedByString:sep]];
                for (size_t r : self->_rows) {
                    NSMutableArray *cells = [NSMutableArray array];
                    for (size_t c = 0; c < s->columns.size(); c++) [cells addObject:Delimited([self cell:r col:c preview:NO], sep)];
                    [out appendFormat:@"%@\r\n", [cells componentsJoinedByString:sep]];
                }
            }
            [data appendData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        }
        NSError *err = nil;
        if (![data writeToURL:target options:NSDataWritingAtomic error:&err]) [self presentError:err];
    }];
}

@end
