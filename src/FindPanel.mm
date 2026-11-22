#import "FindPanel.h"
#import "EditorWindowController.h"
#import "Localization.h"

@interface N2FindPanel () <NSTextFieldDelegate>
@end

@implementation N2FindPanel {
    NSTextField *_findField;
    NSTextField *_replaceField;
    NSButton *_matchCase, *_wholeWord, *_regex, *_wrap;
    NSTextField *_status;
}

+ (N2FindPanel *)shared {
    static N2FindPanel *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[N2FindPanel alloc] init]; });
    return p;
}

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 470, 176)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:YES];
    panel.title = N2L(@"尋找與取代");
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    if ((self = [super initWithWindow:panel])) {
        [self build];
        [panel center];
        panel.frameAutosaveName = @"Notepad2XSFindPanel";
    }
    return self;
}

- (NSTextField *)label:(NSString *)s frame:(NSRect)r {
    NSTextField *l = [NSTextField labelWithString:s];
    l.frame = r;
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (NSButton *)check:(NSString *)title frame:(NSRect)r key:(NSString *)key {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(optionChanged:)];
    b.frame = r;
    b.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    b.identifier = key;
    return b;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)r action:(SEL)a {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:a];
    b.frame = r;
    return b;
}

- (void)build {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ @"FindWrap": @YES }];
    NSView *v = self.window.contentView;
    [v addSubview:[self label:N2L(@"尋找：") frame:NSMakeRect(8, 142, 64, 18)]];
    [v addSubview:[self label:N2L(@"取代為：") frame:NSMakeRect(8, 110, 64, 18)]];

    _findField = [[NSTextField alloc] initWithFrame:NSMakeRect(76, 139, 262, 24)];
    _replaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(76, 107, 262, 24)];
    for (NSTextField *f in @[_findField, _replaceField]) {
        f.usesSingleLineMode = YES;
        f.cell.scrollable = YES;
        f.delegate = self;
        [v addSubview:f];
    }
    // Enter 由預設按鈕「找下一個」處理

    _matchCase = [self check:N2L(@"大小寫相符") frame:NSMakeRect(76, 76, 130, 18) key:@"FindMatchCase"];
    _wholeWord = [self check:N2L(@"全字相符") frame:NSMakeRect(208, 76, 130, 18) key:@"FindWholeWord"];
    _regex     = [self check:N2L(@"正規表示式") frame:NSMakeRect(76, 52, 130, 18) key:@"FindRegex"];
    _wrap      = [self check:N2L(@"到結尾後從頭找") frame:NSMakeRect(208, 52, 130, 18) key:@"FindWrap"];
    for (NSButton *b in @[_matchCase, _wholeWord, _regex, _wrap]) [v addSubview:b];

    _status = [NSTextField labelWithString:@""];
    _status.frame = NSMakeRect(12, 14, 330, 18);
    _status.textColor = NSColor.secondaryLabelColor;
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [v addSubview:_status];

    NSButton *next = [self button:N2L(@"找下一個") frame:NSMakeRect(348, 136, 112, 30) action:@selector(findNextClicked:)];
    next.keyEquivalent = @"\r";
    [v addSubview:next];
    [v addSubview:[self button:N2L(@"找上一個") frame:NSMakeRect(348, 104, 112, 30) action:@selector(findPrevClicked:)]];
    [v addSubview:[self button:N2L(@"取代") frame:NSMakeRect(348, 72, 112, 30) action:@selector(replaceClicked:)]];
    [v addSubview:[self button:N2L(@"全部取代") frame:NSMakeRect(348, 40, 112, 30) action:@selector(replaceAllClicked:)]];
}

- (NSString *)findString { return _findField.stringValue ?: @""; }
- (void)setFindString:(NSString *)s { _findField.stringValue = s ?: @""; }

- (void)optionChanged:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:b.identifier];
}

- (N2FindOptions)options {
    N2FindOptions o = 0;
    if (_matchCase.state == NSControlStateValueOn) o |= N2FindMatchCase;
    if (_wholeWord.state == NSControlStateValueOn) o |= N2FindWholeWord;
    if (_regex.state == NSControlStateValueOn) o |= N2FindRegex;
    if (_wrap.state == NSControlStateValueOn) o |= N2FindWrap;
    return o;
}

- (EditorWindowController *)editor {
    id wc = NSApp.mainWindow.windowController;
    return [wc isKindOfClass:EditorWindowController.class] ? wc : nil;
}

- (void)prefill:(NSString *)selection {
    // 只有單行的選取才自動填入
    if (selection.length && [selection rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        _findField.stringValue = selection;
    _status.stringValue = @"";
}

- (void)showFind:(NSString *)selection {
    [self prefill:selection];
    [self showWindow:nil];
    [self.window makeFirstResponder:_findField];
}

- (void)showReplace:(NSString *)selection {
    [self prefill:selection];
    [self showWindow:nil];
    [self.window makeFirstResponder:_findField.stringValue.length ? _replaceField : _findField];
}

- (void)report:(N2FindResult)r {
    switch (r) {
        case N2FindFound: _status.stringValue = @""; break;
        case N2FindFoundWrapped: _status.stringValue = N2L(@"已從另一端繼續搜尋"); break;
        case N2FindNotFound:
            _status.stringValue = [NSString stringWithFormat:N2L(@"找不到「%@」"), self.findString];
            NSBeep();
            break;
        case N2FindInvalidPattern:
            _status.stringValue = N2L(@"正規表示式有誤");
            NSBeep();
            break;
    }
}

- (void)findNext:(BOOL)forward {
    if (self.findString.length == 0) { [self showFind:self.editor.selectedText]; return; }
    EditorWindowController *ed = self.editor;
    if (!ed) { NSBeep(); return; }
    [self report:[ed findString:self.findString options:self.options forward:forward]];
}

- (void)findNextClicked:(id)sender { [self findNext:YES]; }
- (void)findPrevClicked:(id)sender { [self findNext:NO]; }

- (void)replaceClicked:(id)sender {
    EditorWindowController *ed = self.editor;
    if (!ed || self.findString.length == 0) { NSBeep(); return; }
    [self report:[ed replaceString:self.findString with:_replaceField.stringValue options:self.options]];
}

- (void)replaceAllClicked:(id)sender {
    EditorWindowController *ed = self.editor;
    if (!ed || self.findString.length == 0) { NSBeep(); return; }
    NSInteger n = [ed replaceAll:self.findString with:_replaceField.stringValue options:self.options];
    if (n == N2ReplaceAllReadOnly) { _status.stringValue = @""; return; }   // 編輯視窗已顯示「已鎖定」提示
    if (n < 0) { [self report:N2FindInvalidPattern]; return; }
    _status.stringValue = n ? [NSString stringWithFormat:N2L(@"已取代 %ld 處"), (long)n]
                            : [NSString stringWithFormat:N2L(@"找不到「%@」"), self.findString];
    if (!n) NSBeep();
}

@end
