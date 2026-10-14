import AppKit
import RiftwayCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if library.runtimes.isEmpty {
                RuntimeBanner { library.chooseRuntime() }
            }
            if library.entries.isEmpty {
                DropZone(isTargeted: isTargeted) { model.chooseFiles() }
            } else {
                GameGrid(library: library) { model.chooseFiles() }
                    .overlay {
                        if isTargeted {
                            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
                        }
                    }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open([url]) }
                }
            }
            return true
        }
        .sheet(item: Binding(get: { model.current }, set: { if $0 == nil { model.dismissCurrent() } })) { file in
            AnalysisView(file: file, remaining: model.remaining, canInstall: !library.runtimes.isEmpty,
                         close: { model.dismissCurrent() },
                         install: { report in
                             model.dismissCurrent()
                             library.install(report)
                         })
        }
        .sheet(item: $library.job) { job in
            InstallView(job: job, library: library)
        }
        .sheet(isPresented: $model.showsAssociationOffer) {
            AssociationOfferView { model.associationOfferAnswered(accept: $0) }
        }
        .alert("Riftway", isPresented: Binding(get: { library.problem != nil }, set: { if !$0 { library.problem = nil } })) {
            Button("Aceptar") { library.problem = nil }
        } message: {
            Text(library.problem ?? "")
        }
        .onAppear { library.reload() }
    }
}

private struct RuntimeBanner: View {
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.orange)
            Text("Falta el runtime de Windows. Mientras no haya descargas, elige un runtime compilado.")
                .font(.callout)
            Spacer()
            Button("Elegir runtime…", action: choose)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
}

private struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            VStack(spacing: 6) {
                Text("Arrastra aquí un instalador de Windows")
                    .font(.title3.weight(.semibold))
                Text("Archivos .exe o .msi. También puedes darles doble clic en Finder.")
                    .foregroundStyle(.secondary)
            }
            Button("Elegir archivo…", action: choose)
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        }
    }
}

private struct GameGrid: View {
    @Bindable var library: LibraryModel
    let add: () -> Void
    @State private var trashCandidate: LibraryEntry?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)], spacing: 18) {
                ForEach(library.entries) { entry in
                    GameTile(entry: entry, icon: library.icons[entry.id], isRunning: library.running.contains(entry.id),
                             play: { library.play(entry) }, stop: { library.stop(entry) })
                        .contextMenu { menu(entry) }
                }
                AddTile(action: add)
            }
            .padding(20)
        }
        .confirmationDialog("¿Mover \(trashCandidate?.game.name ?? "") a la Papelera?",
                            isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }),
                            presenting: trashCandidate) { entry in
            Button("Mover a la Papelera", role: .destructive) { library.moveToTrash(entry) }
        } message: { _ in
            Text("Se mueven a la Papelera la botella (con el juego y sus partidas locales) y su app puente. Puedes recuperarlas desde ahí.")
        }
    }

    @ViewBuilder private func menu(_ entry: LibraryEntry) -> some View {
        Button("Jugar") { library.play(entry) }
        let others = entry.game.programs.filter { $0.id != entry.game.primary?.id }
        if !others.isEmpty {
            Menu("Abrir otro programa") {
                ForEach(others) { program in Button(program.name) { library.play(entry, program: program) } }
            }
        }
        if library.running.contains(entry.id) {
            Button("Terminar todos sus procesos") { library.stop(entry) }
        }
        Divider()
        Toggle("Modo diagnóstico", isOn: Binding(get: { entry.record.options.diagnostics },
                                                 set: { library.setDiagnostics(entry, $0) }))
        Button("Abrir logs") { library.showLogs(entry) }
        Button("Abrir disco C: en Finder") { library.showDriveC(entry) }
        Button("Reconstruir app puente") { library.rebuildBridge(entry) }
        Divider()
        Button("Mover a la Papelera…", role: .destructive) { trashCandidate = entry }
    }
}

