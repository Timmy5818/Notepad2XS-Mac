#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"
#import "SyntaxStyles.h"
#import "FindPanel.h"
#import "Localization.h"
#import "ScintillaView.h"
#import <objc/runtime.h>
#include <string>
#include <vector>

static const CGFloat kStatusBarHeight = 22;

// 新版 macOS 的 NSScrollView 讓垂直尺規（行號欄）浮在內容上方，並自動加左內距，
// Scintilla 3.x 會誤判為水平捲動、文字被行號欄蓋住。排版時把內距歸零並讓出尺規寬度。
@interface N2ScintillaScrollView : NSScrollView
@end
@implementation N2ScintillaScrollView
- (void)tile {
    [super tile];
    NSClipView *clipView = self.contentView;
    if (clipView.contentInsets.left != 0 || clipView.contentInsets.top != 0) {
        clipView.automaticallyAdjustsContentInsets = NO;
        clipView.contentInsets = NSEdgeInsetsZero;
        NSPoint o = clipView.bounds.origin;
        [clipView scrollToPoint:NSMakePoint(MAX(o.x, 0), MAX(o.y, 0))];
        [self reflectScrolledClipView:clipView];
    }
    NSRulerView *ruler = self.verticalRulerView;
    if (!self.hasVerticalRuler || !self.rulersVisible || !ruler) return;
    NSRect rf = ruler.frame, clip = clipView.frame;
    CGFloat overlap = NSMaxX(rf) - NSMinX(clip);
    if (overlap > 0 && rf.size.width > 0) {
        clip.origin.x += overlap;
        clip.size.width -= overlap;
        clipView.frame = clip;
    }
}
@end

@interface EditorWindowController () <ScintillaNotificationProtocol, NSWindowDelegate>
- (void)view:(ScintillaView *)v notification:(SCNotification *)scn primary:(BOOL)primary;
@end

// 第二個編輯區的通知轉送：不轉送儲存點通知，避免重複計算修改狀態
@interface N2SecondaryDelegate : NSObject <ScintillaNotificationProtocol>
@property (nonatomic, weak) EditorWindowController *owner;
@property (nonatomic, weak) ScintillaView *view;
@end

@implementation N2SecondaryDelegate
- (void)notification:(SCNotification *)scn {
    [self.owner view:self.view notification:scn primary:NO];
}
@end

@implementation EditorWindowController {
    ScintillaView *_primary;
    ScintillaView *_secondary;
    N2SecondaryDelegate *_secondaryDelegate;
    NSSplitView *_split;
    NSView *_editorArea;
    NSView *_statusBar;
    NSTextField *_statusLeft;
    NSTextField *_statusRight;
    BOOL _loading;
    BOOL _textLoaded;
    sptr_t _lastLineCount;
    N2SplitMode _splitMode;
    NSUInteger _modCount;
    BOOL _forceDirty;   // 加解密清空復原紀錄後：Scintilla 會把目前狀態當成儲存點，存檔前都要保持「未儲存」
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 900, 640);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:YES];
    win.minSize = NSMakeSize(320, 200);
    win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    if ((self = [super initWithWindow:win])) {
        win.delegate = self;
        self.shouldCascadeWindows = YES;
        [self buildViews];
        [self setupToolbar];
        [self setupTabbing];
        [self applySettings];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:)
                                                   name:N2SettingsChangedNotification object:nil];
        static BOOL firstWindow = YES;
        if (firstWindow) {
            firstWindow = NO;
            [win center];
            self.windowFrameAutosaveName = @"Notepad2XSMainWindow";
        }
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _primary.delegate = nil;
    _secondary.delegate = nil;
}

- (ScintillaView *)primarySci { return _primary; }
- (Document *)doc { return (Document *)self.document; }

// 作用中的編輯區：焦點在第二個編輯區時用它，否則用主要編輯區
- (ScintillaView *)sci {
    if (_secondary) {
        NSResponder *fr = self.window.firstResponder;
        if ([fr isKindOfClass:NSView.class] && [(NSView *)fr isDescendantOf:_secondary]) return _secondary;
    }
    return _primary;
}

- (NSArray<ScintillaView *> *)allViews {
    return _secondary ? @[_primary, _secondary] : @[_primary];
}

- (sptr_t)send:(unsigned int)msg { return [self.sci message:msg]; }
- (sptr_t)send:(unsigned int)msg w:(uptr_t)w { return [self.sci message:msg wParam:w]; }
- (sptr_t)send:(unsigned int)msg w:(uptr_t)w l:(sptr_t)l { return [self.sci message:msg wParam:w lParam:l]; }

static sptr_t S(ScintillaView *v, unsigned int msg, uptr_t w = 0, sptr_t l = 0) { return [v message:msg wParam:w lParam:l]; }

#pragma mark - 畫面

- (void)buildViews {
    NSView *content = self.window.contentView;
    NSRect b = content.bounds;

    _statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, b.size.width, kStatusBarHeight)];
    _statusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _statusBar.wantsLayer = YES;
    _statusBar.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, kStatusBarHeight - 1, b.size.width, 1)];
    line.boxType = NSBoxSeparator;
    line.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [_statusBar addSubview:line];

    _statusLeft = [self makeStatusLabel];
    _statusLeft.frame = NSMakeRect(8, 3, b.size.width * 0.55, 16);
    _statusLeft.autoresizingMask = NSViewWidthSizable;
    _statusRight = [self makeStatusLabel];
    _statusRight.alignment = NSTextAlignmentRight;
    _statusRight.frame = NSMakeRect(b.size.width * 0.55, 3, b.size.width * 0.45 - 10, 16);
    _statusRight.autoresizingMask = NSViewWidthSizable | NSViewMinXMargin;
    [_statusBar addSubview:_statusLeft];
    [_statusBar addSubview:_statusRight];
    [content addSubview:_statusBar];

    _editorArea = [[NSView alloc] initWithFrame:NSMakeRect(0, kStatusBarHeight, b.size.width, b.size.height - kStatusBarHeight)];
    _editorArea.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_editorArea];

    _primary = [self makeEditorView];
    _primary.delegate = self;
    _primary.frame = _editorArea.bounds;
    [_editorArea addSubview:_primary];

    if (@available(macOS 14.0, *)) {
        // macOS 14 起新編譯的 App 預設不裁切子視圖
        _statusBar.clipsToBounds = YES;
        _editorArea.clipsToBounds = YES;
    }
}

