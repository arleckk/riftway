import Foundation

/// A program an installer left a shortcut to.
public struct DiscoveredProgram: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Target: Codable, Sendable, Equatable, Hashable {
        /// A Windows program in the bottle and its command line.
        case executable(path: String, arguments: String?)
        /// An Internet shortcut (`.url`): the program is a web page. DSR's shortcut
        /// opens its site, whose Start button launches the game through `dsropen`.
        case web(url: String)
    }

    public var name: String
    public var target: Target
    public var workingDirectory: String?
    /// Windows path of the icon (`.ico` or a program) and its index.
    public var iconLocation: String?
    public var iconIndex: Int32
    /// The `.lnk`, relative to `drive_c`; empty for programs found without one.
    public var shortcut: String

    public init(name: String, target: Target, workingDirectory: String? = nil, iconLocation: String? = nil,
                iconIndex: Int32 = 0, shortcut: String = "") {
        self.name = name
        self.target = target
        self.workingDirectory = workingDirectory
        self.iconLocation = iconLocation
        self.iconIndex = iconIndex
        self.shortcut = shortcut
    }

    /// A program found by its path (a new `.exe`), named after its file.
    public static func executable(_ windowsPath: String) -> DiscoveredProgram {
        let file = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? windowsPath
        let name = file.lowercased().hasSuffix(".exe") ? String(file.dropLast(4)) : file
        return DiscoveredProgram(name: name, target: .executable(path: windowsPath, arguments: nil), iconLocation: windowsPath)
    }

    public var id: String {
        switch target {
        case .executable(let path, let arguments): "exe:" + path.lowercased() + " " + (arguments ?? "")
        case .web(let url): "web:" + url
        }
    }

    /// The program's Windows path, for executables.
    public var windowsPath: String? {
        if case .executable(let path, _) = target { return path }
        return nil
    }
}

public struct UninstallEntry: Codable, Sendable, Equatable {
    public var key: String
    public var displayName: String?
    public var publisher: String?
    public var displayVersion: String?
    public var displayIcon: String?
    public var uninstallString: String?
    public var installLocation: String?
}

public struct DriverEntry: Codable, Sendable, Equatable {
    /// The service's key name, or the `.sys` file for drivers found only on disk.
    public var name: String
    public var imagePath: String?
    /// 1 = kernel driver, 2 = file system driver.
    public var type: UInt32?
}

/// What a bottle gained since its baseline (PRD-01 §5).
public struct InstallResult: Codable, Sendable, Equatable {
    public var programs: [DiscoveredProgram] = []
    public var primary: DiscoveredProgram?
    public var uninstall: [UninstallEntry] = []
    public var protocols: [URLProtocolRegistration] = []
    /// New file extensions registered in HKCR (`.ext`).
    public var associations: [String] = []
    public var drivers: [DriverEntry] = []
    /// New `.exe` files, largest first (Windows paths).
    public var executables: [String] = []
    /// Anti-cheats among the new files and drivers.
    public var anticheat: [AntiCheatFinding] = []
    public var changedFiles = 0

    public init() {}

    /// The installer left nothing a player could start.
    public var isEmpty: Bool { programs.isEmpty && protocols.isEmpty && executables.isEmpty }
}

public enum InstallDiscovery {
    /// Compares a prefix with its baseline. `product` (the installer's product
    /// name) helps choose the primary program.
    public static func discover(prefix: URL, baseline: PrefixSnapshot, product: String? = nil) -> InstallResult {
        let now = PrefixSnapshot.capture(prefix: prefix)
        let system = try? WineRegistry(contentsOf: prefix.appendingPathComponent("system.reg"))
        let user = try? WineRegistry(contentsOf: prefix.appendingPathComponent("user.reg"))
        let driveC = prefix.appendingPathComponent("drive_c")
        let changed = now.changedFiles(since: baseline)

        var result = InstallResult()
        result.changedFiles = changed.count
        result.programs = programs(changed: changed, driveC: driveC)
        result.uninstall = uninstallEntries(system: system, user: user, baseline: baseline)
        result.protocols = URLProtocolRegistration.discover(system: system, user: user)
            .filter { $0.isClaimableFromMacOS && !baseline.protocols.contains($0.scheme) }
        result.associations = associations(system: system, user: user, baseline: baseline)
        result.drivers = drivers(system: system, baseline: baseline, changed: changed)
        result.executables = changed
            .filter { $0.lowercased().hasSuffix(".exe") && !isUninstaller($0) && !isHelper($0) && !isWineFolder($0) }
            .sorted { (now.files[$0]?.size ?? 0) > (now.files[$1]?.size ?? 0) }
            .prefix(20)
            .map(windowsPath)
        result.primary = primary(result.programs, product: product, executables: result.executables, files: now.files)
        result.anticheat = AntiCheatDetector.scan(files: changed, drivers: result.drivers)
        return result
    }

