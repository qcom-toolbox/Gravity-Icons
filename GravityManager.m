#import "GravityManager.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

/// Dock detection by *class name*, not -description: the main page's
/// description mentions the dock somewhere, so a description match
/// classified the home screen page itself as the dock — which exempted it
/// from borders entirely and let icons fall straight under the real dock.
static BOOL GIIsDockClass(UIView *view) {
    return [[NSStringFromClass([view class]) lowercaseString] containsString:@"dock"];
}

static NSString * const kGIDomain = @"com.qcomtoolbox.gravityicons";
static NSString * const kGIEnabledKey = @"GIEnabled";
static NSString * const kGIStrengthKey = @"GIStrength";
static NSString * const kGIHideLabelsKey = @"GIHideLabels";
static NSString * const kGIBordersKey = @"GIBorders";
static NSString * const kGIOutlineKey = @"GIDebugOutline";
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
// A single pairwise resolution pass isn't enough for a cluster of icons all
// touching at once — fixing A-vs-B can reintroduce overlap with C, so a
// pile needs several passes per tick to actually converge instead of
// visibly interpenetrating/jittering.
static const NSInteger kCollisionIterations = 4;


// Rotation: icons pick up spin from bounces and collisions rather than
// spinning on their own in free fall (real torque only comes from an
// off-center impact, and approximating that properly isn't worth the
// complexity here). Kept subtle — a light tumble on impact, not a blur —
// and damped quickly so spin doesn't linger.
static const CGFloat kSpinPerBounceImpulse = 0.0005;    // edge bounces
static const CGFloat kSpinPerCollisionImpulse = 0.0007; // icon-icon hits
static const CGFloat kAngularFrictionPerSecond = 2.5;
static const CGFloat kMaxAngularSpeed = 6.0; // radians/sec

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

static void GICollectImageSubviews(UIView *root, NSInteger depth, NSMutableArray<UIView *> *out) {
    if (!root || depth > 6) return;
    NSString *desc = [root.description lowercaseString];
    if ([desc containsString:@"label"] || [desc containsString:@"badge"]) return;
    if ([desc containsString:@"image"]) [out addObject:root];
    for (UIView *sub in root.subviews) {
        GICollectImageSubviews(sub, depth + 1, out);
    }
}

static BOOL GIPlausibleArtRect(CGRect r, CGRect cell) {
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return NO;
    // Must span most of the cell's width: a smaller "image" (an overlay, or
    // a picture inside a widget) made the collision box smaller than what's
    // drawn, so the visible icon spilled past borders.
    return r.size.width >= cell.size.width * 0.5 && r.size.height >= 10 &&
           r.size.width * r.size.height >= cell.size.width * cell.size.height * 0.2;
}

/// The view that actually draws the artwork, found once at attach and then
/// measured live every frame. SBIconView's own -_iconImageView is preferred:
/// icon-theming tweaks add extra image layers, and a scan for any "image"
/// view sometimes picked a slightly offset one. Falls back to that scan.
static UIView *GIFindIconImageView(UIView *iconView) {
    SEL sel = NSSelectorFromString(@"_iconImageView");
    if ([iconView respondsToSelector:sel]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(iconView, sel);
        if ([candidate isKindOfClass:[UIView class]] && [(UIView *)candidate isDescendantOfView:iconView]) {
            return candidate;
        }
    }

    CGRect cell = iconView.bounds;
    NSMutableArray<UIView *> *images = [NSMutableArray array];
    for (UIView *sub in iconView.subviews) {
        GICollectImageSubviews(sub, 0, images);
    }
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *image in images) {
        CGRect r = CGRectIntersection([image convertRect:image.bounds toView:iconView], cell);
        CGFloat area = r.size.width * r.size.height;
        if (GIPlausibleArtRect(r, cell) && area > bestArea) {
            bestArea = area;
            best = image;
        }
    }
    return best;
}

/// The artwork's rect in `iconView`'s own bounds coordinates, measured live
/// — the box used for collisions/taps while names are hidden. Read every
/// frame rather than once: SpringBoard can re-lay out an icon's insides
/// while gravity runs, and a stale rect let the drawn icon drift inside
/// its box. Falls back to SpringBoard's reported artwork frame, then to the
/// cell trimmed at the label's top edge, then to the whole cell.
static CGRect GILiveArtRect(UIView *iconView, UIView *imageView, NSArray<UIView *> *labels) {
    CGRect cell = iconView.bounds;
    if (imageView && [imageView isDescendantOfView:iconView]) {
        CGRect r = CGRectIntersection([imageView convertRect:imageView.bounds toView:iconView], cell);
        if (GIPlausibleArtRect(r, cell)) return r;
    }

    SEL frameSel = NSSelectorFromString(@"iconImageFrame");
    if ([iconView respondsToSelector:frameSel]) {
        CGRect r = CGRectIntersection(((CGRect (*)(id, SEL))objc_msgSend)(iconView, frameSel), cell);
        if (GIPlausibleArtRect(r, cell)) return r;
    }

    CGFloat minLabelY = CGFLOAT_MAX;
    for (UIView *label in labels) {
        minLabelY = MIN(minLabelY, CGRectGetMinY([label convertRect:label.bounds toView:iconView]));
    }
    if (minLabelY < CGFLOAT_MAX && minLabelY - CGRectGetMinY(cell) > 10) {
        cell.size.height = MIN(cell.size.height, minLabelY - CGRectGetMinY(cell));
    }
    return cell;
}

