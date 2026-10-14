import AppKit
import Observation
import RiftwayCore
import SwiftUI

/// The controller in the main window (PRD-04): the d-pad or the left stick
/// moves through the covers, ✕ opens a game's page, △ plays or stops it,
/// L1/R1 change the section (or the page's tab), ○ goes back and Options
/// switches to the couch mode. It reads the controller only while the main
/// window is in front, without a sheet, and the couch mode is closed; the
/// views act on its `event`.
@MainActor @Observable
final class PadNavigation {
    struct Event: Equatable {
        let serial: Int
        let command: CouchCommand
    }

    /// The last command for the views (Options never: it opens the couch mode).
    private(set) var event: Event?
    /// The controller was the last thing used: covers show the focus and the
    /// window the controller's hints. A click, a key or a scroll hides them.
    private(set) var isActive = false
    /// The game the focus is on, in the grid shown.
    var focused: String?
    /// The covers per row in the grid shown, for up and down.
    var columns = 1

    @ObservationIgnored weak var window: NSWindow?
    /// While true (the couch mode is open) commands are read and dropped.
    @ObservationIgnored var isPaused: () -> Bool = { false }
    @ObservationIgnored var openCouchMode: () -> Void = {}
    @ObservationIgnored private var reader = CouchInputReader()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var serial = 0

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startPolling() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if self?.isActive == true { self?.isActive = false }
            return event
        }
        if NSApp.isActive { startPolling() }
    }

    /// For the render aid: the window as the controller leaves it.
    func showForRender(focused: String?) {
        self.focused = focused
        isActive = true
    }

    /// macOS gives the controller to the app in front, so it polls only then.
    private func startPolling() {
        guard timer == nil else { return }
        reader = CouchInputReader()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let state = CouchPadState.current() else { return }
        // Read even when paused, so a button held across the couch mode
        // (○ or Options that closed it) is not a new press here.
        let commands = reader.read(state, at: ProcessInfo.processInfo.systemUptime)
        guard !commands.isEmpty, !isPaused(), let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        for command in commands {
            if command == .menu {
                openCouchMode()
                continue
            }
            isActive = true
            serial += 1
            event = Event(serial: serial, command: command)
        }
    }
}

/// The controller's buttons and what they do here, at the window's foot
/// while the controller is in use.
struct PadHints: View {
    let family: ControllerFamily
    let hints: [(ControllerButton, String)]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 6) {
                    Text(label(hint.0)).font(.callout.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.12)))
                    Text(hint.1).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func label(_ button: ControllerButton) -> String {
        button == .l1 ? "\(family.label(.l1)) \(family.label(.r1))" : family.label(button)
    }
}
