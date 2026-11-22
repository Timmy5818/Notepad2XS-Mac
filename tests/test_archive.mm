// 壓縮檔直接編輯：開啟（自動選唯一可編輯成員）→ 修改 → 回存 → 用 bsdtar 驗證
// 涵蓋：中文成員名稱、以 - 開頭的惡意成員名稱（不得被當成選項執行）、硬連結、7z、tar.gz、加密 ZIP 成員
#import <Cocoa/Cocoa.h>
#import "ArchiveEdit.h"

static int fails = 0, passes = 0;
static void Check(bool ok, NSString *name) {
    if (ok) { passes++; printf("  ✓ %s\n", name.UTF8String); }
    else { fails++; printf("  ✗ %s\n", name.UTF8String); }
}

static NSString *Sh(NSString *cmd, NSString *cwd) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", cmd];
    t.currentDirectoryURL = [NSURL fileURLWithPath:cwd];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"LC_ALL"] = @"en_US.UTF-8";
    t.environment = env;
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = p;
    [t launchAndReturnError:nil];
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

// 開啟壓縮檔並等待完成（openArchive 在背景執行，結果回到主執行緒）
static N2ArchiveLink *Open(NSString *path, NSError **error) {
    __block N2ArchiveLink *result = nil;
    __block NSError *err = nil;
    __block BOOL done = NO;
    [N2ArchiveLink openArchive:[NSURL fileURLWithPath:path] completion:^(N2ArchiveLink *link, NSError *e) {
        result = link; err = e; done = YES;
    }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && [limit timeIntervalSinceNow] > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (error) *error = err;
    return result;
}

static void RoundTrip(NSString *dir, NSString *archive, NSString *member, NSString *expectOld, NSString *other, NSString *otherContent) {
    NSString *path = [dir stringByAppendingPathComponent:archive];
    NSError *err = nil;
    N2ArchiveLink *link = Open(path, &err);
    Check(link != nil, [NSString stringWithFormat:@"%@：開啟（%@）", archive, err.localizedDescription ?: @"OK"]);
    if (!link) return;
    Check([link.memberPath isEqualToString:member], [NSString stringWithFormat:@"%@：選中成員「%@」", archive, link.memberPath]);
    NSString *old = [NSString stringWithContentsOfURL:link.workURL encoding:NSUTF8StringEncoding error:nil];
    Check([old isEqualToString:expectOld], [NSString stringWithFormat:@"%@：讀出內容正確", archive]);
    NSString *updated = @"更新後的內容 updated\n第二行";
    [updated writeToURL:link.workURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    BOOL ok = [link writeBack:&err];
    Check(ok, [NSString stringWithFormat:@"%@：回存（%@）", archive, err.localizedDescription ?: @"OK"]);
    NSString *q = [NSString stringWithFormat:@"bsdtar -xOf '%@' -- '%@'", archive, [member stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    Check([Sh(q, dir) isEqualToString:updated], [NSString stringWithFormat:@"%@：回存後內容正確", archive]);
    if (other) {
        NSString *q2 = [NSString stringWithFormat:@"bsdtar -xOf '%@' -- '%@'", archive, other];
        Check([Sh(q2, dir) isEqualToString:otherContent], [NSString stringWithFormat:@"%@：其他成員不變", archive]);
    }
    [link cleanup];
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"n2archive-%@", NSUUID.UUID.UUIDString]];
        NSString *src = [dir stringByAppendingPathComponent:@"src"];
        [NSFileManager.defaultManager createDirectoryAtPath:src withIntermediateDirectories:YES attributes:nil error:nil];
        // 從暫存資料夾執行：若成員名稱被當成選項執行，PWNED 會出現在這裡或 src 裡
        [NSFileManager.defaultManager changeCurrentDirectoryPath:dir];

        printf("== 中文成員名稱（ZIP）==\n");
        Sh(@"printf '中文內容' > 中文.txt && printf 'BIN' > data.bin && zip -q ../cjk.zip 中文.txt data.bin", src);
        RoundTrip(dir, @"cjk.zip", @"中文.txt", @"中文內容", @"data.bin", @"BIN");

        printf("== 惡意成員名稱（TAR）==\n");
        Sh(@"rm -rf ./* && printf 'hi' > '--use-compress-program=touch PWNED;cat;x.txt' && "
           @"bsdtar -cf ../evil.tar -- '--use-compress-program=touch PWNED;cat;x.txt'", src);
        RoundTrip(dir, @"evil.tar", @"--use-compress-program=touch PWNED;cat;x.txt", @"hi", nil, nil);
        NSString *pwned = Sh(@"find . -name PWNED", dir);
        Check(pwned.length == 0, @"evil.tar：成員名稱沒有被當成選項執行（沒有產生 PWNED）");

        printf("== 以 - 開頭的成員名稱（ZIP）==\n");
        Sh(@"rm -rf ./* && printf 'dash' > -d.txt && printf 'X' > keep.bin && zip -q ../dash.zip ./-d.txt keep.bin", src);
        RoundTrip(dir, @"dash.zip", @"-d.txt", @"dash", @"keep.bin", @"X");

        printf("== 硬連結（TAR）==\n");
        Sh(@"rm -rf ./* && printf 'link' > a.txt && ln a.txt b.dat && bsdtar -cf ../hard.tar a.txt b.dat", src);
        RoundTrip(dir, @"hard.tar", @"a.txt", @"link", nil, nil);

        printf("== 7z（中文名稱）==\n");
        Sh(@"rm -rf ./* && printf '七' > 說明.md && printf 'Z' > z.bin && bsdtar --format 7zip -cf ../cjk.7z 說明.md z.bin", src);
        RoundTrip(dir, @"cjk.7z", @"說明.md", @"七", @"z.bin", @"Z");

        printf("== tar.gz ==\n");
        Sh(@"rm -rf ./* && mkdir -p sub && printf 'gz' > sub/conf.ini && printf 'G' > g.bin && bsdtar -czf ../t.tar.gz sub/conf.ini g.bin", src);
        RoundTrip(dir, @"t.tar.gz", @"sub/conf.ini", @"gz", @"g.bin", @"G");

        printf("== 加密的 ZIP 成員 ==\n");
        Sh(@"rm -rf ./* && printf 'secret' > s.txt && zip -q -P pw ../enc.zip s.txt", src);
        NSError *err = nil;
        N2ArchiveLink *link = Open([dir stringByAppendingPathComponent:@"enc.zip"], &err);
        Check(!link && [err.localizedDescription containsString:@"密碼保護"], @"enc.zip：拒絕開啟有密碼的成員");

        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        printf(fails ? "失敗 %d 項\n" : "全部通過（%d 項）\n", fails ? fails : passes);
        return fails ? 1 : 0;
    }
}
