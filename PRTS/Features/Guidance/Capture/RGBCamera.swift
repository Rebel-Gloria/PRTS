import AVFoundation
import Foundation
import SpatialCore

nonisolated protocol RGBCapturing: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    var running: Bool { get }
    func setSceneActive(_ active: Bool)
    func setOrientation(_ orientation: ImageOrientation)
    func snapshot(orientation: ImageOrientation) -> CameraImageSnapshot?
    func start(completion: @escaping @Sendable (Bool) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
}

/// The low-vision camera does no world tracking, depth delivery, mesh reconstruction or inference.
/// Session mutations and frame callbacks share one queue; readers retain only the latest image.
nonisolated final class RGBCamera: NSObject, RGBCapturing,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "PRTS.RGBCamera", qos: .userInitiated)
    private let lock = NSLock()
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var recovery = RGBCameraRecovery()
    private var observers: [NSObjectProtocol] = []
    private var latest: CVPixelBuffer?
    private var timestamp: TimeInterval = 0
    private var receivedAt: TimeInterval = 0
    private var isRunning = false
    private var orientation: ImageOrientation = .portrait
    private var frameID: UInt64 = 0

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                else { return }
                let code = error.code
                let domain = error.domain
                self?.queue.async { [weak self] in self?.runtimeError(code: code, domain: domain) }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let reason =
                    (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?
                    .intValue
                self?.queue.async { [weak self] in self?.interruptionBegan(reason: reason) }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in self?.interruptionEnded() }
            }
        )
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var running: Bool { lock.withLock { isRunning } }

    func setSceneActive(_ active: Bool) {
        queue.async { [self] in
            recovery.setSceneActive(active)
            recoverIfNeeded()
        }
    }

    func setOrientation(_ orientation: ImageOrientation) {
        lock.withLock { self.orientation = orientation }
    }

    func snapshot(orientation: ImageOrientation) -> CameraImageSnapshot? {
        lock.withLock {
            guard isRunning, let latest else { return nil }
            return CameraImageSnapshot(
                pixelBuffer: latest,
                orientation: orientation,
                timestamp: timestamp,
                receivedAt: receivedAt,
                frameID: frameID
            )
        }
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            recovery.requestStart()
            guard configured || configure() else {
                completion(false)
                return
            }
            let alreadyRunning = session.isRunning
            if !alreadyRunning { session.startRunning() }
            let started = session.isRunning
            lock.withLock { isRunning = started }
            #if PRTS_DEV
            if !alreadyRunning || !started {
                RecordingStore.shared.event(
                    started ? "rgb_camera_started" : "rgb_camera_start_failed",
                    details: [:]
                )
            }
            #endif
            completion(started)
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            #if PRTS_DEV
            let wasRequested = recovery.requested
            #endif
            recovery.requestStop()
            if session.isRunning { session.stopRunning() }
            lock.withLock {
                isRunning = false
                latest = nil
            }
            #if PRTS_DEV
            if wasRequested { RecordingStore.shared.event("rgb_camera_stopped", details: [:]) }
            RecordingStore.shared.endVideoSegment(source: "rgb")
            #endif
            completion()
        }
    }

    private func configure() -> Bool {
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Keep the camera's native image shape; recording handles compression separately.
        session.sessionPreset = .high
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        configured = true
        return true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard recovery.requested, !recovery.interrupted,
            let image = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite else { return }
        let received = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            latest = image
            timestamp = time
            receivedAt = received
            isRunning = true
            frameID &+= 1
        }
        #if PRTS_DEV
        let identity = lock.withLock { (frameID, orientation) }
        RecordingStore.shared.videoFrame(
            pixelBuffer: image,
            timestamp: time,
            metadata: [
                "source": "rgb", "orientation": String(identity.1.rawValue),
                "frameID": String(identity.0),
            ]
        )
        #endif
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        #if PRTS_DEV
        RecordingStore.shared.noteGap("rgb_capture")
        RecordingStore.shared.event(
            "rgb_camera_frame_dropped",
            details: [
                "timestamp": String(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            ]
        )
        #endif
    }

    private func clearCachedFrame(running: Bool? = nil) {
        lock.withLock {
            latest = nil
            timestamp = 0
            receivedAt = 0
            if let running { isRunning = running }
        }
    }

    private func runtimeError(code: Int, domain: String) {
        let reset =
            domain == AVFoundationErrorDomain
            && code == AVError.Code.mediaServicesWereReset.rawValue
        clearCachedFrame(running: reset && recovery.requested ? nil : false)
        ErrorLog.application.record(NSError(domain: domain, code: code), source: .camera)
        #if PRTS_DEV
        RecordingStore.shared.event(
            "rgb_camera_runtime_error",
            details: ["domain": domain, "code": String(code)]
        )
        RecordingStore.shared.endVideoSegment(source: "rgb")
        #endif
        guard reset else { return }
        recovery.mediaServicesReset()
        recoverIfNeeded()
    }

    private func interruptionBegan(reason: Int?) {
        recovery.setInterrupted(true)
        clearCachedFrame()
        #if PRTS_DEV
        RecordingStore.shared.event(
            "rgb_camera_interrupted",
            details: ["reason": reason.map(String.init) ?? "unavailable"]
        )
        RecordingStore.shared.endVideoSegment(source: "rgb")
        #endif
    }

    private func interruptionEnded() {
        recovery.setInterrupted(false)
        clearCachedFrame()
        #if PRTS_DEV
        RecordingStore.shared.event("rgb_camera_interruption_ended")
        #endif
        recoverIfNeeded()
    }

    private func recoverIfNeeded() {
        guard configured, recovery.takeRecoveryRequest() else { return }
        // A reset is recoverable only while the user still wants this camera in the foreground.
        if !session.isRunning { session.startRunning() }
        let resumed = session.isRunning
        lock.withLock { isRunning = resumed }
        #if PRTS_DEV
        RecordingStore.shared.event(
            resumed ? "rgb_camera_recovered" : "rgb_camera_recovery_failed"
        )
        #endif
    }
}
