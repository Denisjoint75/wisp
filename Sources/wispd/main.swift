import AppKit
import ApplicationServices
import WispCore

let args = CommandLine.arguments.dropFirst()
if args.contains("--version") { print("wispd \(WispVersion.string) (\(WispVersion.build))"); exit(0) }
if args.contains("--verbose") { Log.verbose = true }
if args.contains("--check") {
    let j: JSON = ["accessibility": .bool(AXIsProcessTrusted()), "screenRecording": .bool(ScreenshotService.hasPermission)]
    print(j.stringified())
    exit(0)
}
if args.contains("--request-permissions") {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    _ = ScreenshotService.requestPermission()
    print("requested; check System Settings > Privacy & Security")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in Daemon.shared.shutdown() }
signal(SIGINT) { _ in Daemon.shared.shutdown() }

let server = SocketServer(path: WispPaths.socketPath)
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("wispd: \(error)\n".utf8))
    exit(1)
}

Task { await Daemon.shared.start() }
app.run()
