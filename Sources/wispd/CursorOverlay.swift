import AppKit
import QuartzCore
import WispCore

/// Motion constants recovered from Sky's `ComputerUseCursor.MotionConfiguration.live`.
struct CursorMotionConfig {
    // Values recovered from Codex: the Sky daemon's MotionConfiguration.live and the Chrome content-script cursor,
    // which share one design (same arc handles, scoot threshold, click angle and spring fractions).
    var clickAngle = -44.0          // degrees; the glyph tilts to this while the mouse button is down
    var boundsMargin = 20.0
    var startHandle = 0.4196
    var endpointHandle = 0.15
    var arcSize = 0.2766
    var arcFlow = 0.5784
    var straightPathDistanceThreshold = 10.0
    var springResponseMin = 0.12
    var springResponseMax = 2.2
    var springDampingFraction = 0.9
    var scootDistanceThreshold = 196.0
    var scootRotationMax = 70.0     // degrees of tilt at the middle of a short move
    var scootSquashAmount = 0.15    // squash across the travel axis at the middle of a short move
    var closeEnoughProgress = 0.995 // the click may fire once the path spring is this far along ...
    var closeEnoughDistance = 3.157 // ... or the glyph is within this many points of the target
    var arrivalDistance = 0.85      // motion is over when the glyph is this close ...
    var arrivalVelocity = 12.0      // ... and both position springs are slower than this (pt/s)
    var wobbleAmplitude = 12.5      // degrees of the "thinking" wobble after arriving
    var wobblePeriod = 0.66         // seconds per wobble cycle
    var wobbleEnvelope = 1.41       // seconds until the wobble fades out
    var entranceBlur = 5.0          // px of blur when the cursor is invisible
    var entranceScale = 0.4         // scale when the cursor is invisible
    var speedSquashFloor = 0.65     // stretch factor at very high speed (1 - speed/5500, floored)
}

/// One spring in the form Codex uses (response = period of the undamped oscillation, dampingFraction =
/// fraction of critical damping), integrated with velocity Verlet at 240 Hz.
struct Spring {
    var value: Double
    var target: Double
    var velocity = 0.0
    var force = 0.0
    var response: Double
    var dampingFraction: Double
    private var simulationTime = 0.0
    private var scriptTime = 0.0
    static let substep = 1.0 / 240.0

    init(_ value: Double, target: Double, response: Double, dampingFraction: Double) {
        self.value = value; self.target = target; self.response = response; self.dampingFraction = dampingFraction
    }

    mutating func snap(to t: Double) { value = t; target = t; velocity = 0; force = 0; simulationTime = 0; scriptTime = 0 }

    mutating func retune(response r: Double, dampingFraction d: Double) { response = r; dampingFraction = d }

    /// Advances the spring by `dt` seconds.
    mutating func step(_ dt: Double) {
        let h = Spring.substep
        let stiffness = min(pow(2 * Double.pi / max(0.001, response), 2), 1 / (2 * h * h))
        let damping = sqrt(stiffness) * 2 * dampingFraction
        scriptTime += max(0, dt)
        if scriptTime - simulationTime > 1 { simulationTime = scriptTime - 1.0 / 60.0 }   // never replay a long stall
        while simulationTime < scriptTime {
            let half = h / 2
            let v = velocity + force * half
            value += v * h
            force = v * -damping + (target - value) * stiffness
            velocity = v + force * half
            simulationTime += h
        }
        if settled { value = target }
    }

