import AppKit
import RiftwayCore
import SwiftUI

/// One game: its cover's colors as a header with Play, and what the per-game
/// menu had, in tabs (PRD-04 R1.3).
struct GamePage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Resumen", controls = "Control", compatibility = "Compatibilidad", advanced = "Avanzado"
        var id: Self { self }
    }

    let id: String
    @Bindable var library: LibraryModel
    /// Back to the grid (after the game moves to the Trash).
    let close: () -> Void
    /// The controller: L1/R1 change the tab, ✕ plays.
    let pad: PadNavigation?
    @State private var tab: Tab
    @State private var playSettings = false
    @State private var controllerSettings = false
    @State private var confirmTrash = false

    init(id: String, library: LibraryModel, close: @escaping () -> Void, pad: PadNavigation? = nil, tab: Tab = .summary) {
        self.id = id
        self.library = library
        self.close = close
        self.pad = pad
        _tab = State(initialValue: tab)
    }

    var body: some View {
        if let entry = library.entries.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GameHeader(entry: entry, library: library, controls: { controllerSettings = true })
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Sección", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        switch (tab, entry.game.store) {
                        case (.summary, let store?): StoreSummaryTab(entry: entry, store: store)
                        case (.summary, nil): SummaryTab(entry: entry, library: library)
                        case (.controls, let store?): StoreControlsTab(entry: entry, store: store, library: library)
                        case (.controls, nil): ControlsTab(entry: entry, edit: { controllerSettings = true })
                        case (.compatibility, _): CompatibilityTab(entry: entry, library: library)
                        case (.advanced, _): AdvancedTab(entry: entry, library: library, playSettings: { playSettings = true },
                                                         trash: { confirmTrash = true })
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(entry.game.name)
            .navigationSubtitle("")
            .onChange(of: pad?.event) {
                switch pad?.event?.command {
                case .previousSection?, .nextSection?:
                    let all = Tab.allCases
                    let index = all.firstIndex(of: tab)! + (pad?.event?.command == .nextSection ? 1 : all.count - 1)
                    tab = all[index % all.count]
                case .confirm?:
                    if !library.running.contains(entry.id) && entry.canPlay { library.play(entry) }
                default:
                    break
                }
            }
            .sheet(isPresented: $playSettings) { PlaySettingsView(entry: entry, library: library) }
            .sheet(isPresented: $controllerSettings) { ControllerEditorView(entry: entry, library: library) }
            .confirmationDialog(entry.game.store == nil ? "¿Mover \(entry.game.name) a la Papelera?" : "¿Quitar \(entry.game.name) de la biblioteca?",
                                isPresented: $confirmTrash) {
                Button(entry.game.store == nil ? "Mover a la Papelera" : "Quitar de la biblioteca", role: .destructive) {
                    close()
                    library.moveToTrash(entry)
                }
            } message: {
                Text(entry.game.store == nil
                     ? "Se mueven a la Papelera la botella (con el juego y sus partidas locales) y su app puente. Puedes recuperarlas desde ahí."
                     : "Se quitan su lugar en Riftway y su acceso directo. El juego sigue instalado en Steam.")
            }
        } else {
            ContentUnavailableView("Este juego ya no está en la biblioteca", systemImage: "questionmark.folder")
        }
    }
}

// MARK: Header

private struct GameHeader: View {
    let entry: LibraryEntry
    @Bindable var library: LibraryModel
    let controls: () -> Void

