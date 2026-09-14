import AppKit
import QuartzCore
import WispCore

/// Motion constants recovered from Sky's `ComputerUseCursor.MotionConfiguration.live`.
struct CursorMotionConfig {
    var clickAngle = -44.0          // degrees
    var boundsMargin = 20.0
    var startHandle = 0.4196
    var endpointHandle = 0.15
    var arcSize = 0.2766
    var arcFlow = 0.5784
    var straightPathDistanceThreshold = 10.0
    var springResponseScaler = 0.9
    var springResponseMin = 0.12
    var springResponseMax = 2.2
    var springDampingFraction = 0.9
    var scootDistanceThreshold = 196.0
    var scootPositionResponse = 0.24
    var scootPositionDampingFraction = 0.84
    var scootStretchXAmount = 0.38
    var scootSquashYAmount = 0.18
    var scootRotationMax = 76.0
    var terminalTangentBlendStart = 0.99
    var closeEnoughProgress = 0.995
    var closeEnoughDistance = 3.157
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
    private let glowLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let glyphContainer = CALayer()
    private let panelSize: CGFloat = 96
    private let hotspot = CGPoint(x: 24, y: 24)
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
    /// Master switch for the lens; `false` hides it and keeps it hidden regardless of activity.
    var lensEnabled = true {
        didSet { if lensEnabled != oldValue { applyActivity(animated: false) } }
    }
    private var lensAnchor: CGRect?
    private var lensFollowsCursor = false
    private var pauseHideTask: Task<Void, Never>?

