#import "SyntaxStyles.h"
#import "ScintillaView.h"
#include "SciLexer.h"
#include <vector>

// Scintilla 的顏色是 0xBBGGRR
static constexpr long RGB(int r, int g, int b) { return r | (g << 8) | (b << 16); }

static const long kComment   = RGB(0x00, 0x80, 0x00);
static const long kKeyword   = RGB(0x00, 0x00, 0xFF);
static const long kKeyword2  = RGB(0x26, 0x7F, 0x99);
static const long kString    = RGB(0xA3, 0x15, 0x15);
static const long kNumber    = RGB(0xC8, 0x50, 0x00);
static const long kPreproc   = RGB(0x80, 0x40, 0x80);
static const long kOperator  = RGB(0x40, 0x40, 0x40);
static const long kTag       = RGB(0x80, 0x00, 0x00);
static const long kAttr      = RGB(0xE5, 0x00, 0x00);
static const long kHeading   = RGB(0x00, 0x00, 0x80);

struct LangInfo {
    NSString *langID;
    NSString *name;
    const char *lexer;
    NSArray<NSString *> *extensions;
};

static const std::vector<LangInfo> &Languages() {
    static std::vector<LangInfo> langs = {
        { @"text",     @"純文字",        nullptr,      @[@"txt", @"log"] },
        { @"c",        @"C / C++",       "cpp",        @[@"c", @"h", @"cpp", @"cxx", @"cc", @"hpp", @"hxx", @"hh", @"inl"] },
        { @"objc",     @"Objective-C",   "cpp",        @[@"m", @"mm"] },
        { @"java",     @"Java",          "cpp",        @[@"java"] },
        { @"kotlin",   @"Kotlin",        "cpp",        @[@"kt", @"kts"] },
        { @"csharp",   @"C#",            "cpp",        @[@"cs"] },
        { @"js",       @"JavaScript",    "cpp",        @[@"js", @"mjs", @"cjs", @"jsx"] },
        { @"ts",       @"TypeScript",    "cpp",        @[@"ts", @"tsx"] },
        { @"swift",    @"Swift",         "cpp",        @[@"swift"] },
        { @"json",     @"JSON",          "json",       @[@"json", @"jsonc"] },
        { @"python",   @"Python",        "python",     @[@"py", @"pyw"] },
        { @"php",      @"PHP",           "hypertext",  @[@"php", @"phtml"] },
        { @"html",     @"HTML",          "hypertext",  @[@"html", @"htm", @"xhtml", @"vue"] },
        { @"xml",      @"XML",           "xml",        @[@"xml", @"plist", @"xsd", @"xsl", @"svg", @"csproj", @"vcxproj", @"props", @"targets", @"resx"] },
        { @"css",      @"CSS",           "css",        @[@"css", @"scss", @"less"] },
        { @"sql",      @"SQL",           "sql",        @[@"sql"] },
        { @"bash",     @"Shell",         "bash",       @[@"sh", @"bash", @"zsh", @"command"] },
        { @"batch",    @"Batch",         "batch",      @[@"bat", @"cmd"] },
        { @"ini",      @"INI / 設定檔",   "props",      @[@"ini", @"inf", @"cfg", @"conf", @"properties", @"reg"] },
        { @"markdown", @"Markdown",      "markdown",   @[@"md", @"markdown"] },
        { @"makefile", @"Makefile",      "makefile",   @[@"mak", @"mk"] },
        { @"diff",     @"Diff",          "diff",       @[@"diff", @"patch"] },
    };
    return langs;
}

static const LangInfo *Find(NSString *langID) {
    for (const auto &l : Languages()) if ([l.langID isEqualToString:langID]) return &l;
    return &Languages()[0];
}

NSArray<NSString *> *N2SyntaxLanguageIDs(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (const auto &l : Languages()) [a addObject:l.langID];
    return a;
}

NSString *N2SyntaxDisplayName(NSString *langID) { return Find(langID)->name; }

NSString *N2SyntaxLanguageForFileName(NSString *fileName) {
    if (fileName.length == 0) return @"text";
    NSString *base = fileName.lastPathComponent.lowercaseString;
    if ([base isEqualToString:@"makefile"] || [base isEqualToString:@"gnumakefile"]) return @"makefile";
    if ([base hasPrefix:@".bash"] || [base hasPrefix:@".zsh"] || [base isEqualToString:@".profile"]) return @"bash";
    if ([base isEqualToString:@".gitconfig"] || [base isEqualToString:@".editorconfig"]) return @"ini";
    NSString *ext = base.pathExtension;
    if (ext.length == 0) return @"text";
    for (const auto &l : Languages()) if ([l.extensions containsObject:ext]) return l.langID;
    return @"text";
}

