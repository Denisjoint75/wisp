import AppKit
import CoreServices
import WispCore

struct AppInfo {
    var bundleId: String?
    /// `CFBundleName` from the bundle's Info.plist (an instruction-catalog candidate); nil when unknown.
    var bundleName: String? = nil
    var name: String
    var path: String?
    var pid: pid_t?
    var isRunning: Bool
    var lastUsed: Date?
    var useCount: Int?
    /// True when the app registers the `http` URL scheme or is a known browser (`InstructionCatalog.isWebBrowser`).
    var isBrowser: Bool = false

    var json: JSON {
        [String: JSON].compact([
            ("id", .string(bundleId ?? path ?? name)), ("bundleId", bundleId.map { .string($0) }), ("name", .string(name)),
            ("path", path.map { .string($0) }), ("pid", pid.map { .int(Int($0)) }), ("running", .bool(isRunning)),
            ("lastUsed", lastUsed.map { .string(ISO8601DateFormatter().string(from: $0)) }), ("useCount", useCount.map { .int($0) }),
        ])
    }
}

struct WindowInfo {
    var id: CGWindowID?
    var title: String?
    var frame: CGRect
    var isMain: Bool
    var isFocused: Bool
    var isMinimized: Bool
    var subrole: String?
    var element: AXEl

    var json: JSON {
        [String: JSON].compact([
            ("id", id.map { .int(Int($0)) }), ("title", title.map { .string($0) }), ("frame", frame.uiRect.json),
            ("main", .bool(isMain)), ("focused", .bool(isFocused)), ("minimized", .bool(isMinimized)),
            ("subrole", subrole.map { .string($0) }),
        ])
    }
}

enum AppResolver {
    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    static func info(for app: NSRunningApplication) -> AppInfo {
        let meta = bundleMeta(for: app.bundleURL, bundleId: app.bundleIdentifier)
        return AppInfo(bundleId: app.bundleIdentifier, bundleName: meta.bundleName,
                       name: app.localizedName ?? app.bundleIdentifier ?? "app \(app.processIdentifier)",
                       path: app.bundleURL?.path, pid: app.processIdentifier, isRunning: true, lastUsed: nil, useCount: nil,
                       isBrowser: meta.isBrowser)
    }

