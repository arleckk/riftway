import Foundation

/// Installs a Windows installer into a new bottle (PRD-01 §4): creates the
/// bottle, records its baseline, copies the installer (and the files it needs
/// beside it) into the bottle, runs it as a player would and discovers what it
/// left. The installer's own wizard is shown as is; nothing is clicked for the
/// player.
public final class Installation: @unchecked Sendable {
    public enum Stage: Sendable, Equatable {
        case creatingBottle
        case copyingInstaller
        case runningInstaller
        case discovering
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAnInstaller
        case stopped
        public var description: String {
            switch self {
            case .notAnInstaller: "This file is not a Windows installer or program Riftway can run"
            case .stopped: "The installation was stopped"
            }
        }
    }

    public let library: Library
    public let report: InstallerReport
    public let name: String
    public let runtime: RiftwayHome.InstalledRuntime
    public let setup: BottleSetup
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    public init(report: InstallerReport, name: String? = nil, runtime: RiftwayHome.InstalledRuntime,
                library: Library = Library(), options: GameOptions = GameOptions()) {
        self.report = report
        self.name = name ?? report.displayName
        self.runtime = runtime
        self.library = library
        setup = BottleSetup(runtime: runtime.runtime, root: library.home.newBottleRoot(for: self.name), options: options)
    }

    public var root: URL { setup.root }

    /// Runs the whole installation and returns what it found. The installer's
    /// output goes to the bottle's `logs/installer.log`.
    /// `arguments` go to the installer after its path (`/S` for a silent NSIS
    /// install in tests; players see the wizard).
    public func run(arguments: [String] = [], progress: @Sendable (Stage) -> Void = { _ in }) throws -> InstallResult {
        let command: [String]
        switch report.kind {
        case .installer(.msi): command = ["msiexec", "/i"]
        case .installer: command = []
        case .portable: return try addPortable(progress: progress)
        case .unsupported: throw Failure.notAnInstaller
        }

        progress(.creatingBottle)
        try setup.create(name: name, runtimeVersion: runtime.version)
        try check()
        try PrefixSnapshot.capture(prefix: setup.prefix).write(to: root.appendingPathComponent(Library.baselineFile))
        try setup.applyProgramOverrides()

        progress(.copyingInstaller)
        let folderName = UUID().uuidString.prefix(8).lowercased()
        let folder = setup.prefix.appendingPathComponent("drive_c/ProgramData/Riftway/Installers/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in [report.file] + report.companions {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        let windowsPath = #"C:\ProgramData\Riftway\Installers\"# + folderName + "\\" + report.file.lastPathComponent
        try check()

        progress(.runningInstaller)
        var plan = setup.plan("wine", command + [windowsPath] + arguments)
        plan.workingDirectory = folder.path
        let status = try runInstaller(plan)
        Log().write("install: \(report.file.lastPathComponent) in \(root.lastPathComponent) exited with \(status)")
        try check()

        // Wine writes the registry to disk when its server exits (a few seconds
        // after the last program). A launcher the installer left running keeps
        // it alive: then discovery sees what is on disk, and the rediscovery
        // after that session finds the rest.
        progress(.discovering)
        do { try setup.waitForServer(timeout: 30) } catch is ProcessRunner.Timeout {
            Log().write("install: programs still running in \(root.lastPathComponent); discovering from the saved registry")
        }

        let baseline = try PrefixSnapshot.read(from: root.appendingPathComponent(Library.baselineFile))
        return InstallDiscovery.discover(prefix: setup.prefix, baseline: baseline, product: report.product ?? name)
    }

    /// A program without an installer (PRD-01 §7): copied into the bottle's
    /// `C:\Games\<name>`, its own folder with it when it has one.
    private func addPortable(progress: @Sendable (Stage) -> Void) throws -> InstallResult {
        progress(.creatingBottle)
        try setup.create(name: name, runtimeVersion: runtime.version)
        try check()
        try PrefixSnapshot.capture(prefix: setup.prefix).write(to: root.appendingPathComponent(Library.baselineFile))
        try setup.applyProgramOverrides()

        progress(.copyingInstaller)
        let (source, wholeFolder) = Self.portableSource(for: report.file)
        let folderName = Self.safeFolderName(wholeFolder ? source.lastPathComponent : name)
        let games = setup.prefix.appendingPathComponent("drive_c/Games", isDirectory: true)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let target = games.appendingPathComponent(folderName, isDirectory: true)
        if wholeFolder {
            try FileManager.default.copyItem(at: source, to: target)
        } else {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: report.file, to: target.appendingPathComponent(report.file.lastPathComponent))
        }
        try check()

        progress(.discovering)
        let relative = wholeFolder ? String(report.file.path.dropFirst(source.path.count + 1)) : report.file.lastPathComponent
        let windowsPath = #"C:\Games\"# + folderName + "\\" + relative.replacingOccurrences(of: "/", with: "\\")
        var result = InstallResult()
        let program = DiscoveredProgram.executable(windowsPath)
        result.primary = DiscoveredProgram(name: name, target: program.target, iconLocation: windowsPath)
        result.executables = [windowsPath]
        return result
    }

    /// The program's folder, unless it is a folder of the user's (Downloads,
    /// the Desktop…) or a disk's root: then only the program is copied.
    public static func portableSource(for program: URL) -> (source: URL, wholeFolder: Bool) {
        let folder = program.deletingLastPathComponent().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let userFolders = ["", "Downloads", "Desktop", "Documents", "Applications", "Movies", "Music", "Pictures", "Public", "Library"]
            .map { $0.isEmpty ? home.path : home.appendingPathComponent($0).path }
        let shallow = folder.pathComponents.count <= 3  // "/", "/Applications", "/Volumes/Disk"
        if shallow || userFolders.contains(folder.path) { return (program, false) }
        return (folder, true)
    }

    static func safeFolderName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { "<>:\"/\\|?*".unicodeScalars.contains($0) || $0.value < 0x20 ? "_" : Character($0) }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return result.isEmpty ? "Program" : result
    }

    /// Ends every Windows process in the bottle (the installer and anything it started).
    public func stop() {
        lock.withLock { stopped = true }
        try? setup.killAll()
    }

    private func check() throws {
        if lock.withLock({ stopped }) { throw Failure.stopped }
    }

    private func runInstaller(_ plan: LaunchPlan) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory, isDirectory: true)
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        let log = try Log.appendHandle(setup.logs.appendingPathComponent("installer.log"))
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        try process.run()
        lock.withLock { self.process = process }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The game for the library, with `primary` (the player's choice on the
    /// result screen) or the discovered one.
    public func makeGame(_ result: InstallResult, primary: DiscoveredProgram? = nil, schemes: [String]? = nil) -> Game {
        var game = Game(id: root.lastPathComponent, name: name, publisher: report.company)
        game.merge(result)
        // An installer's file name ("SuperRumble Installer_20250116") says less
        // than the name it registers for uninstalling ("Digimon SuperRumble").
        if report.product == nil, let registered = game.uninstall?.displayName, !registered.isEmpty { game.name = registered }
        if game.publisher == nil { game.publisher = game.uninstall?.publisher }
        if let primary { game.primary = primary }
        if let schemes { game.schemes = schemes }
        game.installer = Game.InstallerInfo(file: report.file.lastPathComponent, product: report.product, version: report.version,
                                            signer: { if case .signed(let signer, _) = report.signature { signer } else { nil } }(),
                                            origin: report.origin)
        return game
    }
}
