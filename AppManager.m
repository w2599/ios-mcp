#import "AppManager.h"
#import "AccessibilityManager.h"
#import "MCPProcessUtil.h"
#import "SpringBoardPrivate.h"
#include <roothide.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "IOSMCPPreferences.h"
#import "MCPLogger.h"
#import <fcntl.h>
#import <spawn.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

typedef struct __SecCode const *SecStaticCodeRef;
typedef CF_OPTIONS(uint32_t, MCPSecCSFlags) {
    kMCPSecCSDefaultFlags = 0
};
#define kMCPSecCSRequirementInformation (1 << 2)

OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path,
                                                  MCPSecCSFlags flags,
                                                  CFDictionaryRef attributes,
                                                  SecStaticCodeRef *staticCode);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code,
                                       MCPSecCSFlags flags,
                                       CFDictionaryRef *information);
extern CFStringRef kSecCodeInfoEntitlementsDict;

@interface UIApplication (MCPPrivate)
- (id)_accessibilityFrontMostApplication;
@end

#define APP_LOG(fmt, ...) do { \
    if ([MCPLogger isDebugLoggingEnabled]) { \
        NSString *_iosmcp_log = [NSString stringWithFormat:(@"[App] " fmt), ##__VA_ARGS__]; \
        NSLog(@"[witchan][ios-mcp]%@", _iosmcp_log); \
        [MCPLogger logMessage:_iosmcp_log]; \
    } \
} while (0)

static id MCPAppMsgSendObject(id target, SEL selector) {
    if (!target || !selector) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id MCPAppMsgSendObjectArg(id target, SEL selector, id arg) {
    if (!target || !selector) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, arg);
}

static BOOL MCPURLUsesSettingsScheme(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"prefs"] || [scheme isEqualToString:@"app-prefs"];
}

static NSString *MCPAppLogSafePath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return @"-";
    }
    NSString *extension = path.pathExtension.lowercaseString;
    if (extension.length > 0 && extension.length <= 12) {
        return [NSString stringWithFormat:@"<path:.%@>", extension];
    }
    return @"<path>";
}

static NSString *MCPAppLogSafeURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return @"-";
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host;
    if (scheme.length > 0 && host.length > 0) {
        return [NSString stringWithFormat:@"<url:%@://%@>", scheme, host];
    }
    if (scheme.length > 0) {
        return [NSString stringWithFormat:@"<url:%@>", scheme];
    }
    return @"<url>";
}

static NSString *MCPAppLogRedactedText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"-";
    }
    NSString *result = [[text stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
                        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSArray<NSDictionary<NSString *, NSString *> *> *rules = @[
        @{@"pattern": @"(?i)\\b[a-z][a-z0-9+.-]*://[^\\s\\\"'<>]+", @"replacement": @"<url>"},
        @{@"pattern": @"(?i)\\b(prefs|app-prefs):[^\\s\\\"'<>]+", @"replacement": @"<url>"},
        @{@"pattern": @"(/private)?/(var|tmp|Applications|User|Users|Library)[^\\s\\\"'<>]*", @"replacement": @"<path>"}
    ];
    for (NSDictionary<NSString *, NSString *> *rule in rules) {
        NSError *regexError = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[@"pattern"]
                                                                               options:0
                                                                                 error:&regexError];
        if (!regex || regexError) {
            continue;
        }
        result = [regex stringByReplacingMatchesInString:result
                                                 options:0
                                                   range:NSMakeRange(0, result.length)
                                            withTemplate:rule[@"replacement"]];
    }
    if (result.length > 256) {
        result = [[result substringToIndex:256] stringByAppendingString:@"...<truncated>"];
    }
    return result;
}

static NSString *MCPSpringBoardKillallPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in @[
        MCPResolvedJailbreakPath(@"/usr/bin/killall"),
        MCPResolvedJailbreakPath(@"/bin/killall"),
        @"/usr/bin/killall",
        @"/bin/killall"
    ]) {
        if (candidate.length && [fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static BOOL MCPScheduleSpringBoardRestart(NSString **error) {
    NSString *killallPath = MCPSpringBoardKillallPath();
    if (!killallPath.length) {
        if (error) *error = @"killall executable not found";
        return NO;
    }

    NSString *spawnPath = [killallPath copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        pid_t pid = 0;
        char *const argv[] = {"killall", "-9", "SpringBoard", NULL};
        int status = posix_spawn(&pid, spawnPath.fileSystemRepresentation, NULL, NULL, argv, NULL);
        if (status != 0) {
            APP_LOG(@"Failed to spawn SpringBoard restart via %@: %s", MCPAppLogSafePath(spawnPath), strerror(status));
            return;
        }
        APP_LOG(@"Scheduled SpringBoard restart pid=%d", pid);
    });
    return YES;
}

static NSUInteger MCPAppLogUTF8Length(NSString *text) {
    return [text isKindOfClass:[NSString class]] ? [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : 0;
}

static NSDictionary<NSString *, id> *MCPDumpEntitlementsFromBinaryAtPath(NSString *binaryPath) {
    if (binaryPath.length == 0) return nil;

    SecStaticCodeRef codeRef = NULL;
    OSStatus createStatus = SecStaticCodeCreateWithPathAndAttributes((__bridge CFURLRef)[NSURL fileURLWithPath:binaryPath],
                                                                     kMCPSecCSDefaultFlags,
                                                                     NULL,
                                                                     &codeRef);
    if (createStatus != errSecSuccess || codeRef == NULL) {
        return nil;
    }

    CFDictionaryRef signingInfo = NULL;
    OSStatus copyStatus = SecCodeCopySigningInformation(codeRef,
                                                        kMCPSecCSRequirementInformation,
                                                        &signingInfo);
    CFRelease(codeRef);
    if (copyStatus != errSecSuccess || signingInfo == NULL) {
        if (signingInfo) CFRelease(signingInfo);
        return nil;
    }

    NSDictionary *entitlementsDict = nil;
    CFTypeRef entitlements = CFDictionaryGetValue(signingInfo, kSecCodeInfoEntitlementsDict);
    if (entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
        entitlementsDict = [(__bridge NSDictionary *)entitlements copy];
    }

    CFRelease(signingInfo);
    return entitlementsDict;
}

static NSString *MCPShellQuote(NSString *string) {
    NSString *value = string ?: @"";
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *MCPConfiguredSudoPassword(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("sudo_password"),
                                                        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *password = [(__bridge NSString *)value copy];
        CFRelease(value);
        if (password.length > 0) return password;
    } else if (value) {
        CFRelease(value);
    }
    return @"alpine";
}

static NSString *MCPBootstrapArgumentPath(NSString *path);

static NSString *MCPDpkgBootstrapPathForDeb(NSString *path) {
    if (!path.isAbsolutePath || ![path.pathExtension.lowercaseString isEqualToString:@"deb"]) {
        return path ?: @"";
    }

#ifdef MCP_ROOTHIDE
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *systemPathFromBootstrap = jbroot(path);
    if (systemPathFromBootstrap.length > 0 &&
        [fm fileExistsAtPath:systemPathFromBootstrap]) {
        return path;
    }

    if ([fm fileExistsAtPath:path]) {
        NSString *bootstrapPath = rootfs(path);
        return bootstrapPath.length > 0 ? bootstrapPath : path;
    }

    NSString *bootstrapPath = rootfs(path);
    return bootstrapPath.length > 0 ? bootstrapPath : path;
#else
    return path;
#endif
}

static NSArray<NSString *> *MCPDpkgBootstrapArguments(NSArray<NSString *> *dpkgArguments) {
    NSMutableArray<NSString *> *convertedArguments = [NSMutableArray arrayWithCapacity:dpkgArguments.count];
    for (NSString *argument in dpkgArguments) {
        NSString *converted = argument;
        if (argument.isAbsolutePath &&
            [argument.pathExtension.lowercaseString isEqualToString:@"deb"]) {
            converted = MCPDpkgBootstrapPathForDeb(argument);
        }
        [convertedArguments addObject:converted ?: @""];
    }
    return convertedArguments;
}

static BOOL MCPDpkgOutputLooksLikeHelperPrivilegeFailure(NSString *output, int exitCode) {
    if (exitCode == 111) return YES;
    if (![output isKindOfClass:[NSString class]] || output.length == 0) return NO;
    return [output rangeOfString:@"setgid(0) failed"].location != NSNotFound ||
           [output rangeOfString:@"setuid(0) failed"].location != NSNotFound ||
           [output rangeOfString:@"dpkg package does not exist:"].location != NSNotFound;
}

static BOOL MCPRunDpkgWithPrivileges(NSArray<NSString *> *dpkgArguments,
                                     NSTimeInterval timeout,
                                     NSUInteger maxOutputBytes,
                                     NSString **output,
                                     int *exitCode,
                                     NSString **errorMessage) {
    if (output) *output = @"";
    if (exitCode) *exitCode = -1;
    if (errorMessage) *errorMessage = nil;

    NSArray<NSString *> *bootstrapDpkgArguments = MCPDpkgBootstrapArguments(dpkgArguments);
    NSMutableArray<NSString *> *helperArguments = [NSMutableArray arrayWithObject:@"/usr/bin/dpkg"];
    if (bootstrapDpkgArguments.count > 0) {
        [helperArguments addObjectsFromArray:bootstrapDpkgArguments];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mcpRootPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-root");
    NSString *helperOutput = nil;
    NSString *helperError = nil;
    int helperExitCode = -1;
    BOOL helperFinished = NO;

    if ([fm isExecutableFileAtPath:mcpRootPath]) {
        helperFinished = MCPRunProcess(mcpRootPath,
                                       helperArguments,
                                       MCPJailbreakEnvironment(),
                                       timeout,
                                       maxOutputBytes,
                                       &helperOutput,
                                       &helperExitCode,
                                       &helperError);
        if (helperFinished && helperExitCode == 0) {
            if (output) *output = helperOutput;
            if (exitCode) *exitCode = helperExitCode;
            if (errorMessage) *errorMessage = helperError;
            return YES;
        }

        if (!MCPDpkgOutputLooksLikeHelperPrivilegeFailure(helperOutput, helperExitCode)) {
            if (output) *output = helperOutput;
            if (exitCode) *exitCode = helperExitCode;
            if (errorMessage) *errorMessage = helperError;
            return helperFinished;
        }

        APP_LOG(@"mcp-root dpkg privilege failed, trying sudo fallback (exit=%d outputBytes=%lu)",
                helperExitCode,
                (unsigned long)MCPAppLogUTF8Length(helperOutput));
    }

    NSString *sudoPath = MCPResolvedJailbreakPath(@"/usr/bin/sudo");
    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    NSString *dpkgPath = MCPResolvedJailbreakPath(@"/usr/bin/dpkg");
    if (![fm isExecutableFileAtPath:sudoPath]) {
        if (output) *output = helperOutput ?: @"";
        if (exitCode) *exitCode = helperExitCode;
        if (errorMessage) {
            *errorMessage = helperError ?: @"mcp-root privilege escalation failed and sudo is not available";
        }
        return helperFinished;
    }
    if (![fm isExecutableFileAtPath:shellPath]) {
        shellPath = @"/bin/sh";
    }
    if (![fm isExecutableFileAtPath:dpkgPath]) {
        if (output) *output = helperOutput ?: @"";
        if (exitCode) *exitCode = helperExitCode;
        if (errorMessage) *errorMessage = @"dpkg executable not found";
        return NO;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
                                         @"printf '%s\\n'",
                                         MCPShellQuote(MCPConfiguredSudoPassword()),
                                         @"|",
                                         MCPShellQuote(sudoPath),
                                         @"-k",
                                         @"-S",
                                         @"-p",
                                         @"''",
                                         MCPShellQuote(dpkgPath),
                                         nil];
    for (NSString *argument in bootstrapDpkgArguments) {
        [parts addObject:MCPShellQuote(argument)];
    }
    NSString *command = [parts componentsJoinedByString:@" "];

    NSString *sudoOutput = nil;
    NSString *sudoError = nil;
    int sudoExitCode = -1;
    BOOL sudoFinished = MCPRunProcess(shellPath,
                                      @[@"-lc", command],
                                      MCPJailbreakEnvironment(),
                                      timeout,
                                      maxOutputBytes,
                                      &sudoOutput,
                                      &sudoExitCode,
                                      &sudoError);
    if (output) *output = sudoOutput;
    if (exitCode) *exitCode = sudoExitCode;
    if (errorMessage) {
        if (sudoError.length > 0) {
            *errorMessage = sudoError;
        } else if (!sudoFinished && helperOutput.length > 0) {
            *errorMessage = [NSString stringWithFormat:@"mcp-root failed: %@", helperOutput];
        }
    }
    return sudoFinished;
}

static BOOL MCPWriteFileToShellPath(NSString *sourcePath, NSString *destPath, NSString **output, NSString **errorMessage) {
    if (output) *output = @"";
    if (errorMessage) *errorMessage = nil;
    if (!sourcePath.length || !destPath.length) {
        if (errorMessage) *errorMessage = @"Missing source or destination path";
        return NO;
    }

    int sourceFD = open(sourcePath.fileSystemRepresentation, O_RDONLY);
    if (sourceFD < 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Failed to open source DEB: %s", strerror(errno)];
        return NO;
    }

    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:shellPath]) {
        shellPath = @"/bin/sh";
    }

    NSString *parent = destPath.stringByDeletingLastPathComponent;
    NSString *command = [NSString stringWithFormat:@"mkdir -p %@ && cat > %@ && chmod 0644 %@",
                         MCPShellQuote(parent),
                         MCPShellQuote(destPath),
                         MCPShellQuote(destPath)];

    int stdinPipe[2] = {-1, -1};
    int outputPipe[2] = {-1, -1};
    if (pipe(stdinPipe) != 0) {
        close(sourceFD);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"stdin pipe failed: %s", strerror(errno)];
        return NO;
    }
    if (pipe(outputPipe) != 0) {
        close(sourceFD);
        close(stdinPipe[0]);
        close(stdinPipe[1]);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"output pipe failed: %s", strerror(errno)];
        return NO;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdinPipe[1]);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);

    const char *shell = shellPath.fileSystemRepresentation;
    char *const argv[] = {
        (char *)(shellPath.lastPathComponent.UTF8String ?: "sh"),
        "-lc",
        (char *)(command.UTF8String ?: ""),
        NULL
    };

    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, shell, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(stdinPipe[0]);
    close(outputPipe[1]);

    if (spawnStatus != 0) {
        close(sourceFD);
        close(stdinPipe[1]);
        close(outputPipe[0]);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"posix_spawn shell failed: %s", strerror(spawnStatus)];
        return NO;
    }

    BOOL writeFailed = NO;
    int savedErrno = 0;
    uint8_t fileBuffer[65536];
    while (1) {
        ssize_t bytesRead = read(sourceFD, fileBuffer, sizeof(fileBuffer));
        if (bytesRead < 0 && errno == EINTR) continue;
        if (bytesRead < 0) {
            writeFailed = YES;
            savedErrno = errno;
            break;
        }
        if (bytesRead == 0) break;

        uint8_t *cursor = fileBuffer;
        ssize_t remaining = bytesRead;
        while (remaining > 0) {
            ssize_t written = write(stdinPipe[1], cursor, (size_t)remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                writeFailed = YES;
                savedErrno = errno;
                remaining = 0;
                break;
            }
            cursor += written;
            remaining -= written;
        }
        if (writeFailed) break;
    }
    close(sourceFD);
    close(stdinPipe[1]);

    NSMutableData *captured = [NSMutableData data];
    char buffer[4096];
    ssize_t n = 0;
    while ((n = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
        if (captured.length < 64 * 1024) {
            NSUInteger allowed = MIN((NSUInteger)n, (64 * 1024) - captured.length);
            [captured appendBytes:buffer length:allowed];
        }
    }
    close(outputPipe[0]);

    int status = 0;
    int waitStatus = waitpid(pid, &status, 0);
    NSString *capturedOutput = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding] ?: @"";
    if (output) *output = capturedOutput;

    if (writeFailed) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Failed to stream staged DEB: %s %@", strerror(savedErrno), MCPAppLogRedactedText(capturedOutput)];
        return NO;
    }
    if (waitStatus < 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"waitpid failed: %s", strerror(errno)];
        return NO;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"staging shell failed: %@", MCPAppLogRedactedText(capturedOutput)];
        return NO;
    }
    return YES;
}

