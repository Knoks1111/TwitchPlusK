/*
 * 7tv-badge-provider.m
 *
 * Voir 7tv-badge-provider.h pour le contexte (Phase 3).
 */

#import "Badge/7tv-badge-provider.h"
#import "Core/7tv-core-manager.h"

NSString *const S7TVBadgesCatalogUpdatedNotification = @"S7TVBadgesCatalogUpdatedNotification";

// Résolution 4x — Helix retourne image_url_4x comme clé principale.
static NSString *const kS7TVBadgeImageURLKey = @"image_url_4x";

static NSString *const kS7TVGlobalBadgesURL =
    @"https://api.twitch.tv/helix/chat/badges/global";

static NSString *S7TVChannelBadgesURL(NSString *channelID) {
    return [NSString stringWithFormat:
        @"https://api.twitch.tv/helix/chat/badges?broadcaster_id=%@", channelID];
}

static NSURL *S7TVUserURL(NSString *channelID) {
    NSURLComponents *components = [NSURLComponents componentsWithString:
        @"https://api.twitch.tv/helix/users"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:channelID]];
    return components.URL;
}


// ============================================================
// MARK: - S7TVResolvedBadge
// ============================================================

@implementation S7TVResolvedBadge
@end


// ============================================================
// MARK: - SevenTVBadgeProvider
// ============================================================

@interface SevenTVBadgeProvider ()
// setID → (version → URL string). Catalogue global (mod/VIP/turbo/staff/
// sub tiers par défaut/etc.) et catalogue channel (sub badges custom de la
// chaîne, bits custom) tenus séparément — la résolution regarde le channel
// D'ABORD (peut surcharger un set du global avec une variante custom),
// PUIS le global en repli (voir resolvedBadgeForIdentifier:).
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *globalBadges;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *channelBadges;
// Même pattern que SevenTVManager.emoteQueue / S7TVChatMessageStore.storeQueue :
// queue concurrente, lectures en dispatch_sync, écritures en
// dispatch_barrier_async.
@property (nonatomic, strong) dispatch_queue_t badgeQueue;
@property (nonatomic, strong) NSString *lastLoadedChannelID; // évite un refetch si join répété sur le même channel
// Avatars des chaînes d'origine du Shared Chat. Le cache est global à la
// session : contrairement aux badges channel, un avatar est lié à un user ID
// Twitch et reste valide lorsqu'on change de chaîne.
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *sharedChatAvatarURLs;
@property (nonatomic, strong) NSMutableSet<NSString *> *fetchingSharedChatAvatarChannelIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *sharedChatAvatarRetryAfter;
@end

@implementation SevenTVBadgeProvider

+ (NSArray<NSString *> *)identifiersFromIRCTag:(NSString * _Nullable)tagValue {
    if (!tagValue.length) return @[];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (NSString *entry in [tagValue componentsSeparatedByString:@","]) {
        if (entry.length && [entry containsString:@"/"]) {
            [identifiers addObject:entry];
        }
    }
    return identifiers;
}

+ (instancetype)sharedProvider {
    static SevenTVBadgeProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [SevenTVBadgeProvider new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _globalBadges  = @{};
        _channelBadges = @{};
        _sharedChatAvatarURLs = @{};
        _fetchingSharedChatAvatarChannelIDs = [NSMutableSet set];
        _sharedChatAvatarRetryAfter = [NSMutableDictionary dictionary];
        _badgeQueue = dispatch_queue_create("tv.s7tv.badge-provider", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

+ (void)setup {
    SevenTVBadgeProvider *provider = [self sharedProvider];
    [provider s7tv_startObservingChannelJoinsOnce];
    [provider loadGlobalBadges];
}

// dispatch_once séparé du singleton lui-même : +setup peut être appelé
// plusieurs fois sans jamais s'abonner deux fois à la notification (ce qui
// dupliquerait les fetchs channel à chaque join).
- (void)s7tv_startObservingChannelJoinsOnce {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:@"S7TVChannelJoined"
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
            NSString *channelID = note.userInfo[@"channelID"];
            if (channelID.length) {
                [[SevenTVBadgeProvider sharedProvider] loadBadgesForChannelID:channelID];
            }
        }];
    });
}

