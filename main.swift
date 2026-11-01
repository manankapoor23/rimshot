// Rimshot: trackpad edges as volume and brightness sliders.
// Entire app: multitouch bindings, gestures, media keys, menu.

import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - Tuning constants (normalized trackpad units, 0...1)

let EDGE_WIDTH: Float = 0.06        // width of each edge zone
let CORNER_SIZE: Float = 0.12       // size of the mute corner
let STEP: Float = 0.035             // vertical travel per step
let TOP_STEP: Float = 0.022         // horizontal travel per step on the top edge (≈ same distance as STEP)
let SWIPE_MIN: Float = 0.15         // horizontal travel needed to skip a track
let TAP_MAX_TIME: Double = 0.25     // longest touch that still counts as a tap
let DOUBLE_TAP_GAP: Double = 0.40   // longest gap between taps for a double-tap
let TAP_MAX_MOVE: Float = 0.02      // farthest a finger can wander and still count as a tap
let BOTTOM_QUARTER: Float = 0.25    // height of the active band when Bottom Quarter Only is on
let BAR_DWELL: Double = 0.15        // how long a finger rests on the top edge before the Touch Bar appears
let BAR_HOLD: Double = 0.70         // hold a button this long to fire it (or start adjusting a slider)
// Points in the hold (fractions of BAR_HOLD) where a charge-up haptic fires; they get closer together.
let BAR_CHARGE_TICKS: [Double] = [0.25, 0.45, 0.60, 0.71, 0.80, 0.87, 0.93, 0.97]
let BAR_HOLD_MOVE: Float = 0.015    // farthest a finger can drift and still count as holding
let BAR_CANCEL_DEPTH: Float = 0.30  // slide this far down from the top to cancel the Touch Bar
let CLICK_GRACE: Double = 0.35      // how long after a lift a tap-to-click still gets swallowed

let DEBUG = ProcessInfo.processInfo.environment["RIMSHOT_DEBUG"] != nil

// MARK: - MultitouchSupport (private, loaded with dlopen)

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var pos: MTPoint; var vel: MTPoint }

// Must match the C layout exactly: 96 bytes per touch.
struct MTTouch {
    var frame: Int32            // 0
    var timestamp: Double       // 8
    var identifier: Int32       // 16
    var state: Int32            // 20  (4 = make touch, 5 = touching)
    var fingerID: Int32         // 24
    var handID: Int32           // 28
    var normalized: MTReadout   // 32  x: 0 left → 1 right, y: 0 bottom → 1 top
    var size: Float             // 48
    var zero1: Int32            // 52
    var angle: Float            // 56
    var majorAxis: Float        // 60
    var minorAxis: Float        // 64
    var mm: MTReadout           // 68
    var zero2: (Int32, Int32)   // 84
    var unknown: Float          // 92
}

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias MTDeviceCreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
typealias MTDeviceGetSensorSurfaceDimensionsFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

// The device list has to stay alive, or the callbacks stop.
var mtDevices: CFArray?
// Physical size of the first trackpad in hundredths of a millimetre (0 if unknown).
var trackpadSize = (width: Int32(0), height: Int32(0))

let contactCallback: MTContactCallback = { device, touches, count, _, _ in
    gestures.handle(device: device, touches: touches, count: Int(count))
    return 0
}

func startMultitouch() -> Int {
    let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    guard let handle = dlopen(path, RTLD_NOW),
          let pCreateList = dlsym(handle, "MTDeviceCreateList"),
          let pRegister = dlsym(handle, "MTRegisterContactFrameCallback"),
          let pStart = dlsym(handle, "MTDeviceStart") else {
        NSLog("Rimshot: failed to load MultitouchSupport: %@", String(cString: dlerror()))
        return 0
    }
    let createList = unsafeBitCast(pCreateList, to: MTDeviceCreateListFn.self)
    let register = unsafeBitCast(pRegister, to: MTRegisterContactFrameCallbackFn.self)
    let start = unsafeBitCast(pStart, to: MTDeviceStartFn.self)
    let dimensions = dlsym(handle, "MTDeviceGetSensorSurfaceDimensions")
        .map { unsafeBitCast($0, to: MTDeviceGetSensorSurfaceDimensionsFn.self) }

    guard let raw = createList() else { return 0 }
    let list = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
    mtDevices = list
    let count = CFArrayGetCount(list)
    for i in 0..<count {
        guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
        let ref = UnsafeMutableRawPointer(mutating: device)
        register(ref, contactCallback)
        _ = start(ref, 0)
        if let dimensions, trackpadSize.width == 0 {
            var w: Int32 = 0, h: Int32 = 0
            _ = dimensions(ref, &w, &h)
            trackpadSize = (w, h)
            NSLog("Rimshot: trackpad surface %.1f × %.1f mm", Double(w) / 100, Double(h) / 100)
        }
    }
    NSLog("Rimshot: listening to %d multitouch device(s)", count)
    return count
}

// MARK: - Media keys (synthetic NX_KEYTYPE_* events)

let KEY_SOUND_UP: Int32 = 0
let KEY_SOUND_DOWN: Int32 = 1
let KEY_BRIGHTNESS_UP: Int32 = 2
let KEY_BRIGHTNESS_DOWN: Int32 = 3
let KEY_MUTE: Int32 = 7
let KEY_PLAY: Int32 = 16
let KEY_NEXT: Int32 = 17
let KEY_PREVIOUS: Int32 = 18
let KEY_ILLUMINATION_UP: Int32 = 21
let KEY_ILLUMINATION_DOWN: Int32 = 22

enum MediaKeys {
    static func press(_ key: Int32, fine: Bool = false) {
        let mods: NSEvent.ModifierFlags = fine ? [.shift, .option] : []
        post(key, down: true, mods)
        post(key, down: false, mods)
    }

    private static func post(_ key: Int32, down: Bool, _ mods: NSEvent.ModifierFlags) {
        let state = down ? 0xA : 0xB
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8)).union(mods)
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: (Int(key) << 16) | (state << 8), data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

// MARK: - Haptics and cursor (main thread only)

enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // One tick of a hold charging up: lighter patterns early, firmer ones near the end.
    static func charge(_ step: Int, of total: Int) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern =
            step * 3 <= total ? .alignment : (step * 3 <= total * 2 ? .generic : .levelChange)
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // The hold is complete: a firm double bump.
    static func thump() {
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            performer.perform(.levelChange, performanceTime: .now)
        }
    }
}

enum Cursor {
    private static var saved: CGPoint?
    private(set) static var frozen = false

    // Called on touch-down, so the pointer can snap back to where the slide started.
    static func remember() {
        saved = CGEvent(source: nil)?.location
    }

    static func freeze() {
        guard !frozen else { return }
        if let saved { CGWarpMouseCursorPosition(saved) }
        CGAssociateMouseAndMouseCursorPosition(0)
        frozen = true
    }

    static func release() {
        guard frozen else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        frozen = false
    }
}

// MARK: - Settings

struct Settings {
    var swapSides: Bool
    var bottomQuarter: Bool
    var haptics: Bool
    var mediaStrip: Bool
    var tapToPlay: Bool
    var topEdge: Bool
    var touchBar: Bool

    static let defaults: [String: Any] = [
        "swapSides": false, "bottomQuarter": false, "haptics": true,
        "mediaStrip": false, "tapToPlay": false, "topEdge": true, "touchBar": true,
    ]

    static func load() -> Settings {
        let d = UserDefaults.standard
        return Settings(
            swapSides: d.bool(forKey: "swapSides"),
            bottomQuarter: d.bool(forKey: "bottomQuarter"),
            haptics: d.bool(forKey: "haptics"),
            mediaStrip: d.bool(forKey: "mediaStrip"),
            tapToPlay: d.bool(forKey: "tapToPlay"),
            topEdge: d.bool(forKey: "topEdge"),
            touchBar: d.bool(forKey: "touchBar"))
    }
}

// MARK: - Touch Bar buttons

enum BarAction {
    case key(CGKeyCode, CGEventFlags)
    case media(Int32)
    case open(String)
    case slider(up: Int32, down: Int32)
}

struct BarItem {
    let title: String
    let short: String
    let symbol: String?
    let action: BarAction

    var isSlider: Bool {
        if case .slider = action { return true }
        return false
    }
}

let BAR_ITEMS: [BarItem] = [
    BarItem(title: "esc", short: "esc", symbol: nil, action: .key(53, [])),
    BarItem(title: "Brightness", short: "Bright", symbol: "sun.max.fill",
            action: .slider(up: KEY_BRIGHTNESS_UP, down: KEY_BRIGHTNESS_DOWN)),
    BarItem(title: "Keyboard Light", short: "Kbd", symbol: "light.max",
            action: .slider(up: KEY_ILLUMINATION_UP, down: KEY_ILLUMINATION_DOWN)),
    BarItem(title: "Mission Control", short: "Mission", symbol: "rectangle.3.group",
            action: .open("/System/Applications/Mission Control.app")),
    BarItem(title: "Screenshot", short: "Shot", symbol: "camera.viewfinder",
            action: .open("/System/Applications/Utilities/Screenshot.app")),
    BarItem(title: "Play / Pause", short: "Play", symbol: "playpause.fill", action: .media(KEY_PLAY)),
    BarItem(title: "Volume", short: "Vol", symbol: "speaker.wave.2.fill",
            action: .slider(up: KEY_SOUND_UP, down: KEY_SOUND_DOWN)),
    BarItem(title: "Mute", short: "Mute", symbol: "speaker.slash.fill", action: .media(KEY_MUTE)),
]

// esc and F1–F12 while Fn (Globe) is held, like the Touch Bar.
let FN_KEY_CODES: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
let FN_ITEMS: [BarItem] = [BarItem(title: "esc", short: "esc", symbol: nil, action: .key(53, []))]
    + FN_KEY_CODES.enumerated().map { i, code in
        BarItem(title: "F\(i + 1)", short: "F\(i + 1)", symbol: nil, action: .key(code, .maskSecondaryFn))
    }

