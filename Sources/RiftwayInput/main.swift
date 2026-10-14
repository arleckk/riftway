import AppKit
import ApplicationServices
import Darwin
import GameController
import RiftwayCore

/// Riftway Input (PRD-08): for one bottle's session, turns the controller into
/// keys and mouse events for the program in front, with the mode the game's
/// `controller.json` gives that program. Started by the bridge or the app with
/// `--bottle <root>`; quits when the bottle's Wine session ends.
///
/// One physical press is one key or mouse button, held as long as the button
/// is: no macros, turbo or timed sequences. Events go to macOS like any
/// keyboard or mouse (they need the Accessibility permission), never injected
/// inside the bottle.
@MainActor
final class InputDelegate: NSObject, NSApplicationDelegate {
    let log = Log()
    let root: URL
    let prefix: URL
    var layout: ControllerLayout
    var layoutStamp: Date?

    /// The program in front, when it is one of this bottle's.
    var program: String?
    var actionSet: ActionSet?
    var pidCache: [pid_t: String?] = [:]

    var pressed: Set<ControllerButton> = []
    /// What each held button produced when pressed, released with it.
    var emitted: [ControllerButton: ControllerOutput] = [:]
    var layers: [String] = []
    var keyFlags: CGEventFlags = []
    var mouseDown: Set<ControllerOutput.MouseButton> = []
    var lastTouch: CGPoint?
    var touchpadHalf: ControllerButton?

    var trusted = false
    var lastTick = Date()
    var started = Date()
    var quietChecks = 0