#pragma mark - Chargement réseau

- (NSURLRequest *)s7tv_helixRequestWithURL:(NSURL *)url {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (mgr.twitchToken.length)   [req setValue:mgr.twitchToken   forHTTPHeaderField:@"Authorization"];
    if (mgr.twitchClientID.length) [req setValue:mgr.twitchClientID forHTTPHeaderField:@"Client-ID"];
    return req;
}

- (void)loadGlobalBadges {
    NSURL *url = [NSURL URLWithString:kS7TVGlobalBadgesURL];
    if (!url) return;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!mgr.twitchToken.length) {
        [mgr log:@"⏳ Badges global: token pas encore dispo, attente GQL..."];
        return; // saveTwitchToken:clientID: rappellera loadGlobalBadges dès que le token arrive
    }

    [mgr log:@"🏗 Badges: chargement catalogue global"];

    __weak typeof(self) weakSelf = self;
    NSURLRequest *req = [self s7tv_helixRequestWithURL:url];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *parsed =
            [strongSelf s7tv_parseBadgeSetsFromData:data error:error];
        if (!parsed) return; // déjà logué dans le parsing, no-op silencieux sinon

        dispatch_barrier_async(strongSelf.badgeQueue, ^{
            strongSelf.globalBadges = parsed;
            // Voir S7TVBadgesCatalogUpdatedNotification (header) : sans ce
            // reload, les messages déjà rendus avant la fin de ce fetch
            // n'auraient jamais leurs badges appliqués.
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVBadgesCatalogUpdatedNotification object:nil];
            });
        });
        [[SevenTVManager sharedManager]
            log:@"🏗 Badges globaux chargés (%lu sets)", (unsigned long)parsed.count];
    }];
    [task resume];
}

- (void)loadBadgesForChannelID:(NSString *)channelID {
    if (!channelID.length) return;

    // Évite un refetch identique si plusieurs ROOMSTATE arrivent pour la
    // même chaîne (ex: reconnexion WebSocket sans vrai changement de
    // channel) — pas une exigence stricte, juste évite du réseau superflu.
    if ([channelID isEqualToString:self.lastLoadedChannelID]) return;

    NSURL *url = [NSURL URLWithString:S7TVChannelBadgesURL(channelID)];
    if (!url) return;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!mgr.twitchToken.length) {
        // CRITIQUE : ne PAS marquer lastLoadedChannelID ici. S7TVChannelJoined
        // arrive souvent avant que le token (capturé depuis les headers GQL)
        // ne soit disponible — si on marquait la chaîne comme "chargée"
        // maintenant, le rattrapage fait par -[SevenTVManager saveTwitchToken:
        // clientID:] (qui rappelle loadBadgesForChannelID: dès que le token
        // arrive) serait bloqué par le garde-fou ci-dessus, alors qu'aucun
        // fetch n'a jamais réellement eu lieu. C'était la cause des badges de
        // sub (channel-only, pas de repli global côté Twitch pour ce set)
        // manquants alors que les badges globaux (mod/VIP/turbo) s'affichaient.
        [mgr log:@"⏳ Badges channel: token pas encore dispo, attente GQL..."];
        return;
    }

    // On ne marque la chaîne comme "chargée" qu'une fois certain qu'un vrai
    // fetch part — sinon un appel prématuré (token pas encore prêt) bloquerait
    // silencieusement le rattrapage ultérieur (voir commentaire ci-dessus).
    self.lastLoadedChannelID = channelID;

    [mgr log:@"🏗 Badges: chargement catalogue channel %@", channelID];

    __weak typeof(self) weakSelf = self;
    NSURLRequest *req = [self s7tv_helixRequestWithURL:url];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *parsed =
            [strongSelf s7tv_parseBadgeSetsFromData:data error:error];
        if (!parsed) return;

        dispatch_barrier_async(strongSelf.badgeQueue, ^{
            strongSelf.channelBadges = parsed;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:S7TVBadgesCatalogUpdatedNotification object:nil];
            });
        });
        [[SevenTVManager sharedManager]
            log:@"🏗 Badges channel chargés (%lu sets) pour %@",
            (unsigned long)parsed.count, channelID];
    }];
    [task resume];
}

