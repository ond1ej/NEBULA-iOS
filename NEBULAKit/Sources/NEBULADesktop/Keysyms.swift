import Foundation

/// X11 keysyms (the RFB KeyEvent key values) and the platform key tables.
///
/// Printable keys are sent as the character the user's keyboard layout produced (Xvnc maps keysyms to its own
/// keymap and adds modifiers as needed), so any layout — Czech included — types correctly. Non-printable keys
/// come from the physical-key tables.
public enum Keysym {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let pause: UInt32 = 0xFF13
    public static let scrollLock: UInt32 = 0xFF14
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let print: UInt32 = 0xFF61
    public static let insert: UInt32 = 0xFF63
    public static let menu: UInt32 = 0xFF67
    public static let numLock: UInt32 = 0xFF7F
    public static let keypadEnter: UInt32 = 0xFF8D
    public static let f1: UInt32 = 0xFFBE
    public static let shiftL: UInt32 = 0xFFE1
    public static let shiftR: UInt32 = 0xFFE2
    public static let controlL: UInt32 = 0xFFE3
    public static let controlR: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let altL: UInt32 = 0xFFE9
    public static let altR: UInt32 = 0xFFEA
    public static let superL: UInt32 = 0xFFEB
    public static let superR: UInt32 = 0xFFEC
    public static let delete: UInt32 = 0xFFFF
    public static let space: UInt32 = 0x20

    /// F1…F35.
    public static func function(_ n: Int) -> UInt32 {
        f1 + UInt32(min(max(n, 1), 35) - 1)
    }

    public static let modifiers: Set<UInt32> = [shiftL, shiftR, controlL, controlR, altL, altR, superL, superR,
                                                0xFFE7, 0xFFE8] // + Meta_L/R

    /// The keysym typing `scalar` produces: Latin-1 is identical to its code point, other Unicode is
    /// 0x01000000 + code point, control characters map to their keys (or nil).
    public static func forScalar(_ scalar: Unicode.Scalar) -> UInt32? {
        let v = scalar.value
        switch v {
        case 0x08: return backSpace
        case 0x09: return tab
        case 0x0A, 0x0D: return returnKey
        case 0x1B: return escape
        case 0x7F: return delete
        case 0x20...0x7E, 0xA0...0xFF: return v
        case 0x00...0x1F, 0x80...0x9F: return nil
        case 0xF700...0xF8FF: return nil // Apple's private-use function-key characters (handled by key tables)
        case 0xFE00...0xFE0F: return nil // variation selectors
        default: return 0x0100_0000 + v
        }
    }

    /// Keysyms for typing `text` (NFC-normalised, one per scalar; unmappable scalars are skipped).
    public static func forText(_ text: String) -> [UInt32] {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.compactMap(forScalar)
    }

    // MARK: - macOS virtual key codes (kVK_*)

