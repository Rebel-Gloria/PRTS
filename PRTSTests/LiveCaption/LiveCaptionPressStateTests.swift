import Testing

@testable import PRTS

struct LiveCaptionPressStateTests {
    @Test func firstPressImmediatelyUsesPhoto() {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 10) == .photo)
        #expect(state.down(at: 10.301) == .photo)
    }

    @Test(arguments: [0.299, 0.3])
    func doublePressIncludesBoundary(interval: Double) {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 10) == .photo)
        #expect(state.down(at: 10 + interval) == .confirm)
    }

    @Test func confirmationRequiresAnotherPair() {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 0) == .photo)
        #expect(state.down(at: 0.2) == .confirm)
        #expect(state.down(at: 0.3) == .photo)
        #expect(state.down(at: 0.4) == .start)
        #expect(state.phase == .running)
    }

    @Test func confirmationIncludesFiveSecondBoundary() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0)
        _ = state.down(at: 0.2)
        #expect(state.down(at: 5) == .photo)
        #expect(state.down(at: 5.2) == .start)
    }

    @Test func expiredConfirmationReturnsToOrdinaryDoublePress() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0)
        _ = state.down(at: 0.2)
        #expect(state.down(at: 5.201) == .photo)
        #expect(state.phase == .normal)
        #expect(state.down(at: 5.4) == .confirm)
    }

    @Test func pairCrossingConfirmationDeadlineStartsFresh() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0)
        _ = state.down(at: 0.2)
        _ = state.down(at: 5.1)
        #expect(state.down(at: 5.3) == .photo)
        #expect(state.down(at: 5.5) == .confirm)
    }

    @Test func runningIgnoresSinglePressAndExitsOnDoublePress() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0)
        _ = state.down(at: 0.2)
        _ = state.down(at: 1)
        _ = state.down(at: 1.2)
        #expect(state.down(at: 2) == .none)
        #expect(state.down(at: 3) == .none)
        #expect(state.down(at: 3.3) == .stop)
        #expect(state.phase == .normal)
        #expect(state.down(at: 4) == .photo)
    }

    @Test func cancelledTouchClearsPair() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0)
        state.cancelPress()
        #expect(state.down(at: 0.2) == .photo)
    }
}
