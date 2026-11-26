// 多分頁：使用 macOS 內建的視窗分頁（與 TextEdit／Finder 相同的分頁列）
// - 設定「開啟文件：在分頁中／在新視窗中」決定新文件的開啟方式
// - ⌘T 新增分頁、⌘W 關閉分頁、⌘⇧] ／⌘⇧[ 下一個／上一個分頁（⌃Tab／⌃⇧Tab 也可以）、⌘1～⌘8 切換、⌘9 最後一個分頁
// - 分頁列右側「＋」新增分頁；滑鼠中鍵點分頁可關閉
// - 分頁右鍵選單（對應 Windows 版 R143～R146）：重新載入、在 Finder 中顯示、在新視窗開啟、關閉其他分頁、
//   關閉全部分頁、全部儲存；分頁列空白處右鍵：新增分頁、全部儲存、關閉全部分頁
// - 重新開啟時還原上次的分頁（R142；只還原已存檔的文件）
// - 重新開啟關閉的分頁（R158）：⇧⌘T 或分頁列空白處右鍵，最近關閉的優先，最多記住 32 個
// - 「顯示／隱藏標籤頁列」由系統自動加在「視窗」選單（依 App 的介面語言顯示）
#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"
#import "Localization.h"
#import "ArchiveEdit.h"

static NSString *const kTabbingIdentifier = @"Notepad2XSDocument";

@implementation EditorWindowController (Tabs)

// 建立視窗時呼叫：依設定決定這個新視窗要加入既有視窗的分頁（Preferred），還是獨立開啟（Disallowed）
- (void)setupTabbing {
    self.window.tabbingIdentifier = kTabbingIdentifier;
    self.window.tabbingMode = N2Settings.openInTabs ? NSWindowTabbingModePreferred : NSWindowTabbingModeDisallowed;
}

// 視窗顯示後改回 Automatic：開啟方式已經決定，之後仍可手動拖曳分頁、合併所有視窗
- (void)showWindow:(id)sender {
    [super showWindow:sender];
    self.window.tabbingMode = NSWindowTabbingModeAutomatic;
    [self ensureTabBarShown];
}

// 「永遠顯示分頁列」：只有一個分頁時系統預設會隱藏分頁列，這裡把它打開（含右側「＋」）。
// 視窗顯示、成為作用中視窗（例如分頁被拖出成新視窗）時檢查
- (void)ensureTabBarShown {
    if (!N2Settings.alwaysShowTabBar) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *w = self.window;
        if (w.isVisible && w.tabGroup && !w.tabGroup.isTabBarVisible) [w toggleTabBar:nil];
    });
}

// 分頁列的「＋」與 ⌘T：在目前視窗新增一個空白文件分頁（不受「新視窗」設定影響）
- (IBAction)newWindowForTab:(id)sender {
    NSError *err = nil;
    NSDocument *doc = [NSDocumentController.sharedDocumentController openUntitledDocumentAndDisplay:NO error:&err];
    if (!doc) { if (err) [self.window presentError:err]; return; }
    [doc makeWindowControllers];
    NSWindow *w = doc.windowControllers.firstObject.window;
    if (!w) return;
    w.tabbingMode = NSWindowTabbingModeAutomatic;
    [self.window addTabbedWindow:w ordered:NSWindowAbove];
    [doc showWindows];
    [w makeKeyAndOrderFront:nil];
}

// ⌘1～⌘8 切到第 N 個分頁，⌘9 切到最後一個（與瀏覽器相同）
- (IBAction)selectTabByNumber:(NSMenuItem *)sender {
    NSArray<NSWindow *> *tabs = self.window.tabbedWindows ?: @[self.window];
    NSInteger n = sender.tag;
    NSInteger idx = n >= 9 ? (NSInteger)tabs.count - 1 : n - 1;
    if (idx < 0 || idx >= (NSInteger)tabs.count) { NSBeep(); return; }
    [tabs[(NSUInteger)idx] makeKeyAndOrderFront:nil];
}

