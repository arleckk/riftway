import Foundation
import Testing
@testable import RiftwayCore

// The layout CrossOver writes for a launcher that registers its own URL protocol.
let systemReg = #"""
WINE REGISTRY Version 2
;; All keys relative to \\Machine

#arch=win64

[Software\\Classes\\dsropen] 1755534398
#time=1dc105cdf3d93c8
"URL Protocol"=""

[Software\\Classes\\dsropen\\shell] 1755534398
@=""

[Software\\Classes\\dsropen\\shell\\open\\command] 1755534398
#time=1dc105cdf3db0ba
@="\"C:\\Program Files (x86)\\Movegames\\Digimon SuperRumble\\SuperRumble Launcher.exe\" \"%1\""

[Software\\Classes\\http] 1755534398
"URL Protocol"=""

[Software\\Classes\\http\\shell\\open\\command] 1755534398
@="\"C:\\windows\\system32\\winebrowser.exe\" \"%1\""

[Software\\Classes\\txtfile\\shell\\open\\command] 1755534398
@="notepad.exe %1"

[Software\\Classes\\other] 1755534398
"Blob"=hex:01,02,03,\
  04,05,06
"Name"="Caf\x00e9 \"quoted\""
"Path"=str(2):"%SystemRoot%\\system32"
"Count"=dword:00000001
"""#

@Suite struct RegistryTests {
    @Test func readsKeysAndStrings() {
        let reg = WineRegistry(text: systemReg)
        #expect(reg.value("URL Protocol", at: #"Software\Classes\dsropen"#) == "")
        #expect(reg.value("", at: #"software\classes\DSROPEN\shell\open\command"#)
            == #""C:\Program Files (x86)\Movegames\Digimon SuperRumble\SuperRumble Launcher.exe" "%1""#)
        #expect(reg.value("name", at: #"Software\Classes\other"#) == "Café \"quoted\"")
        #expect(reg.value("Path", at: #"Software\Classes\other"#) == #"%SystemRoot%\system32"#)
        #expect(reg.value("Count", at: #"Software\Classes\other"#) == nil)
        #expect(reg.subkeys(of: #"Software\Classes"#) == ["dsropen", "http", "other", "txtfile"])
    }

    @Test func discoversOnlyURLProtocols() {
        let found = URLProtocolRegistration.discover(system: WineRegistry(text: systemReg), user: nil)
        #expect(found.map(\.scheme) == ["dsropen", "http"])
        #expect(found.filter(\.isClaimableFromMacOS).map(\.scheme) == ["dsropen"])
        #expect(found.first?.windowsExecutable == #"C:\Program Files (x86)\Movegames\Digimon SuperRumble\SuperRumble Launcher.exe"#)
    }

    @Test func userRegistrationWins() {
        let user = WineRegistry(text: #"""
        [Software\\Classes\\dsropen] 1
        "URL Protocol"=""
        [Software\\Classes\\dsropen\\shell\\open\\command] 1
        @="\"C:\\Users\\me\\Launcher.exe\" \"%1\""
        """#)
        let found = URLProtocolRegistration.discover(system: WineRegistry(text: systemReg), user: user)
        let dsropen = try! #require(found.first { $0.scheme == "dsropen" })
        #expect(dsropen.hive == .user)
        #expect(dsropen.command.contains(#"C:\Users\me"#))
    }
}

@Suite struct CommandLineTests {
    @Test func splitsLikeWindows() {
        #expect(WindowsCommandLine.split(#""C:\Program Files\a b\L.exe" "%1""#) == [#"C:\Program Files\a b\L.exe"#, "%1"])
        #expect(WindowsCommandLine.split(#"C:\dir\x.exe  a "b c" d"#) == [#"C:\dir\x.exe"#, "a", "b c", "d"])
        // Backslashes are literal except before a quote.
        #expect(WindowsCommandLine.split(#"x.exe a\\b "c\\" "d\"e" f\\\"g"#) == ["x.exe", #"a\\b"#, #"c\"#, #"d"e"#, #"f\"g"#])
        #expect(WindowsCommandLine.split(#"x.exe "a""b""#) == ["x.exe", #"a"b"#])
        // The program name keeps its backslashes, even before the closing quote.
        #expect(WindowsCommandLine.split(#""C:\dir\" arg"#) == [#"C:\dir\"#, "arg"])
        #expect(WindowsCommandLine.split("   ") == [])
    }

    @Test func expandsTheURLAsOneArgument() {
        let url = "dsropen:abc;someone@example.com;0FF1CE"
        let template = #""C:\L.exe" "%1""#
        #expect(WindowsCommandLine.expand(template: template, argument: url) == [#"C:\L.exe"#, url])
        // Unquoted %1 still yields one argument, even with spaces in the URL.
        #expect(WindowsCommandLine.expand(template: #"C:\L.exe %1"#, argument: "a:b c") == [#"C:\L.exe"#, "a:b c"])
        #expect(WindowsCommandLine.expand(template: #"C:\L.exe -url=%L %* 100%%"#, argument: "a:b")
            == [#"C:\L.exe"#, "-url=a:b", "100%"])
    }

    @Test func appendsWhenThereIsNoPlaceholder() {
        #expect(WindowsCommandLine.expand(template: #"C:\L.exe -launch"#, argument: "a:b") == [#"C:\L.exe"#, "-launch", "a:b"])
    }

    @Test func dropsPlaceholdersWithoutAnArgument() {
        #expect(WindowsCommandLine.expand(template: #""C:\L.exe" "%1" -x"#, argument: nil) == [#"C:\L.exe"#, "-x"])
    }
}

@Suite struct IncomingURLTests {
    let schemes: Set<String> = ["dsropen"]

    @Test func acceptsLauncherURLs() throws {
        #expect(try IncomingURL.validate("dsropen:tok;someone@example.com;A4CB0E", schemes: schemes) == "dsropen")
        #expect(try IncomingURL.validate("DSROpen://x", schemes: schemes) == "dsropen")
    }

    @Test func rejectsWhatCouldEscape() {
        #expect(throws: IncomingURLError.forbiddenCharacter) { try IncomingURL.validate("dsropen:a\" -evil", schemes: schemes) }
        #expect(throws: IncomingURLError.forbiddenCharacter) { try IncomingURL.validate("dsropen:a\nb", schemes: schemes) }
        #expect(throws: IncomingURLError.schemeNotHandled("steam")) { try IncomingURL.validate("steam://run/1", schemes: schemes) }
        #expect(throws: IncomingURLError.malformed) { try IncomingURL.validate("no-colon", schemes: schemes) }
        #expect(throws: IncomingURLError.malformed) { try IncomingURL.validate("1ds:x", schemes: schemes) }
        #expect(throws: IncomingURLError.tooLong(IncomingURL.maximumLength + 9)) {
            try IncomingURL.validate("dsropen:" + String(repeating: "a", count: IncomingURL.maximumLength + 1), schemes: schemes)
        }
    }

    @Test func redactionHidesThePayload() {
        let url = "dsropen:secret-token;someone@example.com;ABCDEF"
        let shown = IncomingURL.redacted(url)
        #expect(shown.hasPrefix("dsropen:<39 chars, sha256 "))
        #expect(!shown.contains("secret") && !shown.contains("example.com"))
    }
}

@Suite struct BottleTests {
    /// A throwaway prefix: dosdevices/c: → ../drive_c, a launcher, a stand-in wine.
    func makePrefix() throws -> (Bottle, URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("riftway-test-\(UUID().uuidString)", isDirectory: true)
        let prefix = root.appendingPathComponent("DSR", isDirectory: true)
        let gameDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Movegames/Digimon SuperRumble")
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        fm.createFile(atPath: gameDir.appendingPathComponent("SuperRumble Launcher.exe").path, contents: Data())
        try systemReg.write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let wine = root.appendingPathComponent("wine")
        fm.createFile(atPath: wine.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return (Bottle(name: "DSR", prefix: prefix.path, backend: .crossover(wine: wine.path)), root)
    }

    @Test func mapsWindowsPathsThroughDosdevices() throws {
        let (bottle, root) = try makePrefix()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = bottle.unixURL(forWindowsPath: #"C:\Program Files (x86)\Movegames\Digimon SuperRumble\SuperRumble Launcher.exe"#)
        #expect(url?.path.hasSuffix("DSR/drive_c/Program Files (x86)/Movegames/Digimon SuperRumble/SuperRumble Launcher.exe") == true)
        #expect(bottle.unixURL(forWindowsPath: #"C:\..\..\etc\passwd"#) == nil)
        #expect(bottle.unixURL(forWindowsPath: #"\\server\share"#) == nil)
    }

    @Test func plansACrossOverLaunch() throws {
        let (bottle, root) = try makePrefix()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "dsropen:tok;someone@example.com;ABC"
        let plan = try URLBridge(bottle: bottle, schemes: ["dsropen"]).plan(forURL: url)
        #expect(plan.executable == bottle.backend.winePath)
        #expect(Array(plan.arguments.prefix(3)) == ["--bottle", "DSR", "--workdir"])
        #expect(plan.arguments[4] == "--cx-app")
        #expect(plan.arguments[5].hasSuffix("SuperRumble Launcher.exe"))
        #expect(plan.arguments.last == url)
        #expect(plan.workingDirectory.hasSuffix("Digimon SuperRumble"))
        #expect(!plan.logDescription(hiding: url).contains("someone@example.com"))
    }

    @Test func plansAPlainWineLaunch() throws {
        let (crossover, root) = try makePrefix()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(name: "DSR", prefix: crossover.prefix, backend: .wine(wine: crossover.backend.winePath))
        let plan = try URLBridge(bottle: bottle, schemes: ["dsropen"], extraArguments: ["-x"]).plan(forURL: "dsropen:a")
        #expect(plan.environment["WINEPREFIX"] == bottle.prefix)
        #expect(plan.arguments.count == 3)
        #expect(plan.arguments.suffix(2) == ["dsropen:a", "-x"])
    }

    @Test func refusesSchemesTheBottleDoesNotRegister() throws {
        let (bottle, root) = try makePrefix()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: BridgeError.schemeNotRegistered(scheme: "steam", bottle: "DSR")) {
            try URLBridge(bottle: bottle, schemes: ["dsropen", "steam"]).plan(forURL: "steam://run/1")
        }
        // Reserved schemes never pass, even when asked for.
        #expect(throws: BridgeError.invalidURL(.schemeNotHandled("http"))) {
            try URLBridge(bottle: bottle, schemes: ["dsropen", "http"]).plan(forURL: "http://example.com")
        }
        #expect(throws: BridgeError.invalidURL(.schemeNotHandled("evil"))) {
            try URLBridge(bottle: bottle, schemes: ["dsropen"]).plan(forURL: "evil:x")
        }
    }
}

@Suite struct ShimTests {
    @Test func declaresTheSchemes() throws {
        let bottle = Bottle(name: "DSR", prefix: "/tmp/DSR", backend: .crossover(wine: CrossOver.defaultWine))
        let config = ShimConfig(displayName: "Digimon Super Rumble", bottle: bottle, schemes: ["DSROPEN"])
        #expect(config.bundleIdentifier == "com.riftway.shim.digimon-super-rumble")
        let plist = ShimBundle.infoPlist(for: config, hasIcon: true)
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["dsropen"])
        #expect(plist["CFBundleExecutable"] as? String == ShimBundle.executableName)
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ShimConfig.self, from: data) == config)
    }
}

@Suite struct RuntimeEnvironmentTests {
    let runtime = WineRuntime(root: "/RT/rw-1")
    let root = URL(fileURLWithPath: "/Bottles/abc", isDirectory: true)

    @Test func isolatesTheBottle() {
        let env = RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root.appendingPathComponent("prefix"))
        #expect(env["HOME"] == "/Bottles/abc/home")
        #expect(env["TMPDIR"] == "/Bottles/abc/tmp")
        #expect(env["WINEPREFIX"] == "/Bottles/abc/prefix")
        #expect(env["WINELOADER"] == "/RT/rw-1/bin/wine")
        #expect(env["WINESERVER"] == "/RT/rw-1/bin/wineserver")
        #expect(env["WINEDEBUG"] == "-all")
        #expect(env["DXMT_CONFIG_FILE"] == #"C:\ProgramData\Riftway\dxmt.conf"#)
        #expect(env["GST_PLUGIN_SYSTEM_PATH_1_0"] == runtime.root + "/lib/gstreamer-1.0")
        #expect(env["GST_REGISTRY_1_0"] == root.path + "/cache/gstreamer-1.0-registry.bin")
        #expect(env["WINEDLLOVERRIDES"] == "d3d12,nvapi64,nvngx,winemenubuilder.exe=;d3d10core,d3d11,dxgi,winemetal=b")
        // Per-game patches stay inert unless a profile lists the game.
        #expect(env["WINEMAC_MOUSELOOK"] == nil && env["WINE_GAME_MODE"] == nil && env["WINE_APP_DPI"] == nil)
    }

    @Test func serializesGameOptionsWithEachPatchSeparator() {
        var options = GameOptions()
        options.mouselook = ["Client-Win64-Shipping.exe", "Other.exe"]
        options.gameMode = ["Client-Win64-Shipping.exe", "Other.exe"]
        options.appDPI = (192, ["Launcher.exe", "Helper.exe"])
        options.dllOverrides = ["d3d12": "n,b", "dinput8": "n,b"]
        options.environment = ["WINEDEBUG": "+loaddll"]
        let env = RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root.appendingPathComponent("prefix"), options: options)
        #expect(env["WINEMAC_MOUSELOOK"] == "Client-Win64-Shipping.exe;Other.exe")
        #expect(env["WINE_GAME_MODE"] == "Client-Win64-Shipping.exe,Other.exe")
        #expect(env["WINE_APP_DPI"] == "192:Launcher.exe;Helper.exe")
        #expect(env["WINEDLLOVERRIDES"] == "nvapi64,nvngx,winemenubuilder.exe=;d3d10core,d3d11,dxgi,winemetal=b;d3d12,dinput8=n,b")
        #expect(env["WINEDEBUG"] == "+loaddll")
        let decoded = try? JSONDecoder().decode(GameOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }

    @Test func plansARiftwayLaunchWithAWholeEnvironment() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("riftway-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let prefix = base.appendingPathComponent("bottle/prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/Game"), withIntermediateDirectories: true)
        fm.createFile(atPath: prefix.appendingPathComponent("drive_c/Game/Game.exe").path, contents: Data())
        try fm.createDirectory(at: base.appendingPathComponent("rt/bin"), withIntermediateDirectories: true)
        fm.createFile(atPath: base.appendingPathComponent("rt/bin/wine").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let bottle = Bottle(name: "Game", prefix: prefix.path,
                            backend: .riftway(runtime: WineRuntime(root: base.appendingPathComponent("rt").path), options: GameOptions()))
        let plan = try bottle.launchPlan(windowsArguments: [#"C:\Game\Game.exe"#, "-dx11"])
        #expect(plan.replacesEnvironment)
        #expect(plan.arguments.last == "-dx11")
        #expect(plan.environment["HOME"] == base.appendingPathComponent("bottle/home").path)
        #expect(plan.workingDirectory.hasSuffix("drive_c/Game"))
    }
}
