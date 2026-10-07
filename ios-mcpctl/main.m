#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../IOSMCPPreferences.h"
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

typedef NS_ENUM(NSInteger, IOSMCPServiceState) {
    IOSMCPServiceStateRunning,
    IOSMCPServiceStateStopped,
    IOSMCPServiceStateUnresponsive,
};

enum {
    IOSMCPExitSuccess = 0,
    IOSMCPExitStopped = 1,
    IOSMCPExitUsage = 2,
    IOSMCPExitFailure = 3,
};

static const NSTimeInterval IOSMCPControlTimeout = 10.0;
static const NSTimeInterval IOSMCPHealthTimeout = 5.0;

// Settings and SpringBoard run as mobile. Root SSH must use the same domain,
// rather than accidentally reading or writing root's preferences.
static CFStringRef IOSMCPPreferencesUser(void) {
    return CFSTR("mobile");
}

static void IOSMCPSynchronizePreferences(void) {
    CFPreferencesSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN,
                             IOSMCPPreferencesUser(), kCFPreferencesAnyHost);
}

static id IOSMCPCopyPreference(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN,
                                                    IOSMCPPreferencesUser(), kCFPreferencesAnyHost));
}

static uint16_t IOSMCPControlPort(void) {
    IOSMCPSynchronizePreferences();
    uint16_t port = IOS_MCP_DEFAULT_PORT;
    IOSMCPParsePortValue(IOSMCPCopyPreference(IOS_MCP_PORT_PREFERENCE_KEY), &port);
    return port;
}

static BOOL IOSMCPControlEnabled(void) {
    id value = IOSMCPCopyPreference(IOS_MCP_ENABLED_PREFERENCE_KEY);
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : YES;
}

static BOOL IOSMCPSetControlEnabled(BOOL enabled) {
    CFPreferencesSetValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                          enabled ? kCFBooleanTrue : kCFBooleanFalse,
                          (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN,
                          IOSMCPPreferencesUser(), kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN,
                                  IOSMCPPreferencesUser(), kCFPreferencesAnyHost)) {
        fprintf(stderr, "Cannot save mobile's iOS MCP settings. Run as mobile or root.\n");
        return NO;
    }
    return YES;
}

static BOOL IOSMCPPortRefusesConnection(uint16_t port) {
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) return NO;
    int flags = fcntl(socketFD, F_GETFL, 0);
    if (flags < 0 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(socketFD);
        return NO;
    }
    struct sockaddr_in address = {
        .sin_len = sizeof(struct sockaddr_in),
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    int result = connect(socketFD, (struct sockaddr *)&address, sizeof(address));
    int connectionError = result == 0 ? 0 : errno;
    if (connectionError == EINPROGRESS) {
        struct pollfd descriptor = {.fd = socketFD, .events = POLLOUT};
        if (poll(&descriptor, 1, 200) > 0) {
            socklen_t length = sizeof(connectionError);
            if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &connectionError, &length) < 0) {
                connectionError = errno;
            }
        }
    }
    close(socketFD);
    return connectionError == ECONNREFUSED;
}