    // motion state
    private var timer: Timer?
    private var pathPoints: (CGPoint, CGPoint, CGPoint, CGPoint)?  // cubic bezier P0 C1 C2 P3 (CG coords)
    private var progress = 0.0
    private var velocity = 0.0
    private var response = 0.3
    private var damping = 0.9
    private var current = CGPoint.zero
    private var lastTick: CFTimeInterval = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var hideTask: Task<Void, Never>?
    private var isScoot = false
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        panel.sharingType = .none
        panel.animationBehavior = .none
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
        view.wantsLayer = true
        panel.contentView = view
        lens = LensOverlay(accent: CursorOverlay.defaultAccent)
        buildLayers()
        panel.alphaValue = 0
    }

    private func arrowPath() -> CGPath {
        // Classic arrow shape, 24pt tall, hotspot at (0,0).
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17.5), CGPoint(x: 4.6, y: 13.4), CGPoint(x: 7.6, y: 20.2),
            CGPoint(x: 10.6, y: 18.9), CGPoint(x: 7.6, y: 12.2), CGPoint(x: 13.2, y: 12.2),
        ]
        let p = CGMutablePath()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }

    private func buildLayers() {
        guard let root = view.layer else { return }
        root.masksToBounds = false
        glyphContainer.frame = CGRect(x: hotspot.x, y: hotspot.y, width: 1, height: 1)
        glyphContainer.anchorPoint = CGPoint(x: 0, y: 0)
        glyphContainer.position = hotspot
        root.addSublayer(glyphContainer)

        let path = arrowPath()
        glowLayer.path = path
        glowLayer.fillColor = accent.withAlphaComponent(0.9).cgColor
        glowLayer.shadowColor = accent.cgColor
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowRadius = 9
        glowLayer.shadowOffset = .zero
        glyphContainer.addSublayer(glowLayer)

        arrowLayer.path = path
        arrowLayer.fillColor = accent.cgColor
        arrowLayer.strokeColor = NSColor.white.cgColor
        arrowLayer.lineWidth = 1.6
        arrowLayer.lineJoin = .round
        arrowLayer.shadowColor = NSColor.black.cgColor
        arrowLayer.shadowOpacity = 0.35
        arrowLayer.shadowRadius = 1.5
        arrowLayer.shadowOffset = CGSize(width: 0, height: 1)
        glyphContainer.addSublayer(arrowLayer)

        ringLayer.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        ringLayer.fillColor = nil
        ringLayer.strokeColor = accent.cgColor
        ringLayer.lineWidth = 2
        ringLayer.opacity = 0
        ringLayer.position = hotspot
        root.addSublayer(ringLayer)
    }

    func setAccent(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return }
        accent = NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        glowLayer.fillColor = accent.withAlphaComponent(0.9).cgColor
        glowLayer.shadowColor = accent.cgColor
        arrowLayer.fillColor = accent.cgColor
        ringLayer.strokeColor = accent.cgColor
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
        guard enabled else { return }
        hideTask?.cancel()
        if !visible { place(p); progress = 1; velocity = 0; pathPoints = nil }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        let wasVisible = visible
        visible = true
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.panel.animator().alphaValue = 0
        }
        visible = false
        // The lens is independent of the cursor: fall back to the anchor placement (or hide) rather than dropping it.
        updateLensPlacement(animated: true)
    }

    /// Hides the cursor immediately and returns the activity to idle (used on intervention and shutdown).
    func hideNow() {
        hideTask?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
        visible = false
        setActivity(.idle, anchor: nil)
    }

    /// Animates to `target` (CG coords). Returns once the spring is 99.5% done or within ~3pt (Sky's "closeEnough").
    func move(to target: CGPoint, gateOnFinish: Bool = false) async {
        guard enabled else { return }
        if !visible {
            // First appearance: start slightly offset so there is visible motion.
            let start = CGPoint(x: target.x - 60, y: target.y + 40)
            place(start)
            show(at: start)
        }
        hideTask?.cancel()
        let start = current
        let d = hypot(target.x - start.x, target.y - start.y)
        if d < 0.5 { place(target); return }
        buildPath(from: start, to: target, distance: d)
        progress = 0
        velocity = 0
        let scoot = d < config.scootDistanceThreshold
        isScoot = scoot
        if scoot {
            response = config.scootPositionResponse
            damping = config.scootPositionDampingFraction
        } else {
            response = min(config.springResponseMax, max(config.springResponseMin, config.springResponseScaler * (d / 1400)))
            damping = config.springDampingFraction
        }
        startTimer()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            arrivalWaiters.append(c)
            self.gateOnFinish = gateOnFinish
        }
    }

    private var gateOnFinish = false

    private func buildPath(from a: CGPoint, to b: CGPoint, distance d: Double) {
        if d < config.straightPathDistanceThreshold || d < config.scootDistanceThreshold {
            pathPoints = (a, a, b, b)
            return
        }
        let dx = b.x - a.x, dy = b.y - a.y
        var nx = -dy / d, ny = dx / d
        // Pick the bulge side with more room on screen (Sky evaluates candidates against the bounds margin).
        let mid = CGPoint(x: a.x + dx * config.arcFlow, y: a.y + dy * config.arcFlow)
        let bulge = config.arcSize * d
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let candidate1 = CGPoint(x: mid.x + nx * bulge, y: mid.y + ny * bulge)
        let candidate2 = CGPoint(x: mid.x - nx * bulge, y: mid.y - ny * bulge)
        func room(_ p: CGPoint) -> Double {
            min(p.x - screen.minX, screen.maxX - p.x, p.y, screen.height - p.y) - config.boundsMargin
        }
        if room(candidate2) > room(candidate1) { nx = -nx; ny = -ny }
        let peak = CGPoint(x: mid.x + nx * bulge, y: mid.y + ny * bulge)
        let c1 = CGPoint(x: a.x + (peak.x - a.x) * (config.startHandle * 2.2), y: a.y + (peak.y - a.y) * (config.startHandle * 2.2))
        let c2 = CGPoint(x: b.x + (peak.x - b.x) * (config.endpointHandle * 2.2), y: b.y + (peak.y - b.y) * (config.endpointHandle * 2.2))
        pathPoints = (a, c1, c2, b)
    }

    private func point(at t: Double) -> CGPoint {
        guard let (p0, p1, p2, p3) = pathPoints else { return current }
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
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
        guard let (_, _, _, target) = pathPoints else { stopTimer(); return }
        let k = pow(2 * Double.pi / response, 2)
        let c = 2 * damping * sqrt(k)
        let accel = k * (1 - progress) - c * velocity
        velocity += accel * dt
        progress += velocity * dt
        let clamped = min(max(progress, 0), 1.05)
        let p = point(at: min(clamped, 1))
        let prev = current
        place(p)
        applySquash(prev: prev, now: p, dt: dt)
        let remaining = hypot(target.x - p.x, target.y - p.y)
        let done = progress >= config.closeEnoughProgress || remaining <= config.closeEnoughDistance
        if done, !gateOnFinish || abs(velocity) < 0.05 {
            let waiters = arrivalWaiters
            arrivalWaiters = []
            for w in waiters { w.resume() }
        }
        if progress >= 0.999, abs(velocity) < 0.02 {
            place(target)
            resetSquash()
            pathPoints = nil
            stopTimer()
            let waiters = arrivalWaiters
            arrivalWaiters = []
            for w in waiters { w.resume() }
        }
    }

    private func applySquash(prev: CGPoint, now: CGPoint, dt: Double) {
        guard isScoot else { resetSquash(); return }
        let vx = (now.x - prev.x) / dt, vy = (now.y - prev.y) / dt
        let speed = hypot(vx, vy)
        let s = min(1, speed / 2400)
        let angle = atan2(vy, vx)
        let tilt = min(config.scootRotationMax, s * config.scootRotationMax) * .pi / 180
        var t = CATransform3DIdentity
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DScale(t, 1 + config.scootStretchXAmount * s, 1 - config.scootSquashYAmount * s, 1)
        t = CATransform3DRotate(t, -angle, 0, 0, 1)
        _ = tilt
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphContainer.transform = pressed ? CATransform3DRotate(t, config.clickAngle * .pi / 180, 0, 0, 1) : t
        CATransaction.commit()
    }

    private func resetSquash() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphContainer.transform = pressed ? CATransform3DMakeRotation(config.clickAngle * .pi / 180, 0, 0, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// Tilts the arrow (Sky's `clickAngle`) and pulses a ring; call `pressEnd()` after the mouse-up.
    func pressBegin() {
        guard enabled, visible else { return }
        pressed = true
        let anim = CASpringAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = config.clickAngle * Double.pi / 180
        anim.damping = 14
        anim.stiffness = 600
        anim.duration = anim.settlingDuration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        glyphContainer.add(anim, forKey: "press")
        ringPulse()
    }

    func pressEnd() {
        guard enabled else { return }
        pressed = false
        let anim = CASpringAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = config.clickAngle * Double.pi / 180
        anim.toValue = 0
        anim.damping = 12
        anim.stiffness = 420
        anim.duration = anim.settlingDuration
        glyphContainer.removeAnimation(forKey: "press")
        glyphContainer.add(anim, forKey: "release")
    }

    private func ringPulse() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 44.0 / 28.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringLayer.add(group, forKey: "pulse")
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
        activity = a
        lensAnchor = anchor
        applyActivity(animated: true)
    }

    /// Legacy loading toggle kept for existing call sites: `true` maps to `.observing` when idle and `false`
    /// returns `.observing` to `.idle`. An explicit `.acting` or `.paused` state set through `setActivity` is left
    /// untouched so a settle inside an action does not flip the indicator.
    func setLoading(_ on: Bool) {
        switch (on, activity) {
        case (true, .idle): setActivity(.observing, anchor: lensAnchor)
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

    /// Re-places (or hides) the lens after the cursor or anchor changed, without touching the activity state.
    private func updateLensPlacement(animated: Bool) {
        guard lensEnabled, activity != .idle else { return }
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
            // Only a visible lens is "kept" for a second; a hidden one stays hidden.
            guard lens.isVisible else { return }
            lens.setPaused(true)
            pauseHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.activity == .paused else { return }
                self.lensFollowsCursor = false
                self.lens.hide()
            }
        }
    }

    var currentPoint: CGPoint { current }
}
