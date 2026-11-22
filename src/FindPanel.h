// 尋找／取代浮動視窗（全 App 共用一個，作用在目前的主視窗）
#pragma once
#import <Cocoa/Cocoa.h>

@interface N2FindPanel : NSWindowController

@property (class, nonatomic, readonly) N2FindPanel *shared;
@property (nonatomic, copy) NSString *findString;

- (void)showFind:(NSString *)selection;
- (void)showReplace:(NSString *)selection;
- (void)findNext:(BOOL)forward;   // 不開視窗，直接用上次的字串找下一個／上一個

@end
