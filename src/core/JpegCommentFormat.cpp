#include "JpegCommentFormat.h"
#include <algorithm>
#include <cstring>
#include <iterator>
#include <limits>
#include <utility>

namespace xs::jpeg {
namespace {
constexpr uint8_t kSignature[8] = {'N','2','X','S','J','P','G','1'};
constexpr uint8_t kVersion = 1;
constexpr size_t kHeaderSize = 48;
constexpr size_t kMaxCommentData = 65533; // JPEG segment length field excludes the two marker bytes.
constexpr size_t kChunkBytes = kMaxCommentData - kHeaderSize;
constexpr uint64_t kMaxContainerBytes = 128ull * 1024ull * 1024ull;
constexpr uint32_t kMaxParts = 4096;

struct CommentRange {
  size_t markerBegin = 0;
  size_t markerEnd = 0;
  size_t dataBegin = 0;
  size_t dataLength = 0;
};
struct MarkerScan {
  std::vector<CommentRange> comments;
  size_t firstSos = std::numeric_limits<size_t>::max();
};

uint16_t read16(const uint8_t* p) noexcept {
  return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}
uint16_t read16le(const uint8_t* p) noexcept {
  return static_cast<uint16_t>(static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8));
}
uint32_t read32le(const uint8_t* p) noexcept {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
      (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
uint64_t read64le(const uint8_t* p) noexcept {
  uint64_t value = 0;
  for (unsigned i = 0; i < 8; ++i) value |= static_cast<uint64_t>(p[i]) << (i * 8);
  return value;
}
void put16be(std::vector<uint8_t>& out, uint16_t value) {
  out.push_back(static_cast<uint8_t>(value >> 8));
  out.push_back(static_cast<uint8_t>(value));
}
void put16le(uint8_t* p, uint16_t value) noexcept {
  p[0] = static_cast<uint8_t>(value);
  p[1] = static_cast<uint8_t>(value >> 8);
}
void put32le(uint8_t* p, uint32_t value) noexcept {
  for (unsigned i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(value >> (i * 8));
}
void put64le(uint8_t* p, uint64_t value) noexcept {
  for (unsigned i = 0; i < 8; ++i) p[i] = static_cast<uint8_t>(value >> (i * 8));
}
uint32_t crc32(const uint8_t* data, size_t size) noexcept {
  uint32_t crc = 0xffffffffu;
  for (size_t i = 0; i < size; ++i) {
    crc ^= data[i];
    for (unsigned bit = 0; bit < 8; ++bit)
      crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}
bool isStandalone(uint8_t marker) noexcept {
  return marker == 0xD8 || marker == 0xD9 || marker == 0x01 ||
      (marker >= 0xD0 && marker <= 0xD7);
}
bool isStartOfFrame(uint8_t marker) noexcept {
  return (marker >= 0xC0 && marker <= 0xC3) ||
      (marker >= 0xC5 && marker <= 0xC7) ||
      (marker >= 0xC9 && marker <= 0xCB) ||
      (marker >= 0xCD && marker <= 0xCF);
}
bool scanMarkers(const std::vector<uint8_t>& jpeg, MarkerScan& scan, std::string& error) {
  scan = MarkerScan{};
  if (jpeg.size() < 4 || jpeg[0] != 0xff || jpeg[1] != 0xd8) {
    error = "不是有效的 JPEG SOI 檔案。";
    return false;
  }
  size_t pos = 2;
  bool inEntropy = false;
  bool sawSof = false;
  bool sawSos = false;
  bool sawEoi = false;
  while (pos < jpeg.size()) {
    if (inEntropy) {
      // Entropy-coded bytes may contain FF00 stuffing and RSTn markers. Only
      // an unstuffed, non-restart marker ends the current scan.
      while (pos < jpeg.size() && jpeg[pos] != 0xff) ++pos;
      if (pos >= jpeg.size()) break;
      const size_t markerBegin = pos;
      size_t codePos = pos + 1;
      while (codePos < jpeg.size() && jpeg[codePos] == 0xff) ++codePos;
      if (codePos >= jpeg.size()) {
        error = "JPEG 掃描資料在 Marker 中途截斷。";
        return false;
      }
      const uint8_t code = jpeg[codePos];
      if (code == 0x00) { pos = codePos + 1; continue; }
      if (code >= 0xd0 && code <= 0xd7) { pos = codePos + 1; continue; }
      inEntropy = false;
      pos = markerBegin;
    }

    if (pos >= jpeg.size() || jpeg[pos] != 0xff) {
      error = "JPEG Marker 結構無效。";
      return false;
    }
    const size_t markerBegin = pos;
    size_t codePos = pos + 1;
    while (codePos < jpeg.size() && jpeg[codePos] == 0xff) ++codePos;
    if (codePos >= jpeg.size()) {
      error = "JPEG Marker 在檔案結尾被截斷。";
      return false;
    }
    const uint8_t marker = jpeg[codePos];
    if (marker == 0x00) {
      error = "JPEG 在掃描資料之外出現非法 FF00。";
      return false;
    }
    if (marker == 0xd9) { sawEoi = true; break; }
    if (marker == 0xd8) {
      error = "JPEG 影像資料內出現重複 SOI。";
      return false;
    }
    if (isStandalone(marker)) {
      pos = codePos + 1;
      continue;
    }
    if (codePos + 2 >= jpeg.size()) {
      error = "JPEG Segment 長度欄位不完整。";
      return false;
    }
    const uint16_t segmentLength = read16(&jpeg[codePos + 1]);
    if (segmentLength < 2) {
      error = "JPEG Segment 長度小於 2。";
      return false;
    }
    const size_t segmentEnd = codePos + 1u + static_cast<size_t>(segmentLength);
    if (segmentEnd > jpeg.size()) {
      error = "JPEG Segment 超出檔案範圍。";
      return false;
    }
    if (isStartOfFrame(marker)) sawSof = true;
    if (marker == 0xfe) {
      CommentRange range;
      range.markerBegin = markerBegin;
      range.markerEnd = segmentEnd;
      range.dataBegin = codePos + 3;
      range.dataLength = static_cast<size_t>(segmentLength) - 2;
      scan.comments.push_back(range);
    }
    if (marker == 0xda) {
      if (!sawSos) scan.firstSos = markerBegin;
      sawSos = true;
      inEntropy = true;
    } else if (marker == 0xdc && sawSos) {
      // DNL may be embedded in an entropy-coded scan; resume that scan after
      // the DNL segment rather than treating following entropy bytes as markers.
      inEntropy = true;
    }
    pos = segmentEnd;
  }
  if (!sawSof || !sawSos || !sawEoi) {
    error = !sawSof ? "JPEG 缺少 SOF 影像框架標記。" :
        (!sawSos ? "JPEG 缺少 SOS 掃描資料。" : "JPEG 缺少 EOI 結束標記。");
    return false;
  }
  return true;
}
bool hasSignature(const uint8_t* data, size_t length) noexcept {
  return length >= sizeof(kSignature) && std::memcmp(data, kSignature, sizeof(kSignature)) == 0;
}

} // namespace

bool validUtf8(const std::string& value) noexcept {
  size_t i = 0;
  while (i < value.size()) {
    const uint8_t c = static_cast<uint8_t>(value[i]);
    if (c <= 0x7f) { ++i; continue; }
    size_t n = 0;
    uint32_t cp = 0;
    if (c >= 0xc2 && c <= 0xdf) { n = 1; cp = c & 0x1f; }
    else if (c >= 0xe0 && c <= 0xef) { n = 2; cp = c & 0x0f; }
    else if (c >= 0xf0 && c <= 0xf4) { n = 3; cp = c & 0x07; }
    else return false;
    if (i + n >= value.size()) return false;
    for (size_t j = 1; j <= n; ++j) {
      const uint8_t t = static_cast<uint8_t>(value[i + j]);
      if ((t & 0xc0) != 0x80) return false;
      cp = (cp << 6) | (t & 0x3f);
    }
    if ((n == 1 && cp < 0x80) || (n == 2 && cp < 0x800) ||
        (n == 3 && cp < 0x10000) || cp > 0x10ffff ||
        (cp >= 0xd800 && cp <= 0xdfff)) return false;
    i += n + 1;
  }
  return true;
}

bool extract(const std::vector<uint8_t>& jpeg, Payload& payload, std::string& error) {
  payload = Payload{};
  error.clear();
  MarkerScan scan;
  if (!scanMarkers(jpeg, scan, error)) return false;
  struct Part {
    uint32_t index = 0;
    const uint8_t* data = nullptr;
    size_t length = 0;
  };
  std::vector<Part> parts;
  uint8_t modeByte = 0;
  uint8_t version = 0;
  uint32_t partCount = 0;
  uint64_t totalLength = 0;
  uint32_t expectedCrc = 0;
  std::array<uint8_t, 16> documentId{};
  bool haveHeader = false;

  for (const auto& comment : scan.comments) {
    const uint8_t* data = jpeg.data() + comment.dataBegin;
    const size_t length = comment.dataLength;
    if (!hasSignature(data, length)) {
      if (length >= 4 && std::memcmp(data, "N2XS", 4) == 0) {
        error = "Notepad2XS JPEG COM Signature 不完整或版本標記損毀。";
        return false;
      }
      continue;
    }
    if (length < kHeaderSize) { error = "Notepad2XS JPEG COM 標頭不完整。"; return false; }
    const uint8_t currentVersion = data[8];
    const uint8_t currentMode = data[9];
    const uint16_t headerSize = read16le(data + 10);
    if (currentVersion != kVersion || headerSize != kHeaderSize || currentMode > 2) {
      error = "Notepad2XS JPEG COM 版本或模式不支援。";
      return false;
    }
    const uint32_t currentIndex = read32le(data + 28);
    const uint32_t currentCount = read32le(data + 32);
    const uint64_t currentTotal = read64le(data + 36);
    const uint32_t currentCrc = read32le(data + 44);
    if (!currentCount || currentCount > kMaxParts || currentIndex >= currentCount ||
        currentTotal > kMaxContainerBytes) {
      error = "Notepad2XS JPEG COM 分段數量或總長度無效。";
      return false;
    }
    if (!haveHeader) {
      version = currentVersion; modeByte = currentMode; partCount = currentCount;
      totalLength = currentTotal; expectedCrc = currentCrc;
      std::copy(data + 12, data + 28, documentId.begin());
      haveHeader = true;
    } else if (version != currentVersion || modeByte != currentMode || partCount != currentCount ||
        totalLength != currentTotal || expectedCrc != currentCrc ||
        !std::equal(documentId.begin(), documentId.end(), data + 12)) {
      error = "Notepad2XS JPEG COM 混入不同文件或不同版本的分段。";
      return false;
    }
    parts.push_back({currentIndex, data + kHeaderSize, length - kHeaderSize});
  }
  if (!haveHeader) return true;
  const uint64_t expectedParts64 = std::max<uint64_t>(1, (totalLength + kChunkBytes - 1) / kChunkBytes);
  if (expectedParts64 != partCount || expectedParts64 > kMaxParts || parts.size() != partCount) {
    error = "Notepad2XS JPEG COM 分段遺失或數量不一致。";
    return false;
  }
  std::sort(parts.begin(), parts.end(), [](const Part& a, const Part& b) { return a.index < b.index; });
  std::string combined;
  combined.reserve(static_cast<size_t>(totalLength));
  for (uint32_t i = 0; i < partCount; ++i) {
    const Part& part = parts[i];
    if (part.index != i) { error = "Notepad2XS JPEG COM 分段重複或順序索引有缺漏。"; return false; }
    const uint64_t remaining = totalLength - static_cast<uint64_t>(combined.size());
    const size_t expectedSize = static_cast<size_t>(std::min<uint64_t>(kChunkBytes, remaining));
    if (part.length != expectedSize) { error = "Notepad2XS JPEG COM 分段長度不一致。"; return false; }
    combined.append(reinterpret_cast<const char*>(part.data), part.length);
  }
  if (combined.size() != totalLength || crc32(reinterpret_cast<const uint8_t*>(combined.data()), combined.size()) != expectedCrc) {
    error = "Notepad2XS JPEG COM 完整性檢查失敗，資料可能損毀。";
    return false;
  }
  const Mode mode = static_cast<Mode>(modeByte);
  if (mode == Mode::Text && !validUtf8(combined)) {
    error = "Notepad2XS JPEG TXT 內容不是有效 UTF-8。";
    return false;
  }
  payload.found = true;
  payload.mode = mode;
  payload.bytes = std::move(combined);
  return true;
}

bool replace(const std::vector<uint8_t>& original, Mode mode, const std::string& bytes,
             const std::array<uint8_t, 16>& documentId,
             std::vector<uint8_t>& result, std::string& error) {
  error.clear();
  result.clear();
  if (mode != Mode::Text && mode != Mode::Aes && mode != Mode::Exes) {
    error = "Notepad2XS JPEG 儲存模式無效。";
    return false;
  }
  if (bytes.size() > kMaxContainerBytes) {
    error = "JPEG 內嵌文件超過 128 MiB 容量上限。";
    return false;
  }
  if (mode == Mode::Text && !validUtf8(bytes)) {
    error = "JPEG TXT 內容不是有效 UTF-8，已取消儲存。";
    return false;
  }
  MarkerScan scan;
  if (!scanMarkers(original, scan, error)) return false;
  const uint64_t partCount64 = std::max<uint64_t>(1, (bytes.size() + kChunkBytes - 1) / kChunkBytes);
  if (partCount64 > kMaxParts) { error = "JPEG COM 分段數量超過安全上限。"; return false; }
  const uint32_t partCount = static_cast<uint32_t>(partCount64);
  const uint32_t checksum = crc32(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());

  size_t removedBeforeSos = 0;
  for (const auto& comment : scan.comments)
    if (comment.markerBegin < scan.firstSos) removedBeforeSos += comment.markerEnd - comment.markerBegin;
  if (removedBeforeSos > scan.firstSos) { error = "JPEG COM Marker 位移計算失敗。"; return false; }
  const size_t insertOffset = scan.firstSos - removedBeforeSos;

  // Copy all bytes except every syntactically valid COM segment. Non-COM
  // markers and entropy-coded image data are kept byte-for-byte.
  result.reserve(original.size() + bytes.size() + static_cast<size_t>(partCount) * (kHeaderSize + 4));
  size_t cursor = 0;
  for (const auto& comment : scan.comments) {
    if (comment.markerBegin < cursor || comment.markerEnd > original.size()) {
      error = "JPEG COM 區段重疊或範圍無效。";
      result.clear();
      return false;
    }
    result.insert(result.end(), original.begin() + static_cast<std::ptrdiff_t>(cursor),
        original.begin() + static_cast<std::ptrdiff_t>(comment.markerBegin));
    cursor = comment.markerEnd;
  }
  result.insert(result.end(), original.begin() + static_cast<std::ptrdiff_t>(cursor), original.end());
  if (insertOffset > result.size()) { error = "JPEG COM 插入位置無效。"; result.clear(); return false; }

  std::vector<uint8_t> segments;
  const uint64_t segmentBytes = static_cast<uint64_t>(partCount) * (kHeaderSize + 4) + bytes.size();
  if (segmentBytes > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    error = "JPEG COM 配置大小超出平台限制。"; result.clear(); return false;
  }
  segments.reserve(static_cast<size_t>(segmentBytes));
  for (uint32_t index = 0; index < partCount; ++index) {
    const size_t offset = static_cast<size_t>(index) * kChunkBytes;
    const size_t count = std::min(kChunkBytes, bytes.size() - std::min(bytes.size(), offset));
    std::vector<uint8_t> comment(kHeaderSize + count, 0);
    std::copy(std::begin(kSignature), std::end(kSignature), comment.begin());
    comment[8] = kVersion;
    comment[9] = static_cast<uint8_t>(mode);
    put16le(comment.data() + 10, static_cast<uint16_t>(kHeaderSize));
    std::copy(documentId.begin(), documentId.end(), comment.begin() + 12);
    put32le(comment.data() + 28, index);
    put32le(comment.data() + 32, partCount);
    put64le(comment.data() + 36, bytes.size());
    put32le(comment.data() + 44, checksum);
    if (count) std::memcpy(comment.data() + kHeaderSize, bytes.data() + offset, count);
    segments.push_back(0xff);
    segments.push_back(0xfe);
    put16be(segments, static_cast<uint16_t>(comment.size() + 2));
    segments.insert(segments.end(), comment.begin(), comment.end());
  }
  result.insert(result.begin() + static_cast<std::ptrdiff_t>(insertOffset), segments.begin(), segments.end());

  Payload verify;
  if (!extract(result, verify, error) || !verify.found || verify.mode != mode || verify.bytes != bytes) {
    if (error.empty()) error = "JPEG COM 儲存後回讀驗證失敗。";
    result.clear();
    return false;
  }
  return true;
}

} // namespace xs::jpeg
