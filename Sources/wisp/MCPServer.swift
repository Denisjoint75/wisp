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
    /// Options every action tool accepts (mirrors the CLI action flags); the state options apply to the state
    /// returned after the action.
    private static let actionProps: [String: JSON] = stateProps.merging([
        "observe": ["type": "boolean", "description": "Return the new state after the action (default true)."],
        "space": ["type": "string", "enum": ["window", "screenshot", "screen"], "description": "Coordinate space for `at`/`from`/`to`: pixels of the last screenshot (default when one exists), window points, or screen points."],
        "cursor": ["type": "boolean", "description": "Show the animated agent cursor (default true)."],
        "activate": ["type": "boolean", "description": "Bring the app to the front for this action (default false: Wisp operates in place)."],
        "hid": ["type": "boolean", "description": "Deliver through the HID system instead of the app's process (moves the real pointer; only for apps that ignore in-place input)."],
    ]) { a, _ in a }

    private func schema(_ props: [String: JSON], required: [String] = []) -> JSON {
        var p = MCPServer.targetProps
        for (k, v) in props { p[k] = v }
        return ["type": "object", "properties": .object(p), "required": .array(required.map { .string($0) })]
    }

    private lazy var tools: [Tool] = [
        Tool(name: "wisp_apps", description: "List running apps and recently used apps (id, name, bundleId, running).",
             schema: ["type": "object", "properties": ["running": ["type": "boolean"]]]),
        Tool(name: "wisp_windows", description: "List the windows of an app (id, focused, title, frame). Use the id or a title substring as `window` in other tools; sheets and secondary windows show up here.",
             schema: schema([:], required: ["app"])),
        Tool(name: "wisp_state", description: "Read the accessibility tree of an app window or Chrome tab as indexed text (`[12] btn \"Save\"`). Returns a diff vs the previous call by default. The first read of an app includes app-specific guidance inside <app_specific_instructions>; follow it. Call after every action before deciding what to do next; never reuse indices from an old state.",
             schema: schema(MCPServer.stateProps)),
        Tool(name: "wisp_screenshot", description: "Capture a screenshot of the target window/tab (or a display). Coordinates you pass later in `at` are in this image's pixel space.",
             schema: schema(["display": ["type": "integer"]])),
        Tool(name: "wisp_click", description: "Click an element by index (preferred) or a coordinate. Returns the new state diff.",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"], "description": "[x,y] in the last screenshot's pixels (or window points if no screenshot)."],
                             "button": ["type": "string", "enum": ["left", "right", "middle"]], "count": ["type": "integer", "description": "1 single, 2 double, 3 triple"]].merging(MCPServer.actionProps) { a, _ in a })),
        Tool(name: "wisp_move", description: "Move the agent pointer to an element or coordinate without clicking (hover).",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"]]].merging(MCPServer.actionProps) { a, _ in a })),
        Tool(name: "wisp_mouse_down", description: "Press and hold the left mouse button at an element or coordinate (pair with wisp_mouse_up for custom drags).",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"]]].merging(MCPServer.actionProps) { a, _ in a })),
        Tool(name: "wisp_mouse_up", description: "Release the mouse button at an element or coordinate (or where the pointer is when neither is given).",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"]]].merging(MCPServer.actionProps) { a, _ in a })),
        Tool(name: "wisp_type", description: "Type text at the current keyboard focus (use wisp_set for fields). Newline characters press Return, which sends in chat composers: use wisp_set or wisp_paste there.",
             schema: schema(["text": ["type": "string"]].merging(MCPServer.actionProps) { a, _ in a }, required: ["text"])),
        Tool(name: "wisp_key", description: "Press a key chord in xdotool syntax: 'Return', 'cmd+l', 'ctrl+shift+t', 'cmd+l,Return' (comma = sequence).",
             schema: schema(["key": ["type": "string"]].merging(MCPServer.actionProps) { a, _ in a }, required: ["key"])),
        Tool(name: "wisp_set", description: "Replace the value of an editable element (text field, combo, slider) by index.",
             schema: schema(["el": ["type": "integer"], "value": ["type": "string"]].merging(MCPServer.actionProps) { a, _ in a }, required: ["el", "value"])),
        Tool(name: "wisp_scroll", description: "Scroll at an element or point by pages in a direction.",
             schema: schema(["el": ["type": "integer"], "at": ["type": "array", "items": ["type": "number"]], "direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "pages": ["type": "number"]].merging(MCPServer.actionProps) { a, _ in a }, required: ["direction"])),
        Tool(name: "wisp_drag", description: "Drag from one point to another (coordinates like `at`).",
             schema: schema(["from": ["type": "array", "items": ["type": "number"]], "to": ["type": "array", "items": ["type": "number"]]].merging(MCPServer.actionProps) { a, _ in a }, required: ["from", "to"])),
        Tool(name: "wisp_action", description: "Invoke a secondary accessibility action listed in braces in the state text, e.g. ShowMenu, Expand, Increment.",
             schema: schema(["el": ["type": "integer"], "action": ["type": "string"]].merging(MCPServer.actionProps) { a, _ in a }, required: ["el", "action"])),
        Tool(name: "wisp_select_text", description: "Select text (or place the cursor before/after it) inside an editable element.",
             schema: schema(["el": ["type": "integer"], "text": ["type": "string"], "prefix": ["type": "string"], "suffix": ["type": "string"], "selection": ["type": "string", "enum": ["text", "cursor_before", "cursor_after"]]].merging(MCPServer.actionProps) { a, _ in a }, required: ["el", "text"])),
        Tool(name: "wisp_paste", description: "Paste text/markdown/html via the clipboard (clipboard is restored afterwards). Prefer for multi-line or formatted text.",
             schema: schema(["text": ["type": "string"], "format": ["type": "string", "enum": ["text", "md", "html"]]].merging(MCPServer.actionProps) { a, _ in a }, required: ["text"])),
        Tool(name: "wisp_batch", description: "Run several actions in one round trip: steps are objects like {\"kind\":\"click\",\"el\":4}, {\"kind\":\"type\",\"text\":\"hi\"}, {\"kind\":\"key\",\"key\":\"Return\"}, {\"kind\":\"state\"}, {\"kind\":\"sleep\",\"seconds\":0.5}. Stops at the first failure; returns the final state.",
             schema: schema(["steps": ["type": "array", "items": ["type": "object"]]].merging(MCPServer.actionProps) { a, _ in a }, required: ["steps"])),
        Tool(name: "wisp_launch", description: "Launch an app by name/bundle id in the background (it is not brought to the front unless activate=true) and list its windows. Waits until the app shows a window.",
             schema: schema(["activate": ["type": "boolean", "description": "Bring the app to the front after launching (default false: it stays behind the user's windows)."]], required: ["app"])),
        Tool(name: "wisp_activate", description: "Bring an app (and optionally one of its windows) to the front. Only for the rare app that ignores in-place input; Wisp normally operates without raising windows.",
             schema: schema([:], required: ["app"])),
        Tool(name: "wisp_end", description: "End the control session for an app, a Chrome tab (closes it), or everything (no app/tab), hiding the cursor and banner. A bare wisp_end ends the turn: Chrome tabs you opened that are not marked deliverable/handoff are closed.", schema: schema([:])),
        Tool(name: "wisp_turn_end", description: "End every Wisp session: call when the task is finished or the user interrupts; closes unmarked agent tabs and hides the cursor.", schema: ["type": "object", "properties": [:]]),
        Tool(name: "wisp_cancel", description: "Cancel the action currently running in the daemon.", schema: ["type": "object", "properties": [:]]),
        Tool(name: "wisp_status", description: "Daemon status: what Wisp is controlling, activity (idle/observing/acting/paused), whether the screen is locked, open sessions, a pending approval prompt, and the last user intervention.", schema: ["type": "object", "properties": [:]]),
        Tool(name: "wisp_doctor", description: "Health check: daemon version and pid, and whether Accessibility (required) and Screen Recording (screenshots) are granted, with what to tell the user if not.", schema: ["type": "object", "properties": [:]]),
        Tool(name: "wisp_instructions", description: "App-specific guidance catalog: `list` shows every built-in and user instruction file; `show` (app) prints the candidates, the matched files and the composed guidance for an app without controlling it.",
             schema: ["type": "object", "properties": ["command": ["type": "string", "enum": ["list", "show"]], "app": ["type": "string"]], "required": ["command"]]),
        Tool(name: "wisp_policy", description: "Read or change the Wisp policy (~/.config/wisp/policy.json): deny/allow/background lists, approval mode (off|high-risk|all), highRisk, forbidden, blockedURLs, allowSecureFields, cursorEnabled, lensEnabled, bannerText, bannerHint, instructionsMode (merge|replace|off), chromePort, settle timings. `set` merges `changes` into the current policy. Changing policy is a system-settings-class action: confirm with the user first.",
             schema: ["type": "object", "properties": ["command": ["type": "string", "enum": ["get", "set"]], "changes": ["type": "object", "description": "Policy fields to merge for `set`."]], "required": ["command"]]),
        Tool(name: "wisp_approvals", description: "Per-app approval grants (session/always): `list` shows them, `clear` revokes one app (`app`) or all.",
             schema: ["type": "object", "properties": ["command": ["type": "string", "enum": ["list", "clear"]], "app": ["type": "string", "description": "clear: bundle id to revoke (omit to revoke all)."]], "required": ["command"]]),
        Tool(name: "wisp_log", description: "Tail the daemon log (default 60 lines) for troubleshooting.",
             schema: ["type": "object", "properties": ["lines": ["type": "integer"]]]),
        Tool(name: "wisp_chrome", description: "Chrome helpers. With the Wisp Chrome extension connected (status reports `extension.connected`), tabs lists the user's own tabs first (browser=user, the active one first), tab=active is the user\'s active tab and new opens in the user's browser (browser=wisp forces the separate Wisp Chrome). Commands: status, extension (action: install|status|path; install copies the extension and registers the native host, the user then loads it once on chrome://extensions), launch (starts the separate Wisp Chrome hidden in the background with a debug port and a dedicated profile; visible=true shows it), tabs (with [user]/[agent]/[deliverable]/[handoff] marks), new (url, browser), goto (tab,url), eval (tab, expression), close, back, forward, reload, upload (tab, files; el optional: fills the file input you clicked), dialog (tab, accept, text: answers the alert/confirm/prompt that wisp_state reports), mark (tab, mark: deliverable/handoff keep the tab past wisp_end), show (tab optional: bring Chrome forward), hide. Then use `tab` in the other tools.",
             schema: ["type": "object", "properties": ["command": ["type": "string", "enum": ["status", "extension", "launch", "tabs", "new", "goto", "eval", "close", "back", "forward", "reload", "upload", "dialog", "mark", "show", "hide"]],
                                                       "action": ["type": "string", "enum": ["install", "status", "path"], "description": "extension: what to do (default status)."],
                                                       "browser": ["type": "string", "description": "new: user (your browser via the extension) or wisp (the separate Wisp Chrome); extension install: chrome|brave|edge|chromium|arc|vivaldi|all."],
                                                       "tab": ["type": "string"], "url": ["type": "string"], "expression": ["type": "string"], "port": ["type": "integer"], "profile": ["type": "string"],
                                                       "files": ["type": "array", "items": ["type": "string"], "description": "Absolute paths to upload."],
                                                       "el": ["type": "integer", "description": "File input element index for upload (optional after clicking the input)."],
                                                       "accept": ["type": "boolean", "description": "dialog: true accepts, false dismisses."], "text": ["type": "string", "description": "dialog: prompt() answer."],
                                                       "mark": ["type": "string", "enum": ["deliverable", "handoff", "none"]], "visible": ["type": "boolean", "description": "launch: show the window instead of starting hidden."]],
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
        case "notifications/initialized": break
        case "notifications/cancelled":
            // Best effort: ask the daemon to abort whatever is in flight. A separate connection keeps the tool
            // client's state untouched, and a daemon that is not running has nothing to cancel.
            let c = WispClient()
            if (try? c.connect(autoStart: false)) != nil { _ = try? c.call(Proto.Method.sessionCancel, [:], timeout: 5) }
        case "ping": write(Proto.result(id: id, [:]))
        case "tools/list":
            write(Proto.result(id: id, ["tools": .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema] })]))
        case "tools/call":
            let name = req["params"]["name"].string ?? ""
            let args = req["params"]["arguments"]
            do {
                let content = try call(tool: name, args: args)
                write(Proto.result(id: id, ["content": .array(content)]))
            } catch let e as WispError where e.code == .appNotAllowed || e.code == .blockedURL {
                // A refusal is a plain message for the model: the app is off limits or the user said no.
                write(Proto.result(id: id, ["content": [["type": "text", "text": .string(e.message)]], "isError": true]))
            } catch let e as WispError {
                // Interruptions become a sentence the model can relay to the user; other errors keep `name: message`.
                let text = e.userFacingText ?? "error \(e.code.name): \(e.message)" + (e.data.map { "\n" + $0.stringified(pretty: true) } ?? "")
                write(Proto.result(id: id, ["content": [["type": "text", "text": .string(text)]], "isError": true]))
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
        for k in ["full", "query", "screenshot", "bounds", "menus", "maxLines", "observe", "instructions", "space", "cursor", "activate"] where !a[k].isNull { j[k] = a[k] }
        if a["hid"].bool == true { j["delivery"] = "hid" }
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
        case "wisp_move", "wisp_mouse_down", "wisp_mouse_up":
            var a: [String: JSON] = ["kind": .string(tool == "wisp_move" ? "move" : tool == "wisp_mouse_down" ? "mouse_down" : "mouse_up")]
            for k in ["el", "at"] where !args[k].isNull { a[k] = args[k] }
            return try perform(.object(a))
        case "wisp_windows":
            let r = try client.call(Proto.Method.appWindows, try targetParams(args))
            let lines = (r["windows"].array ?? []).map { w in "\(w["id"].int.map(String.init) ?? "?")\t\(w["focused"].bool == true ? "*" : " ")\t\(w["title"].string ?? "")\t\(w["frame"].stringified())" }
            return [["type": "text", "text": .string(lines.isEmpty ? "no windows" : "id\tfocused\ttitle\tframe\n" + lines.joined(separator: "\n"))]]
        case "wisp_activate":
            let r = try client.call(Proto.Method.appActivate, try targetParams(args), timeout: 300)
            return [["type": "text", "text": .string("activated \(r["app"]["name"].string ?? "") window \(r["window"]["id"].int.map(String.init) ?? "?")")]]
        case "wisp_status":
            return [["type": "text", "text": .string(try client.call(Proto.Method.sessionStatus).stringified(pretty: true))]]
        case "wisp_doctor":
            let ping = try client.call(Proto.Method.ping)
            let ax = ping["permissions"]["accessibility"].bool == true
            let screen = ping["permissions"]["screenRecording"].bool == true
            var lines = ["wispd \(ping["version"].string ?? "?") pid \(ping["pid"].int ?? 0), api \(ping["serverApiVersion"].string ?? "?")",
                         "accessibility: \(ax ? "granted" : "MISSING (required): ask the user to allow Wisp in System Settings > Privacy & Security > Accessibility; the Wisp menu bar item has a shortcut")",
                         "screen recording: \(screen ? "granted" : "missing (screenshots disabled): ask the user to allow Wisp in System Settings > Privacy & Security > Screen Recording")"]
            lines.append("policy: \(WispPaths.policyPath); instructions: \(WispPaths.instructionsDir.path); log: \(WispPaths.logPath)")
            return [["type": "text", "text": .string(lines.joined(separator: "\n"))]]
        case "wisp_instructions":
            switch args["command"].string ?? "list" {
            case "show":
                guard let app = args["app"].string else { throw WispError(.invalidParams, "show needs `app`") }
                let r = try client.call(Proto.Method.appInstructions, ["app": .string(app)])
                let matched = (r["matched"].array ?? []).map { "\($0["stem"].string ?? "") (\($0["source"].string ?? ""))" }
                var text = "app: \(r["app"]["name"].string ?? "") (\(r["app"]["bundleId"].string ?? "no bundle id"))\(r["isBrowser"].bool == true ? ", browser" : "")\nmode: \(r["mode"].string ?? "")\ncandidates: \((r["candidates"].array ?? []).compactMap { $0.string }.joined(separator: ", "))\nmatched: \(matched.isEmpty ? "none" : matched.joined(separator: ", "))"
                if let t = r["text"].string { text += "\n\n" + t }
                return [["type": "text", "text": .string(text)]]
            default:
                let r = Commands.instructionsCatalog()
                let rows = (r["stems"].array ?? []).map { "\($0["stem"].string ?? "")  \($0["overridesBuiltin"].bool == true ? "user (overrides builtin)" : ($0["source"].string ?? ""))" }
                return [["type": "text", "text": .string(rows.joined(separator: "\n") + "\n(user files: \(r["directory"].string ?? ""))")]]
            }
        case "wisp_policy":
            if args["command"].string == "set" {
                var p = try client.call(Proto.Method.policyGet)
                for (k, v) in args["changes"].object ?? [:] { p[k] = v }
                return [["type": "text", "text": .string(try client.call(Proto.Method.policySet, p).stringified(pretty: true))]]
            }
            return [["type": "text", "text": .string(try client.call(Proto.Method.policyGet).stringified(pretty: true))]]
        case "wisp_approvals":
            if args["command"].string == "clear" {
                var p: [String: JSON] = [:]
                if let app = args["app"].string { p["app"] = .string(app) }
                _ = try client.call(Proto.Method.approvalsClear, .object(p))
                return [["type": "text", "text": .string(args["app"].string.map { "approval revoked for \($0)" } ?? "approvals cleared")]]
            }
            let r = try client.call(Proto.Method.approvalsList)
            let rows = (r["grants"].array ?? []).map { "\($0["app"].string ?? "")  \($0["grant"].string ?? "")\($0["active"].bool == false ? " (expired: from an earlier daemon run)" : "")" }
            return [["type": "text", "text": .string(rows.isEmpty ? "no approvals" : rows.joined(separator: "\n"))]]
        case "wisp_log":
            let r = try client.call(Proto.Method.daemonLog, ["lines": .int(args["lines"].int ?? 60)])
            return [["type": "text", "text": .string(r["log"].string ?? "")]]
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
            // Launching may wait for the user's approval prompt (up to 120 s), so this needs the long timeout.
            let r = try client.call(Proto.Method.appLaunch, ["app": args["app"], "activate": .bool(args["activate"].bool ?? false)], timeout: 300)
            return [["type": "text", "text": .string(r.stringified(pretty: true))]]
        case "wisp_turn_end":
            _ = try client.call(Proto.Method.sessionEnd, [:])
            return [["type": "text", "text": "turn ended: every Wisp session closed"]]
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
            if let files = args["files"].array { p["files"] = .array(files) }
            if let el = args["el"].int { p["el"] = .int(el) }
            if let accept = args["accept"].bool { p["accept"] = .bool(accept) }
            if let text = args["text"].string { p["text"] = .string(text) }
            if let m = args["mark"].string { p["mark"] = .string(m) }
            if let v = args["visible"].bool { p["visible"] = .bool(v) }
            if let b = args["browser"].string, cmd == "new" { p["browser"] = .string(b) }
            if cmd == "extension" {
                switch args["action"].string ?? "status" {
                case "install":
                    let r = try ChromeExtensionSetup.install(browsers: args["browser"].string.map { [$0] } ?? [], open: true)
                    return [["type": "text", "text": .string("extension copied to \(r["dir"].string ?? ""); native messaging host registered for \((r["hosts"].array ?? []).compactMap { $0["browser"].string }.joined(separator: ", ")). The user must load it once: chrome://extensions, Developer mode, Load unpacked, choose \(r["dir"].string ?? ""). Then wisp_chrome status reports extension.connected.")]]
                case "path":
                    return [["type": "text", "text": .string(ChromeExtension.installDir.path)]]
                default:
                    return [["type": "text", "text": .string(ChromeExtensionSetup.describe(ChromeExtensionSetup.status(client: client)))]]
                }
            }
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
            case "upload": method = Proto.Method.chromeTabUpload
            case "dialog": method = Proto.Method.chromeTabDialog
            case "mark": method = Proto.Method.chromeTabMark
            case "show": method = Proto.Method.chromeShow
            case "hide": method = Proto.Method.chromeHide
            default: throw WispError(.invalidParams, "unknown chrome command \(cmd)")
            }
            let r = try client.call(method, .object(p), timeout: 120)
            if !r["state"].isNull { return stateContent(r["state"]) }
            if cmd == "tabs" {
                let lines = (r.array ?? []).map { t -> String in
                    var tags = t["browser"].string == "user" ? ["user" + (t["active"].bool == true ? ", active" : "")] : []
                    if let m = t["mark"].string { tags.append(m) }
                    return "\(t["id"].string ?? "")  \(t["title"].string ?? "")  \(t["url"].string ?? "")" + (tags.isEmpty ? "" : "  [" + tags.joined(separator: "] [") + "]")
                }
                return [["type": "text", "text": .string(lines.joined(separator: "\n"))]]
            }
            return [["type": "text", "text": .string(r.stringified(pretty: true))]]
        default:
            throw WispError(.unknownMethod, "unknown tool \(tool)")
        }
    }

    static let instructions = """
    Wisp controls macOS apps through accessibility and Chrome tabs through DevTools. Workflow: wisp_state (reads an indexed tree) → act with wisp_click/wisp_set/wisp_key/... (each returns the new state diff) → repeat. Every CLI capability is a tool: wisp_windows/wisp_activate for windows, wisp_move/wisp_mouse_down/wisp_mouse_up for pointer control, wisp_status/wisp_doctor/wisp_log for health, wisp_instructions/wisp_policy/wisp_approvals for configuration, wisp_chrome for DevTools tabs, wisp_turn_end when done. Always use indices from the latest state. Prefer wisp_set for text fields and wisp_paste for long/multi-line text. Ask the user before irreversible or outward-facing actions (sending, deleting, paying, logging in, changing settings). If a result says "user input detected", stop and re-read state. Some apps (System Settings, Terminal, Mail, ...) require the user to approve in a Wisp prompt on screen before the first call succeeds; if a tool reports that the user declined or that an app is forbidden or denied by policy, do not retry, tell the user.
    """
}
