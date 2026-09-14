import XCTest
@testable import WispCore

final class FramingTests: XCTestCase {
    func testRoundTrip() throws {
        var dec = Framing.Decoder()
        let a = Framing.encode(Data("hello".utf8))
        let b = Framing.encode(Data("world!".utf8))
        var all = a + b
        let firstHalf = all.prefix(7)
        all.removeFirst(7)
        XCTAssertEqual(try dec.feed(firstHalf).count, 0, "incomplete frame is buffered")
        let rest = try dec.feed(all)
        XCTAssertEqual(rest.count, 2)
        XCTAssertEqual(String(decoding: rest[0], as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: rest[1], as: UTF8.self), "world!")
    }

    func testTooLarge() {
        var dec = Framing.Decoder()
        var d = Data()
        var len = UInt32(Framing.maxFrame + 1).littleEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        XCTAssertThrowsError(try dec.feed(d))
    }
}

final class JSONTests: XCTestCase {
    func testParseAndAccess() throws {
        let j = try JSON.parse(#"{"a":1,"b":[true,"x"],"c":{"d":2.5},"e":null}"#)
        XCTAssertEqual(j["a"].int, 1)
        XCTAssertEqual(j["b"][0].bool, true)
        XCTAssertEqual(j["b"][1].string, "x")
        XCTAssertEqual(j["c"]["d"].double, 2.5)
        XCTAssertTrue(j["e"].isNull)
        XCTAssertTrue(j["missing"].isNull)
        let s = j.stringified()
        XCTAssertTrue(s.contains("\"a\":1"))
        XCTAssertFalse(s.contains("1.0"))
    }
}

final class KeyParserTests: XCTestCase {
    func testChords() throws {
        let c = try KeyParser.parse("cmd+shift+t")
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].modifiers, [.command, .shift])
        XCTAssertEqual(c[0].key, .character("t"))
        let seq = try KeyParser.parse("super+l,Return")
        XCTAssertEqual(seq.count, 2)
        XCTAssertEqual(seq[0].modifiers, [.command])
        XCTAssertEqual(seq[1].key, .named("return"))
        XCTAssertEqual(try KeyParser.parse("KP_0")[0].key, .named("kp0"))
        XCTAssertEqual(try KeyParser.parse("Page_Down")[0].key, .named("pagedown"))
        XCTAssertEqual(try KeyParser.parse("F12")[0].key, .named("f12"))
        XCTAssertEqual(try KeyParser.parse("A")[0].modifiers, [.shift])
        XCTAssertEqual(try KeyParser.parse("A")[0].key, .character("a"))
        XCTAssertEqual(try KeyParser.parse("ctrl+plus")[0].key, .character("+"))
        XCTAssertEqual(try KeyParser.parse("shift")[0].key, nil)
        XCTAssertThrowsError(try KeyParser.parse("bogus+x"))
        XCTAssertThrowsError(try KeyParser.parse("NoSuchKey"))
    }
}

final class RenderAndDiffTests: XCTestCase {
    func makeTree(items: [String], focused: String? = nil) -> UINode {
        let root = UINode(identity: "win", role: "window", rawRole: "AXWindow")
        root.name = "Test"
        root.frame = UIRect(x: 0, y: 0, w: 800, h: 600)
        let list = UINode(identity: "list", role: "list", rawRole: "AXList")
        list.frame = UIRect(x: 0, y: 0, w: 800, h: 600)
        for (i, name) in items.enumerated() {
            let b = UINode(identity: "btn-\(name)", role: "btn", rawRole: "AXButton")
            b.name = name
            b.frame = UIRect(x: 10, y: Double(20 * i), w: 100, h: 18)
            if name == focused { b.states.insert(.focused) }
            list.add(b)
        }
        root.add(list)
        return root
    }

