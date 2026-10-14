import Foundation
import Testing
@testable import RiftwayCore

@Suite struct GraphicsTests {
    @Test func wined3dIsSearchedBeforeDXMT() {
        let runtime = WineRuntime(root: "/Runtimes/rw-test")
        let root = URL(fileURLWithPath: "/tmp/Bottles/game")
        var options = GameOptions()
        #expect(RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root, options: options)["WINEDLLPATH_FIRST"] == nil)
        options.direct3D11 = .wined3d
        #expect(RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root, options: options)["WINEDLLPATH_FIRST"]
                == "/Runtimes/rw-test/lib/wine/wined3d")
        options.direct3D11 = .dxmt
        #expect(RuntimeEnvironment.make(runtime: runtime, bottleRoot: root, prefix: root, options: options)["WINEDLLPATH_FIRST"] == nil)
    }

    @Test func profilesChooseAndPlayersOverride() throws {
        let profile = try GameProfile.load(profileJSON(#", "d3d11": "wined3d""#))
        #expect(profile.options.direct3D11 == .wined3d)
        #expect(throws: (any Error).self) { try GameProfile.load(profileJSON(#", "d3d11": "vulkan""#)) }
        var player = GameOptions()
        #expect(profile.options.overridden(by: player).direct3D11 == .wined3d)
        player.direct3D11 = .dxmt
        #expect(profile.options.overridden(by: player).direct3D11 == .dxmt)
        let saved = try JSONDecoder().decode(GameOptions.self, from: try JSONEncoder().encode(player))
        #expect(saved.direct3D11 == .dxmt)
    }
}
