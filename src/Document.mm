#import "Document.h"
#import "EditorWindowController.h"
#import "SyntaxStyles.h"
#import "Settings.h"
#include "Scintilla.h"
#include "ExAlgorithms.h"
#include "AesAlgorithms.h"
#include "JpegCommentFormat.h"
#import "History.h"
#import <Security/SecRandom.h>

@implementation Document {
    NSData *_loadedText;
    NSData *_pendingSaveData;   // 已加密好、要直接寫入的位元組
    NSData *_jpegOriginal;      // JPEG 文件：原始圖片位元組（存檔時只替換 COM）
    NSURL *_saveTargetURL;      // 這次存檔的目的地
    NSUInteger _savedModCount;  // dataOfType 取文字時編輯區的修改次數
    NSData *_saveSnapshot;      // 存檔開始時（主執行緒）取下的全文；背景寫入時使用
}

static BOOL IsJpeg(NSURL *u) {
    NSString *e = u.pathExtension.lowercaseString;
    return [e isEqualToString:@"jpg"] || [e isEqualToString:@"jpeg"];
}

- (instancetype)init {
    if ((self = [super init])) {
        // 新文件的編碼與換行格式依偏好設定（開檔時會被實際判斷結果取代）
        _encoding = N2Settings.newDocumentEncoding;
        _eolMode = N2Settings.newDocumentEOL;
        _loadedText = [NSData data];
        // 復原／重做由 Scintilla 自己管理
        self.hasUndoManager = NO;
    }
    return self;
}

+ (BOOL)autosavesInPlace { return NO; }
+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName { return YES; }

- (NSData *)loadedText { return _loadedText; }

- (EditorWindowController *)editor {
    for (NSWindowController *wc in self.windowControllers)
        if ([wc isKindOfClass:EditorWindowController.class]) return (EditorWindowController *)wc;
    return nil;
}

- (NSString *)effectiveLanguageID {
    return self.languageID ?: N2SyntaxLanguageForFileName(self.fileURL.lastPathComponent);
}

- (void)makeWindowControllers {
    [self addWindowController:[[EditorWindowController alloc] init]];
}

#pragma mark - 讀檔

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError {
    N2Encoding enc = N2EncodingUTF8;
    NSData *utf8 = N2DecodeToUTF8(data, &enc, YES);
    [self applyLoadedText:utf8 encoding:enc];
    return YES;
}

- (BOOL)isCryptoLocked {
    return _cryptoState == N2CryptoLockedExternal || _cryptoState == N2CryptoLockedNewCipher;
}

- (void)clearCrypto {
    _cryptoState = N2CryptoPlain;
    _cryptoAlgorithm = N2CryptoNone;
    _credential = nil;   // N2Credential 釋放時會覆寫記憶體
    _pendingAutoDecrypt = NO;
}

- (void)applyLoadedText:(NSData *)utf8 encoding:(N2Encoding)enc {
    [self applyLoadedText:utf8 encoding:enc detectCrypto:YES];
}

- (void)applyLoadedText:(NSData *)utf8 encoding:(N2Encoding)enc detectCrypto:(BOOL)detect {
    // 開檔／重新載入：清除舊的密碼狀態，依內容開頭判斷是否為密文
    [self clearCrypto];
    N2CryptoAlgorithm alg = detect ? N2CryptoDetect((const char *)utf8.bytes, utf8.length) : N2CryptoNone;
    if (alg != N2CryptoNone) {
        _cryptoState = N2CryptoLockedExternal;
        _cryptoAlgorithm = alg;
        _pendingAutoDecrypt = YES;
    }
    _loadedText = utf8;
    _encoding = enc;
    _eolMode = N2DetectEOLMode((const char *)utf8.bytes, utf8.length, N2Settings.newDocumentEOL);
    // 回復到已儲存／重新載入時，視窗已經存在，直接更新內容
    EditorWindowController *ed = self.editor;
    if (ed) {
        dispatch_block_t apply = ^{ [ed loadDocumentText]; };
        if (NSThread.isMainThread) apply(); else dispatch_sync(dispatch_get_main_queue(), apply);
    }
}

#pragma mark - JPEG 內嵌文字（N2XSJPG1 COM，格式沿用 Windows 版 JpegCommentFormat）

static NSError *JpegError(NSString *msg, const std::string &detail) {
    return [NSError errorWithDomain:@"Notepad2XS.JPEG" code:1 userInfo:@{NSLocalizedDescriptionKey: msg,
        NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithUTF8String:detail.c_str()] ?: @""}];
}