/// SpringBoard's own tap-to-launch almost certainly hit-tests against each
/// icon's static grid position rather than the live, transformed view we're
/// animating, so a tap where the icon visually *is* wouldn't reach it. Our
/// own gesture recognizer (added directly to the icon view) correctly
/// tracks the live transform, so once a tap reaches us, this tries to open
/// the app directly via LSApplicationWorkspace — the same long-standing
/// mechanism most jailbreak tweaks use to launch apps programmatically.
/// Every step is a dynamic, respondsToSelector-guarded message send (no
/// compile-time private class needed), and failure anywhere just means
/// nothing happens — the caller still settles the icon back home either
/// way, so a follow-up tap works normally.
static void GITryOpenApp(UIView *iconView) {
    if (![iconView respondsToSelector:@selector(icon)]) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id iconModel = [iconView performSelector:@selector(icon)];
    if (!iconModel || ![iconModel respondsToSelector:@selector(bundleIdentifier)]) return;
    id bundleID = [iconModel performSelector:@selector(bundleIdentifier)];
#pragma clang diagnostic pop

    if (![bundleID isKindOfClass:[NSString class]] || [(NSString *)bundleID length] == 0) return;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultWorkspaceSel]) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [workspaceClass performSelector:defaultWorkspaceSel];
#pragma clang diagnostic pop
    if (!workspace) return;

    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![workspace respondsToSelector:openSel]) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [workspace performSelector:openSel withObject:bundleID];
#pragma clang diagnostic pop
}

// Declared up here so GravitySession (implemented before GravityManager)
// can use it.
@interface GravityManager ()
@property (nonatomic) BOOL isActivating; // YES only while a shake is switching gravity on
- (void)trackHiddenLabels:(NSArray<UIView *> *)labels;
- (CGFloat)dockTopInView:(UIView *)view; // CGFLOAT_MAX if the dock can't be found
@end

static void GICollectStatusBarViews(UIView *root, NSInteger depth, NSMutableArray<UIView *> *out) {
    if (!root || root.hidden || depth > 12) return;
    if ([[NSStringFromClass([root class]) lowercaseString] containsString:@"statusbar"]) {
        [out addObject:root];
        return;
    }
    for (UIView *sub in root.subviews) {
        GICollectStatusBarViews(sub, depth + 1, out);
    }
}

/// Bottom edge of the status bar, in screen coordinates, measured from the
/// actual status bar view. SpringBoard draws it in its own window, and
/// inside SpringBoard the safe-area inset and the scene's status bar height
/// can both read 0, so those alone left the top border stuck at a 20pt
/// guess — too short for a notched phone's 44pt bar. Only views that are
/// actually shaped like a status bar count: pinned to the top, at least
/// half the screen wide, 10–80pt tall.
static CGFloat GIMeasuredStatusBarBottomOnScreen(void) {
    UIScreen *screen = UIScreen.mainScreen;
    NSMutableSet<UIWindow *> *windows = [NSMutableSet setWithArray:UIApplication.sharedApplication.windows];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }

    CGFloat bottom = 0;
    for (UIWindow *window in windows) {
        if (window.hidden) continue;
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        GICollectStatusBarViews(window, 0, candidates);
        for (UIView *bar in candidates) {
            CGRect r = [bar convertRect:bar.bounds toCoordinateSpace:screen.coordinateSpace];
            if (CGRectGetMinY(r) > 10 || r.size.height < 10 || r.size.height > 80) continue;
            if (r.size.width < CGRectGetWidth(screen.bounds) * 0.5) continue;
            bottom = MAX(bottom, CGRectGetMaxY(r));
        }
    }
    return bottom;
}

/// Bottom edge of the status bar, in `view`'s coordinates. Takes the
/// largest of the measured status bar view, the window's safe-area inset
/// and the scene's status bar height (any of them can read 0 inside
/// SpringBoard), never less than the 20pt classic bar.
static CGFloat GIStatusBarBottomInView(UIView *view, NSString **outSource) {
    UIWindow *window = view.window;
    if (!window) return CGRectGetMinY(view.bounds);

    CGFloat measured = GIMeasuredStatusBarBottomOnScreen();
    CGFloat inset = MAX(window.safeAreaInsets.top, window.windowScene.statusBarManager.statusBarFrame.size.height);
    CGFloat height = MAX(MAX(measured, inset), 20.0);
    if (outSource) {
        *outSource = measured >= inset && measured >= 20.0 ? @"measured" : (inset >= 20.0 ? @"inset" : @"20pt");
    }

    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    return [view convertPoint:CGPointMake(0, height) fromCoordinateSpace:screen.coordinateSpace].y;
}

#pragma mark - Per-icon physics state

/// The icon view's layer geometry, as Core Animation uses it to draw: the
/// view's transform is applied around `anchorPoint`, which sits at
/// `position` in the list view. Modeling the rotation pivot as the cell's
/// center instead (assuming anchorPoint is always 0.5/0.5) is part of what
/// let the drawn icon drift inside its collision box.
typedef struct {
    CGRect bounds;
    CGPoint position;
    CGPoint anchor;
} GIViewGeometry;

@interface GIPhysicsState : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) UIView *imageView; // draws the artwork; measured live each frame
@property (nonatomic) CGPoint offset;   // visual offset applied via .transform
@property (nonatomic) CGPoint velocity; // points/sec
@property (nonatomic) CGFloat rotation;        // radians, applied via .transform
@property (nonatomic) CGFloat angularVelocity; // radians/sec
@property (nonatomic, strong) NSArray<UIView *> *labelViews; // hidden while gravity is active
// Refreshed once per frame by -refreshGeometry; read from the live view,
// never captured once, since SpringBoard re-lays out icons (and their
// insides) on its own while gravity runs.
@property (nonatomic) GIViewGeometry geometry;
@property (nonatomic) CGRect artRect; // artwork only, in the view's bounds coordinates
@end

@implementation GIPhysicsState

