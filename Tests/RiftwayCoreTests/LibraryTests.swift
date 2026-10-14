import Foundation
import Testing
@testable import RiftwayCore

/// A `.lnk` as Wine's IShellLink writes it: LinkInfo with an ANSI local base
/// path, then Unicode working directory, arguments and icon location.
func makeShortcut(target: String, workingDirectory: String? = nil, arguments: String? = nil, icon: String? = nil) -> Data {
    var data = Data()
    func u16(_ v: Int) { data += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func u32(_ v: Int) { for i in 0..<4 { data.append(UInt8(v >> (8 * i) & 0xFF)) } }
    var flags = 0x2 | 0x80  // HasLinkInfo, IsUnicode
    if workingDirectory != nil { flags |= 0x10 }
    if arguments != nil { flags |= 0x20 }
    if icon != nil { flags |= 0x40 }
    u32(0x4C)
    data += ShellLink.clsid
    u32(flags)
    data += Data(count: 0x4C - data.count)  // attributes, times, size, icon index, show, hotkey, reserved
    // LinkInfo: header 0x1C bytes, VolumeID (minimal), LocalBasePath, CommonPathSuffix.
    let volume: [UInt8] = [0x11, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0]
    let base = Array(target.utf8) + [0]
    let headerSize = 0x1C
    let volumeOffset = headerSize
    let baseOffset = volumeOffset + volume.count
    let suffixOffset = baseOffset + base.count
    let total = suffixOffset + 1
    u32(total); u32(headerSize); u32(1); u32(volumeOffset); u32(baseOffset); u32(0); u32(suffixOffset)
    data += volume
    data += base
    data.append(0)
    for value in [workingDirectory, arguments, icon] {
        guard let value else { continue }
        let units = Array(value.utf16)
        u16(units.count)
        for unit in units { u16(Int(unit)) }
    }
    u32(0)  // terminal block
    return data
}

@Suite struct ShellLinkTests {
    @Test func readsWineShortcuts() throws {
        let data = makeShortcut(target: #"C:\Games\Game\Game.exe"#, workingDirectory: #"C:\Games\Game"#, arguments: "-dx11",
                                icon: #"C:\Games\Game\Game.ico"#)
        let link = try ShellLink(data: data)
        #expect(link.target == #"C:\Games\Game\Game.exe"#)
        #expect(link.workingDirectory == #"C:\Games\Game"#)
        #expect(link.arguments == "-dx11")
        #expect(link.iconLocation == #"C:\Games\Game\Game.ico"#)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ShellLink.ParseError.notAShortcut) { try ShellLink(data: Data("[InternetShortcut]\n".utf8)) }
        #expect(throws: ShellLink.ParseError.notAShortcut) { try ShellLink(data: Data()) }
    }
}

@Suite struct RegistryDwordTests {
    @Test func readsDwords() {
        let reg = WineRegistry(text: systemReg)
        #expect(reg.dword("Count", at: #"Software\Classes\other"#) == 1)
        #expect(reg.dword("Name", at: #"Software\Classes\other"#) == nil)
    }
}

/// A fake bottle: `<root>/prefix` with hives and files.
struct FakePrefix {
    let root: URL
    var prefix: URL { root.appendingPathComponent("prefix") }
    var driveC: URL { prefix.appendingPathComponent("drive_c") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prefix/drive_c/windows"), withIntermediateDirectories: true)
        try hives(system: "", user: "")
    }

    func hives(system: String, user: String) throws {
        try Data(("WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows] 1\n" + system).utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try Data(("WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n" + user).utf8).write(to: prefix.appendingPathComponent("user.reg"))
    }

    func file(_ relative: String, _ data: Data) throws {
        let url = driveC.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

let installedSystemReg = #"""
[Software\\Classes\\gameopen] 1
"URL Protocol"=""

[Software\\Classes\\gameopen\\shell\\open\\command] 1
@="\"C:\\Games\\Game\\Launcher.exe\" \"%1\""

[Software\\Classes\\.gamesave] 1
@="GameSave"

[Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Game] 1
"DisplayName"="The Game"
"Publisher"="Studio"
"UninstallString"="C:\\Games\\Game\\uninst.exe"

[System\\CurrentControlSet\\Services\\gamekd] 1
"ImagePath"="\\??\\C:\\Games\\Game\\gamekd.sys"
"Type"=dword:00000001

[System\\CurrentControlSet\\Services\\gamesvc] 1
"Type"=dword:00000010
"""#

@Suite struct DiscoveryTests {
    @Test func findsWhatAnInstallerLeft() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        try fake.file("windows/system32/notepad.exe", Data(count: 10))
        try fake.file("users/crossover/AppData/Local/Temp/setup.tmp", Data(count: 10))
        let baseline = PrefixSnapshot.capture(prefix: fake.prefix)
        #expect(baseline.files.isEmpty)  // windows/ and Temp are not tracked

        try fake.hives(system: installedSystemReg, user: "")
        try fake.file("Games/Game/Game.exe", Data(count: 4000))
        try fake.file("Games/Game/Launcher.exe", Data(count: 2000))
        try fake.file("Games/Game/uninst.exe", Data(count: 9000))
        try fake.file("Games/Game/gamekd.sys", Data(count: 100))
        try fake.file("Games/Game/Site.url", Data("[InternetShortcut]\r\nURL=https://game.example/\r\n".utf8))
        let menu = "ProgramData/Microsoft/Windows/Start Menu/Programs/The Game/"
        try fake.file(menu + "The Game.lnk", makeShortcut(target: #"C:\Games\Game\Launcher.exe"#, arguments: "-launcher"))
        try fake.file(menu + "Uninstall.lnk", makeShortcut(target: #"C:\Games\Game\uninst.exe"#))
        try fake.file(menu + "Website.lnk", makeShortcut(target: #"C:\Games\Game\Site.url"#))
        try fake.file("users/crossover/Desktop/Game Direct.lnk", makeShortcut(target: #"C:\Games\Game\Game.exe"#))
        try fake.file("users/crossover/Desktop/Play Online.lnk", makeShortcut(target: #"C:\Games\Game\Site.url"#))

        let result = InstallDiscovery.discover(prefix: fake.prefix, baseline: baseline, product: "The Game")
        #expect(result.programs.map(\.name) == ["Game Direct", "Play Online", "The Game"])
        #expect(result.programs[1].target == .web(url: "https://game.example/"))
        #expect(result.primary?.name == "The Game")
        #expect(result.primary?.target == .executable(path: #"C:\Games\Game\Launcher.exe"#, arguments: "-launcher"))
        #expect(result.uninstall.map(\.displayName) == ["The Game"])
        #expect(result.protocols.map(\.scheme) == ["gameopen"])
        #expect(result.associations == [".gamesave"])
        #expect(result.drivers.map(\.name) == ["gamekd"])  // the .sys on disk is the same driver
        #expect(result.executables.first == #"C:\Games\Game\Game.exe"#)  // largest, uninstaller excluded
    }

    @Test func primaryFallsBackToTheLargestProgram() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        let baseline = PrefixSnapshot.capture(prefix: fake.prefix)
        try fake.file("Games/Tool/small.exe", Data(count: 10))
        try fake.file("Games/Tool/Tool.exe", Data(count: 500))
        try fake.file("Games/Tool/vc_redist.x64.exe", Data(count: 5000))
        let result = InstallDiscovery.discover(prefix: fake.prefix, baseline: baseline, product: nil)
        #expect(result.programs.isEmpty)
        #expect(result.primary?.target == .executable(path: #"C:\Games\Tool\Tool.exe"#, arguments: nil))
        #expect(!result.isEmpty)
    }

    @Test func expandsShortcutVariables() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        try FileManager.default.createDirectory(at: fake.driveC.appendingPathComponent("users/player"), withIntermediateDirectories: true)
        #expect(InstallDiscovery.expand(#"%ProgramFiles(x86)%\Game\Game.exe"#, driveC: fake.driveC) == #"C:\Program Files (x86)\Game\Game.exe"#)
        #expect(InstallDiscovery.expand(#"%APPDATA%\Game\Game.exe"#, driveC: fake.driveC) == #"C:\users\player\AppData\Roaming\Game\Game.exe"#)
    }
}

@Suite struct LibraryModelTests {
    @Test func mergeOnlyAdds() {
        let first = DiscoveredProgram(name: "Launcher", target: .executable(path: #"C:\G\L.exe"#, arguments: nil),
                                      workingDirectory: nil, iconLocation: nil, iconIndex: 0, shortcut: "a.lnk")
        let second = DiscoveredProgram(name: "Game", target: .executable(path: #"C:\G\G.exe"#, arguments: nil),
                                       workingDirectory: nil, iconLocation: nil, iconIndex: 0, shortcut: "b.lnk")
        var game = Game(id: "g", name: "G", primary: first, programs: [first], schemes: ["one"])
        var result = InstallResult()
        result.programs = [second]
        result.primary = second
        result.protocols = [URLProtocolRegistration(scheme: "two", command: #""C:\G\L.exe" "%1""#, hive: .machine)]
        result.uninstall = [UninstallEntry(key: "x", displayName: "Wine Gecko (32-bit)"), UninstallEntry(key: "g", displayName: "G")]
        game.merge(result)
        #expect(game.programs.map(\.name) == ["Launcher", "Game"])
        #expect(game.primary == first)  // the player's choice stays
        #expect(game.schemes == ["one", "two"])
        #expect(game.uninstall?.displayName == "G")  // Wine's own components are not the game
    }

    @Test func runtimesNewestFirstAndFreshBottleFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = RiftwayHome(root: root, bridges: root.appendingPathComponent("Bridges"))
        for version in ["rw-0.1.9", "rw-0.1.10", "rw-0.1.2"] {
            let bin = home.runtimes.appendingPathComponent(version + "/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        #expect(home.installedRuntimes().map(\.version) == ["rw-0.1.10", "rw-0.1.9", "rw-0.1.2"])
        let first = home.newBottleRoot(for: "Digimon SuperRumble")
        #expect(first.lastPathComponent == "digimon-superrumble")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        #expect(home.newBottleRoot(for: "Digimon SuperRumble").lastPathComponent == "digimon-superrumble-2")
    }

    @Test func bridgeConfigReadsOlderFilesAndOnlyOpensWebPages() throws {
        let old = #"{"displayName":"G","bundleIdentifier":"com.riftway.shim.g","schemes":["g"],"bottle":{"name":"g","prefix":"/p","backend":{"wine":{"wine":"/w"}}}}"#
        var config = try JSONDecoder().decode(ShimConfig.self, from: Data(old.utf8))
        #expect(config.program == nil && config.webPage == nil && !config.wineLog)
        config.webPage = "https://game.example/"
        #expect(config.webPageURL?.host == "game.example")
        config.webPage = "file:///etc/passwd"
        #expect(config.webPageURL == nil)
        #expect(ShimBundle.infoPlist(for: ShimConfig(displayName: "G", bottle: config.bottle, schemes: []), hasIcon: false)["CFBundleURLTypes"] == nil)
    }

    @Test func diagnosticModeLogsWithoutCommandLines() {
        var options = GameOptions()
        options.diagnostics = true
        let env = RuntimeEnvironment.make(runtime: WineRuntime(root: "/RT"), bottleRoot: URL(fileURLWithPath: "/B"),
                                          prefix: URL(fileURLWithPath: "/B/prefix"), options: options)
        #expect(env["WINEDEBUG"] == RuntimeEnvironment.diagnosticChannels)
        #expect(!(env["WINEDEBUG"] ?? "").contains("relay") && !(env["WINEDEBUG"] ?? "").contains("process"))
        #expect(env["DXMT_LOG_PATH"] == nil)
    }
}

@Suite struct CustomLaunchTests {
    @Test func keychainRoundTrip() throws {
        let account = "test:" + UUID().uuidString
        defer { try? SecretStore.delete(account: account) }
        #expect(try SecretStore.read(account: account) == nil)
        try SecretStore.save("dsropen:a;b;c", account: account)
        try SecretStore.save("dsropen:d;e;f", account: account)  // replaces
        #expect(try SecretStore.read(account: account) == "dsropen:d;e;f")
        try SecretStore.delete(account: account)
        #expect(try SecretStore.read(account: account) == nil)
    }

    @Test func linksMustUseTheGamesSchemeAndCommandsRun() throws {
        let fake = try FakePrefix()
        defer { fake.remove() }
        let home = RiftwayHome(root: fake.root.appendingPathComponent("home"), bridges: fake.root.appendingPathComponent("bridges"))
        let library = Library(home: home)
        let root = home.bottles.appendingPathComponent("g")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fake.prefix, to: root.appendingPathComponent("prefix"))
        let wine = home.runtimes.appendingPathComponent("rw-1/bin")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: wine.appendingPathComponent("wine").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try library.save(BottleRecord(name: "G", runtimeVersion: "rw-1", created: Date(), options: GameOptions()), in: root)
        try library.save(Game(id: "g", name: "G", schemes: ["gameopen"]), in: root)
        let file = root.appendingPathComponent("prefix/drive_c/Games/G/G.exe")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let entry = try #require(library.entry(at: root))
        #expect(throws: BridgeError.self) {
            _ = try GameLauncher.setCustomLaunch(.link(scheme: "gameopen"), link: "otherscheme:token", for: entry, library: library)
        }
        #expect(library.entry(at: root)?.game.customLaunch == nil)

        let game = try GameLauncher.setCustomLaunch(.command(path: #"C:\Games\G\G.exe"#, arguments: "-dx11 \"two words\""),
                                                    for: entry, library: library)
        #expect(game.customLaunch == .command(path: #"C:\Games\G\G.exe"#, arguments: "-dx11 \"two words\""))
        let updated = try #require(library.entry(at: root))
        guard case .wine(let plan, _) = try GameLauncher.action(for: updated) else { Issue.record("expected wine"); return }
        #expect(plan.arguments.suffix(2) == ["-dx11", "two words"])
        #expect(plan.arguments.first?.hasSuffix("drive_c/Games/G/G.exe") == true)
    }
}
