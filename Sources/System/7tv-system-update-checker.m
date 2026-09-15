#import "7tv-system-update-checker.h"
#import "Localization/7tv-localization-manager.h"
#import "Settings/7tv-settings-controller.h"
#import <UIKit/UIKit.h>

static NSString *const kIgnored = @"s7tv_update_ignored_version";
static NSString *const kManifest = @"s7tv_update_manifest";
static BOOL checkedThisLaunch;

static BOOL S7TVValidVersion(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 40) return NO;
    NSArray *parts = [value componentsSeparatedByString:@"."];
    if (parts.count != 3) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (NSString *part in parts) {
        if (!part.length || [part rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    }
    return YES;
}

static BOOL S7TVValidManifest(id value) {
    return [value isKindOfClass:NSDictionary.class] &&
        S7TVValidVersion(value[@"version"]);
}

// NO uniquement si l'affichage doit attendre.
static BOOL S7TVPresentUpdate(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *manifest = [defaults dictionaryForKey:kManifest];
    if (!S7TVValidManifest(manifest)) return YES;
    NSString *version = manifest[@"version"];
    if ([version compare:@S7TV_BUILD_VERSION options:NSNumericSearch] != NSOrderedDescending ||
        [version isEqualToString:[defaults stringForKey:kIgnored]]) return YES;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;

    UIViewController *presenter = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) presenter = window.rootViewController;
        }
    }
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter.viewIfLoaded.window || presenter.isBeingDismissed || presenter.isBeingPresented ||
        presenter.transitionCoordinator || [presenter isKindOfClass:UIAlertController.class]) return NO;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"update_title")
        message:[NSString stringWithFormat:L(@"update_message"), version, @S7TV_BUILD_VERSION]
        preferredStyle:UIAlertControllerStyleAlert];
    alert.view.tintColor = S7TVAccent();
    [alert addAction:[UIAlertAction actionWithTitle:L(@"update_open") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/Knoks1111/TwitchPlusK/releases/latest"] options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"update_later") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"update_ignore") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [defaults setObject:version forKey:kIgnored];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
    return alert.presentingViewController != nil;
}

static void S7TVPresentUpdateWhenReady(NSTimeInterval deadline) {
    if (NSProcessInfo.processInfo.systemUptime >= deadline || S7TVPresentUpdate()) return;
    // Attente bornée ; aucune nouvelle requête réseau.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        S7TVPresentUpdateWhenReady(deadline);
    });
}

static void S7TVCheckForUpdate(void) {
    if (checkedThisLaunch || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    checkedThisLaunch = YES;
    NSURL *url = [NSURL URLWithString:@"https://raw.githubusercontent.com/Knoks1111/TwitchPlusK/main/update.json"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id manifest = nil;
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse *)response).statusCode == 200 && data.length && data.length <= 16384) {
            manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (S7TVValidManifest(manifest)) [defaults setObject:manifest forKey:kManifest];
            S7TVPresentUpdateWhenReady(NSProcessInfo.processInfo.systemUptime + 10);
        });
        [session finishTasksAndInvalidate];
    }] resume];
}

void S7TVUpdateCheckerSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                S7TVCheckForUpdate();
            }];
        S7TVCheckForUpdate();
    });
}
