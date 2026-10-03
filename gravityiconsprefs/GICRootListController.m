#import "GICRootListController.h"
#import <spawn.h>
#import <unistd.h>

static BOOL GISpawn(const char *path, const char *const argv[]) {
    if (access(path, X_OK) != 0) return NO;
    pid_t pid;
    return posix_spawn(&pid, path, NULL, NULL, (char *const *)argv, NULL) == 0;
}

static void GIRespring(void) {
    const char *sbreload[] = {"sbreload", NULL};
    if (GISpawn("/var/jb/usr/bin/sbreload", sbreload)) return;

    const char *killall[] = {"killall", "-9", "SpringBoard", NULL};
    if (GISpawn("/var/jb/usr/bin/killall", killall)) return;
    GISpawn("/usr/bin/killall", killall);
}

@implementation GICRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
                                                                   message:@"SpringBoard will restart."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        GIRespring();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
