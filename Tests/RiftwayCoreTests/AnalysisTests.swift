import Foundation
import Testing
@testable import RiftwayCore

// MARK: - Synthetic PE files

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func pad(to alignment: Int) { while count % alignment != 0 { append(0) } }
    mutating func utf16z(_ s: String) { for u in s.utf16 { le16(u) }; le16(0) }
    mutating func put32(_ v: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
}

struct TestResource {
    var type: UInt32
    var name: UInt32
    var language: UInt32 = 0x0409
    var data: Data
}

/// A PE32+ image with a `.text` section, an optional `.rsrc` section and an
/// optional overlay, laid out the way linkers do.
func makePE(dll: Bool = false, machine: UInt16 = 0x8664, subsystem: UInt16 = 2,
            resources: [TestResource] = [], overlay: Data = Data(), extraSection: String? = nil) -> Data {
    let fileAlign = 0x200, rsrcRVA = 0x2000
    var rsrc = resources.isEmpty ? Data() : buildResourceSection(resources, rva: rsrcRVA)
    rsrc.pad(to: fileAlign)
    var sections: [(String, Int, Int)] = [(".text", 0x1000, 0x200)]  // name, rva, raw size
    if !rsrc.isEmpty { sections.append((".rsrc", rsrcRVA, rsrc.count)) }
    if let extraSection { sections.append((extraSection, 0x8000, 0x200)) }

    var pe = Data(count: 0x80)
    pe[0] = 0x4D; pe[1] = 0x5A
    pe.put32(0x80, at: 0x3C)
    pe.append(contentsOf: [0x50, 0x45, 0, 0])
    pe.le16(machine); pe.le16(UInt16(sections.count)); pe.le32(0); pe.le32(0); pe.le32(0)
    pe.le16(240); pe.le16(dll ? 0x2022 : 0x0022)
    // Optional header (PE32+).
    let optional = pe.count
    pe.le16(0x20B)
    pe.append(Data(count: 54))           // linker, sizes, entry, base, alignments, versions
    pe.le32(0x9000); pe.le32(UInt32(fileAlign))  // SizeOfImage, SizeOfHeaders
    pe.le32(0); pe.le16(subsystem); pe.le16(0)   // CheckSum, Subsystem, DllCharacteristics
    pe.append(Data(count: 32 + 4))       // stack/heap reserve/commit, loader flags
    pe.le32(16)
    for i in 0..<16 {
        if i == 2, !rsrc.isEmpty { pe.le32(UInt32(rsrcRVA)); pe.le32(UInt32(rsrc.count)) } else { pe.le32(0); pe.le32(0) }
    }
    precondition(pe.count == optional + 240)
    var raw = fileAlign
    for (name, rva, size) in sections {
        var n = Data(name.utf8); n.append(Data(count: 8 - n.count)); pe.append(n)
        pe.le32(UInt32(size)); pe.le32(UInt32(rva)); pe.le32(UInt32(size)); pe.le32(UInt32(raw))
        pe.append(Data(count: 16))
        raw += size
    }
    pe.pad(to: fileAlign)
    pe.append(Data(count: 0x200))  // .text
    pe.append(rsrc)
    if extraSection != nil { pe.append(Data(count: 0x200)) }
    pe.append(overlay)
    return pe
}

/// type → name → language directories, data entries, then the data.
func buildResourceSection(_ items: [TestResource], rva: Int) -> Data {
    let types = Dictionary(grouping: items, by: \.type).sorted { $0.key < $1.key }
    var dirs = Data(), entries = Data(), blobs = Data()
    // Sizes first, so every offset is known while writing.
    let typeDirSize = 16 + 8 * types.count
    var nameDirsSize = 0, langDirsSize = 0
    for (_, group) in types {
        let names = Dictionary(grouping: group, by: \.name)
        nameDirsSize += 16 + 8 * names.count
        for (_, byName) in names { langDirsSize += 16 + 8 * byName.count }
    }
    let entriesStart = typeDirSize + nameDirsSize + langDirsSize
    let blobsStart = entriesStart + 16 * items.count

    func header(_ count: Int) -> Data { var d = Data(count: 12); d.le16(0); d.le16(UInt16(count)); return d }
    var root = header(types.count)
    var nameDirs = Data(), langDirs = Data()
    var nextName = typeDirSize, nextLang = typeDirSize + nameDirsSize
    for (type, group) in types {
        root.le32(type); root.le32(0x8000_0000 | UInt32(nextName))
        let names = Dictionary(grouping: group, by: \.name).sorted { $0.key < $1.key }
        var nameDir = header(names.count)
        for (name, byName) in names {
            nameDir.le32(name); nameDir.le32(0x8000_0000 | UInt32(nextLang))
            var langDir = header(byName.count)
            for item in byName {
                langDir.le32(item.language); langDir.le32(UInt32(entriesStart + entries.count))
                entries.le32(UInt32(rva + blobsStart + blobs.count)); entries.le32(UInt32(item.data.count)); entries.le32(0); entries.le32(0)
                blobs.append(item.data); blobs.pad(to: 4)
            }
            langDirs.append(langDir); nextLang += langDir.count
        }
        nameDirs.append(nameDir); nextName += nameDir.count
    }
    dirs.append(root); dirs.append(nameDirs); dirs.append(langDirs)
    return dirs + entries + blobs
}

