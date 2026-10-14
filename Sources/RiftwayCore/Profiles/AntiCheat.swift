import Foundation

public enum AntiCheatVendor: String, Codable, Sendable, CaseIterable {
    case xigncode3, easyAntiCheat = "easyanticheat", battlEye = "battleye", vanguard, gameGuard = "gameguard"

    public var displayName: String {
        switch self {
        case .xigncode3: "XIGNCODE3"
        case .easyAntiCheat: "Easy Anti-Cheat"
        case .battlEye: "BattlEye"
        case .vanguard: "Riot Vanguard"
        case .gameGuard: "nProtect GameGuard"
        }
    }

    /// Needs a kernel driver on every system: it cannot let the game in under Wine.
    public var alwaysKernel: Bool { self == .vanguard || self == .gameGuard }
}

/// An anti-cheat found in a bottle, with the file that gave it away.
public struct AntiCheatFinding: Codable, Sendable, Equatable, Hashable {
    public var vendor: AntiCheatVendor
    /// A path relative to `C:\`, `/`-separated.
    public var evidence: String
    /// A kernel driver of this anti-cheat is installed in the bottle.
    public var driver: Bool
    /// The studio shipped the vendor's Linux module (`*.so`): it enabled the
    /// anti-cheat's Proton mode. There is no macOS module yet.
    public var protonModule: Bool

    public init(vendor: AntiCheatVendor, evidence: String, driver: Bool = false, protonModule: Bool = false) {
        self.vendor = vendor
        self.evidence = evidence
        self.driver = driver
        self.protonModule = protonModule
    }
}

/// Finds anti-cheats by the files and drivers they install (PRD-05). It only
/// reads names: it never runs, changes or hides anything of theirs. Riftway
/// tells the player and never tries to disable, deceive or evade an
/// anti-cheat (PRD-07, the red line).
public enum AntiCheatDetector {
    struct Rule {
        var vendor: AntiCheatVendor
        /// A folder anywhere in the path.
        var folders: [String] = []
        /// File names; `*` matches anything.
        var files: [String] = []
        /// Kernel drivers (file or service names, without `.sys`).
        var drivers: [String] = []
        /// The vendor's Linux module, shipped when the studio enabled Proton.
        var protonModules: [String] = []
    }

    static let rules: [Rule] = [
        // Confirmed in DSR: XIGNCODE/x3_x64.xem, xxd-0.xem, xm.exe, xigncode.log.
        Rule(vendor: .xigncode3, folders: ["xigncode"], files: ["x3.xem", "x3_x64.xem", "xxd-0.xem"], drivers: ["xhunter1", "xhunter64"]),
        Rule(vendor: .easyAntiCheat, folders: ["easyanticheat"],
             files: ["easyanticheat_eos_setup.exe", "easyanticheat_setup.exe", "easyanticheat_x64.dll", "easyanticheat_x86.dll",
                     "easyanticheat_eos.sys", "start_protected_game.exe"],
             drivers: ["easyanticheat", "easyanticheat_eos"], protonModules: ["easyanticheat_x64.so", "easyanticheat_x86.so"]),
        Rule(vendor: .battlEye, folders: ["battleye"], files: ["beservice.exe", "beservice_x64.exe", "beclient.dll", "beclient_x64.dll"],
             drivers: ["bedaisy", "beservice"], protonModules: ["beclient_x64.so", "beclient.so"]),
        Rule(vendor: .vanguard, folders: ["riot vanguard"], files: ["vgk.sys", "vgc.exe", "vgtray.exe"], drivers: ["vgk", "vgc"]),
        Rule(vendor: .gameGuard, folders: ["gameguard"], files: ["gamemon.des", "gamemon64.des", "gameguard.des", "npgg*.erl"],
             drivers: ["npptnt2", "npsc64", "dump_wmimmc"]),
    ]

    /// `files` are paths relative to `drive_c` (`/`-separated), as discovery lists them.
    public static func scan(files: [String], drivers: [DriverEntry] = []) -> [AntiCheatFinding] {
        var found: [AntiCheatVendor: AntiCheatFinding] = [:]
        func record(_ vendor: AntiCheatVendor, _ evidence: String, driver: Bool = false, proton: Bool = false) {
            var finding = found[vendor] ?? AntiCheatFinding(vendor: vendor, evidence: evidence)
            finding.driver = finding.driver || driver
            finding.protonModule = finding.protonModule || proton
            found[vendor] = finding
        }
        for path in files.sorted() {
            let parts = path.lowercased().split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            let folders = parts.dropLast()
            for rule in rules {
                let sys = name.hasSuffix(".sys") ? String(name.dropLast(4)) : nil
                if rule.protonModules.contains(name) {
                    record(rule.vendor, path, proton: true)
                } else if let sys, rule.drivers.contains(sys) {
                    record(rule.vendor, path, driver: true)
                } else if rule.files.contains(where: { matches(name, $0) }) || folders.contains(where: rule.folders.contains) {
                    record(rule.vendor, path)
                }
            }
        }
        for driver in drivers {
            let file = driver.imagePath?.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
            let names = [driver.name.lowercased(), file.hasSuffix(".sys") ? String(file.dropLast(4)) : file]
            for rule in rules where names.contains(where: rule.drivers.contains) {
                record(rule.vendor, driver.imagePath ?? driver.name, driver: true)
            }
        }
        return AntiCheatVendor.allCases.compactMap { found[$0] }
    }

    /// A shell pattern (`*`, `?`), case-insensitive.
    static func matches(_ name: String, _ pattern: String) -> Bool {
        fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }
}
