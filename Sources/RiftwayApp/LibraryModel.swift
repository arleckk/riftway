import AppKit
import Observation
import RiftwayCore

/// One installation, from the Install button to the result screen.
@MainActor @Observable
final class InstallJob: Identifiable {
    enum Phase: Equatable {
        case running(Installation.Stage)
        case stopping
        case result
        case failed(String)
    }

    let id = UUID()
    let installation: Installation
    var phase: Phase = .running(.creatingBottle)
    var result = InstallResult()
    /// The program Play starts, chosen on the result screen.
    var primaryID: String?
    var schemes: Set<String> = []
    var makeDefaultHandler = true

    init(installation: Installation) { self.installation = installation }

    var name: String { installation.name }
}

@MainActor @Observable
final class LibraryModel {
    private(set) var entries: [LibraryEntry] = []
    private(set) var runtimes: [RiftwayHome.InstalledRuntime] = []
    private(set) var running: Set<String> = []
    private(set) var icons: [String: NSImage] = [:]
    var job: InstallJob?
    /// An error to show in an alert.
    var problem: String?

    let library = Library()
    private let log = Log()

    func reload() {
        runtimes = library.home.installedRuntimes()
        entries = library.entries()
        for entry in entries where icons[entry.id] == nil {
            if let data = GameLauncher.iconData(for: entry), let image = NSImage(data: data) { icons[entry.id] = image }
        }
    }

