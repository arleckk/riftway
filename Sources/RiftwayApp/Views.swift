import AppKit
import RiftwayCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case library, playing, runtimes
}

/// The main window: a sidebar and the library, the games open now or the
/// installed runtimes (PRD-04).
struct LibraryView: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryModel
    @Bindable var updates: UpdateModel
    @State private var isTargeted = false
    @State private var item: SidebarItem? = .library
    @State private var search = ""
    let controllers: ControllerStatus
    let pad: PadNavigation
    /// The game page open over the current section, if any.
    @State private var path: [String] = []

    init(model: AppModel, library: LibraryModel, updates: UpdateModel, controllers: ControllerStatus,
         pad: PadNavigation = PadNavigation(), item: SidebarItem = .library) {
        self.model = model
        self.library = library
        self.updates = updates
        self.controllers = controllers
        self.pad = pad
        _item = State(initialValue: item)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(item: $item, library: library, controllers: controllers)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas)
                    .navigationDestination(for: String.self) { id in
                        GamePage(id: id, library: library, close: { path.removeAll() }, pad: pad)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.canvas)
                    }
            }
            .safeAreaInset(edge: .bottom) {
                if pad.isActive, let family = controllers.pads.first?.family {
                    PadHints(family: family, hints: hints)
                }
            }
        }
        .tint(Theme.violet)
        .onChange(of: item) { path.removeAll() }
        .onChange(of: pad.event) {
            if let command = pad.event?.command { handle(command) }
        }
        .onChange(of: library.requestedPage, initial: true) {
            guard let id = library.requestedPage else { return }
            library.requestedPage = nil
            item = .library
            // After the section change, which empties the path.
            Task { @MainActor in path = [id] }
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
                             let profile = file.profile
                             model.dismissCurrent()
                             library.install(report, profile: profile)
                         })
        }
        .sheet(item: $library.job) { job in
            InstallView(job: job, library: library)
        }
        .sheet(isPresented: $updates.showsSheet) {
            UpdateView(updates: updates, library: library)
        }
        .sheet(isPresented: $model.showsAssociationOffer) {
            AssociationOfferView { model.associationOfferAnswered(accept: $0) }
        }
        .alert("Riftway", isPresented: Binding(get: { library.problem != nil }, set: { if !$0 { library.problem = nil } })) {
            Button("Aceptar") { library.problem = nil }
        } message: {
            Text(library.problem ?? "")
        }
        .onAppear {
            library.reload()
            library.startWatching()
            controllers.start()
        }
    }

    private func open(_ entry: LibraryEntry) { path = [entry.id] }

    /// The covers the controller moves through: the grid shown.
    private var navigable: [LibraryEntry] {
        switch item ?? .library {
        case .library: library.entries.filter { search.isEmpty || $0.game.name.localizedCaseInsensitiveContains(search) }
        case .playing: library.entries.filter { library.running.contains($0.id) }
        case .runtimes: []
        }
    }

    private var hints: [(ControllerButton, String)] {
        if !path.isEmpty { return [(.a, "Jugar"), (.l1, "Pestaña"), (.b, "Volver"), (.start, "Modo sillón")] }
        if navigable.isEmpty { return [(.l1, "Sección"), (.start, "Modo sillón")] }
        return [(.a, "Abrir"), (.y, "Jugar"), (.l1, "Sección"), (.start, "Modo sillón")]
    }

    /// A controller command in the window. On a game's page only ○ is the
    /// window's (back to the grid); the page takes the rest. The controller
    /// never stops a game here: that stays a click, or the couch mode's options.
    private func handle(_ command: CouchCommand) {
        guard path.isEmpty else {
            if command == .back { path.removeAll() }
            return
        }
        let games = navigable
        switch command {
        case .left, .right, .up, .down:
            let index = games.firstIndex { $0.id == pad.focused }
            pad.focused = CoverGridFocus.move(index, command, count: games.count, columns: pad.columns).map { games[$0].id }
        case .confirm, .options:
            // The first press shows where the focus is.
            guard let entry = games.first(where: { $0.id == pad.focused }) else {
                pad.focused = games.first?.id
                return
            }
            if command == .confirm {
                open(entry)
            } else if !library.running.contains(entry.id) && entry.canPlay {
                library.play(entry)
            }
        case .previousSection, .nextSection:
            let all: [SidebarItem] = [.library, .playing, .runtimes]
            let index = all.firstIndex(of: item ?? .library) ?? 0
            item = all[(index + (command == .nextSection ? 1 : all.count - 1)) % all.count]
        case .back:
            if !search.isEmpty { search = "" }
        case .menu:
            break
        }
    }

    @ViewBuilder private var detail: some View {
        switch item ?? .library {
        case .library: LibraryPage(model: model, library: library, search: $search, isTargeted: isTargeted, pad: pad, open: open)
        case .playing: PlayingPage(library: library, pad: pad, open: open)
        case .runtimes: RuntimesPage(library: library)
        }
    }
}

