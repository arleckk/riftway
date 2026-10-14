import RiftwayCore
import SwiftUI

/// The game launchers Riftway downloads for Windows (PRD-01 R1.6): on a Mac
/// their sites give the macOS app. Each one goes to the analysis sheet and
/// installs like any installer.
struct LaunchersView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instalar un launcher").font(.title2.weight(.bold))
                Text("En una Mac, sus sitios te dan la app de macOS. Riftway descarga el instalador de Windows del servidor del fabricante y solo lo usa si él lo firmó.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(StoreLaunchers.all) { launcher in
                        LauncherRow(launcher: launcher, model: model)
                        if launcher.id != StoreLaunchers.all.last?.id { Divider().padding(.leading, 76) }
                    }
                }
            }
            Divider()
            HStack {
                Text("Los que dicen \"Sin probar\" pueden no abrir todavía en Riftway.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 560)
    }
}

private struct LauncherRow: View {
    let launcher: StoreLauncher
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(String(launcher.name.prefix(1)))
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing)))
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
