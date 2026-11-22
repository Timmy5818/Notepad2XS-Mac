#import <Foundation/Foundation.h>
#include "ExecuteCore.h"
#include <cmath>
#include <vector>
extern "C" {
#include "tinyexpr.h"
}

static std::string Format(double value, NSUInteger digits) {
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.locale = NSLocale.currentLocale;
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.usesGroupingSeparator = YES;
    f.minimumFractionDigits = digits;
    f.maximumFractionDigits = digits;
    f.roundingMode = NSNumberFormatterRoundHalfUp;
    NSString *s = [f stringFromNumber:@(value)];
    return s ? std::string(s.UTF8String) : std::string();
}

std::string N2FormatMathAnswer(double value) {
    if (std::floor(value) == value) return Format(value, 0);
    std::string s = Format(value, 2);
    if (s.find_first_of("123456789") == std::string::npos) s = Format(value, 6);
    return s;
}

std::optional<xs::MathEvaluation> N2EvaluateMath(std::string_view expression) {
    if (expression.empty() || expression.size() >= 4096) return std::nullopt;
    std::vector<unsigned char> buf(expression.begin(), expression.end());
    buf.push_back(0);
    double v = 0;
    if (!is_valid_expression(buf.data(), 1, &v)) return std::nullopt;
    xs::MathEvaluation e;
    e.numericValue = v;
    e.formattedAnswer = N2FormatMathAnswer(v);
    return e;
}