enum Keys {
    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

// Main thread only.
func perform(_ item: BarItem) {
    switch item.action {
    case let .key(key, flags): Keys.press(key, flags: flags)
    case let .media(key): MediaKeys.press(key)
    case let .open(path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
    case .slider: break
    }
}

// What the on-screen bar should show.
struct BarState: Equatable {
    var visible = false
    var fn = false
    var index = -1
    var slider = false
    var cancelling = false
    var steps = 0
    var charge = 0          // 0...10, how far a hold has charged
    var pressed = false     // the button already fired during this touch
}

// MARK: - Gesture state machine

// Runs on the multitouch callback thread. Tracks exactly one finger; a second
// finger cancels the gesture until every finger lifts.
final class Gestures {
    enum Zone { case none, corner, left, right, top, bottom }
    private enum Phase { case idle, ignoring, tracking }

    private let lock = NSLock()
    private var phase = Phase.idle
    private var device: UnsafeMutableRawPointer?
    private var fingerID: Int32 = 0
    private var zone = Zone.none
    private var settings = Settings.load()
    private var startPos = MTPoint(x: 0, y: 0)
    private var lastPos = MTPoint(x: 0, y: 0)
    private var anchorY: Float = 0
    private var anchorX: Float = 0
    private var startTime: Double = 0
    private var maxMove: Float = 0
    private var stepped = false
    private var lastCornerTap: Double = 0
    private var observing = false   // true while the trackpad viewer is open

    // Touch Bar
    private var barShown = false
    private var barFn = false
    private var barIndex = -1
    private var barHoldStart: Double = 0
    private var barHoldX: Float = 0
    private var barHoldTicks = 0
    private var barCharge = 0
    private var barSliderItem: BarItem?
    private var barSteps = 0
    private var barCancelling = false
    private var barFired = false
    private var barState = BarState()

    // Click swallowing (see shouldSwallow)
    private var swallowClicksUntil: Double = 0
    private var cornerClickWindow: Double = 0
    private var swallowedDown = false

    func setObserving(_ on: Bool) {
        lock.lock()
        observing = on
        lock.unlock()
    }

    func handle(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        defer { if observing { publish(touches, count) } }

        // While a gesture is in progress, ignore other trackpads.
        if phase != .idle, self.device != device { return }

        var contacts = 0
        var contact: MTTouch?
        if let touches, count > 0 {
            let buffer = touches.assumingMemoryBound(to: MTTouch.self)
            for i in 0..<count where buffer[i].state == 4 || buffer[i].state == 5 {
                contacts += 1
                contact = buffer[i]
            }
        }
        let now = ProcessInfo.processInfo.systemUptime

        switch (phase, contacts) {
        case (.idle, 0):
            break
        case (_, 0):
            if phase == .tracking { lift(now) }
            phase = .idle
            self.device = nil
        case (_, 2...):
            if phase == .tracking { cancel(); report("Cancelled: second finger") }
            phase = .ignoring
            self.device = device
        case (.idle, 1):
            begin(contact!, device: device, now: now)
        case (.tracking, 1):
            move(contact!, now: now)
        default:
            break
        }
    }

    private func zoneFor(_ p: MTPoint) -> Zone {
        if p.x >= 1 - CORNER_SIZE && p.y >= 1 - CORNER_SIZE { return .corner }
        let sideAllowed = !settings.bottomQuarter || p.y <= BOTTOM_QUARTER
        if sideAllowed && p.x <= EDGE_WIDTH { return .left }
        if sideAllowed && p.x >= 1 - EDGE_WIDTH { return .right }
        if settings.topEdge && p.y >= 1 - EDGE_WIDTH { return .top }
        if settings.mediaStrip && p.y <= EDGE_WIDTH { return .bottom }
        return .none
    }

    private func begin(_ touch: MTTouch, device: UnsafeMutableRawPointer?, now: Double) {
        self.device = device
        settings = Settings.load()
        let p = touch.normalized.pos
        zone = zoneFor(p)
        if DEBUG { NSLog("Rimshot: down at (%.3f, %.3f) zone=%@", p.x, p.y, "\(zone)") }
        guard zone != .none else {
            phase = .ignoring
            return
        }
        phase = .tracking
        fingerID = touch.identifier
        startPos = p
        lastPos = p
        anchorY = p.y
        anchorX = p.x
        startTime = now
        maxMove = 0
        stepped = false
        barShown = false
        barIndex = -1
        barSliderItem = nil
        barSteps = 0
        barCancelling = false
        barFired = false
        barHoldTicks = 0
        barCharge = 0
        // A tap in the corner also makes a tap-to-click; swallow it unless this turns into a slide.
        if zone == .corner { cornerClickWindow = now + TAP_MAX_TIME + CLICK_GRACE }
        if zone != .bottom { DispatchQueue.main.async { Cursor.remember() } }
    }

    private func move(_ touch: MTTouch, now: Double) {
        guard touch.identifier == fingerID else {
            cancel()
            phase = .ignoring
            return
        }
        let p = touch.normalized.pos
        lastPos = p
        maxMove = max(maxMove, hypot(p.x - startPos.x, p.y - startPos.y))

        if zone == .corner && (maxMove > TAP_MAX_MOVE || now - startTime > TAP_MAX_TIME) {
            cornerClickWindow = 0
        }
        // A vertical slide that starts in the corner works as the right edge.
        if zone == .corner && !settings.bottomQuarter && abs(p.y - anchorY) >= STEP {
            zone = .right
        }
        if zone == .top {
            if settings.touchBar { moveBar(p, now) } else { slideTop(p) }
            return
        }
        guard zone == .left || zone == .right else { return }

        // Heading inward before the first step means it's a cursor move, not a slide.
        if !stepped && abs(p.x - startPos.x) > 2 * EDGE_WIDTH {
            if DEBUG { NSLog("Rimshot: finger left the edge, ignoring") }
            report("Ignored: moved inward (cursor move)")
            phase = .ignoring
            return
        }

        var dy = p.y - anchorY
        while dy >= STEP { step(up: true); anchorY += STEP; dy -= STEP }
        while dy <= -STEP { step(up: false); anchorY -= STEP; dy += STEP }
    }

    // Top edge without Touch Bar mode: a horizontal keyboard light slider, right is up.
    private func slideTop(_ p: MTPoint) {
        if !stepped && abs(p.y - startPos.y) > 2 * EDGE_WIDTH {
            if DEBUG { NSLog("Rimshot: finger left the top edge, ignoring") }
            report("Ignored: moved down (cursor move)")
            phase = .ignoring
            return
        }
        var dx = p.x - anchorX
        while dx >= TOP_STEP { step(up: true); anchorX += TOP_STEP; dx -= TOP_STEP }
        while dx <= -TOP_STEP { step(up: false); anchorX -= TOP_STEP; dx += TOP_STEP }
    }

    // Top edge in Touch Bar mode: rest to show the bar, slide to pick, lift to press,
    // hold a slider button to adjust it.
    private func moveBar(_ p: MTPoint, _ now: Double) {
        if !barShown {
            if abs(p.y - startPos.y) > 2 * EDGE_WIDTH {
                if DEBUG { NSLog("Rimshot: finger left the top edge before the bar appeared, ignoring") }
                report("Ignored: moved down (cursor move)")
                phase = .ignoring
                return
            }
            guard now - startTime >= BAR_DWELL else { return }
            barShown = true
            if DEBUG { NSLog("Rimshot: touch bar shown") }
            DispatchQueue.main.async { Cursor.freeze() }
        }

        if let item = barSliderItem, case let .slider(upKey, downKey) = item.action {
            var dx = p.x - anchorX
            while dx >= TOP_STEP {
                step(up: true, keys: (upKey, downKey, item.title)); barSteps += 1
                anchorX += TOP_STEP; dx -= TOP_STEP
            }
            while dx <= -TOP_STEP {
                step(up: false, keys: (upKey, downKey, item.title)); barSteps -= 1
                anchorX -= TOP_STEP; dx += TOP_STEP
            }
            updateBar()
            return
        }

        let fn = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        let items = fn ? FN_ITEMS : BAR_ITEMS
        let index = min(items.count - 1, max(0, Int(p.x * Float(items.count))))
        barCancelling = p.y < 1 - BAR_CANCEL_DEPTH

        if barCancelling {
            resetHold(now, p.x)
        } else if index != barIndex || fn != barFn {
            barIndex = index
            barFn = fn
            resetHold(now, p.x)
            if settings.haptics { DispatchQueue.main.async { Haptics.tick() } }
        } else if abs(p.x - barHoldX) >= BAR_HOLD_MOVE {
            resetHold(now, p.x)
        } else if !barFired {
            charge(items[index], now: now, x: p.x)
        }
        updateBar()
    }

    private func resetHold(_ now: Double, _ x: Float) {
        barHoldStart = now
        barHoldX = x
        barHoldTicks = 0
        barCharge = 0
    }

    // Holding still on a button charges it up with quickening haptics, then fires it.
    private func charge(_ item: BarItem, now: Double, x: Float) {
        let progress = (now - barHoldStart) / BAR_HOLD
        let due = BAR_CHARGE_TICKS.filter { progress >= $0 }.count
        if due > barHoldTicks {
            barHoldTicks = due
            if settings.haptics {
                DispatchQueue.main.async { Haptics.charge(due, of: BAR_CHARGE_TICKS.count) }
            }
        }
        barCharge = progress < BAR_CHARGE_TICKS[0] ? 0 : min(10, Int(progress * 10))
        guard progress >= 1 else { return }

        if settings.haptics { DispatchQueue.main.async { Haptics.thump() } }
        barCharge = 0
        if item.isSlider {
            barSliderItem = item
            anchorX = x
            barSteps = 0
            report("Touch Bar: adjusting \(item.title)")
        } else {
            barFired = true
            fire(item)
        }
    }

    private func fire(_ item: BarItem) {
        if item.isSlider {
            report("Touch Bar: hold \(item.title) to adjust")
            return
        }
        if DEBUG { NSLog("Rimshot: touch bar %@", item.title) }
        report("Touch Bar: \(item.title)")
        DispatchQueue.main.async { perform(item) }
    }

    private func updateBar() {
        let state = BarState(visible: barShown, fn: barFn, index: barIndex, slider: barSliderItem != nil,
                             cancelling: barCancelling, steps: barSteps, charge: barCharge, pressed: barFired)
        guard state != barState else { return }
        barState = state
        DispatchQueue.main.async { touchBarHUD?.update(state) }
    }

    private func hideBar() {
        barShown = false
        barSliderItem = nil
        updateBar()
    }

    private func step(up: Bool, keys: (up: Int32, down: Int32, name: String)? = nil) {
        let first = !stepped
        stepped = true
        let key: Int32
        let name: String
        if let keys {
            key = up ? keys.up : keys.down
            name = keys.name
        } else if zone == .top {
            key = up ? KEY_ILLUMINATION_UP : KEY_ILLUMINATION_DOWN
            name = "Keyboard light"
        } else if (zone == .left) != settings.swapSides {
            key = up ? KEY_BRIGHTNESS_UP : KEY_BRIGHTNESS_DOWN
            name = "Brightness"
        } else {
            key = up ? KEY_SOUND_UP : KEY_SOUND_DOWN
            name = "Volume"
        }
        let fine = CGEventSource.flagsState(.combinedSessionState).isSuperset(of: [.maskShift, .maskAlternate])
        let haptics = settings.haptics
        if DEBUG { NSLog("Rimshot: step %@ %@%@", name, up ? "up" : "down", fine ? " (fine)" : "") }
        report("\(name) \(up ? "▲" : "▼")\(fine ? "  (fine ¼ step)" : "")")
        DispatchQueue.main.async {
            if first { Cursor.freeze() }
            MediaKeys.press(key, fine: fine)
            if haptics { Haptics.tick() }
        }
    }

    private func lift(_ now: Double) {
        let isTap = now - startTime <= TAP_MAX_TIME && maxMove <= TAP_MAX_MOVE
        switch zone {
        case .top where settings.touchBar:
            guard barShown else { break }
            swallowClicksUntil = now + CLICK_GRACE
            if barCancelling {
                report("Touch Bar: cancelled")
            } else if barSliderItem == nil && !barFired && barIndex >= 0 {
                fire((barFn ? FN_ITEMS : BAR_ITEMS)[barIndex])
            }
            hideBar()
            DispatchQueue.main.async { Cursor.release() }
        case .left, .right, .top:
            if stepped { DispatchQueue.main.async { Cursor.release() } }
        case .corner:
            guard isTap else { break }
            if now - lastCornerTap <= DOUBLE_TAP_GAP {
                lastCornerTap = 0
                if DEBUG { NSLog("Rimshot: mute") }
                report("Mute toggled")
                DispatchQueue.main.async { MediaKeys.press(KEY_MUTE) }
            } else {
                lastCornerTap = now
                report("Corner tap 1 of 2…")
            }
        case .bottom:
            let dx = lastPos.x - startPos.x
            let dy = lastPos.y - startPos.y
            if abs(dx) >= SWIPE_MIN && abs(dx) > 2 * abs(dy) {
                let key = dx > 0 ? KEY_NEXT : KEY_PREVIOUS
                if DEBUG { NSLog("Rimshot: %@ track", dx > 0 ? "next" : "previous") }
                report(dx > 0 ? "Next track ▶▶" : "◀◀ Previous track")
                DispatchQueue.main.async { MediaKeys.press(key) }
            } else if isTap && settings.tapToPlay {
                if DEBUG { NSLog("Rimshot: play/pause") }
                report("Play / Pause")
                DispatchQueue.main.async { MediaKeys.press(KEY_PLAY) }
            }
        case .none:
            break
        }
    }

    private func cancel() {
        if stepped || barShown { DispatchQueue.main.async { Cursor.release() } }
        stepped = false
        if barShown { hideBar() }
    }

    // MARK: Click swallowing

    // Called by the click event tap on the main thread. Returns true to drop the click,
    // so tapping or pressing on the bar or the mute corner doesn't also click whatever
    // is under the cursor.
    func shouldSwallow(_ type: CGEventType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .leftMouseDown:
            swallowedDown = swallowDown(ProcessInfo.processInfo.systemUptime)
            return swallowedDown
        case .leftMouseDragged:
            return swallowedDown
        case .leftMouseUp:
            defer { swallowedDown = false }
            return swallowedDown
        default:
            return false
        }
    }

    private func swallowDown(_ now: Double) -> Bool {
        if phase == .tracking && zone == .top && settings.touchBar {
            guard barShown else {
                // A real click before the bar appears is just a click.
                phase = .ignoring
                return false
            }
            // Clicking while the bar is up presses the highlighted button.
            if barSliderItem == nil && !barCancelling && !barFired && barIndex >= 0 {
                barFired = true
                fire((barFn ? FN_ITEMS : BAR_ITEMS)[barIndex])
            }
            return true
        }
        return now < swallowClicksUntil || now < cornerClickWindow
    }

    // MARK: Viewer feed (only while the viewer is open)

    private func report(_ text: String) {
        guard observing else { return }
        DispatchQueue.main.async { viewer?.log(text) }
    }

    private func publish(_ touches: UnsafeMutableRawPointer?, _ count: Int) {
        var dots: [TouchDot] = []
        if let touches, count > 0 {
            let buffer = touches.assumingMemoryBound(to: MTTouch.self)
            for i in 0..<count where (1...7).contains(buffer[i].state) {
                let t = buffer[i]
                dots.append(TouchDot(id: t.identifier, pos: t.normalized.pos, size: t.size,
                                     contact: t.state == 4 || t.state == 5))
            }
        }
        let snapshot = TouchSnapshot(
            dots: dots, zone: phase == .tracking ? zone : .none, ignoring: phase == .ignoring,
            trackedID: fingerID, startPos: startPos, stepped: stepped, barShown: barShown)
        DispatchQueue.main.async { viewer?.update(snapshot) }
    }
}

let gestures = Gestures()

// MARK: - Click event tap

var clickTap: CFMachPort?

let clickTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return gestures.shouldSwallow(type) ? nil : Unmanaged.passUnretained(event)
}

