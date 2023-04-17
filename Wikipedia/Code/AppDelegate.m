#import "AppDelegate.h"
@import UserNotifications;
@import BackgroundTasks;
@import WMF.NSUserActivity_WMFExtensions;
@import WMF.NSFileManager_WMFGroup;
#import "WMFAppViewController.h"
#import "UIApplicationShortcutItem+WMFShortcutItem.h"
#import "Wikipedia-Swift.h"
#import "WMFQuoteMacros.h"

static NSTimeInterval const WMFBackgroundFetchInterval = 10800; // 3 Hours
static NSString *const WMFBackgroundAppRefreshTaskIdentifier = @"org.wikimedia.wikipedia.appRefresh";
static NSString *const WMFBackgroundDatabaseHousekeeperTaskIdentifier = @"org.wikimedia.wikipedia.databaseHousekeeper";

@interface AppDelegate ()

@property (nonatomic, strong) WMFAppViewController *appViewController;
@property (nonatomic) BOOL appNeedsResume;

@end

@implementation AppDelegate

#pragma mark - Defaults

+ (void)load {
    /**
     * Register default application preferences.
     * @note This must be loaded before application launch so unit tests can run
     */
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"WMFAutoSignTalkPageDiscussions": @YES
    }];
}

#pragma mark - Accessors

- (UIWindow *)window {
    if (!_window) {
        _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    }
    return _window;
}

#pragma mark - Shortcuts

- (void)updateDynamicIconShortcutItems {
    if (![[UIApplication sharedApplication] respondsToSelector:@selector(shortcutItems)]) {
        return;
    }

    NSMutableArray<UIApplicationShortcutItem *> *shortcutItems =
        [[NSMutableArray alloc] initWithObjects:
                                    [UIApplicationShortcutItem wmf_random],
                                    [UIApplicationShortcutItem wmf_nearby],
                                    nil];

    [shortcutItems addObject:[UIApplicationShortcutItem wmf_search]];

    [UIApplication sharedApplication].shortcutItems = shortcutItems;
}

#pragma mark - UIApplicationDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    DDLogError(@"didFinishLaunchingWithOptions - Start");
    [self registerBackgroundTasksForApplication:application];

#if DEBUG
    // Use NSLog so we can break and copy/paste. DDLogDebug is async.
    NSLog(@"\nSimulator container directory:\n\t%@\n",
          [[NSFileManager defaultManager] wmf_containerPath]);
#endif

#if UI_TEST
    if ([[NSUserDefaults standardUserDefaults] wmf_isFastlaneSnapshotInProgress]) {
        [UIView setAnimationsEnabled:NO];
    }
#endif

    [[NSUserDefaults standardUserDefaults] wmf_migrateFontSizeMultiplier];
    NSUserDefaults.standardUserDefaults.shouldRestoreNavigationStackOnResume = [self shouldRestoreNavigationStackOnResumeAfterBecomingActive];

    self.appNeedsResume = YES;
    WMFAppViewController *vc = [[WMFAppViewController alloc] init];
    [[UIApplication sharedApplication] registerForRemoteNotifications];
    [UNUserNotificationCenter currentNotificationCenter].delegate = vc; // this needs to be set before the end of didFinishLaunchingWithOptions:
    [vc launchAppInWindow:self.window waitToResumeApp:self.appNeedsResume];
    self.appViewController = vc;

    [self updateDynamicIconShortcutItems];

    DDLogError(@"didFinishLaunchingWithOptions - End");
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self cancelPendingBackgroundTasks];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self resumeAppIfNecessary];
    [[WMFMetricsClientBridge sharedInstance] appInForeground];
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    [self.appViewController processShortcutItem:shortcutItem completion:completionHandler];
}

#pragma mark - AppVC Resume

- (void)resumeAppIfNecessary {
    DDLogError(@"resumeAppIfNecessary - Begin");
    if (self.appNeedsResume) {
        [self.appViewController hideSplashScreenAndResumeApp];
        self.appNeedsResume = false;
    }
    DDLogError(@"resumeAppIfNecessary - End");
}

- (BOOL)shouldRestoreNavigationStackOnResumeAfterBecomingActive {
    BOOL shouldOpenAppOnSearchTab = [NSUserDefaults standardUserDefaults].wmf_openAppOnSearchTab;
    if (shouldOpenAppOnSearchTab) {
        return NO;
    }

    return YES;
}

#pragma mark - NSUserActivity Handling

- (BOOL)application:(UIApplication *)application willContinueUserActivityWithType:(NSString *)userActivityType {
    return YES;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *__nullable restorableObjects))restorationHandler {
    DDLogError(@"application:continueUserActivity:restorationHandler - Begin");
    [self.appViewController showSplashView];

    // Assign deep link user info source before routing
    NSMutableDictionary *mutableUserInfo = userActivity.userInfo != nil ? [[NSMutableDictionary alloc] initWithDictionary:userActivity.userInfo] : [[NSMutableDictionary alloc] init];
    mutableUserInfo[WMFRoutingUserInfoKeys.source] = WMFRoutingUserInfoSourceValue.deepLinkRawValue;
    NSDictionary *newUserInfo = [[NSDictionary alloc] initWithDictionary:mutableUserInfo];
    userActivity.userInfo = newUserInfo;

    BOOL result = [self.appViewController processUserActivity:userActivity
                                                     animated:NO
                                                   completion:^{
                                                       if (self.appNeedsResume) {
                                                           [self resumeAppIfNecessary];
                                                       } else {
                                                           [self.appViewController hideSplashViewAnimated:YES];
                                                       }
                                                   }];
    DDLogError(@"application:continueUserActivity:restorationHandler - End");
    return result;
}