    func testRenderAssignsIndicesAndDiffIsStable() {
        let store = RevisionStore()
        let t1 = TreeTransform.apply(makeTree(items: ["One", "Two", "Three"]))
        let r1 = TreeRenderer.render(t1, previousIndices: store.previousIndices)
        let rev1 = store.commit(root: t1, rendered: r1, header: "# test")
        XCTAssertTrue(rev1.fullText.contains("btn \"One\""))
        let oneIndex = r1.identityToIndex["btn-One"]!
        // Second snapshot: "Two" removed, "Four" added, "Three" focused.
        let t2 = TreeTransform.apply(makeTree(items: ["One", "Three", "Four"], focused: "Three"))
        let r2 = TreeRenderer.render(t2, previousIndices: store.previousIndices)
        let rev2 = store.commit(root: t2, rendered: r2, header: "# test")
        XCTAssertEqual(r2.identityToIndex["btn-One"], oneIndex, "unchanged elements keep their index")
        XCTAssertNotEqual(r2.identityToIndex["btn-Four"], r1.identityToIndex["btn-Two"], "new element gets a fresh index")
        let d = TreeDiff.diff(old: rev1, new: rev2, maxLines: 100)!
        XCTAssertEqual(d.added, 1)
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.removed, 1)
        XCTAssertTrue(d.text.contains("+ [") && d.text.contains("~ [") && d.text.contains("- ["))
        // Third snapshot identical to second -> no change.
        let t3 = TreeTransform.apply(makeTree(items: ["One", "Three", "Four"], focused: "Three"))
        let r3 = TreeRenderer.render(t3, previousIndices: store.previousIndices)
        let rev3 = store.commit(root: t3, rendered: r3, header: "# test")
        let d2 = TreeDiff.diff(old: rev2, new: rev3, maxLines: 100)!
        XCTAssertTrue(d2.isEmpty)
        XCTAssertTrue(d2.text.contains("no change"))
    }

    func testBigChangeFallsBackToFull() {
        let store = RevisionStore()
        let t1 = TreeTransform.apply(makeTree(items: (0..<40).map { "A\($0)" }))
        let rev1 = store.commit(root: t1, rendered: TreeRenderer.render(t1), header: "#")
        let t2 = TreeTransform.apply(makeTree(items: (0..<40).map { "B\($0)" }))
        let rev2 = store.commit(root: t2, rendered: TreeRenderer.render(t2, previousIndices: store.previousIndices), header: "#")
        XCTAssertNil(TreeDiff.diff(old: rev1, new: rev2, maxLines: 400))
    }

    func testTransformPrunesAndLabels() {
        let root = UINode(identity: "w", role: "window", rawRole: "AXWindow")
        root.frame = UIRect(x: 0, y: 0, w: 500, h: 500)
        let empty = UINode(identity: "g1", role: "group", rawRole: "AXGroup")
        root.add(empty)
        let label = UINode(identity: "t", role: "txt", rawRole: "AXStaticText"); label.name = "Email"; label.frame = UIRect(x: 0, y: 0, w: 50, h: 10)
        let field = UINode(identity: "f", role: "field", rawRole: "AXTextField"); field.frame = UIRect(x: 60, y: 0, w: 100, h: 10)
        root.add(label); root.add(field)
        // An offscreen interactive control is kept (marked offscreen) so it can still be targeted; the action scrolls it in.
        let offBtn = UINode(identity: "o", role: "btn", rawRole: "AXButton"); offBtn.name = "Hidden"; offBtn.frame = UIRect(x: 900, y: 900, w: 10, h: 10)
        root.add(offBtn)
        // An offscreen non-interactive leaf is dropped.
        let offText = UINode(identity: "ot", role: "txt", rawRole: "AXStaticText"); offText.name = "Faraway"; offText.frame = UIRect(x: 900, y: 950, w: 40, h: 10)
        root.add(offText)
        var o = TreeTransform.Options()
        o.clip = UIRect(x: 0, y: 0, w: 500, h: 500)
        let out = TreeTransform.apply(root, options: o)
        XCTAssertEqual(out.children.count, 2)
        XCTAssertEqual(out.children[0].role, "field")
        XCTAssertEqual(out.children[0].name, "Email")
        let text = TreeRenderer.render(out).text
        XCTAssertTrue(text.contains("field \"Email\""))
        XCTAssertTrue(text.contains("Hidden"))
        XCTAssertTrue(out.children.contains { $0.name == "Hidden" && $0.states.contains(.offscreen) })
        XCTAssertFalse(text.contains("Faraway"))
    }

    func testQueryFilterKeepsAncestors() {
        let t = makeTree(items: ["Alpha", "Beta"])
        let f = TreeTransform.filter(t, query: "beta")
        XCTAssertEqual(f.children.count, 1)
        XCTAssertEqual(f.children[0].children.count, 1)
        XCTAssertEqual(f.children[0].children[0].name, "Beta")
    }

    func testSecureFieldHidesValue() {
        let n = UINode(identity: "p", role: "secure-field", rawRole: "AXSecureTextField")
        n.name = "Password"; n.value = "hunter2"; n.states.insert(.secure)
        XCTAssertFalse(TreeRenderer.describe(n, RenderOptions()).contains("hunter2"))
    }
}

final class ProtocolTests: XCTestCase {
    func testActionParsing() throws {
        let c = try UIAction.parse(["kind": "click", "el": 4, "count": 2])
        if case .click(let el, _, let button, let count) = c { XCTAssertEqual(el, 4); XCTAssertEqual(button, .left); XCTAssertEqual(count, 2) } else { XCTFail() }
        let at = try UIAction.parse(["kind": "click", "at": "120,30", "button": "right"])
        if case .click(_, let p, let b, _) = at { XCTAssertEqual(p?.0, 120); XCTAssertEqual(b, .right) } else { XCTFail() }
        XCTAssertThrowsError(try UIAction.parse(["kind": "click"]))
        XCTAssertThrowsError(try UIAction.parse(["kind": "set", "value": "x"]))
        let s = try UIAction.parse(["kind": "scroll", "direction": "down", "pages": 2])
        XCTAssertEqual(s.kind, "scroll")
        XCTAssertEqual(try UIAction.parse(c.json), c)
    }

