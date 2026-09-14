import AppKit
import ApplicationServices
import WispCore

/// Menu-bar item and the "Wisp is controlling …" banner.
@MainActor
final class StatusUI: NSObject {
    static let shared = StatusUI()

    private var item: NSStatusItem?
    private let banner: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var activeApp: String?
    var onStop: (() -> Void)?
    var onQuit: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var bannerEnabled = true
    private var missing: [PermissionsMonitor.Permission] = []
    private var permissionItems: [NSMenuItem] = []

    private override init() {
        banner = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        banner.level = NSWindow.Level(rawValue: 102)
        banner.isOpaque = false
        banner.backgroundColor = .clear
        banner.hasShadow = true
        banner.ignoresMouseEvents = true
        banner.hidesOnDeactivate = false
        banner.isReleasedWhenClosed = false
        banner.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        banner.sharingType = .none
        // Plain dark pill: no vibrancy so the label stays crisp on any wallpaper.
        let bg = NSView(frame: banner.contentView!.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.86).cgColor
        bg.layer?.cornerRadius = 17
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.frame = NSRect(x: 16, y: 8, width: 328, height: 18)
        label.autoresizingMask = [.width]
        bg.addSubview(label)
        banner.contentView = bg
    }

    private var hideTimer: Timer?

    /// Keeps the banner up while actions are flowing; it fades a few seconds after the last one.
    func touch() {
        guard let app = activeApp, bannerEnabled else { return }
        showBanner(for: app)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.banner.orderOut(nil) }
        }
    }

    private func showBanner(for app: String) {
        let text = "✦ Wisp is controlling \(app)  ·  Esc to stop"
        label.stringValue = text
        let width = max(260, min(720, label.attributedStringValue.size().width + 44))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let s = screen {
            let x = s.visibleFrame.midX - width / 2
            let y = s.visibleFrame.maxY - 46
            banner.setFrame(NSRect(x: x, y: y, width: width, height: 34), display: true)
        }
        label.frame = NSRect(x: 16, y: 8, width: width - 32, height: 18)
        banner.alphaValue = 1
        banner.orderFrontRegardless()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(active: false)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Wisp computer use"
        let menu = NSMenu()
        let status = NSMenuItem(title: "Wisp: idle", action: nil, keyEquivalent: "")
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop current action (Esc)", action: #selector(stopAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.tag = 2
        menu.addItem(updates)
        let version = NSMenuItem(title: "Wisp \(WispVersion.string) (\(WispVersion.build))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wisp", action: #selector(quitAction), keyEquivalent: ""))
        for m in menu.items { m.target = self }
        item.menu = menu
        self.item = item
        rebuildPermissionItems()
    }

    @objc private func stopAction() { onStop?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }

    func setUpdatesAvailable(_ available: Bool) {
        item?.menu?.item(withTag: 2)?.isHidden = !available
    }
    @objc private func quitAction() { onQuit?() }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: WispPathsBridge.logPath)) }
    @objc private func grantAccessibility() { PermissionsMonitor.shared.request(.accessibility) }
    @objc private func grantScreenRecording() { PermissionsMonitor.shared.request(.screenRecording) }

    /// Called by the permissions monitor whenever the set of missing permissions changes.
    func setMissingPermissions(_ list: [PermissionsMonitor.Permission]) {
        missing = list
        rebuildPermissionItems()
        item?.button?.image = MenuBarIcon.image(active: activeApp != nil, warning: !list.isEmpty)
        item?.button?.toolTip = list.isEmpty ? (activeApp.map { "Wisp is controlling \($0)" } ?? "Wisp computer use")
            : "Wisp needs permissions: " + list.map { $0.title }.joined(separator: ", ")
    }

    private func rebuildPermissionItems() {
        guard let menu = item?.menu else { return }
        for m in permissionItems { menu.removeItem(m) }
        permissionItems = []
        guard !missing.isEmpty else { return }
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: "Permissions needed", action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        for p in missing {
            let title: String
            let sel: Selector
            switch p {
            case .accessibility:
                title = "Grant Accessibility access (required)…"
                sel = #selector(grantAccessibility)
            case .screenRecording:
                title = "Grant Screen Recording (for screenshots)…"
                sel = #selector(grantScreenRecording)
            }
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            items.append(mi)
        }
        items.append(.separator())
        var index = 2
        for mi in items {
            menu.insertItem(mi, at: index)
            index += 1
        }
        permissionItems = items
    }

    /// Short onboarding hint in the banner (used on first run when Accessibility is missing).
    func showHint(_ text: String, seconds: Double = 8) {
        label.stringValue = text
        let width = max(300, min(760, label.attributedStringValue.size().width + 44))
        if let s = NSScreen.main ?? NSScreen.screens.first {
            banner.setFrame(NSRect(x: s.visibleFrame.midX - width / 2, y: s.visibleFrame.maxY - 46, width: width, height: 34), display: true)
        }
        label.frame = NSRect(x: 16, y: 8, width: width - 32, height: 18)
        banner.alphaValue = 1
        banner.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.banner.orderOut(nil) }
        }
    }

    func setActive(app: String?) {
        activeApp = app
        if let m = item?.menu?.item(withTag: 1) { m.title = app.map { "Wisp: controlling \($0)" } ?? "Wisp: idle" }
        item?.button?.image = MenuBarIcon.image(active: app != nil, warning: !missing.isEmpty)
        item?.button?.toolTip = app.map { "Wisp is controlling \($0)" } ?? "Wisp computer use"
        if app != nil, bannerEnabled {
            touch()
        } else {
            hideTimer?.invalidate()
            banner.orderOut(nil)
        }
    }
}

