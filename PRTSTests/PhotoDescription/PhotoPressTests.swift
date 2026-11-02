import Testing

@testable import PRTS

struct PhotoPressTests {
    @Test func shortPressAndThreshold() {
        var press = PhotoPressState()
        press.begin(at: 10)
        #expect(press.release(at: 10.499) == [.shortCapture])
        press.begin(at: 20)
        #expect(press.release(at: 20.5) == [.startRecording, .stopRecording])
    }
    @Test func longPressStartsOnceAndCancelNeverSubmits() {
        var press = PhotoPressState()
        press.begin(at: 0)
        #expect(press.advance(to: 0.5) == .startRecording)
        #expect(press.advance(to: 0.6) == .none)
        #expect(press.release(at: 1) == [.stopRecording])
        press.begin(at: 2)
        press.cancel()
        #expect(press.release(at: 3).isEmpty)
        #expect(press.advance(to: 3) == .none)
    }
}