static IOSMCPServiceState IOSMCPProbeService(uint16_t port, NSTimeInterval timeout, NSString **detail) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/health", (unsigned int)port]];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = timeout;
    configuration.timeoutIntervalForResource = timeout;
    configuration.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = timeout;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSURLResponse *response = nil;
    __block NSError *responseError = nil;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                         completionHandler:^(NSData *data, NSURLResponse *receivedResponse, NSError *error) {
        responseData = data;
        response = receivedResponse;
        responseError = error;
        dispatch_semaphore_signal(completion);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(completion,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    if (waitResult != 0) {
        if (detail) *detail = @"health request timed out";
        return IOSMCPServiceStateUnresponsive;
    }
    if (responseError) {
        // A timeout, broken HTTP response or unrelated listener is not proof
        // that STOP completed. Confirm ECONNREFUSED before reporting stopped.
        if (IOSMCPPortRefusesConnection(port)) return IOSMCPServiceStateStopped;
        if (detail) *detail = responseError.localizedDescription;
        return IOSMCPServiceStateUnresponsive;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    id payload = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if (httpResponse.statusCode == 200 && [payload isKindOfClass:NSDictionary.class] &&
        [payload[@"status"] isEqual:@"ok"] && [payload[@"server"] isEqual:@"ios-mcp"]) {
        return IOSMCPServiceStateRunning;
    }
    if (detail) *detail = @"port did not return a valid iOS MCP health response";
    return IOSMCPServiceStateUnresponsive;
}

static void IOSMCPPrintState(IOSMCPServiceState state, uint16_t port, NSString *detail) {
    const char *name = state == IOSMCPServiceStateRunning ? "running" :
        state == IOSMCPServiceStateStopped ? "stopped" : "unresponsive";
    printf("%s (port %u, enabled=%s)\n", name, (unsigned int)port, IOSMCPControlEnabled() ? "yes" : "no");
    if (detail.length) fprintf(stderr, "%s\n", detail.UTF8String);
}

static BOOL IOSMCPRequestState(BOOL running, uint16_t port) {
    if (!IOSMCPSetControlEnabled(running)) return NO;
    CFStringRef notification = running ? IOS_MCP_DARWIN_NOTIFICATION_START : IOS_MCP_DARWIN_NOTIFICATION_STOP;
    uint32_t result = notify_post([(__bridge NSString *)notification UTF8String]);
    if (result != NOTIFY_STATUS_OK) {
        fprintf(stderr, "Saved enabled=%s, but sending the %s request failed (notify status %u).\n",
                running ? "yes" : "no", running ? "start" : "stop", result);
        return NO;
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + IOSMCPControlTimeout;
    IOSMCPServiceState expectedState = running ? IOSMCPServiceStateRunning : IOSMCPServiceStateStopped;
    IOSMCPServiceState state = IOSMCPServiceStateUnresponsive;
    NSString *detail = nil;
    do {
        [NSThread sleepForTimeInterval:0.2];
        if (IOSMCPControlPort() != port) {
            fprintf(stderr, "The configured port changed while waiting; run ios-mcpctl status again.\n");
            return NO;
        }
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) break;
        detail = nil;
        state = IOSMCPProbeService(port, MIN(IOSMCPHealthTimeout, remaining), &detail);
        if (state == expectedState) return YES;
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    fprintf(stderr, "Timed out waiting for iOS MCP to %s. Check that its tweak is loaded in SpringBoard.\n",
            running ? "start" : "stop");
    IOSMCPPrintState(state, port, detail);
    return NO;
}

static void IOSMCPPrintUsage(FILE *output) {
    fprintf(output,
        "Usage: ios-mcpctl start|stop|restart|status\n"
        "  start    Enable and start iOS MCP; leave a healthy server running.\n"
        "  stop     Disable iOS MCP and wait for its listener to close.\n"
        "  restart  Stop, then start iOS MCP; does not restart SpringBoard.\n"
        "  status   Check /health on the port saved in Settings.\n"
        "Uses mobile's settings, including from root SSH.\n"
        "Exit codes: 0 success/running, 1 stopped (status), 2 usage, 3 failure.\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *command = argc == 2 ? [NSString stringWithUTF8String:argv[1]] : nil;
        if ([@[@"help", @"-h", @"--help"] containsObject:command ?: @""]) {
            IOSMCPPrintUsage(stdout);
            return IOSMCPExitSuccess;
        }
        if (![@[@"start", @"stop", @"restart", @"status"] containsObject:command ?: @""]) {
            IOSMCPPrintUsage(stderr);
            return IOSMCPExitUsage;
        }
        uint16_t port = IOSMCPControlPort();
        NSString *detail = nil;
        IOSMCPServiceState state = IOSMCPProbeService(port, IOSMCPHealthTimeout, &detail);
        if ([command isEqualToString:@"status"]) {
            IOSMCPPrintState(state, port, detail);
            return state == IOSMCPServiceStateRunning ? IOSMCPExitSuccess :
                state == IOSMCPServiceStateStopped ? IOSMCPExitStopped : IOSMCPExitFailure;
        }
        if ([command isEqualToString:@"start"] && state == IOSMCPServiceStateRunning) {
            if (!IOSMCPSetControlEnabled(YES)) return IOSMCPExitFailure;
            IOSMCPPrintState(state, port, nil);
            return IOSMCPExitSuccess;
        }
        if ([command isEqualToString:@"stop"] ||
            ([command isEqualToString:@"restart"] && state != IOSMCPServiceStateStopped)) {
            if (!IOSMCPRequestState(NO, port)) return IOSMCPExitFailure;
            if ([command isEqualToString:@"stop"]) {
                IOSMCPPrintState(IOSMCPServiceStateStopped, port, nil);
                return IOSMCPExitSuccess;
            }
        }
        if (!IOSMCPRequestState(YES, port)) return IOSMCPExitFailure;
        IOSMCPPrintState(IOSMCPServiceStateRunning, port, nil);
        return IOSMCPExitSuccess;
    }
}