// Parsing robuste (exigence transverse Phase 1a) : réponse absente, non-200,
// JSON invalide ou structure inattendue → nil + log, jamais de crash.
// Format Helix : { "data": [ { "set_id": "<setID>", "versions": [
//   { "id": "<version>", "image_url_4x": "...", ... } ] } ] }
- (nullable NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)
    s7tv_parseBadgeSetsFromData:(NSData *)data error:(NSError *)networkError {
    if (networkError || !data.length) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ Badges: échec réseau (%@)",
            networkError.localizedDescription ?: @"réponse vide"];
        return nil;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![root isKindOfClass:[NSDictionary class]]) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ Badges: JSON invalide (%@)", jsonError.localizedDescription ?: @"racine non-objet"];
        return nil;
    }

    // Helix retourne { "data": [ ... ] } — tableau à la racine
    NSArray *dataArray = [(NSDictionary *)root objectForKey:@"data"];
    if (![dataArray isKindOfClass:[NSArray class]]) {
        // Pas de clé "data" → très probablement une erreur Helix (401/403,
        // token expiré) plutôt qu'un catalogue vide.
        [[SevenTVManager sharedManager]
            log:@"⚠️ Badges: réponse Helix sans clé \"data\" (token invalide/expiré ?)"];
        return @{};
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *result =
        [NSMutableDictionary dictionaryWithCapacity:dataArray.count];

    for (NSDictionary *set in dataArray) {
        if (![set isKindOfClass:[NSDictionary class]]) continue;

        NSString *setID = set[@"set_id"];
        if (![setID isKindOfClass:[NSString class]] || !setID.length) continue;

        NSArray *versions = set[@"versions"];
        if (![versions isKindOfClass:[NSArray class]]) continue;

        NSMutableDictionary<NSString *, NSString *> *versionToURL =
            [NSMutableDictionary dictionaryWithCapacity:versions.count];

        for (NSDictionary *versionEntry in versions) {
            if (![versionEntry isKindOfClass:[NSDictionary class]]) continue;

            NSString *versionID = versionEntry[@"id"];
            NSString *imageURL  = versionEntry[kS7TVBadgeImageURLKey];

            if ([versionID isKindOfClass:[NSString class]] && versionID.length &&
                [imageURL  isKindOfClass:[NSString class]] && imageURL.length) {
                versionToURL[versionID] = imageURL;
            }
        }
        if (versionToURL.count) result[setID] = [versionToURL copy];
    }

    return [result copy];
}

#pragma mark - Reset au changement de chaîne

- (void)resetChannelBadges {
    dispatch_barrier_async(self.badgeQueue, ^{
        self.channelBadges = @{};
    });
    [[SevenTVManager sharedManager] log:@"🏗 Badges channel réinitialisés (changement de chaîne)"];
}

#pragma mark - Résolution