private struct Sidebar: View {
    @Binding var item: SidebarItem?
    let library: LibraryModel
    let controllers: ControllerStatus

    var body: some View {
        List(selection: $item) {
            Label("Biblioteca", systemImage: "square.grid.2x2").tag(SidebarItem.library)
            Label("Jugando", systemImage: "play.circle").badge(library.running.count).tag(SidebarItem.playing)
            Section("Sistema") {
                Label("Runtimes", systemImage: "shippingbox").tag(SidebarItem.runtimes)
            }
        }
        .safeAreaInset(edge: .bottom) { SidebarFooter(controllers: controllers) }
    }
}

/// The connected controller and the way to Settings, at the sidebar's foot.
private struct SidebarFooter: View {
    let controllers: ControllerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pad = controllers.pads.first {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pad.name).font(.caption.weight(.medium)).lineLimit(1)
                        Text(pad.batteryText ?? "Conectado")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .accessibilityElement(children: .combine)
            }
            Button {
                NSApp.sendAction(Selector(("toggleCouchMode:")), to: nil, from: nil)
            } label: {
                FooterLabel(title: "Modo sillón", symbol: "sofa")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Riftway en pantalla completa, para jugar desde el sillón solo con el control (Options en el control)")
            Button {
                NSApp.sendAction(Selector(("showSettings:")), to: nil, from: nil)
            } label: {
                FooterLabel(title: "Ajustes", symbol: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// A footer button's label, its symbol in a fixed column so the titles line up.
private struct FooterLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).frame(width: 22)
        }
    }
}

// MARK: Pages

private struct LibraryPage: View {
    @Bindable var model: AppModel
    @Bindable var library: LibraryModel
    @Binding var search: String
    let isTargeted: Bool
    let pad: PadNavigation
    let open: (LibraryEntry) -> Void

    var body: some View {
        let shown = library.entries.filter { search.isEmpty || $0.game.name.localizedCaseInsensitiveContains(search) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if SystemRequirements.needsRosetta {
                    PageNotice(symbol: "exclamationmark.triangle.fill",
                               text: "Los juegos de Windows necesitan Rosetta 2. Instálalo desde Terminal con: softwareupdate --install-rosetta")
                }
                if library.runtimes.isEmpty {
                    PageNotice(symbol: "shippingbox", text: "Falta el runtime de Windows. Mientras no haya descargas, elige un runtime compilado.",
                               action: ("Elegir runtime…", { library.chooseRuntime() }))
                }
                if library.entries.isEmpty {
                    EmptyLibrary(isTargeted: isTargeted) { model.chooseFiles() }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search).frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    CoverGrid(entries: shown, library: library, add: search.isEmpty ? { model.chooseFiles() } : nil, pad: pad, open: open)
                }
            }
            .padding(24)
        }
        .overlay {
            if isTargeted && !library.entries.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.violet, lineWidth: 2).padding(10)
            }
        }
        .navigationTitle("Biblioteca")
        .navigationSubtitle(library.entries.count == 1 ? "1 juego" : "\(library.entries.count) juegos")
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseFiles() } label: { Label("Instalar juego", systemImage: "plus") }
                    .help("Instala un juego desde su instalador de Windows (⌘O)")
            }
        }
    }
}

