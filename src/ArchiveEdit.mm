#import "ArchiveEdit.h"
#import "SyntaxStyles.h"
#include <zlib.h>

static NSString *const kZip = @"/usr/bin/zip";
static NSString *const kUnzip = @"/usr/bin/unzip";
static NSString *const kTar = @"/usr/bin/bsdtar";
static const unsigned long long kMaxExpanded = 2ULL * 1024 * 1024 * 1024;   // 重建時的展開總量上限
static const NSUInteger kMaxEntries = 50000;

#pragma mark - 工具

static NSError *Err(NSString *msg, NSString *detail) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:msg forKey:NSLocalizedDescriptionKey];
    if (detail.length) info[NSLocalizedRecoverySuggestionErrorKey] = detail;
    return [NSError errorWithDomain:@"Notepad2XS.Archive" code:1 userInfo:info];
}

// 執行外部工具；stdin 一律接 /dev/null（避免 unzip 等工具等待密碼輸入而卡住）
static int Run(NSString *tool, NSArray<NSString *> *args, NSString *cwd, NSData **outData, NSString **errText) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:tool];
    t.arguments = args;
    if (cwd) t.currentDirectoryURL = [NSURL fileURLWithPath:cwd];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    // UTF-8 語系：中文等非 ASCII 成員名稱原樣輸出（C 語系會變成 \344… 跳脫碼）；en_US 的日期欄位格式與 C 相同
    env[@"LC_ALL"] = @"en_US.UTF-8";
    t.environment = env;
    t.standardInput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = err;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { if (errText) *errText = e.localizedDescription; return -1; }
    // 同時讀取兩個管線，避免輸出過多造成阻塞
    __block NSData *errData = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ errData = [err.fileHandleForReading readDataToEndOfFile]; });
    NSData *o = [out.fileHandleForReading readDataToEndOfFile];
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    [t waitUntilExit];
    if (outData) *outData = o;
    if (errText) *errText = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    return t.terminationStatus;
}

static NSString *CacheRoot(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"local.notepad2xs.mac/archive"];
}

BOOL N2IsArchiveWorkURL(NSURL *url) {
    return [url.path.stringByStandardizingPath hasPrefix:CacheRoot().stringByStandardizingPath];
}

static NSString *NewTempDir(void) {
    NSString *d = [CacheRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    return d;
}

static uint32_t CRC32(NSData *d) { return (uint32_t)crc32(0L, (const Bytef *)d.bytes, (uInt)d.length); }

// bsdtar 會把成員名稱當成比對樣式，特殊字元需要跳脫
static NSString *TarPattern(NSString *name) {
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c == '\\' || c == '*' || c == '?' || c == '[') [s appendString:@"\\"];
        [s appendFormat:@"%C", c];
    }
    return s;
}

#pragma mark - 格式判斷

static NSString *Lower(NSURL *u) { return u.lastPathComponent.lowercaseString; }

static NSString *TarCompression(NSURL *url) {
    NSString *n = Lower(url);
    if ([n hasSuffix:@".tar.gz"] || [n hasSuffix:@".tgz"]) return @"-z";
    if ([n hasSuffix:@".tar.bz2"] || [n hasSuffix:@".tbz"] || [n hasSuffix:@".tbz2"]) return @"-j";
    if ([n hasSuffix:@".tar.xz"] || [n hasSuffix:@".txz"]) return @"-J";
    return nil;
}

N2ArchiveKind N2ArchiveKindForURL(NSURL *url) {
    NSString *n = Lower(url);
    if ([n hasSuffix:@".zip"]) return N2ArchiveZip;
    if ([n hasSuffix:@".7z"]) return N2Archive7z;
    if ([n hasSuffix:@".tar"] || TarCompression(url)) return N2ArchiveTar;
    NSArray *convert = @[@"rar", @"iso", @"cab", @"cpio", @"xar", @"pkg", @"lha", @"lzh", @"jar", @"xpi", @"epub",
                         @"odt", @"ods", @"docx", @"xlsx", @"pptx", @"ar", @"deb", @"rpm"];
    return [convert containsObject:n.pathExtension] ? N2ArchiveConvert : N2ArchiveNone;
}

