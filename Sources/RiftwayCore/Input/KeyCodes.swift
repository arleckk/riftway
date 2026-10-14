import Foundation

/// Key names (Steam Input's, which are positional) and the Mac virtual key
/// codes of the same physical keys on an ANSI keyboard. Wine turns them into
/// the Windows scan codes a physical keyboard would send.
public enum KeyCodes {
    static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09,
            "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11, "O": 0x1F, "U": 0x20, "I": 0x22,
            "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28, "N": 0x2D, "M": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
            "EQUALS": 0x18, "DASH": 0x1B, "LEFT_BRACKET": 0x21, "RIGHT_BRACKET": 0x1E, "BACKSLASH": 0x2A, "SEMICOLON": 0x29,
            "SINGLE_QUOTE": 0x27, "COMMA": 0x2B, "PERIOD": 0x2F, "FORWARD_SLASH": 0x2C, "BACK_TICK": 0x32,
            "RETURN": 0x24, "TAB": 0x30, "SPACE": 0x31, "BACKSPACE": 0x33, "ESCAPE": 0x35, "CAPSLOCK": 0x39,
            "LEFT_SHIFT": 0x38, "RIGHT_SHIFT": 0x3C, "LEFT_CONTROL": 0x3B, "RIGHT_CONTROL": 0x3E, "LEFT_ALT": 0x3A, "RIGHT_ALT": 0x3D,
            "INSERT": 0x72, "DELETE": 0x75, "HOME": 0x73, "END": 0x77, "PAGE_UP": 0x74, "PAGE_DOWN": 0x79,
            "LEFT_ARROW": 0x7B, "RIGHT_ARROW": 0x7C, "DOWN_ARROW": 0x7D, "UP_ARROW": 0x7E,
            "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64, "F9": 0x65,
            "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
            "KEYPAD_0": 0x52, "KEYPAD_1": 0x53, "KEYPAD_2": 0x54, "KEYPAD_3": 0x55, "KEYPAD_4": 0x56, "KEYPAD_5": 0x57,
            "KEYPAD_6": 0x58, "KEYPAD_7": 0x59, "KEYPAD_8": 0x5B, "KEYPAD_9": 0x5C, "KEYPAD_PERIOD": 0x41, "KEYPAD_ENTER": 0x4C,
            "KEYPAD_PLUS": 0x45, "KEYPAD_DASH": 0x4E, "KEYPAD_MULTIPLY": 0x43, "KEYPAD_FORWARD_SLASH": 0x4B,
        ]
        // Common aliases.
        for (alias, name) in [("ENTER", "RETURN"), ("ESC", "ESCAPE"), ("MINUS", "DASH"), ("SHIFT", "LEFT_SHIFT"),
                              ("CONTROL", "LEFT_CONTROL"), ("CTRL", "LEFT_CONTROL"), ("ALT", "LEFT_ALT"), ("GRAVE", "BACK_TICK"),
                              ("UP", "UP_ARROW"), ("DOWN", "DOWN_ARROW"), ("LEFT", "LEFT_ARROW"), ("RIGHT", "RIGHT_ARROW")] {
            t[alias] = t[name]
        }
        return t
    }()

    public static func code(for name: String) -> UInt16? { table[name.uppercased()] }

    /// Modifier keys travel as flags on every other key event, too.
    public static func isModifier(_ name: String) -> Bool {
        ["LEFT_SHIFT", "RIGHT_SHIFT", "SHIFT", "LEFT_CONTROL", "RIGHT_CONTROL", "CONTROL", "CTRL", "LEFT_ALT", "RIGHT_ALT", "ALT"]
            .contains(name.uppercased())
    }
}
