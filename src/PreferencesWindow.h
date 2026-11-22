// 偏好設定視窗（⌘,）。所有控制項直接繫結 NSUserDefaults，變更立即套用到所有視窗。
#pragma once
#import <Cocoa/Cocoa.h>

@interface N2PreferencesWindow : NSWindowController
@property (class, nonatomic, readonly) N2PreferencesWindow *shared;
@end