// ---- 關鍵字 ----
static const char *kCKeywords =
    "alignas alignof asm auto bool break case catch char char8_t char16_t char32_t class const constexpr consteval constinit "
    "const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit export "
    "extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator private protected "
    "public register reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this "
    "thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while "
    "size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t NULL";
static const char *kObjCKeywords =
    "@interface @implementation @end @protocol @property @synthesize @dynamic @class @selector @encode @try @catch @finally "
    "@throw @autoreleasepool @optional @required @import self super nil Nil YES NO id instancetype SEL BOOL IMP "
    "nonatomic atomic strong weak copy assign retain readonly readwrite nullable nonnull";
static const char *kJavaKeywords =
    "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally "
    "float for goto if implements import instanceof int interface long native new package private protected public return short "
    "static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record "
    "sealed permits yield";
static const char *kKotlinKeywords =
    "as as? break class continue do else false for fun if in !in interface is !is null object package return super this throw "
    "true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param "
    "property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final "
    "infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend "
    "tailrec vararg";
static const char *kCSharpKeywords =
    "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum "
    "event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace "
    "new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc "
    "static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while "
    "var async await dynamic get set value yield record init";
static const char *kJSKeywords =
    "async await break case catch class const continue debugger default delete do else export extends false finally for from "
    "function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined "
    "var void while with yield";
static const char *kTSKeywords =
    "abstract any as asserts bigint boolean declare enum implements infer interface is keyof module namespace never number "
    "object private protected public readonly require string symbol type unique unknown";
static const char *kSwiftKeywords =
    "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol "
    "public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in "
    "repeat return switch where while as Any catch false is nil super self Self throw throws true try async await actor some";
static const char *kPythonKeywords =
    "False None True and as assert async await break class continue def del elif else except finally for from global if import "
    "in is lambda nonlocal not or pass raise return try while with yield match case";
static const char *kPythonBuiltins =
    "abs all any bin bool bytes callable chr dict dir divmod enumerate eval exec filter float format frozenset getattr globals "
    "hasattr hash help hex id input int isinstance issubclass iter len list locals map max min next object oct open ord pow print "
    "property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip self cls";
static const char *kSQLKeywords =
    "add all alter and any as asc between by case check column constraint create cross database default delete desc distinct "
    "drop else end exec exists foreign from full group having in index inner insert into is join key left like limit not null "
    "on or order outer primary procedure references right rownum select set table then top truncate union unique update values "
    "view when where with begin commit rollback transaction declare int integer varchar nvarchar char text date datetime "
    "decimal numeric float bit count sum avg min max";
static const char *kBashKeywords =
    "if then else elif fi case esac for select while until do done in function time coproc return exit break continue "
    "local export readonly declare typeset unset shift source alias echo printf read cd pwd test eval exec trap set";
static const char *kBatchKeywords =
    "rem set if else exist errorlevel for in do break call copy chcp cd chdir choice cls country ctty date del erase dir echo "
    "exit goto loadfix loadhigh mkdir md move path pause prompt rename ren rmdir rd shift time type ver verify vol com con lpt "
    "nul defined not equ neq lss leq gtr geq setlocal endlocal enabledelayedexpansion pushd popd start title";
static const char *kHTMLTags =
    "a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col colgroup "
    "data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head "
    "header hr html i iframe img input ins kbd label legend li link main map mark meta meter nav noscript object ol optgroup "
    "option output p param picture pre progress q rp rt ruby s samp script section select small source span strong style sub "
    "summary sup table tbody td template textarea tfoot th thead time title tr track u ul var video wbr "
    "class id style href src alt type name value content rel charset lang width height action method placeholder disabled "
    "checked selected readonly for target onclick onload onchange";
static const char *kPHPKeywords =
    "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty "
    "enddeclare endfor endforeach endif endswitch endwhile eval exit extends final finally fn for foreach function global goto "
    "if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected "
    "public readonly require require_once return static switch throw trait try unset use var while xor yield true false null";