private struct GameTile: View {
    let entry: LibraryEntry
    let icon: NSImage?
    let isRunning: Bool
    let play: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "gamecontroller").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            VStack(spacing: 2) {
                Text(entry.game.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if isRunning {
                Button(action: stop) { Label("Detener", systemImage: "stop.fill") }
            } else {
                Button(action: play) { Label("Jugar", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(entry.game.primary == nil || (entry.runtime == nil && entry.game.primary?.windowsPath != nil))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var subtitle: String {
        if isRunning { return "Abierto" }
        if entry.runtime == nil { return "Falta el runtime \(entry.record.runtimeVersion)" }
        if entry.game.primary == nil { return "Sin programa para abrir" }
        if case .web = entry.game.primary?.target { return "Se abre desde su sitio" }
        return entry.game.publisher ?? ""
    }
}

private struct AddTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 30, weight: .light))
                Text("Instalar un juego…").font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 190)
            .background {
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
    }
}

struct AnalysisView: View {
    let file: PendingFile
    let remaining: Int
    let canInstall: Bool
    let close: () -> Void
    let install: (InstallerReport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = file.report {
                ReportContent(report: report)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Analizando \(file.url.lastPathComponent)…")
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
            Divider()
            HStack {
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                Button(remaining > 0 ? "Siguiente (\(remaining))" : "Cerrar", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Instalar") { if let report = file.report { install(report) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isInstaller || !canInstall)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private var isInstaller: Bool {
        if case .installer = file.report?.kind { return true }
        return false
    }

    private var note: String? {
        guard let report = file.report else { return nil }
        if case .portable = report.kind { return "Agregar programas sin instalador llega pronto." }
        if isInstaller && !canInstall { return "Falta el runtime de Windows." }
        return nil
    }
}

struct InstallView: View {
    @Bindable var job: InstallJob
    let library: LibraryModel
    @State private var confirmStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            switch job.phase {
            case .running(let stage):
                running(stage)
            case .stopping:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Deteniendo el instalador…") }
            case .result:
                InstallResultView(job: job, library: library)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Conservar la botella") { library.discardInstall(job, keepBottle: true) }
                    Button("Mover la botella a la Papelera") { library.discardInstall(job, keepBottle: false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch job.phase {
        case .result: job.result.isEmpty ? "El instalador no dejó nada para abrir" : "Listo: \(job.name)"
        case .failed: "No se completó la instalación"
        default: "Instalando \(job.name)"
        }
    }

    @ViewBuilder private func running(_ stage: Installation.Stage) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(stageText(stage))
        }
        if stage == .runningInstaller {
            Text("El asistente del instalador se abrió en su propia ventana. Complétalo ahí; Riftway sigue cuando termine.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Detener…") { confirmStop = true }
        }
        .confirmationDialog("¿Detener la instalación?", isPresented: $confirmStop) {
            Button("Detener", role: .destructive) { library.stopInstall(job) }
        } message: {
            Text("Se cierran el instalador y todo lo que haya abierto en esta botella.")
        }
    }

    private func stageText(_ stage: Installation.Stage) -> String {
        switch stage {
        case .creatingBottle: "Preparando una botella nueva de Windows…"
        case .copyingInstaller: "Copiando el instalador a la botella…"
        case .runningInstaller: "Esperando al instalador…"
        case .discovering: "Buscando lo que instaló…"
        }
    }
}

private struct InstallResultView: View {
    @Bindable var job: InstallJob
    let library: LibraryModel

    var body: some View {
        let result = job.result
        VStack(alignment: .leading, spacing: 14) {
            if result.isEmpty {
                Text("No encontré accesos directos ni programas nuevos. Puede que cancelaras el asistente o que el instalador falló.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let programs = choices(result)
                if !programs.isEmpty {
                    Picker("Jugar abre", selection: $job.primaryID) {
                        ForEach(programs) { program in
                            Text(label(program)).tag(Optional(program.id))
                        }
                    }
                }
                if !result.protocols.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enlaces que abre desde macOS").font(.callout.weight(.medium))
                        ForEach(result.protocols, id: \.scheme) { registration in
                            Toggle("\(registration.scheme):", isOn: Binding(
                                get: { job.schemes.contains(registration.scheme) },
                                set: { if $0 { job.schemes.insert(registration.scheme) } else { job.schemes.remove(registration.scheme) } }))
                        }
                        Toggle("Abrir siempre estos enlaces con el juego", isOn: $job.makeDefaultHandler)
                            .disabled(job.schemes.isEmpty)
                        Text("Así, el botón de jugar de su sitio web abre el juego en esta Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !result.drivers.isEmpty {
                    Label("Instaló un driver de kernel (\(result.drivers.map(\.name).joined(separator: ", "))). Wine no puede cargarlo; si es un anti-cheat, el juego en línea podría no funcionar.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if result.isEmpty {
                    Button("Conservar la botella") { library.discardInstall(job, keepBottle: true) }
                    Button("Mover la botella a la Papelera") { library.discardInstall(job, keepBottle: false) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Agregar a la biblioteca") { library.finishInstall(job) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Shortcuts first, then the largest new programs, in case the installer's
    /// shortcut is not the one to play.
    private func choices(_ result: InstallResult) -> [DiscoveredProgram] {
        var list = result.programs
        if let primary = result.primary, !list.contains(where: { $0.id == primary.id }) { list.insert(primary, at: 0) }
        for path in result.executables.prefix(4) {
            let program = DiscoveredProgram.executable(path)
            if !list.contains(where: { $0.id == program.id }) { list.append(program) }
        }
        return list
    }

    private func label(_ program: DiscoveredProgram) -> String {
        switch program.target {
        case .web(let url): "\(program.name) (sitio: \(URL(string: url)?.host ?? url))"
        case .executable(let path, _): "\(program.name) (\(path.split(separator: "\\").last ?? ""))"
        }
    }
}

struct ReportContent: View {
    let report: InstallerReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                icon
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.displayName).font(.title2.weight(.semibold)).lineLimit(2)
                    let subtitle = [report.company, report.version.map { "versión \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                    Text(ReportText.kind(report.kind))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .padding(.top, 2)
                }
            }

            if case .unsupported(let reason) = report.kind {
                Notice(text: ReportText.unsupported(reason), tone: .problem)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                Fact("Archivo", "\(report.file.lastPathComponent) · \(ReportText.size(report.fileSize))")
                if let arch = report.architecture { Fact("Arquitectura", arch) }
                if let origin = ReportText.origin(report.origin) { Fact("Descargado de", origin) }
                if let level = ReportText.executionLevel(report.executionLevel) { Fact("Permisos", level) }
                if report.isDotNet { Fact("Requiere", ".NET (se instalará en la botella)") }
                if !report.companions.isEmpty {
                    Fact("Archivos adicionales", report.companions.map(\.lastPathComponent).joined(separator: ", "))
                }
            }

            let signature = ReportText.signature(report.signature)
            Notice(text: signature.text, tone: signature.tone, symbol: "signature")
        }
        .padding(20)
    }

    @ViewBuilder private var icon: some View {
        if let data = report.icon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Notice: View {
    let text: String
    let tone: ReportText.Tone
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol ?? (tone == .problem ? "exclamationmark.octagon" : "exclamationmark.triangle"))
                .foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(tone == .neutral ? 0.08 : 0.12)))
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .caution: .orange
        case .problem: .red
        }
    }
}

struct AssociationOfferView: View {
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("¿Abrir los archivos de Windows con Riftway?")
                .font(.title3.weight(.semibold))
            Text("Así, al darle doble clic a un instalador .exe o .msi en Finder, Riftway lo revisa y te ayuda a instalarlo. macOS te pedirá confirmarlo. Puedes cambiarlo cuando quieras en Ajustes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Ahora no") { answer(false) }.keyboardShortcut(.cancelAction)
                Button("Usar Riftway") { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct SettingsView: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Archivos de Windows") {
                row("Programas (.exe)", FileAssociation.executable)
                row("Instaladores (.msi)", FileAssociation.installer)
                if !FileAssociation.isRiftwayDefaultForAll {
                    Button("Abrir ambos con Riftway") {
                        Task { await FileAssociation.makeRiftwayDefault(); refresh += 1 }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .frame(width: 460)
        .fixedSize()
    }

    private func row(_ title: String, _ type: UTType) -> some View {
        LabeledContent(title) {
            if FileAssociation.isRiftwayDefault(for: type) {
                Label("Riftway", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(FileAssociation.handlerName(for: type) ?? "Ninguna app").foregroundStyle(.secondary)
            }
        }
    }
}
