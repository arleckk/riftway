import AppKit
import UniformTypeIdentifiers

/// Riftway's claim on Windows programs and installers in Finder.
///
/// Info.plist registers Riftway as an alternate handler (it appears in "Open
/// With"). Becoming the default only happens when the user says so, at first
/// launch or in Settings; macOS asks for confirmation itself.
@MainActor
enum FileAssociation {
    /// Both are declared by macOS (`mdls` on a `.exe` and a `.msi` on macOS 26).
    static let executable = UTType("com.microsoft.windows-executable") ?? UTType(filenameExtension: "exe")!
    static let installer = UTType("com.microsoft.msi-installer") ?? UTType(filenameExtension: "msi")!
    static var types: [UTType] { [executable, installer] }

    static func handler(for type: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    static func isRiftwayDefault(for type: UTType) -> Bool {
        guard let handler = handler(for: type) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var isRiftwayDefaultForAll: Bool { types.allSatisfy(isRiftwayDefault(for:)) }

    /// Display name of the app that opens `type` now ("CrossOver", "Riftway"), if any.
    static func handlerName(for type: UTType) -> String? {
        handler(for: type).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    static func makeRiftwayDefault() async {
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            } catch {
                NSLog("Riftway: could not become the default for \(type.identifier): \(error)")
            }
        }
    }
}
