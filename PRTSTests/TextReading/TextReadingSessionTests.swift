import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import PRTS

private enum ReadingTestError: Error { case failed }

nonisolated private final class ReadingTestCamera: TextCapturing, @unchecked Sendable {
    let session = AVCaptureSession()
    private let lock = NSLock()
    private var preview: (@MainActor () -> Void)?
    private var requests: [TextPhotoRequest] = []
    private var startCount = 0
    private var stopCount = 0

    var starts: Int { lock.withLock { startCount } }
    var captures: Int { lock.withLock { requests.count } }
    var stops: Int { lock.withLock { stopCount } }

    func start(frame: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        lock.withLock {
            preview = frame
            startCount += 1
        }
    }
    func capture(_ done: @escaping (CIImage?) -> Void) {
        lock.withLock { requests.append(TextPhotoRequest(completion: done)) }
    }
    func stop() { lock.withLock { stopCount += 1 } }

    @MainActor func frame() { lock.withLock { preview }!() }
    func deliver(_ index: Int, image: CIImage?) {
        lock.withLock { requests[index] }.complete(image)
    }
}

@MainActor
private final class ReadingTestAnswerAudio: AnswerAudio {
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    var pending: [String] = []
    var stops = 0
    var failure: String?
    var active = false
    private var waiter: (Int, CheckedContinuation<Void, Never>)?

    func cue(_ cue: AnswerCue) throws {}
    func speak(_ text: String) throws {
        active = true
        if text == failure { throw ReadingTestError.failed }
        spoken.append(text)
        pending.append(text)
        if let waiter, spoken.count >= waiter.0 {
            self.waiter = nil
            waiter.1.resume()
        }
    }
    func stop() {
        active = false
        stops += 1
        pending.removeAll()
    }
    func finish() { onFinished?() }
    func waitForSpeech(_ count: Int) async {
        if spoken.count >= count { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }
}

@MainActor
private final class ReadingHarness {
    let camera = ReadingTestCamera()
    let audio = ReadingTestAnswerAudio()
    var now: TimeInterval = 0
    var ended = 0
    var encoded: [Float] = []
    var session: TextReadingSession!

    init(
        service: TextReadingService = .vision,
        configure: (inout TextReadingServices) -> Void = { _ in }
    ) {
        var services = TextReadingServices()
        services.now = { [unowned self] in now }
        // The camera timeout never fires on its own; tests end passes explicitly.
        services.sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        services.encode = { [unowned self] image in
            encoded.append(Float(image.extent.width))
            return Data()
        }
        services.vision = { _ in "测试文字。" }
        configure(&services)
        session = TextReadingSession(
            camera: camera,
            voice: audio,
            services: services,
            selectedService: { service },
            cloudSetup: { nil }
        )
        session.finished = { [unowned self] in ended += 1 }
    }

    func capture() {
        camera.frame()
        now += TextReadingSession.settle
        camera.frame()
    }

    func image(_ width: CGFloat = 10) -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: 10))
    }
}

@MainActor
struct TextReadingSessionTests {
    @Test func introSpeechFailureDoesNotStartCamera() {
        let h = ReadingHarness()
        h.audio.failure = "intro"
        h.session.start(intro: "intro")
        #expect(h.camera.starts == 0)
        #expect(h.camera.captures == 0)
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
        #expect(!h.audio.active)
    }

    @Test func captureSpeechFailureDoesNotTakePhoto() {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.audio.failure = "ocr.capturing"
        h.capture()
        #expect(h.camera.captures == 0)
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
        #expect(!h.audio.active)
    }

    @Test func oldPhotoCannotBecomeNewPassPhoto() async {
        let h = ReadingHarness()
        h.session.start(intro: "A")
        h.capture()
        h.session.cancel()
        h.audio.finish()
        h.session.start(intro: "B")
        h.capture()
        h.camera.deliver(0, image: h.image(11))
        h.camera.deliver(1, image: h.image(22))
        await h.audio.waitForSpeech(6)
        await h.session.work?.value
        #expect(h.encoded == [22])
        #expect(h.audio.spoken.last == "ocr.lead.object：测试文字。")
        h.audio.finish()
        #expect(h.ended == 2)
    }

