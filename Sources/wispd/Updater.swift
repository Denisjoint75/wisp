import AppKit
import Sparkle
import WispCore

/// Sparkle-based self updates. Active only when running from the packaged Wisp.app (feed URL and public key in Info.plist).
@MainActor
final class UpdaterHost: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterHost()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleIdentifier != nil, let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else {
            Log.info("Sparkle: not running from a packaged bundle; updater disabled")
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        c.startUpdater()
        controller = c
        Log.info("Sparkle: updater started, feed \(feed)")
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("Sparkle: update available \(item.displayVersionString)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info("Sparkle: no update")
    }
}
