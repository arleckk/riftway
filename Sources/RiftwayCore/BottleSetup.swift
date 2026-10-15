import Foundation

/// Runs a process to completion with a deadline, its output in a log file.
public enum ProcessRunner {
    public struct Timeout: Error, CustomStringConvertible {
        public let command: String
        public var description: String { "timed out: \(command)" }
    }

    public enum Output: Sendable { case discard, inherit, file(URL) }

    /// Exit status of `plan`. Past `timeout` seconds it is terminated (then
    /// killed after two seconds) and `Timeout` is thrown.
    @discardableResult
    public static func run(_ plan: LaunchPlan, log: URL?, timeout: TimeInterval) throws -> Int32 {
        try run(plan, output: log.map(Output.file) ?? .discard, timeout: timeout)
    }

    @discardableResult
    public static func run(_ plan: LaunchPlan, output: Output, timeout: TimeInterval) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory, isDirectory: true)
        process.environment = plan.replacesEnvironment ? plan.environment
            : ProcessInfo.processInfo.environment.merging(plan.environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        var handle: FileHandle?
        switch output {
        case .discard:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .inherit:
            break
        case .file(let url):
            handle = try Log.appendHandle(url)
            process.standardOutput = handle
            process.standardError = handle
        }
        defer { try? handle?.close() }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); done.wait() }
            throw Timeout(command: ([plan.executable] + plan.arguments).joined(separator: " "))
        }
        return process.terminationStatus
    }
}

/// What Riftway records about a bottle it created, in `<bottle>/bottle.json`.
public struct BottleRecord: Codable, Sendable, Equatable {
    public var name: String
    public var runtimeVersion: String
    public var created: Date
    /// The player's own options, on top of the profile's.
    public var options: GameOptions
    /// The game's profile (`GameProfile.id`) and the revision last written to
    /// the bottle's registry and `dxmt.conf`.
    public var profile: String?
    public var profileRevision: Int?
    /// The profiles of the launcher's games last written to the bottle, by id
    /// and revision (PRD-04 R1.6).
    public var storeProfiles: [String: Int]?

    public init(name: String, runtimeVersion: String, created: Date, options: GameOptions,
                profile: String? = nil, profileRevision: Int? = nil) {
        self.name = name
        self.runtimeVersion = runtimeVersion
        self.created = created
        self.options = options
        self.profile = profile
        self.profileRevision = profileRevision
    }
}

/// This build of Riftway, as bottles report it (`HKLM\Software\Riftway`).
/// Keep in step with `app/Info.plist`.
public enum Riftway {
    public static let version = "0.1.0"
}

