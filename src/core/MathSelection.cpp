#include "MathSelection.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iterator>
#include <locale>
#include <limits>
#include <sstream>
#include <utility>

namespace xs {
namespace {
bool lineSpace(char c) { return c == ' ' || c == '\t'; }

std::size_t utf8SpaceLength(std::string_view text, std::size_t position) {
  if (position >= text.size()) return 0;
  const auto c = static_cast<unsigned char>(text[position]);
  if (c == ' ' || c == '\t') return 1;
  if (position + 1 < text.size() && c == 0xc2 &&
      static_cast<unsigned char>(text[position + 1]) == 0xa0)
    return 2; // NO-BREAK SPACE
  if (position + 2 < text.size()) {
    const auto b = static_cast<unsigned char>(text[position + 1]);
    const auto d = static_cast<unsigned char>(text[position + 2]);
    if (c == 0xe3 && b == 0x80 && d == 0x80) return 3; // IDEOGRAPHIC SPACE
    if ((c == 0xe2 && b == 0x80 &&
         ((d >= 0x80 && d <= 0x8a) || d == 0xaf)) ||
        (c == 0xe2 && b == 0x81 && d == 0x9f))
      return 3; // Unicode spacing characters commonly used in documents
  }
  return 0;
}

std::size_t previousUtf8SpaceStart(std::string_view text, std::size_t end) {
  if (!end) return end;
  if (lineSpace(text[end - 1])) return end - 1;
  const std::size_t begin = end >= 3 ? end - 3 : 0;
  for (std::size_t i = begin; i < end; ++i) {
    if (utf8SpaceLength(text, i) == end - i) return i;
  }
  if (end >= 2 && utf8SpaceLength(text, end - 2) == 2) return end - 2;
  return end;
}

bool formattedAnswer(std::string_view text) {
  if (text.empty()) return false;
  bool hasDigit = false;
  bool hasHexSuffix = false;
  bool hasNegativeSign = false;
  std::size_t first = 0;
  while (first < text.size() && lineSpace(text[first])) ++first;
  std::size_t last = text.size();
  while (last > first && lineSpace(text[last - 1])) --last;
  const bool parenthesized = last - first >= 2 && text[first] == '(' &&
                             text[last - 1] == ')';
  for (std::size_t i = 0; i < text.size(); ++i) {
    const auto c = static_cast<unsigned char>(text[i]);
    if (c >= '0' && c <= '9') {
      hasDigit = true;
      continue;
    }
    if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') ||
        c == 'x' || c == 'X' || c == 'h' || c == 'H' ||
        c == 'o' || c == 'O' || c == 'b' || c == 'B' ||
        c == 'i' || c == 'I' || c == 'n' || c == 'N' ||
        c == 'q' || c == 'Q' || c == 's' || c == 'S') {
      if (c == 'h' || c == 'H' || c == 'o' || c == 'O' || c == 'b' || c == 'B')
        hasHexSuffix = true;
      continue;
    }
    if (c == '.' || c == ',' || c == '\'' || c == '_' || c == '#' ||
        lineSpace(static_cast<char>(c)))
      continue;
    if ((c == '(' && parenthesized && i == first) ||
        (c == ')' && parenthesized && i + 1 == last))
      continue;
    if (c == '-' && !hasNegativeSign && (i == first || i + 1 == last)) {
      hasNegativeSign = true;
      continue;
    }
    // Locale-specific grouping separators can be UTF-8 bytes. They are
    // accepted, but visible ASCII operators and arbitrary words are not.
    if (c >= 0x80) continue;
    return false;
  }
  return hasDigit || hasHexSuffix;
}

bool identifierStart(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

bool identifierPart(char c) {
  return identifierStart(c) || (c >= '0' && c <= '9');
}

bool validIdentifier(std::string_view value) {
  if (value.empty() || !identifierStart(value.front())) return false;
  return std::all_of(value.begin() + 1, value.end(), identifierPart);
}

bool allHexDigits(std::string_view value) {
  if (value.empty()) return false;
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
  });
}

bool numericSuffixToken(std::string_view token) {
  // Keep hexadecimal/binary/octal postfix literals intact (FFh, 101b, 17o).
  if (token.size() <= 1) return false;
  const char suffix = token.back();
  const auto digits = token.substr(0, token.size() - 1);
  if ((suffix == 'h' || suffix == 'H') && allHexDigits(digits)) return true;
  if ((suffix == 'b' || suffix == 'B') &&
      std::all_of(digits.begin(), digits.end(), [](char c) { return c == '0' || c == '1'; }))
    return true;
  if ((suffix == 'o' || suffix == 'O') &&
      std::all_of(digits.begin(), digits.end(), [](char c) { return c >= '0' && c <= '7'; }))
    return true;
  return false;
}