- (void)application:(UIApplication *)application didFailToContinueUserActivityWithType:(NSString *)userActivityType error:(NSError *)error {
    DDLogDebug(@"didFailToContinueUserActivityWithType: %@ error: %@", userActivityType, error);
}

- (void)application:(UIApplication *)application didUpdateUserActivity:(NSUserActivity *)userActivity {
    DDLogDebug(@"didUpdateUserActivity: %@", userActivity);
}

#pragma mark - NSURL Handling

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<NSString *, id> *)options {
    DDLogError(@"application:openURL:options: - Begin");
    NSUserActivity *activity = [NSUserActivity wmf_activityForWikipediaScheme:url] ?: [NSUserActivity wmf_activityForURL:url];
    if (activity) {
        [self.appViewController showSplashView];
        BOOL result = [self.appViewController processUserActivity:activity
                                                         animated:NO
                                                       completion:^{
                                                           if (self.appNeedsResume) {
                                                               [self resumeAppIfNecessary];
                                                           } else {
                                                               [self.appViewController hideSplashViewAnimated:YES];
                                                           }
                                                       }];
        DDLogError(@"application:openURL:options: - End");
        return result;
    } else {
        [self resumeAppIfNecessary];
        DDLogError(@"application:openURL:options: - End");
        return NO;
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    DDLogError(@"applicationWillResignActive - Begin");
    [[NSUserDefaults standardUserDefaults] wmf_setAppResignActiveDate:[NSDate date]];
    [[WMFMetricsClientBridge sharedInstance] appInBackground];
    DDLogError(@"applicationWillResignActive - End");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    DDLogError(@"applicationDidEnterBackground - Begin");
    [self updateDynamicIconShortcutItems];
    [self scheduleBackgroundAppRefreshTask];
    [self scheduleDatabaseHousekeeperTask];
    DDLogError(@"applicationDidEnterBackground - End");
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    DDLogError(@"applicationWillTerminate - Begin");
    [self updateDynamicIconShortcutItems];
    [[WMFMetricsClientBridge sharedInstance] appWillClose];
    DDLogError(@"applicationWillTerminate - End");
}

#pragma mark - Background Fetch

/// Cancels any pending background tasks, if applicable on the current platform
- (void)cancelPendingBackgroundTasks {
    [[BGTaskScheduler sharedScheduler] cancelAllTaskRequests];
}

/// Register for any necessary background tasks or updates with the method appropriate for the platform
- (void)registerBackgroundTasksForApplication:(UIApplication *)application {
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:WMFBackgroundAppRefreshTaskIdentifier
                                                          usingQueue:dispatch_get_main_queue()
                                                       launchHandler:^(__kindof BGTask *_Nonnull task) {
                                                           [self.appViewController performBackgroundFetchWithCompletion:^(UIBackgroundFetchResult result) {
                                                               switch (result) {
                                                                   case UIBackgroundFetchResultFailed:
                                                                       [task setTaskCompletedWithSuccess:NO];
                                                                       break;
                                                                   default:
                                                                       [task setTaskCompletedWithSuccess:YES];
                                                                       break;
                                                               }
                                                               // The next task needs to be scheduled
                                                               [self scheduleBackgroundAppRefreshTask];
                                                           }];
                                                       }];

    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:WMFBackgroundDatabaseHousekeeperTaskIdentifier
                                                          usingQueue:dispatch_get_main_queue()
                                                       launchHandler:^(__kindof BGTask *_Nonnull task) {
                                                           [self.appViewController performDatabaseHousekeepingWithCompletion:^(NSError *error) {
                                                               if (error != nil) {
                                                                   [task setTaskCompletedWithSuccess:NO];
                                                               } else {
                                                                   [task setTaskCompletedWithSuccess:YES];
                                                               }
                                                           }];
                                                       }];
}

/// Schedule the next background refresh, if applicable on the current platform
- (void)scheduleBackgroundAppRefreshTask {
    BGAppRefreshTaskRequest *appRefreshTask = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:WMFBackgroundAppRefreshTaskIdentifier];
    appRefreshTask.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:WMFBackgroundFetchInterval];
    NSError *taskSubmitError = nil;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:appRefreshTask error:&taskSubmitError]) {
        DDLogError(@"Unable to schedule background task: %@", taskSubmitError);
    }
}

- (void)scheduleDatabaseHousekeeperTask {
    BGProcessingTaskRequest *databaseHousekeeperTask = [[BGProcessingTaskRequest alloc] initWithIdentifier:WMFBackgroundDatabaseHousekeeperTaskIdentifier];
    databaseHousekeeperTask.earliestBeginDate = nil; // Docs indicate nil = no start delay.
    NSError *taskSubmitError = nil;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:databaseHousekeeperTask error:&taskSubmitError]) {
        DDLogError(@"Unable to schedule background task: %@", taskSubmitError);
    }
}

#pragma mark - Notifications

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    DDLogError(@"Remote notification registration failure: %@", error.localizedDescription);
    [self.appViewController setRemoteNotificationRegistrationStatusWithDeviceToken:nil error:error];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [self.appViewController setRemoteNotificationRegistrationStatusWithDeviceToken:deviceToken error:nil];
}

@end
