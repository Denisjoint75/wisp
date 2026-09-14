import Foundation

public struct UIRect: Equatable, CustomStringConvertible {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }
    public var area: Double { max(0, w) * max(0, h) }
    public func intersects(_ o: UIRect) -> Bool { !(o.x >= maxX || o.maxX <= x || o.y >= maxY || o.maxY <= y) }
    public func intersection(_ o: UIRect) -> UIRect {
        let nx = max(x, o.x), ny = max(y, o.y)
        let mx = min(maxX, o.maxX), my = min(maxY, o.maxY)
        return UIRect(x: nx, y: ny, w: max(0, mx - nx), h: max(0, my - ny))
    }
    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
    public var description: String { "\(Int(x.rounded())),\(Int(y.rounded())),\(Int(w.rounded())),\(Int(h.rounded()))" }
    public var json: JSON { [.number(x), .number(y), .number(w), .number(h)] }
}

public enum UIState: String, CaseIterable {
    case focused, disabled, checked, unchecked, mixed, expanded, collapsed, selected, busy, secure, editable,
         required, invalid, pressed, readonly, hidden, offscreen
}

/// Backend-independent accessibility node. Produced by the macOS AX snapshotter and by the Chrome CDP backend.
public final class UINode {
    public var identity: String
    public var role: String
    public var rawRole: String
    public var subrole: String?
    public var name: String?
    public var value: String?
    public var placeholder: String?
    public var desc: String?
    public var help: String?
    public var url: String?
    public var states: Set<UIState> = []
    public var actions: [String] = []
    public var frame: UIRect?
    public var children: [UINode] = []
    public var valueSettable = false
    public var note: String?
    public var handle: Any?
    public var index: Int?
    public weak var parent: UINode?

    public init(identity: String, role: String, rawRole: String) {
        self.identity = identity
        self.role = role
        self.rawRole = rawRole
    }

    public func add(_ child: UINode) {
        child.parent = self
        children.append(child)
    }

    public var hasDescriptiveContent: Bool {
        if let n = name, !n.isEmpty { return true }
        if let v = value, !v.isEmpty { return true }
        if let p = placeholder, !p.isEmpty { return true }
        if let d = desc, !d.isEmpty { return true }
        if let u = url, !u.isEmpty { return true }
        if !actions.isEmpty { return true }
        if states.contains(.focused) { return true }
        return false
    }

    public var isContainerRole: Bool { Roles.containerRoles.contains(role) }

    /// Whether the node gets an element index in rendered text.
    public var isIndexable: Bool {
        if Roles.interactiveRoles.contains(role) { return true }
        if !actions.isEmpty || valueSettable { return true }
        if role == "txt" || role == "heading" || role == "p" { return true }
        if isContainerRole { return hasDescriptiveContent && role != "window" && role != "web" }
        return hasDescriptiveContent
    }

    public func walk(_ body: (UINode, Int) -> Void, depth: Int = 0) {
        body(self, depth)
        for c in children { c.walk(body, depth: depth + 1) }
    }

    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    /// Deep copy used by tests and by query filtering.
    public func copy() -> UINode {
        let n = UINode(identity: identity, role: role, rawRole: rawRole)
        n.subrole = subrole; n.name = name; n.value = value; n.placeholder = placeholder; n.desc = desc
        n.help = help; n.url = url; n.states = states; n.actions = actions; n.frame = frame
        n.valueSettable = valueSettable; n.note = note; n.handle = handle; n.index = index
        for c in children { n.add(c.copy()) }
        return n
    }
}

public enum Roles {
    /// macOS AX roles -> short vocabulary.
    public static let axRoleMap: [String: String] = [
        "AXApplication": "app", "AXWindow": "window", "AXSheet": "sheet", "AXDrawer": "drawer", "AXDialog": "dialog",
        "AXToolbar": "toolbar", "AXTabGroup": "tabs", "AXGroup": "group", "AXList": "list", "AXOutline": "outline",
        "AXTable": "table", "AXRow": "row", "AXCell": "cell", "AXColumn": "column", "AXHeading": "heading",
        "AXStaticText": "txt", "AXTextField": "field", "AXTextArea": "textarea", "AXSecureTextField": "secure-field",
        "AXButton": "btn", "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "radio",
        "AXPopUpButton": "popup", "AXComboBox": "combo", "AXMenuButton": "menubtn", "AXMenu": "menu",
        "AXMenuBar": "menubar", "AXMenuBarItem": "menubaritem", "AXMenuItem": "menuitem", "AXSlider": "slider",
        "AXIncrementor": "stepper", "AXImage": "img", "AXScrollArea": "scroll", "AXScrollBar": "scrollbar",
        "AXWebArea": "web", "AXSplitGroup": "split", "AXSplitter": "splitter", "AXDisclosureTriangle": "disclosure",
        "AXProgressIndicator": "progress", "AXBusyIndicator": "busy", "AXValueIndicator": "indicator",
        "AXBrowser": "browser", "AXLayoutArea": "layout", "AXLayoutItem": "layoutitem", "AXLevelIndicator": "level",
        "AXDateField": "datefield", "AXTimeField": "timefield", "AXColorWell": "colorwell", "AXHelpTag": "tooltip",
        "AXGrid": "grid", "AXUnknown": "unknown", "AXDockItem": "dockitem", "AXHandle": "handle",
        "AXRelevanceIndicator": "relevance", "AXGrowArea": "growarea", "AXMatte": "matte", "AXRuler": "ruler",
        "AXRulerMarker": "marker", "AXPopover": "popover", "AXSwitch": "switch", "AXToggle": "toggle",
    ]

