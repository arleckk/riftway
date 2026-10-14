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
    public var options: GameOptions
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
    public var options: GameOptions

    public init(runtime: WineRuntime, root: URL, options: GameOptions = GameOptions()) {
        self.runtime = runtime
        self.root = root
        self.options = options
    }

    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var bottle: Bottle {
        Bottle(name: root.lastPathComponent, prefix: prefix.path, backend: .riftway(runtime: runtime, options: options))
    }

    public var environment: [String: String] {
        RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: prefix, options: options)
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
        try registry(#"HKCU\Software\Wine\Mac Driver"#, value: "RetinaMode", data: "Y")
        try configureFontLinking()
        let conf = prefix.appendingPathComponent("drive_c/ProgramData/Riftway/dxmt.conf")
        try fm.createDirectory(at: conf.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: conf.path) { try Data("# Written by Riftway from the game's profile.\n".utf8).write(to: conf) }

        let record = BottleRecord(name: name, runtimeVersion: runtimeVersion, created: Date(), options: options)
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

    /// Writes `options.programDllOverrides` as Wine's per-program defaults,
    /// replacing what an earlier profile wrote.
    public func applyProgramOverrides() throws {
        let key = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults"#
        _ = try ProcessRunner.run(plan("wine", ["reg.exe", "delete", key, "/f"]), log: logs.appendingPathComponent("registry.log"), timeout: 60)
        guard !options.programDllOverrides.isEmpty else { return try waitForServer() }
        var text = "Windows Registry Editor Version 5.00\r\n"
        for (program, overrides) in options.programDllOverrides.sorted(by: { $0.key < $1.key }) {
            text += "\r\n[\(key)\\\(Self.regEscape(program))\\DllOverrides]\r\n"
            for (dll, mode) in overrides.sorted(by: { $0.key < $1.key }) {
                text += "\"\(Self.regEscape(dll))\"=\"\(Self.regEscape(mode))\"\r\n"
            }
        }
        let file = prefix.appendingPathComponent("drive_c/ProgramData/Riftway/program-overrides.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        try data.write(to: file)
        let status = try ProcessRunner.run(plan("wine", ["reg.exe", "import", #"C:\ProgramData\Riftway\program-overrides.reg"#]),
                                           log: logs.appendingPathComponent("registry.log"), timeout: 60)
        guard status == 0 else { throw Failure.step("reg import program-overrides.reg", status: status) }
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
