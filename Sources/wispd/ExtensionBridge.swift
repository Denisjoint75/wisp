import Foundation
import WispCore

/// A DevTools Protocol session regardless of how it reaches the browser: a WebSocket to the Wisp Chrome
/// (`CDPConnection`) or the extension bridge into the user's own browser (`ExtensionTransport`).
protocol CDPTransport: AnyObject {
    var isClosed: Bool { get }
    var onEvent: ((String, JSON) -> Void)? { get set }
    func call(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON
    func close()
}

extension CDPTransport {
    func send(_ method: String, _ params: JSON = [:], timeout: Double = 20) async throws -> JSON {
        try await call(method, params, timeout: timeout)
    }
}

/// The connection to the Wisp Chrome extension, relayed by one `wisp native-host` process over the daemon socket.
/// A DevTools command for a user tab travels as a bridge request (`{type: "request", id, op: "cdp", ...}`) and
/// comes back as a `result` message; the extension's `event` messages reach the tab's `ExtensionTransport`.
/// Messages arrive on the socket queue; everything here is guarded by `lock`.
final class ExtensionBridge {
    static let shared = ExtensionBridge()

    private let lock = NSLock()
    private var connection: SocketServer.Connection?
    private var hello: JSON = .null
    private var connectedAt: Date?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var transports: [Int: WeakTransport] = [:]
    private var keepAlive: Task<Void, Never>?

    private struct WeakTransport { weak var t: ExtensionTransport? }

    static let notConnectedMessage = "the Wisp Chrome extension is not connected: install it with `wisp chrome extension install` (then load it in the browser), or use the separate Wisp Chrome via `wisp chrome launch`"

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }

    /// Summary for `chrome.status` and `wisp chrome extension status`.
    var info: JSON {
        lock.lock(); defer { lock.unlock() }
        var o: [String: JSON] = ["connected": .bool(connection != nil), "id": .string(ChromeExtension.id)]
        if connection != nil {
            o["extensionVersion"] = hello["extensionVersion"]
            o["browser"] = hello["browser"]
            o["since"] = connectedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
            o["attachedTabs"] = .int(transports.values.filter { ($0.t?.isClosed ?? true) == false }.count)
        }
        return .object(o)
    }

    /// A native host announced itself on `conn`. A newer host replaces an older one (the extension reloaded).
    func register(_ conn: SocketServer.Connection, params: JSON) {
        lock.lock()
        let replaced = connection != nil
        connection = conn
        hello = .null
        connectedAt = Date()
        let old = pending
        pending = [:]
        let oldTransports = transports
        transports = [:]
        keepAlive?.cancel()
        keepAlive = makeKeepAlive()
        lock.unlock()
        for (_, c) in old { c.resume(throwing: WispError(.notConnected, "the Chrome extension reconnected")) }
        for w in oldTransports.values { w.t?.markClosed() }
        Log.info("extension bridge: native host connected (pid \(params["pid"].int ?? 0))\(replaced ? ", replacing the previous host" : "")")
    }

    func unregister(_ conn: SocketServer.Connection) {
        lock.lock()
        guard connection === conn else { lock.unlock(); return }
        connection = nil
        hello = .null
        connectedAt = nil
        let old = pending
        pending = [:]
        let oldTransports = transports
        transports = [:]
        keepAlive?.cancel()
        keepAlive = nil
        lock.unlock()
        for (_, c) in old { c.resume(throwing: WispError(.chromeUnavailable, "the Chrome extension disconnected")) }
        for w in oldTransports.values { w.t?.markClosed() }
        Log.info("extension bridge: native host disconnected")
    }

