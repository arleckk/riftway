import AppKit
import Observation
import RiftwayCore

/// A controller in the menu bar while a game is open (PRD-04): each open game
/// with its session time and Stop, the controller's battery, and the way
/// back to Riftway. It leaves the menu bar when the last game closes.
@MainActor
final class PlayingMenu: NSObject, NSMenuDelegate {
    private let library: LibraryModel
    private let controllers: ControllerStatus
    private let showMain: () -> Void
    private var item: NSStatusItem?

    init(library: LibraryModel, controllers: ControllerStatus, showMain: @escaping () -> Void) {
        self.library = library
        self.controllers = controllers
        self.showMain = showMain
    }

    func start() {
        update()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = library.running
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let open = library.entries.filter { library.running.contains($0.id) }
        guard !open.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Riftway: jugando")
            image?.isTemplate = true
            item.button?.image = image
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        }
        item?.button?.toolTip = "Jugando: " + open.map(\.game.name).joined(separator: ", ")
    }

    /// Built when it opens, so session times are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in library.entries where library.running.contains(entry.id) {
            menu.addItem(.sectionHeader(title: entry.game.name))
            let since = library.runningSince[entry.id] ?? Date()
            let time = NSMenuItem(title: "Jugando · \(SessionClock.elapsed(since: since, now: Date()))", action: nil, keyEquivalent: "")
            time.isEnabled = false
            menu.addItem(time)
            let stop = NSMenuItem(title: "Detener", action: #selector(stop(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = entry.id
            stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        if let pad = controllers.pads.first {
            let battery = pad.batteryText.map { " · " + $0.lowercased() } ?? ""
            let controller = NSMenuItem(title: pad.name + battery, action: nil, keyEquivalent: "")
            controller.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
            controller.isEnabled = false
            menu.addItem(controller)
        }
        let open = NSMenuItem(title: "Abrir Riftway", action: #selector(openRiftway(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    @objc private func stop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let entry = library.entries.first(where: { $0.id == id }) else { return }
        library.stop(entry)
    }

    @objc private func openRiftway(_ sender: NSMenuItem) {
        showMain()
    }
}
