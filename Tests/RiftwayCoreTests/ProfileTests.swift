import Foundation
import Testing
@testable import RiftwayCore

func profileJSON(_ extra: String = "", status: String = "playable", match: String = #"{"product": ["The Game"], "company": ["Studio"]}"#) -> Data {
    Data(#"{"schema": 1, "id": "the-game", "name": "The Game", "match": \#(match), "status": "\#(status)"\#(extra)}"#.utf8)
}

@Suite struct ProfileTests {
    @Test func shippedProfilesAreValid() throws {
        let folder = try #require(ProfileStore.shippedDirectories().first)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        #expect(!files.isEmpty)
        for file in files {
            let profile = try GameProfile.load(try Data(contentsOf: folder.appendingPathComponent(file)))
            #expect(file == profile.id + ".json")
        }
    }

    @Test func rejectsTyposAndUnsafeSettings() {
        #expect(throws: GameProfile.Invalid.unknownKey("dll_override")) { try GameProfile.load(profileJSON(#", "dll_override": {}"#)) }
        #expect(throws: GameProfile.Invalid.unknownKey("match.products")) {
            try GameProfile.load(profileJSON(match: #"{"products": ["x"]}"#))
        }
        #expect(throws: GameProfile.Invalid.emptyMatch) { try GameProfile.load(profileJSON(match: "{}")) }
        #expect(throws: GameProfile.Invalid.verifiedWithoutEvidence) { try GameProfile.load(profileJSON(status: "verified")) }
        #expect(throws: GameProfile.Invalid.dllMode("d3d11=native")) { try GameProfile.load(profileJSON(#", "dll_overrides": {"d3d11": "native"}"#)) }
        #expect(throws: GameProfile.Invalid.unknownPatch("WINE_FAKE_GPU")) { try GameProfile.load(profileJSON(#", "game": {"WINE_FAKE_GPU": []}"#)) }
        // Services, drivers and Riftway's own identity are not a profile's to change.
        for key in ["HKLM/System/CurrentControlSet/Services/x", "HKLM/Software/Riftway", "HKLM/Software/Wow6432Node/Riftway",
                    "HKCR/.exe", "HKCU/../HKLM/System", "HKCU"] {
            #expect(throws: GameProfile.Invalid.registryKey(key)) {
                try GameProfile.load(profileJSON(#", "registry": {"\#(key)": {"A": "1"}}"#))
            }
        }
        #expect(throws: GameProfile.Invalid.registryValue("A=dword:1")) {
            try GameProfile.load(profileJSON(#", "registry": {"HKCU/Software/Studio": {"A": "dword:1"}}"#))
        }
        #expect(GameProfile.registryPath("HKCU/Software/Studio/Game") == #"HKEY_CURRENT_USER\Software\Studio\Game"#)
        #expect(GameProfile.registryData("dword:0000002A") == "dword:0000002a")
        #expect(GameProfile.registryData(#"C:\a "b""#) == #""C:\\a \"b\"""#)
    }

    @Test func matchPriority() {
        func profile(_ id: String, _ match: GameProfile.Match) -> GameProfile {
            GameProfile(id: id, name: id, match: match, status: .playable)
        }
        let store = ProfileStore(profiles: [
            profile("by-exe", .init(executables: ["Launcher.exe"])),
            profile("by-product", .init(product: ["The Game"], company: ["Studio"])),
            profile("by-hash", .init(sha256: ["abc123"])),
            profile("by-signer", .init(signer: ["Studio Co., Ltd."], installer: ["Game Installer*.exe"])),
        ])
        var query = ProfileQuery()
        query.executables = ["launcher.exe"]
        #expect(store.match(query)?.id == "by-exe")
        query.products = ["THE GAME"]
        #expect(store.match(query)?.id == "by-exe")  // the company must match too
        query.companies = ["Studio"]
        #expect(store.match(query)?.id == "by-product")
        query.hashes = ["ABC123"]
        #expect(store.match(query)?.id == "by-hash")

        var installer = ProfileQuery()
        installer.signers = ["Studio Co., Ltd."]
        installer.installerNames = ["Game Installer_20250116.exe"]
        #expect(store.match(installer)?.id == "by-signer")
        #expect(store.match(ProfileQuery()) == nil)
    }

    @Test func homeProfilesWinUnlessOlder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shipped = root.appendingPathComponent("shipped"), home = root.appendingPathComponent("home")
        for folder in [shipped, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try profileJSON(#", "revision": 2, "notes": "shipped""#).write(to: shipped.appendingPathComponent("the-game.json"))
        try profileJSON(#", "revision": 1, "notes": "old cache""#).write(to: home.appendingPathComponent("the-game.json"))
        try Data("{".utf8).write(to: home.appendingPathComponent("broken.json"))
        let store = ProfileStore(directories: [shipped, home])
        #expect(store.profiles.map(\.notes) == ["shipped"])
        #expect(store.problems.count == 1)
        try profileJSON(#", "revision": 3, "notes": "feed""#).write(to: home.appendingPathComponent("the-game.json"))
        #expect(ProfileStore(directories: [shipped, home]).profile(id: "the-game")?.notes == "feed")
    }

    @Test func playerOptionsGoOnTopOfTheProfile() throws {
        let profile = try GameProfile.load(profileJSON(#"""
            , "env": {"A": "1", "B": "1"}, "game": {"WINEMAC_MOUSELOOK": ["Game.exe"]},
              "app_dpi": {"dpi": 192, "programs": ["Launcher.exe"]},
              "program_dll_overrides": {"Launcher.exe": {"winegstreamer": ""}}, "dll_overrides": {"xinput1_3": "n,b"}
            """#))
        var player = GameOptions()
        player.environment = ["B": "2"]
        player.mouselook = ["Other.exe"]
        player.programDllOverrides = ["Launcher.exe": ["mshtml": "b"]]
        player.diagnostics = true
        let options = profile.options.overridden(by: player)
        #expect(options.environment == ["A": "1", "B": "2"])
        #expect(options.mouselook == ["Game.exe", "Other.exe"])
        #expect(options.appDPI?.dpi == 192)
        #expect(options.programDllOverrides == ["Launcher.exe": ["winegstreamer": "", "mshtml": "b"]])
        #expect(options.diagnostics)
        let env = RuntimeEnvironment.make(runtime: WineRuntime(root: "/rt"), bottleRoot: URL(fileURLWithPath: "/b"),
                                          prefix: URL(fileURLWithPath: "/b/prefix"), options: options)
        #expect(env["WINEMAC_MOUSELOOK"] == "Game.exe;Other.exe")
        #expect(env["WINE_APP_DPI"] == "192:Launcher.exe")
        #expect(env["WINEDLLOVERRIDES"]?.contains("xinput1_3=n,b") == true)
    }

    @Test func settingsFileCarriesTheIdentityAndTheProfile() throws {
        let profile = try GameProfile.load(profileJSON(#"""
            , "registry": {"HKCU/Software/Studio/The Game": {"DirectX11Use": "1", "Count": "dword:00000002"}},
              "program_dll_overrides": {"Launcher.exe": {"winegstreamer": ""}}, "dxmt_conf": {"d3d11.preferredMaxFrameRate": "60"}
            """#))
        let setup = BottleSetup(runtime: WineRuntime(root: "/rt"), root: URL(fileURLWithPath: "/b"), profile: profile, runtimeVersion: "rw-0.1.2")
        let text = setup.settingsFile
        #expect(text.contains("[HKEY_LOCAL_MACHINE\\Software\\Riftway]\r\n\"Version\"=\"\(Riftway.version)\"\r\n\"Runtime\"=\"rw-0.1.2\"\r\n\"Platform\"=\"macOS\""))
        #expect(text.contains("[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Riftway]"))
        #expect(text.contains("[-HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults]"))
        #expect(text.contains("[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\054c/09cc]\r\n\"Hidraw\"=dword:00000000"))
        #expect(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Launcher.exe\\DllOverrides]\r\n\"winegstreamer\"=\"\""))
        #expect(text.contains("[HKEY_CURRENT_USER\\Software\\Studio\\The Game]\r\n\"Count\"=dword:00000002\r\n\"DirectX11Use\"=\"1\""))
        // The old overrides are deleted before the current ones are written.
        #expect(text.range(of: "[-HKEY_CURRENT_USER")!.lowerBound < text.range(of: "AppDefaults\\Launcher.exe")!.lowerBound)
        #expect(profile.dxmtConfText.hasSuffix("d3d11.preferredMaxFrameRate = 60\n"))
    }
}

@Suite struct AntiCheatTests {
    @Test func findsWhatDSRInstalls() {
        let base = "Program Files (x86)/Movegames/Digimon SuperRumble/Client/Binaries/Win64/"
        let found = AntiCheatDetector.scan(files: [base + "Client-Win64-Shipping.exe", base + "XIGNCODE/x3_x64.xem",
                                                   base + "XIGNCODE/xigncode.log", base + "XIGNCODE:{3629C49D-42C6-4CD8-B2A9-606E13C1E6EA}"])
        #expect(found == [AntiCheatFinding(vendor: .xigncode3, evidence: base + "XIGNCODE/x3_x64.xem")])
        #expect(Compatibility(profile: nil, anticheat: found).status == .untested)
    }

    @Test func kernelAntiCheatsBlockUnlessAProfileSaysOtherwise() {
        let vanguard = AntiCheatDetector.scan(files: ["Program Files/Riot Vanguard/vgc.exe"])
        #expect(vanguard.map(\.vendor) == [.vanguard])
        #expect(Compatibility(profile: nil, anticheat: vanguard).status == .blocked)

        let eac = AntiCheatDetector.scan(files: ["Games/G/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe", "Games/G/EasyAntiCheat/easyanticheat_x64.so"],
                                         drivers: [DriverEntry(name: "EasyAntiCheat_EOS", imagePath: #"C:\Windows\system32\drivers\EasyAntiCheat_EOS.sys"#, type: 1)])
        #expect(eac.count == 1)
        #expect(eac[0].vendor == .easyAntiCheat && eac[0].protonModule && eac[0].driver)
        #expect(Compatibility(profile: nil, anticheat: eac).status == .blocked)
        let tested = GameProfile(id: "g", name: "G", match: .init(executables: ["G.exe"]), status: .playable)
        #expect(Compatibility(profile: tested, anticheat: eac).status == .playable)

        let gameGuard = AntiCheatDetector.scan(files: ["Games/G/GameGuard/GameMon64.des", "Games/G/GameGuard/npgg9.erl"])
        #expect(gameGuard.map(\.vendor) == [.gameGuard])
        #expect(AntiCheatDetector.scan(files: ["Games/G/Game.exe", "Games/G/battle.log"]).isEmpty)
    }

    @Test func discoveryAndMergeKeepFindings() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        let baseline = PrefixSnapshot.capture(prefix: fake.prefix)
        try fake.file("Games/G/BattlEye/BEService_x64.exe", Data(count: 10))
        let result = InstallDiscovery.discover(prefix: fake.prefix, baseline: baseline)
        #expect(result.anticheat.map(\.vendor) == [.battlEye])
        var game = Game(id: "g", name: "G")
        game.merge(result)
        game.merge(result)
        #expect(game.anticheat?.count == 1)
    }
}

@Suite struct ProfileLibraryTests {
    @Test func applyingAProfileWritesTheBottleAndSetsPlay() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        let home = RiftwayHome(root: fake.root.appendingPathComponent("home"), bridges: fake.root.appendingPathComponent("bridges"))
        let bin = home.runtimes.appendingPathComponent("rw-1/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["wine", "wineserver"] {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(tool).path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        let profile = try GameProfile.load(profileJSON(#", "revision": 4, "play_link": "gameopen", "dxmt_conf": {"a": "b"}"#))
        let library = Library(home: home, profiles: ProfileStore(profiles: [profile]))
        let root = home.bottles.appendingPathComponent("g")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fake.prefix, to: root.appendingPathComponent("prefix"))
        try library.save(BottleRecord(name: "G", runtimeVersion: "rw-1", created: Date(), options: GameOptions()), in: root)
        try library.save(Game(id: "g", name: "The Game", publisher: "Studio", schemes: ["gameopen"]), in: root)

        let entry = try #require(library.entry(at: root))
        #expect(entry.profile == nil && entry.compatibility.status == .untested)
        let updated = try #require(try library.updateProfile(entry))
        #expect(updated.record.profile == "the-game" && updated.record.profileRevision == 4)
        let reread = try #require(library.entry(at: root))
        #expect(reread.profile == profile && !reread.profileIsStale)
        #expect(reread.game.customLaunch == .link(scheme: "gameopen"))
        #expect(reread.compatibility.status == .playable)
        let written = root.appendingPathComponent("prefix/drive_c/ProgramData/Riftway")
        #expect(try String(contentsOf: written.appendingPathComponent("dxmt.conf"), encoding: .utf8).hasSuffix("a = b\n"))
        #expect(FileManager.default.fileExists(atPath: written.appendingPathComponent("settings.reg").path))
        #expect(try library.updateProfile(reread) == nil)

        // A newer revision is written again.
        var newer = profile
        newer.revision = 5
        let library2 = Library(home: home, profiles: ProfileStore(profiles: [newer]))
        try library2.save({ var g = reread.game; g.customLaunch = nil; return g }(), in: root)
        let stale = try #require(library2.entry(at: root))
        #expect(stale.profileIsStale)
        #expect(try library2.updateProfile(stale)?.record.profileRevision == 5)
    }
}