BOOL N2IsEditableMemberName(NSString *name) {
    static NSSet *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[
            @"txt", @"log", @"md", @"markdown", @"csv", @"tsv", @"ini", @"inf", @"cfg", @"conf", @"config", @"properties",
            @"json", @"jsonc", @"xml", @"xsd", @"xsl", @"svg", @"plist", @"yaml", @"yml", @"toml", @"html", @"htm", @"xhtml",
            @"css", @"scss", @"less", @"js", @"mjs", @"cjs", @"jsx", @"ts", @"tsx", @"vue", @"c", @"h", @"cpp", @"cxx", @"cc",
            @"hpp", @"hxx", @"m", @"mm", @"java", @"kt", @"kts", @"cs", @"swift", @"py", @"pyw", @"rb", @"php", @"go", @"rs",
            @"sh", @"bash", @"zsh", @"command", @"bat", @"cmd", @"ps1", @"sql", @"mak", @"mk", @"diff", @"patch", @"reg",
            @"rc", @"gradle", @"lua", @"pl", @"r", @"tex", @"srt", @"nfo", @"x60", @"u2f", @"jpg", @"jpeg", @"png", @"webp"]];
    });
    NSString *base = name.lastPathComponent.lowercaseString;
    if ([base isEqualToString:@"makefile"] || [base isEqualToString:@"readme"] || [base isEqualToString:@"license"]) return YES;
    return [exts containsObject:base.pathExtension];
}

@implementation N2ArchiveEntry
@end

#pragma mark - 列出成員

