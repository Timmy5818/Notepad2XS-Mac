#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace xs::jpeg {

enum class Mode : uint8_t { Text = 0, Aes = 1, Exes = 2 };

struct Payload {
  bool found = false;
  Mode mode = Mode::Text;
  std::string bytes;
};

// Parse JPEG marker structure (including markers between progressive scans),
// extracting only the versioned Notepad2XS COM container. Other COM comments
// are intentionally ignored on read and removed on write.
bool extract(const std::vector<uint8_t>& jpeg, Payload& payload, std::string& error);

// Replace every JPEG COM marker with a fresh Notepad2XS multi-COM container.
// documentId must contain 16 cryptographically-random bytes supplied by caller.
bool replace(const std::vector<uint8_t>& original, Mode mode, const std::string& bytes,
             const std::array<uint8_t, 16>& documentId,
             std::vector<uint8_t>& result, std::string& error);

bool validUtf8(const std::string& value) noexcept;

} // namespace xs::jpeg
