import Foundation

/// Appends timestamped lines to `~/Library/Logs/Riftway/riftway.log`. Callers
/// pass URLs through `IncomingURL.redacted` first.
public struct Log: Sendable {
    public let url: URL

    public init(url: URL = Log.defaultURL) { self.url = url }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Riftway", isDirectory: true)
    }

    public static var defaultURL: URL { directory.appendingPathComponent("riftway.log") }

    public func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(ProcessInfo.processInfo.processName)] \(message)\n"
        guard let handle = try? Log.appendHandle(url) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    static func appendHandle(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
