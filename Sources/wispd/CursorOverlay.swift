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
    private let loadingLayer = CAShapeLayer()
    private let glyphContainer = CALayer()
    private let panelSize: CGFloat = 96
    private let hotspot = CGPoint(x: 24, y: 24)
    private var config = CursorMotionConfig()
    var enabled = true
    var accent = NSColor(red: 0.31, green: 0.55, blue: 1.0, alpha: 1)

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

        loadingLayer.path = CGPath(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14), transform: nil)
        loadingLayer.fillColor = nil
        loadingLayer.strokeColor = accent.cgColor
        loadingLayer.lineWidth = 2.2
        loadingLayer.lineCap = .round
        loadingLayer.strokeStart = 0
        loadingLayer.strokeEnd = 0.65
        loadingLayer.opacity = 0
        loadingLayer.position = CGPoint(x: hotspot.x + 26, y: hotspot.y + 26)
        root.addSublayer(loadingLayer)
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
        loadingLayer.strokeColor = accent.cgColor
    }

    // MARK: Coordinate helpers (CG top-left origin <-> AppKit bottom-left origin)

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func panelOrigin(for cgPoint: CGPoint) -> NSPoint {
        NSPoint(x: cgPoint.x - hotspot.x, y: primaryHeight - cgPoint.y - (panelSize - hotspot.y))
    }

    private func place(_ p: CGPoint) {
        current = p
        panel.setFrameOrigin(panelOrigin(for: p))
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
        visible = true
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
        setLoading(false)
    }

    func hideNow() {
        hideTask?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
        visible = false
        setLoading(false)
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

    func setLoading(_ on: Bool) {
        if on {
            guard visible else { return }
            if loadingLayer.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                loadingLayer.add(spin, forKey: "spin")
            }
            loadingLayer.opacity = 1
        } else {
            loadingLayer.opacity = 0
            loadingLayer.removeAnimation(forKey: "spin")
        }
    }

    var currentPoint: CGPoint { current }
}
