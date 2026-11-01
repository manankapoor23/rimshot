# Developing Rimshot

Everything you need to change, build and test Rimshot. For what the app does, see the [README](README.md).

## Hard constraints

- No Xcode. Rimshot builds with only the Xcode Command Line Tools (`xcode-select --install`). Everything has to build with `swiftc` from the terminal through `build.sh`. Don't add `.xcodeproj`, storyboards, asset catalogs or anything else that needs Xcode.
- Target macOS 13 Ventura or later (needed for `SMAppService`).
- Build a single-binary menu bar app in Swift with AppKit. SwiftUI is fine for a settings window later, but the app has to launch through `NSApplication` with `.accessory` activation policy (no Dock icon).
- The app is not sandboxed and not meant for the App Store. It uses a private framework.
- Sign it ad hoc with `codesign --sign -`.
- Keep CPU usage near zero: no polling loops and no timers while idle.

## Files

```
rimshot/
├── main.swift       # entire app: multitouch bindings, gestures, media keys, menu, Trackpad View
├── build.sh         # compiles with swiftc, writes Info.plist, ad-hoc signs Rimshot.app
├── docs/zones.svg   # README diagram
├── README.md        # user-facing page
└── DEVELOPMENT.md   # this file
```

There's no Xcode debugger in this workflow. Use `NSLog` for diagnostics and read the output with `log stream --predicate 'process == "Rimshot"'`, or by running `Rimshot.app/Contents/MacOS/Rimshot` directly from the terminal. Set `RIMSHOT_DEBUG=1` to log every touch-down zone, step, swipe and tap.

---

## How it works

### 1. Raw trackpad input: MultitouchSupport (private)

Public `NSEvent` gestures don't expose finger positions, so the app reads raw touches from `/System/Library/PrivateFrameworks/MultitouchSupport.framework`.

- Load it at runtime with `dlopen` and `dlsym`. Don't link against it, because the framework sits in the dyld shared cache and has no `.tbd` in the SDK.
- The symbols it uses are `MTDeviceCreateList`, `MTRegisterContactFrameCallback` and `MTDeviceStart`.
- The callback runs about 100 times a second on a background thread. It delivers an array of `MTTouch` structs, each 96 bytes. Their layout is defined in `main.swift` and has to match the C layout exactly.
- `normalized.pos` gives x from 0 (left) to 1 (right) and y from 0 (bottom) to 1 (top).
- Touch `state` values 4 and 5 mean the finger is in contact.
- Keep the device list alive in a global, or the callbacks stop.

### 2. Volume, brightness and keyboard light: synthetic media key events

The app posts `NSEvent.otherEvent(with: .systemDefined, subtype: 8, ...)` events and sends them through `cgEvent.post(tap: .cghidEventTap)`. macOS handles them exactly like the physical keys, so the native on-screen display appears.

These are the key codes from IOKit's `NX_KEYTYPE_*`:

| Key | Code |
|---|---|
| Sound up / down | 0 / 1 |
| Brightness up / down | 2 / 3 |
| Mute | 7 |
| Keyboard backlight up / down | 21 / 22 |
| Play | 16 |
| Next / Previous | 17 / 18 |

The event fields are `data1 = (key << 16) | (state << 8)`, with state `0xA` for key down and `0xB` for key up. For fine control, the Shift and Option modifier flags are added to the event.

Posting these events requires Accessibility permission (`AXIsProcessTrustedWithOptions` with the prompt option).

### 3. Gesture state machine (`Gestures` class)

- The app tracks exactly one finger. Two or more fingers cancel the gesture, so normal scrolling and other gestures are never hijacked.
- On touch-down it assigns a zone: `corner` (top-right), `left`, `right`, `top` (when Keyboard Light is on), `bottom` (when Media Strip is on) or `none`.
- A vertical slide that starts in the corner behaves like the right edge, so the top of the right slider still works.
- If a side-edge finger moves more than `2 × EDGE_WIDTH` sideways before the first step, the gesture is dropped as an ordinary cursor move.
- In the left and right zones, every `STEP` of vertical travel emits one key event and one haptic tick. On the top edge, every `TOP_STEP` of horizontal travel does the same, and moving down more than `2 × EDGE_WIDTH` before the first step drops the gesture. The cursor freezes on the first step.
- On lift in the bottom zone, a horizontal travel of at least `SWIPE_MIN` counts as a skip. A short, still touch counts as a tap.
- On lift in the corner zone, two quick taps within `DOUBLE_TAP_GAP` trigger mute.
- Every AppKit call is dispatched to the main thread.

### 4. Other APIs