    var settled: Bool {
        let threshold = 0.001 * 60
        if max(velocity * velocity, force * force) > threshold * threshold { return false }
        let tol = target * 0.01, diff = target - value
        return tol == 0 || diff * diff <= tol * tol
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The visible agent cursor: an overlay panel with a glowing arrow that travels along spring-driven paths.
@MainActor
final class CursorOverlay {
    static let shared = CursorOverlay()

    private let panel: NSPanel
    private let view: FlippedView
    private let glowFarLayer = CAShapeLayer()
    private let glowNearLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let glyphContainer = CALayer()
    private let panelSize: CGFloat = 96
    private let hotspot = CGPoint(x: 32, y: 32)
    /// Scale from the glyph's 16-unit design box to points: the black arrow spans about 15 pt, as in Codex.
    private let glyphScale: CGFloat = 1.21
    private var config = CursorMotionConfig()
    private static let defaultAccent = NSColor(red: 0.31, green: 0.55, blue: 1.0, alpha: 1)
    var enabled = true
    var accent = CursorOverlay.defaultAccent

    // lens (activity indicator) state
    private let lens: LensOverlay
    /// Offset of the lens centre from the arrow tip while it follows the cursor (CG axes, y down).
    private let lensCursorOffset = CGPoint(x: 28, y: 10)
    /// Inset of the lens from the anchor window's top-right corner when the cursor is hidden.
    private let lensAnchorInset: CGFloat = 14
    /// Current activity as last set through `setActivity(_:anchor:)` or `setLoading(_:)`.
    private(set) var activity: WispActivity = .idle
    /// Invoked on the main actor whenever `activity` changes, including the internal transitions back to idle
    /// (pause elapsed, `hideNow`), so the menu bar can mirror the lens.
    var onActivityChanged: ((WispActivity) -> Void)?
    /// Master switch for the lens; `false` hides it and keeps it hidden regardless of activity.
    var lensEnabled = true {
        didSet { if lensEnabled != oldValue { applyActivity(animated: false) } }
    }
    private var lensAnchor: CGRect?
    private var lensFollowsCursor = false
    private var pauseHideTask: Task<Void, Never>?

    // motion state (mirrors the Codex cursor view model)
    private var timer: Timer?
    private var pathPoints: (CGPoint, CGPoint, CGPoint, CGPoint)?  // cubic bezier P0 C1 C2 P3 (CG coords)
    private var progressSpring = Spring(0, target: 1, response: 0.4, dampingFraction: 0.9)
    private var positionX = Spring(0, target: 0, response: 0.19, dampingFraction: 0.9)
    private var positionY = Spring(0, target: 0, response: 0.19, dampingFraction: 0.9)
    private var rotation = Spring(0, target: 0, response: 0.12, dampingFraction: 0.9)
    private var scootAxis = Spring(0, target: 0, response: 0.12, dampingFraction: 0.9)
    private var scootRotation = Spring(0, target: 0, response: 0.055, dampingFraction: 0.82)
    private var scootStretch = Spring(1, target: 1, response: 0.12, dampingFraction: 0.86)
    private var stretch = Spring(1, target: 1, response: 0.2, dampingFraction: 0.85)
    private var visibility = Spring(0, target: 0, response: 0.42, dampingFraction: 0.86)
    private var pressTilt = Spring(0, target: 0, response: 0.12, dampingFraction: 0.9)
    private enum Motion { case bezier(target: CGPoint), scoot(start: CGPoint, end: CGPoint, rotationTarget: Double) }
    private var motion: Motion?
    private var wobbleStartedAt: CFTimeInterval?
    private var current = CGPoint.zero
    private var lastTick: CFTimeInterval = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var gatedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hideTask: Task<Void, Never>?
    private var visible = false
    private var pressed = false

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 102)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.animationBehavior = .none
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true   // the entrance blur is a Core Image filter on the glyph layer
        panel.contentView = view
        lens = LensOverlay(accent: CursorOverlay.defaultAccent)
        buildLayers()
        panel.alphaValue = 0
    }

