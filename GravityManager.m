#import "GravityManager.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const kGIDomain = @"com.qcomtoolbox.gravityicons";
static NSString * const kGIEnabledKey = @"GIEnabled";
static NSString * const kGIStrengthKey = @"GIStrength";
static NSString * const kGIHideLabelsKey = @"GIHideLabels";
static CFStringRef const kGIReloadNotification = CFSTR("com.qcomtoolbox.gravityicons/ReloadPrefs");

// Real-world-ish acceleration in points/sec² at strength 1.0. UIKit's own
// UIGravityBehavior uses roughly 1000pt/s² per unit magnitude as a "feels
// right on a phone screen" baseline; this is tuned well above that so the
// effect reads as snappy rather than sluggish.
static const CGFloat kBaseGravityAcceleration = 7000.0;

// How hard an icon bounces off the page edge (0 = stops dead, 1 = perfectly
// elastic).
static const CGFloat kEdgeElasticity = 0.5;
// How hard two icons bounce off each other — pushed well above the edge
// value on purpose, so icons stay lively/bouncy against each other even
// once they've settled against an edge.
static const CGFloat kIconElasticity = 0.92;
static const CGFloat kFrictionPerSecond = 1.1;
// Hard velocity cap so higher acceleration + bouncier edges can't run away
// into jitter (points/sec).
static const CGFloat kMaxSpeed = 6000.0;

/// Finds the live icon/widget views on a page without calling any private,
/// version-fragile selector. `.subviews`/`.description` are always safe
/// Foundation/UIKit calls, so this can never throw an unrecognized-selector
/// exception the way guessing at e.g. `-viewForIcon:` could. Widget host
/// views don't necessarily contain "SBIcon" in their class name the way
/// plain app icons do, so this matches "icon" or "widget" case-insensitively
/// to pick up both.
static NSArray<UIView *> *GIIconViewsIn(UIView *listView) {
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    for (UIView *v in listView.subviews) {
        NSString *desc = [v.description lowercaseString];
        if ([desc containsString:@"icon"] || [desc containsString:@"widget"]) {
            [icons addObject:v];
        }
    }
    return icons;
}

/// Finds the name-label subview(s) inside a single icon/widget view, again
/// by scanning `.subviews`/`.description` rather than calling any private
/// selector — same safe technique as GIIconViewsIn. The label is nested a
/// level or two deeper than the icon view's direct children (behind an
/// inner content container), so this walks the whole subtree rather than
/// just direct subviews, and matches a few likely name fragments since the
/// exact private class name isn't known.
static void GICollectLabelSubviews(UIView *root, NSInteger depth, NSMutableArray<UIView *> *out) {
    if (!root || depth > 6) return;
    NSString *desc = [root.description lowercaseString];
    if ([desc containsString:@"label"] || [desc containsString:@"legibility"] || [desc containsString:@"title"]) {
        [out addObject:root];
        return; // don't also descend into a matched label's own subviews
    }
    for (UIView *sub in root.subviews) {
        GICollectLabelSubviews(sub, depth + 1, out);
    }
}

static NSArray<UIView *> *GIFindLabelSubviews(UIView *iconView) {
    NSMutableArray<UIView *> *labels = [NSMutableArray array];
    for (UIView *sub in iconView.subviews) {
        GICollectLabelSubviews(sub, 0, labels);
    }
    return labels;
}

#pragma mark - Per-icon physics state

@interface GIPhysicsState : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGPoint offset;   // visual offset applied via .transform
@property (nonatomic) CGPoint velocity; // points/sec
@property (nonatomic) CGRect homeFrame; // original frame, captured once, never written to
@property (nonatomic, strong) NSArray<UIView *> *labelViews; // hidden while gravity is active
@end

@implementation GIPhysicsState
@end

#pragma mark - Per-page physics session

