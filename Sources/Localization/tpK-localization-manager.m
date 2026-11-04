#import "Localization/tpK-localization-manager.h"
#import "tpk-localization-data.h"

NSString *const TPKLanguageDidChangeNotification = @"TPKLanguageDidChangeNotification";

static NSString *const kTPKLanguageDefaultsKey = @"tpk_language";

@implementation TPKLocalization {
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *_tables;
}

+ (instancetype)shared {
    static TPKLocalization *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [TPKLocalization new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tables = TPKLocalizationTables();

        NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kTPKLanguageDefaultsKey];
        // Défaut : anglais — pas de détection automatique de la langue
        // système, le choix reste 100% manuel (voir header).
        _currentLanguage = stored ? (TPKLanguage)stored.integerValue : TPKLanguageEnglish;
    }
    return self;
}

- (void)setCurrentLanguage:(TPKLanguage)currentLanguage {
    if (_currentLanguage == currentLanguage) return;
    _currentLanguage = currentLanguage;
    [[NSUserDefaults standardUserDefaults] setInteger:currentLanguage forKey:kTPKLanguageDefaultsKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TPKLanguageDidChangeNotification object:nil];
    });
}

- (NSString *)stringForKey:(NSString *)key {
    if (!key.length) return @"";
    NSString *language = self.currentLanguage == TPKLanguageEnglish ? @"en" : @"fr";
    NSString *value = _tables[language][key];
    return value.length ? value : [NSString stringWithFormat:@"[Missing translation: %@]", key];
}

@end

NSString *L(NSString *key) {
    return [[TPKLocalization shared] stringForKey:key];
}