static const char *kCSSProps =
    "align-content align-items align-self all animation background background-color background-image border border-bottom "
    "border-color border-left border-radius border-right border-top bottom box-shadow box-sizing clear color column-gap content "
    "cursor display flex flex-direction flex-grow flex-shrink flex-wrap float font font-family font-size font-style font-weight "
    "gap grid grid-template-columns grid-template-rows height justify-content left letter-spacing line-height list-style margin "
    "margin-bottom margin-left margin-right margin-top max-height max-width min-height min-width opacity outline overflow "
    "overflow-x overflow-y padding padding-bottom padding-left padding-right padding-top position right text-align "
    "text-decoration text-transform top transform transition vertical-align visibility white-space width word-break z-index";

static void Send(ScintillaView *v, unsigned int msg, uptr_t w, sptr_t l) { [v message:msg wParam:w lParam:l]; }
static void Fore(ScintillaView *v, int style, long color) { Send(v, SCI_STYLESETFORE, style, color); }
static void Bold(ScintillaView *v, int style) { Send(v, SCI_STYLESETBOLD, style, 1); }
static void Italic(ScintillaView *v, int style) { Send(v, SCI_STYLESETITALIC, style, 1); }
static void Keywords(ScintillaView *v, int set, const char *words) { Send(v, SCI_SETKEYWORDS, set, (sptr_t)words); }

static void StyleCpp(ScintillaView *v) {
    for (int s : {SCE_C_COMMENT, SCE_C_COMMENTLINE, SCE_C_COMMENTDOC, SCE_C_COMMENTLINEDOC, SCE_C_COMMENTDOCKEYWORD})
        Fore(v, s, kComment);
    for (int s : {SCE_C_STRING, SCE_C_CHARACTER, SCE_C_STRINGRAW, SCE_C_VERBATIM, SCE_C_TRIPLEVERBATIM, SCE_C_REGEX,
                  SCE_C_HASHQUOTEDSTRING, SCE_C_STRINGEOL})
        Fore(v, s, kString);
    Fore(v, SCE_C_NUMBER, kNumber);
    Fore(v, SCE_C_WORD, kKeyword); Bold(v, SCE_C_WORD);
    Fore(v, SCE_C_WORD2, kKeyword2);
    Fore(v, SCE_C_PREPROCESSOR, kPreproc);
    Fore(v, SCE_C_OPERATOR, kOperator);
    Send(v, SCI_SETPROPERTY, (uptr_t)"lexer.cpp.track.preprocessor", (sptr_t)"0");
}

static void StyleHTML(ScintillaView *v) {
    for (int s : {SCE_H_TAG, SCE_H_TAGEND, SCE_H_XMLSTART, SCE_H_XMLEND}) Fore(v, s, kTag);
    Fore(v, SCE_H_TAGUNKNOWN, kTag);
    Fore(v, SCE_H_ATTRIBUTE, kAttr); Fore(v, SCE_H_ATTRIBUTEUNKNOWN, kAttr);
    Fore(v, SCE_H_NUMBER, kNumber);
    Fore(v, SCE_H_DOUBLESTRING, kKeyword); Fore(v, SCE_H_SINGLESTRING, kKeyword);
    Fore(v, SCE_H_COMMENT, kComment); Fore(v, SCE_H_XCCOMMENT, kComment);
    Fore(v, SCE_H_ENTITY, kPreproc);
    Fore(v, SCE_H_CDATA, kString);
    Fore(v, SCE_H_SGML_DEFAULT, kPreproc); Fore(v, SCE_H_SGML_COMMAND, kPreproc);
    // 內嵌 JavaScript
    for (int s : {SCE_HJ_COMMENT, SCE_HJ_COMMENTLINE, SCE_HJ_COMMENTDOC}) Fore(v, s, kComment);
    Fore(v, SCE_HJ_KEYWORD, kKeyword); Bold(v, SCE_HJ_KEYWORD);
    for (int s : {SCE_HJ_DOUBLESTRING, SCE_HJ_SINGLESTRING, SCE_HJ_REGEX}) Fore(v, s, kString);
    Fore(v, SCE_HJ_NUMBER, kNumber);
    // 內嵌 PHP
    Fore(v, SCE_HPHP_WORD, kKeyword); Bold(v, SCE_HPHP_WORD);
    Fore(v, SCE_HPHP_HSTRING, kString); Fore(v, SCE_HPHP_SIMPLESTRING, kString);
    Fore(v, SCE_HPHP_COMMENT, kComment); Fore(v, SCE_HPHP_COMMENTLINE, kComment);
    Fore(v, SCE_HPHP_NUMBER, kNumber);
    Fore(v, SCE_HPHP_VARIABLE, kKeyword2); Fore(v, SCE_HPHP_HSTRING_VARIABLE, kKeyword2);
    Fore(v, SCE_H_QUESTION, kPreproc);
}