enum WispPathsBridge {
    static var logPath: String { WispCoreLogPath() }
}


/// Menu-bar glyph: a small cursor arrow with a spark. Template image, so it follows the menu bar appearance.
enum MenuBarIcon {
    static func image(active: Bool, warning: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 3.5, y: 2.5))
            arrow.line(to: NSPoint(x: 3.5, y: 14.5))
            arrow.line(to: NSPoint(x: 6.6, y: 11.6))
            arrow.line(to: NSPoint(x: 8.7, y: 16.2))
            arrow.line(to: NSPoint(x: 10.8, y: 15.3))
            arrow.line(to: NSPoint(x: 8.7, y: 10.8))
            arrow.line(to: NSPoint(x: 12.6, y: 10.8))
            arrow.close()
            arrow.lineJoinStyle = .round
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if active {
                arrow.fill()
            } else {
                arrow.lineWidth = 1.4
                arrow.stroke()
            }
            // spark
            let spark = NSBezierPath()
            let c = NSPoint(x: 14.0, y: 4.5)
            let r: CGFloat = active ? 3.2 : 2.6
            spark.move(to: NSPoint(x: c.x, y: c.y - r))
            spark.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15))
            spark.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15))
            spark.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15))
            spark.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15))
            spark.close()
            spark.fill()
            if warning {
                // corner badge: permissions missing
                let badge = NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 6, height: 6))
                NSColor.black.setFill()
                badge.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: NSRect(x: 13.4, y: 13.4, width: 2.2, height: 2.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            _ = rect
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Watches TCC grants and drives first-run onboarding: system prompts, Settings deep links, menu-bar hints.
@MainActor
final class PermissionsMonitor {
    static let shared = PermissionsMonitor()

    enum Permission: CaseIterable {
        case accessibility, screenRecording
        var title: String { self == .accessibility ? "Accessibility" : "Screen Recording" }
        var settingsURL: URL {
            switch self {
            case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    private var timer: Timer?
    private(set) var missing: [Permission] = []
    private var promptedAccessibility = false
    private var promptedScreen = false
    var onGranted: ((Permission) -> Void)?

    private init() {}

    static func check(_ p: Permission) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    func start() {
        refresh(initial: true)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = missing.isEmpty ? 15 : 2
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(initial: false) }
        }
    }

    private func refresh(initial: Bool) {
        let now = Permission.allCases.filter { !PermissionsMonitor.check($0) }
        if now != missing || initial {
            let newlyGranted = missing.filter { !now.contains($0) }
            missing = now
            StatusUI.shared.setMissingPermissions(now)
            for p in newlyGranted { onGranted?(p) }
            if initial, now.contains(.accessibility) {
                request(.accessibility)
                StatusUI.shared.showHint("✦ Wisp needs Accessibility access · click the menu bar icon to grant it", seconds: 12)
            }
            schedule()
        }
    }

    /// Triggers the system prompt (once) and opens the matching System Settings pane.
    func request(_ p: Permission) {
        switch p {
        case .accessibility:
            if !promptedAccessibility {
                promptedAccessibility = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
        case .screenRecording:
            if !promptedScreen {
                promptedScreen = true
                _ = CGRequestScreenCaptureAccess()
            }
        }
        NSWorkspace.shared.open(p.settingsURL)
    }

    /// Called when a screenshot is requested without permission: prompt once, then let the caller report the error.
    func promptScreenRecordingIfNeeded() {
        guard !PermissionsMonitor.check(.screenRecording), !promptedScreen else { return }
        request(.screenRecording)
    }
}