/// Holds physics state for every icon on a single SBIconListView (one home
/// screen page). Deliberately never reads or writes `view.frame`/`.center` —
/// only `view.transform`, which is a pure compositing offset SpringBoard's
/// own layout system never looks at, so this cannot fight SpringBoard's icon
/// layout the way UIKit Dynamics (UIDynamicAnimator) did in an earlier
/// version of this file.
@interface GravitySession : NSObject
@property (nonatomic, weak) UIView *listView;
@property (nonatomic, strong) NSArray<GIPhysicsState *> *icons;
// The physics playfield: the union of every icon's own home frame, plus a
// small settle margin — NOT listView.bounds. listView.bounds extends well
// past the visible icon grid, down into the area the dock sits over, so
// clamping to it let icons fall behind the dock and made vertical travel
// look "slow" simply because it had much farther to go than horizontal
// travel did. Deriving the bound from the icons' own real layout sidesteps
// needing any private dock-frame API at all.
@property (nonatomic) CGRect contentBounds;
@end

@implementation GravitySession

- (instancetype)initWithListView:(UIView *)listView {
    self = [super init];
    if (self) {
        _listView = listView;
        NSMutableArray<GIPhysicsState *> *states = [NSMutableArray array];
        CGFloat heightSum = 0;
        for (UIView *v in GIIconViewsIn(listView)) {
            GIPhysicsState *state = [GIPhysicsState new];
            state.view = v;
            state.homeFrame = v.frame;
            state.offset = CGPointZero;
            state.velocity = CGPointZero;
            state.labelViews = GIFindLabelSubviews(v);
            [states addObject:state];
            heightSum += v.frame.size.height;
        }
        _icons = states;

        [self setLabelsHidden:[GravityManager sharedManager].hideLabels];

        // Anchoring the bottom edge to the union of *this page's own*
        // icons was the real bug: a sparsely-filled page's icon union
        // stops well above where a full grid would, so any fixed margin
        // added past it lands nowhere near the dock (icons stop too early)
        // — while a densely-filled page's union already reaches close to
        // the dock, so the same margin can overshoot into it (icons
        // overlap the dock). Both symptoms were the same bug measured from
        // the wrong reference point, not a real per-device difference.
        //
        // Anchoring to listView.bounds instead — which does extend down
        // through the dock — sidesteps how populated this particular page
        // happens to be. The dock-height estimate is based on icon size,
        // not screen height: dock/icon sizing is consistent across iPhone
        // models even though screen height isn't, so this shouldn't need
        // separate tuning per device the way a screen-height percentage did.
        CGFloat avgIconHeight = states.count > 0 ? heightSum / states.count : 0;
        // Two independent estimates of the dock's height, combined by
        // taking whichever gives MORE clearance rather than averaging —
        // not going under the dock matters more than maximizing travel
        // distance, so this deliberately errs conservative. Plus a fixed
        // safety border on top so icons don't visually dip under the dock
        // at the edges of a bouncy collision.
        CGFloat iconBasedEstimate = avgIconHeight > 0 ? avgIconHeight * 1.3 : 0;
        CGFloat screenBasedEstimate = CGRectGetHeight(listView.bounds) * 0.16;
        CGFloat dockHeightEstimate = MAX(iconBasedEstimate, screenBasedEstimate) + 10.0;

        // The dock is very likely its own SBIconListView-family instance,
        // hooked and registered exactly like a regular scrollable page —
        // which means the dock-clearance subtraction above was also being
        // applied to the dock's OWN (short, single-row) bounds, collapsing
        // its usable physics area to almost nothing and pinning its icons
        // near the top of that sliver. There's no second dock below the
        // dock to leave room for, so skip the subtraction for anything that
        // looks like the dock itself: either its class name says so, or its
        // bounds are too short to be a real multi-row scrollable page.
        BOOL isDockLike = [[listView.description lowercaseString] containsString:@"dock"] ||
                           (avgIconHeight > 0 && CGRectGetHeight(listView.bounds) < avgIconHeight * 1.8);
        CGFloat bottomInset = isDockLike ? 0 : dockHeightEstimate;

        CGFloat marginX = 4.0; // small cosmetic gap only — the clamp already stops each icon's real edge at the bounds edge
        _contentBounds = CGRectMake(listView.bounds.origin.x + marginX,
                                     listView.bounds.origin.y,
                                     MAX(0, listView.bounds.size.width - marginX * 2),
                                     MAX(0, listView.bounds.size.height - bottomInset));

        NSLog(@"[GravityIcons] geometry: listView.bounds=%@ avgIconHeight=%.1f isDockLike=%d dockHeightEstimate=%.1f -> contentBounds=%@ (bottom=%.1f)",
              NSStringFromCGRect(listView.bounds),
              avgIconHeight,
              isDockLike,
              dockHeightEstimate,
              NSStringFromCGRect(_contentBounds),
              CGRectGetMaxY(_contentBounds));
    }
    return self;
}

