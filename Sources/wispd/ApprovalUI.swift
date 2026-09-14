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

        let timeout = ApprovalUI.timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<ApprovalChoice, Never>) in
            let state = PromptState()
            // Fail closed: if the main queue never gets to run the alert (a wedged main thread), answer `deny` after
            // the timeout instead of leaving the caller hanging. Runs off the main actor on purpose.
            let fallback = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if state.resumeIfNeverStarted() { cont.resume(returning: .deny) }
            }
            // Run the modal loop from a fresh main-queue turn rather than inside the executor job that got us here.
            DispatchQueue.main.async {
                guard state.markStarted() else { return } // the fallback already answered; never show the alert
                // The watchdog counts from the moment the alert actually starts, not from when it was queued.
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled, !state.finished else { return }
                    NSApp.abortModal()
                }
                let response = alert.runModal()
                state.finished = true
                watchdog.cancel()
                fallback.cancel()
                alert.window.orderOut(nil)
                if state.resumeAfterStart() { cont.resume(returning: choice(for: response)) }
            }
        }
    }

    /// Lifecycle flags for one prompt, shared between the main-queue block and the detached fallback.
    private final class PromptState: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var resumed = false
        private var _finished = false

        var finished: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _finished }
            set { lock.lock(); _finished = newValue; lock.unlock() }
        }

        /// Marks the alert as started; false when the fallback already resumed the continuation.
        func markStarted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            started = true
            return true
        }

        /// Claims the continuation for the fallback, only if the alert never started.
        func resumeIfNeverStarted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if started || resumed { return false }
            resumed = true
            return true
        }

        /// Claims the continuation for the alert's own result.
        func resumeAfterStart() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
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
