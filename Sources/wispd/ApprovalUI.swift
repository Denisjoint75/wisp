import AppKit
import WispCore

/// What the user picked in the approval prompt.
enum ApprovalChoice: Equatable, Sendable {
    case once, session, always, deny
}

/// The "Allow Wisp to control <app>?" prompt. Prompts are serialized: a second request waits for the first to close.
@MainActor
enum ApprovalUI {
    /// The prompt dismisses itself as `.deny` after this long; the CLI client times out at 180 s.
    static var timeout: TimeInterval = 120

    private static var last: Task<ApprovalChoice, Never>?

    /// Shows the prompt and returns the user's choice. Safe to call from any actor; the alert itself runs modally on
    /// the main thread, so a caller should not hold the daemon actor busy while waiting.
    static func ask(appName: String, bundleId: String?, icon: NSImage?, risk: Risk, subtitle: String) async -> ApprovalChoice {
        let previous = last
        let task = Task { @MainActor () -> ApprovalChoice in
            _ = await previous?.value
            return await present(appName: appName, bundleId: bundleId, icon: icon, risk: risk, subtitle: subtitle)
        }
        last = task
        let choice = await task.value
        if last == task { last = nil }
        return choice
    }

    private static func present(appName: String, bundleId: String?, icon: NSImage?, risk: Risk, subtitle: String) async -> ApprovalChoice {
        let alert = NSAlert()
        alert.messageText = "Allow Wisp to control \(appName)?"
        var info = subtitle
        if let id = bundleId, !id.isEmpty { info += "\n\n\(id)" }
        alert.informativeText = info
        alert.alertStyle = risk == .high ? .critical : .warning
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Allow for This Session")
        alert.addButton(withTitle: "Always Allow")
        let deny = alert.addButton(withTitle: "Don't Allow")
        deny.keyEquivalent = "\u{1b}"
        alert.buttons[0].keyEquivalent = "\r"
        // Wisp is an LSUIElement accessory app: bring it forward so the sheetless alert is actually visible.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        return await withCheckedContinuation { (cont: CheckedContinuation<ApprovalChoice, Never>) in
            var finished = false
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, !finished else { return }
                NSApp.abortModal()
            }
            // Run the modal loop from a fresh main-queue turn rather than inside the executor job that got us here.
            DispatchQueue.main.async {
                let response = alert.runModal()
                finished = true
                watchdog.cancel()
                alert.window.orderOut(nil)
                cont.resume(returning: choice(for: response))
            }
        }
    }

    private static func choice(for response: NSApplication.ModalResponse) -> ApprovalChoice {
        switch response {
        case .alertFirstButtonReturn: return .once
        case .alertSecondButtonReturn: return .session
        case .alertThirdButtonReturn: return .always
        default: return .deny
        }
    }
}