    func testTargetSpec() throws {
        XCTAssertEqual(try TargetSpec.parse(["app": "Safari"]), .app("Safari", window: nil))
        XCTAssertEqual(try TargetSpec.parse(["tab": "abc"]), .tab("abc"))
        XCTAssertThrowsError(try TargetSpec.parse([:]))
    }

    func testStateOptionsInstructions() {
        XCTAssertNil(StateOptions.parse(["full": true]).instructions, "absent = once per session")
        XCTAssertEqual(StateOptions.parse(["instructions": true]).instructions, true)
        XCTAssertEqual(StateOptions.parse(["instructions": false]).instructions, false)
        XCTAssertNil(StateOptions.parse(["instructions": "yes"]).instructions, "non-boolean values are ignored")
        XCTAssertTrue(StateOptions.parse([:]).json["instructions"].isNull)
        var o = StateOptions()
        o.instructions = false
        XCTAssertEqual(o.json["instructions"].bool, false)
        XCTAssertEqual(StateOptions.parse(o.json), o)
    }

    func testPolicyInstructionsMode() {
        XCTAssertEqual(Policy().instructionsMode, "merge")
        XCTAssertEqual(Policy.from(json: ["instructionsMode": "Replace"]).instructionsMode, "replace")
        XCTAssertEqual(Policy.from(json: ["instructionsMode": "off"]).instructionsMode, "off")
        XCTAssertEqual(Policy.from(json: ["instructionsMode": "bogus"]).instructionsMode, "merge", "unknown modes fall back to the default")
        var p = Policy()
        p.instructionsMode = "replace"
        XCTAssertEqual(p.json["instructionsMode"].string, "replace")
        XCTAssertEqual(Policy.from(json: p.json), p)
    }

    func testPolicyLensAndBannerRoundTrip() {
        let d = Policy()
        XCTAssertTrue(d.lensEnabled)
        XCTAssertEqual(d.bannerText, BannerTemplate.defaultText)
        XCTAssertEqual(d.bannerHint, BannerTemplate.defaultHint)
        var p = Policy()
        p.lensEnabled = false
        p.bannerText = "Wisp drives {app}"
        p.bannerHint = ""
        let j = p.json
        XCTAssertEqual(j["lensEnabled"].bool, false)
        XCTAssertEqual(j["bannerText"].string, "Wisp drives {app}")
        XCTAssertEqual(j["bannerHint"].string, "")
        XCTAssertEqual(Policy.from(json: j), p)
        XCTAssertEqual(Policy.from(json: ["bannerText": "   "]).bannerText, BannerTemplate.defaultText, "a blank template keeps the default")
        XCTAssertEqual(Policy.from(json: ["lensEnabled": "no"]).lensEnabled, true, "non-boolean values are ignored")
    }

    func testBannerTemplateRender() {
        XCTAssertEqual(BannerTemplate.render(BannerTemplate.defaultText, app: "TextEdit"), "✦ Wisp is controlling TextEdit  ·  Esc to stop")
        XCTAssertEqual(BannerTemplate.render("Wisp drives {app}", app: "Safari", hint: "reading"), "Wisp drives Safari · reading")
        XCTAssertEqual(BannerTemplate.render("{app} / {app}", app: "Mail"), "Mail / Mail", "every placeholder is substituted")
        XCTAssertEqual(BannerTemplate.render("no placeholder", app: "Mail", hint: ""), "no placeholder", "an empty hint adds nothing")
        XCTAssertEqual(BannerTemplate.render("x", app: "Mail", hint: "  "), "x", "a blank hint adds nothing")
        XCTAssertEqual(BannerTemplate.render("x", app: "Mail", hint: nil), "x")
    }

    func testPolicyMatching() {
        var p = Policy()
        XCTAssertEqual(p.decision(bundleId: "com.bitwarden.desktop", name: "Bitwarden", path: nil), .denied)
        XCTAssertEqual(p.decision(bundleId: "com.apple.TextEdit", name: "TextEdit", path: nil), .allowed)
        p.deny.append("com.example.*")
        XCTAssertEqual(p.decision(bundleId: "com.example.thing", name: "Thing", path: nil), .denied)
        p.allow.append("com.example.thing")
        XCTAssertEqual(p.decision(bundleId: "com.example.thing", name: "Thing", path: nil), .allowed)
        let j = p.json
        XCTAssertEqual(Policy.from(json: j), p)
    }
}
