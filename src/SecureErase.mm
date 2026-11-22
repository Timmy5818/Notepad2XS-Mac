// 檔案 → 安全刪除目前檔案：覆寫、同步寫入、回讀驗證與刪除流程沿用 Windows 版 SecureEraseCore.h
#import "EditorWindowController.h"
#import "Document.h"
#import "History.h"
#include "SecureEraseCore.h"
#include <atomic>
#include <fcntl.h>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

namespace {
// 同一個檔案描述子從檢查到刪除：拒絕符號連結、硬連結、非一般檔案
class PosixIo : public xs::erase::Io {
    int fd_ = -1;
    std::string path_;
public:
    explicit PosixIo(const std::string &path) : path_(path) {
        fd_ = open(path.c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        if (fd_ < 0) throw xs::erase::Failure{xs::erase::Error::Access, (unsigned long)errno};
        // 建構子丟出例外時解構子不會執行：檢查失敗要先自己關閉 fd
        struct stat st {};
        if (fstat(fd_, &st) != 0 || !S_ISREG(st.st_mode)) { closeFd(); throw xs::erase::Failure{xs::erase::Error::Unsupported}; }
        if (st.st_nlink != 1) { closeFd(); throw xs::erase::Failure{xs::erase::Error::Links}; }
    }
    void closeFd() { if (fd_ >= 0) { close(fd_); fd_ = -1; } }
    ~PosixIo() override { if (fd_ >= 0) close(fd_); }
    std::uint64_t length() override { struct stat st {}; fstat(fd_, &st); return (std::uint64_t)st.st_size; }
    void rewind() override { if (lseek(fd_, 0, SEEK_SET) != 0) throw xs::erase::Failure{xs::erase::Error::Io, (unsigned long)errno}; }
    std::size_t write(const unsigned char *p, std::size_t n) override {
        ssize_t w = ::write(fd_, p, n);
        if (w < 0) throw xs::erase::Failure{xs::erase::Error::Io, (unsigned long)errno};
        return (std::size_t)w;
    }
    std::size_t read(unsigned char *p, std::size_t n) override {
        ssize_t r = ::read(fd_, p, n);
        if (r < 0) throw xs::erase::Failure{xs::erase::Error::Io, (unsigned long)errno};
        return (std::size_t)r;
    }
    // F_FULLFSYNC：要求磁碟把快取真正寫入儲存媒體
    void flush() override { if (fcntl(fd_, F_FULLFSYNC) != 0 && fsync(fd_) != 0) throw xs::erase::Failure{xs::erase::Error::Io, (unsigned long)errno}; }
    void remove() override {
        close(fd_);
        fd_ = -1;
        if (unlink(path_.c_str()) != 0) throw xs::erase::Failure{xs::erase::Error::Io, (unsigned long)errno};
    }
};
}

@implementation EditorWindowController (SecureErase)

- (IBAction)secureEraseFile:(id)sender {
    Document *doc = self.doc;
    NSURL *target = doc.archiveLink ? doc.archiveLink.archiveURL : doc.fileURL;
    if (!target) { [self showMessage:@"這份文件還沒有存成檔案，沒有可刪除的原檔。" info:nil]; return; }
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:target.path error:nil];
    if (!attrs) { [self showMessage:@"找不到原檔。" info:target.path]; return; }
    if (![attrs.fileType isEqualToString:NSFileTypeRegular]) { [self showMessage:@"只能處理一般檔案（不支援符號連結或特殊檔案）。" info:target.path]; return; }
    unsigned long long size = attrs.fileSize;

    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleCritical;
    a.messageText = @"安全刪除目前檔案";
    NSMutableString *info = [NSMutableString stringWithFormat:@"%@\n大小：%@\n\n會先以 0 覆寫整個檔案、同步寫入並回讀驗證，然後刪除。這個動作無法復原。",
                             target.path, [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile]];
    if (doc.archiveLink) [info appendString:@"\n\n這是壓縮檔內的文件：會刪除整個壓縮檔（包含所有成員），不是只清除單一成員。"];
    [info appendString:@"\n\n注意：macOS 的 APFS（寫入時複製、快照）與 SSD 的損耗平均機制，可能讓舊資料仍殘留在磁碟其他位置；"
                       @"這是檔案內容覆寫，不是整碟清除或實體媒體清除保證。版本歷史與 Time Machine 備份不會被處理。"];
    a.informativeText = info;
    NSButton *confirm = [NSButton checkboxWithTitle:doc.isDocumentEdited ? @"我了解檔案會被覆寫並刪除，且同意捨棄未儲存的修改"
                                                                         : @"我了解檔案會被覆寫並刪除，無法復原" target:nil action:nil];
    [confirm sizeToFit];
    a.accessoryView = confirm;
    NSButton *go = [a addButtonWithTitle:@"覆寫並刪除"];
    [a addButtonWithTitle:@"取消"].keyEquivalent = @"\033";
    go.keyEquivalent = @"";
    go.enabled = NO;
    confirm.target = go;   // 勾選後才啟用「覆寫並刪除」
    confirm.action = @selector(n2_toggleEnabledFromCheckbox:);
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn || confirm.state != NSControlStateValueOn) return;
        [self runSecureErase:target size:size];
    }];
}

