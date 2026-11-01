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
├── main.swift       # entire app: multitouch bindings, gestures, Touch Bar, media keys, menu, Trackpad View
├── build.sh         # compiles with swiftc, writes Info.plist, ad-hoc signs Rimshot.app
├── docs/hero.svg    # README hero image
├── docs/zones.svg   # README edge-slider diagram
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
- On touch-down it assigns a zone: `top` (when Top Edge is on), `bottom` (when Media Strip is on) or `none`. Each zone is `EDGE_WIDTH` deep and spans the full width.
- With Touch Bar off, the top edge is a keyboard light slider: every `TOP_STEP` of horizontal travel emits one key event and one haptic tick, and moving down more than `2 × EDGE_WIDTH` before the first step drops the gesture. The cursor freezes on the first step.
- On lift in the bottom zone, a horizontal travel of at least `SWIPE_MIN` counts as a skip. A short, still touch counts as a tap.
- Every AppKit call is dispatched to the main thread.

### 4. Touch Bar (top edge)

- A touch that starts on the top edge shows the bar only after `BAR_DWELL` of resting. Drifting down more than `2 × EDGE_WIDTH` before that drops the gesture as a cursor move.
- Once the bar is up, the finger's x position across the **full trackpad width** picks a button (`BAR_ITEMS`, or `FN_ITEMS` while Fn/Globe is held). Each new button gets a haptic tick, and the cursor is frozen.
- Lift fires the highlighted button. A physical click while the bar is up fires it immediately. Sliding below `1 − BAR_CANCEL_DEPTH` cancels.
- Holding still (within `BAR_HOLD_MOVE`) charges the button. Haptics fire at the `BAR_CHARGE_TICKS` fractions of `BAR_HOLD`, getting closer together and moving from `.alignment` to `.generic` to `.levelChange`. While charging, the highlighted button shows a glow that grows from its center to its edges. A full charge plays a double `.levelChange` and fires the button, or turns a slider button into a slider driven by `TOP_STEP` of horizontal travel.
- The overlay is a borderless, non-activating `NSPanel` (`TouchBarHUD`) that ignores the mouse. It's updated from `Gestures` only when its `BarState` changes.
- Buttons are `BarItem`s with a `BarAction`: a virtual key code, a media key, an app to open, or a slider. Mission Control and Screenshot open their apps in `/System/Applications`.

### 5. Click swallowing

A session-level `CGEventTap` on left mouse down, drag and up asks `Gestures.shouldSwallow`. It drops clicks while the bar is up and for `CLICK_GRACE` after the bar closes (to catch tap-to-click). A real click on the top edge before the bar appears passes through and cancels the gesture. Mouse-up is only swallowed when the matching mouse-down was. Creating the tap needs Accessibility permission, so it's retried each time the menu opens until it succeeds.

### 6. Other APIs

- Haptics use `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, ...)`.
- Cursor freeze uses `CGAssociateMouseAndMouseCursorPosition(0/1)`. The position is saved on touch-down and restored with `CGWarpMouseCursorPosition` on the first step.
- Settings are stored in `UserDefaults`, with keys `haptics`, `mediaStrip`, `tapToPlay`, `topEdge` and `touchBar`.
- Login items use `SMAppService.mainApp.register()` and `unregister()`.

### Tuning constants (top of `main.swift`)

| Constant | Default | Meaning |
|---|---|---|
| `EDGE_WIDTH` | 0.06 | Depth of the top and bottom edge zones |
| `TOP_STEP` | 0.022 | Horizontal travel per slider step on the top edge |
| `SWIPE_MIN` | 0.15 | Horizontal travel needed to skip a track |
| `TAP_MAX_TIME` | 0.25 s | Longest touch that still counts as a tap |
| `TAP_MAX_MOVE` | 0.02 | Farthest a finger can move and still count as a tap |
| `BAR_DWELL` | 0.15 s | Rest time on the top edge before the Touch Bar appears |
| `BAR_HOLD` | 0.70 s | Hold time to fire a button or start a slider |
| `BAR_CHARGE_TICKS` | 0.25 … 0.97 | Fractions of `BAR_HOLD` where charge-up haptics fire |
| `BAR_HOLD_MOVE` | 0.015 | Farthest a finger can drift and still count as holding |
| `BAR_CANCEL_DEPTH` | 0.30 | How far down from the top cancels the Touch Bar |
| `CLICK_GRACE` | 0.35 s | How long after a lift a tap-to-click still gets swallowed |

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
5. False triggers. Moving the cursor or clicking near the top edge shouldn't open the bar. Tune `EDGE_WIDTH` and `BAR_DWELL`.
6. External Magic Trackpad. `MTDeviceCreateList` returns every multitouch device. Check whether the zones make sense on an external trackpad, or limit the app to the built-in one.

---

## Manual test checklist

- [ ] The app launches with no Dock icon and the menu bar icon appears
- [ ] The Accessibility prompt shows on first launch
- [ ] Resting on the top edge shows the Touch Bar; a quick touch doesn't
- [ ] Sliding moves the highlight with a tick per button; lifting presses it
- [ ] Holding a button charges with quickening haptics and a center-out glow, then fires it
- [ ] Shift+Option while dragging a bar slider gives quarter steps
- [ ] Holding Brightness, Keyboard Light or Volume turns it into a working slider
- [ ] Holding Fn/Globe shows esc and F1–F12, and they send the right keys
- [ ] Sliding down cancels without pressing anything
- [ ] Taps and presses on the bar never click whatever is under the cursor
- [ ] With Touch Bar off, sliding along the top edge changes the keyboard backlight
- [ ] A bottom-edge swipe right or left skips to the next or previous track (test with Spotify or Music)
- [ ] Bottom-edge swipes do nothing while Media Strip is off
- [ ] Tap to Play works only when its toggle is on
- [ ] The cursor doesn't move while the bar is up
- [ ] Settings survive a relaunch
- [ ] Open at Login survives a reboot
- [ ] Two-finger scrolling and normal clicking near the edges are unaffected
- [ ] CPU usage is about 0% when idle (check Activity Monitor)

---

## Roadmap

- [ ] Custom Touch Bar buttons, including running a Shortcut
- [ ] Per-app Touch Bar button sets
- [ ] A settings window (SwiftUI) with sliders for the tuning constants
- [ ] Live brightness and volume levels shown in the menu
- [ ] A Light/Dark menu bar icon and a proper app icon (`.icns` generated with `iconutil`, no Xcode)
- [ ] A haptic strength setting
- [ ] A first-run setup guide
- [ ] Splitting `main.swift` into files (`Multitouch.swift`, `Gestures.swift`, `MediaKeys.swift`, `AppDelegate.swift`) and updating `build.sh` to compile them all
- [ ] A GitHub release with a zipped `.app` and install instructions
- [ ] A Homebrew tap
