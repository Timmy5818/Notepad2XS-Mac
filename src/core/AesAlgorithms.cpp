// Native AES-256-GCM implementation for the Notepad2XS authenticated format.
#include "AesAlgorithms.h"
#include "CryptoProgressState.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>
#elif defined(__APPLE__)
// macOS 移植：PBKDF2 與 AES 區塊加密使用系統 CommonCrypto，亂數使用 Security.framework。
// CommonCrypto 沒有公開的 GCM 介面，因此 GCM（CTR＋GHASH）在下方自行組合。
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <Security/SecRandom.h>
#else
// Non-Windows test backend only. Windows builds use the native CNG provider.
#include <openssl/evp.h>
#include <openssl/rand.h>
#endif

namespace xs {
namespace {
void scrub(void *p, size_t n) noexcept {
  volatile uint8_t *b = static_cast<volatile uint8_t *>(p);
  while (n--)
    *b++ = 0;
}
struct Data : std::vector<uint8_t> {
  using std::vector<uint8_t>::vector;
  ~Data() {
    if (!empty())
      scrub(data(), size());
  }
};

constexpr char kFormatPrefix[] = "nb2XSAeSGcMveR1";
constexpr size_t kFormatPrefixLength = sizeof(kFormatPrefix) - 1;
constexpr size_t kHeaderLength = 16;
constexpr size_t kSaltLength = 16;
constexpr size_t kNonceLength = 12;
constexpr size_t kTagLength = 16;
constexpr size_t kKeyLength = 32;
constexpr size_t kMaxPlaintext = 64u * 1024u * 1024u;
#ifdef XS_AES_TESTING
// The production format uses 600,000 iterations. Portable integration tests
// compile with this test-only override to avoid repeating an expensive KDF.
constexpr uint32_t kPbkdf2Iterations = 1000;
#else
constexpr uint32_t kPbkdf2Iterations = 600000;
#endif

#ifdef _WIN32
void check(NTSTATUS status) {
  if (status < 0)
    throw std::runtime_error("Windows crypto operation failed");
}
struct Provider {
  BCRYPT_ALG_HANDLE h = nullptr;
  explicit Provider(LPCWSTR name, ULONG flags = 0) {
    check(BCryptOpenAlgorithmProvider(&h, name, nullptr, flags));
  }
  ~Provider() {
    if (h)
      BCryptCloseAlgorithmProvider(h, 0);
  }
  Provider(const Provider &) = delete;
  Provider &operator=(const Provider &) = delete;
};
struct Key {
  BCRYPT_KEY_HANDLE h = nullptr;
  ~Key() {
    if (h)
      BCryptDestroyKey(h);
  }
};
void randomBytes(Data &bytes) {
  if (bytes.size() > std::numeric_limits<ULONG>::max())
    throw std::runtime_error("random buffer too large");
  check(BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG));
}
Data deriveKey(const std::string &password, const Data &salt) {
  Provider p(BCRYPT_SHA256_ALGORITHM, BCRYPT_ALG_HANDLE_HMAC_FLAG);
  Data key(kKeyLength);
  check(BCryptDeriveKeyPBKDF2(
      p.h, reinterpret_cast<PUCHAR>(const_cast<char *>(password.data())),
      static_cast<ULONG>(password.size()), const_cast<PUCHAR>(salt.data()),
      static_cast<ULONG>(salt.size()), kPbkdf2Iterations, key.data(),
      static_cast<ULONG>(key.size()), 0));
  return key;
}
Data aesGcm(bool encrypt, const Data &input, const Data &key,
            const Data &nonce, const Data &aad, Data &tag) {
  Provider p(BCRYPT_AES_ALGORITHM);
  check(BCryptSetProperty(
      p.h, BCRYPT_CHAINING_MODE,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t *>(BCRYPT_CHAIN_MODE_GCM)),
      sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
  DWORD objectLength = 0, resultLength = 0;
  check(BCryptGetProperty(p.h, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&objectLength),
                          sizeof(objectLength), &resultLength, 0));
  Data object(objectLength), output(input.size() + 16);
  Key symmetricKey;
  check(BCryptGenerateSymmetricKey(p.h, &symmetricKey.h, object.data(),
                                  objectLength,
                                  const_cast<PUCHAR>(key.data()),
                                  static_cast<ULONG>(key.size()), 0));
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO auth;
  BCRYPT_INIT_AUTH_MODE_INFO(auth);
  auth.pbNonce = const_cast<PUCHAR>(nonce.data());
  auth.cbNonce = static_cast<ULONG>(nonce.size());
  auth.pbAuthData = aad.empty() ? nullptr : const_cast<PUCHAR>(aad.data());
  auth.cbAuthData = static_cast<ULONG>(aad.size());
  auth.pbTag = tag.data();
  auth.cbTag = static_cast<ULONG>(tag.size());
  ULONG written = 0;
  UCHAR emptyInput = 0;
  PUCHAR in = input.empty() ? &emptyInput : const_cast<PUCHAR>(input.data());
  PUCHAR out = output.data();
  NTSTATUS status = encrypt
      ? BCryptEncrypt(symmetricKey.h, in, static_cast<ULONG>(input.size()),
                      &auth, nullptr, 0, out,
                      static_cast<ULONG>(output.size()), &written, 0)
      : BCryptDecrypt(symmetricKey.h, in, static_cast<ULONG>(input.size()),
                      &auth, nullptr, 0, out,
                      static_cast<ULONG>(output.size()), &written, 0);
  // On authentication failure BCryptDecrypt may have touched its output
  // buffer. It remains in the scrubbed Data object and is never returned.
  check(status);
  if (written != input.size())
    throw std::runtime_error("AES-GCM output length mismatch");
  output.resize(written);
  return output;
}
#elif defined(__APPLE__)
void randomBytes(Data &bytes) {
  if (SecRandomCopyBytes(kSecRandomDefault, bytes.size(), bytes.data()) != errSecSuccess)
    throw std::runtime_error("secure random generator unavailable");
}
Data deriveKey(const std::string &password, const Data &salt) {
  Data key(kKeyLength);
  if (CCKeyDerivationPBKDF(kCCPBKDF2, password.data(), password.size(), salt.data(), salt.size(),
                           kCCPRFHmacAlgSHA256, kPbkdf2Iterations, key.data(), key.size()) != kCCSuccess)
    throw std::runtime_error("PBKDF2 failed");
  return key;
}

// AES-256 單一區塊（ECB）加密
struct AesBlock {
  CCCryptorRef ref = nullptr;
  explicit AesBlock(const Data &key) {
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeECB, kCCAlgorithmAES, ccNoPadding, nullptr,
                                key.data(), key.size(), nullptr, 0, 0, 0, &ref) != kCCSuccess)
      throw std::runtime_error("AES init failed");
  }
  ~AesBlock() { if (ref) CCCryptorRelease(ref); }
  void encrypt(const uint8_t in[16], uint8_t out[16]) const {
    size_t moved = 0;
    if (CCCryptorUpdate(ref, in, 16, out, 16, &moved) != kCCSuccess || moved != 16)
      throw std::runtime_error("AES block failed");
  }
};

