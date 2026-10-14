import Foundation

/// Reads a Steam Input configuration (`controller_*.vdf`, exported or from
/// Steam's `userdata`) into an `ActionSet`: the first action set's base
/// bindings and its hold layers. Riftway sends keys and mouse buttons; what
/// only Steam can do (XInput output, gyro, system actions) is reported, not
/// imitated. Identifiers in the file (`creator`, the Steam account) are not kept.
public enum SteamInputImport {
    public struct Result: Sendable, Equatable {
        public var actionSet: ActionSet
        /// Bindings Riftway cannot reproduce, as `source.input: binding`.
        public var skipped: [String]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAControllerConfig
        public var description: String { "not a Steam Input controller configuration (controller_mappings)" }
    }

    /// Controls of each Steam "source", by Steam input name.
    static func controls(source: String, mode: String) -> [String: ControllerButton] {
        switch source {
        case "button_diamond": ["button_a": .a, "button_b": .b, "button_x": .x, "button_y": .y]
        case "dpad": ["dpad_north": .dpadUp, "dpad_south": .dpadDown, "dpad_west": .dpadLeft, "dpad_east": .dpadRight]
        case "joystick":
            ["dpad_north": .leftStickUp, "dpad_south": .leftStickDown, "dpad_west": .leftStickLeft, "dpad_east": .leftStickRight, "click": .l3]
        case "right_joystick":
            ["dpad_north": .rightStickUp, "dpad_south": .rightStickDown, "dpad_west": .rightStickLeft, "dpad_east": .rightStickRight, "click": .r3]
        case "left_trigger": ["click": .l2, "edge": .l2]
        case "right_trigger": ["click": .r2, "edge": .r2]
        case "switch": ["button_escape": .select, "button_menu": .start, "left_bumper": .l1, "right_bumper": .r1]
        case "left_trackpad": ["click": .touchpadLeft]
        case "right_trackpad": ["click": .touchpadRight]
        default: [:]
        }
    }

    public static func parse(_ text: String, name: String? = nil) throws -> Result {
        let root = try VDF.parse(text)
        guard let mappings = root["controller_mappings"] else { throw Failure.notAControllerConfig }

        var groups: [String: VDF] = [:]
        for group in mappings.all("group") { if let id = group["id"]?.string { groups[id] = group } }

        // Presets in order: the first is the action set, the rest its layers;
        // `hold_layer N` counts presets from 1.
        let presets = mappings.all("preset")
        var layerTitles: [String: String] = [:]
        for (key, layer) in mappings["action_layers"]?.entries ?? [] { layerTitles[key] = layer["title"]?.string ?? key }
        func layerName(_ index: Int) -> String? {
            guard index >= 1, index - 1 < presets.count, let preset = presets[index - 1]["name"]?.string else { return nil }
            return layerTitles[preset] ?? preset
        }

        var skipped: [String] = []
        func bindings(of preset: VDF, isLayer: Bool) -> (InputLayer, [PointerSource]) {
            var layer = InputLayer()
            var pointer: [PointerSource] = []
            for (groupID, value) in preset["group_source_bindings"]?.entries ?? [] {
                let parts = (value.string ?? "").split(separator: " ").map(String.init)
                guard parts.count >= 2, parts[1] == "active", let group = groups[groupID] else { continue }
                let source = parts[0], mode = group["mode"]?.string ?? ""
                let controls = controls(source: source, mode: mode)
                // A layer's group replaces that source entirely.
                if isLayer { for button in Set(controls.values) { layer.bindings[button] = ControllerOutput.none } }
                switch (source, mode) {
                case ("joystick", "joystick_mouse"), ("joystick", "mouse_joystick"): pointer.append(.leftStick)
                case ("right_joystick", "joystick_mouse"), ("right_joystick", "mouse_joystick"): pointer.append(.rightStick)
                case ("left_trackpad", "absolute_mouse"), ("right_trackpad", "absolute_mouse"),
                     ("left_trackpad", "mouse_region"), ("right_trackpad", "mouse_region"):
                    if !pointer.contains(.touchpad) { pointer.append(.touchpad) }
                default: break
                }
                for (input, activators) in group["inputs"]?.entries ?? [] {
                    guard let button = controls[input] else {
                        if !(activators["activators"]?.entries.isEmpty ?? true) { skipped.append("\(source).\(input)") }
                        continue
                    }
                    // A stick in joystick mode only keeps its click.
                    if (mode == "joystick_move" || mode == "joystick_mouse"), input != "click" { continue }
                    for (activator, settings) in activators["activators"]?.entries ?? [] {
                        guard ["full_press", "soft_press"].contains(activator.lowercased()) else {
                            skipped.append("\(source).\(input) (\(activator))")
                            continue
                        }
                        for (_, binding) in settings["bindings"]?.entries ?? [] {
                            guard let text = binding.string else { continue }
                            if let output = output(text, layerName: layerName) {
                                if layer.bindings[button] == nil || layer.bindings[button] == ControllerOutput.none {
                                    layer.bindings[button] = output
                                }
                            } else {
                                skipped.append("\(source).\(input): \(text.trimmingCharacters(in: CharacterSet(charactersIn: ", ")))")
                            }
                        }
                    }
                }
            }
            return (layer, pointer)
        }

        guard let first = presets.first else { throw Failure.notAControllerConfig }
        let (base, pointer) = bindings(of: first, isLayer: false)
        var layers: [String: InputLayer] = [:]
        for index in presets.indices.dropFirst() {
            guard let name = layerName(index + 1) else { continue }
            layers[name] = bindings(of: presets[index], isLayer: true).0
        }
        let source = "Steam Input" + (name.map { ": " + $0 } ?? "")
        return Result(actionSet: ActionSet(base: base, layers: layers, pointer: pointer, source: source), skipped: skipped)
    }

    /// `key_press F, , ` → key F; `mouse_button LEFT` → left click;
    /// `controller_action hold_layer 2 1 1` → hold that layer. Nil for
    /// what Riftway does not reproduce.
    static func output(_ binding: String, layerName: (Int) -> String?) -> ControllerOutput? {
        let command = binding.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let words = command.split(separator: " ").map(String.init)
        guard let verb = words.first else { return nil }
        switch verb {
        case "key_press":
            guard words.count >= 2, KeyCodes.code(for: words[1]) != nil else { return nil }
            return .key(words[1].uppercased())
        case "mouse_button":
            guard words.count >= 2 else { return nil }
            switch words[1].uppercased() {
            case "LEFT": return .mouse(.left)
            case "RIGHT": return .mouse(.right)
            case "MIDDLE": return .mouse(.middle)
            default: return nil
            }
        case "controller_action":
            if words.count >= 3, words[1] == "hold_layer", let index = Int(words[2]), let name = layerName(index) { return .holdLayer(name) }
            return nil
        default:
            return nil
        }
    }
}
