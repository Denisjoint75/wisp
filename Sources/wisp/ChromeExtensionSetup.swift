import Foundation
import WispCore

/// `wisp chrome extension install|status|path`: copies the bundled extension where the browser can load it and
/// registers the native messaging host manifest(s) that let the extension start `wisp native-host`.
enum ChromeExtensionSetup {
    /// The absolute path of the running `wisp` (symlinks resolved), which the host manifest points at.
    static var binaryPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    static func selectBrowsers(_ keys: [String]) throws -> [ChromeExtension.Browser] {
        if keys.isEmpty { return ChromeExtension.browsers.filter { $0.key == "chrome" || $0.isPresent() } }
        if keys.contains("all") { return ChromeExtension.browsers }
        return try keys.map { k in
            guard let b = ChromeExtension.browser(k) else {
                throw WispError(.invalidParams, "unknown browser `\(k)`; one of \(ChromeExtension.browsers.map { $0.key }.joined(separator: ", ")), all")
            }
            return b
        }
    }

    static func install(browsers keys: [String], open: Bool) throws -> JSON {
        guard let src = ChromeExtension.bundledDir() else {
            throw WispError(.internalError, "cannot find the bundled extension (Wisp.app/Contents/Resources/chrome-extension or integrations/chrome-extension)")
        }
        let fm = FileManager.default
        let dst = ChromeExtension.installDir
        if src.standardizedFileURL.path != dst.standardizedFileURL.path {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        let binary = binaryPath
        var hosts: [JSON] = []
        for b in try selectBrowsers(keys) {
            let url = b.hostManifestURL()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((ChromeExtension.hostManifest(binary: binary).stringified(pretty: true) + "\n").utf8).write(to: url)
            hosts.append(["browser": .string(b.name), "key": .string(b.key), "bundleId": .string(b.bundleId), "path": .string(url.path)])
        }
        var opened = false
        if open, let first = hosts.first, let bid = first["bundleId"].string {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-b", bid, "chrome://extensions"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit(); opened = p.terminationStatus == 0 }
        }
        return ["dir": .string(dst.path), "binary": .string(binary), "id": .string(ChromeExtension.id), "hosts": .array(hosts), "opened": .bool(opened)]
    }

    /// What is installed on disk plus, when the daemon runs, whether the extension is connected.
    static func status(client: WispClient?) -> JSON {
        let fm = FileManager.default
        let dir = ChromeExtension.installDir
        let manifestVersion = (fm.contents(atPath: dir.appendingPathComponent("manifest.json").path)).flatMap { try? JSON.parse($0) }?["version"].string
        let hosts: [JSON] = ChromeExtension.browsers.compactMap { b in
            let url = b.hostManifestURL()
            guard fm.fileExists(atPath: url.path) else { return nil }
            let m = fm.contents(atPath: url.path).flatMap { try? JSON.parse($0) }
            let ok = m?["allowed_origins"].array?.contains { $0.string == ChromeExtension.origin } == true && fm.isExecutableFile(atPath: m?["path"].string ?? "")
            return ["browser": .string(b.name), "key": .string(b.key), "path": .string(url.path), "binary": m?["path"] ?? .null, "valid": .bool(ok)]
        }
        var out: [String: JSON] = ["id": .string(ChromeExtension.id), "dir": .string(dir.path), "installed": .bool(manifestVersion != nil),
                                   "version": manifestVersion.map { .string($0) } ?? .null, "hosts": .array(hosts), "bundled": ChromeExtension.bundledDir().map { .string($0.path) } ?? .null]
        if let c = client, let s = try? c.call(Proto.Method.chromeStatus, [:], timeout: 20) { out["bridge"] = s["extension"] } else { out["bridge"] = .null }
        return .object(out)
    }

    static func describe(_ r: JSON) -> String {
        var lines: [String] = []
        let hosts = r["hosts"].array ?? []
        lines.append("extension: \(r["installed"].bool == true ? "copied to \(r["dir"].string ?? "") (version \(r["version"].string ?? "?"))" : "not installed (run `wisp chrome extension install`)")")
        if hosts.isEmpty { lines.append("native messaging host: not registered for any browser") }
        for h in hosts { lines.append("native messaging host: \(h["browser"].string ?? "")  \(h["valid"].bool == true ? "ok" : "INVALID (re-run install)")  \(h["path"].string ?? "")") }
        let b = r["bridge"]
        if b.isNull { lines.append("bridge: wispd not running") }
        else if b["connected"].bool == true {
            let br = b["browser"]
            lines.append("bridge: connected (\(br["name"].string ?? "browser") \(br["version"].string ?? ""), extension \(b["extensionVersion"].string ?? "?"), \(b["attachedTabs"].int ?? 0) tab(s) attached)")
        } else {
            lines.append("bridge: not connected (load the extension from \(r["dir"].string ?? "the install directory") on chrome://extensions with Developer mode on, then click its icon)")
        }
        return lines.joined(separator: "\n")
    }
}
