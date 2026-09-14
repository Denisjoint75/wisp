import Foundation

/// Wire protocol between `wisp` (client) and `wispd` (daemon): JSON-RPC 2.0 over a unix socket with u32 framing.
public enum Proto {
    public static let apiVersion = "WispIPC-1"

    public enum Method {
        public static let ping = "ping"
        public static let appsList = "apps.list"
        public static let appLaunch = "app.launch"
        public static let appActivate = "app.activate"
        public static let appWindows = "app.windows"
        public static let appState = "app.state"
        public static let appScreenshot = "app.screenshot"
        public static let appPerform = "app.perform"
        public static let appBatch = "app.batch"
        public static let appInstructions = "app.instructions"
        public static let sessionCancel = "session.cancel"
        public static let sessionEnd = "session.end"
        public static let sessionStatus = "session.status"
        public static let policyGet = "policy.get"
        public static let policySet = "policy.set"
        public static let chromeStatus = "chrome.status"
        public static let chromeLaunch = "chrome.launch"
        public static let chromeTabs = "chrome.tabs"
        public static let chromeTabNew = "chrome.tab.new"
        public static let chromeTabGoto = "chrome.tab.goto"
        public static let chromeTabEval = "chrome.tab.eval"
        public static let chromeTabClose = "chrome.tab.close"
        public static let chromeTabBack = "chrome.tab.back"
        public static let chromeTabForward = "chrome.tab.forward"
        public static let chromeTabReload = "chrome.tab.reload"
        public static let daemonShutdown = "daemon.shutdown"
        public static let daemonLog = "daemon.log"
    }

    public static func request(id: Int, method: String, params: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]
    }

    public static func result(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: JSON, _ error: WispError) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": error.json]
    }
}

/// A target that state/actions apply to: a native app window, or a Chrome tab.
public enum TargetSpec: Equatable, CustomStringConvertible {
    case app(String, window: String?)   // display name, bundle id, or path; optional window id/title
    case tab(String)                     // Chrome tab id

    public var description: String {
        switch self {
        case .app(let a, let w): return w.map { "\(a) (window \($0))" } ?? a
        case .tab(let t): return "chrome tab \(t)"
        }
    }

    public var json: JSON {
        switch self {
        case .app(let a, let w): return [String: JSON].compact([("app", .string(a)), ("window", w.map { .string($0) })])
        case .tab(let t): return ["tab": .string(t)]
        }
    }

    public static func parse(_ j: JSON) throws -> TargetSpec {
        if let t = j["tab"].string, !t.isEmpty { return .tab(t) }
        if let a = j["app"].string, !a.isEmpty { return .app(a, window: j["window"].string) }
        throw WispError(.invalidParams, "target requires `app` or `tab`")
    }
}

public enum MouseButton: String { case left, right, middle }

public enum ScrollDirection: String { case up, down, left, right }

public enum SelectionType: String { case text, cursorBefore = "cursor_before", cursorAfter = "cursor_after" }

public enum PasteFormat: String { case text, md, html }

/// One UI action. Encoded in JSON as `{"kind": "...", ...}`.
public enum UIAction: Equatable {
    case click(el: Int?, at: (Double, Double)?, button: MouseButton, count: Int)
    case drag(from: (Double, Double), to: (Double, Double))
    case move(el: Int?, at: (Double, Double)?)
    case type(text: String)
    case key(chord: String)
    case setValue(el: Int, value: String)
    case scroll(el: Int?, at: (Double, Double)?, direction: ScrollDirection, pages: Double)
    case secondaryAction(el: Int, name: String)
    case selectText(el: Int, text: String, prefix: String?, suffix: String?, selection: SelectionType)
    case paste(text: String, format: PasteFormat)
    case mouseDown(el: Int?, at: (Double, Double)?)
    case mouseUp(el: Int?, at: (Double, Double)?)

    public static func == (l: UIAction, r: UIAction) -> Bool { l.json == r.json }

    public var kind: String {
        switch self {
        case .click: return "click"
        case .drag: return "drag"
        case .move: return "move"
        case .type: return "type"
        case .key: return "key"
        case .setValue: return "set"
        case .scroll: return "scroll"
        case .secondaryAction: return "action"
        case .selectText: return "select_text"
        case .paste: return "paste"
        case .mouseDown: return "mouse_down"
        case .mouseUp: return "mouse_up"
        }
    }

    public var json: JSON {
        func pt(_ p: (Double, Double)?) -> JSON? { p.map { .array([.number($0.0), .number($0.1)]) } }
        switch self {
        case .click(let el, let at, let button, let count):
            return [String: JSON].compact([("kind", "click"), ("el", el.map { .int($0) }), ("at", pt(at)),
                                          ("button", .string(button.rawValue)), ("count", .int(count))])
        case .drag(let f, let t):
            return ["kind": "drag", "from": pt(f)!, "to": pt(t)!]
        case .move(let el, let at):
            return [String: JSON].compact([("kind", "move"), ("el", el.map { .int($0) }), ("at", pt(at))])
        case .type(let text): return ["kind": "type", "text": .string(text)]
        case .key(let chord): return ["kind": "key", "key": .string(chord)]
        case .setValue(let el, let v): return ["kind": "set", "el": .int(el), "value": .string(v)]
        case .scroll(let el, let at, let dir, let pages):
            return [String: JSON].compact([("kind", "scroll"), ("el", el.map { .int($0) }), ("at", pt(at)),
                                          ("direction", .string(dir.rawValue)), ("pages", .number(pages))])
        case .secondaryAction(let el, let name): return ["kind": "action", "el": .int(el), "action": .string(name)]
        case .selectText(let el, let text, let prefix, let suffix, let sel):
            return [String: JSON].compact([("kind", "select_text"), ("el", .int(el)), ("text", .string(text)),
                                          ("prefix", prefix.map { .string($0) }), ("suffix", suffix.map { .string($0) }),
                                          ("selection", .string(sel.rawValue))])
        case .paste(let text, let fmt): return ["kind": "paste", "text": .string(text), "format": .string(fmt.rawValue)]
        case .mouseDown(let el, let at):
            return [String: JSON].compact([("kind", "mouse_down"), ("el", el.map { .int($0) }), ("at", pt(at))])
        case .mouseUp(let el, let at):
            return [String: JSON].compact([("kind", "mouse_up"), ("el", el.map { .int($0) }), ("at", pt(at))])
        }
    }

