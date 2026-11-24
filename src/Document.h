// 一份文字文件：負責讀檔、存檔、編碼與換行格式。文字本身放在編輯視窗的 Scintilla 裡。
#pragma once
#import <Cocoa/Cocoa.h>
#import "TextEncoding.h"
#import "CryptoUI.h"
#import "ArchiveEdit.h"

@class EditorWindowController;

// ---- 加密文件狀態（與 Windows 版相同的五種狀態）----
typedef NS_ENUM(NSInteger, N2CryptoState) {
    N2CryptoPlain = 0,          // 一般文字
    N2CryptoDecryptedAuto,      // 開檔自動解密：存檔一律用原演算法與密碼重新加密
    N2CryptoDecryptedManual,    // 手動解密：存檔時詢問「加密後保存／不加密保存／取消」
    N2CryptoLockedExternal,     // 尚未解密的密文：唯讀，拒絕存檔
    N2CryptoLockedNewCipher,    // 剛手動加密的密文：唯讀，存檔時原樣保存密文
};

@interface Document : NSDocument

@property (nonatomic) N2Encoding encoding;          // 存檔時使用的編碼
@property (nonatomic) int eolMode;                  // SC_EOL_CRLF / SC_EOL_LF / SC_EOL_CR
@property (nonatomic, copy) NSString *languageID;   // nil = 依副檔名自動判斷
@property (nonatomic, readonly) NSData *loadedText; // 最近一次讀入的內容（UTF-8）

- (EditorWindowController *)editor;
- (NSString *)effectiveLanguageID;

// ---- 加密狀態 ----
@property (nonatomic) N2CryptoState cryptoState;
@property (nonatomic) N2CryptoAlgorithm cryptoAlgorithm;
@property (nonatomic, strong) N2Credential *credential;   // 解密後記住的來源憑證
@property (nonatomic) BOOL pendingAutoDecrypt;            // 開檔後要詢問密碼
- (BOOL)isCryptoLocked;
- (void)clearCrypto;

// 壓縮檔內文件：存檔後自動寫回壓縮檔
@property (nonatomic, strong) N2ArchiveLink *archiveLink;
@property (nonatomic, readonly) BOOL isImageDocument;   // 檔案是 JPG／PNG／WebP（文字內嵌在圖片區塊）

// 載入原始位元組（版本歷史還原／開啟複本用）
- (BOOL)loadRawData:(NSData *)raw imageURL:(NSURL *)imageURL error:(NSError **)error;   // imageURL 是圖片時依圖片格式解讀

// 用指定編碼重新讀取磁碟上的檔案（會捨棄未儲存的修改）
- (BOOL)reloadWithEncoding:(N2Encoding)encoding error:(NSError **)error;

@end

BOOL N2IsImageTextURL(NSURL *url);   // .jpg／.jpeg／.png／.webp
