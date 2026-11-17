#import "Chat/Emote/UIKit/VOD/tpK-chat-vod-emotes.h"
#import "Chat/Emote/tpK-chat-emotes.h"
#import "Core/tpK-channel-resolver.h"
#import "Core/tpK-core-manager.h"
#import "Emote/tpK-emote-catalog.h"
#import "Settings/tpK-chat-appearance-config.h"
#import <objc/runtime.h>

static const NSUInteger TPKVODLimit = 8 * 1024 * 1024;
static char bufferKey, bypassKey, requestKey, contextKey;

static void VODLog(NSString *stage, NSUInteger value) {
    TPKManager *manager = TPKManager.sharedManager;
    if (manager.logsEnabled && manager.logChat)
        [manager log:@"[Chat] 🧪 VOD emotes: %@=%lu", stage, (unsigned long)value];
}

static void VODWarning(NSString *stage, NSInteger value) {
    TPKManager *manager = TPKManager.sharedManager;
    if (manager.logsEnabled && manager.logErrors)
        [manager log:@"⚠️ VOD emotes: %@=%ld", stage, (long)value];
}

static NSArray *VODOperations(NSURLRequest *request) {
    if (![request.URL.host.lowercaseString isEqualToString:@"gql.twitch.tv"] ||
        ![request.HTTPMethod isEqualToString:@"POST"] ||
        !request.HTTPBody.length || request.HTTPBody.length > 65536) return nil;
    id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    NSArray *operations = [body isKindOfClass:NSArray.class] ? body : body ? @[body] : @[];
    if (!operations.count || operations.count > 32) return nil;
    BOOL found = NO;
    for (id operation in operations) {
        if (![operation isKindOfClass:NSDictionary.class]) return nil;
        NSString *name = operation[@"operationName"];
        if ([name isEqual:@"VideoByIdentifier"] ||
            (TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled &&
             ([name isEqual:@"VideoCommentsByContentOffset"] || [name isEqual:@"VideoCommentsByCursor"]))) found = YES;
    }
    return found ? operations : nil;
}

static NSArray *VODFragments(NSArray *fragments, NSString *(^resolve)(NSString *)) {
    NSMutableArray *result = nil;
    NSUInteger offset = 0, fragmentIndex = 0;
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (id fragment in fragments) {
        if (![fragment isKindOfClass:NSDictionary.class] || ![fragment[@"text"] isKindOfClass:NSString.class]) return fragments;
        NSString *text = fragment[@"text"];
        if (text.length > 65536 || offset > 1048576) return fragments;
        BOOL plain = !fragment[@"emote"] || fragment[@"emote"] == NSNull.null;
        plain &= !fragment[@"mention"] || fragment[@"mention"] == NSNull.null;
        NSMutableArray *pieces = nil;
        NSUInteger start = 0, copied = 0;
        while (plain && start < text.length) {
            if ([spaces characterIsMember:[text characterAtIndex:start]]) { ++start; continue; }
            NSUInteger end = start + 1;
            while (end < text.length && ![spaces characterIsMember:[text characterAtIndex:end]]) ++end;
            NSString *word = [text substringWithRange:NSMakeRange(start, end - start)];
            NSString *identifier = resolve(word);
            if (identifier) {
                if (!pieces) pieces = [NSMutableArray array];
                if (start > copied) {
                    NSMutableDictionary *prefix = [fragment mutableCopy];
                    prefix[@"text"] = [text substringWithRange:NSMakeRange(copied, start - copied)];
                    [pieces addObject:prefix];
                }
                NSMutableDictionary *image = [fragment mutableCopy];
                image[@"text"] = word;
                NSUInteger from = offset + start, to = offset + end - 1;
                NSString *fragmentID = [NSString stringWithFormat:@"%@;%lu;%lu", identifier, (unsigned long)from, (unsigned long)to];
                image[@"emote"] = @{@"__typename":@"EmbeddedEmote", @"id":fragmentID,
                    @"emoteID":identifier, @"setID":NSNull.null,
                    @"from":@(from), @"to":@(to)};
                [pieces addObject:image];
                copied = end;
            }
            start = end;
        }
        if (pieces) {
            if (copied < text.length) {
                NSMutableDictionary *suffix = [fragment mutableCopy];
                suffix[@"text"] = [text substringFromIndex:copied];
                [pieces addObject:suffix];
            }
            if (!result) { result = [NSMutableArray array]; [result addObjectsFromArray:[fragments subarrayWithRange:NSMakeRange(0, fragmentIndex)]]; }
        }
        if (result) [result addObjectsFromArray:pieces ?: @[fragment]];
        offset += text.length;
        ++fragmentIndex;
    }
    return result ?: fragments;
}

