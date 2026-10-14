import CryptoKit
import Foundation
import Testing
@testable import RiftwayCore

struct FeedFixture {
    let root: URL
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    var feed: URL { root.appendingPathComponent("feed/feed.json") }
    var home: RiftwayHome { RiftwayHome(root: root.appendingPathComponent("home"), bridges: root.appendingPathComponent("bridges")) }
    var updater: Updater { Updater(home: home, feedURL: feed, trustedKeys: [publicKey]) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("feed"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Puts `data` next to the feed and describes it.
    func publish(_ name: String, _ data: Data) throws -> [String: Any] {
        try data.write(to: root.appendingPathComponent("feed/" + name))
        return ["url": name, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count]
    }

    func write(_ object: [String: Any], signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws {
        var object = object
        object["schema"] = object["schema"] ?? 1
        object["generated"] = object["generated"] ?? ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: feed)
        try Data(try (signer ?? key).signature(for: data).base64EncodedString().utf8).write(to: URL(fileURLWithPath: feed.path + ".sig"))
    }
}

/// A minimal ad hoc signed app bundle.
func makeApp(at url: URL, identifier: String = "com.riftway.app", version: String) throws {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "app",
                                "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/app").path)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", url.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
}

@Suite struct UpdateFeedTests {
    @Test func onlyTheReleaseKeyAndNoRollbacks() async throws {
        let fixture = try FeedFixture()
        defer { fixture.remove() }
        try fixture.write(["generated": "2026-10-13T10:00:00Z", "profiles": [["id": "bad"]]])
        let manifest = try await fixture.updater.check()
        #expect(manifest.rejectedProfiles == ["bad"])
        #expect(fixture.updater.state.lastFeed == manifest.generated)
        #expect(!fixture.updater.isCheckDue)

        // Another key, a changed byte, or an older feed: refused.
        try fixture.write([:], signedBy: Curve25519.Signing.PrivateKey())
        await #expect(throws: ReleaseManifest.Invalid.badSignature) { _ = try await fixture.updater.check() }
        try fixture.write(["generated": "2026-10-13T11:00:00Z"])
        var bytes = try Data(contentsOf: fixture.feed)
        bytes[bytes.count - 3] ^= 1
        try bytes.write(to: fixture.feed)
        await #expect(throws: ReleaseManifest.Invalid.badSignature) { _ = try await fixture.updater.check() }
        try fixture.write(["generated": "2026-10-12T10:00:00Z"])
        await #expect(throws: ReleaseManifest.Invalid.self) { _ = try await fixture.updater.check() }
        try fixture.write(["schema": 2])
        await #expect(throws: ReleaseManifest.Invalid.schema(2)) { _ = try await fixture.updater.check() }

        #expect(Updater.isAllowed(URL(string: "https://example.com/feed.json")!))
        #expect(Updater.isAllowed(URL(string: "http://localhost:8000/feed.json")!))
        #expect(!Updater.isAllowed(URL(string: "http://example.com/feed.json")!))
    }

    @Test func versions() {
        #expect(VersionNumber.isNewer("0.10.0", than: "0.9.9"))
        #expect(VersionNumber.isNewer("1.0.1", than: "1.0"))
        #expect(!VersionNumber.isNewer("1.0", than: "1.0.0"))
        #expect(VersionNumber.macOS("26.6.2", meets: "26.0"))
        #expect(!VersionNumber.macOS("15.7", meets: "26.0"))
    }