    /// A message from the extension (relayed by the host).
    func handle(message m: JSON) {
        switch m["type"].string {
        case "hello":
            lock.lock()
            hello = m
            lock.unlock()
            let b = m["browser"]
            Log.info("extension bridge: \(b["name"].string ?? "Chrome") \(b["version"].string ?? "") with extension \(m["extensionVersion"].string ?? "?")")
        case "result":
            guard let id = m["id"].int else { return }
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            guard let c = c else { return }
            if let e = m["error"].string { c.resume(throwing: WispError(.internalError, "CDP: \(e)", data: m["error"])) }
            else { c.resume(returning: m["result"]) }
        case "event":
            guard let tab = m["tabId"].int, let method = m["method"].string else { return }
            transport(existingFor: tab)?.onEvent?(method, m["params"])
        case "detached", "tabRemoved":
            guard let tab = m["tabId"].int else { return }
            Log.debug("extension bridge: tab \(tab) \(m["type"].string ?? "") \(m["reason"].string ?? "")")
            lock.lock()
            let t = transports.removeValue(forKey: tab)?.t
            lock.unlock()
            t?.markClosed()
        default:
            break
        }
    }

    private func transport(existingFor tab: Int) -> ExtensionTransport? {
        lock.lock(); defer { lock.unlock() }
        return transports[tab]?.t
    }

    /// The transport for a user tab (one per tab; a closed one is replaced).
    func transport(for tab: Int) -> ExtensionTransport {
        lock.lock(); defer { lock.unlock() }
        if let t = transports[tab]?.t, !t.isClosed { return t }
        let t = ExtensionTransport(tabId: tab)
        transports[tab] = WeakTransport(t: t)
        return t
    }

    func forget(tab: Int) {
        lock.lock()
        transports.removeValue(forKey: tab)
        lock.unlock()
    }

    private func allocate() -> (SocketServer.Connection, Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let conn = connection else { return nil }
        let id = nextId
        nextId += 1
        return (conn, id)
    }

    private func register(_ id: Int, _ c: CheckedContinuation<JSON, Error>) {
        lock.lock()
        pending[id] = c
        lock.unlock()
    }

    private func takePending(_ id: Int) -> CheckedContinuation<JSON, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    /// Sends a request to the extension and waits for its result.
    func request(_ op: String, _ params: JSON = [:], timeout: Double = 20) async throws -> JSON {
        guard let (conn, id) = allocate() else { throw WispError(.chromeUnavailable, ExtensionBridge.notConnectedMessage) }
        var msg = params.object ?? [:]
        msg["type"] = "request"
        msg["id"] = .int(id)
        msg["op"] = .string(op)
        let frame: JSON = ["jsonrpc": "2.0", "method": .string(Proto.Method.bridgeSend), "params": .object(msg)]
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            register(id, c)
            conn.send(frame)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.takePending(id)?.resume(throwing: WispError(.timeout, "the Chrome extension did not answer \(op) within \(Int(timeout))s"))
            }
        }
    }

    /// Pings the extension every 20 s: a message event keeps its service worker (and so the host) alive between
    /// turns, otherwise Chrome stops the worker after 30 s of silence and the bridge would come and go.
    private func makeKeepAlive() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self = self, self.isConnected, !Task.isCancelled else { return }
                _ = try? await self.request("ping", timeout: 10)
            }
        }
    }

    /// End of turn: detaches from every tab so the browser's "Wisp started debugging this browser" bar goes away.
    func detachAll() async {
        guard isConnected else { return }
        _ = try? await request("detachAll", timeout: 10)
    }
}

/// `CDPTransport` for one tab of the user's browser, through the extension bridge. The extension attaches its
/// debugger on the first command and reports `detached` when the user cancels or opens DevTools; the transport is
/// then closed and the backend attaches afresh on the next use.
final class ExtensionTransport: CDPTransport {
    let tabId: Int
    private let lock = NSLock()
    private var closed = false
    var onEvent: ((String, JSON) -> Void)?

    init(tabId: Int) { self.tabId = tabId }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func call(_ method: String, _ params: JSON, timeout: Double) async throws -> JSON {
        guard !isClosed else { throw WispError(.notConnected, "the debugger detached from tab \(tabId); read the tab state again") }
        return try await ExtensionBridge.shared.request("cdp", ["tabId": .int(tabId), "method": .string(method), "params": params], timeout: timeout)
    }

    func close() {
        markClosed()
        ExtensionBridge.shared.forget(tab: tabId)
        let id = tabId
        Task { _ = try? await ExtensionBridge.shared.request("detach", ["tabId": .int(id)], timeout: 5) }
    }
}
