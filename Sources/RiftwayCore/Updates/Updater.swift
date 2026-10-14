import CryptoKit
import Foundation
import Security

/// Checks the release feed and installs what it offers (PRD-06 R5, R6):
/// runtimes and profiles in `<home>`, and the app by swapping its bundle once
/// it quits. Every download is checked against the signed feed's size and
/// SHA-256 before anything is touched; a failure at any step changes nothing.
public struct Updater: Sendable {
    public var home: RiftwayHome
    public var feedURL: URL
    public var trustedKeys: [String]

    public init(home: RiftwayHome = .standard, feedURL: URL, trustedKeys: [String] = ReleaseKeys.trusted) {
        self.home = home
        self.feedURL = feedURL
        self.trustedKeys = trustedKeys
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case insecureAddress(String)
        case download(String, status: Int)
        case size(expected: Int64, got: Int64)
        case hash(expected: String, got: String)
        case notARuntime(String)
        case runtimeExists(String)
        case notTheApp(String)
        case badSignature(String)
        case otherDeveloper(expected: String?, got: String?)
        case notNewer(String)
        case cannotSwap(Int32)
        case requiresMacOS(String)

        public var description: String {
            switch self {
            case .insecureAddress(let url): "Riftway only downloads over HTTPS (or from this Mac while developing): \(url)"
            case .download(let url, let status): "Download failed (\(status)): \(url)"
            case .size(let expected, let got): "The download has \(got) bytes; the feed says \(expected)"
            case .hash(let expected, let got): "The download's SHA-256 is \(got); the feed says \(expected)"
            case .notARuntime(let why): "The runtime archive is not a Riftway runtime: \(why)"
            case .runtimeExists(let version): "Runtime \(version) is already installed"
            case .notTheApp(let why): "The downloaded app is not this Riftway: \(why)"
            case .badSignature(let why): "The downloaded app's code signature is not valid: \(why)"
            case .otherDeveloper(let expected, let got): "The downloaded app is signed by \(got ?? "no team"), not \(expected ?? "no team") like this one"
            case .notNewer(let version): "Version \(version) is not newer than this one"
            case .cannotSwap(let code): "Could not swap the app bundle (errno \(code))"
            case .requiresMacOS(let version): "It needs macOS \(version) or later"
            }
        }
    }

    // MARK: State

    public struct State: Codable, Sendable, Equatable {
        public var lastCheck: Date?
        /// The newest feed accepted: older ones are refused (no rollbacks).
        public var lastFeed: Date?
    }

    public var folder: URL { home.root.appendingPathComponent("Updates", isDirectory: true) }
    /// Profiles from the feed (`ProfileStore.standard` reads them).
    public var profilesFolder: URL { folder.appendingPathComponent("Profiles", isDirectory: true) }
    var stateFile: URL { folder.appendingPathComponent("state.json") }

