// 編輯視窗的雲端動作：開啟雲端檔案、存到雲端、⌘S 存回雲端、逐檔設定（對應 Windows 版 Notepad2.c 的雲端分頁流程）
#import "EditorWindowController.h"
#import "Document.h"
#import "CloudFiles.h"
#import "CryptoUI.h"
#import "Localization.h"
#import "ScintillaView.h"
#include "ExAlgorithms.h"
#include <string>

static NSArray<Document *> *AllDocuments(void) {
    NSMutableArray *docs = [NSMutableArray array];
    for (NSDocument *d in NSDocumentController.sharedDocumentController.documents)
        if ([d isKindOfClass:Document.class]) [docs addObject:d];
    return docs;
}

static Document *DocumentForCloud(N2CloudFile *file) {
    for (Document *d in AllDocuments()) if ([d.cloud isSameFile:file]) return d;
    return nil;
}

// 雲端清單重新整理、更名或搬移後：更新已開啟分頁的標題
static void RefreshCloudTitle(N2CloudFile *metadata) {
    Document *d = DocumentForCloud(metadata);
    if (!d || ([d.cloud.title isEqualToString:metadata.title] && [d.cloud.folder isEqualToString:metadata.folder])) return;
    d.cloud.name = metadata.name;
    d.cloud.folder = metadata.folder;
    d.cloud.title = metadata.title;
    for (NSWindowController *wc in d.windowControllers) [wc synchronizeWindowTitleWithDocumentName];
}

void N2OpenCloudFiles(EditorWindowController *anchor) {
    N2CloudFile *file = N2CloudBrowse(anchor.window, ^(N2CloudFile *meta) { RefreshCloudTitle(meta); });
    if (!file) return;
    Document *existing = DocumentForCloud(file);
    if (existing) {
        [existing.editor.window makeKeyAndOrderFront:nil];
        return;
    }
    NSError *err = nil;
    NSDocumentController *dc = NSDocumentController.sharedDocumentController;
    Document *doc = (Document *)[dc openUntitledDocumentAndDisplay:NO error:&err];
    if (![doc isKindOfClass:Document.class]) { if (err) [NSApp presentError:err]; return; }
    doc.cloud = file;
    [doc makeWindowControllers];
    EditorWindowController *ed = doc.editor;
    [doc loadCloudCiphertext:file.payload];   // 密文：唯讀，視窗出現後詢問密碼
    file.payload = nil;
    // 逐檔設定在解密後才套用（書籤、游標、語法、編碼、換行）
    NSData *state = N2CloudLoadState(anchor.window, file);
    if (state && ![ed.bookmarks stageCloudState:state]) N2CloudMessage(anchor.window, N2L(@"無法讀取這份雲端檔案的逐檔設定。"));
    NSWindow *w = ed.window;
    if (anchor.window) {
        w.tabbingMode = NSWindowTabbingModeAutomatic;
        [anchor.window addTabbedWindow:w ordered:NSWindowAbove];
    }
    [ed synchronizeWindowTitleWithDocumentName];
    [doc showWindows];
    [w makeKeyAndOrderFront:nil];
    // 啟動時自動建立、沒有內容的空白分頁：關掉它
    Document *anchorDoc = anchor.doc;
    if (anchorDoc && anchorDoc != doc && !anchorDoc.fileURL && !anchorDoc.cloud && !anchorDoc.isDocumentEdited &&
        anchor.textAsUTF8.length == 0)
        [anchorDoc close];
}

@implementation EditorWindowController (Cloud)

- (IBAction)showCloudFiles:(id)sender { N2OpenCloudFiles(self); }
- (IBAction)showCloudSettings:(id)sender { N2CloudShowSettings(self.window); }

- (BOOL)canSaveToCloud {
    Document *doc = self.doc;
    if (doc.fileURL || doc.cloud) return NO;
    // 選單檢查只看長度與開頭（完整檢查在執行時）
    sptr_t len = [self.primarySci message:SCI_GETLENGTH];
    if (len < 203 || (len - 203) % 5) return NO;
    const char *p = (const char *)[self.primarySci message:SCI_GETCHARACTERPOINTER];
    return p && p[0] == 'X' && p[1] == '6' && p[2] == '0';
}

