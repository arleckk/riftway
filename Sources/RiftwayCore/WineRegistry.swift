import Foundation

/// Read-only view of one Wine registry hive file (`system.reg`, `user.reg`).
///
/// Only string values (`"x"` and `str(2):"x"`) are kept; dword, hex and other
/// typed values are skipped, including their `\`-continued lines. Key paths and
/// value names are compared case-insensitively, as on Windows.
public struct WineRegistry: Sendable {
    /// Lowercased key path → lowercased value name ("" is the default value) → value.
    public private(set) var keys: [String: [String: String]] = [:]

    public init(text: String) {
        var current: String?
        var continuing = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = Substring(rawLine)
            if continuing {
                continuing = line.hasSuffix("\\")
                continue
            }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let first = trimmed.first else { continue }
            switch first {
            case "[":
                if let path = Self.parseKeyHeader(trimmed) {
                    current = path.lowercased()
                    if keys[current!] == nil { keys[current!] = [:] }
                } else {
                    current = nil
                }
            case "\"", "@":
                guard let key = current else { continue }
                let (entry, needsContinuation) = Self.parseValueLine(trimmed)
                continuing = needsContinuation
                if let (name, value) = entry { keys[key, default: [:]][name.lowercased()] = value }
            default:
                continue
            }
        }
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    public func value(_ name: String, at path: String) -> String? {
        keys[path.lowercased()]?[name.lowercased()]
    }

    public func hasKey(_ path: String) -> Bool { keys[path.lowercased()] != nil }

    /// Names of the direct subkeys of `path`, lowercased.
    public func subkeys(of path: String) -> [String] {
        let prefix = path.lowercased() + "\\"
        var names = Set<String>()
        for key in keys.keys where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let name = rest.split(separator: "\\", maxSplits: 1).first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    // MARK: - Parsing

    /// `[Software\\Classes\\dsropen] 1755534398` → `Software\Classes\dsropen`.
    static func parseKeyHeader(_ line: Substring) -> String? {
        var chars = Array(line.utf16.dropFirst())
        // The key ends at the first unescaped `]`.
        var end: Int?
        var i = 0
        while i < chars.count {
            if chars[i] == 0x5C { i += 2; continue }  // backslash escape
            if chars[i] == 0x5D { end = i; break }
            i += 1
        }
        guard let end else { return nil }
        chars = Array(chars[..<end])
        return unescape(chars)
    }

    /// Returns the parsed (name, string value) when the value is a string, and
    /// whether the line continues on the next one.
    static func parseValueLine(_ line: Substring) -> ((String, String)?, Bool) {
        let utf16 = Array(line.utf16)
        var i = 0
        let name: String
        if utf16.first == 0x40 {  // @
            name = ""
            i = 1
        } else {
            guard let (parsed, next) = readQuoted(utf16, from: 0) else { return (nil, false) }
            name = parsed
            i = next
        }
        guard i < utf16.count, utf16[i] == 0x3D else { return (nil, false) }  // =
        i += 1
        let rest = String(decoding: utf16[i...], as: UTF16.self)
        if rest.hasPrefix("\"") {
            guard let (value, _) = readQuoted(utf16, from: i) else { return (nil, false) }
            return ((name, value), false)
        }
        // REG_EXPAND_SZ and REG_MULTI_SZ in Wine's text form: str(2):"..."
        if rest.hasPrefix("str("), let colon = rest.firstIndex(of: ":") {
            let offset = rest.utf16.distance(from: rest.utf16.startIndex, to: colon.samePosition(in: rest.utf16)!)
            if let (value, _) = readQuoted(utf16, from: i + offset + 1) { return ((name, value), false) }
            return (nil, false)
        }
        return (nil, rest.hasSuffix("\\"))
    }

    /// Reads a `"..."` string starting at `start` (the opening quote). Returns the
    /// unescaped string and the index just past the closing quote.
    static func readQuoted(_ chars: [UInt16], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == 0x22 else { return nil }
        var i = start + 1
        while i < chars.count {
            if chars[i] == 0x5C { i += 2; continue }
            if chars[i] == 0x22 { return (unescape(Array(chars[(start + 1)..<i])), i + 1) }
            i += 1
        }
        return nil
    }

    /// Wine's escapes: `\\`, `\"`, `\n`, `\r`, `\t`, `\a`, `\b`, `\e`, `\f`, `\v`,
    /// `\xHHHH` (up to four hex digits, UTF-16 code units) and octal `\NNN`.
    static func unescape(_ chars: [UInt16]) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(chars.count)
        var i = 0
        func isHex(_ c: UInt16) -> Bool { (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) }
        func hexValue(_ c: UInt16) -> UInt16 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10 }
        while i < chars.count {
            let c = chars[i]
            guard c == 0x5C, i + 1 < chars.count else { out.append(c); i += 1; continue }
            let e = chars[i + 1]
            i += 2
            switch e {
            case 0x6E: out.append(0x0A)  // n
            case 0x72: out.append(0x0D)  // r
            case 0x74: out.append(0x09)  // t
            case 0x61: out.append(0x07)  // a
            case 0x62: out.append(0x08)  // b
            case 0x65: out.append(0x1B)  // e
            case 0x66: out.append(0x0C)  // f
            case 0x76: out.append(0x0B)  // v
            case 0x78:  // x
                var value: UInt16 = 0
                var digits = 0
                while digits < 4, i < chars.count, isHex(chars[i]) {
                    value = value * 16 + hexValue(chars[i]); i += 1; digits += 1
                }
                out.append(digits == 0 ? 0x78 : value)
            case 0x30...0x37:  // octal
                var value: UInt16 = e - 0x30
                var digits = 1
                while digits < 3, i < chars.count, (0x30...0x37).contains(chars[i]) {
                    value = value * 8 + (chars[i] - 0x30); i += 1; digits += 1
                }
                out.append(value)
            default:
                out.append(e)  // \\ \" and anything unknown
            }
        }
        return String(decoding: out, as: UTF16.self)
    }
}