static void MCPRemoveShellPath(NSString *path) {
    if (!path.length) return;
    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:shellPath]) {
        shellPath = @"/bin/sh";
    }
    NSString *command = [NSString stringWithFormat:@"rm -f %@", MCPShellQuote(path)];
    NSString *output = nil;
    NSString *runError = nil;
    int exitCode = -1;
    MCPRunProcess(shellPath,
                  @[@"-lc", command],
                  MCPJailbreakEnvironment(),
                  10,
                  64 * 1024,
                  &output,
                  &exitCode,
                  &runError);
}

static NSString *MCPStageDebForDpkg(NSString *debPath, NSString **stagedPath, NSString **stageError) {
    if (stagedPath) *stagedPath = nil;
    if (stageError) *stageError = nil;

    if (!debPath.length) {
        if (stageError) *stageError = @"Empty DEB path";
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:debPath]) {
        if (stageError) *stageError = [NSString stringWithFormat:@"DEB file not found: %@", debPath];
        return nil;
    }

    NSString *fileName = [NSString stringWithFormat:@"ios-mcp-dpkg-%@.deb", [[NSUUID UUID] UUIDString]];
    NSString *visiblePath = [@"/var/tmp" stringByAppendingPathComponent:fileName];
    NSString *stageOutput = nil;
    NSString *writeError = nil;
    if (!MCPWriteFileToShellPath(debPath, visiblePath, &stageOutput, &writeError)) {
        if (stageError) *stageError = writeError ?: stageOutput ?: @"Failed to stage DEB for dpkg";
        return nil;
    }

    if (stagedPath) *stagedPath = visiblePath;
    return visiblePath;
}

