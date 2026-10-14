import AppKit
import RiftwayCore
import SwiftUI

/// AppKit owns the lifecycle so document opens from Finder and the Dock arrive
/// in `application(_:open:)` and never spawn extra SwiftUI windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let library = LibraryModel()
    let updates = UpdateModel()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    /// Files that arrive before the window exists (a cold launch from Finder).
    private var early: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Riftway"
        window.contentMinSize = NSSize(width: 600, height: 420)
        let host = NSHostingController(rootView: LibraryView(model: model, library: library, updates: updates)
            .frame(minWidth: 600, minHeight: 420))
        // The window keeps its own size; the library's grid has no ideal width
        // and would shrink it to a sliver.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 820, height: 560))
        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") || window.frame.width < 600 || window.frame.height < 420 {
            window.setContentSize(NSSize(width: 820, height: 560))
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        launched = true
        model.start()
        if !early.isEmpty { model.open(early); early = [] }
        library.rebuildBridgesAfterUpdate()
        updates.checkIfDue()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { model.open(urls); showMain() } else { early.append(contentsOf: urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showMain() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openDocument(_ sender: Any?) {
        showMain()
        model.chooseFiles()
    }

    @objc func chooseRuntime(_ sender: Any?) {
        showMain()
        library.chooseRuntime()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(updates: updates, library: library))
            let window = NSWindow(contentViewController: controller)
            window.title = "Ajustes"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        showMain()
        updates.check(manual: true)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: SystemRequirements.credits(runtime: library.runtimes.first?.runtime)])
        NSApp.activate()
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Acerca de Riftway", action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Buscar actualizaciones…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Ajustes…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar Riftway", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Salir de Riftway", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "Archivo")
        file.addItem(withTitle: "Abrir instalador…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Instalar runtime…", action: #selector(chooseRuntime(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Ventana")
        windows.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Riftway", action: #selector(showMain), keyEquivalent: "0")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        return main
    }
}

/// Developer aid: `Riftway --render-analysis <file> <out.png>` draws the analysis
/// sheet for a file to a PNG, without a window or screen-recording permission.
@MainActor
func renderAnalysis(_ file: String, to output: String) -> Int32 {
    let url = URL(fileURLWithPath: file)
    let report = InstallerAnalyzer.analyze(url)
    let profiles = ProfileStore.standard()
    var pending = PendingFile(url: url, report: report)
    pending.profile = profiles.match(ProfileQuery(report: report, hash: profiles.usesHashes))
    return snapshot(AnyView(AnalysisView(file: pending, remaining: 0, canInstall: true, close: {}, install: { _ in })), to: output)
}

/// Developer aid: `Riftway --render-library <out.png>` draws the library of
/// $RIFTWAY_HOME, and `--render-install <bottle> <out.png>` the result screen
/// for an installed bottle (its discovery against its baseline).
@MainActor
func renderLibrary(to output: String, installedBottle: String? = nil) -> Int32 {
    let library = LibraryModel()
    library.reload()
    let view: AnyView
    if let installedBottle {
        let root = URL(fileURLWithPath: installedBottle, isDirectory: true)
        guard let runtime = library.runtimes.first,
              let baseline = try? PrefixSnapshot.read(from: root.appendingPathComponent(Library.baselineFile)) else { return 1 }
        let report = InstallerAnalyzer.analyze(URL(fileURLWithPath: "/dev/null"))
        let job = InstallJob(installation: Installation(report: report, name: "Digimon SuperRumble", runtime: runtime))
        job.result = InstallDiscovery.discover(prefix: root.appendingPathComponent("prefix"), baseline: baseline, product: "Digimon SuperRumble")
        job.primaryID = job.result.primary?.id
        job.schemes = Set(job.result.protocols.map(\.scheme))
        job.phase = .result
        view = AnyView(InstallView(job: job, library: library))
    } else {
        view = AnyView(LibraryView(model: AppModel(), library: library, updates: UpdateModel()).frame(width: 820, height: 560))
    }
    return snapshot(view, to: output)
}

/// Draws a view with its AppKit controls (ImageRenderer leaves them out) in an
/// offscreen window, without screen-recording permission.
@MainActor
func snapshot(_ view: AnyView, to output: String) -> Int32 {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 100), height: max(size.height, 100)))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: output))) != nil else { return 1 }
    return 0
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render-library"), arguments.count > index + 1 {
    exit(MainActor.assumeIsolated { renderLibrary(to: arguments[index + 1]) })
}
if let index = arguments.firstIndex(of: "--render-play-settings"), arguments.count > index + 2 {
    exit(MainActor.assumeIsolated {
        let library = LibraryModel()
        library.reload()
        guard let entry = library.entries.first(where: { $0.id == arguments[index + 1] }) else { return 1 }
        return snapshot(AnyView(PlaySettingsView(entry: entry, library: library)), to: arguments[index + 2])
    })
}
if let index = arguments.firstIndex(of: "--render-install"), arguments.count > index + 2 {
    exit(MainActor.assumeIsolated { renderLibrary(to: arguments[index + 2], installedBottle: arguments[index + 1]) })
}
if let index = arguments.firstIndex(of: "--render-settings"), arguments.count > index + 1 {
    exit(MainActor.assumeIsolated { snapshot(AnyView(SettingsView(updates: UpdateModel(), library: LibraryModel())), to: arguments[index + 1]) })
}
if let index = arguments.firstIndex(of: "--render-updates"), arguments.count > index + 1 {
    // Checks $RIFTWAY_FEED_URL and draws the update sheet.
    exit(MainActor.assumeIsolated {
        let updates = UpdateModel()
        updates.check(manual: true)
        let deadline = Date().addingTimeInterval(30)
        while updates.phase == .checking, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return snapshot(AnyView(UpdateView(updates: updates, library: LibraryModel())), to: arguments[index + 1])
    })
}
if let index = arguments.firstIndex(of: "--render-analysis"), arguments.count > index + 2 {
    exit(MainActor.assumeIsolated { renderAnalysis(arguments[index + 1], to: arguments[index + 2]) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