#pragma mark - 重新載入、在 Finder 中顯示

// 從磁碟重新讀取；有未儲存的修改時先詢問
- (IBAction)reloadFromDisk:(id)sender {
    Document *doc = self.doc;
    if (!doc.fileURL) { NSBeep(); return; }
    void (^reload)(void) = ^{
        NSError *err = nil;
        if (![doc revertToContentsOfURL:doc.fileURL ofType:doc.fileType error:&err] && err) [self presentError:err];
    };
    if (!doc.isDocumentEdited) { reload(); return; }
    NSAlert *a = [NSAlert new];
    a.messageText = N2L(@"要捨棄未儲存的修改並重新載入嗎？");
    a.informativeText = [NSString stringWithFormat:N2L(@"將從磁碟重新讀取「%@」，目前的修改會遺失。"), doc.displayName];
    [a addButtonWithTitle:N2L(@"重新載入")];
    [a addButtonWithTitle:N2L(@"取消")];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) reload();
    }];
}

// 在 Finder 中顯示檔案（壓縮檔內的文件顯示壓縮檔）；檔案已不在時開啟原資料夾
- (IBAction)revealInFinder:(id)sender {
    Document *doc = self.doc;
    NSURL *url = doc.archiveLink ? doc.archiveLink.archiveURL : doc.fileURL;
    if (!url || N2IsArchiveWorkURL(url)) { NSBeep(); return; }
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        return;
    }
    NSURL *folder = url.URLByDeletingLastPathComponent;
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&isDir] && isDir && [NSWorkspace.sharedWorkspace openURL:folder])
        return;
    [self showMessage:N2L(@"無法開啟檔案路徑。") info:N2L(@"檔案與所在資料夾都已不存在。")];
}

@end

#pragma mark - 關閉多個分頁、全部儲存

// 逐一詢問有修改的文件（儲存／不儲存／取消）；全部確認後才一起關閉，按「取消」則全部保留
@interface N2CloseBatch : NSObject
@property (nonatomic, copy) NSArray<NSDocument *> *documents;
@property (nonatomic, copy) void (^completion)(BOOL confirmed);
@property (nonatomic) NSUInteger index;
@end

@implementation N2CloseBatch
static NSMutableSet *gBatches;   // 處理期間保持存在

+ (void)confirm:(NSArray<NSDocument *> *)docs completion:(void (^)(BOOL))completion {
    N2CloseBatch *b = [N2CloseBatch new];
    b.documents = docs;
    b.completion = completion;
    if (!gBatches) gBatches = [NSMutableSet set];
    [gBatches addObject:b];
    [b next];
}

- (void)finish:(BOOL)ok {
    void (^c)(BOOL) = self.completion;
    [gBatches removeObject:self];
    c(ok);
}

- (void)next {
    while (self.index < self.documents.count) {
        NSDocument *d = self.documents[self.index++];
        if (!d.isDocumentEdited) continue;
        // 先切到這個分頁，讓使用者看得到是哪份文件
        [d.windowControllers.firstObject.window makeKeyAndOrderFront:nil];
        [d canCloseDocumentWithDelegate:self shouldCloseSelector:@selector(document:shouldClose:contextInfo:) contextInfo:NULL];
        return;
    }
    [self finish:YES];
}

- (void)document:(NSDocument *)doc shouldClose:(BOOL)shouldClose contextInfo:(void *)info {
    if (!shouldClose) { [self finish:NO]; return; }
    [self next];
}
@end

// 依序儲存有修改的文件（未命名的文件會出現儲存視窗）；取消或失敗就停止
@interface N2SaveBatch : NSObject
@property (nonatomic, copy) NSArray<NSDocument *> *documents;
@property (nonatomic) NSUInteger index;
@end

@implementation N2SaveBatch
static NSMutableSet *gSaveBatches;