    init(root: URL) {
        self.root = root
        prefix = root.appendingPathComponent("prefix", isDirectory: true)
        layout = ControllerLayout.read(bottle: root) ?? ControllerLayout()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GCController.shouldMonitorBackgroundEvents = true
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log.write("input: \(root.lastPathComponent): started" + (trusted ? "" : "; waiting for the Accessibility permission"))
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        frontmostChanged()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.housekeeping() } }
    }

    // MARK: The program in front

    @objc func frontmostChanged() {
        let name = NSWorkspace.shared.frontmostApplication.flatMap { bottleProgram(pid: $0.processIdentifier) }
        guard name != program else { return }
        releaseAll()
        program = name
        actionSet = name.flatMap { layout.controls(for: $0).effectiveActionSet }
        if let name { log.write("input: \(name) → \(layout.controls(for: name).mode.rawValue)") }
    }

    /// The Windows program a process runs, if it is one of this bottle's: Wine
    /// sets its `argv[0]` to the program's path inside the prefix. Only
    /// `argv[0]` is read; the arguments (links with tokens) never are.
    func bottleProgram(pid: pid_t) -> String? {
        if let cached = pidCache[pid] { return cached }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        var name: String?
        if sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size {
                var i = MemoryLayout<Int32>.size
                while i < size, buffer[i] != 0 { i += 1 }  // the executable's path
                while i < size, buffer[i] == 0 { i += 1 }  // padding
                var end = i
                while end < size, buffer[end] != 0 { end += 1 }
                let argv0 = String(decoding: buffer[i..<end], as: UTF8.self)
                let driveC = [prefix.path, prefix.resolvingSymlinksInPath().path].map { $0 + "/drive_c/" }
                if driveC.contains(where: argv0.hasPrefix) { name = (argv0 as NSString).lastPathComponent }
            }
        }
        pidCache[pid] = name
        return name
    }

    // MARK: Reading the controller

    func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.05)
        lastTick = now
        guard trusted, let set = actionSet, let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad
        else { return }

        var down: Set<ControllerButton> = []
        let buttons: [(ControllerButton, GCControllerButtonInput?)] = [
            (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.l1, pad.leftShoulder), (.r1, pad.rightShoulder), (.l2, pad.leftTrigger), (.r2, pad.rightTrigger),
            (.l3, pad.leftThumbstickButton), (.r3, pad.rightThumbstickButton), (.start, pad.buttonMenu), (.select, pad.buttonOptions),
        ]
        for (button, input) in buttons where input?.isPressed == true { down.insert(button) }
        stickAsDpad(pad.leftThumbstick, [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight], into: &down)
        stickAsDpad(pad.rightThumbstick, [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight], into: &down)

        // PlayStation touchpad: a click on either half, and the finger as a pointer.
        var touchpad: GCControllerDirectionPad?
        var touchButton: GCControllerButtonInput?
        if let ds4 = pad as? GCDualShockGamepad { touchpad = ds4.touchpadPrimary; touchButton = ds4.touchpadButton }
        if let ds5 = pad as? GCDualSenseGamepad { touchpad = ds5.touchpadPrimary; touchButton = ds5.touchpadButton }
        if touchButton?.isPressed == true {
            if touchpadHalf == nil { touchpadHalf = (touchpad?.xAxis.value ?? 0) < 0 ? .touchpadLeft : .touchpadRight }
            if let half = touchpadHalf { down.insert(half) }
        } else {
            touchpadHalf = nil
        }

        for button in pressed.subtracting(down) { release(button) }
        for button in ControllerButton.allCases where down.contains(button) && !pressed.contains(button) {
            press(button, output: set.output(for: button, layers: layers))
        }
        pressed = down

        var dx = 0.0, dy = 0.0
        for source in set.pointer {
            switch source {
            case .leftStick: stickVelocity(pad.leftThumbstick, dt: dt, dx: &dx, dy: &dy)
            case .rightStick: stickVelocity(pad.rightThumbstick, dt: dt, dx: &dx, dy: &dy)
            case .touchpad:
                guard let touchpad else { break }
                let x = CGFloat(touchpad.xAxis.value), y = CGFloat(touchpad.yAxis.value)
                if x == 0, y == 0 { lastTouch = nil; break }
                if let last = lastTouch { dx += Double(x - last.x) * 900; dy -= Double(y - last.y) * 450 }
                lastTouch = CGPoint(x: x, y: y)
            }
        }
        if abs(dx) >= 0.5 || abs(dy) >= 0.5 { movePointer(dx: dx, dy: dy) }
    }

    /// A stick as four buttons, with hysteresis so a held direction does not flicker.
    func stickAsDpad(_ stick: GCControllerDirectionPad, _ directions: [ControllerButton], into down: inout Set<ControllerButton>) {
        let x = stick.xAxis.value, y = stick.yAxis.value
        let values: [Float] = [y, -y, -x, x]
        for (direction, value) in zip(directions, values) where value > (pressed.contains(direction) ? 0.35 : 0.5) {
            down.insert(direction)
        }
    }

    func stickVelocity(_ stick: GCControllerDirectionPad, dt: Double, dx: inout Double, dy: inout Double) {
        let x = Double(stick.xAxis.value), y = Double(stick.yAxis.value)
        let magnitude = (x * x + y * y).squareRoot()
        let deadzone = 0.15
        guard magnitude > deadzone else { return }
        let scaled = (magnitude - deadzone) / (1 - deadzone)
        let speed = 1500 * scaled * scaled  // points per second
        dx += x / magnitude * speed * dt
        dy -= y / magnitude * speed * dt
    }

    // MARK: Sending events

    func press(_ button: ControllerButton, output: ControllerOutput) {
        emitted[button] = output
        switch output {
        case .key(let name): key(name, down: true)
        case .mouse(let which): mouse(which, down: true)
        case .holdLayer(let layer): layers.append(layer)
        case .none: break
        }
    }

    func release(_ button: ControllerButton) {
        guard let output = emitted.removeValue(forKey: button) else { return }
        switch output {
        case .key(let name): key(name, down: false)
        case .mouse(let which): mouse(which, down: false)
        case .holdLayer(let layer): if let i = layers.lastIndex(of: layer) { layers.remove(at: i) }
        case .none: break
        }
    }

    func releaseAll() {
        for button in Array(emitted.keys) { release(button) }
        pressed = []
        layers = []
        lastTouch = nil
    }

    func key(_ name: String, down: Bool) {
        guard let code = KeyCodes.code(for: name) else { return }
        if KeyCodes.isModifier(name) {
            let flag: CGEventFlags = name.contains("SHIFT") ? .maskShift : name.contains("CONTROL") || name.contains("CTRL") ? .maskControl : .maskAlternate
            if down { keyFlags.insert(flag) } else { keyFlags.remove(flag) }
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        event.flags = keyFlags
        event.post(tap: .cghidEventTap)
    }

    func mouse(_ button: ControllerOutput.MouseButton, down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let (type, cgButton): (CGEventType, CGMouseButton) = switch button {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        if down { mouseDown.insert(button) } else { mouseDown.remove(button) }
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)?.post(tap: .cghidEventTap)
    }

    func movePointer(dx: Double, dy: Double) {
        let current = CGEvent(source: nil)?.location ?? .zero
        var target = CGPoint(x: current.x + dx, y: current.y + dy)
        // Keep the pointer on a screen.
        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union(CGRect(x: $1.frame.minX, y: 0, width: $1.frame.width, height: $1.frame.height)) }
        if !bounds.isNull { target.x = min(max(target.x, bounds.minX), bounds.maxX - 1); target.y = min(max(target.y, bounds.minY), bounds.maxY - 1) }
        let type: CGEventType = mouseDown.contains(.left) ? .leftMouseDragged : mouseDown.contains(.right) ? .rightMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left) else { return }
        // Games that capture the mouse read the deltas, not the position.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    // MARK: Session

    func housekeeping() {
        if !trusted, AXIsProcessTrusted() {
            trusted = true
            log.write("input: Accessibility permission granted")
        }
        // A changed controller.json applies without restarting.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(ControllerLayout.fileName).path))?[.modificationDate] as? Date
        if stamp != layoutStamp {
            layoutStamp = stamp
            layout = ControllerLayout.read(bottle: root) ?? ControllerLayout()
            program = nil
            pidCache = [:]
            frontmostChanged()
        }
        // The session ends with the bottle's Wine server; give a launch time to start it.
        if WineServer.isRunning(prefix: prefix) {
            quietChecks = 0
        } else if Date().timeIntervalSince(started) > 45 {
            quietChecks += 1
            if quietChecks >= 3 {
                releaseAll()
                log.write("input: \(root.lastPathComponent): session over")
                exit(0)
            }
        }
    }
}

let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: "--bottle"), index + 1 < arguments.count else {
    FileHandle.standardError.write(Data("usage: Riftway Input --bottle <bottle folder>\n".utf8))
    exit(64)
}
let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
// One helper per bottle.
let lock = open(root.appendingPathComponent("input.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = InputDelegate(root: root)
app.delegate = delegate
app.run()