NSString *N2SyntaxLineComment(NSString *langID) {
    static NSDictionary *map = @{
        @"c": @"//", @"objc": @"//", @"java": @"//", @"kotlin": @"//", @"csharp": @"//", @"js": @"//", @"ts": @"//",
        @"swift": @"//", @"json": @"//", @"php": @"//", @"python": @"#", @"bash": @"#", @"makefile": @"#",
        @"ini": @";", @"sql": @"--", @"batch": @"REM",
    };
    return map[langID];
}

NSArray<NSString *> *N2SyntaxBlockComment(NSString *langID) {
    static NSDictionary *map = @{
        @"c": @[@"/*", @"*/"], @"objc": @[@"/*", @"*/"], @"java": @[@"/*", @"*/"], @"kotlin": @[@"/*", @"*/"],
        @"csharp": @[@"/*", @"*/"], @"js": @[@"/*", @"*/"], @"ts": @[@"/*", @"*/"], @"swift": @[@"/*", @"*/"],
        @"css": @[@"/*", @"*/"], @"sql": @[@"/*", @"*/"], @"php": @[@"/*", @"*/"], @"json": @[@"/*", @"*/"],
        @"html": @[@"<!--", @"-->"], @"xml": @[@"<!--", @"-->"], @"markdown": @[@"<!--", @"-->"],
        @"python": @[@"\"\"\"", @"\"\"\""],
    };
    return map[langID];
}

static void ApplyLexerStyles(ScintillaView *v, const LangInfo *lang, NSString *fontName, CGFloat fontSize);

void N2SyntaxApply(ScintillaView *v, NSString *langID, NSString *fontName, CGFloat fontSize, BOOL invert) {
    const LangInfo *lang = Find(langID);
    ApplyLexerStyles(v, lang, fontName, fontSize);

    // 編輯區顏色（BGR）
    long caretLine = RGB(0xE8, 0xF0, 0xF7), selection = RGB(0xA8, 0xD6, 0xF5), caret = RGB(0, 0, 0);
    long whitespace = RGB(0xB0, 0xB0, 0xB0), edge = RGB(0xD8, 0xD8, 0xD8), sameText = RGB(0xFF, 0xC8, 0x00);
    long guide = RGB(0xC0, 0xC0, 0xC0);
    if (invert) {
        // 所有樣式（0～255）前景、背景都反轉
        for (int st = 0; st <= STYLE_MAX; st++) {
            long fore = [v message:SCI_STYLEGETFORE wParam:st];
            long back = [v message:SCI_STYLEGETBACK wParam:st];
            Send(v, SCI_STYLESETFORE, st, fore ^ 0xFFFFFF);
            Send(v, SCI_STYLESETBACK, st, back ^ 0xFFFFFF);
        }
        caretLine ^= 0xFFFFFF; selection ^= 0xFFFFFF; caret ^= 0xFFFFFF;
        whitespace ^= 0xFFFFFF; edge ^= 0xFFFFFF; sameText ^= 0xFFFFFF; guide ^= 0xFFFFFF;
    }
    Send(v, SCI_SETCARETLINEBACK, caretLine, 0);
    Send(v, SCI_SETSELBACK, 1, selection);
    Send(v, SCI_SETCARETFORE, caret, 0);
    Send(v, SCI_SETWHITESPACEFORE, 1, whitespace);
    Send(v, SCI_SETEDGECOLOUR, edge, 0);
    Fore(v, STYLE_INDENTGUIDE, guide);
    Send(v, SCI_INDICSETSTYLE, N2IndicatorSameText, INDIC_ROUNDBOX);
    Send(v, SCI_INDICSETFORE, N2IndicatorSameText, sameText);
    Send(v, SCI_INDICSETALPHA, N2IndicatorSameText, 90);
    Send(v, SCI_INDICSETOUTLINEALPHA, N2IndicatorSameText, 160);
    Send(v, SCI_INDICSETUNDER, N2IndicatorSameText, 1);
    // 不再整份重新上色：ApplyLexerStyles 已做過一次，之後只換顏色，樣式編號不變
}

