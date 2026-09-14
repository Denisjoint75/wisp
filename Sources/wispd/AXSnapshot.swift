import AppKit
import ApplicationServices
import WispCore

/// Captures a window's accessibility tree into `UINode`s.
final class AXSnapshotter {
    struct Options {
        var maxDepth = 60
        var maxNodes = 6000
        var includeMenus = false
        var maxChildrenFetch = 400
        var valueMax = 2000
    }

    static let attrs = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
        kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
        kAXExpandedAttribute, kAXURLAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXRoleDescriptionAttribute,
        "AXDisclosing", "AXElementBusy", kAXHiddenAttribute, kAXIdentifierAttribute, "AXDOMIdentifier",
    ]

    static let secondaryActionNames: [String: String] = [
        "AXPress": "Press", "AXShowMenu": "ShowMenu", "AXIncrement": "Increment", "AXDecrement": "Decrement",
        "AXConfirm": "Confirm", "AXCancel": "Cancel", "AXRaise": "Raise", "AXPick": "Pick", "AXOpen": "Open",
        "AXShowAlternateUI": "ShowAlternateUI", "AXShowDefaultUI": "ShowDefaultUI", "AXScrollToVisible": "ScrollToVisible",
        "AXZoomWindow": "Zoom", "AXDelete": "Delete", "AXShowDetails": "ShowDetails",
    ]

    private var count = 0
    private let options: Options
    private var deadline = Date.distantFuture
    /// The app's focused UI element; only this element is marked `focused` (AXFocused is unreliable on table cells).
    var focusedElement: AXEl?

    init(options: Options = Options()) { self.options = options }

    func snapshot(window: AXEl, windowFrame: CGRect, app: AXEl, extraRoots: [AXEl] = [], timeBudget: TimeInterval = 8) -> UINode {
        count = 0
        deadline = Date().addingTimeInterval(timeBudget)
        let root = build(window, depth: 0, clip: windowFrame)
        for extra in extraRoots {
            if let n = build(extra, depth: 1, clip: nil) { root?.add(n) }
        }
        return root ?? UINode(identity: window.identity, role: "window", rawRole: "AXWindow")
    }

    private func build(_ el: AXEl, depth: Int, clip: CGRect?) -> UINode? {
        if count >= options.maxNodes || depth > options.maxDepth || Date() > deadline { return nil }
        count += 1
        let v = el.values(AXSnapshotter.attrs)
        let rawRole = (v[kAXRoleAttribute] as? String) ?? "AXUnknown"
        let subrole = v[kAXSubroleAttribute] as? String
        let node = UINode(identity: el.identity, role: Roles.short(ax: rawRole, subrole: subrole), rawRole: rawRole)
        node.subrole = subrole
        node.handle = el
        if let t = v[kAXTitleAttribute] as? String, !t.isEmpty { node.name = t }
        if let d = v[kAXDescriptionAttribute] as? String, !d.isEmpty, d.range(of: "^view_[0-9]+$", options: .regularExpression) == nil {
            if node.name == nil { node.name = d } else if d != node.name { node.desc = d }
        }
        if let rd = v[kAXRoleDescriptionAttribute] as? String, node.role == "unknown", !rd.isEmpty { node.role = rd.lowercased() }
        if let h = v[kAXHelpAttribute] as? String, !h.isEmpty, h != node.name { node.help = h }
        if let p = v[kAXPlaceholderValueAttribute] as? String, !p.isEmpty { node.placeholder = p }
        if let u = v[kAXURLAttribute] { node.url = AXEl.stringify(u) }
        if let val = v[kAXValueAttribute] {
            switch node.role {
            case "checkbox", "radio", "switch", "toggle", "menuitem", "tab", "disclosure":
                if let n = val as? NSNumber {
                    switch n.intValue {
                    case 0: node.states.insert(.unchecked)
                    case 1: node.states.insert(.checked)
                    case 2: node.states.insert(.mixed)
                    default: node.value = AXEl.stringify(val)
                    }
                } else if let s = AXEl.stringify(val), !s.isEmpty, s != node.name { node.value = s }
            default:
                if var s = AXEl.stringify(val), !s.isEmpty {
                    if s.count > options.valueMax { s = String(s.prefix(options.valueMax)) + "…" }
                    if node.role == "txt", node.name == nil { node.name = s } else if s != node.name { node.value = s }
                }
            }
        }
        if let e = v[kAXEnabledAttribute] as? Bool, !e { node.states.insert(.disabled) }
        if let f = v[kAXFocusedAttribute] as? Bool, f {
            if let fe = focusedElement { if fe == el { node.states.insert(.focused) } } else { node.states.insert(.focused) }
        }
        if let s = v[kAXSelectedAttribute] as? Bool, s { node.states.insert(.selected) }
        let disclosable: Set<String> = ["disclosure", "combo", "popup", "row", "treeitem", "menubtn", "menuitem", "listitem", "btn", "outline", "cell", "tab", "menubaritem"]
        if let x = v[kAXExpandedAttribute] as? Bool, x || disclosable.contains(node.role) { node.states.insert(x ? .expanded : .collapsed) }
        if let x = v["AXDisclosing"] as? Bool, x || disclosable.contains(node.role) { node.states.insert(x ? .expanded : .collapsed) }
        if let b = v["AXElementBusy"] as? Bool, b { node.states.insert(.busy) }
        if let h = v[kAXHiddenAttribute] as? Bool, h { node.states.insert(.hidden) }
        if rawRole == "AXSecureTextField" || subrole == "AXSecureTextField" { node.states.insert(.secure); node.value = nil }
        if let p = v[kAXPositionAttribute] as? CGPoint, let s = v[kAXSizeAttribute] as? CGSize {
            node.frame = CGRect(origin: p, size: s).uiRect
        }
        if let id = (v[kAXIdentifierAttribute] as? String) ?? (v["AXDOMIdentifier"] as? String), !id.isEmpty, node.name == nil,
           node.role != "group", !id.hasPrefix("_NS") {
            node.desc = id
        }

        // Actions
        let actions = el.actionNames
        var secondary: [String] = []
        let contextMenuRoles: Set<String> = ["btn", "popup", "menubtn", "tab", "field", "textarea", "search", "combo", "menubaritem", "checkbox", "radio", "slider", "stepper", "dockitem"]
        for a in actions {
            if a == "AXPress" || a == "AXScrollToVisible" || a == "AXRaise" { continue }
            if a == "AXShowMenu", !contextMenuRoles.contains(node.role) { continue }
            secondary.append(AXSnapshotter.secondaryActionNames[a] ?? a.replacingOccurrences(of: "AX", with: ""))
        }
        node.actions = secondary
        node.valueSettable = ["field", "textarea", "secure-field", "search", "combo", "slider", "stepper", "datefield", "timefield", "colorwell"].contains(node.role)
            && el.isSettable(kAXValueAttribute)
        if node.valueSettable { node.states.insert(.editable) }
        if let ro = v[kAXValueAttribute], ro is String, node.role == "txt", el.isSettable(kAXValueAttribute) { node.valueSettable = true }

        // Children
        if node.states.contains(.hidden) { return node }
        if node.role == "menubaritem" && !options.includeMenus { return node }
        let kids = childElements(el, role: rawRole)
        for k in kids {
            if count >= options.maxNodes { break }
            if let c = build(k, depth: depth + 1, clip: clip) { node.add(c) }
        }
        return node
    }

    private func childElements(_ el: AXEl, role: String) -> [AXEl] {
        // Prefer visible subsets for large scrolling containers.
        if role == "AXTable" || role == "AXOutline" {
            if let rows = el.value(kAXVisibleRowsAttribute) as? [Any] {
                let r = rows.compactMap { $0 as? AXEl }
                if !r.isEmpty {
                    var out = r
                    if let header = el.value("AXHeader") as? AXEl { out.insert(header, at: 0) }
                    return Array(out.prefix(options.maxChildrenFetch))
                }
            }
        }
        if role == "AXList" || role == "AXScrollArea" || role == "AXBrowser" || role == "AXGroup" || role == "AXWebArea" {
            if let vis = el.value(kAXVisibleChildrenAttribute) as? [Any] {
                let r = vis.compactMap { $0 as? AXEl }
                if r.count > 0, r.count < (el.value(kAXChildrenAttribute) as? [Any])?.count ?? Int.max {
                    return Array(r.prefix(options.maxChildrenFetch))
                }
            }
        }
        return Array(el.children.prefix(options.maxChildrenFetch))
    }
}

