import Foundation

/// The parts of a Windows Portable Executable that installer analysis needs:
/// headers, sections, the overlay, resources (version, manifest, icons) and the
/// Authenticode certificate table. Nothing is executed.
public struct PEFile: Sendable {
    public enum Machine: Sendable, Equatable, CustomStringConvertible {
        case x86, x64, arm64, other(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 0x014C: self = .x86
            case 0x8664: self = .x64
            case 0xAA64: self = .arm64
            default: self = .other(raw)
            }
        }

        public var description: String {
            switch self {
            case .x86: "x86"
            case .x64: "x64"
            case .arm64: "ARM64"
            case .other(let raw): String(format: "0x%04X", raw)
            }
        }
    }

    public enum Subsystem: Sendable, Equatable {
        case gui, console, native, other(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 1: self = .native
            case 2: self = .gui
            case 3: self = .console
            default: self = .other(raw)
            }
        }
    }

    public struct Section: Sendable, Equatable {
        public var name: String
        public var virtualAddress: Int
        public var virtualSize: Int
        public var rawOffset: Int
        public var rawSize: Int
    }

    public struct DataDirectory: Sendable, Equatable {
        public var address: Int
        public var size: Int
        public var isPresent: Bool { address != 0 && size != 0 }
    }

    public enum Failure: Error, Equatable { case notPE, truncated }

    public let machine: Machine
    public let subsystem: Subsystem
    public let isDLL: Bool
    public let is64Bit: Bool
    public let sections: [Section]
    public let directories: [DataDirectory]
    /// File offsets of fields Authenticode leaves out of the image hash.
    let checksumOffset: Int
    let securityDirectoryOffset: Int
    let sizeOfHeaders: Int
    let reader: ByteReader

    static let directoryResource = 2
    static let directorySecurity = 4
    static let directoryCLR = 14

    public init(data: Data) throws(Failure) {
        let reader = ByteReader(data)
        guard reader.u16(0) == 0x5A4D, let lfanew = reader.u32(0x3C).map(Int.init),
              reader.u32(lfanew) == 0x0000_4550 else { throw .notPE }  // "MZ", "PE\0\0"
        let coff = lfanew + 4
        guard let machine = reader.u16(coff), let sectionCount = reader.u16(coff + 2),
              let optionalSize = reader.u16(coff + 16), let characteristics = reader.u16(coff + 18)
        else { throw .truncated }
        let optional = coff + 20
        guard let magic = reader.u16(optional) else { throw .truncated }
        let is64 = magic == 0x20B
        guard is64 || magic == 0x10B else { throw .notPE }
        guard let subsystem = reader.u16(optional + 68),
              let headers = reader.u32(optional + 60).map(Int.init) else { throw .truncated }
        let directoriesStart = optional + (is64 ? 112 : 96)
        let directoryCount = min(Int(reader.u32(directoriesStart - 4) ?? 0), 16)
        var directories: [DataDirectory] = []
        for i in 0..<directoryCount {
            guard let address = reader.u32(directoriesStart + i * 8), let size = reader.u32(directoriesStart + i * 8 + 4) else { throw .truncated }
            directories.append(DataDirectory(address: Int(address), size: Int(size)))
        }
        var sections: [Section] = []
        let sectionTable = optional + Int(optionalSize)
        for i in 0..<Int(sectionCount) {
            let s = sectionTable + i * 40
            guard let rawName = reader.bytes(s, 8), let vsize = reader.u32(s + 8), let vaddr = reader.u32(s + 12),
                  let rsize = reader.u32(s + 16), let roffset = reader.u32(s + 20) else { throw .truncated }
            let name = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
            sections.append(Section(name: name, virtualAddress: Int(vaddr), virtualSize: Int(vsize), rawOffset: Int(roffset), rawSize: Int(rsize)))
        }
        self.machine = Machine(machine)
        self.subsystem = Subsystem(subsystem)
        self.isDLL = characteristics & 0x2000 != 0
        self.is64Bit = is64
        self.sections = sections
        self.directories = directories
        self.checksumOffset = optional + 64
        self.securityDirectoryOffset = directoriesStart + Self.directorySecurity * 8
        self.sizeOfHeaders = headers
        self.reader = reader
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    func directory(_ index: Int) -> DataDirectory? {
        index < directories.count && directories[index].isPresent ? directories[index] : nil
    }

    /// Whether the program is a .NET assembly (it needs a .NET runtime in the prefix).
    public var isDotNet: Bool { directory(Self.directoryCLR) != nil }

    /// File offset of a relative virtual address.
    func offset(ofRVA rva: Int) -> Int? {
        for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress + max(s.virtualSize, s.rawSize) {
            let delta = rva - s.virtualAddress
            guard delta < s.rawSize else { return nil }
            return s.rawOffset + delta
        }
        return rva < sizeOfHeaders ? rva : nil
    }

    /// The certificate table (its directory holds a file offset, not an RVA).
    var certificateTable: Range<Int>? {
        guard let d = directory(Self.directorySecurity), d.address + d.size <= reader.count else { return nil }
        return d.address..<(d.address + d.size)
    }

    /// Bytes appended after the image, where most installers keep their payload.
    /// The certificate table, which signing appends at the very end, is excluded.
    public var overlay: Range<Int>? {
        let imageEnd = sections.map { $0.rawOffset + $0.rawSize }.max() ?? sizeOfHeaders
        var end = reader.count
        if let cert = certificateTable, cert.upperBound >= end - 8, cert.lowerBound >= imageEnd { end = cert.lowerBound }
        return imageEnd < end ? imageEnd..<end : nil
    }

    // MARK: - Resources

    public struct Resource: Sendable, Equatable {
        public enum ID: Sendable, Hashable { case number(UInt32), name(String) }
        public var type: ID
        public var name: ID
        public var language: UInt32
        public var range: Range<Int>
    }

    public static let typeIcon = Resource.ID.number(3)
    public static let typeRCData = Resource.ID.number(10)
    public static let typeGroupIcon = Resource.ID.number(14)
    public static let typeVersion = Resource.ID.number(16)
    public static let typeManifest = Resource.ID.number(24)

    /// Every leaf of the resource tree (type → name → language), in file order.
    public func resources() -> [Resource] {
        guard let dir = directory(Self.directoryResource), let base = offset(ofRVA: dir.address) else { return [] }
        var found: [Resource] = []
        var visited = Set<Int>()

        func entries(at offset: Int) -> [(id: Resource.ID, target: Int, isDirectory: Bool)] {
            guard visited.insert(offset).inserted,  // a loop in a malformed tree ends here
                  let named = reader.u16(offset + 12), let numbered = reader.u16(offset + 14) else { return [] }
            var list: [(Resource.ID, Int, Bool)] = []
            for i in 0..<min(Int(named) + Int(numbered), 4096) {
                let e = offset + 16 + i * 8
                guard let nameField = reader.u32(e), let targetField = reader.u32(e + 4) else { break }
                let id: Resource.ID
                if nameField & 0x8000_0000 != 0 {
                    let at = base + Int(nameField & 0x7FFF_FFFF)
                    let length = Int(reader.u16(at) ?? 0)
                    id = .name(reader.utf16(at + 2, units: length) ?? "")
                } else {
                    id = .number(nameField)
                }
                list.append((id, base + Int(targetField & 0x7FFF_FFFF), targetField & 0x8000_0000 != 0))
            }
            return list
        }

        for type in entries(at: base) where type.isDirectory {
            for name in entries(at: type.target) where name.isDirectory {
                for language in entries(at: name.target) where !language.isDirectory {
                    guard let rva = reader.u32(language.target), let size = reader.u32(language.target + 4),
                          let start = offset(ofRVA: Int(rva)), start + Int(size) <= reader.count else { continue }
                    let lang: UInt32 = if case .number(let n) = language.id { n } else { 0 }
                    found.append(Resource(type: type.id, name: name.id, language: lang, range: start..<(start + Int(size))))
                }
            }
        }
        return found
    }

    func data(of resource: Resource) -> Data? {
        reader.bytes(resource.range.lowerBound, resource.range.count)
    }

    // MARK: Version information

    public struct VersionInfo: Sendable, Equatable {
        public var fileVersion: String?
        public var productVersion: String?
        /// StringFileInfo values of the first string table: ProductName, CompanyName,
        /// FileDescription, OriginalFilename, Comments, LegalCopyright…
        public var strings: [String: String]

        public subscript(_ key: String) -> String? {
            strings[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public func versionInfo() -> VersionInfo? {
        // Localized programs carry one version resource per language.
        let all = resources().filter { $0.type == Self.typeVersion }
        guard let resource = all.first(where: { $0.language == 0x0409 }) ?? all.first(where: { $0.language == 0 }) ?? all.first,
              let raw = data(of: resource) else { return nil }
        return Self.parseVersionInfo(raw)
    }

    /// VS_VERSIONINFO: nested blocks of { wLength, wValueLength, wType, key, pad,
    /// value, pad, children }, each aligned to 32 bits.
    static func parseVersionInfo(_ raw: Data) -> VersionInfo? {
        let r = ByteReader(raw)
        func align(_ x: Int) -> Int { (x + 3) & ~3 }

        struct Block { var key: String; var value: Range<Int>; var valueUnits: Int; var isText: Bool; var children: Range<Int> }
        func block(at offset: Int) -> Block? {
            guard let length = r.u16(offset).map(Int.init), length >= 6, offset + length <= r.count,
                  let valueLength = r.u16(offset + 2).map(Int.init), let type = r.u16(offset + 4),
                  let (key, units) = r.utf16z(offset + 6, limit: 64) else { return nil }
            let valueStart = align(offset + 6 + (units + 1) * 2)
            let valueBytes = type == 1 ? valueLength * 2 : valueLength
            let childrenStart = min(align(valueStart + valueBytes), offset + length)
            return Block(key: key, value: valueStart..<min(valueStart + valueBytes, offset + length), valueUnits: valueLength,
                         isText: type == 1, children: childrenStart..<(offset + length))
        }
        func children(_ range: Range<Int>) -> [Block] {
            var list: [Block] = []
            var at = range.lowerBound
            while at < range.upperBound, let b = block(at: at), let length = r.u16(at).map(Int.init) {
                list.append(b)
                at = align(at + length)
            }
            return list
        }

        guard let root = block(at: 0), root.key == "VS_VERSION_INFO" else { return nil }
        var info = VersionInfo(strings: [:])
        let fixed = root.value.lowerBound
        if root.value.count >= 52, r.u32(fixed) == 0xFEEF_04BD,
           let fileMS = r.u32(fixed + 8), let fileLS = r.u32(fixed + 12),
           let productMS = r.u32(fixed + 16), let productLS = r.u32(fixed + 20) {
            func dotted(_ ms: UInt32, _ ls: UInt32) -> String { "\(ms >> 16).\(ms & 0xFFFF).\(ls >> 16).\(ls & 0xFFFF)" }
            info.fileVersion = dotted(fileMS, fileLS)
            info.productVersion = dotted(productMS, productLS)
        }
        for child in children(root.children) where child.key == "StringFileInfo" {
            // Tables are keyed by language and code page ("040904b0"). Prefer US
            // English, then language-neutral, then whatever comes first.
            let tables = children(child.children)
            let preferred = ["0409", "0000", "0009"].lazy.compactMap { lang in
                tables.first { $0.key.lowercased().hasPrefix(lang) }
            }.first
            guard let table = preferred ?? tables.first else { continue }
            for entry in children(table.children) {
                let units = max(0, min(entry.valueUnits, entry.value.count / 2))
                guard units > 0, var text = r.utf16(entry.value.lowerBound, units: units) else { continue }
                if let nul = text.firstIndex(of: "\0") { text = String(text[..<nul]) }
                info.strings[entry.key] = text
            }
        }
        return info
    }

    // MARK: Manifest

    public func manifest() -> String? {
        guard let resource = resources().first(where: { $0.type == Self.typeManifest }),
              let raw = data(of: resource) else { return nil }
        var text = String(decoding: raw, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// `asInvoker`, `highestAvailable` or `requireAdministrator`.
    public static func executionLevel(inManifest manifest: String) -> String? {
        attribute("level", ofElement: "requestedExecutionLevel", in: manifest)
    }

    static func attribute(_ name: String, ofElement element: String, in xml: String) -> String? {
        let pattern = "<(?:\\w+:)?\(element)\\b[^>]*\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    // MARK: Icon

    /// The first icon group, rebuilt as a standalone `.ico` file.
    public func iconData() -> Data? {
        let all = resources()
        let icons = Dictionary(all.filter { $0.type == Self.typeIcon }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for group in all where group.type == Self.typeGroupIcon {
            guard let raw = data(of: group) else { continue }
            let g = ByteReader(raw)
            guard g.u16(0) == 0, g.u16(2) == 1, let count = g.u16(4).map(Int.init), count > 0 else { continue }
            var images: [(header: Data, image: Data)] = []
            for i in 0..<count {
                let e = 6 + i * 14
                guard let header = g.bytes(e, 12), let id = g.u16(e + 12),
                      let icon = icons[.number(UInt32(id))], let image = data(of: icon) else { continue }
                images.append((header, image))
            }
            guard !images.isEmpty else { continue }
            var ico = Data([0, 0, 1, 0, UInt8(images.count & 0xFF), UInt8(images.count >> 8)])
            var offset = 6 + images.count * 16
            for (header, image) in images {
                // GRPICONDIRENTRY's first 8 bytes match ICONDIRENTRY; replace the
                // resource size with the image's and the id with its file offset.
                ico.append(header.prefix(8))
                ico.append(contentsOf: withUnsafeBytes(of: UInt32(image.count).littleEndian, Array.init))
                ico.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init))
                offset += image.count
            }
            for (_, image) in images { ico.append(image) }
            return ico
        }
        return nil
    }
}