- (ScintillaView *)makeEditorView {
    ScintillaView *v = [[ScintillaView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    object_setClass(v.scrollView, N2ScintillaScrollView.class);   // 子類別沒有新增成員變數，可安全替換
    v.scrollView.automaticallyAdjustsContentInsets = NO;
    v.scrollView.contentInsets = NSEdgeInsetsZero;
    if (@available(macOS 14.0, *)) {
        v.clipsToBounds = YES;
        v.scrollView.clipsToBounds = YES;
        v.scrollView.verticalRulerView.clipsToBounds = YES;
    }
    S(v, SCI_SETCODEPAGE, SC_CP_UTF8);
    S(v, SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT);
    S(v, SCI_SETMARGINWIDTHN, 1, 0);
    S(v, SCI_SETMARGINWIDTHN, 2, 0);
    S(v, SCI_SETMARGINLEFT, 0, 4);
    S(v, SCI_SETMARGINRIGHT, 0, 4);
    S(v, SCI_SETSCROLLWIDTH, 1);
    S(v, SCI_SETSCROLLWIDTHTRACKING, 1);
    S(v, SCI_SETCARETWIDTH, 2);
    S(v, SCI_SETMULTIPLESELECTION, 1);
    S(v, SCI_SETADDITIONALSELECTIONTYPING, 1);
    S(v, SCI_SETVIRTUALSPACEOPTIONS, SCVS_RECTANGULARSELECTION);
    S(v, SCI_SETENDATLASTLINE, 0);
    S(v, SCI_SETMOUSESELECTIONRECTANGULARSWITCH, 1);
    S(v, SCI_SETPASTECONVERTENDINGS, 1);
    S(v, SCI_SETTABINDENTS, 1);
    S(v, SCI_SETBACKSPACEUNINDENTS, 1);
    S(v, SCI_SETWHITESPACESIZE, 2);
    return v;
}

- (NSTextField *)makeStatusLabel {
    NSTextField *f = [NSTextField labelWithString:@""];
    f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    f.textColor = NSColor.secondaryLabelColor;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    return f;
}

- (void)layoutForStatusBar {
    NSRect b = self.window.contentView.bounds;
    BOOL show = N2Settings.showStatusBar;
    _statusBar.hidden = !show;
    CGFloat h = show ? kStatusBarHeight : 0;
    _editorArea.frame = NSMakeRect(0, h, b.size.width, b.size.height - h);
}

#pragma mark - 分割視窗

- (void)setSplitMode:(N2SplitMode)mode {
    if (mode == _splitMode) return;
    sptr_t firstLine = S(_primary, SCI_GETFIRSTVISIBLELINE);
    // 先拆掉目前的分割
    if (_secondary) {
        [_secondary removeFromSuperview];
        _secondary.delegate = nil;
        _secondary = nil;
        _secondaryDelegate = nil;
    }
    if (_split) {
        [_primary removeFromSuperview];
        [_split removeFromSuperview];
        _split = nil;
    }
    _splitMode = mode;
    if (mode == N2SplitNone) {
        _primary.frame = _editorArea.bounds;
        [_editorArea addSubview:_primary];
    } else {
        _split = [[NSSplitView alloc] initWithFrame:_editorArea.bounds];
        _split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _split.vertical = (mode == N2SplitVertical);
        _split.dividerStyle = NSSplitViewDividerStyleThin;
        _secondary = [self makeEditorView];
        _secondaryDelegate = [N2SecondaryDelegate new];
        _secondaryDelegate.owner = self;
        _secondaryDelegate.view = _secondary;
        _secondary.delegate = _secondaryDelegate;
        // 兩個編輯區共用同一份文件（SetDocPointer 會自動增加參考計數）
        S(_secondary, SCI_SETDOCPOINTER, 0, S(_primary, SCI_GETDOCPOINTER));
        [_split addSubview:_primary];
        [_split addSubview:_secondary];
        [_editorArea addSubview:_split];
        [_split adjustSubviews];
        CGFloat total = _split.vertical ? _split.bounds.size.width : _split.bounds.size.height;
        [_split setPosition:floor(total / 2) ofDividerAtIndex:0];
        [self applyViewSettings:_secondary];
        S(_secondary, SCI_SETFIRSTVISIBLELINE, firstLine);
    }
    S(_primary, SCI_SETFIRSTVISIBLELINE, firstLine);
    [self.window makeFirstResponder:_primary.content];
    [self updateStatus];
}

- (IBAction)splitNone:(id)sender { [self setSplitMode:N2SplitNone]; }
- (IBAction)splitHorizontal:(id)sender { [self setSplitMode:N2SplitHorizontal]; }
- (IBAction)splitVertical:(id)sender { [self setSplitMode:N2SplitVertical]; }

#pragma mark - 設定

- (void)settingsChanged:(NSNotification *)n {
    // 字型、反向色彩以外的設定不需要重套語法樣式（整份重新上色在大檔案上很慢）
    NSSet *keys = n.userInfo[N2SettingsChangedKeys];
    BOOL styles = !keys || [keys intersectsSet:[NSSet setWithObjects:N2KeyFontName, N2KeyFontSize, N2KeyInvertColors, nil]];
    [self applySettingsRestyle:styles];
    if ([keys containsObject:N2KeyAlwaysShowTabBar]) [self ensureTabBarShown];
}

- (void)applySettings { [self applySettingsRestyle:YES]; }

- (void)applySettingsRestyle:(BOOL)restyle {
    for (ScintillaView *v in self.allViews) [self applyViewSettings:v restyle:restyle];
    [self layoutForStatusBar];
    [self updateStatus];
}

- (void)applyViewSettings:(ScintillaView *)v { [self applyViewSettings:v restyle:YES]; }

- (void)applyViewSettings:(ScintillaView *)v restyle:(BOOL)restyle {
    NSString *lang = self.doc ? self.doc.effectiveLanguageID : @"text";
    if (restyle) N2SyntaxApply(v, lang, N2Settings.fontName, N2Settings.fontSize, N2Settings.invertColors);
    S(v, SCI_SETWRAPMODE, N2Settings.wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE);
    S(v, SCI_SETWRAPVISUALFLAGS, N2Settings.wrapSymbols ? SC_WRAPVISUALFLAG_END : SC_WRAPVISUALFLAG_NONE);
    S(v, SCI_SETTABWIDTH, N2Settings.tabWidth);
    S(v, SCI_SETINDENT, 0);
    S(v, SCI_SETUSETABS, !N2Settings.tabsAsSpaces);
    S(v, SCI_SETVIEWWS, N2Settings.showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE);
    S(v, SCI_SETVIEWEOL, N2Settings.showEOL);
    S(v, SCI_SETINDENTATIONGUIDES, N2Settings.indentGuides ? SC_IV_LOOKBOTH : SC_IV_NONE);
    S(v, SCI_SETEDGEMODE, N2Settings.longLineMarker ? EDGE_LINE : EDGE_NONE);
    S(v, SCI_SETEDGECOLUMN, N2Settings.longLineColumn);
    S(v, SCI_SETCARETLINEVISIBLE, N2Settings.highlightCurrentLine);
    if (!N2Settings.matchBraces) S(v, SCI_BRACEHIGHLIGHT, (uptr_t)-1, -1);
    if (restyle) [self applyLockAppearance:v];
    [self updateLineNumberMargin:v force:YES];
    [self updateHighlights:v];
}

- (void)applyLanguage {
    for (ScintillaView *v in self.allViews) {
        NSString *lang = self.doc ? self.doc.effectiveLanguageID : @"text";
        N2SyntaxApply(v, lang, N2Settings.fontName, N2Settings.fontSize, N2Settings.invertColors);
        [self applyLockAppearance:v];
        [self updateLineNumberMargin:v force:YES];
    }
    [self updateStatus];
}

// Scintilla 3.x 改變行號欄寬度後，捲動視圖不會自動重新排版
- (void)retile:(ScintillaView *)v {
    NSScrollView *sv = v.scrollView;
    CGFloat thick = sv.verticalRulerView.ruleThickness;
    if (fabs(NSMinX(sv.contentView.frame) - thick) > 0.5 || sv.contentView.contentInsets.left != 0) {
        [sv tile];
        [sv setNeedsDisplay:YES];
    }
}

- (void)updateLineNumberMargin:(ScintillaView *)v force:(BOOL)force {
    sptr_t lines = S(v, SCI_GETLINECOUNT);
    if (!force && lines == _lastLineCount) return;
    _lastLineCount = lines;
    if (!N2Settings.showLineNumbers) {
        S(v, SCI_SETMARGINWIDTHN, 0, 0);
    } else {
        int digits = 3;
        for (sptr_t n = lines; n >= 1000; n /= 10) digits++;
        char sample[24] = "_";
        for (int i = 0; i < digits; i++) sample[i + 1] = '9';
        sample[digits + 1] = 0;
        sptr_t w = S(v, SCI_TEXTWIDTH, STYLE_LINENUMBER, (sptr_t)sample);
        S(v, SCI_SETMARGINTYPEN, 0, SC_MARGIN_NUMBER);
        S(v, SCI_SETMARGINWIDTHN, 0, w + 6);
    }
    [self retile:v];
}

#pragma mark - 文件內容

- (void)setDocument:(id)document {
    [super setDocument:document];
    if (document && !_textLoaded) {
        _textLoaded = YES;
        [self loadDocumentText];
    }
}

- (void)loadDocumentText {
    Document *doc = self.doc;
    if (!doc) return;
    NSData *text = doc.loadedText;
    ScintillaView *v = _primary;   // 文件共用，對主要編輯區操作即可
    _loading = YES;
    // 鎖定（唯讀）時 CLEARALL／APPENDTEXT 不會生效；先解除，載入後由 updateCryptoAppearance 依狀態重新鎖定
    S(v, SCI_SETREADONLY, 0);
    if (_secondary) S(_secondary, SCI_SETREADONLY, 0);
    S(v, SCI_SETUNDOCOLLECTION, 0);
    S(v, SCI_CLEARALL);
    if (text.length) S(v, SCI_APPENDTEXT, text.length, (sptr_t)text.bytes);
    S(v, SCI_SETUNDOCOLLECTION, 1);
    S(v, SCI_EMPTYUNDOBUFFER);
    S(v, SCI_SETSAVEPOINT);
    _forceDirty = NO;
    S(v, SCI_SETEOLMODE, doc.eolMode);
    S(v, SCI_GOTOPOS, 0);
    if (_secondary) S(_secondary, SCI_GOTOPOS, 0);
    _loading = NO;
    [self updateCryptoAppearance];
    // 密文：等視窗顯示後詢問密碼
    if (doc.pendingAutoDecrypt)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self runPendingAutoDecrypt];
        });
}

