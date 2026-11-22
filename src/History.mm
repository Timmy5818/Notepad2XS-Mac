#import "History.h"
#import "Settings.h"
#import "Document.h"
#import "PreferencesWindow.h"
#import <CommonCrypto/CommonDigest.h>
#include <atomic>

@implementation N2HistoryEntry
@end

// 每個完整路徑一個資料夾：路徑的 SHA-256 前 16 位＋檔名，避免同名不同資料夾混在一起
NSString *N2HistoryDirectory(NSURL *target) {
    NSString *path = target.URLByStandardizingPath.path;
    NSData *d = [path dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", h[i]];
    return [N2Settings.historyFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", hex, target.lastPathComponent]];
}

static NSError *HErr(NSString *msg, NSString *detail) {
    return [NSError errorWithDomain:@"Notepad2XS.History" code:1 userInfo:@{
        NSLocalizedDescriptionKey: msg, NSLocalizedRecoverySuggestionErrorKey: detail ?: @"版本歷史備份失敗時不會覆蓋原檔。"}];
}

BOOL N2HistoryBackup(NSURL *target, NSError **error) {
    if (!N2Settings.historyEnabled || !target.isFileURL) return YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    if (![fm fileExistsAtPath:target.path isDirectory:&dir] || dir) return YES;   // 第一次寫入：沒有舊檔可備份
    NSString *folder = N2HistoryDirectory(target);
    NSError *e = nil;
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&e]) {
        if (error) *error = HErr(@"無法建立版本歷史資料夾，已停止儲存。", e.localizedDescription);
        return NO;
    }
    [target.path writeToFile:[folder stringByAppendingPathComponent:@"source.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // 名稱：時間＋遞增序號＋隨機尾碼，同一毫秒連續儲存也不會撞名
    static std::atomic<unsigned> seq{0};
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *name = [NSString stringWithFormat:@"%@_%04u_%04x.n2xsrev", [f stringFromDate:NSDate.date], seq++ % 10000, arc4random_uniform(0x10000)];
    NSString *dest = [folder stringByAppendingPathComponent:name];
    if (![fm copyItemAtPath:target.path toPath:dest error:&e]) {
        if (error) *error = HErr(@"版本歷史備份失敗，已停止儲存。", e.localizedDescription);
        return NO;
    }
    return YES;
}

NSArray<N2HistoryEntry *> *N2HistoryList(NSURL *target) {
    NSString *folder = N2HistoryDirectory(target);
    NSMutableArray *list = [NSMutableArray array];
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil]) {
        if (![n hasSuffix:@".n2xsrev"] || n.length < 19) continue;
        N2HistoryEntry *e = [N2HistoryEntry new];
        e.path = [folder stringByAppendingPathComponent:n];
        e.date = [f dateFromString:[n substringToIndex:19]] ?: NSDate.distantPast;
        e.size = [[NSFileManager.defaultManager attributesOfItemAtPath:e.path error:nil] fileSize];
        [list addObject:e];
    }
    [list sortUsingComparator:^NSComparisonResult(N2HistoryEntry *a, N2HistoryEntry *b) {
        return [b.path.lastPathComponent compare:a.path.lastPathComponent];   // 名稱以時間開頭，倒序＝最新在前
    }];
    return list;
}

void N2HistoryPrune(NSURL *target) {
    if (!N2Settings.historyEnabled) return;
    NSArray *list = N2HistoryList(target);
    NSInteger keep = N2Settings.historyKeep;
    for (NSInteger i = keep; i < (NSInteger)list.count; i++)
        [NSFileManager.defaultManager removeItemAtPath:[list[(NSUInteger)i] path] error:nil];
}

#pragma mark - 版本歷史視窗

@interface N2HistoryWindow () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation N2HistoryWindow {
    __weak Document *_doc;
    NSURL *_target;
    NSArray<N2HistoryEntry *> *_list;
    NSTableView *_table;
    NSTextField *_info;
    NSDateFormatter *_fmt;
}