static NSString *MCPBootstrapArgumentPath(NSString *path) {
    if (path.length == 0) return path ?: @"";
    NSString *converted = rootfs(path);
    return converted.length > 0 ? converted : path;
}

static NSString *MCPFrontmostBundleIdentifier(void) {
    NSDictionary *info = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSString *bundleId = [info[@"bundleId"] isKindOfClass:[NSString class]] ? info[@"bundleId"] : nil;
    return bundleId ?: @"";
}

static NSDictionary *MCPFrontmostApplicationInfo(void) {
    NSDictionary *info = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    return [info isKindOfClass:[NSDictionary class]] ? info : @{};
}

static NSString *MCPNormalizedInstalledAppType(id proxy, NSString *bundleId, NSString *rawType) {
    if ([rawType isEqualToString:@"User"]) return @"User";

    NSString *bundlePath = nil;
    if ([proxy respondsToSelector:@selector(bundleURL)]) {
        id bundleURL = MCPAppMsgSendObject(proxy, @selector(bundleURL));
        if ([bundleURL isKindOfClass:[NSURL class]]) {
            bundlePath = [((NSURL *)bundleURL).path stringByStandardizingPath];
        }
    }

    if ([bundlePath containsString:@"/Containers/Bundle/Application/"]) {
        return @"User";
    }

    if (bundleId.length > 0 && ![bundleId hasPrefix:@"com.apple."]) {
        return @"User";
    }

    if ([rawType isEqualToString:@"Internal"]) return @"System";
    return rawType.length > 0 ? rawType : @"System";
}

static BOOL MCPWaitForFrontmostApp(NSString *expectedBundleId,
                                   NSTimeInterval timeout,
                                   NSDictionary **outFrontmostInfo) {
    if (outFrontmostInfo) *outFrontmostInfo = @{};
    if (expectedBundleId.length == 0) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    NSDictionary *lastInfo = @{};

    while ([deadline timeIntervalSinceNow] > 0) {
        lastInfo = MCPFrontmostApplicationInfo();
        NSString *frontmostBundleId = [lastInfo[@"bundleId"] isKindOfClass:[NSString class]] ? lastInfo[@"bundleId"] : nil;
        if ([frontmostBundleId isEqualToString:expectedBundleId]) {
            if (outFrontmostInfo) *outFrontmostInfo = lastInfo;
            return YES;
        }

        [NSThread sleepForTimeInterval:0.1];
    }

    lastInfo = MCPFrontmostApplicationInfo();
    if (outFrontmostInfo) *outFrontmostInfo = lastInfo;
    return NO;
}

static BOOL MCPWaitForURLOpenVerification(NSURL *url, NSString *previousBundleId, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    BOOL settingsURL = MCPURLUsesSettingsScheme(url);

    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

        NSString *bundleId = MCPFrontmostBundleIdentifier();
        if (bundleId.length == 0) continue;

        if (settingsURL) {
            if ([bundleId isEqualToString:@"com.apple.Preferences"]) {
                return YES;
            }
            continue;
        }

        if (previousBundleId.length > 0) {
            if (![bundleId isEqualToString:previousBundleId]) {
                return YES;
            }
        } else if (![bundleId isEqualToString:@"com.apple.springboard"]) {
            return YES;
        }
    }

    return NO;
}

