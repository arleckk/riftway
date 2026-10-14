import Foundation

/// An installed Riftway runtime: `Runtimes/<version>/` with `bin/wine`,
/// `bin/wineserver`, `lib/wine/…` and `share/wine/…`.
public struct WineRuntime: Sendable, Codable, Equatable {
    public var root: String

    public init(root: String) { self.root = root }

    public var wine: String { root + "/bin/wine" }
    public var wineserver: String { root + "/bin/wineserver" }
}

/// What runs a game's 64-bit Direct3D 10 and 11: DXMT (Metal), the runtime's
/// default, or Wine's own wined3d for a game DXMT does not run. 32-bit games and
/// Direct3D 9 and older always use wined3d.
public enum Direct3D11: String, Codable, CaseIterable, Sendable {
    case dxmt, wined3d
}

/// Per-game switches the runtime's patches read from the environment. Empty
/// lists leave a patch inert, which is the default for every game.
public struct GameOptions: Sendable, Codable, Equatable {
    /// Executables that get raw mouse input while they hide and confine the cursor.
    public var mouselook: [String] = []
    /// Executables started from the Game Mode app bundle.
    public var gameMode: [String] = []
    /// Direct3D 10/11 through wined3d instead of DXMT; nil is the default (DXMT).
    public var direct3D11: Direct3D11?
    /// Executables that see their own DPI (launchers drawn tiny on Retina).
    public var appDPI: (dpi: Int, programs: [String])?
    /// `dll` → `n`, `b`, `n,b`, `b,n` or "" (disabled), on top of the runtime's defaults.
    public var dllOverrides: [String: String] = [:]
    /// DLL overrides for one executable only (`HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`),
    /// such as `winegstreamer` off for a launcher whose web view crashes with it.
    public var programDllOverrides: [String: [String: String]] = [:]
    /// Extra variables from the game's profile; they win over everything else.
    public var environment: [String: String] = [:]
    /// Diagnostic mode: Wine's errors, DLL loads and DXMT's log go to the
    /// bottle's `logs/session-<time>.log`.
    public var diagnostics = false

    public init() {}

    public static func == (a: GameOptions, b: GameOptions) -> Bool {
        a.mouselook == b.mouselook && a.gameMode == b.gameMode && a.direct3D11 == b.direct3D11 && a.appDPI?.dpi == b.appDPI?.dpi
            && a.appDPI?.programs == b.appDPI?.programs && a.dllOverrides == b.dllOverrides && a.environment == b.environment
            && a.programDllOverrides == b.programDllOverrides && a.diagnostics == b.diagnostics
    }

    /// These options under `player`'s: lists are joined, the player's values
    /// win in maps, and the player's DPI setting replaces this one.
    public func overridden(by player: GameOptions) -> GameOptions {
        var result = self
        result.mouselook += player.mouselook.filter { !mouselook.contains($0) }
        result.gameMode += player.gameMode.filter { !gameMode.contains($0) }
        if let dpi = player.appDPI { result.appDPI = dpi }
        if let d3d = player.direct3D11 { result.direct3D11 = d3d }
        result.dllOverrides.merge(player.dllOverrides) { $1 }
        for (program, overrides) in player.programDllOverrides {
            result.programDllOverrides[program, default: [:]].merge(overrides) { $1 }
        }
        result.environment.merge(player.environment) { $1 }
        result.diagnostics = player.diagnostics
        return result
    }

    enum CodingKeys: String, CodingKey {
        case mouselook, gameMode, direct3D11, appDPI, appDPIPrograms, dllOverrides, programDllOverrides, environment, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mouselook = try c.decodeIfPresent([String].self, forKey: .mouselook) ?? []
        gameMode = try c.decodeIfPresent([String].self, forKey: .gameMode) ?? []
        direct3D11 = try c.decodeIfPresent(Direct3D11.self, forKey: .direct3D11)
        if let dpi = try c.decodeIfPresent(Int.self, forKey: .appDPI) {
            appDPI = (dpi, try c.decodeIfPresent([String].self, forKey: .appDPIPrograms) ?? [])
        }
        dllOverrides = try c.decodeIfPresent([String: String].self, forKey: .dllOverrides) ?? [:]
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        programDllOverrides = try c.decodeIfPresent([String: [String: String]].self, forKey: .programDllOverrides) ?? [:]
        diagnostics = try c.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mouselook, forKey: .mouselook)
        try c.encode(gameMode, forKey: .gameMode)
        try c.encodeIfPresent(direct3D11, forKey: .direct3D11)
        try c.encodeIfPresent(appDPI?.dpi, forKey: .appDPI)
        try c.encodeIfPresent(appDPI?.programs, forKey: .appDPIPrograms)
        try c.encode(dllOverrides, forKey: .dllOverrides)
        try c.encode(environment, forKey: .environment)
        try c.encode(programDllOverrides, forKey: .programDllOverrides)
        try c.encode(diagnostics, forKey: .diagnostics)
    }
}

