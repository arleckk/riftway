import Foundation

/// What Riftway does with the controller (PRD-04), in the couch mode and the
/// main window: move through the games, play, open the options, change
/// sections, go back, switch to and from the couch mode (`menu`).
public enum CouchCommand: Equatable, Sendable {
    case left, right, up, down
    case confirm, back, options
    case previousSection, nextSection
    case menu
}

/// The controller as the couch mode reads it, by position: `confirm` is the
/// bottom face button (✕, A), `back` the right one (○, B), `options` the top
/// one (△, Y); `menu` is Options (☰, +). Directions come from the d-pad or
/// the left stick. Home stays macOS's: it opens the Games overlay.
public struct CouchPadState: Equatable, Sendable {
    public var left = false, right = false, up = false, down = false
    public var confirm = false, back = false, options = false
    public var previousSection = false, nextSection = false
    public var menu = false

    public init() {}
}

/// Turns sampled controller states into commands: a button gives one command
/// when pressed; a direction gives one when pressed and repeats while held,
/// after a pause, so a held d-pad scrolls through the games.
public struct CouchInputReader: Sendable {
    public var firstRepeat: TimeInterval
    public var repeatEvery: TimeInterval
    private var previous = CouchPadState()
    /// When each held direction gives its next command.
    private var nextRepeat: [CouchCommand: TimeInterval] = [:]

    public init(firstRepeat: TimeInterval = 0.4, repeatEvery: TimeInterval = 0.12) {
        self.firstRepeat = firstRepeat
        self.repeatEvery = repeatEvery
    }

    public mutating func read(_ state: CouchPadState, at time: TimeInterval) -> [CouchCommand] {
        var commands: [CouchCommand] = []
        let directions: [(CouchCommand, Bool, Bool)] = [
            (.left, state.left, previous.left), (.right, state.right, previous.right),
            (.up, state.up, previous.up), (.down, state.down, previous.down),
        ]
        for (command, now, before) in directions {
            if now && !before {
                commands.append(command)
                nextRepeat[command] = time + firstRepeat
            } else if now, let due = nextRepeat[command], time >= due {
                commands.append(command)
                nextRepeat[command] = time + repeatEvery
            } else if !now {
                nextRepeat[command] = nil
            }
        }
        let buttons: [(CouchCommand, Bool, Bool)] = [
            (.confirm, state.confirm, previous.confirm), (.back, state.back, previous.back),
            (.options, state.options, previous.options),
            (.previousSection, state.previousSection, previous.previousSection),
            (.nextSection, state.nextSection, previous.nextSection), (.menu, state.menu, previous.menu),
        ]
        commands += buttons.filter { $0.1 && !$0.2 }.map(\.0)
        previous = state
        return commands
    }
}

/// Moving through a grid of covers with the d-pad: left and right step
/// through the games in order, up and down jump a row and stop at the edges.
public enum CoverGridFocus {
    /// The index after `command`, in a grid of `count` covers laid out in
    /// `columns`. Without a focus yet, any direction lands on the first.
    public static func move(_ index: Int?, _ command: CouchCommand, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, index < count else { return 0 }
        let columns = max(1, columns)
        switch command {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return index >= columns ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            // A shorter last row: down from above its end lands on its last cover.
            return index / columns < (count - 1) / columns ? count - 1 : index
        default: return index
        }
    }
}