    /// The Codex arrow: a rounded arrowhead pointing up-left, designed in a 16-unit box (the same path the Codex
    /// Chrome extension draws), moved so the tip sits on the hotspot and scaled to points.
    private func arrowPath() -> CGPath {
        let s = glyphScale
        let tip = CGPoint(x: 3.0, y: 3.0)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - tip.x) * s, y: (y - tip.y) * s) }
        let p = CGMutablePath()
        p.move(to: pt(3.04536, 4.45259))
        p.addCurve(to: pt(4.45259, 3.04536), control1: pt(2.7582, 3.60299), control2: pt(3.60299, 2.7582))
        p.addLine(to: pt(14.1828, 6.33403))
        p.addCurve(to: pt(14.0715, 8.39045), control1: pt(15.1637, 6.66558), control2: pt(15.0872, 8.08006))
        p.addLine(to: pt(10.2994, 9.54319))
        p.addCurve(to: pt(9.54319, 10.2994), control1: pt(9.93919, 9.65327), control2: pt(9.65327, 9.93919))
        p.addLine(to: pt(8.39046, 14.0715))
        p.addCurve(to: pt(6.33404, 14.1828), control1: pt(8.08007, 15.0872), control2: pt(6.66558, 15.1637))
        p.closeSubpath()
        return p
    }

    private func buildLayers() {
        guard let root = view.layer else { return }
        root.masksToBounds = false
        glyphContainer.frame = CGRect(x: hotspot.x, y: hotspot.y, width: 1, height: 1)
        glyphContainer.anchorPoint = CGPoint(x: 0, y: 0)
        glyphContainer.position = hotspot
        glyphContainer.masksToBounds = false
        root.addSublayer(glyphContainer)

        let path = arrowPath()
        // Accent glow, as Codex's CSS: drop-shadow(0 0 15px accent 48%) behind drop-shadow(0 0 6px accent 90%).
        // A CSS blur radius is about twice the Core Animation shadow radius.
        for (layer, radius, opacity) in [(glowFarLayer, 7.5, 0.48), (glowNearLayer, 3.0, 0.9)] {
            layer.path = path
            layer.fillColor = accent.cgColor
            layer.strokeColor = accent.cgColor
            layer.lineWidth = 1.5 * glyphScale
            layer.lineJoin = .round
            layer.shadowColor = accent.cgColor
            layer.shadowOpacity = Float(opacity)
            layer.shadowRadius = radius
            layer.shadowOffset = .zero
            glyphContainer.addSublayer(layer)
        }
        // The arrow itself: black with a white outline and a faint contact shadow (the rendered asset's look).
        arrowLayer.path = path
        arrowLayer.fillColor = NSColor.black.cgColor
        arrowLayer.strokeColor = NSColor.white.cgColor
        arrowLayer.lineWidth = 1.5 * glyphScale
        arrowLayer.lineJoin = .round
        arrowLayer.shadowColor = NSColor.black.cgColor
        arrowLayer.shadowOpacity = 0.28
        arrowLayer.shadowRadius = 1.2
        arrowLayer.shadowOffset = CGSize(width: 0, height: 1)
        glyphContainer.addSublayer(arrowLayer)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            glyphContainer.filters = [blur]
        }
        applyVisibility()
    }

    func setAccent(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return }
        accent = NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        for layer in [glowFarLayer, glowNearLayer] {
            layer.fillColor = accent.cgColor
            layer.strokeColor = accent.cgColor
            layer.shadowColor = accent.cgColor
        }
        lens.setAccent(accent)
    }

    // MARK: Coordinate helpers (CG top-left origin <-> AppKit bottom-left origin)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Converts a CG point (top-left origin, y down) to an AppKit point (bottom-left origin, y up) on the primary
    /// screen. Shared by the cursor and lens panels.
    static func appKitPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    private func panelOrigin(for cgPoint: CGPoint) -> NSPoint {
        let tip = CursorOverlay.appKitPoint(fromCG: cgPoint)
        return NSPoint(x: tip.x - hotspot.x, y: tip.y - (panelSize - hotspot.y))
    }

    private func place(_ p: CGPoint) {
        current = p
        panel.setFrameOrigin(panelOrigin(for: p))
        if lensFollowsCursor, lens.isVisible {
            lens.place(centerCG: CGPoint(x: p.x + lensCursorOffset.x, y: p.y + lensCursorOffset.y))
        }
    }

    // MARK: Public API

    func show(at p: CGPoint) {
        guard enabled else { Log.debug("cursor: show skipped (disabled)"); return }
        Log.debug("cursor: show at \(Int(p.x)),\(Int(p.y)) visible=\(visible)")
        hideTask?.cancel()
        if !visible {
            place(p)
            snapSprings(to: p)
            motion = nil
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Codex fades the glyph in through a visibility spring: opacity rises while blur (5 px) and scale (0.4) relax.
        visibility.target = 1
        let wasVisible = visible
        visible = true
        startTimer()
        if !wasVisible { updateLensPlacement(animated: true) }
    }

    func hide(after delay: Double = 1.2) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        visibility.target = 0
        startTimer()   // the tick hides the panel once the visibility spring settles at zero
        visible = false
        // The lens is independent of the cursor: fall back to the anchor placement (or hide) rather than dropping it.
        updateLensPlacement(animated: true)
    }

    /// Hides the cursor and the lens immediately (no fades) and returns the activity to idle (screen lock, shutdown).
    func hideNow() {
        hideTask?.cancel()
        pauseHideTask?.cancel()
        pauseHideTask = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
        visible = false
        visibility.snap(to: 0)   // the next appearance plays the entrance again
        motion = nil
        changeActivity(.idle, note: "hideNow")
        lensAnchor = nil
        lensFollowsCursor = false
        lens.setPaused(false)
        lens.hide(immediately: true)
    }

    /// User intervention: the cursor disappears at once while a visible lens turns neutral and fades after a second
    /// (`.paused`); a hidden lens leaves the activity idle.
    func pauseNow() {
        hideTask?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
        visible = false
        visibility.snap(to: 0)
        motion = nil
        setActivity(.paused, anchor: lensAnchor)
    }

    /// Animates to `target` (CG coords). Returns once the motion is "close enough" for the click to fire (the path
    /// spring is 99.5 % done or the glyph is within ~3 pt), or, with `gateOnFinish`, once the glyph has settled.
    func move(to target: CGPoint, gateOnFinish: Bool = false) async {
        guard enabled else { return }
        if !visible {
            // First appearance: start slightly offset so there is visible motion.
            let start = CGPoint(x: target.x - 60, y: target.y + 40)
            show(at: start)
        }
        hideTask?.cancel()
        wobbleStartedAt = nil
        let start = current
        let d = hypot(target.x - start.x, target.y - start.y)
        if d < 0.5 { snapSprings(to: target); place(target); motion = nil; return }
        if d <= config.scootDistanceThreshold {
            // Short move: the position springs go straight there while the glyph squashes across the travel axis
            // and tilts, most strongly halfway.
            let dx = target.x - start.x, dy = target.y - start.y
            let n = CGPoint(x: dx / d, y: dy / d)
            let axis = atan2(n.y, n.x) * 180 / .pi
            let rotationTarget = min(1, max(-1, n.x * 0.75 + -n.y * 0.62)) * config.scootRotationMax
            positionX.retune(response: 0.19, dampingFraction: 0.9)
            positionY.retune(response: 0.19, dampingFraction: 0.9)
            positionX.target = target.x
            positionY.target = target.y
            rotation.target = rotation.value + shortestTurn(from: rotation.value, to: 0)
            scootAxis.target = scootAxis.value + shortestTurn(from: scootAxis.value, to: axis)
            pathPoints = nil
            motion = .scoot(start: start, end: target, rotationTarget: rotationTarget)
        } else {
            // Long move: a curved path followed by a progress spring whose response grows with the path length,
            // while the position springs chase the point on the path (this is where the overshoot comes from).
            buildPath(from: start, to: target, distance: d)
            let response = min(config.springResponseMax, max(config.springResponseMin, 0.42 + min(1, max(0, (d - 180) / 760)) * 0.22 + 0.04))
            progressSpring = Spring(0, target: 1, response: response, dampingFraction: config.springDampingFraction)
            let chase = min(0.12, max(0.035, response * 0.18))
            positionX.retune(response: chase, dampingFraction: config.springDampingFraction)
            positionY.retune(response: chase, dampingFraction: config.springDampingFraction)
            motion = .bezier(target: target)
        }
        startTimer()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if gateOnFinish { arrivalWaiters.append(c) } else { gatedWaiters.append(c) }
        }
    }

    private func snapSprings(to p: CGPoint) {
        positionX.snap(to: p.x); positionY.snap(to: p.y)
        rotation.snap(to: 0); scootAxis.snap(to: 0); scootRotation.snap(to: 0)
        scootStretch.snap(to: 1); stretch.snap(to: 1)
    }

    private func shortestTurn(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func buildPath(from a: CGPoint, to b: CGPoint, distance d: Double) {
        if d < config.straightPathDistanceThreshold {
            pathPoints = (a, a, b, b)
            return
        }
        let dx = b.x - a.x, dy = b.y - a.y
        var nx = -dy / d, ny = dx / d
        // Pick the bulge side with more room on screen (Codex evaluates candidates against the bounds margin).
        let mid = CGPoint(x: a.x + dx * config.arcFlow, y: a.y + dy * config.arcFlow)
        let bulge = min(520, max(50, config.arcSize * d))
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let candidate1 = CGPoint(x: mid.x + nx * bulge, y: mid.y + ny * bulge)
        let candidate2 = CGPoint(x: mid.x - nx * bulge, y: mid.y - ny * bulge)
        func room(_ p: CGPoint) -> Double {
            min(p.x - screen.minX, screen.maxX - p.x, p.y, screen.height - p.y) - config.boundsMargin
        }
        if room(candidate2) > room(candidate1) { nx = -nx; ny = -ny }
        let peak = CGPoint(x: mid.x + nx * bulge, y: mid.y + ny * bulge)
        let startLen = min(640, max(48, min(d * config.startHandle, d * 0.9)))
        let endLen = min(640, max(48, min(d * config.endpointHandle, d * 0.9)))
        func toward(_ from: CGPoint, _ to: CGPoint, _ len: Double) -> CGPoint {
            let vx = to.x - from.x, vy = to.y - from.y
            let l = max(0.001, hypot(vx, vy))
            return CGPoint(x: from.x + vx / l * len, y: from.y + vy / l * len)
        }
        pathPoints = (a, toward(a, peak, startLen), toward(b, peak, endLen), b)
    }

    private func point(at t: Double) -> CGPoint {
        guard let (p0, p1, p2, p3) = pathPoints else { return current }
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    private func tangent(at t: Double) -> CGPoint {
        guard let (p0, p1, p2, p3) = pathPoints else { return CGPoint(x: 1, y: 0) }
        let u = 1 - t
        let x = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
        let y = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
        return CGPoint(x: x, y: y)
    }

    private func startTimer() {
        if timer != nil { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 30.0, max(1.0 / 240.0, now - lastTick))
        lastTick = now
        var settledMotion = false
        switch motion {
        case .bezier(let target):
            progressSpring.step(dt)
            let t = min(1, max(0, progressSpring.value))
            let p = point(at: t)
            positionX.target = p.x
            positionY.target = p.y
            let tg = tangent(at: t)
            // Face the direction of travel: the glyph points up-left at rest, so the tangent angle gets +134 deg.
            let facing = hypot(tg.x, tg.y) < 0.001 ? 0 : atan2(tg.y, tg.x) * 180 / .pi + 134
            rotation.target = rotation.value + shortestTurn(from: rotation.value, to: facing)
            scootAxis.target = scootAxis.value + shortestTurn(from: scootAxis.value, to: 0)
            scootStretch.target = 1
            scootRotation.target = 0
            if t >= 0.999, abs(progressSpring.velocity) < 0.01, arrived(at: target) {
                settledMotion = true
                snapSprings(to: target)
            }
            let closeEnough = progressSpring.value >= config.closeEnoughProgress || hypot(target.x - current.x, target.y - current.y) <= config.closeEnoughDistance
            if closeEnough { resumeGated() }
        case .scoot(let start, let end, let rotationTarget):
            let prog = projection(of: current, from: start, to: end)
            let bell = sin(min(1, prog) * .pi)
            scootStretch.target = 1 - config.scootSquashAmount * bell
            scootRotation.target = rotationTarget * bell
            stretch.target = 1
            if prog >= 0.999, arrived(at: end) {
                settledMotion = true
                snapSprings(to: end)
            }
            if hypot(end.x - current.x, end.y - current.y) <= config.closeEnoughDistance { resumeGated() }
        case .none:
            stretch.target = 1; scootStretch.target = 1; scootRotation.target = 0
        }
        // Integrate the position and shape springs (velocity Verlet, as Codex does), then measure the speed.
        let before = current
        positionX.step(dt); positionY.step(dt); rotation.step(dt); scootAxis.step(dt)
        scootRotation.step(dt); scootStretch.step(dt); stretch.step(dt); visibility.step(dt); pressTilt.step(dt)
        let p = CGPoint(x: positionX.value, y: positionY.value)
        if case .bezier = motion, !settledMotion {
            let speed = hypot(p.x - before.x, p.y - before.y) / max(dt, 1.0 / 240.0)
            stretch.target = min(1, max(config.speedSquashFloor, 1 - speed / 5500))
        }
        place(p)
        if settledMotion {
            motion = nil
            pathPoints = nil
            wobbleStartedAt = now
            resumeGated()
            let waiters = arrivalWaiters
            arrivalWaiters = []
            for w in waiters { w.resume() }
        }
        applyTransform(now: now)
        applyVisibility()
        // Stop ticking once everything is at rest (and hide the panel when the cursor faded out).
        let allSettled = motion == nil && positionX.settled && positionY.settled && rotation.settled && scootRotation.settled
            && scootStretch.settled && stretch.settled && visibility.settled && pressTilt.settled && wobbleStartedAt == nil
        if allSettled {
            stopTimer()
            if !visible, visibility.value <= 0.001 { panel.orderOut(nil) }
        }
    }

    private func resumeGated() {
        guard !gatedWaiters.isEmpty else { return }
        let waiters = gatedWaiters
        gatedWaiters = []
        for w in waiters { w.resume() }
    }

    private func arrived(at target: CGPoint) -> Bool {
        hypot(target.x - current.x, target.y - current.y) <= config.arrivalDistance
            && abs(positionX.velocity) <= config.arrivalVelocity && abs(positionY.velocity) <= config.arrivalVelocity
    }

    private func projection(of p: CGPoint, from a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 0.001 { return 1 }
        return min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    }

    /// The "thinking" wobble Codex plays after the cursor arrives: a decaying sinusoidal tilt.
    private func wobble(now: CFTimeInterval) -> Double {
        guard let started = wobbleStartedAt else { return 0 }
        let t = now - started
        let envelope = min(1, t / config.wobbleEnvelope)
        if envelope >= 1 { wobbleStartedAt = nil; return 0 }
        return sin(t / config.wobblePeriod * .pi * 2) * sin(envelope * .pi) * config.wobbleAmplitude
    }

    /// Composes the glyph transform the way the Codex cursor does (innermost first): squash across the travel axis,
    /// then the facing/scoot/press/wobble rotation, then the speed stretch and the entrance scale.
    private func applyTransform(now: CFTimeInterval) {
        let vis = min(1, max(0, visibility.value))
        let entrance = config.entranceScale + (1 - config.entranceScale) * vis
        var t = CATransform3DIdentity
        let axis = scootAxis.value * .pi / 180
        let squash = min(1, max(0, scootStretch.value))
        if abs(squash - 1) > 0.001 {
            t = CATransform3DRotate(t, -axis, 0, 0, 1)
            t = CATransform3DScale(t, 1, squash, 1)
            t = CATransform3DRotate(t, axis, 0, 0, 1)
        }
        let angle = (rotation.value + scootRotation.value + pressTilt.value + wobble(now: now)) * .pi / 180
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DScale(t, stretch.value * entrance, entrance, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphContainer.transform = t
        CATransaction.commit()
    }

    private func applyVisibility() {
        let vis = min(1, max(0, visibility.value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphContainer.opacity = Float(vis)
        glyphContainer.setValue(config.entranceBlur * (1 - vis), forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }

    /// The click: the arrow tilts to Codex's `clickAngle` and dips slightly while the mouse button is down; the
    /// glow brightens for the press. Call `pressEnd()` after the mouse-up.
    func pressBegin() {
        guard enabled, visible else { Log.debug("cursor: press skipped (enabled=\(enabled) visible=\(visible))"); return }
        Log.debug("cursor: press at \(Int(current.x)),\(Int(current.y))")
        pressed = true
        wobbleStartedAt = nil
        pressTilt.target = config.clickAngle
        stretch.target = 0.9
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowNearLayer.shadowOpacity = 1
        glowFarLayer.shadowOpacity = 0.7
        CATransaction.commit()
        startTimer()
    }

    func pressEnd() {
        guard enabled else { return }
        pressed = false
        pressTilt.target = 0
        stretch.target = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowNearLayer.shadowOpacity = 0.9
        glowFarLayer.shadowOpacity = 0.48
        CATransaction.commit()
        startTimer()
    }

    // MARK: Activity (lens)

    /// Sets the activity state and the window the lens should attach to when the cursor is hidden.
    ///
    /// - `anchor`: the target window frame in CG (top-left origin) screen coordinates, or nil. While the cursor
    ///   panel is visible the lens sits 28 pt to the right of the arrow tip and follows it; otherwise it sits inside
    ///   the anchor's top-right corner with a 14 pt inset; with no anchor and no cursor it stays hidden.
    /// - `.observing` and `.acting` show the lens (120 ms fade-in); `.idle` hides it (200 ms fade-out); `.paused`
    ///   turns the arc neutral gray, freezes the sweep and hides the lens after 1 s.
    func setActivity(_ a: WispActivity, anchor: CGRect?) {
        changeActivity(a, note: anchor.map { "anchor=\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" })
        lensAnchor = anchor
        applyActivity(animated: true)
    }

    /// Records a transition (no-op when unchanged), logs it and notifies `onActivityChanged`.
    private func changeActivity(_ a: WispActivity, note: String? = nil) {
        guard a != activity else { return }
        Log.debug("activity \(activity.rawValue) -> \(a.rawValue)\(note.map { " (\($0))" } ?? "")")
        activity = a
        onActivityChanged?(a)
    }

    /// Legacy loading toggle kept for existing call sites: `true` maps to `.observing` when idle or paused (a new
    /// read resumes a paused lens) and `false` returns `.observing` to `.idle`. An explicit `.acting` state set
    /// through `setActivity` is left untouched so a settle inside an action does not flip the indicator.
    func setLoading(_ on: Bool) {
        switch (on, activity) {
        case (true, .idle), (true, .paused): setActivity(.observing, anchor: lensAnchor)
        case (false, .observing): setActivity(.idle, anchor: lensAnchor)
        default: break
        }
    }

    /// Where the lens centre should be right now (CG coords), or nil when it has nowhere to go.
    private func lensCenter() -> (CGPoint, followsCursor: Bool)? {
        if visible {
            return (CGPoint(x: current.x + lensCursorOffset.x, y: current.y + lensCursorOffset.y), true)
        }
        if let a = lensAnchor {
            let half = LensOverlay.size / 2
            let inset = lensAnchorInset
            let c = CGPoint(x: a.maxX - inset - half, y: a.minY + inset + half)
            return (c, false)
        }
        return nil
    }

    /// Re-places (or hides) the lens after the cursor or anchor changed, without touching the activity state. A
    /// paused lens stays where it is until it fades.
    private func updateLensPlacement(animated: Bool) {
        guard lensEnabled, activity == .observing || activity == .acting else { return }
        guard let (c, follows) = lensCenter() else {
            lensFollowsCursor = false
            lens.hide()
            return
        }
        lensFollowsCursor = follows
        lens.place(centerCG: c, animated: animated && lens.isVisible)
        if !lens.isVisible, activity != .paused { lens.show() }
    }

    private func applyActivity(animated: Bool) {
        pauseHideTask?.cancel()
        pauseHideTask = nil
        guard lensEnabled else {
            lensFollowsCursor = false
            lens.hide(immediately: true)
            return
        }
        switch activity {
        case .idle:
            lensFollowsCursor = false
            lens.setPaused(false)
            lens.hide()
        case .observing, .acting:
            lens.setPaused(false)
            guard let (c, follows) = lensCenter() else {
                lensFollowsCursor = false
                lens.hide()
                return
            }
            lensFollowsCursor = follows
            lens.place(centerCG: c, animated: animated && lens.isVisible)
            if !lens.isVisible { lens.show() }
        case .paused:
            // Only a visible lens is "kept" for a second; a hidden one stays hidden and the state is already idle.
            // `.paused` is never sticky: it always resolves to `.idle` (or to `.observing` via a new read).
            guard lens.isVisible else {
                lensAnchor = nil
                lensFollowsCursor = false
                changeActivity(.idle, note: "lens hidden")
                return
            }
            lens.setPaused(true)
            pauseHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.activity == .paused else { return }
                self.lensFollowsCursor = false
                self.lens.hide()
                self.lensAnchor = nil
                self.pauseHideTask = nil
                self.changeActivity(.idle, note: "pause elapsed")
            }
        }
    }

    var currentPoint: CGPoint { current }
}