    /// `C:\` + the path relative to `drive_c`.
    static func windowsPath(_ relative: String) -> String {
        "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    static let shortcutFolders = ["programdata/microsoft/windows/start menu/", "users/public/desktop/"]

    static func isShortcutLocation(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        guard lower.hasSuffix(".lnk") else { return false }
        if shortcutFolders.contains(where: lower.hasPrefix) { return true }
        // users/<name>/Desktop/… and users/<name>/AppData/Roaming/Microsoft/Windows/Start Menu/…
        let parts = lower.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "users" else { return false }
        return parts[2].hasPrefix("desktop/") || parts[2].hasPrefix("appdata/roaming/microsoft/windows/start menu/")
    }

    static let excludedNames = ["uninst", "unins0", "uninstall", "setup", "readme", "license", "eula", "manual", "help",
                                "website", "homepage", "support", "vcredist", "dxsetup", "directx"]

    /// Folders Wine itself fills (and refreshes when the runtime changes).
    static let wineFolders = ["windows nt/", "internet explorer/", "windows media player/", "common files/"]

    static func isWineFolder(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        return ["program files/", "program files (x86)/"].contains { root in
            wineFolders.contains { lower.hasPrefix(root + $0) }
        }
    }

    /// Prerequisite installers and crash reporters that ship beside games.
    static func isHelper(_ path: String) -> Bool {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { $0.lowercased() } ?? ""
        return ["setup", "redist", "prereq", "crashreport", "crashpad", "dxwebsetup", "vc_redist", "dotnet"].contains { name.contains($0) }
    }

    static func isUninstaller(_ path: String) -> Bool {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { $0.lowercased() } ?? ""
        return name.hasPrefix("unins") || name.hasPrefix("uninst") || name.contains("uninstall")
    }

    static func programs(changed: [String], driveC: URL) -> [DiscoveredProgram] {
        var seen = Set<String>()
        var found: [DiscoveredProgram] = []
        // Desktop shortcuts first: they are the ones an installer offers to create
        // for the program a player starts.
        let shortcuts = changed.filter(isShortcutLocation).sorted { a, b in
            let da = a.lowercased().contains("/desktop/"), db = b.lowercased().contains("/desktop/")
            return da != db ? da : a < b
        }
        for relative in shortcuts {
            guard let link = try? ShellLink(contentsOf: driveC.appendingPathComponent(relative)), let target = link.target else { continue }
            let name = String((relative.split(separator: "/").last ?? "").dropLast(4))
            let lowerTarget = target.lowercased()
            let program: DiscoveredProgram.Target
            if lowerTarget.hasSuffix(".exe") {
                guard !isUninstaller(target), !excludedNames.contains(where: { name.lowercased().hasPrefix($0) }) else { continue }
                program = .executable(path: expand(target, driveC: driveC), arguments: link.arguments)
            } else if lowerTarget.hasSuffix(".url"), let url = internetShortcutURL(expand(target, driveC: driveC), driveC: driveC) {
                program = .web(url: url)
            } else {
                continue  // documents, folders, batch files
            }
            let entry = DiscoveredProgram(name: name, target: program, workingDirectory: link.workingDirectory,
                                          iconLocation: link.iconLocation, iconIndex: link.iconIndex, shortcut: relative)
            if seen.insert(entry.id).inserted { found.append(entry) }
        }
        return found
    }

    /// Expands the variables shortcuts use (`%ProgramFiles%`, `%APPDATA%`…).
    static func expand(_ path: String, driveC: URL) -> String {
        guard path.contains("%") else { return path }
        let user = (try? FileManager.default.contentsOfDirectory(atPath: driveC.appendingPathComponent("users").path))?
            .first { $0 != "Public" && !$0.hasPrefix(".") } ?? "Public"
        let home = #"C:\users\"# + user
        let variables = [
            "%programfiles%": #"C:\Program Files"#, "%programfiles(x86)%": #"C:\Program Files (x86)"#,
            "%programw6432%": #"C:\Program Files"#, "%systemroot%": #"C:\windows"#, "%windir%": #"C:\windows"#,
            "%systemdrive%": "C:", "%programdata%": #"C:\ProgramData"#, "%allusersprofile%": #"C:\ProgramData"#,
            "%userprofile%": home, "%appdata%": home + #"\AppData\Roaming"#, "%localappdata%": home + #"\AppData\Local"#,
            "%public%": #"C:\users\Public"#,
        ]
        var result = path
        for (name, value) in variables {
            if let range = result.range(of: name, options: .caseInsensitive) { result.replaceSubrange(range, with: value) }
        }
        return result
    }

    /// The `URL=` line of an Internet shortcut, when it is http or https.
    static func internetShortcutURL(_ windowsPath: String, driveC: URL) -> String? {
        guard windowsPath.count > 3, windowsPath.lowercased().hasPrefix("c:\\") else { return nil }
        let relative = windowsPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        guard !relative.split(separator: "/").contains(".."),
              let data = try? Data(contentsOf: driveC.appendingPathComponent(relative)), data.count < 64 * 1024
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("url=") {
            let url = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let lower = url.lowercased()
            if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return url }
        }
        return nil
    }