- Haptics use `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, ...)`.
- Cursor freeze uses `CGAssociateMouseAndMouseCursorPosition(0/1)`. The position is saved on touch-down and restored with `CGWarpMouseCursorPosition` on the first step.
- Settings are stored in `UserDefaults`, with keys `swapSides`, `bottomQuarter`, `haptics`, `mediaStrip`, `tapToPlay` and `topEdge`.
- Login items use `SMAppService.mainApp.register()` and `unregister()`.

### Tuning constants (top of `main.swift`)

| Constant | Default | Meaning |
|---|---|---|
| `EDGE_WIDTH` | 0.06 | Width of each edge zone |
| `CORNER_SIZE` | 0.12 | Size of the mute corner |
| `STEP` | 0.035 | Vertical travel per step |
| `TOP_STEP` | 0.022 | Horizontal travel per step on the top edge |
| `SWIPE_MIN` | 0.15 | Horizontal travel needed to skip a track |
| `TAP_MAX_TIME` | 0.25 s | Longest touch that still counts as a tap |
| `DOUBLE_TAP_GAP` | 0.40 s | Longest gap between taps for a double-tap |
| `TAP_MAX_MOVE` | 0.02 | Farthest a finger can move and still count as a tap |
| `BOTTOM_QUARTER` | 0.25 | Height of the active band for Bottom Quarter Only |

---

## Build and run

```bash
xcode-select -p || xcode-select --install   # make sure the Command Line Tools exist
./build.sh
mv Rimshot.app /Applications/
open /Applications/Rimshot.app
```

Then turn on Rimshot under System Settings → Privacy & Security → Accessibility, and relaunch the app.

Every rebuild changes the ad-hoc signature, so macOS may silently stop trusting the app. If it stops responding after a rebuild, remove it from the Accessibility list, add it back and relaunch.

---

## Known risks and things to verify

1. `MTTouch` struct layout. If touch positions look like garbage, the struct layout or stride is wrong. Log `MemoryLayout<MTTouch>.stride`, which should be 96.
2. Brightness keys. Synthetic brightness events may not work on every Mac or with external displays. The fallback is the private `DisplayServices.framework` (`DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`, loaded with `dlopen`), plus drawing a custom on-screen display.
3. Haptics in a background app. `NSHapticFeedbackManager` may not fire while the app isn't frontmost. Check it, and if it doesn't fire, look into the private `MTActuator` APIs in MultitouchSupport.
4. Cursor freeze. `CGAssociateMouseAndMouseCursorPosition` may behave inconsistently for an accessory app. The fallback is to save the cursor position on the first step and call `CGWarpMouseCursorPosition` on each frame.
5. False triggers. Clicking or moving the cursor near the edges shouldn't change volume. Tune `EDGE_WIDTH` and `STEP`, and think about requiring a minimum slide distance before the first step fires.
6. External Magic Trackpad. `MTDeviceCreateList` returns every multitouch device. Check whether the zones make sense on an external trackpad, or limit the app to the built-in one.

---

## Manual test checklist

- [ ] The app launches with no Dock icon and the menu bar icon appears
- [ ] The Accessibility prompt shows on first launch
- [ ] Sliding the left edge up and down changes brightness and shows the native display
- [ ] Sliding the right edge up and down changes volume and shows the native display
- [ ] Shift+Option while sliding gives quarter steps
- [ ] Sliding along the top edge changes the keyboard backlight and shows the native display
- [ ] Double-tapping the top-right corner toggles mute
- [ ] A bottom-edge swipe right or left skips to the next or previous track (test with Spotify or Music)
- [ ] Bottom-edge swipes do nothing while Media Strip is off
- [ ] Tap to Play works only when its toggle is on
- [ ] A haptic tick fires on each step
- [ ] The cursor doesn't move while sliding
- [ ] Swap Sides and Bottom Quarter Only work and survive a relaunch
- [ ] Open at Login survives a reboot
- [ ] Two-finger scrolling and normal clicking near the edges are unaffected
- [ ] CPU usage is about 0% when idle (check Activity Monitor)

---

## Roadmap

- [ ] A settings window (SwiftUI) with sliders for the tuning constants
- [ ] An optional modifier key that must be held for edge sliding to work
- [ ] Live brightness and volume levels shown in the menu
- [ ] A Light/Dark menu bar icon and a proper app icon (`.icns` generated with `iconutil`, no Xcode)
- [ ] A haptic strength setting
- [ ] A first-run setup guide
- [ ] Splitting `main.swift` into files (`Multitouch.swift`, `Gestures.swift`, `MediaKeys.swift`, `AppDelegate.swift`) and updating `build.sh` to compile them all
- [ ] A GitHub release with a zipped `.app` and install instructions
- [ ] A Homebrew tap