// Needs Accessibility permission; returns false until it's granted.
func startClickTap() -> Bool {
    let mask = (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(mask), callback: clickTapCallback,
                                      userInfo: nil) else {
        NSLog("Rimshot: couldn't create the click event tap (Accessibility not granted?)")
        return false
    }
    clickTap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    NSLog("Rimshot: click event tap installed")
    return true
}

// MARK: - Touch Bar overlay

var touchBarHUD: TouchBarHUD?

// A slim floating bar at the bottom of the screen, shown while a finger rests on the top edge.
final class TouchBarHUD {
    private let panel: NSPanel
    private let barView = TouchBarView()
    private var shown = false
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        barView.frame = blur.bounds
        barView.autoresizingMask = [.width, .height]
        blur.addSubview(barView)
        panel.contentView = blur
    }

    func update(_ state: BarState) {
        barView.state = state
        barView.needsDisplay = true
        if state.visible != shown {
            shown = state.visible
            if shown { show() } else { hide() }
        }
    }

    private func show() {
        generation += 1
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let width = min(860, area.width - 80)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 20, width: width, height: 60), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        })
    }
}

final class TouchBarView: NSView {
    var state = BarState()

    override func draw(_ dirtyRect: NSRect) {
        let items = state.fn ? FN_ITEMS : BAR_ITEMS
        let inner = bounds.insetBy(dx: 8, dy: 8)
        if state.slider, items.indices.contains(state.index) {
            drawSlider(items[state.index], in: inner)
            return
        }

        let width = inner.width / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            let r = NSRect(x: inner.minX + CGFloat(i) * width, y: inner.minY, width: width, height: inner.height)
                .insetBy(dx: 3, dy: 0)
            let selected = i == state.index && !state.cancelling
            let shape = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            shape.fill()
            if selected && state.charge > 0 {
                // The hold fills the button from the bottom as it charges.
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor.white.withAlphaComponent(0.3).setFill()
                NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * CGFloat(state.charge) / 10).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let color: NSColor = selected ? .white : NSColor.labelColor.withAlphaComponent(state.cancelling ? 0.3 : 0.85)
            let caption: String? = !selected ? nil
                : state.pressed ? "✓ done" : (item.isSlider ? "hold to adjust" : (state.charge > 0 ? "hold…" : nil))
            drawContent(item, in: r, color: color, caption: caption)
        }

