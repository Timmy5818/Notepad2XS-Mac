// 檔案 → 搜尋檔案：條件判斷與 CSV 輸出沿用 Windows 版 FileSearchCore.h
#import <Cocoa/Cocoa.h>
#import "N2Common.h"
#include "FileSearchCore.h"
#include <atomic>
#include <memory>

// 與原版相同的時間單位：自 1601 年起的 100 奈秒
static uint64_t Ticks(NSDate *d) { return (uint64_t)((d.timeIntervalSince1970 + 11644473600.0) * 10000000.0); }

@interface N2FoundFile : NSObject
@property (nonatomic, copy) NSString *name, *folder;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong) NSDate *modified;
@end
@implementation N2FoundFile
@end

@interface N2FileSearchWindow : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation N2FileSearchWindow {
    NSPopUpButton *_where, *_date, *_size;
    NSTextField *_names, *_status;
    NSButton *_start, *_stop, *_save;
    NSTableView *_table;
    NSMutableArray<N2FoundFile *> *_results;
    std::shared_ptr<std::atomic<bool>> _cancel;
    BOOL _running;
    NSDateFormatter *_fmt;
}

+ (void)show {
    static N2FileSearchWindow *w;
    if (!w) w = [N2FileSearchWindow new];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:YES];
    win.title = @"搜尋檔案";
    win.minSize = NSMakeSize(700, 360);
    if ((self = [super initWithWindow:win])) {
        _results = [NSMutableArray array];
        _fmt = [NSDateFormatter new];
        _fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
        [self build];
        [win center];
        win.frameAutosaveName = @"Notepad2XSFileSearch";
    }
    return self;
}

static NSTextField *Lbl(NSString *s, NSRect r) { NSTextField *l = [NSTextField labelWithString:s]; l.frame = r; l.autoresizingMask = NSViewMinYMargin; return l; }

- (void)build {
    NSView *v = self.window.contentView;
    [v addSubview:Lbl(@"位置：", NSMakeRect(16, 526, 50, 18))];
    _where = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(64, 520, 220, 26) pullsDown:NO];
    _where.autoresizingMask = NSViewMinYMargin;
    [_where addItemWithTitle:@"家目錄"];
    _where.lastItem.representedObject = NSHomeDirectory();
    [_where addItemWithTitle:@"全部（整台電腦）"];
    _where.lastItem.representedObject = @"/";
    for (NSString *vol in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/Volumes" error:nil]) {
        NSString *p = [@"/Volumes" stringByAppendingPathComponent:vol];
        if ([[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:p error:nil] isEqualToString:@"/"]) continue;   // 開機磁碟的別名
        [_where addItemWithTitle:[NSString stringWithFormat:@"磁碟：%@", vol]];
        _where.lastItem.representedObject = p;
    }
    [v addSubview:_where];
    [v addSubview:Lbl(@"檔名：", NSMakeRect(296, 526, 50, 18))];
    _names = [[NSTextField alloc] initWithFrame:NSMakeRect(344, 522, 240, 24)];
    _names.placeholderString = @"*.xls,*.doc（可用 *，逗號分隔）";
    _names.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_names];
    _date = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(592, 520, 140, 26) pullsDown:NO];
    [_date addItemsWithTitles:@[@"全部日期", @"1 小時內", @"1 日內", @"7 日內", @"30 日內", @"1 年內"]];
    _date.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_date];
    _size = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(736, 520, 148, 26) pullsDown:NO];
    [_size addItemsWithTitles:@[@"全部大小", @"大於 1 MB", @"大於 10 MB", @"大於 100 MB", @"大於 1 GB", @"大於 10 GB"]];
    _size.autoresizingMask = NSViewMinYMargin;
    [v addSubview:_size];

    _start = [NSButton buttonWithTitle:@"開始搜尋" target:self action:@selector(start:)];
    _start.frame = NSMakeRect(12, 482, 110, 32); _start.keyEquivalent = @"\r"; _start.autoresizingMask = NSViewMinYMargin;
    _stop = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    _stop.frame = NSMakeRect(124, 482, 90, 32); _stop.enabled = NO; _stop.autoresizingMask = NSViewMinYMargin;
    _save = [NSButton buttonWithTitle:@"儲存搜尋結果…" target:self action:@selector(saveResults:)];
    _save.frame = NSMakeRect(216, 482, 140, 32); _save.enabled = NO; _save.autoresizingMask = NSViewMinYMargin;
    for (NSView *b in @[_start, _stop, _save]) [v addSubview:b];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 868, 436)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _table = [[NSTableView alloc] initWithFrame:sv.bounds];
    NSArray *cols = @[@[@"name", @"檔名", @240], @[@"size", @"大小", @90], @[@"modified", @"最後修改時間", @150], @[@"folder", @"路徑", @360]];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1]; col.width = [c[2] doubleValue];
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c[0] ascending:YES];
        [_table addTableColumn:col];
    }
    _table.dataSource = self; _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.target = self; _table.doubleAction = @selector(openSelected:);
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:@"開啟（使用 Notepad2XS）" action:@selector(openSelected:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"在 Finder 中顯示" action:@selector(revealSelected:) keyEquivalent:@""].target = self;
    _table.menu = menu;
    sv.documentView = _table;
    [v addSubview:sv];
    _status = [NSTextField labelWithString:@"準備就緒"];
    _status.frame = NSMakeRect(16, 14, 868, 18);
    _status.textColor = NSColor.secondaryLabelColor;
    _status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [v addSubview:_status];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_results.count; }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    N2FoundFile *f = _results[(NSUInteger)row];
    NSString *k = col.identifier;
    if ([k isEqualToString:@"name"]) return f.name;
    if ([k isEqualToString:@"size"]) return [NSByteCountFormatter stringFromByteCount:(long long)f.size countStyle:NSByteCountFormatterCountStyleBinary];
    if ([k isEqualToString:@"modified"]) return [_fmt stringFromDate:f.modified];
    return f.folder;
}
- (void)tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray *)old {
    if (_running) return;   // 搜尋完成或停止後才排序
    [_results sortUsingDescriptors:tv.sortDescriptors];
    [tv reloadData];
}

