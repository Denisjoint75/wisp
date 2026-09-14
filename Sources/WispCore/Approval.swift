import Foundation

/// Risk tier attached to an approval prompt. High-risk apps get a stronger warning in the prompt.
public enum Risk: String, Codable, Equatable, Sendable {
    case high, low

    /// Warning shown as the informative text of the approval prompt.
    public var subtitle: String {
        switch self {
        case .high: return "This app can change system settings or reach sensitive data. Wisp will click, type and read its windows."
        case .low: return "Wisp will click, type and read this app's windows while a task is running."
        }
    }
}

/// How long an approval lasts. `session` grants die with the daemon that recorded them; `always` grants persist.
public enum ApprovalGrant: String, Codable, Equatable, Sendable {
    case session, always
}

/// Outcome of `ApprovalRules.decide`.
public enum ApprovalDecision: Equatable, Sendable {
    /// Proceed without asking.
    case allowed
    /// Blocked by the user's deny list.
    case denied(reason: String)
    /// Blocked by the built-in safety list; cannot be overridden by allow lists or grants.
    case forbidden(reason: String)
    /// Ask the user before controlling the app.
    case needsApproval(risk: Risk, subtitle: String)
}

/// Per-app approval rules: which apps need a prompt, which are never controllable, and which URL hosts are blocked.
/// Patterns are fnmatch-style globs (`*` and `?`) matched case-insensitively against the bundle id and the app name.
public struct ApprovalRules: Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable {
        /// Never prompt (forbidden and deny lists still apply).
        case off
        /// Prompt only for apps on the high-risk list.
        case highRisk
        /// Prompt for every app; high-risk apps get the stronger warning.
        case all
    }

    public var mode: Mode
    public var highRisk: [String]
    public var forbidden: [String]
    public var allow: [String]
    public var deny: [String]
    public var blockedURLHosts: [String]

    public static let defaultHighRisk = [
        "com.apple.systempreferences", "com.apple.Terminal", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.mail", "com.apple.MobileSMS", "com.apple.finder",
    ]

    /// Apps Wisp refuses to control regardless of configuration: the login window, the authentication agent, and
    /// Wisp itself (so an agent cannot approve its own prompts).
    public static let defaultForbidden = ["com.apple.loginwindow", "com.apple.SecurityAgent", "sb.moe.wisp"]

    public init(mode: Mode = .highRisk, highRisk: [String] = ApprovalRules.defaultHighRisk,
                forbidden: [String] = ApprovalRules.defaultForbidden, allow: [String] = [], deny: [String] = [],
                blockedURLHosts: [String] = []) {
        self.mode = mode
        self.highRisk = highRisk
        self.forbidden = forbidden
        self.allow = allow
        self.deny = deny
        self.blockedURLHosts = blockedURLHosts
    }

    // MARK: Glob matching

    /// fnmatch-style match: `*` matches any run of characters, `?` a single character. Case-insensitive.
    public static func globMatches(_ pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern.lowercased().unicodeScalars)
        let s = Array(candidate.lowercased().unicodeScalars)
        var pi = 0, si = 0
        var starP = -1, starS = -1
        while si < s.count {
            if pi < p.count, p[pi] == "*" {
                starP = pi
                starS = si
                pi += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if starP >= 0 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// True when `pattern` glob-matches any of the candidates (nil candidates are skipped).
    public static func matches(_ pattern: String, _ candidates: [String?]) -> Bool {
        candidates.compactMap { $0 }.contains { globMatches(pattern, $0) }
    }

    private static func anyMatch(_ patterns: [String], _ candidates: [String?]) -> String? {
        patterns.first { matches($0, candidates) }
    }

    // MARK: Decision

    /// Decides whether an app may be controlled. Precedence: forbidden > deny (unless an allow pattern matches) >
    /// existing grant > high-risk list > mode `.all` > allowed. `grant` is the caller's stored grant for this app,
    /// typically from `ApprovalStore.grant(for:daemonPid:)`.
    public func decide(bundleId: String?, name: String, grant: ApprovalGrant?) -> ApprovalDecision {
        let ids: [String?] = [bundleId, name]
        let label = bundleId.map { "\(name) (\($0))" } ?? name
        if let p = ApprovalRules.anyMatch(forbidden, ids) {
            return .forbidden(reason: "\(label) is on the built-in forbidden list (\(p))")
        }
        let allowed = ApprovalRules.anyMatch(allow, ids) != nil
        if !allowed, let p = ApprovalRules.anyMatch(deny, ids) {
            return .denied(reason: "\(label) is denied by policy (\(p))")
        }
        if grant != nil { return .allowed }
        if mode == .off { return .allowed }
        if ApprovalRules.anyMatch(highRisk, ids) != nil {
            return .needsApproval(risk: .high, subtitle: Risk.high.subtitle)
        }
        if mode == .all { return .needsApproval(risk: .low, subtitle: Risk.low.subtitle) }
        return .allowed
    }

    /// Convenience over `decide` using this rule set's own blocked host list.
    public func isBlocked(url: String) -> Bool { ApprovalRules.isBlocked(url: url, hosts: blockedURLHosts) }

    // MARK: URL blocking

    /// True when the URL's host matches one of `hosts`. A pattern matches the host itself or any parent domain, so
    /// `example.com` also blocks `mail.example.com`; globs (`*.example.com`, `*bank*`) are applied to the full host.
    /// A bare host or host/path without a scheme is accepted. Ports and a trailing dot are ignored.
    public static func isBlocked(url: String, hosts: [String]) -> Bool {
        guard !hosts.isEmpty, let host = host(of: url) else { return false }
        let labels = host.split(separator: ".").map(String.init)
        var suffixes: [String] = []
        for i in 0..<labels.count { suffixes.append(labels[i...].joined(separator: ".")) }
        for pattern in hosts {
            let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !p.isEmpty else { continue }
            let bare = p.hasSuffix(".") ? String(p.dropLast()) : p
            if suffixes.contains(where: { globMatches(bare, $0) }) { return true }
        }
        return false
    }

    /// Extracts the lower-cased host of a URL string; tolerates a missing scheme.
    public static func host(of url: String) -> String? {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var candidate = s
        if !s.contains("://") {
            // "example.com/x", "//example.com", "user@example.com:8080"
            candidate = "https://" + (s.hasPrefix("//") ? String(s.dropFirst(2)) : s)
        }
        guard let c = URLComponents(string: candidate), var h = c.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("[") { return nil } // IPv6 literals are never matched by host patterns
        return h
    }
}

/// Persisted approvals: `{"always": {bundleId: ISO-8601 date}, "session": {bundleId: daemon pid}}`.
/// Session grants only count while the daemon that recorded them is the one asking (pid match). Thread-safe.
public final class ApprovalStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var always: [String: String] = [:]
    private var session: [String: Int32] = [:]

    private struct File: Codable {
        var always: [String: String]?
        var session: [String: Int32]?
    }

    public init(url: URL) {
        self.url = url
        load()
    }

    // MARK: Mutation

    /// Records a grant. A session grant is tagged with the daemon pid; an `always` grant records the time.
    public func grant(_ grant: ApprovalGrant, for bundleId: String, daemonPid: Int32) {
        lock.lock(); defer { lock.unlock() }
        switch grant {
        case .always:
            always[bundleId] = ApprovalStore.formatter.string(from: Date())
            session.removeValue(forKey: bundleId)
        case .session:
            session[bundleId] = daemonPid
        }
        save()
    }

    /// Removes every grant for the app.
    public func revoke(_ bundleId: String) {
        lock.lock(); defer { lock.unlock() }
        always.removeValue(forKey: bundleId)
        session.removeValue(forKey: bundleId)
        save()
    }

    /// Removes all grants.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        always = [:]
        session = [:]
        save()
    }

    // MARK: Queries

    /// The effective grant for an app: `always` wins; a session grant counts only when it was recorded by `daemonPid`.
    public func grant(for bundleId: String, daemonPid: Int32) -> ApprovalGrant? {
        lock.lock(); defer { lock.unlock() }
        if always[bundleId] != nil { return .always }
        if let pid = session[bundleId], pid == daemonPid { return .session }
        return nil
    }

    /// The date an `always` grant was recorded, if any.
    public func grantedAt(_ bundleId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return always[bundleId].flatMap { ApprovalStore.formatter.date(from: $0) }
    }

    /// All grants, sorted by bundle id. Session grants from other daemons are included unless `daemonPid` is given.
    public func list(daemonPid: Int32? = nil) -> [(bundleId: String, grant: ApprovalGrant)] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: ApprovalGrant] = [:]
        for (id, pid) in session where daemonPid == nil || pid == daemonPid { out[id] = .session }
        for id in always.keys { out[id] = .always }
        return out.keys.sorted().map { (bundleId: $0, grant: out[$0]!) }
    }

    /// Re-reads the file (e.g. after the CLI edited it).
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        load()
    }

    // MARK: Persistence (callers hold the lock)

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func load() {
        always = [:]
        session = [:]
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        always = f.always ?? [:]
        session = f.session ?? [:]
    }

    private func save() {
        let f = File(always: always, session: session)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(f) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
