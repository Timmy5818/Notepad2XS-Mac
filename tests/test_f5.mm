// F5 執行選取核心測試（原版 ChineseMoney／MathSelection／SqlSelection＋Mac 數學格式）
#import <Foundation/Foundation.h>
#include "ChineseMoney.h"
#include "SqlSelection.h"
#include "ExecuteCore.h"
static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fails++; printf("✗ %s\n", msg); } else printf("✓ %s\n", msg); } while (0)
static std::string W2U(const std::wstring &w) { return [[NSString alloc] initWithBytes:w.data() length:w.size() * 4 encoding:NSUTF32LittleEndianStringEncoding].UTF8String; }

static std::string RunMath(const std::string &block) {
    xs::MathVariableContext ctx;
    std::string out, line;
    size_t pos = 0;
    while (pos <= block.size()) {
        size_t nl = block.find('\n', pos);
        if (nl == std::string::npos) nl = block.size();
        line = block.substr(pos, nl - pos);
        auto r = xs::evaluateMathBlockLine(line, 0, ctx, N2EvaluateMath);
        if (r.state == xs::MathBlockLineState::Error) return "ERROR";
        if (r.edit) line = line.substr(0, r.edit->start) + r.edit->replacement + line.substr(r.edit->end);
        out += line;
        if (nl < block.size()) out += "\n";
        pos = nl + 1;
    }
    return out;
}

int main() {
    @autoreleasepool {
        struct { const wchar_t *in, *common, *financial; } money[] = {
            {L"200", L"二百元整", L"貳佰元整"}, {L"1,500", L"一千五百元整", L"壹仟伍佰元整"},
            {L"36000", L"三萬六千元整", L"參萬陸仟元整"}, {L"10", L"十元整", L"壹拾元整"},
            {L"100010001", L"一億零一萬零一元整", L"壹億零壹萬零壹元整"}, {L"200.50", L"二百元五角", L"貳佰元伍角"},
            {L"200.05", L"二百元零五分", L"貳佰元零伍分"}, {L"0.05", L"零元五分", L"零元伍分"},
            {L"-12.34", L"負十二元三角四分", L"負壹拾貳元參角肆分"}, {L"-0.00", L"零元整", L"零元整"},
        };
        bool ok = true;
        for (auto &m : money) {
            auto c = xs::convertMoney(m.in, xs::MoneyStyle::common), f = xs::convertMoney(m.in, xs::MoneyStyle::financial);
            if (c.text != m.common || f.text != m.financial) { ok = false; printf("  %s → %s / %s\n", W2U(m.in).c_str(), W2U(c.text).c_str(), W2U(f.text).c_str()); }
        }
        CHECK(ok, "中文金額：原版說明文件的 10 組範例（一般＋大寫）");
        auto mixed = xs::convertMoney(L" 200\r\n文字\n1,500", xs::MoneyStyle::common);
        CHECK(mixed.text == L" 二百元整\r\n文字\n一千五百元整" && mixed.skipped == 1, "中文金額：保留空白與換行、略過無效行");

        CHECK(N2FormatMathAnswer(1234) == "1,234" && N2FormatMathAnswer(10.0 / 3) == "3.33" && N2FormatMathAnswer(0.001) == "0.001000",
              "數學答案格式（整數千分位、小數 2 位、太小改 6 位）");
        CHECK(RunMath("1+2=") == "1+2=3", "數學：單行算式");
        CHECK(RunMath("a=1\nb=3\na+b=") == "a=1\nb=3\na+b=4", "數學：多行變數區塊");
        CHECK(RunMath("1+2=3") == "1+2=3" && RunMath("2*3=999") == "2*3=6", "數學：重複按 F5 只更新答案");
        CHECK(RunMath("x+1=") == "ERROR", "數學：未宣告變數回報錯誤");
        CHECK(RunMath("sqrt(16)=") == "sqrt(16)=4", "數學：函數");

        auto sql = xs::parseSqlSelection(u"[DB:測試資料庫]\nSELECT *\nFROM t;");
        CHECK(sql.dsn == u"測試資料庫" && sql.statement.find(u"SELECT") == 0, "SQL：解析 [DB:DSN] 與敘述");
        CHECK(xs::sqlNeedsWhereConfirmation(u"UPDATE t SET a=1") && xs::sqlNeedsWhereConfirmation(u"DELETE FROM t;") &&
              !xs::sqlNeedsWhereConfirmation(u"UPDATE t SET a=1 WHERE id=2") && !xs::sqlNeedsWhereConfirmation(u"SELECT * FROM t"),
              "SQL：缺少 WHERE 的 UPDATE／DELETE 警告");
        CHECK(xs::selectedUrl(u"  https://example.com/a?x=1&y=2\n") == u"https://example.com/a?x=1&y=2" && xs::selectedUrl(u"hello").empty(),
              "網址辨識");
        auto ssh = xs::selectedSshUrl(u"ssh://alice:pw@example.com:2222/home/alice/project/");
        CHECK(ssh && ssh->username == u"alice" && ssh->port == 2222 && ssh->passwordProvided && ssh->remoteDirectory == u"/home/alice/project/",
              "SSH URI 辨識（密碼不保留）");
        auto ftp = xs::selectedFtpUrl(u"ftp://user:secret@example.com/pub/");
        CHECK(ftp && ftp->passwordProvided && ftp->url.find(u"secret") == std::u16string::npos, "FTP URI 辨識並移除密碼");
        CHECK(xs::selectedDosBatch(u"[DOSCMD]\necho hi").has_value() && !xs::selectedDosBatch(u"echo hi").has_value(), "腳本標記辨識");
        printf("\n%s（失敗 %d 項）\n", fails ? "有測試失敗" : "全部通過", fails);
    }
    return fails ? 1 : 0;
}