    /// ARIA / Chrome AX roles -> short vocabulary.
    public static let ariaRoleMap: [String: String] = [
        "RootWebArea": "web", "WebArea": "web", "button": "btn", "link": "link", "textbox": "field", "searchbox": "search",
        "combobox": "combo", "listbox": "list", "option": "option", "checkbox": "checkbox", "radio": "radio",
        "switch": "switch", "menuitem": "menuitem", "menuitemcheckbox": "menuitem", "menuitemradio": "menuitem",
        "menu": "menu", "menubar": "menubar", "heading": "heading", "image": "img", "img": "img", "StaticText": "txt",
        "text": "txt", "paragraph": "p", "generic": "group", "group": "group", "list": "list", "listitem": "listitem",
        "table": "table", "grid": "grid", "row": "row", "cell": "cell", "gridcell": "cell", "columnheader": "colheader",
        "rowheader": "rowheader", "dialog": "dialog", "alertdialog": "dialog", "alert": "alert", "tab": "tab",
        "tablist": "tabs", "tabpanel": "tabpanel", "slider": "slider", "spinbutton": "stepper", "scrollbar": "scrollbar",
        "toolbar": "toolbar", "tree": "tree", "treeitem": "treeitem", "main": "main", "navigation": "nav",
        "banner": "banner", "contentinfo": "footer", "region": "region", "form": "form", "article": "article",
        "complementary": "aside", "Iframe": "frame", "iframe": "frame", "figure": "figure", "separator": "separator",
        "progressbar": "progress", "status": "status", "log": "log", "blockquote": "quote", "code": "code",
        "emphasis": "txt", "strong": "txt", "time": "txt", "DescriptionList": "list", "term": "txt", "definition": "txt",
        "Section": "group", "section": "group", "Details": "group", "DisclosureTriangle": "disclosure",
        "summary": "disclosure", "Canvas": "canvas", "video": "video", "audio": "audio", "math": "math",
        "PopUpButton": "popup", "ListMarker": "txt", "LabelText": "txt", "label": "txt", "caption": "txt",
        "LineBreak": "br", "InlineTextBox": "inline", "ColorWell": "colorwell", "date": "datefield", "time_": "timefield",
        "textarea": "textarea", "Pre": "txt", "SvgRoot": "img", "graphics-symbol": "img", "note": "group",
        "application": "app", "document": "doc", "presentation": "group", "none": "group", "Ignored": "ignored",
        "Legend": "txt", "Ruby": "txt", "meter": "level", "menulistpopup": "menu", "MenuListPopup": "menu",
        "MenuListOption": "option", "Footer": "footer", "Header": "banner", "EmbeddedObject": "object",
        "PluginObject": "object", "Splitter": "splitter", "Abbr": "txt", "Marquee": "group", "Timer": "txt",
        "Tooltip": "tooltip", "Directory": "list", "Feed": "list", "Search": "search", "Suggestion": "txt",
        "Insertion": "txt", "Deletion": "txt", "Mark": "txt", "Subscript": "txt", "Superscript": "txt",
        "Comment": "txt", "Doc-*": "group", "Portal": "link", "ImageMap": "img", "DocAbstract": "txt",
    ]

    public static let containerRoles: Set<String> = [
        "app", "window", "sheet", "drawer", "dialog", "toolbar", "tabs", "group", "list", "outline", "table", "row",
        "column", "scroll", "web", "split", "layout", "grid", "browser", "tabpanel", "main", "nav", "banner",
        "footer", "region", "form", "article", "aside", "frame", "figure", "doc", "menubar", "menu", "tree", "matte",
        "popover", "canvas", "object",
    ]

    public static let interactiveRoles: Set<String> = [
        "btn", "link", "field", "textarea", "secure-field", "search", "checkbox", "radio", "popup", "combo", "menubtn",
        "menuitem", "menubaritem", "slider", "stepper", "tab", "disclosure", "colorwell", "datefield", "timefield",
        "option", "treeitem", "switch", "toggle", "listitem", "cell", "colheader", "rowheader", "scrollbar", "dockitem",
    ]

    public static func short(ax role: String, subrole: String?) -> String {
        if let s = subrole {
            switch s {
            case "AXTabButton": return "tab"
            case "AXSearchField": return "search"
            case "AXSecureTextField": return "secure-field"
            case "AXSwitch": return "switch"
            case "AXToggle": return "toggle"
            case "AXCloseButton": return "btn"
            case "AXDialog", "AXSystemDialog": return "dialog"
            case "AXFloatingWindow", "AXStandardWindow": break
            case "AXOutlineRow", "AXTableRow": return "row"
            case "AXSortButton": return "btn"
            case "AXDescriptionList": return "list"
            case "AXContentList": return "list"
            case "AXLandmarkMain": return "main"
            case "AXLandmarkNavigation": return "nav"
            case "AXLandmarkBanner": return "banner"
            case "AXLandmarkContentInfo": return "footer"
            case "AXLandmarkComplementary": return "aside"
            case "AXLandmarkRegion", "AXLandmarkSearch": return "region"
            case "AXApplicationDialog", "AXApplicationAlertDialog": return "dialog"
            case "AXDocumentArticle": return "article"
            case "AXTerm", "AXDefinition", "AXCodeStyleGroup", "AXDeleteStyleGroup", "AXInsertStyleGroup": return "txt"
            case "AXFieldset": return "group"
            case "AXMenuListPopup": return "menu"
            case "AXDetails": return "group"
            case "AXSummary": return "disclosure"
            case "AXSubscriptStyleGroup", "AXSuperscriptStyleGroup": return "txt"
            default: break
            }
        }
        return axRoleMap[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    public static func short(aria role: String) -> String {
        ariaRoleMap[role] ?? role.lowercased()
    }
}