- (void)setRunning:(BOOL)running {
    _running = running;
    _start.enabled = !running; _stop.enabled = running; _save.enabled = !running && _results.count;
    _where.enabled = _names.enabled = _date.enabled = _size.enabled = !running;
}

- (void)start:(id)sender {
    std::vector<std::wstring> filters = xs::fileSearch::patterns(N2ToWide(_names.stringValue));
    if (filters.empty()) { _status.stringValue = @"檔名條件只支援 * 與逗號，不能包含路徑或 ? : \" < > | 等字元。"; return; }
    [_results removeAllObjects];
    [_table reloadData];
    NSString *root = _where.selectedItem.representedObject;
    int dateChoice = (int)_date.indexOfSelectedItem, sizeChoice = (int)_size.indexOfSelectedItem;
    uint64_t now = Ticks(NSDate.date);   // 時間基準在開始時固定
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    _cancel = cancel;
    [self setRunning:YES];
    _status.stringValue = @"搜尋中…";
    NSDate *t0 = NSDate.date;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSSet *skip = [root isEqualToString:@"/"] ? [NSSet setWithArray:@[@"/System", @"/dev", @"/private/var/vm", @"/Volumes", @"/cores", @"/private/var/db"]] : [NSSet set];
        NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsDirectoryKey]
            options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];   // 無權限的資料夾略過
        NSMutableArray *batch = [NSMutableArray array];
        NSUInteger scanned = 0, found = 0;
        NSDate *lastFlush = NSDate.date;
        auto equal = [](wchar_t a, wchar_t b) { return towlower(a) == towlower(b); };
        for (NSURL *u in en) {
            if (*cancel) break;
            NSDictionary *vals = [u resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLIsDirectoryKey] error:nil];
            if ([vals[NSURLIsDirectoryKey] boolValue]) {
                if ([skip containsObject:u.path]) [en skipDescendants];
                continue;
            }
            if (![vals[NSURLIsRegularFileKey] boolValue]) continue;
            scanned++;
            NSString *name = u.lastPathComponent;
            if (!xs::fileSearch::matchesAny(N2ToWide(name), filters, equal)) continue;
            unsigned long long size = [vals[NSURLFileSizeKey] unsignedLongLongValue];
            NSDate *mod = vals[NSURLContentModificationDateKey] ?: NSDate.distantPast;
            if (!xs::fileSearch::passes(size, Ticks(mod), now, dateChoice, sizeChoice)) continue;
            N2FoundFile *f = [N2FoundFile new];
            f.name = name; f.folder = u.URLByDeletingLastPathComponent.path; f.size = size; f.modified = mod;
            [batch addObject:f];
            if (++found >= 100000) { *cancel = true; break; }
            if (batch.count >= 200 || -lastFlush.timeIntervalSinceNow > 0.25) {
                NSArray *b = [batch copy];
                [batch removeAllObjects];
                lastFlush = NSDate.date;
                NSUInteger s = scanned;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_results addObjectsFromArray:b];
                    [self->_table reloadData];
                    self->_status.stringValue = [NSString stringWithFormat:@"搜尋中…已檢查 %lu 個檔案，找到 %lu 個", (unsigned long)s, (unsigned long)self->_results.count];
                });
            }
        }
        NSArray *b = [batch copy];
        BOOL stopped = *cancel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_results addObjectsFromArray:b];
            [self->_table reloadData];
            [self setRunning:NO];
            self->_status.stringValue = [NSString stringWithFormat:@"%@：找到 %lu 個檔案（耗時 %.1f 秒）%@", stopped ? @"已停止" : @"完成",
                                         (unsigned long)self->_results.count, -t0.timeIntervalSinceNow,
                                         self->_results.count >= 100000 ? @"，已達 100,000 筆上限" : @""];
        });
    });
}

