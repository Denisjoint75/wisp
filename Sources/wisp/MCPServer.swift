import Foundation
import WispCore

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
final class MCPServer {
    private let client = WispClient()
    private var connected = false

    private struct Tool {
        let name: String
        let description: String
        let schema: JSON
    }

    private static let targetProps: [String: JSON] = [
        "app": ["type": "string", "description": "App display name, bundle id, or path (native app target)."],
        "tab": ["type": "string", "description": "Chrome tab id/prefix/'active' (DevTools target). Use instead of app."],
        "window": ["type": "string", "description": "Optional window id or title substring."],
    ]
    private static let stateProps: [String: JSON] = [
        "full": ["type": "boolean", "description": "Return the full tree instead of a diff."],
        "query": ["type": "string", "description": "Keep only lines matching this text (and ancestors)."],
        "screenshot": ["type": "boolean", "description": "Also capture a screenshot (returned as an image)."],
        "bounds": ["type": "boolean", "description": "Append @x,y,w,h to each line."],
        "menus": ["type": "boolean", "description": "Include the menu bar in the tree."],
        "maxLines": ["type": "integer"],
        "instructions": ["type": "boolean", "description": "App-specific guidance: omit to get it once per session (first read), true to include it again, false to suppress it."],
    ]

    private func schema(_ props: [String: JSON], required: [String] = []) -> JSON {
        var p = MCPServer.targetProps
        for (k, v) in props { p[k] = v }
        return ["type": "object", "properties": .object(p), "required": .array(required.map { .string($0) })]
    }