/// Clamps a proposed offset (for a view with the given home frame) so the
/// displaced rect stays within `bounds`, bouncing the matching velocity
/// component. Shared by the per-icon integration pass and the post-collision
/// cleanup pass.
static void GIClampSpeed(CGPoint *velocity) {
    CGFloat speed = hypot(velocity->x, velocity->y);
    if (speed > kMaxSpeed) {
        CGFloat scale = kMaxSpeed / speed;
        velocity->x *= scale;
        velocity->y *= scale;
    }
}

static void GIClampToBounds(CGRect homeFrame, CGRect bounds, CGPoint *offset, CGPoint *velocity) {
    CGRect displaced = CGRectOffset(homeFrame, offset->x, offset->y);

    if (displaced.origin.x < bounds.origin.x) {
        offset->x += (bounds.origin.x - displaced.origin.x);
        velocity->x = -velocity->x * kEdgeElasticity;
    } else if (CGRectGetMaxX(displaced) > CGRectGetMaxX(bounds)) {
        offset->x -= (CGRectGetMaxX(displaced) - CGRectGetMaxX(bounds));
        velocity->x = -velocity->x * kEdgeElasticity;
    }

    if (displaced.origin.y < bounds.origin.y) {
        offset->y += (bounds.origin.y - displaced.origin.y);
        velocity->y = -velocity->y * kEdgeElasticity;
    } else if (CGRectGetMaxY(displaced) > CGRectGetMaxY(bounds)) {
        offset->y -= (CGRectGetMaxY(displaced) - CGRectGetMaxY(bounds));
        velocity->y = -velocity->y * kEdgeElasticity;
    }
}

/// Integrates one tick of gravity for every icon on this page: applies
/// acceleration, clamps to the page bounds (edge bounce), resolves
/// icon-icon (and icon-widget) overlap by pushing pairs apart along their
/// axis of least penetration, then re-clamps anything collision pushed back
/// out of bounds. Icon counts per page are small (well under 30 even with
/// widgets), so the O(n²) pairwise collision pass is cheap at 60Hz.
///
/// Runs several smaller sub-steps instead of one big one for the same dt.
/// At the speeds this needs to feel snappy, an icon can cover most of its
/// own width in a single 1/60s tick — two icons can each jump past the
/// other's overlap check between one frame and the next without the single
/// end-of-tick position check ever seeing them touch (classic tunneling).
/// Sub-stepping checks collisions several times within that same tick, at a
/// fraction of the per-check displacement, without changing overall speed.
- (void)stepWithGravity:(CGVector)gravity strength:(CGFloat)strength dt:(NSTimeInterval)dt {
    static const NSInteger kSubsteps = 4;
    NSTimeInterval subDt = dt / kSubsteps;
    for (NSInteger i = 0; i < kSubsteps; i++) {
        [self stepOnceWithGravity:gravity strength:strength dt:subDt];
    }
}

