import CryptoKit
import Foundation

/// The Wisp Chrome extension (`integrations/chrome-extension`) and its native messaging host (`wisp native-host`).
/// The extension lets Wisp drive the tabs of the user's own browser; the daemon side lives in `wispd`
/// (`ExtensionBridge`), the setup command in the CLI (`wisp chrome extension install`).
public enum ChromeExtension {
    /// Extension id, derived from the `key` pinned in the extension's manifest.json (see `id(forKey:)`).
    public static let id = "onbeniodfnedfepagelnhdlahohkcnll"
    /// Native messaging host name: the browser looks up `<hostName>.json` in its NativeMessagingHosts directory.
    public static let hostName = "sb.moe.wisp"
    public static var origin: String { "chrome-extension://\(id)/" }

    /// A Chromium-based browser and where it keeps native messaging host manifests.
    public struct Browser: Equatable {
        public let key: String
        public let name: String
        public let supportDir: String
        public let bundleId: String

        public init(key: String, name: String, supportDir: String, bundleId: String) {
            self.key = key
            self.name = name
            self.supportDir = supportDir
            self.bundleId = bundleId
        }

        /// `~/Library/Application Support/<supportDir>/NativeMessagingHosts/sb.moe.wisp.json`
        public func hostManifestURL(home: URL = WispPaths.home) -> URL {
            home.appendingPathComponent("Library/Application Support/\(supportDir)/NativeMessagingHosts/\(ChromeExtension.hostName).json")
        }

        /// Whether the browser has a profile directory on this Mac (it has been run at least once).
        public func isPresent(home: URL = WispPaths.home) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/\(supportDir)").path)
        }
    }

    public static let browsers: [Browser] = [
        Browser(key: "chrome", name: "Google Chrome", supportDir: "Google/Chrome", bundleId: "com.google.Chrome"),
        Browser(key: "chrome-beta", name: "Google Chrome Beta", supportDir: "Google/Chrome Beta", bundleId: "com.google.Chrome.beta"),
        Browser(key: "chrome-canary", name: "Google Chrome Canary", supportDir: "Google/Chrome Canary", bundleId: "com.google.Chrome.canary"),
        Browser(key: "chromium", name: "Chromium", supportDir: "Chromium", bundleId: "org.chromium.Chromium"),
        Browser(key: "brave", name: "Brave", supportDir: "BraveSoftware/Brave-Browser", bundleId: "com.brave.Browser"),
        Browser(key: "edge", name: "Microsoft Edge", supportDir: "Microsoft Edge", bundleId: "com.microsoft.edgemac"),
        Browser(key: "arc", name: "Arc", supportDir: "Arc/User Data", bundleId: "company.thebrowser.Browser"),
        Browser(key: "vivaldi", name: "Vivaldi", supportDir: "Vivaldi", bundleId: "com.vivaldi.Vivaldi"),
    ]

    public static func browser(_ key: String) -> Browser? {
        browsers.first { $0.key == key.lowercased() }
    }

    /// The manifest the browser reads to start the host: `wisp native-host`, allowed for the Wisp extension only.
    public static func hostManifest(binary: String) -> JSON {
        ["name": .string(hostName), "description": "Wisp native messaging host (wisp native-host)",
         "path": .string(binary), "type": "stdio", "allowed_origins": .array([.string(origin)])]
    }

    /// Chrome's extension id for a manifest `key`: the first 32 hex digits of the SHA-256 of the DER public key,
    /// each digit mapped to a letter a-p.
    public static func id(forKey base64: String) -> String? {
        guard let der = Data(base64Encoded: base64) else { return nil }
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined().prefix(32)
        return String(hex.map { Character(UnicodeScalar(UInt8(ascii: "a") + UInt8($0.hexDigitValue ?? 0))) })
    }

    /// Where `wisp chrome extension install` copies the extension for "Load unpacked".
    public static var installDir: URL { WispPaths.supportDir.appendingPathComponent("chrome-extension", isDirectory: true) }

    /// The extension shipped with this build: `WISP_EXTENSION_DIR`, `Wisp.app/Contents/Resources/chrome-extension`
    /// next to the running CLI, or `integrations/chrome-extension` in a source checkout.
    public static func bundledDir(executable: String? = nil, cwd: String = FileManager.default.currentDirectoryPath) -> URL? {
        let fm = FileManager.default
        func has(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("manifest.json").path) }
        if let p = ProcessInfo.processInfo.environment["WISP_EXTENSION_DIR"], has(URL(fileURLWithPath: p)) { return URL(fileURLWithPath: p) }
        let exe = (executable.map { URL(fileURLWithPath: $0) } ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        var candidates = [
            dir.deletingLastPathComponent().appendingPathComponent("Resources/chrome-extension"),
            dir.appendingPathComponent("Wisp.app/Contents/Resources/chrome-extension"),
            URL(fileURLWithPath: "/Applications/Wisp.app/Contents/Resources/chrome-extension"),
            URL(fileURLWithPath: cwd).appendingPathComponent("integrations/chrome-extension"),
        ]
        var up = dir
        for _ in 0..<4 {
            up = up.deletingLastPathComponent()
            candidates.append(up.appendingPathComponent("integrations/chrome-extension"))
        }
        return candidates.first(where: has)
    }
}
