// 依副檔名套用 Scintilla 語法上色
#pragma once
#import <Cocoa/Cocoa.h>

@class ScintillaView;

// 所有可選語言的 ID（第一個是 "text" 純文字），選單依此順序建立
NSArray<NSString *> *N2SyntaxLanguageIDs(void);
NSString *N2SyntaxDisplayName(NSString *langID);

// 依檔名判斷語言；判斷不出來回傳 "text"
NSString *N2SyntaxLanguageForFileName(NSString *fileName);

// 套用語言（含基本字型樣式與編輯區顏色）。fontName/fontSize 為編輯區字型。
// invert=YES 時把所有顏色做 RGB 反轉（黑白互換、紅青互換），只影響畫面，不影響文件與列印。
void N2SyntaxApply(ScintillaView *view, NSString *langID, NSString *fontName, CGFloat fontSize, BOOL invert);

// 行註解與區塊註解符號；不支援時回傳 nil
NSString *N2SyntaxLineComment(NSString *langID);
NSArray<NSString *> *N2SyntaxBlockComment(NSString *langID);   // @[開始, 結束]

// 「醒目提示相同文字」用的指示器編號
enum { N2IndicatorSameText = 8 };
