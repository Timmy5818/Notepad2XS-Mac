#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

namespace xs::json {
constexpr std::size_t textLimit = 16u * 1024u * 1024u;
constexpr std::size_t depthLimit = 256;
enum class ErrorKind { syntax, limit };
struct Error {
  ErrorKind kind;
  std::size_t position;
};

// Mac 版：同一套規則同時用於 wchar_t 與 UTF-8（char）；非 ASCII 字元只會出現在字串內，原樣保留
template <class Ch>
std::basic_string<Ch> formatT(std::basic_string_view<Ch> input, bool pretty, std::basic_string_view<Ch> eol) {
  using View = std::basic_string_view<Ch>;
  using Str = std::basic_string<Ch>;
  class Formatter {
  public:
    Formatter(View source, bool expand, View newline)
      : source_(source), pretty_(expand), eol_(newline) {}

    Str run() {
      if (source_.size() > textLimit)
        throw Error{ErrorKind::limit, 0};
      result_.reserve(source_.size());
      value(0);
      whitespace();
      if (pos_ != source_.size())
        fail();
      if (source_.back() == Ch('\n') || source_.back() == Ch('\r'))
        append(eol_);
      return std::move(result_);
    }

  private:
    View source_;
    bool pretty_;
    View eol_;
    Str result_;
    std::size_t pos_ = 0;

    [[noreturn]] void fail() const { throw Error{ErrorKind::syntax, pos_}; }

    // 以無號值比較：UTF-8 的多位元組字元（0x80 以上）不能被當成控制字元
    unsigned long peek() const {
      return pos_ < source_.size() ? static_cast<unsigned long>(static_cast<std::make_unsigned_t<Ch>>(source_[pos_])) : 0;
    }

    bool take(unsigned long ch) {
      if (peek() != ch)
        return false;
      ++pos_;
      return true;
    }

    void whitespace() {
      while (peek() == ' ' || peek() == '\t' || peek() == '\r' || peek() == '\n')
        ++pos_;
    }

    void reserveFor(std::size_t size) const {
      if (size > textLimit - result_.size())
        throw Error{ErrorKind::limit, pos_};
    }

    void append(View text) {
      reserveFor(text.size());
      result_.append(text);
    }

    void emit(unsigned long ch) {
      reserveFor(1);
      result_.push_back(static_cast<Ch>(ch));
    }

    void line(std::size_t depth) {
      if (!pretty_)
        return;
      append(eol_);
      reserveFor(depth * 2);
      result_.append(depth * 2, Ch(' '));
    }

    void expect(unsigned long ch) {
      if (!take(ch))
        fail();
      emit(ch);
    }

    static bool digit(unsigned long ch) { return ch >= '0' && ch <= '9'; }

    static bool hex(unsigned long ch) {
      return digit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    }

    void string() {
      const std::size_t start = pos_++;
      while (!take('"')) {
        if (peek() < 0x20)
          fail();
        if (!take('\\')) {
          ++pos_;
          continue;
        }
        switch (peek()) {
        case '"': case '\\': case '/': case 'b': case 'f':
        case 'n': case 'r': case 't':
          ++pos_;
          break;
        case 'u':
          ++pos_;
          for (int i = 0; i < 4; ++i) {
            if (!hex(peek()))
              fail();
            ++pos_;
          }
          break;
        default:
          fail();
        }
      }
      append(source_.substr(start, pos_ - start));
    }

    void digits() {
      if (!digit(peek()))
        fail();
      while (digit(peek()))
        ++pos_;
    }

    void number() {
      const std::size_t start = pos_;
      take('-');
      if (!take('0'))
        digits();
      if (take('.'))
        digits();
      if (take('e') || take('E')) {
        if (!take('+'))
          take('-');
        digits();
      }
      append(source_.substr(start, pos_ - start));
    }

    void literal(const char *word) {
      for (const char *p = word; *p; ++p) {
        if (!take(static_cast<unsigned char>(*p)))
          fail();
      }
      for (const char *p = word; *p; ++p)
        emit(static_cast<unsigned char>(*p));
    }

    void container(std::size_t depth, bool object) {
      if (depth == depthLimit)
        throw Error{ErrorKind::limit, pos_};
      const unsigned long end = object ? '}' : ']';
      emit(peek());
      ++pos_;
      whitespace();
      if (take(end)) {
        emit(end);
        return;
      }
      do {
        line(depth + 1);
        whitespace();
        if (object) {
          if (peek() != '"')
            fail();
          string();
          whitespace();
          expect(':');
          if (pretty_)
            emit(' ');
        }
        value(depth + 1);
        whitespace();
        if (!take(','))
          break;
        emit(',');
      } while (true);
      line(depth);
      expect(end);
    }

    void value(std::size_t depth) {
      whitespace();
      switch (peek()) {
      case '{': container(depth, true); break;
      case '[': container(depth, false); break;
      case '"': string(); break;
      case 't': literal("true"); break;
      case 'f': literal("false"); break;
      case 'n': literal("null"); break;
      default: number(); break;
      }
    }
  };

  return Formatter(input, pretty, eol).run();
}

inline std::wstring format(std::wstring_view input, bool pretty, std::wstring_view eol) {
  return formatT<wchar_t>(input, pretty, eol);
}
inline std::string formatUtf8(std::string_view input, bool pretty, std::string_view eol) {
  return formatT<char>(input, pretty, eol);
}
}
