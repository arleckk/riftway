import Foundation

/// A Wine prefix and the Wine that runs it.
public struct Bottle: Sendable, Codable, Equatable {
    public enum Backend: Sendable, Codable, Equatable {
        /// A CrossOver bottle, started with CrossOver's `wine --bottle NAME`.
        case crossover(wine: String)
        /// A plain Wine build, started with `WINEPREFIX` set.
        case wine(wine: String)
        /// Riftway's own runtime, with the bottle's complete environment
        /// (`RuntimeEnvironment`). The prefix lives in `<bottle>/prefix`.
        case riftway(runtime: WineRuntime, options: GameOptions)

        public var winePath: String {
            switch self {
            case .crossover(let wine), .wine(let wine): wine
            case .riftway(let runtime, _): runtime.wine
            }
        }
    }

    public var name: String
    /// The prefix folder, the one holding `system.reg` and `drive_c`.
    public var prefix: String
    public var backend: Backend

    public init(name: String, prefix: String, backend: Backend) {
        self.name = name
        self.prefix = prefix
        self.backend = backend
    }

    public var prefixURL: URL { URL(fileURLWithPath: prefix, isDirectory: true) }

    /// The URL protocols registered in this prefix, read fresh from its hives (a
    /// launcher update can move the program a protocol points to).
    public func urlProtocols() -> [URLProtocolRegistration] {
        let system = try? WineRegistry(contentsOf: prefixURL.appendingPathComponent("system.reg"))
        let user = try? WineRegistry(contentsOf: prefixURL.appendingPathComponent("user.reg"))
        return URLProtocolRegistration.discover(system: system, user: user)
    }

    /// Maps `C:\Program Files\…` to the file inside the prefix, through
    /// `dosdevices/c:` as Wine does. Refuses `..` components.
    public func unixURL(forWindowsPath path: String) -> URL? {
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":", chars[0].isASCII, chars[0].isLetter else { return nil }
        let drive = chars[0].lowercased() + ":"
        let device = prefixURL.appendingPathComponent("dosdevices").appendingPathComponent(drive)
        var root: URL
        if FileManager.default.fileExists(atPath: device.path) {
            root = device.resolvingSymlinksInPath()
        } else if drive == "c:" {
            root = prefixURL.appendingPathComponent("drive_c")
        } else {
            return nil
        }
        let components = path.dropFirst(2).split(whereSeparator: { $0 == "\\" || $0 == "/" })
        guard !components.contains(where: { $0 == ".." }) else { return nil }
        for component in components where component != "." { root.appendPathComponent(String(component)) }
        return root
    }

    /// The command that runs `windowsArguments` (program first, as a Windows path)
    /// in this bottle, starting in the program's folder like a Windows shortcut.
    public func launchPlan(windowsArguments: [String], environment: [String: String] = [:]) throws(BridgeError) -> LaunchPlan {
        guard let program = windowsArguments.first else { throw .badWindowsPath("") }
        guard let exe = unixURL(forWindowsPath: program) else { throw .badWindowsPath(program) }
        guard FileManager.default.isExecutableFile(atPath: backend.winePath) else { throw .wineNotFound(backend.winePath) }
        guard FileManager.default.fileExists(atPath: exe.path) else { throw .executableNotFound(exe.path) }
        let folder = exe.deletingLastPathComponent().path
        let rest = Array(windowsArguments.dropFirst())
        switch backend {
        case .crossover(let wine):
            return LaunchPlan(executable: wine,
                              arguments: ["--bottle", name, "--workdir", folder, "--cx-app", exe.path] + rest,
                              environment: environment, workingDirectory: folder)
        case .wine(let wine):
            return LaunchPlan(executable: wine, arguments: [exe.path] + rest,
                              environment: environment.merging(["WINEPREFIX": prefix]) { $1 }, workingDirectory: folder)
        case .riftway(let runtime, let options):
            let full = RuntimeEnvironment.make(runtime: runtime, bottleRoot: prefixURL.deletingLastPathComponent(),
                                               prefix: prefixURL, options: options)
            return LaunchPlan(executable: runtime.wine, arguments: [exe.path] + rest,
                              environment: full.merging(environment) { $1 }, workingDirectory: folder,
                              replacesEnvironment: true)
        }
    }
}

/// CrossOver's bottles in their default location.
public enum CrossOver {
    public static let defaultWine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"

    public static var bottlesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    public static func bottles(wine: String = defaultWine) -> [Bottle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bottlesDirectory.path) else { return [] }
        return names.sorted().compactMap { name in
            let prefix = bottlesDirectory.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else { return nil }
            return Bottle(name: name, prefix: prefix.path, backend: .crossover(wine: wine))
        }
    }

    public static func bottle(named name: String, wine: String = defaultWine) -> Bottle? {
        bottles(wine: wine).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum BridgeError: Error, Equatable, CustomStringConvertible {
    case invalidURL(IncomingURLError)
    case schemeNotRegistered(scheme: String, bottle: String)
    case badWindowsPath(String)
    case executableNotFound(String)
    case wineNotFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .invalidURL(let e): "Rejected URL: \(e)"
        case .schemeNotRegistered(let s, let b): "No Windows program in bottle \(b) registers \(s):"
        case .badWindowsPath(let p): "Not a drive path inside the prefix: \(p)"
        case .executableNotFound(let p): "The registered program is missing: \(p)"
        case .wineNotFound(let p): "Wine was not found at \(p)"
        case .launchFailed(let m): "Could not start Wine: \(m)"
        }
    }
}
