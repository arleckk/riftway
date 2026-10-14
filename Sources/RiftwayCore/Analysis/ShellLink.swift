import Foundation

/// A Windows shortcut (`.lnk`, the MS-SHLLINK format): what an installer leaves
/// in the Start menu and on the desktop to say which programs it installed.
///
/// The target comes from LinkInfo's local base path (Wine's IShellLink writes
/// one for every path), then the environment variable block, then the ID list.
public struct ShellLink: Sendable, Equatable {
    /// Windows path of the target, such as `C:\Program Files\Game\Game.exe`.
    public var target: String?
    public var arguments: String?
    public var workingDirectory: String?
    public var iconLocation: String?
    public var iconIndex: Int32 = 0
    public var description: String?

    public enum ParseError: Error, Equatable { case notAShortcut, truncated }

    static let headerSize: UInt32 = 0x4C
    static let clsid: [UInt8] = [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]

    struct Flags: OptionSet {
        let rawValue: UInt32
        static let hasIDList = Flags(rawValue: 0x1)
        static let hasLinkInfo = Flags(rawValue: 0x2)
        static let hasName = Flags(rawValue: 0x4)
        static let hasRelativePath = Flags(rawValue: 0x8)
        static let hasWorkingDir = Flags(rawValue: 0x10)
        static let hasArguments = Flags(rawValue: 0x20)
        static let hasIconLocation = Flags(rawValue: 0x40)
        static let isUnicode = Flags(rawValue: 0x80)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let r = ByteReader(data)
        guard r.u32(0) == Self.headerSize, let id = r.bytes(4, 16), Array(id) == Self.clsid,
              let rawFlags = r.u32(0x14)
        else { throw ParseError.notAShortcut }
        let flags = Flags(rawValue: rawFlags)
        iconIndex = Int32(bitPattern: r.u32(0x38) ?? 0)
        var offset = Int(Self.headerSize)
        var idListTarget: String?
        if flags.contains(.hasIDList) {
            guard let size = r.u16(offset).map(Int.init) else { throw ParseError.truncated }
            idListTarget = Self.pathFromIDList(r, from: offset + 2, end: offset + 2 + size)
            offset += 2 + size
        }
        var linkInfoTarget: String?
        if flags.contains(.hasLinkInfo) {
            guard let size = r.u32(offset).map(Int.init), size >= 4 else { throw ParseError.truncated }
            linkInfoTarget = Self.linkInfoPath(r, at: offset)
            offset += size
        }
        let unicode = flags.contains(.isUnicode)
        func string(_ present: Flags) throws -> String? {
            guard flags.contains(present) else { return nil }
            guard let count = r.u16(offset).map(Int.init) else { throw ParseError.truncated }
            let value: String?
            if unicode {
                value = r.utf16(offset + 2, units: count)
            } else {
                value = r.bytes(offset + 2, count).map { String(decoding: $0, as: UTF8.self) }
            }
            guard let value else { throw ParseError.truncated }
            offset += 2 + count * (unicode ? 2 : 1)
            // Some writers count the terminating NUL.
            let trimmed = String(value.unicodeScalars.reversed().drop(while: { $0.value == 0 }).reversed().map(Character.init))
            return trimmed.isEmpty ? nil : trimmed
        }
        description = try string(.hasName)
        let relative = try string(.hasRelativePath)
        workingDirectory = try string(.hasWorkingDir)
        arguments = try string(.hasArguments)
        iconLocation = try string(.hasIconLocation)
        target = linkInfoTarget ?? Self.environmentTarget(r, from: offset) ?? idListTarget ?? relative
    }

    static func ansiz(_ r: ByteReader, _ offset: Int, limit: Int = 1024) -> String? {
        var bytes: [UInt8] = []
        var i = offset
        while bytes.count < limit, let b = r.u8(i) {
            if b == 0 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
            i += 1
        }
        return nil
    }

    /// LinkInfo: LocalBasePath (the Unicode copy when the header is 0x24 bytes or
    /// more) followed by CommonPathSuffix.
    static func linkInfoPath(_ r: ByteReader, at start: Int) -> String? {
        guard let headerSize = r.u32(start + 4), let flags = r.u32(start + 8), flags & 1 != 0,
              let baseOffset = r.u32(start + 16).map(Int.init), let suffixOffset = r.u32(start + 24).map(Int.init)
        else { return nil }
        var base: String?
        var suffix: String?
        if headerSize >= 0x24, let wideBase = r.u32(start + 28).map(Int.init), let wideSuffix = r.u32(start + 32).map(Int.init) {
            base = r.utf16z(start + wideBase)?.0
            suffix = r.utf16z(start + wideSuffix)?.0
        } else {
            base = ansiz(r, start + baseOffset)
            suffix = ansiz(r, start + suffixOffset)
        }
        guard var path = base, !path.isEmpty else { return nil }
        if let suffix, !suffix.isEmpty {
            if !path.hasSuffix("\\") { path += "\\" }
            path += suffix
        }
        return path
    }

    /// EnvironmentVariableDataBlock (0xA0000001): the target with variables, such
    /// as `%ProgramFiles%\Game\Game.exe`.
    static func environmentTarget(_ r: ByteReader, from start: Int) -> String? {
        var offset = start
        while let size = r.u32(offset).map(Int.init), size >= 8 {
            if r.u32(offset + 4) == 0xA000_0001, size >= 0x314 {
                let wide = r.utf16z(offset + 8 + 260, limit: 260)?.0 ?? ""
                let ansi = ansiz(r, offset + 8, limit: 260) ?? ""
                let value = wide.isEmpty ? ansi : wide
                return value.isEmpty ? nil : value
            }
            offset += size
        }
        return nil
    }

    /// Shell items: a volume item (`C:\`) then one file entry per path
    /// component, with the long name in its 0xBEEF0004 extension block.
    static func pathFromIDList(_ r: ByteReader, from start: Int, end: Int) -> String? {
        var offset = start
        var drive: String?
        var parts: [String] = []
        while offset + 2 <= end, let itemSize = r.u16(offset).map(Int.init), itemSize >= 3, offset + itemSize <= end {
            guard let type = r.u8(offset + 2) else { break }
            switch type & 0x70 {
            case 0x20:
                if let name = ansiz(r, offset + 3, limit: itemSize - 3), name.count >= 2 { drive = String(name.prefix(2)) }
            case 0x30:
                let short = ansiz(r, offset + 14, limit: max(0, itemSize - 14)) ?? ""
                parts.append(longName(r, item: offset, size: itemSize) ?? short)
            default:
                break
            }
            offset += itemSize
        }
        guard let drive, !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        return drive + "\\" + parts.joined(separator: "\\")
    }

    /// The long name in a file entry's 0xBEEF0004 block, whose offset is the
    /// item's last two bytes. Its position inside the block grows with the
    /// block version, so each known position is tried for a printable name.
    static func longName(_ r: ByteReader, item: Int, size: Int) -> String? {
        guard let blockOffset = r.u16(item + size - 2).map(Int.init), blockOffset > 0, blockOffset + 8 < size,
              r.u32(item + blockOffset + 4) == 0xBEEF_0004, let version = r.u16(item + blockOffset + 2)
        else { return nil }
        let candidates: [Int] = version >= 9 ? [0x2E, 0x2A] : version >= 7 ? [0x26, 0x2A] : [0x14]
        for candidate in candidates {
            let start = item + blockOffset + candidate
            guard start < item + size, let (name, _) = r.utf16z(start, limit: (item + size - start) / 2),
                  !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
            else { continue }
            return name
        }
        return nil
    }
}
