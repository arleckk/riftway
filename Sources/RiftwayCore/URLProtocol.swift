import CryptoKit
import Foundation

/// A URL protocol a Windows program registered in a prefix, such as `dsropen`.
public struct URLProtocolRegistration: Sendable, Equatable, Codable {
    public enum Hive: String, Sendable, Codable { case machine, user }

    /// Lowercased scheme, without the colon.
    public var scheme: String
    /// The registered `shell\open\command`, for example `"C:\…\Launcher.exe" "%1"`.
    public var command: String
    public var hive: Hive

    public init(scheme: String, command: String, hive: Hive) {
        self.scheme = scheme
        self.command = command
        self.hive = hive
    }

    /// The program the command starts, as a Windows path.
    public var windowsExecutable: String? { WindowsCommandLine.split(command).first.flatMap { $0.isEmpty ? nil : $0 } }

    /// Finds the URL protocols registered in a prefix's hives. Windows merges
    /// HKCU\Software\Classes over HKLM\Software\Classes into HKEY_CLASSES_ROOT, so
    /// a user registration wins over a machine one.
    public static func discover(system: WineRegistry?, user: WineRegistry?) -> [URLProtocolRegistration] {
        var found: [String: URLProtocolRegistration] = [:]
        for (registry, hive) in [(system, Hive.machine), (user, Hive.user)] {
            guard let registry else { continue }
            let classes = #"Software\Classes"#
            for name in registry.subkeys(of: classes) {
                let base = classes + "\\" + name
                guard registry.hasValue("URL Protocol", at: base),
                      isValidScheme(name),
                      let command = registry.value("", at: base + #"\shell\open\command"#),
                      !command.isEmpty
                else { continue }
                found[name] = URLProtocolRegistration(scheme: name, command: command, hive: hive)
            }
        }
        return found.values.sorted { $0.scheme < $1.scheme }
    }

    /// Schemes macOS itself (or the user's browser and mail app) owns. Every Wine
    /// prefix registers several of them to `winebrowser.exe`, which hands them
    /// back to macOS; a shim claiming one would take the Mac's browser away and
    /// loop.
    public static let reservedSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "file", "mailto", "news", "nntp", "telnet", "ssh",
        "tel", "sms", "facetime", "facetime-audio", "webcal", "itms", "itms-apps", "macappstore",
        "x-apple", "x-apple-helpbasic", "about", "data", "javascript", "blob", "ws", "wss",
    ]

    /// Whether a shim may claim this scheme from macOS: a program's own protocol,
    /// not a reserved one and not Wine's hand-back to the Mac browser.
    public var isClaimableFromMacOS: Bool {
        guard !Self.reservedSchemes.contains(scheme) else { return false }
        let program = windowsExecutable?.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last?.lowercased()
        return program != "winebrowser.exe"
    }

    /// RFC 3986 scheme: a letter, then letters, digits, `+`, `-` or `.`.
    public static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter else { return false }
        return scheme.unicodeScalars.allSatisfy { $0.isASCIILetter || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}

public enum IncomingURLError: Error, Equatable, CustomStringConvertible {
    case malformed
    case tooLong(Int)
    case forbiddenCharacter
    case schemeNotHandled(String)

    public var description: String {
        switch self {
        case .malformed: "the URL has no valid scheme"
        case .tooLong(let n): "the URL is too long (\(n) characters)"
        case .forbiddenCharacter: "the URL contains a control character or a double quote"
        case .schemeNotHandled(let s): "the scheme \(s): is not handled here"
        }
    }
}

/// Checks a URL that arrived from outside Wine (a web page, another app) before
/// it reaches a Windows program. Any web page can open a registered scheme, so
/// this is a trust boundary.
public enum IncomingURL {
    public static let maximumLength = 16 * 1024

    /// Returns the lowercased scheme when `url` is acceptable for one of `schemes`.
    public static func validate(_ url: String, schemes: Set<String>) throws(IncomingURLError) -> String {
        if url.count > maximumLength { throw .tooLong(url.count) }
        // Control characters could end the Windows command line early or forge
        // lines in logs; a double quote could break the program's argument out of
        // its quotes. Browsers percent-encode both.
        for scalar in url.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\"" {
            throw .forbiddenCharacter
        }
        guard let colon = url.firstIndex(of: ":") else { throw .malformed }
        let scheme = String(url[..<colon])
        guard URLProtocolRegistration.isValidScheme(scheme) else { throw .malformed }
        let lowered = scheme.lowercased()
        guard schemes.contains(lowered) else { throw .schemeNotHandled(lowered) }
        return lowered
    }

    /// A log-safe form: the scheme, the payload's length and a short digest, never
    /// the payload itself (it can carry session tokens and e-mail addresses).
    public static func redacted(_ url: String) -> String {
        let scheme = url.firstIndex(of: ":").map { String(url[..<$0]) } ?? "?"
        let digest = SHA256.hash(data: Data(url.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let payload = max(0, url.count - scheme.count - 1)
        return "\(scheme):<\(payload) chars, sha256 \(digest)…>"
    }
}
