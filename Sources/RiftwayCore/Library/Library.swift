import Foundation

/// A game in the library: one bottle, its programs and how to start it. Stored
/// in the bottle as `game.json`, next to `bottle.json` (runtime and options), so
/// a bottle folder carries everything about its game.
public struct Game: Codable, Sendable, Equatable, Identifiable {
    /// The bottle folder's name.
    public var id: String
    public var name: String
    public var publisher: String?
    /// What Play starts.
    public var primary: DiscoveredProgram?
    public var programs: [DiscoveredProgram]
    /// Schemes the bridge claims from macOS.
    public var schemes: [String]
    public var uninstall: UninstallEntry?
    public var drivers: [DriverEntry]
    /// The installer this game came from.
    public var installer: InstallerInfo?
    public var added: Date
    public var lastPlayed: Date?
    /// The bridge app, when one was made.
    public var bridge: String?
    /// What Play starts instead of `primary`, set by the player.
    public var customLaunch: CustomLaunch?
    /// Anti-cheats found in the bottle (nil in libraries from before M4).
    public var anticheat: [AntiCheatFinding]?
    /// A game a launcher installed in this bottle (Steam): Play goes through it.
    public var store: StoreLink?

    /// A Play button the player configured.
    public enum CustomLaunch: Codable, Sendable, Equatable {
        /// A link to one of the game's schemes (`dsropen:token;email;hash`),
        /// handed to the bottle as the website would. The link itself is in the
        /// secret store (`SecretStore`, account `secretAccount`), never here.
        case link(scheme: String)
        /// A program in the bottle with its own arguments.
        case command(path: String, arguments: String?)
    }

    /// The secret store account that holds this game's launch link.
    public var secretAccount: String { "game:" + id }

    public struct InstallerInfo: Codable, Sendable, Equatable {
        public var file: String
        public var product: String?
        public var version: String?
        public var signer: String?
        public var origin: [String]
    }

    public init(id: String, name: String, publisher: String? = nil, primary: DiscoveredProgram? = nil,
                programs: [DiscoveredProgram] = [], schemes: [String] = [], uninstall: UninstallEntry? = nil,
                drivers: [DriverEntry] = [], installer: InstallerInfo? = nil, added: Date = Date()) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.primary = primary
        self.programs = programs
        self.schemes = schemes
        self.uninstall = uninstall
        self.drivers = drivers
        self.installer = installer
        self.added = added
    }

    /// Takes in what a (re)discovery found. Programs and schemes are added,
    /// never removed; the primary program changes only if there was none.
    public mutating func merge(_ result: InstallResult) {
        for program in result.programs where !programs.contains(where: { $0.id == program.id }) { programs.append(program) }
        if primary == nil { primary = result.primary }
        for scheme in result.protocols.map(\.scheme) where !schemes.contains(scheme) { schemes.append(scheme) }
        if uninstall == nil {
            uninstall = result.uninstall.first { entry in
                guard let name = entry.displayName else { return false }
                return !name.lowercased().hasPrefix("wine ")
            }
        }
        for driver in result.drivers where !drivers.contains(driver) { drivers.append(driver) }
        var found = anticheat ?? []
        for finding in result.anticheat {
            if let i = found.firstIndex(where: { $0.vendor == finding.vendor }) {
                found[i].driver = found[i].driver || finding.driver
                found[i].protonModule = found[i].protonModule || finding.protonModule
            } else {
                found.append(finding)
            }
        }
        anticheat = found
    }
}

