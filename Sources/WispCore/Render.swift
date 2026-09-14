import Foundation

public struct RenderedLine: Equatable {
    public let identity: String
    public let index: Int?
    public let depth: Int
    public let body: String

    public var text: String {
        let indent = String(repeating: "  ", count: depth)
        if let i = index { return "\(indent)[\(i)] \(body)" }
        return "\(indent)\(body)"
    }
}

public struct RenderedTree {
    public let lines: [RenderedLine]
    public let nodesByIndex: [Int: UINode]
    public let identityToIndex: [String: Int]
    public var text: String { lines.map { $0.text }.joined(separator: "\n") }
}

public struct RenderOptions {
    public var showBounds = false
    public var valueMax = 240
    public var nameMax = 160
    public var urlMax = 100
    public init() {}
}

/// Renders a `UINode` tree into one line per element with stable indices.
public enum TreeRenderer {
    public static func render(_ root: UINode, previousIndices: [String: Int] = [:], options: RenderOptions = RenderOptions()) -> RenderedTree {
        var lines: [RenderedLine] = []
        var nodesByIndex: [Int: UINode] = [:]
        var identityToIndex: [String: Int] = [:]
        var used = Set(previousIndices.values)
        var next = (previousIndices.values.max() ?? -1) + 1
        var assignedPrevious = Set<Int>()

        func allocate(_ n: UINode) -> Int {
            if let prev = previousIndices[n.identity], !assignedPrevious.contains(prev) {
                assignedPrevious.insert(prev)
                return prev
            }
            while used.contains(next) { next += 1 }
            let i = next
            used.insert(i)
            next += 1
            return i
        }

        func visit(_ n: UINode, depth: Int) {
            if n.role == "note" {
                lines.append(RenderedLine(identity: n.identity, index: nil, depth: depth, body: n.note ?? "[...]"))
                return
            }
            var index: Int? = nil
            if n.isIndexable {
                let i = allocate(n)
                n.index = i
                index = i
                nodesByIndex[i] = n
                identityToIndex[n.identity] = i
            }
            lines.append(RenderedLine(identity: n.identity, index: index, depth: depth, body: describe(n, options)))
            for c in n.children { visit(c, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return RenderedTree(lines: lines, nodesByIndex: nodesByIndex, identityToIndex: identityToIndex)
    }

    public static func describe(_ n: UINode, _ o: RenderOptions) -> String {
        var parts: [String] = [n.role]
        if n.role == "heading", let s = n.subrole, let lvl = Int(s.filter { $0.isNumber }), lvl > 0 { parts[0] = "h\(lvl)" }
        if let name = n.name, !name.isEmpty { parts.append(quote(name, max: o.nameMax)) }
        if n.states.contains(.secure) {
            parts.append("value=\"••••\"")
        } else if let v = n.value, !v.isEmpty, v != n.name {
            parts.append("value=\(quote(v, max: o.valueMax))")
        }
        if let p = n.placeholder, !p.isEmpty, n.value?.isEmpty ?? true { parts.append("placeholder=\(quote(p, max: 80))") }
        if let d = n.desc, !d.isEmpty, d != n.name, d != n.value { parts.append("desc=\(quote(d, max: 120))") }
        if let u = n.url, !u.isEmpty { parts.append("url=\(shortenURL(u, max: o.urlMax))") }
        let order: [UIState] = [.focused, .disabled, .checked, .unchecked, .mixed, .expanded, .collapsed, .selected, .pressed,
                                .required, .invalid, .readonly, .busy, .offscreen]
        for s in order where n.states.contains(s) { parts.append(s.rawValue) }
        if !n.actions.isEmpty { parts.append("{" + n.actions.joined(separator: ", ") + "}") }
        if o.showBounds, let f = n.frame { parts.append("@" + f.description) }
        if let note = n.note { parts.append(note) }
        return parts.joined(separator: " ")
    }

    static func quote(_ s: String, max: Int) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        if t.count > max {
            t = String(t.prefix(max)) + "…(+\(s.count - max))"
        }
        return "\"" + t + "\""
    }

    static func shortenURL(_ u: String, max: Int) -> String {
        if u.count <= max { return u }
        let head = u.prefix(max - 12)
        let tail = u.suffix(8)
        return head + "…" + tail
    }
}