bool builtinFunction(std::string_view name) {
  static constexpr std::string_view names[] = {
      "abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "cosh",
      "exp", "floor", "ln", "log", "not", "pow", "sin", "sinh",
      "sqrt", "tan", "tanh"};
  return std::find(std::begin(names), std::end(names), name) != std::end(names);
}

bool builtinConstant(std::string_view name) {
  return name == "e" || name == "pi";
}

bool builtinWordOperator(std::string_view name) {
  static constexpr std::string_view names[] = {
      "and", "or", "xor", "div", "mod", "shl", "shr"};
  return std::find(std::begin(names), std::end(names), name) != std::end(names);
}

bool expressionLooksMathematical(std::string_view expression) {
  for (char c : expression) {
    if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '*' ||
        c == '/' || c == '%' || c == '^' || c == '(' || c == ')' ||
        c == '&' || c == '|' || c == '~')
      return true;
  }
  std::size_t cursor = 0;
  while (cursor < expression.size()) {
    if (!identifierStart(expression[cursor])) {
      ++cursor;
      continue;
    }
    const auto begin = cursor++;
    while (cursor < expression.size() && identifierPart(expression[cursor])) ++cursor;
    const auto token = expression.substr(begin, cursor - begin);
    if (numericSuffixToken(token) || builtinConstant(token) || builtinWordOperator(token)) return true;
    std::size_t afterToken = cursor;
    while (afterToken < expression.size() && lineSpace(expression[afterToken])) ++afterToken;
    if (afterToken < expression.size() && expression[afterToken] == '(' &&
        builtinFunction(token))
      return true;
  }
  return false;
}

std::optional<std::string> expandVariables(
    std::string_view expression, const MathVariableContext &context,
    std::string &unknownVariable) {
  std::string expanded;
  expanded.reserve(expression.size() + 32);
  for (std::size_t cursor = 0; cursor < expression.size();) {
    if (!identifierStart(expression[cursor])) {
      expanded.push_back(expression[cursor++]);
      continue;
    }

    // Don't treat the x/b/o/d/e marker inside legacy numeric literals as a
    // variable token (for example 0x10 or 3e-4).
    if (cursor > 0 &&
        ((expression[cursor - 1] >= '0' && expression[cursor - 1] <= '9') ||
         expression[cursor - 1] == '.')) {
      const auto begin = cursor++;
      while (cursor < expression.size() && identifierPart(expression[cursor])) ++cursor;
      // Preserve radix prefixes and scientific-notation markers as part of
      // the numeric token; implicit multiplication is not part of the legacy
      // expression grammar, so this token must not be resolved as a variable.
      expanded.append(expression.substr(begin, cursor - begin));
      continue;
    }

    const auto begin = cursor++;
    while (cursor < expression.size() && identifierPart(expression[cursor])) ++cursor;
    const auto token = expression.substr(begin, cursor - begin);
    if (numericSuffixToken(token)) {
      expanded.append(token);
      continue;
    }

    std::size_t afterToken = cursor;
    while (afterToken < expression.size() && lineSpace(expression[afterToken])) ++afterToken;
    const bool functionCall = afterToken < expression.size() && expression[afterToken] == '(';
    if (functionCall && builtinFunction(token)) {
      expanded.append(token);
      continue;
    }

    const auto found = context.variables.find(std::string(token));
    if (found != context.variables.end()) {
      if (!std::isfinite(found->second)) {
        unknownVariable.assign(token);
        return std::nullopt;
      }
      std::ostringstream number;
      number.imbue(std::locale::classic());
      number << std::setprecision((std::numeric_limits<double>::max_digits10))
             << found->second;
      // Parenthesize every substituted value so negative variables preserve
      // the source expression's operator precedence (for example a^2).
      expanded.push_back('(');
      expanded += number.str();
      expanded.push_back(')');
      continue;
    }

    // Zero-argument constants and word operators are resolved by tinyexpr.
    if (builtinConstant(token) || builtinWordOperator(token)) {
      expanded.append(token);
      continue;
    }

    unknownVariable.assign(token);
    return std::nullopt;
  }
  return expanded;
}

MathBlockLineResult blockError(MathBlockLineError error, std::string identifier = {}) {
  MathBlockLineResult result;
  result.state = MathBlockLineState::Error;
  result.error = error;
  result.identifier = std::move(identifier);
  return result;
}

} // namespace