// GF(2^128) 乘法（GCM 位元順序），以遮罩實作、不依資料分支
struct Block128 { uint64_t hi, lo; };
Block128 load128(const uint8_t *p) {
  Block128 b{0, 0};
  for (int i = 0; i < 8; ++i) b.hi = (b.hi << 8) | p[i];
  for (int i = 8; i < 16; ++i) b.lo = (b.lo << 8) | p[i];
  return b;
}
void store128(Block128 b, uint8_t *p) {
  for (int i = 7; i >= 0; --i) { p[i] = uint8_t(b.hi); b.hi >>= 8; }
  for (int i = 15; i >= 8; --i) { p[i] = uint8_t(b.lo); b.lo >>= 8; }
}
Block128 gfMul(Block128 x, Block128 y) {
  Block128 z{0, 0}, v = y;
  for (int i = 0; i < 128; ++i) {
    const uint64_t bit = (i < 64 ? (x.hi >> (63 - i)) : (x.lo >> (127 - i))) & 1;
    const uint64_t mask = 0 - bit;
    z.hi ^= v.hi & mask;
    z.lo ^= v.lo & mask;
    const uint64_t carry = 0 - (v.lo & 1);
    v.lo = (v.lo >> 1) | (v.hi << 63);
    v.hi = (v.hi >> 1) ^ (0xe100000000000000ULL & carry);
  }
  return z;
}
struct Ghash {
  Block128 h, y{0, 0};
  explicit Ghash(Block128 key) : h(key) {}
  void update(const uint8_t *data, size_t n) {
    for (size_t i = 0; i < n; i += 16) {
      uint8_t block[16] = {0};
      std::memcpy(block, data + i, std::min<size_t>(16, n - i));
      Block128 b = load128(block);
      y.hi ^= b.hi; y.lo ^= b.lo;
      y = gfMul(y, h);
      scrub(block, sizeof block);
    }
  }
  void lengths(uint64_t aadBytes, uint64_t textBytes) {
    Block128 b{aadBytes * 8, textBytes * 8};
    y.hi ^= b.hi; y.lo ^= b.lo;
    y = gfMul(y, h);
  }
};

