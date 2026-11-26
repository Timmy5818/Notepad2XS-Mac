// 編輯視窗的加解密指令：EXES／AES 加密與解密、開檔自動解密、鎖定外觀、EX_MD3 雜湊
#import "EditorWindowController.h"
#import "Document.h"
#import "CryptoUI.h"
#import "AiUI.h"
#import "ScintillaView.h"
#include "ExAlgorithms.h"
#include "AesAlgorithms.h"
#include <string>

@implementation EditorWindowController (Crypto)

static sptr_t SC(ScintillaView *v, unsigned int msg, uptr_t w = 0, sptr_t l = 0) { return [v message:msg wParam:w lParam:l]; }

#pragma mark - 外觀

// 鎖定時：唯讀、文字與游標改成灰色（由 applyViewSettings 在套用樣式後呼叫）
- (void)applyLockAppearance:(ScintillaView *)v {
    BOOL locked = self.doc.isCryptoLocked;
    SC(v, SCI_SETREADONLY, locked);
    if (!locked) return;
    for (int st = 0; st <= STYLE_MAX; st++) {
        if (st == STYLE_LINENUMBER) continue;
        SC(v, SCI_STYLESETFORE, st, 0x909090);
        SC(v, SCI_STYLESETBOLD, st, 0);
    }
    SC(v, SCI_SETCARETFORE, 0x909090);
}

- (void)updateCryptoAppearance {
    Document *doc = self.doc;
    NSString *name = N2CryptoName(doc.cryptoAlgorithm);
    NSString *sub = @"";
    switch (doc.cryptoState) {
        case N2CryptoDecryptedAuto:
        case N2CryptoDecryptedManual: sub = [NSString stringWithFormat:@"%@｜已解密", name]; break;
        case N2CryptoLockedExternal: sub = [NSString stringWithFormat:@"%@ 密文・已鎖定（請解密）", name]; break;
        case N2CryptoLockedNewCipher: sub = [NSString stringWithFormat:@"%@ 密文・唯讀", name]; break;
        default: break;
    }
    self.window.subtitle = sub;
    [self applyLanguage];   // 重新套用樣式（applyLanguage 會對每個編輯區套用鎖定外觀）
}

#pragma mark - 共用

- (std::string)wholeText {
    NSData *d = self.textAsUTF8;
    return std::string((const char *)d.bytes, d.length);
}

// 以新內容取代整份文件。asBaseline=YES 時不留復原紀錄並設為已儲存（開檔自動解密）
- (void)replaceDocument:(const std::string &)text asBaseline:(BOOL)baseline {
    ScintillaView *v = self.primarySci;
    SC(v, SCI_SETREADONLY, 0);
    if (baseline) SC(v, SCI_SETUNDOCOLLECTION, 0);
    else SC(v, SCI_BEGINUNDOACTION);
    SC(v, SCI_SETTARGETSTART, 0);
    SC(v, SCI_SETTARGETEND, SC(v, SCI_GETLENGTH));
    SC(v, SCI_REPLACETARGET, text.size(), (sptr_t)text.data());
    if (baseline) {
        SC(v, SCI_SETUNDOCOLLECTION, 1);
        SC(v, SCI_EMPTYUNDOBUFFER);
        [self markSavedAtModification:self.modificationCount];   // 設定儲存點並清除「強制未儲存」
        [self.doc updateChangeCount:NSChangeCleared];
    } else {
        SC(v, SCI_ENDUNDOACTION);
        // 加解密不留復原紀錄：⌘Z 若把明文變回密文，內容會和加密狀態不一致（存檔時會重複加密或把密文當明文）
        [self markDirtyWithoutUndo];
    }
    // 成功後清除選取、游標回到開頭（所有分割檢視）
    for (ScintillaView *x in self.allViews) {
        SC(x, SCI_SETEMPTYSELECTION, 0);
        SC(x, SCI_SCROLLCARET);
    }
}

#pragma mark - 加密

- (IBAction)exesEncrypt:(id)sender { [self encryptDocument:N2CryptoEXES]; }
- (IBAction)aesEncrypt:(id)sender { [self encryptDocument:N2CryptoAES]; }

- (void)encryptDocument:(N2CryptoAlgorithm)alg {
    Document *doc = self.doc;
    if (doc.isCryptoLocked) { [self showMessage:@"文件目前是密文，請先解密。" info:nil]; return; }
    std::string text = self.wholeText;
    if (N2CryptoDetect(text.data(), text.size()) != N2CryptoNone) {
        [self showMessage:@"文件內容已經是密文。" info:@"不會重複加密；如需更換密碼，請先解密。"];
        return;
    }
    [N2PasswordDialog runForWindow:self.window algorithm:alg encrypt:YES completion:^(N2Credential *cred) {
        if (!cred) return;
        N2RunCryptoJob(self.window, [NSString stringWithFormat:@"%@ 加密中", N2CryptoName(alg)], ^std::string {
            std::string pw = cred.secret;
            std::string out = alg == N2CryptoEXES ? xs::exesEncrypt(text, pw) : xs::aesEncrypt(text, pw);
            std::fill(pw.begin(), pw.end(), '\0');
            return out;
        }, ^(BOOL ok, const std::string &cipher, NSString *err) {
            if (!ok) { [self showMessage:@"加密失敗，文件沒有變更。" info:@"文字可能超過 64 MiB，或含有無效的字元。"]; return; }
            if (self.wholeText != text) { [self showMessage:@"加密期間文件被修改，已取消。" info:nil]; return; }
            if (alg == N2CryptoEXES) [self rememberStateBeforeEncryption];   // 存到雲端時的初始逐檔設定
            [self replaceDocument:cipher asBaseline:NO];
            // 新密文：唯讀，存檔時原樣保存；不保留這次的密碼
            doc.cryptoState = N2CryptoLockedNewCipher;
            doc.cryptoAlgorithm = alg;
            doc.credential = nil;
            [self updateCryptoAppearance];
        });
    }];
}