+ (void)saveAll:(NSArray<NSDocument *> *)docs {
    N2SaveBatch *b = [N2SaveBatch new];
    b.documents = docs;
    if (!gSaveBatches) gSaveBatches = [NSMutableSet set];
    [gSaveBatches addObject:b];
    [b next];
}

- (void)next {
    while (self.index < self.documents.count) {
        NSDocument *d = self.documents[self.index++];
        if (!d.isDocumentEdited) continue;
        if (!d.fileURL) [d.windowControllers.firstObject.window makeKeyAndOrderFront:nil];
        [d saveDocumentWithDelegate:self didSaveSelector:@selector(document:didSave:contextInfo:) contextInfo:NULL];
        return;
    }
    [gSaveBatches removeObject:self];
}

- (void)document:(NSDocument *)doc didSave:(BOOL)didSave contextInfo:(void *)info {
    if (!didSave) { [gSaveBatches removeObject:self]; return; }
    [self next];
}
@end

static NSArray<NSDocument *> *DocumentsOf(NSArray<NSWindow *> *windows) {
    NSMutableArray *docs = [NSMutableArray array];
    for (NSWindow *w in windows) {
        NSDocument *d = w.windowController.document;
        if (d && ![docs containsObject:d]) [docs addObject:d];
    }
    return docs;
}

@implementation EditorWindowController (TabCommands)

- (NSArray<NSWindow *> *)tabWindows { return self.window.tabbedWindows ?: @[self.window]; }

// 關閉全部分頁：確認後留下一個空白分頁（與 Windows 版 R143 相同）
- (IBAction)closeAllTabs:(id)sender {
    NSArray *docs = DocumentsOf(self.tabWindows);
    NSWindow *anchor = self.window;
    [N2CloseBatch confirm:docs completion:^(BOOL ok) {
        if (!ok) return;
        // 先在同一個視窗加入空白分頁，再關閉其他分頁，視窗位置與大小維持不變
        NSError *err = nil;
        NSDocument *blank = [NSDocumentController.sharedDocumentController openUntitledDocumentAndDisplay:NO error:&err];
        if (blank) {
            [blank makeWindowControllers];
            NSWindow *w = blank.windowControllers.firstObject.window;
            w.tabbingMode = NSWindowTabbingModeAutomatic;
            [anchor addTabbedWindow:w ordered:NSWindowAbove];
            [blank showWindows];
        }
        for (NSDocument *d in docs) [d close];
    }];
}

// 關閉其他分頁：保留目前分頁
- (IBAction)closeOtherTabs:(id)sender {
    NSMutableArray *others = [NSMutableArray arrayWithArray:self.tabWindows];
    [others removeObject:self.window];
    NSArray *docs = DocumentsOf(others);
    if (!docs.count) { NSBeep(); return; }
    [N2CloseBatch confirm:docs completion:^(BOOL ok) {
        if (!ok) return;
        for (NSDocument *d in docs) [d close];
        [self.window makeKeyAndOrderFront:nil];
    }];
}

@end

// 全部儲存：所有視窗的所有文件
void N2SaveAllDocuments(void) {
    [N2SaveBatch saveAll:NSDocumentController.sharedDocumentController.documents];
}

// 關閉所有文件（Dock 選單「關閉所有分頁」與「恢復應用預設值」使用）
void N2CloseAllDocuments(void (^completion)(BOOL closed)) {
    NSArray *docs = [NSDocumentController.sharedDocumentController.documents copy];
    [N2CloseBatch confirm:docs completion:^(BOOL ok) {
        if (ok) for (NSDocument *d in docs) [d close];
        if (completion) completion(ok);
    }];
}

#pragma mark - 重新開啟時還原分頁

static NSString *const kSessionKey = @"SessionWindows";