/// VS_VERSIONINFO with a fixed file info and one string table.
func versionResource(_ strings: [String: String], table: String = "040904b0") -> Data {
    func block(_ key: String, value: Data, valueLength: Int, text: Bool, children: [Data] = []) -> Data {
        var d = Data()
        d.le16(0); d.le16(UInt16(valueLength)); d.le16(text ? 1 : 0)
        d.utf16z(key); d.pad(to: 4)
        d.append(value); d.pad(to: 4)
        for (i, child) in children.enumerated() { d.append(child); if i < children.count - 1 { d.pad(to: 4) } }
        d[0] = UInt8(d.count & 0xFF); d[1] = UInt8(d.count >> 8)
        return d
    }
    let entries = strings.sorted { $0.key < $1.key }.map { key, value -> Data in
        var v = Data(); v.utf16z(value)
        return block(key, value: v, valueLength: value.utf16.count + 1, text: true)
    }
    let stringTable = block(table, value: Data(), valueLength: 0, text: true, children: entries)
    let fileInfo = block("StringFileInfo", value: Data(), valueLength: 0, text: true, children: [stringTable])
    var fixed = Data()
    fixed.le32(0xFEEF_04BD); fixed.le32(0x0001_0000)
    fixed.le32(0x0002_0003); fixed.le32(0x0004_0005)  // file 2.3.4.5
    fixed.le32(0x0002_0003); fixed.le32(0x0004_0005)
    fixed.append(Data(count: 28))
    return block("VS_VERSION_INFO", value: fixed, valueLength: 52, text: false, children: [fileInfo])
}