/// Creates and prepares bottles on a Riftway runtime: `<root>/prefix` is the
/// Wine prefix; `home`, `tmp`, `cache` and `logs` keep everything else inside the
/// bottle. Follows the steps of Recall's worker (`prepare()`), plus isolation.
public struct BottleSetup: Sendable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case runtimeMissing(String)
        case alreadyExists(String)
        case step(String, status: Int32)
        case noPrefix

        public var description: String {
            switch self {
            case .runtimeMissing(let path): "No runtime at \(path) (bin/wine missing)"
            case .alreadyExists(let path): "A bottle already exists at \(path)"
            case .step(let step, let status): "\(step) failed with status \(status) (see the bottle's logs/)"
            case .noPrefix: "wineboot finished without creating system.reg"
            }
        }
    }

    public var runtime: WineRuntime
    public var root: URL
    /// The player's options.
    public var options: GameOptions
    /// The game's profile; its options are under the player's.
    public var profile: GameProfile?
    /// The runtime's version, for the bottle's identity (`HKLM\Software\Riftway`).
    public var runtimeVersion: String?
    /// The profiles of the games the bottle's launcher installed (Palworld in
    /// Steam's): settings for their own programs only.
    public var storeProfiles: [GameProfile]

    public init(runtime: WineRuntime, root: URL, options: GameOptions = GameOptions(), profile: GameProfile? = nil,
                runtimeVersion: String? = nil, storeProfiles: [GameProfile] = []) {
        self.runtime = runtime
        self.root = root
        self.options = options
        self.profile = profile
        self.runtimeVersion = runtimeVersion
        self.storeProfiles = storeProfiles
    }

    /// What the bottle runs with: the profile's options with its launcher's
    /// games' programs added, then the player's.
    public var effectiveOptions: GameOptions {
        GameProfile.options(profile?.options ?? GameOptions(), adding: storeProfiles).overridden(by: options)
    }

    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var bottle: Bottle {
        Bottle(name: root.lastPathComponent, prefix: prefix.path, backend: .riftway(runtime: runtime, options: effectiveOptions))
    }

    public var environment: [String: String] {
        RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: prefix, options: effectiveOptions)
    }

    /// A command from the runtime's `bin/`, in the bottle's environment. It starts
    /// in `C:\` once the prefix exists: the bottle has no `Z:`, so Wine cannot map
    /// a folder outside the prefix.
    public func plan(_ tool: String, _ arguments: [String]) -> LaunchPlan {
        let driveC = prefix.appendingPathComponent("drive_c")
        let folder = FileManager.default.fileExists(atPath: driveC.path) ? driveC.path : root.path
        return LaunchPlan(executable: runtime.root + "/bin/" + tool, arguments: arguments, environment: environment,
                          workingDirectory: folder, replacesEnvironment: true)
    }

    /// Creates the bottle. `progress` gets a short line per step.
    public func create(name: String, runtimeVersion: String, progress: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: runtime.wine) else { throw Failure.runtimeMissing(runtime.root) }
        guard !fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw Failure.alreadyExists(root.path)
        }
        for folder in ["home", "tmp", "cache/shaders", "cache/pipelines", "logs"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        // The first start of a freshly signed x86_64 server goes through Rosetta
        // translation; Recall allows wineboot three minutes.
        progress("Creating the Windows environment (wineboot)…")
        let boot = try ProcessRunner.run(plan("wine", ["wineboot.exe", "-u", "-r"]), log: logs.appendingPathComponent("wineboot.log"), timeout: 180)
        guard boot == 0 else { throw Failure.step("wineboot", status: boot) }
        try waitForServer()
        guard fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else { throw Failure.noPrefix }

        progress("Isolating the bottle…")
        try isolate()

        progress("Writing settings…")
        var setup = self
        setup.runtimeVersion = runtimeVersion
        try setup.applySettings()
        try configureFontLinking()

        let record = BottleRecord(name: name, runtimeVersion: runtimeVersion, created: Date(), options: options,
                                  profile: profile?.id, profileRevision: profile?.revision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: root.appendingPathComponent("bottle.json"))
        progress("Ready.")
    }

    /// The drive letter for the runtime's shared data (`share/wine`).
    public static let runtimeDrive = "r:"

    /// Removes the `Z:` drive Wine maps to the Mac's whole file system and maps
    /// `R:` to the runtime's `share/wine` only. Wine is not a sandbox; without
    /// `Z:` a Windows program sees `C:`, the runtime's shared data and any folder
    /// the user adds, not the user's files. Wine finds shared components (Wine
    /// Mono for .NET programs) only through a drive letter, which `R:` provides.
    /// Safe to repeat; a bottle moved to another runtime gets `R:` re-pointed.
    public func isolate() throws {
        let fm = FileManager.default
        let devices = prefix.appendingPathComponent("dosdevices")
        let z = devices.appendingPathComponent("z:")
        if (try? fm.destinationOfSymbolicLink(atPath: z.path)) != nil { try fm.removeItem(at: z) }
        let r = devices.appendingPathComponent(Self.runtimeDrive)
        let target = runtime.root + "/share/wine"
        if let current = try? fm.destinationOfSymbolicLink(atPath: r.path) {
            if current == target { return }
            try fm.removeItem(at: r)
        }
        try fm.createSymbolicLink(atPath: r.path, withDestinationPath: target)
    }

    /// Writes a string value with Wine's `reg.exe`, never by editing hive files
    /// under a live server.
    public func registry(_ key: String, value: String, data: String) throws {
        let status = try ProcessRunner.run(plan("wine", ["reg.exe", "add", key, "/v", value, "/t", "REG_SZ", "/d", data, "/f"]),
                                           log: logs.appendingPathComponent("registry.log"), timeout: 60)
        guard status == 0 else { throw Failure.step("reg add \(key)\\\(value)", status: status) }
        try waitForServer()
    }

    /// Riftway's settings for the bottle, as one `.reg` file: Retina mode, the
    /// bottle's identity, per-program DLL overrides and the profile's values.
    /// Per-program overrides replace what an earlier profile wrote.
    public var settingsFile: String {
        var text = "Windows Registry Editor Version 5.00\r\n"
        func key(_ path: String, _ values: [(String, String)]) {
            text += "\r\n[\(path)]\r\n"
            for (name, data) in values { text += "\"\(Self.regEscape(name))\"=\(data)\r\n" }
        }
        key(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, [("RetinaMode", #""Y""#)])
        // PRD-07 R3.1: what the game runs on, in both registry views.
        let identity = [("Version", "\"\(Riftway.version)\""), ("Runtime", "\"\(Self.regEscape(runtimeVersion ?? "unknown"))\""),
                        ("Platform", #""macOS""#)]
        key(#"HKEY_LOCAL_MACHINE\Software\Riftway"#, identity)
        key(#"HKEY_LOCAL_MACHINE\Software\Wow6432Node\Riftway"#, identity)
        // PlayStation controllers as XInput gamepads (through SDL), as most
        // games expect and as Steam Input presents them; Wine would otherwise
        // pass them raw, like Windows does, and XInput-only games (DSR) would
        // not see them (PRD-08).
        for device in Self.playStationControllers {
            key(#"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus\Devices\"# + device, [("Hidraw", "dword:00000000")])
        }
        let appDefaults = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults"#
        text += "\r\n[-\(appDefaults)]\r\n"
        for (program, overrides) in effectiveOptions.programDllOverrides.sorted(by: { $0.key < $1.key }) {
            key(appDefaults + "\\" + Self.regEscape(program) + "\\DllOverrides",
                overrides.sorted { $0.key < $1.key }.map { ($0.key, "\"\(Self.regEscape($0.value))\"") })
        }
        var registry = profile?.registry ?? [:]
        for game in storeProfiles { registry.merge(game.registry) { mine, _ in mine } }
        for (path, values) in registry.sorted(by: { $0.key < $1.key }) {
            guard let full = GameProfile.registryPath(path) else { continue }
            key(full, values.sorted { $0.key < $1.key }.compactMap { name, value in GameProfile.registryData(value).map { (name, $0) } })
        }
        return text
    }

    /// `dxmt.conf`: the profile's lines and the player's, then a section for
    /// each launcher's game's program (DXMT reads the running program's last).
    public var dxmtConfText: String {
        let options = effectiveOptions
        var text = profile?.dxmtConfText ?? "# Written by Riftway from the game's profile.\n"
        if let fps = options.frameRateLimit { text += "# The player's frame rate limit.\nd3d11.preferredMaxFrameRate = \(fps)\n" }
        text += storeProfiles.map(\.dxmtConfSections).joined()
        for (program, fps) in options.programFrameRateLimits.sorted(by: { $0.key < $1.key }) {
            text += "\n# The player's frame rate limit for \(program).\n[\(program)]\nd3d11.preferredMaxFrameRate = \(fps)\n"
        }
        return text
    }

    /// Writes `dxmt.conf` alone: no Wine needed, read when a game makes its swap chain.
    public func writeDXMTConf() throws {
        let folder = prefix.appendingPathComponent("drive_c/ProgramData/Riftway", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(dxmtConfText.utf8).write(to: folder.appendingPathComponent("dxmt.conf"))
    }

    /// DualShock 4 (both models and the USB adapter), DualSense and DualSense Edge.
    public static let playStationControllers = ["054c/05c4", "054c/09cc", "054c/0ba0", "054c/0ce6", "054c/0df2"]

    /// Writes `settingsFile` and the profile's `dxmt.conf` into the bottle.
    /// Safe to repeat: after a profile changes, or to move a bottle to another runtime.
    public func applySettings() throws {
        let folder = prefix.appendingPathComponent("drive_c/ProgramData/Riftway", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeDXMTConf()
        // The profile's controller setup, unless the player has one.
        if let controller = profile?.controller, ControllerLayout.read(bottle: root) == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try controller.write(bottle: root)
        }
        var data = Data([0xFF, 0xFE])
        for unit in settingsFile.utf16 { data += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        try data.write(to: folder.appendingPathComponent("settings.reg"))
        let status = try ProcessRunner.run(plan("wine", ["reg.exe", "import", #"C:\ProgramData\Riftway\settings.reg"#]),
                                           log: logs.appendingPathComponent("registry.log"), timeout: 60)
        guard status == 0 else { throw Failure.step("reg import settings.reg", status: status) }
        try waitForServer()
    }

    static func regEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Waits until the bottle's Wine processes and server have exited.
    public func waitForServer(timeout: TimeInterval = 60) throws {
        _ = try ProcessRunner.run(plan("wineserver", ["-w"]), log: nil, timeout: timeout)
    }

    /// Ends every Wine process in the bottle.
    public func killAll() throws {
        _ = try ProcessRunner.run(plan("wineserver", ["-k"]), log: nil, timeout: 30)
    }
}