// bsdtar -tv：權限 連結數 擁有者 群組 大小 月 日 時間或年 名稱
NSArray<N2ArchiveEntry *> *N2ListArchive(NSURL *url, N2ArchiveKind kind, NSString **error) {
    NSData *out = nil;
    NSString *err = nil;
    int st = Run(kTar, @[@"-tvf", url.path], nil, &out, &err);
    if (st != 0) { if (error) *error = err.length ? err : @"無法讀取這個壓縮檔。"; return nil; }
    NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
                  ?: [[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSScanner *sc = [NSScanner scannerWithString:line];
        sc.charactersToBeSkipped = nil;
        NSString *field = nil;
        NSMutableArray *fields = [NSMutableArray array];
        NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
        for (int i = 0; i < 8; i++) {
            [sc scanCharactersFromSet:ws intoString:nil];
            if (![sc scanUpToCharactersFromSet:ws intoString:&field]) break;
            [fields addObject:field];
        }
        [sc scanCharactersFromSet:ws intoString:nil];
        if (fields.count < 8 || sc.isAtEnd) continue;
        NSString *name = [line substringFromIndex:sc.scanLocation];
        N2ArchiveEntry *e = [N2ArchiveEntry new];
        NSString *perm = fields[0];
        e.isDirectory = [perm hasPrefix:@"d"] || [name hasSuffix:@"/"];
        // 符號連結「name -> target」、硬連結（權限欄 h）「name link to target」：只保留成員本身的名稱
        e.isLink = [perm hasPrefix:@"l"] || [perm hasPrefix:@"h"];
        NSString *sep = [perm hasPrefix:@"l"] ? @" -> " : [perm hasPrefix:@"h"] ? @" link to " : nil;
        if (sep) {
            NSRange r = [name rangeOfString:sep];
            if (r.location != NSNotFound) name = [name substringToIndex:r.location];
        }
        e.path = name;
        e.size = strtoull([fields[4] UTF8String], NULL, 10);
        [list addObject:e];
    }
    return list;
}

// 不安全的路徑：絕對路徑、..、空白名稱、換行（會破壞 -T 清單）、單獨的 -C（bsdtar -T 的切換目錄指令）
static BOOL UnsafePath(NSString *p) {
    if (!p.length || [p hasPrefix:@"/"] || [p rangeOfString:@"\\"].location != NSNotFound) return YES;
    if ([p rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound || [p isEqualToString:@"-C"]) return YES;
    for (NSString *c in [p componentsSeparatedByString:@"/"]) if ([c isEqualToString:@".."]) return YES;
    return NO;
}

#pragma mark - ZIP 清單（含 CRC，用於回存驗證）

// 直接讀 ZIP 中央目錄：不把成員名稱當參數交給外部工具，也避免 unzip 把中文檔名顯示成 ??
// 結果：名稱 → @[未壓縮大小, CRC32（8 位小寫十六進位）, 是否加密]
static uint32_t LE32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t LE16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static NSDictionary<NSString *, NSArray *> *ZipCRCs(NSString *path, NSString **error) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (error) *error = @"無法開啟壓縮檔。"; return nil; }
    unsigned long long fileSize = [fh seekToEndOfFile];
    unsigned long long tailLen = MIN(fileSize, 22ULL + 65535ULL);
    [fh seekToFileOffset:fileSize - tailLen];
    NSData *tail = [fh readDataOfLength:(NSUInteger)tailLen];
    const uint8_t *t = (const uint8_t *)tail.bytes;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--)
        if (LE32(t + i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { [fh closeFile]; if (error) *error = @"不是有效的 ZIP 檔（找不到中央目錄）。"; return nil; }
    uint16_t count = LE16(t + eocd + 10);
    uint32_t cdSize = LE32(t + eocd + 12), cdOffset = LE32(t + eocd + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
        [fh closeFile]; if (error) *error = @"不支援 ZIP64 格式的壓縮檔。"; return nil;
    }
    if ((unsigned long long)cdOffset + cdSize > fileSize) { [fh closeFile]; if (error) *error = @"ZIP 中央目錄位置不正確。"; return nil; }
    [fh seekToFileOffset:cdOffset];
    NSData *cd = [fh readDataOfLength:cdSize];
    [fh closeFile];
    const uint8_t *p = (const uint8_t *)cd.bytes, *end = p + cd.length;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (uint16_t i = 0; i < count; i++) {
        if (end - p < 46 || LE32(p) != 0x02014b50) { if (error) *error = @"ZIP 中央目錄損壞。"; return nil; }
        uint16_t flags = LE16(p + 8), nlen = LE16(p + 28), elen = LE16(p + 30), clen = LE16(p + 32);
        uint32_t crc = LE32(p + 16), usize = LE32(p + 24);
        if (end - p < 46 + nlen + elen + clen) { if (error) *error = @"ZIP 中央目錄損壞。"; return nil; }
        NSData *raw = [NSData dataWithBytes:p + 46 length:nlen];
        // 旗標第 11 位元＝UTF-8；沒有標記時先試 UTF-8（macOS 的 zip 常這樣存），再退回 CP437
        NSString *name = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
        if (!name && !(flags & 0x800))
            name = [[NSString alloc] initWithData:raw encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS)];
        if (name) map[name] = @[[NSString stringWithFormat:@"%u", usize], [NSString stringWithFormat:@"%08x", crc], @((flags & 1) != 0)];
        p += 46 + nlen + elen + clen;
    }
    return map;
}

// 一般位元旗標第 0 位元＝成員有加密
static BOOL ZipMemberEncrypted(NSString *zip, NSString *member) {
    return [ZipCRCs(zip, nil)[member][2] boolValue];
}

#pragma mark - 選擇成員視窗

@interface N2MemberChooser : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSArray<N2ArchiveEntry *> *all, *shown;
@property (nonatomic, strong) NSTableView *table;
@end

