import Foundation

public enum InstallerType: String, Sendable, Codable, CaseIterable {
    case nsis, innoSetup, installShield, wixBurn, squirrel, sevenZipSFX, msi, unknown

    public var displayName: String {
        switch self {
        case .nsis: "NSIS"
        case .innoSetup: "Inno Setup"
        case .installShield: "InstallShield"
        case .wixBurn: "WiX Burn"
        case .squirrel: "Squirrel"
        case .sevenZipSFX: "7-Zip SFX"
        case .msi: "MSI"
        case .unknown: "Instalador"
        }
    }
}

public enum UnsupportedReason: Sendable, Equatable {
    case notWindowsProgram
    case library
    case driver
    case architecture(String)
    case unreadable(String)
}

/// What a `.exe` or `.msi` is, read without running it.
public struct InstallerReport: Sendable {
    public enum Kind: Sendable, Equatable {
        case installer(InstallerType)
        case portable
        case unsupported(UnsupportedReason)
    }

    public var file: URL
    public var fileSize: Int64
    public var kind: Kind
    public var architecture: String?
    public var product: String?
    public var company: String?
    public var version: String?
    public var fileDescription: String?
    /// `asInvoker`, `highestAvailable`, `requireAdministrator`.
    public var executionLevel: String?
    public var isDotNet: Bool
    public var signature: SignatureStatus
    /// Where the file was downloaded from (`kMDItemWhereFroms`), newest first.
    public var origin: [String]
    public var isQuarantined: Bool
    /// Files beside it that a multi-part installer reads (`.bin`, `.cab`).
    public var companions: [URL]
    /// The program's icon as `.ico` bytes.
    public var icon: Data?

    /// A name for the bottle and the library: product, then description, then file name.
    public var displayName: String {
        product ?? fileDescription ?? file.deletingPathExtension().lastPathComponent
    }
}

public enum InstallerAnalyzer {
    public static func analyze(_ url: URL) -> InstallerReport {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var report = InstallerReport(file: url, fileSize: size, kind: .unsupported(.notWindowsProgram), isDotNet: false,
                                     signature: .unsigned, origin: FileOrigin.whereFroms(url),
                                     isQuarantined: FileOrigin.isQuarantined(url), companions: [])
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            report.kind = .unsupported(.unreadable(error.localizedDescription))
            return report
        }

        if data.prefix(8) == CompoundFile.magic {
            analyzeMSI(data, into: &report)
        } else if let pe = try? PEFile(data: data) {
            analyzePE(pe, into: &report)
        }
        if case .installer = report.kind { report.companions = companions(of: url) }
        return report
    }

    static func analyzeMSI(_ data: Data, into report: inout InstallerReport) {
        report.kind = .installer(.msi)
        guard let file = try? CompoundFile(data: data) else { return }
        if file.hasStream(named: "\u{5}DigitalSignature") { report.signature = .unverified }
        guard let summary = MSISummary.read(from: file) else { return }
        report.product = summary.subject
        report.company = summary.author
        report.fileDescription = summary.comments
        switch summary.platform?.lowercased() {
        case "intel": report.architecture = "x86"
        case "x64", "amd64": report.architecture = "x64"
        case "arm64": report.architecture = "ARM64"
        case let other?: report.architecture = other
        case nil: break
        }
        if report.architecture == "ARM64" { report.kind = .unsupported(.architecture("ARM64")) }
    }

    static func analyzePE(_ pe: PEFile, into report: inout InstallerReport) {
        report.architecture = pe.machine.description
        report.isDotNet = pe.isDotNet
        let version = pe.versionInfo()
        report.product = version?["ProductName"]
        report.company = version?["CompanyName"]
        report.fileDescription = version?["FileDescription"]
        report.version = version?["ProductVersion"] ?? version?["FileVersion"] ?? version?.productVersion
        let manifest = pe.manifest()
        report.executionLevel = manifest.flatMap(PEFile.executionLevel(inManifest:))
        report.icon = pe.iconData()
        report.signature = Authenticode.verify(pe)

        if pe.isDLL { report.kind = .unsupported(.library); return }
        if pe.subsystem == .native { report.kind = .unsupported(.driver); return }
        switch pe.machine {
        case .x86, .x64: break
        default: report.kind = .unsupported(.architecture(pe.machine.description)); return
        }
        if let type = installerType(pe, version: version, manifest: manifest) {
            report.kind = .installer(type)
        } else if looksLikeInstaller(name: report.file.lastPathComponent, version: version) {
            report.kind = .installer(.unknown)
        } else {
            report.kind = .portable
        }
    }

    /// Installer engines by their fingerprints in the overlay, sections,
    /// resources, manifest and version strings.
    static func installerType(_ pe: PEFile, version: PEFile.VersionInfo?, manifest: String?) -> InstallerType? {
        let r = pe.reader
        if pe.sections.contains(where: { $0.name == ".wixburn" }) { return .wixBurn }
        let identity = manifest.flatMap { PEFile.attribute("name", ofElement: "assemblyIdentity", in: $0) } ?? ""
        let strings = (version?.strings.values.joined(separator: "\n") ?? "") + "\n" + identity
        func has(_ text: String) -> Bool { strings.range(of: text, options: .caseInsensitive) != nil }

        if let overlay = pe.overlay {
            let head = overlay.lowerBound..<min(overlay.upperBound, overlay.lowerBound + (1 << 20))
            if r.contains(Data("NullsoftInst".utf8), in: head) { return .nsis }
            if r.bytes(overlay.lowerBound, 6) == Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZipSFX }
            if r.contains(Data("Inno Setup Setup Data".utf8), in: head) { return .innoSetup }
            if r.contains(Data("ISSetupStream".utf8), in: head) { return .installShield }
        }
        if identity.hasPrefix("Nullsoft.NSIS") { return .nsis }
        // Inno keeps its loader table in RCDATA #11111, starting with "rDlPtS".
        if pe.resources().contains(where: { $0.type == PEFile.typeRCData && $0.name == .number(11111)
            && pe.reader.bytes($0.range.lowerBound, 6) == Data("rDlPtS".utf8) }) || has("Inno Setup") { return .innoSetup }
        if has("InstallShield") { return .installShield }
        if has("Squirrel") || identity.localizedCaseInsensitiveContains("squirrel") { return .squirrel }
        return nil
    }

    static func looksLikeInstaller(name: String, version: PEFile.VersionInfo?) -> Bool {
        let text = [name, version?["FileDescription"], version?["OriginalFilename"], version?["InternalName"]]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return ["setup", "install", "installer", "instalador"].contains { text.contains($0) }
    }

    /// `game.exe` + `game-1.bin`, `game-2.bin` (Inno, GOG), and `.cab` files
    /// (InstallShield, external MSI cabinets) in the same folder.
    static func companions(of url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().filter { name in
            let lower = name.lowercased()
            return (lower.hasPrefix(stem) && lower.hasSuffix(".bin")) || lower.hasSuffix(".cab")
        }.prefix(64).map { folder.appendingPathComponent($0) }
    }
}

/// Download provenance that macOS records on a file.
enum FileOrigin {
    static func whereFroms(_ url: URL) -> [String] {
        guard let raw = xattr(url, "com.apple.metadata:kMDItemWhereFroms"),
              let list = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }

    static func isQuarantined(_ url: URL) -> Bool { xattr(url, "com.apple.quarantine") != nil }

    static func xattr(_ url: URL, _ name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size < 1 << 20 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? buffer : nil
        }
    }
}