- (NSData *)textAsUTF8 {
    sptr_t len = S(_primary, SCI_GETLENGTH);
    const char *p = (const char *)S(_primary, SCI_GETCHARACTERPOINTER);
    return [NSData dataWithBytes:p length:(NSUInteger)len];
}

- (NSUInteger)modificationCount { return _modCount; }

- (void)markDirtyWithoutUndo {
    S(_primary, SCI_EMPTYUNDOBUFFER);   // 這個呼叫也會把儲存點移到目前位置
    _forceDirty = YES;
    [self.document updateChangeCount:NSChangeDone];
}

- (void)markSavedAtModification:(NSUInteger)count {
    if (count == _modCount) { _forceDirty = NO; S(_primary, SCI_SETSAVEPOINT); }
    else [self.document updateChangeCount:NSChangeDone];   // 存檔期間又有修改：存下來的是舊內容，保持「未儲存」
    [self updateStatus];
}

- (NSString *)selectedText {
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    if (b <= a) return @"";
    const char *p = (const char *)[self send:SCI_GETRANGEPOINTER w:a l:b - a];
    return [[NSString alloc] initWithBytes:p length:b - a encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)showMessage:(NSString *)message info:(NSString *)info {
    NSAlert *a = [NSAlert new];
    a.messageText = message;
    if (info) a.informativeText = info;
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Scintilla 通知

- (void)notification:(SCNotification *)scn {
    [self view:_primary notification:scn primary:YES];
}

- (void)view:(ScintillaView *)v notification:(SCNotification *)scn primary:(BOOL)primary {
    switch (scn->nmhdr.code) {
        case SCN_SAVEPOINTLEFT:
            if (primary && !_loading) [self.document updateChangeCount:NSChangeDone];
            break;
        case SCN_SAVEPOINTREACHED:
            if (primary && !_loading && !_forceDirty) [self.document updateChangeCount:NSChangeCleared];
            break;
        case SCN_UPDATEUI:
            [self retile:v];
            // 只在選取或捲動改變時重算醒目提示；填入標示本身會產生「內容更新」，
            // 若也處理就會無限循環重繪
            if (scn->updated & (SC_UPDATE_SELECTION | SC_UPDATE_V_SCROLL)) [self updateHighlights:v];
            if (v == self.sci) [self updateStatus];
            break;
        case SCN_MODIFIED:
            if (primary && (scn->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) _modCount++;
            if (scn->linesAdded) {
                for (ScintillaView *x in self.allViews) [self updateLineNumberMargin:x force:x != v];
            }
            break;
        case SCN_CHARADDED:
            [self autoIndent:v character:scn->ch];
            break;
        case SCN_ZOOM:
            [self updateLineNumberMargin:v force:YES];
            [self updateStatus];
            break;
        default:
            break;
    }
}

// 自動縮排：新行沿用上一行的縮排（原樣複製 Tab／空格）
- (void)autoIndent:(ScintillaView *)v character:(int)ch {
    if (!N2Settings.autoIndent) return;
    int eol = (int)S(v, SCI_GETEOLMODE);
    if (!(ch == '\n' || (ch == '\r' && eol == SC_EOL_CR))) return;
    sptr_t line = S(v, SCI_LINEFROMPOSITION, S(v, SCI_GETCURRENTPOS));
    if (line < 1) return;
    sptr_t prevStart = S(v, SCI_POSITIONFROMLINE, line - 1);
    sptr_t prevIndentEnd = S(v, SCI_GETLINEINDENTPOSITION, line - 1);
    if (prevIndentEnd <= prevStart) return;
    if (S(v, SCI_GETLINEINDENTPOSITION, line) != S(v, SCI_POSITIONFROMLINE, line)) return;   // 已有縮排
    std::string indent((const char *)S(v, SCI_GETRANGEPOINTER, prevStart, prevIndentEnd - prevStart),
                       (size_t)(prevIndentEnd - prevStart));
    S(v, SCI_REPLACESEL, 0, (sptr_t)indent.c_str());
}

// 括號配對與「醒目提示相同文字」
- (void)updateHighlights:(ScintillaView *)v {
    sptr_t pos = S(v, SCI_GETCURRENTPOS);
    if (N2Settings.matchBraces) {
        auto isBrace = [](int c) { return c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}'; };
        sptr_t bracePos = -1;
        if (pos > 0 && isBrace((int)S(v, SCI_GETCHARAT, pos - 1))) bracePos = pos - 1;
        else if (isBrace((int)S(v, SCI_GETCHARAT, pos))) bracePos = pos;
        if (bracePos >= 0) {
            sptr_t match = S(v, SCI_BRACEMATCH, bracePos, 0);
            if (match >= 0) S(v, SCI_BRACEHIGHLIGHT, bracePos, match);
            else S(v, SCI_BRACEBADLIGHT, bracePos);
        } else {
            S(v, SCI_BRACEHIGHLIGHT, (uptr_t)-1, -1);
        }
    }

    sptr_t len = S(v, SCI_GETLENGTH);
    S(v, SCI_SETINDICATORCURRENT, N2IndicatorSameText);
    S(v, SCI_INDICATORCLEARRANGE, 0, len);
    if (!N2Settings.highlightSelection) return;
    sptr_t a = S(v, SCI_GETSELECTIONSTART), b = S(v, SCI_GETSELECTIONEND);
    if (b <= a || b - a > 256 || S(v, SCI_GETSELECTIONS) > 1 || S(v, SCI_SELECTIONISRECTANGLE)) return;
    if (S(v, SCI_LINEFROMPOSITION, a) != S(v, SCI_LINEFROMPOSITION, b)) return;
    std::string needle((const char *)S(v, SCI_GETRANGEPOINTER, a, b - a), (size_t)(b - a));
    if (needle.find_first_not_of(" \t") == std::string::npos) return;
    // 只標示畫面上看得到的範圍
    sptr_t firstVisible = S(v, SCI_DOCLINEFROMVISIBLE, S(v, SCI_GETFIRSTVISIBLELINE));
    sptr_t lastVisible = S(v, SCI_DOCLINEFROMVISIBLE, S(v, SCI_GETFIRSTVISIBLELINE) + S(v, SCI_LINESONSCREEN) + 1);
    sptr_t from = S(v, SCI_POSITIONFROMLINE, firstVisible);
    sptr_t to = S(v, SCI_GETLINEENDPOSITION, lastVisible);
    sptr_t savedStart = S(v, SCI_GETTARGETSTART), savedEnd = S(v, SCI_GETTARGETEND);
    S(v, SCI_SETSEARCHFLAGS, SCFIND_MATCHCASE);
    int count = 0;
    while (from < to && count < 2000) {
        S(v, SCI_SETTARGETSTART, from);
        S(v, SCI_SETTARGETEND, to);
        sptr_t f = S(v, SCI_SEARCHINTARGET, needle.size(), (sptr_t)needle.data());
        if (f < 0) break;
        S(v, SCI_INDICATORFILLRANGE, f, needle.size());
        from = f + (sptr_t)needle.size();
        count++;
    }
    S(v, SCI_SETTARGETSTART, savedStart);
    S(v, SCI_SETTARGETEND, savedEnd);
}

- (void)updateStatus {
    if (_statusBar.hidden || !_primary) return;
    ScintillaView *v = self.sci;
    sptr_t pos = S(v, SCI_GETCURRENTPOS);
    sptr_t line = S(v, SCI_LINEFROMPOSITION, pos);
    sptr_t col = S(v, SCI_GETCOLUMN, pos);
    sptr_t lines = S(v, SCI_GETLINECOUNT);
    sptr_t selA = S(v, SCI_GETSELECTIONSTART), selB = S(v, SCI_GETSELECTIONEND);
    NSMutableString *left = [NSMutableString stringWithFormat:N2L(@"行 %ld / %ld　　欄 %ld"), (long)line + 1, (long)lines, (long)col + 1];
    if (selB > selA) {
        sptr_t chars = S(v, SCI_COUNTCHARACTERS, selA, selB);
        sptr_t selLines = S(v, SCI_LINEFROMPOSITION, selB) - S(v, SCI_LINEFROMPOSITION, selA) + 1;
        [left appendFormat:N2L(@"　　選取 %ld 字元／%ld 行"), (long)chars, (long)selLines];
    }
    _statusLeft.stringValue = left;

    Document *doc = self.doc;
    NSString *eol = @"LF";
    int mode = doc ? doc.eolMode : SC_EOL_LF;
    if (mode == SC_EOL_CRLF) eol = @"CRLF"; else if (mode == SC_EOL_CR) eol = @"CR";
    CGFloat fs = N2Settings.fontSize;
    long zoom = lround((fs + S(v, SCI_GETZOOM)) / fs * 100.0);
    NSString *lang = N2L(N2SyntaxDisplayName(doc ? doc.effectiveLanguageID : @"text"));
    NSString *ovr = S(v, SCI_GETOVERTYPE) ? N2L(@"　覆寫") : @"";
    _statusRight.stringValue = [NSString stringWithFormat:@"%@　｜　%@　｜　%@　｜　%ld%%%@",
                                lang, N2EncodingDisplayName(doc ? doc.encoding : N2EncodingUTF8), eol, zoom, ovr];
}

#pragma mark - 選單：檢視／格式（切換設定）

- (IBAction)toggleWordWrap:(id)sender { N2Settings.wordWrap = !N2Settings.wordWrap; }
- (IBAction)toggleLineNumbers:(id)sender { N2Settings.showLineNumbers = !N2Settings.showLineNumbers; }
- (IBAction)toggleStatusBar:(id)sender { N2Settings.showStatusBar = !N2Settings.showStatusBar; }
- (IBAction)toggleWhitespace:(id)sender { N2Settings.showWhitespace = !N2Settings.showWhitespace; }
- (IBAction)toggleEOLMarks:(id)sender { N2Settings.showEOL = !N2Settings.showEOL; }
- (IBAction)toggleWrapSymbols:(id)sender { N2Settings.wrapSymbols = !N2Settings.wrapSymbols; }
- (IBAction)toggleIndentGuides:(id)sender { N2Settings.indentGuides = !N2Settings.indentGuides; }
- (IBAction)toggleLongLineMarker:(id)sender { N2Settings.longLineMarker = !N2Settings.longLineMarker; }
- (IBAction)toggleMatchBraces:(id)sender { N2Settings.matchBraces = !N2Settings.matchBraces; }
- (IBAction)toggleHighlightLine:(id)sender { N2Settings.highlightCurrentLine = !N2Settings.highlightCurrentLine; }
- (IBAction)toggleHighlightSelection:(id)sender { N2Settings.highlightSelection = !N2Settings.highlightSelection; }
- (IBAction)toggleInvertColors:(id)sender { N2Settings.invertColors = !N2Settings.invertColors; }
- (IBAction)toggleAutoIndent:(id)sender { N2Settings.autoIndent = !N2Settings.autoIndent; }
- (IBAction)toggleTabsAsSpaces:(id)sender { N2Settings.tabsAsSpaces = !N2Settings.tabsAsSpaces; }

- (IBAction)zoomInText:(id)sender { [self send:SCI_ZOOMIN]; }
- (IBAction)zoomOutText:(id)sender { [self send:SCI_ZOOMOUT]; }
- (IBAction)zoomResetText:(id)sender { [self send:SCI_SETZOOM w:0]; }

- (IBAction)showEditorFont:(id)sender { [N2Settings showFontPanelForTarget:self]; }

- (void)changeEditorFont:(id)sender { [N2Settings applyFontChange:sender]; }

- (IBAction)selectLanguage:(NSMenuItem *)sender {
    NSArray *ids = N2SyntaxLanguageIDs();
    self.doc.languageID = (sender.tag >= 0 && sender.tag < (NSInteger)ids.count) ? ids[sender.tag] : nil;
    [self applyLanguage];
}

#pragma mark - 選單：檔案

- (BOOL)rejectIfReadOnly {
    if (!S(_primary, SCI_GETREADONLY)) return NO;
    [self showMessage:@"文件目前已鎖定（唯讀），無法修改。" info:@"請先解密或解除鎖定。"];
    return YES;
}

- (IBAction)setLineEnding:(NSMenuItem *)sender {
    if ([self rejectIfReadOnly]) return;
    int mode = (int)sender.tag;
    Document *doc = self.doc;
    // 即使模式相同也統一轉換一次，可修正混合換行的檔案
    doc.eolMode = mode;
    [self send:SCI_SETEOLMODE w:mode];
    [self send:SCI_CONVERTEOLS w:mode];
    [doc updateChangeCount:NSChangeDone];
    [self updateStatus];
}

- (IBAction)setSaveEncoding:(NSMenuItem *)sender {
    Document *doc = self.doc;
    N2Encoding enc = (N2Encoding)sender.tag;
    if (doc.encoding == enc) return;
    if ([self rejectIfReadOnly]) return;
    doc.encoding = enc;
    [doc updateChangeCount:NSChangeDone];
    [self updateStatus];
}

- (IBAction)reopenWithEncoding:(NSMenuItem *)sender {
    Document *doc = self.doc;
    if (!doc.fileURL) { NSBeep(); return; }
    N2Encoding enc = (N2Encoding)sender.tag;
    void (^reload)(void) = ^{
        NSError *err = nil;
        if (![doc reloadWithEncoding:enc error:&err] && err)
            [self presentError:err modalForWindow:self.window delegate:nil didPresentSelector:nil contextInfo:NULL];
    };
    if (!doc.isDocumentEdited) { reload(); return; }
    NSAlert *a = [NSAlert new];
    a.messageText = @"要捨棄未儲存的修改嗎？";
    a.informativeText = [NSString stringWithFormat:@"將以「%@」重新讀取檔案，目前的修改會遺失。", N2EncodingDisplayName(enc)];
    [a addButtonWithTitle:@"重新載入"];
    [a addButtonWithTitle:@"取消"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) reload();
    }];
}

#pragma mark - 跳至行

- (IBAction)goToLine:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = @"跳至行";
    a.informativeText = [NSString stringWithFormat:@"輸入行號（1～%ld），也可以輸入「行,欄」。", (long)[self send:SCI_GETLINECOUNT]];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    sptr_t cur = [self send:SCI_LINEFROMPOSITION w:[self send:SCI_GETCURRENTPOS]];
    field.stringValue = [NSString stringWithFormat:@"%ld", (long)cur + 1];
    a.accessoryView = field;
    [a addButtonWithTitle:@"跳至"];
    [a addButtonWithTitle:@"取消"];
    a.window.initialFirstResponder = field;
    ScintillaView *v = self.sci;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSArray *parts = [field.stringValue componentsSeparatedByCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@",:，： "]];
        NSInteger ln = [parts.firstObject integerValue];
        NSInteger col = parts.count > 1 ? [parts[1] integerValue] : 1;
        if (ln < 1) { NSBeep(); return; }
        sptr_t maxLine = S(v, SCI_GETLINECOUNT);
        if (ln > maxLine) ln = maxLine;
        sptr_t pos = S(v, SCI_FINDCOLUMN, ln - 1, MAX(col, 1) - 1);
        S(v, SCI_ENSUREVISIBLEENFORCEPOLICY, ln - 1);
        S(v, SCI_GOTOPOS, pos);
        S(v, SCI_SCROLLCARET);
        [self.window makeFirstResponder:v.content];
    }];
}

