import AppKit
import Carbon.HIToolbox
import CoreGraphics
import WispCore

/// Marks events we post so the interruption monitor can tell them from real user input.
enum WispEventTag {
    static let magic: Int64 = 0x5749_5350  // "WISP"
}

/// Cooperative cancellation for a running action (Esc, user intervention, `wisp cancel`).
final class CancelToken {
    private let lock = NSLock()
    private var reason: WispError?
    func cancel(_ error: WispError) { lock.lock(); if reason == nil { reason = error }; lock.unlock() }
    func reset() { lock.lock(); reason = nil; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return reason != nil }
    func check() throws { lock.lock(); let r = reason; lock.unlock(); if let r = r { throw r } }
}

enum Delivery {
    case pid(pid_t)
    case hid
}

/// Maps characters and named keys to virtual keycodes for the current keyboard layout.
final class KeyCodeMap {
    static let shared = KeyCodeMap()

    private var charMap: [Character: (CGKeyCode, CGEventFlags)] = [:]
    private var layoutId: String = ""

    static let named: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "kpenter": CGKeyCode(kVK_ANSI_KeypadEnter), "tab": CGKeyCode(kVK_Tab),
        "space": CGKeyCode(kVK_Space), "backspace": CGKeyCode(kVK_Delete), "delete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape), "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow), "home": CGKeyCode(kVK_Home),
        "end": CGKeyCode(kVK_End), "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "capslock": CGKeyCode(kVK_CapsLock), "help": CGKeyCode(kVK_Help), "clear": CGKeyCode(kVK_ANSI_KeypadClear),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3), "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5),
        "f6": CGKeyCode(kVK_F6), "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9), "f10": CGKeyCode(kVK_F10),
        "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12), "f13": CGKeyCode(kVK_F13), "f14": CGKeyCode(kVK_F14),
        "f15": CGKeyCode(kVK_F15), "f16": CGKeyCode(kVK_F16), "f17": CGKeyCode(kVK_F17), "f18": CGKeyCode(kVK_F18),
        "f19": CGKeyCode(kVK_F19), "f20": CGKeyCode(kVK_F20),
        "kp0": CGKeyCode(kVK_ANSI_Keypad0), "kp1": CGKeyCode(kVK_ANSI_Keypad1), "kp2": CGKeyCode(kVK_ANSI_Keypad2),
        "kp3": CGKeyCode(kVK_ANSI_Keypad3), "kp4": CGKeyCode(kVK_ANSI_Keypad4), "kp5": CGKeyCode(kVK_ANSI_Keypad5),
        "kp6": CGKeyCode(kVK_ANSI_Keypad6), "kp7": CGKeyCode(kVK_ANSI_Keypad7), "kp8": CGKeyCode(kVK_ANSI_Keypad8),
        "kp9": CGKeyCode(kVK_ANSI_Keypad9), "kpplus": CGKeyCode(kVK_ANSI_KeypadPlus), "kpminus": CGKeyCode(kVK_ANSI_KeypadMinus),
        "kpmultiply": CGKeyCode(kVK_ANSI_KeypadMultiply), "kpdivide": CGKeyCode(kVK_ANSI_KeypadDivide),
        "kpdecimal": CGKeyCode(kVK_ANSI_KeypadDecimal), "kpequals": CGKeyCode(kVK_ANSI_KeypadEquals),
        "volumeup": CGKeyCode(kVK_VolumeUp), "volumedown": CGKeyCode(kVK_VolumeDown), "mute": CGKeyCode(kVK_Mute),
        "eject": 0x92, "menu": 0x6E,
    ]

    static let modifierCodes: [KeyModifier: CGKeyCode] = [
        .command: CGKeyCode(kVK_Command), .shift: CGKeyCode(kVK_Shift), .option: CGKeyCode(kVK_Option),
        .control: CGKeyCode(kVK_Control), .fn: CGKeyCode(kVK_Function),
    ]

    init() { rebuild() }

    func rebuild() {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        let id = idPtr.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        if id == layoutId, !charMap.isEmpty { return }
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [Character: (CGKeyCode, CGEventFlags)] = [:]
        let combos: [(UInt32, CGEventFlags)] = [
            (0, []), (UInt32(shiftKey >> 8), .maskShift), (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for (mods, flags) in combos {
                for code in 0..<128 {
                    var deadKey: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                             OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey, 4, &length, &chars)
                    guard err == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let ch = Character(scalar)
                    if map[ch] == nil { map[ch] = (CGKeyCode(code), flags) }
                }
            }
        }
        charMap = map
        layoutId = id
    }

    func lookup(_ token: KeyToken) -> (CGKeyCode, CGEventFlags)? {
        switch token {
        case .named(let n): return KeyCodeMap.named[n].map { ($0, []) }
        case .character(let c):
            rebuild()
            if let m = charMap[c] { return m }
            if let m = charMap[Character(c.lowercased())] { return (m.0, m.1.union(.maskShift)) }
            return nil
        }
    }
}