@implementation AppManager

+ (instancetype)sharedInstance {
    static AppManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppManager alloc] init];
    });
    return instance;
}

#pragma mark - Launch

- (BOOL)launchApp:(NSString *)bundleId error:(NSString **)error {
    if (!bundleId.length) {
        if (error) *error = @"Empty bundle ID";
        return NO;
    }

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    // Prefer LaunchServices from the current client worker. Calling the legacy
    // SBUIController activation path synchronously on SpringBoard's main queue
    // can block that queue for several seconds on some iOS versions.
    Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
    if (LSWorkspaceClass) {
        @try {
            SEL defaultWorkspaceSel = @selector(defaultWorkspace);
            if (![LSWorkspaceClass respondsToSelector:defaultWorkspaceSel]) {
                errMsg = @"LSApplicationWorkspace defaultWorkspace is unavailable";
            } else {
                id workspace = ((id (*)(id, SEL))objc_msgSend)((id)LSWorkspaceClass, defaultWorkspaceSel);
                SEL openSel = @selector(openApplicationWithBundleID:);
                if (!workspace) {
                    errMsg = @"LSApplicationWorkspace defaultWorkspace returned nil";
                } else if (![workspace respondsToSelector:openSel]) {
                    errMsg = @"LSApplicationWorkspace openApplicationWithBundleID: is unavailable";
                } else {
                    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
                    BOOL opened = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, bundleId);
                    APP_LOG(@"LaunchServices launch request for %@ returned %@ in %.0fms",
                            bundleId,
                            opened ? @"YES" : @"NO",
                            (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0);
                    if (opened) {
                        ok = YES;
                    } else {
                        errMsg = @"LSApplicationWorkspace openApplicationWithBundleID: returned NO";
                    }
                }
            }
        } @catch (NSException *exception) {
            errMsg = [NSString stringWithFormat:@"LSApplicationWorkspace launch failed: %@",
                      exception.reason ?: exception.name ?: @"unknown exception"];
            APP_LOG(@"LaunchServices launch exception for %@: %@ - %@",
                    bundleId,
                    exception.name ?: @"unknown",
                    exception.reason ?: @"-");
        }
    } else {
        errMsg = @"LSApplicationWorkspace is unavailable";
    }

    // Keep the SpringBoard-private path only as a compatibility fallback.
    dispatch_block_t fallbackBlock = ^{
        Class SBAppCtrl = objc_getClass("SBApplicationController");
        if (SBAppCtrl) {
            id appCtrl = [SBAppCtrl performSelector:@selector(sharedInstance)];
            id sbApp = [appCtrl performSelector:@selector(applicationWithBundleIdentifier:) withObject:bundleId];
            if (sbApp) {
                Class SBUICtrlClass = objc_getClass("SBUIController");
                if (SBUICtrlClass) {
                    id ctrl = [SBUICtrlClass performSelector:@selector(sharedInstance)];
                    SEL activateSel = @selector(activateApplication:);
                    if ([ctrl respondsToSelector:activateSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [ctrl performSelector:activateSel withObject:sbApp];
#pragma clang diagnostic pop
                        APP_LOG(@"Launched app via activateApplication: %@", bundleId);
                        ok = YES;
                        return;
                    }
                }
            }
        }
        NSString *primaryError = errMsg.length > 0 ? errMsg : @"LaunchServices request failed";
        errMsg = [NSString stringWithFormat:@"%@; SBUIController fallback unavailable for %@",
                  primaryError,
                  bundleId];
    };

    if (!ok) {
        if ([NSThread isMainThread]) {
            fallbackBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), fallbackBlock);
        }
    }

    if (!ok) {
        if (error) *error = errMsg;
        return NO;
    }

    NSDictionary *frontmostInfo = nil;
    if (MCPWaitForFrontmostApp(bundleId, 5.0, &frontmostInfo)) {
        APP_LOG(@"Launch confirmed in foreground: %@", bundleId);
        return YES;
    }

    NSString *frontmostBundleId = [frontmostInfo[@"bundleId"] isKindOfClass:[NSString class]] ? frontmostInfo[@"bundleId"] : nil;
    NSString *frontmostName = [frontmostInfo[@"name"] isKindOfClass:[NSString class]] ? frontmostInfo[@"name"] : nil;
    if (error) {
        if (frontmostBundleId.length > 0) {
            *error = [NSString stringWithFormat:@"Launch request sent for %@, but frontmost app is still %@%@",
                      bundleId,
                      frontmostBundleId,
                      frontmostName.length > 0 ? [NSString stringWithFormat:@" (%@)", frontmostName] : @""];
        } else {
            *error = [NSString stringWithFormat:@"Launch request sent for %@, but it did not become frontmost within 5 seconds", bundleId];
        }
    }
    APP_LOG(@"Launch not confirmed for %@, currentFrontmostBundleId=%@", bundleId, frontmostBundleId ?: @"-");
    return NO;
}

#pragma mark - Kill

