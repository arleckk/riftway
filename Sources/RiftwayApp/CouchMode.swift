import AppKit
import GameController
import Observation
import RiftwayCore
import SwiftUI

/// The couch mode (PRD-04): Riftway full screen, played from the sofa with
/// the controller alone. The selected game fills the background; its row of
/// covers is below. Settings opens it; the Home (PS) button opens and closes
/// it while Riftway is in front, unless Settings gives that button back to
/// macOS; ○ / B and Esc leave it.
@MainActor @Observable
final class CouchMode {
    enum Section: CaseIterable {
        case library, playing

        var title: String {
            switch self {
            case .library: "Biblioteca"
            case .playing: "Jugando"
            }
        }
    }

    struct Option: Identifiable {
        let title: String
        let symbol: String
        let action: () -> Void
        var id: String { title }
    }

    private(set) var isOpen = false
    private(set) var section: Section = .library
    var selection = 0
    private(set) var optionsOpen = false
    private(set) var optionIndex = 0
    /// Whether Home opens the couch mode (or, off, the Games app as usual).
    var homeButtonOpens = UserDefaults.standard.object(forKey: CouchMode.homeButtonKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(homeButtonOpens, forKey: Self.homeButtonKey)
            claimHomeButtons()
        }
    }
    private static let homeButtonKey = "CouchModeHomeButton"

    let library: LibraryModel
    let controllers: ControllerStatus
    /// Shows a game's page in the main window.
    private let showPage: (LibraryEntry) -> Void
    private var window: NSWindow?
    private var timer: Timer?
    private var reader = CouchInputReader()
    private var observers: [NSObjectProtocol] = []
    private var savedPresentation: NSApplication.PresentationOptions = []

    init(library: LibraryModel, controllers: ControllerStatus, showPage: @escaping (LibraryEntry) -> Void) {
        self.library = library
        self.controllers = controllers
        self.showPage = showPage
    }

    /// Listens for the Home button on every controller.
    func start() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidBecomeCurrent] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimHomeButtons() }
            })
        }
        claimHomeButtons()
    }

    /// While Riftway is in front, Home toggles the couch mode instead of
    /// opening the Games app.
    private func claimHomeButtons() {
        for controller in GCController.controllers() {
            guard let home = controller.extendedGamepad?.buttonHome else { continue }
            guard homeButtonOpens else {
                home.preferredSystemGestureState = .enabled
                home.pressedChangedHandler = nil
                continue
            }
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated {
                    guard NSApp.isActive, let self else { return }
                    self.isOpen ? self.close() : self.open()
                }
            }
        }
    }

    // MARK: Games

    var games: [LibraryEntry] {
        switch section {
        case .library: library.entries
        case .playing: library.entries.filter { library.running.contains($0.id) }
        }
    }

    var selected: LibraryEntry? {
        let games = games
        return games.isEmpty ? nil : games[min(selection, games.count - 1)]
    }

    func isRunning(_ entry: LibraryEntry) -> Bool { library.running.contains(entry.id) }

    func canPlay(_ entry: LibraryEntry) -> Bool {
        !((entry.game.primary == nil && entry.game.customLaunch == nil)
          || (entry.runtime == nil && (entry.game.customLaunch != nil || entry.game.primary?.windowsPath != nil)))
    }

    var options: [Option] {
        guard let entry = selected else { return [Option(title: "Salir del modo sillón", symbol: "xmark") { [weak self] in self?.close() }] }
        var list: [Option] = []
        if isRunning(entry) {
            list.append(Option(title: "Detener", symbol: "stop.fill") { [weak self] in self?.library.stop(entry) })
        } else if canPlay(entry) {
            list.append(Option(title: "Jugar", symbol: "play.fill") { [weak self] in self?.library.play(entry) })
        }
        for program in entry.game.programs where program.id != entry.game.primary?.id {
            list.append(Option(title: "Abrir \(program.name)", symbol: "macwindow") { [weak self] in self?.library.play(entry, program: program) })
        }
        list.append(Option(title: "Ver en Riftway", symbol: "rectangle.on.rectangle") { [weak self] in
            self?.close()
            self?.showPage(entry)
        })
        list.append(Option(title: "Salir del modo sillón", symbol: "xmark") { [weak self] in self?.close() })
        return list
    }

    // MARK: Commands

    func handle(_ command: CouchCommand) {
        if optionsOpen {
            let count = options.count
            switch command {
            case .up: optionIndex = max(0, optionIndex - 1)
            case .down: optionIndex = min(count - 1, optionIndex + 1)
            case .confirm:
                let option = options[min(optionIndex, count - 1)]
                optionsOpen = false
                option.action()
            case .back, .options: optionsOpen = false
            default: break
            }
            return
        }
        let count = games.count
        switch command {
        case .left: selection = max(0, min(selection, count - 1) - 1)
        case .right: selection = min(max(count - 1, 0), selection + 1)
        case .previousSection, .nextSection:
            let all = Section.allCases
            let index = all.firstIndex(of: section)! + (command == .nextSection ? 1 : all.count - 1)
            section = all[index % all.count]
            selection = 0
        case .confirm:
            guard let entry = selected else { return }
            if isRunning(entry) || !canPlay(entry) { openOptions() } else { library.play(entry) }
        case .options: openOptions()
        case .back, .home: close()
        default: break
        }
    }

    /// For the render aid: the options as ✕ or △ would show them.
    func showOptionsForRender() { openOptions() }

    private func openOptions() {
        optionIndex = 0
        optionsOpen = true
    }

    // MARK: Window

    func open() {
        guard !isOpen else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let window = CouchWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CouchView(mode: self))
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        savedPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSCursor.setHiddenUntilMouseMoves(true)
        self.window = window
        optionsOpen = false
        isOpen = true
        reader = CouchInputReader()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func close() {
        guard isOpen else { return }
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        NSApp.presentationOptions = savedPresentation
        optionsOpen = false
        isOpen = false
    }

    /// Reads the current controller 60 times a second while open (only when
    /// Riftway is in front: macOS gives the controller to the active app).
    private func poll() {
        guard NSApp.isActive,
              let pad = GCController.current?.extendedGamepad
                ?? GCController.controllers().lazy.compactMap(\.extendedGamepad).first else { return }
        var state = CouchPadState()
        state.left = pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5
        state.right = pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5
        state.up = pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5
        state.down = pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5
        state.confirm = pad.buttonA.isPressed
        state.back = pad.buttonB.isPressed
        state.options = pad.buttonY.isPressed
        state.previousSection = pad.leftShoulder.isPressed
        state.nextSection = pad.rightShoulder.isPressed
        for command in reader.read(state, at: ProcessInfo.processInfo.systemUptime) { handle(command) }
    }
}

