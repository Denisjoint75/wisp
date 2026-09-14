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

    /// Truncates a full render to the line budget, keeping the header.
    public static func budget(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines { return text }
        let kept = lines.prefix(maxLines)
        return kept.joined(separator: "\n") + "\n… \(lines.count - maxLines) more lines omitted (line budget \(maxLines)); use --query to narrow or raise --max-lines"
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
