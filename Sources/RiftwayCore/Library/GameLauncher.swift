import Foundation

/// Starts a library game's programs and builds its bridge app.
public enum GameLauncher {
    public enum Action: Sendable, Equatable {
        /// Run Wine; its output goes to `log` in diagnostic mode.
        case wine(LaunchPlan, log: URL?)
        /// Open a web page in the Mac's browser (a game started from its site).
        case openWebPage(URL)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case runtimeMissing(String)
        case noProgram
        case badWebAddress(String)
        public var description: String {
            switch self {
            case .runtimeMissing(let version): "The runtime \(version) this game uses is not installed"
            case .noProgram: "This game has no program to start"
            case .badWebAddress(let url): "Not a web address: \(url)"
            }
        }
    }

    /// Where a session's Wine output goes in diagnostic mode.
    public static func sessionLog(root: URL, at date: Date = Date()) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent("logs/session-\(stamp).log")
    }

    public static func action(for entry: LibraryEntry, program: DiscoveredProgram? = nil) throws -> Action {
        // A launcher's game: the launcher starts it (DRM, cloud saves, overlay, Steam Input).
        if program == nil, let store = entry.game.store {
            guard let setup = entry.setup else { throw Failure.runtimeMissing(entry.record.runtimeVersion) }
            let plan = try URLBridge(bottle: setup.bottle, schemes: [store.store.rawValue]).plan(forURL: store.playLink)
            return .wine(plan, log: entry.record.options.diagnostics ? sessionLog(root: entry.root) : nil)
        }
        if program == nil, let custom = entry.game.customLaunch {
            guard let setup = entry.setup else { throw Failure.runtimeMissing(entry.record.runtimeVersion) }
            let log = entry.record.options.diagnostics ? sessionLog(root: entry.root) : nil
            switch custom {
            case .link(let scheme):
                // No link yet (the bridge remembers the first one the site
                // sends): Play opens what the installer left, the site.
                if let link = try entry.secrets.read(account: entry.game.secretAccount) {
                    let plan = try URLBridge(bottle: setup.bottle, schemes: [scheme]).plan(forURL: link)
                    return .wine(plan, log: log)
                }
            case .command(let path, let arguments):
                let plan = try setup.bottle.launchPlan(windowsArguments: [path] + (arguments.map(WindowsCommandLine.split) ?? []))
                return .wine(plan, log: log)
            }
        }
        guard let program = program ?? entry.game.primary else { throw Failure.noProgram }
        switch program.target {
        case .web(let address):
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Failure.badWebAddress(address)
            }
            return .openWebPage(url)
        case .executable(let path, let arguments):
            guard let setup = entry.setup else { throw Failure.runtimeMissing(entry.record.runtimeVersion) }
            let args = [path] + (arguments.map(WindowsCommandLine.split) ?? [])
            let plan = try setup.bottle.launchPlan(windowsArguments: args)
            return .wine(plan, log: entry.record.options.diagnostics ? sessionLog(root: entry.root) : nil)
        }
    }

    /// The game's own uninstaller (its `UninstallString`): a program in the
    /// bottle, or a Windows command such as `MsiExec.exe /X{…}`.
    public static func uninstallPlan(for entry: LibraryEntry) throws -> LaunchPlan {
        guard let setup = entry.setup else { throw Failure.runtimeMissing(entry.record.runtimeVersion) }
        guard let command = entry.game.uninstall?.uninstallString, !command.isEmpty else { throw Failure.noProgram }
        let args = WindowsCommandLine.split(command)
        guard let program = args.first else { throw Failure.noProgram }
        if program.count > 2, Array(program)[1] == ":" {
            return try setup.bottle.launchPlan(windowsArguments: args)
        }
        return setup.plan("wine", args)
    }

    /// Whether the program Play starts is still in the bottle.
    public static func primaryIsMissing(_ entry: LibraryEntry) -> Bool {
        let path: String?
        if case .command(let p, _)? = entry.game.customLaunch { path = p } else { path = entry.game.primary?.windowsPath }
        guard let path else { return false }
        let bottle = Bottle(name: entry.id, prefix: entry.root.appendingPathComponent("prefix").path, backend: .wine(wine: "/usr/bin/false"))
        guard let file = bottle.unixURL(forWindowsPath: path) else { return true }
        return !FileManager.default.fileExists(atPath: file.path)
    }

    /// Waits until every Windows process in the bottle has exited: the game's
    /// session is over, and so are launchers it started.
    public static func waitForSessionEnd(_ entry: LibraryEntry) throws {
        guard let setup = entry.setup else { return }
        try setup.waitForServer(timeout: 7 * 24 * 3600)
    }

    /// The icon of the game's primary program as `.ico` data: its icon file, or
    /// the program's own icon resource.
    public static func iconData(for entry: LibraryEntry) -> Data? {
        let bottle = Bottle(name: entry.game.id, prefix: entry.root.appendingPathComponent("prefix").path,
                            backend: .wine(wine: "/usr/bin/false"))
        var candidates: [String] = []
        if let icon = entry.game.primary?.iconLocation { candidates.append(icon) }
        if let path = entry.game.primary?.windowsPath { candidates.append(path) }
        if let icon = entry.game.uninstall?.displayIcon { candidates.append(icon.split(separator: ",").first.map(String.init) ?? icon) }
        for candidate in candidates {
            let path = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard let file = bottle.unixURL(forWindowsPath: path), let data = try? Data(contentsOf: file) else { continue }
            if path.lowercased().hasSuffix(".ico") { return data }
            if let pe = try? PEFile(data: data), let icon = pe.iconData() { return icon }
        }
        return nil
    }

    /// Sets what Play starts. A link is validated against the game's schemes
    /// and stored in the secret store; nil goes back to the discovered program.
    public static func setCustomLaunch(_ custom: Game.CustomLaunch?, link: String? = nil, for entry: LibraryEntry,
                                       library: Library) throws -> Game {
        var game = entry.game
        switch custom {
        case .link(let scheme)?:
            // Without a pasted link, the bridge remembers the next one the site sends.
            if let link {
                do { _ = try IncomingURL.validate(link, schemes: [scheme]) } catch { throw BridgeError.invalidURL(error) }
                try entry.secrets.save(link, account: game.secretAccount)
            }
        case .command?, nil:
            try entry.secrets.delete(account: game.secretAccount)
        }
        game.customLaunch = custom
        try library.save(game, in: entry.folder)
        return game
    }

    /// Builds (or rebuilds) the game's bridge app in `home.bridges`: its URL
    /// schemes, and a double-click that starts the primary program.
    @discardableResult
    public static func makeBridge(for entry: LibraryEntry, shimBinary: URL, home: RiftwayHome = .standard) throws -> URL {
        guard let setup = entry.setup else { throw Failure.runtimeMissing(entry.record.runtimeVersion) }
        var config = ShimConfig(displayName: entry.game.name, bottle: setup.bottle, schemes: entry.game.schemes)
        if let store = entry.game.store {
            // Claims no scheme (the launcher's bridge does); a double-click asks the launcher.
            config.schemes = []
            config.program = try URLBridge(bottle: setup.bottle, schemes: [store.store.rawValue]).windowsArguments(forURL: store.playLink)
        } else {
            switch (entry.game.customLaunch, entry.game.primary?.target) {
            case (.command(let path, let arguments)?, _), (_, .executable(let path, let arguments)?):
                config.program = [path] + (arguments.map(WindowsCommandLine.split) ?? [])
            case (_, .web(let url)?):
                // A double-click opens the site; the site's Start sends the link.
                config.webPage = url
            case (_, nil):
                break
            }
        }
        config.inputHelper = InputHelper.bundle(nextTo: shimBinary)?.path
        if case .link? = entry.game.customLaunch {
            config.rememberLinkAccount = entry.game.secretAccount
            config.secretsDirectory = entry.secrets.directory.path
        }
        try FileManager.default.createDirectory(at: home.bridges, withIntermediateDirectories: true)
        var icon: URL?
        if let data = iconData(for: entry) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-icon-\(UUID().uuidString).ico")
            try data.write(to: file)
            icon = file
        }
        defer { if let icon { try? FileManager.default.removeItem(at: icon) } }
        let app = try ShimBundle.build(config: config, shimBinary: shimBinary, icon: icon, in: home.bridges)
        try ShimBundle.register(app)
        // Game Mode's bundle, with the bridge's icon.
        let appIcon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        // One bundle per bottle, named after its own game (Steam, also for Palworld's bridge).
        let bottleName = entry.game.store == nil ? entry.game.name
            : (try? Data(contentsOf: entry.root.appendingPathComponent(Library.gameFile))).flatMap { try? Library.decoder.decode(Game.self, from: $0) }?.name
                ?? entry.game.name
        try GameModeApp.ensure(bottleRoot: entry.root, runtime: setup.runtime, options: setup.effectiveOptions, name: bottleName,
                               icon: FileManager.default.fileExists(atPath: appIcon.path) ? appIcon : nil)
        return app
    }
}