#pragma mark - 尋找／取代

- (IBAction)showFindPanel:(id)sender { [N2FindPanel.shared showFind:self.selectedText]; }
- (IBAction)showReplacePanel:(id)sender { [N2FindPanel.shared showReplace:self.selectedText]; }
- (IBAction)findNextText:(id)sender { [N2FindPanel.shared findNext:YES]; }
- (IBAction)findPreviousText:(id)sender { [N2FindPanel.shared findNext:NO]; }
- (IBAction)useSelectionForFind:(id)sender {
    NSString *s = self.selectedText;
    if (s.length) N2FindPanel.shared.findString = s;
}

static int SciFlags(N2FindOptions o) {
    int f = 0;
    if (o & N2FindMatchCase) f |= SCFIND_MATCHCASE;
    if (o & N2FindWholeWord) f |= SCFIND_WHOLEWORD;
    if (o & N2FindRegex) f |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    return f;
}

// 在 [start, end) 搜尋（start > end 代表往回找）；回傳找到的起點或 -1，-2 代表規則錯誤
- (sptr_t)search:(NSData *)needle from:(sptr_t)start to:(sptr_t)end flags:(int)flags {
    [self send:SCI_SETTARGETSTART w:start];
    [self send:SCI_SETTARGETEND w:end];
    [self send:SCI_SETSEARCHFLAGS w:flags];
    [self send:SCI_SETSTATUS w:SC_STATUS_OK];
    sptr_t r = [self send:SCI_SEARCHINTARGET w:needle.length l:(sptr_t)needle.bytes];
    if ([self send:SCI_GETSTATUS] == SC_STATUS_WARN_REGEX) {
        [self send:SCI_SETSTATUS w:SC_STATUS_OK];
        return -2;
    }
    return r;
}