- (BOOL)readJpeg:(NSData *)data error:(NSError **)outError {
    if (data.length > 512ull * 1024 * 1024) { if (outError) *outError = JpegError(@"JPEG 檔案超過 512 MiB。", ""); return NO; }
    std::vector<uint8_t> v((const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length);
    xs::jpeg::Payload p;
    std::string err;
    if (!xs::jpeg::extract(v, p, err)) { if (outError) *outError = JpegError(@"無法讀取 JPEG 內嵌文字。", err); return NO; }
    if (p.mode == xs::jpeg::Mode::Text && !xs::jpeg::validUtf8(p.bytes)) { if (outError) *outError = JpegError(@"JPEG 內嵌文字不是有效的 UTF-8。", ""); return NO; }
    _jpegOriginal = data;
    // TXT 模式是權威標記：即使文字以 X60 開頭也不會跳出密碼視窗
    [self applyLoadedText:[NSData dataWithBytes:p.bytes.data() length:p.bytes.size()] encoding:N2EncodingUTF8
             detectCrypto:p.mode != xs::jpeg::Mode::Text];
    return YES;
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
    _jpegOriginal = nil;
    if (IsJpeg(url)) {
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:outError];
        return data && [self readJpeg:data error:outError];
    }
    return [super readFromURL:url ofType:typeName error:outError];
}

- (BOOL)loadRawData:(NSData *)raw jpeg:(BOOL)jpeg error:(NSError **)error {
    if (jpeg) return [self readJpeg:raw error:error];
    return [self readFromData:raw ofType:@"public.plain-text" error:error];
}

// 產生要寫入 JPEG 的完整位元組：底圖沿用原圖／既有目的檔／內建預設底圖
- (NSData *)jpegDataFor:(NSURL *)target text:(NSData *)utf8 error:(NSError **)outError {
    NSData *base = nil;
    if (_jpegOriginal && [target.path isEqualToString:self.fileURL.path]) base = _jpegOriginal;
    else if ([NSFileManager.defaultManager fileExistsAtPath:target.path]) base = [NSData dataWithContentsOfURL:target];
    else base = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"JpegDefaultArtwork" ofType:@"jpg"]];
    if (!base) { if (outError) *outError = JpegError(@"找不到 JPEG 底圖。", ""); return nil; }
    xs::jpeg::Mode mode = xs::jpeg::Mode::Text;
    std::string bytes((const char *)utf8.bytes, utf8.length);
    if (_pendingSaveData) {   // 加密後的密文
        bytes.assign((const char *)_pendingSaveData.bytes, _pendingSaveData.length);
        mode = N2CryptoDetect(bytes.data(), bytes.size()) == N2CryptoEXES ? xs::jpeg::Mode::Exes : xs::jpeg::Mode::Aes;
    }
    std::array<uint8_t, 16> docId{};
    if (SecRandomCopyBytes(kSecRandomDefault, docId.size(), docId.data()) != errSecSuccess) {
        if (outError) *outError = JpegError(@"無法產生 JPEG 文件識別碼。", "");
        return nil;
    }
    std::vector<uint8_t> original((const uint8_t *)base.bytes, (const uint8_t *)base.bytes + base.length), result;
    std::string err;
    if (!xs::jpeg::replace(original, mode, bytes, docId, result, err)) { if (outError) *outError = JpegError(@"無法寫入 JPEG 內嵌文字。", err); return nil; }
    return [NSData dataWithBytes:result.data() length:result.size()];
}

- (BOOL)isJpegDocument { return self.fileURL && IsJpeg(self.fileURL); }

- (BOOL)reloadWithEncoding:(N2Encoding)encoding error:(NSError **)error {
    if (!self.fileURL) return NO;
    // JPEG：內嵌文字固定以 UTF-8 寫在 COM 區段，整個檔案不能當成文字解碼（存回去會毀掉圖片）
    if (IsJpeg(self.fileURL)) {
        if (error) *error = [NSError errorWithDomain:@"Notepad2XS" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"JPEG 文件不能用其他編碼重新載入。",
            NSLocalizedRecoverySuggestionErrorKey: @"JPEG 內嵌文字固定使用 UTF-8。"}];
        return NO;
    }
    NSData *raw = [NSData dataWithContentsOfURL:self.fileURL options:0 error:error];
    if (!raw) return NO;
    N2Encoding enc = encoding;
    NSData *utf8 = N2DecodeToUTF8(raw, &enc, NO);
    if (!utf8) {
        if (error) *error = [NSError errorWithDomain:@"Notepad2XS" code:2 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"無法用「%@」解讀這個檔案。", N2EncodingDisplayName(encoding)]
        }];
        return NO;
    }
    [self applyLoadedText:utf8 encoding:enc];
    [self updateChangeCount:NSChangeCleared];
    return YES;
}