static NSData *VODTransform(NSData *data, NSURLRequest *request, TPKChannelContext *context) {
    NSArray *operations = VODOperations(request);
    if (!operations || !data.length || data.length > TPKVODLimit) return data;
    VODLog(@"response bytes", data.length);
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    NSArray *responses = [json isKindOfClass:NSArray.class] ? json : json ? @[json] : @[];
    if (responses.count != operations.count) { VODWarning(@"invalid response batch", responses.count); return data; }
    BOOL commentsRequested = NO;
    for (NSUInteger index = 0; index < responses.count; ++index) {
        NSDictionary *operation = operations[index];
        id response = responses[index];
        if ([operation[@"operationName"] isEqual:@"VideoByIdentifier"] && [response isKindOfClass:NSDictionary.class]) {
            id root = response[@"data"];
            id variables = operation[@"variables"];
            if ([root isKindOfClass:NSDictionary.class] && [variables isKindOfClass:NSDictionary.class])
                TPKChannelResolverNoteVideoMetadata(root[@"video"], variables[@"id"]);
        } else if ([operation[@"operationName"] isEqual:@"VideoCommentsByContentOffset"] ||
                   [operation[@"operationName"] isEqual:@"VideoCommentsByCursor"]) commentsRequested = YES;
    }
    if (!commentsRequested || !TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled) return data;
    if (context && !TPKChannelContextIsCurrent(context)) { VODLog(@"stale context", 1); return data; }
    TPKEmoteCatalog *catalog = TPKEmoteCatalog.sharedCatalog;
    NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
    NSMutableSet *channels = [NSMutableSet set];
    for (NSNumber *provider in catalog.providerPriority) {
        TPKEmoteProviderSnapshot *snapshot = [catalog snapshotForProvider:provider.integerValue];
        BOOL channel = context.mediaKind == TPKChannelMediaKindReplay &&
            [snapshot.channelID isEqualToString:[NSString stringWithFormat:@"%u", context.channelID]];
        if (channel) [channels addObject:provider];
    }
    NSInteger resolution = TPKChatAppearanceConfig.sharedConfig.emoteImageResolution;
    NSString *(^resolve)(NSString *) = ^NSString *(NSString *word) {
        id cached = resolved[word];
        if (cached) return cached == NSNull.null ? nil : cached;
        TPKEmoteDescriptor *emote = [catalog resolveEmoteNamed:word];
        if (emote.sectionKind != TPKEmoteSectionKindGlobal && ![channels containsObject:@(emote.provider)]) emote = nil;
        NSURL *url = [emote imageURLForResolution:resolution];
        NSString *identifier = url && url.absoluteString.length <= 1024 ? TPKChatEmoteIdentifier(url, emote.nativeSize) : nil;
        if (resolved.count < 4096) resolved[word] = identifier ?: (id)NSNull.null;
        return identifier;
    };
    BOOL changed = NO;
    NSUInteger comments = 0, fragmentCount = 0;
    for (NSUInteger index = 0; index < responses.count; ++index) {
        NSString *name = operations[index][@"operationName"];
        if (![name isEqual:@"VideoCommentsByContentOffset"] && ![name isEqual:@"VideoCommentsByCursor"]) continue;
        id response = responses[index];
        if (![response isKindOfClass:NSDictionary.class]) continue;
        id node = response;
        for (NSString *key in @[@"data", @"video", @"comments"])
            node = [node isKindOfClass:NSDictionary.class] ? node[key] : nil;
        id edges = [node isKindOfClass:NSDictionary.class] ? node[@"edges"] : nil;
        if (![edges isKindOfClass:NSArray.class] || [edges count] > 4096) continue;
        comments += [edges count];
        for (id edge in edges) {
            if (![edge isKindOfClass:NSDictionary.class]) continue;
            id node = edge[@"node"];
            id message = [node isKindOfClass:NSDictionary.class] ? node[@"message"] : nil;
            if (![message isKindOfClass:NSMutableDictionary.class]) continue;
            NSArray *fragments = message[@"messageFragments"];
            if (![fragments isKindOfClass:NSArray.class]) continue;
            fragmentCount += fragments.count;
            NSArray *updated = VODFragments(fragments, resolve);
            if (updated != fragments) { message[@"messageFragments"] = updated; changed = YES; }
        }
    }
    if (context && !TPKChannelContextIsCurrent(context)) return data;
    VODLog(@"comments", comments);
    VODLog(@"fragments", fragmentCount);
    VODLog(@"eligible channel providers", channels.count);
    VODLog(@"enriched", changed);
    if (changed && TPKManager.sharedManager.logsEnabled && TPKManager.sharedManager.logChat)
        [TPKManager.sharedManager log:@"[Chat] 🧪 VOD emotes: response enriched (channel scope=%@)", channels.count ? @"yes" : @"no"];
    return changed ? ([NSJSONSerialization dataWithJSONObject:json options:0 error:nil] ?: data) : data;
}

