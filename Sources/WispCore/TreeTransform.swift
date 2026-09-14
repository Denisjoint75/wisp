import Foundation

/// Rewrites a raw accessibility tree into the compact tree the renderer prints.
public enum TreeTransform {
    public struct Options {
        public var clip: UIRect?
        public var maxChildren = 60
        public var maxNodes = 4000
        public var dropOffscreen = true
        public init() {}
    }

    public static func apply(_ root: UINode, options: Options = Options()) -> UINode {
        if let clip = options.clip {
            markOffscreen(root, clip: clip)
            if options.dropOffscreen { dropOffscreen(root, clip: clip) }
        }
        associateTitles(root)
        mergeRepetitiveText(root)
        unwrapTrivialGroups(root)
        pruneEmptyContainers(root)
        limitChildren(root, max: options.maxChildren)
        capNodes(root, max: options.maxNodes)
        reparent(root)
        return root
    }

    /// Marks nodes whose frame lies entirely outside the clip rect as offscreen (used to hint that a click will scroll).
    static func markOffscreen(_ node: UINode, clip: UIRect) {
        for child in node.children { markOffscreen(child, clip: clip) }
        if let f = node.frame, !f.isEmpty, !f.intersects(clip), node.role != "window", node.role != "app" {
            node.states.insert(.offscreen)
        }
    }

    /// Removes nodes that are completely outside the clip rect (or have zero size) unless they carry visible descendants.
    /// Interactive controls are kept even when offscreen so they can still be targeted (the action scrolls them in).
    static func dropOffscreen(_ node: UINode, clip: UIRect) {
        node.children = node.children.filter { child in
            dropOffscreen(child, clip: clip)
            guard let f = child.frame else { return true }
            let visible = !f.isEmpty && f.intersects(clip)
            if visible { return true }
            if !child.children.isEmpty { return true }
            if child.states.contains(.focused) { return true }
            // Keep interactive controls and menu items even when off-window: the caller scrolls them into view on use.
            if interactiveRoles.contains(child.role) { return true }
            if child.role == "menuitem" || child.role == "menu" { return true }
            return false
        }
    }

    public static let interactiveRoles: Set<String> = ["field", "textarea", "secure-field", "search", "checkbox", "radio",
        "combo", "popup", "slider", "stepper", "switch", "toggle", "colorwell", "datefield", "timefield", "btn",
        "link", "tab", "menuitem", "menubaritem", "option", "disclosure", "stepper"]

    /// Gives unnamed controls the text of a static-text sibling that precedes them.
    static func associateTitles(_ node: UINode) {
        var out: [UINode] = []
        var i = 0
        let c = node.children
        while i < c.count {
            let n = c[i]
            if n.role == "txt", n.children.isEmpty, let t = n.name ?? n.value, !t.isEmpty, i + 1 < c.count {
                let next = c[i + 1]
                let labelable: Set<String> = ["field", "textarea", "secure-field", "search", "checkbox", "radio", "combo",
                                              "popup", "slider", "stepper", "switch", "toggle", "colorwell", "datefield", "timefield"]
                if labelable.contains(next.role), (next.name ?? "").isEmpty {
                    next.name = t
                    out.append(next)
                    i += 2
                    continue
                }
            }
            out.append(n)
            i += 1
        }
        node.children = out
        for ch in node.children { associateTitles(ch) }
    }

