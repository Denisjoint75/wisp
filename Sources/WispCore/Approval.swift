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
/// Patterns are fnmatch-style globs matched case-insensitively against the bundle id and the app name. This glob
/// dialect supports `*` (any run of characters) and `?` (exactly one character); `Policy.matches`, which the older
/// `deny`/`allow`/`background` lists use, only supports `*` and treats `?` literally.
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
    ///
    /// Hosts and patterns are compared in one form: lower-case ASCII with internationalized labels in punycode
    /// (`xn--bcher-kva.example`), the form `host(of:)` returns. Write patterns in punycode; a Unicode pattern is
    /// converted the same way, but a glob inside a non-ASCII label is matched against that label's punycode text.
    public static func isBlocked(url: String, hosts: [String]) -> Bool {
        guard !hosts.isEmpty, let host = host(of: url) else { return false }
        let labels = host.split(separator: ".").map(String.init)
        var suffixes: [String] = []
        for i in 0..<labels.count { suffixes.append(labels[i...].joined(separator: ".")) }
        for pattern in hosts {
            let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            let bare = asciiHost(p.hasSuffix(".") ? String(p.dropLast()) : p)
            if suffixes.contains(where: { globMatches(bare, $0) }) { return true }
        }
        return false
    }

    /// Extracts the host of a URL string in lower-case ASCII (punycode) form; tolerates a missing scheme.
    ///
    /// Special (WHATWG) schemes treat a backslash like a slash, so for scheme-less, `http` and `https` URLs every
    /// `\` is replaced with `/` before parsing: `https://example.com\@evil.com/` is `example.com`, not `evil.com`
    /// (which is what an RFC 3986 parser makes of it).
    public static func host(of url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let scheme = s.range(of: "://").map { String(s[..<$0.lowerBound]).lowercased() }
        if scheme == nil || scheme == "http" || scheme == "https" { s = s.replacingOccurrences(of: "\\", with: "/") }
        var candidate = s
        if scheme == nil {
            // "example.com/x", "//example.com", "user@example.com:8080"
            candidate = "https://" + (s.hasPrefix("//") ? String(s.dropFirst(2)) : s)
        }
        guard let c = URLComponents(string: candidate), let raw = c.host, !raw.isEmpty else { return nil }
        var h = asciiHost(raw)
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        if h.hasPrefix("[") { return nil } // IPv6 literals are never matched by host patterns
        return h
    }

    // MARK: IDNA

    /// Lower-cases a host and converts every label with non-ASCII characters to its `xn--` punycode form (RFC 3492)
    /// after NFC normalization. Foundation decodes punycode on input and percent-encodes non-ASCII hosts on output,
    /// so this is the one canonical form hosts and patterns are compared in. ASCII input is returned lower-cased.
    public static func asciiHost(_ host: String) -> String {
        let lowered = host.lowercased().precomposedStringWithCanonicalMapping
        return lowered.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let scalars = Array(label.unicodeScalars.map { $0.value })
            if scalars.allSatisfy({ $0 < 0x80 }) { return String(label) }
            return "xn--" + punycode(scalars)
        }.joined(separator: ".")
    }

    /// RFC 3492 punycode encoding of one label (without the `xn--` prefix).
    static func punycode(_ input: [UInt32]) -> String {
        let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700
        var n: UInt32 = 128, delta = 0, bias = 72
        var out: [UInt8] = input.filter { $0 < 0x80 }.map { UInt8($0) }
        let basic = out.count
        var handled = basic
        if basic > 0 { out.append(UInt8(ascii: "-")) }
        func adapt(_ d: Int, _ numPoints: Int, _ first: Bool) -> Int {
            var d = first ? d / damp : d / 2
            d += d / numPoints
            var k = 0
            while d > ((base - tmin) * tmax) / 2 { d /= base - tmin; k += base }
            return k + (base - tmin + 1) * d / (d + skew)
        }
        func digit(_ d: Int) -> UInt8 { d < 26 ? UInt8(ascii: "a") + UInt8(d) : UInt8(ascii: "0") + UInt8(d - 26) }
        while handled < input.count {
            let m = input.filter { $0 >= n }.min()!
            delta += Int(m - n) * (handled + 1)
            n = m
            for c in input {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                    if q < t { break }
                    out.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                out.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Persisted approvals: `{"always": {bundleId: ISO-8601 date}, "session": {bundleId: daemon pid}}`.
/// Session grants only count while the daemon that recorded them is the one asking (pid match). Thread-safe.
public final class ApprovalStore: @unchecked Sendable {
    public let url: URL
    /// Called (outside the lock) with a description of every failed write, so the daemon can log it.
    public var onError: ((String) -> Void)?
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

    /// Records a grant. A session grant is tagged with the daemon pid; an `always` grant records the time. Returns
    /// false when the file could not be written (the grant still applies in memory).
    @discardableResult
    public func grant(_ grant: ApprovalGrant, for bundleId: String, daemonPid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch grant {
        case .always:
            always[bundleId] = ApprovalStore.formatter.string(from: Date())
            session.removeValue(forKey: bundleId)
        case .session:
            session[bundleId] = daemonPid
        }
        return save()
    }

    /// Removes every grant for the app. Returns false when the file could not be written.
    @discardableResult
    public func revoke(_ bundleId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        always.removeValue(forKey: bundleId)
        session.removeValue(forKey: bundleId)
        return save()
    }

    /// Removes all grants. Returns false when the file could not be written.
    @discardableResult
    public func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        always = [:]
        session = [:]
        return save()
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

    /// Writes the file: the data goes to a sibling temp file created with mode 0600, which is then renamed over
    /// the destination, so the grants are never readable by other users and never half-written. Failures are
    /// reported through `onError` and as a false return.
    private func save() -> Bool {
        let f = File(always: always, session: session)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let failure: String
        do {
            let data = try enc.encode(f)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
            }
            if rename(tmp.path, url.path) != 0 {
                let err = errno
                try? FileManager.default.removeItem(at: tmp)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
            return true
        } catch {
            failure = "could not save approvals to \(url.path): \(error)"
        }
        if let cb = onError { DispatchQueue.global().async { cb(failure) } }
        return false
    }
}