    /// Non-printable Mac keys and modifiers.
    public static func macSpecial(keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 0x24: returnKey
        case 0x30: tab
        case 0x31: space
        case 0x33: backSpace
        case 0x35: escape
        case 0x37: superL      // Command
        case 0x36: superR      // right Command
        case 0x38: shiftL
        case 0x3C: shiftR
        case 0x39: capsLock
        case 0x3A: altL        // Option
        case 0x3D: altR
        case 0x3B: controlL
        case 0x3E: controlR
        case 0x4C: keypadEnter
        case 0x72: insert      // Help (Insert on PC keyboards)
        case 0x73: home
        case 0x74: pageUp
        case 0x75: delete      // forward delete
        case 0x77: end
        case 0x79: pageDown
        case 0x7B: left
        case 0x7C: right
        case 0x7D: down
        case 0x7E: up
        case 0x7A: function(1)
        case 0x78: function(2)
        case 0x63: function(3)
        case 0x76: function(4)
        case 0x60: function(5)
        case 0x61: function(6)
        case 0x62: function(7)
        case 0x64: function(8)
        case 0x65: function(9)
        case 0x6D: function(10)
        case 0x67: function(11)
        case 0x6F: function(12)
        case 0x69: function(13)
        case 0x6B: function(14)
        case 0x71: function(15)
        case 0x6A: function(16)
        case 0x40: function(17)
        case 0x4F: function(18)
        case 0x50: function(19)
        case 0x5A: function(20)
        default: nil
        }
    }

    /// US-ANSI printable keys by Mac key code (fallback when the layout yields no character, e.g. Ctrl+dead key).
    public static func macUSLayout(keyCode: UInt16) -> UInt32? {
        let table: [UInt16: Character] = [
            0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x", 0x08: "c",
            0x09: "v", 0x0B: "b", 0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y", 0x11: "t", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-",
            0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "o", 0x20: "u", 0x21: "[", 0x22: "i", 0x23: "p", 0x25: "l",
            0x26: "j", 0x27: "'", 0x28: "k", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "n", 0x2E: "m",
            0x2F: ".", 0x32: "`",
        ]
        return table[keyCode].flatMap { $0.unicodeScalars.first }.flatMap(forScalar)
    }

    /// The device-dependent modifier flag bit (NX_DEVICE*KEYMASK) of a Mac modifier key, to tell left from right
    /// in flagsChanged.
    public static func macModifierDeviceMask(keyCode: UInt16) -> UInt? {
        switch keyCode {
        case 0x3B: 0x0000_0001 // left control
        case 0x38: 0x0000_0002 // left shift
        case 0x3C: 0x0000_0004 // right shift
        case 0x37: 0x0000_0008 // left command
        case 0x36: 0x0000_0010 // right command
        case 0x3A: 0x0000_0020 // left option
        case 0x3D: 0x0000_0040 // right option
        case 0x3E: 0x0000_2000 // right control
        default: nil
        }
    }

    // MARK: - USB HID usages (UIKeyboardHIDUsage)

    /// Non-printable keys and modifiers by HID usage (iOS / iPadOS hardware keyboards).
    public static func hidSpecial(usage: Int) -> UInt32? {
        switch usage {
        case 0x28: returnKey
        case 0x29: escape
        case 0x2A: backSpace
        case 0x2B: tab
        case 0x2C: space
        case 0x39: capsLock
        case 0x3A...0x45: function(usage - 0x3A + 1)        // F1–F12
        case 0x68...0x73: function(usage - 0x68 + 13)       // F13–F24
        case 0x46: print
        case 0x47: scrollLock
        case 0x48: pause
        case 0x49: insert
        case 0x4A: home
        case 0x4B: pageUp
        case 0x4C: delete
        case 0x4D: end
        case 0x4E: pageDown
        case 0x4F: right
        case 0x50: left
        case 0x51: down
        case 0x52: up
        case 0x53: numLock
        case 0x58: keypadEnter
        case 0x65: menu
        case 0xE0: controlL
        case 0xE1: shiftL
        case 0xE2: altL
        case 0xE3: superL
        case 0xE4: controlR
        case 0xE5: shiftR
        case 0xE6: altR
        case 0xE7: superR
        default: nil
        }
    }

    /// US-layout printable keys by HID usage (fallback).
    public static func hidUSLayout(usage: Int) -> UInt32? {
        switch usage {
        case 0x04...0x1D: return UInt32(0x61 + usage - 0x04)             // a–z
        case 0x1E...0x26: return UInt32(0x31 + usage - 0x1E)             // 1–9
        case 0x27: return 0x30                                            // 0
        default:
            let table: [Int: UInt32] = [0x2D: 0x2D, 0x2E: 0x3D, 0x2F: 0x5B, 0x30: 0x5D, 0x31: 0x5C, 0x33: 0x3B,
                                        0x34: 0x27, 0x35: 0x60, 0x36: 0x2C, 0x37: 0x2E, 0x38: 0x2F]
            return table[usage]
        }
    }
}

/// Modifier state of a hardware key event, platform-neutral.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// How a hardware key press maps to the remote desktop.
public enum KeyResolution: Equatable, Sendable {
    /// Press/release this keysym with the physical key.
    case keysym(UInt32)
    /// An Option-composed character (e.g. "@" on a Czech Mac layout): sent as a tap with Alt temporarily released,
    /// so the remote receives the character, not Alt+character.
    case composed(UInt32)
    /// Not mappable (dead key, unknown key): let the platform handle it.
    case unmapped
}

