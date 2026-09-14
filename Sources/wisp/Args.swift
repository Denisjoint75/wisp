import Foundation
import WispCore

/// Tiny argument parser: positional words plus `--flag`, `--key value`, `--key=value`, `-k value`.
struct Args {
    private(set) var positional: [String] = []
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []

    static let valueOptions: Set<String> = [
        "app", "a", "tab", "t", "window", "w", "el", "e", "at", "from", "to", "button", "count", "pages", "query", "q",
        "max-lines", "format", "prefix", "suffix", "cursor", "space", "socket", "lines", "port", "profile", "url", "o", "out",
        "display", "file", "seconds", "expression", "key", "value", "text", "action", "deny", "allow", "background",
    ]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positional.append(contentsOf: argv[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq]), default: []].append(String(body[body.index(after: eq)...]))
                } else if Args.valueOptions.contains(body), i + 1 < argv.count {
                    options[body, default: []].append(argv[i + 1]); i += 1
                } else { flags.insert(body) }
            } else if a.hasPrefix("-"), a.count == 2, a != "-" {
                let k = String(a.dropFirst())
                if Args.valueOptions.contains(k), i + 1 < argv.count { options[k, default: []].append(argv[i + 1]); i += 1 } else { flags.insert(k) }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func flag(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
    func value(_ names: String...) -> String? { for n in names { if let v = options[n]?.last { return v } }; return nil }
    func values(_ names: String...) -> [String] { names.flatMap { options[$0] ?? [] } }
    func int(_ names: String...) -> Int? { value(names.first!).flatMap { Int($0) } ?? names.dropFirst().compactMap { value($0) }.compactMap { Int($0) }.first }
    func double(_ names: String...) -> Double? { names.compactMap { value($0) }.compactMap { Double($0) }.first }

    func point(_ name: String) throws -> (Double, Double)? {
        guard let v = value(name) else { return nil }
        let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw WispError(.invalidParams, "--\(name) expects x,y (got `\(v)`)")
        }
        return (x, y)
    }

    var rest: [String] { Array(positional.dropFirst()) }
}
