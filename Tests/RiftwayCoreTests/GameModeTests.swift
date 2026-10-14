import Foundation
import Testing
@testable import RiftwayCore

@Suite struct GameModeTests {
    @Test func uuid5MatchesPython() {
        // uuid.uuid5(uuid.NAMESPACE_DNS, "python.org")
        let namespace = Data([0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8])
        let uuid = GameModeApp.uuid5(namespace: namespace, name: "python.org")
        #expect(UUID(uuid: uuid.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }).uuidString == "886313E1-3B8A-5372-9B90-0C9AEE199E5D")
    }

    @Test func eachBottleHasItsOwnIdentity() {
        let root = URL(fileURLWithPath: "/tmp/Bottles/digimon-super-rumble")
        #expect(GameModeApp.identifier(bottleRoot: root) == "com.riftway.game.digimon-super-rumble")
        #expect(GameModeApp.identifier(bottleRoot: URL(fileURLWithPath: "/tmp/Bottles/a b_c")) == "com.riftway.game.a-b-c")
        #expect(GameModeApp.executable(bottleRoot: root).path == "/tmp/Bottles/digimon-super-rumble/GameMode/Game.app/Contents/MacOS/wine")
        #expect(GameModeApp.gameKeys(name: "DSR")["LSSupportsGameMode"] as? Bool == true)
    }

    @Test func onlyACurrentBundleIsUsed() {
        let runtime = WineRuntime(root: "/nonexistent/runtime")
        var options = GameOptions()
        options.gameMode = ["Game.exe"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-gm-\(UUID().uuidString)")
        let env = RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root.appendingPathComponent("prefix"), options: options)
        #expect(env["WINE_GAME_MODE"] == "Game.exe")
        #expect(env["WINE_GAME_MODE_APP"] == nil)
    }

    /// With a real runtime (RIFTWAY_TEST_RUNTIME=work/runtime/artifacts/<version>).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RIFTWAY_TEST_RUNTIME"] != nil))
    func makesASignedGameBundleFromTheLoader() throws {
        let runtime = WineRuntime(root: ProcessInfo.processInfo.environment["RIFTWAY_TEST_RUNTIME"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("riftway-gm-\(UUID().uuidString)/test-game")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var options = GameOptions()
        options.gameMode = ["Game.exe"]
        try GameModeApp.ensure(bottleRoot: root, runtime: runtime, options: options, name: "Test Game")
        #expect(GameModeApp.isCurrent(bottleRoot: root, runtime: runtime))
        let data = try Data(contentsOf: GameModeApp.bundle(bottleRoot: root).appendingPathComponent("Contents/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "com.riftway.game.test-game")
        #expect(info["CFBundleName"] as? String == "Test Game")
        let loader = try Data(contentsOf: URL(fileURLWithPath: runtime.root).appendingPathComponent(GameModeApp.loaderPath))
        let copy = try Data(contentsOf: GameModeApp.executable(bottleRoot: root))
        let at = try GameModeApp.uuidOffset(loader)
        #expect(copy.subdata(in: at..<(at + 16)) != loader.subdata(in: at..<(at + 16)))
        let env = RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root.appendingPathComponent("prefix"), options: options)
        #expect(env["WINE_GAME_MODE_APP"] == GameModeApp.executable(bottleRoot: root).path)
        options.gameMode = []
        try GameModeApp.ensure(bottleRoot: root, runtime: runtime, options: options, name: "Test Game")
        #expect(!FileManager.default.fileExists(atPath: GameModeApp.bundle(bottleRoot: root).path))
    }
}
