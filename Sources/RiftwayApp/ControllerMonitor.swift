import Foundation
import GameController
import IOKit.hid
import Observation
import RiftwayCore

/// The controllers connected to the Mac and their buttons as they are pressed,
/// for the controller editor (PRD-08).
///
/// GameController sees the controllers macOS supports (PlayStation, Xbox,
/// Nintendo, MFi): those Riftway Input can turn into keys and mouse. Other
/// gamepads appear only through HID: games with controller support still get
/// them through Wine (SDL), but Riftway Input cannot read them.
@MainActor @Observable
final class ControllerMonitor {
    struct Connected: Identifiable, Equatable {
        let id: String
        let name: String
        let family: ControllerFamily
        /// GameController reads it, so keyboard and desktop modes work with it.
        let supported: Bool
        let battery: Float?
    }

    private(set) var controllers: [Connected] = []
    /// Buttons held right now on the first supported controller.
    private(set) var pressed: Set<ControllerButton> = []
    /// The last button pressed, to select it in the editor.
    private(set) var lastPressed: (button: ControllerButton, at: Date)?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var hid: IOHIDManager?

    var family: ControllerFamily? { controllers.first(where: \.supported)?.family ?? controllers.first?.family }

    func start() {
        guard timer == nil else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        GCController.startWirelessControllerDiscovery {}
        startHID()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        GCController.stopWirelessControllerDiscovery()
        if let hid { IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
        hid = nil
    }

    /// Gamepads and joysticks on HID, to list the ones GameController does not support.
    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        // Only listed, never opened: reading them would need Input Monitoring.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        hid = manager
    }

    func refresh() {
        var list: [Connected] = GCController.controllers().compactMap { controller in
            guard controller.extendedGamepad != nil else { return nil }
            let family = ControllerFamily(productCategory: controller.productCategory)
            return Connected(id: "gc-\(ObjectIdentifier(controller).hashValue)", name: controller.vendorName ?? family.displayName,
                             family: family, supported: true, battery: controller.battery?.batteryLevel)
        }
        // HID devices GameController does not already show.
        if let hid, let devices = IOHIDManagerCopyDevices(hid) as? Set<IOHIDDevice> {
            for device in devices {
                func number(_ key: String) -> Int? { IOHIDDeviceGetProperty(device, key as CFString) as? Int }
                let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Control"
                let family = ControllerFamily(vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey))
                let known = list.contains { $0.family == family && family != .generic }
                if !known {
                    list.append(Connected(id: "hid-\(number(kIOHIDLocationIDKey) ?? 0)-\(name)", name: name, family: family,
                                          supported: false, battery: nil))
                }
            }
        }
        if list != controllers { controllers = list }
    }

    private func poll() {
        // HID devices come and go without GameController notifications.
        if Int(Date().timeIntervalSinceReferenceDate * 30) % 60 == 0 { refresh() }
        guard let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad else {
            if !pressed.isEmpty { pressed = [] }
            return
        }
        var down: Set<ControllerButton> = []
        let buttons: [(ControllerButton, GCControllerButtonInput?)] = [
            (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.l1, pad.leftShoulder), (.r1, pad.rightShoulder), (.l2, pad.leftTrigger), (.r2, pad.rightTrigger),
            (.l3, pad.leftThumbstickButton), (.r3, pad.rightThumbstickButton), (.start, pad.buttonMenu), (.select, pad.buttonOptions),
        ]
        for (button, input) in buttons where input?.isPressed == true { down.insert(button) }
        for (stick, directions) in [(pad.leftThumbstick, [ControllerButton.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight]),
                                    (pad.rightThumbstick, [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight])] {
            let values = [stick.yAxis.value, -stick.yAxis.value, -stick.xAxis.value, stick.xAxis.value]
            for (direction, value) in zip(directions, values) where value > 0.6 { down.insert(direction) }
        }
        var touchpad: GCControllerDirectionPad?
        var touchButton: GCControllerButtonInput?
        if let ds4 = pad as? GCDualShockGamepad { touchpad = ds4.touchpadPrimary; touchButton = ds4.touchpadButton }
        if let ds5 = pad as? GCDualSenseGamepad { touchpad = ds5.touchpadPrimary; touchButton = ds5.touchpadButton }
        if touchButton?.isPressed == true { down.insert((touchpad?.xAxis.value ?? 0) < 0 ? .touchpadLeft : .touchpadRight) }

        for button in down.subtracting(pressed) { lastPressed = (button, Date()) }
        if down != pressed { pressed = down }
    }
}
