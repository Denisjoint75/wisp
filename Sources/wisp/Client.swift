import Foundation
import WispCore

/// Socket client for the daemon; starts `wispd` on demand.
final class WispClient {
    private var fd: Int32 = -1
    private var decoder = Framing.Decoder()
    private var nextId = 1
    let socketPath: String

    init(socketPath: String = WispPaths.socketPath) { self.socketPath = socketPath }

    func connect(autoStart: Bool = true, timeout: Double = 8) throws {
        if tryConnect() { return }
        guard autoStart else { throw WispError(.notConnected, "wispd is not running (socket \(socketPath)); run `wisp daemon start`") }
        try WispClient.spawnDaemon()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(150_000)
            if tryConnect() { return }
        }
        throw WispError(.notConnected, "wispd did not come up within \(Int(timeout))s; check \(WispPaths.logPath)")
    }

    private func tryConnect() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) } }
        if r != 0 { close(s); return false }
        fd = s
        return true
    }

    static func daemonURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["WISP_DAEMON"], FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("wispd"),
            dir.appendingPathComponent("Wisp.app/Contents/MacOS/wispd"),
            dir.deletingLastPathComponent().appendingPathComponent("Wisp.app/Contents/MacOS/wispd"),
            WispPaths.supportDir.appendingPathComponent("Wisp.app/Contents/MacOS/wispd"),
            URL(fileURLWithPath: "/Applications/Wisp.app/Contents/MacOS/wispd"),
            URL(fileURLWithPath: "/usr/local/bin/wispd"),
            URL(fileURLWithPath: "/opt/homebrew/bin/wispd"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func spawnDaemon() throws {
        guard let url = daemonURL() else {
            throw WispError(.notConnected, "cannot find the wispd executable next to wisp; set WISP_DAEMON=/path/to/wispd")
        }
        let p = Process()
        p.executableURL = url
        p.arguments = []
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["WISP_SOCKET"] = WispPaths.socketPath
        p.environment = env
        try p.run()
    }

    func call(_ method: String, _ params: JSON = [:], timeout: Double = 180) throws -> JSON {
        if fd < 0 { try connect() }
        let id = nextId
        nextId += 1
        let payload = Framing.encode(Proto.request(id: id, method: method, params: params).data())
        try writeAll(payload)
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 500)
            if pr == 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { throw WispError(.notConnected, "connection to wispd closed") }
            for frame in try decoder.feed(Data(buf[0..<n])) {
                let j = try JSON.parse(frame)
                if j["id"].int == id {
                    if !j["error"].isNull { throw WispError.from(json: j["error"]) }
                    return j["result"]
                }
            }
        }
        throw WispError(.timeout, "wispd did not answer \(method) within \(Int(timeout))s")
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw WispError(.notConnected, "write to wispd failed") }
                off += n
            }
        }
    }

    deinit { if fd >= 0 { close(fd) } }
}