- (void)runSecureErase:(NSURL *)target size:(unsigned long long)size {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 110) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 50, 340, 20)];
    bar.indeterminate = NO; bar.minValue = 0; bar.maxValue = 1;
    NSTextField *label = [NSTextField labelWithString:@"檢查中…"];
    label.frame = NSMakeRect(20, 76, 340, 18);
    NSButton *stop = [NSButton buttonWithTitle:@"停止" target:nil action:nil];
    stop.frame = NSMakeRect(270, 8, 96, 32);
    for (NSView *v in @[bar, label, stop]) [panel.contentView addSubview:v];
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    auto progress = std::make_shared<std::atomic<uint64_t>>(0);
    auto stage = std::make_shared<std::atomic<int>>(0);
    [stop setButtonType:NSButtonTypePushOnPushOff];   // 按下後狀態變成 On，由計時器讀取並要求停止
    [self.window beginSheet:panel completionHandler:nil];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        if (stop.state == NSControlStateValueOn) *cancel = true;
        static NSArray *names = @[@"檢查中…", @"準備中…", @"覆寫中…", @"同步寫入中…", @"回讀驗證中…", @"刪除中…", @"完成"];
        int s = *stage;
        label.stringValue = s < (int)names.count ? names[(NSUInteger)s] : @"";
        bar.doubleValue = size ? (double)*progress / (double)size : 1;
    }];
    std::string path = target.fileSystemRepresentation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        xs::erase::Outcome out;
        NSString *openError = nil;
        try {
            PosixIo io(path);
            out = xs::erase::overwriteAndDelete(io, size,
                [stage, progress](xs::erase::Update u) { *stage = (int)u.stage; *progress = u.completed; },
                [cancel] { return cancel->load(); });
        } catch (const xs::erase::Failure &f) {
            openError = f.reason == xs::erase::Error::Links ? @"檔案有多個硬連結，無法確保處理所有名稱，已停止。"
                      : f.reason == xs::erase::Error::Unsupported ? @"不是一般檔案，已停止。"
                      : [NSString stringWithFormat:@"無法開啟檔案（錯誤碼 %lu），已停止，檔案沒有被修改。", f.system];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [timer invalidate];
            [self.window endSheet:panel];
            if (openError) { [self showMessage:@"安全刪除未執行。" info:openError]; return; }
            NSString *result;
            if (out.deleted) result = [NSString stringWithFormat:@"已覆寫 %llu 位元組、回讀驗證完成並刪除。", out.written];
            else if (out.overwriteVerified) result = @"覆寫與驗證已完成，但刪除未確認，請手動檢查檔案。";
            else if (out.possiblyChanged) result = [NSString stringWithFormat:@"處理中斷（錯誤碼 %lu），檔案可能已部分覆寫。", out.system];
            else result = @"未開始覆寫，檔案沒有被修改。";
            BOOL destroyed = out.deleted || out.possiblyChanged || out.overwriteVerified;
            NSAlert *done = [NSAlert new];
            done.messageText = out.deleted ? @"安全刪除完成" : @"安全刪除沒有完全成功";
            done.informativeText = result;
            [done beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
                if (!destroyed) return;
                // 已進行破壞性操作：清空並關閉文件，避免之後又把內容存回去
                Document *doc = self.doc;
                [doc clearCrypto];
                [doc updateChangeCount:NSChangeCleared];
                [doc close];
            }];
        });
    });
}

- (IBAction)showVersionHistory:(id)sender { [N2HistoryWindow showForDocument:self.doc]; }

@end

@implementation NSButton (N2Toggle)
- (void)n2_toggleEnabledFromCheckbox:(NSButton *)checkbox { self.enabled = checkbox.state == NSControlStateValueOn; }
@end
