import Foundation

/// What a prefix holds at one moment: its registry keys, URL protocols and the
/// files under `drive_c` (except `windows/`, temporary folders and Riftway's own
/// copies of installers). Taken right after a bottle is created, it is the
/// baseline every discovery compares against, so programs a launcher installs
/// later (DSR downloads its client, Steam its games) are found too.
public struct PrefixSnapshot: Codable, Sendable, Equatable {
    public struct FileStamp: Codable, Sendable, Equatable {
        public var size: Int64
        public var modified: TimeInterval
    }

    public var taken: Date
    /// `hklm\…` and `hkcu\…`, lowercased.
    public var registryKeys: Set<String>
    public var protocols: Set<String>
    /// Path relative to `drive_c`, with `/` separators.
    public var files: [String: FileStamp]

    public init(taken: Date = Date(), registryKeys: Set<String> = [], protocols: Set<String> = [], files: [String: FileStamp] = [:]) {
        self.taken = taken
        self.registryKeys = registryKeys
        self.protocols = protocols
        self.files = files
    }

    /// Folders under `drive_c` that never hold a game's own files.
    static func isSkipped(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        if lower == "windows" || lower.hasPrefix("windows/") { return true }
        if lower.hasPrefix("programdata/riftway") { return true }
        let parts = lower.split(separator: "/")
        // users/<name>/AppData/Local/Temp and users/<name>/Temp
        if parts.count >= 3, parts[0] == "users" {
            if parts[2] == "temp" { return true }
            if parts.count >= 5, parts[2] == "appdata", parts[3] == "local", parts[4] == "temp" { return true }
        }
        return false
    }

    public static func capture(prefix: URL) -> PrefixSnapshot {
        let system = try? WineRegistry(contentsOf: prefix.appendingPathComponent("system.reg"))
        let user = try? WineRegistry(contentsOf: prefix.appendingPathComponent("user.reg"))
        var keys = Set<String>()
        for key in system?.keyPaths ?? [] { keys.insert("hklm\\" + key) }
        for key in user?.keyPaths ?? [] { keys.insert("hkcu\\" + key) }
        let protocols = Set(URLProtocolRegistration.discover(system: system, user: user).map(\.scheme))
        return PrefixSnapshot(registryKeys: keys, protocols: protocols, files: files(in: prefix.appendingPathComponent("drive_c")))
    }

    static func files(in driveC: URL) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let base = driveC.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: driveC.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true })
        else { return result }
        for case let url as URL in walker {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if isSkipped(relative) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, !isSkipped(relative) else { continue }
            result[relative] = FileStamp(size: Int64(values?.fileSize ?? 0),
                                         modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return result
    }

    /// Files that are new or changed since `baseline`.
    public func changedFiles(since baseline: PrefixSnapshot) -> [String] {
        files.compactMap { path, stamp in baseline.files[path] == stamp ? nil : path }.sorted()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> PrefixSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PrefixSnapshot.self, from: Data(contentsOf: url))
    }
}
