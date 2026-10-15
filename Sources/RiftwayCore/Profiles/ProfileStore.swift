import CryptoKit
import Foundation

/// What is known about a game to find its profile: from the installer before
/// installing, and from the bottle after.
public struct ProfileQuery: Sendable, Equatable {
    public var products: [String] = []
    public var companies: [String] = []
    public var signers: [String] = []
    public var installerNames: [String] = []
    /// File names of the game's programs (`Launcher.exe`).
    public var executables: [String] = []
    public var hashes: [String] = []

    public init() {}

    /// Before installing: the installer's version strings, signer, name and hash.
    public init(report: InstallerReport, hash: Bool = true) {
        products = [report.product].compactMap { $0 }
        companies = [report.company].compactMap { $0 }
        if case .signed(let signer, _) = report.signature { signers = [signer] }
        installerNames = [report.file.lastPathComponent]
        if case .portable = report.kind { executables = [report.file.lastPathComponent] }
        if hash, let digest = Self.sha256(of: report.file) { hashes = [digest] }
    }

    /// A game in the library: its installer, the name and publisher it
    /// registered for uninstalling, and its programs.
    public init(game: Game, executables extra: [String] = []) {
        products = [game.installer?.product, game.uninstall?.displayName, game.name].compactMap { $0 }
        companies = [game.publisher, game.uninstall?.publisher].compactMap { $0 }
        signers = [game.installer?.signer].compactMap { $0 }
        installerNames = [game.installer?.file].compactMap { $0 }
        let paths = ([game.primary] + game.programs).compactMap { $0?.windowsPath } + extra
        executables = paths.map { path in path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path }
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The profiles Riftway knows: the ones it ships (`profiles/` in the
/// repository, `Contents/Resources/Profiles` in the app) and the ones in
/// `<home>/Profiles` (the feed's cache, or the player's own), which win over a
/// shipped profile with the same id when their revision is not older.
///
/// The release feed's profiles (PRD-05 R1.5) arrive signed in
/// `<home>/Updates/Profiles` (`Updater`).
public struct ProfileStore: Sendable {
    public private(set) var profiles: [GameProfile]
    /// Files that failed to load, with the reason.
    public private(set) var problems: [String: String]

    public init(profiles: [GameProfile]) {
        self.profiles = profiles.sorted { $0.id < $1.id }
        problems = [:]
    }

    public init(directories: [URL]) {
        var byID: [String: GameProfile] = [:]
        var problems: [String: String] = [:]
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                let file = directory.appendingPathComponent(name)
                do {
                    let profile = try GameProfile.load(try Data(contentsOf: file))
                    if let current = byID[profile.id], current.revision > profile.revision { continue }
                    byID[profile.id] = profile
                } catch {
                    problems[file.path] = "\(error)"
                }
            }
        }
        profiles = byID.values.sorted { $0.id < $1.id }
        self.problems = problems
    }

    /// Shipped profiles, then the release feed's (`Updates/Profiles`), then the player's own.
    public static func standard(home: RiftwayHome = .standard) -> ProfileStore {
        ProfileStore(directories: shippedDirectories() + [home.root.appendingPathComponent("Updates/Profiles", isDirectory: true),
                                                          home.root.appendingPathComponent("Profiles", isDirectory: true)])
    }

    /// `RIFTWAY_PROFILES`; the app's `Contents/Resources/Profiles` (from
    /// `Contents/MacOS` or `Contents/Helpers`); or, run from a checkout
    /// (`swift run`, tests), the repository's `profiles/`.
    public static func shippedDirectories() -> [URL] {
        if let path = ProcessInfo.processInfo.environment["RIFTWAY_PROFILES"], !path.isEmpty {
            return [URL(fileURLWithPath: path, isDirectory: true)]
        }
        let fm = FileManager.default
        var starts: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() { starts.append(executable.deletingLastPathComponent()) }
        #if DEBUG
        // Tests run from Xcode's or SwiftPM's runner, far from the checkout.
        starts.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        #endif
        for start in starts {
            let resources = start.deletingLastPathComponent().appendingPathComponent("Resources/Profiles", isDirectory: true)
            if fm.fileExists(atPath: resources.path) { return [resources] }
            var folder = start
            for _ in 0..<6 {
                let candidate = folder.appendingPathComponent("profiles", isDirectory: true)
                if fm.fileExists(atPath: folder.appendingPathComponent("Package.swift").path), fm.fileExists(atPath: candidate.path) {
                    return [candidate]
                }
                folder.deleteLastPathComponent()
            }
        }
        return []
    }

    public func profile(id: String) -> GameProfile? { profiles.first { $0.id == id } }

    /// Some profile matches on a hash: only then is an installer worth hashing.
    public var usesHashes: Bool { profiles.contains { !$0.match.sha256.isEmpty } }

    /// The best profile for a game: a hash beats a product with its company or
    /// an installer's signer, which beat an executable or installer name
    /// (PRD-05 R1.2). Ties go to the profile matching on more fields.
    /// The best profile for a game that is a bottle's own; launchers' games
    /// have theirs (`storeProfile`).
    public func match(_ query: ProfileQuery) -> GameProfile? {
        profiles.filter { !$0.isStoreGame }.compactMap { profile in Self.score(profile.match, query).map { (profile, $0) } }
            .max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.id > b.0.id }?.0
    }

