import Foundation
import os
import WispCore

enum Log {
    static let logger = Logger(subsystem: "dev.wisp.daemon", category: "wispd")
    private static let queue = DispatchQueue(label: "wisp.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static var handle: FileHandle? = {
        let path = WispPaths.logPath
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ msg: String) { write("INFO", msg); logger.info("\(msg, privacy: .public)") }
    static func warn(_ msg: String) { write("WARN", msg); logger.warning("\(msg, privacy: .public)") }
    static func error(_ msg: String) { write("ERROR", msg); logger.error("\(msg, privacy: .public)") }
    static func debug(_ msg: String) { if verbose { write("DEBUG", msg) } }

    static var verbose = ProcessInfo.processInfo.environment["WISP_VERBOSE"] == "1"

    private static func write(_ level: String, _ msg: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(msg)\n"
        queue.async { handle?.write(Data(line.utf8)) }
        if ProcessInfo.processInfo.environment["WISP_STDERR"] == "1" { FileHandle.standardError.write(Data(line.utf8)) }
    }

    static func tail(lines: Int) -> String {
        guard let data = FileManager.default.contents(atPath: WispPaths.logPath) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

func WispCoreLogPath() -> String { WispPaths.logPath }