// 「存到雲端」：把已 EXES 加密（內容是 X60 密文）的新分頁上傳
- (IBAction)saveToCloud:(id)sender {
    Document *doc = self.doc;
    if (![self canSaveToCloud]) { NSBeep(); return; }
    NSData *text = self.textAsUTF8;
    if (!N2CloudCanSaveX60(text)) { N2CloudMessage(self.window, N2L(@"檔案內容不符合 X60 格式。")); return; }
    NSUInteger count = self.modificationCount;
    N2CloudFile *file = N2CloudSaveNew(self.window, text,
        ^BOOL(N2CloudFile *f) { return DocumentForCloud(f) != nil; },
        ^BOOL { return self.modificationCount == count && !doc.cloud && !doc.fileURL; });
    if (!file) return;
    doc.cloud = file;
    // 上傳成功：分頁顯示雲端檔名並保留密文（已鎖定），解密後即可繼續編輯與儲存
    doc.cryptoState = N2CryptoLockedExternal;
    doc.cryptoAlgorithm = N2CryptoEXES;
    doc.credential = nil;
    doc.pendingAutoDecrypt = NO;
    doc.encoding = N2EncodingUTF8;
    [self markSavedAtModification:count];
    [doc updateChangeCount:NSChangeCleared];
    [self updateCryptoAppearance];
    [self synchronizeWindowTitleWithDocumentName];
    NSData *initial = doc.cloudInitialState;
    doc.cloudInitialState = nil;
    NSData *state = N2CloudLoadState(self.window, file);
    if (!state) return;
    if (state.length) {
        [self.bookmarks stageCloudState:state];
    } else if (initial.length) {
        // 雲端沒有逐檔設定：寫入加密前的書籤與檢視，解密後還原
        [self.bookmarks stageCloudState:initial];
        N2CloudSaveState(self.window, file, initial);
    }
}

// EXES 加密前記住書籤與檢視（之後存到雲端時當作初始逐檔設定）
- (void)rememberStateBeforeEncryption {
    Document *doc = self.doc;
    if (doc.cloud) return;
    doc.cloudInitialState = [self.bookmarks cloudSnapshot:self.sci includeBookmarks:YES];
}

// ⌘S：以解密時的密碼 EXES 加密後覆蓋雲端（版本不符時拒絕，避免蓋掉別人的修改）
- (void)saveCloudDocument:(void (^)(BOOL))completion {
    Document *doc = self.doc;
    N2CloudFile *file = doc.cloud;
    void (^finish)(BOOL) = ^(BOOL ok) { if (completion) completion(ok); };
    if (!file) { finish(NO); return; }
    BOOL decrypted = (doc.cryptoState == N2CryptoDecryptedAuto || doc.cryptoState == N2CryptoDecryptedManual) &&
                     doc.cryptoAlgorithm == N2CryptoEXES && doc.credential;
    if (!decrypted) { N2CloudMessage(self.window, N2L(@"請先解密這份 X60 文件，再儲存至雲端。")); finish(NO); return; }
    if (!doc.isDocumentEdited) {
        [self saveCloudViewIncludingBookmarks:YES];
        finish(YES);
        return;
    }
    NSData *text = self.textAsUTF8;
    if (text.length > 64ull * 1024 * 1024) { N2CloudMessage(self.window, N2L(@"檔案超過可處理的大小。")); finish(NO); return; }
    NSUInteger count = self.modificationCount;
    std::string plain((const char *)text.bytes, text.length);
    N2Credential *cred = doc.credential;
    N2RunCryptoJob(self.window, [NSString stringWithFormat:@"%@ %@", @"EXES", N2L(@"加密中")], ^std::string {
        std::string pw = cred.secret;
        std::string out = xs::exesEncrypt(plain, pw);
        std::fill(pw.begin(), pw.end(), '\0');
        return out;
    }, ^(BOOL ok, const std::string &cipher, NSString *err) {
        if (!ok || self.modificationCount != count || doc.cloud != file) {
            N2CloudMessage(self.window, N2L(@"雲端儲存未完成，請確認後重試。"));
            finish(NO);
            return;
        }
        NSData *bytes = [NSData dataWithBytes:cipher.data() length:cipher.size()];
        if (!N2CloudUpload(self.window, file, bytes)) { finish(NO); return; }
        if (self.modificationCount != count) {
            N2CloudMessage(self.window, N2L(@"雲端儲存未完成，請確認後重試。"));
            finish(NO);
            return;
        }
        [self markSavedAtModification:count];
        [doc updateChangeCount:NSChangeCleared];
        [self synchronizeWindowTitleWithDocumentName];
        [self saveCloudViewIncludingBookmarks:YES];
        [self updateStatus];
        finish(YES);
    });
}

- (BOOL)validateCloudItem:(NSMenuItem *)item handled:(BOOL *)handled {
    *handled = YES;
    if (item.action == @selector(saveToCloud:)) return [self canSaveToCloud];
    if (item.action == @selector(revertDocumentToSaved:) && self.doc.cloud) return NO;
    *handled = NO;
    return YES;
}

// 逐檔設定：⌘S 與關閉分頁時保存；捨棄修改時（includeBookmarks=NO）保留原先儲存的書籤
- (void)saveCloudViewIncludingBookmarks:(BOOL)includeBookmarks {
    Document *doc = self.doc;
    N2CloudFile *file = doc.cloud;
    // 還沒解密（設定尚未套用）時，畫面是密文：不能拿來覆蓋雲端的書籤與檢視
    if (!file || doc.isCryptoLocked || self.bookmarks.hasPendingCloudState || !file.prefsRevision.length) return;
    NSData *state = [self.bookmarks cloudSnapshot:self.sci includeBookmarks:includeBookmarks];
    if (!state || [state isEqualToData:file.prefsState ?: [NSData data]]) return;
    if (N2CloudSaveState(self.window, file, state)) [self.bookmarks commitCloudSnapshot:state];
}

@end
