import Foundation
import Testing

@testable import PRTS

@MainActor
private final class CaptionPhotoAudio: PhotoAnswerAudio {
    var onFinished: (() -> Void)?
    var cues: [PhotoAudioOutput.Cue] = []
    func cue(_ cue: PhotoAudioOutput.Cue) throws { cues.append(cue) }
    func speak(_ text: String) throws {}
    func stop() {}
}

@MainActor
private final class CaptionPhotoRecognizer: PhotoRecognizing {
    var starts = 0
    func start() throws { starts += 1 }
    func endCapture() {}
    func finish() async throws -> String { "谁走过来了？" }
    func cancel() {}
}

@MainActor
private final class CaptionPhotoFixture {
    var time: TimeInterval = 0
    var captures = 0
    var state = LiveCaptionPressState()
    let audio = CaptionPhotoAudio()
    let recognizer = CaptionPhotoRecognizer()
    lazy var photo: PhotoDescriptionCoordinator = {
        var services = PhotoDescriptionServices()
        services.now = { [unowned self] in self.time }
        services.onDevice = { true }
        services.speechAuthorized = { true }
        services.describe = { _, _, _ in "门口有人。" }
        return PhotoDescriptionCoordinator(
            recognizer: recognizer,
            audio: audio,
            services: services
        )
    }()

    func perform(_ actions: [LiveCaptionPressState.Action]) {
        for action in actions {
            switch action {
            case .photo(let action):
                if !photo.perform(
                    action,
                    capture: {
                        self.captures += 1
                        return Task { Data([1]) }
                    },
                    silence: {}
                ) {
                    state.cancel()
                }
            case .start, .stop: photo.cancel()
            }
        }
    }
}

@MainActor
struct LiveCaptionPhotoInteractionTests {
    @Test(arguments: [1, 2])
    func shortPressCueAndCaptureWaitForConfirmation(taps: Int) async {
        let fixture = CaptionPhotoFixture()
        for tap in 0..<taps {
            fixture.time = Double(tap) * 0.2
            fixture.perform(fixture.state.down(at: fixture.time, running: false))
            fixture.time += 0.1
            fixture.perform(fixture.state.up(at: fixture.time))
        }
        #expect(fixture.captures == 0)
        #expect(fixture.audio.cues.isEmpty)
        #expect(!fixture.photo.busy)
        #expect(fixture.photo.work == nil)
        fixture.time = Double(taps - 1) * 0.2 + 0.351
        fixture.perform(fixture.state.advance(to: fixture.time))
        #expect(fixture.captures == 1)
        #expect(fixture.audio.cues == [.submit])
        await fixture.photo.work?.value
        fixture.photo.cancel()
    }

    @Test func triplePressHasNoPhotoCueOrCapture() {
        let fixture = CaptionPhotoFixture()
        for tap in 0..<3 {
            fixture.time = Double(tap) * 0.2
            fixture.perform(fixture.state.down(at: fixture.time, running: false))
            fixture.time += 0.1
            fixture.perform(fixture.state.up(at: fixture.time))
        }
        #expect(fixture.captures == 0)
        #expect(fixture.audio.cues.isEmpty)
        #expect(fixture.photo.work == nil)
    }

    @Test func holdRecordsAtHalfSecondAndSubmitsOnRelease() async {
        let fixture = CaptionPhotoFixture()
        fixture.perform(fixture.state.down(at: 0, running: false))
        fixture.time = 0.5
        fixture.perform(fixture.state.advance(to: fixture.time))
        #expect(fixture.recognizer.starts == 1)
        #expect(fixture.captures == 1)
        #expect(fixture.audio.cues == [.record])
        fixture.time = 1
        fixture.perform(fixture.state.up(at: fixture.time))
        #expect(fixture.audio.cues == [.record, .submit])
        await fixture.photo.work?.value
        fixture.photo.cancel()
    }

    @Test func rejectedHoldDoesNotSubmitAnExistingPhotoAsAQuestion() async {
        let fixture = CaptionPhotoFixture()
        fixture.perform([.photo(.shortCapture)])
        fixture.time = 1
        fixture.perform(fixture.state.down(at: fixture.time, running: false))
        fixture.time = 1.5
        fixture.perform(fixture.state.advance(to: fixture.time))
        fixture.time = 2
        fixture.perform(fixture.state.up(at: fixture.time))
        #expect(fixture.recognizer.starts == 0)
        #expect(fixture.captures == 1)
        #expect(fixture.audio.cues == [.submit])
        await fixture.photo.work?.value
        fixture.photo.cancel()
    }
}
