import AppKit
import RiftwayCore
import SwiftUI

/// The game launchers Riftway downloads for Windows (PRD-01 R1.6): on a Mac
/// their sites give the macOS app. Each one goes to the analysis sheet and
/// installs like any installer.
struct LaunchersPage: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("En una Mac, sus sitios te dan la app de macOS. Riftway descarga el instalador de Windows del servidor del fabricante y solo lo usa si él lo firmó; luego lo instalas como cualquier juego.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(StoreLaunchers.all) { launcher in
                        LauncherRow(launcher: launcher, installed: StoreLaunchers.installed(launcher, in: library.entries).first,
                                    model: model, library: library)
                        if launcher.id != StoreLaunchers.all.last?.id { Divider().padding(.leading, 76) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                Text("Los que dicen \"Sin probar\" pueden no abrir todavía en Riftway.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Launchers")
        .navigationSubtitle("Instaladores de Windows")
    }
}

private struct LauncherRow: View {
    let launcher: StoreLauncher
    /// Its entry in the library, when it is installed.
    let installed: LibraryEntry?
    @Bindable var model: AppModel
    @Bindable var library: LibraryModel

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
                    if installed != nil {
                        Label("Instalado", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.verified)
                    } else {
                        Text(launcher.tested ? "Probado con Riftway" : "Sin probar")
                            .foregroundStyle(launcher.tested ? Theme.verified : .secondary)
                    }
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
            } else if let installed {
                Button("Abrir") { library.requestedPage = installed.id }
                    .help("Su página en la biblioteca")
                Menu {
                    Button("Descargar el instalador otra vez") { model.getLauncher(launcher) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Más opciones")
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

/// Asks before adding the games a launcher installed (PRD-04 R1.6): each with
/// its cover, chosen by default. Those left out are not offered again; the
/// launcher's page still lists them.
struct StoreOfferView: View {
    let offer: LibraryModel.StoreOffer
    let answer: ([InstalledStoreGame]) -> Void
    @State private var chosen: Set<String>

    init(offer: LibraryModel.StoreOffer, answer: @escaping ([InstalledStoreGame]) -> Void) {
        self.offer = offer
        self.answer = answer
        _chosen = State(initialValue: Set(offer.games.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(offer.games.count == 1 ? "\(offer.launcher.game.name) instaló un juego nuevo"
                     : "\(offer.launcher.game.name) instaló \(offer.games.count) juegos nuevos")
                    .font(.title2.weight(.bold))
                Text("¿Lo agregas a tu biblioteca? Tendrá su portada y un acceso directo en Aplicaciones, y Jugar lo abrirá con \(offer.launcher.game.name).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(offer.games) { game in
                        Toggle(isOn: Binding(get: { chosen.contains(game.id) },
                                             set: { if $0 { chosen.insert(game.id) } else { chosen.remove(game.id) } })) {
                            HStack(spacing: 12) {
                                StoreCoverThumbnail(url: game.cover).frame(width: 44)
                                Text(game.name).font(.headline)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            HStack {
                Text("Los que no agregues siguen en la página de \(offer.launcher.game.name).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ahora no") { answer([]) }.keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Agregar \(chosen.count)" : "Agregar") {
                    answer(offer.games.filter { chosen.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
