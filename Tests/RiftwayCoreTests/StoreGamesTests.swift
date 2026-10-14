import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RiftwayCore

@Suite struct StoreGamesTests {
    @Test func readsValveKeyValues() {
        let text = #"""
        "AppState"
        {
            "appid"     "945360"
            "name"      "Among Us"   // a comment
            "installdir"  "Among Us"
            "UserConfig" { "language" "english" }
            "path" "C:\\Program Files (x86)\\Steam"
        }
        """#
        let state = ValveKeyValues.parse(text)["appstate"]
        #expect(state?["appid"]?.string == "945360")
        #expect(state?["name"]?.string == "Among Us")
        #expect(state?["UserConfig"]?["language"]?.string == "english")
        #expect(state?["path"]?.string == #"C:\Program Files (x86)\Steam"#)
    }

    /// A Riftway home with a Steam bottle: Steam's library, one game installed,
    /// one redistributable, one game still downloading.
    private func steamHome() throws -> (Library, LibraryEntry, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-store-\(UUID().uuidString)")
        let home = RiftwayHome(root: base.appendingPathComponent("home"), bridges: base.appendingPathComponent("bridges"))
        let library = Library(home: home)
        let root = home.bottles.appendingPathComponent("steam")
        let steam = root.appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam")
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Among Us/Among Us_Data"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: apps.appendingPathComponent("common/Among Us/Among Us.exe").path, contents: Data(count: 64))
        FileManager.default.createFile(atPath: apps.appendingPathComponent("common/Among Us/UnityCrashHandler64.exe").path, contents: Data(count: 128))
        func manifest(_ id: String, _ name: String, _ dir: String, flags: Int) throws {
            try #"""
            "AppState" { "appid" "\#(id)" "name" "\#(name)" "installdir" "\#(dir)" "StateFlags" "\#(flags)" }
            """#.write(to: apps.appendingPathComponent("appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        try manifest("945360", "Among Us", "Among Us", flags: 4)
        try manifest("228980", "Steamworks Common Redistributables", "Steamworks Shared", flags: 4)
        try manifest("1", "Downloading", "Downloading", flags: 1026)
        let cover = steam.appendingPathComponent("appcache/librarycache/945360")
        try FileManager.default.createDirectory(at: cover, withIntermediateDirectories: true)
        try jpeg().write(to: cover.appendingPathComponent("library_600x900.jpg"))
        try library.save(BottleRecord(name: "Steam", runtimeVersion: "rw-1", created: Date(), options: GameOptions()), in: root)
        try library.save(Game(id: "steam", name: "Steam"), in: root)
        return (library, try #require(library.entry(at: root)), base)
    }

    private func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 60, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func offersInstalledGamesAndAddsThemWithTheirCover() throws {
        let (library, steam, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let offered = library.offeredStoreGames(in: steam)
        #expect(offered.map(\.name) == ["Among Us"])
        let game = try #require(offered.first)
        #expect(game.link.installDir == #"C:\Program Files (x86)\Steam\steamapps\common\Among Us"#)
        #expect(game.cover?.lastPathComponent == "library_600x900.jpg")

        let added = try library.addStoreGame(game, launcher: steam)
        #expect(added.folder.path.hasSuffix("steam/Games/steam-945360"))
        #expect(added.root == steam.root)
        #expect(added.game.primary?.windowsPath == #"C:\Program Files (x86)\Steam\steamapps\common\Among Us\Among Us.exe"#)
        #expect(added.game.anticheat == [])
        #expect(added.profile == nil)
        #expect(CoverArt.data(in: added.folder) != nil)
        #expect(CoverArt.data(in: steam.root) == nil)
        #expect(library.entries().map(\.id).sorted() == ["steam", "steam-945360"])
        #expect(library.offeredStoreGames(in: steam).isEmpty)
        #expect(library.offeredStoreGames(in: added).isEmpty)
    }

    @Test func aStoreGameRunsWithTheLaunchersProfile() throws {
        let (plain, _, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("profiles")
        let library = Library(home: plain.home, profiles: ProfileStore(directories: [shipped]))
        let root = plain.home.bottles.appendingPathComponent("steam")
        try library.save(BottleRecord(name: "Steam", runtimeVersion: "rw-1", created: Date(), options: GameOptions(),
                                      profile: "steam", profileRevision: 1), in: root)
        let steam = try #require(library.entry(at: root))
        let added = try library.addStoreGame(try #require(library.offeredStoreGames(in: steam).first), launcher: steam)
        // Its compatibility is its own, but Steam starts with Steam's arguments
        // when the game's Play (or an uninstall link) is what starts it.
        #expect(added.profile == nil)
        #expect(added.bottleProfile?.id == "steam")
        #expect(added.bottleProfile?.options.environment[GameProfile.appendArgsVariable]?.contains("steamwebhelper.exe=") == true)
        #expect(steam.bottleProfile?.id == "steam")
    }

    @Test func declinedGamesAreNotOfferedAgainButCanBeAdded() throws {
        let (library, steam, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let game = try #require(library.offeredStoreGames(in: steam).first)
        try library.declineStoreGames([game], launcher: steam)
        #expect(library.offeredStoreGames(in: steam).isEmpty)
        #expect(library.installedStoreGames(in: steam).map(\.id) == ["steam-945360"])
        try library.addStoreGame(game, launcher: steam)
        #expect(library.entries().count == 2)
    }

    @Test func aGameUninstalledInSteamLeavesOnlyWhenItsLibraryIsThere() throws {
        let (library, steam, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        try library.addStoreGame(try #require(library.offeredStoreGames(in: steam).first), launcher: steam)
        #expect(library.uninstalledStoreGames(in: steam).isEmpty)
        let apps = steam.root.appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.removeItem(at: apps.appendingPathComponent("appmanifest_945360.acf"))
        #expect(library.uninstalledStoreGames(in: steam).map(\.id) == ["steam-945360"])
    }

    @Test func savingAStoreGameNeverTouchesTheLaunchersFile() throws {
        let (library, steam, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        var added = try library.addStoreGame(try #require(library.offeredStoreGames(in: steam).first), launcher: steam)
        added.game.lastPlayed = Date()
        try library.save(added.game, in: added.folder)
        #expect(library.entry(at: steam.root)?.game.name == "Steam")
        #expect(library.current(added)?.game.lastPlayed != nil)
    }

    @Test func findsWindowsProgramsInAFolderByName() {
        let processes = [WindowsProcesses.Process(pid: 1, windowsPath: #"C:\Program Files (x86)\Steam\steamapps\common\Among Us\Among Us.exe"#),
                         WindowsProcesses.Process(pid: 2, windowsPath: #"C:\Program Files (x86)\Steam\steam.exe"#),
                         WindowsProcesses.Process(pid: 3, windowsPath: #"C:\Program Files (x86)\Steam\steamapps\common\Among Usual\x.exe"#)]
        let found = WindowsProcesses.inFolder(#"C:\program files (x86)\steam\steamapps\common\Among Us"#, among: processes)
        #expect(found.map(\.pid) == [1])
    }
}
