import AppKit
import ApplicationServices
import WispCore

/// Thin wrapper over `AXUIElement`.
struct AXEl: Hashable, CustomStringConvertible {
    let raw: AXUIElement

    init(_ raw: AXUIElement) {
        self.raw = raw
        AXUIElementSetMessagingTimeout(raw, 2.0)
    }

    static func app(pid: pid_t) -> AXEl { AXEl(AXUIElementCreateApplication(pid)) }
    static var systemWide: AXEl { AXEl(AXUIElementCreateSystemWide()) }

    static func == (l: AXEl, r: AXEl) -> Bool { CFEqual(l.raw, r.raw) }
    func hash(into h: inout Hasher) { h.combine(CFHash(raw)) }

    var identity: String { String(CFHash(raw), radix: 36) }

    var description: String { "\(role ?? "?")(\(title ?? ""))" }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(raw, &p)
        return p
    }

    func value(_ attr: String) -> Any? {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, attr as CFString, &out)
        guard err == .success, let v = out else { return nil }
        return AXEl.convert(v)
    }

    func values(_ attrs: [String]) -> [String: Any] {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(raw, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        var result: [String: Any] = [:]
        guard err == .success, let arr = out as? [Any] else { return result }
        for (i, a) in attrs.enumerated() where i < arr.count {
            let v = arr[i] as CFTypeRef
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            if let c = AXEl.convert(v) { result[a] = c }
        }
        return result
    }

    static func convert(_ v: CFTypeRef) -> Any? {
        let tid = CFGetTypeID(v)
        if tid == AXUIElementGetTypeID() { return AXEl(v as! AXUIElement) }
        if tid == AXValueGetTypeID() {
            let ax = v as! AXValue
            switch AXValueGetType(ax) {
            case .cgPoint: var p = CGPoint.zero; AXValueGetValue(ax, .cgPoint, &p); return p
            case .cgSize: var s = CGSize.zero; AXValueGetValue(ax, .cgSize, &s); return s
            case .cgRect: var r = CGRect.zero; AXValueGetValue(ax, .cgRect, &r); return r
            case .cfRange: var r = CFRange(); AXValueGetValue(ax, .cfRange, &r); return NSRange(location: r.location, length: r.length)
            default: return nil
            }
        }
        if tid == CFArrayGetTypeID() { return (v as! [Any]).compactMap { AXEl.convert($0 as CFTypeRef) } }
        if tid == CFStringGetTypeID() { return v as! String }
        if tid == CFAttributedStringGetTypeID() { return (v as! NSAttributedString).string }
        if tid == CFBooleanGetTypeID() { return (v as! Bool) }
        if tid == CFNumberGetTypeID() { return (v as! NSNumber) }
        if tid == CFURLGetTypeID() { return (v as! URL).absoluteString }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n }
        return nil
    }

    var role: String? { value(kAXRoleAttribute) as? String }
    var subrole: String? { value(kAXSubroleAttribute) as? String }
    var title: String? { value(kAXTitleAttribute) as? String }
    var stringValue: String? {
        guard let v = value(kAXValueAttribute) else { return nil }
        return AXEl.stringify(v)
    }
    var children: [AXEl] { (value(kAXChildrenAttribute) as? [Any])?.compactMap { $0 as? AXEl } ?? [] }
    var windows: [AXEl] { (value(kAXWindowsAttribute) as? [Any])?.compactMap { $0 as? AXEl } ?? [] }
    var focusedWindow: AXEl? { value(kAXFocusedWindowAttribute) as? AXEl }
    var mainWindow: AXEl? { value(kAXMainWindowAttribute) as? AXEl }
    var focusedElement: AXEl? { value(kAXFocusedUIElementAttribute) as? AXEl }
    var parent: AXEl? { value(kAXParentAttribute) as? AXEl }
    var isEnabled: Bool { (value(kAXEnabledAttribute) as? Bool) ?? true }

    var frame: CGRect? {
        let v = values([kAXPositionAttribute, kAXSizeAttribute])
        guard let p = v[kAXPositionAttribute] as? CGPoint, let s = v[kAXSizeAttribute] as? CGSize else { return nil }
        return CGRect(origin: p, size: s)
    }

    var actionNames: [String] {
        var out: CFArray?
        guard AXUIElementCopyActionNames(raw, &out) == .success, let a = out as? [String] else { return [] }
        return a
    }

    func actionDescription(_ action: String) -> String? {
        var out: CFString?
        guard AXUIElementCopyActionDescription(raw, action as CFString, &out) == .success else { return nil }
        return out as String?
    }

    func isSettable(_ attr: String) -> Bool {
        var s = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, attr as CFString, &s) == .success && s.boolValue
    }

    @discardableResult
    func set(_ attr: String, _ value: Any) -> AXError {
        AXUIElementSetAttributeValue(raw, attr as CFString, value as CFTypeRef)
    }

    @discardableResult
    func setRange(_ attr: String, _ range: NSRange) -> AXError {
        var r = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &r) else { return .failure }
        return AXUIElementSetAttributeValue(raw, attr as CFString, v)
    }

    @discardableResult
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(raw, action as CFString) }

    /// Whether the element still exists (cheap validity probe).
    var isValid: Bool {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &out)
        return err == .success
    }

    static func stringify(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let b as Bool: return b ? "1" : "0"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e12 { return String(Int(d)) }
            return String(format: "%.3g", d)
        case let r as NSRange: return "\(r.location)+\(r.length)"
        case let u as URL: return u.absoluteString
        case let p as CGPoint: return "\(Int(p.x)),\(Int(p.y))"
        case let a as [Any]: return a.compactMap { stringify($0) }.joined(separator: ", ")
        case is AXEl: return nil
        default: return String(describing: v)
        }
    }
}

extension CGRect {
    var uiRect: UIRect { UIRect(x: origin.x, y: origin.y, w: size.width, h: size.height) }
}

extension UIRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