    /// URL schemes an app bundle registers (`CFBundleURLTypes` / `CFBundleURLSchemes` in its Info.plist).
    static func urlSchemes(for bundleURL: URL?) -> [String] {
        guard let url = bundleURL, let types = Bundle(url: url)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    struct BundleMeta { var bundleName: String?; var isBrowser: Bool }

    private static let metaLock = NSLock()
    private static var metaCache: [String: BundleMeta] = [:]

    /// Reads `CFBundleName` and the browser flag from a bundle's Info.plist once per bundle path. The dictionary
    /// itself is not kept: it is large and only these two facts are needed.
    static func bundleMeta(for bundleURL: URL?, bundleId: String?) -> BundleMeta {
        guard let url = bundleURL else { return BundleMeta(bundleName: nil, isBrowser: InstructionCatalog.isWebBrowser(infoDictionary: nil, bundleId: bundleId)) }
        metaLock.lock(); defer { metaLock.unlock() }
        if let cached = metaCache[url.path] { return cached }
        let info = Bundle(url: url)?.infoDictionary
        let meta = BundleMeta(bundleName: info?["CFBundleName"] as? String,
                              isBrowser: InstructionCatalog.isWebBrowser(infoDictionary: info, bundleId: bundleId ?? Bundle(url: url)?.bundleIdentifier))
        metaCache[url.path] = meta
        return meta
    }

    /// Finds a running application by bundle id, name, or path. Throws `ambiguousApp` for several distinct matches.
    static func findRunning(_ spec: String) throws -> NSRunningApplication? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let apps = runningApps()
        if let pid = Int32(s), let a = apps.first(where: { $0.processIdentifier == pid }) { return a }
        if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == lower }) { return a }
        if s.hasPrefix("/"), let a = apps.first(where: { $0.bundleURL?.path == s || $0.bundleURL?.path.hasPrefix(s) == true }) { return a }
        let byName = apps.filter { ($0.localizedName ?? "").lowercased() == lower || $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == lower }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            let ids = Set(byName.compactMap { $0.bundleIdentifier })
            if ids.count == 1 { return byName[0] }
            throw WispError(.ambiguousApp, "several running apps match `\(spec)`", data: .array(byName.map { info(for: $0).json }))
        }
        let prefix = apps.filter { ($0.localizedName ?? "").lowercased().hasPrefix(lower) || ($0.bundleIdentifier ?? "").lowercased().hasSuffix("." + lower) }
        if prefix.count == 1 { return prefix[0] }
        if prefix.count > 1 {
            throw WispError(.ambiguousApp, "several running apps match `\(spec)`", data: .array(prefix.map { info(for: $0).json }))
        }
        return nil
    }

    /// Finds an installed application bundle URL for a spec.
    static func findInstalled(_ spec: String) throws -> URL? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/") {
            let u = URL(fileURLWithPath: s)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s) { return u }
        let lower = s.lowercased()
        // Spotlight lookup by display name / file name.
        let query = "(kMDItemContentType == \"com.apple.application-bundle\") && ((kMDItemDisplayName == \"\(s)*\"cd) || (kMDItemFSName == \"\(s)*.app\"cd))"
        let results = mdQuery(query, limit: 50)
        var exact: [URL] = []
        var partial: [URL] = []
        for r in results {
            let name = r.url.deletingPathExtension().lastPathComponent.lowercased()
            if name == lower || (r.displayName ?? "").lowercased() == lower { exact.append(r.url) } else { partial.append(r.url) }
        }
        if let e = exact.first { return e }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw WispError(.ambiguousApp, "several installed apps match `\(spec)`", data: .array(partial.map { .string($0.path) }))
        }
        return nil
    }

    struct MDResult { var url: URL; var displayName: String?; var lastUsed: Date?; var useCount: Int? }

    static func mdQuery(_ query: String, limit: Int) -> [MDResult] {
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(q, limit)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var out: [MDResult] = []
        let n = MDQueryGetResultCount(q)
        for i in 0..<n {
            let item = unsafeBitCast(MDQueryGetResultAtIndex(q, i), to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String
            let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            let uc = (MDItemCopyAttribute(item, ("kMDItemUseCount" as CFString)) as? NSNumber)?.intValue
            out.append(MDResult(url: URL(fileURLWithPath: path), displayName: name, lastUsed: last, useCount: uc))
        }
        return out
    }

    /// Running apps plus apps used in the last 14 days (Spotlight), like Sky's `list_apps`.
    static func listApps(runningOnly: Bool) -> [AppInfo] {
        var byKey: [String: AppInfo] = [:]
        var order: [String] = []
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windowOwners = Set(cgList.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        for a in runningApps() {
            var i = info(for: a)
            let key = a.bundleIdentifier ?? a.bundleURL?.path ?? i.name
            if let p = a.bundleURL?.path, let item = MDItemCreate(kCFAllocatorDefault, p as CFString) {
                i.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                i.useCount = (MDItemCopyAttribute(item, ("kMDItemUseCount" as CFString)) as? NSNumber)?.intValue
            }
            // Multi-process apps (Chrome, Electron) register several NSRunningApplication entries under one bundle
            // id: keep one row per app, preferring the process that actually owns windows.
            if let existing = byKey[key] {
                let existingHasWindows = existing.pid.map { windowOwners.contains($0) } ?? false
                let newHasWindows = windowOwners.contains(a.processIdentifier)
                if newHasWindows && !existingHasWindows { byKey[key] = i }
                continue
            }
            byKey[key] = i
            order.append(key)
        }
        if !runningOnly {
            let q = "(kMDItemContentType == \"com.apple.application-bundle\") && (kMDItemLastUsedDate >= $time.today(-14))"
            for r in mdQuery(q, limit: 300) {
                let bundle = Bundle(url: r.url)
                let bid = bundle?.bundleIdentifier
                let key = bid ?? r.url.path
                if byKey[key] != nil { continue }
                let name = r.displayName?.replacingOccurrences(of: ".app", with: "") ?? r.url.deletingPathExtension().lastPathComponent
                byKey[key] = AppInfo(bundleId: bid, name: name, path: r.url.path, pid: nil, isRunning: false, lastUsed: r.lastUsed, useCount: r.useCount)
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.sorted { (a, b) in
            if a.isRunning != b.isRunning { return a.isRunning }
            return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
        }
    }

    /// Launches an app bundle and waits until it is running.
    static func launch(url: URL, activate: Bool) async throws -> NSRunningApplication {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        cfg.addsToRecentItems = false
        cfg.promptsUserIfNeeded = false
        return try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
                if let app = app { cont.resume(returning: app) }
                else { cont.resume(throwing: WispError(.launchFailed, "could not launch \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown error)")")) }
            }
        }
    }

    struct WindowHit { var id: CGWindowID; var pid: pid_t; var owner: String }

    /// Resolves which window a synthesized pointer event at `p` should target for a session on `pid`.
    /// Walks the on-screen window list front to back and returns the first window that is either owned by the target
    /// app (its main window, popups, menus, sheets) or an out-of-process panel drawn on its behalf (Open/Save panels
    /// live in `com.apple.appkit.xpc.openAndSavePanelService`, other remote views in ViewBridge services).
    /// Unrelated windows stacked above the target (an app the user is working in, the Dock's full-screen backstop,
    /// the menu bar, overlays) are skipped: events are addressed to the target window itself, so they keep landing
    /// there without hijacking the user's pointer or requiring the window to be frontmost.
    static func pointerTarget(at p: CGPoint, pid: pid_t) -> WindowHit? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = getpid()
        for c in list {
            guard let owner = c[kCGWindowOwnerPID as String] as? Int32, owner != me, let b = c[kCGWindowBounds as String] as? [String: Double] else { continue }
            let alpha = (c[kCGWindowAlpha as String] as? Double) ?? 1
            if alpha < 0.05 { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.contains(p), let id = c[kCGWindowNumber as String] as? UInt32 else { continue }
            let name = (c[kCGWindowOwnerName as String] as? String) ?? ""
            if owner == pid { return WindowHit(id: id, pid: owner, owner: name) }
            let layer = (c[kCGWindowLayer as String] as? Int) ?? 0
            if (0...8).contains(layer), isPanelHelper(pid: owner) { return WindowHit(id: id, pid: owner, owner: name) }
        }
        return nil
    }

    private static let helperLock = NSLock()
    private static var helperCache: [pid_t: Bool] = [:]

    /// True for AppKit XPC services that draw panels on behalf of other apps (open/save panels, remote views).
    static func isPanelHelper(pid: pid_t) -> Bool {
        helperLock.lock(); defer { helperLock.unlock() }
        if let cached = helperCache[pid] { return cached }
        var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = n > 0 ? String(cString: buf) : ""
        let helper = path.contains(".xpc/Contents/MacOS/") && (path.contains("com.apple.appkit.xpc.") || path.contains("ViewBridge"))
        helperCache[pid] = helper
        return helper
    }

    /// Lists AX windows of an app with CGWindow ids resolved by frame/title matching.
    static func windows(of app: NSRunningApplication) -> [WindowInfo] {
        let ax = AXEl.app(pid: app.processIdentifier)
        let axWindows = ax.windows
        let focused = ax.focusedWindow
        let main = ax.mainWindow
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = cgList.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0 }
        var out: [WindowInfo] = []
        for w in axWindows {
            let v = w.values([kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXSubroleAttribute])
            guard let p = v[kAXPositionAttribute] as? CGPoint, let s = v[kAXSizeAttribute] as? CGSize else { continue }
            let frame = CGRect(origin: p, size: s)
            let title = v[kAXTitleAttribute] as? String
            var id: CGWindowID? = nil
            var best = Double.greatestFiniteMagnitude
            for c in mine {
                guard let b = c[kCGWindowBounds as String] as? [String: Double] else { continue }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                let d = abs(r.origin.x - frame.origin.x) + abs(r.origin.y - frame.origin.y) + abs(r.width - frame.width) + abs(r.height - frame.height)
                let nameMatch = (c[kCGWindowName as String] as? String) == title
                let score = d - (nameMatch ? 1 : 0)
                if d < 8, score < best { best = score; id = (c[kCGWindowNumber as String] as? UInt32) }
            }
            out.append(WindowInfo(id: id, title: title, frame: frame, isMain: main == w, isFocused: focused == w,
                                  isMinimized: (v[kAXMinimizedAttribute] as? Bool) ?? false, subrole: v[kAXSubroleAttribute] as? String, element: w))
        }
        return out
    }
}