static void ApplyLexerStyles(ScintillaView *v, const LangInfo *lang, NSString *fontName, CGFloat fontSize) {

    // 基本樣式：先設 STYLE_DEFAULT，再複製到所有樣式
    Send(v, SCI_STYLERESETDEFAULT, 0, 0);
    [v setStringProperty:SCI_STYLESETFONT parameter:STYLE_DEFAULT value:fontName];
    Send(v, SCI_STYLESETSIZEFRACTIONAL, STYLE_DEFAULT, (sptr_t)lround(fontSize * SC_FONT_SIZE_MULTIPLIER));
    Fore(v, STYLE_DEFAULT, RGB(0, 0, 0));
    Send(v, SCI_STYLESETBACK, STYLE_DEFAULT, RGB(0xFF, 0xFF, 0xFF));
    Send(v, SCI_STYLECLEARALL, 0, 0);
    Fore(v, STYLE_LINENUMBER, RGB(0x80, 0x80, 0x80));
    Send(v, SCI_STYLESETBACK, STYLE_LINENUMBER, RGB(0xF2, 0xF2, 0xF2));
    Fore(v, STYLE_BRACELIGHT, RGB(0xFF, 0x00, 0x00)); Bold(v, STYLE_BRACELIGHT);
    Fore(v, STYLE_CONTROLCHAR, RGB(0x80, 0x80, 0x80));

    if (!lang->lexer) {
        Send(v, SCI_SETLEXER, SCLEX_NULL, 0);
        Send(v, SCI_COLOURISE, 0, -1);
        return;
    }
    [v message:SCI_SETLEXERLANGUAGE wParam:0 lParam:(sptr_t)lang->lexer];
    for (int i = 0; i < 9; i++) Keywords(v, i, "");

    NSString *lid = lang->langID;
    if ([lid isEqualToString:@"c"]) {
        StyleCpp(v); Keywords(v, 0, kCKeywords);
    } else if ([lid isEqualToString:@"objc"]) {
        StyleCpp(v); Keywords(v, 0, kCKeywords); Keywords(v, 1, kObjCKeywords);
    } else if ([lid isEqualToString:@"java"]) {
        StyleCpp(v); Keywords(v, 0, kJavaKeywords);
    } else if ([lid isEqualToString:@"kotlin"]) {
        StyleCpp(v); Keywords(v, 0, kKotlinKeywords);
    } else if ([lid isEqualToString:@"csharp"]) {
        StyleCpp(v); Keywords(v, 0, kCSharpKeywords);
    } else if ([lid isEqualToString:@"js"]) {
        StyleCpp(v); Keywords(v, 0, kJSKeywords);
    } else if ([lid isEqualToString:@"ts"]) {
        StyleCpp(v); Keywords(v, 0, kJSKeywords); Keywords(v, 1, kTSKeywords);
    } else if ([lid isEqualToString:@"swift"]) {
        StyleCpp(v); Keywords(v, 0, kSwiftKeywords);
    } else if ([lid isEqualToString:@"json"]) {
        // 與 Windows 版 R151 的 JSON 配置相同的顏色
        Fore(v, SCE_JSON_PROPERTYNAME, RGB(0x00, 0x3A, 0x8C)); Bold(v, SCE_JSON_PROPERTYNAME);
        for (int s : {SCE_JSON_STRING, SCE_JSON_URI, SCE_JSON_COMPACTIRI}) Fore(v, s, RGB(0x00, 0x80, 0x00));
        Fore(v, SCE_JSON_NUMBER, RGB(0xA0, 0x40, 0x00));
        Fore(v, SCE_JSON_KEYWORD, RGB(0x80, 0x25, 0x80)); Bold(v, SCE_JSON_KEYWORD);
        Fore(v, SCE_JSON_ESCAPESEQUENCE, RGB(0xB0, 0x2C, 0x56)); Bold(v, SCE_JSON_ESCAPESEQUENCE);
        Fore(v, SCE_JSON_OPERATOR, kOperator);
        for (int s : {SCE_JSON_ERROR, SCE_JSON_STRINGEOL}) Send(v, SCI_STYLESETBACK, s, RGB(0xFF, 0xC0, 0xC0));
        Fore(v, SCE_JSON_LINECOMMENT, kComment); Fore(v, SCE_JSON_BLOCKCOMMENT, kComment);
        Keywords(v, 0, "false null true");
        Send(v, SCI_SETPROPERTY, (uptr_t)"lexer.json.allow.comments", (sptr_t)"1");
        Send(v, SCI_SETPROPERTY, (uptr_t)"lexer.json.escape.sequence", (sptr_t)"1");
    } else if ([lid isEqualToString:@"python"]) {
        Fore(v, SCE_P_COMMENTLINE, kComment); Fore(v, SCE_P_COMMENTBLOCK, kComment);
        Fore(v, SCE_P_NUMBER, kNumber);
        for (int s : {SCE_P_STRING, SCE_P_CHARACTER, SCE_P_TRIPLE, SCE_P_TRIPLEDOUBLE, SCE_P_FSTRING, SCE_P_FCHARACTER,
                      SCE_P_FTRIPLE, SCE_P_FTRIPLEDOUBLE, SCE_P_STRINGEOL})
            Fore(v, s, kString);
        Fore(v, SCE_P_WORD, kKeyword); Bold(v, SCE_P_WORD);
        Fore(v, SCE_P_WORD2, kKeyword2);
        Fore(v, SCE_P_DECORATOR, kPreproc);
        Fore(v, SCE_P_DEFNAME, kHeading); Bold(v, SCE_P_DEFNAME);
        Fore(v, SCE_P_CLASSNAME, kHeading); Bold(v, SCE_P_CLASSNAME);
        Fore(v, SCE_P_OPERATOR, kOperator);
        Keywords(v, 0, kPythonKeywords); Keywords(v, 1, kPythonBuiltins);
    } else if ([lid isEqualToString:@"html"] || [lid isEqualToString:@"php"]) {
        StyleHTML(v);
        Keywords(v, 0, kHTMLTags); Keywords(v, 1, kJSKeywords); Keywords(v, 4, kPHPKeywords);
    } else if ([lid isEqualToString:@"xml"]) {
        StyleHTML(v);
    } else if ([lid isEqualToString:@"css"]) {
        Fore(v, SCE_CSS_TAG, kTag); Bold(v, SCE_CSS_TAG);
        Fore(v, SCE_CSS_CLASS, kKeyword2); Fore(v, SCE_CSS_ID, kKeyword2);
        Fore(v, SCE_CSS_PSEUDOCLASS, kPreproc); Fore(v, SCE_CSS_UNKNOWN_PSEUDOCLASS, kPreproc);
        Fore(v, SCE_CSS_IDENTIFIER, kAttr); Fore(v, SCE_CSS_UNKNOWN_IDENTIFIER, kAttr);
        Fore(v, SCE_CSS_VALUE, kKeyword);
        Fore(v, SCE_CSS_COMMENT, kComment);
        Fore(v, SCE_CSS_DOUBLESTRING, kString); Fore(v, SCE_CSS_SINGLESTRING, kString);
        Fore(v, SCE_CSS_IMPORTANT, kAttr); Bold(v, SCE_CSS_IMPORTANT);
        Fore(v, SCE_CSS_DIRECTIVE, kPreproc);
        Fore(v, SCE_CSS_OPERATOR, kOperator);
        Keywords(v, 0, kCSSProps);
    } else if ([lid isEqualToString:@"sql"]) {
        for (int s : {SCE_SQL_COMMENT, SCE_SQL_COMMENTLINE, SCE_SQL_COMMENTDOC, SCE_SQL_COMMENTLINEDOC}) Fore(v, s, kComment);
        Fore(v, SCE_SQL_NUMBER, kNumber);
        Fore(v, SCE_SQL_WORD, kKeyword); Bold(v, SCE_SQL_WORD);
        Fore(v, SCE_SQL_STRING, kString); Fore(v, SCE_SQL_CHARACTER, kString);
        Fore(v, SCE_SQL_OPERATOR, kOperator);
        Keywords(v, 0, kSQLKeywords);
    } else if ([lid isEqualToString:@"bash"]) {
        Fore(v, SCE_SH_COMMENTLINE, kComment);
        Fore(v, SCE_SH_NUMBER, kNumber);
        Fore(v, SCE_SH_WORD, kKeyword); Bold(v, SCE_SH_WORD);
        Fore(v, SCE_SH_STRING, kString); Fore(v, SCE_SH_CHARACTER, kString);
        Fore(v, SCE_SH_SCALAR, kKeyword2); Fore(v, SCE_SH_PARAM, kKeyword2);
        Fore(v, SCE_SH_BACKTICKS, kPreproc);
        Fore(v, SCE_SH_HERE_DELIM, kPreproc); Fore(v, SCE_SH_HERE_Q, kString);
        Fore(v, SCE_SH_OPERATOR, kOperator);
        Keywords(v, 0, kBashKeywords);
    } else if ([lid isEqualToString:@"batch"]) {
        Fore(v, SCE_BAT_COMMENT, kComment);
        Fore(v, SCE_BAT_WORD, kKeyword); Bold(v, SCE_BAT_WORD);
        Fore(v, SCE_BAT_LABEL, kTag); Bold(v, SCE_BAT_LABEL);
        Fore(v, SCE_BAT_HIDE, kPreproc);
        Fore(v, SCE_BAT_COMMAND, kKeyword2);
        Fore(v, SCE_BAT_IDENTIFIER, kAttr);
        Fore(v, SCE_BAT_OPERATOR, kOperator);
        Keywords(v, 0, kBatchKeywords);
    } else if ([lid isEqualToString:@"ini"]) {
        Fore(v, SCE_PROPS_COMMENT, kComment);
        Fore(v, SCE_PROPS_SECTION, kHeading); Bold(v, SCE_PROPS_SECTION);
        Fore(v, SCE_PROPS_ASSIGNMENT, kOperator);
        Fore(v, SCE_PROPS_DEFVAL, kPreproc);
        Fore(v, SCE_PROPS_KEY, kKeyword);
    } else if ([lid isEqualToString:@"markdown"]) {
        for (int s : {SCE_MARKDOWN_HEADER1, SCE_MARKDOWN_HEADER2, SCE_MARKDOWN_HEADER3, SCE_MARKDOWN_HEADER4,
                      SCE_MARKDOWN_HEADER5, SCE_MARKDOWN_HEADER6}) { Fore(v, s, kHeading); Bold(v, s); }
        Bold(v, SCE_MARKDOWN_STRONG1); Bold(v, SCE_MARKDOWN_STRONG2);
        Italic(v, SCE_MARKDOWN_EM1); Italic(v, SCE_MARKDOWN_EM2);
        for (int s : {SCE_MARKDOWN_CODE, SCE_MARKDOWN_CODE2, SCE_MARKDOWN_CODEBK}) Fore(v, s, kString);
        Fore(v, SCE_MARKDOWN_LINK, kKeyword);
        Fore(v, SCE_MARKDOWN_BLOCKQUOTE, kComment);
        Fore(v, SCE_MARKDOWN_ULIST_ITEM, kPreproc); Fore(v, SCE_MARKDOWN_OLIST_ITEM, kPreproc);
        Fore(v, SCE_MARKDOWN_HRULE, kPreproc);
        Fore(v, SCE_MARKDOWN_STRIKEOUT, RGB(0x80, 0x80, 0x80));
    } else if ([lid isEqualToString:@"makefile"]) {
        Fore(v, SCE_MAKE_COMMENT, kComment);
        Fore(v, SCE_MAKE_PREPROCESSOR, kPreproc);
        Fore(v, SCE_MAKE_IDENTIFIER, kKeyword2);
        Fore(v, SCE_MAKE_OPERATOR, kOperator);
        Fore(v, SCE_MAKE_TARGET, kTag); Bold(v, SCE_MAKE_TARGET);
    } else if ([lid isEqualToString:@"diff"]) {
        Fore(v, SCE_DIFF_COMMENT, kComment);
        Fore(v, SCE_DIFF_COMMAND, kKeyword); Bold(v, SCE_DIFF_COMMAND);
        Fore(v, SCE_DIFF_HEADER, kTag); Bold(v, SCE_DIFF_HEADER);
        Fore(v, SCE_DIFF_POSITION, kPreproc);
        Fore(v, SCE_DIFF_DELETED, RGB(0xC0, 0x00, 0x00));
        Fore(v, SCE_DIFF_ADDED, RGB(0x00, 0x80, 0x00));
        Fore(v, SCE_DIFF_CHANGED, RGB(0x00, 0x60, 0xC0));
    }
    Send(v, SCI_COLOURISE, 0, -1);
}