        if state.cancelling {
            text("Release to cancel", at: NSPoint(x: bounds.midX, y: bounds.midY), size: 15,
                 weight: .bold, color: .labelColor)
        }
    }

    private func drawSlider(_ item: BarItem, in r: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()

        let left = NSRect(x: r.minX + 8, y: r.minY, width: 170, height: r.height)
        if let symbol = item.symbol, let image = symbolImage(symbol, color: .labelColor) {
            image.draw(in: NSRect(x: left.minX + 6, y: r.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
        text(item.title, at: NSPoint(x: left.minX + 40, y: r.midY), size: 14, weight: .semibold,
             color: .labelColor, alignLeft: true)

        let track = NSRect(x: r.minX + 190, y: r.midY - 2, width: r.width - 290, height: 4)
        text("◀", at: NSPoint(x: track.minX - 12, y: r.midY), size: 12, weight: .regular, color: .secondaryLabelColor)
        text("▶", at: NSPoint(x: track.maxX + 12, y: r.midY), size: 12, weight: .regular, color: .secondaryLabelColor)
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        // The knob moves with the steps taken, a stand-in for the level macOS doesn't expose.
        let offset = max(-1, min(1, CGFloat(state.steps) / 16))
        let knobX = track.midX + offset * (track.width / 2)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 8, y: r.midY - 8, width: 16, height: 16)).fill()

        let steps = state.steps == 0 ? "0" : String(format: "%+d", state.steps)
        text(steps, at: NSPoint(x: r.maxX - 40, y: r.midY), size: 14, weight: .semibold, color: .labelColor)
    }

    private func drawContent(_ item: BarItem, in r: NSRect, color: NSColor, caption: String?) {
        let lift: CGFloat = caption == nil ? 0 : 6
        if let symbol = item.symbol, let image = symbolImage(symbol, color: color) {
            image.draw(in: NSRect(x: r.midX - image.size.width / 2, y: r.midY - image.size.height / 2 + lift,
                                  width: image.size.width, height: image.size.height))
        } else {
            text(item.title, at: NSPoint(x: r.midX, y: r.midY + lift), size: 14, weight: .semibold, color: color)
        }
        if let caption {
            text(caption, at: NSPoint(x: r.midX, y: r.minY + 8), size: 9, weight: .medium, color: color)
        }
    }

    private func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
                      color: NSColor, alignLeft: Bool = false) {
        let str = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: alignLeft ? point.x : point.x - sz.width / 2, y: point.y - sz.height / 2))
    }
}

