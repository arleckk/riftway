import Foundation

/// What the couch mode does with the controller (PRD-04): move through the
/// games, play, open the options, change sections, leave.
public enum CouchCommand: Equatable, Sendable {
    case left, right, up, down
    case confirm, back, options
    case previousSection, nextSection
    case home
}

/// The controller as the couch mode reads it, by position: `confirm` is the
/// bottom face button (✕, A), `back` the right one (○, B), `options` the top
/// one (△, Y). Directions come from the d-pad or the left stick.
public struct CouchPadState: Equatable, Sendable {
    public var left = false, right = false, up = false, down = false
    public var confirm = false, back = false, options = false
    public var previousSection = false, nextSection = false
    public var home = false

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
            (.nextSection, state.nextSection, previous.nextSection), (.home, state.home, previous.home),
        ]
        commands += buttons.filter { $0.1 && !$0.2 }.map(\.0)
        previous = state
        return commands
    }
}