    public var state: State {
        (try? Data(contentsOf: stateFile)).flatMap { try? ReleaseManifest.decoder.decode(State.self, from: $0) } ?? State()
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    /// Automatic checks happen at most once a day (PRD-05 R1.5).
    public var isCheckDue: Bool { state.lastCheck.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true }

    // MARK: Feed

    /// HTTPS; plain HTTP and files only on this Mac, for development.
    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "file": true
        case "http": ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: false
        }
    }

    /// Downloads and verifies the feed, and records it as the newest seen.
    public func check() async throws -> ReleaseManifest {
        guard Self.isAllowed(feedURL) else { throw Failure.insecureAddress(feedURL.absoluteString) }
        let feed = try await fetch(feedURL)
        let signature = try await fetch(URL(string: feedURL.lastPathComponent + ".sig", relativeTo: feedURL)!.absoluteURL)
        var state = state
        let manifest = try ReleaseManifest.verified(feed: feed, signature: signature, trustedKeys: trustedKeys, notOlderThan: state.lastFeed)
        state.lastCheck = Date()
        state.lastFeed = manifest.generated
        try save(state)
        return manifest
    }

    func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Riftway/\(Riftway.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else { throw Failure.download(url.absoluteString, status: status) }
        return data
    }

    public func resolve(_ download: ReleaseManifest.Download) throws -> URL {
        guard let url = URL(string: download.url, relativeTo: feedURL)?.absoluteURL, Self.isAllowed(url) else {
            throw Failure.insecureAddress(download.url)
        }
        return url
    }

    /// Downloads a file of the feed into `Updates/Downloads` and checks it.
    public func download(_ download: ReleaseManifest.Download) async throws -> URL {
        let source = try resolve(download)
        let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let target = downloads.appendingPathComponent(download.sha256 + "-" + source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path), (try? Self.verify(target, against: download)) != nil { return target }
        let temporary: URL
        if source.isFileURL {
            temporary = downloads.appendingPathComponent(".\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: temporary)
        } else {
            let (file, response) = try await URLSession.shared.download(from: source)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard status == 200 else { throw Failure.download(source.absoluteString, status: status) }
            temporary = file
        }
        do {
            try Self.verify(temporary, against: download)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return target
    }

    static func verify(_ file: URL, against download: ReleaseManifest.Download) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == download.size else { throw Failure.size(expected: download.size, got: size) }
        let hash = ProfileQuery.sha256(of: file) ?? ""
        guard hash == download.sha256.lowercased() else { throw Failure.hash(expected: download.sha256, got: hash) }
    }

    // MARK: Profiles

    /// Replaces the feed's profiles in `Updates/Profiles` with these.
    @discardableResult
    public func install(profiles: [GameProfile]) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".profiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            for profile in profiles {
                try encoder.encode(profile).write(to: staging.appendingPathComponent(profile.id + ".json"))
            }
            if fm.fileExists(atPath: profilesFolder.path) {
                _ = try fm.replaceItemAt(profilesFolder, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: profilesFolder)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return profiles.count
    }

    // MARK: Runtimes

    /// Runtimes in the feed that this Mac can run and does not have.
    public func newRuntimes(in manifest: ReleaseManifest) -> [ReleaseManifest.RuntimeRelease] {
        let installed = Set(home.installedRuntimes().map(\.version))
        return manifest.runtimes.filter { !installed.contains($0.version) && VersionNumber.macOS(meets: $0.minimumMacOS) }
    }

    /// Downloads, unpacks and installs a runtime. Bottles keep the runtime
    /// they were made with; new bottles use the newest.
    public func install(runtime release: ReleaseManifest.RuntimeRelease) async throws -> RiftwayHome.InstalledRuntime {
        guard VersionNumber.macOS(meets: release.minimumMacOS) else { throw Failure.requiresMacOS(release.minimumMacOS) }
        let target = home.runtimes.appendingPathComponent(release.version, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.runtimeExists(release.version) }
        let archive = try await download(release.download)
        defer { try? FileManager.default.removeItem(at: archive) }
        return try installRuntime(archive: archive, version: release.version)
    }

    /// Unpacks a runtime archive (its folder's contents) into `Runtimes/<version>`.
    public func installRuntime(archive: URL, version: String) throws -> RiftwayHome.InstalledRuntime {
        let fm = FileManager.default
        guard !version.isEmpty, !version.contains("/"), !version.hasPrefix(".") else { throw Failure.notARuntime("version \(version)") }
        let target = home.runtimes.appendingPathComponent(version, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw Failure.runtimeExists(version) }
        try fm.createDirectory(at: home.runtimes, withIntermediateDirectories: true)
        let staging = home.runtimes.appendingPathComponent(".\(version)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // bsdtar refuses absolute paths and `..` unless told otherwise.
            let status = try ProcessRunner.run(LaunchPlan(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", staging.path],
                                                          environment: [:], workingDirectory: staging.path),
                                               output: .discard, timeout: 600)
            guard status == 0 else { throw Failure.notARuntime("tar exited with \(status)") }
            guard fm.isExecutableFile(atPath: staging.appendingPathComponent("bin/wine").path),
                  let data = try? Data(contentsOf: staging.appendingPathComponent("runtime.json")),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Failure.notARuntime("bin/wine or runtime.json missing") }
            guard info["version"] as? String == version else { throw Failure.notARuntime("runtime.json is \(info["version"] ?? "?"), not \(version)") }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return RiftwayHome.InstalledRuntime(version: version, runtime: WineRuntime(root: target.path))
    }

    // MARK: The app

    /// Downloads and unpacks a new Riftway.app next to `current` (same disk,
    /// so the swap is one rename) and checks that it is this app, newer, and
    /// validly signed by the same developer.
    public func stage(app release: ReleaseManifest.AppRelease, replacing current: URL) async throws -> URL {
        guard VersionNumber.macOS(meets: release.minimumMacOS) else { throw Failure.requiresMacOS(release.minimumMacOS) }
        let zip = try await download(release.download)
        defer { try? FileManager.default.removeItem(at: zip) }
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        do {
            let status = try ProcessRunner.run(LaunchPlan(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, staging.path],
                                                          environment: [:], workingDirectory: staging.path),
                                               output: .discard, timeout: 300)
            guard status == 0 else { throw Failure.notTheApp("ditto exited with \(status)") }
            let staged = staging.appendingPathComponent(current.lastPathComponent)
            try Self.check(staged: staged, against: current, version: release.version)
            return staged
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// A bundle's `Info.plist`, read from disk (`Bundle` caches it per path,
    /// and the path stays the same across an update).
    public static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    public static func version(of bundle: URL) -> String? { info(bundle)?["CFBundleShortVersionString"] as? String }

    public static func check(staged: URL, against current: URL, version: String) throws {
        guard let new = info(staged), let old = info(current) else { throw Failure.notTheApp("no app bundle") }
        let identifier = new["CFBundleIdentifier"] as? String
        guard identifier == old["CFBundleIdentifier"] as? String else { throw Failure.notTheApp(identifier ?? "no identifier") }
        let newVersion = new["CFBundleShortVersionString"] as? String ?? ""
        guard newVersion == version else { throw Failure.notTheApp("it is version \(newVersion), the feed says \(version)") }
        let oldVersion = old["CFBundleShortVersionString"] as? String ?? ""
        guard VersionNumber.isNewer(newVersion, than: oldVersion) else { throw Failure.notNewer(newVersion) }
        let newCode = try CodeSignature(staged), oldCode = try? CodeSignature(current)
        guard newCode.team == oldCode?.team else { throw Failure.otherDeveloper(expected: oldCode?.team, got: newCode.team) }
    }

    /// Swaps the staged app into place once `pid` (the running Riftway) has
    /// exited, moves the old one to the Trash and opens the new one. Run by
    /// the staged app's own `riftway apply-update`.
    public static func apply(staged: URL, target: URL, waitingFor pid: Int32?, open: Bool = true) throws {
        if let pid {
            let deadline = Date().addingTimeInterval(60)
            while kill(pid, 0) == 0, Date() < deadline { usleep(200_000) }
        }
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.cannotSwap(errno) }
        // The old app is now at the staged path.
        try? FileManager.default.trashItem(at: staged, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        Log().write("update: installed Riftway \(version(of: target) ?? "?")")
        if open {
            _ = try? ProcessRunner.run(LaunchPlan(executable: "/usr/bin/open", arguments: [target.path], environment: [:],
                                                  workingDirectory: "/"), output: .discard, timeout: 30)
        }
    }

    /// Starts the staged app's helper to swap the bundles after this process quits.
    public static func launchApply(staged: URL, target: URL) throws {
        let helper = staged.appendingPathComponent("Contents/Helpers/riftway")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["apply-update", "--staged", staged.path, "--target", target.path,
                             "--pid", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// A bundle's code signature: valid (strictly, nested code included) and its
/// Developer ID team, nil when signed ad hoc.
public struct CodeSignature: Sendable {
    public var team: String?

    public init(_ bundle: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw Updater.Failure.badSignature("unreadable")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else {
            throw Updater.Failure.badSignature((SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)")
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

extension Updater {
    /// The Riftway.app this process belongs to: the app itself, or the app
    /// whose `Contents/Helpers` holds this program. Nil when run from a build folder.
    public static var appBundle: URL? {
        var url = Bundle.main.bundleURL
        if url.pathExtension != "app", let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return url.pathExtension == "app" && FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) ? url : nil
    }

    /// Where the feed is: `RIFTWAY_FEED_URL`, or the app's `RiftwayFeedURL`.
    /// Nil (no update checks at all) until a release location is set.
    public static var configuredFeedURL: URL? {
        if let value = ProcessInfo.processInfo.environment["RIFTWAY_FEED_URL"], !value.isEmpty { return URL(string: value) }
        guard let app = appBundle, let value = info(app)?["RiftwayFeedURL"] as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }
}