std::optional<MathLineEdit> evaluateMathLine(
    std::string_view line, std::size_t documentOffset,
    const MathEvaluator &evaluate, std::size_t maximumExpressionBytes) {
  if (!evaluate || line.empty() || line.find('\0') != std::string_view::npos)
    return std::nullopt;

  std::size_t expressionStart = 0;
  // Scintilla may expose a UTF-8 BOM as the first document character. Treat
  // it as a preserved prefix, just like indentation.
  if (line.size() >= 3 &&
      static_cast<unsigned char>(line[0]) == 0xef &&
      static_cast<unsigned char>(line[1]) == 0xbb &&
      static_cast<unsigned char>(line[2]) == 0xbf)
    expressionStart = 3;
  while (expressionStart < line.size()) {
    const auto whitespace = utf8SpaceLength(line, expressionStart);
    if (!whitespace) break;
    expressionStart += whitespace;
  }

  std::size_t contentEnd = line.size();
  for (;;) {
    const auto whitespaceStart = previousUtf8SpaceStart(line, contentEnd);
    if (whitespaceStart == contentEnd) break;
    contentEnd = whitespaceStart;
  }
  if (contentEnd <= expressionStart ||
      contentEnd - expressionStart > maximumExpressionBytes)
    return std::nullopt;

  std::size_t equals = std::string_view::npos;
  for (std::size_t i = expressionStart; i < contentEnd; ++i) {
    if (line[i] != '=') continue;
    if (equals != std::string_view::npos) return std::nullopt;
    equals = i;
  }

  std::size_t expressionEnd = contentEnd;
  std::size_t replaceStart = contentEnd;
  if (equals != std::string_view::npos) {
    // Equality/comparison or incomplete assignments are not result suffixes.
    if ((equals > 0 && line[equals - 1] == '=') ||
        (equals + 1 < contentEnd && line[equals + 1] == '='))
      return std::nullopt;
    expressionEnd = equals;
    for (;;) {
      const auto whitespaceStart = previousUtf8SpaceStart(line, expressionEnd);
      if (whitespaceStart == expressionEnd) break;
      expressionEnd = whitespaceStart;
    }
    const auto existingAnswer =
        line.substr(equals + 1, contentEnd - equals - 1);
    // A trailing '=' is an intentional empty result slot (for example
    // "1+1="). Re-evaluate it just like an existing "=answer" suffix.
    // Non-empty suffixes still have to match the status-bar answer format so
    // ordinary equality/comparison expressions are not mistaken for results.
    if (expressionEnd <= expressionStart ||
        (!existingAnswer.empty() && !formattedAnswer(existingAnswer)))
      return std::nullopt;
    replaceStart = equals;
  }

  if (expressionEnd - expressionStart > maximumExpressionBytes)
    return std::nullopt;
  const auto answer = evaluate(line.substr(expressionStart,
                                            expressionEnd - expressionStart));
  if (!answer || answer->empty() || answer->find('\0') != std::string::npos)
    return std::nullopt;

  MathLineEdit edit;
  edit.start = documentOffset + replaceStart;
  edit.end = documentOffset + contentEnd;
  edit.replacement.reserve(answer->size() + 1);
  edit.replacement.push_back('=');
  edit.replacement += *answer;
  return edit;
}

