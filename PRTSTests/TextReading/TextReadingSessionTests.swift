import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import PRTS

private enum ReadingTestError: Error { case failed }

private actor ReadingPendingAnswer {
    private var continuation: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func read() async -> String {
        await withCheckedContinuation {
            continuation = $0
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func finish() {
        continuation?.resume(returning: "旧文字。")
        continuation = nil
    }
}

nonisolated private final class ReadingTestCamera: TextCapturing, @unchecked Sendable {
    let session = AVCaptureSession()
    private let lock = NSLock()
    private var previews: [@MainActor () -> Void] = []
    private var requests: [TextPhotoRequest] = []
    private var startCount = 0
    private var stopCount = 0
    var holdsStopCompletion = false
    private var pendingStops: [@MainActor @Sendable () -> Void] = []

    var starts: Int { lock.withLock { startCount } }
    var captures: Int { lock.withLock { requests.count } }
    var stops: Int { lock.withLock { stopCount } }

    func start(frame: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        lock.withLock {
            previews.append(frame)
            startCount += 1
        }
    }
    func capture(_ done: @escaping (CIImage?) -> Void) {
        lock.withLock { requests.append(TextPhotoRequest(completion: done)) }
    }
    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        let complete = lock.withLock {
            stopCount += 1
            if holdsStopCompletion {
                pendingStops.append(completion)
                return false
            }
            return true
        }
        // The session invokes its fake camera on the main actor; real hardware completes later.
        if complete { MainActor.assumeIsolated { completion() } }
    }

    @MainActor func finishStops() {
        let callbacks = lock.withLock {
            let callbacks = pendingStops
            pendingStops.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    @MainActor func frame(_ index: Int? = nil) {
        lock.withLock { previews[index ?? previews.count - 1] }()
    }
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
private final class ReadingTestTimeout {
    private var sleepers: [CheckedContinuation<Void, Never>?] = []
    private var waiter: (Int, CheckedContinuation<Void, Never>)?

    /// Deliberately ignores cancellation so tests also exercise the session's late-result guards.
    func sleep(_ duration: Duration) async {
        #expect(duration == TextReadingSession.cameraTimeout)
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
            if let waiter, sleepers.count >= waiter.0 {
                self.waiter = nil
                waiter.1.resume()
            }
        }
    }

    func waitForSleep(_ count: Int = 1) async {
        if sleepers.count >= count { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    func fire(_ index: Int = 0) {
        let continuation = sleepers[index]
        sleepers[index] = nil
        continuation?.resume()
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
        services.errors = .ignored
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
    #if PRTS_DEV
    @Test func cancellationRecordsTheOriginalInteractionEnd() async throws {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        let id = h.session.interactionID.uuidString
        h.session.cancel()
        h.audio.finish()
        #expect(h.session.phase == .idle)
        let store = RecordingStore.shared
        await withCheckedContinuation { done in store.flush { done.resume() } }
        var names: [String] = []
        for directory in try FileManager.default.contentsOfDirectory(
            at: store.root,
            includingPropertiesForKeys: nil
        ) {
            let path = directory.appendingPathComponent("events.jsonl")
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                let object =
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                guard let payload = object?["payload"] as? [String: Any],
                    let details = payload["details"] as? [String: String],
                    details["interactionID"] == id,
                    let name = payload["name"] as? String
                else { continue }
                names.append(name)
            }
        }
        #expect(names.contains("interaction_started"))
        #expect(names.filter { $0 == "interaction_ended" }.count == 1)
    }
    #endif

    @Test func mutedReaderCompletesWithoutCancellingOrReplayingSpeech() async {
        let pending = ReadingPendingAnswer()
        let h = ReadingHarness { services in
            services.vision = { _ in await pending.read() }
        }
        h.session.start(intro: "intro")
        h.capture()
        h.camera.deliver(0, image: h.image())
        await pending.waitForRequest()
        let work = h.session.work
        h.session.setFeedbackEnabled(false)
        #expect(work?.isCancelled == false)
        h.session.setFeedbackEnabled(true)
        await pending.finish()
        await work?.value
        #expect(h.audio.spoken == ["intro", "ocr.capturing"])
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
    }

    @Test func cancelledHandoffCannotStartTheTextCameraLater() {
        let h = ReadingHarness()
        var ready: (@MainActor @Sendable () -> Void)?
        h.session.start(intro: "intro", prepareCamera: { ready = $0 })
        #expect(h.session.phase == .aiming)
        #expect(h.camera.starts == 0)
        #expect(h.session.work == nil)
        h.session.terminate()
        #expect(h.ended == 1)
        ready?()
        #expect(h.camera.starts == 0)
        #expect(h.session.phase == .idle)
    }

    @Test func handoffStartsCaptureAfterThePreviousCameraReleases() {
        let h = ReadingHarness()
        var ready: (@MainActor @Sendable () -> Void)?
        h.session.start(intro: "intro", prepareCamera: { ready = $0 })
        #expect(h.camera.starts == 0)
        #expect(h.session.work == nil)
        ready?()
        #expect(h.camera.starts == 1)
        #expect(h.session.work != nil)
        h.session.terminate()
    }

    @Test(arguments: [0, 1])
    func aimingTimeoutCoversMissingAndStalledPreview(frames: Int) async {
        let timeout = ReadingTestTimeout()
        let h = ReadingHarness { services in
            services.sleep = { await timeout.sleep($0) }
        }
        h.session.start(intro: "intro")
        let work = h.session.work
        await timeout.waitForSleep()
        for _ in 0..<frames { h.camera.frame() }
        #expect(h.session.framesSeen == frames)
        timeout.fire()
        await work?.value
        #expect(h.session.phase == .ending)
        #expect(h.audio.spoken == ["intro", "ocr.error.camera"])
        #expect(h.camera.stops == 1)
        #expect(h.camera.captures == 0)
        #expect(h.ended == 0)

        h.now += TextReadingSession.settle
        h.camera.frame()
        #expect(h.camera.captures == 0)
        #expect(h.session.framesSeen == frames)
        h.audio.finish()
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
        h.camera.frame()
        h.audio.finish()
        #expect(h.camera.captures == 0)
        #expect(h.ended == 1)
    }

    @Test func aimingTimeoutCannotInterruptCapture() async {
        let timeout = ReadingTestTimeout()
        let h = ReadingHarness { services in
            services.sleep = { await timeout.sleep($0) }
        }
        h.session.start(intro: "intro")
        let work = h.session.work
        await timeout.waitForSleep()
        h.capture()
        #expect(h.camera.captures == 1)
        timeout.fire()
        await work?.value
        #expect(h.audio.spoken == ["intro", "ocr.capturing"])
        #expect(h.camera.stops == 0)
        #expect(h.ended == 0)
        h.camera.deliver(0, image: h.image())
        await h.audio.waitForSpeech(3)
        await h.session.work?.value
        #expect(h.audio.spoken.last == "ocr.lead.object：测试文字。")
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test func aimingTimeoutCannotCancelRecognitionAlreadyInProgress() async {
        let timeout = ReadingTestTimeout()
        let entered = TestSignal()
        let release = TestSignal()
        let h = ReadingHarness { services in
            services.sleep = { await timeout.sleep($0) }
            services.vision = { _ in
                await entered.signal()
                await release.wait()
                return "测试文字。"
            }
        }
        h.session.start(intro: "intro")
        let oldWork = h.session.work
        await timeout.waitForSleep()
        h.capture()
        h.camera.deliver(0, image: h.image())
        await entered.wait()
        let reader = h.session.work
        timeout.fire()
        await oldWork?.value
        #expect(reader?.isCancelled == false)
        #expect(h.audio.spoken == ["intro", "ocr.capturing"])
        #expect(h.ended == 0)
        await release.signal()
        await reader?.value
        #expect(h.audio.spoken.last == "ocr.lead.object：测试文字。")
        h.audio.finish()
        #expect(h.ended == 1)
    }

    @Test(arguments: [false, true])
    func oldTimeoutAndPreviewCannotAffectNewPass(cancel: Bool) async {
        let timeout = ReadingTestTimeout()
        let h = ReadingHarness { services in
            services.sleep = { await timeout.sleep($0) }
        }
        h.session.start(intro: "A")
        let oldWork = h.session.work
        await timeout.waitForSleep()
        if cancel {
            h.session.cancel()
            h.audio.finish()
        } else {
            h.session.terminate()
        }
        #expect(h.ended == 1)
        h.session.start(intro: "B")
        let newWork = h.session.work
        await timeout.waitForSleep(2)
        timeout.fire(0)
        await oldWork?.value
        h.camera.frame(0)
        #expect(h.session.phase == .aiming)
        #expect(h.session.framesSeen == 0)
        #expect(h.camera.captures == 0)
        #expect(h.audio.spoken.last == "B")
        #expect(!h.audio.spoken.contains("ocr.error.camera"))
        #expect(newWork?.isCancelled == false)
        #expect(h.ended == 1)

        timeout.fire(1)
        await newWork?.value
        #expect(h.audio.spoken.last == "ocr.error.camera")
        h.audio.finish()
        #expect(h.ended == 2)
    }

    @Test func guidanceRecoveryWaitsForTextCameraRelease() {
        let h = ReadingHarness()
        h.session.start(intro: "intro")
        h.camera.holdsStopCompletion = true
        h.session.terminate()
        #expect(h.session.phase == .ending)
        #expect(h.ended == 0)
        h.session.start(intro: "another pass")
        #expect(h.camera.starts == 1)
        h.camera.finishStops()
        #expect(h.session.phase == .idle)
        #expect(h.ended == 1)
        h.camera.holdsStopCompletion = false
        h.session.start(intro: "next pass")
        h.session.terminate()
        #expect(h.ended == 2)
    }

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