NSData *TPKVODEmotesTransform(NSData *data, NSURLRequest *request) {
    return VODTransform(data, request, TPKCurrentChannelContext());
}

void TPKVODEmotesTrack(NSURLSessionTask *task, NSURLRequest *request) {
    if (!task || !VODOperations(request)) return;
    VODLog(@"request tracked", 1);
    dispatch_async(dispatch_get_main_queue(), ^{ TPKChannelResolverRefresh(); });
    objc_setAssociatedObject(task, &requestKey, request.copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &contextKey, TPKCurrentChannelContext() ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void TPKVODEmotesNoteSession(NSURLSessionTask *task, NSURLSession *session) {
    if (!objc_getAssociatedObject(task, &requestKey)) return;
    TPKManager *manager = TPKManager.sharedManager;
    if (!manager.logsEnabled || !manager.logChat) return;
    id delegate = session.delegate;
    [manager log:@"[Chat] 🧪 VOD transport: delegate=%@ data=%d completion=%d",
        delegate ? NSStringFromClass([delegate class]) : @"none",
        [delegate respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)],
        [delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]];
}

BOOL TPKVODEmotesReceive(NSURLSessionDataTask *task, NSData *data, void (^flush)(NSData *)) {
    if ([objc_getAssociatedObject(task, &bypassKey) boolValue]) return NO;
    NSMutableData *buffer = objc_getAssociatedObject(task, &bufferKey);
    NSURLRequest *request = objc_getAssociatedObject(task, &requestKey) ?: task.originalRequest ?: task.currentRequest;
    if (!buffer && !VODOperations(request)) {
        objc_setAssociatedObject(task, &bypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (!buffer) {
        if (!objc_getAssociatedObject(task, &requestKey)) TPKVODEmotesTrack(task, request);
        buffer = [NSMutableData data];
        objc_setAssociatedObject(task, &bufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (data.length > TPKVODLimit - buffer.length) {
        objc_setAssociatedObject(task, &bufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(task, &bypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (buffer.length) flush(buffer);
        return NO;
    }
    [buffer appendData:data];
    return YES;
}

NSData *TPKVODEmotesComplete(NSURLSessionTask *task, NSError *error) {
    NSData *data = objc_getAssociatedObject(task, &bufferKey);
    objc_setAssociatedObject(task, &bypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (data) dispatch_async(dispatch_get_main_queue(), ^{ TPKChannelResolverRefresh(); });
    if (data && error) VODWarning(@"completion error", error.code);
    else if (data) VODLog(@"completed bytes", data.length);
    NSURLRequest *request = objc_getAssociatedObject(task, &requestKey) ?: task.originalRequest ?: task.currentRequest;
    id context = objc_getAssociatedObject(task, &contextKey);
    objc_setAssociatedObject(task, &bufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &requestKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &contextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data && !error ? VODTransform(data, request, context == NSNull.null ? nil : context) : data;
}
