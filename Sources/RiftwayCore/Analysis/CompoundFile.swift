import Foundation

/// Reads streams from a Compound File Binary container (the format of `.msi`),
/// enough to get an installer's Summary Information.
struct CompoundFile {
    static let magic = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    enum Failure: Error { case notCompoundFile, malformed }

    private let r: ByteReader
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let entries: [(name: String, type: UInt8, start: UInt32, size: Int)]
    private let miniStream: Data

    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let maxChain = 1 << 20

    init(data: Data) throws(Failure) {
        let r = ByteReader(data)
        guard r.bytes(0, 8) == Self.magic else { throw .notCompoundFile }
        guard let sectorShift = r.u16(0x1E), sectorShift == 9 || sectorShift == 12,
              let miniShift = r.u16(0x20), miniShift == 6,
              let fatCount = r.u32(0x2C), let firstDirectory = r.u32(0x30), let cutoff = r.u32(0x38),
              let firstMiniFAT = r.u32(0x3C), let miniFATCount = r.u32(0x40),
              var difatSector = r.u32(0x44), let difatCount = r.u32(0x48) else { throw .malformed }
        self.r = r
        sectorSize = 1 << Int(sectorShift)
        miniSectorSize = 1 << Int(miniShift)
        miniCutoff = Int(cutoff)
        let size = sectorSize
        func sectorOffset(_ n: UInt32) -> Int { (Int(n) + 1) * size }

        // FAT sector numbers: 109 in the header, the rest in the DIFAT chain.
        var fatSectors: [UInt32] = (0..<109).compactMap { r.u32(0x4C + $0 * 4) }.filter { $0 < 0xFFFF_FFFA }
        var difatLeft = Int(difatCount)
        while difatLeft > 0, difatSector < 0xFFFF_FFFA {
            let base = sectorOffset(difatSector)
            let perSector = size / 4 - 1
            for i in 0..<perSector { if let n = r.u32(base + i * 4), n < 0xFFFF_FFFA { fatSectors.append(n) } }
            guard let next = r.u32(base + perSector * 4) else { throw .malformed }
            difatSector = next
            difatLeft -= 1
        }
        guard fatSectors.count >= Int(fatCount) else { throw .malformed }
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * size / 4)
        for s in fatSectors.prefix(Int(fatCount)) {
            let base = sectorOffset(s)
            for i in 0..<(size / 4) { fat.append(r.u32(base + i * 4) ?? Self.endOfChain) }
        }
        self.fat = fat

        func chain(_ start: UInt32, in table: [UInt32]) throws(Failure) -> [UInt32] {
            var list: [UInt32] = []
            var n = start
            while n < 0xFFFF_FFFA {
                guard Int(n) < table.count, list.count < Self.maxChain else { throw .malformed }
                list.append(n)
                n = table[Int(n)]
            }
            return list
        }
        func read(_ start: UInt32) throws(Failure) -> Data {
            var out = Data()
            for s in try chain(start, in: fat) {
                guard let bytes = r.bytes(sectorOffset(s), size) else { throw .malformed }
                out.append(bytes)
            }
            return out
        }

        let directory = ByteReader(try read(firstDirectory))
        var entries: [(String, UInt8, UInt32, Int)] = []
        for i in 0..<(directory.count / 128) {
            let e = i * 128
            guard let nameBytes = directory.u16(e + 64).map(Int.init), let type = directory.u8(e + 66),
                  let start = directory.u32(e + 116), let size = directory.u64(e + 120) else { continue }
            let units = max(0, min(32, nameBytes / 2) - 1)
            let name = directory.utf16(e, units: units) ?? ""
            entries.append((name, type, start, Int(clamping: sectorShift == 9 ? size & 0xFFFF_FFFF : size)))
        }
        self.entries = entries

