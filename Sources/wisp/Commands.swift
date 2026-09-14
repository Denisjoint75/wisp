import Foundation
import WispCore

struct Output {
    var json: Bool

    func printResult(_ r: JSON, kind: String) {
        if json { print(r.stringified(pretty: true)); return }
        switch kind {
        case "state": printState(r)
        case "perform":
            if !r["state"].isNull { printState(r["state"]) } else { print("ok: \(r["action"].string ?? "")") }
        case "batch":
            for s in r["steps"].array ?? [] {
                let ok = s["ok"].bool ?? false
                print("step \(s["step"].int ?? 0) \(s["kind"].string ?? ""): \(ok ? "ok" : "FAILED \(s["error"]["message"].string ?? "")")")
            }
            if !r["state"].isNull { printState(r["state"]) }
        case "apps":
            for a in r.array ?? [] {
                let running = a["running"].bool == true ? "running" : "        "
                print("\(running)  \(a["name"].string ?? "")  \(a["bundleId"].string ?? a["path"].string ?? "")")
            }
        case "tabs":
            for t in r.array ?? [] {
                let tag = t["mark"].string.map { "  [\($0)]" } ?? ""
                print("\(t["id"].string ?? "")  \(t["title"].string ?? "")  \(t["url"].string ?? "")\(tag)")
            }
        case "windows":
            for w in r["windows"].array ?? [] {
                print("\(w["id"].int.map { String($0) } ?? "?")\t\(w["focused"].bool == true ? "*" : " ")\t\(w["title"].string ?? "")\t\(w["frame"].stringified())")
            }
        case "screenshot":
            print("\(r["path"].string ?? "") \(r["width"].int ?? 0)x\(r["height"].int ?? 0) scale=\(r["scale"].double ?? 0)")
        case "text":
            print(r.string ?? r.stringified(pretty: true))
        case "instructions":
            print("app: \(r["app"]["name"].string ?? "") (\(r["app"]["bundleId"].string ?? "no bundle id"))\(r["isBrowser"].bool == true ? ", browser" : "")")
            print("mode: \(r["mode"].string ?? "")")
            print("candidates: \((r["candidates"].array ?? []).compactMap { $0.string }.joined(separator: ", "))")
            let matched = (r["matched"].array ?? []).map { "\($0["stem"].string ?? "") (\($0["source"].string ?? ""))" }
            print("matched: \(matched.isEmpty ? "none" : matched.joined(separator: ", "))")
            if let t = r["text"].string { print(""); print(t) }
        default:
            print(r.stringified(pretty: true))
        }
    }

    func printState(_ s: JSON) {
        print(s["text"].string ?? "")
        var meta = ["# revision \(s["revision"].int ?? 0)", s["mode"].string ?? "", "\(s["elements"].int ?? 0) elements"]
        if s["settled"].bool == false { meta.append("NOT settled") }
        if let p = s["screenshot"]["path"].string {
            meta.append("screenshot: \(p) (\(s["screenshot"]["width"].int ?? 0)x\(s["screenshot"]["height"].int ?? 0) px, scale \(s["screenshot"]["scale"].double ?? 1))")
        }
        if let e = s["screenshotError"]["message"].string { meta.append("screenshot failed: \(e)") }
        print(meta.joined(separator: " · "))
    }
}

enum Commands {
    static func target(_ a: Args) throws -> JSON {
        var j: [String: JSON] = [:]
        if let t = a.value("tab", "t") { j["tab"] = .string(t) }
        if let app = a.value("app", "a") { j["app"] = .string(app) }
        if let w = a.value("window", "w") { j["window"] = .string(w) }
        if j["tab"] == nil, j["app"] == nil {
            if let env = ProcessInfo.processInfo.environment["WISP_APP"], !env.isEmpty { j["app"] = .string(env) }
            else { throw WispError(.invalidParams, "specify a target: --app <name|bundle id> or --tab <chrome tab id>") }
        }
        return .object(j)
    }

    static func stateOptions(_ a: Args) -> JSON {
        var o: [String: JSON] = [:]
        if a.flag("full") { o["full"] = true }
        if let q = a.value("query", "q") { o["query"] = .string(q) }
        if a.flag("screenshot", "s") { o["screenshot"] = true }
        if a.flag("bounds") { o["bounds"] = true }
        if a.flag("menus") { o["menus"] = true }
        if let m = a.int("max-lines") { o["maxLines"] = .int(m) }
        if a.flag("instructions") { o["instructions"] = true }
        if a.flag("no-instructions") { o["instructions"] = false }
        return .object(o)
    }

