import XCTest
@testable import WispCore

final class InstructionsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeUser(_ stem: String, _ text: String) throws {
        try text.write(to: tempDir.appendingPathComponent(stem + ".md"), atomically: true, encoding: .utf8)
    }

    private let fixtureBuiltin: [String: String] = [
        "_browser": "## Browser\n\nOpen a new tab.",
        "com.example.App": "## Example\n\n- builtin guidance",
        "Example": "## Example\n\n- builtin guidance",
        "com.example.Other": "## Other\n\n- other guidance",
    ]

    private func catalog(_ mode: InstructionCatalog.Mode = .merge) -> InstructionCatalog {
        InstructionCatalog(builtin: fixtureBuiltin, userDir: tempDir, mode: mode)
    }

    // MARK: candidates

    func testCandidateOrderAndDedupe() {
        let c = catalog().candidates(bundleId: "com.example.App", bundleName: "Example", localizedName: "Example",
                                     folderName: "Example App")
        XCTAssertEqual(c, ["com.example.App", "Example", "Example App"])
        XCTAssertEqual(catalog().candidates(bundleId: nil, bundleName: "", localizedName: "  ", folderName: nil), [])
        XCTAssertEqual(catalog().candidates(bundleId: nil, bundleName: nil, localizedName: "Solo", folderName: nil), ["Solo"])
    }

    func testMusicOverrideAddsAppleMusicFirst() {
        let c = catalog().candidates(bundleId: "com.apple.Music", bundleName: "Music", localizedName: "Music", folderName: "Music")
        XCTAssertEqual(c, ["AppleMusic", "com.apple.Music", "Music"])
    }

    // MARK: browser detection

    func testIsWebBrowserFromInfoDictionary() {
        let info: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLName": "Web", "CFBundleURLSchemes": ["HTTP", "https"]],
            ],
        ]
        XCTAssertTrue(InstructionCatalog.isWebBrowser(infoDictionary: info, bundleId: "com.example.Browser"))
        let notBrowser: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["slack"]]]]
        XCTAssertFalse(InstructionCatalog.isWebBrowser(infoDictionary: notBrowser, bundleId: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(InstructionCatalog.isWebBrowser(infoDictionary: nil, bundleId: "com.example.App"))
        XCTAssertFalse(InstructionCatalog.isWebBrowser(infoDictionary: nil, bundleId: nil))
    }

    func testIsWebBrowserFromKnownBundleId() {
        XCTAssertTrue(InstructionCatalog.isWebBrowser(infoDictionary: nil, bundleId: "com.apple.Safari"))
        XCTAssertTrue(InstructionCatalog.isWebBrowser(infoDictionary: [:], bundleId: "org.mozilla.firefox"))
        XCTAssertTrue(InstructionCatalog.isWebBrowser(infoDictionary: nil, bundleId: "com.google.Chrome"))
    }

    // MARK: compose

    func testComposeJoinsWithBlankLineAndBrowserBlockFirst() {
        let c = catalog().compose(candidates: ["com.example.Other"], isBrowser: true)
        XCTAssertEqual(c.text, "## Browser\n\nOpen a new tab.\n\n## Other\n\n- other guidance")
        XCTAssertEqual(c.pieces.map(\.stem), ["_browser", "com.example.Other"])
        XCTAssertEqual(c.pieces.map(\.source), ["builtin", "builtin"])
    }

    func testComposeDedupesIdenticalTexts() {
        let c = catalog().compose(candidates: ["com.example.App", "Example"], isBrowser: false)
        XCTAssertEqual(c.text, "## Example\n\n- builtin guidance")
        XCTAssertEqual(c.pieces.map(\.stem), ["com.example.App"])
    }

    func testComposeNilWhenNothingMatches() {
        let c = catalog().compose(candidates: ["com.unknown.App"], isBrowser: false)
        XCTAssertNil(c.text)
        XCTAssertTrue(c.pieces.isEmpty)
    }

    func testComposeSkipsEmptyUserFiles() throws {
        try writeUser("com.example.App", "  \n\n")
        let c = catalog().compose(candidates: ["com.example.App"], isBrowser: false)
        XCTAssertEqual(c.text, "## Example\n\n- builtin guidance")
        XCTAssertEqual(c.pieces.map(\.source), ["builtin"])
    }

    func testMergeUserFileReplacesBuiltinOfSameStem() throws {
        try writeUser("com.example.App", "## Mine\n\n- user guidance\n")
        let c = catalog(.merge).compose(candidates: ["com.example.App", "com.example.Other"], isBrowser: true)
        XCTAssertEqual(c.text, "## Browser\n\nOpen a new tab.\n\n## Mine\n\n- user guidance\n\n## Other\n\n- other guidance")
        XCTAssertEqual(c.pieces.map(\.source), ["builtin", "user", "builtin"])
    }

    func testMergeAddsUserFileForUnknownStem() throws {
        try writeUser("com.custom.App", "## Custom")
        let c = catalog(.merge).compose(candidates: ["com.custom.App"], isBrowser: false)
        XCTAssertEqual(c.text, "## Custom")
        XCTAssertEqual(c.pieces.map(\.source), ["user"])
    }

    func testReplaceDropsAllBuiltinsWhenAnyUserFileMatches() throws {
        try writeUser("Example", "## Mine")
        let c = catalog(.replace).compose(candidates: ["com.example.App", "Example", "com.example.Other"], isBrowser: true)
        XCTAssertEqual(c.text, "## Mine")
        XCTAssertEqual(c.pieces.map(\.stem), ["Example"])
    }

    func testReplaceFallsBackToBuiltinsWithoutUserFiles() {
        let c = catalog(.replace).compose(candidates: ["com.example.App"], isBrowser: true)
        XCTAssertEqual(c.text, "## Browser\n\nOpen a new tab.\n\n## Example\n\n- builtin guidance")
    }

    func testReplaceUserBrowserFileKeepsBrowserBlock() throws {
        try writeUser("_browser", "## My browser rules")
        let c = catalog(.replace).compose(candidates: ["com.example.App"], isBrowser: true)
        XCTAssertEqual(c.text, "## My browser rules")
    }

    func testOffReturnsNothing() throws {
        try writeUser("com.example.App", "## Mine")
        let c = catalog(.off).compose(candidates: ["com.example.App"], isBrowser: true)
        XCTAssertNil(c.text)
        XCTAssertTrue(c.pieces.isEmpty)
    }

    func testLookup() throws {
        XCTAssertEqual(catalog().lookup(stem: "com.example.App")?.source, "builtin")
        XCTAssertNil(catalog().lookup(stem: "nope"))
        XCTAssertNil(catalog().lookup(stem: "../com.example.App"))
        try writeUser("com.example.App", "## Mine")
        let hit = catalog().lookup(stem: "com.example.App")
        XCTAssertEqual(hit?.text, "## Mine")
        XCTAssertEqual(hit?.source, "user")
    }

    // MARK: generated table matches the resource files

    func testBuiltinTableMatchesResourceFiles() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppInstructions", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(names.isEmpty, "no resource files found at \(dir.path)")
        let stems = Set(names.map { String($0.dropLast(3)) })
        XCTAssertEqual(Set(BuiltinInstructions.text.keys), stems, "run scripts/gen-instructions.sh")
        for name in names {
            let file = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = String(name.dropLast(3))
            XCTAssertEqual(BuiltinInstructions.text[stem]?.trimmingCharacters(in: .whitespacesAndNewlines), file,
                           "builtin \(stem) is stale; run scripts/gen-instructions.sh")
            XCTAssertTrue(file.hasPrefix("## "), "\(name) must start with a '## Title' heading")
        }
        XCTAssertEqual(BuiltinInstructions.text.count, 19)
        XCTAssertNotNil(BuiltinInstructions.text[InstructionCatalog.browserStem])
        XCTAssertNotNil(BuiltinInstructions.text["chrome-tab"])
        XCTAssertNotNil(BuiltinInstructions.text["com.apple.Music"])
    }
}
