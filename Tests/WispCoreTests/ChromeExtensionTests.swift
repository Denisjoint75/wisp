import XCTest
@testable import WispCore

final class ChromeExtensionTests: XCTestCase {
    /// The manifest shipped in integrations/chrome-extension.
    private func repoManifest() throws -> JSON {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir = dir.deletingLastPathComponent() }
        let url = dir.appendingPathComponent("integrations/chrome-extension/manifest.json")
        return try JSON.parse(try Data(contentsOf: url))
    }

    func testIdMatchesThePinnedManifestKey() throws {
        let m = try repoManifest()
        let key = try XCTUnwrap(m["key"].string)
        XCTAssertEqual(ChromeExtension.id(forKey: key), ChromeExtension.id)
        XCTAssertEqual(ChromeExtension.id.count, 32)
        XCTAssertTrue(ChromeExtension.id.allSatisfy { ("a"..."p").contains($0) })
        XCTAssertNil(ChromeExtension.id(forKey: "not base64!"))
    }

    func testManifestDeclaresWhatTheBridgeNeeds() throws {
        let m = try repoManifest()
        XCTAssertEqual(m["manifest_version"].int, 3)
        let perms = Set((m["permissions"].array ?? []).compactMap { $0.string })
        XCTAssertTrue(perms.isSuperset(of: ["debugger", "tabs", "nativeMessaging", "alarms"]))
        XCTAssertEqual(m["background"]["service_worker"].string, "background.js")
        XCTAssertEqual(m["version"].string, WispVersion.string, "the extension version follows the Wisp version (scripts/set-version.sh)")
    }

    func testHostManifestAllowsOnlyTheWispExtension() {
        let j = ChromeExtension.hostManifest(launcher: "/Users/someone/Library/Application Support/Wisp/native-host.sh")
        XCTAssertEqual(j["name"].string, "sb.moe.wisp")
        XCTAssertEqual(j["type"].string, "stdio")
        XCTAssertEqual(j["path"].string, "/Users/someone/Library/Application Support/Wisp/native-host.sh")
        XCTAssertEqual(j["allowed_origins"].array?.compactMap { $0.string }, ["chrome-extension://onbeniodfnedfepagelnhdlahohkcnll/"])
    }

    func testHostLauncherScriptExecsTheBinaryAndRoundTrips() {
        // The host is a #!/bin/sh script that execs `wisp native-host`; Chrome cannot start the Mach-O directly on
        // every macOS. Paths with spaces and quotes must survive the shell quoting.
        for binary in ["/Applications/Wisp.app/Contents/MacOS/wisp", "/Users/some one/it's/wisp"] {
            let s = ChromeExtension.hostLauncherScript(binary: binary)
            XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"), "must start with a shebang")
            XCTAssertTrue(s.hasSuffix("native-host \"$@\"\n"), "must pass the browser's arguments through")
            XCTAssertEqual(ChromeExtension.hostLauncherTarget(script: s), binary)
        }
        XCTAssertEqual(ChromeExtension.hostLauncherScript(binary: "/a/wisp").components(separatedBy: "\n").last { $0.hasPrefix("exec") },
                       "exec '/a/wisp' native-host \"$@\"")
        XCTAssertNil(ChromeExtension.hostLauncherTarget(script: "#!/bin/sh\necho hi\n"))
        XCTAssertNil(ChromeExtension.hostLauncherTarget(script: "not a script"))
    }

    func testBrowserManifestLocations() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ChromeExtension.browser("chrome")?.hostManifestURL(home: home).path,
                       "/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts/sb.moe.wisp.json")
        XCTAssertEqual(ChromeExtension.browser("brave")?.hostManifestURL(home: home).path,
                       "/Users/someone/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/sb.moe.wisp.json")
        XCTAssertEqual(ChromeExtension.browser("Edge")?.bundleId, "com.microsoft.edgemac")
        XCTAssertNil(ChromeExtension.browser("firefox"))
        XCTAssertEqual(Set(ChromeExtension.browsers.map { $0.key }).count, ChromeExtension.browsers.count, "keys are unique")
    }

    func testBundledDirIsFoundFromTheSourceCheckout() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root = root.deletingLastPathComponent() }
        let dir = ChromeExtension.bundledDir(executable: root.appendingPathComponent(".build/debug/wisp").path, cwd: "/")
        XCTAssertEqual(dir?.standardizedFileURL.path, root.appendingPathComponent("integrations/chrome-extension").standardizedFileURL.path)
    }
}
