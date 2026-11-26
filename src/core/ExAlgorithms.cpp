// Native EX_MD3 v6 and Notepad2XS EXES (60,000-round salted EX_MD3 KDF).
// The X60 envelope/stream primitives are retained; no JavaScript runtime.
#include "ExAlgorithms.h"
#include "CryptoProgressState.h"
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <vector>
#ifdef _WIN32
#include <windows.h>
// BCrypt declarations depend on the Windows base types above.
#include <bcrypt.h>
#ifdef _MSC_VER
#pragma comment(lib, "bcrypt.lib")
#endif
#else
#include <fstream>
#endif
namespace xs {
namespace {
void wipe(void *p, size_t n) {
  volatile uint8_t *b = static_cast<volatile uint8_t *>(p);
  while (n--)
    *b++ = 0;
}
struct Bytes : std::vector<uint8_t> {
  using std::vector<uint8_t>::vector;
  ~Bytes() {
    if (!empty())
      wipe(data(), size());
  }
};
Bytes bytes(const std::string &s) { return Bytes(s.begin(), s.end()); }
void append(Bytes &a, const Bytes &b) { a.insert(a.end(), b.begin(), b.end()); }
uint64_t rr(uint64_t x, unsigned n) { return (x >> n) | (x << (64 - n)); }
uint64_t rl(uint64_t x, unsigned n) {
  return n ? (x << n) | (x >> (64 - n)) : x;
}
static const uint64_t K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL,
    0xe9b5dba58189dbbcULL, 0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
    0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL, 0xd807aa98a3030242ULL,
    0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL,
    0xc19bf174cf692694ULL, 0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
    0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL, 0x2de92c6f592b0275ULL,
    0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL,
    0xbf597fc7beef0ee4ULL, 0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
    0x06ca6351e003826fULL, 0x142929670a0e6e70ULL, 0x27b70a8546d22ffcULL,
    0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL,
    0x92722c851482353bULL, 0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
    0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL, 0xd192e819d6ef5218ULL,
    0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL,
    0x34b0bcb5e19b48a8ULL, 0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
    0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL, 0x748f82ee5defb2fcULL,
    0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL,
    0xc67178f2e372532bULL, 0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
    0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL, 0x06f067aa72176fbaULL,
    0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL,
    0x431d67c49c100d4cULL, 0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
    0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL};
static const uint64_t IV[8] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
                               0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
                               0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
                               0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
Bytes sha512(const Bytes &input, const std::function<void(unsigned)>& progress = {}) {
  Bytes m = input;
  m.push_back(128);
  while (m.size() % 128 != 112)
    m.push_back(0);
  const uint64_t bits = static_cast<uint64_t>(input.size()) * 8;
  m.insert(m.end(), 8, 0);
  for (int i = 7; i >= 0; --i)
    m.push_back(static_cast<uint8_t>(bits >> (i * 8)));
  uint64_t h[8];
  std::copy(IV, IV + 8, h);
  for (size_t p = 0; p < m.size(); p += 128) {
    if(progress && p % 65536 == 0)progress(static_cast<unsigned>(p*100/m.size()));
    uint64_t w[80] = {};
    for (int i = 0; i < 16; ++i)
      for (int j = 0; j < 8; ++j)
        w[i] = (w[i] << 8) | m[p + static_cast<size_t>(i) * 8 + static_cast<size_t>(j)];
    for (int i = 16; i < 80; ++i)
      w[i] = w[i - 16] +
             (rr(w[i - 15], 1) ^ rr(w[i - 15], 8) ^ (w[i - 15] >> 7)) +
             w[i - 7] + (rr(w[i - 2], 19) ^ rr(w[i - 2], 61) ^ (w[i - 2] >> 6));
    uint64_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5],
             g = h[6], v = h[7];
    for (int i = 0; i < 80; ++i) {
      uint64_t t = v + (rr(e, 14) ^ rr(e, 18) ^ rr(e, 41)) +
                   ((e & f) ^ (~e & g)) + K[i] + w[i];
      uint64_t u =
          (rr(a, 28) ^ rr(a, 34) ^ rr(a, 39)) + ((a & b) ^ (a & c) ^ (b & c));
      v = g;
      g = f;
      f = e;
      e = d + t;
      d = c;
      c = b;
      b = a;
      a = t + u;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += v;
    wipe(w, sizeof(w));
  }
  Bytes out;
  for (uint64_t v : h)
    for (int j = 7; j >= 0; --j)
      out.push_back(static_cast<uint8_t>(v >> (j * 8)));
  wipe(h, sizeof(h));
  return out;
}
Bytes sha3(const Bytes &input, const std::function<void(unsigned)>& progress = {}) {
  static const unsigned rot[25] = {0,  1, 62, 28, 27, 36, 44, 6,  55,
                                   20, 3, 10, 43, 25, 39, 41, 45, 15,
                                   21, 8, 18, 2,  61, 56, 14};
  static const uint64_t rc[24] = {0x1ULL,
                                  0x8082ULL,
                                  0x800000000000808aULL,
                                  0x8000000080008000ULL,
                                  0x808bULL,
                                  0x80000001ULL,
                                  0x8000000080008081ULL,
                                  0x8000000000008009ULL,
                                  0x8aULL,
                                  0x88ULL,
                                  0x80008009ULL,
                                  0x8000000aULL,
                                  0x8000808bULL,
                                  0x800000000000008bULL,
                                  0x8000000000008089ULL,
                                  0x8000000000008003ULL,
                                  0x8000000000008002ULL,
                                  0x8000000000000080ULL,
                                  0x800aULL,
                                  0x800000008000000aULL,
                                  0x8000000080008081ULL,
                                  0x8000000000008080ULL,
                                  0x80000001ULL,
                                  0x8000000080008008ULL};
  Bytes m = input;
  m.push_back(6);
  while (m.size() % 72)
    m.push_back(0);
  m.back() |= 128;
  uint64_t a[25] = {};
  for (size_t p = 0; p < m.size(); p += 72) {
    if(progress && (p/72) % 1024 == 0)progress(static_cast<unsigned>(p*100/m.size()));
    for (unsigned i = 0; i < 72; ++i)
      a[i / 8] ^= static_cast<uint64_t>(m[p + i]) << ((i % 8) * 8);
    for (uint64_t r : rc) {
      uint64_t c[5], d[5], b[25];
      for (int x = 0; x < 5; ++x)
        c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
      for (int x = 0; x < 5; ++x)
        d[x] = c[(x + 4) % 5] ^ rl(c[(x + 1) % 5], 1);
      for (int y = 0; y < 5; ++y)
        for (int x = 0; x < 5; ++x) {
          int i = x + 5 * y;
          a[i] ^= d[x];
          b[y + 5 * ((2 * x + 3 * y) % 5)] = rl(a[i], rot[i]);
        }
      for (int y = 0; y < 5; ++y)
        for (int x = 0; x < 5; ++x)
          a[x + 5 * y] = b[x + 5 * y] ^
                         ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
      a[0] ^= r;
    }
  }
  Bytes out;
  for (unsigned i = 0; i < 64; ++i)
    out.push_back(static_cast<uint8_t>(a[i / 8] >> ((i % 8) * 8)));
  wipe(a, sizeof(a));
  return out;
}
Bytes hmac(const Bytes &key, const Bytes &msg) {
  Bytes k = key;
  if (k.size() > 128)
    k = sha512(k);
  k.resize(128, 0);
  Bytes inner = k, outer = k;
  for (auto &b : inner)
    b ^= 0x36;
  for (auto &b : outer)
    b ^= 0x5c;
  append(inner, msg);
  append(outer, sha512(inner));
  return sha512(outer);
}
bool validUTF8(const std::string &s) {
  for (size_t i = 0; i < s.size();) {
    uint32_t c = static_cast<uint8_t>(s[i++]);
    unsigned n = 0;
    uint32_t min = 0;
    if (c < 128)
      continue;
    if (c >= 0xc2 && c <= 0xdf) {
      c &= 31;
      n = 1;
      min = 128;
    } else if (c >= 0xe0 && c <= 0xef) {
      c &= 15;
      n = 2;
      min = 2048;
    } else if (c >= 0xf0 && c <= 0xf4) {
      c &= 7;
      n = 3;
      min = 65536;
    } else
      return false;
    if (s.size() - i < n)
      return false;
    while (n--) {
      uint8_t b = static_cast<uint8_t>(s[i++]);
      if ((b & 192) != 128)
        return false;
      c = (c << 6) | (b & 63);
    }
    if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
      return false;
  }
  return true;
}
Bytes derive(const Bytes &prk, const char *label) {
  Bytes info = bytes(label);
  info.push_back(1);
  return hmac(prk, info);
}
uint32_t rot32(uint32_t x, unsigned n) { return (x << n) | (x >> (32 - n)); }
uint32_t load32(const uint8_t *b) {
  return uint32_t(b[0]) | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) |
         (uint32_t(b[3]) << 24);
}
void quarter(uint32_t *x, int a, int b, int c, int d) {
  x[a] += x[b];
  x[d] = rot32(x[d] ^ x[a], 16);
  x[c] += x[d];
  x[b] = rot32(x[b] ^ x[c], 12);
  x[a] += x[b];
  x[d] = rot32(x[d] ^ x[a], 8);
  x[c] += x[d];
  x[b] = rot32(x[b] ^ x[c], 7);
}
struct Stream {
  Bytes key, nonce, block;
  uint64_t counter = 1;
  size_t index = 128;
  Stream(const Bytes &k, const Bytes &n) : key(k), nonce(n) {}
  uint8_t next() {
    if (index == 128) {
      if (!counter)
        throw std::runtime_error("counter");
      uint32_t s[32] = {}, x[32];
      // JS reads two missing trailing constant bytes as zero.
      uint8_t constant[32] = {};
      const char label[] = "EXES-V6.0-ChaCha512-1024-state!!";
      std::memcpy(constant, label, sizeof(label) - 1);
      for (int i = 0; i < 8; ++i)
        s[i] = load32(constant + i * 4);
      for (int i = 0; i < 16; ++i)
        s[8 + i] = load32(key.data() + i * 4);
      s[24] = static_cast<uint32_t>(counter);
      s[25] = static_cast<uint32_t>(counter >> 32);
      ++counter;
      for (int i = 0; i < 6; ++i)
        s[26 + i] = load32(nonce.data() + i * 4);
      std::copy(s, s + 32, x);
      for (int r = 0; r < 10; ++r) {
        for (int c = 0; c < 8; ++c)
          quarter(x, c, 8 + c, 16 + c, 24 + c);
        for (int c = 0; c < 8; ++c)
          quarter(x, c, 8 + ((c + 1) & 7), 16 + ((c + 2) & 7),
                  24 + ((c + 3) & 7));
      }
      block.resize(128);
      for (int i = 0; i < 32; ++i) {
        uint32_t v = x[i] + s[i];
        for (int j = 0; j < 4; ++j)
          block[static_cast<size_t>(i) * 4 + static_cast<size_t>(j)] =
              static_cast<uint8_t>(v >> (j * 8));
      }
      wipe(s, sizeof(s));
      wipe(x, sizeof(x));
      index = 0;
    }
    return block[index++];
  }
  uint32_t word() {
    uint32_t a = next(), b = next(), c = next();
    return (a << 16) | (b << 8) | c;
  }
};
const char charset[] =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
void pack(uint32_t v, std::string &out) {
  uint32_t n = v * 54 + v % 54;
  char c[5];
  for (int i = 4; i >= 0; --i) {
    c[i] = charset[n % 62];
    n /= 62;
  }
  out.append(c, 5);
}
uint32_t unpack(std::string_view s, size_t pos) {
  if (pos > s.size() || s.size() - pos < 5)
    throw std::runtime_error("format");
  uint32_t n = 0;
  for (size_t i = 0; i < 5; ++i) {
    const char *p = std::strchr(charset, s[pos + i]);
    if (!s[pos + i] || !p)
      throw std::runtime_error("format");
    n = n * 62 + static_cast<uint32_t>(p - charset);
  }
  uint32_t v = n / 54;
  if (v > 0xffffff || n % 54 != v % 54)
    throw std::runtime_error("format");
  return v;
}
void wordBytes(Bytes &b, uint32_t v) {
  b.push_back(static_cast<uint8_t>(v >> 16));
  b.push_back(static_cast<uint8_t>(v >> 8));
  b.push_back(static_cast<uint8_t>(v));
}
void packBytes(const Bytes &b, std::string &out) {
  for (size_t i = 0; i < b.size(); i += 3) {
    uint32_t v = uint32_t(b[i]) << 16;
    if (i + 1 < b.size())
      v |= uint32_t(b[i + 1]) << 8;
    if (i + 2 < b.size())
      v |= b[i + 2];
    pack(v, out);
  }
}
Bytes unpackBytes(const std::string &s, size_t off, size_t groups) {
  Bytes b;
  b.reserve(groups * 3);
  for (size_t i = 0; i < groups; ++i)
    wordBytes(b, unpack(s, off + i * 5));
  return b;
}
Bytes nonceFor(const Bytes &iv) {
  Bytes m = iv;
  append(m, bytes("EXES-V6.0-NONCE-192"));
  Bytes n = sha512(m);
  n.resize(24);
  return n;
}
Bytes tagFor(const Bytes &key, const Bytes &salt, const Bytes &iv, uint32_t hi,
             uint32_t lo, const Bytes &ct) {
  Bytes m = bytes("X60");
  append(m, salt);
  append(m, iv);
  wordBytes(m, hi);
  wordBytes(m, lo);
  append(m, ct);
  return hmac(key, m);
}
void checkPassword(const std::string &s) {
  if (s.empty() || s.size() > 1024 * 1024 || !validUTF8(s))
    throw std::runtime_error("password");
}

