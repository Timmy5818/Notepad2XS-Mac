#import "BookmarkStore.h"
#import "ScintillaView.h"
#include "BookmarkFile.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <climits>

using namespace xs::bookmarks;

namespace {
struct FileState {
    std::vector<LineBookmark> lines;
    std::optional<ViewState> view;
};

struct Sidecar {
    std::string folder;   // …/.2xs
    std::string file;     // …/.2xs/<EX_MD3>.ini
};

sptr_t S(ScintillaView *v, unsigned int m, uptr_t w = 0, sptr_t l = 0) { return [v message:m wParam:w lParam:l]; }

std::u16string U16(NSString *s) {
    std::u16string r(s.length, u'\0');
    [s getCharacters:(unichar *)r.data() range:NSMakeRange(0, s.length)];
    return r;
}

// 與 Windows 版相同：用帶副檔名的完整檔名（壓縮檔內的文件加上「|成員路徑」）算 EX_MD3。
// macOS 的檔名可能是分解形式（NFD），先轉成 Windows 常用的組合形式（NFC），兩邊才會算出同一個名稱
Sidecar SidecarFor(NSURL *url, NSString *member) {
    if (!url.isFileURL || !url.path.length) throw std::runtime_error("bookmark path must be a file");
    NSString *name = url.lastPathComponent.precomposedStringWithCanonicalMapping;
    if (!name.length || [name isEqualToString:@"/"]) throw std::runtime_error("missing document name");
    if (member.length) name = [NSString stringWithFormat:@"%@|%@", name, member.precomposedStringWithCanonicalMapping];
    NSString *folder = [url.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".2xs"];
    Sidecar s;
    s.folder = folder.fileSystemRepresentation;
    s.file = s.folder + "/" + sidecarName(U16(name));
    return s;
}

// 資料夾不能是符號連結（與 Windows 版拒絕重新剖析點相同）
void OpenFolder(const Sidecar &s, bool create, bool *exists) {
    struct stat st;
    if (lstat(s.folder.c_str(), &st) != 0) {
        if (errno != ENOENT) throw std::runtime_error("cannot open bookmark folder");
        if (!create) { *exists = false; return; }
        if (mkdir(s.folder.c_str(), 0755) != 0 && errno != EEXIST) throw std::runtime_error("cannot create bookmark folder");
        if (lstat(s.folder.c_str(), &st) != 0) throw std::runtime_error("cannot open bookmark folder");
        chflags(s.folder.c_str(), st.st_flags | UF_HIDDEN);   // 名稱以「.」開頭本來就隱藏；再加上 Finder 的隱藏旗標
    }
    if (!S_ISDIR(st.st_mode)) throw std::runtime_error("invalid bookmark folder");
    *exists = true;
}

bool ReadSidecar(const Sidecar &s, FileState &state) {
    int fd = open(s.file.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) return false;
        throw std::runtime_error("cannot read bookmarks");
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || (size_t)st.st_size > fileLimit) {
        close(fd);
        throw std::runtime_error("invalid bookmark file size");
    }
    std::string bytes((size_t)st.st_size, '\0');
    ssize_t n = read(fd, bytes.data(), bytes.size());
    close(fd);
    if (n != (ssize_t)bytes.size() || !parse(bytes, state.lines, &state.view)) throw std::runtime_error("invalid bookmark data");
    return true;
}

// 先寫到同資料夾的暫存檔再改名，避免寫到一半的檔案；replace=NO 時目的檔已存在就放棄
bool Publish(const std::string &folder, const std::string &path, std::string_view bytes, bool replace) {
    NSString *token = NSUUID.UUID.UUIDString;
    std::string temp = folder + "/" + token.UTF8String + ".tmp";
    int fd = open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) throw std::runtime_error("cannot create temporary bookmark file");
    bool ok = write(fd, bytes.data(), bytes.size()) == (ssize_t)bytes.size() && fsync(fd) == 0;
    close(fd);
    if (!ok) { unlink(temp.c_str()); throw std::runtime_error("cannot write bookmarks"); }
    int r = replace ? rename(temp.c_str(), path.c_str()) : renamex_np(temp.c_str(), path.c_str(), RENAME_EXCL);
    if (r != 0) { unlink(temp.c_str()); return false; }
    return true;
}

