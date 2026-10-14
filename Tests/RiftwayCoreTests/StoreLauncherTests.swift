import Foundation
import Testing
@testable import RiftwayCore

@Suite struct StoreLauncherTests {
    private func report(_ kind: InstallerReport.Kind, _ signature: SignatureStatus) -> InstallerReport {
        InstallerReport(file: URL(fileURLWithPath: "/tmp/setup.exe"), fileSize: 1, kind: kind, isDotNet: false,
                        signature: signature, origin: [], isQuarantined: false, companions: [])
    }

    @Test func everyLauncherComesFromItsPublishersHostOverHTTPS() throws {
        for launcher in StoreLaunchers.all {
            #expect(launcher.allows(launcher.url), "\(launcher.id)")
        }
        let steam = try #require(StoreLaunchers.launcher("Steam"))
        #expect(steam.allows(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!))
        #expect(!steam.allows(URL(string: "http://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!))
        #expect(!steam.allows(URL(string: "https://steamstatic.com.example.net/SteamSetup.exe")!))
        #expect(!steam.allows(URL(string: "https://evilsteamstatic.com/SteamSetup.exe")!))
        let epic = try #require(StoreLaunchers.launcher("epic"))
        #expect(epic.allows(URL(string: "https://epicgames-download1.akamaized.net/Builds/UnrealEngineLauncher/Installers/Windows/EpicInstaller-20.3.3.msi")!))
        #expect(!epic.allows(URL(string: "https://other.akamaized.net/EpicInstaller.msi")!))
    }

    @Test func knowsAnInstalledLauncherByItsProfileOrItsProgram() throws {
        func entry(_ id: String, program: String?, profile: String? = nil, store: StoreLink? = nil) -> LibraryEntry {
            var game = Game(id: id, name: id, primary: program.map { DiscoveredProgram.executable($0) })
            game.store = store
            let root = URL(fileURLWithPath: "/tmp/\(id)")
            return LibraryEntry(game: game, root: root, folder: root,
                                record: BottleRecord(name: id, runtimeVersion: "rw-1", created: Date(), options: GameOptions(), profile: profile))
        }
        let steam = try #require(StoreLaunchers.launcher("steam"))
        let battlenet = try #require(StoreLaunchers.launcher("battlenet"))
        #expect(steam.isInstalled(as: entry("a", program: #"C:\Program Files (x86)\Steam\Steam.exe"#)))
        #expect(steam.isInstalled(as: entry("b", program: nil, profile: "steam")))
        #expect(battlenet.isInstalled(as: entry("c", program: #"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#)))
        #expect(!steam.isInstalled(as: entry("d", program: #"C:\Games\DSR\DSR.exe"#)))
        // A game Steam installed lives in Steam's bottle but is not Steam.
        let game = entry("945360", program: #"C:\Program Files (x86)\Steam\steamapps\common\Among Us\Among Us.exe"#, profile: "steam",
                         store: StoreLink(store: .steam, appID: "945360", installDir: #"C:\Program Files (x86)\Steam\steamapps\common\Among Us"#))
        #expect(!steam.isInstalled(as: game))
    }

    @Test func keepsOnlyInstallersThePublisherSigned() throws {
        let steam = try #require(StoreLaunchers.launcher("steam"))
        try steam.check(report(.installer(.nsis), .signed(signer: "Valve Corp.", trusted: false)))
        #expect(throws: StoreLauncherDownload.Failure.signer(expected: "Valve", got: "Someone Else Ltd")) {
            try steam.check(report(.installer(.nsis), .signed(signer: "Someone Else Ltd", trusted: true)))
        }
        #expect(throws: StoreLauncherDownload.Failure.unsigned) { try steam.check(report(.installer(.nsis), .unsigned)) }
        #expect(throws: StoreLauncherDownload.Failure.invalidSignature) { try steam.check(report(.installer(.nsis), .invalid(.modified))) }
        #expect(throws: StoreLauncherDownload.Failure.notInstaller) {
            try steam.check(report(.unsupported(.notWindowsProgram), .unsigned))
        }
    }

    @Test func anMSILauncherNeedsAnMSI() throws {
        let epic = try #require(StoreLaunchers.launcher("epic"))
        try epic.check(report(.installer(.msi), .unverified))
        #expect(throws: StoreLauncherDownload.Failure.notInstaller) { try epic.check(report(.installer(.nsis), .unsigned)) }
    }
}