- (void)refreshGeometry {
    UIView *view = self.view;
    if (!view) return;
    CALayer *layer = view.layer;
    self.geometry = (GIViewGeometry){ view.bounds, layer.position, layer.anchorPoint };
    self.artRect = GILiveArtRect(view, self.imageView, self.labelViews);
}

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
@property (nonatomic, weak) UITapGestureRecognizer *listTapRecognizer;
@property (nonatomic) BOOL labelsHidden;
@property (nonatomic) NSUInteger ticksSinceLabelScan;
@property (nonatomic) CGFloat avgIconHeight;
@property (nonatomic) BOOL isDockLike;
@property (nonatomic, strong) UIView *outlineView;
@property (nonatomic, strong) UILabel *outlineLabel;
@property (nonatomic, strong) CAShapeLayer *boxLayer; // each icon's live collision box, debug outline only
@end

@implementation GravitySession

/// Collision/tap box, in the icon view's own bounds coordinates: just the
/// artwork while names are hidden (an invisible label shouldn't bump into
/// anything), the whole cell when they're shown.
- (CGRect)hitFrameFor:(GIPhysicsState *)state {
    return self.labelsHidden ? state.artRect : state.geometry.bounds;
}

- (instancetype)initWithListView:(UIView *)listView {
    self = [super init];
    if (self) {
        _listView = listView;
        NSMutableArray<GIPhysicsState *> *states = [NSMutableArray array];
        CGFloat heightSum = 0;
        for (UIView *v in GIIconViewsIn(listView)) {
            GIPhysicsState *state = [GIPhysicsState new];
            state.view = v;
            state.offset = CGPointZero;
            state.velocity = CGPointZero;
            state.rotation = 0;
            state.angularVelocity = 0;
            state.labelViews = GIFindLabelSubviews(v);
            state.imageView = GIFindIconImageView(v);
            [state refreshGeometry];

            [states addObject:state];
            heightSum += v.bounds.size.height;
        }
        _icons = states;

        // A recognizer added directly to an icon view never fired in
        // testing — SpringBoard's list view almost certainly intercepts
        // touches and does its own hit-testing before they'd ever reach an
        // individual icon subview. One recognizer on the list view instead,
        // doing our own hit-testing by hand against each icon's *current*
        // (offset) rect, sidesteps that entirely — it never depends on the
        // view hierarchy's own hit-testing at all.
        UITapGestureRecognizer *listTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(gi_handleListTap:)];
        [listView addGestureRecognizer:listTap];
        _listTapRecognizer = listTap;

        // Fade only when gravity is being switched on by a shake; re-attaching
        // after coming back from an app should hide names instantly, or they
        // visibly flash back for a moment.
        GravityManager *manager = [GravityManager sharedManager];
        [self setLabelsHidden:manager.hideLabels animated:manager.isActivating];

        _avgIconHeight = states.count > 0 ? heightSum / states.count : 0;

        // The dock is its own SBIconListView-family instance, hooked and
        // registered exactly like a scrollable page. Its icons stay inside
        // its own bounds and never get status-bar/dock borders — there's no
        // second dock below the dock to keep out of.
        _isDockLike = GIIsDockClass(listView) ||
                      (_avgIconHeight > 0 && CGRectGetHeight(listView.bounds) < _avgIconHeight * 1.8);

        [self updateContentBounds];
    }
    return self;
}

/// Recomputed at attach time and whenever the borders toggle changes.
/// Borders on: icons stay below the status bar and above the dock. Off:
/// they can use the whole page, status bar and dock area included.
- (void)updateContentBounds {
    UIView *listView = self.listView;
    if (!listView) return;
    CGRect page = listView.bounds;
    CGFloat marginX = 4.0; // small cosmetic gap only — the clamp already stops each icon's real edge at the bounds edge
    CGFloat top = CGRectGetMinY(page);
    CGFloat bottom = CGRectGetMaxY(page);

    GravityManager *manager = [GravityManager sharedManager];
    NSString *statusBarSource = nil;
    CGFloat statusBarBottom = GIStatusBarBottomInView(listView, &statusBarSource);
    CGFloat dockTop = [manager dockTopInView:listView];
    NSString *bottomSource = @"page";

    if (manager.useBorders && !self.isDockLike) {
        top = MAX(top, statusBarBottom + 2.0);

        // Measured from the real dock view when it can be found — a fixed
        // estimate was too tight on one screen size and too loose on the
        // other. Rejected if it would leave less than two rows of room,
        // which can only mean it measured the wrong thing.
        CGFloat minimumHeight = self.avgIconHeight * 2.0;
        if (dockTop < CGFLOAT_MAX && dockTop - 4.0 - top >= minimumHeight) {
            bottom = MIN(bottom, dockTop - 4.0);
            bottomSource = @"dock";
        } else {
            // Fallback: two independent estimates of the dock's height,
            // taking whichever gives more clearance, plus a safety margin.
            CGFloat iconBasedEstimate = self.avgIconHeight * 1.3;
            CGFloat screenBasedEstimate = CGRectGetHeight(page) * 0.16;
            bottom -= MAX(iconBasedEstimate, screenBasedEstimate) + 10.0;
            bottomSource = @"estimate";
        }
    }

    self.contentBounds = CGRectMake(CGRectGetMinX(page) + marginX,
                                    top,
                                    MAX(0, CGRectGetWidth(page) - marginX * 2),
                                    MAX(0, bottom - top));

    NSString *summary = [NSString stringWithFormat:@"%@ borders=%d page=%.0f-%.0f statusbar=%.0f(%@) docktop=%@ -> %.0f-%.0f (%@)",
                         self.isDockLike ? @"DOCK" : @"PAGE",
                         manager.useBorders,
                         CGRectGetMinY(page), CGRectGetMaxY(page),
                         statusBarBottom, statusBarSource,
                         dockTop < CGFLOAT_MAX ? [NSString stringWithFormat:@"%.0f", dockTop] : @"none",
                         CGRectGetMinY(self.contentBounds), CGRectGetMaxY(self.contentBounds),
                         bottomSource];
    NSLog(@"[GravityIcons] geometry: %@", summary);
    [self updateOutlineWithSummary:summary];
}

