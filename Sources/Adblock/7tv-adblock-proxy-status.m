#import "Adblock/7tv-adblock-proxy-status.h"
#import "Adblock/7tv-adblock-settings.h"
#import <os/log.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

// Copie adaptée de twab_tcpConnectReachable (TwitchAdBlock v0.1.13).
static BOOL S7TVAdblockTCPConnectReachable(NSString *host, int port, int timeoutSeconds) {
    if (!host.length || port <= 0) return NO;
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portString[16];
    snprintf(portString, sizeof(portString), "%d", port);
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host.UTF8String, portString, &hints, &addresses) != 0 || !addresses) {
        return NO;
    }

    BOOL connected = NO;
    for (struct addrinfo *address = addresses;
         address && !connected;
         address = address->ai_next) {
        int socketDescriptor = socket(address->ai_family,
                                      address->ai_socktype,
                                      address->ai_protocol);
        if (socketDescriptor < 0) continue;
        int flags = fcntl(socketDescriptor, F_GETFL, 0);
        fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK);

        int result = connect(socketDescriptor, address->ai_addr, address->ai_addrlen);
        if (result == 0) {
            connected = YES;
        } else if (errno == EINPROGRESS) {
            fd_set writable;
            FD_ZERO(&writable);
            FD_SET(socketDescriptor, &writable);
            struct timeval timeout = { timeoutSeconds, 0 };
            int selected = select(socketDescriptor + 1, NULL, &writable, NULL, &timeout);
            if (selected > 0) {
                int error = 0;
                socklen_t length = sizeof(error);
                if (getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR,
                               &error, &length) == 0 && error == 0) {
                    connected = YES;
                }
            }
        }
        close(socketDescriptor);
    }
    freeaddrinfo(addresses);
    return connected;
}

void S7TVAdblockCheckProxyStatus(
    NSString *address,
    void (^completion)(S7TVAdblockProxyStatus)) {
    void (^reply)(S7TVAdblockProxyStatus) = ^(S7TVAdblockProxyStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
    };
    if (!address.length) {
        reply(S7TVAdblockProxyStatusOffline);
        return;
    }
    NSURL *URL = S7TVAdblockNormalizedProxyURL(address);
    if (!URL.host.length) {
        os_log_error(OS_LOG_DEFAULT, "[7TV-Adblock] probe: unparseable proxy address");
        reply(S7TVAdblockProxyStatusOffline);
        return;
    }
    NSString *host = URL.host;
    int port = (URL.port ?: @8080).intValue;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *start = NSDate.date;
        BOOL reachable = S7TVAdblockTCPConnectReachable(host, port, 10);
        NSTimeInterval elapsed = -[start timeIntervalSinceNow];
        os_log(OS_LOG_DEFAULT,
               "[7TV-Adblock] proxy probe %{public}@:%d reachable=%d in %.2fs",
               host, port, reachable, elapsed);
        reply(reachable ? S7TVAdblockProxyStatusOnline : S7TVAdblockProxyStatusOffline);
    });
}
