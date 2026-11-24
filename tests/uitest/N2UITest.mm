// 測試專用：App 內建的自動操作（只在 UITEST=1 ./build.sh 時編入，正式版不含）
// 不需要「輔助使用」「螢幕錄影」權限：事件由 App 自己送出，截圖由視窗自己繪製
// 環境變數 N2_UITEST_SCRIPT＝指令檔，每行一個指令：
//   open <路徑>                 開啟檔案
//   new                         新增文件
//   menu 檢視/顯示書籤欄          執行選單項目（依標題路徑）
//   key <字元> [cmd,opt,shift,ctrl]   按鍵（字元可用 F2、Tab、Return、Esc、Left、Right、Up、Down、Delete）
//   type <文字>                 逐字輸入（走一般文字輸入流程）
//   click <x> <y> [right|middle]   點編輯區（座標以編輯區左上角為原點）
//   wait <秒>                   等待
//   snap <檔案>                  主視窗截圖（含附加的對話框）
//   dump                        印出目前文件的文字、選取、書籤、視窗與對話框
//   alert <按鈕編號>             按下對話框按鈕（0 起算）
//   sci <訊息> [w] [l]           直接送 Scintilla 訊息並印出結果
//   setpos <位置>                 設定游標
//   default <鍵> <值|-delete>     變更偏好設定
//   eval tabs                   印出分頁資訊
//   quit                        結束
#import <Cocoa/Cocoa.h>
#import "../../src/EditorWindowController.h"
#import "../../src/Document.h"
#import "ScintillaView.h"
#import <WebKit/WebKit.h>

static NSArray<NSString *> *gLines;
static NSMenu *gTracking;   // 目前正在顯示的選單（右鍵選單）
static NSUInteger gIndex;
static FILE *gOut;

static void Out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Out(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(gOut, "%s\n", s.UTF8String);
    fflush(gOut);
}

static NSWindow *DocWindow(void) {
    NSWindow *w = NSApp.mainWindow ?: NSApp.keyWindow;
    if ([w.windowController isKindOfClass:EditorWindowController.class]) return w;
    for (NSWindow *x in NSApp.orderedWindows) if ([x.windowController isKindOfClass:EditorWindowController.class]) return x;
    return nil;
}

// 最前面的視窗（有附加的對話框時用對話框）
static NSWindow *FrontWindow(void) {
    NSWindow *w = NSApp.keyWindow;
    if (!w) for (NSWindow *x in NSApp.orderedWindows) if (x.isVisible) { w = x; break; }
    while (w.attachedSheet) w = w.attachedSheet;
    return w;
}

static EditorWindowController *Editor(void) { return (EditorWindowController *)DocWindow().windowController; }

static NSMenuItem *FindMenu(NSString *path) {
    NSMenu *menu = NSApp.mainMenu;
    NSMenuItem *found = nil;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        found = nil;
        [menu update];
        for (NSMenuItem *it in menu.itemArray) if ([it.title isEqualToString:part]) { found = it; break; }
        if (!found) return nil;
        menu = found.submenu;
    }
    return found;
}

static NSEventModifierFlags Mods(NSString *s) {
    NSEventModifierFlags m = 0;
    if ([s containsString:@"cmd"]) m |= NSEventModifierFlagCommand;
    if ([s containsString:@"opt"]) m |= NSEventModifierFlagOption;
    if ([s containsString:@"shift"]) m |= NSEventModifierFlagShift;
    if ([s containsString:@"ctrl"]) m |= NSEventModifierFlagControl;
    return m;
}

static void PostKey(NSString *chars, unsigned short code, NSEventModifierFlags mods) {
    NSWindow *w = NSApp.keyWindow ?: DocWindow();
    NSString *plain = (mods & NSEventModifierFlagShift) ? chars : chars;
    for (NSEventType t : {NSEventTypeKeyDown, NSEventTypeKeyUp}) {
        NSEvent *e = [NSEvent keyEventWithType:t location:NSZeroPoint modifierFlags:mods timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:plain
                                     isARepeat:NO keyCode:code];
        [NSApp postEvent:e atStart:NO];
    }
}