private struct PlayingPage: View {
    @Bindable var library: LibraryModel
    let pad: PadNavigation
    let open: (LibraryEntry) -> Void

    var body: some View {
        let games = library.entries.filter { library.running.contains($0.id) }
        Group {
            if games.isEmpty {
                ContentUnavailableView("Ningún juego abierto", systemImage: "play.circle",
                                       description: Text("Los juegos que abras desde Riftway o desde su sitio aparecen aquí."))
            } else {
                ScrollView {
                    CoverGrid(entries: games, library: library, add: nil, pad: pad, open: open).padding(24)
                }
            }
        }
        .navigationTitle("Jugando")
        .navigationSubtitle("")
    }
}

private struct RuntimesPage: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Group {
            if library.runtimes.isEmpty {
                ContentUnavailableView {
                    Label("Sin runtimes", systemImage: "shippingbox")
                } description: {
                    Text("El runtime es el Windows de Riftway: Wine, DXMT y los decodificadores de video.")
                } actions: {
                    Button("Instalar runtime…") { library.chooseRuntime() }
                }
            } else {
                List {
                    Section {
                        ForEach(Array(library.runtimes.enumerated()), id: \.element.version) { index, installed in
                            RuntimeRow(installed: installed, isDefault: index == 0,
                                       games: library.entries.filter { $0.record.runtimeVersion == installed.version }.map(\.game.name))
                        }
                    } footer: {
                        Text("Cada juego usa el runtime con el que se instaló o al que lo cambiaste; los juegos nuevos usan el más reciente.")
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Runtimes")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { library.chooseRuntime() } label: { Label("Instalar runtime", systemImage: "plus") }
                    .help("Instala un runtime compilado")
            }
        }
    }
}

private struct RuntimeRow: View {
    let installed: RiftwayHome.InstalledRuntime
    let isDefault: Bool
    let games: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.title3).foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(installed.version).font(.body.weight(.medium))
                    if isDefault {
                        Text("Para juegos nuevos").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(Theme.violet)
                            .background(Capsule().fill(Theme.violet.opacity(0.14)))
                    }
                }
                Text(games.isEmpty ? "Sin juegos" : games.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: installed.runtime.root)])
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Pieces

/// A warning that the page needs something (Rosetta, a runtime), as a card.
private struct PageNotice: View {
    let symbol: String
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.playable)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.playable.opacity(0.12)))
    }
}

/// The library before the first game: an invitation to drop an installer.
private struct EmptyLibrary: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "arrow.down").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .scaleEffect(isTargeted ? 1.08 : 1)
            .animation(.snappy, value: isTargeted)
            VStack(spacing: 6) {
                Text("Arrastra aquí un instalador de Windows").font(.title3.weight(.semibold))
                Text("Archivos .exe o .msi. También puedes darles doble clic en Finder.").foregroundStyle(.secondary)
            }
            Button("Elegir archivo…", action: choose)
                .keyboardShortcut("o")
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Theme.violet : Color.secondary.opacity(0.35))
        }
    }
}

/// Verified, playable or blocked; nothing for untested games (PRD-05).
struct StatusBadge: View {
    let compatibility: Compatibility

    var body: some View {
        if compatibility.status != .untested || !compatibility.anticheat.isEmpty {
            Text(compatibility.status == .untested ? "Anti-cheat" : ReportText.status(compatibility.status))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }

    private var color: Color {
        compatibility.status == .untested ? Theme.playable : Theme.color(compatibility.status)
    }
}

/// The badge and the explanation, for the analysis and result screens.
struct CompatibilityNotice: View {
    let compatibility: Compatibility
    let installed: Bool