/// Debug aid behind a Settings switch: draws the exact rectangle icons are
/// being kept inside, plus the numbers it was computed from, so a
/// screenshot shows whether a border is measured wrong or measured right
/// but not enforced.
- (void)updateOutlineWithSummary:(NSString *)summary {
    if (![GravityManager sharedManager].showOutline) {
        [self removeOutline];
        return;
    }
    UIView *listView = self.listView;
    if (!listView) return;

    UIView *outline = self.outlineView;
    UILabel *text = self.outlineLabel;
    if (!outline) {
        outline = [[UIView alloc] init];
        outline.userInteractionEnabled = NO;
        outline.backgroundColor = UIColor.clearColor;
        outline.layer.borderWidth = 2.0;
        text = [[UILabel alloc] init];
        text.numberOfLines = 0;
        text.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
        text.textColor = UIColor.whiteColor;
        text.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [outline addSubview:text];
        CAShapeLayer *boxes = [CAShapeLayer layer];
        boxes.fillColor = UIColor.clearColor.CGColor;
        boxes.strokeColor = UIColor.yellowColor.CGColor;
        boxes.lineWidth = 1.0;
        [outline.layer addSublayer:boxes];
        self.outlineView = outline;
        self.outlineLabel = text;
        self.boxLayer = boxes;
    }
    outline.layer.borderColor = (self.isDockLike ? UIColor.cyanColor : UIColor.redColor).CGColor;
    outline.frame = self.contentBounds;
    text.text = summary;
    CGSize size = [text sizeThatFits:CGSizeMake(CGRectGetWidth(self.contentBounds) - 8, CGFLOAT_MAX)];
    text.frame = CGRectMake(4, 4, size.width, size.height);
    [listView addSubview:outline];
}

- (void)removeOutline {
    [self.outlineView removeFromSuperview];
    self.outlineView = nil;
    self.outlineLabel = nil;
    self.boxLayer = nil;
}

#pragma mark - Oriented-box geometry

/// A rectangle that can be rotated — an icon's live collision shape, built
/// fresh each check from its (fixed) frame plus its current offset and
/// rotation. Pure geometry, no state of its own.
typedef struct {
    CGPoint center;
    CGFloat halfWidth;
    CGFloat halfHeight;
    CGFloat angle; // radians
} GIBox;

/// Where `localRect` (in the view's own bounds coordinates) is drawn in the
/// list view once `.transform` = rotate-then-translate(offset) is applied —
/// the same math Core Animation uses: rotation happens around the layer's
/// anchor point, which sits at `position`. A sub-rect like the artwork
/// therefore orbits the anchor rather than spinning in place.
static GIBox GIBoxMake(CGRect localRect, GIViewGeometry geometry, CGPoint offset, CGFloat rotation) {
    CGFloat anchorX = CGRectGetMinX(geometry.bounds) + geometry.anchor.x * CGRectGetWidth(geometry.bounds);
    CGFloat anchorY = CGRectGetMinY(geometry.bounds) + geometry.anchor.y * CGRectGetHeight(geometry.bounds);
    CGFloat dx = CGRectGetMidX(localRect) - anchorX, dy = CGRectGetMidY(localRect) - anchorY;
    CGFloat c = cos(rotation), s = sin(rotation);
    GIBox box;
    box.center = CGPointMake(geometry.position.x + dx * c - dy * s + offset.x,
                             geometry.position.y + dx * s + dy * c + offset.y);
    box.halfWidth = localRect.size.width / 2.0;
    box.halfHeight = localRect.size.height / 2.0;
    box.angle = rotation;
    return box;
}

static void GIBoxAxes(GIBox box, CGVector axes[2]) {
    axes[0] = CGVectorMake(cos(box.angle), sin(box.angle));
    axes[1] = CGVectorMake(-sin(box.angle), cos(box.angle));
}

static void GIBoxCorners(GIBox box, CGPoint corners[4]) {
    CGVector axes[2];
    GIBoxAxes(box, axes);
    CGVector ex = CGVectorMake(axes[0].dx * box.halfWidth, axes[0].dy * box.halfWidth);
    CGVector ey = CGVectorMake(axes[1].dx * box.halfHeight, axes[1].dy * box.halfHeight);
    corners[0] = CGPointMake(box.center.x - ex.dx - ey.dx, box.center.y - ex.dy - ey.dy);
    corners[1] = CGPointMake(box.center.x + ex.dx - ey.dx, box.center.y + ex.dy - ey.dy);
    corners[2] = CGPointMake(box.center.x + ex.dx + ey.dx, box.center.y + ex.dy + ey.dy);
    corners[3] = CGPointMake(box.center.x - ex.dx + ey.dx, box.center.y - ex.dy + ey.dy);
}