static void Key(NSString *name, NSString *mods) {
    static NSDictionary *special = @{
        @"F2": @[@(NSF2FunctionKey), @120], @"F5": @[@(NSF5FunctionKey), @96], @"Tab": @[@('\t'), @48],
        @"Return": @[@('\r'), @36], @"Esc": @[@(27), @53], @"Left": @[@(NSLeftArrowFunctionKey), @123],
        @"Right": @[@(NSRightArrowFunctionKey), @124], @"Up": @[@(NSUpArrowFunctionKey), @126],
        @"Down": @[@(NSDownArrowFunctionKey), @125], @"Delete": @[@(127), @51], @"Space": @[@(' '), @49],
    };
    NSArray *sp = special[name];
    unichar c = sp ? (unichar)[sp[0] integerValue] : [name characterAtIndex:0];
    unsigned short code = sp ? (unsigned short)[sp[1] integerValue] : 0;
    PostKey([NSString stringWithCharacters:&c length:1], code, Mods(mods ?: @""));
}

static void Click(CGFloat x, CGFloat y, NSString *kind) {
    EditorWindowController *ed = Editor();
    NSView *content = ed.sci.content;
    NSWindow *w = ed.window;
    // x 從編輯區（含邊界）左緣起算；y 從可見區頂端起算
    NSView *sv = ed.sci;
    NSPoint p = [sv convertPoint:NSMakePoint(x, sv.isFlipped ? y : NSHeight(sv.bounds) - y) toView:nil];
    NSEventType down = NSEventTypeLeftMouseDown, up = NSEventTypeLeftMouseUp;
    NSInteger button = 0;
    if ([kind isEqualToString:@"right"]) { down = NSEventTypeRightMouseDown; up = NSEventTypeRightMouseUp; button = 1; }
    if ([kind isEqualToString:@"middle"]) { down = NSEventTypeOtherMouseDown; up = NSEventTypeOtherMouseUp; button = 2; }
    (void)content;
    for (NSEventType t : {down, up}) {
        NSEvent *e = [NSEvent mouseEventWithType:t location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        if (button == 2) {
            CGEventRef cg = CGEventCreateCopy(e.CGEvent);
            CGEventSetIntegerValueField(cg, kCGMouseEventButtonNumber, 2);
            e = [NSEvent eventWithCGEvent:cg];
            CFRelease(cg);
        }
        [NSApp postEvent:e atStart:NO];
    }
}

static void Snap(NSString *path) {
    NSWindow *w = DocWindow();
    if (!w) { Out(@"snap: 沒有視窗"); return; }
    NSMutableArray<NSWindow *> *list = [NSMutableArray arrayWithObject:w];
    if (w.attachedSheet) [list addObject:w.attachedSheet];
    for (NSWindow *x in NSApp.windows) if (x.isVisible && x != w && x != w.attachedSheet && x.level > NSNormalWindowLevel - 1 &&
                                          ![x.windowController isKindOfClass:EditorWindowController.class] && x.frame.size.width > 50) [list addObject:x];
    NSInteger i = 0;
    for (NSWindow *x in list) {
        NSView *v = x.contentView.superview ?: x.contentView;
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *p = i == 0 ? path : [path.stringByDeletingPathExtension stringByAppendingFormat:@"_%ld.png", (long)i];
        [png writeToFile:p atomically:YES];
        Out(@"snap: %@ (%@)", p, x.title.length ? x.title : NSStringFromClass(x.class));
        i++;
    }
}

static void DumpAlert(NSWindow *sheet) {
    for (NSView *v in sheet.contentView.subviews) {
        if ([v isKindOfClass:NSTextField.class]) Out(@"  文字：%@", ((NSTextField *)v).stringValue);
        if ([v isKindOfClass:NSButton.class]) Out(@"  按鈕：%@", ((NSButton *)v).title);
    }
}

static void Dump(void) {
    EditorWindowController *ed = Editor();
    if (!ed) { Out(@"dump: 沒有文件視窗"); return; }
    ScintillaView *v = ed.sci;
    NSData *d = ed.textAsUTF8;
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    Out(@"文件：%@  已修改：%d  路徑：%@", ed.doc.displayName, ed.doc.isDocumentEdited, ed.doc.fileURL.path ?: @"-");
    Out(@"文字：%@", [[text stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"] stringByReplacingOccurrencesOfString:@"\r" withString:@"␍"]);
    Out(@"選取：%ld-%ld  游標行：%ld", [v message:SCI_GETANCHOR], [v message:SCI_GETCURRENTPOS],
        [v message:SCI_LINEFROMPOSITION wParam:[v message:SCI_GETCURRENTPOS]]);
    NSMutableArray *marks = [NSMutableArray array];
    for (sptr_t line = 0; line < [v message:SCI_GETLINECOUNT]; line++) {
        unsigned m = (unsigned)[v message:SCI_MARKERGET wParam:line];
        if (m & (1u << 22)) [marks addObject:[NSString stringWithFormat:@"%ld藍", line + 1]];
        if (m & (1u << 23)) [marks addObject:[NSString stringWithFormat:@"%ld紅", line + 1]];
        if (m & (1u << 21)) [marks addObject:[NSString stringWithFormat:@"%ld搜", line + 1]];
    }
    Out(@"書籤：%@", [marks componentsJoinedByString:@" "]);
    Out(@"邊界寬度：%ld %ld %ld %ld  縮放：%ld  第一可見行：%ld", [v message:SCI_GETMARGINWIDTHN wParam:0], [v message:SCI_GETMARGINWIDTHN wParam:1],
        [v message:SCI_GETMARGINWIDTHN wParam:2], [v message:SCI_GETMARGINWIDTHN wParam:3], [v message:SCI_GETZOOM],
        [v message:SCI_GETFIRSTVISIBLELINE]);
    NSWindow *w = ed.window;
    Out(@"視窗：%@  分頁數：%lu  標題：%@", w.title, (unsigned long)(w.tabbedWindows.count ?: 1), w.subtitle ?: @"");
    if (w.attachedSheet) { Out(@"對話框："); DumpAlert(w.attachedSheet); }
}

static NSAlert *AttachedAlert(void) {
    NSWindow *sheet = DocWindow().attachedSheet;
    for (NSView *v in sheet.contentView.subviews) (void)v;
    return nil;
}

static void PressAlert(NSInteger index) {
    NSWindow *sheet = NSApp.modalWindow ?: DocWindow().attachedSheet;
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:sheet.contentView];
    while (stack.count) {
        NSView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:NSButton.class] && ((NSButton *)v).bezelStyle == NSBezelStyleRounded) [buttons addObject:(NSButton *)v];
        [stack addObjectsFromArray:v.subviews];
    }
    // 依畫面位置由右到左（NSAlert 第一個按鈕在最右邊）
    [buttons sortUsingComparator:^NSComparisonResult(NSButton *a, NSButton *b) {
        NSRect ra = [a convertRect:a.bounds toView:nil], rb = [b convertRect:b.bounds toView:nil];
        if (fabs(NSMinY(ra) - NSMinY(rb)) > 4) return NSMinY(ra) > NSMinY(rb) ? NSOrderedAscending : NSOrderedDescending;
        return NSMaxX(ra) > NSMaxX(rb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (index < 0 || index >= (NSInteger)buttons.count) { Out(@"alert: 找不到按鈕 %ld（共 %lu 個）", (long)index, (unsigned long)buttons.count); return; }
    Out(@"alert: 按下「%@」", buttons[index].title);
    [buttons[index] performClick:nil];
}

static void RunNext(void);

// 一般、選單追蹤、強制回應視窗（runModal）期間都會執行
static void After(double seconds, void (^block)(void)) {
    NSTimer *t = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) { block(); }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSModalPanelRunLoopMode];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSEventTrackingRunLoopMode];
}

static void Exec(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    NSString *rest = parts.count > 1 ? [line substringFromIndex:cmd.length + 1] : @"";
    double delay = 0.25;
    if ([cmd isEqualToString:@"open"]) {
        [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:rest] display:YES
            completionHandler:^(NSDocument *doc, BOOL already, NSError *e) { if (e) Out(@"open 失敗：%@", e.localizedDescription); }];
        delay = 1.0;
    } else if ([cmd isEqualToString:@"new"]) {
        [NSDocumentController.sharedDocumentController newDocument:nil];
        delay = 0.6;
    } else if ([cmd isEqualToString:@"menu"]) {
        NSMenuItem *it = FindMenu(rest);
        if (!it) Out(@"menu: 找不到「%@」", rest);
        else {
            NSMenu *m = it.menu;
            [m update];
            EditorWindowController *ed = Editor();
            if (!it.target && ed && [ed respondsToSelector:it.action] && !NSApp.mainWindow) {
                // App 不在最前面：直接交給文件視窗（先用它的驗證規則）
                if ([ed respondsToSelector:@selector(validateMenuItem:)] && ![ed validateMenuItem:it]) Out(@"menu: 「%@」停用中", rest);
                else [NSApp sendAction:it.action to:ed from:it];
            } else if (!it.isEnabled) Out(@"menu: 「%@」停用中", rest);
            else [m performActionForItemAtIndex:[m indexOfItem:it]];
        }
        delay = 0.5;
    } else if ([cmd isEqualToString:@"menustate"]) {
        NSMenuItem *it = FindMenu(rest);
        [it.menu update];
        Out(@"menustate: %@ 啟用=%d 勾選=%d 快捷鍵=%@", rest, it.isEnabled, it.state == NSControlStateValueOn, it.keyEquivalent);
        delay = 0.05;
    } else if ([cmd isEqualToString:@"key"]) {
        Key(parts[1], parts.count > 2 ? parts[2] : nil);
    } else if ([cmd isEqualToString:@"type"]) {
        for (NSUInteger i = 0; i < rest.length; i++) PostKey([rest substringWithRange:NSMakeRange(i, 1)], 0, 0);
        delay = 0.2 + rest.length * 0.02;
    } else if ([cmd isEqualToString:@"click"]) {
        Click([parts[1] doubleValue], [parts[2] doubleValue], parts.count > 3 ? parts[3] : @"left");
        delay = 0.4;
    } else if ([cmd isEqualToString:@"wait"]) {
        delay = rest.doubleValue;
    } else if ([cmd isEqualToString:@"snap"]) {
        Snap(rest);
    } else if ([cmd isEqualToString:@"dump"]) {
        Dump();
        delay = 0.05;
    } else if ([cmd isEqualToString:@"alert"]) {
        PressAlert(rest.integerValue);
        delay = 0.6;
    } else if ([cmd isEqualToString:@"sci"]) {
        sptr_t r = [Editor().sci message:(unsigned)[parts[1] intValue] wParam:parts.count > 2 ? [parts[2] longLongValue] : 0
                                  lParam:parts.count > 3 ? [parts[3] longLongValue] : 0];
        Out(@"sci %@ → %ld", rest, (long)r);
        delay = 0.05;
    } else if ([cmd isEqualToString:@"setpos"]) {
        [Editor().sci message:SCI_GOTOPOS wParam:rest.integerValue];
        delay = 0.1;
    } else if ([cmd isEqualToString:@"select"]) {
        [Editor().sci message:SCI_SETSEL wParam:[parts[1] integerValue] lParam:[parts[2] integerValue]];
        delay = 0.1;
    } else if ([cmd isEqualToString:@"default"]) {
        NSString *val = parts.count > 2 ? parts[2] : @"-delete";
        if ([val isEqualToString:@"-delete"]) [NSUserDefaults.standardUserDefaults removeObjectForKey:parts[1]];
        else if ([val isEqualToString:@"YES"] || [val isEqualToString:@"NO"]) [NSUserDefaults.standardUserDefaults setBool:[val isEqualToString:@"YES"] forKey:parts[1]];
        else [NSUserDefaults.standardUserDefaults setObject:val forKey:parts[1]];
    } else if ([cmd isEqualToString:@"button"]) {
        // 在任何可見視窗中按下標題相符的按鈕或核取方塊
        BOOL done = NO;
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible || done) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
            while (stack.count && !done) {
                NSView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).title isEqualToString:rest]) {
                    [(NSButton *)v performClick:nil]; done = YES;
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        if (!done) Out(@"button: 找不到「%@」", rest);
        delay = 0.5;
    } else if ([cmd isEqualToString:@"field"]) {
        // field <編號> <文字>：設定目前最前面視窗的第 N 個可編輯文字欄位
        NSWindow *x = FrontWindow();
        NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
        while (stack.count) {
            NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).isEditable) [fields addObject:(NSTextField *)v];
            [stack addObjectsFromArray:v.subviews];
        }
        [fields sortUsingComparator:^NSComparisonResult(NSTextField *a, NSTextField *b) {
            NSRect ra = [a convertRect:a.bounds toView:nil], rb = [b convertRect:b.bounds toView:nil];
            if (fabs(NSMinY(ra) - NSMinY(rb)) > 4) return NSMinY(ra) > NSMinY(rb) ? NSOrderedAscending : NSOrderedDescending;
            return NSMinX(ra) < NSMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
        }];
        NSInteger n = [parts[1] integerValue];
        NSString *val = parts.count > 2 ? [rest substringFromIndex:[parts[1] length] + 1] : @"";
        if (n < (NSInteger)fields.count) { fields[n].stringValue = val; Out(@"field %ld = %@", (long)n, val); }
        else Out(@"field: 只有 %lu 個欄位", (unsigned long)fields.count);
        delay = 0.2;
    } else if ([cmd isEqualToString:@"labels"]) {
        // 印出最前面視窗（或指定標題的視窗）所有文字
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible || (rest.length && ![x.title containsString:rest])) continue;
            if (!rest.length && x != NSApp.keyWindow) continue;
            Out(@"[%@]", x.title);
            NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
            while (stack.count) {
                NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).stringValue.length) Out(@"  %@", ((NSTextField *)v).stringValue);
                else if ([v isKindOfClass:NSButton.class]) Out(@"  [%@]%@", ((NSButton *)v).title, ((NSButton *)v).state ? @"✓" : @"");
                else if ([v isKindOfClass:NSPopUpButton.class]) Out(@"  <%@>", ((NSPopUpButton *)v).titleOfSelectedItem);
                [stack addObjectsFromArray:v.subviews];
            }
        }
        delay = 0.05;
    } else if ([cmd isEqualToString:@"snapkey"]) {
        NSWindow *x = FrontWindow();
        NSView *v = x.contentView.superview ?: x.contentView;
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:rest atomically:YES];
        Out(@"snapkey: %@ (%@)", rest, x.title);
    } else if ([cmd isEqualToString:@"action"]) {
        // 稍後才送出：動作可能開啟強制回應視窗（runModal），不能卡住後續指令
        NSString *selName = rest;
        After(0.05, ^{
            SEL sel = NSSelectorFromString(selName);
            // App 不在最前面時沒有主視窗，nil 目標找不到編輯視窗：直接送給文件視窗
            id target = [Editor() respondsToSelector:sel] ? Editor() : nil;
            BOOL ok = [NSApp sendAction:sel to:target from:nil];
            if (!ok) ok = [NSApp sendAction:sel to:NSApp.delegate from:nil];
            Out(@"action %@ → %d", selName, ok);
        });
        delay = 0.8;
    } else if ([cmd isEqualToString:@"tabbar"]) {
        // 列出分頁按鈕位置（視窗座標，左上角為原點）
        NSWindow *w = DocWindow();
        NSView *frameView = w.contentView.superview;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:frameView];
        while (stack.count) {
            NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            NSString *cls = NSStringFromClass(v.class);
            if ([cls containsString:@"TabButton"] || [cls containsString:@"TabBar"]) {
                NSRect r = [v convertRect:v.bounds toView:nil];
                Out(@"  %@ x=%.0f y=%.0f w=%.0f h=%.0f hidden=%d", cls, NSMinX(r), NSHeight(w.frame) - NSMaxY(r), NSWidth(r), NSHeight(r), v.isHidden);
            }
            [stack addObjectsFromArray:v.subviews];
        }
        delay = 0.05;
    } else if ([cmd isEqualToString:@"winclick"]) {
        // winclick x y [right|middle]：視窗座標（左上角為原點）
        NSWindow *w = DocWindow();
        NSPoint p = NSMakePoint([parts[1] doubleValue], NSHeight(w.frame) - [parts[2] doubleValue]);
        NSString *kind = parts.count > 3 ? parts[3] : @"left";
        NSEventType down = NSEventTypeLeftMouseDown, up = NSEventTypeLeftMouseUp;
        if ([kind isEqualToString:@"right"]) { down = NSEventTypeRightMouseDown; up = NSEventTypeRightMouseUp; }
        if ([kind isEqualToString:@"middle"]) { down = NSEventTypeOtherMouseDown; up = NSEventTypeOtherMouseUp; }
        for (NSEventType t : {down, up}) {
            NSEvent *e = [NSEvent mouseEventWithType:t location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                        windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
            if ([kind isEqualToString:@"middle"]) {
                CGEventRef cg = CGEventCreateCopy(e.CGEvent);
                CGEventSetIntegerValueField(cg, kCGMouseEventButtonNumber, 2);
                e = [NSEvent eventWithCGEvent:cg];
                CFRelease(cg);
            }
            [NSApp postEvent:e atStart:NO];
        }
        delay = 0.8;
    } else if ([cmd isEqualToString:@"trackedmenu"]) {
        // 印出正在顯示的選單；trackedmenu <項目標題> 則選取該項目，否則關閉選單
        NSMenu *m = gTracking;
        if (!m) { Out(@"trackedmenu: 沒有顯示中的選單"); }
        else {
            NSMutableArray *items = [NSMutableArray array];
            NSMenuItem *pick = nil;
            for (NSMenuItem *it in m.itemArray) {
                if (it.isSeparatorItem) { [items addObject:@"—"]; continue; }
                [items addObject:[NSString stringWithFormat:@"%@%@", it.title, it.isEnabled ? @"" : @"(停用)"]];
                if (rest.length && [it.title isEqualToString:rest]) pick = it;
            }
            Out(@"選單：%@", [items componentsJoinedByString:@" | "]);
            [m cancelTrackingWithoutAnimation];
            if (pick) {
                NSMenuItem *p2 = pick;
                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp sendAction:p2.action to:p2.target from:p2]; });
            }
        }
        delay = 0.8;
    } else if ([cmd isEqualToString:@"hittest"]) {
        NSWindow *w = DocWindow();
        NSView *frameView = w.contentView.superview;
        NSPoint p = NSMakePoint([parts[1] doubleValue], NSHeight(w.frame) - [parts[2] doubleValue]);
        NSView *hit = [frameView hitTest:[frameView convertPoint:p fromView:nil]];
        NSMutableArray *chain = [NSMutableArray array];
        for (NSView *v = hit; v; v = v.superview) [chain addObject:NSStringFromClass(v.class)];
        Out(@"hittest: %@", [chain componentsJoinedByString:@" < "]);
        delay = 0.05;
    } else if ([cmd isEqualToString:@"fsroot"]) {
        // 檔案搜尋視窗：把位置設成指定資料夾（代替開啟面板）
        for (NSWindow *x in NSApp.windows) {
            if ([x.windowController respondsToSelector:NSSelectorFromString(@"useFolder:")])
                [x.windowController performSelector:NSSelectorFromString(@"useFolder:") withObject:rest];
        }
        delay = 0.2;
    } else if ([cmd isEqualToString:@"table"]) {
        // 印出最前面視窗中表格的內容
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible || (rest.length && ![x.title containsString:rest])) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
            while (stack.count) {
                NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                if ([v isKindOfClass:NSTableView.class]) {
                    NSTableView *t = (NSTableView *)v;
                    for (NSInteger r = 0; r < t.numberOfRows && r < 50; r++) {
                        NSMutableArray *cells = [NSMutableArray array];
                        for (NSTableColumn *c in t.tableColumns) {
                            id val = [t.dataSource tableView:t objectValueForTableColumn:c row:r];
                            [cells addObject:[val description] ?: @""];
                        }
                        Out(@"  %@", [cells componentsJoinedByString:@" | "]);
                    }
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        delay = 0.05;
    } else if ([cmd isEqualToString:@"saveas"]) {
        // 不經過儲存視窗，直接另存到指定路徑
        NSDocument *d = Editor().doc;
        [d saveToURL:[NSURL fileURLWithPath:rest] ofType:d.fileType ?: @"public.plain-text" forSaveOperation:NSSaveAsOperation
           completionHandler:^(NSError *e) { Out(@"saveas %@ → %@", rest.lastPathComponent, e ? e.localizedDescription : @"OK"); }];
        delay = 1.5;
    } else if ([cmd isEqualToString:@"popup"]) {
        // popup <編號> <項目標題>：在最前面視窗（含附加的對話框）選取第 N 個彈出式選單的項目並觸發動作
        NSWindow *x = FrontWindow();
        NSMutableArray<NSPopUpButton *> *pops = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
        while (stack.count) {
            NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSPopUpButton.class] && !v.isHiddenOrHasHiddenAncestor) [pops addObject:(NSPopUpButton *)v];
            [stack addObjectsFromArray:v.subviews];
        }
        [pops sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
            NSRect ra = [a convertRect:a.bounds toView:nil], rb = [b convertRect:b.bounds toView:nil];
            if (fabs(NSMinY(ra) - NSMinY(rb)) > 4) return NSMinY(ra) > NSMinY(rb) ? NSOrderedAscending : NSOrderedDescending;
            return NSMinX(ra) < NSMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
        }];
        NSInteger n = [parts[1] integerValue];
        NSString *title = parts.count > 2 ? [rest substringFromIndex:[parts[1] length] + 1] : @"";
        if (n >= (NSInteger)pops.count) Out(@"popup: 只有 %lu 個", (unsigned long)pops.count);
        else {
            NSPopUpButton *pop = pops[n];
            NSMutableArray *titles = [NSMutableArray array];
            for (NSMenuItem *it in pop.itemArray) [titles addObject:it.title];
            NSMenuItem *item = [pop itemWithTitle:title];
            if (!item) Out(@"popup %ld: 找不到「%@」；項目：%@", (long)n, title, [titles componentsJoinedByString:@" | "]);
            else if (pop.pullsDown) { [NSApp sendAction:item.action to:item.target from:item]; Out(@"popup %ld → %@", (long)n, title); }
            else { [pop selectItem:item]; [NSApp sendAction:pop.action to:pop.target from:pop]; Out(@"popup %ld → %@", (long)n, title); }
        }
        delay = 0.4;
    } else if ([cmd isEqualToString:@"popups"]) {
        NSWindow *x = FrontWindow();
        NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
        while (stack.count) {
            NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSPopUpButton.class] && !v.isHiddenOrHasHiddenAncestor) {
                NSMutableArray *titles = [NSMutableArray array];
                for (NSMenuItem *it in ((NSPopUpButton *)v).itemArray) [titles addObject:it.title];
                Out(@"  <%@> %@", ((NSPopUpButton *)v).titleOfSelectedItem, [titles componentsJoinedByString:@" | "]);
            }
            [stack addObjectsFromArray:v.subviews];
        }
        delay = 0.05;
    } else if ([cmd isEqualToString:@"textview"]) {
        // textview <編號> <文字>：設定最前面視窗第 N 個可編輯 NSTextView（\n 代表換行），並通知內容已改變
        NSWindow *x = FrontWindow();
        NSMutableArray<NSTextView *> *tvs = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
        while (stack.count) {
            NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
            if ([v isKindOfClass:NSTextView.class]) [tvs addObject:(NSTextView *)v];
            [stack addObjectsFromArray:v.subviews];
        }
        NSInteger n = [parts[1] integerValue];
        NSString *val = parts.count > 2 ? [[rest substringFromIndex:[parts[1] length] + 1] stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"] : @"";
        if (n < (NSInteger)tvs.count) {
            NSTextView *tv = tvs[n];
            [tv setString:val];
            [tv didChangeText];
            Out(@"textview %ld = %@", (long)n, val);
        } else Out(@"textview: 只有 %lu 個", (unsigned long)tvs.count);
        delay = 0.3;
    } else if ([cmd isEqualToString:@"texts"]) {
        // 印出所有可見視窗中 NSTextView 的內容
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
            while (stack.count) {
                NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                if ([v isKindOfClass:NSTextView.class] && ![v.superview.superview isKindOfClass:NSClassFromString(@"SCIContentView")])
                    Out(@"  [%@] %@", x.title, [((NSTextView *)v).string stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"]);
                [stack addObjectsFromArray:v.subviews];
            }
        }
        delay = 0.05;
    } else if ([cmd isEqualToString:@"js"]) {
        // 在最前面視窗的 WKWebView 執行腳本並印出結果
        WKWebView *web = nil;
        for (NSWindow *x in NSApp.windows) {
            if (!x.isVisible) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:x.contentView];
            while (stack.count && !web) {
                NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
                if ([v isKindOfClass:WKWebView.class]) web = (WKWebView *)v;
                [stack addObjectsFromArray:v.subviews];
            }
        }
        if (!web) Out(@"js: 找不到 WKWebView");
        else [web evaluateJavaScript:rest completionHandler:^(id r, NSError *e) { Out(@"js → %@%@", r ?: @"", e ? e.localizedDescription : @""); }];
        delay = 0.5;
    } else if ([cmd isEqualToString:@"echo"]) {
        Out(@"%@", rest);
        delay = 0.01;
    } else if ([cmd isEqualToString:@"tabs"]) {
        NSWindow *w = DocWindow();
        NSArray *tabs = w ? (w.tabbedWindows ?: @[w]) : @[];
        NSMutableArray *names = [NSMutableArray array];
        for (NSWindow *t in tabs) [names addObject:[NSString stringWithFormat:@"%@%@", t == w ? @"*" : @"", t.title]];
        Out(@"分頁：%@  所有文件數：%lu", [names componentsJoinedByString:@" | "], (unsigned long)NSDocumentController.sharedDocumentController.documents.count);
        delay = 0.05;
    } else if ([cmd isEqualToString:@"windows"]) {
        for (NSWindow *x in NSApp.windows) if (x.isVisible) Out(@"window: %@ [%@] key=%d", x.title, NSStringFromClass(x.class), x.isKeyWindow);
        delay = 0.05;
    } else if ([cmd isEqualToString:@"quit"]) {
        Out(@"quit");
        for (NSDocument *d in NSDocumentController.sharedDocumentController.documents) [d updateChangeCount:NSChangeCleared];
        for (NSWindow *x in NSApp.windows) if (x.attachedSheet) [x endSheet:x.attachedSheet];
        if (NSApp.modalWindow) [NSApp abortModal];
        After(3, ^{ exit(0); });   // 結束被擋住時強制結束
        [NSApp terminate:nil];
        return;
    } else if (cmd.length && ![cmd hasPrefix:@"#"]) {
        Out(@"未知指令：%@", line);
    }
    (void)AttachedAlert;
    After(delay, ^{ RunNext(); });
}

static void RunNext(void) {
    // 選單與快捷鍵要有作用中的主視窗：App 必須在最前面
    if (!NSApp.isActive) [NSApp activateIgnoringOtherApps:YES];
    while (gIndex < gLines.count) {
        NSString *line = [gLines[gIndex++] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        Out(@"> %@", line);
        @try { Exec(line); } @catch (NSException *e) { Out(@"例外：%@", e.reason); RunNext(); }
        return;
    }
}

__attribute__((constructor)) static void N2UITestInstall(void) {
    const char *script = getenv("N2_UITEST_SCRIPT");
    if (!script) return;
    const char *outPath = getenv("N2_UITEST_OUT");
    gOut = outPath ? fopen(outPath, "w") : stdout;
    NSString *s = [NSString stringWithContentsOfFile:@(script) encoding:NSUTF8StringEncoding error:nil];
    gLines = [s componentsSeparatedByString:@"\n"];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { if (n.object != NSApp.mainMenu) gTracking = n.object; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { if (n.object == gTracking) gTracking = nil; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        After(1.0, ^{ RunNext(); });
    }];
}
