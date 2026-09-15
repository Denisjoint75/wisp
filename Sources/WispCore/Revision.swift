import Foundation

/// A rendered snapshot of one target, kept so later actions can resolve element indices and diffs can be produced.
public final class Revision {
    public let id: Int
    public let rendered: RenderedTree
    public let root: UINode
    public let header: String
    public let createdAt: Date

    public init(id: Int, rendered: RenderedTree, root: UINode, header: String) {
        self.id = id
        self.rendered = rendered
        self.root = root
        self.header = header
        self.createdAt = Date()
    }

    public func node(at index: Int) -> UINode? { rendered.nodesByIndex[index] }
    public var fullText: String { header + "\n" + rendered.text }
}

public struct DiffResult {
    public let text: String
    public let changed: Int
    public let added: Int
    public let removed: Int
    public var isEmpty: Bool { changed == 0 && added == 0 && removed == 0 }
}

public enum TreeDiff {
    /// Returns a diff, or nil when the change is so large that a full tree is better.
    public static func diff(old: Revision, new: Revision, maxLines: Int) -> DiffResult? {
        var oldByIdentity: [String: RenderedLine] = [:]
        for l in old.rendered.lines where l.index != nil { oldByIdentity[l.identity] = l }
        var newIdentities = Set<String>()
        var out: [String] = []
        var changed = 0, added = 0
        for l in new.rendered.lines {
            guard l.index != nil else { continue }
            newIdentities.insert(l.identity)
            if let o = oldByIdentity[l.identity] {
                if o.body != l.body { out.append("~ " + l.text.trimmingCharacters(in: .whitespaces)); changed += 1 }
            } else {
                out.append("+ " + l.text.trimmingCharacters(in: .whitespaces)); added += 1
            }
        }
        var removedIdx: [Int] = []
        for (id, l) in oldByIdentity where !newIdentities.contains(id) { if let i = l.index { removedIdx.append(i) } }
        removedIdx.sort()
        let removed = removedIdx.count
        let indexed = new.rendered.lines.filter { $0.index != nil }.count
        if indexed > 20, Double(changed + added) > 0.6 * Double(indexed) { return nil }
        if removed > 0 { out.append("- " + ranges(removedIdx)) }
        var text: String
        if changed == 0 && added == 0 && removed == 0 {
            text = "# no change (revision \(new.id), same as \(old.id))"
        } else {
            let header = "# diff vs revision \(old.id) (~ changed, + added, - removed by index range); revision \(new.id)"
            if out.count > maxLines {
                let extra = out.count - maxLines
                out = Array(out.prefix(maxLines)) + ["… \(extra) more changed lines omitted; use --full or --query"]
            }
            text = ([header] + out).joined(separator: "\n")
        }
        return DiffResult(text: text, changed: changed, added: added, removed: removed)
    }

    static func ranges(_ sorted: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "[\(sorted[i])..\(sorted[j])]" : "[\(sorted[i])]")
            i = j + 1
        }
        return parts.joined(separator: " ")
    }

    /// Truncates a full render to the line budget, keeping the header. What falls below the cut is not lost
    /// entirely: the landmarks down there (pagination nav, a dialog, a form, the footer) and a few of their controls
    /// are listed after the omission note with their real indices, so the agent can act on them without a second
    /// `state --query`. On a long page the head of the tree is the header and the first results; the controls
    /// that move the task on (next page, load more, accept, submit) are usually at the bottom.
    public static func budget(_ text: String, maxLines: Int, summaryLines: Int = 40) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count <= maxLines { return text }
        var out = lines.prefix(maxLines).joined(separator: "\n")
            + "\n… \(lines.count - maxLines) more lines omitted (line budget \(maxLines)); use --query to narrow or raise --max-lines"
        let summary = cutSummary(Array(lines.dropFirst(maxLines)), maxLines: summaryLines)
        if !summary.isEmpty {
            out += "\n# below the cut, landmarks and some of their controls (indices are valid targets):\n" + summary.joined(separator: "\n")
        }
        return out
    }

    /// Container roles worth pointing at below the cut.
    public static let landmarkRoles: Set<String> = ["nav", "main", "banner", "footer", "region", "form", "aside", "dialog",
                                                    "sheet", "alert", "tabs", "toolbar", "menubar", "menu"]

    /// The landmark lines among `lines` (in order), each followed by the enabled, indexed controls whose nearest
    /// landmark it is: all of them up to `perLandmark`, otherwise the first ones and the last two around a count of
    /// the rest, because the control that moves on (Next, Submit, Accept) tends to be the last one. Nested
    /// landmarks keep their own controls: the pagination `nav` inside `main` lists the page buttons, not `main`.
    static func cutSummary(_ lines: [String], maxLines: Int, perLandmark: Int = 6) -> [String] {
        struct Entry { let line: String; let indent: Int; let role: String; var controls: [String] = [] }
        var entries: [Entry] = []
        var stack: [Int] = []   // indices into `entries` of the landmarks enclosing the current line
        for line in lines {
            guard let (indent, indexed, role) = parse(line) else { continue }
            while let top = stack.last, entries[top].indent >= indent { stack.removeLast() }
            if landmarkRoles.contains(role), indexed {
                entries.append(Entry(line: line, indent: indent, role: role))
                stack.append(entries.count - 1)
            } else if indexed, TreeTransform.interactiveRoles.contains(role), let top = stack.last, !isDisabled(line) {
                entries[top].controls.append(line)
            }
        }
        var out: [String] = []
        for e in entries {
            if out.count >= maxLines { out.append("… more landmarks below; use --query"); break }
            out.append(e.line)
            var shown = e.controls
            var hidden = 0
            if shown.count > perLandmark {
                hidden = shown.count - perLandmark
                shown = Array(shown.prefix(perLandmark - 2)) + Array(shown.suffix(2))
            }
            for (i, c) in shown.enumerated() where out.count < maxLines {
                if hidden > 0, i == perLandmark - 2 { out.append(String(repeating: " ", count: e.indent + 2) + "… \(hidden) more controls in this \(e.role)") }
                out.append(c)
            }
        }
        return out
    }

    /// A control the agent cannot act on right now; not worth a summary line.
    static func isDisabled(_ line: String) -> Bool {
        line.hasSuffix(" disabled") || line.contains(" disabled ")
    }

    /// `(indent, has index, role)` of a rendered tree line such as `      [757] btn "Go to page 2" offscreen` or
    /// `    group`; nil for headers, notes and blank lines.
    static func parse(_ line: String) -> (Int, Bool, String)? {
        let indent = line.prefix { $0 == " " }.count
        var rest = Substring(line.dropFirst(indent))
        if rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix("…") || rest.hasPrefix("[tree") || rest.hasPrefix("[truncated") { return nil }
        var indexed = false
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), Int(rest[rest.index(after: rest.startIndex)..<close]) != nil {
            indexed = true
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        let role = String(rest.prefix { $0 != " " })
        return role.isEmpty ? nil : (indent, indexed, role)
    }
}

/// Per-target revision history.
public final class RevisionStore {
    private var latestRevision: Revision?
    private var counter = 0

    public init() {}

    public var latest: Revision? { latestRevision }
    public var previousIndices: [String: Int] { latestRevision?.rendered.identityToIndex ?? [:] }

    public func commit(root: UINode, rendered: RenderedTree, header: String) -> Revision {
        counter += 1
        let r = Revision(id: counter, rendered: rendered, root: root, header: header)
        latestRevision = r
        return r
    }

    public func reset() { latestRevision = nil }
}