    /// The profile of a game a launcher installed, by its store and app ID.
    public func storeProfile(for link: StoreLink) -> GameProfile? {
        switch link.store {
        case .steam: profiles.filter { $0.match.steam.contains(link.appID) }.max { $0.revision < $1.revision }
        }
    }

    static func score(_ match: GameProfile.Match, _ query: ProfileQuery) -> Int? {
        func same(_ a: String, _ b: String) -> Bool { InstallDiscovery.normalized(a) == InstallDiscovery.normalized(b) && !InstallDiscovery.normalized(a).isEmpty }
        func any(_ wanted: [String], _ have: [String]) -> Bool { wanted.contains { w in have.contains { same(w, $0) } } }
        var score = 0
        if match.sha256.contains(where: { h in query.hashes.contains { $0.lowercased() == h.lowercased() } }) { score += 1000 }
        if any(match.product, query.products), match.company.isEmpty || any(match.company, query.companies) { score += 100 }
        if any(match.signer, query.signers) { score += 100 }
        if match.executables.contains(where: { e in query.executables.contains { $0.lowercased() == e.lowercased() } }) { score += 10 }
        if match.installer.contains(where: { p in query.installerNames.contains { AntiCheatDetector.matches($0, p) } }) { score += 10 }
        return score > 0 ? score : nil
    }
}

/// What the player is told about a game: its status, why, and the
/// anti-cheats found in its bottle.
public struct Compatibility: Sendable, Equatable {
    public var status: CompatibilityStatus
    /// The profile the status comes from, if any.
    public var profile: GameProfile?
    public var anticheat: [AntiCheatFinding]

    /// A profile's status stands: it was tested with the anti-cheat in place.
    /// Without one, an anti-cheat that always needs a kernel driver, or any
    /// anti-cheat driver in the bottle, blocks the game; any other anti-cheat
    /// leaves it untested, with a warning.
    public init(profile: GameProfile?, anticheat: [AntiCheatFinding] = []) {
        self.profile = profile
        self.anticheat = anticheat
        if let profile {
            status = profile.status
        } else if anticheat.contains(where: { $0.vendor.alwaysKernel || $0.driver }) {
            status = .blocked
        } else {
            status = .untested
        }
    }

    /// The vendors known from the profile and from the bottle.
    public var vendors: [AntiCheatVendor] {
        var vendors = anticheat.map(\.vendor)
        if let vendor = profile?.anticheat?.vendor, !vendors.contains(vendor) { vendors.insert(vendor, at: 0) }
        return vendors
    }
}