// 結束程式時記錄每個視窗的分頁（只記已存檔的文件，壓縮檔內文件與未命名草稿不記）
void N2SaveSession(void) {
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSWindow *w in NSApp.orderedWindows) {
        if (![w.windowController isKindOfClass:EditorWindowController.class] || [seen containsObject:@(w.windowNumber)]) continue;
        NSArray<NSWindow *> *tabs = w.tabbedWindows ?: @[w];
        NSMutableArray *files = [NSMutableArray array];
        NSInteger active = 0;
        for (NSWindow *t in tabs) {
            [seen addObject:@(t.windowNumber)];
            Document *d = (Document *)t.windowController.document;
            NSURL *u = d.fileURL;
            if (!u || d.archiveLink || N2IsArchiveWorkURL(u)) continue;
            if (t == w.tabGroup.selectedWindow || (tabs.count == 1)) active = (NSInteger)files.count;
            [files addObject:u.path];
        }
        if (files.count) [groups addObject:@{@"files": files, @"active": @(active)}];
    }
    [NSUserDefaults.standardUserDefaults setObject:groups forKey:kSessionKey];
}

BOOL N2HasSessionToRestore(void) {
    if (!N2Settings.restoreSession) return NO;
    for (NSDictionary *g in [NSUserDefaults.standardUserDefaults arrayForKey:kSessionKey])
        for (NSString *p in g[@"files"]) if ([NSFileManager.defaultManager fileExistsAtPath:p]) return YES;
    return NO;
}

// 依序開啟記錄的視窗與分頁：每個視窗的第一份文件獨立成視窗，其餘加入它的分頁，最後切到原本作用中的分頁
static void RestoreStep(NSArray<NSDictionary *> *groups, NSUInteger g, NSUInteger f, NSWindow *anchor,
                        NSWindow *activeWindow, BOOL any, void (^done)(BOOL)) {
    if (g >= groups.count) { done(any); return; }
    NSDictionary *group = [groups[g] isKindOfClass:NSDictionary.class] ? groups[g] : @{};
    NSArray *files = [group[@"files"] isKindOfClass:NSArray.class] ? group[@"files"] : @[];
    if (f >= files.count) {
        [activeWindow ?: anchor makeKeyAndOrderFront:nil];
        RestoreStep(groups, g + 1, 0, nil, nil, any, done);
        return;
    }
    BOOL isActive = [group[@"active"] integerValue] == (NSInteger)f;
    NSString *path = [files[f] isKindOfClass:NSString.class] ? files[f] : nil;
    NSURL *url = path ? [NSURL fileURLWithPath:path] : nil;
    NSDocumentController *dc = NSDocumentController.sharedDocumentController;
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:path] || [dc documentForURL:url]) {
        RestoreStep(groups, g, f + 1, anchor, activeWindow, any, done);
        return;
    }
    [dc openDocumentWithContentsOfURL:url display:NO completionHandler:^(NSDocument *doc, BOOL already, NSError *e) {
        NSWindow *first = anchor, *active = activeWindow;
        NSWindow *last = first.tabbedWindows.lastObject ?: first;   // 依記錄順序接在最後一個分頁後面
        BOOL opened = any;
        if (doc && !already) {
            if (!doc.windowControllers.count) [doc makeWindowControllers];
            NSWindow *w = doc.windowControllers.firstObject.window;
            if (first) {
                w.tabbingMode = NSWindowTabbingModeAutomatic;
                [last addTabbedWindow:w ordered:NSWindowAbove];
            } else {
                w.tabbingMode = NSWindowTabbingModeDisallowed;   // 每個記錄的視窗各自獨立
                first = w;
            }
            [doc showWindows];
            if (isActive) active = w;
            opened = YES;
        }
        RestoreStep(groups, g, f + 1, first, active, opened, done);
    }];
}

void N2RestoreSession(void (^done)(BOOL restored)) {
    NSArray *groups = N2Settings.restoreSession ? [NSUserDefaults.standardUserDefaults arrayForKey:kSessionKey] : nil;
    RestoreStep(groups ?: @[], 0, 0, nil, nil, NO, done);
}

#pragma mark - 重新開啟關閉的分頁（R158）

static NSMutableArray<NSDictionary *> *gClosedDocuments;   // {path, member}，最後一個是最近關閉的
static const NSUInteger kClosedLimit = 32;

