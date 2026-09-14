import XCTest
@testable import WispCore

final class ApprovalRulesTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(ApprovalRules.globMatches("com.apple.*", "com.apple.finder"))
        XCTAssertTrue(ApprovalRules.globMatches("COM.APPLE.FINDER", "com.apple.Finder"))
        XCTAssertTrue(ApprovalRules.globMatches("*.Terminal", "com.apple.Terminal"))
        XCTAssertTrue(ApprovalRules.globMatches("*", "anything"))
        XCTAssertTrue(ApprovalRules.globMatches("*", ""))
        XCTAssertTrue(ApprovalRules.globMatches("com.apple.?ail", "com.apple.mail"))
        XCTAssertTrue(ApprovalRules.globMatches("*pass*", "com.1password.1password"))
        XCTAssertTrue(ApprovalRules.globMatches("a*b*c", "axxbyyc"))
        XCTAssertFalse(ApprovalRules.globMatches("com.apple.?ail", "com.apple.email"))
        XCTAssertFalse(ApprovalRules.globMatches("com.apple.*", "org.mozilla.firefox"))
        XCTAssertFalse(ApprovalRules.globMatches("a*b", "acbd"))
        XCTAssertFalse(ApprovalRules.globMatches("", "x"))
        // name is matched too
        XCTAssertTrue(ApprovalRules.matches("Safari", [nil, "Safari"]))
        XCTAssertFalse(ApprovalRules.matches("Safari", [nil]))
    }

    func testForbiddenBeatsAllowAndGrant() {
        var r = ApprovalRules()
        r.allow = ["*"]
        let d = r.decide(bundleId: "com.apple.loginwindow", name: "loginwindow", grant: .always)
        guard case .forbidden = d else { return XCTFail("expected forbidden, got \(d)") }
        // Wisp itself is forbidden by default, also when matched by name only.
        guard case .forbidden = r.decide(bundleId: nil, name: "sb.moe.wisp", grant: nil) else { return XCTFail() }
    }

    func testAllowBeatsDeny() {
        var r = ApprovalRules()
        r.deny = ["com.google.*"]
        guard case .denied(let reason) = r.decide(bundleId: "com.google.Chrome", name: "Google Chrome", grant: nil) else { return XCTFail() }
        XCTAssertTrue(reason.contains("com.google.*"))
        r.allow = ["com.google.Chrome"]
        XCTAssertEqual(r.decide(bundleId: "com.google.Chrome", name: "Google Chrome", grant: nil), .allowed)
        // deny by app name
        r.deny = ["Slack"]
        guard case .denied = r.decide(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", grant: nil) else { return XCTFail() }
        // a grant does not override deny
        guard case .denied = r.decide(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", grant: .always) else { return XCTFail() }
    }

    func testGrantBeatsHighRisk() {
        let r = ApprovalRules()
        XCTAssertEqual(r.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: .session), .allowed)
        XCTAssertEqual(r.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: .always), .allowed)
        XCTAssertEqual(r.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: nil),
                       .needsApproval(risk: .high, subtitle: Risk.high.subtitle))
    }

    func testModes() {
        var r = ApprovalRules()
        // highRisk (default): only listed apps prompt
        XCTAssertEqual(r.decide(bundleId: "com.apple.TextEdit", name: "TextEdit", grant: nil), .allowed)
        guard case .needsApproval(.high, _) = r.decide(bundleId: "com.apple.finder", name: "Finder", grant: nil) else { return XCTFail() }
        // all: everything prompts, high-risk keeps the strong warning
        r.mode = .all
        guard case .needsApproval(.low, let sub) = r.decide(bundleId: "com.apple.TextEdit", name: "TextEdit", grant: nil) else { return XCTFail() }
        XCTAssertEqual(sub, Risk.low.subtitle)
        guard case .needsApproval(.high, _) = r.decide(bundleId: "com.apple.finder", name: "Finder", grant: nil) else { return XCTFail() }
        XCTAssertEqual(r.decide(bundleId: "com.apple.TextEdit", name: "TextEdit", grant: .session), .allowed)
        // off: never prompts, but forbidden and deny still apply
        r.mode = .off
        XCTAssertEqual(r.decide(bundleId: "com.apple.finder", name: "Finder", grant: nil), .allowed)
        r.deny = ["com.apple.finder"]
        guard case .denied = r.decide(bundleId: "com.apple.finder", name: "Finder", grant: nil) else { return XCTFail() }
        guard case .forbidden = r.decide(bundleId: "com.apple.SecurityAgent", name: "SecurityAgent", grant: nil) else { return XCTFail() }
    }

    func testDefaults() {
        let r = ApprovalRules()
        XCTAssertEqual(r.mode, .highRisk)
        XCTAssertTrue(r.highRisk.contains("com.apple.systempreferences"))
        XCTAssertEqual(r.forbidden, ["com.apple.loginwindow", "com.apple.SecurityAgent", "sb.moe.wisp"])
        XCTAssertTrue(r.allow.isEmpty && r.deny.isEmpty && r.blockedURLHosts.isEmpty)
    }

    func testURLBlocking() {
        let hosts = ["example.com", "*.bank.test", "*wallet*"]
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://example.com/login", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://mail.example.com", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "http://a.b.example.com:8080/x?y=1", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "HTTPS://EXAMPLE.COM.", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "example.com/path", hosts: hosts), "scheme-less URL")
        XCTAssertTrue(ApprovalRules.isBlocked(url: "online.bank.test", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://my.wallet.io", hosts: hosts))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://bank.test", hosts: hosts), "*.bank.test needs a subdomain")
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://notexample.com", hosts: hosts))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://example.com.evil.net", hosts: hosts))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://example.org/?q=example.com", hosts: hosts))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://example.com", hosts: []))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "", hosts: hosts))
        XCTAssertFalse(ApprovalRules.isBlocked(url: "about:blank", hosts: hosts))
        XCTAssertEqual(ApprovalRules.host(of: "https://User@Sub.Example.com:443/p"), "sub.example.com")
        var r = ApprovalRules()
        r.blockedURLHosts = ["example.com"]
        XCTAssertTrue(r.isBlocked(url: "https://www.example.com"))
    }

    func testURLBackslashNormalization() {
        // WHATWG parsers treat "\\" like "/" in special schemes; an RFC 3986 parser reads the same text as user info
        // followed by host evil.com. The host must be what the browser will actually load.
        let hosts = ["example.com"]
        XCTAssertEqual(ApprovalRules.host(of: "https://example.com\\@evil.com/"), "example.com")
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://example.com\\@evil.com/", hosts: hosts))
        XCTAssertEqual(ApprovalRules.host(of: "http://example.com\\evil.com"), "example.com")
        XCTAssertEqual(ApprovalRules.host(of: "example.com\\@evil.com"), "example.com", "scheme-less input is normalized too")
        XCTAssertEqual(ApprovalRules.host(of: "HTTPS://example.com\\@evil.com"), "example.com", "scheme is matched case-insensitively")
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://evil.com/?next=example.com\\", hosts: hosts))
        // Non-special schemes keep their backslashes.
        XCTAssertEqual(ApprovalRules.host(of: "ftp://example.com\\@evil.com/"), "evil.com")
    }

    func testIDNHosts() {
        // Hosts are compared in punycode; patterns are written in punycode (a Unicode pattern is converted too).
        XCTAssertEqual(ApprovalRules.punycode(Array("bücher".unicodeScalars.map { $0.value })), "bcher-kva")
        XCTAssertEqual(ApprovalRules.asciiHost("Bücher.Example"), "xn--bcher-kva.example")
        XCTAssertEqual(ApprovalRules.asciiHost("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        XCTAssertEqual(ApprovalRules.asciiHost("plain.example"), "plain.example")
        XCTAssertEqual(ApprovalRules.host(of: "https://bücher.example/x"), "xn--bcher-kva.example")
        XCTAssertEqual(ApprovalRules.host(of: "https://xn--bcher-kva.example/"), "xn--bcher-kva.example", "punycode input stays punycode")
        XCTAssertEqual(ApprovalRules.host(of: "https://BÜCHER.example"), "xn--bcher-kva.example")
        let hosts = ["xn--bcher-kva.example"]
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://bücher.example/login", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://xn--bcher-kva.example/", hosts: hosts))
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://shop.bücher.example/", hosts: hosts), "parent-domain match in punycode")
        XCTAssertTrue(ApprovalRules.isBlocked(url: "https://bücher.example/", hosts: ["bücher.example"]), "a Unicode pattern is converted")
        XCTAssertFalse(ApprovalRules.isBlocked(url: "https://bucher.example/", hosts: hosts))
    }
}

final class PolicyApprovalTests: XCTestCase {
    func testPolicyDefaultsAndRoundTrip() {
        let d = Policy()
        XCTAssertEqual(d.approval, "high-risk")
        XCTAssertEqual(d.highRisk, ApprovalRules.defaultHighRisk)
        XCTAssertEqual(d.forbidden, ApprovalRules.defaultForbidden)
        XCTAssertTrue(d.blockedURLs.isEmpty)
        // Apple's sensitive apps moved from deny to the approval tiers; password managers stay denied.
        for id in ["com.apple.Terminal", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.loginwindow", "com.apple.SecurityAgent"] {
            XCTAssertFalse(d.deny.contains(id), "\(id) must not be on the deny list")
        }
        XCTAssertTrue(d.deny.contains("com.1password.1password"))
        var p = Policy()
        p.approval = "all"
        p.highRisk = ["com.example.*"]
        p.forbidden = ["com.example.bank"]
        p.blockedURLs = ["example.com", "*.bank.test"]
        let j = p.json
        XCTAssertEqual(j["approval"].string, "all")
        XCTAssertEqual(j["highRisk"].stringArray, ["com.example.*"])
        XCTAssertEqual(j["forbidden"].stringArray, ["com.example.bank"])
        XCTAssertEqual(j["blockedURLs"].stringArray, ["example.com", "*.bank.test"])
        XCTAssertEqual(Policy.from(json: j), p)
        XCTAssertEqual(Policy.from(json: ["approval": "OFF"]).approval, "off")
        XCTAssertEqual(Policy.from(json: ["approval": "bogus"]).approval, "high-risk", "unknown modes fall back to the default")
        XCTAssertEqual(Policy.from(json: [:]).blockedURLs, [])
    }

    func testPolicyToApprovalRules() {
        var p = Policy()
        p.approval = "all"
        p.highRisk = ["com.example.hi"]
        p.forbidden = ["com.example.never"]
        p.allow = ["com.example.ok"]
        p.deny = ["com.example.no"]
        p.blockedURLs = ["example.com"]
        let r = p.approvalRules
        XCTAssertEqual(r.mode, .all)
        XCTAssertEqual(r.highRisk, ["com.example.hi"])
        XCTAssertEqual(r.allow, ["com.example.ok"])
        XCTAssertEqual(r.deny, ["com.example.no"])
        XCTAssertEqual(r.blockedURLHosts, ["example.com"])
        // The built-in forbidden entries are always present, the policy's own come after them.
        XCTAssertEqual(r.forbidden, ApprovalRules.defaultForbidden + ["com.example.never"])
        p.forbidden = []
        XCTAssertEqual(p.approvalRules.forbidden, ApprovalRules.defaultForbidden, "an empty list cannot remove the built-in entries")
        p.approval = "off"
        XCTAssertEqual(p.approvalRules.mode, .off)
        p.approval = "high-risk"
        XCTAssertEqual(p.approvalRules.mode, .highRisk)
        XCTAssertEqual(Policy.approvalMode("ALL"), .all)
        XCTAssertEqual(Policy.approvalMode("bogus"), .highRisk)
    }

    func testDaemonDefaultPrecedence() {
        // What the daemon enforces out of the box: Policy() mapped to rules, no stored grants.
        var p = Policy()
        p.allow = ["*"]
        let r = p.approvalRules
        guard case .forbidden = r.decide(bundleId: "com.apple.loginwindow", name: "loginwindow", grant: .always) else { return XCTFail("loginwindow must be forbidden even when allowed and granted") }
        guard case .forbidden = r.decide(bundleId: "com.apple.SecurityAgent", name: "SecurityAgent", grant: nil) else { return XCTFail() }
        guard case .forbidden = r.decide(bundleId: "sb.moe.wisp", name: "Wisp", grant: nil) else { return XCTFail() }

        let d = Policy().approvalRules
        guard case .needsApproval(.high, _) = d.decide(bundleId: "com.apple.systempreferences", name: "System Settings", grant: nil) else { return XCTFail("System Settings is high risk") }
        guard case .needsApproval(.high, _) = d.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: nil) else { return XCTFail("Terminal is high risk, not denied") }
        guard case .needsApproval(.high, _) = d.decide(bundleId: "com.apple.keychainaccess", name: "Keychain Access", grant: nil) else { return XCTFail() }
        guard case .needsApproval(.high, _) = d.decide(bundleId: "com.apple.Passwords", name: "Passwords", grant: nil) else { return XCTFail() }
        guard case .denied = d.decide(bundleId: "com.1password.1password", name: "1Password", grant: nil) else { return XCTFail("password managers are denied") }
        guard case .denied = d.decide(bundleId: "com.bitwarden.desktop", name: "Bitwarden", grant: .always) else { return XCTFail("a grant does not override deny") }
        XCTAssertEqual(d.decide(bundleId: "com.apple.TextEdit", name: "TextEdit", grant: nil), .allowed)
        XCTAssertEqual(d.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: .session), .allowed, "a stored grant skips the prompt")
        // Mode off: no prompts, but forbidden and deny still hold.
        var off = Policy()
        off.approval = "off"
        XCTAssertEqual(off.approvalRules.decide(bundleId: "com.apple.Terminal", name: "Terminal", grant: nil), .allowed)
        guard case .denied = off.approvalRules.decide(bundleId: "com.1password.1password", name: "1Password", grant: nil) else { return XCTFail() }
        guard case .forbidden = off.approvalRules.decide(bundleId: "com.apple.loginwindow", name: "loginwindow", grant: nil) else { return XCTFail() }
    }
}

final class ApprovalStoreTests: XCTestCase {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-approval-\(UUID().uuidString)", isDirectory: true)
        return dir.appendingPathComponent("approvals.json")
    }

    func testRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ApprovalStore(url: url)
        XCTAssertNil(store.grant(for: "com.apple.finder", daemonPid: 1))
        XCTAssertTrue(store.list().isEmpty)

        store.grant(.always, for: "com.apple.finder", daemonPid: 1)
        store.grant(.session, for: "com.apple.Terminal", daemonPid: 1)
        XCTAssertEqual(store.grant(for: "com.apple.finder", daemonPid: 1), .always)
        XCTAssertEqual(store.grant(for: "com.apple.finder", daemonPid: 99), .always, "always grants ignore the pid")
        XCTAssertEqual(store.grant(for: "com.apple.Terminal", daemonPid: 1), .session)
        XCTAssertNil(store.grant(for: "com.apple.Terminal", daemonPid: 2), "session grant from another daemon is ignored")
        XCTAssertNotNil(store.grantedAt("com.apple.finder"))
        XCTAssertNil(store.grantedAt("com.apple.Terminal"))

        // file format
        let data = try Data(contentsOf: url)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let always = try XCTUnwrap(j["always"] as? [String: String])
        let session = try XCTUnwrap(j["session"] as? [String: Int])
        XCTAssertTrue(always["com.apple.finder"]!.hasSuffix("Z"))
        XCTAssertEqual(session["com.apple.Terminal"], 1)

        // a fresh store re-reads the file
        let reopened = ApprovalStore(url: url)
        XCTAssertEqual(reopened.grant(for: "com.apple.finder", daemonPid: 5), .always)
        XCTAssertEqual(reopened.grant(for: "com.apple.Terminal", daemonPid: 1), .session)
        XCTAssertNil(reopened.grant(for: "com.apple.Terminal", daemonPid: 5))
        XCTAssertEqual(reopened.list().map { $0.bundleId }, ["com.apple.Terminal", "com.apple.finder"])
        XCTAssertEqual(reopened.list(daemonPid: 5).map { $0.bundleId }, ["com.apple.finder"])
        XCTAssertEqual(reopened.list(daemonPid: 5).first?.grant, .always)

        // upgrading session -> always drops the session entry; revoke and clear
        reopened.grant(.always, for: "com.apple.Terminal", daemonPid: 1)
        XCTAssertEqual(reopened.grant(for: "com.apple.Terminal", daemonPid: 7), .always)
        reopened.revoke("com.apple.Terminal")
        XCTAssertNil(reopened.grant(for: "com.apple.Terminal", daemonPid: 1))
        reopened.clear()
        XCTAssertTrue(reopened.list().isEmpty)
        store.reload()
        XCTAssertNil(store.grant(for: "com.apple.finder", daemonPid: 1))
    }

    func testMissingOrCorruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = ApprovalStore(url: url)
        XCTAssertTrue(store.list().isEmpty)
        store.grant(.session, for: "x", daemonPid: 3)
        XCTAssertEqual(ApprovalStore(url: url).grant(for: "x", daemonPid: 3), .session)
    }

    func testSaveFailureIsReported() throws {
        // The "directory" is a regular file, so the store cannot create its temp file: the grant stays in memory,
        // the write reports false and onError fires.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-approval-\(UUID().uuidString)")
        try Data("x".utf8).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ApprovalStore(url: dir.appendingPathComponent("approvals.json"))
        let reported = expectation(description: "onError")
        store.onError = { msg in
            XCTAssertTrue(msg.contains("approvals.json"), msg)
            reported.fulfill()
        }
        XCTAssertFalse(store.grant(.always, for: "com.apple.finder", daemonPid: 1))
        XCTAssertEqual(store.grant(for: "com.apple.finder", daemonPid: 1), .always, "the grant still applies in memory")
        wait(for: [reported], timeout: 2)
    }

    func testSavedFileIsPrivate() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ApprovalStore(url: url)
        XCTAssertTrue(store.grant(.session, for: "x", daemonPid: 3))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["approvals.json"], "no temp file is left behind")
    }

    func testConcurrentAccess() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ApprovalStore(url: url)
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            store.grant(i % 2 == 0 ? .always : .session, for: "app\(i)", daemonPid: 1)
            _ = store.grant(for: "app\(i)", daemonPid: 1)
            _ = store.list()
        }
        XCTAssertEqual(store.list(daemonPid: 1).count, 64)
    }
}
