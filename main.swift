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

    static let defaults: [String: Any] = [
        "swapSides": false, "bottomQuarter": false, "haptics": true,
        "mediaStrip": false, "tapToPlay": false, "topEdge": true,
    ]

    static func load() -> Settings {
        let d = UserDefaults.standard
        return Settings(
            swapSides: d.bool(forKey: "swapSides"),
            bottomQuarter: d.bool(forKey: "bottomQuarter"),
            haptics: d.bool(forKey: "haptics"),
            mediaStrip: d.bool(forKey: "mediaStrip"),
            tapToPlay: d.bool(forKey: "tapToPlay"),
            topEdge: d.bool(forKey: "topEdge"))
    }
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
            move(contact!)
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
        if zone != .bottom { DispatchQueue.main.async { Cursor.remember() } }
    }

    private func move(_ touch: MTTouch) {
        guard touch.identifier == fingerID else {
            cancel()
            phase = .ignoring
            return
        }
        let p = touch.normalized.pos
        lastPos = p
        maxMove = max(maxMove, hypot(p.x - startPos.x, p.y - startPos.y))

        // A vertical slide that starts in the corner works as the right edge.
        if zone == .corner && !settings.bottomQuarter && abs(p.y - anchorY) >= STEP {
            zone = .right
        }
        if zone == .top {
            slideTop(p)
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

    // Top edge: a horizontal slider, right is up.
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

    private func step(up: Bool) {
        let first = !stepped
        stepped = true
        let key: Int32
        let name: String
        if zone == .top {
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
        if stepped { DispatchQueue.main.async { Cursor.release() } }
        stepped = false
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
            trackedID: fingerID, startPos: startPos, stepped: stepped)
        DispatchQueue.main.async { viewer?.update(snapshot) }
    }
}

let gestures = Gestures()

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

        // Top keyboard backlight strip.
        let top = rect(EDGE_WIDTH, 1 - EDGE_WIDTH, 1 - CORNER_SIZE, 1)
        if s.topEdge {
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

        if snap.zone == .top {
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
        case .top: return "top (keyboard light)"
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
            ("Haptics", "haptics"), ("Keyboard Light", "topEdge"),
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
        menu.addItem(toggle("Keyboard Light (top edge)", key: "topEdge"))
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
