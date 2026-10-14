import AppKit
import RiftwayCore
import SwiftUI

/// AppKit owns the lifecycle so document opens from Finder and the Dock arrive
/// in `application(_:open:)` and never spawn extra SwiftUI windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let library = LibraryModel()
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
        window.contentViewController = NSHostingController(rootView: LibraryView(model: model, library: library))
        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") { window.center() }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        launched = true
        model.start()
        if !early.isEmpty { model.open(early); early = [] }
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
            let controller = NSHostingController(rootView: SettingsView())
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

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Acerca de Riftway", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
    let report = InstallerAnalyzer.analyze(URL(fileURLWithPath: file))
    let view = ReportContent(report: report).frame(width: 560).background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: output))) != nil else { return 1 }
    return 0
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
        view = AnyView(LibraryView(model: AppModel(), library: library).frame(width: 820, height: 560))
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
if let index = arguments.firstIndex(of: "--render-install"), arguments.count > index + 2 {
    exit(MainActor.assumeIsolated { renderLibrary(to: arguments[index + 2], installedBottle: arguments[index + 1]) })
}
if let index = arguments.firstIndex(of: "--render-analysis"), arguments.count > index + 2 {
    exit(MainActor.assumeIsolated { renderAnalysis(arguments[index + 1], to: arguments[index + 2]) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