let adminManifest = Data(#"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
<assemblyIdentity version="1.0.0.0" processorArchitecture="*" name="Nullsoft.NSIS.exehead" type="win32"/>
<trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
<requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
</requestedPrivileges></security></trustInfo></assembly>
"""#.utf8)

func iconResources() -> [TestResource] {
    let image = Data(repeating: 0xAB, count: 40)
    var group = Data(); group.le16(0); group.le16(1); group.le16(1)
    group.append(contentsOf: [16, 16, 0, 0]); group.le16(1); group.le16(32); group.le32(UInt32(image.count)); group.le16(7)
    return [TestResource(type: 3, name: 7, data: image), TestResource(type: 14, name: 1, data: group)]
}

func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-analysis-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - Tests

@Suite struct PEFileTests {
    @Test func readsHeadersAndResources() throws {
        let data = makePE(resources: [
            TestResource(type: 16, name: 1, data: versionResource(["ProductName": "Digimon SuperRumble", "CompanyName": "MoveInteractive",
                                                                     "ProductVersion": "1.2.3"])),
            TestResource(type: 24, name: 1, data: adminManifest),
        ] + iconResources())
        let pe = try PEFile(data: data)
        #expect(pe.machine == .x64)
        #expect(pe.subsystem == .gui)
        #expect(!pe.isDLL)
        #expect(pe.sections.map(\.name) == [".text", ".rsrc"])
        let version = try #require(pe.versionInfo())
        #expect(version["ProductName"] == "Digimon SuperRumble")
        #expect(version["CompanyName"] == "MoveInteractive")
        #expect(version.fileVersion == "2.3.4.5")
        #expect(PEFile.executionLevel(inManifest: try #require(pe.manifest())) == "requireAdministrator")
        let ico = try #require(pe.iconData())
        #expect(ico.prefix(6) == Data([0, 0, 1, 0, 1, 0]))
        #expect(ico.count == 6 + 16 + 40)
        #expect(pe.overlay == nil)
    }

    @Test func prefersEnglishVersionResource() throws {
        let data = makePE(resources: [
            TestResource(type: 16, name: 1, language: 0x0401, data: versionResource(["ProductName": "واين"], table: "040104b0")),
            TestResource(type: 16, name: 1, language: 0x0409, data: versionResource(["ProductName": "Wine"])),
        ])
        #expect(try PEFile(data: data).versionInfo()?["ProductName"] == "Wine")
    }

    @Test func rejectsWhatIsNotPE() {
        #expect(throws: PEFile.Failure.notPE) { try PEFile(data: Data("hello".utf8)) }
        var truncated = makePE()
        truncated = truncated.prefix(0x90)
        #expect(throws: PEFile.Failure.truncated) { try PEFile(data: truncated) }
    }

    @Test func survivesGarbageResourceTrees() throws {
        // A resource directory that points at itself must not loop.
        var looping = Data(count: 12); looping.le16(0); looping.le16(1)
        looping.le32(16); looping.le32(0x8000_0000)
        let pe = try PEFile(data: makePE(resources: [TestResource(type: 99, name: 1, data: Data())]))
        _ = pe.resources()
        #expect(PEFile.parseVersionInfo(Data([1, 2, 3])) == nil)
    }
}

@Suite struct InstallerDetectionTests {
    @Test func detectsNSISFromItsOverlay() throws {
        var overlay = Data([0xEF, 0xBE, 0xAD, 0xDE]); overlay.append(Data("NullsoftInst".utf8)); overlay.append(Data(count: 64))
        let url = try temporaryFile("dsr_setup.exe", makePE(resources: [TestResource(type: 24, name: 1, data: adminManifest)], overlay: overlay))
        let report = InstallerAnalyzer.analyze(url)
        #expect(report.kind == .installer(.nsis))
        #expect(report.executionLevel == "requireAdministrator")
        #expect(report.signature == .unsigned)
        #expect(report.architecture == "x64")
    }

    @Test func detectsWiXBurnBySection() throws {
        let url = try temporaryFile("vc_redist.exe", makePE(extraSection: ".wixburn"))
        #expect(InstallerAnalyzer.analyze(url).kind == .installer(.wixBurn))
    }

    @Test func detectsInnoAndItsCompanions() throws {
        let url = try temporaryFile("setup_game_1.0.exe", makePE(overlay: Data("Inno Setup Setup Data (6.3.0)".utf8)))
        let folder = url.deletingLastPathComponent()
        for name in ["setup_game_1.0-1.bin", "setup_game_1.0-2.bin", "unrelated.bin", "readme.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        let report = InstallerAnalyzer.analyze(url)
        #expect(report.kind == .installer(.innoSetup))
        #expect(report.companions.map(\.lastPathComponent) == ["setup_game_1.0-1.bin", "setup_game_1.0-2.bin"])
    }

    @Test func classifiesProgramsAndUnsupportedFiles() throws {
        let game = try temporaryFile("Game.exe", makePE(resources: [
            TestResource(type: 16, name: 1, data: versionResource(["ProductName": "Some Game", "FileDescription": "Some Game"])),
        ]))
        let report = InstallerAnalyzer.analyze(game)
        #expect(report.kind == .portable)
        #expect(report.displayName == "Some Game")
        #expect(InstallerAnalyzer.analyze(try temporaryFile("x.dll", makePE(dll: true))).kind == .unsupported(.library))
        #expect(InstallerAnalyzer.analyze(try temporaryFile("d.sys", makePE(subsystem: 1))).kind == .unsupported(.driver))
        #expect(InstallerAnalyzer.analyze(try temporaryFile("a.exe", makePE(machine: 0xAA64))).kind == .unsupported(.architecture("ARM64")))
        #expect(InstallerAnalyzer.analyze(try temporaryFile("n.exe", Data("not a program".utf8))).kind == .unsupported(.notWindowsProgram))
        // A plain program named like an installer still counts as one.
        #expect(InstallerAnalyzer.analyze(try temporaryFile("GameSetup.exe", makePE())).kind == .installer(.unknown))
    }
}

@Suite struct MSITests {
    /// An OLE property set with a code page and VT_LPSTR properties.
    func summaryStream(_ props: [UInt32: String]) -> Data {
        var section = Data()
        let all: [(UInt32, Data)] = [(1, { var d = Data(); d.le32(2); d.le16(65001); d.le16(0); return d }())]
            + props.sorted { $0.key < $1.key }.map { id, text in
                var d = Data(); d.le32(30); let bytes = Data(text.utf8) + Data([0]); d.le32(UInt32(bytes.count)); d.append(bytes); d.pad(to: 4)
                return (id, d)
            }
        var offset = 8 + all.count * 8
        var index = Data(), values = Data()
        for (id, value) in all { index.le32(id); index.le32(UInt32(offset)); values.append(value); offset += value.count }
        section.le32(UInt32(offset)); section.le32(UInt32(all.count)); section.append(index); section.append(values)
        var stream = Data(); stream.le16(0xFFFE); stream.le16(0); stream.le32(0x0002_0006)
        stream.append(Data(count: 16)); stream.le32(1)
        stream.append(Data(count: 16)); stream.le32(48)
        stream.append(section)
        return stream
    }

    @Test func parsesSummaryInformation() throws {
        let summary = try #require(MSISummary.parse(summaryStream([3: "Epic Games Launcher", 4: "Epic Games, Inc.", 7: "Intel;1033"])))
        #expect(summary.subject == "Epic Games Launcher")
        #expect(summary.author == "Epic Games, Inc.")
        #expect(summary.platform == "Intel")
    }

    @Test func readsAStreamFromACompoundFile() throws {
        // One FAT sector, one directory sector, and a stream above the mini
        // stream cutoff so it lives in regular sectors.
        let payload = summaryStream([3: "Café Launcher", 4: "Studio", 7: "x64;1033"]) + Data(count: 4096)
        let sectors = (payload.count + 511) / 512
        var file = Data(count: 512)
        file.replaceSubrange(0..<8, with: CompoundFile.magic)
        func at(_ o: Int, _ v: UInt32) { file.put32(v, at: o) }
        file[0x1A] = 0x3E; file[0x1C] = 0xFE; file[0x1D] = 0xFF  // minor, version 3, byte order
        file[0x1E] = 9; file[0x20] = 6
        at(0x2C, 1); at(0x30, 1); at(0x38, 4096); at(0x3C, 0xFFFF_FFFE); at(0x40, 0); at(0x44, 0xFFFF_FFFE); at(0x48, 0)
        for i in 0..<109 { at(0x4C + i * 4, 0xFFFF_FFFF) }
        at(0x4C, 0)                                         // FAT lives in sector 0
        var fat = Data(); fat.le32(0xFFFF_FFFD); fat.le32(0xFFFF_FFFE)  // sector 0 FAT, sector 1 directory
        for s in 0..<sectors { fat.le32(s == sectors - 1 ? 0xFFFF_FFFE : UInt32(3 + s)) }
        fat.append(Data(repeating: 0xFF, count: 512 - fat.count))
        func entry(_ name: String, type: UInt8, start: UInt32, size: UInt32) -> Data {
            var d = Data(); for u in name.utf16 { d.le16(u) }; d.le16(0); d.append(Data(count: 64 - d.count))
            d.le16(UInt16((name.utf16.count + 1) * 2)); d.append(type); d.append(Data(count: 49))
            d.le32(start); d.le32(size); d.le32(0)
            return d
        }
        var directory = entry("Root Entry", type: 5, start: 0xFFFF_FFFE, size: 0)
        directory.append(entry("\u{5}SummaryInformation", type: 2, start: 2, size: UInt32(payload.count)))
        directory.append(Data(count: 512 - directory.count))
        file.append(fat); file.append(directory); file.append(payload)
        file.append(Data(count: sectors * 512 - payload.count))

        let url = try temporaryFile("launcher.msi", file)
        let report = InstallerAnalyzer.analyze(url)
        #expect(report.kind == .installer(.msi))
        #expect(report.product == "Café Launcher")
        #expect(report.company == "Studio")
        #expect(report.architecture == "x64")
        #expect(report.signature == .unsigned)
    }
}

@Suite struct DERTests {
    @Test func readsLengths() {
        #expect(DER.elementLength([0x30, 0x05]) == 7)
        #expect(DER.elementLength([0x30, 0x82, 0x1E, 0x30]) == 0x1E30 + 4)
        #expect(DER.elementLength([0x30]) == nil)
        var der = DER([0x30, 0x03, 0x02, 0x01, 0x07, 0x04, 0x00])
        #expect(der.next(tag: 0x30) == [0x02, 0x01, 0x07])
        #expect(der.next(tag: 0x04) == [])
        #expect(der.next(tag: 0x04) == nil)
    }
}