#pragma mark - 存檔

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError {
    __block NSData *utf8 = _saveSnapshot;
    dispatch_block_t grab = ^{ utf8 = [self.editor textAsUTF8]; self->_savedModCount = self.editor.modificationCount; };
    if (!utf8) { if (NSThread.isMainThread) grab(); else dispatch_sync(dispatch_get_main_queue(), grab); }
    if (!utf8) utf8 = _loadedText;
    NSURL *target = _saveTargetURL ?: self.fileURL;
    if (IsJpeg(target)) return [self jpegDataFor:target text:utf8 error:outError];   // JPEG：文字一律 UTF-8 寫入 COM
    if (_pendingSaveData) return _pendingSaveData;   // 加密後的 ASCII 密文
    return N2EncodeFromUTF8((const char *)utf8.bytes, utf8.length, self.encoding, outError);
}

- (BOOL)writeSafelyToURL:(NSURL *)url ofType:(NSString *)typeName
        forSaveOperation:(NSSaveOperationType)saveOperation error:(NSError **)outError {
    // 版本歷史：先備份即將被覆蓋的舊檔，備份失敗就停止儲存（壓縮檔暫存工作檔不備份）
    BOOL userSave = saveOperation == NSSaveOperation || saveOperation == NSSaveAsOperation || saveOperation == NSSaveToOperation;
    if (userSave && !N2IsArchiveWorkURL(url) && !N2HistoryBackup(url, outError)) return NO;
    BOOL ok = [super writeSafelyToURL:url ofType:typeName forSaveOperation:saveOperation error:outError];
    // 背景寫入時：暫存檔已寫好，接下來的壓縮檔回存可能很久，先讓使用者繼續操作
    if (!NSThread.isMainThread) [self unblockUserInteraction];
    if (ok && userSave && !N2IsArchiveWorkURL(url)) N2HistoryPrune(url);
    if (ok && IsJpeg(url) && saveOperation != NSSaveToOperation) _jpegOriginal = [NSData dataWithContentsOfURL:url];
    // 壓縮檔內文件：暫存檔寫好後，寫回壓縮檔（驗證通過才替換原檔）
    if (ok && self.archiveLink && [url.path isEqualToString:self.archiveLink.workURL.path] &&
        (saveOperation == NSSaveOperation || saveOperation == NSSaveAsOperation)) {
        ok = [self.archiveLink writeBack:outError];
    }
    if (ok && (saveOperation == NSSaveOperation || saveOperation == NSSaveAsOperation)) {
        NSUInteger count = _savedModCount;   // 取文字那一刻的修改次數
        dispatch_async(dispatch_get_main_queue(), ^{ [self.editor markSavedAtModification:count]; });
    }
    return ok;
}

#pragma mark - 加密存檔

static NSError *CryptoError(NSString *message, NSString *suggestion) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (suggestion) info[NSLocalizedRecoverySuggestionErrorKey] = suggestion;
    return [NSError errorWithDomain:@"Notepad2XS" code:10 userInfo:info];
}

static NSError *Cancelled(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

static N2CryptoAlgorithm ForcedAlgorithm(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"x60"]) return N2CryptoEXES;
    if ([ext isEqualToString:@"u2f"]) return N2CryptoAES;
    return N2CryptoNone;
}

- (std::string)currentUTF8 {
    NSData *d = [self.editor textAsUTF8] ?: _loadedText;
    return std::string((const char *)d.bytes, d.length);
}

// 加密目前文字，完成後回傳 ASCII 密文
- (void)encryptCurrentWith:(N2CryptoAlgorithm)alg credential:(N2Credential *)cred
                completion:(void (^)(NSData *cipher, NSError *error))completion {
    std::string text = [self currentUTF8];
    NSWindow *w = self.editor.window;
    NSString *title = [NSString stringWithFormat:@"%@ 加密後儲存", N2CryptoName(alg)];
    N2RunCryptoJob(w, title, ^std::string {
        std::string pw = cred.secret;
        std::string out = alg == N2CryptoEXES ? xs::exesEncrypt(text, pw) : xs::aesEncrypt(text, pw);
        std::fill(pw.begin(), pw.end(), '\0');
        return out;
    }, ^(BOOL ok, const std::string &result, NSString *err) {
        if (!ok) completion(nil, CryptoError(@"加密失敗，沒有儲存檔案。",
                                             @"文字可能超過 64 MiB，或含有無效的字元。不會改用明文儲存。"));
        else completion([NSData dataWithBytes:result.data() length:result.size()], nil);
    });
}