    var shimBinary: URL {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + ShimBundle.executableName)
        if FileManager.default.isExecutableFile(atPath: helpers.path) { return helpers }
        // Run from `swift build`: the shim sits next to the app's executable.
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(ShimBundle.executableName)
    }

    // MARK: Runtimes

    func chooseRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Elige la carpeta de un runtime de Riftway (por ejemplo work/runtime/artifacts/rw-0.1.2-spike)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let home = library.home
        Task {
            do {
                _ = try await Task.detached { try home.installRuntime(from: folder) }.value
                reload()
            } catch {
                problem = "\(error)"
            }
        }
    }

    // MARK: Installing

    func install(_ report: InstallerReport) {
        guard let runtime = runtimes.first else {
            problem = "Primero instala un runtime (menú Archivo › Instalar runtime…)."
            return
        }
        let job = InstallJob(installation: Installation(report: report, runtime: runtime, library: library))
        self.job = job
        log.write("app: installing \(report.file.lastPathComponent) into \(job.installation.root.lastPathComponent)")
        let installation = job.installation
        Task {
            do {
                let result = try await Task.detached {
                    try installation.run { stage in Task { @MainActor in if job.phase != .stopping { job.phase = .running(stage) } } }
                }.value
                job.result = result
                job.primaryID = result.primary?.id
                job.schemes = Set(result.protocols.map(\.scheme))
                job.phase = .result
            } catch Installation.Failure.stopped {
                job.phase = .failed("Detuviste la instalación.")
            } catch {
                job.phase = .failed("\(error)")
            }
        }
    }

    func stopInstall(_ job: InstallJob) {
        job.phase = .stopping
        let installation = job.installation
        Task.detached { installation.stop() }
    }

    /// Adds the installed game to the library and builds its bridge.
    func finishInstall(_ job: InstallJob) {
        let result = job.result
        let candidates = result.programs + (result.primary.map { [$0] } ?? []) + result.executables.map(DiscoveredProgram.executable)
        let primary = candidates.first { $0.id == job.primaryID } ?? result.primary
        let schemes = result.protocols.map(\.scheme).filter(job.schemes.contains)
        var game = job.installation.makeGame(result, primary: primary, schemes: schemes)
        let root = job.installation.root
        let makeDefault = job.makeDefaultHandler
        self.job = nil
        let library = library
        let shim = shimBinary
        Task {
            do {
                try library.save(game, in: root)
                if let entry = library.entry(at: root) {
                    let app = try await Task.detached { try GameLauncher.makeBridge(for: entry, shimBinary: shim, home: library.home) }.value
                    game.bridge = app.path
                    try library.save(game, in: root)
                    if makeDefault {
                        for scheme in game.schemes { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) }
                    }
                }
            } catch {
                problem = "El juego se agregó, pero su app puente falló: \(error)"
            }
            reload()
        }
    }

    /// Closes a failed or empty installation, moving its bottle to the Trash.
    func discardInstall(_ job: InstallJob, keepBottle: Bool) {
        self.job = nil
        guard !keepBottle else { return }
        let root = job.installation.root
        let setup = job.installation.setup
        Task.detached {
            try? setup.killAll()
            try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
        }
    }

    // MARK: Playing

    func play(_ entry: LibraryEntry, program: DiscoveredProgram? = nil) {
        do {
            switch try GameLauncher.action(for: entry, program: program) {
            case .openWebPage(let url):
                NSWorkspace.shared.open(url)
            case .wine(let plan, let logFile):
                let pid = try Launcher.start(plan, outputLog: logFile)
                log.write("app: started \(entry.game.name) (pid \(pid))")
                watchSession(entry)
            }
            var game = entry.game
            game.lastPlayed = Date()
            try library.save(game, in: entry.root)
        } catch {
            problem = "\(error)"
        }
    }

    /// Marks the game as running until its bottle's last program exits, then
    /// looks for what a launcher installed meanwhile (PRD-01 R5.2).
    private func watchSession(_ entry: LibraryEntry) {
        guard !running.contains(entry.id) else { return }
        running.insert(entry.id)
        let library = library
        let shim = shimBinary
        Task {
            let newSchemes: [String] = await Task.detached {
                try? GameLauncher.waitForSessionEnd(entry)
                guard let (_, schemes) = try? library.rediscover(entry) else { return [] }
                if !schemes.isEmpty, entry.game.bridge != nil, let updated = library.entry(at: entry.root) {
                    _ = try? GameLauncher.makeBridge(for: updated, shimBinary: shim, home: library.home)
                }
                return schemes
            }.value
            running.remove(entry.id)
            if !newSchemes.isEmpty { log.write("app: \(entry.game.name) registered \(newSchemes.joined(separator: ", "))") }
            reload()
        }
    }

    func stop(_ entry: LibraryEntry) {
        guard let setup = entry.setup else { return }
        Task.detached { try? setup.killAll() }
    }

    // MARK: Settings and housekeeping

    func setDiagnostics(_ entry: LibraryEntry, _ on: Bool) {
        var record = entry.record
        record.options.diagnostics = on
        do {
            try library.save(record, in: entry.root)
            if entry.game.bridge != nil, let updated = library.entry(at: entry.root) {
                _ = try GameLauncher.makeBridge(for: updated, shimBinary: shimBinary, home: library.home)
            }
        } catch {
            problem = "\(error)"
        }
        reload()
    }

    func showDriveC(_ entry: LibraryEntry) {
        NSWorkspace.shared.open(entry.root.appendingPathComponent("prefix/drive_c"))
    }

    func showLogs(_ entry: LibraryEntry) {
        let logs = entry.root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }

    func rebuildBridge(_ entry: LibraryEntry) {
        do {
            let app = try GameLauncher.makeBridge(for: entry, shimBinary: shimBinary, home: library.home)
            var game = entry.game
            game.bridge = app.path
            try library.save(game, in: entry.root)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            problem = "\(error)"
        }
        reload()
    }

    /// Moves the game's bridge and bottle to the Trash (never deletes them).
    /// The bridge is unregistered after it moves (PRD-03: LaunchServices
    /// re-indexes a bundle still in place).
    func moveToTrash(_ entry: LibraryEntry) {
        let fm = FileManager.default
        do {
            if let setup = entry.setup { try? setup.killAll() }
            if let bridge = entry.game.bridge.map({ URL(fileURLWithPath: $0) }), fm.fileExists(atPath: bridge.path) {
                var trashed: NSURL?
                try fm.trashItem(at: bridge, resultingItemURL: &trashed)
                try? ShimBundle.unregister(bridge)
                if let trashed = trashed as URL? { try? ShimBundle.unregister(trashed) }
            }
            try fm.trashItem(at: entry.root, resultingItemURL: nil)
            icons[entry.id] = nil
        } catch {
            problem = "\(error)"
        }
        reload()
    }
}
