#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Coordinates physics ("gravity") for every home screen page. Physics only
/// ever runs while `isActive` is YES, which nothing but a device shake turns
/// on (see Tweak.xm) — never automatically on boot/respring. `isEnabled`
/// (from Settings) just gates whether a shake is allowed to do that.
@interface GravityManager : NSObject

+ (instancetype)sharedManager;

/// Called from -layoutIconsNow for every SBIconListView SpringBoard lays
/// out. Cheap: just remembers the page exists. If physics is already active
/// when a new page registers (e.g. a page appears mid-session), it's
/// attached immediately too.
- (void)registerListView:(UIView *)listView;

/// Called when a page is about to leave the window (page recycled, folder
/// closed, etc). Forgets the page and tears down its physics if it had any.
- (void)unregisterListView:(UIView *)listView;

/// Flips the shake-activated physics engine on/off. No-ops if `isEnabled`
/// is NO (feature turned off in Settings).
- (void)toggleActive;

/// Re-reads the on/off + strength values from CFPreferences. Call after the
/// Settings toggle posts its darwin notification.
- (void)reloadPreferences;

@property (nonatomic, readonly) BOOL isEnabled;    // Settings toggle
@property (nonatomic, readonly) BOOL isActive;     // shake-toggled runtime state
@property (nonatomic, readonly) BOOL hideLabels;   // Settings toggle for app-name labels
@property (nonatomic, readonly) BOOL useBorders;   // Settings toggle: keep icons out of the status bar and dock
@property (nonatomic, readonly) BOOL showOutline;  // Settings toggle (debug): draw the active borders on screen

@end

NS_ASSUME_NONNULL_END