Data aesGcm(bool encrypt, const Data &input, const Data &key,
            const Data &nonce, const Data &aad, Data &tag) {
  if (nonce.size() != 12 || key.size() != 32 || tag.size() != kTagLength)
    throw std::runtime_error("AES-GCM parameters");
  // 明文上限 64 MiB，遠低於 GCM 32 位元計數器的上限
  AesBlock aes(key);
  uint8_t zero[16] = {0}, hBytes[16], j0[16], ek0[16];
  aes.encrypt(zero, hBytes);
  std::memcpy(j0, nonce.data(), 12);
  j0[12] = 0; j0[13] = 0; j0[14] = 0; j0[15] = 1;
  aes.encrypt(j0, ek0);

  Ghash gh(load128(hBytes));
  gh.update(aad.data(), aad.size());
  if (!encrypt) gh.update(input.data(), input.size());

  // CTR：計數器從 inc32(J0) 開始，交給 CommonCrypto 的 CTR 模式一次處理整段。
  // CommonCrypto 以 128 位元大端序遞增；GCM 只遞增低 32 位元。明文上限 64 MiB（約 4M 區塊），
  // 從 2 開始的低 32 位元不會溢位，因此兩者產生的金鑰流相同。
  Data output(input.size());
  uint8_t counter[16];
  std::memcpy(counter, j0, 16);
  counter[15] = 2;
  if (!input.empty()) {
    CCCryptorRef ctr = nullptr;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, counter,
                                key.data(), key.size(), nullptr, 0, 0, kCCModeOptionCTR_BE, &ctr) != kCCSuccess)
      throw std::runtime_error("AES-CTR init failed");
    size_t moved = 0;
    const CCCryptorStatus st = CCCryptorUpdate(ctr, input.data(), input.size(), output.data(), output.size(), &moved);
    CCCryptorRelease(ctr);
    if (st != kCCSuccess || moved != input.size()) throw std::runtime_error("AES-CTR failed");
  }

  if (encrypt) gh.update(output.data(), output.size());
  gh.lengths(aad.size(), input.size());
  uint8_t s[16], computed[16];
  store128(gh.y, s);
  for (int i = 0; i < 16; ++i) computed[i] = s[i] ^ ek0[i];
  scrub(hBytes, sizeof hBytes);
  scrub(ek0, sizeof ek0);

  if (encrypt) {
    std::memcpy(tag.data(), computed, 16);
  } else {
    uint8_t diff = 0;   // 常數時間比較
    for (int i = 0; i < 16; ++i) diff |= uint8_t(computed[i] ^ tag[i]);
    if (diff != 0) {
      scrub(output.data(), output.size());
      throw std::runtime_error("AES-GCM authentication failed");
    }
  }
  return output;
}
#else
void randomBytes(Data &bytes) {
  if (bytes.size() > static_cast<size_t>(std::numeric_limits<int>::max()) ||
      RAND_bytes(bytes.data(), static_cast<int>(bytes.size())) != 1)
    throw std::runtime_error("secure random generator unavailable");
}
Data deriveKey(const std::string &password, const Data &salt) {
  Data key(kKeyLength);
  if (password.size() > static_cast<size_t>(std::numeric_limits<int>::max()) ||
      salt.size() > static_cast<size_t>(std::numeric_limits<int>::max()) ||
      PKCS5_PBKDF2_HMAC(password.data(), static_cast<int>(password.size()),
                        salt.data(), static_cast<int>(salt.size()),
                        static_cast<int>(kPbkdf2Iterations), EVP_sha256(),
                        static_cast<int>(key.size()), key.data()) != 1)
    throw std::runtime_error("PBKDF2 failed");
  return key;
}
Data aesGcm(bool encrypt, const Data &input, const Data &key,
            const Data &nonce, const Data &aad, Data &tag) {
  struct Context {
    EVP_CIPHER_CTX *p = EVP_CIPHER_CTX_new();
    ~Context() { EVP_CIPHER_CTX_free(p); }
  } context;
  if (!context.p)
    throw std::bad_alloc();
  const EVP_CIPHER *cipher = EVP_aes_256_gcm();
  if (EVP_CipherInit_ex(context.p, cipher, nullptr, nullptr, nullptr,
                        encrypt ? 1 : 0) != 1 ||
      EVP_CIPHER_CTX_ctrl(context.p, EVP_CTRL_GCM_SET_IVLEN,
                          static_cast<int>(nonce.size()), nullptr) != 1 ||
      EVP_CipherInit_ex(context.p, nullptr, nullptr, key.data(), nonce.data(),
                        encrypt ? 1 : 0) != 1)
    throw std::runtime_error("AES-GCM initialization failed");
  int written = 0;
  if (!aad.empty() &&
      EVP_CipherUpdate(context.p, nullptr, &written, aad.data(),
                       static_cast<int>(aad.size())) != 1)
    throw std::runtime_error("AES-GCM AAD failed");
  Data output(input.size() + 16);
  int total = 0;
  if (!input.empty()) {
    if (EVP_CipherUpdate(context.p, output.data(), &written, input.data(),
                         static_cast<int>(input.size())) != 1)
      throw std::runtime_error("AES-GCM update failed");
    total += written;
  }
  if (!encrypt && EVP_CIPHER_CTX_ctrl(context.p, EVP_CTRL_GCM_SET_TAG,
                                      static_cast<int>(tag.size()),
                                      tag.data()) != 1)
    throw std::runtime_error("AES-GCM tag setup failed");
  if (EVP_CipherFinal_ex(context.p, output.data() + total, &written) != 1)
    throw std::runtime_error("AES-GCM authentication failed");
  total += written;
  output.resize(static_cast<size_t>(total));
  if (encrypt && EVP_CIPHER_CTX_ctrl(context.p, EVP_CTRL_GCM_GET_TAG,
                                     static_cast<int>(tag.size()),
                                     tag.data()) != 1)
    throw std::runtime_error("AES-GCM tag retrieval failed");
  if (output.size() != input.size())
    throw std::runtime_error("AES-GCM output length mismatch");
  return output;
}
#endif

