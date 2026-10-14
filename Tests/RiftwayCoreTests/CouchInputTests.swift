import Testing
@testable import RiftwayCore

@Suite struct CouchInputTests {
    private func state(_ change: (inout CouchPadState) -> Void) -> CouchPadState {
        var state = CouchPadState()
        change(&state)
        return state
    }

    @Test func buttonsGiveOneCommandPerPress() {
        var reader = CouchInputReader()
        let pressed = state { $0.confirm = true }
        #expect(reader.read(pressed, at: 0) == [.confirm])
        #expect(reader.read(pressed, at: 1).isEmpty)
        #expect(reader.read(CouchPadState(), at: 1.1).isEmpty)
        #expect(reader.read(pressed, at: 1.2) == [.confirm])
    }

    @Test func heldDirectionsRepeatAfterAPause() {
        var reader = CouchInputReader(firstRepeat: 0.4, repeatEvery: 0.1)
        let right = state { $0.right = true }
        #expect(reader.read(right, at: 0) == [.right])
        #expect(reader.read(right, at: 0.3).isEmpty)
        #expect(reader.read(right, at: 0.4) == [.right])
        #expect(reader.read(right, at: 0.45).isEmpty)
        #expect(reader.read(right, at: 0.5) == [.right])
        // Let go and press again: right away, with a new pause.
        #expect(reader.read(CouchPadState(), at: 0.55).isEmpty)
        #expect(reader.read(right, at: 0.6) == [.right])
        #expect(reader.read(right, at: 0.7).isEmpty)
    }

    @Test func simultaneousPressesAllCount() {
        var reader = CouchInputReader()
        let both = state {
            $0.down = true
            $0.nextSection = true
        }
        #expect(reader.read(both, at: 0) == [.down, .nextSection])
    }

    @Test func gridFocusMovesByRowsAndStopsAtEdges() {
        // 7 covers in 3 columns: 0 1 2 / 3 4 5 / 6
        #expect(CoverGridFocus.move(nil, .down, count: 7, columns: 3) == 0)
        #expect(CoverGridFocus.move(1, .down, count: 7, columns: 3) == 4)
        #expect(CoverGridFocus.move(4, .down, count: 7, columns: 3) == 6)
        #expect(CoverGridFocus.move(6, .down, count: 7, columns: 3) == 6)
        #expect(CoverGridFocus.move(5, .up, count: 7, columns: 3) == 2)
        #expect(CoverGridFocus.move(2, .up, count: 7, columns: 3) == 2)
        #expect(CoverGridFocus.move(2, .right, count: 7, columns: 3) == 3)
        #expect(CoverGridFocus.move(0, .left, count: 7, columns: 3) == 0)
        #expect(CoverGridFocus.move(9, .left, count: 7, columns: 3) == 0)
        #expect(CoverGridFocus.move(0, .down, count: 0, columns: 3) == nil)
    }
}
