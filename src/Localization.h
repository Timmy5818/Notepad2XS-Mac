// 介面語言：繁體中文（原文）、English、日本語、简体中文、한국어、Français、Deutsch、Русский
// 選單、狀態列、尋找視窗與偏好設定標題會翻譯；變更後重新啟動生效
#pragma once
#import <Foundation/Foundation.h>

NSString *N2L(NSString *zhHant);
NSString *N2CurrentLanguage(void);                 // zh-Hant / en / ja / zh-Hans / ko / fr / de / ru
NSArray<NSArray<NSString *> *> *N2LanguageChoices(void);   // @[代碼, 顯示名稱]
void N2ApplyLanguagePreference(void);              // 讓系統視窗（開啟／儲存）也使用同一語言