enum ChromiumSupport {
    static let knownBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.spotify.client", "notion.id", "com.figma.Desktop",
        "com.hnc.Discord", "com.openai.chat", "com.openai.codex", "md.obsidian", "com.electron.*", "com.github.GitHubClient",
        "com.linear", "com.todesktop.230313mzl4w4u92", "com.postmanlabs.mac", "com.1password.1password", "us.zoom.xos",
    ]

    /// Asks Chromium/Electron apps to expose their full accessibility tree.
    static func enable(app: AXEl, bundleId: String?) -> Bool {
        var changed = false
        for attr in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            if (app.value(attr) as? Bool) != true {
                if app.set(attr, true) == .success { changed = true }
            }
        }
        return changed
    }

    static func isChromiumLike(bundleId: String?, path: String?) -> Bool {
        if let b = bundleId, knownBundles.contains(b) { return true }
        if let p = path {
            let fm = FileManager.default
            if fm.fileExists(atPath: p + "/Contents/Frameworks/Electron Framework.framework") { return true }
            if fm.fileExists(atPath: p + "/Contents/Frameworks/Chromium Embedded Framework.framework") { return true }
            if let items = try? fm.contentsOfDirectory(atPath: p + "/Contents/Frameworks"),
               items.contains(where: { $0.contains("Framework.framework") && ($0.contains("Chrome") || $0.contains("Electron")) }) { return true }
        }
        return false
    }
}
