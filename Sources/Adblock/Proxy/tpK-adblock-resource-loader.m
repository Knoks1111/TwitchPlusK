#import "Adblock/Proxy/tpK-adblock-resource-loader.h"
#import "Adblock/Proxy/tpK-adblock-proxy.h"
#import "Adblock/tpK-adblock-settings.h"

@implementation TPKAdblockResourceLoader

+ (instancetype)sharedLoader {
    static TPKAdblockResourceLoader *loader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ loader = [TPKAdblockResourceLoader new]; });
    return loader;
}

- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *URL = loadingRequest.request.URL;
    if (![URL.scheme isEqualToString:@"tpk-adblock"]) return NO;
    NSURLComponents *components = [NSURLComponents
        componentsWithURL:URL resolvingAgainstBaseURL:YES];
    components.scheme = @"https";
    NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
    request.URL = components.URL;

    NSString *proxyAddress = TPKAdblockEffectiveProxyAddresses().firstObject;
    if (!proxyAddress.length) {
        NSError *error = [NSError errorWithDomain:@"TwitchPlusK.Adblock"
            code:1 userInfo:@{NSLocalizedDescriptionKey: @"No usable video proxy configured"}];
        [loadingRequest finishLoadingWithError:error];
        return YES;
    }
    NSURLSession *session = TPKAdblockProxySession(
        [NSURLSession sessionWithConfiguration:
         NSURLSessionConfiguration.ephemeralSessionConfiguration], proxyAddress);
    [[session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) {
                [loadingRequest finishLoadingWithError:error ?: [NSError
                    errorWithDomain:@"TwitchPlusK.Adblock" code:2
                    userInfo:@{NSLocalizedDescriptionKey: @"Empty proxy response"}]];
                return;
            }
            AVAssetResourceLoadingContentInformationRequest *information =
                loadingRequest.contentInformationRequest;
            information.contentType = AVFileTypeMPEG4;
            information.contentLength = response.expectedContentLength >= 0
                ? response.expectedContentLength : (long long)data.length;
            information.byteRangeAccessSupported = NO;
            [loadingRequest.dataRequest respondWithData:data];
            [loadingRequest finishLoading];
        }] resume];
    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    return [self handleLoadingRequest:loadingRequest];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self handleLoadingRequest:renewalRequest];
}

@end
