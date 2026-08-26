# Gravity Icons

A rootless iOS 15 tweak that gives your home screen icons real physics.
Enable it in **Settings → Gravity Icons**, then **shake your device** to send
icons falling based on how you tilt it — shake again to settle them back.

## How it works

- `GravityManager` never runs physics automatically on boot/respring — it
  only ever activates from an explicit device shake, hooked in `Tweak.xm` via
  `SBHomeScreenWindow -motionEnded:withEvent:` for `UIEventSubtypeMotionShake`
  (a public `UIResponder` method, so this hook is safe regardless of
  SpringBoard's private internals). An earlier version of this tweak tried to
  attach physics automatically as soon as a page's icons mounted, which
  fought SpringBoard's own icon-layout system badly enough to hang SpringBoard
  on boot — gating everything behind a deliberate, well-after-boot user
  gesture is what fixed that.
- `Tweak.xm` hooks `SBIconListView -layoutIconsNow` (a long-stable,
  widely-used private method) purely to register that a page exists.
  Registration is cheap — no physics work happens there.
- Icon views on a page are found by filtering `listView.subviews` for
  `description` containing `"SBIcon"`, not by calling a private
  selector like `-viewForIcon:`. `.subviews`/`.description` are guaranteed
  Foundation/UIKit calls, so this can't throw an unrecognized-selector
  exception the way a guessed private method name could.
- When active, `GravityManager` integrates a small hand-rolled physics step
  per icon (gravity + edge bounce + friction) on every `CMMotionManager`
  device-motion tick (~60 Hz), and applies it purely via `view.transform` — a
  compositing-only offset. It never touches `.frame`/`.center`, which are the
  properties SpringBoard's own layout system owns, so there's nothing left to
  fight with.
- Shaking again (or disabling the Settings toggle) springs every icon's
  transform back to `CGAffineTransformIdentity` and stops the motion feed.
- The Settings toggle is a plain `Root.plist` under
  `/Library/PreferenceBundles/GravityIconsPrefs.bundle`, loaded by
  PreferenceLoader — no compiled preferences code needed. It gates whether a
  shake is allowed to do anything at all; flipping it off mid-session also
  force-stops any physics that's currently running. Changes apply live via a
  Darwin notification (`com.qcomtoolbox.gravityicons/ReloadPrefs`), no
  respring needed.

Design directly informed by
[kritanta-ios-tweaks/Gravitation](https://github.com/kritanta-ios-tweaks/Gravitation),
a real, published tweak that solves the same problem — its shake-to-activate
gating and subview-filtering icon lookup are the two things that made this
version stable where the first attempt wasn't.

## Build requirements

- A Mac (or Linux/Docker) with [Theos](https://theos.dev) installed and
  `$THEOS` set.
- The iOS 15 SDK in `$THEOS/sdks` (grab one from
  [theos/sdks](https://github.com/theos/sdks) if you don't have it).
- A rootless jailbreak toolchain target (Dopamine, XinaA15, palera1n
  rootless, Serotonin, etc.) — this project already sets
  `THEOS_PACKAGE_SCHEME = rootless` in the `Makefile`.
- `ldid` for local signing if you're not building on-device.

## Build & install

```bash
cd GravityIcons
make package
```

To build and install directly onto a device over SSH/USB (adjust
`THEOS_DEVICE_IP`, or run this straight from an on-device Theos setup):

```bash
make do
```

`make do` builds, packages, installs, and (per the `after-install::` rule in
the `Makefile`) runs `sbreload` so SpringBoard restarts and the toggle shows
up in Settings.

If `dpkg` complains about a missing `mobilesubstrate` dependency, install
through Sileo/Filza instead of raw `dpkg -i` — `make do` uses `dpkg -i`
directly, which doesn't resolve virtual-package dependencies the way
apt-based installs do.

## Notes / things to double-check on your exact iOS 15.x build

Jailbreak tweaks rely on SpringBoard's private class layout, which can shift
between point releases. `-layoutIconsNow` and `SBHomeScreenWindow` are both
long-stable, widely relied-upon by other published tweaks — but if physics
still doesn't kick in on your specific build:

- Confirm `-layoutIconsNow` still exists on `SBIconListView` for your exact
  iOS 15.x by pulling class-dump headers for SpringBoard from your device.
- Confirm shakes are actually reaching `SBHomeScreenWindow` and not being
  intercepted by something else first (e.g. another tweak with an activator
  binding on shake).

## Uninstalling

Remove the package from Sileo/Zebra like any other tweak, then respring.
Because physics only ever runs after a shake and only ever touches
`view.transform` (never `.frame`/`.center`, never written back to
SpringBoard's on-disk icon state), there's no risk of icons being left in a
bad position even if you remove the tweak mid-session.