/// Axis-aligned bounding box of a (possibly rotated) box — used against the
/// walls/dock, which are always axis-aligned, so a tilted icon's swept
/// extent (slightly larger than its unrotated frame) is what's tested, not
/// its unrotated frame.
static CGRect GIBoxAABB(GIBox box) {
    CGPoint corners[4];
    GIBoxCorners(box, corners);
    CGFloat minX = corners[0].x, maxX = corners[0].x;
    CGFloat minY = corners[0].y, maxY = corners[0].y;
    for (int i = 1; i < 4; i++) {
        minX = MIN(minX, corners[i].x); maxX = MAX(maxX, corners[i].x);
        minY = MIN(minY, corners[i].y); maxY = MAX(maxY, corners[i].y);
    }
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

static void GIProjectCorners(CGPoint corners[4], CGVector axis, CGFloat *outMin, CGFloat *outMax) {
    CGFloat minV = corners[0].x * axis.dx + corners[0].y * axis.dy;
    CGFloat maxV = minV;
    for (int i = 1; i < 4; i++) {
        CGFloat proj = corners[i].x * axis.dx + corners[i].y * axis.dy;
        minV = MIN(minV, proj);
        maxV = MAX(maxV, proj);
    }
    *outMin = minV;
    *outMax = maxV;
}

/// Separating Axis Theorem test between two (possibly rotated) boxes. A
/// rectangle only has 2 distinct edge-normal directions, so 4 candidate
/// axes (2 per box) are all that need checking. Returns NO the moment any
/// axis shows a gap (a proof they don't overlap); otherwise returns the
/// axis of *least* overlap as the push-apart direction — the standard,
/// correct way to separate two overlapping oriented rectangles.
static BOOL GIBoxesOverlap(GIBox a, GIBox b, CGVector *outAxis, CGFloat *outOverlap) {
    CGVector axesA[2], axesB[2];
    GIBoxAxes(a, axesA);
    GIBoxAxes(b, axesB);
    CGPoint cornersA[4], cornersB[4];
    GIBoxCorners(a, cornersA);
    GIBoxCorners(b, cornersB);
    CGVector testAxes[4] = { axesA[0], axesA[1], axesB[0], axesB[1] };

    CGFloat bestOverlap = CGFLOAT_MAX;
    CGVector bestAxis = CGVectorMake(1, 0);

    for (int i = 0; i < 4; i++) {
        CGFloat minA, maxA, minB, maxB;
        GIProjectCorners(cornersA, testAxes[i], &minA, &maxA);
        GIProjectCorners(cornersB, testAxes[i], &minB, &maxB);
        CGFloat overlap = MIN(maxA, maxB) - MAX(minA, minB);
        if (overlap <= 0) return NO;
        if (overlap < bestOverlap) {
            bestOverlap = overlap;
            bestAxis = testAxes[i];
        }
    }

    CGVector centerDiff = CGVectorMake(a.center.x - b.center.x, a.center.y - b.center.y);
    if (centerDiff.dx * bestAxis.dx + centerDiff.dy * bestAxis.dy < 0) {
        bestAxis = CGVectorMake(-bestAxis.dx, -bestAxis.dy);
    }
    *outAxis = bestAxis;
    *outOverlap = bestOverlap;
    return YES;
}

/// Point containment test respecting rotation — used for tap hit-testing so
/// the tappable area actually matches what's drawn on screen.
static BOOL GIBoxContainsPoint(GIBox box, CGPoint point) {
    CGFloat dx = point.x - box.center.x;
    CGFloat dy = point.y - box.center.y;
    CGFloat c = cos(-box.angle), s = sin(-box.angle);
    CGFloat localX = dx * c - dy * s;
    CGFloat localY = dx * s + dy * c;
    return fabs(localX) <= box.halfWidth && fabs(localY) <= box.halfHeight;
}

static void GIClampSpeed(CGPoint *velocity) {
    CGFloat speed = hypot(velocity->x, velocity->y);
    if (speed > kMaxSpeed) {
        CGFloat scale = kMaxSpeed / speed;
        velocity->x *= scale;
        velocity->y *= scale;
    }
}

/// Clamps a proposed offset so the icon's *rotated* bounding box stays
/// within `bounds`, bouncing the matching velocity component.
/// `angularVelocity` may be NULL when the caller doesn't want bounces to
/// impart spin (not currently used that way, but keeps this reusable).
///
/// Spin on bounce is derived from the *tangential* velocity at the wall —
/// e.g. hitting a side wall while sliding downward spins it consistently
/// one way, like rolling contact — rather than a random coin flip. Same
/// physical trigger (an impact happened), deterministic response.
static void GIClampToBounds(CGRect hitFrame, GIViewGeometry geometry, CGFloat rotation, CGRect bounds, CGPoint *offset, CGPoint *velocity, CGFloat *angularVelocity) {
    CGRect displaced = GIBoxAABB(GIBoxMake(hitFrame, geometry, *offset, rotation));
    BOOL xBounced = NO, yBounced = NO;

    if (displaced.origin.x < bounds.origin.x) {
        offset->x += (bounds.origin.x - displaced.origin.x);
        velocity->x = -velocity->x * kEdgeElasticity;
        xBounced = YES;
    } else if (CGRectGetMaxX(displaced) > CGRectGetMaxX(bounds)) {
        offset->x -= (CGRectGetMaxX(displaced) - CGRectGetMaxX(bounds));
        velocity->x = -velocity->x * kEdgeElasticity;
        xBounced = YES;
    }

    if (displaced.origin.y < bounds.origin.y) {
        offset->y += (bounds.origin.y - displaced.origin.y);
        velocity->y = -velocity->y * kEdgeElasticity;
        yBounced = YES;
    } else if (CGRectGetMaxY(displaced) > CGRectGetMaxY(bounds)) {
        offset->y -= (CGRectGetMaxY(displaced) - CGRectGetMaxY(bounds));
        velocity->y = -velocity->y * kEdgeElasticity;
        yBounced = YES;
    }

    if (angularVelocity) {
        if (xBounced) *angularVelocity += velocity->y * kSpinPerBounceImpulse;
        if (yBounced) *angularVelocity -= velocity->x * kSpinPerBounceImpulse;
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
    for (GIPhysicsState *state in self.icons) {
        [state refreshGeometry];
    }
    NSTimeInterval subDt = dt / kSubsteps;
    for (NSInteger i = 0; i < kSubsteps; i++) {
        [self stepOnceWithGravity:gravity strength:strength dt:subDt];
    }
    [self enforceLabelsHidden];
    [self updateIconBoxOverlay];
}

/// Debug outline only: traces each icon's live collision box, so a
/// screenshot shows directly whether the box matches the drawn icon.
- (void)updateIconBoxOverlay {
    CAShapeLayer *layer = self.boxLayer;
    if (!layer) return;
    CGPoint origin = self.contentBounds.origin;
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (GIPhysicsState *state in self.icons) {
        if (!state.view) continue;
        CGPoint corners[4];
        GIBoxCorners(GIBoxMake([self hitFrameFor:state], state.geometry, state.offset, state.rotation), corners);
        [path moveToPoint:CGPointMake(corners[0].x - origin.x, corners[0].y - origin.y)];
        for (int i = 1; i < 4; i++) {
            [path addLineToPoint:CGPointMake(corners[i].x - origin.x, corners[i].y - origin.y)];
        }
        [path closePath];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.path = path.CGPath;
    [CATransaction commit];
}

- (void)stepOnceWithGravity:(CGVector)gravity strength:(CGFloat)strength dt:(NSTimeInterval)dt {
    UIView *listView = self.listView;
    if (!listView) return;
    CGRect bounds = self.contentBounds;
    if (CGRectIsEmpty(bounds)) return;

    CGFloat friction = MAX(0.0, 1.0 - kFrictionPerSecond * dt);
    CGFloat angularFriction = MAX(0.0, 1.0 - kAngularFrictionPerSecond * dt);
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

        CGFloat angularVelocity = state.angularVelocity * angularFriction;
        GIClampToBounds([self hitFrameFor:state], state.geometry, state.rotation, bounds, &offset, &velocity, &angularVelocity);
        if (fabs(angularVelocity) > kMaxAngularSpeed) angularVelocity = copysign(kMaxAngularSpeed, angularVelocity);

        state.offset = offset;
        state.velocity = velocity;
        state.rotation += angularVelocity * dt;
        state.angularVelocity = angularVelocity;
    }

    // Pass 2: pairwise collision using the icon's *rotated* hit box (just
    // the artwork while names are hidden, so invisible text doesn't
    // collide) via proper oriented-box overlap (SAT), not a plain
    // axis-aligned rect check. Mass is approximated from each view's own
    // frame area, so a large widget shoves a small icon out of the way much
    // more than the icon shoves the widget. Repeated several times so a
    // cluster of icons all touching at once actually converges instead of
    // visibly interpenetrating (resolving A-vs-B can reintroduce overlap
    // with C, which only a bad single pass would leave uncorrected).
    NSUInteger count = icons.count;
    for (NSInteger iteration = 0; iteration < kCollisionIterations; iteration++) {
    for (NSUInteger i = 0; i < count; i++) {
        GIPhysicsState *a = icons[i];
        if (!a.view) continue;

        for (NSUInteger j = i + 1; j < count; j++) {
            GIPhysicsState *b = icons[j];
            if (!b.view) continue;

            CGRect frameA = [self hitFrameFor:a], frameB = [self hitFrameFor:b];
            GIBox boxA = GIBoxMake(frameA, a.geometry, a.offset, a.rotation);
            GIBox boxB = GIBoxMake(frameB, b.geometry, b.offset, b.rotation);
            CGVector axis;
            CGFloat overlap;
            if (!GIBoxesOverlap(boxA, boxB, &axis, &overlap)) continue;

            CGFloat massA = MAX(1.0, frameA.size.width * frameA.size.height);
            CGFloat massB = MAX(1.0, frameB.size.width * frameB.size.height);
            CGFloat invMassA = 1.0 / massA;
            CGFloat invMassB = 1.0 / massB;
            CGFloat totalInvMass = invMassA + invMassB;
            if (totalInvMass <= 0) continue;
            CGFloat shareA = invMassA / totalInvMass;
            CGFloat shareB = invMassB / totalInvMass;

            CGPoint offsetA = a.offset;
            CGPoint offsetB = b.offset;
            offsetA.x += axis.dx * overlap * shareA;
            offsetA.y += axis.dy * overlap * shareA;
            offsetB.x -= axis.dx * overlap * shareB;
            offsetB.y -= axis.dy * overlap * shareB;

            CGPoint velocityA = a.velocity;
            CGPoint velocityB = b.velocity;

            // Position correction (push apart along the true separating
            // axis) always applies. The velocity impulse — and the spin
            // kick tied to it — only applies if the two are actually
            // closing in on each other along that axis. Icons moving
            // together (e.g. both falling under the same gravity, the
            // common case in a cluster) or just resting in continued
            // contact have ~zero closing velocity; applying the
            // impulse/spin unconditionally on every tick they merely touch
            // — not just when they actually hit — was what made packed
            // icons feel glued together earlier, and separately was the
            // actual cause of the "spins for no reason" bug: icons resting
            // together kept re-triggering a "collision" every tick with no
            // real impact behind it.
            CGFloat relNormal = (velocityA.x - velocityB.x) * axis.dx + (velocityA.y - velocityB.y) * axis.dy;
            if (relNormal < 0) { // closing in, not separating/parallel
                CGFloat impulse = -(1.0 + kIconElasticity) * relNormal / totalInvMass;
                velocityA.x += impulse * axis.dx * invMassA;
                velocityA.y += impulse * axis.dy * invMassA;
                velocityB.x -= impulse * axis.dx * invMassB;
                velocityB.y -= impulse * axis.dy * invMassB;

                // Spin from the tangential relative velocity (perpendicular
                // to the separating axis), only on an actual impact —
                // deterministic, not a coin flip.
                CGVector tangent = CGVectorMake(-axis.dy, axis.dx);
                CGFloat tangentialRel = (velocityA.x - velocityB.x) * tangent.dx + (velocityA.y - velocityB.y) * tangent.dy;
                CGFloat kick = tangentialRel * kSpinPerCollisionImpulse;
                a.angularVelocity += kick;
                b.angularVelocity -= kick;
            }

            GIClampSpeed(&velocityA);
            GIClampSpeed(&velocityB);
            a.offset = offsetA;
            b.offset = offsetB;
            a.velocity = velocityA;
            b.velocity = velocityB;
        }
    }
    }

    // Pass 3: collision can push something back outside the page bounds;
    // clamp once more and apply the final transform.
    for (GIPhysicsState *state in icons) {
        UIView *view = state.view;
        if (!view) continue;

        CGPoint offset = state.offset;
        CGPoint velocity = state.velocity;
        CGFloat angularVelocity = state.angularVelocity;
        GIClampToBounds([self hitFrameFor:state], state.geometry, state.rotation, bounds, &offset, &velocity, &angularVelocity);
        if (fabs(angularVelocity) > kMaxAngularSpeed) angularVelocity = copysign(kMaxAngularSpeed, angularVelocity);
        state.offset = offset;
        state.velocity = velocity;
        state.angularVelocity = angularVelocity;

        CGAffineTransform t = CGAffineTransformMakeTranslation(offset.x, offset.y);
        view.transform = CGAffineTransformRotate(t, state.rotation);
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

    [self setLabelsHidden:NO animated:YES];

    UIView *listView = self.listView;
    UITapGestureRecognizer *listTap = self.listTapRecognizer;
    if (listView && listTap) [listView removeGestureRecognizer:listTap];
    [self removeOutline];
}

/// Used when the list view leaves the window — which happens whenever an
/// app opens, not just when gravity is actually being turned off — rather
/// than `restoreAndTearDown`. Gravity is still on at this point, so names
/// stay hidden: the app-launch zoom animates from the icon itself, and
/// restoring the label here made the name visibly flash back. The manager
/// keeps track of every label it hid and restores them all when gravity is
/// really switched off, even for pages that aren't attached at that moment.
- (void)silentTearDown {
    for (GIPhysicsState *state in self.icons) {
        UIView *view = state.view;
        if (view) view.transform = CGAffineTransformIdentity;
    }

    UIView *listView = self.listView;
    UITapGestureRecognizer *listTap = self.listTapRecognizer;
    if (listView && listTap) [listView removeGestureRecognizer:listTap];
    [self removeOutline];
}

/// Tapping an icon while it's displaced needs its own path: SpringBoard's
/// native tap-to-launch almost certainly hit-tests against each icon's
/// static grid position, not wherever it's currently displaced to, so a tap
/// where the icon visually sits wouldn't reach it. This recognizer lives on
/// the list view itself and does its own hit-test by hand against each
/// icon's current (offset) rect — bypassing the view hierarchy's own
/// hit-testing, and the SBIconListView-level interception that made a
/// recognizer on the individual icon view never fire at all. Once a tap is
/// matched to an icon, best-effort open the app directly, then settle that
/// one icon back home either way so a follow-up tap at its normal position
/// works through SpringBoard's own handling too.
- (void)gi_handleListTap:(UITapGestureRecognizer *)recognizer {
    UIView *listView = self.listView;
    if (!listView) return;

    // Same box as collisions: just the artwork while names are hidden (an
    // invisible label shouldn't be tappable), the whole cell when shown.
    // GIBoxContainsPoint respects rotation, so the tappable area actually
    // matches what's drawn on screen instead of an unrotated approximation.
    CGPoint point = [recognizer locationInView:listView];
    GIPhysicsState *tappedState = nil;
    for (GIPhysicsState *state in self.icons) {
        [state refreshGeometry];
        GIBox box = GIBoxMake([self hitFrameFor:state], state.geometry, state.offset, state.rotation);
        if (GIBoxContainsPoint(box, point)) {
            tappedState = state;
            break;
        }
    }
    if (!tappedState || !tappedState.view) return;
    UIView *tappedView = tappedState.view;

    @try {
        GITryOpenApp(tappedView);
    } @catch (NSException *exception) {
        NSLog(@"[GravityIcons] tap-to-open failed: %@", exception);
    }

    tappedState.velocity = CGPointZero;
    tappedState.angularVelocity = 0;
    tappedState.offset = CGPointZero;
    tappedState.rotation = 0;
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        tappedView.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)setLabelsHidden:(BOOL)hidden animated:(BOOL)animated {
    self.labelsHidden = hidden;
    NSArray<GIPhysicsState *> *icons = self.icons;
    if (hidden) {
        for (GIPhysicsState *state in icons) {
            [[GravityManager sharedManager] trackHiddenLabels:state.labelViews];
        }
    }
    void (^apply)(void) = ^{
        for (GIPhysicsState *state in icons) {
            for (UIView *label in state.labelViews) {
                label.alpha = hidden ? 0.0 : 1.0;
            }
        }
    };
    if (animated) {
        [UIView animateWithDuration:hidden ? 0.15 : 0.25 animations:apply];
    } else {
        apply();
    }
}

/// SpringBoard resets label alpha on its own — layout passes, badge
/// updates, launch/close animations — and sometimes swaps the label view
/// out for a new one entirely, so hiding it once doesn't stick. Called once
/// per physics tick: re-applies alpha 0 to the known labels every tick, and
/// re-scans for replacement label views about twice a second.
- (void)enforceLabelsHidden {
    if (!self.labelsHidden) return;
    BOOL rescan = (++self.ticksSinceLabelScan >= 30);
    if (rescan) self.ticksSinceLabelScan = 0;
    for (GIPhysicsState *state in self.icons) {
        UIView *view = state.view;
        if (!view) continue;
        if (rescan) {
            state.labelViews = GIFindLabelSubviews(view);
            [[GravityManager sharedManager] trackHiddenLabels:state.labelViews];
        }
        for (UIView *label in state.labelViews) {
            if (label.alpha != 0.0) label.alpha = 0.0;
        }
    }
}

@end

#pragma mark - GravityManager

@interface GravityManager ()
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) NSHashTable<UIView *> *registeredListViews;
@property (nonatomic, strong) NSMapTable<UIView *, GravitySession *> *sessions;
@property (nonatomic, assign) CGFloat strength;
@property (nonatomic, assign) CFTimeInterval lastTick;
// Every label hidden since gravity was switched on, across all pages —
// including pages detached since (an app opened, a page was recycled), so
// they can all be brought back when gravity is actually switched off.
@property (nonatomic, strong) NSHashTable<UIView *> *hiddenLabelViews;
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
        _hiddenLabelViews = [NSHashTable weakObjectsHashTable];
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

    BOOL wasUsingBorders = _useBorders;
    CFPropertyListRef bordersValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIBordersKey, (__bridge CFStringRef)kGIDomain);
    if (bordersValue) {
        _useBorders = [(__bridge id)bordersValue boolValue];
        CFRelease(bordersValue);
    } else {
        _useBorders = YES; // default on
    }

    // Turning the feature off in Settings also kills any physics that's
    // currently running from a prior shake.
    if (!_isEnabled && _isActive) {
        [self setActive:NO];
    }

    BOOL wasShowingOutline = _showOutline;
    CFPropertyListRef outlineValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kGIOutlineKey, (__bridge CFStringRef)kGIDomain);
    if (outlineValue) {
        _showOutline = [(__bridge id)outlineValue boolValue];
        CFRelease(outlineValue);
    } else {
        _showOutline = NO;
    }

    // Icons outside the new bounds get pushed back in by the next tick's
    // edge clamp, so this just needs the bounds themselves recomputed (which
    // also adds/removes the debug outline).
    if (_isActive && (wasUsingBorders != _useBorders || wasShowingOutline != _showOutline)) {
        for (GravitySession *session in [self allSessions]) {
            [session updateContentBounds];
        }
    }

    // Apply a live toggle of the label preference to whatever's already
    // running, instead of waiting for the next shake to pick it up.
    if (_isActive && wasHidingLabels != _hideLabels) {
        for (GravitySession *session in [self allSessions]) {
            [session setLabelsHidden:_hideLabels animated:YES];
        }
        if (!_hideLabels) [self restoreHiddenLabels];
    }
}