// 取得新的加密密碼並加密（目的副檔名是 .x60／.u2f，但目前沒有可用的密碼）
// persist=NO（儲存複本）：只加密這份輸出，不改變文件本身的加密狀態與密碼
- (void)askAndEncrypt:(N2CryptoAlgorithm)alg persist:(BOOL)persist completion:(void (^)(NSData *cipher, NSError *error))completion {
    [N2PasswordDialog runForWindow:self.editor.window algorithm:alg encrypt:YES completion:^(N2Credential *cred) {
        if (!cred) { completion(nil, Cancelled()); return; }
        [self encryptCurrentWith:alg credential:cred completion:^(NSData *cipher, NSError *error) {
            if (cipher && persist) {
                // 之後一般儲存沿用這組密碼自動加密
                self.cryptoState = N2CryptoDecryptedAuto;
                self.cryptoAlgorithm = alg;
                self.credential = cred;
            }
            completion(cipher, error);
        }];
    }];
}

// 決定這次存檔要寫入什麼：nil 代表照一般文字流程
- (void)prepareSaveTo:(NSURL *)url operation:(NSSaveOperationType)op completion:(void (^)(NSData *data, NSError *error))completion {
    N2CryptoAlgorithm forced = ForcedAlgorithm(url);
    BOOL persist = op != NSSaveToOperation;
    std::string text = [self currentUTF8];
    N2CryptoAlgorithm textAlg = N2CryptoDetect(text.data(), text.size());
    NSData *raw = [NSData dataWithBytes:text.data() length:text.size()];

    switch (_cryptoState) {
        case N2CryptoLockedExternal:
            completion(nil, CryptoError(@"這是尚未解密的密文，不能儲存。",
                                        @"請先用「工具 → 加解密」輸入正確密碼解密。"));
            return;
        case N2CryptoLockedNewCipher:
            if (forced != N2CryptoNone && forced != _cryptoAlgorithm) {
                completion(nil, CryptoError([NSString stringWithFormat:@"目前的密文是 %@ 格式，和副檔名不符。", N2CryptoName(_cryptoAlgorithm)],
                                            @".x60 必須是 EXES 密文，.u2f 必須是 AES 密文。"));
                return;
            }
            if (textAlg != _cryptoAlgorithm) { completion(nil, CryptoError(@"密文內容和記錄的格式不符，已取消儲存。", nil)); return; }
            completion(raw, nil);   // 原樣保存密文，不再加密一次
            return;
        case N2CryptoDecryptedAuto:
        case N2CryptoDecryptedManual: {
            if (forced != N2CryptoNone && forced != _cryptoAlgorithm) {
                [self askAndEncrypt:forced persist:persist completion:completion];
                return;
            }
            if (_cryptoState == N2CryptoDecryptedAuto || forced != N2CryptoNone) {
                [self encryptCurrentWith:_cryptoAlgorithm credential:_credential completion:completion];
                return;
            }
            NSAlert *a = [NSAlert new];
            a.messageText = [NSString stringWithFormat:@"這份文件是手動 %@ 解密的，要怎麼儲存？", N2CryptoName(_cryptoAlgorithm)];
            a.informativeText = @"「加密後保存」會使用解密時的密碼重新加密。";
            [a addButtonWithTitle:@"加密後保存"];
            [a addButtonWithTitle:@"不加密保存"];
            [a addButtonWithTitle:@"取消"];
            [a beginSheetModalForWindow:self.editor.window completionHandler:^(NSModalResponse r) {
                if (r == NSAlertFirstButtonReturn) [self encryptCurrentWith:self.cryptoAlgorithm credential:self.credential completion:completion];
                else if (r == NSAlertSecondButtonReturn) completion(nil, nil);
                else completion(nil, Cancelled());
            }];
            return;
        }
        case N2CryptoPlain:
        default:
            if (forced == N2CryptoNone) { completion(nil, nil); return; }
            if (textAlg == forced) { completion(raw, nil); return; }   // 已經是同格式密文，不重複加密
            if (textAlg != N2CryptoNone) {
                completion(nil, CryptoError([NSString stringWithFormat:@"文件內容是 %@ 密文，不能存成這個副檔名。", N2CryptoName(textAlg)],
                                            @"請先解密，再另存新檔。"));
                return;
            }
            [self askAndEncrypt:forced persist:persist completion:completion];
            return;
    }
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op
completionHandler:(void (^)(NSError *))handler {
    if (op == NSAutosaveElsewhereOperation || op == NSAutosaveInPlaceOperation || op == NSAutosaveAsOperation) {
        // 加密相關文件不做自動儲存（避免明文落地）
        if (_cryptoState != N2CryptoPlain || ForcedAlgorithm(url) != N2CryptoNone) { handler(nil); return; }
        [super saveToURL:url ofType:typeName forSaveOperation:op completionHandler:handler];
        return;
    }
    [self prepareSaveTo:url operation:op completion:^(NSData *data, NSError *error) {
        if (error) { handler(error); return; }
        self->_pendingSaveData = data;
        self->_saveTargetURL = url;
        // 在主執行緒先取下全文與修改次數：壓縮檔回存在背景執行，背景不能再回主執行緒取文字
        self->_saveSnapshot = [self.editor textAsUTF8];
        self->_savedModCount = self.editor.modificationCount;
        [super saveToURL:url ofType:typeName forSaveOperation:op completionHandler:^(NSError *e) {
            self->_pendingSaveData = nil;
            self->_saveTargetURL = nil;
            self->_saveSnapshot = nil;
            [self.editor updateCryptoAppearance];
            handler(e);
        }];
    }];
}

// 壓縮檔內文件：回存（解開、重建、驗證）可能很久，改在背景寫入，畫面不會卡住
- (BOOL)canAsynchronouslyWriteToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op {
    return self.archiveLink && [url.path isEqualToString:self.archiveLink.workURL.path] &&
           (op == NSSaveOperation || op == NSSaveAsOperation);
}

- (NSString *)displayName {
    if (self.archiveLink && [self.fileURL.path isEqualToString:self.archiveLink.workURL.path])
        return [NSString stringWithFormat:@"%@（%@）", self.archiveLink.memberPath, self.archiveLink.archiveURL.lastPathComponent];
    return [super displayName];
}

- (void)close {
    [self.archiveLink cleanup];
    self.archiveLink = nil;
    [self clearCrypto];
    [super close];
}

- (void)setFileURL:(NSURL *)fileURL {
    BOOL changed = ![fileURL isEqual:self.fileURL];
    // 另存到別的位置後就是一般檔案，不再寫回壓縮檔
    if (changed && self.archiveLink && fileURL && ![fileURL.path isEqualToString:self.archiveLink.workURL.path]) {
        [self.archiveLink cleanup];
        self.archiveLink = nil;
    }
    [super setFileURL:fileURL];
    // 另存新檔改了副檔名時，重新套用語法上色
    if (changed && !self.languageID) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self.editor applyLanguage]; });
    }
}

