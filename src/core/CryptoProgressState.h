#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <utility>

namespace xs {
enum class CryptoStage : uint8_t {
  Preparing, Deriving, Encrypting, Authenticating, Decrypting, Encoding,
  Saving, Complete
};
struct CryptoUpdate {
  CryptoStage stage = CryptoStage::Preparing;
  uint32_t completed = 0, total = 0;
};
using CryptoObserver = std::function<void(CryptoUpdate)>;
// An observer belongs only to the worker executing this job. Nested scopes
// restore the preceding observer; unrelated threads never inherit one.
inline thread_local const CryptoObserver* cryptoObserver = nullptr;
class CryptoObserverScope {
  const CryptoObserver* previous_;
public:
  explicit CryptoObserverScope(const CryptoObserver& observer) noexcept
      : previous_(cryptoObserver) { cryptoObserver = &observer; }
  ~CryptoObserverScope() { cryptoObserver = previous_; }
  CryptoObserverScope(const CryptoObserverScope&) = delete;
  CryptoObserverScope& operator=(const CryptoObserverScope&) = delete;
};
inline void reportCryptoProgress(CryptoStage stage, uint32_t completed = 0,
                                 uint32_t total = 0) {
  if (cryptoObserver) (*cryptoObserver)({stage, completed, total});
}
// One atomic snapshot prevents mixed stage/count reads by the UI. No text,
// password, HWND, or document state is ever shared through this channel.
class CryptoProgressState {
  std::atomic<uint64_t> value_{0};
public:
  CryptoStage publish(CryptoUpdate update) noexcept {
    constexpr uint64_t mask = (uint64_t(1) << 28) - 1;
    const uint64_t next = (uint64_t(update.stage) << 56) |
        ((uint64_t(update.total) & mask) << 28) | (uint64_t(update.completed) & mask);
    return static_cast<CryptoStage>(value_.exchange(next, std::memory_order_relaxed) >> 56);
  }
  CryptoUpdate read() const noexcept {
    constexpr uint64_t mask = (uint64_t(1) << 28) - 1;
    const auto value = value_.load(std::memory_order_relaxed);
    return {static_cast<CryptoStage>(value >> 56), static_cast<uint32_t>(value & mask),
            static_cast<uint32_t>((value >> 28) & mask)};
  }
};
// Stage transitions and final completion bypass the 100-ms paint interval.
class CryptoPaintSchedule {
  uint64_t last_ = 0;
  CryptoStage stage_ = CryptoStage::Preparing;
  bool painted_ = false;
public:
  bool due(uint64_t now, CryptoStage stage, bool force = false) noexcept {
    if (!force && painted_ && stage == stage_ && now - last_ < 100) return false;
    painted_ = true; last_ = now; stage_ = stage; return true;
  }
};
}
