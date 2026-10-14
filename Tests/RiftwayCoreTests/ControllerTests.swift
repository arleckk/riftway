import Foundation
import Testing
@testable import RiftwayCore

/// The shape of a Steam Input export (a DSR layout), trimmed: two hold layers
/// on the bumpers, triggers as mouse buttons, the left stick as WASD.
let steamConfig = #"""
"controller_mappings"
{
	"version"		"3"
	"creator"		"7656119800000000"
	"actions" { "Default" { "title" "Default" } }
	"action_layers"
	{
		"Preset_1000001" { "title" "Hold L1" "set_layer" "1" }
	}
	"group" { "id" "0" "mode" "four_buttons" "inputs" {
		"button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press F, , " } } } }
		"button_b" { "activators" { "Full_Press" { "bindings" { "binding" "key_press ESCAPE, , " } } } }
	} }
	"group" { "id" "4" "mode" "trigger" "inputs" {
		"click" { "activators" { "Full_Press" { "bindings" { "binding" "mouse_button RIGHT, , " } } } }
	} }
	"group" { "id" "16" "mode" "dpad" "inputs" {
		"dpad_north" { "activators" { "Full_Press" { "bindings" { "binding" "key_press W, , " } } } }
		"click" { "activators" { "Full_Press" { "bindings" { "binding" "key_press BACK_TICK, , " } } } }
	} }
	"group" { "id" "7" "mode" "switches" "inputs" {
		"left_bumper" { "activators" { "Full_Press" { "bindings" { "binding" "controller_action hold_layer 2 1 1, , " } } } }
		"button_capture" { "activators" { "release" { "bindings" { "binding" "controller_action system_key_1, , " } } } }
	} }
	"group" { "id" "8" "mode" "joystick_move" "inputs" {
		"click" { "activators" { "Full_Press" { "bindings" { "binding" "xinput_button JOYSTICK_RIGHT, , " } } } }
	} }
	"group" { "id" "17" "mode" "absolute_mouse" "inputs" {
		"click" { "activators" { "Soft_Press" { "bindings" { "binding" "key_press SPACE, , " } } } }
	} }
	"group" { "id" "18" "mode" "four_buttons" "inputs" {
		"button_a" { "activators" { "Full_Press" { "bindings" { "binding" "key_press 2, , " } } } }
	} }
	"group" { "id" "19" "mode" "trigger" "inputs" { } }
	// A comment.
	"preset" { "id" "0" "name" "Default" "group_source_bindings" {
		"0" "button_diamond active"
		"4" "left_trigger active"
		"16" "joystick active"
		"7" "switch active"
		"8" "right_joystick active"
		"17" "right_trackpad active"
		"3" "joystick inactive"
	} }
	"preset" { "id" "1" "name" "Preset_1000001" "group_source_bindings" {
		"18" "button_diamond active"
		"19" "left_trigger active"
	} }
}
"""#

@Suite struct ControllerTests {
    @Test func vdfKeepsRepeatedKeysInOrder() throws {
        let vdf = try VDF.parse(#""a" { "k" "1" "k" "2" "q" "say \"hi\"" } // end"#)
        #expect(vdf["a"]?.all("k").compactMap(\.string) == ["1", "2"])
        #expect(vdf["a"]?["q"]?.string == #"say "hi""#)
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""a" { "k" "1""#) }
    }

    @Test func importsSteamInputLayouts() throws {
        let result = try SteamInputImport.parse(steamConfig, name: "controller_ps4.vdf")
        let set = result.actionSet
        #expect(set.base.bindings[.a] == .key("F"))
        #expect(set.base.bindings[.b] == .key("ESCAPE"))
        #expect(set.base.bindings[.l2] == .mouse(.right))
        #expect(set.base.bindings[.leftStickUp] == .key("W"))
        #expect(set.base.bindings[.l3] == .key("BACK_TICK"))
        #expect(set.base.bindings[.l1] == .holdLayer("Hold L1"))
        #expect(set.base.bindings[.touchpadRight] == .key("SPACE"))
        #expect(set.base.bindings[.r3] == nil)
        #expect(set.pointer == [.touchpad])
        #expect(set.source == "Steam Input: controller_ps4.vdf")
        // The layer replaces the face buttons and silences the left trigger.
        #expect(set.output(for: .a, layers: ["Hold L1"]) == .key("2"))
        #expect(set.output(for: .b, layers: ["Hold L1"]) == ControllerOutput.none)
        #expect(set.output(for: .l2, layers: ["Hold L1"]) == ControllerOutput.none)
        #expect(set.output(for: .leftStickUp, layers: ["Hold L1"]) == .key("W"))
        #expect(result.skipped.contains("right_joystick.click: xinput_button JOYSTICK_RIGHT"))
        #expect(result.skipped.contains { $0.hasPrefix("switch.button_capture") })
        // Nothing of the Steam account survives.
        let json = String(decoding: try JSONEncoder().encode(set), as: UTF8.self)
        #expect(!json.contains("7656119"))
        #expect(throws: SteamInputImport.Failure.notAControllerConfig) { try SteamInputImport.parse(#""other" { }"#) }
    }

    @Test func layoutsArePerProgram() throws {
        var layout = ControllerLayout()
        layout.programs["SuperRumble Launcher.exe"] = ProgramControls(mode: .desktop)
        layout.programs["Client-Win64-Shipping.exe"] = ProgramControls(mode: .keyboard,
                                                                       actionSet: ActionSet(base: InputLayer(bindings: [.a: .key("F")])))
        #expect(layout.controls(for: "superrumble launcher.exe").effectiveActionSet == .desktop)
        #expect(layout.controls(for: "Client-Win64-Shipping.exe").effectiveActionSet?.base.bindings[.a] == .key("F"))
        #expect(layout.controls(for: "Other.exe").effectiveActionSet == nil)
        #expect(layout.needsHelper)
        let data = try JSONEncoder().encode(layout)
        #expect(String(decoding: data, as: UTF8.self).contains(#""a":"key:F""#))
        #expect(try JSONDecoder().decode(ControllerLayout.self, from: data) == layout)
        #expect(ControllerOutput("key:NOPE") == nil)
        #expect(KeyCodes.code(for: "back_tick") == 0x32)
    }

    @Test func controllerFamilies() {
        #expect(ControllerFamily(productCategory: "DualShock 4") == .playStation4)
        #expect(ControllerFamily(productCategory: "DualSense") == .playStation5)
        #expect(ControllerFamily(productCategory: "Xbox One") == .xbox)
        #expect(ControllerFamily(productCategory: "Switch Pro Controller") == .switchPro)
        #expect(ControllerFamily(productCategory: "Nintendo Switch Joy-Con (L/R)") == .joyCon)
        #expect(ControllerFamily(vendorID: 0x054c, productID: 0x09cc) == .playStation4)
        #expect(ControllerFamily(vendorID: 0x054c, productID: 0x0ce6) == .playStation5)
        #expect(ControllerFamily(vendorID: 0x045e, productID: 0x0b13) == .xbox)
        #expect(ControllerFamily(vendorID: 0x0079, productID: 0x0006) == .generic)
        #expect(ControllerFamily.playStation4.label(.a) == "✕")
        #expect(ControllerFamily.xbox.label(.l2) == "LT")
        #expect(ControllerFamily.switchPro.label(.a) == "B")  // bottom button
        #expect(!ControllerFamily.xbox.buttons.contains(.touchpadLeft))
        #expect(KeyCodes.name(for: 0x31) == "SPACE")
        #expect(KeyCodes.name(for: 0x38) == "LEFT_SHIFT")
        #expect(KeyCodes.displayName("BACK_TICK") == "`")
        #expect(KeyCodes.displayName("KEYPAD_DASH") == "Num -")
    }

    @Test func renameLayersAndShareLayouts() throws {
        var set = try SteamInputImport.parse(steamConfig).actionSet
        try set.renameLayer("Hold L1", to: "L1")
        #expect(set.base.bindings[.l1] == .holdLayer("L1"))
        #expect(set.output(for: .a, layers: ["L1"]) == .key("2"))
        #expect(throws: ActionSet.LayerError.empty) { try set.renameLayer("L1", to: " ") }
        #expect(throws: ActionSet.LayerError.missing("Nope")) { try set.renameLayer("Nope", to: "X") }
        set.layers["R1"] = InputLayer()
        #expect(throws: ActionSet.LayerError.exists("R1")) { try set.renameLayer("L1", to: "R1") }

        var shared = ControllerLayout(otherPrograms: .off)
        shared.programs["client-win64-shipping.exe"] = ProgramControls(mode: .keyboard, actionSet: set)
        let data = try ControllerExport(game: "Digimon Super Rumble", layout: shared).data()
        let file = try ControllerExport.read(data)
        #expect(file.layout == shared && file.game == "Digimon Super Rumble")
        #expect(throws: ControllerExport.Invalid.notAControllerFile) { try ControllerExport.read(Data("{}".utf8)) }

        var mine = ControllerLayout()
        mine.programs["Client-Win64-Shipping.exe"] = ProgramControls(mode: .native)
        mine.programs["SuperRumble Launcher.exe"] = ProgramControls(mode: .desktop)
        mine.merge(file.layout)
        #expect(mine.programs.count == 2)
        #expect(mine.controls(for: "Client-Win64-Shipping.exe").mode == .keyboard)
        #expect(mine.controls(for: "SuperRumble Launcher.exe").mode == .desktop)
        #expect(mine.otherPrograms == .off)
    }

    @Test func holdLayersLikeAPlayerPressesThem() {
        let silent: [ControllerButton: ControllerOutput] = [.l1: .none, .r1: .none]
        var set = ActionSet(base: InputLayer(bindings: [.l1: .holdLayer("L1"), .r1: .holdLayer("R1"), .dpadLeft: .key("Q")]))
        set.layers["L1"] = InputLayer(bindings: silent.merging([.dpadLeft: .key("A")]) { $1 })
        set.layers["R1"] = InputLayer(bindings: silent.merging([.dpadLeft: .key("Z")]) { $1 })
        func down(_ key: String) -> ButtonMapper.Event { .init(output: .key(key), down: true) }
        func up(_ key: String) -> ButtonMapper.Event { .init(output: .key(key), down: false) }

        // The d-pad and L1 in the same poll: the layer's key.
        var mapper = ButtonMapper(set: set)
        #expect(mapper.update([.dpadLeft, .l1]) == [down("A")])
        #expect(mapper.update([.l1]) == [up("A")])
        #expect(mapper.update([]) == [])
        #expect(mapper.layers.isEmpty)

        // R1 pressed before letting go of L1 (L1's layer silences it): R1's
        // layer once L1 is up.
        #expect(mapper.update([.l1]) == [])
        #expect(mapper.update([.l1, .r1]) == [])
        #expect(mapper.layers == ["L1"])
        #expect(mapper.update([.r1]) == [])
        #expect(mapper.layers == ["R1"])
        #expect(mapper.update([.r1, .dpadLeft]) == [down("Z")])
        // A key keeps going up as the one that went down.
        #expect(mapper.update([.dpadLeft]) == [])
        #expect(mapper.update([]) == [up("Z")])
        #expect(mapper.update([.dpadLeft]) == [down("Q")])
        #expect(mapper.releaseAll() == [up("Q")])
    }
}