- (BOOL)killApp:(NSString *)bundleId error:(NSString **)error {
    if (!bundleId.length) {
        if (error) *error = @"Empty bundle ID";
        return NO;
    }

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class FBSClass = objc_getClass("FBSSystemService");
        if (!FBSClass) {
            errMsg = @"FBSSystemService not available";
            return;
        }

        id service = [FBSClass performSelector:@selector(sharedService)];

        SEL termSel = @selector(terminateApplication:forReason:andReport:withDescription:);
        if ([service respondsToSelector:termSel]) {
            NSMethodSignature *sig = [service methodSignatureForSelector:termSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = service;
            inv.selector = termSel;
            NSString *bid = bundleId;
            [inv setArgument:&bid atIndex:2];
            int reason = 1;
            [inv setArgument:&reason atIndex:3];
            BOOL report = NO;
            [inv setArgument:&report atIndex:4];
            NSString *desc = @"Terminated via ios-mcp";
            [inv setArgument:&desc atIndex:5];
            [inv invoke];

            APP_LOG(@"Killed app: %@", bundleId);
            ok = YES;
        } else {
            errMsg = @"terminateApplication: selector not available";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (error) *error = errMsg;
    return ok;
}

#pragma mark - List Installed

- (NSArray<NSDictionary *> *)listInstalledApps:(NSString *)type {
    __block NSArray *result = @[];

    dispatch_block_t block = ^{
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (!LSWorkspaceClass) return;

        id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
        NSArray *allApps = [workspace performSelector:@selector(allInstalledApplications)];

        NSMutableArray *list = [NSMutableArray array];
        for (id proxy in allApps) {
            NSString *appId   = [proxy performSelector:@selector(applicationIdentifier)];
            NSString *name    = [proxy performSelector:@selector(localizedName)];
            NSString *rawType = [proxy performSelector:@selector(applicationType)];

            if (!appId) continue;

            NSString *appType = MCPNormalizedInstalledAppType(proxy, appId, rawType);

            // Filter by type
            if ([type isEqualToString:@"user"] && ![appType isEqualToString:@"User"]) continue;
            if ([type isEqualToString:@"system"] && [appType isEqualToString:@"User"]) continue;

            [list addObject:@{
                @"bundleId": appId ?: @"",
                @"name":     name ?: @"",
                @"type":     appType ?: @""
            }];
        }

        result = [list copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - List Running

- (NSArray<NSDictionary *> *)listRunningApps {
    __block NSArray *result = @[];

    dispatch_block_t block = ^{
        Class SBAppCtrl = objc_getClass("SBApplicationController");
        if (!SBAppCtrl) return;

        id controller = [SBAppCtrl performSelector:@selector(sharedInstance)];

        NSArray *running = nil;
        if ([controller respondsToSelector:@selector(runningApplications)]) {
            running = [controller performSelector:@selector(runningApplications)];
        } else {
            // Fallback: iterate all and check isRunning
            NSArray *all = [controller performSelector:@selector(allApplications)];
            NSMutableArray *filtered = [NSMutableArray array];
            for (id app in all) {
                BOOL isRunning = NO;
                NSMethodSignature *sig = [app methodSignatureForSelector:@selector(isRunning)];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app;
                    inv.selector = @selector(isRunning);
                    [inv invoke];
                    [inv getReturnValue:&isRunning];
                }
                if (isRunning) [filtered addObject:app];
            }
            running = filtered;
        }

        NSMutableArray *list = [NSMutableArray array];
        for (id app in running) {
            NSString *bid  = [app performSelector:@selector(bundleIdentifier)];
            NSString *name = [app performSelector:@selector(displayName)];
            if (!bid) continue;
            [list addObject:@{
                @"bundleId": bid ?: @"",
                @"name":     name ?: @""
            }];
        }

        result = [list copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - Frontmost App

- (NSDictionary *)getFrontmostApp {
    NSDictionary *resolved = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    if ([resolved isKindOfClass:[NSDictionary class]] && resolved.count > 0) {
        return resolved;
    }

    __block NSDictionary *result = @{};

    dispatch_block_t block = ^{
        id frontApp = nil;
        Class springBoardClass = objc_getClass("SpringBoard");
        SEL sharedApplicationSel = @selector(sharedApplication);
        SEL frontmostSel = @selector(_accessibilityFrontMostApplication);
        if (springBoardClass && [springBoardClass respondsToSelector:sharedApplicationSel]) {
            id springBoard = MCPAppMsgSendObject((id)springBoardClass, sharedApplicationSel);
            if (springBoard && [springBoard respondsToSelector:frontmostSel]) {
                frontApp = MCPAppMsgSendObject(springBoard, frontmostSel);
            }
        }

        if (frontApp && [frontApp respondsToSelector:@selector(bundleIdentifier)]) {
            NSString *bid  = [frontApp performSelector:@selector(bundleIdentifier)];
            NSString *name = [frontApp performSelector:@selector(displayName)];
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (bid.length > 0) info[@"bundleId"] = bid;
            if (name.length > 0) info[@"name"] = name;
            result = info;
        } else {
            result = @{@"bundleId": @"com.apple.springboard", @"name": @"SpringBoard"};
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - Open URL

- (BOOL)openURL:(NSString *)urlString error:(NSString **)error {
    if (!urlString.length) {
        if (error) *error = @"Empty URL";
        return NO;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) *error = [NSString stringWithFormat:@"Invalid URL: %@", urlString];
        return NO;
    }

    __block BOOL ok = NO;
    __block BOOL attemptedOpen = NO;
    __block NSString *errMsg = nil;
    __block NSString *previousBundleId = @"";

    dispatch_block_t block = ^{
        previousBundleId = MCPFrontmostBundleIdentifier();
        UIApplication *app = [UIApplication sharedApplication];

        // Method 1: UIApplication openURL:options:completionHandler:
        if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            attemptedOpen = YES;

            __block BOOL completionCalled = NO;
            [app openURL:url options:@{} completionHandler:^(BOOL success) {
                completionCalled = YES;
                ok = success;
                if (!success) errMsg = @"openURL returned NO";
            }];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
            while (!completionCalled && [deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }

            if (!completionCalled && !ok && !errMsg) {
                errMsg = @"openURL completion timed out";
            }
            if (ok) return;
        }

        // Method 2: legacy UIApplication openURL:
        SEL legacyOpenSel = @selector(openURL:);
        if ([app respondsToSelector:legacyOpenSel]) {
            attemptedOpen = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            BOOL opened = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(app, legacyOpenSel, url);
#pragma clang diagnostic pop
            if (opened) {
                APP_LOG(@"Opened URL via UIApplication: %@", MCPAppLogSafeURLString(urlString));
                ok = YES;
                errMsg = nil;
                return;
            }
            if (!errMsg) {
                errMsg = @"openURL returned NO";
            }
        }

        // Method 3: LSApplicationWorkspace openSensitiveURL:withOptions:
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (LSWorkspaceClass) {
            id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
            SEL openSel = @selector(openSensitiveURL:withOptions:);
            if ([workspace respondsToSelector:openSel]) {
                attemptedOpen = YES;
                NSMethodSignature *sig = [workspace methodSignatureForSelector:openSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = workspace;
                inv.selector = openSel;
                NSURL *u = url;
                [inv setArgument:&u atIndex:2];
                NSDictionary *opts = @{};
                [inv setArgument:&opts atIndex:3];
                [inv invoke];

                BOOL result = NO;
                if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
                    [inv getReturnValue:&result];
                } else {
                    result = YES;
                }

                if (result) {
                    APP_LOG(@"Opened URL via LSApplicationWorkspace: %@", MCPAppLogSafeURLString(urlString));
                    ok = YES;
                    errMsg = nil;
                    return;
                }
                if (!errMsg) {
                    errMsg = @"openSensitiveURL returned NO";
                }
            }
        }

        if (!ok && attemptedOpen && MCPWaitForURLOpenVerification(url, previousBundleId, 1.0)) {
            APP_LOG(@"Verified URL open after dispatch: %@", MCPAppLogSafeURLString(urlString));
            ok = YES;
            errMsg = nil;
            return;
        }

        if (!ok && !errMsg) {
            errMsg = @"No URL open method available";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    // Some private schemes (notably prefs:/app-prefs:) can report NO from
    // UIKit/LS even though SpringBoard performs the handoff shortly after the
    // call returns. Verify the visible foreground transition once more outside
    // the main-thread open dispatch before reporting failure.
    if (!ok && attemptedOpen && MCPWaitForURLOpenVerification(url, previousBundleId, 2.0)) {
        APP_LOG(@"Verified URL open after main dispatch returned: %@", MCPAppLogSafeURLString(urlString));
        ok = YES;
        errMsg = nil;
    }

    if (error) *error = errMsg;
    return ok;
}

#pragma mark - Install DEB

- (BOOL)installDebPackage:(NSString *)debPath error:(NSString **)error {
    if (![debPath.pathExtension.lowercaseString isEqualToString:@"deb"]) {
        if (error) *error = @"DEB install requires a .deb file";
        return NO;
    }
    if (!debPath.isAbsolutePath) {
        if (error) *error = @"DEB install requires an absolute device path";
        return NO;
    }

    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:debPath isDirectory:&isDirectory] || isDirectory) {
        if (error) *error = @"DEB file not found or path is a directory";
        return NO;
    }

    NSString *stageError = nil;
    NSString *stagedDebPath = nil;
    NSString *dpkgDebPath = MCPStageDebForDpkg(debPath, &stagedDebPath, &stageError);
    if (!dpkgDebPath.length) {
        if (error) *error = stageError ?: @"Failed to stage DEB for dpkg";
        return NO;
    }

    APP_LOG(@"Installing DEB via privileged dpkg: %@", MCPAppLogSafePath(debPath));
    NSString *output = nil;
    NSString *spawnError = nil;
    int exitCode = -1;
    BOOL finished = MCPRunDpkgWithPrivileges(@[@"-i", dpkgDebPath],
                                             180,
                                             512 * 1024,
                                             &output,
                                             &exitCode,
                                             &spawnError);
    if (stagedDebPath.length > 0) {
        MCPRemoveShellPath(stagedDebPath);
    }
    if (!finished || exitCode != 0) {
        APP_LOG(@"dpkg install failed (spawnError=%@ exit=%d outputBytes=%lu)",
                MCPAppLogRedactedText(spawnError ?: @"none"),
                exitCode,
                (unsigned long)MCPAppLogUTF8Length(output));
        NSString *details = output.length > 0 ? output : (spawnError ?: @"unknown error");
        if (error) *error = [NSString stringWithFormat:@"dpkg install failed: %@", details];
        return NO;
    }

    APP_LOG(@"dpkg install succeeded outputBytes=%lu", (unsigned long)MCPAppLogUTF8Length(output));
    NSString *restartError = nil;
    if (!MCPScheduleSpringBoardRestart(&restartError)) {
        if (error) *error = [NSString stringWithFormat:@"DEB installed but failed to schedule SpringBoard restart: %@", restartError ?: @"unknown error"];
        return NO;
    }

    return YES;
}

- (NSDictionary *)appInfoForBundleId:(NSString *)bundleId error:(NSString **)error {
    if (error) *error = nil;
    if (bundleId.length == 0) {
        if (error) *error = @"bundle_id is required";
        return nil;
    }

    __block NSDictionary *result = nil;
    __block NSString *failure = nil;

    dispatch_block_t block = ^{
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (!LSWorkspaceClass) {
            failure = @"LSApplicationWorkspace unavailable";
            return;
        }
        id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];

        id proxy = nil;
        SEL proxySel = @selector(applicationProxyForIdentifier:);
        if ([workspace respondsToSelector:proxySel]) {
            proxy = MCPAppMsgSendObjectArg(workspace, proxySel, bundleId);
        }
        if (!proxy) {
            // Fallback scan in case applicationProxyForIdentifier: returns a placeholder.
            SEL allAppsSel = @selector(allInstalledApplications);
            if ([workspace respondsToSelector:allAppsSel]) {
                NSArray *allApps = MCPAppMsgSendObject(workspace, allAppsSel);
                for (id candidate in allApps) {
                    if (![candidate respondsToSelector:@selector(applicationIdentifier)]) continue;
                    NSString *appId = [candidate performSelector:@selector(applicationIdentifier)];
                    if ([appId isEqualToString:bundleId]) { proxy = candidate; break; }
                }
            }
        }
        if (!proxy) {
            failure = [NSString stringWithFormat:@"App not installed: %@", bundleId];
            return;
        }

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"bundle_id"] = bundleId;

        if ([proxy respondsToSelector:@selector(localizedName)]) {
            NSString *name = MCPAppMsgSendObject(proxy, @selector(localizedName));
            if ([name isKindOfClass:[NSString class]]) info[@"name"] = name;
        }

        NSString *rawType = nil;
        if ([proxy respondsToSelector:@selector(applicationType)]) {
            rawType = MCPAppMsgSendObject(proxy, @selector(applicationType));
        }
        info[@"type"] = MCPNormalizedInstalledAppType(proxy, bundleId, rawType ?: @"");

        // Bundle (.app) path.
        NSString *bundlePath = nil;
        if ([proxy respondsToSelector:@selector(bundleURL)]) {
            id bundleURL = MCPAppMsgSendObject(proxy, @selector(bundleURL));
            if ([bundleURL isKindOfClass:[NSURL class]]) {
                bundlePath = [((NSURL *)bundleURL).path stringByStandardizingPath];
            }
        }
        if (bundlePath.length) info[@"bundle_path"] = bundlePath;

        // Data container (sandbox) path.
        NSString *dataContainer = nil;
        if ([proxy respondsToSelector:@selector(dataContainerURL)]) {
            id dataURL = MCPAppMsgSendObject(proxy, @selector(dataContainerURL));
            if ([dataURL isKindOfClass:[NSURL class]]) {
                dataContainer = [((NSURL *)dataURL).path stringByStandardizingPath];
            }
        }
        if (dataContainer.length) info[@"data_container"] = dataContainer;

        // App Group / shared container paths.
        if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
            id groupURLs = MCPAppMsgSendObject(proxy, @selector(groupContainerURLs));
            if ([groupURLs isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *groups = [NSMutableDictionary dictionary];
                [(NSDictionary *)groupURLs enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                    if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSURL class]]) {
                        groups[key] = [((NSURL *)obj).path stringByStandardizingPath];
                    }
                }];
                if (groups.count) info[@"group_containers"] = groups;
            }
        }

        // Version info from Info.plist.
        NSString *executablePath = nil;
        if (bundlePath.length) {
            NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
            if ([plist isKindOfClass:[NSDictionary class]]) {
                if ([plist[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]]) {
                    info[@"short_version"] = plist[@"CFBundleShortVersionString"];
                }
                if ([plist[@"CFBundleVersion"] isKindOfClass:[NSString class]]) {
                    info[@"version"] = plist[@"CFBundleVersion"];
                }
                if ([plist[@"DTPlatformVersion"] isKindOfClass:[NSString class]]) {
                    info[@"sdk_version"] = plist[@"DTPlatformVersion"];
                }
                if ([plist[@"MinimumOSVersion"] isKindOfClass:[NSString class]]) {
                    info[@"minimum_os_version"] = plist[@"MinimumOSVersion"];
                }
                NSString *executable = [plist[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? plist[@"CFBundleExecutable"] : nil;
                if (executable.length) {
                    executablePath = [bundlePath stringByAppendingPathComponent:executable];
                    info[@"executable_path"] = executablePath;
                }
            }
        }

        // Read entitlements from the main executable.
        if (executablePath.length) {
            NSDictionary *entitlements = MCPDumpEntitlementsFromBinaryAtPath(executablePath);
            if (entitlements.count) info[@"entitlements"] = entitlements;
        }

        result = [info copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (!result) {
        if (error) *error = failure ?: @"Failed to read app info";
        return nil;
    }
    return result;
}

@end
