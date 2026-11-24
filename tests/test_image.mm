// R135 PNG／WebP（以及 JPG）內嵌文字：寫入、讀回、圖片內容不變（用 macOS ImageIO 解碼比對像素）
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "ImageCommentFormat.h"

using namespace xs::image;
using Bytes = std::vector<uint8_t>;
static int fails = 0, passes = 0;
static void Check(bool ok, NSString *name) {
    if (ok) { passes++; printf("  ✓ %s\n", name.UTF8String); } else { fails++; printf("  ✗ %s\n", name.UTF8String); }
}

// 解碼成 RGBA 像素（第一格）＋影格數；ImageIO 無法解碼時回傳 nil
static NSData *Pixels(const Bytes &b, size_t *frames) {
    NSData *d = [NSData dataWithBytes:b.data() length:b.size()];
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
    if (!src) return nil;
    *frames = CGImageSourceGetCount(src);
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    NSMutableData *px = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(img);
    return px;
}

static void RoundTrip(NSString *label, NSString *path, Format format) {
    NSData *file = [NSData dataWithContentsOfFile:path];
    Check(file != nil, [NSString stringWithFormat:@"%@：讀取底圖", label]);
    if (!file) return;
    Bytes source((const uint8_t *)file.bytes, (const uint8_t *)file.bytes + file.length);
    std::string error;
    Payload out;
    Check(detect(source) == format, [NSString stringWithFormat:@"%@：辨識格式", label]);
    Check(extract(format, source, out, error) && !out.found, [NSString stringWithFormat:@"%@：普通圖片沒有內嵌文字", label]);
    size_t frames0 = 0, frames1 = 0;
    NSData *before = Pixels(source, &frames0);
    const std::string cases[] = {u8"繁體中文 🌊\r\n第二行", std::string("a\0b", 3), "", std::string("AES\0\xff", 5), std::string("EXES\0\xf0", 6)};
    Bytes previous = source;
    bool allOk = true, pixelsOk = true;
    for (unsigned i = 0; i < 5; ++i) {
        Mode mode = i == 3 ? Mode::Aes : i == 4 ? Mode::Exes : Mode::Text;
        std::array<uint8_t, 16> id{};
        id[0] = (uint8_t)(i + 1);
        Bytes saved;
        if (!replace(format, previous, mode, cases[i], id, saved, error)) { allOk = false; break; }
        Payload p;
        if (!extract(format, saved, p, error) || !p.found || p.mode != mode || p.bytes != cases[i]) allOk = false;
        NSData *after = Pixels(saved, &frames1);
        if (!after || ![after isEqualToData:before] || frames1 != frames0) pixelsOk = false;
        previous = std::move(saved);
    }
    Check(allOk, [NSString stringWithFormat:@"%@：文字（含 NUL、空字串）、AES、EXES 寫入後讀回相同（連續覆寫 5 次）", label]);
    Check(before && pixelsOk, [NSString stringWithFormat:@"%@：寫入後 ImageIO 仍能解碼，像素與影格數不變", label]);
    Bytes invalid;
    Check(!replace(format, source, Mode::Text, "\xc0\x80", {}, invalid, error) && invalid.empty(), [NSString stringWithFormat:@"%@：拒絕無效的 UTF-8", label]);
    Bytes broken = source;
    broken[broken.size() / 2] ^= 0x5A;
    Payload bp;
    bool rejected = !extract(format, broken, bp, error) || !bp.found;
    Check(rejected, [NSString stringWithFormat:@"%@：損毀的圖片不會讀出內嵌文字", label]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *res = argc > 1 ? @(argv[1]) : @"resources";
        printf("== PNG ==\n");
        RoundTrip(@"PNG 預設底圖", [res stringByAppendingPathComponent:@"PngDefaultArtwork.png"], Format::Png);
        printf("== WebP ==\n");
        RoundTrip(@"WebP 預設底圖", [res stringByAppendingPathComponent:@"WebpDefaultArtwork.webp"], Format::Webp);
        printf("== JPG ==\n");
        RoundTrip(@"JPG 預設底圖", [res stringByAppendingPathComponent:@"JpegDefaultArtwork.jpg"], Format::Jpeg);
        printf(fails ? "失敗 %d 項\n" : "全部通過（%d 項）\n", fails ? fails : passes);
        return fails ? 1 : 0;
    }
}