    private var palette: CoverPalette { library.palettes[entry.id] ?? .riftway }
    private var since: Date? { library.running.contains(entry.id) ? (library.runningSince[entry.id] ?? Date()) : nil }

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            GameCover(name: entry.game.name, icon: library.icons[entry.id], palette: palette, art: library.covers[entry.id])
                .coverDrop { library.setCover(entry, image: $0) }
                .frame(width: 120)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    HeaderPill(text: ReportText.status(entry.compatibility.status))
                    if let vendor = entry.profile?.anticheat?.vendor ?? entry.compatibility.anticheat.first?.vendor {
                        HeaderPill(text: vendor.displayName + ((entry.profile?.anticheat?.kernel ?? false) ? " · kernel" : ""))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let publisher = entry.game.publisher, !publisher.isEmpty {
                        Text(publisher).font(.callout).foregroundStyle(.white.opacity(0.75))
                    }
                    Text(entry.game.name).font(.largeTitle.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if since != nil {
                        Button { library.stop(entry) } label: { Label("Detener", systemImage: "stop.fill") }
                            .buttonStyle(.borderedProminent).tint(.black.opacity(0.45)).controlSize(.large)
                    } else {
                        Button { library.play(entry) } label: { Label("Jugar", systemImage: "play.fill") }
                            .buttonStyle(PlayButtonStyle(large: true))
                            .disabled(!entry.canPlay)
                            .keyboardShortcut(.defaultAction)
                    }
                    if let store = entry.game.store {
                        Button { library.openStoreLink(store.pageLink, for: entry) } label: { Label("Abrir en Steam", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.bordered).controlSize(.large).tint(.white)
                    } else {
                        Button(action: controls) { Label("Control", systemImage: "gamecontroller") }
                            .buttonStyle(.bordered).controlSize(.large).tint(.white)
                    }
                    let others = entry.game.store == nil ? entry.game.programs.filter { $0.id != entry.game.primary?.id } : []
                    if !others.isEmpty {
                        Menu {
                            ForEach(others) { program in Button(program.name) { library.play(entry, program: program) } }
                        } label: {
                            Label("Abrir otro programa", systemImage: "ellipsis")
                        }
                        .menuStyle(.button).buttonStyle(.bordered).controlSize(.large).tint(.white).fixedSize()
                    }
                }
                if let since {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("Jugando · \(SessionClock.elapsed(since: since, now: context.date))")
                    }
                    .font(.callout.weight(.medium)).foregroundStyle(Theme.cyan)
                } else if let problem {
                    Text(problem).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [Color(palette.top), Color(palette.bottom)], startPoint: .topTrailing, endPoint: .bottomLeading)
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var problem: String? {
        if entry.runtime == nil { return "Falta el runtime \(entry.record.runtimeVersion)" }
        if GameLauncher.primaryIsMissing(entry) { return "Falta el programa: revisa Configurar Jugar, en Avanzado" }
        if entry.game.primary == nil && entry.game.customLaunch == nil { return "Sin programa para abrir" }
        return nil
    }
}

private struct HeaderPill: View {
    let text: String

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
    }
}

