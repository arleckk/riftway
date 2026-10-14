import CryptoKit
import Foundation
import RiftwayCore

let usage = """
riftway-release — signing keys and the update feed (PRD-06)

  riftway-release keygen
      Make the Ed25519 release key: the private key goes to the key file
      (never into the repository), the public key is printed for ReleaseKeys.
  riftway-release public-key
      Print the public key of the key file.
  riftway-release sign <file>
      Write <file>.sig: the base64 Ed25519 signature of its bytes.
  riftway-release verify <feed.json> [--public-key B64]
      Check feed.json.sig (against ReleaseKeys.trusted by default) and print the feed.
  riftway-release feed --out DIR [--app-zip FILE --app-version V --build N --minimum-macos V [--notes TEXT]]
                       [--runtime FILE.tar.gz]... [--profiles DIR]
      Copy the files into DIR and write DIR/feed.json, with addresses relative
      to the feed, sizes and SHA-256. A runtime's version and minimum macOS come
      from its runtime.json; profiles are validated.

The key file is $RIFTWAY_RELEASE_KEY, or ~/.riftway/release-signing.key.
"""

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

nonisolated var keyFile: URL {
    if let path = ProcessInfo.processInfo.environment["RIFTWAY_RELEASE_KEY"], !path.isEmpty { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".riftway/release-signing.key")
}

nonisolated func privateKey() throws -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw Failure("No release key at \(keyFile.path); run riftway-release keygen")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// `--name value` pairs (repeatable) and positional arguments.
func parse(_ args: ArraySlice<String>) -> (values: [String: [String]], positional: [String]) {
    var values: [String: [String]] = [:], positional: [String] = []
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg.hasPrefix("--"), let value = it.next() { values[arg, default: []].append(value) } else { positional.append(arg) }
    }
    return (values, positional)
}

/// Copies `file` into `out` and describes it for the feed.
func publish(_ file: URL, into out: URL) throws -> [String: Any] {
    let target = out.appendingPathComponent(file.lastPathComponent)
    if file.standardizedFileURL != target.standardizedFileURL {
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: file, to: target)
    }
    let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
    return ["url": file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.lastPathComponent,
            "sha256": try sha256(target), "size": size]
}

func makeFeed(_ values: [String: [String]]) throws {
    guard let outPath = values["--out"]?.first else { throw Failure("Pass --out DIR") }
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var feed: [String: Any] = ["schema": ReleaseManifest.schemaVersion, "generated": ISO8601DateFormatter().string(from: Date())]

    if let zip = values["--app-zip"]?.first {
        guard let version = values["--app-version"]?.first, let build = values["--build"]?.first.flatMap(Int.init),
              let minimum = values["--minimum-macos"]?.first else {
            throw Failure("--app-zip needs --app-version, --build and --minimum-macos")
        }
        var app: [String: Any] = ["version": version, "build": build, "minimum_macos": minimum,
                                  "download": try publish(URL(fileURLWithPath: zip), into: out)]
        if let notes = values["--notes"]?.first { app["notes"] = notes }
        feed["app"] = app
    }

    var runtimes: [[String: Any]] = []
    for path in values["--runtime"] ?? [] {
        let archive = URL(fileURLWithPath: path)
        // runtime.json from inside the archive: its version and minimum macOS.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzOf", archive.path, "runtime.json"]
        let pipe = Pipe()
        tar.standardOutput = pipe
        try tar.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = info["version"] as? String else {
            throw Failure("\(path) has no runtime.json with a version")
        }
        runtimes.append(["version": version, "minimum_macos": info["minimum_macos"] as? String ?? "14.0",
                         "download": try publish(archive, into: out)])
    }
    if !runtimes.isEmpty { feed["runtimes"] = runtimes }

    if let folder = values["--profiles"]?.first {
        var profiles: [Any] = []
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".json") {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            do { _ = try GameProfile.load(data) } catch { throw Failure("\(name): \(error)") }
            profiles.append(try JSONSerialization.jsonObject(with: data))
        }
        feed["profiles"] = profiles
    }

    let data = try JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    _ = try ReleaseManifest.parse(data)
    try data.write(to: out.appendingPathComponent("feed.json"))
    print("Wrote \(out.appendingPathComponent("feed.json").path); sign it with: riftway-release sign \(out.path)/feed.json")
}

let args = CommandLine.arguments
do {
    guard args.count > 1 else { print(usage); exit(64) }
    let (values, positional) = parse(args.dropFirst(2))
    switch args[1] {
    case "keygen":
        let fm = FileManager.default
        guard !fm.fileExists(atPath: keyFile.path) else { throw Failure("\(keyFile.path) exists; refusing to replace a release key") }
        try fm.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        guard fm.createFile(atPath: keyFile.path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                            attributes: [.posixPermissions: 0o600]) else { throw Failure("Could not write \(keyFile.path)") }
        print("Private key: \(keyFile.path) (back it up somewhere safe; never commit it)")
        print("Public key:  \(key.publicKey.rawRepresentation.base64EncodedString())")
    case "public-key":
        print(try privateKey().publicKey.rawRepresentation.base64EncodedString())
    case "sign":
        guard let path = positional.first else { throw Failure("Pass the file") }
        let file = URL(fileURLWithPath: path)
        let signature = try privateKey().signature(for: try Data(contentsOf: file))
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sig"))
        print("Signed: \(path).sig")
    case "verify":
        guard let path = positional.first else { throw Failure("Pass feed.json") }
        let keys = values["--public-key"] ?? ReleaseKeys.trusted
        let manifest = try ReleaseManifest.verified(feed: try Data(contentsOf: URL(fileURLWithPath: path)),
                                                    signature: try Data(contentsOf: URL(fileURLWithPath: path + ".sig")), trustedKeys: keys)
        print("Signature ok. Generated \(manifest.generated)")
        if let app = manifest.app { print("app \(app.version) (\(app.build)), macOS \(app.minimumMacOS)+: \(app.download.url)") }
        for r in manifest.runtimes { print("runtime \(r.version), macOS \(r.minimumMacOS)+: \(r.download.url) (\(r.download.size) bytes)") }
        print("profiles: " + manifest.profiles.map { "\($0.id) r\($0.revision)" }.joined(separator: ", "))
        if !manifest.rejectedProfiles.isEmpty { print("rejected: \(manifest.rejectedProfiles)") }
    case "feed":
        try makeFeed(values)
    default:
        print(usage); exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("riftway-release: \(error)\n".utf8))
    exit(1)
}