/// Top edge of the dock in `view`'s coordinates. The dock's icon row is an
/// SBIconListView-family view registered through the same -layoutIconsNow
/// hook as every page, so it's found among the registered views rather than
/// by searching the whole window (that earlier attempt latched onto
/// unrelated views with "dock" in their name). From that row, walk up to the
/// outermost dock-named ancestor that's still dock-sized — the platter
/// behind the icons, which sits a little above the icons themselves.
- (CGFloat)dockTopInView:(UIView *)view {
    UIWindow *window = view.window;
    if (!window) return CGFLOAT_MAX;

    for (UIView *candidate in self.registeredListViews.allObjects) {
        if (candidate == view || candidate.window != window) continue;
        if (!GIIsDockClass(candidate)) continue;

        UIView *platter = candidate;
        CGFloat maxHeight = CGRectGetHeight(window.bounds) * 0.35;
        for (UIView *ancestor = candidate.superview; ancestor && ancestor != window; ancestor = ancestor.superview) {
            if (GIIsDockClass(ancestor) &&
                CGRectGetHeight(ancestor.bounds) <= maxHeight) {
                platter = ancestor;
            }
        }
        return CGRectGetMinY([platter convertRect:platter.bounds toView:view]);
    }
    return CGFLOAT_MAX;
}

