import Foundation

/// Per-app instruction catalog: the built-in texts (generated from `Resources/AppInstructions/*.md`) merged with
/// the user's own Markdown files under `WispPaths.instructionsDir`. Mirrors Codex's AppInstructions mechanism:
/// the daemon prepends the composed text to the first observation of an app.
///
/// Pure Foundation; the caller (daemon) supplies the app metadata it reads from `NSRunningApplication` and the
/// bundle's `Info.plist`.
public struct InstructionCatalog {
    /// How user files under `userDir` combine with the built-in texts.
    public enum Mode: String {
        /// A user file replaces the built-in text of the same stem; other built-ins still apply.
        case merge
        /// As soon as any user file matches, every built-in text (the browser block included) is ignored.
        case replace
        /// No instructions at all.
        case off
    }

    /// Extra stems tried before the bundle id, kept for parity with Codex (which keys Music through an
    /// `AppleMusic` file). The override only adds a candidate; whichever file exists wins.
    public static let overrides: [String: [String]] = ["com.apple.Music": ["AppleMusic"]]

    /// Bundle ids that always receive the `_browser` block, even without an `http` URL scheme in `Info.plist`.
    public static let knownBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.apple.Safari", "com.operasoftware.Opera",
    ]

    /// Stem of the block injected for web browsers.
    public static let browserStem = "_browser"

    /// The result of `compose`: the pieces that were used, in order, and the joined text.
    public struct Composition {
        /// `(stem, source)` per piece; `source` is `"builtin"` or `"user"`.
        public var pieces: [(stem: String, source: String)]
        /// Pieces joined with a blank line, or nil when nothing applied.
        public var text: String?

        public init(pieces: [(stem: String, source: String)] = [], text: String? = nil) {
            self.pieces = pieces
            self.text = text
        }
    }

    public let builtin: [String: String]
    public let userDir: URL
    public let mode: Mode

    public init(builtin: [String: String] = BuiltinInstructions.text, userDir: URL, mode: Mode = .merge) {
        self.builtin = builtin
        self.userDir = userDir
        self.mode = mode
    }

    /// Stems to look up for an app, most specific first: override stems, bundle id, bundle name (`CFBundleName`),
    /// localized name and the `.app` folder name. Nil and empty values are dropped, duplicates removed.
    public func candidates(bundleId: String?, bundleName: String?, localizedName: String?, folderName: String?) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var raw: [String?] = []
        if let id = bundleId, let extra = Self.overrides[id] { raw.append(contentsOf: extra) }
        raw.append(contentsOf: [bundleId, bundleName, localizedName, folderName])
        for case let s? in raw {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || seen.contains(t) { continue }
            seen.insert(t)
            out.append(t)
        }
        return out
    }

    /// True when the app registers the `http` URL scheme in its `CFBundleURLTypes` or is a known browser.
    public static func isWebBrowser(infoDictionary: [String: Any]?, bundleId: String?) -> Bool {
        if let id = bundleId, knownBrowsers.contains(id) { return true }
        guard let types = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        for type in types {
            guard let schemes = type["CFBundleURLSchemes"] as? [String] else { continue }
            if schemes.contains(where: { $0.lowercased() == "http" }) { return true }
        }
        return false
    }

    /// The text for one stem: the user's `<userDir>/<stem>.md` when it exists and is not blank, else the built-in.
    /// Ignores `mode`; `compose` applies it.
    public func lookup(stem: String) -> (text: String, source: String)? {
        if let user = userText(stem: stem) { return (user, "user") }
        if let b = builtin[stem], !b.isEmpty { return (b, "builtin") }
        return nil
    }

    /// Composes the instruction text for an app from its candidate stems. The `_browser` block comes first when
    /// `isBrowser`; identical piece texts are emitted once; pieces are joined with a blank line.
    public func compose(candidates: [String], isBrowser: Bool) -> Composition {
        if mode == .off { return Composition() }
        var stems: [String] = []
        if isBrowser { stems.append(Self.browserStem) }
        for c in candidates where !stems.contains(c) { stems.append(c) }

        var found: [(stem: String, source: String, text: String)] = []
        for stem in stems {
            if let hit = lookup(stem: stem) { found.append((stem, hit.source, hit.text)) }
        }
        if mode == .replace, found.contains(where: { $0.source == "user" }) {
            found.removeAll { $0.source == "builtin" }
        }

        var pieces: [(stem: String, source: String)] = []
        var texts: [String] = []
        var seen = Set<String>()
        for f in found where !seen.contains(f.text) {
            seen.insert(f.text)
            pieces.append((f.stem, f.source))
            texts.append(f.text)
        }
        return Composition(pieces: pieces, text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"))
    }

    // MARK: - Private

    private func userText(stem: String) -> String? {
        // Stems come from app metadata; never let one escape the instructions directory.
        if stem.contains("/") || stem == "." || stem == ".." { return nil }
        let url = userDir.appendingPathComponent(stem + ".md", isDirectory: false)
        guard let data = FileManager.default.contents(atPath: url.path),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
