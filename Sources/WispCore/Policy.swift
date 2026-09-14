import Foundation

/// User policy loaded from `~/.config/wisp/policy.json`.
public struct Policy: Equatable {
    public var deny: [String]
    public var allow: [String]
    public var background: [String]
    public var allowSecureFields: Bool
    public var clickInterval: Double
    public var settleMin: Double
    public var settleQuiet: Double
    public var settleMax: Double
    public var cursorEnabled: Bool
    public var cursorAccent: String
    public var interventionDebounce: Double
    public var bannerEnabled: Bool
    public var chromePort: Int
    public var maxChildren: Int
    public var privateWindowField: Bool
    /// How per-app instructions are composed: `merge` (user files replace the built-in text of the same stem),
    /// `replace` (any user match drops every built-in text) or `off`. See `InstructionCatalog.Mode`.
    public var instructionsMode: String
    /// Shows the activity lens (the small sweeping ring next to the cursor or in the window corner).
    public var lensEnabled: Bool
    /// Banner template; `{app}` is replaced with the controlled app's name. See `BannerTemplate.render`.
    public var bannerText: String
    /// Suffix appended to the banner while Wisp is observing (reading the UI); empty disables it.
    public var bannerHint: String
    /// When the daemon asks the user before controlling an app: `off` (never), `high-risk` (apps matching
    /// `highRisk`) or `all` (every app; high-risk ones get the stronger warning). See `ApprovalRules.Mode`.
    public var approval: String
    /// Apps that prompt with the high-risk warning (globs against bundle id and name; see `ApprovalRules`).
    public var highRisk: [String]
    /// Apps Wisp never controls, whatever the allow list or stored grants say. The built-in entries
    /// (`ApprovalRules.defaultForbidden`) are always in effect; this list can only add to them.
    public var forbidden: [String]
    /// URL hosts Chrome tabs may not open and whose web content is refused inside app windows (see
    /// `ApprovalRules.isBlocked(url:hosts:)`; written in punycode, `example.com` also covers its subdomains).
    public var blockedURLs: [String]

    public static let instructionsModes = ["merge", "replace", "off"]
    /// Accepted `approval` values, in `ApprovalRules.Mode` order.
    public static let approvalModes = ["off", "high-risk", "all"]

    /// Password managers. Apple's own sensitive apps are covered by the approval tiers instead: Terminal, Keychain
    /// Access and Passwords prompt as high risk, the login window and SecurityAgent are forbidden outright.
    public static let defaultDeny = [
        "com.bitwarden.desktop", "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.dashlane.dashlanephonefinal", "com.nordsec.nordpass", "com.lastpass.lastpassmacdesktop",
    ]

    public init() {
        deny = Policy.defaultDeny
        allow = []
        background = []
        allowSecureFields = false
        clickInterval = 0.1
        settleMin = 0.25
        settleQuiet = 0.3
        settleMax = 5.0
        cursorEnabled = true
        cursorAccent = "#4F8BFF"
        interventionDebounce = 2.0
        bannerEnabled = true
        chromePort = 9222
        maxChildren = 60
        privateWindowField = false
        instructionsMode = "merge"
        lensEnabled = true
        bannerText = BannerTemplate.defaultText
        bannerHint = BannerTemplate.defaultHint
        approval = "high-risk"
        highRisk = ApprovalRules.defaultHighRisk
        forbidden = ApprovalRules.defaultForbidden
        blockedURLs = []
    }

    public var json: JSON {
        ["deny": .array(deny.map { .string($0) }), "allow": .array(allow.map { .string($0) }),
         "background": .array(background.map { .string($0) }), "allowSecureFields": .bool(allowSecureFields),
         "clickInterval": .number(clickInterval), "settleMin": .number(settleMin), "settleQuiet": .number(settleQuiet),
         "settleMax": .number(settleMax), "cursorEnabled": .bool(cursorEnabled), "cursorAccent": .string(cursorAccent),
         "interventionDebounce": .number(interventionDebounce), "bannerEnabled": .bool(bannerEnabled),
         "chromePort": .int(chromePort), "maxChildren": .int(maxChildren), "privateWindowField": .bool(privateWindowField),
         "instructionsMode": .string(instructionsMode), "lensEnabled": .bool(lensEnabled), "bannerText": .string(bannerText),
         "bannerHint": .string(bannerHint), "approval": .string(approval), "highRisk": .array(highRisk.map { .string($0) }),
         "forbidden": .array(forbidden.map { .string($0) }), "blockedURLs": .array(blockedURLs.map { .string($0) })]
    }

