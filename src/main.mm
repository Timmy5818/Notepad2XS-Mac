#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        static AppDelegate *delegate;   // NSApp.delegate 是 weak，要自己保留
        NSApplication *app = NSApplication.sharedApplication;
        delegate = [AppDelegate new];
        app.delegate = delegate;
        return NSApplicationMain(argc, argv);
    }
}