#pragma mark - 列印

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary<NSPrintInfoAttributeKey, id> *)printSettings
                                           error:(NSError **)outError {
    NSPrintInfo *info = [self.printInfo copy];
    [info.dictionary addEntriesFromDictionary:printSettings];
    info.horizontalPagination = NSPrintingPaginationModeFit;
    info.verticalPagination = NSPrintingPaginationModeAutomatic;
    info.verticallyCentered = NO;
    info.dictionary[NSPrintHeaderAndFooter] = @YES;   // 頁首：文件名稱與日期；頁尾：頁碼

    NSSize paper = info.paperSize;
    CGFloat width = paper.width - info.leftMargin - info.rightMargin;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, 100)];
    tv.textContainer.widthTracksTextView = YES;
    tv.horizontallyResizable = NO;
    tv.verticallyResizable = YES;
    tv.drawsBackground = NO;
    NSAttributedString *text = self.editor.attributedTextForPrinting ?: [NSAttributedString new];
    [tv.textStorage setAttributedString:text];
    [tv.layoutManager ensureLayoutForTextContainer:tv.textContainer];
    [tv sizeToFit];

    NSPrintOperation *op = [NSPrintOperation printOperationWithView:tv printInfo:info];
    op.jobTitle = self.displayName;
    op.showsPrintPanel = YES;
    op.showsProgressPanel = YES;
    return op;
}

// 存檔視窗允許任何副檔名
- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel {
    savePanel.allowsOtherFileTypes = YES;
    savePanel.extensionHidden = NO;
    savePanel.canSelectHiddenExtension = NO;
    savePanel.allowedContentTypes = @[];
    if (!self.fileURL) savePanel.nameFieldStringValue = [self.displayName stringByAppendingPathExtension:@"txt"];
    return YES;
}

- (NSString *)fileNameExtensionForType:(NSString *)typeName saveOperation:(NSSaveOperationType)saveOperation {
    return nil;
}

@end