- (N2FindResult)findString:(NSString *)text options:(N2FindOptions)options forward:(BOOL)forward {
    NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (needle.length == 0) return N2FindNotFound;
    int flags = SciFlags(options);
    sptr_t len = [self send:SCI_GETLENGTH];
    sptr_t selA = [self send:SCI_GETSELECTIONSTART], selB = [self send:SCI_GETSELECTIONEND];
    BOOL wrapped = NO;
    sptr_t found;
    if (forward) {
        found = [self search:needle from:selB to:len flags:flags];
        // 正規表示式找到空字串且位置沒變，往後跳一個字元
        if (found == selB && [self send:SCI_GETTARGETEND] == found && selA == selB && selB < len)
            found = [self search:needle from:[self send:SCI_POSITIONAFTER w:selB] to:len flags:flags];
        if (found == -1 && (options & N2FindWrap)) { found = [self search:needle from:0 to:len flags:flags]; wrapped = YES; }
    } else {
        found = [self search:needle from:selA to:0 flags:flags];
        if (found == -1 && (options & N2FindWrap)) { found = [self search:needle from:len to:0 flags:flags]; wrapped = YES; }
    }
    if (found == -2) return N2FindInvalidPattern;
    if (found < 0) return N2FindNotFound;
    sptr_t tA = [self send:SCI_GETTARGETSTART], tB = [self send:SCI_GETTARGETEND];
    sptr_t line = [self send:SCI_LINEFROMPOSITION w:tA];
    [self send:SCI_ENSUREVISIBLEENFORCEPOLICY w:line];
    [self send:SCI_SETSEL w:tA l:tB];
    [self send:SCI_SCROLLRANGE w:tB l:tA];
    return wrapped ? N2FindFoundWrapped : N2FindFound;
}