+ (void)showForDocument:(Document *)doc {
    static N2HistoryWindow *w;
    if (!w) w = [N2HistoryWindow new];
    w->_doc = doc;
    w->_target = doc.archiveLink ? nil : doc.fileURL;
    [w reload:nil];
    [w showWindow:nil];
    [w.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 380)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    win.title = @"版本歷史";
    if ((self = [super initWithWindow:win])) {
        _fmt = [NSDateFormatter new];
        _fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
        NSView *v = win.contentView;
        _info = [NSTextField wrappingLabelWithString:@""];
        _info.frame = NSMakeRect(16, 338, 528, 32);
        _info.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [v addSubview:_info];
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 56, 400, 276)];
        sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
        sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _table = [[NSTableView alloc] initWithFrame:sv.bounds];
        NSTableColumn *t = [[NSTableColumn alloc] initWithIdentifier:@"date"]; t.title = @"備份時間"; t.width = 220;
        NSTableColumn *s = [[NSTableColumn alloc] initWithIdentifier:@"size"]; s.title = @"大小"; s.width = 140;
        [_table addTableColumn:t]; [_table addTableColumn:s];
        _table.dataSource = self; _table.delegate = self;
        _table.target = self; _table.doubleAction = @selector(openCopy:);
        sv.documentView = _table;
        [v addSubview:sv];
        NSArray *buttons = @[@[@"開啟複本", @"openCopy:"], @[@"還原至編輯區", @"restore:"], @[@"開啟備份資料夾", @"openFolder:"],
                             @[@"重新整理", @"reload:"], @[@"設定…", @"settings:"]];
        CGFloat y = 300;
        for (NSArray *b in buttons) {
            NSButton *btn = [NSButton buttonWithTitle:b[0] target:self action:NSSelectorFromString(b[1])];
            btn.frame = NSMakeRect(424, y, 126, 32);
            btn.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
            [v addSubview:btn];
            y -= 38;
        }
        [win center];
    }
    return self;
}

- (void)reload:(id)sender {
    _list = _target ? N2HistoryList(_target) : @[];
    if (!_target) _info.stringValue = @"這份文件還沒有存成檔案（或是壓縮檔內的文件），沒有版本歷史。";
    else if (!N2Settings.historyEnabled) _info.stringValue = @"版本歷史目前未啟用；可在「設定… → 一般」開啟。以下是先前留下的備份。";
    else _info.stringValue = [NSString stringWithFormat:@"%@：共 %lu 個備份（保留最新 %ld 版）", _target.lastPathComponent,
                              (unsigned long)_list.count, (long)N2Settings.historyKeep];
    [_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)_list.count; }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    N2HistoryEntry *e = _list[(NSUInteger)r];
    if ([c.identifier isEqualToString:@"date"]) return [_fmt stringFromDate:e.date];
    return [NSByteCountFormatter stringFromByteCount:(long long)e.size countStyle:NSByteCountFormatterCountStyleFile];
}

- (N2HistoryEntry *)selected {
    NSInteger r = _table.selectedRow;
    return r >= 0 && r < (NSInteger)_list.count ? _list[(NSUInteger)r] : nil;
}

- (void)openCopy:(id)sender {
    N2HistoryEntry *e = self.selected;
    if (!e) { NSBeep(); return; }
    NSData *raw = [NSData dataWithContentsOfFile:e.path];
    NSError *err = nil;
    Document *copy = [NSDocumentController.sharedDocumentController openUntitledDocumentAndDisplay:NO error:&err];
    if (![copy isKindOfClass:Document.class]) { if (err) [self presentError:err]; return; }
    [copy loadRawData:raw jpeg:[@[@"jpg", @"jpeg"] containsObject:_target.pathExtension.lowercaseString] error:&err];
    [copy makeWindowControllers];
    [copy showWindows];
}

- (void)restore:(id)sender {
    N2HistoryEntry *e = self.selected;
    Document *doc = _doc;
    if (!e || !doc) { NSBeep(); return; }
    NSData *raw = [NSData dataWithContentsOfFile:e.path];
    void (^go)(void) = ^{
        NSError *err = nil;
        if (![doc loadRawData:raw jpeg:[@[@"jpg", @"jpeg"] containsObject:self->_target.pathExtension.lowercaseString] error:&err]) { [self presentError:err]; return; }
        [doc updateChangeCount:NSChangeDone];   // 還原後保持「尚未儲存」，按儲存才寫回磁碟
    };
    if (!doc.isDocumentEdited) { go(); return; }
    NSAlert *a = [NSAlert new];
    a.messageText = @"目前文件有未儲存的修改，要捨棄並還原這個版本嗎？";
    [a addButtonWithTitle:@"還原"];
    [a addButtonWithTitle:@"取消"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { if (r == NSAlertFirstButtonReturn) go(); }];
}

- (void)openFolder:(id)sender {
    NSString *folder = _target ? N2HistoryDirectory(_target) : N2Settings.historyFolder;
    if (![NSFileManager.defaultManager fileExistsAtPath:folder]) folder = N2Settings.historyFolder;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:folder]];
}

- (void)settings:(id)sender { [N2PreferencesWindow.shared showWindow:nil]; }

@end