@implementation N2MemberChooser
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.shown.count; }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    N2ArchiveEntry *e = self.shown[(NSUInteger)row];
    if ([col.identifier isEqualToString:@"size"])
        return [NSByteCountFormatter stringFromByteCount:(long long)e.size countStyle:NSByteCountFormatterCountStyleFile];
    return e.path;
}
- (void)controlTextDidChange:(NSNotification *)n {
    NSString *q = [(NSSearchField *)n.object stringValue];
    self.shown = q.length ? [self.all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"path CONTAINS[cd] %@", q]] : self.all;
    [self.table reloadData];
    if (self.shown.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}
- (void)doubleClicked:(id)sender { [NSApp stopModalWithCode:NSAlertFirstButtonReturn]; }
@end

static N2ArchiveEntry *ChooseMember(NSArray<N2ArchiveEntry *> *entries, NSString *archiveName) {
    N2MemberChooser *c = [N2MemberChooser new];
    c.all = [entries sortedArrayUsingComparator:^NSComparisonResult(N2ArchiveEntry *a, N2ArchiveEntry *b) {
        return [a.path localizedStandardCompare:b.path];
    }];
    c.shown = c.all;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 330)];
    NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 302, 560, 24)];
    search.placeholderString = @"篩選檔名";
    search.delegate = c;
    [box addSubview:search];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 294)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
    NSTableColumn *name = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    name.title = @"文件"; name.width = 440;
    NSTableColumn *size = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    size.title = @"大小"; size.width = 90;
    [tv addTableColumn:name]; [tv addTableColumn:size];
    tv.dataSource = c; tv.delegate = c;
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.target = c; tv.doubleAction = @selector(doubleClicked:);
    sv.documentView = tv;
    [box addSubview:sv];
    c.table = tv;
    [tv reloadData];
    [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"選擇要編輯的文件（%@）", archiveName];
    a.informativeText = [NSString stringWithFormat:@"共 %lu 個可編輯文件；一次只能編輯一個。", (unsigned long)entries.count];
    a.accessoryView = box;
    [a addButtonWithTitle:@"開啟"];
    [a addButtonWithTitle:@"取消"];
    a.window.initialFirstResponder = tv;
    NSModalResponse r = [a runModal];
    NSInteger row = tv.selectedRow;
    if (r != NSAlertFirstButtonReturn || row < 0 || row >= (NSInteger)c.shown.count) return nil;
    return c.shown[(NSUInteger)row];
}

#pragma mark - N2ArchiveLink

@implementation N2ArchiveLink {
    NSString *_tempDir;
}

- (instancetype)initWithArchive:(NSURL *)archive member:(NSString *)member kind:(N2ArchiveKind)kind
                        workURL:(NSURL *)work tempDir:(NSString *)dir {
    if ((self = [super init])) {
        _archiveURL = archive; _memberPath = [member copy]; _kind = kind; _workURL = work; _tempDir = dir;
    }
    return self;
}

- (void)cleanup {
    if (_tempDir) [NSFileManager.defaultManager removeItemAtPath:_tempDir error:nil];
    _tempDir = nil;
}

// 依副檔名推算轉換後的 ZIP 名稱（Backup.tar.gz → Backup.zip）
static NSURL *ConvertedZipURL(NSURL *src) {
    NSString *name = src.lastPathComponent;
    NSString *base = name.stringByDeletingPathExtension;
    if ([base.pathExtension.lowercaseString isEqualToString:@"tar"]) base = base.stringByDeletingPathExtension;
    return [[src URLByDeletingLastPathComponent] URLByAppendingPathComponent:[base stringByAppendingPathExtension:@"zip"]];
}