// Clear the KDF-owned credential input and round outputs on exit,
// including exceptions. Never cache the result across salts/documents.
template <typename Char> struct SecretText {
  std::basic_string<Char> value;
  SecretText() = default;
  SecretText(const SecretText &) = delete;
  SecretText &operator=(const SecretText &) = delete;
  void clear() noexcept {
    if (!value.empty()) wipe(&value[0], value.size() * sizeof(Char));
    value.clear();
  }
  ~SecretText() { clear(); }
};

Bytes stretchExesPassword(const std::string &password, const Bytes &salt) {
#ifdef XS_EXES_TESTING
  // Integration tests exercise many document transactions with a lower cost.
  // The separate production KDF suite never defines this test-only macro.
  constexpr uint32_t iterations = 1000;
#else
  constexpr uint32_t iterations = 60000;
#endif
  constexpr char16_t hex[] = u"0123456789abcdef";
  SecretText<char16_t> input;
  // password is already checked as strict UTF-8 by both public entry points.
  // Decode to UTF-16 so the first EX_MD3 frame has the same U16 length and
  // encoding as ex_md3n(prefix + saltHex + password, 60000) in the JS reference.
  input.value.reserve(16 + salt.size() * 2 + password.size());
  input.value = u"notepad2xs_exes_";
  for (uint8_t b : salt) {
    input.value += hex[b >> 4];
    input.value += hex[b & 15];
  }
  for (size_t i = 0; i < password.size();) {
    uint32_t c = static_cast<uint8_t>(password[i++]);
    unsigned continuation = 0;
    if (c >= 0xf0) { c &= 7; continuation = 3; }
    else if (c >= 0xe0) { c &= 15; continuation = 2; }
    else if (c >= 0xc0) { c &= 31; continuation = 1; }
    while (continuation > 0) {
      --continuation;
      c = (c << 6) | (static_cast<uint8_t>(password[i++]) & 63u);
    }
    if (c <= 0xffff) input.value += static_cast<char16_t>(c);
    else {
      c -= 0x10000;
      input.value += static_cast<char16_t>(0xd800 + (c >> 10));
      input.value += static_cast<char16_t>(0xdc00 + (c & 1023));
    }
  }
  reportCryptoProgress(CryptoStage::Deriving, 0, iterations);
  SecretText<char> result;
  for (uint32_t i = 0; i < iterations; ++i) {
    SecretText<char> next;
    next.value = exmd3(input.value);
    result.value.swap(next.value);
    input.clear();
    // EX_MD3 emits 209 ASCII characters. Prefix and salt are included only
    // in the first input; subsequent rounds hash the preceding output alone.
    if (i + 1 < iterations)
      input.value.assign(result.value.begin(), result.value.end());
    reportCryptoProgress(CryptoStage::Deriving, i + 1, iterations);
  }
  return bytes(result.value);
}
} // namespace
std::string exmd3(const std::u16string &text) { return exmd3WithProgress(text, {}); }
std::string exmd3WithProgress(const std::u16string &text, const std::function<void(unsigned)>& progress) {
  auto report=[&](unsigned value){if(progress)progress(value);};
  report(0);
  const std::string alphabet = "rt478aGHLTdbADEFyu3MeRfhi6mnQj",
                    safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxy"
                           "z0123456789-_.!~*'();,/?:@&=+$#";
  std::string enc;
  enc.reserve(text.size());
  auto emit = [&](uint32_t b) {
    const char *h = "0123456789ABCDEF";
    enc += '%';
    enc += h[(b >> 4) & 15];
    enc += h[b & 15];
  };
  for (size_t i = 0; i < text.size(); ++i) {
    if(i%65536==0)report(static_cast<unsigned>(i*20/(text.size()?text.size():1)));
    uint32_t c = text[i];
    if (c < 128 && safe.find(static_cast<char>(c)) != std::string::npos) {
      enc += static_cast<char>(c);
      continue;
    }
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.size() &&
        text[i + 1] >= 0xdc00 && text[i + 1] <= 0xdfff) {
      c = 0x10000 + ((c - 0xd800) << 10) + (text[++i] - 0xdc00);
    }
    if (c < 128)
      emit(c);
    else if (c < 2048) {
      emit(192 | (c >> 6));
      emit(128 | (c & 63));
    } else if (c < 65536) {
      emit(224 | (c >> 12));
      emit(128 | ((c >> 6) & 63));
      emit(128 | (c & 63));
    } else {
      emit(240 | (c >> 18));
      emit(128 | ((c >> 12) & 63));
      emit(128 | ((c >> 6) & 63));
      emit(128 | (c & 63));
    }
  }
  std::string frame = "EXMD3-V6|U16:" + std::to_string(text.size()) +
                      "|ENC:" + std::to_string(enc.size()) + ":";
  const std::string suffix="|ALPHABET:"+alphabet+"|OUT:209";
  frame.reserve(frame.size()+enc.size()+suffix.size());
  frame+=enc;frame+=suffix;
  if(!enc.empty())wipe(&enc[0],enc.size());
  std::string().swap(enc);
  report(20);
  Bytes seed;
  { Bytes input=bytes("EXMD3-V6-SHA512|");
    input.reserve(input.size()+frame.size());input.insert(input.end(),frame.begin(),frame.end());
    seed=sha512(input,[&](unsigned p){report(20+p*35/100);}); }
  report(55);
  { Bytes input=bytes("EXMD3-V6-SHA3-512|");
    input.reserve(input.size()+frame.size());input.insert(input.end(),frame.begin(),frame.end());
    if(!frame.empty())wipe(&frame[0],frame.size());
    std::string().swap(frame);
    append(seed,sha3(input,[&](unsigned p){report(55+p*40/100);})); }
  report(95);
  std::string out;
  for (uint32_t counter = 0; out.size() < 209; ++counter) {
    Bytes a = bytes("EXMD3-V6-SQ-SHA512|"), b = bytes("EXMD3-V6-SQ-SHA3-512|");
    append(a, seed);
    append(b, seed);
    for (int j = 3; j >= 0; --j) {
      a.push_back(static_cast<uint8_t>(counter >> (8 * j)));
      b.push_back(static_cast<uint8_t>(counter >> (8 * j)));
    }
    Bytes block = sha512(a);
    append(block, sha3(b));
    for (uint8_t v : block)
      if (v < 240 && out.size() < 209)
        out += alphabet[v % 30];
  }
  report(100);
  return out;
}
std::string exesEncrypt(const std::string &text, const std::string &password,
                        const uint8_t *fixed) {
  checkPassword(password);
  // Empty documents use the same authenticated EXES envelope (zero payload).
  if (text.size() > 64 * 1024 * 1024 || !validUTF8(text))
    throw std::runtime_error("text");
  Bytes rnd(48);
  if (fixed)
    std::copy(fixed, fixed + 48, rnd.begin());
  else {
#ifdef _WIN32
    if (BCryptGenRandom(nullptr, rnd.data(), 48,
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
      throw std::runtime_error("rng");
#else
    std::ifstream f("/dev/urandom", std::ios::binary);
    if (!f.read(reinterpret_cast<char *>(rnd.data()), 48))
      throw std::runtime_error("rng");
#endif
  }
  Bytes salt(rnd.begin(), rnd.begin() + 24), iv(rnd.begin() + 24, rnd.end()),
      prk = hmac(salt, stretchExesPassword(password, salt)),
      key = derive(prk, "EXES-V6.0-ENC-CHACHA512"),
      mac = derive(prk, "EXES-V6.0-MAC-HMAC512");
  reportCryptoProgress(CryptoStage::Encrypting);
  Stream stream(key, nonceFor(iv));
  uint32_t hi = static_cast<uint32_t>(text.size() / 16777216) ^ stream.word(),
           lo = static_cast<uint32_t>(text.size() % 16777216) ^ stream.word();
  Bytes ct((text.size() + 2) / 3 * 3);
  for (size_t i = 0; i < ct.size(); ++i)
    ct[i] = static_cast<uint8_t>(
        (i < text.size() ? static_cast<uint8_t>(text[i]) : 0) ^ stream.next());
  Bytes tag = tagFor(mac, salt, iv, hi, lo, ct);
  tag.resize(66, 0);
  reportCryptoProgress(CryptoStage::Encoding);
  std::string out = "X60";
  out.reserve(203 + ct.size() / 3 * 5);
  packBytes(salt, out);
  packBytes(iv, out);
  pack(hi, out);
  pack(lo, out);
  packBytes(ct, out);
  packBytes(tag, out);
  return out;
}
std::string exesDecrypt(const std::string &cipher,
                        const std::string &password) {
  checkPassword(password);
  if (cipher.size() < 203 ||
      cipher.size() > 203 + ((64 * 1024 * 1024 + 2) / 3) * 5 ||
      cipher.compare(0, 3, "X60") || (cipher.size() - 203) % 5)
    throw std::runtime_error("format");
  size_t groups = (cipher.size() - 203) / 5;
  Bytes salt = unpackBytes(cipher, 3, 8), iv = unpackBytes(cipher, 43, 8),
        ct = unpackBytes(cipher, 93, groups),
        tag = unpackBytes(cipher, 93 + groups * 5, 22);
  if (tag[64] || tag[65])
    throw std::runtime_error("format");
  uint32_t hi = unpack(cipher, 83), lo = unpack(cipher, 88);
  Bytes prk = hmac(salt, stretchExesPassword(password, salt)),
        key = derive(prk, "EXES-V6.0-ENC-CHACHA512"),
        mac = derive(prk, "EXES-V6.0-MAC-HMAC512");
  reportCryptoProgress(CryptoStage::Authenticating);
  Bytes expected = tagFor(mac, salt, iv, hi, lo, ct);
  uint8_t diff = 0;
  for (size_t i = 0; i < 64; ++i)
    diff = static_cast<uint8_t>(diff | (tag[i] ^ expected[i]));
  if (diff)
    throw std::runtime_error("authentication");
  reportCryptoProgress(CryptoStage::Decrypting);
  Stream stream(key, nonceFor(iv));
  const uint32_t hiMix = stream.word();
  const uint32_t loMix = stream.word();
  uint64_t len = uint64_t(hi ^ hiMix) * 16777216 + (lo ^ loMix);
  if (len > 64 * 1024 * 1024 || (len + 2) / 3 * 3 != ct.size())
    throw std::runtime_error("length");
  for (auto &b : ct)
    b ^= stream.next();
  for (size_t i = static_cast<size_t>(len); i < ct.size(); ++i)
    if (ct[i])
      throw std::runtime_error("padding");
  reportCryptoProgress(CryptoStage::Encoding);
  std::string out(ct.begin(), ct.begin() + static_cast<ptrdiff_t>(len));
  if (!validUTF8(out))
    throw std::runtime_error("utf8");
  return out;
}
} // namespace xs

namespace xs {
bool validX60Envelope(std::string_view cipher) noexcept {
  if (cipher.size() < 203 || cipher.size() > 203 + ((64 * 1024 * 1024 + 2) / 3) * 5 ||
      cipher.compare(0, 3, "X60") || (cipher.size() - 203) % 5)
    return false;
  try {
    uint32_t word = 0;
    for (size_t i = 3; i < cipher.size(); i += 5)
      word = unpack(cipher, i);
    return (word & 0xffff) == 0;
  } catch (...) {
    return false;
  }
}
}
