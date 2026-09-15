import AppKit
import Foundation
import WispCore

/// Minimal Chrome DevTools Protocol client over `URLSessionWebSocketTask`.
final class CDPConnection: CDPTransport {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private let lock = NSLock()
    private(set) var isClosed = false
    var onEvent: ((String, JSON) -> Void)?

    init(url: URL) { self.url = url }

    func connect() async throws {
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 64 * 1024 * 1024
        t.resume()
        task = t
        receiveLoop()
        // Probe the connection with a cheap command.
        _ = try await call("Runtime.evaluate", ["expression": "1"], timeout: 8)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.fail(err)
            case .success(let msg):
                var data: Data?
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: break
                }
                if let d = data, let j = try? JSON.parse(d) { self.handle(j) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ j: JSON) {
        if let id = j["id"].int {
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            if let c = c {
                if !j["error"].isNull {
                    let msg = j["error"]["message"].string ?? "CDP error"
                    c.resume(throwing: WispError(.internalError, "CDP: \(msg)", data: j["error"]))
                } else {
                    c.resume(returning: j["result"])
                }
            }
        } else if let method = j["method"].string {
            onEvent?(method, j["params"])
        }
    }

    private func fail(_ err: Error) {
        lock.lock()
        isClosed = true
        let all = pending
        pending = [:]
        lock.unlock()
        for (_, c) in all { c.resume(throwing: WispError(.notConnected, "CDP connection closed: \(err.localizedDescription)")) }
    }

    private func allocateId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func register(_ id: Int, _ c: CheckedContinuation<JSON, Error>) {
        lock.lock(); pending[id] = c; lock.unlock()
    }