    static let uninstallRoots = [
        #"Software\Microsoft\Windows\CurrentVersion\Uninstall"#,
        #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#,
    ]

    static func uninstallEntries(system: WineRegistry?, user: WineRegistry?, baseline: PrefixSnapshot) -> [UninstallEntry] {
        var entries: [UninstallEntry] = []
        for (registry, hive) in [(system, "hklm"), (user, "hkcu")] {
            guard let registry else { continue }
            for root in uninstallRoots {
                for name in registry.subkeys(of: root) {
                    let key = root + "\\" + name
                    guard !baseline.registryKeys.contains(hive + "\\" + key.lowercased()) else { continue }
                    let entry = UninstallEntry(key: name, displayName: registry.value("DisplayName", at: key),
                                               publisher: registry.value("Publisher", at: key),
                                               displayVersion: registry.value("DisplayVersion", at: key),
                                               displayIcon: registry.value("DisplayIcon", at: key),
                                               uninstallString: registry.value("UninstallString", at: key),
                                               installLocation: registry.value("InstallLocation", at: key))
                    if entry.displayName != nil || entry.uninstallString != nil { entries.append(entry) }
                }
            }
        }
        return entries
    }

    static func associations(system: WineRegistry?, user: WineRegistry?, baseline: PrefixSnapshot) -> [String] {
        var found = Set<String>()
        for (registry, hive) in [(system, "hklm"), (user, "hkcu")] {
            guard let registry else { continue }
            for name in registry.subkeys(of: #"Software\Classes"#) where name.hasPrefix(".") {
                if !baseline.registryKeys.contains(hive + #"\software\classes\"# + name) { found.insert(name) }
            }
        }
        return found.sorted()
    }

    static func drivers(system: WineRegistry?, baseline: PrefixSnapshot, changed: [String]) -> [DriverEntry] {
        var found: [DriverEntry] = []
        let services = #"System\CurrentControlSet\Services"#
        if let system {
            for name in system.subkeys(of: services) {
                let key = services + "\\" + name
                guard !baseline.registryKeys.contains("hklm\\" + key.lowercased()),
                      let type = system.dword("Type", at: key), type == 1 || type == 2
                else { continue }
                found.append(DriverEntry(name: name, imagePath: system.value("ImagePath", at: key), type: type))
            }
        }
        let listed = Set(found.compactMap { $0.imagePath?.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last?.lowercased() })
        for file in changed where file.lowercased().hasSuffix(".sys") {
            let name = String(file.split(separator: "/").last ?? "")
            if !listed.contains(name.lowercased()) { found.append(DriverEntry(name: name, imagePath: windowsPath(file), type: nil)) }
        }
        return found
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// The program the Play button starts: the shortcut named like the product,
    /// then one whose name contains it, then the first desktop shortcut, then
    /// the first shortcut to a program, then the largest new program.
    static func primary(_ programs: [DiscoveredProgram], product: String?, executables: [String],
                        files: [String: PrefixSnapshot.FileStamp]) -> DiscoveredProgram? {
        if let product, !normalized(product).isEmpty {
            let wanted = normalized(product)
            if let exact = programs.first(where: { normalized($0.name) == wanted }) { return exact }
            if let close = programs.first(where: { normalized($0.name).contains(wanted) || wanted.contains(normalized($0.name)) }) {
                return close
            }
        }
        if let desktop = programs.first(where: { $0.shortcut.lowercased().contains("/desktop/") }) { return desktop }
        if let first = programs.first { return first }
        return executables.first.map(DiscoveredProgram.executable)
    }
}
