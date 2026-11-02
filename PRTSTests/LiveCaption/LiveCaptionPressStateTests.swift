import Testing

@testable import PRTS

struct LiveCaptionPressStateTests {
    @Test func singleTapWaitsForConfirmation() {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 0, running: false).isEmpty)
        #expect(state.up(at: 0.1).isEmpty)
        #expect(state.advance(to: 0.349).isEmpty)
        #expect(state.advance(to: 0.35).isEmpty)
        #expect(state.advance(to: 0.35.nextUp) == [.photo(.shortCapture)])
        #expect(state.advance(to: 1).isEmpty)
        #expect(state.deadline == nil)
    }

    @Test(arguments: [0.349, 0.35])
    func adjacentPressBoundaryStartsAfterThirdRelease(interval: Double) {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 0, running: false).isEmpty)
        #expect(state.up(at: 0.01).isEmpty)
        #expect(state.down(at: interval, running: false).isEmpty)
        #expect(state.up(at: interval + 0.01).isEmpty)
        #expect(state.down(at: interval * 2, running: false).isEmpty)
        #expect(state.up(at: interval * 2 + 0.01) == [.start])
        #expect(state.advance(to: 2).isEmpty)
    }

    @Test func twoTapsDescribeOnceAfterSecondDeadline() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 10, running: false)
        _ = state.up(at: 10.1)
        #expect(state.down(at: 10.2, running: false).isEmpty)
        #expect(state.up(at: 10.3).isEmpty)
        #expect(state.advance(to: 10.54).isEmpty)
        #expect(state.advance(to: (10.2 + 0.35).nextUp) == [.photo(.shortCapture)])
        #expect(state.advance(to: 11).isEmpty)
    }

    @Test func lateSecondPressConfirmsFirstAndStartsNewSequence() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0, running: false)
        _ = state.up(at: 0.1)
        #expect(state.down(at: 0.351, running: false) == [.photo(.shortCapture)])
        #expect(state.up(at: 0.4).isEmpty)
        #expect(state.advance(to: 0.702) == [.photo(.shortCapture)])
    }

    @Test func lateThirdPressConfirmsPairAndStartsNewSequence() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0, running: false)
        _ = state.up(at: 0.1)
        _ = state.down(at: 0.2, running: false)
        _ = state.up(at: 0.3)
        #expect(state.down(at: 0.551, running: false) == [.photo(.shortCapture)])
        #expect(state.up(at: 0.6).isEmpty)
        #expect(state.advance(to: 0.902) == [.photo(.shortCapture)])
    }

    @Test func releaseAfterTapDeadlineStillDescribes() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0, running: false)
        #expect(state.advance(to: 0.4).isEmpty)
        #expect(state.up(at: 0.499) == [.photo(.shortCapture)])
    }

    @Test func runningStopsOnDownAndSuppressesTheHold() {
        var state = LiveCaptionPressState()
        #expect(state.down(at: 10, running: true) == [.stop])
        #expect(state.deadline == nil)
        #expect(state.advance(to: 10.5).isEmpty)
        #expect(state.up(at: 11).isEmpty)
        #expect(state.down(at: 12, running: false).isEmpty)
        _ = state.up(at: 12.1)
        #expect(state.advance(to: 12.4) == [.photo(.shortCapture)])
    }

    @Test(arguments: [0, 1, 2])
    func holdAtAnyPositionRecordsAndClearsTaps(taps: Int) {
        var state = LiveCaptionPressState()
        for tap in 0..<taps {
            _ = state.down(at: Double(tap) * 0.25, running: false)
            _ = state.up(at: Double(tap) * 0.25 + 0.1)
        }
        let start = Double(taps) * 0.25
        #expect(state.down(at: start, running: false).isEmpty)
        #expect(state.deadline == start + 0.5)
        #expect(state.advance(to: start + 0.499).isEmpty)
        #expect(state.advance(to: start + 0.5) == [.photo(.startRecording)])
        #expect(state.deadline == nil)
        #expect(state.advance(to: start + 1).isEmpty)
        #expect(state.up(at: start + 1) == [.photo(.stopRecording)])
        #expect(state.down(at: start + 1.1, running: false).isEmpty)
        #expect(state.up(at: start + 1.2).isEmpty)
        #expect(state.advance(to: start + 1.5) == [.photo(.shortCapture)])
    }

    @Test(arguments: [0.5, 0.501])
    func lateLongPressTimerStartsAndStopsOnRelease(duration: Double) {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0, running: false)
        #expect(state.up(at: duration) == [.photo(.startRecording), .photo(.stopRecording)])
        #expect(state.advance(to: 1).isEmpty)
    }

    @Test func cancellationClearsPendingPhotoAndHold() {
        var state = LiveCaptionPressState()
        _ = state.down(at: 0, running: false)
        _ = state.up(at: 0.1)
        state.cancel()
        #expect(state.advance(to: 1).isEmpty)
        _ = state.down(at: 2, running: false)
        state.cancel()
        #expect(state.advance(to: 2.5).isEmpty)
        #expect(state.up(at: 3).isEmpty)
    }
}
