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
    /// Games whose bottle has programs open, however they were started (the
    /// app, the game's site through its bridge, a launcher).
    private(set) var running: Set<String> = []
    /// Games started from the app whose Wine server may not be up yet.
    private var starting: [String: Date] = [:]
    private var watcher: Task<Void, Never>?
    private(set) var icons: [String: NSImage] = [:]
    /// Each game's generated cover, from its icon (Riftway's own without one).
    private(set) var palettes: [String: CoverPalette] = [:]
    /// When each open game was first seen open, for its session time.
    private(set) var runningSince: [String: Date] = [:]
    var job: InstallJob?
    /// An error to show in an alert.
    var problem: String?

    let library = Library()
    private let log = Log()

    /// Checks every two seconds which bottles are open. When one closes, its
    /// bottle is searched again: launchers install programs and protocols
    /// after the installer (PRD-01 R5.2).
    func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshRunning()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshRunning() {
        var now: Set<String> = []
        for entry in entries where WineServer.isRunning(prefix: entry.root.appendingPathComponent("prefix")) {
            now.insert(entry.id)
            starting[entry.id] = nil
        }
        // Wine takes a moment to start; give a launch 20 s to show up.
        starting = starting.filter { Date().timeIntervalSince($0.value) < 20 }
        now.formUnion(starting.keys)
        let closed = running.subtracting(now)
        if now != running { running = now }
        for id in now where runningSince[id] == nil { runningSince[id] = Date() }
        for id in runningSince.keys where !now.contains(id) { runningSince[id] = nil }
        for id in closed {
            if let entry = entries.first(where: { $0.id == id }) { sessionEnded(entry) }
        }
    }

    private func sessionEnded(_ entry: LibraryEntry) {
        let library = library
        let shim = shimBinary
        Task {
            let newSchemes: [String] = await Task.detached {
                guard let (_, schemes) = try? library.rediscover(entry), var updated = library.entry(at: entry.root) else { return [] }
                // Launchers download the programs a profile matches on.
                var profileChanged = false
                if let applied = try? library.updateProfile(updated) {
                    updated = applied
                    profileChanged = true
                }
                if !schemes.isEmpty || profileChanged, updated.game.bridge != nil {
                    _ = try? GameLauncher.makeBridge(for: updated, shimBinary: shim, home: library.home)
                }
                return schemes
            }.value
            if !newSchemes.isEmpty { log.write("app: \(entry.game.name) registered \(newSchemes.joined(separator: ", "))") }
            reload()
        }
    }

    func reload() {
        runtimes = library.home.installedRuntimes()
        entries = library.entries()
        for entry in entries where icons[entry.id] == nil {
            if let data = GameLauncher.iconData(for: entry), let image = NSImage(data: data) { icons[entry.id] = image }
        }
        for entry in entries where palettes[entry.id] == nil {
            palettes[entry.id] = icons[entry.id]?.coverPalette ?? .riftway
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

    func install(_ report: InstallerReport, profile: GameProfile?) {
        guard let runtime = runtimes.first else {
            problem = "Primero instala un runtime (menú Archivo › Instalar runtime…)."
            return
        }
        let job = InstallJob(installation: Installation(report: report, runtime: runtime, library: library, profile: profile))
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
                    let app = try await Task.detached {
                        // A profile found only now, from the installed programs.
                        let entry = (try library.updateProfile(entry)) ?? entry
                        return try GameLauncher.makeBridge(for: entry, shimBinary: shim, home: library.home)
                    }.value
                    if let saved = library.entry(at: root) { game = saved.game }
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
                InputHelper.startIfNeeded(app: InputHelper.bundle(nextTo: shimBinary), bottleRoot: entry.root)
                starting[entry.id] = Date()
                running.insert(entry.id)
            }
            var game = entry.game
            game.lastPlayed = Date()
            try library.save(game, in: entry.root)
        } catch {
            problem = "\(error)"
        }
    }

    /// Runs the game's uninstaller in its bottle; the bottle stays (its saves
    /// may be there) and the search after the session updates the game.
    func uninstall(_ entry: LibraryEntry) {
        do {
            let pid = try Launcher.start(try GameLauncher.uninstallPlan(for: entry))
            log.write("app: started the uninstaller of \(entry.game.name) (pid \(pid))")
            starting[entry.id] = Date()
            running.insert(entry.id)
        } catch {
            problem = "\(error)"
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

    /// A profile that matches a game without one.
    func suggestedProfile(for entry: LibraryEntry) -> GameProfile? {
        library.profiles.match(ProfileQuery(game: entry.game))
    }

    /// Sets the game's profile (nil: none), writes it to the bottle and
    /// rebuilds the bridge, which carries the bottle's options.
    func setProfile(_ entry: LibraryEntry, _ profile: GameProfile?) {
        let library = library
        let shim = shimBinary
        Task {
            do {
                try await Task.detached {
                    let updated = try library.apply(profile, to: entry)
                    if updated.game.bridge != nil { _ = try GameLauncher.makeBridge(for: updated, shimBinary: shim, home: library.home) }
                }.value
                log.write("app: \(entry.game.name) uses profile \(profile?.id ?? "none")")
            } catch {
                problem = "\(error)"
            }
            reload()
        }
    }

    func showDriveC(_ entry: LibraryEntry) {
        NSWorkspace.shared.open(entry.root.appendingPathComponent("prefix/drive_c"))
    }

    func showLogs(_ entry: LibraryEntry) {
        let logs = entry.root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }

    /// Sets what Play starts; `link` (with its token) goes to the secret store.
    func setCustomLaunch(_ entry: LibraryEntry, _ custom: Game.CustomLaunch?, link: String?) throws {
        let game = try GameLauncher.setCustomLaunch(custom, link: link, for: entry, library: library)
        if game.bridge != nil, let updated = library.entry(at: entry.root) {
            _ = try? GameLauncher.makeBridge(for: updated, shimBinary: shimBinary, home: library.home)
        }
        reload()
    }

    /// After Riftway changes version, every bridge is rebuilt with the new
    /// shim (PRD-06 R7); their schemes and defaults stay.
    func rebuildBridgesAfterUpdate() {
        let key = "lastRunVersion"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(Riftway.version, forKey: key)
        guard let last, last != Riftway.version else { return }
        let library = library
        let shim = shimBinary
        let entries = library.entries().filter { $0.game.bridge != nil }
        Task.detached { [log] in
            for entry in entries { _ = try? GameLauncher.makeBridge(for: entry, shimBinary: shim, home: library.home) }
            log.write("app: rebuilt \(entries.count) bridges after updating from \(last)")
        }
    }

    /// Saves the game's controller setup. A running Riftway Input picks it up
    /// at once; the next launch starts it if the setup needs it.
    func saveController(_ layout: ControllerLayout, for entry: LibraryEntry) throws {
        try layout.write(bottle: entry.root)
        log.write("app: \(entry.game.name) controller setup saved (\(layout.programs.count) programs)")
        if running.contains(entry.id) { InputHelper.startIfNeeded(app: InputHelper.bundle(nextTo: shimBinary), bottleRoot: entry.root) }
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
            palettes[entry.id] = nil
        } catch {
            problem = "\(error)"
        }
        reload()
    }
}
