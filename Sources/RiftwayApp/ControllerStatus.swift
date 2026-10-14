import Foundation
import GameController
import Observation

/// The controllers connected to the Mac and their batteries, for the sidebar.
/// Unlike `ControllerMonitor` (the editor's), it never reads buttons: it hears
/// connections and reads batteries once a minute.
@MainActor @Observable
final class ControllerStatus {
    struct Pad: Equatable, Identifiable {
        let id: ObjectIdentifier
        let name: String
        let battery: Float?
        let charging: Bool
    }

    private(set) var pads: [Pad] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let now = GCController.controllers().filter { $0.extendedGamepad != nil }.map { controller in
            Pad(id: ObjectIdentifier(controller),
                name: controller.productCategory.isEmpty ? (controller.vendorName ?? "Control") : controller.productCategory,
                battery: controller.battery.map(\.batteryLevel),
                charging: controller.battery?.batteryState == .charging)
        }
        if now != pads { pads = now }
    }
}