void EnsureReadme(const std::string &folder) noexcept {
    try {
        std::string path = folder + "/readme.txt";
        struct stat st;
        if (lstat(path.c_str(), &st) == 0 && !S_ISDIR(st.st_mode)) return;
        static const char message[] = "\xEF\xBB\xBF這是 notepad2xs 相關設定檔用資料夾。\r\n"
                                      "內含此目錄各文件的手動書籤與檢視狀態。\r\n";
        Publish(folder, path, std::string_view(message, sizeof(message) - 1), false);
    } catch (...) {
        // 說明檔與文件設定無關，失敗也不影響
    }
}

void WriteSidecar(const Sidecar &s, const std::vector<LineBookmark> *lines, const std::optional<ViewState> &view) {
    bool exists = false;
    OpenFolder(s, true, &exists);
    EnsureReadme(s.folder);
    FileState state;
    const bool had = ReadSidecar(s, state);
    if (had && (!lines || *lines == state.lines) && (!view || view == state.view)) return;
    if (lines) state.lines = *lines;
    if (view) state.view = view;
    if (!Publish(s.folder, s.file, serialize(state.lines, state.view), had))
        throw std::runtime_error("cannot publish document settings");
}

std::vector<LineBookmark> CurrentLines(ScintillaView *v) {
    std::vector<LineBookmark> lines;
    sptr_t line = S(v, SCI_MARKERNEXT, 0, N2ManualBookmarkMask);
    while (line >= 0) {
        if (line >= INT_MAX || lines.size() >= fileLimit / 2) throw std::length_error("bookmark list too large");
        sptr_t marks = S(v, SCI_MARKERGET, (uptr_t)line);
        lines.push_back({(int)line + 1, (marks & (1u << N2RedBookmark)) != 0});
        line = S(v, SCI_MARKERNEXT, (uptr_t)line + 1, N2ManualBookmarkMask);
    }
    return lines;
}

int NonNegative(sptr_t value) { return (int)std::clamp<sptr_t>(value, 0, INT_MAX); }

ViewState CaptureView(ScintillaView *v) {
    int top = NonNegative(S(v, SCI_GETFIRSTVISIBLELINE));
    int line = NonNegative(S(v, SCI_DOCLINEFROMVISIBLE, (uptr_t)top));
    int visible = NonNegative(S(v, SCI_VISIBLEFROMDOCLINE, (uptr_t)line));
    uptr_t caret = (uptr_t)S(v, SCI_GETCURRENTPOS);
    return {line, std::max(0, top - visible), NonNegative(S(v, SCI_GETXOFFSET)),
            NonNegative(S(v, SCI_LINEFROMPOSITION, caret)), NonNegative(S(v, SCI_GETCOLUMN, caret)),
            (int)std::clamp<sptr_t>(S(v, SCI_GETZOOM), -zoomLimit, zoomLimit)};
}

void ApplyView(ScintillaView *v, const ViewState &view) {
    sptr_t lastLine = std::max<sptr_t>(0, S(v, SCI_GETLINECOUNT) - 1);
    S(v, SCI_SETZOOM, (uptr_t)view.zoom);
    uptr_t caretLine = (uptr_t)std::min<sptr_t>(view.caretLine, lastLine);
    sptr_t caret = S(v, SCI_FINDCOLUMN, caretLine, view.caretColumn);
    S(v, SCI_GOTOPOS, (uptr_t)caret);
    uptr_t topLine = (uptr_t)std::min<sptr_t>(view.topLine, lastLine);
    sptr_t visible = std::max<sptr_t>(0, S(v, SCI_VISIBLEFROMDOCLINE, topLine));
    sptr_t wraps = std::max<sptr_t>(0, S(v, SCI_WRAPCOUNT, topLine) - 1);
    S(v, SCI_SETFIRSTVISIBLELINE, (uptr_t)(visible + std::min<sptr_t>(view.wrappedLine, wraps)));
    if (S(v, SCI_GETWRAPMODE) == SC_WRAP_NONE) S(v, SCI_SETXOFFSET, (uptr_t)std::min(view.horizontalOffset, INT_MAX / 2));
}
}

