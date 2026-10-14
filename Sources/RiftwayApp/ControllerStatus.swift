import AppKit
import Foundation
import GameController
import Observation
import RiftwayCore

/// The controllers connected to the Mac and their batteries, for the sidebar.
/// Unlike `ControllerMonitor` (the editor's), it never reads buttons: it hears
/// connections and battery changes, and rereads the batteries every few
/// seconds and whenever Riftway comes to the front.
@MainActor @Observable
final class ControllerStatus {
    struct Pad: Equatable, Identifiable {
        let id: ObjectIdentifier
        let name: String
        /// 0…1, or nil while the controller has not said: a DualShock 4 that
        /// just connected over Bluetooth reads 0 until its first full report.
        let battery: Float?
        let charging: Bool
        let family: ControllerFamily

        /// "Batería 85 %", "Cargando 40 %", "Cargando", or nil.
        var batteryText: String? {
            switch (battery, charging) {
            case (let level?, true): "Cargando \(Int((level * 100).rounded())) %"
            case (nil, true): "Cargando"
            case (let level?, false): "Batería \(Int((level * 100).rounded())) %"
            case (nil, false): nil
            }
        }
    }

    private(set) var pads: [Pad] = []
    private var observers: [NSObjectProtocol] = []
    private var batteryObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        watchBatteries(of: controllers)
        let now = controllers.map { controller in
            Pad(id: ObjectIdentifier(controller),
                name: controller.productCategory.isEmpty ? (controller.vendorName ?? "Control") : controller.productCategory,
                battery: Self.level(controller.battery),
                charging: controller.battery?.batteryState == .charging,
                family: ControllerFamily(productCategory: controller.productCategory))
        }
        if now != pads { pads = now }
    }

    /// A level of 0 is a controller that has not reported yet (one that is
    /// truly empty has switched off), and an unknown state has no level.
    private static func level(_ battery: GCDeviceBattery?) -> Float? {
        guard let battery, battery.batteryState != .unknown, battery.batteryLevel > 0 else { return nil }
        return min(battery.batteryLevel, 1)
    }

    /// The battery reports when it changes, so the first real reading shows
    /// as soon as it arrives instead of at the next reread.
    private func watchBatteries(of controllers: [GCController]) {
        let ids = Set(controllers.map(ObjectIdentifier.init))
        batteryObservers = batteryObservers.filter { ids.contains($0.key) }
        for controller in controllers where batteryObservers[ObjectIdentifier(controller)] == nil {
            guard let battery = controller.battery else { continue }
            let changed: @Sendable (GCDeviceBattery, Any) -> Void = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            batteryObservers[ObjectIdentifier(controller)] = [
                battery.observe(\.batteryLevel, changeHandler: { changed($0, $1) }),
                battery.observe(\.batteryState, changeHandler: { changed($0, $1) }),
            ]
        }
    }
}
