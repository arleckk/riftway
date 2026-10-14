import Foundation

/// Per-game knowledge as data (PRD-05): how to recognize a game, how well it
/// runs and what its bottle needs. Profiles are JSON files (schema 1) in
/// `profiles/`; every field is optional except `id`, `name`, `match` and
/// `status`. A profile changes the bottle (environment, DLL overrides,
/// registry, `dxmt.conf`), never the game's files.
public struct GameProfile: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1

    public var schema: Int
    public var id: String
    public var name: String
    /// Bumped on every change, so bottles that applied an older one apply it again.
    public var revision: Int
    public var match: Match
    public var status: CompatibilityStatus
    public var anticheat: AntiCheatInfo?
    /// End-to-end evidence behind `verified`.
    public var tested: Evidence?
    public var env: [String: String]
    /// Executable lists for the runtime's patches: `WINEMAC_MOUSELOOK`, `WINE_GAME_MODE`.
    public var game: [String: [String]]
    /// `{"dpi": 192, "programs": ["Launcher.exe"]}` for launchers drawn tiny on Retina.
    public var appDPI: AppDPI?
    /// `"wined3d"` for a game DXMT does not run; DXMT when absent.
    public var d3d11: Direct3D11?
    public var dllOverrides: [String: String]
    public var programDllOverrides: [String: [String: String]]
    /// Arguments appended to a program's command line wherever it starts
    /// (`{"steamwebhelper.exe": "--in-process-gpu"}`); the runtime adds them
    /// from `RIFTWAY_APPEND_ARGS` (runtime patch wine-append-args).
    public var programArgs: [String: String]
    /// `"HKCU/Software/Studio/Game": {"Value": "1"}`; `dword:00000001` for a DWORD.
    public var registry: [String: [String: String]]
    public var dxmtConf: [String: String]
    /// A scheme the Play button starts by default with the last link the
    /// game's site sent (`dsropen`), instead of opening the site.
    public var playLink: String?
    /// A controller setup (PRD-08) for bottles that have none of their own.
    public var controller: ControllerLayout?
    public var notes: String?

    public struct Match: Codable, Sendable, Equatable {
        /// `ProductName` of the installer or of the game (`VS_VERSIONINFO`, MSI, uninstall entry).
        public var product: [String] = []
        public var company: [String] = []
        /// Authenticode signer of the installer, for installers without version strings.
        public var signer: [String] = []
        /// Installer file names; `*` matches anything (`SuperRumble Installer*.exe`).
        public var installer: [String] = []
        /// File names of the game's programs.
        public var executables: [String] = []
        /// SHA-256 of the installer or of a program, lowercase hex.
        public var sha256: [String] = []

        public init(product: [String] = [], company: [String] = [], signer: [String] = [], installer: [String] = [],
                    executables: [String] = [], sha256: [String] = []) {
            self.product = product
            self.company = company
            self.signer = signer
            self.installer = installer
            self.executables = executables
            self.sha256 = sha256
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            product = try c.decodeIfPresent([String].self, forKey: .product) ?? []
            company = try c.decodeIfPresent([String].self, forKey: .company) ?? []
            signer = try c.decodeIfPresent([String].self, forKey: .signer) ?? []
            installer = try c.decodeIfPresent([String].self, forKey: .installer) ?? []
            executables = try c.decodeIfPresent([String].self, forKey: .executables) ?? []
            sha256 = try c.decodeIfPresent([String].self, forKey: .sha256) ?? []
        }

        var isEmpty: Bool {
            product.isEmpty && signer.isEmpty && installer.isEmpty && executables.isEmpty && sha256.isEmpty
        }
    }

    public struct AntiCheatInfo: Codable, Sendable, Equatable {
        public var vendor: AntiCheatVendor
        /// Whether it needs a kernel driver to let the game in.
        public var kernel: Bool
    }

    public struct Evidence: Codable, Sendable, Equatable {
        public var date: String
        public var macos: String
        public var hardware: String
        public var runtime: String
        public var online: Bool?
    }

    public struct AppDPI: Codable, Sendable, Equatable {
        public var dpi: Int
        public var programs: [String]
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, name, revision, match, status, anticheat, tested, env, game, notes, registry
        case appDPI = "app_dpi", dllOverrides = "dll_overrides", programDllOverrides = "program_dll_overrides"
        case programArgs = "program_args"
        case dxmtConf = "dxmt_conf", playLink = "play_link", controller, d3d11
    }

    public init(id: String, name: String, match: Match, status: CompatibilityStatus) {
        schema = Self.schemaVersion
        self.id = id
        self.name = name
        revision = 1
        self.match = match
        self.status = status
        env = [:]
        game = [:]
        dllOverrides = [:]
        programDllOverrides = [:]
        programArgs = [:]
        registry = [:]
        dxmtConf = [:]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        match = try c.decode(Match.self, forKey: .match)
        status = try c.decode(CompatibilityStatus.self, forKey: .status)
        anticheat = try c.decodeIfPresent(AntiCheatInfo.self, forKey: .anticheat)
        tested = try c.decodeIfPresent(Evidence.self, forKey: .tested)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        game = try c.decodeIfPresent([String: [String]].self, forKey: .game) ?? [:]
        appDPI = try c.decodeIfPresent(AppDPI.self, forKey: .appDPI)
        d3d11 = try c.decodeIfPresent(Direct3D11.self, forKey: .d3d11)
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
        programDllOverrides = try c.decodeIfPresent([String: [String: String]].self, forKey: .programDllOverrides) ?? [:]
        programArgs = try c.decodeIfPresent([String: String].self, forKey: .programArgs) ?? [:]
        registry = try c.decodeIfPresent([String: [String: String]].self, forKey: .registry) ?? [:]
        dxmtConf = try c.decodeIfPresent([String: String].self, forKey: .dxmtConf) ?? [:]
        playLink = try c.decodeIfPresent(String.self, forKey: .playLink)
        controller = try c.decodeIfPresent(ControllerLayout.self, forKey: .controller)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    // MARK: Validation

    public enum Invalid: Error, CustomStringConvertible, Equatable {
        case notJSON
        case unknownKey(String)
        case schema(Int)
        case badID(String)
        case emptyMatch
        case dllMode(String)
        case registryKey(String)
        case registryValue(String)
        case unknownPatch(String)
        case verifiedWithoutEvidence
        case playLink(String)
        case controllerLayer(program: String, layer: String)
        case programArgs(String)

        public var description: String {
            switch self {
            case .notJSON: "not a JSON object"
            case .unknownKey(let key): "unknown key \(key)"
            case .schema(let version): "schema \(version) is not supported (this Riftway reads \(GameProfile.schemaVersion))"
            case .badID(let id): "id \(id) must be lowercase letters, digits and dashes"
            case .emptyMatch: "match needs a product, signer, installer, executable or hash"
            case .dllMode(let entry): "DLL override \(entry): the mode must be n, b, n,b, b,n or empty"
            case .registryKey(let key): "registry key \(key): only HKCU and HKLM/Software outside Riftway's own key"
            case .registryValue(let value): "registry value \(value): a string, or dword: and eight hex digits"
            case .unknownPatch(let name): "game.\(name) is not one of the runtime's patches"
            case .verifiedWithoutEvidence: "verified needs tested (date, macOS, hardware, runtime)"
            case .playLink(let scheme): "play_link \(scheme) is not a URL scheme"
            case .controllerLayer(let program, let layer): "controller: \(program) holds layer \(layer), which it does not have"
            case .programArgs(let entry): "program_args \(entry): a program file name (.exe) and arguments, without ; or ="
            }
        }
    }

    static let knownKeys: Set<String> = ["schema", "id", "name", "revision", "match", "status", "anticheat", "tested", "env",
                                         "game", "app_dpi", "dll_overrides", "program_dll_overrides", "program_args", "registry",
                                         "dxmt_conf", "play_link", "controller", "d3d11", "notes"]
    static let knownMatchKeys: Set<String> = ["product", "company", "signer", "installer", "executables", "sha256"]
    public static let patches = ["WINEMAC_MOUSELOOK", "WINE_GAME_MODE"]
    /// The runtime's variable for `program_args` (wine-append-args.patch).
    public static let appendArgsVariable = "RIFTWAY_APPEND_ARGS"

    /// Decodes and checks a profile file: what the profile CI runs on every
    /// file in `profiles/`. Unknown keys are errors, so a typo never silently
    /// drops a setting.
    public static func load(_ data: Data) throws -> GameProfile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid.notJSON }
        if let key = object.keys.sorted().first(where: { !knownKeys.contains($0) }) { throw Invalid.unknownKey(key) }
        if let match = object["match"] as? [String: Any], let key = match.keys.sorted().first(where: { !knownMatchKeys.contains($0) }) {
            throw Invalid.unknownKey("match." + key)
        }
        let profile = try JSONDecoder().decode(GameProfile.self, from: data)
        try profile.validate()
        return profile
    }

    public func validate() throws {
        guard schema == Self.schemaVersion else { throw Invalid.schema(schema) }
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            throw Invalid.badID(id)
        }
        guard !match.isEmpty else { throw Invalid.emptyMatch }
        let modes: Set<String> = ["n", "b", "n,b", "b,n", ""]
        for (dll, mode) in dllOverrides where !modes.contains(mode) { throw Invalid.dllMode("\(dll)=\(mode)") }
        for (program, overrides) in programDllOverrides {
            for (dll, mode) in overrides where !modes.contains(mode) { throw Invalid.dllMode("\(program): \(dll)=\(mode)") }
        }
        for (key, values) in registry {
            guard Self.registryPath(key) != nil else { throw Invalid.registryKey(key) }
            for (name, value) in values where Self.registryData(value) == nil { throw Invalid.registryValue("\(name)=\(value)") }
        }
        for name in game.keys where !Self.patches.contains(name) { throw Invalid.unknownPatch(name) }
        for (program, arguments) in programArgs {
            // The runtime reads "program=arguments;program=arguments".
            guard program.lowercased().hasSuffix(".exe"), !program.contains("\\"), !program.contains("/"),
                  !(program + arguments).contains(";"), !program.contains("="),
                  !arguments.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Invalid.programArgs("\(program)=\(arguments)")
            }
        }
        if status == .verified, tested == nil { throw Invalid.verifiedWithoutEvidence }
        if let playLink, !URLProtocolRegistration.isValidScheme(playLink) { throw Invalid.playLink(playLink) }
        for (program, controls) in controller?.programs ?? [:] {
            guard let set = controls.actionSet else { continue }
            for output in ([set.base] + Array(set.layers.values)).flatMap(\.bindings.values) {
                if case .holdLayer(let layer) = output, set.layers[layer] == nil { throw Invalid.controllerLayer(program: program, layer: layer) }
            }
        }
    }

    // MARK: What the profile does to a bottle

    /// The profile's part of a bottle's options; the player's own options go on top.
    public var options: GameOptions {
        var options = GameOptions()
        options.mouselook = game["WINEMAC_MOUSELOOK"] ?? []
        options.gameMode = game["WINE_GAME_MODE"] ?? []
        options.appDPI = appDPI.map { ($0.dpi, $0.programs) }
        options.direct3D11 = d3d11
        options.dllOverrides = dllOverrides
        options.programDllOverrides = programDllOverrides
        options.environment = env
        if !programArgs.isEmpty {
            options.environment[Self.appendArgsVariable] = programArgs.keys.sorted()
                .map { "\($0)=\(programArgs[$0]!)" }.joined(separator: ";")
        }
        return options
    }

    /// `HKCU/Software/Studio/Game` → `HKEY_CURRENT_USER\Software\Studio\Game`.
    /// Only the current user's keys and machine-wide software settings: never
    /// services or drivers, and never Riftway's own key, which tells the game
    /// honestly what it runs on (PRD-07 R3.1).
    public static func registryPath(_ key: String) -> String? {
        let parts = key.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard parts.count >= 2, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("]") }) else { return nil }
        let root: String
        switch parts[0].uppercased() {
        case "HKCU", "HKEY_CURRENT_USER": root = "HKEY_CURRENT_USER"
        case "HKLM", "HKEY_LOCAL_MACHINE": root = "HKEY_LOCAL_MACHINE"
        default: return nil
        }
        let rest = parts.dropFirst().map { $0.lowercased() }
        if root == "HKEY_LOCAL_MACHINE", rest.first != "software" { return nil }
        if rest.first == "software", rest.dropFirst().first == "riftway"
            || (rest.dropFirst().first == "wow6432node" && rest.dropFirst(2).first == "riftway") { return nil }
        return ([root] + parts.dropFirst()).joined(separator: "\\")
    }

    /// The value as a `.reg` file writes it: `"text"` or `dword:0000002a`.
    public static func registryData(_ value: String) -> String? {
        if value.lowercased().hasPrefix("dword:") {
            let hex = value.dropFirst(6)
            guard hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "dword:" + hex.lowercased()
        }
        return "\"" + BottleSetup.regEscape(value) + "\""
    }

    /// `dxmt.conf`, the same `key = value` lines as `dxvk.conf`.
    public var dxmtConfText: String {
        var text = "# Written by Riftway from the profile \(id) (revision \(revision)).\n"
        for (key, value) in dxmtConf.sorted(by: { $0.key < $1.key }) { text += "\(key) = \(value)\n" }
        return text
    }
}

/// How well a game runs (PRD-05).
public enum CompatibilityStatus: String, Codable, Sendable, CaseIterable {
    /// Tested end to end, with evidence, on the hardware and macOS stated.
    case verified
    /// Runs with known problems.
    case playable
    /// No data.
    case untested
    /// Something outside Riftway prevents it (a kernel anti-cheat, DRM, the game's terms).
    case blocked
}
