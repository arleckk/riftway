import CryptoKit
import Foundation

/// The app bundle a game's programs start from so macOS turns Game Mode on for
/// them (docs/RUNTIME-BUILD.md, step 8).
///
/// macOS turns Game Mode on only for a process whose executable is the main
/// executable of an app bundle that declares itself a game, and every Wine
/// process runs Wine's bare loader. The bundle is a copy of the runtime's
/// loader with the loader's embedded Info.plist plus the game category and
/// Game Mode keys. The runtime's ntdll execs the programs in `WINE_GAME_MODE`
/// from the executable `WINE_GAME_MODE_APP` names (`runtime/patches/
/// wine-game-mode-app.patch`); the copy finds ntdll.so through `argv[0]`, the
/// usual loader's path.
///
/// Each game gets its own, in its bottle (`GameMode/Game.app`), because the
/// runtime is verified and never changes: the game's name and icon in the Dock,
/// and its own identity for the Local Network and microphone permissions. The
/// copy differs from the loader in its `LC_UUID` too, since Local Network
/// privacy keys apps by their main executable's UUID. It is signed ad hoc with
/// the loader's entitlements and the hardened runtime.
///
/// Derived from Recall's `scripts/game_mode_app.py` (Apache 2.0,
/// github.com/AsherJN/recall), which makes one bundle inside the runtime.
public enum GameModeApp {
    public static let loaderPath = "lib/wine/x86_64-unix/wine"
    /// Records which loader the copy came from, to make it again for another runtime.
    static let loaderKey = "RiftwayLoaderSHA256"

    public static func bundle(bottleRoot: URL) -> URL {
        bottleRoot.appendingPathComponent("GameMode/Game.app", isDirectory: true)
    }

    public static func executable(bottleRoot: URL) -> URL {
        bundle(bottleRoot: bottleRoot).appendingPathComponent("Contents/MacOS/wine")
    }

    public enum Failure: Error, CustomStringConvertible {
        case notMachO, noEmbeddedInfo, noUUID
        case codesign(String)

        public var description: String {
            switch self {
            case .notMachO: "The runtime's loader is not a 64-bit Mach-O file"
            case .noEmbeddedInfo: "The runtime's loader has no embedded Info.plist"
            case .noUUID: "The runtime's loader has no LC_UUID"
            case .codesign(let output): "codesign failed: \(output)"
            }
        }
    }

    /// `com.riftway.game.<bottle>`: a bottle's folder name is its library id.
    public static func identifier(bottleRoot: URL) -> String {
        let id = bottleRoot.lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()
        return "com.riftway.game." + (id.isEmpty ? "game" : id)
    }

    /// Whether the bottle's bundle was made from this runtime's loader.
    public static func isCurrent(bottleRoot: URL, runtime: WineRuntime) -> Bool {
        let plist = bundle(bottleRoot: bottleRoot).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let recorded = info[loaderKey] as? String,
              let loader = try? Data(contentsOf: URL(fileURLWithPath: runtime.root).appendingPathComponent(loaderPath))
        else { return false }
        return recorded == sha256(loader) && FileManager.default.isExecutableFile(atPath: executable(bottleRoot: bottleRoot).path)
    }