// 其他格式 → ZIP：成功後來源改名為 .bak
+ (NSURL *)convertToZip:(NSURL *)src error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *zipURL = ConvertedZipURL(src);
    NSURL *bakURL = [src URLByAppendingPathExtension:@"bak"];
    if ([fm fileExistsAtPath:zipURL.path] || [fm fileExistsAtPath:bakURL.path]) {
        *error = Err(@"無法轉換：同名的 ZIP 或 .bak 備份已經存在。",
                     [NSString stringWithFormat:@"%@\n%@", zipURL.lastPathComponent, bakURL.lastPathComponent]);
        return nil;
    }
    NSString *listErr = nil;
    NSArray *entries = N2ListArchive(src, N2ArchiveConvert, &listErr);
    if (!entries) { *error = Err(@"無法讀取這個檔案。", listErr); return nil; }
    unsigned long long total = 0;
    for (N2ArchiveEntry *e in entries) {
        if (UnsafePath(e.path)) { *error = Err(@"壓縮檔含有不安全的路徑，已拒絕轉換。", e.path); return nil; }
        total += e.size;
    }
    if (entries.count > kMaxEntries || total > kMaxExpanded) { *error = Err(@"壓縮檔太大，無法轉換。", nil); return nil; }
    NSString *dir = NewTempDir(), *stage = [dir stringByAppendingPathComponent:@"stage"];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *err = nil;
    if (Run(kTar, @[@"-xf", src.path, @"-C", stage, @"--no-same-owner"], nil, nil, &err) != 0) {
        [fm removeItemAtPath:dir error:nil];
        *error = Err(@"解開檔案時發生錯誤，已取消轉換。", err);
        return nil;
    }
    NSString *tmpZip = [zipURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".%@.n2tmp", NSUUID.UUID.UUIDString]];
    if (Run(kZip, @[@"-r", @"-q", @"-y", tmpZip, @"."], stage, nil, &err) != 0 ||
        Run(kUnzip, @[@"-tq", tmpZip], nil, nil, &err) != 0) {
        [fm removeItemAtPath:tmpZip error:nil];
        [fm removeItemAtPath:dir error:nil];
        *error = Err(@"建立 ZIP 時發生錯誤，已取消轉換。", err);
        return nil;
    }
    [fm removeItemAtPath:dir error:nil];
    NSError *e = nil;
    if (![fm moveItemAtPath:tmpZip toPath:zipURL.path error:&e]) {
        [fm removeItemAtPath:tmpZip error:nil];
        *error = Err(@"無法建立 ZIP 檔。", e.localizedDescription);
        return nil;
    }
    if (![fm moveItemAtURL:src toURL:bakURL error:&e]) {
        [fm removeItemAtURL:zipURL error:nil];
        *error = Err(@"無法把原始檔改名為 .bak，已取消轉換。", e.localizedDescription);
        return nil;
    }
    return zipURL;
}

// 外部工具（列出、轉換、解出）在背景執行，避免大型壓縮檔卡住畫面；對話框與 completion 都在主執行緒
static void InBackground(dispatch_block_t work, dispatch_block_t then) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        work();
        dispatch_async(dispatch_get_main_queue(), then);
    });
}

+ (void)openArchive:(NSURL *)url completion:(void (^)(N2ArchiveLink *, NSError *))completion {
    N2ArchiveKind kind = N2ArchiveKindForURL(url);
    if (kind == N2ArchiveConvert) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"要把「%@」轉成 ZIP 再編輯嗎？", url.lastPathComponent];
        a.informativeText = [NSString stringWithFormat:@"會在同一個資料夾建立「%@」，原始檔改名為「%@.bak」。原始檔的內容不會被修改。",
                             ConvertedZipURL(url).lastPathComponent, url.lastPathComponent];
        [a addButtonWithTitle:@"轉成 ZIP"];
        [a addButtonWithTitle:@"取消"];
        if ([a runModal] != NSAlertFirstButtonReturn) { completion(nil, nil); return; }
        __block NSURL *zip = nil;
        __block NSError *error = nil;
        InBackground(^{ NSError *e = nil; zip = [self convertToZip:url error:&e]; error = e; }, ^{
            if (!zip) { completion(nil, error); return; }
            [self openListed:zip kind:N2ArchiveZip completion:completion];
        });
        return;
    }
    [self openListed:url kind:kind completion:completion];
}