    private lazy var tools: [Tool] = [
        Tool(name: "wisp_apps", description: "List running apps and recently used apps (id, name, bundleId, running).",
             schema: ["type": "object", "properties": ["running": ["type": "boolean"]]]),
        Tool(name: "wisp_state", description: "Read the accessibility tree of an app window or Chrome tab as indexed text (`[12] btn \"Save\"`). Returns a diff vs the previous call by default. The first read of an app includes app-specific guidance inside <app_specific_instructions>; follow it. Call after every action before deciding what to do next; never reuse indices from an old state.",
             schema: schema(MCPServer.stateProps)),
        Tool(name: "wisp_screenshot", description: "Capture a screenshot of the target window/tab (or a display). Coordinates you pass later in `at` are in this image's pixel space.",
             schema: schema(["display": ["type": "integer"]])),
        Tool(name: "wisp_click", description: "Click an element by index (preferred) or a coordinate. Returns the new state diff.",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"], "description": "[x,y] in the last screenshot's pixels (or window points if no screenshot)."],
                             "button": ["type": "string", "enum": ["left", "right", "middle"]], "count": ["type": "integer", "description": "1 single, 2 double, 3 triple"],
                             "observe": ["type": "boolean"]].merging(MCPServer.stateProps) { a, _ in a })),
        Tool(name: "wisp_type", description: "Type text at the current keyboard focus (use wisp_set for fields; newlines press Return).",
             schema: schema(["text": ["type": "string"], "observe": ["type": "boolean"]], required: ["text"])),
        Tool(name: "wisp_key", description: "Press a key chord in xdotool syntax: 'Return', 'cmd+l', 'ctrl+shift+t', 'cmd+l,Return' (comma = sequence).",
             schema: schema(["key": ["type": "string"], "observe": ["type": "boolean"]], required: ["key"])),
        Tool(name: "wisp_set", description: "Replace the value of an editable element (text field, combo, slider) by index.",
             schema: schema(["el": ["type": "integer"], "value": ["type": "string"], "observe": ["type": "boolean"]], required: ["el", "value"])),
        Tool(name: "wisp_scroll", description: "Scroll at an element or point by pages in a direction.",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"]], "direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "pages": ["type": "number"], "observe": ["type": "boolean"]], required: ["direction"])),
        Tool(name: "wisp_drag", description: "Drag from one point to another (coordinates like `at`).",
             schema: schema(["from": ["type": "array", "items": ["type": "number"]], "to": ["type": "array", "items": ["type": "number"]], "observe": ["type": "boolean"]], required: ["from", "to"])),
        Tool(name: "wisp_action", description: "Invoke a secondary accessibility action listed in braces in the state text, e.g. ShowMenu, Expand, Increment.",
             schema: schema(["el": ["type": "integer"], "action": ["type": "string"], "observe": ["type": "boolean"]], required: ["el", "action"])),
        Tool(name: "wisp_select_text", description: "Select text (or place the cursor before/after it) inside an editable element.",
             schema: schema(["el": ["type": "integer"], "text": ["type": "string"], "prefix": ["type": "string"], "suffix": ["type": "string"], "selection": ["type": "string", "enum": ["text", "cursor_before", "cursor_after"]], "observe": ["type": "boolean"]], required: ["el", "text"])),
        Tool(name: "wisp_paste", description: "Paste text/markdown/html via the clipboard (clipboard is restored afterwards). Prefer for multi-line or formatted text.",
             schema: schema(["text": ["type": "string"], "format": ["type": "string", "enum": ["text", "md", "html"]], "observe": ["type": "boolean"]], required: ["text"])),
        Tool(name: "wisp_batch", description: "Run several actions in one round trip: steps are objects like {\"kind\":\"click\",\"el\":4}, {\"kind\":\"type\",\"text\":\"hi\"}, {\"kind\":\"key\",\"key\":\"Return\"}, {\"kind\":\"state\"}, {\"kind\":\"sleep\",\"seconds\":0.5}. Stops at the first failure; returns the final state.",
             schema: schema(["steps": ["type": "array", "items": ["type": "object"]], "observe": ["type": "boolean"]], required: ["steps"])),
        Tool(name: "wisp_launch", description: "Launch (or bring forward) an app by name/bundle id and list its windows.", schema: schema([:], required: ["app"])),
        Tool(name: "wisp_end", description: "End the control session for an app (or all), hiding the cursor and banner.", schema: schema([:])),
        Tool(name: "wisp_cancel", description: "Cancel the action currently running in the daemon.", schema: ["type": "object", "properties": [:]]),
        Tool(name: "wisp_chrome", description: "Chrome DevTools helpers: status, launch (starts Chrome with a debug port and a dedicated profile), tabs, new (url), goto (tab,url), eval (tab, expression), close, back, forward, reload. Then use `tab` in the other tools.",
             schema: ["type": "object", "properties": ["command": ["type": "string", "enum": ["status", "launch", "tabs", "new", "goto", "eval", "close", "back", "forward", "reload"]],
                                                       "tab": ["type": "string"], "url": ["type": "string"], "expression": ["type": "string"], "port": ["type": "integer"], "profile": ["type": "string"]],
                      "required": ["command"]]),
    ]

    func serve() -> Int32 {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if line.isEmpty { continue }
                handleLine(line)
            }
        }
        return 0
    }

    private func write(_ j: JSON) {
        var d = j.data()
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }

    private func handleLine(_ line: Data) {
        guard let req = try? JSON.parse(line) else { return }
        let id = req["id"]
        let method = req["method"].string ?? ""
        switch method {
        case "initialize":
            let v = req["params"]["protocolVersion"].string ?? "2025-06-18"
            write(Proto.result(id: id, ["protocolVersion": .string(v), "capabilities": ["tools": ["listChanged": false]],
                                         "serverInfo": ["name": "wisp", "version": .string(WispVersion.string)],
                                         "instructions": .string(MCPServer.instructions)]))
        case "notifications/initialized", "notifications/cancelled": break
        case "ping": write(Proto.result(id: id, [:]))
        case "tools/list":
            write(Proto.result(id: id, ["tools": .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema] })]))
        case "tools/call":
            let name = req["params"]["name"].string ?? ""
            let args = req["params"]["arguments"]
            do {
                let content = try call(tool: name, args: args)
                write(Proto.result(id: id, ["content": .array(content)]))
            } catch let e as WispError {
                write(Proto.result(id: id, ["content": [["type": "text", "text": .string("error \(e.code.name): \(e.message)" + (e.data.map { "\n" + $0.stringified(pretty: true) } ?? ""))]], "isError": true]))
            } catch {
                write(Proto.result(id: id, ["content": [["type": "text", "text": .string("error: \(error)")]], "isError": true]))
            }
        default:
            if !id.isNull { write(Proto.error(id: id, WispError(.unknownMethod, "unknown method \(method)"))) }
        }
    }

    private func ensureClient() throws {
        if !connected { try client.connect(autoStart: true); connected = true }
    }

    private func targetParams(_ a: JSON) throws -> JSON {
        var j: [String: JSON] = [:]
        if let t = a["tab"].string { j["tab"] = .string(t) }
        if let app = a["app"].string { j["app"] = .string(app) }
        if let w = a["window"].string { j["window"] = .string(w) }
        if j.isEmpty { throw WispError(.invalidParams, "specify `app` or `tab`") }
        for k in ["full", "query", "screenshot", "bounds", "menus", "maxLines", "observe", "instructions"] where !a[k].isNull { j[k] = a[k] }
        return .object(j)
    }

    private func stateContent(_ state: JSON) -> [JSON] {
        var out: [JSON] = []
        var text = state["text"].string ?? ""
        text += "\n# revision \(state["revision"].int ?? 0) · \(state["mode"].string ?? "") · \(state["elements"].int ?? 0) elements"
        if state["settled"].bool == false { text += " · NOT settled" }
        out.append(["type": "text", "text": .string(text)])
        if let p = state["screenshot"]["path"].string, let d = FileManager.default.contents(atPath: p) {
            out.append(["type": "image", "data": .string(d.base64EncodedString()), "mimeType": "image/png"])
            out.append(["type": "text", "text": .string("screenshot \(state["screenshot"]["width"].int ?? 0)x\(state["screenshot"]["height"].int ?? 0) px (scale \(state["screenshot"]["scale"].double ?? 1)); pass `at` in these pixels")])
        }
        if let e = state["screenshotError"]["message"].string { out.append(["type": "text", "text": .string("screenshot failed: \(e)")]) }
        return out
    }

    private func performResult(_ r: JSON) -> [JSON] {
        if !r["state"].isNull { return stateContent(r["state"]) }
        return [["type": "text", "text": .string("ok: \(r["action"].string ?? "")")]]
    }

    private func call(tool: String, args: JSON) throws -> [JSON] {
        try ensureClient()
        func perform(_ action: JSON) throws -> [JSON] {
            var p = try targetParams(args)
            p["action"] = action
            return performResult(try client.call(Proto.Method.appPerform, p, timeout: 300))
        }
        switch tool {
        case "wisp_apps":
            let r = try client.call(Proto.Method.appsList, ["running": .bool(args["running"].bool ?? false)])
            let lines = (r.array ?? []).map { "\($0["running"].bool == true ? "[running] " : "")\($0["name"].string ?? "")  \($0["bundleId"].string ?? $0["path"].string ?? "")" }
            return [["type": "text", "text": .string(lines.joined(separator: "\n"))]]
        case "wisp_state":
            return stateContent(try client.call(Proto.Method.appState, try targetParams(args), timeout: 300))
        case "wisp_screenshot":
            let p: JSON
            if let d = args["display"].int { p = ["display": .int(d)] } else { p = try targetParams(args) }
            let r = try client.call(Proto.Method.appScreenshot, p)
            var out: [JSON] = [["type": "text", "text": .string("screenshot \(r["width"].int ?? 0)x\(r["height"].int ?? 0) px, scale \(r["scale"].double ?? 1), file \(r["path"].string ?? "")")]]
            if let path = r["path"].string, let d = FileManager.default.contents(atPath: path) {
                out.append(["type": "image", "data": .string(d.base64EncodedString()), "mimeType": "image/png"])
            }
            return out
        case "wisp_click":
            var a: [String: JSON] = ["kind": "click"]
            for k in ["el", "at", "button", "count"] where !args[k].isNull { a[k] = args[k] }
            return try perform(.object(a))
        case "wisp_type": return try perform(["kind": "type", "text": args["text"]])
        case "wisp_key": return try perform(["kind": "key", "key": args["key"]])
        case "wisp_set": return try perform(["kind": "set", "el": args["el"], "value": args["value"]])
        case "wisp_scroll":
            var a: [String: JSON] = ["kind": "scroll", "direction": args["direction"]]
            for k in ["el", "at", "pages"] where !args[k].isNull { a[k] = args[k] }
            return try perform(.object(a))
        case "wisp_drag": return try perform(["kind": "drag", "from": args["from"], "to": args["to"]])
        case "wisp_action": return try perform(["kind": "action", "el": args["el"], "action": args["action"]])
        case "wisp_select_text":
            var a: [String: JSON] = ["kind": "select_text", "el": args["el"], "text": args["text"]]
            for k in ["prefix", "suffix", "selection"] where !args[k].isNull { a[k] = args[k] }
            return try perform(.object(a))
        case "wisp_paste": return try perform(["kind": "paste", "text": args["text"], "format": args["format"].isNull ? "text" : args["format"]])
        case "wisp_batch":
            var p = try targetParams(args)
            p["steps"] = args["steps"]
            let r = try client.call(Proto.Method.appBatch, p, timeout: 900)
            var text = (r["steps"].array ?? []).map { "step \($0["step"].int ?? 0) \($0["kind"].string ?? ""): \($0["ok"].bool == true ? "ok" : "FAILED " + ($0["error"]["message"].string ?? ""))" }.joined(separator: "\n")
            if r["ok"].bool == false { text = "batch stopped at step \(r["failedStep"].int ?? -1)\n" + text }
            var out: [JSON] = [["type": "text", "text": .string(text)]]
            if !r["state"].isNull { out.append(contentsOf: stateContent(r["state"])) }
            return out
        case "wisp_launch":
            let r = try client.call(Proto.Method.appLaunch, ["app": args["app"], "activate": true], timeout: 60)
            return [["type": "text", "text": .string(r.stringified(pretty: true))]]
        case "wisp_end":
            var p: [String: JSON] = [:]
            if let a = args["app"].string { p["app"] = .string(a) }
            if let t = args["tab"].string { p["tab"] = .string(t) }
            _ = try client.call(Proto.Method.sessionEnd, .object(p))
            return [["type": "text", "text": "session ended"]]
        case "wisp_cancel":
            _ = try client.call(Proto.Method.sessionCancel)
            return [["type": "text", "text": "cancelled"]]
        case "wisp_chrome":
            let cmd = args["command"].string ?? "status"
            var p: [String: JSON] = [:]
            if let t = args["tab"].string { p["tab"] = .string(t) }
            if let u = args["url"].string { p["url"] = .string(u) }
            if let e = args["expression"].string { p["expression"] = .string(e) }
            if let port = args["port"].int { p["port"] = .int(port) }
            if let prof = args["profile"].string { p["profile"] = .string(prof) }
            let method: String
            switch cmd {
            case "status": method = Proto.Method.chromeStatus
            case "launch": method = Proto.Method.chromeLaunch
            case "tabs": method = Proto.Method.chromeTabs
            case "new": method = Proto.Method.chromeTabNew
            case "goto": method = Proto.Method.chromeTabGoto
            case "eval": method = Proto.Method.chromeTabEval
            case "close": method = Proto.Method.chromeTabClose
            case "back": method = Proto.Method.chromeTabBack
            case "forward": method = Proto.Method.chromeTabForward
            case "reload": method = Proto.Method.chromeTabReload
            default: throw WispError(.invalidParams, "unknown chrome command \(cmd)")
            }
            let r = try client.call(method, .object(p), timeout: 120)
            if !r["state"].isNull { return stateContent(r["state"]) }
            if cmd == "tabs" {
                return [["type": "text", "text": .string((r.array ?? []).map { "\($0["id"].string ?? "")  \($0["title"].string ?? "")  \($0["url"].string ?? "")" }.joined(separator: "\n"))]]
            }
            return [["type": "text", "text": .string(r.stringified(pretty: true))]]
        default:
            throw WispError(.unknownMethod, "unknown tool \(tool)")
        }
    }

    static let instructions = """
    Wisp controls macOS apps through accessibility and Chrome tabs through DevTools. Workflow: wisp_state (reads an indexed tree) → act with wisp_click/wisp_set/wisp_key/... (each returns the new state diff) → repeat. Always use indices from the latest state. Prefer wisp_set for text fields and wisp_paste for long/multi-line text. Ask the user before irreversible or outward-facing actions (sending, deleting, paying, logging in, changing settings). If a result says "user input detected", stop and re-read state.
    """
}