// 關閉分頁時記錄（已存檔的文件與壓縮檔成員；未命名與雲端文件不記錄）
void N2RememberClosedDocument(Document *doc) {
    NSString *path = nil, *member = nil;
    if (doc.archiveLink) { path = doc.archiveLink.archiveURL.path; member = doc.archiveLink.memberPath; }
    else if (doc.fileURL && !N2IsArchiveWorkURL(doc.fileURL) && !doc.cloud) path = doc.fileURL.path;
    if (!path.length) return;
    if (!gClosedDocuments) gClosedDocuments = [NSMutableArray array];
    if (gClosedDocuments.count == kClosedLimit) [gClosedDocuments removeObjectAtIndex:0];
    [gClosedDocuments addObject:member ? @{@"path": path, @"member": member} : @{@"path": path}];
}

BOOL N2HasClosedDocuments(void) { return gClosedDocuments.count > 0; }

// 每次重開一個：讀取磁碟上最後儲存的版本並沿用 .2xs；已開啟時切換到該分頁；找不到檔案時提示
void N2ReopenClosedDocument(void) {
    if (!gClosedDocuments.count) { NSBeep(); return; }
    NSDictionary *entry = gClosedDocuments.lastObject;
    [gClosedDocuments removeLastObject];
    NSString *path = entry[@"path"], *member = entry[@"member"];
    for (NSDocument *d in NSDocumentController.sharedDocumentController.documents) {
        if (![d isKindOfClass:Document.class]) continue;
        Document *doc = (Document *)d;
        BOOL same = member ? (doc.archiveLink && [doc.archiveLink.archiveURL.path isEqualToString:path] &&
                              [doc.archiveLink.memberPath isEqualToString:member])
                           : (!doc.archiveLink && [doc.fileURL.path isEqualToString:path]);
        if (same) { [doc.editor.window makeKeyAndOrderFront:nil]; return; }
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSAlert *a = [NSAlert new];
        a.alertStyle = NSAlertStyleWarning;
        a.messageText = [NSString stringWithFormat:N2L(@"載入「%@」時發生錯誤。"), path.lastPathComponent];
        a.informativeText = path;
        [a addButtonWithTitle:N2L(@"確定")];
        [a runModal];
        return;
    }
    N2SetRequestedArchiveMember(member);
    [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:path] display:YES
        completionHandler:^(NSDocument *doc, BOOL already, NSError *e) {
        N2SetRequestedArchiveMember(nil);
        if (e) [NSApp presentError:e];
    }];
}

#pragma mark - 分頁列的滑鼠操作（中鍵關閉、右鍵選單）

// 分頁列是系統的私有視圖：從點到的視圖往上找名稱含 "TabButton" 的視圖，
// 再依同一層分頁按鈕的水平位置換算成第幾個分頁（順序與 tabbedWindows 相同）
// onTabBar：點在分頁列上（包括空白處）
static NSWindow *TabWindowAtEvent(NSEvent *e, BOOL *onTabBar) {
    if (onTabBar) *onTabBar = NO;
    NSWindow *w = e.window;
    if (![w.windowController isKindOfClass:EditorWindowController.class]) return nil;
    NSArray<NSWindow *> *tabs = w.tabbedWindows ?: @[w];
    NSView *frameView = w.contentView.superview;
    NSView *hit = [frameView hitTest:[frameView convertPoint:e.locationInWindow fromView:nil]];
    // 新版 macOS 的分頁列（NSTabBar）攔下所有點擊，hitTest 只回傳分頁列本身：改用位置找分頁按鈕
    NSView *bar = nil;
    for (NSView *v = hit; v; v = v.superview)
        if ([NSStringFromClass(v.class) isEqualToString:@"NSTabBar"] || [NSStringFromClass(v.class) hasSuffix:@"TabBar"]) { bar = v; break; }
    if (!bar) return nil;
    if (onTabBar) *onTabBar = YES;
    NSMutableArray<NSView *> *buttons = [NSMutableArray array];
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:bar];
    while (stack.count) {
        NSView *v = stack.lastObject; [stack removeLastObject];
        NSString *cls = NSStringFromClass(v.class);
        if ([cls hasSuffix:@"TabButton"] && ![cls containsString:@"NewTab"]) { if (!v.hidden) [buttons addObject:v]; continue; }
        [stack addObjectsFromArray:v.subviews];
    }
    NSView *button = nil;
    for (NSView *b in buttons)
        if (NSPointInRect([b convertPoint:e.locationInWindow fromView:nil], b.bounds)) { button = b; break; }
    if (!button || buttons.count != tabs.count) return nil;   // 結構不如預期時不動作，避免關錯分頁
    [buttons sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        return [@(NSMinX([a convertRect:a.bounds toView:nil])) compare:@(NSMinX([b convertRect:b.bounds toView:nil]))];
    }];
    NSUInteger i = [buttons indexOfObjectIdenticalTo:button];
    if (w.windowTitlebarLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft) i = tabs.count - 1 - i;
    return i < tabs.count ? tabs[i] : nil;
}