    public static func parse(_ j: JSON) throws -> UIAction {
        func pt(_ v: JSON) -> (Double, Double)? {
            if let a = v.array, a.count == 2, let x = a[0].double, let y = a[1].double { return (x, y) }
            if let s = v.string {
                let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 { return (parts[0], parts[1]) }
            }
            return nil
        }
        func requireEl() throws -> Int {
            guard let el = j["el"].int else { throw WispError(.invalidParams, "`el` (element index) is required") }
            return el
        }
        let kind = j["kind"].string ?? j["cmd"].string ?? ""
        switch kind {
        case "click":
            let button = MouseButton(rawValue: j["button"].string ?? "left") ?? .left
            let count = j["count"].int ?? 1
            let el = j["el"].int, at = pt(j["at"])
            guard el != nil || at != nil else { throw WispError(.invalidParams, "click needs `el` or `at`") }
            return .click(el: el, at: at, button: button, count: max(1, min(count, 3)))
        case "drag":
            guard let f = pt(j["from"]), let t = pt(j["to"]) else { throw WispError(.invalidParams, "drag needs `from` and `to`") }
            return .drag(from: f, to: t)
        case "move":
            let el = j["el"].int, at = pt(j["at"])
            guard el != nil || at != nil else { throw WispError(.invalidParams, "move needs `el` or `at`") }
            return .move(el: el, at: at)
        case "type":
            guard let t = j["text"].string else { throw WispError(.invalidParams, "type needs `text`") }
            return .type(text: t)
        case "key":
            guard let k = j["key"].string, !k.isEmpty else { throw WispError(.invalidParams, "key needs `key`") }
            return .key(chord: k)
        case "set", "set_value", "setValue":
            guard let v = j["value"].string else { throw WispError(.invalidParams, "set needs `value`") }
            return .setValue(el: try requireEl(), value: v)
        case "scroll":
            guard let d = ScrollDirection(rawValue: (j["direction"].string ?? "down").lowercased()) else {
                throw WispError(.invalidParams, "scroll direction must be up, down, left or right")
            }
            let pages = j["pages"].double ?? 1
            guard pages > 0, pages.isFinite else { throw WispError(.invalidParams, "pages must be > 0") }
            return .scroll(el: j["el"].int, at: pt(j["at"]), direction: d, pages: pages)
        case "action", "secondary_action", "perform_secondary_action":
            guard let a = j["action"].string ?? j["name"].string else { throw WispError(.invalidParams, "action needs `action`") }
            return .secondaryAction(el: try requireEl(), name: a)
        case "select_text", "selectText":
            guard let t = j["text"].string else { throw WispError(.invalidParams, "select_text needs `text`") }
            let sel = SelectionType(rawValue: j["selection"].string ?? "text") ?? .text
            return .selectText(el: try requireEl(), text: t, prefix: j["prefix"].string, suffix: j["suffix"].string, selection: sel)
        case "paste":
            guard let t = j["text"].string else { throw WispError(.invalidParams, "paste needs `text`") }
            return .paste(text: t, format: PasteFormat(rawValue: j["format"].string ?? "text") ?? .text)
        case "mouse_down": return .mouseDown(el: j["el"].int, at: pt(j["at"]))
        case "mouse_up": return .mouseUp(el: j["el"].int, at: pt(j["at"]))
        default:
            throw WispError(.invalidParams, "unknown action kind `\(kind)`")
        }
    }

    /// Element index this action refers to, if any.
    public var elementIndex: Int? {
        switch self {
        case .click(let el, _, _, _): return el
        case .move(let el, _): return el
        case .scroll(let el, _, _, _): return el
        case .mouseDown(let el, _): return el
        case .mouseUp(let el, _): return el
        case .setValue(let el, _), .secondaryAction(let el, _), .selectText(let el, _, _, _, _): return el
        default: return nil
        }
    }
}

/// Options for `app.state`.
public struct StateOptions: Equatable {
    public var full: Bool = false
    public var query: String? = nil
    public var screenshot: Bool = false
    public var bounds: Bool = false
    public var includeMenus: Bool = false
    public var maxLines: Int = 400
    /// Per-app instructions in the response: nil delivers them once per session (first observation), true forces
    /// them on this read, false suppresses them.
    public var instructions: Bool? = nil

    public init() {}

    public static func parse(_ j: JSON) -> StateOptions {
        var o = StateOptions()
        o.full = j["full"].bool ?? false
        o.query = j["query"].string
        o.screenshot = j["screenshot"].bool ?? false
        o.bounds = j["bounds"].bool ?? false
        o.includeMenus = j["menus"].bool ?? false
        if let m = j["maxLines"].int, m > 20 { o.maxLines = m }
        o.instructions = j["instructions"].bool
        return o
    }

    public var json: JSON {
        [String: JSON].compact([("full", .bool(full)), ("query", query.map { .string($0) }), ("screenshot", .bool(screenshot)),
                                ("bounds", .bool(bounds)), ("menus", .bool(includeMenus)), ("maxLines", .int(maxLines)),
                                ("instructions", instructions.map { .bool($0) })])
    }
}
