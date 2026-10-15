import Foundation
import Testing
@testable import RiftwayCore

@Suite struct BottleLocationTests {
    /// A home and a folder outside it that stands for another disk.
    private func setUp() throws -> (Library, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-locations-\(UUID().uuidString)")
        let home = RiftwayHome(root: base.appendingPathComponent("home"), bridges: base.appendingPathComponent("bridges"))
        let disk = base.appendingPathComponent("Games", isDirectory: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        return (Library(home: home), disk, base)
    }

    @discardableResult
    private func bottle(_ id: String, _ name: String, in folder: URL, library: Library) throws -> URL {
        let root = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prefix/dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("prefix/dosdevices/c:").path, withDestinationPath: "../drive_c")
        FileManager.default.createFile(atPath: root.appendingPathComponent("prefix/system.reg").path, contents: Data(count: 4096))
        try library.save(BottleRecord(name: name, runtimeVersion: "rw-1", created: Date(), options: GameOptions()), in: root)
        try library.save(Game(id: id, name: name), in: root)
        return root
    }

    @Test func aChosenFolderGetsARiftwayFolderUnlessItIsOne() throws {
        let (_, disk, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = BottleLocations.root(forChosen: disk)
        #expect(root.lastPathComponent == "Riftway")
        #expect(BottleLocations.root(forChosen: root) == root)
        #expect(BottleLocations.problem(for: root) == nil)
        // Someone else's Riftway folder is not taken over.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data())
        #expect(BottleLocations.problem(for: root) == .notEmpty)
        try BottleLocations.prepare(root)
        #expect(BottleLocations.problem(for: root) == nil)
    }

    @Test func newGamesGoWhereSettingsSayWithAnIdFreeEverywhere() throws {
        let (library, disk, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = library.home
        try bottle("steam", "Steam", in: home.bottles, library: library)
        let root = BottleLocations.root(forChosen: disk)
        try home.addLocation(root, install: true)
        #expect(home.installFolder == root)
        #expect(home.newBottleRoot(for: "Steam").path == root.appendingPathComponent("steam-2").path)
        // Back home.
        try home.addLocation(home.bottles, install: true)
        #expect(home.installFolder == home.bottles)
        #expect(home.locations().folders.map(\.path) == [root.path])
    }

    @Test func aDisconnectedDiskStillSaysWhatItHolds() throws {
        let (library, disk, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = library.home
        let root = BottleLocations.root(forChosen: disk)
        try home.addLocation(root, install: true)
        try bottle("elden-ring", "ELDEN RING", in: root, library: library)
        try bottle("steam", "Steam", in: home.bottles, library: library)
        #expect(Set(library.entries().map(\.id)) == ["elden-ring", "steam"])
        #expect(library.disconnectedFolders().isEmpty)
        // Unplugged: its games leave the list but are remembered, their ids stay
        // taken and no folder is made in the disk's place.
        try FileManager.default.removeItem(at: disk)
        #expect(library.entries().map(\.id) == ["steam"])
        #expect(library.disconnectedFolders().map(\.games) == [["elden-ring": "ELDEN RING"]])
        #expect(home.installFolderIsMissing)
        #expect(home.newBottleRoot(for: "Elden Ring").lastPathComponent == "elden-ring-2")
        #expect(!FileManager.default.fileExists(atPath: disk.path))
    }

    @Test func movingOnTheSameDiskIsARename() throws {
        let (library, disk, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = library.home
        try bottle("steam", "Steam", in: home.bottles, library: library)
        let entry = try #require(library.entries().first)
        let secrets = entry.secrets.directory
        let root = BottleLocations.root(forChosen: disk)
        let moved = try BottleMove.move(entry, to: root, home: home)
        #expect(moved == root.appendingPathComponent("steam"))
        #expect(!FileManager.default.fileExists(atPath: entry.root.path))
        let after = try #require(library.entries().first)
        #expect(after.root.standardizedFileURL == moved)
        #expect(after.secrets.directory == secrets)
        #expect(home.locations().folders.first?.games == ["steam": "Steam"])
        #expect(throws: BottleMove.Failure.alreadyThere) { try BottleMove.move(after, to: root, home: home) }
        // And back.
        try BottleMove.move(after, to: home.bottles, home: home)
        #expect(library.entries().first?.root.deletingLastPathComponent().standardizedFileURL == home.bottles.standardizedFileURL)
        #expect(home.locations().folders.first?.games == [:])
    }

    @Test func theCopyBetweenDisksKeepsTheBottleAsItIs() throws {
        let (library, disk, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try bottle("steam", "Steam", in: library.home.bottles, library: library)
        FileManager.default.createFile(atPath: source.appendingPathComponent("prefix/big.bin").path, contents: Data(count: 3_000_000))
        let target = disk.appendingPathComponent("steam")
        let fractions = Fractions()
        try BottleMove.copy(source, to: target, bytes: BottleMove.size(of: source).bytes, progress: { fractions.add($0) }, isCancelled: { false })
        #expect(BottleMove.size(of: target) == BottleMove.size(of: source))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("prefix/dosdevices/c:").path) == "../drive_c")
        #expect(fractions.last ?? 0 > 0.99)
        #expect(throws: BottleMove.Failure.cancelled) {
            try BottleMove.copy(source, to: disk.appendingPathComponent("again"), bytes: 1, progress: { _ in }, isCancelled: { true })
        }
    }

    private final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ value: Double) { lock.withLock { values.append(value) } }
        var last: Double? { lock.withLock { values.last } }
    }
}
