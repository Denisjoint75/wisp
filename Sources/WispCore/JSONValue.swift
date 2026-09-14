import Foundation

/// A small dynamic JSON value used for the daemon protocol, the CLI and the CDP client.
public enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Construction

    public init(_ any: Any?) {
        guard let any = any else { self = .null; return }
        switch any {
        case let v as JSON: self = v
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber bridging: `1 as? Bool` succeeds, so inspect the CF type to tell booleans from numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let f as Float: self = .number(Double(f))
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON($0) })
        case let o as [String: Any]:
            var out: [String: JSON] = [:]
            for (k, v) in o { out[k] = JSON(v) }
            self = .object(out)
        case let o as [String: JSON]: self = .object(o)
        case let a as [JSON]: self = .array(a)
        default: self = .string(String(describing: any))
        }
    }

    public static func int(_ i: Int) -> JSON { .number(Double(i)) }

    // MARK: Accessors

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int: Int? {
        switch self {
        case .number(let d): return d.isFinite ? Int(d) : nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }
    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }

    public subscript(key: String) -> JSON {
        get { object?[key] ?? .null }
        set {
            var o = object ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }
    public subscript(index: Int) -> JSON {
        guard let a = array, index >= 0, index < a.count else { return .null }
        return a[index]
    }

    public var stringArray: [String]? { array?.compactMap { $0.string } }

    // MARK: Serialization

    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return Int64(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.toAny() }
            return out
        }
    }

    public func data(pretty: Bool = false) -> Data {
        var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        if pretty { opts.insert(.withoutEscapingSlashes) }
        return (try? JSONSerialization.data(withJSONObject: toAny(), options: opts)) ?? Data("null".utf8)
    }

    public func stringified(pretty: Bool = false) -> String {
        String(decoding: data(pretty: pretty), as: UTF8.self)
    }

    public static func parse(_ data: Data) throws -> JSON {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any)
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension Dictionary where Key == String, Value == JSON {
    /// Builds an object dropping `.null` values, handy for optional fields.
    static func compact(_ pairs: [(String, JSON?)]) -> JSON {
        var o: [String: JSON] = [:]
        for (k, v) in pairs { if let v = v, !v.isNull { o[k] = v } }
        return .object(o)
    }
}
