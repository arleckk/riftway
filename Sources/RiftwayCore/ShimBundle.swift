import Foundation

/// What a game's shim app does, stored in its `Contents/Resources/shim.json`.
public struct ShimConfig: Codable, Sendable, Equatable {
    public var displayName: String
    public var bundleIdentifier: String
    public var bottle: Bottle
    /// The URL schemes the shim claims from macOS, lowercased.
    public var schemes: [String]
    public var extraArguments: [String]
    public var environment: [String: String]
    /// Log the launch it would make instead of starting Wine.
    public var dryRun: Bool
    /// Keep Wine's output (errors only unless the environment sets WINEDEBUG) in
    /// `<bottle>/logs/session-<time>.log`, for diagnosing a game.
    public var wineLog: Bool = false
    /// The Windows command line a double-click on the bridge starts (program
    /// first). Without one, the program of the first scheme starts.
    public var program: [String]?
    /// A web page a double-click opens in the Mac's browser instead (games
    /// started from their site, which then calls the bridge's scheme).
    public var webPage: String?
    /// Where the bridge remembers the last link it received (`SecretStore`),
    /// for a game whose Play button reuses it.
    public var rememberLinkAccount: String?
    public var secretsDirectory: String?

    public init(displayName: String, bottle: Bottle, schemes: [String], extraArguments: [String] = [],
                environment: [String: String] = [:], dryRun: Bool = false) {
        self.displayName = displayName
        self.bundleIdentifier = "com.riftway.shim." + ShimBundle.slug(displayName)
        self.bottle = bottle
        self.schemes = schemes.map { $0.lowercased() }
        self.extraArguments = extraArguments
        self.environment = environment
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey { case displayName, bundleIdentifier, bottle, schemes, extraArguments, environment, dryRun, wineLog, program, webPage, rememberLinkAccount, secretsDirectory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        bottle = try c.decode(Bottle.self, forKey: .bottle)
        schemes = try c.decode([String].self, forKey: .schemes)
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        wineLog = try c.decodeIfPresent(Bool.self, forKey: .wineLog) ?? false
        program = try c.decodeIfPresent([String].self, forKey: .program)
        webPage = try c.decodeIfPresent(String.self, forKey: .webPage)
        rememberLinkAccount = try c.decodeIfPresent(String.self, forKey: .rememberLinkAccount)
        secretsDirectory = try c.decodeIfPresent(String.self, forKey: .secretsDirectory)
    }

    /// `webPage` when it is an http or https address.
    public var webPageURL: URL? {
        guard let webPage, let url = URL(string: webPage), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Where a session's Wine output goes when `wineLog` is on.
    public func sessionLog(at date: Date = Date()) -> URL? {
        var diagnostics = false
        if case .riftway(_, let options) = bottle.backend { diagnostics = options.diagnostics }
        guard wineLog || diagnostics else { return nil }
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let root = bottle.prefixURL.deletingLastPathComponent()
        return root.appendingPathComponent("logs/session-\(stamp).log")
    }

    public var bridge: URLBridge {
        URLBridge(bottle: bottle, schemes: Set(schemes), extraArguments: extraArguments, environment: environment, program: program)
    }
}

/// Builds the small per-game app that macOS knows as the owner of the game's
/// URL schemes (`CFBundleURLTypes` must be in an app's Info.plist, so one
/// signed host app cannot claim schemes discovered after it shipped). The shim
/// doubles as the game's icon in Launchpad and the Dock: opened without a URL,
/// it starts the program the scheme points to.
public enum ShimBundle {
    public static let executableName = "riftway-shim"
    public static let configName = "shim.json"

    public enum Failure: Error, CustomStringConvertible {
        case tool(String, Int32, String)
        public var description: String {
            switch self { case .tool(let name, let code, let out): "\(name) failed (\(code)): \(out)" }
        }
    }

    public static func slug(_ name: String) -> String {
        let allowed = name.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    public static func infoPlist(for config: ShimConfig, hasIcon: Bool) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": config.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": config.displayName,
            "CFBundleDisplayName": config.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            // No Dock tile of its own: the shim hands off to Wine and quits.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
        ]
        if !config.schemes.isEmpty {
            plist["CFBundleURLTypes"] = [[
                "CFBundleURLName": config.bundleIdentifier + ".url",
                "CFBundleURLSchemes": config.schemes,
                "CFBundleTypeRole": "Viewer",
            ]]
        }
        if hasIcon { plist["CFBundleIconFile"] = "AppIcon" }
        return plist
    }

    /// Writes `<directory>/<displayName>.app`, replacing an earlier shim there,
    /// and signs it ad hoc. Returns the bundle's URL.
    public static func build(config: ShimConfig, shimBinary: URL, icon: URL?, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let app = directory.appendingPathComponent(config.displayName + ".app", isDirectory: true)
        let staging = directory.appendingPathComponent(".\(slug(config.displayName))-\(UUID().uuidString).app", isDirectory: true)
        let stagingContents = staging.appendingPathComponent("Contents", isDirectory: true)

        try fm.createDirectory(at: stagingContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingContents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: shimBinary, to: stagingContents.appendingPathComponent("MacOS/" + executableName))
            let hasIcon = icon.map { (try? installIcon($0, into: stagingContents.appendingPathComponent("Resources"))) != nil } ?? false
            let plist = try PropertyListSerialization.data(fromPropertyList: infoPlist(for: config, hasIcon: hasIcon), format: .xml, options: 0)
            try plist.write(to: stagingContents.appendingPathComponent("Info.plist"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: stagingContents.appendingPathComponent("Resources/" + configName))
            try sign(staging)
            if fm.fileExists(atPath: app.path) {
                _ = try fm.replaceItemAt(app, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: app)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return app
    }

    /// `.icns` is copied; `.ico` and images are converted with `sips`.
    static func installIcon(_ icon: URL, into resources: URL) throws {
        let target = resources.appendingPathComponent("AppIcon.icns")
        if icon.pathExtension.lowercased() == "icns" {
            try FileManager.default.copyItem(at: icon, to: target)
        } else {
            try run("/usr/bin/sips", ["-s", "format", "icns", icon.path, "--out", target.path])
        }
    }

    /// Ad hoc signature: enough for Apple Silicon to run a bundle made on this Mac
    /// (it carries no quarantine flag, so Gatekeeper does not assess it).
    public static func sign(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static func register(_ app: URL) throws { try run(lsregister, ["-f", app.path]) }

    public static func unregister(_ app: URL) throws { try run(lsregister, ["-u", app.path]) }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.tool(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
