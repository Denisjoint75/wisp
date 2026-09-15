import Foundation
import WispCore

/// Unix-domain socket server speaking length-framed JSON-RPC.
final class SocketServer {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "wisp.socket", attributes: .concurrent)
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let connLock = NSLock()

    init(path: String) { self.path = path }

    func start() throws {
        // Reuse or replace a stale socket file.
        if FileManager.default.fileExists(atPath: path) {
            if SocketServer.probe(path: path) {
                throw WispError(.internalError, "another wispd is already listening on \(path)")
            }
            unlink(path)
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WispError(.internalError, "socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw WispError(.internalError, "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bindResult == 0 else { throw WispError(.internalError, "bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw WispError(.internalError, "listen() failed") }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
        try? String(getpid()).write(toFile: WispPaths.pidPath, atomically: true, encoding: .utf8)
        Log.info("listening on \(path)")
    }

    private func accept() {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(fd, &addr, &len)
        guard client >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
            Log.warn("rejecting peer uid \(uid)")
            close(client)
            return
        }
        let conn = Connection(fd: client, queue: queue)
        connLock.lock()
        connections[ObjectIdentifier(conn)] = conn
        connLock.unlock()
        conn.onClose = { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.connLock.lock()
            self.connections.removeValue(forKey: ObjectIdentifier(conn))
            self.connLock.unlock()
        }
        conn.run()
    }

    static func probe(path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) } }
        return r == 0
    }

    final class Connection {
        let fd: Int32
        let queue: DispatchQueue
        private var decoder = Framing.Decoder()
        private var reader: DispatchSourceRead?
        private let writeQueue = DispatchQueue(label: "wisp.socket.write")
        private var closed = false
        var onClose: (() -> Void)?

        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            self.queue = queue
        }

        func run() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readAvailable() }
            src.setCancelHandler { [weak self] in
                guard let self = self else { return }
                close(self.fd)
            }
            src.resume()
            reader = src
        }

        private func readAvailable() {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            if n <= 0 { shutdown(); return }
            do {
                let frames = try decoder.feed(Data(buf[0..<n]))
                for f in frames { handleFrame(f) }
            } catch {
                send(Proto.error(id: .null, WispError(.protocolError, "\(error)")))
                shutdown()
            }
        }

        private func handleFrame(_ data: Data) {
            guard let req = try? JSON.parse(data) else {
                send(Proto.error(id: .null, WispError(.invalidRequest, "invalid JSON")))
                return
            }
            let id = req["id"]
            guard let method = req["method"].string else {
                send(Proto.error(id: id, WispError(.invalidRequest, "missing method")))
                return
            }
            let params = req["params"]
            // Fast paths that must not wait behind a running action.
            switch method {
            case Proto.Method.ping:
                send(Proto.result(id: id, Daemon.shared.pingInfo()))
                return
            case Proto.Method.sessionCancel:
                Daemon.shared.cancelNow(reason: .cancelled, message: "cancelled by client")
                send(Proto.result(id: id, ["ok": true]))
                return
            // The extension bridge: relayed messages never wait behind a running action either (a CDP result for
            // that very action may be among them).
            case Proto.Method.bridgeRegister:
                ExtensionBridge.shared.register(self, params: params)
                send(Proto.result(id: id, ["ok": true, "version": .string(WispVersion.string)]))
                return
            case Proto.Method.bridgeMessage:
                ExtensionBridge.shared.handle(message: params)
                if !id.isNull { send(Proto.result(id: id, ["ok": true])) }
                return
            default: break
            }
            Task {
                let out = await Daemon.shared.dispatch(method: method, params: params)
                if !out["error"].isNull { self.send(Proto.error(id: id, WispError.from(json: out["error"]))) }
                else { self.send(Proto.result(id: id, out["result"])) }
            }
        }

        func send(_ json: JSON) {
            let frame = Framing.encode(json.data())
            writeQueue.async { [self] in
                if closed { return }
                frame.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { break }
                        off += n
                    }
                }
            }
        }

        private func shutdown() {
            if closed { return }
            closed = true
            reader?.cancel()
            ExtensionBridge.shared.unregister(self)
            onClose?()
        }
    }
}