/// A borderless window that still takes the keyboard.
private final class CouchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: View

struct CouchView: View {
    @Bindable var mode: CouchMode
    @FocusState private var focused: Bool

    var body: some View {
        let games = mode.games
        let selected = mode.selected
        let palette = selected.flatMap { mode.library.palettes[$0.id] } ?? .riftway
        ZStack {
            ZStack {
                LinearGradient(colors: [Color(palette.top), Color(palette.bottom)], startPoint: .topTrailing, endPoint: .bottomLeading)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: selected?.id)
            VStack(alignment: .leading, spacing: 0) {
                CouchTopBar(mode: mode)
                Spacer(minLength: 20)
                if let selected {
                    CouchHero(mode: mode, entry: selected)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode.section == .playing ? "Ningún juego abierto" : "Tu biblioteca está vacía")
                            .font(.system(size: 44, weight: .bold))
                        Text(mode.section == .playing ? "Cambia a Biblioteca para elegir uno." : "Instala un juego desde la ventana de Riftway.")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 64)
                }
                CouchRow(mode: mode, games: games)
                CouchHints(mode: mode)
            }
            if mode.optionsOpen { CouchOptions(mode: mode) }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            let command: CouchCommand? = switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            case .downArrow: .down
            case .return: .confirm
            case .escape: .back
            case .space: .options
            case .tab: press.modifiers.contains(.shift) ? .previousSection : .nextSection
            default: nil
            }
            guard let command else { return .ignored }
            mode.handle(command)
            return .handled
        }
    }
}

private struct CouchTopBar: View {
    @Bindable var mode: CouchMode

