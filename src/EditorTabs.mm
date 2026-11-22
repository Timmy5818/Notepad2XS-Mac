// 多分頁：使用 macOS 內建的視窗分頁（與 TextEdit／Finder 相同的分頁列）
// - 設定「開啟文件：在分頁中／在新視窗中」決定新文件的開啟方式
// - ⌘T 新增分頁、⌘W 關閉分頁、⌘⇧] ／⌘⇧[ 下一個／上一個分頁（⌃Tab／⌃⇧Tab 也可以）、⌘1～⌘8 切換、⌘9 最後一個分頁
// - 分頁列右側「＋」新增分頁；滑鼠中鍵點分頁可關閉
// - 「顯示／隱藏標籤頁列」由系統自動加在「視窗」選單（依 App 的介面語言顯示）
#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"

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

@end

#pragma mark - 滑鼠中鍵關閉分頁

// 分頁列是系統的私有視圖：從點到的視圖往上找名稱含 "TabButton" 的視圖，
// 再依同一層分頁按鈕的水平位置換算成第幾個分頁（順序與 tabbedWindows 相同）
static NSWindow *TabWindowAtEvent(NSEvent *e) {
    NSWindow *w = e.window;
    NSArray<NSWindow *> *tabs = w.tabbedWindows;
    if (tabs.count < 2) return nil;
    NSView *frameView = w.contentView.superview;
    NSView *hit = [frameView hitTest:[frameView convertPoint:e.locationInWindow fromView:nil]];
    NSView *button = nil;
    for (NSView *v = hit; v; v = v.superview) {
        if ([NSStringFromClass(v.class) containsString:@"TabButton"]) { button = v; break; }
    }
    if (!button) return nil;
    NSMutableArray<NSView *> *buttons = [NSMutableArray array];
    for (NSView *s in button.superview.subviews)
        if ([s isKindOfClass:button.class] && !s.hidden) [buttons addObject:s];
    if (buttons.count != tabs.count) return nil;   // 結構不如預期時不動作，避免關錯分頁
    [buttons sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        return [@(NSMinX(a.frame)) compare:@(NSMinX(b.frame))];
    }];
    NSUInteger i = [buttons indexOfObjectIdenticalTo:button];
    if (w.windowTitlebarLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft) i = tabs.count - 1 - i;
    return i < tabs.count ? tabs[i] : nil;
}

void N2InstallTabMiddleClick(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskOtherMouseUp handler:^NSEvent *(NSEvent *e) {
        if (e.buttonNumber != 2) return e;
        NSWindow *target = TabWindowAtEvent(e);
        if (!target) return e;
        [target performClose:nil];   // 有未儲存的修改時照常詢問
        return nil;
    }];
}
