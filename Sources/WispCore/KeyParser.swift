import Foundation

public enum KeyModifier: String, CaseIterable { case command, option, control, shift, fn }

public enum KeyToken: Equatable {
    case named(String)
    case character(Character)
}

public struct KeyChord: Equatable {
    public var modifiers: Set<KeyModifier>
    public var key: KeyToken?   // nil = modifiers only

    public init(modifiers: Set<KeyModifier>, key: KeyToken?) {
        self.modifiers = modifiers
        self.key = key
    }
}

/// Parses xdotool-style key strings: `Return`, `super+c`, `ctrl+shift+t`, `KP_0`, `cmd+l,Return` (comma = sequence).
public enum KeyParser {
    static let modifierAliases: [String: KeyModifier] = [
        "cmd": .command, "command": .command, "super": .command, "super_l": .command, "super_r": .command, "meta": .command,
        "meta_l": .command, "win": .command, "windows": .command, "gui": .command,
        "alt": .option, "alt_l": .option, "alt_r": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control, "control_l": .control, "control_r": .control, "ctl": .control,
        "shift": .shift, "shift_l": .shift, "shift_r": .shift,
        "fn": .fn, "function": .fn,
    ]

    static let namedAliases: [String: String] = [
        "return": "return", "enter": "return", "ret": "return", "kp_enter": "kpenter", "tab": "tab", "space": "space",
        "backspace": "backspace", "bs": "backspace", "delete": "delete", "del": "delete", "forwarddelete": "delete",
        "escape": "escape", "esc": "escape", "up": "up", "down": "down", "left": "left", "right": "right",
        "uparrow": "up", "downarrow": "down", "leftarrow": "left", "rightarrow": "right",
        "home": "home", "end": "end", "page_up": "pageup", "pageup": "pageup", "prior": "pageup",
        "page_down": "pagedown", "pagedown": "pagedown", "next": "pagedown", "caps_lock": "capslock", "capslock": "capslock",
        "help": "help", "insert": "help", "menu": "menu", "clear": "clear", "kp_delete": "delete", "kp_decimal": "kpdecimal",
        "kp_add": "kpplus", "kp_plus": "kpplus", "kp_subtract": "kpminus", "kp_minus": "kpminus", "kp_multiply": "kpmultiply",
        "kp_divide": "kpdivide", "kp_equal": "kpequals", "kp_separator": "kpdecimal", "kp_space": "space", "kp_tab": "tab",
        "kp_up": "up", "kp_down": "down", "kp_left": "left", "kp_right": "right", "kp_home": "home", "kp_end": "end",
        "kp_page_up": "pageup", "kp_page_down": "pagedown", "kp_prior": "pageup", "kp_next": "pagedown", "kp_begin": "clear",
        "kp_insert": "help", "volumeup": "volumeup", "volumedown": "volumedown", "mute": "mute",
        "eject": "eject", "print": "f13", "f13": "f13", "f14": "f14", "f15": "f15", "scroll_lock": "f14", "pause": "f15",
        "plus": "+", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "apostrophe": "'", "quotedbl": "\"", "grave": "`", "asciitilde": "~", "bracketleft": "[",
        "bracketright": "]", "braceleft": "{", "braceright": "}", "less": "<", "greater": ">", "question": "?",
        "exclam": "!", "at": "@", "numbersign": "#", "dollar": "$", "percent": "%", "asciicircum": "^", "ampersand": "&",
        "asterisk": "*", "parenleft": "(", "parenright": ")", "underscore": "_", "bar": "|", "colon": ":",
    ]

    public static func parse(_ input: String) throws -> [KeyChord] {
        let sequences = input.split(separator: ",", omittingEmptySubsequences: true).map { String($0) }
        var chords: [KeyChord] = []
        for seq in sequences {
            let tokens = seq.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            var mods = Set<KeyModifier>()
            var key: KeyToken? = nil
            var pendingPlus = false
            for (i, raw) in tokens.enumerated() {
                if raw.isEmpty {
                    // "cmd++" means the plus key; consecutive separators encode '+'.
                    if i == tokens.count - 1 || pendingPlus { key = .character("+") }
                    pendingPlus = true
                    continue
                }
                let lower = raw.lowercased()
                if let m = modifierAliases[lower], i < tokens.count - 1 || key != nil || tokens.count == 1 && false {
                    mods.insert(m)
                    continue
                }
                if let m = modifierAliases[lower], i == tokens.count - 1 {
                    // modifier as the last token: modifiers-only chord (e.g. "shift" or "cmd+shift")
                    mods.insert(m)
                    continue
                }
                if i < tokens.count - 1 {
                    throw WispError(.invalidParams, "unknown modifier `\(raw)` in key `\(input)`")
                }
                if let named = namedAliases[lower] {
                    if named.count == 1, let c = named.first { key = .character(c) } else { key = .named(named) }
                } else if lower.count >= 2, lower.first == "f", let n = Int(lower.dropFirst()), (1...20).contains(n) {
                    key = .named("f\(n)")
                } else if lower.hasPrefix("kp_"), lower.count == 4, let d = lower.last, d.isNumber {
                    key = .named("kp\(d)")
                } else if raw.count == 1, let c = raw.first {
                    if c.isUppercase, c.isLetter { mods.insert(.shift); key = .character(Character(c.lowercased())) }
                    else { key = .character(c) }
                } else if lower.hasPrefix("u+"), let scalar = UInt32(lower.dropFirst(2), radix: 16), let u = Unicode.Scalar(scalar) {
                    key = .character(Character(u))
                } else {
                    throw WispError(.invalidParams, "unknown key `\(raw)` in `\(input)`")
                }
            }
            if key == nil, mods.isEmpty { throw WispError(.invalidParams, "empty key chord in `\(input)`") }
            chords.append(KeyChord(modifiers: mods, key: key))
        }
        if chords.isEmpty { throw WispError(.invalidParams, "empty key string") }
        return chords
    }
}