- (void)trackHiddenLabels:(NSArray<UIView *> *)labels {
    for (UIView *label in labels) {
        [self.hiddenLabelViews addObject:label];
    }
}

- (void)restoreHiddenLabels {
    for (UIView *label in self.hiddenLabelViews.allObjects) {
        label.alpha = 1.0;
    }
    [self.hiddenLabelViews removeAllObjects];
}

- (void)toggleActive {
    if (!self.isEnabled) return;
    [self setActive:!self.isActive];
}

- (void)setActive:(BOOL)active {
    if (_isActive == active) return;
    _isActive = active;

    if (active) {
        self.isActivating = YES;
        for (UIView *listView in self.registeredListViews.allObjects) {
            [self attachToListView:listView];
        }
        self.isActivating = NO;
        [self startMotionUpdates];
    } else {
        [self.motionManager stopDeviceMotionUpdates];
        for (UIView *listView in [self.sessions.keyEnumerator allObjects]) {
            [self detachFromListView:listView];
        }
        [self restoreHiddenLabels];
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

    // The list view leaving the window (an app opening, a page being
    // recycled) isn't the user turning gravity off, so this uses the
    // silent teardown, not the animated/label-restoring one — that one is
    // reserved for setActive:NO, the actual deliberate deactivation path.
    GravitySession *session = [self.sessions objectForKey:listView];
    if (!session) return;
    [session silentTearDown];
    [self.sessions removeObjectForKey:listView];
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