    @Test func downloadsAreCheckedAndProfilesInstalled() async throws {
        let fixture = try FeedFixture()
        defer { fixture.remove() }
        let download = try fixture.publish("file.bin", Data("payload".utf8))
        let good = ReleaseManifest.Download(url: "file.bin", sha256: download["sha256"] as! String, size: 7)
        let file = try await fixture.updater.download(good)
        #expect(try Data(contentsOf: file) == Data("payload".utf8))
        await #expect(throws: Updater.Failure.size(expected: 8, got: 7)) {
            _ = try await fixture.updater.download(ReleaseManifest.Download(url: "file.bin", sha256: good.sha256.replacingOccurrences(of: "a", with: "b"), size: 8))
        }
        await #expect(throws: Updater.Failure.self) {
            _ = try await fixture.updater.download(ReleaseManifest.Download(url: "file.bin", sha256: String(repeating: "0", count: 64), size: 7))
        }
        await #expect(throws: Updater.Failure.insecureAddress("http://example.com/x")) {
            _ = try await fixture.updater.download(ReleaseManifest.Download(url: "http://example.com/x", sha256: good.sha256, size: 7))
        }

        let profile = GameProfile(id: "feed-game", name: "Feed Game", match: .init(executables: ["Feed.exe"]), status: .playable)
        try fixture.updater.install(profiles: [profile])
        try fixture.updater.install(profiles: [profile])  // replaces
        let store = ProfileStore.standard(home: fixture.home)
        #expect(store.profile(id: "feed-game") == profile)
    }

    @Test func runtimesUnpackIntoTheirVersion() async throws {
        let fixture = try FeedFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("rt")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.appendingPathComponent("bin/wine").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try Data(#"{"version": "rw-9.0.0", "minimum_macos": "14.0"}"#.utf8).write(to: source.appendingPathComponent("runtime.json"))
        let archive = fixture.root.appendingPathComponent("feed/rw-9.0.0.tar.gz")
        _ = try ProcessRunner.run(LaunchPlan(executable: "/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path, "."],
                                             environment: [:], workingDirectory: source.path), output: .discard, timeout: 30)
        let data = try Data(contentsOf: archive)
        let download = ReleaseManifest.Download(url: "rw-9.0.0.tar.gz", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                                size: Int64(data.count))
        let release = ReleaseManifest.RuntimeRelease(version: "rw-9.0.0", minimumMacOS: "14.0", download: download)
        let manifest = ReleaseManifest(generated: Date(), runtimes: [release])
        #expect(fixture.updater.newRuntimes(in: manifest).count == 1)
        let installed = try await fixture.updater.install(runtime: release)
        #expect(installed.version == "rw-9.0.0")
        #expect(fixture.home.installedRuntimes().map(\.version) == ["rw-9.0.0"])
        #expect(fixture.updater.newRuntimes(in: manifest).isEmpty)
        // An archive whose runtime.json names another version is refused, and leaves nothing behind.
        #expect(throws: Updater.Failure.self) { _ = try fixture.updater.installRuntime(archive: archive, version: "rw-9.0.1") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home.runtimes.path) == ["rw-9.0.0"])
    }

    @Test func appUpdatesAreThisAppNewerAndSwapInPlace() throws {
        let fixture = try FeedFixture()
        defer { fixture.remove() }
        let current = fixture.root.appendingPathComponent("Applications/Riftway.app")
        try makeApp(at: current, version: "0.1.0")
        let newer = fixture.root.appendingPathComponent("staged/Riftway.app")
        try makeApp(at: newer, version: "0.2.0")
        try Updater.check(staged: newer, against: current, version: "0.2.0")
        #expect(throws: Updater.Failure.self) { try Updater.check(staged: newer, against: current, version: "0.3.0") }
        #expect(throws: Updater.Failure.notNewer("0.1.0")) { try Updater.check(staged: current, against: current, version: "0.1.0") }
        let other = fixture.root.appendingPathComponent("other/Riftway.app")
        try makeApp(at: other, identifier: "com.example.other", version: "0.2.0")
        #expect(throws: Updater.Failure.notTheApp("com.example.other")) { try Updater.check(staged: other, against: current, version: "0.2.0") }
        // A modified file breaks the signature.
        let tampered = fixture.root.appendingPathComponent("tampered/Riftway.app")
        try makeApp(at: tampered, version: "0.2.0")
        try Data("#!/bin/sh\n".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/app"))
        #expect(throws: Updater.Failure.self) { try Updater.check(staged: tampered, against: current, version: "0.2.0") }

        try Updater.apply(staged: newer, target: current, waitingFor: nil, open: false)
        #expect(Updater.version(of: current) == "0.2.0")
        #expect(!FileManager.default.fileExists(atPath: newer.path))
    }

    @Test func uninstallKeepsBottlesUnlessAsked() throws {
        let fixture = try FeedFixture()
        defer { fixture.remove() }
        let home = fixture.home
        for folder in [home.runtimes, home.bottles, home.root.appendingPathComponent("Updates"), home.bridges] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let app = fixture.root.appendingPathComponent("Riftway.app")
        let uninstaller = Uninstaller(home: home, app: app)
        #expect(uninstaller.items(includingBottles: false) == [home.bridges, home.runtimes, home.root.appendingPathComponent("Updates", isDirectory: true)])
        #expect(uninstaller.items(includingBottles: true) == [home.bridges, home.root])
    }
}