+ (void)openListed:(NSURL *)url kind:(N2ArchiveKind)kind completion:(void (^)(N2ArchiveLink *, NSError *))completion {
    __block NSArray<N2ArchiveEntry *> *entries = nil;
    __block NSString *listErr = nil;
    InBackground(^{ entries = N2ListArchive(url, kind, &listErr); }, ^{
        if (!entries) { completion(nil, Err(@"無法讀取這個壓縮檔。", listErr)); return; }
        NSMutableArray *editable = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (N2ArchiveEntry *e in entries) {
            if (e.isDirectory || e.isLink || UnsafePath(e.path) || !N2IsEditableMemberName(e.path)) continue;
            if ([seen containsObject:e.path]) continue;   // 重複名稱只列一次（回存時會拒絕）
            [seen addObject:e.path];
            [editable addObject:e];
        }
        if (editable.count == 0) { completion(nil, Err(@"壓縮檔裡沒有可以編輯的文字文件。", nil)); return; }
        N2ArchiveEntry *chosen = editable.count == 1 ? editable.firstObject : ChooseMember(editable, url.lastPathComponent);
        if (!chosen) { completion(nil, nil); return; }
        [self extract:chosen from:url kind:kind completion:completion];
    });
}

+ (void)extract:(N2ArchiveEntry *)chosen from:(NSURL *)url kind:(N2ArchiveKind)kind
     completion:(void (^)(N2ArchiveLink *, NSError *))completion {
    __block NSError *error = nil;
    __block NSString *work = nil, *dir = nil;
    InBackground(^{
        if (kind == N2ArchiveZip && ZipMemberEncrypted(url.path, chosen.path)) {
            error = Err(@"這個成員有密碼保護，目前不支援。", chosen.path);
            return;
        }
        NSData *data = nil;
        NSString *err = nil;
        // -- 之後才是成員名稱：名稱開頭是 - 也不會被當成 bsdtar 的選項
        if (Run(kTar, @[@"-xOf", url.path, @"--", TarPattern(chosen.path)], nil, &data, &err) != 0 || data.length != chosen.size) {
            error = Err(@"無法解出選取的文件。", err);
            return;
        }
        dir = NewTempDir();
        work = [[dir stringByAppendingPathComponent:@"work"] stringByAppendingPathComponent:chosen.path.lastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:work.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![data writeToFile:work atomically:YES]) { error = Err(@"無法建立暫存檔。", nil); work = nil; }
    }, ^{
        if (!work) { completion(nil, error); return; }
        completion([[N2ArchiveLink alloc] initWithArchive:url member:chosen.path kind:kind
                                                  workURL:[NSURL fileURLWithPath:work] tempDir:dir], nil);
    });
}

#pragma mark - 回存

- (BOOL)writeBack:(NSError **)error {
    NSData *content = [NSData dataWithContentsOfURL:_workURL];
    if (!content) { if (error) *error = Err(@"讀不到暫存的工作檔。", nil); return NO; }
    if (![NSFileManager.defaultManager fileExistsAtPath:_archiveURL.path]) {
        if (error) *error = Err(@"找不到原本的壓縮檔，可能已被移動或刪除。", _archiveURL.path);
        return NO;
    }
    return _kind == N2ArchiveZip ? [self writeBackZip:content error:error] : [self writeBackRebuild:content error:error];
}

