// 壓縮檔內文件直接編輯（ZIP／7Z／TAR 原生回存；其他格式轉 ZIP）
// 使用 macOS 內建工具：/usr/bin/zip、/usr/bin/unzip（ZIP 單一成員替換）與 /usr/bin/bsdtar（libarchive）
#pragma once
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, N2ArchiveKind) {
    N2ArchiveNone = 0,
    N2ArchiveZip,          // 原生：只替換單一成員
    N2Archive7z,           // 原生：重建 7z
    N2ArchiveTar,          // 原生：重建 tar（含 .tar.gz／.tgz／.tar.bz2／.tar.xz）
    N2ArchiveConvert,      // 其他 libarchive 可讀格式：先轉成 ZIP
};

N2ArchiveKind N2ArchiveKindForURL(NSURL *url);

@interface N2ArchiveEntry : NSObject
@property (nonatomic, copy) NSString *path;       // 壓縮檔內的完整路徑（原樣）
@property (nonatomic) unsigned long long size;
@property (nonatomic) BOOL isDirectory, isLink;
@end

// 一份「壓縮檔內文件」的連結：記住來源壓縮檔、成員路徑與暫存工作檔
@interface N2ArchiveLink : NSObject
@property (nonatomic, readonly) NSURL *archiveURL;
@property (nonatomic, readonly) NSString *memberPath;
@property (nonatomic, readonly) NSURL *workURL;      // 暫存工作檔（文件實際開啟的路徑）
@property (nonatomic, readonly) N2ArchiveKind kind;

// 選擇成員並解壓到暫存檔；需要時顯示選擇視窗或「轉成 ZIP」確認。取消時 link 與 error 皆為 nil。
+ (void)openArchive:(NSURL *)url completion:(void (^)(N2ArchiveLink *link, NSError *error))completion;

// 把工作檔內容寫回壓縮檔（驗證通過才替換原檔）
- (BOOL)writeBack:(NSError **)error;

// 關閉文件時清除暫存資料
- (void)cleanup;
@end

// 判斷檔案是否位於壓縮檔暫存區（不加入最近使用的檔案）
BOOL N2IsArchiveWorkURL(NSURL *url);

// 是否為可編輯的文字檔（依副檔名）
BOOL N2IsEditableMemberName(NSString *name);

// 列出成員（測試用公開）
NSArray<N2ArchiveEntry *> *N2ListArchive(NSURL *url, N2ArchiveKind kind, NSString **error);
