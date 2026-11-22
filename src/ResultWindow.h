// SQL／系統資訊查詢的原生結果表格視窗（報表格式與匯出沿用 Windows 版 SqlResults.cpp）
#pragma once
#import <Cocoa/Cocoa.h>
#include "SqlResults.h"

@interface N2ResultWindow : NSWindowController
+ (void)showReport:(const xs::SqlReport &)report;
@end