- (void)stepOnceWithGravity:(CGVector)gravity strength:(CGFloat)strength dt:(NSTimeInterval)dt {
    UIView *listView = self.listView;
    if (!listView) return;
    CGRect bounds = self.contentBounds;
    if (CGRectIsEmpty(bounds)) return;

    CGFloat friction = MAX(0.0, 1.0 - kFrictionPerSecond * dt);
    NSArray<GIPhysicsState *> *icons = self.icons;

    // Pass 1: integrate acceleration/velocity/position, bounce off edges.
    for (GIPhysicsState *state in icons) {
        if (!state.view) continue;

        CGPoint velocity = state.velocity;
        velocity.x += gravity.dx * strength * kBaseGravityAcceleration * dt;
        velocity.y += gravity.dy * strength * kBaseGravityAcceleration * dt;
        velocity.x *= friction;
        velocity.y *= friction;
        GIClampSpeed(&velocity);

        CGPoint offset = state.offset;
        offset.x += velocity.x * dt;
        offset.y += velocity.y * dt;

        GIClampToBounds(state.homeFrame, bounds, &offset, &velocity);

        state.offset = offset;
        state.velocity = velocity;
    }

    // Pass 2: pairwise collision. Mass is approximated from each view's own
    // frame area, so a large widget shoves a small icon out of the way much
    // more than the icon shoves the widget.
    NSUInteger count = icons.count;
    for (NSUInteger i = 0; i < count; i++) {
        GIPhysicsState *a = icons[i];
        if (!a.view) continue;
        CGRect rectA = CGRectOffset(a.homeFrame, a.offset.x, a.offset.y);
        CGFloat massA = MAX(1.0, a.homeFrame.size.width * a.homeFrame.size.height);

        for (NSUInteger j = i + 1; j < count; j++) {
            GIPhysicsState *b = icons[j];
            if (!b.view) continue;
            CGRect rectB = CGRectOffset(b.homeFrame, b.offset.x, b.offset.y);
            if (!CGRectIntersectsRect(rectA, rectB)) continue;

            CGFloat overlapX = MIN(CGRectGetMaxX(rectA), CGRectGetMaxX(rectB)) - MAX(CGRectGetMinX(rectA), CGRectGetMinX(rectB));
            CGFloat overlapY = MIN(CGRectGetMaxY(rectA), CGRectGetMaxY(rectB)) - MAX(CGRectGetMinY(rectA), CGRectGetMinY(rectB));
            if (overlapX <= 0 || overlapY <= 0) continue;

            CGFloat massB = MAX(1.0, b.homeFrame.size.width * b.homeFrame.size.height);
            CGFloat invMassA = 1.0 / massA;
            CGFloat invMassB = 1.0 / massB;
            CGFloat totalInvMass = invMassA + invMassB;
            if (totalInvMass <= 0) continue;
            CGFloat shareA = invMassA / totalInvMass;
            CGFloat shareB = invMassB / totalInvMass;

            CGPoint offsetA = a.offset;
            CGPoint offsetB = b.offset;
            CGPoint velocityA = a.velocity;
            CGPoint velocityB = b.velocity;

            // Resolve along whichever axis has the smaller overlap, which
            // is the axis that actually separates the two rects. Position
            // correction (push apart) always applies to kill the overlap.
            // The velocity impulse below only applies if the two are
            // actually closing in on each other along that axis — icons
            // moving together (e.g. both falling under the same gravity,
            // the common case in a cluster) have ~zero relative velocity,
            // and the standard impulse formula correctly leaves that alone
            // instead of killing their shared momentum on every contact
            // tick, which is what made packed icons feel glued in place.
            if (overlapX < overlapY) {
                CGFloat direction = (CGRectGetMidX(rectA) < CGRectGetMidX(rectB)) ? -1.0 : 1.0;
                offsetA.x += direction * overlapX * shareA;
                offsetB.x -= direction * overlapX * shareB;

                CGFloat rel = velocityA.x - velocityB.x;
                if (rel * direction < 0) { // closing in, not separating/parallel
                    CGFloat impulse = -(1.0 + kIconElasticity) * rel / totalInvMass;
                    velocityA.x += impulse * invMassA;
                    velocityB.x -= impulse * invMassB;
                }
            } else {
                CGFloat direction = (CGRectGetMidY(rectA) < CGRectGetMidY(rectB)) ? -1.0 : 1.0;
                offsetA.y += direction * overlapY * shareA;
                offsetB.y -= direction * overlapY * shareB;

                CGFloat rel = velocityA.y - velocityB.y;
                if (rel * direction < 0) {
                    CGFloat impulse = -(1.0 + kIconElasticity) * rel / totalInvMass;
                    velocityA.y += impulse * invMassA;
                    velocityB.y -= impulse * invMassB;
                }
            }

            GIClampSpeed(&velocityA);
            GIClampSpeed(&velocityB);
            a.offset = offsetA;
            b.offset = offsetB;
            a.velocity = velocityA;
            b.velocity = velocityB;
            rectA = CGRectOffset(a.homeFrame, a.offset.x, a.offset.y);
        }
    }

    // Pass 3: collision can push something back outside the page bounds;
    // clamp once more and apply the final transform.
    for (GIPhysicsState *state in icons) {
        UIView *view = state.view;
        if (!view) continue;

        CGPoint offset = state.offset;
        CGPoint velocity = state.velocity;
        GIClampToBounds(state.homeFrame, bounds, &offset, &velocity);
        state.offset = offset;
        state.velocity = velocity;

        view.transform = CGAffineTransformMakeTranslation(offset.x, offset.y);
    }
}