    static func merge(_ a: JSON, _ b: JSON) -> JSON {
        var o = a.object ?? [:]
        for (k, v) in b.object ?? [:] { o[k] = v }
        return .object(o)
    }

    static func performParams(_ a: Args, action: JSON) throws -> JSON {
        var p = merge(try target(a), stateOptions(a))
        p["action"] = action
        if a.flag("no-observe") { p["observe"] = false }
        // Wisp operates in place by default (no window raise). --activate forces the app to the front for the rare
        // app that ignores background input; --no-activate is the explicit default and kept for clarity.
        if a.flag("activate") { p["activate"] = true }
        if a.flag("no-activate") { p["activate"] = false }
        if a.flag("hid") { p["delivery"] = "hid" }
        if a.flag("no-cursor") { p["cursor"] = false }
        if let s = a.value("space") { p["space"] = .string(s) }
        return p
    }

    static func run(_ argv: [String]) -> Int32 {
        let a = Args(argv)
        let out = Output(json: a.flag("json", "j"))
        // `--version` / `-v` and `--help` / `-h` work as bare flags, not just as subcommands.
        if a.flag("version", "v") { print("wisp \(WispVersion.string) (\(WispVersion.build))"); return 0 }
        let cmd = a.positional.first ?? "help"
        if let sock = a.value("socket") { setenv("WISP_SOCKET", sock, 1) }
        do {
            switch cmd {
            case "help", "-h", "--help": print(helpText); return 0
            case "version", "--version": print("wisp \(WispVersion.string) (\(WispVersion.build))"); return 0
            case "mcp": return MCPServer().serve()
            case "doctor": return doctor(a, out)
            case "daemon": return daemon(a, out)
            case "instructions" where a.rest.first == "list": return instructionsList(out)
            default: break
            }
            let client = WispClient()
            try client.connect(autoStart: cmd != "cancel" && cmd != "status")
            let result: JSON
            var kind = "json"
            switch cmd {
            case "apps":
                result = try client.call(Proto.Method.appsList, ["running": .bool(a.flag("running"))]); kind = "apps"
            case "windows":
                result = try client.call(Proto.Method.appWindows, try target(a)); kind = "windows"
            case "launch":
                result = try client.call(Proto.Method.appLaunch, merge(try target(a), ["activate": .bool(!a.flag("no-activate"))])); kind = "windows"
            case "activate":
                result = try client.call(Proto.Method.appActivate, try target(a))
            case "state":
                result = try client.call(Proto.Method.appState, merge(try target(a), stateOptions(a))); kind = "state"
            case "screenshot":
                var p = try? target(a)
                if let d = a.int("display") { p = ["display": .int(d)] }
                guard let params = p else { throw WispError(.invalidParams, "screenshot needs --app, --tab or --display") }
                result = try client.call(Proto.Method.appScreenshot, params); kind = "screenshot"
                if let o = a.value("o", "out"), let src = result["path"].string {
                    try? FileManager.default.removeItem(atPath: o)
                    try FileManager.default.copyItem(atPath: src, toPath: o)
                    print("saved \(o)")
                }
            case "click", "move", "mouse-down", "mouse-up":
                var action: [String: JSON] = ["kind": .string(cmd == "mouse-down" ? "mouse_down" : cmd == "mouse-up" ? "mouse_up" : cmd)]
                if let el = a.int("el", "e") { action["el"] = .int(el) }
                if let at = try a.point("at") { action["at"] = [.number(at.0), .number(at.1)] }
                if a.positional.count > 1, action["el"] == nil, action["at"] == nil, let el = Int(a.positional[1]) { action["el"] = .int(el) }
                if cmd == "click" {
                    action["button"] = .string(a.flag("right") ? "right" : a.flag("middle") ? "middle" : (a.value("button") ?? "left"))
                    action["count"] = .int(a.flag("double") ? 2 : a.flag("triple") ? 3 : (a.int("count") ?? 1))
                }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: .object(action))); kind = "perform"
            case "type":
                let text = a.value("text") ?? a.rest.joined(separator: " ")
                guard !text.isEmpty else { throw WispError(.invalidParams, "type needs text") }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "type", "text": .string(text)])); kind = "perform"
            case "key":
                let k = a.value("key") ?? a.rest.joined(separator: " ")
                guard !k.isEmpty else { throw WispError(.invalidParams, "key needs a chord, e.g. `cmd+l` or `Return`") }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "key", "key": .string(k)])); kind = "perform"
            case "set":
                var rest = a.rest
                var el = a.int("el", "e")
                if el == nil, let first = rest.first, let n = Int(first) { el = n; rest.removeFirst() }
                guard let e = el else { throw WispError(.invalidParams, "set needs --el <index>") }
                let value = a.value("value") ?? rest.joined(separator: " ")
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "set", "el": .int(e), "value": .string(value)])); kind = "perform"
            case "scroll":
                var action: [String: JSON] = ["kind": "scroll"]
                if let el = a.int("el", "e") { action["el"] = .int(el) }
                if let at = try a.point("at") { action["at"] = [.number(at.0), .number(at.1)] }
                let dir = a.flag("up") ? "up" : a.flag("left") ? "left" : a.flag("right") ? "right" : a.flag("down") ? "down" : (a.rest.first ?? "down")
                action["direction"] = .string(dir)
                action["pages"] = .number(a.double("pages") ?? 1)
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: .object(action))); kind = "perform"
            case "drag":
                guard let f = try a.point("from"), let t = try a.point("to") else { throw WispError(.invalidParams, "drag needs --from x,y --to x,y") }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "drag", "from": [.number(f.0), .number(f.1)], "to": [.number(t.0), .number(t.1)]])); kind = "perform"
            case "action":
                var rest = a.rest
                var el = a.int("el", "e")
                if el == nil, let first = rest.first, let n = Int(first) { el = n; rest.removeFirst() }
                guard let e = el, let name = a.value("action") ?? rest.first else { throw WispError(.invalidParams, "action needs --el <index> <ActionName>") }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "action", "el": .int(e), "action": .string(name)])); kind = "perform"
            case "select-text", "select_text":
                var rest = a.rest
                var el = a.int("el", "e")
                if el == nil, let first = rest.first, let n = Int(first) { el = n; rest.removeFirst() }
                guard let e = el else { throw WispError(.invalidParams, "select-text needs --el <index> <text>") }
                let text = a.value("text") ?? rest.joined(separator: " ")
                var action: [String: JSON] = ["kind": "select_text", "el": .int(e), "text": .string(text)]
                if let p = a.value("prefix") { action["prefix"] = .string(p) }
                if let s = a.value("suffix") { action["suffix"] = .string(s) }
                if let c = a.value("cursor") { action["selection"] = .string(c == "before" ? "cursor_before" : c == "after" ? "cursor_after" : "text") }
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: .object(action))); kind = "perform"
            case "paste":
                let text = a.value("text") ?? a.rest.joined(separator: " ")
                result = try client.call(Proto.Method.appPerform, try performParams(a, action: ["kind": "paste", "text": .string(text), "format": .string(a.value("format") ?? "text")])); kind = "perform"
            case "batch":
                let src = a.rest.first ?? "-"
                let data: Data
                if src == "-" { data = FileHandle.standardInput.readDataToEndOfFile() } else { data = try Data(contentsOf: URL(fileURLWithPath: src)) }
                var steps: [JSON] = []
                let text = String(decoding: data, as: UTF8.self)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                    steps = (try JSON.parse(text)).array ?? []
                } else {
                    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("#") {
                        steps.append(try JSON.parse(String(line)))
                    }
                }
                var p = merge(try target(a), stateOptions(a))
                p["steps"] = .array(steps)
                if a.flag("no-observe") { p["observe"] = false }
                result = try client.call(Proto.Method.appBatch, p, timeout: 900); kind = "batch"
            case "cancel":
                result = try client.call(Proto.Method.sessionCancel)
            case "end":
                var p: JSON = [:]
                if let app = a.value("app", "a") { p["app"] = .string(app) }
                if let t = a.value("tab", "t") { p["tab"] = .string(t) }
                result = try client.call(Proto.Method.sessionEnd, p)
            case "status":
                result = try client.call(Proto.Method.sessionStatus)
            case "policy":
                let sub = a.rest.first ?? "get"
                if sub == "get" { result = try client.call(Proto.Method.policyGet) }
                else if sub == "set" {
                    var p = try client.call(Proto.Method.policyGet)
                    if let f = a.value("file") { p = try JSON.parse(try Data(contentsOf: URL(fileURLWithPath: f))) }
                    if !a.values("deny").isEmpty { p["deny"] = .array(a.values("deny").map { .string($0) }) }
                    if !a.values("allow").isEmpty { p["allow"] = .array(a.values("allow").map { .string($0) }) }
                    if !a.values("background").isEmpty { p["background"] = .array(a.values("background").map { .string($0) }) }
                    if a.flag("allow-secure-fields") { p["allowSecureFields"] = true }
                    if a.flag("no-cursor") { p["cursorEnabled"] = false }
                    if a.flag("cursor") { p["cursorEnabled"] = true }
                    if let port = a.int("port") { p["chromePort"] = .int(port) }
                    if let m = a.value("instructions-mode") {
                        guard Policy.instructionsModes.contains(m.lowercased()) else { throw WispError(.invalidParams, "--instructions-mode must be merge, replace or off") }
                        p["instructionsMode"] = .string(m.lowercased())
                    }
                    if let t = a.value("banner-text") {
                        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { throw WispError(.invalidParams, "--banner-text must not be empty (use {app} for the app name)") }
                        p["bannerText"] = .string(t)
                    }
                    if let h = a.value("banner-hint") { p["bannerHint"] = .string(h) }
                    if let l = a.value("lens") {
                        switch l.lowercased() {
                        case "on", "true", "1", "yes": p["lensEnabled"] = true
                        case "off", "false", "0", "no": p["lensEnabled"] = false
                        default: throw WispError(.invalidParams, "--lens must be on or off")
                        }
                    }
                    if let m = a.value("approval") {
                        guard Policy.approvalModes.contains(m.lowercased()) else { throw WispError(.invalidParams, "--approval must be off, high-risk or all") }
                        p["approval"] = .string(m.lowercased())
                    }
                    // Repeatable list flags replace the whole list; a single empty value clears it.
                    for (flag, key) in [("high-risk", "highRisk"), ("forbid", "forbidden"), ("block-url", "blockedURLs")] where !a.values(flag).isEmpty {
                        p[key] = .array(a.values(flag).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { .string($0) })
                    }
                    result = try client.call(Proto.Method.policySet, p)
                } else { throw WispError(.invalidParams, "policy get|set") }
            case "approvals":
                switch a.rest.first ?? "list" {
                case "list":
                    result = try client.call(Proto.Method.approvalsList)
                    if !out.json {
                        let grants = result["grants"].array ?? []
                        if grants.isEmpty { print("no approvals (\(result["path"].string ?? ""))") }
                        for g in grants {
                            var line = "\(g["app"].string ?? "")  \(g["grant"].string ?? "")"
                            if let at = g["grantedAt"].string { line += "  since \(at)" }
                            if g["active"].bool == false { line += "  (from an earlier daemon; inactive)" }
                            print(line)
                        }
                        return 0
                    }
                case "clear":
                    var p: JSON = [:]
                    if let app = a.value("app", "a") { p["app"] = .string(app) }
                    result = try client.call(Proto.Method.approvalsClear, p)
                    if !out.json { print(a.value("app", "a").map { "approval for \($0) removed" } ?? "approvals cleared"); return 0 }
                default: throw WispError(.invalidParams, "approvals list | clear [--app X]")
                }
            case "instructions":
                guard a.rest.first == "show" else { throw WispError(.invalidParams, "instructions list | show --app X") }
                result = try client.call(Proto.Method.appInstructions, try target(a)); kind = "instructions"
            case "chrome":
                let sub = a.rest.first ?? "status"
                var p: JSON = [:]
                if let t = a.value("tab", "t") { p["tab"] = .string(t) }
                switch sub {
                case "status": result = try client.call(Proto.Method.chromeStatus)
                case "launch":
                    if let port = a.int("port") { p["port"] = .int(port) }
                    if let prof = a.value("profile") { p["profile"] = .string(prof) }
                    if let u = a.value("url") ?? a.rest.dropFirst().first { p["url"] = .string(u) }
                    if a.flag("visible") { p["visible"] = true }
                    result = try client.call(Proto.Method.chromeLaunch, p, timeout: 60)
                case "tabs": result = try client.call(Proto.Method.chromeTabs); kind = "tabs"
                case "new":
                    if let u = a.value("url") ?? a.rest.dropFirst().first { p["url"] = .string(u) }
                    result = try client.call(Proto.Method.chromeTabNew, p, timeout: 60)
                case "goto":
                    guard let u = a.value("url") ?? a.rest.dropFirst().first else { throw WispError(.invalidParams, "chrome goto needs a URL") }
                    p["url"] = .string(u)
                    p = merge(p, stateOptions(a))
                    if a.flag("no-observe") { p["observe"] = false }
                    result = try client.call(Proto.Method.chromeTabGoto, p, timeout: 120)
                    if !result["state"].isNull { kind = "perform" }
                case "eval":
                    guard let e = a.value("expression") ?? a.rest.dropFirst().joined(separator: " ").nilIfEmpty else { throw WispError(.invalidParams, "chrome eval needs an expression") }
                    p["expression"] = .string(e)
                    result = try client.call(Proto.Method.chromeTabEval, p, timeout: 60)
                    if !out.json { print(result["value"].string ?? result["value"].stringified(pretty: true)); return 0 }
                case "close": result = try client.call(Proto.Method.chromeTabClose, p)
                case "back", "forward", "reload":
                    p = merge(p, stateOptions(a))
                    if a.flag("no-observe") { p["observe"] = false }
                    let m = sub == "back" ? Proto.Method.chromeTabBack : sub == "forward" ? Proto.Method.chromeTabForward : Proto.Method.chromeTabReload
                    result = try client.call(m, p, timeout: 120)
                    if !result["state"].isNull { kind = "perform" }
                case "upload":
                    let files = a.rest.dropFirst().map { $0.hasPrefix("/") ? $0 : FileManager.default.currentDirectoryPath + "/" + $0 }
                    guard !files.isEmpty else { throw WispError(.invalidParams, "chrome upload needs --tab T [--el N] /path/to/file ...") }
                    if let el = a.int("el", "e") { p["el"] = .int(el) }
                    p["files"] = .array(files.map { .string($0) })
                    p = merge(p, stateOptions(a))
                    if a.flag("no-observe") { p["observe"] = false }
                    result = try client.call(Proto.Method.chromeTabUpload, p, timeout: 120); kind = "perform"
                case "dialog":
                    let verb = a.rest.dropFirst().first ?? ""
                    guard verb == "accept" || verb == "dismiss" else { throw WispError(.invalidParams, "chrome dialog --tab T accept|dismiss [--text S]") }
                    p["accept"] = .bool(verb == "accept")
                    if let t = a.value("text") { p["text"] = .string(t) }
                    p = merge(p, stateOptions(a))
                    if a.flag("no-observe") { p["observe"] = false }
                    result = try client.call(Proto.Method.chromeTabDialog, p, timeout: 120); kind = "perform"
                case "mark":
                    guard let m = a.rest.dropFirst().first, ["deliverable", "handoff", "none"].contains(m) else {
                        throw WispError(.invalidParams, "chrome mark --tab T deliverable|handoff|none")
                    }
                    p["mark"] = .string(m)
                    result = try client.call(Proto.Method.chromeTabMark, p)
                    if !out.json { print("tab \(result["tab"].string ?? "") marked \(result["mark"].string ?? m)"); return 0 }
                case "show":
                    result = try client.call(Proto.Method.chromeShow, p)
                    if !out.json { print("Chrome shown"); return 0 }
                case "hide":
                    result = try client.call(Proto.Method.chromeHide)
                    if !out.json { print("Chrome hidden"); return 0 }
                default: throw WispError(.invalidParams, "chrome status|launch|tabs|new|goto|eval|close|back|forward|reload|upload|dialog|mark|show|hide")
                }
            case "log":
                result = try client.call(Proto.Method.daemonLog, ["lines": .int(a.int("lines") ?? 60)])
                if !out.json { print(result["log"].string ?? ""); return 0 }
            default:
                FileHandle.standardError.write(Data("unknown command `\(cmd)`; run `wisp help`\n".utf8))
                return 2
            }
            out.printResult(result, kind: kind)
            return 0
        } catch let e as WispError {
            if out.json { print(JSON.object(["error": e.json]).stringified(pretty: true)) }
            else { FileHandle.standardError.write(Data("error: \(e.code.name): \(e.message)\n".utf8)) }
            if let d = e.data, !out.json { FileHandle.standardError.write(Data((d.stringified(pretty: true) + "\n").utf8)) }
            return e.code == .userIntervened || e.code == .userStoppedSession || e.code == .cancelled ? 3 : 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func doctor(_ a: Args, _ out: Output) -> Int32 {
        var report: [String: JSON] = [:]
        let daemonPath = WispClient.daemonURL()?.path
        report["daemonExecutable"] = daemonPath.map { .string($0) } ?? .null
        report["socket"] = .string(WispPaths.socketPath)
        if let d = daemonPath {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: d)
            p.arguments = [a.flag("request-permissions", "request-screen") ? "--request-permissions" : "--check"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let j = try? JSON.parse(data) { report["daemonPermissions"] = j } else { report["daemonOutput"] = .string(String(decoding: data, as: UTF8.self)) }
        }
        let client = WispClient()
        if (try? client.connect(autoStart: !a.flag("no-start"))) != nil, let ping = try? client.call(Proto.Method.ping) {
            report["daemon"] = ping
        } else {
            report["daemon"] = .null
        }
        report["chrome"] = .bool(FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app"))
        report["policyPath"] = .string(WispPaths.policyPath)
        report["logPath"] = .string(WispPaths.logPath)
        let j = JSON.object(report)
        if out.json { print(j.stringified(pretty: true)); return 0 }
        print("wispd executable: \(daemonPath ?? "NOT FOUND (set WISP_DAEMON)")")
        let perms = j["daemon"]["permissions"]
        print("daemon: \(j["daemon"].isNull ? "not running" : "running pid \(j["daemon"]["pid"].int ?? 0), api \(j["daemon"]["serverApiVersion"].string ?? "")")")
        print("accessibility permission: \(perms["accessibility"].bool == true ? "granted" : "MISSING -> System Settings > Privacy & Security > Accessibility (add wispd)")")
        print("screen recording permission: \(perms["screenRecording"].bool == true ? "granted" : "missing (screenshots disabled) -> run `wisp doctor --request-permissions`")")
        print("socket: \(WispPaths.socketPath)")
        print("policy: \(WispPaths.policyPath)")
        print("log: \(WispPaths.logPath)")
        print("chrome: \(j["chrome"].bool == true ? "installed" : "not found") (use `wisp chrome launch` for CDP control)")
        return 0
    }

    /// `wisp instructions list`: every built-in stem plus the user's own files, without talking to the daemon.
    static func instructionsList(_ out: Output) -> Int32 {
        let dir = WispPaths.instructionsDir
        let userStems = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
        let builtin = Set(BuiltinInstructions.text.keys)
        var rows: [JSON] = []
        for stem in builtin.union(userStems).sorted() {
            let source = userStems.contains(stem) ? "user" : "builtin"
            rows.append(["stem": .string(stem), "source": .string(source), "overridesBuiltin": .bool(userStems.contains(stem) && builtin.contains(stem))])
        }
        if out.json { print(JSON.object(["directory": .string(dir.path), "stems": .array(rows)]).stringified(pretty: true)); return 0 }
        for r in rows {
            let stem = r["stem"].string ?? ""
            let mark = r["overridesBuiltin"].bool == true ? "user (overrides builtin)" : (r["source"].string ?? "")
            print("\(stem.padding(toLength: max(stem.count, 32), withPad: " ", startingAt: 0))  \(mark)")
        }
        print("\(builtin.count) builtin, \(userStems.count) user (\(dir.path))")
        return 0
    }

    static func daemon(_ a: Args, _ out: Output) -> Int32 {
        let sub = a.rest.first ?? "status"
        let client = WispClient()
        switch sub {
        case "start":
            if (try? client.connect(autoStart: false)) != nil { print("wispd already running"); return 0 }
            do { try client.connect(autoStart: true); print("wispd started (pid \((try? client.call(Proto.Method.ping))?["pid"].int ?? 0))"); return 0 }
            catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); return 1 }
        case "stop":
            guard (try? client.connect(autoStart: false)) != nil else { print("wispd not running"); return 0 }
            _ = try? client.call(Proto.Method.daemonShutdown)
            print("wispd stopped")
            return 0
        case "restart":
            if (try? client.connect(autoStart: false)) != nil { _ = try? client.call(Proto.Method.daemonShutdown); usleep(500_000) }
            let c2 = WispClient()
            do { try c2.connect(autoStart: true); print("wispd restarted"); return 0 } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); return 1 }
        case "status":
            guard (try? client.connect(autoStart: false)) != nil, let p = try? client.call(Proto.Method.ping) else { print("wispd not running"); return 1 }
            if out.json { print(p.stringified(pretty: true)) } else { print("wispd running pid \(p["pid"].int ?? 0), api \(p["serverApiVersion"].string ?? ""), accessibility=\(p["permissions"]["accessibility"].bool ?? false) screen=\(p["permissions"]["screenRecording"].bool ?? false)") }
            return 0
        case "log":
            guard (try? client.connect(autoStart: false)) != nil, let r = try? client.call(Proto.Method.daemonLog, ["lines": .int(a.int("lines") ?? 60)]) else {
                print((try? String(contentsOfFile: WispPaths.logPath, encoding: .utf8)) ?? "no log"); return 0
            }
            print(r["log"].string ?? "")
            return 0
        default:
            print("daemon start|stop|restart|status|log")
            return 2
        }
    }

    static let helpText = """
    wisp — computer use for agents (macOS). Targets: --app <name|bundle id|path> [--window <id|title>] or --tab <chrome tab>.

    Observe
      wisp apps [--running]                      list running apps and apps used in the last 14 days
      wisp windows --app X                       list windows
      wisp state --app X [--full] [--query Q] [--screenshot] [--bounds] [--menus] [--max-lines N]
                 [--instructions | --no-instructions]   app guidance is included once per session by default
      wisp screenshot --app X | --tab T | --display N [-o out.png]
      wisp instructions list | show --app X      built-in and user (~/.config/wisp/instructions) app guidance

    Act (every action returns the new state diff unless --no-observe)
      wisp click --app X --el N | --at x,y [--right|--middle] [--double|--triple]
      wisp type --app X "text"                   wisp key --app X "cmd+l,Return"
      wisp set --app X --el N "value"            wisp scroll --app X [--el N|--at x,y] --down [--pages 2]
      wisp drag --app X --from x,y --to x,y      wisp action --app X --el N "ShowMenu"
      wisp select-text --app X --el N "text" [--prefix P] [--suffix S] [--cursor before|after]
      wisp paste --app X "text" [--format text|md|html]
      wisp move | mouse-down | mouse-up --app X --el N|--at x,y
      wisp batch --app X [-|file.jsonl]          run several steps in one round trip
      Options: --space window|screenshot|screen, --no-activate, --hid, --no-cursor, plus state flags

    Chrome over DevTools
      wisp chrome launch [--visible] [--port 9222] [--profile DIR] [URL]   hidden in the background unless --visible
      wisp chrome tabs | new [URL] | close --tab T              tabs shows [agent]/[deliverable]/[handoff] tags
      wisp chrome goto --tab T URL | back | forward | reload    wisp chrome eval --tab T "document.title"
      wisp chrome upload --tab T [--el N] /abs/file ...         fill a file input (click it first, or pass --el)
      wisp chrome dialog --tab T accept|dismiss [--text S]      answer an alert/confirm/prompt reported by state
      wisp chrome mark --tab T deliverable|handoff|none         keep a tab past `wisp end` (marks reset each turn)
      wisp chrome show [--tab T] | hide                         bring the Wisp Chrome forward / hide it again
      then use --tab T with state/click/type/...

    Session & daemon
      wisp cancel | end [--app X | --tab T] | status | log    bare `end` closes unmarked agent Chrome tabs
      wisp policy get | set [--allow ID ...] [--deny ID ...] [--instructions-mode merge|replace|off]
                            [--banner-text "✦ Wisp is controlling {app}"] [--banner-hint reading] [--lens on|off]
                            [--approval off|high-risk|all] [--high-risk PATTERN ...] [--forbid PATTERN ...]
                            [--block-url HOST ...]        list flags replace the list; one empty value clears it
      wisp approvals list | clear [--app X]      per-app approvals the user granted from the prompt
      wisp doctor [--request-permissions]        wisp daemon start|stop|restart|status|log
      wisp mcp                                   MCP stdio server exposing the same tools
      wisp --json ... for machine-readable output
    """
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