// MARK: - Trackpad viewer (testing aid)

struct TouchDot {
    var id: Int32
    var pos: MTPoint
    var size: Float
    var contact: Bool
}

struct TouchSnapshot {
    var dots: [TouchDot] = []
    var zone = Gestures.Zone.none
    var ignoring = false
    var trackedID: Int32 = 0
    var startPos = MTPoint(x: 0, y: 0)
    var stepped = false
    var barShown = false
}

var viewer: ViewerController?

// Draws the trackpad to scale with every zone, live fingers and an action log.
final class TrackpadView: NSView {
    var snapshot = TouchSnapshot()
    var events: [(time: Date, text: String)] = []
    var accessibilityGranted = AXIsProcessTrusted()

    private let brightnessColor = NSColor.systemOrange
    private let volumeColor = NSColor.systemBlue
    private let muteColor = NSColor.systemRed
    private let mediaColor = NSColor.systemPurple
    private let keyboardColor = NSColor.systemGreen
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.S"
        return f
    }()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let s = Settings.load()
        let snap = snapshot

        // Fit the pad to its real aspect ratio above the status area.
        let aspect: CGFloat = trackpadSize.height > 0
            ? CGFloat(trackpadSize.width) / CGFloat(trackpadSize.height) : 1.6
        let statusHeight: CGFloat = 150
        let area = bounds.insetBy(dx: 24, dy: 16)
        let padArea = NSRect(x: area.minX, y: area.minY + statusHeight,
                             width: area.width, height: max(area.height - statusHeight, 50))
        var w = padArea.width, h = w / aspect
        if h > padArea.height { h = padArea.height; w = h * aspect }
        let pad = NSRect(x: padArea.midX - w / 2, y: padArea.midY - h / 2, width: w, height: h)

        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> NSRect {
            NSRect(x: pad.minX + CGFloat(x0) * w, y: pad.minY + CGFloat(y0) * h,
                   width: CGFloat(x1 - x0) * w, height: CGFloat(y1 - y0) * h)
        }
        func point(_ p: MTPoint) -> NSPoint {
            NSPoint(x: pad.minX + CGFloat(p.x) * w, y: pad.minY + CGFloat(p.y) * h)
        }

        // Pad surface.
        let padPath = NSBezierPath(roundedRect: pad, xRadius: 16, yRadius: 16)
        NSColor.controlBackgroundColor.setFill()
        padPath.fill()
        NSGraphicsContext.saveGraphicsState()
        padPath.addClip()

        text("normal trackpad", at: NSPoint(x: pad.midX, y: pad.midY), size: 13,
             color: .tertiaryLabelColor, weight: .regular)

        // Side edges.
        let leftIsBrightness = !s.swapSides
        for side in [Gestures.Zone.left, .right] {
            let isBrightness = (side == .left) == leftIsBrightness
            let color = isBrightness ? brightnessColor : volumeColor
            let active = snap.zone == side
            let x0: Float = side == .left ? 0 : 1 - EDGE_WIDTH
            let x1: Float = side == .left ? EDGE_WIDTH : 1
            let startTop: Float = s.bottomQuarter ? BOTTOM_QUARTER : 1
            // Where a slide may start, and (with Bottom Quarter Only) where it can continue.
            fill(rect(x0, 0, x1, startTop), color, alpha: active ? 0.45 : 0.22)
            if s.bottomQuarter {
                fill(rect(x0, startTop, x1, 1), color, alpha: active ? 0.3 : 0.06)
            }
            let label = (isBrightness ? "BRIGHTNESS" : "VOLUME") + "  ▲▼"
            let labelY: Float = s.bottomQuarter ? BOTTOM_QUARTER / 2 : 0.5
            text(label, at: point(MTPoint(x: (x0 + x1) / 2, y: labelY)), size: 11,
                 color: color, rotated: true)
        }
        if s.bottomQuarter {
            dashedLine(from: point(MTPoint(x: 0, y: BOTTOM_QUARTER)),
                       to: point(MTPoint(x: 1, y: BOTTOM_QUARTER)), color: .secondaryLabelColor)
            text("Bottom Quarter Only: side slides must start below this line",
                 at: point(MTPoint(x: 0.5, y: BOTTOM_QUARTER + 0.03)), size: 10,
                 color: .secondaryLabelColor, weight: .regular)
        }

        // Bottom media strip.
        let strip = rect(EDGE_WIDTH, 0, 1 - EDGE_WIDTH, EDGE_WIDTH)
        if s.mediaStrip {
            fill(strip, mediaColor, alpha: snap.zone == .bottom ? 0.45 : 0.22)
            let label = "◀◀ PREV   ·   swipe   ·   NEXT ▶▶" + (s.tapToPlay ? "      tap: ▶︎❙❙" : "")
            text(label, at: NSPoint(x: strip.midX, y: strip.midY), size: 10, color: mediaColor)
        } else {
            dashedRect(strip, color: .tertiaryLabelColor)
            text("media strip off", at: NSPoint(x: strip.midX, y: strip.midY), size: 10,
                 color: .tertiaryLabelColor, weight: .regular)
        }

        // Top strip: Touch Bar or keyboard light slider.
        let top = rect(EDGE_WIDTH, 1 - EDGE_WIDTH, 1 - CORNER_SIZE, 1)
        if s.topEdge && s.touchBar {
            fill(top, keyboardColor, alpha: snap.zone == .top ? 0.45 : 0.22)
            text("TOUCH BAR  ·  rest, slide, lift", at: NSPoint(x: top.midX, y: top.midY),
                 size: 10, color: keyboardColor)
            // Where each button sits once the bar is up (it spans the full width).
            let n = BAR_ITEMS.count
            let labelY = 1 - EDGE_WIDTH - 0.035
            for (i, item) in BAR_ITEMS.enumerated() {
                let x = (Float(i) + 0.5) / Float(n)
                text(item.short, at: point(MTPoint(x: x, y: labelY)), size: 9,
                     color: keyboardColor.withAlphaComponent(0.8), weight: .medium)
                if i > 0 {
                    let bx = Float(i) / Float(n)
                    let divider = NSBezierPath()
                    divider.move(to: point(MTPoint(x: bx, y: labelY - 0.025)))
                    divider.line(to: point(MTPoint(x: bx, y: 1 - EDGE_WIDTH)))
                    keyboardColor.withAlphaComponent(0.35).setStroke()
                    divider.stroke()
                }
            }
        } else if s.topEdge {
            fill(top, keyboardColor, alpha: snap.zone == .top ? 0.45 : 0.22)
            text("◀ dimmer   ·   KEYBOARD LIGHT   ·   brighter ▶", at: NSPoint(x: top.midX, y: top.midY),
                 size: 10, color: keyboardColor)
        } else {
            dashedRect(top, color: .tertiaryLabelColor)
            text("keyboard light off", at: NSPoint(x: top.midX, y: top.midY), size: 10,
                 color: .tertiaryLabelColor, weight: .regular)
        }

        // Mute corner (drawn over the right edge it overlaps).
        let corner = rect(1 - CORNER_SIZE, 1 - CORNER_SIZE, 1, 1)
        NSColor.controlBackgroundColor.setFill()
        corner.fill()
        fill(corner, muteColor, alpha: snap.zone == .corner ? 0.45 : 0.22)
        text("MUTE", at: NSPoint(x: corner.midX, y: corner.midY + 7), size: 11, color: muteColor)
        text("double-tap", at: NSPoint(x: corner.midX, y: corner.midY - 8), size: 9,
             color: muteColor, weight: .regular)

        // Live slide guides: step ticks from the touch-down point, and the inward limit.
        if snap.zone == .left || snap.zone == .right {
            let x0: Float = snap.zone == .left ? 0 : 1 - EDGE_WIDTH
            let x1: Float = snap.zone == .left ? EDGE_WIDTH : 1
            var k: Float = -40
            while k <= 40 {
                let y = snap.startPos.y + k * STEP
                if y >= 0 && y <= 1 {
                    let a = point(MTPoint(x: x0, y: y)), b = point(MTPoint(x: x1, y: y))
                    let tick = NSBezierPath()
                    tick.move(to: a); tick.line(to: b)
                    tick.lineWidth = k == 0 ? 2 : 1
                    NSColor.labelColor.withAlphaComponent(k == 0 ? 0.8 : 0.35).setStroke()
                    tick.stroke()
                }
                k += 1
            }
            if !snap.stepped {
                let limit = snap.zone == .left
                    ? snap.startPos.x + 2 * EDGE_WIDTH : snap.startPos.x - 2 * EDGE_WIDTH
                dashedLine(from: point(MTPoint(x: limit, y: 0)), to: point(MTPoint(x: limit, y: 1)),
                           color: .systemRed)
            }
        }

        if snap.zone == .top && s.touchBar {
            let limit = snap.barShown ? 1 - BAR_CANCEL_DEPTH : snap.startPos.y - 2 * EDGE_WIDTH
            dashedLine(from: point(MTPoint(x: 0, y: limit)), to: point(MTPoint(x: 1, y: limit)),
                       color: .systemRed)
        } else if snap.zone == .top {
            var k: Float = -60
            while k <= 60 {
                let x = snap.startPos.x + k * TOP_STEP
                if x >= 0 && x <= 1 {
                    let a = point(MTPoint(x: x, y: 1 - EDGE_WIDTH)), b = point(MTPoint(x: x, y: 1))
                    let tick = NSBezierPath()
                    tick.move(to: a); tick.line(to: b)
                    tick.lineWidth = k == 0 ? 2 : 1
                    NSColor.labelColor.withAlphaComponent(k == 0 ? 0.8 : 0.35).setStroke()
                    tick.stroke()
                }
                k += 1
            }
            if !snap.stepped {
                let limit = snap.startPos.y - 2 * EDGE_WIDTH
                dashedLine(from: point(MTPoint(x: 0, y: limit)), to: point(MTPoint(x: 1, y: limit)),
                           color: .systemRed)
            }
        }

        // Fingers.
        for dot in snap.dots {
            let c = point(dot.pos)
            let r = 9 + CGFloat(min(max(dot.size, 0), 3)) * 5
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let tracked = snap.zone != .none && dot.id == snap.trackedID
            let color: NSColor = tracked ? zoneColor(snap.zone, s) : (snap.ignoring ? .systemGray : .labelColor)
            if dot.contact {
                color.withAlphaComponent(0.75).setFill()
                circle.fill()
            }
            color.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        padPath.lineWidth = 1.5
        padPath.stroke()

        drawStatus(in: NSRect(x: area.minX, y: area.minY, width: area.width, height: statusHeight - 12), snap, s)
    }

    private func drawStatus(in r: NSRect, _ snap: TouchSnapshot, _ s: Settings) {
        let contacts = snap.dots.filter(\.contact).count
        let state: String
        if snap.ignoring { state = "ignoring until all fingers lift" }
        else if snap.zone == .none { state = contacts == 0 ? "idle" : "—" }
        else { state = snap.stepped ? "sliding" : "tracking" }
        let fine = CGEventSource.flagsState(.combinedSessionState).isSuperset(of: [.maskShift, .maskAlternate])
        let size = trackpadSize.width > 0
            ? String(format: "%.0f × %.0f mm", Double(trackpadSize.width) / 100, Double(trackpadSize.height) / 100)
            : "size unknown"

        var lines: [(String, NSColor)] = [
            ("Fingers \(contacts)    Zone \(zoneName(snap.zone, s))    State \(state)    Cursor \(Cursor.frozen ? "frozen" : "free")    ⇧⌥ fine \(fine ? "held" : "off")",
             .labelColor),
            ("Accessibility \(accessibilityGranted ? "granted ✓" : "NOT granted ✗ (keys won't reach macOS)")    Trackpad \(size)",
             accessibilityGranted ? .secondaryLabelColor : .systemRed),
        ]
        if events.isEmpty {
            lines.append(("Actions appear here as they fire.", .tertiaryLabelColor))
        }
        for (i, e) in events.enumerated() {
            lines.append(("\(clock.string(from: e.time))   \(e.text)",
                          NSColor.labelColor.withAlphaComponent(i == 0 ? 1 : max(0.25, 0.8 - CGFloat(i) * 0.12))))
        }

        var y = r.maxY
        for (i, (line, color)) in lines.enumerated() {
            let font = i < 2 ? NSFont.systemFont(ofSize: 12, weight: i == 0 ? .medium : .regular)
                             : NSFont.monospacedSystemFont(ofSize: 12, weight: i == 2 ? .semibold : .regular)
            let str = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
            y -= str.size().height + (i == 2 ? 8 : 2)
            if y < r.minY { break }
            str.draw(at: NSPoint(x: r.minX, y: y))
        }
    }

    private func zoneColor(_ zone: Gestures.Zone, _ s: Settings) -> NSColor {
        switch zone {
        case .left: return s.swapSides ? volumeColor : brightnessColor
        case .right: return s.swapSides ? brightnessColor : volumeColor
        case .corner: return muteColor
        case .bottom: return mediaColor
        case .top: return keyboardColor
        case .none: return .labelColor
        }
    }

    private func zoneName(_ zone: Gestures.Zone, _ s: Settings) -> String {
        switch zone {
        case .left: return s.swapSides ? "left (volume)" : "left (brightness)"
        case .right: return s.swapSides ? "right (brightness)" : "right (volume)"
        case .corner: return "corner (mute)"
        case .bottom: return "bottom (media)"
        case .top: return s.touchBar ? "top (touch bar)" : "top (keyboard light)"
        case .none: return "none"
        }
    }

    private func fill(_ r: NSRect, _ color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        r.fill(using: .sourceOver)
    }

    private func dashedLine(from a: NSPoint, to b: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    private func dashedRect(_ r: NSRect, color: NSColor) {
        let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        path.setLineDash([5, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    private func text(_ string: String, at center: NSPoint, size: CGFloat, color: NSColor,
                      weight: NSFont.Weight = .semibold, rotated: Bool = false) {
        let str = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
        let sz = str.size()
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: center.x, yBy: center.y)
        if rotated { t.rotate(byDegrees: 90) }
        t.concat()
        str.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class ViewerController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let padView = TrackpadView()
    private var boxes: [String: NSButton] = [:]
    private var lastAXCheck = Date.distantPast

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Rimshot Trackpad View"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 760, height: 480)
        window.delegate = self

        let toggles: [(String, String)] = [
            ("Swap Sides", "swapSides"), ("Bottom Quarter Only", "bottomQuarter"),
            ("Haptics", "haptics"), ("Top Edge", "topEdge"), ("Touch Bar", "touchBar"),
            ("Media Strip", "mediaStrip"), ("Tap to Play", "tapToPlay"),
        ]
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        for (title, key) in toggles {
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(flip(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(key)
            boxes[key] = box
            row.addArrangedSubview(box)
        }

        let content = NSView()
        padView.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(padView)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            padView.topAnchor.constraint(equalTo: content.topAnchor),
            padView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            padView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: padView.bottomAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
        window.center()
        window.setFrameAutosaveName("RimshotTrackpadView")

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        settingsChanged()
    }

    func show() {
        gestures.setObserving(true)
        padView.accessibilityGranted = AXIsProcessTrusted()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        gestures.setObserving(false)
    }

    func update(_ snapshot: TouchSnapshot) {
        padView.snapshot = snapshot
        if Date().timeIntervalSince(lastAXCheck) > 2 {
            lastAXCheck = Date()
            padView.accessibilityGranted = AXIsProcessTrusted()
        }
        padView.needsDisplay = true
    }

    func log(_ text: String) {
        padView.events.insert((Date(), text), at: 0)
        if padView.events.count > 6 { padView.events.removeLast() }
        padView.needsDisplay = true
    }

    @objc private func flip(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func settingsChanged() {
        let d = UserDefaults.standard
        for (key, box) in boxes { box.state = d.bool(forKey: key) ? .on : .off }
        boxes["tapToPlay"]?.isEnabled = d.bool(forKey: "mediaStrip")
        boxes["touchBar"]?.isEnabled = d.bool(forKey: "topEdge")
        padView.needsDisplay = true
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var deviceCount = 0
    private var layoutOK = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Settings.defaults)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Rimshot") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "ES"
        }
        menu.delegate = self
        statusItem.menu = menu

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("Rimshot: accessibility trusted = %@", trusted ? "yes" : "no")

        let stride = MemoryLayout<MTTouch>.stride
        NSLog("Rimshot: MTTouch stride = %d", stride)
        if stride != 96 {
            layoutOK = false
            NSLog("Rimshot: MTTouch stride is %d, expected 96; not starting multitouch", stride)
        } else {
            deviceCount = startMultitouch()
        }
        touchBarHUD = TouchBarHUD()
        _ = startClickTap()
        if CommandLine.arguments.contains("--viewer") { showViewer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Cursor.release()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !layoutOK {
            menu.addItem(disabled("Touch data layout mismatch, see log"))
            menu.addItem(.separator())
        } else if deviceCount == 0 {
            menu.addItem(disabled("No trackpad found"))
            menu.addItem(.separator())
        }
        if clickTap == nil && AXIsProcessTrusted() { _ = startClickTap() }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        menu.addItem(item("Show Trackpad View", #selector(showViewer)))
        menu.addItem(.separator())

        let d = UserDefaults.standard
        menu.addItem(toggle("Swap Sides", key: "swapSides"))
        menu.addItem(toggle("Bottom Quarter Only", key: "bottomQuarter"))
        menu.addItem(toggle("Haptic Feedback", key: "haptics"))
        menu.addItem(toggle("Top Edge", key: "topEdge"))
        let bar = toggle("Touch Bar (off: keyboard light slider)", key: "touchBar")
        bar.indentationLevel = 1
        bar.isEnabled = d.bool(forKey: "topEdge")
        menu.addItem(bar)
        menu.addItem(toggle("Media Strip", key: "mediaStrip"))
        let tap = toggle("Tap to Play", key: "tapToPlay")
        tap.indentationLevel = 1
        tap.isEnabled = d.bool(forKey: "mediaStrip")
        menu.addItem(tap)
        menu.addItem(.separator())

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Rimshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, key: String) -> NSMenuItem {
        let item = item(title, #selector(flip(_:)))
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }

    @objc private func flip(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: key), forKey: key)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Rimshot: Open at Login failed: %@", error.localizedDescription)
        }
    }

    @objc private func showViewer() {
        if viewer == nil { viewer = ViewerController() }
        viewer?.show()
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