bool validUtf8(const std::string &s) {
  for (size_t i = 0; i < s.size();) {
    uint32_t c = static_cast<uint8_t>(s[i++]);
    unsigned n = 0;
    uint32_t min = 0;
    if (c < 128)
      continue;
    if (c >= 0xc2 && c <= 0xdf) {
      c &= 31; n = 1; min = 128;
    } else if (c >= 0xe0 && c <= 0xef) {
      c &= 15; n = 2; min = 2048;
    } else if (c >= 0xf0 && c <= 0xf4) {
      c &= 7; n = 3; min = 65536;
    } else {
      return false;
    }
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

constexpr char kBase64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
std::string base64(const Data &bytes) {
  std::string output;
  output.reserve((bytes.size() + 2) / 3 * 4);
  for (size_t i = 0; i < bytes.size(); i += 3) {
    uint32_t value = uint32_t(bytes[i]) << 16;
    if (i + 1 < bytes.size()) value |= uint32_t(bytes[i + 1]) << 8;
    if (i + 2 < bytes.size()) value |= bytes[i + 2];
    output += kBase64Alphabet[(value >> 18) & 63];
    output += kBase64Alphabet[(value >> 12) & 63];
    output += i + 1 < bytes.size() ? kBase64Alphabet[(value >> 6) & 63] : '=';
    output += i + 2 < bytes.size() ? kBase64Alphabet[value & 63] : '=';
  }
  return output;
}
Data unbase64(const std::string &input) {
  std::string text;
  for (char c : input) {
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
    text += c;
  }
  if (text.empty() || text.size() % 4)
    throw std::runtime_error("Base64 format");
  Data output;
  output.reserve(text.size() / 4 * 3);
  for (size_t i = 0; i < text.size(); i += 4) {
    uint32_t value = 0;
    unsigned padding = 0;
    for (size_t j = 0; j < 4; ++j) {
      char c = text[i + j];
      if (c == '=') {
        if (i + 4 != text.size() || j < 2)
          throw std::runtime_error("Base64 padding");
        ++padding;
        value <<= 6;
      } else {
        const char *p = std::strchr(kBase64Alphabet, c);
        if (!p || padding)
          throw std::runtime_error("Base64 character");
        value = (value << 6) | static_cast<uint32_t>(p - kBase64Alphabet);
      }
    }
    if (padding > 2 || (padding == 1 && (value & 255)) ||
        (padding == 2 && (value & 65535)))
      throw std::runtime_error("Base64 bits");
    output.push_back(static_cast<uint8_t>(value >> 16));
    if (padding < 2) output.push_back(static_cast<uint8_t>(value >> 8));
    if (!padding) output.push_back(static_cast<uint8_t>(value));
  }
  return output;
}
void passwordCheck(const std::string &password) {
  if (password.empty() || password.size() > 1024u * 1024u ||
      !validUtf8(password))
    throw std::runtime_error("password");
}
void put32le(Data &data, size_t offset, uint32_t value) {
  for (unsigned i = 0; i < 4; ++i)
    data[offset + i] = static_cast<uint8_t>(value >> (i * 8));
}
uint32_t get32le(const Data &data, size_t offset) {
  return uint32_t(data[offset]) | (uint32_t(data[offset + 1]) << 8) |
         (uint32_t(data[offset + 2]) << 16) |
         (uint32_t(data[offset + 3]) << 24);
}
Data makeAad(const Data &headerAndSalt) {
  Data aad;
  aad.reserve(kFormatPrefixLength + headerAndSalt.size());
  aad.insert(aad.end(), kFormatPrefix, kFormatPrefix + kFormatPrefixLength);
  aad.insert(aad.end(), headerAndSalt.begin(), headerAndSalt.end());
  return aad;
}
} // namespace

#ifdef XS_AES_TESTING
std::string aesEncrypt(const std::string &utf8, const std::string &password,
                       const uint8_t *fixedSalt16,
                       const uint8_t *fixedNonce12) {
#else
std::string aesEncrypt(const std::string &utf8, const std::string &password) {
  const uint8_t *fixedSalt16 = nullptr;
  const uint8_t *fixedNonce12 = nullptr;
#endif
  passwordCheck(password);
  if (utf8.size() > kMaxPlaintext || !validUtf8(utf8))
    throw std::runtime_error("plaintext");

  Data header(kHeaderLength, 0);
  header[0] = 'N'; header[1] = '2'; header[2] = 'G'; header[3] = '1';
  header[4] = 1; // AES-256-GCM
  header[5] = 1; // PBKDF2-HMAC-SHA256
  header[6] = static_cast<uint8_t>(kTagLength);
  header[7] = static_cast<uint8_t>(kSaltLength);
  header[8] = static_cast<uint8_t>(kNonceLength);
  header[9] = 0; // reserved flags
  put32le(header, 10, kPbkdf2Iterations);
  header[14] = 0; header[15] = 0;

  Data salt(kSaltLength), nonce(kNonceLength), tag(kTagLength);
  if (fixedSalt16) std::copy(fixedSalt16, fixedSalt16 + kSaltLength, salt.begin());
  else randomBytes(salt);
  if (fixedNonce12) std::copy(fixedNonce12, fixedNonce12 + kNonceLength, nonce.begin());
  else randomBytes(nonce);

  Data aadInput = header;
  aadInput.insert(aadInput.end(), salt.begin(), salt.end());
  Data aad = makeAad(aadInput);
  reportCryptoProgress(CryptoStage::Deriving);
  Data key = deriveKey(password, salt);
  Data plain(utf8.begin(), utf8.end());
  reportCryptoProgress(CryptoStage::Encrypting);
  Data encrypted = aesGcm(true, plain, key, nonce, aad, tag);

  Data wire;
  wire.reserve(header.size() + salt.size() + nonce.size() + encrypted.size() + tag.size());
  wire.insert(wire.end(), header.begin(), header.end());
  wire.insert(wire.end(), salt.begin(), salt.end());
  wire.insert(wire.end(), nonce.begin(), nonce.end());
  wire.insert(wire.end(), encrypted.begin(), encrypted.end());
  wire.insert(wire.end(), tag.begin(), tag.end());
  reportCryptoProgress(CryptoStage::Encoding);
  std::string output(kFormatPrefix, kFormatPrefixLength);
  output += base64(wire);
  return output;
}

std::string aesDecrypt(const std::string &input, const std::string &password) {
  passwordCheck(password);
  if (input.size() > 112000000 || input.size() < kFormatPrefixLength + 4 ||
      input.compare(0, kFormatPrefixLength, kFormatPrefix) != 0)
    throw std::runtime_error("Notepad2XS AES-GCM format");

  const std::string encoded = input.substr(kFormatPrefixLength);
  Data wire = unbase64(encoded);
  const size_t minimum = kHeaderLength + kSaltLength + kNonceLength + kTagLength;
  if (wire.size() < minimum || wire.size() > minimum + kMaxPlaintext)
    throw std::runtime_error("AES-GCM payload size");

  if (wire[0] != 'N' || wire[1] != '2' || wire[2] != 'G' || wire[3] != '1' ||
      wire[4] != 1 || wire[5] != 1 || wire[6] != kTagLength ||
      wire[7] != kSaltLength || wire[8] != kNonceLength || wire[9] != 0 ||
      get32le(wire, 10) != kPbkdf2Iterations || wire[14] != 0 || wire[15] != 0)
    throw std::runtime_error("Unsupported or invalid AES-GCM header");

  Data headerAndSalt(wire.begin(), wire.begin() +
      static_cast<std::ptrdiff_t>(kHeaderLength + kSaltLength));
  Data aad = makeAad(headerAndSalt);
  const size_t nonceOffset = kHeaderLength + kSaltLength;
  const size_t cipherOffset = nonceOffset + kNonceLength;
  const size_t tagOffset = wire.size() - kTagLength;
  Data salt(wire.begin() + static_cast<std::ptrdiff_t>(kHeaderLength),
            wire.begin() + static_cast<std::ptrdiff_t>(nonceOffset));
  Data nonce(wire.begin() + static_cast<std::ptrdiff_t>(nonceOffset),
             wire.begin() + static_cast<std::ptrdiff_t>(cipherOffset));
  Data ciphertext(wire.begin() + static_cast<std::ptrdiff_t>(cipherOffset),
                  wire.begin() + static_cast<std::ptrdiff_t>(tagOffset));
  Data tag(wire.begin() + static_cast<std::ptrdiff_t>(tagOffset), wire.end());
  reportCryptoProgress(CryptoStage::Deriving);
  Data key = deriveKey(password, salt);
  reportCryptoProgress(CryptoStage::Authenticating);
  Data plaintext = aesGcm(false, ciphertext, key, nonce, aad, tag);
  reportCryptoProgress(CryptoStage::Encoding);
  std::string output(plaintext.begin(), plaintext.end());
  if (!validUtf8(output)) {
    if (!output.empty()) scrub(&output[0], output.size());
    throw std::runtime_error("UTF8");
  }
  return output;
}
} // namespace xs