/// A game and its bottle, as the library lists them.
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public var game: Game
    /// The bottle: prefix, `bottle.json`, logs, controller setup.
    public var root: URL
    /// The game's own files (`game.json`, its cover): the bottle itself, or
    /// `<bottle>/Games/<id>` for a game its launcher installed there.
    public var folder: URL
    public var record: BottleRecord
    /// The runtime the bottle uses, when it is installed.
    public var runtime: WineRuntime?
    /// The game's profile, when the record names one Riftway knows.
    public var profile: GameProfile?
    /// The bottle's profile, which the bottle runs with: the game's, or for a
    /// game its launcher installed, the launcher's (Steam's webhelper
    /// arguments must reach Steam however it starts).
    public var bottleProfile: GameProfile? = nil

    public var id: String { game.id }

    public var compatibility: Compatibility { Compatibility(profile: profile, anticheat: game.anticheat ?? []) }

    /// Whether Play has something to start: a program, a launch link or a
    /// command, and the runtime it needs.
    public var canPlay: Bool {
        if game.store != nil { return runtime != nil }
        return !((game.primary == nil && game.customLaunch == nil)
          || (runtime == nil && (game.customLaunch != nil || game.primary?.windowsPath != nil)))
    }

    /// The profile changed since the bottle's registry and `dxmt.conf` were written.
    public var profileIsStale: Bool { profile.map { $0.revision != record.profileRevision } ?? false }

    /// The Riftway home's secret store (`<home>/Secrets`; bottles are `<home>/Bottles/<id>`).
    public var secrets: SecretStore {
        SecretStore(directory: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Secrets", isDirectory: true))
    }

    public var setup: BottleSetup? {
        runtime.map { BottleSetup(runtime: $0, root: root, options: record.options, profile: bottleProfile ?? profile, runtimeVersion: record.runtimeVersion) }
    }

    /// The sizes the player can give the interface, as Windows' scaling.
    public static let interfaceDPIs = [96, 144, 192]

    /// The programs an interface size applies to: those the player or the
    /// profile named (Steam's webhelper draws its window), or the primary program's file.
    public var interfacePrograms: [String] {
        if let programs = record.options.appDPI?.programs, !programs.isEmpty { return programs }
        if let programs = (bottleProfile ?? profile)?.appDPI?.programs, !programs.isEmpty { return programs }
        guard let path = game.primary?.windowsPath,
              let file = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last else { return [] }
        return [String(file)]
    }

    /// The interface's DPI without the player's choice: its profile's, or Wine's 96.
    public var profileInterfaceDPI: Int { (bottleProfile ?? profile)?.appDPI?.dpi ?? 96 }
}

/// Reads and writes the library: every `Bottles/<id>/game.json`.
public struct Library: Sendable {
    public var home: RiftwayHome
    public var profiles: ProfileStore

    public init(home: RiftwayHome = .standard, profiles: ProfileStore? = nil) {
        self.home = home
        self.profiles = profiles ?? .standard(home: home)
    }