NSURL *N2BookmarkSidecarURL(NSURL *url, NSString *member) {
    try {
        Sidecar s = SidecarFor(url, member);
        return [NSURL fileURLWithFileSystemRepresentation:s.file.c_str() isDirectory:NO relativeToURL:nil];
    } catch (...) { return nil; }
}

@implementation N2BookmarkContext {
    std::vector<LineBookmark> _lines;   // 上次成功讀寫的書籤
    std::optional<ViewState> _view;
    BOOL _retryBookmarks, _retryView;
    NSURL *_pendingURL;                 // 文件仍鎖定（尚未解密）時：解密後才載入
    NSString *_pendingMember;
}

- (void)reset {
    _lines.clear();
    _view.reset();
    _retryBookmarks = _retryView = NO;
    _pendingURL = nil;
    _pendingMember = nil;
}

- (void)restore:(ScintillaView *)v state:(FileState &)state {
    if (state.view) ApplyView(v, *state.view);
    _view = state.view;
    auto &lines = state.lines;
    sptr_t count = S(v, SCI_GETLINECOUNT);
    lines.erase(std::upper_bound(lines.begin(), lines.end(), count,
        [](sptr_t last, const LineBookmark &b) { return last < b.line; }), lines.end());
    for (const auto &b : lines) {
        if (S(v, SCI_MARKERADD, (uptr_t)(b.line - 1), b.red ? N2RedBookmark : N2BlueBookmark) < 0) {
            S(v, SCI_MARKERDELETEALL, N2BlueBookmark);
            S(v, SCI_MARKERDELETEALL, N2RedBookmark);
            return;
        }
    }
    _lines = std::move(lines);
}

- (void)loadInto:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked {
    [self reset];
    if (!url) return;
    try {
        if (locked) { _pendingURL = url; _pendingMember = member; }
        Sidecar s = SidecarFor(url, member);
        bool exists = false;
        OpenFolder(s, true, &exists);   // 與 Windows 版相同：成功開啟文件（即使只是閱讀）就建立 .2xs
        EnsureReadme(s.folder);
        FileState state;
        if (!ReadSidecar(s, state) && !Publish(s.folder, s.file, serialize({}), false))
            ReadSidecar(s, state);      // 其他視窗可能剛好先建立了
        if (!locked) [self restore:v state:state];
    } catch (...) {
        // 書籤只是附加資訊，失敗不影響開檔
    }
}

- (void)loadAfterUnlock:(ScintillaView *)v {
    if (!_pendingURL) return;
    NSURL *url = _pendingURL;
    NSString *member = _pendingMember;
    _pendingURL = nil;
    _pendingMember = nil;
    try {
        Sidecar s = SidecarFor(url, member);
        bool exists = false;
        OpenFolder(s, false, &exists);
        FileState state;
        if (exists && ReadSidecar(s, state)) [self restore:v state:state];
    } catch (...) {
    }
}

- (BOOL)save:(ScintillaView *)v url:(NSURL *)url member:(NSString *)member locked:(BOOL)locked mode:(N2BookmarkSaveMode)mode {
    if (!url || locked || _pendingURL) return NO;
    const bool includeBookmarks = mode != N2BookmarkSaveViewOnly;
    try {
        ViewState view = CaptureView(v);
        const bool writeView = mode != N2BookmarkSaveChanged || _retryView || view != _view;
        auto lines = includeBookmarks ? CurrentLines(v) : std::vector<LineBookmark>{};
        const bool writeBookmarks = includeBookmarks && (mode == N2BookmarkSaveNewTarget || _retryBookmarks || lines != _lines);
        if (!writeView && !writeBookmarks) return NO;
        WriteSidecar(SidecarFor(url, member), writeBookmarks ? &lines : nullptr,
                     writeView ? std::optional<ViewState>{view} : std::nullopt);
        if (writeBookmarks) { _lines = std::move(lines); _retryBookmarks = NO; }
        if (writeView) { _view = view; _retryView = NO; }
    } catch (...) {
        // 之後存檔時再試；文件本身的儲存不受影響
        _retryBookmarks |= includeBookmarks;
        _retryView = YES;
    }
    return YES;
}

@end
