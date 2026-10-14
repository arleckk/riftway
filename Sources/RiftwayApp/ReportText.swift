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

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
