// 人工智慧：連接設定、指令視窗、範本管理、HTTP 連線
// 請求組裝、回應解析、範本與設定格式沿用 Windows 版 OrCore.cpp（src/core）
#pragma once
#import <Cocoa/Cocoa.h>
#include <string>

@class EditorWindowController;

// 連接設定視窗
@interface N2AiSettingsWindow : NSWindowController
+ (void)show;
@end

// 範本管理視窗
@interface N2AiTemplateWindow : NSWindowController
+ (void)showWithCompletion:(void (^)(void))completion;
@end

// 對編輯視窗執行 AI 指令
void N2AiRunForEditor(EditorWindowController *editor);