MathBlockLineResult evaluateMathBlockLine(
    std::string_view line, std::size_t documentOffset,
    MathVariableContext &context,
    const MathExpressionEvaluator &evaluate,
    std::size_t maximumExpressionBytes) {
  if (!evaluate || line.empty() || line.find('\0') != std::string_view::npos)
    return {};

  std::size_t expressionStart = 0;
  if (line.size() >= 3 &&
      static_cast<unsigned char>(line[0]) == 0xef &&
      static_cast<unsigned char>(line[1]) == 0xbb &&
      static_cast<unsigned char>(line[2]) == 0xbf)
    expressionStart = 3;
  while (expressionStart < line.size()) {
    const auto whitespace = utf8SpaceLength(line, expressionStart);
    if (!whitespace) break;
    expressionStart += whitespace;
  }

  std::size_t contentEnd = line.size();
  for (;;) {
    const auto whitespaceStart = previousUtf8SpaceStart(line, contentEnd);
    if (whitespaceStart == contentEnd) break;
    contentEnd = whitespaceStart;
  }
  if (contentEnd <= expressionStart ||
      contentEnd - expressionStart > maximumExpressionBytes)
    return {};

  std::size_t equals = std::string_view::npos;
  for (std::size_t i = expressionStart; i < contentEnd; ++i) {
    if (line[i] != '=') continue;
    if (equals != std::string_view::npos) return {};
    equals = i;
  }
  if (equals != std::string_view::npos &&
      ((equals > expressionStart && line[equals - 1] == '=') ||
       (equals + 1 < contentEnd && line[equals + 1] == '=')))
    return {};

  // A simple identifier on the left side denotes a variable assignment.
  if (equals != std::string_view::npos) {
    std::size_t nameStart = expressionStart;
    while (nameStart < equals && lineSpace(line[nameStart])) ++nameStart;
    std::size_t nameEnd = equals;
    while (nameEnd > nameStart && lineSpace(line[nameEnd - 1])) --nameEnd;
    const auto name = line.substr(nameStart, nameEnd - nameStart);
    if (validIdentifier(name) && !numericSuffixToken(name)) {
      std::size_t valueStart = equals + 1;
      while (valueStart < contentEnd && lineSpace(line[valueStart])) ++valueStart;
      if (valueStart >= contentEnd) {
        // `a=` is also a convenient way to request the current value of an
        // already defined variable. An undeclared left-hand name remains an
        // incomplete assignment and is reported instead of being ignored.
        if (context.variables.find(std::string(name)) == context.variables.end() &&
            !builtinConstant(name))
          return blockError(MathBlockLineError::InvalidAssignment, std::string(name));
      } else {
        const auto expression = line.substr(valueStart, contentEnd - valueStart);
        if (expression.size() > maximumExpressionBytes)
          return blockError(MathBlockLineError::InvalidExpression, std::string(name));
        if (!expressionLooksMathematical(expression)) {
          std::size_t rhsStart = 0;
          while (rhsStart < expression.size() && lineSpace(expression[rhsStart])) ++rhsStart;
          std::size_t rhsEnd = expression.size();
          while (rhsEnd > rhsStart && lineSpace(expression[rhsEnd - 1])) --rhsEnd;
          const auto rhsName = expression.substr(rhsStart, rhsEnd - rhsStart);
          if (!validIdentifier(rhsName) ||
              context.variables.find(std::string(rhsName)) == context.variables.end())
            return {};
        }
        std::string unknown;
        const auto expanded = expandVariables(expression, context, unknown);
        if (!expanded)
          return blockError(MathBlockLineError::UnknownVariable, std::move(unknown));
        const auto value = evaluate(*expanded);
        if (!value || !std::isfinite(value->numericValue) || value->formattedAnswer.empty())
          return blockError(MathBlockLineError::InvalidExpression, std::string(name));
        context.variables[std::string(name)] = value->numericValue;
        MathBlockLineResult result;
        result.state = MathBlockLineState::Assignment;
        result.identifier.assign(name);
        return result;
      }
    }
  }

  std::size_t expressionEnd = contentEnd;
  std::size_t replaceStart = contentEnd;
  if (equals != std::string_view::npos) {
    expressionEnd = equals;
    for (;;) {
      const auto whitespaceStart = previousUtf8SpaceStart(line, expressionEnd);
      if (whitespaceStart == expressionEnd) break;
      expressionEnd = whitespaceStart;
    }
    const auto existingAnswer = line.substr(equals + 1, contentEnd - equals - 1);
    if (!existingAnswer.empty() && !formattedAnswer(existingAnswer)) return {};
    replaceStart = equals;
  }
  if (expressionEnd <= expressionStart ||
      expressionEnd - expressionStart > maximumExpressionBytes)
    return {};

  const auto expression = line.substr(expressionStart, expressionEnd - expressionStart);
  const bool knownVariable = validIdentifier(expression) &&
      context.variables.find(std::string(expression)) != context.variables.end();
  if (!expressionLooksMathematical(expression) && !knownVariable) return {};
  std::string unknown;
  const auto expanded = expandVariables(expression, context, unknown);
  if (!expanded)
    return blockError(MathBlockLineError::UnknownVariable, std::move(unknown));
  const auto value = evaluate(*expanded);
  if (!value || value->formattedAnswer.empty())
    return blockError(MathBlockLineError::InvalidExpression);

  MathBlockLineResult result;
  result.state = MathBlockLineState::Result;
  MathLineEdit edit;
  edit.start = documentOffset + replaceStart;
  edit.end = documentOffset + contentEnd;
  edit.replacement.reserve(value->formattedAnswer.size() + 1);
  edit.replacement.push_back('=');
  edit.replacement += value->formattedAnswer;
  result.edit = std::move(edit);
  return result;
}

} // namespace xs
