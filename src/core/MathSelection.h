#pragma once

#include <cstddef>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace xs {

// A replacement is expressed in byte offsets relative to the Scintilla
// document. The inserted text is the exact status-bar-formatted answer,
// prefixed by '='; the source expression and indentation are not replaced.
struct MathLineEdit {
  std::size_t start = 0;
  std::size_t end = 0;
  std::string replacement;
};

using MathEvaluator =
    std::function<std::optional<std::string>(std::string_view expression)>;

// The block evaluator returns both the status-bar-formatted answer and the
// raw numeric value used by subsequent variable references.
struct MathEvaluation {
  double numericValue = 0.0;
  std::string formattedAnswer;
};

using MathExpressionEvaluator =
    std::function<std::optional<MathEvaluation>(std::string_view expression)>;

// Variables are private to one F5 operation and are evaluated top-to-bottom.
// A fresh context must be created for every selection/current-line operation.
struct MathVariableContext {
  std::map<std::string, double> variables;
};

enum class MathBlockLineState {
  Ignored,
  Assignment,
  Result,
  Error
};

enum class MathBlockLineError {
  None,
  InvalidAssignment,
  UnknownVariable,
  InvalidExpression
};

struct MathBlockLineResult {
  MathBlockLineState state = MathBlockLineState::Ignored;
  MathBlockLineError error = MathBlockLineError::None;
  std::string identifier;
  std::optional<MathLineEdit> edit;
};

// Evaluates one physical line in a block-local variable environment.
// `name = expression` assigns/updates a variable without changing the line.
// Other expressions are evaluated and receive/refresh an '=answer' suffix.
MathBlockLineResult evaluateMathBlockLine(
    std::string_view line, std::size_t documentOffset,
    MathVariableContext &context,
    const MathExpressionEvaluator &evaluate,
    std::size_t maximumExpressionBytes = 4096);

// Legacy single-line helper retained for existing integrations and tests.
std::optional<MathLineEdit> evaluateMathLine(
    std::string_view line, std::size_t documentOffset,
    const MathEvaluator &evaluate,
    std::size_t maximumExpressionBytes = 4096);

} // namespace xs