/// The complete environment for running Wine from a Riftway runtime in one
/// bottle. It replaces the caller's environment instead of extending it, so a
/// developer's HOME, caches or Wine variables never leak into a bottle, the way
/// Recall's worker does (`wineEnv()` in its `portable_setup.m`).
public enum RuntimeEnvironment {
    /// Graphics through DXMT for D3D10/11; D3D12, NVAPI and NGX stay off so no
    /// stand-in claims a GPU the Mac doesn't have. `winemenubuilder` is off:
    /// Riftway makes its own shortcuts and associations.
    public static let baseDLLOverrides: [String: String] = [
        "d3d11": "b", "dxgi": "b", "d3d10core": "b", "winemetal": "b",
        "d3d12": "", "nvapi64": "", "nvngx": "",
        "winemenubuilder.exe": "",
    ]

    /// Where the bottle's DXMT configuration lives, inside the prefix: bottles
    /// have no `Z:` drive, so a host path would be unreachable from Windows.
    public static let dxmtConfigWindowsPath = #"C:\ProgramData\Riftway\dxmt.conf"#

    public static func make(runtime: WineRuntime, bottleRoot: URL, prefix: URL, options: GameOptions = GameOptions(),
                            debug: String = "-all") -> [String: String] {
        let root = bottleRoot.path
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root + "/home",
            "USER": "riftway",
            "TMPDIR": root + "/tmp",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "WINEPREFIX": prefix.path,
            "WINEARCH": "win64",
            "WINELOADER": runtime.wine,
            "WINESERVER": runtime.wineserver,
            "WINEDEBUG": debug,
            "WINEMSYNC": "1",
            "WINEESYNC": "0",
            "DXMT_CONFIG_FILE": dxmtConfigWindowsPath,
            "DXMT_SHADER_CACHE_PATH": root + "/cache/shaders",
            "DXMT_PIPELINE_CACHE_PATH": root + "/cache/pipelines",
            "DXMT_LOG_LEVEL": "error",
            "DXMT_LOG_PATH": "none",
            "DXMT_PREPARE_SHADERS": "1",
            "DXMT_USE_DEFAULT_METAL_CACHE": "1",
            "DXMT_CANVAS_DRAWABLES": "3",
            // winegstreamer's GStreamer: plugins from the runtime only (never
            // Homebrew's), the registry cached per bottle, no GIO modules.
            "GST_PLUGIN_SYSTEM_PATH_1_0": runtime.root + "/lib/gstreamer-1.0",
            "GST_PLUGIN_PATH_1_0": "",
            "GST_PLUGIN_SCANNER_1_0": runtime.root + "/libexec/gstreamer-1.0/gst-plugin-scanner",
            "GST_REGISTRY_1_0": root + "/cache/gstreamer-1.0-registry.bin",
            "GIO_MODULE_DIR": runtime.root + "/lib/gio/modules",
            // winebus reads controllers through SDL in winedevice.exe, which is
            // never the frontmost app: Apple's GameController framework would
            // only deliver input to the frontmost one, so SDL reads them as
            // HID devices instead, in the background (PRD-08).
            "SDL_JOYSTICK_MFI": "0",
            "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS": "1",
        ]
        env["WINEDLLOVERRIDES"] = dllOverrides(baseDLLOverrides.merging(options.dllOverrides) { $1 })
        if !options.mouselook.isEmpty { env["WINEMAC_MOUSELOOK"] = options.mouselook.joined(separator: ";") }
        if !options.gameMode.isEmpty {
            env["WINE_GAME_MODE"] = options.gameMode.joined(separator: ",")
            // The game's own bundle, when it was made from this runtime's loader.
            if GameModeApp.isCurrent(bottleRoot: bottleRoot, runtime: runtime) {
                env["WINE_GAME_MODE_APP"] = GameModeApp.executable(bottleRoot: bottleRoot).path
            }
        }
        if options.direct3D11 == .wined3d {
            // Wine's own d3d11, dxgi and d3d10core, searched before DXMT's
            // (runtime/patches/wine-dll-path-first.patch).
            env["WINEDLLPATH_FIRST"] = runtime.root + "/lib/wine/wined3d"
        }
        if let dpi = options.appDPI, !dpi.programs.isEmpty {
            env["WINE_APP_DPI"] = "\(dpi.dpi):" + dpi.programs.joined(separator: ";")
        }
        if options.diagnostics {
            env["WINEDEBUG"] = diagnosticChannels
            env["DXMT_LOG_LEVEL"] = "info"
            env["DXMT_LOG_PATH"] = nil  // stderr, into the session log
        }
        env.merge(options.environment) { $1 }
        return env
    }

    /// Errors, DLL loads with timestamps and process ids; never `+relay` or
    /// `+process`, which would copy command lines (URLs with tokens) into the log.
    public static let diagnosticChannels = "fixme-all,+timestamp,+pid,+loaddll"

    /// Wine's syntax: DLLs that share a mode are joined by commas, groups by
    /// semicolons (`d3d11,dxgi=b;d3d12=`). Sorted so the value is stable.
    public static func dllOverrides(_ overrides: [String: String]) -> String {
        Dictionary(grouping: overrides, by: \.value)
            .sorted { $0.key < $1.key }
            .map { mode, entries in entries.map(\.key).sorted().joined(separator: ",") + "=" + mode }
            .joined(separator: ";")
    }
}
