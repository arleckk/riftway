import Foundation

/// Bounds-checked little-endian reads over a file's bytes. Every read returns nil
/// past the end, so malformed or truncated files fail soft instead of trapping.
struct ByteReader: Sendable {
    let data: Data

    init(_ data: Data) {
        // Work with zero-based indices whatever slice we were given.
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
        return value
    }

    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    func bytes(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }

    /// UTF-16LE text of `length` code units at `offset`.
    func utf16(_ offset: Int, units length: Int) -> String? {
        guard let raw = bytes(offset, length * 2) else { return nil }
        let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    /// A NUL-terminated UTF-16LE string starting at `offset`, at most `limit` units.
    func utf16z(_ offset: Int, limit: Int = 1024) -> (String, units: Int)? {
        var units: [UInt16] = []
        var i = offset
        while units.count < limit, let unit = u16(i) {
            if unit == 0 { return (String(decoding: units, as: UTF16.self), units.count) }
            units.append(unit)
            i += 2
        }
        return nil
    }

    func contains(_ needle: Data, in range: Range<Int>) -> Bool {
        let clamped = max(0, range.lowerBound)..<min(data.count, range.upperBound)
        guard !clamped.isEmpty else { return false }
        return data.range(of: needle, in: clamped) != nil
    }
}
