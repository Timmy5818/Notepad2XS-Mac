// 本機版本歷史：存檔覆蓋前備份磁碟上的舊檔（規則與 Windows 版相同）
#pragma once
#import <Cocoa/Cocoa.h>

@interface N2HistoryEntry : NSObject
@property (nonatomic, copy) NSString *path;   // 備份檔
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) unsigned long long size;
@end

// 備份即將被覆蓋的檔案；未啟用或檔案不存在時直接成功。失敗時應停止這次存檔。
BOOL N2HistoryBackup(NSURL *target, NSError **error);
// 依設定清理較舊的版本（失敗不影響存檔）
void N2HistoryPrune(NSURL *target);
NSArray<N2HistoryEntry *> *N2HistoryList(NSURL *target);   // 最新在前
NSString *N2HistoryDirectory(NSURL *target);

@class Document;
@interface N2HistoryWindow : NSWindowController
+ (void)showForDocument:(Document *)doc;
@end
