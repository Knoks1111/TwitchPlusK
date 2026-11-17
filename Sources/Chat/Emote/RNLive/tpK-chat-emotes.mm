#import "Chat/Emote/tpK-chat-emotes.h"
#import "Core/tpK-core-manager.h"
#import "Emote/tpK-emote-catalog.h"
#import "Emote/tpK-emote-image-transport.h"
#import "Settings/tpK-chat-appearance-config.h"
#include <string>
#include <vector>
#include <functional>
#include <charconv>
#include <cstdint>

// IRC ranges count Unicode code points, not UTF-8 bytes or UTF-16 units.
namespace TPKChatIRC {
using Resolve = std::function<std::string(const std::string &, const std::string &, const std::string &)>;
static bool Number(const std::string &text, size_t &value) {
    if (text.empty()) return false;
    auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    return result.ec == std::errc() && result.ptr == text.data() + text.size();
}
static bool Space(uint32_t c) {
    return c == 32 || (c >= 9 && c <= 13) || c == 0x85 || c == 0xa0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}
static bool Decode(const std::string &s, size_t &offset, uint32_t &c) {
    unsigned char lead = s[offset++];
    c = lead;
    if (lead < 128) return true;
    unsigned count = lead >= 0xc2 && lead <= 0xdf ? 1 : lead >= 0xe0 && lead <= 0xef ? 2 :
        lead >= 0xf0 && lead <= 0xf4 ? 3 : 0;
    if (!count || offset + count > s.size()) return false;
    c = lead & ((1u << (6 - count)) - 1);
    for (unsigned i = 0; i < count; ++i) {
        unsigned char next = s[offset++];
        if ((next & 0xc0) != 0x80) return false;
        c = (c << 6) | (next & 0x3f);
    }
    return c >= (count == 1 ? 0x80u : count == 2 ? 0x800u : 0x10000u) &&
        c <= 0x10ffff && !(c >= 0xd800 && c <= 0xdfff);
}
static std::string Line(const std::string &line, const Resolve &resolve) {
    if (line.empty() || line.size() > 65536 || line[0] != '@') return line;
    size_t tagsEnd = line.find(' '), cursor = tagsEnd;
    if (tagsEnd == std::string::npos) return line;
    while (cursor < line.size() && line[cursor] == ' ') ++cursor;
    if (cursor < line.size() && line[cursor] == ':') {
        cursor = line.find(' ', cursor);
        if (cursor == std::string::npos) return line;
        while (cursor < line.size() && line[cursor] == ' ') ++cursor;
    }
    size_t commandEnd = line.find(' ', cursor);
    if (commandEnd == std::string::npos) return line;
    std::string command = line.substr(cursor, commandEnd - cursor);
    if (command != "PRIVMSG" && command != "USERNOTICE") return line;
    cursor = commandEnd + 1;
    size_t targetEnd = line.find(' ', cursor);
    if (targetEnd == std::string::npos || line[cursor] != '#' || targetEnd == cursor + 1) return line;
    std::string channel = line.substr(cursor + 1, targetEnd - cursor - 1);
    size_t bodyStart = line.find(" :", targetEnd);
    if (bodyStart == std::string::npos) return line;
    bodyStart += 2;
    std::string body = line.substr(bodyStart), emotes, room;
    size_t emoteStart = std::string::npos, emoteLength = 0;
    for (size_t start = 1; start < tagsEnd;) {
        size_t end = line.find(';', start);
        if (end == std::string::npos || end > tagsEnd) end = tagsEnd;
        std::string tag = line.substr(start, end - start);
        if (tag.compare(0, 7, "emotes=") == 0) {
            if (emoteStart != std::string::npos) return line;
            emotes = tag.substr(7); emoteStart = start + 7; emoteLength = end - emoteStart;
        } else if (tag.compare(0, 8, "room-id=") == 0) room = tag.substr(8);
        start = end + 1;
    }
    std::vector<std::pair<size_t, size_t>> occupied;
    for (size_t start = 0; start < emotes.size();) {
        size_t end = emotes.find('/', start);
        if (end == std::string::npos) end = emotes.size();
        size_t colon = emotes.find(':', start);
        if (colon == std::string::npos || colon >= end) return line;
        for (size_t pos = colon + 1; pos < end;) {
            size_t comma = emotes.find(',', pos);
            if (comma == std::string::npos || comma > end) comma = end;
            size_t dash = emotes.find('-', pos), first = 0, last = 0;
            if (dash == std::string::npos || dash >= comma || !Number(emotes.substr(pos, dash-pos), first) ||
                !Number(emotes.substr(dash+1, comma-dash-1), last) || first > last) return line;
            occupied.emplace_back(first, last); pos = comma + 1;
        }
        start = end + 1;
    }
    // ACTION positions are relative to the displayed body, as in native parsePrivmsgLine.
    if (body.compare(0, 8, "\001ACTION ") == 0 && body.back() == '\001') body = body.substr(8, body.size()-9);
    std::string additions;
    size_t offset = 0, codepoint = 0, tokenByte = 0, tokenPoint = 0;
    bool token = false;
    auto finish = [&] {
        if (!token) return;
        token = false;
        for (const auto &range : occupied)
            if (tokenPoint <= range.second && codepoint > range.first) return;
        std::string id = resolve(channel, room, body.substr(tokenByte, offset-tokenByte));
        if (id.empty()) return;
        if (!additions.empty()) additions += '/';
        additions += id + ':' + std::to_string(tokenPoint) + '-' + std::to_string(codepoint-1);
    };
    while (offset < body.size()) {
        size_t before = offset;
        uint32_t c;
        if (!Decode(body, offset, c)) return line;
        if (Space(c)) {
            size_t after = offset; offset = before; finish(); offset = after;
        } else if (!token) { token = true; tokenByte = before; tokenPoint = codepoint; }
        ++codepoint;
    }
    finish();
    if (additions.empty()) return line;
    if (!emotes.empty()) additions = emotes + '/' + additions;
    std::string result = line;
    if (emoteStart == std::string::npos) result.insert(tagsEnd, ";emotes=" + additions);
    else result.replace(emoteStart, emoteLength, additions);
    return result;
}
static std::string Frame(const std::string &text, const Resolve &resolve) {
    if (text.size() > 1048576) return text;
    std::string output;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        size_t contentEnd = end > start && text[end-1] == '\r' ? end-1 : end;
        output += Line(text.substr(start, contentEnd-start), resolve);
        output.append(text, contentEnd, end-contentEnd);
        if (end < text.size()) output += '\n';
        start = end + 1;
    }
    return output;
}
} // namespace TPKChatIRC