- (NSString *)tempArchivePath {
    NSString *ext = _archiveURL.lastPathComponent.pathExtension;
    return [_archiveURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.n2tmp.%@", NSUUID.UUID.UUIDString, ext]];
}

- (BOOL)replaceArchiveWith:(NSString *)tmp error:(NSError **)error {
    NSError *e = nil;
    // 保留原檔權限
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:_archiveURL.path error:nil];
    if (attrs[NSFilePosixPermissions])
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: attrs[NSFilePosixPermissions]} ofItemAtPath:tmp error:nil];
    if (![NSFileManager.defaultManager replaceItemAtURL:_archiveURL withItemAtURL:[NSURL fileURLWithPath:tmp]
                                         backupItemName:nil options:0 resultingItemURL:nil error:&e]) {
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        if (error) *error = Err(@"無法替換原本的壓縮檔。", e.localizedDescription);
        return NO;
    }
    return YES;
}

// ZIP：複製原檔 → 用 zip 只替換這個成員 → 驗證其他成員的長度與 CRC32 不變 → 原子替換
- (BOOL)writeBackZip:(NSData *)content error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *err = nil;
    NSDictionary *before = ZipCRCs(_archiveURL.path, &err);
    if (!before || !before[_memberPath]) { if (error) *error = Err(@"壓縮檔裡找不到原本的文件，已取消回存。", err); return NO; }
    NSString *stage = [NewTempDir() stringByAppendingPathComponent:@"stage"];
    NSString *member = [stage stringByAppendingPathComponent:_memberPath];
    [fm createDirectoryAtPath:member.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = self.tempArchivePath;
    BOOL ok = [content writeToFile:member atomically:NO] && [fm copyItemAtPath:_archiveURL.path toPath:tmp error:nil];
    // ./ 前綴（zip 會去掉）＋ -nw 不展開萬用字元：成員名稱不會被當成選項或樣式
    if (ok) ok = Run(kZip, @[@"-q", @"-nw", tmp, [@"./" stringByAppendingString:_memberPath]], stage, nil, &err) == 0;
    if (ok) ok = Run(kUnzip, @[@"-tq", tmp], nil, nil, &err) == 0;
    NSDictionary *after = ok ? ZipCRCs(tmp, &err) : nil;
    [fm removeItemAtPath:stage.stringByDeletingLastPathComponent error:nil];
    if (!after) {
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = Err(@"寫回壓縮檔時發生錯誤，原壓縮檔沒有變更。", err);
        return NO;
    }
    // 檢查：成員集合相同、其他成員不變、目標成員內容正確
    NSString *expectCRC = [NSString stringWithFormat:@"%08x", CRC32(content)];
    BOOL same = [[NSSet setWithArray:before.allKeys] isEqualToSet:[NSSet setWithArray:after.allKeys]];
    for (NSString *k in before) {
        if (!same) break;
        if ([k isEqualToString:_memberPath]) {
            same = [after[k][0] longLongValue] == (long long)content.length && [after[k][1] isEqualToString:expectCRC];
        } else {
            same = [before[k] isEqualToArray:after[k]];
        }
    }
    if (!same) {
        [fm removeItemAtPath:tmp error:nil];
        if (error) *error = Err(@"回存驗證失敗（其他成員或目標內容不一致），原壓縮檔沒有變更。", nil);
        return NO;
    }
    return [self replaceArchiveWith:tmp error:error];
}

// 7Z／TAR：完整解開 → 替換目標檔 → 依原順序重建 → 再解開新檔逐一比對 → 原子替換
- (BOOL)writeBackRebuild:(NSData *)content error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *err = nil;
    NSArray<N2ArchiveEntry *> *entries = N2ListArchive(_archiveURL, _kind, &err);
    if (!entries) { if (error) *error = Err(@"無法讀取原本的壓縮檔。", err); return NO; }
    unsigned long long total = 0;
    NSUInteger targets = 0;
    NSMutableSet *names = [NSMutableSet set];
    for (N2ArchiveEntry *e in entries) {
        total += e.size;
        if ([e.path isEqualToString:_memberPath]) targets++;
        if (UnsafePath(e.path) || [names containsObject:e.path]) {
            if (error) *error = Err(@"壓縮檔含有不安全或重複的路徑，無法安全回存。", e.path);
            return NO;
        }
        [names addObject:e.path];
    }
    if (targets != 1) { if (error) *error = Err(@"壓縮檔裡找不到原本的文件，已取消回存。", nil); return NO; }
    if (entries.count > kMaxEntries || total > kMaxExpanded) { if (error) *error = Err(@"壓縮檔太大，無法安全回存。", nil); return NO; }

    NSString *dir = NewTempDir();
    NSString *stage = [dir stringByAppendingPathComponent:@"stage"], *verify = [dir stringByAppendingPathComponent:@"verify"];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:verify withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = self.tempArchivePath;
    // 失敗時清除暫存資料並回報錯誤
