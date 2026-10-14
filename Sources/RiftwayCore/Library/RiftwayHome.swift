import Foundation

/// Where Riftway keeps its runtimes and bottles:
///
///     ~/Library/Application Support/Riftway/
///       Runtimes/<version>/     bin/wine, lib/, share/, runtime.json
///       Bottles/<id>/           prefix/, bottle.json, game.json, baseline.json, logs/…
///     ~/Applications/Riftway/   one bridge app per game
///
/// `RIFTWAY_HOME` moves both (tests, development).
public struct RiftwayHome: Sendable, Equatable {
    public var root: URL
    public var bridges: URL

    public init(root: URL, bridges: URL) {
        self.root = root
        self.bridges = bridges
    }

    /// `RIFTWAY_HOME` keeps everything inside it, bridges in `<home>/Bridges`.
    public static var standard: RiftwayHome {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["RIFTWAY_HOME"] {
            let root = URL(fileURLWithPath: custom, isDirectory: true)
            return RiftwayHome(root: root, bridges: root.appendingPathComponent("Bridges", isDirectory: true))
        }
        return RiftwayHome(root: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Riftway", isDirectory: true),
                           bridges: fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Riftway", isDirectory: true))
    }

    public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("Bottles", isDirectory: true) }

    /// An installed runtime and its version (the folder's name).
    public struct InstalledRuntime: Sendable, Equatable {
        public var version: String
        public var runtime: WineRuntime
    }

    /// Installed runtimes, newest version first.
    public func installedRuntimes() -> [InstalledRuntime] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: runtimes.path) else { return [] }
        return names.compactMap { name -> InstalledRuntime? in
            let folder = runtimes.appendingPathComponent(name)
            guard !name.hasPrefix("."), fm.isExecutableFile(atPath: folder.appendingPathComponent("bin/wine").path) else { return nil }
            return InstalledRuntime(version: name, runtime: WineRuntime(root: folder.path))
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    public func runtime(version: String) -> InstalledRuntime? {
        installedRuntimes().first { $0.version == version }
    }

    public enum RuntimeInstallError: Error, CustomStringConvertible, Equatable {
        case notARuntime(String)
        case alreadyInstalled(String)
        public var description: String {
            switch self {
            case .notARuntime(let path): "\(path) is not a Riftway runtime (bin/wine and runtime.json are needed)"
            case .alreadyInstalled(let version): "Runtime \(version) is already installed"
            }
        }
    }

    /// Copies an assembled runtime folder into `Runtimes/<its name>`, as an APFS
    /// clone when the disk allows (instant, no extra space).
    @discardableResult
    public func installRuntime(from folder: URL) throws -> InstalledRuntime {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: folder.appendingPathComponent("bin/wine").path),
              fm.fileExists(atPath: folder.appendingPathComponent("runtime.json").path)
        else { throw RuntimeInstallError.notARuntime(folder.path) }
        let version = folder.lastPathComponent
        let target = runtimes.appendingPathComponent(version, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw RuntimeInstallError.alreadyInstalled(version) }
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let staging = runtimes.appendingPathComponent(".\(version)-\(UUID().uuidString)", isDirectory: true)
        // FileManager.copyItem clones on APFS and keeps symlinks and permissions.
        do {
            try fm.copyItem(at: folder, to: staging)
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return InstalledRuntime(version: version, runtime: WineRuntime(root: target.path))
    }

    /// A new, unused bottle folder for `name`: `Bottles/<slug>`, `<slug>-2`…
    public func newBottleRoot(for name: String) -> URL {
        let base = ShimBundle.slug(name).isEmpty ? "bottle" : ShimBundle.slug(name)
        var candidate = bottles.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bottles.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
