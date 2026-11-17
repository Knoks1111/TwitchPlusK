#import "Chat/Emote/tpK-chat-emotes.h"
#import "Emote/tpK-emote-image-transport.h"
#include <math.h>

NSString *TPKChatEmoteIdentifier(NSURL *url, CGSize size) {
    NSString *encoded = [[url.absoluteString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    encoded = [[encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    CGFloat ratio = size.height > 0 ? size.width / size.height : 1;
    if (!isfinite(ratio) || ratio <= 0) ratio = 1;
    return [NSString stringWithFormat:@"tpk_r%ld_%@", (long)lround(MIN(5, MAX(.125, ratio)) * 1000),
        [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""]];
}

NSURLRequest *TPKChatEmotesImageRequest(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (![url.host.lowercaseString isEqualToString:@"static-cdn.jtvnw.net"] ||
        ![request.HTTPMethod isEqualToString:@"GET"]) return request;
    NSArray<NSString *> *parts = url.pathComponents;
    BOOL nativeRoute = (parts.count == 7 && [parts[2] isEqualToString:@"v2"]) ||
        (parts.count == 5 && [parts[2] isEqualToString:@"v1"]);
    if (!nativeRoute || ![parts[1] isEqualToString:@"emoticons"] ||
        ![parts[3] hasPrefix:@"tpk_"] || parts[3].length > 1400) return request;
    NSString *payload = [parts[3] substringFromIndex:4];
    if ([payload hasPrefix:@"r"]) {
        NSRange separator = [payload rangeOfString:@"_"];
        if (separator.location == NSNotFound) return request;
        NSString *digits = [payload substringWithRange:NSMakeRange(1, separator.location - 1)];
        if (!digits.length || digits.length > 4 ||
            [digits rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound ||
            digits.integerValue < 125 || digits.integerValue > 5000) return request;
        payload = [payload substringFromIndex:separator.location + 1];
    }
    NSString *encoded = [payload stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (encoded.length % 4) encoded = [encoded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSURL *image = text ? [NSURL URLWithString:text] : nil;
    if (!TPKEmoteImageProviderURL(image)) return request;
    // Do not forward Twitch cookies or authorization headers to provider CDNs.
    return [NSURLRequest requestWithURL:image cachePolicy:request.cachePolicy timeoutInterval:request.timeoutInterval];
}