#define FAIL(msg, detail) do { [fm removeItemAtPath:dir error:nil]; [fm removeItemAtPath:tmp error:nil]; \
                               if (error) *error = Err(msg, detail); return NO; } while (0)
    if (Run(kTar, @[@"-xf", _archiveURL.path, @"-C", stage, @"--no-same-owner"], nil, nil, &err) != 0)
        FAIL(@"解開壓縮檔時發生錯誤，原壓縮檔沒有變更。", err);
    if (![content writeToFile:[stage stringByAppendingPathComponent:_memberPath] atomically:NO])
        FAIL(@"無法寫入暫存資料。", nil);

    // 依原本順序與名稱重建（-n：不遞迴，避免重複加入）
    NSString *listFile = [dir stringByAppendingPathComponent:@"list.txt"];
    NSMutableString *list = [NSMutableString string];
    for (N2ArchiveEntry *e in entries) [list appendFormat:@"%@\n", e.path];
    [list writeToFile:listFile atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *args = [NSMutableArray arrayWithObject:@"-c"];
    if (_kind == N2Archive7z) [args addObjectsFromArray:@[@"--format", @"7zip"]];
    else if (TarCompression(_archiveURL)) [args addObject:TarCompression(_archiveURL)];
    [args addObjectsFromArray:@[@"-n", @"-f", tmp, @"-C", stage, @"-T", listFile]];
    if (Run(kTar, args, nil, nil, &err) != 0) FAIL(@"重建壓縮檔時發生錯誤，原壓縮檔沒有變更。", err);

    // 驗證：成員清單相同，且每個檔案內容與預期一致
    NSArray<N2ArchiveEntry *> *newEntries = N2ListArchive([NSURL fileURLWithPath:tmp], _kind, &err);
    NSMutableArray *oldNames = [NSMutableArray array], *newNames = [NSMutableArray array];
    for (N2ArchiveEntry *e in entries) [oldNames addObject:e.path];
    for (N2ArchiveEntry *e in newEntries) [newNames addObject:e.path];
    if (!newEntries || ![[NSSet setWithArray:oldNames] isEqualToSet:[NSSet setWithArray:newNames]])
        FAIL(@"回存驗證失敗（成員清單不一致），原壓縮檔沒有變更。", err);
    if (Run(kTar, @[@"-xf", tmp, @"-C", verify, @"--no-same-owner"], nil, nil, &err) != 0)
        FAIL(@"回存驗證失敗（新壓縮檔無法解開），原壓縮檔沒有變更。", err);
    for (N2ArchiveEntry *e in entries) {
        if (e.isDirectory || e.isLink) continue;
        NSData *expect = [NSData dataWithContentsOfFile:[stage stringByAppendingPathComponent:e.path]];
        NSData *actual = [NSData dataWithContentsOfFile:[verify stringByAppendingPathComponent:e.path]];
        if (!expect || ![expect isEqualToData:actual])
            FAIL(@"回存驗證失敗（內容不一致），原壓縮檔沒有變更。", e.path);
    }
#undef FAIL
    [fm removeItemAtPath:dir error:nil];
    return [self replaceArchiveWith:tmp error:error];
}

@end