enum SessionClock {
    /// "0:42": hours and minutes.
    static func elapsed(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}

// MARK: Tabs

private struct Fact: Identifiable {
    let label: String
    let value: String
    var detail: String?
    var id: String { label }
}

private struct FactGrid: View {
    let facts: [Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.label).font(.caption).foregroundStyle(.secondary)
                    Text(fact.value).font(.body.weight(.medium))
                    if let detail = fact.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A titled block of a tab.
private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct SummaryTab: View {
    let entry: LibraryEntry
    @Bindable var library: LibraryModel

    var body: some View {
        let options = entry.setup?.effectiveOptions ?? entry.record.options
        let layout = ControllerLayout.read(bottle: entry.root) ?? ControllerLayout()
        VStack(alignment: .leading, spacing: 18) {
            FactGrid(facts: [
                Fact(label: "Jugar abre", value: playTarget),
                Fact(label: "Gráficos", value: options.direct3D11 == .wined3d ? "wined3d (experimental)" : "DXMT",
                     detail: "Direct3D 10 y 11 sobre Metal"),
                Fact(label: "Game Mode", value: options.gameMode.isEmpty ? "No" : "Al jugar en pantalla completa",
                     detail: options.gameMode.isEmpty ? nil : options.gameMode.joined(separator: ", ")),
                controlFact(layout),
                Fact(label: "Runtime", value: entry.record.runtimeVersion,
                     detail: entry.runtime == nil ? "No está instalado" : nil),
                Fact(label: "Modo diagnóstico", value: options.diagnostics ? "Encendido" : "Apagado",
                     detail: options.diagnostics ? "Cada sesión deja un log" : nil),
            ])
            if let notes = entry.profile?.notes, !notes.isEmpty {
                Block(title: "Notas del perfil") {
                    Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StoreGamesBlock(launcher: entry, library: library)
        }
    }

    private var playTarget: String {
        switch entry.game.customLaunch {
        case .link?: return "Tu enlace guardado"
        case .command?: return "Tu comando"
        case nil: break
        }
        guard let primary = entry.game.primary else { return "Nada todavía" }
        if case .web = primary.target { return "Su sitio web" }
        return primary.name
    }

    /// The program the controller matters most for: one mapped to keys, else
    /// one in desktop mode, else every other program's mode.
    private func controlFact(_ layout: ControllerLayout) -> Fact {
        for mode in [InputMode.keyboard, .desktop] {
            if let program = layout.programs.keys.sorted().first(where: { layout.programs[$0]?.mode == mode }) {
                return Fact(label: "Control", value: ControllerEditorView.modeName(mode), detail: program)
            }
        }
        return Fact(label: "Control", value: ControllerEditorView.modeName(layout.otherPrograms))
    }
}

private struct ControlsTab: View {
    let entry: LibraryEntry
    let edit: () -> Void

    var body: some View {
        let layout = ControllerLayout.read(bottle: entry.root) ?? ControllerLayout()
        VStack(alignment: .leading, spacing: 18) {
            Block(title: "Por programa") {
                VStack(spacing: 0) {
                    ForEach(layout.programs.keys.sorted(), id: \.self) { name in
                        let controls = layout.programs[name]
                        row(name, ControllerEditorView.modeName(controls?.mode ?? .native), layers(controls))
                        Divider()
                    }
                    row("Otros programas", ControllerEditorView.modeName(layout.otherPrograms), nil)
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            }
            Button("Editar control…", action: edit).controlSize(.large)
        }
    }

    private func row(_ program: String, _ mode: String, _ detail: String?) -> some View {
        HStack {
            Text(program)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(mode).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 10)
    }

    private func layers(_ controls: ProgramControls?) -> String? {
        guard controls?.mode == .keyboard, let set = controls?.effectiveActionSet else { return nil }
        let names = set.layers.keys.sorted()
        return names.isEmpty ? "Sin capas" : "Capas: " + names.joined(separator: ", ")
    }
}

private struct CompatibilityTab: View {
    let entry: LibraryEntry
    @Bindable var library: LibraryModel

    var body: some View {
        let isOpen = library.running.contains(entry.id)
        VStack(alignment: .leading, spacing: 18) {
            CompatibilityNotice(compatibility: entry.compatibility, installed: true)
            if entry.game.store != nil {
                Text("Los perfiles de Riftway ajustan la botella, y esta es la de Steam: su perfil está en la página de Steam.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
            Block(title: "Perfil") {
                if let profile = entry.profile {
                    FactGrid(facts: [
                        Fact(label: "Perfil", value: profile.name, detail: ReportText.status(profile.status)),
                        Fact(label: "Revisión", value: "\(profile.revision)",
                             detail: entry.profileIsStale ? "Aplicada: \(entry.record.profileRevision ?? 0); hay una nueva" : "Aplicada"),
                    ])
                    HStack {
                        Button(entry.profileIsStale ? "Aplicar la revisión nueva" : "Volver a aplicar") { library.setProfile(entry, profile) }
                        Button("Quitar perfil") { library.setProfile(entry, nil) }
                    }
                    .disabled(isOpen)
                } else if let suggested = library.suggestedProfile(for: entry) {
                    Text("Hay un perfil para este juego: \(suggested.name).").foregroundStyle(.secondary)
                    Button("Aplicar perfil de \(suggested.name)") { library.setProfile(entry, suggested) }.disabled(isOpen)
                } else {
                    Text("Ningún perfil de Riftway coincide con este juego.").foregroundStyle(.secondary)
                }
                if isOpen { Text("Cierra el juego para cambiar su perfil.").font(.caption).foregroundStyle(.secondary) }
            }
            }
            if !entry.compatibility.anticheat.isEmpty {
                Block(title: entry.game.store == nil ? "Anti-cheat encontrado en la botella" : "Anti-cheat encontrado en su carpeta") {
                    ForEach(Array(entry.compatibility.anticheat.enumerated()), id: \.offset) { _, finding in
                        Label(ReportText.anticheat(finding), systemImage: "shield.lefthalf.filled").font(.callout)
                    }
                }
            }
        }
    }
}

private struct AdvancedTab: View {
    let entry: LibraryEntry
    @Bindable var library: LibraryModel
    let playSettings: () -> Void
    let trash: () -> Void

    var body: some View {
        if let store = entry.game.store { storeBody(store) } else { bottleBody }
    }

    /// A launcher's game: its bottle's settings are the launcher's.
    private func storeBody(_ store: StoreLink) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            coverBlock
            Block(title: "Archivos") {
                HStack {
                    Button("Mostrar la carpeta del juego") { library.showStoreFolder(entry) }
                    Button("Reconstruir acceso directo") { library.rebuildBridge(entry) }
                }
                Text("El modo diagnóstico, Direct3D y lo demás de Wine se ajustan en la página de Steam: es su botella.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Block(title: "Quitar") {
                HStack {
                    Button("Desinstalar en Steam…") { library.openStoreLink(store.uninstallLink, for: entry) }
                    Button("Quitar de la biblioteca…", role: .destructive, action: trash)
                }
                Text("Steam pide confirmar antes de desinstalar. Al desinstalarlo ahí, también sale de Riftway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A DPI as Windows names its scaling: 96 is 100 %.
    private static func scale(_ dpi: Int) -> String { "\(dpi * 100 / 96) %" }

    private var coverBlock: some View {
        Block(title: "Portada") {
            HStack {
                Button("Elegir imagen…") { library.chooseCover(entry) }
                Button("Quitar portada") { library.removeCover(entry) }
                    .disabled(library.covers[entry.id] == nil)
            }
            Text("También puedes arrastrar una imagen sobre la portada. Se ve mejor vertical (2:3); los colores de la página salen de ella.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bottleBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            Block(title: "Ejecución") {
                Toggle("Modo diagnóstico: cada sesión deja un log de Wine", isOn: Binding(
                    get: { entry.record.options.diagnostics }, set: { library.setDiagnostics(entry, $0) }))
                Picker("Direct3D 11", selection: Binding(
                    get: { entry.record.options.direct3D11 }, set: { library.setDirect3D11(entry, $0) })) {
                    Text("Lo que diga el perfil").tag(Direct3D11?.none)
                    Text("DXMT").tag(Direct3D11?.some(.dxmt))
                    Text("wined3d (experimental)").tag(Direct3D11?.some(.wined3d))
                }
                .fixedSize()
                Text("wined3d no pasa de shader model 3 en macOS: sirve para juegos sencillos o para comparar.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Tamaño de la interfaz", selection: Binding(
                    get: { entry.record.options.appDPI?.dpi }, set: { library.setInterfaceDPI(entry, $0) })) {
                    Text("Lo que diga el perfil (\(Self.scale(entry.profileInterfaceDPI)))").tag(Int?.none)
                    ForEach(LibraryEntry.interfaceDPIs, id: \.self) { dpi in
                        Text(Self.scale(dpi)).tag(Int?.some(dpi))
                    }
                }
                .fixedSize()
                .disabled(entry.interfacePrograms.isEmpty)
                Text(entry.interfacePrograms.isEmpty ? "Elige primero qué abre Jugar."
                     : "Como la escala de Windows: si las letras se ven chicas en una pantalla Retina, súbelo. Aplica a \(entry.interfacePrograms.joined(separator: ", ")) al volver a abrirlo.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Configurar Jugar…", action: playSettings)
            }
            .disabled(library.running.contains(entry.id))
            coverBlock
            Block(title: "Archivos") {
                HStack {
                    Button("Abrir disco C:") { library.showDriveC(entry) }
                    Button("Abrir logs") { library.showLogs(entry) }
                    Button("Mostrar la botella") { NSWorkspace.shared.activateFileViewerSelecting([entry.root]) }
                    Button("Reconstruir app puente") { library.rebuildBridge(entry) }
                }
            }
            Block(title: "Quitar") {
                HStack {
                    if entry.game.uninstall?.uninstallString != nil {
                        Button("Desinstalar juego…") { library.uninstall(entry) }
                    }
                    Button("Mover a la Papelera…", role: .destructive, action: trash)
                }
                Text("La Papelera se lleva la botella completa: el juego, sus partidas locales y su app puente.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Launchers' games (PRD-04 R1.6)

/// A Steam game's summary: where it is and that Steam starts it.
private struct StoreSummaryTab: View {
    let entry: LibraryEntry
    let store: StoreLink

    var body: some View {
        FactGrid(facts: [
            Fact(label: "Jugar abre", value: "Steam", detail: "Con su protección, la nube, el overlay y los logros"),
            Fact(label: "Instalado en", value: URL(fileURLWithPath: store.installDir.replacingOccurrences(of: "\\", with: "/")).lastPathComponent,
                 detail: store.installDir),
            Fact(label: "Control", value: "Steam Input", detail: "La configuración de Steam para este juego"),
            Fact(label: "ID de Steam", value: store.appID),
            Fact(label: "Runtime", value: entry.record.runtimeVersion, detail: "El de la botella de Steam"),
        ])
    }
}

/// Steam Input drives a Steam game's controller; Riftway stays out of it.
private struct StoreControlsTab: View {
    let entry: LibraryEntry
    let store: StoreLink
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Steam Input se encarga del control", systemImage: "gamecontroller.fill").font(.headline)
            Text("En los juegos de Steam, el control llega a Steam y Steam lo traduce para el juego, con la configuración que tenga en Steam (la oficial, la de la comunidad o la tuya). Riftway no le agrega nada.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Configurar el control en Steam") { library.openStoreLink("steam://controllerconfig/\(store.appID)", for: entry) }
                .controlSize(.large)
        }
    }
}

/// On a launcher's page: the games it installed, and the way to add the
/// ones not in the library (also those declined before).
private struct StoreGamesBlock: View {
    let launcher: LibraryEntry
    @Bindable var library: LibraryModel
    @State private var installed: [InstalledStoreGame] = []

    var body: some View {
        // A VStack, not a Group: the task has to run while the list is empty.
        VStack(alignment: .leading, spacing: 0) {
            if !installed.isEmpty {
                Block(title: "Juegos de \(launcher.game.name)") {
                    VStack(spacing: 0) {
                        ForEach(installed) { game in
                            HStack(spacing: 12) {
                                StoreCoverThumbnail(url: game.cover).frame(width: 32)
                                Text(game.name)
                                Spacer()
                                if library.entries.contains(where: { $0.id == game.id }) {
                                    Text("En la biblioteca").foregroundStyle(.secondary)
                                } else {
                                    Button("Agregar a la biblioteca") {
                                        do { try library.addStoreGame(game, launcher: launcher) } catch { library.problem = "\(error)" }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            if game.id != installed.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                }
            }
        }
        .task(id: launcher.id) {
            let library = library.library, launcher = launcher
            installed = await Task.detached { library.installedStoreGames(in: launcher) }.value
        }
    }
}

/// A launcher's cover from its cache, small.
struct StoreCoverThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(2 / 3, contentMode: .fill)
            } else {
                Rectangle().fill(Theme.card)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
