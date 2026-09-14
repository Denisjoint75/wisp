import AppKit
import QuartzCore

/// What the daemon is doing right now, as shown by the lens indicator (Sky's `ActivityState` = idle | loading |
/// paused, split so that "loading" distinguishes observing from acting).
///
/// - `idle`: nothing in flight; the lens is hidden.
/// - `observing`: capturing or settling (reading the UI tree, taking a screenshot, waiting for quiet).
/// - `acting`: an action is being performed; the lens accompanies the cursor.
/// - `paused`: the user intervened; the lens turns neutral, stops sweeping and fades after a second.
enum WispActivity: String, Equatable {
    case idle
    case observing
    case acting
    case paused
}

/// The "observing" lens: a small borderless panel, independent of the cursor, drawn with Core Animation.
///
/// Artwork: a thin ring with a sweeping arc that rotates once every 1.1 s (ease-in-out), a soft outer glow in the
/// cursor accent colour, and a subtle breathing scale (0.94 -> 1.0). `CursorOverlay` owns placement and state; this
/// type only knows how to show, move, pause and hide itself.
@MainActor
final class LensOverlay {
    /// Panel edge length in points. The ring is drawn inside with room for the glow.
    static let size: CGFloat = 44

    private static let ringRadius: CGFloat = 12
    private static let spinKey = "spin"
    private static let breatheKey = "breathe"
    private static let pausedTint = NSColor(white: 0.66, alpha: 1)

    private let panel: NSPanel
    private let view: NSView
    private let container = CALayer()
    private let glowLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private var accent: NSColor
    private var fadeGeneration = 0

    /// True between a `show` and the start of a `hide` fade.
    private(set) var isVisible = false
    /// True while the arc is neutral and frozen.
    private(set) var isPaused = false

    init(accent: NSColor) {
        self.accent = accent
        let size = LensOverlay.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 102)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none          // never appears in our own screenshots
        panel.animationBehavior = .none
        view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        panel.contentView = view
        panel.alphaValue = 0
        buildLayers()
    }

    // MARK: Artwork

    private func buildLayers() {
        guard let root = view.layer else { return }
        root.masksToBounds = false
        let size = LensOverlay.size
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let center = CGPoint(x: size / 2, y: size / 2)
        let r = LensOverlay.ringRadius
        let circle = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)

        // The container carries the breathing scale; every layer is centred in it so scale and rotation pivot on
        // the ring centre.
        container.frame = bounds
        container.masksToBounds = false
        root.addSublayer(container)

        // Soft outer glow: a wide, faint stroke of the same circle with a coloured shadow.
        glowLayer.frame = bounds
        glowLayer.path = circle
        glowLayer.fillColor = nil
        glowLayer.lineWidth = 3
        glowLayer.shadowOpacity = 0.85
        glowLayer.shadowRadius = 7
        glowLayer.shadowOffset = .zero
        container.addSublayer(glowLayer)

        // Thin base ring.
        ringLayer.frame = bounds
        ringLayer.path = circle
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 1.2
        container.addSublayer(ringLayer)

        // Sweeping arc: a quarter-plus of the circle with round caps; it rotates about the centre.
        arcLayer.frame = bounds
        arcLayer.path = circle
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 2.4
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = 0.3
        container.addSublayer(arcLayer)

        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isPaused {
            let tint = LensOverlay.pausedTint
            glowLayer.strokeColor = tint.withAlphaComponent(0.12).cgColor
            glowLayer.shadowColor = tint.cgColor
            glowLayer.shadowOpacity = 0.25
            ringLayer.strokeColor = tint.withAlphaComponent(0.45).cgColor
            arcLayer.strokeColor = tint.cgColor
        } else {
            glowLayer.strokeColor = accent.withAlphaComponent(0.22).cgColor
            glowLayer.shadowColor = accent.cgColor
            glowLayer.shadowOpacity = 0.85
            ringLayer.strokeColor = accent.withAlphaComponent(0.35).cgColor
            arcLayer.strokeColor = accent.cgColor
        }
        CATransaction.commit()
    }

    private func startMotion() {
        if arcLayer.animation(forKey: LensOverlay.spinKey) == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.1
            spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            spin.repeatCount = .infinity
            arcLayer.add(spin, forKey: LensOverlay.spinKey)
        }
        if container.animation(forKey: LensOverlay.breatheKey) == nil {
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.94
            breathe.toValue = 1.0
            breathe.duration = 1.3
            breathe.autoreverses = true
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.repeatCount = .infinity
            container.add(breathe, forKey: LensOverlay.breatheKey)
        }
    }

    private func stopMotion(freezeArc: Bool) {
        if freezeArc, let pres = arcLayer.presentation() {
            // Keep the arc where it is instead of snapping back to angle zero.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arcLayer.transform = pres.transform
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arcLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        arcLayer.removeAnimation(forKey: LensOverlay.spinKey)
        container.removeAnimation(forKey: LensOverlay.breatheKey)
    }

    // MARK: Public API

    /// Updates the accent colour (the cursor's accent); a paused lens keeps its neutral tint until resumed.
    func setAccent(_ color: NSColor) {
        accent = color
        applyColors()
    }

    /// Positions the lens so its centre sits at `center` (CG top-left screen coordinates).
    func place(centerCG center: CGPoint, animated: Bool = false) {
        let half = LensOverlay.size / 2
        let p = CursorOverlay.appKitPoint(fromCG: center)
        let origin = NSPoint(x: p.x - half, y: p.y - half)
        if animated, isVisible {
            // `setFrameOrigin` is not animatable through the animator proxy; the whole frame is.
            let frame = NSRect(origin: origin, size: panel.frame.size)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    /// Orders the panel in and fades it up over 120 ms; restarts the sweep unless paused.
    func show() {
        fadeGeneration += 1
        if !isPaused { startMotion() }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        isVisible = true
    }

    /// Fades the panel out over 200 ms (or immediately) and orders it out once done.
    func hide(immediately: Bool = false) {
        fadeGeneration += 1
        let gen = fadeGeneration
        isVisible = false
        if immediately {
            panel.alphaValue = 0
            panel.orderOut(nil)
            stopMotion(freezeArc: false)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self = self, self.fadeGeneration == gen, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.stopMotion(freezeArc: false)
            }
        })
    }

    /// Paused: neutral gray, arc frozen in place, glow dimmed. Resuming restores the accent and the sweep.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        applyColors()
        if paused {
            stopMotion(freezeArc: true)
        } else if isVisible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arcLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            startMotion()
        }
    }
}
