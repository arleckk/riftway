import Foundation

/// Turns the buttons held on a controller into key and mouse presses for an
/// action set, with its hold layers (PRD-08). Riftway Input feeds it the held
/// buttons on every poll.
///
/// - Buttons that hold a layer are handled before the rest pressed in the same
///   poll, so pressing L1 and the d-pad together gives the layer's key.
/// - A held button a layer silenced takes its layer when that layer goes away:
///   pressing R1 before letting go of L1 still switches to R1's layer.
public struct ButtonMapper: Sendable {
    /// A key or mouse button going down or up.
    public struct Event: Equatable, Sendable {
        public let output: ControllerOutput
        public let down: Bool
    }

    public let set: ActionSet
    public private(set) var pressed: Set<ControllerButton> = []
    /// Held layers, the newest last.
    public private(set) var layers: [String] = []
    /// What each held button produced when pressed; it is released with it.
    private var emitted: [ControllerButton: ControllerOutput] = [:]

    public init(set: ActionSet) { self.set = set }

    public mutating func update(_ down: Set<ControllerButton>) -> [Event] {
        var events: [Event] = []
        for button in ControllerButton.allCases where pressed.contains(button) && !down.contains(button) {
            release(button, into: &events)
        }
        var new = ControllerButton.allCases.filter { down.contains($0) && !pressed.contains($0) }
        pressed = down
        // Layers first, again after each one (a layer can map another button to a layer).
        while let i = new.firstIndex(where: { set.output(for: $0, layers: layers).isLayer }) {
            press(new.remove(at: i), into: &events)
        }
        for button in new { press(button, into: &events) }
        // Silenced buttons still held that now hold a layer.
        while let button = ControllerButton.allCases.first(where: {
            emitted[$0] == ControllerOutput.none && set.output(for: $0, layers: layers).isLayer
        }) {
            press(button, into: &events)
        }
        return events
    }

    /// Lets go of everything (another program came to the front).
    public mutating func releaseAll() -> [Event] {
        var events: [Event] = []
        for button in ControllerButton.allCases where emitted[button] != nil { release(button, into: &events) }
        pressed = []
        layers = []
        return events
    }

    private mutating func press(_ button: ControllerButton, into events: inout [Event]) {
        let output = set.output(for: button, layers: layers)
        emitted[button] = output
        switch output {
        case .key, .mouse: events.append(Event(output: output, down: true))
        case .holdLayer(let layer): layers.append(layer)
        case .none: break
        }
    }

    private mutating func release(_ button: ControllerButton, into events: inout [Event]) {
        guard let output = emitted.removeValue(forKey: button) else { return }
        switch output {
        case .key, .mouse: events.append(Event(output: output, down: false))
        case .holdLayer(let layer): if let i = layers.lastIndex(of: layer) { layers.remove(at: i) }
        case .none: break
        }
    }
}

extension ControllerOutput {
    var isLayer: Bool { if case .holdLayer = self { true } else { false } }
}
