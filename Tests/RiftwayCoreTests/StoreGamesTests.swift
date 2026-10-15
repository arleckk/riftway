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
        // The interface size is the profile's until the player picks one,
        // and it reaches Steam's programs from the game too.
        #expect(added.interfacePrograms == ["steam.exe", "steamwebhelper.exe"])
        #expect(added.profileInterfaceDPI == 192)
        var record = steam.record
        record.options.appDPI = (144, steam.interfacePrograms)
        try library.save(record, in: root)
        let game = try #require(library.current(added))
        let setup = BottleSetup(runtime: WineRuntime(root: "/rw"), root: game.root, options: game.record.options,
                                profile: game.bottleProfile, runtimeVersion: "rw-1")
        #expect(setup.environment["WINE_APP_DPI"] == "144:steam.exe;steamwebhelper.exe")
    }

    @Test func aStoreGamesProfileAddsItsProgramsToTheLaunchersBottle() throws {
        let (plain, _, base) = try steamHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("profiles")
        let extra = base.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try #"""
        {"schema": 1, "id": "among-us", "name": "Among Us", "revision": 3, "status": "playable",
         "match": {"steam": ["945360"], "executables": ["Among Us.exe"], "product": ["Steam"]},
         "game": {"WINE_GAME_MODE": ["Among Us.exe"]},
         "program_args": {"Among Us.exe": "-screen-fullscreen 1", "steamwebhelper.exe": "--not-this"},
         "program_dll_overrides": {"Among Us.exe": {"xinput1_3": "b"}},
         "dxmt_conf": {"d3d11.preferredMaxFrameRate": "60"}}
        """#.write(to: extra.appendingPathComponent("among-us.json"), atomically: true, encoding: .utf8)
        let library = Library(home: plain.home, profiles: ProfileStore(directories: [shipped, extra]))
        let root = plain.home.bottles.appendingPathComponent("steam")
        try library.save(BottleRecord(name: "Steam", runtimeVersion: "rw-1", created: Date(), options: GameOptions(),
                                      profile: "steam", profileRevision: 2), in: root)
        let steam = try #require(library.entry(at: root))
        // Its product says Steam, but a Steam game's profile is never a bottle's.
        #expect(library.profiles.match(ProfileQuery(game: steam.game))?.id != "among-us")
        #expect(!steam.profileIsStale)
        let game = try library.addStoreGame(try #require(library.offeredStoreGames(in: steam).first), launcher: steam)
        #expect(game.profile?.id == "among-us")
        #expect(game.compatibility.status == .playable)
        // Written when Steam closes: both pages say it is pending.
        let launcher = try #require(library.entry(at: root))
        #expect(launcher.storeProfiles.map(\.id) == ["among-us"])
        #expect(launcher.profileIsStale && game.profileIsStale)
        let setup = BottleSetup(runtime: WineRuntime(root: "/rw"), root: root, options: launcher.record.options,
                                profile: launcher.profile, runtimeVersion: "rw-1", storeProfiles: launcher.storeProfiles)
        let options = setup.effectiveOptions
        #expect(options.gameMode == ["Among Us.exe"])
        #expect(options.programDllOverrides["Among Us.exe"] == ["xinput1_3": "b"])
        // Steam's own arguments stay Steam's.
        let arguments = options.environment[GameProfile.appendArgsVariable] ?? ""
        #expect(arguments.contains("Among Us.exe=-screen-fullscreen 1"))
        #expect(arguments.contains("steamwebhelper.exe=--in-process-gpu"))
        #expect(!arguments.contains("--not-this"))
        #expect(setup.settingsFile.contains(#"AppDefaults\Among Us.exe\DllOverrides"#))
        let sections = launcher.storeProfiles[0].dxmtConfSections
        #expect(sections.contains("[Among Us.exe]\nd3d11.preferredMaxFrameRate = 60\n"))
        // The bridge of the game gets the same environment as Steam's.
        #expect(game.setup?.storeProfiles.map(\.id) ?? ["among-us"] == ["among-us"])
        var record = launcher.record
        record.storeProfiles = ["among-us": 3]
        try library.save(record, in: root)
        #expect(library.entry(at: root)?.profileIsStale == false)
        #expect(library.current(game)?.profileIsStale == false)
    }

    @Test func frameRateLimitsGoToTheRightSectionOfDxmtConf() throws {
        let game = try GameProfile.load(Data(#"""
        {"schema": 1, "id": "g", "name": "G", "status": "untested", "revision": 2,
         "match": {"steam": ["1"], "executables": ["G-Win64-Shipping.exe"]},
         "dxmt_conf": {"d3d11.preferredMaxFrameRate": "60"}}
        """#.utf8))
        var options = GameOptions()
        options.programFrameRateLimits = ["G-Win64-Shipping.exe": 40]
        options.metalHUD = true
        let setup = BottleSetup(runtime: WineRuntime(root: "/rw"), root: URL(fileURLWithPath: "/tmp/b"), options: options,
                                runtimeVersion: "rw-1", storeProfiles: [game])
        let text = setup.dxmtConfText
        // The player's section comes after the profile's: DXMT keeps the last value.
        let profile = try #require(text.range(of: "[G-Win64-Shipping.exe]\nd3d11.preferredMaxFrameRate = 60"))
        let player = try #require(text.range(of: "[G-Win64-Shipping.exe]\nd3d11.preferredMaxFrameRate = 40"))
        #expect(profile.lowerBound < player.lowerBound)
        #expect(setup.environment["MTL_HUD_ENABLED"] == "1")
        // The bottle's own game: one line for the whole bottle, before any section.
        options = GameOptions()
        options.frameRateLimit = 30
        let own = BottleSetup(runtime: WineRuntime(root: "/rw"), root: URL(fileURLWithPath: "/tmp/b"), options: options, storeProfiles: [game])
        let line = try #require(own.dxmtConfText.range(of: "\nd3d11.preferredMaxFrameRate = 30\n"))
        #expect(line.lowerBound < (own.dxmtConfText.range(of: "[G-Win64-Shipping.exe]")?.lowerBound ?? own.dxmtConfText.endIndex))
        #expect(own.environment["MTL_HUD_ENABLED"] == nil)
        // Saved options read back.
        let data = try JSONEncoder().encode(setup.options)
        #expect(try JSONDecoder().decode(GameOptions.self, from: data) == setup.options)
    }

    @Test func aStoreGamesProfileCannotChangeTheWholeBottle() throws {
        func profile(_ extra: String) -> Data {
            Data(#"{"schema": 1, "id": "g", "name": "G", "status": "untested", "match": {"steam": ["1"]}\#(extra)}"#.utf8)
        }
        #expect(throws: GameProfile.Invalid.storeGame("env")) { try GameProfile.load(profile(#", "env": {"A": "1"}"#)) }
        #expect(throws: GameProfile.Invalid.storeGame("dll_overrides")) { try GameProfile.load(profile(#", "dll_overrides": {"d3d11": "n"}"#)) }
        #expect(throws: GameProfile.Invalid.storeGame("match.executables")) {
            try GameProfile.load(profile(#", "dxmt_conf": {"d3d11.preferredMaxFrameRate": "60"}"#))
        }
        #expect(try GameProfile.load(profile(#", "game": {"WINE_GAME_MODE": ["g.exe"]}"#)).isStoreGame)
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
