#!/usr/bin/env python3
"""Run the production DEB installer on macOS with process/staging doubles.

No device is changed. Covers validation, dpkg failures, cleanup and restart timing.
"""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFIX = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#define APP_LOG(...) do {} while (0)
static NSUInteger stageCalls, dpkgCalls, cleanupCalls, restartCalls;
static BOOL stageOK, processOK, restartOK;
static int processExit;
static NSString *expectedPath;
static NSString *MCPStageDebForDpkg(NSString *path, NSString **staged, NSString **error) {
    stageCalls++;
    assert([path isEqual:expectedPath]);
    if (!stageOK) { *error = @"stage failed"; return nil; }
    *staged = @"/tmp/staged.deb";
    return *staged;
}
static BOOL MCPRunDpkgWithPrivileges(NSArray *args, NSTimeInterval timeout,
                                    NSUInteger limit, NSString **output, int *code, NSString **error) {
    dpkgCalls++;
    assert(([args isEqual:@[@"-i", @"/tmp/staged.deb"]]));
    assert(timeout == 180 && limit == 512 * 1024);
    *output = @"fixture dpkg output";
    *code = processExit;
    return processOK;
}
static void MCPRemoveShellPath(NSString *path) {
    assert([path isEqual:@"/tmp/staged.deb"]);
    cleanupCalls++;
}
static BOOL MCPScheduleSpringBoardRestart(NSString **error) {
    assert(cleanupCalls == 1);
    restartCalls++;
    if (!restartOK) *error = @"restart failed";
    return restartOK;
}
@interface AppManager : NSObject
- (BOOL)installDebPackage:(NSString *)path error:(NSString **)error;
@end
@implementation AppManager
'''
SUFFIX = r'''
@end
static void reset(void) {
    stageCalls = dpkgCalls = cleanupCalls = restartCalls = 0;
    stageOK = processOK = restartOK = YES; processExit = 0;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *root = @(argv[1]);
        NSFileManager *fm = NSFileManager.defaultManager;
        AppManager *manager = [AppManager new];
        for (NSString *name in @[@"app.ipa", @"app.IPA", @"app.tipa", @"app.TIPA", @"app.zip", @"app.deb.zip", @"noextension"]) {
            reset();
            NSString *path = [root stringByAppendingPathComponent:name];
            assert([fm createFileAtPath:path contents:[NSData data] attributes:nil]);
            NSString *error = nil;
            assert(![manager installDebPackage:path error:&error] && error.length);
            assert(!stageCalls && !dpkgCalls && !restartCalls);
        }
        for (NSString *path in @[@"", @"relative.deb", [root stringByAppendingPathComponent:@"missing.deb"]]) {
            reset(); NSString *error = nil;
            assert(![manager installDebPackage:path error:&error] && error.length);
            assert(!stageCalls && !dpkgCalls && !restartCalls);
        }
        NSString *directory = [root stringByAppendingPathComponent:@"directory.deb"];
        assert([fm createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]);
        reset(); assert(![manager installDebPackage:directory error:nil] && !stageCalls);
        for (NSString *name in @[@"package.deb", @"package.DEB", @"space quote ' package.DeB"]) {
            expectedPath = [root stringByAppendingPathComponent:name];
            assert([fm createFileAtPath:expectedPath contents:[NSData data] attributes:nil]);
            for (NSUInteger mode = 0; mode < 5; mode++) {
                reset();
                if (mode == 1) stageOK = NO;
                if (mode == 2) processOK = NO;
                if (mode == 3) processExit = 1;
                if (mode == 4) restartOK = NO;
                NSString *error = nil;
                assert([manager installDebPackage:expectedPath error:&error] == (mode == 0));
                assert(stageCalls == 1);
                assert(dpkgCalls == (mode == 1 ? 0 : 1));
                assert(cleanupCalls == dpkgCalls);
                assert(restartCalls == (mode == 0 || mode == 4 ? 1 : 0));
                if (mode) assert(error.length);
            }
        }
        puts("PASS DEB validation, dpkg failures, staging cleanup and restart ordering");
    }
}
'''

def main():
    source = (ROOT / 'AppManager.m').read_text()
    begin = source.index('- (BOOL)installDebPackage:')
    end = source.index('\n- (NSDictionary *)appInfoForBundleId:', begin)
    with tempfile.TemporaryDirectory(prefix='ios-mcp-deb-install-') as tmp:
        work = Path(tmp)
        harness = work / 'test.m'
        harness.write_text(PREFIX + source[begin:end] + SUFFIX)
        binary = work / 'test'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Werror',
                        '-framework', 'Foundation', str(harness), '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(work)], check=True)

if __name__ == '__main__':
    main()
