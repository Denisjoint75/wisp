import AppKit
import ApplicationServices

/// One AXObserver per application; records notification timestamps for settle detection and tree invalidation.
final class AXNotificationHub {
    static let shared = AXNotificationHub()

    private final class Entry {
        let observer: AXObserver
        let app: AXUIElement
        var lastEvent = Date.distantPast
        var count = 0
        var destroyed = 0
        var layoutChanges = 0
        init(observer: AXObserver, app: AXUIElement) { self.observer = observer; self.app = app }
    }

    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()

    static let notifications: [String] = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXUIElementDestroyedNotification, kAXWindowCreatedNotification, kAXWindowMovedNotification,
        kAXWindowResizedNotification, kAXSheetCreatedNotification, kAXDrawerCreatedNotification, kAXMenuOpenedNotification,
        kAXMenuClosedNotification, kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification,
        kAXSelectedTextChangedNotification, kAXRowCountChangedNotification, kAXTitleChangedNotification,
        kAXSelectedRowsChangedNotification, "AXLoadComplete", "AXElementBusyChanged", kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification, kAXMainWindowChangedNotification, kAXCreatedNotification,
    ]

    func observe(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if entries[pid] != nil { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let hub = Unmanaged<AXNotificationHub>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            hub.record(pid: pid, notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let obs = observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var added = 0
        for n in AXNotificationHub.notifications {
            let err = AXObserverAddNotification(obs, app, n as CFString, refcon)
            if err == .success { added += 1 } else { Log.debug("AXObserverAddNotification(\(n)) pid \(pid): \(err.rawValue)") }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
        Log.debug("AX observer for pid \(pid): \(added)/\(AXNotificationHub.notifications.count) notifications registered")
        entries[pid] = Entry(observer: obs, app: app)
    }

    func stop(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(e.observer), .defaultMode)
    }

    private func record(pid: pid_t, notification: String) {
        lock.lock(); defer { lock.unlock() }
        if Log.verbose { Log.debug("AX notification \(notification) from pid \(pid)") }
        guard let e = entries[pid] else { return }
        e.lastEvent = Date()
        e.count += 1
        if notification == kAXUIElementDestroyedNotification { e.destroyed += 1 }
        if notification == kAXLayoutChangedNotification || notification == kAXWindowCreatedNotification || notification == kAXSheetCreatedNotification { e.layoutChanges += 1 }
    }

    struct Stats { var lastEvent: Date; var count: Int; var destroyed: Int; var layoutChanges: Int }

    func stats(pid: pid_t) -> Stats? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[pid] else { return nil }
        return Stats(lastEvent: e.lastEvent, count: e.count, destroyed: e.destroyed, layoutChanges: e.layoutChanges)
    }
}