/// Springs every icon's transform back to identity (its untouched home
/// frame) and lets go — frame/center were never modified, so there's
/// nothing to restore there.
- (void)restoreAndTearDown {
    NSArray<GIPhysicsState *> *icons = self.icons;
    [UIView animateWithDuration:0.4
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (GIPhysicsState *state in icons) {
            UIView *view = state.view;
            if (view) view.transform = CGAffineTransformIdentity;
        }
    } completion:nil];

    [self setLabelsHidden:NO];
}

- (void)setLabelsHidden:(BOOL)hidden {
    NSArray<GIPhysicsState *> *icons = self.icons;
    [UIView animateWithDuration:hidden ? 0.15 : 0.25 animations:^{
        for (GIPhysicsState *state in icons) {
            for (UIView *label in state.labelViews) {
                label.alpha = hidden ? 0.0 : 1.0;
            }
        }
    }];
}

@end

#pragma mark - GravityManager

@interface GravityManager ()
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) NSHashTable<UIView *> *registeredListViews;
@property (nonatomic, strong) NSMapTable<UIView *, GravitySession *> *sessions;
@property (nonatomic, assign) CGFloat strength;
@property (nonatomic, assign) CFTimeInterval lastTick;
@end

@implementation GravityManager

+ (instancetype)sharedManager {
    static GravityManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [GravityManager new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _registeredListViews = [NSHashTable weakObjectsHashTable];
        _sessions = [NSMapTable weakToStrongObjectsMapTable];
        _motionManager = [CMMotionManager new];
        [self reloadPreferences];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge const void *)(self),
                                         gravityPrefsChanged,
                                         kGIReloadNotification,
                                         NULL,
                                         CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

static void gravityPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[GravityManager sharedManager] reloadPreferences];
}