    @Test func missingPhotoReportsFailure() async {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: nil)
        await h.audio.waitForSpeech(3)
        #expect(h.audio.spoken.last == "ocr.failed")
        #expect(!h.audio.spoken.contains("ocr.empty"))
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test func encodingFailureReportsFailureWithoutInvokingReader() async {
        let h = ReadingHarness { services in
            services.encode = { _ in throw ReadingTestError.failed }
            services.vision = { _ in
                Issue.record("Encoding failure cannot enter recognition")
                return ""
            }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(3)
        #expect(h.audio.spoken.last == "ocr.failed")
        #expect(!h.audio.spoken.contains("ocr.empty"))
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test(arguments: ["新结果。", ""])
    func fallbackDiscardsFailedReadersQueuedSpeech(text: String) async {
        let h = ReadingHarness(service: .onDevice) { services in
            services.surface = { _ in .paper }
            services.copy = { send in
                send("旧结果。尚未完成")
                throw ReadingTestError.failed
            }
            services.vision = { _ in text }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(4)
        await h.session.work?.value
        #expect(h.audio.stops == 1)
        #expect(h.audio.pending == [text.isEmpty ? "ocr.empty" : "ocr.lead.object：新结果。"])
        h.audio.finish()
        #expect(h.ended == 1)
        #expect(!h.audio.active)
    }

    @Test func allReadersFailAfterPartialText() async {
        var readers: [String] = []
        let h = ReadingHarness(service: .onDevice) { services in
            services.surface = { _ in .paper }
            services.copy = { send in
                readers.append("local")
                send("已识别部分。尚未结束")
                throw ReadingTestError.failed
            }
            services.vision = { _ in
                readers.append("vision")
                throw ReadingTestError.failed
            }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(4)
        #expect(readers == ["local", "vision"])
        #expect(Array(h.audio.spoken.suffix(2)) == ["ocr.lead.paper：已识别部分。", "ocr.failed"])
        #expect(!h.audio.spoken.contains("尚未结束"))
        #expect(!h.audio.spoken.contains("ocr.empty"))
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test func allReadersFailWithoutText() async {
        var readers: [String] = []
        let h = ReadingHarness(service: .onDevice) { services in
            services.surface = { _ in
                readers.append("local")
                throw ReadingTestError.failed
            }
            services.vision = { _ in
                readers.append("vision")
                throw ReadingTestError.failed
            }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(3)
        #expect(readers == ["local", "vision"])
        #expect(h.audio.spoken == ["intro", "ocr.capturing", "ocr.failed"])
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test func successfulEmptyResultUsesEmptyPrompt() async {
        let h = ReadingHarness { $0.vision = { _ in "" } }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(3)
        #expect(h.audio.spoken.last == "ocr.empty")
        h.audio.finish()
    }

    @Test func cancellationDuringRecognitionDoesNotAnnounceFailureOrEmpty() async {
        let entered = TestSignal()
        let release = TestSignal()
        let h = ReadingHarness { services in
            services.vision = { _ in
                await entered.signal()
                await release.wait()
                throw CancellationError()
            }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await entered.wait()
        let work = h.session.work
        h.session.terminate()
        await release.signal()
        await work?.value
        #expect(h.audio.spoken == ["intro", "ocr.capturing"])
        #expect(h.ended == 1)
        #expect(!h.audio.active)
    }

    @Test func userCancellationReleasesAudioAfterPromptAndFinishesOnce() {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.session.cancel()
        #expect(h.session.phase == .ending)
        #expect(h.audio.spoken == ["intro", "ocr.cancelled"])
        #expect(h.audio.active)
        #expect(h.ended == 0)
        h.session.cancel()
        h.audio.finish()
        #expect(!h.audio.active)
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
        h.audio.finish()
        h.session.terminate()
        #expect(h.ended == 1)
    }

    @Test func lifecycleTerminationIsSilentIncludingDuringCancelPrompt() {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.session.terminate()
        #expect(h.audio.spoken == ["intro"])
        #expect(!h.audio.active)
        #expect(h.ended == 1)
        h.session.start(intro: "second")
        h.session.cancel()
        h.session.terminate()
        h.audio.finish()
        #expect(h.audio.spoken == ["intro", "second", "ocr.cancelled"])
        #expect(!h.audio.active)
        #expect(h.ended == 2)
    }

    @Test func cancelPromptFailureStillFinishesAndReleasesAudio() {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.audio.failure = "ocr.cancelled"
        h.session.cancel()
        #expect(h.session.phase == .idle)
        #expect(!h.audio.active)
        #expect(h.ended == 1)
    }
}
