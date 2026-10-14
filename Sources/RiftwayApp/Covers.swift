import AppKit
import RiftwayCore
import SwiftUI
import UniformTypeIdentifiers

/// Games as covers (2:3), with the per-game menu and its sheets (PRD-04 R1.1, R1.3).
struct CoverGrid: View {
    let entries: [LibraryEntry]
    @Bindable var library: LibraryModel
    /// The install tile at the end, when the grid shows the whole library.
    let add: (() -> Void)?
    /// The controller's focus, and where the grid tells it its columns.
    let pad: PadNavigation?
    /// Opens the game's page.
    let open: (LibraryEntry) -> Void
    @State private var trashCandidate: LibraryEntry?
    @State private var playSettings: LibraryEntry?
    @State private var controllerSettings: LibraryEntry?

    private static let minimum: CGFloat = 150, spacing: CGFloat = 22

    var body: some View {
        ScrollViewReader { scroller in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimum, maximum: 190), spacing: Self.spacing, alignment: .top)],
                      alignment: .leading, spacing: 26) {
                ForEach(entries) { entry in
                    CoverTile(entry: entry, icon: library.icons[entry.id], art: library.covers[entry.id],
                              palette: library.palettes[entry.id] ?? .riftway,
                              runningSince: library.running.contains(entry.id) ? (library.runningSince[entry.id] ?? Date()) : nil,
                              focused: pad?.isActive == true && pad?.focused == entry.id,
                              play: { library.play(entry) }, stop: { library.stop(entry) }, open: { open(entry) },
                              setCover: { library.setCover(entry, image: $0) })
                        .contextMenu { menu(entry) }
                        .id(entry.id)
                }
                if let add { AddCover(action: add) }
            }
            // An adaptive grid fits as many minimum-width columns as the width allows.
            .onGeometryChange(for: Int.self) { max(1, Int((($0.size.width + Self.spacing) / (Self.minimum + Self.spacing)).rounded(.down))) } action: {
                pad?.columns = $0
            }
            .onChange(of: pad?.focused) {
                guard let id = pad?.focused else { return }
                withAnimation(.snappy(duration: 0.2)) { scroller.scrollTo(id) }
            }
        }
        .sheet(item: $playSettings) { entry in
            PlaySettingsView(entry: entry, library: library)
        }
        .sheet(item: $controllerSettings) { entry in
            ControllerEditorView(entry: entry, library: library)
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
        Button("Ver página del juego") { open(entry) }
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
        Button("Configurar Jugar…") { playSettings = entry }
        Button("Configurar control…") { controllerSettings = entry }
        Button("Cambiar portada…") { library.chooseCover(entry) }
        if library.covers[entry.id] != nil {
            Button("Quitar portada") { library.removeCover(entry) }
        }
        Toggle("Modo diagnóstico", isOn: Binding(get: { entry.record.options.diagnostics },
                                                 set: { library.setDiagnostics(entry, $0) }))
        Button("Abrir logs") { library.showLogs(entry) }
        Button("Abrir disco C: en Finder") { library.showDriveC(entry) }
        Button("Reconstruir app puente") { library.rebuildBridge(entry) }
        profileMenu(entry)
        Divider()
        if entry.game.uninstall?.uninstallString != nil {
            Button("Desinstalar juego…") { library.uninstall(entry) }
        }
        Button("Mover a la Papelera…", role: .destructive) { trashCandidate = entry }
    }

    @ViewBuilder private func profileMenu(_ entry: LibraryEntry) -> some View {
        let isOpen = library.running.contains(entry.id)
        if let profile = entry.profile {
            Menu("Perfil: \(profile.name)") {
                Text(ReportText.status(profile.status) + " · revisión \(profile.revision)")
                Button(entry.profileIsStale ? "Aplicar la revisión nueva" : "Volver a aplicar") { library.setProfile(entry, profile) }
                    .disabled(isOpen)
                Button("Quitar perfil") { library.setProfile(entry, nil) }.disabled(isOpen)
            }
        } else if let suggested = library.suggestedProfile(for: entry) {
            Button("Aplicar perfil de \(suggested.name)") { library.setProfile(entry, suggested) }.disabled(isOpen)
        }
    }
}

