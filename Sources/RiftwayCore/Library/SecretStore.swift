import Foundation

/// Secrets a game's Play button needs (a launch link with a session token and
/// an e-mail address), one file per game in `<Riftway home>/Secrets/`: readable
/// by this user only, excluded from backups and outside every bottle, so no
/// Windows program can reach them (bottles have no `Z:` drive). They never go
/// to `game.json` or to logs.
///
/// Not the Keychain: the bridge saves the link and Riftway reads it, and
/// builds without a Developer ID have a different code identity per program
/// and per build, so the Keychain would ask for the password on every access.
/// With a Developer ID, a shared access group can hold them instead.
public struct SecretStore: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public init(home: RiftwayHome) { directory = home.root.appendingPathComponent("Secrets", isDirectory: true) }

    /// `game:digimon-super-rumble` → `Secrets/game-digimon-super-rumble.link`.
    public func file(for account: String) -> URL {
        let safe = String(account.lowercased().unicodeScalars.map {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" ? Character($0) : "-"
        })
        return directory.appendingPathComponent(safe + ".link")
    }

    public func save(_ value: String, account: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(excluded)
        // Created 0600 before any byte is written, then moved into place.
        let target = file(for: account)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            try handle.write(contentsOf: Data(value.utf8))
            try handle.close()
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    public func read(account: String) throws -> String? {
        let url = file(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// When the secret was last saved, without reading it.
    public func savedDate(account: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: account).path))?[.modificationDate] as? Date
    }

    public func delete(account: String) throws {
        let url = file(for: account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
