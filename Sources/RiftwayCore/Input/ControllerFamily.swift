import Foundation

/// The kind of controller, for its button names and for what Riftway can do
/// with it (PRD-08).
public enum ControllerFamily: String, Codable, CaseIterable, Sendable {
    case playStation4, playStation5, xbox, switchPro, joyCon, generic

    /// From what GameController reports (`productCategory`, "DualShock 4",
    /// "DualSense", "Xbox One"…) or, for HID devices, the USB vendor and product.
    public init(productCategory: String? = nil, vendorID: Int? = nil, productID: Int? = nil) {
        let category = (productCategory ?? "").lowercased()
        if category.contains("dualsense") { self = .playStation5; return }
        if category.contains("dualshock") { self = .playStation4; return }
        if category.contains("xbox") { self = .xbox; return }
        if category.contains("joy-con") || category.contains("joycon") { self = .joyCon; return }
        if category.contains("switch") || category.contains("nintendo") { self = .switchPro; return }
        switch (vendorID, productID) {
        case (0x054c?, let product?) where [0x0ce6, 0x0df2].contains(product): self = .playStation5
        case (0x054c?, let product?) where [0x05c4, 0x09cc, 0x0ba0].contains(product): self = .playStation4
        case (0x045e?, _): self = .xbox
        case (0x057e?, let product?) where [0x2006, 0x2007].contains(product): self = .joyCon
        case (0x057e?, _): self = .switchPro
        default: self = .generic
        }
    }

    public var displayName: String {
        switch self {
        case .playStation4: "DualShock 4"
        case .playStation5: "DualSense"
        case .xbox: "Control de Xbox"
        case .switchPro: "Nintendo Switch Pro"
        case .joyCon: "Joy-Con"
        case .generic: "Control genérico"
        }
    }

    public var hasTouchpad: Bool { self == .playStation4 || self == .playStation5 }

    /// The button's name on this controller. Buttons are by position (Xbox
    /// names): on Nintendo controllers the bottom button is B and the right
    /// one A.
    public func label(_ button: ControllerButton) -> String {
        let ps = self == .playStation4 || self == .playStation5
        let nintendo = self == .switchPro || self == .joyCon
        switch button {
        case .a: return ps ? "✕" : nintendo ? "B" : "A"
        case .b: return ps ? "○" : nintendo ? "A" : "B"
        case .x: return ps ? "□" : nintendo ? "Y" : "X"
        case .y: return ps ? "△" : nintendo ? "X" : "Y"
        case .dpadUp: return "Cruceta ↑"
        case .dpadDown: return "Cruceta ↓"
        case .dpadLeft: return "Cruceta ←"
        case .dpadRight: return "Cruceta →"
        case .l1: return ps ? "L1" : nintendo ? "L" : "LB"
        case .r1: return ps ? "R1" : nintendo ? "R" : "RB"
        case .l2: return ps ? "L2" : nintendo ? "ZL" : "LT"
        case .r2: return ps ? "R2" : nintendo ? "ZR" : "RT"
        case .l3: return ps ? "L3" : "Clic stick izq."
        case .r3: return ps ? "R3" : "Clic stick der."
        case .start: return self == .playStation4 ? "Options" : self == .playStation5 ? "Options" : nintendo ? "+" : "Menú"
        case .select: return self == .playStation4 ? "Share" : self == .playStation5 ? "Create" : nintendo ? "−" : "Vista"
        case .leftStickUp: return "Stick izq. ↑"
        case .leftStickDown: return "Stick izq. ↓"
        case .leftStickLeft: return "Stick izq. ←"
        case .leftStickRight: return "Stick izq. →"
        case .rightStickUp: return "Stick der. ↑"
        case .rightStickDown: return "Stick der. ↓"
        case .rightStickLeft: return "Stick der. ←"
        case .rightStickRight: return "Stick der. →"
        case .touchpadLeft: return "Touchpad izq."
        case .touchpadRight: return "Touchpad der."
        }
    }

    /// Buttons this controller has, for the editor.
    public var buttons: [ControllerButton] {
        ControllerButton.allCases.filter { hasTouchpad || ($0 != .touchpadLeft && $0 != .touchpadRight) }
    }
}

extension KeyCodes {
    /// The canonical name of a Mac key code (`0x31` → `SPACE`), for a key the
    /// player presses to assign it.
    public static func name(for code: UInt16) -> String? {
        let aliases: Set<String> = ["ENTER", "ESC", "MINUS", "SHIFT", "CONTROL", "CTRL", "ALT", "GRAVE", "UP", "DOWN", "LEFT", "RIGHT"]
        return table.filter { $0.value == code && !aliases.contains($0.key) }.map(\.key).sorted().first
    }

    /// How a key name reads in the app.
    public static func displayName(_ name: String) -> String {
        switch name.uppercased() {
        case "SPACE": "Espacio"
        case "ESCAPE": "Esc"
        case "RETURN": "Enter"
        case "TAB": "Tab"
        case "BACKSPACE": "Borrar"
        case "BACK_TICK": "`"
        case "DASH": "-"
        case "EQUALS": "="
        case "LEFT_BRACKET": "["
        case "RIGHT_BRACKET": "]"
        case "BACKSLASH": "\\"
        case "SEMICOLON": ";"
        case "SINGLE_QUOTE": "'"
        case "COMMA": ","
        case "PERIOD": "."
        case "FORWARD_SLASH": "/"
        case "LEFT_SHIFT": "Shift izq."
        case "RIGHT_SHIFT": "Shift der."
        case "LEFT_CONTROL": "Ctrl izq."
        case "RIGHT_CONTROL": "Ctrl der."
        case "LEFT_ALT": "Alt izq."
        case "RIGHT_ALT": "Alt der."
        case "UP_ARROW": "↑"
        case "DOWN_ARROW": "↓"
        case "LEFT_ARROW": "←"
        case "RIGHT_ARROW": "→"
        case "PAGE_UP": "Re Pág"
        case "PAGE_DOWN": "Av Pág"
        case "CAPSLOCK": "Bloq Mayús"
        case let other where other.hasPrefix("KEYPAD_"): "Num " + displayName(String(other.dropFirst(7)))
        case let other: other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
