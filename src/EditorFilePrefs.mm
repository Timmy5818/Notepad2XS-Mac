// 個別檔案設定（對應 Windows 版 R155）與關閉時保存書籤（R156）
// - 語法：「格式 → 語法」選擇後記住；「此檔案恢復自動判斷語法」清除
// - 開檔編碼：「以指定編碼重新開啟」成功後記住；「以自動偵測編碼重新載入」清除；以不同編碼存檔時清除
// - 自動換行：「此檔案自動換行」切換並記住；「此檔案恢復預設換行」回到全域設定
// 設定存在文件旁的 .2xs（與書籤同一個 INI 的 [FileSettings]）；雲端文件存在雲端的逐檔設定
#import "EditorWindowController.h"
#import "Document.h"
#import "Settings.h"
#import "SyntaxStyles.h"
#import "Localization.h"
#import "ScintillaView.h"

@interface EditorWindowController (NavigationPrivate)
- (NSURL *)bookmarkURL:(NSString **)member;
@end

@implementation EditorWindowController (FilePrefs)

- (void)installFilePreferenceHook {
    __weak EditorWindowController *weakSelf = self;
    self.bookmarks.applyPreferences = ^{ [weakSelf applyFilePreferences]; };
}

- (int)filePreference:(N2FilePreference)p { return [self.bookmarks preference:p]; }

// 有本機路徑（含壓縮檔成員）或雲端文件才有個別設定
- (BOOL)hasFilePreferences {
    Document *doc = self.doc;
    if (doc.cloud) return YES;
    NSString *member = nil;
    return [self bookmarkURL:&member] != nil;
}

- (void)setFilePreference:(N2FilePreference)p value:(int)value {
    NSString *member = nil;
    NSURL *url = self.doc.cloud ? nil : [self bookmarkURL:&member];
    if (![self.bookmarks setPreference:p value:value url:url member:member])
        [self showMessage:N2L(@"無法儲存此檔案的個別設定。本次開啟期間仍會套用。") info:nil];
}

- (BOOL)effectiveWordWrap {
    int wrap = [self filePreference:N2FilePrefWordWrap];
    return wrap == -1 ? N2Settings.wordWrap : wrap == 1;
}

- (void)applyWordWrap {
    for (ScintillaView *v in self.allViews)
        [v message:SCI_SETWRAPMODE wParam:self.effectiveWordWrap ? SC_WRAP_WORD : SC_WRAP_NONE];
    [self updateStatus];
}

- (NSString *)fileNameForSyntax {
    Document *doc = self.doc;
    if (doc.archiveLink) return doc.archiveLink.memberPath.lastPathComponent;
    return doc.fileURL.lastPathComponent;
}

// 讀到設定後套用：語法（文件鎖定時不改）、換行、雲端文件的編碼
- (void)applyFilePreferences {
    Document *doc = self.doc;
    int syntax = [self filePreference:N2FilePrefSyntax];
    BOOL restyle = NO;
    if (!doc.isCryptoLocked && syntax != -1) {
        NSString *lang = N2LanguageForSyntaxResource(syntax, self.fileNameForSyntax);
        if (lang && ![lang isEqualToString:doc.languageID]) { doc.languageID = lang; restyle = YES; }
    }
    if (doc.cloud) {
        // EXES 明文固定是 UTF-8：只記住選擇，不轉換編輯區內容
        N2Encoding enc = N2EncodingUTF8;
        N2EncodingForReadResource([self filePreference:N2FilePrefEncoding], &enc);
        doc.encoding = enc;
    }
    if (restyle) [self applyLanguage];
    [self applyWordWrap];
}

#pragma mark - 選單動作

// 「此檔案自動換行」
- (IBAction)toggleFileWordWrap:(id)sender {
    if (!self.hasFilePreferences || self.doc.isCryptoLocked) { NSBeep(); return; }
    [self setFilePreference:N2FilePrefWordWrap value:self.effectiveWordWrap ? 0 : 1];
    [self applyWordWrap];
}

// 「此檔案恢復預設換行」
- (IBAction)resetFileWordWrap:(id)sender {
    if (!self.hasFilePreferences || self.doc.isCryptoLocked) { NSBeep(); return; }
    [self setFilePreference:N2FilePrefWordWrap value:-1];
    [self applyWordWrap];
}

// 「此檔案恢復自動判斷語法」
- (IBAction)resetFileSyntax:(id)sender {
    if (!self.hasFilePreferences || self.doc.isCryptoLocked) { NSBeep(); return; }
    [self setFilePreference:N2FilePrefSyntax value:-1];
    self.doc.languageID = nil;
    [self applyLanguage];
}