    /// Collapses runs of plain text siblings into one text node when the parent is a simple container.
    static func mergeRepetitiveText(_ node: UINode) {
        for ch in node.children { mergeRepetitiveText(ch) }
        guard node.children.count > 1 else { return }
        var out: [UINode] = []
        var run: [UINode] = []
        func flush() {
            if run.count >= 2 {
                let joined = run.compactMap { $0.name ?? $0.value }.joined(separator: " ")
                let m = run[0]
                m.name = joined
                m.value = nil
                if let f0 = run[0].frame, let f1 = run[run.count - 1].frame {
                    m.frame = UIRect(x: min(f0.x, f1.x), y: min(f0.y, f1.y), w: max(f0.maxX, f1.maxX) - min(f0.x, f1.x), h: max(f0.maxY, f1.maxY) - min(f0.y, f1.y))
                }
                out.append(m)
            } else {
                out.append(contentsOf: run)
            }
            run = []
        }
        for ch in node.children {
            let plain = ch.role == "txt" && ch.children.isEmpty && ch.actions.isEmpty && !ch.states.contains(.focused)
                && !ch.valueSettable && (ch.name ?? ch.value ?? "").count < 400
            if plain { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        node.children = out
    }

    /// Unwraps containers that carry no information and have exactly one child.
    static func unwrapTrivialGroups(_ node: UINode) {
        var out: [UINode] = []
        for var ch in node.children {
            while ch.isContainerRole, ch.role != "window", ch.role != "web", ch.role != "sheet", ch.role != "dialog",
                  ch.role != "menu", !ch.hasDescriptiveContent, ch.children.count == 1, ch.note == nil {
                let only = ch.children[0]
                if ch.frame != nil, only.frame == nil { only.frame = ch.frame }
                ch = only
            }
            unwrapTrivialGroups(ch)
            out.append(ch)
        }
        node.children = out
    }

    /// Drops containers that have neither content nor children.
    static func pruneEmptyContainers(_ node: UINode) {
        for ch in node.children { pruneEmptyContainers(ch) }
        node.children = node.children.filter { ch in
            if ch.children.isEmpty, ch.isContainerRole, !ch.hasDescriptiveContent, ch.note == nil { return false }
            if ch.children.isEmpty, (ch.role == "txt" || ch.role == "p" || ch.role == "inline" || ch.role == "br" || ch.role == "ignored"),
               (ch.name ?? ch.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if ch.role == "ignored" || ch.role == "inline" || ch.role == "br" { return false }
            if ch.children.isEmpty, (ch.role == "img" || ch.role == "separator" || ch.role == "splitter" || ch.role == "growarea" || ch.role == "matte"),
               !ch.hasDescriptiveContent, !ch.states.contains(.focused) { return false }
            return true
        }
    }

    /// Caps the number of children per container, keeping focused/selected ones and a window around them.
    static func limitChildren(_ node: UINode, max: Int) {
        if node.children.count > max {
            let c = node.children
            let pivot = c.firstIndex { $0.states.contains(.focused) || $0.states.contains(.selected) } ?? 0
            let start = Swift.max(0, Swift.min(pivot - max / 4, c.count - max))
            let end = Swift.min(c.count, start + max)
            node.children = Array(c[start..<end])
            let hidden = c.count - node.children.count
            let marker = UINode(identity: node.identity + "#trunc", role: "note", rawRole: "note")
            marker.note = "[truncated to \(node.children.count) of \(c.count) children; \(hidden) not shown (range \(start)..<\(end))]"
            node.children.append(marker)
        }
        for ch in node.children { limitChildren(ch, max: max) }
    }

    static func capNodes(_ root: UINode, max: Int) {
        var count = 0
        func visit(_ n: UINode) {
            count += 1
            if count > max { n.children = []; return }
            var kept: [UINode] = []
            for c in n.children {
                if count > max { break }
                visit(c)
                kept.append(c)
            }
            if kept.count < n.children.count {
                let marker = UINode(identity: n.identity + "#cap", role: "note", rawRole: "note")
                marker.note = "[tree capped at \(max) nodes; use --query to narrow]"
                kept.append(marker)
            }
            n.children = kept
        }
        visit(root)
    }

    static func reparent(_ node: UINode) {
        for c in node.children { c.parent = node; reparent(c) }
    }

    /// Keeps only nodes matching a case-insensitive query and their ancestors.
    public static func filter(_ root: UINode, query: String) -> UINode {
        let q = query.lowercased()
        func matches(_ n: UINode) -> Bool {
            for s in [n.name, n.value, n.placeholder, n.desc, n.url, n.help, n.role] {
                if let s = s, s.lowercased().contains(q) { return true }
            }
            return false
        }
        func prune(_ n: UINode) -> Bool {
            var keep = matches(n)
            var kids: [UINode] = []
            for c in n.children where prune(c) { kids.append(c); keep = true }
            n.children = kids
            return keep
        }
        let copy = root.copy()
        _ = prune(copy)
        reparent(copy)
        return copy
    }
}
