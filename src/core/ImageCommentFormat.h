#pragma once
#include "JpegCommentFormat.h"

namespace xs::image {

enum class Format { Unknown, Jpeg, Png, Webp };
using jpeg::Mode;
using jpeg::Payload;

Format detect(const std::vector<uint8_t>& source) noexcept;
bool extract(Format format, const std::vector<uint8_t>& source, Payload& payload, std::string& error);
bool replace(Format format, const std::vector<uint8_t>& source, Mode mode, const std::string& bytes,
             const std::array<uint8_t, 16>& documentId, std::vector<uint8_t>& output, std::string& error);

} // namespace xs::image