static NSMenuItem *MenuItem(NSMenu *m, NSString *title, SEL action, id target) {
    NSMenuItem *it = [m addItemWithTitle:N2L(title) action:action keyEquivalent:@""];
    it.target = target;
    return it;
}

// 分頁的右鍵選單；tab 為 nil 時是分頁列空白處的選單
NSMenu *N2TabContextMenu(NSWindow *tab, NSWindow *window) {
    EditorWindowController *ed = (EditorWindowController *)(tab ?: window).windowController;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    m.autoenablesItems = NO;
    MenuItem(m, @"新增分頁", @selector(newWindowForTab:), (EditorWindowController *)window.windowController);
    if (tab) {
        Document *doc = ed.doc;
        [m addItem:NSMenuItem.separatorItem];
        MenuItem(m, @"重新載入", @selector(reloadFromDisk:), ed).enabled = doc.fileURL != nil && !doc.archiveLink;
        MenuItem(m, @"在 Finder 中顯示", @selector(revealInFinder:), ed).enabled =
            (doc.fileURL != nil && !N2IsArchiveWorkURL(doc.fileURL)) || doc.archiveLink != nil;
        MenuItem(m, @"在新視窗開啟", @selector(moveTabToNewWindow:), tab).enabled = (tab.tabbedWindows.count > 1);
        [m addItem:NSMenuItem.separatorItem];
        MenuItem(m, @"關閉分頁", @selector(performClose:), tab);
        MenuItem(m, @"關閉其他分頁", @selector(closeOtherTabs:), ed).enabled = (tab.tabbedWindows.count > 1);
    }
    MenuItem(m, @"關閉全部分頁", @selector(closeAllTabs:), ed);
    if (!tab) MenuItem(m, @"重新開啟關閉的分頁", @selector(reopenClosedTab:), NSApp.delegate).enabled = N2HasClosedDocuments();
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *saveAll = MenuItem(m, @"全部儲存", @selector(saveAllDocuments:), NSApp.delegate);
    saveAll.enabled = YES;
    return m;
}

void N2InstallTabMiddleClick(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskOtherMouseUp | NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *e) {
        if (e.type == NSEventTypeOtherMouseUp) {
            if (e.buttonNumber != 2) return e;
            NSWindow *target = TabWindowAtEvent(e, NULL);
            if (!target || !target.tabbedWindows.count) return e;
            [target performClose:nil];   // 有未儲存的修改時照常詢問
            return nil;
        }
        BOOL onTabBar = NO;
        NSWindow *tab = TabWindowAtEvent(e, &onTabBar);
        if (!onTabBar) return e;
        NSView *frameView = e.window.contentView.superview;
        [NSMenu popUpContextMenu:N2TabContextMenu(tab, e.window) withEvent:e forView:frameView];
        return nil;
    }];
}
