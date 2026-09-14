import Foundation

public enum WispPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var supportDir: URL {
        let u = home.appendingPathComponent("Library/Application Support/Wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    public static var configDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let u = base.appendingPathComponent("wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["WISP_SOCKET"], !p.isEmpty { return p }
        return supportDir.appendingPathComponent("wisp.sock").path
    }

    public static var logPath: String { supportDir.appendingPathComponent("wispd.log").path }
    public static var pidPath: String { supportDir.appendingPathComponent("wispd.pid").path }
    public static var policyPath: String { configDir.appendingPathComponent("policy.json").path }
    public static var instructionsDir: URL { configDir.appendingPathComponent("instructions", isDirectory: true) }

    public static var screenshotDir: URL {
        let u = URL(fileURLWithPath: "/tmp/wisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    public static var chromeProfileDir: URL {
        supportDir.appendingPathComponent("chrome-profile", isDirectory: true)
    }
}
