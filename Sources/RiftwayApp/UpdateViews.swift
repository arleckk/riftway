import AppKit
import RiftwayCore
import SwiftUI

struct UpdateView: View {
    @Bindable var updates: UpdateModel
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actualizaciones").font(.title3.weight(.semibold))
            switch updates.phase {
            case .idle, .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Buscando actualizaciones…") }
            case .installing(let message):
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(message) }
            case .upToDate:
                Label("Riftway \(Riftway.version) está al día.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .available:
                available
            }
            HStack {
                Spacer()
                Button("Cerrar") { updates.showsSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var available: some View {
        if let app = updates.newApp {
            VStack(alignment: .leading, spacing: 6) {
                Text("Riftway \(app.version) está disponible (tienes \(Riftway.version)).").font(.callout.weight(.medium))
                if let notes = app.notes { Text(notes).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Se verifica la firma de la descarga, Riftway se cierra, se reemplaza y vuelve a abrir. Tus juegos siguen igual.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Instalar y reabrir") { updates.installApp(app) }.buttonStyle(.borderedProminent)
            }
        }
        if !updates.newRuntimes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(updates.newRuntimes, id: \.version) { runtime in
                    HStack {
                        Text("Runtime \(runtime.version) · \(runtime.download.size / 1_000_000) MB").font(.callout.weight(.medium))
                        Spacer()
                        Button("Descargar") { updates.installRuntime(runtime) { library.reload() } }
                    }
                }
                Text("Los juegos que ya tienes siguen con su runtime; los que instales después usan el más reciente.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UpdateSettings: View {
    @Bindable var updates: UpdateModel
    @State private var automatic = true

    var body: some View {
        Section("Actualizaciones") {
            if let feed = updates.feedURL {
                Toggle("Buscar actualizaciones automáticamente", isOn: $automatic)
                    .onChange(of: automatic) { updates.automatic = automatic }
                LabeledContent("Fuente") { Text(feed.host ?? feed.absoluteString).foregroundStyle(.secondary) }
                LabeledContent("Última búsqueda") {
                    Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Nunca").foregroundStyle(.secondary)
                }
                Text("Es la única conexión que Riftway hace por su cuenta: descarga el feed firmado de versiones y perfiles de juegos, como mucho una vez al día. No envía datos tuyos.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Buscar ahora") { updates.check(manual: true) }
            } else {
                Text("Esta versión no tiene configurado dónde buscar actualizaciones: se actualiza compilando desde el código.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { automatic = updates.automatic }
    }
}

struct UninstallSettings: View {
    let library: LibraryModel
    @State private var confirming = false
    @State private var includeBottles = false

    var body: some View {
        Section("Desinstalar") {
            Button("Desinstalar Riftway…", role: .destructive) { confirming = true }
            Text("Mueve a la Papelera la app, sus apps puente y los runtimes. Nada se borra definitivamente.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("¿Desinstalar Riftway?").font(.title3.weight(.semibold))
                Text("Se cierran los juegos abiertos y se mueven a la Papelera Riftway, las apps puente de tus juegos (los enlaces del sitio dejan de abrirlos) y los runtimes.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("También mover a la Papelera los juegos instalados y sus partidas (\(library.entries.count))", isOn: $includeBottles)
                Text(includeBottles ? "Los juegos y partidas locales se pueden recuperar desde la Papelera hasta que la vacíes."
                                    : "Los juegos se quedan en ~/Library/Application Support/Riftway/Bottles para cuando vuelvas a instalar Riftway.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancelar") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Desinstalar", role: .destructive) {
                        let include = includeBottles
                        confirming = false
                        Task.detached {
                            Uninstaller().run(includingBottles: include)
                            await MainActor.run { NSApp.terminate(nil) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }
}

/// Apple Silicon needs Rosetta 2 for the runtime's x86_64 Wine (PRD-06 R3).
enum SystemRequirements {
    static var needsRosetta: Bool {
        #if arch(arm64)
        return !FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        #else
        return false
        #endif
    }

    /// The About panel's credits (R10): Riftway's license and the runtime's components.
    @MainActor static func credits(runtime: WineRuntime?) -> NSAttributedString {
        var text = "Riftway se distribuye bajo la licencia Apache 2.0.\n\n"
        if let runtime {
            let licenses = URL(fileURLWithPath: runtime.root).appendingPathComponent("licenses")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: licenses.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            if !names.isEmpty {
                text += "El runtime de Windows incluye componentes de terceros con sus propias licencias: " + names.joined(separator: ", ")
                    + ". Sus textos están en " + licenses.path + ", y el código fuente y los parches de cada runtime se publican junto con su versión.\n"
            }
        }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
    }
}
