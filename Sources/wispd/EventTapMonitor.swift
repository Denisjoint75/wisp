import AppKit
import CoreGraphics

/// Listen-only session event tap. Detects Esc (cancel) and real user input during an action (intervention).
final class EventTapMonitor {
    static let shared = EventTapMonitor()

    var onEscape: (() -> Void)?
    var onUserInput: ((CGEventType) -> Void)?
    /// Only report intervention while armed (an action is executing).
    var armed = false

    private var tap: CFMachPort?
    private var thread: Thread?
    private var lastMouse = CGPoint.zero
    private(set) var isRunning = false

    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            Log.warn("event tap unavailable (Accessibility permission missing?)")
            return false
        }
        self.tap = tap
        let t = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self?.isRunning = true
            CFRunLoopRun()
        }
        t.name = "wisp.eventtap"
        t.start()
        thread = t
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        // Ignore our own synthesized events.
        if event.getIntegerValueField(.eventSourceUserData) == WispEventTag.magic { return }
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53 { onEscape?(); return }
        }
        guard armed else { return }
        if type == .mouseMoved {
            let p = event.location
            let d = abs(p.x - lastMouse.x) + abs(p.y - lastMouse.y)
            lastMouse = p
            if d < 12 { return }
        }
        onUserInput?(type)
    }
}
