import Foundation

/// Font linking for Chinese, Japanese and Korean text, with the Mac's own fonts.
///
/// Windows UI fonts (Tahoma, behind "MS Shell Dlg", Segoe UI, Arial…) have no CJK
/// glyphs; Windows draws CJK text in them through `FontLink\SystemLink`, which
/// falls back to Gulim, MS Gothic or Microsoft YaHei. A bottle has none of those,
/// so a Korean installer shows boxes. Wine loads the Mac's system fonts through
/// CoreText and matches SystemLink entries by file name and family, so the
/// entries point at fonts every Mac has in `/System/Library/Fonts`.
public enum FontLinking {
    public struct Fallback: Sendable, Equatable {
        public var file: String
        /// The family as Wine names it; nil matches the file's first family
        /// (CoreText names some families differently, "Hiragino Sans W3"…).
        public var family: String?
        public var language: String
        /// For messages: the family, or the file.
        public var label: String { family ?? file }
    }

    /// In fallback order: Korean, Japanese, Simplified and Traditional Chinese.
    /// Han characters take the first font that has them, so a profile for a
    /// Japanese or Chinese game can reorder this list.
    public static let macFallbacks: [Fallback] = [
        Fallback(file: "AppleSDGothicNeo.ttc", family: "Apple SD Gothic Neo", language: "ko"),
        Fallback(file: "ヒラギノ角ゴシック W3.ttc", family: nil, language: "ja"),
        Fallback(file: "Hiragino Sans GB.ttc", family: nil, language: "zh-Hans"),
        Fallback(file: "STHeiti Light.ttc", family: "Heiti TC", language: "zh-Hant"),
    ]

    /// The Windows UI fonts programs draw dialogs and launchers with.
    public static let linkedFonts = [
        "Tahoma", "Microsoft Sans Serif", "Segoe UI", "Arial", "Verdana", "Lucida Sans Unicode",
        "Times New Roman", "Courier New",
    ]

    public static let key = #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#

    /// Fallbacks whose font file exists on this Mac.
    public static func available(_ fallbacks: [Fallback] = macFallbacks,
                                 fontsDirectory: URL = URL(fileURLWithPath: "/System/Library/Fonts")) -> [Fallback] {
        fallbacks.filter { FileManager.default.fileExists(atPath: fontsDirectory.appendingPathComponent($0.file).path) }
    }

    /// A `.reg` file (REGEDIT 5) with one REG_MULTI_SZ value per linked font.
    /// REG_MULTI_SZ is written as `hex(7)`: UTF-16LE strings, each NUL-terminated,
    /// then a final NUL. Write it with `registryFileData`: a version 5 file must be
    /// UTF-16LE with a BOM, or reg.exe reads `hex(7)` as ANSI and splits it at
    /// every zero byte.
    public static func registryFile(fallbacks: [Fallback]) -> String {
        let entries = fallbacks.map { fallback in fallback.family.map { "\(fallback.file),\($0)" } ?? fallback.file }
        var bytes: [UInt8] = []
        for entry in entries {
            for unit in entry.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            bytes += [0, 0]
        }
        bytes += [0, 0]
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
        var text = "Windows Registry Editor Version 5.00\r\n\r\n[\(key)]\r\n"
        for font in linkedFonts { text += "\"\(font)\"=hex(7):\(hex)\r\n" }
        return text
    }

    /// `registryFile` encoded as Windows writes .reg files: UTF-16LE with a BOM.
    public static func registryFileData(fallbacks: [Fallback]) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in registryFile(fallbacks: fallbacks).utf16 { data += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return data
    }
}

extension BottleSetup {
    /// Writes the bottle's CJK font links (`FontLinking`). Wine reads them when a
    /// session starts, so they apply to programs started afterwards.
    public func configureFontLinking(fallbacks: [FontLinking.Fallback] = FontLinking.available()) throws {
        guard !fallbacks.isEmpty else { return }
        let file = prefix.appendingPathComponent("drive_c/ProgramData/Riftway/fontlink.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FontLinking.registryFileData(fallbacks: fallbacks).write(to: file)
        let status = try ProcessRunner.run(plan("wine", ["reg.exe", "import", #"C:\ProgramData\Riftway\fontlink.reg"#]),
                                           log: logs.appendingPathComponent("registry.log"), timeout: 60)
        guard status == 0 else { throw Failure.step("reg import fontlink.reg", status: status) }
        try waitForServer()
    }
}