- (N2FindResult)replaceString:(NSString *)text with:(NSString *)replacement options:(N2FindOptions)options {
    NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (needle.length == 0) return N2FindNotFound;
    int flags = SciFlags(options);
    if ([self rejectIfReadOnly]) return N2FindNotFound;
    sptr_t selA = [self send:SCI_GETSELECTIONSTART], selB = [self send:SCI_GETSELECTIONEND];
    // 目前選取正好是一個符合項目才取代
    sptr_t f = [self search:needle from:selA to:selB flags:flags];
    if (f == -2) return N2FindInvalidPattern;
    if (f == selA && [self send:SCI_GETTARGETEND] == selB && selB > selA) {
        NSData *rep = [replacement dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        sptr_t newLen = (options & N2FindRegex)
            ? [self send:SCI_REPLACETARGETRE w:rep.length l:(sptr_t)rep.bytes]
            : [self send:SCI_REPLACETARGET w:rep.length l:(sptr_t)rep.bytes];
        [self send:SCI_SETSEL w:selA + newLen l:selA + newLen];
    }
    return [self findString:text options:options forward:YES];
}

- (NSInteger)replaceAll:(NSString *)text with:(NSString *)replacement options:(N2FindOptions)options {
    NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (needle.length == 0) return 0;
    // 唯讀時 REPLACETARGET 不會修改內容卻照樣回傳長度，取代成空字串會無限迴圈
    if ([self rejectIfReadOnly]) return N2ReplaceAllReadOnly;
    NSData *rep = [replacement dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    int flags = SciFlags(options);
    BOOL regex = (options & N2FindRegex) != 0;
    NSInteger count = 0;
    sptr_t pos = 0;
    [self send:SCI_BEGINUNDOACTION];
    while (YES) {
        sptr_t len = [self send:SCI_GETLENGTH];
        if (pos > len) break;
        sptr_t f = [self search:needle from:pos to:len flags:flags];
        if (f == -2) { count = -1; break; }
        if (f < 0) break;
        sptr_t tA = [self send:SCI_GETTARGETSTART], tB = [self send:SCI_GETTARGETEND];
        sptr_t newLen = regex ? [self send:SCI_REPLACETARGETRE w:rep.length l:(sptr_t)rep.bytes]
                              : [self send:SCI_REPLACETARGET w:rep.length l:(sptr_t)rep.bytes];
        count++;
        pos = tA + newLen;
        if (tA == tB) {   // 空字串符合：往後移一格，避免無限迴圈
            if (pos >= [self send:SCI_GETLENGTH]) break;
            pos = [self send:SCI_POSITIONAFTER w:pos];
        }
    }
    [self send:SCI_ENDUNDOACTION];
    return count;
}

#pragma mark - 列印

- (NSAttributedString *)attributedTextForPrinting {
    ScintillaView *v = _primary;
    sptr_t len = S(v, SCI_GETLENGTH);
    S(v, SCI_COLOURISE, 0, -1);
    std::vector<char> styled((size_t)len * 2 + 2);
    Sci_TextRange tr;
    tr.chrg.cpMin = 0;
    tr.chrg.cpMax = (Sci_PositionCR)len;
    tr.lpstrText = styled.data();
    S(v, SCI_GETSTYLEDTEXT, 0, (sptr_t)&tr);

    BOOL invert = N2Settings.invertColors;
    CGFloat size = N2Settings.fontSize;
    NSFont *base = [NSFont fontWithName:N2Settings.fontName size:size] ?: [NSFont userFixedPitchFontOfSize:size];
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    CGFloat spaceW = [@" " sizeWithAttributes:@{NSFontAttributeName: base}].width;
    para.defaultTabInterval = spaceW * N2Settings.tabWidth;
    para.tabStops = @[];

    NSMutableDictionary<NSNumber *, NSDictionary *> *attrCache = [NSMutableDictionary dictionary];
    NSDictionary *(^attrsFor)(int) = ^NSDictionary *(int style) {
        NSDictionary *cached = attrCache[@(style)];
        if (cached) return cached;
        long fore = S(v, SCI_STYLEGETFORE, style);
        if (invert) fore ^= 0xFFFFFF;   // 列印一律用原本（未反轉）的顏色
        NSColor *color = [NSColor colorWithSRGBRed:(fore & 0xFF) / 255.0 green:((fore >> 8) & 0xFF) / 255.0
                                              blue:((fore >> 16) & 0xFF) / 255.0 alpha:1];
        NSFont *f = base;
        NSFontTraitMask traits = 0;
        if (S(v, SCI_STYLEGETBOLD, style)) traits |= NSBoldFontMask;
        if (S(v, SCI_STYLEGETITALIC, style)) traits |= NSItalicFontMask;
        if (traits) f = [NSFontManager.sharedFontManager convertFont:base toHaveTrait:traits];
        NSDictionary *d = @{NSFontAttributeName: f, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: para};
        attrCache[@(style)] = d;
        return d;
    };

    NSMutableAttributedString *out = [NSMutableAttributedString new];
    std::string run;
    int runStyle = -1;
    auto flush = [&]() {
        if (run.empty()) return;
        NSString *s = [[NSString alloc] initWithBytes:run.data() length:run.size() encoding:NSUTF8StringEncoding]
                      ?: [[NSString alloc] initWithBytes:run.data() length:run.size() encoding:NSISOLatin1StringEncoding];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:attrsFor(runStyle)]];
        run.clear();
    };
    for (sptr_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)styled[(size_t)i * 2];
        int st = (unsigned char)styled[(size_t)i * 2 + 1];
        // UTF-8 後續位元組不切段，避免切斷字元
        if (st != runStyle && (c & 0xC0) != 0x80) { flush(); runStyle = st; }
        run += (char)c;
    }
    flush();
    return out;
}

