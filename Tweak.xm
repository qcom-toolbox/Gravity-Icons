#import <UIKit/UIKit.h>
#import "GravityManager.h"

// Minimal forward declarations. -layoutIconsNow is a long-standing,
// widely-used SBIconListView method (used unguarded by other published
// gravity/physics icon tweaks across many iOS versions), so it's hooked
// directly rather than treated as a risky guess. SBHomeScreenWindow only
// needs -motionEnded:withEvent:, which it inherits from UIResponder/UIWindow
// regardless of SpringBoard's private additions, so that hook is safe even
// if the rest of the class has changed.
@interface SBIconListView : UIView
- (void)layoutIconsNow;
@end

@interface SBHomeScreenWindow : UIWindow
@end

%hook SBIconListView

- (void)layoutIconsNow {
    %orig;
    [[GravityManager sharedManager] registerListView:self];
}

- (void)willMoveToWindow:(UIWindow *)window {
    %orig;
    if (!window) {
        [[GravityManager sharedManager] unregisterListView:self];
    }
}

%end

// Shake the device to toggle gravity on/off. Physics never runs
// automatically on boot/respring — only this explicit, deliberate,
// well-after-boot gesture turns it on, which is what keeps this safe.
%hook SBHomeScreenWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) {
        [[GravityManager sharedManager] toggleActive];
    }
}

%end

%ctor {
    @autoreleasepool {
        [GravityManager sharedManager];
    }
}
