<p align="center">
  <img src="docs/zones.svg" alt="Rimshot trackpad zones: brightness on the left edge, volume on the right, keyboard light along the top, mute in the top-right corner" width="760">
</p>

<h1 align="center">Rimshot</h1>

<p align="center">
  <strong>Your MacBook trackpad has edges you never use. Rimshot turns them into sliders.</strong>
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white">
  <img alt="Size" src="https://img.shields.io/badge/size-416%20KB-success">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

Slide a finger up the right edge and the volume goes up. Slide the left edge for brightness and the top edge for the keyboard backlight. Double-tap the top-right corner to mute. macOS shows its usual on-screen display, you feel a light haptic tick on every step, and the cursor stays put while you slide.

No more hunting for the brightness keys, and no Touch Bar required. It's free, open source, and a no-cost alternative to paid edge-gesture apps like EdgeBar.

## What you can do

| Where | Gesture | What happens |
|---|---|---|
| **Left edge** | Slide up or down | Display brightness |
| **Right edge** | Slide up or down | Volume |
| **Top edge** | Slide left or right | Keyboard backlight |
| **Top-right corner** | Double-tap | Mute / unmute |
| **Bottom edge** *(optional)* | Swipe left or right | Previous / next track |
| **Bottom edge** *(optional)* | Tap | Play / pause |
| **Any slider** | Hold <kbd>⇧</kbd> <kbd>⌥</kbd> while sliding | Quarter steps for fine control |

## Why Rimshot

- **Feels built in.** It uses the same volume and brightness overlay as your keyboard keys, a haptic tick on every step, and a cursor that doesn't drift while you slide.
- **Stays out of your way.** Only single-finger slides that start on an edge count. Two-finger scrolling, clicking and every other gesture work exactly as before. If your finger heads inward, Rimshot treats it as a normal cursor move and backs off.
- **Tiny and native.** It's written in Swift with AppKit, and the whole app is 416 KB. It uses about 30 MB of memory and **0% CPU** when idle, because it wakes up only when you touch the trackpad. No Electron and no background polling.
- **Yours to read.** Rimshot needs Accessibility permission, so you should be able to see what it does: the whole app is about 950 lines of Swift in a single file.

## Install

You'll need macOS 13 Ventura or later and a MacBook. Building takes about 30 seconds and needs only Apple's free Command Line Tools, not Xcode.

```bash
xcode-select --install          # skip if you already have the Command Line Tools
git clone https://github.com/manankapoor23/rimshot.git
cd rimshot && ./build.sh
mv Rimshot.app /Applications/ && open /Applications/Rimshot.app
```

Because you build it yourself, macOS won't show "unidentified developer" warnings.

### First launch

Rimshot asks for **Accessibility** permission the first time it runs. It needs this to send volume and brightness key presses to macOS, the same way your keyboard does. Turn it on under **System Settings → Privacy & Security → Accessibility**, then relaunch Rimshot.

A slider icon appears in your menu bar. There's no Dock icon.

## Settings

Everything lives in the menu bar menu:

- **Swap Sides**: brightness on the right, volume on the left.
- **Bottom Quarter Only**: side slides only start from the lower 25% of the edges, for people who rest a finger near the edges.
- **Haptic Feedback**: the tick on each step.
- **Keyboard Light (top edge)**: on by default.
- **Media Strip** and **Tap to Play**: track controls on the bottom edge, off by default.
- **Open at Login**.

## See what Rimshot sees

Choose **Show Trackpad View** from the menu to open a live, to-scale map of your trackpad. It shows every zone, your fingers as you touch, where each step will fire, and a log of every action. It's handy for learning the zones, and for reporting bugs.

## Good to know

- Rimshot reads raw touch data through a private Apple framework, `MultitouchSupport`. That's the only way to see where fingers are, but it means a future macOS update could break it. If that happens, please [open an issue](https://github.com/manankapoor23/rimshot/issues).
- Brightness and keyboard light work by simulating the hardware keys. That may not work on every Mac model or with external displays.
- If **tap to click** is on, the double-tap in the mute corner also counts as a double-click wherever your cursor is.
- If you rebuild the app, macOS may stop trusting it. Remove Rimshot from the Accessibility list, add it back, and relaunch.

## Contributing

Bug reports, ideas and pull requests are welcome. [DEVELOPMENT.md](DEVELOPMENT.md) covers how Rimshot works under the hood, the tuning constants, the build constraints and the manual test checklist.

## License

[MIT](LICENSE). Free to use, change and share.