    /// Makes (or makes again) the bottle's bundle from the runtime's loader.
    /// `icon` is an `.icns` file, such as the game's bridge icon.
    public static func make(bottleRoot: URL, runtime: WineRuntime, name: String, icon: URL? = nil) throws {
        let fm = FileManager.default
        let loader = URL(fileURLWithPath: runtime.root).appendingPathComponent(loaderPath)
        let data = try Data(contentsOf: loader)
        let identifier = identifier(bottleRoot: bottleRoot)

        var info = try embeddedInfo(data)
        info.merge(gameKeys(name: name)) { $1 }
        info["CFBundleIdentifier"] = identifier
        info["LSMinimumSystemVersion"] = "26.0"
        info[loaderKey] = sha256(data)
        if icon != nil { info["CFBundleIconFile"] = "AppIcon" }

        var copy = data
        let at = try uuidOffset(data)
        copy.replaceSubrange(at..<(at + 16), with: uuid5(namespace: data.subdata(in: at..<(at + 16)), name: identifier))

        // Built aside and swapped in, so a bottle never has half a bundle.
        let target = bundle(bottleRoot: bottleRoot)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".Game-\(UUID().uuidString).app")
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("Contents/Info.plist"))
        let executable = staging.appendingPathComponent("Contents/MacOS/wine")
        try copy.write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if let icon {
            try fm.createDirectory(at: staging.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: icon, to: staging.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        }

        let entitlements = staging.deletingLastPathComponent().appendingPathComponent(".entitlements-\(UUID().uuidString).plist")
        defer { try? fm.removeItem(at: entitlements) }
        var sign = ["--force", "--options", "runtime", "--sign", "-"]
        if let xml = try codesign(["-d", "--xml", "--entitlements", "-", loader.path]), !xml.isEmpty {
            try xml.write(to: entitlements)
            sign += ["--entitlements", entitlements.path]
        }
        _ = try codesign(sign + [staging.path])
        _ = try codesign(["--verify", "--strict", staging.path])

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
    }

    /// The bundle for a game whose options list Game Mode programs: made when
    /// missing, from another runtime or for another name, and left alone
    /// otherwise (an ad hoc signature changes with every build, and macOS
    /// would ask for the game's permissions again). Removed when no program
    /// uses Game Mode.
    public static func ensure(bottleRoot: URL, runtime: WineRuntime, options: GameOptions, name: String, icon: URL? = nil) throws {
        guard !options.gameMode.isEmpty else { return remove(bottleRoot: bottleRoot) }
        let plist = bundle(bottleRoot: bottleRoot).appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        if isCurrent(bottleRoot: bottleRoot, runtime: runtime), info?["CFBundleName"] as? String == name { return }
        try make(bottleRoot: bottleRoot, runtime: runtime, name: name, icon: icon)
    }

    public static func remove(bottleRoot: URL) {
        try? FileManager.default.removeItem(at: bundle(bottleRoot: bottleRoot).deletingLastPathComponent())
    }

    static func gameKeys(name: String) -> [String: Any] {
        [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "wine",
            "CFBundlePackageType": "APPL",
            "LSApplicationCategoryType": "public.app-category.games",
            "LSSupportsGameMode": true,
            "GCSupportsGameMode": true,  // the key's name on macOS 14 and 15
            // The game is its own app to macOS, so its permission prompts name it.
            "NSLocalNetworkUsageDescription": "\(name) busca otros dispositivos en tu red local.",
            "NSMicrophoneUsageDescription": "\(name) usa el micrófono para el chat de voz.",
        ]
    }

    // MARK: Mach-O

    private static let segment64: UInt32 = 0x19, uuidCommand: UInt32 = 0x1b

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private static func u64(_ data: Data, _ at: Int) -> UInt64 {
        data.subdata(in: at..<(at + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    private static func name(_ data: Data, _ at: Int) -> String {
        String(decoding: data.subdata(in: at..<(at + 16)).prefix { $0 != 0 }, as: UTF8.self)
    }

    /// (command, offset) of each load command of a 64-bit little-endian Mach-O file.
    static func loadCommands(_ data: Data) throws -> [(UInt32, Int)] {
        guard data.count > 32, u32(data, 0) == 0xfeedfacf else { throw Failure.notMachO }
        var commands: [(UInt32, Int)] = []
        var offset = 32
        for _ in 0..<u32(data, 16) {
            guard offset + 8 <= data.count else { throw Failure.notMachO }
            commands.append((u32(data, offset), offset))
            offset += Int(u32(data, offset + 4))
        }
        return commands
    }

    /// The Info.plist in the `__TEXT,__info_plist` section.
    static func embeddedInfo(_ data: Data) throws -> [String: Any] {
        for (command, offset) in try loadCommands(data) where command == segment64 && name(data, offset + 8) == "__TEXT" {
            for i in 0..<Int(u32(data, offset + 64)) {
                let section = offset + 72 + 80 * i
                guard name(data, section) == "__info_plist" else { continue }
                let size = Int(u64(data, section + 40)), start = Int(u32(data, section + 48))
                let bytes = data.subdata(in: start..<(start + size)).prefix { $0 != 0 }
                guard let info = try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any]
                else { throw Failure.noEmbeddedInfo }
                return info
            }
        }
        throw Failure.noEmbeddedInfo
    }

    static func uuidOffset(_ data: Data) throws -> Int {
        guard let (_, offset) = try loadCommands(data).first(where: { $0.0 == uuidCommand }) else { throw Failure.noUUID }
        return offset + 8
    }

    /// RFC 4122 version 5 (SHA-1, name-based) UUID bytes, as Python's `uuid.uuid5`.
    static func uuid5(namespace: Data, name: String) -> Data {
        var bytes = Array(Insecure.SHA1.hash(data: namespace + Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return Data(bytes)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func codesign(_ arguments: [String]) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.codesign(String(decoding: errors, as: UTF8.self)) }
        return output
    }
}