    static let gameFile = "game.json"
    /// Games a launcher installed in a bottle: `<bottle>/Games/<id>/game.json`.
    public static let storeGamesFolder = "Games"
    /// Store games the player chose not to add (`<bottle>/Games/declined.json`).
    static let declinedFile = "declined.json"
    static let recordFile = "bottle.json"
    public static let baselineFile = "baseline.json"

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func entries() -> [LibraryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.bottles.path) else { return [] }
        return names.sorted().flatMap { name -> [LibraryEntry] in
            let root = home.bottles.appendingPathComponent(name, isDirectory: true)
            guard let main = entry(at: root) else { return [] }
            return [main] + storeEntries(in: root)
        }
        .sorted { ($0.game.lastPlayed ?? $0.game.added) > ($1.game.lastPlayed ?? $1.game.added) }
    }

    /// The bottle's own game (`<bottle>/game.json`), or with `folder` one of
    /// the games its launcher installed there.
    public func entry(at root: URL, folder: URL? = nil) -> LibraryEntry? {
        let folder = folder ?? root
        guard let gameData = try? Data(contentsOf: folder.appendingPathComponent(Self.gameFile)),
              let game = try? Self.decoder.decode(Game.self, from: gameData),
              let recordData = try? Data(contentsOf: root.appendingPathComponent(Self.recordFile)),
              let record = try? Self.decoder.decode(BottleRecord.self, from: recordData)
        else { return nil }
        // A store game is not the launcher: the bottle's profile is the launcher's.
        let bottleProfile = record.profile.flatMap(profiles.profile(id:))
        return LibraryEntry(game: game, root: root, folder: folder, record: record,
                            runtime: home.runtime(version: record.runtimeVersion)?.runtime,
                            profile: game.store == nil ? bottleProfile : nil, bottleProfile: bottleProfile)
    }

    /// The entry as saved now (it may have changed since `entry` was read).
    public func current(_ entry: LibraryEntry) -> LibraryEntry? {
        self.entry(at: entry.root, folder: entry.folder)
    }

    public func save(_ game: Game, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(game).write(to: folder.appendingPathComponent(Self.gameFile), options: .atomic)
    }

    // MARK: Games a launcher installed (PRD-04 R1.6)

    func storeEntries(in root: URL) -> [LibraryEntry] {
        let games = root.appendingPathComponent(Self.storeGamesFolder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: games.path) else { return [] }
        return names.sorted().compactMap { name in
            let folder = games.appendingPathComponent(name, isDirectory: true)
            guard let entry = entry(at: root, folder: folder), entry.game.store != nil else { return nil }
            return entry
        }
    }

    /// The games the bottle's launcher has installed that are neither in the
    /// library nor declined: what Riftway offers to add.
    public func offeredStoreGames(in launcher: LibraryEntry) -> [InstalledStoreGame] {
        guard launcher.game.store == nil else { return [] }
        let prefix = launcher.root.appendingPathComponent("prefix")
        guard SteamLibrary.isSteamBottle(prefix: prefix) else { return [] }
        let linked = Set(storeEntries(in: launcher.root).compactMap { $0.game.store?.gameID })
        let declined = declinedStoreGames(in: launcher.root)
        return SteamLibrary.installed(prefix: prefix).filter { !linked.contains($0.id) && !declined.contains($0.id) }
    }

    /// Every game the launcher has installed, added or not (for the launcher's page).
    public func installedStoreGames(in launcher: LibraryEntry) -> [InstalledStoreGame] {
        let prefix = launcher.root.appendingPathComponent("prefix")
        guard launcher.game.store == nil, SteamLibrary.isSteamBottle(prefix: prefix) else { return [] }
        return SteamLibrary.installed(prefix: prefix)
    }

    /// Adds a game its launcher installed: its own entry in the bottle, the
    /// launcher's cover, its program (for the icon) and its anti-cheats.
    @discardableResult
    public func addStoreGame(_ installed: InstalledStoreGame, launcher: LibraryEntry) throws -> LibraryEntry {
        let folder = launcher.root.appendingPathComponent(Self.storeGamesFolder, isDirectory: true)
            .appendingPathComponent(installed.id, isDirectory: true)
        let prefix = launcher.root.appendingPathComponent("prefix")
        var game = Game(id: installed.id, name: installed.name, publisher: nil)
        game.store = installed.link
        if let program = SteamLibrary.mainProgram(installed.link, prefix: prefix) {
            game.primary = DiscoveredProgram(name: installed.name, target: .executable(path: program, arguments: nil))
            game.programs = [game.primary!]
        }
        if let folder = SteamLibrary.bottle(prefix).unixURL(forWindowsPath: installed.link.installDir),
           let walker = FileManager.default.enumerator(atPath: folder.path) {
            var files: [String] = []
            while let file = walker.nextObject() as? String { files.append(file) }
            game.anticheat = AntiCheatDetector.scan(files: files)
        }
        try save(game, in: folder)
        if let cover = installed.cover, let data = try? Data(contentsOf: cover) { try? CoverArt.set(data, in: folder) }
        var declined = declinedStoreGames(in: launcher.root)
        if declined.remove(installed.id) != nil { try writeDeclined(declined, in: launcher.root) }
        guard let entry = entry(at: launcher.root, folder: folder) else { throw CocoaError(.fileReadCorruptFile) }
        return entry
    }

    /// "Not now": Riftway does not offer the game again (the launcher's page still lists it).
    public func declineStoreGames(_ games: [InstalledStoreGame], launcher: LibraryEntry) throws {
        try writeDeclined(declinedStoreGames(in: launcher.root).union(games.map(\.id)), in: launcher.root)
    }

    /// Store games the launcher uninstalled: their library folder is there
    /// but their manifest is not (a disconnected drive removes nothing).
    public func uninstalledStoreGames(in launcher: LibraryEntry) -> [LibraryEntry] {
        let prefix = launcher.root.appendingPathComponent("prefix")
        guard launcher.game.store == nil, SteamLibrary.isSteamBottle(prefix: prefix) else { return [] }
        let installed = Set(SteamLibrary.installed(prefix: prefix).map(\.id))
        return storeEntries(in: launcher.root).filter { entry in
            guard let store = entry.game.store, !installed.contains(entry.id) else { return false }
            return SteamLibrary.libraryIsPresent(for: store, prefix: prefix)
        }
    }

    func declinedStoreGames(in root: URL) -> Set<String> {
        let file = root.appendingPathComponent(Self.storeGamesFolder).appendingPathComponent(Self.declinedFile)
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    private func writeDeclined(_ ids: Set<String>, in root: URL) throws {
        let folder = root.appendingPathComponent(Self.storeGamesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(ids.sorted()).write(to: folder.appendingPathComponent(Self.declinedFile), options: .atomic)
    }

    public func save(_ record: BottleRecord, in root: URL) throws {
        try Self.encoder.encode(record).write(to: root.appendingPathComponent(Self.recordFile), options: .atomic)
    }

    /// Discovers what the bottle gained since its baseline and records it in
    /// the game (PRD-01 R5.2: after every session, launchers install more).
    /// Returns the updated game and the schemes that are new to it.
    public func rediscover(_ entry: LibraryEntry) throws -> (Game, newSchemes: [String]) {
        let baseline = try PrefixSnapshot.read(from: entry.root.appendingPathComponent(Self.baselineFile))
        let result = InstallDiscovery.discover(prefix: entry.root.appendingPathComponent("prefix"), baseline: baseline,
                                               product: entry.game.installer?.product ?? entry.game.name)
        // The game as saved now, not as `entry` read it when the session
        // started: what Play starts may have changed meanwhile.
        var game = current(entry)?.game ?? entry.game
        let before = Set(game.schemes)
        game.merge(result)
        try save(game, in: entry.folder)
        return (game, game.schemes.filter { !before.contains($0) })
    }

    /// Sets the game's profile (nil: none) and writes it to the bottle: its
    /// registry values, per-program overrides and `dxmt.conf`. A profile's
    /// `play_link` becomes what Play starts, unless the player chose already.
    /// The bottle's programs must be closed. Returns the updated entry.
    @discardableResult
    public func apply(_ profile: GameProfile?, to entry: LibraryEntry) throws -> LibraryEntry {
        var entry = entry
        entry.profile = profile
        entry.record.profile = profile?.id
        entry.record.profileRevision = profile?.revision
        if let setup = entry.setup { try setup.applySettings() }
        try save(entry.record, in: entry.root)
        if let scheme = profile?.playLink, entry.game.customLaunch == nil, entry.game.schemes.contains(scheme) {
            entry.game.customLaunch = .link(scheme: scheme)
            try save(entry.game, in: entry.root)
        }
        return entry
    }

    /// After a session or an install: finds a profile for a game without one
    /// (launchers add programs a profile matches on) and writes a profile that
    /// changed since the bottle last applied it. Returns the updated entry
    /// when something changed.
    public func updateProfile(_ entry: LibraryEntry) throws -> LibraryEntry? {
        if entry.record.profile == nil, let found = profiles.match(ProfileQuery(game: entry.game)) {
            return try apply(found, to: entry)
        }
        if entry.profileIsStale, entry.runtime != nil { return try apply(entry.profile, to: entry) }
        return nil
    }
}
