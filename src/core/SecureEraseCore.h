#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>

namespace xs::erase {
enum class Stage { Checking, Ready, Overwriting, Flushing, Verifying, Deleting, Complete };
enum class Error {
  None, Io, Cancelled, Verify, Changed, Unsupported, Links, Streams,
  Path, TooMany, Busy, Access, Missing, Directory, Close, Ui
};
struct Failure {
  Error reason;
  unsigned long system = 0;
};
struct Outcome {
  std::uint64_t written = 0, verified = 0;
  bool possiblyChanged = false, overwriteVerified = false, deleted = false;
  Error error = Error::None;
  unsigned long system = 0;
  Stage failedStage = Stage::Ready;
};
struct Update {
  Stage stage = Stage::Checking;
  std::uint64_t completed = 0, total = 0;
};
// The Win32 implementation retains the SAME exclusive, validated file handle
// from confirmation until deletion. Tests exercise this algorithm with real
// portable files and injected failures; they do not certify physical erasure.
class Io {
public:
  virtual ~Io() = default;
  virtual std::uint64_t length() = 0;
  virtual void rewind() = 0;
  virtual std::size_t write(const unsigned char*, std::size_t) = 0;
  virtual std::size_t read(unsigned char*, std::size_t) = 0;
  virtual void flush() = 0;
  virtual void remove() = 0;
};
using Observer = std::function<void(Update)>;
using Cancel = std::function<bool()>;
inline Outcome overwriteAndDelete(Io& io, std::uint64_t expected,
                                  const Observer& report, const Cancel& cancel) {
  Outcome result;
  Stage stage = Stage::Ready;
  try {
    std::array<unsigned char, 64 * 1024> buffer{};
    const auto publish = [&](Stage value, std::uint64_t done) {
      stage = value;
      if (report) report({value, done, expected});
    };
    const auto checkCancel = [&]() {
      if (cancel && cancel()) throw Failure{Error::Cancelled};
    };
    checkCancel();
    if (io.length() != expected) throw Failure{Error::Changed};
    io.rewind();
    publish(Stage::Overwriting, 0);
    while (result.written < expected) {
      checkCancel();
      const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(
          expected - result.written, buffer.size()));
      // A failing write can have side effects even if no byte count returns.
      result.possiblyChanged = true;
      const auto n = io.write(buffer.data(), count);
      if (!n || n > count) throw Failure{Error::Io};
      result.written += n;
      publish(Stage::Overwriting, result.written);
    }
    publish(Stage::Flushing, result.written);
    io.flush();
    checkCancel();
    if (io.length() != expected) throw Failure{Error::Changed};
    io.rewind();
    publish(Stage::Verifying, 0);
    while (result.verified < expected) {
      checkCancel();
      const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(
          expected - result.verified, buffer.size()));
      const auto n = io.read(buffer.data(), count);
      if (!n || n > count) throw Failure{Error::Io};
      for (std::size_t i = 0; i < n; ++i)
        if (buffer[i]) throw Failure{Error::Verify};
      result.verified += n;
      publish(Stage::Verifying, result.verified);
    }
    if (io.length() != expected) throw Failure{Error::Changed};
    result.overwriteVerified = true;
    checkCancel();
    publish(Stage::Deleting, expected);
    result.possiblyChanged = true;
    io.remove();
    result.deleted = true;
    publish(Stage::Complete, expected);
  } catch (const Failure& error) {
    result.error = error.reason;
    result.system = error.system;
    result.failedStage = stage;
  } catch (...) {
    result.error = Error::Io;
    result.failedStage = stage;
  }
  return result;
}
} // namespace xs::erase