- (void)stop:(id)sender { if (_cancel) *_cancel = true; }

- (NSArray<N2FoundFile *> *)selectedFiles {
    NSMutableArray *a = [NSMutableArray array];
    NSIndexSet *s = _table.clickedRow >= 0 && ![_table.selectedRowIndexes containsIndex:(NSUInteger)_table.clickedRow]
                    ? [NSIndexSet indexSetWithIndex:(NSUInteger)_table.clickedRow] : _table.selectedRowIndexes;
    for (NSUInteger i = s.firstIndex; i != NSNotFound; i = [s indexGreaterThanIndex:i]) [a addObject:_results[i]];
    return a;
}

- (void)openSelected:(id)sender {
    for (N2FoundFile *f in self.selectedFiles) {
        NSURL *u = [NSURL fileURLWithPath:[f.folder stringByAppendingPathComponent:f.name]];
        [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:u display:YES
                                                                   completionHandler:^(NSDocument *d, BOOL a, NSError *e) { if (e) [NSApp presentError:e]; }];
    }
}

- (void)revealSelected:(id)sender {
    NSMutableArray *urls = [NSMutableArray array];
    for (N2FoundFile *f in self.selectedFiles) [urls addObject:[NSURL fileURLWithPath:[f.folder stringByAppendingPathComponent:f.name]]];
    if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}

- (void)saveResults:(id)sender {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"搜尋結果.csv";
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        std::wstring out = L"﻿\"檔名\",\"大小\",\"最後修改時間\",\"路徑\"\r\n";
        for (N2FoundFile *f in self->_results) {
            out += xs::fileSearch::csvCell(N2ToWide(f.name)) + L"," + xs::fileSearch::csvCell(std::to_wstring(f.size)) + L"," +
                   xs::fileSearch::csvCell(N2ToWide([self->_fmt stringFromDate:f.modified])) + L"," + xs::fileSearch::csvCell(N2ToWide(f.folder)) + L"\r\n";
        }
        NSError *e = nil;
        if (![N2FromWide(out) writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:&e]) [self presentError:e];
    }];
}

@end

void N2ShowFileSearch(void) { [N2FileSearchWindow show]; }
