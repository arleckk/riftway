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
            launch(secret: nil) { () throws(BridgeError) in try config.bridge.planForProgram() }
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        receivedURL = true
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let config else {
            log.write("shim: URL event without a URL or configuration")
            return quitSoon()
        }
        log.write("shim \(config.bundleIdentifier): received \(IncomingURL.redacted(url))")
        launch(secret: url) { () throws(BridgeError) in try config.bridge.plan(forURL: url) }
    }

    private func launch(secret: String?, _ makePlan: () throws(BridgeError) -> LaunchPlan) {
        guard let config else { return quitSoon() }
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
            }
        } catch {
            log.write("shim: \(error)")
            alert(error.description)
        }
        quitSoon()
    }

    private func alert(_ message: String) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(config?.displayName ?? "Riftway") could not open the link"
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