// 「語法」選單：選擇後記住這個檔案的語法
- (void)rememberSelectedLanguage {
    if (!self.hasFilePreferences || self.doc.isCryptoLocked) return;
    NSString *lang = self.doc.languageID;
    [self setFilePreference:N2FilePrefSyntax value:lang ? N2SyntaxResourceForLanguage(lang) : -1];
}

- (BOOL)canReloadWithEncoding {
    Document *doc = self.doc;
    if (doc.cloud) return !doc.isCryptoLocked;
    return doc.fileURL != nil && !doc.isImageDocument && doc.cryptoState == N2CryptoPlain;
}

// 「以指定編碼重新開啟」成功後記住；雲端文件只記住選擇
- (void)rememberReadEncoding:(N2Encoding)enc {
    [self setFilePreference:N2FilePrefEncoding value:N2EncodingReadResource(enc)];
}

// 「以自動偵測編碼重新載入」
- (IBAction)reloadWithAutoEncoding:(id)sender {
    Document *doc = self.doc;
    if (![self canReloadWithEncoding] || [self filePreference:N2FilePrefEncoding] == -1) { NSBeep(); return; }
    if (doc.cloud) {
        [self setFilePreference:N2FilePrefEncoding value:-1];
        doc.encoding = N2EncodingUTF8;
        [self updateStatus];
        return;
    }
    void (^reload)(void) = ^{
        [self saveBookmarks:N2BookmarkSaveViewOnly];
        NSError *err = nil;
        if (![doc reloadWithEncoding:(N2Encoding)-1 error:&err]) {
            if (err) [self presentError:err modalForWindow:self.window delegate:nil didPresentSelector:nil contextInfo:NULL];
            return;
        }
        [self setFilePreference:N2FilePrefEncoding value:-1];
        [self updateStatus];
    };
    if (!doc.isDocumentEdited) { reload(); return; }
    NSAlert *a = [NSAlert new];
    a.messageText = N2L(@"要捨棄未儲存的修改嗎？");
    a.informativeText = N2L(@"將以自動偵測的編碼重新讀取檔案，目前的修改會遺失。");
    [a addButtonWithTitle:N2L(@"重新載入")];
    [a addButtonWithTitle:N2L(@"取消")];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) reload();
    }];
}

// 存檔成功後：存檔編碼與指定的開檔編碼不同時，清除開檔編碼（下次開檔重新偵測）
- (void)fileEncodingSaved {
    // 比較實際的編碼（Windows 版可能寫入別名 ID，例如 GBK 61020、UTF-8 BOM 61007）
    int read = [self filePreference:N2FilePrefEncoding];
    N2Encoding preferred;
    if (read == -1 || !N2EncodingForReadResource(read, &preferred)) return;
    if (N2EncodingReadResource(preferred) != N2EncodingReadResource(self.doc.encoding))
        [self setFilePreference:N2FilePrefEncoding value:-1];
}

// R156：關閉分頁或結束程式時保存書籤。選「不儲存」時文字已被捨棄，只記錄檢視狀態，保留上次存的書籤
- (void)finalizeDocumentState {
    Document *doc = self.doc;
    if (!doc) return;
    if (doc.cloud) [self saveCloudViewIncludingBookmarks:!doc.isDocumentEdited];
    else [self saveBookmarks:doc.isDocumentEdited ? N2BookmarkSaveViewOnly : N2BookmarkSaveChanged];
}

- (BOOL)validateFilePreferenceItem:(NSMenuItem *)item handled:(BOOL *)handled {
    SEL a = item.action;
    *handled = YES;
    Document *doc = self.doc;
    BOOL usable = self.hasFilePreferences && !doc.isCryptoLocked;
    if (a == @selector(toggleFileWordWrap:)) {
        item.state = usable && self.effectiveWordWrap ? NSControlStateValueOn : NSControlStateValueOff;
        return usable;
    }
    if (a == @selector(resetFileWordWrap:)) return usable && [self filePreference:N2FilePrefWordWrap] != -1;
    if (a == @selector(resetFileSyntax:)) return usable && [self filePreference:N2FilePrefSyntax] != -1;
    if (a == @selector(reloadWithAutoEncoding:)) return [self canReloadWithEncoding] && [self filePreference:N2FilePrefEncoding] != -1;
    *handled = NO;
    return YES;
}

@end
