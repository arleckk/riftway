import Foundation

/// A controller's buttons by position, Xbox names: `a` is the bottom face
/// button (✕ on PlayStation), `b` the right one (○), `x` the left (□), `y` the
/// top (△). A stick used as a d-pad gives four directions.
public enum ControllerButton: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case a, b, x, y
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    /// Start, Menu, Options (PlayStation).
    case start
    /// Back, View, Share (PlayStation).
    case select
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
    /// A click on the left or right half of a PlayStation touchpad.
    case touchpadLeft, touchpadRight
}

/// What a button does in keyboard and desktop modes: one physical press is
/// one key or mouse button, held while the button is (PRD-08: no macros, no
/// turbo, no timed sequences).
public enum ControllerOutput: Codable, Equatable, Sendable, CustomStringConvertible {
    /// A key by its name (`KeyCodes`): `F`, `ESCAPE`, `SPACE`, `1`, `BACK_TICK`…
    case key(String)
    case mouse(MouseButton)
    /// While held, the named layer's bindings take over.
    case holdLayer(String)
    /// Explicitly nothing (a layer that silences a button).
    case none

    public enum MouseButton: String, Codable, Sendable { case left, right, middle }

    /// `key:F`, `mouse:left`, `layer:L1`, `none`.
    public var description: String {
        switch self {
        case .key(let name): "key:" + name
        case .mouse(let button): "mouse:" + button.rawValue
        case .holdLayer(let layer): "layer:" + layer
        case .none: "none"
        }
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("key", 2) where KeyCodes.code(for: parts[1]) != nil: self = .key(parts[1].uppercased())
        case ("mouse", 2): guard let button = MouseButton(rawValue: parts[1]) else { return nil }; self = .mouse(button)
        case ("layer", 2) where !parts[1].isEmpty: self = .holdLayer(parts[1])
        case ("none", 1): self = .none
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let output = ControllerOutput(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a controller output: \(text)"))
        }
        self = output
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What moves the mouse pointer.
public enum PointerSource: String, Codable, CaseIterable, Sendable {
    case leftStick, rightStick, touchpad
}

/// Bindings that are active together. A layer lists only what it changes.
public struct InputLayer: Codable, Equatable, Sendable {
    public var bindings: [ControllerButton: ControllerOutput]

    public init(bindings: [ControllerButton: ControllerOutput] = [:]) { self.bindings = bindings }
}

/// A full mapping for one program: base bindings, layers held from it, and
/// the pointer sources.
public struct ActionSet: Codable, Equatable, Sendable {
    public var base: InputLayer
    public var layers: [String: InputLayer]
    public var pointer: [PointerSource]
    /// Where it came from, for the player (`Steam Input: controller_ps4.vdf`).
    public var source: String?

    public init(base: InputLayer = InputLayer(), layers: [String: InputLayer] = [:], pointer: [PointerSource] = [], source: String? = nil) {
        self.base = base
        self.layers = layers
        self.pointer = pointer
        self.source = source
    }

    /// The binding for `button` with `layers` held, topmost first; a layer
    /// that does not mention the button leaves the one below.
    public func output(for button: ControllerButton, layers held: [String]) -> ControllerOutput {
        for name in held.reversed() {
            if let output = layers[name]?.bindings[button] { return output }
        }
        return base.bindings[button] ?? .none
    }

    /// Launchers and menus: the right stick and the touchpad move the pointer,
    /// the bottom face button clicks.
    public static let desktop = ActionSet(base: InputLayer(bindings: [
        .a: .mouse(.left), .b: .mouse(.right), .x: .key("ESCAPE"), .y: .key("TAB"),
        .r2: .mouse(.left), .l2: .mouse(.right),
        .dpadUp: .key("UP_ARROW"), .dpadDown: .key("DOWN_ARROW"), .dpadLeft: .key("LEFT_ARROW"), .dpadRight: .key("RIGHT_ARROW"),
        .start: .key("RETURN"), .select: .key("ESCAPE"),
        .leftStickUp: .key("UP_ARROW"), .leftStickDown: .key("DOWN_ARROW"),
        .leftStickLeft: .key("LEFT_ARROW"), .leftStickRight: .key("RIGHT_ARROW"),
    ]), pointer: [.rightStick, .touchpad], source: "Riftway: escritorio")
}

public enum InputMode: String, Codable, CaseIterable, Sendable {
    /// The controller reaches the program as an Xbox controller (XInput).
    case native
    /// Pointer and clicks (`ActionSet.desktop`).
    case desktop
    /// The program's `actionSet`.
    case keyboard
    /// Nothing.
    case off
}

public struct ProgramControls: Codable, Equatable, Sendable {
    public var mode: InputMode
    public var actionSet: ActionSet?

    public init(mode: InputMode, actionSet: ActionSet? = nil) {
        self.mode = mode
        self.actionSet = actionSet
    }

    /// The bindings that apply, or nil when Riftway sends nothing.
    public var effectiveActionSet: ActionSet? {
        switch mode {
        case .native, .off: nil
        case .desktop: actionSet ?? .desktop
        case .keyboard: actionSet
        }
    }
}

/// A game's controller setup (PRD-08), per program: the launcher and the game
/// are different programs with different modes. Stored as the bottle's
/// `controller.json`.
/// Starts Riftway Input for a bottle's session (PRD-08).
public enum InputHelper {
    public static let bundleName = "Riftway Input.app"

    /// `Riftway Input.app` beside a helper of Riftway.app (`Contents/Helpers`).
    public static func bundle(nextTo helper: URL) -> URL? {
        let app = helper.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(bundleName)
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Opens it through LaunchServices (so it is its own app for the
    /// Accessibility permission) when the game's layout needs it. It keeps one
    /// instance per bottle and quits when the session ends.
    @discardableResult
    public static func startIfNeeded(app: URL?, bottleRoot: URL) -> Bool {
        guard let app, ControllerLayout.read(bottle: bottleRoot)?.needsHelper == true else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", app.path, "--args", "--bottle", bottleRoot.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }
}

public struct ControllerLayout: Codable, Equatable, Sendable {
    public static let fileName = "controller.json"
    public var schema = 1
    /// By program file name (`Client-Win64-Shipping.exe`), any case.
    public var programs: [String: ProgramControls]
    /// For programs not listed.
    public var otherPrograms: InputMode

    public init(programs: [String: ProgramControls] = [:], otherPrograms: InputMode = .native) {
        self.programs = programs
        self.otherPrograms = otherPrograms
    }

    public func controls(for program: String) -> ProgramControls {
        programs.first { $0.key.caseInsensitiveCompare(program) == .orderedSame }?.value ?? ProgramControls(mode: otherPrograms)
    }

    /// Some program needs Riftway to send keys or mouse events.
    public var needsHelper: Bool {
        programs.values.contains { $0.effectiveActionSet != nil } || otherPrograms == .desktop
    }

    public static func read(bottle root: URL) -> ControllerLayout? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(ControllerLayout.self, from: data)
    }

    public func write(bottle root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension ControllerLayout {
    /// Programs of a game the player may want to set up: the game's programs,
    /// those its URL protocols start (a launcher), and the `.exe` files in
    /// their folders (the game a launcher starts), helpers left out.
    public static func programSuggestions(for entry: LibraryEntry, limit: Int = 40) -> [String] {
        let bottle = Bottle(name: entry.id, prefix: entry.root.appendingPathComponent("prefix").path, backend: .wine(wine: "/usr/bin/false"))
        var paths = ([entry.game.primary] + entry.game.programs).compactMap { $0?.windowsPath }
        if let uninstall = entry.game.uninstall?.uninstallString, let program = WindowsCommandLine.split(uninstall).first { paths.append(program) }
        if let system = try? WineRegistry(contentsOf: entry.root.appendingPathComponent("prefix/system.reg")) {
            let user = try? WineRegistry(contentsOf: entry.root.appendingPathComponent("prefix/user.reg"))
            for registration in URLProtocolRegistration.discover(system: system, user: user) where entry.game.schemes.contains(registration.scheme) {
                if let exe = registration.windowsExecutable { paths.append(exe) }
            }
        }
        var names: [String] = []
        func add(_ name: String) {
            let lower = name.lowercased()
            guard lower.hasSuffix(".exe"), !names.contains(where: { $0.lowercased() == lower }),
                  !InstallDiscovery.isUninstaller(name), !InstallDiscovery.isHelper(name),
                  !["crashreportclient.exe", "unrealcefsubprocess.exe", "xm.exe"].contains(lower) else { return }
            names.append(name)
        }
        var folders: [URL] = []
        for path in paths {
            add(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path)
            if let file = bottle.unixURL(forWindowsPath: path) { folders.append(file.deletingLastPathComponent()) }
        }
        let fm = FileManager.default
        for folder in Set(folders) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            var seen = 0
            while let file = walker.nextObject() as? URL, seen < 5000, names.count < limit {
                seen += 1
                if walker.level > 5 { walker.skipDescendants(); continue }
                if file.pathExtension.lowercased() == "exe" { add(file.lastPathComponent) }
            }
        }
        return names
    }
}

extension ActionSet {
    public enum LayerError: Error, Equatable, CustomStringConvertible {
        case empty, exists(String), missing(String)
        public var description: String {
            switch self {
            case .empty: "A layer needs a name"
            case .exists(let name): "There is already a layer \(name)"
            case .missing(let name): "There is no layer \(name)"
            }
        }
    }

    /// Renames a layer and every button that holds it.
    public mutating func renameLayer(_ old: String, to new: String) throws {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw LayerError.empty }
        guard name != old else { return }
        guard layers[name] == nil else { throw LayerError.exists(name) }
        guard let layer = layers.removeValue(forKey: old) else { throw LayerError.missing(old) }
        layers[name] = layer
        func rename(_ bindings: inout [ControllerButton: ControllerOutput]) {
            for (button, output) in bindings where output == .holdLayer(old) { bindings[button] = .holdLayer(name) }
        }
        rename(&base.bindings)
        for key in layers.keys { rename(&layers[key]!.bindings) }
    }
}

/// A game's controller setup as a file to share (`Exportar…`): every program's
/// mode and bindings, nothing about the player or the bottle.
public struct ControllerExport: Codable, Equatable, Sendable {
    public static let format = "riftway.controller"
    public var format: String
    public var schema: Int
    /// The game it was made for, as a hint.
    public var game: String?
    public var layout: ControllerLayout

    public init(game: String?, layout: ControllerLayout) {
        format = Self.format
        schema = 1
        self.game = game
        self.layout = layout
    }

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case notAControllerFile, schema(Int)
        public var description: String {
            switch self {
            case .notAControllerFile: "not a Riftway controller file"
            case .schema(let version): "controller file schema \(version) is newer than this Riftway"
            }
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func read(_ data: Data) throws -> ControllerExport {
        guard let file = try? JSONDecoder().decode(ControllerExport.self, from: data), file.format == format else {
            throw Invalid.notAControllerFile
        }
        guard file.schema == 1 else { throw Invalid.schema(file.schema) }
        return file
    }
}

extension ControllerLayout {
    /// Takes in an imported setup: its programs replace the ones with the same
    /// name, the rest stay.
    public mutating func merge(_ other: ControllerLayout) {
        for (name, controls) in other.programs {
            if let existing = programs.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { programs[existing] = nil }
            programs[name] = controls
        }
        otherPrograms = other.otherPrograms
    }
}
