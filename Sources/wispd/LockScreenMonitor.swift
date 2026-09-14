import AppKit
import CoreGraphics
import Foundation

/// Watches the login session for lock/unlock transitions so an in-flight action can be cancelled the moment the
/// screen locks, and cached UI state can be invalidated once the user is back.
///
/// Mirrors Codex's `SystemLockScreenMonitor`: it reads `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`
/// for the initial value, then follows the distributed notifications `com.apple.screenIsLocked` /
/// `com.apple.screenIsUnlocked` (screen saver lock, Cmd-Ctrl-Q, lid close with a password) and NSWorkspace's
/// `sessionDidResignActive` / `sessionDidBecomeActive` (fast user switching, where our session leaves the console
/// entirely). Both sources collapse into one boolean; callbacks only fire on a real transition, so a lock that is
/// reported by both channels still produces a single `onLock`.
///
/// Integration (wired by the daemon, not by this file):
///
///     // in Daemon.start(), after StatusUI / CursorOverlay are configured:
///     LockScreenMonitor.shared.onLock = {
///         Daemon.shared.cancelNow(reason: .screenLocked, message: "the screen was locked")
///         CursorOverlay.shared.hideNow()          // callbacks already run on the main thread
///         StatusUI.shared.setActive(app: nil)     // drops the "Wisp is controlling …" banner
///     }
///     LockScreenMonitor.shared.onUnlock = {
///         // Windows may have moved, closed or re-rendered behind the lock screen: forget every cached revision so
///         // the next `state` call returns a full tree instead of a diff against a stale one.
///         Task { await Daemon.shared.resetAllRevisions() }   // for s in sessions.values { s.revisions.reset() }
///     }
///     LockScreenMonitor.shared.start()
///
/// `checkScreenLock()` in `Daemon.swift` remains the synchronous pre-action guard (it throws `screenLocked` before
/// any event is posted); this monitor covers the window *during* an action, where the guard has already passed.
/// Actions may also consult `LockScreenMonitor.shared.isLocked` from any thread instead of re-reading the CG
/// session dictionary.
final class LockScreenMonitor {
    static let shared = LockScreenMonitor()

    /// Called on the main thread when the session transitions from unlocked to locked.
    var onLock: (() -> Void)?
    /// Called on the main thread when the session transitions from locked to unlocked.
    var onUnlock: (() -> Void)?

    private let lock = NSLock()
    private var locked = false
    private var started = false
    private var distributedTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    private static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private init() {}

    /// Current lock state as last observed. Safe to read from any thread.
    var isLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return locked
    }

    /// Synchronous query of the CG session: `true` when the login window / screen lock is up for this session.
    /// Cheap enough to call before every action; `nil` dictionaries (no console session) read as unlocked, matching
    /// the pre-existing `checkScreenLock()` guard.
    static func currentlyLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Begins observing. Idempotent: a second call is a no-op. Seeds `isLocked` from the CG session so a daemon
    /// that starts while the screen is already locked reports the right value before any notification arrives.
    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        locked = Self.currentlyLocked()
        let initial = locked
        lock.unlock()

        let dnc = DistributedNotificationCenter.default()
        distributedTokens = [
            dnc.addObserver(forName: Self.lockedNotification, object: nil, queue: .main) { [weak self] _ in
                self?.transition(to: true, source: "screenIsLocked")
            },
            dnc.addObserver(forName: Self.unlockedNotification, object: nil, queue: .main) { [weak self] _ in
                self?.transition(to: false, source: "screenIsUnlocked")
            },
        ]
        let wnc = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            wnc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // Fast user switching: another user owns the console, our windows are not reachable.
                self?.transition(to: true, source: "sessionDidResignActive")
            },
            wnc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // Back on the console. The screen can still be locked (switched back to the lock screen), so trust
                // the CG session dictionary rather than assuming unlocked.
                self?.transition(to: Self.currentlyLocked(), source: "sessionDidBecomeActive")
            },
        ]
        Log.info("lock-screen monitor started; locked=\(initial)")
    }

    /// Stops observing. `isLocked` keeps its last value; `start()` may be called again later.
    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        let dnc = DistributedNotificationCenter.default()
        for t in distributedTokens { dnc.removeObserver(t) }
        distributedTokens.removeAll()
        let wnc = NSWorkspace.shared.notificationCenter
        for t in workspaceTokens { wnc.removeObserver(t) }
        workspaceTokens.removeAll()
        Log.info("lock-screen monitor stopped")
    }

    /// Applies a new state and fires the matching callback only when the state actually changed. Always runs on the
    /// main thread (observers are registered on `.main`), so callbacks may touch AppKit directly.
    private func transition(to newValue: Bool, source: String) {
        lock.lock()
        let changed = locked != newValue
        locked = newValue
        lock.unlock()
        guard changed else { return }
        Log.info("screen \(newValue ? "locked" : "unlocked") (\(source))")
        if newValue { onLock?() } else { onUnlock?() }
    }
}
