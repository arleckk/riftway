import CryptoKit
import Foundation

/// What a release offers (PRD-06): the app, runtimes and game profiles, each
/// download with its size and SHA-256. The feed is `feed.json` plus
/// `feed.json.sig`, an Ed25519 signature of its exact bytes by the release
/// key, the way Sparkle signs its appcasts. Apple's notarization, when there is
/// a Developer ID, is checked on top; it never replaces this.
public struct ReleaseManifest: Sendable, Equatable {
    public static let schemaVersion = 1

    public struct Download: Codable, Sendable, Equatable {
        /// Absolute, or relative to the feed's address.
        public var url: String
        public var sha256: String
        public var size: Int64
    }

    public struct AppRelease: Codable, Sendable, Equatable {
        public var version: String
        public var build: Int
        public var minimumMacOS: String
        public var notes: String?
        /// A zip of `Riftway.app` (`ditto -c -k --keepParent`).
        public var download: Download

        enum CodingKeys: String, CodingKey { case version, build, notes, download, minimumMacOS = "minimum_macos" }
    }

    public struct RuntimeRelease: Codable, Sendable, Equatable {
        public var version: String
        public var minimumMacOS: String
        /// The runtime folder's contents as `.tar.gz`, with its `runtime.json`.
        public var download: Download

        enum CodingKeys: String, CodingKey { case version, download, minimumMacOS = "minimum_macos" }
    }

    public var schema: Int
    /// When the feed was made. An older feed than one already accepted is
    /// refused, so a replayed old feed cannot roll anything back.
    public var generated: Date
    public var app: AppRelease?
    public var runtimes: [RuntimeRelease]
    /// Profiles in the feed, validated like the shipped ones (PRD-05 R1.5).
    public var profiles: [GameProfile]
    /// Profile files that failed validation; the rest still apply.
    public var rejectedProfiles: [String]

    public init(schema: Int = Self.schemaVersion, generated: Date, app: AppRelease? = nil, runtimes: [RuntimeRelease] = [],
                profiles: [GameProfile] = [], rejectedProfiles: [String] = []) {
        self.schema = schema
        self.generated = generated
        self.app = app
        self.runtimes = runtimes
        self.profiles = profiles
        self.rejectedProfiles = rejectedProfiles
    }

    struct Envelope: Codable {
        var schema: Int
        var generated: Date
        var app: AppRelease?
        var runtimes: [RuntimeRelease]?
    }

    public enum Invalid: Error, CustomStringConvertible, Equatable {
        case badSignature
        case malformed(String)
        case schema(Int)
        case older(than: Date)
        case badHash(String)

        public var description: String {
            switch self {
            case .badSignature: "the release feed's signature is not from Riftway's release key"
            case .malformed(let why): "the release feed is malformed: \(why)"
            case .schema(let version): "the release feed uses schema \(version); update Riftway by hand"
            case .older(let date): "the release feed is older than one already seen (\(date))"
            case .badHash(let hash): "not a SHA-256: \(hash)"
            }
        }
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Checks the signature against the trusted keys, then reads the feed.
    public static func verified(feed: Data, signature: Data, trustedKeys: [String] = ReleaseKeys.trusted,
                                notOlderThan lastAccepted: Date? = nil) throws -> ReleaseManifest {
        guard let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              trustedKeys.contains(where: { key in
                  guard let keyData = Data(base64Encoded: key),
                        let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
                  return publicKey.isValidSignature(raw, for: feed)
              })
        else { throw Invalid.badSignature }
        let manifest = try parse(feed)
        if let lastAccepted, manifest.generated < lastAccepted { throw Invalid.older(than: lastAccepted) }
        return manifest
    }

    /// Reads a feed without checking its signature (the release tools).
    public static func parse(_ feed: Data) throws -> ReleaseManifest {
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: feed) } catch { throw Invalid.malformed("\(error)") }
        guard envelope.schema == schemaVersion else { throw Invalid.schema(envelope.schema) }
        for download in [envelope.app?.download].compactMap({ $0 }) + (envelope.runtimes ?? []).map(\.download) {
            guard download.sha256.count == 64, download.sha256.allSatisfy(\.isHexDigit) else { throw Invalid.badHash(download.sha256) }
        }
        var profiles: [GameProfile] = []
        var rejected: [String] = []
        let object = try? JSONSerialization.jsonObject(with: feed) as? [String: Any]
        for item in object?["profiles"] as? [Any] ?? [] {
            let id = (item as? [String: Any])?["id"] as? String ?? "?"
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let profile = try? GameProfile.load(data) else { rejected.append(id); continue }
            profiles.append(profile)
        }
        return ReleaseManifest(schema: envelope.schema, generated: envelope.generated, app: envelope.app,
                               runtimes: envelope.runtimes ?? [], profiles: profiles, rejectedProfiles: rejected)
    }
}

/// The public keys whose signatures Riftway trusts on release feeds. A new
/// key is added here one release before the old one is retired, so every
/// installed version can verify the feed that moves it to the next key.
public enum ReleaseKeys {
    public static let trusted: [String] = [
        // 2026-10-13, the first release key.
        "Em+droj/T+2JHaalVbbCt5XcKoydZnt5jywAYwdcp6Q=",
    ]
}

/// `1.10.0` > `1.9.2`; missing parts count as zero.
public enum VersionNumber {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// This Mac's macOS, as `26.6.2`.
    public static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func macOS(_ current: String = macOS, meets minimum: String) -> Bool {
        !isNewer(minimum, than: current)
    }
}
