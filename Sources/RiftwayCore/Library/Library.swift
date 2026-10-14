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

    /// A Play button the player configured.
    public enum CustomLaunch: Codable, Sendable, Equatable {
        /// A link to one of the game's schemes (`dsropen:token;email;hash`),
        /// handed to the bottle as the website would. The link itself is in the
        /// Keychain (`SecretStore`, account `keychainAccount`), never in files.
        case link(scheme: String)
        /// A program in the bottle with its own arguments.
        case command(path: String, arguments: String?)
    }

    /// The Keychain account that holds this game's launch link.
    public var keychainAccount: String { "game:" + id }

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
    }
}

/// A game and its bottle, as the library lists them.
public struct LibraryEntry: Sendable, Equatable, Identifiable {
    public var game: Game
    public var root: URL
    public var record: BottleRecord
    /// The runtime the bottle uses, when it is installed.
    public var runtime: WineRuntime?

    public var id: String { game.id }

    public var setup: BottleSetup? {
        runtime.map { BottleSetup(runtime: $0, root: root, options: record.options) }
    }
}

/// Reads and writes the library: every `Bottles/<id>/game.json`.
public struct Library: Sendable {
    public var home: RiftwayHome

    public init(home: RiftwayHome = .standard) { self.home = home }

    static let gameFile = "game.json"
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
        return names.sorted().compactMap { entry(at: home.bottles.appendingPathComponent($0, isDirectory: true)) }
            .sorted { ($0.game.lastPlayed ?? $0.game.added) > ($1.game.lastPlayed ?? $1.game.added) }
    }

    public func entry(at root: URL) -> LibraryEntry? {
        guard let gameData = try? Data(contentsOf: root.appendingPathComponent(Self.gameFile)),
              let game = try? Self.decoder.decode(Game.self, from: gameData),
              let recordData = try? Data(contentsOf: root.appendingPathComponent(Self.recordFile)),
              let record = try? Self.decoder.decode(BottleRecord.self, from: recordData)
        else { return nil }
        return LibraryEntry(game: game, root: root, record: record, runtime: home.runtime(version: record.runtimeVersion)?.runtime)
    }

    public func save(_ game: Game, in root: URL) throws {
        try Self.encoder.encode(game).write(to: root.appendingPathComponent(Self.gameFile), options: .atomic)
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
        var game = entry.game
        let before = Set(game.schemes)
        game.merge(result)
        try save(game, in: entry.root)
        return (game, game.schemes.filter { !before.contains($0) })
    }
}
