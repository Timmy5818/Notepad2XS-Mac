#import "Localization.h"
#import "Settings.h"

// 翻譯表：resources/Localization.json，{ 繁中原文: { 語言代碼: 譯文 } }
// 語言代碼：en、ja、zh-Hans、ko、fr、de、ru、es、pt-BR、it、pl（R136.1 新增後四種）
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *Table(void) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"Localization" ofType:@"json"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        t = [obj isKindOfClass:NSDictionary.class] ? obj : @{};
    });
    return t;
}

NSArray<NSArray<NSString *> *> *N2LanguageChoices(void) {
    return @[@[@"", @"跟隨系統（Follow System）"], @[@"zh-Hant", @"繁體中文"], @[@"en", @"English"], @[@"ja", @"日本語"],
             @[@"zh-Hans", @"简体中文"], @[@"ko", @"한국어"], @[@"fr", @"Français"], @[@"de", @"Deutsch"], @[@"ru", @"Русский"],
             @[@"es", @"Español"], @[@"pt-BR", @"Português (Brasil)"], @[@"it", @"Italiano"], @[@"pl", @"Polski"]];
}

static NSString *Normalize(NSString *lang) {
    lang = lang.lowercaseString;
    if ([lang hasPrefix:@"zh-hans"] || [lang hasPrefix:@"zh-cn"] || [lang hasPrefix:@"zh-sg"]) return @"zh-Hans";
    if ([lang hasPrefix:@"zh"]) return @"zh-Hant";
    // 與 Windows 版相同：葡萄牙文只自動辨識巴西變體，其他地區改用英文；西班牙文各地區共用
    if ([lang hasPrefix:@"pt-br"]) return @"pt-BR";
    if ([lang hasPrefix:@"pt"]) return @"en";
    for (NSString *code in @[@"en", @"ja", @"ko", @"fr", @"de", @"ru", @"es", @"it", @"pl"]) if ([lang hasPrefix:code]) return code;
    return nil;
}

NSString *N2CurrentLanguage(void) {
    static NSString *cached;
    if (cached) return cached;   // 介面語言在啟動時決定
    NSString *setting = [NSUserDefaults.standardUserDefaults stringForKey:N2KeyUILanguage];
    if (setting.length) cached = setting;
    else {
        for (NSString *l in NSLocale.preferredLanguages) if ((cached = Normalize(l))) break;
        if (!cached) cached = @"zh-Hant";
    }
    return cached;
}

NSString *N2L(NSString *zh) {
    NSString *lang = N2CurrentLanguage();
    if (!zh || [lang isEqualToString:@"zh-Hant"]) return zh;
    NSDictionary *row = Table()[zh];
    if (!row) return zh;
    // 沒有該語言的譯文時改用英文（新語言的少數進階訊息與 Windows 版相同使用英文）
    return row[lang] ?: row[@"en"] ?: zh;
}

void N2ApplyLanguagePreference(void) {
    // 只看使用者實際儲存的設定（不受啟動參數影響），沒有設定時用預設的繁體中文
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    NSString *setting = saved[N2KeyUILanguage] ?: @"zh-Hant";
    if (setting.length) {
        if (![saved[@"AppleLanguages"] isEqual:@[setting]])
            [NSUserDefaults.standardUserDefaults setObject:@[setting] forKey:@"AppleLanguages"];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
}