    var body: some View {
        let text = ReportText.compatibility(compatibility, installed: installed)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Compatibilidad").font(.callout.weight(.medium))
                StatusBadge(compatibility: compatibility)
            }
            Notice(text: text.text, tone: text.tone, symbol: compatibility.status == .verified ? "checkmark.seal" : nil)
        }
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
            if file.report == nil || isInstaller || isPortable {
                InstallSteps(current: 0).padding(.horizontal, 20).padding(.top, 18)
            }
            if let report = file.report {
                ReportContent(report: report)
                if isInstaller || isPortable {
                    CompatibilityNotice(compatibility: Compatibility(profile: file.profile), installed: false)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                }
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
                Button(isPortable ? "Agregar a la biblioteca" : "Instalar") { if let report = file.report { install(report) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(isInstaller || isPortable) || !canInstall)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    private var isInstaller: Bool {
        if case .installer = file.report?.kind { return true }
        return false
    }

    private var isPortable: Bool {
        if case .portable = file.report?.kind { return true }
        return false
    }

    private var note: String? {
        guard let report = file.report else { return nil }
        if (isInstaller || isPortable) && !canInstall { return "Falta el runtime de Windows." }
        if isPortable {
            let (_, wholeFolder) = Installation.portableSource(for: report.file)
            return wholeFolder ? "Se copia su carpeta a una botella nueva." : "Se copia el programa a una botella nueva."
        }
        return nil
    }
}

struct InstallView: View {
    @Bindable var job: InstallJob
    let library: LibraryModel
    @State private var confirmStop = false
    /// The last step that ran, for a stop or a failure.
    @State private var lastStep = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            InstallSteps(current: step.index, done: step.done, failed: step.failed)
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
        .onChange(of: job.phase, initial: true) {
            if case .running(let stage) = job.phase { lastStep = Self.step(stage) }
        }
    }

    private static func step(_ stage: Installation.Stage) -> Int {
        switch stage {
        case .creatingBottle, .copyingInstaller: 1
        case .runningInstaller: 2
        case .discovering: 3
        }
    }

    private var step: (index: Int, done: Bool, failed: Bool) {
        switch job.phase {
        case .running(let stage): (Self.step(stage), false, false)
        case .stopping: (lastStep, false, false)
        case .result: (3, true, false)
        case .failed: (lastStep, false, true)
        }
    }

    private var title: String {
        switch job.phase {
        case .result: job.result.isEmpty ? (job.result.uninstall.isEmpty ? "El instalador no dejó nada para abrir" : "Componente instalado")
                                         : "Listo: \(job.name)"
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
        case .copyingInstaller: "Copiando a la botella…"
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
            if result.isEmpty, let component = result.uninstall.first?.displayName {
                Text("Se instaló \(component), pero no dejó programas para abrir: es un componente, como Visual C++ o DirectX, que otros programas usan. Puedes conservar la botella para instalar ahí el programa que lo necesita.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if result.isEmpty {
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
                let compatibility = Compatibility(profile: job.installation.setup.profile, anticheat: result.anticheat)
                if compatibility.profile != nil || !compatibility.anticheat.isEmpty {
                    CompatibilityNotice(compatibility: compatibility, installed: true)
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
    let updates: UpdateModel
    let library: LibraryModel
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
            UpdateSettings(updates: updates)
            UninstallSettings(library: library)
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

/// What Play starts: what the installer left, a launch link the player pastes
/// (remembered from the site or pasted; kept outside the bottle), or a program
/// of the bottle with its own arguments.
struct PlaySettingsView: View {
    enum Mode: Hashable { case discovered, link, command }

    let entry: LibraryEntry
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var scheme: String
    @State private var link: String
    /// The link saved when the sheet opened.
    private let savedLink: String
    @State private var path: String
    @State private var arguments: String
    @State private var problem: String?

    init(entry: LibraryEntry, library: LibraryModel) {
        self.entry = entry
        self.library = library
        let game = entry.game
        switch game.customLaunch {
        case .link(let scheme)?:
            _mode = State(initialValue: .link)
            _scheme = State(initialValue: scheme)
        case .command?:
            _mode = State(initialValue: .command)
            _scheme = State(initialValue: game.schemes.first ?? "")
        case nil:
            _mode = State(initialValue: .discovered)
            _scheme = State(initialValue: game.schemes.first ?? "")
        }
        savedLink = (try? entry.secrets.read(account: game.secretAccount)) ?? ""
        _link = State(initialValue: savedLink)
        if case .command(let path, let arguments)? = game.customLaunch {
            _path = State(initialValue: path)
            _arguments = State(initialValue: arguments ?? "")
        } else {
            let fallback = game.primary?.windowsPath ?? game.programs.compactMap(\.windowsPath).first ?? ""
            _path = State(initialValue: fallback)
            _arguments = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Qué abre Jugar en \(entry.game.name)").font(.title3.weight(.semibold))
            Picker("", selection: $mode) {
                Text(discoveredLabel).tag(Mode.discovered)
                if !entry.game.schemes.isEmpty { Text("Un enlace del juego, como dsropen:…").tag(Mode.link) }
                Text("Un programa de la botella con argumentos").tag(Mode.command)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch mode {
            case .discovered:
                EmptyView()
            case .link:
                if entry.game.schemes.count > 1 {
                    Picker("Esquema", selection: $scheme) {
                        ForEach(entry.game.schemes, id: \.self) { Text("\($0):").tag($0) }
                    }
                }
                Text(linkStatus).font(.callout)
                TextField("\(scheme):…", text: $link, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.callout, design: .monospaced))
                Text("Jugar usa el último enlace que el sitio le mandó al juego; se recuerda solo cada vez que entras desde el sitio, y aquí puedes pegar o corregir uno. Si lo dejas vacío, Jugar abre el sitio hasta el próximo. Se guarda solo para tu usuario, fuera de la botella, y en los logs sale censurado.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .command:
                TextField("Programa (ruta de Windows)", text: $path)
                TextField("Argumentos", text: $arguments)
                Text("Por ejemplo: C:\\Program Files\\Juego\\Juego.exe con -dx11.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var discoveredLabel: String {
        switch entry.game.primary?.target {
        case .web(let url)?: "Lo que dejó el instalador: el sitio (\(URL(string: url)?.host ?? url))"
        case .executable(let path, _)?: "Lo que dejó el instalador: \(path.split(separator: "\\").last ?? "")"
        case nil: "Lo que dejó el instalador"
        }
    }

    private var linkStatus: String {
        guard let date = entry.secrets.savedDate(account: entry.game.secretAccount) else {
            return "Aún no hay enlace guardado: la próxima vez que des Start en el sitio, se recordará."
        }
        return "Enlace guardado " + date.formatted(.relative(presentation: .named)) + "."
    }

    private var canSave: Bool {
        switch mode {
        case .discovered, .link: true
        case .command: path.lowercased().hasSuffix(".exe")
        }
    }

    private func save() {
        do {
            switch mode {
            case .discovered:
                try library.setCustomLaunch(entry, nil, link: nil)
            case .link:
                let edited = link.trimmingCharacters(in: .whitespacesAndNewlines)
                if edited.isEmpty { try entry.secrets.delete(account: entry.game.secretAccount) }
                try library.setCustomLaunch(entry, .link(scheme: scheme),
                                            link: edited.isEmpty || edited == savedLink ? nil : edited)
            case .command:
                try library.setCustomLaunch(entry, .command(path: path, arguments: arguments.isEmpty ? nil : arguments), link: nil)
            }
            dismiss()
        } catch {
            problem = "\(error)"
        }
    }
}