    public static func from(json j: JSON) -> Policy {
        var p = Policy()
        if let a = j["deny"].stringArray { p.deny = a }
        if let a = j["allow"].stringArray { p.allow = a }
        if let a = j["background"].stringArray { p.background = a }
        if let b = j["allowSecureFields"].bool { p.allowSecureFields = b }
        if let d = j["clickInterval"].double { p.clickInterval = max(0.02, min(d, 1)) }
        if let d = j["settleMin"].double { p.settleMin = max(0, min(d, 5)) }
        if let d = j["settleQuiet"].double { p.settleQuiet = max(0.05, min(d, 5)) }
        if let d = j["settleMax"].double { p.settleMax = max(0.2, min(d, 30)) }
        if let b = j["cursorEnabled"].bool { p.cursorEnabled = b }
        if let s = j["cursorAccent"].string { p.cursorAccent = s }
        if let d = j["interventionDebounce"].double { p.interventionDebounce = max(0, min(d, 30)) }
        if let b = j["bannerEnabled"].bool { p.bannerEnabled = b }
        if let i = j["chromePort"].int { p.chromePort = i }
        if let i = j["maxChildren"].int { p.maxChildren = max(10, min(i, 500)) }
        if let b = j["privateWindowField"].bool { p.privateWindowField = b }
        if let m = j["instructionsMode"].string?.lowercased(), Policy.instructionsModes.contains(m) { p.instructionsMode = m }
        if let b = j["lensEnabled"].bool { p.lensEnabled = b }
        if let s = j["bannerText"].string, !s.trimmingCharacters(in: .whitespaces).isEmpty { p.bannerText = s }
        if let s = j["bannerHint"].string { p.bannerHint = s }
        if let m = j["approval"].string?.lowercased(), Policy.approvalModes.contains(m) { p.approval = m }
        if let a = j["highRisk"].stringArray { p.highRisk = a }
        if let a = j["forbidden"].stringArray { p.forbidden = a }
        if let a = j["blockedURLs"].stringArray { p.blockedURLs = a }
        return p
    }

    /// The approval rule set the daemon enforces: `approval`/`highRisk`/`forbidden`/`blockedURLs` plus the
    /// `allow`/`deny` lists. The built-in forbidden entries are always included so neither the policy file nor a
    /// stored grant can make Wisp control itself or the login window.
    public var approvalRules: ApprovalRules {
        var forbid = ApprovalRules.defaultForbidden
        for f in forbidden where !forbid.contains(f) { forbid.append(f) }
        return ApprovalRules(mode: Policy.approvalMode(approval), highRisk: highRisk, forbidden: forbid, allow: allow, deny: deny,
                             blockedURLHosts: blockedURLs)
    }

    /// Maps a policy `approval` string to the rule mode; unknown values fall back to the default (`high-risk`).
    public static func approvalMode(_ s: String) -> ApprovalRules.Mode {
        switch s.lowercased() {
        case "off": return .off
        case "all": return .all
        default: return .highRisk
        }
    }

    public static func load(path: String = WispPaths.policyPath) -> Policy {
        guard let data = FileManager.default.contents(atPath: path), let j = try? JSON.parse(data) else { return Policy() }
        return from(json: j)
    }

    public func save(path: String = WispPaths.policyPath) throws {
        try json.data(pretty: true).write(to: URL(fileURLWithPath: path))
    }

    /// Glob-style match (`*` wildcard) against bundle id, name or path.
    public static func matches(_ pattern: String, _ candidates: [String]) -> Bool {
        let p = pattern.lowercased()
        for c in candidates.map({ $0.lowercased() }) {
            if p == c { return true }
            if p.contains("*") {
                let regex = "^" + NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*") + "$"
                if c.range(of: regex, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    public enum Decision { case allowed, denied }

    public func decision(bundleId: String?, name: String?, path: String?) -> Decision {
        let ids = [bundleId, name, path].compactMap { $0 }
        if allow.contains(where: { Policy.matches($0, ids) }) { return .allowed }
        if deny.contains(where: { Policy.matches($0, ids) }) { return .denied }
        return .allowed
    }

    public func usesBackground(bundleId: String?, name: String?) -> Bool {
        background.contains(where: { Policy.matches($0, [bundleId, name].compactMap { $0 }) })
    }
}

/// The "Wisp is controlling …" banner text, computed from the policy template.
public enum BannerTemplate {
    public static let defaultText = "✦ Wisp is controlling {app}  ·  Esc to stop"
    public static let defaultHint = "reading"
    public static let appPlaceholder = "{app}"

    /// Substitutes `{app}` in `template` and, when `hint` is non-empty, appends it after a " · " separator (the daemon
    /// passes the hint only while observing).
    public static func render(_ template: String, app: String, hint: String? = nil) -> String {
        var text = template.replacingOccurrences(of: appPlaceholder, with: app)
        if let h = hint?.trimmingCharacters(in: .whitespaces), !h.isEmpty { text += " · " + h }
        return text
    }
}
