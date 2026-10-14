import AppKit
import RiftwayCore
import SwiftUI

/// The game launchers Riftway downloads for Windows (PRD-01 R1.6): on a Mac
/// their sites give the macOS app. Each one goes to the analysis sheet and
/// installs like any installer.
struct LaunchersPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("En una Mac, sus sitios te dan la app de macOS. Riftway descarga el instalador de Windows del servidor del fabricante y solo lo usa si él lo firmó; luego lo instalas como cualquier juego.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(StoreLaunchers.all) { launcher in
                        LauncherRow(launcher: launcher, model: model)
                        if launcher.id != StoreLaunchers.all.last?.id { Divider().padding(.leading, 76) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                Text("Los que dicen \"Sin probar\" pueden no abrir todavía en Riftway.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Launchers")
        .navigationSubtitle("Instaladores de Windows")
    }
}

private struct LauncherRow: View {
    let launcher: StoreLauncher
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon = LauncherIcon.image(launcher.id) {
                    // On white, like an app icon: some logos are black (Ubisoft's).
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white)
                } else {
                    Text(String(launcher.name.prefix(1)))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(launcher.name).font(.headline)
                HStack(spacing: 6) {
                    Text(launcher.tested ? "Probado con Riftway" : "Sin probar")
                        .foregroundStyle(launcher.tested ? Theme.verified : .secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(launcher.signer.map { _ in "Firmado por \(launcher.publisher)" } ?? "Del servidor de \(launcher.publisher) (MSI)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let problem = model.launcherProblem[launcher.id] {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.blocked)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let progress = model.launcherProgress[launcher.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress).frame(width: 120)
                    Button("Cancelar") { model.cancelLauncher(launcher) }.controlSize(.small)
                }
            } else {
                Button("Descargar") { model.getLauncher(launcher) }
                    .help("Descarga \(launcher.url.host ?? "") y luego muestra el análisis del instalador")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The launchers' own icons, shipped in the app (`Resources/Launchers`, from
/// `app/Launchers`, where NOTICE.md says whose trademarks they are).
enum LauncherIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ id: String) -> NSImage? {
        if let image = cache[id] { return image }
        // Run from `swift build` (the render aids): the repository's copy.
        let folders = [Bundle.main.resourceURL?.appendingPathComponent("Launchers"),
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("app/Launchers")]
        guard let image = folders.compactMap({ $0 }).lazy
            .compactMap({ NSImage(contentsOf: $0.appendingPathComponent(id + ".png")) }).first else { return nil }
        cache[id] = image
        return image
    }
}