static BOOL ProviderURL(NSURL *url) {
    return TPKEmoteImageProviderURL(url);
}

@protocol TPKChatSocketURL <NSObject>
- (NSURL *)url;
@end

id TPKChatEmotesReceive(id socket, id message) {
    @autoreleasepool {
    if (!TPKChatAppearanceConfig.sharedConfig.nativeEmotesEnabled) return message;
    NSURL *url = [socket isKindOfClass:NSURLRequest.class] ? [(NSURLRequest *)socket URL] :
        [socket respondsToSelector:@selector(url)] ? [(id<TPKChatSocketURL>)socket url] : nil;
    if (![url isKindOfClass:NSURL.class] || ![@[@"irc-ws.chat.twitch.tv", @"irc.chat.twitch.tv"] containsObject:url.host.lowercaseString]) return message;
    BOOL binary = [message isKindOfClass:NSData.class];
    NSString *text = binary ? [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding] :
        [message isKindOfClass:NSString.class] ? message : nil;
    if (!text.length) return message;
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    std::string original((const char *)bytes.bytes, bytes.length);
    TPKManager *manager = TPKManager.sharedManager;
    NSString *login = manager.currentChannelName.lowercaseString, *channelID = manager.currentChannelTwitchID;
    TPKEmoteCatalog *catalog = TPKEmoteCatalog.sharedCatalog;
    NSInteger resolution = TPKChatAppearanceConfig.sharedConfig.emoteImageResolution;
    NSMutableDictionary<NSString *, NSString *> *resolved = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *providerChannels = [NSMutableDictionary dictionary];
    @try {
        std::string enriched = TPKChatIRC::Frame(original, [&](const std::string &channel, const std::string &room, const std::string &word) {
            NSString *target = [NSString stringWithUTF8String:channel.c_str()];
            NSString *roomID = [NSString stringWithUTF8String:room.c_str()];
            if (!login.length || ![login isEqualToString:target.lowercaseString] ||
                (roomID.length && ![channelID isEqualToString:roomID])) return std::string();
            NSString *name = [[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding];
            if (resolved[name]) return std::string(resolved[name].UTF8String);
            TPKEmoteDescriptor *emote = [catalog resolveEmoteNamed:name];
            if (!emote) return std::string();
            if (emote.sectionKind != TPKEmoteSectionKindGlobal) {
                NSNumber *provider = @(emote.provider);
                if (!providerChannels[provider]) providerChannels[provider] = [catalog snapshotForProvider:emote.provider].channelID ?: @"";
                if (![providerChannels[provider] isEqualToString:channelID]) return std::string();
            }
            NSURL *image = [emote imageURLForResolution:resolution];
            if (!ProviderURL(image) || image.absoluteString.length > 1024) return std::string();
            NSString *identifier = TPKChatEmoteIdentifier(image, emote.nativeSize);
            resolved[name] = identifier;
            return std::string(identifier.UTF8String);
        });
        if (enriched == original) return message;
        NSData *data = [NSData dataWithBytes:enriched.data() length:enriched.size()];
        return binary ? data : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @catch (__unused NSException *exception) { return message; }
    }
}