- (void)reloadPreferences {
    CFPropertyListRef enabledValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIEnabledKey, (__bridge CFStringRef)kGIDomain);
    if (enabledValue) {
        // CFBoolean and CFNumber both bridge to an NSNumber-compatible
        // object, so -boolValue handles whichever type PSSwitchCell wrote.
        _isEnabled = [(__bridge id)enabledValue boolValue];
        CFRelease(enabledValue);
    } else {
        _isEnabled = YES; // default on
    }

    CFPropertyListRef strengthValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIStrengthKey, (__bridge CFStringRef)kGIDomain);
    if (strengthValue) {
        self.strength = [(__bridge id)strengthValue doubleValue];
        CFRelease(strengthValue);
    } else {
        self.strength = 1.0;
    }
    if (self.strength <= 0.01) self.strength = 1.0;

    BOOL wasHidingLabels = _hideLabels;
    CFPropertyListRef hideLabelsValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIHideLabelsKey, (__bridge CFStringRef)kGIDomain);
    if (hideLabelsValue) {
        _hideLabels = [(__bridge id)hideLabelsValue boolValue];
        CFRelease(hideLabelsValue);
    } else {
        _hideLabels = YES; // default on
    }

    // Turning the feature off in Settings also kills any physics that's
    // currently running from a prior shake.
    if (!_isEnabled && _isActive) {
        [self setActive:NO];
    }

    // Apply a live toggle of the label preference to whatever's already
    // running, instead of waiting for the next shake to pick it up.
    if (_isActive && wasHidingLabels != _hideLabels) {
        for (GravitySession *session in [self allSessions]) {
            [session setLabelsHidden:_hideLabels];
        }
    }
}

- (void)toggleActive {
    if (!self.isEnabled) return;
    [self setActive:!self.isActive];
}

- (void)setActive:(BOOL)active {
    if (_isActive == active) return;
    _isActive = active;

    if (active) {
        for (UIView *listView in self.registeredListViews.allObjects) {
            [self attachToListView:listView];
        }
        [self startMotionUpdates];
    } else {
        [self.motionManager stopDeviceMotionUpdates];
        for (UIView *listView in [self.sessions.keyEnumerator allObjects]) {
            [self detachFromListView:listView];
        }
    }
}

- (void)registerListView:(UIView *)listView {
    if (!listView) return;
    [self.registeredListViews addObject:listView];
    if (self.isActive) {
        [self attachToListView:listView];
    }
}

- (void)unregisterListView:(UIView *)listView {
    if (!listView) return;
    [self.registeredListViews removeObject:listView];
    [self detachFromListView:listView];
}

- (void)attachToListView:(UIView *)listView {
    if (!self.isActive || !listView.window) return;
    if ([self.sessions objectForKey:listView]) return; // already running for this page

    @try {
        GravitySession *session = [[GravitySession alloc] initWithListView:listView];
        if (session.icons.count == 0) return;
        [self.sessions setObject:session forKey:listView];
    } @catch (NSException *exception) {
        NSLog(@"[GravityIcons] failed to attach physics to a page: %@", exception);
    }
}

- (void)detachFromListView:(UIView *)listView {
    GravitySession *session = [self.sessions objectForKey:listView];
    if (!session) return;
    [session restoreAndTearDown];
    [self.sessions removeObjectForKey:listView];
}

- (NSArray<GravitySession *> *)allSessions {
    NSMutableArray<GravitySession *> *result = [NSMutableArray array];
    for (GravitySession *session in self.sessions.objectEnumerator) {
        [result addObject:session];
    }
    return result;
}

- (void)startMotionUpdates {
    if (!self.motionManager.isDeviceMotionAvailable || self.motionManager.isDeviceMotionActive) return;

    self.lastTick = CACurrentMediaTime();

    __weak __typeof(self) weakSelf = self;
    self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0;
    [self.motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                              toQueue:[NSOperationQueue mainQueue]
                                                          withHandler:^(CMDeviceMotion * _Nullable motion, NSError * _Nullable error) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !motion || !strongSelf.isActive) return;

        CFTimeInterval now = CACurrentMediaTime();
        NSTimeInterval dt = now - strongSelf.lastTick;
        strongSelf.lastTick = now;
        if (dt <= 0 || dt > 0.25) dt = 1.0 / 60.0; // clamp huge gaps (e.g. after backgrounding)

        CGVector gravity = CGVectorMake(motion.gravity.x, -motion.gravity.y);
        @try {
            for (GravitySession *session in [strongSelf allSessions]) {
                [session stepWithGravity:gravity strength:strongSelf.strength dt:dt];
            }
        } @catch (NSException *exception) {
            NSLog(@"[GravityIcons] physics tick failed, stopping: %@", exception);
            [strongSelf setActive:NO];
        }
    }];
}

@end
