import Foundation
import WispCore

/// `wisp native-host`: the Chrome native messaging host. The browser starts it when the Wisp extension connects and
/// speaks length-prefixed JSON on stdin/stdout (u32 native-endian, the same framing as the daemon socket on
/// little-endian Macs). The host is a relay: extension messages go to wispd as `bridge.message` notifications and
/// wispd's `bridge.send` notifications go back to the extension. It exits when either side closes, and the
/// extension reconnects (starting a new host, and wispd with it, when needed).
enum NativeHost {
    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let stdinFD = FileHandle.standardInput.fileDescriptor
        let stdoutFD = FileHandle.standardOutput.fileDescriptor
        let outLock = NSLock()
        func emit(_ j: JSON) {
            let frame = Framing.encode(j.data())
            outLock.lock(); defer { outLock.unlock() }
            frame.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(stdoutFD, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }

        let client = WispClient()
        do {
            try client.connect(autoStart: true, timeout: 20)
            _ = try client.call(Proto.Method.bridgeRegister, ["pid": .int(Int(getpid())), "cli": .string(WispVersion.string)], timeout: 10)
        } catch {
            let msg = String(describing: error)
            emit(["type": "daemon", "state": "unavailable", "error": .string(msg)])
            FileHandle.standardError.write(Data("wisp native-host: \(msg)\n".utf8))
            return 1
        }
        emit(["type": "daemon", "state": "connected", "version": .string(WispVersion.string)])

        // Extension -> daemon.
        let reader = Thread {
            var decoder = Framing.Decoder()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(stdinFD, &buf, buf.count)
                if n <= 0 { exit(0) }   // the browser closed the port (extension reloaded, browser quit)
                guard let frames = try? decoder.feed(Data(buf[0..<n])) else { exit(2) }
                for f in frames {
                    guard let j = try? JSON.parse(f) else { continue }
                    do { try client.notify(Proto.Method.bridgeMessage, j) } catch { exit(0) }
                }
            }
        }
        reader.start()

        // Daemon -> extension.
        while true {
            do {
                guard let j = try client.receive(timeoutMs: 1000) else { continue }
                if j["method"].string == Proto.Method.bridgeSend { emit(j["params"]) }
            } catch {
                emit(["type": "daemon", "state": "unavailable", "error": "wispd closed the connection"])
                return 0
            }
        }
    }
}
