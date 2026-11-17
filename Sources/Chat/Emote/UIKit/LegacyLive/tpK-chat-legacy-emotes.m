#import "Chat/Emote/tpK-chat-emotes.h"

NSURLSessionWebSocketMessage *TPKChatEmotesReceiveLegacy(NSURLSessionWebSocketTask *task, NSURLSessionWebSocketMessage *message) {
    id original = message.type == NSURLSessionWebSocketMessageTypeString ? message.string : message.data;
    if (!original) return message;
    id enriched = TPKChatEmotesReceive(task.originalRequest ?: task.currentRequest, original);
    if (enriched == original) return message;
    return [enriched isKindOfClass:NSString.class]
        ? [[NSURLSessionWebSocketMessage alloc] initWithString:enriched]
        : [[NSURLSessionWebSocketMessage alloc] initWithData:enriched];
}
