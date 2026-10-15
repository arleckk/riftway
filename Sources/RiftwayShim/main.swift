import AppKit
import RiftwayCore

/// The per-game shim. macOS opens it for the game's URL schemes (a web login
/// redirecting to `dsropen:…`) and for a double-click. It forwards the URL to
/// the bottle through the command the Windows program registered, then quits.
@MainActor
final class ShimDelegate: NSObject, NSApplicationDelegate {
    private let log = Log()
    private var config: ShimConfig?
    private var receivedURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The raw Apple Event string, not application(_:open:): opaque URLs such as
        // `scheme:a;b@c;d` reach it untouched, without Foundation's URL parsing.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        config = Self.loadConfig()
        if config == nil { log.write("shim: missing or unreadable \(ShimBundle.configName)") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A URL launch delivers its event right after launch; give it a moment
        // before treating this as a double-click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard !receivedURL else { return }
            guard let config else { return quitSoon() }
            if let page = config.webPageURL {
                log.write("shim \(config.bundleIdentifier): opening the game's web page")
                NSWorkspace.shared.open(page)
                return quitSoon()
            }
            _ = launch(secret: nil) { () throws(BridgeError) in try config.bridge.planForProgram() }
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        receivedURL = true
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let config else {
            log.write("shim: URL event without a URL or configuration")
            return quitSoon()
        }
        log.write("shim \(config.bundleIdentifier): received \(IncomingURL.redacted(url))")
        let launched = launch(secret: url) { () throws(BridgeError) in try config.bridge.plan(forURL: url) }
        // The game's Play button reuses the newest link (it carries a session
        // that expires); only a link the bottle accepted is kept.
        if launched, !config.dryRun, let account = config.rememberLinkAccount, let directory = config.secretsDirectory {
            do {
                try SecretStore(directory: URL(fileURLWithPath: directory, isDirectory: true)).save(url, account: account)
                log.write("shim: remembered \(IncomingURL.redacted(url)) for Play")
            } catch {
                log.write("shim: could not remember the link: \(error)")
            }
        }
    }

    @discardableResult
    private func launch(secret: String?, _ makePlan: () throws(BridgeError) -> LaunchPlan) -> Bool {
        guard let config else { quitSoon(); return false }
        // A bottle on a disconnected disk: say so, and never let Wine make a
        // new prefix (or a folder) in its place.
        let bottleRoot = URL(fileURLWithPath: config.bottle.prefix, isDirectory: true).deletingLastPathComponent()
        guard BottleLocations.isAvailable(bottleRoot), FileManager.default.fileExists(atPath: config.bottle.prefix) else {
            let drive = BottleLocations.driveName(bottleRoot)
            log.write("shim: the bottle is not there (\(drive) disconnected?)")
            alert("Conecta \(drive) y vuelve a abrir \(config.displayName): su botella está ahí.",
                  title: "\(config.displayName) está en \(drive)")
            quitSoon()
            return false
        }
        do {
            var plan = try makePlan()
            if config.wineLog {
                // Keep Wine's errors (the bottle's default silences them) and
                // send DXMT's log to stderr, which lands in the session log.
                if plan.environment["WINEDEBUG"] == "-all" { plan.environment["WINEDEBUG"] = "fixme-all" }
                plan.environment["DXMT_LOG_PATH"] = nil
            }
            if config.dryRun {
                log.write("shim: dry run, would start: \(plan.logDescription(hiding: secret))")
            } else {
                let pid = try Launcher.start(plan, outputLog: config.sessionLog())
                log.write("shim: started pid \(pid) in bottle \(config.bottle.name): \(plan.logDescription(hiding: secret))")
                if InputHelper.startIfNeeded(app: config.inputHelper.map { URL(fileURLWithPath: $0) }, bottleRoot: bottleRoot) {
                    log.write("shim: started Riftway Input for the game's controller layout")
                }
            }
        } catch {
            log.write("shim: \(error)")
            alert(error.description)
            quitSoon()
            return false
        }
        quitSoon()
        return true
    }

    private func alert(_ message: String, title: String? = nil) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title ?? "\(config?.displayName ?? "Riftway") could not open the link"
        alert.informativeText = message
        alert.runModal()
    }

    /// More URL events can still arrive while Wine starts; quit once it is quiet.
    private func quitSoon() {
        NSObject.cancelPreviousPerformRequests(withTarget: NSApp as Any)
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 1.5)
    }

    private static func loadConfig() -> ShimConfig? {
        guard let url = Bundle.main.url(forResource: "shim", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShimConfig.self, from: data)
    }
}

let app = NSApplication.shared
let delegate = ShimDelegate()
app.delegate = delegate
app.run()
