import Foundation

/// A game launcher Riftway can fetch (PRD-01 R1.6). On a Mac, the launchers'
/// sites hand out their macOS app, so Riftway downloads the Windows installer
/// itself, only from the publisher's servers, and keeps it only when the
/// publisher signed it.
public struct StoreLauncher: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let publisher: String
    /// The publisher's link to its latest Windows installer.
    public let url: URL
    /// Where the download may end up after redirects (the host or a parent domain).
    public let hosts: [String]
    /// A part of the Authenticode signer's name. Nil for an MSI: Riftway does
    /// not verify MSI signatures yet, so the publisher's HTTPS host is the check.
    public let signer: String?
    /// Installed and opened on Riftway's runtime (the corpus, PLAN.md).
    public let tested: Bool

    public init(id: String, name: String, publisher: String, url: URL, hosts: [String], signer: String?, tested: Bool) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.url = url
        self.hosts = hosts
        self.signer = signer
        self.tested = tested
    }

    /// Whether a download may come from `url`: HTTPS, on one of `hosts`.
    public func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether the downloaded file is this launcher's installer, from what the
    /// analyzer read: a Windows installer, signed by the publisher.
    public func check(_ report: InstallerReport) throws {
        guard case .installer(let type) = report.kind else { throw StoreLauncherDownload.Failure.notInstaller }
        guard let signer else {
            // An MSI: the signature is not checked (yet); the host was.
            guard type == .msi else { throw StoreLauncherDownload.Failure.notInstaller }
            return
        }
        switch report.signature {
        case .signed(let name, _):
            // Windows' code-signing roots are not all in macOS's store, so the
            // chain may read untrusted; the signature over this exact file
            // and the publisher's name are what count.
            guard name.localizedCaseInsensitiveContains(signer) else {
                throw StoreLauncherDownload.Failure.signer(expected: signer, got: name)
            }
        case .unsigned, .unverified:
            throw StoreLauncherDownload.Failure.unsigned
        case .invalid:
            throw StoreLauncherDownload.Failure.invalidSignature
        }
    }
}

public enum StoreLaunchers {
    public static let all: [StoreLauncher] = [
        StoreLauncher(id: "steam", name: "Steam", publisher: "Valve",
                 url: URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!,
                 hosts: ["steamstatic.com"], signer: "Valve", tested: true),
        StoreLauncher(id: "epic", name: "Epic Games Launcher", publisher: "Epic Games",
                 url: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
                 hosts: ["epicgames.com", "epicgames-download1.akamaized.net"], signer: nil, tested: true),
        StoreLauncher(id: "gog", name: "GOG Galaxy", publisher: "GOG",
                 url: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
                 hosts: ["gog-statics.com", "gog.com"], signer: "GOG", tested: false),
        StoreLauncher(id: "ea", name: "EA app", publisher: "Electronic Arts",
                 url: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
                 hosts: ["origin-a.akamaihd.net"], signer: "Electronic Arts", tested: false),
        StoreLauncher(id: "ubisoft", name: "Ubisoft Connect", publisher: "Ubisoft",
                 url: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
                 hosts: ["cdn.ubi.com"], signer: "Ubisoft", tested: false),
        StoreLauncher(id: "battlenet", name: "Battle.net", publisher: "Blizzard",
                 url: URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
                 hosts: ["battle.net"], signer: "Blizzard", tested: false),
    ]

    public static func launcher(_ id: String) -> StoreLauncher? {
        all.first { $0.id == id.lowercased() }
    }
}

/// Downloads a launcher's installer into `<home>/Installers/<launcher id>/`
/// (replacing the last one: the bottle keeps its own copy) and checks it.
public enum StoreLauncherDownload {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case status(Int)
        case host(String)
        case notInstaller
        case unsigned
        case invalidSignature
        case signer(expected: String, got: String)

        public var description: String {
            switch self {
            case .status(let code): "El servidor respondió \(code)."
            case .host(let host): "La descarga terminó en \(host), que no es del fabricante."
            case .notInstaller: "Lo descargado no es un instalador de Windows."
            case .unsigned: "El instalador no está firmado."
            case .invalidSignature: "La firma del instalador no es válida: el archivo cambió después de firmarse."
            case .signer(let expected, let got): "El instalador está firmado por \(got), no por \(expected)."
            }
        }
    }

    public static func folder(for launcher: StoreLauncher, home: RiftwayHome) -> URL {
        home.root.appendingPathComponent("Installers/\(launcher.id)", isDirectory: true)
    }

    /// Downloads, checks and keeps the installer; `progress` gets 0…1 when the
    /// server says the size. Returns the installer, analyzed.
    public static func run(_ launcher: StoreLauncher, home: RiftwayHome = .standard,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let (temporary, response) = try await Downloader.download(launcher.url, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let final = response.url ?? launcher.url
        guard launcher.allows(final) else { throw Failure.host(final.host ?? final.absoluteString) }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw Failure.status(status) }

        let folder = folder(for: launcher, home: home)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = final.lastPathComponent.isEmpty ? launcher.url.lastPathComponent : final.lastPathComponent
        let file = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: file)
        do {
            try launcher.check(InstallerAnalyzer.analyze(file))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // Like a browser download: where it came from, for the analysis sheet.
        if let origin = try? PropertyListSerialization.data(fromPropertyList: [launcher.url.absoluteString], format: .binary, options: 0) {
            file.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = origin.withUnsafeBytes { setxattr(path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, origin.count, 0, 0) }
            }
        }
        return file
    }
}

/// A URLSession download that reports its progress (the async API does not).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var result: (URL, URLResponse)?
    private let lock = NSLock()

    private init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        let downloader = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.lock.withLock { downloader.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// The file goes away when this returns: move it somewhere of ours.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-download-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: location, to: kept)) != nil, let response = downloadTask.response else { return }
        lock.withLock { result = (kept, response) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, (URL, URLResponse)?) in
            defer { self.continuation = nil }
            return (self.continuation, self.result)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let result {
            continuation?.resume(returning: result)
        } else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }
}