/// Maps hardware key events (Mac key codes, iOS HID usages) to keysyms. Pure and platform-neutral (unit-tested).
public enum HardwareKeyResolver {
    public enum Table: Sendable { case mac, hid }

    public static func resolve(code: Int, table: Table, characters: String, charactersIgnoringModifiers: String,
                               modifiers: KeyModifiers) -> KeyResolution {
        let special: UInt32?
        switch table {
        case .mac: special = UInt16(exactly: code).flatMap { Keysym.macSpecial(keyCode: $0) }
        case .hid: special = Keysym.hidSpecial(usage: code)
        }
        if let special { return .keysym(special) }

        // With Control/Command the layout's control character is useless: use the unmodified character so the
        // remote sees e.g. Ctrl + "c" (layout-correct on QWERTZ too).
        let shortcut = modifiers.contains(.control) || modifiers.contains(.command)
        let text = shortcut ? charactersIgnoringModifiers : characters
        if let scalar = text.precomposedStringWithCanonicalMapping.unicodeScalars.first,
           let keysym = Keysym.forScalar(scalar) {
            if !shortcut, modifiers.contains(.option), characters != charactersIgnoringModifiers {
                return .composed(keysym)
            }
            return .keysym(keysym)
        }
        if shortcut {
            let fallback: UInt32?
            switch table {
            case .mac: fallback = UInt16(exactly: code).flatMap { Keysym.macUSLayout(keyCode: $0) }
            case .hid: fallback = Keysym.hidUSLayout(usage: code)
            }
            if let fallback { return .keysym(fallback) }
        }
        return .unmapped
    }
}

/// Tracks which physical keys are down and which keysym each sent, so a key-up always releases exactly what its
/// key-down pressed (modifiers may change in between), and everything can be released when focus is lost.
public struct PressedKeyTracker: Sendable {
    private var pressed: [Int: UInt32] = [:]
    /// Sentinel for keys whose down already sent a complete tap (composed characters, Command shortcuts).
    private static let tapped: UInt32 = 0

    public init() {}

    public var isEmpty: Bool { pressed.isEmpty }

    /// Keysyms currently held on the remote.
    public var heldKeysyms: [UInt32] { pressed.values.filter { $0 != Self.tapped } }

    /// Handles a key-down. Returns false when unmapped (caller passes the event on).
    public mutating func keyDown(code: Int, resolution: KeyResolution, tapOnly: Bool = false,
                                 send: (UInt32, Bool) -> Void) -> Bool {
        switch resolution {
        case .unmapped:
            return false
        case .keysym(let k):
            if tapOnly {
                send(k, true)
                send(k, false)
                pressed[code] = Self.tapped
            } else {
                // A repeated down without up is autorepeat; the server repeats it.
                pressed[code] = k
                send(k, true)
            }
            return true
        case .composed(let k):
            let alts = heldKeysyms.filter { $0 == Keysym.altL || $0 == Keysym.altR }
            for a in alts { send(a, false) }
            send(k, true)
            send(k, false)
            for a in alts { send(a, true) }
            pressed[code] = Self.tapped
            return true
        }
    }

    /// Handles a key-up. Returns false when the key was not tracked.
    public mutating func keyUp(code: Int, send: (UInt32, Bool) -> Void) -> Bool {
        guard let k = pressed.removeValue(forKey: code) else { return false }
        if k != Self.tapped { send(k, false) }
        return true
    }

    /// Records a key that is down without going through `keyDown` (e.g. a modifier from flagsChanged).
    public mutating func press(code: Int, keysym: UInt32, send: (UInt32, Bool) -> Void) {
        pressed[code] = keysym
        send(keysym, true)
    }

    public func isPressed(code: Int) -> Bool { pressed[code] != nil }

    /// Releases every held key.
    public mutating func releaseAll(send: (UInt32, Bool) -> Void) {
        for (_, k) in pressed.sorted(by: { $0.key < $1.key }) where k != Self.tapped { send(k, false) }
        pressed.removeAll()
    }
}