    var body: some View {
        HStack(spacing: 28) {
            Text("Riftway").font(.title.weight(.heavy))
            HStack(spacing: 22) {
                ForEach(CouchMode.Section.allCases, id: \.self) { section in
                    VStack(spacing: 6) {
                        Text(section.title).font(.title3.weight(section == mode.section ? .semibold : .regular))
                            .foregroundStyle(section == mode.section ? .white : .white.opacity(0.6))
                        Capsule().fill(section == mode.section ? Theme.cyan : .clear).frame(height: 3)
                    }
                    .fixedSize()
                }
            }
            Spacer()
            if let pad = mode.controllers.pads.first {
                Label(pad.battery.map { "\(Int(($0 * 100).rounded())) %" } ?? pad.name, systemImage: "gamecontroller.fill")
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute()).font(.title3.monospacedDigit())
            }
        }
        .padding(.horizontal, 64).padding(.top, 40)
    }
}

private struct CouchHero: View {
    @Bindable var mode: CouchMode
    let entry: LibraryEntry

    var body: some View {
        let running = mode.isRunning(entry)
        VStack(alignment: .leading, spacing: 14) {
            Text(running ? "Jugando" : ReportText.status(entry.compatibility.status))
                .font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(running ? Theme.cyan.opacity(0.3) : .white.opacity(0.18)))
            Text(entry.game.name).font(.system(size: 56, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
            HStack(spacing: 14) {
                Label(running ? "Opciones" : "Jugar", systemImage: running ? "ellipsis" : "play.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .foregroundStyle(Theme.onPink)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pink))
                    .opacity(running || mode.canPlay(entry) ? 1 : 0.4)
                    .onTapGesture { mode.handle(.confirm) }
                Label("Opciones", systemImage: "slider.horizontal.3")
                    .font(.title2)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.5)))
                    .opacity(running ? 0 : 1)
                    .onTapGesture { mode.handle(.options) }
            }
        }
        .padding(.horizontal, 64)
        .animation(.snappy, value: entry.id)
    }
}

private struct CouchRow: View {
    @Bindable var mode: CouchMode
    let games: [LibraryEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 26) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, entry in
                        let isSelected = index == min(mode.selection, games.count - 1)
                        GameCover(name: entry.game.name, icon: mode.library.icons[entry.id],
                                  palette: mode.library.palettes[entry.id] ?? .riftway)
                            .frame(width: isSelected ? 190 : 150)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? Theme.cyan : .clear, lineWidth: 4)
                            }
                            .overlay(alignment: .topTrailing) {
                                if mode.isRunning(entry) {
                                    Circle().fill(Theme.cyan).frame(width: 12, height: 12).padding(10)
                                }
                            }
                            .shadow(color: .black.opacity(isSelected ? 0.5 : 0.25), radius: isSelected ? 18 : 8, y: 6)
                            .id(entry.id)
                            .onTapGesture(count: 2) { mode.selection = index; mode.handle(.confirm) }
                            .onTapGesture { mode.selection = index }
                    }
                }
                .padding(.horizontal, 64).padding(.vertical, 28)
                .animation(.snappy(duration: 0.2), value: mode.selection)
            }
            .onChange(of: mode.selected?.id) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

/// The buttons, named as on the connected controller (✕ or A), or the keys.
private struct CouchHints: View {
    @Bindable var mode: CouchMode

    var body: some View {
        HStack(spacing: 26) {
            Spacer()
            if let family = mode.controllers.pads.first?.family {
                hint(family.label(.a), "Jugar")
                hint(family.label(.y), "Opciones")
                hint(family.label(.b), "Salir")
                hint("\(family.label(.l1)) \(family.label(.r1))", "Sección")
            } else {
                hint("Return", "Jugar")
                hint("Espacio", "Opciones")
                hint("Esc", "Salir")
                hint("Tab", "Sección")
            }
        }
        .padding(.horizontal, 64).padding(.bottom, 36)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.headline)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.18)))
            Text(action).font(.title3).foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct CouchOptions: View {
    @Bindable var mode: CouchMode

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { mode.handle(.back) }
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.selected?.game.name ?? "Riftway").font(.title2.weight(.bold)).padding(.bottom, 8)
                ForEach(Array(mode.options.enumerated()), id: \.element.id) { index, option in
                    Label(option.title, systemImage: option.symbol)
                        .font(.title3)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(width: 380, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(index == mode.optionIndex ? Theme.violet.opacity(0.85) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { mode.handle(.back); option.action() }
                }
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.1).opacity(0.95)))
        }
    }
}