    private func takePending(_ id: Int) -> CheckedContinuation<JSON, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    func call(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        guard let task = task, !isClosed else { throw WispError(.notConnected, "CDP connection is closed") }
        let id = allocateId()
        let msg = JSON.object(["id": .int(id), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            register(id, c)
            task.send(.string(msg.stringified())) { [weak self] err in
                if let err = err, let self = self {
                    self.takePending(id)?.resume(throwing: WispError(.notConnected, "CDP send failed: \(err.localizedDescription)"))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.takePending(id)?.resume(throwing: WispError(.timeout, "CDP \(method) timed out after \(Int(timeout))s"))
            }
        }
    }

    func close() {
        isClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
    }
}

struct ChromeTabInfo {
    /// Which browser owns the tab: the separate Wisp Chrome (DevTools port) or the user's own browser (extension).
    enum Browser: String { case wisp, user }

    var id: String
    var title: String
    var url: String
    var wsURL: String?
    var type: String
    /// Set for tabs the agent opened: `agent` (unmarked scratch tab), `deliverable` or `handoff`.
    var mark: String?
    var browser: Browser = .wisp
    /// The active tab of its window (user tabs only).
    var active: Bool? = nil

    /// The `chrome.tabs` id for a user tab.
    var extensionTabId: Int? { browser == .user ? Int(id) : nil }

    var json: JSON {
        [String: JSON].compact([("id", .string(id)), ("title", .string(title)), ("url", .string(url)), ("type", .string(type)),
                                ("mark", mark.map { .string($0) }), ("browser", .string(browser.rawValue)), ("active", active.map { .bool($0) })])
    }
}

/// Talks to a Chrome instance started with `--remote-debugging-port`.
final class ChromeBackend {
    /// Turn-scoped label on a tab the agent opened. Unmarked (`none`) tabs are scratch and closed by `endTurn()`;
    /// `deliverable` and `handoff` tabs survive the turn. The label shown in tab lists is `agent` for `none`.
    enum Mark: String { case none, deliverable, handoff
        var label: String { self == .none ? "agent" : rawValue }
    }

    var port: Int {
        didSet { ChromeBackend.persist(port: port) }
    }
    private var tabs: [String: ChromeTab] = [:]
    private var host: String?
    /// Ids of the user's tabs (through the extension) seen by the last `listTabs`; they are `chrome.tabs` ids.
    private var userTabIds = Set<String>()
    /// Tabs created through Wisp (`newTab`, `launch(url:)`) and their marks for the current turn.
    private(set) var agentTabs: [String: Mark] = [:]
    private var appCache: NSRunningApplication?

    static var stateFile: URL { WispPaths.supportDir.appendingPathComponent("chrome.json") }

    init(port: Int) {
        if let d = FileManager.default.contents(atPath: ChromeBackend.stateFile.path), let j = try? JSON.parse(d), let p = j["port"].int {
            self.port = p
        } else {
            self.port = port
        }
    }

    static func persist(port: Int) {
        try? JSON.object(["port": .int(port)]).data().write(to: stateFile)
    }

    /// Chrome may bind IPv4 or IPv6 loopback depending on what is free; try both.
    private func http(_ path: String, method: String = "GET") async throws -> JSON {
        let hosts = host.map { [$0] } ?? ["127.0.0.1", "[::1]"]
        var lastError: Error?
        for h in hosts {
            var req = URLRequest(url: URL(string: "http://\(h):\(port)\(path)")!)
            req.httpMethod = method
            req.timeoutInterval = 5
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { lastError = WispError(.chromeUnavailable, "HTTP \(http.statusCode)"); continue }
                if data.isEmpty, path.hasPrefix("/json/version") || path.hasPrefix("/json/list") { lastError = WispError(.chromeUnavailable, "empty reply"); continue }
                host = h
                if data.isEmpty { return .null }
                return (try? JSON.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
            } catch {
                lastError = error
            }
        }
        _ = lastError
        throw WispError(.chromeUnavailable, "Chrome DevTools is not reachable on port \(port). Start it with `wisp chrome launch` (uses --remote-debugging-port and a dedicated profile).")
    }

    /// Finds a free loopback port starting at `preferred`.
    static func freePort(preferred: Int) -> Int {
        func isFree(_ p: Int) -> Bool {
            for family in [AF_INET, AF_INET6] {
                let s = socket(family, SOCK_STREAM, 0)
                if s < 0 { continue }
                defer { close(s) }
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                var ok = false
                if family == AF_INET {
                    var a = sockaddr_in()
                    a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(p).bigEndian); a.sin_addr.s_addr = inet_addr("127.0.0.1")
                    ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
                } else {
                    var a = sockaddr_in6()
                    a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = in_port_t(UInt16(p).bigEndian); a.sin6_addr = in6addr_loopback
                    ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
                }
                if !ok { return false }
            }
            return true
        }
        var p = preferred
        while p < preferred + 200 { if isFree(p) { return p }; p += 1 }
        return preferred
    }

    func version() async throws -> JSON { try await http("/json/version") }

    /// Tabs of the user's browser (through the extension, listed first: the active tab of the focused window, then
    /// the rest) followed by the Wisp Chrome's tabs. With the extension connected, `active` therefore means the tab
    /// the user is looking at.
    func listTabs() async throws -> [ChromeTabInfo] {
        var list: [ChromeTabInfo] = []
        var userIds = Set<String>()
        if ExtensionBridge.shared.isConnected, let r = try? await ExtensionBridge.shared.request("tabs", timeout: 8) {
            for t in r["tabs"].array ?? [] {
                guard let id = t["id"].int else { continue }
                let sid = String(id)
                userIds.insert(sid)
                list.append(ChromeTabInfo(id: sid, title: t["title"].string ?? "", url: t["url"].string ?? "", wsURL: nil, type: "page",
                                          mark: agentTabs[sid]?.label, browser: .user, active: t["active"].bool))
            }
        }
        userTabIds = userIds
        do {
            list += try await devToolsTabs()
        } catch {
            // No Wisp Chrome running: fine as long as the extension answered.
            if list.isEmpty { throw error }
        }
        // Tabs the user closed by hand are gone for good; forget their marks.
        let open = Set(list.map { $0.id })
        agentTabs = agentTabs.filter { open.contains($0.key) }
        return list
    }

    private func devToolsTabs() async throws -> [ChromeTabInfo] {
        let j = try await http("/json/list")
        return (j.array ?? []).compactMap { t -> ChromeTabInfo? in
            guard let id = t["id"].string else { return nil }
            return ChromeTabInfo(id: id, title: t["title"].string ?? "", url: t["url"].string ?? "", wsURL: t["webSocketDebuggerUrl"].string,
                                 type: t["type"].string ?? "", mark: agentTabs[id]?.label)
        }.filter { $0.type == "page" }
    }

    private func isUserTab(_ id: String) -> Bool { userTabIds.contains(id) || tabs[id]?.info.browser == .user }

    /// `wisp chrome new example.com` means https; `about:`, `chrome:`, `file:` and friends pass through.
    static func normalizedURL(_ u: String) -> String {
        if u.contains("://") || u.hasPrefix("about:") || u.hasPrefix("chrome:") || u.hasPrefix("data:") || u.hasPrefix("javascript:") { return u }
        return "https://" + u
    }

    /// Opens a tab: in the user's browser when the extension is connected (or `browser == .user`), else in the
    /// Wisp Chrome. Either way it is an agent tab for this turn.
    func newTab(url: String?, browser: ChromeTabInfo.Browser? = nil) async throws -> ChromeTabInfo {
        let where_ = browser ?? (ExtensionBridge.shared.isConnected ? .user : .wisp)
        if where_ == .user {
            var p: [String: JSON] = ["active": true]
            if let u = url { p["url"] = .string(ChromeBackend.normalizedURL(u)) }
            let r = try await ExtensionBridge.shared.request("new", .object(p), timeout: 15)
            guard let id = r["id"].int else { throw WispError(.chromeUnavailable, "the Chrome extension did not create a tab: \(r.stringified())") }
            let sid = String(id)
            agentTabs[sid] = Mark.none
            userTabIds.insert(sid)
            return ChromeTabInfo(id: sid, title: r["title"].string ?? "", url: r["url"].string ?? url ?? "", wsURL: nil, type: "page",
                                 mark: Mark.none.label, browser: .user, active: true)
        }
        let target = url.map { "?" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
        let j = try await http("/json/new" + target, method: "PUT")
        guard let id = j["id"].string else { throw WispError(.chromeUnavailable, "Chrome did not create a tab: \(j.stringified())") }
        agentTabs[id] = Mark.none
        return ChromeTabInfo(id: id, title: j["title"].string ?? "", url: j["url"].string ?? "", wsURL: j["webSocketDebuggerUrl"].string, type: "page", mark: Mark.none.label)
    }

    func closeTab(id: String) async throws {
        if isUserTab(id), let n = Int(id) {
            // Forget the transport first: the extension's `tabRemoved` would only close it anyway.
            tabs.removeValue(forKey: id)?.close()
            _ = try await ExtensionBridge.shared.request("close", ["tabId": .int(n)], timeout: 10)
        } else {
            _ = try await http("/json/close/\(id)")
            tabs.removeValue(forKey: id)?.close()
        }
        agentTabs.removeValue(forKey: id)
    }

    /// Makes a tab the active one of its window. `focusWindow` also brings that window (and the browser) forward,
    /// which only `wisp chrome show` asks for; actions never steal focus.
    func activateTab(id: String, focusWindow: Bool = false) async throws {
        if isUserTab(id), let n = Int(id) {
            _ = try await ExtensionBridge.shared.request("activate", ["tabId": .int(n), "focusWindow": .bool(focusWindow)], timeout: 10)
            return
        }
        _ = try await http("/json/activate/\(id)")
    }

    /// Registers tabs Chrome itself opened at launch as agent tabs.
    func registerAgentTabs(_ ids: [String]) { for id in ids where agentTabs[id] == nil { agentTabs[id] = Mark.none } }

    /// Labels an agent tab for this turn; a tab the user opened becomes an agent tab once it is marked.
    func mark(tab id: String, _ m: Mark) { agentTabs[id] = m }

    /// End of turn: closes every unmarked agent tab (errors ignored) and forgets all marks; the next turn starts clean
    /// and a `deliverable`/`handoff` tab is an ordinary user tab from then on.
    func endTurn() async {
        let scratch = agentTabs.filter { $0.value == Mark.none }.map { $0.key }
        agentTabs.removeAll()
        for id in scratch {
            if isUserTab(id), let n = Int(id) {
                tabs.removeValue(forKey: id)?.close()
                _ = try? await ExtensionBridge.shared.request("close", ["tabId": .int(n)], timeout: 10)
            } else {
                _ = try? await http("/json/close/\(id)")
                tabs.removeValue(forKey: id)?.close()
            }
        }
        // Let go of the user's remaining tabs: the browser's "Wisp started debugging" bar disappears until the
        // next turn touches a tab again.
        for (id, t) in tabs where t.info.browser == .user {
            tabs.removeValue(forKey: id)
            t.close()
        }
        await ExtensionBridge.shared.detachAll()
    }

    /// The Chrome process that owns our debug port (the Wisp instance, never the user's own Chrome).
    func runningApp() -> NSRunningApplication? {
        if let a = appCache, !a.isTerminated { return a }
        let needle = "--remote-debugging-port=\(port)"
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier?.lowercased(), bid.contains("chrome") || bid.contains("chromium"), !bid.contains("helper") else { continue }
            if ChromeBackend.processArgs(app.processIdentifier).contains(needle) { appCache = app; return app }
        }
        return nil
    }

    private static func processArgs(_ pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the Wisp Chrome is hidden (launched in the background or `hide()`); the overlay cursor is pointless then.
    var isHidden: Bool { runningApp()?.isHidden ?? false }

    /// Brings the Wisp Chrome forward (optionally switching to a tab first).
    func show(tab spec: String?) async throws {
        if let spec = spec {
            let t = try await tab(spec)
            if t.info.browser == .user {
                // The user's own browser: switch to the tab and focus its window; nothing to unhide.
                try await activateTab(id: t.id, focusWindow: true)
                return
            }
            try await activateTab(id: t.id)
        }
        guard let app = runningApp() else { throw WispError(.chromeUnavailable, "the Wisp Chrome process is not running (use `wisp chrome launch`)") }
        if app.isHidden {
            await MainActor.run { _ = app.unhide() }
            for _ in 0..<20 where app.isHidden { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        // wispd is never the active app, so the cooperative macOS 14 `activate()` is refused. Accessibility can make
        // any app frontmost from the background; the activation call is kept as a second attempt.
        let ax = AXEl.app(pid: app.processIdentifier)
        _ = ax.set(kAXFrontmostAttribute, true)
        (ax.focusedWindow ?? ax.windows.first)?.perform(kAXRaiseAction)
        await MainActor.run { _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows]) }
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Hides the Wisp Chrome (all of its windows); CDP keeps working while hidden.
    func hide() async {
        guard let app = runningApp() else { return }
        await MainActor.run { _ = app.hide() }
    }

    /// Resolves a tab by id, id prefix, "active"/"current", or a substring of its title/URL.
    func tab(_ spec: String) async throws -> ChromeTab {
        let list = try await listTabs()
        var info: ChromeTabInfo?
        if spec == "active" || spec == "current" || spec.isEmpty { info = list.first }
        else if let exact = list.first(where: { $0.id == spec }) { info = exact }
        else if let pre = list.first(where: { $0.id.hasPrefix(spec) }) { info = pre }
        else {
            let lower = spec.lowercased()
            let m = list.filter { $0.title.lowercased().contains(lower) || $0.url.lowercased().contains(lower) }
            if m.count == 1 { info = m[0] } else if m.count > 1 {
                throw WispError(.ambiguousApp, "several tabs match `\(spec)`", data: .array(m.map { $0.json }))
            }
        }
        guard let i = info else { throw WispError(.tabNotFound, "no Chrome tab matches `\(spec)`", data: .array(list.map { $0.json })) }
        if let t = tabs[i.id], !t.conn.isClosed { t.info = i; return t }
        let t: ChromeTab
        if let n = i.extensionTabId {
            // The extension attaches its debugger on the first command.
            t = ChromeTab(info: i, conn: ExtensionBridge.shared.transport(for: n))
        } else {
            guard let ws = i.wsURL, let url = URL(string: ws) else { throw WispError(.chromeUnavailable, "tab \(i.id) has no debugger URL (another client attached?)") }
            let c = CDPConnection(url: url)
            try await c.connect()
            t = ChromeTab(info: i, conn: c)
        }
        try await t.enableDomains()
        tabs[i.id] = t
        return t
    }

    func dropTab(_ id: String) { tabs.removeValue(forKey: id)?.close() }

    /// Forgets every cached revision of the open tabs (the next `state` returns a full tree).
    func resetRevisions() { for t in tabs.values { t.revisions.reset() } }

    /// Starts (or reuses) the Wisp Chrome. Returns the debug port and the ids of the tabs this call opened, which the
    /// caller registers as agent tabs. `visible: false` launches Chrome hidden and in the background so the user's
    /// frontmost app does not change (`wisp chrome show` brings it forward later).
    static func launch(port requested: Int, profile: URL, url: String?, app: String = "Google Chrome", visible: Bool = false) async throws -> (port: Int, tabs: [String]) {
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // Reuse a Wisp Chrome that is already running on the recorded port.
        if let d = FileManager.default.contents(atPath: stateFile.path), let j = try? JSON.parse(d), let p = j["port"].int {
            let existing = ChromeBackend(port: p)
            if (try? await existing.version()) != nil {
                var opened: [String] = []
                if let u = url, let t = try? await existing.newTab(url: u) { opened.append(t.id) }
                return (p, opened)
            }
        }
        let port = freePort(preferred: requested)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = visible ? ["-n", "-a", app] : ["-g", "-j", "-n", "-a", app]
        args += ["--args", "--remote-debugging-port=\(port)", "--user-data-dir=\(profile.path)",
                 "--no-first-run", "--no-default-browser-check", "--disable-session-crashed-bubble"]
        if let u = url { args.append(u) } else { args.append("about:blank") }
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw WispError(.launchFailed, "could not launch \(app) (open exit \(p.terminationStatus))") }
        persist(port: port)
        let backend = ChromeBackend(port: port)
        for _ in 0..<60 {
            if (try? await backend.version()) != nil {
                // Everything Chrome opened at startup (the URL or about:blank) is the agent's.
                let tabs = ((try? await backend.listTabs()) ?? []).map { $0.id }
                if !visible {
                    // Chrome activates and shows itself while it creates its first window, regardless of `open -g -j`.
                    // Keep it hidden through that phase so the user's frontmost app never changes.
                    let until = Date().addingTimeInterval(2.5)
                    while Date() < until {
                        if let app = backend.runningApp(), !app.isHidden { app.hide() }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                return (port, tabs)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WispError(.chromeUnavailable, "Chrome started but the debug port \(port) did not come up")
    }
}

/// One attached tab.
final class ChromeTab {
    var info: ChromeTabInfo
    let conn: CDPTransport
    let revisions = RevisionStore()
    var lastScreenshot: ScreenshotResult?
    var instructionsShown = false
    var needsSettle = false
    private var domainsEnabled = false
    private var lastLoadEvent = Date.distantPast
    private var lastAXUpdate = Date.distantPast
    private var lastNavigationStart = Date.distantPast
    var lastActionAt = Date.distantPast
    /// Events arrive on the socket's queue; the two pending records are read from the daemon actor.
    private let eventLock = NSLock()
    private var pendingChooser: (backendNodeId: Int?, mode: String)?
    private var pendingDialog: (type: String, message: String, defaultPrompt: String?)?

    init(info: ChromeTabInfo, conn: CDPTransport) {
        self.info = info
        self.conn = conn
        conn.onEvent = { [weak self] method, params in
            guard let self = self else { return }
            switch method {
            case "Page.loadEventFired", "Page.frameStoppedLoading", "Page.domContentEventFired": self.lastLoadEvent = Date()
            case "Page.frameStartedLoading", "Page.frameStartedNavigating", "Page.frameNavigated": self.lastNavigationStart = Date()
            case "Accessibility.nodesUpdated", "Accessibility.loadComplete": self.lastAXUpdate = Date()
            case "Page.fileChooserOpened":
                self.eventLock.lock()
                self.pendingChooser = (params["backendNodeId"].int, params["mode"].string ?? "selectSingle")
                self.eventLock.unlock()
                Log.debug("tab \(self.id.prefix(8)): file chooser opened (node \(params["backendNodeId"].int.map(String.init) ?? "?"), \(params["mode"].string ?? "?"))")
            case "Page.javascriptDialogOpening":
                self.eventLock.lock()
                self.pendingDialog = (params["type"].string ?? "dialog", params["message"].string ?? "", params["defaultPrompt"].string)
                self.eventLock.unlock()
            case "Page.javascriptDialogClosed":
                self.eventLock.lock()
                self.pendingDialog = nil
                self.eventLock.unlock()
            default: break
            }
        }
    }

    var id: String { info.id }

    /// The JavaScript dialog (alert/confirm/prompt/beforeunload) currently blocking the page, if any. While it is up
    /// the renderer is stopped: no snapshot, no evaluate, no settle; only `handleDialog` moves on.
    var dialog: (type: String, message: String)? {
        eventLock.lock(); defer { eventLock.unlock() }
        return pendingDialog.map { ($0.type, $0.message) }
    }

    private var chooserNode: Int? {
        eventLock.lock(); defer { eventLock.unlock() }
        return pendingChooser?.backendNodeId
    }

    func close() { conn.close() }

    func enableDomains() async throws {
        if domainsEnabled { return }
        _ = try await conn.send("Page.enable")
        _ = try await conn.send("DOM.enable")
        _ = try await conn.send("Runtime.enable")
        _ = try? await conn.send("Accessibility.enable")
        _ = try? await conn.send("DOM.getDocument", ["depth": 0])
        // Clicking a file input reports `Page.fileChooserOpened` instead of opening the native panel; `setFiles`
        // then fills it. Focus emulation keeps the page believing it is focused while Chrome sits hidden in the background.
        _ = try? await conn.send("Page.setInterceptFileChooserDialog", ["enabled": true])
        _ = try? await conn.send("Emulation.setFocusEmulationEnabled", ["enabled": true])
        domainsEnabled = true
    }

    /// Fills a file input: the given node, else the input whose chooser the last click opened.
    func setFiles(backendNodeId: Int?, files: [String]) async throws {
        var target = backendNodeId ?? chooserNode
        // The chooser event can arrive a moment after the click that opened it was acknowledged: give it a short
        // grace period before giving up.
        if target == nil {
            let deadline = Date().addingTimeInterval(1.5)
            while target == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
                target = chooserNode
            }
        }
        guard let node = target else {
            throw WispError(.invalidParams, "no file input targeted; click the file input first or pass --el")
        }
        _ = try await conn.send("DOM.setFileInputFiles", ["files": .array(files.map { .string($0) }), "backendNodeId": .int(node)])
        clearPending(chooser: true, dialog: false)
    }

    private func clearPending(chooser: Bool, dialog: Bool) {
        eventLock.lock(); defer { eventLock.unlock() }
        if chooser { pendingChooser = nil }
        if dialog { pendingDialog = nil }
    }

    /// Accepts or dismisses the open JavaScript dialog (`text` answers a prompt).
    func handleDialog(accept: Bool, text: String?) async throws {
        var params: [String: JSON] = ["accept": .bool(accept)]
        if let t = text { params["promptText"] = .string(t) }
        _ = try await conn.send("Page.handleJavaScriptDialog", .object(params))
        clearPending(chooser: false, dialog: true)
    }

    /// Sends an input event. Chrome answers only once the page acknowledged the event, and a page that opens a
    /// JavaScript dialog from its handler never does until the dialog is handled, so return as soon as one opens (the
    /// late reply is discarded).
    private func dispatchInput(_ method: String, _ params: JSON) async throws {
        final class Slot {
            private let lock = NSLock()
            private var result: Result<JSON, Error>?
            func set(_ r: Result<JSON, Error>) { lock.lock(); result = r; lock.unlock() }
            func get() -> Result<JSON, Error>? { lock.lock(); defer { lock.unlock() }; return result }
        }
        let slot = Slot()
        let conn = self.conn
        Task {
            do { slot.set(.success(try await conn.send(method, params))) } catch { slot.set(.failure(error)) }
        }
        while true {
            if let r = slot.get() { _ = try r.get(); return }
            if dialog != nil { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    struct Viewport { var width: Double; var height: Double; var scrollX: Double; var scrollY: Double; var dpr: Double }

    func viewport() async throws -> Viewport {
        let m = try await conn.send("Page.getLayoutMetrics")
        let vv = m["cssVisualViewport"]
        let lv = m["cssLayoutViewport"]
        let dpr = (try? await conn.send("Runtime.evaluate", ["expression": "window.devicePixelRatio", "returnByValue": true]))?["result"]["value"].double ?? 2
        return Viewport(width: vv["clientWidth"].double ?? lv["clientWidth"].double ?? 1280,
                        height: vv["clientHeight"].double ?? lv["clientHeight"].double ?? 800,
                        scrollX: lv["pageX"].double ?? 0, scrollY: lv["pageY"].double ?? 0, dpr: dpr)
    }

    struct Snapshot { var root: UINode; var viewport: Viewport; var title: String; var url: String }

    /// Builds a `UINode` tree from the accessibility tree plus DOM layout bounds.
    func snapshot() async throws -> Snapshot {
        try await enableDomains()
        let vp = try await viewport()
        async let axResp = conn.send("Accessibility.getFullAXTree", ["depth": -1], timeout: 30)
        async let domResp = conn.send("DOMSnapshot.captureSnapshot", ["computedStyles": [], "includeDOMRects": true], timeout: 30)
        async let titleResp = conn.send("Runtime.evaluate", ["expression": "JSON.stringify({t:document.title,u:location.href})", "returnByValue": true])
        let ax = try await axResp
        let dom = try? await domResp
        let tj = (try? await titleResp)?["result"]["value"].string
        var title = info.title, url = info.url
        if let tj = tj, let parsed = try? JSON.parse(tj) { title = parsed["t"].string ?? title; url = parsed["u"].string ?? url }
        info.title = title; info.url = url

        // backendNodeId -> viewport bounds
        var bounds: [Int: UIRect] = [:]
        if let docs = dom?["documents"].array, let first = docs.first {
            let backendIds = first["nodes"]["backendNodeId"].array ?? []
            let layoutIdx = first["layout"]["nodeIndex"].array ?? []
            let layoutBounds = first["layout"]["bounds"].array ?? []
            let sx = first["scrollOffsetX"].double ?? 0, sy = first["scrollOffsetY"].double ?? 0
            for (k, ni) in layoutIdx.enumerated() {
                guard let n = ni.int, n < backendIds.count, let bid = backendIds[n].int, k < layoutBounds.count,
                      let b = layoutBounds[k].array, b.count == 4 else { continue }
                let r = UIRect(x: (b[0].double ?? 0) - sx, y: (b[1].double ?? 0) - sy, w: b[2].double ?? 0, h: b[3].double ?? 0)
                if bounds[bid] == nil || r.area > (bounds[bid]?.area ?? 0) { bounds[bid] = r }
            }
        }

        let nodes = ax["nodes"].array ?? []
        var byId: [String: JSON] = [:]
        var rootId: String?
        for n in nodes {
            guard let id = n["nodeId"].string else { continue }
            byId[id] = n
            if n["parentId"].isNull, rootId == nil { rootId = id }
        }
        guard let rid = rootId, let rootJ = byId[rid] else {
            throw WispError(.accessibilityError, "Chrome returned an empty accessibility tree for tab \(id)")
        }

        var total = 0
        func build(_ j: JSON) -> [UINode] {
            total += 1
            if total > 8000 { return [] }
            let children = (j["childIds"].array ?? []).compactMap { $0.string }.compactMap { byId[$0] }
            if j["ignored"].bool == true {
                return children.flatMap { build($0) }
            }
            let rawRole = j["role"]["value"].string ?? "generic"
            let backend = j["backendDOMNodeId"].int
            let identity = backend.map { "cdp:\($0)" } ?? "ax:\(j["nodeId"].string ?? "?")"
            let node = UINode(identity: identity, role: Roles.short(aria: rawRole), rawRole: rawRole)
            node.handle = backend
            if let name = j["name"]["value"].string, !name.isEmpty { node.name = name }
            if let v = j["value"]["value"] as JSON?, !v.isNull {
                let s = v.string ?? v.stringified()
                if !s.isEmpty, s != node.name { node.value = s }
            }
            if let d = j["description"]["value"].string, !d.isEmpty, d != node.name { node.desc = d }
            for p in j["properties"].array ?? [] {
                let pname = p["name"].string ?? ""
                let pv = p["value"]["value"]
                switch pname {
                case "focused": if pv.bool == true { node.states.insert(.focused) }
                case "disabled": if pv.bool == true { node.states.insert(.disabled) }
                case "checked":
                    switch pv.string ?? (pv.bool == true ? "true" : "false") {
                    case "true": node.states.insert(.checked)
                    case "mixed": node.states.insert(.mixed)
                    default: node.states.insert(.unchecked)
                    }
                case "pressed": if pv.string == "true" || pv.bool == true { node.states.insert(.pressed) }
                case "expanded":
                    if let b = pv.bool { node.states.insert(b ? .expanded : .collapsed); node.actions.append(b ? "Collapse" : "Expand") }
                case "selected": if pv.bool == true { node.states.insert(.selected) }
                case "required": if pv.bool == true { node.states.insert(.required) }
                case "invalid": if let s = pv.string, s != "false" { node.states.insert(.invalid) }
                case "readonly": if pv.bool == true { node.states.insert(.readonly) }
                case "busy": if pv.bool == true { node.states.insert(.busy) }
                case "hidden": if pv.bool == true { node.states.insert(.hidden) }
                case "url": if let u = pv.string, !u.isEmpty { node.url = u }
                case "placeholder": if let s = pv.string, !s.isEmpty { node.placeholder = s }
                case "level": if let l = pv.int, node.role == "heading" { node.subrole = "level\(l)" }
                case "settable": if pv.bool == true { node.valueSettable = true }
                case "editable": if let s = pv.string, s != "false" { node.states.insert(.editable); node.valueSettable = true }
                case "hasPopup": if let s = pv.string, s != "false" { node.actions.append("ShowMenu") }
                default: break
                }
            }
            if ["field", "search", "combo", "textarea", "stepper", "slider"].contains(node.role) { node.valueSettable = true }
            if let b = backend, let r = bounds[b] { node.frame = r }
            for c in children { for cn in build(c) { node.add(cn) } }
            return [node]
        }
        let roots = build(rootJ)
        let root: UINode
        if roots.count == 1 { root = roots[0] } else {
            root = UINode(identity: "cdp:root", role: "web", rawRole: "RootWebArea")
            for r in roots { root.add(r) }
        }
        root.role = "web"
        root.name = title
        root.url = url
        return Snapshot(root: root, viewport: vp, title: title, url: url)
    }

    // MARK: Element geometry

    func center(ofBackendNode id: Int) async throws -> CGPoint {
        _ = try? await conn.send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": .int(id)])
        let box = try await conn.send("DOM.getBoxModel", ["backendNodeId": .int(id)])
        guard let q = box["model"]["content"].array, q.count >= 8 else { throw WispError(.elementOffscreen, "element has no layout box") }
        let xs = stride(from: 0, to: 8, by: 2).compactMap { q[$0].double }
        let ys = stride(from: 1, to: 8, by: 2).compactMap { q[$0].double }
        let vp = try await viewport()
        var cx = xs.reduce(0, +) / Double(xs.count), cy = ys.reduce(0, +) / Double(ys.count)
        cx = min(max(cx, 1), vp.width - 1)
        cy = min(max(cy, 1), vp.height - 1)
        return CGPoint(x: cx, y: cy)
    }

    /// Screen coordinates (CG, top-left origin) for a viewport point, used to place the overlay cursor.
    func screenPoint(for p: CGPoint) async -> CGPoint? {
        guard let m = await windowMetrics() else { return nil }
        let chrome = max(0, m.outerHeight - m.innerHeight)
        return CGPoint(x: m.x + p.x, y: m.y + chrome + p.y)
    }

    /// The browser window's frame in CG screen coordinates (used to anchor the activity lens), or nil when the page
    /// cannot be asked (a crashed or navigating target).
    func windowFrame() async -> CGRect? {
        guard let m = await windowMetrics(), m.outerWidth > 0, m.outerHeight > 0 else { return nil }
        return CGRect(x: m.x, y: m.y, width: m.outerWidth, height: m.outerHeight)
    }

    private struct WindowMetrics { var x, y, outerWidth, outerHeight, innerHeight: Double }

    private func windowMetrics() async -> WindowMetrics? {
        if dialog != nil { return nil }
        let expr = "JSON.stringify({x:window.screenX,y:window.screenY,oh:window.outerHeight,ih:window.innerHeight,ow:window.outerWidth,iw:window.innerWidth})"
        guard let r = try? await conn.send("Runtime.evaluate", ["expression": .string(expr), "returnByValue": true]),
              let s = r["result"]["value"].string, let j = try? JSON.parse(s),
              let sx = j["x"].double, let sy = j["y"].double, let oh = j["oh"].double, let ih = j["ih"].double else { return nil }
        return WindowMetrics(x: sx, y: sy, outerWidth: j["ow"].double ?? 0, outerHeight: oh, innerHeight: ih)
    }

    // MARK: Input

    static func cdpModifiers(_ mods: Set<KeyModifier>) -> Int {
        var m = 0
        if mods.contains(.option) { m |= 1 }
        if mods.contains(.control) { m |= 2 }
        if mods.contains(.command) { m |= 4 }
        if mods.contains(.shift) { m |= 8 }
        return m
    }

    func click(at p: CGPoint, button: MouseButton, count: Int, modifiers: Int = 0, clickInterval: Double,
               beforeDown: (() async -> Void)? = nil, afterUp: (() async -> Void)? = nil) async throws {
        let b = button.rawValue
        try await dispatchInput("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": .number(p.x), "y": .number(p.y), "button": "none", "modifiers": .int(modifiers)])
        for i in 1...max(1, count) {
            await beforeDown?()
            try await dispatchInput("Input.dispatchMouseEvent", ["type": "mousePressed", "x": .number(p.x), "y": .number(p.y), "button": .string(b), "clickCount": .int(i), "modifiers": .int(modifiers)])
            try? await Task.sleep(nanoseconds: UInt64(clickInterval * 1_000_000_000))
            try await dispatchInput("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": .number(p.x), "y": .number(p.y), "button": .string(b), "clickCount": .int(i), "modifiers": .int(modifiers)])
            await afterUp?()
            if i < count { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
    }

    func mouse(_ type: String, at p: CGPoint, button: MouseButton = .left) async throws {
        try await dispatchInput("Input.dispatchMouseEvent", ["type": .string(type), "x": .number(p.x), "y": .number(p.y), "button": .string(type == "mouseMoved" ? "none" : button.rawValue), "clickCount": 1])
    }

    func drag(from a: CGPoint, to b: CGPoint) async throws {
        _ = try await conn.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": .number(a.x), "y": .number(a.y), "button": "none"])
        _ = try await conn.send("Input.dispatchMouseEvent", ["type": "mousePressed", "x": .number(a.x), "y": .number(a.y), "button": "left", "clickCount": 1])
        for i in 1...12 {
            let t = Double(i) / 12
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            _ = try await conn.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": .number(p.x), "y": .number(p.y), "button": "left", "buttons": 1])
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await conn.send("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": .number(b.x), "y": .number(b.y), "button": "left", "clickCount": 1])
    }

    func scroll(at p: CGPoint, dx: Double, dy: Double) async throws {
        var rx = dx, ry = dy
        while abs(rx) > 0.5 || abs(ry) > 0.5 {
            let sx = max(-300, min(300, rx)), sy = max(-300, min(300, ry))
            rx -= sx; ry -= sy
            _ = try await conn.send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": .number(p.x), "y": .number(p.y), "deltaX": .number(sx), "deltaY": .number(sy)])
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    static let namedKeys: [String: (key: String, code: String, vk: Int, text: String?)] = [
        "return": ("Enter", "Enter", 13, "\r"), "kpenter": ("Enter", "NumpadEnter", 13, "\r"), "tab": ("Tab", "Tab", 9, "\t"),
        "space": (" ", "Space", 32, " "), "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil),
        "escape": ("Escape", "Escape", 27, nil), "up": ("ArrowUp", "ArrowUp", 38, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
        "left": ("ArrowLeft", "ArrowLeft", 37, nil), "right": ("ArrowRight", "ArrowRight", 39, nil), "home": ("Home", "Home", 36, nil),
        "end": ("End", "End", 35, nil), "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
        "capslock": ("CapsLock", "CapsLock", 20, nil), "help": ("Insert", "Insert", 45, nil), "clear": ("Clear", "NumLock", 12, nil),
        "f1": ("F1", "F1", 112, nil), "f2": ("F2", "F2", 113, nil), "f3": ("F3", "F3", 114, nil), "f4": ("F4", "F4", 115, nil),
        "f5": ("F5", "F5", 116, nil), "f6": ("F6", "F6", 117, nil), "f7": ("F7", "F7", 118, nil), "f8": ("F8", "F8", 119, nil),
        "f9": ("F9", "F9", 120, nil), "f10": ("F10", "F10", 121, nil), "f11": ("F11", "F11", 122, nil), "f12": ("F12", "F12", 123, nil),
    ]

    func pressChord(_ chord: KeyChord) async throws {
        let mods = ChromeTab.cdpModifiers(chord.modifiers)
        guard let key = chord.key else { return }
        var k: String, code: String, vk: Int, text: String?
        switch key {
        case .named(let n):
            guard let e = ChromeTab.namedKeys[n] else { throw WispError(.invalidParams, "key `\(n)` is not supported for Chrome tabs") }
            (k, code, vk, text) = e
        case .character(let c):
            k = String(c)
            if c.isLetter, c.isASCII { code = "Key" + String(c).uppercased(); vk = Int(String(c).uppercased().unicodeScalars.first!.value) }
            else if c.isNumber, c.isASCII { code = "Digit" + String(c); vk = Int(c.unicodeScalars.first!.value) }
            else { code = ""; vk = 0 }
            text = (mods & 6) != 0 ? nil : String(c)
        }
        var down: [String: JSON] = ["type": .string(text == nil ? "rawKeyDown" : "keyDown"), "key": .string(k), "code": .string(code),
                                    "windowsVirtualKeyCode": .int(vk), "nativeVirtualKeyCode": .int(vk), "modifiers": .int(mods)]
        if let t = text { down["text"] = .string(t); down["unmodifiedText"] = .string(t) }
        if mods & 4 != 0 { down["commands"] = commandsFor(key: k) }
        try await dispatchInput("Input.dispatchKeyEvent", .object(down))
        try? await Task.sleep(nanoseconds: 20_000_000)
        try await dispatchInput("Input.dispatchKeyEvent", ["type": "keyUp", "key": .string(k), "code": .string(code), "windowsVirtualKeyCode": .int(vk), "modifiers": .int(mods)])
    }

    /// Editing commands Chrome expects for ⌘-shortcuts on macOS.
    private func commandsFor(key: String) -> JSON {
        switch key.lowercased() {
        case "a": return ["selectAll"]
        case "c": return ["copy"]
        case "v": return ["paste"]
        case "x": return ["cut"]
        case "z": return ["undo"]
        default: return []
        }
    }

    func insertText(_ text: String) async throws {
        var buffer = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                if !buffer.isEmpty { _ = try await conn.send("Input.insertText", ["text": .string(buffer)]); buffer = "" }
                try await pressChord(KeyChord(modifiers: [], key: .named("return")))
            } else if ch == "\t" {
                if !buffer.isEmpty { _ = try await conn.send("Input.insertText", ["text": .string(buffer)]); buffer = "" }
                try await pressChord(KeyChord(modifiers: [], key: .named("tab")))
            } else { buffer.append(ch) }
        }
        if !buffer.isEmpty { _ = try await conn.send("Input.insertText", ["text": .string(buffer)]) }
    }

    func setValue(backendNodeId: Int, value: String) async throws {
        _ = try? await conn.send("DOM.focus", ["backendNodeId": .int(backendNodeId)])
        let resolved = try await conn.send("DOM.resolveNode", ["backendNodeId": .int(backendNodeId)])
        guard let objectId = resolved["object"]["objectId"].string else { throw WispError(.invalidElement, "could not resolve element") }
        let fn = """
        function(v) {
          const el = this;
          const tag = (el.tagName || '').toLowerCase();
          if (tag === 'input' || tag === 'textarea') {
            const proto = tag === 'input' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, v);
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'native';
          }
          if (tag === 'select') {
            for (const o of el.options) { if (o.value === v || o.text === v) { el.value = o.value; el.dispatchEvent(new Event('change', {bubbles: true})); return 'select'; } }
            return 'no-option';
          }
          if (el.isContentEditable) {
            el.focus();
            const sel = window.getSelection(); const range = document.createRange(); range.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(range);
            return 'contenteditable';
          }
          return 'unsupported';
        }
        """
        let r = try await conn.send("Runtime.callFunctionOn", ["objectId": .string(objectId), "functionDeclaration": .string(fn), "arguments": [["value": .string(value)]], "returnByValue": true])
        let how = r["result"]["value"].string ?? "unsupported"
        if how == "contenteditable" {
            try await insertText(value)
        } else if how == "unsupported" || how == "no-option" {
            // Fallback: select all and type.
            try await pressChord(KeyChord(modifiers: [.command], key: .character("a")))
            try await insertText(value)
        }
    }

    func selectText(backendNodeId: Int, text: String, prefix: String?, suffix: String?, selection: SelectionType) async throws {
        let resolved = try await conn.send("DOM.resolveNode", ["backendNodeId": .int(backendNodeId)])
        guard let objectId = resolved["object"]["objectId"].string else { throw WispError(.invalidElement, "could not resolve element") }
        let fn = """
        function(text, prefix, suffix, mode) {
          const el = this;
          const tag = (el.tagName || '').toLowerCase();
          const needle = (prefix || '') + text + (suffix || '');
          if (tag === 'input' || tag === 'textarea') {
            const i = el.value.indexOf(needle); if (i < 0) return 'not-found';
            const s = i + (prefix || '').length, e = s + text.length;
            el.focus();
            if (mode === 'cursor_before') el.setSelectionRange(s, s); else if (mode === 'cursor_after') el.setSelectionRange(e, e); else el.setSelectionRange(s, e);
            return 'ok';
          }
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          let nodes = [], full = '';
          while (walker.nextNode()) { nodes.push({n: walker.currentNode, start: full.length}); full += walker.currentNode.nodeValue; }
          const i = full.indexOf(needle); if (i < 0) return 'not-found';
          const s = i + (prefix || '').length, e = s + text.length;
          function locate(off) { for (let k = nodes.length - 1; k >= 0; k--) { if (nodes[k].start <= off) return {node: nodes[k].n, offset: off - nodes[k].start}; } return null; }
          const a = locate(s), b = locate(e); if (!a || !b) return 'not-found';
          const range = document.createRange();
          if (mode === 'cursor_before') { range.setStart(a.node, a.offset); range.collapse(true); }
          else if (mode === 'cursor_after') { range.setStart(b.node, b.offset); range.collapse(true); }
          else { range.setStart(a.node, a.offset); range.setEnd(b.node, b.offset); }
          const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
          if (el.focus) el.focus();
          return 'ok';
        }
        """
        let r = try await conn.send("Runtime.callFunctionOn", [
            "objectId": .string(objectId), "functionDeclaration": .string(fn),
            "arguments": [["value": .string(text)], ["value": .string(prefix ?? "")], ["value": .string(suffix ?? "")], ["value": .string(selection.rawValue)]],
            "returnByValue": true])
        if r["result"]["value"].string != "ok" { throw WispError(.actionNotAvailable, "text `\(text)` not found in element") }
    }

    func screenshot() async throws -> ScreenshotResult {
        let r = try await conn.send("Page.captureScreenshot", ["format": "png", "captureBeyondViewport": false], timeout: 30)
        guard let b64 = r["data"].string, let data = Data(base64Encoded: b64) else { throw WispError(.internalError, "no screenshot data") }
        let url = WispPaths.screenshotDir.appendingPathComponent("wisp-tab-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: url)
        let vp = try await viewport()
        var w = Int(vp.width * vp.dpr), h = Int(vp.height * vp.dpr)
        if let img = NSImage(data: data), let rep = img.representations.first { w = rep.pixelsWide; h = rep.pixelsHigh }
        return ScreenshotResult(path: url.path, width: w, height: h, scale: Double(w) / max(1, vp.width), originX: 0, originY: 0)
    }

    func evaluate(_ expression: String) async throws -> JSON {
        let r = try await conn.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": true, "awaitPromise": true, "userGesture": true], timeout: 30)
        if !r["exceptionDetails"].isNull {
            throw WispError(.internalError, "JavaScript error: " + (r["exceptionDetails"]["exception"]["description"].string ?? r["exceptionDetails"]["text"].string ?? "unknown"))
        }
        return r["result"]["value"]
    }

    func navigate(_ url: String) async throws {
        var u = url
        if !u.contains("://") { u = "https://" + u }
        _ = try await conn.send("Page.navigate", ["url": .string(u)])
        needsSettle = true
    }

    func history(_ delta: Int) async throws {
        let h = try await conn.send("Page.getNavigationHistory")
        guard let entries = h["entries"].array, let cur = h["currentIndex"].int else { return }
        let target = cur + delta
        guard target >= 0, target < entries.count, let id = entries[target]["id"].int else {
            throw WispError(.actionNotAvailable, "no history entry in that direction")
        }
        _ = try await conn.send("Page.navigateToHistoryEntry", ["entryId": .int(id)])
        needsSettle = true
    }

    func reload() async throws {
        _ = try await conn.send("Page.reload")
        needsSettle = true
    }

    /// Waits until the DOM stops mutating (quiet window) or the budget elapses. If the last action started a
    /// navigation, first waits for the load event.
    func waitForQuiet(min: Double, quiet: Double, max: Double) async {
        let start = Date()
        try? await Task.sleep(nanoseconds: UInt64(min * 1_000_000_000))
        while Date().timeIntervalSince(start) < max {
            // A JavaScript dialog stops the renderer; nothing settles until it is handled.
            if dialog != nil { needsSettle = false; return }
            let navStarted = lastNavigationStart > lastActionAt.addingTimeInterval(-0.05)
            let loaded = lastLoadEvent >= lastNavigationStart
            let readyState = (try? await conn.send("Runtime.evaluate", ["expression": "document.readyState", "returnByValue": true], timeout: 3))?["result"]["value"].string
            if (!navStarted || loaded) && readyState == "complete" { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let expr = """
        new Promise(resolve => {
          const quiet = \(Int(quiet * 1000)), max = \(Int(Swift.max(0.2, max - min) * 1000));
          let last = performance.now(); const start = last;
          const obs = new MutationObserver(() => { last = performance.now(); });
          obs.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
          const tick = () => {
            const now = performance.now();
            if (document.readyState === 'complete' && now - last >= quiet) { obs.disconnect(); resolve('quiet'); return; }
            if (now - start >= max) { obs.disconnect(); resolve('timeout'); return; }
            setTimeout(tick, 50);
          };
          tick();
        })
        """
        if dialog != nil { needsSettle = false; return }
        _ = try? await conn.send("Runtime.evaluate", ["expression": .string(expr), "awaitPromise": true, "returnByValue": true], timeout: max + 2)
        needsSettle = false
    }
}
