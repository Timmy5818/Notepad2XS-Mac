// F5 執行選取的非 UI 核心：數學評估與答案格式（沿用 Windows 版 tinyexpr 與 MathSelection）
#pragma once
#include "MathSelection.h"
#include <optional>
#include <string>
#include <string_view>

// 與 Windows 版狀態列十進位格式相同：整數加千分位；小數取 2 位（地區預設），
// 若結果看不到 1～9 的數字（例如 0.001），改用 6 位
std::string N2FormatMathAnswer(double value);
// 用 tinyexpr（含原版前處理：去除 $、逗號轉小數點等）計算算式
std::optional<xs::MathEvaluation> N2EvaluateMath(std::string_view expression);