- (void)s7tv_loadSharedChatAvatarForChannelID:(NSString *)channelID {
    if (!channelID.length) return;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!mgr.twitchToken.length || !mgr.twitchClientID.length) {
        // Ne pas marquer comme "en cours" : le chargement des catalogues de
        // badges, relancé à la capture du token, provoquera un nouveau rendu.
        return;
    }

    __block BOOL shouldFetch = NO;
    NSDate *now = [NSDate date];
    dispatch_barrier_sync(self.badgeQueue, ^{
        NSDate *retryAfter = self.sharedChatAvatarRetryAfter[channelID];
        BOOL retryAllowed = !retryAfter || [retryAfter compare:now] != NSOrderedDescending;
        if (!self.sharedChatAvatarURLs[channelID] &&
            ![self.fetchingSharedChatAvatarChannelIDs containsObject:channelID] &&
            retryAllowed) {
            [self.fetchingSharedChatAvatarChannelIDs addObject:channelID];
            shouldFetch = YES;
        }
    });
    if (!shouldFetch) return;

    NSURL *url = S7TVUserURL(channelID);
    if (!url) {
        dispatch_barrier_async(self.badgeQueue, ^{
            [self.fetchingSharedChatAvatarChannelIDs removeObject:channelID];
        });
        return;
    }

    NSURLRequest *request = [self s7tv_helixRequestWithURL:url];
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
        dispatch_barrier_async(strongSelf.badgeQueue, ^{
            [strongSelf.fetchingSharedChatAvatarChannelIDs removeObject:channelID];
            if (succeeded) {
                NSMutableDictionary *updated = [strongSelf.sharedChatAvatarURLs mutableCopy];
                updated[channelID] = avatarURLString;
                strongSelf.sharedChatAvatarURLs = [updated copy];
                [strongSelf.sharedChatAvatarRetryAfter removeObjectForKey:channelID];
            } else {
                // Évite une rafale de requêtes si Helix/token est temporairement
                // indisponible pendant que plusieurs cellules sont rendues.
                strongSelf.sharedChatAvatarRetryAfter[channelID] =
                    [NSDate dateWithTimeIntervalSinceNow:30.0];
            }

            if (succeeded) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:S7TVBadgesCatalogUpdatedNotification object:nil];
                });
            }
        });

        if (!succeeded) {
            [[SevenTVManager sharedManager] log:
                @"⚠️ Avatar Shared Chat: échec Helix pour la chaîne %@ (HTTP %ld, %@)",
                channelID, (long)statusCode, error.localizedDescription ?: @"réponse invalide"];
        }
    }];
    [task resume];
}

- (nullable id<S7TVResolvedEmote>)resolvedChannelAvatarForChannelID:(NSString *)channelID {
    if (!channelID.length) return nil;

    __block NSString *imageURLString = nil;
    dispatch_sync(self.badgeQueue, ^{
        imageURLString = self.sharedChatAvatarURLs[channelID];
    });
    if (!imageURLString.length) {
        [self s7tv_loadSharedChatAvatarForChannelID:channelID];
        return nil;
    }

    NSURL *url = [NSURL URLWithString:imageURLString];
    if (!url) return nil;

    S7TVResolvedBadge *avatar = [S7TVResolvedBadge new];
    avatar.emoteID = [@"shared-chat-avatar/" stringByAppendingString:channelID];
    avatar.nativeSize = CGSizeMake(1, 1);
    avatar.isAnimated = NO;
    avatar.imageURL = url;
    avatar.rendersCircular = YES;
    return avatar;
}

- (nullable id<S7TVResolvedEmote>)resolvedSharedChatAvatarForChannelID:(NSString *)channelID {
    return [self resolvedChannelAvatarForChannelID:channelID];
}

- (nullable id<S7TVResolvedEmote>)resolvedBadgeForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;

    NSRange slash = [identifier rangeOfString:@"/"];
    if (slash.location == NSNotFound) return nil; // format inattendu, jamais planter

    NSString *setID   = [identifier substringToIndex:slash.location];
    NSString *version = [identifier substringFromIndex:slash.location + 1];
    if (!setID.length || !version.length) return nil;

    __block NSString *imageURLString = nil;
    dispatch_sync(self.badgeQueue, ^{
        // Channel d'abord (peut surcharger, ex: sub badge custom de la
        // chaîne), sinon repli sur le global.
        imageURLString = self.channelBadges[setID][version] ?: self.globalBadges[setID][version];
    });
    if (!imageURLString.length) return nil;

    NSURL *url = [NSURL URLWithString:imageURLString];
    if (!url) return nil;

    S7TVResolvedBadge *badge = [S7TVResolvedBadge new];
    badge.emoteID = identifier;
    // Tous les badges Twitch (sub/mod/VIP/custom) sont carrés — même
    // raisonnement de fallback que S7TVTwitchNativeEmoteFactory pour les
    // emotes natives (voir 7tv-emote-provider.m), pas une approximation
    // risquée ici puisque c'est systématiquement vrai pour ce type d'asset.
    badge.nativeSize = CGSizeMake(1, 1);
    badge.isAnimated = NO;
    badge.imageURL = url;
    return badge;
}

@end
