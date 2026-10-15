import Foundation
import RiftwayCore

/// Spanish wording for an `InstallerReport`, kept apart from the views so every
/// screen describes a file the same way.
enum ReportText {
    enum Tone { case neutral, caution, problem }

    static func kind(_ kind: InstallerReport.Kind) -> String {
        switch kind {
        case .installer(.unknown): "Instalador"
        case .installer(let type): "Instalador \(type.displayName)"
        case .portable: "Programa sin instalador"
        case .unsupported: "No se puede abrir"
        }
    }

    static func unsupported(_ reason: UnsupportedReason) -> String {
        switch reason {
        case .notWindowsProgram: "No es un programa de Windows."
        case .library: "Es una biblioteca (DLL), no un programa que se pueda abrir."
        case .driver: "Es un driver de Windows. Wine no puede cargar drivers de kernel."
        case .architecture(let arch): "Está compilado para \(arch). Riftway corre programas x86 y x64."
        case .unreadable(let message): "No se pudo leer el archivo: \(message)"
        }
    }

    static func signature(_ status: SignatureStatus) -> (text: String, tone: Tone) {
        switch status {
        case .unsigned:
            ("Sin firma digital. Muchos instaladores pequeños no la traen; asegúrate de que venga del sitio oficial.", .caution)
        case .signed(let signer, true):
            ("Firmado por \(sentence(signer))", .neutral)
        case .signed(let signer, false):
            ("Firmado por \(sentence(signer)) La firma es válida; su autoridad certificadora es de Windows y macOS no la incluye.", .neutral)
        case .invalid(.modified):
            ("La firma no coincide: el archivo cambió después de firmarse. No lo instales si no confías en su origen.", .problem)
        case .invalid(.badSignature):
            ("La firma digital no es válida.", .problem)
        case .invalid(.malformed):
            ("La firma digital está dañada o no se puede leer.", .problem)
        case .invalid(.unsupportedAlgorithm):
            ("La firma usa un algoritmo que Riftway todavía no verifica.", .caution)
        case .unverified:
            ("Trae firma digital; Riftway todavía no verifica firmas de MSI.", .neutral)
        }
    }

    static func executionLevel(_ level: String?) -> String? {
        switch level {
        case "requireAdministrator": "Pide permisos de administrador de Windows. Es normal en instaladores; no son permisos de administrador de tu Mac."
        case "highestAvailable": "Pide los permisos más altos disponibles."
        default: nil
        }
    }

    /// "digimonsuperrumble.com" from the download URL, or the URL itself.
    static func origin(_ origins: [String]) -> String? {
        guard let first = origins.first else { return nil }
        return URL(string: first)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? first
    }

    /// "Move Interactive Co., Ltd." stays as is; "Codeweavers, Inc" gains a period.
    static func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }

    static func status(_ status: CompatibilityStatus) -> String {
        switch status {
        case .verified: "Verificado"
        case .playable: "Jugable"
        case .untested: "Sin probar"
        case .blocked: "Bloqueado"
        }
    }

    /// What the player reads about a game's compatibility, before installing
    /// (no anti-cheat scan yet) or from its bottle.
    static func compatibility(_ c: Compatibility, installed: Bool) -> (text: String, tone: Tone) {
        var parts: [String] = []
        switch c.status {
        case .verified:
            let tested = c.profile?.tested.map { " (\($0.date), macOS \($0.macos), \($0.hardware)\($0.online == true ? ", en línea" : ""))" } ?? ""
            parts.append("Verificado: se probó de punta a punta en Riftway\(tested).")
        case .playable:
            parts.append("Jugable, con problemas conocidos.")
        case .untested:
            parts.append(installed ? "Sin datos de compatibilidad para este juego." : "Sin datos de compatibilidad. Al instalarlo, Riftway busca anti-cheats en lo que deje.")
        case .blocked:
            parts.append("Bloqueado: algo fuera del alcance de Riftway impide jugarlo.")
        }
        if let info = c.profile?.anticheat {
            parts.append("Usa \(info.vendor.displayName)" + (info.kernel ? ", que necesita su driver de kernel." : " en modo usuario, sin driver."))
        }
        for finding in c.anticheat where finding.vendor != c.profile?.anticheat?.vendor || c.profile == nil {
            parts.append(anticheat(finding))
        }
        if let notes = c.profile?.notes { parts.append(notes) }
        let tone: Tone = switch c.status {
        case .blocked: .problem
        case .verified, .playable: .neutral
        case .untested: c.anticheat.isEmpty ? .neutral : .caution
        }
        return (parts.joined(separator: " "), tone)
    }

    static func anticheat(_ f: AntiCheatFinding) -> String {
        let name = f.vendor.displayName
        if f.vendor.alwaysKernel || f.driver {
            return "Instaló \(name), que necesita un driver de kernel; Wine no lo carga y el juego en línea no va a entrar."
        }
        switch f.vendor {
        case .easyAntiCheat, .battlEye:
            return "Usa \(name). Solo funciona si el estudio habilitó su modo para Wine"
                + (f.protonModule ? " (lo hizo para Linux; en Mac no hay módulo todavía)." : "; en Mac no está confirmado.")
        default:
            return "Usa \(name) en modo usuario: puede funcionar (Digimon Super Rumble entra), pero no hay datos de este juego."
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Why a folder can't hold games (the same rules as Recall).
    static func location(_ problem: BottleLocations.Problem) -> String {
        switch problem {
        case .unreadable: "No se puede leer esa carpeta. Elige otra."
        case .network: "Los discos de red no sirven: elige un disco conectado a esta Mac."
        case .readOnly(let drive): "\(drive) es de solo lectura. Elige otro lugar."
        case .format(let drive, let format):
            "\(drive) está formateado como \(format). Wine necesita APFS o Mac OS Extended; reformatearlo en la Utilidad de Discos lo borra."
        case .caseSensitive(let drive): "\(drive) distingue mayúsculas y minúsculas, y los juegos de Windows no lo soportan. Elige otro disco."
        case .cloud: "Las carpetas de iCloud Drive u otra nube no sirven. Elige una que no se sincronice."
        case .notEmpty: "Esa carpeta Riftway ya tiene otros archivos. Elige otro lugar."
        }
    }

    static func move(_ failure: BottleMove.Failure) -> String {
        switch failure {
        case .running: "Cierra el juego (y su launcher) antes de moverlo."
        case .disconnected(let drive): "\(drive) no está conectado."
        case .unsuitable(let problem): location(problem)
        case .alreadyThere: "El juego ya está ahí."
        case .exists(let path): "Ya hay una carpeta \((path as NSString).lastPathComponent) ahí."
        case .notEnoughSpace(let needed, let free): "Necesita \(size(needed)) y ahí hay \(size(free)) libres."
        case .incomplete: "La copia no quedó igual que el original. El juego se queda donde estaba."
        case .cancelled: "Cancelado. El juego se queda donde estaba."
        }
    }
}
