import Darwin
import Foundation

/// A game a launcher installed in its own bottle (Steam), in the library as a
/// game of its own (PRD-04 R1.6): Riftway reads the launcher's records, and
/// Play asks the launcher to start it, so its DRM, cloud saves, overlay and
/// Steam Input keep working.
public struct StoreLink: Codable, Sendable, Equatable {
    public enum Store: String, Codable, Sendable {
        case steam
    }

    public var store: Store
    public var appID: String
    /// Where the launcher installed it (Windows path).
    public var installDir: String

    public init(store: Store, appID: String, installDir: String) {
        self.store = store
        self.appID = appID
        self.installDir = installDir
    }

    /// The library id of the game: `steam-945360`.
    public var gameID: String { "\(store.rawValue)-\(appID)" }
    /// What Play hands the launcher.
    public var playLink: String { "steam://rungameid/\(appID)" }
    /// The game's page in the launcher.
    public var pageLink: String { "steam://nav/games/details/\(appID)" }
    /// The launcher's own uninstall, with its confirmation.
    public var uninstallLink: String { "steam://uninstall/\(appID)" }
}

/// A game the launcher reports as installed.
public struct InstalledStoreGame: Sendable, Equatable, Identifiable {
    public var link: StoreLink
    public var name: String
    /// Its cover in the launcher's cache (2:3), when the launcher has one.
    public var cover: URL?
    public var id: String { link.gameID }
}

/// Valve's KeyValues text format (`.acf`, `.vdf`): quoted keys, quoted values
/// or `{ … }` blocks, `\\` escapes. Enough for Steam's manifests.
public enum ValveKeyValues {
    public indirect enum Node: Equatable, Sendable {
        case value(String)
        case block([(String, Node)])

        public static func == (a: Node, b: Node) -> Bool {
            switch (a, b) {
            case (.value(let x), .value(let y)): x == y
            case (.block(let x), .block(let y)): x.map(\.0) == y.map(\.0) && x.map(\.1) == y.map(\.1)
            default: false
            }
        }

        /// The child with this key (case-insensitive, like Steam).
        public subscript(key: String) -> Node? {
            guard case .block(let children) = self else { return nil }
            return children.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }

        public var string: String? {
            if case .value(let text) = self { text } else { nil }
        }

        public var children: [(String, Node)] {
            if case .block(let children) = self { children } else { [] }
        }
    }

    /// The top-level block (`"AppState" { … }` reads as a block holding AppState).
    public static func parse(_ text: String) -> Node {
        var scalars = Array(text.unicodeScalars)[...]
        return .block(block(&scalars))
    }

    private static func block(_ s: inout ArraySlice<Unicode.Scalar>) -> [(String, Node)] {
        var children: [(String, Node)] = []
        while let key = token(&s) {
            if key == "}" { break }
            guard let next = token(&s) else { break }
            if next == "{" {
                children.append((key, .block(block(&s))))
            } else {
                children.append((key, .value(next)))
            }
        }
        return children
    }

    /// The next quoted string, or `{` / `}`; skips whitespace and `//` comments.
    private static func token(_ s: inout ArraySlice<Unicode.Scalar>) -> String? {
        while let c = s.first {
            if CharacterSet.whitespacesAndNewlines.contains(c) {
                s.removeFirst()
            } else if c == "/", s.dropFirst().first == "/" {
                while let d = s.first, d != "\n" { s.removeFirst() }
            } else {
                break
            }
        }
        guard let c = s.first else { return nil }
        s.removeFirst()
        if c == "{" || c == "}" { return String(c) }
        var out = String.UnicodeScalarView()
        if c == "\"" {
            while let d = s.first {
                s.removeFirst()
                if d == "\"" { break }
                if d == "\\", let e = s.first {
                    s.removeFirst()
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(e)
                    }
                } else {
                    out.append(d)
                }
            }
        } else {
            // An unquoted token, up to whitespace or a brace.
            out.append(c)
            while let d = s.first, !CharacterSet.whitespacesAndNewlines.contains(d), d != "{", d != "}" {
                out.append(d)
                s.removeFirst()
            }
        }
        return String(out)
    }
}

/// Steam's records in a bottle: its library folders and the games in them.
public enum SteamLibrary {
    /// Apps Steam installs that are not games.
    static let notGames: Set<String> = ["228980"]  // Steamworks Common Redistributables

    /// Steam's folder in the prefix (Windows path), as Steam recorded it.
    public static func steamFolder(prefix: URL) -> String {
        if let registry = try? WineRegistry(contentsOf: prefix.appendingPathComponent("user.reg")),
           let path = registry.value("SteamPath", at: #"Software\Valve\Steam"#), path.count > 2 {
            return path.replacingOccurrences(of: "/", with: "\\")
        }
        return #"C:\Program Files (x86)\Steam"#
    }