enum EventSynth {
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .combinedSessionState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    static func flags(for mods: Set<KeyModifier>) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods.contains(.command) { f.insert(.maskCommand) }
        if mods.contains(.shift) { f.insert(.maskShift) }
        if mods.contains(.option) { f.insert(.maskAlternate) }
        if mods.contains(.control) { f.insert(.maskControl) }
        if mods.contains(.fn) { f.insert(.maskSecondaryFn) }
        return f
    }

    static func post(_ e: CGEvent, _ delivery: Delivery) {
        e.setIntegerValueField(.eventSourceUserData, value: WispEventTag.magic)
        switch delivery {
        case .pid(let p): e.postToPid(p)
        case .hid: e.post(tap: .cghidEventTap)
        }
    }

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: Mouse

    static func cgButton(_ b: MouseButton) -> CGMouseButton {
        switch b { case .left: return .left; case .right: return .right; case .middle: return .center }
    }

    static func mouseTypes(_ b: MouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch b {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    static func mouseEvent(_ type: CGEventType, at p: CGPoint, button: MouseButton = .left, clickState: Int = 1,
                           flags: CGEventFlags = [], windowID: CGWindowID?) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(button)) else { return nil }
        e.flags = flags
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .leftMouseDragged {
            e.setDoubleValueField(.mouseEventPressure, value: 1)
        }
        if let w = windowID, w != 0 {
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w))
            // Field 51 is the event record's window id; AppKit uses it for `NSEvent.windowNumber`, so the target
            // window (not whatever is under the real pointer) receives the event.
            e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(w))
        }
        return e
    }

    static func move(to p: CGPoint, delivery: Delivery, windowID: CGWindowID?) {
        if let e = mouseEvent(.mouseMoved, at: p, windowID: windowID) { post(e, delivery) }
    }

    static func click(at p: CGPoint, button: MouseButton, count: Int, flags: CGEventFlags = [], delivery: Delivery,
                      windowID: CGWindowID?, clickInterval: Double, cancel: CancelToken,
                      beforeDown: (() async -> Void)? = nil, afterUp: (() async -> Void)? = nil) async throws {
        let types = mouseTypes(button)
        move(to: p, delivery: delivery, windowID: windowID)
        await sleep(0.03)
        for i in 1...max(1, count) {
            try cancel.check()
            await beforeDown?()
            if let d = mouseEvent(types.down, at: p, button: button, clickState: i, flags: flags, windowID: windowID) { post(d, delivery) }
            await sleep(clickInterval)
            if let u = mouseEvent(types.up, at: p, button: button, clickState: i, flags: flags, windowID: windowID) { post(u, delivery) }
            await afterUp?()
            if i < count { await sleep(0.08) }
        }
    }

    static func mouseDown(at p: CGPoint, button: MouseButton, delivery: Delivery, windowID: CGWindowID?) {
        move(to: p, delivery: delivery, windowID: windowID)
        if let d = mouseEvent(mouseTypes(button).down, at: p, button: button, windowID: windowID) { post(d, delivery) }
    }

    static func mouseUp(at p: CGPoint, button: MouseButton, delivery: Delivery, windowID: CGWindowID?) {
        if let u = mouseEvent(mouseTypes(button).up, at: p, button: button, windowID: windowID) { post(u, delivery) }
    }

    static func drag(from a: CGPoint, to b: CGPoint, button: MouseButton = .left, delivery: Delivery, windowID: CGWindowID?,
                     steps: Int = 24, duration: Double = 0.24, cancel: CancelToken) async throws {
        let types = mouseTypes(button)
        move(to: a, delivery: delivery, windowID: windowID)
        await sleep(0.03)
        if let d = mouseEvent(types.down, at: a, button: button, windowID: windowID) { post(d, delivery) }
        await sleep(0.05)
        for i in 1...steps {
            try cancel.check()
            let t = Double(i) / Double(steps)
            let s = t * t * (3 - 2 * t)
            let p = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
            if let m = mouseEvent(types.drag, at: p, button: button, windowID: windowID) { post(m, delivery) }
            await sleep(duration / Double(steps))
        }
        await sleep(0.05)
        if let u = mouseEvent(types.up, at: b, button: button, windowID: windowID) { post(u, delivery) }
    }

    static func scroll(at p: CGPoint, dx: Int, dy: Int, delivery: Delivery, windowID: CGWindowID?, cancel: CancelToken) async throws {
        var rx = dx, ry = dy
        move(to: p, delivery: delivery, windowID: windowID)
        while rx != 0 || ry != 0 {
            try cancel.check()
            let sx = max(-120, min(120, rx)), sy = max(-120, min(120, ry))
            rx -= sx; ry -= sy
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(sy), wheel2: Int32(sx), wheel3: 0) else { break }
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let w = windowID, w != 0 {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w))
            }
            post(e, delivery)
            await sleep(0.016)
        }
    }

    // MARK: Keyboard

    static func keyEvent(code: CGKeyCode, down: Bool, flags: CGEventFlags, unicode: String? = nil) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        e.flags = flags
        if let u = unicode {
            var units = Array(u.utf16)
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        return e
    }

    static func pressChord(_ chord: KeyChord, delivery: Delivery, cancel: CancelToken, holdKey: Double = 0.02) async throws {
        try cancel.check()
        var flags = flags(for: chord.modifiers)
        var keyCode: CGKeyCode? = nil
        if let k = chord.key {
            guard let m = KeyCodeMap.shared.lookup(k) else {
                throw WispError(.invalidParams, "cannot map key \(k) to a keycode on the current keyboard layout")
            }
            keyCode = m.0
            flags.formUnion(m.1)
        }
        let order: [KeyModifier] = [.fn, .control, .option, .shift, .command]
        var held: [CGKeyCode] = []
        var running: CGEventFlags = []
        for m in order where chord.modifiers.contains(m) || (m == .shift && flags.contains(.maskShift)) || (m == .option && flags.contains(.maskAlternate)) {
            let code = KeyCodeMap.modifierCodes[m]!
            running.formUnion(EventSynth.flags(for: [m]))
            if let e = keyEvent(code: code, down: true, flags: running) { post(e, delivery) }
            held.append(code)
            await sleep(0.01)
        }
        if let code = keyCode {
            if let d = keyEvent(code: code, down: true, flags: flags) { post(d, delivery) }
            await sleep(holdKey)
            if let u = keyEvent(code: code, down: false, flags: flags) { post(u, delivery) }
        }
        for code in held.reversed() {
            await sleep(0.01)
            running = []
            if let e = keyEvent(code: code, down: false, flags: []) { post(e, delivery) }
        }
    }

    static func typeText(_ text: String, delivery: Delivery, cancel: CancelToken, perChar: Double = 0.008) async throws {
        for ch in text {
            try cancel.check()
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                try await pressChord(KeyChord(modifiers: [], key: .named("return")), delivery: delivery, cancel: cancel)
                continue
            }
            if ch == "\t" {
                try await pressChord(KeyChord(modifiers: [], key: .named("tab")), delivery: delivery, cancel: cancel)
                continue
            }
            let mapped = KeyCodeMap.shared.lookup(.character(ch))
            let code = mapped?.0 ?? 0
            let flags = mapped?.1 ?? []
            if let d = keyEvent(code: code, down: true, flags: flags, unicode: String(ch)) { post(d, delivery) }
            if let u = keyEvent(code: code, down: false, flags: flags, unicode: String(ch)) { post(u, delivery) }
            await sleep(perChar)
        }
    }

    // MARK: Clipboard

    static func paste(text: String, format: PasteFormat, delivery: Delivery, cancel: CancelToken) async throws {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        pb.clearContents()
        switch format {
        case .text:
            pb.setString(text, forType: .string)
        case .html:
            pb.setData(Data(text.utf8), forType: .html)
            pb.setString(stripTags(text), forType: .string)
        case .md:
            pb.setString(text, forType: .string)
            if let html = markdownToHTML(text) { pb.setData(Data(html.utf8), forType: .html) }
        }
        await sleep(0.05)
        try await pressChord(KeyChord(modifiers: [.command], key: .character("v")), delivery: delivery, cancel: cancel)
        await sleep(0.3)
        restorePasteboard(pb, saved)
    }

    static func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restorePasteboard(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(items)
    }

    static func stripTags(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let att = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
        return att.string
    }

    /// Minimal Markdown → HTML (headings, bold, italic, code, links, lists, paragraphs).
    static func markdownToHTML(_ md: String) -> String? {
        var out: [String] = []
        var inList = false
        func inline(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            t = t.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<i>$1</i>", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
            return t
        }
        for rawLine in md.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { out.append("<ul>"); inList = true }
                out.append("<li>" + inline(String(line.dropFirst(2))) + "</li>")
                continue
            }
            if inList { out.append("</ul>"); inList = false }
            if line.isEmpty { continue }
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                let level = line[m].filter { $0 == "#" }.count
                out.append("<h\(level)>" + inline(String(line[m.upperBound...])) + "</h\(level)>")
            } else {
                out.append("<p>" + inline(line) + "</p>")
            }
        }
        if inList { out.append("</ul>") }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    // MARK: Activation

    @MainActor
    /// Makes the target app believe it is active without raising its windows or stealing the user's focus, by
    /// posting an AppKit-defined application-activated event to its process. Apps that gate input on `NSApp.isActive`
    /// then accept our synthesized events while staying in the background. No effect on the real front app or cursor.
    static func syntheticActivate(pid: pid_t, windowID: CGWindowID?) {
        let windowNumber = windowID.map { Int($0) } ?? 0
        guard let ns = NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                                          context: nil, subtype: Int16(NSEvent.EventSubtype.applicationActivated.rawValue),
                                          data1: 0, data2: 0),
              let e = ns.cgEvent else { return }
        e.setIntegerValueField(.eventSourceUserData, value: WispEventTag.magic)
        e.postToPid(pid)
    }

    static func bringToFront(_ app: NSRunningApplication, window: AXEl?) async {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
        }
        if let w = window {
            w.perform(kAXRaiseAction)
            w.set(kAXMainAttribute, true)
        }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            await sleep(0.05)
        }
    }
}