#pragma mark - 解密

- (IBAction)exesDecrypt:(id)sender { [self decryptDocument:N2CryptoEXES]; }
- (IBAction)aesDecrypt:(id)sender { [self decryptDocument:N2CryptoAES]; }

- (void)decryptDocument:(N2CryptoAlgorithm)requested {
    Document *doc = self.doc;
    std::string text = self.wholeText;
    N2CryptoAlgorithm alg = N2CryptoDetect(text.data(), text.size());
    if (alg == N2CryptoNone) {
        [self showMessage:@"文件內容不是 EXES／AES 密文。" info:@"密文開頭必須是 X60（EXES）或 nb2XSAeSGcMveR1（AES）。"];
        return;
    }
    // 鎖定時以記錄的演算法為準；一般狀態下點錯選單則提示
    if (!doc.isCryptoLocked && requested != alg) {
        [self showMessage:[NSString stringWithFormat:@"這是 %@ 密文，請改用「%@ 解密」。", N2CryptoName(alg), N2CryptoName(alg)] info:nil];
        return;
    }
    BOOL baseline = doc.cryptoState == N2CryptoLockedExternal;   // 開檔密文：解密後視為正常開檔
    [N2PasswordDialog runForWindow:self.window algorithm:alg encrypt:NO completion:^(N2Credential *cred) {
        if (!cred) return;
        N2RunCryptoJob(self.window, [NSString stringWithFormat:@"%@ 解密中", N2CryptoName(alg)], ^std::string {
            std::string pw = cred.secret;
            std::string out = alg == N2CryptoEXES ? xs::exesDecrypt(text, pw) : xs::aesDecrypt(text, pw);
            std::fill(pw.begin(), pw.end(), '\0');
            return out;
        }, ^(BOOL ok, const std::string &plain, NSString *err) {
            if (!ok) {
                [self showMessage:@"無法解密。" info:@"密碼（或金鑰檔案、網址內容）不正確，或密文已損毀。文件維持原樣。"];
                return;
            }
            if (self.wholeText != text) { [self showMessage:@"解密期間文件被修改，已取消。" info:nil]; return; }
            [self replaceDocument:plain asBaseline:baseline];
            doc.cryptoState = baseline ? N2CryptoDecryptedAuto : N2CryptoDecryptedManual;
            doc.cryptoAlgorithm = alg;
            doc.credential = cred;
            doc.pendingAutoDecrypt = NO;
            [self updateCryptoAppearance];
            [self loadBookmarksAfterUnlock];   // 開檔時是密文：解密後才套用 .2xs 的書籤
            // 明文若無法用目前的 8-bit 編碼表示，改成 UTF-8（自動加密存檔時不受影響）
            N2Encoding enc = doc.encoding;
            if (enc == N2EncodingBig5 || enc == N2EncodingGB18030 || enc == N2EncodingShiftJIS || enc == N2EncodingWindows1252) {
                if (!N2EncodeFromUTF8(plain.data(), plain.size(), enc, NULL)) {
                    doc.encoding = N2EncodingUTF8;
                    [self updateStatus];
                }
            }
        });
    }];
}

// 開檔後偵測到密文：視窗顯示出來後詢問密碼
- (void)runPendingAutoDecrypt {
    Document *doc = self.doc;
    if (!doc.pendingAutoDecrypt || !self.window.isVisible || self.window.attachedSheet) return;
    doc.pendingAutoDecrypt = NO;
    [self decryptDocument:doc.cryptoAlgorithm];
}

#pragma mark - EX_MD3 雜湊

- (IBAction)exmd3Hash:(id)sender {
    if (self.doc.isCryptoLocked) { NSBeep(); return; }
    if ([self send:SCI_SELECTIONISRECTANGLE] || [self send:SCI_GETSELECTIONS] > 1) {
        [self showMessage:@"這個功能不支援矩形選取或多重選取。" info:nil];
        return;
    }
    NSString *sel = self.selectedText;
    if (!sel.length) { [self showMessage:@"請先選取要計算雜湊的文字。" info:@"雜湊結果（209 字元）會取代選取的文字，且無法還原成原文。"]; return; }
    sptr_t a = [self send:SCI_GETSELECTIONSTART], b = [self send:SCI_GETSELECTIONEND];
    std::u16string u(sel.length, 0);
    [sel getCharacters:(unichar *)u.data() range:NSMakeRange(0, sel.length)];
    N2RunCryptoJob(self.window, @"EX_MD3 雜湊計算中", ^std::string { return xs::exmd3(u); },
                   ^(BOOL ok, const std::string &hash, NSString *err) {
        if (!ok) { [self showMessage:@"雜湊計算失敗。" info:nil]; return; }
        [self send:SCI_SETTARGETSTART w:a];
        [self send:SCI_SETTARGETEND w:b];
        [self send:SCI_REPLACETARGET w:hash.size() l:(sptr_t)hash.data()];
        [self send:SCI_SETSEL w:a l:a + (sptr_t)hash.size()];
    });
}

- (IBAction)showDefaultKeys:(id)sender { [N2DefaultKeyWindow show]; }

#pragma mark - 人工智慧

- (IBAction)runAI:(id)sender {
    if (self.doc.isCryptoLocked) { [self showMessage:@"文件目前是密文，請先解密。" info:nil]; return; }
    N2AiRunForEditor(self);
}

@end