    /// Whether the bottle has Steam (its library file or its program).
    public static func isSteamBottle(prefix: URL) -> Bool {
        let bottle = bottle(prefix)
        guard let folder = bottle.unixURL(forWindowsPath: steamFolder(prefix: prefix)) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("steamapps").path)
    }

    /// The games Steam has fully installed in the bottle, by name.
    public static func installed(prefix: URL) -> [InstalledStoreGame] {
        let bottle = bottle(prefix)
        let steam = steamFolder(prefix: prefix)
        var libraries = [steam]
        if let main = bottle.unixURL(forWindowsPath: steam),
           let text = try? String(contentsOf: main.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for (_, folder) in ValveKeyValues.parse(text)["libraryfolders"]?.children ?? [] {
                if let path = folder["path"]?.string, !libraries.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                    libraries.append(path)
                }
            }
        }
        let cache = bottle.unixURL(forWindowsPath: steam)?.appendingPathComponent("appcache/librarycache")
        var games: [InstalledStoreGame] = []
        for library in libraries {
            guard let apps = bottle.unixURL(forWindowsPath: library)?.appendingPathComponent("steamapps"),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: apps.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: apps.appendingPathComponent(file), encoding: .utf8),
                      let state = ValveKeyValues.parse(text)["AppState"],
                      let appID = state["appid"]?.string, !notGames.contains(appID),
                      let name = state["name"]?.string, let dir = state["installdir"]?.string,
                      // StateFlags 4: fully installed (an update in progress adds bits).
                      let flags = state["StateFlags"]?.string.flatMap(Int.init), flags & 4 != 0,
                      !games.contains(where: { $0.link.appID == appID }) else { continue }
                let installDir = library + #"\steamapps\common\"# + dir
                games.append(InstalledStoreGame(link: StoreLink(store: .steam, appID: appID, installDir: installDir),
                                                name: name, cover: cover(appID: appID, cache: cache)))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether the Steam library folder holding the game is there.
    public static func libraryIsPresent(for link: StoreLink, prefix: URL) -> Bool {
        guard let range = link.installDir.range(of: #"\steamapps\common\"#, options: .caseInsensitive),
              let apps = bottle(prefix).unixURL(forWindowsPath: link.installDir[..<range.lowerBound] + #"\steamapps"#) else { return false }
        return FileManager.default.fileExists(atPath: apps.path)
    }

    /// The portrait cover (600×900, 2:3) in Steam's library cache.
    static func cover(appID: String, cache: URL?) -> URL? {
        guard let folder = cache?.appendingPathComponent(appID) else { return nil }
        for name in ["library_600x900_2x.jpg", "library_600x900.jpg"] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        // Newer clients keep it in a hashed subfolder.
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.lastPathComponent == "library_600x900.jpg" { return file }
        }
        return nil
    }

    /// The program the game is: the `.exe` in its folder named like the
    /// game, else the largest, never a crash handler or a redistributable.
    public static func mainProgram(_ link: StoreLink, prefix: URL) -> String? {
        guard let folder = bottle(prefix).unixURL(forWindowsPath: link.installDir)?.resolvingSymlinksInPath(),
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let skipped = ["crash", "unins", "redist", "setup", "vc_", "dxsetup", "launcherhelper", "eac", "battleye", "report"]
        var best: (path: String, size: Int, named: Bool)?
        let folderName = folder.lastPathComponent.lowercased().filter(\.isLetter)
        for case let file as URL in walker where file.pathExtension.lowercased() == "exe" {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            if skipped.contains(where: name.contains) { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(folder.path.count)).replacingOccurrences(of: "/", with: "\\")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let named = name.filter(\.isLetter) == folderName
            if best == nil || (named && !best!.named) || (named == best!.named && size > best!.size) {
                best = (link.installDir + relative, size, named)
            }
        }
        return best?.path
    }

    static func bottle(_ prefix: URL) -> Bottle {
        Bottle(name: "steam", prefix: prefix.path, backend: .wine(wine: "/usr/bin/false"))
    }
}

/// The Windows programs Wine runs now: Wine names each process (`argv[0]`)
/// after its Windows path. Only that name is read, never the arguments.
public enum WindowsProcesses {
    public struct Process: Sendable, Equatable {
        public var pid: pid_t
        /// `C:\Program Files (x86)\Steam\steamapps\common\Among Us\Among Us.exe`.
        public var windowsPath: String
    }

    public static func running() -> [Process] {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var found: [Process] = []
        for info in procs.prefix(count) {
            let pid = info.kp_proc.p_pid
            guard pid > 0, let name = argv0(pid), name.count > 3,
                  name.dropFirst().hasPrefix(":\\"), name.lowercased().hasSuffix(".exe") else { continue }
            found.append(Process(pid: pid, windowsPath: name))
        }
        return found
    }

    /// The processes of a program in this folder (Windows path, any depth).
    public static func inFolder(_ folder: String, among processes: [Process]) -> [Process] {
        let prefix = folder.lowercased().hasSuffix("\\") ? folder.lowercased() : folder.lowercased() + "\\"
        return processes.filter { $0.windowsPath.lowercased().hasPrefix(prefix) }
    }

    /// `argv[0]`: KERN_PROCARGS2 is argc, the executable path, padding, then
    /// argv[0]. Parsing stops there.
    static func argv0(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }  // the executable path
        while i < size, buffer[i] == 0 { i += 1 }  // padding
        let start = i
        while i < size, buffer[i] != 0 { i += 1 }
        guard i > start else { return nil }
        return String(decoding: buffer[start..<i], as: UTF8.self)
    }
}
