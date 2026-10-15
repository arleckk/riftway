import Foundation

/// Where bottles live (PRD-02 R2.3): `Bottles/` in Riftway's home, and the
/// folders the player added, each a `Riftway` folder (with a `.riftway-bottles`
/// marker) on a disk that follows Recall's rules. `locations.json` in the home
/// lists them, which one new games go to, and the games last seen in each, so
/// a disconnected disk still says what it holds.
public struct BottleLocations: Codable, Sendable, Equatable {
    public struct Folder: Codable, Sendable, Equatable {
        /// The `Riftway` folder that holds the bottles.
        public var path: String
        /// Bottle id → game name, as last seen.
        public var games: [String: String]

        public init(path: String, games: [String: String] = [:]) {
            self.path = path
            self.games = games
        }

        public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    public var folders: [Folder] = []
    /// Where new bottles go; nil: the home's `Bottles`.
    public var install: String?

    public init(folders: [Folder] = [], install: String? = nil) {
        self.folders = folders
        self.install = install
    }

    public static let file = "locations.json"
    /// The folder Riftway makes inside the one the player chooses.
    public static let folderName = "Riftway"
    static let marker = ".riftway-bottles"

    /// Picking a folder Riftway made reconnects it; any other folder gets a
    /// `Riftway` folder inside it.
    public static func root(forChosen folder: URL) -> URL {
        let folder = folder.standardizedFileURL
        return folder.lastPathComponent == folderName || FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path)
            ? folder : folder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// False while the disk holding the folder is disconnected. Riftway never
    /// creates the folder's parent, so an unplugged disk can't become a stray
    /// folder; an unclean eject can leave an empty `/Volumes/<name>` behind.
    public static func isAvailable(_ root: URL) -> Bool {
        var directory: ObjCBool = false
        let parent = root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { return false }
        let parts = root.standardizedFileURL.pathComponents
        guard parts.count > 3, parts[1] == "Volumes" else { return true }
        let volume = (try? parent.resourceValues(forKeys: [.volumeURLKey]).volume)?.standardizedFileURL.path
        return volume == NSString.path(withComponents: Array(parts[0...2]))
    }

    /// The disk's name: "PortableSSD", also while it is disconnected.
    public static func driveName(_ root: URL) -> String {
        if isAvailable(root), let name = try? existing(root).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName {
            return name
        }
        let parts = root.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : "Macintosh HD"
    }

    /// A short name: the disk, and the chosen folder when it is not the disk itself
    /// ("PortableSSD › Games").
    public static func title(_ root: URL) -> String {
        let drive = driveName(root)
        let folder = root.lastPathComponent == folderName ? root.deletingLastPathComponent() : root
        let parts = folder.standardizedFileURL.pathComponents
        if parts.count == 3, parts[1] == "Volumes" { return drive }
        return "\(drive) › \(folder.lastPathComponent)"
    }

    /// Whether two folders are on the same disk, where moving a bottle is a rename.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let x = try? existing(a).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let y = try? existing(b).resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// Why a folder can't hold bottles.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable
        case network
        case readOnly(drive: String)
        /// exFAT, FAT, NTFS: `format` is macOS's name for it.
        case format(drive: String, format: String)
        case caseSensitive(drive: String)
        case cloud
        case notEmpty

        public var description: String {
            switch self {
            case .unreadable: "That folder can't be read"
            case .network: "Network drives aren't supported; choose a drive connected to this Mac"
            case .readOnly(let drive): "\(drive) is read-only"
            case .format(let drive, let format):
                "\(drive) is formatted as \(format); choose a drive formatted as APFS or Mac OS Extended (reformatting erases it)"
            case .caseSensitive(let drive): "\(drive) is case-sensitive, which Windows games don't support"
            case .cloud: "Folders synced to iCloud Drive or other cloud storage aren't supported"
            case .notEmpty: "That Riftway folder already holds other files"
            }
        }
    }

    /// Why `root` (a `Riftway` folder, made or to make) can't hold bottles, or
    /// nil. The same rules as Recall: APFS or Mac OS Extended, not
    /// case-sensitive, local, writable and not synced to the cloud.
    public static func problem(for root: URL) -> Problem? {
        let folder = root.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [.volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeTypeNameKey, .volumeLocalizedFormatDescriptionKey,
                                         .volumeSupportsCaseSensitiveNamesKey, .volumeLocalizedNameKey, .isUbiquitousItemKey]
        guard let values = try? folder.resourceValues(forKeys: keys) else { return .unreadable }
        let drive = values.volumeLocalizedName ?? "This drive"
        if values.volumeIsLocal == false { return .network }
        if values.volumeIsReadOnly == true { return .readOnly(drive: drive) }
        if !["apfs", "hfs"].contains((values.volumeTypeName ?? "").lowercased()) {
            return .format(drive: drive, format: values.volumeLocalizedFormatDescription ?? values.volumeTypeName ?? "?")
        }
        if values.volumeSupportsCaseSensitiveNames == true { return .caseSensitive(drive: drive) }
        let path = folder.path
        if values.isUbiquitousItem == true || path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/") {
            return .cloud
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), !fm.fileExists(atPath: root.appendingPathComponent(marker).path),
           (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == false {
            return .notEmpty
        }
        return nil
    }

    /// Makes the `Riftway` folder and its marker; its parent must exist.
    public static func prepare(_ root: URL) throws {
        let fm = FileManager.default
        guard isAvailable(root) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.deletingLastPathComponent().path]) }
        if !fm.fileExists(atPath: root.path) { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
        let marker = root.appendingPathComponent(marker)
        if !fm.fileExists(atPath: marker.path) {
            try Data("Bottles of Riftway: each folder is a game with its Windows environment.\n".utf8).write(to: marker)
        }
    }

    static func existing(_ root: URL) -> URL {
        FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
    }
}