#pragma mark - 選單狀態

// 選單與工具列共用：原版 EXES 按鈕在空白文件中停用（人工智慧可對空白文件產生內容，維持可用）
- (BOOL)isActionAvailable:(SEL)a {
    Document *doc = self.doc;
    if (a == @selector(exesEncrypt:) || a == @selector(exesDecrypt:) || a == @selector(aesEncrypt:) || a == @selector(aesDecrypt:))
        return [self send:SCI_GETLENGTH] > 0;
    if (a == @selector(showVersionHistory:)) return doc.fileURL != nil && !doc.archiveLink;
    if (a == @selector(secureEraseFile:)) return doc.fileURL != nil || doc.archiveLink != nil;
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    Document *doc = self.doc;
    if (![self isActionAvailable:a]) return NO;
    struct { SEL sel; BOOL on; } toggles[] = {
        {@selector(toggleWordWrap:), N2Settings.wordWrap},
        {@selector(toggleLineNumbers:), N2Settings.showLineNumbers},
        {@selector(toggleStatusBar:), N2Settings.showStatusBar},
        {@selector(toggleWhitespace:), N2Settings.showWhitespace},
        {@selector(toggleEOLMarks:), N2Settings.showEOL},
        {@selector(toggleWrapSymbols:), N2Settings.wrapSymbols},
        {@selector(toggleIndentGuides:), N2Settings.indentGuides},
        {@selector(toggleLongLineMarker:), N2Settings.longLineMarker},
        {@selector(toggleMatchBraces:), N2Settings.matchBraces},
        {@selector(toggleHighlightLine:), N2Settings.highlightCurrentLine},
        {@selector(toggleHighlightSelection:), N2Settings.highlightSelection},
        {@selector(toggleInvertColors:), N2Settings.invertColors},
        {@selector(toggleAutoIndent:), N2Settings.autoIndent},
        {@selector(toggleTabsAsSpaces:), N2Settings.tabsAsSpaces},
        {@selector(splitNone:), _splitMode == N2SplitNone},
        {@selector(splitHorizontal:), _splitMode == N2SplitHorizontal},
        {@selector(splitVertical:), _splitMode == N2SplitVertical},
        {@selector(toggleToolbarVisible:), self.window.toolbar.visible},
        {@selector(toggleAlwaysOnTop:), self.window.level == NSFloatingWindowLevel},
    };
    for (auto &t : toggles) if (a == t.sel) { item.state = t.on ? NSControlStateValueOn : NSControlStateValueOff; return YES; }

    if (a == @selector(setLineEnding:)) item.state = (doc.eolMode == item.tag);
    else if (a == @selector(setSaveEncoding:)) item.state = (doc.encoding == item.tag);
    else if (a == @selector(reopenWithEncoding:)) return doc.fileURL != nil && !doc.isJpegDocument;
    else if (a == @selector(selectLanguage:)) {
        NSArray *ids = N2SyntaxLanguageIDs();
        if (item.tag < 0) item.state = (doc.languageID == nil);
        else item.state = (doc.languageID && item.tag < (NSInteger)ids.count && [ids[item.tag] isEqualToString:doc.languageID]);
    }
    return YES;
}

#pragma mark - 視窗

- (void)windowDidBecomeKey:(NSNotification *)n {
    [self ensureTabBarShown];
    NSResponder *fr = self.window.firstResponder;
    BOOL inEditor = [fr isKindOfClass:NSView.class] &&
                    ([(NSView *)fr isDescendantOf:_primary] || (_secondary && [(NSView *)fr isDescendantOf:_secondary]));
    if (!inEditor) [self.window makeFirstResponder:_primary.content];
    [self runPendingAutoDecrypt];
}

- (void)windowDidResize:(NSNotification *)n { [self updateStatus]; }

@end
