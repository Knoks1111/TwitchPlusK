#import "Picker/tpK-picker-channel-avatar.h"
#import "Core/tpK-core-manager.h"

NSString *const TPKPickerChannelAvatarDidUpdateNotification = @"TPKPickerChannelAvatarDidUpdateNotification";

static NSURL *TPKUserURL(NSString *channelID) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.twitch.tv/helix/users"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:channelID]];
    return components.URL;
}

@interface TPKPickerChannelAvatarProvider ()
@property (nonatomic, strong) dispatch_queue_t avatarQueue;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *channelAvatarURLs;
@property (nonatomic, strong) NSMutableSet<NSString *> *fetchingChannelIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *avatarRetryAfter;
@end

@implementation TPKPickerChannelAvatarProvider
+ (instancetype)sharedProvider {
    static TPKPickerChannelAvatarProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [TPKPickerChannelAvatarProvider new];
    });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _channelAvatarURLs = @{};
        _fetchingChannelIDs = [NSMutableSet set];
        _avatarRetryAfter = [NSMutableDictionary dictionary];
        _avatarQueue = dispatch_queue_create("tv.s7tv.picker-avatar", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}
- (NSURLRequest *)tpk_helixRequestWithURL:(NSURL *)url {
    TPKManager *mgr = [TPKManager sharedManager];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    NSDictionary<NSString *, NSString *> *credentials = [mgr tpk_twitchCredentialsSnapshot];
    if (credentials[@"Authorization"].length) {
        [req setValue:credentials[@"Authorization"] forHTTPHeaderField:@"Authorization"];
    }
    if (credentials[@"Client-ID"].length) {
        [req setValue:credentials[@"Client-ID"] forHTTPHeaderField:@"Client-ID"];
    }
    return req;
}
- (void)tpk_loadChannelAvatarForChannelID:(NSString *)channelID {
    if (!channelID.length) return;

    TPKManager *mgr = [TPKManager sharedManager];
    NSDictionary<NSString *, NSString *> *credentials = [mgr tpk_twitchCredentialsSnapshot];
    if (!credentials[@"Authorization"].length || !credentials[@"Client-ID"].length) {
        // The picker retries when Twitch credentials become available.
        return;
    }

    __block BOOL shouldFetch = NO;
    NSDate *now = [NSDate date];
    dispatch_barrier_sync(self.avatarQueue, ^{
        NSDate *retryAfter = self.avatarRetryAfter[channelID];
        BOOL retryAllowed = !retryAfter || [retryAfter compare:now] != NSOrderedDescending;
        if (!self.channelAvatarURLs[channelID] &&
            ![self.fetchingChannelIDs containsObject:channelID] &&
            retryAllowed) {
            [self.fetchingChannelIDs addObject:channelID];
            shouldFetch = YES;
        }
    });
    if (!shouldFetch) return;

    NSURL *url = TPKUserURL(channelID);
    if (!url) {
        dispatch_barrier_async(self.avatarQueue, ^{
            [self.fetchingChannelIDs removeObject:channelID];
        });
        return;
    }

    NSURLRequest *request = [self tpk_helixRequestWithURL:url];
    NSString *requestToken = [request valueForHTTPHeaderField:@"Authorization"];
    NSString *requestClientID = [request valueForHTTPHeaderField:@"Client-ID"];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *avatarURLString = nil;
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && data.length && statusCode >= 200 && statusCode < 300) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *users = [root isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
            NSDictionary *user = [users isKindOfClass:[NSArray class]] ? users.firstObject : nil;
            NSString *returnedID = [user isKindOfClass:[NSDictionary class]] ? user[@"id"] : nil;
            NSString *candidateURL = [user isKindOfClass:[NSDictionary class]]
                ? user[@"profile_image_url"] : nil;
            if ([returnedID isKindOfClass:[NSString class]] &&
                [returnedID isEqualToString:channelID] &&
                [candidateURL isKindOfClass:[NSString class]] &&
                candidateURL.length && [NSURL URLWithString:candidateURL]) {
                avatarURLString = candidateURL;
            }
        }

        BOOL succeeded = avatarURLString.length > 0;
        TPKManager *currentManager = [TPKManager sharedManager];
        NSDictionary<NSString *, NSString *> *currentCredentials =
            [currentManager tpk_twitchCredentialsSnapshot];
        BOOL credentialsChanged =
            ![requestToken isEqualToString:currentCredentials[@"Authorization"]] ||
            ![requestClientID isEqualToString:currentCredentials[@"Client-ID"]];
        dispatch_barrier_async(strongSelf.avatarQueue, ^{
            [strongSelf.fetchingChannelIDs removeObject:channelID];
            if (succeeded) {
                NSMutableDictionary *updated = [strongSelf.channelAvatarURLs mutableCopy];
                updated[channelID] = avatarURLString;
                strongSelf.channelAvatarURLs = [updated copy];
                [strongSelf.avatarRetryAfter removeObjectForKey:channelID];
            } else if (credentialsChanged) {
                [strongSelf.avatarRetryAfter removeObjectForKey:channelID];
            } else {
                // Limit retries when Helix or the token is unavailable.
                strongSelf.avatarRetryAfter[channelID] =
                    [NSDate dateWithTimeIntervalSinceNow:30.0];
            }

            if (succeeded) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:TPKPickerChannelAvatarDidUpdateNotification object:nil];
                });
            } else if (credentialsChanged) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [strongSelf tpk_loadChannelAvatarForChannelID:channelID];
                });
            }
        });

        if (!succeeded) {
            [[TPKManager sharedManager] log:
                @"⚠️ Avatar: échec Helix pour la chaîne %@ (HTTP %ld, %@)",
                channelID, (long)statusCode, error.localizedDescription ?: @"réponse invalide"];
        }
    }];
    [task resume];
}
- (nullable NSURL *)channelAvatarURLForChannelID:(NSString *)channelID {
    if (!channelID.length) return nil;

    __block NSString *imageURLString = nil;
    dispatch_sync(self.avatarQueue, ^{
        imageURLString = self.channelAvatarURLs[channelID];
    });
    if (!imageURLString.length) {
        [self tpk_loadChannelAvatarForChannelID:channelID];
        return nil;
    }

    NSURL *url = [NSURL URLWithString:imageURLString];
    if (!url) return nil;
    return url;
}
@end