/// One game: its cover, name and state. A click opens its page; Play shows
/// on hover, and a double click plays too. An image dropped on it becomes its
/// cover.
private struct CoverTile: View {
    let entry: LibraryEntry
    let icon: NSImage?
    let art: NSImage?
    let palette: CoverPalette
    /// When the game was opened, if it is open.
    let runningSince: Date?
    /// Where the controller's focus is.
    let focused: Bool
    let play: () -> Void
    let stop: () -> Void
    let open: () -> Void
    let setCover: (Data) -> Void
    @State private var hovering = false
    private var raised: Bool { hovering || focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameCover(name: entry.game.name, icon: icon, palette: palette, art: art)
                .coverDrop(setCover)
                .overlay(alignment: .bottomLeading) {
                    if let runningSince { SessionPill(since: runningSince).padding(8) }
                }
                .overlay {
                    if hovering {
                        if runningSince != nil {
                            Button(action: stop) { Label("Detener", systemImage: "stop.fill") }
                                .buttonStyle(.borderedProminent).tint(.black.opacity(0.55))
                        } else if entry.canPlay {
                            Button(action: play) { Label("Jugar", systemImage: "play.fill") }
                                .buttonStyle(PlayButtonStyle())
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(runningSince != nil ? Theme.cyan : .white.opacity(hovering ? 0.25 : 0.08),
                                      lineWidth: runningSince != nil ? 2.5 : 1)
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.pink, lineWidth: 3)
                            .padding(-4)
                    }
                }
                .shadow(color: .black.opacity(raised ? 0.28 : 0.16), radius: raised ? 12 : 6, y: raised ? 6 : 3)
                .scaleEffect(raised ? 1.02 : 1)
                .animation(.snappy(duration: 0.18), value: raised)
                .onTapGesture(count: 2) { if runningSince == nil && entry.canPlay { play() } }
                .onTapGesture { open() }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.game.name).font(.callout.weight(.semibold)).lineLimit(2)
                status
            }
        }
        .onHover { hovering = $0 }
        .help(ReportText.compatibility(entry.compatibility, installed: true).text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: runningSince == nil ? "Jugar" : "Detener") { runningSince == nil ? play() : stop() }
    }

    /// What the player needs to know first: a problem, the session, else the compatibility.
    @ViewBuilder private var status: some View {
        if let runningSince {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Jugando · \(SessionClock.elapsed(since: runningSince, now: context.date))").foregroundStyle(Theme.cyan)
            }
            .font(.caption)
        } else if entry.runtime == nil {
            Text("Falta el runtime \(entry.record.runtimeVersion)").font(.caption).foregroundStyle(Theme.blocked)
        } else if GameLauncher.primaryIsMissing(entry) {
            Text("Falta el programa: revisa Configurar Jugar").font(.caption).foregroundStyle(Theme.blocked)
        } else if entry.game.primary == nil && entry.game.customLaunch == nil {
            Text("Sin programa para abrir").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(statusText).font(.caption).foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        let compatibility = entry.compatibility
        if compatibility.status == .untested && !compatibility.anticheat.isEmpty { return "Sin probar · anti-cheat" }
        return ReportText.status(compatibility.status)
    }

    private var statusColor: Color {
        let compatibility = entry.compatibility
        return compatibility.status == .untested && !compatibility.anticheat.isEmpty ? Theme.playable : Theme.color(compatibility.status)
    }
}

/// How long the game has been open, on its cover.
private struct SessionPill: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Circle().fill(Theme.cyan).frame(width: 6, height: 6)
                Text(SessionClock.elapsed(since: since, now: context.date)).monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.5)))
        }
    }

}

/// A cover made from the game's icon: its colors as a gradient, a streak of
/// the rift's light and the icon large. Without an icon, the name's initials.
struct GameCover: View {
    let name: String
    let icon: NSImage?
    let palette: CoverPalette
    /// The game's own cover, filling the 2:3 frame in place of the drawn one.
    var art: NSImage? = nil

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            if let art {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: width, height: geometry.size.height)
                    .clipped()
            } else {
                drawn(width: width, height: geometry.size.height)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Riftway's cover: the icon's colors, the rift, the icon (or initials).
    private func drawn(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Color(palette.top), Color(palette.bottom)], startPoint: .top, endPoint: .bottom)
            // The rift: a soft diagonal light across the cover.
            LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.5, height: height * 2)
                .rotationEffect(.degrees(24))
                .offset(x: width * 0.22, y: -width * 0.1)
                .blendMode(.plusLighter)
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: width * 0.58)
                        .shadow(color: .black.opacity(0.35), radius: width * 0.05, y: width * 0.02)
                } else {
                    Text(initials).font(.system(size: width * 0.28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .offset(y: -width * 0.08)
        }
        .frame(width: width, height: height)
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// The last tile: install another game.
private struct AddCover: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(hovering ? Theme.violet : Color.secondary.opacity(0.4))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus").font(.system(size: 28, weight: .light))
                            .foregroundStyle(hovering ? Theme.violet : .secondary)
                    }
                Text("Instalar un juego…").font(.callout).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// Takes an image dropped on a cover (a file from Finder, or an image from
    /// a browser) and hands its data to `set`. Other files pass through to the
    /// window, which installs them.
    func coverDrop(_ set: @escaping (Data) -> Void) -> some View {
        modifier(CoverDropTarget(set: set))
    }
}

private struct CoverDropTarget: ViewModifier {
    let set: (Data) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45))
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.pink, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        Label("Usar como portada", systemImage: "photo").font(.callout.weight(.semibold))
                            .foregroundStyle(.white).multilineTextAlignment(.center).padding(8)
                    }
                }
            }
            .onDrop(of: [.image], isTargeted: $targeted) { providers in
                guard let provider = providers.first,
                      let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in set(data) }
                }
                return true
            }
    }
}
