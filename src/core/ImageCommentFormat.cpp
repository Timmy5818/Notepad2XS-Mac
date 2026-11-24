#include "ImageCommentFormat.h"
#include <algorithm>
#include <array>
#include <cstring>

namespace xs::image {
namespace {
using Bytes = std::vector<uint8_t>;
constexpr uint8_t pngSignature[] = {137, 80, 78, 71, 13, 10, 26, 10};
constexpr char textKeyword[] = "Notepad2XS";
constexpr char binarySignature[] = "N2XIMG01";
constexpr size_t headerSize = 16;
constexpr size_t textLimit = 64u * 1024u * 1024u;
constexpr size_t payloadLimit = 128u * 1024u * 1024u;
constexpr size_t fileLimit = 512u * 1024u * 1024u;

struct Range {
  size_t begin = 0, end = 0;
};
struct Layout {
  Range comment;
  size_t insert = 0;
  uint32_t width = 0, height = 0;
  bool alpha = false, extended = false;
};

uint32_t read32(const uint8_t* p, bool bigEndian = false) noexcept {
  uint32_t result = 0;
  for (unsigned i = 0; i < 4; ++i)
    result |= static_cast<uint32_t>(p[i]) << ((bigEndian ? 3 - i : i) * 8);
  return result;
}
void write32(uint8_t* p, uint32_t value, bool bigEndian = false) noexcept {
  for (unsigned i = 0; i < 4; ++i)
    p[i] = static_cast<uint8_t>(value >> ((bigEndian ? 3 - i : i) * 8));
}
void append32(Bytes& out, uint32_t value, bool bigEndian = false) {
  const size_t offset = out.size();
  out.resize(offset + 4);
  write32(out.data() + offset, value, bigEndian);
}
uint32_t crc32(const uint8_t* p, size_t size) noexcept {
  static constexpr auto table = [] {
    std::array<uint32_t, 256> result{};
    for (uint32_t i = 0; i < result.size(); ++i) {
      auto value = i;
      for (unsigned bit = 0; bit < 8; ++bit)
        value = (value >> 1) ^ (0xedb88320u & (0u - (value & 1u)));
      result[i] = value;
    }
    return result;
  }();
  uint32_t crc = 0xffffffffu;
  for (size_t i = 0; i < size; ++i)
    crc = (crc >> 8) ^ table[(crc ^ p[i]) & 255u];
  return ~crc;
}
bool tag(const uint8_t* p, const char (&type)[5]) noexcept {
  return std::memcmp(p, type, 4) == 0;
}
bool reject(std::string& error, const char* message) {
  error = message;
  return false;
}
bool savePayload(Payload& payload, Mode mode, const uint8_t* data, size_t size, std::string& error) {
  if (size > (mode == Mode::Text ? textLimit : payloadLimit))
    return reject(error, "圖片內嵌文字超過大小上限。");
  std::string bytes(reinterpret_cast<const char*>(data), size);
  if (mode == Mode::Text && !jpeg::validUtf8(bytes))
    return reject(error, "圖片內嵌文字不是有效的 UTF-8。");
  payload = {true, mode, std::move(bytes)};
  return true;
}
bool readBinary(Payload& payload, const uint8_t* data, size_t size, std::string& error) {
  if (size < headerSize || size - headerSize > payloadLimit ||
      std::memcmp(data, binarySignature, 8) != 0 ||
      data[8] > static_cast<uint8_t>(Mode::Exes) || data[9] || data[10] || data[11])
    return reject(error, "圖片內嵌資料的標頭或模式無效。");
  if (read32(data + 12) != crc32(data + headerSize, size - headerSize))
    return reject(error, "圖片內嵌資料的完整性驗證失敗。");
  return savePayload(payload, static_cast<Mode>(data[8]), data + headerSize, size - headerSize, error);
}
void appendBinary(Bytes& out, Mode mode, const std::string& bytes) {
  out.insert(out.end(), binarySignature, binarySignature + 8);
  out.insert(out.end(), {static_cast<uint8_t>(mode), 0, 0, 0});
  append32(out, crc32(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size()));
  out.insert(out.end(), bytes.begin(), bytes.end());
}

bool scanPng(const Bytes& source, Layout& layout, Payload& payload, std::string& error) {
  bool dataSeen = false, dataEnded = false, palette = false;
  uint8_t color = 0;
  for (size_t pos = sizeof(pngSignature); pos < source.size();) {
    const auto remain = source.size() - pos;
    if (remain < 12) break;
    const auto* p = source.data() + pos;
    const size_t size = read32(p, true);
    const auto* type = p + 4;
    const auto* data = type + 4;
    if (size > remain - 12) break;
    if (read32(data + size, true) != crc32(type, size + 4))
      return reject(error, "PNG 資料區塊的 CRC 不符。");
    for (size_t i = 0; i < 4; ++i)
      if (!((type[i] >= 'A' && type[i] <= 'Z') || (type[i] >= 'a' && type[i] <= 'z')))
        return reject(error, "PNG 資料區塊名稱無效。");
    const size_t end = pos + size + 12;
    if (pos == sizeof(pngSignature) && !tag(type, "IHDR")) break;
    if (tag(type, "IHDR")) {
      if (pos != sizeof(pngSignature) || size != 13) break;
      const auto width = read32(data, true), height = read32(data + 4, true);
      color = data[9];
      if (!width || !height || width > 0x7fffffffu || height > 0x7fffffffu) break;
      const auto depth = data[8];
      const bool validDepth = color == 0 ? (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16)
          : color == 3 ? (depth == 1 || depth == 2 || depth == 4 || depth == 8)
          : (color == 2 || color == 4 || color == 6) && (depth == 8 || depth == 16);
      if (!validDepth || data[10] || data[11] || data[12] > 1) break;
    } else if (tag(type, "PLTE")) {
      if (palette || dataSeen || !size || size > 768 || size % 3 || color == 0 || color == 4) break;
      palette = true;
    } else if (tag(type, "IDAT")) {
      if (dataEnded || (color == 3 && !palette)) break;
      dataSeen = true;
    } else if (tag(type, "IEND")) {
      if (!dataSeen || size || end != source.size()) break;
      layout.insert = pos;
      return true;
    } else {
      if ((type[0] & 0x20) == 0)
        return reject(error, "PNG 含有不支援的必要資料區塊。");
      if (dataSeen) dataEnded = true;
      const bool isText = tag(type, "iTXt") && size >= sizeof(textKeyword) &&
          std::memcmp(data, textKeyword, sizeof(textKeyword)) == 0;
      const bool isBinary = tag(type, "npXs");
      if (isText || isBinary) {
        if (payload.found) return reject(error, "PNG 含有重複的 Notepad2XS 文字資料。");
        if (isText) {
          const size_t offset = sizeof(textKeyword);
          // The two flags are zero. Language and translated keyword may be
          // populated by a metadata editor; both must be NUL-terminated.
          if (size < offset + 4 || data[offset] || data[offset + 1])
            return reject(error, "PNG Notepad2XS iTXt 文字格式不支援。");
          const auto* languageEnd = std::find(data + offset + 2, data + size, uint8_t{0});
          if (languageEnd == data + size) break;
          const auto* titleEnd = std::find(languageEnd + 1, data + size, uint8_t{0});
          if (titleEnd == data + size) break;
          const auto* text = titleEnd + 1;
          if (std::find(text, data + size, uint8_t{0}) != data + size)
            return reject(error, "PNG iTXt 內嵌文字含有 NUL。");
          if (!savePayload(payload, Mode::Text, text, static_cast<size_t>(data + size - text), error)) return false;
        } else if (!readBinary(payload, data, size, error)) {
          return false;
        }
        layout.comment = {pos, end};
      }
    }
    pos = end;
  }
  return reject(error, "PNG 資料區塊不完整或順序無效。");
}

struct RiffChunk {
  const uint8_t* type = nullptr;
  const uint8_t* data = nullptr;
  size_t size = 0, end = 0;
};
bool riffChunk(const uint8_t* base, size_t pos, size_t limit, RiffChunk& chunk) noexcept {
  if (limit - pos < 8) return false;
  const auto* p = base + pos;
  const size_t length = read32(p + 4);
  const auto remain = limit - pos - 8;
  if (length > remain || (length & 1u) > remain - length) return false;
  if ((length & 1u) && p[8 + length] != 0) return false;
  chunk = {p, p + 8, length, pos + 8 + length + (length & 1u)};
  return true;
}
struct Frame {
  uint32_t width = 0, height = 0;
  bool alpha = false;
};
bool bitstream(const RiffChunk& part, Frame& frame) noexcept {
  const auto* p = part.data;
  if (tag(part.type, "VP8L")) {
    if (part.size < 5 || p[0] != 0x2f) return false;
    const auto word = read32(p + 1);
    if (word >> 29) return false;
    frame = {(word & 0x3fffu) + 1, ((word >> 14) & 0x3fffu) + 1, (word & (1u << 28)) != 0};
  } else {
    if (part.size < 10 || (p[0] & 1u) || p[3] != 0x9d || p[4] != 0x01 || p[5] != 0x2a)
      return false;
    const auto word = read32(p + 6);
    frame = {word & 0x3fffu, (word >> 16) & 0x3fffu, false};
  }
  return frame.width && frame.height;
}
uint32_t read24(const uint8_t* p) noexcept {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
      (static_cast<uint32_t>(p[2]) << 16);
}
bool animationFrame(const RiffChunk& part, uint32_t canvasWidth, uint32_t canvasHeight) {
  if (part.size < 16) return false;
  const auto* p = part.data;
  const auto width = read24(p + 6) + 1, height = read24(p + 9) + 1;
  if (2 * read24(p) + width > canvasWidth || 2 * read24(p + 3) + height > canvasHeight)
    return false;
  bool image = false, alpha = false;
  for (size_t pos = 16; pos < part.size;) {
    RiffChunk child;
    if (!riffChunk(p, pos, part.size, child)) return false;
    if (tag(child.type, "ALPH")) {
      if (image || alpha || !child.size) return false;
      alpha = true;
    } else if (tag(child.type, "VP8 ") || tag(child.type, "VP8L")) {
      Frame frame;
      if (image || (alpha && tag(child.type, "VP8L")) || !bitstream(child, frame) ||
          frame.width != width || frame.height != height)
        return false;
      image = true;
    }
    pos = child.end;
  }
  return image;
}
bool scanWebp(const Bytes& source, Layout& layout, Payload& payload, std::string& error) {
  if (read32(source.data() + 4) != source.size() - 8)
    return reject(error, "WebP RIFF 長度不符。");
  bool animated = false, animHeader = false, image = false, alpha = false, profile = false;
  for (size_t pos = 12; pos < source.size();) {
    RiffChunk part;
    if (!riffChunk(source.data(), pos, source.size(), part))
      return reject(error, "WebP 資料區塊長度或補位無效。");
    if (tag(part.type, "VP8X")) {
      if (pos != 12 || part.size != 10)
        return reject(error, "WebP 延伸標頭無效。");
      layout.extended = true;
      animated = (part.data[0] & 2u) != 0;
      layout.width = read24(part.data + 4) + 1;
      layout.height = read24(part.data + 7) + 1;
      if (static_cast<uint64_t>(layout.width) * layout.height > 0xffffffffu)
        return reject(error, "WebP 畫布大小超出格式限制。");
    } else if (tag(part.type, "ICCP")) {
      if (!layout.extended || image || alpha || profile || animHeader)
        return reject(error, "WebP 色彩描述區塊位置不正確。");
      profile = true;
    } else if (tag(part.type, "ANIM")) {
      if (!animated || animHeader || image || part.size != 6)
        return reject(error, "WebP 動畫標頭無效。");
      animHeader = true;
    } else if (tag(part.type, "ANMF")) {
      if (!animHeader || !animationFrame(part, layout.width, layout.height))
        return reject(error, "WebP 動畫影格格式不完整或尺寸無效。");
      image = true;
    } else if (tag(part.type, "ALPH")) {
      if (!layout.extended || animated || image || alpha || !part.size)
        return reject(error, "WebP 透明資料區塊位置不正確。");
      alpha = true;
    } else if (tag(part.type, "VP8 ") || tag(part.type, "VP8L")) {
      Frame frame;
      if (image || animated || (alpha && tag(part.type, "VP8L")) || !bitstream(part, frame) ||
          (layout.extended && (frame.width != layout.width || frame.height != layout.height)))
        return reject(error, "WebP 影像標頭或尺寸無效。");
      layout.width = frame.width;
      layout.height = frame.height;
      layout.alpha = alpha || frame.alpha;
      image = true;
    } else if (tag(part.type, "N2XS")) {
      if (!layout.extended || payload.found)
        return reject(error, "WebP 的 Notepad2XS 資料區塊不完整或重複。");
      if (!readBinary(payload, part.data, part.size, error)) return false;
      layout.comment = {pos, part.end};
    }
    pos = part.end;
  }
  if (!image) return reject(error, "WebP 缺少影像資料。");
  layout.insert = source.size();
  return true;
}

bool scan(Format format, const Bytes& source, Layout& layout, Payload& payload, std::string& error) {
  if (format == Format::Unknown || detect(source) != format || source.size() > fileLimit)
    return reject(error, "圖片格式與副檔名不符，或檔案超過 512 MiB。");
  return format == Format::Png ? scanPng(source, layout, payload, error)
                               : scanWebp(source, layout, payload, error);
}
void appendRange(Bytes& out, const Bytes& source, size_t begin, size_t end) {
  out.insert(out.end(), source.data() + begin, source.data() + end);
}
void appendTag(Bytes& out, const char (&type)[5]) {
  out.insert(out.end(), type, type + 4);
}
void appendPng(Bytes& out, Mode mode, const std::string& bytes) {
  // PNG iTXt forbids NUL. Preserve such TXT documents in the private
  // container, just as JPEG and WebP preserve their exact UTF-8 bytes.
  const bool text = mode == Mode::Text && bytes.find('\0') == bytes.npos;
  const size_t size = (text ? sizeof(textKeyword) + 4 : headerSize) + bytes.size();
  append32(out, static_cast<uint32_t>(size), true);
  const size_t typeOffset = out.size();
  if (text) {
    appendTag(out, "iTXt");
    out.insert(out.end(), textKeyword, textKeyword + sizeof(textKeyword));
    out.insert(out.end(), {0, 0, 0, 0});
    out.insert(out.end(), bytes.begin(), bytes.end());
  } else {
    appendTag(out, "npXs");
    appendBinary(out, mode, bytes);
  }
  append32(out, crc32(out.data() + typeOffset, size + 4), true);
}
void appendWebpHeader(Bytes& out, const Layout& layout) {
  appendTag(out, "VP8X");
  append32(out, 10);
  out.insert(out.end(), {static_cast<uint8_t>(layout.alpha ? 0x10 : 0), 0, 0, 0});
  for (const auto size : {layout.width, layout.height})
    for (unsigned i = 0; i < 3; ++i)
      out.push_back(static_cast<uint8_t>((size - 1) >> (i * 8)));
}
} // namespace

Format detect(const std::vector<uint8_t>& source) noexcept {
  if (source.size() >= sizeof(pngSignature) && !std::memcmp(source.data(), pngSignature, sizeof(pngSignature)))
    return Format::Png;
  if (source.size() >= 12 && tag(source.data(), "RIFF") && tag(source.data() + 8, "WEBP"))
    return Format::Webp;
  if (source.size() >= 2 && source[0] == 0xff && source[1] == 0xd8)
    return Format::Jpeg;
  return Format::Unknown;
}
bool extract(Format format, const std::vector<uint8_t>& source, Payload& payload, std::string& error) {
  if (format == Format::Jpeg) return jpeg::extract(source, payload, error);
  payload = {};
  error.clear();
  Layout layout;
  Payload result;
  if (!scan(format, source, layout, result, error)) return false;
  payload = std::move(result);
  return true;
}
bool replace(Format format, const std::vector<uint8_t>& source, Mode mode, const std::string& bytes,
             const std::array<uint8_t, 16>& documentId, std::vector<uint8_t>& output, std::string& error) {
  if (format == Format::Jpeg) return jpeg::replace(source, mode, bytes, documentId, output, error);
  error.clear();
  if (&source == &output) return reject(error, "圖片讀寫緩衝區不可相同。");
  output.clear();
  if (static_cast<uint8_t>(mode) > static_cast<uint8_t>(Mode::Exes) ||
      bytes.size() > (mode == Mode::Text ? textLimit : payloadLimit))
    return reject(error, "圖片內嵌資料的模式或長度無效。");
  if (mode == Mode::Text && !jpeg::validUtf8(bytes))
    return reject(error, "圖片內嵌文字必須是有效的 UTF-8。");
  Layout layout;
  {
    Payload previous;
    if (!scan(format, source, layout, previous, error)) return false;
  }
  const bool webp = format == Format::Webp;
  const size_t begin = webp ? 12 : 0;
  const auto erased = layout.comment.end - layout.comment.begin;
  const size_t overhead = webp ? 8 + headerSize + (bytes.size() & 1u) + (layout.extended ? 0 : 18)
      : 12 + std::max(sizeof(textKeyword) + 4, headerSize);
  if (source.size() - erased + bytes.size() + overhead > fileLimit)
    return reject(error, "加入文字後圖片超過 512 MiB。");
  Bytes result;
  result.reserve(source.size() - erased + bytes.size() + overhead);
  if (webp) {
    appendRange(result, source, 0, begin);
    if (!layout.extended) appendWebpHeader(result, layout);
  }
  if (erased) {
    appendRange(result, source, begin, layout.comment.begin);
    appendRange(result, source, layout.comment.end, layout.insert);
  } else {
    appendRange(result, source, begin, layout.insert);
  }
  if (webp) {
    appendTag(result, "N2XS");
    append32(result, static_cast<uint32_t>(headerSize + bytes.size()));
    appendBinary(result, mode, bytes);
    if (bytes.size() & 1u) result.push_back(0);
    write32(result.data() + 4, static_cast<uint32_t>(result.size() - 8));
  } else {
    appendPng(result, mode, bytes);
    appendRange(result, source, layout.insert, source.size());
  }
  output = std::move(result);
  return true;
}
} // namespace xs::image