        var miniFAT: [UInt32] = []
        if miniFATCount > 0 {
            let raw = ByteReader(try read(firstMiniFAT))
            miniFAT = (0..<(raw.count / 4)).compactMap { raw.u32($0 * 4) }
        }
        self.miniFAT = miniFAT
        if let root = entries.first(where: { $0.1 == 5 }) {
            miniStream = try read(root.2)
        } else {
            miniStream = Data()
        }
    }

    func hasStream(named name: String) -> Bool { entries.contains { $0.type == 2 && $0.name == name } }

    /// A stream's bytes by its directory name, or nil when absent.
    func stream(named name: String) -> Data? {
        guard let entry = entries.first(where: { $0.type == 2 && $0.name == name }) else { return nil }
        var out = Data()
        var n = entry.start
        var guardCount = 0
        if entry.size < miniCutoff {
            let mini = ByteReader(miniStream)
            while n < 0xFFFF_FFFA, out.count < entry.size, Int(n) < miniFAT.count, guardCount < Self.maxChain {
                guard let bytes = mini.bytes(Int(n) * miniSectorSize, miniSectorSize) else { return nil }
                out.append(bytes)
                n = miniFAT[Int(n)]
                guardCount += 1
            }
        } else {
            while n < 0xFFFF_FFFA, out.count < entry.size, Int(n) < fat.count, guardCount < Self.maxChain {
                guard let bytes = r.bytes((Int(n) + 1) * sectorSize, sectorSize) else { return nil }
                out.append(bytes)
                n = fat[Int(n)]
                guardCount += 1
            }
        }
        return out.count >= entry.size ? out.prefix(entry.size) : nil
    }
}

/// The Summary Information property set an `.msi` carries.
public struct MSISummary: Sendable, Equatable {
    /// PIDSI_TITLE, usually "Installation Database".
    public var title: String?
    /// PIDSI_SUBJECT: the product name.
    public var subject: String?
    /// PIDSI_AUTHOR: the manufacturer.
    public var author: String?
    public var comments: String?
    /// PIDSI_TEMPLATE: "Intel;1033", "x64;1033", "Arm64;1033"…
    public var template: String?
    /// PIDSI_APPNAME: the tool that built the package.
    public var creatingApplication: String?

    public var platform: String? { template?.split(separator: ";").first.map(String.init) }

    static func read(from file: CompoundFile) -> MSISummary? {
        file.stream(named: "\u{5}SummaryInformation").flatMap(parse)
    }

    /// OLE property set: header, one FMTID/offset pair, then a section of
    /// (property id, offset) pairs. Strings are VT_LPSTR in the set's code page.
    static func parse(_ stream: Data) -> MSISummary? {
        let r = ByteReader(stream)
        guard r.u16(0) == 0xFFFE, let sets = r.u32(24), sets >= 1, let section = r.u32(44).map(Int.init),
              let count = r.u32(section + 4) else { return nil }
        var props: [UInt32: Int] = [:]
        for i in 0..<min(Int(count), 256) {
            guard let id = r.u32(section + 8 + i * 8), let offset = r.u32(section + 12 + i * 8) else { break }
            props[id] = section + Int(offset)
        }
        var codepage: UInt32 = 1252
        if let at = props[1], r.u32(at) == 2, let value = r.u16(at + 4) { codepage = UInt32(value) }  // VT_I2
        let encoding: String.Encoding = {
            if codepage == 65001 { return .utf8 }
            let cf = CFStringConvertWindowsCodepageToEncoding(codepage)
            return cf == kCFStringEncodingInvalidId ? .windowsCP1252 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }()
        func string(_ id: UInt32) -> String? {
            guard let at = props[id], r.u32(at) == 30, let length = r.u32(at + 4).map(Int.init),
                  length > 0, length < 65536, let raw = r.bytes(at + 8, length) else { return nil }
            let text = String(data: raw.prefix { $0 != 0 }, encoding: encoding) ?? String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return MSISummary(title: string(2), subject: string(3), author: string(4), comments: string(6),
                          template: string(7), creatingApplication: string(18))
    }
}
